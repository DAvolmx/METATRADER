"""
web/service.py — TradingService: el "controlador" de la versión web.

Reutiliza EXACTAMENTE los mismos motores que la app de escritorio
(ReplayEngine, SMCEngine, PaperTradingEngine, BacktestEngine,
LiveExecutionEngine, mercado sintético). No contiene lógica de trading propia.

Hilos:
  * Todas las operaciones que tocan MT5 o el estado de la sesión se ejecutan
    en UN único hilo (self.run): la librería MetaTrader5 no es thread-safe y
    así el estado nunca se modifica desde dos peticiones a la vez.
  * El backtest (cálculo puro, sin MT5) corre en otro hilo para no bloquear.

Seguridad (igual que en escritorio):
  * Por defecto todas las órdenes son SIMULADAS.
  * Real solo en LIVE, con MT5 conectado y tras autorizar escribiendo el número
    de cuenta. Cada orden real: preview (order_check) -> token -> send.
  * En REPLAY/SYNTHETIC es imposible autorizar el trading real.
"""
from __future__ import annotations

import logging
import secrets
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Optional

import numpy as np
import pandas as pd

from core.app_state import AppMode, AppState
from core.models import TIMEFRAME_SECONDS, bars_from_df, epoch_s, is_derivable
from data.aggregator import BarAggregator
from data.data_manager import DataManager, validate_bars
from mt5.connector import ConnectionState, MT5Connector
from replay.replay_engine import ReplayEngine
from smc.smc_engine import SMC_ENGINE_VERSION, SMCConfig, SMCEngine
from storage.database import Database
from strategies.smc_fvg import SMCFVGStrategy
from strategies.smc_quality import SMCQualityStrategy
from strategies.macro_liquidity import MacroLiquidityStrategy
from trading.backtest_engine import BacktestConfig, BacktestEngine
from trading.paper_engine import PaperConfig, PaperTradingEngine
from trading.position_sizer import size_by_risk
from trading.risk_manager import atr, stop_from, take_profit_rr, validate_stops
from trading.statistics import drawdown_series
from trading.trade_models import SymbolSpec, Trade

log = logging.getLogger("ldz.web")
ROOT = Path(__file__).parent.parent
HISTORY_DIR = ROOT / "data" / "history"
CHART_TFS_DEFAULT = ["H4", "H1", "M15", "M5"]


class ServiceError(Exception):
    """Error de negocio: se devuelve al navegador como 400 con el mensaje."""


def ts(t) -> int:
    return int(pd.Timestamp(t).timestamp())


def trade_dict(t: Trade, floating: Optional[float] = None) -> dict:
    return {
        "id": t.id, "direction": t.direction, "volume": t.volume,
        "entry_time": ts(t.entry_time) if t.entry_time else None, "entry_price": t.entry_price,
        "sl": t.stop_loss, "tp": t.take_profit,
        "exit_time": ts(t.exit_time) if t.exit_time else None, "exit_price": t.exit_price,
        "exit_reason": t.exit_reason, "profit": t.profit, "floating": floating,
        "r": t.r_multiple, "swap": t.swap, "commission": t.commission, "status": t.status,
        "outcome": t.outcome, "synthetic": t.synthetic, "comment": t.comment,
    }


class Session:
    """Estado de UNA pestaña: símbolo, replay, motores SMC, operaciones simuladas, backtest…"""

    def __init__(self, sid: str) -> None:
        self.sid = sid
        self.spec: Optional[SymbolSpec] = None
        self.replay: Optional[ReplayEngine] = None
        self.engines: dict[str, SMCEngine] = {}
        self.aggs: dict[str, BarAggregator] = {}
        self.fed_idx = 0
        self.paper: Optional[PaperTradingEngine] = None
        self.paper_idx = 0
        self.smc_cfg = SMCConfig.load()
        self.chart_tfs = list(CHART_TFS_DEFAULT)
        self.bt_result = None
        self.live = False
        self.source = None
        self.session_id = 0            # cambia en cada carga: el navegador recarga todo
        self.quiz: list[dict] = []     # retos de predicción (modo aprendizaje)
        self.quiz_open: Optional[dict] = None
        self.journal: dict[int, dict] = {}   # id operación -> {setup, note, lesson}
        self.load_params: dict = {}


SESSION_ATTRS = ("spec", "replay", "engines", "aggs", "fed_idx", "paper", "paper_idx", "smc_cfg", "chart_tfs",
                 "bt_result", "live", "source", "session_id", "quiz", "quiz_open", "load_params", "journal")


