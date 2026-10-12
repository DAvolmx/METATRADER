//+------------------------------------------------------------------+
//|  GOLD_MASTER_GUARDIAN_EA.mq5 — Protector de la cuenta            |
//|  Vigila TODAS las posiciones (manuales y de EAs) en cada tick:   |
//|   1. Pone SL/TP automático a posiciones SIN stop (por ATR)       |
//|   2. Breakeven y trailing automáticos                            |
//|   3. Límite de pérdida diaria → cierra todo y bloquea el día     |
//|   4. Límite de operaciones por día (anti-sobreoperación)         |
//|   5. Guardia de margen: cierra la peor posición si el nivel de   |
//|      margen cae bajo el mínimo                                   |
//|   6. Horas bloqueadas: cierra órdenes abiertas en horas malas    |
//|  No abre operaciones: sólo protege.                              |
//+------------------------------------------------------------------+
#property copyright "David Domez — GOLD MASTER SYSTEM"
#property version   "1.00"
#property strict
#include <Trade\Trade.mqh>
#include <GoldMaster/GoldMaster_Core.mqh>
#include <GoldMaster/GoldMaster_Panel.mqh>
#include <GoldMaster/GoldMaster_Bridge.mqh>
CGMPanel g_panel;

input group "=== STOP AUTOMÁTICO ==="
input bool   AutoSL            = true;
input ENUM_TIMEFRAMES ATR_TF   = PERIOD_M15; // TF del ATR y de la estructura (antes M5 → SL muy cortos)
input bool   StructuralSL      = true;    // SL detrás del último swing (máx/mín) del ATR_TF
input double SL_ATR_Mult       = 1.5;     // SL por ATR si no hay swing válido
input double SL_PadATR         = 0.25;    // colchón detrás del swing
input double MinStopUSD         = 8.0;     // distancia mínima del SL en precio ($ de oro)
input double MaxSL_USD         = 25.0;    // distancia máxima del SL
input double MaxRiskPctPos  = 0.0;     // 0 = off. Si >0 recorta el SL por riesgo (en cuentas chicas deja stops diminutos)
input double TP_R              = 2.0;     // TP = SL × R (0 = no poner TP)
input bool   ReplaceTinyStops  = true;    // corrige SL/TP que pongas demasiado pegados (< MinStopUSD)
input int    GraceSeconds      = 10;      // espera antes de poner SL (por si lo pones tú)
input bool   AutoBreakeven     = true;
input double BE_At_R           = 1.0;
input bool   AutoTrailing      = true;
input double Trail_ATR         = 1.5;     // distancia del trailing en ATR(ATR_TF)
input double Trail_Start_R     = 1.5;     // el trailing arranca a partir de este R

input group "=== LÍMITES DE LA CUENTA ==="
input double MaxDailyLossPct   = 10.0;    // % del balance de inicio del día
input int    MaxTradesPerDay   = 20;      // nuevas posiciones por día (todas)
input double MinMarginPct    = 80.0;    // % — por debajo cierra la peor posición (antes 200: cerraba tus entradas al instante)
input bool   CloseOnLimit      = true;    // al tocar límite diario: cerrar todo
input bool   CloseManualOnLimits = false;  // false = a tus operaciones manuales sólo te AVISA (no las cierra)

input group "=== HORAS BLOQUEADAS (hora del servidor) ==="
input string BlockedHours      = "0,1";   // lista separada por comas
input bool   CloseNewInBlocked = true;    // cerrar posiciones abiertas en esas horas

input group "=== MANTENIMIENTO DE GRÁFICOS ==="
input bool   ShowRefreshButton = true;   // botón "⟳ Refrescar MT5" en este gráfico
input bool   AutoHealCharts    = true;   // recarga sola los gráficos que se quedan congelados
input int    PeriodicRefreshMin= 0;      // refresco total cada N minutos (0 = sólo cuando se traban)

input group "=== FILTRO ==="
input string OnlySymbolsLike   = "XAU";   // "" = todos los símbolos

CTrade trade; CGMBridge g_br; datetime g_lastHeal=0, g_lastPeriodic=0;

