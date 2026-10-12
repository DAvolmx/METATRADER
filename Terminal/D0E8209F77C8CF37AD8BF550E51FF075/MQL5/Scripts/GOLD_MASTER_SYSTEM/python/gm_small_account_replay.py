"""Immutable, read-only $10 SMC research replay using closed MT5 bars."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys

import pandas as pd

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'replay_terminal'))
from gm_market_service import atomic_json
from trading.trade_models import SymbolSpec
from trading.backtest_engine import BacktestEngine,BacktestConfig
from strategies.smc_fvg import SMCFVGStrategy


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--symbol',default='XAUUSDmicro')
    p.add_argument('--bars',type=int,default=5000)
    p.add_argument('--balance',type=float,default=10)
    p.add_argument('--risk-pct',type=float,default=1)
    p.add_argument('--challenge-days',type=float,default=3)
    p.add_argument('--goal',type=float,default=100)
    p.add_argument('--terminal',default=os.getenv('GM_TERMINAL_PATH','C:/Program Files/MetaTrader 5/terminal64.exe'))
    a=p.parse_args()
    if (a.bars<500 or not 0<a.balance<=1_000_000 or not 0<a.risk_pct<=1
            or not 0<a.challenge_days<=30 or a.goal<=a.balance):
        p.error('bars >=500; 0 < balance <= 1,000,000; 0 < risk-pct <= 1; goal > balance')
    import MetaTrader5 as mt5
    if not mt5.initialize(a.terminal,timeout=10000): raise SystemExit(str(mt5.last_error()))
    try:
        if not mt5.symbol_select(a.symbol,True): raise SystemExit('symbol unavailable')
        spec=mt5.symbol_info(a.symbol)
        account=mt5.account_info()
        raw=mt5.copy_rates_from_pos(a.symbol,mt5.TIMEFRAME_M5,1,a.bars)
        if raw is None or len(raw)<500: raise SystemExit('closed-bar history unavailable')
        frame=pd.DataFrame(raw)
        frame['time']=pd.to_datetime(frame.time,unit='s',utc=True)
        frame=frame.sort_values('time').drop_duplicates('time').reset_index(drop=True)
        folder=HERE/'runtime'/'research'/('small_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
        folder.mkdir(parents=True,exist_ok=False)
        bars_file=folder/'M5_closed.csv'
        frame.to_csv(bars_file,index=False)
        contract=SymbolSpec(a.symbol,spec.digits,spec.point,spec.trade_contract_size,
                            spec.currency_profit,account.currency,spec.volume_min,
                            spec.volume_max,spec.volume_step,spec.trade_stops_level)
        deadline=frame.time.iloc[-1]+pd.Timedelta(minutes=5)
        trade_start=deadline-pd.Timedelta(days=a.challenge_days)
        cfg=BacktestConfig(a.symbol,'M5',initial_balance=a.balance,slippage_points=2,
                           apply_swap=False,topdown_tfs=('H1',),trade_start=trade_start.to_pydatetime())
        result=BacktestEngine(frame,contract,cfg).run(SMCFVGStrategy(bias_tf='H1',risk_pct=a.risk_pct))
        result.export(folder/'smc_fvg')
        rejection_reasons=dict(Counter(x['reason'] for x in result.rejected_orders))
        active=result.equity[result.equity.time>=trade_start]
        reached=active[active.equity>=a.goal]
        challenge={'goal':a.goal,'deadline_days':a.challenge_days,
                   'trade_start':trade_start.isoformat(),'deadline':deadline.isoformat(),
                   'required_daily_compound_return_pct':100*((a.goal/a.balance)**(1/a.challenge_days)-1),
                   'goal_reached':not reached.empty,
                   'first_goal_time':reached.time.iloc[0].isoformat() if not reached.empty else None,
                   'max_equity':float(active.equity.max()) if len(active) else None,
                   'final_balance':float(result.equity.balance.iloc[-1])}
        report={'validated':False,'promotion_allowed':False,'source':'MT5 closed M5 bars',
                'symbol':a.symbol,'bars':len(frame),'start':frame.time.iloc[0].isoformat(),
                'end':frame.time.iloc[-1].isoformat(),
                'data_sha256':hashlib.sha256(bars_file.read_bytes()).hexdigest(),
                'code_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'initial_balance':a.balance,'risk_pct':a.risk_pct,
                'min_volume':spec.volume_min,'contract_size':spec.trade_contract_size,
                'statistics':result.statistics,'challenge':challenge,
                'rejection_reasons':rejection_reasons,
                'limitations':['historical M5 bid bars, no full tick sequence',
                               'commission and swap not calibrated','same inspected history; no pristine holdout',
                               'one winning trade is not evidence of profitability',
                               'no real order or candidate promotion']}
        atomic_json(folder/'report.json',report)
        print(json.dumps({'report':str(folder/'report.json'),'trades':len(result.trades),
                          'rejected_orders':len(result.rejected_orders)}))
    finally: mt5.shutdown()

if __name__=='__main__': main()
