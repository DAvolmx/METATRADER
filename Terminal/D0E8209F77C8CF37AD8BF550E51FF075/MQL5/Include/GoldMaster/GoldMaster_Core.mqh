//+──────────────────────────────────────────────────────────────────────────+
//│          GOLD MASTER SYSTEM — Core Library v3.1                          │
//│  Módulo central: constantes, estructuras, funciones compartidas          │
//│  v3.1: News filter, multi-TF EMA bias, volatility regime, spread monitor │
//│  Incluir en todos los EAs e Indicadores del sistema                      │
//+──────────────────────────────────────────────────────────────────────────+
#ifndef GOLDMASTER_CORE_MQH
#define GOLDMASTER_CORE_MQH

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//════════════════════════════════════════════════════════
//  CONSTANTES GLOBALES DEL SISTEMA
//════════════════════════════════════════════════════════
#define GM_VERSION        "3.1"
#define GM_MAGIC_BASE     900000
#define GM_MAGIC_SCALP    900001
#define GM_MAGIC_DAYTRADE 900002
#define GM_MAGIC_PENDING  900003
#define GM_MAGIC_ORB      900004
#define GM_MAGIC_NEWS     900005
#define GM_MAX_SPREAD     40        // puntos máximos permitidos
#define GM_MIN_ATR_PIPS   0.20      // filtro lateralidad
#define GM_NEWS_FREEZE_MIN 30       // minutos a bloquear antes/después de noticias
#define GM_SPREAD_WARN    30        // puntos: alerta spread elevado
#define GM_SLIP_MAX       5         // puntos: slippage máximo aceptable

//════════════════════════════════════════════════════════
//  ENUM: TIPOS DE SEÑAL
//════════════════════════════════════════════════════════
enum ENUM_GM_SIGNAL {
   GM_SIGNAL_NONE       = 0,
   GM_SIGNAL_BUY        = 1,
   GM_SIGNAL_SELL       = -1,
   GM_SIGNAL_BUY_LIMIT  = 2,
   GM_SIGNAL_SELL_LIMIT = -2,
   GM_SIGNAL_BUY_STOP   = 3,
   GM_SIGNAL_SELL_STOP  = -3,
};

enum ENUM_GM_SESSION {
   GM_SESSION_TOKIO   = 0,
   GM_SESSION_LONDON  = 1,
   GM_SESSION_NY      = 2,
   GM_SESSION_OVERLAP = 3,
   GM_SESSION_NONE    = 4,
};

enum ENUM_GM_TREND {
   GM_TREND_BULL = 1,
   GM_TREND_BEAR = -1,
   GM_TREND_FLAT = 0,
};

// v3.1: Régimen de volatilidad
enum ENUM_GM_VOLATILITY {
   GM_VOL_LOW    = 0,    // ATR < 60% media histórica  → lateral/rango
   GM_VOL_NORMAL = 1,    // ATR 60-140% → tendencia normal
   GM_VOL_HIGH   = 2,    // ATR > 140% → expansión / noticias
};

//════════════════════════════════════════════════════════
//  ESTRUCTURA: RESULTADO DE SEÑAL
//════════════════════════════════════════════════════════
struct GMSignal {
   ENUM_GM_SIGNAL type;
   double         entry_price;
   double         sl;
   double         tp1;
   double         tp2;
   double         tp3;
   double         lot;
   string         reason;
   double         rr_ratio;
   double         confidence;    // 0-1 (del modelo ML)
   datetime       expires;
};

//════════════════════════════════════════════════════════
//  ESTRUCTURA: ESTADO DE POSICIÓN GESTIONADA
//════════════════════════════════════════════════════════
struct GMTradeState {
   ulong    ticket;
   double   orig_lot;
   double   risk_dist;
   double   entry_price;
   double   tp1, tp2, tp3;
   bool     p1_done;
   bool     p2_done;
   bool     trail_on;
   datetime open_time;
   int      magic;
   string   setup_type;
};

//════════════════════════════════════════════════════════
//  v3.1: ESTRUCTURA: NOTICIA DE ALTO IMPACTO
//════════════════════════════════════════════════════════
struct GMNewsEvent {
   datetime time;         // hora UTC del evento
   string   name;         // nombre del evento
   string   currency;     // moneda afectada ("USD","XAU",etc)
   int      impact;       // 1=bajo, 2=medio, 3=alto
};

