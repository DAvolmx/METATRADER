"""
gm_live_api.py — Servicio puente que CONECTA todo el sistema para el workstation web.

Une en un solo API JSON lo que ya produce el sistema:
  * MetaTrader5 (si está, solo Windows): cuenta, posiciones, cotización y DOM
    (MarketBookGet) — "lo más cercano al libro de órdenes".
  * Ficheros del puente en Common\\Files\\GoldMaster\\ que escriben gm_intel/gm_micro/
    gm_bridge: intel.txt (flujo/COT/sentimiento), micro.json (DXY, OFI), ea_state.txt,
    news_calendar.csv.
  * gm_forecast: pronóstico de las 2 velas H4 (lee el report cacheado).

Diseño a prueba de fallos: si MT5 no está, cae a los ficheros; si no hay ficheros,
devuelve estado "offline" con mensaje claro — nunca inventa datos de cuenta.

Arrancar en tu PC (con el venv del terminal):
    uvicorn gm_live_api:app --port 8777
El workstation hace fetch de /api/snapshot cada segundo y rellena los paneles.
"""
from __future__ import annotations

import csv
import json
import os
import time
from pathlib import Path

from fastapi import Body, FastAPI
from fastapi.middleware.cors import CORSMiddleware

try:
    from gm_guardian import GuardianConfig, Journal, RiskGovernor, learn_from_journal
    _GOV = RiskGovernor(GuardianConfig(symbol=os.getenv("GM_SYMBOL", "XAUUSD")))
    _JOURNAL = Journal()
    HAS_GUARDIAN = True
except Exception:
    HAS_GUARDIAN = False

# --- MT5 opcional (solo Windows) ---
try:
    import MetaTrader5 as mt5  # type: ignore
    HAS_MT5 = True
except Exception:
    mt5 = None
    HAS_MT5 = False

SYMBOL = os.getenv("GM_SYMBOL", "XAUUSD")


def _bridge_dir() -> Path:
    env = os.getenv("GM_BRIDGE_DIR")
    if env:
        return Path(env)
    # Ruta típica del sandbox común de MT5 en Windows; en Linux usa GM_BRIDGE_DIR.
    appdata = os.getenv("APPDATA")
    if appdata:
        return Path(appdata) / "MetaQuotes" / "Terminal" / "Common" / "Files" / "GoldMaster"
    return Path.cwd() / "GoldMaster"


def _read_kv(path: Path) -> dict:
    out = {}
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    except Exception:
        pass
    return out


def _read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _mt5_ready() -> bool:
    if not HAS_MT5:
        return False
    try:
        return bool(mt5.initialize())
    except Exception:
        return False


