"""
gm_confluence.py — Motor de CONFLUENCIAS: combina señales SMC/TA y busca la mejor mezcla.

Señales (voto direccional +1/-1/0 por vela, causal):
  CONTEXTO (persistente, filtra tendencia):
    ema       EMA50 vs EMA200 + precio vs EMA200
    channel   pendiente del canal de regresión
    momentum  signo del momentum de 12 velas
  GATILLOS (evento puntual que dispara la entrada):
    ob        retest de un Order Block de impulso FUERTE (disp>=2.5 ATR)
    fvg       retest de un Fair Value Gap de 3 velas
    wyckoff   spring (barrido del mínimo previo y recuperación) / upthrust
    sr        rebote en soporte/resistencia (swing previo)

Una ESTRATEGIA = 1 gatillo + un subconjunto de contexto que debe estar de acuerdo.
Se prueban todas esas combinaciones sobre datos reales (train/test) y la mejor se
valida con el laboratorio de robustez (espejo/tiempo/ruido). Así se evita el
espejismo de "probar mil cosas y quedarse con la que tuvo suerte".

Nota honesta: Elliott NO se incluye — su conteo de ondas es subjetivo y no se puede
codificar de forma reproducible sin introducir sesgo. Wyckoff se aproxima por su
huella objetiva (spring/upthrust = barrido de liquidez + recuperación).
"""
from __future__ import annotations

import itertools
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
CONTEXT = ("ema", "channel", "momentum")
TRIGGERS = ("ob", "fvg", "wyckoff", "sr")


def compute_signals(df, chan_len=50, disp_atr=2.5, swing=5):
    o = df["open"].to_numpy(float); h = df["high"].to_numpy(float)
    l = df["low"].to_numpy(float); c = df["close"].to_numpy(float)
    atr = go.atr(h, l, c); e50 = go.ema(c, 50); e200 = go.ema(c, 200)
    slope, mid, dev = go.rolling_reg(c, chan_len)
    sdir, swL, swH = go.structure(h, l, c, k=swing)
    n = len(c)
    ctx = {k: np.zeros(n, int) for k in CONTEXT}
    trg = {k: np.zeros(n, int) for k in TRIGGERS}
    # contexto (vectorizable)
    ctx["ema"] = np.where((c > e200) & (e50 > e200), 1, np.where((c < e200) & (e50 < e200), -1, 0))
    ctx["channel"] = np.where(slope > 0, 1, np.where(slope < 0, -1, 0))
    mom = c - np.r_[c[:12] * 0 + c[0], c[:-12]]
    ctx["momentum"] = np.sign(mom).astype(int)
    # gatillos (causales, con estado)
    bull_obs = []; bear_obs = []; last_down = None; last_up = None
    fvg_up = None; fvg_dn = None
    start = max(chan_len, 200, swing + 1) + 2
    for b in range(start, n):
        a = atr[b] if atr[b] > 0 else 1e-9
        if c[b - 1] < o[b - 1]: last_down = (l[b - 1], h[b - 1], b - 1)
        if c[b - 1] > o[b - 1]: last_up = (l[b - 1], h[b - 1], b - 1)
        # OB fuerte
        if np.isfinite(swH[b]) and c[b] > swH[b] and (c[b] - c[b - 1]) > disp_atr * a and last_down:
            bull_obs.append((last_down[0], last_down[1], b)); bull_obs = bull_obs[-50:]
        if np.isfinite(swL[b]) and c[b] < swL[b] and (c[b - 1] - c[b]) > disp_atr * a and last_up:
            bear_obs.append((last_up[0], last_up[1], b)); bear_obs = bear_obs[-50:]
        nb = []
        for lo, hi, bar in bull_obs:
            if c[b] < lo or (b - bar) > 60: continue
            if l[b] <= hi and h[b] >= lo and c[b] > lo and b > bar and trg["ob"][b] == 0:
                trg["ob"][b] = 1
            else: nb.append((lo, hi, bar))
        bull_obs = nb
        nx = []
        for lo, hi, bar in bear_obs:
            if c[b] > hi or (b - bar) > 60: continue
            if h[b] >= lo and l[b] <= hi and c[b] < hi and b > bar and trg["ob"][b] == 0:
                trg["ob"][b] = -1
            else: nx.append((lo, hi, bar))
        bear_obs = nx
        # FVG de 3 velas + retest
        if fvg_up and b - fvg_up[2] <= 12 and l[b] <= fvg_up[1] and c[b] > fvg_up[1]:
            trg["fvg"][b] = 1; fvg_up = None
        if fvg_dn and b - fvg_dn[2] <= 12 and h[b] >= fvg_dn[0] and c[b] < fvg_dn[0]:
            trg["fvg"][b] = -1; fvg_dn = None
        if l[b] > h[b - 2] and c[b - 1] > o[b - 1]: fvg_up = (h[b - 2], l[b], b)
        if h[b] < l[b - 2] and c[b - 1] < o[b - 1]: fvg_dn = (h[b], l[b - 2], b)
        # Wyckoff spring / upthrust (barrido de liquidez a 20 velas)
        lo20 = l[b - 20:b].min() if b >= 20 else l[:b].min()
        hi20 = h[b - 20:b].max() if b >= 20 else h[:b].max()
        if l[b] < lo20 and c[b] > lo20: trg["wyckoff"][b] = 1
        elif h[b] > hi20 and c[b] < hi20: trg["wyckoff"][b] = -1
        # S/R: rebote en swing previo
        if np.isfinite(swL[b]) and l[b] <= swL[b] and c[b] > swL[b]: trg["sr"][b] = 1
        elif np.isfinite(swH[b]) and h[b] >= swH[b] and c[b] < swH[b]: trg["sr"][b] = -1
    return dict(o=o, h=h, l=l, c=c, atr=atr, spread=df["spread"].to_numpy(float), ctx=ctx, trg=trg)


