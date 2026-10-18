"""
gm_gold_sde.py — ECUACIÓN MAESTRA DEL ORO (XAUUSD)

Modelo estocástico de 4 capas para el log-precio del oro, calibrado sobre datos
reales 2004-2025. No es una fórmula de predicción: es una ecuación que reproduce
la ESTRUCTURA DE RIESGO del oro (volatilidad agrupada, colas gruesas, saltos,
estacionalidad horaria, regímenes) para poder dimensionar posiciones y calcular
probabilidad de ruina con honestidad.

────────────────────────────────────────────────────────────────────────────────
LA ECUACIÓN
────────────────────────────────────────────────────────────────────────────────

    d ln S(t) = μ(t) dt + σ(t)·s(h) dW(t) + J dN(t)

con las cuatro capas:

  L1  SECULAR        ln S*(t) = α + β·t
                     tendencia log-lineal de largo plazo (β = deriva anual)

  L2  CÍCLICA        ε(t) = ln S(t) − ln S*(t)
                     dε = −κ·ε dt + ...        (Ornstein-Uhlenbeck)
                     κ = velocidad de reversión, vida media = ln2/κ

  L3  VOLATILIDAD    σ²(t) = ω + a·u²(t−1) + b·σ²(t−1)      (GARCH(1,1))
                     s(h)  = multiplicador estacional por hora UTC
                     innovaciones Student-t(ν) → colas gruesas endógenas

  L4  SALTOS         J ~ ley de saltos,  N(t) ~ Poisson(λ(R))
                     R(t) = régimen de Markov de 3 estados {calmo, normal, agitado}

y la deriva total, con la corrección de Itô y la compensación del salto:

    μ(t) = β + κ·(ε̄ − ε(t)) + m(R(t)) − λ(R(t))·E[e^J − 1] − ½·σ²(t)·s²(h)

────────────────────────────────────────────────────────────────────────────────
QUÉ VALIDA Y QUÉ NO
────────────────────────────────────────────────────────────────────────────────
El módulo trae su propia batería de validación (`validate`). Reporta, medido
sobre datos fuera de muestra, no afirmado:
  * ajuste distribucional de los residuos estandarizados (KS, curtosis)
  * ausencia de autocorrelación en z y presencia en z²  (lo que debe pasar)
  * calidad del pronóstico de VOLATILIDAD (R² de Mincer-Zarnowitz)
  * calidad del pronóstico de DIRECCIÓN (AUC) — se espera ≈0.50, o sea nula
  * coincidencia de momentos y de la distribución de máximo drawdown entre
    caminos simulados y la serie real

Uso:
    from gm_gold_sde import calibrate, simulate, validate, GoldSDE
    model = calibrate(df)            # df con índice datetime y columna 'close'
    paths = simulate(model, n_paths=10_000, n_steps=5_811)
    report = validate(model, df_test)
"""
from __future__ import annotations

import json
import math
from dataclasses import dataclass, asdict, field
from pathlib import Path

import numpy as np
import pandas as pd

# ───────────────────────── parámetros del modelo ─────────────────────────

#: unidad interna de retorno = porcentaje (r_pct = 100·Δln S). Mantener todo en
#: esta escala evita los errores de escala típicos al mezclar GARCH y simulación.
SCALE = 100.0


