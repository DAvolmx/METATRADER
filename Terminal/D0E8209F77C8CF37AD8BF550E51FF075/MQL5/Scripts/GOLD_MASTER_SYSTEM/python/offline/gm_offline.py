"""
gm_offline.py — Backtest + validación GOLD MASTER SIN MetaTrader5, con datos CSV/Excel.

Reutiliza EXACTAMENTE la lógica del repo:
  * estrategia PRO Signals M1  (gm_optimizer.features / signals / simulate / stats)
  * motor de ejecución vela-a-vela con costes (gm_validation.simulate_orders)
  * Monte Carlo bootstrap estacionario (gm_validation.bootstrap_metrics)
  * ML meta-labeling honesto, umbral fijo, etiquetas purgadas (gm_optimizer.train_ml)

Flujo:
  1. importa M1 real con offline.mt5_import
  2. deriva M15 por reagregación (features necesita M1 + M15)
  3. train/test 70/30 cronológico (sin barajar)  → genera señales en TODO el set,
     simula train y test por separado con límites de ventana (purga el trade que
     cruza el límite)  → métricas fuera de muestra REALES
  4. Monte Carlo sobre el PnL de las operaciones de test
  5. (opcional) ML meta-labeling: ¿filtra el modelo las señales malas?
  6. escribe report JSON + series para graficar (equity, velas) en ./out_offline

Nada aquí despliega parámetros a un EA ni promete rentabilidad: es investigación.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
OPT = HERE.parent / "optimizer"
sys.path.insert(0, str(OPT))
sys.path.insert(0, str(HERE))

import gm_optimizer as go            # noqa: E402  (mt5 opcional: el módulo ya lo tolera)
from gm_validation import split_trades, equity_path, bootstrap_metrics  # noqa: E402
from mt5_import import load_mt5, resample  # noqa: E402

OUT = HERE / "out_offline"
OUT.mkdir(exist_ok=True)

# Parámetros por defecto de la estrategia (dentro del GRID de investigación de gm_retrain).
DEFAULT_P = dict(fast=21, slow=55, minscore=4, tp=2.0, slatr=1.2,
                 be=1.5, lock=0.3, chdev=2.0, session=False, maxbars=240)

# XAUUSD estándar: 1 punto = 0.01 $, 0.01 lote = 1 oz → 1.0 USD por cada 1.0 $ de precio.
POINT = 0.01
USD_PER_PRICE = 1.0
START_EQ, RUIN_EQ = float(os.getenv("GM_START", "50")), float(os.getenv("GM_RUIN", "25"))


def _stats_usd(res, usd_per_price, start, ruin):
    """Métricas en dólares para un lote mínimo fijo, a partir de TradeResult."""
    if not res:
        return dict(n=0)
    r = np.array([x[1] for x in res])            # R múltiplos netos
    risk = np.array([x[2] for x in res])
    pnl = r * risk * usd_per_price
    eq = equity_path(pnl, start)
    peak = np.maximum.accumulate(eq)
    dd = float(((peak - eq) / peak).max() * 100) if len(eq) else 0.0
    wins, losses = pnl[pnl > 0], pnl[pnl < 0]
    return dict(
        n=int(len(r)),
        win_rate=float((r > 0).mean() * 100),
        expectancy_R=float(r.mean()),
        profit_factor=float(wins.sum() / -losses.sum()) if losses.size else float("inf"),
        net_usd=float(pnl.sum()),
        return_pct=float((eq[-1] - start) / start * 100),
        max_dd_pct=dd,
        final_equity=float(eq[-1]),
        ruin=bool((eq <= ruin).any()),
        sqn=float(r.mean() / r.std() * np.sqrt(min(len(r), 100))) if r.std() > 0 else 0.0,
    )


def run(csv_path: str, params: dict | None = None, split_frac: float = 0.70,
        with_ml: bool = True, seed: int = 42) -> dict:
    P = {**DEFAULT_P, **(params or {})}
    m1 = load_mt5(csv_path)
    m15 = resample(m1, "M15")
    # features() espera DataFrames con columnas time/open/high/low/close/spread
    f = go.features(m1[["time", "open", "high", "low", "close", "spread"]],
                    m15[["time", "open", "high", "low", "close", "spread"]])

    sigs = go.signals(f, P)
    split_bar = int(len(m1) * split_frac)

    all_res = go.simulate(f, P, sigs, POINT)
    train_res = go.simulate(f, P, sigs, POINT, start_bar=0, end_bar=split_bar)
    test_res = go.simulate(f, P, sigs, POINT, start_bar=split_bar, end_bar=len(m1))

    report = {
        "data": {
            "file": Path(csv_path).name,
            "bars_m1": int(len(m1)),
            "bars_m15": int(len(m15)),
            "from": str(m1["time"].iloc[0]),
            "to": str(m1["time"].iloc[-1]),
            "price_min": float(m1["low"].min()),
            "price_max": float(m1["high"].max()),
            "spread_mean": float(m1["spread"].mean()),
        },
        "params": P,
        "split": {"frac": split_frac, "split_bar": split_bar,
                  "train_bars": split_bar, "test_bars": int(len(m1) - split_bar)},
        "signals_total": int(len(sigs)),
        "metrics": {
            "all": _stats_usd(all_res, USD_PER_PRICE, START_EQ, RUIN_EQ),
            "train": _stats_usd(train_res, USD_PER_PRICE, START_EQ, RUIN_EQ),
            "test_oos": _stats_usd(test_res, USD_PER_PRICE, START_EQ, RUIN_EQ),
        },
        "assumptions": {
            "point": POINT, "usd_per_price": USD_PER_PRICE,
            "start_equity": START_EQ, "ruin_equity": RUIN_EQ,
            "note": ("backtest por velas (no por ticks); spread real del fichero; "
                     "sin comisión ni swap salvo que se parametrice. "
                     "3,5 meses NO bastan para afirmar rentabilidad: es una medición, no una promesa."),
        },
    }

    # Monte Carlo bootstrap sobre el PnL de TEST (fuera de muestra)
    if test_res:
        pnl = np.array([x[1] * x[2] * USD_PER_PRICE for x in test_res])
        if len(pnl) >= 10:
            mc = bootstrap_metrics(pnl, START_EQ, RUIN_EQ, np.random.default_rng(seed), runs=5000)
            report["montecarlo_test"] = {k: (float(v) if isinstance(v, (int, float, np.floating)) else v)
                                         for k, v in mc.items()}

    # ML meta-labeling (umbral fijo, sin exportar modelo)
    if with_ml:
        try:
            ml = go.train_ml(f, all_res, split_bar, threshold=0.5, export=False)
            report["ml_metalabel"] = ml
        except Exception as e:  # sklearn ausente o pocas muestras
            report["ml_metalabel"] = {"error": str(e)}

    # Series para graficar
    eq_all = equity_path(np.array([x[1] * x[2] * USD_PER_PRICE for x in all_res]), START_EQ) \
        if all_res else np.array([START_EQ])
    (OUT / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    np.save(OUT / "equity_all.npy", eq_all)
    # velas M15 + marcas de operaciones para el gráfico web
    trades = [{"signal_bar": int(x[0]), "dir": int(np.sign(x[1])) if False else int(x[1] > 0) * 2 - 1,
               "R": float(x[1])} for x in all_res]
    (OUT / "trades.json").write_text(json.dumps(trades, ensure_ascii=False), encoding="utf-8")
    m15.assign(time=m15["time"].astype(str)).to_json(OUT / "m15.json", orient="records")
    return report


def _fmt(m: dict) -> str:
    if not m or m.get("n", 0) == 0:
        return "  (sin operaciones)"
    return (f"  ops={m['n']}  winrate={m['win_rate']:.1f}%  PF={m['profit_factor']:.2f}  "
            f"exp={m['expectancy_R']:.3f}R  net=${m['net_usd']:.2f}  ret={m['return_pct']:.1f}%  "
            f"DD={m['max_dd_pct']:.1f}%  SQN={m['sqn']:.2f}  ruina={m['ruin']}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("uso: python gm_offline.py <XAUUSD_M1.csv|xlsx>"); raise SystemExit(2)
    rep = run(sys.argv[1])
    d = rep["data"]
    print(f"\nDatos: {d['bars_m1']} M1  {d['from']} -> {d['to']}  "
          f"({d['price_min']:.2f}-{d['price_max']:.2f}, spread~{d['spread_mean']:.1f})")
    print(f"Señales: {rep['signals_total']}  |  split {int(rep['split']['frac']*100)}/"
          f"{int((1-rep['split']['frac'])*100)} en barra {rep['split']['split_bar']}")
    print("TODO :", _fmt(rep["metrics"]["all"]))
    print("TRAIN:", _fmt(rep["metrics"]["train"]))
    print("TEST :", _fmt(rep["metrics"]["test_oos"]), "  <-- fuera de muestra")
    if "montecarlo_test" in rep:
        mc = rep["montecarlo_test"]
        print("Monte Carlo (test):", {k: round(v, 3) if isinstance(v, float) else v
                                       for k, v in list(mc.items())[:8]})
    if "ml_metalabel" in rep:
        print("ML meta-label:", rep["ml_metalabel"])
    print(f"\nReport -> {OUT/'report.json'}")
