"""
gm_guardian.py — Guardián de Riesgo + Diario que aprende de TU operativa.

Es la capa que protege la cuenta (lo que demostramos que mata cuentas pequeñas: el
TAMAÑO, no la estrategia — 72% de ruina en micro con $10) y captura cada operación
con su contexto para que el sistema aprenda TU edge discrecional (lo único con
evidencia real de funcionar).

Tres partes, sin depender de MT5 (testeable headless):

  1. RiskGovernor.evaluate(equity, stop_distance, ctx) -> decisión:
     aplica la escalera de capital (micro→normal), tope de riesgo %/op, objetivo y
     stop diarios, máx. operaciones/día, bloqueo por noticias, por régimen "agitado"
     y por spread, y el SUELO de lote mínimo. Devuelve lote permitido, riesgo en $,
     si se permite y POR QUÉ. Nunca deja sobredimensionar.

  2. Journal: registra cada operación con su contexto (régimen, DXY, banda del
     pronóstico, confluencia, hora, spread, resultado R) en JSONL. stats() resume.

  3. learn_from_journal(): entrena un clasificador contexto→ganancia con TUS trades,
     así el ML copia lo que a ti te funciona en vez de señales mecánicas que fallan.
"""
from __future__ import annotations

import json
import sys
import time
from dataclasses import dataclass, asdict, field
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "offline"))
try:
    from gm_capital import Stage, DEFAULT_STAGES          # reutiliza la escalera
except Exception:
    @dataclass
    class Stage:
        name: str; equity_from: float; equity_to: float; risk_pct: float
        daily_target: float; daily_loss: float; max_trades_day: int
    DEFAULT_STAGES = [
        Stage("semilla $10-$25", 0, 25, 3.0, 2.0, 1.5, 3),
        Stage("construir $25-$50", 25, 50, 3.5, 4.0, 2.5, 4),
        Stage("acelerar $50+", 50, float("inf"), 6.0, 12.0, 8.0, 6)]

# Economía por símbolo: (lote mínimo, USD por 1.0 de precio por 1.0 lote)
SYMBOLS = {
    "XAUUSDmicro": dict(min_lot=0.1, usd_per_price_per_lot=1.0),   # 0.1 lot ≈ $0.10/$
    "XAUUSD":      dict(min_lot=0.01, usd_per_price_per_lot=100.0),  # 0.01 lot ≈ $1/$
}


@dataclass
class GuardianConfig:
    symbol: str = "XAUUSDmicro"
    stages: list = field(default_factory=lambda: list(DEFAULT_STAGES))
    max_risk_frac: float = 0.5          # si ni el lote mínimo cabe bajo esto -> bloquea
    #: múltiplo máximo del objetivo de etapa que se tolera cuando el lote
    #: mínimo impide bajar más. Por encima de esto se bloquea en vez de dejar
    #: que la cuenta opere al triple del riesgo planeado sin enterarse.
    over_target_max: float = 2.0
    news_blackout_min: int = 30         # no operar a < X min de noticia de alto impacto
    max_spread_points: float = 60.0     # spread máximo (en puntos de 0.01)
    block_regimes: tuple = ("agitado",) # regímenes donde no se opera (perdía -0.17R)
    min_pretrade_score: int = 50        # por debajo, se avisa (no bloquea por sí solo)


def _stage_for(equity, stages):
    for s in stages:
        if s.equity_from <= equity < s.equity_to:
            return s
    return stages[-1]


