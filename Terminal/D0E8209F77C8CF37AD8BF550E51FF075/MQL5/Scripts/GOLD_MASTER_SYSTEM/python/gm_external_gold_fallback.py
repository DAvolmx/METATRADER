"""Preserve partial Dukascopy downloads and fetch an explicit gold futures proxy."""
import json,hashlib,urllib.request
from pathlib import Path
import pandas as pd
from gm_history_collect import clean

folder=Path(__file__).resolve().parent/'runtime'/'history_archive_20261007'
manifest=json.loads((folder/'manifest.json').read_text(encoding='utf-8'))
files=list((folder/'duka_daily').glob('*.csv'))
if files:
    frames=[pd.read_csv(p) for p in files];f=pd.concat(frames,ignore_index=True)
    f['time']=pd.to_datetime(f.time,utc=True);f=clean(f)
    f['spread']=f.spread_price/.001
    path=folder/'duka_gold_partial_M1.csv';f.to_csv(path,index=False)
    manifest['datasets']['duka_gold_partial']=dict(source='Dukascopy',asset='gold',symbol='XAUUSD',
        file=path.name,bars=len(f),tf='M1',point=.001,broker_tradable=False,data_quality_passed=False,
        missing_reason='HTTP 429 and incomplete requested trading days; excluded from strategy ranking',
        start=f.time.min().isoformat(),end=f.time.max().isoformat(),
        sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    print('preserved Dukascopy minute bars',len(f),flush=True)
url='https://query1.finance.yahoo.com/v8/finance/chart/GC%3DF?range=2y&interval=1h'
try:
    raw=urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'}),timeout=20).read()
    result=json.loads(raw)['chart']['result'][0];q=result['indicators']['quote'][0]
    f=pd.DataFrame(q);f['time']=pd.to_datetime(result['timestamp'],unit='s',utc=True)
    f=f.dropna(subset=['open','high','low','close']);f=clean(f)
    f=f[f.time+pd.Timedelta(hours=1)<pd.Timestamp.now(tz='UTC')]
    f['spread']=f.close*.0005;f['tick_volume']=f.get('volume',0)
    path=folder/'yahoo_gold_futures.csv';f.to_csv(path,index=False)
    manifest['datasets']['yahoo_gold_futures']=dict(source='Yahoo Finance',asset='gold',symbol='GC=F',
        file=path.name,bars=len(f),tf='H1',point=1,broker_tradable=False,
        spread_basis='modelled_0.05pct_cost_not_observed_bid_ask',
        start=f.time.min().isoformat(),end=f.time.max().isoformat(),url=url,
        sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
        limitations=['Gold futures proxy, not Deriv spot XAUUSD; contract rolls not independently adjusted.'])
    print('gold futures proxy H1',len(f),flush=True)
except Exception as error:
    manifest['errors']['yahoo_gold_futures']=str(error);print('gold futures fallback',error,flush=True)
(folder/'manifest.json').write_text(json.dumps(manifest,indent=2,allow_nan=False),encoding='utf-8')
