# GOLD MASTER — subsistema offline (sin MetaTrader5)

Investigación y puente ML con datos exportados de MT5, ejecutable en Linux/CI o en
cualquier Python con `pandas`. **No** usa la librería `MetaTrader5` (solo Windows) y
**no** despliega parámetros a ningún EA por sí mismo: todo es investigación.

## Instalación

```bash
pip install -r ../requirements.txt     # numpy pandas scikit-learn arch hmmlearn ...
pip install hmmlearn scipy pytest       # si no están ya
```

## Módulos

| Fichero | Qué hace |
|---|---|
| `mt5_import.py` | Importa exports de barras de MT5 (CSV/TSV/Excel, con o sin columna de hora, CRLF, con/sin `<corchetes>`) → DataFrame canónico `time,open,high,low,close,tickvol,volume,spread`. `resample()` reagrega M1 a cualquier temporalidad sin look-ahead. |
| `gm_offline.py` | Backtest de la estrategia PRO Signals M1 (reutiliza `gm_optimizer`), split train/test cronológico con purga, métricas en USD, Monte Carlo bootstrap y meta-labeling. |
| `gm_ml.py` | Capa ML: régimen de mercado (HMM 3 estados) + meta-labeling con walk-forward purgado + modelo lineal exportable a MQL5. |
| `gm_bridge.py` | **Puente ML EA⇄Python** (cierra el "ddl"): entrena 3 clasificadores sobre tus datos y sirve `ml_predictions.csv` con el contrato exacto de `GoldMaster_ML.mqh`. |

## Uso rápido

```bash
# 1) Backtest sobre tu M1 real
python gm_offline.py  XAUUSD_M1.csv

# 2) Capa ML (régimen + meta-labeling walk-forward)
python gm_ml.py       XAUUSD_M1.csv

# 3) Entrenar el puente y servir predicciones al EA
python gm_bridge.py train  XAUUSD_M1.csv
python gm_bridge.py serve  --dir "<ruta>/MQL5/Files/GoldMaster" --interval 5
```

Todo escribe sus informes en `out_offline/` (ignorado por git; son datos, no fuentes).

## El puente de ficheros EA ⇄ Python (el "ddl")

No hace falta compilar ninguna DLL de C++ ni abrir puertos. MT5 y Python se comunican
por **ficheros** en la carpeta sandbox del terminal, que es como el sistema ya
intercambia `intel.txt`/`commands.csv`:

```
  EA (MQL5)                                   Python (gm_bridge.py serve)
  ─────────                                   ───────────────────────────
  GoldMaster_ML.mqh : WriteFeatures()  ─────►  ml_features.csv  ──► lee features
                                                                     predice (LR+GB+RF)
  CGMLBridge.ReadCSV() ◄──── ml_predictions.csv ◄──── escribe (atómico tmp+replace)
```

**Contrato** (lo valida `tests/test_bridge_offline.py`):

- EA → `ml_features.csv`: `timestamp,symbol,close,atr,ema21,ema50,ema200,trend,dxy_bias,session,confluence`
- Py → `ml_predictions.csv`: `timestamp,signal,confidence_lstm,confidence_xgb,confidence_lgbm,ensemble_signal,ensemble_confidence,price_target,regime`
  con `timestamp` en formato MT5 `YYYY.MM.DD HH:MM:SS`.

Las tres columnas de confianza las pueblan tres modelos reales
(logística → `lstm`, HistGradientBoosting → `xgb`, RandomForest → `lgbm`; `ensemble` = media).

**Ruta importante:** por defecto `CGMLBridge` lee de la carpeta local del terminal
(`MQL5/Files/GoldMaster/`), no de `Common/Files`. Apunta `--dir` de `serve` a esa misma
carpeta, o pásale a `CGMLBridge.Init()` la ruta que prefieras.

## Honestidad sobre los resultados

- Datos actuales: ~3,5 meses de M1 → suficiente para **construir y demostrar**, no para
  afirmar rentabilidad. Para validación seria hace falta M1 de varios años con walk-forward.
- La predicción direccional del puente tiene AUC fuera de muestra modesta (~0.55). El uso
  fuerte del ML es el **meta-labeling** de `gm_ml` (filtra señales de una estrategia ya
  existente), con AUC ~0.65 y mejora de esperanza clara, siempre con muestras pequeñas.
- Nada aquí promociona parámetros ni opera solo. La decisión final es del EA y del usuario.

## Tests

```bash
python -m pytest tests/ -q
```
