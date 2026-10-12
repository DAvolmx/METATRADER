//+------------------------------------------------------------------+
//|  GOLD_MASTER_ORB_EA.mq5                                          |
//|  Open Range Breakout EA — GOLD MASTER v3.0                       |
//|  Captura rango sesión Londres y opera el breakout                |
//+------------------------------------------------------------------+
#property copyright "David Domez — GOLD MASTER SYSTEM v3.0"
#property version   "3.00"
#property strict

#include <GoldMaster/GoldMaster_Core.mqh>
#include <GoldMaster/GoldMaster_Panel.mqh>
#include <GoldMaster/GoldMaster_PendingOrders.mqh>
#include <GoldMaster/GoldMaster_PositionManager.mqh>

input group "=== ORB CONFIG ==="
input int    ORB_Hour_Start    = 7;
input int    ORB_Hour_End      = 8;
input double ORB_RR            = 2.5;
input double ORB_Risk_Pct      = 1.0;
input double RiskCashPerTrade   = 0.0; // tope monetario por lado; 0 = porcentual
input int    ORB_ATR_Max_Mult  = 3;
input bool   ORB_Cancel_On_NY  = true;
input bool   ORB_OCO           = true;   // OCO: al activarse un lado, cancelar el otro
input double ORB_RangeMaxH1    = 2.0;    // rango máx = N × ATR(H1)
input double ORB_RangeMinH1    = 0.4;    // rango mín = N × ATR(H1)
input double ORB_BufferATR     = 0.1;    // entrada = extremo del rango ± N × ATR(H1)
input bool   ORB_SL_Mid        = false;  // SL en mitad del rango (true) o lado opuesto (false)
input double ORB_SLPadATR      = 0.25;   // margen extra del SL en ATR(H1)
input double ORB_BE_R          = 1.0;    // breakeven al llegar a N R (0 = off)
input bool   ORB_TrendFilter   = false;  // sólo operar a favor de EMA50 H1

input group "=== FILTROS ==="
input int    ATR_Period        = 14;
input int    MaxSpreadPts      = 50;
input double MaxDailyDD_Pct    = 4.0;

input group "=== CUENTA MICRO / CENT ==="
input double MinLotRiskTol     = 1.5;   // acepta lote mínimo si su riesgo <= riesgo×tol

input group "=== IDENTIFICACIÓN ==="
input int    MagicNumber       = 900004;
input string EA_Comment        = "GM_ORB";

CGoldMasterPending*         g_pending = NULL;
CGoldMasterPositionManager* g_posmgr  = NULL;
int    h_ATR = INVALID_HANDLE;
int    h_ATR_H1 = INVALID_HANDLE;
int    h_EMA_H1 = INVALID_HANDLE;
string g_symbol;

double   g_orb_high = 0, g_orb_low = 0;
bool     g_orb_range_set     = false;
bool     g_orb_orders_placed = false;
datetime g_orb_day    = 0;
double   g_balance_start = 0;
double   g_dd = 0;