# ───────────────────────── API ─────────────────────────
app = FastAPI(title="GOLD MASTER Live API", version="1.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


@app.get("/api/status")
def status():
    d = _bridge_dir()
    return {"mt5": _mt5_ready(), "bridge_dir": str(d), "bridge_exists": d.exists(),
            "symbol": SYMBOL, "ts": int(time.time())}


@app.get("/api/account")
def account():
    if _mt5_ready():
        a = mt5.account_info()
        if a:
            return {"source": "mt5", "balance": a.balance, "equity": a.equity,
                    "margin_free": a.margin_free, "profit": a.profit, "currency": a.currency,
                    "leverage": a.leverage}
    st = _read_kv(_bridge_dir() / "ea_state.txt")
    if st:
        return {"source": "bridge", "equity": float(st.get("equity", 0) or 0),
                "status": st.get("status"), "positions": int(st.get("positions", 0) or 0)}
    return {"source": "offline", "message": "Sin MT5 ni ea_state.txt. Arranca MT5 y el EA/bridge."}


@app.get("/api/positions")
def positions():
    if _mt5_ready():
        ps = mt5.positions_get(symbol=SYMBOL) or []
        return {"source": "mt5", "positions": [
            {"ticket": p.ticket, "side": "BUY" if p.type == 0 else "SELL", "volume": p.volume,
             "price_open": p.price_open, "price_current": p.price_current, "sl": p.sl, "tp": p.tp,
             "profit": p.profit} for p in ps]}
    return {"source": "offline", "positions": []}


@app.get("/api/quote")
def quote():
    if _mt5_ready():
        t = mt5.symbol_info_tick(SYMBOL)
        if t:
            return {"source": "mt5", "bid": t.bid, "ask": t.ask, "last": t.last, "ts": t.time}
    return {"source": "offline"}


@app.get("/api/dom")
def dom():
    """Profundidad de mercado (MarketBookGet) — el DOM/heatmap del workstation."""
    if _mt5_ready():
        try:
            mt5.market_book_add(SYMBOL)
            book = mt5.market_book_get(SYMBOL) or []
            levels = [{"type": "ask" if b.type == 1 else "bid", "price": b.price, "volume": b.volume}
                      for b in book]
            if levels:
                return {"source": "mt5", "levels": levels}
        except Exception:
            pass
    return {"source": "offline", "levels": [],
            "note": "El broker no publica DOM o MT5 no está. En oro CFD suele no haber libro nivel-2."}


@app.get("/api/flow")
def flow():
    """Métricas de flujo (CVD/VPIN/delta/VWAP/DXY) desde intel.txt + micro.json."""
    intel = _read_kv(_bridge_dir() / "intel.txt")
    micro = _read_json(_bridge_dir() / "micro.json")
    if not intel and not micro:
        return {"source": "offline", "message": "Sin intel.txt/micro.json. Arranca gm_intel/gm_micro."}
    g = lambda k, d=None: intel.get(k, d)
    return {"source": "bridge",
            "cvd": g("delta_z"), "vpin": g("vpin"), "vwap": g("vwap"), "poc": g("poc"),
            "vah": g("vah"), "val": g("val"), "hurst": g("hurst"), "composite": g("composite"),
            "dxy": g("dxy"), "dxy_corr": g("dxy_corr"), "dxy_bias": g("dxy_bias"),
            "dxy_shock": g("dxy_shock"), "micro_bias": g("micro_bias"),
            "micro": {k: micro.get(k) for k in ("ofi", "tick_speed", "beta", "leadlag") if k in micro}}


@app.get("/api/news")
def news():
    path = _bridge_dir() / "news_calendar.csv"
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            rows = list(csv.DictReader(f))[:20]
    except Exception:
        pass
    if not rows:
        return {"source": "offline", "events": [], "message": "Sin news_calendar.csv (gm_intel lo genera)."}
    return {"source": "bridge", "events": rows}


@app.get("/api/forecast")
def forecast():
    """Pronóstico de 2 velas H4 (report cacheado por gm_forecast)."""
    here = Path(__file__).resolve().parent
    for p in (here.parent / "offline" / "out_offline" / "forecast.json",):
        if p.exists():
            return {"source": "cache", **_read_json(p)}
    return {"source": "offline", "message": "Ejecuta: python gm_forecast.py <datos> para generar el pronóstico."}


@app.get("/api/snapshot")
def snapshot():
    """Todo junto, para que el workstation haga un solo fetch por segundo."""
    return {"ts": int(time.time()), "status": status(), "account": account(),
            "positions": positions()["positions"], "quote": quote(), "dom": dom(),
            "flow": flow(), "forecast_available": (Path(__file__).resolve().parent.parent
            / "offline" / "out_offline" / "forecast.json").exists()}


@app.post("/api/guardian/evaluate")
def guardian_evaluate(payload: dict = Body(...)):
    """Pre-trade: decide si se puede operar y con qué lote. body: {equity, stop_distance, ctx}."""
    if not HAS_GUARDIAN:
        return {"allow": False, "reason": "guardian no disponible"}
    return _GOV.evaluate(float(payload.get("equity", 0)), float(payload.get("stop_distance", 0)),
                         payload.get("ctx") or {})


@app.post("/api/journal")
def journal_record(trade: dict = Body(...)):
    """Registra una operación con su contexto y actualiza los contadores del día."""
    if not HAS_GUARDIAN:
        return {"ok": False, "reason": "guardian no disponible"}
    rec = _JOURNAL.record(trade)
    if "pnl_usd" in trade:
        _GOV.register_result(float(trade["pnl_usd"]))
    return {"ok": True, "trade": rec, "stats": _JOURNAL.stats()}


@app.get("/api/journal")
def journal_stats():
    if not HAS_GUARDIAN:
        return {"n": 0}
    return _JOURNAL.stats()


@app.get("/api/guardian/learn")
def guardian_learn():
    """Entrena un modelo con TUS operaciones del diario (investigación)."""
    if not HAS_GUARDIAN:
        return {"trained": False, "reason": "guardian no disponible"}
    return learn_from_journal(_JOURNAL)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=int(os.getenv("GM_LIVE_PORT", "8777")))
