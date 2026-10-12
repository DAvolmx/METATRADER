"""
gm_hypothesis.py — Motor de hipótesis adaptativas para GOLD MASTER SYSTEM
Genera, registra y evalúa hipótesis de trading como reglas candidatas.

USO:
    from gm_hypothesis import HypothesisRegistry
    reg = HypothesisRegistry()
    reg.propose("bos_london_m15", "BOS en M15 durante sesión Londres (7-10 UTC)")
    reg.record_trade("bos_london_m15", r_multiple=1.5, won=True)
    reg.evaluate_all()
"""
from __future__ import annotations
import json, time, hashlib
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import List, Optional

# ── Ruta de persistencia ────────────────────────────────────────────────────
_BASE = Path(__file__).parent / "runtime"
_BASE.mkdir(parents=True, exist_ok=True)
HYPOTHESES_JSON = _BASE / "hypotheses.json"

# ── Constantes de validación ────────────────────────────────────────────────
MIN_TRADES_TO_EVALUATE = 30   # mínimo de trades para considerar válida
MIN_PROFIT_FACTOR      = 1.20 # PF mínimo para VALIDADA
MIN_WIN_RATE           = 0.40 # WR mínimo
MAX_P_VALUE            = 0.05 # significancia estadística (binomial vs 0.5)

# ── Estados posibles ────────────────────────────────────────────────────────
STATE_PROPOSED  = "PROPUESTA"
STATE_TESTING   = "EN_PRUEBA"
STATE_VALIDATED = "VALIDADA"
STATE_REJECTED  = "RECHAZADA"


@dataclass
class TradeRecord:
    timestamp:  float
    r_multiple: float
    won:        bool
    asset:      str
    tf:         str
    session:    str = ""


@dataclass
class Hypothesis:
    name:        str
    description: str
    asset:       str          = "XAUUSD"
    tf:          str          = "M15"
    state:       str          = STATE_PROPOSED
    created_at:  float        = field(default_factory=time.time)
    updated_at:  float        = field(default_factory=time.time)
    trades:      List[dict]   = field(default_factory=list)
    # métricas calculadas
    n_trades:    int          = 0
    win_rate:    float        = 0.0
    profit_factor: float      = 0.0
    expectancy_r: float       = 0.0
    score:       float        = 0.0   # 0-1 confianza compuesta
    notes:       str          = ""

    # ── ID estable ──────────────────────────────────────────────────────────
    @property
    def id(self) -> str:
        return hashlib.sha256(f"{self.name}:{self.asset}:{self.tf}".encode()).hexdigest()[:12]

    def record_trade(self, r_multiple: float, won: bool,
                     asset: str = "", tf: str = "", session: str = "") -> None:
        """Registra resultado de un trade bajo esta hipótesis."""
        self.trades.append(asdict(TradeRecord(
            timestamp=time.time(), r_multiple=r_multiple, won=won,
            asset=asset or self.asset, tf=tf or self.tf, session=session
        )))
        self.updated_at = time.time()
        self._recalculate()

    def _recalculate(self) -> None:
        """Recalcula métricas desde los trades registrados."""
        if not self.trades:
            return
        rs    = [t["r_multiple"] for t in self.trades]
        wins  = [t["won"] for t in self.trades]
        self.n_trades = len(rs)
        self.win_rate = sum(wins) / self.n_trades

        gross_win  = sum(r for r, w in zip(rs, wins) if w)
        gross_loss = abs(sum(r for r, w in zip(rs, wins) if not w))
        self.profit_factor = gross_win / gross_loss if gross_loss > 0 else 99.0
        self.expectancy_r  = sum(rs) / self.n_trades

        # score compuesto 0-1
        pf_score  = min(1.0, max(0.0, (self.profit_factor - 1.0) / 1.5))
        wr_score  = min(1.0, max(0.0, (self.win_rate - 0.35) / 0.30))
        n_score   = min(1.0, self.n_trades / 100)
        self.score = 0.4 * pf_score + 0.3 * wr_score + 0.3 * n_score

    def evaluate(self) -> str:
        """Evalúa el estado según umbrales. Devuelve el estado nuevo."""
        if self.n_trades < MIN_TRADES_TO_EVALUATE:
            new_state = STATE_TESTING if self.n_trades > 0 else STATE_PROPOSED
        elif self.profit_factor >= MIN_PROFIT_FACTOR and self.win_rate >= MIN_WIN_RATE:
            new_state = STATE_VALIDATED
        else:
            new_state = STATE_REJECTED
        self.state = new_state
        self.updated_at = time.time()
        return new_state

    def summary(self) -> str:
        return (f"[{self.state}] {self.name} | "
                f"n={self.n_trades} WR={self.win_rate:.0%} "
                f"PF={self.profit_factor:.2f} E[R]={self.expectancy_r:+.2f} "
                f"score={self.score:.2f}")


