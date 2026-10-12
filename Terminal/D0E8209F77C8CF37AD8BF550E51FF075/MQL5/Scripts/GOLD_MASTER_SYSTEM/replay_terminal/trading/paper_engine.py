"""
trading/paper_engine.py — PaperTradingEngine (operaciones VIRTUALES).

BARRERA ARQUITECTÓNICA: este módulo no importa MetaTrader5 ni mt5/execution.
Un test verifica que no aparece 'order_send' en el paquete trading/.

Precios: las velas de MT5 son BID.
  BUY  entra a ASK (+slippage) y sale a BID.
  SELL entra a BID (-slippage) y sale a ASK.

Ambigüedad OHLC (SL y TP dentro de la misma vela, sin ticks):
  WORST_CASE   -> se asume SL (por defecto)
  OPTIMISTIC   -> se asume TP
  CONSERVATIVE -> heurística por cuerpo: vela a favor => TP, en contra => SL
  TICK_DATA    -> aplica tick_fallback (por defecto WORST_CASE) porque
                  first_extreme no contiene la secuencia bid/ask completa.
                  Con tick_fallback=None se lanza error.
Swap: se aplica en cada rollover (trading/swap.py) si apply_swap=True.
first_extreme no permite determinar qué nivel de salida se alcanzó primero.
"""
from __future__ import annotations

from dataclasses import dataclass
import math
from decimal import Decimal
from datetime import datetime
from typing import Optional

from trading.swap import rollover_multiplier, swap_per_night
from trading.trade_models import ProfitFn, SymbolSpec, Trade, TradeStatus

AMBIGUITY_POLICIES = ("WORST_CASE", "OPTIMISTIC", "CONSERVATIVE", "TICK_DATA")


@dataclass
class PaperConfig:
    initial_balance: float = 10_000.0
    ambiguity: str = "WORST_CASE"
    commission_per_lot: float = 0.0     # ida y vuelta, en divisa de la cuenta
    slippage_points: float = 0.0
    apply_swap: bool = True
    tick_fallback: Optional[str] = "WORST_CASE"


