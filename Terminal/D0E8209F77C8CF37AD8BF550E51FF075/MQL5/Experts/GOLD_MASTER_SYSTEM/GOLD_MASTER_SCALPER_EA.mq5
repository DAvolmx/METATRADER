//+------------------------------------------------------------------+
//|  GOLD_MASTER_SCALPER_EA.mq5                                      |
//|  Basado en ORO_SCALPER_PRO v1.0 (BOS + RSI(7) + EMA + sesión),   |
//|  corregido e integrado al GOLD MASTER SYSTEM:                    |
//|   + BOS real sin repintado (GoldMaster_Structure, 300 velas)     |
//|   + Tendencia mayor por estructura H1 (HH/HL) además de EMA200   |
//|   + Filtro DXY (sintético/directo) + intel del dashboard          |
//|     (sentimiento, DXY, rendimiento real 10y) vía bridge           |
//|   + Filtro de noticias (calendario del dashboard)                 |
//|   + Filtros de volatilidad en DÓLARES (no "pips" ambiguos)        |
//|   + Entrada a mercado O con BUY/SELL STOP sobre la vela de ruptura|
//|   + Modo de llenado automático (Deriv no acepta IOC)              |
//|   + Lotaje con control de lote mínimo (cuentas micro)             |
//|   + Gestión cada TICK: TP1 parcial, breakeven y trailing          |
//+------------------------------------------------------------------+
#property copyright "David Domez — GOLD MASTER SYSTEM"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <GoldMaster/GoldMaster_Core.mqh>
#include <GoldMaster/GoldMaster_Structure.mqh>
#include <GoldMaster/GoldMaster_DXY.mqh>
#include <GoldMaster/GoldMaster_Bridge.mqh>
#include <GoldMaster/GoldMaster_Panel.mqh>
#include <GoldMaster/GoldMaster_Assets.mqh>
CGMPanel g_panel;
GM_AssetProfile g_asset;   // perfil del activo detectado automáticamente

input group "=== GESTIÓN DE RIESGO ==="
input double RiskPercent      = 1.0;    // % del balance por trade
input double RiskCashPerTrade = 0.0;    // 0: porcentual; >0: tope de pérdida al SL en moneda de cuenta
input double SL_ATR_Mult      = 1.5;    // SL = ATR × mult (o detrás del swing si es mayor)
input bool   SL_BehindSwing   = true;   // SL detrás del último swing contrario
input double TP1_R            = 1.0;    // TP1 (cierre parcial) en R
input double TP2_R            = 2.5;    // TP final en R
input double PartialPct       = 50.0;   // % a cerrar en TP1
input double TrailATR         = 1.5;    // trailing tras TP1 (× ATR)
input double MinLotRiskTol    = 1.5;    // cuentas micro: tolerancia de lote mínimo

input group "=== INDICADORES ==="
input int    EMA_Fast         = 20;
input int    EMA_Slow         = 50;
input int    EMA_Trend        = 200;
input ENUM_TIMEFRAMES TrendTF = PERIOD_M15;  // TF de la EMA200
input int    RSI_Period       = 7;
input double RSI_BullMin      = 45, RSI_BullMax = 68;
input double RSI_BearMin      = 32, RSI_BearMax = 55;
input int    ATR_Period       = 14;

input group "=== ESTRUCTURA ==="
input int    SwingStrength    = 3;      // velas a cada lado (sin repintado)
input ENUM_TIMEFRAMES HTF     = PERIOD_H1;
input bool   RequireHTFStructure = true; // H1 debe estar en HH/HL (compras) o LH/LL (ventas)
input int    ConfirmBars      = 1;      // velas tras el BOS antes de entrar
input int    SignalExpiryBars = 6;      // la señal caduca si no se cumple todo

input group "=== ENTRADA ==="
input bool   UseStopEntry     = true;   // true: BUY/SELL STOP sobre/bajo la vela de ruptura · false: a mercado
input double StopBufferATR    = 0.10;
input int    StopExpiryBars   = 4;

