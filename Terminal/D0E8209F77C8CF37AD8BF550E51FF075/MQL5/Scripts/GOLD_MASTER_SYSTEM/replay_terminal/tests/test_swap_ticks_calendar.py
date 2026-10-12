"""Swap, orden intra-vela desde ticks y temporalidades de calendario (W1/MN1)."""
from datetime import datetime, timedelta, timezone

import numpy as np
import pandas as pd
import pytest

from core.models import Bar, tf_bucket_start, tf_close
from data.aggregator import BarAggregator
from data.data_manager import resample_ohlc
from data.ticks import annotate_first_extreme, bars_from_ticks
from trading.paper_engine import PaperConfig, PaperTradingEngine
from trading.swap import rollover_multiplier, swap_per_night

UTC = timezone.utc


# ---------------------------------------------------------------- swap
def test_rollover_counts_weekdays_and_triple():
    mon = datetime(2026, 1, 5, 12, tzinfo=UTC)          # lunes
    assert rollover_multiplier(mon, mon + timedelta(hours=6)) == 0
    assert rollover_multiplier(mon, mon + timedelta(days=1)) == 1          # noche lun->mar
    assert rollover_multiplier(mon, mon + timedelta(days=3)) == 1 + 1 + 3  # mié triple
    fri = datetime(2026, 1, 9, 12, tzinfo=UTC)
    assert rollover_multiplier(fri, fri + timedelta(days=3)) == 1          # vie cuenta, sáb/dom no


def test_swap_modes(gold_spec):
    gold_spec.swap_long, gold_spec.swap_short = -50.0, 10.0
    gold_spec.swap_mode = 1                                   # puntos
    assert swap_per_night(gold_spec, "BUY", 1.0, 2300, 2300) == pytest.approx(-50 * 0.01 * 100)
    gold_spec.swap_mode = 4                                   # divisa de la cuenta
    assert swap_per_night(gold_spec, "SELL", 0.5, 2300, 2300) == pytest.approx(5.0)
    gold_spec.swap_mode = 6                                   # interés anual sobre apertura
    assert swap_per_night(gold_spec, "BUY", 1.0, 2000, 2100) == pytest.approx(-50 / 100 / 360 * 2000 * 100)
    gold_spec.swap_mode = 7                                   # reapertura: no soportado
    assert swap_per_night(gold_spec, "BUY", 1.0, 2300, 2300) is None
    gold_spec.swap_mode = 0
    assert swap_per_night(gold_spec, "BUY", 1.0, 2300, 2300) == 0.0


def test_swap_charged_in_paper_engine(gold_spec):
    gold_spec.swap_long, gold_spec.swap_mode, gold_spec.swap_rollover3days = -20.0, 4, 3
    e = PaperTradingEngine(gold_spec, PaperConfig())
    t0 = datetime(2026, 1, 6, 22, 0, tzinfo=UTC)              # martes 22:00
    e.update_quote(2300, 0, t0)
    t = e.open("BUY", 1.0)
    for h in range(1, 30):                                    # cruza mar->mié (1) y mié->jue (3)
        tt = t0 + timedelta(hours=h)
        e.on_bar(Bar(tt, 2300, 2300.5, 2299.5, 2300), tt + timedelta(hours=1))
    e.close(t.id)
    assert t.swap == pytest.approx(-20 * 4)
    assert t.profit == pytest.approx(-80.0)


def test_swap_unsupported_is_flagged(gold_spec):
    gold_spec.swap_long, gold_spec.swap_mode = -1.0, 8
    e = PaperTradingEngine(gold_spec, PaperConfig())
    t0 = datetime(2026, 1, 6, 23, tzinfo=UTC)
    e.update_quote(2300, 0, t0)
    e.open("BUY", 1.0)
    e.on_bar(Bar(t0 + timedelta(hours=2), 2300, 2301, 2299, 2300), t0 + timedelta(hours=3))
    assert e.swap_unsupported


# ---------------------------------------------------------------- ticks
def _ticks(prices, start):
    return pd.DataFrame({"time": [start + timedelta(seconds=i) for i in range(len(prices))],
                         "bid": prices, "ask": [p + 0.2 for p in prices]})


