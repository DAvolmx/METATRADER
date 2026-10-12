"""
charts/chart_widget.py — Un gráfico de velas: zoom/paneo (rueda/arrastre),
crosshair con OHLCV, overlays SMC/operaciones y herramientas de dibujo.

Coordenadas: x = índice de vela visible. Los dibujos se guardan en TIEMPO
y PRECIO (no en píxeles ni índices), así sobreviven a recargas.
Herramientas implementadas: línea horizontal, línea vertical, trendline,
rectángulo, texto, Fibonacci (0/23.6/38.2/50/61.8/78.6/100) y canal
paralelo (3 clics: dos puntos de la base y un punto del lado opuesto).

Edición: clic en un dibujo lo selecciona (se ven sus anclas). Arrastrar un
ancla mueve ese punto; arrastrar el cuerpo mueve el dibujo entero. Botón
derecho: eliminar / color / editar texto. Tecla Supr: eliminar seleccionado.
Los cambios se guardan en SQLite al soltar.
"""
from __future__ import annotations

from core.models import epoch_ns

from datetime import datetime
from typing import Callable, Optional

import copy
import math

import numpy as np
import pandas as pd
import pyqtgraph as pg
from PySide6 import QtCore, QtGui, QtWidgets

from charts.candle_item import CandlestickItem, FormingCandle
from charts.overlays import OverlayLayer

pg.setConfigOptions(antialias=True, background="#131722", foreground="#d1d4dc")

FIB_LEVELS = (0.0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0)
TOOL_CLICKS = {"hline": 1, "vline": 1, "text": 1, "trend": 2, "rect": 2, "fib": 2, "channel": 3}


HIT_PX = 8


class DrawViewBox(pg.ViewBox):
    """ViewBox que intercepta clics/arrastres sobre dibujos; si no hay dibujo, zoom/paneo normal."""

    def __init__(self) -> None:
        super().__init__()
        self.chart: Optional["ChartWidget"] = None

    def mouseDragEvent(self, ev, axis=None):
        ch = self.chart
        if ch is not None and ev.button() == QtCore.Qt.LeftButton and ch.tool is None:
            if ev.isStart():
                hit = ch.hit_test(ev.buttonDownScenePos())
                if hit is not None:
                    ch.begin_drag(hit, self.mapSceneToView(ev.buttonDownScenePos()))
            if ch._drag is not None:
                ev.accept()
                ch.update_drag(self.mapSceneToView(ev.scenePos()))
                if ev.isFinish():
                    ch.finish_drag()
                return
        super().mouseDragEvent(ev, axis)

    def mouseClickEvent(self, ev):
        ch = self.chart
        if ch is not None and ch.tool is None:
            hit = ch.hit_test(ev.scenePos())
            if hit is not None:
                ev.accept()
                ch.select(hit[0])
                if ev.button() == QtCore.Qt.RightButton:
                    ch.drawing_menu(hit[0], ev.screenPos())
                return
            if ev.button() == QtCore.Qt.LeftButton and ch.selected_id is not None:
                ch.select(None)
        super().mouseClickEvent(ev)


class TimeAxis(pg.AxisItem):
    def __init__(self, chart: "ChartWidget") -> None:
        super().__init__(orientation="bottom")
        self.chart = chart

    def tickStrings(self, values, scale, spacing):
        out = []
        times = self.chart.times
        for v in values:
            i = int(round(v))
            if 0 <= i < len(times):
                t = times[i]
                out.append(t.strftime("%d/%m %H:%M") if spacing < 400 else t.strftime("%d/%m"))
            else:
                out.append("")
        return out


