"""
simulation/synthetic_market.py
==============================
Generador de mercado SINTÉTICO calibrado con velas reales de MT5.

Caso de uso
-----------
Es fin de semana, el mercado está cerrado. El usuario descarga las últimas
velas reales y quiere seguir "operando" sobre un futuro simulado que tenga
un comportamiento estadístico parecido al del símbolo real.

ADVERTENCIA
-----------
Los datos generados NO son una predicción. Son un escenario plausible
construido remuestreando el comportamiento histórico. Sirven para entrenar
la ejecución y la lectura del gráfico, no para estimar rentabilidad real.

Decisión técnica (ambigüedad documentada)
-----------------------------------------
Alternativas evaluadas para generar precios:
  1. Paseo aleatorio / GBM (volatilidad constante, colas normales).
     Descartado: no reproduce colas gruesas, ni clusters de volatilidad,
     ni la estacionalidad intradía (Londres / Nueva York vs Asia).
  2. Modelos GARCH. Reproducen clusters de volatilidad, pero requieren
     estimación de parámetros y no reproducen mechas ni forma de vela.
  3. Block bootstrap de velas históricas  <-- ELEGIDO
     Se copian bloques de velas consecutivas reales (en forma RELATIVA:
     retornos y tamaño de mechas), encadenados a partir del último precio.
     - Conserva colas gruesas, mechas y autocorrelación de corto plazo.
     - Cada bloque se elige entre los que empiezan a la MISMA HORA del día
       que la vela simulada => conserva la estacionalidad intradía.
     - Se puede eliminar la deriva histórica (remove_drift) para que el
       escenario no herede la tendencia del periodo descargado.

Garantías
---------
  * Generación incremental: la vela N+1 NO existe hasta que se llama a
    step(). No hay futuro precalculado que se pueda "espiar".
  * Reproducible con semilla (seed).
  * OHLC siempre coherente: high >= max(open, close), low <= min(open, close).
  * Cada vela conoce qué extremo se alcanzó primero (first_extreme), así el
    motor de simulación resuelve SL/TP sin ambigüedad dentro del mundo
    sintético.
  * Las horas de mercado se respetan: solo se generan velas en franjas
    hora-de-la-semana que existen en el histórico (no inventa sesiones).
"""

from __future__ import annotations

from core.models import epoch_ns

import math
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Optional

import numpy as np
import pandas as pd

SYNTHETIC_ENGINE_VERSION = "1.0"

from core.models import TIMEFRAME_SECONDS  # fuente única

REQUIRED_COLUMNS = ("time", "open", "high", "low", "close")


# ---------------------------------------------------------------------------
# Modelos
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class SyntheticBar:
    """Vela sintética. `synthetic=True` siempre: nunca se confunde con datos reales."""
    time: datetime          # apertura de la vela
    open: float
    high: float
    low: float
    close: float
    tick_volume: int
    spread: int             # en puntos (igual que MT5)
    first_extreme: str      # "HIGH" o "LOW": qué extremo se tocó primero
    synthetic: bool = True


@dataclass
class SimConfig:
    timeframe: str = "M1"           # temporalidad base generada
    block_size: int = 30            # velas por bloque remuestreado
    vol_multiplier: float = 1.0     # 1.0 = volatilidad histórica
    remove_drift: bool = True       # quitar la tendencia media del histórico
    respect_sessions: bool = True   # no generar velas fuera de horario
    min_slot_count: int = 3         # apariciones mínimas de una franja hora-semana
    seed: Optional[int] = None
    digits: Optional[int] = None    # None = inferir del histórico


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
def infer_digits(prices: np.ndarray, max_digits: int = 6) -> int:
    """Infiere los decimales del símbolo a partir de los precios históricos."""
    sample = prices[: min(len(prices), 2000)]
    for d in range(0, max_digits + 1):
        if np.all(np.abs(np.round(sample, d) - sample) < 10 ** (-(d + 2))):
            return d
    return max_digits


def hour_of_week(t: datetime) -> int:
    return t.weekday() * 24 + t.hour


