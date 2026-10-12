"""Download closed H1 bars from MT5, Dukascopy gold and Binance spot. No orders."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone, timedelta
import hashlib, io, json, lzma, struct, urllib.request, urllib.error
from threading import Event
from pathlib import Path
import pandas as pd
from gm_feed import resolve_symbol
from gm_market_service import SPEC_FIELDS

HERE=Path(__file__).resolve().parent
DUKA_RATE_LIMITED=Event()

def fetch(url):
    try:
        return urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'GoldMaster-Research/1.0'}),timeout=20).read()
    except urllib.error.HTTPError as error:
        if error.code==429 and 'dukascopy.com' in url: DUKA_RATE_LIMITED.set()
        raise

def clean(frame):
    frame=frame.sort_values('time').drop_duplicates('time').reset_index(drop=True)
    frame=frame[(frame['low']>0)&(frame['high']>=frame[['open','close']].max(axis=1))
                &(frame['low']<=frame[['open','close']].min(axis=1))].copy()
    return frame

def save(folder, manifest, name, frame, metadata):
    frame=clean(frame)
    if len(frame)<500: raise ValueError(f'{name}: insufficient bars {len(frame)}')
    path=folder/(name+'.csv');frame.to_csv(path,index=False)
    manifest['datasets'][name]={**metadata,'file':path.name,'bars':len(frame),
        'start':frame.time.iloc[0].isoformat(),'end':frame.time.iloc[-1].isoformat(),
        'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
    (folder/'manifest.json').write_text(json.dumps(manifest,indent=2,allow_nan=False),encoding='utf-8')
    print(name,len(frame),flush=True)

def duka_day(day,cache=None):
    cached=cache/(day.strftime('%Y%m%d')+'.csv') if cache else None
    if cached and cached.exists():
        result=pd.read_csv(cached);result['time']=pd.to_datetime(result.time,utc=True);return result
    if DUKA_RATE_LIMITED.is_set(): raise ValueError('Dukascopy downloads paused after HTTP 429')
    prefix=f'https://datafeed.dukascopy.com/datafeed/XAUUSD/{day.year}/{day.month-1:02}/{day.day:02}'
    frames=[]
    for side in ('BID','ASK'):
        data=lzma.decompress(fetch(prefix+f'/{side}_candles_min_1.bi5'))
        if len(data)%24: raise ValueError('invalid Dukascopy record length')
        rows=list(struct.iter_unpack('>5If',data))
        f=pd.DataFrame(rows,columns=['second','open','close','low','high','volume'])
        f['time']=pd.Timestamp(day)+pd.to_timedelta(f.second,unit='s')
        for field in ('open','close','low','high'): f[field]=f[field]/1000
        frames.append(f)
    bid,ask=frames
    bid=bid.merge(ask[['time','open']].rename(columns={'open':'ask_open'}),on='time',how='inner')
    bid['spread_price']=(bid.ask_open-bid.open).clip(lower=0)
    if cached: bid.to_csv(cached,index=False)
    return bid

def collect(folder,days,external_end=None):
    folder.mkdir(parents=True,exist_ok=True)
    manifest={'created_at':datetime.now(timezone.utc).isoformat(),'datasets':{},'errors':{},
              'execution':'disabled','limitations':['Current MT5 metadata is not point-in-time.',
              'External spot is not the same venue/product as Deriv CFDs.',
              'No claim of calibrated broker commission, swap or pristine holdout.']}
    import MetaTrader5 as mt5
    if not mt5.initialize('C:/Program Files/MetaTrader 5/terminal64.exe',timeout=10000):
        manifest['errors']['MT5']=str(mt5.last_error())
    else:
        try:
            aliases={'gold':('XAUUSD',),'gold_micro':('XAUUSDmicro',),'bitcoin':('BTCUSD',),
                'ethereum':('ETHUSD',),'btceth':('BTCETH',),
                'nasdaq':('USTECH','US Tech 100','US_TECH100','USTEC','NAS100','US100'),
                'eurusd':('EURUSD',),'usdjpy':('USDJPY',),'dxy':('DXYUSD',)}
            for asset, names in aliases.items():
                try:
                    symbol=resolve_symbol(mt5,names)
                    if not symbol: raise ValueError('symbol unavailable at Deriv')
                    cached=folder/('mt5_'+asset+'.csv')
                    if cached.exists():
                        df=pd.read_csv(cached);df['time']=pd.to_datetime(df.time,utc=True)
                    else:
                        data=mt5.copy_rates_from_pos(symbol,mt5.TIMEFRAME_H1,1,30000)
                        if data is None: raise ValueError(str(mt5.last_error()))
                        df=pd.DataFrame(data);df['time']=pd.to_datetime(df.time,unit='s',utc=True)
                    spec=mt5.symbol_info(symbol)
                    save(folder,manifest,'mt5_'+asset,df,dict(source='Deriv MT5',asset=asset,
                        symbol=symbol,point=spec.point,tf='H1',spread_basis='reported_H1_points',
                        broker_tradable=True,spec={k:getattr(spec,k,None) for k in SPEC_FIELDS}))
                except Exception as e: manifest['errors']['mt5_'+asset]=str(e)
        finally: mt5.shutdown()
    # Match an actual historical MT5 interval; keep external prices separate.
    gold=manifest['datasets'].get('mt5_gold')
    end=pd.Timestamp(gold['end']).to_pydatetime() if gold else datetime.now(timezone.utc)-timedelta(days=1)
    end=end.replace(hour=0,minute=0,second=0,microsecond=0)
    if external_end: end=pd.Timestamp(external_end,tz='UTC').to_pydatetime()
    dates=[end-timedelta(days=i) for i in range(1,days+1)]
    chunks=[]; missing=[]
    cache=folder/'duka_daily';cache.mkdir(exist_ok=True)
    with ThreadPoolExecutor(max_workers=2) as pool:
        pending={pool.submit(duka_day,d,cache):d for d in dates if d.weekday()<5}
        for task in as_completed(pending):
            try: chunks.append(task.result())
            except Exception as e: missing.append(dict(day=pending[task].isoformat(),error=str(e)))
            if (len(chunks)+len(missing))%25==0:
                print('external_gold_days',len(chunks)+len(missing),'loaded',len(chunks),flush=True)
    if chunks:
        f=pd.concat(chunks).sort_values('time').set_index('time')
        h=f.resample('1h').agg({'open':'first','high':'max','low':'min','close':'last',
                             'volume':'sum','spread_price':'median'}).dropna().reset_index()
        h['spread']=h.spread_price/.001
        try:
            save(folder,manifest,'duka_gold',h,dict(source='Dukascopy',asset='gold',symbol='XAUUSD',
                point=.001,tf='H1',spread_basis='median_of_minute_ask_minus_bid',
                broker_tradable=False,missing_days=missing,
                url_pattern='https://datafeed.dukascopy.com/datafeed/XAUUSD/YYYY/MM_zero_based/DD/SIDE_candles_min_1.bi5'))
        except Exception as e: manifest['errors']['duka_gold']=str(e)
    else: manifest['errors']['duka_gold']=missing
    for pair,asset in (('BTCUSDT','bitcoin'),('ETHUSDT','ethereum'),('ETHBTC','btceth')):
        try:
            cursor=int((end-timedelta(days=days)).timestamp()*1000);finish=int(end.timestamp()*1000)
            rows=[]
            while cursor<finish:
                url=f'https://data-api.binance.vision/api/v3/klines?symbol={pair}&interval=1h&limit=1000&startTime={cursor}&endTime={finish-1}'
                batch=json.loads(fetch(url))
                if not batch: break
                rows.extend(batch);cursor=int(batch[-1][0])+3600000
            df=pd.DataFrame(rows)
            f=pd.DataFrame({'time':pd.to_datetime(df[0],unit='ms',utc=True),
                'open':df[1].astype(float),'high':df[2].astype(float),
                'low':df[3].astype(float),'close':df[4].astype(float)})
            if pair=='ETHBTC':
                lo=1/f.high;hi=1/f.low
                f['open']=1/f.open;f['close']=1/f.close;f['low']=lo;f['high']=hi
            # Explicit cost scenario: 0.20% round trip at signal-price scale; not observed bid/ask.
            point=.00001 if pair=='ETHBTC' else .01
            f['spread']=f.close*.002/point;f['tick_volume']=0
            save(folder,manifest,'binance_'+asset,f,dict(source='Binance spot',asset=asset,
                symbol='BTCETH_inverse_ETHBTC' if pair=='ETHBTC' else pair,point=point,tf='H1',
                spread_basis='modelled_0.20pct_roundtrip_not_observed_bid_ask',broker_tradable=False,
                url='https://data-api.binance.vision/api/v3/klines',derived=pair=='ETHBTC'))
        except Exception as e: manifest['errors']['binance_'+asset]=str(e)
    (folder/'manifest.json').write_text(json.dumps(manifest,indent=2,allow_nan=False),encoding='utf-8')
    print(folder/'manifest.json',flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--days',type=int,default=365)
    p.add_argument('--folder',type=Path,required=True);p.add_argument('--external-end');a=p.parse_args();collect(a.folder,a.days,a.external_end)
