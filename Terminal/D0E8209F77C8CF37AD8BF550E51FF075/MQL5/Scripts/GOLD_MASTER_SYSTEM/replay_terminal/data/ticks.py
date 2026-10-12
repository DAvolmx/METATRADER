"""
data/ticks.py — Ticks reales de MT5 para resolver el orden dentro de la vela.

Problema: con solo OHLC no se sabe si una vela tocó antes el máximo o el
mínimo. Con los ticks (mt5.copy_ticks_range) se sabe exactamente.

  annotate_first_extreme(bars, ticks, tf)
      Para cada vela añade first_extreme = "HIGH"/"LOW": qué extremo del BID
      se alcanzó primero dentro de la vela según los ticks. Las velas sin
      ticks quedan en None (la política TICK_DATA aplica entonces su fallback
      y lo cuenta; nunca se inventa).

  fetch_ticks_range(symbol, start, end)
      Descarga por bloques diarios (no satura la memoria ni el terminal).

  bars_from_ticks(ticks, tf)
      Reconstruye velas BID desde ticks (útil para validar los datos del broker).
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Callable, Optional

import numpy as np
import pandas as pd

from core.models import TIMEFRAME_SECONDS, epoch_s

log = logging.getLogger(__name__)


def ticks_to_df(raw) -> pd.DataFrame:
    """Convierte el array de copy_ticks_* a DataFrame (time UTC con ms, bid, ask)."""
    df = pd.DataFrame(raw)
    if df.empty:
        return pd.DataFrame(columns=["time", "bid", "ask"])
    if "time_msc" in df:
        df["time"] = pd.to_datetime(df["time_msc"], unit="ms", utc=True)
    else:
        df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    df = df[df["bid"] > 0]
    return df[["time", "bid", "ask"]].sort_values("time", kind="stable").reset_index(drop=True)


def _bucket(times: pd.Series, tf: str) -> np.ndarray:
    s = epoch_s(times)
    return s - s % TIMEFRAME_SECONDS[tf]


def annotate_first_extreme(bars: pd.DataFrame, ticks: pd.DataFrame, tf: str) -> pd.DataFrame:
    out = bars.copy()
    if "first_extreme" not in out:
        out["first_extreme"] = None
    if ticks is None or ticks.empty:
        return out
    t = ticks.reset_index(drop=True).copy()
    t["_b"] = _bucket(t["time"], tf)
    t["_pos"] = np.arange(len(t))
    g = t.groupby("_b")
    pos_max = t.loc[g["bid"].idxmax(), ["_b", "_pos"]].set_index("_b")["_pos"]
    pos_min = t.loc[g["bid"].idxmin(), ["_b", "_pos"]].set_index("_b")["_pos"]
    fe = pd.Series(np.where(pos_max.values < pos_min.values, "HIGH", "LOW"), index=pos_max.index)
    fe = fe.astype(object)
    fe[pos_max.values == pos_min.values] = None          # un solo tick
    keys = _bucket(out["time"], tf)
    mapped = pd.Series(keys).map(fe)
    has = mapped.notna().to_numpy()
    col = np.array(list(out["first_extreme"]), dtype=object)
    col[has] = mapped[has].to_numpy()
    out["first_extreme"] = pd.Series([x if isinstance(x, str) else None for x in col], index=out.index, dtype=object)
    return out


def bars_from_ticks(ticks: pd.DataFrame, tf: str) -> pd.DataFrame:
    t = ticks.reset_index(drop=True).copy()
    t["_b"] = _bucket(t["time"], tf)
    g = t.groupby("_b")
    out = pd.DataFrame({"open": g["bid"].first(), "high": g["bid"].max(), "low": g["bid"].min(),
                        "close": g["bid"].last(), "tick_volume": g["bid"].size()})
    out["time"] = pd.to_datetime(out.index, unit="s", utc=True)
    return out.reset_index(drop=True)[["time", "open", "high", "low", "close", "tick_volume"]]


def fetch_ticks_range(symbol: str, start: datetime, end: datetime,
                      progress: Optional[Callable[[float], None]] = None) -> pd.DataFrame:
    """Descarga ticks por días con mt5.copy_ticks_range (función oficial)."""
    from mt5.connector import mt5, MT5_AVAILABLE
    if not MT5_AVAILABLE:
        raise RuntimeError("MetaTrader5 no disponible: no se pueden descargar ticks")
    parts = []
    day = start
    total = max((end - start).total_seconds(), 1)
    while day < end:
        nxt = min(day + timedelta(days=1), end)
        raw = mt5.copy_ticks_range(symbol, day, nxt, mt5.COPY_TICKS_ALL)
        if raw is None:
            log.warning(f"copy_ticks_range {day:%Y-%m-%d}: {mt5.last_error()}")
        elif len(raw):
            parts.append(ticks_to_df(raw))
        if progress:
            progress(min(1.0, (nxt - start).total_seconds() / total))
        day = nxt
    if not parts:
        return pd.DataFrame(columns=["time", "bid", "ask"])
    return pd.concat(parts, ignore_index=True).drop_duplicates()


def annotate_from_mt5(bars: pd.DataFrame, symbol: str, tf: str,
                      progress: Optional[Callable[[float], None]] = None) -> tuple[pd.DataFrame, float]:
    """Descarga los ticks del rango de `bars` y anota first_extreme. Devuelve (velas, cobertura 0..1)."""
    times = pd.to_datetime(bars["time"], utc=True)
    start = times.iloc[0].to_pydatetime()
    end = (times.iloc[-1] + pd.Timedelta(seconds=TIMEFRAME_SECONDS[tf])).to_pydatetime()
    out = bars.copy()
    out["first_extreme"] = None
    # por bloques para no tener millones de ticks en memoria
    day = start
    while day < end:
        nxt = min(day + timedelta(days=5), end)
        ticks = fetch_ticks_range(symbol, day, nxt)
        mask = (times >= day) & (times < nxt)
        if mask.any() and not ticks.empty:
            out.loc[mask] = annotate_first_extreme(out.loc[mask], ticks, tf)
        if progress:
            progress(min(1.0, (nxt - start).total_seconds() / max((end - start).total_seconds(), 1)))
        day = nxt
    coverage = float(out["first_extreme"].notna().mean()) if len(out) else 0.0
    return out, coverage
