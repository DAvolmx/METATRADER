"""Research implementation of H3 sweep -> H1 break -> M15 trigger; no live orders."""
from collections import Counter
import numpy as np
import pandas as pd

class MacroLiquidityStrategy:
    name,version="GM_MACRO_LIQUIDITY_CANDIDATE","1.0"
    def __init__(self,bias_tf="H1",rr=2,sl_buffer_points=20,risk_pct=.5,dxy=None):
        if not 0<risk_pct<=1 or rr<1: raise ValueError("Macro: riesgo <=1%, RR >=1")
        self.params=dict(rr=rr,risk_pct=risk_pct,channel_days=7,dxy_required=True)
        self.dxy=dxy.sort_values("time") if dxy is not None else None
        if self.dxy is not None:
            self.dxy_times=pd.to_datetime(self.dxy.time,utc=True).astype("int64").to_numpy()/1e9+3600
            self.dxy_closes=self.dxy.close.to_numpy(float)
        self.groups={3600:None,10800:None};self.closed={3600:[],10800:[]}
        self.sweep=None;self.macro=None;self.day=None;self.start_balance=0;self.rejections=Counter()
        self.last_hi=None;self.last_lo=None;self.broken_hi=False;self.broken_lo=False;self.h1_event=None
    def reject(self,why):self.rejections[why]+=1
    def aggregate(self,b,seconds):
        bucket=int(b.time.timestamp())//seconds*seconds;g=self.groups[seconds]
        if g is not None and g[0]!=bucket:
            self.groups[seconds]=None
            self.reject("gap_in_bucket")
        g=self.groups[seconds]
        if g is None:g=[bucket,b.open,b.high,b.low,b.close,0]
        g[2]=max(g[2],b.high);g[3]=min(g[3],b.low);g[4]=b.close;g[5]+=1;self.groups[seconds]=g
        if int(b.time.timestamp())+900==bucket+seconds:
            self.groups[seconds]=None
            if g[5]!=seconds//900:return False
            self.closed[seconds].append(g);self.closed[seconds]=self.closed[seconds][-400:];return True
        return False
    def on_bar(self,ctx):
        if ctx.time.date()!=self.day:self.day=ctx.time.date();self.start_balance=ctx.balance
        new_h1=self.aggregate(ctx.bar,3600);self.aggregate(ctx.bar,10800)
        h1=self.closed[3600];h3=self.closed[10800]
        if new_h1 and len(h1)>=5:
            idx=len(h1)-3;p=h1[idx];neighbors=h1[idx-2:idx]+h1[idx+1:idx+3]
            if all(p[2]>b[2] for b in neighbors):self.last_hi=p[2];self.broken_hi=False
            if all(p[3]<b[3] for b in neighbors):self.last_lo=p[3];self.broken_lo=False
            if self.last_hi is not None and not self.broken_hi and h1[-1][4]>self.last_hi:
                self.h1_event=(1,h1[-1][0]+3600);self.broken_hi=True
            if self.last_lo is not None and not self.broken_lo and h1[-1][4]<self.last_lo:
                self.h1_event=(-1,h1[-1][0]+3600);self.broken_lo=True
        if len(h1)<200 or len(h3)<30:return self.reject("warmup")
        macro=h3[-1];end=macro[0]+10800;start=end-7*86400;history=[b for b in h3 if b[0]>=start]
        if len(history)<30 or history[0][0]>start+86400:return self.reject("weekly_coverage")
        if self.macro!=macro[0]:self.macro=macro[0];self.sweep=None
        if ctx.bar.time.timestamp()<end:return
        hist=ctx.history[-15:]
        if len(hist)<15:return
        atr=sum(max(b.high,a.close)-min(b.low,a.close) for a,b in zip(hist[:-1],hist[1:]))/14
        if atr<=0:return
        x=np.array([(b[0]-start)/10800 for b in history]);y=np.array([b[4] for b in history]);slope=np.polyfit(x,y,1)[0]
        if abs(slope)<.02*atr:return self.reject("flat_channel")
        direction=1 if slope>0 else -1
        def ema(period):
            value=h1[0][4]
            for b in h1[1:]:value+=2/(period+1)*(b[4]-value)
            return value
        if direction*(ema(50)-ema(200))<=0:return self.reject("ema_disagrees")
        if self.dxy is None:return self.reject("dxy_absent")
        clock=ctx.time.timestamp();j=int(np.searchsorted(self.dxy_times,clock,side="right"))-1
        if j<4 or clock-self.dxy_times[j]>7200:return self.reject("dxy_stale")
        move=self.dxy_closes[j]/self.dxy_closes[j-4]-1
        if direction*move>.0001:return self.reject("dxy_veto")
        if self.sweep and ctx.bar.time.timestamp()-self.sweep[1]>8*900:self.sweep=None
        b=ctx.bar
        if self.sweep is None:
            if direction==1 and b.low<macro[3]<b.close:self.sweep=(1,clock,b.low)
            elif direction==-1 and b.high>macro[2]>b.close:self.sweep=(-1,clock,b.high)
        if not self.sweep or not self.h1_event:return
        d,t,extreme=self.sweep
        if self.h1_event[0]!=d or self.h1_event[1]<t:return
        if ctx.open_trades or ctx.pending_orders or ctx.balance<=self.start_balance*.98:return
        previous=hist[-2]
        if d==1 and b.close<=previous.high or d==-1 and b.close>=previous.low:return
        if b.spread>50:return self.reject("spread")
        entry=b.close+(b.spread*ctx.spec.point if d==1 else 0);stop=extreme-d*.2*atr
        risk=d*(entry-stop);room=macro[2]-entry if d==1 else entry-macro[3]
        if risk<=0 or room<risk*self.params["rr"]:return self.reject("target_room")
        order=ctx.buy if d==1 else ctx.sell
        order(stop_loss=stop,rr=self.params["rr"],risk_pct=self.params["risk_pct"],comment="GM_MACRO experimental")
        self.sweep=None
