"""
gm_pro_chart.py — Terminal PRO con TradingView Lightweight Charts (motor gráfico nativo de TradingView):
zoom con rueda/pinza, arrastre, escala de precios arrastrable, sin reinicios al actualizar (cada vela se
actualiza con series.update, el zoom del usuario nunca se pierde). Se sirve dentro del mismo dashboard:
   http://127.0.0.1:8050/pro
APIs JSON:  /api/candles?tf=M5&n=1500   /api/live?tf=M5   /api/intel
"""
import os, sys, json, time
import numpy as np, pandas as pd
from flask import jsonify, request, Response
import MetaTrader5 as mt5

TF = {"M1": mt5.TIMEFRAME_M1, "M5": mt5.TIMEFRAME_M5, "M15": mt5.TIMEFRAME_M15, "M30": mt5.TIMEFRAME_M30,
      "H1": mt5.TIMEFRAME_H1, "H4": mt5.TIMEFRAME_H4, "D1": mt5.TIMEFRAME_D1}

def _ema(x, n): return pd.Series(x).ewm(span=n, adjust=False).mean().values

def register_pro(app, symbol_getter, gm_dir):
    srv = app.server
    import threading; LK = threading.Lock()          # la API de MetaTrader5 no es segura entre hilos

    def _reconnect(sym):
        try: mt5.shutdown()
        except Exception: pass
        ok = mt5.initialize()
        if ok: mt5.symbol_select(sym, True)
        print(f"[PRO] reconexión MT5: {ok} {mt5.last_error()}", flush=True)

    def rates(tf, n):
        sym = symbol_getter(); n = int(n)
        with LK:
            r = None
            for attempt in range(2):
                for k in (n, min(n, 1000), 300):           # el terminal puede limitar 'Max bars'
                    r = mt5.copy_rates_from_pos(sym, TF.get(tf, mt5.TIMEFRAME_M5), 0, k)
                    if r is not None and len(r): break
                if r is not None and len(r): break
                print(f"[PRO] copy_rates vacío {sym} {tf}: {mt5.last_error()}", flush=True)
                _reconnect(sym)                             # conexión perdida (terminal reiniciado) → reconectar
        return pd.DataFrame(r) if r is not None and len(r) else pd.DataFrame()

    def pack(df):
        t = df.time.astype(int).tolist(); c = df.close.values
        e50, e200 = _ema(c, 50), _ema(c, 200)
        day = pd.to_datetime(df.time, unit="s").dt.date.values; tp = (df.high+df.low+df.close).values/3; v = np.maximum(df.tick_volume.values, 1)
        vw = pd.Series(tp*v).groupby(day).cumsum().values/pd.Series(v).groupby(day).cumsum().values
        return {"candles": [{"time": a, "open": o, "high": h, "low": l, "close": cc} for a, o, h, l, cc in zip(t, df.open, df.high, df.low, df.close)],
                "volume": [{"time": a, "value": float(vv), "color": "rgba(38,166,91,.35)" if cc >= o else "rgba(214,48,64,.35)"} for a, vv, o, cc in zip(t, df.tick_volume, df.open, df.close)],
                "ema50": [{"time": a, "value": float(x)} for a, x in zip(t, e50)], "ema200": [{"time": a, "value": float(x)} for a, x in zip(t, e200)],
                "vwap": [{"time": a, "value": float(x)} for a, x in zip(t, vw)]}

    @srv.route("/api/candles")
    def _candles():
        df = rates(request.args.get("tf", "M5"), request.args.get("n", 1500))
        return jsonify(pack(df) if not df.empty else {})

    @srv.route("/api/live")
    def _live():
        df = rates(request.args.get("tf", "M5"), 260)
        if df.empty: return jsonify({})
        p = pack(df); out = {k: v[-2:] for k, v in p.items()}
        pos = []
        with LK: plist = mt5.positions_get(symbol=symbol_getter()) or []; acc = mt5.account_info(); tk = mt5.symbol_info_tick(symbol_getter())
        for x in plist:
            pos.append({"type": "BUY" if x.type == 0 else "SELL", "vol": x.volume, "open": x.price_open, "sl": x.sl, "tp": x.tp, "pnl": x.profit})
        out["positions"] = pos
        out["account"] = {"balance": acc.balance, "equity": acc.equity, "margin_level": acc.margin_level} if acc else {}
        out["bid"], out["ask"] = (tk.bid, tk.ask) if tk else (0, 0)
        return jsonify(out)

    @srv.route("/api/intel")
    def _intel():
        out = {}
        for name in ("intel.json", "micro.json"):
            try: out.update(json.load(open(os.path.join(gm_dir, name))))
            except Exception: pass
        try:
            lines = open(os.path.join(gm_dir, "alerts.csv"), encoding="utf-8", errors="ignore").read().strip().splitlines()[-8:]
            out["alerts"] = [l.split(",", 2) for l in reversed(lines)]
        except Exception: out["alerts"] = []
        return jsonify(out)


    # ───────────── APIs adicionales: overlays, noticias, estado, acciones, investigación ─────────────
    import gm_structure as gs
    HERE = os.path.dirname(os.path.abspath(__file__))

    def _params():
        P = dict(fast=21, slow=89, minscore=3, tp=2.0, slatr=1.2, be=1.5, lock=0.3, chdev=2.0, session=False, maxbars=240)
        try:
            for ln in open(os.path.join(gm_dir, "signal_params.txt")):
                k, _, v = ln.strip().partition("=")
                if k in ("fast", "slow", "minscore"): P[k] = int(v)
                elif k in ("tp", "slatr"): P[k] = float(v)
        except Exception: pass
        return P

    @srv.route("/api/overlays")
    def _overlays():
        tf = request.args.get("tf", "M5"); out = {"zones": [], "markers": [], "levels": {}, "trade": None}
        try:
            h1 = rates("H1", 700)
            if not h1.empty:
                d = h1.rename(columns={"tick_volume": "volume"}).copy(); d.index = pd.to_datetime(d.time, unit="s")
                px = float(h1.close.iloc[-1])
                lv = gs.levels(d, strength=3, tol_atr=0.3, min_touches=2)
                lv = sorted(lv, key=lambda z: abs(z["p"] - px))[:8]
                out["zones"] = [{"price": float(z["p"]), "touches": int(z["n"]), "side": "supply" if z["p"] > px else "demand"} for z in lv]
            with LK:
                d1 = mt5.copy_rates_from_pos(symbol_getter(), mt5.TIMEFRAME_D1, 1, 1); w1 = mt5.copy_rates_from_pos(symbol_getter(), mt5.TIMEFRAME_W1, 0, 1)
            if d1 is not None and len(d1): out["levels"].update(PDH=float(d1["high"][0]), PDL=float(d1["low"][0]), PDC=float(d1["close"][0]))
            if w1 is not None and len(w1): out["levels"]["WO"] = float(w1["open"][0])
        except Exception as ex: out["zones_error"] = str(ex)
        try:   # señales del modo en vivo (mismas reglas que el indicador PRO Signals, parámetros re-entrenados)
            sys.path.insert(0, os.path.join(HERE, "optimizer")); import gm_optimizer as go
            df = rates(tf, 1500); m15 = rates("M15", 1200)
            if not df.empty and not m15.empty:
                for x in (df, m15): x["time"] = pd.to_datetime(x["time"], unit="s")
                F = go.features(df, m15); P = _params(); sig = go.signals(F, P)
                t = ((df.time - pd.Timestamp(0)).dt.total_seconds()).astype("int64")   # segundos epoch (independiente de la unidad datetime64[s]/[ns])
                for b, dd, sc in sig[-40:]:
                    out["markers"].append({"time": int(t.iloc[b]), "position": "belowBar" if dd > 0 else "aboveBar",
                                           "color": "#06b6d4" if dd > 0 else "#ec4899", "shape": "arrowUp" if dd > 0 else "arrowDown",
                                           "text": ("Buy" if dd > 0 else "Sell") + ("+" if sc >= 4 else "")})
                if sig:
                    b, dd, sc = sig[-1]; e = float(F["c"][b]); a = float(F["atr"][b])
                    sw = F["swL"][b] if dd > 0 else F["swH"][b]
                    risk = max(P["slatr"]*a, (e - (sw - dd*0.25*a))*dd if sw == sw else P["slatr"]*a)
                    out["trade"] = {"dir": int(dd), "entry": e, "sl": e - dd*risk, "tp1": e + dd*risk*P["tp"]/2,
                                    "tp2": e + dd*risk*P["tp"], "tp3": e + dd*risk*P["tp"]*1.5, "score": int(sc), "time": int(t.iloc[b])}
                out["params"] = P
        except Exception as ex: out["signals_error"] = str(ex)
        return jsonify(out)

    @srv.route("/api/news")
    def _news():
        evs = []
        try:
            now = time.time()
            for ln in open(os.path.join(gm_dir, "news_calendar.csv"), encoding="ascii", errors="ignore"):
                p = ln.strip().split(",")
                if len(p) < 5: continue
                ts = pd.Timestamp(p[0].replace(".", "-") + " " + p[1], tz="UTC").timestamp()
                if ts > now - 1800: evs.append({"ts": int(ts), "title": p[2], "cur": p[3], "impact": int(p[4]) if p[4].isdigit() else p[4]})
        except Exception: pass
        return jsonify(sorted(evs, key=lambda e: e["ts"])[:10])

    @srv.route("/api/state")
    def _state():
        from gm_intel import override_on
        try:
            from gm_control import auto_on; auto = auto_on()
        except Exception: auto = None
        st = {}
        try:
            for ln in open(os.path.join(gm_dir, "ea_state.txt"), encoding="ascii", errors="ignore"):
                k, _, v = ln.strip().partition("="); st[k] = v
        except Exception: pass
        hb = {}
        try: hb = json.load(open(os.path.join(gm_dir, "service_heartbeat.txt")))
        except Exception: pass
        with LK: ti = mt5.terminal_info()
        return jsonify({"auto": auto, "override": override_on(), "algo": bool(ti.trade_allowed) if ti else False,
                        "service_age": int(time.time() - hb.get("ts", 0)) if hb else -1, "ea": st})

    @srv.route("/api/action", methods=["POST"])
    def _action():
        j = request.get_json(force=True) or {}; act = j.get("act", "")
        try:
            import gm_control as gc
            from gm_intel import set_override, override_on
            with LK:
                if act in ("BUY", "SELL"): msg = gc.market_order(symbol_getter(), act, float(j.get("lot", 0.1)), float(j.get("rr", 2.0)))
                elif act == "CLOSE_ALL": msg = gc.close_all("XAU")
                elif act == "AUTO": gc.set_auto(not gc.auto_on()); msg = "Modo autónomo " + ("ON" if gc.auto_on() else "OFF")
                elif act == "OVERRIDE": set_override(not override_on()); msg = "Filtros " + ("OFF (sin filtros)" if override_on() else "ON")
                else: msg = "acción desconocida"
        except Exception as ex: msg = f"Error: {ex}"
        return jsonify({"msg": msg})

    @srv.route("/api/research")
    def _research():
        out = {}
        for k, p in (("mc", "optimizer/out/mc_report.json"), ("lab", "optimizer/out/lab_report.json")):
            try: out[k] = json.load(open(os.path.join(HERE, p)))
            except Exception: pass
        try: out["params"] = dict(l.strip().split("=", 1) for l in open(os.path.join(gm_dir, "signal_params.txt")) if "=" in l)
        except Exception: pass
        return jsonify(out)

    @srv.route("/pro")
    def _pro():
        return Response(PAGE.replace("__SYM__", symbol_getter()), mimetype="text/html")

