"""
gm_vault.py — Bóveda Obsidian como cuaderno de laboratorio del sistema.

La bóveda no es documentación: es la MEMORIA del sistema, en markdown plano que
tanto tú como los agentes podéis leer y escribir. Cada experimento deja una nota
con metadatos en YAML, enlaces [[wiki]] a lo que toca, y un veredicto explícito.

────────────────────────────────────────────────────────────────────────────────
POR QUÉ ESTO IMPORTA DE VERDAD: EL LIBRO DE PRUEBAS MÚLTIPLES
────────────────────────────────────────────────────────────────────────────────
El modo de fallo que arruina a casi todo sistema cuantitativo casero no es un
bug: es OLVIDAR CUÁNTAS COSAS SE HAN PROBADO. Si pruebas 500 variantes a lo
largo de meses y te quedas con la que mejor salió, parecerá excelente aunque no
haya ningún efecto real, y el p-valor que calcules sobre esa única variante será
una mentira estadística.

La bóveda lo arregla porque cada hipótesis contrastada queda registrada con
fecha. `counted_tests()` suma todas las pruebas de la historia del proyecto y
`corrected_threshold()` devuelve el umbral de significación que de verdad hay
que superar. Es decir: el sistema se vuelve MÁS exigente con el tiempo, no más
crédulo, y eso es justo lo contrario de lo que hace una curva de capital bonita.

Formato de nota (compatible con Obsidian, Dataview y Bases):

    ---
    tipo: experimento
    fecha: 2026-10-18
    agente: order-blocks
    hipotesis: "los OB con barrido previo tienen esperanza positiva"
    n_pruebas: 486
    metrica: expectancy_R
    valor: 0.3793
    p_valor: 0.8474
    veredicto: refutada
    tags: [smc, order-blocks, montecarlo]
    ---
    # ...cuerpo en markdown con enlaces [[...]]
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

#: tipos de nota que entiende la bóveda
TIPOS = ("experimento", "hipotesis", "estrategia", "dato", "incidencia",
         "decision", "indice")

_FM = re.compile(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", re.DOTALL)


def _yaml_dump(d: dict) -> str:
    """Serializa el frontmatter sin depender de PyYAML.

    Solo se admiten escalares y listas planas, que es todo lo que necesita el
    cuaderno. Mantenerlo así evita una dependencia y hace el fichero trivial de
    leer a mano, que es parte del objetivo.
    """
    out = []
    for k, v in d.items():
        if isinstance(v, (list, tuple)):
            inner = ", ".join(json.dumps(x, ensure_ascii=False) if isinstance(x, str) else str(x)
                              for x in v)
            out.append(f"{k}: [{inner}]")
        elif isinstance(v, bool):
            out.append(f"{k}: {'true' if v else 'false'}")
        elif isinstance(v, (int, float)):
            out.append(f"{k}: {v}")
        elif v is None:
            out.append(f"{k}:")
        else:
            s = str(v)
            out.append(f"{k}: {json.dumps(s, ensure_ascii=False)}"
                       if any(c in s for c in ':#[]{}\n"') else f"{k}: {s}")
    return "\n".join(out)


def _yaml_load(text: str) -> dict:
    """Lee el frontmatter escrito por _yaml_dump (y lo razonablemente parecido)."""
    d: dict = {}
    for line in text.splitlines():
        line = line.rstrip()
        if not line or line.lstrip().startswith("#") or ":" not in line:
            continue
        k, _, v = line.partition(":")
        k, v = k.strip(), v.strip()
        if not v:
            d[k] = None
        elif v.startswith("[") and v.endswith("]"):
            inner = v[1:-1].strip()
            d[k] = [x.strip().strip('"') for x in inner.split(",")] if inner else []
        elif v in ("true", "false"):
            d[k] = (v == "true")
        else:
            try:
                d[k] = int(v) if re.fullmatch(r"-?\d+", v) else float(v)
            except ValueError:
                d[k] = v.strip('"')
    return d


@dataclass
class Note:
    """Una nota de la bóveda: metadatos + cuerpo markdown."""

    slug: str
    meta: dict = field(default_factory=dict)
    body: str = ""

    def render(self) -> str:
        return f"---\n{_yaml_dump(self.meta)}\n---\n\n{self.body.strip()}\n"

    @property
    def links(self) -> list[str]:
        return re.findall(r"\[\[([^\]|#]+)", self.body)


class Vault:
    """Bóveda Obsidian en disco. Crea la estructura si no existe."""

    SUBDIRS = ("00-indice", "10-experimentos", "20-hipotesis", "30-estrategias",
               "40-datos", "50-diario", "60-decisiones")

    def __init__(self, root: str | Path):
        self.root = Path(root)
        for d in self.SUBDIRS:
            (self.root / d).mkdir(parents=True, exist_ok=True)

    # ---------------------------------------------------------------- escribir

    def _dir_for(self, tipo: str) -> Path:
        return self.root / {
            "indice": "00-indice", "experimento": "10-experimentos",
            "hipotesis": "20-hipotesis", "estrategia": "30-estrategias",
            "dato": "40-datos", "incidencia": "50-diario",
            "decision": "60-decisiones",
        }.get(tipo, "10-experimentos")

    def write(self, note: Note, overwrite: bool = True) -> Path:
        tipo = str(note.meta.get("tipo", "experimento"))
        p = self._dir_for(tipo) / f"{note.slug}.md"
        if p.exists() and not overwrite:
            return p
        p.write_text(note.render(), encoding="utf-8")
        return p

    def log_experiment(self, *, agente: str, hipotesis: str, metrica: str,
                       valor: float, veredicto: str, cuerpo: str,
                       n_pruebas: int = 1, p_valor: float | None = None,
                       tags: list[str] | None = None, slug: str | None = None,
                       fecha: str | None = None, enlaces: list[str] | None = None,
                       datos: str | None = None) -> Path:
        """Registra un experimento. `n_pruebas` alimenta el libro de pruebas.

        Declarar `n_pruebas` honestamente es la obligación del agente que llama:
        si has barrido 486 especificaciones, son 486 pruebas, no una.
        """
        f = fecha or date.today().isoformat()
        sl = slug or f"{f}-{agente}-{re.sub(r'[^a-z0-9]+', '-', hipotesis.lower())[:48].strip('-')}"
        body = cuerpo.strip()
        if enlaces:
            body += "\n\n## Relacionado\n" + "\n".join(f"- [[{e}]]" for e in enlaces)
        meta = {
            "tipo": "experimento", "fecha": f, "agente": agente,
            "hipotesis": hipotesis, "n_pruebas": int(n_pruebas),
            "metrica": metrica, "valor": round(float(valor), 6),
            "veredicto": veredicto,
            "tags": tags or [agente],
        }
        if p_valor is not None:
            meta["p_valor"] = round(float(p_valor), 6)
        if datos:
            meta["datos"] = datos
        return self.write(Note(sl, meta, body))

    # ------------------------------------------------------------------- leer

    def read(self, path: Path) -> Note:
        raw = path.read_text(encoding="utf-8", errors="replace")
        m = _FM.match(raw)
        if not m:
            return Note(path.stem, {}, raw)
        return Note(path.stem, _yaml_load(m.group(1)), m.group(2))

    def notes(self, tipo: str | None = None) -> list[Note]:
        base = self._dir_for(tipo) if tipo else self.root
        return [self.read(p) for p in sorted(base.rglob("*.md"))]

    def experiments(self) -> list[Note]:
        return [n for n in self.notes("experimento")
                if n.meta.get("tipo") == "experimento"]

    # ------------------------------- libro de pruebas múltiples (lo importante)

    def counted_tests(self) -> int:
        """Total de hipótesis contrastadas en la historia del proyecto."""
        return sum(int(n.meta.get("n_pruebas", 1) or 1) for n in self.experiments())

    def corrected_threshold(self, alpha: float = 0.05,
                            extra_tests: int = 0) -> dict:
        """Umbral de significación corregido por TODO lo probado hasta hoy.

        Devuelve la corrección de Bonferroni (conservadora y transparente) y el
        umbral efectivo. Un resultado con p=0.01 que parecía bueno deja de serlo
        en cuanto el libro acumula 500 pruebas: el umbral baja a 0.0001.
        """
        n = self.counted_tests() + int(extra_tests)
        n = max(1, n)
        return {
            "pruebas_registradas": self.counted_tests(),
            "pruebas_extra": int(extra_tests),
            "pruebas_totales": n,
            "alpha_nominal": alpha,
            "alpha_bonferroni": alpha / n,
            "explicacion": (
                f"se han contrastado {n} hipotesis en este proyecto, asi que un "
                f"resultado necesita p < {alpha/n:.2e} para ser creible al "
                f"{alpha:.0%}. Un p=0.01 aislado NO basta."),
        }

    def verdict_counts(self) -> dict:
        c: dict = {}
        for n in self.experiments():
            v = str(n.meta.get("veredicto", "sin-veredicto"))
            c[v] = c.get(v, 0) + 1
        return c

    # ------------------------------------------------------------------ indice

    def rebuild_index(self) -> Path:
        """Reconstruye el mapa de contenido con tablas Dataview y el estado real."""
        exps = sorted(self.experiments(),
                      key=lambda n: str(n.meta.get("fecha", "")), reverse=True)
        thr = self.corrected_threshold()
        vc = self.verdict_counts()

        lines = [
            "# GOLD MASTER — cuaderno de laboratorio", "",
            "> Memoria del sistema. Cada experimento queda aquí con su veredicto,",
            "> y el recuento de pruebas endurece el umbral de significación.", "",
            "## Estado", "",
            f"- Experimentos registrados: **{len(exps)}**",
            f"- Hipótesis contrastadas (sumando barridos): **{thr['pruebas_totales']}**",
            f"- Umbral exigible hoy: **p < {thr['alpha_bonferroni']:.2e}** "
            f"(Bonferroni sobre α=0.05)",
            "- Veredictos: " + (", ".join(f"{k} {v}" for k, v in sorted(vc.items()))
                                or "ninguno"),
            "",
            "## Experimentos recientes", "",
            "| fecha | agente | hipótesis | métrica | valor | p | veredicto |",
            "|---|---|---|---|---|---|---|",
        ]
        for n in exps[:40]:
            m = n.meta
            p = m.get("p_valor")
            lines.append(
                f"| {m.get('fecha','')} | {m.get('agente','')} "
                f"| [[{n.slug}\\|{str(m.get('hipotesis',''))[:58]}]] "
                f"| {m.get('metrica','')} | {m.get('valor','')} "
                f"| {'' if p is None else f'{float(p):.4f}'} "
                f"| **{m.get('veredicto','')}** |")

        lines += [
            "", "## Consultas vivas (Dataview)", "",
            "```dataview", "TABLE agente, metrica, valor, p_valor, veredicto",
            'FROM "10-experimentos"', "WHERE veredicto != \"refutada\"",
            "SORT fecha DESC", "```", "",
            "```dataview", "TABLE hipotesis, n_pruebas, valor, veredicto",
            'FROM "10-experimentos"', "SORT n_pruebas DESC", "LIMIT 15", "```", "",
            "## Cómo leer esto", "",
            "Un veredicto `candidata` NO significa que funcione: significa que",
            "todavía no ha sido refutada. Antes de arriesgar dinero una hipótesis",
            "tiene que superar el umbral corregido de arriba, mantenerse estable",
            "año a año, y sobrevivir al test nulo sintético.",
        ]
        p = self.root / "00-indice" / "INDICE.md"
        p.write_text(
            Note("INDICE", {"tipo": "indice", "fecha": date.today().isoformat(),
                            "tags": ["indice", "moc"]},
                 "\n".join(lines)).render(), encoding="utf-8")
        return p


__all__ = ["Vault", "Note", "TIPOS"]