def prepare_history(df: pd.DataFrame) -> pd.DataFrame:
    """Valida y limpia un DataFrame de velas (formato MT5 copy_rates_*)."""
    missing = [c for c in REQUIRED_COLUMNS if c not in df.columns]
    if missing:
        raise ValueError(f"Faltan columnas en el histórico: {missing}")

    out = df.copy()
    out["time"] = pd.to_datetime(out["time"], utc=True)
    out = out.sort_values("time").drop_duplicates(subset="time", keep="last")
    for col in ("open", "high", "low", "close"):
        out[col] = out[col].astype(float)

    bad = (
        (out[["open", "high", "low", "close"]] <= 0).any(axis=1)
        | (out["high"] < out[["open", "close"]].max(axis=1))
        | (out["low"] > out[["open", "close"]].min(axis=1))
    )
    out = out[~bad]

    if "tick_volume" not in out.columns:
        out["tick_volume"] = 0
    if "spread" not in out.columns:
        out["spread"] = 0
    return out.reset_index(drop=True)


# ---------------------------------------------------------------------------
# Calibración
# ---------------------------------------------------------------------------
class MarketCalibration:
    """
    Convierte el histórico en componentes relativos reutilizables:
      r_oc : log(close/open)            cuerpo
      r_up : log(high/max(open,close))  mecha superior (>=0)
      r_dn : log(min(open,close)/low)   mecha inferior (>=0)
      gap  : log(open/close_anterior)   (0 si hay hueco de sesión)
    """

    def __init__(self, df: pd.DataFrame, timeframe: str = "M1", block_size: int = 30) -> None:
        if timeframe not in TIMEFRAME_SECONDS:
            raise ValueError(f"Temporalidad no soportada: {timeframe}")
        hist = prepare_history(df)
        if len(hist) < block_size * 5:
            raise ValueError(
                f"Histórico insuficiente: {len(hist)} velas. "
                f"Se necesitan al menos {block_size * 5} (block_size x 5)."
            )

        self.timeframe = timeframe
        self.tf_seconds = TIMEFRAME_SECONDS[timeframe]
        self.block_size = block_size
        self.times: list[datetime] = [t.to_pydatetime() for t in hist["time"]]

        o = hist["open"].to_numpy()
        h = hist["high"].to_numpy()
        l = hist["low"].to_numpy()
        c = hist["close"].to_numpy()

        self.r_oc = np.log(c / o)
        self.r_up = np.log(h / np.maximum(o, c))
        self.r_dn = np.log(np.minimum(o, c) / l)

        dt = np.diff(epoch_ns(hist["time"])) / 1e9
        breaks = np.concatenate([[True], dt > 1.5 * self.tf_seconds])   # hueco ANTES de la vela i
        gap = np.zeros(len(c))
        gap[1:] = np.log(o[1:] / c[:-1])
        gap[breaks] = 0.0
        self.gap = gap

        self.tick_volume = hist["tick_volume"].to_numpy().astype(int)
        self.spread = hist["spread"].to_numpy().astype(int)
        self.drift = float(np.mean(self.r_oc + self.gap))
        self.digits = infer_digits(np.concatenate([o, h, l, c]))

        # Inicios de bloque válidos: el bloque no cruza un hueco de sesión.
        n = len(c)
        cum_breaks = np.cumsum(breaks.astype(int))
        starts = []
        for i in range(0, n - block_size + 1):
            # huecos en (i, i+block_size-1]  => cum[i+b-1] - cum[i]
            if cum_breaks[i + block_size - 1] - cum_breaks[i] == 0:
                starts.append(i)
        if not starts:
            raise ValueError("No hay bloques continuos suficientes en el histórico.")
        self.valid_starts = np.array(starts, dtype=int)

        hours = np.array([self.times[i].hour for i in self.valid_starts])
        self.starts_by_hour: dict[int, np.ndarray] = {
            hr: self.valid_starts[hours == hr] for hr in range(24)
        }

        slots = [hour_of_week(t) for t in self.times]
        self.slot_counts = np.bincount(slots, minlength=168)

        self.last_time: datetime = self.times[-1]
        self.last_close: float = float(c[-1])
        self.last_spread: int = int(self.spread[-1])
        self.n_bars = n


