# Catálogo de EAs, indicadores y scripts propios

Ficha por fichero `.mq5` **propio** del repositorio. Se evalúan **código y riesgo**, no promesas.
Ninguna ficha afirma que un EA sea rentable: no hay evidencia de eso, y el propio sistema ya ha
medido que las estrategias mecánicas probadas no superan la corrección por pruebas múltiples
(ver [`HALLAZGOS.md`](HALLAZGOS.md), secciones 1 a 3). Un EA bien escrito y uno rentable son cosas
distintas; aquí sólo se puede juzgar la primera.

Lo que sí se dice de cada uno: qué decide y con qué, para qué temporalidad y símbolo está pensado,
qué controles de riesgo tiene y **qué le falta**. El criterio de riesgo usado es el de
[`DOCTRINA_RIESGO.md`](DOCTRINA_RIESGO.md). El mapa de módulos y el contrato de los ficheros del
puente están en [`ARQUITECTURA.md`](ARQUITECTURA.md).

## Alcance

- **Incluido:** `<BASE>/Experts/` (carpetas del usuario), `<BASE>/Indicators/GOLD_MASTER_SYSTEM/`,
  `<BASE>/Scripts/DATOS/` y `<BASE>/Scripts/GOLD_MASTER_SYSTEM/GM_Deploy.mq5`.
  **55 ficheros `.mq5`**: 44 EAs en `Experts/`, 2 indicadores guardados dentro de `Experts/`,
  4 indicadores, 4 scripts de datos y 1 script de despliegue.
- **Excluido** (ejemplos de fábrica de MetaQuotes, fuera de alcance): `Experts/Examples/`,
  `Experts/Advisors/Free Robots/`, `Experts/Advisors/experORO/`, `Experts/Advisors/Expert*.mq5`,
  `Scripts/Examples/`, `Scripts/UnitTests/`, `Indicators/Examples/`,
  `Indicators/Free Indicators/`.
- `<BASE>` = `Terminal/D0E8209F77C8CF37AD8BF550E51FF075/MQL5`.

## Cómo leer las fichas

- **Controles de riesgo** se comprueban uno a uno sobre el código: verificación del resultado de
  `OrderSend`/`CTrade` (**retcode**), validación del stop, suelo de lote mínimo con tope de riesgo,
  filtro de spread, límite de operaciones o de pérdida diaria, comprobación de margen y respeto de
  `SYMBOL_TRADE_STOPS_LEVEL`.
- **Banderas rojas** llevan identificador `BR-nn` y cita `fichero:línea`. Se reservan para lo que
  puede llevar a ruina o a una pérdida no acotada, no para defectos de estilo.
- **Riesgo de ruina** es una valoración del *mecanismo*, no una predicción: alto = el EA puede
  arriesgar una fracción grande e incontrolada del capital; medio = el riesgo por operación está
  acotado pero el agregado o los filtros no; bajo = el riesgo por operación y el agregado están
  acotados y el EA se niega a operar cuando no caben.

---

## Resumen de banderas rojas

**18 banderas rojas** en **17 ficheros**. Detalle completo en cada ficha; índice aquí.

| Id | Fichero:línea | Problema |
|---|---|---|
| BR-01 | `Experts/BRIDGE_PYTHON/TALOS_Bridge_JSON_MT5_Python.mq5:262`, `:287` | Abre **sin stop loss** si el JSON externo no manda `sl_pts` |
| BR-02 | `Experts/BRIDGE_PYTHON/TALOS_Bridge_JSON_MT5_Python.mq5:26`, `:28`, `:240` | Ejecuta órdenes reales por defecto (`InpDemoMode=false`) con lote de hasta 5.0 dictado por un fichero que **nada en el repositorio escribe** |
| BR-03 | `Experts/SMC_MULTI_ACTIVO/HUGOx_StructuralBreakout_Zones.mq5:52`, `:396`, `:437` | `AllowMultiplePositions=true` por defecto **sin tope** de posiciones simultáneas |
| BR-04 | `Experts/SMC_MULTI_ACTIVO/HUGOx_StructuralBreakout_Zones.mq5:19`, `:20` | SL 150 pips > TP 100 pips: relación riesgo/beneficio 1:0,67 fijada en los valores por defecto |
| BR-05 ✅ | `Experts/SCALPER_M1_M5/GRIDOP_ScalperPro_BOS_RSI7_Sesiones.mq5:550` | Suelo de lote mínimo **sin tope de riesgo**: `MathMax(lotsCalc, minLot)` |
| BR-06 ✅ | `Experts/SCALPER_M1_M5/XAU_M1_SCALPER_EMA_ADX_RSI.mq5:193` | Mismo patrón, agravado por `MinLotManual` como suelo adicional |
| BR-07 ✅ | `Experts/SMC_GOLD/PRUEBAS_SMC_BOS_CHoCH_2TP.mq5:146` | Mismo patrón |
| BR-08 ✅ | `Experts/BOTS_ORO/GOLD_MASTER_EA.mq5:368` | Mismo patrón |
| BR-09 ✅ | `Experts/CRIPTOS/eterium.mq5:689` | Mismo patrón (atenuado por tope de 1 posición y límite diario) |
| BR-10 ✅ | `Experts/BOTS_ORO/ORO_MASTER_v1_LoteMin.mq5:686` | Siempre lote mínimo: el riesgo por operación deja de estar controlado |
| BR-11 ✅ | `Experts/BOTS_ORO/ORO_MASTER_v1_SiempreOpera.mq5:690` | Siempre lote mínimo **y sin comprobación de margen**: "intenta abrir pase lo que pase" |
| BR-12 ✅ | `Experts/SMC_GOLD/EXPER_ORO2_SMC_COMPLETO_RSI_FVG.mq5:686` | Casi idéntico a BR-10 (2 líneas de diferencia) y **con el mismo magic** `20260905` |

> ### ✅ BR-05 … BR-12 corregidas
>
> Las ocho se arreglaron con una guarda compartida,
> [`Include/GoldMaster/GoldMaster_LotGuard.mqh`](../../../Include/GoldMaster/GoldMaster_LotGuard.mqh),
> en vez de con ocho parches distintos. La guarda calcula lo que de verdad
> arriesga el lote mínimo y **devuelve 0 (no operar)** si se pasa de los
> límites, porque por debajo del mínimo del bróker no hay nada que recortar:
> la única alternativa honesta a no operar es operar con más riesgo del
> planeado.
>
> Cada EA expone dos entradas nuevas: `InpLG_MaxRiskPct` (techo por operación,
> 5 % de equity por omisión) e `InpLG_MaxOverTarget` (múltiplo máximo del
> riesgo objetivo, 2× por omisión).
>
> Comportamiento validado por simulación de la lógica (oro estándar, stop 4,0):
>
> | Equity | Resultado |
> |---|---|
> | 10 $ | **bloquea** — el mínimo arriesga 40 % |
> | 47,85 $ | **bloquea** — 8,4 % > techo del 5 % |
> | 47,85 $ con stop 1,5 | permite 0,01 (riesgo 1,50 $) |
> | 200 $ | permite 0,03 (riesgo 12,00 $) |
> | 10 $ en **cuenta cent** | permite 0,10 (riesgo 0,40 $) |
>
> Dos agujeros adicionales encontrados al aplicarla, ya cerrados:
> `XAU_M1_SCALPER` devolvía un lote **operable** en tres rutas de fallo de
> datos (ahora bloquea) y su `MinLotManual` configurable podía subir el lote
> por encima de lo aprobado (ahora se le pasa a la guarda); `PRUEBAS_SMC`
> operaba **sin comprobar el lote** en su sitio de llamada.
>
> **Pendiente de tu parte:** compilar en MetaEditor. En este entorno Linux no
> hay compilador MQL5, así que la sintaxis no está verificada por el compilador.

| BR-13 | `Experts/SMC_GOLD/ORO4_SMC_v3_Compacto.mq5:19`, `:141`, `:172` | Hasta 5 entradas, cada una al 2 % completo → ~10 % de riesgo agregado sin tope de grupo ni límite diario |
| BR-14 | `Experts/SMC_GOLD/SCALPER_SMC_EMA_ATR_5pos.mq5:15`, `:19` | Hasta 5 posiciones al 2 % cada una, sin tope agregado ni límite diario |
| BR-15 | `Experts/GRID_PENDIENTES/TALOS_EMA5_13_ATR_Trailing_v10.mq5:10`, `:150`, `:157` | Apila hasta 4 posiciones del mismo lado, una por vela, con lote fijo y sin tope de riesgo |
| BR-16 | `Experts/CRIPTOS/btcusd.mq5:49`, `:50` | Hasta 5 entradas piramidadas por símbolo con lote fijo, **sin límite de pérdida diaria ni filtro de spread** |
| BR-17 | `Include/GoldMaster/GoldMaster_Core.mqh:571` y `Experts/GOLD_MASTER_SYSTEM/GOLD_MASTER_PULLBACK_EA.mq5:79` | Modo "SIN FILTROS" (botón en el gráfico, persistente) pone el tope de riesgo del lote mínimo en `DBL_MAX` |
| BR-18 | `Experts/ESPECIALES_DERIV/EA1_Boom1000_SpikeRetrace_SELL.mq5:24`, `:42` | `InpSLPercent` admite 0 = **sin SL**, y el filtro de spread viene **desactivado** por defecto en un índice sintético |

Defecto de código que no es riesgo de ruina pero impide que el EA funcione, documentado por su
gravedad:

| Id | Fichero:línea | Problema |
|---|---|---|
| D-01 | `Experts/GOLD_MASTER_SCALPER_V3/GOLD_MASTER_SCALPER_V3_VOLATILE.mq5:631` | `trade.Sell(lots, bid, _Symbol, sl, tp, "GMSv3_SM")` invierte argumentos: la firma es `Sell(volume, symbol, price, sl, tp, comment)`, así que pasa un `double` donde va el símbolo y un `string` donde va el precio |

---

## `Experts/GOLD_MASTER_SYSTEM/` — EAs del sistema actual

Todos incluyen `GoldMaster_Core.mqh` y usan `GM_CalcLot()`, que **se niega a operar** (devuelve 0)
cuando el lote mínimo del broker arriesga más de `riesgo × g_gm_minlot_risk_tol`. Es la diferencia
principal respecto a las familias antiguas.

### `GOLD_MASTER_MACRO_LIQUIDITY_EA.mq5` (81 líneas)

- **Nombre interno:** sin `#property copyright`; `#property version "1.00"`, `#property strict`.
- **Estrategia:** canal de regresión de 7 días sobre la **vela H3 ya cerrada**
  (`GM_MacroRead`). Exige pendiente mínima `MinSlopeATR × ATR(M15)`, alineación
  EMA50/EMA200 H1 con la dirección del canal y que el DXY **no** coincida con la dirección del oro
  (`GM_DXYClosed`, con histórico cerrado). Después espera un **barrido** del extremo de la vela H3
  en M15 con recuperación del cierre, confirmación H1 en el mismo sentido (`GM_MacroH1`), y que el
  cierre M15 supere el extremo de la vela anterior. Entra a mercado con SL en el extremo barrido
  menos `StopPadATR × ATR` redondeado al tick, y TP a `RewardRisk` × riesgo, exigiendo que haya
  espacio libre hasta el extremo del canal.
- **Temporalidad / símbolo:** H3 (contexto) + H1 (confirmación) + M15 (gatillo). XAU; con
  `UseDXYFilter=true` el `OnInit` **rechaza** cualquier símbolo que no contenga "XAU" (línea 28).
- **Inputs de riesgo:** `PaperModeOnly=true`, `RiskPct=0.5`, `RiskCashPerTrade=0`,
  `RewardRisk=2`, `MaxSpreadPoints=50`, `MaxDailyLossPct=2`, `MaxAccountStopRiskPct=3`,
  `RiskReservePct=10`, `StopPadATR=0.2`, `SweepExpiryBars=8`.
- **Controles de riesgo:** los más completos del repositorio.
  `g_gm_minlot_risk_tol=1.0` (línea 26, el más estricto); validación de inputs en `OnInit` con
  `INIT_PARAMETERS_INCORRECT`; pérdida diaria con equity del día persistida en `GlobalVariable`
  por servidor+cuenta+magic (sobrevive a reinicios); **presupuesto conjunto de stops** de toda la
  cuenta vía `GM_AccountStopRisk` más una reserva del 10 % (línea 68); `OrderCalcProfit` para
  verificar que la pérdida al SL es negativa; `OrderCalcMargin` contra margen libre;
  `SYMBOL_TRADE_STOPS_LEVEL` comprobado para SL **y** TP (línea 70); `OrderCheck` antes de enviar
  (línea 78); **retcode verificado** (`trade.ResultRetcode()==TRADE_RETCODE_DONE`, línea 80); una
  sola exposición por símbolo (`HasExposure`); modo papel por defecto.
- **Banderas rojas:** ninguna.
- **Duplicados:** no.
- **Nota:** su `Comment` dice de sus propios niveles «niveles candidatos, no libro de órdenes».

### `GOLD_MASTER_PULLBACK_EA.mq5` (172 líneas)

- **Nombre interno:** `GOLD MASTER SYSTEM`, v1.00.
- **Estrategia:** tendencia por EMA50 > EMA200 en M15 **y** EMA50 de H4 subiendo (ventas al revés),
  con cierre por encima de la EMA200. Gatillo: RSI(14) cruza de vuelta el nivel 30 hacia arriba
  (o 70 hacia abajo). SL detrás del último swing de M15 más `SLPadATR × ATR`, acotado a
  [`MinSL_ATR`, `MaxSL_ATR`]; TP a `TP_R` × riesgo. Cierre por tiempo a las `MaxBarsInTrade` velas y
  stop a `+LockR` a partir de `BE_R`.
- **Temporalidad / símbolo:** M15 con contexto H4. Diseñado para oro; `GM_GetProfile` detecta el
  activo.
- **Inputs de riesgo:** `RiskPct=2.0`, `RiskCashPerTrade=0`, `MinLotRiskTol=2.5`,
  `MaxSpreadPts=60`, `MaxPositions=1`, `TP_R=1.5`, `BE_R=1.5`, `LockR=0.3`,
  `SessionStart=7`/`SessionEnd=20`, `UseIntel=true`, `RequireAutonomous=true`,
  `SkipRangeRegime=false`, `Mode` (`MODE_VALIDADO` / `MODE_AGRESIVO`).
- **Controles de riesgo:** `GM_CalcLot` con suelo de lote mínimo y tope; filtro de spread; filtro
  de sesión; una posición; **bloquea entradas si la intel falta, ha caducado o es de otro símbolo**
  (línea 146: `return` con aviso en panel); respeta `block_trading`, `dxy_shock` contrario y
  `gov_block` del puente; exige MODO AUTÓNOMO ON en vivo; `rmult<=0` impide operar; el retcode se
  imprime en el log.
- **Banderas rojas:** **BR-17**. El botón "⚠ SIN FILTROS (opera siempre)" del gráfico
  (líneas 51–52, 78–79) persiste su estado en una `GlobalVariable` por símbolo y pone
  `g_gm_minlot_risk_tol = 1000.0` (línea 165), lo que en `GM_CalcLot` activa `cap = DBL_MAX`
  (`GoldMaster_Core.mqh:571`) y **desactiva el único control que impide arriesgar una fracción
  arbitraria del capital con el lote mínimo**. El propio `Print` de la línea 79 enumera lo que se
  desactiva: noticias, gobernador de riesgo, régimen, DXY shock, sesión, spread y el tope de riesgo
  del lote mínimo. El SL y el TP se siguen colocando, así que la pérdida está acotada por operación,
  pero puede ser una fracción enorme del capital. Con `Mode=MODE_AGRESIVO` se suma riesgo ≥ 3 %,
  24 h y hasta 2 posiciones; el propio EA lo etiqueta «NO validado en backtest» (línea 67).
- **Duplicados:** `AUDIT_20261007/GOLD_MASTER_PULLBACK_EA.mq5` es una instantánea anterior (le
  faltan `OnTradeTransaction` y el arreglo de `MQL_VISUAL_MODE`).

### `GOLD_MASTER_SCALPER_EA.mq5` (308 líneas)

- **Nombre interno:** `David Domez — GOLD MASTER SYSTEM`, v2.00. Su cabecera declara que está
  basado en `ORO_SCALPER_PRO v1.0`.