class TradingService:
    def __init__(self, db_path: Optional[Path] = None, mt5_enabled: bool = True) -> None:
        self._exec = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ldz-core")
        self._compute = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ldz-bt")
        self.state = AppState()
        self.state.mode = AppMode.REPLAY
        self.db_path = db_path
        self.db: Optional[Database] = None
        self.mt5_enabled = mt5_enabled
        self.connector = MT5Connector()
        self.live_exec = None
        self.sessions: dict[str, Session] = {}
        self._cur: Session = self._session("default")
        self._previews: dict[str, Any] = {}
        self.events: list[dict] = []       # avisos para el navegador (cierres de SL/TP, etc.)
        self.run(self._init_db)

    # ------------------------------------------------------------------ pestañas
    def _session(self, sid: str) -> "Session":
        if sid not in self.sessions:
            if len(self.sessions) >= 20:
                raise ServiceError("Máximo 20 pestañas abiertas")
            self.sessions[sid] = Session(sid)
        return self.sessions[sid]

    def in_session(self, sid: str, fn: Callable, *a, **kw):
        """Ejecuta fn con la pestaña `sid` como sesión activa (siempre en el hilo núcleo)."""
        prev = self._cur
        previous_mode = self.state.mode
        self._cur = self._session(sid or "default")
        self.state.mode = AppMode.LIVE if self._cur.live else (AppMode.SYNTHETIC if self._cur.replay and self._cur.replay.in_synthetic_zone else AppMode.REPLAY)
        try:
            return fn(*a, **kw)
        finally:
            self._cur = prev
            self.state.mode = previous_mode

    def list_sessions(self) -> list[dict]:
        out = []
        for sid, ss in self.sessions.items():
            if ss.replay is None:
                out.append({"sid": sid, "loaded": False})
                continue
            bars = ss.replay.visible_base_bars()
            last = bars[-1].close if bars else None
            day_ago = ss.replay.current_time - timedelta(days=1)
            ref = next((b.close for b in reversed(bars) if b.time <= day_ago), bars[0].open if bars else None)
            out.append({"sid": sid, "loaded": True, "symbol": ss.spec.symbol, "base_tf": ss.replay.base_tf,
                        "price": last, "change_pct": round((last / ref - 1) * 100, 2) if (last and ref) else None,
                        "digits": ss.spec.digits, "live": ss.live, "synthetic_zone": ss.replay.in_synthetic_zone,
                        "params": ss.load_params})
        return out

    def close_session(self, sid: str) -> dict:
        ss = self.sessions.get(sid)
        if ss is None:
            raise ServiceError("Pestaña inexistente")
        if ss.live and self.state.real_trading_enabled:
            self.in_session(sid, self.kill)
        del self.sessions[sid]
        return {"closed": sid}

    # ------------------------------------------------------------------ hilos
    def run(self, fn: Callable, *a, **kw):
        """Ejecuta fn en el hilo único del núcleo y devuelve su resultado."""
        return self._exec.submit(fn, *a, **kw).result()

    def _init_db(self) -> None:
        self.db = Database(self.db_path) if self.db_path else Database()

    def shutdown(self) -> None:
        def _close():
            try:
                self.connector.disconnect()
            finally:
                if self.db:
                    self.db.close()
        self.run(_close)
        self._exec.shutdown(wait=False)
        self._compute.shutdown(wait=False)

    def _notify(self, level: str, msg: str) -> None:
        self.events.append({"t": datetime.now(timezone.utc).isoformat(), "level": level, "msg": msg})
        self.events = self.events[-200:]
        getattr(log, "warning" if level == "warning" else "info")(msg)

    # ------------------------------------------------------------------ MT5
    def connect(self, terminal_path: Optional[str] = None) -> dict:
        if not self.mt5_enabled:
            raise ServiceError("MT5 desactivado en este servidor")
        st, acc = (self.connector.connect_with_path(terminal_path) if terminal_path
                   else self.connector.connect())
        if st == ConnectionState.CONNECTED and acc:
            self.db.save_account(acc.login, acc.server, acc.currency, acc.leverage, acc.trade_mode)
            if self.live_exec is None:
                from mt5.execution import LiveExecutionEngine
                import json
                cfg = json.loads((ROOT / "config" / "settings.json").read_text(encoding="utf-8"))
                self.live_exec = LiveExecutionEngine(self.state, int(cfg.get("magic_number", 260901)),
                                                     cfg.get("comment", "LDZ_TRADING_TERMINAL"), db=self.db)
        return self.status()

    def monitor(self) -> dict:
        """Llamado periódicamente por el navegador: detecta desconexión y cambio de cuenta."""
        if self.connector.account is None:
            return self.status()
        prev = self.connector.account
        st, acc = self.connector.ping()
        if st == ConnectionState.ACCOUNT_CHANGED:
            if self.live_exec:
                self.live_exec.kill_switch()
            self.state.unlock_trading()
            self._set_mode(AppMode.LIVE if self.live else self.state.mode)
            self._notify("warning", f"CAMBIO DE CUENTA DETECTADO: {prev.login}@{prev.server} -> "
                                    f"{acc.login}@{acc.server}. Trading real bloqueado: vuelve a autorizar.")
        elif st == ConnectionState.DISCONNECTED:
            self.state.lock_trading()
            s2, _ = self.connector.connect()
            if s2 == ConnectionState.CONNECTED:
                self.state.unlock_trading()
            else:
                self._notify("warning", "MT5 desconectado: RECONNECTING… (LIVE TRADING = LOCKED)")
        return self.status()

    def status(self) -> dict:
        acc = self.connector.account
        return {
            "mt5": self.connector.state.name,
            "account": None if acc is None else {
                "login": acc.login, "server": acc.server, "balance": acc.balance, "equity": acc.equity,
                "currency": acc.currency, "leverage": acc.leverage, "demo": acc.is_demo},
            "mode": self.state.mode.name,
            "real_enabled": self.state.real_trading_enabled,
            "can_send_real": self._real_route(),
            "live": self.live,
            "smc_version": SMC_ENGINE_VERSION,
            "loaded": self.replay is not None,
        }

    def symbols(self, q: str = "") -> list[str]:
        if self.connector.state != ConnectionState.CONNECTED:
            return []
        from mt5.market_data import list_symbols
        return list_symbols(q)[:300]

    def history_files(self) -> list[str]:
        return sorted(p.name for p in HISTORY_DIR.glob("*.csv")) if HISTORY_DIR.exists() else []

    # ------------------------------------------------------------------ carga
    def load(self, p: dict) -> dict:
        self.live = False
        self.load_params = {k: p.get(k) for k in ("source", "symbol", "base_tf", "bars", "start", "start_at_end",
                                                  "synthetic", "seed", "vol", "file")}
        source = p.get("source", "MT5")
        base = p.get("base_tf", "M5")
        symbol = p.get("symbol", "XAUUSD")
        if source == "CSV":
            from mt5.market_data import load_history
            path = HISTORY_DIR / Path(p["file"]).name          # nunca rutas arbitrarias
            if not path.exists():
                raise ServiceError(f"No existe {path.name}")
            raw, spec_d = load_history(path)
            df, rep = validate_bars(raw, base)
        elif source == "DEMO":
            from web.demo_data import demo_history                 # datos de demostración (no reales)
            df, rep = validate_bars(demo_history(base), base)
            spec_d = {"symbol": "DEMO", "digits": 2, "point": 0.01, "contract_size": 100.0,
                      "profit_currency": "USD", "account_currency": "USD"}
        else:
            if self.connector.state != ConnectionState.CONNECTED and self.mt5_enabled:
                self.connector.connect()
            online = self.connector.state == ConnectionState.CONNECTED
            df, rep = DataManager(self.db).get_bars(symbol, base, int(p.get("bars", 20000)), use_mt5=online)
            if online:
                from mt5.market_data import get_symbol_spec, save_history
                spec_d = get_symbol_spec(symbol)
                self.db.save_symbol_spec(spec_d)
                save_history(df, spec_d, HISTORY_DIR, base)
            else:
                spec_d = self.db.load_symbol_spec(symbol)
        if spec_d:
            self.spec = SymbolSpec.from_dict(spec_d)
        else:
            from simulation.synthetic_market import infer_digits
            d = infer_digits(df[["open", "high", "low", "close"]].to_numpy().ravel())
            self.spec = SymbolSpec(symbol, d, 10 ** -d)
        self.source = source

        synth = None
        if p.get("synthetic"):
            from simulation.synthetic_market import MarketCalibration, SimConfig, SyntheticMarket
            seed = int(p.get("seed") or 0) or int(datetime.now().timestamp())
            synth = SyntheticMarket(MarketCalibration(df, base, block_size=30),
                                    SimConfig(timeframe=base, vol_multiplier=float(p.get("vol", 1.0)),
                                              seed=seed, digits=self.spec.digits))
            self._notify("info", f"Mercado sintético activo (semilla {seed}): al acabar los datos el replay "
                                 "continúa con velas NO reales")
        tfs = [tf for tf in p.get("chart_tfs", self.chart_tfs) if is_derivable(tf, base)]
        self.chart_tfs = tfs
        start = None
        if not p.get("start_at_end") and p.get("start"):
            start = pd.Timestamp(p["start"], tz="UTC") if pd.Timestamp(p["start"]).tzinfo is None \
                else pd.Timestamp(p["start"]).tz_convert("UTC")
            start = start.to_pydatetime()
        all_tfs = sorted({t for t in set(tfs + [base] + ["W1", "D1", "H4", "H1", "M15"]) if is_derivable(t, base)},
                         key=lambda t: TIMEFRAME_SECONDS[t])
        self.replay = ReplayEngine(df, base, tuple(all_tfs), start, synthetic_market=synth)
        if p.get("start_at_end"):
            self.replay.idx = self.replay.start_idx = self.replay.n_real
        self._rebuild_smc()
        acc = self.connector.account
        self.paper = PaperTradingEngine(self.spec, PaperConfig(initial_balance=float(p.get("initial_balance", 10_000.0)), slippage_points=float(p.get("slippage_points",2)), commission_per_lot=float(p.get("commission_per_lot",0)), ambiguity="WORST_CASE"),
                                        synthetic=synth is not None)
        lb = self.replay.last_closed_bar
        self.paper.update_quote(lb.close, lb.spread, self.replay.current_time)
        self.paper_idx = self.replay.idx
        self.bt_result = None
        self.session_id += 1
        self._set_mode(AppMode.SYNTHETIC if self.replay.in_synthetic_zone else AppMode.REPLAY)
        self._notify("info", f"Datos {self.spec.symbol} {base}: {rep.summary()}")
        return {"report": rep.summary(), "gaps": len(rep.gaps), "symbol": self.spec.symbol,
                "base_tf": base, "chart_tfs": self.chart_tfs, "spec": self.spec.__dict__, **self.session_state()}

    def set_smc_config(self, cfg: dict) -> dict:
        d = self.smc_cfg.to_dict()
        d.update({k: v for k, v in cfg.items() if k in d})
        self.smc_cfg = SMCConfig(**d)
        self._rebuild_smc()
        return self.smc_cfg.to_dict()

    def _rebuild_smc(self) -> None:
        if self.replay is None:
            return
        base = self.replay.base_tf
        tfs = set(self.replay.chart_tfs) | {base}
        self.engines = {tf: SMCEngine(tf, self.smc_cfg, self.spec.point) for tf in tfs}
        self.aggs = {tf: BarAggregator(tf, base) for tf in tfs if tf != base}
        self.fed_idx = 0
        self._feed(len(self.replay.bars))

    def _feed(self, upto: int) -> None:
        base = self.replay.base_tf
        for b in self.replay.bars[self.fed_idx:upto]:
            self.engines[base].on_bar(b)
            for tf, agg in self.aggs.items():
                for c in agg.update(b):
                    self.engines[tf].on_bar(c)
        self.fed_idx = max(self.fed_idx, upto)

    def _need(self) -> None:
        if self.replay is None:
            raise ServiceError("Carga datos primero")

    # ------------------------------------------------------------------ replay
    def _advance(self) -> bool:
        r = self.replay
        if not r.step_forward():
            return False
        if r.idx > self.fed_idx:
            self._feed(r.idx)
        if r.idx > self.paper_idx:
            for i in range(self.paper_idx, r.idx):
                b = r.bars[i]
                for t in self.paper.on_bar(b, b.time + r.base_delta):
                    self._notify("info", f"Simulada #{t.id} cerrada por {t.exit_reason} @ {t.exit_price}: "
                                         f"{t.profit} {self.paper.currency}")
                before={o["id"] for o in self.paper.stop_orders if o["status"]=="FILLED"}
                self.paper.process_stops(b, b.time + r.base_delta)
                for o in self.paper.stop_orders:
                    if o["status"]=="FILLED" and o["id"] not in before:
                        self.journal[o["trade_id"]]={"setup":o["setup"],"note":o["note"],"lesson":"", "clock":ts(o["created_time"])}
                        self._notify("info",f"Pendiente #{o['id']} activada · operación #{o['trade_id']} @ {o['fill']}")
            self.paper_idx = r.idx
        if r.in_synthetic_zone and self.state.mode != AppMode.SYNTHETIC:
            self._set_mode(AppMode.SYNTHETIC)
        self._check_quiz()
        return True

    def step(self, n: int = 1) -> dict:
        self._need()
        moved = 0
        for _ in range(max(1, min(int(n), 5000))):
            if not self._advance():
                break
            moved += 1
        return {"moved": moved, **self.session_state()}

    def back(self, n: int = 1) -> dict:
        self._need()
        for _ in range(max(1, int(n))):
            if not self.replay.step_back():
                break
        return self.session_state()

    def reset(self) -> dict:
        self._need()
        self.replay.reset()
        return self.session_state()

    def jump(self, t: str) -> dict:
        """Atrás: solo mira. Adelante: avanza vela a vela (simulación coherente)."""
        self._need()
        tt = pd.Timestamp(t)
        tt = (tt.tz_localize("UTC") if tt.tzinfo is None else tt.tz_convert("UTC")).to_pydatetime()
        target = max(1, min(self.replay._index_for(tt), len(self.replay.bars)))
        if target <= self.replay.idx:
            self.replay.idx = target
        else:
            while self.replay.idx < target and self._advance():
                pass
        return self.session_state()

    def next_trade(self) -> dict:
        self._need()
        if not self.bt_result:
            raise ServiceError("Ejecuta un backtest primero")
        now = self.replay.current_time
        nxt = [t for t in self.bt_result.trades if t.entry_time and t.entry_time > now]
        if not nxt:
            raise ServiceError("No hay más operaciones del backtest")
        return self.jump((nxt[0].entry_time + self.replay.base_delta).isoformat())

    # ------------------------------------------------------------------ vistas
    def bars(self, tf: str, limit: int = 1500) -> dict:
        self._need()
        if tf not in self.replay.chart_tfs or tf not in self.engines:
            if not is_derivable(tf, self.replay.base_tf):
                raise ServiceError(f"{tf} no se puede derivar de {self.replay.base_tf}")
            if tf not in self.replay.chart_tfs:
                self.replay.chart_tfs.append(tf)
            self.replay._resampled_upto = -1
            self._rebuild_smc()
        df = self.replay.visible(tf).tail(int(limit))
        t = epoch_s(df["time"]) if len(df) else np.array([], dtype=int)
        syn = df["synthetic"].to_numpy(bool) if "synthetic" in df else np.zeros(len(df), bool)
        rows = [{"time": int(t[i]), "open": float(o), "high": float(h), "low": float(l), "close": float(c),
                 "synthetic": bool(syn[i])}
                for i, (o, h, l, c) in enumerate(zip(df["open"], df["high"], df["low"], df["close"]))]
        f = self.replay.forming(tf)
        forming = None if f is None else {"time": ts(f.time), "open": f.open, "high": f.high, "low": f.low,
                                          "close": f.close, "synthetic": f.synthetic}
        return {"tf": tf, "bars": rows, "forming": forming, "clock": ts(self.replay.current_time)}

    def smc(self, tf: str, since: Optional[int] = None) -> dict:
        self._need()
        eng = self.engines.get(tf)
        if eng is None:
            self.bars(tf, 1)
            eng = self.engines[tf]
        snap = eng.snapshot(self.replay.current_time)
        lim = (lambda t: since is None or ts(t) >= since)
        out = {
            "tf": tf, "state": snap.state,
            "swings": [{"time": ts(s.formation_time), "price": s.price, "kind": s.kind}
                       for s in snap.swings[-200:] if lim(s.formation_time)],
            "events": [{"type": e.type, "direction": e.direction, "price": e.price,
                        "from": ts(e.source_swing.formation_time), "time": ts(e.timestamp),
                        "new_state": e.new_state, "reason": e.reason} for e in snap.events[-40:]],
            "fvgs": [{"direction": g.direction, "top": g.top, "bottom": g.bottom, "from": ts(g.formation_time),
                      "detected": ts(g.detected_at), "status": st}
                     for g, st in snap.fvgs[-120:] if st in ("OPEN", "PARTIALLY_FILLED")],
            "order_blocks": [{"direction": o.direction, "top": o.top, "bottom": o.bottom,
                              "from": ts(o.formation_time), "status": st}
                             for o, st in snap.order_blocks[-40:] if st == "ACTIVE"],
            "liquidity": [{"kind": lv.kind, "price": lv.price, "from": ts(lv.formation_time),
                           "equal": bool(lv.equal_detected_at and lv.equal_detected_at <= snap.time),
                           "label": lv.equal_label, "status": st}
                          for lv, st in snap.liquidity[-150:] if st != "SWEPT"],
            "range": None if not snap.active_range else {"from": ts(snap.active_range["start"]),
                                                         "high": snap.active_range["high"],
                                                         "low": snap.active_range["low"]},
            "enabled": self.smc_cfg.enabled,
        }
        return out

    def macro_context(self) -> dict:
        self._need()
        frame=self.replay.visible("H3")
        if frame.empty: return {"valid":False,"reason":"historia H3 ausente"}
        end=pd.Timestamp(frame.iloc[-1]["time"])+pd.Timedelta(hours=3)
        start=end-pd.Timedelta(days=7)
        history=frame[frame["time"]>=start]
        if len(history)<30 or pd.Timestamp(history.iloc[0]["time"])>start+pd.Timedelta(days=1):
            return {"valid":False,"reason":"historia semanal insuficiente"}
        x=(pd.to_datetime(history["time"],utc=True)-start).dt.total_seconds().to_numpy()/10800
        y=history["close"].to_numpy(float)
        slope,intercept=np.polyfit(x,y,1)
        fit=intercept+slope*x
        above=float(np.max(history["high"].to_numpy()-fit))
        below=float(np.max(fit-history["low"].to_numpy()))
        last=history.iloc[-1];mid=float(fit[-1])
        return {"valid":True,"start":ts(start),"time":ts(last["time"]),"end":ts(end),
                **{key:float(last[key]) for key in ("open","close","high","low")},
                "slope":float(slope),"mid":mid,"upper":mid+above,"lower":mid-below,
                "scope":"H3 derivada del reloj de datos; requiere cotejar anclaje servidor"}

    def frame(self, tfs: list[str], limit: int = 1500, with_smc: bool = True) -> dict:
        """Todo lo que la web necesita para pintar un instante: estado + velas + SMC de cada gráfico."""
        self._need()
        charts = {}
        macro=self.macro_context()
        for tf in tfs:
            c = self.bars(tf, limit)
            if with_smc:
                c["smc"] = self.smc(tf)
            c["macro"]=macro
            charts[tf] = c
        return {"state": self.session_state(), "charts": charts, "bt_trades": self.backtest_trades_visible()}

    def topdown(self) -> list[dict]:
        out = []
        t = self.replay.current_time
        for tf in sorted(self.engines, key=lambda x: -TIMEFRAME_SECONDS[x]):
            s = self.engines[tf].snapshot(t)
            ev = s.events[-1] if s.events else None
            fv = [g for g, st in s.fvgs if st in ("OPEN", "PARTIALLY_FILLED")]
            out.append({"tf": tf, "state": s.state,
                        "last_event": f"{ev.type} {ev.direction} @ {ev.price}" if ev else None,
                        "fvg": fv[-1].direction if fv else None})
        return out

    def _can_trade(self) -> tuple[bool, str]:
        if self.paper is None or self.replay is None:
            return False, "Carga datos primero"
        if self.replay.idx < self.paper_idx:
            return False, "Estás viendo el pasado: avanza hasta el presente del replay para operar"
        if self.state.trading_locked and self._real_route():
            return False, "Trading bloqueado"
        return True, ""

    def session_state(self) -> dict:
        if self.replay is None:
            return {"loaded": False, **self.status()}
        r, pp = self.replay, self.paper
        ok, why = self._can_trade()
        trades = pp.trades[-300:]
        return {
            "loaded": True, **self.status(), "session": self.session_id,
            "symbol": self.spec.symbol, "digits": self.spec.digits, "point": self.spec.point,
            "base_tf": r.base_tf, "clock": ts(r.current_time), "idx": r.idx, "total": len(r.bars),
            "n_real": r.n_real, "synthetic_zone": r.in_synthetic_zone, "state": r.state.value,
            "bid": pp.bid, "ask": pp.ask, "spread": pp.spread_points,
            "balance": pp.balance, "equity": round(pp.equity, 2), "currency": pp.currency,
            "pending_orders": [{k:(ts(v) if k=="created_time" else v) for k,v in o.items()} for o in pp.stop_orders[-100:]],
            "can_trade": ok, "why": why, "route": "REAL" if self._real_route() else "SIMULACION",
            "trades": [trade_dict(t, pp.floating(t) if t.status == "OPEN" else None) for t in trades],
            "stats": self._paper_stats(), "topdown": self.topdown(),
            "events": self.events[-20:], "quiz_open": self.quiz_open,
        }

    def _paper_stats(self) -> dict:
        c = self.paper.closed_trades
        wins = sum(1 for t in c if (t.profit or 0) > 0)
        return {"trades": len(c), "wins": wins, "win_rate": round(100 * wins / len(c), 1) if c else None,
                "net": round(sum(t.profit or 0 for t in c), 2)}

    # ------------------------------------------------------------------ órdenes
    def _set_mode(self, mode: AppMode) -> None:
        if mode == AppMode.REAL and not self.state.real_trading_enabled:
            mode = AppMode.LIVE
        self.state.mode = mode

    def _real_route(self) -> bool:
        return (self.state.mode == AppMode.REAL and self.state.can_send_real_orders()
                and self.live_exec is not None and self.live)

    def _mt5_profit_fn(self):
        from mt5.connector import mt5

        def fn(direction, volume, p_open, p_close):
            t = mt5.ORDER_TYPE_BUY if direction == "BUY" else mt5.ORDER_TYPE_SELL
            return mt5.order_calc_profit(t, self.spec.symbol, volume, p_open, p_close)
        return fn

    def compute_order(self, direction: str, p: dict) -> dict:
        self._need()
        direction = direction.upper()
        if direction not in ("BUY", "SELL"):
            raise ServiceError("Dirección inválida")
        entry = float(p["entry_price"]) if p.get("order_type") in ("BUY_STOP","SELL_STOP") and p.get("entry_price") else (self.paper.ask if direction == "BUY" else self.paper.bid)
        bars = self.replay.visible_base_bars()[-200:]
        a = atr([b.high for b in bars], [b.low for b in bars], [b.close for b in bars]) if bars else None
        struct = None
        sl_mode = p.get("sl_mode", "POINTS")
        sl_val = float(p.get("sl", 0) or 0)
        if sl_mode == "STRUCTURE":
            snap = self.engines[self.replay.base_tf].snapshot(self.replay.current_time)
            sw = [s for s in snap.swings if s.kind == ("LOW" if direction == "BUY" else "HIGH")]
            struct = sw[-1].price if sw else None
        try:
            sl = stop_from(sl_mode, direction, entry, sl_val, self.spec, a, struct) \
                if (sl_val or sl_mode == "STRUCTURE") else None
        except ValueError as e:
            raise ServiceError(str(e))
        tp_mode, tp_val = p.get("tp_mode", "R:R"), float(p.get("tp", 0) or 0)
        tp = None
        if tp_mode == "R:R" and sl is not None and tp_val > 0:
            tp = take_profit_rr(direction, entry, sl, tp_val, self.spec.digits)
        elif tp_mode == "PRICE" and tp_val > 0:
            tp = tp_val
        real = self._real_route()
        profit_fn = self._mt5_profit_fn() if real else self.paper.profit_fn
        balance = self.connector.account.balance if real else self.paper.balance
        if p.get("use_risk", True):
            res = size_by_risk(balance, float(p.get("risk_pct", 1.0)), direction, entry, sl, self.spec, profit_fn)
            vol, risk, reason = res.volume, res.actual_risk, res.reason
        else:
            vol, reason = float(p.get("volume", self.spec.volume_min)), ""
            risk = abs(profit_fn(direction, vol, entry, sl)) if (sl and profit_fn) else None
        return {"direction": direction, "entry": entry, "sl": sl, "tp": tp, "volume": vol,
                "risk_money": risk, "reason": reason, "route": "REAL" if real else "SIMULACION",
                "rr": round(abs(tp - entry) / abs(entry - sl), 2) if (tp and sl) else None,
                "currency": self.paper.currency}

    def order(self, direction: str, p: dict) -> dict:
        ok, why = self._can_trade()
        if not ok:
            raise ServiceError(why)
        o = self.compute_order(direction, p)
        if o["volume"] is None:
            raise ServiceError(f"No se puede calcular el volumen: {o['reason']}")
        if o["route"] == "REAL":
            return self.preview_real(o)
        errs = validate_stops(o["direction"], self.paper.bid, self.paper.ask, o["sl"], o["tp"], self.spec)
        if errs:
            raise ServiceError("; ".join(errs))
        try:
            setup = (p.get("setup") or "").strip()[:40]
            t = self.paper.open(o["direction"], o["volume"], o["sl"], o["tp"], setup or "web", self.replay.current_time)
            self.journal[t.id] = {"setup": setup or "Sin etiqueta", "note": (p.get("note") or "").strip()[:500],
                                  "lesson": "", "clock": ts(self.replay.current_time)}
        except ValueError as e:
            raise ServiceError(str(e))
        self.db.save_trade(self.state.mode.name, None, None, self.spec.symbol, trade_dict(t))
        self._notify("info", f"SIMULADA #{t.id} {t.direction} {t.volume} @ {t.entry_price} SL {t.stop_loss} TP {t.take_profit}")
        return {"trade": trade_dict(t), **self.session_state()}

    def pending_stop(self, direction: str, p: dict) -> dict:
        ok,why=self._can_trade()
        if not ok:raise ServiceError(why+". Usa Nueva práctica desde aquí.")
        if self.live or self._real_route():raise ServiceError("Las pendientes están disponibles solo en replay simulado")
        kind=p.get("order_type")
        if kind not in ("BUY_STOP","SELL_STOP") or direction!=("BUY" if kind=="BUY_STOP" else "SELL"):
            raise ServiceError("Tipo y dirección incompatibles")
        entry=p.get("entry_price")
        if entry is None or not np.isfinite(entry) or entry<=0:raise ServiceError("Indica un precio de activación válido")
        entry=round(float(entry),self.spec.digits)
        if (direction=="BUY" and entry<=self.paper.ask) or (direction=="SELL" and entry>=self.paper.bid):
            raise ServiceError("Buy Stop debe superar ASK; Sell Stop debe estar debajo de BID")
        p=dict(p,entry_price=entry)
        o=self.compute_order(direction,p)
        if o["volume"] is None:raise ServiceError(o["reason"])
        spread=self.paper.ask-self.paper.bid
        bid=entry-spread if direction=="BUY" else entry
        errors=validate_stops(direction,bid,bid+spread,o["sl"],o["tp"],self.spec)
        if errors:raise ServiceError("; ".join(errors))
        if sum(z["status"]=="PENDING" for z in self.paper.stop_orders)>=20:raise ServiceError("Máximo 20 pendientes")
        order=self.paper.queue_stop(dict(order_type=kind,direction=direction,entry=entry,sl=o["sl"],tp=o["tp"],volume=o["volume"],
            setup=(p.get("setup") or "stop replay")[:40],note=(p.get("note") or "")[:500],created_time=self.replay.current_time))
        return {"pending_id":order["id"],**self.session_state()}

    def cancel_pending(self, order_id: int) -> dict:
        self._need()
        for o in self.paper.stop_orders:
            if o["id"]==order_id and o["status"]=="PENDING":o["status"]="CANCELLED"
        return self.session_state()

    def practice_here(self) -> dict:
        self._need()
        if self.live:raise ServiceError("Desactiva LIVE para iniciar una práctica histórica")
        old=self.paper
        self.paper=PaperTradingEngine(self.spec,old.cfg,old.profit_fn,old.synthetic)
        self.paper_idx=self.replay.idx
        self.replay.start_idx=self.replay.idx
        b=self.replay.last_closed_bar
        self.paper.update_quote(b.close,b.spread,self.replay.current_time)
        self.journal={};self.quiz_open=None;self.session_id+=1
        return self.session_state()

    def close(self, trade_id: Optional[int] = None) -> dict:
        self._need()
        try:
            for t in self.paper.close(trade_id):
                self._notify("info", f"Simulada #{t.id} cerrada @ {t.exit_price}: {t.profit}")
        except ValueError as e:
            raise ServiceError(str(e))
        return self.session_state()

    # ------------------------------------------------------------------ real
    def authorize(self, typed_login: str) -> dict:
        acc = self.connector.account
        if not self.live or acc is None or self.live_exec is None:
            raise ServiceError("El trading real solo se autoriza en modo LIVE con MT5 conectado")
        if str(typed_login).strip() != str(acc.login):
            raise ServiceError("El número de cuenta escrito no coincide")
        from mt5.execution import TradingBlocked
        try:
            self.state.mode = AppMode.LIVE
            self.live_exec.authorize(acc.login, acc.server)
        except (TradingBlocked, PermissionError) as e:
            raise ServiceError(str(e))
        self.state.unlock_trading()
        self._set_mode(AppMode.REAL)
        self._notify("warning", f"TRADING REAL AUTORIZADO para {acc.login}@{acc.server}")
        return self.status()

    def kill(self) -> dict:
        if self.live_exec:
            self.live_exec.kill_switch()
        else:
            self.state.revoke_real_trading()
        self.state.unlock_trading()
        self._set_mode(AppMode.LIVE if self.live else AppMode.REPLAY)
        self._notify("warning", "KILL SWITCH: trading real bloqueado (posiciones existentes NO se cierran)")
        return self.status()

    def preview_real(self, o: dict) -> dict:
        from mt5.execution import TradingBlocked
        try:
            pv = self.live_exec.preview(self.spec.symbol, o["direction"], o["volume"], o["sl"], o["tp"])
        except TradingBlocked as e:
            raise ServiceError(str(e))
        token = secrets.token_urlsafe(16)
        self._previews = {token: (pv, datetime.now(timezone.utc))}
        return {"real_preview": {
            "token": token, "ok": pv.ok, "symbol": pv.symbol, "direction": pv.direction, "volume": pv.volume,
            "price": pv.price, "sl": pv.sl, "tp": pv.tp, "margin": pv.margin, "risk": pv.risk_money,
            "reward": pv.reward_money, "retcode": pv.check_retcode, "comment": pv.check_comment,
            "account": pv.account, "server": pv.server}}

    def send_real(self, token: str) -> dict:
        from mt5.execution import TradingBlocked
        item = self._previews.pop(token, None)
        if item is None:
            raise ServiceError("Confirmación caducada o inválida: vuelve a pedir la orden")
        pv, when = item
        if datetime.now(timezone.utc) - when > timedelta(seconds=30):
            raise ServiceError("La confirmación caducó (30 s): vuelve a pedir la orden")
        try:
            res = self.live_exec.send(pv)
        except TradingBlocked as e:
            raise ServiceError(str(e))
        self._notify("warning", f"ORDEN REAL ejecutada: retcode {res.retcode} deal {res.deal} order {res.order}")
        return {"retcode": res.retcode, "deal": res.deal, "order": res.order}

    def real_positions(self) -> list[dict]:
        if self.live_exec is None:
            return []
        return [{"ticket": p.ticket, "symbol": p.symbol, "volume": p.volume, "type": p.type,
                 "price_open": p.price_open, "sl": p.sl, "tp": p.tp, "profit": p.profit}
                for p in self.live_exec.own_positions()]

    def close_real(self, ticket: int) -> dict:
        from mt5.execution import TradingBlocked
        if self.live_exec is None:
            raise ServiceError("MT5 no conectado")
        try:
            r = self.live_exec.close_position(int(ticket))
        except TradingBlocked as e:
            raise ServiceError(str(e))
        return {"retcode": r.retcode, "deal": r.deal}

    # ------------------------------------------------------------------ live
    def set_live(self, on: bool) -> dict:
        self._need()
        if on:
            if self.connector.state != ConnectionState.CONNECTED or self.source != "MT5":
                raise ServiceError("LIVE requiere MT5 conectado y datos cargados desde MT5")
            if self.replay.in_synthetic_zone or self.replay.synthetic is not None:
                raise ServiceError("Recarga sin mercado sintético para usar LIVE")
            self.replay.idx = len(self.replay.bars)
            self._feed(self.replay.idx)
            for i in range(self.paper_idx, self.replay.idx):
                b = self.replay.bars[i]
                self.paper.on_bar(b, b.time + self.replay.base_delta)
            self.paper_idx = self.replay.idx
            for other in self.sessions.values():
                if other is not self._cur and other.live:
                    raise ServiceError(f"Ya hay otra pestaña en LIVE ({other.spec.symbol}); desactívala primero")
            self.live = True
            self._set_mode(AppMode.LIVE)
        else:
            if self.state.real_trading_enabled:
                self.kill()
            self.live = False
            self._set_mode(AppMode.REPLAY)
        return self.session_state()

    def live_tick(self) -> dict:
        if not self.live:
            raise ServiceError("LIVE no activo")
        from mt5.market_data import current_tick, fetch_rates
        sym, base = self.spec.symbol, self.replay.base_tf
        tick = current_tick(sym)
        if tick is not None and tick.bid > 0:
            t = datetime.fromtimestamp(tick.time, tz=timezone.utc)
            for tr in self.paper.on_tick(tick.bid, tick.ask, t):
                self._notify("info", f"Simulada #{tr.id} cerrada por {tr.exit_reason} @ {tr.exit_price}")
            last = self.replay.bars[-1].time
            if int(last.timestamp()) + 2 * TIMEFRAME_SECONDS[base] <= tick.time:
                df = fetch_rates(sym, base, 50)
                if self.replay.append_bars(bars_from_df(df)):
                    self._feed(len(self.replay.bars))
                    self.paper_idx = self.replay.idx
                    self.db.upsert_candles(sym, base, df)
        return self.session_state()

    # ------------------------------------------------------------------ backtest
    def backtest(self, p: dict, sid: str = "default") -> dict:
        """Prepara en el hilo núcleo y calcula en el hilo de cómputo (no bloquea el resto)."""
        def prepare():
            self._need()
            df = self.replay.base_df.copy()
            amb = p.get("ambiguity", "WORST_CASE")
            if p.get("use_ticks"):
                raise ServiceError("El backtest tick a tick requiere la secuencia bid/ask completa; esta versión utiliza OHLC.")
            base = self.replay.base_tf
            challenge_start = None
            if p.get("challenge"):
                balance = float(p.get("initial_balance", 10))
                goal = float(p.get("challenge_goal", 100))
                days = float(p.get("challenge_days", 3))
                if not (0 < balance < goal and 0 < days <= 30):
                    raise ServiceError("Reto: balance > 0, meta mayor al balance y plazo de hasta 30 días")
                deadline = pd.Timestamp(df["time"].iloc[-1]) + pd.Timedelta(seconds=TIMEFRAME_SECONDS[base])
                challenge_start = (deadline - pd.Timedelta(days=days)).to_pydatetime()
            cfg = BacktestConfig(
                symbol=self.spec.symbol, timeframe=base,
                initial_balance=float(p.get("initial_balance", 10_000)),
                spread_mode=p.get("spread_mode", "HISTORICAL"),
                fixed_spread_points=int(p.get("fixed_spread_points", 0)),
                slippage_points=float(p.get("slippage_points", 0)),
                commission_per_lot=float(p.get("commission_per_lot", 0)),
                ambiguity=amb, apply_swap=bool(p.get("apply_swap", True)),
                topdown_tfs=tuple(t for t in ("W1", "D1", "H4", "H1", "M15") if is_derivable(t, base)),
                smc=self.smc_cfg.to_dict(), trade_start=challenge_start,
                challenge_goal=goal if challenge_start is not None else None)
            if p.get("strategy")=="GM_MACRO":
                if base!="M15":raise ServiceError("GM Macro requiere cargar base M15; ejecuta en la siguiente apertura")
                if "synthetic" in df and df["synthetic"].astype(bool).any():raise ServiceError("GM Macro requiere velas históricas; excluye extensión sintética")
                if "XAU" not in self.spec.symbol:raise ServiceError("GM Macro con DXY inverso se limita a oro")
                path=Path(__file__).resolve().parents[2]/"python/runtime/history_archive_20261007/mt5_dxy.csv"
                if not path.exists():raise ServiceError("Falta histórico DXY: no se sustituye por cotización actual")
                dxy=pd.read_csv(path);dxy["time"]=pd.to_datetime(dxy["time"],utc=True)
                strat=MacroLiquidityStrategy(rr=float(p.get("rr",2)),risk_pct=float(p.get("risk_pct",.5)),dxy=dxy)
            else:
                strategy_cls = SMCQualityStrategy if p.get("strategy")=="SMC_QUALITY" else SMCFVGStrategy
                strat = strategy_cls(p.get("bias_tf", "H1"), float(p.get("rr", 2.0)),
                                     float(p.get("sl_buffer_points", 20)), float(p.get("risk_pct", 1.0)))
            return df, self.spec, cfg, strat

        df, spec, cfg, strat = self.run(self.in_session, sid, prepare)
        res = self._compute.submit(lambda: BacktestEngine(df, spec, cfg).run(strat)).result()

        def store():
            self.bt_result = res
            bid = self.db.save_backtest(res.meta(), res.statistics, res.trades_as_dicts())
            self._notify("info", f"Backtest #{bid}: {res.statistics['total_trades']} operaciones, "
                                 f"neto {res.statistics['net_profit']} {res.currency}")
            return bid
        bid = self.run(self.in_session, sid, store)
        return self.run(self.in_session, sid, self.backtest_payload, bid)

    def backtest_payload(self, bid: Optional[int] = None) -> dict:
        res = self.bt_result
        if res is None:
            raise ServiceError("Sin backtest")
        eq = res.equity
        _, ddp = drawdown_series(eq.set_index("time")["equity"])
        t = epoch_s(eq["time"])
        step = max(1, len(eq) // 3000)          # submuestreo para el navegador
        challenge = None
        if res.config.trade_start is not None:
            active = eq[eq["time"] >= pd.Timestamp(res.config.trade_start)]
            goal = float(res.config.challenge_goal)
            reached = active[active["equity"] >= goal]
            challenge = {"goal": goal, "goal_reached": not reached.empty,
                         "first_goal_time": ts(reached["time"].iloc[0]) if not reached.empty else None,
                         "max_equity": float(active["equity"].max()) if len(active) else float(res.config.initial_balance),
                         "final_balance": float(eq["balance"].iloc[-1]),
                         "rejected_orders": len(res.rejected_orders)}
        return {
            "id": bid, "strategy": res.strategy, "strategy_version": res.strategy_version,
            "smc_version": res.smc_version, "engine_version": res.engine_version,
            "statistics": res.statistics, "currency": res.currency,
            "challenge": challenge,
            "equity": [{"time": int(t[i]), "value": float(eq["equity"].iloc[i])} for i in range(0, len(eq), step)],
            "drawdown": [{"time": int(t[i]), "value": float(-(ddp.fillna(0).iloc[i]))} for i in range(0, len(eq), step)],
            "trades": [trade_dict(x) for x in res.trades],
        }

    def backtest_trades_visible(self) -> list[dict]:
        """Operaciones del backtest que el reloj ya ha alcanzado (sin revelar futuro)."""
        if not self.bt_result or not self.replay:
            return []
        clock = self.replay.current_time
        out = []
        for x in self.bt_result.trades:
            if x.entry_time and x.entry_time <= clock:
                d = trade_dict(x)
                if x.exit_time and x.exit_time > clock:
                    d.update(exit_time=None, exit_price=None, exit_reason=None, profit=None, outcome=None,
                             r=None, swap=None, status="OPEN")
                out.append(d)
        return out

    def export_backtest(self) -> str:
        if not self.bt_result:
            raise ServiceError("Sin backtest")
        folder = ROOT / "exports" / f"backtest_{datetime.now():%Y%m%d_%H%M%S}"
        self.bt_result.export(folder)
        return str(folder)

    # ------------------------------------------------------------------ dibujos
    def drawings(self, tf: str) -> list[dict]:
        self._need()
        return self.db.load_drawings(self.spec.symbol, tf)

    def save_drawing(self, d: dict) -> dict:
        self._need()
        kind = d["kind"]
        if kind not in ("hline", "vline", "trend", "rect", "fib", "channel", "text", "ray", "extended", "long", "short", "arrow"):
            raise ServiceError("Tipo de dibujo desconocido")
        if kind in ("long", "short", "arrow", "ray", "extended"):
            import math
            coords=d["coordinates"]
            count=3 if kind in ("long", "short") else 2
            for i in range(1,count+1):
                try:
                    price=float(coords[f"p{i}"])
                    stamp=pd.Timestamp(coords[f"t{i}"])
                    if not math.isfinite(price) or price<=0 or pd.isna(stamp): raise ValueError()
                except (KeyError,TypeError,ValueError,OverflowError):
                    raise ServiceError("Cada punto requiere fecha válida y precio positivo finito")
            if kind=="long" and not float(coords["p2"])<float(coords["p1"])<float(coords["p3"]):
                raise ServiceError("Long: stop < entrada < objetivo")
            if kind=="short" and not float(coords["p3"])<float(coords["p1"])<float(coords["p2"]):
                raise ServiceError("Short: objetivo < entrada < stop")
        did = self.db.save_drawing(self.spec.symbol, d.get("timeframe"), kind, d["coordinates"],
                                   d.get("style") or {"color": "#ffeb3b"},
                                   ts(self.replay.current_time), d.get("id"))
        return {"id": did}

    def delete_drawing(self, did: int) -> dict:
        self.db.delete_drawing(int(did))
        return {"deleted": did}

    # ================================================================== APRENDIZAJE
    EXPLAIN = {
        ("BOS", "bullish"): "BOS alcista: el precio CERRÓ por encima del último máximo confirmado. La estructura "
                            "sigue alcista; los retrocesos hacia FVG/OB alcistas son zonas de interés para comprar.",
        ("BOS", "bearish"): "BOS bajista: el precio CERRÓ por debajo del último mínimo confirmado. Continuación "
                            "bajista; busca ventas en retrocesos a FVG/OB bajistas.",
        ("CHoCH", "bullish"): "CHoCH alcista: en tendencia BAJISTA el precio rompió el máximo protegido. Primer aviso "
                              "de cambio de carácter: espera un BOS alcista que lo confirme antes de confiar.",
        ("CHoCH", "bearish"): "CHoCH bajista: en tendencia ALCISTA el precio rompió el mínimo protegido. Posible giro: "
                              "espera confirmación (BOS bajista) antes de vender agresivamente.",
    }

    def explain(self, tf: str, limit: int = 25) -> list[dict]:
        """Lista didáctica de lo que el motor SMC ve AHORA (sin futuro) en `tf`, con explicación."""
        self._need()
        m = self.smc(tf)
        price = self.paper.bid
        items = []
        for e in m["events"]:
            txt = self.EXPLAIN.get((e["type"], e["direction"]), "")
            if e["new_state"] == "RANGING":
                txt = ("CHoCH fallido → RANGO: el mercado rompió en ambos sentidos sin continuación. Opera los "
                       "extremos del rango o espera la ruptura (BOS) para seguir la nueva dirección.")
            items.append({"time": e["time"], "kind": e["type"], "dir": e["direction"], "price": e["price"],
                          "title": f"{e['type']} {'alcista' if e['direction'] == 'bullish' else 'bajista'} @ {e['price']}",
                          "text": txt, "why": e["reason"]})
        fvgs = sorted(m["fvgs"], key=lambda f: abs(((f["top"] + f["bottom"]) / 2) - (price or 0)))[:6]
        for f in fvgs:
            inside = price is not None and f["bottom"] <= price <= f["top"]
            items.append({"time": f["detected"], "kind": "FVG", "dir": f["direction"], "price": f["top"],
                          "title": f"FVG {'alcista' if f['direction'] == 'bullish' else 'bajista'} "
                                   f"[{f['bottom']} – {f['top']}] · {f['status']}",
                          "text": ("Hueco de 3 velas: una vela fue tan impulsiva que dejó un tramo sin negociar. El "
                                   "precio tiende a volver a 'rellenarlo'. "
                                   + ("El precio está DENTRO ahora mismo." if inside else "")),
                          "why": "low[3] > high[1]" if f["direction"] == "bullish" else "high[3] < low[1]"})
        for o in m["order_blocks"]:
            items.append({"time": o["from"], "kind": "OB", "dir": o["direction"], "price": o["top"],
                          "title": f"Order Block {'alcista' if o['direction'] == 'bullish' else 'bajista'} "
                                   f"[{o['bottom']} – {o['top']}]",
                          "text": "Última vela contraria antes del impulso que rompió estructura. Zona donde "
                                  "pudo haber órdenes institucionales; su primer retesteo es un punto de interés.",
                          "why": "vela contraria + desplazamiento + BOS/CHoCH"})
        for l in m["liquidity"]:
            if not l["equal"]:
                continue
            items.append({"time": l["from"], "kind": l["label"], "dir": "bullish" if l["kind"] == "SSL" else "bearish",
                          "price": l["price"], "title": f"{l['label']} @ {l['price']} (liquidez)",
                          "text": ("Máximos/mínimos iguales: muchos stops acumulados al otro lado. El precio suele "
                                   "barrer esa liquidez antes de moverse en la dirección real."),
                          "why": "≥2 swings dentro de la tolerancia"})
        if m["range"]:
            items.append({"time": m["range"]["from"], "kind": "RANGO", "dir": "neutral", "price": m["range"]["high"],
                          "title": f"Rango activo [{m['range']['low']} – {m['range']['high']}]",
                          "text": "Sin tendencia clara: evita perseguir el precio en mitad del rango.", "why": ""})
        prio = {"BOS": 0, "CHoCH": 0, "RANGO": 0, "OB": 1, "EQH": 1, "EQL": 1, "FVG": 2}
        items.sort(key=lambda x: (prio.get(x["kind"], 3), -x["time"]))
        return items[:limit]

    # ---------------- reto de predicción ("¿sube o baja?")
    def quiz_start(self, guess: str, horizon: int) -> dict:
        self._need()
        ok, why = self._can_trade()
        if not ok:
            raise ServiceError(why)
        if self.quiz_open:
            raise ServiceError("Ya hay un reto abierto: avanza velas para resolverlo")
        guess = guess.upper()
        if guess not in ("UP", "DOWN"):
            raise ServiceError("La predicción debe ser UP o DOWN")
        horizon = max(1, min(int(horizon), 500))
        self.quiz_open = {"id": len(self.quiz) + 1, "guess": guess, "horizon": horizon,
                          "start_idx": self.replay.idx, "time": ts(self.replay.current_time),
                          "price": self.paper.bid, "tf": self.replay.base_tf}
        return {"quiz": self.quiz_open, **self.quiz_stats()}

    def _check_quiz(self) -> None:
        q = self.quiz_open
        if not q or self.replay.idx < q["start_idx"] + q["horizon"]:
            return
        end = self.replay.bars[q["start_idx"] + q["horizon"] - 1].close
        move = end - q["price"]
        q.update(end_price=end, move=round(move, self.spec.digits), points=round(move / self.spec.point, 1),
                 correct=(move > 0 and q["guess"] == "UP") or (move < 0 and q["guess"] == "DOWN"),
                 end_time=ts(self.replay.current_time))
        self.quiz.append(q)
        self.quiz_open = None
        self._notify("info", f"Reto #{q['id']}: dijiste {'SUBE' if q['guess'] == 'UP' else 'BAJA'} → "
                             f"{'ACIERTO' if q['correct'] else 'FALLO'} ({q['points']:+} pts en {q['horizon']} velas)")

    def quiz_reveal(self) -> dict:
        """Avanza las velas que faltan para resolver el reto abierto."""
        self._need()
        q = self.quiz_open
        if not q:
            raise ServiceError("No hay reto abierto")
        while self.quiz_open and self._advance():
            pass
        return {"result": self.quiz[-1] if self.quiz else None, **self.quiz_stats(), **self.session_state()}

    def quiz_stats(self) -> dict:
        done = self.quiz
        ok = sum(1 for q in done if q["correct"])
        streak = 0
        for q in reversed(done):
            if not q["correct"]:
                break
            streak += 1
        return {"quiz_total": len(done), "quiz_ok": ok,
                "quiz_accuracy": round(100 * ok / len(done), 1) if done else None,
                "quiz_streak": streak, "quiz_open": self.quiz_open, "quiz_history": done[-30:]}

    # ---------------- inicio de replay en una barra (TradingView "Seleccionar barra") o aleatorio
    def start_at(self, t: Optional[str] = None, random_pick: bool = False) -> dict:
        """
        Reinicia la práctica en otra barra: el futuro desde ese punto queda oculto y las operaciones
        simuladas abiertas se cancelan (no tendría sentido mantenerlas en otro momento del tiempo).
        """
        self._need()
        r = self.replay
        if random_pick:
            import random
            lo, hi = min(300, r.n_real - 2), max(301, r.n_real - 300)
            idx = random.randint(lo, max(lo, hi))
        else:
            tt = pd.Timestamp(t)
            tt = (tt.tz_localize("UTC") if tt.tzinfo is None else tt.tz_convert("UTC")).to_pydatetime()
            idx = max(1, min(r._index_for(tt), r.n_real))
        for o in self.paper.stop_orders:
            if o["status"]=="PENDING":o["status"]="CANCELLED"
        self.paper.cancel_all()
        r.idx = r.start_idx = idx
        self.paper_idx = idx
        lb = r.last_closed_bar
        self.paper.update_quote(lb.close, lb.spread, r.current_time)
        self.quiz_open = None
        self.session_id += 1
        self._set_mode(AppMode.SYNTHETIC if r.in_synthetic_zone else AppMode.REPLAY)
        self._notify("info", f"Replay reiniciado en {r.current_time:%Y-%m-%d %H:%M}"
                             + (" (aleatorio: no mires la fecha, lee el gráfico)" if random_pick else ""))
        return self.session_state()

    # ---------------- diario de operaciones
    def journal_list(self) -> dict:
        self._need()
        rows = []
        by_setup: dict[str, list] = {}
        for t in self.paper.trades:
            j = self.journal.get(t.id, {"setup": t.comment or "Sin etiqueta", "note": "", "lesson": ""})
            d = trade_dict(t, self.paper.floating(t) if t.status == "OPEN" else None)
            d.update(setup=j["setup"], note=j["note"], lesson=j["lesson"],
                     mae_r=round(t.mae / t.initial_risk, 2) if t.initial_risk else None,
                     mfe_r=round(t.mfe / t.initial_risk, 2) if t.initial_risk else None)
            rows.append(d)
            if t.status == "CLOSED":
                by_setup.setdefault(j["setup"], []).append(t)
        stats = []
        for setup, ts_ in by_setup.items():
            wins = [x for x in ts_ if (x.profit or 0) > 0]
            rs = [x.r_multiple for x in ts_ if x.r_multiple is not None]
            stats.append({"setup": setup, "trades": len(ts_), "win_rate": round(100 * len(wins) / len(ts_), 1),
                          "avg_r": round(sum(rs) / len(rs), 2) if rs else None,
                          "net": round(sum(x.profit or 0 for x in ts_), 2)})
        stats.sort(key=lambda x: -(x["avg_r"] or -99))
        return {"trades": list(reversed(rows)), "by_setup": stats, "currency": self.paper.currency}

    def learning_review(self) -> dict:
        """Describe practice evidence without promoting rules or predicting profits."""
        self._need()
        journal=self.journal_list()
        closed=[t for t in journal["trades"] if t["status"]=="CLOSED"]
        missing_plan=sum(not t.get("note", "").strip() for t in closed)
        missing_lesson=sum(not t.get("lesson", "").strip() for t in closed)
        untagged=sum(t.get("setup") in (None,"","Sin etiqueta") for t in closed)
        tasks=[]
        if missing_plan: tasks.append(f"{missing_plan} operaciones cerradas sin plan escrito. Antes de entrar: tesis, invalidación y objetivo.")
        if missing_lesson: tasks.append(f"{missing_lesson} operaciones cerradas sin lección. Revisa entrada, MAE/MFE y salida, incluso cuando hubo ganancia.")
        if untagged: tasks.append(f"{untagged} operaciones sin setup: etiquétalas para comparar decisiones similares.")
        if not closed: tasks.append("Practica una operación con plan escrito y stop definido; avanza el replay y registra una lección al cerrarla.")
        if not tasks: tasks.append("Compara un setup en otro tramo cronológico sin cambiar sus reglas; registra también señales descartadas.")
        return {"closed":len(closed),"missing_plan":missing_plan,"missing_lesson":missing_lesson,
                "untagged":untagged,"tasks":tasks,"by_setup":journal["by_setup"],
                "scope":"Sesión actual de práctica; no certifica rentabilidad ni activa reglas",
                "execution":{"slippage_points":self.paper.cfg.slippage_points,
                             "commission_per_lot":self.paper.cfg.commission_per_lot,
                             "ambiguity":self.paper.cfg.ambiguity}}

    def journal_update(self, trade_id: int, lesson: str = "", note: Optional[str] = None,
                       setup: Optional[str] = None) -> dict:
        self._need()
        if not any(t.id == trade_id for t in self.paper.trades):
            raise ServiceError("Operación inexistente")
        j = self.journal.setdefault(trade_id, {"setup": "Sin etiqueta", "note": "", "lesson": ""})
        j["lesson"] = (lesson or "")[:1000]
        if note is not None:
            j["note"] = note[:500]
        if setup:
            j["setup"] = setup[:40]
        self.db.save_trade("JOURNAL", None, None, self.spec.symbol, {"trade_id": trade_id, **j})
        return {"ok": True, **j}


for _n in SESSION_ATTRS:
    setattr(TradingService, _n, property(lambda self, n=_n: getattr(self._cur, n),
                                         lambda self, v, n=_n: setattr(self._cur, n, v)))