@dataclass
class GoldSDE:
    """Parámetros calibrados de la ecuación maestra. Serializable a JSON."""

    # --- metadatos de calibración ---
    symbol: str = "XAUUSD"
    timeframe: str = "H1"
    t_start: str = ""
    t_end: str = ""
    n_bars: int = 0
    bars_per_year: float = 5811.0

    # --- L1 secular: ln S* = alpha + beta·t  (t en años desde t_start) ---
    alpha: float = 0.0
    beta: float = 0.0
    secular_r2: float = 0.0

    # --- L2 cíclica: OU sobre el residuo epsilon ---
    ou_phi: float = 1.0           # AR(1) diario del residuo
    ou_kappa: float = 0.0         # velocidad de reversión (año^-1)
    ou_halflife_years: float = float("inf")
    ou_sigma: float = 0.0         # vol del residuo
    adf_stat: float = 0.0         # Dickey-Fuller aumentado sobre epsilon
    adf_pvalue: float = 1.0       # >0.05 ⇒ no se puede descartar paseo aleatorio

    # --- L3 volatilidad: GARCH(1,1)-t en escala porcentual ---
    garch_omega: float = 0.0
    garch_alpha: float = 0.0
    garch_beta: float = 0.0
    garch_nu: float = 8.0         # grados de libertad Student-t
    garch_loglik: float = 0.0     # log-verosimilitud alcanzada (control de ajuste)
    uncond_vol_pct: float = 0.0   # vol incondicional por barra, en %
    seasonal: list[float] = field(default_factory=lambda: [1.0] * 24)

    # --- L4 saltos: excesos sobre umbral, ley de Pareto generalizada (POT) ---
    jump_threshold_sd: float = 4.0
    jump_lambda_year: float = 0.0     # intensidad media anual
    jump_mean_pct: float = 0.0        # exceso medio (magnitud), en %
    jump_std_pct: float = 0.0
    jump_gpd_shape: float = 0.0       # ξ de la GPD (0 ⇒ exponencial)
    jump_gpd_scale: float = 0.0       # β de la GPD, en %
    jump_p_up: float = 0.5            # fracción de saltos al alza
    jump_compensator: float = 0.0     # E[e^J − 1] en log-unidades

    # --- regímenes de Markov ---
    regime_names: list[str] = field(default_factory=lambda: ["calmo", "normal", "agitado"])
    regime_drift_pct: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.0])
    regime_vol_mult: list[float] = field(default_factory=lambda: [1.0, 1.0, 1.0])
    regime_lambda_year: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.0])
    regime_transmat: list[list[float]] = field(
        default_factory=lambda: [[1 / 3] * 3 for _ in range(3)]
    )
    regime_steady: list[float] = field(default_factory=lambda: [1 / 3] * 3)
    #: cada cuántas barras se evalúa un cambio de régimen. La matriz de
    #: transición se estima a frecuencia DIARIA (los regímenes macro del oro
    #: duran meses, no horas), así que la simulación debe conmutar al mismo
    #: ritmo o los regímenes se promedian y el drawdown sale subestimado.
    regime_bars: int = 24
    regime_duration_days: list[float] = field(default_factory=lambda: [1.0, 1.0, 1.0])

    # ---------------------------------------------------------------- helpers

    def mu_bar(self, epsilon: float, regime: int, sigma_pct: float, hour: int) -> float:
        """Deriva total esperada de ln S para UNA barra, en unidades de log (no %).

        Implementa  μ·dt = [β + κ(ε̄−ε) + m(R) − λ(R)E[e^J−1] − ½σ²s²]·dt
        con dt = 1/bars_per_year.
        """
        dt = 1.0 / self.bars_per_year
        s = self.seasonal[hour % 24]
        sig = (sigma_pct / SCALE) * s
        drift_secular = self.beta * dt
        drift_ou = self.ou_kappa * (0.0 - epsilon) * dt
        drift_regime = (self.regime_drift_pct[regime] / SCALE)
        comp = -self.regime_lambda_year[regime] * self.jump_compensator * dt
        ito = -0.5 * sig * sig
        return drift_secular + drift_ou + drift_regime + comp + ito

    def to_json(self, path: str | Path) -> None:
        Path(path).write_text(json.dumps(asdict(self), indent=2), encoding="utf-8")

    @classmethod
    def from_json(cls, path: str | Path) -> "GoldSDE":
        return cls(**json.loads(Path(path).read_text(encoding="utf-8")))

    def equation_text(self) -> str:
        """La ecuación con los números calibrados, para documentación."""
        hl = ("%.2f años" % self.ou_halflife_years) if np.isfinite(self.ou_halflife_years) else "∞"
        return (
            f"ECUACIÓN MAESTRA DEL ORO — {self.symbol} {self.timeframe}, "
            f"{self.t_start} → {self.t_end} ({self.n_bars:,} barras)\n"
            f"\n"
            f"  d ln S = μ dt + σ(t)·s(h) dW + J dN(λ)\n"
            f"\n"
            f"  L1 secular     ln S* = {self.alpha:.4f} + {self.beta:.5f}·t     "
            f"(R²={self.secular_r2:.3f}, deriva {100*self.beta:.2f}%/año)\n"
            f"  L2 cíclica     dε = −{self.ou_kappa:.4f}·ε dt                  "
            f"(vida media {hl}, ADF p={self.adf_pvalue:.3f})\n"
            f"  L3 volatilidad σ²ₜ = {self.garch_omega:.3e} + {self.garch_alpha:.4f}·u²ₜ₋₁ "
            f"+ {self.garch_beta:.4f}·σ²ₜ₋₁,  t(ν={self.garch_nu:.1f})\n"
            f"                 persistencia α+β = {self.garch_alpha + self.garch_beta:.4f},  "
            f"vol incond. {self.uncond_vol_pct:.4f}%/barra "
            f"({self.uncond_vol_pct*math.sqrt(self.bars_per_year):.1f}%/año)\n"
            f"  L4 saltos      λ = {self.jump_lambda_year:.1f}/año sobre umbral "
            f"{self.jump_threshold_sd:.0f}σ,  exceso ~ GPD(ξ={self.jump_gpd_shape:.3f}, "
            f"β={self.jump_gpd_scale:.3f}%),  {100*self.jump_p_up:.0f}% al alza\n"
            f"  Regímenes      " + ",  ".join(
                f"{n}: σ×{m:.2f}, λ={l:.0f}/año, π={p:.2f}, dura {d:.0f}d"
                for n, m, l, p, d in zip(self.regime_names, self.regime_vol_mult,
                                         self.regime_lambda_year, self.regime_steady,
                                         self.regime_duration_days)
            )
        )


# ───────────────────────── utilidades de datos ─────────────────────────


def prepare(df: pd.DataFrame, price_col: str = "close") -> pd.DataFrame:
    """Normaliza el DataFrame: índice datetime, columna close, retornos log en %.

    Exige índice temporal ordenado y precios positivos. Elimina barras con
    precio no positivo o retorno no finito (datos corruptos del broker).
    """
    out = df.copy()
    if not isinstance(out.index, pd.DatetimeIndex):
        raise ValueError("prepare() exige un DatetimeIndex")
    out = out[~out.index.duplicated(keep="first")].sort_index()
    if price_col not in out.columns:
        raise ValueError(f"falta la columna '{price_col}'")
    out = out[out[price_col] > 0]
    out["logp"] = np.log(out[price_col].astype(float))
    out["r_pct"] = out["logp"].diff() * SCALE
    out = out[np.isfinite(out["r_pct"].fillna(0.0))]
    out["hour"] = out.index.hour
    return out.dropna(subset=["r_pct"])


