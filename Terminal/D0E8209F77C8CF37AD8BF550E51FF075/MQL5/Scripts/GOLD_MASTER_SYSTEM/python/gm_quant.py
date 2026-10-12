"""
gm_quant.py — capa cuantitativa institucional de GOLD MASTER
  · Pronóstico de volatilidad: GARCH(1,1) (paquete `arch`) con respaldo EWMA RiskMetrics (λ=0.94)
  · Régimen de mercado: HMM gaussiano de 2-3 estados (`hmmlearn`) con respaldo Kaufman ER + ADX
  · Filtro de Kalman (nivel + pendiente) sobre H1 → tendencia sin retraso de medias móviles
  · Macro intermercado (yfinance, sin clave): DXY, US10Y, VIX, plata (ratio oro/plata), futuros GC
    + FRED (opcional, FRED_API_KEY): rendimiento real 10Y (DFII10), el driver nº1 del oro
  · Estacionalidad intradía: retorno medio por hora (z-score) de los últimos 60 días
  · Gobernador de riesgo de cartera: riesgo abierto total de TODAS las posiciones XAU (EAs + manual)
    y objetivo de volatilidad → risk_mult y gov_block para todos los EAs vía intel.txt
Todo es opcional y tolerante a fallos: si una fuente falla se usa un valor neutro.
"""
import os, time, logging
import numpy as np, pandas as pd
log = logging.getLogger("gm_quant")
try:
    import MetaTrader5 as mt5; HAS_MT5 = True
except Exception:
    HAS_MT5 = False

MAX_PORTFOLIO_RISK_PCT = float(os.getenv("GM_MAX_PORT_RISK", "6"))   # % del patrimonio en riesgo abierto total
TARGET_DAILY_VOL_PCT   = float(os.getenv("GM_TARGET_VOL", "1.2"))    # vol diaria "normal" del oro (%)

def _rates(sym, tf, n):
    if not HAS_MT5: return None
    r = mt5.copy_rates_from_pos(sym, tf, 1, n)  # pos=1 → excluye barra en formación
    return None if r is None or len(r) == 0 else pd.DataFrame(r)

# ─── volatilidad ──────────────────────────────────────────────
def vol_forecast(close_daily):
    r = np.log(close_daily).diff().dropna()*100
    if len(r) < 120: return float(r.std()) if len(r) else 1.0, "n/a"
    try:
        from arch import arch_model
        res = arch_model(r[-750:], vol="GARCH", p=1, q=1, dist="t", rescale=False).fit(disp="off")
        return float(np.sqrt(res.forecast(horizon=1).variance.values[-1, 0])), "GARCH"
    except Exception:
        lam = 0.94; v = r.iloc[:30].var()
        for x in r.iloc[30:]: v = lam*v + (1-lam)*x*x
        return float(np.sqrt(v)), "EWMA"

# ─── régimen ──────────────────────────────────────────────────
def efficiency_ratio(c, n=20):
    c = np.asarray(c); net = abs(c[-1]-c[-n-1]); path = np.abs(np.diff(c[-n-1:])).sum()
    return float(net/path) if path > 0 else 0.0

def adx(h, l, c, n=14):
    h, l, c = map(np.asarray, (h, l, c))
    up = np.r_[0, np.diff(h)]; dn = -np.r_[0, np.diff(l)]
    pdm = np.where((up > dn) & (up > 0), up, 0); ndm = np.where((dn > up) & (dn > 0), dn, 0)
    tr = np.maximum(h-l, np.maximum(abs(h-np.r_[c[0], c[:-1]]), abs(l-np.r_[c[0], c[:-1]])))
    sm = lambda x: pd.Series(x).ewm(alpha=1/n, adjust=False).mean().values
    atr = sm(tr); pdi = 100*sm(pdm)/atr; ndi = 100*sm(ndm)/atr
    dx = 100*abs(pdi-ndi)/np.maximum(pdi+ndi, 1e-9)
    return float(sm(dx)[-1]), float(pdi[-1]), float(ndi[-1])

