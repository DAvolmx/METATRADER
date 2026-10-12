/* LDZ Trading Terminal · Web (interfaz estilo TradingView)
 * - Pestañas: cada una es una sesión independiente en el servidor (?sid=…).
 * - Gráficos: TradingView Lightweight Charts™ + capa canvas propia (SMC, operaciones, dibujos).
 * - El navegador NO calcula trading: pide al servidor, que filtra todo por el reloj del replay.
 */
"use strict";
const LWC = window.LightweightCharts;
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const TF_SEC = { M1: 60, M2: 120, M3: 180, M5: 300, M10: 600, M15: 900, M30: 1800, H1: 3600, H3:10800, H4: 14400, D1: 86400, W1: 604800, MN1: 2592000 };
const TF_BTNS = [["1m", "M1"], ["2m", "M2"], ["3m", "M3"], ["5m", "M5"], ["10m", "M10"], ["15m", "M15"], ["30m", "M30"],
                 ["1h", "H1"], ["3h", "H3"], ["4h", "H4"], ["D", "D1"], ["S", "W1"], ["M", "MN1"]];
const MIN_SPEED = 0.1, MAX_SPEED = 200, MIN_INTERVAL = 40;
const LAYOUT_TFS = { "1": ["H1"], "2": ["H1", "M5"], "2v": ["H4", "M15"], "3": ["D1","H4","M15"], "4": ["D1", "H4", "H1", "M15"] };
const DEFAULT_CHECKLIST = "La estructura de la temporalidad superior va a mi favor\nHay un BOS/CHoCH que justifica la idea\nEntro en una zona (FVG/OB) y no en mitad del movimiento\nEl SL está detrás de estructura, no a una distancia arbitraria\nEl R:R es al menos 1:2\nNo estoy operando por impulso o para recuperar pérdidas";

const store = { get(k, d) { try { const v = localStorage.getItem("ldz." + k); return v === null ? d : JSON.parse(v); } catch (_) { return d; } },
                set(k, v) { try { localStorage.setItem("ldz." + k, JSON.stringify(v)); } catch (_) {} } };
const S = {
  tabs: store.get("tabs", []), active: store.get("active", null), panes: [], focus: 0, state: null, playing: false,
  layers:store.get("layers",{ema20:true,ema50:true,macro:true,quotes:true,trades:true}),
  followLatest:false, linkTime:store.get("linkTime",true), timeWindow:null, rangeSync:false, updatingCharts:false, drawLocked:store.get("drawLocked",true), magnet:store.get("magnet",false), speed: 1, tool: null, toolPts: [], btTrades: [], showBt: true, showDraw: true, showSmc: store.get("showSmc",true), smcOpts: {},
  busy: false, pendingFull: false, sessionVer: null, digits: 2, picking: false, rp: store.get("rp", "trade"), seen: null,
};
const theme = () => document.documentElement.dataset.theme;
const sid = () => S.active;
const T = (v, d) => (v === null || v === undefined || Number.isNaN(v)) ? "N/A" : Number(v).toFixed(d ?? S.digits);
const fmtT = (t) => t ? new Date(t * 1000).toISOString().slice(0, 16).replace("T", " ") : "—";
const isoOf = (t) => new Date(t * 1000).toISOString().replace(".000Z", "+00:00");
function lowerBound(arr, t) { let lo = 0, hi = arr.length - 1, a = -1; while (lo <= hi) { const m = (lo + hi) >> 1; if (arr[m] <= t) { a = m; lo = m + 1; } else hi = m - 1; } return a; }

// ------------------------------------------------------------------ API
async function api(path, opts = {}) {
  const url = path.includes("sid=") || !opts.sid ? path : path + (path.includes("?") ? "&" : "?") + "sid=" + encodeURIComponent(opts.sid);
  const o = { method: opts.method || "GET", headers: {} };
  if (opts.body !== undefined) { o.body = JSON.stringify(opts.body); o.headers["Content-Type"] = "application/json"; }
  const r = await fetch(url, o);
  let data = null; try { data = await r.json(); } catch (_) {}
  if (!r.ok) {
    const detail=data?.detail,labels={entry_price:"Precio de activación",risk_pct:"Riesgo %",volume:"Volumen",sl:"Stop loss",tp:"Objetivo"};
    const message=Array.isArray(detail)?detail.map(e=>`${labels[e.loc?.at(-1)]||e.loc?.at(-1)||"Campo"}: ${e.type==="greater_than"?"debe ser mayor que "+e.ctx?.gt:e.type==="finite_number"?"introduce un número válido":e.msg}`).join(". "):typeof detail==="string"?detail:r.statusText;
    throw new Error(message||"No se pudo completar la solicitud");
  }
  return data;
}
const sapi = (path, opts = {}) => api(path, { ...opts, sid: sid() });
function toast(msg, cls = "") {
  const duplicate=$$("#toast > div").find(x=>x.textContent===msg);if(duplicate)return;
  const d = document.createElement("div"); d.className = cls; d.textContent = msg;
  const box = $("#toast"); box.appendChild(d); while (box.children.length > 3) box.firstChild.remove();
  setTimeout(() => d.remove(), cls === "err" ? 7000 : 3500);
}
const err = (e) => toast(e.message || String(e), "err");

// ------------------------------------------------------------------ colores según tema
function palette() {
  const dark = theme() === "dark";
  return { bg: dark ? "#131722" : "#ffffff", text: dark ? "#d1d4dc" : "#131722", grid: dark ? "#1f2430" : "#f2f4f8",
    border: dark ? "#2a2e39" : "#e0e3eb", up: dark ? "#26a69a" : "#089981", down: dark ? "#ef5350" : "#f23645",
    sUp: "#7e57c2", sDown: "#ba68c8", muted: "#787b86", draw: dark ? "#ffeb3b" : "#2962ff" };
}

// ================================================================== PANEL DE GRÁFICO
class Pane {
  constructor(idx, tf) {
    this.sessionId=sid(); this.idx = idx; this.tf = tf; this.times = []; this.itemsTimes = []; this.bars = []; this.smc = null;
    this.drawings = []; this.selected = null; this.drag = null; this.lastSig = null; this.measure = null; this.flash = null;
    const el = document.createElement("div"); el.className = "cp";
    el.innerHTML = `<div class="pane-head"><div class="legend"><div class="ttl"></div><div class="ohlc"></div><div class="window-info"></div></div>
      <div class="bs"><button class="s" title="Venta virtual"><b class="bid">—</b><small>VENDER</small></button>
        <span class="sp">—</span><button class="b" title="Compra virtual"><b class="ask">—</b><small>COMPRAR</small></button></div></div><div class="host"></div>`;
    $("#grid").appendChild(el);
    this.el = el; this.host = $(".host", el);
    const info=document.createElement("button");info.className="pane-info-btn";info.textContent="⋯";info.title="Mostrar/ocultar OHLC y fechas";info.setAttribute("aria-expanded","false");
    info.onclick=()=>{const on=el.classList.toggle("head-expanded");info.setAttribute("aria-expanded",String(on));};$(".pane-head",el).append(info);
    const P = palette();
    this.chart = LWC.createChart(this.host, {
      autoSize: true, localization: { locale: "es-ES", dateFormat: "dd MMM 'yy" },
      layout: { background: { type: "solid", color: P.bg }, textColor: P.text, fontSize: 12, fontFamily: "-apple-system, Segoe UI, Roboto, sans-serif" },
      grid: { vertLines: { color: P.grid }, horzLines: { color: P.grid } },
      crosshair: { mode: LWC.CrosshairMode.Normal },
      rightPriceScale: { borderColor: P.border, scaleMargins: { top: 0.12, bottom: 0.08 } },
      timeScale: { borderColor: P.border, timeVisible: true, secondsVisible: false, rightOffset: 12, shiftVisibleRangeOnNewBar:false, rightBarStaysOnScroll:true },
    });
    this.series = this.chart.addCandlestickSeries({ upColor: P.up, downColor: P.down, borderUpColor: P.up, borderDownColor: P.down,
      wickUpColor: P.up, wickDownColor: P.down, priceLineColor: P.down, priceFormat: { type: "price", precision: 2, minMove: 0.01 } });
    this.studiesVisible=true;
    this.ema20=this.chart.addLineSeries({color:"#f5a623",lineWidth:1,priceLineVisible:false,lastValueVisible:false,visible:this.studiesVisible && S.layers.ema20,title:"EMA20"});
    this.ema50=this.chart.addLineSeries({color:"#42a5f5",lineWidth:1,priceLineVisible:false,lastValueVisible:false,visible:this.studiesVisible && S.layers.ema50,title:"EMA50"});
    this.canvas = document.createElement("canvas"); this.canvas.className = "ov"; this.host.appendChild(this.canvas);
    this.ctx = this.canvas.getContext("2d");
    const rd = () => this.requestDraw();
    this.chart.timeScale().subscribeVisibleLogicalRangeChange(() => {rd();this.syncWindow();});
    this.chart.subscribeCrosshairMove((p) => { this.onCrosshair(p); rd(); });
    this.resizeObserver=new ResizeObserver(rd); this.resizeObserver.observe(this.host);
    this.host.addEventListener("mousedown", (e) => this.onMouseDown(e), true);
    this.host.addEventListener("mousemove", (e) => this.onMove(e));
    this.host.addEventListener("contextmenu", (e) => this.onContext(e));
    const begin=()=>{this.interacting=true;S.followLatest=false;$("#followLatest").classList.remove("on");};
    this.host.addEventListener("mousedown",begin,true);
    this.endInteraction=()=>{if(this.interacting){this.syncWindow(true);this.interacting=false;}};
    window.addEventListener("mouseup",this.endInteraction);
    this.host.addEventListener("wheel",()=>{begin();clearTimeout(this.interactionTimer);this.interactionTimer=setTimeout(this.endInteraction,200);rd();},{passive:true});
    el.addEventListener("mousedown", () => setFocus(this.idx), true);
    $(".bs .s", el).onclick = (e) => { e.stopPropagation(); sendOrder("SELL"); };
    $(".bs .b", el).onclick = (e) => { e.stopPropagation(); sendOrder("BUY"); };
  }
  destroy() { window.removeEventListener("mouseup",this.endInteraction);clearTimeout(this.interactionTimer);this.destroyed=true; this.resizeObserver.disconnect(); if(this._raf) cancelAnimationFrame(this._raf); this.chart.remove(); this.el.remove(); }
  applyTheme() {
    const P = palette();
    this.chart.applyOptions({ layout: { background: { type: "solid", color: P.bg }, textColor: P.text },
      grid: { vertLines: { color: P.grid }, horzLines: { color: P.grid } }, rightPriceScale: { borderColor: P.border }, timeScale: { borderColor: P.border } });
    this.series.applyOptions({ upColor: P.up, downColor: P.down, borderUpColor: P.up, borderDownColor: P.down, wickUpColor: P.up, wickDownColor: P.down });
    this.lastSig = null;
  }
  requestDraw() { if(this.destroyed) return; if (!this._raf) this._raf = requestAnimationFrame(() => { this._raf = null; this.draw(); }); }

  // ---------- datos
  setData(c, full) {
    const P = palette();
    const item = (b) => b.synthetic ? { time: b.time, open: b.open, high: b.high, low: b.low, close: b.close,
      color: b.close >= b.open ? P.sUp : P.sDown, borderColor: b.close >= b.open ? P.sUp : P.sDown, wickColor: b.close >= b.open ? P.sUp : P.sDown }
      : { time: b.time, open: b.open, high: b.high, low: b.low, close: b.close };
    let bars = c.bars;
    if (!full && this.bars.length && bars.length) {
      const first = bars[0].time, k = lowerBound(this.times, first - 1);
      if (first > this.times[this.times.length - 1]) S.pendingFull = true;
      bars = this.bars.slice(0, k + 1).concat(bars);
    }
    this.bars = bars; this.times = bars.map(b => b.time);
    const items = bars.map(item);
    if (c.forming && (!items.length || c.forming.time > items[items.length - 1].time)) {
      const f = c.forming, col = f.close >= f.open ? P.up : P.down;
      items.push({ time: f.time, open: f.open, high: f.high, low: f.low, close: f.close, color: col + "66", borderColor: col, wickColor: col });
    }
    const sig = `${this.tf}|${items.length ? items[0].time : 0}|${theme()}`;
    if (full || sig !== this.lastSig) { this.series.setData(items); this.lastSig = sig; }
    else { try { items.slice(-Math.min(items.length, c.bars.length + 1)).forEach(it => this.series.update(it)); } catch (_) { this.series.setData(items); } }
    const ema=(period)=>{const out=[];let value=null;const alpha=2/(period+1);
      for(let i=0;i<bars.length;i++){const b=bars[i];value=value===null?b.close:alpha*b.close+(1-alpha)*value;
        if(i>=period-1) out.push({time:b.time,value});}return out;};
    this.ema20.setData(ema(20));this.ema50.setData(ema(50));
    const precision=S.state?.digits??2,step=S.state?.point??.01;
    this.series.applyOptions({priceFormat:{type:"price",precision,minMove:step}});
    this.itemsTimes = items.map(i => i.time);
    this.macro=c.macro || null;
    this.smc = c.smc || null;
    this.renderLegend();
    this.requestDraw();
  }
  renderLegend(b) {
    const st = S.state; if (!st || !st.loaded) return;
    const last = b || this.bars[this.bars.length - 1]; if (!last) return;
    const ch = last.close - last.open, cls = ch >= 0 ? "up" : "dn";
    $(".ttl", this.el).innerHTML = `${st.symbol} · ${this.tf} · LDZ <span class="muted small">${this.smc ? "estructura " + this.smc.state : ""}</span>`;
    $(".ohlc", this.el).innerHTML = `<span>A<b class="${cls}">${T(last.open)}</b></span><span>Máx<b class="${cls}">${T(last.high)}</b></span>
      <span>Mín<b class="${cls}">${T(last.low)}</b></span><span>C<b class="${cls}">${T(last.close)}</b></span>
      <span class="${cls}">${ch >= 0 ? "+" : ""}${T(ch)} (${ch >= 0 ? "+" : ""}${(ch / last.open * 100).toFixed(2)}%)</span>`;
  }
  // ---------- coordenadas (índice lógico, como TradingView)
  // Anclas absolutas UTC/precio; interpolación reversible sin redondear a velas.
  logicalOf(t) { const tt=this.itemsTimes,n=tt.length,step=TF_SEC[this.tf]||60;
    if(!n||!Number.isFinite(t))return null;
    if(t<tt[0])return (t-tt[0])/step;
    if(t>=tt[n-1])return n-1+(t-tt[n-1])/step;
    const i=lowerBound(tt,t);return i+(t-tt[i])/(tt[i+1]-tt[i]); }
  x(t) { const l=this.logicalOf(t);return l===null?null:this.chart.timeScale().logicalToCoordinate(l); }
  y(p) { return this.series.priceToCoordinate(p); }
  timeAtX(x) { const l=this.chart.timeScale().coordinateToLogical(x),tt=this.itemsTimes,n=tt.length,step=TF_SEC[this.tf]||60;
    if(l===null||!n)return null;
    if(l<0)return tt[0]+l*step;
    if(l>=n-1)return tt[n-1]+(l-n+1)*step;
    const i=Math.floor(l);return tt[i]+(l-i)*(tt[i+1]-tt[i]); }
  priceAtY(y) { return this.series.coordinateToPrice(y); }
  rightX() { return this.chart.timeScale().width(); }
  localXY(e) { const r = this.host.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; }

