"""
trading/statistics.py — Métricas de rendimiento.

Definiciones usadas (documentadas para que los resultados sean auditables):
  Profit Factor   = beneficio bruto / |pérdida bruta|
  Expectancy      = beneficio neto medio por operación
  Payoff Ratio    = ganancia media / |pérdida media|
  Max Drawdown    = máxima caída de la curva de EQUITY desde un máximo previo
  Sharpe / Sortino= sobre retornos DIARIOS de equity, anualizados con sqrt(252),
                    tasa libre de riesgo = 0. Requieren >= 2 días con datos.
  Calmar          = CAGR / MaxDD%   (requiere >= 1 día de histórico)
  Recovery Factor = beneficio neto / MaxDD
  MAE / MFE       = excursión adversa / favorable media, en múltiplos de R
Valor None => no calculable con los datos disponibles (se muestra N/A).
"""
from __future__ import annotations

import math
from typing import Optional

import numpy as np
import pandas as pd

from trading.trade_models import Trade, TradeStatus


def _streaks(values: list[float]) -> tuple[int, int]:
    best_w = best_l = cw = cl = 0
    for v in values:
        if v > 0:
            cw, cl = cw + 1, 0
        elif v < 0:
            cl, cw = cl + 1, 0
        else:
            cw = cl = 0
        best_w, best_l = max(best_w, cw), max(best_l, cl)
    return best_w, best_l


def drawdown_series(equity: pd.Series) -> tuple[pd.Series, pd.Series]:
    peak = equity.cummax()
    dd = equity - peak
    dd_pct = dd / peak.replace(0, np.nan) * 100
    return dd, dd_pct


def compute_statistics(trades: list[Trade], equity_curve: Optional[pd.DataFrame],
                       initial_balance: float) -> dict:
    closed = [t for t in trades if t.status == TradeStatus.CLOSED and t.profit is not None]
    profits = [t.profit for t in closed]
    wins = [p for p in profits if p > 0]
    losses = [p for p in profits if p < 0]
    n = len(closed)
    gp, gl = sum(wins), sum(losses)
    net = gp + gl
    rs = [t.r_multiple for t in closed if t.r_multiple is not None]
    cw, cl = _streaks(profits)

    def r_exc(t: Trade, v: float) -> Optional[float]:
        r = t.initial_risk
        return v / r if r else None

    maes = [x for x in (r_exc(t, t.mae) for t in closed) if x is not None]
    mfes = [x for x in (r_exc(t, t.mfe) for t in closed) if x is not None]
    risk_money = [abs(t.profit / t.r_multiple) for t in closed
                  if t.r_multiple not in (None, 0) and t.profit is not None]

    s = {
        "total_trades": n,
        "wins": len(wins),
        "losses": len(losses),
        "breakeven": n - len(wins) - len(losses),
        "win_rate": round(100 * len(wins) / n, 2) if n else None,
        "gross_profit": round(gp, 2),
        "gross_loss": round(gl, 2),
        "net_profit": round(net, 2),
        "profit_factor": round(gp / abs(gl), 3) if gl < 0 else None,
        "average_win": round(float(np.mean(wins)), 2) if wins else None,
        "average_loss": round(float(np.mean(losses)), 2) if losses else None,
        "expectancy": round(net / n, 2) if n else None,
        "average_r": round(float(np.mean(rs)), 3) if rs else None,
        "payoff_ratio": round(float(np.mean(wins)) / abs(float(np.mean(losses))), 3)
        if wins and losses else None,
        "consecutive_wins": cw,
        "consecutive_losses": cl,
        "avg_mae_r": round(float(np.mean(maes)), 3) if maes else None,
        "avg_mfe_r": round(float(np.mean(mfes)), 3) if mfes else None,
        "avg_risk_per_trade": round(float(np.mean(risk_money)), 2) if risk_money else None,
        "max_drawdown": None, "max_drawdown_pct": None, "sharpe": None,
        "sortino": None, "calmar": None, "recovery_factor": None,
    }

    if equity_curve is not None and len(equity_curve) > 1:
        eq = equity_curve.set_index("time")["equity"].astype(float)
        dd, dd_pct = drawdown_series(eq)
        mdd = float(-dd.min())
        mdd_pct = float(-dd_pct.min()) if dd_pct.notna().any() else None
        s["max_drawdown"] = round(mdd, 2)
        s["max_drawdown_pct"] = round(mdd_pct, 3) if mdd_pct is not None else None
        s["recovery_factor"] = round(net / mdd, 3) if mdd > 0 else None

        daily = eq.resample("1D").last().dropna()
        rets = daily.pct_change().dropna()
        if len(rets) >= 2 and rets.std() > 0:
            s["sharpe"] = round(float(rets.mean() / rets.std() * math.sqrt(252)), 3)
            downside = rets[rets < 0]
            if len(downside) >= 2 and downside.std() > 0:
                s["sortino"] = round(float(rets.mean() / downside.std() * math.sqrt(252)), 3)
        days = (eq.index[-1] - eq.index[0]).total_seconds() / 86400
        final = float(eq.iloc[-1])
        if days >= 1 and mdd_pct and initial_balance > 0 and final > 0:
            cagr = (final / initial_balance) ** (365.25 / days) - 1
            s["calmar"] = round(cagr * 100 / mdd_pct, 3)
    return s