int OnInit() { GM_TFBadge("ORB EA","M5,M15");
   if(ORB_Hour_Start<0 || ORB_Hour_End>=17 || ORB_Hour_End<=ORB_Hour_Start ||
      ORB_RR<=0 || ORB_Risk_Pct<=0 || RiskCashPerTrade<0 || MaxDailyDD_Pct<=0 ||
      ATR_Period<1 || ORB_RangeMinH1<=0 || ORB_RangeMaxH1<=ORB_RangeMinH1 ||
      ORB_BufferATR<0 || ORB_SLPadATR<0) return INIT_PARAMETERS_INCORRECT;
   g_symbol  = Symbol();
   g_pending = new CGoldMasterPending(g_symbol, MagicNumber, true);   // (symbol, magic) — antes estaban invertidos
   g_posmgr  = new CGoldMasterPositionManager(MagicNumber, g_symbol);
   h_ATR     = iATR(g_symbol, PERIOD_M5, ATR_Period);
   h_ATR_H1  = iATR(g_symbol, PERIOD_H1, ATR_Period);
   h_EMA_H1  = iMA(g_symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   if(h_ATR==INVALID_HANDLE || h_ATR_H1==INVALID_HANDLE || h_EMA_H1==INVALID_HANDLE)
      return INIT_FAILED;
   g_posmgr.SetBreakevenR(ORB_BE_R);
   g_balance_start = AccountInfoDouble(ACCOUNT_BALANCE);
   g_gm_minlot_risk_tol = MinLotRiskTol;
   GM_Log("GM_ORB","ORB EA iniciado — " + g_symbol);
   GM_SymbolReport(g_symbol, ORB_Risk_Pct, 10.0);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   if(g_pending) { delete g_pending; g_pending=NULL; }
   if(g_posmgr)  { delete g_posmgr;  g_posmgr=NULL; }
   IndicatorRelease(h_ATR);
   IndicatorRelease(h_ATR_H1);
   IndicatorRelease(h_EMA_H1);
   ObjectsDeleteAll(0,"GM_ORB");
}

void OnTick() {
   MqlDateTime now; TimeToStruct(TimeCurrent(), now);
   datetime today = TimeCurrent() - (now.hour*3600+now.min*60+now.sec);
   
   // Reset diario
   if(g_orb_day != today) {
      g_pending.CancelAllPending();
      g_orb_day=today; g_orb_high=0; g_orb_low=0;
      g_orb_range_set=false; g_orb_orders_placed=false;
      g_balance_start=AccountInfoDouble(ACCOUNT_BALANCE);
   }
   
   // DD check
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   g_dd=(g_balance_start>0)?((g_balance_start-equity)/g_balance_start*100.0):0;
   if(g_dd>=MaxDailyDD_Pct) { g_pending.CancelAllPending(); g_posmgr.ManageAll(); return; }
   
   // Gestionar posiciones
   double atr=GM_GetATR(h_ATR,1);
   if(atr>0) g_posmgr.SetATR(atr);
   g_posmgr.ManageAll();

   // OCO: si ya hay una posición ORB abierta hoy, cancelar la pendiente contraria
   if(ORB_OCO && g_orb_orders_placed) {
      bool has_pos=false;
      for(int i=PositionsTotal()-1;i>=0;i--) {
         ulong tk=PositionGetTicket(i);
         if(PositionGetInteger(POSITION_MAGIC)==MagicNumber && PositionGetString(POSITION_SYMBOL)==g_symbol
            && (datetime)PositionGetInteger(POSITION_TIME)>=today) { has_pos=true; break; }
      }
      if(has_pos && g_pending.CountPending()>0) {
         g_pending.CancelAllPending();
         GM_Log("GM_ORB","OCO: breakout confirmado, pendiente contraria cancelada");
      }
   }
   
   // Hora del servidor: no se presupone que sea UTC. Cancelar aunque falte el tick de las 17:00.
   if(ORB_Cancel_On_NY && now.hour>=17) { g_pending.CancelAllPending(); return; }
   if(GM_GetSpread(g_symbol)>MaxSpreadPts) return;
   
   // Reconstruir exclusivamente el intervalo finalizado de hoy, incluso tras reiniciar.
   datetime range_start=today+ORB_Hour_Start*3600;
   datetime range_end=today+ORB_Hour_End*3600;
   if(TimeCurrent()>=range_end && !g_orb_range_set) {
      MqlRates rates[];
      int copied=CopyRates(g_symbol,PERIOD_M1,range_start,range_end-1,rates);
      int expected=(ORB_Hour_End-ORB_Hour_Start)*60;
      if(copied!=expected) return; // Falta historia: no construir un rango incompleto.
      double high=0,low=DBL_MAX;
      for(int i=0;i<copied;i++) {
         if(rates[i].time<range_start || rates[i].time>=range_end) return;
         high=MathMax(high,rates[i].high); low=MathMin(low,rates[i].low);
      }
      if(high<=low || low<=0) return;
      g_orb_high=high; g_orb_low=low; g_orb_range_set=true;
   }

   // FASE 2: Colocar pendientes cuando termina la hora de rango
   if(TimeCurrent()>=range_end && now.hour<17 && !g_orb_orders_placed && g_orb_high>g_orb_low) {
      if(g_pending.CountPending()>0 || g_posmgr.CountPositions()>0) { g_orb_orders_placed=true; return; }
      double range=g_orb_high-g_orb_low;
      double atr_h1=GM_GetATR(h_ATR_H1,1);
      // Filtro vs ATR(H1): el rango de 1 hora se compara con la volatilidad de 1 hora
      // (antes se comparaba con ATR(M5) → descartaba ~60% de días válidos)
      if(atr_h1>0 && range<atr_h1*ORB_RangeMaxH1 && range>atr_h1*ORB_RangeMinH1) {
         bool allow_b=true, allow_s=true;
         if(ORB_TrendFilter) {
            double ema=GM_GetEMA(h_EMA_H1,1), c1=iClose(g_symbol,PERIOD_H1,1);
            if(ema<=0 || c1<=0) return;
            allow_b = (c1>ema); allow_s = (c1<ema);
         }
         // Mismos cálculos que gm_backtest.py (ATR de H1 para buffer y SL)
         g_pending.PlaceORBOrders(g_orb_high, g_orb_low, atr_h1, ORB_Risk_Pct, ORB_BufferATR,
                                  EA_Comment, ORB_RR, ORB_SL_Mid, ORB_SLPadATR, allow_b, allow_s, RiskCashPerTrade);
         g_orb_range_set     = true;
         g_orb_orders_placed = true;
         GM_Log("GM_ORB","ORB colocado H="+DoubleToString(g_orb_high,5)+" L="+DoubleToString(g_orb_low,5));
      } else if(atr_h1>0) {
         GM_Log("GM_ORB","ORB rango inv: "+DoubleToString(range,2)+" ATR_H1="+DoubleToString(atr_h1,2));
         g_orb_orders_placed=true;
      }
   }
   
   // FASE 3: Cancelar pendientes al inicio de NY (17 UTC)
   if(ORB_Cancel_On_NY && now.hour==17 && now.min==0) {
      for(int i=OrdersTotal()-1;i>=0;i--) {
         ulong t=OrderGetTicket(i);
         if(OrderGetInteger(ORDER_MAGIC)==MagicNumber && 
            OrderGetString(ORDER_SYMBOL)==g_symbol)
            g_pending.CancelOrder(t);
      }
   }
   
   // Info en pantalla
   string info="GM ORB EA v3\n";
   info+="Rango: "+(g_orb_range_set?"SET":"ESPERANDO")+"\n";
   if(g_orb_high>g_orb_low) {
      info+="H: "+DoubleToString(g_orb_high,2)+"\n";
      info+="L: "+DoubleToString(g_orb_low,2)+"\n";
      info+="Amp: "+DoubleToString(g_orb_high-g_orb_low,2)+"\n";
   }
   info+="Pend: "+IntegerToString(g_pending.CountPending())+"\n";
   info+="Pos: "+IntegerToString(g_posmgr.CountPositions())+"\n";
   info+="DD: "+DoubleToString(g_dd,1)+"%";
   double cur_ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double cur_atr = (atr>0)?atr:10.0;
   GM_DrawText("GM_ORB_INFO", TimeCurrent(), cur_ask + cur_atr, info, clrAqua);
}
