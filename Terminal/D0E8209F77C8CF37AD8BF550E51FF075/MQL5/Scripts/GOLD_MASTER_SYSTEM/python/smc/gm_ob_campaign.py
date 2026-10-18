"""
gm_ob_campaign.py — Campaña de entrenamiento duro y juicio de los order blocks.

Ejecuta, en un solo lote y escribiendo resultados parciales por si se corta:

  FASE 1  Detección y barrido sobre oro REAL, con train/test por fecha.
  FASE 2  Bootstrap por bloques de la mejor especificación: ruina y drawdown.
  FASE 3  Contraste de realidad de White: corrige por haber probado N variantes.
  FASE 4  Test nulo sintético: el mismo barrido sobre caminos generados con la
          ecuación maestra, que no contienen estructura institucional.
  FASE 5  Veredicto y meta-etiquetado ML sobre los bloques reales.

Sobre la duración: lo que decide la fiabilidad es el NÚMERO DE CAMINOS nulos,
no las horas de reloj. Con 100 caminos el p-valor del test nulo tiene
resolución de 0.01, que es de sobra para decidir al 5%. `--budget-min` corta
por tiempo y el informe dice con cuántos caminos se concluyó.

Uso:
    python gm_ob_campaign.py DATOS.csv PARAMS.json --out out_campaign \
        --null-paths 120 --budget-min 110
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "core"), str(HERE.parent / "model")]

import gm_data                      # noqa: E402
import gm_ob_montecarlo as mc       # noqa: E402
import gm_ob_strategies as st       # noqa: E402
import gm_orderblocks_pro as obm    # noqa: E402
from gm_gold_sde import GoldSDE     # noqa: E402


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def phase1(df, split, out: Path):
    log("FASE 1 — deteccion y barrido sobre oro real")
    cut = df.index[int(len(df) * split)]
    tr, te = df[df.index < cut], df[df.index >= cut]
    obs_tr, obs_te = obm.detect(tr), obm.detect(te)
    log(f"  train {len(tr):,} barras / {len(obs_tr)} OB  |  "
        f"test {len(te):,} barras / {len(obs_te)} OB  (corte {cut:%Y-%m})")

    obm.summary(obs_tr).to_csv(out / "ob_summary_train.csv")
    specs = st.grid()
    log(f"  barriendo {len(specs)} especificaciones…")
    res_tr = st.sweep(tr, obs_tr, specs, min_trades=30)
    res_tr.to_csv(out / "sweep_train.csv", index=False)

    # las mismas especificaciones, sin reajustar nada, sobre el tramo de prueba
    res_te = st.sweep(te, obs_te, specs, min_trades=15)
    res_te.to_csv(out / "sweep_test.csv", index=False)

    trades_by_spec = {sp.label(): st.backtest(tr, obs_tr, sp) for sp in specs}
    return dict(cut=cut, tr=tr, te=te, obs_tr=obs_tr, obs_te=obs_te,
                specs=specs, res_tr=res_tr, res_te=res_te,
                trades_by_spec=trades_by_spec)


def phase2(ctx, out: Path):
    log("FASE 2 — bootstrap por bloques de la mejor especificacion")
    ok = ctx["res_tr"][ctx["res_tr"]["n"] >= 30]
    if ok.empty:
        return {"error": "ninguna especificacion con n>=30"}
    best = ok.iloc[0]
    t = ctx["trades_by_spec"].get(best["spec"])
    R = t["R"].to_numpy() if t is not None and not t.empty else np.array([])
    boot = {}
    for rf in (0.01, 0.02, 0.05):
        boot[f"riesgo_{int(rf*100)}pct"] = mc.bootstrap_equity(
            R, n_boot=20_000, risk_frac=rf, seed=11)
    res = {"best_spec": str(best["spec"]), "train_expectancy_R": float(best["expectancy_R"]),
           "bootstrap": boot}
    (out / "bootstrap.json").write_text(json.dumps(res, indent=2), encoding="utf-8")
    for k, v in boot.items():
        log(f"  {k}: ruina {v.get('p_ruin_pct')}%  dd_p50 {v.get('max_dd_p50_pct')}%  "
            f"final_p50 x{v.get('final_p50')}")
    return res


def phase3(ctx, out: Path):
    log("FASE 3 — contraste de realidad de White (pruebas multiples)")
    mat = mc.build_matrix(ctx["trades_by_spec"])
    log(f"  matriz {mat.shape[0]} bloques x {mat.shape[1]} especificaciones")
    rc = mc.reality_check(mat, n_boot=5_000, seed=23, min_trades=30)
    (out / "reality_check.json").write_text(json.dumps(rc, indent=2), encoding="utf-8")
    log(f"  mejor={rc.get('best_spec')}  p={rc.get('p_value')}  → {rc.get('verdict')}")
    return rc


def phase4(ctx, model, out: Path, n_paths: int, budget_min: float):
    log(f"FASE 4 — test nulo sintetico ({n_paths} caminos, limite {budget_min:.0f} min)")
    ratio = mc.calibrate_bridge(ctx["tr"])
    n_bars = len(ctx["tr"])
    log(f"  razon de amplitud intrabarra calibrada: {ratio:.3f}")
    t0 = time.time()
    rows = []
    csv = out / "synthetic_null.csv"
    for p in range(n_paths):
        if (time.time() - t0) / 60.0 > budget_min:
            log(f"  limite de tiempo alcanzado con {p} caminos")
            break
        dfs = mc.synth_ohlc(model, n_bars, ratio, seed=p * 7919, drift_annual=0.0)
        obs = obm.detect(dfs)
        if obs.empty:
            rows.append({"path": p, "n_obs": 0, "best_exp_R": np.nan})
            continue
        r = st.sweep(dfs, obs, ctx["specs"], min_trades=30)
        okr = r[r["n"] >= 30]
        rows.append({
            "path": p, "n_obs": int(len(obs)), "n_specs_ok": int(len(okr)),
            "best_exp_R": float(okr["expectancy_R"].max()) if len(okr) else np.nan,
            "median_exp_R": float(okr["expectancy_R"].median()) if len(okr) else np.nan,
            "pct_positive": (round(100.0 * float((okr["expectancy_R"] > 0).mean()), 1)
                             if len(okr) else np.nan),
            "best_spec": str(okr.iloc[0]["spec"]) if len(okr) else "",
        })
        pd.DataFrame(rows).to_csv(csv, index=False)   # parcial, por si se corta
        el = (time.time() - t0) / 60.0
        log(f"  camino {p+1}/{n_paths}: {rows[-1]['n_obs']} OB, "
            f"mejor {rows[-1]['best_exp_R']:+.3f}R  ({el:.1f} min, "
            f"{el/(p+1):.2f} min/camino)")
    return pd.DataFrame(rows)


def phase5(ctx, nulldf, out: Path):
    log("FASE 5 — veredicto y meta-etiquetado")
    ok = ctx["res_tr"][ctx["res_tr"]["n"] >= 30]
    real_best = float(ok["expectancy_R"].max()) if len(ok) else np.nan
    verdict = mc.null_verdict(real_best, nulldf["best_exp_R"].to_numpy()) \
        if not nulldf.empty else {"error": "sin caminos nulos"}
    (out / "null_verdict.json").write_text(json.dumps(verdict, indent=2), encoding="utf-8")
    log(f"  real {verdict.get('real_best_exp_R')}R vs nulo p50 {verdict.get('null_p50')}R "
        f"p90 {verdict.get('null_p90')}R → p={verdict.get('p_value')}")
    log(f"  {verdict.get('verdict')}")

    ml = meta_label(ctx)
    (out / "meta_label.json").write_text(json.dumps(ml, indent=2), encoding="utf-8")
    return verdict, ml


def meta_label(ctx) -> dict:
    """Meta-etiquetado: ¿se puede predecir QUÉ order block funciona?

    No predice el precio. Dado un bloque ya detectado y su contexto, estima la
    probabilidad de que la operación salga bien, con validación walk-forward
    purgada (sin solape entre entrenamiento y validación).
    """
    from sklearn.ensemble import HistGradientBoostingClassifier
    from sklearn.metrics import roc_auc_score

    base = st.TradeSpec(zone="full", entry="touch", tp_r=2.0)
    t = st.backtest(ctx["tr"], ctx["obs_tr"], base)
    if t.empty or len(t) < 120:
        return {"error": f"muestra insuficiente para ML: {len(t)}"}
    obs = ctx["obs_tr"].set_index("confirm_index")
    feats = obs.loc[t["confirm_index"], obm.FEATURES].astype(float)
    X = feats.to_numpy()
    y = (t["R"].to_numpy() > 0).astype(int)
    n = len(y)

    # walk-forward purgado: 5 tramos, hueco de 24 barras entre train y test
    aucs, accs = [], []
    folds = 5
    gap = 24
    for i in range(1, folds):
        cut = int(n * i / folds)
        tr_end = max(0, cut - gap)
        if tr_end < 60 or cut >= n:
            continue
        te_end = int(n * (i + 1) / folds)
        Xtr, ytr = X[:tr_end], y[:tr_end]
        Xte, yte = X[cut:te_end], y[cut:te_end]
        if len(np.unique(ytr)) < 2 or len(np.unique(yte)) < 2 or len(yte) < 20:
            continue
        clf = HistGradientBoostingClassifier(max_iter=200, learning_rate=0.05,
                                             max_depth=3, random_state=0)
        clf.fit(Xtr, ytr)
        pr = clf.predict_proba(Xte)[:, 1]
        aucs.append(float(roc_auc_score(yte, pr)))
        accs.append(float(((pr > 0.5).astype(int) == yte).mean()))
    if not aucs:
        return {"error": "no se pudo validar: tramos degenerados"}
    return {
        "n_trades": int(n), "base_win_rate_pct": round(100.0 * float(y.mean()), 2),
        "folds_validos": len(aucs),
        "auc_por_fold": [round(a, 4) for a in aucs],
        "auc_medio": round(float(np.mean(aucs)), 4),
        "acierto_medio_pct": round(100.0 * float(np.mean(accs)), 2),
        "features": obm.FEATURES,
        "verdict": ("el contexto del bloque SI discrimina (AUC>0.55)"
                    if np.mean(aucs) > 0.55 else
                    "el contexto del bloque NO discrimina: AUC indistinguible de 0.5, "
                    "o sea no se puede saber de antemano que order block funcionara"),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("data", type=Path)
    ap.add_argument("params", type=Path)
    ap.add_argument("--out", type=Path, default=Path("out_campaign"))
    ap.add_argument("--split", type=float, default=0.70)
    ap.add_argument("--null-paths", type=int, default=120)
    ap.add_argument("--budget-min", type=float, default=110.0)
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)

    df = gm_data.load(a.data)
    model = GoldSDE.from_json(a.params)
    log(f"datos: {gm_data.describe(df)}")

    ctx = phase1(df, a.split, a.out)
    b = phase2(ctx, a.out)
    rc = phase3(ctx, a.out)
    nulldf = phase4(ctx, model, a.out, a.null_paths, a.budget_min)
    verdict, ml = phase5(ctx, nulldf, a.out)

    (a.out / "CAMPAIGN.json").write_text(json.dumps({
        "datos": gm_data.describe(df), "corte": str(ctx["cut"]),
        "n_ob_train": int(len(ctx["obs_tr"])), "n_ob_test": int(len(ctx["obs_te"])),
        "n_especificaciones": len(ctx["specs"]),
        "bootstrap": b, "reality_check": rc,
        "null_paths_completados": int(len(nulldf)),
        "null_verdict": verdict, "meta_label": ml,
    }, indent=2, default=str), encoding="utf-8")
    log(f"campana completa → {a.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