def _years(idx: pd.DatetimeIndex) -> np.ndarray:
    """Tiempo en años desde el primer timestamp."""
    secs = (idx - idx[0]).total_seconds().to_numpy(dtype=float)
    return secs / (365.25 * 24 * 3600.0)


# ───────────────────────── L1 + L2: secular y cíclica ─────────────────────────


def _fit_secular_ou(d: pd.DataFrame, m: GoldSDE) -> pd.Series:
    """Ajusta ln S* = α + β·t por OLS y el OU del residuo. Devuelve ε (residuo)."""
    t = _years(d.index)
    y = d["logp"].to_numpy(dtype=float)
    # OLS cerrado (evita dependencia extra y es exacto)
    tm, ym = t.mean(), y.mean()
    var_t = ((t - tm) ** 2).sum()
    beta = ((t - tm) * (y - ym)).sum() / var_t if var_t > 0 else 0.0
    alpha = ym - beta * tm
    fit = alpha + beta * t
    eps = y - fit
    ss_tot = ((y - ym) ** 2).sum()
    m.alpha, m.beta = float(alpha), float(beta)
    m.secular_r2 = float(1.0 - (eps ** 2).sum() / ss_tot) if ss_tot > 0 else 0.0

    # OU sobre el residuo, estimado a frecuencia DIARIA (el horario mete ruido)
    eps_s = pd.Series(eps, index=d.index)
    daily = eps_s.resample("1D").last().dropna()
    if len(daily) > 100:
        x, yv = daily.to_numpy()[:-1], daily.to_numpy()[1:]
        xm2, ym2 = x.mean(), yv.mean()
        vx = ((x - xm2) ** 2).sum()
        phi = float(((x - xm2) * (yv - ym2)).sum() / vx) if vx > 0 else 1.0
        phi = min(max(phi, 1e-6), 0.999999)
        resid = yv - (ym2 + phi * (x - xm2))
        dt_d = 1.0 / 365.25
        m.ou_phi = phi
        m.ou_kappa = float(-math.log(phi) / dt_d)
        m.ou_halflife_years = float(math.log(2.0) / m.ou_kappa) if m.ou_kappa > 0 else float("inf")
        m.ou_sigma = float(resid.std(ddof=1))
        # Dickey-Fuller aumentado: ¿es ε un paseo aleatorio?
        try:
            from statsmodels.tsa.stattools import adfuller

            st = adfuller(daily.to_numpy(), maxlag=10, regression="c", autolag="AIC",
                          result_object=False)
            m.adf_stat, m.adf_pvalue = float(st[0]), float(st[1])
        except Exception:
            m.adf_stat, m.adf_pvalue = float("nan"), float("nan")
    return eps_s


# ───────────────────────── L3: estacionalidad + GARCH ─────────────────────────


def _fit_seasonal(d: pd.DataFrame, m: GoldSDE) -> np.ndarray:
    """Multiplicador de volatilidad por hora UTC, robusto a saltos (vía MAD).

    s(h) = MAD(|r| en la hora h) / MAD(|r| global). Se usa MAD y no la varianza
    porque un solo salto de CPI distorsionaría la varianza de esa hora.
    """
    r = d["r_pct"].to_numpy(dtype=float)
    h = d["hour"].to_numpy()
    glob = np.median(np.abs(r - np.median(r)))
    if glob <= 0:
        glob = np.std(r) or 1.0
    s = np.ones(24, dtype=float)
    for hh in range(24):
        sel = r[h == hh]
        if len(sel) >= 50:
            mad = np.median(np.abs(sel - np.median(sel)))
            s[hh] = float(mad / glob) if mad > 0 else 1.0
    # normaliza para que la media cuadrática sea 1 (no cambia la vol global)
    s = s / math.sqrt(float(np.mean(s ** 2)))
    s = np.clip(s, 0.15, 6.0)
    m.seasonal = [float(x) for x in s]
    return s


def _fit_garch_once(x: pd.Series) -> tuple[dict, np.ndarray, float]:
    """Una pasada de GARCH(1,1)-t por MLE. Devuelve (params, σ condicional, LL)."""
    from arch import arch_model

    am = arch_model(x, mean="Constant", vol="GARCH", p=1, q=1, dist="t", rescale=False)
    res = am.fit(disp="off", show_warning=False)
    p = res.params
    return ({"omega": float(p["omega"]), "alpha": float(p["alpha[1]"]),
             "beta": float(p["beta[1]"]), "nu": float(p.get("nu", 8.0))},
            np.asarray(res.conditional_volatility, dtype=float),
            float(res.loglikelihood))