class RiskGovernor:
    def __init__(self, cfg: GuardianConfig | None = None):
        self.cfg = cfg or GuardianConfig()
        self._day = None; self.day_pnl = 0.0; self.day_trades = 0

    def _roll_day(self, now: datetime):
        d = now.date()
        if d != self._day:
            self._day = d; self.day_pnl = 0.0; self.day_trades = 0

    def register_result(self, pnl_usd: float, now: datetime | None = None):
        self._roll_day(now or datetime.now(timezone.utc))
        self.day_pnl += pnl_usd; self.day_trades += 1

    def export_limits(self, bridge_dir) -> str:
        """Escribe guardian.txt para que GoldMaster_Guardian.mqh (el EA) sincronice límites."""
        p = Path(bridge_dir); p.mkdir(parents=True, exist_ok=True)
        f = p / "guardian.txt"
        f.write_text(f"news_blackout_min={self.cfg.news_blackout_min}\n"
                     f"max_spread_points={self.cfg.max_spread_points}\n"
                     f"max_risk_frac={self.cfg.max_risk_frac}\n"
                     f"over_target_max={self.cfg.over_target_max}\n", encoding="utf-8")
        return str(f)

    def pretrade_score(self, ctx: dict) -> tuple[int, list[str]]:
        """0-100 según confluencia con el contexto. No bloquea solo; informa."""
        s = 50; w = []
        reg = ctx.get("regime")
        if reg == "calmo": s += 15
        elif reg == "agitado": s -= 25; w.append("régimen agitado (histórico −0.17R)")
        side = ctx.get("side", 0)
        dxy = ctx.get("dxy_bias", 0)                 # +1 dólar sube, -1 baja
        if dxy and side and (dxy * side < 0): s += 10   # oro sube si el dólar baja
        elif dxy and side and (dxy * side > 0): s -= 10; w.append("DXY en contra")
        if ctx.get("confluence", 0) >= 3: s += 15
        if ctx.get("forecast_in_band") is False: s -= 10; w.append("fuera de la banda del pronóstico")
        nn = ctx.get("near_news_min")
        if nn is not None and nn <= self.cfg.news_blackout_min: s -= 20; w.append("noticia inminente")
        return max(0, min(100, s)), w

    def evaluate(self, equity: float, stop_distance: float, ctx: dict | None = None,
                 now: datetime | None = None) -> dict:
        """Decide si se puede operar y con qué lote/riesgo. stop_distance en precio."""
        ctx = ctx or {}
        now = now or datetime.now(timezone.utc)
        self._roll_day(now)
        stage = _stage_for(equity, self.cfg.stages)
        sym = SYMBOLS.get(self.cfg.symbol, SYMBOLS["XAUUSDmicro"])
        score, warns = self.pretrade_score(ctx)

        def block(reason):
            return dict(allow=False, reason=reason, stage=stage.name, score=score,
                        warnings=warns, lot=0.0, risk_usd=0.0)

        # --- bloqueos duros ---
        if stop_distance <= 0:
            return block("stop inválido")
        if self.day_trades >= stage.max_trades_day:
            return block(f"tope diario de operaciones ({stage.max_trades_day})")
        if self.day_pnl >= stage.daily_target:
            return block(f"objetivo diario alcanzado (${stage.daily_target:.2f}) — guarda y para")
        if self.day_pnl <= -stage.daily_loss:
            return block(f"stop diario alcanzado (−${stage.daily_loss:.2f}) — protección")
        if ctx.get("regime") in self.cfg.block_regimes:
            return block(f"régimen {ctx.get('regime')} bloqueado")
        nn = ctx.get("near_news_min")
        if nn is not None and nn <= self.cfg.news_blackout_min:
            return block(f"noticia de alto impacto en {nn} min (blackout {self.cfg.news_blackout_min})")
        sp = ctx.get("spread_points")
        if sp is not None and sp > self.cfg.max_spread_points:
            return block(f"spread {sp} > máximo {self.cfg.max_spread_points}")

        # --- dimensionamiento con suelo de lote mínimo ---
        want_risk = stage.risk_pct / 100.0 * equity
        ppl = sym["usd_per_price_per_lot"]; min_lot = sym["min_lot"]
        min_risk = min_lot * stop_distance * ppl
        if min_risk > self.cfg.max_risk_frac * equity:
            return block(f"ni el lote mínimo cabe: arriesga ${min_risk:.2f} "
                         f"(> {self.cfg.max_risk_frac*100:.0f}% de ${equity:.2f}). "
                         f"Usa cuenta cent o más capital.")
        lot = max(min_lot, round(want_risk / (stop_distance * ppl) / min_lot) * min_lot)
        risk_usd = lot * stop_distance * ppl
        # recorta si por redondeo se pasa del objetivo
        while risk_usd > self.cfg.max_risk_frac * equity and lot > min_lot:
            lot = round((lot - min_lot) / min_lot) * min_lot; risk_usd = lot * stop_distance * ppl

        # --- el riesgo real puede superar al de la etapa, y hay que DECIRLO ---
        # Cuando el lote mínimo no permite bajar hasta el objetivo de la etapa,
        # la operación pasa igualmente mientras quepa bajo max_risk_frac. Eso
        # deja un hueco peligroso: una etapa que declara 3.5% puede acabar
        # arriesgando 8.4% y el panel lo mostraba como "PERMITIDO" sin más.
        # Ahora se calcula el exceso, se avisa, y si supera `over_target_max`
        # veces el objetivo se BLOQUEA: para una cuenta pequeña, arriesgar el
        # triple de lo planeado en cada operación es la via rapida a la ruina.
        risk_pct = risk_usd / equity * 100.0
        over = risk_pct / stage.risk_pct if stage.risk_pct > 0 else 1.0
        forced = risk_usd > want_risk * 1.05        # el lote mínimo manda
        if forced and over > self.cfg.over_target_max:
            return block(
                f"el lote mínimo fuerza {risk_pct:.1f}% de riesgo, "
                f"{over:.1f}x el {stage.risk_pct:.1f}% de la etapa '{stage.name}' "
                f"(máximo {self.cfg.over_target_max:.1f}x). "
                f"Usa cuenta cent, un stop más ajustado, o capitaliza más.")
        if forced:
            warns.append(
                f"riesgo {risk_pct:.1f}% = {over:.1f}x el objetivo de etapa "
                f"({stage.risk_pct:.1f}%): lo impone el lote mínimo, no la señal")
        return dict(allow=True, reason="ok", stage=stage.name, score=score, warnings=warns,
                    lot=round(lot, 2), risk_usd=round(risk_usd, 2),
                    risk_pct=round(risk_pct, 2),
                    stage_target_pct=stage.risk_pct,
                    risk_over_target=bool(forced),
                    over_target_x=round(over, 2),
                    day_trades=self.day_trades, day_pnl=round(self.day_pnl, 2))


