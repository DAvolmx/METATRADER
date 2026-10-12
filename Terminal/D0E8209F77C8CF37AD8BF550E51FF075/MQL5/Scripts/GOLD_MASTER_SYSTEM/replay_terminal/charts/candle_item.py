"""
charts/candle_item.py — Velas japonesas para pyqtgraph (QPicture cacheado).
x = índice de la vela (sin huecos de fin de semana en el eje).
"""
from __future__ import annotations

import numpy as np
import pyqtgraph as pg
from PySide6 import QtCore, QtGui

BULL = QtGui.QColor("#26a69a")
BEAR = QtGui.QColor("#ef5350")
SYNTH_BULL = QtGui.QColor("#7e57c2")
SYNTH_BEAR = QtGui.QColor("#ba68c8")


class CandlestickItem(pg.GraphicsObject):
    """Velas CERRADAS (se redibuja solo si cambian)."""

    def __init__(self) -> None:
        super().__init__()
        self._pic = QtGui.QPicture()
        self._rect = QtCore.QRectF()

    def set_data(self, o, h, l, c, synthetic=None) -> None:
        o, h, l, c = map(np.asarray, (o, h, l, c))
        n = len(o)
        syn = np.zeros(n, bool) if synthetic is None else np.asarray(synthetic, bool)
        pic = QtGui.QPicture()
        p = QtGui.QPainter(pic)
        w = 0.35
        pens = {}
        for i in range(n):
            up = c[i] >= o[i]
            col = (SYNTH_BULL if up else SYNTH_BEAR) if syn[i] else (BULL if up else BEAR)
            key = col.name()
            if key not in pens:
                pn = pg.mkPen(col, width=1); pn.setCosmetic(True)
                pens[key] = (pn, pg.mkBrush(col))
            pn, br = pens[key]
            p.setPen(pn)
            p.setBrush(br)
            p.drawLine(QtCore.QPointF(i, l[i]), QtCore.QPointF(i, h[i]))
            body = c[i] - o[i]
            if abs(body) < 1e-12:
                p.drawLine(QtCore.QPointF(i - w, o[i]), QtCore.QPointF(i + w, o[i]))
            else:
                p.drawRect(QtCore.QRectF(i - w, o[i], 2 * w, body))
        p.end()
        self.prepareGeometryChange()
        self._pic = pic
        self._rect = QtCore.QRectF(-1, float(l.min()), n + 2, float(h.max() - l.min())) if n else QtCore.QRectF()
        self.update()

    def paint(self, p, *args) -> None:
        p.drawPicture(0, 0, self._pic)

    def boundingRect(self) -> QtCore.QRectF:
        return self._rect


class FormingCandle(pg.GraphicsObject):
    """Vela en formación (hueca, discontinua). No la usan los indicadores."""

    def __init__(self) -> None:
        super().__init__()
        self.bar = None
        self.x = 0

    def set_bar(self, x: int, bar) -> None:
        self.prepareGeometryChange()
        self.x, self.bar = x, bar
        self.update()

    def boundingRect(self) -> QtCore.QRectF:
        if self.bar is None:
            return QtCore.QRectF()
        return QtCore.QRectF(self.x - 0.5, self.bar.low, 1, (self.bar.high - self.bar.low) or 1e-9)

    def paint(self, p, *args) -> None:
        b = self.bar
        if b is None:
            return
        col = BULL if b.close >= b.open else BEAR
        pn = pg.mkPen(col, width=1, style=QtCore.Qt.DashLine); pn.setCosmetic(True)
        p.setPen(pn)
        p.setBrush(QtCore.Qt.NoBrush)
        p.drawLine(QtCore.QPointF(self.x, b.low), QtCore.QPointF(self.x, b.high))
        p.drawRect(QtCore.QRectF(self.x - 0.35, b.open, 0.7, (b.close - b.open) or 1e-9))
