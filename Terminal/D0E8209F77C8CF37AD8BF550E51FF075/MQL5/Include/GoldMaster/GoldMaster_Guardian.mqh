//+──────────────────────────────────────────────────────────────────────────+
//│  GOLD MASTER — Guardian v1.0  (gobernador de riesgo DENTRO del EA)         │
//│  Hace cumplir en MT5 lo que gm_guardian.py evalúa: escalera de capital,    │
//│  riesgo %/op, objetivo y stop diarios, máx. operaciones/día, bloqueo por   │
//│  régimen "agitado", noticias y spread, y SUELO de lote mínimo.             │
//│                                                                            │
//│  El EA llama a CanTrade(...) ANTES de cada orden. Si allow=false, NO opera.│
//│  Opcional: lee límites actualizados de Common\Files\GoldMaster\guardian.txt│
//│  (key=value) que escribe gm_live_api/gm_bridge; si no, usa los de abajo.   │
//+──────────────────────────────────────────────────────────────────────────+
#ifndef GOLDMASTER_GUARDIAN_MQH
#define GOLDMASTER_GUARDIAN_MQH

struct GMStage { double from, to, risk_pct, daily_target, daily_loss; int max_trades; };

struct GMGuardDecision {
   bool   allow;
   string reason;
   double lot;
   double risk_usd;
   double risk_pct;
   int    score;
};

class CGMGuardian {
private:
   GMStage m_stages[3];
   int     m_news_blackout_min;
   double  m_max_spread_points;
   double  m_max_risk_frac;        // si ni el lote mínimo cabe bajo esto -> bloquea
   // estado diario
   datetime m_day;
   double   m_day_pnl;
   int      m_day_trades;

   GMStage StageFor(double eq) {
      for(int i=0;i<3;i++) if(eq>=m_stages[i].from && eq<m_stages[i].to) return m_stages[i];
      return m_stages[2];
   }
   void RollDay() {
      datetime d = (datetime)(TimeCurrent()/86400*86400);
      if(d!=m_day){ m_day=d; m_day_pnl=0; m_day_trades=0; }
   }
   double ReadKV(string file,string key,double def) {
      int fh=FileOpen(file,FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(fh==INVALID_HANDLE) return def;
      double v=def;
      while(!FileIsEnding(fh)){ string ln=FileReadString(fh); int p=StringFind(ln,"=");
         if(p>0 && StringSubstr(ln,0,p)==key){ v=StringToDouble(StringSubstr(ln,p+1)); break; } }
      FileClose(fh); return v;
   }

public:
   CGMGuardian() {
      // Escalera por defecto (idéntica a gm_capital): semilla / construir / acelerar
      m_stages[0].from=0;   m_stages[0].to=25;  m_stages[0].risk_pct=3.0; m_stages[0].daily_target=2;  m_stages[0].daily_loss=1.5; m_stages[0].max_trades=3;
      m_stages[1].from=25;  m_stages[1].to=50;  m_stages[1].risk_pct=3.5; m_stages[1].daily_target=4;  m_stages[1].daily_loss=2.5; m_stages[1].max_trades=4;
      m_stages[2].from=50;  m_stages[2].to=1e12;m_stages[2].risk_pct=6.0; m_stages[2].daily_target=12; m_stages[2].daily_loss=8;   m_stages[2].max_trades=6;
      m_news_blackout_min=30; m_max_spread_points=600; m_max_risk_frac=0.5;
      m_day=0; m_day_pnl=0; m_day_trades=0;
   }

   // Llamar al cerrar cada operación para actualizar contadores diarios.
   void RegisterResult(double pnl_usd){ RollDay(); m_day_pnl+=pnl_usd; m_day_trades++; }

   // Permite sobrescribir límites desde el puente (si existe guardian.txt).
   void SyncFromBridge() {
      string f="GoldMaster\\guardian.txt";
      m_news_blackout_min=(int)ReadKV(f,"news_blackout_min",m_news_blackout_min);
      m_max_spread_points=ReadKV(f,"max_spread_points",m_max_spread_points);
      m_max_risk_frac=ReadKV(f,"max_risk_frac",m_max_risk_frac);
   }

   //--- DECISIÓN: ¿se puede operar y con qué lote? -------------------------------
   // equity        : AccountInfoDouble(ACCOUNT_EQUITY)
   // stop_price    : distancia del SL en PRECIO (p.ej. 1.2*ATR)
   // usd_per_price : USD por 1.0 de precio por 1.0 lote (XAUUSDmicro=1.0, XAUUSD=100)
   // min_lot       : SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN)
   // regime_agitado: 1 si el régimen es "agitado" (del intel), 0 si no
   // near_news_min : minutos a la próxima noticia alto impacto (-1 si ninguna)
   // spread_points : spread actual en puntos
   GMGuardDecision CanTrade(double equity,double stop_price,double usd_per_price,double min_lot,
                            int regime_agitado,int near_news_min,double spread_points) {
      GMGuardDecision d; d.allow=false; d.lot=0; d.risk_usd=0; d.risk_pct=0; d.score=50;
      RollDay();
      GMStage s=StageFor(equity);
      if(MQLInfoInteger(MQL_TESTER)==false) SyncFromBridge();

      if(stop_price<=0){ d.reason="stop invalido"; return d; }
      if(m_day_trades>=s.max_trades){ d.reason="tope diario de operaciones"; return d; }
      if(m_day_pnl>=s.daily_target){ d.reason="objetivo diario alcanzado - guarda y para"; return d; }
      if(m_day_pnl<=-s.daily_loss){ d.reason="stop diario alcanzado - proteccion"; return d; }
      if(regime_agitado==1){ d.reason="regimen agitado bloqueado"; return d; }
      if(near_news_min>=0 && near_news_min<=m_news_blackout_min){ d.reason="noticia inminente (blackout)"; return d; }
      if(spread_points>m_max_spread_points){ d.reason="spread demasiado alto"; return d; }

      double want_risk = s.risk_pct/100.0*equity;
      double min_risk  = min_lot*stop_price*usd_per_price;
      if(min_risk > m_max_risk_frac*equity){
         d.reason=StringFormat("ni el lote minimo cabe (arriesga %.2f > %.0f%% de %.2f): usa cuenta cent o mas capital",
                               min_risk, m_max_risk_frac*100, equity);
         return d;
      }
      double lot = MathMax(min_lot, MathRound(want_risk/(stop_price*usd_per_price)/min_lot)*min_lot);
      double risk= lot*stop_price*usd_per_price;
      while(risk > m_max_risk_frac*equity && lot>min_lot){ lot-=min_lot; risk=lot*stop_price*usd_per_price; }

      d.allow=true; d.reason="ok"; d.lot=NormalizeDouble(lot,2);
      d.risk_usd=NormalizeDouble(risk,2); d.risk_pct=NormalizeDouble(risk/equity*100,2);
      return d;
   }

   int    DayTrades(){ return m_day_trades; }
   double DayPnL(){ return m_day_pnl; }
   string StageName(double eq){ GMStage s=StageFor(eq); return (eq<25?"semilla":(eq<50?"construir":"acelerar")); }
};

#endif
