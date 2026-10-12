"""
gm_montecarlo.py — Monte Carlo de TRAYECTORIAS DE PRECIO (no sólo de operaciones) para el oro.
Tres universos de datos, cada uno con N trayectorias M15 de ~6 meses:
  REAL   : bootstrap estacionario por bloques de velas reales descargadas de MT5 (conserva autocorrelación,
           rachas de volatilidad y la forma intravela)
  SIM    : retornos simulados GARCH(1,1) con innovaciones t de Student (colas gruesas) ajustado al oro,
           + rangos intravela muestreados de velas reales con volatilidad parecida
  MIXTO  : alterna bloques reales y bloques GARCH (≈50/50) → mercados "nuevos" pero con ADN real
Sobre cada trayectoria se ejecuta la estrategia PULLBACK (modo validado y agresivo) y se mide
retorno, drawdown y factor de beneficio para una cuenta de 50 USD en XAUUSDmicro (0.1 lot = 0.10 USD/$).
"""
import os, sys, json, time
import numpy as np, pandas as pd
import MetaTrader5 as mt5
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gm_optimizer import load
from gm_lab import feats, s_pullback, sim
from gm_validation import equity_path

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out"); os.makedirs(OUT, exist_ok=True)
SYM, N_PATHS, LEN, BLOCK, START = "XAUUSDmicro", int(os.getenv("MC_PATHS", "40")), 12000, 96, 50.0
PARAMS = {"VALIDADO": dict(lvl=30, tp=1.5, slatr=1.0), "AGRESIVO": dict(lvl=38, tp=2.0, slatr=1.0)}

def fit_garch(r):
    try:
        from arch import arch_model
        m = arch_model(r*100, vol="GARCH", p=1, q=1, dist="t", rescale=False).fit(disp="off")
        p = m.params; return dict(mu=p["mu"]/100, w=p["omega"]/1e4, a=p["alpha[1]"], b=p["beta[1]"], nu=max(p["nu"], 3.0))
    except Exception:
        v = r.var(); return dict(mu=0.0, w=v*0.05, a=0.05, b=0.90, nu=5.0)

def garch_path(g, n, rng, v0):
    r = np.empty(n); v = v0
    t = rng.standard_t(g["nu"], n)*np.sqrt((g["nu"]-2)/g["nu"])
    for i in range(n):
        r[i] = g["mu"] + np.sqrt(v)*t[i]; v = g["w"] + g["a"]*(r[i]-g["mu"])**2 + g["b"]*v
    return r

def build(real, mode, rng, g):
    """devuelve DataFrame OHLC sintético con la misma estructura que MT5"""
    c = real.close.values; o = real.open.values; h = real.high.values; l = real.low.values
    ret = np.log(c[1:]/c[:-1]); body_hi = np.log(h[1:]/np.maximum(o[1:], c[1:])); body_lo = np.log(np.minimum(o[1:], c[1:])/l[1:])
    vol = pd.Series(np.abs(ret)).rolling(96, min_periods=10).mean().bfill().values
    spr = real.spread.values[1:]
    R, UH, UL, SP = [], [], [], []
    while len(R) < LEN:
        use_real = mode == "REAL" or (mode == "MIXTO" and rng.random() < 0.5)
        if use_real:
            s = rng.integers(0, len(ret)-BLOCK); sl = slice(s, s+BLOCK)
            R += list(ret[sl]); UH += list(body_hi[sl]); UL += list(body_lo[sl]); SP += list(spr[sl])
        else:
            rr = garch_path(g, BLOCK, rng, np.var(ret[-2000:]))
            # rangos intravela de velas reales con volatilidad similar
            idx = np.searchsorted(np.sort(vol), np.abs(rr)); order = np.argsort(vol)
            pick = order[np.clip(idx + rng.integers(-50, 50, BLOCK), 0, len(vol)-1)]
            R += list(rr); UH += list(body_hi[pick]); UL += list(body_lo[pick]); SP += list(spr[pick])
    R, UH, UL, SP = (np.array(x[:LEN]) for x in (R, UH, UL, SP))
    close = c[-1]*np.exp(np.cumsum(R)); opn = np.r_[c[-1], close[:-1]]
    high = np.maximum(opn, close)*np.exp(np.abs(UH)); low = np.minimum(opn, close)*np.exp(-np.abs(UL))
    t = pd.date_range("2030-01-01", periods=LEN, freq="15min")
    df = pd.DataFrame({"time": t, "open": opn, "high": high, "low": low, "close": close, "spread": SP.astype(int)})
    df = df[t.dayofweek < 5].reset_index(drop=True)                       # sin fines de semana
    h4 = df.set_index("time").resample("4h").agg({"open": "first", "high": "max", "low": "min", "close": "last"}).dropna().reset_index()
    return df, h4

def metrics(res, usd):
    if not res: return dict(n=0, ret=0, dd=0, pf=0, exp=0)
    pnl = np.array([x[1]*x[2]*usd for x in res]); R = np.array([x[1] for x in res])
    eq = equity_path(pnl, START); pk = np.maximum.accumulate(eq)
    w, l = pnl[pnl > 0].sum(), -pnl[pnl < 0].sum()
    return dict(n=len(R), ret=float((eq[-1]-START)/START*100), dd=float(((pk-eq)/pk).max()*100),
                pf=float(w/l) if l > 0 else 9.9, exp=float(R.mean()), ruin=bool((eq <= START/2).any()))

if __name__ == "__main__":
    t0 = time.time(); mt5.initialize(); info = mt5.symbol_info(SYM); usd = info.trade_contract_size*info.volume_min
    real = load(SYM, mt5.TIMEFRAME_M15, 99000); mt5.shutdown()
    print(f"datos reales: {len(real)} velas M15 {real.time.iloc[0]} -> {real.time.iloc[-1]}", flush=True)
    g = fit_garch(np.log(real.close).diff().dropna().values[-20000:]); print("GARCH:", {k: round(v, 6) for k, v in g.items()}, flush=True)
    rng = np.random.default_rng(42); rows = []
    for mode in ("REAL", "SIM", "MIXTO"):
        for k in range(N_PATHS):
            df, h4 = build(real, mode, rng, g); F = feats(df, h4)
            for pname, P in PARAMS.items():
                m = metrics(sim(F, s_pullback(F, P), info.point, 96), usd); rows.append(dict(mode=mode, path=k, params=pname, **m))
        print(f"  {mode}: {N_PATHS} trayectorias listas ({time.time()-t0:.0f}s)", flush=True)
    df = pd.DataFrame(rows); df.to_csv(os.path.join(OUT, "mc_paths.csv"), index=False)
    summ = {}
    for (mode, p), d in df.groupby(["mode", "params"]):
        summ[f"{mode}·{p}"] = dict(paths=len(d), trades_med=float(d.n.median()), p_profit=float((d.ret > 0).mean()),
                                   ret_p5=float(d.ret.quantile(.05)), ret_p50=float(d.ret.median()), ret_p95=float(d.ret.quantile(.95)),
                                   dd_p50=float(d.dd.median()), dd_p95=float(d.dd.quantile(.95)), pf_med=float(d.pf.median()),
                                   p_ruin50=float(d.ruin.mean()))
    json.dump(summ, open(os.path.join(OUT, "mc_report.json"), "w"), indent=2)
    print(pd.DataFrame(summ).T.round(2).to_string()); print("LISTO")