  // ---------- pintado
  draw() {
    const w = this.host.clientWidth, h = this.host.clientHeight, dpr = window.devicePixelRatio || 1;
    if (this.canvas.width !== w * dpr || this.canvas.height !== h * dpr) { this.canvas.width = w * dpr; this.canvas.height = h * dpr;
      this.canvas.style.width = w + "px"; this.canvas.style.height = h + "px"; }
    const g = this.ctx; g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, w, h);
    const R = this.rightX(), H = h - this.chart.timeScale().height();
    g.save(); g.beginPath(); g.rect(0, 0, R, H); g.clip();
    if (this.smc && S.showSmc) this.drawSMC(g, R);
    if(S.layers.trades) this.drawTrades(g);
    if(S.layers.macro && this.macro?.valid){const m=this.macro;
      for(const [key,col] of [["high","#ef5350"],["low","#42a5f5"],["open","#b2b5be"],["close","#f5a623"]]){
        const y=this.y(m[key]);this.line(g,0,y,R,y,col,1,[5,4]);this.label(g,`H3 ${key} ${T(m[key])}`,10,y,col);}
      const x1=this.x(m.start),x2=this.x(m.time);
      for(const value of [m.upper,m.mid,m.lower])this.line(g,x1,this.y(value-m.slope*(m.time-m.start)/10800),x2,this.y(value),"#ab75e8",1.5);
    }
    if (S.showDraw) this.drawDrawings(g, R, H);
    this.drawMeasure(g); this.drawFlash(g, H); this.drawQuiz(g, R);
    if (S.picking && this.hoverX !== undefined) this.line(g, this.hoverX, 0, this.hoverX, H, "#7b1fa2", 2, [6, 4]);
    g.restore();
  }
  line(g, x1, y1, x2, y2, c, w = 1, d = []) { if ([x1, y1, x2, y2].some(v => v === null || v === undefined)) return;
    g.strokeStyle = c; g.lineWidth = w; g.setLineDash(d); g.beginPath(); g.moveTo(x1, y1); g.lineTo(x2, y2); g.stroke(); g.setLineDash([]); }
  rect(g, x1, y1, x2, y2, fill, stroke) { if ([x1, y1, x2, y2].some(v => v === null || v === undefined)) return;
    g.fillStyle = fill; g.fillRect(Math.min(x1, x2), Math.min(y1, y2), Math.abs(x2 - x1), Math.abs(y2 - y1));
    if (stroke) { g.strokeStyle = stroke; g.lineWidth = 1; g.strokeRect(Math.min(x1, x2), Math.min(y1, y2), Math.abs(x2 - x1), Math.abs(y2 - y1)); } }
  text(g, s, x, y, c, al = "left", base = "bottom", bold = false) { if (x === null || y === null) return; g.fillStyle = c;
    g.font = `${bold ? "600 " : ""}11px -apple-system, Segoe UI, sans-serif`; g.textAlign = al; g.textBaseline = base; g.fillText(s, x, y); }
  label(g, s, x, y, bg, fg = "#fff") { if (x === null || y === null) return; g.font = "600 11px Segoe UI, sans-serif";
    const w = g.measureText(s).width + 10; g.fillStyle = bg; g.fillRect(x, y - 9, w, 18); this.text(g, s, x + 5, y, fg, "left", "middle", true); }
  tri(g, x, y, up, c, s = 4) { if (x === null || y === null) return; g.fillStyle = c; g.beginPath();
    if (up) { g.moveTo(x, y - s); g.lineTo(x - s, y + s); g.lineTo(x + s, y + s); } else { g.moveTo(x, y + s); g.lineTo(x - s, y - s); g.lineTo(x + s, y - s); }
    g.closePath(); g.fill(); }
  drawSMC(g, R) {
    const m = this.smc, o = S.smcOpts, P = palette();
    if (m.range) { const x = this.x(m.range.from);
      this.rect(g, x, this.y(m.range.high), R, this.y(m.range.low), "rgba(120,123,134,0.10)", "#9598a1"); this.text(g, "RANGO", x + 4, this.y(m.range.high) - 3, "#787b86", "left", "bottom", true); }
    if (o.fvg !== false) for (const f of m.fvgs) this.rect(g, this.x(f.from), this.y(f.top), R, this.y(f.bottom),
      f.direction === "bullish" ? "rgba(8,153,129,0.13)" : "rgba(242,54,69,0.13)");
    if (o.order_blocks !== false) for (const b of m.order_blocks) { const c = b.direction === "bullish" ? "41,98,255" : "245,124,0";
      this.rect(g, this.x(b.from), this.y(b.top), R, this.y(b.bottom), `rgba(${c},0.14)`, `rgba(${c},0.7)`);
      this.text(g, "OB", this.x(b.from) + 3, this.y(b.top) - 2, `rgb(${c})`, "left", "bottom", true); }
    for (const l of m.liquidity) { const key = l.equal ? (l.kind === "BSL" ? "eqh" : "eql") : l.kind.toLowerCase(); if (o[key] === false) continue;
      const c = l.equal ? "#f57c00" : "#9598a1", y = this.y(l.price); this.line(g, this.x(l.from), y, R, y, c, 1, [2, 3]);
      if (l.equal) this.text(g, l.label, R - 4, y - 2, c, "right", "bottom", true); }
    for (const e of m.events) { if ((e.type === "BOS" && o.bos === false) || (e.type === "CHoCH" && o.choch === false)) continue;
      const bull = e.direction === "bullish", c = e.type === "BOS" ? (bull ? P.up : P.down) : (bull ? "#00acc1" : "#f57c00");
      const x1 = this.x(e.from), x2 = this.x(e.time), y = this.y(e.price);
      this.line(g, x1, y, x2, y, c, 1.5, e.type === "BOS" ? [] : [5, 3]);
      if (x1 !== null && x2 !== null) this.text(g, e.new_state === "RANGING" ? "CHoCH→RANGO" : e.type, (x1 + x2) / 2, y + (bull ? -3 : 12), c, "center", "bottom", true); }
    if (o.swings !== false) for (const s of m.swings) this.tri(g, this.x(s.time), this.y(s.price) + (s.kind === "HIGH" ? -8 : 8), s.kind === "LOW", "#9598a1", 3);
  }
  drawTrades(g) {
    const P = palette(), list = ((S.state && S.state.trades) || []).concat(S.showBt ? S.btTrades : []);
    for (const t of list) { if (!t.entry_time) continue;
      const x0 = this.x(t.entry_time), closed = !!t.exit_time, x1 = closed ? this.x(t.exit_time) : this.rightX();
      if (!closed && t.status === "OPEN") {   // posición abierta: zonas de riesgo/beneficio estilo TradingView
        if (t.tp) this.rect(g, x0, this.y(t.entry_price), x1, this.y(t.tp), "rgba(8,153,129,0.14)");
        if (t.sl) this.rect(g, x0, this.y(t.entry_price), x1, this.y(t.sl), "rgba(242,54,69,0.14)");
        this.label(g, `${t.direction === "BUY" ? "COMPRA" : "VENTA"} ${t.volume}  ${T(t.floating, 2)}`, 6, this.y(t.entry_price), t.direction === "BUY" ? "#2962ff" : P.down);
      } else {
        if (t.sl) this.line(g, x0, this.y(t.sl), x1, this.y(t.sl), P.down, 1);
        if (t.tp) this.line(g, x0, this.y(t.tp), x1, this.y(t.tp), P.up, 1);
      }
      this.tri(g, x0, this.y(t.entry_price), t.direction === "BUY", t.direction === "BUY" ? "#2962ff" : P.down, 6);
      if (closed) { const c = t.profit > 0 ? P.up : (t.profit < 0 ? P.down : "#9598a1");
        this.line(g, x0, this.y(t.entry_price), x1, this.y(t.exit_price), c, 1.5, [4, 3]);
        const xx = x1, yy = this.y(t.exit_price); if (xx !== null && yy !== null) { this.line(g, xx - 4, yy - 4, xx + 4, yy + 4, c, 2); this.line(g, xx - 4, yy + 4, xx + 4, yy - 4, c, 2); } }
    }
  }
  drawQuiz(g, R) {
    const q = S.state && S.state.quiz_open; if (!q) return;
    const x = this.x(q.time), y = this.y(q.price); this.line(g, x, 0, x, 2000, "#7b1fa2", 1, [3, 3]);
    this.label(g, `Reto: ${q.guess === "UP" ? "▲ SUBE" : "▼ BAJA"} · ${q.horizon} velas`, Math.max(4, (x || 0) + 6), (y || 40) - 20, "#7b1fa2");
  }
  drawFlash(g, H) { if (!this.flash || Date.now() > this.flash.until) return; const x = this.x(this.flash.t);
    this.line(g, x, 0, x, H, "#7b1fa2", 2); if (this.flash.p) { const y = this.y(this.flash.p); this.line(g, 0, y, this.rightX(), y, "#7b1fa2", 1, [4, 4]); } }
  drawMeasure(g) {
    const m = this.measure; if (!m || !m.b) return;
    const x1 = this.x(m.a.t), y1 = this.y(m.a.p), x2 = this.x(m.b.t), y2 = this.y(m.b.p); const up = m.b.p >= m.a.p;
    this.rect(g, x1, y1, x2, y2, up ? "rgba(41,98,255,0.16)" : "rgba(242,54,69,0.16)", up ? "#2962ff" : "#f23645");
    const d = m.b.p - m.a.p, bars = Math.round(Math.abs(this.logicalOf(m.b.t) - this.logicalOf(m.a.t)));
    const pts = S.state ? d / S.state.point : 0;
    this.label(g, `${d >= 0 ? "+" : ""}${T(d)} (${(d / m.a.p * 100).toFixed(2)}%) · ${pts.toFixed(0)} pts · ${bars} velas`,
      Math.min(x1, x2), Math.min(y1, y2) - 14, up ? "#2962ff" : "#f23645");
  }
  // ---------- dibujos
  tx(c, k) { return this.x(Date.parse(c["t" + k]) / 1000); }
  anchors(d) { const c = d.coordinates, out = {}; let k = 1;
    while (c["p" + k] !== undefined) { out[k] = [c["t" + k] ? this.tx(c, k) : this.rightX() - 20, this.y(c["p" + k])]; k++; }
    if (d.kind === "hline") out[1] = [this.rightX() / 2, this.y(c.p1)];
    if (d.kind === "vline") out[1] = [this.tx(c, 1), this.host.clientHeight / 2];
    return out; }
  drawDrawings(g, R, H) {
    for (const d of this.drawings) { const c = d.coordinates, col = (d.style && d.style.color) || palette().draw;
      if (d.kind === "hline") { const y = this.y(c.p1); this.line(g, 0, y, R, y, col, 1.5); this.label(g, T(c.p1), R - 70, y, col); }
      else if (d.kind === "vline") { const x = this.tx(c, 1); this.line(g, x, 0, x, H, col, 1.5); }
      else if (d.kind === "long" || d.kind === "short") {
        const x1=this.tx(c,1), x2=this.tx(c,3), ye=this.y(c.p1), ys=this.y(c.p2), yt=this.y(c.p3);
        if([x1,x2,ye,ys,yt].some(v=>v===null || !Number.isFinite(v))) continue;
        const left=Math.min(x1,x2),right=Math.max(x1+40,x2),risk=Math.abs(c.p1-c.p2),reward=Math.abs(c.p3-c.p1);
        this.rect(g,left,ye,right,ys,"rgba(242,54,69,.18)","#f23645");
        this.rect(g,left,ye,right,yt,"rgba(38,166,154,.18)","#26a69a");
        this.line(g,left,ye,right,ye,"#b2b5be",1.5);
        this.label(g,`${d.kind.toUpperCase()} · entrada ${T(c.p1)} · RR ${risk?(reward/risk).toFixed(2):"—"}`,left,ye-5,"#b2b5be");
        this.label(g,`SL ${T(c.p2)} · ${(risk/c.p1*100).toFixed(2)}% precio`,left,ys,"#f23645");
        this.label(g,`TP ${T(c.p3)} · dibujo, sin orden`,left,yt,"#26a69a");
      }
      else if (d.kind === "arrow") {
        const x1=this.tx(c,1),x2=this.tx(c,2),y1=this.y(c.p1),y2=this.y(c.p2);
        if([x1,x2,y1,y2].some(v=>v===null)) continue;
        this.line(g,x1,y1,x2,y2,col,2); const a=Math.atan2(y2-y1,x2-x1);
        this.line(g,x2,y2,x2-12*Math.cos(a-.45),y2-12*Math.sin(a-.45),col,2);
        this.line(g,x2,y2,x2-12*Math.cos(a+.45),y2-12*Math.sin(a+.45),col,2);
      }
      else if (d.kind === "trend") this.line(g, this.tx(c, 1), this.y(c.p1), this.tx(c, 2), this.y(c.p2), col, 2);
      else if (d.kind === "ray" || d.kind === "extended") {
        const x1=this.tx(c,1),y1=this.y(c.p1),x2=this.tx(c,2),y2=this.y(c.p2),RW=this.rightX()||R;
        if(x1===null||x2===null) continue;
        const dx=x2-x1,dy=y2-y1,len=Math.hypot(dx,dy)||1,dirx=dx/len,diry=dy/len,far=4*R;
        const rx2=x1+dirx*far,ry2=y1+diry*far;
        const rx1=d.kind==="extended"?x1-dirx*far:x1,ry1=d.kind==="extended"?y1-diry*far:y1;
        this.line(g,rx1,ry1,rx2,ry2,col,2);
        g.fillStyle=col;g.beginPath();g.arc(x1,y1,3,0,Math.PI*2);g.fill();
        g.beginPath();g.arc(x2,y2,3,0,Math.PI*2);g.fill(); }
      else if (d.kind === "rect") this.rect(g, this.tx(c, 1), this.y(c.p1), this.tx(c, 2), this.y(c.p2), col + "22", col);
      else if (d.kind === "text") this.text(g, c.text || "", this.tx(c, 1), this.y(c.p1), col, "left", "bottom", true);
      else if (d.kind === "fib") { const x1 = this.tx(c, 1), x2 = Math.max(this.tx(c, 2) || 0, R - 2);
        for (const lv of [0, .236, .382, .5, .618, .786, 1]) { const p = c.p2 + (c.p1 - c.p2) * lv, y = this.y(p);
          this.line(g, x1, y, x2, y, col, 1, [4, 3]); this.text(g, `${(lv * 100).toFixed(1)}%  ${T(p)}`, x1 + 3, y - 2, col); } }
      else if (d.kind === "channel") { const x1 = this.tx(c, 1), x2 = this.tx(c, 2), x3 = this.tx(c, 3); if ([x1, x2, x3].includes(null)) continue;
        const y1 = this.y(c.p1), y2 = this.y(c.p2), sl = x2 !== x1 ? (y2 - y1) / (x2 - x1) : 0, off = this.y(c.p3) - (y1 + sl * (x3 - x1));
        this.line(g,x1,y1+off/2,R,y1+off/2+sl*(R-x1),col,1,[5,4]);
        this.line(g, x1, y1, R, y1 + sl * (R - x1), col, 1.6); this.line(g, x1, y1 + off, R, y1 + off + sl * (R - x1), col, 1.6);
        g.fillStyle = col + "14"; g.beginPath(); g.moveTo(x1, y1); g.lineTo(R, y1 + sl * (R - x1)); g.lineTo(R, y1 + off + sl * (R - x1)); g.lineTo(x1, y1 + off); g.closePath(); g.fill(); }
      if (this.selected === d.id) for (const [ax, ay] of Object.values(this.anchors(d))) { if (ax === null || ay === null) continue;
        g.fillStyle = palette().bg; g.strokeStyle = "#2962ff"; g.lineWidth = 2; g.beginPath(); g.arc(ax, ay, 5, 0, 7); g.fill(); g.stroke(); }
    }
    if (S.tool && S.toolPts.length && S.toolPane === this) for (const p of S.toolPts) this.tri(g, this.x(p.t), this.y(p.p), true, "#2962ff", 5);
  }
  hit(px, py) {
    const near = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]) <= 8;
    const seg = (p, a, b, kind="segment") => { const dx = b[0] - a[0], dy = b[1] - a[1], L = dx * dx + dy * dy; const raw=L?((p[0]-a[0])*dx+(p[1]-a[1])*dy)/L:0;
      const t=kind==="extended"?raw:kind==="ray"?Math.max(0,raw):Math.max(0,Math.min(1,raw));
      return Math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy)); };
    const P = [px, py];
    if (!S.showDraw) return null;
    for (const d of [...this.drawings].reverse()) {
      for (const [k, a] of Object.entries(this.anchors(d))) if (a[0] !== null && a[1] !== null && near(P, a)) return { id: d.id, mode: "anchor", k: +k };
      const c = d.coordinates; let body = false;
      if (d.kind === "hline") body = Math.abs(this.y(c.p1) - py) <= 6;
      else if (d.kind === "vline") body = Math.abs(this.tx(c, 1) - px) <= 6;
      else if (d.kind === "trend" || d.kind === "ray" || d.kind === "extended" || d.kind === "arrow") body = seg(P, [this.tx(c, 1), this.y(c.p1)], [this.tx(c, 2), this.y(c.p2)],d.kind) <= 6;
      else if (d.kind === "long" || d.kind === "short") {
        const x1=this.tx(c,1),x2=Math.max(x1+40,this.tx(c,3)),ys=this.y(c.p2),yt=this.y(c.p3);
        body=px>=Math.min(x1,x2)-6 && px<=Math.max(x1,x2)+6 && py>=Math.min(ys,yt)-6 && py<=Math.max(ys,yt)+6;
      }
      else if (d.kind === "rect" || d.kind === "fib") { const x1 = this.tx(c, 1), x2 = d.kind === "fib" ? this.rightX() : this.tx(c, 2), y1 = this.y(c.p1), y2 = this.y(c.p2);
        body = px >= Math.min(x1, x2) - 6 && px <= Math.max(x1, x2) + 6 && py >= Math.min(y1, y2) - 6 && py <= Math.max(y1, y2) + 6; }
      else if (d.kind === "text") { const x = this.tx(c, 1), y = this.y(c.p1); body = px >= x && px <= x + 140 && py >= y - 14 && py <= y + 2; }
      else if (d.kind === "channel") { const x1 = this.tx(c, 1), x2 = this.tx(c, 2), x3 = this.tx(c, 3), R = this.rightX(), y1 = this.y(c.p1);
        const sl = x2 !== x1 ? (this.y(c.p2) - y1) / (x2 - x1) : 0, off = this.y(c.p3) - (y1 + sl * (x3 - x1));
        body = seg(P, [x1, y1], [R, y1 + sl * (R - x1)]) <= 6 || seg(P, [x1, y1 + off], [R, y1 + off + sl * (R - x1)]) <= 6; }
      if (body) return { id: d.id, mode: "body", k: 0 };
    }
    return null;
  }
  onMove(e) { this.requestDraw(); const [px] = this.localXY(e); if (S.picking) { this.hoverX = px; this.requestDraw(); }
    if (this.measure && this.measure.a && !this.measure.done) { const [mx, my] = this.localXY(e); const t = this.timeAtX(mx), p = this.priceAtY(my);
      if (t !== null && p !== null) { this.measure.b = { t, p }; this.requestDraw(); } } }
  onMouseDown(e) {
    if (e.button !== 0) return;
    const [px, py] = this.localXY(e); if (px > this.rightX()) return;
    if (S.picking) { e.preventDefault(); e.stopPropagation(); const t = this.timeAtX(px); S.picking = false; this.el.classList.remove("picking");
      if (t !== null) startAt(isoOf(t)); return; }
    if (S.tool === "measure") { e.preventDefault(); e.stopPropagation(); const t = this.timeAtX(px), p = this.priceAtY(py); if (t === null || p === null) return;
      if (!this.measure || this.measure.done) this.measure = { a: { t, p }, b: null, done: false }; else { this.measure.b = { t, p }; this.measure.done = true; }
      this.requestDraw(); return; }
    if (S.tool) { e.preventDefault(); e.stopPropagation(); this.addPoint(px, py); return; }
    const h = this.hit(px, py);
    if (!h) { if (this.selected !== null) { this.selected = null; this.requestDraw(); } return; }
    e.preventDefault(); e.stopPropagation(); this.selected = h.id; const d = this.drawings.find(x => x.id === h.id);
    if(S.drawLocked){this.requestDraw();renderObjectList();return;}
    this.drag = { ...h, start: [px, py], orig: JSON.parse(JSON.stringify(d.coordinates)), d, moved: false };
    this.chart.applyOptions({ handleScroll: false, handleScale: false });
    const move = (ev) => { const [mx, my] = this.localXY(ev); this.dragTo(mx, my); };
    const up = async () => { window.removeEventListener("mousemove", move); window.removeEventListener("mouseup", up);
      this.chart.applyOptions({ handleScroll: true, handleScale: true }); const dr = this.drag; this.drag = null;
      if (dr && dr.moved) await saveDrawing(this, dr.d); this.requestDraw(); };
    window.addEventListener("mousemove", move); window.addEventListener("mouseup", up); this.requestDraw();
  }
  dragTo(mx, my) {
    const dr = this.drag; if (!dr) return; if(!dr.moved && Math.hypot(mx-dr.start[0],my-dr.start[1])<4)return; const c = dr.d.coordinates, o = dr.orig; dr.moved = true;
    if (dr.mode === "anchor") { const k = dr.k;
      if (dr.d.kind !== "vline") { const p = this.priceAtY(my); if (p !== null) c["p" + k] = p; }
      if (dr.d.kind !== "hline" && c["t" + k]) { const t = this.timeAtX(mx); if (t !== null) c["t" + k] = isoOf(t); }
    } else { const dt=this.timeAtX(mx)-this.timeAtX(dr.start[0]);
      const dp=this.priceAtY(my)-this.priceAtY(dr.start[1]);
      for(const key of Object.keys(o)) {
        if(/^p\d+$/.test(key)&&dr.d.kind!=="vline")c[key]=o[key]+dp;
        if(/^t\d+$/.test(key)&&dr.d.kind!=="hline")c[key]=isoOf(Date.parse(o[key])/1000+dt);
      }
    }
    this.requestDraw();
  }
  onContext(e) { const [px, py] = this.localXY(e), h = this.hit(px, py); if (!h) return; e.preventDefault(); this.selected = h.id; this.requestDraw(); openCtx(this, h.id, e.clientX, e.clientY); }
  addPoint(px, py) {
    let t = this.timeAtX(px); const price = this.priceAtY(py); if (t === null || price === null) return;
    // Snap only to OHLC at the clicked time, never another candle's level.
    let snapPrice=price;
    const bar=this.bars[lowerBound(this.times,t)];
    if(S.magnet && bar) {
      t=bar.time; let distance=5;
      for(const lv of [bar.open,bar.high,bar.low,bar.close]) {
        const dy=Math.abs(this.y(lv)-py); if(dy<distance) {distance=dy;snapPrice=lv;}
      }
    }
    if(S.toolPane && S.toolPane!==this) S.toolPts=[];
    S.toolPane=this; S.toolPts.push({t,p:snapPrice}); this.requestDraw();
    const need = { hline: 1, vline: 1, text: 1, trend: 2, ray: 2, extended: 2, rect: 2, fib: 2, channel: 3, long:3, short:3, arrow:2 }[S.tool];
    if (S.toolPts.length < need) { toast(`${S.tool}: punto ${S.toolPts.length}/${need}`); return; }
    const coords = {}; S.toolPts.forEach((q, i) => { coords["t" + (i + 1)] = isoOf(q.t); coords["p" + (i + 1)] = q.p; });
    if (S.tool === "text") { const s = prompt("Texto:"); if (!s) return setTool(null); coords.text = s; }
    if(S.tool==="long" && !(coords.p2<coords.p1 && coords.p1<coords.p3) ||
       S.tool==="short" && !(coords.p3<coords.p1 && coords.p1<coords.p2)) {
      toast("Orden de clics: entrada, stop y objetivo. Revisa el lado de SL/TP."); S.toolPts=[]; this.requestDraw(); return;
    }
    const kind = S.tool,color=S.toolColor||palette().draw; setTool(null);
    api("/api/drawings", { sid:this.sessionId, method: "POST", body: { kind, coordinates: coords, style: { color } } }).then(data => { if (data && data.id) undoStack.push(data.id); if (undoStack.length > MAX_UNDO) undoStack.shift(); return loadDrawings(); }).catch(err);
  }
  onCrosshair(p) {
    if (!p.time || !p.seriesData) { this.renderLegend(); return; }
    const b = p.seriesData.get(this.series); if (b) this.renderLegend(b);
    if (S.syncing || S.panes.length < 2) return; S.syncing = true;
    for (const o of S.panes) if (o !== this && o.itemsTimes.length) { const i = lowerBound(o.itemsTimes, p.time); if (i < 0) continue;
      try { o.chart.setCrosshairPosition(b ? b.close : 0, o.itemsTimes[i], o.series); } catch (_) {} }
    S.syncing = false;
  }
  syncWindow(force=false){
    if((!force&&!this.interacting)||S.rangeSync||S.updatingCharts||!S.linkTime||this.idx!==S.focus||!this.itemsTimes.length)return;
    const r=this.chart.timeScale().getVisibleLogicalRange();if(!r)return;
    const ts=this.chart.timeScale(),a=ts.logicalToCoordinate(r.from),b=ts.logicalToCoordinate(r.to);
    if(a===null||b===null)return;
    const from=this.timeAtX(a),to=this.timeAtX(b);if(S.timeWindow&&Math.abs(from-S.timeWindow.from)<.01&&Math.abs(to-S.timeWindow.to)<.01)return;
    setCommonWindow(from,to,this);
  }
  setRange(code) {
    if(!this.itemsTimes.length)return;
    const end=Number(S.state?.clock)||this.itemsTimes.at(-1)+TF_SEC[this.tf],d=86400;
    const span={"1D":d,"5D":5*d,"1M":30*d,"3M":91*d,"6M":182*d,"1A":365*d,"5A":1826*d}[code];
    const from=code==="ALL"?this.itemsTimes[0]:code==="YTD"?Date.UTC(new Date(end*1000).getUTCFullYear(),0,1)/1000:end-span;
    if(S.linkTime)setCommonWindow(from,end);
    else{this.chart.timeScale().setVisibleLogicalRange({from:this.logicalOf(from),to:this.logicalOf(end)});updateWindowInfo();}
  }
  goto(t, p) { const l = this.logicalOf(t); if (l === null) return; const ts = this.chart.timeScale(), r = ts.getVisibleLogicalRange();
    const half = r ? (r.to - r.from) / 2 : 60; ts.setVisibleLogicalRange({ from: l - half, to: l + half }); this.flash = { t, p, until: Date.now() + 2500 };
    this.requestDraw(); setTimeout(() => this.requestDraw(), 2600); }
}

