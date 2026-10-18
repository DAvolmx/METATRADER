"""
gm_calibrate.py — Calibra la ecuación maestra del oro y la valida fuera de muestra.

Protocolo (el mismo que usaría un comité de riesgo, no un vendedor de cursos):
  1. Parte la serie en ENTRENAMIENTO y PRUEBA por fecha, sin solape.
  2. Calibra las 4 capas SOLO con el tramo de entrenamiento.
  3. Valida sobre el tramo de prueba, que el modelo no ha visto.
  4. Recalibra con la serie completa para producción y guarda los parámetros.
  5. Escribe un informe con las métricas MEDIDAS, incluidas las que salen mal.

Uso:
    python gm_calibrate.py /ruta/XAU_real_h1_21y.csv --split 0.75 --out out_model
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "core")]

import gm_data  # noqa: E402
from gm_gold_sde import calibrate, validate  # noqa: E402


def _fmt(v) -> str:
    if isinstance(v, bool):
        return "sí" if v else "NO"
    if isinstance(v, float):
        return f"{v:.4f}" if abs(v) < 1000 else f"{v:,.1f}"
    return str(v)


def run(path: Path, split: float, out_dir: Path, n_paths: int) -> dict:
    df = gm_data.load(path)
    print(f"[datos] {gm_data.describe(df)}")

    cut = df.index[int(len(df) * split)]
    train, test = df[df.index < cut], df[df.index >= cut]
    print(f"[split] entrena {len(train):,} barras (<{cut:%Y-%m-%d})  "
          f"prueba {len(test):,} barras (≥{cut:%Y-%m-%d})")

    # --- 1-2. calibrar solo con entrenamiento ---
    m_tr, diag_tr = calibrate(train)
    print("\n" + m_tr.equation_text() + "\n")

    # --- 3. validar DENTRO (entrenamiento) y FUERA (prueba) de muestra ---
    print("[validación] en muestra…")
    v_in = validate(m_tr, diag_tr, n_paths=n_paths, seed=7)

    print("[validación] fuera de muestra…")
    # Reusa los parámetros de entrenamiento, pero los diagnósticos del tramo de
    # prueba: así la sigma del GARCH se recalcula sobre datos no vistos.
    m_te, diag_te = calibrate(test)
    for k in ("garch_omega", "garch_alpha", "garch_beta", "garch_nu", "seasonal",
              "beta", "alpha", "ou_kappa", "jump_lambda_year", "jump_mean_pct",
              "jump_std_pct", "jump_compensator", "regime_drift_pct",
              "regime_vol_mult", "regime_lambda_year", "regime_transmat"):
        setattr(m_te, k, getattr(m_tr, k))  # parámetros del TRAIN
    v_out = validate(m_te, diag_te, n_paths=n_paths, seed=11)

    # --- 4. recalibrar con todo para producción ---
    m_full, diag_full = calibrate(df)
    v_full = validate(m_full, diag_full, n_paths=n_paths, seed=13)

    out_dir.mkdir(parents=True, exist_ok=True)
    m_full.to_json(out_dir / "params_xauusd_h1.json")
    (out_dir / "validation.json").write_text(
        json.dumps({"in_sample": v_in, "out_of_sample": v_out, "full": v_full},
                   indent=2), encoding="utf-8")

    # diagnóstico por barra, útil para el dashboard y el replay
    diag_full[["sigma_pct", "z", "epsilon", "jump", "regime"]].to_csv(
        out_dir / "diagnostics.csv.gz", compression="gzip")

    # --- 5. informe ---
    lines = [m_full.equation_text(), "", "VALIDACIÓN (medida, no afirmada)", "=" * 78,
             "en muestra = params train, datos train · fuera muestra = params train,",
             "datos 2020-2025 nunca vistos · completo = el modelo que se despliega",
             "-" * 78,
             f"{'métrica':38s} {'en muestra':>12s} {'fuera muestra':>14s} {'completo':>12s}"]
    keys = ["resid_ks_pvalue", "resid_kurtosis", "ljungbox_z_p", "ljungbox_z2_p",
            "vol_forecast_r2", "vol_spearman", "direction_auc", "direction_hit_pct",
            "real_vol_annual_pct", "sim_vol_annual_pct", "real_kurtosis", "sim_kurtosis",
            "real_skew", "sim_skew", "real_acf_abs_1", "sim_acf_abs_1",
            "real_acf_abs_24", "sim_acf_abs_24", "real_acf_abs_120", "sim_acf_abs_120",
            "real_max_dd_pct", "sim_max_dd_p50_pct", "sim_max_dd_p05_pct",
            "sim_max_dd_p95_pct", "real_dd_inside_sim_band", "sim0_max_dd_p50_pct", "sim0_max_dd_p05_pct", "sim0_max_dd_p01_pct", "real_dd_inside_sim0_band"]
    for k in keys:
        lines.append(f"{k:38s} {_fmt(v_in.get(k, '—')):>12s} "
                     f"{_fmt(v_out.get(k, '—')):>14s} {_fmt(v_full.get(k, '—')):>12s}")
    report = "\n".join(lines)
    (out_dir / "REPORT.txt").write_text(report, encoding="utf-8")
    print("\n" + report)
    print(f"\n[ok] parámetros → {out_dir/'params_xauusd_h1.json'}")
    return {"params": m_full, "in": v_in, "out": v_out, "full": v_full}


def main() -> int:
    ap = argparse.ArgumentParser(description="Calibra la ecuación maestra del oro")
    ap.add_argument("data", type=Path, help="CSV/TSV/Excel de velas (H1 recomendado)")
    ap.add_argument("--split", type=float, default=0.75, help="fracción de entrenamiento")
    ap.add_argument("--out", type=Path, default=Path("out_model"))
    ap.add_argument("--paths", type=int, default=500, help="caminos MC para validar")
    a = ap.parse_args()
    run(a.data, a.split, a.out, a.paths)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
