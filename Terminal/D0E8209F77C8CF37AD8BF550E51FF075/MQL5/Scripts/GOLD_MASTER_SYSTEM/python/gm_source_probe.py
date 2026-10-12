import urllib.request
import lzma
import struct
URLS = [
 'https://data-api.binance.vision/api/v3/klines?symbol=ETHBTC&interval=1h&limit=5',
 'https://datafeed.dukascopy.com/datafeed/XAUUSD/2025/05/02/BID_candles_min_1.bi5',
 'https://datafeed.dukascopy.com/datafeed/XAUUSD/2025/05/02/BID_candles_hour_1.bi5']
for url in URLS:
    try:
        data=urllib.request.urlopen(url,timeout=15).read()
        print(url, 'bytes',len(data),flush=True)
        if url.endswith('.bi5'):
            raw=lzma.decompress(data)
            print('decoded',len(raw),'first',struct.unpack('>5If',raw[:24]),flush=True)
    except Exception as error:
        print(url,type(error).__name__,str(error),flush=True)
