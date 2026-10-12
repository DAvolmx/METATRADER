# -*- coding: utf-8 -*-
"""
GOLD MASTER — Intelligence Layer v4.0
======================================
Módulos:
  1. NewsCalendar    — calendario económico (ForexFactory JSON) + cuenta regresiva
                       + exporta news_calendar.csv (UTC) para CGMNewsFilter del EA
  2. NewsSentiment   — titulares RSS → FinBERT (si está instalado) o léxico propio,
                       con mapeo "qué significa para el ORO" y decaimiento temporal
  3. COTEngine       — CFTC Disaggregated (Managed Money) para Gold COMEX 088691,
                       COT Index 3 años (percentil) → posicionamiento de fondos
  4. OrderFlowEngine — "radar de ballenas": delta por tick-rule, delta acumulado,
                       VPIN (Easley/López de Prado/O'Hara, BVC), Kyle lambda,
                       velas de absorción (volumen z>3), Volume Profile (POC/VAH/VAL),
                       VWAP diario con bandas σ
  5. StatsEngine     — Hurst exponent (tendencia vs reversión), vol realizada,
                       Kelly fraccional
  6. Composite       — score compuesto -1..+1 + multiplicador de riesgo
  7. Bridge          — comunicación bidireccional con el EA vía Common\\Files\\GoldMaster:
                       intel.txt (Py→EA), commands.csv (Py→EA), ea_state.txt (EA→Py)

Nota honesta: XAUUSD en MT5 es CFD OTC — no existe cinta real de "ballenas".
Aquí se usan PROXIES estadísticos del flujo. Para footprint real hace falta
feed de futuros GC (CME) vía Rithmic/dxFeed/Databento; hay un hook en
OrderFlowEngine.external_feed() para enchufarlo.
"""
import os, math, time, json, threading, logging, datetime as dt
import xml.etree.ElementTree as ET
import numpy as np
import pandas as pd

log = logging.getLogger("GM_INTEL")

try:
    import requests
    HAS_REQ = True
except ImportError:
    HAS_REQ = False

try:
    import MetaTrader5 as mt5
    HAS_MT5 = True
except ImportError:
    HAS_MT5 = False

_FINBERT = None
def _get_finbert():
    # FinBERT necesita torch/torchvision; en este PC Windows (Control de aplicaciones) bloquea sus DLL y
    # muestra la ventana "Imagen incorrecta". Sólo se intenta si GM_USE_FINBERT=1; si no, se usa el léxico.
    if os.getenv("GM_USE_FINBERT") != "1":
        return None
    """Carga FinBERT perezosamente (pip install transformers torch)."""
    global _FINBERT
    if _FINBERT is None:
        try:
            from transformers import pipeline
            _FINBERT = pipeline("text-classification", model="ProsusAI/finbert", top_k=None)
            log.info("FinBERT cargado")
        except Exception as e:
            log.warning(f"FinBERT no disponible ({e}); usando léxico")
            _FINBERT = False
    return _FINBERT

GM_DIR = os.path.join(os.environ.get("APPDATA", ""), "MetaQuotes", "Terminal",
                      "Common", "Files", "GoldMaster")
os.makedirs(GM_DIR, exist_ok=True)
UA = {"User-Agent": "Mozilla/5.0 GoldMaster/4.0"}
UTC = dt.timezone.utc

def _now():
    return dt.datetime.now(UTC)

# ══════════════════════════════════════════════════════════════════
# 1. CALENDARIO + CUENTA REGRESIVA
# ══════════════════════════════════════════════════════════════════
class NewsCalendar:
    URLS = ["https://nfs.faireconomy.media/ff_calendar_thisweek.json",
            "https://nfs.faireconomy.media/ff_calendar_nextweek.json"]
    IMPACT = {"High": 3, "Medium": 2, "Low": 1, "Holiday": 0}
    CURRENCIES = {"USD", "XAU", "CNY", "EUR"}

    def __init__(self, refresh_s=3 * 3600):
        self.events, self.last, self.refresh_s = [], 0, refresh_s

    def update(self, force=False):
        if not HAS_REQ or (not force and time.time() - self.last < self.refresh_s):
            return
        evs = []
        for u in self.URLS:
            try:
                r = requests.get(u, headers=UA, timeout=10)
                if r.status_code != 200:
                    continue
                for e in r.json():
                    cur = e.get("country", "")
                    if cur not in self.CURRENCIES:
                        continue
                    t = pd.Timestamp(e["date"]).tz_convert("UTC").to_pydatetime()
                    evs.append({"time": t, "title": e.get("title", ""), "currency": cur,
                                "impact": self.IMPACT.get(e.get("impact", "Low"), 1),
                                "forecast": e.get("forecast", ""), "previous": e.get("previous", "")})
            except Exception as ex:
                log.warning(f"Calendario {u}: {ex}")
        if evs:
            self.events = sorted(evs, key=lambda x: x["time"])
            self.last = time.time()
            self.export_csv()

    def export_csv(self):
        """Formato que lee CGMNewsFilter: YYYY.MM.DD,HH:MM,nombre,moneda,impacto (UTC)"""
        p = os.path.join(GM_DIR, "news_calendar.csv")
        with open(p, "w", encoding="ascii", errors="ignore") as f:
            for e in self.events:
                name = e["title"].replace(",", " ")
                f.write(f"{e['time']:%Y.%m.%d},{e['time']:%H:%M},{name},{e['currency']},{e['impact']}\n")

    def upcoming(self, n=8, min_impact=2):
        now = _now()
        return [e for e in self.events if e["time"] >= now - dt.timedelta(minutes=5)
                and e["impact"] >= min_impact][:n]

    def next_event(self, min_impact=3):
        up = self.upcoming(1, min_impact)
        if not up:
            return None, None
        return up[0], (up[0]["time"] - _now()).total_seconds()

    def in_freeze(self, freeze_min=30, min_impact=3):
        now = _now()
        return any(abs((e["time"] - now).total_seconds()) <= freeze_min * 60
                   for e in self.events if e["impact"] >= min_impact and e["currency"] == "USD")

