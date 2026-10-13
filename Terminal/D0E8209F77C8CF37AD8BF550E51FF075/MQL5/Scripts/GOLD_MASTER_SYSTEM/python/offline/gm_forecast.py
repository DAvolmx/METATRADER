"""
gm_forecast.py — Pronóstico PROBABILÍSTICO de las próximas 2 velas H4 + el camino de
velas de temporalidad baja (M15) que las forma.

No predice el futuro exacto (se demostró que la dirección a estos plazos es casi
aleatoria, AUC ~0.51). En su lugar da una DISTRIBUCIÓN honesta:

  1. Deriva (drift)  — Ridge sobre features causales (pendiente EMA, momentum,
     distancia a EMA50, estructura). Si no hay señal, la deriva tiende a ~0.
  2. Volatilidad     — EWMA de |retornos| H4 (clúster de volatilidad).
  3. Monte Carlo     — M caminos de 16 pasos M15 por cada H4 (16·15min = 4h), con
     mu/paso y sigma/paso; se agregan a OHLC H4. La vela H4 pronosticada = mediana
     de cierres; el rango sombreado = percentiles p10/p90. El camino M15 mostrado
     es el más cercano a la mediana.
  4. CALIBRACIÓN     — sobre el histórico mide qué % de los cierres reales de la
     siguiente H4 caen dentro de la banda p10-p90. Si está bien calibrado, ~80%.

Pensado para enchufarse al terminal replay (dibuja las 2 H4 "fantasma" + su M15) y al
puente. Investigación; una banda no es una garantía de dirección.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "optimizer"))
sys.path.insert(0, str(HERE))

import gm_optimizer as go                       # noqa: E402
from mt5_import import load_mt5, resample        # noqa: E402

OUT = HERE / "out_offline"; OUT.mkdir(exist_ok=True)
SUBSTEPS = 16            # velas M15 por vela H4
HORIZON = 2             # H4 a pronosticar
SIG_SCALE = 1.20        # ajuste de calibración de la banda (EWMA subestima la cola)


def _features(c, h, l):
    atr = go.atr(h, l, c); e50 = go.ema(c, 50); e200 = go.ema(c, 200)
    slope, mid, dev = go.rolling_reg(c, 50)
    sdir, swL, swH = go.structure(h, l, c)
    a = np.where(atr > 0, atr, 1e-9)
    mom = c - np.r_[c[:12] * 0 + c[0], c[:-12]]
    X = np.column_stack([slope / a, mom / a, (c - e50) / a, (e50 - e200) / a, sdir]).astype(float)
    return np.nan_to_num(X, nan=0.0, posinf=0.0, neginf=0.0), atr


def fit_drift(h4, train_frac=0.70):
    from sklearn.linear_model import Ridge
    c = h4["close"].to_numpy(float); h = h4["high"].to_numpy(float); l = h4["low"].to_numpy(float)
    X, atr = _features(c, h, l)
    r = np.r_[np.diff(np.log(c)), 0.0]        # retorno log de la SIGUIENTE vela
    n = len(c); split = int(n * train_frac)
    sl = slice(200, split)
    m = Ridge(alpha=5.0).fit(X[sl], r[sl])
    # volatilidad EWMA de |retorno|
    ewma = pd.Series(np.abs(np.r_[0.0, np.diff(np.log(c))])).ewm(alpha=1/32, adjust=False).mean().to_numpy()
    return m, X, atr, ewma, c, split


def mc_h4_paths(c0, mu_h4, sig_h4, runs, rng):
    """Devuelve (closes[runs], paths[runs,SUBSTEPS] precios M15) para UNA vela H4."""
    mu = mu_h4 / SUBSTEPS
    sig = sig_h4 / np.sqrt(SUBSTEPS)
    steps = rng.normal(mu, sig, size=(runs, SUBSTEPS))
    logp = np.log(c0) + np.cumsum(steps, axis=1)
    prices = np.exp(logp)
    return prices[:, -1], prices


def ohlc_from_path(c0, path):
    o = c0; cl = path[-1]; hi = max(o, path.max()); lo = min(o, path.min())
    return dict(open=round(float(o), 2), high=round(float(hi), 2), low=round(float(lo), 2), close=round(float(cl), 2))


def forecast(h4, runs=800, seed=0):
    m, X, atr, ewma, c, split = fit_drift(h4)
    rng = np.random.default_rng(seed)
    i = len(c) - 1
    c0 = c[i]; sig = max(ewma[i], 1e-5) * SIG_SCALE
    out = []
    cur = c0
    for step in range(HORIZON):
        mu = float(m.predict(X[i:i+1])[0]) * (0.6 ** step)   # deriva decae con el horizonte
        closes, paths = mc_h4_paths(cur, mu, sig, runs, rng)
        med = float(np.median(closes))
        p10, p90 = float(np.percentile(closes, 10)), float(np.percentile(closes, 90))
        # camino M15 representativo = el más cercano a la mediana de cierre
        j = int(np.argmin(np.abs(closes - med)))
        rep = paths[j]
        m15 = [round(float(x), 2) for x in rep]
        out.append(dict(h4=ohlc_from_path(cur, rep), median_close=round(med, 2),
                        p10=round(p10, 2), p90=round(p90, 2),
                        up_prob=round(float((closes > cur).mean()), 3),
                        m15_path=m15))
        cur = med
    # calibración sobre test
    cov = _calibration(m, X, ewma, c, split, rng)
    return dict(base_close=round(c0, 2), horizon=HORIZON, substeps=SUBSTEPS,
                forecast=out, calibration=cov)


def _calibration(m, X, ewma, c, split, rng, runs=300):
    hits = tot = 0
    for i in range(split, len(c) - 1):
        mu = float(m.predict(X[i:i+1])[0]); sig = max(ewma[i], 1e-5) * SIG_SCALE
        closes, _ = mc_h4_paths(c[i], mu, sig, runs, rng)
        p10, p90 = np.percentile(closes, 10), np.percentile(closes, 90)
        real = c[i + 1]
        hits += int(p10 <= real <= p90); tot += 1
    # también direccional: ¿acierta el signo la mediana?
    dir_hit = dir_tot = 0
    for i in range(split, len(c) - 1):
        mu = float(m.predict(X[i:i+1])[0])
        if mu == 0: continue
        dir_hit += int(np.sign(mu) == np.sign(c[i + 1] - c[i])); dir_tot += 1
    return dict(band_coverage_pct=round(hits / tot * 100, 1) if tot else None,
                expected_coverage_pct=80.0, n=tot,
                direction_hit_pct=round(dir_hit / dir_tot * 100, 1) if dir_tot else None)


def run(csv_path, runs=800):
    m1 = load_mt5(csv_path); h4 = resample(m1, "H4")
    rep = forecast(h4, runs=runs)
    rep["file"] = Path(csv_path).name
    rep["last_time"] = str(h4["time"].iloc[-1])
    (OUT / "forecast.json").write_text(json.dumps(rep, indent=2, ensure_ascii=False), encoding="utf-8")
    return rep


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("uso: python gm_forecast.py <M1_o_H1.csv>"); raise SystemExit(2)
    r = run(sys.argv[1])
    print(f"\nPronóstico H4 desde {r['last_time']}  (cierre base {r['base_close']})")
    for k, f in enumerate(r["forecast"], 1):
        h = f["h4"]
        print(f"  H4 +{k}: O{h['open']} H{h['high']} L{h['low']} C{h['close']}  "
              f"(mediana {f['median_close']}, rango p10-p90 {f['p10']}–{f['p90']}, P(sube)={f['up_prob']:.0%}) "
              f"· {len(f['m15_path'])} velas M15")
    cal = r["calibration"]
    print(f"\nCalibración (test, {cal['n']} velas): la vela real cayó dentro de la banda p10-p90 "
          f"el {cal['band_coverage_pct']}% (ideal ~{cal['expected_coverage_pct']}%)")
    print(f"Acierto direccional de la mediana: {cal['direction_hit_pct']}%  (50% = azar)")
    print(f"\nReport -> {OUT/'forecast.json'}")
