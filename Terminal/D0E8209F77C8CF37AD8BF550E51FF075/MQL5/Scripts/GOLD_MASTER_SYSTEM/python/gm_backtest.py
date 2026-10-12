# -*- coding: utf-8 -*-
"""
GOLD MASTER — Backtester ORB + Optimizador Walk-Forward + Monte Carlo  v1.0
===========================================================================
Uso:
  python gm_backtest.py --symbol XAUUSD --from 2025-01-01 --to 2026-09-29
  python gm_backtest.py --csv XAUUSD_M1.csv            (export M1 de MT5)
  python gm_backtest.py --symbol XAUUSD --quick        (menos combinaciones)

Qué hace:
  1. Simula la estrategia ORB EXACTAMENTE como el EA (hora de rango, buffer ATR,
     SL al lado opuesto, RR, OCO, breakeven, cancelación NY) sobre velas M1,
     con spread real y supuesto pesimista (si SL y TP caen en la misma vela → SL).
  2. Optimiza parámetros con WALK-FORWARD (entrena N meses, prueba el siguiente
     mes que NO vio). Sólo el resultado fuera de muestra (OOS) cuenta.
  3. Monte Carlo sobre los trades OOS: barajado de orden, bootstrap, trades
     saltados y deslizamiento → distribución de drawdown, prob. de ruina, etc.
  4. Guarda: bt_report.html (si hay plotly), bt_trades.csv, bt_summary.json
     y ORB_best.set  → Strategy Tester › Inputs › botón derecho › Cargar.
"""
import os, sys, json, math, argparse, itertools, random, datetime as dt
import numpy as np
import pandas as pd

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

# ══════════════════════════════════════════════════════════════════
# DATOS
# ══════════════════════════════════════════════════════════════════
def load_mt5(symbol, d0, d1):
    import MetaTrader5 as mt5
    if not mt5.initialize():
        raise SystemExit("No se pudo conectar a MT5 (¿terminal abierto?)")
    mt5.symbol_select(symbol, True)
    r = mt5.copy_rates_range(symbol, mt5.TIMEFRAME_M1, d0, d1)
    info = mt5.symbol_info(symbol)
    if r is None or len(r) == 0:
        raise SystemExit(f"Sin datos M1 para {symbol}. Abre un gráfico M1 y desplázate atrás para descargar historial.")
    df = pd.DataFrame(r)
    df["time"] = pd.to_datetime(df["time"], unit="s")
    spec = {"contract": info.trade_contract_size, "point": info.point, "vol_min": info.volume_min,
            "vol_step": info.volume_step}
    return df.set_index("time"), spec


def load_csv(path):
    """Acepta el CSV que exporta MT5 (Centro de historial) o columnas time,open,high,low,close,..."""
    df = pd.read_csv(path, sep=None, engine="python")
    df.columns = [c.strip("<>").lower() for c in df.columns]
    if "date" in df.columns and "time" in df.columns:
        df["time"] = pd.to_datetime(df["date"].astype(str) + " " + df["time"].astype(str))
    else:
        df["time"] = pd.to_datetime(df["time"])
    df = df.rename(columns={"tickvol": "tick_volume", "vol": "tick_volume"})
    if "spread" not in df.columns:
        df["spread"] = 16
    return df.set_index("time")[["open", "high", "low", "close", "spread"]], \
        {"contract": 100.0, "point": 0.01, "vol_min": 0.01, "vol_step": 0.01}


def synthetic(days=400, seed=1):
    """Datos sintéticos para probar el código sin MT5."""
    rng = np.random.default_rng(seed)
    idx = pd.date_range("2025-01-01", periods=days * 1440, freq="1min")
    idx = idx[idx.dayofweek < 5]
    ret = rng.standard_t(4, len(idx)) * 0.25
    c = 2600 + np.cumsum(ret)
    o = np.r_[c[0], c[:-1]]
    h = np.maximum(o, c) + np.abs(rng.normal(0, 0.15, len(c)))
    l = np.minimum(o, c) - np.abs(rng.normal(0, 0.15, len(c)))
    return pd.DataFrame({"open": o, "high": h, "low": l, "close": c, "spread": 16}, index=idx), \
        {"contract": 100.0, "point": 0.01, "vol_min": 0.01, "vol_step": 0.01}

