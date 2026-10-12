from types import SimpleNamespace as NS
from gm_small_account import feasibility

class Broker:
    ORDER_TYPE_BUY=0
    ORDER_TYPE_SELL=1
    def __init__(self): self.spec=NS(volume_min=.01,point=.01,trade_stops_level=20)
    def symbol_info(self,_): return self.spec
    def symbol_info_tick(self,_): return NS(bid=4000.,ask=4000.2,time_msc=100000)
    def order_calc_profit(self,kind,symbol,vol,entry,stop): return (stop-entry if kind==0 else entry-stop)*100*vol
    def order_calc_margin(self,*args): return 8.

def test_minimum_lot_exceeds_ten_dollar_risk_budget():
    result=feasibility(Broker(),'XAUUSD',10,1,8,100)
    assert result['status']=='infeasible'
    assert result['minimum_lot_loss']==8
    assert result['risk_budget']==.1

def test_missing_broker_economics_never_approves():
    broker=Broker();broker.order_calc_profit=lambda *args: None
    assert feasibility(broker,'XAUUSD',10,1,8,100)['status']=='unknown'

def test_spread_is_included_in_minimum_legal_stop():
    result=feasibility(Broker(),'XAUUSD',10,1,.3,100)
    assert result['status']=='infeasible'
    assert result['reason']=='stop_below_broker_minimum'

def test_stale_quote_never_passes_feasibility():
    assert feasibility(Broker(),'XAUUSD',10,1,8,120)['status']=='unknown'

def test_margin_can_allow_entry_while_one_percent_risk_fails():
    broker=Broker()
    broker.order_calc_margin=lambda *args: .51
    result=feasibility(broker,'XAUUSDmicro',6,1,9,100)
    assert result['margin_within_hypothetical_balance'] is True
    assert result['status']=='infeasible'
    assert result['reason']=='minimum_lot_exceeds_risk_budget'
