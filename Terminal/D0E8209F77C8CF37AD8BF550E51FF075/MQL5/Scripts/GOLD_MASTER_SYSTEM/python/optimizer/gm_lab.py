"""
GOLD MASTER LAB — compara varias estrategias sobre datos reales de MT5 (XAUUSDmicro),
optimiza con walk-forward (70% / 30%) y valida con Monte Carlo para una cuenta de 50 USD.
Estrategias: DEMA-live (indicador), Pullback de tendencia (RSI), Ruptura de Londres (ORB).
"""
import os, sys, json, itertools, time
try:
    from zoneinfo import ZoneInfo  # Python 3.9+
    _TZ_LONDON = ZoneInfo("Europe/London")
except ImportError:
    import pytz; _TZ_LONDON = pytz.timezone("Europe/London")
import numpy as np, pandas as pd
import MetaTrader5 as mt5
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gm_optimizer import ema, dema, atr, rolling_reg, structure, load
from gm_validation import simulate_orders, split_trades, select_candidate, bootstrap_metrics

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out"); os.makedirs(OUT, exist_ok=True)
# Comisión monetaria por operación completa y por el volumen simulado.
# No se presume una tarifa del broker: la corrida debe registrar el valor usado.
COMMISSION_USD_PER_TRADE = float(os.getenv("GM_COMMISSION_USD_PER_TRADE", "0"))
if not np.isfinite(COMMISSION_USD_PER_TRADE) or COMMISSION_USD_PER_TRADE < 0:
    raise ValueError("GM_COMMISSION_USD_PER_TRADE debe ser finita y no negativa")
SYM = "XAUUSDmicro"; START = 50.0; RUIN = 25.0; MC = 4000
def log(*a): print(*a, flush=True)

def rsi(c, n=14):
    d = np.diff(c, prepend=c[0]); up = pd.Series(np.maximum(d, 0)).ewm(alpha=1/n, adjust=False).mean()
    dn = pd.Series(np.maximum(-d, 0)).ewm(alpha=1/n, adjust=False).mean(); return (100 - 100/(1 + up/(dn + 1e-12))).values

def feats(df, htf):
    o, h, l, c = (df[k].values for k in ("open", "high", "low", "close"))
    t = pd.to_datetime(df["time"])
    # DST-aware London hour (P5)
    t_utc = t.dt.tz_localize("UTC") if t.dt.tz is None else t.dt.tz_convert("UTC")
    t_london = t_utc.dt.tz_convert(_TZ_LONDON)
    t = t_utc.dt.tz_localize(None)
    F = dict(o=o, h=h, l=l, c=c, t=t.values, hour=t.dt.hour.values,
             hour_london=t_london.dt.hour.values, date_london=t_london.dt.date.values,
             date=t.dt.date.values, spread=df["spread"].values,
             atr=atr(h, l, c), e50=ema(c, 50), e200=ema(c, 200), rsi=rsi(c))
    F["slope"], F["mid"], F["dev"] = rolling_reg(c, 50)
    F["sdir"], F["swL"], F["swH"] = structure(h, l, c)
    e = ema(htf["close"].values, 50); s = np.r_[0, np.diff(e)]
    step = pd.to_datetime(htf["time"]).diff().median()
    a = pd.DataFrame({"t": (pd.to_datetime(htf["time"]) + step).astype("datetime64[ns]"), "s": s}).sort_values("t")
    b = pd.DataFrame({"t": t.astype("datetime64[ns]")})
    F["htf"] = pd.merge_asof(b, a, on="t", direction="backward")["s"].fillna(0).values
    F["dm"] = {}
    return F

def D(F, n):
    if n not in F["dm"]: F["dm"][n] = dema(F["c"], n)
    return F["dm"][n]

def mk(F, b, d, sl_raw, P):
    """normaliza SL (mín/máx en ATR) y TP en R"""
    a = F["atr"][b]; e = F["c"][b]
    risk = (e - sl_raw)*d if not np.isnan(sl_raw) else P["slatr"]*a
    risk = min(max(risk, P["slatr"]*a), 4*a)
    return (b, d, e, e - d*risk, e + d*risk*P["tp"], risk)

