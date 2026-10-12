"""
GOLD MASTER — Optimizador + Walk-Forward + Monte Carlo de la estrategia PRO Signals (modo en vivo, M1)
Datos reales desde MT5 (paquete MetaTrader5). Cuentas pequeñas: XAUUSDmicro (0.1 lot) y XAUUSD (0.01 lot).
Uso:  python gm_optimizer.py            (resultados en ./out)
"""
import os, json, itertools, time, sys
import numpy as np, pandas as pd
try:
    import MetaTrader5 as mt5
except ImportError:  # numerical validation is available without an MT5 installation
    mt5 = None
from gm_validation import simulate_orders, split_trades, select_candidate, bootstrap_metrics, equity_path
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out"); os.makedirs(OUT, exist_ok=True)
BARS = 160000           # ~4 meses de M1
START_EQ = 30.0
RUIN_EQ = 10.0
MC_RUNS = 5000
DIRS = {}
SYMBOLS = {"XAUUSDmicro": None, "XAUUSD": None}

def log(*a):
    print(*a, flush=True)

# ───────────────────────────── datos
def load(sym, tf, n):
    if mt5 is None:
        raise RuntimeError("MetaTrader5 is required only to load broker history")
    r = None
    for k in (n, 99000, 60000, 30000):                 # el terminal limita las velas ("Máx. barras en gráfico")
        r = mt5.copy_rates_from_pos(sym, tf, 1, min(k, n))  # exclude the unfinished bar
        if r is not None and len(r) > 0: break
    if r is None or len(r) == 0:
        log("  copy_rates falló", sym, tf, mt5.last_error()); return None
    df = pd.DataFrame(r); df["time"] = pd.to_datetime(df["time"], unit="s"); return df

def ema(x, n): return pd.Series(x).ewm(span=n, adjust=False).mean().values
def dema(x, n): e = ema(x, n); return 2*e - ema(e, n)
def atr(h, l, c, n=14):
    pc = np.r_[c[0], c[:-1]]; tr = np.maximum(h, pc) - np.minimum(l, pc)
    return pd.Series(tr).ewm(alpha=1/n, adjust=False).mean().values

def rolling_reg(y, L):
    """pendiente, valor medio al final y desvío residual de una regresión lineal móvil"""
    s = pd.Series(y); x = np.arange(L); xm = x.mean(); sxx = ((x-xm)**2).sum()
    w = (x - xm) / sxx
    slope = s.rolling(L).apply(lambda v: np.dot(w, v), raw=True).values
    mean = s.rolling(L).mean().values
    end = mean + slope*(L-1-xm)
    var_y = s.rolling(L).var(ddof=0).values
    var_res = np.maximum(var_y - slope**2*(sxx/L), 0)
    return slope, end, np.sqrt(var_res)

def structure(h, l, c, k=2):
    """dirección estructural (último BOS) y último swing low/high confirmado, sin mirar al futuro"""
    n = len(c); sdir = np.zeros(n, int); lastL = np.full(n, np.nan); lastH = np.full(n, np.nan)
    sh = sl = np.nan; d = 0
    for i in range(n):
        j = i - k                                   # pivote confirmado k velas después
        if j >= k:
            if h[j] == max(h[j-k:j+k+1]): sh = h[j]
            if l[j] == min(l[j-k:j+k+1]): sl = l[j]
        if not np.isnan(sh) and c[i] > sh: d = 1
        if not np.isnan(sl) and c[i] < sl: d = -1
        sdir[i] = d; lastH[i] = sh; lastL[i] = sl
    return sdir, lastL, lastH

def features(m1, m15):
    o, h, l, c = (m1[k].values for k in ("open", "high", "low", "close"))
    f = {"o": o, "h": h, "l": l, "c": c, "t": m1["time"].values, "spread": m1["spread"].values}
    f["atr"] = atr(h, l, c); f["e50"] = ema(c, 50); f["e200"] = ema(c, 200)
    f["slope"], f["mid"], f["dev"] = rolling_reg(c, 50)
    f["sdir"], f["swL"], f["swH"] = structure(h, l, c)
    hr = pd.to_datetime(m1["time"]).dt.hour.values; f["hour"] = hr
    win = 30*24*60
    f["mhi"] = pd.Series(h).rolling(win, min_periods=1000).max().values
    f["mlo"] = pd.Series(l).rolling(win, min_periods=1000).min().values
    # pendiente EMA50 de M15 con velas CERRADAS
    e = ema(m15["close"].values, 50); slope15 = np.r_[0, np.diff(e)]
    close_t = m15["time"] + pd.Timedelta(minutes=15)
    a = pd.DataFrame({"t": pd.to_datetime(close_t).astype("datetime64[ns]"), "s": slope15}).sort_values("t")
    b = pd.DataFrame({"t": pd.to_datetime(m1["time"]).astype("datetime64[ns]")})
    f["htf"] = pd.merge_asof(b, a, on="t", direction="backward")["s"].fillna(0).values
    f["_dema"] = {}
    return f

