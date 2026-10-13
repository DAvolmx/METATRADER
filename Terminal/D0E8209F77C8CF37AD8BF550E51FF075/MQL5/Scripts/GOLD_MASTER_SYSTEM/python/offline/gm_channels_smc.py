"""
gm_channels_smc.py — Estrategia COMBINADA: canales de regresión + rompimiento +
Order Blocks + estructura SMC (BOS/CHoCH), backtesteable sobre datos reales o
sintéticos. Opera en H1 por defecto.

Lógica (causal, solo velas cerradas):
  1. Canal de regresión lineal de L velas -> línea media + bandas ±k·desviación.
     Un canal "alcista" tiene pendiente>0; "bajista" pendiente<0.
  2. Rompimiento: cierre por ENCIMA de la banda superior (ruptura alcista) o por
     DEBAJO de la inferior (bajista), tras venir de dentro del canal.
  3. Filtro SMC: la ruptura debe ir a favor de la estructura (sdir = BOS/CHoCH) y
     del sesgo EMA200.
  4. Order Block: debe existir un OB reciente a favor (demanda para largos, oferta
     para cortos) = la última vela opuesta antes del impulso de desplazamiento.
     El SL se apoya detrás del OB; TP = RR·riesgo.

Reutiliza gm_optimizer (rolling_reg, structure, atr, ema) y el motor de ejecución
con costes (simulate_orders). Investigación; no opera ni promete rentabilidad.
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

import gm_optimizer as go                                   # noqa: E402
from gm_validation import simulate_orders, equity_path, bootstrap_metrics  # noqa: E402
from mt5_import import load_mt5, resample                   # noqa: E402

OUT = HERE / "out_offline"; OUT.mkdir(exist_ok=True)
POINT = 0.01

DEFAULTS = dict(chan_len=50, band_k=2.0, rr=2.0, slatr=1.0, maxbars=48,
                ob_displacement=1.0, ob_max_age=20)


def build_orders(df: pd.DataFrame, P: dict):
    c = df["close"].to_numpy(float); h = df["high"].to_numpy(float)
    l = df["low"].to_numpy(float); o = df["open"].to_numpy(float)
    atr = go.atr(h, l, c); e200 = go.ema(c, 200)
    slope, mid, dev = go.rolling_reg(c, P["chan_len"])
    sdir, swL, swH = go.structure(h, l, c)
    k = P["band_k"]
    upper = mid + k * dev; lower = mid - k * dev
    orders = []
    bull_ob = None   # (low, bar)  demanda
    bear_ob = None   # (high, bar) oferta
    cand_down = None; cand_up = None
    L = P["chan_len"]
    for b in range(max(L, 200) + 1, len(c)):
        # --- seguimiento de Order Blocks ---
        if c[b - 1] < o[b - 1]:
            cand_down = (l[b - 1], b - 1)                 # última vela bajista (posible demanda)
        if c[b - 1] > o[b - 1]:
            cand_up = (h[b - 1], b - 1)                   # última vela alcista (posible oferta)
        disp = (c[b] - c[b - 1])
        if disp > P["ob_displacement"] * atr[b] and cand_down:
            bull_ob = cand_down                           # impulso alcista confirma OB de demanda
        if -disp > P["ob_displacement"] * atr[b] and cand_up:
            bear_ob = cand_up
        if bull_ob and c[b] < bull_ob[0]:
            bull_ob = None                                # OB mitigado/roto
        if bear_ob and c[b] > bear_ob[0]:
            bear_ob = None
        if not (np.isfinite(upper[b]) and np.isfinite(dev[b])) or dev[b] <= 0:
            continue
        # --- rupturas de canal con confluencia SMC + OB ---
        broke_up = c[b] > upper[b] and c[b - 1] <= upper[b - 1]
        broke_dn = c[b] < lower[b] and c[b - 1] >= lower[b - 1]
        if broke_up and slope[b] > 0 and sdir[b] == 1 and c[b] > e200[b] and bull_ob \
                and (b - bull_ob[1]) <= P["ob_max_age"]:
            entry = c[b]; stop = min(bull_ob[0], lower[b]) - 0.1 * atr[b]
            risk = entry - stop
            if 0 < risk <= 4 * atr[b]:
                orders.append((b, 1, entry, stop, entry + P["rr"] * risk, risk)); bull_ob = None
        if broke_dn and slope[b] < 0 and sdir[b] == -1 and c[b] < e200[b] and bear_ob \
                and (b - bear_ob[1]) <= P["ob_max_age"]:
            entry = c[b]; stop = max(bear_ob[0], upper[b]) + 0.1 * atr[b]
            risk = stop - entry
            if 0 < risk <= 4 * atr[b]:
                orders.append((b, -1, entry, stop, entry - P["rr"] * risk, risk)); bear_ob = None
    feats = {"o": o, "h": h, "l": l, "c": c, "spread": df["spread"].to_numpy(float)}
    return feats, orders


def _metrics(trades, start=50.0):
    if not trades:
        return dict(n=0)
    R = np.array([t[1] for t in trades]); risk = np.array([t[2] for t in trades])
    pnl = R * risk
    eq = equity_path(pnl, start); peak = np.maximum.accumulate(eq)
    wins, losses = pnl[pnl > 0], pnl[pnl < 0]
    return dict(n=int(len(R)), win_rate=float((R > 0).mean() * 100),
                expectancy_R=float(R.mean()), profit_factor=float(wins.sum() / -losses.sum()) if losses.size else float("inf"),
                return_pct=float((eq[-1] - start) / start * 100),
                max_dd_pct=float(((peak - eq) / peak).max() * 100) if len(eq) else 0.0,
                sqn=float(R.mean() / R.std() * np.sqrt(min(len(R), 100))) if R.std() > 0 else 0.0)


def run(csv_path, tf="H1", P=None, split_frac=0.70, label=""):
    P = {**DEFAULTS, **(P or {})}
    m1 = load_mt5(csv_path); bars = resample(m1, tf)
    feats, orders = build_orders(bars, P)
    n = len(bars["close"]); split = int(n * split_frac)
    tr = simulate_orders(feats, orders, POINT, P["maxbars"], 0.0, 0.0, 0.0, 0.0, 0, split)
    te = simulate_orders(feats, orders, POINT, P["maxbars"], 0.0, 0.0, 0.0, 0.0, split, n)
    def pack(res): return [(x[0], x[1], x[2]) for x in res]
    mc = None
    tep = pack(te)
    if len(tep) >= 10:
        pnl = np.array([t[1] * t[2] for t in tep])
        mc = {k: (float(v) if isinstance(v, (int, float, np.floating)) else v)
              for k, v in bootstrap_metrics(pnl, 50.0, 25.0, np.random.default_rng(3), runs=3000).items()}
    rep = dict(label=label or Path(csv_path).name, tf=tf, params=P, bars=int(n),
               signals=len(orders), all=_metrics(pack(tr) + tep), train=_metrics(pack(tr)),
               test=_metrics(tep), mc_test=mc)
    return rep


def _fmt(m):
    if not m or m.get("n", 0) == 0: return "sin ops"
    return (f"n={m['n']:4d} exp={m['expectancy_R']:+.3f}R PF={m['profit_factor']:.2f} "
            f"ret={m['return_pct']:+.0f}% DD={m['max_dd_pct']:.0f}% WR={m['win_rate']:.0f}%")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("uso: python gm_channels_smc.py <M1.csv> [TF=H1]"); raise SystemExit(2)
    tf = sys.argv[2] if len(sys.argv) > 2 else "H1"
    rep = run(sys.argv[1], tf)
    print(f"\nCanales+OB+SMC  {rep['label']}  {tf}  ({rep['bars']} velas, {rep['signals']} señales)")
    print("  TRAIN:", _fmt(rep["train"]))
    print("  TEST :", _fmt(rep["test"]), " <-- fuera de muestra")
    if rep["mc_test"]:
        print("  MC(test):", {k: round(v, 3) if isinstance(v, float) else v
                              for k, v in list(rep["mc_test"].items())[:6]})
    (OUT / "channels_smc.json").write_text(json.dumps(rep, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"\nReport -> {OUT/'channels_smc.json'}")
