"""
gm_ob_strategies.py — Espacio de estrategias sobre order blocks, y su backtest.

Una estrategia de order block no es una sola regla: es una COMBINACIÓN de
decisiones, y cada decisión cambia el resultado. Este módulo parametriza todas
y las prueba con el mismo motor, para poder comparar manzanas con manzanas:

  zona        full (mecha a mecha) · body (cuerpo) · eq (50%, equilibrio/OTE)
  entrada     touch (borde próximo) · eq (mitad) · deep (borde lejano)
  stop        borde distal de la zona + colchón en ATR
  objetivo    múltiplo de R, o estructura
  filtros     escenario, sweep previo, FVG, extremo del rango, BOS, sesión
  caducidad   barras máximas esperando entrada, y barras máximas en posición

────────────────────────────────────────────────────────────────────────────────
HONESTIDAD DEL MOTOR
────────────────────────────────────────────────────────────────────────────────
1. ANTI-LOOK-AHEAD. La entrada solo se busca a partir de confirm_index+1. Si la
   estrategia filtra por FVG, el arranque se retrasa a fvg_known_index+1, porque
   el imbalance de 3 velas no se conoce hasta que cierra la tercera.
2. SL ANTES QUE TP. Si una misma barra toca stop y objetivo, se asume stop. Es
   la hipótesis conservadora: sin datos de ticks no se sabe el orden real, y la
   alternativa optimista es exactamente cómo se fabrican backtests bonitos.
3. COSTES REALES. Spread y deslizamiento se descuentan en unidades de precio al
   entrar y al salir, no se ignoran ni se "asumen pequeños".
4. SIN REOPTIMIZACIÓN OCULTA. El motor no ajusta nada: recibe la especificación
   y devuelve las operaciones. Quien elija la mejor de N especificaciones carga
   con el sesgo de selección múltiple, y gm_ob_montecarlo lo mide.
"""
from __future__ import annotations

import itertools
from dataclasses import dataclass, asdict

import numpy as np
import pandas as pd


@dataclass(frozen=True)
class TradeSpec:
    """Una estrategia concreta del espacio de order blocks."""

    zone: str = "full"          # full | body | eq
    entry: str = "touch"        # touch | eq | deep
    sl_buffer_atr: float = 0.25
    tp_r: float = 2.0
    max_wait: int = 48          # barras esperando que el precio entre en zona
    max_hold: int = 96          # barras máximas en posición
    # filtros (None = no filtra)
    subtype: str | None = None
    require_sweep: bool = False
    require_fvg: bool = False
    require_extreme: bool = False
    require_bos: bool = False
    session: str | None = None
    kind: str | None = None     # bullish | bearish | None = ambos

    def label(self) -> str:
        bits = [self.zone, self.entry, f"tp{self.tp_r:g}R"]
        if self.subtype:
            bits.append(self.subtype)
        for flag, name in ((self.require_sweep, "sweep"), (self.require_fvg, "fvg"),
                           (self.require_extreme, "ext"), (self.require_bos, "bos")):
            if flag:
                bits.append(name)
        if self.session:
            bits.append(self.session)
        if self.kind:
            bits.append(self.kind)
        return "·".join(bits)


@dataclass(frozen=True)
class Costs:
    """Costes en unidades de PRECIO del instrumento (oro: dólares por onza)."""

    spread: float = 0.30
    slippage: float = 0.10

    @property
    def total(self) -> float:
        return self.spread + self.slippage


def _zone_edges(r: pd.Series, zone: str) -> tuple[float, float]:
    """Devuelve (techo, suelo) de la zona según el refinamiento elegido."""
    if zone == "body":
        return float(r["zone_body_top"]), float(r["zone_body_bot"])
    if zone == "eq":
        eq = float(r["zone_eq"])
        if r["kind"] == "bullish":
            return eq, float(r["zone_full_bot"])
        return float(r["zone_full_top"]), eq
    return float(r["zone_full_top"]), float(r["zone_full_bot"])


