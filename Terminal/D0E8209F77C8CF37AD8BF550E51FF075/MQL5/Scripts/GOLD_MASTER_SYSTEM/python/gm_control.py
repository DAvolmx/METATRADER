"""
gm_control.py — CENTRO DE CONTROL del dashboard
  · Modo AUTÓNOMO ON/OFF: con ON los EAs abren operaciones solos; con OFF sólo gestionan (no abren nada)
  · Trading manual desde la web: lote, COMPRA / VENTA a mercado con SL estructural automático (ATR M15, mín. 8 $)
    y TP 2R; cerrar todas las posiciones del oro; posiciones abiertas en vivo
  · Estado de todo el sistema (MT5 conectado, trading algorítmico, servicio, monitor micro, DXY en vivo)
Los clics del usuario son los que envían órdenes: este módulo nunca opera por su cuenta.
"""
import os, json, time
import numpy as np
import MetaTrader5 as mt5
from gm_intel import GM_DIR, override_on

AUTO_FILE = os.path.join(GM_DIR, "autonomous.json")
def auto_on():
    try:
        with open(AUTO_FILE) as f: return bool(json.load(f).get("on"))
    except Exception: return False
def set_auto(on):
    with open(AUTO_FILE, "w") as f: json.dump({"on": bool(on), "ts": int(time.time())}, f)

def _filling(sym):
    fm = mt5.symbol_info(sym).filling_mode
    return mt5.ORDER_FILLING_FOK if fm & 1 else (mt5.ORDER_FILLING_IOC if fm & 2 else mt5.ORDER_FILLING_RETURN)

def market_order(sym, side, lot, rr=2.0, min_sl=8.0):
    info = mt5.symbol_info(sym); tick = mt5.symbol_info_tick(sym)
    if info is None or tick is None: return "Sin conexión con MT5"
    r = mt5.copy_rates_from_pos(sym, mt5.TIMEFRAME_M15, 1, 30)
    atr = float(np.mean(r["high"] - r["low"])) if r is not None and len(r) else min_sl
    dist = max(min_sl, 1.5*atr)
    price = tick.ask if side == "BUY" else tick.bid; d = 1 if side == "BUY" else -1
    lot = max(info.volume_min, round(round(lot/info.volume_step)*info.volume_step, 2))
    req = dict(action=mt5.TRADE_ACTION_DEAL, symbol=sym, volume=lot, type=mt5.ORDER_TYPE_BUY if d > 0 else mt5.ORDER_TYPE_SELL,
               price=price, sl=round(price - d*dist, info.digits), tp=round(price + d*dist*rr, info.digits),
               deviation=50, magic=0, comment="GM dashboard", type_filling=_filling(sym), type_time=mt5.ORDER_TIME_GTC)
    res = mt5.order_send(req)
    if res is None: return f"Error: {mt5.last_error()}"
    if res.retcode != mt5.TRADE_RETCODE_DONE: return f"Rechazada ({res.retcode}): {res.comment}"
    return f"✔ {side} {lot} @ {res.price:.2f} · SL {req['sl']:.2f} · TP {req['tp']:.2f}"

def close_all(sym_like="XAU"):
    n = 0
    for p in mt5.positions_get() or []:
        if sym_like not in p.symbol: continue
        t = mt5.symbol_info_tick(p.symbol); buy = p.type == 0
        r = mt5.order_send(dict(action=mt5.TRADE_ACTION_DEAL, symbol=p.symbol, volume=p.volume, position=p.ticket,
                                type=mt5.ORDER_TYPE_SELL if buy else mt5.ORDER_TYPE_BUY, price=t.bid if buy else t.ask,
                                deviation=50, magic=0, comment="GM close", type_filling=_filling(p.symbol)))
        n += r is not None and r.retcode == mt5.TRADE_RETCODE_DONE
    return f"Cerradas {n} posiciones"

