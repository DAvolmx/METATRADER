"""
strategies/smc_fvg.py — Estrategia de EJEMPLO: continuación SMC con FVG.

Reglas (v1.0):
  1. Sesgo: estado de estructura de la temporalidad superior (bias_tf).
  2. Confirmación: en la temporalidad base, el último evento de estructura
     (BOS o CHoCH) coincide con el sesgo.
  3. Zona: FVG en la dirección del sesgo, detectado DESPUÉS de ese evento,
     aún OPEN/PARTIALLY_FILLED.
  4. Gatillo: la vela cerrada actual entra en el FVG y cierra fuera de su
     extremo lejano (respeta la zona).
  5. SL = extremo lejano del FVG ± buffer;  TP = rr × riesgo.
  6. Una operación por FVG; máximo una posición abierta.
Es un ejemplo verificable, NO una recomendación de inversión.
"""
from __future__ import annotations


class SMCFVGStrategy:
    name = "SMC_FVG_CONTINUATION"
    version = "1.0"

    def __init__(self, bias_tf: str = "H1", rr: float = 2.0, sl_buffer_points: float = 20,
                 risk_pct: float = 1.0) -> None:
        self.params = dict(bias_tf=bias_tf, rr=rr, sl_buffer_points=sl_buffer_points, risk_pct=risk_pct)
        self._used: set[int] = set()

    def on_bar(self, ctx) -> None:
        if ctx.open_trades or ctx.pending_orders:
            return
        bar = ctx.bar
        t = ctx.time
        bias = ctx.topdown.engines[self.params["bias_tf"]].state_at(t) \
            if self.params["bias_tf"] in ctx.topdown.engines else "UNKNOWN"
        if bias not in ("BULLISH", "BEARISH"):
            return
        base = ctx.smc
        evs = base.structure.events
        if not evs:
            return
        last = evs[-1]
        want = "bullish" if bias == "BULLISH" else "bearish"
        if last.direction != want:
            return
        buf = self.params["sl_buffer_points"] * ctx.spec.point
        for g in reversed(base.fvg.fvgs):
            if g.detected_at <= last.timestamp:
                break
            if id(g) in self._used or g.direction != want:
                continue
            if g.status.current not in ("OPEN", "PARTIALLY_FILLED"):
                continue
            if g.detected_at >= t:      # recién detectado en esta misma vela
                continue
            if want == "bullish" and bar.low <= g.top and bar.close > g.top:
                self._used.add(id(g))
                ctx.buy(stop_loss=g.bottom - buf, rr=self.params["rr"],
                        risk_pct=self.params["risk_pct"], comment=f"FVG {g.bottom}-{g.top}")
                return
            if want == "bearish" and bar.high >= g.bottom and bar.close < g.bottom:
                self._used.add(id(g))
                ctx.sell(stop_loss=g.top + buf, rr=self.params["rr"],
                         risk_pct=self.params["risk_pct"], comment=f"FVG {g.bottom}-{g.top}")
                return
