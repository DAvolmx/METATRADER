"""
smc/fvg.py — Fair Value Gap de tres velas.

  Bullish: low[c3]  > high[c1]   zona [high[c1], low[c3]]
  Bearish: high[c3] < low[c1]    zona [high[c3], low[c1]]
Se detecta al CIERRE de c3. min_size_points filtra gaps insignificantes.

Estados (evaluados en velas posteriores a la detección):
  OPEN -> PARTIALLY_FILLED (el precio entra en la zona)
       -> FILLED           (la mecha atraviesa toda la zona)
       -> INVALIDATED      (una vela CIERRA más allá del extremo lejano)
"""
from __future__ import annotations

from datetime import datetime

from smc.models import FVG


class FVGTracker:
    def __init__(self, min_size: float = 0.0) -> None:
        self.min_size = min_size
        self._bars: list = []
        self.fvgs: list[FVG] = []
        self._active: list[FVG] = []

    def update(self, bar, index: int, close_time: datetime) -> list[FVG]:
        # 1) actualizar estado de FVG previos con esta vela
        still = []
        for g in self._active:
            st = g.status.current
            if g.direction == "bullish":
                if bar.close < g.bottom:
                    g.status.set(close_time, "INVALIDATED")
                elif bar.low <= g.bottom:
                    g.status.set(close_time, "FILLED")
                elif bar.low < g.top and st == "OPEN":
                    g.status.set(close_time, "PARTIALLY_FILLED")
            else:
                if bar.close > g.top:
                    g.status.set(close_time, "INVALIDATED")
                elif bar.high >= g.top:
                    g.status.set(close_time, "FILLED")
                elif bar.high > g.bottom and st == "OPEN":
                    g.status.set(close_time, "PARTIALLY_FILLED")
            if g.status.current in ("OPEN", "PARTIALLY_FILLED"):
                still.append(g)
        self._active = still

        # 2) detectar nuevo FVG
        self._bars.append(bar)
        if len(self._bars) > 3:
            self._bars.pop(0)
        new = []
        if len(self._bars) == 3:
            c1, c2, c3 = self._bars
            g = None
            if c3.low > c1.high and c3.low - c1.high > self.min_size:
                g = FVG("bullish", c3.low, c1.high, c2.time, close_time, index)
            elif c3.high < c1.low and c1.low - c3.high > self.min_size:
                g = FVG("bearish", c1.low, c3.high, c2.time, close_time, index)
            if g:
                g.status.set(close_time, "OPEN")
                self.fvgs.append(g)
                self._active.append(g)
                new.append(g)
        return new
