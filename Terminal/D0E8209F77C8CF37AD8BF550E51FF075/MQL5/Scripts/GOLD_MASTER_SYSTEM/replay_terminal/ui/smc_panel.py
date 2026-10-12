"""ui/smc_panel.py — Activación de componentes SMC y parámetros."""
from __future__ import annotations

from PySide6 import QtCore, QtWidgets

from smc.smc_engine import SMCConfig

ITEMS = [("swings", "Swing High/Low"), ("bos", "BOS"), ("choch", "CHoCH"), ("eqh", "EQH"),
         ("eql", "EQL"), ("bsl", "BSL"), ("ssl", "SSL"), ("fvg", "FVG"), ("order_blocks", "Order Blocks")]


class SMCPanel(QtWidgets.QGroupBox):
    changed = QtCore.Signal()          # visibilidad
    params_changed = QtCore.Signal()   # requiere recalcular

    def __init__(self, cfg: SMCConfig, parent=None) -> None:
        super().__init__("SMC", parent)
        lay = QtWidgets.QGridLayout(self)
        self.checks = {}
        for i, (k, label) in enumerate(ITEMS):
            cb = QtWidgets.QCheckBox(label)
            cb.setChecked(cfg.enabled.get(k, True))
            cb.toggled.connect(self.changed)
            lay.addWidget(cb, i // 2, i % 2)
            self.checks[k] = cb
        r = len(ITEMS) // 2 + 1
        self.left = QtWidgets.QSpinBox(); self.left.setRange(1, 50); self.left.setValue(cfg.swing_left_bars)
        self.right = QtWidgets.QSpinBox(); self.right.setRange(1, 50); self.right.setValue(cfg.swing_right_bars)
        self.confirm = QtWidgets.QComboBox(); self.confirm.addItems(["CLOSE", "WICK"])
        self.confirm.setCurrentText(cfg.break_confirmation)
        self.tol = QtWidgets.QDoubleSpinBox(); self.tol.setDecimals(3); self.tol.setRange(0, 5)
        self.tol.setSingleStep(0.01); self.tol.setValue(cfg.liquidity_tolerance_pct); self.tol.setSuffix(" %")
        self.disp = QtWidgets.QDoubleSpinBox(); self.disp.setRange(0, 20); self.disp.setValue(cfg.ob_min_displacement)
        self.ranging = QtWidgets.QComboBox(); self.ranging.addItems(["Sí", "No"])
        self.ranging.setCurrentText("Sí" if cfg.ranging_enabled else "No")
        form = [("Swing izq.", self.left), ("Swing der.", self.right), ("Ruptura", self.confirm),
                ("Tol. EQ", self.tol), ("OB desplaz.", self.disp), ("Detectar RANGO", self.ranging)]
        for j, (lab, w) in enumerate(form):
            lay.addWidget(QtWidgets.QLabel(lab), r + j, 0)
            lay.addWidget(w, r + j, 1)
        btn = QtWidgets.QPushButton("Recalcular SMC")
        btn.clicked.connect(self.params_changed)
        lay.addWidget(btn, r + len(form), 0, 1, 2)
        self.base_cfg = cfg

    def options(self) -> dict:
        return {k: cb.isChecked() for k, cb in self.checks.items()}

    def config(self) -> SMCConfig:
        d = self.base_cfg.to_dict()
        d.update(swing_left_bars=self.left.value(), swing_right_bars=self.right.value(),
                 break_confirmation=self.confirm.currentText(),
                 liquidity_tolerance_pct=self.tol.value(), ob_min_displacement=self.disp.value(),
                 ranging_enabled=self.ranging.currentText() == "Sí")
        d["enabled"] = self.options()
        return SMCConfig(**d)
