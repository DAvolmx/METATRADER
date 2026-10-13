"""
gm_ml.py — Capa de aprendizaje automático de GOLD MASTER (investigación, offline).

Tres piezas, todas sobre datos reales importados con offline.mt5_import:

  1. RÉGIMEN DE MERCADO (HMM gaussiano, hmmlearn)
     Ajusta un HMM de 3 estados sobre features de M15 (retorno, volatilidad,
     rango relativo) usando SOLO el tramo de entrenamiento, y decodifica todo
     el histórico. Ordena los estados por volatilidad -> {calmo, normal, agitado}.
     Mide la esperanza de la estrategia DENTRO de cada régimen => aprende CUÁNDO
     operar (y cuándo no). Esto ataca "detectar variaciones y microvariaciones".

  2. META-LABELING CON WALK-FORWARD PURGADO
     Reutiliza gm_optimizer.ml_features / signals / simulate para generar las
     operaciones, y entrena un clasificador (HistGradientBoosting) en ventanas
     crecientes: entrena con el pasado, predice el bloque siguiente, con EMBARGO
     entre train y test para no filtrar información. Agrega AUC fuera de muestra
     y compara la esperanza de "operar todo" vs "operar solo lo que el modelo
     aprueba". Umbral FIJO antes de leer resultados (sin elegir a posteriori).

  3. MODELO LINEAL EXPORTABLE
     Entrena una regresión logística estandarizada y vuelca sus coeficientes a
     CSV (z=(x-mean)/std ; p=sigmoide(b0+Σw·z)) para que el EA en MQL5 pueda
     puntuar señales sin DLLs. Investigación: NO promociona parámetros solo.

Nada aquí despliega a producción automáticamente.
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

import gm_optimizer as go                      # noqa: E402
from mt5_import import load_mt5, resample      # noqa: E402

OUT = HERE / "out_offline"; OUT.mkdir(exist_ok=True)
POINT, USD_PER_PRICE = 0.01, 1.0
REGIME_NAMES = ("calmo", "normal", "agitado")

DEFAULT_P = dict(fast=21, slow=55, minscore=4, tp=2.0, slatr=1.2, be=1.5, lock=0.3,
                 chdev=2.0, session=False, maxbars=240)
BEST_P = {**DEFAULT_P, "fast": 34, "slow": 89, "minscore": 5, "tp": 1.5, "slatr": 1.2}


# ───────────────────────── 1. Régimen de mercado (HMM) ─────────────────────────
def regime_hmm(m15: pd.DataFrame, train_frac: float = 0.70, n_states: int = 3, seed: int = 0):
    """Devuelve (estados por vela M15, orden vol asc, nombres). Ajuste solo en train."""
    from hmmlearn.hmm import GaussianHMM
    from sklearn.preprocessing import StandardScaler
    c = m15["close"].to_numpy(float)
    r = np.diff(np.log(c), prepend=np.log(c[0]))
    vol = pd.Series(np.abs(r)).rolling(20, min_periods=1).mean().to_numpy()
    rng = ((m15["high"] - m15["low"]) / m15["close"]).to_numpy(float)
    X = np.column_stack([r, vol, rng])
    X = np.nan_to_num(X, nan=0.0, posinf=0.0, neginf=0.0)
    split = int(len(X) * train_frac)
    # Los retornos del oro son ~1e-3: sin estandarizar, el HMM con covarianza diagonal
    # colapsa en un único estado. Escalamos con estadística SOLO del tramo de train.
    sc = StandardScaler().fit(X[:split])
    Xs = sc.transform(X)
    model = GaussianHMM(n_components=n_states, covariance_type="full", n_iter=500,
                        tol=1e-4, random_state=seed)
    model.fit(Xs[:split])
    states = model.predict(Xs)
    # ordenar estados por volatilidad media (col 1) ascendente -> nombres estables
    order = np.argsort([model.means_[s, 1] for s in range(n_states)])
    remap = {old: new for new, old in enumerate(order)}
    states = np.array([remap[s] for s in states])
    return states, split


def regime_edge(m1, m15, states, split_m15, P):
    """Esperanza de la estrategia por régimen (solo operaciones del tramo TEST)."""
    f = go.features(m1[["time", "open", "high", "low", "close", "spread"]],
                    m15[["time", "open", "high", "low", "close", "spread"]])
    sigs = go.signals(f, P)
    res = go.simulate(f, P, sigs, POINT)
    # mapear cada operación (barra M1) al régimen M15 vigente en su apertura
    m15_close = (m15["time"] + pd.Timedelta(minutes=15)).to_numpy()
    m1_time = m1["time"].to_numpy()
    split_bar_m1 = int(len(m1) * 0.70)
    rows = []
    for x in res:
        b = x.signal_bar
        if b >= len(m1_time):
            continue
        k = int(np.searchsorted(m15_close, m1_time[b], side="right")) - 1
        if k < 0 or k >= len(states):
            continue
        rows.append((states[k], float(x.r_multiple), b >= split_bar_m1))
    df = pd.DataFrame(rows, columns=["regime", "R", "is_test"])
    out = {}
    for seg, sub in (("todo", df), ("test", df[df.is_test])):
        g = {}
        for s in range(3):
            d = sub[sub.regime == s]["R"]
            g[REGIME_NAMES[s]] = dict(n=int(len(d)), exp=float(d.mean()) if len(d) else None,
                                      wr=float((d > 0).mean() * 100) if len(d) else None)
        out[seg] = g
    return out, int(len(df))


# ───────────────────── 2. Meta-labeling walk-forward purgado ─────────────────────
def walkforward_metalabel(m1, m15, P, folds: int = 4, embargo: int = 2, threshold: float = 0.5):
    from sklearn.ensemble import HistGradientBoostingClassifier
    from sklearn.metrics import roc_auc_score
    f = go.features(m1[["time", "open", "high", "low", "close", "spread"]],
                    m15[["time", "open", "high", "low", "close", "spread"]])
    sigs = go.signals(f, P)
    res = go.simulate(f, P, sigs, POINT)
    if len(res) < 80:
        return {"error": f"pocas operaciones ({len(res)}) para walk-forward"}
    res = sorted(res, key=lambda x: x.signal_bar)
    X = np.nan_to_num(np.array([go.ml_features(f, x.signal_bar, x.direction) for x in res], float),
                      nan=0.0, posinf=0.0, neginf=0.0)
    y = np.array([int(x.r_multiple > 0) for x in res])
    R = np.array([x.r_multiple for x in res])
    n = len(res)
    bounds = [int(n * i / (folds + 1)) for i in range(folds + 2)]  # ventana creciente
    agg_p, agg_R, agg_y, per_fold = [], [], [], []
    for k in range(1, folds + 1):
        tr_end = bounds[k]                      # entrena [0, tr_end)
        te_lo, te_hi = bounds[k], bounds[k + 1] # test [bounds[k], bounds[k+1])
        tr_idx = np.arange(0, max(0, tr_end - embargo))
        te_idx = np.arange(te_lo, te_hi)
        if len(tr_idx) < 50 or len(te_idx) < 10 or len(np.unique(y[tr_idx])) < 2:
            continue
        gb = HistGradientBoostingClassifier(max_depth=3, learning_rate=0.05, max_iter=300,
                                            l2_regularization=1.0, random_state=1)
        gb.fit(X[tr_idx], y[tr_idx])
        p = gb.predict_proba(X[te_idx])[:, 1]
        agg_p += list(p); agg_R += list(R[te_idx]); agg_y += list(y[te_idx])
        kept = p >= threshold
        per_fold.append(dict(fold=k, train=len(tr_idx), test=len(te_idx),
                             base_exp=float(R[te_idx].mean()),
                             kept=int(kept.sum()),
                             kept_exp=float(R[te_idx][kept].mean()) if kept.any() else None))
    if not per_fold:
        return {"error": "ninguna ventana con datos suficientes"}
    agg_p, agg_R, agg_y = map(np.array, (agg_p, agg_R, agg_y))
    kept = agg_p >= threshold
    auc = float(roc_auc_score(agg_y, agg_p)) if len(np.unique(agg_y)) > 1 else None
    return dict(folds=per_fold, oos_trades=int(len(agg_R)), auc_oos=auc, threshold=threshold,
                base_exp=float(agg_R.mean()), base_wr=float((agg_R > 0).mean() * 100),
                kept=int(kept.sum()), kept_exp=float(agg_R[kept].mean()) if kept.any() else None,
                kept_wr=float((agg_R[kept] > 0).mean() * 100) if kept.any() else None,
                status="research_only", promotion_allowed=False)


# ───────────────────── 3. Modelo lineal exportable a MQL5 ─────────────────────
def export_linear(m1, m15, P, train_frac: float = 0.70):
    from sklearn.linear_model import LogisticRegression
    from sklearn.preprocessing import StandardScaler
    f = go.features(m1[["time", "open", "high", "low", "close", "spread"]],
                    m15[["time", "open", "high", "low", "close", "spread"]])
    res = sorted(go.simulate(f, P, go.signals(f, P), POINT), key=lambda x: x.signal_bar)
    if len(res) < 80:
        return {"error": "pocas operaciones para el modelo lineal"}
    X = np.nan_to_num(np.array([go.ml_features(f, x.signal_bar, x.direction) for x in res], float),
                      nan=0.0, posinf=0.0, neginf=0.0)
    y = np.array([int(x.r_multiple > 0) for x in res])
    split = int(len(res) * train_frac)
    if len(np.unique(y[:split])) < 2:
        return {"error": "train sin ambas clases"}
    sc = StandardScaler().fit(X[:split])
    lr = LogisticRegression(C=0.5, max_iter=2000).fit(sc.transform(X[:split]), y[:split])
    path = OUT / "ml_linear_XAUUSD.csv"
    pd.DataFrame({"feature": ["__intercept__"] + go.ML_COLS,
                  "mean": [0.0] + list(sc.mean_), "std": [1.0] + list(sc.scale_),
                  "w": [float(lr.intercept_[0])] + list(map(float, lr.coef_[0]))}
                 ).to_csv(path, index=False)
    return {"file": str(path.name), "features": go.ML_COLS, "train_trades": int(split)}


def run(csv_path: str, P: dict | None = None) -> dict:
    P = P or BEST_P
    m1 = load_mt5(csv_path); m15 = resample(m1, "M15")
    states, split_m15 = regime_hmm(m15)
    counts = {REGIME_NAMES[s]: int((states == s).sum()) for s in range(3)}
    edge, ntr = regime_edge(m1, m15, states, split_m15, P)
    wf = walkforward_metalabel(m1, m15, P)
    lin = export_linear(m1, m15, P)
    rep = dict(params={k: P[k] for k in ("fast", "slow", "minscore", "tp", "slatr")},
               regime=dict(bars_m15=int(len(m15)), counts=counts, edge=edge, trades_mapped=ntr),
               walkforward=wf, linear_export=lin)
    (OUT / "ml_report.json").write_text(json.dumps(rep, indent=2, ensure_ascii=False), encoding="utf-8")
    return rep


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("uso: python gm_ml.py <XAUUSD_M1.csv>"); raise SystemExit(2)
    r = run(sys.argv[1])
    print("\n=== RÉGIMEN (HMM 3 estados sobre M15) ===")
    print("velas por régimen:", r["regime"]["counts"])
    print("esperanza de la estrategia por régimen (TEST fuera de muestra):")
    for name, d in r["regime"]["edge"]["test"].items():
        e = "—" if d["exp"] is None else f"{d['exp']:+.3f}R"
        wr = "—" if d["wr"] is None else f"{d['wr']:.0f}%"
        print(f"  {name:8s}: n={d['n']:3d}  exp={e}  wr={wr}")
    print("\n=== META-LABELING walk-forward purgado ===")
    wf = r["walkforward"]
    if "error" in wf:
        print(" ", wf["error"])
    else:
        print(f"  AUC fuera de muestra: {wf['auc_oos']:.3f}  ({wf['oos_trades']} ops en {len(wf['folds'])} ventanas)")
        print(f"  Operar TODO : exp={wf['base_exp']:+.3f}R  wr={wf['base_wr']:.0f}%")
        ke = "—" if wf['kept_exp'] is None else f"{wf['kept_exp']:+.3f}R"
        print(f"  Operar FILTRADO por ML (p>={wf['threshold']}): exp={ke}  "
              f"wr={wf['kept_wr']:.0f}%  ({wf['kept']}/{wf['oos_trades']} ops)")
    print("\n=== modelo lineal exportable ===")
    print(" ", r["linear_export"])
    print(f"\nReport -> {OUT/'ml_report.json'}")
