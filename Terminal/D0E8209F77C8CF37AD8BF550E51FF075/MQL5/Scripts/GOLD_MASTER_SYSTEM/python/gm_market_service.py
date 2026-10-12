"""Multi-asset analytics for Deriv and the replay terminal. Read-only MT5 access.

Usage: python gm_market_service.py --once [--export-bars]
       python gm_market_service.py --interval 1
No execution endpoints, model promotion or writes to the legacy EA bridge.
"""
import argparse
from collections import deque
from datetime import datetime, timezone, timedelta
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import time

import numpy as np
import pandas as pd
from gm_feed import DXYFeed, TickCursor, quote_valid, resolve_symbol
from gm_runtime import InstanceLock, RetrySchedule
from gm_small_account import feasibility

HERE = Path(__file__).resolve().parent
RUNTIME = HERE / "runtime"
PROFILES = {
    "gold": ("XAUUSD", "XAUUSDmicro"),
    "nasdaq": ("USTECH", "US Tech 100", "US_TECH100", "USTEC", "NAS100", "US100"),
    "bitcoin": ("BTCUSD",),
    "ethereum": ("ETHUSD",),
    "btceth": ("BTCETH",),
    "dxy": ("DXYUSD", "USDX", "DXY"),
}
SPEC_FIELDS = ("name", "description", "point", "digits", "trade_tick_size", "trade_tick_value",
               "trade_tick_value_profit", "trade_tick_value_loss", "trade_contract_size", "volume_min",
               "volume_max", "volume_step", "trade_stops_level", "trade_freeze_level", "trade_mode",
               "currency_profit", "currency_margin", "filling_mode", "swap_mode", "swap_long", "swap_short")


def atomic_json(path, obj):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(obj, indent=2, ensure_ascii=False, allow_nan=False), encoding="utf-8")
    # Windows readers can briefly deny replacement while a dashboard opens JSON.
    for attempt in range(8):
        try:
            os.replace(tmp, path)
            break
        except PermissionError:
            if attempt == 7: raise
            time.sleep(.01 * 2**attempt)


def smc_snapshot(frame, point):
    """Reuse exactly the trainer's causal SMC implementation on closed bars."""
    trainer = HERE.parent / "replay_terminal"
    if str(trainer) not in sys.path:
        sys.path.insert(0, str(trainer))
    from core.models import bars_from_df
    from smc.smc_engine import SMCEngine, SMCConfig
    engine = SMCEngine("M5", SMCConfig(), point)
    for bar in bars_from_df(frame):
        engine.on_bar(bar)
    snap = engine.snapshot(engine.last_close_time)
    event = snap.events[-1] if snap.events else None
    return {"state": snap.state, "asof": engine.last_close_time.isoformat(),
            "event": {"kind": event.type, "direction": event.direction, "price": event.price,
                      "known_at": event.timestamp.isoformat()} if event else None,
            "zones": [{"kind": "FVG", "direction": g.direction, "top": g.top, "bottom": g.bottom,
                       "known_at": g.detected_at.isoformat(), "status": state}
                      for g, state in snap.fvgs if state in ("OPEN", "PARTIALLY_FILLED")][-8:],
            "execution": "analysis_only", "validated_edge": False}


