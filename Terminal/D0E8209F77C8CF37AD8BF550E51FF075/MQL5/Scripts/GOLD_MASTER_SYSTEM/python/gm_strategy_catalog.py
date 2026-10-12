"""Ten frozen H1 research strategies. Closed bars only; no orders or optimization."""
import numpy as np
import pandas as pd

CATALOG={
 'ema_trend':('Cruce EMA20/50 con EMA200',2),
 'rsi_pullback':('Retroceso RSI30/70 en tendencia EMA50/200',2),
 'donchian':('Ruptura del canal previo de 20 barras',3),
 'compression':('Ruptura tras compresión de volatilidad',3),
 'bollinger_range':('Reversión Bollinger en régimen lateral',2),
 'liquidity_sweep':('Barrido y recuperación del rango previo',2),
 'momentum':('Cambio de signo de momentum de 12 barras',2),
 'london_orb':('Ruptura del rango asiático en Londres',2),
 'previous_day':('Ruptura del máximo/mínimo del día anterior',3),
 'fvg_retest':('Retesteo de FVG de tres velas con EMA200',2)}

def features(df):
    c=df.close;h=df.high;l=df.low;o=df.open
    prev=c.shift(1)
    atr=pd.concat([h-l,(h-prev).abs(),(l-prev).abs()],axis=1).max(axis=1).ewm(alpha=1/14,adjust=False).mean()
    delta=c.diff().fillna(0);up=delta.clip(lower=0).ewm(alpha=1/14,adjust=False).mean()
    dn=(-delta.clip(upper=0)).ewm(alpha=1/14,adjust=False).mean()
    time=pd.to_datetime(df.time,utc=True)
    f={k:df[k].to_numpy(float) for k in ('open','high','low','close','spread')}
    f.update(atr=atr.to_numpy(),rsi=(100-100/(1+up/(dn+1e-12))).to_numpy(),
        e20=c.ewm(span=20,adjust=False).mean().to_numpy(),
        e50=c.ewm(span=50,adjust=False).mean().to_numpy(),
        e200=c.ewm(span=200,adjust=False).mean().to_numpy(),
        hi20=h.rolling(20).max().shift(1).to_numpy(),
        lo20=l.rolling(20).min().shift(1).to_numpy(),
        mean=c.rolling(20).mean().to_numpy(),std=c.rolling(20).std(ddof=0).to_numpy(),
        momentum=c.diff(12).to_numpy(),time=time,
        london=time.dt.tz_convert('Europe/London'))
    daily=df.assign(day=time.dt.floor('D')).groupby('day').agg(high=('high','max'),low=('low','min')).shift(1)
    f['prevhi']=time.dt.floor('D').map(daily.high).to_numpy()
    f['prevlo']=time.dt.floor('D').map(daily.low).to_numpy()
    return f

def signals(df):
    f=features(df);c=f['close'];o=f['open'];h=f['high'];l=f['low'];a=f['atr']
    result={k:[] for k in CATALOG}
    asian={};fvg_up=None;fvg_down=None
    def add(name,b,d,stop=None):
        risk=1.5*a[b] if stop is None else (c[b]-stop)*d
        if not np.isfinite(risk) or risk<=0 or risk>4*a[b]: return
        risk=max(risk,a[b]);rr=CATALOG[name][1]
        result[name].append((b,d,c[b],c[b]-d*risk,c[b]+d*risk*rr,risk))
    for b in range(len(c)):
        stamp=f['london'].iloc[b];day=stamp.date()
        if stamp.hour<7:
            hi,lo=asian.get(day,(-np.inf,np.inf));asian[day]=(max(hi,h[b]),min(lo,l[b]))
        if b<300: continue
        trend=1 if c[b]>f['e200'][b] else -1
        fast=f['e20'];slow=f['e50'];r=f['rsi']
        cross=1 if fast[b]>slow[b] and fast[b-1]<=slow[b-1] else -1 if fast[b]<slow[b] and fast[b-1]>=slow[b-1] else 0
        if cross==trend: add('ema_trend',b,cross)
        if trend==1 and slow[b]>f['e200'][b] and r[b-1]<30<=r[b]: add('rsi_pullback',b,1)
        if trend==-1 and slow[b]<f['e200'][b] and r[b-1]>70>=r[b]: add('rsi_pullback',b,-1)
        breakout=1 if c[b]>f['hi20'][b] and c[b-1]<=f['hi20'][b-1] else -1 if c[b]<f['lo20'][b] and c[b-1]>=f['lo20'][b-1] else 0
        if breakout==trend:
            add('donchian',b,breakout)
            if 4*f['std'][b-1]<2*a[b-1]: add('compression',b,breakout)
        if abs(slow[b]-slow[b-10])<.5*a[b]:
            if c[b-1]<f['mean'][b-1]-2*f['std'][b-1] and c[b]>f['mean'][b]-2*f['std'][b]: add('bollinger_range',b,1)
            if c[b-1]>f['mean'][b-1]+2*f['std'][b-1] and c[b]<f['mean'][b]+2*f['std'][b]: add('bollinger_range',b,-1)
        if l[b]<f['lo20'][b] and c[b]>f['lo20'][b] and trend==1: add('liquidity_sweep',b,1,l[b]-.1*a[b])
        if h[b]>f['hi20'][b] and c[b]<f['hi20'][b] and trend==-1: add('liquidity_sweep',b,-1,h[b]+.1*a[b])
        m=f['momentum']
        if m[b]>0>=m[b-1] and trend==1: add('momentum',b,1)
        if m[b]<0<=m[b-1] and trend==-1: add('momentum',b,-1)
        if day in asian and 7<=stamp.hour<11:
            hi,lo=asian[day]
            if c[b]>hi and c[b-1]<=hi and trend==1: add('london_orb',b,1,lo)
            if c[b]<lo and c[b-1]>=lo and trend==-1: add('london_orb',b,-1,hi)
        if c[b]>f['prevhi'][b] and c[b-1]<=f['prevhi'][b] and trend==1: add('previous_day',b,1)
        if c[b]<f['prevlo'][b] and c[b-1]>=f['prevlo'][b] and trend==-1: add('previous_day',b,-1)
        # Only gaps known before this bar may trigger; consume a gap once.
        if fvg_up and b-fvg_up[2]<=12 and l[b]<=fvg_up[1] and c[b]>fvg_up[1] and trend==1:
            add('fvg_retest',b,1,fvg_up[0]-.1*a[b]);fvg_up=None
        if fvg_down and b-fvg_down[2]<=12 and h[b]>=fvg_down[0] and c[b]<fvg_down[0] and trend==-1:
            add('fvg_retest',b,-1,fvg_down[1]+.1*a[b]);fvg_down=None
        if l[b]>h[b-2] and c[b-1]>o[b-1]: fvg_up=(h[b-2],l[b],b)
        if h[b]<l[b-2] and c[b-1]<o[b-1]: fvg_down=(h[b],l[b-2],b)
    return f,result