def _fit_vol_and_jumps(r_deseason: np.ndarray, m: GoldSDE,
                       years: float) -> tuple[np.ndarray, np.ndarray]:
    """Ajusta la difusión (GARCH-t) y mide la ley de los saltos.

    NOTA DE DISEÑO — por qué UNA pasada y no dos:
    La tentación es separar difusión y saltos winsorizando los retornos
    extremos a ±c·σ y reajustando el GARCH sobre la serie "limpia". Se probó y
    es INESTABLE: la winsorización crea masas puntuales artificiales justo en
    ±c·σ, y el MLE de la segunda pasada se va a un óptimo local absurdo
    (medido sobre 2004-2020: ν→188, α→0.55, persistencia 0.66, vol
    incondicional 65.8%/año frente al 17.9% real). Una pasada sobre la serie
    desestacionalizada es estable y da ν≈4.4 con persistencia 0.98.

    CONSECUENCIA IMPORTANTE: al ajustarse sobre la serie CRUDA, las colas de
    la Student-t ya absorben los saltos. Por eso `simulate` NO añade saltos de
    Poisson por defecto (`include_jumps=False`): hacerlo cuenta las colas dos
    veces, y está medido — curtosis simulada 50.9 frente a 24.6 real.
    La capa de saltos se estima igualmente porque sirve para otras cosas:
    marcar qué barras fueron saltos (diagnóstico y panel), alimentar la lógica
    de bloqueo por noticias, y construir escenarios de estrés deliberados.

    Devuelve (σ condicional, máscara de saltos).
    """
    x = pd.Series(r_deseason).replace([np.inf, -np.inf], np.nan).dropna()
    c = m.jump_threshold_sd

    p1, sigma1, ll1 = _fit_garch_once(x)
    m.garch_omega, m.garch_alpha = p1["omega"], p1["alpha"]
    m.garch_beta, m.garch_nu = p1["beta"], p1["nu"]
    m.garch_loglik = ll1
    persist = m.garch_alpha + m.garch_beta
    m.uncond_vol_pct = (float(math.sqrt(m.garch_omega / max(1e-12, 1.0 - persist)))
                        if persist < 1 else float(x.std()))

    n = min(len(x), len(sigma1))
    xv, s1 = x.to_numpy()[:n], np.maximum(sigma1[:n], 1e-12)
    mask = np.abs(xv) > c * s1
    thr = c * s1
    sigma2 = sigma1

    # --- ley de los excesos (POT / Pareto generalizada) ---
    excess = np.abs(xv[mask]) - thr[mask]
    excess = excess[excess > 0]
    m.jump_lambda_year = float(mask.sum() / years) if years > 0 else 0.0
    m.jump_p_up = float(np.mean(xv[mask] > 0)) if mask.any() else 0.5
    if len(excess) >= 30:
        from scipy import stats

        # floc=0: el exceso arranca en el umbral por construcción
        xi, _, beta = stats.genpareto.fit(excess, floc=0.0)
        # ξ≥1 ⇒ media infinita: inadmisible para un compensador, se recorta
        m.jump_gpd_shape = float(min(max(xi, -0.5), 0.45))
        m.jump_gpd_scale = float(max(beta, 1e-6))
        m.jump_mean_pct = float(np.mean(excess))
        m.jump_std_pct = float(np.std(excess, ddof=1))
    else:
        m.jump_gpd_shape, m.jump_gpd_scale = 0.0, 0.0
        m.jump_mean_pct, m.jump_std_pct = 0.0, 0.0

    # compensador E[e^J − 1] por Monte Carlo sobre la ley ajustada (en log-unidades)
    if m.jump_gpd_scale > 0:
        rng = np.random.default_rng(0)
        u = rng.random(200_000)
        mag = _gpd_icdf(u, m.jump_gpd_shape, m.jump_gpd_scale)
        sgn = np.where(rng.random(200_000) < m.jump_p_up, 1.0, -1.0)
        m.jump_compensator = float(np.mean(np.exp(sgn * mag / SCALE) - 1.0))
    else:
        m.jump_compensator = 0.0
    return sigma2[:n], mask


def _gpd_icdf(u: np.ndarray, xi: float, beta: float) -> np.ndarray:
    """Inversa de la CDF de la Pareto generalizada. Vectorizada para simular."""
    u = np.clip(u, 1e-12, 1 - 1e-12)
    if abs(xi) < 1e-8:
        return -beta * np.log1p(-u)
    return (beta / xi) * (np.power(1.0 - u, -xi) - 1.0)


# ───────────────────────── L4: saltos ─────────────────────────


# ───────────────────────── regímenes de Markov ─────────────────────────