//════════════════════════════════════════════════════════
//  v3.1: ESTRUCTURA: SESGO MULTI-TIMEFRAME
//════════════════════════════════════════════════════════
struct GMMTFBias {
   int bias_htf;    // 1=bull -1=bear 0=flat (H4/D1)
   int bias_mtf;    // 1=bull -1=bear 0=flat (H1)
   int bias_ltf;    // 1=bull -1=bear 0=flat (M15)
   int confluence;  // cuántos TFs coinciden: 0,1,2,3
   bool aligned;    // los 3 TFs apuntan igual
};

//════════════════════════════════════════════════════════
//  v3.1: ESTRUCTURA: ESTADO DEL SPREAD/SLIPPAGE
//════════════════════════════════════════════════════════
struct GMSpreadState {
   int    current_spread;  // spread actual en puntos
   double avg_spread_1h;   // promedio últimas ~60 velas M1
   bool   spread_ok;       // spread <= GM_MAX_SPREAD
   bool   spread_elevated; // spread > GM_SPREAD_WARN
   double last_slippage;   // último slippage en puntos (log)
   bool   trading_ok;      // resumen: puede operar
};

//════════════════════════════════════════════════════════
//  FILTRO DE NOTICIAS — Gestor de calendario
//  Carga eventos desde archivo CSV y filtra operaciones
//════════════════════════════════════════════════════════
class CGMNewsFilter {
private:
   GMNewsEvent  m_events[];
   int          m_count;
   string       m_csv_path;   // ej: "GoldMaster\\news_calendar.csv"
   datetime     m_last_load;