# ══════════════════════════════════════════════════════════════════
# 2. SENTIMIENTO DE NOTICIAS (orientado a ORO)
# ══════════════════════════════════════════════════════════════════
class NewsSentiment:
    FEEDS = [
        "https://news.google.com/rss/search?q=gold+price+OR+XAUUSD&hl=en-US&gl=US&ceid=US:en",
        "https://news.google.com/rss/search?q=Federal+Reserve+OR+Treasury+yields+OR+US+dollar&hl=en-US&gl=US&ceid=US:en",
        "https://www.fxstreet.com/rss/news",
        "https://www.kitco.com/rss/KitcoNews.xml",
    ]
    # Léxico de impacto sobre el ORO (no sobre el activo mencionado)
    GOLD_BULL = {"rate cut": 1.0, "cuts rates": 1.0, "dovish": 0.9, "safe haven": 0.8, "safe-haven": 0.8,
                 "geopolitical": 0.6, "war": 0.6, "conflict": 0.5, "sanctions": 0.4, "recession": 0.6,
                 "weaker dollar": 0.9, "dollar falls": 0.8, "dollar slips": 0.7, "yields fall": 0.8,
                 "yields drop": 0.8, "central bank buying": 1.0, "central banks buy": 1.0, "etf inflows": 0.8,
                 "record high": 0.6, "all-time high": 0.6, "rallies": 0.6, "surges": 0.7, "jumps": 0.5,
                 "inflation rises": 0.5, "hotter inflation": 0.3, "tariff": 0.4, "uncertainty": 0.4,
                 "soft jobs": 0.7, "jobless claims rise": 0.6, "slowdown": 0.5, "debt ceiling": 0.5}
    GOLD_BEAR = {"rate hike": 1.0, "hawkish": 0.9, "higher for longer": 0.9, "strong dollar": 0.9,
                 "dollar rises": 0.8, "dollar gains": 0.8, "yields rise": 0.8, "yields climb": 0.8,
                 "strong jobs": 0.7, "beats expectations": 0.3, "ceasefire": 0.6, "peace deal": 0.6,
                 "risk-on": 0.5, "etf outflows": 0.8, "profit-taking": 0.5, "slumps": 0.7, "tumbles": 0.7,
                 "falls": 0.4, "drops": 0.4, "slides": 0.5, "sell-off": 0.6, "cooling inflation": 0.4}

    def __init__(self, refresh_s=600, half_life_h=6.0):
        self.items, self.last, self.refresh_s, self.hl = [], 0, refresh_s, half_life_h

    def _fetch(self):
        out = []
        for u in self.FEEDS:
            try:
                r = requests.get(u, headers=UA, timeout=10)
                root = ET.fromstring(r.content)
                for it in root.iter("item"):
                    title = (it.findtext("title") or "").strip()
                    pub = it.findtext("pubDate")
                    try:
                        t = pd.Timestamp(pub).tz_convert("UTC").to_pydatetime() if pub else _now()
                    except Exception:
                        t = _now()
                    if title:
                        out.append({"title": title, "time": t, "link": it.findtext("link") or "",
                                    "source": u.split("/")[2]})
            except Exception as ex:
                log.debug(f"RSS {u}: {ex}")
        seen, uniq = set(), []
        for x in sorted(out, key=lambda z: z["time"], reverse=True):
            k = x["title"][:70].lower()
            if k not in seen:
                seen.add(k); uniq.append(x)
        return uniq[:80]

    def _lex(self, t):
        t = t.lower()
        b = sum(w for k, w in self.GOLD_BULL.items() if k in t)
        s = sum(w for k, w in self.GOLD_BEAR.items() if k in t)
        return float(np.tanh(b - s))

    def _score(self, titles):
        lex = [self._lex(t) for t in titles]
        fb = _get_finbert()
        if not fb:
            return lex
        res = fb(titles, truncation=True)
        out = []
        for t, l, r in zip(titles, lex, res):
            d = {x["label"].lower(): x["score"] for x in r}
            pol = d.get("positive", 0) - d.get("negative", 0)
            tl = t.lower()
            if "gold" in tl or "bullion" in tl or "xau" in tl:
                g = pol                           # tono sobre el oro = tono sobre el oro
            elif any(k in tl for k in ("dollar", "yield", "treasur", "fed ", "powell", "rates")):
                g = -pol * 0.6                    # bueno para USD/yields = malo para oro
            else:
                g = pol * 0.2
            out.append(float(np.clip(0.5 * g + 0.5 * l if l else g, -1, 1)))
        return out

    def update(self, force=False):
        if not HAS_REQ or (not force and time.time() - self.last < self.refresh_s):
            return
        items = self._fetch()
        if not items:
            return
        for it, s in zip(items, self._score([i["title"] for i in items])):
            it["score"] = s
        self.items, self.last = items, time.time()

    def aggregate(self):
        """Promedio ponderado con decaimiento exponencial (vida media hl horas)."""
        if not self.items:
            return 0.0, 0
        now = _now()
        w = np.array([0.5 ** (max((now - i["time"]).total_seconds(), 0) / 3600 / self.hl) for i in self.items])
        s = np.array([i["score"] for i in self.items])
        rel = np.abs(s) > 0.05
        if w[rel].sum() == 0:
            return 0.0, len(self.items)
        return float((w[rel] * s[rel]).sum() / w[rel].sum()), int(rel.sum())