def build_orders(sig, trigger, context_subset, rr=2.0, sl_atr=1.5):
    c = sig["c"]; atr = sig["atr"]; n = len(c)
    tr = sig["trg"][trigger]
    orders = []
    last_dir = 0
    for b in range(1, n):
        d = tr[b]
        if d == 0: continue
        if context_subset and not all(sig["ctx"][k][b] == d for k in context_subset): continue
        if d == last_dir and orders and b - orders[-1][0] < 5: continue  # evita ráfagas
        a = atr[b] if atr[b] > 0 else 1e-9
        entry = c[b]; stop = entry - d * sl_atr * a; risk = sl_atr * a
        orders.append((b, d, entry, stop, entry + d * rr * risk, risk)); last_dir = d
    return orders


def _m(trades, start=50.0):
    if not trades: return dict(n=0)
    R = np.array([t[1] for t in trades]); risk = np.array([t[2] for t in trades]); pnl = R * risk
    eq = equity_path(pnl, start); peak = np.maximum.accumulate(eq)
    w, l = pnl[pnl > 0].sum(), -pnl[pnl < 0].sum()
    return dict(n=int(len(R)), win_rate=float((R > 0).mean() * 100), expectancy_R=float(R.mean()),
                profit_factor=float(w / l) if l > 0 else 9.9,
                return_pct=float((eq[-1] - start) / start * 100))


def _sim(feats, orders, split, n, maxbars=48):
    pk = lambda r: [(x[0], x[1], x[2]) for x in r]
    tr = pk(simulate_orders(feats, orders, POINT, maxbars, 0, 0, 0, 0, 0, split))
    te = pk(simulate_orders(feats, orders, POINT, maxbars, 0, 0, 0, 0, split, n))
    return _m(tr), _m(te), te


def run(csv_path, tf="H1", rr=2.0, split_frac=0.70):
    bars = resample(load_mt5(csv_path), tf)
    sig = compute_signals(bars)
    feats = {k: sig[k] for k in ("o", "h", "l", "c", "spread")}
    n = len(sig["c"]); split = int(n * split_frac)
    rows = []
    for trig in TRIGGERS:
        for r in range(0, len(CONTEXT) + 1):
            for ctxsub in itertools.combinations(CONTEXT, r):
                orders = build_orders(sig, trig, ctxsub, rr=rr)
                if len(orders) < 40: continue
                mt, me, _ = _sim(feats, orders, split, n)
                if me["n"] < 25 or mt["n"] < 25: continue
                robust = mt["expectancy_R"] > 0 and me["expectancy_R"] > 0 and me["profit_factor"] > 1
                rows.append(dict(trigger=trig, context=list(ctxsub), train=mt, test=me, robust=bool(robust)))
    rows.sort(key=lambda x: (not x["robust"], -(x["test"]["expectancy_R"])))
    rep = dict(file=Path(csv_path).name, tf=tf, rr=rr, combos=len(rows),
               robust=[r for r in rows if r["robust"]], top=rows[:12])
    (OUT / "confluence.json").write_text(json.dumps(rep, indent=2, ensure_ascii=False), encoding="utf-8")
    return rep


def _line(r):
    mt, me = r["train"], r["test"]
    ctx = "+".join(r["context"]) or "sin-contexto"
    return (f"{r['trigger']:8s} x [{ctx:24s}] TRAIN {mt['expectancy_R']:+.3f}/n{mt['n']:4d} | "
            f"TEST {me['expectancy_R']:+.3f}/PF{me['profit_factor']:.2f}/n{me['n']:4d}/WR{me['win_rate']:.0f}%")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("uso: python gm_confluence.py <M1_o_H1.csv> [TF=H1]"); raise SystemExit(2)
    tf = sys.argv[2] if len(sys.argv) > 2 else "H1"
    rep = run(sys.argv[1], tf)
    print(f"\nConfluencias — {rep['file']} {tf}  ({rep['combos']} combinaciones válidas)")
    print(f"ROBUSTAS (train>0 Y test>0 Y PF>1): {len(rep['robust'])}")
    print("\n=== TOP por expectancy OOS ===")
    for r in rep["top"]:
        print(("*R* " if r["robust"] else "    ") + _line(r))
    print(f"\nReport -> {OUT/'confluence.json'}")