- **Estrategia:** BOS/CHoCH real sin repintado sobre 300 velas (`GMS_Swings` + `GMS_Events`), y al
  detectar un evento nuevo y reciente guarda dirección y extremos de la vela de ruptura. Tras
  `ConfirmBars` velas exige, todo a la vez: separación EMA20-EMA50 ≥ `MinEMAGap_ATR × ATR`, EMA20 vs
  EMA50 en la dirección, precio al lado correcto de la EMA200 del `TrendTF`, RSI(7) dentro de la
  banda del lado, estructura H1 alineada (`RequireHTFStructure`), que el sesgo DXY no sea contrario
  y que el compuesto del puente no supere `IntelVeto` en contra. Entrada con BUY/SELL **STOP** sobre
  la vela de ruptura (o a mercado) y SL por `SL_ATR_Mult` o detrás del swing contrario, el más
  amplio. Gestión por tick: parcial en TP1, breakeven y trailing.
- **Temporalidad / símbolo:** TF del gráfico (pensado M1/M5) con HTF H1 y EMA200 en M15. Oro.
- **Inputs de riesgo:** `RiskPercent=1.0`, `RiskCashPerTrade=0`, `MinLotRiskTol=1.5`,
  `SL_ATR_Mult=1.5`, `TP1_R=1.0`, `TP2_R=2.5`, `PartialPct=50`, `MaxTradesPerDay=5`,
  `CooldownBars=6`, `MaxSpreadPts=60`, `MinATR_USD=0.8`, `MaxATR_USD=8.0`, `NewsFreezeMin=20`,
  `IntelVeto=0.45`.
- **Controles de riesgo:** `GM_CalcLot`; tope diario de operaciones y cooldown; filtros de spread,
  sesión, ATR mínimo y máximo (bloquea spikes de noticia); filtro de noticias del calendario;
  descarta la señal si `risk > ATR×4`; exige MODO AUTÓNOMO en vivo; expira la orden stop pendiente;
  el retcode se registra.
- **Banderas rojas:** ninguna. Los filtros son numerosos y en `AND`, lo que reduce mucho la
  frecuencia de entrada (es precisamente el problema que la familia `XAU_M1_SCALPER` intentó
  resolver pasando a puntuación).
- **Duplicados:** `AUDIT_20261007/GOLD_MASTER_SCALPER_EA.mq5` es una instantánea anterior. Es la
  versión mantenida de `SCALPER_M1_M5/GRIDOP_ScalperPro_BOS_RSI7_Sesiones.mq5`.

### `GOLD_MASTER_ORB_EA.mq5` (195 líneas)

- **Nombre interno:** `David Domez — GOLD MASTER SYSTEM v3.0`, v3.00.
- **Estrategia:** Opening Range Breakout de la sesión de Londres. Reconstruye el rango de
  `ORB_Hour_Start` a `ORB_Hour_End` leyendo **todas** las velas M1 del intervalo ya terminado y
  abortando si falta alguna (`copied!=expected`, línea 135). Si la amplitud
  del rango queda entre `ORB_RangeMinH1` y `ORB_RangeMaxH1` veces el **ATR(H1)**, coloca pendientes a
  ambos lados con buffer `ORB_BufferATR × ATR(H1)` y SL al lado opuesto (o a la mitad del rango) más
  `ORB_SLPadATR`. OCO: al abrirse una posición cancela la pendiente contraria. Cancela todo a partir
  de las 17 h del servidor.
- **Temporalidad / símbolo:** rango en M1, filtros y SL en ATR(H1), gestión con ATR(M5). Oro.
- **Inputs de riesgo:** `ORB_Risk_Pct=1.0`, `RiskCashPerTrade=0`, `ORB_RR=2.5`,
  `MaxDailyDD_Pct=4.0`, `MaxSpreadPts=50`, `MinLotRiskTol=1.5`, `ORB_BE_R=1.0`,
  `ORB_OCO=true`, `ORB_Cancel_On_NY=true`, `ORB_TrendFilter=false`.
- **Controles de riesgo:** validación de inputs en `OnInit`; drawdown diario que cancela pendientes
  y deja de abrir; filtro de spread; una sola colocación al día (`g_orb_orders_placed`); **no
  construye un rango incompleto**; no presupone que la hora del servidor sea UTC (cancela con
  `hour>=17`, no sólo en el tick de las 17:00); OCO; sizing vía `CGoldMasterPending` con
  `ORB_Risk_Pct` y `RiskCashPerTrade`.
- **Banderas rojas:** ninguna.
- **Notas:** su lógica está replicada en Python en `python/gm_backtest.py`, que simula «exactamente
  como el EA» con supuesto pesimista; es el único EA del repositorio con un backtester propio
  dedicado.

### `GOLD_MASTER_STRUCTURE_EA.mq5` (356 líneas)

- **Nombre interno:** `David Domez — GOLD MASTER SYSTEM`, v1.00.
- **Estrategia:** estructura en dos niveles. Tendencia mayor en H1 por swings confirmados
  (HH/HL o LH/LL) más el último BOS/CHoCH; micro-estructura en M5; sólo opera cuando la micro se
  **re-alinea** con la mayor tras un retroceso. Niveles estructurales: clusters de swings de H4 con
  ≥ `LevelMinTouches` toques, usados para **no** entrar si hay un nivel fuerte en contra a menos de
  `MinRoomR` y para poner el TP en el siguiente nivel si da el RR mínimo. Entrada con BUY/SELL STOP
  sobre el último swing micro con buffer ATR, SL detrás del swing opuesto más `SLPadATR`. La
  pendiente se cancela si la micro rompe en contra (CHoCH contrario) o expira.
- **Temporalidad / símbolo:** H1 (sesgo) + M5 (ejecución) + H4 (niveles). Multi-activo vía
  `GM_GetProfile`.
- **Inputs de riesgo:** `RiskPct=1.0`, `RiskCashPerTrade=0`, `MinRR=2.0`, `MaxRR=4.0`,
  `MinSL_ATR=0.8`, `MaxSL_ATR=4.0`, `MaxTradesPerDay=3`, `MaxSpreadPts=50`,
  `MaxDailyDD_Pct=3.0`, `PendingExpiryBars=12`, `BE_R=1.0`, `BE_NoDiv_R=1.5`, `NoDiv_LockR=0.3`,
  `UseDXYFilter=true`, `RequireEMAAlign=true`.
- **Controles de riesgo:** acota el SL por arriba y por abajo en ATR; exige RR mínimo **y** espacio
  libre hasta el nivel contrario; tope diario de operaciones; drawdown diario; filtro de spread;
  filtro de sesión; expiración de pendientes; filtro DXY; trata explícitamente el caso de **lote no
  divisible** (micro 0.1) moviendo el stop a `+NoDiv_LockR` en vez de intentar un parcial imposible.
  El envío lo hace `CGoldMasterPending`, que **sí** comprueba
  `res.retcode == TRADE_RETCODE_DONE || TRADE_RETCODE_PLACED`
  (`GoldMaster_PendingOrders.mqh:38`, `:243`, `:396`); por eso este fichero no lo repite.
- **Banderas rojas:** ninguna.
- **Duplicados:** no.

### `GOLD_MASTER_EA_v3.mq5` (522 líneas)

- **Nombre interno:** `Gold Master System v3.1`, v3.10.
- **Estrategia:** EA de confluencia. Suma puntos de SMC (`GoldMaster_SMC.mqh`: BOS/CHoCH, order
  blocks con *quality score* ≥ `MinOBQuality`, FVG, liquidez y sus barridos, inducements,
  premium/discount), sesgo multi-TF por EMA (H4/H1/M15), régimen de volatilidad, y votos del
  ensemble ML leído de `ml_predictions.csv`; el compuesto del puente aporta `IntelWeight` puntos y
  veta el lado contrario si supera `IntelVeto`. Entra cuando el score alcanza `MinConfluenceScore`
  sobre 17, colocando pendientes en los OB/FVG con expiración en velas.
- **Temporalidad / símbolo:** TF del gráfico con contexto H4/H1/M15. Oro.
- **Inputs de riesgo:** `RiskPercent=0.5`, `MaxDailyLossPct=2.0`, `MaxDrawdownPct=5.0`,
  `MaxPositions=3`, `MinConfluenceScore=6`, `MinMLVotes=2`, `MinMLConfidence=0.62`,
  `ATR_SL_Mult=1.5`, TP1/TP2/TP3 = 3/5/8 × ATR, `MinLotRiskTol=1.5`, `NewsFreezeMins=30`,
  `MLMaxAgeSecs=300`, `IntelMaxAgeSecs=120`, `IntelVeto=0.55`.
- **Controles de riesgo:** validación de inputs en `OnInit` (línea 112); pérdida diaria y drawdown;
  filtro de noticias con nombre del evento en el panel; filtro de sesión; tope de posiciones y de
  pendientes (`MaxPositions*2`); rechazo si el ATR es inválido; no opera en alta volatilidad sin
  confluencia; `GM_CalcLot`; caducidad de la predicción ML (300 s) y de la intel (120 s).
- **Banderas rojas:** ninguna. El riesgo real es de **sobreajuste**, no de ruina: un score de 17
  componentes con umbral ajustable es un espacio de búsqueda muy grande, y eso es justo lo que
  `HALLAZGOS.md` §2 mide y penaliza.
- **Duplicados:** es la base de `GOLD_MASTER_GLOBAL/GOLD_MASTER_GLOBAL_EA.mq5`.

### `GOLD_ADAPTIVE_EA.mq5` (344 líneas)

- **Nombre interno:** `GoldMaster System`, v1.01, `#property tester_file "GoldMaster\\rules_db.json"`.
- **Estrategia:** no tiene estrategia propia: **ejecuta reglas** validadas que lee de
  `rules_db.json`. Parsea el JSON a mano y sólo acepta una regla si está `active`, `validated`, no
  `test_only`, su `asset` coincide con `_Symbol`, su `tf` es `"M15"`, su `implementation` es
  exactamente `"EMA_CROSS_M15_H1"`, tiene ≥ 30 operaciones de evidencia, un `validated_at` en el
  pasado y un `score` entre `MinRuleScore` y 1.0 (líneas 118–125). Si hay regla elegible, evalúa el
  cruce EMA M15/H1 dentro de la ventana de Londres. SL = `SL_ATR_Mult × ATR(14)`, TP = SL ×
  `TP_RR_Ratio`.
- **Temporalidad / símbolo:** M15, ventana `LondonOpenHour`–`LondonCloseHour` (UTC). El símbolo lo
  fija la regla, que debe coincidir con el del gráfico.
- **Inputs de riesgo:** `PaperModeOnly=true`, `RiskPctPerTrade=3.0`, `RiskCashPerTrade=0`,
  `MinLot=0.01`, `MaxLot=0.10`, `MinRuleScore=0.60`, `SL_ATR_Mult=1.5`, `TP_RR_Ratio=2.0`,
  `RuleReloadMins=15`.
- **Controles de riesgo:** modo papel por defecto, y la ejecución real exige poner
  `PaperModeOnly=false` a mano (líneas 318 y 326); `CalcLotSize` devuelve 0 si el lote no es viable con el
  riesgo configurado y el EA descarta la señal (línea 295); `MaxLot` acota por arriba; una posición
  por símbolo+magic; retcode comprobado y registrado (líneas 327–334); registra también los intentos
  **fallidos** de cargar reglas para no reintentar en cada tick. El snapshot que consume lo filtra
  además `python/gm_rules_bridge.py` con criterios más estrictos y lleva `execution: "disabled"`.
- **Banderas rojas:** ninguna, pero **`RiskPctPerTrade=3.0` es alto** para el único EA cuyo riesgo
  no pasa por `GM_CalcLot`; el tope efectivo lo da `MaxLot=0.10`, no el porcentaje.
- **Nota:** si el fichero de reglas no existe, no carga ninguna regla y no opera. Con
  `RulesUseCommon=false` (por defecto) lo busca en `<BASE>/Files/GoldMaster/`.

### `GOLD_MASTER_GUARDIAN_EA.mq5` (239 líneas)

- **Nombre interno:** `David Domez — GOLD MASTER SYSTEM`, v1.00.
- **Estrategia:** **no abre operaciones**. Es un protector que vigila en cada tick *todas* las
  posiciones, propias, de otros EAs y manuales: pone SL/TP a las que no tienen (SL detrás del último
  swing del `ATR_TF` o por `SL_ATR_Mult`, con suelo `MinStopUSD` y techo `MaxSL_USD`), aplica
  breakeven y trailing, cierra todo y **bloquea el día** al tocar el límite de pérdida diaria,
  limita nuevas posiciones por día, cierra la peor posición si el nivel de margen cae bajo
  `MinMarginPct`, y cierra lo abierto en horas bloqueadas. Además mantiene los gráficos (recarga los
  que se congelan).
- **Temporalidad / símbolo:** indiferente; `OnlySymbolsLike="XAU"` filtra por nombre.
- **Inputs de riesgo:** `MaxDailyLossPct=10.0`, `MaxTradesPerDay=20`, `MinMarginPct=80.0`,
  `MinStopUSD=8.0`, `MaxSL_USD=25.0`, `TP_R=2.0`, `BE_At_R=1.0`, `Trail_ATR=1.5`,
  `Trail_Start_R=1.5`, `GraceSeconds=10`, `ReplaceTinyStops=true`, `CloseOnLimit=true`,
  `CloseManualOnLimits=false`, `BlockedHours="0,1"`, `MaxRiskPctPos=0.0`.
- **Controles de riesgo:** es él mismo un control. Detalles de diseño sensatos: `GraceSeconds`
  espera antes de poner un SL por si lo pone el usuario; con `CloseManualOnLimits=false` a las
  operaciones manuales sólo les **avisa** (`Alert`) en vez de cerrarlas; el comentario de
  `MinMarginPct` documenta que el valor anterior (200) cerraba entradas al instante;
  `MaxRiskPctPos=0.0` está desactivado a propósito porque «en cuentas chicas deja stops diminutos».
- **Banderas rojas:** ninguna. `MaxDailyLossPct=10.0` es permisivo comparado con el 2–3 % del resto
  del sistema, pero es un límite global de cuenta, no un riesgo por operación.
- **Veredicto aparte:** es el EA que conviene tener puesto siempre que haya cualquier otra cosa
  operando.

### `AUDIT_20261007/GOLD_MASTER_PULLBACK_EA.mq5` (156 líneas) y `AUDIT_20261007/GOLD_MASTER_SCALPER_EA.mq5` (292 líneas)

- **Qué son:** instantáneas de auditoría del 7-10-2026 de los dos EAs homónimos de la carpeta padre.
  Verificado por `diff`: el Pullback de la auditoría usa `MQL_TESTER` donde la versión actual usa
  `MQL_VISUAL_MODE` (el arreglo nº 1 documentado en `GoldMaster_Panel.mqh`) y le falta
  `OnTradeTransaction` para registrar el P&L en el panel.
- **Veredicto:** archivar como referencia histórica. No cargar en gráficos: comparten lógica y
  magic con las versiones vigentes.

---

## `Experts/GOLD_MASTER_GLOBAL/`

### `GOLD_MASTER_GLOBAL_EA.mq5` (593 líneas)

- **Nombre interno:** `Gold Master System GLOBAL v1.0`, v1.00.
- **Estrategia:** intento declarado de unificar el repositorio. Toma el núcleo de `EA_v3` (SMC +
  score de confluencia 0-17 + votos ML + puente) y le añade filtro DXY con veto y ajuste de score
  (de `VARIOS2`), sesgo por rendimiento real 10 años, parciales 1R/2R/runner (de `SCALPER2` y
  `COPILOT_v5`), sesiones con rango asiático (de `HUGO`), puntuación de sesión (+2 en overlap),
  ruptura del rango asiático como entrada y un detector de *spike retrace* adaptado de
  `EA1_Boom1000`. Umbral de entrada subido a 7 porque las sesiones aportan hasta +2.
- **Temporalidad / símbolo:** TF del gráfico con contexto multi-TF. Oro.
- **Inputs de riesgo:** `PaperModeOnly=true`, `RiskPercent=0.5`, `MaxDailyLossPct=2.0`,
  `MaxDrawdownPct=5.0`, `MaxPositions=3`, `MinConfluenceScore=7`, `UsePartials=true`
  (`Partial1_Pct=0.50`, `Partial2_Pct=0.30`, `RunnerTrail_ATR=1.5`), `DXY_MaxAgeSecs=90`.
- **Controles de riesgo:** valida inputs en `OnInit` (línea 161); pérdida diaria y drawdown; tope
  conjunto de posiciones y pendientes (líneas 340 y 421); respeta `SYMBOL_TRADE_STOPS_LEVEL`; modo
  papel por defecto; `GM_CalcLot`.
