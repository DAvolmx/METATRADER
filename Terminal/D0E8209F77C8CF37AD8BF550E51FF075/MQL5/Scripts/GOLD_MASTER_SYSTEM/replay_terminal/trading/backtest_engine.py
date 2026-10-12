"""
trading/backtest_engine.py — Backtesting vela a vela sin look-ahead.

Bucle (por cada vela base, en orden cronológico):
  1. Apertura de la vela i: se ejecutan las órdenes pendientes emitidas al
     cierre de i-1 (execution = NEXT_OPEN). El lotaje se recalcula con el
     precio REAL de entrada. Si la apertura ya está más allá del SL, la orden
     se cancela.
  2. Durante la vela i: SL/TP con política de ambigüedad (PaperTradingEngine).
  3. Cierre de la vela i: SMC + Top-Down reciben la vela cerrada.
  4. La estrategia decide con información hasta el cierre de i.
  5. Se registra la equity al cierre de i.
Nunca se usa df.shift(-1) ni índices futuros. MT5 no interviene.
"""
from __future__ import annotations

import csv
import json
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional

import pandas as pd

from core.models import Bar, bars_from_df, tf_delta
from smc.smc_engine import SMC_ENGINE_VERSION, SMCConfig, SMCEngine
from smc.top_down import TopDownAnalyzer
from trading.paper_engine import PaperConfig, PaperTradingEngine
from trading.position_sizer import size_by_risk
from trading.risk_manager import take_profit_rr
from trading.statistics import compute_statistics
from trading.trade_models import SymbolSpec, Trade

BACKTEST_ENGINE_VERSION = "1.2"   # 1.2: inicio de operaciones tras calentamiento


@dataclass
class BacktestConfig:
    symbol: str
    timeframe: str
    initial_balance: float = 10_000.0
    spread_mode: str = "HISTORICAL"     # HISTORICAL | FIXED
    fixed_spread_points: int = 0
    slippage_points: float = 0.0
    commission_per_lot: float = 0.0
    apply_swap: bool = True             # swap real del símbolo (trading/swap.py)
    ambiguity: str = "WORST_CASE"
    tick_fallback: Optional[str] = "WORST_CASE"   # solo para ambiguity=TICK_DATA
    execution_delay_bars: int = 1       # 1 = apertura de la vela siguiente
    topdown_tfs: tuple = ("D1", "H4", "H1")
    smc: dict = field(default_factory=dict)
    trade_start: Optional[datetime] = None  # pre-start bars warm SMC; no orders
    challenge_goal: Optional[float] = None


@dataclass
class PendingOrder:
    direction: str
    stop_loss: float
    rr: Optional[float]
    take_profit: Optional[float]
    risk_pct: Optional[float]
    volume: Optional[float]
    comment: str
    signal_time: datetime
    execute_at_index: int


@dataclass
class BacktestResult:
    config: BacktestConfig
    strategy: str
    strategy_version: str
    parameters: dict
    trades: list[Trade]
    equity: pd.DataFrame
    statistics: dict
    start: datetime
    end: datetime
    rejected_orders: list[dict]
    currency: str
    smc_version: str = SMC_ENGINE_VERSION
    engine_version: str = BACKTEST_ENGINE_VERSION

    def meta(self) -> dict:
        return {"symbol": self.config.symbol, "timeframe": self.config.timeframe,
                "start": self.start, "end": self.end, "strategy": self.strategy,
                "strategy_version": self.strategy_version, "smc_version": self.smc_version,
                "parameters": {"strategy": self.parameters, "config": asdict(self.config),
                               "engine_version": self.engine_version}}

    def trades_as_dicts(self) -> list[dict]:
        return [{**asdict(t), "outcome": t.outcome} for t in self.trades]

    def export(self, folder: Path) -> dict[str, Path]:
        folder.mkdir(parents=True, exist_ok=True)
        paths = {}
        rows = self.trades_as_dicts()
        p = folder / "trades.csv"
        with open(p, "w", newline="", encoding="utf-8") as f:
            if rows:
                w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
                w.writeheader()
                w.writerows(rows)
        paths["trades_csv"] = p
        p = folder / "equity.csv"
        self.equity.to_csv(p, index=False)
        paths["equity_csv"] = p
        p = folder / "backtest.json"
        with open(p, "w", encoding="utf-8") as f:
            json.dump({"meta": self.meta(), "statistics": self.statistics, "trades": rows,
                       "currency": self.currency}, f, default=str, indent=2, ensure_ascii=False)
        paths["json"] = p
        return paths


class BacktestContext:
    """Lo único que la estrategia puede ver o hacer."""

    def __init__(self, bt: "BacktestEngine") -> None:
        self._bt = bt

    @property
    def bar(self) -> Bar:
        return self._bt.bars[self._bt.i]

    @property
    def index(self) -> int:
        return self._bt.i

    @property
    def time(self) -> datetime:
        """Instante actual = cierre de la vela actual."""
        return self.bar.time + self._bt.delta

    @property
    def history(self) -> list[Bar]:
        return self._bt.bars[: self._bt.i + 1]

    @property
    def smc(self) -> SMCEngine:
        return self._bt.smc

    @property
    def topdown(self) -> TopDownAnalyzer:
        return self._bt.topdown

    @property
    def spec(self) -> SymbolSpec:
        return self._bt.spec

    @property
    def open_trades(self) -> list[Trade]:
        return self._bt.paper.open_trades

    @property
    def pending_orders(self) -> list[PendingOrder]:
        return self._bt.pending

    @property
    def balance(self) -> float:
        return self._bt.paper.balance

    def _order(self, direction, stop_loss, rr=None, take_profit=None, risk_pct=None,
               volume=None, comment="") -> None:
        if rr is None and take_profit is None:
            raise ValueError("Indica rr o take_profit")
        self._bt.pending.append(PendingOrder(
            direction, stop_loss, rr, take_profit, risk_pct, volume, comment, self.time,
            self._bt.i + self._bt.cfg.execution_delay_bars))

    def buy(self, stop_loss: float, **kw) -> None:
        self._order("BUY", stop_loss, **kw)

    def sell(self, stop_loss: float, **kw) -> None:
        self._order("SELL", stop_loss, **kw)

    def close_all(self) -> None:
        self._bt.close_all_requested = True


