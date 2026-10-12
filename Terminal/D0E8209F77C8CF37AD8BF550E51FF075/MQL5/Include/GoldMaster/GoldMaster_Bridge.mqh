//+──────────────────────────────────────────────────────────────────────────+
//│  GOLD MASTER — Bridge v4.0  (EA ⇄ Python Dashboard/Intel)               │
//│  Common\Files\GoldMaster\                                                │
//│    intel.txt     Py→EA  key=value (sentimiento, flow, COT, noticias)     │
//│    commands.csv  Py→EA  id,cmd,arg1,arg2                                 │
//│    ea_state.txt  EA→Py  heartbeat + estado                               │
//+──────────────────────────────────────────────────────────────────────────+
#ifndef GOLDMASTER_BRIDGE_MQH
#define GOLDMASTER_BRIDGE_MQH
#include "GoldMaster_Core.mqh"

struct GMIntel {
   string   symbol;
   long     ts;
   double   sentiment, cot_index, cot_bias, delta_z, vpin, whale_bias, flow_bias;
   double   vwap, vwap_z, poc, vah, val, hurst, composite, risk_mult, dxy, dxy_chg24, dxy_corr;
   int      dxy_bias;
   int      block_trading, next_news_secs;
   string   regime, next_news;
   bool     valid;
   int dxy_shock; double micro_bias; int override_on; int auto_trade;
   int gov_block; double port_risk_pct; double vol_fcst; double macro_bias; double hour_edge_z; string regime_q;
};

struct GMCommand { long id; string cmd; string a1; string a2; };

class CGMBridge {
private:
   string  m_dir;
   GMIntel m_intel;
   long    m_last_cmd;
   bool    m_paused;
   int     m_max_age;
   datetime m_last_read;

   int OpenR(string f) { return FileOpen(m_dir+f, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE); }

public:
   CGMBridge() { m_dir="GoldMaster\\"; m_last_cmd=0; m_paused=false; m_max_age=120; m_last_read=0; ZeroMemory(m_intel); m_intel.risk_mult=1.0; }

   void Init(int max_age_s=120) {
      m_max_age = max_age_s;
      // Ignorar comandos viejos: arrancar desde el último id existente
      GMCommand c[]; int n = ReadCommands(c);
      for(int i=0;i<n;i++) if(c[i].id > m_last_cmd) m_last_cmd = c[i].id;
      ReadIntel();
   }

   bool ReadIntel() {
      if(MQLInfoInteger(MQL_TESTER)) { m_intel.valid=false; return false; } // no hay intel histórica
      int fh = OpenR("intel.txt");
      if(fh == INVALID_HANDLE) { m_intel.valid=false; return false; }
      GMIntel x; ZeroMemory(x); x.risk_mult=1.0; x.next_news_secs=-1;
      while(!FileIsEnding(fh)) {
         string line = FileReadString(fh);
         int p = StringFind(line, "=");
         if(p <= 0) continue;
         string k = StringSubstr(line, 0, p), v = StringSubstr(line, p+1);
         double d = StringToDouble(v);
         if     (k=="ts")             x.ts = (long)StringToInteger(v);
         else if(k=="symbol")         x.symbol = v;
         else if(k=="sentiment")      x.sentiment = d;
         else if(k=="cot_index")      x.cot_index = d;
         else if(k=="cot_bias")       x.cot_bias = d;
         else if(k=="delta_z")        x.delta_z = d;
         else if(k=="vpin")           x.vpin = d;
         else if(k=="whale_bias")     x.whale_bias = d;
         else if(k=="flow_bias")      x.flow_bias = d;
         else if(k=="vwap")           x.vwap = d;
         else if(k=="vwap_z")         x.vwap_z = d;
         else if(k=="poc")            x.poc = d;
         else if(k=="vah")            x.vah = d;
         else if(k=="val")            x.val = d;
         else if(k=="hurst")          x.hurst = d;
         else if(k=="composite")      x.composite = d;
         else if(k=="risk_mult")      x.risk_mult = d;
         else if(k=="block_trading")  x.block_trading = (int)StringToInteger(v);
         else if(k=="next_news_secs") x.next_news_secs = (int)StringToInteger(v);
         else if(k=="dxy")            x.dxy = d;
         else if(k=="dxy_chg24")      x.dxy_chg24 = d;
         else if(k=="dxy_corr")       x.dxy_corr = d;
         else if(k=="dxy_bias")       x.dxy_bias = (int)StringToInteger(v);
         else if(k=="regime")         x.regime = v;
         else if(k=="auto_trade")     x.auto_trade = (int)StringToInteger(v);
         else if(k=="override")       x.override_on = (int)StringToInteger(v);
         else if(k=="dxy_shock")      x.dxy_shock = (int)StringToInteger(v);
         else if(k=="micro_bias")     x.micro_bias = d;
         else if(k=="gov_block")      x.gov_block = (int)StringToInteger(v);
         else if(k=="port_risk_pct")  x.port_risk_pct = d;
         else if(k=="vol_fcst")       x.vol_fcst = d;
         else if(k=="macro_bias")     x.macro_bias = d;
         else if(k=="hour_edge_z")    x.hour_edge_z = d;
         else if(k=="regime_q")       x.regime_q = v;
         else if(k=="next_news")      x.next_news = v;
      }
      FileClose(fh);
      long age = (long)TimeGMT() - x.ts;
      x.valid = (x.ts > 0 && age >= -2 && age <= m_max_age && x.symbol==_Symbol);
      m_intel = x;
      m_last_read = TimeLocal();
      return x.valid;
   }

