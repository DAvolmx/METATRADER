"""Replay: avance, retroceso, reset, velocidad, multitemporal, extensión sintética."""
import pandas as pd
import pytest

from replay.replay_engine import ReplayEngine, ReplayState
from simulation.synthetic_market import MarketCalibration, SimConfig, SyntheticMarket


@pytest.fixture
def rp(history_m1):
    df = history_m1.head(2000)
    return ReplayEngine(df, "M1", ("M1", "M5", "H1"), start_time=df["time"].iloc[600])


def test_start_hides_future(rp, history_m1):
    assert rp.idx == 600
    assert pd.Timestamp(rp.current_time) == history_m1["time"].iloc[599] + pd.Timedelta(minutes=1)
    assert len(rp.visible("M1")) == 600


def test_forward_back_reset(rp):
    rp.step_forward(); rp.step_forward()
    assert rp.idx == 602
    rp.step_back()
    assert rp.idx == 601
    rp.reset()
    assert rp.idx == 600 and rp.state == ReplayState.STOPPED


def test_finished_at_end(history_m1):
    df = history_m1.head(300)
    rp = ReplayEngine(df, "M1", ("M1",), start_time=df["time"].iloc[298])
    assert rp.step_forward() and rp.step_forward()
    assert not rp.step_forward() and rp.state == ReplayState.FINISHED


def test_speeds(rp):
    rp.set_speed(10.0)
    assert rp.interval_ms(1000) == 100 and rp.bars_per_tick() == 1
    rp.set_speed(3.7)                       # cualquier valor del slider
    assert rp.interval_ms(1000) == 270
    rp.set_speed(100.0)                     # muy rápido: varias velas por refresco
    assert rp.interval_ms(1000) == 40 and rp.bars_per_tick() == 4
    with pytest.raises(ValueError):
        rp.set_speed(500.0)


def test_multitimeframe_sync(rp):
    for _ in range(137):
        rp.step_forward()
    clock = pd.Timestamp(rp.current_time)
    h1 = rp.visible("H1")
    m5 = rp.visible("M5")
    assert (h1["time"] + pd.Timedelta(hours=1) <= clock).all()
    assert (m5["time"] + pd.Timedelta(minutes=5) <= clock).all()
    # la siguiente vela M5 aún no está completa => no visible
    assert clock - (m5["time"].iloc[-1] + pd.Timedelta(minutes=5)) < pd.Timedelta(minutes=5)


def test_synthetic_extension(history_m1):
    df = history_m1.head(1500)
    syn = SyntheticMarket(MarketCalibration(df, "M1"), SimConfig(seed=3))
    rp = ReplayEngine(df, "M1", ("M1", "M15"), start_time=df["time"].iloc[-1], synthetic_market=syn)
    while rp.idx < rp.n_real:
        rp.step_forward()
    assert not rp.in_synthetic_zone
    for _ in range(40):
        assert rp.step_forward()
    assert rp.in_synthetic_zone and len(rp.bars) == 1540
    assert all(b.synthetic for b in rp.bars[1500:])
    m15 = rp.visible("M15")
    assert m15["synthetic"].iloc[-1]


def test_live_append(history_m1):
    from core.models import bars_from_df
    df = history_m1.head(1000)
    rp = ReplayEngine(df.head(900), "M1", ("M1", "M5"), start_time=df["time"].iloc[899])
    rp.idx = len(rp.bars)
    assert rp.append_bars(bars_from_df(df.iloc[880:950])) == 50
    assert rp.idx == 950 and len(rp.visible("M1")) == 950

def test_auxiliary_h3_not_in_panels(rp):
    assert "H3" not in rp.chart_tfs
    frame = rp.visible("H3")
    assert "H3" in rp.chart_tfs
    assert (frame["close_time"] <= pd.Timestamp(rp.current_time)).all()
    rp.step_forward()
    assert (rp.visible("H3")["close_time"] <= pd.Timestamp(rp.current_time)).all()
