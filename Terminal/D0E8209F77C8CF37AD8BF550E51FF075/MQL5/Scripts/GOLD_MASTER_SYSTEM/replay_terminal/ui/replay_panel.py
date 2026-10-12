"""ui/replay_panel.py — Controles de replay."""
from __future__ import annotations

from PySide6 import QtCore, QtWidgets

import math

from replay.replay_engine import MAX_SPEED, MIN_SPEED


class ReplayPanel(QtWidgets.QWidget):
    play = QtCore.Signal(); pause = QtCore.Signal(); next = QtCore.Signal()
    prev = QtCore.Signal(); reset = QtCore.Signal(); speed = QtCore.Signal(float)
    next_trade = QtCore.Signal(); jump = QtCore.Signal(object)

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        lay = QtWidgets.QHBoxLayout(self)
        lay.setContentsMargins(4, 2, 4, 2)
        def b(text, sig, tip):
            x = QtWidgets.QPushButton(text); x.setToolTip(tip); x.clicked.connect(sig); lay.addWidget(x); return x
        b("⏮", self.prev, "Vela anterior (←)")
        self.btn_play = b("▶ Play", self.play, "Reproducir (Espacio)")
        b("⏸", self.pause, "Pausa (Espacio)")
        b("⏭", self.next, "Siguiente vela (→)")
        b("🔄 Reset", self.reset, "Reset (R)")
        b("⏭ Trade", self.next_trade, "Ir a la siguiente operación del backtest")
        lay.addWidget(QtWidgets.QLabel("Velocidad"))
        # Slider logarítmico: 0.1x … 200x (posición 0..1000)
        self.speed_slider = QtWidgets.QSlider(QtCore.Qt.Horizontal)
        self.speed_slider.setRange(0, 1000)
        self.speed_slider.setFixedWidth(180)
        self.speed_slider.setToolTip("Velocidad de reproducción (1x = 1 vela por segundo)")
        self.speed_label = QtWidgets.QLabel()
        self.speed_label.setMinimumWidth(52)
        self.speed_label.setStyleSheet("font-weight:bold;color:#90caf9")
        self.speed_slider.valueChanged.connect(self._slider_changed)
        lay.addWidget(self.speed_slider)
        lay.addWidget(self.speed_label)
        for preset in (1, 5, 20, 100):
            pb = QtWidgets.QPushButton(f"{preset}x")
            pb.setFixedWidth(42)
            pb.clicked.connect(lambda _=False, v=preset: self.set_speed_value(v))
            lay.addWidget(pb)
        self.set_speed_value(1.0)
        lay.addWidget(QtWidgets.QLabel("Ir a"))
        self.goto = QtWidgets.QDateTimeEdit()
        self.goto.setDisplayFormat("yyyy-MM-dd HH:mm")
        lay.addWidget(self.goto)
        gb = QtWidgets.QPushButton("Ir")
        gb.clicked.connect(lambda: self.jump.emit(self.goto.dateTime().toPython()))
        lay.addWidget(gb)
        self.clock = QtWidgets.QLabel("—")
        self.clock.setStyleSheet("font-weight:bold;color:#ffd54f;padding-left:12px")
        lay.addWidget(self.clock)
        lay.addStretch()

    @staticmethod
    def _pos_to_speed(pos: int) -> float:
        lo, hi = math.log10(MIN_SPEED), math.log10(MAX_SPEED)
        return round(10 ** (lo + (hi - lo) * pos / 1000), 2)

    @staticmethod
    def _speed_to_pos(v: float) -> int:
        lo, hi = math.log10(MIN_SPEED), math.log10(MAX_SPEED)
        return int(round((math.log10(v) - lo) / (hi - lo) * 1000))

    def set_speed_value(self, v: float) -> None:
        self.speed_slider.setValue(self._speed_to_pos(v))
        self._slider_changed(self.speed_slider.value(), exact=v)

    def _slider_changed(self, pos: int, exact: float | None = None) -> None:
        v = exact if exact is not None else self._pos_to_speed(pos)
        v = min(MAX_SPEED, max(MIN_SPEED, v))
        self.speed_label.setText(f"{v:g}x")
        self.speed.emit(float(v))
