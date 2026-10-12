"""
charts/picture_overlay.py — Capa de dibujo de alto rendimiento.

En vez de crear cientos de QGraphicsItems por refresco (lento), todas las
primitivas (líneas, rectángulos, marcadores, textos) se pintan en UN solo
GraphicsObject. Marcadores y textos se dibujan en coordenadas de pantalla
para que no se deformen con el zoom.
"""
from __future__ import annotations

import pyqtgraph as pg
from PySide6 import QtCore, QtGui

_STYLES = {"solid": QtCore.Qt.SolidLine, "dash": QtCore.Qt.DashLine, "dot": QtCore.Qt.DotLine}


class PictureOverlay(pg.GraphicsObject):
    def __init__(self) -> None:
        super().__init__()
        self.lines: list = []    # (x0,y0,x1,y1,color,width,style)
        self.rects: list = []    # (x,y,w,h,fill_rgba,pen_color|None)
        self.marks: list = []    # (x,y,shape,color,size)
        self.texts: list = []    # (x,y,text,color,anchor_x,anchor_y)
        self._rect = QtCore.QRectF()
        self._font = QtGui.QFont()
        self._font.setPointSize(7)

    # -- construcción -------------------------------------------------------
    def clear(self) -> None:
        self.lines, self.rects, self.marks, self.texts = [], [], [], []

    def line(self, x0, y0, x1, y1, color, width=1.0, style="solid") -> None:
        self.lines.append((x0, y0, x1, y1, color, width, style))

    def rect(self, x, y, w, h, fill, pen=None) -> None:
        self.rects.append((x, y, w, h, fill, pen))

    def mark(self, x, y, shape, color, size=8) -> None:
        self.marks.append((x, y, shape, color, size))

    def text(self, x, y, s, color, ax=0.0, ay=1.0) -> None:
        self.texts.append((x, y, s, color, ax, ay))

    def commit(self) -> None:
        xs, ys = [], []
        for x0, y0, x1, y1, *_ in self.lines:
            xs += [x0, x1]; ys += [y0, y1]
        for x, y, w, h, *_ in self.rects:
            xs += [x, x + w]; ys += [y, y + h]
        for x, y, *_ in self.marks + self.texts:
            xs.append(x); ys.append(y)
        self.prepareGeometryChange()
        if xs:
            self._rect = QtCore.QRectF(min(xs), min(ys), (max(xs) - min(xs)) or 1, (max(ys) - min(ys)) or 1)
        else:
            self._rect = QtCore.QRectF()
        self.update()

    # -- pintado -------------------------------------------------------------
    def boundingRect(self) -> QtCore.QRectF:
        return self._rect

    def paint(self, p: QtGui.QPainter, *args) -> None:
        for x, y, w, h, fill, pen in self.rects:
            p.setBrush(pg.mkBrush(*fill) if isinstance(fill, tuple) else pg.mkBrush(fill))
            p.setPen(pg.mkPen(pen, width=1, cosmetic=True) if pen else QtCore.Qt.NoPen)
            p.drawRect(QtCore.QRectF(x, y, w, h))
        for x0, y0, x1, y1, color, width, style in self.lines:
            pen = pg.mkPen(color, width=width, style=_STYLES.get(style, QtCore.Qt.SolidLine))
            pen.setCosmetic(True)
            p.setPen(pen)
            p.drawLine(QtCore.QPointF(x0, y0), QtCore.QPointF(x1, y1))
        if not (self.marks or self.texts):
            return
        tr = p.transform()
        p.save()
        p.resetTransform()
        p.setFont(self._font)
        fm = QtGui.QFontMetrics(self._font)
        for x, y, shape, color, size in self.marks:
            pt = tr.map(QtCore.QPointF(x, y))
            c = pg.mkColor(color)
            p.setPen(pg.mkPen(c))
            p.setBrush(pg.mkBrush(c))
            s = size / 2
            if shape == "up":
                poly = QtGui.QPolygonF([pt + QtCore.QPointF(0, -s), pt + QtCore.QPointF(-s, s), pt + QtCore.QPointF(s, s)])
                p.drawPolygon(poly)
            elif shape == "down":
                poly = QtGui.QPolygonF([pt + QtCore.QPointF(0, s), pt + QtCore.QPointF(-s, -s), pt + QtCore.QPointF(s, -s)])
                p.drawPolygon(poly)
            elif shape == "square":
                p.setBrush(pg.mkBrush("#131722"))
                p.drawRect(QtCore.QRectF(pt.x() - s, pt.y() - s, 2 * s, 2 * s))
            elif shape == "x":
                p.drawLine(pt + QtCore.QPointF(-s, -s), pt + QtCore.QPointF(s, s))
                p.drawLine(pt + QtCore.QPointF(-s, s), pt + QtCore.QPointF(s, -s))
            else:
                p.drawEllipse(pt, s, s)
        for x, y, s, color, ax, ay in self.texts:
            pt = tr.map(QtCore.QPointF(x, y))
            w, h = fm.horizontalAdvance(s), fm.height()
            p.setPen(pg.mkPen(color))
            p.drawText(QtCore.QPointF(pt.x() - ax * w, pt.y() + (1 - ay) * h - 2), s)
        p.restore()
