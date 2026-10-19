# GOLD MASTER SYSTEM

Laboratorio cuantitativo y estación de trabajo para oro (XAUUSD) sobre
MetaTrader 5, con investigación en Python.

---

## Lo primero, para no perder tu tiempo

Este sistema **no tiene una estrategia rentable demostrada**, y lo sabe porque lo
ha medido. Lo que tiene es el instrumental para no engañarse, que es lo que casi
ningún sistema casero tiene:

| Pregunta | Respuesta medida |
|---|---|
| ¿Predice la dirección del oro? | No. AUC 0,490 en muestra, 0,498 fuera. El azar. |
| ¿Funcionan los order blocks? | No se distingue de la suerte. White p = 0,847 sobre 486 variantes. |
| ¿Y comparados con datos sin estructura? | El 91,7 % de los caminos **sintéticos** dan mejor resultado que el oro real. |
| ¿Sirve de algo el DXY? | Señal real (4,09σ) pero **inestable**: dos años seguidos sin efecto. |
| ¿Puedo operar oro con 10 $ en micro? | **No.** El lote mínimo obliga a arriesgar >50 % por operación. |

Los números, el método y cómo reproducirlos: **[docs/HALLAZGOS.md](docs/HALLAZGOS.md)**.

Si buscas un sistema que prometa rentabilidad, este no es. Si buscas uno que te
diga la verdad sobre tu riesgo y te impida arruinarte, sigue leyendo.

## Qué sí hace

1. **Dimensiona honestamente.** Una ecuación estocástica de 4 capas calibrada
   sobre 21 años reales reproduce la estructura de riesgo del oro (volatilidad
   anual simulada 17,4 % vs 17,2 % real; ACF(|r|) 0,258 vs 0,269) y permite
   calcular probabilidad de ruina y distribución de drawdown.
   → [docs/ECUACION_ORO.md](docs/ECUACION_ORO.md)
2. **Te protege del lote mínimo.** El gobernador de riesgo bloquea la operación
   cuando ni el lote mínimo cabe en tu capital, en vez de dejarte operar al 50 %.
   → [docs/DOCTRINA_RIESGO.md](docs/DOCTRINA_RIESGO.md)
3. **Detecta el autoengaño.** Contraste de realidad de White, test nulo
   sintético, y un libro de pruebas múltiples que **endurece el umbral** conforme
   investigas: medido, pasó de p < 1,25e-02 a p < 1,02e-04 tras registrar 486
   pruebas.
4. **Replay y estudio.** Terminal de replay con gráficos tipo TradingView, SMC,
   DOM, noticias y cuenta en vivo.
5. **Recuerda.** Bóveda Obsidian donde cada experimento queda con su veredicto, y
   un agente crítico que publica las contradicciones y lo pendiente de revalidar.

## Arranque rápido

```bash
pip install -r python/requirements.txt

# 1. Exporta tu histórico desde TU MT5 (no uses un proxy: el spread y los
#    huecos de tu broker forman parte del resultado)
#    En MT5: ejecuta Scripts/DATOS/GM_InventarioSimbolos.mq5  → ve qué tienes
#            ejecuta Scripts/DATOS/GM_ExportarHistorico.mq5   → exporta a CSV

# 2. Calibra la ecuación y valida fuera de muestra
python python/model/gm_calibrate.py XAUUSD_H1.csv --split 0.75 --out out_model

# 3. Juzga las estrategias de order block (barrido + White + nulo sintético)
python python/smc/gm_ob_campaign.py XAUUSD_H1.csv \
    out_model/params_xauusd_h1.json --out out_campaign --null-paths 140

# 4. Panel en vivo + API (sirve las dos cosas en el mismo puerto)
python python/live/gm_live_api.py        # → http://127.0.0.1:8777

# 5. Terminal de replay
python replay_terminal/web/server.py

# 6. Ciclo de agentes; deja todo escrito en la bóveda Obsidian
python python/agents/gm_lab.py --vault ~/GoldMasterVault \
    --gold XAUUSD_H1.csv --dxy DXY_d1.csv
```

## Mapa

```
GOLD_MASTER_SYSTEM/
├── docs/                 documentación (empieza por HALLAZGOS.md)
├── python/
│   ├── core/             carga unificada de datos (MT5, CSV, Excel)
│   ├── model/            la ecuación maestra, calibración, DXY
│   ├── smc/              order blocks, estrategias, Monte Carlo
│   ├── agents/           agentes de investigación + bóveda Obsidian
│   ├── live/             API en vivo, gobernador de riesgo, panel
│   ├── offline/          laboratorio de backtest e investigación
│   └── optimizer/        optimización de parámetros
├── replay_terminal/      terminal de replay (motor, web, Qt)
└── assets/               plantillas de MT5
```

Fuera de esta carpeta: `Include/GoldMaster/` (librerías .mqh, incluido el
guardián dentro del EA), `Experts/` (los EAs, organizados por estrategia),
`Scripts/DATOS/` (inventario y exportación de símbolos).

- Arquitectura detallada y contrato del puente MT5↔Python →
  [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md)
- Catálogo de EAs con banderas de riesgo → [docs/CATALOGO_EAS.md](docs/CATALOGO_EAS.md)

## Reglas de la casa

1. **Nada se afirma sin medirlo.** Un resultado sin método declarado no entra en
   la documentación.
2. **Train/test siempre separados por fecha**, y sin solape.
3. **Todo barrido declara sus pruebas.** 486 especificaciones son 486 pruebas, no
   una. El umbral de significación se corrige por el total acumulado.
4. **El stop manda sobre el objetivo** cuando una barra toca los dos. Sin datos
   de ticks no se sabe el orden, y la alternativa optimista es cómo se fabrican
   backtests bonitos.
5. **Los costes se descuentan siempre.** Spread y deslizamiento, al entrar y al
   salir.
6. **El sistema no opera solo.** La capa en vivo informa y bloquea; no envía
   órdenes por iniciativa propia.