class ChartWidget(QtWidgets.QWidget):
    crosshair_time = QtCore.Signal(object)          # datetime bajo el cursor
    drawing_created = QtCore.Signal(str, dict)       # kind, coords {t1,p1,...}
    drawing_modified = QtCore.Signal(int, dict, dict)  # id, coords, style
    drawing_deleted = QtCore.Signal(int)
    price_clicked = QtCore.Signal(float)

    def __init__(self, timeframe: str, parent=None) -> None:
        super().__init__(parent)
        self.timeframe = timeframe
        self.times: list[datetime] = []
        self._times_ns = np.array([], dtype="int64")
        self.df: Optional[pd.DataFrame] = None
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)
        self.title = QtWidgets.QLabel(timeframe)
        self.title.setStyleSheet("background:#1e222d;color:#d1d4dc;padding:2px 6px;font-weight:bold")
        lay.addWidget(self.title)
        vb = DrawViewBox()
        vb.chart = self
        self.pw = pg.PlotWidget(viewBox=vb, axisItems={"bottom": TimeAxis(self)})
        self.pw.showGrid(x=True, y=True, alpha=0.12)
        self.pw.getPlotItem().showAxis("right")
        self.pw.getPlotItem().hideAxis("left")
        lay.addWidget(self.pw)
        self.plot = self.pw.getPlotItem()
        self.candles = CandlestickItem()
        self.plot.addItem(self.candles)
        self.forming_item = FormingCandle()
        self.plot.addItem(self.forming_item)
        self._sig = None          # firma de los datos dibujados
        self.smc_layer = OverlayLayer(self.plot)
        self.trade_layer = OverlayLayer(self.plot)
        self.draw_layer = OverlayLayer(self.plot)
        # crosshair
        self.vline = pg.InfiniteLine(angle=90, movable=False, pen=pg.mkPen("#787b86", style=QtCore.Qt.DashLine))
        self.hline = pg.InfiniteLine(angle=0, movable=False, pen=pg.mkPen("#787b86", style=QtCore.Qt.DashLine))
        self.plot.addItem(self.vline, ignoreBounds=True)
        self.plot.addItem(self.hline, ignoreBounds=True)
        self.info = pg.TextItem("", color="#d1d4dc", anchor=(0, 0))
        self.plot.addItem(self.info, ignoreBounds=True)
        self.price_line = pg.InfiniteLine(angle=0, movable=False, pen=pg.mkPen("#2962ff", width=1))
        self.plot.addItem(self.price_line, ignoreBounds=True)
        self._mouse_proxy = pg.SignalProxy(self.pw.scene().sigMouseMoved, rateLimit=60, slot=self._on_mouse)
        self.pw.scene().sigMouseClicked.connect(self._on_click)
        self.tool: Optional[str] = None
        self._tool_pts: list[tuple[datetime, float]] = []
        self._follow = True
        self._last_n = 0
        self._drawings: list[dict] = []
        self.selected_id: Optional[int] = None
        self._drag: Optional[dict] = None

    # -- datos ------------------------------------------------------------
    def set_bars(self, df: pd.DataFrame, forming=None) -> bool:
        """Devuelve True si las velas cerradas cambiaron (para redibujar overlays)."""
        n = len(df)
        sig = (n, df["time"].iloc[-1] if n else None, df["time"].iloc[0] if n else None)
        changed = sig != self._sig
        if changed:
            self.df = df.reset_index(drop=True)
            self._times_ns = epoch_ns(self.df["time"]) if n else np.array([], "int64")
            self.times = [t.to_pydatetime() for t in pd.to_datetime(self.df["time"], utc=True)]
            syn = self.df["synthetic"].to_numpy(bool) if "synthetic" in self.df else None
            self.candles.set_data(self.df["open"], self.df["high"], self.df["low"], self.df["close"], syn)
            self._sig = sig
        self.forming_item.set_bar(n, forming)
        if n:
            self.price_line.setPos(forming.close if forming is not None else float(self.df["close"].iloc[-1]))
        if self._follow and changed:
            self._autorange(n)
        return changed

    def _autorange(self, n: int, window: int = 120) -> None:
        if n == 0:
            return
        x0 = max(0, n - window)
        sub = self.df.iloc[x0:]
        lo, hi = float(sub["low"].min()), float(sub["high"].max())
        pad = (hi - lo) * 0.08 or 1
        self.plot.setXRange(x0, n + 8, padding=0)
        self.plot.setYRange(lo - pad, hi + pad, padding=0)

    def set_follow(self, on: bool) -> None:
        self._follow = on

    def x_of(self, t: datetime) -> float:
        """Índice de la vela que contiene t (búsqueda binaria)."""
        if not len(self._times_ns):
            return 0
        v = pd.Timestamp(t).value
        i = int(np.searchsorted(self._times_ns, v, side="right")) - 1
        return float(max(0, i))

    def time_at(self, x: float) -> Optional[datetime]:
        i = int(round(x))
        if 0 <= i < len(self.times):
            return self.times[i]
        if self.times and i >= len(self.times):
            step = (self.times[-1] - self.times[-2]) if len(self.times) > 1 else pd.Timedelta(minutes=1)
            return self.times[-1] + step * (i - len(self.times) + 1)
        return None

    # -- crosshair --------------------------------------------------------
    def _on_mouse(self, evt) -> None:
        pos = evt[0]
        if not self.plot.sceneBoundingRect().contains(pos) or self.df is None:
            return
        mp = self.plot.vb.mapSceneToView(pos)
        self.vline.setPos(mp.x())
        self.hline.setPos(mp.y())
        i = int(round(mp.x()))
        vr = self.plot.vb.viewRange()
        self.info.setPos(vr[0][0], vr[1][1])
        if 0 <= i < len(self.df):
            r = self.df.iloc[i]
            self.info.setText(f"{self.times[i]:%Y-%m-%d %H:%M}  O {r.open}  H {r.high}  L {r.low}  "
                              f"C {r.close}  V {int(r.get('tick_volume', 0))}   precio {mp.y():.2f}")
            self.crosshair_time.emit(self.times[i])

    def show_time(self, t: datetime) -> None:
        """Sincronización de crosshair desde otro gráfico."""
        if len(self.times):
            self.vline.setPos(self.x_of(t))

    # -- dibujo -------------------------------------------------------------
    def set_tool(self, tool: Optional[str]) -> None:
        self.tool = tool
        self._tool_pts = []
        self.pw.setCursor(QtCore.Qt.CrossCursor if tool else QtCore.Qt.ArrowCursor)

    def _on_click(self, ev) -> None:
        if self.df is None:
            return
        mp = self.plot.vb.mapSceneToView(ev.scenePos())
        if self.tool is None:
            if ev.button() == QtCore.Qt.LeftButton and ev.double():
                self.price_clicked.emit(float(mp.y()))
            return
        t = self.time_at(mp.x())
        if t is None:
            return
        self._tool_pts.append((t, float(mp.y())))
        if len(self._tool_pts) >= TOOL_CLICKS[self.tool]:
            coords = {}
            for k, (tt, pp) in enumerate(self._tool_pts, 1):
                coords[f"t{k}"] = tt.isoformat()
                coords[f"p{k}"] = pp
            if self.tool == "text":
                text, ok = QtWidgets.QInputDialog.getText(self, "Texto", "Texto:")
                if not ok or not text:
                    self.set_tool(None)
                    return
                coords["text"] = text
            kind = self.tool
            self.set_tool(None)
            self.drawing_created.emit(kind, coords)

    def draw_drawings(self, drawings: list[dict]) -> None:
        if self._drag is None:
            self._drawings = copy.deepcopy(drawings)
        self._render_drawings()

    def _render_drawings(self) -> None:
        drawings = self._drawings
        P = self.draw_layer.pic
        P.clear()
        n = len(self.times)
        vr = self.plot.vb.viewRange()
        for d in drawings:
            c, kind = d["coordinates"], d["kind"]
            color = d.get("style", {}).get("color", "#ffeb3b")
            x = lambda k: self._x_time(c[f"t{k}"])
            if kind == "hline":
                P.line(-1e6, c["p1"], 1e6, c["p1"], color, 1.3)
                P.text(n, c["p1"], f"{c['p1']:.2f}", color, 0.0, 1.0)
            elif kind == "vline":
                P.line(x(1), -1e9, x(1), 1e9, color, 1.3)
            elif kind == "trend":
                P.line(x(1), c["p1"], x(2), c["p2"], color, 1.3)
            elif kind == "rect":
                x1, x2 = sorted((x(1), x(2))); y1, y2 = sorted((c["p1"], c["p2"]))
                P.rect(x1, y1, x2 - x1, y2 - y1, (255, 235, 59, 25), color)
            elif kind == "text":
                P.text(x(1), c["p1"], c.get("text", ""), color, 0.0, 1.0)
            elif kind == "fib":
                xe = max(x(2), n)
                for lvl in FIB_LEVELS:
                    y = c["p2"] + (c["p1"] - c["p2"]) * lvl
                    P.line(x(1), y, xe, y, color, 1.0, "dash")
                    P.text(x(1), y, f"{lvl * 100:.1f}%  {y:.2f}", color, 0.0, 1.0)
            elif kind == "channel":
                x1, x2, x3 = x(1), x(2), x(3)
                slope = (c["p2"] - c["p1"]) / (x2 - x1) if x2 != x1 else 0.0
                off = c["p3"] - (c["p1"] + slope * (x3 - x1))
                xe = max(x2, n + 5)
                P.line(x1, c["p1"], xe, c["p1"] + slope * (xe - x1), color, 1.3)
                P.line(x1, c["p1"] + off, xe, c["p1"] + off + slope * (xe - x1), color, 1.3)
        sel = next((d for d in drawings if d.get("id") == self.selected_id), None)
        if sel is not None:
            for k, (x, y) in self._anchors(sel).items():
                P.mark(x, y, "square", "#ffffff", 9)
        P.commit()

    # -- edición interactiva --------------------------------------------------
    def _anchors(self, d: dict) -> dict:
        """Anclas editables en coordenadas de vista {k: (x, y)}."""
        c, kind = d["coordinates"], d["kind"]
        n = sum(1 for key in c if key.startswith("p"))
        out = {}
        for k in range(1, n + 1):
            x = self._x_time(c[f"t{k}"]) if f"t{k}" in c else len(self.times)
            out[k] = (x, c[f"p{k}"])
        if kind == "vline":
            vr = self.plot.vb.viewRange()
            out = {1: (out[1][0], (vr[1][0] + vr[1][1]) / 2)}
        if kind == "hline":
            vr = self.plot.vb.viewRange()
            out = {1: ((vr[0][0] + vr[0][1]) / 2, c["p1"])}
        return out

    def _to_px(self, x: float, y: float) -> QtCore.QPointF:
        return self.plot.vb.mapViewToScene(QtCore.QPointF(x, y))

    @staticmethod
    def _seg_dist(p, a, b) -> float:
        ax, ay, bx, by, px, py = a.x(), a.y(), b.x(), b.y(), p.x(), p.y()
        dx, dy = bx - ax, by - ay
        L = dx * dx + dy * dy
        t = 0.0 if L == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L))
        return math.hypot(px - (ax + t * dx), py - (ay + t * dy))

    def hit_test(self, scene_pos) -> Optional[tuple[int, str, int]]:
        """(id, 'anchor'|'body', k) del dibujo bajo el cursor, o None."""
        best = None
        for d in reversed(self._drawings):
            if d.get("id") is None:
                continue
            c, kind = d["coordinates"], d["kind"]
            for k, (x, y) in self._anchors(d).items():
                q = self._to_px(x, y)
                dist = math.hypot(q.x() - scene_pos.x(), q.y() - scene_pos.y())
                if dist <= HIT_PX and (best is None or dist < best[0]):
                    best = (dist, (d["id"], "anchor", k))
            if best is not None:
                continue
            body = False
            if kind == "hline":
                body = abs(self._to_px(0, c["p1"]).y() - scene_pos.y()) <= HIT_PX
            elif kind == "vline":
                body = abs(self._to_px(self._x_time(c["t1"]), 0).x() - scene_pos.x()) <= HIT_PX
            elif kind == "trend":
                a = self._to_px(self._x_time(c["t1"]), c["p1"]); b = self._to_px(self._x_time(c["t2"]), c["p2"])
                body = self._seg_dist(scene_pos, a, b) <= HIT_PX
            elif kind in ("rect", "fib"):
                a = self._to_px(self._x_time(c["t1"]), c["p1"])
                b = self._to_px(max(self._x_time(c["t2"]), len(self.times)) if kind == "fib"
                                else self._x_time(c["t2"]), c["p2"])
                r = QtCore.QRectF(a, b).normalized().adjusted(-HIT_PX, -HIT_PX, HIT_PX, HIT_PX)
                body = r.contains(scene_pos)
            elif kind == "channel":
                x1, x2, x3 = (self._x_time(c[f"t{k}"]) for k in (1, 2, 3))
                slope = (c["p2"] - c["p1"]) / (x2 - x1) if x2 != x1 else 0.0
                off = c["p3"] - (c["p1"] + slope * (x3 - x1))
                xe = max(x2, len(self.times) + 5)
                for o in (0.0, off):
                    a = self._to_px(x1, c["p1"] + o); b = self._to_px(xe, c["p1"] + o + slope * (xe - x1))
                    body = body or self._seg_dist(scene_pos, a, b) <= HIT_PX
            elif kind == "text":
                q = self._to_px(self._x_time(c["t1"]), c["p1"])
                body = QtCore.QRectF(q.x(), q.y() - 14, 120, 18).contains(scene_pos)
            if body:
                return (d["id"], "body", 0)
        return best[1] if best else None

    def select(self, drawing_id: Optional[int]) -> None:
        self.selected_id = drawing_id
        self._render_drawings()

    def _find(self, drawing_id: int) -> Optional[dict]:
        return next((d for d in self._drawings if d.get("id") == drawing_id), None)

    def begin_drag(self, hit, view_pt) -> None:
        d = self._find(hit[0])
        if d is None:
            return
        self.selected_id = hit[0]
        self._drag = {"id": hit[0], "mode": hit[1], "k": hit[2], "start": (view_pt.x(), view_pt.y()),
                      "orig": copy.deepcopy(d["coordinates"])}

    def update_drag(self, view_pt) -> None:
        g = self._drag
        if g is None:
            return
        d = self._find(g["id"])
        c, orig = d["coordinates"], g["orig"]
        if g["mode"] == "anchor":
            k = g["k"]
            if d["kind"] != "vline":
                c[f"p{k}"] = float(view_pt.y())
            if d["kind"] != "hline" and f"t{k}" in c:
                t = self.time_at(view_pt.x())
                if t is not None:
                    c[f"t{k}"] = t.isoformat()
        else:
            dx = int(round(view_pt.x() - g["start"][0]))
            dy = float(view_pt.y() - g["start"][1])
            for key, val in orig.items():
                if key.startswith("p") and d["kind"] != "vline":
                    c[key] = val + dy
                elif key.startswith("t") and d["kind"] != "hline":
                    t = self.time_at(self._x_time(val) + dx)
                    if t is not None:
                        c[key] = t.isoformat()
        self._render_drawings()

    def finish_drag(self) -> None:
        g, self._drag = self._drag, None
        if g is None:
            return
        d = self._find(g["id"])
        if d is not None and d["coordinates"] != g["orig"]:
            self.drawing_modified.emit(g["id"], d["coordinates"], d.get("style", {}))

    def delete_selected(self) -> None:
        if self.selected_id is not None:
            did, self.selected_id = self.selected_id, None
            self.drawing_deleted.emit(did)

    def drawing_menu(self, drawing_id: int, screen_pos) -> None:
        d = self._find(drawing_id)
        if d is None:
            return
        m = QtWidgets.QMenu(self)
        a_del = m.addAction("Eliminar")
        a_col = m.addAction("Color…")
        a_txt = m.addAction("Editar texto") if d["kind"] == "text" else None
        act = m.exec(screen_pos.toPoint() if hasattr(screen_pos, "toPoint") else screen_pos)
        if act is a_del:
            self.selected_id = drawing_id
            self.delete_selected()
        elif act is a_col:
            col = QtWidgets.QColorDialog.getColor(QtGui.QColor(d.get("style", {}).get("color", "#ffeb3b")), self)
            if col.isValid():
                d.setdefault("style", {})["color"] = col.name()
                self.drawing_modified.emit(drawing_id, d["coordinates"], d["style"])
        elif a_txt is not None and act is a_txt:
            text, ok = QtWidgets.QInputDialog.getText(self, "Texto", "Texto:", text=d["coordinates"].get("text", ""))
            if ok:
                d["coordinates"]["text"] = text
                self.drawing_modified.emit(drawing_id, d["coordinates"], d.get("style", {}))

    def _x_time(self, iso: str) -> float:
        t = pd.Timestamp(iso)
        if len(self._times_ns) and t.value > self._times_ns[-1]:
            step = self._times_ns[-1] - self._times_ns[-2] if len(self._times_ns) > 1 else 60e9
            return float(len(self._times_ns) - 1 + (t.value - self._times_ns[-1]) / step)
        return self.x_of(t)
