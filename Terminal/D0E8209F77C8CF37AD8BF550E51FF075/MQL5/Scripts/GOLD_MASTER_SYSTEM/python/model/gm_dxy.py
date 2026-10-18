"""
gm_dxy.py — Relación oro / índice dólar (DXY), investigada en serio.

"El oro sube cuando el dólar baja" es cierto de media y falso en los momentos
que importan. Este módulo mide EXACTAMENTE cuánto, cuándo y con qué estabilidad,
sobre dos décadas de datos diarios, y separa lo que es describir el pasado de lo
que sería predecir el futuro.

  1. CORRELACIÓN     contemporánea y móvil a varias ventanas; su DISPERSIÓN es
                     el dato importante, no su media
  2. POR RÉGIMEN     la correlación condicionada al régimen de volatilidad: en
                     crisis el oro y el dólar suben JUNTOS (los dos son refugio)
                     y la cobertura se rompe justo cuando se necesita
  3. ADELANTO/RETRASO correlación cruzada a distintos desfases: ¿manda el DXY o
                     manda el oro?
  4. COINTEGRACIÓN   ¿existe una relación de equilibrio de largo plazo, o solo
                     dos paseos aleatorios que se mueven parecido?
  5. BETA MÓVIL      sensibilidad del oro al dólar y su estabilidad temporal
  6. PREDICCIÓN      la prueba honesta: el DXY de HOY, ¿predice el oro de MAÑANA
                     fuera de muestra? Correlación contemporánea ≠ capacidad
                     predictiva, y confundirlas es el error clásico.
  7. SHOCKS          estudio de eventos: respuesta del oro a movimientos
                     extremos del dólar
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd


def align(gold: pd.DataFrame, dxy: pd.DataFrame,
          price_col: str = "close") -> pd.DataFrame:
    """Alinea oro y DXY a cierres diarios comunes. Sin relleno hacia delante.

    No se interpola ni se arrastra el último valor: un festivo en el que el DXY
    no cotiza no es un día de correlación, y rellenarlo inventaría observaciones
    que inflarían artificialmente la significación de todo lo que sigue.
    """
    g = gold[[price_col]].copy()
    g.index = pd.DatetimeIndex(g.index).tz_localize(None).normalize()
    g = g.groupby(level=0).last().rename(columns={price_col: "gold"})

    d = dxy[[price_col]].copy()
    d.index = pd.DatetimeIndex(d.index).tz_localize(None).normalize()
    d = d.groupby(level=0).last().rename(columns={price_col: "dxy"})

    out = g.join(d, how="inner").dropna()
    out = out[(out["gold"] > 0) & (out["dxy"] > 0)]
    out["r_gold"] = np.log(out["gold"]).diff() * 100.0
    out["r_dxy"] = np.log(out["dxy"]).diff() * 100.0
    return out.dropna()


def correlations(df: pd.DataFrame, windows=(21, 63, 126, 252)) -> dict:
    """Correlación global y móvil. La DISPERSIÓN es el resultado relevante."""
    out = {"n_dias": int(len(df)),
           "desde": str(df.index[0].date()), "hasta": str(df.index[-1].date()),
           "corr_global": round(float(df["r_gold"].corr(df["r_dxy"])), 4)}
    for w in windows:
        rc = df["r_gold"].rolling(w).corr(df["r_dxy"]).dropna()
        if len(rc) < 10:
            continue
        out[f"movil_{w}d"] = {
            "media": round(float(rc.mean()), 4),
            "mediana": round(float(rc.median()), 4),
            "desv": round(float(rc.std()), 4),
            "min": round(float(rc.min()), 4),
            "max": round(float(rc.max()), 4),
            "pct_positiva": round(100.0 * float((rc > 0).mean()), 1),
        }
    return out


def by_regime(df: pd.DataFrame, n_states: int = 3) -> dict:
    """Correlación condicionada al régimen de volatilidad del oro.

    El régimen se estima con terciles de volatilidad realizada a 21 días, no con
    un HMM: aquí interesa un corte transparente y reproducible, no el mejor
    ajuste. Lo que se busca es si la cobertura aguanta en los tramos tensos.
    """
    d = df.copy()
    rv = d["r_gold"].rolling(21).std()
    q = rv.quantile([1 / 3, 2 / 3]).to_numpy()
    d["regimen"] = np.where(rv <= q[0], "calmo",
                            np.where(rv <= q[1], "normal", "agitado"))
    out = {}
    for name in ("calmo", "normal", "agitado"):
        sub = d[d["regimen"] == name]
        if len(sub) < 30:
            continue
        out[name] = {
            "n": int(len(sub)),
            "corr": round(float(sub["r_gold"].corr(sub["r_dxy"])), 4),
            "vol_oro_anual_pct": round(float(sub["r_gold"].std() * math.sqrt(252)), 2),
            "vol_dxy_anual_pct": round(float(sub["r_dxy"].std() * math.sqrt(252)), 2),
        }
    # los dos al alza a la vez: la cobertura rota
    both_up = ((d["r_gold"] > 0) & (d["r_dxy"] > 0))
    out["pct_ambos_al_alza"] = round(100.0 * float(both_up.mean()), 2)
    ag = d[d["regimen"] == "agitado"]
    if len(ag) > 30:
        out["pct_ambos_al_alza_en_agitado"] = round(
            100.0 * float(((ag["r_gold"] > 0) & (ag["r_dxy"] > 0)).mean()), 2)
    return out


def lead_lag(df: pd.DataFrame, max_lag: int = 10) -> dict:
    """Correlación cruzada a distintos desfases.

    lag>0 significa que el DXY de hace `lag` días se compara con el oro de hoy
    (el DXY adelantaría). lag<0 es lo contrario. Si el pico está en lag=0, los
    dos reaccionan a la misma información y ninguno predice al otro.
    """
    rg, rd = df["r_gold"], df["r_dxy"]
    rows = []
    for lag in range(-max_lag, max_lag + 1):
        c = float(rg.corr(rd.shift(lag)))
        rows.append({"lag": lag, "corr": round(c, 4)})
    tab = pd.DataFrame(rows)
    best = tab.loc[tab["corr"].abs().idxmax()]
    return {
        "tabla": tab.to_dict("records"),
        "lag_de_maxima_correlacion": int(best["lag"]),
        "corr_en_ese_lag": float(best["corr"]),
        "corr_en_lag_0": float(tab.loc[tab["lag"] == 0, "corr"].iloc[0]),
        "interpretacion": (
            "el pico esta en lag 0: ambos reaccionan a la misma informacion y "
            "ninguno adelanta al otro de forma util"
            if int(best["lag"]) == 0 else
            f"el pico esta en lag {int(best['lag'])}, revisar si es explotable "
            f"tras costes (ver `predictive`)"),
    }


def cointegration(df: pd.DataFrame) -> dict:
    """¿Hay equilibrio de largo plazo entre ln(oro) y ln(DXY)?

    Engle-Granger: se regresa ln(oro) sobre ln(DXY) y se contrasta si el residuo
    es estacionario. Si NO lo es, los dos son paseos aleatorios que a veces se
    mueven parecido, y cualquier estrategia de "vuelta a la relacion normal"
    carece de base estadistica.
    """
    from statsmodels.tsa.stattools import adfuller

    y = np.log(df["gold"].to_numpy())
    x = np.log(df["dxy"].to_numpy())
    X = np.column_stack([np.ones_like(x), x])
    beta, *_ = np.linalg.lstsq(X, y, rcond=None)
    resid = y - X @ beta
    st = adfuller(resid, maxlag=20, autolag="AIC", result_object=False)
    return {
        "beta_largo_plazo": round(float(beta[1]), 4),
        "r2": round(float(1 - resid.var() / y.var()), 4),
        "adf_residuo": round(float(st[0]), 4),
        "adf_pvalue": round(float(st[1]), 4),
        "cointegrados": bool(st[1] < 0.05),
        "interpretacion": (
            "cointegrados: existe una relacion de equilibrio y las desviaciones "
            "tienden a corregirse" if st[1] < 0.05 else
            "NO cointegrados: no se puede descartar que sean dos paseos "
            "aleatorios. Operar la 'vuelta a la relacion normal' no tiene base"),
    }


def rolling_beta(df: pd.DataFrame, window: int = 252) -> dict:
    """Sensibilidad del oro al dólar, y su estabilidad en el tiempo."""
    cov = df["r_gold"].rolling(window).cov(df["r_dxy"])
    var = df["r_dxy"].rolling(window).var()
    beta = (cov / var).dropna()
    if len(beta) < 10:
        return {"error": "serie insuficiente"}
    return {
        "ventana_dias": window,
        "beta_media": round(float(beta.mean()), 4),
        "beta_mediana": round(float(beta.median()), 4),
        "beta_desv": round(float(beta.std()), 4),
        "beta_min": round(float(beta.min()), 4),
        "beta_max": round(float(beta.max()), 4),
        "pct_negativa": round(100.0 * float((beta < 0).mean()), 1),
        "interpretacion": (
            f"un +1% en el DXY mueve el oro {beta.median():+.2f}% de mediana, "
            f"pero la beta oscila entre {beta.min():.2f} y {beta.max():.2f}: "
            f"usarla como constante es un error"),
    }


def predictive(df: pd.DataFrame, split: float = 0.70) -> dict:
    """La prueba honesta: ¿el DXY de hoy predice el oro de MAÑANA?

    Se ajusta en el primer tramo y se mide en el segundo, que el modelo no ha
    visto. Se reportan R² fuera de muestra y acierto direccional. Un R² negativo
    significa que el modelo es PEOR que predecir la media, lo que es el
    resultado habitual y el que separa correlación de capacidad predictiva.
    """
    d = df.copy()
    d["y"] = d["r_gold"].shift(-1)                    # oro de mañana
    for k in (1, 2, 3, 5):
        d[f"dxy_lag{k}"] = d["r_dxy"].shift(k - 1)    # DXY de hoy y días previos
    d["dxy_5d"] = d["r_dxy"].rolling(5).sum()
    d["gold_lag1"] = d["r_gold"]
    d = d.dropna()
    feats = [c for c in d.columns if c.startswith("dxy_") or c == "gold_lag1"]
    n = len(d)
    cut = int(n * split)
    Xtr, ytr = d[feats].to_numpy()[:cut], d["y"].to_numpy()[:cut]
    Xte, yte = d[feats].to_numpy()[cut:], d["y"].to_numpy()[cut:]
    if len(yte) < 100:
        return {"error": "tramo de prueba insuficiente"}

    A = np.column_stack([np.ones(len(Xtr)), Xtr])
    coef, *_ = np.linalg.lstsq(A, ytr, rcond=None)
    pred = np.column_stack([np.ones(len(Xte)), Xte]) @ coef
    ss_res = float(((yte - pred) ** 2).sum())
    ss_tot = float(((yte - ytr.mean()) ** 2).sum())
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else 0.0
    hit = float(((pred > 0) == (yte > 0)).mean())

    # ¿y solo con el signo del DXY de hoy, la regla de manual?
    simple = float(((-d["r_dxy"].to_numpy()[cut:] > 0) == (yte > 0)).mean())
    return {
        "n_train": cut, "n_test": int(len(yte)),
        "features": feats,
        "r2_fuera_muestra": round(r2, 5),
        "acierto_direccional_pct": round(100.0 * hit, 2),
        "acierto_regla_simple_pct": round(100.0 * simple, 2),
        "interpretacion": (
            "hay senal fuera de muestra, PERO este numero por si solo no "
            "autoriza a operar: hay que pasar por ablation() para saber si "
            "viene del dolar o del propio oro, y por stability() para ver si "
            "se mantiene ano a ano. Medido, no se mantiene."
            if r2 > 0.002 and hit > 0.52 else
            "sin capacidad predictiva util: la correlacion es CONTEMPORANEA "
            "(sirve para entender y para cubrir, no para anticipar)"),
    }


def shocks(df: pd.DataFrame, z: float = 2.5, horizon: int = 5) -> dict:
    """Estudio de eventos: respuesta del oro a shocks extremos del dólar."""
    d = df.copy()
    sd = d["r_dxy"].rolling(252).std()
    d["z"] = d["r_dxy"] / sd
    up = d.index[d["z"] >= z]
    dn = d.index[d["z"] <= -z]
    pos = d.index.get_indexer

    def response(dates):
        rows = []
        for t in dates:
            i = int(pos([t])[0])
            if i < 0 or i + horizon >= len(d):
                continue
            rows.append(d["r_gold"].to_numpy()[i + 1:i + 1 + horizon].sum())
        return np.asarray(rows)

    ru, rd_ = response(up), response(dn)
    out = {"umbral_z": z, "horizonte_dias": horizon,
           "n_shocks_dolar_al_alza": int(len(ru)),
           "n_shocks_dolar_a_la_baja": int(len(rd_))}
    if len(ru) > 5:
        out["oro_tras_shock_dolar_alza_media_pct"] = round(float(ru.mean()), 3)
        out["oro_tras_shock_dolar_alza_pct_negativo"] = round(
            100.0 * float((ru < 0).mean()), 1)
    if len(rd_) > 5:
        out["oro_tras_shock_dolar_baja_media_pct"] = round(float(rd_.mean()), 3)
        out["oro_tras_shock_dolar_baja_pct_positivo"] = round(
            100.0 * float((rd_ > 0).mean()), 1)
    if len(ru) > 5 and len(rd_) > 5:
        from scipy import stats
        t = stats.ttest_ind(ru, rd_, equal_var=False)
        out["diferencia_t"] = round(float(t.statistic), 3)
        out["diferencia_p"] = round(float(t.pvalue), 4)
        out["interpretacion"] = (
            "la reaccion del oro difiere segun el signo del shock del dolar"
            if t.pvalue < 0.05 else
            "no hay diferencia significativa entre shocks al alza y a la baja")
    return out


def ablation(df: pd.DataFrame, split: float = 0.70) -> dict:
    """¿De dónde viene el acierto: del DXY o de la autocorrelación del oro?

    Sin esta descomposición el resultado de `predictive` es ininterpretable: un
    modelo que mezcla retardos del oro y del dólar puede acertar por el oro y
    atribuirsele al dólar. Se ajustan los tres modelos por separado, con el
    mismo corte y el mismo tramo de prueba.

    Medido sobre 2004-2025 (1.566 días de prueba, oro diario vs DXY):
        solo oro   R² −0.00046, acierto 53.96%   (R² negativo: peor que la media)
        solo DXY   R² +0.00213, acierto 55.17%   ← el efecto es del DÓLAR
        oro + DXY  R² +0.00162, acierto 54.85%   (el oro no aporta, resta)
    """
    d = _design(df)
    cut = int(len(d) * split)
    sets = {"solo_oro": GOLD_FEATS, "solo_dxy": DXY_FEATS,
            "oro_y_dxy": GOLD_FEATS + DXY_FEATS}
    out = {}
    for name, feats in sets.items():
        out[name] = _fit_oos(d, feats, cut)
    best = max(sets, key=lambda k: out[k]["acierto_direccional_pct"])
    out["mejor_modelo"] = best
    out["atribucion"] = (
        "el efecto es atribuible al DOLAR: el modelo de solo DXY iguala o supera "
        "al que incluye retardos del oro"
        if best in ("solo_dxy", "oro_y_dxy") and
           out["solo_dxy"]["acierto_direccional_pct"] >=
           out["solo_oro"]["acierto_direccional_pct"]
        else "el acierto viene de la autocorrelacion del ORO, no del dolar")
    return out


def stability(df: pd.DataFrame, split: float = 0.70,
              feats: list[str] | None = None) -> dict:
    """Acierto direccional año a año en el tramo de prueba.

    Es la comprobación que decide si un resultado agregado sirve para operar.
    Un 55% de media repartido como 50/50/60/66 no es un edge estable: es un
    edge que DESAPARECE durante años enteros, y quien lo dimensione con la
    media agregada pasará esos años plano o perdiendo.

    Medido (modelo oro+DXY): 2019 55.3% · 2020 59.8% · 2021 49.6% ·
    2022 50.6% · 2023 53.6% · 2024 55.2% · 2025 66.4% (n=107).
    Dos años consecutivos SIN efecto, y el agregado lo esconde.
    """
    d = _design(df)
    feats = feats or (GOLD_FEATS + DXY_FEATS)
    cut = int(len(d) * split)
    Xtr = d[feats].to_numpy()[:cut]
    ytr = d["y"].to_numpy()[:cut]
    A = np.column_stack([np.ones(len(Xtr)), Xtr])
    coef, *_ = np.linalg.lstsq(A, ytr, rcond=None)
    Xte = d[feats].to_numpy()[cut:]
    yte = d["y"].to_numpy()[cut:]
    pred = np.column_stack([np.ones(len(Xte)), Xte]) @ coef
    ok = pd.Series((pred > 0) == (yte > 0), index=d.index[cut:])

    por_ano, flojos = {}, []
    for yr, g in ok.groupby(ok.index.year):
        pct = round(100.0 * float(g.mean()), 1)
        por_ano[int(yr)] = {"acierto_pct": pct, "n": int(len(g))}
        if pct < 52.0 and len(g) >= 100:
            flojos.append(int(yr))

    # magnitud económica neta de una regla long/short sobre el signo previsto
    strat = np.sign(pred) * yte
    cost_pct = 0.02           # ≈0.40 USD de coste sobre oro a ~2000, en %
    neto = float(strat.mean()) - cost_pct
    sharpe = (neto / float(strat.std()) * math.sqrt(252)
              if strat.std() > 0 else 0.0)
    return {
        "por_ano": por_ano,
        "anos_sin_efecto": flojos,
        "retorno_bruto_diario_pct": round(float(strat.mean()), 4),
        "coste_estimado_pct": cost_pct,
        "retorno_neto_diario_pct": round(neto, 4),
        "sharpe_neto_anualizado": round(sharpe, 2),
        "veredicto": (
            f"INESTABLE: sin efecto en {flojos}. El agregado no se puede usar "
            f"para dimensionar; hace falta validacion continua antes de confiar"
            if flojos else
            "estable en todos los anos del tramo de prueba"),
    }


DXY_FEATS = ["dxy_lag1", "dxy_lag2", "dxy_lag3", "dxy_lag5", "dxy_5d"]
GOLD_FEATS = ["gold_lag1", "gold_5d"]


def _design(df: pd.DataFrame) -> pd.DataFrame:
    """Matriz de diseño. `y` es el retorno del oro de MAÑANA.

    Sobre el desfase horario: el DXY de la Fed es el fijado de mediodia en Nueva
    York (17:00 UTC) y el cierre del oro es la ultima barra UTC del dia, asi que
    predecir el dia t+1 con el dolar del dia t deja ~30 horas de margen. No hay
    look-ahead por construccion.
    """
    d = df.copy()
    d["y"] = d["r_gold"].shift(-1)
    for k in (1, 2, 3, 5):
        d[f"dxy_lag{k}"] = d["r_dxy"].shift(k - 1)
    d["dxy_5d"] = d["r_dxy"].rolling(5).sum()
    d["gold_lag1"] = d["r_gold"]
    d["gold_5d"] = d["r_gold"].rolling(5).sum()
    return d.dropna()


def _fit_oos(d: pd.DataFrame, feats: list[str], cut: int) -> dict:
    """Ajusta por MCO en el primer tramo y mide en el segundo."""
    Xtr, ytr = d[feats].to_numpy()[:cut], d["y"].to_numpy()[:cut]
    Xte, yte = d[feats].to_numpy()[cut:], d["y"].to_numpy()[cut:]
    A = np.column_stack([np.ones(len(Xtr)), Xtr])
    coef, *_ = np.linalg.lstsq(A, ytr, rcond=None)
    pred = np.column_stack([np.ones(len(Xte)), Xte]) @ coef
    ss_tot = float(((yte - ytr.mean()) ** 2).sum())
    r2 = 1.0 - float(((yte - pred) ** 2).sum()) / ss_tot if ss_tot > 0 else 0.0
    hit = float(((pred > 0) == (yte > 0)).mean())
    se = math.sqrt(0.25 / len(yte))
    return {
        "n_test": int(len(yte)),
        "r2_fuera_muestra": round(r2, 5),
        "acierto_direccional_pct": round(100.0 * hit, 2),
        "sigmas_sobre_azar": round((hit - 0.5) / se, 2),
    }


def full_report(gold: pd.DataFrame, dxy: pd.DataFrame) -> dict:
    """Ejecuta las siete secciones y devuelve el informe completo."""
    df = align(gold, dxy)
    return {
        "datos": {"n_dias_comunes": int(len(df)),
                  "desde": str(df.index[0].date()), "hasta": str(df.index[-1].date())},
        "correlaciones": correlations(df),
        "por_regimen": by_regime(df),
        "adelanto_retraso": lead_lag(df),
        "cointegracion": cointegration(df),
        "beta_movil": rolling_beta(df),
        "prediccion": predictive(df),
        "ablacion": ablation(df),
        "estabilidad": stability(df),
        "shocks": shocks(df),
    }


__all__ = ["align", "correlations", "by_regime", "lead_lag", "cointegration",
           "rolling_beta", "predictive", "ablation", "stability", "shocks",
           "full_report", "DXY_FEATS", "GOLD_FEATS"]