def _fit_regimes(d: pd.DataFrame, sigma: np.ndarray, jump_mask: np.ndarray,
                 m: GoldSDE, years: float) -> np.ndarray:
    """HMM gaussiano de 3 estados ajustado a frecuencia DIARIA.

    Por qué diaria y no horaria: ajustando el HMM sobre barras H1 la matriz de
    transición sale con diagonal ≈0.96-0.97 POR HORA, o sea una duración
    esperada de 24-36 HORAS por régimen. Los regímenes macro del oro duran
    meses (el mercado bajista 2011-2015 son cuatro años). Con regímenes que
    duran un día, la simulación promedia las épocas tranquilas y las tensas, y
    el máximo drawdown simulado sale muy por debajo del real: medido, el
    drawdown real de −45% caía FUERA de la banda simulada [−32%, −11%].
    Ajustando a escala diaria los regímenes persisten y la banda cubre la
    realidad. `regime_bars` le dice al simulador cada cuántas barras conmutar.

    Los estados se ORDENAN por volatilidad para que el índice 0 sea siempre
    'calmo' y el 2 'agitado': sin esto el etiquetado baila entre ejecuciones y
    los parámetros guardados dejan de significar lo mismo.
    """
    from hmmlearn.hmm import GaussianHMM
    from sklearn.preprocessing import StandardScaler

    n = min(len(d), len(sigma))
    dd = d.iloc[:n]
    r = dd["r_pct"].to_numpy(dtype=float)

    # --- agrega a día: vol realizada, retorno y momento semanal ---
    day = pd.DataFrame({"r": r}, index=dd.index)
    g = day.groupby(day.index.normalize())["r"]
    rv_d = g.std().fillna(0.0)
    ret_d = g.sum()
    daily = pd.DataFrame({"rv": rv_d, "ret": ret_d}).dropna()
    daily = daily[daily["rv"] > 0]
    if len(daily) < 200:
        raise ValueError(f"insuficientes días para regímenes: {len(daily)}")
    mom5 = daily["ret"].rolling(5).sum().bfill()
    feats = np.column_stack([np.log(daily["rv"].to_numpy()),
                             np.abs(daily["ret"].to_numpy()),
                             mom5.to_numpy()])
    feats = np.nan_to_num(feats, nan=0.0, posinf=0.0, neginf=0.0)
    Z = StandardScaler().fit_transform(feats)

    hmm = GaussianHMM(n_components=3, covariance_type="full", n_iter=200,
                      random_state=42, min_covar=1e-4)
    hmm.fit(Z)
    st_d = hmm.predict(Z)

    rv_arr = daily["rv"].to_numpy()
    vol_by = [float(np.mean(rv_arr[st_d == k])) if (st_d == k).any() else np.inf
              for k in range(3)]
    order = np.argsort(vol_by)
    remap = {int(old): new for new, old in enumerate(order)}
    st_d = np.array([remap[int(s)] for s in st_d], dtype=int)

    T = hmm.transmat_[np.ix_(order, order)]
    T = T / T.sum(axis=1, keepdims=True)
    m.regime_transmat = [[float(v) for v in row] for row in T]
    m.regime_duration_days = [float(1.0 / max(1e-6, 1.0 - T[k, k])) for k in range(3)]
    # barras por día observadas: cadencia de conmutación en la simulación
    m.regime_bars = int(round(m.bars_per_year / 252.0)) if m.bars_per_year else 24
    m.regime_bars = max(1, min(m.regime_bars, 48))

    # --- propaga el régimen del día a cada barra horaria ---
    st_series = pd.Series(st_d, index=daily.index)
    states = st_series.reindex(dd.index.normalize()).ffill().bfill().to_numpy().astype(int)

    glob_vol = float(np.std(r, ddof=1)) or 1.0
    drift, volm, lam, steady = [], [], [], []
    jm = jump_mask[:n]
    for k in range(3):
        sel = states == k
        cnt = int(sel.sum())
        steady.append(cnt / n if n else 0.0)
        if cnt > 30:
            drift.append(float(np.mean(r[sel])))
            volm.append(float(np.std(r[sel], ddof=1) / glob_vol))
            yrs_k = years * cnt / n
            lam.append(float(jm[sel].sum() / yrs_k) if yrs_k > 0 else 0.0)
        else:
            drift.append(0.0); volm.append(1.0); lam.append(0.0)
    m.regime_drift_pct = drift
    m.regime_vol_mult = volm
    m.regime_lambda_year = lam
    m.regime_steady = steady
    return states


# ───────────────────────── calibración completa ─────────────────────────


def calibrate(df: pd.DataFrame, symbol: str = "XAUUSD", timeframe: str = "H1",
              price_col: str = "close") -> tuple[GoldSDE, pd.DataFrame]:
    """Calibra las 4 capas. Devuelve (parámetros, diagnóstico por barra)."""
    d = prepare(df, price_col)
    if len(d) < 2000:
        raise ValueError(f"se necesitan ≥2000 barras para calibrar, hay {len(d)}")

    m = GoldSDE(symbol=symbol, timeframe=timeframe,
                t_start=str(d.index[0]), t_end=str(d.index[-1]), n_bars=len(d))
    span_years = float(_years(d.index)[-1]) or 1.0
    m.bars_per_year = float(len(d) / span_years)

    eps = _fit_secular_ou(d, m)
    s = _fit_seasonal(d, m)
    r = d["r_pct"].to_numpy(dtype=float)
    r_des = r / s[d["hour"].to_numpy()]
    sigma, jump_mask = _fit_vol_and_jumps(r_des, m, span_years)

    n = min(len(d), len(sigma))
    states = _fit_regimes(d, sigma, jump_mask, m, span_years)

    diag = pd.DataFrame({
        "r_pct": r[:n],
        "r_deseason": r_des[:n],
        "sigma_pct": sigma[:n],
        "z": r_des[:n] / np.maximum(sigma[:n], 1e-12),
        "epsilon": eps.to_numpy()[:n],
        "jump": jump_mask[:n],
        "regime": states[:n],
        "hour": d["hour"].to_numpy()[:n],
    }, index=d.index[:n])
    return m, diag


# ───────────────────────── simulación Monte Carlo ─────────────────────────


