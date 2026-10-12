//+------------------------------------------------------------------+
//|  GoldMaster_Structure.mqh — Estructura de mercado SIN repintado  |
//|  Swings (HH/HL/LH/LL) · BOS · CHoCH · Niveles con múltiples toques|
//|  Todos los arrays en orden cronológico (0 = más antiguo).         |
//+------------------------------------------------------------------+
#ifndef GOLDMASTER_STRUCTURE_MQH
#define GOLDMASTER_STRUCTURE_MQH

#define GMS_HH 1
#define GMS_HL 2
#define GMS_LH 3
#define GMS_LL 4

struct GMSSwing { datetime t; double p; bool high; int bar; int label; };
struct GMSEvent { datetime t_swing; datetime t_break; double price; int dir; bool choch; int bar_break; };
struct GMSLevel { double p; int touches; datetime first_t; };

// Swings confirmados con 'strength' velas a cada lado. r[] en orden cronológico.
int GMS_Swings(const MqlRates &r[], int n, int strength, GMSSwing &out[]) {
   ArrayResize(out, 0);
   int cnt=0; double lastH=0, lastL=0;
   for(int i=strength; i<n-strength-1; i++) {        // n-1 = vela en curso → excluida
      bool isH=true, isL=true;
      for(int k=1;k<=strength;k++) {
         if(r[i].high <= r[i-k].high || r[i].high < r[i+k].high) isH=false;
         if(r[i].low  >= r[i-k].low  || r[i].low  > r[i+k].low)  isL=false;
      }
      if(isH) {
         ArrayResize(out,cnt+1);
         out[cnt].t=r[i].time; out[cnt].p=r[i].high; out[cnt].high=true; out[cnt].bar=i;
         out[cnt].label = (lastH==0) ? 0 : (r[i].high>lastH ? GMS_HH : GMS_LH);
         lastH=r[i].high; cnt++;
      }
      if(isL) {
         ArrayResize(out,cnt+1);
         out[cnt].t=r[i].time; out[cnt].p=r[i].low; out[cnt].high=false; out[cnt].bar=i;
         out[cnt].label = (lastL==0) ? 0 : (r[i].low>lastL ? GMS_HL : GMS_LL);
         lastL=r[i].low; cnt++;
      }
   }
   return cnt;
}

// Recorre las velas en orden y detecta rupturas por CIERRE del último swing activo.
// Devuelve nº de eventos; 'trend' queda con la tendencia vigente (1/-1/0).
int GMS_Events(const MqlRates &r[], int n, int strength, const GMSSwing &sw[], int nsw, GMSEvent &ev[], int &trend) {
   ArrayResize(ev,0); trend=0;
   int cnt=0, k=0;
   int aH=-1, aL=-1; bool brokeH=true, brokeL=true;
   for(int i=0;i<n-1;i++) {                          // sólo velas cerradas
      while(k<nsw && sw[k].bar+strength <= i) {      // swing confirmado en esta vela
         if(sw[k].high) { aH=k; brokeH=false; } else { aL=k; brokeL=false; }
         k++;
      }
      if(aH>=0 && !brokeH && r[i].close > sw[aH].p) {
         ArrayResize(ev,cnt+1);
         ev[cnt].t_swing=sw[aH].t; ev[cnt].t_break=r[i].time; ev[cnt].price=sw[aH].p;
         ev[cnt].dir=1; ev[cnt].choch=(trend==-1); ev[cnt].bar_break=i; cnt++;
         trend=1; brokeH=true;
      }
      if(aL>=0 && !brokeL && r[i].close < sw[aL].p) {
         ArrayResize(ev,cnt+1);
         ev[cnt].t_swing=sw[aL].t; ev[cnt].t_break=r[i].time; ev[cnt].price=sw[aL].p;
         ev[cnt].dir=-1; ev[cnt].choch=(trend==1); ev[cnt].bar_break=i; cnt++;
         trend=-1; brokeL=true;
      }
   }
   return cnt;
}

// Agrupa swings en niveles; devuelve sólo los que tienen ≥ min_touches
int GMS_Levels(const GMSSwing &sw[], int nsw, double tol, int min_touches, GMSLevel &out[]) {
   GMSLevel tmp[]; int m=0;
   for(int i=0;i<nsw;i++) {
      int f=-1;
      for(int j=0;j<m;j++) if(MathAbs(tmp[j].p-sw[i].p)<=tol) { f=j; break; }
      if(f<0) { ArrayResize(tmp,m+1); tmp[m].p=sw[i].p; tmp[m].touches=1; tmp[m].first_t=sw[i].t; m++; }
      else { tmp[f].p=(tmp[f].p*tmp[f].touches+sw[i].p)/(tmp[f].touches+1); tmp[f].touches++; }
   }
   ArrayResize(out,0); int c=0;
   for(int j=0;j<m;j++) if(tmp[j].touches>=min_touches) { ArrayResize(out,c+1); out[c]=tmp[j]; c++; }
   return c;
}