# ══════════════════════════════════════════════════════════════════
# 3. COT — posicionamiento de fondos (Managed Money) en COMEX Gold
# ══════════════════════════════════════════════════════════════════
class COTEngine:
    URL = ("https://publicreporting.cftc.gov/resource/72hh-3qpy.json?"
           "cftc_contract_market_code=088691&$order=report_date_as_yyyy_mm_dd%20DESC&$limit=160")

    def __init__(self):
        self.df, self.last = pd.DataFrame(), 0

    def update(self, force=False):
        if not HAS_REQ or (not force and time.time() - self.last < 12 * 3600):
            return
        try:
            d = pd.DataFrame(requests.get(self.URL, headers=UA, timeout=15).json())
            d["date"] = pd.to_datetime(d["report_date_as_yyyy_mm_dd"])
            for c in ("m_money_positions_long_all", "m_money_positions_short_all",
                      "prod_merc_positions_long", "prod_merc_positions_short", "open_interest_all"):
                d[c] = pd.to_numeric(d.get(c), errors="coerce")
            d["mm_net"] = d["m_money_positions_long_all"] - d["m_money_positions_short_all"]
            d["comm_net"] = d["prod_merc_positions_long"] - d["prod_merc_positions_short"]
            self.df, self.last = d.sort_values("date").reset_index(drop=True), time.time()
        except Exception as ex:
            log.warning(f"COT: {ex}")

    def summary(self):
        if self.df.empty:
            return {"cot_index": 50.0, "mm_net": 0, "mm_chg": 0, "bias": 0.0, "date": "-"}
        d = self.df.tail(156)                       # ~3 años semanales
        lo, hi, cur = d.mm_net.min(), d.mm_net.max(), d.mm_net.iloc[-1]
        idx = 100 * (cur - lo) / (hi - lo) if hi > lo else 50
        chg = cur - d.mm_net.iloc[-2] if len(d) > 1 else 0
        # Extremos = contrarian (fondos saturados), zona media = seguir el cambio semanal
        if idx > 85:   bias = -0.5
        elif idx < 15: bias = 0.5
        else:          bias = float(np.tanh(chg / (d.mm_net.diff().std() + 1e-9)) * 0.5)
        return {"cot_index": round(float(idx), 1), "mm_net": int(cur), "mm_chg": int(chg),
                "bias": round(bias, 3), "date": f"{d.date.iloc[-1]:%Y-%m-%d}"}

