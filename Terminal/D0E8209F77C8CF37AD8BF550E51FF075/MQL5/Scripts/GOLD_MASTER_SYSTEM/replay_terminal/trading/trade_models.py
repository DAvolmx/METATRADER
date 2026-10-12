"""
trading/trade_models.py — Modelos de operación y especificación de símbolo.
Sin dependencias de MT5: los usan la simulación, el paper trading y el backtest.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Callable, Optional

# profit_fn(direction, volume, price_open, price_close) -> dinero o None
ProfitFn = Callable[[str, float, float, float], Optional[float]]


@dataclass
class SymbolSpec:
    symbol: str
    digits: int
    point: float
    contract_size: Optional[float] = None
    profit_currency: Optional[str] = None
    account_currency: Optional[str] = None
    volume_min: float = 0.01
    volume_max: float = 100.0
    volume_step: float = 0.01
    stops_level: int = 0            # puntos
    swap_long: Optional[float] = None
    swap_short: Optional[float] = None
    swap_mode: Optional[int] = None  # SymbolInfo.swap_mode (ver trading/swap.py)
    swap_rollover3days: int = 3      # MT5: 0=domingo ... 3=miércoles
    base_currency: Optional[str] = None
    margin_currency: Optional[str] = None

    def money_per_price_unit(self, volume: float) -> Optional[float]:
        """
        Dinero por 1.0 de movimiento de precio. Válido solo si la divisa de
        beneficio del símbolo es la de la cuenta (XAUUSD en cuenta USD).
        En otro caso None => la UI muestra N/A. En LIVE se prefiere
        mt5.order_calc_profit (ver mt5/execution.py).
        """
        if (self.contract_size and self.profit_currency and self.account_currency
                and self.profit_currency == self.account_currency):
            return self.contract_size * volume
        return None

    def default_profit_fn(self) -> Optional[ProfitFn]:
        if self.money_per_price_unit(1.0) is None:
            return None

        def fn(direction: str, volume: float, p_open: float, p_close: float) -> float:
            d = p_close - p_open if direction == "BUY" else p_open - p_close
            return d * self.money_per_price_unit(volume)
        return fn

    @classmethod
    def from_dict(cls, d: dict) -> "SymbolSpec":
        keys = cls.__dataclass_fields__.keys()
        return cls(**{k: v for k, v in d.items() if k in keys})


class TradeStatus:
    OPEN = "OPEN"
    CLOSED = "CLOSED"
    CANCELLED = "CANCELLED"


@dataclass
class Trade:
    id: int
    symbol: str
    direction: str                    # BUY | SELL
    volume: float
    entry_time: datetime
    entry_price: float
    stop_loss: Optional[float] = None
    take_profit: Optional[float] = None
    exit_time: Optional[datetime] = None
    exit_price: Optional[float] = None
    exit_reason: Optional[str] = None  # SL | TP | MANUAL | END
    commission: float = 0.0
    swap: float = 0.0                 # acumulado, signo MT5 (+ abono / - cargo)
    spread: float = 0.0               # en precio, pagado al entrar
    slippage: float = 0.0             # en precio
    profit: Optional[float] = None    # neto = bruto - comisión + swap
    r_multiple: Optional[float] = None
    mae: float = 0.0                  # peor excursión en precio (<=0)
    mfe: float = 0.0                  # mejor excursión en precio (>=0)
    status: str = TradeStatus.OPEN
    signal_time: Optional[datetime] = None
    comment: str = ""
    synthetic: bool = False

    @property
    def initial_risk(self) -> Optional[float]:
        return None if self.stop_loss is None else abs(self.entry_price - self.stop_loss)

    def price_diff(self, price: float) -> float:
        d = price - self.entry_price
        return d if self.direction == "BUY" else -d

    @property
    def outcome(self) -> Optional[str]:
        if self.status != TradeStatus.CLOSED or self.profit is None:
            return None
        if abs(self.profit) < 1e-9:
            return "BREAKEVEN"
        return "WIN" if self.profit > 0 else "LOSS"
