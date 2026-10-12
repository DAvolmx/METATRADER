"""Offline execution and validation primitives. No broker calls or order submission.

MT5 OHLC are treated as bid prices, with the reported bar spread as an ask
approximation. OHLC cannot recover tick order: stops take precedence, a changed
stop becomes active on the following bar, and limit targets receive no favorable
gap improvement. Tick replay is required to validate actual execution.
"""
from typing import NamedTuple
import numpy as np


class TradeResult(NamedTuple):
    signal_bar: int
    r_multiple: float
    risk_price: float
    entry_bar: int
    exit_bar: int
    direction: int
    entry_price: float
    exit_price: float
    reason: str


def simulate_orders(features, signals, point, maxbars, be=0.0, lock=0.0,
                    commission_price=0.0, slippage_points=0.0,
                    start_bar=0, end_bar=None):
    """Fill closed-bar signals at the next open, with one open position at a time.

    Signals are (bar, direction, reference_entry, stop, target, risk_price).
    Stop/target distances are recentered on the actual fill. commission_price
    is the round-trip cash commission divided by cash value per price unit;
    slippage_points is adverse slippage on each market fill, including stops.
    start_bar/end_bar delimit information and fills (end exclusive). A trade
    forcibly closed by that boundary is marked window_end and must be purged
    before training. The signal at start_bar-1 is deliberately excluded.
    """
    if not np.isfinite(point) or point <= 0 or maxbars < 1:
        raise ValueError("point and maxbars must be positive")
    if not all(np.isfinite(x) and x >= 0 for x in
               (commission_price, slippage_points, be, lock)):
        raise ValueError("costs and break-even settings must be finite and nonnegative")
    if be and lock > be:
        raise ValueError("locked profit cannot exceed the break-even trigger")
    arrays = {key: np.asarray(features[key], dtype=float)
              for key in ("o", "h", "l", "c", "spread")}
    n = len(arrays["c"])
    end = n if end_bar is None else min(n, int(end_bar))
    if not 0 <= start_bar <= end:
        raise ValueError("invalid simulation window")
    if any(len(x) != n for x in arrays.values()):
        raise ValueError("OHLC and spreads must have equal length")
    if any(not np.isfinite(x[start_bar:end]).all() for x in arrays.values()):
        raise ValueError("nonfinite OHLC or spread")
    o, h, l, c, spread = (arrays[k] for k in ("o", "h", "l", "c", "spread"))
    if (spread[start_bar:end] < 0).any():
        raise ValueError("negative spread")
    window = slice(start_bar, end)
    if ((h[window] < np.maximum(o[window], c[window])).any()
            or (l[window] > np.minimum(o[window], c[window])).any()):
        raise ValueError("inconsistent OHLC")
    slip = slippage_points * point
    trades, busy = [], start_bar - 1
    for b, direction, reference, _stop, target, risk in sorted(signals, key=lambda x: x[0]):
        b, direction = int(b), int(direction)
        entry_bar = b + 1
        if b < start_bar or entry_bar >= end or entry_bar <= busy:
            continue
        if direction not in (-1, 1):
            raise ValueError("direction must be -1 or 1")
        distance = (target - reference) * direction
        if not all(np.isfinite(x) and x > 0 for x in (risk, distance)):
            continue
        entry = o[entry_bar] + (spread[entry_bar] * point if direction > 0 else 0) + direction * slip
        stop, take = entry - direction * risk, entry + direction * distance
        moved = False
        last = min(end - 1, entry_bar + int(maxbars) - 1)
        reason = "window_end" if entry_bar + maxbars > end else "time"
        exit_price = None
        for i in range(entry_bar, last + 1):
            # Long positions close at bid; shorts close at ask.
            offset = spread[i] * point if direction < 0 else 0.0
            qo, qh, ql = o[i] + offset, h[i] + offset, l[i] + offset
            stop_hit = ql <= stop if direction > 0 else qh >= stop
            take_hit = qh >= take if direction > 0 else ql <= take
            if stop_hit:
                fill = min(stop, qo) if direction > 0 else max(stop, qo)
                exit_price, reason = fill - direction * slip, "stop"
                break
            if take_hit:
                exit_price, reason = take, "target"
                break
            favorable = qh - entry if direction > 0 else entry - ql
            if not moved and be > 0 and favorable >= be * risk:
                stop, moved = entry + direction * lock * risk, True
        if exit_price is None:
            i = last
            exit_price = c[i] + (spread[i] * point if direction < 0 else 0.0) - direction * slip
        net_r = ((exit_price - entry) * direction - commission_price) / risk
        trades.append(TradeResult(b, float(net_r), float(risk), entry_bar, i,
                                  direction, float(entry), float(exit_price), reason))
        busy = i
    return trades