# ══════════════════════════════════════════════════════════════════
# PRE-CÁLCULO POR DÍA
# ══════════════════════════════════════════════════════════════════
def prepare(df):
    """Convierte a arrays numpy por día (rápido) + ATR/EMA de H1."""
    h1 = df.resample("1h").agg({"open": "first", "high": "max", "low": "min", "close": "last"}).dropna()
    tr = pd.concat([h1.high - h1.low, (h1.high - h1.close.shift()).abs(), (h1.low - h1.close.shift()).abs()], axis=1).max(axis=1)
    h1["atr"] = tr.rolling(14).mean()
    h1["ema50"] = h1.close.ewm(span=50).mean()
    days = {}
    for day, g in df.groupby(df.index.date):
        if len(g) > 300:
            days[day] = dict(hour=g.index.hour.values, t=g.index.values, H=g.high.values, L=g.low.values,
                             C=g.close.values, S=g.spread.values.astype(float))
    h1a = dict(t=h1.index.values, atr=h1.atr.values, ema=h1.ema50.values, c=h1.close.values)
    return days, h1a

# ══════════════════════════════════════════════════════════════════
# SIMULADOR
#   simulate_day → trades del día en unidades R (independiente del balance) y cacheado,
#   simulate    → compone el balance aplicando % de riesgo (interés compuesto)
# ══════════════════════════════════════════════════════════════════
DEFAULT = dict(start_hour=7, end_hour=8, buffer_atr=0.1, rr=2.0, sl_mode="opposite", sl_pad_atr=0.25,
               range_min=0.4, range_max=2.0, be_r=1.0, cancel_hour=17, close_hour=21, oco=True,
               trend_filter=False, risk_pct=1.0,
               commission_lot=0.0,   # Escenario USD/lote/lado; cero NO confirma tarifa de la cuenta
               contract_size=100.0)  # contrato estándar XAUUSDmicro = 1 oz × 100 micro
_CACHE = {}
_PKEYS = ("start_hour", "end_hour", "buffer_atr", "rr", "sl_mode", "sl_pad_atr", "range_min", "range_max",
          "be_r", "cancel_hour", "close_hour", "oco", "trend_filter")