def get_dema(f, n):
    if n not in f["_dema"]: f["_dema"][n] = dema(f["c"], n)
    return f["_dema"][n]

# ───────────────────────────── estrategia (idéntica al indicador en modo vivo)
def signals(f, P):
    df, ds = get_dema(f, P["fast"]), get_dema(f, P["slow"])
    up = (df > ds) & (np.r_[False, df[:-1] <= ds[:-1]]); dn = (df < ds) & (np.r_[False, df[:-1] >= ds[:-1]])
    idx = np.where(up | dn)[0]
    out = []; last = 0; c = f["c"]
    for b in idx:
        if b < 300: continue
        d = 1 if up[b] else -1
        if d == last: continue
        if P["session"] and not (7 <= f["hour"][b] < 20): continue
        if d > 0 and c[b] > f["mid"][b] + P["chdev"]*f["dev"][b]: continue
        if d < 0 and c[b] < f["mid"][b] - P["chdev"]*f["dev"][b]: continue
        sc = 1
        if (d > 0 and c[b] > f["e50"][b] > f["e200"][b]) or (d < 0 and c[b] < f["e50"][b] < f["e200"][b]): sc += 1
        if f["slope"][b]*d > 0: sc += 1
        if f["sdir"][b] == d: sc += 1
        if f["htf"][b]*d > 0: sc += 1
        eq = (f["mhi"][b] + f["mlo"][b]) / 2
        if (d > 0 and c[b] < eq) or (d < 0 and c[b] > eq): sc += 1
        if sc < P["minscore"]: continue
        out.append((b, d, sc)); last = d
    return out

def simulate(f, P, sigs, point, start_bar=0, end_bar=None):
    """Closed-bar signals; next-open bid/ask fills. First three result fields are compatible."""
    c, a = f["c"], f["atr"]
    orders = []
    for b, d, sc in sigs:
        e = c[b]; sw = f["swL"][b] if d > 0 else f["swH"][b]
        sl = sw - d*0.25*a[b] if not np.isnan(sw) else e - d*P["slatr"]*a[b]
        risk = (e - sl)*d
        if risk < P["slatr"]*a[b]: risk = P["slatr"]*a[b]
        if risk > 3.5*a[b]: risk = 3.5*a[b]
        sl = e - d*risk; tp = e + d*risk*P["tp"]
        orders.append((b, d, e, sl, tp, risk))
    res = simulate_orders(f, orders, point, P["maxbars"], P["be"], P["lock"],
                          P.get("commission_price", 0.0), P.get("slippage_points", 0.0),
                          start_bar, end_bar)
    DIRS.clear()
    DIRS.update({x.signal_bar: x.direction for x in res})
    return res

def stats(res):
    if not res: return dict(n=0, exp=-9, wr=0, pf=0, sqn=-9)
    R = np.array([x[1] for x in res]); w = R[R > 0].sum(); ls = -R[R < 0].sum()
    sd = R.std() if len(R) > 1 else 1
    return dict(n=len(R), exp=float(R.mean()), wr=float((R > 0).mean()), pf=float(w/ls) if ls > 0 else 99,
                sqn=float(R.mean()/sd*np.sqrt(min(len(R), 100))) if sd > 0 else 0, total=float(R.sum()))

# ───────────────────────────── Monte Carlo en dólares (lote mínimo fijo)
def montecarlo(res, usd_per_price, rng):
    pnl = np.array([x[1]*x[2]*usd_per_price for x in res])    # $ por operación con lote mínimo
    if len(pnl) < 10: return None
    out = bootstrap_metrics(pnl, START_EQ, RUIN_EQ, rng, runs=MC_RUNS)
    out.update(trades=len(pnl), avg_loss_usd=float(pnl[pnl < 0].mean()) if (pnl < 0).any() else 0)
    return out


