//+------------------------------------------------------------------+
//|  GoldMaster_DXY.mqh — Índice del Dólar (DXY) para el sistema     |
//|  1) Si el broker tiene el índice (USDX, DXY, DX, USDIndex…) lo usa|
//|  2) Si no (caso Deriv), lo SINTETIZA con la fórmula oficial ICE:  |
//|     DXY = 50.14348112 × EURUSD^-0.576 × USDJPY^0.136 ×            |
//|           GBPUSD^-0.119 × USDCAD^0.091 × USDSEK^0.042 ×           |
//|           USDCHF^0.036                                            |
//|     Detecta sufijos del broker (EURUSD.m, EURUSDm, frxEURUSD…).   |
//|  El oro suele moverse INVERSO al dólar: DXY↑ → presión bajista.   |
//+------------------------------------------------------------------+
#ifndef GOLDMASTER_DXY_MQH
#define GOLDMASTER_DXY_MQH

class CGMDXY {
private:
   string m_direct;          // símbolo directo si existe
   string m_pair[6];
   double m_w[6];
   bool   m_ok[6];
   bool   m_ready;
   string m_mode;

   string Resolve(string base) {
      string cands[6];
      cands[0]=base; cands[1]=base+".m"; cands[2]=base+"m"; cands[3]="frx"+base; cands[4]=base+".r"; cands[5]=base+"+";
      for(int i=0;i<6;i++) if(SymbolSelect(cands[i],true)) { double c[]; if(CopyClose(cands[i],PERIOD_H1,0,1,c)>0) return cands[i]; }
      // búsqueda amplia: cualquier símbolo que contenga el par
      for(int i=0;i<SymbolsTotal(false);i++) {
         string s=SymbolName(i,false);
         if(StringFind(s,base)>=0 && SymbolSelect(s,true)) { double c[]; if(CopyClose(s,PERIOD_H1,0,1,c)>0) return s; }
      }
      return "";
   }

public:
   CGMDXY() { m_ready=false; m_direct=""; m_mode="N/A"; }

   bool Init() {
      // DXYUSD primero: Deriv lo tiene bajo Índices como DXYUSD (USD Index)
      string direct[] = {"DXYUSD","USDX","DXY","DX","USDIndex","USDOLLAR","DOLLAR.IDX","DXY.cash"};
      for(int i=0;i<ArraySize(direct);i++)
         if(SymbolSelect(direct[i],true)) { double c[]; if(CopyClose(direct[i],PERIOD_H1,0,1,c)>0) { m_direct=direct[i]; m_ready=true; m_mode="directo "+m_direct; return true; } }
      string base[6] = {"EURUSD","USDJPY","GBPUSD","USDCAD","USDSEK","USDCHF"};
      double w[6]    = {-0.576, 0.136, -0.119, 0.091, 0.042, 0.036};
      int found=0;
      for(int i=0;i<6;i++) { m_pair[i]=Resolve(base[i]); m_w[i]=w[i]; m_ok[i]=(m_pair[i]!=""); if(m_ok[i]) found++; }
      // EURUSD, USDJPY y GBPUSD son imprescindibles (≈83% del peso)
      m_ready = m_ok[0] && m_ok[1] && m_ok[2];
      m_mode  = m_ready ? StringFormat("sintético (%d/6 pares)", found) : "N/A (faltan pares)";
      return m_ready;
   }

   bool   Ready() { return m_ready; }
   string Mode()  { return m_mode; }

   // Valor del DXY en la vela 'shift' de 'tf'
   double Value(ENUM_TIMEFRAMES tf=PERIOD_H1, int shift=0) {
      if(!m_ready) return 0;
      if(m_direct!="") { double c[]; return CopyClose(m_direct,tf,shift,1,c)>0 ? c[0] : 0; }
      datetime t = iTime(m_pair[0], tf, shift);
      double v = 50.14348112, wsum = 0;
      for(int i=0;i<6;i++) {
         if(!m_ok[i]) continue;
         int b = iBarShift(m_pair[i], tf, t, false);
         double c[]; if(b<0 || CopyClose(m_pair[i],tf,b,1,c)<=0 || c[0]<=0) return 0;
         v *= MathPow(c[0], m_w[i]); wsum += MathAbs(m_w[i]);
      }
      return v;
   }

   int Series(ENUM_TIMEFRAMES tf, int n, double &out[]) {
      ArrayResize(out, n); ArraySetAsSeries(out, true);
      for(int i=0;i<n;i++) { out[i]=Value(tf,i); if(out[i]<=0) { ArrayResize(out,i); return i; } }
      return n;
   }

   // % de cambio en las últimas 'bars' velas
   double ChangePct(ENUM_TIMEFRAMES tf=PERIOD_H1, int bars=24) {
      double a=Value(tf,0), b=Value(tf,bars);
      return (a>0 && b>0) ? (a/b-1.0)*100.0 : 0;
   }

   // Tendencia: EMA rápida vs lenta del DXY → 1 dólar fuerte, -1 dólar débil, 0 neutro
   int Trend(ENUM_TIMEFRAMES tf=PERIOD_H1, int fast=20, int slow=50) {
      double s[]; int n=Series(tf, slow*3, s);
      if(n < slow+5) return 0;
      double kf=2.0/(fast+1), ks=2.0/(slow+1), ef=s[n-1], es=s[n-1];
      for(int i=n-2;i>=0;i--) { ef=s[i]*kf+ef*(1-kf); es=s[i]*ks+es*(1-ks); }
      double gap=(ef-es)/es*100.0;
      return gap>0.03 ? 1 : gap<-0.03 ? -1 : 0;
   }

   // Correlación de retornos DXY vs símbolo (normalmente negativa con el oro)
   double Correlation(string sym, ENUM_TIMEFRAMES tf=PERIOD_H1, int n=60) {
      double d[]; int m=Series(tf, n+1, d);
      double g[]; ArraySetAsSeries(g,true);
      if(m<n+1 || CopyClose(sym,tf,0,n+1,g)<n+1) return 0;
      double sx=0,sy=0,sxx=0,syy=0,sxy=0;
      for(int i=0;i<n;i++) {
         double x=d[i]/d[i+1]-1, y=g[i]/g[i+1]-1;
         sx+=x; sy+=y; sxx+=x*x; syy+=y*y; sxy+=x*y;
      }
      double cov=sxy/n-sx/n*sy/n, vx=sxx/n-MathPow(sx/n,2), vy=syy/n-MathPow(sy/n,2);
      return (vx>0&&vy>0) ? cov/MathSqrt(vx*vy) : 0;
   }

   // Sesgo para el ORO: -Trend del DXY (sólo si la correlación es negativa)
   int GoldBias(string gold_sym, ENUM_TIMEFRAMES tf=PERIOD_H1) {
      int t=Trend(tf);
      double c=Correlation(gold_sym, tf);
      if(c > -0.2) return 0;     // correlación débil → el DXY no está mandando
      return -t;
   }
};
#endif