// Recalcula todos los indicadores de un gráfico (equivale a cambiar de temporalidad y volver)
void RefreshChart(long c){
   if(c==ChartID()){ ChartRedraw(c); return; }          // el propio gráfico del Guardian no se reinicia
   ChartSetSymbolPeriod(c,ChartSymbol(c),(ENUM_TIMEFRAMES)ChartPeriod(c)); ChartRedraw(c);
}
int RefreshAll(string why){
   int n=0; for(long c=ChartFirst();c>=0;c=ChartNext(c)){ RefreshChart(c); n++; }
   Print("[GUARDIAN] ⟳ ",n," gráficos refrescados (",why,")"); return n;
}
// Gráfico "congelado": su última vela es mucho más vieja que el tiempo del servidor con mercado activo
void HealCharts(){
   datetime now=TimeTradeServer();
   for(long c=ChartFirst();c>=0;c=ChartNext(c)){
      string sy=ChartSymbol(c); ENUM_TIMEFRAMES tf=(ENUM_TIMEFRAMES)ChartPeriod(c);
      MqlTick tk; if(!SymbolInfoTick(sy,tk) || now-(datetime)tk.time>120) continue;   // mercado cerrado / sin ticks
      datetime last=iTime(sy,tf,0); int ps=PeriodSeconds(tf);
      if(last>0 && now-last > 2*ps+60){ Print("[GUARDIAN] gráfico ",sy," ",EnumToString(tf)," congelado (",(now-last),"s) → recarga"); RefreshChart(c); }
   }
}
void MakeButton(){
   string n="GMG_REFRESH"; if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_RIGHT_UPPER); ObjectSetInteger(0,n,OBJPROP_XDISTANCE,170); ObjectSetInteger(0,n,OBJPROP_YDISTANCE,25);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,160); ObjectSetInteger(0,n,OBJPROP_YSIZE,26); ObjectSetString(0,n,OBJPROP_TEXT,"⟳ Refrescar MT5");
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'30,60,110'); ObjectSetInteger(0,n,OBJPROP_COLOR,clrWhite); ObjectSetInteger(0,n,OBJPROP_FONTSIZE,9);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
}
double g_dayStart=0; datetime g_day=0; int g_newToday=0; bool g_locked=false;
ulong  g_seen[]; 
bool g_nolim=false; string GBTN="GM_GD_BTN", GVL;
void DrawGBtn(){ GM_Button(GBTN,10,70,230,g_nolim?"⚠ LÍMITES DE CUENTA: OFF":"✔ LÍMITES DE CUENTA: ON",g_nolim?clrFireBrick:C'20,110,60'); }

bool Seen(ulong t){ for(int i=0;i<ArraySize(g_seen);i++) if(g_seen[i]==t) return true; return false; }
void MarkSeen(ulong t){ int n=ArraySize(g_seen); if(n>500){ArrayRemove(g_seen,0,100);n=ArraySize(g_seen);} ArrayResize(g_seen,n+1); g_seen[n]=t; }

bool HourBlocked(int h){
   string parts[]; int n=StringSplit(BlockedHours,',',parts);
   for(int i=0;i<n;i++) if(StringLen(parts[i])>0 && (int)StringToInteger(parts[i])==h) return true;
   return false;
}
string g_hs[]; int g_hh[];
double AtrOf(string s){
   int k=-1; for(int i=0;i<ArraySize(g_hs);i++) if(g_hs[i]==s){k=i;break;}
   if(k<0){ k=ArraySize(g_hs); ArrayResize(g_hs,k+1); ArrayResize(g_hh,k+1); g_hs[k]=s; g_hh[k]=iATR(s,ATR_TF,14); }
   double b[]; return CopyBuffer(g_hh[k],0,1,1,b)>0 ? b[0] : 0; }
// último swing (fuerza 3) a favor del stop en ATR_TF
double SwingStop(string s,int type,double ref){
   for(int i=4;i<120;i++){
      bool ok=true;
      if(type==POSITION_TYPE_BUY){ double l=iLow(s,ATR_TF,i); if(l<=0||l>=ref) continue;
         for(int j=1;j<=3&&ok;j++) if(iLow(s,ATR_TF,i-j)<l||iLow(s,ATR_TF,i+j)<l) ok=false; if(ok) return l; }
      else { double h=iHigh(s,ATR_TF,i); if(h<=0||h<=ref) continue;
         for(int j=1;j<=3&&ok;j++) if(iHigh(s,ATR_TF,i-j)>h||iHigh(s,ATR_TF,i+j)>h) ok=false; if(ok) return h; }
   }
   return 0; }

int OnInit(){ GVL="GM_GD_NOLIM"; g_nolim=GlobalVariableCheck(GVL)&&GlobalVariableGet(GVL)>0; DrawGBtn(); if(!MQLInfoInteger(MQL_TESTER) && GM_IsDuplicateInstance()){ Print("[GM] Ya hay otra copia de este EA en ",_Symbol," → esta se retira"); ExpertRemove(); return INIT_SUCCEEDED; } g_panel.Init("GUARD",10,330); g_br.Init(300); if(ShowRefreshButton) MakeButton(); trade.SetDeviationInPoints(50); EventSetTimer(1); Print("[GUARDIAN] activo"); return INIT_SUCCEEDED; }
void OnDeinit(const int r){ g_panel.Destroy(); ObjectDelete(0,"GMG_REFRESH"); EventKillTimer();  }
void OnTimer(){
   Guard();
   // comandos del dashboard (REFRESH_CHARTS) — se leen cada 2 s
   static int k=0; if(++k%2==0){ GMCommand cmds[]; int n=g_br.PollNew(cmds);
      for(int i=0;i<n;i++) if(cmds[i].cmd=="REFRESH_CHARTS") RefreshAll("dashboard"); }
   if(AutoHealCharts && TimeCurrent()-g_lastHeal>=60){ g_lastHeal=TimeCurrent(); HealCharts(); }
   if(PeriodicRefreshMin>0 && TimeCurrent()-g_lastPeriodic>=PeriodicRefreshMin*60){ g_lastPeriodic=TimeCurrent(); RefreshAll("periódico"); }
}
void OnTick(){ /* gestión sólo en OnTimer — evita spam por tick */ }

