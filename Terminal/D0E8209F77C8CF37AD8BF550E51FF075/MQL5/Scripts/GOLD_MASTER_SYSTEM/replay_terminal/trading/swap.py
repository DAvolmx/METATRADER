"""
trading/swap.py — Swap (rollover nocturno) con las reglas de MT5.

Se cobra/abona por cada medianoche (hora del servidor) que una posición
cruza abierta, solo en rollovers de lunes a viernes; el día indicado por
swap_rollover3days (MT5: 0=domingo … 6=sábado, normalmente 3=miércoles)
cuenta TRIPLE para cubrir el fin de semana.

Modos de SymbolInfo.swap_mode soportados:
  0 DISABLED            sin swap
  1 POINTS              puntos × point × contrato × lotes (si beneficio = divisa cuenta)
  2 CURRENCY_SYMBOL     dinero en divisa base       (si divisa base = divisa cuenta)
  3 CURRENCY_MARGIN     dinero en divisa de margen  (si = divisa cuenta)
  4 CURRENCY_DEPOSIT    dinero en divisa de la cuenta
  5 INTEREST_CURRENT    % anual sobre precio actual / 360
  6 INTEREST_OPEN       % anual sobre precio de apertura / 360
  7,8 REOPEN_*          no soportados (MT5 reabre la posición): se marca y no se inventa
Signo: igual que MT5 (positivo = abono, negativo = cargo).
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Optional

SWAP_DISABLED, SWAP_POINTS, SWAP_CCY_SYMBOL, SWAP_CCY_MARGIN, SWAP_CCY_DEPOSIT = 0, 1, 2, 3, 4
SWAP_INTEREST_CURRENT, SWAP_INTEREST_OPEN = 5, 6


def swap_per_night(spec, direction: str, volume: float, open_price: float,
                   current_price: float) -> Optional[float]:
    """Swap de UNA noche en divisa de la cuenta, o None si no se puede calcular con exactitud."""
    rate = spec.swap_long if direction == "BUY" else spec.swap_short
    mode = spec.swap_mode
    if mode is None or rate is None:
        return None
    if mode == SWAP_DISABLED or rate == 0:
        return 0.0
    acc = spec.account_currency
    same_profit = spec.profit_currency is not None and spec.profit_currency == acc
    if mode == SWAP_POINTS:
        return rate * spec.point * spec.contract_size * volume if (same_profit and spec.contract_size) else None
    if mode == SWAP_CCY_DEPOSIT:
        return rate * volume
    if mode == SWAP_CCY_SYMBOL:
        return rate * volume if spec.base_currency and spec.base_currency == acc else None
    if mode == SWAP_CCY_MARGIN:
        return rate * volume if spec.margin_currency and spec.margin_currency == acc else None
    if mode in (SWAP_INTEREST_CURRENT, SWAP_INTEREST_OPEN):
        if not (same_profit and spec.contract_size):
            return None
        price = current_price if mode == SWAP_INTEREST_CURRENT else open_price
        return rate / 100.0 / 360.0 * price * spec.contract_size * volume
    return None


def rollover_multiplier(prev: datetime, now: datetime, rollover3days_mt5: int = 3) -> int:
    """
    Suma de multiplicadores de las medianoches en (prev, now].
    Rollover que cierra lunes..viernes = 1 (x3 el día triple). Sábado/domingo = 0.
    """
    if now <= prev:
        return 0
    triple_py = (rollover3days_mt5 - 1) % 7          # MT5 domingo=0  ->  Python lunes=0
    m = prev.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)
    total = 0
    while m <= now:
        ended = (m - timedelta(days=1)).weekday()
        if ended <= 4:
            total += 3 if ended == triple_py else 1
        m += timedelta(days=1)
    return total
