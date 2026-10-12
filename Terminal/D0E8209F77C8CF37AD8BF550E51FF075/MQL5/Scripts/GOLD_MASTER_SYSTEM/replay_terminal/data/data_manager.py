"""
data/data_manager.py — DataManager: descarga, validación, huecos, caché y
remuestreo.

  MT5 ──► DataManager ──► SQLite cache ──► Replay / Backtest / Gráficos

Reglas:
  * Timestamps internos en UTC (tz-aware). MT5 entrega la hora del SERVIDOR
    del broker en segundos; se guarda tal cual, rotulada como UTC. Si el servidor
    del broker no está en GMT+0, las horas mostradas son "hora broker"; la
    UI muestra ambas para que se pueda verificar.
  * No se fabrican datos: los huecos se DETECTAN y se informan, no se rellenan.
  * Una temporalidad no disponible se puede DERIVAR de una inferior solo si
    es múltiplo exacto (resample_ohlc). W1 (semana desde el domingo, como MT5)
    y MN1 (mes natural) se derivan por calendario.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import pandas as pd

from core.models import TIMEFRAME_SECONDS, epoch_s, is_derivable

logger = logging.getLogger(__name__)

COLUMNS = ["time", "open", "high", "low", "close", "tick_volume", "spread"]


@dataclass
class ValidationReport:
    rows_in: int = 0
    rows_out: int = 0
    duplicates: int = 0
    invalid_ohlc: int = 0
    unsorted: bool = False
    gaps: list = field(default_factory=list)

    def summary(self) -> str:
        return (f"{self.rows_out}/{self.rows_in} velas válidas | duplicadas {self.duplicates} | "
                f"OHLC inválidas {self.invalid_ohlc} | desordenadas {self.unsorted} | "
                f"huecos {len(self.gaps)}")


def validate_bars(df: pd.DataFrame, timeframe: Optional[str] = None) -> tuple[pd.DataFrame, ValidationReport]:
    rep = ValidationReport(rows_in=len(df))
    missing = [c for c in ("time", "open", "high", "low", "close") if c not in df.columns]
    if missing:
        raise ValueError(f"Faltan columnas: {missing}")
    out = df.copy()
    out["time"] = pd.to_datetime(out["time"], utc=True)
    rep.unsorted = not out["time"].is_monotonic_increasing
    out = out.sort_values("time", kind="stable")
    before = len(out)
    out = out.drop_duplicates(subset="time", keep="last")
    rep.duplicates = before - len(out)
    for c in ("open", "high", "low", "close"):
        out[c] = pd.to_numeric(out[c], errors="coerce")
    bad = (~np.isfinite(out[["open", "high", "low", "close"]]).all(axis=1)
           | out["time"].isna()
           | (out[["open", "high", "low", "close"]] <= 0).any(axis=1)
           | (out["high"] < out[["open", "close"]].max(axis=1))
           | (out["low"] > out[["open", "close"]].min(axis=1)))
    rep.invalid_ohlc = int(bad.sum())
    out = out[~bad]
    if "tick_volume" not in out:
        out["tick_volume"] = 0
    if "spread" not in out:
        out["spread"] = 0
    for c in ("spread", "tick_volume"):
        values = pd.to_numeric(out[c], errors="coerce")
        if (~np.isfinite(values) | (values < 0) | (values % 1 != 0)).any():
            raise ValueError(f"{c} debe contener enteros finitos no negativos")
        out[c] = values
    out = out.reset_index(drop=True)
    rep.rows_out = len(out)
    if timeframe:
        rep.gaps = detect_gaps(out, timeframe)
    return out, rep


def detect_gaps(df: pd.DataFrame, timeframe: str, min_missing: int = 1,
                ignore_weekends: bool = True) -> list[dict]:
    """Huecos donde faltan >= min_missing velas (los fines de semana se omiten)."""
    tf = TIMEFRAME_SECONDS[timeframe]
    t = pd.to_datetime(df["time"], utc=True)
    secs = epoch_s(t)
    gaps = []
    for i in np.where(np.diff(secs) > tf)[0]:
        a, b = t.iloc[i], t.iloc[i + 1]
        missing = int((secs[i + 1] - secs[i]) // tf) - 1
        if missing < min_missing:
            continue
        if ignore_weekends and (a.weekday() >= 4 and b.weekday() in (6, 0)) and (b - a).days <= 3:
            continue
        gaps.append({"after": a, "before": b, "missing_bars": missing})
    return gaps


def _bucket_starts(times: pd.Series, to_tf: str) -> pd.Series:
    """Apertura de la vela de to_tf para cada timestamp (vectorizado)."""
    t = pd.to_datetime(times, utc=True)
    if to_tf == "MN1":
        return t.dt.tz_localize(None).dt.to_period("M").dt.start_time.dt.tz_localize("UTC")
    if to_tf == "W1":
        day = t.dt.floor("1D")
        return day - pd.to_timedelta((day.dt.weekday + 1) % 7, unit="D")
    secs = pd.Series(epoch_s(t), index=t.index)
    tf = TIMEFRAME_SECONDS[to_tf]
    return pd.to_datetime(secs - secs % tf, unit="s", utc=True)


def _bucket_closes(starts: pd.Series, to_tf: str) -> pd.Series:
    if to_tf == "MN1":
        return (starts.dt.tz_localize(None).dt.to_period("M") + 1).dt.start_time.dt.tz_localize("UTC")
    return starts + pd.Timedelta(seconds=TIMEFRAME_SECONDS[to_tf])


def resample_ohlc(df: pd.DataFrame, from_tf: str, to_tf: str) -> pd.DataFrame:
    """
    Deriva `to_tf` desde `from_tf` (incluye W1 con semana desde el domingo
    y MN1 por mes natural). Añade:
      close_time : instante de cierre de cada vela de to_tf
      complete   : False si con los datos disponibles el intervalo no terminó
    """
    if not is_derivable(to_tf, from_tf):
        raise ValueError(f"{to_tf} no se puede derivar de {from_tf}")
    f = TIMEFRAME_SECONDS[from_tf]
    if to_tf == from_tf:
        out = df.copy()
        out["time"] = pd.to_datetime(out["time"], utc=True)
        out["close_time"] = out["time"] + pd.Timedelta(seconds=f)
        out["complete"] = True
        return out
    times = pd.to_datetime(df["time"], utc=True)
    starts = _bucket_starts(times, to_tf)
    ends = times + pd.Timedelta(seconds=f)
    g = df.assign(_b=starts.values, _end=ends.values).groupby("_b", sort=True)
    agg = {"open": "first", "high": "max", "low": "min", "close": "last", "_end": "max"}
    if "tick_volume" in df:
        agg["tick_volume"] = "sum"
    if "spread" in df:
        agg["spread"] = "last"
    if "synthetic" in df:
        agg["synthetic"] = "max"
    out = g.agg(agg).reset_index().rename(columns={"_b": "time"})
    out["time"] = pd.to_datetime(out["time"], utc=True)
    out["close_time"] = _bucket_closes(out["time"], to_tf)
    out["complete"] = (pd.to_datetime(out["_end"], utc=True) >= out["close_time"]) | (out.index < len(out) - 1)
    return out[["time", "open", "high", "low", "close"]
               + [c for c in ("tick_volume", "spread", "synthetic") if c in out] + ["close_time", "complete"]]


class DataManager:
    """Fuente de datos con caché. MT5 es opcional (offline => caché/CSV)."""

    def __init__(self, db=None) -> None:
        self.db = db
        self._mem: dict[tuple[str, str], pd.DataFrame] = {}

    def get_bars(self, symbol: str, timeframe: str, count: int = 20000,
                 use_mt5: bool = True) -> tuple[pd.DataFrame, ValidationReport]:
        key = (symbol, timeframe)
        df = None
        if use_mt5:
            try:
                from mt5.market_data import fetch_rates
                df = fetch_rates(symbol, timeframe, count)
                if self.db is not None:
                    self.db.upsert_candles(symbol, timeframe, df)
            except Exception as exc:   # MT5 cerrado, símbolo inexistente, etc.
                logger.warning(f"MT5 no disponible para {symbol} {timeframe}: {exc}. Usando caché.")
                df = None
        if df is None and key in self._mem:
            df = self._mem[key]
        if df is None and self.db is not None:
            cached = self.db.load_candles(symbol, timeframe)
            if len(cached):
                df = cached.tail(count)
        if df is None or len(df) == 0:
            raise RuntimeError(f"Datos insuficientes para {symbol} {timeframe} (ni MT5 ni caché)")
        clean, rep = validate_bars(df, timeframe)
        self._mem[key] = clean
        return clean, rep

    def load_csv(self, path) -> tuple[pd.DataFrame, ValidationReport]:
        df = pd.read_csv(path)
        return validate_bars(df)