   // Lee el CSV de noticias: formato fecha,hora,nombre,moneda,impacto
   // Columnas: 2024.01.15,08:30,NFP,USD,3
   void LoadCSV() {
      m_count = 0;
      ArrayResize(m_events, 0);
      // Se intenta PRIMERO el sandbox COMUN y despues el del terminal.
      //
      // Por que: gm_intel.py escribe el calendario en
      //   %APPDATA%\MetaQuotes\Terminal\Common\Files\GoldMaster\news_calendar.csv
      // es decir, en el sandbox COMUN. Este FileOpen se hacia SIN FILE_COMMON,
      // asi que resolvia contra MQL5\Files del terminal y NUNCA encontraba el
      // fichero. Resultado: el filtro de noticias no bloqueaba jamas, y lo
      // hacia en silencio (el aviso sale una sola vez y encima dice que "en
      // backtest es normal"), de modo que cualquier EA que lo use creia tener
      // proteccion ante noticias sin tenerla. Probar las dos ubicaciones
      // ademas evita romper a quien haya dejado el CSV a mano en el terminal.
      int fh = FileOpen(m_csv_path, FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ, ',');
      bool from_common = (fh != INVALID_HANDLE);
      if(!from_common)
         fh = FileOpen(m_csv_path, FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
      if(fh == INVALID_HANDLE) {
         static bool s_warned=false;
         if(!s_warned) {
            s_warned=true;
            GM_Log("NewsFilter","CSV NO encontrado ni en Common\\Files\\"+m_csv_path+
                   " ni en el sandbox del terminal. EL FILTRO DE NOTICIAS NO VA A "
                   "BLOQUEAR NADA. Genera el calendario con gm_intel.py antes de "
                   "operar en real; en backtest sin calendario es esperable.",true);
         }
         return;
      }
      GM_Log("NewsFilter", StringFormat("calendario cargado desde %s",
             from_common ? "Common\\Files" : "sandbox del terminal"), false);
      int rows = 0;
      while(!FileIsEnding(fh) && rows < 500) {
         string date_s  = FileReadString(fh);
         string time_s  = FileReadString(fh);
         string name_s  = FileReadString(fh);
         string curr_s  = FileReadString(fh);
         string imp_s   = FileReadString(fh);
         if(StringLen(date_s) < 8) { rows++; continue; }
         string dt_str  = date_s + " " + time_s;
         datetime ev_t  = StringToTime(dt_str);
         if(ev_t == 0) { rows++; continue; }
         GMNewsEvent ev;
         ev.time     = ev_t;
         ev.name     = name_s;
         ev.currency = curr_s;
         ev.impact   = (int)StringToInteger(imp_s);
         int sz = ArraySize(m_events);
         ArrayResize(m_events, sz+1);
         m_events[sz] = ev;
         m_count++;
         rows++;
      }
      FileClose(fh);
      m_last_load = TimeCurrent();
      GM_Log("NewsFilter", "Cargadas "+IntegerToString(m_count)+" noticias de "+m_csv_path, true);
   }

public:
   CGMNewsFilter() { m_count=0; m_last_load=0; m_csv_path="GoldMaster\\news_calendar.csv"; }

   void Init(string csv_path="") {
      if(StringLen(csv_path) > 0) m_csv_path = csv_path;
      LoadCSV();
   }

   // Recarga si han pasado más de 6 horas
   void Refresh() {
      if(TimeCurrent() - m_last_load > 6*3600) LoadCSV();
   }

   // Verdadero si hay noticia de alto impacto en la ventana (minutos)
   // min_impact: 2=medio+, 3=solo alto
   bool IsNewsTime(int freeze_min=30, int min_impact=3, string currencies="USD,XAU") {
      Refresh();
      datetime now = TimeGMT();
      datetime window = (datetime)(freeze_min * 60);
      for(int i=0; i<m_count; i++) {
         if(m_events[i].impact < min_impact) continue;
         // Verifica si la moneda es relevante
         bool curr_match = (StringFind(currencies, m_events[i].currency) >= 0);
         if(!curr_match) continue;
         long diff = MathAbs((long)now - (long)m_events[i].time);
         if(diff <= window) return true;
      }
      return false;
   }

   // Próxima noticia en segundos (0 si no hay)
   int SecondsToNextNews(int min_impact=3, string currencies="USD,XAU") {
      Refresh();
      datetime now = TimeGMT();
      int best = 999999;
      for(int i=0; i<m_count; i++) {
         if(m_events[i].impact < min_impact) continue;
         if(StringFind(currencies, m_events[i].currency) < 0) continue;
         long diff = (long)(m_events[i].time - now);
         if(diff > 0 && (int)diff < best) best = (int)diff;
      }
      return (best == 999999) ? 0 : best;
   }

   // Nombre de la próxima noticia de alto impacto
   string NextNewsName(int min_impact=3) {
      Refresh();
      datetime now = TimeGMT();
      datetime best_t = 0;
      string   best_n = "";
      for(int i=0; i<m_count; i++) {
         if(m_events[i].impact < min_impact) continue;
         long diff = (long)(m_events[i].time - now);
         if(diff > 0 && (best_t == 0 || m_events[i].time < best_t)) {
            best_t = m_events[i].time;
            best_n = m_events[i].name;
         }
      }
      return best_n;
   }

   int Count() { return m_count; }
};

//════════════════════════════════════════════════════════
//  SESGO MULTI-TF — Clase para calcular alineación EMA
//════════════════════════════════════════════════════════
class CGMMTFBiasEngine {
private:
   string m_symbol;
   int    m_ema_fast;
   int    m_ema_slow;

   // Devuelve 1/−1/0 comparando EMA fast vs slow en el TF dado
   int GetEMABias(ENUM_TIMEFRAMES tf) {
      int h_fast = iMA(m_symbol, tf, m_ema_fast, 0, MODE_EMA, PRICE_CLOSE);
      int h_slow = iMA(m_symbol, tf, m_ema_slow, 0, MODE_EMA, PRICE_CLOSE);
      if(h_fast == INVALID_HANDLE || h_slow == INVALID_HANDLE) return 0;
      double fast_val[1], slow_val[1];
      if(CopyBuffer(h_fast, 0, 1, 1, fast_val) < 1) return 0;
      if(CopyBuffer(h_slow, 0, 1, 1, slow_val) < 1) return 0;
      IndicatorRelease(h_fast);
      IndicatorRelease(h_slow);
      double diff = fast_val[0] - slow_val[0];
      double threshold = SymbolInfoDouble(m_symbol, SYMBOL_POINT) * 5;
      if(diff >  threshold) return  1;
      if(diff < -threshold) return -1;
      return 0;
   }

public:
   CGMMTFBiasEngine() { m_symbol=_Symbol; m_ema_fast=21; m_ema_slow=50; }

   void Init(string symbol, int ema_fast=21, int ema_slow=50) {
      m_symbol   = symbol;
      m_ema_fast = ema_fast;
      m_ema_slow = ema_slow;
   }