# ───────────────────────────── ML (meta-labeling): ¿esta señal llegará a ganancia?
def ml_features(f, b, d):
    a = f["atr"][b] or 1e-9; c = f["c"][b]
    eq = (f["mhi"][b] + f["mlo"][b]) / 2; rng_m = max(f["mhi"][b] - f["mlo"][b], 1e-9)
    return [d, f["slope"][b]*d/a, (c - f["mid"][b])*d/max(f["dev"][b], 1e-9), (c - f["e50"][b])*d/a,
            (f["e50"][b] - f["e200"][b])*d/a, f["sdir"][b]*d, np.sign(f["htf"][b])*d, (c - eq)*d/rng_m,
            a/c*1e4, f["hour"][b], f["spread"][b],
            (c - f["c"][max(b-15, 0)])*d/a, (c - f["c"][max(b-60, 0)])*d/a]
ML_COLS = ["dir","slope_atr","ch_z","dist_e50","e50_e200","struct","htf","range_pos","atr_bp","hour","spread","mom15","mom60"]

def train_ml(f, res, split, threshold=0.5, export=False):
    """Research evaluation: fixed threshold, purged labels, no automatic model export."""
    if not 0 < threshold < 1:
        raise ValueError("threshold must be fixed before reading holdout results")
    try:
        from sklearn.ensemble import HistGradientBoostingClassifier
        from sklearn.linear_model import LogisticRegression
        from sklearn.preprocessing import StandardScaler
    except ImportError:
        return {"error": "scikit-learn no instalado (pip install scikit-learn)"}
    train, test, purged = split_trades(res, split)
    res = train + test
    X = np.nan_to_num(np.array([ml_features(f, x.signal_bar, x.direction) for x in res], float), nan=0.0, posinf=0.0, neginf=0.0)
    y = np.array([int(x.r_multiple > 0) for x in res]); R = np.array([x.r_multiple for x in res])
    tr = np.arange(len(res)) < len(train); te = ~tr
    if tr.sum() < 60 or te.sum() < 20: return {"error": "pocas operaciones para entrenar"}
    if len(np.unique(y[tr])) < 2: return {"error": "entrenamiento requiere ganancias y pérdidas"}
    gb = HistGradientBoostingClassifier(max_depth=3, learning_rate=0.05, max_iter=300, l2_regularization=1.0, random_state=1)
    gb.fit(X[tr], y[tr]); p = gb.predict_proba(X[te])[:, 1]
    sc = StandardScaler().fit(X[tr]); lr = LogisticRegression(C=0.5, max_iter=2000).fit(sc.transform(X[tr]), y[tr])
    out = {"train_trades": int(tr.sum()), "test_trades": int(te.sum()),
           "test_base_exp": float(R[te].mean()), "test_base_wr": float(y[te].mean())}
    m = p >= threshold
    out.update(fixed_threshold=threshold, purged_trades=len(purged), kept=int(m.sum()),
               filtered_exp=float(R[te][m].mean()) if m.any() else None,
               status="research_only", promotion_allowed=False)
    if not export:
        return out
    import joblib; joblib.dump({"gb": gb, "cols": ML_COLS, "threshold": threshold, "research_only": True}, os.path.join(OUT, f"ml_{SYM_CUR}.joblib"))
    # coeficientes lineales exportables a MQL5 (z = (x-mean)/std; p = 1/(1+exp(-(b0+Σw·z))))
    pd.DataFrame({"feature": ["__intercept__"] + ML_COLS,
                  "mean": [0] + list(sc.mean_), "std": [1] + list(sc.scale_),
                  "w": [lr.intercept_[0]] + list(lr.coef_[0])}).to_csv(os.path.join(OUT, f"ml_linear_{SYM_CUR}.csv"), index=False)
    return out

SYM_CUR=''
GRID = dict(fast=[13, 21, 34], slow=[55, 89], minscore=[3, 4, 5], tp=[1.5, 2.0, 3.0],
            slatr=[1.2, 2.0], be=[0, 1.5], lock=[0.3], chdev=[2.0], session=[True], maxbars=[240])

