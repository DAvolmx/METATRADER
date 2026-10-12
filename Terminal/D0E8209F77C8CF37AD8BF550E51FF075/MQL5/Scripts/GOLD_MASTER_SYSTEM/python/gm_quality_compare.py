"""Reproduce the experimental quality candidate on a saved research dataset."""
import json, sys
from pathlib import Path
import pandas as pd
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'replay_terminal'))
from trading.trade_models import SymbolSpec
from trading.backtest_engine import BacktestConfig,BacktestEngine
from strategies.smc_quality import SMCQualityStrategy
folder=Path(sys.argv[1]).resolve()
source=json.loads((folder/'report.json').read_text())
output={'validated':False,'promotion_allowed':False,'scope':'descriptive comparison on previously inspected data; not independent validation','assets':{}}
for asset in ('gold','nasdaq','bitcoin'):
    item=source['assets'][asset]; s=item['spec']
    df=pd.read_csv(folder/f'{asset}_M5.csv'); df['time']=pd.to_datetime(df.time,utc=True)
    spec=SymbolSpec(item['symbol'],s['digits'],s['point'],s['trade_contract_size'],s['currency_profit'],'USD',s['volume_min'],s['volume_max'],s['volume_step'],s['trade_stops_level'])
    strategy=SMCQualityStrategy()
    cfg=BacktestConfig(item['symbol'],'M5',initial_balance=10000,slippage_points=2,apply_swap=False,topdown_tfs=('H1',))
    result=BacktestEngine(df.tail(5000).reset_index(drop=True),spec,cfg).run(strategy)
    result.export(folder/f'{asset}_quality')
    output['assets'][asset]={'statistics':result.statistics,'rejections':dict(strategy.rejections),'source_sha256':item['sha256']}
    print(asset,result.statistics,flush=True)
(folder/'quality_comparison.json').write_text(json.dumps(output,indent=2,default=str),encoding='utf-8')
