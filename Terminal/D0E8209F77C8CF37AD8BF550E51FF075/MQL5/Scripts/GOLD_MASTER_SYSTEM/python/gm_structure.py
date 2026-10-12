# -*- coding: utf-8 -*-
"""
Estructura de mercado SIN repintado (misma lógica que GoldMaster_Structure.mqh):
swings HH/HL/LH/LL, BOS, CHoCH, niveles multi-toque, canal de regresión y Fibonacci.
Además genera la "lectura del mercado" en texto (idea tomada del Gold Assistant:
cada señal viene con su RAZÓN).
"""
import numpy as np
import pandas as pd


def swings(df, strength=3):
    H, L = df.high.values, df.low.values
    out, lastH, lastL = [], None, None
    for i in range(strength, len(df) - strength - 1):
        win_h = H[i - strength:i + strength + 1]; win_l = L[i - strength:i + strength + 1]
        if (H[i] > H[max(0,i-strength):i]).all() and (H[i] > H[i+1:min(len(H),i+strength+1)]).all():
            lab = "" if lastH is None else ("HH" if H[i] > lastH else "LH")
            out.append(dict(i=i, t=df.index[i], p=float(H[i]), high=True, label=lab)); lastH = H[i]
        if L[i] == win_l.min() and (L[i] < L[i - strength:i]).all():
            lab = "" if lastL is None else ("HL" if L[i] > lastL else "LL")
            out.append(dict(i=i, t=df.index[i], p=float(L[i]), high=False, label=lab)); lastL = L[i]
    return out


def events(df, sw, strength=3):
    C = df.close.values
    ev, trend, k = [], 0, 0
    aH = aL = None; bH = bL = True
    sw = sorted(sw, key=lambda s: s["i"])
    for i in range(len(df) - 1):
        while k < len(sw) and sw[k]["i"] + strength <= i:
            if sw[k]["high"]: aH, bH = sw[k], False
            else: aL, bL = sw[k], False
            k += 1
        if aH and not bH and C[i] > aH["p"]:
            ev.append(dict(t0=aH["t"], t1=df.index[i], p=aH["p"], dir=1, choch=trend == -1)); trend, bH = 1, True
        if aL and not bL and C[i] < aL["p"]:
            ev.append(dict(t0=aL["t"], t1=df.index[i], p=aL["p"], dir=-1, choch=trend == 1)); trend, bL = -1, True
    return ev, trend


def levels(df, strength=2, tol_atr=0.3, min_touches=3):
    sw = swings(df, strength)
    atr = (df.high - df.low).rolling(14).mean().iloc[-1]
    tol = atr * tol_atr
    lv = []
    for s in sw:
        for l in lv:
            if abs(l["p"] - s["p"]) <= tol:
                l["p"] = (l["p"] * l["n"] + s["p"]) / (l["n"] + 1); l["n"] += 1; break
        else:
            lv.append(dict(p=s["p"], n=1))
    return [l for l in lv if l["n"] >= min_touches]


def regression_channel(df, n=120, k=2.0):
    sub = df.tail(n)
    x = np.arange(len(sub)); y = sub.close.values
    a, b = np.polyfit(x, y, 1)
    mid = a * x + b
    sd = np.std(y - mid)
    slope_pct = a * len(sub) / y.mean() * 100
    return dict(t=sub.index, mid=mid, up=mid + k * sd, lo=mid - k * sd, slope_pct=slope_pct,
                dir=1 if slope_pct > 0.3 else (-1 if slope_pct < -0.3 else 0))


FIBS = [0.0, 0.236, 0.382, 0.5, 0.618, 0.705, 0.786, 1.0]


def fibonacci(sw, trend):
    hs = [s for s in sw if s["high"]]; ls = [s for s in sw if not s["high"]]
    if not hs or not ls:
        return None
    h, l = hs[-1], ls[-1]
    rng = h["p"] - l["p"]
    if rng <= 0:
        return None
    up = trend >= 0          # tendencia alcista: retroceso desde el máximo hacia abajo
    lv = {f: (h["p"] - rng * f) if up else (l["p"] + rng * f) for f in FIBS}
    return dict(levels=lv, t0=min(h["t"], l["t"]), up=up)


def read_market(htf_df, ltf_df, dxy=None, strength_htf=3, strength_ltf=3):
    """Lectura en texto: tendencia mayor, micro, último evento, zona, DXY y conclusión."""
    out = {}
    swH = swings(htf_df, strength_htf); evH, tH = events(htf_df, swH, strength_htf)
    swL = swings(ltf_df, strength_ltf); evL, tL = events(ltf_df, swL, strength_ltf)
    name = {1: "ALCISTA", -1: "BAJISTA", 0: "RANGO"}
    out["htf"], out["ltf"] = tH, tL
    lastL = evL[-1] if evL else None
    out["last"] = (("CHoCH" if lastL["choch"] else "BOS") + (" ↑" if lastL["dir"] > 0 else " ↓")) if lastL else "—"
    hs = [s for s in swL if s["high"]]; ls = [s for s in swL if not s["high"]]
    px = float(ltf_df.close.iloc[-1])
    zona = "—"
    if hs and ls:
        eq = (hs[-1]["p"] + ls[-1]["p"]) / 2
        zona = "PREMIUM (caro)" if px > eq else "DISCOUNT (barato)"
    out["zona"] = zona
    reasons, score = [], 0
    reasons.append(f"Tendencia mayor {name[tH]}"); score += tH * 2
    reasons.append(f"Micro tendencia {name[tL]} · último {out['last']}"); score += tL
    if dxy and dxy.get("dxy"):
        b = dxy.get("dxy_bias", 0)
        reasons.append(f"DXY {dxy['dxy']} ({dxy['dxy_chg24']:+.2f}% 24h, corr {dxy['dxy_corr']:+.2f}) → "
                       + ("favorece compras de oro" if b > 0 else "favorece ventas de oro" if b < 0 else "sin efecto claro"))
        score += b
    if zona.startswith("DISCOUNT") and tH > 0: reasons.append("Precio en descuento dentro de tendencia alcista ✔"); score += 1
    if zona.startswith("PREMIUM") and tH < 0: reasons.append("Precio en premium dentro de tendencia bajista ✔"); score -= 1
    out["score"] = score
    out["accion"] = "BUSCAR COMPRAS (buy stop sobre último máximo micro)" if score >= 3 else \
        "BUSCAR VENTAS (sell stop bajo último mínimo micro)" if score <= -3 else "ESPERAR: estructura no alineada"
    out["razones"] = reasons
    return out
