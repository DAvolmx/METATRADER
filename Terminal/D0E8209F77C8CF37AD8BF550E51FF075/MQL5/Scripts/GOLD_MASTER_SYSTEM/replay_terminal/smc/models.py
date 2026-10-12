"""
smc/models.py — Objetos SMC estructurados.

Todo objeto guarda:
  formation_time : cuándo se formó el patrón (apertura de la vela clave)
  detected_at    : instante en que el patrón PUDO conocerse (cierre de la
                   vela que lo confirma). La UI/replay solo lo muestra si
                   detected_at <= reloj.
Los objetos con estado guardan historial (time, status) para consultar el
estado "tal como era" en cualquier instante sin mirar el futuro.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional


@dataclass
class StatusHistory:
    history: list[tuple[datetime, str]] = field(default_factory=list)

    def set(self, t: datetime, status: str) -> None:
        if not self.history or self.history[-1][1] != status:
            self.history.append((t, status))

    def at(self, t: datetime) -> Optional[str]:
        st = None
        for when, s in self.history:
            if when <= t:
                st = s
            else:
                break
        return st

    @property
    def current(self) -> Optional[str]:
        return self.history[-1][1] if self.history else None


@dataclass
class Swing:
    kind: str                 # HIGH | LOW
    price: float
    index: int                # índice de la vela del swing
    formation_time: datetime
    detected_at: datetime
    confirm_index: int


@dataclass
class StructureEvent:
    type: str                 # BOS | CHoCH
    direction: str            # bullish | bearish
    price: float              # nivel roto
    timestamp: datetime       # = detected_at (cierre de la vela que rompe)
    index: int
    source_swing: Swing
    previous_state: str
    new_state: str
    reason: str

    @property
    def detected_at(self) -> datetime:
        return self.timestamp


@dataclass
class FVG:
    direction: str            # bullish | bearish
    top: float
    bottom: float
    formation_time: datetime  # apertura de la vela central
    detected_at: datetime     # cierre de la 3ª vela
    index: int                # índice de la 3ª vela
    status: StatusHistory = field(default_factory=StatusHistory)


@dataclass
class LiquidityLevel:
    kind: str                 # BSL (sobre máximos) | SSL (bajo mínimos)
    price: float
    swings: list[Swing]
    formation_time: datetime
    detected_at: datetime     # cuando se confirmó el primer swing
    equal_detected_at: Optional[datetime] = None   # cuando alcanzó min_contacts (EQH/EQL)
    status: StatusHistory = field(default_factory=StatusHistory)

    @property
    def is_equal(self) -> bool:
        return self.equal_detected_at is not None

    @property
    def equal_label(self) -> str:
        return "EQH" if self.kind == "BSL" else "EQL"


@dataclass
class OrderBlock:
    direction: str            # bullish | bearish
    top: float
    bottom: float
    formation_time: datetime
    detected_at: datetime
    index: int
    displacement: float       # múltiplos del rango de la vela OB
    trigger: StructureEvent
    status: StatusHistory = field(default_factory=StatusHistory)
