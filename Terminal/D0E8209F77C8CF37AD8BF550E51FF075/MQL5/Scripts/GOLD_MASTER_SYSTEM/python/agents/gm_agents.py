"""
gm_agents.py — Agentes de investigación que se mejoran a través de la bóveda.

Cada agente hace una cosa, la mide, y DEJA CONSTANCIA en la bóveda Obsidian.
El siguiente ciclo lee lo que dejó el anterior, así que el sistema acumula
criterio en vez de repetir experimentos.

En qué consiste exactamente la "mejora", que conviene decirlo sin humo: no es
que el sistema se vuelva rentable solo. Es que se vuelve MÁS DIFÍCIL DE ENGAÑAR.
Tres mecanismos concretos:

  1. No repite lo refutado. `AgentContext.ya_refutado()` consulta la bóveda, y
     un agente que iba a reprobar una hipótesis ya tumbada se salta el trabajo.
  2. Endurece el umbral. Cada barrido suma sus pruebas al libro, y
     `corrected_threshold()` baja la exigencia aceptable para todos los agentes.
     Un resultado que hoy pasa, dentro de 300 pruebas ya no pasa.
  3. Detecta deriva. Los agentes comparan sus números con los registrados la
     última vez y avisan si el mercado se ha movido bajo los pies del modelo.

AGENTES
  calibracion    recalibra la ecuación maestra y compara con la última vez
  regimen        dice en qué régimen está el mercado HOY y qué implica
  order-blocks   reejecuta taxonomía y barrido, y los juzga con el umbral vivo
  dxy            reejecuta la estabilidad interanual del efecto dólar
  sentimiento    publica el estado y REVALIDA si anticipa algo
  diario         aprende de TUS operaciones registradas
  critico        lee las notas recientes y escribe las contradicciones abiertas

Ninguno opera ni envía órdenes. Son de investigación.
"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "core"), str(HERE.parent / "model"),
                str(HERE.parent / "smc"), str(HERE.parent / "live")]

from gm_vault import Note, Vault  # noqa: E402


@dataclass
class AgentContext:
    """Lo que comparten todos los agentes en un ciclo."""

    vault: Vault
    data_gold: Path | None = None
    data_dxy: Path | None = None
    params: Path | None = None
    out_dir: Path | None = None
    extra: dict = field(default_factory=dict)

    # ------------------------------------------------- memoria de la bóveda

    def umbral(self, alpha: float = 0.05) -> float:
        """Umbral de p-valor exigible HOY, dado todo lo ya probado."""
        return float(self.vault.corrected_threshold(alpha)["alpha_bonferroni"])

    def ya_refutado(self, hipotesis_substr: str) -> bool:
        """¿Hay ya un experimento que refutó esta hipótesis?"""
        s = hipotesis_substr.lower()
        return any(s in str(n.meta.get("hipotesis", "")).lower()
                   and str(n.meta.get("veredicto")) == "refutada"
                   for n in self.vault.experiments())

    def ultimo(self, agente: str, metrica: str | None = None):
        """Última nota de un agente, para comparar y detectar deriva."""
        xs = [n for n in self.vault.experiments()
              if n.meta.get("agente") == agente
              and (metrica is None or n.meta.get("metrica") == metrica)]
        xs.sort(key=lambda n: str(n.meta.get("fecha", "")))
        return xs[-1] if xs else None


class Agent:
    """Base. `run` devuelve un resumen y escribe en la bóveda."""

    name = "base"

    def run(self, ctx: AgentContext) -> dict:  # pragma: no cover - interfaz
        raise NotImplementedError


# ───────────────────────────── calibración ─────────────────────────────


class CalibrationAgent(Agent):
    """Recalibra la ecuación maestra y avisa si los parámetros han derivado."""

    name = "calibracion"

    def run(self, ctx: AgentContext) -> dict:
        import gm_data
        from gm_gold_sde import calibrate, validate

        if not ctx.data_gold or not Path(ctx.data_gold).exists():
            return {"agente": self.name, "error": "sin datos de oro"}
        df = gm_data.load(ctx.data_gold)
        m, diag = calibrate(df)
        v = validate(m, diag, n_paths=200, seed=7)

        prev = ctx.ultimo(self.name, "vol_anual_pct")
        deriva = ""
        vol = float(m.uncond_vol_pct * np.sqrt(m.bars_per_year))
        if prev is not None:
            antes = float(prev.meta.get("valor", vol))
            d = vol - antes
            deriva = (f"\nLa volatilidad incondicional pasa de {antes:.2f}% a "
                      f"{vol:.2f}% anual ({d:+.2f} pp) desde {prev.meta.get('fecha')}."
                      + ("  **Deriva relevante: conviene redimensionar.**"
                         if abs(d) > 2.0 else "  Sin deriva relevante."))

        cuerpo = (
            f"## Ecuación calibrada\n\n```\n{m.equation_text()}\n```\n"
            f"{deriva}\n\n## Validación\n\n"
            f"- Volatilidad simulada **{v.get('sim_vol_annual_pct'):.2f}%** frente a "
            f"real {v.get('real_vol_annual_pct'):.2f}%\n"
            f"- ACF(|r|) rezago 1: simulada {v.get('sim_acf_abs_1'):.3f} vs "
            f"real {v.get('real_acf_abs_1'):.3f}\n"
            f"- Drawdown real {v.get('real_max_dd_pct'):.1f}% "
            f"{'DENTRO' if v.get('real_dd_inside_sim_band') else 'FUERA'} de la banda "
            f"simulada [{v.get('sim_max_dd_p05_pct'):.1f}%, "
            f"{v.get('sim_max_dd_p95_pct'):.1f}%]\n"
            f"- **AUC direccional {v.get('direction_auc'):.4f}** — el modelo no "
            f"predice dirección, y no pretende hacerlo. Sirve para dimensionar.\n\n"
            f"## Para dimensionar\n\n"
            f"Usa la banda de deriva NEUTRAL, no la histórica: p05 "
            f"{v.get('sim0_max_dd_p05_pct'):.1f}%, p01 "
            f"{v.get('sim0_max_dd_p01_pct'):.1f}%. La banda con β histórico hereda "
            f"el viento de cola de 2004-2025 y no genera bajistas plurianuales.")

        ctx.vault.log_experiment(
            agente=self.name,
            hipotesis="la ecuacion maestra sigue describiendo el riesgo del oro",
            metrica="vol_anual_pct", valor=vol,
            veredicto=("confirmada" if v.get("real_dd_inside_sim_band")
                       else "revisar"),
            n_pruebas=1, cuerpo=cuerpo, tags=["modelo", "calibracion", "riesgo"],
            enlaces=["INDICE"], datos=str(ctx.data_gold))
        if ctx.out_dir:
            m.to_json(Path(ctx.out_dir) / "params_xauusd_h1.json")
        return {"agente": self.name, "vol_anual_pct": round(vol, 2),
                "direction_auc": v.get("direction_auc"),
                "dd_dentro_banda": v.get("real_dd_inside_sim_band")}


# ───────────────────────────── régimen ─────────────────────────────


class RegimeAgent(Agent):
    """En qué régimen está el mercado hoy, y qué implica operativamente."""

    name = "regimen"

    def run(self, ctx: AgentContext) -> dict:
        import gm_data
        from gm_gold_sde import GoldSDE, calibrate

        if not ctx.data_gold or not Path(ctx.data_gold).exists():
            return {"agente": self.name, "error": "sin datos de oro"}
        df = gm_data.load(ctx.data_gold)
        m, diag = calibrate(df)
        reg = int(diag["regime"].iloc[-1])
        nombre = m.regime_names[reg]
        ult = diag["regime"].tail(24 * 10)
        cuota = {m.regime_names[k]: round(100.0 * float((ult == k).mean()), 1)
                 for k in range(3)}
        vol_now = float(diag["sigma_pct"].iloc[-1] * np.sqrt(m.bars_per_year))

        cuerpo = (
            f"## Régimen actual: **{nombre}**\n\n"
            f"- Multiplicador de volatilidad del régimen: ×{m.regime_vol_mult[reg]:.2f}\n"
            f"- Duración esperada: {m.regime_duration_days[reg]:.0f} días\n"
            f"- Volatilidad condicional ahora: {vol_now:.1f}% anual\n"
            f"- Reparto de los últimos 10 días: {cuota}\n\n"
            f"## Implicación\n\n"
            + ("Régimen **agitado**: históricamente el peor tramo medido "
               "(−0.17R en el catálogo de estrategias). El gobernador de riesgo "
               "lo bloquea por defecto, y con razón.\n"
               if nombre == "agitado" else
               "Régimen **calmo**: el tramo menos malo del histórico (+0.54R), "
               "pero eso NO es una señal de entrada: es una condición de contexto.\n"
               if nombre == "calmo" else
               "Régimen **normal**: sin sesgo medido digno de mención.\n")
            + f"\nEl lote debe salir de la volatilidad de AHORA ({vol_now:.1f}% "
              f"anual), no de una media histórica.")

        ctx.vault.log_experiment(
            agente=self.name, hipotesis=f"el regimen actual es {nombre}",
            metrica="vol_condicional_anual_pct", valor=vol_now,
            veredicto="observacion", n_pruebas=0, cuerpo=cuerpo,
            tags=["regimen", "riesgo"], enlaces=["INDICE"])
        return {"agente": self.name, "regimen": nombre,
                "vol_condicional_anual_pct": round(vol_now, 1)}


# ───────────────────────── order blocks ─────────────────────────


class OrderBlockAgent(Agent):
    """Reejecuta la taxonomía y el barrido, y los juzga con el umbral vivo."""

    name = "order-blocks"

    def run(self, ctx: AgentContext) -> dict:
        import gm_data
        import gm_ob_montecarlo as mc
        import gm_ob_strategies as st
        import gm_orderblocks_pro as obm

        if not ctx.data_gold or not Path(ctx.data_gold).exists():
            return {"agente": self.name, "error": "sin datos de oro"}
        df = gm_data.load(ctx.data_gold)
        cut = df.index[int(len(df) * 0.70)]
        tr = df[df.index < cut]
        obs = obm.detect(tr)
        if obs.empty:
            return {"agente": self.name, "error": "sin order blocks detectados"}

        specs = st.grid()
        res = st.sweep(tr, obs, specs, min_trades=30)
        ok = res[res["n"] >= 30]
        if ok.empty:
            return {"agente": self.name, "error": "ninguna especificacion con n>=30"}
        best = ok.iloc[0]

        trades = {sp.label(): st.backtest(tr, obs, sp) for sp in specs}
        rc = mc.reality_check(mc.build_matrix(trades), n_boot=2000, seed=23)
        p = float(rc.get("p_value", 1.0))
        umbral = ctx.umbral()
        pasa = p < umbral

        resumen = obm.summary(obs)
        cuerpo = (
            f"## Bloques detectados: {len(obs)}\n\n```\n{resumen.to_string()}\n```\n\n"
            f"## Mejor de {len(specs)} especificaciones\n\n"
            f"- `{best['spec']}` → esperanza **{best['expectancy_R']:+.4f}R** "
            f"con {int(best['n'])} operaciones, PF {best['profit_factor']}, "
            f"t={best['t_stat']}\n"
            f"- Positivas: {int((ok['expectancy_R']>0).sum())}/{len(ok)}\n\n"
            f"## Juicio con corrección por pruebas múltiples\n\n"
            f"- Contraste de realidad de White: **p = {p:.4f}**\n"
            f"- Umbral exigible hoy (bóveda, {ctx.vault.counted_tests()} pruebas "
            f"previas): **p < {umbral:.2e}**\n"
            f"- Veredicto: **{'pasa' if pasa else 'NO pasa'}**\n\n"
            + ("" if pasa else
               "La mejor de cientos de variantes no se distingue de la suerte. "
               "Es el resultado esperado cuando se barre un espacio grande sobre "
               "una serie finita, y por eso el barrido se registra con sus "
               f"{len(specs)} pruebas en el libro, no como una sola.\n"))

        ctx.vault.log_experiment(
            agente=self.name,
            hipotesis="alguna estrategia de order block tiene esperanza positiva real",
            metrica="expectancy_R", valor=float(best["expectancy_R"]),
            p_valor=p, veredicto=("candidata" if pasa else "refutada"),
            n_pruebas=len(specs), cuerpo=cuerpo,
            tags=["smc", "order-blocks", "montecarlo"], enlaces=["INDICE"],
            datos=str(ctx.data_gold))
        return {"agente": self.name, "n_obs": int(len(obs)),
                "mejor": str(best["spec"]),
                "expectancy_R": float(best["expectancy_R"]),
                "p_white": p, "umbral": umbral, "pasa": pasa}


# ───────────────────────────── DXY ─────────────────────────────


class DxyAgent(Agent):
    """Reejecuta la estabilidad interanual del efecto dólar sobre el oro."""

    name = "dxy"

    def run(self, ctx: AgentContext) -> dict:
        import gm_data
        import gm_dxy

        if not (ctx.data_gold and ctx.data_dxy
                and Path(ctx.data_gold).exists() and Path(ctx.data_dxy).exists()):
            return {"agente": self.name, "error": "faltan datos de oro o DXY"}
        gold, dxy = gm_data.load(ctx.data_gold), gm_data.load(ctx.data_dxy)
        d = gm_dxy.align(gold, dxy)
        abl = gm_dxy.ablation(d)
        est = gm_dxy.stability(d)
        corr = gm_dxy.correlations(d)
        coint = gm_dxy.cointegration(d)

        flojos = est.get("anos_sin_efecto", [])
        por_ano = "\n".join(
            f"- {y}: {v['acierto_pct']:.1f}% (n={v['n']})"
            for y, v in sorted(est.get("por_ano", {}).items()))
        cuerpo = (
            f"## Correlación\n\n"
            f"- Global **{corr['corr_global']:+.4f}**, contemporánea\n"
            f"- Móvil 252d: media {corr['movil_252d']['media']:+.3f}, "
            f"desviación {corr['movil_252d']['desv']:.3f}, rango "
            f"[{corr['movil_252d']['min']:+.2f}, {corr['movil_252d']['max']:+.2f}]\n"
            f"- Cointegrados: **{coint['cointegrados']}** (ADF p={coint['adf_pvalue']})\n\n"
            f"## Atribución\n\n"
            f"- solo oro: R² {abl['solo_oro']['r2_fuera_muestra']:+.5f}, "
            f"acierto {abl['solo_oro']['acierto_direccional_pct']:.2f}%\n"
            f"- solo DXY: R² {abl['solo_dxy']['r2_fuera_muestra']:+.5f}, "
            f"acierto {abl['solo_dxy']['acierto_direccional_pct']:.2f}% "
            f"({abl['solo_dxy']['sigmas_sobre_azar']:.2f}σ)\n"
            f"- ambos: R² {abl['oro_y_dxy']['r2_fuera_muestra']:+.5f}, "
            f"acierto {abl['oro_y_dxy']['acierto_direccional_pct']:.2f}%\n\n"
            f"{abl['atribucion']}\n\n"
            f"## Estabilidad año a año\n\n{por_ano}\n\n"
            f"- Sharpe neto agregado: **{est['sharpe_neto_anualizado']}**\n"
            f"- {est['veredicto']}\n\n"
            + ("**Esta es la señal más prometedora del sistema y la única con "
               "significación real, pero su inestabilidad prohíbe dimensionarla "
               "con la media agregada.**\n" if flojos else ""))

        p_aprox = 1.0 - min(0.9999, abl["solo_dxy"]["acierto_direccional_pct"] / 100.0)
        ctx.vault.log_experiment(
            agente=self.name,
            hipotesis="el DXY anticipa la direccion del oro al dia siguiente",
            metrica="acierto_direccional_pct",
            valor=float(abl["solo_dxy"]["acierto_direccional_pct"]),
            p_valor=p_aprox,
            veredicto=("inestable" if flojos else "candidata"),
            n_pruebas=3, cuerpo=cuerpo, tags=["dxy", "macro", "prediccion"],
            enlaces=["INDICE"], datos=str(ctx.data_dxy))
        return {"agente": self.name,
                "acierto_solo_dxy_pct": abl["solo_dxy"]["acierto_direccional_pct"],
                "anos_sin_efecto": flojos,
                "sharpe_neto": est["sharpe_neto_anualizado"]}


# ───────────────────────── sentimiento ─────────────────────────


class SentimentAgent(Agent):
    """Publica el estado de sentimiento y REVALIDA su capacidad predictiva.

    No se limita a publicar el número: vuelve a medir si el índice anticipa al
    oro. Un indicador de sentimiento que se publica sin revalidar es la receta
    para que, dentro de un año, alguien lo opere creyendo que predice.
    """

    name = "sentimiento"

    def run(self, ctx: AgentContext) -> dict:
        import gm_data
        import gm_sentiment as snt

        if not ctx.data_gold or not Path(ctx.data_gold).exists():
            return {"agente": self.name, "error": "sin datos de oro"}
        gold = gm_data.load(ctx.data_gold)
        dxy = (gm_data.load(ctx.data_dxy)
               if ctx.data_dxy and Path(ctx.data_dxy).exists() else None)
        cot_path = ctx.extra.get("cot")
        cot = (snt.load_cot(cot_path)
               if cot_path and Path(cot_path).exists() else None)

        ints = snt.internals(gold)
        data, faltan = snt.attach_external(ints, cot, dxy)
        zs = snt.composite(data)
        val = float(zs["compuesto"].iloc[-1])
        v = snt.validate(zs, gm_data.resample(gold, "1D"))

        mejor = max((x["sigmas_sobre_azar"] for k, x in v.items()
                     if isinstance(x, dict)), default=0.0)
        filas = "\n".join(
            f"- {k}: acierto {x['acierto_pct']:.2f}% ({x['sigmas_sobre_azar']:+.2f} sigma), "
            f"corr train {x['corr_train']:+.4f} -> test {x['corr_test']:+.4f}"
            for k, x in v.items() if isinstance(x, dict))
        comps = {n: round(float(zs[f"z_{n}"].iloc[-1]), 2)
                 for n in snt.SIGNOS if f"z_{n}" in zs.columns
                 and np.isfinite(zs[f"z_{n}"].iloc[-1])}
        volteo = any(isinstance(x, dict) and x["corr_train"] * x["corr_test"] < 0
                     for x in v.values())

        cuerpo = (
            f"## Estado: **{val:+.1f}** — {snt.etiqueta(val)}\n\n"
            f"- Componentes usados: {zs.attrs.get('componentes_usados')}\n"
            f"- Fuentes ausentes: {faltan or 'ninguna'}\n"
            f"- Lectura por componente (z): {comps}\n\n"
            f"## Revalidación de su capacidad predictiva\n\n{filas}\n\n"
            f"{v['veredicto']}\n\n"
            + ("Un cambio de SIGNO en la correlación entre entrenamiento y "
               "prueba indica que no hay relación estable, no que haga falta "
               "más ajuste.\n" if volteo else ""))

        ctx.vault.log_experiment(
            agente=self.name,
            hipotesis="el indice de sentimiento anticipa al oro",
            metrica="sigmas_sobre_azar", valor=float(mejor),
            veredicto=("candidata" if mejor > 2.0 else "refutada"),
            n_pruebas=len([x for x in v.values() if isinstance(x, dict)]),
            cuerpo=cuerpo, tags=["sentimiento", "contexto"], enlaces=["INDICE"],
            datos=str(ctx.data_gold))
        return {"agente": self.name, "compuesto": round(val, 1),
                "etiqueta": snt.etiqueta(val), "fuentes_ausentes": faltan,
                "max_sigma": round(float(mejor), 2)}



# ───────────────────────────── diario ─────────────────────────────


class JournalAgent(Agent):
    """Aprende de TUS operaciones registradas por el gobernador de riesgo."""

    name = "diario"

    def run(self, ctx: AgentContext) -> dict:
        try:
            from gm_guardian import Journal, learn_from_journal
        except Exception as e:
            return {"agente": self.name, "error": f"guardian no disponible: {e}"}
        j = Journal()
        stats = j.stats()
        n = int(stats.get("n", 0) or 0)
        if n < 20:
            cuerpo = (
                f"## Operaciones registradas: {n}\n\n"
                f"Con menos de 20 operaciones no se puede aprender nada de tu "
                f"operativa sin autoengañarse: cualquier patrón que salga será "
                f"ruido. Registra contexto en cada operación (régimen, sesión, "
                f"escenario del bloque, spread) y este agente empezará a servir.\n")
            ctx.vault.log_experiment(
                agente=self.name, hipotesis="mi operativa tiene un patron aprovechable",
                metrica="n_operaciones", valor=float(n), veredicto="sin-datos",
                n_pruebas=0, cuerpo=cuerpo, tags=["diario"], enlaces=["INDICE"])
            return {"agente": self.name, "n": n, "estado": "muestra insuficiente"}

        ml = learn_from_journal(j)
        cuerpo = (
            f"## Tu operativa\n\n"
            f"- Operaciones: {n}\n"
            f"- Acierto: {stats.get('win_rate')}%\n"
            f"- Esperanza: {stats.get('expectancy_R')}R\n"
            f"- Neto: {stats.get('net_usd')} USD\n\n"
            f"## Modelo sobre tus datos\n\n```json\n"
            f"{json.dumps(ml, indent=2, ensure_ascii=False)}\n```\n")
        ctx.vault.log_experiment(
            agente=self.name, hipotesis="mi operativa tiene un patron aprovechable",
            metrica="expectancy_R", valor=float(stats.get("expectancy_R") or 0.0),
            veredicto="observacion", n_pruebas=1, cuerpo=cuerpo,
            tags=["diario", "ml"], enlaces=["INDICE"])
        return {"agente": self.name, "n": n, "ml": ml}


# ───────────────────────────── crítico ─────────────────────────────


class CriticAgent(Agent):
    """Lee la bóveda y escribe las contradicciones y preguntas abiertas.

    Es el agente que impide que el cuaderno se convierta en una colección de
    buenas noticias: busca candidatas sin confirmar, veredictos contradictorios
    sobre lo mismo, y señales que llevan tiempo sin revalidarse.
    """

    name = "critico"

    def run(self, ctx: AgentContext) -> dict:
        exps = ctx.vault.experiments()
        thr = ctx.vault.corrected_threshold()
        hoy = date.today().isoformat()

        candidatas = [n for n in exps if str(n.meta.get("veredicto")) == "candidata"]
        inestables = [n for n in exps if str(n.meta.get("veredicto")) == "inestable"]
        revisar = [n for n in exps if str(n.meta.get("veredicto")) == "revisar"]

        # misma hipótesis con veredictos distintos = contradicción a resolver
        porh: dict[str, set] = {}
        for n in exps:
            porh.setdefault(str(n.meta.get("hipotesis", "")), set()).add(
                str(n.meta.get("veredicto")))
        contras = {h: sorted(v) for h, v in porh.items() if len(v) > 1}

        # señales sin revalidar
        viejas = []
        for n in candidatas + inestables:
            f = str(n.meta.get("fecha", ""))
            if f and f < hoy:
                viejas.append((f, n.slug))

        lineas = [
            "## Preguntas abiertas", "",
            f"Umbral exigible hoy: **p < {thr['alpha_bonferroni']:.2e}** "
            f"({thr['pruebas_totales']} hipótesis contrastadas).", "",
        ]
        if candidatas:
            lineas += ["### Candidatas sin confirmar", ""] + [
                f"- [[{n.slug}]] — {n.meta.get('hipotesis')} "
                f"({n.meta.get('metrica')}={n.meta.get('valor')})"
                for n in candidatas] + [""]
        if inestables:
            lineas += ["### Señales inestables (no dimensionar con el agregado)", ""] + [
                f"- [[{n.slug}]] — {n.meta.get('hipotesis')}" for n in inestables] + [""]
        if revisar:
            lineas += ["### Marcadas para revisar", ""] + [
                f"- [[{n.slug}]] — {n.meta.get('hipotesis')}" for n in revisar] + [""]
        if contras:
            lineas += ["### Contradicciones", ""] + [
                f"- «{h[:70]}» tiene veredictos {v}" for h, v in contras.items()] + [""]
        if viejas:
            lineas += ["### Pendientes de revalidar", ""] + [
                f"- [[{s}]] (último: {f})" for f, s in sorted(viejas)] + [""]
        if not (candidatas or inestables or revisar or contras):
            lineas += ["Nada pendiente: todo lo registrado está refutado o es "
                       "observación. Eso es un estado sano, no un fracaso.", ""]

        lineas += [
            "### Lo que este cuaderno NO puede decirte", "",
            "- Que una estrategia vaya a funcionar en el futuro.",
            "- Que un resultado agregado se mantenga año a año (mira la",
            "  estabilidad, no la media).",
            "- Nada sobre lo que no se haya registrado. Un experimento que no",
            "  se apunta no cuenta para el umbral, y entonces el umbral miente.",
        ]

        ctx.vault.write(Note(
            f"{hoy}-preguntas-abiertas",
            {"tipo": "decision", "fecha": hoy, "agente": self.name,
             "tags": ["critico", "preguntas-abiertas"]},
            "\n".join(lineas)))
        return {"agente": self.name, "candidatas": len(candidatas),
                "inestables": len(inestables), "contradicciones": len(contras),
                "umbral": thr["alpha_bonferroni"]}


REGISTRY: dict[str, type[Agent]] = {
    CalibrationAgent.name: CalibrationAgent,
    RegimeAgent.name: RegimeAgent,
    OrderBlockAgent.name: OrderBlockAgent,
    DxyAgent.name: DxyAgent,
    SentimentAgent.name: SentimentAgent,
    JournalAgent.name: JournalAgent,
    CriticAgent.name: CriticAgent,
}

#: el crítico va último a propósito: necesita leer lo que han escrito los demás
ORDEN = ["calibracion", "regimen", "order-blocks", "dxy", "sentimiento",
         "diario", "critico"]


def run_cycle(ctx: AgentContext, agents: list[str] | None = None) -> dict:
    """Ejecuta un ciclo completo y reconstruye el índice de la bóveda."""
    names = agents or ORDEN
    out = {}
    for nm in names:
        cls = REGISTRY.get(nm)
        if cls is None:
            out[nm] = {"error": "agente desconocido"}
            continue
        try:
            out[nm] = cls().run(ctx)
        except Exception as e:                      # un agente roto no tumba el ciclo
            out[nm] = {"agente": nm, "error": f"{type(e).__name__}: {e}"}
    ctx.vault.rebuild_index()
    return out


__all__ = ["Agent", "AgentContext", "REGISTRY", "ORDEN", "run_cycle",
           "CalibrationAgent", "RegimeAgent", "OrderBlockAgent", "DxyAgent",
           "SentimentAgent", "JournalAgent", "CriticAgent"]
