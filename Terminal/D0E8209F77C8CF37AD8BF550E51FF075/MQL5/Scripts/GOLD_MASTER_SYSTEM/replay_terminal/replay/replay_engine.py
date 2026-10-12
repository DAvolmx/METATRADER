"""
replay/replay_engine.py — Bar Replay multitemporal sin look-ahead.

Un único ReplayClock. El reloj vale siempre el CIERRE de la última vela base
visible (current_replay_time). Para cada temporalidad:
  visible(tf)  -> velas CERRADAS:  time + tf <= reloj
  forming(tf)  -> vela en formación construida SOLO con velas base ya
                  cerradas (para dibujar; los indicadores no la usan).
Extensión sintética: si se activa un SyntheticMarket, al llegar al final de
los datos reales el replay continúa generando velas sintéticas (marcadas
synthetic=True) — el "modo fin de semana".
"""
from __future__ import annotations

from datetime import datetime, timedelta
from enum import Enum
from typing import Optional

import pandas as pd

from core.models import Bar, TIMEFRAME_SECONDS, bars_from_df, epoch_ns, is_derivable, tf_bucket_start, tf_close, tf_delta
from data.data_manager import resample_ohlc

SPEEDS = (0.25, 0.5, 1.0, 2.0, 5.0, 10.0)      # atajos
MIN_SPEED, MAX_SPEED = 0.1, 200.0                # rango continuo del slider
MIN_INTERVAL_MS = 40                             # por debajo, se avanzan varias velas por refresco


class ReplayState(str, Enum):
    STOPPED = "STOPPED"
    PAUSED = "PAUSED"
    PLAYING = "PLAYING"
    FINISHED = "FINISHED"


