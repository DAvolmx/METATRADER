from pathlib import Path
import sys
import numpy as np
import pandas as pd
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from gm_strategy_catalog import signals, CATALOG


def frame(n=1200):
    rng=np.random.default_rng(56);c=2000+np.cumsum(rng.normal(0,2,n));o=np.r_[c[0],c[:-1]]
    return pd.DataFrame(dict(time=pd.date_range('2025-01-01',periods=n,freq='h',tz='UTC'),
        open=o,close=c,high=np.maximum(o,c)+rng.uniform(.1,3,n),
        low=np.minimum(o,c)-rng.uniform(.1,3,n),spread=np.full(n,30)))


def test_all_ten_families_ignore_future_bars():
    history=frame();_,full=signals(history);_,prefix=signals(history.iloc[:900])
    assert len(CATALOG)==10
    assert sum(map(len,full.values()))>0
    for name in CATALOG:
        assert [s for s in full[name] if s[0]<900]==prefix[name],name


def test_every_order_has_positive_risk_and_declared_rr():
    _,orders=signals(frame())
    for name,items in orders.items():
        for bar,direction,entry,stop,target,risk in items:
            assert bar>=300 and risk>0 and direction in (-1,1)
            assert np.isclose((entry-stop)*direction,risk)
            assert np.isclose((target-entry)*direction/risk,CATALOG[name][1])
