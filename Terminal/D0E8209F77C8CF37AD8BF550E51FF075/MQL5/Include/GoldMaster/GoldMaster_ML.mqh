//+──────────────────────────────────────────────────────────────────────────+
//│          GOLD MASTER SYSTEM — ML Bridge v3.1                             │
//│  Módulo: Puente CSV entre predicciones Python ML y el EA MQL5            │
//│  Python escribe predictions.csv → MQL5 lee → filtra por confianza        │
//│                                                                           │
//│  Formato CSV (Python escribe):                                            │
//│  timestamp,signal,confidence_lstm,confidence_xgb,confidence_lgbm,        │
//│           ensemble_signal,ensemble_confidence,price_target,regime         │
//│                                                                           │
//│  Ejemplo:                                                                 │
//│  2024.01.15 14:30:00,1,0.72,0.68,0.75,1,0.717,2045.50,trending           │
//+──────────────────────────────────────────────────────────────────────────+
#ifndef GOLDMASTER_ML_MQH
#define GOLDMASTER_ML_MQH

#include "GoldMaster_Core.mqh"

//════════════════════════════════════════════════════════
//  ESTRUCTURA: PREDICCIÓN ML COMPLETA
//════════════════════════════════════════════════════════
struct GMLPrediction {
   datetime timestamp;          // cuándo fue generada la predicción
   int      signal;             // 1=buy, -1=sell, 0=neutral
   double   conf_lstm;          // confianza del modelo LSTM (0-1)
   double   conf_xgb;           // confianza del modelo XGBoost (0-1)
   double   conf_lgbm;          // confianza del modelo LightGBM (0-1)
   int      ensemble_signal;    // señal del voto del ensemble (1/-1/0)
   double   ensemble_conf;      // confianza media ponderada ensemble (0-1)
   double   price_target;       // objetivo de precio predicho
   string   regime;             // "trending", "ranging", "volatile"
   bool     valid;              // si la predicción es reciente y válida
   int      age_seconds;        // segundos desde que fue generada
};

//════════════════════════════════════════════════════════
//  CLASE: LECTOR DE PREDICCIONES ML
//════════════════════════════════════════════════════════
class CGMLBridge {
private:
   string       m_csv_path;          // ruta al CSV de predicciones
   GMLPrediction m_last;             // última predicción cargada
   datetime     m_last_read;         // última vez que se leyó el CSV
   int          m_read_interval_s;   // cada cuántos segundos releer
   double       m_min_confidence;    // confianza mínima para señal válida
   int          m_max_age_s;         // antigüedad máxima de predicción (s)
   int          m_min_model_votes;   // mínimo de modelos que deben coincidir (1-3)

   void ResetPrediction(GMLPrediction &p) {
      p.timestamp       = 0;
      p.signal          = 0;
      p.conf_lstm       = 0;
      p.conf_xgb        = 0;
      p.conf_lgbm       = 0;
      p.ensemble_signal = 0;
      p.ensemble_conf   = 0;
      p.price_target    = 0;
      p.regime          = "unknown";
      p.valid           = false;
      p.age_seconds     = 999999;
   }

   // Lee el CSV y carga la predicción más reciente (última línea)
   bool ReadCSV() {
      int fh = FileOpen(m_csv_path, FILE_READ|FILE_CSV|FILE_ANSI, ',');
      if(fh == INVALID_HANDLE) {
         GM_Log("ML_Bridge", "CSV no encontrado: " + m_csv_path, true);
         return false;
      }

      // Saltar encabezado
      bool header_skipped = false;
      GMLPrediction best;
      ResetPrediction(best);
      int rows = 0;

      while(!FileIsEnding(fh) && rows < 1000) {
         string ts_s    = FileReadString(fh);
         string sig_s   = FileReadString(fh);
         string lstm_s  = FileReadString(fh);
         string xgb_s   = FileReadString(fh);
         string lgbm_s  = FileReadString(fh);
         string esig_s  = FileReadString(fh);
         string econf_s = FileReadString(fh);
         string ptgt_s  = FileReadString(fh);
         string reg_s   = FileReadString(fh);
         rows++;

         // Saltar encabezado (primera fila con texto no numérico)
         if(!header_skipped) { header_skipped=true; continue; }
         if(StringLen(ts_s) < 10) continue;

         datetime ts = StringToTime(ts_s);
         if(ts == 0) continue;

         // Solo guardar si es más reciente
         if(ts > best.timestamp) {
            best.timestamp       = ts;
            best.signal          = (int)StringToInteger(sig_s);
            best.conf_lstm       = StringToDouble(lstm_s);
            best.conf_xgb        = StringToDouble(xgb_s);
            best.conf_lgbm       = StringToDouble(lgbm_s);
            best.ensemble_signal = (int)StringToInteger(esig_s);
            best.ensemble_conf   = StringToDouble(econf_s);
            best.price_target    = StringToDouble(ptgt_s);
            best.regime          = reg_s;
         }
      }
      FileClose(fh);

      if(best.timestamp == 0) return false;

      // Calcular antigüedad
      best.age_seconds = (int)(TimeCurrent() - best.timestamp);
      best.valid       = (best.age_seconds <= m_max_age_s);
      m_last           = best;
      m_last_read      = TimeCurrent();
      return true;
   }

public:
   CGMLBridge() {
      m_csv_path         = "GoldMaster\\ml_predictions.csv";
      m_last_read        = 0;
      m_read_interval_s  = 60;     // releer cada 60 segundos
      m_min_confidence   = 0.60;   // confianza mínima 60%
      m_max_age_s        = 300;    // predicción válida por 5 minutos
      m_min_model_votes  = 2;      // al menos 2 de 3 modelos deben coincidir
      ResetPrediction(m_last);
   }