class PaperTradingEngine:
    def __init__(self, spec: SymbolSpec, config: Optional[PaperConfig] = None,
                 profit_fn: Optional[ProfitFn] = None, synthetic: bool = False) -> None:
        self.spec = spec
        self.cfg = config or PaperConfig()
        if (not math.isfinite(self.cfg.initial_balance) or self.cfg.initial_balance <= 0
                or any(not math.isfinite(x) or x < 0 for x in
                       (self.cfg.commission_per_lot, self.cfg.slippage_points))):
            raise ValueError("Balance y costes deben ser finitos y válidos")
        if self.cfg.ambiguity not in AMBIGUITY_POLICIES:
            raise ValueError(f"Política desconocida: {self.cfg.ambiguity}")
        self.profit_fn = profit_fn or spec.default_profit_fn()
        # Sin conversión a dinero se contabiliza en PUNTOS (y se rotula así).
        self.currency = spec.account_currency if self.profit_fn else "PTS"
        self.synthetic = synthetic
        self.balance = self.cfg.initial_balance
        self.trades: list[Trade] = []
        self.stop_orders = []
        self._next_stop_id = 1
        self._next_id = 1
        self.bid: Optional[float] = None
        self.spread_points: int = 0
        self.time: Optional[datetime] = None
        self.swap_unsupported = False      # True si el modo de swap del símbolo no es calculable
        self._swap_checked: dict[int, datetime] = {}
        self.ambiguous_bars = 0
        self.ambiguous_fallbacks = 0

    # -- cotización ---------------------------------------------------------
    def update_quote(self, bid: float, spread_points: int, time: datetime) -> None:
        if not math.isfinite(bid) or bid <= 0 or not math.isfinite(spread_points) or spread_points < 0:
            raise ValueError("Cotización inválida")
        self.bid, self.spread_points, self.time = bid, int(spread_points), time

    @property
    def ask(self) -> Optional[float]:
        if self.bid is None:
            return None
        return round(self.bid + self.spread_points * self.spec.point, self.spec.digits)

    @property
    def open_trades(self) -> list[Trade]:
        return [t for t in self.trades if t.status == TradeStatus.OPEN]

    @property
    def closed_trades(self) -> list[Trade]:
        return [t for t in self.trades if t.status == TradeStatus.CLOSED]

    # -- dinero -------------------------------------------------------------
    def pnl(self, t: Trade, exit_price: float) -> float:
        if self.profit_fn:
            return self.profit_fn(t.direction, t.volume, t.entry_price, exit_price)
        return t.price_diff(exit_price) / self.spec.point

    def floating(self, t: Trade) -> Optional[float]:
        if self.bid is None:
            return None
        return self.pnl(t, self.bid if t.direction == "BUY" else self.ask)

    @property
    def equity(self) -> float:
        return self.balance + sum((self.floating(t) or 0.0) + t.swap - t.commission
                                  for t in self.open_trades)

    def _accrue_swap(self, until: datetime, price: Optional[float]) -> None:
        """Cobra/abona el swap de cada medianoche cruzada hasta `until`."""
        if not self.cfg.apply_swap or self.profit_fn is None:
            return
        for t in self.open_trades:
            prev = self._swap_checked.get(t.id, t.entry_time)
            if prev is None:
                continue
            mult = rollover_multiplier(prev, until, self.spec.swap_rollover3days)
            self._swap_checked[t.id] = max(prev, until)
            if mult == 0:
                continue
            night = swap_per_night(self.spec, t.direction, t.volume, t.entry_price,
                                   price if price is not None else t.entry_price)
            if night is None:
                self.swap_unsupported = True
                continue
            t.swap = round(t.swap + night * mult, 2)

    # -- órdenes ------------------------------------------------------------
    def open(self, direction: str, volume: float, stop_loss: Optional[float] = None,
             take_profit: Optional[float] = None, comment: str = "",
             signal_time: Optional[datetime] = None) -> Trade:
        direction = direction.upper()
        if direction not in ("BUY", "SELL"):
            raise ValueError("direction debe ser BUY o SELL")
        if self.bid is None:
            raise ValueError("No hay cotización (precio inválido)")
        if not math.isfinite(volume):
            raise ValueError("Volumen no finito")
        units = Decimal(str(volume)) / Decimal(str(self.spec.volume_step))
        if units != units.to_integral_value():
            raise ValueError("Volumen no alineado con volume_step")
        if any(x is not None and (not math.isfinite(x) or x <= 0) for x in (stop_loss, take_profit)):
            raise ValueError("SL/TP inválidos")
        if not (self.spec.volume_min - 1e-12 <= volume <= self.spec.volume_max + 1e-12):
            raise ValueError(f"Volumen fuera de rango [{self.spec.volume_min}, {self.spec.volume_max}]")
        slip = self.cfg.slippage_points * self.spec.point
        if direction == "BUY":
            entry = round(self.ask + slip, self.spec.digits)
            if stop_loss is not None and stop_loss >= self.bid:
                raise ValueError(f"SL de BUY debe estar por debajo del BID ({self.bid})")
            if take_profit is not None and take_profit <= entry:
                raise ValueError(f"TP de BUY debe estar por encima de la entrada ({entry})")
        else:
            entry = round(self.bid - slip, self.spec.digits)
            if stop_loss is not None and stop_loss <= self.ask:
                raise ValueError(f"SL de SELL debe estar por encima del ASK ({self.ask})")
            if take_profit is not None and take_profit >= entry:
                raise ValueError(f"TP de SELL debe estar por debajo de la entrada ({entry})")
        t = Trade(
            id=self._next_id, symbol=self.spec.symbol, direction=direction, volume=volume,
            entry_time=self.time, entry_price=entry, stop_loss=stop_loss,
            take_profit=take_profit, spread=self.spread_points * self.spec.point,
            slippage=slip, commission=self.cfg.commission_per_lot * volume,
            comment=comment, signal_time=signal_time, synthetic=self.synthetic,
        )
        self._next_id += 1
        self.trades.append(t)
        return t

    def queue_stop(self, order: dict) -> dict:
        order = dict(order, id=self._next_stop_id, status="PENDING")
        self._next_stop_id += 1
        self.stop_orders.append(order)
        return order

    def process_stops(self, bar, close_time):
        # OHLC cannot reveal intrabar order: adverse SL is applied conservatively,
        # TP on the trigger candle is deliberately deferred to the next candle.
        spread=bar.spread*self.spec.point
        for o in self.stop_orders:
            if o["status"]!="PENDING":continue
            buy=o["direction"]=="BUY"
            if not (bar.high+spread>=o["entry"] if buy else bar.low<=o["entry"]):continue
            bid=max(bar.open,o["entry"]-spread) if buy else min(bar.open,o["entry"])
            self.update_quote(bid,bar.spread,close_time)
            try:
                tr=self.open(o["direction"],o["volume"],o["sl"],o["tp"],o["setup"],o["created_time"])
                o.update(status="FILLED",trade_id=tr.id,fill=tr.entry_price)
                if tr.stop_loss is not None and (bar.low<=tr.stop_loss if buy else bar.high+spread>=tr.stop_loss):
                    self._finalize(tr,tr.stop_loss,close_time,"SL")
            except ValueError as e:o.update(status="REJECTED",reason=str(e))
        self.update_quote(bar.close,bar.spread,close_time)

    def close(self, trade_id: Optional[int] = None, reason: str = "MANUAL") -> list[Trade]:
        out = []
        if self.time is not None:
            self._accrue_swap(self.time, self.bid)
        for t in self.open_trades:
            if trade_id is None or t.id == trade_id:
                price = self.bid if t.direction == "BUY" else self.ask
                self._finalize(t, price, self.time, reason)
                out.append(t)
        if trade_id is not None and not out:
            raise ValueError(f"No hay operación abierta con id {trade_id}")
        return out

    def cancel_all(self) -> None:
        for t in self.open_trades:
            t.status = TradeStatus.CANCELLED

    # -- avance de vela -------------------------------------------------------
    def on_bar(self, bar, bar_close_time: datetime) -> list[Trade]:
        """
        Procesa una vela CERRADA: SL/TP, MAE/MFE. Solo afecta a operaciones
        abiertas antes del cierre de la vela. Deja la cotización en el cierre.
        """
        closed = []
        sp = bar.spread * self.spec.point
        self._accrue_swap(bar.time, bar.open)     # rollovers hasta la apertura de esta vela
        for t in self.open_trades:
            if t.direction == "BUY":
                o, hi, lo = bar.open, bar.high, bar.low
                worst, best = lo, hi
                sl_hit = t.stop_loss is not None and lo <= t.stop_loss
                tp_hit = t.take_profit is not None and hi >= t.take_profit
                gap_sl = t.stop_loss is not None and o <= t.stop_loss
                gap_tp = t.take_profit is not None and o >= t.take_profit
                sl_extreme, favorable = "LOW", bar.close >= bar.open
            else:
                o, hi, lo = bar.open + sp, bar.high + sp, bar.low + sp
                worst, best = hi, lo
                sl_hit = t.stop_loss is not None and hi >= t.stop_loss
                tp_hit = t.take_profit is not None and lo <= t.take_profit
                gap_sl = t.stop_loss is not None and o >= t.stop_loss
                gap_tp = t.take_profit is not None and o <= t.take_profit
                sl_extreme, favorable = "HIGH", bar.close <= bar.open

            exit_price = reason = None
            if gap_sl:
                exit_price, reason = o, "SL"
            elif gap_tp:
                exit_price, reason = o, "TP"
            elif sl_hit and tp_hit:
                sl_first = self._resolve_ambiguity(bar, sl_extreme, favorable)
                exit_price, reason = (t.stop_loss, "SL") if sl_first else (t.take_profit, "TP")
            elif sl_hit:
                exit_price, reason = t.stop_loss, "SL"
            elif tp_hit:
                exit_price, reason = t.take_profit, "TP"

            # MAE/MFE: la excursión no puede ir más allá del precio de salida
            w = t.price_diff(worst)
            b = t.price_diff(best)
            if exit_price is not None:
                x = t.price_diff(exit_price)
                if reason == "SL":
                    w = max(w, x)
                else:
                    b = min(b, x)
            t.mae = min(t.mae, w)
            t.mfe = max(t.mfe, b)

            if exit_price is not None:
                self._finalize(t, exit_price, bar_close_time, reason)
                closed.append(t)

        self.update_quote(bar.close, bar.spread, bar_close_time)
        return closed

    def on_tick(self, bid: float, ask: float, time: datetime) -> list[Trade]:
        """LIVE: SL/TP evaluados tick a tick con BID/ASK reales."""
        self._accrue_swap(time, bid)
        self.bid, self.time = bid, time
        self.spread_points = int(round((ask - bid) / self.spec.point))
        closed = []
        for t in self.open_trades:
            px = bid if t.direction == "BUY" else ask
            d = t.price_diff(px)
            t.mae, t.mfe = min(t.mae, d), max(t.mfe, d)
            if t.direction == "BUY":
                hit_sl = t.stop_loss is not None and bid <= t.stop_loss
                hit_tp = t.take_profit is not None and bid >= t.take_profit
            else:
                hit_sl = t.stop_loss is not None and ask >= t.stop_loss
                hit_tp = t.take_profit is not None and ask <= t.take_profit
            if hit_sl or hit_tp:
                self._finalize(t, px, time, "SL" if hit_sl else "TP")
                closed.append(t)
        return closed

    def _resolve_ambiguity(self, bar, sl_extreme: str, favorable: bool) -> bool:
        self.ambiguous_bars += 1
        fe = getattr(bar, "first_extreme", None)
        if getattr(bar, "synthetic", False) and fe in ("HIGH", "LOW"):
            return fe == sl_extreme
        p = self.cfg.ambiguity
        if p == "TICK_DATA":
            if self.cfg.tick_fallback is None:
                raise RuntimeError("TICK_DATA requiere la secuencia bid/ask completa; first_extreme no determina "
                                   "la primera barrera tocada. Usa WORST_CASE para OHLC.")
            self.ambiguous_fallbacks += 1
            p = self.cfg.tick_fallback
        if p == "WORST_CASE":
            return True
        if p == "OPTIMISTIC":
            return False
        if p == "CONSERVATIVE":
            return not favorable
        raise ValueError(f"Política desconocida: {p}")

    def _finalize(self, t: Trade, price: float, when, reason: str) -> None:
        if reason != "TP":
            slip = self.cfg.slippage_points * self.spec.point
            price += -slip if t.direction == "BUY" else slip
        t.exit_price = round(price, self.spec.digits)
        t.exit_time = when
        t.exit_reason = reason
        t.status = TradeStatus.CLOSED
        gross = self.pnl(t, t.exit_price)
        t.profit = round(gross - t.commission + t.swap, 2)
        risk = t.initial_risk
        t.r_multiple = round(t.price_diff(t.exit_price) / risk, 3) if risk else None
        self.balance = round(self.balance + t.profit, 2)