   // Calcula sesgo completo en 3 TFs
   GMMTFBias GetBias(ENUM_TIMEFRAMES htf=PERIOD_H4,
                     ENUM_TIMEFRAMES mtf=PERIOD_H1,
                     ENUM_TIMEFRAMES ltf=PERIOD_M15) {
      GMMTFBias b;
      b.bias_htf   = GetEMABias(htf);
      b.bias_mtf   = GetEMABias(mtf);
      b.bias_ltf   = GetEMABias(ltf);
      // Confluence: cuántos TFs coinciden
      int target = (b.bias_htf != 0) ? b.bias_htf : b.bias_mtf;
      b.confluence = 0;
      if(b.bias_htf == target && target != 0) b.confluence++;
      if(b.bias_mtf == target && target != 0) b.confluence++;
      if(b.bias_ltf == target && target != 0) b.confluence++;
      b.aligned = (b.confluence == 3);
      return b;
   }

   // Sesgo rápido en un solo TF (int 1/-1/0)
   int QuickBias(ENUM_TIMEFRAMES tf) { return GetEMABias(tf); }
};

//════════════════════════════════════════════════════════
//  DETECTOR DE RÉGIMEN DE VOLATILIDAD
//════════════════════════════════════════════════════════
class CGMVolatilityRegime {
private:
   string m_symbol;
   int    m_atr_period;
   int    m_lookback;       // barras históricas para calcular promedio

public:
   CGMVolatilityRegime() { m_symbol=_Symbol; m_atr_period=14; m_lookback=100; }

   void Init(string symbol, int atr_period=14, int lookback=100) {
      m_symbol     = symbol;
      m_atr_period = atr_period;
      m_lookback   = lookback;
   }

   // ATR actual (barra 1)
   double CurrentATR(ENUM_TIMEFRAMES tf=PERIOD_H1) {
      int h = iATR(m_symbol, tf, m_atr_period);
      if(h == INVALID_HANDLE) return 0;
      double buf[1];
      int ok = CopyBuffer(h, 0, 1, 1, buf);
      IndicatorRelease(h);
      return (ok < 1) ? 0 : buf[0];
   }

   // ATR promedio de las últimas m_lookback barras
   double AvgATR(ENUM_TIMEFRAMES tf=PERIOD_H1) {
      int h = iATR(m_symbol, tf, m_atr_period);
      if(h == INVALID_HANDLE) return 0;
      double buf[];
      ArrayResize(buf, m_lookback);
      int got = CopyBuffer(h, 0, 1, m_lookback, buf);
      IndicatorRelease(h);
      if(got <= 0) return 0;
      double sum = 0;
      for(int i=0; i<got; i++) sum += buf[i];
      return sum / got;
   }

   // Régimen actual
   ENUM_GM_VOLATILITY GetRegime(ENUM_TIMEFRAMES tf=PERIOD_H1) {
      double cur = CurrentATR(tf);
      double avg = AvgATR(tf);
      if(avg <= 0) return GM_VOL_NORMAL;
      double ratio = cur / avg;
      if(ratio < 0.60) return GM_VOL_LOW;
      if(ratio > 1.40) return GM_VOL_HIGH;
      return GM_VOL_NORMAL;
   }

   // Ratio actual/promedio (útil para scoring)
   double VolatilityRatio(ENUM_TIMEFRAMES tf=PERIOD_H1) {
      double avg = AvgATR(tf);
      if(avg <= 0) return 1.0;
      return CurrentATR(tf) / avg;
   }

   // Está en expansión (bueno para momentum trades)
   bool IsExpanding(ENUM_TIMEFRAMES tf=PERIOD_H1) {
      return (GetRegime(tf) == GM_VOL_HIGH);
   }

   // Está en contracción (bueno para acumular órdenes pendientes)
   bool IsContracting(ENUM_TIMEFRAMES tf=PERIOD_H1) {
      return (GetRegime(tf) == GM_VOL_LOW);
   }
};

//════════════════════════════════════════════════════════
//  MONITOR DE SPREAD / SLIPPAGE
//════════════════════════════════════════════════════════
class CGMSpreadMonitor {
private:
   string   m_symbol;
   double   m_spread_buf[];    // histórico de spreads M1
   int      m_buf_size;
   int      m_buf_idx;
   int      m_buf_filled;
   double   m_last_slippage;
   int      m_slip_count;      // operaciones con slippage registradas
   double   m_avg_slippage;

public:
   CGMSpreadMonitor() {
      m_symbol       = _Symbol;
      m_buf_size     = 60;       // historial ~1h en M1
      m_buf_idx      = 0;
      m_buf_filled   = 0;
      m_last_slippage= 0;
      m_slip_count   = 0;
      m_avg_slippage = 0;
   }

