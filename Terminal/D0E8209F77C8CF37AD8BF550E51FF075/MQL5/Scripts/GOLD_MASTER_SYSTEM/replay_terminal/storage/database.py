"""
storage/database.py — Persistencia SQLite (sin credenciales, nunca).

Tablas: accounts, symbols, candles_cache, drawings, layouts, trades,
positions, backtests, backtest_trades, settings, smc_events, logs,
schema_version. Las migraciones son idempotentes (CREATE IF NOT EXISTS).
"""
from __future__ import annotations

from core.models import epoch_s

import json
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import pandas as pd

DB_FILE = Path(__file__).parent.parent / "data" / "ldz.db"
SCHEMA_VERSION = 1

SCHEMA = """
CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS accounts (
    login INTEGER, server TEXT, currency TEXT, leverage INTEGER, trade_mode INTEGER,
    last_seen TEXT, PRIMARY KEY (login, server));
CREATE TABLE IF NOT EXISTS symbols (
    symbol TEXT PRIMARY KEY, spec_json TEXT NOT NULL, updated_at TEXT);
CREATE TABLE IF NOT EXISTS candles_cache (
    symbol TEXT NOT NULL, timeframe TEXT NOT NULL, time INTEGER NOT NULL,
    open REAL, high REAL, low REAL, close REAL, tick_volume INTEGER, spread INTEGER,
    PRIMARY KEY (symbol, timeframe, time));
CREATE TABLE IF NOT EXISTS drawings (
    id INTEGER PRIMARY KEY AUTOINCREMENT, symbol TEXT, timeframe TEXT, kind TEXT,
    coordinates TEXT, style TEXT, replay_timestamp TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS layouts (name TEXT PRIMARY KEY, data TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS trades (
    id INTEGER PRIMARY KEY AUTOINCREMENT, mode TEXT, account INTEGER, server TEXT,
    symbol TEXT, data TEXT, created_at TEXT);
CREATE TABLE IF NOT EXISTS positions (
    ticket INTEGER PRIMARY KEY, account INTEGER, symbol TEXT, data TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS backtests (
    id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT, symbol TEXT, timeframe TEXT,
    start TEXT, end TEXT, strategy TEXT, strategy_version TEXT, smc_version TEXT,
    parameters TEXT, statistics TEXT);
CREATE TABLE IF NOT EXISTS backtest_trades (
    backtest_id INTEGER, trade_no INTEGER, data TEXT, PRIMARY KEY (backtest_id, trade_no));
CREATE TABLE IF NOT EXISTS smc_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT, symbol TEXT, timeframe TEXT, type TEXT,
    detected_at TEXT, data TEXT);
CREATE TABLE IF NOT EXISTS logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp TEXT, level TEXT, module TEXT,
    event TEXT, message TEXT, account INTEGER, symbol TEXT);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _json(o: Any) -> str:
    return json.dumps(o, default=str, ensure_ascii=False)


class Database:
    def __init__(self, path: Path = DB_FILE) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self.conn = sqlite3.connect(str(self.path), check_same_thread=False)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.migrate()

    def migrate(self) -> None:
        with self._lock, self.conn:
            self.conn.executescript(SCHEMA)
            cur = self.conn.execute("SELECT version FROM schema_version").fetchone()
            if cur is None:
                self.conn.execute("INSERT INTO schema_version VALUES (?)", (SCHEMA_VERSION,))

    def close(self) -> None:
        self.conn.close()

    # -- velas ------------------------------------------------------------
    def upsert_candles(self, symbol: str, timeframe: str, df: pd.DataFrame) -> int:
        t = pd.Series(epoch_s(df["time"]))
        rows = list(zip([symbol] * len(df), [timeframe] * len(df), t.tolist(),
                        df["open"].astype(float), df["high"].astype(float), df["low"].astype(float),
                        df["close"].astype(float),
                        df.get("tick_volume", pd.Series([0] * len(df))).astype(int),
                        df.get("spread", pd.Series([0] * len(df))).astype(int)))
        with self._lock, self.conn:
            self.conn.executemany(
                "INSERT OR REPLACE INTO candles_cache VALUES (?,?,?,?,?,?,?,?,?)", rows)
        return len(rows)

    def load_candles(self, symbol: str, timeframe: str, start: Optional[datetime] = None,
                     end: Optional[datetime] = None) -> pd.DataFrame:
        q = ("SELECT time, open, high, low, close, tick_volume, spread FROM candles_cache "
             "WHERE symbol=? AND timeframe=?")
        args: list = [symbol, timeframe]
        if start:
            q += " AND time>=?"; args.append(int(start.timestamp()))
        if end:
            q += " AND time<=?"; args.append(int(end.timestamp()))
        with self._lock:
            df = pd.read_sql_query(q + " ORDER BY time", self.conn, params=args)
        df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
        return df

    # -- símbolos / cuentas / settings ---------------------------------------
    def save_symbol_spec(self, spec: dict) -> None:
        with self._lock, self.conn:
            self.conn.execute("INSERT OR REPLACE INTO symbols VALUES (?,?,?)",
                              (spec["symbol"], _json(spec), _now()))

    def load_symbol_spec(self, symbol: str) -> Optional[dict]:
        r = self.conn.execute("SELECT spec_json FROM symbols WHERE symbol=?", (symbol,)).fetchone()
        return json.loads(r[0]) if r else None

    def save_account(self, login, server, currency, leverage, trade_mode) -> None:
        with self._lock, self.conn:
            self.conn.execute("INSERT OR REPLACE INTO accounts VALUES (?,?,?,?,?,?)",
                              (login, server, currency, leverage, trade_mode, _now()))

    def set_setting(self, key: str, value: Any) -> None:
        with self._lock, self.conn:
            self.conn.execute("INSERT OR REPLACE INTO settings VALUES (?,?)", (key, _json(value)))

    def get_setting(self, key: str, default: Any = None) -> Any:
        r = self.conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return json.loads(r[0]) if r else default

    # -- dibujos -----------------------------------------------------------
    def save_drawing(self, symbol, timeframe, kind, coordinates, style, replay_timestamp=None,
                     drawing_id: Optional[int] = None) -> int:
        with self._lock, self.conn:
            if drawing_id is None:
                cur = self.conn.execute(
                    "INSERT INTO drawings (symbol,timeframe,kind,coordinates,style,replay_timestamp,"
                    "created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
                    (symbol, timeframe, kind, _json(coordinates), _json(style),
                     str(replay_timestamp) if replay_timestamp else None, _now(), _now()))
                return int(cur.lastrowid)
            self.conn.execute("UPDATE drawings SET coordinates=?, style=?, updated_at=? WHERE id=?",
                              (_json(coordinates), _json(style), _now(), drawing_id))
            return drawing_id

    def load_drawings(self, symbol: str, timeframe: Optional[str] = None) -> list[dict]:
        q, a = "SELECT * FROM drawings WHERE symbol=?", [symbol]
        if timeframe:
            q += " AND timeframe=?"; a.append(timeframe)
        cur = self.conn.execute(q, a)
        cols = [c[0] for c in cur.description]
        out = []
        for row in cur.fetchall():
            d = dict(zip(cols, row))
            d["coordinates"] = json.loads(d["coordinates"])
            d["style"] = json.loads(d["style"])
            out.append(d)
        return out

    def delete_drawing(self, drawing_id: int) -> None:
        with self._lock, self.conn:
            self.conn.execute("DELETE FROM drawings WHERE id=?", (drawing_id,))

    # -- operaciones y backtests ------------------------------------------------
    def save_trade(self, mode: str, account, server, symbol, data: dict) -> int:
        with self._lock, self.conn:
            cur = self.conn.execute(
                "INSERT INTO trades (mode,account,server,symbol,data,created_at) VALUES (?,?,?,?,?,?)",
                (mode, account, server, symbol, _json(data), _now()))
            return int(cur.lastrowid)

    def save_backtest(self, meta: dict, statistics: dict, trades: list[dict]) -> int:
        with self._lock, self.conn:
            cur = self.conn.execute(
                "INSERT INTO backtests (created_at,symbol,timeframe,start,end,strategy,strategy_version,"
                "smc_version,parameters,statistics) VALUES (?,?,?,?,?,?,?,?,?,?)",
                (_now(), meta["symbol"], meta["timeframe"], str(meta["start"]), str(meta["end"]),
                 meta["strategy"], meta["strategy_version"], meta["smc_version"],
                 _json(meta["parameters"]), _json(statistics)))
            bid = int(cur.lastrowid)
            self.conn.executemany("INSERT INTO backtest_trades VALUES (?,?,?)",
                                  [(bid, i, _json(t)) for i, t in enumerate(trades)])
            return bid

    def load_backtest(self, backtest_id: int) -> Optional[dict]:
        cur = self.conn.execute("SELECT * FROM backtests WHERE id=?", (backtest_id,))
        row = cur.fetchone()
        if not row:
            return None
        d = dict(zip([c[0] for c in cur.description], row))
        d["parameters"] = json.loads(d["parameters"])
        d["statistics"] = json.loads(d["statistics"])
        d["trades"] = [json.loads(r[0]) for r in self.conn.execute(
            "SELECT data FROM backtest_trades WHERE backtest_id=? ORDER BY trade_no", (backtest_id,))]
        return d

    def list_backtests(self) -> list[tuple]:
        return self.conn.execute(
            "SELECT id, created_at, symbol, timeframe, strategy, strategy_version FROM backtests "
            "ORDER BY id DESC").fetchall()

    def save_smc_events(self, symbol: str, timeframe: str, events: list) -> None:
        rows = [(symbol, timeframe, e.type, e.timestamp.isoformat(),
                 _json({"direction": e.direction, "price": e.price, "reason": e.reason}))
                for e in events]
        with self._lock, self.conn:
            self.conn.executemany(
                "INSERT INTO smc_events (symbol,timeframe,type,detected_at,data) VALUES (?,?,?,?,?)", rows)

    def log(self, level, module, event, message, account=None, symbol=None) -> None:
        with self._lock, self.conn:
            self.conn.execute(
                "INSERT INTO logs (timestamp,level,module,event,message,account,symbol) "
                "VALUES (?,?,?,?,?,?,?)", (_now(), level, module, event, message, account, symbol))