// Análisis rápido de un TF: tendencia y último evento
struct GMSState { int trend; int last_dir; bool last_choch; datetime last_t; double last_price; bool ok; };

GMSState GMS_Analyze(string sym, ENUM_TIMEFRAMES tf, int strength, int bars) {
   GMSState s; ZeroMemory(s);
   MqlRates r[]; int n=CopyRates(sym, tf, 0, bars, r);
   if(n < strength*4+10) return s;
   GMSSwing sw[]; int ns=GMS_Swings(r,n,strength,sw);
   GMSEvent ev[]; int tr; int ne=GMS_Events(r,n,strength,sw,ns,ev,tr);
   s.trend=tr; s.ok=true;
   if(ne>0) { s.last_dir=ev[ne-1].dir; s.last_choch=ev[ne-1].choch; s.last_t=ev[ne-1].t_break; s.last_price=ev[ne-1].price; }
   return s;
}

string GMS_EventName(int dir, bool choch) {
   if(dir==0) return "—";
   return (choch?"CHoCH":"BOS") + (dir>0?" ↑":" ↓");
}
string GMS_TrendName(int t) { return t==1?"ALCISTA":t==-1?"BAJISTA":"RANGO"; }

//══════════════════════════════════════════════════════════════════════
//  ORDER BLOCKS (OB) — zona institucional antes de un BOS/CHoCH
//══════════════════════════════════════════════════════════════════════
struct GMOrderBlock {
   int      dir;        // +1 = bullish OB (soporte), -1 = bearish OB (resistencia)
   double   top;        // precio más alto de la vela OB
   double   bot;        // precio más bajo de la vela OB
   double   mid;        // mitad del OB (entrada ideal)
   datetime t;          // tiempo de la vela OB
   int      bar;        // índice en el array rates[]
   bool     mitigated;  // ya fue tocado/roto → OB inválido
   int      touches;    // veces que el precio regresó al OB
};

// Busca los N últimos Order Blocks en un array de rates[]
// Un Bullish OB  = última vela bajista antes de un BOS alcista
// Un Bearish OB  = última vela alcista antes de un BOS bajista
int GMS_OrderBlocks(const MqlRates &r[], int n, int swing_str, GMOrderBlock &out[], int max_ob=6){
   ArrayResize(out,0);
   if(n < swing_str*4+10) return 0;
   GMSSwing sw[]; int ns = GMS_Swings(r, n, swing_str, sw);
   GMSEvent ev[]; int tr; int ne = GMS_Events(r, n, swing_str, sw, ns, ev, tr);
   int cnt = 0;
   for(int i=ne-1; i>=0 && cnt<max_ob; i--){
      int dir = ev[i].dir;                      // dirección del BOS/CHoCH
      int bk  = ev[i].bar_break;                // barra donde rompió
      // Buscar la última vela opuesta antes del breakout = OB
      for(int b=bk-1; b>=MathMax(0,bk-15); b--){
         bool is_opp = (dir>0) ? (r[b].close < r[b].open) : (r[b].close > r[b].open);
         if(is_opp){
            ArrayResize(out, cnt+1);
            out[cnt].dir  = dir;
            out[cnt].top  = MathMax(r[b].open, r[b].close);
            out[cnt].bot  = MathMin(r[b].open, r[b].close);
            out[cnt].mid  = (out[cnt].top + out[cnt].bot) * 0.5;
            out[cnt].t    = r[b].time;
            out[cnt].bar  = b;
            out[cnt].mitigated = false;
            out[cnt].touches   = 0;
            cnt++;
            break;
         }
      }
   }
   // Marcar OBs mitigados (precio cruzó el mid sin respetar)
   double last_close = r[n-1].close;
   for(int i=0; i<cnt; i++){
      if(out[i].dir>0 && last_close < out[i].bot) out[i].mitigated = true;
      if(out[i].dir<0 && last_close > out[i].top) out[i].mitigated = true;
   }
   return cnt;
}

// ¿El precio actual está dentro (o muy cerca) de un OB activo?
// tol = tolerancia en puntos del instrumento
bool GMS_InOrderBlock(double price, const GMOrderBlock &obs[], int n, int dir, double tol_pts, int &ob_idx){
   ob_idx = -1;
   for(int i=0; i<n; i++){
      if(obs[i].mitigated) continue;
      if(obs[i].dir != dir) continue;
      double pad = tol_pts;
      if(price >= obs[i].bot - pad && price <= obs[i].top + pad){
         ob_idx = i;
         return true;
      }
   }
   return false;
}

//══════════════════════════════════════════════════════════════════════
//  FAIR VALUE GAPS (FVG / Imbalance)
//══════════════════════════════════════════════════════════════════════
struct GMFairValueGap {
   int      dir;        // +1 = bullish FVG (hueco alcista), -1 = bearish FVG
   double   top;        // límite superior del gap
   double   bot;        // límite inferior del gap
   double   mid;
   datetime t;
   int      bar;        // barra central del gap (índice en r[])
   bool     filled;     // ya fue rellenado
};

