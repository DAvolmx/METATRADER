# -*- coding: utf-8 -*-
"""
GOLD MASTER — DXY (índice del dólar)
Orden de fuentes:
  1. Símbolo directo en MT5 (USDX, DXY, DX, USDIndex…)
  2. DXY SINTÉTICO desde los pares FX del broker (fórmula oficial ICE):
     DXY = 50.14348112·EURUSD^-0.576·USDJPY^0.136·GBPUSD^-0.119·USDCAD^0.091·USDSEK^0.042·USDCHF^0.036
  3. Twelve Data (API gratis, 800 llamadas/día): DXY sintético con EUR/USD, USD/JPY… (env TWELVEDATA_API_KEY)
  4. Yahoo Finance (DX-Y.NYB, el índice ICE real, con retraso)
Macro (diario, FRED — env FRED_API_KEY, gratis en fred.stlouisfed.org):
  · DFII10  = rendimiento REAL a 10 años (TIPS): el driver #1 del oro a medio plazo (↑ real yield → oro ↓)
  · DTWEXBGS = índice dólar ponderado por comercio de la Fed (confirma la tendencia del DXY)
"""
import os, json, urllib.request
import time
import numpy as np
import pandas as pd
from gm_feed import DXY_SYMBOLS, resolve_symbol

try:
    import MetaTrader5 as mt5
except ImportError:
    mt5 = None

W = {"EURUSD": -0.576, "USDJPY": 0.136, "GBPUSD": -0.119, "USDCAD": 0.091, "USDSEK": 0.042, "USDCHF": 0.036}
DIRECT = list(DXY_SYMBOLS)