def split_trades(trades, split, embargo=0):
    """Purged chronological split; never use a label ending in the test period."""
    if embargo < 0:
        raise ValueError("embargo must be nonnegative")
    train, test, purged = [], [], []
    for trade in trades:
        if trade.reason == "window_end":
            purged.append(trade)
        elif trade.signal_bar < split and trade.exit_bar < split:
            train.append(trade)
        elif trade.signal_bar >= split + embargo:
            test.append(trade)
        else:
            purged.append(trade)
    return train, test, purged


def select_candidate(rows, min_trades=30):
    """Rank exclusively by IS. OOS remains untouched until a winner is fixed."""
    eligible = [r for r in rows if r["IS"]["n"] >= min_trades
                and np.isfinite(r["IS"]["exp"]) and r["IS"]["exp"] > 0]
    return max(eligible, key=lambda r: (r["IS"]["exp"], r["IS"]["n"])) if eligible else None


def equity_path(pnl, start):
    """Stop trading after insolvency; do not permit a later simulated recovery.

    A loss larger than the remaining equity is retained as a deficit (no broker
    balance-protection assumption). Margin calls before insolvency are not modeled.
    """
    if not np.isfinite(start) or start <= 0:
        raise ValueError("starting equity must be positive")
    values = np.asarray(pnl, dtype=float)
    if not np.isfinite(values).all():
        raise ValueError("PnL must be finite")
    result = [float(start)]
    for value in values:
        result.append(result[-1] + float(value))
        if result[-1] <= 0:
            break
    return np.asarray(result)


def stationary_sample(values, rng, block_length):
    """Stationary bootstrap, preserving local runs with expected block length."""
    values = np.asarray(values, dtype=float)
    if block_length < 1:
        raise ValueError("block_length must be at least one")
    n = len(values)
    if not n:
        return values.copy()
    indices = np.empty(n, dtype=int)
    indices[0] = rng.integers(n)
    for i in range(1, n):
        indices[i] = rng.integers(n) if rng.random() < 1 / block_length else (indices[i-1] + 1) % n
    return values[indices]


def bootstrap_metrics(pnl, start, ruin, rng, runs=4000, block_length=None,
                      skip_probability=0.1, extra_cost_fraction=0.05):
    pnl = np.asarray(pnl, dtype=float)
    if runs < 1 or not 0 <= ruin < start or not 0 <= skip_probability <= 1:
        raise ValueError("invalid bootstrap settings")
    if not np.isfinite(pnl).all() or extra_cost_fraction < 0:
        raise ValueError("nonfinite PnL or negative cost stress")
    if not len(pnl):
        return None
    block = max(1, int(np.sqrt(len(pnl)))) if block_length is None else block_length
    finals, drawdowns, bankrupt, ruins = [], [], 0, 0
    scale = extra_cost_fraction * np.abs(pnl).mean()
    for _ in range(runs):
        sample = stationary_sample(pnl, rng, block)
        sample = sample[rng.random(len(sample)) >= skip_probability]
        sample = sample - np.abs(rng.normal(0, scale, len(sample)))
        equity = equity_path(sample, start)
        peaks = np.maximum.accumulate(equity)
        ruins += bool((equity <= ruin).any())
        bankrupt += bool((equity <= 0).any())
        finals.append(equity[-1])
        drawdowns.append(float(((peaks - equity) / peaks).max()))
    return dict(method="stationary_block_bootstrap", block_length=block, runs=runs,
                p_ruin=ruins/runs, p_insolvency=bankrupt/runs,
                final_p5=float(np.percentile(finals, 5)), final_p50=float(np.median(finals)),
                final_p95=float(np.percentile(finals, 95)), p_profit=float(np.mean(np.asarray(finals) > start)),
                maxdd_p50=float(np.median(drawdowns)), maxdd_p95=float(np.percentile(drawdowns, 95)),
                insolvency_policy="stop_after_first_nonpositive_equity",
                assumptions="fixed lot; margin, swaps, tick sequence and broker stop-out not modeled")