// Detecta FVGs: hueco entre r[i-1].high y r[i+1].low (bullish) o inverso
int GMS_FairValueGaps(const MqlRates &r[], int n, GMFairValueGap &out[], int max_fvg=8){
   ArrayResize(out,0);
   int cnt=0;
   for(int i=1; i<n-1 && cnt<max_fvg; i++){
      // Bullish FVG: r[i-1].high < r[i+1].low  (gap en la subida)
      if(r[i-1].high < r[i+1].low){
         ArrayResize(out,cnt+1);
         out[cnt].dir    = 1;
         out[cnt].top    = r[i+1].low;
         out[cnt].bot    = r[i-1].high;
         out[cnt].mid    = (out[cnt].top + out[cnt].bot)*0.5;
         out[cnt].t      = r[i].time;
         out[cnt].bar    = i;
         out[cnt].filled = false;
         cnt++;
      }
      // Bearish FVG: r[i-1].low > r[i+1].high (gap en la bajada)
      else if(r[i-1].low > r[i+1].high){
         ArrayResize(out,cnt+1);
         out[cnt].dir    = -1;
         out[cnt].top    = r[i-1].low;
         out[cnt].bot    = r[i+1].high;
         out[cnt].mid    = (out[cnt].top + out[cnt].bot)*0.5;
         out[cnt].t      = r[i].time;
         out[cnt].bar    = i;
         out[cnt].filled = false;
         cnt++;
      }
   }
   // Los más recientes primero (invertir)
   GMFairValueGap tmp;
   for(int a=0,b=cnt-1; a<b; a++,b--){ tmp=out[a]; out[a]=out[b]; out[b]=tmp; }
   // Marcar rellenados
   double lo = r[n-1].low, hi = r[n-1].high;
   for(int i=0; i<cnt; i++){
      if(out[i].dir>0  && lo <= out[i].mid) out[i].filled = true;
      if(out[i].dir<0  && hi >= out[i].mid) out[i].filled = true;
   }
   return cnt;
}

bool GMS_InFVG(double price, const GMFairValueGap &fvgs[], int n, int dir, int &fvg_idx){
   fvg_idx = -1;
   for(int i=0; i<n; i++){
      if(fvgs[i].filled) continue;
      if(fvgs[i].dir != dir) continue;
      if(price >= fvgs[i].bot && price <= fvgs[i].top){
         fvg_idx = i;
         return true;
      }
   }
   return false;
}

//══════════════════════════════════════════════════════════════════════
//  PUNTUACIÓN CONFLUENCIA — 10 puntos máx
//══════════════════════════════════════════════════════════════════════
struct GMConfluence {
   int score;        // 0-10
   bool htf_trend;   // +1 tendencia HTF a favor
   bool ob_hit;      // +2 precio en Order Block activo
   bool fvg_hit;     // +1 precio en FVG activo
   bool sweep;       // +1 barrido de liquidez previo
   bool ema_align;   // +1 EMA50>EMA200 (compra) o viceversa
   bool bos_confirm; // +1 BOS/CHoCH confirmado en TF operacional
   bool session_ok;  // +1 en sesión London/NY
   bool low_spread;  // +1 spread bajo
   bool rsi_ok;      // +1 RSI no sobreextendido
   bool dxy_ok;      // +1 DXY correlación a favor (XAUUSD negativa)
   string grade;     // "A+" >= 8, "A" >= 6, "B" >= 4, "C" < 4
};

string GMConf_Grade(int score){
   if(score>=8) return "A+";
   if(score>=6) return "A";
   if(score>=4) return "B";
   return "C";
}

GMConfluence GMConf_Build(
   bool htf_trend, bool ob_hit,   bool fvg_hit, bool sweep,
   bool ema_align, bool bos,      bool session,  bool spread,
   bool rsi_ok,    bool dxy_ok)
{
   GMConfluence c; ZeroMemory(c);
   c.htf_trend   = htf_trend;  if(htf_trend) c.score += 1;
   c.ob_hit      = ob_hit;     if(ob_hit)    c.score += 2;  // OB vale doble
   c.fvg_hit     = fvg_hit;    if(fvg_hit)   c.score += 1;
   c.sweep       = sweep;      if(sweep)     c.score += 1;
   c.ema_align   = ema_align;  if(ema_align) c.score += 1;
   c.bos_confirm = bos;        if(bos)       c.score += 1;
   c.session_ok  = session;    if(session)   c.score += 1;
   c.low_spread  = spread;     if(spread)    c.score += 1;
   c.rsi_ok      = rsi_ok;     if(rsi_ok)    c.score += 1;
   c.dxy_ok      = dxy_ok;     if(dxy_ok)    c.score += 1;
   c.score       = MathMin(c.score, 10);
   c.grade       = GMConf_Grade(c.score);
   return c;
}
#endif
