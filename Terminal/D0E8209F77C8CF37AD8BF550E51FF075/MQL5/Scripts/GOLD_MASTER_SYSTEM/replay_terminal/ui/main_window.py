"""
ui/main_window.py — Ventana principal y controlador de la aplicación.

Modos (separados y visibles en todo momento):
  REPLAY     histórico, futuro oculto, operaciones VIRTUALES.
  SYNTHETIC  replay que continúa con mercado sintético al acabar los datos.
  LIVE       datos actuales de MT5; operaciones VIRTUALES salvo autorización.
  REAL       LIVE + trading real autorizado explícitamente (🔴).

Hilos: TODAS las llamadas a MetaTrader5 se hacen en el hilo principal (la
librería no es thread-safe; son llamadas cortas con QTimer). El cálculo
pesado (backtest) va en QThreadPool y no congela la interfaz.
"""
from __future__ import annotations

import json
import logging
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

import numpy as np
import pandas as pd
from PySide6 import QtCore, QtGui, QtWidgets

from charts.chart_widget import ChartWidget
from core.app_state import AppMode, app_state
from core.models import TIMEFRAME_SECONDS, Bar, bars_from_df, is_derivable, tf_delta
from data.aggregator import BarAggregator
from data.data_manager import DataManager, validate_bars
from mt5.connector import ConnectionState, MT5Connector
from replay.replay_engine import ReplayEngine, ReplayState
from smc.smc_engine import SMC_ENGINE_VERSION, SMCConfig, SMCEngine
from storage.database import Database
from strategies.smc_fvg import SMCFVGStrategy
from trading.backtest_engine import BacktestConfig, BacktestEngine
from trading.paper_engine import PaperConfig, PaperTradingEngine
from trading.position_sizer import size_by_risk
from trading.risk_manager import atr, stop_from, take_profit_rr, validate_stops
from trading.trade_models import SymbolSpec
from ui import dialogs
from ui.backtest_panel import BacktestPanel
from ui.replay_panel import ReplayPanel
from ui.smc_panel import SMCPanel
from ui.style import QSS
from ui.trade_panel import TradePanel

log = logging.getLogger("ldz.ui")
ROOT = Path(__file__).parent.parent
APP_VERSION = "0.3.0"
MAX_BARS_DRAWN = 700


def load_json(name: str) -> dict:
    p = ROOT / "config" / name
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {}


class Worker(QtCore.QRunnable):
    class Sig(QtCore.QObject):
        done = QtCore.Signal(object)
        error = QtCore.Signal(str)

    def __init__(self, fn, *a, **kw) -> None:
        super().__init__()
        self.fn, self.a, self.kw = fn, a, kw
        self.sig = Worker.Sig()

    def run(self) -> None:
        try:
            self.sig.done.emit(self.fn(*self.a, **self.kw))
        except Exception as e:
            self.sig.error.emit(f"{e}\n{traceback.format_exc()}")


class QtLogHandler(logging.Handler, QtCore.QObject):
    line = QtCore.Signal(str)

    def __init__(self) -> None:
        logging.Handler.__init__(self)
        QtCore.QObject.__init__(self)
        self.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s", "%H:%M:%S"))

    def emit(self, record) -> None:
        try:
            self.line.emit(self.format(record))
        except Exception:
            pass


