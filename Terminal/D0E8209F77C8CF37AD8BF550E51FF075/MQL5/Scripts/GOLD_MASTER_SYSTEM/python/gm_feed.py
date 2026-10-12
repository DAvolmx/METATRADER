"""Read-only feed utilities. No orders, credentials, or terminal initialization."""
from collections import Counter
from dataclasses import dataclass
import math
import os
import time

DXY_WEIGHTS = {"EURUSD": -.576, "USDJPY": .136, "GBPUSD": -.119,
               "USDCAD": .091, "USDSEK": .042, "USDCHF": .036}
DXY_SYMBOLS = ("DXYUSD", "USDX", "DXY", "DX", "USDIndex", "USDOLLAR", "DOLLAR.IDX")


def quote_valid(tick, now=None, max_age=5.0):
    if tick is None:
        return False
    now = time.time() if now is None else now
    stamp = getattr(tick, "time_msc", 0) / 1000 or getattr(tick, "time", 0)
    return (math.isfinite(tick.bid) and math.isfinite(tick.ask)
            and 0 < tick.bid <= tick.ask and -2 <= now - stamp <= max_age)


def resolve_symbol(api, aliases, override=None):
    """Explicit override/exact aliases; only an unambiguous suffix is inferred."""
    names = [s.name for s in (api.symbols_get() or [])]
    if override:
        return override if override in names and api.symbol_select(override, True) else None
    for alias in aliases:
        if alias in names and api.symbol_select(alias, True):
            return alias
    candidates = [n for n in names if any(n.startswith(a + sep) for a in aliases for sep in (".", "_", "-"))]
    if len(candidates) == 1 and api.symbol_select(candidates[0], True):
        return candidates[0]
    return None


@dataclass(frozen=True)
class DXYQuote:
    value: float | None
    source: str
    valid: bool


class DXYFeed:
    def __init__(self, api, max_age=5.0):
        self.api, self.max_age = api, max_age
        self.direct = resolve_symbol(api, DXY_SYMBOLS, os.getenv("GM_DXY_SYMBOL"))
        self.pairs = {} if self.direct else {k: resolve_symbol(api, (k,)) for k in DXY_WEIGHTS}

    def quote(self, now=None):
        now = time.time() if now is None else now
        if self.direct:
            tick = self.api.symbol_info_tick(self.direct)
            ok = quote_valid(tick, now, self.max_age)
            # Do not silently change source on a stale direct feed: it creates false jumps.
            return DXYQuote((tick.bid + tick.ask) / 2 if ok else None, self.direct, ok)
        acc, stamps = 0.0, []
        if not all(self.pairs.get(base) for base in DXY_WEIGHTS):
            return DXYQuote(None, "synthetic_unavailable_6_pairs_required", False)
        for base, weight in DXY_WEIGHTS.items():
            symbol = self.pairs.get(base)
            tick = self.api.symbol_info_tick(symbol) if symbol else None
            if not quote_valid(tick, now, self.max_age):
                return DXYQuote(None, "synthetic_unavailable_6_pairs_required", False)
            stamps.append(tick.time_msc / 1000)
            acc += weight * math.log((tick.bid + tick.ask) / 2)
        if max(stamps) - min(stamps) > 2:
            return DXYQuote(None, "synthetic_unsynchronized", False)
        return DXYQuote(50.14348112 * math.exp(acc), "synthetic_6_pairs", True)


class TickCursor:
    """Deduplicate overlapping fetches, preserving identical ticks in one millisecond.

    Request again from last_msc inclusively. A millisecond is not a unique tick ID.
    """
    def __init__(self):
        self.last_msc = 0
        self.boundary = Counter()

    def take(self, rows):
        old_stamp, seen = self.last_msc, Counter()
        newest, new_boundary, out = old_stamp, self.boundary.copy(), []
        for row in rows:
            stamp = int(row["time_msc"])
            key = tuple(row[k].item() if hasattr(row[k], "item") else row[k]
                        for k in (row.dtype.names if hasattr(row, "dtype") else sorted(row)))
            if stamp < old_stamp:
                continue
            seen[(stamp, key)] += 1
            if stamp > old_stamp or seen[(stamp, key)] > self.boundary[key]:
                out.append(row)
            if stamp > newest:
                newest, new_boundary = stamp, Counter()
            if stamp == newest:
                new_boundary[key] = seen[(stamp, key)]
        self.last_msc, self.boundary = newest, new_boundary
        return out