def run_symbol(sym):
    info = mt5.symbol_info(sym)
    if info is None: log("sin símbolo", sym); return None
    mt5.symbol_select(sym, True)
    m1 = load(sym, mt5.TIMEFRAME_M1, BARS); m15 = load(sym, mt5.TIMEFRAME_M15, BARS//15 + 500)
    if m1 is None or m15 is None: log("sin datos", sym); return None
    log(f"{sym}: {len(m1)} velas M1 {m1.time.iloc[0]} -> {m1.time.iloc[-1]}  contrato={info.trade_contract_size} lotmin={info.volume_min}")
    f = features(m1, m15)
    usd = info.trade_contract_size*info.volume_min           # $ por 1.00 de precio con lote mínimo
    split = int(len(m1)*0.7)
    keys = list(GRID); rows = []
    t0 = time.time()
    for vals in itertools.product(*[GRID[k] for k in keys]):
        P = dict(zip(keys, vals))
        if P["fast"] >= P["slow"]: continue
        sig = signals(f, P)
        res = simulate(f, P, sig, info.point, end_bar=split)
        tr, _, purged = split_trades(res, split)
        rows.append({"P": P, "IS": stats(tr), "purged": len(purged)})
    log(f"  {len(rows)} combinaciones en {time.time()-t0:.0f}s")
    pd.DataFrame([{**r["P"], **{f"is_{k}": v for k, v in r["IS"].items()}, "purged": r["purged"]}
                  for r in rows]).to_csv(os.path.join(OUT, f"grid_{sym}.csv"), index=False)
    best = select_candidate(rows, min_trades=40)
    if best is None:
        return dict(symbol=sym, status="no_positive_training_candidate", promotion_allowed=False)
    P = best["P"]
    sig = signals(f, P)
    tr, _, purge_train = split_trades(simulate(f, P, sig, info.point, end_bar=split), split)
    _, te, purge_test = split_trades(simulate(f, P, sig, info.point, start_bar=split), split)
    res = tr + te
    mc = montecarlo(te, usd, np.random.default_rng(7))  # stress only untouched holdout
    global SYM_CUR; SYM_CUR = sym
    try: mlr = train_ml(f, res, split)
    except Exception as ex: mlr = {"error": str(ex)}
    pnl = [x[1]*x[2]*usd for x in res]
    active_equity = equity_path(pnl, START_EQ)[1:]
    eq = np.full(len(res), np.nan); eq[:len(active_equity)] = active_equity
    pd.DataFrame({"bar_time": [str(f["t"][x[0]]) for x in res], "R": [x[1] for x in res],
                  "exit_time": [str(f["t"][x.exit_bar]) for x in res],
                  "entry_price": [x.entry_price for x in res], "exit_price": [x.exit_price for x in res],
                  "exit_reason": [x.reason for x in res], "usd": pnl, "equity": eq,
                  "executed_before_insolvency": np.arange(len(res)) < len(active_equity)
                  }).to_csv(os.path.join(OUT, f"trades_{sym}.csv"), index=False)
    return dict(symbol=sym, usd_per_1_price_minlot=usd, period=[str(m1.time.iloc[0]), str(m1.time.iloc[-1])],
                best_params=P, in_sample=stats(tr), out_of_sample=stats(te),
                validation="chronological_70_30_holdout_is_only_selection",
                purged_trades=len(purge_train)+len(purge_test), montecarlo_scope="OOS_only",
                execution="next_open_bid_ask_bar_spread_stop_first",
                costs={"commission_price": P.get("commission_price", 0), "slippage_points": P.get("slippage_points", 0), "swaps_modeled": False},
                status="research_only", promotion_allowed=False,
                full=stats(res), montecarlo=mc, ml=mlr,
                final_equity_minlot=float(active_equity[-1]) if len(active_equity) else START_EQ)

if __name__ == "__main__":
    if mt5 is None: log("Instala MetaTrader5 para descargar datos; las pruebas offline no lo requieren"); sys.exit(1)
    if not mt5.initialize(): log("MT5 no inicializa:", mt5.last_error()); sys.exit(1)
    report = {}
    for s in SYMBOLS:
        try: report[s] = run_symbol(s)
        except Exception as e: log("error", s, e); report[s] = {"error": str(e)}
    mt5.shutdown()
    with open(os.path.join(OUT, "report.json"), "w") as fh: json.dump(report, fh, indent=2, default=str)
    log(json.dumps(report, indent=2, default=str)); log("LISTO")
