"""The research terminal must never reach the broker execution API."""
from unittest.mock import MagicMock
import pytest
from core.app_state import AppState, AppMode
from mt5.execution import LiveExecutionEngine, TradingBlocked

@pytest.mark.parametrize("mode", list(AppMode))
@pytest.mark.parametrize("method", ["authorize", "preview", "send", "close_position"])
def test_broker_execution_disabled_even_in_live_mode(mode, method):
    state, broker = AppState(), MagicMock()
    state.mode = mode
    engine = LiveExecutionEngine(state, mt5_module=broker)
    with pytest.raises(TradingBlocked):
        getattr(engine, method)("XAUUSD")
    broker.order_send.assert_not_called()
    assert not state.real_trading_enabled

def test_kill_switch_has_no_broker_side_effects():
    state, broker = AppState(), MagicMock()
    engine = LiveExecutionEngine(state, mt5_module=broker)
    engine.kill_switch()
    assert state.trading_locked
    broker.order_send.assert_not_called()