# ---------------------------------------------------------------------------
# Generador
# ---------------------------------------------------------------------------
class SyntheticMarket:
    """
    Genera velas sintéticas UNA A UNA a continuación del último dato real.

        calib = MarketCalibration(df, "M1")
        market = SyntheticMarket(calib, SimConfig(seed=42))
        bar = market.step()
    """

    def __init__(self, calibration: MarketCalibration, config: Optional[SimConfig] = None) -> None:
        self.calib = calibration
        self.config = config or SimConfig(timeframe=calibration.timeframe)
        if self.config.timeframe != calibration.timeframe:
            raise ValueError("SimConfig.timeframe debe coincidir con la calibración.")
        if self.config.vol_multiplier <= 0:
            raise ValueError("vol_multiplier debe ser > 0")

        self.rng = np.random.default_rng(self.config.seed)
        self.digits = self.config.digits if self.config.digits is not None else calibration.digits
        self.tf = timedelta(seconds=calibration.tf_seconds)

        self._price: float = calibration.last_close
        self._time: datetime = calibration.last_time
        self._block_start: Optional[int] = None
        self._block_offset: int = 0
        self.bars_generated: int = 0

    # -- estado público -------------------------------------------------
    @property
    def current_time(self) -> datetime:
        """Apertura de la última vela generada (o del último dato real)."""
        return self._time

    @property
    def last_price(self) -> float:
        return self._price

    # -- internos ---------------------------------------------------------
    def _slot_is_open(self, t: datetime) -> bool:
        return self.calib.slot_counts[hour_of_week(t)] >= self.config.min_slot_count

    def _next_time(self) -> datetime:
        t = self._time + self.tf
        if not self.config.respect_sessions:
            return t
        max_steps = int(7 * 86400 / self.calib.tf_seconds) + 2
        for _ in range(max_steps):
            if self._slot_is_open(t):
                return t
            t += self.tf
        raise RuntimeError("No se encontró ninguna franja de mercado abierta en el histórico.")

    def _pick_block(self, t: datetime) -> int:
        candidates = self.calib.starts_by_hour.get(t.hour)
        if candidates is None or len(candidates) == 0:
            candidates = self.calib.valid_starts
        return int(self.rng.choice(candidates))

    def _round(self, x: float) -> float:
        return round(x, self.digits)

    # -- API --------------------------------------------------------------
    def step(self) -> SyntheticBar:
        """Genera y devuelve la siguiente vela cerrada."""
        t = self._next_time()
        session_gap = (t - self._time) > self.tf * 1.5

        if (
            self._block_start is None
            or self._block_offset >= self.calib.block_size
            or session_gap
        ):
            self._block_start = self._pick_block(t)
            self._block_offset = 0

        i = self._block_start + self._block_offset
        first_in_block = self._block_offset == 0
        self._block_offset += 1

        v = self.config.vol_multiplier
        drift = self.calib.drift if self.config.remove_drift else 0.0

        gap = 0.0 if first_in_block else self.calib.gap[i] * v
        r_oc = (self.calib.r_oc[i] - drift) * v
        r_up = self.calib.r_up[i] * v
        r_dn = self.calib.r_dn[i] * v

        o = self._price * math.exp(gap)
        c = o * math.exp(r_oc)
        h = max(o, c) * math.exp(r_up)
        l = min(o, c) * math.exp(-r_dn)

        o, c, h, l = self._round(o), self._round(c), self._round(h), self._round(l)
        h = max(h, o, c)
        l = min(l, o, c)

        bar = SyntheticBar(
            time=t,
            open=o,
            high=h,
            low=l,
            close=c,
            tick_volume=int(self.calib.tick_volume[i]),
            spread=int(self.calib.spread[i]),
            first_extreme="HIGH" if self.rng.random() < 0.5 else "LOW",
        )
        self._price = c
        self._time = t
        self.bars_generated += 1
        return bar


# Agregador multitemporal: implementación única en data/aggregator.py
from data.aggregator import BarAggregator as TimeframeAggregator  # noqa: E402,F401
