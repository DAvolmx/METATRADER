"""Backtest: operaciones, equity, drawdown, estadísticas, reproducibilidad, persistencia."""
from datetime import datetime, timedelta, timezone

import pandas as pd
import pytest

from strategies.smc_fvg import SMCFVGStrategy
from trading.backtest_engine import BacktestConfig, BacktestEngine
from trading.statistics import compute_statistics
from trading.trade_models import Trade, TradeStatus


def run(df, spec, **kw):
    cfg = BacktestConfig("XAUUSD", "M1", topdown_tfs=("M15",), **kw)
    return BacktestEngine(df, spec, cfg).run(SMCFVGStrategy(bias_tf="M15", risk_pct=0.5))


def test_backtest_runs_and_balances(history_m1, gold_spec):
    res = run(history_m1, gold_spec)
    s = res.statistics
    assert s["total_trades"] == len(res.trades) > 0
    assert s["wins"] + s["losses"] + s["breakeven"] == s["total_trades"]
    assert res.equity["balance"].iloc[-1] == pytest.approx(10_000 + s["net_profit"], abs=0.05)
    assert s["max_drawdown"] >= 0
    for t in res.trades:
        assert t.status == "CLOSED" and t.exit_time >= t.entry_time
        assert t.r_multiple is not None


def test_reproducible(history_m1, gold_spec):
    a = run(history_m1, gold_spec).statistics
    b = run(history_m1, gold_spec).statistics
    assert a == b


def test_trade_start_warms_indicators_without_earlier_orders(history_m1, gold_spec):
    end=pd.to_datetime(history_m1.time.iloc[-1],utc=True)
    future=end+pd.Timedelta(days=1)
    result=run(history_m1,gold_spec,trade_start=future)
    assert result.statistics["total_trades"]==0
    assert result.statistics["rejected_orders"]==0


def test_costs_reduce_profit(history_m1, gold_spec):
    base = run(history_m1, gold_spec).statistics["net_profit"]
    costly = run(history_m1, gold_spec, commission_per_lot=7, slippage_points=20).statistics["net_profit"]
    assert costly < base


def _t(i, profit, r):
    t0 = datetime(2026, 1, 1, tzinfo=timezone.utc)
    t = Trade(i, "X", "BUY", 1, t0, 100, stop_loss=99)
    t.status, t.profit, t.r_multiple, t.exit_price = TradeStatus.CLOSED, profit, r, 100 + r
    return t


def test_statistics_definitions():
    trades = [_t(1, 100, 1), _t(2, -50, -0.5), _t(3, 200, 2), _t(4, -50, -0.5), _t(5, -50, -0.5)]
    eq = pd.DataFrame({"time": pd.date_range("2026-01-01", periods=6, freq="1D", tz="UTC"),
                       "equity": [1000, 1100, 1050, 1250, 1200, 1150], "balance": 0})
    s = compute_statistics(trades, eq, 1000)
    assert s["win_rate"] == 40.0
    assert s["profit_factor"] == pytest.approx(300 / 150, abs=1e-3)
    assert s["expectancy"] == 30.0
    assert s["payoff_ratio"] == pytest.approx(150 / 50, abs=1e-3)
    assert s["consecutive_losses"] == 2 and s["consecutive_wins"] == 1
    assert s["max_drawdown"] == 100
    assert s["max_drawdown_pct"] == pytest.approx(100 / 1250 * 100, abs=1e-3)
    assert s["sharpe"] is not None and s["recovery_factor"] == pytest.approx(1.5)


def test_statistics_empty():
    s = compute_statistics([], None, 1000)
    assert s["total_trades"] == 0 and s["profit_factor"] is None and s["sharpe"] is None


def test_persist_and_export(history_m1, gold_spec, tmp_path):
    from storage.database import Database
    res = run(history_m1, gold_spec)
    db = Database(tmp_path / "t.db")
    bid = db.save_backtest(res.meta(), res.statistics, res.trades_as_dicts())
    back = db.load_backtest(bid)
    from smc.smc_engine import SMC_ENGINE_VERSION
    assert back["strategy_version"] == "1.0" and back["smc_version"] == SMC_ENGINE_VERSION
    assert back["parameters"]["strategy"]["bias_tf"] == "M15"
    assert len(back["trades"]) == len(res.trades)
    paths = res.export(tmp_path / "exp")
    assert pd.read_csv(paths["trades_csv"]).shape[0] == len(res.trades)
