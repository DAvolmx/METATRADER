"""Fixtures comunes. Ningún test necesita MT5 instalado."""
from __future__ import annotations

import sys
import types
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

import numpy as np
import pandas as pd
import pytest

# Stub de MetaTrader5 para entornos sin la librería (Linux/CI).
if "MetaTrader5" not in sys.modules:
    try:
        import MetaTrader5  # noqa: F401
    except ImportError:
        stub = types.ModuleType("MetaTrader5")
        for name, val in dict(TRADE_ACTION_DEAL=1, ORDER_TYPE_BUY=0, ORDER_TYPE_SELL=1,
                              ORDER_FILLING_FOK=0, ORDER_FILLING_IOC=1, ORDER_FILLING_RETURN=2,
                              ORDER_TIME_GTC=0, TRADE_RETCODE_DONE=10009, TRADE_RETCODE_PLACED=10008,
                              SYMBOL_TRADE_MODE_DISABLED=0, POSITION_TYPE_BUY=0, POSITION_TYPE_SELL=1,
                              TIMEFRAME_M1=1, TIMEFRAME_M5=5, COPY_TICKS_ALL=-1).items():
            setattr(stub, name, val)
        for fn in ("initialize", "shutdown", "last_error", "account_info", "symbol_info",
                   "symbol_info_tick", "symbol_select", "order_check", "order_send",
                   "order_calc_margin", "order_calc_profit", "positions_get", "copy_rates_from_pos",
                   "symbols_get", "copy_ticks_range"):
            setattr(stub, fn, MagicMock())
        sys.modules["MetaTrader5"] = stub

from core.models import Bar  # noqa: E402
from trading.trade_models import SymbolSpec  # noqa: E402

T0 = datetime(2026, 1, 5, tzinfo=timezone.utc)


def mkbars(rows, tf_minutes=1, start=T0, spread=0, first_extreme=None):
    """rows: lista de (o,h,l,c). Devuelve list[Bar] consecutivas."""
    return [Bar(start + timedelta(minutes=tf_minutes * i), *map(float, r), 10, spread, first_extreme)
            for i, r in enumerate(rows)]


@pytest.fixture
def gold_spec():
    return SymbolSpec("XAUUSD", 2, 0.01, 100.0, "USD", "USD", 0.01, 100.0, 0.01, 0)


@pytest.fixture(scope="session")
def history_m1():
    from tests.test_synthetic_market import make_history
    return make_history(days=6)