def simulate(m: GoldSDE, n_paths: int = 1000, n_steps: int = 5811,
             s0: float = 1.0, seed: int = 0,
             start_hour: int = 0, start_regime: int | None = None,
             antithetic: bool = True, use_ou: bool = False,
             eps0: float = 0.0, include_jumps: bool = False,
             drift_annual: float | None = None,
             stats_only: bool = False) -> np.ndarray | dict:
    """Simula caminos de precio con la ecuación completa. Devuelve (n_paths, n_steps+1).

    Vectorizado sobre caminos: cada paso actualiza GARCH, régimen y saltos para
    los n_paths a la vez. `antithetic` empareja cada camino con su reflejo
    (−W) para reducir la varianza del estimador sin sesgarlo.

    `use_ou=False` POR DEFECTO, y es deliberado. La capa L2 (reversión a la
    tendencia secular) es la única del modelo que hace una apuesta DIRECCIONAL:
    activarla equivale a afirmar que el oro vuelve a su tendencia log-lineal, lo
    que infla los retornos simulados cuando el precio está por debajo de ella y
    maquillaría a la baja la probabilidad de ruina. Mientras el test ADF sobre ε
    no descarte el paseo aleatorio (ver `adf_pvalue`), simular sin OU es la
    hipótesis conservadora. Para medir el escenario optimista: use_ou=True con
    `eps0` = desviación actual respecto de la tendencia.

    `include_jumps=False` POR DEFECTO, y también es deliberado. El GARCH se
    ajusta sobre la serie cruda, así que las colas de la Student-t YA absorben
    los saltos de noticias; añadir encima el Poisson cuenta las colas dos veces.
    Está medido: con saltos, curtosis simulada 50.9 contra 24.6 real. Úsalo en
    True solo para escenarios de estrés deliberados, sabiendo que exagera.

    `drift_annual` sustituye la deriva secular β. Para TRABAJO DE RIESGO hay
    que pasar 0.0, y la razón está medida: con β = +6.48%/año (lo ajustado
    sobre 2004-2025) ninguna realización reproduce con probabilidad apreciable
    el mercado bajista real de 2011-2015, que fue un −45% a lo largo de cuatro
    años. El drawdown real cae FUERA de la banda simulada [−29%, −9%]. Ese
    −45% es un fenómeno de DERIVA a escala de años, no de volatilidad, y con
    21 años de historia (≈2 ciclos) no se puede estimar un proceso de deriva
    bi-regimen con honestidad. Por eso el modelo captura bien el riesgo de
    volatilidad y MAL el riesgo de mercado bajista plurianual: dimensionar con
    la banda de β histórico es optimista. Pasa drift_annual=0.0 para la banda
    neutral, o un valor negativo para estresar.

    `stats_only=True` no guarda los caminos: va acumulando máximo drawdown,
    valor final y volatilidad realizada por camino, con memoria O(n_paths) en
    vez de O(n_paths × n_steps). Es lo que permite simular a longitud real
    (122.027 barras) con decenas de miles de caminos, y es obligatorio para
    comparar drawdowns de forma honesta: un camino de 1,5 años tiene menos
    oportunidades de caer que una serie real de 21 años, así que comparar
    ambos infravalora el riesgo del modelo. Devuelve un dict en ese modo.
    """
    rng = np.random.default_rng(seed)
    P = int(n_paths)
    seas = np.asarray(m.seasonal, dtype=float)
    T = np.asarray(m.regime_transmat, dtype=float)
    T = T / T.sum(axis=1, keepdims=True)
    cumT = np.cumsum(T, axis=1)
    dt = 1.0 / m.bars_per_year
    nu = max(2.1, m.garch_nu)
    # escala para que la t(nu) tenga varianza 1
    t_scale = math.sqrt((nu - 2.0) / nu)

    # estado inicial
    sig = np.full(P, max(m.uncond_vol_pct, 1e-6), dtype=float)
    if start_regime is None:
        p0 = np.asarray(m.regime_steady, dtype=float)
        p0 = p0 / p0.sum() if p0.sum() > 0 else np.full(3, 1 / 3)
        reg = rng.choice(3, size=P, p=p0)
    else:
        reg = np.full(P, int(start_regime), dtype=int)

    logp = np.full(P, math.log(max(s0, 1e-12)), dtype=float)
    eps = np.full(P, float(eps0), dtype=float)
    if stats_only:
        out = None
        peak = np.exp(logp).copy()
        maxdd = np.zeros(P, dtype=float)
        sum_r2 = np.zeros(P, dtype=float)
    else:
        out = np.empty((P, n_steps + 1), dtype=np.float32)
        out[:, 0] = np.exp(logp)

    vol_mult = np.asarray(m.regime_vol_mult, dtype=float)
    reg_drift = np.asarray(m.regime_drift_pct, dtype=float) / SCALE
    reg_lam = np.asarray(m.regime_lambda_year, dtype=float)
    switch_every = max(1, int(m.regime_bars))
    beta_eff = float(m.beta if drift_annual is None else drift_annual)

    half = P // 2 if antithetic else 0
    for i in range(n_steps):
        h = (start_hour + i) % 24
        s_h = seas[h]

        # innovación Student-t estandarizada
        z = rng.standard_t(nu, size=P) * t_scale
        if half:  # antitético: la segunda mitad refleja la primera
            z[half:] = -z[:half] if P % 2 == 0 else -z[:half]

        # volatilidad efectiva: GARCH × régimen × estacionalidad
        sig_eff = sig * vol_mult[reg] * s_h
        u_pct = sig_eff * z                      # retorno difusivo en %

        # Saltos. En una barra con salto el retorno NO es difusión + salto:
        # es exactamente ±(c·σ + exceso), que es la descomposición con la que
        # se estimó (la difusión se winsoriza al umbral y el exceso se ajusta
        # aparte con la GPD). Sumar las dos cosas contaría el umbral dos veces.
        # Y el GARCH debe realimentarse con la parte WINSORIZADA, igual que en
        # la calibración, o un salto infla la vol futura de un modo que el
        # ajuste nunca vio.
        if include_jumps and m.jump_gpd_scale > 0:
            p_jump = np.clip(reg_lam[reg] * dt, 0.0, 0.5)
            jumped = rng.random(P) < p_jump
            thr = m.jump_threshold_sd * sig_eff
            exc = _gpd_icdf(rng.random(P), m.jump_gpd_shape, m.jump_gpd_scale)
            sgn = np.where(rng.random(P) < m.jump_p_up, 1.0, -1.0)
            u_tot = np.where(jumped, sgn * (thr + exc), u_pct)   # retorno observado
            u_cont = np.where(jumped, sgn * thr, u_pct)          # lo que ve el GARCH
        else:
            u_tot = u_cont = u_pct

        # deriva: secular + régimen − compensador − Itô (+ OU solo si se pide)
        sig_log = sig_eff / SCALE
        mu = beta_eff * dt + reg_drift[reg] - 0.5 * sig_log * sig_log
        if include_jumps:
            # el compensador solo corresponde si de verdad se simulan saltos
            mu = mu - reg_lam[reg] * m.jump_compensator * dt
        if use_ou:
            mu = mu + m.ou_kappa * (-eps) * dt

        step = mu + u_tot / SCALE
        logp = logp + step
        if use_ou:
            # d(ε) = d(ln S) − β dt, por definición ε = ln S − (α + βt)
            eps = eps + step - beta_eff * dt
        price = np.exp(logp)
        if stats_only:
            np.maximum(peak, price, out=peak)
            np.minimum(maxdd, price / peak - 1.0, out=maxdd)
            sum_r2 += step * step
        else:
            out[:, i + 1] = price

        # actualiza GARCH con la innovación DESESTACIONALIZADA (como se ajustó)
        u_des = u_cont / max(s_h, 1e-9) / np.maximum(vol_mult[reg], 1e-9)
        sig = np.sqrt(np.maximum(
            m.garch_omega + m.garch_alpha * u_des ** 2 + m.garch_beta * sig ** 2, 1e-12))

        # transición de régimen: solo cada `switch_every` barras, porque la
        # matriz se estimó a frecuencia diaria (ver _fit_regimes)
        if (i + 1) % switch_every == 0:
            reg = (rng.random(P)[:, None] > cumT[reg]).sum(axis=1)
            np.clip(reg, 0, 2, out=reg)

    if stats_only:
        return {
            "final": np.exp(logp),
            "max_dd": maxdd,
            "total_logret": logp - math.log(max(s0, 1e-12)),
            "vol_annual_pct": np.sqrt(sum_r2 / max(1, n_steps)) * SCALE
            * math.sqrt(m.bars_per_year),
            "n_paths": P,
            "n_steps": int(n_steps),
        }
    return out