   void Init(string csv_path      = "",
             double min_conf      = 0.60,
             int    max_age_s     = 300,
             int    min_votes     = 2,
             int    read_interval = 60) {
      if(StringLen(csv_path) > 0) m_csv_path = csv_path;
      m_min_confidence  = min_conf;
      m_max_age_s       = max_age_s;
      m_min_model_votes = min_votes;
      m_read_interval_s = read_interval;
      ReadCSV();
   }

   // Actualiza si ha pasado el intervalo de lectura
   void Refresh() {
      if(TimeCurrent() - m_last_read >= m_read_interval_s) ReadCSV();
   }

   // Predicción completa
   GMLPrediction GetPrediction() {
      Refresh();
      return m_last;
   }

   // Señal filtrada: devuelve 1, -1, o 0 si no cumple criterios
   int GetFilteredSignal() {
      Refresh();
      if(!m_last.valid) return 0;
      if(m_last.ensemble_conf < m_min_confidence) return 0;

      // Contar votos de modelos individuales
      int votes = 0;
      int target = m_last.ensemble_signal;
      if(target == 0) return 0;
      if(m_last.signal == target)          votes++;

      // Votar basado en confianza individual vs threshold
      // LSTM: vota si conf_lstm > min_confidence
      if(m_last.conf_lstm  >= m_min_confidence) {
         // Para LSTM, la señal es la del ensemble si la confianza es suficiente
         votes++;
      }
      if(m_last.conf_xgb  >= m_min_confidence) votes++;
      if(m_last.conf_lgbm >= m_min_confidence) votes++;

      if(votes < m_min_model_votes) return 0;
      return target;
   }

   // Confianza del ensemble (0-1)
   double GetConfidence() {
      Refresh();
      return m_last.ensemble_conf;
   }

   // ¿La predicción es válida y reciente?
   bool IsValid() {
      Refresh();
      return m_last.valid && (m_last.age_seconds <= m_max_age_s);
   }

   // Régimen de mercado según ML
   string GetRegime() {
      Refresh();
      return m_last.regime;
   }

   // Precio objetivo
   double GetPriceTarget() {
      Refresh();
      return m_last.price_target;
   }

   // Confianza por modelo individual
   double GetLSTMConf()  { Refresh(); return m_last.conf_lstm;  }
   double GetXGBConf()   { Refresh(); return m_last.conf_xgb;   }
   double GetLGBMConf()  { Refresh(); return m_last.conf_lgbm;  }

   // String de estado para logging/UI
   string StatusString() {
      Refresh();
      if(!m_last.valid)
         return StringFormat("ML: Sin datos (última: %ds ago)", m_last.age_seconds);
      string dir = (m_last.ensemble_signal == 1) ? "BUY" :
                   (m_last.ensemble_signal == -1) ? "SELL" : "NEUTRAL";
      return StringFormat("ML: %s conf:%.0f%% LSTM:%.0f%% XGB:%.0f%% LGBM:%.0f%% [%s] %ds",
                          dir,
                          m_last.ensemble_conf*100,
                          m_last.conf_lstm*100,
                          m_last.conf_xgb*100,
                          m_last.conf_lgbm*100,
                          m_last.regime,
                          m_last.age_seconds);
   }