def simulate_day(day, g, h1, pt, p):
    key = (day,) + tuple(p[k] for k in _PKEYS)
    if key in _CACHE:
        return _CACHE[key]
    out = []
    hr = g["hour"]
    m = (hr >= p["start_hour"]) & (hr < p["end_hour"])
    if m.sum() < 20:
        _CACHE[key] = out; return out
    hi, lo = g["H"][m].max(), g["L"][m].min()
    t_place = np.datetime64(pd.Timestamp(day) + pd.Timedelta(hours=p["end_hour"]))
    k = np.searchsorted(h1["t"], t_place) - 1
    if k < 0 or np.isnan(h1["atr"][k]):
        _CACHE[key] = out; return out
    atr, ema, lastc = h1["atr"][k], h1["ema"][k], h1["c"][k]
    rng = hi - lo
    if not (p["range_min"] * atr < rng < p["range_max"] * atr):
        _CACHE[key] = out; return out
    buf, pad, mid = p["buffer_atr"] * atr, p["sl_pad_atr"] * atr, (hi + lo) / 2
    pend = []
    if not p["trend_filter"] or lastc > ema:
        e = hi + buf; sl = (lo - pad) if p["sl_mode"] == "opposite" else (mid - pad)
        pend.append([1, e, sl, e + (e - sl) * p["rr"]])
    if not p["trend_filter"] or lastc < ema:
        e = lo - buf; sl = (hi + pad) if p["sl_mode"] == "opposite" else (mid + pad)
        pend.append([-1, e, sl, e - (sl - e) * p["rr"]])
    sm = (g["t"] >= t_place) & (hr < p["close_hour"])
    idx = np.nonzero(sm)[0]
    if len(idx) == 0 or not pend:
        _CACHE[key] = out; return out
    H, L, C, S, T, HR = g["H"], g["L"], g["C"], g["S"] * pt, g["t"], hr
    pos = []
    for n, i in enumerate(idx):
        last = n == len(idx) - 1
        for o in pend[:]:
            if HR[i] >= p["cancel_hour"]:
                pend.remove(o); continue
            if (o[0] == 1 and H[i] + S[i] >= o[1]) or (o[0] == -1 and L[i] <= o[1]):
                pend.remove(o)
                pos.append(dict(side=o[0], fill=o[1], sl=o[2], tp=o[3], risk=abs(o[1] - o[2]), be=False, t_in=T[i]))
                if p["oco"]:
                    pend.clear()
        for q in pos[:]:
            s = q["side"]
            hit_sl = (L[i] <= q["sl"]) if s == 1 else (H[i] + S[i] >= q["sl"])
            hit_tp = (H[i] >= q["tp"]) if s == 1 else (L[i] + S[i] <= q["tp"])
            ex = why = None
            if hit_sl:   ex, why = q["sl"], ("BE" if q["be"] else "SL")      # pesimista
            elif hit_tp: ex, why = q["tp"], "TP"
            elif last:   ex, why = (C[i] if s == 1 else C[i] + S[i]), "TIME"
            if ex is None:
                fav = (H[i] - q["fill"]) if s == 1 else (q["fill"] - L[i] - S[i])
                if p["be_r"] > 0 and not q["be"] and fav >= p["be_r"] * q["risk"]:
                    q["sl"] = q["fill"] + s * S[i]; q["be"] = True
                continue
            out.append(dict(date=str(day), t_in=pd.Timestamp(q["t_in"]), t_out=pd.Timestamp(T[i]), side=s,
                            entry=q["fill"], exit=ex, risk_px=q["risk"], r=(ex - q["fill"]) * s / q["risk"], why=why))
            pos.remove(q)
    _CACHE[key] = out
    return out


def simulate(days, h1, spec, p, balance0=3000.0, dates=None):
    bal, rows = balance0, []
    for day in (dates if dates is not None else sorted(days)):
        g = days.get(day)
        if g is None:
            continue
        for t in simulate_day(day, g, h1, spec["point"], p):
            lot = bal * p["risk_pct"] / 100.0 / (t["risk_px"] / spec["point"] * (spec.get("tick_value", 0.01)))
            lot = max(spec.get("vol_min", 0.01), round(lot / spec.get("vol_step", 0.01)) * spec.get("vol_step", 0.01))
            # Comisión entrada + salida (ida y vuelta)
            comm_rt = 2 * p.get("commission_lot", 0.0) * lot
            pnl_gross = t["r"] * bal * p["risk_pct"] / 100
            pnl = pnl_gross - comm_rt
            bal += pnl
            rows.append(dict(t, lot=lot, pnl_gross=pnl_gross, commission=comm_rt, pnl=pnl, balance=bal))
    return pd.DataFrame(rows)

