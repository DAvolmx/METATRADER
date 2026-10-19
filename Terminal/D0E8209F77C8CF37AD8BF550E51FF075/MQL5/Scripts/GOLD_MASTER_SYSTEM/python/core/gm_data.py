"""
gm_data.py — Carga unificada de datos de mercado para todo el sistema.

Un solo sitio que entiende todos los formatos que entran al sistema, para que
ningún módulo tenga que volver a adivinar separadores ni formatos de fecha:

  * Exportación de MetaTrader 5  (TSV con cabeceras <DATE> <TIME> <OPEN>…)
  * CSV genérico                 (coma o punto y coma, con o sin columna hora)
  * Excel                        (.xlsx / .xls)

Devuelve siempre el mismo contrato: DataFrame con DatetimeIndex UTC ordenado y
columnas open/high/low/close/volume (float), sin duplicados ni precios ≤ 0.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

#: nombres aceptados para cada columna del contrato, en minúsculas y sin <>
ALIASES = {
    "open": ("open", "o", "apertura"),
    "high": ("high", "h", "max", "maximo", "máximo"),
    "low": ("low", "l", "min", "minimo", "mínimo"),
    "close": ("close", "c", "cierre", "last", "price", "adj close"),
    # tickvol ANTES que vol a proposito: en los CFD (oro incluido) la columna
    # <VOL> (volumen real) viene a cero y <TICKVOL> es la que trae el dato. Con
    # el orden inverso el volumen quedaba en cero en todo el sistema, en
    # silencio. Aun asi se elige por CONTENIDO mas abajo, no solo por orden.
    "volume": ("tickvol", "volume", "volumen", "vol", "real volume"),
}


def _clean(name: str) -> str:
    return str(name).strip().strip("<>").strip().lower().replace(" ", "")


def _sniff_sep(path: Path) -> str:
    """Detecta el separador contando candidatos en la primera línea no vacía."""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.strip():
                counts = {s: line.count(s) for s in ("\t", ";", ",")}
                return max(counts, key=counts.get) if max(counts.values()) else ","
    return ","


def _build_index(df: pd.DataFrame) -> pd.DatetimeIndex:
    """Construye el índice temporal a partir de las columnas de fecha/hora."""
    cols = {_clean(c): c for c in df.columns}
    date_c = next((cols[k] for k in ("date", "fecha", "datetime", "time", "timestamp")
                   if k in cols), None)
    if date_c is None:
        raise ValueError(f"no encuentro columna de fecha en {list(df.columns)}")
    time_c = cols.get("time") if _clean(date_c) != "time" else None
    raw = df[date_c].astype(str)
    if time_c is not None and time_c != date_c:
        raw = raw.str.strip() + " " + df[time_c].astype(str).str.strip()
    # MT5 usa 2004.06.11; pandas lo entiende mejor con guiones
    idx = pd.to_datetime(raw.str.replace(".", "-", regex=False).str.strip(),
                         errors="coerce", format="mixed")
    if idx.isna().all():
        idx = pd.to_datetime(df[date_c], errors="coerce", unit="s")
    return pd.DatetimeIndex(idx)


def load(path: str | Path, tz: str | None = None) -> pd.DataFrame:
    """Carga un fichero de velas al contrato estándar del sistema.

    Levanta ValueError si el fichero no tiene fecha o cierre utilizables: es
    preferible fallar ruidosamente que devolver un DataFrame medio vacío que
    luego se backtestea como si fuera bueno.
    """
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(p)

    if p.suffix.lower() in (".xlsx", ".xls"):
        df = pd.read_excel(p)
    else:
        df = pd.read_csv(p, sep=_sniff_sep(p), engine="python",
                         skipinitialspace=True, encoding_errors="replace")

    idx = _build_index(df)
    out = pd.DataFrame(index=idx)
    cols = {_clean(c): c for c in df.columns}
    for target, names in ALIASES.items():
        cands = [cols[n] for n in names if n in cols]
        if not cands:
            continue
        # .to_numpy() es obligatorio: df[src] trae un RangeIndex y pandas
        # alinearía por índice contra el DatetimeIndex de `out`, dejando la
        # columna entera en NaN sin avisar.
        vals = [pd.to_numeric(df[c], errors="coerce").to_numpy() for c in cands]
        if target == "volume" and len(vals) > 1:
            # elige por CONTENIDO: la primera candidata con algún dato real.
            # Un fichero puede traer <VOL> y <TICKVOL> y que una de las dos sea
            # toda ceros, asi que el orden de la lista no basta.
            vals = sorted(vals, key=lambda a: -float(np.nansum(np.abs(a))))
        out[target] = vals[0]

    if "close" not in out.columns:
        raise ValueError(f"{p.name}: no encuentro columna de cierre entre {list(df.columns)}")
    for c in ("open", "high", "low"):
        if c not in out.columns:
            out[c] = out["close"]
    if "volume" not in out.columns:
        out["volume"] = 0.0

    out = out[~out.index.isna()]
    out = out[np.isfinite(out["close"]) & (out["close"] > 0)]
    out = out[~out.index.duplicated(keep="first")].sort_index()
    if tz:
        out.index = out.index.tz_localize(tz) if out.index.tz is None \
            else out.index.tz_convert(tz)
    if len(out) == 0:
        raise ValueError(f"{p.name}: 0 filas utilizables tras limpiar")
    return out[["open", "high", "low", "close", "volume"]]


def resample(df: pd.DataFrame, rule: str) -> pd.DataFrame:
    """Reagrupa velas a una temporalidad mayor (p.ej. '4h', '1D')."""
    agg = {"open": "first", "high": "max", "low": "min", "close": "last", "volume": "sum"}
    out = df.resample(rule).agg(agg).dropna(subset=["close"])
    return out


def describe(df: pd.DataFrame) -> str:
    """Resumen de una línea para los logs: periodo, barras y rango de precio."""
    span_d = (df.index[-1] - df.index[0]).total_seconds() / 86400.0
    return (f"{len(df):,} barras  {df.index[0]:%Y-%m-%d} → {df.index[-1]:%Y-%m-%d}  "
            f"({span_d/365.25:.1f} años)  precio {df['close'].min():.2f}–{df['close'].max():.2f}")


__all__ = ["load", "resample", "describe", "ALIASES"]
