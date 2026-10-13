"""
gm_tournament.py — Torneo de backtest de estrategias sobre datos reales.

Mide las 10 estrategias del catálogo H1 (gm_strategy_catalog) + la PRO Signals M1
(gm_optimizer) sobre el M1 importado, con split train/test cronológico y Monte
Carlo bootstrap del PnL fuera de muestra. Emite un ranking y un veredicto:

    KEEP  — rentable fuera de muestra (expectancy>0, profit factor>1) con nº de
            operaciones suficiente y riesgo de ruina bajo en Monte Carlo.
    WEAK  — señal pobre o muestra insuficiente (ni claramente buena ni basura).
    JUNK  — pierde fuera de muestra.

Decide sobre lo que SÍ se puede ejecutar aquí (estrategias en Python). Los EAs .mq5
no se pueden backtestear sin MetaTrader5 (solo Windows); su limpieza se decide aparte.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "optimizer"))
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import gm_optimizer as go                              # noqa: E402
import gm_strategy_catalog as cat                      # noqa: E402
from gm_validation import simulate_orders, equity_path, bootstrap_metrics  # noqa: E402
from mt5_import import load_mt5, resample              # noqa: E402

OUT = HERE / "out_offline"; OUT.mkdir(exist_ok=True)
POINT, USD_PER_PRICE = 0.01, 1.0
START_EQ, RUIN_EQ = 50.0, 25.0
MIN_TRADES = 25           # por debajo de esto la muestra no decide
H1_MAXBARS = 48           # ~2 días en H1


def _metrics(trades, start=START_EQ):
    if not trades:
        return dict(n=0)
    R = np.array([t[1] for t in trades]); risk = np.array([t[2] for t in trades])
    pnl = R * risk * USD_PER_PRICE
    eq = equity_path(pnl, start); peak = np.maximum.accumulate(eq)
    dd = float(((peak - eq) / peak).max() * 100) if len(eq) else 0.0
    wins, losses = pnl[pnl > 0], pnl[pnl < 0]
    return dict(n=int(len(R)), win_rate=float((R > 0).mean() * 100),
                expectancy_R=float(R.mean()), total_R=float(R.sum()),
                profit_factor=float(wins.sum() / -losses.sum()) if losses.size else float("inf"),
                return_pct=float((eq[-1] - start) / start * 100), max_dd_pct=dd,
                sqn=float(R.mean() / R.std() * np.sqrt(min(len(R), 100))) if R.std() > 0 else 0.0)


def _verdict(test, mc):
    if not test or test.get("n", 0) < MIN_TRADES:
        return "WEAK"
    if test["expectancy_R"] > 0 and test["profit_factor"] > 1.0 and (mc is None or mc.get("p_ruin", 1) < 0.5):
        return "KEEP"
    if test["expectancy_R"] <= 0 or test["profit_factor"] < 1.0:
        return "JUNK"
    return "WEAK"


def _mc(trades_test, seed=7):
    if len(trades_test) < 10:
        return None
    pnl = np.array([t[1] * t[2] * USD_PER_PRICE for t in trades_test])
    m = bootstrap_metrics(pnl, START_EQ, RUIN_EQ, np.random.default_rng(seed), runs=3000)
    return {k: (float(v) if isinstance(v, (int, float, np.floating)) else v) for k, v in m.items()}


def run_catalog(m1, split_frac=0.70):
    h1 = resample(m1, "H1")
    f, sigs = cat.signals(h1)
    feats = {k: np.asarray(f[k], float) for k in ("open", "high", "low", "close", "spread")}
    feats = {"o": feats["open"], "h": feats["high"], "l": feats["low"], "c": feats["close"], "spread": feats["spread"]}
    split = int(len(h1) * split_frac)
    rows = []
    for name, (desc, rr) in cat.CATALOG.items():
        orders = sigs[name]
        tr = simulate_orders(feats, orders, POINT, H1_MAXBARS, 0.0, 0.0, 0.0, 0.0, 0, split)
        te = simulate_orders(feats, orders, POINT, H1_MAXBARS, 0.0, 0.0, 0.0, 0.0, split, len(h1))
        mcte = _mc(te)
        test_m = _metrics(te)
        rows.append(dict(strategy=name, desc=desc, kind="catalog_H1",
                         train=_metrics(tr), test=test_m, mc_test=mcte, verdict=_verdict(test_m, mcte)))
    return rows, len(h1)


def run_pro_signals(m1, split_frac=0.70):
    m15 = resample(m1, "M15")
    f = go.features(m1[["time", "open", "high", "low", "close", "spread"]],
                    m15[["time", "open", "high", "low", "close", "spread"]])
    best = dict(fast=34, slow=89, minscore=5, tp=1.5, slatr=1.2, be=1.5, lock=0.3,
                chdev=2.0, session=False, maxbars=240)
    sg = go.signals(f, best)
    split = int(len(m1) * split_frac)
    def pack(res):
        return [(x[0], x[1], x[2]) for x in res]   # (bar, net_R, risk_price)
    tr = pack(go.simulate(f, best, sg, POINT, 0, split))
    te = pack(go.simulate(f, best, sg, POINT, split, len(m1)))
    mcte = _mc(te); test_m = _metrics(te)
    return dict(strategy="pro_signals_M1", desc="PRO Signals (DEMA 34/89, score>=5, TP1.5)",
                kind="pro_M1", train=_metrics(tr), test=test_m, mc_test=mcte, verdict=_verdict(test_m, mcte))


def run(csv_path, split_frac=0.70):
    m1 = load_mt5(csv_path)
    rows, nh1 = run_catalog(m1, split_frac)
    rows.append(run_pro_signals(m1, split_frac))
    # ranking: KEEP primero, luego por expectancy OOS
    order = {"KEEP": 0, "WEAK": 1, "JUNK": 2}
    rows.sort(key=lambda r: (order[r["verdict"]], -(r["test"].get("expectancy_R", -9) if r["test"] else -9)))
    rep = dict(data=dict(file=Path(csv_path).name, bars_m1=int(len(m1)), h1_bars=int(nh1),
                         frm=str(m1.time.iloc[0]), to=str(m1.time.iloc[-1])),
               split_frac=split_frac, min_trades=MIN_TRADES, ranking=rows,
               keep=[r["strategy"] for r in rows if r["verdict"] == "KEEP"],
               junk=[r["strategy"] for r in rows if r["verdict"] == "JUNK"],
               weak=[r["strategy"] for r in rows if r["verdict"] == "WEAK"])
    (OUT / "tournament.json").write_text(json.dumps(rep, indent=2, ensure_ascii=False), encoding="utf-8")
    return rep


def _fmt(m):
    if not m or m.get("n", 0) == 0:
        return "sin ops"
    return (f"n={m['n']:3d} exp={m['expectancy_R']:+.3f}R PF={m['profit_factor']:.2f} "
            f"ret={m['return_pct']:+.0f}% DD={m['max_dd_pct']:.0f}%")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("uso: python gm_tournament.py <XAUUSD_M1.csv>"); raise SystemExit(2)
    rep = run(sys.argv[1])
    d = rep["data"]
    print(f"\nTorneo sobre {d['bars_m1']} M1 ({d['h1_bars']} H1)  {d['frm']} -> {d['to']}")
    print(f"{'ESTRATEGIA':22s} {'VEREDICTO':8s} {'TEST (fuera de muestra)'}")
    print("-" * 78)
    for r in rep["ranking"]:
        print(f"{r['strategy']:22s} {r['verdict']:8s} {_fmt(r['test'])}")
    print("-" * 78)
    print("KEEP:", rep["keep"] or "—")
    print("WEAK:", rep["weak"] or "—")
    print("JUNK:", rep["junk"] or "—")
    print(f"\nReport -> {OUT/'tournament.json'}")
