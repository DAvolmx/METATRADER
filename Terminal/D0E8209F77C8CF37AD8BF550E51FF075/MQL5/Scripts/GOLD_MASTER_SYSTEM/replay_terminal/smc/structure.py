"""
smc/structure.py — Máquina de estados de estructura (BOS / CHoCH).

Estados: UNKNOWN, BULLISH, BEARISH, RANGING.

RANGING (definición objetiva, v1.1):
  Un CHoCH que NO es confirmado por un BOS en su dirección y es seguido por un
  CHoCH en la dirección contraria es un "CHoCH fallido": el mercado rompió la
  estructura en ambos sentidos sin continuación => RANGO.
    techo = máximo entre el nivel del CHoCH alcista y el último swing high
    suelo = mínimo entre el nivel del CHoCH bajista y el último swing low
  Dentro del rango no se emiten eventos. Salida: un cierre (o mecha, según
  break_confirmation) fuera del rango => BOS en esa dirección ("ruptura del
  rango") y la estructura vuelve a ser BULLISH/BEARISH.
  Se puede desactivar con ranging_enabled = false (comportamiento v1.0).

Definiciones (break_confirmation = CLOSE por defecto, WICK opcional):
  * Swing protegido: al producirse un BOS alcista, el último swing low
    confirmado pasa a ser el "protected low" (simétrico en bajista).
  * BOS alcista : en UNKNOWN o BULLISH, ruptura del último swing high
                  confirmado y no roto.
  * CHoCH alcista: en BEARISH, ruptura del protected high. Cambia el estado.
  * En BEARISH, romper un swing high que NO es el protegido es una ruptura
    interna: se marca el swing como roto pero no genera BOS ni CHoCH.
Cada evento guarda el estado previo, el nuevo y una razón legible.
"""
from __future__ import annotations

from datetime import datetime
from typing import Optional

from smc.models import StatusHistory, StructureEvent, Swing

UNKNOWN, BULLISH, BEARISH, RANGING = "UNKNOWN", "BULLISH", "BEARISH", "RANGING"


