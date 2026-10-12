"""ui/backtest_panel.py — Backtest: parámetros, métricas, equity/drawdown, operaciones."""
from __future__ import annotations

from core.models import epoch_s

import pandas as pd
import pyqtgraph as pg
from PySide6 import QtCore, QtWidgets

from trading.paper_engine import AMBIGUITY_POLICIES
from trading.statistics import drawdown_series

LABELS = {
    "total_trades": "Total Trades", "wins": "Wins", "losses": "Losses", "breakeven": "Breakeven",
    "win_rate": "Win Rate %", "gross_profit": "Gross Profit", "gross_loss": "Gross Loss",
    "net_profit": "Net Profit", "profit_factor": "Profit Factor", "average_win": "Average Win",
    "average_loss": "Average Loss", "expectancy": "Expectancy", "average_r": "Average R",
    "max_drawdown": "Max Drawdown", "max_drawdown_pct": "Max Drawdown %", "sharpe": "Sharpe",
    "sortino": "Sortino", "calmar": "Calmar", "recovery_factor": "Recovery Factor",
    "payoff_ratio": "Payoff Ratio", "consecutive_wins": "Consecutive Wins",
    "consecutive_losses": "Consecutive Losses", "avg_mae_r": "MAE medio (R)",
    "avg_mfe_r": "MFE medio (R)", "avg_risk_per_trade": "Risk per trade",
    "rejected_orders": "Órdenes rechazadas", "swap_total": "Swap total", "swap_status": "Swap",
    "ambiguous_bars": "Velas SL+TP ambiguas", "ambiguous_fallbacks": "Resueltas por política (sin ticks)",
    "currency": "Moneda",
}


