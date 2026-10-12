"""
simulation/sim_session.py
=========================
Sesión de práctica sobre mercado SINTÉTICO: abrir/cerrar operaciones
virtuales, SL/TP, P&L flotante y cerrado.

Barrera de seguridad: este módulo NO importa MetaTrader5 ni el ejecutor real.
Es imposible que envíe órdenes al broker.

Precios
-------
Las velas de MT5 se construyen con BID. Por tanto:
  BUY  entra al ASK = bid + spread*point   y sale al BID
  SELL entra al BID                         y sale al ASK
El spread de cada vela sintética viene del histórico real remuestreado.

Resolución SL/TP
----------------
Cada vela sintética sabe qué extremo tocó primero (first_extreme), así que
si en la misma vela se tocan SL y TP se resuelve sin suponer. Si la vela
abre más allá del SL/TP (gap), se llena al precio de apertura.
"""

from __future__ import annotations

import csv
from dataclasses import dataclass, field, asdict
from datetime import datetime
from pathlib import Path
from typing import Optional

from trading.trade_models import SymbolSpec
from simulation.synthetic_market import (
    SyntheticBar,
    SyntheticMarket,
    TimeframeAggregator,
    TIMEFRAME_SECONDS,
)


@dataclass
class SimTrade:
    id: int
    direction: str               # "BUY" | "SELL"
    volume: float
    entry_time: datetime
    entry_price: float
    sl: Optional[float] = None
    tp: Optional[float] = None
    exit_time: Optional[datetime] = None
    exit_price: Optional[float] = None
    exit_reason: Optional[str] = None   # "SL" | "TP" | "MANUAL"
    status: str = "OPEN"
    synthetic: bool = True

    def price_diff(self, exit_price: float) -> float:
        d = exit_price - self.entry_price
        return d if self.direction == "BUY" else -d


