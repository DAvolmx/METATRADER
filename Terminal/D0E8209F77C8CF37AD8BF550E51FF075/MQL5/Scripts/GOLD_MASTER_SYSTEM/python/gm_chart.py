# -*- coding: utf-8 -*-
"""
GOLD MASTER — Gráfico Pro v5
- Temporalidades M1…D1 · zoom/pan · dibujos persistentes (navegador + archivo)
- Capas con ETIQUETAS legibles (a la derecha, sin amontonar):
    Estructura (HH/HL/LH/LL + BOS/CHoCH) · Niveles multi-toque · Canal de regresión
    Fibonacci · FVG · Order Blocks · EMAs · VWAP/POC · Órdenes · DXY (eje propio)
- Panel "Lectura del mercado": tendencia, micro tendencia, último evento, zona, DXY y acción sugerida
- Alertas de precio: crea una línea; al cruzarla aparece aviso en pantalla
"""
import os, json, time
import numpy as np
import pandas as pd
import gm_structure as gs

try:
    import MetaTrader5 as mt5
except ImportError:
    mt5 = None

TFS = {"M1": "TIMEFRAME_M1", "M5": "TIMEFRAME_M5", "M15": "TIMEFRAME_M15", "M30": "TIMEFRAME_M30",
       "H1": "TIMEFRAME_H1", "H4": "TIMEFRAME_H4", "D1": "TIMEFRAME_D1"}
HTF_OF = {"M1": "M15", "M5": "H1", "M15": "H1", "M30": "H4", "H1": "H4", "H4": "D1", "D1": "D1"}
DRAW_BUTTONS = ["drawline", "drawopenpath", "drawclosedpath", "drawcircle", "drawrect", "eraseshape"]
COLORS = ["#ffd740", "#00e5ff", "#ff5252", "#69f0ae", "#e040fb", "#ffffff"]
BULL, BEAR, CHOCH, MUTED = "#42a5f5", "#ef5350", "#ffd740", "#9e9e9e"
OVERLAYS = ["Estructura", "Niveles", "Canal", "Fibo", "FVG", "OB", "EMA", "VWAP", "Perfil", "Órdenes", "DXY"]


def _file(gm_dir, symbol, kind="drawings"):
    return os.path.join(gm_dir, f"{kind}_{symbol}.json")


def _load(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def _save(path, data):
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f)
    except Exception:
        pass


def get_rates(symbol, tf_name, n):
    if mt5 is None:
        return pd.DataFrame()
    r = mt5.copy_rates_from_pos(symbol, getattr(mt5, TFS[tf_name]), 0, n)
    if r is None or len(r) == 0:
        return pd.DataFrame()
    d = pd.DataFrame(r)
    d["time"] = pd.to_datetime(d["time"], unit="s")
    return d.set_index("time")


def find_fvgs(df, n=2):
    out, h, l = [], df.high.values, df.low.values
    atr = (df.high - df.low).rolling(14).mean().values
    nb = ns = 0
    for i in range(len(df) - 1, 2, -1):
        bull, bear = l[i] > h[i - 2], h[i] < l[i - 2]
        if not (bull or bear):
            continue
        lo, hi = (h[i - 2], l[i]) if bull else (h[i], l[i - 2])
        if hi - lo < 0.15 * (atr[i] or 0):
            continue
        fut = df.iloc[i + 1:]
        if (bull and (fut.low <= lo).any()) or (bear and (fut.high >= hi).any()):
            continue
        if bull and nb < n: out.append(("alcista", df.index[i - 1], lo, hi)); nb += 1
        if bear and ns < n: out.append(("bajista", df.index[i - 1], lo, hi)); ns += 1
        if nb >= n and ns >= n:
            break
    return out


def find_obs(df, ev, n=2):
    out, nb, ns = [], 0, 0
    for e in reversed(ev):
        i1 = df.index.get_loc(e["t1"])
        for j in range(i1, max(0, i1 - 30), -1):
            r = df.iloc[j]
            if (e["dir"] > 0 and r.close < r.open) or (e["dir"] < 0 and r.close > r.open):
                fut = df.iloc[i1 + 1:]
                mit = (fut.low < r.low).any() if e["dir"] > 0 else (fut.high > r.high).any()
                if not mit:
                    if e["dir"] > 0 and nb < n: out.append(("compra", df.index[j], r.low, r.high)); nb += 1
                    if e["dir"] < 0 and ns < n: out.append(("venta", df.index[j], r.low, r.high)); ns += 1
                break
        if nb >= n and ns >= n:
            break
    return out