// Ventana común por fechas, nunca por el mismo número de barras.
function setCommonWindow(from,to,source=null,fitHistory=false){
 const ready=S.panes.filter(p=>p.itemsTimes.length);if(!ready.length||!Number.isFinite(from)||!Number.isFinite(to)||to<=from)return;
 const earliest=Math.max(...ready.map(p=>p.itemsTimes[0]));
 const end=Number(S.state?.clock)||Math.min(...ready.map(p=>p.itemsTimes.at(-1)+TF_SEC[p.tf]));
 if(fitHistory){from=Math.max(from,earliest);to=Math.min(to,end);}if(to<=from)return;
 S.timeWindow={from,to};const tab=tabObj(S.active);if(tab){tab.timeWindow=S.timeWindow;saveTabs();}
 S.rangeSync=true;
 try{for(const p of ready)if(p!==source)p.chart.timeScale().setVisibleLogicalRange({from:p.logicalOf(from),to:p.logicalOf(to)});}
 finally{S.rangeSync=false;}
 updateWindowInfo();
}
function updateWindowInfo(){
 for(const p of S.panes){const el=$(".window-info",p.el);if(!el)continue;
 const r=p.chart.timeScale().getVisibleLogicalRange();if(!r||!p.itemsTimes.length){el.textContent="";continue;}
 const ts=p.chart.timeScale(),a=ts.logicalToCoordinate(r.from),b=ts.logicalToCoordinate(r.to);if(a===null||b===null)continue;
 const from=p.timeAtX(a),to=p.timeAtX(b),n=p.bars.filter(x=>x.time>=from&&x.time<to).length;
 el.textContent=`${fmtT(from)} → ${fmtT(to)} · ${n} velas cerradas${p.itemsTimes.length>p.bars.length && p.itemsTimes.at(-1)>=from && p.itemsTimes.at(-1)<to?" · última en formación":""}`;
 }
}

