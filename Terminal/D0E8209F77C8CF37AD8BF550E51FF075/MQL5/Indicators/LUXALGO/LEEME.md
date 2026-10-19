# Indicadores LuxAlgo portados a MQL5

Dos indicadores de **LuxAlgo**, originalmente en Pine Script v5, portados a MQL5
para poder usarlos en MetaTrader.

| Fichero | Original |
|---|---|
| `LuxAlgo_SmartMoneyConcepts.mq5` | *Smart Money Concepts [LuxAlgo]* |
| `LuxAlgo_OrderBlocks_Breakers.mq5` | *Order Blocks & Breaker Blocks [LuxAlgo]* |

## Licencia — léelo antes de usarlos

Obra original **© LuxAlgo**, bajo
[**CC BY-NC-SA 4.0**](https://creativecommons.org/licenses/by-nc-sa/4.0/).

Estos ports son **obras derivadas** y heredan exactamente la misma licencia:

- **Atribución** — hay que mantener el crédito a LuxAlgo. Está en la cabecera
  de cada `.mq5`; no la borres.
- **NoComercial** — ⚠️ **no se pueden usar con fines comerciales.** Vender,
  alquilar o comercializar un EA, un servicio o un curso construido sobre esto
  incumple la licencia. Para uso personal, sin problema.
- **CompartirIgual** — si los redistribuyes (modificados o no), tienen que ir
  con esta misma licencia.

## Qué se portó y qué no

**Portado íntegro:** estructura interna y de swing (BOS / CHoCH), order blocks
internos y de swing con su mitigación, EQH/EQL, fair value gaps, máximos y
mínimos fuertes/débiles, zonas de premium/descuento, y niveles del día, semana
y mes anteriores. Order blocks con breakers, su conversión de polaridad y las
etiquetas de cambio.

**No portado**, y conviene saberlo:

- *Coloreado de velas por tendencia.* El `plotcandle` de Pine no tiene
  equivalente directo en MQL5 sin sobreponer un indicador de velas completo.
- *Modo MONOCHROME.* Es puramente estético; se puede conseguir poniendo los
  mismos colores a mano en las entradas.
- *Transparencia real.* MQL5 no admite canal alfa en los objetos estándar del
  gráfico. Se aproxima mandando los rectángulos al fondo (`OBJPROP_BACK`), que
  es lo más parecido.

## Diferencia de rendimiento respecto al Pine

El Pine recalcula en cada tick. Estos ports **recalculan una vez por barra**
(hay una guarda `s_lastBar` en `OnCalculate`). La estructura solo puede cambiar
cuando cierra una vela, así que el resultado es el mismo y el terminal no se
arrastra: borrar y redibujar cientos de objetos en cada tick es carísimo.

## Lo que este sistema midió sobre los order blocks

Antes de operar con esto, conviene saber lo que dice la evidencia recogida en
[`docs/HALLAZGOS.md`](../../Scripts/GOLD_MASTER_SYSTEM/docs/HALLAZGOS.md),
medido sobre 21 años de oro real (122.027 velas H1):

| Prueba | Resultado |
|---|---|
| 486 estrategias de order block, train/test | mejor +0,379R, **t = 1,51** (no significativo) |
| Contraste de realidad de White | **p = 0,835** |
| Test nulo sintético (84 caminos sin estructura institucional) | **el 96,4 % superó el mejor resultado real** |
| Clasificador con 15 variables de contexto | **AUC 0,426** (por debajo del azar) |

Es decir: como **herramienta visual** para leer el gráfico y mantener un marco
de análisis coherente, perfecto. Como **generador de señales de entrada**, la
evidencia dice que no aporta ventaja. No es una crítica a LuxAlgo — es lo que
pasa con los order blocks en general, medido con un protocolo serio.

## Instalación

1. Copia los `.mq5` a `MQL5\Indicators\LUXALGO\` de tu terminal.
2. Abre MetaEditor (F4 desde MT5), abre cada fichero y pulsa **Compilar** (F7).
3. En MT5, actualiza el Navegador y arrastra el indicador al gráfico.

Si al compilar sale algún error, pásamelo: estos ports se escribieron sin
compilador MQL5 disponible, así que la sintaxis no está verificada por el
compilador, solo revisada a mano.
