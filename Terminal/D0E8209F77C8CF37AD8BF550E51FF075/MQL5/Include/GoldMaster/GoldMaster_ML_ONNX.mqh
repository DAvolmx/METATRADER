//+------------------------------------------------------------------+
//| GoldMaster_ML_ONNX.mqh                                          |
//| Capa de Machine Learning via ONNX Runtime nativo de MT5          |
//| Modelo: XGBoost → ONNX · Entrenado en GC=F 1h 2 años            |
//| Uso: #include y llamar a GM_ML_Predict() en OnTick               |
//+------------------------------------------------------------------+
#ifndef GOLDMASTER_ML_ONNX_MQH
#define GOLDMASTER_ML_ONNX_MQH

#include <GoldMaster/GoldMaster_Core.mqh>

// ─── Constantes del modelo ──────────────────────────────────────────
#define GM_ML_N_FEATURES   16
#define GM_ML_MODEL_FILE   "xau_signal_model.onnx"  // en MQL5/Files/
#define GM_ML_THRESHOLD    0.60                      // prob >= 0.60 → señal confirmada
#define GM_ML_DISABLED_PROB 0.5                      // retorno neutro si ONNX no disponible

// ─── Handles y estado ───────────────────────────────────────────────
static long   g_onnx_handle  = INVALID_HANDLE;
static bool   g_onnx_ready   = false;
static bool   g_onnx_tried   = false;   // para no intentar cargar en cada tick

//+------------------------------------------------------------------+
//| Inicializar el modelo ONNX (llamar una sola vez desde OnInit)     |
//+------------------------------------------------------------------+
bool GM_ML_Init(string modelFile = GM_ML_MODEL_FILE)
{
   if(g_onnx_tried) return g_onnx_ready;
   g_onnx_tried = true;

   // Verificar que existe el archivo
   if(!FileIsExist(modelFile, FILE_COMMON))
   {
      // Intentar en la carpeta de datos del EA
      if(!FileIsExist(modelFile))
      {
         Print("[GM_ML] Modelo ONNX no encontrado: ", modelFile, " · Filtro ML desactivado");
         g_onnx_ready = false;
         return false;
      }
   }

   // Cargar via OnnxCreate (MT5 >= build 3660)
   g_onnx_handle = OnnxCreate(modelFile, 0);
   if(g_onnx_handle == INVALID_HANDLE)
   {
      Print("[GM_ML] OnnxCreate falló (build ", TerminalInfoInteger(TERMINAL_BUILD),
            ") · Filtro ML desactivado. Error: ", GetLastError());
      g_onnx_ready = false;
      return false;
   }

   // Definir forma del tensor de entrada: [1, 16]
   ulong input_shape[]  = {1, GM_ML_N_FEATURES};
   ulong output_shape[] = {1, 2};   // 2 clases: [prob_sell, prob_buy]

   if(!OnnxSetInputShape(g_onnx_handle, 0, input_shape))
   {
      Print("[GM_ML] OnnxSetInputShape falló: ", GetLastError());
      OnnxRelease(g_onnx_handle);
      g_onnx_handle = INVALID_HANDLE;
      g_onnx_ready  = false;
      return false;
   }

   if(!OnnxSetOutputShape(g_onnx_handle, 0, output_shape))
   {
      Print("[GM_ML] OnnxSetOutputShape falló: ", GetLastError());
      OnnxRelease(g_onnx_handle);
      g_onnx_handle = INVALID_HANDLE;
      g_onnx_ready  = false;
      return false;
   }

   g_onnx_ready = true;
   Print("[GM_ML] Modelo ONNX cargado · ", modelFile,
         " · Threshold=", GM_ML_THRESHOLD,
         " · Features=", GM_ML_N_FEATURES);
   return true;
}

//+------------------------------------------------------------------+
//| Liberar handle ONNX (llamar desde OnDeinit)                      |
//+------------------------------------------------------------------+
void GM_ML_Deinit()
{
   if(g_onnx_handle != INVALID_HANDLE)
   {
      OnnxRelease(g_onnx_handle);
      g_onnx_handle = INVALID_HANDLE;
   }
   g_onnx_ready = false;
   g_onnx_tried = false;
}