void CloseAll(string why){
   for(int i=PositionsTotal()-1;i>=0;i--){ ulong t=PositionGetTicket(i); string s=PositionGetString(POSITION_SYMBOL);
      if(OnlySymbolsLike!="" && StringFind(s,OnlySymbolsLike)<0) continue;
      trade.SetTypeFilling(GM_FillingMode(s)); trade.PositionClose(t); }
   Print("[GUARDIAN] CIERRE TOTAL: ",why);
}

void Guard(){
   // ── GUARD 0: Algo Trading desactivado ─────────────────────────
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)){
      static datetime s_tradingOffWarn = 0;
      if(TimeCurrent() - s_tradingOffWarn >= 300){
         Print("[GUARDIAN] Trading deshabilitado en el terminal; gestion suspendida.");
         s_tradingOffWarn = TimeCurrent();
      }
      return;  // sin retries, sin spam
   }
   datetime d=iTime(_Symbol,PERIOD_D1,0);
   if(d!=g_day){ g_day=d; g_dayStart=AccountInfoDouble(ACCOUNT_BALANCE); g_newToday=0; g_locked=false; }
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = g_dayStart>0 ? (g_dayStart-eq)/g_dayStart*100 : 0;
   double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   MqlDateTime now; TimeToStruct(TimeCurrent(),now);

   if(!g_nolim && !g_locked && ddPct>=MaxDailyLossPct){ g_locked=true; if(CloseOnLimit) CloseAll(StringFormat("pérdida diaria %.1f%%",ddPct)); }

   double worstP=0; ulong worst=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      string s=PositionGetString(POSITION_SYMBOL);
      if(OnlySymbolsLike!="" && StringFind(s,OnlySymbolsLike)<0) continue;
      trade.SetTypeFilling(GM_FillingMode(s));
      int type=(int)PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN), sl=PositionGetDouble(POSITION_SL), tp=PositionGetDouble(POSITION_TP);
      double prof=PositionGetDouble(POSITION_PROFIT);
      datetime ot=(datetime)PositionGetInteger(POSITION_TIME);
      int dig=(int)SymbolInfoInteger(s,SYMBOL_DIGITS);
      if(prof<worstP){ worstP=prof; worst=t; }

      // posición nueva
      if(!Seen(t)){ MarkSeen(t);
         if(ot >= g_day){ g_newToday++;
            MqlDateTime o; TimeToStruct(ot,o);
            bool manual = PositionGetInteger(POSITION_MAGIC)==0;
            if(g_nolim) { /* límites desactivados */ } else
            if(manual && !CloseManualOnLimits && (g_locked || g_newToday>MaxTradesPerDay || (CloseNewInBlocked && HourBlocked(o.hour)))){
               Alert("[GUARDIAN] Aviso: operación manual #",t," abierta con ", g_locked?"límite de pérdida diaria alcanzado":g_newToday>MaxTradesPerDay?"máx. operaciones del día superado":"hora bloqueada"," — no se cierra, gestiona el riesgo");
            }
            else if(g_locked || g_newToday>MaxTradesPerDay || (CloseNewInBlocked && HourBlocked(o.hour))){
               trade.PositionClose(t);
               Print("[GUARDIAN] cerrada #",t,": ", g_locked?"día bloqueado":g_newToday>MaxTradesPerDay?"máx. operaciones del día":"hora bloqueada");
               continue; } } }

      double atr=AtrOf(s); if(atr<=0) continue;
      double bid=SymbolInfoDouble(s,SYMBOL_BID), ask=SymbolInfoDouble(s,SYMBOL_ASK);
      double px = type==POSITION_TYPE_BUY?bid:ask;
      // 1) SL automático
      int sg = type==POSITION_TYPE_BUY?1:-1;
      bool tiny = ReplaceTinyStops && PositionGetInteger(POSITION_MAGIC)==0 && sl>0 && (sl-open)*sg<0 && MathAbs(open-sl)<MinStopUSD*0.999;
      if(AutoSL && (sl==0||tiny) && TimeCurrent()-ot>=GraceSeconds){
         double dist=atr*SL_ATR_Mult;
         if(StructuralSL){ double sw=SwingStop(s,type,open); if(sw>0) dist=MathAbs(open-sw)+atr*SL_PadATR; }
         dist=MathMax(MinStopUSD,MathMin(MaxSL_USD,dist));
         double vol=PositionGetDouble(POSITION_VOLUME), cs=SymbolInfoDouble(s,SYMBOL_TRADE_CONTRACT_SIZE);
         if(MaxRiskPctPos>0 && vol>0 && cs>0){
            double cap=AccountInfoDouble(ACCOUNT_EQUITY)*MaxRiskPctPos/100.0/(vol*cs);
            double minDist=(SymbolInfoInteger(s,SYMBOL_TRADE_STOPS_LEVEL)+10)*SymbolInfoDouble(s,SYMBOL_POINT);
            if(cap<dist) dist=MathMax(cap,minDist);
         }
         double nsl = open - sg*dist;
         if(tiny) tp=0;                                        // recalcular TP con el nuevo SL
         if(type==POSITION_TYPE_BUY && nsl>=bid) nsl=bid-atr*0.5;
         if(type==POSITION_TYPE_SELL && nsl<=ask) nsl=ask+atr*0.5;
         double ntp = tp; if(tp==0 && TP_R>0) ntp = open + (type==POSITION_TYPE_BUY?1:-1)*MathAbs(open-nsl)*TP_R;
         if(trade.PositionModify(t,NormalizeDouble(nsl,dig),NormalizeDouble(ntp,dig)))
            Print("[GUARDIAN] SL automático #",t," SL ",DoubleToString(nsl,dig)," TP ",DoubleToString(ntp,dig));
         continue;
      }
      if(sl==0) continue;
      double risk=MathAbs(open-sl); double r = risk>0 ? (type==POSITION_TYPE_BUY?px-open:open-px)/risk : 0;
      // 2) Breakeven
      bool beDone = type==POSITION_TYPE_BUY ? sl>=open : sl<=open;
      if(AutoBreakeven && !beDone && r>=BE_At_R){
         double be=open+(type==POSITION_TYPE_BUY?1:-1)*(ask-bid);
         trade.PositionModify(t,NormalizeDouble(be,dig),tp); continue; }
      // 3) Trailing (sólo tras breakeven)
      if(AutoTrailing && beDone && (type==POSITION_TYPE_BUY?px-open:open-px) >= Trail_Start_R*MathMax(MinStopUSD,atr*SL_ATR_Mult)){
         double nsl = type==POSITION_TYPE_BUY ? px-atr*Trail_ATR : px+atr*Trail_ATR;
         double pt=SymbolInfoDouble(s,SYMBOL_POINT);
         if((type==POSITION_TYPE_BUY && nsl>sl+MathMax(20*pt,0.25*atr)) || (type==POSITION_TYPE_SELL && nsl<sl-MathMax(20*pt,0.25*atr)))
            trade.PositionModify(t,NormalizeDouble(nsl,dig),tp);
      }
   }
   // 5) Guardia de margen
   static datetime lastMarginAct=0;
   if(!g_nolim && ml>0 && ml<MinMarginPct && worst>0 && TimeCurrent()-lastMarginAct>=30){
      lastMarginAct=TimeCurrent();
      if(trade.PositionClose(worst)) Print("[GUARDIAN] margen ",DoubleToString(ml,0),"% → cerrada la peor #",worst);
      else Print("[GUARDIAN] margen ",DoubleToString(ml,0),"%: no se pudo cerrar #",worst," (",trade.ResultRetcode(),")");
   }

   g_panel.Show(StringFormat("GUARDIAN · DD día %.1f%% / %.0f%% · Nuevas hoy %d/%d · Margen %.0f%% %s",
           ddPct, MaxDailyLossPct, g_newToday, MaxTradesPerDay, ml, g_locked?"· DÍA BLOQUEADO":""));
}

void OnChartEvent(const int id,const long &l,const double &d,const string &s){
   g_panel.OnEvent(id,l,d,s);
   if(id==CHARTEVENT_OBJECT_CLICK && s==GBTN){ g_nolim=!g_nolim; GlobalVariableSet(GVL,g_nolim?1:0); DrawGBtn();
      Print(g_nolim?"[GUARDIAN] Límites OFF: sin bloqueo diario, sin máx. de operaciones, sin horas bloqueadas, sin cierre por margen. SL/TP/BE/trailing siguen activos."
                   :"[GUARDIAN] Límites de cuenta reactivados."); }
   if(id==CHARTEVENT_OBJECT_CLICK && s=="GMG_REFRESH"){ RefreshAll("botón"); ObjectSetInteger(0,s,OBJPROP_STATE,false); }
}