   int ReadCommands(GMCommand &out[]) {
      ArrayResize(out, 0);
      int fh = FileOpen(m_dir+"commands.csv", FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE, ',');
      if(fh == INVALID_HANDLE) return 0;
      int n = 0;
      while(!FileIsEnding(fh) && n < 5000) {
         GMCommand c;
         c.id  = (long)StringToInteger(FileReadString(fh));
         c.cmd = FileReadString(fh);
         c.a1  = FileReadString(fh);
         c.a2  = FileReadString(fh);
         if(c.id <= 0) continue;
         ArrayResize(out, n+1); out[n++] = c;
      }
      FileClose(fh);
      return n;
   }

   // Devuelve sólo comandos nuevos
   int PollNew(GMCommand &out[]) {
      GMCommand all[]; int n = ReadCommands(all);
      ArrayResize(out, 0); int k = 0;
      for(int i=0;i<n;i++) if(all[i].id > m_last_cmd) {
         ArrayResize(out, k+1); out[k++] = all[i]; m_last_cmd = all[i].id;
         if(all[i].cmd=="PAUSE")  m_paused = true;
         if(all[i].cmd=="RESUME") m_paused = false;
      }
      return k;
   }

   void WriteState(string status, int positions, int pending, int bull, int bear) {
      int fh = FileOpen(m_dir+"ea_state.txt", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ);
      if(fh == INVALID_HANDLE) return;
      FileWriteString(fh, "ts="+IntegerToString((long)TimeGMT())+"\n");
      FileWriteString(fh, "status="+(m_paused?"PAUSED":status)+"\n");
      FileWriteString(fh, "positions="+IntegerToString(positions)+"\n");
      FileWriteString(fh, "pending="+IntegerToString(pending)+"\n");
      FileWriteString(fh, "equity="+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2)+"\n");
      FileWriteString(fh, "bull_score="+IntegerToString(bull)+"\n");
      FileWriteString(fh, "bear_score="+IntegerToString(bear)+"\n");
      FileWriteString(fh, "last_cmd="+IntegerToString(m_last_cmd)+"\n");
      FileWriteString(fh, "intel_valid="+(m_intel.valid?"1":"0")+"\n");
      FileClose(fh);
   }

   bool    IsPaused()     { return m_paused; }
   bool    Valid()        { long age=(long)TimeGMT()-m_intel.ts;
                           return m_intel.valid && m_intel.symbol==_Symbol && age>=-2 && age<=m_max_age; }
   GMIntel Data()         { return m_intel; }
   bool    AutoTrade()    { return Valid() && m_intel.auto_trade==1; }
   GMIntel Intel()        { return m_intel; }
   bool    BlockTrading() { if(MQLInfoInteger(MQL_TESTER)) return false; return !Valid() || m_intel.block_trading==1; }
   double  RiskMult()     { if(MQLInfoInteger(MQL_TESTER)) return 1.0;
                           return Valid() ? MathMax(0.0, MathMin(1.0, m_intel.risk_mult)) : 0.0; }
   double  Composite()    { return Valid() ? m_intel.composite : 0.0; }
   string  Status() {
      if(!m_intel.valid) return "INTEL: sin datos";
      return StringFormat("INTEL comp:%+.2f sent:%+.2f flow:%+.2f VPIN:%.2f H:%.2f %s | news:%s en %dm",
         m_intel.composite, m_intel.sentiment, m_intel.flow_bias, m_intel.vpin, m_intel.hurst,
         m_intel.regime, m_intel.next_news, m_intel.next_news_secs/60);
   }
};
#endif