class Journal:
    """Diario de operaciones con contexto, en JSONL (una línea por trade)."""
    def __init__(self, path: Path | None = None):
        self.path = Path(path) if path else (HERE.parent / "offline" / "out_offline" / "journal.jsonl")
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def record(self, trade: dict):
        trade = {"ts": int(time.time()), **trade}
        with open(self.path, "a", encoding="utf-8") as f:
            f.write(json.dumps(trade, ensure_ascii=False) + "\n")
        return trade

    def load(self) -> list[dict]:
        if not self.path.exists():
            return []
        return [json.loads(l) for l in self.path.read_text(encoding="utf-8").splitlines() if l.strip()]

    def stats(self) -> dict:
        t = self.load()
        if not t:
            return dict(n=0)
        rs = [x.get("R", 0.0) for x in t if "R" in x]
        wins = [r for r in rs if r > 0]
        pnl = [x.get("pnl_usd", 0.0) for x in t]
        return dict(n=len(t), with_R=len(rs),
                    win_rate=round(len(wins) / len(rs) * 100, 1) if rs else None,
                    expectancy_R=round(sum(rs) / len(rs), 3) if rs else None,
                    net_usd=round(sum(pnl), 2),
                    by_regime=_group_exp(t, "regime"))


def _group_exp(trades, key):
    g = {}
    for x in trades:
        k = x.get("ctx", {}).get(key) or x.get(key)
        if k is None or "R" not in x:
            continue
        g.setdefault(k, []).append(x["R"])
    return {k: dict(n=len(v), exp=round(sum(v) / len(v), 3)) for k, v in g.items()}


FEATURES = ["side", "regime_code", "dxy_bias", "confluence", "hour", "spread_points", "forecast_in_band"]


def _vec(x):
    ctx = x.get("ctx", x)
    reg = {"calmo": 1, "normal": 0, "agitado": -1}.get(ctx.get("regime"), 0)
    fib = ctx.get("forecast_in_band"); fib = 1 if fib else (0 if fib is False else 0)
    return [float(ctx.get("side", 0)), float(reg), float(ctx.get("dxy_bias", 0)),
            float(ctx.get("confluence", 0)), float(ctx.get("hour", 0)),
            float(ctx.get("spread_points", 0)), float(fib)]


def learn_from_journal(journal: Journal, min_trades: int = 60) -> dict:
    """Entrena contexto→ganancia con TUS operaciones. Solo investigación."""
    t = [x for x in journal.load() if "R" in x]
    if len(t) < min_trades:
        return {"trained": False, "reason": f"faltan trades ({len(t)}/{min_trades})",
                "note": "sigue operando: cada trade con contexto alimenta esto"}
    try:
        import numpy as np
        from sklearn.ensemble import HistGradientBoostingClassifier
        from sklearn.metrics import roc_auc_score
    except Exception as e:
        return {"trained": False, "reason": f"scikit-learn no disponible ({e})"}
    import numpy as np
    X = np.array([_vec(x) for x in t]); y = np.array([int(x["R"] > 0) for x in t])
    if len(set(y)) < 2:
        return {"trained": False, "reason": "hacen falta ganadoras y perdedoras"}
    split = int(len(X) * 0.7)
    gb = HistGradientBoostingClassifier(max_depth=3, max_iter=200, random_state=1).fit(X[:split], y[:split])
    p = gb.predict_proba(X[split:])[:, 1]
    auc = float(roc_auc_score(y[split:], p)) if len(set(y[split:])) > 1 else None
    return {"trained": True, "n": len(t), "auc_oos": auc, "features": FEATURES,
            "status": "research_only", "promotion_allowed": False}


if __name__ == "__main__":
    g = RiskGovernor(GuardianConfig(symbol="XAUUSDmicro"))
    # ejemplo: cuenta $12, stop de $4, régimen normal, sin noticias
    dec = g.evaluate(12.0, 4.0, dict(regime="normal", side=1, dxy_bias=-1, confluence=3,
                                     spread_points=18, near_news_min=120))
    print("decisión:", json.dumps(dec, ensure_ascii=False))
    dec2 = g.evaluate(12.0, 4.0, dict(regime="agitado", side=1))
    print("en agitado:", dec2["allow"], "·", dec2["reason"])
    j = Journal(); print("journal stats:", j.stats())