//+------------------------------------------------------------------+
//| Calcular los 16 features para la barra actual                    |
//| Devuelve false si no hay suficiente historia                     |
//+------------------------------------------------------------------+
bool GM_ML_BuildFeatures(string sym, ENUM_TIMEFRAMES tf_h1,
                          int h_atr14, int h_ema8, int h_ema21,
                          float &features[])
{
   ArrayResize(features, GM_ML_N_FEATURES);

   // Pedir historia mínima: 200 velas H1
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(sym, tf_h1, 0, 60, r) < 55) return false;

   double c  = r[1].close, o = r[1].open;
   double h  = r[1].high,  l = r[1].low;

   // EMA 8 y 21 (buffer 0 = valor en barra 1)
   double buf[]; ArraySetAsSeries(buf, true);
   double ema8 = 0, ema21 = 0, atr14 = 0;
   if(CopyBuffer(h_ema8,  0, 1, 1, buf) > 0) ema8  = buf[0];
   if(CopyBuffer(h_ema21, 0, 1, 1, buf) > 0) ema21 = buf[0];
   if(CopyBuffer(h_atr14, 0, 1, 1, buf) > 0) atr14 = buf[0];

   if(c <= 0 || ema8 <= 0 || ema21 <= 0 || atr14 <= 0) return false;

   // ema_cross, ema_slope
   double slope_buf[];
   ArraySetAsSeries(slope_buf, true);
   double ema21_lag = 0;
   if(CopyBuffer(h_ema21, 0, 4, 1, slope_buf) > 0) ema21_lag = slope_buf[0];

   float ema_cross  = (float)((ema8 - ema21) / c);
   float ema_slope  = ema21_lag > 0 ? (float)((ema21 - ema21_lag) / c) : 0.0f;

   // RSI manual (14 períodos H1)
   double gains = 0, losses = 0;
   for(int i = 1; i <= 14; i++)
   {
      double diff = r[i].close - r[i+1].close;
      if(diff > 0) gains  += diff;
      else         losses -= diff;
   }
   double avg_gain = gains  / 14.0;
   double avg_loss = losses / 14.0;
   double rsi = (avg_loss > 0) ? 100.0 - 100.0 / (1.0 + avg_gain/avg_loss) : 100.0;
   float  rsi_norm = (float)((rsi - 50.0) / 50.0);

   // ATR normalizado
   float atr_norm = (float)(atr14 / c);

   // Bollinger (20 períodos)
   double sum20 = 0, sum20sq = 0;
   for(int i = 1; i <= 20; i++) { sum20 += r[i].close; sum20sq += r[i].close * r[i].close; }
   double sma20 = sum20 / 20.0;
   double std20 = MathSqrt(sum20sq/20.0 - sma20*sma20);
   float  bb_pos = (std20 > 0) ? (float)((c - sma20) / (2.0 * std20)) : 0.0f;

   // ADX aproximado (simplificado sin wilder)
   double plus_dm = 0, minus_dm = 0, tr_sum = 0;
   for(int i = 1; i <= 14; i++)
   {
      double up   = r[i].high - r[i+1].high;
      double down = r[i+1].low - r[i].low;
      if(up > 0 && up > down)   plus_dm  += up;
      if(down > 0 && down > up) minus_dm += down;
      double tr = MathMax(r[i].high - r[i].low,
               MathMax(MathAbs(r[i].high - r[i+1].close),
                       MathAbs(r[i].low  - r[i+1].close)));
      tr_sum += tr;
   }
   double pdi = (tr_sum > 0) ? 100.0 * plus_dm  / tr_sum : 0.0;
   double mdi = (tr_sum > 0) ? 100.0 * minus_dm / tr_sum : 0.0;
   float  adx    = (float)(MathAbs(pdi - mdi) / (pdi + mdi + 1e-10));
   float  di_diff = (float)((pdi - mdi) / 100.0);

   // Candle body, wicks
   float body       = (atr14 > 0) ? (float)((c - o) / atr14) : 0.0f;
   float upper_wick = (atr14 > 0) ? (float)((h - MathMax(c,o)) / atr14) : 0.0f;
   float lower_wick = (atr14 > 0) ? (float)((MathMin(c,o) - l) / atr14) : 0.0f;

   // Sesión (hora GMT del cierre de la barra)
   MqlDateTime dt; TimeToStruct(r[1].time, dt);
   float is_london = (dt.hour >= 7 && dt.hour < 11) ? 1.0f : 0.0f;
   float is_ny     = (dt.hour >= 13 && dt.hour < 17) ? 1.0f : 0.0f;

   // Momentum 3 y 8
   float mom3 = (r[4].close > 0) ? (float)((c - r[4].close) / r[4].close) : 0.0f;
   float mom8 = (r[9].close > 0) ? (float)((c - r[9].close) / r[9].close) : 0.0f;

   // Vol ratio (simplificado: siempre 1.0 si no hay volumen real H1)
   double vol20 = 0;
   for(int i = 1; i <= 20; i++) vol20 += (double)r[i].tick_volume;
   float vol_ratio = (vol20 > 0) ? (float)((r[1].tick_volume * 20.0) / vol20) : 1.0f;

   // ATR ratio (ATR actual vs. media 50)
   double atr50 = 0;
   for(int i = 1; i <= 50 && i < 55; i++)
   {
      double tr2 = MathMax(r[i].high - r[i].low,
                MathMax(MathAbs(r[i].high - r[i+1].close),
                        MathAbs(r[i].low  - r[i+1].close)));
      atr50 += tr2;
   }
   atr50 /= 50.0;
   float atr_ratio = (atr50 > 0) ? (float)(atr14 / atr50) : 1.0f;

   // Ordenar igual que el entrenamiento:
   // ['ema_cross','ema_slope','rsi_norm','atr_norm','bb_pos','adx','di_diff',
   //  'body','upper_wick','lower_wick','is_london','is_ny','mom3','mom8','vol_ratio','atr_ratio']
   features[0]  = ema_cross;
   features[1]  = ema_slope;
   features[2]  = rsi_norm;
   features[3]  = atr_norm;
   features[4]  = bb_pos;
   features[5]  = adx;
   features[6]  = di_diff;
   features[7]  = body;
   features[8]  = upper_wick;
   features[9]  = lower_wick;
   features[10] = is_london;
   features[11] = is_ny;
   features[12] = mom3;
   features[13] = mom8;
   features[14] = vol_ratio;
   features[15] = atr_ratio;

   return true;
}

