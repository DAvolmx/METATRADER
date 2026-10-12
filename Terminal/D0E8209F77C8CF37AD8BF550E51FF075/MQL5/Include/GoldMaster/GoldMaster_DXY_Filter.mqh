//+------------------------------------------------------------------+
//| GoldMaster_DXY_Filter.mqh                                        |
//| Módulo DXY — lee dxy_bias desde gm_state.json (escrito por       |
//| gm_bridge.py / gm_dxy.py con DXYEngine.summary()).               |
//| Expone:                                                           |
//|   DXYBias()      → -1 (dólar sube→oro baja), 0 (neutro), +1     |
//|   DXYVeto(dir)   → true si la dirección está bloqueada por DXY   |
//|   DXYRealYield() → rendimiento real 10y (DFII10 FRED)            |
//|   DXYMode()      → string con fuente del dato                    |
//+------------------------------------------------------------------+
#ifndef GOLDMASTER_DXY_FILTER_MQH
#define GOLDMASTER_DXY_FILTER_MQH

class CGMDXYFilter {
private:
   string   m_state_path;
   datetime m_last_read;
   int      m_max_age_secs;
   int      m_bias;          // -1 / 0 / +1
   int      m_ry_bias;       // rendimiento real: -1/0/+1
   double   m_dxy_val;
   double   m_dxy_chg24;
   double   m_real_yield;
   string   m_mode;
   bool     m_enabled;

   // ── lee JSON mínimo: busca campo entre comillas
   double   _field(const string &js, const string key) {
      string tok = "\"" + key + "\":";
      int p = StringFind(js, tok);
      if(p < 0) return 0.0;
      p += StringLen(tok);
      while(p < StringLen(js) && (StringGetCharacter(js,p)==' ' || StringGetCharacter(js,p)=='"')) p++;
      string num = "";
      for(int i=p; i<StringLen(js); i++) {
         ushort c = StringGetCharacter(js,i);
         if(c==','||c=='}'||c=='"') break;
         num += ShortToString(c);
      }
      return StringToDouble(num);
   }
   string   _sfield(const string &js, const string key) {
      string tok = "\"" + key + "\":\"";
      int p = StringFind(js, tok);
      if(p < 0) return "N/A";
      p += StringLen(tok);
      string val = "";
      for(int i=p; i<StringLen(js); i++) {
         ushort c = StringGetCharacter(js,i);
         if(c=='"') break;
         val += ShortToString(c);
      }
      return val;
   }

   void _refresh() {
      datetime now = TimeCurrent();
      if(now - m_last_read < m_max_age_secs) return;
      m_last_read = now;
      int fh = FileOpen(m_state_path, FILE_READ|FILE_TXT|FILE_ANSI);
      if(fh == INVALID_HANDLE) { m_bias = 0; return; }
      string js = "";
      while(!FileIsEnding(fh)) js += FileReadString(fh);
      FileClose(fh);
      // leer los campos dxy del JSON generado por gm_bridge.py
      m_dxy_val    = _field(js, "dxy");
      m_dxy_chg24  = _field(js, "dxy_chg24");
      m_real_yield = _field(js, "real_yield");
      m_ry_bias    = (int)_field(js, "ry_bias");
      m_mode       = _sfield(js, "dxy_mode");
      // dxy_bias: -1=dólar sube→filtrar longs oro, +1=dólar baja→filtrar shorts oro
      // gm_dxy.py calcula: bias = -trend si corr < -0.2 else 0
      // trend=+1 cuando DXY sube → bias=-1
      m_bias = (int)_field(js, "dxy_bias");
   }

public:
   CGMDXYFilter() : m_bias(0), m_ry_bias(0), m_dxy_val(0), m_dxy_chg24(0),
                    m_real_yield(0), m_last_read(0), m_max_age_secs(60),
                    m_mode("N/A"), m_enabled(true) {}

   void Init(const string state_json_path, int max_age_secs=60, bool enabled=true) {
      m_state_path    = state_json_path;
      m_max_age_secs  = max_age_secs;
      m_enabled       = enabled;
   }

   // ── API pública ──────────────────────────────────────────────
   int    DXYBias()        { if(!m_enabled) return 0; _refresh(); return m_bias; }
   int    RealYieldBias()  { if(!m_enabled) return 0; _refresh(); return m_ry_bias; }
   double DXYValue()       { _refresh(); return m_dxy_val; }
   double DXYChg24h()      { _refresh(); return m_dxy_chg24; }
   double RealYield()      { _refresh(); return m_real_yield; }
   string Mode()           { _refresh(); return m_mode; }

   // DXYVeto: devuelve true si la dirección está contra el sesgo del dólar
   //   dir = +1 (BUY) bloqueado si DXY sube (bias=-1)
   //   dir = -1 (SELL) bloqueado si DXY baja (bias=+1)
   bool DXYVeto(int dir) {
      if(!m_enabled) return false;
      _refresh();
      if(m_bias == 0) return false;
      // dólar sube → bias=-1 → vetamos BUY (dir=+1)
      if(m_bias == -1 && dir == 1)  return true;
      // dólar baja → bias=+1 → vetamos SELL (dir=-1)
      if(m_bias ==  1 && dir == -1) return true;
      return false;
   }

   // Ajuste de score: DXY confirma → +1pt, DXY contra → -1pt
   int ScoreAdjust(int dir) {
      if(!m_enabled || m_bias==0) return 0;
      return (m_bias == dir) ? 1 : -1;
   }

   // Resumen para log
   string Summary() {
      _refresh();
      return StringFormat("DXY=%.3f chg24=%.3f%% bias=%+d RY=%.2f%% ry_bias=%+d [%s]",
         m_dxy_val, m_dxy_chg24, m_bias, m_real_yield, m_ry_bias, m_mode);
   }
};

#endif