class BacktestPanel(QtWidgets.QWidget):
    run_requested = QtCore.Signal(dict)
    export_requested = QtCore.Signal()
    show_on_chart = QtCore.Signal(bool)
    trade_selected = QtCore.Signal(object)

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        lay = QtWidgets.QHBoxLayout(self)
        left = QtWidgets.QVBoxLayout()
        form = QtWidgets.QFormLayout()
        self.bias = QtWidgets.QComboBox(); self.bias.addItems(["M15", "H1", "H4", "D1", "W1"]); self.bias.setCurrentText("H1")
        self.rr = QtWidgets.QDoubleSpinBox(); self.rr.setRange(0.5, 10); self.rr.setValue(2.0)
        self.risk = QtWidgets.QDoubleSpinBox(); self.risk.setRange(0.05, 10); self.risk.setValue(1.0); self.risk.setSuffix(" %")
        self.buffer = QtWidgets.QSpinBox(); self.buffer.setRange(0, 10000); self.buffer.setValue(20)
        self.balance = QtWidgets.QDoubleSpinBox(); self.balance.setRange(10, 1e9); self.balance.setValue(10000)
        self.spread_mode = QtWidgets.QComboBox(); self.spread_mode.addItems(["HISTORICAL", "FIXED"])
        self.fixed_spread = QtWidgets.QSpinBox(); self.fixed_spread.setRange(0, 100000)
        self.slip = QtWidgets.QDoubleSpinBox(); self.slip.setRange(0, 10000)
        self.comm = QtWidgets.QDoubleSpinBox(); self.comm.setRange(0, 1000)
        self.amb = QtWidgets.QComboBox(); self.amb.addItems(AMBIGUITY_POLICIES)
        self.swap = QtWidgets.QCheckBox("Aplicar swap del símbolo"); self.swap.setChecked(True)
        self.ticks = QtWidgets.QCheckBox("Orden intra-vela desde ticks MT5 (TICK_DATA)")
        for lab, w in [("Sesgo (TF)", self.bias), ("R:R", self.rr), ("Riesgo", self.risk),
                       ("Buffer SL (pts)", self.buffer), ("Balance inicial", self.balance),
                       ("Spread", self.spread_mode), ("Spread fijo (pts)", self.fixed_spread),
                       ("Slippage (pts)", self.slip), ("Comisión / lote", self.comm),
                       ("Ambigüedad OHLC", self.amb), ("", self.swap), ("", self.ticks)]:
            form.addRow(lab, w)
        left.addLayout(form)
        self.btn_run = QtWidgets.QPushButton("▶ Ejecutar backtest (SMC_FVG v1.0)")
        self.btn_run.clicked.connect(lambda: self.run_requested.emit(self.params()))
        left.addWidget(self.btn_run)
        self.chk_chart = QtWidgets.QCheckBox("Mostrar operaciones en el gráfico")
        self.chk_chart.setChecked(True)
        self.chk_chart.toggled.connect(self.show_on_chart)
        left.addWidget(self.chk_chart)
        btn_exp = QtWidgets.QPushButton("Exportar CSV/JSON")
        btn_exp.clicked.connect(self.export_requested)
        left.addWidget(btn_exp)
        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        left.addWidget(self.status)
        left.addStretch()
        lay.addLayout(left, 1)

        self.stats = QtWidgets.QTableWidget(len(LABELS), 2)
        self.stats.setHorizontalHeaderLabels(["Métrica", "Valor"])
        self.stats.verticalHeader().hide()
        for i, (k, lab) in enumerate(LABELS.items()):
            self.stats.setItem(i, 0, QtWidgets.QTableWidgetItem(lab))
            self.stats.setItem(i, 1, QtWidgets.QTableWidgetItem("—"))
        self.stats.horizontalHeader().setStretchLastSection(True)
        lay.addWidget(self.stats, 1)

        right = QtWidgets.QVBoxLayout()
        self.eq_plot = pg.PlotWidget(axisItems={"bottom": pg.DateAxisItem()}, title="Equity")
        self.dd_plot = pg.PlotWidget(axisItems={"bottom": pg.DateAxisItem()}, title="Drawdown %")
        self.dd_plot.setXLink(self.eq_plot)
        right.addWidget(self.eq_plot, 2)
        right.addWidget(self.dd_plot, 1)
        self.trades = QtWidgets.QTableWidget(0, 10)
        self.trades.setHorizontalHeaderLabels(["#", "Dir", "Vol", "Entrada", "Precio", "SL", "TP",
                                               "Salida", "Profit", "R"])
        self.trades.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectRows)
        self.trades.itemSelectionChanged.connect(self._sel)
        right.addWidget(self.trades, 2)
        lay.addLayout(right, 3)
        self._trades = []

    def params(self) -> dict:
        return dict(bias_tf=self.bias.currentText(), rr=self.rr.value(), risk_pct=self.risk.value(),
                    sl_buffer_points=self.buffer.value(), initial_balance=self.balance.value(),
                    spread_mode=self.spread_mode.currentText(), fixed_spread_points=self.fixed_spread.value(),
                    slippage_points=self.slip.value(), commission_per_lot=self.comm.value(),
                    ambiguity=self.amb.currentText(), apply_swap=self.swap.isChecked(),
                    use_ticks=self.ticks.isChecked())

    def show_result(self, res) -> None:
        for i, k in enumerate(LABELS):
            v = res.statistics.get(k)
            self.stats.item(i, 1).setText("N/A" if v is None else str(v))
        eq = res.equity
        x = epoch_s(eq["time"]).astype(float)
        self.eq_plot.clear()
        self.eq_plot.plot(x, eq["equity"].to_numpy(), pen=pg.mkPen("#2962ff", width=1.5))
        self.eq_plot.plot(x, eq["balance"].to_numpy(), pen=pg.mkPen("#787b86", width=1))
        _, ddp = drawdown_series(eq.set_index("time")["equity"])
        self.dd_plot.clear()
        self.dd_plot.plot(x, ddp.fillna(0).to_numpy(), pen=pg.mkPen("#ef5350"), fillLevel=0,
                          brush=(239, 83, 80, 60))
        self._trades = res.trades
        self.trades.setRowCount(len(res.trades))
        for r, t in enumerate(res.trades):
            vals = [t.id, t.direction, t.volume, f"{t.entry_time:%Y-%m-%d %H:%M}", t.entry_price,
                    t.stop_loss, t.take_profit, t.exit_reason, t.profit, t.r_multiple]
            for c, v in enumerate(vals):
                it = QtWidgets.QTableWidgetItem("N/A" if v is None else str(v))
                if c == 8 and t.profit is not None:
                    it.setForeground(pg.mkColor("#26a69a" if t.profit > 0 else "#ef5350"))
                self.trades.setItem(r, c, it)

    def _sel(self) -> None:
        rows = {i.row() for i in self.trades.selectedItems()}
        if rows:
            self.trade_selected.emit(self._trades[min(rows)])