# ══════════════════════════════════════════════════════════════════
# MÉTRICAS
# ══════════════════════════════════════════════════════════════════
def metrics(tr, balance0=3000.0):
    if tr is None or len(tr) == 0:
        return dict(trades=0, net=0, pf=0, wr=0, exp_r=0, maxdd_pct=0, sqn=0, score=-1e9)
    eq = balance0 + tr.pnl.cumsum()
    peak = eq.cummax()
    dd = ((peak - eq) / peak).max() * 100
    wins, loss = tr.pnl[tr.pnl > 0].sum(), -tr.pnl[tr.pnl < 0].sum()
    pf = wins / loss if loss > 0 else (9.99 if wins > 0 else 0)
    r = tr.r
    sqn = (r.mean() / r.std() * math.sqrt(len(r))) if len(r) > 1 and r.std() > 0 else 0
    daily = tr.groupby("date").pnl.sum()
    sharpe = daily.mean() / daily.std() * math.sqrt(252) if len(daily) > 2 and daily.std() > 0 else 0
    # score: robusto, premia expectativa y nº de trades, castiga DD
    score = r.mean() * math.sqrt(len(r)) - 0.05 * dd if len(r) >= 15 else -1e9
    f = lambda x: float(x)
    return dict(trades=int(len(tr)), net=round(f(tr.pnl.sum()), 2), pf=round(f(pf), 2), wr=round(f((tr.pnl > 0).mean() * 100), 1),
                exp_r=round(f(r.mean()), 3), maxdd_pct=round(f(dd), 2), sqn=round(f(sqn), 2), sharpe=round(f(sharpe), 2),
                score=round(f(score), 3))

# ══════════════════════════════════════════════════════════════════
# OPTIMIZACIÓN WALK-FORWARD
# ══════════════════════════════════════════════════════════════════
GRID = dict(start_hour=[6, 7, 8], buffer_atr=[0.05, 0.1, 0.2], rr=[1.5, 2.0, 2.5, 3.0],
            sl_mode=["opposite", "mid"], range_min=[0.3, 0.5], range_max=[1.5, 2.0, 3.0],
            be_r=[0.0, 1.0, 1.5], trend_filter=[False, True])


def sample_grid(n, seed=7):
    keys = list(GRID)
    allc = list(itertools.product(*[GRID[k] for k in keys]))
    random.Random(seed).shuffle(allc)
    out = []
    for c in allc[:n]:
        p = dict(DEFAULT); p.update(dict(zip(keys, c))); p["end_hour"] = p["start_hour"] + 1
        out.append(p)
    return out


def walk_forward(days, h1, spec, is_months=4, oos_months=1, n_combos=150, balance0=3000.0):
    dates = sorted(days)
    months = sorted({(d.year, d.month) for d in dates})
    combos = sample_grid(n_combos)
    oos_trades, windows = [], []
    for k in range(is_months, len(months), oos_months):
        is_m, oos_m = set(months[k - is_months:k]), set(months[k:k + oos_months])
        is_d = [d for d in dates if (d.year, d.month) in is_m]
        oos_d = [d for d in dates if (d.year, d.month) in oos_m]
        if not oos_d:
            break
        best, best_s = None, -1e9
        for p in combos:
            s = metrics(simulate(days, h1, spec, p, balance0, is_d), balance0)["score"]
            if s > best_s:
                best, best_s = p, s
        t = simulate(days, h1, spec, best, balance0, oos_d)
        m = metrics(t, balance0)
        windows.append(dict(period=f"{oos_d[0]}→{oos_d[-1]}", is_score=best_s, oos=m,
                            params={k: best[k] for k in GRID}))
        oos_trades.append(t)
        print(f"  WF {oos_d[0]}→{oos_d[-1]}  IS score {best_s:6.2f} | OOS trades {m['trades']:3d} "
              f"net {m['net']:8.2f} PF {m['pf']:4.2f} DD {m['maxdd_pct']:5.2f}%")
    oos = pd.concat(oos_trades, ignore_index=True) if oos_trades else pd.DataFrame()
    return oos, windows


def stable_params(windows):
    """Parámetros más elegidos en las ventanas (moda) → lo que se lleva a MT5."""
    p = dict(DEFAULT)
    for k in GRID:
        vals = [w["params"][k] for w in windows]
        if vals:
            p[k] = max(set(vals), key=vals.count)
    p["end_hour"] = p["start_hour"] + 1
    return p

