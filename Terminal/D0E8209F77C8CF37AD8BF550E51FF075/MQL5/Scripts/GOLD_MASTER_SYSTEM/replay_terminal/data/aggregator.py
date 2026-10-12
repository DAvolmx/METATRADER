"""
data/aggregator.py — Construye temporalidades superiores vela a vela.

Solo emite velas CERRADAS: una vela superior se cierra cuando cerró la vela
base que termina justo en el fin de su intervalo, o cuando llega una vela de
otro intervalo (hueco de sesión). `forming` es la vela en formación, solo
para dibujar; los indicadores deben usar `closed`.
"""
from __future__ import annotations

from datetime import datetime
from typing import Optional

from core.models import Bar, TIMEFRAME_SECONDS, is_derivable, tf_bucket_start, tf_close


class BarAggregator:
    def __init__(self, timeframe: str, base_timeframe: str) -> None:
        self.timeframe = timeframe
        self.tf = TIMEFRAME_SECONDS[timeframe]
        self.base = TIMEFRAME_SECONDS[base_timeframe]
        if not is_derivable(timeframe, base_timeframe):
            raise ValueError(f"{timeframe} no se puede derivar de {base_timeframe}")
        self.closed: list[Bar] = []
        self._f: Optional[dict] = None

    @property
    def forming(self) -> Optional[Bar]:
        return self._to_bar(self._f) if self._f else None

    def _bucket(self, t: datetime) -> datetime:
        return tf_bucket_start(t, self.timeframe)

    @staticmethod
    def _to_bar(f: dict) -> Bar:
        if f["high_k"] < f["low_k"]:
            fe = "HIGH"
        elif f["low_k"] < f["high_k"]:
            fe = "LOW"
        else:
            fe = f["same_first"]
        return Bar(time=f["time"], open=f["open"], high=f["high"], low=f["low"],
                   close=f["close"], tick_volume=f["tick_volume"], spread=f["spread"],
                   first_extreme=fe, synthetic=f["synthetic"])

    def _close(self) -> Bar:
        bar = self._to_bar(self._f)
        self.closed.append(bar)
        self._f = None
        return bar

    def update(self, bar) -> list[Bar]:
        """Añade una vela base. Devuelve las velas superiores que se cerraron."""
        out: list[Bar] = []
        b = self._bucket(bar.time)
        if self._f is not None and self._f["bucket"] != b:
            out.append(self._close())
        syn = bool(getattr(bar, "synthetic", False))
        if self._f is None:
            self._f = dict(bucket=b, time=b,
                           open=bar.open, high=bar.high, low=bar.low, close=bar.close,
                           tick_volume=bar.tick_volume, spread=bar.spread, k=0,
                           high_k=0, low_k=0, same_first=getattr(bar, "first_extreme", None),
                           synthetic=syn)
        else:
            f = self._f
            f["k"] += 1
            if bar.high > f["high"]:
                f["high"], f["high_k"] = bar.high, f["k"]
            if bar.low < f["low"]:
                f["low"], f["low_k"] = bar.low, f["k"]
            if f["high_k"] == f["low_k"]:
                f["same_first"] = getattr(bar, "first_extreme", None)
            f["close"] = bar.close
            f["tick_volume"] += bar.tick_volume
            f["spread"] = bar.spread
            f["synthetic"] = f["synthetic"] or syn
        if int(bar.time.timestamp()) + self.base >= int(tf_close(b, self.timeframe).timestamp()):
            out.append(self._close())
        return out
