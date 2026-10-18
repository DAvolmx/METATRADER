"""Pruebas de los agentes: memoria, degradación limpia y orden del ciclo."""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from gm_agents import ORDEN, REGISTRY, AgentContext, run_cycle  # noqa: E402
from gm_vault import Vault  # noqa: E402


def _ctx(tmp_path):
    return AgentContext(vault=Vault(tmp_path / "b"))


def test_registro_completo():
    assert set(REGISTRY) == set(ORDEN)
    assert ORDEN[-1] == "critico", "el critico debe ir ultimo: lee a los demas"


def test_agentes_sin_datos_no_explotan(tmp_path):
    """Sin ficheros de datos deben devolver error controlado, no excepción."""
    ctx = _ctx(tmp_path)
    for nm in ("calibracion", "regimen", "order-blocks", "dxy"):
        r = REGISTRY[nm]().run(ctx)
        assert "error" in r, f"{nm} deberia reportar error con datos ausentes"


def test_ciclo_aisla_fallos(tmp_path):
    """Un agente que falla no debe tumbar el ciclo ni el índice."""
    ctx = _ctx(tmp_path)
    res = run_cycle(ctx, ["calibracion", "critico"])
    assert "calibracion" in res and "critico" in res
    assert "error" not in res["critico"]
    assert (ctx.vault.root / "00-indice" / "INDICE.md").exists()


def test_contexto_recuerda_refutados(tmp_path):
    ctx = _ctx(tmp_path)
    assert not ctx.ya_refutado("order block")
    ctx.vault.log_experiment(
        agente="order-blocks",
        hipotesis="alguna estrategia de order block tiene esperanza positiva real",
        metrica="R", valor=0.3, veredicto="refutada", cuerpo="x", n_pruebas=486)
    assert ctx.ya_refutado("order block")
    assert not ctx.ya_refutado("el dxy anticipa")


def test_contexto_umbral_sigue_a_la_boveda(tmp_path):
    ctx = _ctx(tmp_path)
    antes = ctx.umbral()
    ctx.vault.log_experiment(agente="x", hipotesis="h", metrica="R", valor=0.0,
                             veredicto="refutada", cuerpo="c", n_pruebas=999)
    assert ctx.umbral() < antes / 100


def test_contexto_ultimo_por_agente(tmp_path):
    ctx = _ctx(tmp_path)
    assert ctx.ultimo("calibracion") is None
    ctx.vault.log_experiment(agente="calibracion", hipotesis="h", fecha="2026-01-01",
                             metrica="vol_anual_pct", valor=17.0,
                             veredicto="confirmada", cuerpo="c")
    ctx.vault.log_experiment(agente="calibracion", hipotesis="h", fecha="2026-06-01",
                             metrica="vol_anual_pct", valor=21.0,
                             veredicto="confirmada", cuerpo="c")
    n = ctx.ultimo("calibracion", "vol_anual_pct")
    assert n is not None and n.meta["valor"] == 21.0


def test_critico_escribe_preguntas_abiertas(tmp_path):
    ctx = _ctx(tmp_path)
    ctx.vault.log_experiment(agente="dxy", hipotesis="el dxy anticipa al oro",
                             metrica="acierto", valor=55.2, veredicto="inestable",
                             cuerpo="c", n_pruebas=3)
    r = REGISTRY["critico"]().run(ctx)
    assert r["inestables"] == 1
    notas = list((ctx.vault.root / "60-decisiones").glob("*preguntas-abiertas.md"))
    assert notas, "el critico debe dejar una nota de decisiones"
    txt = notas[0].read_text(encoding="utf-8")
    assert "inestables" in txt.lower() and "el dxy anticipa al oro" in txt


def test_critico_detecta_contradicciones(tmp_path):
    ctx = _ctx(tmp_path)
    for v in ("candidata", "refutada"):
        ctx.vault.log_experiment(agente="a", hipotesis="la misma hipotesis",
                                 metrica="R", valor=0.1, veredicto=v,
                                 cuerpo="c", slug=f"n-{v}")
    assert REGISTRY["critico"]().run(ctx)["contradicciones"] == 1