class SimSession:
    def __init__(
        self,
        market: SyntheticMarket,
        spec: SymbolSpec,
        higher_timeframes: tuple[str, ...] = ("M5", "M15", "H1", "H4"),
    ) -> None:
        self.market = market
        self.spec = spec
        base = market.calib.timeframe
        self.aggregators: dict[str, TimeframeAggregator] = {
            tf: TimeframeAggregator(tf, base)
            for tf in higher_timeframes
            if TIMEFRAME_SECONDS[tf] > TIMEFRAME_SECONDS[base]
        }
        self.base_bars: list[SyntheticBar] = []
        self.trades: list[SimTrade] = []
        self._next_id = 1
        self._bid = market.calib.last_close
        self._spread = market.calib.last_spread
        self._time = market.calib.last_time

    # -- precios ----------------------------------------------------------
    @property
    def bid(self) -> float:
        return self._bid

    @property
    def ask(self) -> float:
        return round(self._bid + self._spread * self.spec.point, self.spec.digits)

    @property
    def time(self) -> datetime:
        return self._time

    @property
    def open_trades(self) -> list[SimTrade]:
        return [t for t in self.trades if t.status == "OPEN"]

    @property
    def closed_trades(self) -> list[SimTrade]:
        return [t for t in self.trades if t.status == "CLOSED"]

    # -- avance -----------------------------------------------------------
    def next_bar(self) -> SyntheticBar:
        bar = self.market.step()
        self._check_exits(bar)
        for agg in self.aggregators.values():
            agg.update(bar)
        self.base_bars.append(bar)
        # La vela está cerrada: el precio actual es su cierre.
        self._bid = bar.close
        self._spread = bar.spread
        # Hora actual = cierre de la vela
        self._time = bar.time + self.market.tf
        return bar

    # -- órdenes virtuales ------------------------------------------------
    def open_trade(
        self, direction: str, volume: float,
        sl: Optional[float] = None, tp: Optional[float] = None,
    ) -> SimTrade:
        direction = direction.upper()
        if direction not in ("BUY", "SELL"):
            raise ValueError("direction debe ser BUY o SELL")
        if volume <= 0:
            raise ValueError("El volumen debe ser > 0")

        entry = self.ask if direction == "BUY" else self.bid
        if direction == "BUY":
            if sl is not None and sl >= self.bid:
                raise ValueError(f"SL de BUY debe estar por debajo del BID ({self.bid})")
            if tp is not None and tp <= entry:
                raise ValueError(f"TP de BUY debe estar por encima del ASK ({entry})")
        else:
            if sl is not None and sl <= self.ask:
                raise ValueError(f"SL de SELL debe estar por encima del ASK ({self.ask})")
            if tp is not None and tp >= entry:
                raise ValueError(f"TP de SELL debe estar por debajo del BID ({entry})")

        trade = SimTrade(
            id=self._next_id, direction=direction, volume=volume,
            entry_time=self._time, entry_price=entry, sl=sl, tp=tp,
        )
        self._next_id += 1
        self.trades.append(trade)
        return trade

    def close_trade(self, trade_id: Optional[int] = None) -> list[SimTrade]:
        """Cierra una operación (o todas si trade_id es None) a precio actual."""
        closed = []
        for t in self.open_trades:
            if trade_id is None or t.id == trade_id:
                price = self.bid if t.direction == "BUY" else self.ask
                self._finalize(t, price, self._time, "MANUAL")
                closed.append(t)
        if trade_id is not None and not closed:
            raise ValueError(f"No hay operación abierta con id {trade_id}")
        return closed

    # -- P&L ----------------------------------------------------------------
    def floating(self, t: SimTrade) -> float:
        price = self.bid if t.direction == "BUY" else self.ask
        return t.price_diff(price)

    def points(self, price_diff: float) -> float:
        return round(price_diff / self.spec.point, 1)

    def money(self, t: SimTrade, price_diff: float) -> Optional[float]:
        k = self.spec.money_per_price_unit(t.volume)
        return None if k is None else round(price_diff * k, 2)

    def stats(self) -> dict:
        closed = self.closed_trades
        diffs = [t.price_diff(t.exit_price) for t in closed]
        moneys = [self.money(t, d) for t, d in zip(closed, diffs)]
        wins = sum(1 for d in diffs if d > 0)
        return {
            "trades": len(closed),
            "wins": wins,
            "losses": sum(1 for d in diffs if d < 0),
            "win_rate": round(100 * wins / len(closed), 1) if closed else None,
            "net_points": self.points(sum(diffs)) if closed else 0.0,
            "net_money": (
                round(sum(moneys), 2) if closed and all(m is not None for m in moneys) else None
            ),
        }

    # -- internos -----------------------------------------------------------
    def _finalize(self, t: SimTrade, price: float, when: datetime, reason: str) -> None:
        t.exit_price = round(price, self.spec.digits)
        t.exit_time = when
        t.exit_reason = reason
        t.status = "CLOSED"

    def _check_exits(self, bar: SyntheticBar) -> None:
        sp = bar.spread * self.spec.point
        close_time = bar.time + self.market.tf
        for t in self.open_trades:
            if t.direction == "BUY":       # sale al BID
                o, hi, lo = bar.open, bar.high, bar.low
                sl_hit = t.sl is not None and lo <= t.sl
                tp_hit = t.tp is not None and hi >= t.tp
                gap_sl = t.sl is not None and o <= t.sl
                gap_tp = t.tp is not None and o >= t.tp
                sl_first_extreme = "LOW"
            else:                           # sale al ASK
                o, hi, lo = bar.open + sp, bar.high + sp, bar.low + sp
                sl_hit = t.sl is not None and hi >= t.sl
                tp_hit = t.tp is not None and lo <= t.tp
                gap_sl = t.sl is not None and o >= t.sl
                gap_tp = t.tp is not None and o <= t.tp
                sl_first_extreme = "HIGH"

            if gap_sl:
                self._finalize(t, o, bar.time, "SL")
            elif gap_tp:
                self._finalize(t, o, bar.time, "TP")
            elif sl_hit and tp_hit:
                if bar.first_extreme == sl_first_extreme:
                    self._finalize(t, t.sl, close_time, "SL")
                else:
                    self._finalize(t, t.tp, close_time, "TP")
            elif sl_hit:
                self._finalize(t, t.sl, close_time, "SL")
            elif tp_hit:
                self._finalize(t, t.tp, close_time, "TP")

    # -- exportación ----------------------------------------------------------
    def export_trades_csv(self, path: Path) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", newline="", encoding="utf-8") as f:
            fields = list(SimTrade.__dataclass_fields__.keys()) + ["points", "money"]
            w = csv.DictWriter(f, fieldnames=fields)
            w.writeheader()
            for t in self.closed_trades:
                d = t.price_diff(t.exit_price)
                row = asdict(t)
                row["points"] = self.points(d)
                m = self.money(t, d)
                row["money"] = "N/A" if m is None else m
                w.writerow(row)
        return path
