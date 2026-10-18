"""
core/models.py — Modelos base compartidos por todas las capas.

Convención temporal (válida en TODO el sistema):
  Bar.time = APERTURA de la vela (igual que MT5).
  Una vela está CERRADA en el instante  time + duración_de_su_temporalidad.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Iterable, Optional

import numpy as np
import pandas as pd

# Duración NOMINAL (para ordenar y validar múltiplos). W1 y MN1 son
# temporalidades de CALENDARIO: sus límites se calculan con tf_bucket_start /
# tf_close (semana que empieza el DOMINGO 00:00 como en MT5; mes natural).
TIMEFRAME_SECONDS: dict[str, int] = {
    "M1": 60, "M2": 120, "M3": 180, "M5": 300, "M10": 600, "M15": 900, "M30": 1800,
    "H1": 3600, "H3": 10800, "H4": 14400, "D1": 86400, "W1": 7 * 86400, "MN1": 30 * 86400,
}
CALENDAR_TFS = ("W1", "MN1")
TIMEFRAMES_ORDER = list(TIMEFRAME_SECONDS.keys())


def epoch_ns(times) -> np.ndarray:
    """Nanosegundos Unix, independiente de la unidad interna de pandas (2.x usa ns, 3.x puede usar us)."""
    t = pd.to_datetime(pd.Series(times), utc=True).dt.as_unit("ns")
    return t.astype("int64").to_numpy()


def epoch_s(times) -> np.ndarray:
    return epoch_ns(times) // 1_000_000_000


def tf_delta(tf: str) -> timedelta:
    """Duración fija. No usar con MN1 (variable): usar tf_close."""
    if tf == "MN1":
        raise ValueError("MN1 no tiene duración fija: usa tf_close()")
    return timedelta(seconds=TIMEFRAME_SECONDS[tf])


def tf_bucket_start(t: datetime, tf: str) -> datetime:
    """Apertura de la vela de `tf` que contiene el instante t."""
    if tf == "MN1":
        return t.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    if tf == "W1":
        d = t.replace(hour=0, minute=0, second=0, microsecond=0)
        return d - timedelta(days=(d.weekday() + 1) % 7)       # domingo
    e = int(t.timestamp())
    s = TIMEFRAME_SECONDS[tf]
    return datetime.fromtimestamp(e - e % s, tz=t.tzinfo)


def tf_close(open_time: datetime, tf: str) -> datetime:
    """Instante de CIERRE de la vela de `tf` que abre en open_time."""
    if tf == "MN1":
        y, m = open_time.year + (open_time.month // 12), open_time.month % 12 + 1
        return open_time.replace(year=y, month=m, day=1, hour=0, minute=0, second=0, microsecond=0)
    return open_time + timedelta(seconds=TIMEFRAME_SECONDS[tf])


def is_derivable(tf: str, base: str) -> bool:
    """¿Se puede construir `tf` exactamente a partir de velas `base`?"""
    if TIMEFRAME_SECONDS[tf] < TIMEFRAME_SECONDS[base]:
        return False
    if tf in CALENDAR_TFS:
        return 86400 % TIMEFRAME_SECONDS[base] == 0 and base not in CALENDAR_TFS
    return TIMEFRAME_SECONDS[tf] % TIMEFRAME_SECONDS[base] == 0


# slots=True elimina el __dict__ por instancia. Medido con 500.000 velas:
# 198 bytes/vela y 3,1 s de construccion sin slots; el replay materializa
# la lista completa en el arranque, asi que con un historico M1 de anos la
# diferencia son cientos de MB y segundos de espera antes de la primera vela.
@dataclass(frozen=True, slots=True)
class Bar:
    time: datetime
    open: float
    high: float
    low: float
    close: float
    tick_volume: int = 0
    spread: int = 0
    first_extreme: Optional[str] = None   # "HIGH"/"LOW" si se conoce el orden intra-vela
    synthetic: bool = False


def bars_from_df(df: pd.DataFrame) -> list[Bar]:
    has_fe = "first_extreme" in df.columns
    has_syn = "synthetic" in df.columns
    has_vol = "tick_volume" in df.columns
    has_spr = "spread" in df.columns
    times = pd.to_datetime(df["time"], utc=True)
    o, h, l, c = (df[k].to_numpy(dtype=float) for k in ("open", "high", "low", "close"))
    vol = df["tick_volume"].fillna(0).to_numpy() if has_vol else None
    spr = df["spread"].fillna(0).to_numpy() if has_spr else None
    fe = df["first_extreme"].to_numpy() if has_fe else None
    syn = df["synthetic"].to_numpy() if has_syn else None
    out = []
    for i, t in enumerate(times):
        f = fe[i] if fe is not None else None
        out.append(Bar(
            time=t.to_pydatetime(), open=float(o[i]), high=float(h[i]), low=float(l[i]),
            close=float(c[i]),
            tick_volume=int(vol[i]) if vol is not None else 0,
            spread=int(spr[i]) if spr is not None else 0,
            first_extreme=f if isinstance(f, str) else None,
            synthetic=bool(syn[i]) if syn is not None else False,
        ))
    return out


def bars_to_df(bars: Iterable) -> pd.DataFrame:
    cols = ["time", "open", "high", "low", "close", "tick_volume", "spread",
            "first_extreme", "synthetic"]
    rows = [(b.time, b.open, b.high, b.low, b.close, b.tick_volume, b.spread,
             getattr(b, "first_extreme", None), getattr(b, "synthetic", False)) for b in bars]
    df = pd.DataFrame(rows, columns=cols)
    if len(df):
        df["time"] = pd.to_datetime(df["time"], utc=True)
    return df