def _passes(r: pd.Series, spec: TradeSpec) -> bool:
    if spec.kind and r["kind"] != spec.kind:
        return False
    if spec.subtype and r["subtype"] != spec.subtype:
        return False
    if spec.require_sweep and not r["sweep_before"]:
        return False
    if spec.require_fvg and not r["fvg_paired"]:
        return False
    if spec.require_extreme and not r["is_extreme"]:
        return False
    if spec.require_bos and not r["bos_confirmed"]:
        return False
    if spec.session and r["session"] != spec.session:
        return False
    return True


def backtest(df: pd.DataFrame, obs: pd.DataFrame, spec: TradeSpec,
             costs: Costs | None = None) -> pd.DataFrame:
    """Ejecuta una especificación sobre los OB detectados. Devuelve operaciones.

    Cada fila es una operación con su R neto de costes, para que las métricas y
    el Monte Carlo trabajen siempre sobre la misma unidad.
    """
    costs = costs or Costs()
    if obs.empty:
        return pd.DataFrame()
    h = df["high"].to_numpy(dtype=float)
    l = df["low"].to_numpy(dtype=float)
    c = df["close"].to_numpy(dtype=float)
    n = len(df)
    out: list[dict] = []

    for _, r in obs.iterrows():
        if not _passes(r, spec):
            continue
        # arranque: nunca antes de confirmar; si se filtra por FVG, tampoco
        # antes de que ese FVG sea conocible
        start = int(r["confirm_index"]) + 1
        if spec.require_fvg:
            fk = int(r.get("fvg_known_index", -1))
            if fk >= 0:
                start = max(start, fk + 1)
        if start >= n:
            continue

        top, bot = _zone_edges(r, spec.zone)
        if not (np.isfinite(top) and np.isfinite(bot)) or top <= bot:
            continue
        bull = r["kind"] == "bullish"
        atr_v = float(r["atr_at_confirm"])
        eqp = (top + bot) / 2.0

        # precio objetivo de entrada según el refinamiento
        want = {"touch": top if bull else bot,
                "eq": eqp,
                "deep": bot if bull else top}[spec.entry]

        # --- esperar a que el precio entre en zona ---
        wait_end = min(n, start + spec.max_wait)
        fill = -1
        for k in range(start, wait_end):
            if (l[k] <= want) if bull else (h[k] >= want):
                fill = k
                break
        if fill < 0:
            continue

        # --- stop al borde distal + colchón; coste en la entrada ---
        if bull:
            entry = want + costs.total / 2.0
            sl = bot - spec.sl_buffer_atr * atr_v
            risk = entry - sl
        else:
            entry = want - costs.total / 2.0
            sl = top + spec.sl_buffer_atr * atr_v
            risk = sl - entry
        if risk <= 0:
            continue
        tp = entry + spec.tp_r * risk if bull else entry - spec.tp_r * risk

        # --- recorrer la posición; stop antes que objetivo en la misma barra ---
        hold_end = min(n, fill + 1 + spec.max_hold)
        res_r, bars, why = None, 0, "timeout"
        for k in range(fill, hold_end):
            bars = k - fill
            hit_sl = (l[k] <= sl) if bull else (h[k] >= sl)
            hit_tp = (h[k] >= tp) if bull else (l[k] <= tp)
            if hit_sl:                       # conservador: el stop manda
                res_r, why = -1.0, "sl"
                break
            if hit_tp:
                res_r, why = float(spec.tp_r), "tp"
                break
        if res_r is None:                    # cierre por caducidad, a mercado
            last = c[min(hold_end, n) - 1]
            gross = (last - entry) if bull else (entry - last)
            res_r = float((gross - costs.total / 2.0) / risk)

        out.append({
            "ob_index": int(r["ob_index"]), "confirm_index": int(r["confirm_index"]),
            "entry_index": int(fill), "entry_time": df.index[fill],
            "kind": r["kind"], "subtype": r["subtype"],
            "entry": entry, "sl": sl, "tp": tp, "risk_price": risk,
            "R": res_r, "exit_reason": why, "bars_held": bars,
            "cost_R": float(costs.total / risk),
            "session": r["session"], "sweep_before": bool(r["sweep_before"]),
            "fvg_paired": bool(r["fvg_paired"]), "is_extreme": bool(r["is_extreme"]),
            "bos_confirmed": bool(r["bos_confirmed"]),
        })
    return pd.DataFrame(out)