input group "=== FILTROS (en $ de precio, válidos para XAUUSD y micro) ==="
input double MinATR_USD       = 0.8;    // ATR mínimo en $ (lateral)
input double MaxATR_USD       = 8.0;    // ATR máximo en $ (noticia/spike)
input double MinEMAGap_ATR    = 0.15;   // distancia EMA20-50 mínima en ATR
input int    MaxTradesPerDay  = 5;
input int    CooldownBars     = 6;
input int    MaxSpreadPts     = 60;

input group "=== SESIONES (UTC) ==="
input bool   FilterSession    = true;
input int    London_Start=7, London_End=11, NY_Start=13, NY_End=17;

input group "=== DXY / MACRO / NOTICIAS ==="
input bool   UseDXYFilter     = true;   // DXY interno (pares FX del broker)
input bool   UseIntelBridge   = true;   // usar intel.txt del dashboard (DXY, real yields, sentimiento)
input double IntelVeto        = 0.45;   // |compuesto| ≥ veto bloquea el lado contrario
input bool   UseNewsFilter    = true;
input int    NewsFreezeMin    = 20;

input group "=== IDENTIFICACIÓN ==="
input ulong  MagicNumber      = 202600;
input bool   EnableBuy        = true;
input bool   EnableSell       = true;
input bool   ShowLogs         = true;

CTrade trade;
CGMDXY g_dxy;
CGMBridge g_bridge;
CGMNewsFilter g_news;
int hEF, hES, hET, hRSI, hATR;
int    g_tradesToday=0, g_barsSinceClose=999, g_pending=0, g_confirm=0, g_sigAge=0;
datetime g_day=0, g_lastBar=0, g_lastEventT=0, g_stopTime=0;
double g_sigHigh=0, g_sigLow=0;
ulong  g_stopTicket=0;
bool   g_partialDone=false; ulong g_posTicket=0; double g_initRisk=0;

void Log(string s) { if(ShowLogs) Print("[SCALPER] ", s); }
double Buf(int h, int shift) { double b[]; return CopyBuffer(h,0,shift,1,b)>0 ? b[0] : 0; }

//══════════════════════════════════════════════════════════════════
int OnInit() {
   // ── Auto-detección de activo (XAUUSD / NASDAQ / BTC / ETH) ──
   g_asset = GM_GetProfile(_Symbol);
   GM_LogProfile(g_asset);
   GM_TFBadgeAsset("SCALPER EA", g_asset.tf_scalp, g_asset.name, g_asset.icon);
   if(!MQLInfoInteger(MQL_TESTER) && GM_IsDuplicateInstance()){ Print("[GM] Ya hay otra copia de este EA en ",_Symbol," → esta se retira"); ExpertRemove(); return INIT_SUCCEEDED; }
   g_panel.InitWithAsset("SCALP",g_asset,10,200);
   if((bool)MQLInfoInteger(MQL_VISUAL_MODE)) g_panel.SetReplayMode(true,_Symbol);  // FIX#1: MQL_VISUAL_MODE detecta solo modo visual, no backtest normal
   hEF=iMA(_Symbol,PERIOD_CURRENT,EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   hES=iMA(_Symbol,PERIOD_CURRENT,EMA_Slow,0,MODE_EMA,PRICE_CLOSE);
   hET=iMA(_Symbol,TrendTF,EMA_Trend,0,MODE_EMA,PRICE_CLOSE);
   hRSI=iRSI(_Symbol,PERIOD_CURRENT,RSI_Period,PRICE_CLOSE);
   hATR=iATR(_Symbol,PERIOD_CURRENT,ATR_Period);
   if(hEF==INVALID_HANDLE||hES==INVALID_HANDLE||hET==INVALID_HANDLE||hRSI==INVALID_HANDLE||hATR==INVALID_HANDLE) return INIT_FAILED;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(GM_FillingMode(_Symbol));        // ← ORO_SCALPER_PRO usaba IOC fijo (error 10030 en Deriv)
   g_gm_minlot_risk_tol = MinLotRiskTol;
   if(UseDXYFilter) Log(g_dxy.Init() ? "DXY: "+g_dxy.Mode() : "DXY no disponible en el broker");
   if(UseIntelBridge) g_bridge.Init(180);
   if(UseNewsFilter) g_news.Init();
   GM_SymbolReport(_Symbol, RiskPercent, 5.0);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int r) { g_panel.Destroy();
   IndicatorRelease(hEF); IndicatorRelease(hES); IndicatorRelease(hET); IndicatorRelease(hRSI); IndicatorRelease(hATR);
   
}

bool MyPosition(ulong &ticket) {
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC)==(long)MagicNumber && PositionGetString(POSITION_SYMBOL)==_Symbol) { ticket=t; return true; }
   }
   return false;
}