# ══════════════════════════════════════════════════════════════════
# 4. ORDER FLOW — "radar de ballenas"
# ══════════════════════════════════════════════════════════════════
class OrderFlowEngine:
    def __init__(self, symbol="XAUUSD"):
        self.symbol = symbol
        self.state = {}
        self.whales = []

    def external_feed(self):
        """Hook: aquí conectar time&sales real de GC (Rithmic/dxFeed/Databento)."""
        return None

    def _m1(self, n=1440):
        r = mt5.copy_rates_from_pos(self.symbol, mt5.TIMEFRAME_M1, 0, n)
        if r is None or len(r) == 0:
            return pd.DataFrame()
        d = pd.DataFrame(r); d["time"] = pd.to_datetime(d.time, unit="s", utc=True)
        return d

    def _ticks(self, minutes=60):
        t0 = dt.datetime.now(UTC) - dt.timedelta(minutes=minutes)
        tk = mt5.copy_ticks_from(self.symbol, t0.replace(tzinfo=None), 200000, mt5.COPY_TICKS_ALL)
        if tk is None or len(tk) == 0:
            return pd.DataFrame()
        d = pd.DataFrame(tk); d["time"] = pd.to_datetime(d.time_msc, unit="ms", utc=True)
        return d

    @staticmethod
    def vpin_bvc(m1, buckets=50):
        """VPIN con Bulk Volume Classification: V_buy = V·Φ(Δp/σ)."""
        dp = m1.close.diff().fillna(0)
        sig = dp.rolling(100, min_periods=20).std().replace(0, np.nan).bfill().fillna(1e-9)
        z = (dp / sig).clip(-6, 6).values
        phi = 0.5 * (1 + np.vectorize(math.erf)(z / math.sqrt(2)))
        v = m1.tick_volume.values.astype(float)
        vb, vs = v * phi, v * (1 - phi)
        n = min(buckets, len(v))
        oi = np.abs(vb[-n:] - vs[-n:]).sum() / max(v[-n:].sum(), 1)
        return float(oi), vb, vs

    @staticmethod
    def kyle_lambda(m1, n=240):
        d = m1.tail(n)
        dp = d.close.diff().dropna().values
        sv = (np.sign(d.close - d.open) * d.tick_volume).iloc[1:].values
        if len(dp) < 20 or np.var(sv) == 0:
            return 0.0
        return float(np.cov(dp, sv)[0, 1] / np.var(sv))

    @staticmethod
    def volume_profile(m1, bins=60, va=0.70):
        if m1.empty:
            return None
        px = (m1.high + m1.low + m1.close) / 3
        hist, edges = np.histogram(px, bins=bins, weights=m1.tick_volume)
        mids = (edges[:-1] + edges[1:]) / 2
        poc_i = int(hist.argmax())
        tot, acc, lo, hi = hist.sum(), hist[poc_i], poc_i, poc_i
        while acc < va * tot and (lo > 0 or hi < len(hist) - 1):
            nl = hist[lo - 1] if lo > 0 else -1
            nh = hist[hi + 1] if hi < len(hist) - 1 else -1
            if nh >= nl: hi += 1; acc += hist[hi]
            else:        lo -= 1; acc += hist[lo]
        return {"poc": float(mids[poc_i]), "vah": float(mids[hi]), "val": float(mids[lo]),
                "mids": mids.tolist(), "hist": hist.tolist()}

    def update(self):
        if not HAS_MT5:
            return
        m1 = self._m1()
        if m1.empty:
            return
        # ─ Delta por tick-rule (última hora) ─
        tk = self._ticks(60)
        delta_z, cum_delta = 0.0, []
        if not tk.empty:
            mid = (tk.bid + tk.ask) / 2
            sgn = np.sign(mid.diff()).replace(0, np.nan).ffill().fillna(0)
            vol = tk.volume_real if "volume_real" in tk and tk.volume_real.sum() > 0 else pd.Series(1.0, index=tk.index)
            tk["d"] = sgn * vol
            per_min = tk.set_index("time").d.resample("1min").sum()
            cum_delta = per_min.cumsum().tail(60).tolist()
            if per_min.std() > 0:
                delta_z = float((per_min.tail(15).sum() / 15 - per_min.mean()) / per_min.std())
        # ─ VPIN / Kyle ─
        vpin, vb, vs = self.vpin_bvc(m1)
        lam = self.kyle_lambda(m1)
        # ─ Velas de absorción / huella institucional (vol z>3) ─
        v = m1.tick_volume.astype(float)
        vz = (v - v.rolling(120, min_periods=30).mean()) / v.rolling(120, min_periods=30).std()
        wh = []
        for i in np.where(vz.fillna(0).values > 3)[0][-15:]:
            r = m1.iloc[i]
            body = r.close - r.open
            rng = max(r.high - r.low, 1e-9)
            # cuerpo pequeño + volumen enorme = absorción (la ballena frena el precio)
            kind = "ABSORCIÓN" if abs(body) / rng < 0.3 else ("COMPRA" if body > 0 else "VENTA")
            side = 1 if body > 0 else -1
            if kind == "ABSORCIÓN":
                side = 1 if (r.close - r.low) / rng > 0.5 else -1
            wh.append({"time": f"{r.time:%H:%M}", "price": round(float(r.close), 2), "kind": kind,
                       "side": side, "z": round(float(vz.iloc[i]), 1)})
        self.whales = wh[::-1]
        # ─ Volume profile (sesión) + VWAP ─
        today = m1[m1.time.dt.date == m1.time.iloc[-1].date()]
        vp = self.volume_profile(today if len(today) > 30 else m1.tail(300))
        tp = (today.high + today.low + today.close) / 3 if len(today) else (m1.high + m1.low + m1.close) / 3
        w = today.tick_volume if len(today) else m1.tick_volume
        vwap = float((tp * w).sum() / max(w.sum(), 1))
        vstd = float(np.sqrt(((tp - vwap) ** 2 * w).sum() / max(w.sum(), 1)))
        last = float(m1.close.iloc[-1])
        whale_bias = float(np.tanh(sum(x["side"] * x["z"] / 3 for x in wh[-5:]) / 3)) if wh else 0.0
        flow_bias = float(np.clip(0.6 * np.tanh(delta_z / 2) + 0.4 * whale_bias, -1, 1))
        self.state = {"delta_z": round(delta_z, 2), "cum_delta": cum_delta, "vpin": round(vpin, 3),
                      "kyle_lambda": lam, "whale_bias": round(whale_bias, 3), "flow_bias": round(flow_bias, 3),
                      "vwap": round(vwap, 2), "vwap_std": round(vstd, 2), "price": last,
                      "vwap_z": round((last - vwap) / vstd, 2) if vstd > 0 else 0.0, "profile": vp}