// ================================================================== PESTAÑAS
function saveTabs() { store.set("tabs", S.tabs); store.set("active", S.active); }
function newSid() { return "t" + Date.now().toString(36) + Math.random().toString(36).slice(2, 6); }
function tabObj(id) { return S.tabs.find(t => t.sid === id); }
function renderTabs(prices = {}) {
  $("#tabs").innerHTML = S.tabs.map(t => { const p = prices[t.sid] || {}; const ch = p.change_pct;
    return `<div class="tab ${t.sid === S.active ? "active" : ""}" data-sid="${t.sid}" title="${t.title || ""}">
      <span class="dot">${(t.symbol || "?").slice(0, 1)}</span><b>${t.symbol || "Nueva"}</b>
      <span class="px">${p.price !== undefined && p.price !== null ? Number(p.price).toFixed(p.digits ?? 2) : ""}</span>
      ${ch !== undefined && ch !== null ? `<span class="ch ${ch >= 0 ? "up" : "dn"}">${ch >= 0 ? "▲ +" : "▼ "}${ch}%</span>` : ""}
      <span class="x" data-close="${t.sid}" title="Cerrar pestaña">✕</span></div>`; }).join("");
  $("#empty").hidden = S.tabs.length > 0; $("#grid").hidden = S.tabs.length === 0;
  renderWatch(prices);
}
function renderWatch(prices) {
  $("#watch").innerHTML = `<tr><th>Pestaña</th><th>TF</th><th>Último</th><th>Cambio</th></tr>` + S.tabs.map(t => { const p = prices[t.sid] || {};
    return `<tr class="click ${t.sid === S.active ? "sel" : ""}" data-sid="${t.sid}"><td><b>${t.symbol || "—"}</b>${p.synthetic_zone ? " *" : ""}${p.live ? " ●" : ""}</td>
      <td>${p.base_tf || "—"}</td><td>${p.price ? Number(p.price).toFixed(p.digits ?? 2) : "—"}</td>
      <td class="${(p.change_pct || 0) >= 0 ? "pos" : "neg"}">${p.change_pct ?? "—"}%</td></tr>`; }).join("");
}
async function pollSessions() {
  try { const list = await api("/api/sessions"); const m = {}; list.forEach(x => m[x.sid] = x); renderTabs(m); } catch (_) {}
}
async function switchTab(id) {
  if(id!==S.active)undoStack.length=0;
  if (id === S.active && S.panes.length) return;
  pause(); S.timeWindow=tabObj(id)?.timeWindow||null; S.active = id; saveTabs(); S.sessionVer = null; S.state = null;
  const t = tabObj(id); buildLayout(t.layout || "1", t.tfs);
  renderTabs();
  try { const st = await sapi("/api/state");
    if (!st.loaded) { if (t.params) await sapi("/api/load", { method: "POST", body: t.params }); else return openLoad(true); }
    await refresh(true); refreshSide(true);
  } catch (e) { err(e); }
}
async function closeTab(id) {
  pause(); try { await api(`/api/sessions/${encodeURIComponent(id)}`, { method: "DELETE" }); } catch (_) {}
  const i = S.tabs.findIndex(t => t.sid === id); S.tabs.splice(i, 1);
  if (S.active === id) { S.active = null; S.panes.forEach(p => p.destroy()); S.panes = []; }
  saveTabs(); renderTabs();
  if (!S.active && S.tabs.length) switchTab(S.tabs[Math.max(0, i - 1)].sid);
}

// ================================================================== DISTRIBUCIÓN Y TEMPORALIDADES
function buildLayout(layout, tfs) {
  setTool(null);
  S.panes.forEach(p => p.destroy()); S.panes = [];
  tfs = (tfs && tfs.length) ? tfs : LAYOUT_TFS[layout];
  const n = { "1": 1, "2": 2, "2v": 2, "3":3, "4": 4 }[layout];
  const tab = tabObj(S.active), base = (S.state && S.state.base_tf) || (tab && tab.params && tab.params.base_tf);
  const fix = (tf) => (!base || derivable(tf, base)) ? tf : base;     // TF imposible para la base -> la base
  tfs = Array.from({ length: n }, (_, i) => fix(tfs[i] || LAYOUT_TFS[layout][i]));
  $("#layoutSelect").value=layout;
  $("#grid").className = "l" + layout;
  for (let i = 0; i < n; i++) S.panes.push(new Pane(i, tfs[i]));
  const t = tabObj(S.active); if (t) { t.layout = layout; t.tfs = S.panes.map(p => p.tf); saveTabs(); }
  setFocus(0);
}
function setFocus(i) { S.focus = i; S.panes.forEach((p, k) => p.el.classList.toggle("focus", k === i)); renderTfBar(); }
const fp = () => S.panes[S.focus] || S.panes[0];
function derivable(tf, base) { const a = TF_SEC[tf], b = TF_SEC[base]; if (!a || !b || a < b) return false;
  if (tf === "W1" || tf === "MN1") return 86400 % b === 0; return a % b === 0; }
function renderTfBar() {
  const base = S.state && S.state.base_tf; const cur = fp() && fp().tf;
  $("#tfBar").innerHTML = TF_BTNS.map(([l, tf]) => `<button data-tf="${tf}" class="${tf === cur ? "active" : ""}" ${base && !derivable(tf, base) ? "disabled title='No se puede construir desde la TF base " + base + "'" : ""}>${l}</button>`).join("");
}
async function setPaneTf(tf) {
  const p = fp(); if (!p || p.tf === tf) return; p.syncWindow(true); p.tf = tf; p.lastSig = null; p.bars = []; p.itemsTimes = [];
  const t = tabObj(S.active); if (t) { t.tfs = S.panes.map(x => x.tf); saveTabs(); }
  renderTfBar(); await refresh(true); refreshSide(true);
}

// ================================================================== REFRESCO
async function refresh(full = false, n = 1) {
  if (!S.active) return;
  if (S.busy) { if (full) S.pendingFull = true; return; }
  S.busy = true;
  try {
    const tfs = [...new Set(S.panes.map(p => p.tf))].join(",");
    const f = await sapi(`/api/frame?tfs=${tfs}&limit=${full ? 5000 : Math.max(6, n + 3)}`);
    if (!full && f.state.session !== S.sessionVer) { S.pendingFull = true; }
    else {
      S.sessionVer = f.state.session; S.state = f.state; S.btTrades = f.bt_trades || [];
      const savedViews=S.panes.map(p=>{
        const ts=p.chart.timeScale(),r=ts.getVisibleLogicalRange();if(!r||!p.itemsTimes.length)return null;
        const a=ts.logicalToCoordinate(r.from),b=ts.logicalToCoordinate(r.to);return a===null||b===null?null:{from:p.timeAtX(a),to:p.timeAtX(b)};
      });
      S.updatingCharts=true;
      try{
        for(const p of S.panes){const d=f.charts[p.tf];if(d)p.setData(d,full);}
        if(S.followLatest){const end=Number(S.state.clock),span=S.timeWindow?S.timeWindow.to-S.timeWindow.from:7*86400;setCommonWindow(end-span,end);}
        else if(S.linkTime){if(S.timeWindow)setCommonWindow(S.timeWindow.from,S.timeWindow.to);else{const end=Number(S.state.clock);setCommonWindow(end-7*86400,end,null,true);}}
        else for(const p of S.panes){const r=savedViews[p.idx];if(r&&p.itemsTimes.length)p.chart.timeScale().setVisibleLogicalRange({from:p.logicalOf(r.from),to:p.logicalOf(r.to)});}
      }finally{S.updatingCharts=false;}
      updateWindowInfo();
      renderState();
      if (full) await loadDrawings();
    }
  } catch (e) { err(e); }
  finally { S.busy = false; if (S.pendingFull) { S.pendingFull = false; refresh(true); } }
}
function renderState() {
  const st = S.state; if (!st) return;
  S.digits = st.digits ?? 2;
  $("#mt5").textContent = `MT5 ${st.mt5 === "CONNECTED" ? "● " + (st.account ? st.account.login : "") : "○ " + st.mt5}`;
  $("#mt5").className = "mt5 " + (st.mt5 === "CONNECTED" ? "ok" : "ko");
  const label = { REPLAY: "REPLAY", LIVE: "LIVE DATA", SYNTHETIC: "SINTÉTICO · NO REAL", REAL: "🔴 REAL TRADING" }[st.mode] || st.mode;
  $("#mode").textContent = label; $("#mode").className = `mode ${st.mode}`;
  $("#btnLive").classList.toggle("on", !!st.live);
  $("#btnAuth").disabled = true; $("#btnKill").disabled = !st.real_enabled;
  if (!st.loaded) return;
  $("#symName").textContent = st.symbol; $("#baseTfLbl").textContent = st.base_tf; renderTfBar();
  $("#clock").textContent = `${fmtT(st.clock)}${st.synthetic_zone ? " · SINTÉTICO" : ""}`;
  $("#utc").textContent = `vela ${st.idx}/${st.total} · reloj del replay (UTC)`;
  for (const p of S.panes) {
    if(!p.quoteLines) p.quoteLines={};
    for(const [side,color] of [["bid","#f23645"],["ask","#26a69a"]]) {
      const price=Number(st[side]); if(!Number.isFinite(price)||price<=0) continue;
      const opts={price,color,lineWidth:1,lineStyle:2,axisLabelVisible:S.layers.quotes,lineVisible:S.layers.quotes,title:side.toUpperCase()};
      if(p.quoteLines[side]) p.quoteLines[side].applyOptions(opts);
      else p.quoteLines[side]=p.series.createPriceLine(opts);
    }
    $(".bid", p.el).textContent = T(st.bid); $(".ask", p.el).textContent = T(st.ask);
    $(".sp", p.el).textContent = st.spread; $(".bs", p.el).style.opacity = st.can_trade ? 1 : 0.45; }
  $("#qBid").textContent = T(st.bid); $("#qAsk").textContent = T(st.ask); $("#qSpread").textContent = `${st.spread} pts`;
  const real = st.route === "REAL"; $("#route").textContent = real ? "Destino: 🔴 REAL TRADING (MT5)" : "Destino: SIMULACIÓN (sin órdenes a MT5)";
  $("#route").classList.toggle("real", real);
  $("#practiceNotice").textContent=st.can_trade?"Las órdenes se programan desde el reloj actual del replay.":"Estás revisando el pasado. Nueva práctica desde aquí reinicia la cuenta virtual y actualiza BID/ASK a esa vela.";
  $("#stopEntryHelp").textContent=`Buy Stop por encima de ASK ${T(st.ask)} · Sell Stop por debajo de BID ${T(st.bid)}. El precio no se cambia automáticamente.`;
  const pendingBox=$("#pendingList");pendingBox.replaceChildren();
  for(const o of st.pending_orders||[]){const row=document.createElement("div"),label=document.createElement("span");
    label.textContent=`#${o.id} ${o.order_type} @ ${T(o.entry)} · ${o.status}${o.reason?" · "+o.reason:""}`;row.append(label);
    if(o.status==="PENDING"){const b=document.createElement("button");b.textContent="Cancelar";b.onclick=()=>act(`/api/pending/${o.id}/cancel`,false);row.append(b);}pendingBox.append(row);}
  $("#bBuy").disabled = $("#bSell").disabled = !st.can_trade; $("#bBuy").title = $("#bSell").title = st.why || "";
  $("#acctLine").textContent = `Balance ${T(st.balance, 2)} ${st.currency} · Equity ${T(st.equity, 2)} · ${st.stats.trades} cerradas · win ${st.stats.win_rate ?? "—"}% · neto ${T(st.stats.net, 2)}`;
  renderPositions(); renderTopdown();
  for (const ev of st.events || []) if (S.seen && ev.t > S.seen) { toast(ev.msg, ev.level); logLine(ev); } else if (!S.seen) logLine(ev);
  if ((st.events || []).length) S.seen = st.events[st.events.length - 1].t;
  const t = tabObj(S.active); if (t && t.symbol !== st.symbol) { t.symbol = st.symbol; saveTabs(); renderTabs(); }
}
function renderPositions() {
  const st = S.state, open = st.trades.filter(t => t.status === "OPEN"), closed = st.trades.filter(t => t.status !== "OPEN").reverse();
  const head = `<tr><th>#</th><th>Lado</th><th>Vol</th><th>Entrada</th><th>SL</th><th>TP</th><th>Hora</th><th>P&L</th><th></th></tr>`;
  $("#tPos").innerHTML = head + (open.map(t => `<tr><td>${t.id}${t.synthetic ? "*" : ""}</td><td class="${t.direction === "BUY" ? "pos" : "neg"}">${t.direction === "BUY" ? "Compra" : "Venta"}</td>
    <td>${t.volume}</td><td>${T(t.entry_price)}</td><td>${T(t.sl)}</td><td>${T(t.tp)}</td><td>${fmtT(t.entry_time)}</td>
    <td class="${t.floating >= 0 ? "pos" : "neg"}">${T(t.floating, 2)}</td><td><button class="small" data-close="${t.id}">Cerrar</button></td></tr>`).join("")
    || `<tr><td colspan="9" class="muted">Sin posiciones abiertas. Usa COMPRAR/VENDER en el gráfico o en Operar.</td></tr>`);
  $("#tHist").innerHTML = `<tr><th>#</th><th>Lado</th><th>Vol</th><th>Entrada</th><th>Salida</th><th>Motivo</th><th>R</th><th>P&L</th></tr>` + closed.map(t =>
    `<tr class="click" data-t="${t.entry_time}" data-p="${t.entry_price}"><td>${t.id}</td><td>${t.direction === "BUY" ? "Compra" : "Venta"}</td><td>${t.volume}</td>
    <td>${T(t.entry_price)}</td><td>${T(t.exit_price)}</td><td>${t.exit_reason}</td><td>${T(t.r, 2)}</td><td class="${t.profit >= 0 ? "pos" : "neg"}">${T(t.profit, 2)}</td></tr>`).join("");
}
function renderTopdown() {
  const st = S.state; if (!st || !st.topdown) return;
  $("#topdown").innerHTML = st.topdown.map(t => `<div class="card"><span class="k ${t.state === "BULLISH" ? "bullish" : t.state === "BEARISH" ? "bearish" : "neutral"}">${t.tf}</span>
    <span class="t"> ${{ BULLISH: "Alcista", BEARISH: "Bajista", RANGING: "Rango", UNKNOWN: "Sin estructura aún" }[t.state] || t.state}</span>
    <p>${t.last_event ? "Último: " + t.last_event : "Sin rupturas confirmadas"}${t.fvg ? " · FVG " + (t.fvg === "bullish" ? "alcista" : "bajista") + " abierto" : ""}</p></div>`).join("");
}