bool InSession() {
   if(!FilterSession) return true;
   MqlDateTime d; TimeToStruct(TimeGMT(), d);
   return (d.hour>=London_Start && d.hour<London_End) || (d.hour>=NY_Start && d.hour<NY_End);
}

//══════════════════════════════════════════════════════════════════
//  Gestión en cada tick (el original sólo gestionaba al abrir vela)
//══════════════════════════════════════════════════════════════════
void ManagePosition(ulong ticket, double atr) {
   if(!PositionSelectByTicket(ticket)) return;
   if(ticket != g_posTicket) {                      // nueva posición
      g_posTicket=ticket; g_partialDone=false;
      g_initRisk=MathAbs(PositionGetDouble(POSITION_PRICE_OPEN)-PositionGetDouble(POSITION_SL));
   }
   int type=(int)PositionGetInteger(POSITION_TYPE);
   double open=PositionGetDouble(POSITION_PRICE_OPEN), sl=PositionGetDouble(POSITION_SL), tp=PositionGetDouble(POSITION_TP);
   double vol=PositionGetDouble(POSITION_VOLUME);
   double px = type==POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol,SYMBOL_BID) : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double r = g_initRisk>0 ? ((type==POSITION_TYPE_BUY ? px-open : open-px)/g_initRisk) : 0;
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(!g_partialDone && r >= TP1_R) {
      double cl = GM_PartialLot(_Symbol, vol, PartialPct/100.0);
      if(cl>0 && trade.PositionClosePartial(ticket, cl)) Log(StringFormat("TP1 %.1fR: cerrado %.2f lotes", TP1_R, cl));
      else Log("TP1: lote no divisible → sólo breakeven");
      double be = open + (type==POSITION_TYPE_BUY?1:-1)*GM_GetSpread(_Symbol)*pt;
      if((type==POSITION_TYPE_BUY && be>sl) || (type==POSITION_TYPE_SELL && (sl==0||be<sl)))
         trade.PositionModify(ticket, NormalizeDouble(be,_Digits), tp);
      g_partialDone=true;
   }
   if(g_partialDone && atr>0) {
      double nsl = type==POSITION_TYPE_BUY ? px-atr*TrailATR : px+atr*TrailATR;
      nsl=NormalizeDouble(nsl,_Digits);
      bool better = type==POSITION_TYPE_BUY ? (nsl>sl+pt*10 && nsl>open) : ((sl==0||nsl<sl-pt*10) && nsl<open);
      if(better) trade.PositionModify(ticket, nsl, tp);
   }
}