   void Init(string symbol, int history_bars=60) {
      m_symbol   = symbol;
      m_buf_size = history_bars;
      ArrayResize(m_spread_buf, m_buf_size);
      ArrayInitialize(m_spread_buf, 0);
   }

   // Llamar en cada tick o barra nueva
   void Tick() {
      int spread = GM_GetSpread(m_symbol);
      m_spread_buf[m_buf_idx] = (double)spread;
      m_buf_idx = (m_buf_idx + 1) % m_buf_size;
      if(m_buf_filled < m_buf_size) m_buf_filled++;
   }

   // Promedio spread histórico
   double AvgSpread() {
      if(m_buf_filled == 0) return 0;
      double sum = 0;
      for(int i=0; i<m_buf_filled; i++) sum += m_spread_buf[i];
      return sum / m_buf_filled;
   }

   // Registrar slippage tras OrderSend
   // expected_price: precio al que se solicitó, actual_price: precio real obtenido
   void LogSlippage(double expected_price, double actual_price, bool is_buy) {
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(point <= 0) return;
      double slip;
      if(is_buy)  slip = (actual_price - expected_price) / point;
      else        slip = (expected_price - actual_price) / point;
      m_last_slippage = slip;
      m_slip_count++;
      m_avg_slippage = (m_avg_slippage * (m_slip_count-1) + slip) / m_slip_count;
      if(slip > GM_SLIP_MAX)
         GM_Log("SpreadMon", StringFormat("⚠ Slippage alto: %.1f pts (avg:%.1f)", slip, m_avg_slippage), true);
   }

   // Estado completo
   GMSpreadState GetState() {
      GMSpreadState st;
      st.current_spread  = GM_GetSpread(m_symbol);
      st.avg_spread_1h   = AvgSpread();
      st.spread_ok       = (st.current_spread <= GM_MAX_SPREAD);
      st.spread_elevated = (st.current_spread > GM_SPREAD_WARN);
      st.last_slippage   = m_last_slippage;
      st.trading_ok      = st.spread_ok;
      return st;
   }

   // ¿Se puede operar ahora?
   bool CanTrade() {
      return (GM_GetSpread(m_symbol) <= GM_MAX_SPREAD);
   }

   double LastSlippage() { return m_last_slippage; }
   double AvgSlippage()  { return m_avg_slippage; }
   int    SlipCount()    { return m_slip_count; }
};

//════════════════════════════════════════════════════════
//  FUNCIONES UTILITARIAS (heredadas + mejoradas)
//════════════════════════════════════════════════════════

// Retorna la sesión activa actual (hora UTC)
ENUM_GM_SESSION GM_GetSession() {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;
   if(h >= 0  && h < 7)  return GM_SESSION_TOKIO;
   if(h >= 7  && h < 12) return GM_SESSION_LONDON;
   if(h >= 12 && h < 17) return GM_SESSION_OVERLAP;
   if(h >= 17 && h < 21) return GM_SESSION_NY;
   return GM_SESSION_NONE;
}

string GM_SessionName(ENUM_GM_SESSION s) {
   switch(s) {
      case GM_SESSION_TOKIO:   return "Tokio";
      case GM_SESSION_LONDON:  return "Londres";
      case GM_SESSION_OVERLAP: return "NY/Londres Overlap";
      case GM_SESSION_NY:      return "Nueva York";
      default:                 return "Nocturna";
   }
}

// ─── Soporte cuentas micro/cent (p.ej. XAUUSDmicro, lote mínimo 0.1) ───
// Si el lote calculado < lote mínimo, se acepta el mínimo sólo si su riesgo real
// no supera riesgo_deseado × g_gm_minlot_risk_tol. Si lo supera → lote 0 = NO operar.
double g_gm_minlot_risk_tol = 1.5;
// Cuentas pequeñas: se acepta el lote mínimo si su riesgo real ≤ este % del balance (aunque supere RiskPct).
// XAUUSDmicro (0.1 lote = 0.10$/$): con 50$ y 5% → SL hasta 25$.  XAUUSD normal (0.01 lote = 1$/$): con 50$ → SL hasta 2.5$ (casi nunca).
double g_gm_minlot_max_pct = 5.0;
datetime g_gm_skip_last = 0; int g_gm_skip_count = 0;

// Dinero que se gana/pierde con `lot` por un movimiento de `price_dist` en precio
double GM_MoneyPerMove(string symbol, double lot, double price_dist) {
   double tv = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0) return 0;
   return lot * price_dist / ts * tv;
}

