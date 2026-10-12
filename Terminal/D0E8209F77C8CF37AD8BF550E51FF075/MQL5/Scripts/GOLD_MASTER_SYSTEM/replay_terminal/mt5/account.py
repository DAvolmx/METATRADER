"""
mt5/account.py  —  MT5Monitor
Hilo de monitoreo periódico de la conexión y cuenta MT5.
"""
from __future__ import annotations
import logging
import time
from typing import Optional
from mt5.connector import MT5Connector, AccountSnapshot, ConnectionState

logger = logging.getLogger(__name__)

try:
    from PySide6.QtCore import QThread, Signal, QObject
    PYSIDE6_AVAILABLE = True
except ImportError:
    PYSIDE6_AVAILABLE = False
    class QObject:
        pass
    class Signal:
        def __init__(self, *args): pass
        def emit(self, *args): pass
        def connect(self, *args): pass
    class QThread(QObject):
        def start(self): pass
        def quit(self): pass
        def wait(self): pass
        def msleep(self, ms): time.sleep(ms / 1000)
        def isInterruptionRequested(self): return False
        def requestInterruption(self): pass
        def run(self): pass


class MT5MonitorSignals(QObject):
    connection_state_changed = Signal(object, object)
    account_changed = Signal(object, object)
    reconnect_failed = Signal(str)


class MT5Monitor(QThread):
    DEFAULT_INTERVAL_MS: int = 3000
    MAX_RECONNECT_ATTEMPTS: int = 5

    def __init__(self, connector: MT5Connector, interval_ms: int = DEFAULT_INTERVAL_MS) -> None:
        super().__init__()
        self._connector = connector
        self._interval_ms = interval_ms
        self.signals = MT5MonitorSignals()
        self._previous_account: Optional[AccountSnapshot] = connector.account
        self._previous_state: ConnectionState = connector.state
        self._reconnect_attempts: int = 0
        self._trading_locked: bool = False

    @property
    def trading_locked(self) -> bool:
        return self._trading_locked

    def run(self) -> None:
        logger.info("MT5Monitor iniciado.")
        while not self.isInterruptionRequested():
            self._tick()
            self.msleep(self._interval_ms)
        logger.info("MT5Monitor detenido.")

    def stop(self) -> None:
        self.requestInterruption()
        self.quit()
        self.wait()

    def _tick(self) -> None:
        state, account = self._connector.ping()
        if state == ConnectionState.CONNECTED:
            self._reconnect_attempts = 0
            if self._previous_state != ConnectionState.CONNECTED:
                logger.info("MT5 reconectado.")
                self._trading_locked = False
            self._emit_if_changed(state, account)
        elif state == ConnectionState.ACCOUNT_CHANGED:
            prev = self._previous_account
            self._trading_locked = True
            logger.warning(f"CAMBIO DE CUENTA: {prev.login if prev else '?'} -> {account.login if account else '?'}")
            self.signals.account_changed.emit(prev, account)
            self._emit_if_changed(state, account)
            self._post_account_change(account)
        elif state == ConnectionState.DISCONNECTED:
            self._handle_disconnected()
            self._emit_if_changed(state, account)
        elif state == ConnectionState.ERROR:
            self._emit_if_changed(state, account)
        self._previous_state = state
        self._previous_account = account

    def _emit_if_changed(self, state, account):
        if state != self._previous_state or account != self._previous_account:
            self.signals.connection_state_changed.emit(state, account)

    def _handle_disconnected(self) -> None:
        self._trading_locked = True
        self._reconnect_attempts += 1
        logger.warning(f"MT5 desconectado. Intento {self._reconnect_attempts}/{self.MAX_RECONNECT_ATTEMPTS}")
        if self._reconnect_attempts > self.MAX_RECONNECT_ATTEMPTS:
            logger.error("Reconexión fallida.")
            self.signals.reconnect_failed.emit(f"No se pudo reconectar después de {self.MAX_RECONNECT_ATTEMPTS} intentos.")

    def _post_account_change(self, new_account: Optional[AccountSnapshot]) -> None:
        if new_account is None:
            logger.error("Nueva cuenta es None. Trading permanece bloqueado.")
            return
        if new_account.login > 0 and new_account.server:
            logger.info(f"Nueva cuenta verificada: {new_account.login}@{new_account.server}. Desbloqueando.")
            self._trading_locked = False
        else:
            logger.warning("Datos de nueva cuenta incoherentes. Trading bloqueado.")