- **Banderas rojas:** ninguna de ruina, pero **una degradación silenciosa importante**: su filtro
  DXY lee `DXYStatePath = "GoldMaster\\gm_state.json"` (línea 81) y **ese fichero no lo escribe nada
  en el repositorio** (ver `ARQUITECTURA.md` §7.13). `CGMDXYFilter` devuelve `bias = 0` si no lo
  encuentra, de modo que `DXYVeto()` nunca veta y `ScoreAdjust()` nunca suma: el EA opera creyendo
  tener filtro DXY cuando no lo tiene, sin emitir ningún aviso.
- **Duplicados:** superconjunto de `GOLD_MASTER_EA_v3.mq5`. Mantener los dos cargados a la vez
  duplicaría la exposición.

---

## `Experts/GOLD_MASTER_SCALPER_V3/`

### `GOLD_MASTER_SCALPER_V3_VOLATILE.mq5` (656 líneas)

- **Nombre interno:** `Gold Master System v3.1 — Volatile XAUUSD`, v3.10.
- **Estrategia:** el `GOLD_MASTER_SCALPER_EA` con **dos juegos de parámetros** y conmutación
  automática: cuando `ATR > VolatileATR_USD` entra en modo volátil (SL más corto con tope absoluto
  `MaxSL_USD`, TP más cercano, parcial mayor, trailing más agresivo, bandas RSI más anchas, cooldown
  más corto, spread máximo más alto y entrada forzada a mercado). Añade un filtro de tendencia HTF
  en M15 (EMA20/50 + ADX ≥ 22), confirmación opcional de momentum en M5, filtro de cuerpo de vela
  (`MaxBody_ATR`) y de proporción mecha/cuerpo, y limita el trailing a una modificación por barra.
- **Temporalidad / símbolo:** M1 con HTF M15 y estructura H1. XAUUSD en días de NFP/CPI/Fed, según
  su cabecera.
- **Inputs de riesgo:** `PaperModeOnly=true`, `RiskPercent=0.8`, `MaxDailyLossPct=2.0`,
  `MinLotRiskTol=1.5`, `MaxTradesPerDay=5`, `MaxSpreadPts=60` / `MaxSpread_V_Pts=120`,
  `MinATR_USD=0.8`, `MaxATR_USD=25.0`, `MaxSL_USD=5.0`.
- **Controles de riesgo:** `GM_CalcLot`; modo papel por defecto; `HasEnoughMargin` con
  `OrderCalcMargin × 1.3` antes de enviar (línea 611); descarta la señal si `risk > ATR×4`
  (línea 600); tope absoluto de SL en dólares; tope diario; pérdida diaria; filtros de spread,
  sesión, ATR, cuerpo y mecha; filtro de noticias; `trade.ResultRetcode()` se registra.
- **Banderas rojas:** ninguna de ruina. Pero **D-01**: en la línea 631,
  `trade.Sell(lots, bid, _Symbol, sl, tp, "GMSv3_SM")` invierte el símbolo y el precio respecto a la
  firma `CTrade::Sell(volume, symbol, price, sl, tp, comment)` (`Include/Trade/Trade.mqh:116`). La
  rama de **venta a mercado** no está bien escrita; las ventas con orden STOP (línea 627) sí lo
  están. Hay que corregirlo y recompilar antes de usar el EA, también en papel, porque
  `ForceMarketInVol=true` hace que el modo volátil use precisamente la rama de mercado.
- **Duplicados:** variante de `GOLD_MASTER_SYSTEM/GOLD_MASTER_SCALPER_EA.mq5`.

---

## `Experts/BRIDGE_PYTHON/`

### `TALOS_Bridge_JSON_MT5_Python.mq5` (475 líneas) — **el fichero de mayor riesgo del repositorio**

- **Nombre interno:** `TALOS Intelligence`, v3.00, «Bridge JSON bidireccional MT5 ↔ Python TALOS».
- **Estrategia:** ninguna propia. Sondea cada `InpPollMs` (1000 ms) el fichero
  `Common\Files\talos_signal.json` y **ejecuta lo que diga**: `BUY`, `SELL` o `CLOSE`, con el `lote`,
  `sl_pts` y `tp_pts` que vengan en el JSON. Escribe `talos_result.json` y `talos_estado.json`, y
  lee también `talos_prediccion.json` y `talos_sentimiento.json`.
- **Temporalidad / símbolo:** el del gráfico. Pensado para oro según el nombre interno
  («TALOS GOLD»), pero nada en el código lo restringe.
- **Inputs de riesgo:** `InpSpreadLimit=80`, `InpMinLot=0.01`, `InpMaxLot=5.0`,
  `InpDailyDDLimit=0.10` (kill-switch diario), `InpDemoMode=false`.
- **Controles de riesgo que sí tiene:** filtro de spread antes de operar (línea 229); kill-switch de
  drawdown diario (`g_KillSwitch`, líneas 219 y 443–448); de-duplicación por `signal_id`;
  `ClampLote` acota al rango `[InpMinLot, InpMaxLot]` y al `volume_step`;
  registra `Trade.ResultOrder()`.
- **Banderas rojas:**
  - **BR-01 — abre sin stop loss.** Líneas 262 y 287:
    `double sl = sl_pts > 0 ? ask - sl_pts * punto : 0;` (y el simétrico para la venta). Si el JSON
    no trae `sl_pts`, o trae 0, o la clave está mal escrita, o el `StringToDouble` falla, **la orden
    se envía con `sl = 0`**, es decir **sin stop**. Lo mismo con el TP. No hay ninguna comprobación
    posterior que lo impida. Un fichero malformado produce una posición sin protección, y el único
    freno queda ser el kill-switch de drawdown diario, que actúa *después* de la pérdida.
  - **BR-02 — ejecución real por defecto desde una fuente que no existe.** `InpDemoMode=false`
    (línea 28) significa que el EA opera en real desde el primer tick. `InpMaxLot=5.0` (línea 26)
    permite que un fichero externo pida 5 lotes, que en XAUUSD son 500 onzas. Y, verificado por
    búsqueda en todo el repositorio, **ningún script de este proyecto escribe
    `talos_signal.json`**: el puente del sistema usa el espacio de nombres `GoldMaster\` con
    `intel.txt` y `commands.csv`, no `talos_*`. Es decir: el productor es externo, desconocido o ya
    no existe, y el consumidor envía dinero real. Un fichero antiguo que quede en la carpeta común
    puede disparar órdenes en cuanto se cargue el EA.
- **Duplicados:** no, pero es funcionalmente redundante con `GoldMaster_Bridge.mqh` +
  `commands.csv`, que sí tiene productor y sí es el camino soportado.
- **Qué haría falta para usarlo:** rechazar cualquier señal con `sl_pts <= 0`; poner
  `InpDemoMode=true` por defecto; bajar `InpMaxLot` a algo coherente con la cuenta; y escribir (o
  identificar) el productor del JSON.

---

## `Experts/BOTS_ORO/`

### `GOLD_MASTER_EA.mq5` (424 líneas)

- **Nombre interno:** `Gold Master System — David Domez`, v2.00, descripción «EA SMC + DXY +
  Scalping + Day Trade para XAUUSD/Deriv». Su cabecera dice que combina ORO3/ORO4 (SMC+EMA200),
  TALOS (agresivo), el scalper multi-posición y el filtro DXY.
- **Estrategia:** pila de EMAs 5/13/50/200 sobre la vela cerrada. Opera a favor del stack y usa la
  EMA200 como sesgo: contra ella **reduce el riesgo** por `InpContraTendFactor` en vez de prohibir.
  Filtro DXY por EMA del símbolo `InpDXYSymbol` comparando `InpDXY_LookBack` barras. SL =
  `InpATR_SL_Mult × ATR`, TP = SL × `InpTP_RR`. Protección escalonada: parcial del 40 % en 1R con SL
  a breakeven, 30 % en 2R con SL a +1R, y trailing ATR del resto a partir de `InpTrailStartR`.
- **Temporalidad / símbolo:** M5/M15 recomendados por la cabecera. XAUUSD / XAUUSDm en Deriv.
- **Inputs de riesgo:** `InpRiskPct=1.5`, `InpMaxPositions=3`, `InpMaxDrawdownPct=5.0`,
  `InpMaxSpread=35`, `InpSlippage=20`, `InpMinATR_Pips=0.30`, `InpContraTendFactor=0.5`.
- **Controles de riesgo:** drawdown diario sobre el balance del inicio del día; filtro de spread;
  filtro de ATR mínimo; filtro de sesiones; tope de 3 posiciones propias (`ContarMisPosiciones`);
  comprobación de margen con `OrderCalcMargin` y caída a lote mínimo si no alcanza; magic propio.
  **No comprueba el retcode** (sólo el booleano de `trade.Buy`/`trade.Sell`, líneas 255 y 266).
- **Banderas rojas:** **BR-08**. `CalcularLote` (línea 356) termina en
  `lot = MathMax(lot_min, MathMin(lot_max, lot))` (línea 368): cuando el riesgo calculado pide menos
  que el lote mínimo del broker, **sube** al mínimo sin comprobar cuánto arriesga eso. Combinado con
  `InpMaxPositions=3` y un riesgo nominal de 1,5 %, en una cuenta pequeña el riesgo real por
  operación puede multiplicarse por un factor arbitrario y el agregado por tres. Es exactamente el
  mecanismo descrito en [`DOCTRINA_RIESGO.md`](DOCTRINA_RIESGO.md) §«El suelo de lote mínimo».
  Además, en la línea 375, si no hay margen suficiente baja a `lot_min` en lugar de **no operar**.
- **Duplicados:** no es un duplicado literal, pero su funcionalidad está cubierta y mejorada por
  `GOLD_MASTER_SYSTEM/GOLD_MASTER_SCALPER_EA.mq5`, que usa `GM_CalcLot`.

### `ORO_MASTER_v1.mq5` (863 líneas)

- **Nombre interno:** `David - Proyecto ORO`, v1.00, con tres líneas de `#property description`.
  Su propia cabecera incluye una **advertencia honesta**: «codigo bien escrito != estrategia
  rentable. Backtestea con "cada tick basado en ticks reales" y haz forward en DEMO antes de operar
  en real».
- **Estrategia:** motor de estructura BOS/CHoCH con swings confirmados por fractal de
  `InpSwingWindow=5` velas a cada lado, con buffer circular y sin look-ahead (precalienta con 600
  velas). Detecta el **order block** del impulso que rompió la estructura (última vela opuesta, hasta
  `InpOB_MaxLookback` atrás) y acepta también un FVG como confirmación alternativa. Espera el
  **retest** de esa zona con colchón `InpRetestBufferATR` durante como máximo `InpRetestMaxVelas`
  velas, y exige micro-confirmación: cruce del RSI(14) sobre el nivel 50 en la vela de entrada. SL
  detrás del order block o por `InpATR_SL_Mult`, el más amplio. Cierra por CHoCH en contra.
- **Temporalidad / símbolo:** M15/M30 según la cabecera. XAUUSD.
- **Inputs de riesgo:** `InpTradingEnabled=true`, `InpMaxPositions=1`, `InpMinBarsEntreTrades=2`,
  `InpMaxSpreadPoints=60.0`, `InpRiskPercent=1.0`, `InpMargenSeguridadPct=80.0`,
  `InpPermitirLoteMinimo=true`, `InpContraTendRiskFactor=0.5`, `InpATR_SL_Mult=1.8`,
  `InpTP_RatioSL=3.0`, parciales 40 %/30 % en 1R/2R, `InpTrailStartR=2.0`.
- **Controles de riesgo:** una sola posición; cooldown entre operaciones; filtro de spread;
  `CalcularLotesPorRiesgo` + `AjustarLotesPorMargen` con `InpMargenSeguridadPct` y **cancelación si
  el lotaje resulta inválido** (línea 680); **retcode comprobado y descrito** (línea 685);
  `InpTradingEnabled=false` permite usarlo sólo para analizar y dibujar.
- **Banderas rojas:** ninguna. Es el mejor construido de las familias antiguas.
- **Duplicados:** base de las dos variantes siguientes y de
  `SMC_GOLD/EXPER_ORO2_SMC_COMPLETO_RSI_FVG.mq5`.

### `ORO_MASTER_v1_LoteMin.mq5` (878 líneas)

- **Nombre interno:** igual que el anterior; cabecera propia «\*\*\* VARIANTE LOTE MINIMO \*\*\*».
  Magic distinto (`20260905`) para poder correr ambos.
- **Diferencia con `ORO_MASTER_v1`:** verificado por `diff`, sólo cambia la cabecera, el magic, el
  bloque de lotaje, los textos de log y el comentario de las órdenes. La lógica de señal es idéntica.
- **Banderas rojas:** **BR-10**. Línea 686:
  `double lotes = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);` — abre **siempre** con el volumen
  mínimo del símbolo, «sin importar el riesgo», como declara su propia cabecera. `InpRiskPercent`
  deja de dimensionar y queda sólo como filtro direccional. Sí comprueba margen (líneas 689–694) y
  sí comprueba retcode. El riesgo por operación es el que salga: en XAUUSD estándar, 0.01 lotes con
  un SL de 1,8 ATR (del orden de 10 $ de precio) son unos 10 $ de pérdida, que en una cuenta de 50 $
  es el 20 % en una sola operación.
- **Veredicto:** su propósito declarado («probar la logica en real/demo con exposicion minima») es
  legítimo. Úsese **en demo**, con conciencia de que el porcentaje de riesgo no se respeta.

### `ORO_MASTER_v1_SiempreOpera.mq5` (879 líneas)

- **Nombre interno:** igual; cabecera «\*\*\* VARIANTE LOTE MINIMO + SIEMPRE INTENTA ABRIR \*\*\*».
  Magic `20260906`.
- **Diferencia:** como la variante de lote mínimo, pero **elimina también la comprobación de
  margen**. Su cabecera es honesta sobre el límite real: «si la cuenta no tiene margen, el BROKER
  rechazara la orden (error 10019) y no habra trade. Ningun codigo puede abrir una posicion sin
  margen suficiente».
- **Banderas rojas:** **BR-11**. Línea 690: lote mínimo fijo y, a diferencia de la variante
  anterior, **ningún filtro previo**; cada señal intenta abrir. Suma el problema de BR-10 (riesgo por
  operación no controlado) y lo agrava eliminando el único freno local que quedaba. El retcode sí se
  comprueba y se informa con el significado del 10019.
- **Veredicto:** archivar. Su única utilidad es diagnosticar si el EA genera señales; para eso basta
  `InpTradingEnabled=false` en `ORO_MASTER_v1.mq5`, que no envía nada.

### `ORO2.mq5` (233 líneas)

- **Nombre interno:** `SMC Execution Bot`, v3.0, fichero original `ORO.mq5`, «EA ESTRUCTURA DE
  MERCADO (SMC Matemático)».
- **Estrategia:** mucho más simple de lo que anuncia. Define «BOS» como el cierre de la vela anterior
  al otro lado de la EMA20, con la EMA20 del lado correcto de la EMA50. SL = `ATRMultiplierSL × ATR`,
  TP = `RatioTP × ATR` (nótese: el TP es un múltiplo del ATR, **no** de R, así que el RR real varía
  con el multiplicador de SL). Trailing al superar `TrailActivation × ATR`.
- **Temporalidad / símbolo:** el comentario interno menciona M1. Oro.
- **Inputs de riesgo:** `RiskPerTrade=2.0`, `ATRMultiplierSL=2.0`, `RatioTP=3.0`,
  `TrailActivation=0.8`. Nada más: **no hay** filtro de spread, de sesión, de noticias, tope diario
  ni límite de pérdida.
- **Controles de riesgo:** sizing por riesgo con `CalculateLotSize`; magic propio (`777000`,
  línea 45); una operación a la vez. **No comprueba el retcode.**
- **Defectos de código a tener en cuenta:**
  - Línea 66: `if(PositionsTotal() > 0) { ManageTrailingStop(); return; }` cuenta las posiciones de
    **todos los símbolos y todos los EAs**, no las propias. Con cualquier otra cosa operando en la
    cuenta, este EA no abre nunca; y su trailing se ejecuta mirando posiciones ajenas.
  - Lee los indicadores en el índice 0 (vela **en formación**, líneas 84–86) y los compara con
    `iClose(...,1)`. La señal cambia dentro de la vela: repinta.
- **Banderas rojas:** ninguna de ruina (hay SL y sizing por riesgo), pero la ausencia total de
  filtros y los dos defectos anteriores lo hacen inservible tal cual.
- **Duplicados:** mismo origen que `SMC_GOLD/ORO4_SMC_v3_Compacto.mq5` (que es este más
  `MaxEntries`), y ambos son la raíz de `ORO3` → `ELIOT1`.

---

## `Experts/SMC_GOLD/`

### `ORO4_SMC_v3_Compacto.mq5` (279 líneas)

