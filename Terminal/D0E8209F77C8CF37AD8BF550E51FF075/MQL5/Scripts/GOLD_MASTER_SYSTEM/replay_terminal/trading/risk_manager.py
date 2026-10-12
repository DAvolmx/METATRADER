"""
trading/risk_manager.py — Cálculo de SL/TP y validaciones previas a operar.
"""
from __future__ import annotations

from typing import Optional

import numpy as np

from trading.trade_models import SymbolSpec


def atr(highs, lows, closes, period: int = 14) -> Optional[float]:
    """ATR clásico (media simple de True Range) con datos YA CERRADOS."""
    h, l, c = np.asarray(highs), np.asarray(lows), np.asarray(closes)
    if len(c) < period + 1:
        return None
    tr = np.maximum(h[1:] - l[1:], np.maximum(abs(h[1:] - c[:-1]), abs(l[1:] - c[:-1])))
    return float(np.mean(tr[-period:]))


def stop_from(mode: str, direction: str, entry: float, value: float, spec: SymbolSpec,
              atr_value: Optional[float] = None, structure_price: Optional[float] = None) -> float:
    """
    mode: PRICE | POINTS | PERCENT | ATR | STRUCTURE
    value: precio, puntos, %, multiplicador ATR o buffer en puntos (STRUCTURE).
    """
    sign = -1 if direction == "BUY" else 1
    if mode == "PRICE":
        sl = value
    elif mode == "POINTS":
        sl = entry + sign * value * spec.point
    elif mode == "PERCENT":
        sl = entry * (1 + sign * value / 100.0)
    elif mode == "ATR":
        if atr_value is None:
            raise ValueError("ATR no disponible (datos insuficientes)")
        sl = entry + sign * value * atr_value
    elif mode == "STRUCTURE":
        if structure_price is None:
            raise ValueError("No hay swing estructural confirmado")
        sl = structure_price + sign * value * spec.point
    else:
        raise ValueError(f"Modo de SL desconocido: {mode}")
    return round(sl, spec.digits)


def take_profit_rr(direction: str, entry: float, stop_loss: float, rr: float, digits: int) -> float:
    risk = abs(entry - stop_loss)
    return round(entry + risk * rr if direction == "BUY" else entry - risk * rr, digits)


def validate_stops(direction: str, bid: float, ask: float, sl: Optional[float],
                   tp: Optional[float], spec: SymbolSpec) -> list[str]:
    """Devuelve lista de errores (vacía = válido). Respeta trade_stops_level."""
    errs = []
    min_dist = spec.stops_level * spec.point
    if direction == "BUY":
        if sl is not None and sl > bid - min_dist:
            errs.append(f"SL debe estar <= {bid - min_dist:.{spec.digits}f}")
        if tp is not None and tp < ask + min_dist:
            errs.append(f"TP debe estar >= {ask + min_dist:.{spec.digits}f}")
    else:
        if sl is not None and sl < ask + min_dist:
            errs.append(f"SL debe estar >= {ask + min_dist:.{spec.digits}f}")
        if tp is not None and tp > bid - min_dist:
            errs.append(f"TP debe estar <= {bid - min_dist:.{spec.digits}f}")
    return errs
