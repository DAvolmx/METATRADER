"""SL/TP por modo, R:R y validación de stops."""
import pytest

from trading.risk_manager import atr, stop_from, take_profit_rr, validate_stops


def test_stop_modes(gold_spec):
    assert stop_from("PRICE", "BUY", 2300, 2290, gold_spec) == 2290
    assert stop_from("POINTS", "BUY", 2300, 500, gold_spec) == 2295.0
    assert stop_from("POINTS", "SELL", 2300, 500, gold_spec) == 2305.0
    assert stop_from("PERCENT", "BUY", 2000, 1, gold_spec) == 1980.0
    assert stop_from("ATR", "SELL", 2300, 1.5, gold_spec, atr_value=4) == 2306.0
    assert stop_from("STRUCTURE", "BUY", 2300, 20, gold_spec, structure_price=2295) == 2294.8
    with pytest.raises(ValueError):
        stop_from("ATR", "BUY", 2300, 1, gold_spec, atr_value=None)
    with pytest.raises(ValueError):
        stop_from("STRUCTURE", "BUY", 2300, 1, gold_spec)


def test_rr():
    assert take_profit_rr("BUY", 100, 98, 2, 2) == 104
    assert take_profit_rr("SELL", 100, 101, 3, 2) == 97


def test_atr_needs_data():
    assert atr([1, 2], [0, 1], [1, 1], period=14) is None
    h = [10 + i for i in range(20)]; l = [x - 2 for x in h]; c = [x - 1 for x in h]
    assert atr(h, l, c, 14) == pytest.approx(2.0)


def test_validate_stops_level(gold_spec):
    gold_spec.stops_level = 100           # 1.00 USD
    assert validate_stops("BUY", 2300, 2300.2, 2299.5, None, gold_spec)       # demasiado cerca
    assert not validate_stops("BUY", 2300, 2300.2, 2298.0, 2305, gold_spec)
    assert validate_stops("SELL", 2300, 2300.2, 2299, None, gold_spec)        # lado incorrecto
