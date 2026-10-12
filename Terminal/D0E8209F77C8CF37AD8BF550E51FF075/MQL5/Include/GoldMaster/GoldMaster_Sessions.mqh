//+------------------------------------------------------------------+
//| GoldMaster_Sessions.mqh                                          |
//| Sesiones de mercado + Rango Asiático como zona de liquidez       |
//| Extraído y refinado de HUGO.mq5 / HUGOx.mq5                     |
//|                                                                  |
//| Sesiones (hora servidor GMT/UTC Deriv):                          |
//|   Asia:     00:00 – 08:00   (liquidez, no operar por defecto)   |
//|   London:   07:00 – 12:00   (alta volatilidad, alta prioridad)  |
//|   Overlap:  12:00 – 15:00   (London + NY simultáneo, máx vola)  |
//|   NY:       15:00 – 20:00   (alta volatilidad)                  |
//|   Dead:     20:00 – 23:59   (evitar)                            |
//|                                                                  |
//| El rango asiático (high/low de 00:00-08:00) se usa como:        |
//|   - Zona de liquidez objetivo (precio busca ese rango)           |
//|   - Breakout del rango al inicio de London = señal fuerte        |
//+------------------------------------------------------------------+
#ifndef GOLDMASTER_SESSIONS_MQH
#define GOLDMASTER_SESSIONS_MQH

enum GMSession {
   GMG_SESSION_ASIA    = 0,
   GMG_SESSION_LONDON  = 1,
   GMG_SESSION_OVERLAP = 2,
   GMG_SESSION_NY      = 3,
   GMG_SESSION_DEAD    = 4
};

class CGMSessions {
private:
   string   m_symbol;
   int      m_gmt_offset;    // offset servidor vs UTC (horas) — Deriv = 0
   int      m_asia_start;    // hora inicio Asia (default 0)
   int      m_asia_end;      // hora fin Asia (default 8)
   int      m_london_start;  // 7
   int      m_london_end;    // 12
   int      m_overlap_start; // 12
   int      m_overlap_end;   // 15
   int      m_ny_start;      // 15
   int      m_ny_end;        // 20

   // Rango asiático calculado al inicio de London
   double   m_asian_high;
   double   m_asian_low;
   datetime m_asian_range_day;  // día para el que está calculado
   bool     m_asian_range_valid;

   // Recalcula el rango asiático del día actual
   void _calcAsianRange() {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      datetime today = StringToTime(StringFormat("%04d.%02d.%02d 00:00:00",
                                                  dt.year, dt.mon, dt.day));
      if(m_asian_range_day == today && m_asian_range_valid) return;

      // Barras entre 00:00 y 08:00 del día actual en M15
      datetime t_start = today + m_asia_start * 3600;
      datetime t_end   = today + m_asia_end   * 3600;

      MqlRates rates[];
      int copied = CopyRates(m_symbol, PERIOD_M15, t_start, t_end, rates);
      if(copied <= 0) { m_asian_range_valid = false; return; }

      double hi = rates[0].high, lo = rates[0].low;
      for(int i=1; i<copied; i++) {
         if(rates[i].high > hi) hi = rates[i].high;
         if(rates[i].low  < lo) lo = rates[i].low;
      }
      m_asian_high        = hi;
      m_asian_low         = lo;
      m_asian_range_day   = today;
      m_asian_range_valid = (hi > lo);
   }

   int _serverHour() {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      return dt.hour;
   }

public:
   CGMSessions() : m_symbol(_Symbol), m_gmt_offset(0),
                   m_asia_start(0), m_asia_end(8),
                   m_london_start(7), m_london_end(12),
                   m_overlap_start(12), m_overlap_end(15),
                   m_ny_start(15), m_ny_end(20),
                   m_asian_high(0), m_asian_low(0),
                   m_asian_range_day(0), m_asian_range_valid(false) {}

   void Init(const string symbol, int gmt_offset=0,
             int asia_start=0,    int asia_end=8,
             int london_start=7,  int london_end=12,
             int overlap_start=12,int overlap_end=15,
             int ny_start=15,     int ny_end=20) {
      m_symbol        = symbol;
      m_gmt_offset    = gmt_offset;
      m_asia_start    = asia_start;
      m_asia_end      = asia_end;
      m_london_start  = london_start;
      m_london_end    = london_end;
      m_overlap_start = overlap_start;
      m_overlap_end   = overlap_end;
      m_ny_start      = ny_start;
      m_ny_end        = ny_end;
   }

