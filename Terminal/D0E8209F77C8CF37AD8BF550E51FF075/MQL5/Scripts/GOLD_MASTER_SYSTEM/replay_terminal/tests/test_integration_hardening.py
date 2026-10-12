from pathlib import Path
from types import SimpleNamespace as NS
from datetime import datetime,timedelta,timezone
import pytest
from fastapi.testclient import TestClient
from web.server import create_app
from web.service import TradingService
from strategies.smc_quality import SMCQualityStrategy

def test_cross_site_mutations_and_dns_rebinding_are_blocked(tmp_path):
    svc=TradingService(db_path=tmp_path/"web.db",mt5_enabled=False)
    with TestClient(create_app(svc)) as client:
        assert client.post("/api/replay/step",headers={"origin":"https://attacker.invalid"}).status_code==403
        assert client.get("/api/status",headers={"host":"evil.invalid"}).status_code==400
        assert client.get("/api/analytics").json()["execution"]=="disabled"

def test_quality_rejects_spread_and_daily_drawdown_before_signals():
    strategy=SMCQualityStrategy()
    t=datetime(2026,1,1,tzinfo=timezone.utc)
    bars=[NS(high=102.,low=98.,close=100.) for _ in range(51)]
    ctx=NS(open_trades=[],pending_orders=[],time=t,balance=10000,history=bars,
           bar=NS(spread=100),spec=NS(point=.01))
    strategy.on_bar(ctx)
    assert strategy.rejections["spread_vs_atr"]==1
    ctx.balance=9700;strategy.on_bar(ctx)
    assert strategy.rejections["daily_risk_limit"]==1

def test_quality_risk_cannot_exceed_one_percent():
    with pytest.raises(ValueError): SMCQualityStrategy(risk_pct=2)

def test_api_rejects_invalid_costs_and_unknown_fields():
    from web.server import BacktestReq
    from pydantic import ValidationError
    for payload in ({'slippage_points':-1},{'commission_per_lot':-1},{'initial_balance':float('inf')},{'rr':float('nan')},{'typo_risk':1}):
        with pytest.raises(ValidationError): BacktestReq(**payload)

def test_replay_uses_configurable_virtual_balance(tmp_path):
    svc=TradingService(db_path=tmp_path/'practice.db',mt5_enabled=False)
    with TestClient(create_app(svc)) as client:
        response=client.post('/api/load',json={'source':'DEMO','base_tf':'M5','bars':500,'initial_balance':25000})
        assert response.status_code==200, response.text
        assert response.json()['balance']==25000
