"""Offline candidate research. Never replaces parameters consumed by EAs.

Candidates are versioned with data/code fingerprints and holdout results.
Deployment and live parameter promotion are deliberately outside this command.
"""
import hashlib
import itertools
import json
import logging
import os
from pathlib import Path
import sys
import time
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "optimizer"))
import gm_optimizer as go
from gm_validation import split_trades, select_candidate

GRID = dict(fast=[13,21,34], slow=[55,89], minscore=[3,4,5], tp=[1.5,2.,3.],
            slatr=[1.2,2.], be=[1.5], lock=[.3], chdev=[2.], session=[False], maxbars=[240])

def retrain(symbol):
    mt5 = go.mt5
    info = mt5.symbol_info(symbol)
    if info is None:
        return {"updated": False, "reason": "symbol unavailable"}
    m1, m15 = go.load(symbol, mt5.TIMEFRAME_M1, 99000), go.load(symbol, mt5.TIMEFRAME_M15, 9000)
    if m1 is None or m15 is None:
        return {"updated": False, "reason": "history unavailable"}
    features, split, rows = go.features(m1,m15), int(len(m1)*.7), []
    for values in itertools.product(*GRID.values()):
        params = dict(zip(GRID,values))
        if params["fast"] >= params["slow"]: continue
        trades = go.simulate(features,params,go.signals(features,params),info.point,end_bar=split)
        train,_,_ = split_trades(trades,split)
        rows.append({"P":params,"IS":go.stats(train)})
    selected = select_candidate(rows,40)
    out = {"updated":False,"promotion_allowed":False,"symbol":symbol,"ts":int(time.time()),
           "status":"research_candidate_only","selection":"training_only","grid_trials":len(rows),
           "data_start":str(m1.time.iloc[0]),"data_end":str(m1.time.iloc[-1]),
           "data_sha256":hashlib.sha256(m1.to_csv(index=False).encode()).hexdigest(),
           "code_sha256":hashlib.sha256(Path(go.__file__).read_bytes()).hexdigest(),
           "limitations":["bar execution approximation","swaps and commissions require calibration",
                          "one historical split is not prospective validation"]}
    if selected:
        params = selected["P"]
        trades = go.simulate(features,params,go.signals(features,params),info.point,start_bar=split)
        _,test,purged = split_trades(trades,split)
        out.update(params=params,train=selected["IS"],holdout=go.stats(test),purged=len(purged))
    else:
        out["status"] = "no_positive_training_candidate"
    destination = HERE / "runtime" / "candidates"
    destination.mkdir(parents=True,exist_ok=True)
    name = f"candidate_{time.time_ns()}.json"
    (destination/name).write_text(json.dumps(out,indent=2,allow_nan=False),encoding="utf-8")
    return out

if __name__ == "__main__":
    if go.mt5 is None or not go.mt5.initialize(timeout=10000):
        raise SystemExit("MT5 unavailable")
    try:
        print(json.dumps(retrain(os.getenv("GM_SYMBOL","XAUUSD")),indent=2))
    finally:
        go.mt5.shutdown()
