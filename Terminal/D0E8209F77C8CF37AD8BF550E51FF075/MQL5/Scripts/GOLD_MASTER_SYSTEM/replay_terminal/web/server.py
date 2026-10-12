"""
web/server.py — API FastAPI + interfaz web con TradingView Lightweight Charts.

Arranque:   .venv\\Scripts\\python.exe -m web            (o web.bat)
Abre:       http://127.0.0.1:8000

Escucha SOLO en 127.0.0.1. Operaciones virtuales; ejecución real deshabilitada.
"""
from __future__ import annotations

import asyncio
import logging
import json
import time
from urllib.parse import urlsplit
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal, Optional

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, ConfigDict
from starlette.middleware.trustedhost import TrustedHostMiddleware

from web.service import ServiceError, TradingService
from web.dashboard_api import register_dashboard
from web.research_api import register_research

STATIC = Path(__file__).parent / "static"
log = logging.getLogger("ldz.web")

TF = Literal["M1", "M2", "M3", "M5", "M10", "M15", "M30", "H1", "H3", "H4", "D1", "W1", "MN1"]
SID = Query("default", min_length=1, max_length=40, pattern=r"^[A-Za-z0-9_-]+$",
            description="Pestaña (sesión) sobre la que actúa la petición")


class RequestModel(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False, extra="forbid")


class LoadReq(RequestModel):
    slippage_points: float = Field(2, ge=0, le=100000)
    commission_per_lot: float = Field(0, ge=0, le=100000)
    initial_balance: float = Field(10000, gt=0, le=1_000_000_000)
    source: Literal["MT5", "CSV", "DEMO"] = "MT5"
    symbol: str = "XAUUSD"
    base_tf: Literal["M1", "M5", "M15"] = "M5"
    bars: int = Field(20000, ge=500, le=500_000)
    start: Optional[str] = None
    start_at_end: bool = False
    synthetic: bool = False
    seed: int = 0
    vol: float = Field(1.0, gt=0, le=5)
    file: Optional[str] = None
    chart_tfs: list[TF] = ["H4", "H1", "M15", "M5"]


class OrderReq(RequestModel):
    order_type: Literal["MARKET","BUY_STOP","SELL_STOP"] = "MARKET"
    entry_price: Optional[float] = Field(None, gt=0)
    direction: Literal["BUY", "SELL"]
    use_risk: bool = True
    risk_pct: float = Field(1.0, gt=0, le=10)
    volume: float = Field(0.01, gt=0)
    sl_mode: Literal["PRICE", "POINTS", "PERCENT", "ATR", "STRUCTURE"] = "POINTS"
    sl: float = 0
    tp_mode: Literal["R:R", "PRICE", "NONE"] = "R:R"
    tp: float = 2.0
    setup: str = ""          # etiqueta para el diario (BOS+FVG, OB, Sweep…)
    note: str = ""


class BacktestReq(RequestModel):
    strategy: Literal["SMC_FVG", "SMC_QUALITY", "GM_MACRO"] = "SMC_FVG"
    bias_tf: TF = "H1"
    rr: float = Field(2.0, gt=0)
    risk_pct: float = Field(1.0, gt=0, le=10)
    sl_buffer_points: float = Field(20, ge=0)
    initial_balance: float = Field(10_000, gt=0)
    spread_mode: Literal["HISTORICAL", "FIXED"] = "HISTORICAL"
    fixed_spread_points: int = Field(0, ge=0)
    slippage_points: float = Field(0, ge=0)
    commission_per_lot: float = Field(0, ge=0)
    ambiguity: Literal["WORST_CASE", "OPTIMISTIC", "CONSERVATIVE", "TICK_DATA"] = "WORST_CASE"
    apply_swap: bool = True
    use_ticks: bool = False
    challenge: bool = False
    challenge_goal: float = Field(100, gt=0)
    challenge_days: float = Field(3, gt=0, le=30)


class DrawingReq(RequestModel):
    id: Optional[int] = None
    timeframe: Optional[TF] = None
    kind: Literal["hline", "vline", "trend", "rect", "fib", "channel", "text", "ray", "extended", "long", "short", "arrow"]
    coordinates: dict
    style: dict = {}