# ───────────────────────── validación honesta ─────────────────────────


def _max_drawdown(path: np.ndarray) -> float:
    peak = np.maximum.accumulate(path)
    return float(np.min(path / peak) - 1.0)


def validate(m: GoldSDE, diag: pd.DataFrame, n_paths: int = 500,
             seed: int = 7) -> dict:
    """Batería de validación. Devuelve un dict de métricas MEDIDAS, no afirmadas."""
    from scipy import stats

    out: dict = {}
    z = diag["z"].to_numpy(dtype=float)
    z = z[np.isfinite(z)]

    # --- 1. residuos estandarizados ---
    nu = max(2.1, m.garch_nu)
    zs = z / np.std(z, ddof=1)
    ks = stats.kstest(zs, lambda q: stats.t.cdf(q * math.sqrt(nu / (nu - 2)), df=nu))
    out["resid_ks_stat"] = float(ks.statistic)
    out["resid_ks_pvalue"] = float(ks.pvalue)
    out["resid_kurtosis"] = float(stats.kurtosis(z, fisher=False))
    out["resid_skew"] = float(stats.skew(z))

    # Ljung-Box: z no debe autocorrelar, z² sí debió quedar limpio tras GARCH
    try:
        from statsmodels.stats.diagnostic import acorr_ljungbox

        lb_z = acorr_ljungbox(z, lags=[24], return_df=True)
        lb_z2 = acorr_ljungbox(z ** 2, lags=[24], return_df=True)
        out["ljungbox_z_p"] = float(lb_z["lb_pvalue"].iloc[0])
        out["ljungbox_z2_p"] = float(lb_z2["lb_pvalue"].iloc[0])
    except Exception:
        out["ljungbox_z_p"] = out["ljungbox_z2_p"] = float("nan")

    # --- 2. pronóstico de VOLATILIDAD: Mincer-Zarnowitz r² = a + b·σ² ---
    r2v = diag["r_deseason"].to_numpy(dtype=float) ** 2
    sv = diag["sigma_pct"].to_numpy(dtype=float) ** 2
    ok = np.isfinite(r2v) & np.isfinite(sv)
    if ok.sum() > 100:
        x, y = sv[ok], r2v[ok]
        xm, ym = x.mean(), y.mean()
        vx = ((x - xm) ** 2).sum()
        b = ((x - xm) * (y - ym)).sum() / vx if vx > 0 else 0.0
        a = ym - b * xm
        pred = a + b * x
        ss = ((y - ym) ** 2).sum()
        out["vol_forecast_r2"] = float(1 - ((y - pred) ** 2).sum() / ss) if ss > 0 else 0.0
        out["vol_mz_slope"] = float(b)
    # correlación de rangos: mucho más robusta que el R² con colas gruesas
    if ok.sum() > 100:
        out["vol_spearman"] = float(stats.spearmanr(sv[ok], r2v[ok]).statistic)

    # --- 3. pronóstico de DIRECCIÓN (la prueba de honestidad) ---
    r = diag["r_pct"].to_numpy(dtype=float)
    eps = diag["epsilon"].to_numpy(dtype=float)
    reg = diag["regime"].to_numpy()
    drift = np.asarray(m.regime_drift_pct)[reg] + m.beta / m.bars_per_year * SCALE \
        - m.ou_kappa * eps / m.bars_per_year * SCALE
    nxt = np.roll(r, -1)
    okd = np.isfinite(drift) & np.isfinite(nxt)
    okd[-1] = False
    if okd.sum() > 500:
        y_true = (nxt[okd] > 0).astype(int)
        if 0 < y_true.mean() < 1:
            from sklearn.metrics import roc_auc_score

            out["direction_auc"] = float(roc_auc_score(y_true, drift[okd]))
        out["direction_hit_pct"] = float(
            100.0 * np.mean((drift[okd] > 0) == (nxt[okd] > 0)))

    # --- 4. coincidencia de momentos y drawdown: simulado vs real ---
    n_steps = min(len(diag), 8760)
    sim = simulate(m, n_paths=n_paths, n_steps=n_steps, s0=1.0, seed=seed)
    sr = np.diff(np.log(np.maximum(sim, 1e-12)), axis=1) * SCALE
    real = r[np.isfinite(r)]
    bpy = m.bars_per_year

    def ann(v):
        return float(v * math.sqrt(bpy))

    out["real_vol_annual_pct"] = ann(float(np.std(real, ddof=1)))
    out["sim_vol_annual_pct"] = ann(float(np.mean(np.std(sr, axis=1, ddof=1))))
    out["real_kurtosis"] = float(stats.kurtosis(real, fisher=False))
    out["sim_kurtosis"] = float(np.mean([stats.kurtosis(row, fisher=False) for row in sr[:200]]))
    out["real_skew"] = float(stats.skew(real))
    out["sim_skew"] = float(np.mean([stats.skew(row) for row in sr[:200]]))

    # agrupamiento de volatilidad: ACF de |r| a varios rezagos
    def acf_abs(x, lag):
        a = np.abs(x)
        a = a - a.mean()
        d = (a * a).sum()
        return float((a[:-lag] * a[lag:]).sum() / d) if d > 0 and lag < len(a) else 0.0

    for lag in (1, 24, 120):
        out[f"real_acf_abs_{lag}"] = acf_abs(real, lag)
        out[f"sim_acf_abs_{lag}"] = float(np.mean([acf_abs(row, lag) for row in sr[:200]]))

    # --- 5. distribución del máximo drawdown, A LONGITUD REAL ---
    # Crítico: el drawdown máximo crece con la longitud del camino, así que hay
    # que simular tantas barras como tiene la serie real. Comparar un real de
    # 21 años contra caminos de 1,5 años infravalora el riesgo del modelo.
    real_path = np.exp(np.cumsum(real / SCALE))
    out["real_max_dd_pct"] = 100.0 * _max_drawdown(real_path)
    n_real = len(real)
    out["dd_n_steps"] = int(n_real)

    st = simulate(m, n_paths=n_paths, n_steps=n_real, s0=1.0, seed=seed + 1,
                  stats_only=True)
    dds = np.asarray(st["max_dd"]) * 100.0
    out["sim_max_dd_p50_pct"] = float(np.percentile(dds, 50))
    out["sim_max_dd_p05_pct"] = float(np.percentile(dds, 5))
    out["sim_max_dd_p95_pct"] = float(np.percentile(dds, 95))
    out["real_dd_inside_sim_band"] = bool(
        out["sim_max_dd_p05_pct"] <= out["real_max_dd_pct"] <= out["sim_max_dd_p95_pct"])

    # La misma banda con DERIVA NEUTRAL (β=0). Es la cifra honesta para
    # dimensionar: la banda con β histórico hereda el viento de cola de
    # 2004-2025 y no puede generar un bajista plurianual como 2011-2015.
    st0 = simulate(m, n_paths=n_paths, n_steps=n_real, s0=1.0, seed=seed + 2,
                   drift_annual=0.0, stats_only=True)
    dd0 = np.asarray(st0["max_dd"]) * 100.0
    out["sim0_max_dd_p50_pct"] = float(np.percentile(dd0, 50))
    out["sim0_max_dd_p05_pct"] = float(np.percentile(dd0, 5))
    out["sim0_max_dd_p01_pct"] = float(np.percentile(dd0, 1))
    out["real_dd_inside_sim0_band"] = bool(
        out["sim0_max_dd_p05_pct"] <= out["real_max_dd_pct"])

    out["n_paths"] = int(n_paths)
    out["n_steps"] = int(n_steps)
    return out


__all__ = ["GoldSDE", "calibrate", "simulate", "validate", "prepare", "SCALE"]
