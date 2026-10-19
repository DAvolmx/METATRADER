"""
gm_lab.py — Lanzador del laboratorio de agentes.

Ejecuta un ciclo de investigación y deja todo escrito en la bóveda Obsidian,
que puedes abrir directamente con Obsidian apuntándolo a la carpeta de la
bóveda.

    python gm_lab.py --vault ~/GoldMasterVault \\
        --gold datos/XAUUSD_H1.csv --dxy datos/DXY_d1.csv

    python gm_lab.py --vault ~/GoldMasterVault --agentes regimen,critico
    python gm_lab.py --vault ~/GoldMasterVault --estado

Cada ejecución endurece el umbral de significación del proyecto, porque suma al
libro de pruebas las hipótesis que haya contrastado. Eso es intencionado.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# El directorio del script se anade a mano para que funcione tambien con
# `python -I` (modo aislado), que no lo prepende a sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from gm_agents import ORDEN, AgentContext, run_cycle  # noqa: E402
from gm_vault import Vault  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description="Laboratorio de agentes GOLD MASTER")
    ap.add_argument("--vault", type=Path, required=True, help="carpeta de la boveda")
    ap.add_argument("--gold", type=Path, help="CSV de velas de oro")
    ap.add_argument("--dxy", type=Path, help="CSV diario del DXY")
    ap.add_argument("--params", type=Path, help="params_xauusd_h1.json")
    ap.add_argument("--cot", type=Path, help="CSV de posicionamiento COT (CFTC)")
    ap.add_argument("--out", type=Path, help="carpeta de salida de artefactos")
    ap.add_argument("--agentes", type=str, default="",
                    help=f"lista separada por comas; por omision: {','.join(ORDEN)}")
    ap.add_argument("--estado", action="store_true",
                    help="solo mostrar el estado de la boveda y salir")
    a = ap.parse_args()

    v = Vault(a.vault)
    if a.estado:
        thr = v.corrected_threshold()
        print(json.dumps({
            "boveda": str(v.root),
            "experimentos": len(v.experiments()),
            "veredictos": v.verdict_counts(),
            **thr,
        }, indent=2, ensure_ascii=False))
        print("\nindice:", v.rebuild_index())
        return 0

    ctx = AgentContext(vault=v, data_gold=a.gold, data_dxy=a.dxy,
                       params=a.params, out_dir=a.out,
                       extra={"cot": a.cot} if a.cot else {})
    names = [x.strip() for x in a.agentes.split(",") if x.strip()] or None
    res = run_cycle(ctx, names)
    print(json.dumps(res, indent=2, ensure_ascii=False, default=str))
    thr = v.corrected_threshold()
    print(f"\n[boveda] {v.root}")
    print(f"[boveda] {thr['pruebas_totales']} hipotesis contrastadas en total "
          f"→ umbral exigible p < {thr['alpha_bonferroni']:.2e}")
    print(f"[boveda] indice: {v.rebuild_index()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
