"""
strategies/base.py — Contrato de estrategia para el BacktestEngine.

La estrategia solo ve el BacktestContext: velas CERRADAS hasta la actual,
motores SMC alimentados con esas mismas velas y sus posiciones. Las órdenes
que emite se ejecutan en la APERTURA de la vela siguiente (nunca al cierre
de la vela que generó la señal, que ya pasó).
"""
from __future__ import annotations

from typing import Protocol


class Strategy(Protocol):
    name: str
    version: str
    params: dict

    def on_bar(self, ctx) -> None: ...
