"""
smc/swings.py — Swing High / Swing Low con confirmación sin look-ahead.

Un swing en la vela c necesita `right_bars` velas posteriores. Por eso se
CONFIRMA al cierre de la vela c + right_bars (detected_at), nunca antes.
Definición:
  Swing High: high[c] >  max(high[c-left : c])  y  high[c] >= max(high[c+1 : c+right])
  Swing Low : low[c]  <  min(low[c-left : c])   y  low[c]  <= min(low[c+1 : c+right])
(Con máximos iguales, el primero es el swing; el segundo queda como contacto
de liquidez EQH en liquidity.py.)
"""
from __future__ import annotations

from datetime import datetime

from smc.models import Swing


class SwingDetector:
    def __init__(self, left: int = 5, right: int = 5) -> None:
        if left < 1 or right < 1:
            raise ValueError("left/right deben ser >= 1")
        self.left, self.right = left, right
        self.highs: list[float] = []
        self.lows: list[float] = []
        self.times: list[datetime] = []
        self.swing_highs: list[Swing] = []
        self.swing_lows: list[Swing] = []

    def update(self, bar, close_time: datetime) -> list[Swing]:
        self.highs.append(bar.high)
        self.lows.append(bar.low)
        self.times.append(bar.time)
        n = len(self.highs) - 1
        c = n - self.right
        new: list[Swing] = []
        if c - self.left < 0:
            return new
        h, l = self.highs, self.lows
        if h[c] > max(h[c - self.left:c]) and h[c] >= max(h[c + 1:n + 1]):
            s = Swing("HIGH", h[c], c, self.times[c], close_time, n)
            self.swing_highs.append(s)
            new.append(s)
        if l[c] < min(l[c - self.left:c]) and l[c] <= min(l[c + 1:n + 1]):
            s = Swing("LOW", l[c], c, self.times[c], close_time, n)
            self.swing_lows.append(s)
            new.append(s)
        return new