# ─── estrategias
def s_dema(F, P):
    df, ds = D(F, P["fast"]), D(F, P["slow"]); c = F["c"]; out = []; last = 0
    up = (df > ds) & np.r_[False, df[:-1] <= ds[:-1]]; dn = (df < ds) & np.r_[False, df[:-1] >= ds[:-1]]
    for b in np.where(up | dn)[0]:
        if b < 300: continue
        d = 1 if up[b] else -1
        if d == last or not (7 <= F["hour"][b] < 20): continue
        if (c[b] - F["mid"][b])*d > 2*F["dev"][b]: continue
        sc = 1 + ((c[b]-F["e50"][b])*d > 0 and (F["e50"][b]-F["e200"][b])*d > 0) + (F["slope"][b]*d > 0) + (F["sdir"][b] == d) + (F["htf"][b]*d > 0)
        if sc < P["minscore"]: continue
        out.append(mk(F, b, d, F["swL"][b] - 0.25*F["atr"][b] if d > 0 else F["swH"][b] + 0.25*F["atr"][b], P)); last = d
    return out

def s_pullback(F, P):
    c, r = F["c"], F["rsi"]; out = []
    for b in range(300, len(c)-1):
        if not (7 <= F["hour"][b] < 20): continue
        up = F["e50"][b] > F["e200"][b] and F["htf"][b] > 0 and c[b] > F["e200"][b]
        dn = F["e50"][b] < F["e200"][b] and F["htf"][b] < 0 and c[b] < F["e200"][b]
        if up and r[b-1] < P["lvl"] <= r[b]:
            out.append(mk(F, b, 1, F["swL"][b] - 0.25*F["atr"][b], P))
        elif dn and r[b-1] > 100-P["lvl"] >= r[b]:
            out.append(mk(F, b, -1, F["swH"][b] + 0.25*F["atr"][b], P))
    return out

def s_london(F, P):
    c, h, l = F["c"], F["h"], F["l"]; out = []; dates = F.get("date_london",F["date"])
    hr = F.get("hour_london", F["hour"])  # DST-aware (P5)
    day_idx = pd.Series(np.arange(len(c))).groupby(dates)
    widths = []
    for dte, idx in day_idx:
        idx = idx.values; rng = idx[(hr[idx] >= 0) & (hr[idx] < 7)]
        if len(rng) < 10: continue
        hi, lo = h[rng].max(), l[rng].min(); w = hi - lo; widths.append(w)
        med = np.median(widths[-20:])
        if len(widths) < 5 or w > P["maxw"]*med: continue
        for b in idx[(hr[idx] >= 7) & (hr[idx] < 12)]:
            buf = 0.1*F["atr"][b]
            d = 1 if c[b] > hi + buf else -1 if c[b] < lo - buf else 0
            if d == 0: continue
            if P["trend"] and F["htf"][b]*d <= 0: break
            sl = (hi + lo)/2 if P["slmode"] == "mid" else (lo if d > 0 else hi)
            out.append(mk(F, b, d, sl, P)); break
    return out

STRATS = {
 "dema":     (s_dema,     dict(fast=[13, 21], slow=[55, 89], minscore=[3, 4, 5], tp=[1.5, 2.0, 3.0], slatr=[1.0, 1.5])),
 "pullback": (s_pullback, dict(lvl=[30, 35, 40, 45], tp=[1.5, 2.0, 3.0], slatr=[1.0, 1.5, 2.0])),
 "london":   (s_london,   dict(tp=[1.0, 1.5, 2.0, 3.0], slmode=["mid", "opp"], maxw=[1.0, 1.5, 2.5], trend=[False, True], slatr=[0.5])),
}

def sim(F, sigs, point, maxbars, be=1.5, lock=0.3, **kwargs):
    return simulate_orders(F, sigs, point, maxbars, be, lock, **kwargs)

