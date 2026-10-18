"""Pruebas de la bóveda Obsidian y del libro de pruebas múltiples."""
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from gm_vault import Note, Vault  # noqa: E402


def test_crea_estructura(tmp_path):
    v = Vault(tmp_path / "boveda")
    for d in Vault.SUBDIRS:
        assert (v.root / d).is_dir()


def test_roundtrip_frontmatter(tmp_path):
    v = Vault(tmp_path / "b")
    meta = {"tipo": "experimento", "fecha": "2026-01-01", "agente": "x",
            "hipotesis": "algo con: dos puntos", "n_pruebas": 7,
            "valor": 1.5, "ok": True, "tags": ["a", "b"], "vacio": None}
    p = v.write(Note("nota", meta, "# Cuerpo\n\nenlace a [[OTRA]]"))
    back = v.read(p)
    assert back.meta["hipotesis"] == "algo con: dos puntos"
    assert back.meta["n_pruebas"] == 7
    assert back.meta["valor"] == 1.5
    assert back.meta["ok"] is True
    assert back.meta["tags"] == ["a", "b"]
    assert back.meta["vacio"] is None
    assert back.links == ["OTRA"]


def test_log_experiment_y_recuento(tmp_path):
    v = Vault(tmp_path / "b")
    v.log_experiment(agente="a1", hipotesis="h1", metrica="R", valor=0.1,
                     veredicto="refutada", cuerpo="x", n_pruebas=486)
    v.log_experiment(agente="a2", hipotesis="h2", metrica="R", valor=0.2,
                     veredicto="candidata", cuerpo="y", n_pruebas=3)
    assert len(v.experiments()) == 2
    assert v.counted_tests() == 489
    assert v.verdict_counts() == {"refutada": 1, "candidata": 1}


def test_umbral_se_endurece_con_las_pruebas(tmp_path):
    """El mecanismo central: más experimentos ⇒ umbral MÁS exigente."""
    v = Vault(tmp_path / "b")
    flojo = v.corrected_threshold()["alpha_bonferroni"]
    v.log_experiment(agente="sweep", hipotesis="barrido grande", metrica="R",
                     valor=0.4, veredicto="refutada", cuerpo="x", n_pruebas=486)
    duro = v.corrected_threshold()["alpha_bonferroni"]
    assert duro < flojo / 100          # 0.05 -> ~1.0e-4
    assert v.corrected_threshold(extra_tests=1000)["pruebas_totales"] == 1486


def test_umbral_nunca_divide_por_cero(tmp_path):
    v = Vault(tmp_path / "b")
    t = v.corrected_threshold()
    assert t["pruebas_totales"] >= 1 and t["alpha_bonferroni"] == pytest.approx(0.05)


def test_indice_refleja_el_estado(tmp_path):
    v = Vault(tmp_path / "b")
    v.log_experiment(agente="dxy", hipotesis="el dolar anticipa al oro",
                     metrica="acierto", valor=55.17, p_valor=0.0001,
                     veredicto="inestable", cuerpo="cuerpo", n_pruebas=3)
    txt = v.rebuild_index().read_text(encoding="utf-8")
    assert "el dolar anticipa al oro" in txt
    assert "inestable" in txt
    assert "dataview" in txt
    assert "p < " in txt


def test_notas_en_subcarpeta_correcta(tmp_path):
    v = Vault(tmp_path / "b")
    v.write(Note("d1", {"tipo": "decision", "fecha": "2026-01-01"}, "x"))
    v.write(Note("e1", {"tipo": "experimento", "fecha": "2026-01-01"}, "y"))
    assert (v.root / "60-decisiones" / "d1.md").exists()
    assert (v.root / "10-experimentos" / "e1.md").exists()
