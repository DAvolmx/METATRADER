"""
trading/position_sizer.py — Lotaje por riesgo.

NO se usa una fórmula universal tipo "pip value = 10". El valor monetario de
la distancia entrada→SL lo calcula una profit_fn:
  * LIVE: mt5.order_calc_profit (función oficial de MT5).
  * Simulación/backtest: SymbolSpec.default_profit_fn (tamaño de contrato real
    leído de symbol_info y guardado al descargar).
El volumen se redondea HACIA ABAJO al volume_step (nunca arriesgar de más) y
se valida contra volume_min / volume_max.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from decimal import Decimal, ROUND_DOWN
from typing import Optional

from trading.trade_models import ProfitFn, SymbolSpec


@dataclass
class SizeResult:
    volume: Optional[float]
    risk_money: float
    loss_per_lot: Optional[float]
    actual_risk: Optional[float]
    reason: str = ""

    @property
    def ok(self) -> bool:
        return self.volume is not None


def round_volume_down(volume: float, step: float) -> float:
    q = Decimal(str(step))
    return float((Decimal(str(volume)) / q).to_integral_value(rounding=ROUND_DOWN) * q)


def size_by_risk(balance: float, risk_pct: float, direction: str, entry: float,
                 stop_loss: Optional[float], spec: SymbolSpec,
                 profit_fn: Optional[ProfitFn]) -> SizeResult:
    if (not all(math.isfinite(x) for x in (balance, risk_pct, entry))
            or balance <= 0 or not 0 < risk_pct <= 100 or entry <= 0
            or direction not in ("BUY", "SELL")):
        return SizeResult(None, 0, None, None, "Balance, riesgo, precio o dirección inválidos")
    if spec.volume_step <= 0 or spec.volume_min <= 0 or spec.volume_max < spec.volume_min:
        return SizeResult(None, 0, None, None, "Especificaciones de volumen inválidas")
    risk_money = balance * risk_pct / 100.0
    if stop_loss is None or not math.isfinite(stop_loss) or stop_loss <= 0:
        return SizeResult(None, risk_money, None, None, "Sin SL no se puede dimensionar por riesgo")
    if (direction == "BUY" and stop_loss >= entry) or (direction == "SELL" and stop_loss <= entry):
        return SizeResult(None, risk_money, None, None, "SL en el lado incorrecto de la entrada")
    if profit_fn is None:
        return SizeResult(None, risk_money, None, None, "No se puede calcular el valor monetario (N/A)")
    pnl = profit_fn(direction, 1.0, entry, stop_loss)
    if pnl is None or not math.isfinite(pnl) or pnl >= 0:
        return SizeResult(None, risk_money, None, None, "Cálculo de pérdida por lote inválido")
    loss_per_lot = abs(pnl)
    vol = round_volume_down(risk_money / loss_per_lot, spec.volume_step)
    if vol < spec.volume_min - 1e-12:
        return SizeResult(None, risk_money, loss_per_lot, None,
                          f"El riesgo ({risk_money:.2f}) no alcanza el volumen mínimo "
                          f"{spec.volume_min} (requiere {loss_per_lot * spec.volume_min:.2f})")
    vol = min(vol, spec.volume_max)
    return SizeResult(vol, risk_money, loss_per_lot, round(vol * loss_per_lot, 2))