# ══════════════════════════════════════════════════════════════════
# MONTE CARLO
# ══════════════════════════════════════════════════════════════════
def monte_carlo(r_list, risk_pct=1.0, balance0=3000.0, n=5000, skip=0.10, slip_r=0.05, ruin_dd=30.0, seed=42):
    rng = np.random.default_rng(seed)
    r = np.asarray(r_list, float)
    if len(r) < 10:
        return {}
    finals, dds = [], []
    for i in range(n):
        s = rng.choice(r, len(r), replace=True)                     # bootstrap
        s = s[rng.random(len(s)) > skip] - slip_r                   # trades perdidos + deslizamiento
        eq = balance0 * np.cumprod(1 + s * risk_pct / 100)          # interés compuesto al % de riesgo
        peak = np.maximum.accumulate(np.r_[balance0, eq])
        dd = ((peak[1:] - eq) / peak[1:]).max() * 100 if len(eq) else 0
        finals.append(eq[-1] if len(eq) else balance0); dds.append(dd)
    finals, dds = np.array(finals), np.array(dds)
    pct = lambda a, q: round(float(np.percentile(a, q)), 2)
    # Riesgo máximo por trade para que DD95 < 20%
    safe = risk_pct * 20 / max(pct(dds, 95), 1e-9)
    return dict(n=n, final_p5=pct(finals, 5), final_p50=pct(finals, 50), final_p95=pct(finals, 95),
                dd_p50=pct(dds, 50), dd_p95=pct(dds, 95), dd_p99=pct(dds, 99),
                prob_profit=round(float((finals > balance0).mean() * 100), 1),
                prob_ruin=round(float((dds >= ruin_dd).mean() * 100), 2),
                risk_for_dd20_at_p95=round(safe, 2), finals=finals.tolist()[:2000], dds=dds.tolist()[:2000])

# ══════════════════════════════════════════════════════════════════
# SALIDAS
# ══════════════════════════════════════════════════════════════════
def write_set(p, path):
    lines = {"ORB_Hour_Start": p["start_hour"], "ORB_Hour_End": p["end_hour"], "ORB_RR": p["rr"],
             "ORB_Risk_Pct": p["risk_pct"], "ORB_RangeMaxH1": p["range_max"], "ORB_RangeMinH1": p["range_min"],
             "ORB_BufferATR": p["buffer_atr"], "ORB_SL_Mid": "true" if p["sl_mode"] == "mid" else "false",
             "ORB_SLPadATR": p["sl_pad_atr"], "ORB_BE_R": p["be_r"],
             "ORB_TrendFilter": "true" if p["trend_filter"] else "false", "ORB_OCO": "true"}
    with open(path, "w", encoding="utf-16") as f:        # MT5 lee .set en UTF-16
        for k, v in lines.items():
            f.write(f"{k}={v}\n")


def html_report(path, base_tr, oos_tr, mc, summary):
    try:
        import plotly.graph_objects as go
        from plotly.subplots import make_subplots
    except ImportError:
        return False
    fig = make_subplots(rows=2, cols=2, subplot_titles=("Equity: base vs Walk-Forward OOS", "R por trade (OOS)",
                                                        "Monte Carlo: balance final", "Monte Carlo: max drawdown %"))
    if len(base_tr): fig.add_trace(go.Scatter(y=base_tr.balance, name="Base (parámetros actuales)"), 1, 1)
    if len(oos_tr): fig.add_trace(go.Scatter(y=3000 + oos_tr.pnl.cumsum(), name="Walk-forward OOS"), 1, 1)
    if len(oos_tr): fig.add_trace(go.Bar(y=oos_tr.r, marker_color=np.where(oos_tr.r > 0, "#26a69a", "#ef5350"), name="R"), 1, 2)
    if mc:
        fig.add_trace(go.Histogram(x=mc["finals"], nbinsx=60, name="Final"), 2, 1)
        fig.add_trace(go.Histogram(x=mc["dds"], nbinsx=60, name="DD"), 2, 2)
    fig.update_layout(template="plotly_dark", height=850, title="GOLD MASTER — Backtest ORB")
    body = fig.to_html(full_html=False, include_plotlyjs="cdn")
    table = "<pre style='color:#ddd;background:#111;padding:12px'>" + json.dumps(summary, indent=2, default=str) + "</pre>"
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"<html><body style='background:#0d0d1a'>{body}{table}</body></html>")
    return True

