"""
mt5_import.py — Importador robusto de datos históricos de MetaTrader 5 (offline).

Lee los ficheros que exporta MT5 desde "Símbolos → Barras → Exportar barras" o
desde el gráfico ("Guardar como"), tanto en CSV/TSV como en Excel, y devuelve un
DataFrame canónico listo para el resto del sistema GOLD MASTER:

    columnas: time (datetime64, UTC-naive tal como las da MT5), open, high, low,
              close, tickvol, volume, spread

Tolera:
  * separador TAB, coma o punto y coma (autodetección);
  * cabeceras con y sin <corchetes>:  <DATE> <TIME> <OPEN> ...  o  Date Time Open ...
  * ficheros con columna de hora separada (M1..H4) y sin ella (D1, W1, MN);
  * saltos de línea CRLF (Windows) o LF;
  * decimal con punto; miles sin separador (formato estándar de MT5);
  * columnas que falten (tickvol/volume/spread) → se rellenan con 0.

No depende de MetaTrader5 ni de Qt: corre en cualquier Python con pandas.
"""
from __future__ import annotations

from pathlib import Path
import io
import pandas as pd

__all__ = ["load_mt5", "resample", "TF_RULES"]

# Mapa de nombres de columna (ya en minúsculas, sin <>) → nombre canónico.
_ALIASES = {
    "date": "date", "fecha": "date",
    "time": "time", "hora": "time",
    "open": "open", "apertura": "open", "o": "open",
    "high": "high", "maximo": "high", "máximo": "high", "h": "high", "max": "high",
    "low": "low", "minimo": "low", "mínimo": "low", "l": "low", "min": "low",
    "close": "close", "cierre": "close", "c": "close",
    "tickvol": "tickvol", "tick_volume": "tickvol", "volumen_tick": "tickvol",
    "vol": "volume", "volume": "volume", "real_volume": "volume", "volumen": "volume",
    "spread": "spread",
}

_NUMERIC = ("open", "high", "low", "close", "tickvol", "volume", "spread")

TF_RULES = {
    "M1": "1min", "M2": "2min", "M3": "3min", "M4": "4min", "M5": "5min",
    "M6": "6min", "M10": "10min", "M12": "12min", "M15": "15min", "M20": "20min",
    "M30": "30min", "H1": "1h", "H2": "2h", "H3": "3h", "H4": "4h", "H6": "6h",
    "H8": "8h", "H12": "12h", "D1": "1D", "W1": "1W", "MN1": "1MS",
}


def _clean_header(name: str) -> str:
    return str(name).strip().strip("<>").strip().lower()


def _sniff_sep(sample: str) -> str:
    """Elige el separador con más apariciones en la primera línea."""
    first = sample.splitlines()[0] if sample else ""
    counts = {sep: first.count(sep) for sep in ("\t", ";", ",")}
    sep, n = max(counts.items(), key=lambda kv: kv[1])
    return sep if n > 0 else "\t"


def _read_table(path: Path) -> pd.DataFrame:
    suffix = path.suffix.lower()
    if suffix in (".xlsx", ".xlsm", ".xls"):
        return pd.read_excel(path, dtype=str)
    raw = path.read_bytes().decode("utf-8-sig", errors="replace")
    sep = _sniff_sep(raw)
    return pd.read_csv(io.StringIO(raw), sep=sep, dtype=str, engine="python")


def load_mt5(path: str | Path) -> pd.DataFrame:
    """Carga un export de barras de MT5 y devuelve el DataFrame canónico.

    Lanza ValueError con un mensaje claro si faltan columnas OHLC o las fechas
    no son parseables, para que el fallo sea entendible y no un KeyError opaco.
    """
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"No existe el fichero: {path}")

    df = _read_table(path)
    df.columns = [_ALIASES.get(_clean_header(c), _clean_header(c)) for c in df.columns]

    missing = [c for c in ("open", "high", "low", "close") if c not in df.columns]
    if missing:
        raise ValueError(
            f"{path.name}: faltan columnas OHLC {missing}. "
            f"Cabeceras leídas: {list(df.columns)}")

    if "date" not in df.columns:
        raise ValueError(f"{path.name}: no se encontró columna de fecha (<DATE>)")

    date = df["date"].astype(str).str.strip()
    if "time" in df.columns:
        stamp = date + " " + df["time"].astype(str).str.strip()
    else:
        stamp = date  # D1/W1/MN: sin hora
    # MT5 usa 'YYYY.MM.DD'; dejamos que pandas resuelva formatos mixtos.
    time = pd.to_datetime(stamp.str.replace(".", "-", regex=False),
                          format="mixed", errors="coerce")
    if time.isna().all():
        raise ValueError(f"{path.name}: no se pudieron parsear las fechas (ej. '{stamp.iloc[0]}')")

    out = pd.DataFrame({"time": time})
    for col in _NUMERIC:
        if col in df.columns:
            out[col] = pd.to_numeric(df[col].astype(str).str.replace(",", "", regex=False),
                                     errors="coerce")
        else:
            out[col] = 0.0

    out = (out.dropna(subset=["time", "open", "high", "low", "close"])
              .drop_duplicates(subset=["time"])
              .sort_values("time")
              .reset_index(drop=True))
    out[["tickvol", "volume", "spread"]] = out[["tickvol", "volume", "spread"]].fillna(0)
    if out.empty:
        raise ValueError(f"{path.name}: no quedaron velas válidas tras limpiar")
    return out


def resample(m1: pd.DataFrame, timeframe: str) -> pd.DataFrame:
    """Reagrega velas (normalmente M1) a una temporalidad mayor, sin look-ahead.

    El sello de tiempo de cada vela es el de APERTURA (igual que MT5). El spread
    se toma como media (redondeada) del periodo; tickvol/volume se suman.
    """
    tf = timeframe.upper()
    if tf not in TF_RULES:
        raise ValueError(f"Temporalidad no soportada: {timeframe}. Usa una de {list(TF_RULES)}")
    rule = TF_RULES[tf]
    g = (m1.set_index("time")
            .resample(rule, label="left", closed="left")
            .agg(open=("open", "first"), high=("high", "max"), low=("low", "min"),
                 close=("close", "last"), tickvol=("tickvol", "sum"),
                 volume=("volume", "sum"), spread=("spread", "mean"))
            .dropna(subset=["open", "high", "low", "close"]))
    g["spread"] = g["spread"].round().astype("int64")
    return g.reset_index()


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print("uso: python mt5_import.py <fichero.csv|xlsx> [TF]"); raise SystemExit(2)
    bars = load_mt5(sys.argv[1])
    print(f"{len(bars)} velas  {bars['time'].iloc[0]} -> {bars['time'].iloc[-1]}")
    if len(sys.argv) > 2:
        r = resample(bars, sys.argv[2])
        print(f"{sys.argv[2]}: {len(r)} velas")
        print(r.head().to_string(index=False))