   // ── Sesión actual ──────────────────────────────────────────────
   GMSession CurrentSession() {
      int h = _serverHour();
      if(h >= m_overlap_start && h < m_overlap_end) return GMG_SESSION_OVERLAP;
      if(h >= m_london_start  && h < m_london_end)  return GMG_SESSION_LONDON;
      if(h >= m_ny_start      && h < m_ny_end)      return GMG_SESSION_NY;
      if(h >= m_asia_start    && h < m_asia_end)    return GMG_SESSION_ASIA;
      return GMG_SESSION_DEAD;
   }

   string SessionName(GMSession s = GMG_SESSION_DEAD) {
      GMSession cur = (s == GMG_SESSION_DEAD) ? CurrentSession() : s;
      switch(cur) {
         case GMG_SESSION_ASIA:    return "ASIA";
         case GMG_SESSION_LONDON:  return "LONDON";
         case GMG_SESSION_OVERLAP: return "OVERLAP";
         case GMG_SESSION_NY:      return "NY";
         default:                 return "DEAD";
      }
   }

   // ── Filtros de operar ─────────────────────────────────────────
   bool IsHighValueSession() {
      GMSession s = CurrentSession();
      return (s == GMG_SESSION_LONDON || s == GMG_SESSION_OVERLAP || s == GMG_SESSION_NY);
   }
   bool IsLondon()  { return CurrentSession() == GMG_SESSION_LONDON; }
   bool IsOverlap() { return CurrentSession() == GMG_SESSION_OVERLAP; }
   bool IsNY()      { return CurrentSession() == GMG_SESSION_NY; }
   bool IsAsia()    { return CurrentSession() == GMG_SESSION_ASIA; }

   // Peso de sesión para scoring (0.5 = sesión menor, 1.0 = normal, 1.5 = overlap)
   double SessionWeight() {
      switch(CurrentSession()) {
         case GMG_SESSION_OVERLAP: return 1.5;
         case GMG_SESSION_LONDON:
         case GMG_SESSION_NY:      return 1.0;
         case GMG_SESSION_ASIA:    return 0.5;
         default:                 return 0.0;
      }
   }

   // Puntos de confluencia que aporta la sesión al score general
   int SessionScore() {
      switch(CurrentSession()) {
         case GMG_SESSION_OVERLAP: return 2;  // máx valor
         case GMG_SESSION_LONDON:
         case GMG_SESSION_NY:      return 1;
         default:                 return 0;
      }
   }

   // ── Rango asiático ────────────────────────────────────────────
   void UpdateAsianRange()    { _calcAsianRange(); }
   bool  AsianRangeValid()    { return m_asian_range_valid; }
   double AsianHigh()         { return m_asian_high; }
   double AsianLow()          { return m_asian_low; }
   double AsianMid()          { return (m_asian_high + m_asian_low) / 2.0; }
   double AsianRangeSize()    { return m_asian_high - m_asian_low; }

   // ¿El precio está dentro del rango asiático? (zona de liquidez)
   bool InAsianRange(double price, double buffer_atr=0) {
      if(!m_asian_range_valid) return false;
      return (price >= m_asian_low  - buffer_atr &&
              price <= m_asian_high + buffer_atr);
   }

   // ¿Breakout del rango asiático? Señal de expansión (fuerte al inicio de London)
   bool AsianBreakout(double price, int dir) {
      if(!m_asian_range_valid) return false;
      if(dir ==  1) return price > m_asian_high;
      if(dir == -1) return price < m_asian_low;
      return false;
   }

   // Distancia a la zona más cercana del rango asiático (en puntos)
   double DistToAsianRange(double price) {
      if(!m_asian_range_valid) return DBL_MAX;
      if(price > m_asian_high) return (price - m_asian_high) / _Point;
      if(price < m_asian_low)  return (m_asian_low - price)  / _Point;
      return 0;
   }

   string Summary() {
      _calcAsianRange();
      return StringFormat("Sesión: %s | Asian H=%.3f L=%.3f rango=%.0f pts [%s]",
         SessionName(), m_asian_high, m_asian_low,
         AsianRangeSize()/_Point,
         m_asian_range_valid ? "OK" : "N/A");
   }
};

#endif