// ================================================================== DIBUJOS
async function loadDrawings() { if (!S.active) return;
  const session=sid(); const allDrawings = await api(`/api/drawings`,{sid:session}); if(session!==sid())return; S.panes.forEach(p => { p.drawings = structuredClone(allDrawings); p.requestDraw(); }); renderObjectList(); }
async function saveDrawing(p, d) { try { await api("/api/drawings", { sid:p.sessionId, method: "POST", body: { id: d.id, kind: d.kind, coordinates: d.coordinates, style: d.style || {} } }); await loadDrawings(); } catch (e) { err(e); await loadDrawings(); } }

// ── Undo stack ─────────────────────────────────────────────────────
const undoStack = [];
const MAX_UNDO = 30;
async function undoLastDrawing() {
  if (!undoStack.length) return;
  const id = undoStack.pop();
  await deleteDrawing(id);
}
async function deleteDrawing(id) { try { await sapi(`/api/drawings/${id}`, { method: "DELETE" }); S.panes.forEach(p => { if (p.selected === id) p.selected = null; }); await loadDrawings(); } catch (e) { err(e); } }
function openCtx(p, id, x, y) {
  const m = $("#ctx"), d = p.drawings.find(z => z.id === id); m.hidden = false; m.style.left = x + "px"; m.style.top = y + "px";
  $("[data-act=color]", m).value = (d.style && d.style.color) || palette().draw; $("[data-act=text]", m).style.display = d.kind === "text" ? "" : "none";
  m.onclick = async (ev) => { const a = ev.target.dataset.act; if (!a || a === "color") return; m.hidden = true;
    if (a === "delete") await deleteDrawing(id);
    if (a === "text") { const s = prompt("Texto:", d.coordinates.text || ""); if (s !== null) { d.coordinates.text = s; await saveDrawing(p, d); } } };
  $("[data-act=color]", m).onchange = async (ev) => { d.style = { ...(d.style || {}), color: ev.target.value }; m.hidden = true; await saveDrawing(p, d); };
}
async function deleteSelected(){
 const selected=[...new Set(S.panes.map(p=>p.selected).filter(id=>id!==null))];
 if(!selected.length)return toast("Selecciona un dibujo o usa Objetos");
 for(const id of selected)await deleteDrawing(id);
}
function renderObjectList(){
 const box=$("#objectList");if(!box)return;box.replaceChildren();
 const drawings=fp()?.drawings||[];
 if(!drawings.length){box.textContent="Sin dibujos guardados";return;}
 for(const d of drawings){const row=document.createElement("div"),label=document.createElement("button"),remove=document.createElement("button");
 label.textContent=`${d.kind} #${d.id}`;label.onclick=()=>{const p=fp();p.selected=d.id;p.requestDraw();if(d.coordinates.t1)p.goto(Date.parse(d.coordinates.t1)/1000,d.coordinates.p1);};
 const edit=document.createElement("button");edit.textContent="Exacto";edit.title="Editar anclas UTC y precio";
 edit.onclick=async()=>{const p=fp(),copy=structuredClone(d);
   for(const key of Object.keys(copy.coordinates).filter(k=>/^[tp]\d+$/.test(k))){
     const value=prompt(`${d.kind} #${d.id} · ${key.startsWith("t")?"Fecha UTC (ISO 8601)":"Precio"} · ancla ${key.slice(1)}`,String(copy.coordinates[key]));
     if(value===null)return;
     if(key.startsWith("t")){const t=Date.parse(value);if(!Number.isFinite(t)||!/(Z|[+-]\d{2}:\d{2})$/.test(value))return toast("Usa fecha ISO con zona UTC: 2026-10-01T12:00:00Z","err");copy.coordinates[key]=isoOf(t/1000);}
     else {const v=Number(value);if(!value.trim()||!Number.isFinite(v)||v<=0)return toast("Precio inválido","err");copy.coordinates[key]=v;}
   }
   await saveDrawing(p,copy);
 };
 label.title=Object.entries(d.coordinates).map(([k,v])=>`${k}: ${v}`).join(" · ");
 remove.textContent="✕";remove.title="Borrar este dibujo";remove.onclick=()=>deleteDrawing(d.id);row.append(label,edit,remove);box.appendChild(row);}
}
function applyLayers(){
 store.set("layers",S.layers);store.set("showSmc",S.showSmc);
 $("#toggleSmc").classList.toggle("on",S.showSmc);
 for(const input of $$("[data-layer]"))input.checked=input.dataset.layer==="smc"?S.showSmc:!!S.layers[input.dataset.layer];
 const names={ema20:"EMA 20",ema50:"EMA 50",macro:"Macro H3",quotes:"BID/ASK",trades:"Operaciones"};
 const visible=Object.keys(names).filter(k=>S.layers[k]).map(k=>names[k]);if(S.showSmc)visible.push("SMC");
 $("#layerStatus").textContent="Visibles en todos los paneles: "+(visible.join(" · ")||"ninguna capa");
 const smcInput=$("[data-layer=smc]");if(smcInput)smcInput.checked=S.showSmc;
 for(const p of S.panes){p.ema20.applyOptions({visible:S.layers.ema20&&p.studiesVisible});p.ema50.applyOptions({visible:S.layers.ema50&&p.studiesVisible});
 for(const line of Object.values(p.quoteLines||{}))line.applyOptions({lineVisible:S.layers.quotes,axisLabelVisible:S.layers.quotes});p.requestDraw();}
}
function setTool(t) { const label=$("#activeTool");if(label)label.textContent="· "+(t||"cursor"); S.tool = t || null; S.toolPts = []; S.toolPane = null;
  $$("#lefttools [data-tool]").forEach(b => b.classList.toggle("active", (b.dataset.tool || null) === S.tool));
  if (t !== "measure") S.panes.forEach(p => { p.measure = null; p.requestDraw(); }); }

// ================================================================== REPLAY
const posToSpeed = (p) => { const lo = Math.log10(MIN_SPEED), hi = Math.log10(MAX_SPEED); return Math.round(10 ** (lo + (hi - lo) * p / 1000) * 100) / 100; };
const speedToPos = (v) => { const lo = Math.log10(MIN_SPEED), hi = Math.log10(MAX_SPEED); return Math.round((Math.log10(v) - lo) / (hi - lo) * 1000); };
function setSpeed(v) { S.speed = Math.min(MAX_SPEED, Math.max(MIN_SPEED, v)); $("#speed").value = speedToPos(S.speed); $("#speedBtn").textContent = `${S.speed}x`; }
async function stepN(n) { if (!S.active) return false;
  try { const r = await sapi(`/api/replay/step?n=${n}`, { method: "POST" }); await refresh(false, n); throttleSide(); return r.moved > 0; } catch (e) { err(e); return false; } }
async function playLoop() {
  while (S.playing) { const iv = Math.max(MIN_INTERVAL, 1000 / S.speed), n = Math.max(1, Math.round(S.speed * iv / 1000)), t0 = performance.now();
    const moved = await stepN(n); if (!moved) { pause(); toast("Replay: fin de los datos"); break; }
    await new Promise(r => setTimeout(r, Math.max(0, iv - (performance.now() - t0)))); }
}
function play() { if (!S.active || S.playing) return; S.playing = true; $("#bPlay").textContent = "⏸"; playLoop(); }
function pause() { S.playing = false; $("#bPlay").textContent = "▶"; }
async function act(path, full = true) { try { await sapi(path, { method: "POST" }); await refresh(full); refreshSide(true); } catch (e) { err(e); } }
async function startAt(t) { pause(); await act(`/api/replay/start_at?t=${encodeURIComponent(t)}`); }

// ================================================================== OPERAR (entrada simulada directa)
function orderParams(dir) { return { direction: dir, use_risk: $("#useRisk").checked, risk_pct: +$("#risk").value, volume: +$("#volume").value,
  sl_mode: $("#slMode").value, sl: +$("#sl").value, tp_mode: $("#tpMode").value, tp: +$("#tp").value, setup: $("#setup").value, note: $("#note").value }; }
