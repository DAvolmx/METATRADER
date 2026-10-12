"""Causal SMC candidate with explicit quality/cost/risk gates. Not certified alpha."""
from collections import Counter
import math


class SMCQualityStrategy:
    name, version = "SMC_QUALITY_CANDIDATE", "1.0"

    def __init__(self, bias_tf="H1", rr=2.0, sl_buffer_points=20, risk_pct=.25):
        self.params = dict(bias_tf=bias_tf,rr=rr,sl_buffer_points=sl_buffer_points,risk_pct=risk_pct,
                           min_gap_atr=.15,max_spread_atr=.08,max_setup_bars=48,daily_loss_pct=2.,max_daily_entries=3)
        if not (0 < risk_pct <= 1 and math.isfinite(rr) and rr >= 1):
            raise ValueError("SMC quality: riesgo máximo 1%, R:R >= 1")
        self.used, self.rejections = set(), Counter()
        self.day, self.day_start, self.entries = None, None, 0

    def reject(self, why):
        self.rejections[why] += 1

    def on_bar(self, ctx):
        if ctx.open_trades or ctx.pending_orders: return
        if ctx.time.date() != self.day:
            self.day,self.day_start,self.entries=ctx.time.date(),ctx.balance,0
        if ctx.balance <= 0 or ctx.balance < self.day_start*.98 or self.entries >= 3:
            return self.reject("daily_risk_limit")
        hist=ctx.history[-51:]
        if len(hist)<51: return self.reject("warmup")
        ranges=[max(b.high,p.close)-min(b.low,p.close) for p,b in zip(hist[:-1],hist[1:])]
        atr=sum(ranges[-14:])/14
        if not math.isfinite(atr) or atr<=0: return self.reject("invalid_atr")
        spread=ctx.bar.spread*ctx.spec.point
        if spread/atr>self.params["max_spread_atr"]: return self.reject("spread_vs_atr")
        trend=ctx.topdown.engines.get(self.params["bias_tf"])
        bias=trend.state_at(ctx.time) if trend else "UNKNOWN"
        direction="bullish" if bias=="BULLISH" else "bearish" if bias=="BEARISH" else None
        if direction is None: return self.reject("htf_unconfirmed")
        events=ctx.smc.structure.events
        if not events or events[-1].direction!=direction: return self.reject("structure_disagrees")
        for gap in reversed(ctx.smc.fvg.fvgs):
            if gap.detected_at<=events[-1].timestamp: break
            key=(gap.detected_at,gap.direction,gap.bottom,gap.top)
            if key in self.used or gap.direction!=direction or gap.detected_at>=ctx.time: continue
            if gap.status.current not in ("OPEN","PARTIALLY_FILLED"): continue
            if ctx.index-gap.index>self.params["max_setup_bars"]: continue
            if gap.top-gap.bottom<self.params["min_gap_atr"]*atr: continue
            buy=direction=="bullish"
            trigger=(ctx.bar.low<=gap.top and ctx.bar.close>gap.top) if buy else (ctx.bar.high>=gap.bottom and ctx.bar.close<gap.bottom)
            if not trigger: continue
            pad=max(self.params["sl_buffer_points"]*ctx.spec.point,.1*atr)
            stop=gap.bottom-pad if buy else gap.top+pad
            risk=(ctx.bar.close-stop) if buy else (stop-ctx.bar.close)
            if not .75*atr<=risk<=3*atr or spread/risk>.1:
                return self.reject("stop_cost_quality")
            self.used.add(key);self.entries+=1
            order=ctx.buy if buy else ctx.sell
            order(stop_loss=stop,rr=self.params["rr"],risk_pct=self.params["risk_pct"],comment="SMC_QUALITY experimental")
            return