def register(app, symbol_getter):
    from dash import dcc, html, Input, Output, State, ctx, no_update
    import dash_bootstrap_components as dbc
    card = {"background": "#13132a", "border": "1px solid #2e2e55"}
    layout = dbc.Card([
        dbc.CardHeader(html.Div([html.B("🎛 CENTRO DE CONTROL"), html.Span(id="gc2-status", className="ms-3 small")])),
        dbc.CardBody(dbc.Row([
            dbc.Col([
                dbc.Button("🤖 MODO AUTÓNOMO: OFF", id="gc2-auto", color="secondary", className="w-100 mb-2", n_clicks=0),
                html.Div("ON: los EAs abren y gestionan operaciones solos. OFF: sólo gestionan las abiertas.", className="small text-muted"),
            ], md=3),
            dbc.Col([
                dbc.InputGroup([dbc.InputGroupText("Lote"), dbc.Input(id="gc2-lot", type="number", value=0.1, step=0.1, min=0.01)], size="sm", className="mb-2"),
                dbc.ButtonGroup([dbc.Button("▲ COMPRAR", id="gc2-buy", color="success"), dbc.Button("▼ VENDER", id="gc2-sell", color="danger"),
                                 dbc.Button("✖ Cerrar oro", id="gc2-close", color="warning", outline=True)], className="w-100"),
                html.Div("SL automático (1,5 ATR M15, mín. 8 $) y TP 2R. El Guardian gestiona BE y trailing.", className="small text-muted mt-1"),
                html.Div(id="gc2-ack", className="small mt-1"),
            ], md=4),
            dbc.Col(html.Div(id="gc2-pos", style={"maxHeight": "120px", "overflowY": "auto", "fontSize": "12px"}), md=5),
        ])),
        dcc.Interval(id="gc2-tick", interval=2000),
        dcc.ConfirmDialog(id="gc2-confirm", message="¿Activar el MODO AUTÓNOMO? Los EAs abrirán operaciones reales con tu dinero sin pedir confirmación."),
    ], style=card, className="mb-2")

    @app.callback(Output("gc2-confirm", "displayed"), Input("gc2-auto", "n_clicks"), prevent_initial_call=True)
    def _ask(n):
        if auto_on(): set_auto(False); return False      # apagar no necesita confirmación
        return True

    @app.callback(Output("gc2-auto", "children"), Output("gc2-auto", "color"), Output("gc2-status", "children"), Output("gc2-pos", "children"),
                  Input("gc2-tick", "n_intervals"), Input("gc2-confirm", "submit_n_clicks"), Input("gc2-auto", "n_clicks"))
    def _state(_, ok, __):
        if ctx.triggered_id == "gc2-confirm" and ok: set_auto(True)
        on = auto_on(); ti = mt5.terminal_info()
        hb = "?"
        try:
            with open(os.path.join(GM_DIR, "service_heartbeat.txt")) as f: hb = int(time.time() - json.load(f)["ts"])
        except Exception: pass
        try:
            with open(os.path.join(GM_DIR, "micro.json")) as f: mic = json.load(f)
        except Exception: mic = {}
        dot = lambda okk: "🟢" if okk else "🔴"
        status = (f"{dot(ti is not None)} MT5  {dot(ti is not None and ti.trade_allowed)} Algo-trading  "
                  f"{dot(isinstance(hb, int) and hb < 60)} Servicio ({hb}s)  {dot(time.time() - mic.get('micro_ts', 0) < 10)} Micro  "
                  f"DXY {mic.get('dxy_live', '—')} (z60 {mic.get('dxy_z60', 0)})  {'🔓 SIN FILTROS' if override_on() else ''}")
        rows = []
        for p in mt5.positions_get() or []:
            if "XAU" not in p.symbol: continue
            rows.append(html.Div(f"{'▲' if p.type == 0 else '▼'} {p.symbol} {p.volume} @ {p.price_open:.2f} · SL {p.sl or '—'} · TP {p.tp or '—'} · "
                                 f"{p.profit:+.2f} $", style={"color": "#00e676" if p.profit >= 0 else "#ff5252"}))
        return ("🤖 MODO AUTÓNOMO: ON" if on else "🤖 MODO AUTÓNOMO: OFF"), ("success" if on else "secondary"), status, rows or "Sin posiciones abiertas"

    @app.callback(Output("gc2-ack", "children"), Input("gc2-buy", "n_clicks"), Input("gc2-sell", "n_clicks"),
                  Input("gc2-close", "n_clicks"), State("gc2-lot", "value"), prevent_initial_call=True)
    def _trade(b, s, c, lot):
        sym = symbol_getter()
        if ctx.triggered_id == "gc2-close": return close_all()
        return market_order(sym, "BUY" if ctx.triggered_id == "gc2-buy" else "SELL", float(lot or 0.1))
    return layout
