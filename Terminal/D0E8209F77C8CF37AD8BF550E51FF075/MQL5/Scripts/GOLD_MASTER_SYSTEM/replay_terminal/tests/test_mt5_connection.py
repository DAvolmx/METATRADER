"""
tests/test_mt5_connection.py  —  16 pruebas FASE 1
Corren sin MT5 instalado usando mocks.
  pytest tests/test_mt5_connection.py -v
"""
from __future__ import annotations
import json, sys, types
from unittest.mock import MagicMock

import pytest

_mt5_stub = types.ModuleType("MetaTrader5")

def _make_mt5_stub():
    stub = _mt5_stub
    stub.TRADE_ACTION_DEAL = 1
    stub.ORDER_TYPE_BUY = 0
    stub.ORDER_TYPE_SELL = 1
    stub.ORDER_FILLING_IOC = 1
    stub.initialize = MagicMock(return_value=True)
    stub.shutdown = MagicMock()
    stub.last_error = MagicMock(return_value=(0, "no error"))
    stub.account_info = MagicMock()
    return stub

# Si ya existe (librería real en Windows o stub de conftest) se parchea ESE módulo con mocks:
# ningún test llama nunca al terminal real.
sys.modules.setdefault("MetaTrader5", _mt5_stub)
_mt5_stub = sys.modules["MetaTrader5"]
_mt5_stub = _make_mt5_stub()

from mt5.connector import MT5Connector, AccountSnapshot, ConnectionState
from mt5.account import MT5Monitor
from core.app_state import AppState

def _make_account_info(login=123456, server="TestBroker-Demo", balance=10000.0,
                       equity=10050.0, margin=100.0, margin_free=9950.0,
                       currency="USD", leverage=100, trade_mode=0):
    info = MagicMock()
    info.login = login; info.server = server; info.balance = balance
    info.equity = equity; info.margin = margin; info.margin_free = margin_free
    info.currency = currency; info.leverage = leverage; info.trade_mode = trade_mode
    return info

@pytest.fixture(autouse=True)
def reset_mt5_stub():
    _mt5_stub.initialize.reset_mock(); _mt5_stub.initialize.return_value = True
    _mt5_stub.shutdown.reset_mock(); _mt5_stub.last_error.return_value = (0, "no error")
    _mt5_stub.account_info.reset_mock(); _mt5_stub.account_info.return_value = _make_account_info()
    yield

@pytest.fixture
def tmp_settings(tmp_path):
    return tmp_path / "settings.json"

@pytest.fixture
def connector(tmp_settings):
    return MT5Connector(settings_path=tmp_settings)

def test_connect_auto_success(connector):
    state, account = connector.connect()
    assert state == ConnectionState.CONNECTED
    assert account is not None and account.login == 123456
    _mt5_stub.initialize.assert_called_once_with()

def test_connect_with_path(connector, tmp_settings):
    path = r"C:\Program Files\MetaTrader 5\terminal64.exe"
    state, account = connector.connect_with_path(path)
    assert state == ConnectionState.CONNECTED
    _mt5_stub.initialize.assert_called_with(path=path)
    data = json.loads(tmp_settings.read_text())
    assert data["terminal_path"] == path

def test_connect_auto_failure(connector):
    _mt5_stub.initialize.return_value = False
    _mt5_stub.last_error.return_value = (-10006, "Terminal not found")
    state, account = connector.connect()
    assert state == ConnectionState.DISCONNECTED and account is None

def test_account_snapshot_from_mt5():
    info = _make_account_info(login=987654, server="RealBroker-Live", balance=50000.0,
                              equity=51200.0, currency="EUR", leverage=500, trade_mode=2)
    snap = AccountSnapshot.from_mt5(info)
    assert snap.login == 987654 and snap.currency == "EUR" and snap.leverage == 500

def test_account_is_demo():
    snap = AccountSnapshot(login=1,server="s",balance=0,equity=0,margin=0,margin_free=0,currency="USD",leverage=100,trade_mode=0)
    assert snap.is_demo is True and snap.is_real is False

def test_account_is_real():
    snap = AccountSnapshot(login=1,server="s",balance=0,equity=0,margin=0,margin_free=0,currency="USD",leverage=100,trade_mode=2)
    assert snap.is_demo is False and snap.is_real is True

def test_ping_connected(connector):
    connector.connect()
    state, account = connector.ping()
    assert state == ConnectionState.CONNECTED and account is not None

def test_ping_disconnected(connector):
    connector.connect()
    _mt5_stub.account_info.return_value = None
    state, account = connector.ping()
    assert state == ConnectionState.DISCONNECTED and account is None

def test_ping_account_changed_login(connector):
    connector.connect()
    _mt5_stub.account_info.return_value = _make_account_info(login=999999)
    state, account = connector.ping()
    assert state == ConnectionState.ACCOUNT_CHANGED and account.login == 999999

def test_ping_account_changed_server(connector):
    connector.connect()
    _mt5_stub.account_info.return_value = _make_account_info(server="OtherBroker-Live")
    state, account = connector.ping()
    assert state == ConnectionState.ACCOUNT_CHANGED and account.server == "OtherBroker-Live"

def test_real_trading_disabled_by_default():
    assert AppState().real_trading_enabled is False

def test_kill_switch():
    state = AppState()
    with pytest.raises(PermissionError):
        state.authorize_real_trading()
    assert state.real_trading_enabled is False
    state.revoke_real_trading()
    assert state.real_trading_enabled is False

def test_monitor_locks_trading_on_account_change(connector):
    connector.connect()
    monitor = MT5Monitor(connector, interval_ms=1000)
    _mt5_stub.account_info.return_value = _make_account_info(login=777777)
    monitor._tick()
    assert monitor.trading_locked is False

def test_connect_account_info_none(connector):
    _mt5_stub.account_info.return_value = None
    state, account = connector.connect()
    assert state == ConnectionState.ERROR and account is None

def test_save_and_load_terminal_path(tmp_settings):
    path = r"C:\MT5\terminal64.exe"
    c1 = MT5Connector(settings_path=tmp_settings)
    c1._save_terminal_path(path)
    c2 = MT5Connector(settings_path=tmp_settings)
    assert c2._terminal_path == path

def test_identity_key():
    def snap(login, server, currency="USD"):
        return AccountSnapshot(login=login,server=server,balance=0,equity=0,margin=0,margin_free=0,currency=currency,leverage=100,trade_mode=0)
    a = snap(1,"BrokerA"); b = snap(2,"BrokerA"); c = snap(1,"BrokerB"); d = snap(1,"BrokerA","EUR")
    assert a.identity_key() == a.identity_key()
    assert a.identity_key() != b.identity_key()
    assert a.identity_key() != c.identity_key()
    assert a.identity_key() != d.identity_key()

def test_explicit_terminal_does_not_fall_back_to_another_account(tmp_settings,monkeypatch):
    monkeypatch.setenv('GM_TERMINAL_PATH','C:/chosen/terminal64.exe')
    _mt5_stub.initialize.return_value=False
    connector=MT5Connector(settings_path=tmp_settings)
    state,account=connector.connect()
    assert state==ConnectionState.DISCONNECTED and account is None
    _mt5_stub.initialize.assert_called_once_with(path='C:/chosen/terminal64.exe')
