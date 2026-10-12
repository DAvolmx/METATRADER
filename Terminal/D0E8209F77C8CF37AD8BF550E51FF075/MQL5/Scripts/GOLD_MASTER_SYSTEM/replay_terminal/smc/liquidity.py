"""
smc/liquidity.py — Liquidez: BSL / SSL, EQH / EQL y barridos (sweeps).

  BSL: cada swing high confirmado y no barrido (stops de compra encima).
  SSL: cada swing low confirmado y no barrido.
  EQH/EQL: un nivel acumula `min_contacts` swings dentro de la tolerancia.
  Tolerancia = max(tolerance_abs, precio * tolerance_pct/100). Configurable:
  no existe un valor universal válido para todos los símbolos.
  Sweep: una vela posterior supera el nivel (high > BSL / low < SSL).
"""
from __future__ import annotations

from datetime import datetime

from smc.models import LiquidityLevel, Swing


class LiquidityTracker:
    def __init__(self, tolerance_abs: float = 0.0, tolerance_pct: float = 0.03,
                 min_contacts: int = 2) -> None:
        if min_contacts < 2:
            raise ValueError("min_contacts debe ser >= 2")
        self.tol_abs, self.tol_pct, self.min_contacts = tolerance_abs, tolerance_pct, min_contacts
        self.levels: list[LiquidityLevel] = []
        self._active: list[LiquidityLevel] = []

    def _tol(self, price: float) -> float:
        return max(self.tol_abs, price * self.tol_pct / 100.0)

    def update(self, bar, close_time: datetime, new_swings: list[Swing]) -> list[LiquidityLevel]:
        # 1) barridos con la vela actual (solo niveles ya conocidos)
        swept = []
        still = []
        for lv in self._active:
            if (lv.kind == "BSL" and bar.high > lv.price) or (lv.kind == "SSL" and bar.low < lv.price):
                lv.status.set(close_time, "SWEPT")
                swept.append(lv)
            else:
                still.append(lv)
        self._active = still

        # 2) nuevos swings confirmados al cierre de esta vela
        for s in new_swings:
            kind = "BSL" if s.kind == "HIGH" else "SSL"
            match = None
            for lv in self._active:
                if lv.kind == kind and abs(lv.price - s.price) <= self._tol(lv.price):
                    match = lv
                    break
            if match:
                match.swings.append(s)
                if len(match.swings) >= self.min_contacts and match.equal_detected_at is None:
                    match.equal_detected_at = close_time
                    match.status.set(close_time, "EQUAL")
            else:
                lv = LiquidityLevel(kind, s.price, [s], s.formation_time, close_time)
                lv.status.set(close_time, "ACTIVE")
                self.levels.append(lv)
                self._active.append(lv)
        return swept
