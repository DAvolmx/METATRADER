"""Pruebas del motor SMC: swings, BOS, CHoCH, FVG, EQH/EQL, sweeps, OB."""
from datetime import timedelta

import pytest

from smc.fvg import FVGTracker
from smc.liquidity import LiquidityTracker
from smc.smc_engine import SMCConfig, SMCEngine
from smc.swings import SwingDetector
from tests.conftest import mkbars


def feed(engine, bars):
    evs = []
    for b in bars:
        evs += engine.on_bar(b)
    return evs


def test_swing_confirmed_only_after_right_bars():
    rows = [(10, 11, 9, 10), (10, 12, 9, 11), (11, 15, 10, 14), (14, 13, 11, 12), (12, 12.5, 10, 11)]
    det = SwingDetector(2, 2)
    found_at = None
    for i, b in enumerate(mkbars(rows)):
        new = det.update(b, b.time + timedelta(minutes=1))
        if new:
            found_at = i
            s = new[0]
    assert found_at == 4            # vela 2 + 2 velas de confirmación
    assert s.kind == "HIGH" and s.price == 15 and s.index == 2
    assert s.detected_at == mkbars(rows)[4].time + timedelta(minutes=1)


def test_swing_left_strict():
    det = SwingDetector(1, 1)
    out = []
    for b in mkbars([(1, 5, 0, 1), (1, 5, 0, 1), (1, 3, 0, 1)]):
        out += det.update(b, b.time)
    assert not [s for s in out if s.kind == "HIGH"]     # 5 no supera estrictamente al anterior


def _zigzag(points, steps=3):
    """Serie que une precios clave con velas monótonas."""
    rows = []
    for a, b in zip(points, points[1:]):
        for k in range(steps):
            o = a + (b - a) * k / steps
            c = a + (b - a) * (k + 1) / steps
            rows.append((o, max(o, c) + 0.1, min(o, c) - 0.1, c))
    return rows


def test_bos_then_choch_sequence():
    # sube, retrocede, rompe máximo (BOS alcista), cae bajo el protected low (CHoCH bajista)
    pts = [100, 110, 104, 116, 108, 120, 96, 90]
    eng = SMCEngine("M1", SMCConfig(swing_left_bars=2, swing_right_bars=2))
    evs = feed(eng, mkbars(_zigzag(pts)))
    kinds = [(e.type, e.direction) for e in evs]
    assert ("BOS", "bullish") in kinds
    assert ("CHoCH", "bearish") in kinds
    first_choch = next(e for e in evs if e.type == "CHoCH")
    assert first_choch.previous_state == "BULLISH" and first_choch.new_state == "BEARISH"
    assert "protected low" in first_choch.reason
    assert all(e.timestamp == mkbars(_zigzag(pts))[e.index].time + timedelta(minutes=1) for e in evs)


def test_close_vs_wick_confirmation():
    pts = [100, 110, 104, 109.5]
    rows = _zigzag(pts) + [(109.5, 110.5, 109, 109.8)] + [(109.8, 110, 109, 109.5)] * 3
    e_close = SMCEngine("M1", SMCConfig(swing_left_bars=2, swing_right_bars=2, break_confirmation="CLOSE"))
    e_wick = SMCEngine("M1", SMCConfig(swing_left_bars=2, swing_right_bars=2, break_confirmation="WICK"))
    bars = mkbars(rows)
    feed(e_close, bars)
    feed(e_wick, bars)
    assert not [e for e in e_close.structure.events if e.direction == "bullish" and e.price > 109]
    assert [e for e in e_wick.structure.events if e.direction == "bullish" and e.price > 109]


def test_fvg_bullish_and_states():
    rows = [(100, 101, 99, 100.5), (100.5, 106, 100.4, 105.8), (105.8, 107, 102, 106.5),
            (106.5, 106.6, 101.5, 102.5),   # entra en el gap (101..102) -> parcial
            (102.5, 102.6, 100.8, 101.2),   # mecha atraviesa el gap -> FILLED
            ]
    tr = FVGTracker()
    bars = mkbars(rows)
    for i, b in enumerate(bars):
        tr.update(b, i, b.time + timedelta(minutes=1))
    g = tr.fvgs[0]
    assert g.direction == "bullish" and g.bottom == 101 and g.top == 102
    assert g.detected_at == bars[2].time + timedelta(minutes=1)
    assert g.formation_time == bars[1].time
    assert [s for _, s in g.status.history] == ["OPEN", "PARTIALLY_FILLED", "FILLED"]
    assert g.status.at(bars[2].time + timedelta(minutes=1)) == "OPEN"


def test_fvg_bearish_invalidated_by_close():
    rows = [(110, 111, 108, 109), (109, 109.5, 103, 103.5), (103.5, 106, 102, 103), (103, 112, 103, 111.5)]
    tr = FVGTracker()
    for i, b in enumerate(mkbars(rows)):
        tr.update(b, i, b.time + timedelta(minutes=1))
    g = tr.fvgs[0]
    assert g.direction == "bearish" and g.top == 108 and g.bottom == 106
    assert g.status.current == "INVALIDATED"