class HypothesisRegistry:
    """Repositorio persistente de hipótesis. Hilo-seguro para un solo proceso."""

    def __init__(self, path: Path = HYPOTHESES_JSON):
        self._path = path
        self._hyps: dict[str, Hypothesis] = {}
        self._load()
        self._seed_defaults()

    # ── Persistencia ────────────────────────────────────────────────────────
    def _load(self) -> None:
        if not self._path.exists():
            return
        try:
            raw = json.loads(self._path.read_text(encoding="utf-8"))
            for d in raw.get("hypotheses", []):
                h = Hypothesis(**{k: v for k, v in d.items() if k != "id"})
                self._hyps[h.name] = h
        except Exception as e:
            print(f"[HypothesisRegistry] Aviso al cargar: {e}")

    def _save(self) -> None:
        data = {"version": 1, "updated_at": time.time(),
                "hypotheses": [asdict(h) for h in self._hyps.values()]}
        self._path.write_text(json.dumps(data, indent=2, ensure_ascii=False),
                              encoding="utf-8")

    def _seed_defaults(self) -> None:
        """Hipótesis iniciales si el registro está vacío."""
        defaults = [
            Hypothesis(
                name="sesion_Londres",
                description="Operar solo durante sesión Londres 07:00-10:00 UTC mejora WR",
                asset="XAUUSD", tf="M15",
                notes="Basado en análisis de sesiones: 60-70% del movimiento diario ocurre aquí"
            ),
            Hypothesis(
                name="BOS_H1_grande",
                description="BOS en H1 con vela de ruptura >1.5×ATR tiene mayor continuación",
                asset="XAUUSD", tf="H1",
                notes="Filtra BOS débiles; esperar retroceso a nivel fracturado"
            ),
            Hypothesis(
                name="confluencia_H4_M15",
                description="Señal M15 en dirección de estructura H4 mejora PF vs señal M15 sola",
                asset="XAUUSD", tf="M15",
                notes="HTF da el sesgo, LTF da la entrada. Documentado en datos propios"
            ),
            Hypothesis(
                name="evitar_noticias_2h",
                description="Evitar trades en 2h antes/después de NFP/CPI/Fed elimina outliers negativos",
                asset="XAUUSD", tf="M15",
                notes="Volatilidad extrema destruye el edge técnico en esas ventanas"
            ),
        ]
        added = False
        for h in defaults:
            if h.name not in self._hyps:
                self._hyps[h.name] = h
                added = True
        if added:
            self._save()

    # ── API pública ──────────────────────────────────────────────────────────
    def propose(self, name: str, description: str,
                asset: str = "XAUUSD", tf: str = "M15",
                notes: str = "") -> Hypothesis:
        """Propone una hipótesis nueva. No reemplaza si ya existe."""
        if name in self._hyps:
            return self._hyps[name]
        h = Hypothesis(name=name, description=description,
                       asset=asset, tf=tf, notes=notes)
        self._hyps[name] = h
        self._save()
        return h

    def record_trade(self, name: str, r_multiple: float, won: bool,
                     session: str = "") -> Optional[Hypothesis]:
        """Registra un trade bajo una hipótesis y guarda."""
        h = self._hyps.get(name)
        if h is None:
            print(f"[HypothesisRegistry] Hipótesis '{name}' no existe.")
            return None
        h.record_trade(r_multiple, won, session=session)
        self._save()
        return h

    def evaluate_all(self) -> dict[str, str]:
        """Evalúa todas las hipótesis y devuelve {nombre: estado}."""
        results = {}
        for h in self._hyps.values():
            results[h.name] = h.evaluate()
        self._save()
        return results

    def get_validated(self, min_score: float = 0.6) -> List[Hypothesis]:
        """Devuelve hipótesis VALIDADAS con score >= min_score."""
        return [h for h in self._hyps.values()
                if h.state == STATE_VALIDATED and h.score >= min_score]

    def get_all(self) -> List[Hypothesis]:
        return list(self._hyps.values())

    def print_summary(self) -> None:
        print(f"\n{'='*60}")
        print(f"HYPOTHESIS REGISTRY — {len(self._hyps)} hipótesis")
        print('='*60)
        for h in sorted(self._hyps.values(), key=lambda x: x.score, reverse=True):
            print(f"  {h.summary()}")
        print('='*60)


# ── CLI rápida ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    reg = HypothesisRegistry()
    reg.print_summary()
    print(f"\nArchivo: {HYPOTHESES_JSON}")
