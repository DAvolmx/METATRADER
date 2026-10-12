"""
smc/order_blocks.py — Order Blocks.

Definición configurable (no "cualquier vela contraria"):
  1. Debe existir una ruptura estructural (BOS o CHoCH) en la vela n.
  2. OB alcista = última vela BAJISTA (close < open) antes del impulso, buscada
     hacia atrás desde n hasta `lookback` velas.
  3. Desplazamiento = (cierre de la ruptura - techo del OB) / rango del OB
     debe ser >= min_displacement (múltiplos del rango de la vela OB).
  4. volume_filter (opcional): tick_volume del OB >= media de las 20 previas.
Estados: ACTIVE -> MITIGATED (el precio vuelve a la zona)
                -> INVALIDATED (una vela cierra al otro lado de la zona)
"""
from __future__ import annotations

from datetime import datetime

import numpy as np

from smc.models import OrderBlock, StructureEvent


class OrderBlockTracker:
    def __init__(self, min_displacement: float = 1.0, lookback: int = 20,
                 volume_filter: bool = False) -> None:
        self.min_disp, self.lookback, self.volume_filter = min_displacement, lookback, volume_filter
        self.bars: list = []
        self.blocks: list[OrderBlock] = []
        self._active: list[OrderBlock] = []

    def update(self, bar, index: int, close_time: datetime,
               events: list[StructureEvent]) -> list[OrderBlock]:
        # 1) estado de OB existentes
        still = []
        for ob in self._active:
            if ob.direction == "bullish":
                if bar.close < ob.bottom:
                    ob.status.set(close_time, "INVALIDATED")
                elif bar.low <= ob.top:
                    ob.status.set(close_time, "MITIGATED")
            else:
                if bar.close > ob.top:
                    ob.status.set(close_time, "INVALIDATED")
                elif bar.high >= ob.bottom:
                    ob.status.set(close_time, "MITIGATED")
            if ob.status.current == "ACTIVE":
                still.append(ob)
        self._active = still

        self.bars.append(bar)
        new = []
        for ev in events:
            bullish = ev.direction == "bullish"
            start = max(0, index - self.lookback)
            k = None
            for j in range(index - 1, start - 1, -1):
                b = self.bars[j]
                if (bullish and b.close < b.open) or (not bullish and b.close > b.open):
                    k = j
                    break
            if k is None:
                continue
            ob_bar = self.bars[k]
            rng = ob_bar.high - ob_bar.low
            if rng <= 0:
                continue
            disp = (bar.close - ob_bar.high) / rng if bullish else (ob_bar.low - bar.close) / rng
            if disp < self.min_disp:
                continue
            if self.volume_filter:
                prev = [b.tick_volume for b in self.bars[max(0, k - 20):k]]
                if not prev or ob_bar.tick_volume < np.mean(prev):
                    continue
            ob = OrderBlock("bullish" if bullish else "bearish", ob_bar.high, ob_bar.low,
                            ob_bar.time, close_time, k, round(disp, 3), ev)
            ob.status.set(close_time, "ACTIVE")
            self.blocks.append(ob)
            self._active.append(ob)
            new.append(ob)
        return new