function dialog(text, checks = [], okLabel = "Confirmar") {
  return new Promise(res => { $("#dlgText").textContent = text; $("#dlgYes").textContent = okLabel;
    $("#dlgChecks").innerHTML = checks.map((c, i) => `<label><input type="checkbox" data-i="${i}"> ${c}</label>`).join("");
    const yes = $("#dlgYes"); const upd = () => { yes.disabled = $$("#dlgChecks input").some(i => !i.checked); };
    $$("#dlgChecks input").forEach(i => i.onchange = upd); upd();
    const d = $("#dlg"); d.returnValue = ""; d.onclose = () => res(d.returnValue === "yes"); d.showModal(); });
}
const pendingOrders=new Set();
async function sendOrder(dir) {
  if (!S.state || !S.state.can_trade) return toast(S.state ? S.state.why : "Carga datos primero", "err");
  const session=sid();if(pendingOrders.has(session))return;
  const params=orderParams(dir);pendingOrders.add(session);
  try {
    const r = await api("/api/order", {sid:session,method:"POST",body:params});
    if(session!==sid()){toast("Operación registrada en la pestaña de origen");return;}
    if(r.trade)toast(`SIMULADA #${r.trade.id} ${dir==="BUY"?"COMPRA":"VENTA"} · ${r.trade.volume} lotes @ ${T(r.trade.entry_price)}`);
    if (r.real_preview) { const p = r.real_preview;
      if (!p.ok) return toast(`order_check rechazó la orden: ${p.retcode} ${p.comment}`, "err");
      if (!(await dialog(`🔴 ORDEN REAL\n\n${p.direction} ${p.volume} ${p.symbol} @ ${p.price}\nSL ${p.sl}  TP ${p.tp}\nRiesgo ${T(p.risk, 2)} · Objetivo ${T(p.reward, 2)} · Margen ${T(p.margin, 2)}\norder_check: ${p.retcode} (${p.comment})\nCuenta ${p.account} @ ${p.server}\n\n¿Enviar? (caduca en 30 s)`, [], "Enviar orden real"))) return;
      const res = await sapi(`/api/real/send?token=${encodeURIComponent(p.token)}`, { method: "POST" }); toast(`Orden real: retcode ${res.retcode} deal ${res.deal}`, "warning"); }
    $("#note").value = ""; await refresh(false); $("#bottom").classList.remove("collapsed"); await renderJournal();
  } catch (e) { err(e); } finally {pendingOrders.delete(session);}
}
let calcRequest=0;
async function updateCalc() {
  const request=++calcRequest,session=sid();
  const auto=$("#useRisk").checked;$("#volume").disabled=auto;$("#risk").disabled=!auto;
  if (!S.state || !S.state.loaded) return;
  try { const pv = await sapi("/api/order/preview", { method: "POST", body: orderParams($("#calcSide").value) });
    if(request!==calcRequest||session!==sid())return;
    const notice=$("#riskNotice");notice.replaceChildren();
    const text=document.createElement("span");
    if(pv.reason){text.textContent=pv.reason;notice.className="risk-notice blocked";
      const match=pv.reason.match(/volumen mínimo ([\d.]+) \(requiere ([\d.]+)\)/);
      if(match){const min=Number(match[1]),loss=Number(match[2]),pct=100*loss/Number(S.state.balance);
        text.textContent=`Con este SL, el lote mínimo ${min} arriesga aproximadamente ${T(loss,2)} ${pv.currency} (${T(pct,2)} % del balance). Tu límite es ${T(Number(S.state.balance)*Number($("#risk").value)/100,2)} ${pv.currency}.`;
        notice.append(text);const action=document.createElement("button");action.textContent=`Usar ${min} lotes en modo manual`;
        action.onclick=()=>{$("#useRisk").checked=false;$("#volume").value=min;updateCalc();};notice.append(action);
      }else notice.append(text);
    }else{notice.className="risk-notice";text.textContent=auto?`Volumen calculado: ${pv.volume} lotes · pérdida estimada al SL ${T(pv.risk_money,2)} ${pv.currency}.`:`Modo manual: ${pv.volume} lotes · pérdida estimada al SL ${T(pv.risk_money,2)} ${pv.currency}.`;notice.append(text);}
    $("#calc").innerHTML = [["Volumen", pv.volume ?? "N/A"], ["Riesgo", `${T(pv.risk_money, 2)} ${pv.currency}`], [`SL (${$("#calcSide").value==="BUY"?"compra":"venta"})`, T(pv.sl)], ["TP (compra)", T(pv.tp)], ["R:R", pv.rr ? "1:" + pv.rr : "N/A"], ["Margen", "N/A"]]
      .map(([k, v]) => `<span class="muted">${k}</span><b>${v}</b>`).join("") + (pv.reason ? `<span class="neg" style="grid-column:1/3">${pv.reason}</span>` : "");
  } catch(e) {if(request!==calcRequest||session!==sid())return;$("#riskNotice").textContent=e.message;$("#calc").textContent=e.message || "Revisa volumen y niveles de stop";}
}

// ================================================================== APRENDER, DIARIO, ESTADÍSTICAS
const GLOSSARY = [
  ["Estructura de mercado", "Secuencia de máximos y mínimos. Alcista: máximos y mínimos crecientes. Bajista: decrecientes."],
  ["Swing high / low", "Máximo/mínimo con N velas menores a cada lado. Solo se CONFIRMA cuando pasan las N velas de la derecha: hasta entonces no existe."],
  ["BOS", "Break of Structure: cierre más allá del último swing a favor de la tendencia. Confirma continuación."],
  ["CHoCH", "Change of Character: en tendencia, se rompe el swing protegido contrario. Primer aviso de cambio; mejor esperar confirmación."],
  ["Rango (CHoCH fallido)", "Dos CHoCH seguidos en sentidos opuestos sin BOS: no hay tendencia. Se opera en los extremos o se espera la ruptura."],
  ["FVG", "Fair Value Gap: hueco entre la mecha de la vela 1 y la de la vela 3. Zona de desequilibrio que el precio suele rellenar."],
  ["Order Block", "Última vela contraria antes de un impulso que rompe estructura. Posible zona de órdenes institucionales."],
  ["Liquidez (BSL/SSL)", "Stops acumulados sobre máximos (BSL) o bajo mínimos (SSL). EQH/EQL = máximos/mínimos iguales: imán de liquidez."],
  ["Sweep", "El precio supera un nivel de liquidez y vuelve: barrió los stops. Suele preceder al movimiento real."],
  ["R múltiplo", "Resultado dividido por el riesgo inicial. +2R = ganaste el doble de lo que arriesgabas."],
  ["MAE / MFE", "Máxima excursión adversa / favorable: cuánto fue en tu contra y a tu favor la operación. Enseña si tus stops/objetivos están bien puestos."],
  ["Expectancy", "Ganancia media por operación. La media histórica puede ser positiva; necesita costos, muestra suficiente y validación fuera de muestra."],
  ["Look-ahead bias", "Usar información futura sin darse cuenta. El replay filtra por su reloj; cualquier indicador nuevo debe conservar ese límite temporal."],
];
let sideTimer = null;
function throttleSide() { if (sideTimer) return; sideTimer = setTimeout(() => { sideTimer = null; refreshSide(false); }, 900); }
async function refreshSide(force) {
  if (!S.active || !S.state || !S.state.loaded) return;
  const rp = S.rp;
  try {
    if (rp === "learn" || force) {
      const items = await sapi(`/api/learn/explain?tf=${fp().tf}`);
      $("#explain").innerHTML = items.map(i => `<div class="card" data-t="${i.time}" data-p="${i.price}"><span class="k ${i.dir}">${i.kind}</span>
        <span class="t"> ${i.title}</span><p>${i.text}</p>${i.why ? `<div class="why">Motor: ${i.why}</div>` : ""}</div>`).join("")
        || `<p class="muted">Aún no hay estructura confirmada en ${fp().tf}. Avanza velas.</p>`;
      const review=await sapi("/api/learn/review"),box=$("#learningReview"); box.replaceChildren();
      const summary=document.createElement("p");summary.textContent=`${review.closed} cerradas · ${review.missing_lesson} lecciones pendientes`;box.appendChild(summary);
      for(const task of review.tasks){const p=document.createElement("p");p.textContent=task;box.appendChild(p);}
      for(const item of review.by_setup){const p=document.createElement("p");p.textContent=`${item.setup}: n=${item.trades}, media ${item.avg_r??"—"}R${item.trades<30?" · muestra pequeña":" · resultado descriptivo"}`;box.appendChild(p);}
      const costs=document.createElement("small");costs.textContent=`${review.scope}. Costos: ${review.execution.slippage_points} pts; comisión ${review.execution.commission_per_lot}/lote; ${review.execution.ambiguity}.`;box.appendChild(costs);
      const q = await sapi("/api/learn/quiz"); renderQuiz(q);
    }
    if ((rp === "trade" || force)) updateCalc();
    if (!$("#bottom").classList.contains("collapsed") || force) await renderJournal();
  } catch (_) {}
}
function renderQuiz(q) {
  $("#quizStats").innerHTML = [["Retos", q.quiz_total], ["Aciertos", q.quiz_ok], ["Precisión", q.quiz_accuracy === null ? "—" : q.quiz_accuracy + "%"], ["Racha", q.quiz_streak]]
    .map(([k, v]) => `<div class="stat"><span>${k}</span><b>${v}</b></div>`).join("");
  $("#qReveal").disabled = !q.quiz_open; $("#qUp").disabled = $("#qDown").disabled = !!q.quiz_open;
  $("#quizHist").innerHTML = (q.quiz_open ? `<div class="card"><b>Reto abierto:</b> ${q.quiz_open.guess === "UP" ? "▲ SUBE" : "▼ BAJA"} desde ${T(q.quiz_open.price)} en ${q.quiz_open.horizon} velas</div>` : "")
    + [...q.quiz_history].reverse().map(x => `<div class="card" data-t="${x.time}" data-p="${x.price}"><span class="k ${x.correct ? "bullish" : "bearish"}">${x.correct ? "ACIERTO" : "FALLO"}</span>
      <span class="t"> ${x.guess === "UP" ? "▲" : "▼"} ${fmtT(x.time)}</span><p>${T(x.price)} → ${T(x.end_price)} (${x.points > 0 ? "+" : ""}${x.points} pts en ${x.horizon} velas)</p></div>`).join("");
}
async function renderJournal() {
  const j = await sapi("/api/journal");
  $("#journalBox").innerHTML = (j.trades.filter(t => t.status !== "OPEN").map(t => `<div class="card jrow"><span class="k ${t.profit > 0 ? "bullish" : "bearish"}">${t.profit > 0 ? "GANADA" : "PERDIDA"}</span>
    <span class="t"> #${t.id} ${t.direction === "BUY" ? "Compra" : "Venta"} · ${t.setup} · ${T(t.r, 2)}R · ${T(t.profit, 2)} ${j.currency}</span>
    <p>${t.note ? "Idea: " + t.note : "<span class='muted'>Sin nota de entrada</span>"}</p>
    <p class="why">MAE ${t.mae_r ?? "—"}R · MFE ${t.mfe_r ?? "—"}R ${t.mfe_r > 1 && t.r < 0 ? "· ⚠ estuvo +" + t.mfe_r + "R a favor y acabó en pérdida: ¿mover a breakeven / parcial?" : ""}${t.mae_r !== null && t.mae_r > -0.3 && t.r < 0 ? "" : ""}</p>
    <textarea rows="2" data-lesson="${t.id}" placeholder="Lección aprendida (se guarda al salir del campo)">${t.lesson || ""}</textarea></div>`).join("")
    || `<p class="muted">Cierra operaciones para revisarlas aquí. Etiqueta el setup y escribe la idea al entrar.</p>`);
  const st = S.state.stats;
  $("#statsBox").innerHTML = [["Operaciones", st.trades], ["Win rate", (st.win_rate ?? "—") + "%"], ["Neto", T(st.net, 2)], ["Balance", T(S.state.balance, 2)]]
    .map(([k, v]) => `<div class="stat"><span>${k}</span><b>${v}</b></div>`).join("")
    + j.by_setup.map(s => `<div class="stat"><span>${s.setup} · ${s.trades} ops</span><b class="${(s.avg_r || 0) >= 0 ? "pos" : "neg"}">${s.avg_r ?? "—"}R</b><span>win ${s.win_rate}% · ${T(s.net, 2)}</span></div>`).join("");
}
function logLine(ev) { const l = $("#logs"); l.textContent = `${ev.t.slice(11, 19)} ${ev.level.toUpperCase()}  ${ev.msg}\n` + l.textContent; }

// ================================================================== BACKTEST / REAL
let eqChart, eqSeries;
async function runBacktest() {
  const body = { strategy: $("#btStrategy").value, bias_tf: $("#btBias").value, rr: +$("#btRR").value, risk_pct: +$("#btRisk").value, sl_buffer_points: +$("#btBuf").value, initial_balance: +$("#btBal").value,
    spread_mode: $("#btSpread").value, fixed_spread_points: +$("#btFix").value, slippage_points: +$("#btSlip").value, commission_per_lot: +$("#btComm").value,
    ambiguity: $("#btAmb").value, apply_swap: $("#btSwap").checked, use_ticks: $("#btTicks").checked,
    challenge: $("#btChallenge").checked, challenge_goal: +$("#btGoal").value, challenge_days: +$("#btDays").value };
  $("#btRun").disabled = true; $("#btStatus").textContent = "Ejecutando…";
  try { const r = await sapi("/api/backtest", { method: "POST", body });
    const ch = r.challenge;
    $("#btStatus").textContent = `Backtest #${r.id} guardado · ${r.strategy} v${r.strategy_version} · SMC ${r.smc_version}. ${ch ? `Reto: ${ch.goal_reached ? "alcanzado" : "no alcanzado"}; máximo ${ch.max_equity.toFixed(2)} ${r.currency}; ${ch.rejected_orders} órdenes rechazadas. ` : ""}Las operaciones aparecen en el gráfico cuando el reloj llega a ellas (⏭).`;
    const L = { total_trades: "Operaciones", win_rate: "Win rate %", net_profit: "Neto", profit_factor: "Profit factor", expectancy: "Expectancy", average_r: "R medio",
      max_drawdown_pct: "Max DD %", sharpe: "Sharpe", sortino: "Sortino", payoff_ratio: "Payoff", consecutive_losses: "Pérdidas seguidas", avg_mae_r: "MAE (R)",
      avg_mfe_r: "MFE (R)", swap_total: "Swap", swap_status: "Swap estado", ambiguous_fallbacks: "Velas sin ticks", currency: "Moneda" };
    $("#btStats").innerHTML = Object.entries(L).map(([k, l]) => `<tr><td class="muted">${l}</td><td><b>${r.statistics[k] ?? "N/A"}</b></td></tr>`).join("");
    const P = palette();
    if (!eqChart) { eqChart = LWC.createChart($("#eqChart"), { autoSize: true, localization: { locale: "es-ES" }, layout: { background: { type: "solid", color: P.bg }, textColor: P.text, fontSize: 10 },
      grid: { vertLines: { visible: false }, horzLines: { color: P.grid } }, timeScale: { timeVisible: true } });
      eqSeries = eqChart.addAreaSeries({ lineColor: "#2962ff", topColor: "rgba(41,98,255,.25)", bottomColor: "rgba(41,98,255,0)", lineWidth: 2 }); }
    eqSeries.setData(r.equity); eqChart.timeScale().fitContent();
    $("#btTrades").innerHTML = `<tr><th>#</th><th>Lado</th><th>Entrada</th><th>R</th><th>P&L</th></tr>` + r.trades.map(t => `<tr class="click" data-t="${t.entry_time}" data-p="${t.entry_price}">
      <td>${t.id}</td><td>${t.direction === "BUY" ? "Compra" : "Venta"}</td><td>${fmtT(t.entry_time)}</td><td>${T(t.r, 2)}</td><td class="${t.profit > 0 ? "pos" : "neg"}">${T(t.profit, 2)}</td></tr>`).join("");
    await refresh(false);
  } catch (e) { err(e); $("#btStatus").textContent = "Error: " + e.message; } finally { $("#btRun").disabled = false; }
}
async function refreshRealPositions() {
  try { const ps = await sapi("/api/real/positions");
    $("#realPos").innerHTML = `<tr><th>Ticket</th><th>Vol</th><th>Tipo</th><th>Apertura</th><th>Profit</th><th></th></tr>` + (ps.map(p => `<tr><td>${p.ticket}</td><td>${p.volume}</td>
      <td>${p.type === 0 ? "BUY" : "SELL"}</td><td>${p.price_open}</td><td>${T(p.profit, 2)}</td><td><button class="small" data-rclose="${p.ticket}">Cerrar</button></td></tr>`).join("")
      || `<tr><td colspan="6" class="muted">Sin posiciones del sistema (las manuales no se tocan)</td></tr>`); } catch (e) { err(e); }
}

