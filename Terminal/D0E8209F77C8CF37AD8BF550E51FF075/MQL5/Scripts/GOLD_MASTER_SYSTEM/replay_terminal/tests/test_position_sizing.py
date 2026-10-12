"""Lotaje por riesgo: sin fórmulas universales, redondeo hacia abajo, límites."""
import pytest

from trading.position_sizer import round_volume_down, size_by_risk


def test_xauusd_sizing(gold_spec):
    # 10 000 USD, 1% = 100 USD; SL a 5 USD con contrato 100 oz => 500 USD/lote => 0.20 lotes
    r = size_by_risk(10_000, 1.0, "BUY", 2300.0, 2295.0, gold_spec, gold_spec.default_profit_fn())
    assert r.ok and r.volume == 0.20 and r.actual_risk == pytest.approx(100.0)


def test_rounds_down_never_more_risk(gold_spec):
    r = size_by_risk(10_000, 1.0, "SELL", 2300.0, 2303.0, gold_spec, gold_spec.default_profit_fn())
    # 100/300 = 0.333.. -> 0.33
    assert r.volume == 0.33 and r.actual_risk <= 100


def test_below_min_volume_rejected(gold_spec):
    r = size_by_risk(100, 0.5, "BUY", 2300.0, 2280.0, gold_spec, gold_spec.default_profit_fn())
    assert not r.ok and "mínimo" in r.reason


def test_max_volume_clamped(gold_spec):
    gold_spec.volume_max = 1.0
    r = size_by_risk(10_000_000, 2.0, "BUY", 2300.0, 2299.0, gold_spec, gold_spec.default_profit_fn())
    assert r.volume == 1.0


def test_no_profit_fn_is_na(gold_spec):
    r = size_by_risk(10_000, 1, "BUY", 2300, 2290, gold_spec, None)
    assert not r.ok and "N/A" in r.reason


def test_wrong_side_and_no_sl(gold_spec):
    f = gold_spec.default_profit_fn()
    assert not size_by_risk(10_000, 1, "BUY", 2300, 2310, gold_spec, f).ok
    assert not size_by_risk(10_000, 1, "BUY", 2300, None, gold_spec, f).ok


def test_volume_step_rounding():
    assert round_volume_down(0.129, 0.01) == 0.12
    assert round_volume_down(1.7, 0.5) == 1.5
    assert round_volume_down(0.3, 0.1) == 0.3       # sin error de coma flotante


def test_uses_injected_profit_fn(gold_spec):
    """Simula mt5.order_calc_profit con otro valor de contrato."""
    calls = []
    def fake(direction, volume, p_open, p_close):
        calls.append((direction, volume, p_open, p_close))
        return (p_close - p_open) * 10 * volume
    r = size_by_risk(1000, 1, "BUY", 100, 99, gold_spec, fake)
    assert calls == [("BUY", 1.0, 100, 99)] and r.volume == 1.0