//+------------------------------------------------------------------+
//| Predecir probabilidad de movimiento ALCISTA                      |
//|                                                                  |
//| Retorna: prob_buy ∈ [0.0, 1.0]                                   |
//|   > GM_ML_THRESHOLD → señal BUY confirmada por ML               |
//|   < (1-GM_ML_THRESHOLD) → señal SELL confirmada por ML          |
//|   en el medio → señal débil (no operar)                          |
//|                                                                  |
//| dir = +1 BUY / -1 SELL / 0 sin señal técnica                    |
//| Retorna GM_ML_DISABLED_PROB (0.5) si ONNX no disponible         |
//+------------------------------------------------------------------+
double GM_ML_Predict(string sym, ENUM_TIMEFRAMES tf_h1,
                     int h_atr14, int h_ema8, int h_ema21,
                     int dir = 0)
{
   if(!g_onnx_ready) return GM_ML_DISABLED_PROB;

   float features[];
   if(!GM_ML_BuildFeatures(sym, tf_h1, h_atr14, h_ema8, h_ema21, features))
      return GM_ML_DISABLED_PROB;

   // Tensor de salida: [1, 2] → [prob_sell, prob_buy]
   float output[];
   ArrayResize(output, 2);
   ArrayInitialize(output, 0.0f);

   if(!OnnxRun(g_onnx_handle,
               ONNX_NO_CONVERSION,
               features,
               output))
   {
      Print("[GM_ML] OnnxRun error: ", GetLastError());
      return GM_ML_DISABLED_PROB;
   }

   // output[1] = probabilidad de BUY (clase 1)
   double prob_buy = MathMin(MathMax((double)output[1], 0.0), 1.0);
   return prob_buy;
}

//+------------------------------------------------------------------+
//| Helper rápido: ¿la señal técnica está confirmada por ML?         |
//+------------------------------------------------------------------+
bool GM_ML_Confirms(double prob_buy, int dir)
{
   if(!g_onnx_ready) return true;   // sin modelo: no filtrar
   if(dir ==  1) return (prob_buy  >= GM_ML_THRESHOLD);
   if(dir == -1) return (prob_buy  <= 1.0 - GM_ML_THRESHOLD);
   return false;
}

#endif // GOLDMASTER_ML_ONNX_MQH