   // Escribir CSV de features para que Python las lea
   // Python usa estas features para hacer predicciones
   bool WriteFeatures(string symbol,
                      double close,
                      double atr,
                      double ema21,
                      double ema50,
                      double ema200,
                      int    trend,
                      double dxy_bias,    // 1=dxy subiendo, -1=bajando, 0=neutro
                      int    session,
                      int    confluence_score) {
      string feat_path = "GoldMaster\\ml_features.csv";
      int fh = FileOpen(feat_path, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
      if(fh == INVALID_HANDLE) return false;
      // Escribir encabezado + una fila de features actuales
      FileWrite(fh, "timestamp,symbol,close,atr,ema21,ema50,ema200,trend,dxy_bias,session,confluence");
      FileWrite(fh,
         TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
         symbol, close, atr, ema21, ema50, ema200,
         trend, dxy_bias, session, confluence_score);
      FileClose(fh);
      return true;
   }
};

//════════════════════════════════════════════════════════
//  FILTRO DE CONFLUENCIA — Evaluador de setup
//════════════════════════════════════════════════════════

// Calcula score de confluencia combinando SMC + ML + Técnico
// Retorna int 0-15+ (mínimo recomendado: 5 para entrar)
struct GMConfluenceScore {
   int total;
   // Desglose
   int htf_bias;      // 2 si HTF EMA alineada
   int mtf_bias;      // 1 si MTF alineada
   int ltf_bias;      // 1 si LTF alineada
   int smc_bos;       // 1 si hay BOS en dirección
   int smc_choch;     // 2 si hay CHoCH confirmado
   int smc_ob;        // 2 si precio está en OB válido
   int smc_fvg;       // 1 si hay FVG sin llenar
   int smc_liq;       // 2 si hay sweep de liquidez
   int smc_ote;       // 2 si está en zona OTE 61.8-78.6%
   int ml_signal;     // 2 si ML ensemble coincide
   int ml_conf_bonus; // 1 extra si confianza > 80%
   int vol_regime;    // 1 si volatilidad es normal
   string summary;    // texto resumen
};

// Función auxiliar para construir score de confluencia
// (Llamar desde el EA con todos los valores disponibles)
GMConfluenceScore GM_CalcConfluence(
   int    direction,        // 1=bull, -1=bear
   int    htf_bias,         // EMA bias H4
   int    mtf_bias,         // EMA bias H1
   int    ltf_bias,         // EMA bias M15
   bool   has_bos,          // BOS en dirección
   bool   has_choch,        // CHoCH confirmado
   bool   has_ob,           // precio en OB
   bool   has_fvg,          // FVG sin llenar
   bool   has_liq_sweep,    // sweep de liquidez
   bool   has_ote,          // en zona OTE
   int    ml_signal,        // señal ML
   double ml_conf,          // confianza ML
   ENUM_GM_VOLATILITY vol   // régimen volatilidad
) {
   GMConfluenceScore sc;
   sc.total       = 0;
   sc.htf_bias    = (htf_bias  == direction) ? 2 : 0;
   sc.mtf_bias    = (mtf_bias  == direction) ? 1 : 0;
   sc.ltf_bias    = (ltf_bias  == direction) ? 1 : 0;
   sc.smc_bos     = has_bos    ? 1 : 0;
   sc.smc_choch   = has_choch  ? 2 : 0;
   sc.smc_ob      = has_ob     ? 2 : 0;
   sc.smc_fvg     = has_fvg    ? 1 : 0;
   sc.smc_liq     = has_liq_sweep ? 2 : 0;
   sc.smc_ote     = has_ote    ? 2 : 0;
   sc.ml_signal   = (ml_signal == direction) ? 2 : 0;
   sc.ml_conf_bonus = (ml_conf > 0.80 && ml_signal == direction) ? 1 : 0;
   sc.vol_regime  = (vol == GM_VOL_NORMAL) ? 1 : 0;

   sc.total = sc.htf_bias + sc.mtf_bias + sc.ltf_bias +
              sc.smc_bos  + sc.smc_choch + sc.smc_ob +
              sc.smc_fvg  + sc.smc_liq   + sc.smc_ote +
              sc.ml_signal + sc.ml_conf_bonus + sc.vol_regime;

   sc.summary = StringFormat(
      "Score:%d | Bias:%d/%d/%d | SMC:BOS%d CHoCH%d OB%d FVG%d Liq%d OTE%d | ML:%d(%.0f%%)",
      sc.total,
      sc.htf_bias, sc.mtf_bias, sc.ltf_bias,
      sc.smc_bos, sc.smc_choch, sc.smc_ob, sc.smc_fvg, sc.smc_liq, sc.smc_ote,
      sc.ml_signal, ml_conf*100
   );
   return sc;
}

#endif
