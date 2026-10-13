"""
gm_robustness.py — Suite de ROBUSTEZ por transformaciones de datos.

Una ventaja real debe sobrevivir a que le cambien el mundo de debajo. Aquí se
backtestea la misma estrategia sobre variantes del histórico y se mira si el edge
aguanta o se evapora:

  identity     — datos tal cual (referencia).
  mirror       — ESPEJO vertical del precio (sube<->baja). Una estrategia simétrica
                 debe rendir parecido; si solo gana aquí o solo en identity, tiene
                 sesgo direccional (iba montada en la tendencia alcista del oro).
  reverse      — TIEMPO INVERTIDO (última vela -> primera). Si una estrategia causal
                 sigue ganando con el tiempo al revés, huele a sobreajuste/look-ahead;
                 lo sano es que PIERDA aquí.
  noise_k      — RUIDO gaussiano ~k·ATR en cada vela (varias semillas). El edge debe
                 sobrevivir a perturbaciones de microestructura; si se rompe con poco
                 ruido, era frágil.

Se agrega la esperanza fuera de muestra en cada variante y se emite un veredicto de
robustez. Reutiliza gm_channels_smc / catálogo y el motor de ejecución. Investigación.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "optimizer"))
sys.path.insert(0, str(HERE))

import gm_channels_smc as ch                                # noqa: E402
from gm_validation import simulate_orders                   # noqa: E402
from mt5_import import load_mt5, resample                   # noqa: E402

OUT = HERE / "out_offline"; OUT.mkdir(exist_ok=True)
POINT = 0.01


# ───────────────────────── transformaciones ─────────────────────────
def t_identity(df):
    return df.copy()


def t_mirror(df):
    """Espejo vertical en log-precio: sube<->baja. Alto<->bajo se intercambian."""
    o = df["open"].to_numpy(float); h = df["high"].to_numpy(float)
    l = df["low"].to_numpy(float); c = df["close"].to_numpy(float)
    piv = np.log(o[0])
    mir = lambda x: np.exp(2 * piv - np.log(x))
    out = df.copy()
    out["open"] = mir(o); out["close"] = mir(c)
    out["high"] = mir(l); out["low"] = mir(h)   # reflejar intercambia máximo y mínimo
    return out


def t_reverse(df):
    """Tiempo invertido: se recorre de la última vela a la primera."""
    r = df.iloc[::-1].reset_index(drop=True).copy()
    r["time"] = df["time"].to_numpy()            # sellos de tiempo ascendentes
    o = r["open"].to_numpy(float).copy(); c = r["close"].to_numpy(float).copy()
    r["open"], r["close"] = c, o                 # al ir hacia atrás, apertura<->cierre
    return r


def t_noise(df, k=0.3, seed=0):
    """Ruido gaussiano ~k·ATR por vela, manteniendo coherencia OHLC."""
    rng = np.random.default_rng(seed)
    c = df["close"].to_numpy(float); h = df["high"].to_numpy(float); l = df["low"].to_numpy(float)
    pc = np.r_[c[0], c[:-1]]
    tr = np.maximum(h - l, np.maximum(np.abs(h - pc), np.abs(l - pc)))
    atr = pd.Series(tr).ewm(alpha=1 / 14, adjust=False).mean().to_numpy()
    eps = rng.normal(0, 1, len(c)) * k * atr
    out = df.copy()
    for col in ("open", "high", "low", "close"):
        out[col] = df[col].to_numpy(float) + eps
    hi = np.maximum.reduce([out["open"], out["close"], out["high"]])
    lo = np.minimum.reduce([out["open"], out["close"], out["low"]])
    out["high"] = hi; out["low"] = lo
    return out


def eval_channels(bars, P, split_frac=0.70):
    feats, orders = ch.build_orders(bars, P)
    n = len(bars["close"]); split = int(n * split_frac)
    pk = lambda res: [(x[0], x[1], x[2]) for x in res]
    tr = pk(simulate_orders(feats, orders, POINT, P["maxbars"], 0, 0, 0, 0, 0, split))
    te = pk(simulate_orders(feats, orders, POINT, P["maxbars"], 0, 0, 0, 0, split, n))
    return ch._metrics(tr), ch._metrics(te)


def run(csv_path, tf="H1", P=None, noise_levels=(0.2, 0.5), noise_seeds=(1, 2, 3)):
    P = {**ch.DEFAULTS, **(P or {})}
    bars = resample(load_mt5(csv_path), tf)
    variants = {"identity": t_identity(bars), "mirror": t_mirror(bars), "reverse": t_reverse(bars)}
    results = {}
    for name, b in variants.items():
        tr, te = eval_channels(b, P)
        results[name] = dict(train=tr, test=te)
    # ruido: media de esperanza OOS sobre semillas
    for k in noise_levels:
        exps, pfs, ns = [], [], []
        for s in noise_seeds:
            tr, te = eval_channels(t_noise(bars, k, s), P)
            if te.get("n", 0) >= 20:
                exps.append(te["expectancy_R"]); pfs.append(te["profit_factor"]); ns.append(te["n"])
        results[f"noise_{k}"] = dict(test=dict(n=int(np.mean(ns)) if ns else 0,
                                     expectancy_R=float(np.mean(exps)) if exps else None,
                                     profit_factor=float(np.mean(pfs)) if pfs else None,
                                     seeds=len(exps)))
    # veredicto de robustez
    idt = results["identity"]["test"]; mir = results["mirror"]["test"]; rev = results["reverse"]["test"]
    noise_ok = all(results[f"noise_{k}"]["test"]["expectancy_R"] is not None and
                   results[f"noise_{k}"]["test"]["expectancy_R"] > 0 for k in noise_levels)
    verdict = []
    verdict.append("identity+" if idt.get("expectancy_R", -9) > 0 else "identity-")
    verdict.append("simétrica" if (idt.get("expectancy_R", -9) > 0 and mir.get("expectancy_R", -9) > 0)
                   else "sesgo-direccional")
    verdict.append("causal-ok" if rev.get("expectancy_R", 9) <= idt.get("expectancy_R", -9)
                   else "sospecha-overfit(gana-en-reverse)")
    verdict.append("ruido-ok" if noise_ok else "frágil-al-ruido")
    rep = dict(file=Path(csv_path).name, tf=tf, params={k: P[k] for k in ("chan_len", "band_k", "rr", "ob_displacement")},
               results=results, verdict=verdict)
    (OUT / "robustness.json").write_text(json.dumps(rep, indent=2, ensure_ascii=False, default=str), encoding="utf-8")
    return rep


def _fmt(m):
    if not m or m.get("expectancy_R") is None or m.get("n", 0) == 0:
        return "sin datos"
    pf = m.get("profit_factor")
    return f"n={m['n']:4d} exp={m['expectancy_R']:+.3f}R" + (f" PF={pf:.2f}" if pf else "")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("uso: python gm_robustness.py <M1_o_H1.csv> [TF=H1]"); raise SystemExit(2)
    tf = sys.argv[2] if len(sys.argv) > 2 else "H1"
    rep = run(sys.argv[1], tf)
    print(f"\nRobustez — {rep['file']} {tf}  params={rep['params']}")
    for name, r in rep["results"].items():
        print(f"  {name:12s} TEST {_fmt(r.get('test'))}")
    print("  VEREDICTO:", " · ".join(rep["verdict"]))
    print(f"\nReport -> {OUT/'robustness.json'}")
