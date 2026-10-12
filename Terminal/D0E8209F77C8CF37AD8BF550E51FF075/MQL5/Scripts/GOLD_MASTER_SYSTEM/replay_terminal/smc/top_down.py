"""
smc/top_down.py — Análisis Top-Down multitemporal (D1 → H4 → H1 → M15).

Se alimenta SOLO con velas base cerradas; las temporalidades superiores se
construyen con BarAggregator y cada motor SMC recibe sus velas solo cuando
cierran. Es DESCRIPTIVO: no genera señales de compra/venta por sí mismo.
"""
from __future__ import annotations

from datetime import datetime
from typing import Optional

from core.models import TIMEFRAME_SECONDS, is_derivable
from data.aggregator import BarAggregator
from smc.smc_engine import SMCConfig, SMCEngine


class TopDownAnalyzer:
    def __init__(self, base_timeframe: str, timeframes=("D1", "H4", "H1", "M15"),
                 config: Optional[SMCConfig] = None, point: float = 0.01) -> None:
        self.base = base_timeframe
        self.tfs = [tf for tf in timeframes if tf == base_timeframe or is_derivable(tf, base_timeframe)]
        self.engines = {tf: SMCEngine(tf, config, point) for tf in self.tfs}
        self.aggs = {tf: BarAggregator(tf, base_timeframe) for tf in self.tfs if tf != base_timeframe}

    def on_base_bar(self, bar) -> None:
        for tf in self.tfs:
            if tf == self.base:
                self.engines[tf].on_bar(bar)
            else:
                for closed in self.aggs[tf].update(bar):
                    self.engines[tf].on_bar(closed)

    def summary(self, t: datetime) -> dict[str, dict]:
        out = {}
        for tf in self.tfs:
            snap = self.engines[tf].snapshot(t)
            last_ev = snap.events[-1] if snap.events else None
            open_fvg = [g for g, st in snap.fvgs if st in ("OPEN", "PARTIALLY_FILLED")]
            out[tf] = {
                "state": snap.state,
                "last_event": f"{last_ev.type} {last_ev.direction} @ {last_ev.price}" if last_ev else None,
                "open_fvgs": len(open_fvg),
                "last_fvg": f"{open_fvg[-1].direction} [{open_fvg[-1].bottom}-{open_fvg[-1].top}]"
                if open_fvg else None,
            }
        return out

    def describe(self, t: datetime) -> list[str]:
        lines = []
        for tf, d in self.summary(t).items():
            extra = f" | {d['last_event']}" if d["last_event"] else ""
            fvg = f" | FVG {d['last_fvg']}" if d["last_fvg"] else ""
            lines.append(f"{tf}: {d['state']}{extra}{fvg}")
        return lines
