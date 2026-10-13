"""
gm_synth.py — Generador de velas M1 SINTÉTICAS por bootstrap de bloques.

Cuando no hay histórico largo real (y la red del entorno bloquea las descargas),
genera años de M1 muestreando BLOQUES contiguos de los retornos reales del M1 del
usuario. El bootstrap por bloques (stationary/circular) conserva autocorrelación,
rachas de volatilidad y la forma intravela — suficiente para pruebas de ROBUSTEZ.

NO es historia real: es un universo plausible con el "ADN" del oro del usuario.
Sirve para estimar cómo se comporta una estrategia en muchos mercados parecidos,
no para afirmar lo que pasó. Salida en formato export de MT5 (TAB) → lo lee mt5_import.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from mt5_import import load_mt5   # noqa: E402

MIN_PER_YEAR = 1380 * 5 * 52      # ~ velas M1 de oro por año (23h x 5 días x 52 sem)


def synth_m1(real: pd.DataFrame, years: float = 5.0, block: int = 240, seed: int = 7) -> pd.DataFrame:
    c = real["close"].to_numpy(float); o = real["open"].to_numpy(float)
    h = real["high"].to_numpy(float); l = real["low"].to_numpy(float)
    sp = real["spread"].to_numpy(float)
    r = np.diff(np.log(c))                                   # retornos log M1
    up = np.log(np.maximum(h[1:], np.maximum(o[1:], c[1:])) / np.maximum(o[1:], c[1:]))   # mecha alta
    dn = np.log(np.minimum(o[1:], c[1:]) / np.minimum(l[1:], np.minimum(o[1:], c[1:])))   # mecha baja
    spr = sp[1:]
    n_src = len(r)
    n = int(years * MIN_PER_YEAR)
    rng = np.random.default_rng(seed)
    R = np.empty(n); UH = np.empty(n); UL = np.empty(n); SP = np.empty(n)
    i = 0
    while i < n:
        s = rng.integers(0, n_src - block)
        m = min(block, n - i); sl = slice(s, s + m)
        R[i:i + m] = r[sl]; UH[i:i + m] = up[sl]; UL[i:i + m] = dn[sl]; SP[i:i + m] = spr[sl]
        i += m
    close = c[-1] * np.exp(np.cumsum(R))
    opn = np.r_[c[-1], close[:-1]]
    high = np.maximum(opn, close) * np.exp(np.abs(UH))
    low = np.minimum(opn, close) * np.exp(-np.abs(UL))
    # calendario M1 saltando fines de semana
    t = pd.bdate_range("2021-01-04 00:00", periods=n, freq="min")
    df = pd.DataFrame({"time": t, "open": opn, "high": high, "low": low, "close": close,
                       "tickvol": 1, "volume": 0, "spread": SP.astype(int)})
    return df


def write_mt5_csv(df: pd.DataFrame, path: Path):
    out = df.copy()
    out["<DATE>"] = out["time"].dt.strftime("%Y.%m.%d")
    out["<TIME>"] = out["time"].dt.strftime("%H:%M:%S")
    cols = {"open": "<OPEN>", "high": "<HIGH>", "low": "<LOW>", "close": "<CLOSE>",
            "tickvol": "<TICKVOL>", "volume": "<VOL>", "spread": "<SPREAD>"}
    out = out.rename(columns=cols)
    out = out[["<DATE>", "<TIME>", "<OPEN>", "<HIGH>", "<LOW>", "<CLOSE>", "<TICKVOL>", "<VOL>", "<SPREAD>"]]
    for c in ("<OPEN>", "<HIGH>", "<LOW>", "<CLOSE>"):
        out[c] = out[c].round(2)
    out.to_csv(path, sep="\t", index=False)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("uso: python gm_synth.py <real_M1.csv> <salida.csv> [years=5] [seed=7]"); raise SystemExit(2)
    years = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0
    seed = int(sys.argv[4]) if len(sys.argv) > 4 else 7
    real = load_mt5(sys.argv[1])
    df = synth_m1(real, years, seed=seed)
    write_mt5_csv(df, Path(sys.argv[2]))
    print(f"sintético: {len(df)} velas M1 (~{years} años)  {df.time.iloc[0]} -> {df.time.iloc[-1]}  "
          f"-> {sys.argv[2]}")
