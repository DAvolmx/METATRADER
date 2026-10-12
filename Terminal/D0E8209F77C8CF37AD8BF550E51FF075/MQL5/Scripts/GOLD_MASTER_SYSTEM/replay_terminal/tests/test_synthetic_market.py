"""
tests/test_synthetic_market.py — Simulador de mercado sintético.
No requiere MT5.   pytest tests/test_synthetic_market.py -v
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd
import pytest

from core.app_state import AppState, AppMode
from simulation.synthetic_market import (
    MarketCalibration, SimConfig, SyntheticMarket, TimeframeAggregator,
)
from simulation.sim_session import SimSession, SymbolSpec


def make_history(days=10, seed=0, high_vol_hours=range(13, 17), weekdays_only=True):
    """Histórico M1 artificial: oro ~2300, 3x de volatilidad en horas de NY."""
    rng = np.random.default_rng(seed)
    idx = pd.date_range("2026-01-05 00:00", periods=days * 1440, freq="1min", tz="UTC")
    if weekdays_only:
        idx = idx[idx.weekday < 5]
    vol = np.where(np.isin(idx.hour, list(high_vol_hours)), 0.0006, 0.0002)
    r = rng.normal(0, vol)
    close = 2300 * np.exp(np.cumsum(r))
    open_ = np.concatenate([[2300], close[:-1]])
    wick = np.abs(rng.normal(0, vol)) * close
    high = np.maximum(open_, close) + wick
    low = np.minimum(open_, close) - wick
    return pd.DataFrame({
        "time": idx, "open": open_.round(2), "high": high.round(2),
        "low": low.round(2), "close": close.round(2),
        "tick_volume": rng.integers(10, 100, len(idx)), "spread": 20,
    })


@pytest.fixture(scope="module")
def calib():
    return MarketCalibration(make_history(), "M1", block_size=30)


def gen(calib, n, **kw):
    m = SyntheticMarket(calib, SimConfig(timeframe="M1", seed=kw.pop("seed", 1), **kw))
    return m, [m.step() for _ in range(n)]


def test_calibration_basics(calib):
    assert calib.digits == 2
    assert calib.last_close > 0
    assert len(calib.valid_starts) > 0


def test_insufficient_history_rejected():
    with pytest.raises(ValueError):
        MarketCalibration(make_history().head(50), "M1", block_size=30)


def test_reproducible_with_seed(calib):
    _, a = gen(calib, 300, seed=42)
    _, b = gen(calib, 300, seed=42)
    _, c = gen(calib, 300, seed=43)
    assert a == b
    assert a != c


def test_ohlc_coherent(calib):
    _, bars = gen(calib, 3000)
    for b in bars:
        assert b.high >= max(b.open, b.close)
        assert b.low <= min(b.open, b.close)
        assert b.synthetic is True
        assert b.first_extreme in ("HIGH", "LOW")


def test_continues_from_last_real_bar(calib):
    _, bars = gen(calib, 5)
    assert bars[0].open == pytest.approx(calib.last_close)
    assert bars[0].time > calib.last_time


def test_time_strictly_increasing(calib):
    _, bars = gen(calib, 2000)
    times = [b.time for b in bars]
    assert all(t2 > t1 for t1, t2 in zip(times, times[1:]))


def test_no_precomputed_future(calib):
    """Generación incremental: solo existen las velas pedidas."""
    m, _ = gen(calib, 10)
    assert m.bars_generated == 10


def test_respects_sessions_no_weekend_bars(calib):
    # El histórico no tiene sábados/domingos => el simulador tampoco
    _, bars = gen(calib, 1440 * 4)
    assert all(b.time.weekday() < 5 for b in bars)


def test_intraday_volatility_preserved(calib):
    _, bars = gen(calib, 1440 * 5, seed=7)
    df = pd.DataFrame([{"h": b.time.hour, "r": b.high - b.low} for b in bars])
    hi = df[df.h.between(13, 16)].r.mean()
    lo = df[~df.h.between(13, 16)].r.mean()
    assert hi > 1.8 * lo


def test_vol_multiplier_scales_ranges(calib):
    _, a = gen(calib, 2000, seed=3, vol_multiplier=1.0)
    _, b = gen(calib, 2000, seed=3, vol_multiplier=2.0)
    ra = np.mean([x.high - x.low for x in a])
    rb = np.mean([x.high - x.low for x in b])
    assert 1.7 < rb / ra < 2.3


def test_aggregator_only_emits_closed_bars(calib):
    m, _ = gen(calib, 0)
    agg = TimeframeAggregator("M15", "M1")
    base = []
    for _ in range(100):
        b = m.step()
        base.append(b)
        for closed in agg.update(b):
            # Toda vela cerrada ya terminó en el tiempo simulado
            end = closed.time.timestamp() + 900
            assert end <= b.time.timestamp() + 60
            members = [x for x in base if closed.time.timestamp() <= x.time.timestamp() < end]
            assert closed.open == members[0].open
            assert closed.close == members[-1].close
            assert closed.high == max(x.high for x in members)
            assert closed.low == min(x.low for x in members)


def make_session(calib, seed=1):
    m = SyntheticMarket(calib, SimConfig(timeframe="M1", seed=seed))
    spec = SymbolSpec("XAUUSD", 2, 0.01, 100.0, "USD", "USD")
    return SimSession(m, spec)


def test_buy_enters_at_ask_sell_at_bid(calib):
    s = make_session(calib)
    s.next_bar()
    b = s.open_trade("BUY", 0.1)
    v = s.open_trade("SELL", 0.1)
    assert b.entry_price == s.ask
    assert v.entry_price == s.bid
    assert s.ask > s.bid


def test_invalid_sl_tp_rejected(calib):
    s = make_session(calib)
    s.next_bar()
    with pytest.raises(ValueError):
        s.open_trade("BUY", 0.1, sl=s.bid + 5)
    with pytest.raises(ValueError):
        s.open_trade("SELL", 0.1, tp=s.bid + 5)
    with pytest.raises(ValueError):
        s.open_trade("BUY", 0)


def test_sl_tp_eventually_close_trade(calib):
    s = make_session(calib, seed=11)
    s.next_bar()
    t = s.open_trade("BUY", 0.1, sl=s.bid - 1.0, tp=s.ask + 1.0)
    for _ in range(5000):
        if t.status == "CLOSED":
            break
        s.next_bar()
    assert t.status == "CLOSED"
    assert t.exit_reason in ("SL", "TP")
    if t.exit_reason == "TP":
        assert t.exit_price >= t.tp
    else:
        assert t.exit_price <= t.sl


def test_money_pnl_xauusd(calib):
    s = make_session(calib)
    s.next_bar()
    t = s.open_trade("BUY", 0.10)
    s.next_bar()
    s.close_trade(t.id)
    d = t.price_diff(t.exit_price)
    assert s.money(t, d) == pytest.approx(round(d * 100 * 0.10, 2))


def test_money_na_when_currency_differs(calib):
    m = SyntheticMarket(calib, SimConfig(timeframe="M1", seed=1))
    s = SimSession(m, SymbolSpec("XAUEUR", 2, 0.01, 100.0, "EUR", "USD"))
    s.next_bar()
    t = s.open_trade("BUY", 0.1)
    assert s.money(t, 1.0) is None


def test_export_csv(calib, tmp_path):
    s = make_session(calib)
    s.next_bar()
    s.open_trade("SELL", 0.2)
    s.next_bar()
    s.close_trade()
    out = s.export_trades_csv(tmp_path / "t.csv")
    df = pd.read_csv(out)
    assert len(df) == 1 and df.synthetic.iloc[0]


def test_real_trading_cannot_be_authorized_in_synthetic_mode():
    st = AppState()
    st.mode = AppMode.SYNTHETIC
    with pytest.raises(PermissionError):
        st.authorize_real_trading()
    assert st.can_send_real_orders() is False


def test_simulation_package_cannot_send_orders():
    """Barrera arquitectónica: ningún archivo de simulación referencia order_send ni MetaTrader5."""
    root = Path(__file__).parent.parent
    for f in list((root / "simulation").glob("*.py")) + [root / "simular.py"]:
        src = f.read_text(encoding="utf-8")
        assert "order_send" not in src
        assert "import MetaTrader5" not in src
