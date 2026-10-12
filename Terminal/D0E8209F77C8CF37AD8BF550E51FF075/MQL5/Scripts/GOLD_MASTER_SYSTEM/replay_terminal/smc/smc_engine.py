"""
smc/smc_engine.py — Motor SMC incremental y causal.

Se alimenta con velas CERRADAS en orden cronológico (on_bar). Cada vela solo
puede afectar a objetos detectados en o después de su cierre. Por eso:
  * Calcular sobre todo el histórico y consultar  snapshot(t)  es idéntico a
    calcular solo con las velas cerradas hasta t. tests/test_no_lookahead.py
    lo demuestra comparando ambos caminos vela a vela.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

from core.models import TIMEFRAME_SECONDS, tf_close
from smc.fvg import FVGTracker
from smc.liquidity import LiquidityTracker
from smc.models import FVG, LiquidityLevel, OrderBlock, StructureEvent, Swing
from smc.order_blocks import OrderBlockTracker
from smc.structure import StructureTracker, UNKNOWN
from smc.swings import SwingDetector

SMC_ENGINE_VERSION = "1.1"   # 1.1: estado RANGING
SMC_CONFIG_FILE = Path(__file__).parent.parent / "config" / "smc.json"


@dataclass
class SMCConfig:
    swing_left_bars: int = 5
    swing_right_bars: int = 5
    break_confirmation: str = "CLOSE"
    ranging_enabled: bool = True
    fvg_min_size_points: float = 0.0
    liquidity_tolerance_abs: float = 0.0
    liquidity_tolerance_pct: float = 0.03
    liquidity_min_contacts: int = 2
    ob_min_displacement: float = 1.0
    ob_lookback: int = 20
    ob_volume_filter: bool = False
    enabled: dict = field(default_factory=lambda: {
        k: True for k in ("swings", "bos", "choch", "eqh", "eql", "bsl", "ssl", "fvg", "order_blocks")})

    @classmethod
    def load(cls, path: Path = SMC_CONFIG_FILE) -> "SMCConfig":
        if not path.exists():
            return cls()
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        keys = cls.__dataclass_fields__.keys()
        return cls(**{k: v for k, v in d.items() if k in keys})

    def to_dict(self) -> dict:
        return {k: getattr(self, k) for k in self.__dataclass_fields__}


@dataclass
class SMCSnapshot:
    time: datetime
    state: str
    swings: list[Swing]
    events: list[StructureEvent]
    fvgs: list[tuple[FVG, str]]
    liquidity: list[tuple[LiquidityLevel, str]]
    order_blocks: list[tuple[OrderBlock, str]]
    active_range: Optional[dict] = None


class SMCEngine:
    def __init__(self, timeframe: str, config: Optional[SMCConfig] = None, point: float = 0.01) -> None:
        self.timeframe = timeframe
        self.cfg = config or SMCConfig()
        self.swings = SwingDetector(self.cfg.swing_left_bars, self.cfg.swing_right_bars)
        self.structure = StructureTracker(self.cfg.break_confirmation, self.cfg.ranging_enabled)
        self.fvg = FVGTracker(self.cfg.fvg_min_size_points * point)
        self.liq = LiquidityTracker(self.cfg.liquidity_tolerance_abs,
                                    self.cfg.liquidity_tolerance_pct, self.cfg.liquidity_min_contacts)
        self.obs = OrderBlockTracker(self.cfg.ob_min_displacement, self.cfg.ob_lookback,
                                     self.cfg.ob_volume_filter)
        self.n = 0
        self.last_close_time: Optional[datetime] = None

    def on_bar(self, bar) -> list[StructureEvent]:
        """Procesa UNA vela cerrada. Devuelve los eventos de estructura nuevos."""
        if self.last_close_time is not None and bar.time < self.last_close_time:
            raise ValueError("Velas fuera de orden cronológico")
        idx = self.n
        ct = tf_close(bar.time, self.timeframe)
        # La estructura se evalúa con los swings conocidos ANTES de esta vela;
        # los swings que esta vela confirma solo sirven a partir de la siguiente.
        events = self.structure.update(bar, idx, ct)
        new_swings = self.swings.update(bar, ct)
        for s in new_swings:
            self.structure.add_swing(s)
        self.fvg.update(bar, idx, ct)
        self.liq.update(bar, ct, new_swings)
        self.obs.update(bar, idx, ct, events)
        self.n += 1
        self.last_close_time = ct
        return events

    # -- consultas "tal como era" en el instante t -------------------------
    @property
    def state(self) -> str:
        return self.structure.state

    def state_at(self, t: datetime) -> str:
        return self.structure.state_history.at(t) or UNKNOWN

    def snapshot(self, t: datetime) -> SMCSnapshot:
        e = self.cfg.enabled
        sw = [s for s in self.swings.swing_highs + self.swings.swing_lows if s.detected_at <= t] \
            if e.get("swings", True) else []
        evs = [ev for ev in self.structure.events if ev.timestamp <= t and
               ((ev.type == "BOS" and e.get("bos", True)) or (ev.type == "CHoCH" and e.get("choch", True)))]
        fv = [(g, g.status.at(t)) for g in self.fvg.fvgs if g.detected_at <= t] if e.get("fvg", True) else []
        lq = []
        for lv in self.liq.levels:
            if lv.detected_at > t:
                continue
            if (lv.kind == "BSL" and not e.get("bsl", True)) or (lv.kind == "SSL" and not e.get("ssl", True)):
                continue
            lq.append((lv, lv.status.at(t)))
        ob = [(o, o.status.at(t)) for o in self.obs.blocks if o.detected_at <= t] \
            if e.get("order_blocks", True) else []
        return SMCSnapshot(t, self.state_at(t), sorted(sw, key=lambda s: s.index), evs, fv, lq, ob,
                           self.structure.range_at(t))

    def signature(self, t: datetime) -> list:
        """Representación comparable del snapshot (usada por los tests de look-ahead)."""
        s = self.snapshot(t)
        def le(lv, st):
            eq = lv.equal_detected_at if lv.equal_detected_at and lv.equal_detected_at <= t else None
            n_sw = len([x for x in lv.swings if x.detected_at <= t])
            return ("LIQ", lv.kind, lv.price, lv.detected_at, eq, n_sw, st)
        return (
            [s.state]
            + [("SW", x.kind, x.price, x.index, x.detected_at) for x in s.swings]
            + [("EV", x.type, x.direction, x.price, x.index, x.timestamp, x.reason) for x in s.events]
            + [("FVG", g.direction, g.top, g.bottom, g.detected_at, st) for g, st in s.fvgs]
            + [le(lv, st) for lv, st in s.liquidity]
            + [("OB", o.direction, o.top, o.bottom, o.detected_at, st) for o, st in s.order_blocks]
            + ([("RANGE", s.active_range["start"], s.active_range["high"], s.active_range["low"])]
               if s.active_range else [])
        )
