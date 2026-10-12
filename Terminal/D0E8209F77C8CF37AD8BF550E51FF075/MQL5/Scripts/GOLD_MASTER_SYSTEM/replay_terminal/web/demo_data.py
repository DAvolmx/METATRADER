"""
web/demo_data.py — Datos de DEMOSTRACIÓN (aleatorios, no reales) para probar
la web sin MT5. Se rotulan como símbolo "DEMO".
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from data.data_manager import resample_ohlc


def demo_history(base_tf: str = "M5", days: int = 30, seed: int = 7) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    idx = pd.date_range("2026-08-03", periods=days * 1440, freq="1min", tz="UTC")
    idx = idx[idx.weekday < 5]
    vol = np.where(np.isin(idx.hour, [13, 14, 15, 16]), 0.0006, 0.0002)
    trend = np.sin(np.arange(len(idx)) / 4000) * 0.00004
    close = 2300 * np.exp(np.cumsum(rng.normal(trend, vol)))
    open_ = np.concatenate([[2300], close[:-1]])
    wick = np.abs(rng.normal(0, vol)) * close
    df = pd.DataFrame({"time": idx, "open": open_.round(2),
                       "high": (np.maximum(open_, close) + wick).round(2),
                       "low": (np.minimum(open_, close) - wick).round(2), "close": close.round(2),
                       "tick_volume": rng.integers(10, 100, len(idx)), "spread": 20})
    if base_tf == "M1":
        return df
    return resample_ohlc(df, "M1", base_tf).drop(columns=["close_time", "complete"])