//══════════════════════════════════════════════════════════════════
void OnTick() {
   double atr = Buf(hATR,1);
   ulong pos=0;
   bool hasPos = MyPosition(pos);
   if(hasPos) ManagePosition(pos, atr);

   // detectar llenado de la orden stop
   if(g_stopTicket>0 && !OrderSelect(g_stopTicket)) { if(hasPos) { g_tradesToday++; Log("Orden stop ejecutada"); } g_stopTicket=0; }

   datetime bar=iTime(_Symbol,PERIOD_CURRENT,0);
   if(bar==g_lastBar) return;
   g_lastBar=bar;

   // reset diario
   datetime day=iTime(_Symbol,PERIOD_D1,0);
   if(day!=g_day) { g_day=day; g_tradesToday=0; }
   if(hasPos) { g_barsSinceClose=0; return; }
   g_barsSinceClose++;
   if(UseIntelBridge) g_bridge.ReadIntel();

   // expiración de la orden stop
   if(g_stopTicket>0 && TimeCurrent()-g_stopTime > StopExpiryBars*PeriodSeconds()) {
      trade.OrderDelete(g_stopTicket); g_stopTicket=0; Log("Orden stop expirada");
   }
   if(!MQLInfoInteger(MQL_TESTER) && UseIntelBridge && !g_bridge.AutoTrade()) return;   // MODO AUTÓNOMO OFF en el dashboard

   // ── Estructura (BOS real) ──
   MqlRates r[]; int n=CopyRates(_Symbol,PERIOD_CURRENT,0,300,r);
   if(n<100) return;
   GMSSwing sw[]; int ns=GMS_Swings(r,n,SwingStrength,sw);
   GMSEvent ev[]; int trend; int ne=GMS_Events(r,n,SwingStrength,sw,ns,ev,trend);
   if(ne>0 && ev[ne-1].t_break!=g_lastEventT && ev[ne-1].bar_break>=n-3) {   // evento nuevo y reciente
      g_lastEventT=ev[ne-1].t_break; g_pending=ev[ne-1].dir; g_confirm=0; g_sigAge=0;
      g_sigHigh=r[ev[ne-1].bar_break].high; g_sigLow=r[ev[ne-1].bar_break].low;
      Log(StringFormat("%s detectado en %.2f", GMS_EventName(ev[ne-1].dir, ev[ne-1].choch), ev[ne-1].price));
   }
   if(g_pending==0) { Panel(trend, atr, "sin señal"); return; }
   g_confirm++; g_sigAge++;
   if(g_sigAge > SignalExpiryBars) { Log("Señal caducada"); g_pending=0; return; }
   if(g_confirm < ConfirmBars) return;

   // ── Filtros ──
   string why="";
   if(g_tradesToday>=MaxTradesPerDay) why="máx. trades del día";
   else if(g_barsSinceClose<CooldownBars) why="cooldown";
   else if(!InSession()) why="fuera de sesión";
   else if(atr<MinATR_USD) why=StringFormat("ATR bajo %.2f$", atr);
   else if(atr>MaxATR_USD) why=StringFormat("ATR alto %.2f$ (noticia?)", atr);
   else if(GM_GetSpread(_Symbol)>MaxSpreadPts) why="spread alto";
   else if(UseNewsFilter && g_news.IsNewsTime(NewsFreezeMin,3)) why="noticia de alto impacto";
   else if(g_stopTicket>0 && OrderSelect(g_stopTicket)) why="orden stop ya colocada";
   if(why!="") { Panel(trend, atr, why); return; }

   double ef=Buf(hEF,1), es=Buf(hES,1), et=Buf(hET,1), rsi=Buf(hRSI,1);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   bool emaGap = MathAbs(ef-es) >= atr*MinEMAGap_ATR;
   GMSState H = GMS_Analyze(_Symbol, HTF, 3, 300);
   int dxyBias = (UseDXYFilter && g_dxy.Ready()) ? g_dxy.GoldBias(_Symbol, PERIOD_H1) : 0;
   double comp = (UseIntelBridge && g_bridge.Valid()) ? g_bridge.Composite() : 0;

   int dir=g_pending;
   bool ok = (dir>0 ? EnableBuy : EnableSell) && emaGap
          && (dir>0 ? (ef>es && ask>et && rsi>=RSI_BullMin && rsi<=RSI_BullMax)
                    : (ef<es && bid<et && rsi>=RSI_BearMin && rsi<=RSI_BearMax))
          && (!RequireHTFStructure || H.trend==dir)
          && !(dxyBias==-dir)
          && !(dir>0 ? comp<=-IntelVeto : comp>=IntelVeto);
   Log(StringFormat("EVAL %s | EMA %s RSI %.1f HTF %s DXY %+d intel %+.2f → %s", dir>0?"BUY":"SELL",
       dir>0?(ef>es?"ok":"no"):(ef<es?"ok":"no"), rsi, GMS_TrendName(H.trend), dxyBias, comp, ok?"ENTRAR":"no"));
   if(!ok) { Panel(trend, atr, "condiciones incompletas"); return; }

   // ── SL / TP ──
   double entry, sl;
   if(dir>0) {
      entry = UseStopEntry ? g_sigHigh + atr*StopBufferATR : ask;
      if(UseStopEntry && entry<=ask) entry=ask+atr*StopBufferATR;
      sl = entry - atr*SL_ATR_Mult;
      if(SL_BehindSwing) for(int i=ns-1;i>=0;i--) if(!sw[i].high) { sl=MathMin(sl, sw[i].p-atr*0.2); break; }
   } else {
      entry = UseStopEntry ? g_sigLow - atr*StopBufferATR : bid;
      if(UseStopEntry && entry>=bid) entry=bid-atr*StopBufferATR;
      sl = entry + atr*SL_ATR_Mult;
      if(SL_BehindSwing) for(int i=ns-1;i>=0;i--) if(sw[i].high) { sl=MathMax(sl, sw[i].p+atr*0.2); break; }
   }
   double risk=MathAbs(entry-sl);
   if(risk > atr*4) { Log("SL demasiado lejos, se omite"); g_pending=0; return; }
   double tp = entry + dir*risk*TP2_R;
   double lots = GM_CalcLot(_Symbol, RiskPercent, risk, RiskCashPerTrade);
   if(lots<=0) { g_pending=0; return; }
   entry=NormalizeDouble(entry,_Digits); sl=NormalizeDouble(sl,_Digits); tp=NormalizeDouble(tp,_Digits);
   bool sent;
   if(UseStopEntry) {
      sent = dir>0 ? trade.BuyStop(lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,"GM_SCALP_BS")
                   : trade.SellStop(lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,"GM_SCALP_SS");
      if(sent) { g_stopTicket=trade.ResultOrder(); g_stopTime=TimeCurrent(); }
   } else {
      sent = dir>0 ? trade.Buy(lots,_Symbol,ask,sl,tp,"GM_SCALP_B") : trade.Sell(lots,_Symbol,bid,sl,tp,"GM_SCALP_S");
      if(sent) g_tradesToday++;
   }
   Log(StringFormat("%s %s %.2f lots @%.2f SL %.2f TP %.2f (%.1fR) %s", sent?"✅":"❌", dir>0?"BUY":"SELL", lots, entry, sl, tp, TP2_R,
       sent?"":IntegerToString(trade.ResultRetcode())));
   g_pending=0;
   Panel(trend, atr, sent?"orden enviada":"error al enviar");
}