def hmm_regime(ret):
    try:
        from hmmlearn.hmm import GaussianHMM
        X = np.c_[ret, pd.Series(ret).rolling(10).std().bfill().values]
        m = GaussianHMM(n_components=3, covariance_type="full", n_iter=200, random_state=1).fit(X[-3000:])
        st = m.predict(X[-3000:]); cur = st[-1]
        vols = [X[-3000:][st == k, 1].mean() if (st == k).any() else 0 for k in range(3)]
        return ("HIGH_VOL" if cur == int(np.argmax(vols)) else "CALM"), float(m.predict_proba(X[-3000:])[-1].max())
    except Exception:
        return None, 0.0

def kalman_trend(price, q=1e-3, r=1.0):
    """modelo nivel+pendiente; devuelve pendiente filtrada (precio/vela) y su z"""
    x = np.array([price[0], 0.0]); P = np.eye(2); F = np.array([[1, 1], [0, 1]]); H = np.array([[1, 0]])
    Q = q*np.var(np.diff(price))*np.eye(2); R = r*np.var(np.diff(price)); slopes = []
    for z in price:
        x = F@x; P = F@P@F.T + Q
        S = H@P@H.T + R; K = P@H.T/S
        x = x + (K*(z - H@x)).ravel(); P = (np.eye(2) - K@H)@P; slopes.append(x[1])
    s = np.array(slopes); sd = s[-200:].std() or 1e-9
    return float(s[-1]), float(s[-1]/sd)

# ─── macro intermercado ───────────────────────────────────────
_macro_cache = {"t": 0, "v": {}}
def macro(refresh_s=1800):
    if time.time() - _macro_cache["t"] < refresh_s and _macro_cache["v"]: return _macro_cache["v"]
    out = {"vix": 0, "us10y": 0, "us10y_chg5": 0, "gs_ratio": 0, "real_yield": 0, "real_yield_chg5": 0, "macro_bias": 0}
    try:
        import yfinance as yf
        d = yf.download(["^VIX", "^TNX", "GC=F", "SI=F", "^GVZ"], period="3mo", interval="1d", progress=False, auto_adjust=True)["Close"].ffill()
        out["vix"] = round(float(d["^VIX"].iloc[-1]), 2)
        out["us10y"] = round(float(d["^TNX"].iloc[-1]), 3); out["us10y_chg5"] = round(float(d["^TNX"].iloc[-1]-d["^TNX"].iloc[-6]), 3)
        out["gs_ratio"] = round(float(d["GC=F"].iloc[-1]/d["SI=F"].iloc[-1]), 2)
        if "^GVZ" in d: out["gvz"] = round(float(d["^GVZ"].iloc[-1]), 2)     # volatilidad implícita de opciones de oro (CBOE)
    except Exception as e:
        log.warning(f"yfinance: {e}")
    key = os.getenv("FRED_API_KEY")
    if key:
        try:
            import requests
            js = requests.get("https://api.stlouisfed.org/fred/series/observations",
                              params={"series_id": "DFII10", "api_key": key, "file_type": "json", "sort_order": "desc", "limit": 10}, timeout=10).json()
            v = [float(o["value"]) for o in js["observations"] if o["value"] != "."]
            out["real_yield"] = v[0]; out["real_yield_chg5"] = round(v[0]-v[min(5, len(v)-1)], 3)
        except Exception as e:
            log.warning(f"FRED: {e}")
    # sube el rendimiento real / nominal → bajista oro; VIX alto → refugio alcista
    ry = out["real_yield_chg5"] if key else out["us10y_chg5"]
    b = -np.tanh(ry/0.15) + (0.3 if out["vix"] > 25 else 0)
    out["macro_bias"] = round(float(np.clip(b, -1, 1)), 3)
    _macro_cache.update(t=time.time(), v=out)
    return out

# ─── estacionalidad intradía ──────────────────────────────────
def hour_seasonality(m15):
    df = m15.copy(); df["t"] = pd.to_datetime(df.time, unit="s"); df["r"] = np.log(df.close).diff()
    g = df.groupby(df.t.dt.hour)["r"]; mu, sd, n = g.mean(), g.std(), g.count()
    h = pd.Timestamp.utcnow().hour if not len(df) else int(df.t.iloc[-1].hour)
    if h not in mu.index or n[h] < 30: return 0.0
    return round(float(mu[h]/(sd[h]/np.sqrt(n[h]))), 2)