// ================================================================== DIÁLOGO DE CARGA / NUEVA PESTAÑA
let loadForNew = true;
async function openLoad(isNew) {
  loadForNew = isNew; $("#loadTitle").textContent = isNew ? "Nueva pestaña" : "Cambiar datos de esta pestaña";
  const t = !isNew && tabObj(S.active), p = (t && t.params) || {};
  $("#practiceBalance").value = p.initial_balance || 10000;
  $("#practiceSlip").value = p.slippage_points ?? 2;
  $("#practiceComm").value = p.commission_per_lot ?? 0;
  if(isNew) $("#baseTf").value="M1";
  if (p.source) { $("#src").value = p.source; $("#symbol").value = p.symbol || "XAUUSD"; $("#baseTf").value = p.base_tf || "M5"; $("#nbars").value = p.bars || 20000;
    $("#atEnd").checked = !!p.start_at_end; $("#synth").checked = !!p.synthetic; }
  if (!$("#start").value) $("#start").value = new Date(Date.now() - 4 * 86400e3).toISOString().slice(0, 16);
  $("#src").dispatchEvent(new Event("change"));
  $("#loadDlg").showModal();
}
async function submitLoad() {
  const params = { source: $("#src").value, symbol: $("#symbol").value.trim(), base_tf: $("#baseTf").value, bars: +$("#nbars").value, start: $("#start").value || null,
    initial_balance: +$("#practiceBalance").value, slippage_points:+$("#practiceSlip").value, commission_per_lot:+$("#practiceComm").value, start_at_end: $("#atEnd").checked, synthetic: $("#synth").checked, seed: +$("#seed").value, vol: +$("#vol").value, file: $("#file").value || null };
  let id = S.active;
  if (loadForNew || !id) { id = newSid(); S.tabs.push({ sid: id, symbol: params.source === "DEMO" ? "DEMO" : params.symbol, params, layout: derivable("M15",params.base_tf)?"3":"1", tfs: derivable("M15",params.base_tf)?["D1","H4","M15"]:[params.base_tf] }); }
  else Object.assign(tabObj(id), { params, symbol: params.symbol });
  saveTabs(); renderTabs(); toast("Cargando datos…");
  try {
    const tf0 = (tabObj(id).tfs || ["H1"]);
    await api(`/api/load?sid=${id}`, { method: "POST", body: { ...params, chart_tfs: tf0 } });
    S.active = null; await switchTab(id);
  } catch (e) { err(e); }
}