class MainWindow(QtWidgets.QMainWindow):
    def __init__(self, db_path: Optional[Path] = None) -> None:
        super().__init__()
        self.setWindowTitle(f"LDZ Trading Terminal v{APP_VERSION}")
        self.resize(1600, 980)
        self.setStyleSheet(QSS)
        self.settings = load_json("settings.json")
        self.risk_cfg = load_json("risk.json")
        self.db = Database(db_path) if db_path else Database()
        self.dm = DataManager(self.db)
        self.connector = MT5Connector()
        self.live_exec = None            # se crea al conectar (necesita MT5)
        self.pool = QtCore.QThreadPool.globalInstance()

        # estado de datos
        self.spec: Optional[SymbolSpec] = None
        self.replay: Optional[ReplayEngine] = None
        self.engines: dict[str, SMCEngine] = {}
        self.aggs: dict[str, BarAggregator] = {}
        self.fed_idx = 0
        self.paper: Optional[PaperTradingEngine] = None
        self.paper_idx = 0
        self.bt_result = None
        self.show_bt = True
        self.mode = AppMode.REPLAY
        self.prev_account = None
        self._smc_version = 0
        self._drawings_version = 0
        self._drawings_cache: dict = {}

        self._build_ui()
        self._shortcuts()
        self.play_timer = QtCore.QTimer(self); self.play_timer.timeout.connect(self._play_tick)
        self.live_timer = QtCore.QTimer(self); self.live_timer.timeout.connect(self._live_tick)
        self.monitor_timer = QtCore.QTimer(self); self.monitor_timer.timeout.connect(self._monitor_tick)
        self.monitor_timer.start(int(self.settings.get("monitor_interval_ms", 3000)))
        self._set_mode(AppMode.REPLAY)
        QtCore.QTimer.singleShot(200, self._try_connect)

    # ======================================================================
    # UI
    # ======================================================================
    def _build_ui(self) -> None:
        central = QtWidgets.QWidget()
        self.setCentralWidget(central)
        v = QtWidgets.QVBoxLayout(central)
        v.setContentsMargins(4, 4, 4, 4)

        # Barra 1: cuenta
        top = QtWidgets.QHBoxLayout()
        self.lbl_status = QtWidgets.QLabel("MT5: DISCONNECTED")
        self.lbl_account = QtWidgets.QLabel("Cuenta: —")
        self.lbl_balance = QtWidgets.QLabel("Balance: —")
        self.lbl_equity = QtWidgets.QLabel("Equity: —")
        self.lbl_mode = QtWidgets.QLabel("REPLAY")
        for w in (self.lbl_status, self.lbl_account, self.lbl_balance, self.lbl_equity):
            w.setStyleSheet("padding:2px 10px;border-right:1px solid #2a2e39")
            top.addWidget(w)
        top.addStretch()
        self.btn_connect = QtWidgets.QPushButton("Conectar MT5")
        self.btn_connect.clicked.connect(self._connect_dialog)
        self.btn_auth = QtWidgets.QPushButton("AUTORIZAR TRADES"); self.btn_auth.setObjectName("auth")
        self.btn_auth.clicked.connect(self._authorize_real)
        self.btn_kill = QtWidgets.QPushButton("⛔ BLOQUEAR TRADING"); self.btn_kill.setObjectName("danger")
        self.btn_kill.clicked.connect(self._kill_switch)
        self.btn_close_real = QtWidgets.QPushButton("CERRAR POSICIONES")
        self.btn_close_real.clicked.connect(self._close_real_positions)
        for w in (self.btn_connect, self.btn_auth, self.btn_kill, self.btn_close_real, self.lbl_mode):
            top.addWidget(w)
        v.addLayout(top)

        # Barra 2: datos
        bar2 = QtWidgets.QHBoxLayout()
        self.src = QtWidgets.QComboBox(); self.src.addItems(["MT5", "CSV"])
        self.symbol = QtWidgets.QComboBox(); self.symbol.setEditable(True)
        self.symbol.setCurrentText(self.settings.get("default_symbol", "XAUUSD"))
        self.symbol.setMinimumWidth(130)
        self.base_tf = QtWidgets.QComboBox(); self.base_tf.addItems(["M1", "M5", "M15"]); self.base_tf.setCurrentText("M5")
        self.nbars = QtWidgets.QSpinBox(); self.nbars.setRange(500, 500_000); self.nbars.setValue(30_000)
        self.start_dt = QtWidgets.QDateTimeEdit(); self.start_dt.setDisplayFormat("yyyy-MM-dd HH:mm")
        self.start_dt.setDateTime(QtCore.QDateTime.currentDateTime().addDays(-3))
        self.chk_end = QtWidgets.QCheckBox("Empezar al final")
        self.chk_synth = QtWidgets.QCheckBox("Continuar con mercado sintético")
        self.chk_synth.setToolTip("Al terminar los datos reales, el replay sigue con velas SINTÉTICAS "
                                  "calibradas con el histórico (no es predicción).")
        self.seed = QtWidgets.QSpinBox(); self.seed.setRange(0, 2_000_000_000); self.seed.setValue(0)
        self.seed.setToolTip("0 = semilla aleatoria")
        self.vol = QtWidgets.QDoubleSpinBox(); self.vol.setRange(0.1, 5); self.vol.setValue(1.0); self.vol.setSuffix("x vol")
        btn_load = QtWidgets.QPushButton("Cargar"); btn_load.clicked.connect(self._load)
        self.btn_live = QtWidgets.QPushButton("LIVE"); self.btn_live.setCheckable(True)
        self.btn_live.toggled.connect(self._toggle_live)
        for lab, w in [("Fuente", self.src), ("Símbolo", self.symbol), ("TF base", self.base_tf),
                       ("Velas", self.nbars), ("Inicio replay", self.start_dt)]:
            bar2.addWidget(QtWidgets.QLabel(lab)); bar2.addWidget(w)
        for w in (self.chk_end, self.chk_synth, QtWidgets.QLabel("Semilla"), self.seed, self.vol,
                  btn_load, self.btn_live):
            bar2.addWidget(w)
        bar2.addStretch()
        v.addLayout(bar2)

        # Barra 3: dibujo y sincronización
        bar3 = QtWidgets.QHBoxLayout()
        bar3.addWidget(QtWidgets.QLabel("Dibujo:"))
        for kind, label in [("hline", "— H"), ("vline", "| V"), ("trend", "╱ Trend"), ("rect", "▭ Rect"),
                            ("channel", "▱ Canal"), ("fib", "Fibo"), ("text", "T Texto")]:
            b = QtWidgets.QPushButton(label)
            b.clicked.connect(lambda _=False, k=kind: self._set_tool(k))
            bar3.addWidget(b)
        b = QtWidgets.QPushButton("Borrar dibujos"); b.clicked.connect(self._clear_drawings); bar3.addWidget(b)
        self.sync_cross = QtWidgets.QCheckBox("Sync crosshair"); self.sync_cross.setChecked(True)
        self.follow = QtWidgets.QCheckBox("Seguir precio"); self.follow.setChecked(True)
        self.follow.toggled.connect(lambda on: [c.set_follow(on) for c in self.charts])
        bar3.addWidget(self.sync_cross); bar3.addWidget(self.follow)
        bar3.addStretch()
        v.addLayout(bar3)

        # Gráficos 2x2
        split = QtWidgets.QSplitter(QtCore.Qt.Vertical)
        grid_w = QtWidgets.QWidget()
        grid = QtWidgets.QGridLayout(grid_w)
        grid.setContentsMargins(0, 0, 0, 0); grid.setSpacing(3)
        self.chart_tfs = ["H4", "H1", "M15", "M5"]
        self.charts: list[ChartWidget] = []
        self.tf_selectors = []
        for i, tf in enumerate(self.chart_tfs):
            box = QtWidgets.QWidget(); bl = QtWidgets.QVBoxLayout(box); bl.setContentsMargins(0, 0, 0, 0); bl.setSpacing(0)
            sel = QtWidgets.QComboBox(); sel.addItems(["M1", "M5", "M10", "M15", "M30", "H1", "H4", "D1", "W1", "MN1"])
            sel.setCurrentText(tf)
            sel.currentTextChanged.connect(lambda t, k=i: self._change_chart_tf(k, t))
            ch = ChartWidget(tf)
            ch.crosshair_time.connect(lambda t, src=ch: self._sync_crosshair(src, t))
            ch.drawing_created.connect(lambda kind, c, src=ch: self._save_drawing(src, kind, c))
            ch.price_clicked.connect(lambda p: self.trade_panel.sl.setValue(p))
            ch.drawing_modified.connect(self._update_drawing)
            ch.drawing_deleted.connect(self._delete_drawing)
            bl.addWidget(sel); bl.addWidget(ch)
            grid.addWidget(box, i // 2, i % 2)
            self.charts.append(ch); self.tf_selectors.append(sel)
        split.addWidget(grid_w)

        # Panel inferior
        bottom = QtWidgets.QWidget(); bv = QtWidgets.QVBoxLayout(bottom); bv.setContentsMargins(0, 0, 0, 0)
        self.replay_panel = ReplayPanel()
        bv.addWidget(self.replay_panel)
        tabs = QtWidgets.QTabWidget()
        # Tab operar
        op = QtWidgets.QWidget(); oh = QtWidgets.QHBoxLayout(op)
        self.smc_panel = SMCPanel(SMCConfig.load())
        self.trade_panel = TradePanel()
        self.trade_panel.risk.setValue(float(self.risk_cfg.get("default_risk_percent", 1.0)))
        self.topdown_box = QtWidgets.QPlainTextEdit(); self.topdown_box.setReadOnly(True)
        self.topdown_box.setLineWrapMode(QtWidgets.QPlainTextEdit.NoWrap)
        self.positions = QtWidgets.QTableWidget(0, 9)
        self.positions.setHorizontalHeaderLabels(["#", "Dir", "Vol", "Entrada", "SL", "TP", "Estado", "P&L", "R"])
        td = QtWidgets.QGroupBox("Top-Down (descriptivo, no es señal)"); tl = QtWidgets.QVBoxLayout(td); tl.addWidget(self.topdown_box)
        pos = QtWidgets.QGroupBox("Operaciones simuladas"); pl = QtWidgets.QVBoxLayout(pos); pl.addWidget(self.positions)
        oh.addWidget(self.smc_panel, 2); oh.addWidget(self.trade_panel, 3); oh.addWidget(td, 2); oh.addWidget(pos, 4)
        tabs.addTab(op, "Operar")
        self.bt_panel = BacktestPanel()
        tabs.addTab(self.bt_panel, "Backtest")
        self.log_box = QtWidgets.QPlainTextEdit(); self.log_box.setReadOnly(True); self.log_box.setMaximumBlockCount(3000)
        tabs.addTab(self.log_box, "Logs")
        bv.addWidget(tabs)
        split.addWidget(bottom)
        split.setSizes([620, 340])
        v.addWidget(split)

        # Señales
        rp = self.replay_panel
        rp.play.connect(self._play); rp.pause.connect(self._pause); rp.next.connect(self._next)
        rp.prev.connect(self._prev); rp.reset.connect(self._reset); rp.speed.connect(self._speed)
        rp.next_trade.connect(self._next_trade); rp.jump.connect(self._jump)
        self.smc_panel.changed.connect(self._refresh)
        self.smc_panel.params_changed.connect(self._rebuild_smc)
        self.trade_panel.order_requested.connect(self._order)
        self.trade_panel.close_all.connect(self._close_paper)
        self.trade_panel.params_changed.connect(self._update_trade_panel)
        self.bt_panel.run_requested.connect(self._run_backtest)
        self.bt_panel.export_requested.connect(self._export_backtest)
        self.bt_panel.show_on_chart.connect(lambda on: (setattr(self, "show_bt", on), self._refresh()))
        self.bt_panel.trade_selected.connect(lambda t: self._jump(t.entry_time + timedelta(hours=1)))

        h = QtLogHandler(); h.line.connect(self.log_box.appendPlainText)
        logging.getLogger().addHandler(h)
        self._qt_log = h

    def _shortcuts(self) -> None:
        for key, fn in [(QtCore.Qt.Key_Right, self._next), (QtCore.Qt.Key_Left, self._prev),
                        (QtCore.Qt.Key_Space, self._toggle_play), (QtCore.Qt.Key_R, self._reset),
                        (QtCore.Qt.Key_Escape, lambda: self._set_tool(None)),
                        (QtCore.Qt.Key_Delete, lambda: [c.delete_selected() for c in self.charts])]:
            sc = QtGui.QShortcut(QtGui.QKeySequence(key), self)
            sc.setContext(QtCore.Qt.ApplicationShortcut)
            sc.activated.connect(fn)

    # ======================================================================
    # MT5
    # ======================================================================
    def _try_connect(self) -> None:
        state, acc = self.connector.connect()
        self._apply_connection(state, acc)

    def _connect_dialog(self) -> None:
        state, acc = self.connector.connect()
        if state != ConnectionState.CONNECTED:
            path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Selecciona terminal64.exe", "",
                                                            "terminal64.exe (terminal64.exe)")
            if path:
                state, acc = self.connector.connect_with_path(path)
        self._apply_connection(state, acc)
        if state != ConnectionState.CONNECTED:
            QtWidgets.QMessageBox.warning(self, "MT5", "No se pudo conectar. Abre MetaTrader 5 con sesión "
                                                       "iniciada (o usa la fuente CSV).")

    def _apply_connection(self, state, acc) -> None:
        self.lbl_status.setText(f"MT5: {state.name}")
        col = {"CONNECTED": "#26a69a", "ACCOUNT_CHANGED": "#ff9100", "RECONNECTING": "#ffd54f"}.get(state.name, "#ef5350")
        self.lbl_status.setStyleSheet(f"padding:2px 10px;color:{col};font-weight:bold")
        if state == ConnectionState.CONNECTED and acc:
            self.lbl_account.setText(f"Cuenta: {acc.login} | {acc.server} | {'DEMO' if acc.is_demo else 'REAL'} | 1:{acc.leverage}")
            self.lbl_balance.setText(f"Balance: {acc.balance:,.2f} {acc.currency}")
            self.lbl_equity.setText(f"Equity: {acc.equity:,.2f} {acc.currency}")
            self.db.save_account(acc.login, acc.server, acc.currency, acc.leverage, acc.trade_mode)
            self.prev_account = acc
            if self.live_exec is None:
                from mt5.execution import LiveExecutionEngine
                self.live_exec = LiveExecutionEngine(app_state, int(self.settings.get("magic_number", 260901)),
                                                     self.settings.get("comment", "LDZ_TRADING_TERMINAL"), db=self.db)
            try:
                from mt5.market_data import list_symbols
                cur = self.symbol.currentText()
                names = list_symbols()
                if names:
                    self.symbol.clear(); self.symbol.addItems(names); self.symbol.setCurrentText(cur)
            except Exception as e:
                log.warning(f"No se pudo listar símbolos: {e}")
        self._update_buttons()

    def _monitor_tick(self) -> None:
        if self.connector.state in (ConnectionState.DISCONNECTED, ConnectionState.ERROR) and self.prev_account is None:
            return
        state, acc = self.connector.ping()
        if state == ConnectionState.ACCOUNT_CHANGED:
            old = self.prev_account
            if self.live_exec:
                self.live_exec.kill_switch()
            else:
                app_state.revoke_real_trading(); app_state.lock_trading()
            self._set_mode(AppMode.LIVE if self.btn_live.isChecked() else self.mode)
            dialogs.account_changed(self, f"{old.login} @ {old.server}" if old else "?", f"{acc.login} @ {acc.server}")
            self.symbol.setCurrentText(self.symbol.currentText())
            app_state.unlock_trading()        # sincronizada; el trading REAL sigue revocado
            self._apply_connection(ConnectionState.CONNECTED, acc)
        elif state == ConnectionState.DISCONNECTED:
            app_state.lock_trading()
            self.lbl_status.setText("MT5: RECONNECTING...  (LIVE TRADING = LOCKED)")
            self.lbl_status.setStyleSheet("padding:2px 10px;color:#ffd54f;font-weight:bold")
            s2, acc2 = self.connector.connect()
            if s2 == ConnectionState.CONNECTED:
                if self.prev_account and acc2.identity_key() != self.prev_account.identity_key():
                    if self.live_exec:
                        self.live_exec.kill_switch()
                    dialogs.account_changed(self, self.prev_account.login, acc2.login)
                app_state.unlock_trading()
                self._apply_connection(s2, acc2)
        elif state == ConnectionState.CONNECTED and acc:
            self.lbl_balance.setText(f"Balance: {acc.balance:,.2f} {acc.currency}")
            self.lbl_equity.setText(f"Equity: {acc.equity:,.2f} {acc.currency}")
        self._update_buttons()

    # ======================================================================
    # Modo y seguridad
    # ======================================================================
    def _set_mode(self, mode: AppMode) -> None:
        if mode == AppMode.REAL and not app_state.real_trading_enabled:
            mode = AppMode.LIVE
        self.mode = mode
        app_state.mode = mode
        label = {AppMode.LIVE: ("LIVE DATA", "LIVE"), AppMode.REPLAY: ("REPLAY", "REPLAY"),
                 AppMode.PAPER: ("SIMULATION", "SIMULATION"), AppMode.SYNTHETIC: ("SYNTHETIC · DATOS NO REALES", "SYNTHETIC"),
                 AppMode.REAL: ("🔴 REAL TRADING", "REAL")}[mode]
        self.lbl_mode.setText(label[0])
        self.lbl_mode.setObjectName(f"mode_{label[1]}")
        self.lbl_mode.setStyleSheet("")
        self.lbl_mode.style().unpolish(self.lbl_mode); self.lbl_mode.style().polish(self.lbl_mode)
        self._update_buttons()

    def _real_route(self) -> bool:
        return (self.mode == AppMode.REAL and app_state.can_send_real_orders()
                and self.live_exec is not None and self.btn_live.isChecked())

    def _update_buttons(self) -> None:
        connected = self.connector.state == ConnectionState.CONNECTED
        self.btn_auth.setEnabled(connected and self.btn_live.isChecked() and not app_state.real_trading_enabled)
        self.btn_kill.setEnabled(app_state.real_trading_enabled)
        self.btn_close_real.setEnabled(connected and self.live_exec is not None)
        self.trade_panel.set_route(self._real_route())
        ok, why = self._can_trade()
        self.trade_panel.set_trading_enabled(ok, why)

    def _can_trade(self) -> tuple[bool, str]:
        if self.paper is None or self.replay is None:
            return False, "Carga datos primero"
        if self.replay.idx < self.paper_idx:
            return False, "Estás viendo el pasado: avanza hasta el presente del replay para operar"
        if app_state.trading_locked and self._real_route():
            return False, "Trading bloqueado"
        return True, ""

    def _authorize_real(self) -> None:
        acc = self.connector.account
        if acc is None or self.live_exec is None or not self.btn_live.isChecked():
            QtWidgets.QMessageBox.warning(self, "Real", "El trading real solo se autoriza en modo LIVE con MT5 conectado.")
            return
        if not dialogs.confirm_real_trading(self, acc.login, acc.server):
            return
        try:
            app_state.mode = AppMode.LIVE
            self.live_exec.authorize(acc.login, acc.server)
            app_state.unlock_trading()
            self._set_mode(AppMode.REAL)
            log.warning(f"TRADING REAL AUTORIZADO para {acc.login}@{acc.server}")
        except Exception as e:
            QtWidgets.QMessageBox.critical(self, "Real", str(e))

    def _kill_switch(self) -> None:
        if self.live_exec:
            self.live_exec.kill_switch()
        else:
            app_state.revoke_real_trading(); app_state.lock_trading()
        app_state.unlock_trading()   # el bloqueo efectivo es la revocación: hay que re-autorizar
        self._set_mode(AppMode.LIVE if self.btn_live.isChecked() else AppMode.REPLAY)
        log.warning("KILL SWITCH: trading real bloqueado (las posiciones existentes NO se cierran)")

    def _close_real_positions(self) -> None:
        if self.live_exec is None:
            return
        try:
            pos = self.live_exec.own_positions()
        except Exception as e:
            QtWidgets.QMessageBox.critical(self, "Posiciones", str(e)); return
        if not pos:
            QtWidgets.QMessageBox.information(self, "Posiciones", "No hay posiciones abiertas de este sistema "
                                                                  "(las manuales no se tocan).")
            return
        txt = "\n".join(f"#{p.ticket} {p.symbol} {p.volume} profit {p.profit}" for p in pos)
        if not dialogs.confirm(self, "CERRAR POSICIONES", f"Se cerrarán SOLO las posiciones del sistema (magic):\n\n{txt}\n\n¿Continuar?"):
            return
        for p in pos:
            try:
                self.live_exec.close_position(p.ticket)
            except Exception as e:
                log.error(f"No se pudo cerrar {p.ticket}: {e}")

    # ======================================================================
    # Carga de datos
    # ======================================================================
    def _load(self) -> None:
        self._pause()
        self.btn_live.setChecked(False)
        symbol = self.symbol.currentText().strip()
        base = self.base_tf.currentText()
        QtWidgets.QApplication.setOverrideCursor(QtCore.Qt.WaitCursor)
        try:
            if self.src.currentText() == "CSV":
                path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Histórico CSV", str(ROOT / "data" / "history"), "CSV (*.csv)")
                if not path:
                    return
                from mt5.market_data import load_history
                raw, spec_d = load_history(Path(path))
                df, rep = validate_bars(raw, base)
                if spec_d:
                    symbol = spec_d.get("symbol", symbol)
            else:
                if self.connector.state != ConnectionState.CONNECTED:
                    self._try_connect()
                df, rep = self.dm.get_bars(symbol, base, self.nbars.value(),
                                           use_mt5=self.connector.state == ConnectionState.CONNECTED)
                spec_d = None
                if self.connector.state == ConnectionState.CONNECTED:
                    from mt5.market_data import get_symbol_spec, save_history
                    spec_d = get_symbol_spec(symbol)
                    self.db.save_symbol_spec(spec_d)
                    save_history(df, spec_d, ROOT / "data" / "history", base)
                else:
                    spec_d = self.db.load_symbol_spec(symbol)
            log.info(f"Datos {symbol} {base}: {rep.summary()}")
            for g in rep.gaps[:10]:
                log.info(f"  hueco: {g['after']} → {g['before']} ({g['missing_bars']} velas)")
            if spec_d:
                self.spec = SymbolSpec.from_dict(spec_d)
            else:
                from simulation.synthetic_market import infer_digits
                d = infer_digits(df[["open", "high", "low", "close"]].to_numpy().ravel())
                self.spec = SymbolSpec(symbol, d, 10 ** -d)
                log.warning("Sin especificación del símbolo: el P&L se expresa en PUNTOS")
            self._build_session(df, base)
        except Exception as e:
            log.error(f"Error cargando datos: {e}")
            QtWidgets.QMessageBox.critical(self, "Datos", str(e))
        finally:
            QtWidgets.QApplication.restoreOverrideCursor()

    def _build_session(self, df: pd.DataFrame, base: str) -> None:
        synth = None
        if self.chk_synth.isChecked():
            from simulation.synthetic_market import MarketCalibration, SimConfig, SyntheticMarket
            calib = MarketCalibration(df, base, block_size=30)
            seed = self.seed.value() or int(datetime.now().timestamp())
            synth = SyntheticMarket(calib, SimConfig(timeframe=base, vol_multiplier=self.vol.value(),
                                                      seed=seed, digits=self.spec.digits))
            log.info(f"Mercado sintético activo (semilla {seed}): al acabar los datos reales el replay sigue con datos NO reales")
        tfs = [s.currentText() for s in self.tf_selectors]
        start = None if self.chk_end.isChecked() else self.start_dt.dateTime().toPython().replace(tzinfo=timezone.utc)
        self.replay = ReplayEngine(df, base, tuple(sorted(set(tfs + [base]), key=lambda t: TIMEFRAME_SECONDS[t])),
                                   start, synthetic_market=synth)
        if self.chk_end.isChecked():
            self.replay.idx = self.replay.n_real
            self.replay.start_idx = self.replay.n_real
        self.replay_panel.goto.setDateTime(QtCore.QDateTime(self.replay.current_time.replace(tzinfo=None)))
        self._rebuild_smc()
        bal = self.connector.account.balance if self.connector.account else 10_000.0
        self.paper = PaperTradingEngine(self.spec, PaperConfig(initial_balance=bal),
                                        synthetic=synth is not None)
        lb = self.replay.last_closed_bar
        self.paper.update_quote(lb.close, lb.spread, self.replay.current_time)
        self.paper_idx = self.replay.idx
        self.bt_result = None
        self._set_mode(AppMode.SYNTHETIC if self.replay.in_synthetic_zone else AppMode.REPLAY)
        self._refresh()

    def _rebuild_smc(self) -> None:
        if self.replay is None:
            return
        cfg = self.smc_panel.config()
        base = self.replay.base_tf
        tfs = set(self.replay.chart_tfs) | {base}
        self.engines = {tf: SMCEngine(tf, cfg, self.spec.point) for tf in tfs}
        self.aggs = {tf: BarAggregator(tf, base) for tf in tfs if tf != base}
        self.fed_idx = 0
        self._feed(len(self.replay.bars))     # cálculo causal; el reloj filtra lo visible
        self._smc_version += 1
        self._refresh()

    def _feed(self, upto: int) -> None:
        base = self.replay.base_tf
        for b in self.replay.bars[self.fed_idx:upto]:
            self.engines[base].on_bar(b)
            for tf, agg in self.aggs.items():
                for c in agg.update(b):
                    self.engines[tf].on_bar(c)
        self.fed_idx = max(self.fed_idx, upto)

    def _change_chart_tf(self, k: int, tf: str) -> None:
        self.charts[k].timeframe = tf
        self.charts[k].title.setText(tf)
        if self.replay is not None:
            df = self.replay.base_df
            if not is_derivable(tf, self.replay.base_tf):
                QtWidgets.QMessageBox.warning(self, "TF", f"{tf} no se puede derivar de {self.replay.base_tf}")
                return
            if tf not in self.replay.chart_tfs:
                self.replay.chart_tfs.append(tf)
                self.replay._resampled_upto = -1
                self._rebuild_smc()
            else:
                self._refresh()

    # ======================================================================
    # Replay
    # ======================================================================
    def _advance(self) -> bool:
        r = self.replay
        if r is None or not r.step_forward():
            return False
        if r.idx > self.fed_idx:
            self._feed(r.idx)
        if r.idx > self.paper_idx:
            for i in range(self.paper_idx, r.idx):
                b = r.bars[i]
                for t in self.paper.on_bar(b, b.time + r.base_delta):
                    log.info(f"Simulada #{t.id} cerrada por {t.exit_reason} @ {t.exit_price}: {t.profit} {self.paper.currency}")
            self.paper_idx = r.idx
        if r.in_synthetic_zone and self.mode != AppMode.SYNTHETIC:
            self._set_mode(AppMode.SYNTHETIC)
        return True

    def _next(self) -> None:
        if self._advance():
            self._refresh()

    def _prev(self) -> None:
        if self.replay and self.replay.step_back():
            self._refresh()

    def _play(self) -> None:
        if self.replay is None:
            return
        self.replay.play()
        self.play_timer.start(self.replay.interval_ms())

    def _pause(self) -> None:
        if self.replay:
            self.replay.pause()
        self.play_timer.stop()

    def _toggle_play(self) -> None:
        if self.replay and self.replay.state == ReplayState.PLAYING:
            self._pause()
        else:
            self._play()

    def _play_tick(self) -> None:
        for _ in range(self.replay.bars_per_tick() if self.replay else 1):
            if not self._advance():
                self._pause()
                log.info("Replay: fin de los datos")
                break
        self._refresh()

    def _speed(self, s: float) -> None:
        if self.replay:
            self.replay.set_speed(s)
            if self.play_timer.isActive():
                self.play_timer.start(self.replay.interval_ms())

    def _reset(self) -> None:
        if self.replay is None:
            return
        self._pause()
        self.replay.reset()
        self._refresh()

    def _jump(self, t) -> None:
        """Ir a un instante: hacia atrás solo mira; hacia delante avanza vela a vela (simulación coherente)."""
        if self.replay is None:
            return
        if isinstance(t, datetime) and t.tzinfo is None:
            t = t.replace(tzinfo=timezone.utc)
        target = self.replay._index_for(t)
        target = max(1, min(target, len(self.replay.bars)))
        if target <= self.replay.idx:
            self.replay.idx = target
        else:
            while self.replay.idx < target and self._advance():
                pass
        self._refresh()

    def _next_trade(self) -> None:
        if not self.bt_result or not self.replay:
            return
        now = self.replay.current_time
        nxt = [t for t in self.bt_result.trades if t.entry_time and t.entry_time > now]
        if nxt:
            self._jump(nxt[0].entry_time + self.replay.base_delta)

    # ======================================================================
    # Render
    # ======================================================================
    def _refresh(self) -> None:
        r = self.replay
        if r is None:
            return
        clock = r.current_time
        tag = " · SINTÉTICO" if r.in_synthetic_zone else ""
        self.replay_panel.clock.setText(f"Reloj replay: {clock:%Y-%m-%d %H:%M} UTC/broker{tag}  ·  vela {r.idx}/{len(r.bars)}")
        opts = self.smc_panel.options()
        trades = list(self.paper.trades) if self.paper else []
        if self.bt_result is not None and self.show_bt:
            trades += self.bt_result.trades
        trade_sig = (len(trades), sum(t.status == "CLOSED" for t in trades), clock if self.bt_result else None)
        for ch in self.charts:
            tf = ch.timeframe
            if tf not in r.chart_tfs:
                continue
            df = r.visible(tf).tail(MAX_BARS_DRAWN)
            changed = ch.set_bars(df, r.forming(tf))
            key = (changed, tuple(sorted(opts.items())), self._smc_version)
            if changed or getattr(ch, "_smc_key", None) != key[1:]:
                if len(df) and tf in self.engines:
                    snap = self.engines[tf].snapshot(clock)
                    ch.smc_layer.draw_smc(snap, ch.x_of, len(df), opts)
                    ch.title.setText(f"{tf}  ·  estructura {snap.state}")
                else:
                    ch.smc_layer.clear()
                ch._smc_key = key[1:]
            if changed or getattr(ch, "_trade_sig", None) != trade_sig:
                ch.trade_layer.draw_trades(trades, ch.x_of, clock)
                ch._trade_sig = trade_sig
            dsig = (self._drawings_version, changed)
            if changed or getattr(ch, "_draw_sig", None) != self._drawings_version:
                ch.draw_drawings(self._drawings_for(tf))
                ch._draw_sig = self._drawings_version
        # Top-down descriptivo
        lines = []
        for tf in sorted(self.engines, key=lambda t: -TIMEFRAME_SECONDS[t]):
            s = self.engines[tf].snapshot(clock)
            ev = s.events[-1] if s.events else None
            fv = [g for g, st in s.fvgs if st in ("OPEN", "PARTIALLY_FILLED")]
            lines.append(f"{tf:>4}: {s.state:<8}" + (f" | último {ev.type} {ev.direction} @ {ev.price}" if ev else "")
                         + (f" | FVG {fv[-1].direction}" if fv else ""))
        self.topdown_box.setPlainText("\n".join(lines))
        self._update_positions()
        self._update_trade_panel()
        self._update_buttons()

    def _update_positions(self) -> None:
        if not self.paper:
            return
        tr = self.paper.trades[-200:]
        self.positions.setRowCount(len(tr))
        for i, t in enumerate(reversed(tr)):
            pnl = self.paper.floating(t) if t.status == "OPEN" else t.profit
            vals = [t.id, t.direction, t.volume, t.entry_price, t.stop_loss, t.take_profit,
                    t.status if t.status != "CLOSED" else f"{t.exit_reason} @ {t.exit_price}",
                    None if pnl is None else round(pnl, 2), t.r_multiple]
            for c, v in enumerate(vals):
                self.positions.setItem(i, c, QtWidgets.QTableWidgetItem("N/A" if v is None else str(v)))

    # ======================================================================
    # Operaciones
    # ======================================================================
    def _compute_order(self, direction: str, p: dict) -> dict:
        bid, ask = self.paper.bid, self.paper.ask
        entry = ask if direction == "BUY" else bid
        bars = self.replay.visible_base_bars()[-200:] if self.replay else []
        a = atr([b.high for b in bars], [b.low for b in bars], [b.close for b in bars]) if bars else None
        struct = None
        base_eng = self.engines.get(self.replay.base_tf) if self.replay else None
        if base_eng and p["sl_mode"] == "STRUCTURE":
            snap = base_eng.snapshot(self.replay.current_time)
            kind = "LOW" if direction == "BUY" else "HIGH"
            sw = [s for s in snap.swings if s.kind == kind]
            struct = sw[-1].price if sw else None
        sl = stop_from(p["sl_mode"], direction, entry, p["sl"], self.spec, a, struct) if p["sl"] or p["sl_mode"] == "STRUCTURE" else None
        tp = None
        if p["tp_mode"] == "R:R" and sl is not None:
            tp = take_profit_rr(direction, entry, sl, p["tp"], self.spec.digits)
        elif p["tp_mode"] == "PRICE" and p["tp"] > 0:
            tp = p["tp"]
        profit_fn = self.paper.profit_fn
        if self._real_route():
            profit_fn = self._mt5_profit_fn()
        if p["use_risk"]:
            res = size_by_risk(self.paper.balance if not self._real_route() else self.connector.account.balance,
                               p["risk_pct"], direction, entry, sl, self.spec, profit_fn)
            vol, risk_money, reason = res.volume, res.actual_risk, res.reason
        else:
            vol, reason = p["volume"], ""
            risk_money = abs(profit_fn(direction, vol, entry, sl)) if (sl and profit_fn) else None
        return dict(entry=entry, sl=sl, tp=tp, volume=vol, risk_money=risk_money, reason=reason,
                    rr=(abs(tp - entry) / abs(entry - sl)) if (tp and sl) else None)

    def _mt5_profit_fn(self):
        from mt5.connector import mt5
        def fn(direction, volume, p_open, p_close):
            t = mt5.ORDER_TYPE_BUY if direction == "BUY" else mt5.ORDER_TYPE_SELL
            return mt5.order_calc_profit(t, self.spec.symbol, volume, p_open, p_close)
        return fn

    def _update_trade_panel(self) -> None:
        if not self.paper or self.paper.bid is None:
            return
        acc = self.connector.account
        cur = self.paper.currency
        tp = self.trade_panel
        try:
            o = self._compute_order("BUY", tp.params())
            vol, risk, rr = o["volume"], o["risk_money"], o["rr"]
        except Exception:
            vol = risk = rr = None
        tp.set_values(Symbol=self.spec.symbol, Bid=self.paper.bid, Ask=self.paper.ask,
                      Spread=f"{self.paper.spread_points} pts",
                      Account=f"{acc.login}" if acc else "SIMULACIÓN",
                      Balance=f"{self.paper.balance:,.2f} {cur}", Equity=f"{self.paper.equity:,.2f} {cur}",
                      **{"Risk $": None if risk is None else f"{risk:,.2f} {cur}",
                         "Volume": vol, "Margin": None,
                         "R:R": None if rr is None else f"1:{rr:.2f}"})

    def _order(self, direction: str, p: dict) -> None:
        ok, why = self._can_trade()
        if not ok:
            QtWidgets.QMessageBox.information(self, "Operar", why); return
        try:
            o = self._compute_order(direction, p)
        except Exception as e:
            QtWidgets.QMessageBox.warning(self, "Orden", str(e)); return
        if o["volume"] is None:
            QtWidgets.QMessageBox.warning(self, "Orden", f"No se puede calcular el volumen: {o['reason']}"); return
        if self._real_route():
            self._send_real(direction, o)
            return
        errs = validate_stops(direction, self.paper.bid, self.paper.ask, o["sl"], o["tp"], self.spec)
        if errs:
            QtWidgets.QMessageBox.warning(self, "Orden", "\n".join(errs)); return
        try:
            t = self.paper.open(direction, o["volume"], o["sl"], o["tp"], "manual", self.replay.current_time)
            self.db.save_trade(self.mode.name, None, None, self.spec.symbol,
                               {"id": t.id, "direction": t.direction, "volume": t.volume,
                                "entry": t.entry_price, "sl": t.stop_loss, "tp": t.take_profit,
                                "time": t.entry_time, "synthetic": t.synthetic})
            log.info(f"SIMULADA #{t.id} {direction} {t.volume} @ {t.entry_price} SL {t.stop_loss} TP {t.take_profit}")
        except ValueError as e:
            QtWidgets.QMessageBox.warning(self, "Orden", str(e))
        self._refresh()

    def _send_real(self, direction: str, o: dict) -> None:
        from mt5.execution import TradingBlocked
        try:
            pv = self.live_exec.preview(self.spec.symbol, direction, o["volume"], o["sl"], o["tp"])
            if not pv.ok:
                QtWidgets.QMessageBox.critical(self, "order_check", f"Rechazada: retcode {pv.check_retcode} {pv.check_comment}")
                return
            if not dialogs.confirm_order(self, pv, self.connector.account.currency):
                return
            res = self.live_exec.send(pv)
            QtWidgets.QMessageBox.information(self, "Orden real", f"Ejecutada. retcode {res.retcode} deal {res.deal} order {res.order}")
        except TradingBlocked as e:
            QtWidgets.QMessageBox.critical(self, "Orden bloqueada", str(e))
        self._update_buttons()

    def _close_paper(self) -> None:
        if self.paper:
            for t in self.paper.close():
                log.info(f"Simulada #{t.id} cerrada manualmente @ {t.exit_price}: {t.profit}")
            self._refresh()

    # ======================================================================
    # LIVE
    # ======================================================================
    def _toggle_live(self, on: bool) -> None:
        if on:
            if self.connector.state != ConnectionState.CONNECTED or self.replay is None or self.src.currentText() != "MT5":
                QtWidgets.QMessageBox.information(self, "LIVE", "Conecta MT5 y carga datos con fuente MT5 primero.")
                self.btn_live.setChecked(False); return
            if self.replay.in_synthetic_zone:
                QtWidgets.QMessageBox.information(self, "LIVE", "Recarga sin mercado sintético para usar LIVE.")
                self.btn_live.setChecked(False); return
            self._pause()
            self._jump(datetime.now(timezone.utc) + timedelta(days=1))
            self._set_mode(AppMode.LIVE)
            self.live_timer.start(1000)
        else:
            self.live_timer.stop()
            if app_state.real_trading_enabled:
                self._kill_switch()
            self._set_mode(AppMode.REPLAY)

    def _live_tick(self) -> None:
        try:
            from mt5.market_data import current_tick, fetch_rates
            sym, base = self.spec.symbol, self.replay.base_tf
            tick = current_tick(sym)
            if tick is not None and tick.bid > 0:
                t = datetime.fromtimestamp(tick.time, tz=timezone.utc)
                for tr in self.paper.on_tick(tick.bid, tick.ask, t):
                    log.info(f"Simulada #{tr.id} cerrada por {tr.exit_reason} @ {tr.exit_price}")
            last = self.replay.bars[-1].time
            if tick is not None and int(last.timestamp()) + 2 * TIMEFRAME_SECONDS[base] <= tick.time:
                df = fetch_rates(sym, base, 50)
                n = self.replay.append_bars(bars_from_df(df))
                if n:
                    self._feed(len(self.replay.bars))
                    self.paper_idx = self.replay.idx
                    self.db.upsert_candles(sym, base, df)
            self._refresh()
        except Exception as e:
            log.error(f"LIVE: {e}")

    # ======================================================================
    # Backtest
    # ======================================================================
    def _run_backtest(self, p: dict) -> None:
        if self.replay is None:
            QtWidgets.QMessageBox.information(self, "Backtest", "Carga datos primero."); return
        df = self.replay.base_df.copy()
        ambiguity = p["ambiguity"]
        if p.get("use_ticks"):
            df = self._annotate_ticks(df)
            if df is None:
                return
            ambiguity = "TICK_DATA"
        cfg = BacktestConfig(symbol=self.spec.symbol, timeframe=self.replay.base_tf,
                             initial_balance=p["initial_balance"], spread_mode=p["spread_mode"],
                             fixed_spread_points=p["fixed_spread_points"], slippage_points=p["slippage_points"],
                             commission_per_lot=p["commission_per_lot"], ambiguity=ambiguity,
                             apply_swap=p.get("apply_swap", True),
                             topdown_tfs=tuple(t for t in ("W1", "D1", "H4", "H1", "M15")
                                               if is_derivable(t, self.replay.base_tf)),
                             smc=self.smc_panel.config().to_dict())
        strat = SMCFVGStrategy(p["bias_tf"], p["rr"], p["sl_buffer_points"], p["risk_pct"])
        spec = self.spec
        self.bt_panel.btn_run.setEnabled(False)
        self.bt_panel.status.setText(f"Ejecutando sobre {len(df)} velas…")
        w = Worker(lambda: BacktestEngine(df, spec, cfg).run(strat))
        w.sig.done.connect(self._backtest_done)
        w.sig.error.connect(self._backtest_error)
        self.pool.start(w)

    def _annotate_ticks(self, df: pd.DataFrame):
        """Descarga ticks de MT5 (hilo principal: la librería no es thread-safe) y anota el orden intra-vela."""
        key = (self.spec.symbol, self.replay.base_tf, len(df), str(df["time"].iloc[-1]))
        if getattr(self, "_ticks_cache", (None,))[0] == key:
            return self._ticks_cache[1]
        if self.connector.state != ConnectionState.CONNECTED:
            QtWidgets.QMessageBox.warning(self, "Ticks", "Para TICK_DATA hace falta MT5 conectado.")
            return None
        from data.ticks import annotate_from_mt5
        dlg = QtWidgets.QProgressDialog("Descargando ticks de MT5…", "Cancelar", 0, 100, self)
        dlg.setWindowModality(QtCore.Qt.WindowModal)
        dlg.show()

        def prog(f):
            dlg.setValue(int(f * 100))
            QtWidgets.QApplication.processEvents()
        try:
            out, cov = annotate_from_mt5(df, self.spec.symbol, self.replay.base_tf, prog)
        except Exception as e:
            dlg.close()
            QtWidgets.QMessageBox.critical(self, "Ticks", str(e))
            return None
        dlg.close()
        log.info(f"Orden intra-vela desde ticks: cobertura {cov:.1%} de las velas")
        if cov < 0.5:
            QtWidgets.QMessageBox.information(
                self, "Ticks", f"El broker solo entregó ticks para el {cov:.0%} de las velas. "
                "Las velas sin ticks usarán WORST_CASE y se contarán en las estadísticas.")
        self._ticks_cache = (key, out)
        return out

    def _backtest_done(self, res) -> None:
        self.bt_panel.btn_run.setEnabled(True)
        self.bt_result = res
        self.bt_panel.show_result(res)
        bid = self.db.save_backtest(res.meta(), res.statistics, res.trades_as_dicts())
        self.bt_panel.status.setText(f"Backtest #{bid} guardado. {res.statistics['total_trades']} operaciones · "
                                     f"neto {res.statistics['net_profit']} {res.currency}. "
                                     f"Usa ⏭ Trade o Play para verlo sin revelar el futuro.")
        log.info(f"Backtest #{bid}: {res.statistics}")
        self._refresh()

    def _backtest_error(self, msg: str) -> None:
        self.bt_panel.btn_run.setEnabled(True)
        self.bt_panel.status.setText("Error en el backtest (ver Logs)")
        log.error(msg)

    def _export_backtest(self) -> None:
        if self.bt_result is None:
            return
        folder = ROOT / "exports" / f"backtest_{datetime.now():%Y%m%d_%H%M%S}"
        paths = self.bt_result.export(folder)
        rows = []
        for tf, eng in self.engines.items():
            for e in eng.structure.events:
                rows.append({"timeframe": tf, "type": e.type, "direction": e.direction, "price": e.price,
                             "detected_at": e.timestamp, "reason": e.reason})
        pd.DataFrame(rows).to_csv(folder / "smc_events.csv", index=False)
        QtWidgets.QMessageBox.information(self, "Exportado", f"Archivos en:\n{folder}")

    # ======================================================================
    # Dibujos y crosshair
    # ======================================================================
    def _set_tool(self, kind) -> None:
        for ch in self.charts:
            ch.set_tool(kind)

    def _save_drawing(self, chart: ChartWidget, kind: str, coords: dict) -> None:
        if not self.spec:
            return
        for ch in self.charts:
            ch.set_tool(None)
        self.db.save_drawing(self.spec.symbol, chart.timeframe, kind, coords, {"color": "#ffeb3b"},
                             self.replay.current_time if self.replay else None)
        self._drawings_version += 1
        self._refresh()

    def _update_drawing(self, drawing_id: int, coords: dict, style: dict) -> None:
        if not self.spec:
            return
        self.db.save_drawing(self.spec.symbol, None, None, coords, style or {"color": "#ffeb3b"},
                             drawing_id=drawing_id)
        self._drawings_version += 1
        self._refresh()

    def _delete_drawing(self, drawing_id: int) -> None:
        self.db.delete_drawing(drawing_id)
        self._drawings_version += 1
        self._refresh()

    def _clear_drawings(self) -> None:
        if not self.spec:
            return
        for ch in self.charts:
            for d in self.db.load_drawings(self.spec.symbol, ch.timeframe):
                self.db.delete_drawing(d["id"])
        self._drawings_version += 1
        self._refresh()

    def _drawings_for(self, tf: str) -> list:
        if not self.spec:
            return []
        key = (self.spec.symbol, tf, self._drawings_version)
        if key not in self._drawings_cache:
            self._drawings_cache = {k: v for k, v in self._drawings_cache.items() if k[2] == self._drawings_version}
            self._drawings_cache[key] = self.db.load_drawings(self.spec.symbol, tf)
        return self._drawings_cache[key]

    def _sync_crosshair(self, src: ChartWidget, t) -> None:
        if self.sync_cross.isChecked():
            for ch in self.charts:
                if ch is not src:
                    ch.show_time(t)

    def closeEvent(self, ev) -> None:
        self.live_timer.stop(); self.play_timer.stop(); self.monitor_timer.stop()
        try:
            self.connector.disconnect()
        finally:
            self.db.close()
        super().closeEvent(ev)