- **Nombre interno:** `SMC Execution Bot`, v3.0 (mismo encabezado que `ORO2.mq5`).
- **Estrategia:** idéntica a `ORO2.mq5` (EMA20 vs EMA50 + cierre al otro lado de la EMA20) más un
  contador `entry_count` que permite **varias entradas en la misma señal**.
- **Temporalidad / símbolo:** sin declarar en el fichero; el linaje apunta a M1/M5. Oro.
- **Inputs de riesgo:** `RiskPerTrade=2.0`, `ATRMultiplierSL=2.0`, `RatioTP=3.0`,
  `TrailActivation=0.8`, `MaxEntries=5`.
- **Controles de riesgo:** sizing por riesgo; SL y TP siempre presentes. **No hay** filtro de
  spread, sesión, noticias, tope diario ni límite de pérdida diaria; **no comprueba el retcode**;
  arrastra el mismo uso de `PositionsTotal()` global y la misma lectura de indicadores en índice 0
  que `ORO2.mq5`.
- **Banderas rojas:** **BR-13**. `MaxEntries=5` (línea 19) con la comprobación
  `if(entry_count < MaxEntries)` en las líneas 141 y 172, y cada entrada dimensionada al
  **`RiskPerTrade` completo** (2 %): el riesgo agregado de un cluster llega al ~10 % del balance sin
  ningún tope de grupo, sin stop común que lo reduzca al añadir, y sin límite de pérdida diaria que
  lo corte. A eso se suma el suelo de lote mínimo de `CalculateLotSize`, que puede elevar cada
  entrada por encima del 2 % nominal.
- **Duplicados:** `ORO2.mq5` es este mismo EA sin `MaxEntries`.

### `ORO3_SMC_v4_EMA200_Parciales.mq5` (497 líneas)

- **Nombre interno:** `SMC Execution Bot`, v4.0, fichero original `ORO_v4.0.mq5`.
- **Estrategia:** la de `ORO4`/`ORO2` más tres cambios que la cabecera documenta: (1) EMA200 como
  **sesgo direccional** que permite ambos lados pero reduce el riesgo en contra por
  `ContraTendRiskFactor`; (2) protección escalonada: parcial en 1R → SL a breakeven, parcial en 2R →
  SL a +1R, trailing ATR del resto, **con *fallback*** que, si el lote es demasiado pequeño para
  partirlo (típico en cuentas 1:1), omite el parcial pero igualmente mueve el SL; (3) ajuste por
  margen con `OrderCalcMargin` para evitar el 10019.
- **Temporalidad / símbolo:** oro; TF no declarada.
- **Inputs de riesgo:** `RiskPerTrade=2.0`, `ATRMultiplierSL=2.0` (define 1R), `RatioTP=3.0`,
  `ContraTendRiskFactor=0.5`, parciales 40 %/30 % en 1R/2R, `TrailStartR=2.0`,
  `TrailATRMult=1.0`, `MargenSeguridadPct=80.0`, `PermitirLoteMinimo=true`, `MagicNumber=777000`.
- **Controles de riesgo:** sizing por riesgo con ajuste por margen; parciales con breakeven y lock;
  manejo explícito del lote indivisible; magic propio; retcode comprobado. Sigue **sin** filtro de
  spread, de sesión, de noticias ni límite de pérdida diaria.
- **Banderas rojas:** ninguna marcada. `PermitirLoteMinimo=true` es el mismo mecanismo de BR-08 pero
  aquí es un input explícito y documentado («Abrir con lote minimo si el riesgo pide menos»), y hay
  ajuste por margen; conviene ponerlo en `false` en cuentas pequeñas.
- **Duplicados:** evolución de `ORO4`; superado por `ELIOT1`.

### `ELIOT1_SMC_v5_FVG_Liquidez_3TP.mq5` (605 líneas)

- **Nombre interno:** `SMC Elite Execution Bot`, v5.0, fichero original `ORO_v5.0_SMC.mq5`.
- **Estrategia:** la rama más desarrollada de la familia ORO. Suma a `ORO3`: BOS y CHoCH explícitos,
  zonas de liquidez con tolerancia `LiquidezTolerance`, FVG como objetivos parciales, trailing
  adaptativo a la estructura y filtro de sesgo institucional en el TF `TimeframeSesgo` (H1). Tres
  objetivos: 1.5R / 2.5R / 4R con parciales del 35 % y 30 % y runner.
- **Temporalidad / símbolo:** TF del gráfico con sesgo en H1. Oro.
- **Inputs de riesgo:** `RiskPerTrade=2.0`, `ATRMultiplierSL=1.8`, TP 1.5/2.5/4.0 R,
  `Parcial1_Pct=35`, `Parcial2_Pct=30`, `TrailStartR=1.5`, `TrailATRMult=1.2`,
  `MargenSeguridadPct=80.0`, `PermitirLoteMinimo=true`, `LookbackBars=50`, `MagicNumber=777001`.
- **Controles de riesgo:** sizing por riesgo con ajuste por margen; parciales con breakeven y lock;
  trailing adaptativo; magic propio. **No comprueba el retcode** (sólo el booleano, líneas 248 y
  270). Sigue sin filtro de spread, sesión, noticias ni límite diario.
- **Banderas rojas:** ninguna marcada; mismas reservas sobre `PermitirLoteMinimo` que en `ORO3`.
- **Duplicados:** es el final de la línea `ORO2` → `ORO4` → `ORO3` → `ELIOT1`. De los cuatro, éste
  es el único que merece revisión; los otros tres son versiones anteriores.

### `EXPER_ORO2_SMC_COMPLETO_RSI_FVG.mq5` (877 líneas)

- **Qué es:** prácticamente el mismo EA que `Experts/BOTS_ORO/ORO_MASTER_v1_LoteMin.mq5`:
  **2 líneas de diferencia** (verificado con `diff`; los hashes NO coinciden, así que
  no es un duplicado literal) y **el mismo magic `20260905`**.
  Verificado: el `diff` sólo señala la ausencia de salto de línea final. Mismo magic
  (`20260905`), mismo comentario de orden (`ORO_MASTER_MIN`).
- **Banderas rojas:** **BR-12**, la misma BR-10 del original: línea 686, lote mínimo fijo.
- **Riesgo adicional por ser duplicado:** si se cargan los dos ficheros en gráficos distintos,
  comparten magic, así que cada instancia contará las posiciones de la otra como propias y la
  gestión de parciales y trailing interferirá. Es un modo de fallo silencioso.
- **Veredicto:** **borrar este fichero** y conservar el de `BOTS_ORO/`.

### `SCALPER_SMC_EMA_ATR_5pos.mq5` (472 líneas)

- **Nombre interno:** `SMC Scalping Bot`, v3.0, fichero original `ScalpingBot_SMC.mq5`.
- **Estrategia:** misma señal del linaje `ORO2` (EMA20/EMA50 + ATR) en modo scalping, abriendo hasta
  `InpMaxPositions` posiciones simultáneas numeradas en el comentario (`SMC Scalp #n`).
- **Temporalidad / símbolo:** scalping; TF no declarada. Oro.
- **Inputs de riesgo:** `RiskPerTrade=2.0`, `ATRMultiplierSL=2.0`, `RatioTP=3.0`,
  `TrailActivation=0.8`, `InpMaxPositions=5`, `InpSlippage=50`, `InpMagicNumber=777000`,
  `InpUseTrailing=true`.
- **Controles de riesgo:** sizing por riesgo; SL y TP presentes; retcode consultado en el log de
  error. **No hay** filtro de spread, sesión, noticias, tope de operaciones diarias ni límite de
  pérdida diaria.
- **Banderas rojas:** **BR-14**. `InpMaxPositions=5` (línea 19) con `RiskPerTrade=2.0` (línea 15)
  y **sin tope de riesgo agregado**: 5 posiciones simultáneas al 2 % cada una son ~10 % del balance
  expuesto a la vez, todas correlacionadas porque son el mismo símbolo y la misma señal. No hay stop
  común que baje el riesgo del grupo al añadir (compárese con
  `SCALPER_M1_M5/SCALPER2_Piramide`, que sí lo tiene) ni límite diario que corte una racha.
  Comparte `MagicNumber=777000` con `ORO3` y `ORO4`, lo que provoca interferencia si se cargan
  juntos.
- **Duplicados:** variante multi-posición del linaje `ORO2`.

### `PRUEBAS_SMC_BOS_CHoCH_2TP.mq5` (318 líneas)

- **Nombre interno:** sin `#property copyright` propio relevante; el nombre del fichero indica su
  carácter de prueba.
- **Estrategia:** BOS/CHoCH con swings por fractal, construcción de zonas y dos objetivos (TP1/TP2)
  gestionados **en código**, no en el servidor.
- **Temporalidad / símbolo:** M15 por el `ZoneLookback` del indicador hermano. Oro.
- **Inputs de riesgo:** `RiskPercent` (sizing por riesgo). Sin filtros de spread, sesión ni límites
  diarios.
- **Controles de riesgo:** SL siempre presente; retcode consultado.
- **Banderas rojas:**
  - **BR-07**. `CalcLotSize` (línea 129) termina en `lot = MathMax(minLot, MathMin(maxLot, lot))`
    (línea 146):
    suelo de lote mínimo sin tope de riesgo.
  - **Riesgo operativo relacionado, no marcado como BR aparte:** las órdenes se envían con
    **TP = 0** (líneas 160 y 162: `trade.Sell(lot,_Symbol,0,sl,0,...)`) porque TP1 y TP2 se guardan
    en variables (`activeTP1`, `activeTP2`) y se gestionan por tick. Si el EA se descarga, el
    terminal se cierra o el gráfico cambia de símbolo, la posición **queda sin objetivo** (el SL sí
    está en el servidor y protege). Es una dependencia del EA que conviene conocer.
- **Duplicados:** su lógica de zonas y niveles es la misma que el indicador
  `Experts/INDICADORES_SMC/SMC_SLTP_Indicator_BOS_Zones.mq5`, que la dibuja sin operar.
- **Veredicto:** es un banco de pruebas, y como tal debería quedarse en demo.

### `Bot_Liquidez_UltraRapido_4H_15M.mq5` (400 líneas)

- **Nombre interno:** `Estrategia Liquidez 4H/15M`, v3.10, descripción «Ejecución Asíncrona + BE
  Inteligente + Trailing + Filtros». Era `Experts/experto oro.mq5` antes de la reorganización.
- **Estrategia:** gatillo de liquidez 4H/15M con filtro de tendencia EMA50/EMA200 + ADX ≥ 22 y
  confirmación EMA en M15. SL/TP dinámicos por ATR (`1.2 ×` y `3.0 ×`) con *fallback* a 80/200 pips
  fijos. Breakeven a 40 pips **con desplazamiento de +15 pips** (el comentario de la línea 29 lo
  subraya: «BE en +15 pips (NO en $0!) - Bloquea pérdidas») y trailing posterior de 30 pips con
  paso de 10.
- **Temporalidad / símbolo:** 4H (contexto) + M15 (gatillo). Oro.
- **Inputs de riesgo:** `InpLotSize=0.01` (lote fijo), `InpMagicNumber=999154`,
  `InpSpreadMaxPips=3.0`, `InpHoraInicio=8`/`InpHoraFin=20`, `InpMaxOpsDia=2`,
  `InpCooldownMin=60`, `InpAdxMinimo=22.0`.
- **Controles de riesgo:** filtro de spread (3 pips, estricto); filtro horario que evita la apertura
  asiática; **tope de 2 operaciones al día**; cooldown de 60 minutos; breakeven con desplazamiento
  positivo; filtro ADX; magic propio en `request.magic` y en `SetExpertMagicNumber`; SL y TP siempre
  presentes. Varios comentarios documentan el valor anterior de cada parámetro y por qué se cambió,
  lo que indica iteración sobre backtest.
- **Puntos a vigilar (no son banderas rojas):**
  - El lote es **fijo** (`InpLotSize=0.01`): el riesgo por operación no se adapta al capital ni a la
    distancia del SL.
  - Usa `OrderSendAsync` (línea 298) y sólo comprueba el booleano de retorno. Con envío asíncrono
    ese booleano significa «encolado», no «aceptado por el servidor»; el veredicto real llegaría en
    `OnTradeTransaction`, que este EA **no implementa**. El contador diario `g_ops_hoy` se incrementa
    al encolar (líneas 202 y 210), así que una orden rechazada consume cupo diario.
- **Duplicados:** no.

---

## `Experts/SMC_MULTI_ACTIVO/`

### `HUGO_MultiSMC_v3.20_XAU_OB.mq5` (682 líneas) y `VARIOS1_MultiSMC_v3.20_XAU_XAG.mq5` (683 líneas)

- **Nombre interno (ambos):** `MultiAsset SMC Deriv`, v3.20, fichero original
  `MultiAssetSMC_Deriv.mq5`, «MultiAsset SMC EA v3.2 - Optimizado para Deriv».
- **Son el mismo EA.** Verificado por `diff`: la **única** diferencia funcional es el valor por
  defecto de `UseXAGUSD` (línea 17): `false` en `HUGO`, `true` en `VARIOS1`. Todo lo demás, incluido
  `MagicNumber = 20260917`, es idéntico.
- **Estrategia:** multi-símbolo (XAUUSD, XAGUSD, USOIL, UKOIL activables). Estructura en H1 sobre
  `CandlasEstructura=50` velas con swings confirmados por `SwingConfirmBars=2`; detecta el order
  block en las `CandlasOB=5` velas previas al impulso exigiendo cuerpo ≥ `OB_MinBody` del rango;
  entrada en M15 al retestear el OB, con RSI(14) fuera de las zonas `RSI_OB=65` / `RSI_OS=35`. SL al
  borde del OB menos `SL_ATR_Multiplier × ATR`, TP a `TP_RR_Ratio` × riesgo.
- **Temporalidad / símbolo:** H1 estructura + M15 entrada; multi-activo con `SufijoSimbolo` para los
  sufijos del broker.
- **Inputs de riesgo:** `RiesgoPorcentaje=1.0`, `SL_ATR_Multiplier=1.5`, `TP_RR_Ratio=2.0`,
  `MaxTradesPorSimbolo=1`, `MaxTradesTotales=2`, `MaxDailyDrawdown=12.0`,
  `MaxSpreadMultiplier=4.0` (relativo a la **mediana** del spread del símbolo),
  `MaxATRMultiplier=2.5` (relativo a la mediana del ATR), `CooldownSL_Minutos=15`,
  `FiltrarSesion=true` 7–20 h, `EvitarViernesTarde=true`, `UsarTrailing=false`.
- **Controles de riesgo:** sizing por riesgo; tope por símbolo **y** total; drawdown diario del 12 %;
  **filtros de spread y ATR adaptativos** (comparan contra la mediana medida del propio símbolo en
  vez de un umbral fijo, líneas 253 y 263), que es el enfoque correcto para un broker con spread
  variable; cooldown tras un SL; filtro de sesión; evita el viernes por la tarde; comprueba
  `lote > 0` antes de enviar (líneas 427 y 447). **No comprueba el retcode**.
- **Banderas rojas:** ninguna. `MaxDailyDrawdown=12.0` es alto pero es un límite de cuenta.
- **Duplicados:** uno de los dos debe desaparecer. Comparten `MagicNumber`, así que cargarlos a la
  vez hace que cada uno cuente las posiciones del otro: `MaxTradesTotales=2` se convierte en un
  límite compartido mal contabilizado. **Conservar uno y exponer `UseXAGUSD` como input a cambiar en
  el gráfico, que es lo que ya es.**

### `VARIOS2_MultiSMC_v3.70_DXY_Filter.mq5` (839 líneas)

- **Nombre interno:** `MultiAsset SMC Deriv`, v3.70, «XAUUSD + XAGUSD + GBPUSD + DXY Filtro».
- **Estrategia:** la v3.20 anterior más (1) GBPUSD como tercer símbolo con su propio sufijo y
  (2) un **filtro DXY** que lee el símbolo `NombreDXY="USDX"` del broker, calcula una EMA de
  `EMA_DXY_Period=50` en `TF_DXY=PERIOD_H4` y veta las direcciones que contradicen el dólar. Sube
  `MaxTradesTotales` a 3.
- **Temporalidad / símbolo:** H1 + M15, con DXY en H4. XAUUSD + XAGUSD + GBPUSD.
- **Inputs de riesgo:** como la v3.20, con `MaxTradesTotales=3`, más `UseDXYFilter=true`,
  `NombreDXY="USDX"`, `TF_DXY=PERIOD_H4`, `EMA_DXY_Period=50`.
- **Controles de riesgo:** los de la v3.20 (filtros de spread y ATR adaptativos, topes por símbolo y
  total, drawdown diario, cooldown tras SL, sesión, viernes) más el veto DXY. **No comprueba el
  retcode.**
