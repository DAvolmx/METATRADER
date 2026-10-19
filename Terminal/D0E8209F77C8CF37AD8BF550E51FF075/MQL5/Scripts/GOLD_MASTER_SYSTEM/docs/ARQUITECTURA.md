# GOLD_MASTER_SYSTEM — Arquitectura

Documento de orientación. Describe lo que el código **hace**, leído del código fuente, no lo
que se pretendía que hiciera. Cuando un dato no se puede determinar leyendo el repositorio, se
escribe explícitamente *sin determinar*.

Convenciones de ruta usadas en todo el documento:

- `<BASE>` = `Terminal/D0E8209F77C8CF37AD8BF550E51FF075/MQL5` (carpeta de datos de MetaTrader 5)
- `<RAÍZ>` = `<BASE>/Scripts/GOLD_MASTER_SYSTEM`
- `<COMMON>` = carpeta común del terminal: en Windows
  `%APPDATA%\MetaQuotes\Terminal\Common\Files\GoldMaster\`. Es el sandbox compartido por el que
  MT5 y Python se intercambian ficheros (ver "Contrato de ficheros del puente").

## Documentos hermanos

Este documento describe **dónde está cada cosa y cómo se habla entre sí**. No repite lo que ya
está escrito en los demás; cuando el tema aparece, se enlaza:

| Documento | Qué cubre |
|---|---|
| [`../README.md`](../README.md) | Qué es el sistema, arranque rápido y las reglas de la casa |
| [`HALLAZGOS.md`](HALLAZGOS.md) | Qué dice la evidencia medida: ausencia de ventaja direccional, order blocks frente al contraste de White, test nulo sintético, efecto del dólar, COT, sentimiento |
| [`ECUACION_ORO.md`](ECUACION_ORO.md) | La SDE de 4 capas, sus defectos corregidos y su validación |
| [`DOCTRINA_RIESGO.md`](DOCTRINA_RIESGO.md) | Escalera de capital, el suelo de lote mínimo, los bloqueos del guardián, dimensionado y ruina medida |
| [`CATALOGO_EAS.md`](CATALOGO_EAS.md) | Ficha por EA: estrategia, inputs de riesgo, controles presentes y banderas rojas con `fichero:línea` |

---

## 1. Árbol de directorios comentado

```
<BASE>/
├── Include/GoldMaster/              Librerías .mqh compartidas por EAs e indicadores
│   ├── GoldMaster_Core.mqh          Núcleo: sizing de lote, noticias, spread, régimen, sesgo multi-TF
│   ├── GoldMaster_Bridge.mqh        Lado MQL5 del puente: intel.txt, commands.csv, ea_state.txt
│   ├── GoldMaster_Guardian.mqh      Gobernador de riesgo dentro del EA (escalera de capital)
│   ├── GoldMaster_ML.mqh            Puente CSV de predicciones ML (ml_predictions / ml_features)
│   ├── GoldMaster_ML_ONNX.mqh       Inferencia ONNX nativa de MT5 (modelo XGBoost exportado)
│   ├── GoldMaster_SMC.mqh           Motor SMC: swings, BOS/CHoCH, OB, FVG, liquidez, premium/discount
│   ├── GoldMaster_Structure.mqh     Estructura sin repintado (swings, BOS, CHoCH, niveles, OB, FVG)
│   ├── GoldMaster_DXY.mqh           DXY directo o sintético ICE con los pares del broker
│   ├── GoldMaster_DXY_Filter.mqh    Lector de gm_state.json → dxy_bias / real_yield (ver §7)
│   ├── GoldMaster_MacroLiquidity.mqh Canal de regresión sobre la vela H3 cerrada
│   ├── GoldMaster_MacroRisk.mqh     Riesgo agregado al SL de TODAS las posiciones y pendientes
│   ├── GoldMaster_PendingOrders.mqh Órdenes pendientes (incl. colocación ORB con OCO)
│   ├── GoldMaster_PositionManager.mqh Breakeven, trailing, parciales, conteo de posiciones
│   ├── GoldMaster_Partials.mqh      Cierres escalonados 1R / 2R / runner
│   ├── GoldMaster_Sessions.mqh      Sesiones Asia/Londres/Overlap/NY + rango asiático
│   ├── GoldMaster_Assets.mqh        Perfiles por activo (oro, índices, cripto, forex)
│   ├── GoldMaster_Panel.mqh         Panel en gráfico + estadística de sesión
│   └── GoldMaster_Logger.mqh        Log con niveles a fichero
│
├── Experts/                         Expert Advisors (catálogo detallado en CATALOGO_EAS.md)
│   ├── GOLD_MASTER_SYSTEM/          EAs del sistema actual (+ AUDIT_20261007/ = instantánea previa)
│   ├── GOLD_MASTER_GLOBAL/          Intento de EA unificado
│   ├── GOLD_MASTER_SCALPER_V3/      Scalper con modo "volátil"
│   ├── BOTS_ORO/                    Familia ORO_MASTER y sus variantes
│   ├── SMC_GOLD/                    Familia SMC sobre oro (v3 → v4 → v5)
│   ├── SMC_MULTI_ACTIVO/            Familia MultiAssetSMC (HUGO / VARIOS)
│   ├── SCALPER_M1_M5/               Scalpers M1/M5 (XAU_M1_SCALPER v1…v5, pirámide)
│   ├── GRID_PENDIENTES/             Órdenes pendientes EMA5/13 y variante agresiva
│   ├── PROTECCION_SL/               COPILOT: sólo gestiona SL/TP, no abre operaciones
│   ├── INDICADORES_SMC/             Dos indicadores guardados dentro de Experts/
│   ├── CRIPTOS/                     BTC/ETH
│   ├── ESPECIALES_DERIV/            Boom 1000 (índice sintético)
│   ├── BRIDGE_PYTHON/               TALOS_Bridge: ejecuta órdenes desde ficheros JSON
│   ├── Examples/  Advisors/         Ejemplos de fábrica de MetaQuotes (fuera de alcance)
│
├── Indicators/GOLD_MASTER_SYSTEM/   Indicadores propios
│   ├── GOLD_MASTER_PRO_Signals.mq5  Señales M1/M5/M15 con SL/TP y lote sugerido (1312 líneas)
│   ├── GOLD_MASTER_Indicador_v4.mq5 Estructura limpia + DXY + panel
│   ├── GOLD_MASTER_Institutional.mq5 VWAP±σ, PDH/PDL/PDC, apertura semanal, squeeze
│   └── GOLD_MASTER_MACRO_LIQUIDITY.mq5 Dibuja el canal H3 de GoldMaster_MacroLiquidity.mqh
│
├── Scripts/DATOS/                   Scripts de datos (sólo lectura de mercado)
│   ├── GM_ExportarHistorico.mq5     Exporta histórico a CSV para el laboratorio Python
│   ├── GM_InventarioSimbolos.mq5    Inventario real de símbolos del broker + profundidad
│   ├── ImportarTicksDuka.mq5        Importa ticks de Dukascopy a un símbolo *_DUKA
│   └── VerificarTicksDuka.mq5       Verifica el símbolo *_DUKA importado
│
└── Scripts/GOLD_MASTER_SYSTEM/      = <RAÍZ>
    ├── GM_Deploy.mq5                Monta gráficos/plantillas/EAs y lanza el stack Python
    ├── INICIAR.bat                  Abre MT5 (si hace falta) y llama a GM_START_ALL.bat
    ├── GM_START_ALL.bat             Llama a INICIAR_OBSERVATORIO.ps1 -OpenBrowser
    ├── GM_START_SERVICE.bat         Arranca sólo python/gm_service.py (GM_SYMBOL=XAUUSDmicro)
    ├── GM_STOP_ALL.bat              Arranca python/gm_stop.py
    ├── INICIAR_OBSERVATORIO.ps1     Verifica carpeta MT5, exporta reglas, arranca observador + web
    ├── README.md                     Puerta de entrada: qué hace, arranque rápido, reglas de la casa
    ├── collaboration/               Scripts PowerShell de trabajo asistido (COLABORAR*.ps1)
    ├── assets/TradingView_Dark.tpl   Plantilla de gráfico
    ├── data/                        Vacía en el repositorio
    ├── docs/
    │   ├── ARQUITECTURA.md           Este documento
    │   ├── CATALOGO_EAS.md           Ficha de riesgo por EA
    │   ├── HALLAZGOS.md              Evidencia medida (empezar por aquí)
    │   ├── ECUACION_ORO.md           La SDE de 4 capas y su validación
    │   └── DOCTRINA_RIESGO.md        Escalera de capital y suelo de lote mínimo
    │
    ├── python/                      Capa analítica y de servicios (ver §3)
    │   ├── *.py                     ~30 scripts de nivel superior (servicios, dashboards, CLI)
    │   ├── core/gm_data.py          Carga unificada de datos de mercado
    │   ├── model/                   Ecuación maestra del oro (SDE) + calibración + estudio DXY
    │   ├── smc/                     Order blocks: detector exhaustivo, estrategias, Monte Carlo
    │   ├── agents/                  Agentes de investigación + bóveda Obsidian
    │   ├── offline/                 Investigación sin MetaTrader5 + puente ML
    │   ├── live/                    API puente en vivo + guardián de riesgo
    │   ├── optimizer/               Optimizador walk-forward, validación, Monte Carlo
    │   ├── tests/                   pytest de la capa python/
    │   ├── montecarlo/              Vacía
    │   └── runtime/                 NO está en el repositorio: se crea en ejecución (ver §3.9)
    │
    └── replay_terminal/             Terminal de replay/backtest/paper (ver §4)
        ├── main.py                  Aplicación de escritorio PySide6
        ├── simular.py               Simulador de mercado sintético por consola
        ├── core/ data/ storage/     Modelos, reloj, descarga/caché SQLite, ticks
        ├── replay/ simulation/      Motor de replay sin look-ahead + mercado sintético
        ├── smc/ strategies/         Motor SMC incremental y estrategias de investigación
        ├── trading/                 Paper engine, backtest, sizing, swap, estadística
        ├── mt5/                     Conector MT5 (lectura); ejecución real deshabilitada
        ├── charts/ ui/              Gráfico pyqtgraph y ventana principal
        ├── web/                     API FastAPI + interfaz web (Lightweight Charts)
        ├── tests/                   pytest (incl. test_no_lookahead, test_architecture)
        ├── exports/                 Salidas de backtest fechadas
        └── config/                  Vacía
```

---

## 2. Visión de conjunto

Hay **cuatro bloques** que se comunican principalmente por ficheros, no por red:

```
   ┌────────────────────────┐        ficheros en <COMMON>         ┌────────────────────────┐
   │  MT5  (MQL5)           │ ◄──────────────────────────────────► │  python/  (servicios) │
   │  EAs + indicadores     │   intel.txt  commands.csv            │  gm_service, gm_intel │
   │  Include/GoldMaster    │   ea_state.txt  guardian.txt         │  gm_micro, gm_quant   │
   │                        │   ml_features.csv ⇄ ml_predictions   │  gm_guardian          │
   └────────────────────────┘   news_calendar.csv  rules_db.json   └────────────────────────┘
              │                                                               │
              │ CSV exportado por Scripts/DATOS                               │ ficheros en
              ▼                                                               ▼ python/runtime
   ┌────────────────────────┐                                      ┌────────────────────────┐
   │  python/offline        │                                      │  replay_terminal/web   │
   │  python/optimizer      │  informes JSON/CSV en out_*/         │  dashboard + replay    │
   │  python/smc  model     │                                      │  (FastAPI, 127.0.0.1)  │
   └────────────────────────┘                                      └────────────────────────┘