# ══════════════════════════════════════════════════════════════════
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", default=os.environ.get("GM_SYMBOL", "XAUUSD"))
    ap.add_argument("--from", dest="d0", default="2025-01-01")
    ap.add_argument("--to", dest="d1", default=dt.date.today().isoformat())
    ap.add_argument("--csv")
    ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--risk", type=float, default=1.0)
    ap.add_argument("--balance", type=float, default=3000.0)
    a = ap.parse_args()

    if a.synthetic:  df, spec = synthetic()
    elif a.csv:      df, spec = load_csv(a.csv)
    else:            df, spec = load_mt5(a.symbol, dt.datetime.fromisoformat(a.d0), dt.datetime.fromisoformat(a.d1))
    print(f"Datos: {len(df):,} velas M1  {df.index[0]} → {df.index[-1]}  contrato={spec['contract']}")
    days, h1 = prepare(df)

    base = dict(DEFAULT); base["risk_pct"] = a.risk
    base_tr = simulate(days, h1, spec, base, a.balance)
    mb = metrics(base_tr, a.balance)
    print("\n[1] Parámetros actuales del EA:", mb)

    print("\n[2] Walk-forward (4 meses entrena → 1 mes prueba):")
    oos_tr, windows = walk_forward(days, h1, spec, n_combos=40 if a.quick else 150, balance0=a.balance)
    mo = metrics(oos_tr, a.balance)
    print("    OOS total:", mo)

    best = stable_params(windows) if windows else base
    best["risk_pct"] = a.risk
    full_best = simulate(days, h1, spec, best, a.balance)
    mf = metrics(full_best, a.balance)
    print("\n[3] Parámetros estables (moda de ventanas):", {k: best[k] for k in GRID}, "\n    Todo el periodo:", mf)

    src = oos_tr if len(oos_tr) >= 20 else full_best
    mc = monte_carlo(src.r.values if len(src) else [], a.risk, a.balance)
    if mc:
        print(f"\n[4] Monte Carlo ({mc['n']} sims, 10% trades perdidos, -0.05R slippage):")
        print(f"    Balance final p5/p50/p95: {mc['final_p5']} / {mc['final_p50']} / {mc['final_p95']}")
        print(f"    Max DD p50/p95/p99: {mc['dd_p50']}% / {mc['dd_p95']}% / {mc['dd_p99']}%")
        print(f"    Prob. beneficio {mc['prob_profit']}%  ·  Prob. DD≥30% {mc['prob_ruin']}%")
        print(f"    Riesgo/trade para DD95≤20%: {mc['risk_for_dd20_at_p95']}%")

    verdict = ("✅ Robusta: OOS positivo y Monte Carlo favorable" if mo["net"] > 0 and mc and mc["prob_profit"] >= 70
               else "⚠️ Marginal: operar sólo en demo / riesgo mínimo" if mo["net"] > 0
               else "❌ Sin ventaja fuera de muestra: NO operar en real con estos parámetros")
    print("\nVEREDICTO:", verdict)

    summary = dict(base=mb, walk_forward_oos=mo, best_params={k: best[k] for k in GRID}, best_full=mf,
                   monte_carlo={k: v for k, v in (mc or {}).items() if k not in ("finals", "dds")},
                   windows=windows, verdict=verdict)
    with open(os.path.join(OUT_DIR, "bt_summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, default=str)
    (oos_tr if len(oos_tr) else full_best).to_csv(os.path.join(OUT_DIR, "bt_trades.csv"), index=False)
    write_set(best, os.path.join(OUT_DIR, "ORB_best.set"))
    if html_report(os.path.join(OUT_DIR, "bt_report.html"), base_tr, oos_tr, mc, summary):
        print("Reporte: bt_report.html")
    print("Parámetros para MT5: ORB_best.set")


if __name__ == "__main__":
    main()