- **Banderas rojas:** ninguna. Un aviso práctico: si el broker no tiene el símbolo `USDX`, hay que
  comprobar qué hace el filtro en ese caso antes de confiar en él — el enfoque robusto es el de
  `GoldMaster_DXY.mqh`, que sintetiza el índice con los pares del broker cuando no existe.
- **Duplicados:** evolución de `HUGO`/`VARIOS1`. Es la versión a conservar de las tres.

### `HUGOx_StructuralBreakout_Zones.mq5` (583 líneas)

- **Nombre interno:** «XAUUSD - Consolidation Structural Breakout EA», sin autor;
  «Estrategia: Acción del precio / Consolidación / Ruptura — Sin indicadores».
- **Estrategia:** sin indicadores, sólo acción del precio. Busca una zona de consolidación de
  `ConsolidationBars=8` velas cuyo rango total no supere `MaxZoneRangeFactor=3.0` veces el tamaño
  medio de vela y en la que ninguna vela tenga cuerpo dominante (`MaxBodyPercent=0.45`), con mecha
  mínima `MinWickBodyRatio=0.80` para interpretarla como búsqueda de liquidez. Entra en la ruptura
  cuando una vela tiene cuerpo ≥ `MinBreakoutBodyPercent=0.55` y cierra al menos
  `MinCloseOutsidePercent=0.60` fuera de la zona. `BreakoutMemoryBars=20` evita repetir la misma
  ruptura.
- **Temporalidad / símbolo:** `InpTF=PERIOD_M15`; `InpSymbol` vacío = el del gráfico. XAUUSD, con
  `PipSize=0.01`.
- **Inputs de riesgo:** `LotSize=0.01` (**fijo**), `StopLossPips=150.0`, `TakeProfitPips=100.0`,
  `BreakEvenPips=50.0`, `AllowMultiplePositions=true`, `MagicNumber=26092601`.
- **Controles de riesgo:** SL y TP siempre presentes; breakeven; **retcode comprobado y descrito**
  (líneas 427 y 468); magic propio; memoria de rupturas. **No hay**
  filtro de spread, de sesión, de noticias, tope de operaciones diarias, límite de pérdida diaria ni
  comprobación de margen.
- **Banderas rojas:**
  - **BR-03 — acumulación sin tope.** `AllowMultiplePositions=true` por defecto (línea 52), y el
    único uso de ese input es `if(!AllowMultiplePositions && CountMyPositions() > 0) return;`
    (líneas 396 y 437). Es decir, **cuando está en `true` no existe ningún límite superior** al
    número de posiciones simultáneas: no hay `MaxPositions`, ni tope de riesgo agregado, ni límite
    diario, ni comprobación de margen. Cada ruptura nueva añade otra posición de 0.01 lotes con SL
    de 150 pips. En XAUUSD estándar eso son ~150 $ de pérdida por cada 0.1 lotes acumulados; en una
    secuencia de rupturas falsas en un mismo tramo lateral, las posiciones se suman sin freno. Es
    una rejilla sin límite por acumulación, aunque el fichero no se llame "grid".
  - **BR-04 — relación riesgo/beneficio negativa por defecto.** `StopLossPips=150.0` (línea 19)
    frente a `TakeProfitPips=100.0` (línea 20): cada operación arriesga 1,5 para ganar 1. Con esos
    valores hace falta una tasa de acierto sostenida por encima del 60 % **antes de costes** sólo
    para empatar, y no hay nada en el repositorio que la respalde (ver `HALLAZGOS.md` §1).
- **Duplicados:** no.
- **Veredicto:** archivar. Si se quiere rescatar la idea de ruptura de consolidación, su detección
  es lo único reutilizable; la gestión hay que reescribirla.

---

## `Experts/SCALPER_M1_M5/`

### `GRIDOP_ScalperPro_BOS_RSI7_Sesiones.mq5` (616 líneas)

- **Nombre interno:** `ORO Scalper Pro`, v1.00, fichero original `ORO_SCALPER_PRO.mq5`, «Estrategia:
  BOS + RSI(7) + EMA Trend + Sesión Londres/NY».
- **Estrategia:** BOS detectado con swings de `SwingWindow=3`, confirmación de `ConfirmBars=2`
  velas, EMA20/EMA50 en la dirección, EMA200 del TF superior como sesgo macro, RSI(7) dentro de la
  banda del lado (45–65 compras, 35–55 ventas), ATR entre `Min_ATR_Pips` y `Max_ATR_Pips`, y
  separación mínima EMA20-EMA50. SL = `SL_ATR_Mult × ATR`, TP1 a 2 ATR con cierre del 50 % y TP2 a
  4 ATR.
- **Temporalidad / símbolo:** M1/M5, sesiones Londres 8–12 y NY 13–20 UTC. XAUUSD.
- **Inputs de riesgo:** `RiskPercent=1.0`, `SL_ATR_Mult=2.0`, `TP1_ATR_Mult=2.0`,
  `TP2_ATR_Mult=4.0`, `UsePartialClose=true`, `MaxTradesPerDay=5`, `CooldownBars=8`,
  `Min_ATR_Pips=25.0`, `Max_ATR_Pips=150.0`, `Min_EMA_Distance=10.0`, `MagicNumber=202600`.
- **Controles de riesgo:** tope de 5 operaciones al día; cooldown de 8 velas; filtros de ATR mínimo
  y máximo; filtro de sesión; cierre parcial; una operación activa (`currentTicket`); magic propio.
  Comprueba el booleano de `trade.Buy`/`trade.Sell` e imprime `GetLastError()` en el fallo, pero
  **no el retcode**. **No hay** filtro de spread ni límite de pérdida diaria.
- **Banderas rojas:** **BR-05**. `CalculateLots` (línea 529) termina en
  `lotsCalc = MathMax(lotsCalc, minLot)` (línea 550) y devuelve ese valor sin comprobar cuánto
  arriesga. Es el patrón exacto que `GM_CalcLot` corrige: cuando el riesgo pedido es menor que el
  lote mínimo del broker, el EA **opera igual** con el mínimo. Con `SL_ATR_Mult=2.0` en M1 de oro y
  una cuenta pequeña, el riesgo real por operación puede ser varias veces el 1 % nominal, y el tope
  diario de 5 operaciones no lo acota en dinero.
- **Duplicados:** es el **predecesor** de `GOLD_MASTER_SYSTEM/GOLD_MASTER_SCALPER_EA.mq5`, que lo
  declara en su cabecera («Basado en ORO_SCALPER_PRO v1.0») y le añade BOS sin repintado, estructura
  H1, DXY, intel, noticias, filtros en dólares, entrada por stop, modo de llenado automático y
  `GM_CalcLot`. Comparte `MagicNumber=202600` con él: **no cargar ambos**.
- **Veredicto:** archivar en favor de `GOLD_MASTER_SCALPER_EA.mq5`.

### `SCALPER2_Piramide_EMA_ADX_H4filter.mq5` (679 líneas)

- **Nombre interno:** `PiramideH1 v2.1`, v2.10, fichero original `PiramideH1_v21.mq5`.
- **Estrategia:** pirámide **a favor** de la tendencia con **stop común**. Primera entrada sólo tras
  un pullback a la EMA rápida (tolerancia `InpPullbackTolAtr`), con EMA20/EMA50 separadas al menos
  `InpMinEmaDiffAtr`, pendiente de la EMA lenta a favor en `InpSlopeBars`, ADX ≥ `InpAdxMin` y
  filtro de TF superior (EMA de H4 con pendiente y precio del lado correcto). Añade posiciones
  cuando el precio ha avanzado `InpEntryStepAtr=1.5` ATR a favor, y al añadir **sube el SL de las
  anteriores al del nuevo nivel**, de modo que el riesgo del grupo no se triplica. Trailing del stop
  común. Cierra posiciones contrarias si cambia la tendencia.
- **Temporalidad / símbolo:** `InpTF=PERIOD_H1` con filtro en H4. Símbolo configurable.
- **Inputs de riesgo:** `InpDryRun=false`, `InpMaxPositions=3`, `InpEntryStepAtr=1.5`,
  `InpMinBarsBetween=3`, `InpSLAtr=2.0`, `InpTPAtr=4.0`, `InpTrailAtr=2.5`, `InpLoteFijo=0.0`
  (0 = por riesgo), `InpRiesgoPct=1.0`, **`InpRiesgoMaxTotalPct=3.0`**,
  **`InpRiesgoMaxLoteMin=5.0`**, `InpDailyMaxLossPct=3.0`, `InpMaxSpreadPts=50`,
  `InpViernesCorteHora=20`, `InpAdxMin=20.0`, `InpVelasTrasPerdida=6`.
- **Controles de riesgo:** los mejores de las familias no-`GoldMaster`. **Stop común** que acota el
  riesgo del grupo; **tope explícito de riesgo abierto total** (`InpRiesgoMaxTotalPct=3.0`);
  **tope del lote mínimo** (`InpRiesgoMaxLoteMin=5.0`: si el lote mínimo arriesga más de ese
  porcentaje, no entra — es el control que les falta a BR-05…BR-09); pérdida diaria **realizada +
  flotante** (la cabecera explica que en la v1 sólo se medía la flotante y «casi nunca se
  activaba»); filtro de spread; pausa de `InpVelasTrasPerdida` velas tras un cierre en pérdida;
  cooldown en velas reales con `iBarShift`; estado restaurado al reiniciar; `InpDryRun` para no
  operar; usa los dígitos del símbolo operado, no los del gráfico; indicadores leídos en la **vela
  cerrada** (la cabecera documenta que la v1 repintaba).
- **Banderas rojas:** ninguna. **La pirámide no es martingala**: añade cuando el precio ya se ha
  movido a favor `1.5 ATR`, nunca después de una pérdida, y el stop común reduce el riesgo del grupo
  en cada añadido.
- **Honestidad del propio fichero:** su cabecera registra el resultado medido en el backtest de
  septiembre de 2026: «12 primeras entradas, −162 USD; las ampliaciones de la pirámide dieron
  +32 USD». Es decir, el componente que el EA añade tiene signo positivo en esa muestra y la entrada
  base, negativo. Una muestra de 12 operaciones no permite concluir nada en ninguna dirección.
- **Duplicados:** no. Su mecánica de parciales se reutilizó en
  `Include/GoldMaster/GoldMaster_Partials.mqh`.

### `XAU_M1_SCALPER_EMA_ADX_RSI.mq5` (604 líneas) — v1

- **Nombre interno:** `XAU_M1_SCALPER_V1.mq5`, v1.00, «Scalping XAUUSD M1 - EMA/ADX/RSI/ATR».
- **Estrategia:** EMA 9/21/100 en M1, RSI(14) en banda (52–72 compras, 28–48 ventas) y ADX ≥ 20.
  SL = `max(SL_ATR × ATR, stops_level)`, TP = `max(TP_ATR × ATR, stops_level)`. Breakeven a
  `BreakEvenATR` y trailing desde `TrailStartATR`.
- **Temporalidad / símbolo:** M1. XAUUSD.
- **Inputs de riesgo:** `RiskPercent=0.50`, `MaxLot=0.10`, **`MinLotManual=0.01`**,
  `MaxSpreadPoints=80`, `SlippagePoints=30`, `SL_ATR=1.50`, `TP_ATR=2.00`,
  `MagicNumber=26061001`, `OnlyNewCandle=true`.
- **Controles de riesgo:** filtro de spread; `MaxLot` acota por arriba; **respeta
  `SYMBOL_TRADE_STOPS_LEVEL`** al calcular SL y TP (`MinimumStopDistance`, línea 239, usada en 255 y 307), que es
  más de lo que hacen la mayoría de los EAs antiguos; retcode comprobado. **No hay** modo papel,
  límite de pérdida diaria, tope de operaciones diarias ni filtro de sesión.
- **Banderas rojas:** **BR-06**. `NormalizeLot` (línea 182) hace
  `if(minLot < MinLotManual) minLot = MinLotManual;` y después `lot = MathMax(lot,minLot);`
  (línea 193). Es el suelo de lote mínimo **doblemente** agravado: no sólo fuerza el mínimo del
  broker cuando el riesgo pide menos, sino que permite subir ese suelo por input. Con
  `RiskPercent=0.50` el usuario cree arriesgar medio punto porcentual; lo que arriesgue de verdad lo
  decide el lote mínimo y la distancia del SL, sin aviso.
- **Duplicados:** primera versión de la familia; superada por v2/v3 y, en gestión, por v4/v5.

### `XAU_M1_SCALPER_V2_PRO.mq5` (608 líneas)

- **Nombre interno:** `XAU M1 Scalper v2 PRO — XAUUSD`, v2.00.
- **Estrategia:** la v1 más una **cascada de tendencia HTF de tres capas** que deben coincidir todas:
  M15 (EMA20/50 + ADX ≥ 22), H1 (EMA50/200) y M5 (EMA9/21 + MACD). Añade Bollinger(20,2) para no
  entrar en rango, Stochastic(5,3,3) para no entrar sobreextendido, filtro de vela limpia
  (cuerpo > mecha), filtro de sesión UTC, ATR máximo, divergencia mínima +DI/−DI, auto-detección de
  cuenta micro, *throttle* del trailing a una modificación por barra, pre-chequeo de margen y
  cooldown. La cabecera enumera las 12 mejoras.
- **Temporalidad / símbolo:** M1 con M5/M15/H1. XAUUSD y XAUUSDmicro (auto-detectado).
- **Inputs de riesgo:** `PaperMode=true`, `RiskPercent=0.50`, `MaxLot=1.00`,
  `MaxSpreadPoints=80`, **`MaxDailyLossPct=3.0`**, `SL_ATR=1.30`, `TP_ATR=2.20`,
  `MinATR_USD=0.60`, `MaxATR_USD=20.0`, `CooldownBars=3`, `MagicNumber=26061002`.
- **Controles de riesgo:** modo papel por defecto; **límite de pérdida diaria** (lo que le faltaba a
  la v1); auto-detección micro; pre-chequeo de margen (evita el 10019); filtros de spread, sesión,
  ATR mínimo y máximo; cooldown; respeta `stops_level`; retcode comprobado.
- **Banderas rojas:** ninguna. El problema de esta versión es el contrario: su propia cabecera de la
  v3 dice que el `AND` de 8 filtros hacía que «el EA nunca entraba / entraba tarde».
- **Duplicados:** evolución de la v1.

### `XAU_M1_SCALPER_V3_SCORE.mq5` (531 líneas)

- **Nombre interno:** `XAU M1 Scalper v3 SCORE — XAUUSD`, v3.00.
- **Estrategia:** la v2 convertida de `AND` a **puntuación**. Ocho componentes que suman hasta 8
  puntos (HTF M15 vale 2; H1, M5, stack EMA M1, RSI, ADX+DI, Stochastic y Bollinger valen 1 cada
  uno) y entra cuando el total alcanza `MinScore`. Conserva **filtros duros** que bloquean sin
  importar la puntuación: ADX de M15 por debajo del mínimo (rango), ATR fuera de
  [`MinATR_USD`, `MaxATR_USD`], spread excesivo, fuera de sesión, cooldown, pérdida diaria y
  `PaperMode`.
- **Temporalidad / símbolo:** M1 con M5/M15/H1. XAUUSD y micro.
- **Inputs de riesgo:** `PaperMode=true`, `RiskPercent=0.50`, `MaxLot=1.00`,
  `MaxSpreadPoints=80`, `MaxDailyLossPct=3.0`, **`MinScore=5`** (de 8),
  `MagicNumber=26061003`.
- **Controles de riesgo:** los de la v2, más la separación explícita entre puntuación y filtros
  duros, que es la decisión de diseño correcta: lo que protege el capital no se puede compensar con
  puntos. Pre-chequeo de margen con `OrderCalcMargin × 1.3`; respeta `stops_level`; retcode
  comprobado.
- **Banderas rojas:** ninguna. Aviso metodológico, no de código: un umbral ajustable sobre 8
  componentes es un espacio de búsqueda de 8 dimensiones; si se ajusta `MinScore` mirando resultados,
  cada valor probado es una prueba más que hay que declarar (`HALLAZGOS.md` §2).
- **Duplicados:** es la versión **vigente** de la familia en cuanto a señal.

### `XAU_M1_SCALPER_V4_FIXED.mq5` (509 líneas)

- **Nombre interno:** `David`, v4.00. Su cabecera lista cinco arreglos confirmados en el log del
  9-10-2026: filtro de sesión (operaba en horas asiáticas), *throttle* del trailing garantizado a
  1× por barra M1, paso mínimo del trailing para evitar breakeven prematuro, cooldown en segundos
  además de en barras, y breakeven con *buffer* en lugar del precio exacto de entrada.
