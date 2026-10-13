"""
gm_capital.py — Gestión de capital POR ETAPAS para capitalizar cuentas pequeñas.

Filosofía del usuario: empezar una cuenta de ~$10 operando lento y poco, asegurando
ganancias de $2-5, hasta llegar a ~$50; a partir de ahí arriesgar más.

Se modela como una escalera de etapas por EQUITY. Cada etapa fija:
  risk_pct        — riesgo por operación como % del equity actual
  daily_target    — al alcanzar esta ganancia en el día, se "guarda" y no se opera más
  daily_loss      — al alcanzar esta pérdida en el día, se para (protección)
  max_trades_day  — tope de operaciones por día
Cuando el equity cruza el umbral de una etapa, se cambia de etapa automáticamente.

Suelo de LOTE MÍNIMO: en XAUUSD el lote mínimo ya arriesga varios dólares; solo en
símbolos micro/cent (p.ej. XAUUSDmicro: 0.1 lot ≈ $0.10 por cada $1 de precio) cabe
arriesgar $0.2-0.6 en una cuenta de $10. `value_per_minlot` parametriza eso. Si el
riesgo del lote mínimo supera `max_risk_frac` del equity, la operación se OMITE (no
se puede dimensionar hacia abajo) — refleja la realidad, no la esconde.

Reutiliza las operaciones de la estrategia KEEP (gm_optimizer PRO Signals) sobre datos
reales. Investigación; no opera ni promete rentabilidad.
"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass, asdict
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "optimizer"))
sys.path.insert(0, str(HERE))

import gm_optimizer as go                       # noqa: E402
from mt5_import import load_mt5, resample        # noqa: E402

OUT = HERE / "out_offline"; OUT.mkdir(exist_ok=True)
POINT = 0.01


@dataclass
class Stage:
    name: str
    equity_from: float
    equity_to: float          # inf = última
    risk_pct: float           # % del equity por operación
    daily_target: float       # $ ganados en el día -> guardar y parar
    daily_loss: float         # $ perdidos en el día -> parar
    max_trades_day: int


# Escalera por defecto: lento y conservador hasta $50, luego agresivo.
DEFAULT_STAGES = [
    Stage("semilla $10-$25", 0.0, 25.0, risk_pct=3.0, daily_target=2.0, daily_loss=1.5, max_trades_day=3),
    Stage("construir $25-$50", 25.0, 50.0, risk_pct=3.5, daily_target=4.0, daily_loss=2.5, max_trades_day=4),
    Stage("acelerar $50+", 50.0, float("inf"), risk_pct=6.0, daily_target=12.0, daily_loss=8.0, max_trades_day=6),
]


def _stage_for(equity, stages):
    for s in stages:
        if s.equity_from <= equity < s.equity_to:
            return s
    return stages[-1]


def pro_signals_trades(m1):
    """Operaciones de la estrategia KEEP, en orden, con (día, R, riesgo_en_precio)."""
    m15 = resample(m1, "M15")
    f = go.features(m1[["time", "open", "high", "low", "close", "spread"]],
                    m15[["time", "open", "high", "low", "close", "spread"]])
    P = dict(fast=34, slow=89, minscore=5, tp=1.5, slatr=1.2, be=1.5, lock=0.3,
             chdev=2.0, session=False, maxbars=240)
    res = sorted(go.simulate(f, P, go.signals(f, P), POINT), key=lambda x: x[0])
    t = pd.to_datetime(m1["time"]).dt.normalize().to_numpy()
    out = []
    for x in res:
        b = x[0]
        if b < len(t):
            out.append((pd.Timestamp(t[b]), float(x[1]), float(x[2])))   # (day, R, risk_price)
    return out


def simulate_staged(trades, start=10.0, stages=None, value_per_minlot=0.10,
                    max_risk_frac=0.5, ruin=5.0):
    """Simula el equity aplicando la escalera de etapas, día a día.

    value_per_minlot = USD por cada 1.0 de precio con el LOTE MÍNIMO del símbolo
    (XAUUSDmicro ≈ 0.10). pnl = R * riesgo_$; riesgo_$ = clamp(risk_pct*equity,
    piso de lote mínimo, max_risk_frac*equity). Si el piso supera el techo -> omite.
    """
    stages = stages or DEFAULT_STAGES
    eq = start
    curve = [eq]
    day = None; day_pnl = 0.0; day_trades = 0
    reached_50 = None; n_taken = 0; n_skipped = 0
    peak = eq; max_dd = 0.0
    for i, (d, R, risk_price) in enumerate(trades):
        if d != day:
            day = d; day_pnl = 0.0; day_trades = 0
        s = _stage_for(eq, stages)
        if day_trades >= s.max_trades_day:      # tope diario de operaciones
            continue
        if day_pnl >= s.daily_target or day_pnl <= -s.daily_loss:  # objetivo/stop diario
            continue
        min_risk = value_per_minlot * risk_price           # lote mínimo irreducible
        want_risk = s.risk_pct / 100.0 * eq
        if min_risk > max_risk_frac * eq:                  # ni el lote mínimo cabe -> omitir
            n_skipped += 1
            continue
        risk_usd = max(want_risk, min_risk)
        pnl = R * risk_usd
        eq += pnl; day_pnl += pnl; day_trades += 1; n_taken += 1
        curve.append(eq)
        peak = max(peak, eq); max_dd = max(max_dd, (peak - eq) / peak * 100)
        if reached_50 is None and eq >= 50.0:
            reached_50 = dict(trade=n_taken, date=str(d.date()))
        if eq <= ruin:
            return dict(ruined=True, final=eq, trades=n_taken, skipped=n_skipped,
                        reached_50=reached_50, max_dd=max_dd, curve=curve)
    return dict(ruined=False, final=float(eq), trades=n_taken, skipped=n_skipped,
                reached_50=reached_50, max_dd=float(max_dd), curve=curve)


def montecarlo_paths(trades, runs=3000, start=10.0, stages=None, value_per_minlot=0.10, seed=11):
    """Baraja el ORDEN de las operaciones (bootstrap) y mide P(llegar a $50) y P(ruina)."""
    rng = np.random.default_rng(seed)
    arr = trades[:]
    finals, hit50, ruined, t50 = [], 0, 0, []
    for _ in range(runs):
        order = rng.permutation(len(arr))
        shuffled = [arr[i] for i in order]
        r = simulate_staged(shuffled, start, stages, value_per_minlot)
        finals.append(r["final"])
        if r["reached_50"]:
            hit50 += 1; t50.append(r["reached_50"]["trade"])
        if r["ruined"]:
            ruined += 1
    finals = np.array(finals)
    return dict(runs=runs, p_hit50=hit50 / runs * 100, p_ruin=ruined / runs * 100,
                final_p5=float(np.percentile(finals, 5)), final_p50=float(np.percentile(finals, 50)),
                final_p95=float(np.percentile(finals, 95)),
                median_trades_to_50=(float(np.median(t50)) if t50 else None))


def run(csv_path, start=10.0, value_per_minlot=0.10):
    m1 = load_mt5(csv_path)
    trades = pro_signals_trades(m1)
    base = simulate_staged(trades, start, value_per_minlot=value_per_minlot)
    mc = montecarlo_paths(trades, start=start, value_per_minlot=value_per_minlot)
    rep = dict(start=start, value_per_minlot=value_per_minlot,
               stages=[asdict(s) for s in DEFAULT_STAGES],
               n_trades_available=len(trades),
               chronological=dict(final=base["final"], trades=base["trades"], skipped=base["skipped"],
                                  reached_50=base["reached_50"], max_dd=base["max_dd"], ruined=base["ruined"]),
               montecarlo=mc)
    (OUT / "capital_plan.json").write_text(json.dumps(rep, indent=2, ensure_ascii=False), encoding="utf-8")
    # curva para graficar
    np.save(OUT / "capital_curve.npy", np.array(base["curve"]))
    return rep


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("uso: python gm_capital.py <XAUUSD_M1.csv> [start=10] [value_per_minlot=0.10]"); raise SystemExit(2)
    start = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
    vpm = float(sys.argv[3]) if len(sys.argv) > 3 else 0.10
    r = run(sys.argv[1], start, vpm)
    print(f"\nPlan de capitalización desde ${r['start']:.0f}  (XAUUSDmicro, ${vpm:.2f}/$ a lote mínimo)")
    print("Escalera de etapas:")
    for s in r["stages"]:
        hi = "∞" if s["equity_to"] == float("inf") else f"${s['equity_to']:.0f}"
        print(f"  {s['name']:18s} riesgo {s['risk_pct']}%/op · objetivo diario ${s['daily_target']} · "
              f"stop diario ${s['daily_loss']} · máx {s['max_trades_day']} ops/día")
    c = r["chronological"]
    print(f"\nRecorrido cronológico ({r['n_trades_available']} señales disponibles):")
    print(f"  equity final ${c['final']:.2f} | ops tomadas {c['trades']} | omitidas {c['skipped']} | "
          f"maxDD {c['max_dd']:.0f}% | {'RUINA' if c['ruined'] else 'vivo'}")
    print(f"  llegó a $50: {c['reached_50']}")
    mc = r["montecarlo"]
    print(f"\nMonte Carlo ({mc['runs']} órdenes barajadas) desde ${r['start']:.0f}:")
    print(f"  P(llegar a $50) = {mc['p_hit50']:.1f}%   P(ruina<$5) = {mc['p_ruin']:.1f}%")
    print(f"  equity final  p5 ${mc['final_p5']:.1f} · mediana ${mc['final_p50']:.1f} · p95 ${mc['final_p95']:.1f}")
    if mc["median_trades_to_50"]:
        print(f"  operaciones medianas para llegar a $50: {mc['median_trades_to_50']:.0f}")
    print(f"\nReport -> {OUT/'capital_plan.json'}")