// Lote para cierre parcial; 0 si la posición no se puede dividir (ej. 0.1 con mínimo 0.1)
double GM_PartialLot(string symbol, double pos_lot, double frac) {
   double mn = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double st = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(st <= 0) st = 0.01;
   if(mn <= 0) mn = st;
   double lot = MathFloor(pos_lot * frac / st + 1e-9) * st;
   if(lot < mn) return 0;
   if(pos_lot - lot < mn - 1e-9) return 0;      // lo que queda sería < mínimo
   return NormalizeDouble(lot, 2);
}

// Informe del símbolo al iniciar: cuánto vale cada movimiento con el lote mínimo
void GM_SymbolReport(string symbol, double risk_pct, double typical_sl) {
   double mn = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double st = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double cs = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double m1  = GM_MoneyPerMove(symbol, mn, 1.0);
   double rsk = GM_MoneyPerMove(symbol, mn, typical_sl);
   GM_Log("SYMBOL", StringFormat("%s | contrato:%.2f | lote min:%.2f step:%.2f | $1 de movimiento con lote min = %.2f %s",
          symbol, cs, mn, st, m1, cur), true);
   GM_Log("SYMBOL", StringFormat("SL típico %.2f → riesgo con lote min = %.2f %s (%.2f%% del balance, objetivo %.2f%%)",
          typical_sl, rsk, cur, bal > 0 ? rsk/bal*100 : 0, risk_pct), true);
   if(bal > 0 && rsk/bal*100 > risk_pct * g_gm_minlot_risk_tol)
      GM_Log("SYMBOL", "⚠ El lote mínimo excede tu riesgo: se saltarán trades con SL amplio. Sube balance, baja SL o usa símbolo micro.", true);
}