- **Estrategia:** sesgo M15 (`m15_bias`) y después puntuación de 5 componentes (stack EMA, cruce,
  ADX, RSI en zona, vela del color correcto) exigiendo `score >= 3` **y** el stack EMA
  obligatoriamente. SL = `SL_ATR_Mult × ATR`, TP = `TP_ATR_Mult × ATR`.
- **Temporalidad / símbolo:** M1 con sesgo M15. XAUUSD / micro.
- **Inputs de riesgo:** `PaperMode=true`, **`LotNormal=0.10` / `LotMicro=0.50` (lote fijo)**,
  `TP_ATR_Mult=2.5`, `SL_ATR_Mult=1.2`, `MaxSpread_Points=80`, `DailyLoss_Pct=3.0`,
  `Cooldown_Seconds=120`, `Cooldown_Bars=2`, `MinATR_USD=0.50`, `MaxATR_USD=20.0`,
  `M15_ADX_Min=22.0`, `Trail_ATR_Mult=0.8`, `Breakeven_ATR_Mult=0.6`, `Breakeven_Buffer=3.0`.
- **Controles de riesgo:** modo papel por defecto; **una sola posición** (`if(PositionsTotal() > 0)
  return;`, línea 342); `HasEnoughMargin` antes de cada orden; pérdida diaria; filtros de spread,
  sesión, ATR y ADX de M15; cooldown doble (segundos y barras); `OnTradeTransaction` para registrar
  el cierre y arrancar el cooldown. **No comprueba el retcode** (sólo el booleano, líneas 445 y 476).
- **Banderas rojas:** ninguna marcada, pero el **lote fijo es un retroceso** respecto a v1–v3, que
  dimensionaban por riesgo: `LotNormal=0.10` y `LotMicro=0.50` no se adaptan ni al capital ni a la
  distancia del SL, así que el riesgo por operación varía con el ATR sin control. El freno efectivo
  es el tope de una posición y el límite diario del 3 %.
- **Duplicados:** comparte la señal con la v3 (simplificada) y la gestión con la v5.

### `XAU_M1_SCALPER_V5_ML.mq5` (504 líneas)

- **Nombre interno:** `David Domez — GOLD MASTER SYSTEM`, v5.00.
- **Qué es:** **la v4 más una capa ML**. Verificado por `diff`: los cambios son la cabecera, el
  `#include <GoldMaster\GoldMaster_ML_ONNX.mqh>` y el grupo de inputs del filtro ML. Todo lo demás
  (señal, gestión, arreglos FIX-1…5) es idéntico a la v4.
- **Estrategia añadida:** filtro ONNX con el modelo `xau_signal_model.onnx` (XGBoost de H1, 16
  features, según la cabecera): sólo confirma BUY si `prob_buy >= ML_Threshold` y SELL si
  `prob_buy <= 1 - ML_Threshold`.
- **Inputs de riesgo:** los de la v4, más `UseMLFilter=true`,
  `MLModelFile="xau_signal_model.onnx"` (en `MQL5/Files/`), `ML_Threshold=0.60`.
- **Controles de riesgo:** los de la v4. La cabecera añade «no activar live sin demo 48h».
- **Banderas rojas:** ninguna marcada; hereda el lote fijo de la v4.
- **Dependencia externa:** el modelo `.onnx` debe existir en `MQL5/Files/`. **No está en el
  repositorio** y no hay ningún script que lo entrene ni lo exporte (`offline/gm_ml.py` exporta un
  modelo lineal a MQL5, no un ONNX). El comportamiento sin modelo **sí está resuelto y es seguro**:
  `GM_ML_Init` falla y registra el error, y `GM_ML_Predict` devuelve `GM_ML_DISABLED_PROB = 0.5`
  (`Include/GoldMaster/GoldMaster_ML_ONNX.mqh:16`, `:242`). Con `ML_Threshold=0.60`, un 0.5 no
  confirma BUY (`>= 0.60`) ni SELL (`<= 0.40`), así que el EA **deja de operar** en vez de operar sin
  filtro. Es el fallo seguro correcto, pero significa que, sin el modelo, la v5 es la v4 apagada.
- **Duplicados:** variante ML de la v4.

---

## `Experts/GRID_PENDIENTES/`

El nombre de la carpeta induce a error: ninguno de los tres es una rejilla clásica con niveles
equiespaciados y recuperación. Los dos primeros colocan **una** pendiente por dirección con un tope
de órdenes; el tercero apila posiciones a mercado.

### `GRID_EMA5_13_PendingOrders_v1.mq5` (275 líneas)

- **Nombre interno:** `Asistente AI`, v2.10, fichero original `EA_Pendientes_Deriv.mq5`.
- **Estrategia:** tendencia por cruce EMA5/EMA13 en la vela cerrada. Si es alcista y no hay ya una
  pendiente de compra, coloca **un** Buy Stop (o Buy Limit, según `InpTipoPendiente`) a
  `InpDistanciaPend=300` puntos del Ask, con SL a 80 puntos y TP a 2000 puntos, y expiración de
  `InpExpirationMin=60` minutos. Simétrico para las ventas. Filtra por `InpMinATR`.
- **Temporalidad / símbolo:** TF del gráfico. Deriv según el nombre original; el tamaño de los
  parámetros en puntos sugiere oro.
- **Inputs de riesgo:** `InpLotSize=0.01` (**fijo**), `InpSL=80`, `InpTP=2000`,
  `InpMaxOrders=5`, `InpTrailingStart=250`, `InpTrailingStep=50`, `InpMinATR=0.50`,
  `InpMagic=999888`.
- **Controles de riesgo:** tope de 5 órdenes/posiciones por dirección; expiración de pendientes;
  filtro de ATR mínimo; `ExistePendienteSimilar` evita duplicar la misma pendiente; magic propio;
  SL y TP siempre presentes.
- **Banderas rojas:** ninguna de ruina — hay SL, lote pequeño y tope. Pero tres carencias serias:
  - **El resultado del envío se descarta por completo.** Líneas 150, 158, 170 y 178:
    `trade.BuyStop(...)`, `trade.BuyLimit(...)`, `trade.SellStop(...)`, `trade.SellLimit(...)` se
    llaman como sentencias sueltas, sin asignar ni comprobar el booleano, y sin consultar
    `ResultRetcode()`. Un rechazo del servidor (precio inválido, `stops_level`, margen) es
    silencioso: el EA cree haber colocado la orden.
  - **No valida `SYMBOL_TRADE_STOPS_LEVEL`.** Con `InpSL=80` puntos (0,80 $ en oro), muchos brokers
    rechazan el SL por estar demasiado cerca; combinado con el punto anterior, el rechazo no se ve.
  - **Sin filtro de spread, sin filtro de sesión y sin límite de pérdida diaria.**
  - Relación SL/TP de 80 a 2000 puntos: el TP está 25 veces más lejos que el SL, lo que exige una
    tasa de acierto muy baja pero también significa que casi todas las operaciones terminarán en el
    SL o por expiración del trailing; no hay nada que evalúe si esa asimetría funciona.
- **Duplicados:** ver el siguiente.

### `GRID_MINI_EMA5_13_Lote01.mq5` (275 líneas)

- **Qué es:** **duplicado de `GRID_EMA5_13_PendingOrders_v1.mq5` con una sola diferencia**.
  Verificado por `diff`: línea 20, `InpLotSize = 0.1` en vez de `0.01`. Todo lo demás es idéntico,
  **incluido `InpMagic = 999888`**.
- **Banderas rojas:** las mismas carencias del original, con riesgo diez veces mayor por ser un lote
  diez veces más grande con el mismo SL de 80 puntos.
- **Riesgo adicional por ser duplicado:** magic compartido. Si se cargan los dos,
  `ExistePendienteSimilar` y el conteo de `InpMaxOrders` mezclarán las órdenes de ambos y el tope de
  5 por dirección se aplicará mal.
- **Veredicto:** **borrar.** El lote ya es un input; no hace falta un fichero para cambiarlo.

### `TALOS_EMA5_13_ATR_Trailing_v10.mq5` (296 líneas)

- **Nombre interno:** `Asistente AI`, v10.00, fichero original `EA_Agresivo_Micro_v10.mq5`.
- **Estrategia:** cruce EMA5/EMA13. En **cada vela nueva** en que la tendencia persista, abre otra
  posición a mercado a favor, hasta `InpMaxOrders`. Con `InpUseDynamicSLTP=true`, SL = 1,5 ATR
  acotado a [300, 1500] puntos y TP = 3,0 ATR acotado a [600, 3000]. Cierra las posiciones contrarias
  al cambiar la tendencia y espera `InpReversalWaitBars` velas antes de reentrar. Trailing dinámico
  por ATR con mínimos en puntos.
- **Temporalidad / símbolo:** TF del gráfico. Avisa en `OnInit` si el símbolo no contiene "XAU".
- **Inputs de riesgo:** **`InpLotSize=0.1` (fijo)**, `InpTP=110`, `InpSL=60`,
  **`InpMaxOrders=4`**, `InpMinATR=0.30`, `InpReversalWaitBars=2`, `InpCloseOnReversal=true`,
  `InpUseDynamicSLTP=true`, `InpTrailingStartATR=1.5`, `InpTrailingStepATR=0.5`,
  `InpMagic=20250912`.
- **Controles de riesgo:** `CheckMargin` antes de cada orden (líneas 152 y 159); normalización del
  lote contra `volume_min`/`volume_max`/`volume_step` en `OnInit`; tope de 4 posiciones por
  dirección; cierre al revertir la tendencia; filtro de ATR mínimo; SL y TP siempre presentes.
- **Banderas rojas:** **BR-15**. Tres cosas que se multiplican:
  - **Lote fijo** `InpLotSize=0.1` (línea 10), sin relación con el capital ni con la distancia del
    SL. No hay `RiskPercent` en ningún sitio.
  - **Apilamiento en la misma dirección**, una posición por vela mientras el cruce persista, hasta 4
    (líneas 150 y 157: `if(newTrend == 1 && buyCount < InpMaxOrders)`), **sin stop común** que
    reduzca el riesgo del grupo al añadir y **sin tope de riesgo agregado**.
  - **Ningún límite de pérdida diaria, ningún filtro de spread y ningún control del retcode** (las
    llamadas `trade.Buy` y `trade.Sell` de las líneas 155 y 162 se emiten como sentencias sueltas).

  Aritmética del caso peor con los valores por defecto: 4 posiciones de 0.1 lotes en XAUUSD estándar
  son 40 onzas; con el SL dinámico en su tope de 1500 puntos (15 $ de precio) la pérdida conjunta
  ronda los 600 $, decidida por el EA sin consultar el capital. En XAUUSDmicro la escala es 100 veces
  menor, pero el mecanismo es el mismo y el fichero no comprueba en qué símbolo está más allá de un
  `Print` de advertencia.
- **Duplicados:** no, aunque comparte la señal EMA5/13 con los dos anteriores.
- **Veredicto:** archivar. Si se quiere apilar a favor de la tendencia, `SCALPER2_Piramide` ya lo
  hace con stop común, tope de riesgo de grupo y límite diario.

---

## `Experts/PROTECCION_SL/`

Ninguno de los dos abre posiciones: verificado, la única acción que emiten es
`TRADE_ACTION_SLTP`.

### `COPILOT_v5_GoldProtector.mq5` (795 líneas)

- **Nombre interno:** `GoldTradeProtector.mq5`, v5.00, «Optimizado para XAUUSD».
- **Estrategia:** protector de posiciones. Recorre todas las posiciones, pone SL/TP a las que no
  tienen (SL ajustado por volatilidad con ATR y acotado a
  [`InpMinSLPoints`, `InpMaxSLPoints`], TP por `InpRiskRewardRatio` o dinámico), aplica breakeven
  bloqueable (`InpLockBreakeven` impide el retroceso), trailing con paso mínimo, un SL agresivo al
  detectar reversión, un breakeven de emergencia al detectar *spike*, y bloqueo de ganancias
  (`LockProfits`) al alcanzar `InpProfitLockPercent`.
- **Temporalidad / símbolo:** indiferente; parámetros calibrados para XAUUSD.
- **Inputs de riesgo:** `InpStopLoss=300` pts, `InpTakeProfit=600` pts, `InpTrailingStop=150`,
  `InpBreakeven=80`, `InpMinSLPoints=100`, `InpMaxSLPoints=800`, `InpMaxRiskPercent=2.0`,
  `InpMaxDailyLoss=5.0`, `InpMaxDrawdown=10.0`, `InpMaxLotSize=1.0`,
  `InpUseRiskManagement=true`, `InpProfitLockPercent=50.0`.
- **Controles de riesgo:** itera por `PositionsTotal()` y filtra por `POSITION_MAGIC` (líneas 278 y
  342); límite de pérdida diaria y de drawdown; acota el SL por arriba y por abajo; paso mínimo del
  trailing.
- **Puntos a vigilar:**
  - Las seis llamadas a `OrderSend` (líneas 481, 575, 593, 647, 710, 764) comprueban el **booleano**
    de retorno y no `result.retcode`. En MQL5 el booleano indica que la petición se envió; el
    veredicto está en el retcode. Sólo la primera (línea 483) imprime `result.retcode`, y lo hace en
    la rama de fallo del booleano.
  - `CalculateOptimalLotSize` (líneas 245–263) existe, termina en el patrón
    `lotSize = MathMax(minLot, MathMin(maxLot, lotSize))` (línea 261) y **no se llama desde ningún
    sitio**: es código muerto. Por eso ese suelo de lote mínimo **no** se cuenta como bandera roja
    aquí, pero conviene borrarlo para que no se reutilice tal cual.
- **Banderas rojas:** ninguna. Es un EA que sólo puede reducir riesgo, no aumentarlo.

### `COPILOT_v4_GoldProtector.mq5` (469 líneas)

- **Qué es:** la versión anterior del mismo fichero (`GoldTradeProtector.mq5` v4.00). Verificado por
  `diff` de inputs: la v5 es un **superconjunto** — añade todo el grupo «PROTECCIÓN DE CAPITAL»
  (`InpMaxRiskPercent`, `InpMaxDailyLoss`, `InpMaxDrawdown`, `InpMaxLotSize`,
  `InpUseRiskManagement`, `InpProfitLockPercent`, `InpUseProfitLock`) y pasa de 3 a 6 puntos de
  modificación de SL/TP.
- **Banderas rojas:** ninguna, pero **le faltan los límites de pérdida diaria y de drawdown** que la
  v5 sí tiene.
- **Veredicto:** archivar. No tiene ninguna capacidad que la v5 no tenga.

---

## `Experts/CRIPTOS/`

### `eterium.mq5` (1230 líneas)

- **Nombre interno:** `ETHUSD_Hybrid_EA_V1.mq5`, v1.00, «H4 Regime → H1 BOS → M15 Pullback → ATR
  Risk Management».
- **Estrategia:** cascada de tres temporalidades. H4 define el régimen por EMA rápida/lenta; H1
  confirma un BOS en ese sentido; M15 da el gatillo en el pullback, exigiendo además volumen de la
  vela ≥ `VolumeMultiplier` × volumen medio (líneas 432 y 494). SL = `SL_ATR_Multiplier × ATR`;
  **sin TP en el servidor** (se envía `0`, líneas 574 y 586) y la salida se gestiona con trailing de
  `TrailATRMultiplier`.
- **Temporalidad / símbolo:** H4 + H1 + M15. ETHUSD (`InpSymbol` vacío = el del gráfico).
- **Inputs de riesgo:** `RiskPercent=0.75`, **`MaxDailyLossPercent=2.0`**,
  **`MaxConsecutiveLosses=3`**, **`MaxOpenPositions=1`**, `SL_ATR_Multiplier=1.50`,
  `TrailATRMultiplier=2.0`, `MaxSpreadPoints=2500`, `VolumeMultiplier=1.10`,
  `MagicNumber=260102`, `AllowLong`/`AllowShort`.
- **Controles de riesgo:** de los mejores del repositorio fuera de `GOLD_MASTER_SYSTEM`. Sizing por
  riesgo sobre el **equity**; una sola posición; límite de pérdida diaria; **contador de pérdidas
  consecutivas** que pausa el EA (poco común y muy útil); filtro de spread; filtro de volumen;
  retcode consultado; magic propio.
- **Banderas rojas:** **BR-09**. `CalculateVolume` (línea 632) termina en `volume = MathMax(volume, minLot);`
  (línea 689) sin comprobar el riesgo resultante. Está **muy atenuado** por `MaxOpenPositions=1`,
  `MaxDailyLossPercent=2.0` y `MaxConsecutiveLosses=3`, que acotan el daño agregado; pero el riesgo
  de **una** operación puede seguir superando el 0,75 % nominal sin aviso.
