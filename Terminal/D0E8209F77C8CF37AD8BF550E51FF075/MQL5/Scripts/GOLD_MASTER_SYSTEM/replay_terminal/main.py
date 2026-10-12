"""
main.py  —  LDZ Trading Terminal v0.1.0 — FASE 1
"""
from __future__ import annotations
import argparse, logging, sys, time
from pathlib import Path

LOG_DIR = Path(__file__).parent / "logs"
LOG_DIR.mkdir(exist_ok=True)

from core.logging_setup import setup_logging
setup_logging()
logger = logging.getLogger("ldz.main")

from mt5.connector import MT5Connector, ConnectionState, AccountSnapshot
from mt5.account import MT5Monitor
from core.app_state import app_state

APP_VERSION = "0.3.0"
SMC_ENGINE_VERSION = "1.0"

def print_banner():
    print(); print("=" * 60)
    print(f"  LDZ Trading Terminal  v{APP_VERSION}")
    print(f"  SMC Engine            v{SMC_ENGINE_VERSION}")
    print("=" * 60); print()

def print_account(account: AccountSnapshot):
    mode_label = "DEMO" if account.is_demo else "REAL"
    print()
    print("┌─── MT5: CONNECTED ──────────────────────────────┐")
    print(f"│  Cuenta   : {account.login:<36} │")
    print(f"│  Servidor : {account.server:<36} │")
    print(f"│  Balance  : {account.balance:<10.2f} {account.currency:<25} │")
    print(f"│  Equity   : {account.equity:<10.2f} {account.currency:<25} │")
    print(f"│  Margen   : {account.margin:<10.2f}                           │")
    print(f"│  Libre    : {account.margin_free:<10.2f}                           │")
    print(f"│  Apalanca.: 1:{account.leverage:<38} │")
    print(f"│  Modo     : {mode_label:<36} │")
    print("└─────────────────────────────────────────────────┘"); print()

def print_state(state: ConnectionState):
    labels = {
        ConnectionState.CONNECTED: "CONNECTED",
        ConnectionState.DISCONNECTED: "DISCONNECTED",
        ConnectionState.RECONNECTING: "RECONNECTING",
        ConnectionState.ACCOUNT_CHANGED: "ACCOUNT CHANGED",
        ConnectionState.ERROR: "ERROR",
    }
    print(f"  Estado MT5: {labels.get(state, str(state))}")

def on_state_changed(state, account):
    print_state(state)
    if account and state == ConnectionState.CONNECTED:
        print_account(account)

def on_account_changed(prev_account, new_account):
    prev_login = prev_account.login if prev_account else "?"
    new_login = new_account.login if new_account else "?"
    print()
    print("CAMBIO DE CUENTA DETECTADO")
    print(f"  Cuenta anterior : {prev_login}")
    print(f"  Cuenta actual   : {new_login}")
    print("  Operaciones reales BLOQUEADAS"); print()

def on_reconnect_failed(message: str):
    print(f"\nRECONEXION FALLIDA: {message}\n")

def run_gui(autotest: str | None = None, symbol: str = "XAUUSD") -> int:
    """Interfaz gráfica completa (PySide6 + pyqtgraph)."""
    from PySide6 import QtWidgets
    from ui.main_window import MainWindow
    app = QtWidgets.QApplication(sys.argv)
    app.setApplicationName("LDZ Trading Terminal")
    w = MainWindow()
    w.show()
    if autotest:
        from ui.autotest import run_autotest
        return run_autotest(app, w, Path(autotest), symbol)
    return app.exec()


def main() -> int:
    parser = argparse.ArgumentParser(description="LDZ Trading Terminal")
    parser.add_argument("--terminal", type=str, default=None)
    parser.add_argument("--check", action="store_true", help="Solo verificar conexión MT5 y salir")
    parser.add_argument("--console", action="store_true", help="Monitor de conexión en consola (sin GUI)")
    parser.add_argument("--autotest", metavar="CAPTURA.png", default=None,
                        help="Prueba automática de la GUI con MT5 real (sin enviar órdenes) y captura de pantalla")
    parser.add_argument("--symbol", default="XAUUSD")
    args = parser.parse_args()

    if not args.check and not args.console and not args.terminal:
        return run_gui(args.autotest, args.symbol)

    print_banner()
    assert app_state.real_trading_enabled is False, "CRITICAL: real_trading_enabled debe ser False"

    connector = MT5Connector()
    if args.terminal:
        state, account = connector.connect_with_path(args.terminal)
    else:
        state, account = connector.connect()

    print_state(state)

    if state in (ConnectionState.ERROR, ConnectionState.DISCONNECTED):
        print("\n  No se pudo conectar a MetaTrader 5.")
        print("  Verifica que el terminal MT5 esté abierto con sesión activa.")
        print('  Usa:  python main.py --terminal "C:\\MT5\\terminal64.exe"\n')
        if args.check:
            return 1
    elif account:
        print_account(account)

    if args.check:
        connector.disconnect()
        return 0 if state == ConnectionState.CONNECTED else 1

    monitor = MT5Monitor(connector, interval_ms=3000)
    try:
        monitor.signals.connection_state_changed.connect(on_state_changed)
        monitor.signals.account_changed.connect(on_account_changed)
        monitor.signals.reconnect_failed.connect(on_reconnect_failed)
    except Exception:
        pass

    monitor.start()
    print("  Monitor iniciado. Presiona Ctrl+C para salir.\n")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n  Cerrando LDZ Trading Terminal...")

    monitor.stop()
    connector.disconnect()
    print("  Desconectado.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