def merge_relayout(shapes, rel):
    if not rel:
        return shapes, False
    if "shapes" in rel:
        return rel["shapes"], True
    changed, shapes = False, [dict(s) for s in shapes]
    for k, v in rel.items():
        if k.startswith("shapes[") and "]." in k:
            idx = int(k[7:k.index("]")]); attr = k[k.index("].") + 2:]
            if idx < len(shapes):
                shapes[idx][attr] = v; changed = True
    return shapes, changed


def register_chart(app, symbol_getter, gm_dir, intel=None):
    from dash import dcc, html, Input, Output, State, ctx, no_update
    import dash_bootstrap_components as dbc
    import plotly.graph_objects as go
    from plotly.subplots import make_subplots

    card = {"background": "#1a1a2e", "border": "1px solid #333"}
    layout = html.Div([
        dbc.Card([
            dbc.CardHeader([
                dbc.Row([
                    dbc.Col(dbc.RadioItems(id="gc-tf", options=[{"label": k, "value": k} for k in TFS], value="M15",
                                           inline=True, className="btn-group btn-group-sm", inputClassName="btn-check",
                                           labelClassName="btn btn-outline-info", labelCheckedClassName="active"), md="auto"),
                    dbc.Col(dcc.Dropdown(id="gc-bars", options=[{"label": f"{x} velas", "value": x} for x in (150, 300, 600, 1200)],
                                         value=300, clearable=False, style={"width": "120px", "color": "#000"}), md="auto"),
                    dbc.Col([dbc.Button("🎨", id="gc-color", size="sm", color="secondary", className="me-1", title="Cambiar color de dibujo"),
                             dbc.Button("🗑 Dibujos", id="gc-clear", size="sm", color="danger", outline=True, className="me-1"),
                             dbc.Button("🏷 Etiquetas", id="gc-labels", size="sm", color="info", outline=True, n_clicks=0,
                                        title="Mostrar/ocultar textos sobre el gráfico")], md="auto"),
                    dbc.Col(dbc.InputGroup([
                        dbc.Input(id="gc-alert-px", type="number", placeholder="Precio alerta", size="sm", style={"width": "120px"}),
                        dbc.Button("🔔 Alerta", id="gc-alert-add", size="sm", color="warning"),
                        dbc.Button("✖", id="gc-alert-clear", size="sm", color="secondary", title="Borrar alertas"),
                    ], size="sm"), md="auto"),
                ], className="g-2 align-items-center mb-1"),
                dcc.Checklist(id="gc-ov", inline=True, options=[{"label": x, "value": x} for x in OVERLAYS],
                              value=["Estructura", "Niveles", "FVG", "OB", "Órdenes", "DXY"],
                              inputStyle={"marginRight": "4px", "marginLeft": "12px"}, style={"fontSize": "13px"}),
            ]),
            dbc.CardBody(dcc.Graph(
                id="gc-graph", style={"height": "680px"},
                config={"scrollZoom": True, "displaylogo": False, "modeBarButtonsToAdd": DRAW_BUTTONS,
                        "modeBarButtonsToRemove": ["lasso2d", "select2d", "autoScale2d"], "edits": {"shapePosition": True}, "doubleClick": "reset+autosize", "responsive": True},
            ), style={"padding": "4px"}),
        ], style=card, className="mb-2"),
        dbc.Row([
            dbc.Col(dbc.Card([dbc.CardHeader("🧭 Lectura del mercado"), dbc.CardBody(html.Div(id="gc-read"))], style=card), md=8),
            dbc.Col(dbc.Card([dbc.CardHeader("💵 DXY · índice del dólar"), dbc.CardBody(html.Div(id="gc-dxy"))], style=card), md=4),
        ], className="mb-2"),
        html.Div(id="gc-toast-wrap", style={"position": "fixed", "top": 20, "right": 20, "zIndex": 2000}),
        dcc.Store(id="gc-shapes", storage_type="local"),
        dcc.Store(id="gc-alerts", storage_type="local"),
        dcc.Store(id="gc-colidx", data=0),
        dcc.Interval(id="gc-tick", interval=3000),
    ])

    # ─── dibujos ───
    @app.callback(Output("gc-shapes", "data"), Input("gc-graph", "relayoutData"), Input("gc-clear", "n_clicks"),
                  State("gc-shapes", "data"))
    def _save_shapes(rel, _, stored):
        sym = symbol_getter(); path = _file(gm_dir, sym)
        if stored is None:
            stored = _load(path, [])
            if ctx.triggered_id is None:
                return stored
        if ctx.triggered_id == "gc-clear":
            _save(path, []); return []
        shapes, changed = merge_relayout(stored or [], rel)
        if not changed:
            return no_update
        _save(path, shapes); return shapes

    @app.callback(Output("gc-colidx", "data"), Input("gc-color", "n_clicks"), State("gc-colidx", "data"), prevent_initial_call=True)
    def _color(_, i):
        return (i + 1) % len(COLORS)

    # ─── alertas ───
    @app.callback(Output("gc-alerts", "data"), Input("gc-alert-add", "n_clicks"), Input("gc-alert-clear", "n_clicks"),
                  State("gc-alert-px", "value"), State("gc-alerts", "data"))
    def _alerts(_a, _c, px, alerts):
        sym = symbol_getter(); path = _file(gm_dir, sym, "alerts")
        alerts = alerts if alerts is not None else _load(path, [])
        if ctx.triggered_id == "gc-alert-clear":
            alerts = []
        elif ctx.triggered_id == "gc-alert-add" and px:
            d = get_rates(sym, "M1", 2)
            side = 1 if (not d.empty and px > d.close.iloc[-1]) else -1
            alerts.append({"px": float(px), "side": side, "done": False})
        _save(path, alerts)
        return alerts

    # ─── gráfico ───
    @app.callback(Output("gc-graph", "figure"), Output("gc-read", "children"), Output("gc-dxy", "children"),
                  Output("gc-toast-wrap", "children"), Output("gc-alerts", "data", allow_duplicate=True),
                  Input("gc-tick", "n_intervals"), Input("gc-tf", "value"), Input("gc-bars", "value"),
                  Input("gc-ov", "value"), Input("gc-shapes", "data"), Input("gc-colidx", "data"),
                  Input("gc-labels", "n_clicks"), Input("gc-alerts", "data"), prevent_initial_call="initial_duplicate")
    def _fig(_, tf, nbars, ov, shapes, colidx, nlab, alerts):
        sym = symbol_getter(); ov = ov or []; labels_on = (nlab or 0) % 2 == 0
        df = get_rates(sym, tf, int(nbars) + 200)
        empty = go.Figure().update_layout(template="plotly_dark", title="Sin datos de MT5")
        if df.empty:
            return empty, "Sin datos", "—", None, no_update
        d = df.iloc[-int(nbars):]
        x0, x1 = d.index[0], d.index[-1]
        step = d.index[-1] - d.index[-2]
        xr = x1 + step * 3           # columna de etiquetas a la derecha
        px = float(d.close.iloc[-1])
        dxy_on = "DXY" in ov and intel is not None
        rows = 3 if dxy_on else 2
        fig = make_subplots(rows=rows, cols=1, shared_xaxes=True, vertical_spacing=0.02,
                            row_heights=[0.68, 0.14, 0.18] if dxy_on else [0.82, 0.18])
        fig.add_trace(go.Candlestick(x=d.index, open=d.open, high=d.high, low=d.low, close=d.close, name=sym,
                                     increasing_line_color="#26a69a", decreasing_line_color="#ef5350",
                                     increasing_fillcolor="#26a69a", decreasing_fillcolor="#ef5350"), 1, 1)
        ann = []

        def label(y, text, color, x=None, size=10):
            if labels_on:
                ann.append(dict(x=x or xr, y=y, xref="x", yref="y", text=text, showarrow=False, xanchor="left",
                                font=dict(color=color, size=size), bgcolor="rgba(13,13,26,0.75)", borderpad=2))

        def hseg(xa, xb, y, color, name, dash="dot", width=1):
            fig.add_trace(go.Scatter(x=[xa, xb], y=[y, y], mode="lines", showlegend=False, name=name,
                                     line=dict(color=color, width=width, dash=dash),
                                     hovertemplate=f"{name}: %{{y:.2f}}<extra></extra>"), 1, 1)

        def box(t0, lo, hi, fill, name):
            fig.add_trace(go.Scatter(x=[t0, x1, x1, t0, t0], y=[lo, lo, hi, hi, lo], fill="toself", mode="lines",
                                     fillcolor=fill, line=dict(width=0), showlegend=False, name=name,
                                     hovertemplate=f"{name}<br>%{{y:.2f}}<extra></extra>"), 1, 1)

        sw = gs.swings(d, 3); ev, trend = gs.events(d, sw, 3)

        if "EMA" in ov:
            for span, c in ((21, "#42a5f5"), (50, "#ffa726"), (200, "#ab47bc")):
                e = df.close.ewm(span=span).mean().loc[d.index]
                fig.add_trace(go.Scatter(x=d.index, y=e, name=f"EMA{span}", line=dict(color=c, width=1)), 1, 1)
                label(e.iloc[-1], f"EMA{span}", c, size=9)
        if "Canal" in ov:
            ch = gs.regression_channel(d, min(120, len(d)))
            c = BULL if ch["dir"] > 0 else BEAR if ch["dir"] < 0 else MUTED
            for key, dash in (("up", "dash"), ("mid", "dot"), ("lo", "dash")):
                fig.add_trace(go.Scatter(x=ch["t"], y=ch[key], mode="lines", showlegend=False, hoverinfo="skip",
                                         line=dict(color=c, width=1, dash=dash)), 1, 1)
            label(ch["up"][-1], f"Canal {'alcista' if ch['dir']>0 else 'bajista' if ch['dir']<0 else 'lateral'} ({ch['slope_pct']:+.2f}%)", c)
        if "Fibo" in ov:
            fb = gs.fibonacci(sw, trend)
            if fb:
                for f, y in fb["levels"].items():
                    col = CHOCH if f in (0.618, 0.705, 0.786) else MUTED
                    hseg(fb["t0"], x1, y, col, f"Fib {f*100:.1f}%", "dot")
                    label(y, f"Fib {f*100:.1f}%" + ("  ← OTE" if f == 0.705 else ""), col, size=9)
        if "FVG" in ov:
            for typ, t0, lo, hi in find_fvgs(d):
                box(t0, lo, hi, "rgba(38,166,154,0.16)" if typ == "alcista" else "rgba(239,83,80,0.16)", f"FVG {typ}")
                label((lo + hi) / 2, f"FVG {typ}", BULL if typ == "alcista" else BEAR, size=9)
        if "OB" in ov:
            for typ, t0, lo, hi in find_obs(d, ev):
                box(t0, lo, hi, "rgba(66,165,245,0.20)" if typ == "compra" else "rgba(171,71,188,0.20)", f"OB {typ}")
                label((lo + hi) / 2, f"OB {typ} {(lo+hi)/2:.2f}", BULL if typ == "compra" else "#ce93d8", size=9)
        if "Niveles" in ov:
            big = get_rates(sym, "H4", 400)
            if not big.empty:
                lv = sorted(gs.levels(big, 2, 0.3, 3), key=lambda l: abs(l["p"] - px))[:6]
                for l in lv:
                    res = l["p"] > px; c = "#e57373" if res else "#81c784"
                    hseg(x0, x1, l["p"], c, f"{'Resistencia' if res else 'Soporte'} ×{l['n']}", "solid", 2 if l["n"] >= 4 else 1)
                    label(l["p"], f"{'R' if res else 'S'} ×{l['n']}  {l['p']:.2f}", c)
        if "Estructura" in ov:
            for s in sw[-14:]:
                if not s["label"]:
                    continue
                c = BULL if s["label"] in ("HH", "HL") else BEAR
                if labels_on:
                    ann.append(dict(x=s["t"], y=s["p"], text=s["label"], showarrow=False, font=dict(color=c, size=9),
                                    yshift=10 if s["high"] else -10, xref="x", yref="y"))
            for e in ev[-6:]:
                c = CHOCH if e["choch"] else (BULL if e["dir"] > 0 else BEAR)
                name = ("CHoCH" if e["choch"] else "BOS") + (" ↑" if e["dir"] > 0 else " ↓")
                fig.add_trace(go.Scatter(x=[e["t0"], e["t1"]], y=[e["p"], e["p"]], mode="lines", showlegend=False,
                                         line=dict(color=c, width=2 if e["choch"] else 1, dash="solid" if e["choch"] else "dash"),
                                         hovertemplate=f"{name} %{{y:.2f}}<extra></extra>"), 1, 1)
                if labels_on:
                    ann.append(dict(x=e["t0"] + (e["t1"] - e["t0"]) / 2, y=e["p"], text=name, showarrow=False,
                                    font=dict(color=c, size=10), yshift=9 if e["dir"] > 0 else -9, xref="x", yref="y"))
        st = (getattr(intel, "snapshot", None) or {}) if intel else {}
        if "VWAP" in ov and st.get("vwap"):
            hseg(x0, x1, st["vwap"], "#ffeb3b", "VWAP", "solid"); label(st["vwap"], "VWAP", "#ffeb3b")
        if "Perfil" in ov and st.get("poc"):
            for k, c in (("poc", "#ffd740"), ("vah", "#69f0ae"), ("val", "#ff8a80")):
                hseg(x0, x1, st[k], c, k.upper()); label(st[k], k.upper(), c, size=9)
        if "Órdenes" in ov and mt5 is not None:
            for p in (mt5.positions_get(symbol=sym) or []):
                c = "#26a69a" if p.type == 0 else "#ef5350"
                hseg(x0, x1, p.price_open, c, f"#{p.ticket}", "solid", 2)
                label(p.price_open, f"{'BUY' if p.type == 0 else 'SELL'} {p.volume} · {p.profit:+.2f}$", c)
                if p.sl: hseg(x0, x1, p.sl, "#ef5350", "SL"); label(p.sl, f"SL #{p.ticket}", "#ef5350", size=9)
                if p.tp: hseg(x0, x1, p.tp, "#26a69a", "TP"); label(p.tp, f"TP #{p.ticket}", "#26a69a", size=9)
            for o in (mt5.orders_get(symbol=sym) or []):
                hseg(x0, x1, o.price_open, "#90a4ae", "Pendiente", "dash"); label(o.price_open, f"Pend #{o.ticket}", "#90a4ae", size=9)
        # alertas
        toast, alerts_out, changed = None, list(alerts or []), False
        for a in alerts_out:
            hseg(x0, x1, a["px"], "#ff9800", "Alerta", "longdash"); label(a["px"], f"🔔 {a['px']:.2f}", "#ff9800")
            if not a.get("done") and ((a["side"] > 0 and d.high.iloc[-1] >= a["px"]) or (a["side"] < 0 and d.low.iloc[-1] <= a["px"])):
                a["done"], changed = True, True
                toast = dbc.Toast(f"{sym} tocó {a['px']:.2f}", header="🔔 Alerta de precio", icon="warning",
                                  duration=15000, is_open=True, dismissable=True)
        alerts_out = [a for a in alerts_out if not a.get("done")]
        # volumen
        vcol = np.where(d.close >= d.open, "rgba(38,166,154,0.6)", "rgba(239,83,80,0.6)")
        fig.add_trace(go.Bar(x=d.index, y=d.tick_volume, marker_color=vcol, showlegend=False, name="Vol"), 2, 1)
        # DXY
        dx = {}
        if dxy_on:
            dser = intel.dxy.series(tf if tf in ("M5", "M15", "M30", "H1", "H4", "D1") else "M15", int(nbars) + 50)
            if dser is not None and len(dser):
                if getattr(dser.index, "tz", None) is not None:          # Yahoo devuelve hora de NY con zona → quitarla
                    dser.index = dser.index.tz_convert("UTC").tz_localize(None)
                dser = dser[dser.index >= pd.Timestamp(x0)]
                fig.add_trace(go.Scatter(x=dser.index, y=dser.values, name="DXY", line=dict(color="#80cbc4", width=1.5),
                                         hovertemplate="DXY %{y:.3f}<extra></extra>"), 3, 1)
                fig.update_yaxes(title_text="DXY", row=3, col=1)
            try:
                dx = intel.dxy.summary(get_rates(sym, "H1", 300).close)
            except Exception:
                dx = {}
        fig.update_xaxes(rangebreaks=[dict(bounds=["sat", "mon"])], rangeslider_visible=False, showspikes=True,
                         spikemode="across", spikethickness=1, spikecolor="#888", spikesnap="cursor", gridcolor="#1f2937")
        # El rango inicial sólo se fija al cambiar de temporalidad / nº de velas. En los refrescos
        # automáticos NO se toca: así el zoom y el desplazamiento del usuario se conservan (uirevision).
        if ctx.triggered_id in (None, "gc-tf", "gc-bars"):
            fig.update_xaxes(range=[x0, x1 + step * 18], row=1, col=1)
        fig.update_yaxes(showspikes=True, spikemode="across", spikethickness=1, spikecolor="#888",
                         gridcolor="#1f2937", side="right")
        fig.update_layout(template="plotly_dark", paper_bgcolor="#0d0d1a", plot_bgcolor="#0d0d1a",
                          margin=dict(l=10, r=60, t=34, b=10), dragmode="pan", hovermode="x unified",
                          legend=dict(orientation="h", y=1.04, x=0, font=dict(size=10)),
                          title=dict(text=f"{sym} · {tf} · {px:.2f}", x=0.5, font=dict(size=13)),
                          shapes=shapes or [], annotations=ann,
                          newshape=dict(line=dict(color=COLORS[colidx or 0], width=2), fillcolor="rgba(255,215,64,0.12)"),
                          uirevision=f"{sym}-{tf}-{nbars}")
        # lectura del mercado
        htf = get_rates(sym, HTF_OF[tf], 400)
        rd = gs.read_market(htf if not htf.empty else d, d, dx or st)
        colr = "#00e676" if rd["score"] >= 3 else "#ff5252" if rd["score"] <= -3 else "#ffd740"
        name = {1: "ALCISTA", -1: "BAJISTA", 0: "RANGO"}
        read = [html.H5(rd["accion"], style={"color": colr}),
                html.Div(f"Tendencia {HTF_OF[tf]}: {name[rd['htf']]} · Micro {tf}: {name[rd['ltf']]} · Último: {rd['last']} · Zona: {rd['zona']}",
                         className="small mb-1"),
                html.Ul([html.Li(r_, className="small") for r_ in rd["razones"]], className="mb-0"),
                html.Div(f"Puntuación de alineación: {rd['score']:+d}  (≥ +3 compras · ≤ −3 ventas)", className="small text-muted")]
        if dx.get("dxy"):
            b = dx["dxy_bias"]
            dxy_card = [html.H3(f"{dx['dxy']:.3f}", style={"color": "#ef5350" if dx["dxy_chg24"] > 0 else "#26a69a"}),
                        html.Div(f"Δ 24h: {dx['dxy_chg24']:+.2f}%"),
                        html.Div(f"Dólar: {'FUERTE ↑' if dx['dxy_trend'] > 0 else 'DÉBIL ↓' if dx['dxy_trend'] < 0 else 'neutro'}"),
                        html.Div(f"Correlación con {sym} (60h): {dx['dxy_corr']:+.2f}"),
                        html.Div("Efecto en el oro: " + ("favorece COMPRAS" if b > 0 else "favorece VENTAS" if b < 0 else "sin influencia clara"),
                                 style={"color": "#00e676" if b > 0 else "#ff5252" if b < 0 else "#ffd740", "fontWeight": "bold"}),
                        html.Div(f"Fuente: {dx['dxy_mode']}", className="small text-muted")]
        else:
            dxy_card = html.Div("DXY no disponible: activa EURUSD, USDJPY y GBPUSD en Observación del mercado, o instala yfinance.",
                                className="small text-muted")
        return fig, read, dxy_card, toast, (alerts_out if changed else no_update)

    return layout