- **Nota aparte:** al no enviar TP al servidor, si el EA se descarga la posición queda sin objetivo
  (el SL sí está puesto y protege).
- **Duplicados:** no.

### `btcusd.mq5` (636 líneas)

- **Nombre interno:** `Deriv_BTC_ETH_v17_SMART.mq5`, v17.00, copyright «Venice AI», «BTC + ETH -
  Detección de Régimen + Confluencia Múltiple».
- **Estrategia:** detector de régimen sobre `InpRegimeBars=150` velas (eficiencia de precio contra
  `InpTrendThreshold`, volatilidad contra la media por `InpVolHighPct`/`InpVolLowPct`) que clasifica
  en tendencia alcista/bajista, rango o volátil; **no opera en régimen volátil**. Dentro del régimen
  permitido, suma una puntuación de hasta 10 con EMA 15/40/150, ADX, RSI, Stochastic y Bollinger, y
  entra si alcanza `InpMinScore=7`. Añade entradas cuando el precio avanza `InpEntryStepATR=0.6`
  ATR. SL = `max(ATR × InpSL_ATR, stops_level × 1.5 + 50 puntos)`, TP = `ATR × InpTP_ATR`.
- **Temporalidad / símbolo:** M5 (`iTime(..., PERIOD_M5, 0)` controla la vela nueva). BTCUSD y
  ETHUSD simultáneamente, con nombres configurables.
- **Inputs de riesgo:** **`InpBTC_Lot=0.01` / `InpETH_Lot=0.10` (lote fijo)**,
  **`InpMaxEntries=5`**, **`InpMaxPosPerSym=5`**, `InpEntryStepATR=0.6`, `InpSL_ATR=1.5`,
  `InpTP_ATR=5.0`, `InpMinScore=7`, `InpUseSession=true` 10–23 h, `InpMinATRPct=0.02`,
  `InpTradeOnTrend=true`, `InpTradeOnRange=false`, `InpMagic=20241115`.
- **Controles de riesgo:** tope de 5 posiciones por símbolo; filtro de sesión; filtro de ATR mínimo;
  **respeta `SYMBOL_TRADE_STOPS_LEVEL`** al calcular el SL (línea 509, con un margen de 1,5× más 50
  puntos, que es lo correcto en cripto); bloqueo del régimen volátil; retcode consultado; magic
  propio.
- **Banderas rojas:** **BR-16**. `InpMaxEntries=5` y `InpMaxPosPerSym=5` (líneas 49–50) con **lote
  fijo**, aplicados a **dos símbolos a la vez**: hasta 10 posiciones abiertas, 5 en BTC y 5 en ETH,
  todas dimensionadas sin mirar el capital. Verificado por búsqueda: en el fichero **no existe
  ninguna** referencia a pérdida diaria, drawdown, equity ni filtro de spread. En cripto, donde el
  spread se abre con la volatilidad y los huecos de fin de semana son habituales, la ausencia del
  filtro de spread y de un cortacircuitos diario convierte el apilamiento en el modo de fallo
  dominante. El SL está siempre puesto, así que la pérdida por posición está acotada; lo que no está
  acotado es el agregado.
- **Duplicados:** no.
- **Veredicto:** revisar — la detección de régimen y el tratamiento de `stops_level` son
  aprovechables; el dimensionado y la ausencia de límites diarios, no.

---

## `Experts/ESPECIALES_DERIV/`

### `EA1_Boom1000_SpikeRetrace_SELL.mq5` (428 líneas)

- **Nombre interno:** `BoomerHangLogic_Deriv.mq5`, v3.10, «EA para Boom 1000 (Deriv)»,
  `#property description "Detecta spikes alcistas en Boom 1000 y opera el retroceso post-spike"`.
- **Estrategia:** específica del índice sintético Boom 1000, que por construcción produce spikes
  alcistas. Detecta un spike cuando una vela M1 tiene cuerpo ≥ `InpSpikeCandlePercent=0.05 %` del
  precio en las últimas `InpSpikeLookback=3` velas, espera entre `InpMinBarsAfterSpike=1` y
  `InpMaxBarsAfterSpike=30` velas, y **vende** si el retroceso está entre
  `InpMinRetracePercent=0.02 %` y `InpMaxRetracePercent=0.50 %`. SL y TP en porcentaje del precio,
  con trailing también porcentual. Sólo opera a la baja.
- **Temporalidad / símbolo:** M1. Boom 1000 de Deriv. **No operar en otros símbolos**: toda la
  lógica depende de la asimetría artificial del índice.
- **Inputs de riesgo:** **`InpLotSize=0.2` (fijo; es el mínimo de Deriv para este índice)**,
  `InpSLPercent=0.30` («0 = sin SL»), `InpTPPercent=0.20` («0 = sin TP»),
  `InpMaxSpreadPoints=20000`, **`InpSkipSpreadFilter=true`**, `InpMaxTradesPerDay=3`,
  `InpDailyLossLimit=5.0`, `InpMaxConsecLosses=3`, `InpPauseMinutes=120`,
  `InpMaxMinutesInTrade=120`, `InpMagicNumber=20260424`.
- **Controles de riesgo que sí tiene, y son buenos:** tope de 3 operaciones al día; límite de
  pérdida diaria del 5 %; **pausa de 120 minutos tras 3 pérdidas consecutivas**; cierre por tiempo a
  los 120 minutos; trailing; magic propio; retcode consultado.
- **Banderas rojas:** **BR-18**, dos defectos de configuración por defecto:
  - **`InpSLPercent` admite 0 = sin stop loss** (línea 24, comentario «Stop Loss (% del precio,
    0=sin SL)»). El valor por defecto es 0.30, así que de fábrica hay stop; pero el input está
    diseñado para poder quitarlo, y en un índice cuya razón de existir es generar spikes de cientos
    de puntos en un tick, una posición corta sin stop tiene pérdida potencial no acotada. Un stop
    opcional es un stop que algún día estará en 0.
  - **El filtro de spread viene desactivado:** `InpSkipSpreadFilter = true` (línea 42), con el
    comentario «\*\*\* CLAVE: Ignorar filtro de spread (para backtest) \*\*\*». Es un ajuste de
    backtest que quedó como valor por defecto. En un sintético de Deriv el spread se ensancha
    precisamente en el spike, que es el momento en que este EA opera, y `InpMaxSpreadPoints=20000`
    sugiere que el spread normal ya es enorme. Hay que ponerlo en `false` antes de cualquier uso en
    vivo.
- **Duplicados:** no. Su detector de *spike retrace* se reutilizó en
  `GOLD_MASTER_GLOBAL_EA.mq5`, adaptado a XAUUSD.

---

## `Experts/INDICADORES_SMC/` — indicadores guardados en la carpeta de EAs

No son EAs: ambos declaran `#property indicator_chart_window` y no tienen `OnTick` ni envían
órdenes. Riesgo de ruina nulo.

### `SMC_BOS_CHoCH_Indicator_v4.mq5` (210 líneas)

- **Nombre interno:** `Hugo`, v1.00. 4 buffers, 4 plots.
- **Qué hace:** detecta swings con fractales de ventana `FractalRange=3` y marca BOS (continuación) y
  CHoCH (cambio de carácter) con colores distintos: BOS alcista azul, BOS bajista rojo-naranja,
  CHoCH alcista verde, CHoCH bajista magenta. Opcionalmente dibuja la línea del nivel roto.
- **Declaración relevante:** «Sin repintado: confirma swings solo con velas cerradas y marca la
  ruptura en el cierre de la vela que rompe».
- **Inputs:** `FractalRange=3`, `ShowLabels=true`, `ShowLevelLine=true`.
- **Veredicto:** mantener. Debería estar en `Indicators/`, no en `Experts/`.

### `SMC_SLTP_Indicator_BOS_Zones.mq5` (238 líneas)

- **Nombre interno:** `Hugo`, v1.00. Sin buffers ni plots: dibuja con objetos.
- **Qué hace:** cada vez que detecta un BOS/CHoCH dibuja las líneas de entrada, SL, TP1 y TP2 con la
  misma lógica de swings y zonas que `SMC_GOLD/PRUEBAS_SMC_BOS_CHoCH_2TP.mq5`, para seguimiento
  manual sin que ningún EA opere. Opcionalmente pinta las cajas de discount/premium.
- **Inputs:** `FractalRange=3`, `ZoneLookback=96` (24 h en M15), `MajorSwingLookback=200`,
  colores y `ShowZones=true`.
- **Veredicto:** mantener. Es la versión "sólo mirar" del EA de pruebas; útil precisamente por eso.
  Debería estar en `Indicators/`.

---

## `Indicators/GOLD_MASTER_SYSTEM/`

Ninguno envía órdenes. Riesgo de ruina nulo. Se catalogan por completitud y porque uno de ellos
consume un fichero del puente.

| Fichero | Líneas | Qué hace | Nota |
|---|---|---|---|
| `GOLD_MASTER_PRO_Signals.mq5` | 1312 | Señales M1/M5/M15 con entrada, SL y TP1/TP2/TP3; estructura sin repintado; confluencia M1·M5·M15·H1·H4 con grado A+/A/B; caja de operación en el gráfico; lote sugerido; y tasa de acierto de TP1/TP2/TP3 **medida sobre el historial del gráfico** | Con `UseAutoParams=true` relee cada 300 s `GoldMaster\signal_params.txt`. **Ese fichero no lo escribe nada en el repositorio** (`ARQUITECTURA.md` §7.13); sin él usa `fast=21, slow=89, minscore=3, tp=2, slatr=1.2` e informa `"manual"`. El `LoadAutoParams` sólo aplica los cambios si la clave `updated` vale literalmente `True` |
| `GOLD_MASTER_Indicador_v4.mq5` | 351 | Estructura "menos es más": swings HH/HL/LH/LL etiquetados, BOS/CHoCH con línea del swing a la ruptura, los N OB y FVG sin mitigar más cercanos, EQH/EQL, niveles multi-toque, premium/equilibrio/discount y panel con tendencia H1/LTF, DXY y señal | Dibuja flechas cuando el evento LTF va a favor del HTF y el DXY no está en contra |
| `GOLD_MASTER_Institutional.mq5` | 106 | VWAP diario con bandas ±1σ/±2σ ponderadas por volumen, PDH/PDL/PDC, apertura semanal, rango asiático (00–07 servidor) y squeeze de Bollinger(20,2) dentro de Keltner(20,1.5) | Declara «Sin repintado: todo se calcula con velas cerradas del pasado» |
| `GOLD_MASTER_MACRO_LIQUIDITY.mq5` | 12 | Envoltorio de `GoldMaster_MacroLiquidity.mqh`: dibuja el canal de regresión de la vela H3 cerrada | Su propio `Comment` califica los niveles de «candidatos, no libro de órdenes». Si falta histórico H3 de una semana, lo dice y no dibuja |

---

## `Scripts/DATOS/` y `Scripts/GOLD_MASTER_SYSTEM/`

Scripts, no EAs. Ninguno envía órdenes; los cuatro de `DATOS/` son de sólo lectura sobre el mercado.
Sus contratos de salida están en `ARQUITECTURA.md` §6.3 y §7.11.

| Fichero | Líneas | Qué hace | Salvaguardas declaradas |
|---|---|---|---|
| `Scripts/DATOS/GM_ExportarHistorico.mq5` | 6331 B | Exporta todo el histórico de un símbolo a `Files/GoldMaster/<SÍMBOLO>_<TF>.csv` en el formato que `python/core/gm_data.py` lee sin configuración. Pide la historia al terminal antes de exportar (la descarga es perezosa) | «SOLO LECTURA sobre el mercado: unicamente escribe un fichero». Su cabecera insiste en usar **el símbolo que se va a operar**, no un proxy, porque el spread, el horario y los huecos del broker forman parte del resultado |
| `Scripts/DATOS/GM_InventarioSimbolos.mq5` | 8425 B | Inventario real del broker: qué símbolos ofrece y cuánta historia hay de cada uno, en 20 columnas | «SOLO LECTURA: no crea simbolos, no modifica nada, no opera». Advierte que el "USD Basket" de Deriv es equiponderado y **no** es el DXY de ICE |
| `Scripts/DATOS/ImportarTicksDuka.mq5` | 8339 B | Importa ticks de Dukascopy en CSV a un símbolo personalizado | Cuatro restricciones **verificadas en el código**: sólo crea símbolos con sufijo `_DUKA` (comprobado con `StringFind` antes de empezar), sólo lee de `MQL5/Files`, no toca símbolos reales del broker, no opera ni cambia la configuración del terminal |
| `Scripts/DATOS/VerificarTicksDuka.mq5` | 3519 B | Verifica que el símbolo `*_DUKA` tiene ticks y los resume en el Diario | Sólo lee y escribe en el log |
| `Scripts/GOLD_MASTER_SYSTEM/GM_Deploy.mq5` | 5975 B | Monta el entorno: resuelve el símbolo del gráfico, abre gráficos con plantillas sin duplicar los existentes y opcionalmente lanza el stack Python | **Importa `shell32.dll`**, así que hay que marcar "Permitir importar DLL" al ejecutarlo. `MacroExclusive=true` por defecto evita añadir un segundo motor de entradas; `DeployScalper=false` está desactivado y etiquetado «2º motor de entradas (más riesgo)» |

---

## Tabla resumen

Riesgo de ruina del **mecanismo**, no predicción de resultados. Veredictos: *mantener* = apto para
seguir usándose con los controles que tiene; *revisar* = hay algo concreto que corregir antes de
usarlo con dinero real; *archivar* = superado por otro fichero, o su diseño de riesgo habría que
reescribirlo.