```

Puntos que conviene saber antes de tocar nada:

- **La ejecución real está restringida por diseño en varias capas.** `replay_terminal/mt5/execution.py`
  es una barrera: `LiveExecutionEngine` llama a `app_state.revoke_real_trading()` en el constructor y
  todo método de ejecución está bloqueado (`TradingBlocked`). `replay_terminal/trading/paper_engine.py`
  no importa MetaTrader5 y hay un test que verifica que `order_send` no aparece en el paquete
  `trading/`. Varios EAs del sistema arrancan con `PaperModeOnly = true`.
- **`python/gm_market_service.py` y `python/gm_feed.py` son de sólo lectura** y lo declaran en su
  docstring: sin órdenes, sin credenciales, sin promoción de parámetros.
- **El sizing de lote de los EAs del sistema está centralizado** en `GM_CalcLot()`
  (`<BASE>/Include/GoldMaster/GoldMaster_Core.mqh:549`), que redondea hacia abajo, comprueba margen
  y **se niega a operar** si el lote mínimo del broker arriesga más de lo permitido. El criterio y
  por qué es el número que decide la supervivencia de una cuenta pequeña están en
  [`DOCTRINA_RIESGO.md`](DOCTRINA_RIESGO.md). Los EAs antiguos no usan esta función: ver
  [`CATALOGO_EAS.md`](CATALOGO_EAS.md).

### Reorganización de carpetas (contexto para leer rutas antiguas)

Las rutas de este documento son las **actuales**. Si encuentras referencias viejas en comentarios de
código, commits o notas:

- `Experts/BOTS ORO/` (con espacio) → `Experts/BOTS_ORO/`
- Los EAs que estaban sueltos en `Experts/` se movieron a su carpeta por estrategia; en particular
  `Experts/experto oro.mq5` → `Experts/SMC_GOLD/Bot_Liquidez_UltraRapido_4H_15M.mq5`
- Los scripts de ticks de Dukascopy se movieron a `Scripts/DATOS/`, donde conviven con los nuevos
  `GM_InventarioSimbolos.mq5` y `GM_ExportarHistorico.mq5`
- `Indicators/INDICADORES/` y `Experts/Advisors/Examples/` se eliminaron por ser duplicados exactos

---

## 3. Subsistema `python/`

Responsabilidad global: producir inteligencia de mercado en vivo para los EAs, y hacer
investigación reproducible offline. Dependencias comunes: `numpy`, `pandas`; en Windows
`MetaTrader5` (sólo lectura). Varias piezas degradan a valores neutros si una fuente falla.

### 3.1 Servicios en vivo (scripts de `python/*.py`)

| Módulo | Responsabilidad | Arranque |
|---|---|---|
| `python/gm_service.py` | Servicio headless de producción. Cada 20 s (`GM_EVERY_S`) llama a `IntelEngine.compute()` → escribe `intel.txt`; levanta `MicroMonitor`; relanza el hilo micro si se congela > 30 s; escribe `service_heartbeat.txt`; re-entrena cada `GM_RETRAIN_H` horas (def. 6). | `GM_START_SERVICE.bat` o `python gm_service.py`. Variables: `GM_SYMBOL` (def. `XAUUSDmicro`), `GM_EVERY_S`, `GM_RETRAIN_H`. Log rotativo en `python/logs/service.log`. |
| `python/gm_intel.py` | Capa de inteligencia (7 módulos): calendario ForexFactory, sentimiento RSS (FinBERT si `GM_USE_FINBERT=1`, si no léxico), COT CFTC (Managed Money, Gold COMEX 088691), order flow por proxies (delta por tick-rule, VPIN BVC, Kyle lambda, volume profile, VWAP±σ), Hurst/vol/Kelly, score compuesto y el **puente**. Es el único escritor de `intel.txt`, `intel.json` y `news_calendar.csv`. | Importado por `gm_service.py` y por el dashboard. `IntelEngine.start(every_s)` o `.follow()` (modo seguidor, lee `intel.json` sin recalcular). |
| `python/gm_micro.py` | Monitor de micro-variaciones a 1 muestra/segundo: OFI (Cont-Kukanov-Stoikov), velocidad de ticks (z), spread (z), micro-tendencia EWMA 5 s vs 60 s, DXY sintético recalculado cada segundo con 6 pares, beta y correlación oro↔DXY en ventana de 30 min, lead-lag 1–15 s. Escribe `micro.json` (atómico con reintentos) y `alerts.csv`. | `MicroMonitor(symbol, gm_dir).start()`. Telegram opcional con `TELEGRAM_TOKEN` / `TELEGRAM_CHAT`. |
| `python/gm_quant.py` | Capa cuantitativa: GARCH(1,1) con respaldo EWMA(λ=0.94), régimen HMM 2–3 estados con respaldo Kaufman ER + ADX, filtro de Kalman en H1, macro intermercado (yfinance; FRED con `FRED_API_KEY`), estacionalidad horaria, gobernador de riesgo de cartera (riesgo abierto de todas las posiciones XAU) → aporta `risk_mult_q`, `gov_block`, `macro_bias`, `vol_fcst`, `regime_q` a `intel.txt`. | Se instancia dentro de `IntelEngine`. Todo opcional y tolerante a fallos. |
| `python/gm_dxy.py` | DXY con orden de fuentes: símbolo directo en MT5 → sintético ICE con los pares del broker → Twelve Data (`TWELVEDATA_API_KEY`) → Yahoo `DX-Y.NYB`. Macro FRED: `DFII10` (rendimiento real 10 a.) y `DTWEXBGS`. | Importado por `gm_intel`. |
| `python/gm_feed.py` | Utilidades de feed de sólo lectura: pesos ICE del DXY, `quote_valid()` (rechaza cotizaciones de más de 5 s), `resolve_symbol()`, `DXYFeed`, `TickCursor`. No inicializa el terminal ni envía órdenes. | Librería. |
| `python/gm_market_service.py` | Analítica multi-activo (oro, nasdaq, bitcoin, ethereum, btceth, dxy) con acceso MT5 de **sólo lectura**. Escribe `market_snapshot.json` y datasets fechados en `python/runtime/`. Usa `InstanceLock` para no duplicar instancias. | `python gm_market_service.py --once [--export-bars]` o `--interval N`. Lo lanza `INICIAR_OBSERVATORIO.ps1`. |
| `python/gm_supervisor.py` | Vigilante de producción: arranca `gm_service.py` y `GOLD_MASTER_dashboard_v3.py` como hijos con backoff; reinicia el servicio si `service_heartbeat.txt` supera 120 s o si `micro.json` se congela > 60 s; reinicia el dashboard si `http://127.0.0.1:8050` falla 3 veces. | Lo lanza `GM_START_ALL.bat` según su docstring. Log en `python/logs/supervisor.log`. |
| `python/gm_stop.py` | Mata, por PowerShell y en este orden, `gm_supervisor`, `gm_service` y `dashboard_v3`. | `GM_STOP_ALL.bat`. |
| `python/gm_control.py` | Centro de control del dashboard: interruptor **MODO AUTÓNOMO** (`autonomous.json`), trading manual a mercado con SL 1,5·ATR(M15) mínimo 8 $ y TP 2R, cierre de todas las posiciones XAU, estado del sistema. Comprueba `retcode != TRADE_RETCODE_DONE` y lo informa. Pide confirmación explícita al activar el modo autónomo. | Registrado como componente Dash. |
| `python/gm_check_binding.py` | Antes de arrancar, verifica que `terminal_info().data_path` es exactamente `<BASE>/..` y que el terminal está conectado; si no, aborta. Evita operar contra otra instalación de MT5. | Lo ejecuta `INICIAR_OBSERVATORIO.ps1` como primer paso. |
| `python/gm_runtime.py` | `InstanceLock` (bloqueo de fichero propiedad del SO, sin decisiones por PID obsoleto) y `RetrySchedule` (backoff exponencial acotado a 60 s). | Librería. |
| `python/gm_rules_bridge.py` | Exporta a `<BASE>/Files/GoldMaster/rules_db.json` sólo las reglas elegibles de `python/runtime/rules_db.json`, con esquema plano y escritura atómica. Sólo admite `implementation == 'EMA_CROSS_M15_H1'`, `tf == 'M15'`, `validated`, `costs_calibrated`, `pristine_holdout`, `report_sha256` y ≥ 30 operaciones de evidencia. El payload lleva `execution: 'disabled'`. | `python gm_rules_bridge.py`. Lo ejecuta `INICIAR_OBSERVATORIO.ps1`. |
| `python/gm_rules_db.py` | Registro de reglas validadas (dataclass `Rule`: score, evidence_trades, win_rate, profit_factor, expectancy_r, decay_trades…). Persiste en `python/runtime/rules_db.json`. | Librería (`RulesDB`). |
| `python/gm_hypothesis.py` | Motor de hipótesis: proponer, registrar operaciones y evaluar. Persiste en `python/runtime/hypotheses.json`. | Librería (`HypothesisRegistry`). |
| `python/gm_retrain.py` | Investigación de candidatos offline. Versiona cada candidato con huellas de datos y de código y resultados de holdout en `python/runtime/candidates/`. Su docstring dice explícitamente que **nunca** reemplaza los parámetros que consumen los EAs. | Llamado por `gm_service.py` en bucle; también a mano. |
| `python/gm_structure.py` | Estructura de mercado sin repintado en Python, misma lógica que `GoldMaster_Structure.mqh`: swings HH/HL/LH/LL, BOS, CHoCH, niveles multi-toque, canal de regresión, Fibonacci, y "lectura del mercado" en texto. | Librería. |
| `python/gm_small_account.py` | Comprobación de viabilidad de una cuenta pequeña: pregunta a MT5 la pérdida en dinero y el margen al volumen mínimo. Nunca envía una orden; si falta un dato devuelve `unknown`, no aprobación. | Librería (`feasibility`). |
| `python/gm_small_account_replay.py` | Replay de investigación SMC con 10 $ sobre barras cerradas de MT5, inmutable y de sólo lectura. | `python gm_small_account_replay.py` (ver `--help`). |
| `python/gm_strategy_catalog.py` | Diez estrategias H1 **congeladas** (ema_trend, rsi_pullback, donchian, compression, bollinger_range, liquidity_sweep, momentum, london_orb, previous_day, …) sobre barras cerradas. | Librería. |
| `python/gm_strategy_archive.py` | Evalúa las diez familias congeladas, archiva evidencia, rechaza las que fallan y **no promociona nada a producción**. | `python gm_strategy_archive.py` (ver `--help`). |
| `python/gm_research_run.py` | Estudio reproducible de sólo lectura con estrategias fijas; sin optimización ni órdenes. | `python gm_research_run.py`. |
| `python/gm_quality_compare.py` | Reproduce el candidato experimental `SMCQualityStrategy` sobre un dataset guardado. Marca el resultado como *comparación descriptiva, no validación independiente*. | `python gm_quality_compare.py <carpeta_con_report.json>`. |
| `python/gm_history_collect.py` | Descarga barras H1 **cerradas** de MT5, oro de Dukascopy y spot de Binance. Sin órdenes. | `python gm_history_collect.py` (argparse). |
| `python/gm_external_gold_fallback.py` | Conserva descargas parciales de Dukascopy y marca el dataset como `data_quality_passed=False` con el motivo (HTTP 429, días incompletos) para que quede excluido del ranking. | Script de un solo uso. |
| `python/gm_source_probe.py` | Sonda de disponibilidad de Binance y Dukascopy. | `python gm_source_probe.py`. |
| `python/gm_backtest.py` | Backtester ORB + optimizador walk-forward + Monte Carlo. Simula la estrategia ORB igual que el EA (hora de rango, buffer ATR, SL al lado opuesto, RR, OCO, breakeven, cancelación NY) sobre M1 con spread real y supuesto pesimista (SL y TP en la misma vela → SL). Salidas: `bt_report.html`, `bt_trades.csv`, `bt_summary.json`. | `python gm_backtest.py --symbol XAUUSD --from … --to …` o `--csv XAUUSD_M1.csv`; `--quick`. |
| `python/gm_chart.py` | Gráfico Pro v5 para el dashboard: capas (estructura, niveles, canal, Fibonacci, FVG, OB, EMAs, VWAP/POC, órdenes, DXY), dibujos persistentes y alertas de precio. Persiste en `drawings_<SÍMBOLO>.json` y `alerts_<SÍMBOLO>.json`. | Componente Dash. |
| `python/gm_pro_chart.py` | Terminal PRO con TradingView Lightweight Charts servido dentro del dashboard en `/pro`. API: `/api/candles`, `/api/live`, `/api/intel`. Lee del puente `micro.json`, `intel.json`, `alerts.csv`, `signal_params.txt`, `news_calendar.csv`, `ea_state.txt`, `service_heartbeat.txt`. | Se registra sobre el servidor Flask del dashboard (puerto 8050). |
| `python/GOLD_MASTER_dashboard_v3.py` | Dashboard Dash v3.1: ensemble ML, alertas Telegram, curva de capital, mapa de calor por sesión, Sharpe/drawdown, backtesting visual. | `python GOLD_MASTER_dashboard_v3.py` → `http://127.0.0.1:8050`. Lo arranca `gm_supervisor.py`. |

### 3.2 `python/core/`

- **Responsabilidad:** un único punto de entrada de datos para todo el sistema.
- `core/gm_data.py` — entiende exports de MT5 (TSV con cabeceras `<DATE> <TIME> <OPEN>…`), CSV
  genérico (coma o punto y coma) y Excel. Devuelve siempre el mismo contrato: DataFrame con
  `DatetimeIndex` UTC ordenado, columnas `open/high/low/close/volume` en float, sin duplicados ni
  precios ≤ 0.
- **Depende de:** `pandas`. **Ejecutable:** no, es librería.

### 3.3 `python/model/` — la "ecuación maestra" del oro

- **Responsabilidad:** modelar la **estructura de riesgo** del oro, no predecir su dirección.
- `model/gm_gold_sde.py` — SDE de 4 capas para el log-precio:
  `d ln S(t) = μ(t) dt + σ(t)·s(h) dW(t) + J dN(t)` (volatilidad agrupada, colas gruesas, saltos,
  estacionalidad horaria, regímenes), calibrado sobre datos reales 2004-2025. El propio módulo
  advierte que no es una fórmula de predicción, sino la base para dimensionar posiciones y calcular
  probabilidad de ruina.
- `model/gm_calibrate.py` — protocolo de calibración: partición entrenamiento/prueba por fecha sin
  solape, calibración sólo con entrenamiento, validación en prueba, recalibración completa para
  producción, informe con las métricas medidas **incluidas las que salen mal**.
  Uso: `python gm_calibrate.py <XAU_real_h1_21y.csv> --split 0.75 --out out_model`.
- `model/gm_dxy.py` — estudio serio de la relación oro/DXY: correlación contemporánea y móvil (lo
  relevante es su **dispersión**), correlación por régimen de volatilidad (en crisis oro y dólar
  suben juntos y la cobertura se rompe), adelanto/retraso por correlación cruzada, cointegración.
- **Salidas:** `model/out_model/`. **Tests:** `model/tests/`.

### 3.4 `python/smc/` — order blocks bajo prueba

- **Responsabilidad:** detectar order blocks exhaustivamente y **medir si alguno tiene esperanza
  positiva** una vez corregido por pruebas múltiples.
- `smc/gm_orderblocks_pro.py` — detector con subtipos etiquetados: `classic`, `breaker`,
  `mitigation`, `rejection`, `propulsion`, más atributos ortogonales combinables.
- `smc/gm_ob_strategies.py` — espacio paramétrico de estrategias de OB: zona (`full`/`body`/`eq`),
  entrada (`touch`/`eq`/`deep`), stop (borde distal + colchón ATR), objetivo (múltiplo de R o
  estructura), filtros (escenario, sweep previo, FVG, extremo de rango, BOS, sesión) y caducidades.
- `smc/gm_ob_montecarlo.py` — tres pruebas de exigencia creciente: bootstrap de la secuencia
  (ruina, drawdown, dispersión), **contraste de realidad de White** (corrección por haber probado N
  especificaciones; el bootstrap se hace sobre los order blocks, no por estrategia) y una tercera
  más estricta.
- `smc/gm_ob_campaign.py` — campaña en 5 fases con resultados parciales: detección y barrido sobre
  oro real con train/test por fecha → bootstrap por bloques → contraste de White → test nulo
  sintético con caminos de la ecuación maestra (sin estructura institucional) → veredicto y
  meta-etiquetado ML. `--budget-min` corta por tiempo y el informe dice con cuántos caminos nulos
  se concluyó.
- **Depende de:** `python/model/` (caminos nulos) y `numpy`/`pandas`.

### 3.5 `python/agents/`

- **Responsabilidad:** acumular criterio entre ciclos de investigación en lugar de repetir
  experimentos.
- `agents/gm_vault.py` — bóveda Obsidian como cuaderno de laboratorio: nota markdown por
  experimento con YAML, enlaces `[[wiki]]` y veredicto explícito. Lleva el **libro de pruebas
  múltiples**, que es su razón de ser: contar cuántas hipótesis se han contrastado para que el
  umbral de significación se endurezca.
- `agents/gm_agents.py` — agentes que consultan la bóveda: `AgentContext.ya_refutado()` evita
  repetir lo refutado y `corrected_threshold()` endurece el umbral con cada barrido.
- `agents/gm_lab.py` — lanzador:
  `python gm_lab.py --vault ~/GoldMasterVault --gold datos/XAUUSD_H1.csv --dxy datos/DXY_d1.csv`;
  también `--agentes regimen,critico` y `--estado`.

### 3.6 `python/offline/` — investigación sin MetaTrader5

- **Responsabilidad:** backtest y validación ejecutables en Linux/CI con datos exportados.
  **No usa** la librería `MetaTrader5` y **no despliega** parámetros a ningún EA (así lo declara
  `offline/README.md`).
- `offline/mt5_import.py` — importador robusto de exports de MT5 (TAB/coma/punto y coma, con o sin
  columna de hora, CRLF, con o sin `<corchetes>`, Excel) → `time,open,high,low,close,tickvol,volume,spread`.
  `resample()` reagrega M1 a cualquier temporalidad sin look-ahead.
- `offline/gm_bridge.py` — **lado Python del puente ML**. Entrena tres clasificadores reales y sirve
  `ml_predictions.csv` con el contrato exacto de `GoldMaster_ML.mqh`. Mapa honesto declarado en el
  propio fichero: `confidence_lstm` ← regresión logística, `confidence_xgb` ← HistGradientBoosting,
  `confidence_lgbm` ← RandomForest, `ensemble` ← media de las tres; el régimen sale del HMM de
  `gm_ml`. Uso: `python gm_bridge.py train <M1.csv>`, `predict <M1.csv>`,
  `serve --dir "<ruta>/MQL5/Files/GoldMaster" --interval 5`.
- `offline/gm_offline.py` — backtest de la estrategia PRO Signals M1 reutilizando `gm_optimizer`,
  split cronológico con purga, Monte Carlo bootstrap estacionario y meta-labeling con umbral fijo.
- `offline/gm_ml.py` — régimen HMM de 3 estados ordenados por volatilidad (`calmo`/`normal`/`agitado`,
  ajustados sólo con el tramo de entrenamiento) + meta-labeling walk-forward purgado + modelo lineal
  exportable a MQL5.
- `offline/gm_forecast.py` — pronóstico **probabilístico** de las 2 próximas velas H4 y el camino
  M15 que las forma: deriva por Ridge sobre features causales, volatilidad EWMA, Monte Carlo de M
  caminos de 16 pasos. El módulo dice explícitamente que la dirección a esos plazos es casi aleatoria
  (AUC ≈ 0,51) y que por eso entrega una distribución, no un número.
- `offline/gm_research.py` — búsqueda anti-sobreajuste: exige que una configuración sea positiva en
  **dos arenas a la vez**, el tramo test real (30 % final) y 5 años sintéticos por block bootstrap.
- `offline/gm_robustness.py` — suite de robustez por transformaciones del histórico: `identity`,
  `mirror` (espejo vertical), `reverse` (tiempo invertido) y más. Sirve para detectar que una
  estrategia iba montada en la tendencia alcista del oro.
- `offline/gm_synth.py` — generador de M1 sintético por bootstrap de bloques (conserva
  autocorrelación, rachas de volatilidad y forma intravela). Salida en formato export de MT5.
  Advertencia explícita: no es historia real.
- `offline/gm_tournament.py` — torneo de las 10 estrategias del catálogo + PRO Signals M1 con split
  cronológico y Monte Carlo del PnL fuera de muestra; veredictos `KEEP` / `WEAK` / `JUNK`.
- `offline/gm_orderblocks.py` — estrategia de retest de order blocks causales con canal de regresión
  y EMAs 50/200 como sesgo.
- `offline/gm_channels_smc.py` — canales de regresión + rompimiento + OB + BOS/CHoCH, en H1, sólo
  velas cerradas.
- `offline/gm_confluence.py` — motor de confluencias: votos direccionales separados en **contexto**
  (ema, channel, momentum) y **gatillos** (ob, fvg, wyckoff spring/upthrust) y búsqueda de la mejor
  mezcla.
- `offline/gm_capital.py` — escalera de capital por etapas (`risk_pct`, `daily_target`,
  `daily_loss`, `max_trades_day` por tramo de equity). `DEFAULT_STAGES` es la referencia que
  reutilizan `gm_guardian.py` y `GoldMaster_Guardian.mqh`.
- **Salidas:** `offline/out_offline/`. **Tests:** `offline/tests/`.

### 3.7 `python/live/`

- **Responsabilidad:** unir MT5 + los ficheros del puente + el pronóstico en un solo API JSON para
  el *workstation* web, y hacer cumplir el riesgo.
- `live/gm_live_api.py` — FastAPI. Fuentes en cascada: MT5 (cuenta, posiciones, cotización, DOM vía
  `MarketBookGet`) → ficheros del puente (`intel.txt`, `micro.json`, `ea_state.txt`,
  `news_calendar.csv`) → offline. Endpoints: `/api/status`, `/api/account`, `/api/positions`,
  `/api/quote`, `/api/dom`, `/api/flow`, `/api/news`, `/api/forecast`, `/api/sentiment`,
  `/api/snapshot`, `POST /api/guardian/evaluate`, `GET|POST /api/journal`, `/api/guardian/learn`.
  Carpeta del puente configurable con `GM_BRIDGE_DIR`; símbolo con `GM_SYMBOL`.
  Arranque: `uvicorn gm_live_api:app --port 8777` desde `python/live`.
- `live/gm_guardian.py` — tres piezas sin dependencia de MT5 (testeable headless):
  1. `RiskGovernor.evaluate(equity, stop_distance, ctx)` aplica escalera de capital, tope de riesgo
     por operación, objetivo y stop diarios, máximo de operaciones/día, bloqueo por noticias, por
     régimen "agitado" y por spread, y el **suelo de lote mínimo**; devuelve lote permitido, riesgo
     en dinero, si se permite y **por qué**.
  2. `Journal`: registra cada operación con su contexto en JSONL.
  3. `learn_from_journal()`: entrena un clasificador contexto→ganancia con las operaciones reales
     del usuario.
  `RiskGovernor.export_limits(dir)` es el escritor de `guardian.txt`.
  Economía por símbolo declarada: `XAUUSDmicro` (min_lot 0.1, 1.0 USD por punto de precio y lote),
  `XAUUSD` (min_lot 0.01, 100.0).
- `live/workstation_live.html` — interfaz que consume `/api/snapshot` (1 fetch/s).

### 3.8 `python/optimizer/`

- `optimizer/gm_validation.py` — primitivas de ejecución y validación offline, con sus supuestos
  escritos: los OHLC de MT5 se tratan como **bid** y el spread de la barra aproxima el ask; los OHLC
  no permiten recuperar el orden intra-vela, así que **los stops tienen precedencia**, un stop
  modificado se activa en la barra siguiente y los límites no reciben mejora por hueco favorable.
  Dice explícitamente que validar la ejecución real exige replay de ticks.
- `optimizer/gm_optimizer.py` — optimizador + walk-forward + Monte Carlo de la estrategia PRO
  Signals (M1) con datos reales de MT5. `python gm_optimizer.py` → `./out`. Funciona sin MT5
  instalado para la parte numérica.
- `optimizer/gm_lab.py` — compara DEMA-live, Pullback de tendencia (RSI) y ruptura de Londres (ORB)
  con walk-forward 70/30 y Monte Carlo para una cuenta de 50 USD.
- `optimizer/gm_montecarlo.py` — Monte Carlo de **trayectorias de precio** en tres universos: REAL
  (bootstrap estacionario por bloques), SIM (GARCH(1,1) con innovaciones t de Student + rangos
  intravela muestreados) y MIXTO (≈50/50).
- **Salidas:** `optimizer/out/`.

### 3.9 `python/tests/` y `python/runtime/`

- `python/tests/` — `test_atomic_snapshot.py`, `test_market_validation.py`, `test_rules_bridge.py`,
  `test_runtime.py`, `test_small_account.py`, `test_strategy_catalog.py`. Ejecución: `pytest` desde
  `python/`.
- `python/runtime/` — **no existe en el repositorio**; se crea en ejecución. Contiene
  `rules_db.json`, `hypotheses.json`, `market_snapshot.json`, `observer.pid`, `replay.pid`,
  `observer.out.log`, `observer.err.log`, `replay.out.log`, `replay.err.log`, `candidates/`,
  `datasets/<marca_de_tiempo>/`, `research_archive_latest.json` y
  `history_archive_20261007/`. Es **estado local, no fuente**.

---

## 4. Subsistema `replay_terminal/`

Responsabilidad: terminal de investigación — replay histórico sin look-ahead, mercado sintético,
paper trading, backtest y un dashboard web. **La ejecución real está deshabilitada en el código**
(`mt5/execution.py`).

Dependencias fijadas a propósito en `replay_terminal/requirements.txt` (el comentario explica que
el Control de aplicaciones de Windows bloquea las DLL de paquetes demasiado nuevos):
`PySide6==6.11.2`, `pyqtgraph==0.14.0`, `pandas==2.2.3`, `numpy==2.2.6`, `pydantic>=2.7`,
`fastapi==0.142.2`, `uvicorn==0.54.0`, `httpx>=0.27`, `pytest>=8.0`.
Aparte: `requirements-mt5.txt` → `MetaTrader5==5.0.5120` (la 5.0.6231 tiene la DLL bloqueada).

### 4.1 `core/`

- `core/models.py` — modelos base y **la convención temporal de todo el sistema**: `Bar.time` es la
  **apertura** de la vela (igual que MT5) y una vela está cerrada en `time + duración del TF`.
  Incluye `TIMEFRAME_SECONDS`, `is_derivable`, `tf_bucket_start`, `tf_close`, `epoch_s`.
- `core/app_state.py` — estado global y modos: `LIVE`, `REPLAY`, `PAPER`, `REAL`, `SYNTHETIC`.
  Expone `revoke_real_trading()`.
- `core/logging_setup.py` — `logs/app.log`, `logs/trading.log`, `logs/errors.log` con formato
  `timestamp | level | module | event | message | account | symbol`. Nunca registra contraseñas ni
  tokens.

### 4.2 `data/`

- `data/data_manager.py` — `MT5 → DataManager → caché SQLite → replay/backtest/gráficos`. Reglas
  declaradas: timestamps internos en UTC tz-aware; MT5 entrega la hora del **servidor del broker**
  y se guarda tal cual rotulada como UTC (la UI muestra ambas); **no se fabrican datos**, los huecos
  se detectan y se informan; una temporalidad se deriva de una inferior sólo si es múltiplo exacto
  (`resample_ohlc`), con W1 empezando en domingo como MT5.
- `data/aggregator.py` — `BarAggregator`: construye temporalidades superiores vela a vela y sólo
  emite velas **cerradas**; `forming` existe únicamente para dibujar.
- `data/ticks.py` — `annotate_first_extreme(bars, ticks, tf)` resuelve con ticks reales
  (`mt5.copy_ticks_range`) qué extremo del bid se alcanzó primero dentro de cada vela; las velas sin
  ticks quedan en `None` y la política las cuenta, nunca se inventan. `fetch_ticks_range()` descarga
  por bloques diarios.

### 4.3 `storage/`

- `storage/database.py` — SQLite, sin credenciales nunca. Tablas: `accounts`, `symbols`,
  `candles_cache`, `drawings`, `layouts`, `trades`, `positions`, `backtests`, `backtest_trades`,
  `settings`, `smc_events`, `logs`, `schema_version`. Migraciones idempotentes.

### 4.4 `replay/`

- `replay/replay_engine.py` — un único `ReplayClock` cuyo valor es siempre el **cierre de la última
  vela base visible**. Para cada TF: `visible(tf)` = velas cerradas con `time + tf <= reloj`;
  `forming(tf)` = vela en formación construida sólo con velas base ya cerradas (sólo para dibujar).
  Con un `SyntheticMarket` activo, al agotar los datos reales continúa generando velas marcadas
  `synthetic=True` (modo fin de semana).

### 4.5 `smc/`

Motor SMC **incremental y causal**: se alimenta con velas cerradas en orden cronológico vía
`on_bar()`, y cada vela sólo puede afectar a objetos detectados en o después de su cierre.
`tests/test_no_lookahead.py` demuestra vela a vela que calcular todo el histórico y consultar
`snapshot(t)` es idéntico a calcular sólo con las velas cerradas hasta `t`.

| Módulo | Qué define |
|---|---|
| `smc/smc_engine.py` | Orquestador (`SMCEngine`, `SMCConfig`), `snapshot(t)` |
| `smc/swings.py` | Swing high/low con confirmación: un swing en `c` necesita `right_bars` velas posteriores, se confirma al cierre de `c + right_bars` (`detected_at`) |
| `smc/structure.py` | Máquina de estados BOS/CHoCH con estados `UNKNOWN`/`BULLISH`/`BEARISH`/`RANGING`; define objetivamente `RANGING` como "CHoCH fallido" seguido de CHoCH contrario |
| `smc/order_blocks.py` | OB con definición configurable: exige ruptura estructural, busca la última vela contraria hasta `lookback`, mide desplazamiento en múltiplos del rango del OB, filtro de volumen opcional; estados `ACTIVE → MITIGATED → INVALIDATED` |
| `smc/fvg.py` | FVG de 3 velas detectado al cierre de c3; estados `OPEN → PARTIALLY_FILLED → FILLED → INVALIDATED` |
| `smc/liquidity.py` | BSL/SSL, EQH/EQL con tolerancia configurable (no hay valor universal por símbolo) y barridos |
| `smc/models.py` | Objetos con `formation_time` y `detected_at`, más historial `(time, status)` para consultar el estado "tal como era" |
| `smc/top_down.py` | Análisis multitemporal D1→H4→H1→M15, **descriptivo**: no genera señales por sí mismo |

### 4.6 `strategies/`

- `strategies/base.py` — contrato: la estrategia sólo ve `BacktestContext` (velas cerradas hasta la
  actual y motores SMC alimentados con esas mismas velas) y sus órdenes se ejecutan en la
  **apertura de la vela siguiente**.
- `strategies/smc_fvg.py` — estrategia de ejemplo: sesgo HTF → confirmación BOS/CHoCH en TF base →
  FVG en la dirección aún `OPEN`/`PARTIALLY_FILLED` → gatillo al entrar y cerrar fuera del extremo
  lejano → SL en el extremo lejano ± buffer, TP = rr × riesgo.
- `strategies/smc_quality.py` — `SMC_QUALITY_CANDIDATE` v1.0 con puertas explícitas de calidad,
  coste y riesgo (`min_gap_atr`, `max_spread_atr`, `max_setup_bars`, `daily_loss_pct`,
  `max_daily_entries`), `risk_pct` ≤ 1. Etiquetado en el propio docstring como *no certified alpha*.
- `strategies/macro_liquidity.py` — `GM_MACRO_LIQUIDITY_CANDIDATE` v1.0: barrido H3 → ruptura H1 →
  gatillo M15, con DXY requerido. *No live orders.*

### 4.7 `trading/`

- `trading/paper_engine.py` — operaciones virtuales. **Barrera arquitectónica declarada**: no
  importa MetaTrader5 ni `mt5/execution`; un test comprueba que `order_send` no aparece en el
  paquete. Precios: las velas de MT5 son bid, la compra entra a ask (+slippage) y sale a bid.
  Ambigüedad OHLC (SL y TP en la misma vela sin ticks): política `WORST_CASE` por defecto (se asume
  SL); el resto de políticas está en `AMBIGUITY_POLICIES`.
- `trading/backtest_engine.py` — bucle vela a vela sin look-ahead: (1) en la apertura de `i` se
  ejecutan las órdenes emitidas al cierre de `i-1`, recalculando el lotaje con el precio **real** de
  entrada y cancelando la orden si la apertura ya rebasó el SL; (2) SL/TP durante la vela con
  política de ambigüedad; (3) al cierre de `i` los motores SMC reciben la vela; (4) la estrategia
  decide con información hasta el cierre de `i`; (5) se registra la equity.
- `trading/position_sizer.py` — **no usa fórmulas universales tipo "pip value = 10"**: el valor
  monetario de entrada→SL lo calcula una `profit_fn` (`mt5.order_calc_profit` en vivo,
  `SymbolSpec.default_profit_fn` con el tamaño de contrato real en simulación). Redondea el volumen
  **hacia abajo** al `volume_step` y valida contra `volume_min`/`volume_max`.
- `trading/risk_manager.py` — cálculo de SL/TP y validaciones previas.
- `trading/swap.py` — swap con las reglas de MT5: se cobra por cada medianoche del servidor cruzada,
  sólo en rollovers de lunes a viernes, con triple el día de `swap_rollover3days`. Soporta los modos
  `DISABLED`, `POINTS`, `CURRENCY_SYMBOL` y los demás documentados en el fichero.
- `trading/statistics.py` — métricas con su definición escrita para que sean auditables: profit
  factor, expectancy, payoff, max drawdown sobre equity, Sharpe/Sortino sobre retornos **diarios**
  anualizados con √252 y tasa libre de riesgo 0 (requieren ≥ 2 días), Calmar, recovery factor.
- `trading/trade_models.py` — `SymbolSpec` y modelos de operación, sin dependencias de MT5.

### 4.8 `simulation/`

- `simulation/synthetic_market.py` — generador de mercado sintético calibrado con velas reales de
  MT5, para el caso "es fin de semana y el mercado está cerrado". Lleva su propia sección de
  ADVERTENCIA.
- `simulation/sim_session.py` — sesión de práctica sobre mercado sintético. Barrera de seguridad
  declarada: no importa MetaTrader5 ni el ejecutor real.

### 4.9 `mt5/`

- `mt5/connector.py` — única responsabilidad: la conexión al terminal. Estrategias en orden:
  `mt5.initialize()` → `initialize(path=…)` con ruta manual o guardada → diálogo para elegir
  `terminal64.exe`. Regla de seguridad declarada: **nunca guarda contraseñas**.
- `mt5/market_data.py` — descarga mínima de velas y especificación de símbolo. Funciones MT5 usadas
  listadas en el docstring. Advertencia sobre la hora del servidor del broker.
- `mt5/account.py` — `MT5Monitor`: hilo de monitoreo periódico de conexión y cuenta.
- `mt5/execution.py` — **frontera de ejecución**: `LiveExecutionEngine` revoca el trading real al
  construirse y todos sus métodos lanzan `TradingBlocked`.

### 4.10 `charts/` y `ui/`

- `charts/chart_widget.py` — gráfico de velas con zoom/paneo, crosshair OHLCV, overlays y
  herramientas de dibujo (línea H/V, trendline, rectángulo, texto, Fibonacci, canal paralelo). Los
  dibujos se guardan en **tiempo y precio**, no en píxeles, para sobrevivir a recargas.
- `charts/picture_overlay.py` — todas las primitivas se pintan en un único `GraphicsObject` por
  rendimiento; marcadores y textos en coordenadas de pantalla.
- `charts/candle_item.py`, `charts/overlays.py` — velas con `QPicture` cacheado y pintado de objetos
  SMC/operaciones ya filtrados por el reloj.
- `ui/main_window.py` — ventana principal y controlador (50 KB). Modos siempre visibles: `REPLAY`,
  `SYNTHETIC`, `LIVE`, `REAL` (este último sólo con autorización explícita). Regla de hilos: **todas
  las llamadas a MetaTrader5 se hacen en el hilo principal**.
- `ui/trade_panel.py` — muestra antes de operar símbolo, bid, ask, spread, cuenta, balance, equity,
  riesgo %, SL, TP, riesgo en dinero, volumen, margen y R:R; lo que no se puede calcular se muestra
  como `N/A`, nunca se inventa. No decide si la orden es real o virtual: emite `order_requested`.
- `ui/dialogs.py` — `confirm_real_trading(parent, login, server)`: confirmación explícita.
- `ui/replay_panel.py`, `ui/smc_panel.py`, `ui/backtest_panel.py`, `ui/style.py`, `ui/autotest.py`.
- **Arranque de la app de escritorio:**
  `python main.py [--terminal RUTA] [--check] [--console] [--autotest CAPTURA.png] [--symbol XAUUSD]`.
- **Prueba automática de la UI con datos reales:**
  `.venv\Scripts\python.exe main.py --autotest logs\captura.png --symbol XAUUSD` — recorre conexión,
  carga de velas, replay, operación simulada, dibujo, mercado sintético, backtest y captura; nunca
  envía órdenes reales.

### 4.11 `web/`

- `web/server.py` — API FastAPI + interfaz con TradingView Lightweight Charts (vendorizado en
  `web/static/vendor`). Escucha **sólo en 127.0.0.1**; operaciones virtuales; ejecución real
  deshabilitada.
- `web/service.py` — `TradingService`, el controlador de la versión web (64 KB). Reutiliza
  exactamente los mismos motores que la app de escritorio y **no contiene lógica de trading propia**.
  Todas las operaciones que tocan MT5 o el estado de sesión se ejecutan en un único hilo porque la
  librería `MetaTrader5` no es thread-safe.
- `web/dashboard_api.py` — `register_dashboard(app, svc_holder)` añade `/api/dashboard`, que reúne
  cuenta MT5 en vivo, reglas activas de `python/runtime/rules_db.json`, hipótesis de
  `python/runtime/hypotheses.json`, `market_snapshot.json` y el estado de compilación de los EAs de
  `<BASE>/Experts/GOLD_MASTER_SYSTEM`. También `/api/dashboard/rules_db` y
  `/api/dashboard/hypotheses`.
- `web/research_api.py` — endpoints de sólo lectura del archivo de investigación; resuelve la carpeta
  por el puntero `python/runtime/research_archive_latest.json`.
- `web/demo_data.py` — datos aleatorios etiquetados con el símbolo `DEMO` para probar sin MT5.
- **Arranque:** `python -m web [--port N] [--no-browser]` desde `replay_terminal/`. Puerto por
  defecto **8000** en `web/__main__.py`; `INICIAR_OBSERVATORIO.ps1` lo arranca en **8766**.

### 4.12 `tests/`

17 ficheros, entre ellos: `test_no_lookahead.py` (prueba la causalidad del motor SMC),
`test_architecture.py` (verifica las barreras: que `trading/` no contenga `order_send`),
`test_backtest.py`, `test_paper_trading.py`, `test_position_sizing.py`, `test_risk.py`,
`test_swap_ticks_calendar.py`, `test_synthetic_market.py`, `test_replay.py`, `test_smc.py`,
`test_web_api.py`, `test_gui_smoke.py`, `test_mt5_connection.py`,
`test_integration_hardening.py`, `test_data.py`, `test_execution.py`, más `conftest.py`.
Ejecución: `pytest` desde `replay_terminal/`.

---

## 5. Subsistema `<BASE>/Include/GoldMaster/` (librerías MQL5)

Responsabilidad: todo lo compartido por los EAs e indicadores del sistema. Un EA del sistema típico
incluye `GoldMaster_Core.mqh` y de ahí lo que necesite.

| Módulo | Responsabilidad | Piezas clave |
|---|---|---|
| `GoldMaster_Core.mqh` (671 líneas) | Núcleo. Es el fichero que hay que leer primero. | `GM_CalcLot()` (sizing con suelo de lote mínimo, redondeo a la baja y control de margen), `GM_NormalizeLot`, `GM_GetATR`, `GM_GetEMA`, `GM_GetSpread`, `GM_FillingMode`, `GM_Log`, `GM_ServerIdentity`, estructuras `GMSignal`/`GMTradeState`/`GMNewsEvent`/`GMMTFBias`/`GMSpreadState`, clases `CGMNewsFilter`, `CGMMTFBiasEngine`, `CGMVolatilityRegime`, `CGMSpreadMonitor`. Variables globales de política: `g_gm_minlot_risk_tol` (def. 1.5) y `g_gm_minlot_max_pct` |
| `GoldMaster_Bridge.mqh` (166) | Lado MQL5 del puente con Python. `CGMBridge` | `ReadIntel()` (parser key=value de `intel.txt`, valida edad ≤ `max_age` y que el símbolo coincida), `PollNew()` (comandos nuevos de `commands.csv`, procesa `PAUSE`/`RESUME`), `WriteState()` (escribe `ea_state.txt`), `BlockTrading()`, `RiskMult()` (acotado a [0,1]), `AutoTrade()`. En el tester (`MQL_TESTER`) el puente se desactiva: `ReadIntel` devuelve inválido, `BlockTrading` es `false` y `RiskMult` es 1.0 |
| `GoldMaster_Guardian.mqh` (118) | Gobernador de riesgo **dentro** del EA. Replica en MQL5 lo que evalúa `gm_guardian.py` | `CGMGuardian::CanTrade(equity, stop_price, usd_per_price, min_lot, regime_agitado, near_news_min, spread_points)` → `GMGuardDecision{allow, reason, lot, risk_usd, risk_pct, score}`. Escalera por defecto: 0–25 $ → 3 %/op, objetivo 2, stop 1,5, 3 ops; 25–50 $ → 3,5 %, 4, 2,5, 4 ops; ≥ 50 $ → 6 %, 12, 8, 6 ops. `SyncFromBridge()` lee `guardian.txt` |
| `GoldMaster_ML.mqh` (323) | Puente CSV de ML. `CGMLBridge` | Lee `ml_predictions.csv` (fila más reciente, caducidad `m_max_age_s` = 300 s, confianza mínima 0.60, ≥ 2 de 3 modelos de acuerdo), `WriteFeatures()` escribe `ml_features.csv`. También `GMConfluenceScore` y `GM_CalcConfluence()` (0–15+, mínimo recomendado 5) |
| `GoldMaster_ML_ONNX.mqh` (278) | Inferencia con el ONNX Runtime nativo de MT5. Modelo XGBoost → ONNX entrenado en `GC=F` 1 h, 2 años | `GM_ML_Predict()` |
| `GoldMaster_SMC.mqh` (523) | Motor SMC v3.1 | `CGoldMasterSMC` + `GMSwing`, `GMOB`, `GMFVG`, `GMLiqLevel`, `GMPremiumDiscount`, `GMBias`. Incluye OB quality score, inducements, breaker y mitigation blocks, score de confluencia multi-TF |
| `GoldMaster_Structure.mqh` (287) | Estructura sin repintado, arrays en orden cronológico (0 = más antiguo) | `GMS_Swings`, `GMS_Events`, `GMS_Analyze`, `GMS_TrendName`, `GMS_EventName`, `GMSSwing`, `GMSEvent`, `GMSLevel`, `GMSState`, `GMOrderBlock`, `GMFairValueGap`, `GMConfluence` |
| `GoldMaster_DXY.mqh` (115) | `CGMDXY`: usa el índice del broker si existe (`USDX`, `DXY`, `DX`, `USDIndex`…) y si no lo sintetiza con la fórmula oficial ICE detectando sufijos del broker | `Ready()`, `Value()`, `ChangePct()`, `GoldBias()`, `Mode()` |
| `GoldMaster_DXY_Filter.mqh` (124) | `CGMDXYFilter`: lee `dxy`, `dxy_chg24`, `real_yield`, `ry_bias`, `dxy_mode`, `dxy_bias` de un JSON con un parser mínimo | `DXYBias()`, `DXYVeto(dir)`, `ScoreAdjust(dir)`, `Summary()`. Ver la advertencia de §7 sobre `gm_state.json` |
| `GoldMaster_MacroLiquidity.mqh` (49) | Canal de regresión sobre la **vela H3 ya cerrada**; rechaza si falta historial o si la vela no ha terminado | `GM_MacroRead`, `GM_MacroDraw`, `GM_MacroH1`, `GM_DXYClosed`, struct `GMMacro` |
| `GoldMaster_MacroRisk.mqh` (29) | Riesgo al SL en moneda de cuenta sumando **todas** las posiciones y pendientes. Si una posición no tiene SL o no se puede valorar, **bloquea la admisión** | `GM_AccountStopRisk(risk, reason)` |
| `GoldMaster_PendingOrders.mqh` (404) | Órdenes pendientes con gestión, expiración, cancelación y reentrada | `CGoldMasterPending::PlaceORBOrders(...)`, `CancelAllPending`, `CountPending`, `CancelOrder` |
| `GoldMaster_PositionManager.mqh` (228) | Gestión de posiciones | `CGoldMasterPositionManager::ManageAll`, `SetATR`, `SetBreakevenR`, `CountPositions` |
| `GoldMaster_Partials.mqh` (203) | Cierres escalonados: TP1 (1R) cierra `Pct1` y mueve SL a BE; TP2 (2R) cierra `Pct2`; el runner lleva trailing ATR | `CGMPartials`, `GMPartialState` |
| `GoldMaster_Sessions.mqh` (198) | Sesiones en hora de servidor: Asia 00–08 (liquidez, no operar por defecto), Londres 07–12, Overlap 12–15, NY 15–20, Dead 20–24. Rango asiático como zona de liquidez | `CGMSessions` |
| `GoldMaster_Assets.mqh` (300) | Perfiles multi-activo: oro (`XAUUSD`/`XAUUSDmicro`), Nasdaq, S&P 500, Dow, BTC, ETH y perfil forex genérico | `GM_GetProfile(_Symbol)` → `GM_AssetProfile` |
| `GoldMaster_Panel.mqh` (395) | Panel en gráfico + estadística de sesión, con modo replay. La cabecera documenta seis correcciones de la v2.1, entre ellas que el EA debe pasar `MQL_VISUAL_MODE` y **no** `MQL_TESTER` a `SetReplayMode` | `CGMPanel::Show`, `RegisterTrade`, `SetReplayMode`, `OnEvent`, `GM_SessionStats` |
| `GoldMaster_Logger.mqh` (148) | Log con niveles a fichero en la carpeta común | `CGMLogger`, macros `GM_LOG_I/W/E`, `ENUM_GM_LOGLEVEL` |

---

## 6. Subsistemas MQL5 ejecutables

### 6.1 `<BASE>/Experts/`

El catálogo completo, con estrategia, parámetros de riesgo, controles y banderas rojas por fichero,
está en **`CATALOGO_EAS.md`** (documento hermano). Resumen de carpetas en §1 del árbol.

### 6.2 `<BASE>/Indicators/GOLD_MASTER_SYSTEM/`

- `GOLD_MASTER_PRO_Signals.mq5` (1312 líneas) — señales M1/M5/M15 con entrada, SL y TP1/TP2/TP3,
  estructura sin repintado, confluencia multitemporal M1·M5·M15·H1·H4 con grado A+/A/B, caja de
  operación gráfica, lote sugerido y tasa de acierto medida sobre el historial del gráfico. Con
  `UseAutoParams=true` relee cada 300 s `GoldMaster\signal_params.txt` (ver §7).
- `GOLD_MASTER_Indicador_v4.mq5` (351) — estructura "menos es más": swings etiquetados, BOS/CHoCH
  con línea desde el swing a la vela de ruptura, los N OB y FVG sin mitigar más cercanos, EQH/EQL,
  niveles multi-toque, premium/equilibrio/discount y panel con tendencia H1/LTF y DXY.
- `GOLD_MASTER_Institutional.mq5` (106) — VWAP diario con bandas ±1σ/±2σ, PDH/PDL/PDC, apertura
  semanal, rango asiático (00–07 servidor) y squeeze Bollinger(20,2) dentro de Keltner(20,1.5).
  Declara no repintado: todo con velas cerradas.
- `GOLD_MASTER_MACRO_LIQUIDITY.mq5` (12) — envoltorio que dibuja el canal H3 de
  `GoldMaster_MacroLiquidity.mqh`. Su propio `Comment` dice que son "niveles candidatos, no libro de
  órdenes".

### 6.3 `<BASE>/Scripts/DATOS/`

Responsabilidad: alimentar el laboratorio Python con datos del **broker real**. Los cuatro scripts
son de sólo lectura sobre el mercado.

| Script | Qué hace | Entradas | Salida |
|---|---|---|---|
| `GM_ExportarHistorico.mq5` | Exporta todo el histórico disponible de un símbolo en el formato que lee `python/core/gm_data.py` sin configuración. Pide la historia al terminal (descarga perezosa) antes de exportar. | `InpSimbolo` (vacío = el del gráfico), `InpTF` (def. `PERIOD_H1`), `InpDesde` (def. 2004.01.01), `InpHasta` (0 = ahora), `InpMaxBarras` (2 000 000) | `<BASE>/Files/GoldMaster/<SÍMBOLO>_<TF>.csv` (`FILE_COMMON`) |
| `GM_InventarioSimbolos.mq5` | Interroga al terminal: qué símbolos ofrece el broker de verdad y cuánta historia hay de cada uno. La cabecera advierte que el "USD Basket" de Deriv es equiponderado y **no** es el DXY de ICE (media geométrica, EUR al 57,6 %). | `InpFiltro`, `InpSoloVisibles`, `InpSoloConHist` (def. true), `InpTF` (def. `PERIOD_D1`) | `inventario_simbolos.csv` (ver §7) |
| `ImportarTicksDuka.mq5` | Importa ticks de Dukascopy en CSV a un símbolo personalizado. Restricciones de seguridad declaradas: sólo crea símbolos con sufijo `_DUKA`, sólo lee de `MQL5/Files`, no toca símbolos reales del broker, no opera, no cambia la configuración del terminal. | `InpSimbolo` (`XAUUSD`), `InpSufijo` (`_DUKA`, obligatorio y verificado), `InpArchivoCsv`, `InpBloqueTicks` (10 000) | Símbolo personalizado `<SÍMBOLO>_DUKA` |
| `VerificarTicksDuka.mq5` | Verifica que el símbolo importado tiene ticks y muestra estadísticas en el Diario. | `InpSimbolo` (`XAUUSD_DUKA`), `InpDias` (5) | Sólo log |

### 6.4 `<RAÍZ>/GM_Deploy.mq5` y los lanzadores

`GM_Deploy.mq5` resuelve el símbolo (vacío = el del gráfico donde se suelta el script), abre
gráficos y les aplica plantillas sin duplicar los que ya existen (`SkipExisting`), y opcionalmente
lanza el stack Python. **Importa `shell32.dll`**, así que al ejecutarlo hay que marcar "Permitir
importar DLL". Interruptores: `DeployMacroLiquidity` (true), `MacroExclusive` (true, no añade otros
motores de entrada), `DeployGuardian` (true), `DeployPullback` (true), `DeployStructure` (false),
`DeployScalper` (false, "2º motor de entradas, más riesgo"), `DeploySignals` (true),
`LaunchDashboard` (true → `http://127.0.0.1:8766`).

Cadena de arranque real:

```
INICIAR.bat
 ├─ abre terminal64.exe con /config:gm_iniciar.ini  (si no está abierto; espera 30 s)
 └─ GM_START_ALL.bat
     └─ powershell INICIAR_OBSERVATORIO.ps1 -OpenBrowser
         ├─ python gm_check_binding.py      verifica la carpeta de MT5; aborta si no coincide
         ├─ python gm_rules_bridge.py       exporta el snapshot de reglas para MT5
         ├─ python gm_market_service.py     observador (si market_snapshot.json no está fresco)
         └─ python -m web --port 8766       replay + dashboard web
```

Variables usadas por los lanzadores: `GM_PYTHON` (intérprete; el valor por defecto del `.ps1` apunta
a `D:/ENTRENADOR/ldz_trading_terminal/.venv/Scripts/python.exe`), `GM_TERMINAL_PATH` (def.
`C:/Program Files/MetaTrader 5/terminal64.exe`).

Puertos locales (todos en 127.0.0.1): **8050** dashboard Dash, **8766** replay/observatorio según el
`.ps1` (**8000** si se arranca `python -m web` sin `--port`), **8777** `gm_live_api` según su README.

`GM_START_SERVICE.bat` arranca sólo `gm_service.py` con `GM_SYMBOL=XAUUSDmicro`,
`PYTHONIOENCODING=utf-8` y `C:\Python312\python.exe`. `GM_STOP_ALL.bat` arranca `gm_stop.py`.

---

## 7. CONTRATO DE FICHEROS DEL PUENTE

Esta sección documenta los ficheros por los que MT5 y Python se comunican. **Es la parte crítica
del documento**: antes no estaba escrita en ningún sitio y cualquier cambio de nombre de clave rompe
el sistema en silencio (los lectores MQL5 ignoran las claves que no conocen).

### 7.1 Dónde viven

Hay **tres** ubicaciones distintas y conviene no confundirlas:

| Ubicación | Cómo la ve MQL5 | Cómo la ve Python | Qué guarda |
|---|---|---|---|
| **Sandbox común** `<COMMON>` | `FileOpen("GoldMaster\\...", ...\|FILE_COMMON)` | `os.path.join(os.environ["APPDATA"], "MetaQuotes","Terminal","Common","Files","GoldMaster")` (`gm_intel.GM_DIR`); configurable con `GM_BRIDGE_DIR` en `gm_live_api` | El puente en vivo: `intel.txt`, `commands.csv`, `ea_state.txt`, `micro.json`, `guardian.txt`, `news_calendar.csv`, `alerts.csv`, `autonomous.json`, `override.json`, `service_heartbeat.txt`, `intel.json`, `inventario_simbolos.csv`, exports de histórico |
| **Sandbox del terminal** `<BASE>/Files/GoldMaster/` | `FileOpen("GoldMaster\\...", ...)` **sin** `FILE_COMMON` | `Path(__file__).parents[2] / 'Files' / 'GoldMaster'` en `gm_rules_bridge.py` | `rules_db.json` (snapshot para `GOLD_ADAPTIVE_EA` con `RulesUseCommon=false`), `ml_predictions.csv`, `ml_features.csv` |
| **Runtime local** `<RAÍZ>/python/runtime/` | — | `HERE / "runtime"` | Estado de los servicios Python, no del puente: `rules_db.json` (origen), `hypotheses.json`, `market_snapshot.json`, pids, logs, `candidates/`, `datasets/` |

Atención al detalle de `FILE_COMMON`: `CGMLBridge` (`GoldMaster_ML.mqh:64` y `:239`) y
`CGMNewsFilter` (`GoldMaster_Core.mqh:147`) abren **sin** `FILE_COMMON`, es decir en
`<BASE>/Files/GoldMaster/`; en cambio `CGMBridge`, `CGMGuardian` y el lector de `signal_params.txt`
**sí** usan `FILE_COMMON`. Los escritores Python de `intel.txt`, `micro.json`, `guardian.txt`,
`news_calendar.csv` apuntan al **común**. Por tanto `news_calendar.csv` lo escribe `gm_intel.py` en
el común pero `CGMNewsFilter` lo busca en el sandbox del terminal: **hay que copiarlo o enlazarlo**,
o pasar una ruta por el input del EA. Esto no está resuelto en el código.

### 7.2 `intel.txt` — Python → EA

- **Escribe:** `python/gm_intel.py` → `IntelEngine.write_intel()` (`gm_intel.py:516`). Escritura
  atómica: escribe `intel.tmp` y hace `os.replace`. Codificación ASCII, errores ignorados. Formato
  `clave=valor` una por línea; en el valor se sustituyen `=` y saltos de línea por espacios.
  Volcado paralelo a `intel.json` (mismo contenido, JSON).
- **Lee:** `CGMBridge::ReadIntel()` (`GoldMaster_Bridge.mqh:49`), y a través de él
  `GOLD_MASTER_PULLBACK_EA`, `GOLD_MASTER_SCALPER_EA`, `GOLD_MASTER_EA_v3`,
  `GOLD_MASTER_GLOBAL_EA`, `GOLD_MASTER_SCALPER_V3_VOLATILE`, `GOLD_MASTER_GUARDIAN_EA`.
  También `python/live/gm_live_api.py` y `python/gm_pro_chart.py` (vía `intel.json`).
- **Validez:** el EA sólo lo considera válido si `ts > 0`, la edad está entre −2 s y `max_age_s`
  (def. 120) **y** `symbol == _Symbol`. En el tester se ignora por completo.

Campos que el parser MQL5 reconoce (los demás se descartan silenciosamente):

| Clave | Tipo | Significado |
|---|---|---|
| `ts` | entero (epoch UTC) | marca de tiempo del snapshot |
| `symbol` | texto | símbolo al que corresponde; debe coincidir con `_Symbol` |
| `sentiment` | −1..+1 | sentimiento de titulares mapeado a "qué significa para el oro" |
| `cot_index` | 0..100 | percentil COT a 3 años (Managed Money, Gold COMEX 088691) |
| `cot_bias` | −1..+1 | sesgo del posicionamiento de fondos |
| `delta_z` | z-score | delta por tick-rule normalizado |
| `vpin` | 0..1 | VPIN (Easley/López de Prado/O'Hara, BVC) |
| `whale_bias` | −1..+1 | proxy de absorción/volumen anómalo |
| `flow_bias` | −1..+1 | sesgo agregado de order flow |
| `vwap` | precio | VWAP diario |
| `vwap_z` | z-score | distancia del precio al VWAP en σ |
| `poc`, `vah`, `val` | precio | volume profile: point of control, value area high/low |
| `hurst` | 0..1 | exponente de Hurst |
| `regime` | texto | `TREND` si Hurst > 0.55, `MEANREV` si < 0.45, `RANDOM` en medio |
| `composite` | −1..+1 | score compuesto (pesos declarados: sent 0.20, cot 0.10, flow 0.30, struct 0.20, dxy 0.20) |
| `risk_mult` | 0..1 | multiplicador de riesgo; el EA lo acota a [0,1] y lo usa como 0 si la intel no es válida |
| `block_trading` | 0/1 | 1 = no abrir operaciones |
| `next_news` | texto | nombre del próximo evento de alto impacto |
| `next_news_secs` | entero | segundos hasta ese evento; −1 si no hay |
| `dxy`, `dxy_chg24`, `dxy_corr` | número | valor del DXY, cambio 24 h, correlación con el oro |
| `dxy_bias` | −1/0/+1 | sesgo del dólar |
| `auto_trade` | 0/1 | copiado de `autonomous.json`; los EAs con `RequireAutonomous` no abren si es 0 |
| `override` | 0/1 | copiado de `override.json`: modo "sin filtros" |
| `dxy_shock` | −1/0/+1 | de `micro.json`; sólo distinto de 0 si \|z60\| > 2.5 **y** \|corr medida\| ≥ 0.3 |
| `micro_bias` | −1..+1 | sesgo micro combinado de `micro.json` |
| `gov_block` | 0/1 | bloqueo del gobernador de riesgo de cartera (`gm_quant`) |
| `port_risk_pct` | % | riesgo abierto total de todas las posiciones XAU |
| `vol_fcst` | % | pronóstico de volatilidad (GARCH o EWMA) |
| `macro_bias` | −1..+1 | sesgo macro intermercado |
| `hour_edge_z` | z-score | estacionalidad intradía de la hora actual |
| `regime_q` | texto | régimen cuantitativo (los EAs comparan contra `"RANGE"` y `"HIGH_VOL"`) |

Reglas de seguridad implementadas en el escritor (`gm_intel.py:490`–`512`):

- Si `spread_z > 4`, `risk_mult` se limita a 0.5 como máximo.
- Si `market_valid` es 0 en `micro.json`, `block_trading` pasa a 1.
- Si el modo "sin filtros" está activo (`override.json`), se fuerza `block_trading=0`, `gov_block=0`,
  `dxy_shock=0`, `risk_mult=1.0`, `override=1`.
- **Pero** si `micro.json` tiene más de 5 s o `market_valid` es 0, se fuerza después
  `block_trading=1`, `risk_mult=0.0`, `auto_trade=0`. El comentario del código lo dice explícito:
  un feed obsoleto no se puede desbloquear con el override de la interfaz.

Campos adicionales que el escritor emite y que el parser MQL5 **no** lee (los consumen el dashboard
y `gm_live_api`): `sent_n`, `cot_mm_net`, `cot_mm_chg`, `cot_date`, `dxy_live`, `dxy_z60`,
`dxy_beta`, `dxy_corr_live`, `dxy_lead_s`, `gold_exp_move`, `micro_trend`, `ofi_60`, `spread_z`,
`tick_z`, `g_z60`, `risk_mult_q`.

### 7.3 `commands.csv` — Python → EA

- **Escribe:** `python/gm_intel.py` → `Bridge.send_command()` (`gm_intel.py:527`), en modo
  **append**, ASCII.
- **Lee:** `CGMBridge::ReadCommands()` / `PollNew()` (`GoldMaster_Bridge.mqh:104`).
- **Formato:** CSV sin cabecera, separador `,`, cuatro campos: `id,cmd,arg1,arg2`.
- **Campos:** `id` es un contador creciente; el EA ignora `id <= 0` y, en `Init()`, arranca desde el
  último id existente para no reejecutar comandos viejos. Lee como máximo 5000 líneas por pasada.
- **Comandos documentados:** `PAUSE`, `RESUME`, `CLOSE_ALL`, `CANCEL_PENDING`, `SET_RISK <pct>`,
  `SET_MINSCORE <n>`. `CGMBridge` procesa por sí mismo `PAUSE` y `RESUME` (cambian `IsPaused()`); el
  resto los devuelve al EA, que decide.
- **Nota:** el fichero sólo crece; nada en el código lo rota ni lo trunca.

### 7.4 `ea_state.txt` — EA → Python

- **Escribe:** `CGMBridge::WriteState(status, positions, pending, bull, bear)`
  (`GoldMaster_Bridge.mqh:134`), con `FILE_WRITE` (sobrescribe) y `FILE_SHARE_READ`.
- **Lee:** `Bridge.read_ea_state()` (`gm_intel.py:534`), `python/live/gm_live_api.py`,
  `python/gm_pro_chart.py:156`.
- **Formato:** `clave=valor`, una por línea.

| Clave | Contenido |
|---|---|
| `ts` | `TimeGMT()` en el momento de escribir |
| `status` | `PAUSED` si el puente está pausado, si no el texto que pase el EA |
| `positions` | número de posiciones que reporta el EA |
| `pending` | número de órdenes pendientes |
| `equity` | `ACCOUNT_EQUITY` con 2 decimales |
| `bull_score` / `bear_score` | puntuaciones alcista/bajista que pase el EA |
| `last_cmd` | último `id` de `commands.csv` procesado |
| `intel_valid` | `1`/`0` según si la intel que tiene cargada es válida |

El lector Python añade dos campos calculados: `age_s` (= ahora − `ts`) y `alive` (= `age_s < 90`).
Si el fichero no existe o falla el parseo devuelve `{"alive": False, "age_s": -1}`.

### 7.5 `micro.json` — Python → Python (y a `intel.txt`)

- **Escribe:** `python/gm_micro.py` → `MicroMonitor.run()` (`gm_micro.py:143`), una vez por segundo.
  Escritura atómica vía `micro.tmp` + `os.replace`, con hasta 5 reintentos de 50 ms porque en Windows
  el dashboard puede tener el fichero abierto.
- **Lee:** `gm_intel.py` (fusiona un subconjunto en `intel.txt`), `gm_control.py:92`,
  `gm_supervisor.py` (detecta congelación > 60 s), `gm_pro_chart.py`, `gm_live_api.py`.
- **Ningún EA lo lee directamente.**

Claves (todas del dict `st` en `gm_micro.py:84`–`131`):

| Clave | Significado |
|---|---|
| `micro_ts` | epoch del ciclo |
| `market_valid` | 1 si hay cotización fresca y válida; 0 con `status: "stale_quote"` |
| `dxy_valid` | 1 si el DXY es finito |
| `dxy_source` | nombre del símbolo directo, o `"synthetic_6_pairs"` |
| `gold_mid` | precio medio (bid+ask)/2 |
| `dxy_live` | valor del DXY calculado este segundo |
| `g_z10`, `g_z60` | z-score del log-precio del oro a 10 s y 60 s |
| `tick_z` | z-score del número de ticks del último segundo (sólo con > 60 muestras) |
| `spread_z` | z-score del spread (sólo con > 60 muestras) |
| `ofi_60` | suma del order flow imbalance de los últimos 60 s |
| `micro_trend` | (EWMA 5 s − EWMA 60 s) × 1e4, sólo con > 60 muestras |
| `dxy_z10`, `dxy_z60` | z-score del DXY a 10 s y 60 s |
| `dxy_beta` | beta oro↔DXY sobre retornos de 5 s, ventana ≤ 360 muestras |
| `dxy_corr_live` | correlación oro↔DXY en la misma ventana |
| `dxy_lead_s`, `dxy_lead_corr` | desfase (0/5/10/15 s) de máxima correlación cruzada y su valor |
| `gold_exp_move` | movimiento esperado del oro en dólares = `dxy_beta × Δln(DXY 60 s) × mid` |
| `dxy_shock` | −1/0/+1; distinto de 0 sólo si \|`dxy_z60`\| > 2.5 **y** \|`dxy_corr_live`\| ≥ 0.3 |
| `micro_bias` | `clip(0.4·tanh(g_z60/2) + 0.3·tanh(ofi_60/40) + 0.3·dxy_shock, −1, 1)` |

### 7.6 `news_calendar.csv` — Python → EA

- **Escribe:** `python/gm_intel.py` → `NewsCalendar.export_csv()` (`gm_intel.py:109`), con
  `FILE_WRITE` (sobrescribe), ASCII. Fuente: `nfs.faireconomy.media/ff_calendar_thisweek.json` y
  `..._nextweek.json`.
- **Lee:** `CGMNewsFilter::LoadCSV()` (`GoldMaster_Core.mqh:147`). Recarga si han pasado más de
  6 horas; lee como máximo 500 filas. Si el fichero no existe, avisa una sola vez y desactiva el
  filtro ("en backtest es normal").
- **Formato:** CSV sin cabecera, separador `,`, **5 columnas en UTC**:

| # | Columna | Formato | Nota |
|---|---|---|---|
| 1 | fecha | `YYYY.MM.DD` | |
| 2 | hora | `HH:MM` | |
| 3 | nombre | texto | las comas del título se reemplazan por espacios en el escritor |
| 4 | moneda | `USD`, `XAU`, `CNY`, `EUR` | el escritor sólo emite estas |
| 5 | impacto | `3`=High, `2`=Medium, `1`=Low, `0`=Holiday | |

- **Uso en el EA:** `IsNewsTime(freeze_min=30, min_impact=3, currencies="USD,XAU")`.
- **Discrepancia de ubicación:** ver §7.1. El escritor usa el común, el lector el sandbox del
  terminal.

### 7.7 `ml_features.csv` — EA → Python

- **Escribe:** `CGMLBridge::WriteFeatures()` (`GoldMaster_ML.mqh:238`), con `FILE_WRITE` (sobrescribe,
  siempre **una sola fila** más la cabecera).
- **Lee:** `python/offline/gm_bridge.py` → `read_features()` en el bucle `serve`.
- **Cabecera exacta:** `timestamp,symbol,close,atr,ema21,ema50,ema200,trend,dxy_bias,session,confluence`
- **Campos:** `timestamp` con `TimeToString(TIME_DATE|TIME_SECONDS)`; `trend` −1/0/+1;
  `dxy_bias` 1 = dólar subiendo, −1 = bajando, 0 = neutro; `session` 0=Asia, 1=Londres, 2=NY;
  `confluence` el score entero del EA.

### 7.8 `ml_predictions.csv` — Python → EA

- **Escribe:** `python/offline/gm_bridge.py` → `write_predictions()` (`serve`). Timestamp en formato
  MT5 `YYYY.MM.DD HH:MM:SS` para que `StringToTime` del EA lo entienda.
- **Lee:** `CGMLBridge::ReadCSV()` (`GoldMaster_ML.mqh:63`). Salta la primera fila (cabecera), lee
  como máximo 1000 filas y se queda con la de `timestamp` más alto. La predicción es válida si
  `TimeCurrent() - timestamp <= m_max_age_s` (def. **300 s**).
- **Cabecera exacta:**
  `timestamp,signal,confidence_lstm,confidence_xgb,confidence_lgbm,ensemble_signal,ensemble_confidence,price_target,regime`

| Columna | Tipo | Significado |
|---|---|---|
| `timestamp` | `YYYY.MM.DD HH:MM:SS` | cuándo se generó |
| `signal` | 1/−1/0 | compra / venta / neutral |
| `confidence_lstm` | 0..1 | **en realidad** regresión logística (mapa declarado en `gm_bridge.py`) |
| `confidence_xgb` | 0..1 | **en realidad** HistGradientBoosting |
| `confidence_lgbm` | 0..1 | **en realidad** RandomForest |
| `ensemble_signal` | 1/−1/0 | voto del ensemble |
| `ensemble_confidence` | 0..1 | media de las tres confianzas |
| `price_target` | precio | objetivo predicho |
| `regime` | texto | `trending` / `ranging` / `volatile` (del HMM de `gm_ml`) |

- **Filtros del lado EA:** confianza mínima 0.60 y al menos 2 de 3 modelos de acuerdo
  (`m_min_confidence`, `m_min_model_votes`), reconfigurables por `Init()`.
- **Ejemplo real de la cabecera del .mqh:**
  `2024.01.15 14:30:00,1,0.72,0.68,0.75,1,0.717,2045.50,trending`

### 7.9 `guardian.txt` — Python → EA

- **Escribe:** `python/live/gm_guardian.py` → `RiskGovernor.export_limits(bridge_dir)`
  (`gm_guardian.py:86`), UTF-8, sobrescribe.
- **Lee:** `CGMGuardian::SyncFromBridge()` (`GoldMaster_Guardian.mqh:67`), que se llama desde
  `CanTrade()` sólo si **no** se está en el tester. Si falta el fichero o la clave, se queda con el
  valor por defecto del EA.
- **Formato:** `clave=valor`. **Sólo tres claves**:

| Clave | Por defecto en el EA | Por defecto en Python | Significado |
|---|---|---|---|
| `news_blackout_min` | 30 | 30 | minutos antes/después de una noticia de alto impacto en que no se opera |
| `max_spread_points` | 600 | 60.0 | spread máximo admitido, en puntos |
| `max_risk_frac` | 0.5 | 0.5 | si ni el lote mínimo arriesga menos que esta fracción del equity, se bloquea |

- **Discrepancia observada:** el valor por defecto de `max_spread_points` es 600 en
  `GoldMaster_Guardian.mqh:59` y 60.0 en `GuardianConfig` de `gm_guardian.py`. Si `guardian.txt`
  existe gana el de Python (10× más estricto); si no existe, gana el del EA. No está claro cuál es
  el deseado: **sin determinar**.
- **Lo que NO se sincroniza:** la escalera de capital (`stages`), `block_regimes` y
  `min_pretrade_score` existen en Python pero **no** se exportan; la escalera está duplicada a mano
  en `GoldMaster_Guardian.mqh:56`–`58` y debe mantenerse sincronizada con `gm_capital.DEFAULT_STAGES`
  manualmente. La razón de que la lógica viva en dos sitios y el criterio con el que bloquea están
  en [`DOCTRINA_RIESGO.md`](DOCTRINA_RIESGO.md) (secciones «Los bloqueos» y «Doble implementación,
  un solo criterio»); este documento sólo describe el canal por el que viajan los tres parámetros.

### 7.10 `rules_db.json` — Python → EA

- **Origen:** `python/gm_rules_db.py` escribe `<RAÍZ>/python/runtime/rules_db.json` (documento
  completo con historial).
- **Exporta:** `python/gm_rules_bridge.py` → `export_snapshot()`, escritura atómica (`.tmp` +
  `replace`) a `<BASE>/Files/GoldMaster/rules_db.json`, con `allow_nan=False`. Devuelve el sha256 del
  resultado.
- **Lee:** `GOLD_ADAPTIVE_EA.mq5` → `LoadRulesFromJSON()` con un parser manual de cadenas (no un
  parser JSON). Rutas: input `RulesDBPath` (def. `GoldMaster\rules_db.json`) y
  `RulesUseCommon=false` → sandbox del terminal. Recarga cada `RuleReloadMins` (def. 15), y registra
  también los intentos fallidos para no reintentar en cada tick.
  El EA declara además `#property tester_file "GoldMaster\\rules_db.json"` para que el fichero viaje
  al backtest.
- **También lo lee** `replay_terminal/web/dashboard_api.py` (desde `python/runtime/`).

Esquema del **snapshot exportado** (plano, con `name` primero porque así lo recorre el lector MQL5):

| Campo | Nivel | Contenido |
|---|---|---|
| `version` | raíz | `2` |
| `generated_at` | raíz | epoch de la exportación |
| `execution` | raíz | literal `"disabled"` |
| `rules` | raíz | lista de reglas aceptadas |
| `rejected_rules` | raíz | lista de **nombres** de las reglas rechazadas |
| `name` | regla | identificador |
| `active`, `validated` | regla | siempre `true` en el snapshot |
| `test_only` | regla | siempre `false` |
| `asset` | regla | símbolo; el EA exige `== _Symbol` |
| `tf` | regla | el exportador y el EA exigen `"M15"` |
| `implementation` | regla | el exportador y el EA exigen `"EMA_CROSS_M15_H1"` |
| `score` | regla | 0..1; el EA exige `>= MinRuleScore` (def. 0.60) |
| `evidence_trades` | regla | entero; ambos lados exigen `>= 30` |
| `validated_at` | regla | epoch; ambos exigen `> 0` y `<= ahora` |
| `win_rate`, `profit_factor`, `expectancy_r` | regla | finitos; el exportador exige `expectancy_r > 0` |

Criterios de elegibilidad **adicionales** que aplica `gm_rules_bridge.py` sobre el documento origen
y que no viajan en el snapshot: `document['test_only'] is not True`,
`validation.costs_calibrated is True`, `validation.pristine_holdout is True` y
`validation.report_sha256` no vacío.

### 7.11 `inventario_simbolos.csv` — MT5 → Python/humano

- **Escribe:** `<BASE>/Scripts/DATOS/GM_InventarioSimbolos.mq5:43`, en `GoldMaster\` con
  `FILE_COMMON`, separador `,`. Crea la carpeta si falta (`FolderCreate` con `FILE_COMMON`).
- **Lee:** nadie en el repositorio lo consume programáticamente. Es un informe para decidir qué
  símbolos usar.
- **Cabecera exacta (20 columnas, `GM_InventarioSimbolos.mq5:50`):**
  `symbol, descripcion, path, visible, digits, point, spread_actual, spread_flotante, vol_min,
  vol_step, vol_max, contract_size, tick_value, moneda_beneficio, modo_calculo, barras_disponibles,
  primera_fecha, ultima_fecha, anos_historia, sesiones_cotiza`
- **Fila de datos** (`GM_InventarioSimbolos.mq5:117`), 20 valores en el mismo orden:
  nombre del símbolo, `SYMBOL_DESCRIPTION`, `SYMBOL_PATH`, `SYMBOL_VISIBLE`, `SYMBOL_DIGITS`,
  `SYMBOL_POINT` (8 decimales), `SYMBOL_SPREAD`, `SYMBOL_SPREAD_FLOAT`, `SYMBOL_VOLUME_MIN` (4 dec.),
  `SYMBOL_VOLUME_STEP` (4 dec.), `SYMBOL_VOLUME_MAX` (2 dec.), `SYMBOL_TRADE_CONTRACT_SIZE` (2 dec.),
  `SYMBOL_TRADE_TICK_VALUE` (6 dec.), `SYMBOL_CURRENCY_PROFIT`,
  `EnumToString(SYMBOL_TRADE_CALC_MODE)`, barras disponibles en `InpTF`, primera y última fecha
  (`TIME_DATE`, vacías si no hay historia), años de historia (2 dec.) y número de sesiones de
  cotización del lunes (`SymbolInfoSessionQuote`, hasta 8; es la pista de si el símbolo es sintético
  24/7).

### 7.12 Ficheros de control de la interfaz

| Fichero | Escribe | Lee | Contenido |
|---|---|---|---|
| `autonomous.json` | `gm_control.set_auto()` (`gm_control.py:21`) | `gm_control.auto_on()`, `gm_intel.py:498` → clave `auto_trade` de `intel.txt` | `{"on": bool, "ts": epoch}`. Con `on=false` los EAs que llevan `RequireAutonomous=true` gestionan lo abierto pero **no abren** nada |
| `override.json` | `gm_intel.set_override()` (`gm_intel.py:421`) | `gm_intel.override_on()`, `gm_control.py` | `{"on": bool, "ts": epoch}`. Modo "sin filtros": ignora bloqueo por noticias, gobernador de cartera, régimen y DXY shock. El SL y la gestión del Guardian siguen activos. Un feed obsoleto lo anula (§7.2) |
| `service_heartbeat.txt` | `gm_service.py:63` | `gm_control.py:89`, `gm_supervisor.py:39`, `gm_pro_chart.py:160` | JSON en una línea: `{"ts": epoch, "ok": bool}`. `gm_supervisor` reinicia el servicio si pasa de 120 s; `gm_control` lo pinta en rojo a partir de 60 s |
| `alerts.csv` | `gm_micro._alerts()` (`gm_micro.py:135`), modo append | `gm_pro_chart.py:78` (últimas 8 líneas) | `epoch,clave,mensaje` sin cabecera. Claves emitidas: `dxy` (DXY SHOCK), `gold` (\|g_z10\| > 3), `spread` (`spread_z` > 4). Enfriamiento: 120 s, 60 s y 300 s respectivamente |
| `intel.json` | `gm_intel.write_intel()` | `IntelEngine.follow()`, `gm_pro_chart.py`, `gm_live_api.py` | El mismo snapshot que `intel.txt`, en JSON. Permite que el dashboard siga al servicio sin duplicar cálculos ni escrituras |
| `drawings_<SÍMBOLO>.json`, `alerts_<SÍMBOLO>.json` | `gm_chart.py:165`, `:185` | `gm_chart.py` | Dibujos y alertas de precio del gráfico del dashboard, por símbolo |
| `<SÍMBOLO>_<TF>.csv` | `GM_ExportarHistorico.mq5` | `python/core/gm_data.py`, `offline/mt5_import.py` | Export de barras en el formato que esos importadores aceptan sin configuración |

### 7.13 Contratos declarados pero **sin escritor** en el repositorio

Esto es importante y no es un detalle menor: hay tres contratos que un componente **lee** y que
**nada en este repositorio escribe**.

1. **`gm_state.json`** — lo lee `CGMDXYFilter::_refresh()` (`GoldMaster_DXY_Filter.mqh:60`), y
   `GOLD_MASTER_GLOBAL_EA.mq5:81` lo declara como input `DXYStatePath` con el comentario «escrito por
   gm_bridge.py». **No existe ningún escritor**: `offline/gm_bridge.py` sólo escribe
   `ml_predictions.csv`. Campos que el filtro espera: `dxy`, `dxy_chg24`, `real_yield`, `ry_bias`,
   `dxy_mode` (texto), `dxy_bias`. Mientras no exista el fichero, `CGMDXYFilter` devuelve
   `m_bias = 0`, es decir el filtro DXY de `GOLD_MASTER_GLOBAL_EA` **no filtra nada** y la función
   degrada en silencio. Nota adicional: el `FileOpen` de la línea 60 va **sin** `FILE_COMMON`, luego
   lo busca en `<BASE>/Files/GoldMaster/`.

2. **`signal_params.txt`** — lo lee `GOLD_MASTER_PRO_Signals.mq5:124` (con `FILE_COMMON`) cuando
   `UseAutoParams=true`, con el comentario «parámetros re-entrenados por gm_service.py».
   `gm_pro_chart.py:91` y `:187` también lo leen. **No existe ningún escritor**: `gm_retrain.py`
   deja los candidatos en `python/runtime/candidates/` y su docstring dice expresamente que nunca
   reemplaza los parámetros que consumen los EAs. Claves que el indicador reconoce: `updated`
   (`True`/`False`; si no es `True` **no aplica nada**), `fast`, `slow`, `minscore`, `tp`, `slatr`,
   `oos_exp`. Sin fichero, el indicador usa sus valores por defecto
   (`fast=21, slow=89, minscore=3, tp=2, slatr=1.2`, info `"manual"`).

3. **`talos_signal.json`, `talos_prediccion.json`, `talos_sentimiento.json`** —
   `Experts/BRIDGE_PYTHON/TALOS_Bridge_JSON_MT5_Python.mq5` los lee de `Common\Files\` (ojo: en la
   raíz del común, **no** dentro de `GoldMaster\`) y escribe `talos_result.json` y
   `talos_estado.json`. Es un **espacio de nombres de puente distinto y paralelo** al de
   `GoldMaster\`. No hay ningún productor en el repositorio. Dado que ese EA **envía órdenes reales**
   según el contenido de esos ficheros, es también una bandera roja de riesgo; está documentada en
   `CATALOGO_EAS.md`.

### 7.14 Resumen de dirección y frescura

| Fichero | Dirección | Escritura | Caducidad que aplica el lector |
|---|---|---|---|
| `intel.txt` | Py → EA | atómica (`.tmp` + replace) | ≤ 120 s por defecto, y el símbolo debe coincidir |
| `intel.json` | Py → Py | sobrescribe | la que aplique el consumidor |
| `commands.csv` | Py → EA | **append** (crece sin límite) | por `id`, no por tiempo |
| `ea_state.txt` | EA → Py | sobrescribe | `alive` si < 90 s |
| `micro.json` | Py → Py | atómica con reintentos | `gm_intel` exige ≤ 5 s; `gm_supervisor` reinicia a > 60 s |
| `guardian.txt` | Py → EA | sobrescribe | sin caducidad; se relee en cada `CanTrade()` |
| `news_calendar.csv` | Py → EA | sobrescribe | recarga cada 6 h |
| `ml_features.csv` | EA → Py | sobrescribe (1 fila) | el servidor sondea cada `--interval` (def. 5 s) |
| `ml_predictions.csv` | Py → EA | append/sobrescribe según uso | ≤ 300 s |
| `rules_db.json` | Py → EA | atómica | recarga cada 15 min |
| `autonomous.json` / `override.json` | UI → Py → EA | sobrescribe | sin caducidad propia; viajan en `intel.txt` |
| `service_heartbeat.txt` | Py → Py | sobrescribe | 60 s (aviso) / 120 s (reinicio) |
| `alerts.csv` | Py → Py | **append** | se leen las últimas 8 líneas |
| `inventario_simbolos.csv` | MT5 → humano | sobrescribe | — |
| `gm_state.json` | — → EA | **sin escritor** | 60 s |
| `signal_params.txt` | — → indicador | **sin escritor** | relee cada 300 s |
| `talos_*.json` | — → EA | **sin escritor** | sondeo cada `InpPollMs` (1000 ms) |

---

## 8. Qué leer primero si llegas nuevo

1. [`../README.md`](../README.md) y [`HALLAZGOS.md`](HALLAZGOS.md), para saber **qué está medido y
   qué no** antes de tocar código. Evita reconstruir conclusiones que ya se contrastaron.
2. Este documento, §7 (el contrato de ficheros) — es lo que no se deduce leyendo un fichero suelto.
3. `<BASE>/Include/GoldMaster/GoldMaster_Core.mqh`, en particular `GM_CalcLot()` en la línea 549,
   junto con [`DOCTRINA_RIESGO.md`](DOCTRINA_RIESGO.md).
4. `<BASE>/Include/GoldMaster/GoldMaster_Bridge.mqh` completo: son 166 líneas y define medio sistema.
5. `<RAÍZ>/python/gm_service.py` (70 líneas): es el bucle de producción entero.
6. `<RAÍZ>/replay_terminal/core/models.py` para la convención temporal, y
   `replay_terminal/tests/test_no_lookahead.py` para entender qué garantía da el motor SMC.
7. [`CATALOGO_EAS.md`](CATALOGO_EAS.md) antes de poner cualquier EA en una cuenta real.
