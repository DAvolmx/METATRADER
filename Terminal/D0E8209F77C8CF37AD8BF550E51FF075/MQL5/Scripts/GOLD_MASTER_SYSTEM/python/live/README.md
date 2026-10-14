# GOLD MASTER — capa EN VIVO (conecta todo)

`gm_live_api.py` es el servicio puente que une MT5 + los servicios Python + el pronóstico
en un solo API JSON que consume el workstation web. Corre en **tu PC Windows** (MT5 es
solo Windows); en Linux funciona en modo lectura de ficheros o offline.

## Cómo se conecta todo

```
   MT5 (cuenta, posiciones, DOM)  ─┐
   gm_intel.py  → intel.txt        ├─►  gm_live_api.py  ─►  /api/snapshot  ─►  Workstation web
   gm_micro.py  → micro.json       │        (FastAPI)         (1 fetch/seg)      (paneles en vivo)
   gm_forecast  → forecast.json    │
   EA/bridge    → ea_state.txt    ─┘
```

## Arranque (en tu PC, con el venv del terminal)

```bash
# 1) servicios que escriben el puente (cada uno en su ventana)
python gm_intel.py            # noticias, COT, flujo → intel.txt, news_calendar.csv
python gm_micro.py            # DXY sintético, OFI, micro-variaciones → micro.json
python offline/gm_forecast.py <datos_M1.csv>   # pronóstico H4 → out_offline/forecast.json

# 2) el API puente
cd python/live
uvicorn gm_live_api:app --port 8777
```

Variables: `GM_SYMBOL` (def. XAUUSD), `GM_BRIDGE_DIR` (def. la carpeta Common\Files\GoldMaster
de MT5; ponla a mano en Linux).

## Endpoints

| Ruta | Qué da | Fuente |
|---|---|---|
| `/api/status` | MT5 on/off, carpeta del puente | — |
| `/api/account` | balance, equity, margen, profit | MT5 → ea_state.txt → offline |
| `/api/positions` | posiciones abiertas | MT5 |
| `/api/quote` | bid/ask/last | MT5 |
| `/api/dom` | profundidad (MarketBookGet) | MT5 (si el broker la publica) |
| `/api/flow` | CVD, VPIN, VWAP, POC, DXY ρ, OFI | intel.txt + micro.json |
| `/api/news` | calendario económico | news_calendar.csv |
| `/api/forecast` | 2 velas H4 + banda + M15 | forecast.json |
| `/api/snapshot` | **todo junto** (un solo fetch) | agregado |

Siempre responde con `"source"`: `mt5` / `bridge` / `cache` / `offline`. **Nunca inventa**
datos de cuenta: si no hay MT5 ni ficheros, dice `offline` con el motivo.

## Conectar el workstation

En el frontend, sustituye el bloque de datos embebidos por un sondeo:

```js
async function tick(){
  const s = await (await fetch("http://127.0.0.1:8777/api/snapshot")).json();
  if (s.account.source !== "offline") paintAccount(s.account);
  if (s.dom.levels.length)           paintDom(s.dom.levels);
  if (s.flow.source  !== "offline")  paintFlow(s.flow);
  paintPositions(s.positions);
}
setInterval(tick, 1000);
```

## Honestidad

La parte en vivo depende de tu MT5 y de que el broker publique DOM (en oro CFD OTC a
menudo no hay libro nivel-2). Esto no promete rentabilidad: informa la decisión, que
sigue siendo tuya. El API nunca manda órdenes por su cuenta.

## Tests

```bash
python -m pytest tests/ -q      # 2 tests: modo offline y lectura del puente
```