class BacktestEngine:
    def __init__(self, df: pd.DataFrame, spec: SymbolSpec, config: BacktestConfig) -> None:
        if config.execution_delay_bars < 1:
            raise ValueError("La señal requiere al menos una vela de retraso de ejecución")
        self.df = df
        self.spec = spec
        self.cfg = config
        self.delta = tf_delta(config.timeframe)
        self.bars = bars_from_df(df)
        smc_cfg = SMCConfig(**config.smc) if config.smc else SMCConfig.load()
        self.smc = SMCEngine(config.timeframe, smc_cfg, spec.point)
        self.topdown = TopDownAnalyzer(config.timeframe, config.topdown_tfs, smc_cfg, spec.point)
        self.paper = PaperTradingEngine(
            spec, PaperConfig(config.initial_balance, config.ambiguity,
                              config.commission_per_lot, config.slippage_points,
                              config.apply_swap, config.tick_fallback),
            synthetic=bool(len(df) and "synthetic" in df and df["synthetic"].any()))
        self.pending: list[PendingOrder] = []
        self.rejected: list[dict] = []
        self.i = 0
        self.close_all_requested = False

    def _spread(self, bar: Bar) -> int:
        return self.cfg.fixed_spread_points if self.cfg.spread_mode == "FIXED" else bar.spread

    def _execute_pending(self, bar: Bar) -> None:
        keep = []
        for o in self.pending:
            if o.execute_at_index > self.i:
                keep.append(o)
                continue
            slip = self.cfg.slippage_points * self.spec.point
            entry_est = self.paper.ask + slip if o.direction == "BUY" else self.paper.bid - slip
            try:
                volume = o.volume
                if volume is None:
                    res = size_by_risk(self.paper.balance, o.risk_pct or 1.0, o.direction, entry_est,
                                       o.stop_loss, self.spec, self.paper.profit_fn)
                    if not res.ok:
                        raise ValueError(res.reason)
                    volume = res.volume
                tp = o.take_profit
                if tp is None:
                    tp = take_profit_rr(o.direction, entry_est, o.stop_loss, o.rr, self.spec.digits)
                self.paper.open(o.direction, volume, round(o.stop_loss, self.spec.digits), tp,
                                o.comment, o.signal_time)
            except ValueError as e:
                self.rejected.append({"time": bar.time, "direction": o.direction,
                                      "signal_time": o.signal_time, "reason": str(e)})
        self.pending = keep

    def run(self, strategy) -> BacktestResult:
        if not self.bars:
            raise ValueError("Sin velas para el backtest")
        equity_rows = []
        ctx = BacktestContext(self)
        trade_start = None
        if self.cfg.trade_start is not None:
            mark = pd.Timestamp(self.cfg.trade_start)
            trade_start = (mark.tz_localize("UTC") if mark.tzinfo is None
                           else mark.tz_convert("UTC")).to_pydatetime()
        for i, bar in enumerate(self.bars):
            self.i = i
            close_t = bar.time + self.delta
            # 1) apertura
            self.paper.update_quote(bar.open, self._spread(bar), bar.time)
            if self.close_all_requested:
                self.paper.close(reason="MANUAL")
                self.close_all_requested = False
            self._execute_pending(bar)
            # 2) durante la vela
            eff = bar if self.cfg.spread_mode == "HISTORICAL" else Bar(
                bar.time, bar.open, bar.high, bar.low, bar.close, bar.tick_volume,
                self.cfg.fixed_spread_points, bar.first_extreme, bar.synthetic)
            self.paper.on_bar(eff, close_t)
            # 3) análisis con la vela cerrada
            self.smc.on_bar(bar)
            self.topdown.on_base_bar(bar)
            # 4) estrategia
            if trade_start is None or close_t >= trade_start:
                strategy.on_bar(ctx)
            # 5) equity
            equity_rows.append({"time": close_t, "balance": self.paper.balance,
                                "equity": round(self.paper.equity, 2)})
        # Cierre de posiciones abiertas al final de los datos
        self.paper.close(reason="END")
        if equity_rows:
            equity_rows[-1]["balance"] = equity_rows[-1]["equity"] = self.paper.balance
        eq = pd.DataFrame(equity_rows)
        eq["time"] = pd.to_datetime(eq["time"], utc=True)
        stats = compute_statistics(self.paper.trades, eq, self.cfg.initial_balance)
        stats["currency"] = self.paper.currency
        stats["rejected_orders"] = len(self.rejected)
        stats["swap_total"] = round(sum(t.swap for t in self.paper.closed_trades), 2)
        stats["swap_status"] = ("NO SOPORTADO (modo de swap del símbolo)" if self.paper.swap_unsupported
                                else "aplicado" if self.cfg.apply_swap and self.paper.profit_fn else "desactivado")
        stats["ambiguous_bars"] = self.paper.ambiguous_bars
        stats["ambiguous_fallbacks"] = self.paper.ambiguous_fallbacks
        return BacktestResult(self.cfg, strategy.name, strategy.version, dict(strategy.params),
                              self.paper.closed_trades, eq, stats, self.bars[0].time,
                              self.bars[-1].time + self.delta, self.rejected, self.paper.currency)