class ReplayEngine:
    def __init__(self, base_df: pd.DataFrame, base_tf: str, chart_tfs=("H4", "H1", "M15", "M5"),
                 start_time: Optional[datetime] = None, end_time: Optional[datetime] = None,
                 synthetic_market=None) -> None:
        if len(base_df) == 0:
            raise ValueError("Sin datos para el replay")
        self.base_tf = base_tf
        self.base_delta = tf_delta(base_tf)
        self.chart_tfs = [tf for tf in chart_tfs if is_derivable(tf, base_tf)]
        from data.data_manager import validate_bars
        df, _ = validate_bars(base_df, base_tf)
        if end_time is not None:
            df = df[df["time"] + self.base_delta <= end_time]
        self.base_df = df.reset_index(drop=True)
        if self.base_df.empty:
            raise ValueError("No hay velas válidas dentro del intervalo del replay")
        self.bars: list[Bar] = bars_from_df(self.base_df)
        self.synthetic = synthetic_market
        self.n_real = len(self.bars)
        self._times_ns = epoch_ns(self.base_df["time"])

        self.start_idx = max(1, self._index_for(start_time)) if start_time else min(200, len(self.bars))
        self.idx = self.start_idx            # nº de velas base visibles
        self.state = ReplayState.STOPPED
        self.speed = 1.0
        self._resampled: dict[str, pd.DataFrame] = {}
        self._resampled_upto = -1
        self._refresh_resample()

    # -- tiempo -----------------------------------------------------------
    def _index_for(self, t: datetime) -> int:
        """Número de velas base cerradas en el instante t."""
        t = pd.Timestamp(t).tz_convert("UTC") if pd.Timestamp(t).tzinfo else pd.Timestamp(t, tz="UTC")
        close_ns = self._times_ns + int(self.base_delta.total_seconds() * 1e9)
        return int((close_ns <= t.value).sum())

    @property
    def current_time(self) -> datetime:
        """current_replay_time = cierre de la última vela base visible."""
        if self.idx == 0:
            return self.bars[0].time
        return self.bars[self.idx - 1].time + self.base_delta

    @property
    def last_closed_bar(self) -> Optional[Bar]:
        return self.bars[self.idx - 1] if self.idx else None

    @property
    def in_synthetic_zone(self) -> bool:
        return self.idx > self.n_real

    # -- navegación -------------------------------------------------------
    def step_forward(self) -> bool:
        if self.idx < len(self.bars):
            self.idx += 1
            return True
        if self.synthetic is not None:
            sb = self.synthetic.step()
            self.bars.append(Bar(sb.time, sb.open, sb.high, sb.low, sb.close, sb.tick_volume,
                                 sb.spread, sb.first_extreme, True))
            self.idx += 1
            return True
        self.state = ReplayState.FINISHED
        return False

    def append_bars(self, new_bars: list[Bar]) -> int:
        """
        LIVE: añade velas reales recién cerradas. Si el replay estaba al final,
        avanza con ellas. Devuelve cuántas velas nuevas se añadieron.
        """
        if self.n_real != len(self.bars):
            raise RuntimeError("No se pueden añadir velas reales tras velas sintéticas")
        last = self.bars[-1].time
        add = [b for b in new_bars if b.time > last]
        if not add:
            return 0
        at_end = self.idx == len(self.bars)
        self.bars.extend(add)
        from core.models import bars_to_df
        self.base_df = pd.concat([self.base_df, bars_to_df(add)[self.base_df.columns.intersection(
            ["time", "open", "high", "low", "close", "tick_volume", "spread"])]], ignore_index=True)
        self.n_real = len(self.bars)
        self._times_ns = epoch_ns(self.base_df["time"])
        if at_end:
            self.idx = len(self.bars)
        return len(add)

    def step_back(self) -> bool:
        if self.idx > 1:
            self.idx -= 1
            if self.state == ReplayState.FINISHED:
                self.state = ReplayState.PAUSED
            return True
        return False

    def jump_to(self, t: datetime) -> None:
        self.idx = max(1, min(self._index_for(t), self.n_real))

    def reset(self) -> None:
        self.idx = self.start_idx
        self.state = ReplayState.STOPPED

    def play(self) -> None:
        if self.state != ReplayState.FINISHED:
            self.state = ReplayState.PLAYING

    def pause(self) -> None:
        if self.state == ReplayState.PLAYING:
            self.state = ReplayState.PAUSED

    def set_speed(self, s: float) -> None:
        if not (MIN_SPEED <= s <= MAX_SPEED):
            raise ValueError(f"Velocidad fuera de rango [{MIN_SPEED}, {MAX_SPEED}]: {s}")
        self.speed = float(s)

    def interval_ms(self, base_ms: int = 1000) -> int:
        """Milisegundos entre refrescos (1x = 1 vela por segundo)."""
        return max(MIN_INTERVAL_MS, int(base_ms / self.speed))

    def bars_per_tick(self, base_ms: int = 1000) -> int:
        """Velas a avanzar en cada refresco para mantener la velocidad pedida."""
        return max(1, round(self.speed * self.interval_ms(base_ms) / base_ms))

    # -- vistas por temporalidad ------------------------------------------------
    def _refresh_resample(self) -> None:
        """
        Remuestreo incremental: al llegar velas nuevas (sintéticas o LIVE) solo
        se recalcula desde el último intervalo abierto de cada temporalidad.
        """
        from core.models import bars_to_df
        n = len(self.bars)
        for tf in self.chart_tfs:
            cached = self._resampled.get(tf)
            covered = self._covered.get(tf, 0) if hasattr(self, "_covered") else 0
            if not hasattr(self, "_covered"):
                self._covered = {}
            if cached is None or self._resampled_upto == -1:
                self._resampled[tf] = resample_ohlc(bars_to_df(self.bars) if n != len(self.base_df)
                                                    else self.base_df, self.base_tf, tf)
                self._covered[tf] = n
                continue
            if covered == n:
                continue
            last_t = cached["time"].iloc[-1]
            k = covered
            while k > 0 and pd.Timestamp(self.bars[k - 1].time) >= last_t:
                k -= 1
            tail = resample_ohlc(bars_to_df(self.bars[k:]), self.base_tf, tf)
            self._resampled[tf] = pd.concat([cached[cached["time"] < last_t], tail], ignore_index=True)
            self._covered[tf] = n
        self._resampled_upto = n

    def visible(self, tf: str) -> pd.DataFrame:
        """Velas CERRADAS de tf en el instante actual. Nunca incluye futuro."""
        if not is_derivable(tf, self.base_tf):
            raise ValueError(f"Temporalidad {tf} no derivable desde {self.base_tf}")
        # Auxiliary studies may request a timeframe not currently shown in a panel.
        if tf not in self.chart_tfs:
            self.chart_tfs.append(tf)
            self._resampled_upto = -1
        self._refresh_resample()
        df = self._resampled[tf]
        return df[df["close_time"] <= pd.Timestamp(self.current_time)]

    def forming(self, tf: str) -> Optional[Bar]:
        """Vela de tf en formación, construida con velas base ya cerradas."""
        if self.idx == 0:
            return None
        last = self.bars[self.idx - 1]
        bstart = tf_bucket_start(last.time, tf)
        if last.time + self.base_delta >= tf_close(bstart, tf):
            return None    # la vela de tf acaba de cerrar
        members = []
        for b in reversed(self.bars[:self.idx]):
            if b.time < bstart:
                break
            members.append(b)
        members.reverse()
        return Bar(bstart, members[0].open, max(b.high for b in members), min(b.low for b in members),
                   members[-1].close, sum(b.tick_volume for b in members), members[-1].spread, None,
                   any(b.synthetic for b in members))

    def visible_base_bars(self) -> list[Bar]:
        return self.bars[:self.idx]
