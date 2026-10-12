"""
gm_rules_db.py — Registro de reglas de trading validadas para GOLD MASTER SYSTEM

Las reglas se promueven desde hipótesis validadas (gm_hypothesis.py).
El EA MQL5 lee rules_db.json para combinar señales activas.

USO:
    from gm_rules_db import RulesDB
    db = RulesDB()
    db.promote_from_hypothesis(hyp)          # desde Hypothesis validada
    rules = db.get_active_rules("XAUUSD", "M15", min_score=0.6)
"""
from __future__ import annotations
import json, time
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import List, Optional

_BASE = Path(__file__).parent / "runtime"
_BASE.mkdir(parents=True, exist_ok=True)
RULES_DB_JSON = _BASE / "rules_db.json"


@dataclass
class Rule:
    name:             str
    description:      str
    asset:            str
    tf:               str
    score:            float        # 0-1 confianza
    evidence_trades:  int          # trades que respaldan la regla
    win_rate:         float
    profit_factor:    float
    expectancy_r:     float
    active:           bool         = True
    created_at:       float        = field(default_factory=time.time)
    last_validated:   float        = field(default_factory=time.time)
    last_updated:     float        = field(default_factory=time.time)
    decay_trades:     int          = 0   # trades desde última validación
    notes:            str          = ""
    source_hypothesis: str         = ""  # nombre de la hipótesis origen

    def deactivate(self, reason: str = "") -> None:
        self.active = False
        self.last_updated = time.time()
        if reason:
            self.notes = f"[DESACTIVADA: {reason}] " + self.notes

    def update_decay(self, new_r: float, won: bool) -> None:
        """Actualiza decay counter. Si el edge decae, desactiva."""
        self.decay_trades += 1
        self.last_updated = time.time()
        # Revalidar cada 20 trades post-validación
        if self.decay_trades >= 20:
            # Señal de alerta: PF estimado en decay window
            # (lógica completa en gm_market_service.py)
            pass


class RulesDB:
    """Base de datos de reglas de trading validadas."""

    def __init__(self, path: Path = RULES_DB_JSON):
        self._path = path
        self._rules: dict[str, Rule] = {}
        self._load()

    def _load(self) -> None:
        if not self._path.exists():
            return
        try:
            raw = json.loads(self._path.read_text(encoding="utf-8"))
            for d in raw.get("rules", []):
                r = Rule(**d)
                self._rules[r.name] = r
        except Exception as e:
            print(f"[RulesDB] Aviso al cargar: {e}")

    def _save(self) -> None:
        data = {
            "version": 1,
            "updated_at": time.time(),
            "total_rules": len(self._rules),
            "active_rules": sum(1 for r in self._rules.values() if r.active),
            "rules": [asdict(r) for r in self._rules.values()]
        }
        self._path.write_text(json.dumps(data, indent=2, ensure_ascii=False),
                              encoding="utf-8")

    # ── API pública ──────────────────────────────────────────────────────────
    def promote_from_hypothesis(self, hyp) -> Optional[Rule]:
        """Promueve una hipótesis validada a regla activa."""
        if hyp.state != "VALIDADA":
            print(f"[RulesDB] '{hyp.name}' no está VALIDADA (estado: {hyp.state})")
            return None
        rule = Rule(
            name=hyp.name,
            description=hyp.description,
            asset=hyp.asset,
            tf=hyp.tf,
            score=hyp.score,
            evidence_trades=hyp.n_trades,
            win_rate=hyp.win_rate,
            profit_factor=hyp.profit_factor,
            expectancy_r=hyp.expectancy_r,
            notes=hyp.notes,
            source_hypothesis=hyp.name,
        )
        self._rules[rule.name] = rule
        self._save()
        print(f"[RulesDB] '{rule.name}' promovida → score={rule.score:.2f}")
        return rule

    def add_manual(self, name: str, description: str, asset: str, tf: str,
                   score: float, evidence_trades: int, win_rate: float,
                   profit_factor: float, expectancy_r: float,
                   notes: str = "") -> Rule:
        """Añade una regla manualmente (ej. basada en literatura)."""
        rule = Rule(name=name, description=description, asset=asset, tf=tf,
                    score=score, evidence_trades=evidence_trades,
                    win_rate=win_rate, profit_factor=profit_factor,
                    expectancy_r=expectancy_r, notes=notes)
        self._rules[name] = rule
        self._save()
        return rule

    def get_active_rules(self, symbol: str = "XAUUSD",
                         tf: str = "M15",
                         min_score: float = 0.6) -> List[Rule]:
        """API para el EA: devuelve reglas activas por símbolo, TF y score."""
        return [r for r in self._rules.values()
                if r.active
                and r.asset == symbol
                and r.tf == tf
                and r.score >= min_score]

    def deactivate(self, name: str, reason: str = "") -> bool:
        if name not in self._rules:
            return False
        self._rules[name].deactivate(reason)
        self._save()
        return True

    def export_for_ea(self, symbol: str = "XAUUSD", tf: str = "M15",
                      min_score: float = 0.5) -> dict:
        """
        Exporta reglas activas en formato simple que puede leer MQL5
        via FileReadString / JSON parse en el EA.
        """
        active = self.get_active_rules(symbol, tf, min_score)
        return {
            "symbol": symbol, "tf": tf, "generated_at": time.time(),
            "rules": [
                {"name": r.name, "score": round(r.score, 3),
                 "wr": round(r.win_rate, 3), "pf": round(r.profit_factor, 2),
                 "exp_r": round(r.expectancy_r, 3)}
                for r in sorted(active, key=lambda x: x.score, reverse=True)
            ]
        }

    def print_summary(self) -> None:
        print(f"\n{'='*60}")
        print(f"RULES DB — {len(self._rules)} reglas "
              f"({sum(1 for r in self._rules.values() if r.active)} activas)")
        print('='*60)
        for r in sorted(self._rules.values(), key=lambda x: x.score, reverse=True):
            status = "✅" if r.active else "❌"
            print(f"  {status} [{r.tf}] {r.name} "
                  f"score={r.score:.2f} WR={r.win_rate:.0%} PF={r.profit_factor:.2f}")
        print('='*60)


if __name__ == "__main__":
    db = RulesDB()
    # Ejemplo: añadir regla manual basada en literatura
    if not db._rules:
        db.add_manual(
            name="sesion_Londres_manual",
            description="Filtro de sesión Londres — solo operar 07-10 UTC",
            asset="XAUUSD", tf="M15",
            score=0.65, evidence_trades=0,
            win_rate=0.0, profit_factor=0.0, expectancy_r=0.0,
            notes="Regla manual basada en análisis de sesiones. Requiere validación con datos."
        )
    db.print_summary()
    ea_payload = db.export_for_ea("XAUUSD", "M15")
    print(f"\nExport EA: {json.dumps(ea_payload, indent=2)}")
    print(f"\nArchivo: {RULES_DB_JSON}")