class DXYEngine:
    def __init__(self):
        self.mode, self.direct, self.pairs = "N/A", None, {}
        self._resolved = False
        self._cache, self._cache_t = {}, {}

    def _resolve(self):
        if self._resolved or mt5 is None:
            return
        names = [s.name for s in (mt5.symbols_get() or [])]
        if not names:
            return  # terminal disconnected: retry after reconnect
        self.direct = resolve_symbol(mt5, DIRECT, os.getenv("GM_DXY_SYMBOL"))
        if self.direct:
            self.mode, self._resolved = f"MT5 directo ({self.direct})", True
            return
        for base in W:
            cands = [n for n in names if base in n]
            cands.sort(key=len)                       # 'EURUSD' antes que 'EURUSD.m'
            for c in cands:
                if mt5.symbol_select(c, True):
                    self.pairs[base] = c
                    break
        if set(W) <= set(self.pairs):
            self.mode, self._resolved = "sintético MT5 (6/6 pares)", True

    def _rates(self, sym, tf, n):
        r = mt5.copy_rates_from_pos(sym, tf, 1, n)  # closed bars only
        if r is None or len(r) == 0:
            return None
        d = pd.DataFrame(r)
        d["time"] = pd.to_datetime(d["time"], unit="s")
        return d.set_index("time")["close"]

    def series(self, tf_name="H1", n=300):
        """Serie de cierres del DXY (pd.Series indexada por tiempo)."""
        key = (tf_name, n)
        if key in self._cache and time.time() - self._cache_t[key] < 30:
            return self._cache[key]
        s = None
        if mt5 is not None:
            self._resolve()
            tf = getattr(mt5, f"TIMEFRAME_{tf_name}")
            if self.direct:
                s = self._rates(self.direct, tf, n)
            elif self.pairs and "EURUSD" in self.pairs:
                frames = {b: self._rates(sym, tf, n) for b, sym in self.pairs.items()}
                frames = {b: f for b, f in frames.items() if f is not None}
                if set(W) <= set(frames):
                    df = pd.DataFrame(frames).dropna()  # simultaneous complete basket
                    s = 50.14348112 * np.exp(sum(np.log(df[b]) * W[b] for b in df.columns))
        if s is None or len(s) == 0:
            s = self._twelvedata(tf_name, n)
        if s is None or len(s) == 0:
            s = self._yahoo(tf_name, n)
        if s is not None:
            self._cache[key], self._cache_t[key] = s, time.time()
        return s

    def _twelvedata(self, tf_name, n):
        key = os.environ.get("TWELVEDATA_API_KEY", "")
        if not key:
            return None
        iv = {"M1": "1min", "M5": "5min", "M15": "15min", "M30": "30min", "H1": "1h", "H4": "4h", "D1": "1day"}.get(tf_name, "1h")
        tdsym = {"EURUSD": "EUR/USD", "USDJPY": "USD/JPY", "GBPUSD": "GBP/USD", "USDCAD": "USD/CAD", "USDSEK": "USD/SEK", "USDCHF": "USD/CHF"}
        try:
            url = (f"https://api.twelvedata.com/time_series?symbol={','.join(tdsym.values())}"
                   f"&interval={iv}&outputsize={min(n, 5000)}&apikey={key}")
            data = json.loads(urllib.request.urlopen(url, timeout=15).read())
            frames = {}
            for base, tds in tdsym.items():
                vals = (data.get(tds) or {}).get("values")
                if vals:
                    f = pd.DataFrame(vals)
                    frames[base] = pd.Series(f["close"].astype(float).values, index=pd.to_datetime(f["datetime"])).sort_index()
            if not set(W) <= set(frames):
                return None
            df = pd.DataFrame(frames).dropna()
            self.mode = f"Twelve Data sintético ({len(frames)}/6)"
            return 50.14348112 * np.exp(sum(np.log(df[b]) * W[b] for b in df.columns))
        except Exception:
            return None

    def macro(self):
        """Rendimiento real 10y (DFII10) y dólar amplio Fed (DTWEXBGS) vía FRED. Cache 6h."""
        if getattr(self, "_macro_t", 0) and time.time() - self._macro_t < 6 * 3600:
            return self._macro
        key, out = os.environ.get("FRED_API_KEY", ""), {}
        if key:
            for sid in ("DFII10", "DTWEXBGS"):
                try:
                    url = (f"https://api.stlouisfed.org/fred/series/observations?series_id={sid}&api_key={key}"
                           f"&file_type=json&sort_order=desc&limit=40")
                    obs = json.loads(urllib.request.urlopen(url, timeout=15).read())["observations"]
                    v = [float(o["value"]) for o in obs if o["value"] not in (".", "")]
                    if len(v) > 21:
                        out[sid] = {"last": v[0], "chg_20d": v[0] - v[20]}
                except Exception:
                    pass
        ry = out.get("DFII10")
        # real yield subiendo > 10pb en 20 días → presión bajista sobre el oro
        out["ry_bias"] = (-1 if ry and ry["chg_20d"] > 0.10 else 1 if ry and ry["chg_20d"] < -0.10 else 0)
        self._macro, self._macro_t = out, time.time()
        return out

    def _yahoo(self, tf_name, n):
        try:
            import yfinance as yf
            iv = {"M5": "5m", "M15": "15m", "M30": "30m", "H1": "60m", "H4": "60m", "D1": "1d"}.get(tf_name, "60m")
            per = "60d" if iv.endswith("m") else "2y"
            d = yf.download("DX-Y.NYB", period=per, interval=iv, progress=False)
            if d is None or d.empty:
                return None
            self.mode = "Yahoo Finance (DX-Y.NYB)"
            c = d["Close"]
            c = c.iloc[:, 0] if isinstance(c, pd.DataFrame) else c
            return c.tail(n)
        except Exception:
            return None

    def summary(self, gold_close: pd.Series = None):
        s = self.series("H1", 300)
        if s is None or len(s) < 60:
            return {"dxy": 0, "dxy_chg24": 0, "dxy_trend": 0, "dxy_corr": 0, "dxy_bias": 0, "dxy_mode": self.mode}
        ef, es = s.ewm(span=20).mean().iloc[-1], s.ewm(span=50).mean().iloc[-1]
        gap = (ef - es) / es * 100
        trend = 1 if gap > 0.03 else (-1 if gap < -0.03 else 0)
        corr = 0.0
        if gold_close is not None and len(gold_close) > 60:
            j = pd.concat([s.pct_change(), gold_close.pct_change()], axis=1, join="inner").dropna().tail(60)
            if len(j) > 20:
                corr = float(j.corr().iloc[0, 1])
        bias = -trend if corr < -0.2 else 0
        chg = (s.iloc[-1] / s.iloc[-25] - 1) * 100 if len(s) > 25 else 0
        m = self.macro()
        ry = m.get("DFII10") or {}
        return {"dxy": round(float(s.iloc[-1]), 3), "dxy_chg24": round(float(chg), 3), "dxy_trend": trend,
                "dxy_corr": round(corr, 2), "dxy_bias": bias, "dxy_mode": self.mode,
                "real_yield": ry.get("last", 0), "real_yield_chg20d": round(ry.get("chg_20d", 0), 3),
                "ry_bias": m.get("ry_bias", 0)}