def metrics(trades: pd.DataFrame, min_trades: int = 30) -> dict:
    """Métricas de una serie de operaciones, en R. Sin maquillaje."""
    if trades is None or trades.empty:
        return {"n": 0, "verdict": "sin operaciones"}
    R = trades["R"].to_numpy(dtype=float)
    n = len(R)
    wins, losses = R[R > 0], R[R <= 0]
    gross_win, gross_loss = float(wins.sum()), float(-losses.sum())
    exp_r = float(R.mean())
    sd = float(R.std(ddof=1)) if n > 1 else 0.0
    eq = np.cumsum(R)
    peak = np.maximum.accumulate(np.concatenate([[0.0], eq]))
    dd = float((np.concatenate([[0.0], eq]) - peak).min())
    # t de Student sobre la esperanza: ¿se distingue de cero?
    tstat = float(exp_r / (sd / np.sqrt(n))) if sd > 0 and n > 1 else 0.0
    out = {
        "n": n,
        "expectancy_R": round(exp_r, 4),
        "total_R": round(float(R.sum()), 2),
        "win_rate_pct": round(100.0 * len(wins) / n, 2),
        "profit_factor": round(gross_win / gross_loss, 3) if gross_loss > 0 else np.inf,
        "sd_R": round(sd, 3),
        "t_stat": round(tstat, 2),
        "sharpe_per_trade": round(exp_r / sd, 4) if sd > 0 else 0.0,
        "max_dd_R": round(dd, 2),
        "avg_bars": round(float(trades["bars_held"].mean()), 1),
        "cost_R_mean": round(float(trades["cost_R"].mean()), 4),
        "pct_tp": round(100.0 * float((trades["exit_reason"] == "tp").mean()), 1),
        "pct_sl": round(100.0 * float((trades["exit_reason"] == "sl").mean()), 1),
        "pct_timeout": round(100.0 * float((trades["exit_reason"] == "timeout").mean()), 1),
    }
    # veredicto deliberadamente severo: |t|>2 es el mínimo para mirarlo, y aun
    # así no corrige por haber probado muchas especificaciones
    if n < min_trades:
        out["verdict"] = f"muestra insuficiente (<{min_trades})"
    elif exp_r <= 0:
        out["verdict"] = "esperanza negativa"
    elif tstat < 2.0:
        out["verdict"] = "no distinguible de cero"
    else:
        out["verdict"] = "candidato (pendiente de correccion por multiples pruebas)"
    return out


def grid(zones=("full", "body", "eq"), entries=("touch", "eq", "deep"),
         tps=(1.5, 2.0, 3.0), subtypes=(None, "classic", "breaker", "rejection",
                                        "propulsion", "mitigation"),
         flags=((False, False), (True, False), (False, True)),
         kinds=(None,)) -> list[TradeSpec]:
    """Genera el espacio de estrategias a barrer.

    `flags` son pares (require_sweep, require_extreme). El número de
    especificaciones es el que luego hay que penalizar por pruebas múltiples:
    con este espacio salen cientos, y el mejor resultado de cientos de pruebas
    sobre ruido parece excelente por pura suerte.
    """
    specs = []
    for z, e, tp, st, (sw, ex), k in itertools.product(
            zones, entries, tps, subtypes, flags, kinds):
        specs.append(TradeSpec(zone=z, entry=e, tp_r=tp, subtype=st,
                               require_sweep=sw, require_extreme=ex, kind=k))
    return specs


def sweep(df: pd.DataFrame, obs: pd.DataFrame, specs: list[TradeSpec],
          costs: Costs | None = None, min_trades: int = 30) -> pd.DataFrame:
    """Prueba muchas especificaciones y devuelve una tabla ordenada."""
    rows = []
    for sp in specs:
        t = backtest(df, obs, sp, costs)
        m = metrics(t, min_trades)
        m["spec"] = sp.label()
        m.update({f"p_{k}": v for k, v in asdict(sp).items()})
        rows.append(m)
    res = pd.DataFrame(rows)
    return res.sort_values("expectancy_R", ascending=False).reset_index(drop=True)


__all__ = ["TradeSpec", "Costs", "backtest", "metrics", "grid", "sweep"]
