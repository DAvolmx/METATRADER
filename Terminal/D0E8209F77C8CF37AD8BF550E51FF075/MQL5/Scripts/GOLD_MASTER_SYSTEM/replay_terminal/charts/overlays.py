"""
charts/overlays.py — Objetos SMC y operaciones sobre un gráfico.
Recibe objetos YA filtrados por el reloj (snapshot / trades visibles) y los
pinta en una PictureOverlay (un único objeto gráfico, rápido).
"""
from __future__ import annotations

from charts.picture_overlay import PictureOverlay

COL = {
    "BOS_bull": "#26a69a", "BOS_bear": "#ef5350", "CHoCH_bull": "#00e5ff", "CHoCH_bear": "#ff9100",
    "FVG_bull": (38, 166, 154, 45), "FVG_bear": (239, 83, 80, 45),
    "OB_bull": (41, 98, 255, 55), "OB_bear": (255, 152, 0, 55),
    "BSL": "#b0bec5", "SSL": "#b0bec5", "EQ": "#ffd54f", "SWING": "#9e9e9e",
}


class OverlayLayer:
    def __init__(self, plot) -> None:
        self.plot = plot
        self.pic = PictureOverlay()
        plot.addItem(self.pic, ignoreBounds=True)

    def clear(self) -> None:
        self.pic.clear()
        self.pic.commit()

    def draw_smc(self, snap, x_of, n_bars: int, opts: dict) -> None:
        P = self.pic
        P.clear()
        right = n_bars + 1
        visible = lambda x: x > 0 or x == 0     # x_of ya acota a >= 0
        if opts.get("swings", True):
            for s in snap.swings[-150:]:
                x = x_of(s.formation_time)
                if x > 0:
                    P.mark(x, s.price, "down" if s.kind == "HIGH" else "up", COL["SWING"], 6)
        rg = getattr(snap, "active_range", None)
        if rg is not None:
            x0 = x_of(rg["start"])
            P.rect(x0, rg["low"], right - x0, rg["high"] - rg["low"], (158, 158, 158, 28), "#9e9e9e")
            P.text(x0, rg["high"], "RANGO", "#bdbdbd")
        for ev in snap.events[-30:]:
            key = f"{ev.type}_{'bull' if ev.direction == 'bullish' else 'bear'}"
            x0, x1 = x_of(ev.source_swing.formation_time), x_of(ev.timestamp) - 1
            if x1 <= 0:
                continue
            P.line(x0, ev.price, x1, ev.price, COL[key], 1.4, "solid" if ev.type == "BOS" else "dash")
            P.text((x0 + x1) / 2, ev.price, ev.type, COL[key], 0.5, 0.0 if ev.direction == "bullish" else 1.0)
        for g, st in snap.fvgs[-80:]:
            if st not in ("OPEN", "PARTIALLY_FILLED"):
                continue
            x0 = x_of(g.formation_time)
            P.rect(x0, g.bottom, right - x0, g.top - g.bottom,
                   COL["FVG_bull" if g.direction == "bullish" else "FVG_bear"])
        for o, st in snap.order_blocks[-30:]:
            if st != "ACTIVE":
                continue
            x0 = x_of(o.formation_time)
            c = COL["OB_bull" if o.direction == "bullish" else "OB_bear"]
            P.rect(x0, o.bottom, right - x0, o.top - o.bottom, c, c[:3])
            P.text(x0, o.top, "OB", "#90caf9" if o.direction == "bullish" else "#ffcc80")
        for lv, st in snap.liquidity[-100:]:
            if st == "SWEPT":
                continue
            is_eq = lv.equal_detected_at is not None and lv.equal_detected_at <= snap.time
            key = ("eqh" if lv.kind == "BSL" else "eql") if is_eq else lv.kind.lower()
            if not opts.get(key, True):
                continue
            x0 = x_of(lv.formation_time)
            color = COL["EQ"] if is_eq else COL[lv.kind]
            P.line(x0, lv.price, right, lv.price, color, 1.0, "dot")
            if is_eq:
                P.text(right - 2, lv.price, lv.equal_label, color, 1.0, 1.0)
        P.commit()

    def draw_trades(self, trades, x_of, clock) -> None:
        P = self.pic
        P.clear()
        for t in trades:
            if t.entry_time is None or t.entry_time > clock:
                continue
            x0 = x_of(t.entry_time)
            closed = t.exit_time is not None and t.exit_time <= clock
            x1 = x_of(t.exit_time) if closed else x0 + 15
            color = "#26a69a" if t.direction == "BUY" else "#ef5350"
            if t.stop_loss:
                P.line(x0, t.stop_loss, x1, t.stop_loss, "#ef5350", 1.0)
            if t.take_profit:
                P.line(x0, t.take_profit, x1, t.take_profit, "#26a69a", 1.0)
            P.mark(x0, t.entry_price, "up" if t.direction == "BUY" else "down", color, 12)
            if closed:
                profit = t.profit or 0
                out = "#26a69a" if profit > 0 else ("#ef5350" if profit < 0 else "#bdbdbd")
                P.line(x0, t.entry_price, x1, t.exit_price, out, 1.5, "dash")
                P.mark(x1, t.exit_price, "x", out, 10)
        P.commit()