// ================================================================== ARRANQUE
function wire() {
  const workspace=store.get("workspace",{hideTop:false,hideTools:false,hideReplay:false,hideRanges:true,hideJournal:true,hideRail:false});
  function applyWorkspace(){for(const [key,hidden] of Object.entries(workspace))document.body.classList.toggle(key,!!hidden);store.set("workspace",workspace);S.panes.forEach(p=>p.requestDraw());}
  for(const input of $$("[data-workspace]")){const key=input.dataset.workspace;input.checked=!workspace[key];input.onchange=()=>{workspace[key]=!input.checked;applyWorkspace();};}applyWorkspace();
  function maximize(on){document.body.classList.toggle("chart-maximized",on);$("#maximizeChart").textContent=on?"⛶ Restaurar vista":"⛶ Ampliar gráfico";$("#maximizeChart").setAttribute("aria-pressed",String(on));$("#analysisTools").open=false;S.panes.forEach(p=>p.requestDraw());}
  $("#maximizeChart").onclick=()=>maximize(!document.body.classList.contains("chart-maximized"));
  // tema
  document.documentElement.dataset.theme = store.get("theme", "light");
  $("#themeBtn").onclick = () => { const t = theme() === "light" ? "dark" : "light"; document.documentElement.dataset.theme = t; store.set("theme", t);
    S.panes.forEach(p => p.applyTheme()); refresh(true); if (eqChart) { eqChart.remove(); eqChart = null; } };
  // pestañas
  $("#tabs").addEventListener("click", (e) => { const x = e.target.closest("[data-close]"); if (x) { e.stopPropagation(); return closeTab(x.dataset.close); }
    const t = e.target.closest(".tab"); if (t) switchTab(t.dataset.sid); });
  $("#tabs").addEventListener("auxclick", (e) => { const t = e.target.closest(".tab"); if (t && e.button === 1) closeTab(t.dataset.sid); });
  $("#tabAdd").onclick = () => openLoad(true); $("#emptyAdd").onclick = () => openLoad(true); $("#symBtn").onclick = () => openLoad(false);
  $("#watch").addEventListener("click", (e) => { const r = e.target.closest("tr[data-sid]"); if (r) switchTab(r.dataset.sid); });
  $("#loadDlg").addEventListener("close", () => { if ($("#loadDlg").returnValue === "ok") submitLoad(); });
  $("#src").addEventListener("change", async () => { const csv = $("#src").value === "CSV"; $("#fileWrap").hidden = !csv; $("#symWrap").hidden = csv || $("#src").value === "DEMO";
    if (csv) { const f = await api("/api/history"); $("#file").innerHTML = f.map(x => `<option>${x}</option>`).join("") || "<option value=''>(no hay CSV)</option>"; } });
  $("#symbol").addEventListener("input", async (e) => { if (e.target.value.length < 2) return;
    try { const s = await api(`/api/symbols?q=${encodeURIComponent(e.target.value)}`); $("#symbols").innerHTML = s.map(x => `<option value="${x}">`).join(""); } catch (_) {} });
  // temporalidades y distribución
  $("#tfBar").addEventListener("click", (e) => { const b = e.target.closest("[data-tf]"); if (b && !b.disabled) setPaneTf(b.dataset.tf); });
  const dd = (btn, menu) => { $(btn).onclick = (e) => { e.stopPropagation(); $$(".menu.open").forEach(m => m !== $(menu) && m.classList.remove("open")); $(menu).classList.toggle("open"); }; };
  dd("#selBarBtn", "#selBarMenu"); dd("#speedBtn", "#speedMenu");
  document.addEventListener("click", (e) => { if(!e.target.closest("#analysisTools"))$("#analysisTools").open=false; if (!e.target.closest(".menu")) $$(".menu.open").forEach(m => m.classList.remove("open")); if (!e.target.closest("#ctx")) $("#ctx").hidden = true; });
  $("#layoutSelect").onchange=async(e)=>{
    const layout=e.target.value,current=fp()?.tf;fp()?.syncWindow(true);
    $("#analysisTools").open=false;
    buildLayout(layout,layout==="1"&&current?[current]:null);await refresh(true);
  };
  $("#immersiveBtn").onclick=()=>maximize(!document.body.classList.contains("chart-maximized"));
  $("#scalpView").onclick=async()=>{
    if(!S.state?.loaded)return toast("Carga una práctica con base M1");
    if(S.state.base_tf!=="M1"){await openLoad(true);$("#baseTf").value="M1";$("#symbol").value=S.state.symbol==="DEMO"?"XAUUSD":S.state.symbol;toast("Carga base M1 para ver 1m, 5m y 15m reales; la práctica actual se conserva.");return;}
    buildLayout("4",["H3","M15","M5","M1"]);await refresh(true);
  };
  for(const input of $$("[data-layer]")){input.checked=input.dataset.layer==="smc"?S.showSmc:S.layers[input.dataset.layer];
    input.onchange=()=>{if(input.dataset.layer==="smc")S.showSmc=input.checked;else S.layers[input.dataset.layer]=input.checked;applyLayers();};}
  applyLayers();
  $("#removeIndicators").onclick=()=>{S.showSmc=false;S.layers.ema20=false;S.layers.ema50=false;S.layers.macro=false;
    $$("[data-layer]").forEach(input=>input.checked=input.dataset.layer==="smc"?false:S.layers[input.dataset.layer]);applyLayers();};
  $("#deleteSelected").onclick=deleteSelected;
  $("#calcSide").onchange=updateCalc;
  $("#fitBtn").onclick = () => {if(S.linkTime)fp()?.setRange("ALL");else S.panes.forEach(p=>p.chart.timeScale().fitContent());};
  $("#followLatest").onclick=()=>{S.followLatest=!S.followLatest;$("#followLatest").classList.toggle("on",S.followLatest);
    if(S.followLatest){const end=Number(S.state?.clock),span=S.timeWindow?S.timeWindow.to-S.timeWindow.from:7*86400;setCommonWindow(end-span,end);}
  };
  $("#linkTime").checked=S.linkTime;
  $("#linkTime").onchange=()=>{S.linkTime=$("#linkTime").checked;store.set("linkTime",S.linkTime);if(S.linkTime)fp()?.syncWindow(true);};
  $("#strategyView").onclick=async()=>{if(!S.state?.loaded)return toast("Carga una práctica");
    if(!derivable("M15",S.state.base_tf))return toast("Carga datos base M15, M5 o M1 para comparar sin inventar velas","err");
    S.linkTime=true;store.set("linkTime",true);$("#linkTime").checked=true;
    const end=Number(S.state.clock);S.timeWindow={from:end-7*86400,to:end};buildLayout("3",["D1","H4","M15"]);await refresh(true);
  };
  // herramientas
  $$("#lefttools [data-tool]").forEach(b => b.onclick = () => {setTool(b.dataset.tool || null);S.toolColor=b.dataset.color||palette().draw;$("#analysisTools").open=false;$("#activeTool").textContent="· "+b.textContent.trim();});
  for(const [id,key] of [["drawLock","drawLocked"],["drawMagnet","magnet"]]){
    const input=$("#"+id);input.checked=S[key];input.onchange=()=>{S[key]=input.checked;store.set(key,S[key]);};
  }
  $("#toggleDraw").onclick = () => { S.showDraw = !S.showDraw; $("#toggleDraw").classList.toggle("on", !S.showDraw); S.panes.forEach(p => p.requestDraw()); };
  $("#toggleSmc").onclick = () => { S.showSmc = !S.showSmc; applyLayers(); };
  $("#clearDraw").onclick = async () => { const p = fp(); if (!p || !p.drawings.length) return; if (!(await dialog(`¿Borrar los ${p.drawings.length} dibujos de ${p.tf}?`))) return;
    for (const d of p.drawings) await sapi(`/api/drawings/${d.id}`, { method: "DELETE" }); await loadDrawings(); };
  // replay
  $("#bNext").onclick = () => stepN(1); $("#bPrev").onclick = () => act("/api/replay/back?n=1");
  $("#bPlay").onclick = () => S.playing ? pause() : play(); $("#bReset").onclick = () => { pause(); act("/api/replay/reset"); };
  $("#bNextTrade").onclick = () => act("/api/replay/next_trade"); $("#bEnd").onclick = () => { pause(); const s = S.state;
    if (s) act(`/api/replay/jump?t=${encodeURIComponent(isoOf(s.clock + 365 * 86400))}`); };
  $("#selBarMenu").addEventListener("click", async (e) => { const b = e.target.closest("[data-sel]"); if (!b) return; $("#selBarMenu").classList.remove("open"); pause();
    if (b.dataset.sel === "pick") { S.picking = true; S.panes.forEach(p => p.el.classList.add("picking")); toast("Haz clic en la vela donde quieres empezar el replay"); }
    if (b.dataset.sel === "random") act("/api/replay/start_at?random=true");
    if (b.dataset.sel === "date") { const d = prompt("Fecha de inicio (AAAA-MM-DD HH:MM):", fmtT(S.state && S.state.clock)); if (d) startAt(d.replace(" ", "T")); } });
  $("#speed").addEventListener("input", (e) => setSpeed(posToSpeed(+e.target.value)));
  $$("#speedMenu [data-speed]").forEach(b => b.onclick = () => setSpeed(+b.dataset.speed));
  $$("#rangebar [data-range]").forEach(b => b.onclick = () => fp() && fp().setRange(b.dataset.range));
  $("#bGoto").onclick = () => { if ($("#goto").value) act(`/api/replay/jump?t=${encodeURIComponent($("#goto").value)}`); };
  // panel inferior
  $("#bToggle").onclick = () => { $("#bottom").classList.toggle("collapsed"); setTimeout(() => S.panes.forEach(p => p.requestDraw()), 50); refreshSide(true); };
  $$(".btab").forEach(b => b.onclick = () => { $$(".btab").forEach(x => x.classList.toggle("active", x === b)); $$(".bpane").forEach(p => p.classList.toggle("active", p.id === "b-" + b.dataset.b)); });
  $("#tPos").addEventListener("click", async (e) => { const id = e.target.dataset.close; if (id) { try { await sapi(`/api/close?trade_id=${id}`, { method: "POST" }); await refresh(false); await renderJournal(); } catch (er) { err(er); } } });
  $("#bCloseAll").onclick = () => act("/api/close", false);
  const gotoRow = (e) => { const r = e.target.closest("[data-t]"); if (r && fp()) fp().goto(+r.dataset.t, +r.dataset.p); };
  ["#tHist", "#btTrades", "#explain", "#quizHist"].forEach(s => $(s).addEventListener("click", gotoRow));
  $("#journalBox").addEventListener("focusout", async (e) => { const id = e.target.dataset.lesson; if (!id) return;
    try { await sapi(`/api/journal/${id}`, { method: "POST", body: { lesson: e.target.value } }); toast("Lección guardada"); } catch (er) { err(er); } });
  // panel derecho
  const openRp = (rp) => { maximize(false); if (S.rp === "dash" && rp !== "dash" && typeof Dashboard !== "undefined") Dashboard.unmount(); S.rp = rp; store.set("rp", rp); $("#rightpanel").classList.remove("hidden");store.set("panelOpen",true);
    $$("#rail [data-rp]").forEach(b => b.classList.toggle("active", b.dataset.rp === rp)); $$(".rp").forEach(p => p.classList.toggle("active", p.id === "rp-" + rp));
    $("#rtitle").textContent = { watch: "Lista de pestañas", trade: "Operar", learn: "Aprender", bt: "Backtest", real: "Ejecución real", logs: "Registros", set: "Ajustes", dash: "Dashboard" }[rp];
    if (rp === "dash" && typeof Dashboard !== "undefined") setTimeout(() => Dashboard.mount(document.getElementById("rp-dashboard")), 60);
    setTimeout(() => S.panes.forEach(p => p.requestDraw()), 50); refreshSide(true); };
  $$("#rail [data-rp]").forEach(b => b.onclick = () => (S.rp === b.dataset.rp && !$("#rightpanel").classList.contains("hidden")) ? $("#rclose").click() : openRp(b.dataset.rp));
  $("#rclose").onclick = () => { if (typeof Dashboard !== "undefined") Dashboard.unmount(); $("#rightpanel").classList.add("hidden");store.set("panelOpen",false); $$("#rail [data-rp]").forEach(b => b.classList.remove("active")); setTimeout(() => S.panes.forEach(p => p.requestDraw()), 50); };
  $("#dockTrade").onclick=()=>{$("#workspaceControls").open=false;openRp("trade");};
  $("#openTrade").onclick = () => openRp("trade"); $("#openLearn").onclick = () => openRp("learn");
  $$(".lt").forEach(b => b.onclick = () => { $$(".lt").forEach(x => x.classList.toggle("active", x === b)); $$(".lp").forEach(p => p.classList.toggle("active", p.id === "lp-" + b.dataset.l)); });
  $("#glossary").innerHTML = GLOSSARY.map(([k, v]) => `<details><summary>${k}</summary><p>${v}</p></details>`).join("");
  // operar
  $("#practiceHere").onclick=async()=>{pause();if(!await dialog("Nueva práctica en la vela actual: se reiniciarán el balance, las operaciones y las pendientes de esta pestaña.",[],"Reiniciar práctica"))return;await act("/api/replay/practice_here",true);};
  async function sendStop(dir){
    if(!S.state?.can_trade)return toast("Pulsa Nueva práctica desde aquí para operar desde esta vela histórica","err");
    const field=$("#stopEntry"),raw=field.value.trim(),entry=Number(raw);
    if(!raw||!Number.isFinite(entry)||entry<=0){field.setAttribute("aria-invalid","true");field.focus();return toast("Escribe un precio de activación mayor que cero antes de programar la entrada.","err");}
    if((dir==="BUY"&&entry<=Number(S.state.ask))||(dir==="SELL"&&entry>=Number(S.state.bid))){field.setAttribute("aria-invalid","true");field.focus();return toast(dir==="BUY"?`Buy Stop debe estar por encima de ASK ${T(S.state.ask)}.`:`Sell Stop debe estar por debajo de BID ${T(S.state.bid)}.`,"err");}
    field.removeAttribute("aria-invalid");
    const session=sid();if(pendingOrders.has(session))return;pendingOrders.add(session);
    $("#buyStop").disabled=$("#sellStop").disabled=true;
    try{const params={...orderParams(dir),order_type:dir==="BUY"?"BUY_STOP":"SELL_STOP",entry_price:entry};
      const r=await api("/api/order",{sid:session,method:"POST",body:params});toast(`Pendiente simulada #${r.pending_id} guardada`);if(session===sid())await refresh(false);
    }catch(e){err(e);}finally{pendingOrders.delete(session);$("#buyStop").disabled=$("#sellStop").disabled=false;}}
  $("#stopEntry").oninput=()=>$("#stopEntry").removeAttribute("aria-invalid");
  for(const [id,side] of [["stopFromAsk","ask"],["stopFromBid","bid"]])$("#"+id).onclick=()=>{
    if(!S.state?.loaded)return toast("Carga una práctica primero","err");
    const step=Number(S.state.point)||10**(-S.digits),price=Number(S.state[side])+(side==="ask"?step:-step);
    $("#stopEntry").value=price.toFixed(S.digits);$("#stopEntry").removeAttribute("aria-invalid");$("#stopEntry").focus();
  };
  $("#buyStop").onclick=()=>sendStop("BUY");$("#sellStop").onclick=()=>sendStop("SELL");
  $("#bBuy").onclick = () => sendOrder("BUY"); $("#bSell").onclick = () => sendOrder("SELL");
  ["#useRisk", "#risk", "#volume", "#slMode", "#sl", "#tpMode", "#tp"].forEach(s => $(s).addEventListener("change", updateCalc));
  // reto
  $("#qUp").onclick = () => quiz("UP"); $("#qDown").onclick = () => quiz("DOWN");
  $("#qReveal").onclick = async () => { try { const r = await sapi("/api/learn/quiz/reveal", { method: "POST" }); renderQuiz(r);
    if (r.result) toast(`${r.result.correct ? "✅ ACIERTO" : "❌ FALLO"}: ${r.result.points > 0 ? "+" : ""}${r.result.points} pts`, r.result.correct ? "" : "warning"); await refresh(false, r.result ? r.result.horizon : 1); } catch (e) { err(e); } };
  // ajustes SMC
  const checks = [["swings", "Swings"], ["bos", "BOS"], ["choch", "CHoCH"], ["eqh", "EQH"], ["eql", "EQL"], ["bsl", "BSL"], ["ssl", "SSL"], ["fvg", "FVG"], ["order_blocks", "Order Blocks"]];
  $("#smcChecks").innerHTML = checks.map(([k, l]) => `<label><input type="checkbox" data-k="${k}" checked> ${l}</label>`).join("");
  $$("#smcChecks input").forEach(i => i.addEventListener("change", () => { smcOpts(); S.panes.forEach(p => p.requestDraw()); })); smcOpts();
  $("#btnSmc").onclick = async () => { try { await sapi("/api/smc/config", { method: "POST", body: { ...smcParams(), enabled: S.smcOpts } }); await refresh(true); toast("SMC recalculado"); } catch (e) { err(e); } };
  // backtest / real / mt5
  $("#btRun").onclick = runBacktest; $("#btShow").onchange = (e) => { S.showBt = e.target.checked; S.panes.forEach(p => p.requestDraw()); };
  $("#btExport").onclick = async () => { try { const r = await sapi("/api/backtest/export", { method: "POST" }); toast(`Exportado en ${r.folder}`); } catch (e) { err(e); } };
  $("#btnRealPos").onclick = refreshRealPositions;
  $("#realPos").addEventListener("click", async (e) => { const t = e.target.dataset.rclose; if (!t) return; if (!(await dialog(`¿Cerrar la posición ${t}? (solo del sistema)`))) return;
    try { await sapi(`/api/real/close?ticket=${t}`, { method: "POST" }); refreshRealPositions(); } catch (er) { err(er); } });
  $("#btnLive").onclick = async () => { try { const on = !(S.state && S.state.live); await sapi(`/api/live?on=${on}`, { method: "POST" }); await refresh(true); } catch (e) { err(e); } };
  $("#btnAuth").onclick = async () => { const a = S.state && S.state.account; if (!a) return;
    if (!(await dialog(`⚠ OPERACIONES REALES\n\nLas siguientes acciones enviarán órdenes reales a la cuenta conectada de MetaTrader 5.\n\nCuenta: ${a.login}\nServidor: ${a.server}\n\n¿Deseas continuar?`, [], "Continuar"))) return;
    const typed = prompt(`Escribe el número de cuenta (${a.login}) para autorizar:`); if (!typed) return;
    try { await sapi(`/api/real/authorize?login=${encodeURIComponent(typed)}`, { method: "POST" }); toast("Trading REAL autorizado", "warning"); await refresh(false); } catch (e) { err(e); } };
  $("#btnKill").onclick = async () => { try { await sapi("/api/real/kill", { method: "POST" }); toast("Trading real bloqueado", "warning"); await refresh(false); } catch (e) { err(e); } };
  $("#helpBtn").onclick = () => dialog("Atajos de teclado\n\n→ / ←   siguiente / anterior vela\nEspacio   play / pausa\nR   volver al inicio del replay\nAlt+R   ajustar zoom\nEsc   cursor (cancela herramienta)\nSupr   borrar dibujo seleccionado\nB / S   comprar / vender (simulado)\nU / D   reto: sube / baja\nCtrl+T   nueva pestaña · Ctrl+W cerrar pestaña\nCtrl+Tab   siguiente pestaña\n\nRatón: clic en un dibujo para seleccionarlo, arrastra sus puntos, botón derecho para el menú.", [], "Entendido");
  // teclado
  document.addEventListener("keydown", (e) => {
    if(document.activeElement?.isContentEditable || e.repeat) return;
    if (["INPUT", "SELECT", "TEXTAREA"].includes(document.activeElement.tagName) || $("dialog[open]")) return;
    const k = e.key;
    if (k === "ArrowRight") { e.preventDefault(); stepN(1); } else if (k === "ArrowLeft") { e.preventDefault(); $("#bPrev").click(); }
    else if (k === " ") { e.preventDefault(); $("#bPlay").click(); } else if ((k === "r" || k === "R") && e.altKey) { $("#fitBtn").click(); }
    else if (k === "r" || k === "R") $("#bReset").click(); else if (k === "Escape") { $("#analysisTools").open=false; setTool(null); S.picking = false; S.panes.forEach(p => p.el.classList.remove("picking")); }
    else if(k==="Delete" || k==="Backspace"){e.preventDefault();deleteSelected();}
    else if((e.ctrlKey || e.metaKey) && k.toLowerCase()==="z"){e.preventDefault();undoLastDrawing();}
    else if(!e.ctrlKey && !e.metaKey && !e.altKey && (k==="b" || k==="B"))sendOrder("BUY"); else if(!e.ctrlKey && !e.metaKey && !e.altKey && (k==="s" || k==="S"))sendOrder("SELL");
    else if (k === "u" || k === "U") quiz("UP"); else if (k === "d" || k === "D") quiz("DOWN");
    else if (e.ctrlKey && (k === "t" || k === "T")) { e.preventDefault(); openLoad(true); }
    else if (e.ctrlKey && (k === "w" || k === "W") && S.active) { e.preventDefault(); closeTab(S.active); }
    else if (e.ctrlKey && k === "Tab" && S.tabs.length > 1) { e.preventDefault(); const i = S.tabs.findIndex(t => t.sid === S.active); switchTab(S.tabs[(i + 1) % S.tabs.length].sid); }
  });
  // sondeos
  setInterval(pollSessions, 2500);
  setInterval(async () => { try { const s = await api("/api/monitor"); if (S.state) Object.assign(S.state, { mt5: s.mt5, account: s.account }); } catch (_) {} }, 4000);
  setInterval(async () => { if (!S.state || !S.state.live || S.busy) return; try { await sapi("/api/live/tick"); await refresh(false); } catch (e) { err(e); } }, 1000);
  setInterval(() => S.panes.forEach(p => p.requestDraw()), 500);
  setSpeed(1);if(store.get("panelOpen",false))openRp(S.rp);else $("#rclose").click();
  // restaurar pestañas
  renderTabs(); pollSessions();
  if (S.tabs.length) switchTab(tabObj(S.active) ? S.active : S.tabs[0].sid); else openLoad(true);
}
function smcOpts() { const o = {}; $$("#smcChecks input").forEach(i => o[i.dataset.k] = i.checked); S.smcOpts = o; return o; }
function smcParams() { return { swing_left_bars: +$("#swL").value, swing_right_bars: +$("#swR").value, break_confirmation: $("#brk").value,
  liquidity_tolerance_pct: +$("#tol").value, ob_min_displacement: +$("#obd").value, ranging_enabled: $("#rng").value === "true" }; }
async function quiz(g) { try { const r = await sapi(`/api/learn/quiz?guess=${g}&horizon=${$("#qH").value}`, { method: "POST" }); renderQuiz(r);
  toast(`Reto: ${g === "UP" ? "▲ SUBE" : "▼ BAJA"} en ${$("#qH").value} velas. Avanza o pulsa Revelar.`); S.panes.forEach(p => p.requestDraw()); await refresh(false); } catch (e) { err(e); } }
window.addEventListener("DOMContentLoaded", wire);
window.LDZ = S;

