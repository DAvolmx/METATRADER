"""
gm_ob_montecarlo.py — Sistema Monte Carlo para juzgar estrategias de order block.

Tres pruebas, de menos a más exigente. Las tres hacen falta: pasar la primera y
suspender la tercera significa que la estrategia no sirve, por bonita que sea la
curva de capital.

  1. BOOTSTRAP DE LA SECUENCIA (`bootstrap_equity`)
     Remuestrea las operaciones para obtener la distribución de resultados:
     probabilidad de ruina, drawdown esperado, dispersión del resultado final.
     Responde "¿qué pasa si el mismo edge se repite en otro orden?".

  2. CORRECCIÓN POR PRUEBAS MÚLTIPLES (`reality_check`)
     Contraste de realidad de White. Si se prueban 486 especificaciones y se
     escoge la mejor, esa mejor parece excelente por pura suerte. El bootstrap
     se hace sobre los ORDER BLOCKS, no sobre cada estrategia por separado, para
     conservar la dependencia entre especificaciones que comparten bloques.
     Responde "¿sobreviviría la mejor si el edge real fuese cero?".

  3. TEST NULO SINTÉTICO (`synthetic_null`)
     El más severo, y el que de verdad contesta si los order blocks capturan
     algo institucional. Se generan caminos de oro con la ecuación maestra
     calibrada (gm_gold_sde), que por construcción NO contiene ninguna huella de
     dinero institucional: solo volatilidad agrupada, colas y regímenes. Se
     corre el detector completo y el mismo barrido sobre esos caminos. Si la
     mejor estrategia sobre oro REAL cae dentro de la distribución de mejores
     resultados sobre oro SINTÉTICO, entonces lo que mide el detector es
     cosecha de volatilidad y no estructura de mercado.
     Responde "¿hay order blocks, o solo hay volatilidad?".
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd


# ───────────────────── 1. bootstrap de la secuencia ─────────────────────


def bootstrap_equity(R: np.ndarray, n_boot: int = 20_000, horizon: int | None = None,
                     risk_frac: float = 0.02, ruin_frac: float = 0.5,
                     block: int = 5, seed: int = 0) -> dict:
    """Distribución del resultado remuestreando la secuencia de operaciones.

    Usa bootstrap POR BLOQUES (block>1) porque las operaciones de order block no
    son independientes: llegan agrupadas en los mismos tramos de mercado, y un
    bootstrap i.i.d. rompería esa agrupación y subestimaría el drawdown.

    `risk_frac` es la fracción de capital arriesgada por operación, y la ruina
    se declara al perder `ruin_frac` del capital inicial.
    """
    R = np.asarray(R, dtype=float)
    R = R[np.isfinite(R)]
    n = len(R)
    if n < 10:
        return {"n": n, "error": "muestra insuficiente"}
    H = int(horizon or n)
    rng = np.random.default_rng(seed)

    nb = max(1, H // block)
    starts = rng.integers(0, n, size=(n_boot, nb))
    offs = np.arange(block)
    idx = (starts[:, :, None] + offs[None, None, :]) % n
    draws = R[idx.reshape(n_boot, -1)[:, :H]]

    # capital multiplicativo: cada operación mueve risk_frac·R del capital
    growth = np.log1p(np.clip(risk_frac * draws, -0.99, None))
    eq = np.exp(np.cumsum(growth, axis=1))
    peak = np.maximum.accumulate(eq, axis=1)
    dd = (eq / peak - 1.0).min(axis=1)
    final = eq[:, -1]
    ruined = (eq.min(axis=1) <= (1.0 - ruin_frac))

    return {
        "n_trades_src": n, "horizon": H, "n_boot": n_boot,
        "risk_frac": risk_frac,
        "p_ruin_pct": round(100.0 * float(ruined.mean()), 2),
        "p_profit_pct": round(100.0 * float((final > 1.0).mean()), 2),
        "final_p05": round(float(np.percentile(final, 5)), 3),
        "final_p50": round(float(np.percentile(final, 50)), 3),
        "final_p95": round(float(np.percentile(final, 95)), 3),
        "max_dd_p50_pct": round(100.0 * float(np.percentile(dd, 50)), 2),
        "max_dd_p05_pct": round(100.0 * float(np.percentile(dd, 5)), 2),
        "expectancy_R": round(float(R.mean()), 4),
    }


# ───────────────── 2. corrección por pruebas múltiples ─────────────────


def build_matrix(trades_by_spec: dict[str, pd.DataFrame]) -> pd.DataFrame:
    """Matriz order-block × especificación con el R obtenido en cada cruce.

    La clave es `confirm_index`: todas las especificaciones operan la MISMA
    población de bloques, así que remuestrear filas conserva la correlación
    entre estrategias (dos variantes que operan el mismo bloque suben y bajan
    juntas). Sin esto, el contraste de realidad sale demasiado permisivo.
    """
    cols = {}
    for name, t in trades_by_spec.items():
        if t is None or t.empty:
            continue
        cols[name] = t.groupby("confirm_index")["R"].mean()
    if not cols:
        return pd.DataFrame()
    return pd.DataFrame(cols).sort_index()


def reality_check(mat: pd.DataFrame, n_boot: int = 5_000, block: int = 5,
                  seed: int = 0, min_trades: int = 30) -> dict:
    """Contraste de realidad de White sobre la mejor especificación.

    H0: ninguna especificación tiene esperanza positiva. Se centra cada columna
    (se le resta su media) y se remuestrean BLOQUES de bloques-de-orden para
    construir la distribución del máximo estadístico. El p-valor es la fracción
    de remuestreos cuyo máximo iguala o supera el observado.
    """
    if mat.empty:
        return {"error": "matriz vacia"}
    counts = mat.notna().sum(axis=0)
    keep = counts[counts >= min_trades].index
    if len(keep) == 0:
        return {"error": f"ninguna especificacion con >={min_trades} operaciones"}
    M = mat[keep]
    X = M.to_numpy(dtype=float)
    nrow, ncol = X.shape
    mask = np.isfinite(X)
    cnt = mask.sum(axis=0).astype(float)
    Xz = np.where(mask, X, 0.0)
    means = Xz.sum(axis=0) / cnt
    # estadístico: media × sqrt(n), que penaliza las muestras pequeñas
    stat = means * np.sqrt(cnt)
    best_i = int(np.nanargmax(stat))
    observed = float(stat[best_i])

    # bajo H0 cada columna tiene media cero
    Xc = np.where(mask, X - means[None, :], 0.0)
    rng = np.random.default_rng(seed)
    nb = max(1, nrow // block)
    offs = np.arange(block)
    null_max = np.empty(n_boot)
    for b in range(n_boot):
        s = rng.integers(0, nrow, size=nb)
        rows = ((s[:, None] + offs[None, :]).ravel() % nrow)[:nrow]
        sub_v, sub_m = Xc[rows], mask[rows]
        c = sub_m.sum(axis=0).astype(float)
        with np.errstate(invalid="ignore", divide="ignore"):
            mu = np.where(c > 0, sub_v.sum(axis=0) / np.maximum(c, 1), 0.0)
        null_max[b] = np.nanmax(mu * np.sqrt(c))

    p = float((null_max >= observed).mean())
    return {
        "n_specs_tested": int(ncol), "n_obs": int(nrow),
        "best_spec": str(keep[best_i]),
        "best_expectancy_R": round(float(means[best_i]), 4),
        "best_n": int(cnt[best_i]),
        "observed_stat": round(observed, 4),
        "null_stat_p50": round(float(np.percentile(null_max, 50)), 4),
        "null_stat_p95": round(float(np.percentile(null_max, 95)), 4),
        "p_value": round(p, 4),
        "verdict": ("sobrevive la correccion por pruebas multiples" if p < 0.05
                    else "NO sobrevive: explicable por haber probado muchas variantes"),
    }


# ───────────────── 3. test nulo sintético ─────────────────


def calibrate_bridge(df: pd.DataFrame) -> float:
    """Calibra la amplitud intrabarra a partir de datos reales.

    La ecuación maestra simula CIERRES horarios, pero el detector de order
    blocks necesita máximos y mínimos. Se construyen con un puente browniano
    dentro de cada barra, y su amplitud no se inventa: se ajusta para que la
    razón mediana (máximo−mínimo)/|cierre−apertura| de las barras sintéticas
    coincida con la de las barras reales.
    """
    o = df["open"].to_numpy(dtype=float)
    h = df["high"].to_numpy(dtype=float)
    l = df["low"].to_numpy(dtype=float)
    c = df["close"].to_numpy(dtype=float)
    body = np.abs(c - o)
    ok = body > 0
    return float(np.median((h - l)[ok] / body[ok]))


def synth_ohlc(model, n_bars: int, target_ratio: float, seed: int = 0,
               substeps: int = 10, s0: float = 2000.0,
               drift_annual: float | None = None) -> pd.DataFrame:
    """Genera velas OHLC sintéticas a partir de la ecuación maestra.

    Los cierres salen del modelo; el recorrido dentro de cada barra se rellena
    con un puente browniano de `substeps` tramos, escalado para reproducir la
    razón de amplitud real medida por `calibrate_bridge`. Es una barra con la
    MISMA dinámica de volatilidad, colas y regímenes que el oro, pero sin
    ninguna estructura institucional que un order block pudiera estar leyendo.
    """
    from gm_gold_sde import simulate

    px = simulate(model, n_paths=1, n_steps=n_bars, s0=s0, seed=seed,
                  drift_annual=drift_annual, antithetic=False)[0]
    lp = np.log(px.astype(float))
    r = np.diff(lp)                                    # n_bars retornos
    rng = np.random.default_rng(seed + 991)

    # puente browniano: incrementos que suman r, con varianza controlada.
    #
    # La amplitud del puente se escala con la VOLATILIDAD LOCAL, no con |r| de
    # la propia barra. Escalarla con |r| acopla mecha y cuerpo, y entonces una
    # vela de cuerpo diminuto no puede tener mecha grande: el generador se
    # vuelve estructuralmente incapaz de producir velas de rechazo (medido: 1
    # bloque de rechazo sintetico frente a 169 reales), y el test nulo dejaria
    # de ser justo justo en el escenario mas interesante. Con volatilidad local
    # el cuerpo y el recorrido quedan desacoplados, como en el mercado.
    m = int(substeps)
    w = rng.standard_normal((n_bars, m))
    w -= w.mean(axis=1, keepdims=True)                 # suma cero
    loc = pd.Series(r).rolling(24, min_periods=4).std().bfill().to_numpy()
    loc = np.where(np.isfinite(loc) & (loc > 0), loc, np.nanstd(r))
    sd = loc / math.sqrt(m)
    k = 1.0
    for _ in range(40):                                # ajusta k a la razón real
        path = r[:, None] * np.arange(1, m + 1)[None, :] / m + k * sd[:, None] * w
        hi, lo = path.max(axis=1), path.min(axis=1)
        hi = np.maximum(hi, np.maximum(0.0, r)); lo = np.minimum(lo, np.minimum(0.0, r))
        nz = np.abs(r) > 1e-12
        got = np.median((hi - lo)[nz] / np.abs(r)[nz])
        if abs(got - target_ratio) < 0.01:
            break
        k *= (target_ratio / max(got, 1e-9)) ** 0.5
        k = min(max(k, 1e-3), 50.0)

    op = lp[:-1]
    cl = lp[1:]
    return pd.DataFrame({
        "open": np.exp(op), "high": np.exp(op + hi), "low": np.exp(op + lo),
        "close": np.exp(cl), "volume": 0.0,
    }, index=pd.date_range("2000-01-01", periods=n_bars, freq="1h"))


def synthetic_null(model, specs, n_bars: int, target_ratio: float,
                   n_paths: int = 30, seed0: int = 0, min_trades: int = 30,
                   detector_cfg=None, costs=None, drift_annual: float = 0.0,
                   progress=None) -> pd.DataFrame:
    """Corre el detector y el barrido completos sobre caminos SINTÉTICOS.

    Devuelve una fila por camino con la mejor esperanza alcanzada en ese camino.
    La distribución de esa columna es la referencia nula: cuánto "edge" produce
    barrer cientos de especificaciones sobre volatilidad pura.
    """
    import gm_ob_strategies as st
    import gm_orderblocks_pro as obm

    rows = []
    for p in range(n_paths):
        df = synth_ohlc(model, n_bars, target_ratio, seed=seed0 + p * 7919,
                        drift_annual=drift_annual)
        obs = obm.detect(df, detector_cfg)
        if obs.empty:
            rows.append({"path": p, "n_obs": 0, "best_exp_R": np.nan})
            continue
        res = st.sweep(df, obs, specs, costs, min_trades)
        ok = res[res["n"] >= min_trades]
        rows.append({
            "path": p, "n_obs": int(len(obs)),
            "n_specs_ok": int(len(ok)),
            "best_exp_R": float(ok["expectancy_R"].max()) if len(ok) else np.nan,
            "median_exp_R": float(ok["expectancy_R"].median()) if len(ok) else np.nan,
            "pct_positive": (round(100.0 * float((ok["expectancy_R"] > 0).mean()), 1)
                             if len(ok) else np.nan),
            "best_spec": str(ok.iloc[0]["spec"]) if len(ok) else "",
        })
        if progress:
            progress(p + 1, n_paths, rows[-1])
    return pd.DataFrame(rows)


def null_verdict(real_best: float, null_best: np.ndarray) -> dict:
    """Compara la mejor esperanza real contra la distribución nula sintética."""
    nb = np.asarray(null_best, dtype=float)
    nb = nb[np.isfinite(nb)]
    if len(nb) < 5:
        return {"error": "distribucion nula insuficiente"}
    p = float((nb >= real_best).mean())
    return {
        "real_best_exp_R": round(float(real_best), 4),
        "null_n_paths": int(len(nb)),
        "null_p50": round(float(np.percentile(nb, 50)), 4),
        "null_p90": round(float(np.percentile(nb, 90)), 4),
        "null_max": round(float(nb.max()), 4),
        "p_value": round(p, 4),
        "verdict": (
            "el edge real supera lo que produce la volatilidad pura" if p < 0.05
            else "INDISTINGUIBLE de volatilidad pura: el detector no esta leyendo "
                 "estructura institucional, esta cosechando volatilidad"),
    }


__all__ = ["bootstrap_equity", "build_matrix", "reality_check", "calibrate_bridge",
           "synth_ohlc", "synthetic_null", "null_verdict"]
