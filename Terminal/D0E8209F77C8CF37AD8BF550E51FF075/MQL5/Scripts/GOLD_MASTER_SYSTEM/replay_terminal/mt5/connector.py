"""
mt5/connector.py
================
Responsabilidad única: gestionar la conexión con el terminal MetaTrader 5.

Estrategias de conexión (en orden):
  A) mt5.initialize()  — detección automática
  B) mt5.initialize(path=ruta_terminal)  — ruta manual o guardada en settings
  C) El usuario selecciona terminal64.exe mediante diálogo

Reglas de seguridad:
  - NUNCA guarda contraseñas.
  - NUNCA envía órdenes.  Eso corresponde a LiveExecutionEngine.
  - Toda llamada a mt5.* en este módulo es de lectura / inicialización.

Thread-safety:
  - La librería MetaTrader5 NO es thread-safe.
  - MT5Connector debe instanciarse y usarse desde un único QThread dedicado
    (MT5Worker, definido en core/mt5_worker.py — Fase 3+).
  - En la Fase 1 lo llamamos desde el hilo principal para simplificar
    la demostración, pero la arquitectura ya prevé el worker.
"""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass, field
from enum import Enum, auto
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

try:
    import MetaTrader5 as mt5  # type: ignore
    MT5_AVAILABLE = True
except ImportError:
    mt5 = None  # type: ignore
    MT5_AVAILABLE = False
    logger.warning("Librería MetaTrader5 no disponible en este entorno.")

CONFIG_DIR = Path(__file__).parent.parent / "config"
SETTINGS_FILE = CONFIG_DIR / "settings.json"


class ConnectionState(Enum):
    DISCONNECTED = auto()
    CONNECTED = auto()
    RECONNECTING = auto()
    ACCOUNT_CHANGED = auto()
    ERROR = auto()


@dataclass
class AccountSnapshot:
    login: int
    server: str
    balance: float
    equity: float
    margin: float
    margin_free: float
    currency: str
    leverage: int
    trade_mode: int

    @property
    def is_demo(self) -> bool:
        return self.trade_mode == 0

    @property
    def is_real(self) -> bool:
        return self.trade_mode == 2

    @classmethod
    def from_mt5(cls, info) -> "AccountSnapshot":
        return cls(
            login=info.login,
            server=info.server,
            balance=info.balance,
            equity=info.equity,
            margin=info.margin,
            margin_free=info.margin_free,
            currency=info.currency,
            leverage=info.leverage,
            trade_mode=info.trade_mode,
        )

    def identity_key(self) -> tuple:
        return (self.login, self.server, self.currency)


class MT5Connector:
    def __init__(self, settings_path: Path = SETTINGS_FILE) -> None:
        self._settings_path = settings_path
        self._state: ConnectionState = ConnectionState.DISCONNECTED
        self._account: Optional[AccountSnapshot] = None
        self._terminal_path: Optional[str] = os.getenv("GM_TERMINAL_PATH") or self._load_terminal_path()

    @property
    def state(self) -> ConnectionState:
        return self._state

    @property
    def account(self) -> Optional[AccountSnapshot]:
        return self._account

    @property
    def is_connected(self) -> bool:
        return self._state == ConnectionState.CONNECTED

    def connect(self) -> tuple[ConnectionState, Optional[AccountSnapshot]]:
        if not MT5_AVAILABLE:
            logger.error("MetaTrader5 no está instalado.")
            self._state = ConnectionState.ERROR
            return self._state, None
        if self._terminal_path:
            logger.info(f"Intentando ruta guardada: {self._terminal_path}")
            if self._try_initialize(path=self._terminal_path):
                return self._post_connect()
            # An explicitly selected terminal must not silently switch accounts.
            self._state = ConnectionState.DISCONNECTED
            self._account = None
            return self._state, None
        if self._try_initialize(path=None):
            return self._post_connect()
        logger.warning("No se pudo conectar automáticamente. Usa connect_with_path(path).")
        self._state = ConnectionState.DISCONNECTED
        return self._state, None

    def connect_with_path(self, path: str) -> tuple[ConnectionState, Optional[AccountSnapshot]]:
        if not MT5_AVAILABLE:
            self._state = ConnectionState.ERROR
            return self._state, None
        if self._try_initialize(path=path):
            self._terminal_path = path
            self._save_terminal_path(path)
            return self._post_connect()
        self._state = ConnectionState.ERROR
        return self._state, None

    def disconnect(self) -> None:
        if MT5_AVAILABLE and mt5 is not None:
            mt5.shutdown()
        self._state = ConnectionState.DISCONNECTED
        self._account = None
        logger.info("Desconectado de MetaTrader 5.")

    def ping(self) -> tuple[ConnectionState, Optional[AccountSnapshot]]:
        if not MT5_AVAILABLE or mt5 is None:
            self._state = ConnectionState.ERROR
            return self._state, None
        info = mt5.account_info()
        if info is None:
            logger.warning(f"mt5.account_info() devolvió None. Error: {mt5.last_error()}")
            self._state = ConnectionState.DISCONNECTED
            self._account = None
            return self._state, None
        new_account = AccountSnapshot.from_mt5(info)
        if (self._account is not None and
                new_account.identity_key() != self._account.identity_key()):
            logger.warning(f"CAMBIO DE CUENTA: {self._account.login} → {new_account.login}")
            self._account = new_account
            self._state = ConnectionState.ACCOUNT_CHANGED
            return self._state, self._account
        self._account = new_account
        self._state = ConnectionState.CONNECTED
        return self._state, self._account

    def _try_initialize(self, path: Optional[str]) -> bool:
        try:
            if path:
                result = mt5.initialize(path=path)
            else:
                result = mt5.initialize()
            if result:
                logger.info("mt5.initialize() exitoso.")
                return True
            else:
                logger.warning(f"mt5.initialize() falló: {mt5.last_error()}")
                return False
        except Exception as exc:
            logger.exception(f"Excepción durante mt5.initialize(): {exc}")
            return False

    def _post_connect(self) -> tuple[ConnectionState, Optional[AccountSnapshot]]:
        info = mt5.account_info()
        if info is None:
            logger.error(f"Conectado pero account_info() devolvió None: {mt5.last_error()}")
            self._state = ConnectionState.ERROR
            return self._state, None
        self._account = AccountSnapshot.from_mt5(info)
        self._state = ConnectionState.CONNECTED
        logger.info(f"MT5 CONNECTED | Login={self._account.login} | Server={self._account.server}")
        return self._state, self._account

    def _load_terminal_path(self) -> Optional[str]:
        if not self._settings_path.exists():
            return None
        try:
            with open(self._settings_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            return data.get("terminal_path")
        except (json.JSONDecodeError, OSError) as exc:
            logger.warning(f"No se pudo leer settings.json: {exc}")
            return None

    def _save_terminal_path(self, path: str) -> None:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        existing: dict = {}
        if self._settings_path.exists():
            try:
                with open(self._settings_path, "r", encoding="utf-8") as f:
                    existing = json.load(f)
            except (json.JSONDecodeError, OSError):
                pass
        existing["terminal_path"] = path
        with open(self._settings_path, "w", encoding="utf-8") as f:
            import json as _json
            _json.dump(existing, f, indent=2)
        logger.info(f"Ruta de terminal guardada: {path}")
