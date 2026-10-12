"""
mt5/market_data.py
==================
Descarga mínima de velas y especificación de símbolo desde MT5.
(Base de la FASE 2; el DataManager completo con caché SQLite vendrá después.)

Funciones MT5 usadas (todas reales y documentadas):
  mt5.symbol_select, mt5.symbol_info, mt5.symbol_info_tick,
  mt5.copy_rates_from_pos, mt5.account_info, mt5.last_error

Nota sobre la hora: MT5 devuelve `time` en segundos según la hora del
SERVIDOR del broker. Se guarda tal cual, marcada como UTC de forma
convencional. Para el simulador es consistente porque calibración y
generación usan la misma referencia.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Optional

import pandas as pd

from mt5.connector import mt5, MT5_AVAILABLE

logger = logging.getLogger(__name__)

TIMEFRAME_NAMES = ("M1", "M5", "M10", "M15", "M30", "H1", "H3", "H4", "D1")


def _tf_constant(timeframe: str) -> int:
    if timeframe not in TIMEFRAME_NAMES:
        raise ValueError(f"Temporalidad no soportada: {timeframe}")
    return getattr(mt5, f"TIMEFRAME_{timeframe}")


def ensure_symbol(symbol: str) -> None:
    if not MT5_AVAILABLE:
        raise RuntimeError("MetaTrader5 no disponible")
    info = mt5.symbol_info(symbol)
    if info is None:
        raise ValueError(f"El símbolo '{symbol}' no existe en este broker. ¿Quizá {symbol}m o GOLD?")
    if not info.visible and not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"No se pudo hacer visible '{symbol}': {mt5.last_error()}")


def fetch_rates(symbol: str, timeframe: str, count: int) -> pd.DataFrame:
    """Descarga las últimas `count` velas. Descarta la vela en formación si el mercado está abierto."""
    ensure_symbol(symbol)
    rates = mt5.copy_rates_from_pos(symbol, _tf_constant(timeframe), 0, count)
    if rates is None or len(rates) == 0:
        raise RuntimeError(f"copy_rates_from_pos devolvió vacío: {mt5.last_error()}")

    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)

    # Descartar la última vela si todavía está en formación. Si el mercado está
    # cerrado (último tick hace > 1 h) la última vela ya es definitiva y se conserva.
    import time as _time
    from core.models import TIMEFRAME_SECONDS
    tick = mt5.symbol_info_tick(symbol)
    if tick is not None:
        last_open = int(df["time"].iloc[-1].timestamp())
        lag = _time.time() - int(tick.time)          # el servidor puede ir adelantado (lag < 0)
        market_active = lag < 3600
        if market_active and last_open + TIMEFRAME_SECONDS[timeframe] > int(tick.time):
            df = df.iloc[:-1]
            logger.info("Última vela en formación descartada.")

    cols = [c for c in ("time", "open", "high", "low", "close", "tick_volume", "spread") if c in df]
    return df[cols].reset_index(drop=True)


def get_symbol_spec(symbol: str) -> dict:
    ensure_symbol(symbol)
    info = mt5.symbol_info(symbol)
    acc = mt5.account_info()
    return {
        "symbol": symbol,
        "digits": int(info.digits),
        "point": float(info.point),
        "contract_size": float(info.trade_contract_size),
        "profit_currency": info.currency_profit,
        "account_currency": acc.currency if acc else None,
        "volume_min": float(info.volume_min),
        "volume_max": float(info.volume_max),
        "volume_step": float(info.volume_step),
        "stops_level": int(info.trade_stops_level),
        "swap_long": float(info.swap_long),
        "swap_short": float(info.swap_short),
        "swap_mode": int(info.swap_mode),
        "swap_rollover3days": int(info.swap_rollover3days),
        "base_currency": info.currency_base,
        "margin_currency": info.currency_margin,
    }


def list_symbols(pattern: str = "") -> list[str]:
    """Símbolos del broker (mt5.symbols_get). Filtro simple por subcadena."""
    if not MT5_AVAILABLE:
        return []
    syms = mt5.symbols_get()
    names = sorted(s.name for s in (syms or ()))
    return [n for n in names if pattern.upper() in n.upper()] if pattern else names


def current_tick(symbol: str):
    """Último tick (bid/ask/time) o None."""
    return mt5.symbol_info_tick(symbol) if MT5_AVAILABLE else None


def save_history(df: pd.DataFrame, spec: dict, folder: Path, timeframe: str) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    base = folder / f"{spec['symbol']}_{timeframe}"
    df.to_csv(base.with_suffix(".csv"), index=False)
    with open(base.with_suffix(".meta.json"), "w", encoding="utf-8") as f:
        json.dump(spec, f, indent=2)
    return base.with_suffix(".csv")


def load_history(csv_path: Path) -> tuple[pd.DataFrame, Optional[dict]]:
    df = pd.read_csv(csv_path)
    df["time"] = pd.to_datetime(df["time"], utc=True)
    meta_path = Path(str(csv_path)[:-4] + ".meta.json")
    spec = None
    if meta_path.exists():
        with open(meta_path, encoding="utf-8") as f:
            spec = json.load(f)
    return df, spec