class MarketMonitor:
    def __init__(self, api, runtime=RUNTIME):
        self.api, self.runtime = api, Path(runtime)
        self.symbols = {asset: resolve_symbol(api, aliases, os.getenv("GM_" + asset.upper() + "_SYMBOL"))
                        for asset, aliases in PROFILES.items()}
        self.dxy = DXYFeed(api)
        self.gold_micro = resolve_symbol(api, ("XAUUSDmicro",), os.getenv("GM_GOLD_MICRO_SYMBOL"))
        self.cursors = {s: TickCursor() for s in self.symbols.values() if s}
        self.ticks = {s: deque(maxlen=100000) for s in self.cursors}
        self.frames, self.analysis, self.last_refresh = {}, {}, 0.0
        self.identity = None

    def refresh_bars(self):
        for symbol in self.cursors:
            raw = self.api.copy_rates_from_pos(symbol, self.api.TIMEFRAME_M5, 1, 800)
            if raw is None or len(raw) < 100:
                self.frames.pop(symbol, None)
                self.analysis[symbol] = {"status": "insufficient_bars"}
                continue
            frame = pd.DataFrame(raw)
            frame["time"] = pd.to_datetime(frame.time, unit="s", utc=True)
            frame = frame.sort_values("time").drop_duplicates("time")
            self.frames[symbol] = frame
            spec = self.api.symbol_info(symbol)
            self.analysis[symbol] = smc_snapshot(frame, spec.point)

    def sample(self, now=None):
        now = time.time() if now is None else now
        terminal = self.api.terminal_info()
        if terminal is None or not terminal.connected:
            return {"schema": 1, "ts": now, "status": "disconnected", "assets": {}, "execution": "disabled"}
        # Reset caches on account/server change without writing any account identifier.
        account = self.api.account_info()
        identity = (account.login, account.server) if account else None
        if self.identity is not None and identity != self.identity:
            self.__init__(self.api, self.runtime)
        self.identity = identity
        if now - self.last_refresh >= 15:
            self.refresh_bars()
            self.last_refresh = now
        dxy = self.dxy.quote(now)
        out = {"schema": 1, "ts": now, "status": "connected", "execution": "disabled",
               "dxy": {"value": dxy.value, "source": dxy.source, "valid": dxy.valid}, "assets": {}}
        for asset, symbol in self.symbols.items():
            if not symbol:
                out["assets"][asset] = {"status": "symbol_unresolved", "override": "GM_" + asset.upper() + "_SYMBOL"}
                continue
            cursor = self.cursors[symbol]
            begin = max(cursor.last_msc / 1000, now - 60) if cursor.last_msc else now - 5
            gap = bool(cursor.last_msc and now - cursor.last_msc / 1000 > 60)
            raw = self.api.copy_ticks_range(symbol, datetime.fromtimestamp(begin, timezone.utc),
                                            datetime.fromtimestamp(now, timezone.utc), self.api.COPY_TICKS_ALL)
            if raw is not None:
                for row in cursor.take(raw):
                    b, a, stamp = float(row["bid"]), float(row["ask"]), int(row["time_msc"]) / 1000
                    if math.isfinite(b) and math.isfinite(a) and 0 < b <= a:
                        self.ticks[symbol].append((stamp, (b+a)/2, a-b))
            recent = [t for t in self.ticks[symbol] if now - 60 <= t[0] <= now]
            quote = self.api.symbol_info_tick(symbol)
            valid = quote_valid(quote, now)
            spec = self.api.symbol_info(symbol)
            record = {"symbol": symbol, "status": "fresh" if valid else "stale", "tick_gap": gap,
                      "tick_read_ok": raw is not None, "tick_count_60s": len(recent),
                      "quote_age_s": round(now - quote.time_msc / 1000, 3) if quote else None,
                      "bid": quote.bid if valid else None, "ask": quote.ask if valid else None,
                      "spread": quote.ask - quote.bid if valid else None,
                      "spec": {k: getattr(spec, k, None) for k in SPEC_FIELDS},
                      "smc": self.analysis.get(symbol, {}), "ret_60s_bp": None}
            if len(recent) >= 2:
                record["observed_window_s"] = recent[-1][0] - recent[0][0]
                # Do not label a five second warm-up window as a sixty second move.
                if valid and record["observed_window_s"] >= 55:
                    record["ret_60s_bp"] = 10000 * math.log(recent[-1][1] / recent[0][1])
            frame = self.frames.get(symbol)
            dx = self.frames.get(self.symbols.get("dxy"))
            if frame is not None:
                record["bars_count"] = len(frame)
                record["bars_last_close"] = (frame.time.iloc[-1] + pd.Timedelta(minutes=5)).isoformat()
                record["bars_fresh"] = 0 <= now - (frame.time.iloc[-1].timestamp()+300) <= 360
                if asset in ("gold", "nasdaq", "bitcoin", "ethereum", "btceth"):
                    ranges = (frame.high-frame.low).tail(15)
                    illustrative_stop = float(ranges.mean()*1.5) if len(ranges)==15 else None
                    record["small_account_10usd"] = feasibility(self.api,symbol,10.0,1.0,illustrative_stop,now)
                    record["small_account_10usd"]["stop_basis"] = "1.5x mean M5 range, illustrative only"
                    if asset == "gold" and self.gold_micro:
                        record["small_account_10usd_micro"] = feasibility(
                            self.api,self.gold_micro,10.0,1.0,illustrative_stop,now)
                        record["small_account_10usd_micro"]["stop_basis"] = "same illustrative gold price distance"
                        record["small_account_6usd"] = feasibility(
                            self.api,symbol,6.0,1.0,illustrative_stop,now)
                        record["small_account_6usd_micro"] = feasibility(
                            self.api,self.gold_micro,6.0,1.0,illustrative_stop,now)
            if frame is not None and dx is not None and asset != "dxy":
                joined = pd.concat([frame.set_index("time").close.pct_change(),
                                    dx.set_index("time").close.pct_change()], axis=1, join="inner").dropna().tail(120)
                if len(joined) >= 60 and (joined.std() > 0).all():
                    record["dxy_corr_m5"] = float(joined.corr().iloc[0, 1])
                    record["dxy_beta_m5"] = float(joined.iloc[:, 0].cov(joined.iloc[:, 1]) / joined.iloc[:, 1].var())
                    record["dxy_samples"] = len(joined)
            out["assets"][asset] = record
        return out

    def export_bars(self):
        """Immutable research dataset with contract metadata and content hashes."""
        folder = self.runtime / "datasets" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        folder.mkdir(parents=True, exist_ok=False)
        manifest = {"source": "MT5 closed M5 bars", "files": [], "costs": "historical spread; commission/swap not calibrated"}
        for i, (symbol, frame) in enumerate(self.frames.items()):
            path = folder / f"asset_{i}_M5.csv"
            frame.to_csv(path, index=False)
            spec = self.api.symbol_info(symbol)
            manifest["files"].append({"symbol": symbol, "file": path.name, "rows": len(frame),
                                      "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                                      "spec": {k: getattr(spec, k, None) for k in SPEC_FIELDS}})
        atomic_json(folder / "manifest.json", manifest)
        return str(folder)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--once", action="store_true")
    p.add_argument("--export-bars", action="store_true")
    p.add_argument("--interval", type=float, default=1)
    p.add_argument("--terminal", default=os.getenv("GM_TERMINAL_PATH"))
    args = p.parse_args()
    if not math.isfinite(args.interval) or args.interval < .25:
        p.error("interval must be >= 0.25 seconds")
    import MetaTrader5 as mt5
    lock = InstanceLock(RUNTIME / "observer.lock")
    try:
        lock.__enter__()
    except RuntimeError as exc:
        print(str(exc))
        return 3
    monitor, retry = None, RetrySchedule()
    started, cycles = time.monotonic(), 0
    try:
        while True:
            start = time.monotonic()
            try:
                if monitor is None and retry.ready(start):
                    initialized = mt5.initialize(args.terminal, timeout=10000) if args.terminal else mt5.initialize(timeout=10000)
                    terminal = mt5.terminal_info() if initialized else None
                    if terminal is not None and terminal.connected:
                        monitor = MarketMonitor(mt5)
                        retry.reset()
                    else:
                        mt5.shutdown()
                        retry.failed(start)
                snapshot = monitor.sample() if monitor else {
                    "schema": 1, "ts": time.time(), "status": "reconnecting",
                    "assets": {}, "execution": "disabled"}
                if snapshot["status"] == "disconnected":
                    monitor = None
                    mt5.shutdown()
                    retry.failed(start)
            except Exception as exc:
                monitor = None
                mt5.shutdown()
                retry.failed(start)
                snapshot = {"schema": 1, "ts": time.time(), "status": "error", "error": str(exc),
                            "assets": {}, "execution": "disabled"}
            cycles += 1
            snapshot["service"] = {"pid": os.getpid(), "cycles": cycles,
                                   "uptime_s": round(time.monotonic()-started, 1),
                                   "cycle_ms": round(1000*(time.monotonic()-start), 1),
                                   "retry_in_s": round(max(0, retry.next_at-time.monotonic()), 1),
                                   "consecutive_failures": retry.failures}
            atomic_json(RUNTIME / "market_snapshot.json", snapshot)
            if args.once:
                if args.export_bars and monitor and monitor.frames:
                    print(monitor.export_bars())
                print(json.dumps({"status": snapshot["status"], "symbols": monitor.symbols if monitor else {}}))
                return 0 if snapshot["status"] == "connected" else 2
            time.sleep(max(.05, args.interval-(time.monotonic()-start)))
    except KeyboardInterrupt:
        return 0
    finally:
        mt5.shutdown()
        atomic_json(RUNTIME / "market_snapshot.json", {"schema": 1, "ts": time.time(),
                    "status": "stopped", "assets": {}, "execution": "disabled"}) if not args.once else None
        lock.__exit__()


if __name__ == "__main__":
    raise SystemExit(main())