def test_first_extreme_from_ticks():
    start = datetime(2026, 1, 5, 10, 0, tzinfo=UTC)
    ticks = pd.concat([_ticks([100, 101, 105, 99, 102], start),               # máximo primero
                       _ticks([100, 96, 98, 104, 101], start + timedelta(minutes=1))])  # mínimo primero
    bars = bars_from_ticks(ticks, "M1")
    assert list(bars["high"]) == [105, 104] and list(bars["low"]) == [99, 96]
    ann = annotate_first_extreme(bars, ticks, "M1")
    assert list(ann["first_extreme"]) == ["HIGH", "LOW"]


def test_bars_without_ticks_stay_unknown():
    start = datetime(2026, 1, 5, 10, 0, tzinfo=UTC)
    bars = pd.DataFrame({"time": [start, start + timedelta(minutes=1)], "open": [1, 1],
                         "high": [2, 2], "low": [0, 0], "close": [1, 1]})
    ann = annotate_first_extreme(bars, _ticks([1, 2, 0], start), "M1")
    assert ann["first_extreme"].iloc[0] == "HIGH" and ann["first_extreme"].iloc[1] is None


def test_backtest_uses_tick_order(history_m1, gold_spec):
    from strategies.smc_fvg import SMCFVGStrategy
    from trading.backtest_engine import BacktestConfig, BacktestEngine
    df = history_m1.copy()
    df["first_extreme"] = np.where(np.arange(len(df)) % 2 == 0, "HIGH", "LOW")
    res = BacktestEngine(df, gold_spec, BacktestConfig("XAUUSD", "M1", ambiguity="TICK_DATA",
                                                      tick_fallback=None, topdown_tfs=("M15",))
                         ).run(SMCFVGStrategy(bias_tf="M15"))
    assert res.statistics["ambiguous_fallbacks"] == 0


# ---------------------------------------------------------------- W1 / MN1
def test_calendar_buckets():
    t = datetime(2026, 1, 7, 15, 30, tzinfo=UTC)               # miércoles
    assert tf_bucket_start(t, "W1") == datetime(2026, 1, 4, tzinfo=UTC)     # domingo
    assert tf_close(datetime(2026, 1, 4, tzinfo=UTC), "W1") == datetime(2026, 1, 11, tzinfo=UTC)
    assert tf_bucket_start(t, "MN1") == datetime(2026, 1, 1, tzinfo=UTC)
    assert tf_close(datetime(2026, 12, 1, tzinfo=UTC), "MN1") == datetime(2027, 1, 1, tzinfo=UTC)
    assert tf_close(datetime(2026, 2, 1, tzinfo=UTC), "MN1") == datetime(2026, 3, 1, tzinfo=UTC)


def _hourly(days, start=datetime(2026, 1, 1, tzinfo=UTC)):
    idx = pd.date_range(start, periods=days * 24, freq="1h", tz="UTC")
    p = 100 + np.arange(len(idx)) * 0.01
    return pd.DataFrame({"time": idx, "open": p, "high": p + 0.5, "low": p - 0.5, "close": p + 0.1,
                         "tick_volume": 1, "spread": 0})


def test_resample_w1_mn1_and_aggregator_agree():
    df = _hourly(75)                                           # 1 ene -> 16 mar
    for tf in ("W1", "MN1"):
        r = resample_ohlc(df, "H1", tf)
        agg = BarAggregator(tf, "H1")
        from core.models import bars_from_df
        closed = []
        for b in bars_from_df(df):
            closed += agg.update(b)
        full = r[r["complete"]]
        assert len(closed) == len(full)
        for c, (_, row) in zip(closed, full.iterrows()):
            assert pd.Timestamp(c.time) == row["time"] and c.high == row["high"] and c.close == row["close"]
    mn = resample_ohlc(df, "H1", "MN1")
    assert list(mn["time"].dt.month) == [1, 2, 3] and list(mn["complete"]) == [True, True, False]
    assert mn["close_time"].iloc[1] == pd.Timestamp("2026-03-01", tz="UTC")


def test_replay_w1_hides_open_week():
    from replay.replay_engine import ReplayEngine
    df = _hourly(30)
    rp = ReplayEngine(df, "H1", ("H1", "W1"), start_time=datetime(2026, 1, 15, tzinfo=UTC))
    vis = rp.visible("W1")
    assert (vis["close_time"] <= pd.Timestamp(rp.current_time)).all()
    f = rp.forming("W1")
    assert f is not None and pd.Timestamp(f.time) == pd.Timestamp("2026-01-11", tz="UTC")
