from pathlib import Path
import sys
from types import SimpleNamespace as NS
from unittest.mock import MagicMock
import numpy as np
import pytest
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT),str(ROOT/"optimizer")]
from gm_feed import DXYFeed,TickCursor,quote_valid,resolve_symbol
from gm_validation import simulate_orders,split_trades,select_candidate,equity_path,bootstrap_metrics

def test_stale_crossed_and_future_quotes_rejected():
    for bid,ask,stamp in [(100,101,94000),(102,101,100000),(100,101,110000),(float("nan"),101,100000)]:
        assert not quote_valid(NS(bid=bid,ask=ask,time_msc=stamp),100)
    assert quote_valid(NS(bid=100,ask=101,time_msc=99000),100)

def test_direct_deriv_dxy_preferred_and_stale_not_replaced():
    api=MagicMock();api.symbols_get.return_value=[NS(name="DXYUSD"),NS(name="DXY")]
    api.symbol_select.return_value=True
    api.symbol_info_tick.return_value=NS(bid=100.,ask=100.1,time_msc=100000)
    feed=DXYFeed(api)
    assert feed.quote(100).source=="DXYUSD"
    assert not feed.quote(110).valid

def test_incomplete_basket_is_not_reported_as_dxy():
    api=MagicMock();api.symbols_get.return_value=[NS(name=x) for x in ["EURUSD","GBPUSD","USDJPY"]]
    api.symbol_select.return_value=True
    assert not DXYFeed(api).quote(100).valid

def test_ambiguous_suffix_is_not_guessed():
    api=MagicMock();api.symbols_get.return_value=[NS(name="XAUUSD.a"),NS(name="XAUUSD.b")]
    assert resolve_symbol(api,("XAUUSD",)) is None

def test_ticks_same_millisecond_and_identical_rows_are_preserved_once():
    cursor=TickCursor()
    rows=[dict(time_msc=100,bid=1.,ask=2.),dict(time_msc=100,bid=1.,ask=2.)]
    assert len(cursor.take(rows))==2
    assert cursor.take(rows)==[]
    assert len(cursor.take(rows+[rows[0],dict(time_msc=101,bid=2.,ask=3.)]))==2
    assert cursor.take([dict(time_msc=101,bid=2.,ask=3.)])==[]

def frame():
    return {"o":np.array([100,101,99,99.]),"h":np.array([101,105,100,100.]),
            "l":np.array([99,95,98,98.]),"c":np.array([100,102,99,99.]),"spread":np.array([2,2,2,2.])}

def test_next_open_and_both_barriers_use_worst_case():
    trade=simulate_orders(frame(),[(0,1,100,98,104,2)],.1,2)[0]
    assert trade.entry_bar==1 and trade.entry_price==pytest.approx(101.2)
    assert trade.exit_price==pytest.approx(99.2) and trade.reason=="stop"
    assert trade.r_multiple==pytest.approx(-1.)

def test_short_closes_at_ask_and_cost_stress_reduces_pnl():
    f=frame();f["h"]=np.array([101,102,100,100.]);f["l"]=np.array([99,100,98,98.])
    sig=[(0,-1,100,110,80,10)]
    a=simulate_orders(f,sig,.1,2)[0]
    b=simulate_orders(f,sig,.1,2,slippage_points=2,commission_price=.5)[0]
    assert a.exit_price==pytest.approx(99.2)
    assert b.r_multiple<a.r_multiple

def test_training_selection_cannot_see_holdout():
    rows=[{"P":"a","IS":{"n":40,"exp":.1},"OOS":{"exp":100}},
          {"P":"b","IS":{"n":40,"exp":.2},"OOS":{"exp":-100}}]
    assert select_candidate(rows)["P"]=="b"

def test_split_purges_label_crossing_boundary():
    f=frame();trade=simulate_orders(f,[(0,1,100,90,130,10)],.1,2)[0]
    a,b,p=split_trades([trade],2)
    assert not a and not b and p==[trade]

def test_insolvency_absorbing_and_bootstrap_reproducible():
    assert equity_path([-110,1000],100).tolist()==[100,-10]
    kw=dict(pnl=[-110,1000],start=100,ruin=50,runs=100,skip_probability=0,extra_cost_fraction=0)
    a=bootstrap_metrics(rng=np.random.default_rng(7),**kw)
    b=bootstrap_metrics(rng=np.random.default_rng(7),**kw)
    assert a==b and a["p_insolvency"]>0

def test_micro_z_uses_actual_elapsed_seconds():
    from gm_micro import MicroMonitor
    x=np.linspace(1,2,150)
    times=np.arange(150)*10
    assert MicroMonitor._z(x,1,times)==0  # samples are 10s apart, not 1s