void Panel(int trend, double atr, string status) {
   string dx = g_dxy.Ready() ? StringFormat("DXY %.3f (Δ24h %+.2f%%) %s", g_dxy.Value(PERIOD_H1,0), g_dxy.ChangePct(PERIOD_H1,24),
               g_dxy.Mode()) : "DXY no disponible";
   string in = (UseIntelBridge && g_bridge.Valid()) ? g_bridge.Status() : "Intel dashboard: sin datos";
   g_panel.Show(StringFormat("GOLD MASTER · SCALPER v2\nMicro: %s · ATR %.2f$ · Trades hoy %d/%d\n%s\n%s\nEstado: %s",
           GMS_TrendName(trend), atr, g_tradesToday, MaxTradesPerDay, dx, in, status));
}

void OnChartEvent(const int id,const long &l,const double &d,const string &s){ g_panel.OnEvent(id,l,d,s); }

// FIX#4: RegisterTrade — registra P&L en el panel de sesión cuando cierra una posición
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest    &req,
                        const MqlTradeResult     &res)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong deal = trans.deal;
   if(!HistoryDealSelect(deal)) return;
   if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;
   if(HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber)    return;
   double profit = HistoryDealGetDouble(deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal, DEAL_SWAP)
                 + HistoryDealGetDouble(deal, DEAL_COMMISSION);
   g_panel.RegisterTrade(profit);
}
