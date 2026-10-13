"""
gm_research.py — Búsqueda ROBUSTA de parámetros rentables (anti-overfitting).

Problema demostrado: una config puede verse rentable en 3,5 meses reales por
suerte de muestra pequeña y ser basura con muchas operaciones. Aquí se exige que
una config sea positiva en DOS arenas a la vez:

  REAL    — tramo test (30% final) del M1 real del usuario (tiene tendencia real,
            pero pocas operaciones).
  SINTET  — 5 años sintéticos (block bootstrap): MUCHAS operaciones (robustez al
            ruido y a la reversión), aunque sin tendencias largas reales.

Una config que gana en ambas es mucho más creíble que una que solo brilla en una.
Se barren rejillas de dos familias:
  * pro_signals (gm_optimizer): DEMA cross + score multi-confluencia (M1).
  * channels_smc (gm_channels_smc): canal + rompimiento + OB + estructura (H1).

Veredicto ROBUST si: SINTET test expectancy>0 y PF>1 con n>=50 y p_ruin<0.5,
Y ADEMÁS REAL test expectancy>0 con n>=10. Si ninguna pasa, se reporta honestamente.
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
import gm_channels_smc as ch                                # noqa: E402
from gm_validation import simulate_orders, equity_path, bootstrap_metrics  # noqa: E402
from mt5_import import load_mt5, resample                   # noqa: E402

OUT = HERE / "out_offline"; OUT.mkdir(exist_ok=True)
POINT = 0.01


def _m(trades):
    if not trades:
        return dict(n=0, exp=-9.0, pf=0.0, ret=-999.0, dd=999.0)
    R = np.array([t[1] for t in trades]); risk = np.array([t[2] for t in trades]); pnl = R * risk
    eq = equity_path(pnl, 50.0); peak = np.maximum.accumulate(eq)
    w, l = pnl[pnl > 0].sum(), -pnl[pnl < 0].sum()
    return dict(n=int(len(R)), exp=float(R.mean()), pf=float(w / l) if l > 0 else 9.9,
                ret=float((eq[-1] - 50) / 50 * 100), dd=float(((peak - eq) / peak).max() * 100))


def _ruin(trades):
    if len(trades) < 10:
        return 1.0
    pnl = np.array([t[1] * t[2] for t in trades])
    return float(bootstrap_metrics(pnl, 50.0, 25.0, np.random.default_rng(5), runs=1500).get("p_ruin", 1.0))


# ───────── pro_signals ─────────
def pro_features(csv):
    m1 = load_mt5(csv); m15 = resample(m1, "M15")
    f = go.features(m1[["time", "open", "high", "low", "close", "spread"]],
                    m15[["time", "open", "high", "low", "close", "spread"]])
    return f, len(m1)


def eval_pro(f, n, P, split_frac=0.70):
    sg = go.signals(f, P); split = int(n * split_frac)
    pk = lambda res: [(x[0], x[1], x[2]) for x in res]
    tr = pk(go.simulate(f, P, sg, POINT, 0, split)); te = pk(go.simulate(f, P, sg, POINT, split, n))
    return _m(tr), _m(te), te


PRO_GRID = dict(fast=[13, 21, 34], slow=[55, 89, 144], minscore=[3, 4, 5], tp=[1.5, 2.0, 3.0],
                slatr=[1.0, 1.5], be=[1.5], lock=[0.3], chdev=[2.0], session=[False], maxbars=[240])


def search_pro(real_csv, synth_csv):
    fr, nr = pro_features(real_csv); fs, ns = pro_features(synth_csv)
    rows = []
    keys = list(PRO_GRID)
    for vals in itertools.product(*PRO_GRID.values()):
        P = dict(zip(keys, vals))
        if P["fast"] >= P["slow"]:
            continue
        _, r_te, _ = eval_pro(fr, nr, P)
        s_tr, s_te, s_te_tr = eval_pro(fs, ns, P)
        if s_te["n"] < 50:
            continue
        robust = (s_te["exp"] > 0 and s_te["pf"] > 1 and r_te["exp"] > 0 and r_te["n"] >= 10)
        rows.append(dict(family="pro_signals", params={k: P[k] for k in ("fast", "slow", "minscore", "tp", "slatr")},
                         real_test=r_te, synth_test=s_te,
                         ruin=_ruin(s_te_tr) if robust else None, robust=bool(robust)))
    return rows


# ───────── channels_smc ─────────
CH_GRID = dict(chan_len=[30, 50, 80], band_k=[1.5, 2.0, 2.5], rr=[1.5, 2.0, 3.0],
               slatr=[1.0], maxbars=[48], ob_displacement=[0.8, 1.2], ob_max_age=[20])


def eval_ch(bars, P, split_frac=0.70):
    feats, orders = ch.build_orders(bars, P)
    n = len(bars["close"]); split = int(n * split_frac)
    pk = lambda res: [(x[0], x[1], x[2]) for x in res]
    tr = pk(simulate_orders(feats, orders, POINT, P["maxbars"], 0, 0, 0, 0, 0, split))
    te = pk(simulate_orders(feats, orders, POINT, P["maxbars"], 0, 0, 0, 0, split, n))
    return _m(tr), _m(te), te


def search_ch(real_csv, synth_csv, tf="H1"):
    br = resample(load_mt5(real_csv), tf); bs = resample(load_mt5(synth_csv), tf)
    rows = []; keys = list(CH_GRID)
    for vals in itertools.product(*CH_GRID.values()):
        P = {**ch.DEFAULTS, **dict(zip(keys, vals))}
        _, r_te, _ = eval_ch(br, P)
        s_tr, s_te, s_te_tr = eval_ch(bs, P)
        if s_te["n"] < 50:
            continue
        robust = (s_te["exp"] > 0 and s_te["pf"] > 1 and r_te["exp"] > 0 and r_te["n"] >= 10)
        rows.append(dict(family="channels_smc", params={k: P[k] for k in ("chan_len", "band_k", "rr", "ob_displacement")},
                         real_test=r_te, synth_test=s_te,
                         ruin=_ruin(s_te_tr) if robust else None, robust=bool(robust)))
    return rows


def run(real_csv, synth_csv):
    rows = search_pro(real_csv, synth_csv) + search_ch(real_csv, synth_csv)
    # orden: robustas primero, luego por expectancy sintética (muestra grande)
    rows.sort(key=lambda r: (not r["robust"], -r["synth_test"]["exp"]))
    robust = [r for r in rows if r["robust"]]
    rep = dict(evaluated=len(rows), robust_count=len(robust),
               robust=robust[:20], top_overall=rows[:15])
    (OUT / "research.json").write_text(json.dumps(rep, indent=2, ensure_ascii=False), encoding="utf-8")
    return rep


def _line(r):
    rt, st = r["real_test"], r["synth_test"]
    return (f"{r['family']:13s} {str(r['params'])[:52]:52s} | SINT n={st['n']:4d} exp={st['exp']:+.3f} PF={st['pf']:.2f}"
            f" | REAL n={rt['n']:3d} exp={rt['exp']:+.3f}"
            + (f" | ruin={r['ruin']:.2f}" if r['ruin'] is not None else ""))


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("uso: python gm_research.py <real_M1.csv> <synth_M1.csv>"); raise SystemExit(2)
    rep = run(sys.argv[1], sys.argv[2])
    print(f"\nEvaluadas {rep['evaluated']} configs. ROBUSTAS (positivas en real Y sintético): {rep['robust_count']}")
    if rep["robust"]:
        print("\n=== CONFIGS ROBUSTAS ===")
        for r in rep["robust"]:
            print(" ", _line(r))
    print("\n=== TOP por expectancy sintética (muestra grande) ===")
    for r in rep["top_overall"]:
        print(("*R* " if r["robust"] else "    ") + _line(r))
    print(f"\nReport -> {OUT/'research.json'}")