def test_equal_highs_and_sweep():
    from smc.models import Swing
    t0 = mkbars([(1, 1, 1, 1)])[0].time
    lt = LiquidityTracker(tolerance_abs=0.5, tolerance_pct=0.0, min_contacts=2)
    b = mkbars([(100, 100, 99, 99.5)])[0]
    s1 = Swing("HIGH", 100.0, 1, t0, t0, 3)
    s2 = Swing("HIGH", 100.3, 5, t0, t0, 7)
    lt.update(b, t0 + timedelta(minutes=1), [s1])
    lt.update(b, t0 + timedelta(minutes=2), [s2])
    lv = lt.levels[0]
    assert lv.is_equal and lv.equal_label == "EQH" and len(lv.swings) == 2
    sweep = mkbars([(100, 101, 99.8, 99.9)])[0]
    swept = lt.update(sweep, t0 + timedelta(minutes=3), [])
    assert swept == [lv] and lv.status.current == "SWEPT"


def test_tolerance_is_configurable():
    from smc.models import Swing
    t0 = mkbars([(1, 1, 1, 1)])[0].time
    b = mkbars([(1, 1, 1, 1)])[0]
    strict = LiquidityTracker(0.0, 0.0001, 2)
    strict.update(b, t0, [Swing("LOW", 100.0, 1, t0, t0, 3)])
    strict.update(b, t0, [Swing("LOW", 100.3, 2, t0, t0, 4)])
    assert len(strict.levels) == 2 and not any(l.is_equal for l in strict.levels)


def test_order_block_requires_break_and_displacement():
    pts = [100, 110, 104, 116, 108, 125]
    rows = _zigzag(pts)
    eng = SMCEngine("M1", SMCConfig(swing_left_bars=2, swing_right_bars=2, ob_min_displacement=0.5))
    bars = mkbars(rows)
    feed(eng, bars)
    assert eng.obs.blocks, "debería existir al menos un OB alcista tras el BOS"
    for ob in eng.obs.blocks:
        src = bars[ob.index]
        assert (src.close < src.open) == (ob.direction == "bullish")
        assert ob.displacement >= 0.5
        assert ob.detected_at == ob.trigger.timestamp
    strict = SMCEngine("M1", SMCConfig(swing_left_bars=2, swing_right_bars=2, ob_min_displacement=50))
    feed(strict, bars)
    assert not strict.obs.blocks


def test_out_of_order_bars_rejected():
    eng = SMCEngine("M1")
    bars = mkbars([(1, 2, 0.5, 1.5)] * 3)
    eng.on_bar(bars[2])
    with pytest.raises(ValueError):
        eng.on_bar(bars[0])


def test_enabled_flags_filter_snapshot(history_m1):
    from core.models import bars_from_df
    bars = bars_from_df(history_m1.head(800))
    cfg = SMCConfig()
    cfg.enabled["fvg"] = False
    cfg.enabled["bos"] = False
    eng = SMCEngine("M1", cfg)
    feed(eng, bars)
    snap = eng.snapshot(bars[-1].time + timedelta(minutes=1))
    assert snap.fvgs == [] and all(e.type != "BOS" for e in snap.events)


def test_failed_choch_creates_range_and_breakout_exits():
    # alcista (BOS) -> CHoCH bajista -> sin BOS bajista, CHoCH alcista => RANGO -> ruptura
    pts = [100, 110, 104, 116, 108, 120, 100, 112, 103, 124, 130]
    bars = mkbars(_zigzag(pts))
    eng = SMCEngine("M1", SMCConfig(swing_left_bars=2, swing_right_bars=2))
    feed(eng, bars)
    states = [e.new_state for e in eng.structure.events]
    assert "RANGING" in states, states
    i = states.index("RANGING")
    ev = eng.structure.events[i]
    assert ev.type == "CHoCH" and "CHoCH fallido" in ev.reason
    rg = eng.structure.ranges[0]
    assert rg["low"] < rg["high"]
    # durante el rango el snapshot lo expone; al romper, vuelve a tendencia
    assert eng.snapshot(ev.timestamp).active_range is not None
    after = eng.structure.events[i + 1]
    assert after.type == "BOS" and "rango" in after.reason and after.new_state in ("BULLISH", "BEARISH")
    assert rg["end"] == after.timestamp


def test_ranging_can_be_disabled():
    pts = [100, 110, 104, 116, 108, 120, 100, 112, 103, 124, 130]
    eng = SMCEngine("M1", SMCConfig(swing_left_bars=2, swing_right_bars=2, ranging_enabled=False))
    feed(eng, mkbars(_zigzag(pts)))
    assert "RANGING" not in [e.new_state for e in eng.structure.events]
