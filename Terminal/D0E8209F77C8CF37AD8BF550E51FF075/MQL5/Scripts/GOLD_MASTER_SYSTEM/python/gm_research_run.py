"""Reproducible read-only Deriv study; fixed strategies, no optimization or orders."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import numpy as np
import pandas as pd
from gm_feed import resolve_symbol
from gm_market_service import PROFILES, SPEC_FIELDS, atomic_json

HERE = Path(__file__).resolve().parent
RESEARCH_SEED = 20261006
sys.path.insert(0, str(HERE / "optimizer"))
from gm_lab import feats, s_dema, s_pullback, s_london, sim
from gm_validation import split_trades, bootstrap_metrics


def metrics(trades):
    r = np.array([t.r_multiple for t in trades])
    win, loss = r[r>0].sum(), -r[r<0].sum()
    return {"n":len(r),"expectancy_R":float(r.mean()) if len(r) else None,
            "win_rate":float((r>0).mean()) if len(r) else None,
            "profit_factor_R":float(win/loss) if loss>0 else None}


def scenario_seed(asset, strategy, base_seed=RESEARCH_SEED):
    """Stable independent MC stream per experiment, across Python processes."""
    payload=f"{base_seed}:{asset}:{strategy}".encode("utf-8")
    return int.from_bytes(hashlib.sha256(payload).digest()[:8], "big")


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bars",type=int,default=30000)
    parser.add_argument("--smc-bars",type=int,default=5000)
    parser.add_argument("--mc-runs",type=int,default=2000)
    parser.add_argument("--terminal",default=os.getenv("GM_TERMINAL_PATH", "C:/Program Files/MetaTrader 5/terminal64.exe"))
    args=parser.parse_args()
    import MetaTrader5 as mt5
    if not mt5.initialize(args.terminal,timeout=10000): raise SystemExit(str(mt5.last_error()))
    folder=HERE/"runtime"/"research"/datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder.mkdir(parents=True,exist_ok=False)
    report={"status":"research_only","promotion_allowed":False,"seed":RESEARCH_SEED,
            "selection":"fixed_parameters_no_grid","data_source":"connected MT5 closed bars",
            "limitations":["bar spread; no full historical tick path","commission and historical swaps uncalibrated",
                            "contract metadata is current, not point-in-time","fixed parameters were designed on earlier history; no pristine holdout claim",
                            "R statistics differ from fixed-lot cash returns","not a native MT5 EA backtest"],"assets":{}}
    try:
        account=mt5.account_info()
        for asset in ("gold","nasdaq","bitcoin","dxy"):
            symbol=resolve_symbol(mt5,PROFILES[asset])
            if not symbol:
                report["assets"][asset]={"status":"unresolved"}; continue
            raw=mt5.copy_rates_from_pos(symbol,mt5.TIMEFRAME_M5,1,args.bars)
            if raw is None or len(raw)<500:
                report["assets"][asset]={"symbol":symbol,"status":"insufficient_data","error":str(mt5.last_error())};continue
            df=pd.DataFrame(raw);df["time"]=pd.to_datetime(df.time,unit="s",utc=True)
            df=df.sort_values("time").drop_duplicates("time").reset_index(drop=True)
            path=folder/f"{asset}_M5.csv";df.to_csv(path,index=False)
            spec=mt5.symbol_info(symbol)
            item={"symbol":symbol,"bars":len(df),"start":str(df.time.iloc[0]),"end":str(df.time.iloc[-1]),
                  "sha256":hashlib.sha256(path.read_bytes()).hexdigest(),"spec":{k:getattr(spec,k,None) for k in SPEC_FIELDS},"strategies":{}}
            report["assets"][asset]=item
            print(asset,symbol,len(df),str(df.time.iloc[0]),str(df.time.iloc[-1]),flush=True)
            if asset=="dxy": continue
            hf=df.set_index("time").resample("1h").agg({"open":"first","high":"max","low":"min","close":"last"}).dropna().reset_index()
            # gm_lab uses naive UTC internally; retain UTC in exported CSV.
            inputs=df.copy();inputs["time"]=inputs.time.dt.tz_localize(None);hf["time"]=hf.time.dt.tz_localize(None)
            f=feats(inputs,hf);split=int(len(df)*.7)
            definitions={"dema":(s_dema,dict(fast=21,slow=89,minscore=3,tp=2.,slatr=1.2)),
                         "pullback":(s_pullback,dict(lvl=30,tp=1.5,slatr=1.)),
                         "london":(s_london,dict(tp=2.,slmode="opp",maxw=2.5,trend=True,slatr=.5))}
            for name,(fn,params) in definitions.items():
                sig=fn(f,params)
                train,_,_=split_trades(sim(f,sig,spec.point,288,end_bar=split),split)
                _,test,purged=split_trades(sim(f,sig,spec.point,288,start_bar=split),split)
                stress_f={**f,"spread":f["spread"]*2}
                _,stressed,_=split_trades(sim(stress_f,sig,spec.point,288,start_bar=split,slippage_points=2),split)
                # 100 units at fixed 0.25 units per R. Scenario, not actual broker sizing.
                mc_seed=scenario_seed(asset,name)
                mc=bootstrap_metrics([t.r_multiple*.25 for t in test],100,50,np.random.default_rng(mc_seed),runs=args.mc_runs)
                item["strategies"][name]={"params":params,"train":metrics(train),"holdout":metrics(test),"stress":metrics(stressed),
                                          "purged":len(purged),"montecarlo":mc,"montecarlo_seed":mc_seed,
                                          "simulation_notes":{"entry":"next_M5_open","intrabar_tie":"SL_first",
                                                              "price_basis":"historical_M5_spread_plus_modelled_slippage",
                                                              "commission":"not_calibrated_or_included","swaps":"not_included",
                                                              "historical_ticks":"not_used"},
                                          "mc_unit":"normalized fixed risk 0.25 per R, starting 100",
                                          "validated":False,"session_basis":"UTC hours 07-20; London label not DST-adjusted"}
                pd.DataFrame([t._asdict() for t in test]).to_csv(folder/f"{asset}_{name}_holdout.csv",index=False)
            # Same SMC-FVG engine and execution engine as the trainer.
            sys.path.insert(0,str(HERE.parent/"replay_terminal"))
            from trading.trade_models import SymbolSpec
            from trading.backtest_engine import BacktestConfig,BacktestEngine
            from strategies.smc_fvg import SMCFVGStrategy
            smc_spec=SymbolSpec(symbol,spec.digits,spec.point,spec.trade_contract_size,
                                spec.currency_profit,account.currency if account else None,
                                spec.volume_min,spec.volume_max,spec.volume_step,spec.trade_stops_level)
            if smc_spec.money_per_price_unit(1) is not None:
                cfg=BacktestConfig(symbol,"M5",initial_balance=10000,slippage_points=2,apply_swap=False,topdown_tfs=("H1",))
                result=BacktestEngine(df.tail(args.smc_bars).reset_index(drop=True),smc_spec,cfg).run(SMCFVGStrategy(bias_tf="H1",risk_pct=.25))
                result.export(folder/f"{asset}_smc")
                item["strategies"]["smc_fvg"]={"statistics":result.statistics,"bars":min(len(df),args.smc_bars),
                                               "validated":False,"scope":"fixed strategy descriptive backtest; no optimization"}
            else:
                item["strategies"]["smc_fvg"]={"status":"currency_conversion_required"}
            atomic_json(folder/"report.json",report)
        atomic_json(folder/"report.json",report)
        print(str(folder/"report.json"),flush=True)
    finally: mt5.shutdown()

if __name__=="__main__": main()
