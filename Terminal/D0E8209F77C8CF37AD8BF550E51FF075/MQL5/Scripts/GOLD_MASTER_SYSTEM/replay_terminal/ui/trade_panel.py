"""
ui/trade_panel.py — Panel de operación.

Muestra antes de operar: símbolo, bid, ask, spread, cuenta, balance, equity,
riesgo %, SL, TP, riesgo $, volumen, margen y R:R. Lo que no se puede
calcular se muestra como N/A (nunca se inventa).
El panel NO decide si la orden es real o virtual: emite order_requested y el
controlador la enruta (PaperTradingEngine o LiveExecutionEngine).
"""
from __future__ import annotations

from PySide6 import QtCore, QtWidgets


class TradePanel(QtWidgets.QGroupBox):
    order_requested = QtCore.Signal(str, dict)   # BUY/SELL, params
    close_all = QtCore.Signal()
    params_changed = QtCore.Signal()

    def __init__(self, parent=None) -> None:
        super().__init__("Trade Panel", parent)
        g = QtWidgets.QGridLayout(self)
        self.lbl = {}
        info = ["Symbol", "Bid", "Ask", "Spread", "Account", "Balance", "Equity",
                "Risk $", "Volume", "Margin", "R:R"]
        for i, k in enumerate(info):
            g.addWidget(QtWidgets.QLabel(k), i % 6, (i // 6) * 2)
            v = QtWidgets.QLabel("N/A")
            v.setStyleSheet("font-weight:bold")
            g.addWidget(v, i % 6, (i // 6) * 2 + 1)
            self.lbl[k] = v
        r = 6
        self.use_risk = QtWidgets.QCheckBox("Lotaje por riesgo")
        self.use_risk.setChecked(True)
        self.risk = QtWidgets.QDoubleSpinBox(); self.risk.setRange(0.01, 10); self.risk.setValue(1.0)
        self.risk.setSingleStep(0.25); self.risk.setSuffix(" %")
        self.volume = QtWidgets.QDoubleSpinBox(); self.volume.setDecimals(2); self.volume.setRange(0.01, 100)
        self.volume.setValue(0.01); self.volume.setSingleStep(0.01)
        self.sl_mode = QtWidgets.QComboBox(); self.sl_mode.addItems(["PRICE", "POINTS", "PERCENT", "ATR", "STRUCTURE"])
        self.sl = QtWidgets.QDoubleSpinBox(); self.sl.setDecimals(5); self.sl.setRange(0, 10_000_000)
        self.tp_mode = QtWidgets.QComboBox(); self.tp_mode.addItems(["R:R", "PRICE", "NONE"])
        self.tp = QtWidgets.QDoubleSpinBox(); self.tp.setDecimals(5); self.tp.setRange(0, 10_000_000); self.tp.setValue(2.0)
        rows = [(self.use_risk, self.risk), (QtWidgets.QLabel("Volumen"), self.volume),
                (self.sl_mode, self.sl), (self.tp_mode, self.tp)]
        for j, (a, b) in enumerate(rows):
            g.addWidget(a, r + j, 0, 1, 2)
            g.addWidget(b, r + j, 2, 1, 2)
        for w in (self.risk, self.volume, self.sl, self.tp):
            w.valueChanged.connect(self.params_changed)
        for w in (self.sl_mode, self.tp_mode):
            w.currentTextChanged.connect(self.params_changed)
        self.use_risk.toggled.connect(self.params_changed)
        r += len(rows)
        self.buy = QtWidgets.QPushButton("BUY"); self.buy.setObjectName("buy")
        self.sell = QtWidgets.QPushButton("SELL"); self.sell.setObjectName("sell")
        self.btn_close = QtWidgets.QPushButton("Cerrar todas (simuladas)")
        g.addWidget(self.buy, r, 0, 1, 2)
        g.addWidget(self.sell, r, 2, 1, 2)
        g.addWidget(self.btn_close, r + 1, 0, 1, 4)
        self.route = QtWidgets.QLabel("Destino: SIMULACIÓN")
        self.route.setStyleSheet("color:#81c784;font-weight:bold")
        g.addWidget(self.route, r + 2, 0, 1, 4)
        self.buy.clicked.connect(lambda: self.order_requested.emit("BUY", self.params()))
        self.sell.clicked.connect(lambda: self.order_requested.emit("SELL", self.params()))
        self.btn_close.clicked.connect(self.close_all)

    def params(self) -> dict:
        return dict(use_risk=self.use_risk.isChecked(), risk_pct=self.risk.value(),
                    volume=self.volume.value(), sl_mode=self.sl_mode.currentText(), sl=self.sl.value(),
                    tp_mode=self.tp_mode.currentText(), tp=self.tp.value())

    def set_values(self, **kw) -> None:
        for k, v in kw.items():
            if k in self.lbl:
                self.lbl[k].setText("N/A" if v is None else str(v))

    def set_route(self, real: bool) -> None:
        if real:
            self.route.setText("Destino: 🔴 REAL TRADING (MT5)")
            self.route.setStyleSheet("color:#ef5350;font-weight:bold")
        else:
            self.route.setText("Destino: SIMULACIÓN (sin órdenes a MT5)")
            self.route.setStyleSheet("color:#81c784;font-weight:bold")

    def set_trading_enabled(self, on: bool, reason: str = "") -> None:
        self.buy.setEnabled(on)
        self.sell.setEnabled(on)
        self.buy.setToolTip(reason)
        self.sell.setToolTip(reason)