class StructureTracker:
    def __init__(self, break_confirmation: str = "CLOSE", ranging_enabled: bool = True) -> None:
        if break_confirmation not in ("CLOSE", "WICK"):
            raise ValueError("break_confirmation debe ser CLOSE o WICK")
        self.mode = break_confirmation
        self.state = UNKNOWN
        self.state_history = StatusHistory()
        self.last_high: Optional[Swing] = None
        self.last_low: Optional[Swing] = None
        self.protected_high: Optional[Swing] = None
        self.protected_low: Optional[Swing] = None
        self._broken: set[int] = set()   # id() de swings rotos
        self.events: list[StructureEvent] = []
        self.ranging_enabled = ranging_enabled
        self._pending_choch: Optional[StructureEvent] = None   # CHoCH aún sin BOS que lo confirme
        self.range_high: Optional[Swing] = None
        self.range_low: Optional[Swing] = None
        self.ranges: list[dict] = []    # {start, end, high, low} para consultar "tal como era"

    def add_swing(self, s: Swing) -> None:
        if s.kind == "HIGH":
            self.last_high = s
        else:
            self.last_low = s

    def _is_broken(self, s: Optional[Swing]) -> bool:
        return s is None or id(s) in self._broken

    def update(self, bar, index: int, close_time: datetime) -> list[StructureEvent]:
        up_px = bar.close if self.mode == "CLOSE" else bar.high
        dn_px = bar.close if self.mode == "CLOSE" else bar.low
        out = []

        # ---- en rango: solo cuenta la ruptura de sus límites
        if self.state == RANGING:
            if up_px > self.range_high.price:
                out.append(self._event("BOS", "bullish", self.range_high, index, close_time, BULLISH,
                                       f"ruptura alcista del rango [{self.range_low.price}, {self.range_high.price}]"))
            elif dn_px < self.range_low.price:
                out.append(self._event("BOS", "bearish", self.range_low, index, close_time, BEARISH,
                                       f"ruptura bajista del rango [{self.range_low.price}, {self.range_high.price}]"))
            return out

        # ---- rupturas alcistas
        if self.state == BEARISH:
            ph = self.protected_high if not self._is_broken(self.protected_high) else self.last_high
            if not self._is_broken(ph) and up_px > ph.price:
                out.append(self._event("CHoCH", "bullish", ph, index, close_time, BULLISH,
                                       f"cierre {bar.close} rompe el protected high {ph.price} "
                                       f"en estructura bajista"))
            elif not self._is_broken(self.last_high) and up_px > self.last_high.price:
                self._broken.add(id(self.last_high))   # ruptura interna
        elif not self._is_broken(self.last_high) and up_px > self.last_high.price:
            prev = self.state
            out.append(self._event("BOS", "bullish", self.last_high, index, close_time, BULLISH,
                                   "primera ruptura: define estructura alcista" if prev == UNKNOWN
                                   else f"continuación alcista: rompe swing high {self.last_high.price}"))

        # ---- rupturas bajistas
        if self.state == BULLISH and not any(e.direction == "bullish" for e in out):
            pl = self.protected_low if not self._is_broken(self.protected_low) else self.last_low
            if not self._is_broken(pl) and dn_px < pl.price:
                out.append(self._event("CHoCH", "bearish", pl, index, close_time, BEARISH,
                                       f"cierre {bar.close} rompe el protected low {pl.price} "
                                       f"en estructura alcista"))
            elif not self._is_broken(self.last_low) and dn_px < self.last_low.price:
                self._broken.add(id(self.last_low))
        elif self.state in (UNKNOWN, BEARISH) and not out:
            if not self._is_broken(self.last_low) and dn_px < self.last_low.price:
                prev = self.state
                out.append(self._event("BOS", "bearish", self.last_low, index, close_time, BEARISH,
                                       "primera ruptura: define estructura bajista" if prev == UNKNOWN
                                       else f"continuación bajista: rompe swing low {self.last_low.price}"))
        return out

    def _event(self, typ, direction, swing, index, t, new_state, reason) -> StructureEvent:
        prev = self.state
        self._broken.add(id(swing))
        pend = self._pending_choch
        failed = (typ == "CHoCH" and self.ranging_enabled and pend is not None
                  and pend.direction != direction)
        if failed:
            bull_sw = swing if direction == "bullish" else pend.source_swing
            bear_sw = swing if direction == "bearish" else pend.source_swing
            highs = [x for x in (bull_sw, self.last_high) if x is not None]
            lows = [x for x in (bear_sw, self.last_low) if x is not None]
            self.range_high = max(highs, key=lambda x: x.price)
            self.range_low = min(lows, key=lambda x: x.price)
            new_state = RANGING
            reason += (f" · CHoCH fallido (el {pend.type} {pend.direction} previo no fue confirmado por BOS)"
                       f" => RANGO [{self.range_low.price}, {self.range_high.price}]")
            self.protected_high = self.protected_low = None
        elif new_state == BULLISH:
            self.protected_low = self.last_low
            self.protected_high = None
        else:
            self.protected_high = self.last_high
            self.protected_low = None
        self.state = new_state
        self.state_history.set(t, new_state)
        ev = StructureEvent(typ, direction, swing.price, t, index, swing, prev, new_state, reason)
        self.events.append(ev)
        if failed:
            self.ranges.append({"start": t, "end": None, "high": self.range_high.price,
                                "low": self.range_low.price, "start_index": index})
        elif prev == RANGING and self.ranges and self.ranges[-1]["end"] is None:
            self.ranges[-1]["end"] = t
        if typ == "CHoCH" and not failed:
            self._pending_choch = ev
        else:
            self._pending_choch = None
        if new_state != RANGING:
            self.range_high = self.range_low = None
        return ev

    def range_at(self, t: datetime) -> Optional[dict]:
        for r in reversed(self.ranges):
            if r["start"] <= t and (r["end"] is None or r["end"] > t):
                return r
        return None
