"""
core/app_state.py  —  Estado global de la aplicación.
"""
from __future__ import annotations
from enum import Enum, auto
from typing import Optional

class AppMode(Enum):
    LIVE = auto()
    REPLAY = auto()
    PAPER = auto()
    REAL = auto()
    SYNTHETIC = auto()  # Mercado sintético (simulador de fin de semana)

class AppState:
    def __init__(self) -> None:
        self.mode: AppMode = AppMode.LIVE
        self.real_trading_enabled: bool = False  # OFF por defecto — CRÍTICO
        self.trading_locked: bool = False
        self.connected: bool = False
        self.current_symbol: Optional[str] = None
        self.current_timeframe: Optional[str] = None

    def authorize_real_trading(self) -> None:
        raise PermissionError("Esta edición de investigación solo permite operaciones simuladas")
        # Legacy mode transitions below are unreachable by design.
        if self.mode in (AppMode.REPLAY, AppMode.PAPER, AppMode.SYNTHETIC):
            raise PermissionError(
                f"No se puede autorizar trading real en modo {self.mode.name}"
            )
        self.real_trading_enabled = True
        self.mode = AppMode.REAL

    def revoke_real_trading(self) -> None:
        self.real_trading_enabled = False
        if self.mode == AppMode.REAL:
            self.mode = AppMode.LIVE

    def can_send_real_orders(self) -> bool:
        return False

    def lock_trading(self) -> None:
        self.trading_locked = True

    def unlock_trading(self) -> None:
        self.trading_locked = False

app_state = AppState()
