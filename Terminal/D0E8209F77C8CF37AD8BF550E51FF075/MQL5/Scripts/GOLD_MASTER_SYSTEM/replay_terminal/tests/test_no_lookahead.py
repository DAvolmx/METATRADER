"""
tests/test_no_lookahead.py — Demuestra que ningún indicador usa velas futuras.

Para muchos instantes t:
  A) motor alimentado SOLO con las velas cerradas hasta t
  B) motor alimentado con TODO el histórico y consultado con snapshot(t)
deben ser idénticos. Si algún cálculo mirase el futuro, B "sabría" algo que
A no puede saber y la comparación fallaría.
También se comprueba en replay (visible/forming) y en el agregador.
"""
import random
from datetime import timedelta

import pandas as pd
import pytest

from core.models import bars_from_df
from data.aggregator import BarAggregator
from replay.replay_engine import ReplayEngine
from smc.smc_engine import SMCConfig, SMCEngine


@pytest.mark.parametrize("cfg", [SMCConfig(), SMCConfig(swing_left_bars=3, swing_right_bars=8,
                                                        break_confirmation="WICK", ob_min_displacement=0.3)])
def test_smc_truncated_equals_full(history_m1, cfg):
    bars = bars_from_df(history_m1.head(2500))
    full = SMCEngine("M1", cfg)
    for b in bars:
        full.on_bar(b)
    rnd = random.Random(7)
    for k in sorted(rnd.sample(range(15, len(bars)), 35)):
        part = SMCEngine("M1", cfg)
        for b in bars[:k]:
            part.on_bar(b)
        t = bars[k - 1].time + timedelta(minutes=1)
        assert part.signature(t) == full.signature(t), f"look-ahead detectado en k={k}"


def test_future_bars_cannot_change_past_snapshot(history_m1):
    """Alterar velas FUTURAS no cambia nada de lo visible en t."""
    bars = bars_from_df(history_m1.head(1500))
    k = 900
    t = bars[k - 1].time + timedelta(minutes=1)
    e1 = SMCEngine("M1"); [e1.on_bar(b) for b in bars]
    df2 = history_m1.head(1500).copy()
    df2.loc[k:, ["open", "high", "low", "close"]] *= 1.05      # futuro distinto
    df2.loc[k:, "high"] = df2.loc[k:, ["open", "high", "close"]].max(axis=1)
    df2.loc[k:, "low"] = df2.loc[k:, ["open", "low", "close"]].min(axis=1)
    e2 = SMCEngine("M1"); [e2.on_bar(b) for b in bars_from_df(df2)]
    assert e1.signature(t) == e2.signature(t)


def test_replay_never_shows_future(history_m1):
    df = history_m1.head(3000)
    rp = ReplayEngine(df, "M1", ("M1", "M5", "M15", "H1"), start_time=df["time"].iloc[500])
    for _ in range(300):
        rp.step_forward()
        clock = pd.Timestamp(rp.current_time)
        for tf, mins in (("M1", 1), ("M5", 5), ("M15", 15), ("H1", 60)):
            vis = rp.visible(tf)
            assert (vis["time"] + pd.Timedelta(minutes=mins) <= clock).all()
            f = rp.forming(tf)
            if f is not None:
                members = df[(df["time"] >= pd.Timestamp(f.time)) & (df["time"] + pd.Timedelta(minutes=1) <= clock)]
                assert f.high == members["high"].max() and f.close == members["close"].iloc[-1]


def test_aggregator_emits_only_closed(history_m1):
    agg = BarAggregator("M15", "M1")
    for b in bars_from_df(history_m1.head(400)):
        for c in agg.update(b):
            assert c.time + timedelta(minutes=15) <= b.time + timedelta(minutes=1)


def test_backtest_signal_executes_next_open(history_m1, gold_spec):
    """Toda entrada ocurre DESPUÉS de su señal (apertura de la vela siguiente)."""
    from strategies.smc_fvg import SMCFVGStrategy
    from trading.backtest_engine import BacktestConfig, BacktestEngine
    res = BacktestEngine(history_m1.head(4000), gold_spec,
                         BacktestConfig("XAUUSD", "M1", topdown_tfs=("M15",))).run(SMCFVGStrategy(bias_tf="M15"))
    assert res.trades
    for t in res.trades:
        assert t.signal_time is not None and t.entry_time >= t.signal_time