PAGE = r"""<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>GOLD MASTER · Terminal PRO</title>
<script src="https://unpkg.com/lightweight-charts@4.2.0/dist/lightweight-charts.standalone.production.js"></script>
<style>
:root{--bg:#0b0e14;--panel:#121722;--line:#1f2937;--txt:#d1d5db;--mut:#7c8597;--up:#26a65b;--dn:#d63040;--gold:#f5c542;--cy:#06b6d4;--pk:#ec4899}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--txt);font:13px/1.4 Inter,Segoe UI,Arial;overflow:hidden}
header{display:flex;align-items:center;gap:12px;padding:6px 12px;border-bottom:1px solid var(--line);background:var(--panel);flex-wrap:wrap}
.logo{font-weight:800;color:var(--gold);letter-spacing:.5px}.px{font-size:20px;font-weight:700;font-variant-numeric:tabular-nums}.mut{color:var(--mut)}
button{font:inherit;cursor:pointer}.tf button,.tog button{background:transparent;border:1px solid var(--line);color:var(--txt);padding:3px 9px;border-radius:6px;margin-right:3px}
.tf button.on,.tog button.on{background:var(--gold);color:#111;border-color:var(--gold);font-weight:700}
.dot{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:4px}
main{display:grid;grid-template-columns:1fr 340px;height:calc(100vh - 46px)}#chart{position:relative}
aside{border-left:1px solid var(--line);background:var(--panel);overflow:auto;padding:8px}
.card{border:1px solid var(--line);border-radius:10px;padding:9px;margin-bottom:8px}.card h4{margin:0 0 6px;font-size:11px;color:var(--mut);text-transform:uppercase;letter-spacing:.6px;display:flex;justify-content:space-between}
.kv{display:flex;justify-content:space-between;padding:1px 0;font-variant-numeric:tabular-nums}.up{color:var(--up)}.dn{color:var(--dn)}
.pill{padding:1px 8px;border-radius:10px;font-weight:700;font-size:11px}.pill.up{background:rgba(38,166,91,.15)}.pill.dn{background:rgba(214,48,64,.15)}
.alert{border-left:3px solid var(--gold);padding:3px 8px;margin:3px 0;background:#0e131c;font-size:12px}
.row{display:flex;gap:6px;align-items:center;margin:4px 0}.btn{flex:1;border:0;border-radius:7px;padding:8px;font-weight:800;color:#fff}
.buy{background:var(--up)}.sell{background:var(--dn)}.gray{background:#2b3445}.warn{background:#9a3412}
input[type=number]{width:70px;background:#0b0e14;border:1px solid var(--line);color:var(--txt);border-radius:6px;padding:5px}
#toast{position:fixed;right:16px;bottom:16px;background:#1f2937;border:1px solid var(--gold);padding:10px 14px;border-radius:8px;display:none;z-index:9;max-width:360px}
#ticket{position:absolute;left:10px;top:10px;z-index:3;background:rgba(18,23,34,.92);border:1px solid var(--line);border-radius:10px;padding:8px 10px;min-width:210px}
.tabs{display:flex;gap:4px;margin-bottom:6px}.tabs button{flex:1;background:#0b0e14;border:1px solid var(--line);color:var(--mut);border-radius:6px;padding:4px}.tabs button.on{color:#111;background:var(--gold)}
@media(max-width:1000px){body{overflow:auto}main{grid-template-columns:1fr;grid-template-rows:65vh auto;height:auto}}
</style></head><body>
<header><span class="logo">GOLD MASTER</span><span class="mut">__SYM__</span><span id="px" class="px">—</span><span id="spr" class="mut"></span>
<div class="tf" id="tf"></div>
<div class="tog" id="tog"></div>
<span id="sys" class="mut" style="margin-left:auto"></span></header>
<main><div id="chart"><div id="ticket"></div></div><aside>
<div class="tabs"><button data-t="trade" class="on">Operar</button><button data-t="mkt">Mercado</button><button data-t="res">Investigación</button></div>
<section data-p="trade">
 <div class="card"><h4>Cuenta</h4><div id="acc"></div></div>
 <div class="card"><h4>Orden manual <span class="mut">SL estructural · TP 2R</span></h4>
  <div class="row"><span class="mut">Lote</span><input id="lot" type="number" step="0.1" min="0.1" value="0.1"><span class="mut">RR</span><input id="rr" type="number" step="0.5" min="1" value="2"></div>
  <div class="row"><button class="btn buy" onclick="act('BUY')">COMPRAR</button><button class="btn sell" onclick="act('SELL')">VENDER</button></div>
  <div class="row"><button class="btn gray" onclick="if(confirm('¿Cerrar TODAS las posiciones del oro?'))act('CLOSE_ALL')">Cerrar todo</button></div></div>
 <div class="card"><h4>Sistema</h4>
  <div class="row"><button id="bAuto" class="btn gray" onclick="act('AUTO')">Autónomo</button><button id="bOv" class="btn gray" onclick="if(confirm('Cambiar filtros de riesgo. Sin filtros los EAs operan aunque haya noticias, shock del DXY o riesgo de cartera alto. ¿Continuar?'))act('OVERRIDE')">Filtros</button></div>
  <div id="sysd"></div></div>
 <div class="card"><h4>Posiciones</h4><div id="pos" class="mut">—</div></div>
 <div class="card"><h4>Alertas <span class="mut">Shift+clic = alerta de precio</span></h4><div id="alr"></div></div>
</section>
<section data-p="mkt" style="display:none">
 <div class="card"><h4>Dólar (DXY) en vivo</h4><div id="dxy"></div></div>
 <div class="card"><h4>Micro-estructura</h4><div id="mic"></div></div>
 <div class="card"><h4>Régimen y riesgo</h4><div id="reg"></div></div>
 <div class="card"><h4>Sentimiento · COT · Macro</h4><div id="sen"></div></div>
 <div class="card"><h4>Noticias</h4><div id="news"></div></div>
</section>
<section data-p="res" style="display:none">
 <div class="card"><h4>Parámetros vivos (re-entrenados)</h4><div id="prm"></div></div>
 <div class="card"><h4>Monte Carlo (50 USD)</h4><div id="mc"></div></div>
 <div class="card"><h4>Laboratorio de estrategias</h4><div id="lab"></div></div>
</section></aside></main><div id="toast"></div>
<script>
const $=id=>document.getElementById(id);const LS={g:(k,d)=>{try{return JSON.parse(localStorage.getItem(k))??d}catch(e){return d}},s:(k,v)=>{try{localStorage.setItem(k,JSON.stringify(v))}catch(e){}}};
const TFS=["M1","M5","M15","M30","H1","H4","D1"];let tf=LS.g("gm_tf","M5");let OV=LS.g("gm_ov",{EMA:1,VWAP:1,Zonas:1,"Señales":1,Niveles:1,Posiciones:1});
const el=$("chart");const chart=LightweightCharts.createChart(el,{layout:{background:{color:"#0b0e14"},textColor:"#d1d5db"},grid:{vertLines:{color:"#131925"},horzLines:{color:"#131925"}},
 crosshair:{mode:0},rightPriceScale:{borderColor:"#1f2937"},timeScale:{borderColor:"#1f2937",timeVisible:true,rightOffset:12},localization:{priceFormatter:p=>p.toFixed(2)}});
const cs=chart.addCandlestickSeries({upColor:"#26a65b",downColor:"#d63040",borderVisible:false,wickUpColor:"#26a65b",wickDownColor:"#d63040"});
const vol=chart.addHistogramSeries({priceFormat:{type:"volume"},priceScaleId:""});vol.priceScale().applyOptions({scaleMargins:{top:.86,bottom:0}});
const L=(c,w=1,st=0)=>chart.addLineSeries({color:c,lineWidth:w,lineStyle:st,priceLineVisible:false,lastValueVisible:false,crosshairMarkerVisible:false});
const e50=L("#3b82f6"),e200=L("#a855f7"),vw=L("#f5c542",2,2);
new ResizeObserver(()=>chart.applyOptions({width:el.clientWidth,height:el.clientHeight})).observe(el);
let lines={pos:[],zones:[],lv:[],tr:[],user:[]};const clr=k=>{lines[k].forEach(l=>cs.removePriceLine(l));lines[k]=[]};
const pl=(k,o)=>lines[k].push(cs.createPriceLine(Object.assign({lineWidth:1,axisLabelVisible:true},o)));
function toast(m){const t=$("toast");t.innerHTML=m;t.style.display="block";clearTimeout(t._h);t._h=setTimeout(()=>t.style.display="none",5000)}
function beep(){try{const a=new AudioContext(),o=a.createOscillator();o.frequency.value=880;o.connect(a.destination);o.start();setTimeout(()=>o.stop(),180)}catch(e){}}
function notify(m){toast(m);beep();if(window.Notification&&Notification.permission==="granted")new Notification("GOLD MASTER",{body:m.replace(/<[^>]+>/g,"")})}
if(window.Notification&&Notification.permission==="default")Notification.requestPermission();
function tfBtns(){$("tf").innerHTML=TFS.map(t=>`<button class="${t==tf?'on':''}" onclick="setTf('${t}')">${t}</button>`).join("");
 $("tog").innerHTML=Object.keys(OV).map(k=>`<button class="${OV[k]?'on':''}" onclick="tog('${k}')">${k}</button>`).join("")}
function tog(k){OV[k]=!OV[k];LS.s("gm_ov",OV);tfBtns();vis();overlays()}
function vis(){e50.applyOptions({visible:!!OV.EMA});e200.applyOptions({visible:!!OV.EMA});vw.applyOptions({visible:!!OV.VWAP})}
async function load(){let d={};try{d=await (await fetch(`/api/candles?tf=${tf}&n=2000`)).json()}catch(e){};if(!d.candles||!d.candles.length){toast&&toast("Esperando datos de MT5…");setTimeout(()=>load().then(vis),2000);return;}
 cs.setData(d.candles);vol.setData(d.volume);e50.setData(d.ema50);e200.setData(d.ema200);vw.setData(d.vwap);chart.timeScale().scrollToRealTime();overlays();userLines()}
function setTf(t){tf=t;LS.s("gm_tf",t);tfBtns();load()}
const kv=(k,v,c="")=>`<div class="kv"><span class="mut">${k}</span><span class="${c}">${v}</span></div>`;const f=(x,d=2)=>x==null||x===""?"—":(+x).toFixed(d);
let lastTrade=0;
async function overlays(){try{const o=await (await fetch(`/api/overlays?tf=${tf}`)).json();clr("zones");clr("lv");clr("tr");
 if(OV.Zonas)(o.zones||[]).forEach(z=>pl("zones",{price:z.price,color:z.side=="supply"?"rgba(236,72,153,.55)":"rgba(6,182,212,.55)",lineWidth:2,lineStyle:0,title:(z.side=="supply"?"Oferta ":"Demanda ")+z.touches+"x"}));
 if(OV.Niveles)Object.entries(o.levels||{}).forEach(([k,v])=>pl("lv",{price:v,color:"#64748b",lineStyle:3,title:k}));
 try{cs.setMarkers(OV["Señales"]?(o.markers||[]).filter(m=>m.time>1e9).sort((a,b)=>a.time-b.time):[])}catch(e){console.warn(e)}
 const t=o.trade;if(t&&OV["Señales"]){const c=t.dir>0?"#06b6d4":"#ec4899";pl("tr",{price:t.entry,color:"#e5e7eb",lineWidth:2,title:"Entrada"});pl("tr",{price:t.sl,color:"#d63040",lineStyle:2,title:"SL"});
  ["tp1","tp2","tp3"].forEach((k,i)=>pl("tr",{price:t[k],color:"#26a65b",lineStyle:i==2?0:2,title:k.toUpperCase()}));
  $("ticket").innerHTML=`<b style="color:${c}">${t.dir>0?"▲ COMPRA":"▼ VENTA"}${t.score>=4?"+":""}</b> <span class="mut">score ${t.score}/6</span>`+kv("Entrada",f(t.entry))+kv("SL",f(t.sl),"dn")+kv("TP1 / TP2 / TP3",`${f(t.tp1)} / ${f(t.tp2)} / ${f(t.tp3)}`,"up");
  if(lastTrade&&t.time!==lastTrade)notify(`Nueva señal ${t.dir>0?"COMPRA":"VENTA"} ${f(t.entry)} · SL ${f(t.sl)} · TP2 ${f(t.tp2)}`);lastTrade=t.time}else $("ticket").innerHTML="<span class='mut'>sin señal activa</span>";
}catch(e){}}
// líneas del usuario: Alt+clic = línea horizontal, Shift+clic = alerta de precio, clic derecho sobre ninguna = borrar todas
let UL=LS.g("gm_lines_"+"__SYM__",[]),AL=LS.g("gm_alerts_"+"__SYM__",[]);
function userLines(){clr("user");UL.forEach(p=>pl("user",{price:p,color:"#f5c542",lineStyle:0,title:"línea"}));AL.forEach(p=>pl("user",{price:p,color:"#f97316",lineStyle:1,title:"🔔 "+p.toFixed(2)}))}
chart.subscribeClick(p=>{const e=window.event;if(!p.point||!e)return;const price=cs.coordinateToPrice(p.point.y);if(price==null)return;
 if(e.altKey){UL.push(price);LS.s("gm_lines___SYM__",UL);userLines()}else if(e.shiftKey){AL.push(price);LS.s("gm_alerts___SYM__",AL);userLines();toast("Alerta en "+price.toFixed(2))}});
el.addEventListener("contextmenu",e=>{if(UL.length||AL.length){e.preventDefault();if(confirm("¿Borrar tus líneas y alertas?")){UL=[];AL=[];LS.s("gm_lines___SYM__",UL);LS.s("gm_alerts___SYM__",AL);userLines()}}});
let lastPx=null;
async function live(){try{const d=await (await fetch(`/api/live?tf=${tf}`)).json();if(!d.candles)return;
 d.candles.forEach(c=>cs.update(c));d.volume.forEach(c=>vol.update(c));d.ema50.forEach(c=>e50.update(c));d.ema200.forEach(c=>e200.update(c));d.vwap.forEach(c=>vw.update(c));
 const px=d.candles[d.candles.length-1].close;$("px").textContent=px.toFixed(2);$("px").style.color=lastPx==null||px>=lastPx?"var(--up)":"var(--dn)";$("spr").textContent="spread "+((d.ask-d.bid)||0).toFixed(2);
 if(lastPx!=null)AL=AL.filter(a=>{if((lastPx<a&&px>=a)||(lastPx>a&&px<=a)){notify("🔔 Precio cruzó "+a.toFixed(2));return false}return true});if(lastPx!=null)LS.s("gm_alerts___SYM__",AL);lastPx=px;
 clr("pos");if(OV.Posiciones)(d.positions||[]).forEach(p=>{pl("pos",{price:p.open,color:p.type=="BUY"?"#26a65b":"#d63040",lineWidth:2,title:`${p.type} ${p.vol} ${p.pnl.toFixed(2)}$`});
  if(p.sl)pl("pos",{price:p.sl,color:"#d63040",lineStyle:2,title:"SL pos"});if(p.tp)pl("pos",{price:p.tp,color:"#26a65b",lineStyle:2,title:"TP pos"})});
 const a=d.account||{};$("acc").innerHTML=kv("Balance",f(a.balance)+" $")+kv("Patrimonio",f(a.equity)+" $",(a.equity||0)<(a.balance||0)?"dn":"up")+kv("Nivel de margen",a.margin_level?f(a.margin_level,0)+" %":"—",(a.margin_level||999)<150?"dn":"");
 $("pos").innerHTML=(d.positions||[]).map(p=>kv(`${p.type} ${p.vol} @ ${f(p.open)}`,`${p.pnl.toFixed(2)} $ ${p.sl?"":"<span class='pill dn'>sin SL</span>"}`,p.pnl>=0?"up":"dn")).join("")||"sin posiciones";
}catch(e){}}
let lastAlertTs=0;
async function intel(){try{const q=await (await fetch("/api/intel")).json();const sh=q.dxy_shock||0;
 $("dxy").innerHTML=kv("DXY",f(q.dxy_live,3))+kv("z 60 s",f(q.dxy_z60),Math.abs(q.dxy_z60||0)>2?"dn":"")+kv("Beta oro/DXY",f(q.dxy_beta,3))+kv("Correlación",f(q.dxy_corr_live))+kv("Se adelanta",(q.dxy_lead_s||0)+" s")+kv("Oro esperado",f(q.gold_exp_move)+" $")+kv("Shock",sh?`<span class="pill ${sh>0?'up':'dn'}">${sh>0?'ALCISTA oro':'BAJISTA oro'}</span>`:"—");
 $("mic").innerHTML=kv("Sesgo micro",f(q.micro_bias),q.micro_bias>0?"up":"dn")+kv("OFI 60 s",f(q.ofi_60,0))+kv("Velocidad ticks z",f(q.tick_z))+kv("Spread z",f(q.spread_z),q.spread_z>3?"dn":"")+kv("Oro z 60 s",f(q.g_z60));
 $("reg").innerHTML=kv("Régimen",q.regime_q||"—")+kv("ADX / ER",f(q.adx,1)+" / "+f(q.er))+kv("Kalman z",f(q.kalman_z))+kv("Vol. prevista ("+(q.vol_model||"")+")",f(q.vol_fcst)+" %")+kv("VaR / ES 95 %",f(q.var95_pct)+" / "+f(q.es95_pct)+" %")+kv("Riesgo de cartera",f(q.port_risk_pct)+" %",q.gov_block?"dn":"")+kv("Multiplicador",f(q.risk_mult))+kv("Bloqueo",q.block_trading?"<span class='pill dn'>SÍ</span>":"no")+kv("Compuesto",f(q.composite),q.composite>0?"up":"dn");
 $("sen").innerHTML=kv("Sentimiento noticias",f(q.sentiment)+" ("+(q.sent_n||0)+")",q.sentiment>0?"up":"dn")+kv("COT índice / sesgo",f(q.cot_index,0)+" / "+f(q.cot_bias))+kv("VPIN",f(q.vpin))+kv("VIX / GVZ",f(q.vix,1)+" / "+f(q.gvz,1))+kv("US10Y (Δ5d)",f(q.us10y,2)+" ("+f(q.us10y_chg5,3)+")")+kv("Ratio oro/plata",f(q.gs_ratio,1))+kv("Sesgo macro",f(q.macro_bias),q.macro_bias>0?"up":"dn")+kv("Hurst",f(q.hurst));
 const al=q.alerts||[];$("alr").innerHTML=al.map(a=>`<div class="alert"><span class="mut">${new Date(a[0]*1000).toLocaleTimeString()}</span> ${a[2]||""}</div>`).join("")||"<span class='mut'>sin alertas</span>";
 if(al.length&&+al[0][0]>lastAlertTs){if(lastAlertTs)notify(al[0][2]);lastAlertTs=+al[0][0]}
}catch(e){}}
async function news(){try{const n=await (await fetch("/api/news")).json();const now=Date.now()/1000;
 $("news").innerHTML=n.map(e=>{const s=e.ts-now,h=Math.floor(Math.abs(s)/3600),m=Math.floor(Math.abs(s)%3600/60),sec=Math.floor(Math.abs(s)%60);
  return kv(`<span class="pill ${e.impact>=3?'dn':''}">${"!".repeat(e.impact||1)}</span> ${e.cur} ${e.title}`,s>0?`${h}h ${m}m ${sec}s`:"en curso",s<1800&&s>0?"dn":"")}).join("")||"<span class='mut'>sin eventos</span>"}catch(e){}}
async function state(){try{const s=await (await fetch("/api/state")).json();
 $("bAuto").className="btn "+(s.auto?"buy":"gray");$("bAuto").textContent="Autónomo: "+(s.auto?"ON":"OFF");$("bOv").className="btn "+(s.override?"warn":"gray");$("bOv").textContent=s.override?"⚠ SIN FILTROS":"Filtros: ON";
 const ok=(b,t)=>`<span class="dot" style="background:${b?'#26a65b':'#d63040'}"></span>${t}`;
 $("sys").innerHTML=ok(s.algo,"Algo MT5")+" &nbsp; "+ok(s.service_age>=0&&s.service_age<90,"Servicio")+" &nbsp; "+ok(true,"Web");
 $("sysd").innerHTML=kv("Trading algorítmico MT5",s.algo?"ON":"<span class='pill dn'>OFF</span>")+kv("Servicio (latido)",s.service_age>=0?s.service_age+" s":"—")+kv("EA activo",s.ea.ea||s.ea.name||"—")}catch(e){}}
async function research(){try{const r=await (await fetch("/api/research")).json();const p=r.params||{};
 $("prm").innerHTML=kv("DEMA",`${p.fast||"—"}/${p.slow||"—"}`)+kv("Puntuación mín.",p.minscore||"—")+kv("TP (R)",p.tp||"—")+kv("Validación exp. / PF",`${p.oos_exp||"—"} / ${p.oos_pf||"—"}`)+kv("Actualizado",p.ts?new Date(p.ts*1000).toLocaleString():"—");
 $("mc").innerHTML=Object.entries(r.mc||{}).map(([k,v])=>kv(k,`<span class="${v.ret_p50>0?'up':'dn'}">${v.ret_p50.toFixed(1)}%</span> · P(gan) ${(v.p_profit*100).toFixed(0)}% · DD ${v.dd_p50.toFixed(0)}%`)).join("")||"ejecuta gm_montecarlo.py";
 const lab=r.lab||{};$("lab").innerHTML=Object.entries(lab).map(([tfn,o])=>Object.entries(o).map(([n,x])=>x.OOS?kv(`${tfn} ${n}`,`PF ${x.OOS.pf.toFixed(2)} · ${x.OOS.n} ops · ${x.OOS.usd.toFixed(1)}$`,x.OOS.usd>0?"up":"dn"):"").join("")).join("")||"ejecuta gm_lab.py"}catch(e){}}
async function act(a){const r=await (await fetch("/api/action",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({act:a,lot:+$("lot").value,rr:+$("rr").value})})).json();toast(r.msg);state();live()}
document.querySelectorAll(".tabs button").forEach(b=>b.onclick=()=>{document.querySelectorAll(".tabs button").forEach(x=>x.classList.toggle("on",x==b));
 document.querySelectorAll("aside section").forEach(s=>s.style.display=s.dataset.p==b.dataset.t?"":"none");if(b.dataset.t=="res")research()});
document.addEventListener("keydown",e=>{if(e.target.tagName=="INPUT")return;const i=TFS.indexOf(tf);if(e.key=="ArrowRight"&&i<TFS.length-1)setTf(TFS[i+1]);if(e.key=="ArrowLeft"&&i>0)setTf(TFS[i-1]);if(e.key=="r")chart.timeScale().scrollToRealTime()});
tfBtns();load().then(vis);setInterval(live,1000);setInterval(intel,2000);setInterval(overlays,15000);setInterval(news,1000);setInterval(state,5000);intel();news();state();
</script></body></html>"""