def create_app(service: Optional[TradingService] = None) -> FastAPI:
    svc_holder = {"svc": service}

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if svc_holder["svc"] is None:
            svc_holder["svc"] = TradingService()
            try:
                svc_holder["svc"].run(svc_holder["svc"].connect)
            except Exception as e:
                log.warning(f"MT5 no conectado al arrancar: {e}")
        yield
        svc_holder["svc"].shutdown()

    app = FastAPI(title="GOLD MASTER · Research & Replay", version="0.5.0", lifespan=lifespan)
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost", "[::1]"] + (["testserver"] if service is not None else []))

    @app.middleware("http")
    async def local_origin(request: Request, call_next):
        origin = request.headers.get("origin")
        if request.headers.get("sec-fetch-site") == "cross-site":
            return JSONResponse({"detail": "Origen externo bloqueado"}, status_code=403)
        if origin and urlsplit(origin).netloc != request.headers.get("host"):
            return JSONResponse({"detail": "Origen externo bloqueado"}, status_code=403)
        return await call_next(request)

    @app.get("/api/analytics")
    async def analytics():
        path = STATIC.parents[2] / "python" / "runtime" / "market_snapshot.json"
        try:
            snapshot = json.loads(path.read_text(encoding="utf-8"))
            age = time.time() - float(snapshot.get("ts", 0))
            snapshot["snapshot_age_s"] = round(age, 1)
            snapshot["snapshot_fresh"] = -2 <= age <= 10
            snapshot["execution"] = "disabled"
            return snapshot
        except (OSError, ValueError, TypeError):
            return {"status": "service_unavailable", "snapshot_fresh": False, "assets": {}, "execution": "disabled"}

    @app.exception_handler(ServiceError)
    async def _svc_err(_: Request, exc: ServiceError):
        return JSONResponse(status_code=400, content={"detail": str(exc)})

    def S() -> TradingService:
        return svc_holder["svc"]

    async def call(fn, *a, **kw):
        """Ejecuta en el hilo único del núcleo sin bloquear el bucle async (sesión 'default')."""
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, lambda: S().run(fn, *a, **kw))

    async def scall(sid: str, fn, *a, **kw):
        """Igual que call, pero con la pestaña `sid` como sesión activa."""
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, lambda: S().run(S().in_session, sid, fn, *a, **kw))

    # ---------------------------------------------------------------- estado / MT5
    @app.get("/api/status")
    async def status():
        return await call(S().status)

    @app.post("/api/connect")
    async def connect(terminal_path: Optional[str] = None):
        return await call(S().connect, terminal_path)

    @app.get("/api/monitor")
    async def monitor():
        return await call(S().monitor)

    @app.get("/api/symbols")
    async def symbols(q: str = ""):
        return await call(S().symbols, q)

    @app.get("/api/history")
    async def history():
        return await call(S().history_files)

    # ---------------------------------------------------------------- sesión / replay
    @app.post("/api/load")
    async def load(req: LoadReq, sid: str = SID):
        return await scall(sid, S().load, req.model_dump())

    @app.get("/api/state")
    async def state(sid: str = SID):
        return await scall(sid, S().session_state)

    @app.post("/api/replay/step")
    async def step(n: int = 1, sid: str = SID):
        return await scall(sid, S().step, n)

    @app.post("/api/replay/back")
    async def back(n: int = 1, sid: str = SID):
        return await scall(sid, S().back, n)

    @app.post("/api/replay/reset")
    async def reset(sid: str = SID):
        return await scall(sid, S().reset)

    @app.post("/api/replay/jump")
    async def jump(t: str, sid: str = SID):
        return await scall(sid, S().jump, t)

    @app.post("/api/replay/next_trade")
    async def next_trade(sid: str = SID):
        return await scall(sid, S().next_trade)

    @app.get("/api/bars")
    async def bars(tf: TF, limit: int = 1500, sid: str = SID):
        return await scall(sid, S().bars, tf, limit)

    @app.get("/api/frame")
    async def frame(tfs: str = "H4,H1,M15,M5", limit: int = 1500, smc: bool = True, sid: str = SID):
        lst = [t for t in tfs.split(",") if t in ("M1", "M2", "M3", "M5", "M10", "M15", "M30", "H1", "H3", "H4", "D1", "W1", "MN1")]
        return await scall(sid, S().frame, lst, max(2, min(limit, 5000)), smc)

    @app.get("/api/smc")
    async def smc(tf: TF, sid: str = SID):
        return await scall(sid, S().smc, tf)

    @app.post("/api/smc/config")
    async def smc_config(cfg: dict, sid: str = SID):
        return await scall(sid, S().set_smc_config, cfg)

    # ---------------------------------------------------------------- operaciones
    @app.post("/api/order/preview")
    async def order_preview(req: OrderReq, sid: str = SID):
        return await scall(sid, S().compute_order, req.direction, req.model_dump())

    @app.post("/api/order")
    async def order(req: OrderReq, sid: str = SID):
        return await scall(sid, (S().pending_stop if req.order_type!="MARKET" else S().order), req.direction, req.model_dump())

    @app.post("/api/pending/{order_id}/cancel")
    async def cancel_pending(order_id: int, sid: str = SID):
        return await scall(sid, S().cancel_pending, order_id)

    @app.post("/api/replay/practice_here")
    async def practice_here(sid: str = SID):
        return await scall(sid, S().practice_here)

    @app.post("/api/close")
    async def close(trade_id: Optional[int] = None, sid: str = SID):
        return await scall(sid, S().close, trade_id)

    # ---------------------------------------------------------------- real
    @app.post("/api/real/authorize")
    async def authorize(login: str, sid: str = SID):
        return await scall(sid, S().authorize, login)

    @app.post("/api/real/kill")
    async def kill(sid: str = SID):
        return await scall(sid, S().kill)

    @app.post("/api/real/send")
    async def send(token: str, sid: str = SID):
        return await scall(sid, S().send_real, token)

    @app.get("/api/real/positions")
    async def positions(sid: str = SID):
        return await scall(sid, S().real_positions)

    @app.post("/api/real/close")
    async def close_real(ticket: int, sid: str = SID):
        return await scall(sid, S().close_real, ticket)

    # ---------------------------------------------------------------- live
    @app.post("/api/live")
    async def live(on: bool, sid: str = SID):
        return await scall(sid, S().set_live, on)

    @app.get("/api/live/tick")
    async def live_tick(sid: str = SID):
        return await scall(sid, S().live_tick)

    # ---------------------------------------------------------------- backtest
    @app.post("/api/backtest")
    async def backtest(req: BacktestReq, sid: str = SID):
        loop = asyncio.get_running_loop()
        svc = S()
        # prepare/store usan in_session dentro de run; el cálculo puro va en su propio hilo
        return await loop.run_in_executor(None, lambda: svc.backtest(req.model_dump(), sid))

    @app.get("/api/backtest/visible")
    async def bt_visible(sid: str = SID):
        return await scall(sid, S().backtest_trades_visible)

    @app.post("/api/backtest/export")
    async def bt_export(sid: str = SID):
        return {"folder": await scall(sid, S().export_backtest)}

    # ---------------------------------------------------------------- dibujos
    @app.get("/api/drawings")
    async def drawings(tf: Optional[TF] = None, sid: str = SID):
        return await scall(sid, S().drawings, tf)

    @app.post("/api/drawings")
    async def save_drawing(req: DrawingReq, sid: str = SID):
        return await scall(sid, S().save_drawing, req.model_dump())

    @app.delete("/api/drawings/{did}")
    async def delete_drawing(did: int, sid: str = SID):
        return await scall(sid, S().delete_drawing, did)

    # ---------------------------------------------------------------- pestañas
    @app.get("/api/sessions")
    async def sessions():
        return await call(S().list_sessions)

    @app.delete("/api/sessions/{tab}")
    async def close_session(tab: str):
        return await call(S().close_session, tab)

    # ---------------------------------------------------------------- aprendizaje
    @app.get("/api/learn/review")
    async def learning_review(sid: str = SID):
        return await scall(sid, S().learning_review)

    @app.get("/api/learn/explain")
    async def explain(tf: TF, sid: str = SID):
        return await scall(sid, S().explain, tf)

    @app.post("/api/learn/quiz")
    async def quiz(guess: Literal["UP", "DOWN"], horizon: int = Query(12, ge=1, le=500), sid: str = SID):
        return await scall(sid, S().quiz_start, guess, horizon)

    @app.post("/api/learn/quiz/reveal")
    async def quiz_reveal(sid: str = SID):
        return await scall(sid, S().quiz_reveal)

    @app.get("/api/learn/quiz")
    async def quiz_stats(sid: str = SID):
        return await scall(sid, S().quiz_stats)

    @app.post("/api/replay/start_at")
    async def start_at(t: Optional[str] = None, random: bool = False, sid: str = SID):
        return await scall(sid, S().start_at, t, random)

    @app.get("/api/journal")
    async def journal(sid: str = SID):
        return await scall(sid, S().journal_list)

    @app.post("/api/journal/{trade_id}")
    async def journal_update(trade_id: int, body: dict, sid: str = SID):
        return await scall(sid, S().journal_update, trade_id, body.get("lesson", ""), body.get("note"),
                           body.get("setup"))

    # ---------------------------------------------------------------- web
    app.mount("/static", StaticFiles(directory=STATIC), name="static")

    @app.get("/")
    async def index():
        return FileResponse(STATIC / "index.html")

    register_dashboard(app, svc_holder)
    register_research(app)
    return app
