"""
gm_orderblocks.py — Estrategia basada en ORDER BLOCKS (detecta todos y opera sus retests),
con canal de regresión para la tendencia y EMAs 50/200 como sesgo.

Definición de Order Block (causal, solo velas cerradas):
  * Bullish OB (demanda): la ÚLTIMA vela bajista antes de un impulso alcista que
    ROMPE el último swing alto (BOS alcista). Su zona = [low, high] de esa vela.
  * Bearish OB (oferta): la última vela alcista antes de un impulso bajista que
    rompe el último swing bajo.
Se guardan TODOS los OB activos (no mitigados). Un OB muere cuando el precio lo
atraviesa por completo (cierre al otro lado).

Entrada = RETEST: cuando el precio vuelve a entrar en la zona de un OB no mitigado
y la respeta (cierra a favor), se entra en la dirección del OB. Filtros opcionales:
  * canal de regresión: pendiente a favor (tendencia).
  * EMAs: ema_fast/ema_slow y ema_filter (sesgo macro).
SL detrás del OB; TP = rr·riesgo.

Backtesteable con train/test; pensada para pasar por gm_robustness. Investigación.
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

DEFAULTS = dict(
    swing=5,                 # velas a cada lado para swings/estructura
    # Mejor config hallada por sweep en 10 años reales (train+test positivos):
    # SOLO OB de impulso fuerte (disp_atr alto) + filtro de canal; la EMA restringía de más.
    disp_atr=2.5,            # impulso mínimo (en ATR) para validar el OB
    rr=2.0,                  # TP = rr * riesgo
    sl_buffer=0.1,           # colchón (en ATR) detrás del OB
    max_active=50,           # OB activos máximos por lado
    retest_max_age=60,       # velas máx. que un OB sigue válido esperando retest
    maxbars=48,              # duración máx. de la operación
    use_channel=1, chan_len=50,          # filtro de canal (pendiente) — ayuda
    use_ema=0, ema_fast=50, ema_slow=200, ema_filter=200,   # filtro EMAs — restringía de más
)


def build_orders(df: pd.DataFrame, P: dict):
    o = df["open"].to_numpy(float); h = df["high"].to_numpy(float)
    l = df["low"].to_numpy(float); c = df["close"].to_numpy(float)
    atr = go.atr(h, l, c)
    efast = go.ema(c, int(P["ema_fast"])); eslow = go.ema(c, int(P["ema_slow"]))
    efilt = go.ema(c, int(P["ema_filter"]))
    slope, mid, dev = go.rolling_reg(c, int(P["chan_len"]))
    sdir, swL, swH = go.structure(h, l, c, k=int(P["swing"]))
    n = len(c)
    bull_obs = []   # dicts {lo, hi, bar}
    bear_obs = []
    orders = []
    last_down = None   # (lo, hi, bar) última vela bajista
    last_up = None
    prev_swH = np.nan; prev_swL = np.nan
    start = max(int(P["ema_filter"]), int(P["chan_len"]), 200) + 2
    for b in range(start, n):
        # registrar última vela opuesta
        if c[b - 1] < o[b - 1]:
            last_down = (l[b - 1], h[b - 1], b - 1)
        if c[b - 1] > o[b - 1]:
            last_up = (l[b - 1], h[b - 1], b - 1)
        a = atr[b] if atr[b] > 0 else 1e-9
        # --- detección de OB por impulso que rompe estructura ---
        broke_up = np.isfinite(swH[b]) and c[b] > swH[b] and (c[b] - c[b - 1]) > P["disp_atr"] * a
        broke_dn = np.isfinite(swL[b]) and c[b] < swL[b] and (c[b - 1] - c[b]) > P["disp_atr"] * a
        if broke_up and last_down:
            bull_obs.append(dict(lo=last_down[0], hi=last_down[1], bar=b))
            bull_obs = bull_obs[-int(P["max_active"]):]
        if broke_dn and last_up:
            bear_obs.append(dict(lo=last_up[0], hi=last_up[1], bar=b))
            bear_obs = bear_obs[-int(P["max_active"]):]
        # --- filtros de tendencia ---
        up_ok = True; dn_ok = True
        if P["use_ema"]:
            up_ok = up_ok and c[b] > efilt[b] and efast[b] >= eslow[b]
            dn_ok = dn_ok and c[b] < efilt[b] and efast[b] <= eslow[b]
        if P["use_channel"]:
            up_ok = up_ok and slope[b] > 0
            dn_ok = dn_ok and slope[b] < 0
        # --- retests de OB no mitigados ---
        still_bull = []
        for ob in bull_obs:
            if c[b] < ob["lo"]:                       # mitigado/invalidado
                continue
            if (b - ob["bar"]) > P["retest_max_age"]:
                continue
            touched = l[b] <= ob["hi"] and h[b] >= ob["lo"]
            if touched and c[b] > ob["lo"] and up_ok and b > ob["bar"]:
                entry = c[b]; stop = ob["lo"] - P["sl_buffer"] * a; risk = entry - stop
                if 0 < risk <= 4 * a:
                    orders.append((b, 1, entry, stop, entry + P["rr"] * risk, risk))
                    continue                           # consumir OB (no re-encolar)
            still_bull.append(ob)
        bull_obs = still_bull
        still_bear = []
        for ob in bear_obs:
            if c[b] > ob["hi"]:
                continue
            if (b - ob["bar"]) > P["retest_max_age"]:
                continue
            touched = h[b] >= ob["lo"] and l[b] <= ob["hi"]
            if touched and c[b] < ob["hi"] and dn_ok and b > ob["bar"]:
                entry = c[b]; stop = ob["hi"] + P["sl_buffer"] * a; risk = stop - entry
                if 0 < risk <= 4 * a:
                    orders.append((b, -1, entry, stop, entry - P["rr"] * risk, risk))
                    continue
            still_bear.append(ob)
        bear_obs = still_bear
    feats = {"o": o, "h": h, "l": l, "c": c, "spread": df["spread"].to_numpy(float)}
    orders.sort(key=lambda x: x[0])
    return feats, orders


def _metrics(trades, start=50.0):
    if not trades:
        return dict(n=0)
    R = np.array([t[1] for t in trades]); risk = np.array([t[2] for t in trades]); pnl = R * risk
    eq = equity_path(pnl, start); peak = np.maximum.accumulate(eq)
    w, l = pnl[pnl > 0].sum(), -pnl[pnl < 0].sum()
    return dict(n=int(len(R)), win_rate=float((R > 0).mean() * 100), expectancy_R=float(R.mean()),
                profit_factor=float(w / l) if l > 0 else 9.9,
                return_pct=float((eq[-1] - start) / start * 100),
                max_dd_pct=float(((peak - eq) / peak).max() * 100) if len(eq) else 0.0)


def run(csv_path, tf="H1", P=None, split_frac=0.70):
    P = {**DEFAULTS, **(P or {})}
    bars = resample(load_mt5(csv_path), tf)
    feats, orders = build_orders(bars, P)
    n = len(bars["close"]); split = int(n * split_frac)
    pk = lambda res: [(x[0], x[1], x[2]) for x in res]
    tr = pk(simulate_orders(feats, orders, POINT, int(P["maxbars"]), 0, 0, 0, 0, 0, split))
    te = pk(simulate_orders(feats, orders, POINT, int(P["maxbars"]), 0, 0, 0, 0, split, n))
    mc = None
    if len(te) >= 10:
        pnl = np.array([t[1] * t[2] for t in te])
        mc = {k: (float(v) if isinstance(v, (int, float, np.floating)) else v)
              for k, v in bootstrap_metrics(pnl, 50.0, 25.0, np.random.default_rng(3), runs=3000).items()}
    rep = dict(file=Path(csv_path).name, tf=tf, obs_detected=len(orders),
               params={k: P[k] for k in ("disp_atr", "rr", "use_channel", "use_ema", "ema_fast", "ema_slow")},
               train=_metrics(tr), test=_metrics(te), mc_test=mc)
    (OUT / "orderblocks.json").write_text(json.dumps(rep, indent=2, ensure_ascii=False), encoding="utf-8")
    return rep


def _fmt(m):
    if not m or m.get("n", 0) == 0: return "sin ops"
    return (f"n={m['n']:4d} exp={m['expectancy_R']:+.3f}R PF={m['profit_factor']:.2f} "
            f"ret={m['return_pct']:+.0f}% DD={m['max_dd_pct']:.0f}% WR={m['win_rate']:.0f}%")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("uso: python gm_orderblocks.py <M1_o_H1.csv> [TF=H1]"); raise SystemExit(2)
    tf = sys.argv[2] if len(sys.argv) > 2 else "H1"
    rep = run(sys.argv[1], tf)
    print(f"\nOrder Blocks + canal + EMAs  {rep['file']}  {tf}  ({rep['obs_detected']} entradas por retest)")
    print("  TRAIN:", _fmt(rep["train"]))
    print("  TEST :", _fmt(rep["test"]), " <-- fuera de muestra")
    if rep["mc_test"]:
        print("  MC(test):", {k: round(v, 3) if isinstance(v, float) else v
                              for k, v in list(rep["mc_test"].items())[:6]})
    print(f"\nReport -> {OUT/'orderblocks.json'}")