# ─── gobernador de riesgo de cartera ──────────────────────────
def portfolio_risk(atr_h1):
    if not HAS_MT5: return {}
    acc = mt5.account_info(); pos = mt5.positions_get() or []
    if acc is None: return {}
    eq = acc.equity or 1e-9; total = 0.0; nopen = 0; nosl = 0
    for p in pos:
        if "XAU" not in p.symbol: continue
        si = mt5.symbol_info(p.symbol); cs = si.trade_contract_size if si else 100
        dist = abs(p.price_open - p.sl) if p.sl > 0 else 5*atr_h1     # P10 — sin SL: 5× ATR conservador (antes 2×)
        if p.sl > 0 and ((p.type == 0 and p.sl >= p.price_open) or (p.type == 1 and p.sl <= p.price_open)): dist = 0  # ya en BE/ganancia
        total += dist*p.volume*cs; nopen += 1; nosl += p.sl == 0
    pct = 100*total/eq
    gov = int(pct >= MAX_PORTFOLIO_RISK_PCT or nosl > 0)  # P10 — bloquear también si hay pos sin SL
    return {"port_risk_pct": round(pct, 2), "open_pos": nopen, "pos_no_sl": nosl,
            "margin_level": round(acc.margin_level or 0, 1), "gov_block": gov}

class QuantEngine:
    def __init__(self, symbol):
        self.symbol = symbol; self._hmm_t = 0; self._hmm = ("", 0.0)

    def compute(self):
        out = {}
        d1 = _rates(self.symbol, mt5.TIMEFRAME_D1, 900) if HAS_MT5 else None
        h1 = _rates(self.symbol, mt5.TIMEFRAME_H1, 3500) if HAS_MT5 else None
        m15 = _rates(self.symbol, mt5.TIMEFRAME_M15, 6000) if HAS_MT5 else None
        if d1 is not None:
            v, model = vol_forecast(d1.set_index(pd.to_datetime(d1.time, unit="s")).close)
            hist = np.log(d1.close).diff().rolling(20).std().dropna()*100
            rr = np.log(d1.close).diff().dropna().values[-500:]*100
            var95 = float(np.percentile(rr, 5)); es95 = float(rr[rr <= var95].mean())
            out.update(vol_fcst=round(v, 3), vol_model=model, vol_pctile=round(float((hist < v).mean()*100), 0),
                       var95_pct=round(var95, 2), es95_pct=round(es95, 2))
        atr_h1 = 0.0
        if h1 is not None and len(h1) > 300:
            c = h1.close.values; er = efficiency_ratio(c, 20); a, pdi, ndi = adx(h1.high, h1.low, h1.close)
            ks, kz = kalman_trend(c[-1500:])
            atr_h1 = float(pd.Series(np.maximum(h1.high-h1.low, abs(h1.high-h1.close.shift()))).rolling(14).mean().iloc[-1])
            if time.time() - self._hmm_t > 3600:
                self._hmm = hmm_regime(np.log(h1.close).diff().fillna(0).values); self._hmm_t = time.time()
            trend = "UP" if (pdi > ndi and kz > 0.5) else "DN" if (ndi > pdi and kz < -0.5) else ""
            rq = ("TREND_" + trend) if (a > 22 and er > 0.3 and trend) else "RANGE"
            if self._hmm[0] == "HIGH_VOL": rq = "HIGH_VOL"
            out.update(er=round(er, 3), adx=round(a, 1), kalman_z=round(kz, 2), regime_q=rq,
                       hmm_state=self._hmm[0] or "n/a", hmm_prob=round(self._hmm[1], 2))
        if m15 is not None: out["hour_edge_z"] = hour_seasonality(m15.tail(60*96))
        out.update(macro())
        out.update(portfolio_risk(atr_h1))
        # multiplicador de riesgo: objetivo de volatilidad × régimen × gobernador
        rm = 1.0
        if out.get("vol_fcst"): rm *= float(np.clip(TARGET_DAILY_VOL_PCT/out["vol_fcst"], 0.4, 1.25))
        if out.get("regime_q") == "HIGH_VOL": rm *= 0.5
        if out.get("gov_block"): rm = 0.0
        out["risk_mult_q"] = round(rm, 2)
        return out