| Fichero | Carpeta | Estrategia en pocas palabras | Riesgo de ruina | Veredicto |
|---|---|---|---|---|
| `GOLD_MASTER_MACRO_LIQUIDITY_EA.mq5` | GOLD_MASTER_SYSTEM | Canal H3 → barrido M15 → confirmación H1, con veto DXY | bajo | mantener |
| `GOLD_MASTER_GUARDIAN_EA.mq5` | GOLD_MASTER_SYSTEM | Protector: pone SL/TP, BE, trailing y límites de cuenta; no abre | bajo | mantener |
| `GOLD_MASTER_ORB_EA.mq5` | GOLD_MASTER_SYSTEM | Ruptura del rango de Londres con pendientes y OCO | bajo | mantener |
| `GOLD_MASTER_STRUCTURE_EA.mq5` | GOLD_MASTER_SYSTEM | Estructura H1 + micro M5 + niveles H4, entrada por stop | bajo | mantener |
| `GOLD_MASTER_SCALPER_EA.mq5` | GOLD_MASTER_SYSTEM | BOS + RSI(7) + EMA + DXY + intel, entrada por stop | bajo | mantener |
| `GOLD_ADAPTIVE_EA.mq5` | GOLD_MASTER_SYSTEM | Ejecuta reglas validadas de `rules_db.json` (cruce EMA M15/H1) | bajo | mantener |
| `GOLD_MASTER_EA_v3.mq5` | GOLD_MASTER_SYSTEM | Score de confluencia SMC + ML + puente, 0-17 | bajo | revisar (sobreajuste, no ruina) |
| `GOLD_MASTER_PULLBACK_EA.mq5` | GOLD_MASTER_SYSTEM | Pullback RSI(30/70) en tendencia M15/H4 | medio (**BR-17**) | revisar (quitar el modo "sin filtros") |
| `AUDIT_20261007/GOLD_MASTER_PULLBACK_EA.mq5` | GOLD_MASTER_SYSTEM | Instantánea previa del anterior | medio | archivar |
| `AUDIT_20261007/GOLD_MASTER_SCALPER_EA.mq5` | GOLD_MASTER_SYSTEM | Instantánea previa del scalper | bajo | archivar |
| `GOLD_MASTER_GLOBAL_EA.mq5` | GOLD_MASTER_GLOBAL | `EA_v3` + DXY + parciales + sesiones + spike retrace | bajo | revisar (`gm_state.json` no existe: filtro DXY inerte) |
| `GOLD_MASTER_SCALPER_V3_VOLATILE.mq5` | GOLD_MASTER_SCALPER_V3 | Scalper con dos juegos de parámetros según ATR | bajo | revisar (**D-01**: argumentos de `Sell` invertidos) |
| `TALOS_Bridge_JSON_MT5_Python.mq5` | BRIDGE_PYTHON | Ejecuta órdenes dictadas por un JSON externo | **alto** (**BR-01**, **BR-02**) | archivar (o reescribir las dos salvaguardas) |
| `ORO_MASTER_v1.mq5` | BOTS_ORO | BOS/CHoCH + order block + FVG + retest con RSI | bajo | mantener |
| `ORO_MASTER_v1_LoteMin.mq5` | BOTS_ORO | El anterior, siempre con lote mínimo | medio (**BR-10**) | revisar (sólo demo) |
| `ORO_MASTER_v1_SiempreOpera.mq5` | BOTS_ORO | El anterior, sin comprobar margen | **alto** (**BR-11**) | archivar |
| `GOLD_MASTER_EA.mq5` | BOTS_ORO | Stack EMA 5/13/50/200 + DXY + parciales | medio (**BR-08**) | archivar (superado por `GOLD_MASTER_SCALPER_EA`) |
| `ORO2.mq5` | BOTS_ORO | Cierre al otro lado de la EMA20 con EMA50 a favor | medio | archivar |
| `ELIOT1_SMC_v5_FVG_Liquidez_3TP.mq5` | SMC_GOLD | SMC con BOS/CHoCH, liquidez, FVG y 3 objetivos | medio | revisar (es la rama viva de la familia ORO) |
| `ORO3_SMC_v4_EMA200_Parciales.mq5` | SMC_GOLD | Linaje ORO + EMA200 de sesgo + parciales escalonados | medio | archivar (superado por `ELIOT1`) |
| `ORO4_SMC_v3_Compacto.mq5` | SMC_GOLD | Linaje ORO con hasta 5 entradas por señal | **alto** (**BR-13**) | archivar |
| `SCALPER_SMC_EMA_ATR_5pos.mq5` | SMC_GOLD | Linaje ORO en scalping con 5 posiciones al 2 % | **alto** (**BR-14**) | archivar |
| `EXPER_ORO2_SMC_COMPLETO_RSI_FVG.mq5` | SMC_GOLD | Casi idéntico a `ORO_MASTER_v1_LoteMin` (2 líneas) y mismo magic | medio (**BR-12**) | archivar (el magic compartido es el problema) |
| `PRUEBAS_SMC_BOS_CHoCH_2TP.mq5` | SMC_GOLD | BOS/CHoCH con TP1/TP2 gestionados en código | medio (**BR-07**) | revisar (sólo demo) |
| `Bot_Liquidez_UltraRapido_4H_15M.mq5` | SMC_GOLD | Gatillo de liquidez 4H/15M con EMA+ADX, 2 ops/día | bajo | mantener |
| `VARIOS2_MultiSMC_v3.70_DXY_Filter.mq5` | SMC_MULTI_ACTIVO | SMC multi-activo H1/M15 con order blocks y filtro DXY | bajo | mantener |
| `HUGO_MultiSMC_v3.20_XAU_OB.mq5` | SMC_MULTI_ACTIVO | La v3.20 del anterior, sin GBPUSD ni DXY | bajo | archivar (duplicado de `VARIOS1` salvo un input) |
| `VARIOS1_MultiSMC_v3.20_XAU_XAG.mq5` | SMC_MULTI_ACTIVO | Idéntico a `HUGO` salvo `UseXAGUSD` | bajo | archivar (conservar uno de los dos) |
| `HUGOx_StructuralBreakout_Zones.mq5` | SMC_MULTI_ACTIVO | Ruptura de consolidación sin indicadores | **alto** (**BR-03**, **BR-04**) | archivar |
| `SCALPER2_Piramide_EMA_ADX_H4filter.mq5` | SCALPER_M1_M5 | Pirámide a favor con **stop común** y tope de riesgo de grupo | bajo | mantener |
| `XAU_M1_SCALPER_V3_SCORE.mq5` | SCALPER_M1_M5 | Scalper M1 por puntuación 5/8 con filtros duros | bajo | mantener |
| `XAU_M1_SCALPER_V2_PRO.mq5` | SCALPER_M1_M5 | Scalper M1 con cascada HTF de 3 capas en `AND` | bajo | archivar (apenas entra; superado por la v3) |
| `XAU_M1_SCALPER_V5_ML.mq5` | SCALPER_M1_M5 | La v4 más filtro ONNX | medio (lote fijo) | revisar (el modelo `.onnx` no está en el repositorio) |
| `XAU_M1_SCALPER_V4_FIXED.mq5` | SCALPER_M1_M5 | Scalper M1 con 5 arreglos de gestión y lote fijo | medio (lote fijo) | revisar (volver a dimensionar por riesgo) |
| `XAU_M1_SCALPER_EMA_ADX_RSI.mq5` | SCALPER_M1_M5 | Scalper M1 EMA 9/21/100 + ADX + RSI | **alto** (**BR-06**) | archivar |
| `GRIDOP_ScalperPro_BOS_RSI7_Sesiones.mq5` | SCALPER_M1_M5 | BOS + RSI(7) + EMA + sesiones (predecesor del scalper del sistema) | **alto** (**BR-05**) | archivar (magic compartido con el vigente) |
| `GRID_EMA5_13_PendingOrders_v1.mq5` | GRID_PENDIENTES | Una pendiente por dirección en cruce EMA5/13, máx. 5 | medio | revisar (resultado del envío descartado) |
| `GRID_MINI_EMA5_13_Lote01.mq5` | GRID_PENDIENTES | **Duplicado** del anterior con lote 0.1 | medio | archivar (borrar: magic duplicado) |
| `TALOS_EMA5_13_ATR_Trailing_v10.mq5` | GRID_PENDIENTES | Apila hasta 4 posiciones por vela con lote fijo | **alto** (**BR-15**) | archivar |
| `COPILOT_v5_GoldProtector.mq5` | PROTECCION_SL | Protector de posiciones con límites de cuenta; no abre | bajo | mantener |
| `COPILOT_v4_GoldProtector.mq5` | PROTECCION_SL | La v5 sin los límites de pérdida diaria ni drawdown | bajo | archivar |
| `eterium.mq5` | CRIPTOS | H4 régimen → H1 BOS → M15 pullback, 1 posición | bajo (**BR-09** atenuado) | mantener |
| `btcusd.mq5` | CRIPTOS | Régimen + puntuación 7/10 en BTC y ETH, 5 entradas cada uno | **alto** (**BR-16**) | revisar (añadir límite diario y filtro de spread) |
| `EA1_Boom1000_SpikeRetrace_SELL.mq5` | ESPECIALES_DERIV | Spike alcista → espera → retroceso → venta en Boom 1000 | medio (**BR-18**) | revisar (activar el filtro de spread; SL no opcional) |
| `SMC_BOS_CHoCH_Indicator_v4.mq5` | INDICADORES_SMC | Indicador: marca BOS y CHoCH sin repintado | nulo (no opera) | mantener (mover a `Indicators/`) |
| `SMC_SLTP_Indicator_BOS_Zones.mq5` | INDICADORES_SMC | Indicador: dibuja entrada/SL/TP1/TP2 y zonas | nulo (no opera) | mantener (mover a `Indicators/`) |
| `GOLD_MASTER_PRO_Signals.mq5` | Indicators/GOLD_MASTER_SYSTEM | Indicador de señales M1/M5/M15 con grado y estadística | nulo (no opera) | mantener |
| `GOLD_MASTER_Indicador_v4.mq5` | Indicators/GOLD_MASTER_SYSTEM | Indicador de estructura + DXY + panel | nulo (no opera) | mantener |
| `GOLD_MASTER_Institutional.mq5` | Indicators/GOLD_MASTER_SYSTEM | Indicador: VWAP±σ, PDH/PDL/PDC, rango asiático, squeeze | nulo (no opera) | mantener |
| `GOLD_MASTER_MACRO_LIQUIDITY.mq5` | Indicators/GOLD_MASTER_SYSTEM | Indicador: canal H3 de liquidez macro | nulo (no opera) | mantener |
| `GM_ExportarHistorico.mq5` | Scripts/DATOS | Exporta histórico a CSV para el laboratorio Python | nulo (no opera) | mantener |
| `GM_InventarioSimbolos.mq5` | Scripts/DATOS | Inventario de símbolos del broker con profundidad | nulo (no opera) | mantener |
| `ImportarTicksDuka.mq5` | Scripts/DATOS | Importa ticks de Dukascopy a un símbolo `*_DUKA` | nulo (no opera) | mantener |
| `VerificarTicksDuka.mq5` | Scripts/DATOS | Verifica el símbolo `*_DUKA` importado | nulo (no opera) | mantener |
| `GM_Deploy.mq5` | Scripts/GOLD_MASTER_SYSTEM | Monta gráficos y plantillas y lanza el stack Python | nulo (no opera) | mantener |

### Recuento

| | Ficheros |
|---|---|
| Total `.mq5` propios catalogados | **55** |
| EAs que pueden abrir posiciones | 41 |
| EAs que sólo gestionan o protegen (no abren) | 3 (`GOLD_MASTER_GUARDIAN_EA`, `COPILOT_v4`, `COPILOT_v5`) |
| Indicadores | 6 (4 en `Indicators/`, 2 en `Experts/INDICADORES_SMC/`) |
| Scripts | 5 (4 de datos + `GM_Deploy`) |
| Con bandera roja de riesgo de ruina | 17 ficheros, 18 banderas |
| Riesgo de ruina **alto** | 9 |
| Riesgo de ruina **medio** | 14 |
| Riesgo de ruina **bajo** | 21 |
| Sin riesgo (no operan: indicadores y scripts) | 11 |
| Duplicados exactos o casi exactos detectados | 4 pares/grupos |

### Duplicados a resolver

| Conservar | Borrar o archivar | Motivo |
|---|---|---|
| `BOTS_ORO/ORO_MASTER_v1_LoteMin.mq5` | `SMC_GOLD/EXPER_ORO2_SMC_COMPLETO_RSI_FVG.mq5` | 2 líneas de diferencia y el **mismo magic** `20260905` |
| `GRID_PENDIENTES/GRID_EMA5_13_PendingOrders_v1.mq5` | `GRID_PENDIENTES/GRID_MINI_EMA5_13_Lote01.mq5` | Sólo cambia `InpLotSize` (0.01 → 0.1), que ya es un input; mismo magic `999888` |
| `SMC_MULTI_ACTIVO/VARIOS2_MultiSMC_v3.70_DXY_Filter.mq5` | `HUGO_MultiSMC_v3.20_XAU_OB.mq5` y `VARIOS1_MultiSMC_v3.20_XAU_XAG.mq5` | Los dos de la v3.20 sólo difieren en `UseXAGUSD` y comparten magic `20260917`; la v3.70 es su superconjunto |
| `GOLD_MASTER_SYSTEM/GOLD_MASTER_SCALPER_EA.mq5` | `SCALPER_M1_M5/GRIDOP_ScalperPro_BOS_RSI7_Sesiones.mq5` y los dos de `AUDIT_20261007/` | El vigente declara ser una evolución del `GRIDOP` y comparte con él `MagicNumber=202600` |

**Por qué el magic compartido importa:** dos EAs con el mismo número mágico se atribuyen mutuamente
las posiciones. Los topes (`MaxPositions`, `MaxTradesPerDay`), la gestión de parciales, el breakeven
y el trailing operan sobre posiciones que el EA no abrió. Es un modo de fallo que no produce ningún
error en el log.

---

## Patrones transversales

Lo que aparece repetido en varios ficheros, por si se quiere arreglar de una vez.

1. **El suelo de lote mínimo sin tope de riesgo** (BR-05 a BR-12) es, con diferencia, el defecto más
   extendido: 8 ficheros. El patrón es siempre
   `lot = MathMax(lot_calculado, SymbolInfoDouble(_, SYMBOL_VOLUME_MIN))`. La corrección ya existe y
   está probada: `GM_CalcLot()` en `Include/GoldMaster/GoldMaster_Core.mqh:549`, que en ese caso
   **devuelve 0 y el EA no opera**, con un log que dice cuánto arriesgaría. Sustituir la función de
   lotaje por una llamada a `GM_CalcLot` resuelve BR-05, BR-06, BR-07, BR-08, BR-09, BR-10 y BR-12 de
   una vez. El fundamento está en [`DOCTRINA_RIESGO.md`](DOCTRINA_RIESGO.md).
2. **Apilamiento sin tope de riesgo agregado** (BR-03, BR-13, BR-14, BR-15, BR-16): varias posiciones
   simultáneas en el mismo símbolo y la misma dirección, cada una al riesgo completo. La solución ya
   implementada en el repositorio es la de `SCALPER2_Piramide`: **stop común** que sube al añadir,
   más un `InpRiesgoMaxTotalPct` explícito. `GOLD_MASTER_MACRO_LIQUIDITY_EA` usa la variante más
   fuerte: `GM_AccountStopRisk` mide el riesgo al SL de **toda la cuenta** y lo compara con un
   presupuesto.
3. **El resultado del envío sin comprobar.** **14 de los 41 EAs que abren posiciones** se quedan en
   el booleano de `CTrade` o lo descartan por completo: `GOLD_MASTER_EA` (BOTS_ORO), `ORO2`,
   `TALOS_Bridge`, los tres de `GRID_PENDIENTES`, `GRIDOP`, `XAU_M1_SCALPER_V4` y `V5`, `ELIOT1`,
   `ORO4`, `HUGO`, `VARIOS1` y `VARIOS2`. El booleano no es el veredicto del servidor: el veredicto
   es `trade.ResultRetcode()` comparado con `TRADE_RETCODE_DONE`. Los casos peores son
   `GRID_EMA5_13`, `GRID_MINI` y `TALOS_EMA5_13_v10`, que no asignan ni el booleano.
   Para evitar un reproche injusto: `GOLD_MASTER_ORB_EA`, `GOLD_MASTER_STRUCTURE_EA`,
   `GOLD_MASTER_EA_v3` y `GOLD_MASTER_GLOBAL_EA` no lo comprueban en su propio fichero porque
   **delegan el envío** en `GoldMaster_PendingOrders.mqh`, que sí lo hace
   (`res.retcode == TRADE_RETCODE_DONE || TRADE_RETCODE_PLACED`, líneas 38, 243 y 396), igual que
   `GoldMaster_Partials.mqh` (líneas 80 y 101). `GoldMaster_PositionManager.mqh`, en cambio, **no**
   comprueba ningún retcode.
4. **`SYMBOL_TRADE_STOPS_LEVEL` ignorado.** Sólo `GOLD_MASTER_MACRO_LIQUIDITY_EA`,
   `XAU_M1_SCALPER_EMA_ADX_RSI`, `btcusd`, `SCALPER2_Piramide`, `GOLD_MASTER_EA_v3` y
   `GOLD_MASTER_GLOBAL_EA` lo comprueban. Un SL por debajo de ese mínimo se rechaza, y si además el
   retcode no se mira (punto 3), el EA se queda operando sin stop creyendo tenerlo.
5. **Falta de límite de pérdida diaria.** Ausente en todo el linaje `ORO2`/`ORO4`/`ORO3`/`ELIOT1`/
   `SCALPER_SMC_5pos`, en los tres de `GRID_PENDIENTES`, en `GRIDOP` y en `btcusd`. Es el
   cortacircuitos que convierte una racha mala en una pérdida acotada; sin él, el tope de operaciones
   diarias limita el número de intentos pero no el dinero.
6. **Lote fijo en lugar de dimensionado por riesgo:** `HUGOx`, `btcusd`, `Bot_Liquidez`,
   `TALOS_EMA5_13_v10`, los dos `GRID_*`, `EA1_Boom1000` y las versiones 4 y 5 de
   `XAU_M1_SCALPER` (que retrocedieron respecto a 1-3). Con lote fijo, el riesgo por operación
   depende del ATR del momento, no de una decisión.
7. **Contratos del puente sin productor.** Tres componentes leen ficheros que nada escribe:
   `GOLD_MASTER_GLOBAL_EA` (`gm_state.json`), `GOLD_MASTER_PRO_Signals` (`signal_params.txt`) y
   `TALOS_Bridge` (`talos_signal.json`). Los dos primeros degradan en silencio a "sin filtro" o "sin
   parámetros nuevos"; el tercero es BR-02. Detalle en [`ARQUITECTURA.md`](ARQUITECTURA.md) §7.13.

## Lo que este catálogo no dice

No dice que ningún EA gane dinero, ni que los marcados «mantener» sean rentables. Decir que un EA
está bien construido significa exactamente esto: que respeta el resultado del broker, que pone el
stop donde dice que lo pone, que no deja crecer la exposición sin límite y que se niega a operar
cuando el tamaño no cabe. Si además tiene ventaja es una pregunta distinta, y la respuesta medida
hasta ahora, para las estrategias mecánicas probadas en este repositorio, está en
[`HALLAZGOS.md`](HALLAZGOS.md): no se distingue de la suerte una vez corregido por el número de
pruebas realizadas.