def st(res, usd):
    """usd = USD por punto × volumen mínimo (precio por unidad de riesgo en precio)"""
    if not res: return dict(n=0, exp=-9, pf=0, usd=0, wr=0, usd_net=0, commission_total=0)
    R = np.array([x[1] for x in res])
    P = np.array([x[1]*x[2]*usd for x in res])           # P&L bruto
    comm_total = COMMISSION_USD_PER_TRADE * len(res)
    P_net = P - COMMISSION_USD_PER_TRADE                  # P4 — deducir comisión por trade
    w, ls = P_net[P_net > 0].sum(), -P_net[P_net < 0].sum()
    R_net = R - COMMISSION_USD_PER_TRADE / (np.array([x[2] for x in res]) * usd + 1e-12)
    return dict(n=len(R), exp=float(R_net.mean()), wr=float((P_net > 0).mean()),
                pf=float(w/ls) if ls > 0 else 99, usd=float(P.sum()),
                usd_net=float(P_net.sum()), commission_total=float(comm_total))

import hashlib as _hl
def _mc_rng(strategy_name: str, tf_name: str):
    """P9 — semilla estable y única por estrategia+timeframe usando SHA-256."""
    key = f"{strategy_name}:{tf_name}".encode()
    seed = 20261006 + int(_hl.sha256(key).hexdigest()[:8], 16) % 100000
    return np.random.default_rng(seed)

def montecarlo(res, usd, rng):
    pnl = np.array([x[1]*x[2]*usd-COMMISSION_USD_PER_TRADE for x in res]); N = len(pnl)
    if N < 15: return None
    return bootstrap_metrics(pnl, START, RUIN, rng, MC)

def run(tfname, tf, htf_tf, maxbars):
    info = mt5.symbol_info(SYM); usd = info.trade_contract_size*info.volume_min
    df = load(SYM, tf, 99000); hf = load(SYM, htf_tf, 30000)
    log(f"{tfname}: {len(df)} velas {df.time.iloc[0]} -> {df.time.iloc[-1]}")
    F = feats(df, hf); split = int(len(df)*0.7); out = {}
    for name, (fn, grid) in STRATS.items():
        keys = list(grid); rows = []; t0 = time.time()
        for v in itertools.product(*[grid[k] for k in keys]):
            P = dict(zip(keys, v))
            if "fast" in P and P["fast"] >= P["slow"]: continue
            res = sim(F, fn(F, P), info.point, maxbars, end_bar=split)
            train, _, purged = split_trades(res, split)
            rows.append(dict(P=P, IS=st(train, usd)))
        good = [r for r in rows if r["IS"]["n"] >= 30 and r["IS"]["usd_net"] > 0 and r["IS"]["exp"] > 0]
        best = select_candidate(good, min_trades=30)
        info_s = dict(combos=len(rows), positive_training_combos=len(good),
                      validation="IS_only_selection_then_untouched_holdout", promotion_allowed=False)
        if best:
            res = sim(F, fn(F, best["P"]), info.point, maxbars, start_bar=split)
            _, test, purged = split_trades(res, split)
            info_s.update(best=best["P"], IS=best["IS"], OOS=st(test, usd),
                          montecarlo_50usd=montecarlo(test, usd, _mc_rng(name, tfname)), purged=len(purged),
                          simulation_notes={
                              "tie_resolution": "SL_wins_pessimistic",
                              "bar_resolution": "OHLC_M5_pessimistic_ambiguity",
                              "commission": f"USD {COMMISSION_USD_PER_TRADE:.2f}_per_trade_roundtrip_for_simulated_volume",
                              "commission_source": "GM_COMMISSION_USD_PER_TRADE environment; zero means uncalibrated",
                              "session_basis": "Europe/London DST-adjusted"
                          })
        out[name] = info_s
        log(f"  {name}: {len(rows)} combos, robustas {len(good)}  ({time.time()-t0:.0f}s)  best={info_s.get('best')} OOS={info_s.get('OOS')}")
    return out

if __name__ == "__main__":
    if not mt5.initialize(): log("MT5 no inicializa", mt5.last_error()); sys.exit(1)
    rep = {}
    for tfn, tf, htf, mb in [("M5", mt5.TIMEFRAME_M5, mt5.TIMEFRAME_H1, 288), ("M15", mt5.TIMEFRAME_M15, mt5.TIMEFRAME_H4, 96)]:
        try: rep[tfn] = run(tfn, tf, htf, mb)
        except Exception as e: import traceback; traceback.print_exc(); rep[tfn] = {"error": str(e)}
    mt5.shutdown()
    json.dump(rep, open(os.path.join(OUT, "lab_report.json"), "w"), indent=2, default=str); log("LISTO")
