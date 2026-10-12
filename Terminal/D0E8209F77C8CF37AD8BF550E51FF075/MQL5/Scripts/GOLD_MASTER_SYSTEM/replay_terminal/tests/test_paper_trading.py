"""PaperTradingEngine: BUY/SELL, BID/ASK, SL/TP, gaps, ambigüedad, MAE/MFE, R."""
from datetime import timedelta

import pytest

from trading.paper_engine import PaperConfig, PaperTradingEngine
from tests.conftest import mkbars


def engine(spec, **kw):
    e = PaperTradingEngine(spec, PaperConfig(**kw))
    b = mkbars([(2300, 2300, 2300, 2300)], spread=20)[0]
    e.update_quote(2300.0, 20, b.time)
    return e


def step(e, row, spread=20, fe=None, i=1):
    b = mkbars([row], start=e.time + timedelta(minutes=i - 1), spread=spread, first_extreme=fe)[0]
    return e.on_bar(b, b.time + timedelta(minutes=1))


def test_entry_prices(gold_spec):
    e = engine(gold_spec)
    assert e.open("BUY", 0.1).entry_price == 2300.2
    assert e.open("SELL", 0.1).entry_price == 2300.0


def test_tp_hit_buy_profit(gold_spec):
    e = engine(gold_spec)
    t = e.open("BUY", 0.10, stop_loss=2295, take_profit=2305)
    step(e, (2300, 2306, 2299, 2305.5))
    assert t.exit_reason == "TP" and t.exit_price == 2305
    assert t.profit == pytest.approx((2305 - 2300.2) * 100 * 0.10)
    assert t.r_multiple == pytest.approx(4.8 / 5.2, rel=1e-3)
    assert e.balance == pytest.approx(10_000 + t.profit)


def test_sell_exits_at_ask(gold_spec):
    e = engine(gold_spec)
    t = e.open("SELL", 0.10, stop_loss=2305)
    # high BID 2304.9 -> ASK 2305.1 >= SL
    step(e, (2300, 2304.9, 2299, 2301))
    assert t.exit_reason == "SL" and t.exit_price == 2305


def test_gap_through_sl_fills_at_open(gold_spec):
    e = engine(gold_spec)
    t = e.open("BUY", 0.10, stop_loss=2295)
    step(e, (2290, 2292, 2288, 2291))
    assert t.exit_reason == "SL" and t.exit_price == 2290      # peor que el SL


@pytest.mark.parametrize("policy,expected", [("WORST_CASE", "SL"), ("OPTIMISTIC", "TP"),
                                              ("CONSERVATIVE", "TP")])
def test_ambiguity_policies(gold_spec, policy, expected):
    e = engine(gold_spec, ambiguity=policy)
    t = e.open("BUY", 0.10, stop_loss=2295, take_profit=2305)
    step(e, (2300, 2306, 2294, 2304))          # vela alcista que toca ambos
    assert t.exit_reason == expected


def test_tick_data_policy(gold_spec):
    # sin orden intra-vela y sin fallback => error explícito
    e = engine(gold_spec, ambiguity="TICK_DATA", tick_fallback=None)
    e.open("BUY", 0.10, stop_loss=2295, take_profit=2305)
    with pytest.raises(RuntimeError):
        step(e, (2300, 2306, 2294, 2304))
    # con fallback: se resuelve con la política y se CUENTA
    e1 = engine(gold_spec, ambiguity="TICK_DATA")
    t1 = e1.open("BUY", 0.10, stop_loss=2295, take_profit=2305)
    step(e1, (2300, 2306, 2294, 2304))
    assert t1.exit_reason == "SL" and e1.ambiguous_fallbacks == 1
    # con orden real (desde ticks) no hay ambigüedad
    e2 = engine(gold_spec, ambiguity="TICK_DATA")
    t2 = e2.open("BUY", 0.10, stop_loss=2295, take_profit=2305)
    step(e2, (2300, 2306, 2294, 2304), fe="HIGH")
    # The order of global extremes does not establish the first barrier crossing.
    assert t2.exit_reason == "SL" and e2.ambiguous_fallbacks == 1


def test_mae_mfe(gold_spec):
    e = engine(gold_spec)
    t = e.open("BUY", 0.10, stop_loss=2290, take_profit=2320)
    step(e, (2300, 2303, 2297, 2301), i=1)
    step(e, (2301, 2308, 2299, 2307), i=2)
    assert t.mae == pytest.approx(2297 - 2300.2)
    assert t.mfe == pytest.approx(2308 - 2300.2)


def test_invalid_orders(gold_spec):
    e = engine(gold_spec)
    with pytest.raises(ValueError):
        e.open("BUY", 0.10, stop_loss=2301)
    with pytest.raises(ValueError):
        e.open("SELL", 0.10, take_profit=2301)
    with pytest.raises(ValueError):
        e.open("BUY", 0.001)
    with pytest.raises(ValueError):
        e.close(99)


def test_commission_and_slippage(gold_spec):
    e = engine(gold_spec, commission_per_lot=7.0, slippage_points=10)
    t = e.open("BUY", 1.0)
    assert t.entry_price == 2300.3 and t.commission == 7.0
    e.close(t.id)
    assert t.profit == pytest.approx((2299.9 - 2300.3) * 100 - 7.0)  # slippage on both market fills


def test_points_mode_without_money(gold_spec):
    gold_spec.account_currency = "EUR"
    e = engine(gold_spec)
    assert e.currency == "PTS"
    t = e.open("BUY", 0.1)
    e.close(t.id)
    assert t.profit == pytest.approx(-20.0)


def test_on_tick_live(gold_spec):
    e = engine(gold_spec)
    t = e.open("SELL", 0.1, take_profit=2295)
    closed = e.on_tick(2294.8, 2295.0, e.time)
    assert closed == [t] and t.exit_reason == "TP"