// Modo de llenado soportado por el símbolo/broker (evita error 10030 "Unsupported filling mode")
ENUM_ORDER_TYPE_FILLING GM_FillingMode(string symbol) {
   long fm = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((fm & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

// Normaliza volumen al step del símbolo
double GM_NormalizeLot(string symbol, double lot) {
   double mn = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(st <= 0) st = 0.01;   // guard: SYMBOL_VOLUME_STEP=0 durante init del backtester
   if(mn <= 0) mn = 0.01;
   lot = MathFloor(lot / st) * st;
   return MathMax(mn, MathMin(mx, lot));
}

// Calcula lote según % riesgo y distancia SL en precio
double GM_CalcLot(string symbol, double risk_pct, double sl_price_dist, double fixed_risk_cash=0) {
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amt = balance * risk_pct / 100.0;
   if(fixed_risk_cash > 0) risk_amt = fixed_risk_cash;
   if(risk_amt <= 0 || risk_amt >= AccountInfoDouble(ACCOUNT_EQUITY)) return 0;
   double tick_val = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_sz  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   // Guards contra division por cero durante sincronizacion de ticks en backtester
   if(tick_sz      <= 0) return 0;
   if(tick_val     <= 0) return 0;
   if(sl_price_dist<= 0) return 0;
   if(balance      <= 0) return 0;
   double lot = risk_amt / (sl_price_dist / tick_sz * tick_val);
   double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double vstp = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(vstp <= 0) vstp = 0.01;
   if(vmin <= 0) vmin = vstp;
   lot = MathFloor(lot / vstp + 1e-9) * vstp;       // redondeo hacia ABAJO (nunca más riesgo)
   if(lot < vmin) {
      double risk_min = vmin * sl_price_dist / tick_sz * tick_val;
      // límite = el mayor entre (riesgo objetivo × tolerancia) y el techo absoluto de cuenta pequeña
      double cap = MathMax(risk_amt * g_gm_minlot_risk_tol, balance * g_gm_minlot_max_pct / 100.0);
      if(g_gm_minlot_risk_tol >= 100) cap = DBL_MAX;          // modo SIN FILTROS
      if(fixed_risk_cash > 0) cap = fixed_risk_cash;         // cash override is a hard cap
      if(risk_min > cap) {
         g_gm_skip_count++;
         if(TimeCurrent() - g_gm_skip_last >= 3600) {         // como mucho 1 aviso por hora (antes: 1 por vela)
            GM_Log("LOT", StringFormat("Skip: lote min %.2f arriesga %.2f > %.2f permitido (SL %.2f) · %d señales saltadas desde el último aviso. Sube balance o baja SL.",
                   vmin, risk_min, cap, sl_price_dist, g_gm_skip_count), true);
            g_gm_skip_last = TimeCurrent(); g_gm_skip_count = 0;
         }
         return 0;
      }
      lot = vmin;
   }
   double margin_req = 0;
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(ask > 0 && OrderCalcMargin(ORDER_TYPE_BUY, symbol, lot, ask, margin_req)) {
      double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(margin_req > free * 0.75) {
         lot = MathFloor(lot * free * 0.75 / margin_req / vstp) * vstp;
         if(lot < vmin) { GM_Log("LOT", "Skip: margen insuficiente", true); return 0; }
      }
   }
   return GM_NormalizeLot(symbol, lot);
}

// Spread actual en puntos
int GM_GetSpread(string symbol) {
   return (int)SymbolInfoInteger(symbol, SYMBOL_SPREAD);
}

// ATR del símbolo y período
double GM_GetATR(int handle, int shift=1) {
   double buf[1];
   if(CopyBuffer(handle, 0, shift, 1, buf) < 1) return 0;
   return buf[0];
}

// EMA value
double GM_GetEMA(int handle, int shift=1) {
   double buf[1];
   if(CopyBuffer(handle, 0, shift, 1, buf) < 1) return 0;
   return buf[0];
}

// Log unificado del sistema
void GM_Log(string module, string msg, bool verbose=true) {
   if(!verbose) return;
   PrintFormat("[GoldMaster][%s] %s", module, msg);
}

// Dibuja texto en el chart
void GM_DrawText(string name, datetime t, double price, string txt, color col, int fontsize=9, bool above=true) {
   if(ObjectFind(0, name) >= 0) return;
   ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetString(0, name, OBJPROP_TEXT, " " + txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontsize);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, above ? ANCHOR_LOWER : ANCHOR_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

// Dibuja línea horizontal
void GM_DrawHLine(string name, double price, color col, ENUM_LINE_STYLE style=STYLE_DASH, int width=1) {
   if(ObjectFind(0, name) >= 0) { ObjectSetDouble(0, name, OBJPROP_PRICE, price); return; }
   ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

// Dibuja rectángulo (zona)
void GM_DrawRect(string name, datetime t1, double p1, datetime t2, double p2, color col, bool fill=true) {
   ObjectDelete(0, name);
   if(ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2)) {
      ObjectSetInteger(0, name, OBJPROP_COLOR,   col);
      ObjectSetInteger(0, name, OBJPROP_BACK,    true);
      ObjectSetInteger(0, name, OBJPROP_FILL,    fill);
      ObjectSetInteger(0, name, OBJPROP_STYLE,   STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }
}

// v3.1: Nombre del régimen de volatilidad
string GM_VolatilityName(ENUM_GM_VOLATILITY v) {
   switch(v) {
      case GM_VOL_LOW:    return "Bajo (Rango)";
      case GM_VOL_HIGH:   return "Alto (Expansión)";
      default:            return "Normal (Tendencia)";
   }
}

// v3.1: Resumen string del sesgo multi-TF
string GM_MTFBiasStr(GMMTFBias &b) {
   string htf_s = (b.bias_htf== 1)?"↑":(b.bias_htf==-1)?"↓":"→";
   string mtf_s = (b.bias_mtf== 1)?"↑":(b.bias_mtf==-1)?"↓":"→";
   string ltf_s = (b.bias_ltf== 1)?"↑":(b.bias_ltf==-1)?"↓":"→";
   return StringFormat("H4:%s H1:%s M15:%s [%d/3]", htf_s, mtf_s, ltf_s, b.confluence);
}

#endif