# ══════════════════════════════════════════════════════════════════
# 5. ESTADÍSTICA
# ══════════════════════════════════════════════════════════════════
def hurst(series, max_lag=100):
    """H>0.55 tendencia (seguir breakout), H<0.45 reversión a la media (fade)."""
    x = np.log(np.asarray(series, dtype=float))
    lags = range(2, min(max_lag, len(x) // 2))
    tau = [np.std(x[l:] - x[:-l]) for l in lags]
    if len(tau) < 5 or min(tau) <= 0:
        return 0.5
    return float(np.polyfit(np.log(list(lags)), np.log(tau), 1)[0])

def kelly_fraction(win_rate, rr, frac=0.25):
    """Kelly fraccional (¼ Kelly por defecto — Thorp)."""
    if rr <= 0:
        return 0.0
    k = win_rate - (1 - win_rate) / rr
    return max(0.0, k * frac)

# ══════════════════════════════════════════════════════════════════
# 6+7. MOTOR PRINCIPAL + BRIDGE
# ══════════════════════════════════════════════════════════════════
from gm_dxy import DXYEngine


OVERRIDE_FILE = os.path.join(GM_DIR, "override.json")
def override_on():
    try:
        with open(OVERRIDE_FILE) as fh: return bool(json.load(fh).get("on"))
    except Exception: return False
def set_override(on):
    with open(OVERRIDE_FILE, "w") as fh: json.dump({"on": bool(on), "ts": int(time.time())}, fh)
    log.warning(f"MODO SIN FILTROS {'ACTIVADO' if on else 'desactivado'}")

class IntelEngine:
    W = {"sent": 0.20, "cot": 0.10, "flow": 0.30, "struct": 0.20, "dxy": 0.20}

    def __init__(self, symbol="XAUUSD", freeze_min=30):
        self.symbol, self.freeze_min = symbol, freeze_min
        self.cal, self.sent, self.cot = NewsCalendar(), NewsSentiment(), COTEngine()
        self.flow = OrderFlowEngine(symbol)
        self.dxy = DXYEngine()
        try:
            from gm_quant import QuantEngine; self.quant = QuantEngine(symbol)
        except Exception as ex:
            log.warning(f"QuantEngine no disponible: {ex}"); self.quant = None
        self.snapshot, self.cmd_id = {}, int(time.time())
        self.lock = threading.Lock()
        self._stop = False

    # ─── Cálculo ─────────────────────────────────────────
    def compute(self):
        for f in (self.cal.update, self.sent.update, self.cot.update, self.flow.update):
            try: f()
            except Exception as ex: log.warning(f"{f.__qualname__}: {ex}")
        s_score, s_n = self.sent.aggregate()
        cot = self.cot.summary()
        fl = self.flow.state or {}
        h = 0.5
        gold_h1 = None
        if HAS_MT5:
            r = mt5.copy_rates_from_pos(self.symbol, mt5.TIMEFRAME_M15, 0, 400)
            if r is not None and len(r) > 50:
                h = hurst(pd.DataFrame(r).close.values)
            g = mt5.copy_rates_from_pos(self.symbol, mt5.TIMEFRAME_H1, 0, 300)
            if g is not None and len(g):
                gd = pd.DataFrame(g); gold_h1 = pd.Series(gd.close.values, index=pd.to_datetime(gd.time, unit='s'))
        try:
            dx = self.dxy.summary(gold_h1)
        except Exception as ex:
            log.warning(f'DXY: {ex}'); dx = {'dxy': 0, 'dxy_chg24': 0, 'dxy_trend': 0, 'dxy_corr': 0, 'dxy_bias': 0, 'dxy_mode': 'error'}
        # Estructura: en tendencia (H>0.5) seguir lado del VWAP; en reversión, fade de extremos
        vz = fl.get("vwap_z", 0.0)
        struct = float(np.tanh(vz / 2)) if h >= 0.5 else float(-np.tanh(vz / 2) * (abs(vz) > 1.5))
        comp = (self.W["sent"] * s_score + self.W["cot"] * cot["bias"] +
                self.W["flow"] * fl.get("flow_bias", 0) + self.W["struct"] * struct + self.W["dxy"] * (0.7 * dx["dxy_bias"] + 0.3 * dx.get("ry_bias", 0)))
        nxt, secs = self.cal.next_event(3)
        freeze = self.cal.in_freeze(self.freeze_min, 3)
        vpin = fl.get("vpin", 0)
        risk = 0.0 if freeze else (0.5 if vpin > 0.6 else (0.75 if secs is not None and secs < 7200 else 1.0))
        snap = {"ts": int(time.time()), "sentiment": round(s_score, 3), "sent_n": s_n,
                "cot_index": cot["cot_index"], "cot_bias": cot["bias"], "cot_mm_net": cot["mm_net"],
                "cot_mm_chg": cot["mm_chg"], "cot_date": cot["date"],
                "delta_z": fl.get("delta_z", 0), "vpin": vpin, "whale_bias": fl.get("whale_bias", 0),
                "flow_bias": fl.get("flow_bias", 0), "vwap": fl.get("vwap", 0), "vwap_z": vz,
                "poc": (fl.get("profile") or {}).get("poc", 0), "vah": (fl.get("profile") or {}).get("vah", 0),
                "val": (fl.get("profile") or {}).get("val", 0), "hurst": round(h, 3),
                "regime": "TREND" if h > 0.55 else ("MEANREV" if h < 0.45 else "RANDOM"),
                "composite": round(float(np.clip(comp, -1, 1)), 3),
                "block_trading": int(freeze), "risk_mult": risk,
                "next_news": nxt["title"] if nxt else "", "next_news_secs": int(secs) if secs is not None else -1,
                **dx}
        mic = getattr(self, "micro", None)
        if mic and mic.state and time.time()-mic.state.get("micro_ts", 0) <= 5:
            snap.update({k: v for k, v in mic.state.items() if k in ("dxy_live", "dxy_z60", "dxy_shock", "dxy_beta", "dxy_corr_live",
                         "dxy_lead_s", "gold_exp_move", "micro_bias", "micro_trend", "ofi_60", "spread_z", "tick_z", "g_z60")})
            if mic.state.get("spread_z", 0) > 4: snap["risk_mult"] = min(snap["risk_mult"], 0.5)
            if not mic.state.get("market_valid", 0): snap["block_trading"] = 1
        if self.quant:
            try:
                q = self.quant.compute(); snap.update(q)
                snap["risk_mult"] = round(min(snap["risk_mult"], q.get("risk_mult_q", 1.0)), 2)
                if q.get("gov_block"): snap["block_trading"] = 1
                snap["composite"] = round(float(np.clip(snap["composite"] + 0.15*q.get("macro_bias", 0), -1, 1)), 3)
            except Exception as ex:
                log.warning(f"quant: {ex}")
        try:
            with open(os.path.join(GM_DIR, "autonomous.json")) as fh: snap["auto_trade"] = int(bool(json.load(fh).get("on")))
        except Exception:
            snap["auto_trade"] = 0
        if override_on():
            # Modo sin filtros (botón del dashboard): no se bloquea ni se reduce el lote por filtros externos.
            snap.update(block_trading=0, gov_block=0, dxy_shock=0, risk_mult=1.0, override=1)
        else:
            snap["override"] = 0
        snap["symbol"] = self.symbol
        # A stale feed cannot be unblocked by the UI's optional strategy override.
        if mic and (time.time()-mic.state.get("micro_ts", 0)>5 or not mic.state.get("market_valid", 0)):
            snap.update(block_trading=1, risk_mult=0.0, auto_trade=0)
        with self.lock:
            self.snapshot = snap
        self.write_intel(snap)
        return snap

    # ─── Bridge ──────────────────────────────────────────
    def write_intel(self, snap):
        """key=value (fácil de parsear en MQL5). Escritura atómica vía archivo temporal."""
        p, tmp = os.path.join(GM_DIR, "intel.txt"), os.path.join(GM_DIR, "intel.tmp")
        with open(tmp, "w", encoding="ascii", errors="ignore") as f:
            for k, v in snap.items():
                f.write(f"{k}={str(v).replace('=', ' ').replace(chr(10), ' ')}\n")
        os.replace(tmp, p)
        with open(os.path.join(GM_DIR, "intel.json"), "w") as f:
            json.dump(snap, f)

    def send_command(self, cmd, a1="", a2=""):
        """Comandos: PAUSE, RESUME, CLOSE_ALL, CANCEL_PENDING, SET_RISK <pct>, SET_MINSCORE <n>"""
        self.cmd_id += 1
        with open(os.path.join(GM_DIR, "commands.csv"), "a", encoding="ascii") as f:
            f.write(f"{self.cmd_id},{cmd},{a1},{a2}\n")
        return self.cmd_id

    @staticmethod
    def read_ea_state():
        p = os.path.join(GM_DIR, "ea_state.txt")
        st = {}
        try:
            with open(p, encoding="ascii", errors="ignore") as f:
                for line in f:
                    if "=" in line:
                        k, v = line.strip().split("=", 1); st[k] = v
            st["age_s"] = int(time.time()) - int(st.get("ts", 0))
            st["alive"] = st["age_s"] < 90
        except Exception:
            st = {"alive": False, "age_s": -1}
        return st

    def follow(self, every_s=5):
        """Modo seguidor: lee intel.json escrito por gm_service.py (sin duplicar cálculos ni escrituras)."""
        def loop():
            p = os.path.join(GM_DIR, "intel.json")
            while not self._stop:
                try:
                    with open(p) as fh: snap = json.load(fh)
                    with self.lock: self.snapshot = snap
                except Exception: pass
                time.sleep(every_s)
        threading.Thread(target=loop, daemon=True).start()

    # ─── Loop en background ──────────────────────────────
    def start(self, every_s=20):
        if getattr(self, '_started', False):
            return
        self._started = True
        def loop():
            while not self._stop:
                try: self.compute()
                except Exception as ex: log.error(f"Intel loop: {ex}")
                time.sleep(every_s)
        threading.Thread(target=loop, daemon=True).start()

# ══════════════════════════════════════════════════════════════════
# PANEL DASH (se registra desde el dashboard)
# ══════════════════════════════════════════════════════════════════
def register_dash(app, engine: IntelEngine):
    from dash import dcc, html, Input, Output, State, ctx
    import dash_bootstrap_components as dbc
    import plotly.graph_objects as go

    card = {"background": "#1a1a2e", "border": "1px solid #333"}

    def col(v):
        return "#00e676" if v > 0.15 else ("#ff5252" if v < -0.15 else "#ffd740")

    layout = html.Div([
        dbc.Row([
            dbc.Col(dbc.Card([dbc.CardHeader("⏱ Próxima noticia alto impacto"),
                              dbc.CardBody(html.Div(id="gi-countdown"))], style=card), md=3),
            dbc.Col(dbc.Card([dbc.CardHeader("📰 Sentimiento (impacto ORO)"),
                              dbc.CardBody(dcc.Graph(id="gi-sent-gauge", config={"displayModeBar": False},
                                                     style={"height": "170px"}))], style=card), md=3),
            dbc.Col(dbc.Card([dbc.CardHeader("🐋 Radar de ballenas / Order Flow"),
                              dbc.CardBody(html.Div(id="gi-flow"))], style=card), md=3),
            dbc.Col(dbc.Card([dbc.CardHeader("🔗 Bridge MT5 ⇄ Dashboard"),
                              dbc.CardBody([html.Div(id="gi-bridge"),
                                            dbc.ButtonGroup([
                                                dbc.Button("⏸ Pausar", id="gi-pause", color="warning", size="sm"),
                                                dbc.Button("▶ Reanudar", id="gi-resume", color="success", size="sm"),
                                                dbc.Button("✖ Cerrar todo", id="gi-close", color="danger", size="sm"),
                                                dbc.Button("🗑 Pendientes", id="gi-cancel", color="secondary", size="sm"),
                                                dbc.Button("⟳ Refrescar MT5", id="gi-refresh", color="info", size="sm", title="Recalcula todos los gráficos e indicadores de MT5"),
                                                dbc.Button("🔓 Sin filtros: OFF", id="gi-override", color="dark", size="sm", outline=True,
                                                           title="Ignora bloqueos de noticias, riesgo de cartera, régimen y DXY shock. El SL y la gestión del Guardian siguen activos."),
                                            ], className="mt-2"),
                                            html.Div(id="gi-cmd-ack", className="small mt-1")])], style=card), md=3),
        ], className="mb-2"),
        dbc.Row([
            dbc.Col(dbc.Card([dbc.CardHeader("📅 Calendario (USD/XAU)"),
                              dbc.CardBody(html.Div(id="gi-calendar"))], style=card), md=4),
            dbc.Col(dbc.Card([dbc.CardHeader("📊 Volume Profile + Delta acumulado"),
                              dbc.CardBody(dcc.Graph(id="gi-profile", config={"displayModeBar": False},
                                                     style={"height": "260px"}))], style=card), md=4),
            dbc.Col(dbc.Card([dbc.CardHeader("🗞 Titulares"),
                              dbc.CardBody(html.Div(id="gi-news", style={"maxHeight": "260px", "overflowY": "auto"}))],
                             style=card), md=4),
        ], className="mb-2"),
        dcc.Interval(id="gi-tick", interval=1000),
        dcc.Interval(id="gi-slow", interval=20_000),
    ])

    @app.callback(Output("gi-countdown", "children"), Input("gi-tick", "n_intervals"))
    def _cd(_):
        e, secs = engine.cal.next_event(3)
        if not e:
            return html.Div("Sin eventos de alto impacto", className="text-muted")
        s = int(secs)
        neg = s < 0
        s = abs(s)
        txt = f"{s // 86400}d {s % 86400 // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}" if s >= 86400 \
            else f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"
        color = "#ff5252" if s < 1800 or neg else ("#ffd740" if s < 7200 else "#00e676")
        return [html.H2(("−" if neg else "") + txt, style={"color": color, "fontFamily": "monospace"}),
                html.Div(f"{e['currency']} · {e['title']}", className="fw-bold"),
                html.Div(f"{e['time']:%a %d %H:%M} UTC · prev {e['previous']} · fcst {e['forecast']}",
                         className="small text-muted"),
                html.Div("🔒 EA BLOQUEADO (freeze)" if engine.snapshot.get("block_trading") else "",
                         style={"color": "#ff5252"})]

    @app.callback(Output("gi-sent-gauge", "figure"), Output("gi-flow", "children"),
                  Output("gi-bridge", "children"), Output("gi-calendar", "children"),
                  Output("gi-profile", "figure"), Output("gi-news", "children"),
                  Input("gi-slow", "n_intervals"))
    def _slow(_):
        s = engine.snapshot or {}
        g = go.Figure(go.Indicator(mode="gauge+number", value=s.get("sentiment", 0) * 100,
                                   number={"suffix": "", "font": {"size": 28}},
                                   gauge={"axis": {"range": [-100, 100]}, "bar": {"color": col(s.get("sentiment", 0))},
                                          "steps": [{"range": [-100, -15], "color": "#3a1212"},
                                                    {"range": [15, 100], "color": "#123a1a"}]}))
        g.update_layout(margin=dict(l=10, r=10, t=10, b=0), paper_bgcolor="rgba(0,0,0,0)", font_color="#ddd")
        comp = s.get("composite", 0)
        flow = [html.H4(f"Compuesto {comp:+.2f}", style={"color": col(comp)}),
                html.Div(f"Δ z-score 15m: {s.get('delta_z', 0):+.2f}"),
                html.Div(f"VPIN (toxicidad): {s.get('vpin', 0):.2f}"
                         + ("  ⚠️" if s.get("vpin", 0) > 0.6 else "")),
                html.Div(f"COT idx: {s.get('cot_index', 50)} · MM Δ {s.get('cot_mm_chg', 0):+,}"),
                html.Div(f"Hurst {s.get('hurst', 0.5)} → {s.get('regime', '-')}"),
                html.Div(f"VWAP {s.get('vwap', 0)} (z {s.get('vwap_z', 0):+.2f}) · POC {s.get('poc', 0):.2f}"),
                html.Hr(className="my-1"),
                *[html.Div(f"{w['time']} {w['kind']} @{w['price']} (z{w['z']})",
                           style={"color": "#00e676" if w["side"] > 0 else "#ff5252", "fontSize": "12px"})
                  for w in engine.flow.whales[:5]]]
        st = engine.read_ea_state()
        bridge = [html.Div(("🟢 EA conectado" if st.get("alive") else "🔴 EA sin señal") +
                           f" (hace {st.get('age_s', '?')}s)"),
                  html.Div(f"Estado: {st.get('status', '-')} · Pos: {st.get('positions', '-')} · "
                           f"Pend: {st.get('pending', '-')}", className="small"),
                  html.Div(f"Riesgo x{s.get('risk_mult', 1)} · último cmd #{st.get('last_cmd', '-')}",
                           className="small text-muted")]
        cal = [html.Div([html.Span(f"{e['time']:%a %H:%M} ", className="text-muted"),
                         html.Span("🔴" if e["impact"] == 3 else "🟠"),
                         html.Span(f" {e['currency']} {e['title']}")], style={"fontSize": "12px"})
               for e in engine.cal.upcoming(12)]
        vp = (engine.flow.state or {}).get("profile")
        fig = go.Figure()
        if vp:
            fig.add_trace(go.Bar(x=vp["hist"], y=vp["mids"], orientation="h", marker_color="#546e7a",
                                 name="Vol", xaxis="x"))
            for k, c in (("poc", "#ffd740"), ("vah", "#00e676"), ("val", "#ff5252")):
                fig.add_hline(y=vp[k], line_color=c, line_dash="dot", annotation_text=k.upper())
        cd = (engine.flow.state or {}).get("cum_delta", [])
        if cd:
            fig.add_trace(go.Scatter(y=cd, mode="lines", line_color="#00d4ff", name="CumΔ",
                                     xaxis="x2", yaxis="y2"))
        fig.update_layout(template="plotly_dark", margin=dict(l=40, r=10, t=10, b=20), showlegend=False,
                          paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)",
                          xaxis=dict(domain=[0, 0.45]), xaxis2=dict(domain=[0.55, 1], anchor="y2"),
                          yaxis2=dict(anchor="x2", side="right"))
        news = [html.Div([html.Span(f"{i['score']:+.2f} ", style={"color": col(i["score"]), "fontFamily": "monospace"}),
                          html.A(i["title"], href=i["link"], target="_blank",
                                 style={"color": "#ccc", "fontSize": "12px"})])
                for i in engine.sent.items[:30]]
        return g, flow, bridge, cal, fig, news

    @app.callback(Output("gi-override", "children"), Output("gi-override", "color"), Output("gi-override", "outline"),
                  Input("gi-override", "n_clicks"))
    def _override(n):
        on = override_on()
        if n: on = not on; set_override(on)
        return ("🔓 Sin filtros: ON" if on else "🔓 Sin filtros: OFF"), ("danger" if on else "dark"), (not on)

    @app.callback(Output("gi-cmd-ack", "children"),
                  Input("gi-pause", "n_clicks"), Input("gi-resume", "n_clicks"),
                  Input("gi-close", "n_clicks"), Input("gi-cancel", "n_clicks"), Input("gi-refresh", "n_clicks"), prevent_initial_call=True)
    def _cmd(*_):
        m = {"gi-pause": "PAUSE", "gi-resume": "RESUME", "gi-close": "CLOSE_ALL", "gi-cancel": "CANCEL_PENDING", "gi-refresh": "REFRESH_CHARTS"}
        c = m.get(ctx.triggered_id)
        if not c:
            return ""
        i = engine.send_command(c)
        return f"Enviado #{i} {c} — el EA lo ejecuta en ≤1 s"

    return layout

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    if HAS_MT5: mt5.initialize()
    e = IntelEngine()
    print(json.dumps(e.compute(), indent=2, default=str))
