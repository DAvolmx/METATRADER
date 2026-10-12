//+------------------------------------------------------------------+
//|  GOLD_MASTER_STRUCTURE_EA.mq5                                    |
//|  Estrategia de ESTRUCTURA multi-temporalidad con Buy/Sell Stop   |
//|                                                                  |
//|  1. Tendencia MAYOR (HTF, H1): swings confirmados → HH/HL o LH/LL|
//|     + último BOS / CHoCH.                                        |
//|  2. MICRO tendencia (LTF, M5): mismo análisis en temporalidad    |
//|     baja. Se opera SÓLO cuando la micro-estructura vuelve a      |
//|     alinearse con la mayor (CHoCH/BOS a favor tras un retroceso).|
//|  3. NIVELES ESTRUCTURALES: zonas donde el precio ya reaccionó    |
//|     ≥ N veces (clusters de swings H1/H4). Se usan para:          |
//|       - no entrar si hay un nivel fuerte en contra muy cerca     |
//|       - poner el TP en el siguiente nivel (si da RR mínimo)      |
//|  4. Entrada: BUY STOP sobre el último swing high micro           |
//|             SELL STOP bajo el último swing low micro             |
//|     SL: detrás del último swing opuesto micro (+ margen ATR)     |
//|  5. La pendiente se cancela si la micro-estructura se rompe en   |
//|     contra (CHoCH contrario) o expira.                           |
//+------------------------------------------------------------------+
#property copyright "David Domez — GOLD MASTER SYSTEM"
#property version   "1.00"
#property strict

#include <GoldMaster/GoldMaster_Core.mqh>
#include <GoldMaster/GoldMaster_PendingOrders.mqh>
#include <GoldMaster/GoldMaster_PositionManager.mqh>
#include <GoldMaster/GoldMaster_DXY.mqh>
#include <GoldMaster/GoldMaster_Panel.mqh>
#include <GoldMaster/GoldMaster_Assets.mqh>
CGMPanel g_panel;
GM_AssetProfile g_asset;   // perfil del activo detectado automáticamente

input group "=== TEMPORALIDADES ==="
input ENUM_TIMEFRAMES HTF          = PERIOD_H1;   // tendencia mayor
input ENUM_TIMEFRAMES LTF          = PERIOD_M5;   // micro tendencia / ejecución
input ENUM_TIMEFRAMES LevelsTF     = PERIOD_H4;   // niveles estructurales
input int    SwingStrengthHTF      = 3;           // velas a cada lado para confirmar swing (HTF)
input int    SwingStrengthLTF      = 2;           // idem LTF
input int    LookbackHTF           = 150;
input int    LookbackLTF           = 200;

input group "=== NIVELES ESTRUCTURALES ==="
input int    LevelsLookback        = 300;         // velas de LevelsTF a escanear
input double LevelTolATR           = 0.35;        // tolerancia de cluster (× ATR del nivel)
input int    LevelMinTouches       = 2;           // toques mínimos para considerar nivel
input double MinRoomR              = 1.5;         // espacio libre mínimo (en R) hasta nivel contrario
input bool   TPAtNextLevel         = true;        // TP en siguiente nivel si RR ≥ MinRR

input group "=== ENTRADA / RIESGO ==="
input double RiskPct               = 1.0;
input double RiskCashPerTrade      = 0.0; // 0: porcentual; >0: tope de pérdida al SL en moneda de cuenta
input double MinRR                 = 2.0;         // RR mínimo
input double MaxRR                 = 4.0;         // TP máximo en R
input double EntryBufferATR        = 0.10;        // buffer sobre/bajo el swing (× ATR LTF)
input double SLPadATR              = 0.30;        // margen del SL (× ATR LTF)
input double MinSL_ATR             = 0.8;         // SL mínimo (× ATR LTF) — evita stops ridículos
input double MaxSL_ATR             = 4.0;         // SL máximo (× ATR LTF)
input int    PendingExpiryBars     = 12;          // expira la pendiente tras N velas LTF
input double BE_R                  = 1.0;         // breakeven a N R (0 = off)
input double BE_NoDiv_R           = 1.5;         // lote no divisible (micro 0.1): mover stop a partir de N R
input double NoDiv_LockR          = 0.3;         // ...asegurando +N R (en vez de BE exacto)
input bool   RequireEMAAlign       = true;        // EMA50 > EMA200 en HTF para compras (y viceversa)

input group "=== DXY (índice del dólar) ==="
input bool   UseDXYFilter          = true;        // no comprar oro con dólar fuerte (ni vender con dólar débil)

input group "=== FILTROS ==="
input int    SessionStartHour      = 7;           // hora servidor
input int    SessionEndHour        = 20;
input int    MaxTradesPerDay       = 3;
input int    MaxSpreadPts          = 50;
input double MaxDailyDD_Pct        = 3.0;

input group "=== IDENTIFICACIÓN ==="
input int    MagicNumber           = 900010;
input string EA_Comment            = "GM_STRUCT";
input bool   DrawOnChart           = true;
input bool   Verbose               = true;

//──────────────────────────────────────────────────────────────────
struct Swing { datetime t; double price; bool high; };
struct Structure {
   int      trend;        // 1 alcista (HH+HL), -1 bajista (LH+LL), 0 rango
   int      last_event;   // 1 BOS bull, -1 BOS bear, 2 CHoCH bull, -2 CHoCH bear, 0 nada
   datetime event_time;
   double   last_high, prev_high, last_low, prev_low;
   datetime last_high_t, last_low_t;
   bool     valid;
};
struct Level { double price; int touches; bool resistance; };

CGoldMasterPending*         g_pending = NULL;
CGoldMasterPositionManager* g_posmgr  = NULL;
string   g_symbol;
int      h_atr_ltf, h_atr_lvl, h_ema50, h_ema200;
datetime g_last_ltf_bar = 0, g_day = 0;
double   g_day_balance = 0;
int      g_trades_today = 0;
ulong    g_buy_ticket = 0, g_sell_ticket = 0;
datetime g_buy_time = 0, g_sell_time = 0;
Level    g_levels[];
CGMDXY   g_dxy;
datetime g_used_buy_ev = 0, g_used_sell_ev = 0;   // un setup por evento BOS/CHoCH

//════════════════════════════════════════════════════════════════════
int OnInit() {
   g_asset = GM_GetProfile(_Symbol);
   GM_LogProfile(g_asset);
   GM_TFBadgeAsset("STRUCTURE EA", g_asset.tf_scalp, g_asset.name, g_asset.icon);
   if(!MQLInfoInteger(MQL_TESTER) && GM_IsDuplicateInstance()){ Print("[GM] Ya hay otra copia de este EA en ",_Symbol," → esta se retira"); ExpertRemove(); return INIT_SUCCEEDED; }
   g_panel.InitWithAsset("STRUCT",g_asset,10,30);
   if(MQLInfoInteger(MQL_TESTER)) g_panel.SetReplayMode(true,_Symbol);
   g_symbol  = _Symbol;
   g_pending = new CGoldMasterPending(g_symbol, MagicNumber, Verbose);
   g_posmgr  = new CGoldMasterPositionManager(MagicNumber, g_symbol);
   g_posmgr.SetBreakevenR(BE_R); g_posmgr.SetNoDivBE(BE_NoDiv_R,NoDiv_LockR);
   h_atr_ltf = iATR(g_symbol, LTF, 14);
   h_atr_lvl = iATR(g_symbol, LevelsTF, 14);
   h_ema50   = iMA(g_symbol, HTF, 50,  0, MODE_EMA, PRICE_CLOSE);
   h_ema200  = iMA(g_symbol, HTF, 200, 0, MODE_EMA, PRICE_CLOSE);
   if(h_atr_ltf==INVALID_HANDLE || h_ema50==INVALID_HANDLE) return INIT_FAILED;
   GM_SymbolReport(g_symbol, RiskPct, 10.0);
   if(UseDXYFilter) GM_Log("STRUCT", g_dxy.Init() ? "DXY: "+g_dxy.Mode() : "DXY no disponible → filtro desactivado", true);
   GM_Log("STRUCT", "EA de estructura iniciado — "+g_symbol+" HTF="+EnumToString(HTF)+" LTF="+EnumToString(LTF), true);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { g_panel.Destroy();
   if(g_pending) { delete g_pending; g_pending=NULL; }
   if(g_posmgr)  { delete g_posmgr;  g_posmgr=NULL; }
   IndicatorRelease(h_atr_ltf); IndicatorRelease(h_atr_lvl);
   IndicatorRelease(h_ema50);   IndicatorRelease(h_ema200);
   if(DrawOnChart) ObjectsDeleteAll(0, "GMS_");
}

//════════════════════════════════════════════════════════════════════
//  SWINGS (fractales confirmados — sin repintado)
//════════════════════════════════════════════════════════════════════
int GetSwings(ENUM_TIMEFRAMES tf, int strength, int lookback, Swing &out[]) {
   ArrayResize(out, 0);
   MqlRates r[]; ArraySetAsSeries(r, true);
   int n = CopyRates(g_symbol, tf, 0, lookback, r);
   if(n < strength*2+5) return 0;
   int cnt = 0;
   // recorrer de antiguo → reciente para que out[] quede en orden cronológico
   for(int i = n-1-strength; i >= strength+1; i--) {   // i≥strength+1 → vela 0 (abierta) nunca participa
      bool isH = true, isL = true;
      for(int k = 1; k <= strength; k++) {
         if(r[i].high <= r[i+k].high || r[i].high < r[i-k].high) isH = false;
         if(r[i].low  >= r[i+k].low  || r[i].low  > r[i-k].low)  isL = false;
      }
      if(isH) { ArrayResize(out, cnt+1); out[cnt].t=r[i].time; out[cnt].price=r[i].high; out[cnt].high=true;  cnt++; }
      if(isL) { ArrayResize(out, cnt+1); out[cnt].t=r[i].time; out[cnt].price=r[i].low;  out[cnt].high=false; cnt++; }
   }
   return cnt;
}

//════════════════════════════════════════════════════════════════════
//  ESTRUCTURA: tendencia + BOS / CHoCH
//════════════════════════════════════════════════════════════════════
Structure Analyze(ENUM_TIMEFRAMES tf, int strength, int lookback) {
   Structure s; ZeroMemory(s);
   Swing sw[]; int n = GetSwings(tf, strength, lookback, sw);
   if(n < 4) return s;
   // últimos 2 highs y 2 lows
   int hFound=0, lFound=0;
   for(int i=n-1; i>=0 && (hFound<2 || lFound<2); i--) {
      if(sw[i].high && hFound<2) { if(hFound==0){ s.last_high=sw[i].price; s.last_high_t=sw[i].t; } else s.prev_high=sw[i].price; hFound++; }
      if(!sw[i].high && lFound<2) { if(lFound==0){ s.last_low=sw[i].price; s.last_low_t=sw[i].t; } else s.prev_low=sw[i].price; lFound++; }
   }
   if(hFound<2 || lFound<2) return s;
   bool hh = s.last_high > s.prev_high, hl = s.last_low > s.prev_low;
   bool lh = s.last_high < s.prev_high, ll = s.last_low < s.prev_low;
   s.trend = (hh && hl) ? 1 : (lh && ll) ? -1 : 0;

   // BOS / CHoCH: ¿alguna vela CERRÓ más allá del último swing después de formarse?
   MqlRates r[]; ArraySetAsSeries(r, true);
   // P6 — usar lookback completo en lugar de 50 velas fijas
   int _scan = (tf == HTF) ? LookbackHTF : LookbackLTF;
   int k = CopyRates(g_symbol, tf, 1, _scan, r);
   for(int i=k-1; i>=0; i--) {
      if(r[i].time > s.last_high_t && r[i].close > s.last_high) {
         s.last_event = (s.trend == -1) ? 2 : 1;  s.event_time = r[i].time; break;   // rompió high
      }
      if(r[i].time > s.last_low_t && r[i].close < s.last_low) {
         s.last_event = (s.trend == 1) ? -2 : -1; s.event_time = r[i].time; break;   // rompió low
      }
   }
   // Un BOS/CHoCH redefine la tendencia vigente
   if(s.last_event == 1 || s.last_event == 2)   s.trend = 1;
   if(s.last_event == -1 || s.last_event == -2) s.trend = -1;
   s.valid = true;
   return s;
}

string EvName(int e) { return e==1?"BOS↑":e==2?"CHoCH↑":e==-1?"BOS↓":e==-2?"CHoCH↓":"—"; }

//════════════════════════════════════════════════════════════════════
//  NIVELES ESTRUCTURALES (zonas con varios toques)
//════════════════════════════════════════════════════════════════════
void BuildLevels() {
   ArrayResize(g_levels, 0);
   Swing sw[]; int n = GetSwings(LevelsTF, 2, LevelsLookback, sw);
   double atr = GM_GetATR(h_atr_lvl, 1);
   if(n == 0 || atr <= 0) return;
   double tol = atr * LevelTolATR;
   double px[]; int tc[]; ArrayResize(px, 0); ArrayResize(tc, 0);
   for(int i=0; i<n; i++) {
      int found = -1;
      for(int j=0; j<ArraySize(px); j++) if(MathAbs(px[j]-sw[i].price) <= tol) { found=j; break; }
      if(found < 0) { int m=ArraySize(px); ArrayResize(px,m+1); ArrayResize(tc,m+1); px[m]=sw[i].price; tc[m]=1; }
      else { px[found] = (px[found]*tc[found] + sw[i].price) / (tc[found]+1); tc[found]++; }
   }
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   for(int j=0; j<ArraySize(px); j++) {
      if(tc[j] < LevelMinTouches) continue;
      int m = ArraySize(g_levels); ArrayResize(g_levels, m+1);
      g_levels[m].price = px[j]; g_levels[m].touches = tc[j]; g_levels[m].resistance = (px[j] > bid);
   }
   if(DrawOnChart) {
      ObjectsDeleteAll(0, "GMS_LVL_");
      for(int j=0; j<ArraySize(g_levels); j++)
         GM_DrawHLine("GMS_LVL_"+IntegerToString(j), g_levels[j].price,
                      g_levels[j].resistance ? clrTomato : clrMediumSeaGreen, STYLE_DOT, (int)MathMin(3, g_levels[j].touches-1));
   }
}

// Nivel más cercano en una dirección (dir=1 arriba, -1 abajo) desde price
double NextLevel(double price, int dir) {
   double best = 0;
   for(int j=0; j<ArraySize(g_levels); j++) {
      double p = g_levels[j].price;
      if(dir == 1 && p > price && (best == 0 || p < best)) best = p;
      if(dir == -1 && p < price && (best == 0 || p > best)) best = p;
   }
   return best;
}

//════════════════════════════════════════════════════════════════════
bool OrderAlive(ulong t) { return (t > 0 && OrderSelect(t)); }

void CancelIf(ulong &t, string why) {
   if(OrderAlive(t)) { g_pending.CancelOrder(t); GM_Log("STRUCT", "Pendiente cancelada: "+why, Verbose); }
   t = 0;
}

void OnTick() {
   // Reset diario + DD
   datetime today = iTime(g_symbol, PERIOD_D1, 0);
   if(today != g_day) { g_day = today; g_day_balance = AccountInfoDouble(ACCOUNT_BALANCE); g_trades_today = 0; }
   double atr_ltf = GM_GetATR(h_atr_ltf, 1);
   if(atr_ltf > 0) g_posmgr.SetATR(atr_ltf);
   g_posmgr.ManageAll();

   // Detectar llenados (una pendiente desapareció y hay posición) → OCO + contador
   if(g_buy_ticket  > 0 && !OrderAlive(g_buy_ticket))  { g_buy_ticket  = 0; g_trades_today++; CancelIf(g_sell_ticket, "OCO"); }
   if(g_sell_ticket > 0 && !OrderAlive(g_sell_ticket)) { g_sell_ticket = 0; g_trades_today++; CancelIf(g_buy_ticket,  "OCO"); }

   // Sólo en vela nueva LTF
   datetime bar = iTime(g_symbol, LTF, 0);
   if(bar == g_last_ltf_bar) return;
   g_last_ltf_bar = bar;

   double dd = g_day_balance > 0 ? (g_day_balance - AccountInfoDouble(ACCOUNT_EQUITY)) / g_day_balance * 100 : 0;
   MqlDateTime now; TimeToStruct(TimeCurrent(), now);
   bool session = (now.hour >= SessionStartHour && now.hour < SessionEndHour);

   // Expiración de pendientes
   int lsec = PeriodSeconds(LTF);
   if(g_buy_ticket  && TimeCurrent() - g_buy_time  > PendingExpiryBars*lsec) CancelIf(g_buy_ticket,  "expirada");
   if(g_sell_ticket && TimeCurrent() - g_sell_time > PendingExpiryBars*lsec) CancelIf(g_sell_ticket, "expirada");
   if(!session) { CancelIf(g_buy_ticket, "fuera de sesión"); CancelIf(g_sell_ticket, "fuera de sesión"); return; }

   // ─── Análisis ───
   Structure H = Analyze(HTF, SwingStrengthHTF, LookbackHTF);
   Structure L = Analyze(LTF, SwingStrengthLTF, LookbackLTF);
   static datetime lvl_bar = 0;
   if(iTime(g_symbol, LevelsTF, 0) != lvl_bar) { lvl_bar = iTime(g_symbol, LevelsTF, 0); BuildLevels(); }
   if(!H.valid || !L.valid || atr_ltf <= 0) return;

   double e50 = GM_GetEMA(h_ema50, 1), e200 = GM_GetEMA(h_ema200, 1);
   int emaBias = (e50 > e200) ? 1 : (e50 < e200) ? -1 : 0;
   int dxyBias = (UseDXYFilter && g_dxy.Ready()) ? g_dxy.GoldBias(g_symbol, PERIOD_H1) : 0;
   double dxyVal = g_dxy.Ready() ? g_dxy.Value(PERIOD_H1,0) : 0, dxyChg = g_dxy.Ready() ? g_dxy.ChangePct(PERIOD_H1,24) : 0;
   int bias = H.trend;
   if(RequireEMAAlign && bias != emaBias) bias = 0;
   if(dxyBias != 0 && bias == -dxyBias) bias = 0;          // DXY empuja en contra → no operar

   g_panel.Show(StringFormat("GOLD MASTER · ESTRUCTURA\nHTF %s: %s  último %s\nLTF %s: %s  último %s\nEMA50/200: %s\nDXY: %.3f (Δ24h %+.2f%%) → %s\nNiveles: %d  |  Trades hoy: %d  |  DD día: %.2f%%",
           EnumToString(HTF), H.trend==1?"ALCISTA":H.trend==-1?"BAJISTA":"RANGO", EvName(H.last_event),
           EnumToString(LTF), L.trend==1?"ALCISTA":L.trend==-1?"BAJISTA":"RANGO", EvName(L.last_event),
           emaBias==1?"alcista":emaBias==-1?"bajista":"plana",
           dxyVal, dxyChg, dxyBias>0?"favorece COMPRAS de oro":dxyBias<0?"favorece VENTAS de oro":"neutral", ArraySize(g_levels), g_trades_today, dd));

   // Invalidación: micro-estructura gira en contra → cancelar pendiente de ese lado
   if(L.trend == -1) CancelIf(g_buy_ticket,  "CHoCH micro bajista");
   if(L.trend ==  1) CancelIf(g_sell_ticket, "CHoCH micro alcista");
   if(bias != 1)  CancelIf(g_buy_ticket,  "tendencia mayor ya no alcista");
   if(bias != -1) CancelIf(g_sell_ticket, "tendencia mayor ya no bajista");

   // Filtros de nuevas órdenes
   if(dd >= MaxDailyDD_Pct || g_trades_today >= MaxTradesPerDay) return;
   if(GM_GetSpread(g_symbol) > MaxSpreadPts) return;
   if(g_posmgr.CountPositions() > 0) return;          // una operación a la vez

   // ─── COMPRA: HTF alcista + micro alineada (acaba de hacer BOS/CHoCH alcista) ───
   if(bias == 1 && L.trend == 1 && (L.last_event == 1 || L.last_event == 2) && L.event_time != g_used_buy_ev && !OrderAlive(g_buy_ticket)) {
      double entry = L.last_high + atr_ltf * EntryBufferATR;
      double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
      if(entry <= ask) entry = ask + atr_ltf * EntryBufferATR;           // ya rompió: siguiente tick sobre el precio
      double sl = L.last_low - atr_ltf * SLPadATR;
      double risk = entry - sl;
      if(risk >= atr_ltf*MinSL_ATR && risk <= atr_ltf*MaxSL_ATR) {
         double lvl = NextLevel(entry, 1);
         double room = (lvl > 0) ? (lvl - entry) / risk : 99;
         if(room >= MinRoomR) {
            double tp = entry + risk * MinRR;
            if(TPAtNextLevel && lvl > 0 && room >= MinRR) tp = entry + MathMin(lvl - entry - atr_ltf*0.1, risk*MaxRR);
            double lot = GM_CalcLot(g_symbol, RiskPct, risk, RiskCashPerTrade);
            if(lot > 0) {
               g_buy_ticket = g_pending.PlaceBuyStop(entry, sl, tp, lot, EA_Comment+"_B");
               g_buy_time = TimeCurrent(); g_used_buy_ev = L.event_time;
               GM_Log("STRUCT", StringFormat("BUY STOP %.2f SL %.2f TP %.2f | HTF %s LTF %s | espacio %.1fR",
                      entry, sl, tp, EvName(H.last_event), EvName(L.last_event), room), true);
               if(DrawOnChart) GM_DrawText("GMS_B_"+TimeToString(bar), bar, entry, "▲ "+EvName(L.last_event), clrDeepSkyBlue);
            }
         } else GM_Log("STRUCT", StringFormat("Compra descartada: resistencia en %.2f a sólo %.1fR", lvl, room), Verbose);
      }
   }
   // ─── VENTA ───
   if(bias == -1 && L.trend == -1 && (L.last_event == -1 || L.last_event == -2) && L.event_time != g_used_sell_ev && !OrderAlive(g_sell_ticket)) {
      double entry = L.last_low - atr_ltf * EntryBufferATR;
      double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
      if(entry >= bid) entry = bid - atr_ltf * EntryBufferATR;
      double sl = L.last_high + atr_ltf * SLPadATR;
      double risk = sl - entry;
      if(risk >= atr_ltf*MinSL_ATR && risk <= atr_ltf*MaxSL_ATR) {
         double lvl = NextLevel(entry, -1);
         double room = (lvl > 0) ? (entry - lvl) / risk : 99;
         if(room >= MinRoomR) {
            double tp = entry - risk * MinRR;
            if(TPAtNextLevel && lvl > 0 && room >= MinRR) tp = entry - MathMin(entry - lvl - atr_ltf*0.1, risk*MaxRR);
            double lot = GM_CalcLot(g_symbol, RiskPct, risk, RiskCashPerTrade);
            if(lot > 0) {
               g_sell_ticket = g_pending.PlaceSellStop(entry, sl, tp, lot, EA_Comment+"_S");
               g_sell_time = TimeCurrent(); g_used_sell_ev = L.event_time;
               GM_Log("STRUCT", StringFormat("SELL STOP %.2f SL %.2f TP %.2f | HTF %s LTF %s | espacio %.1fR",
                      entry, sl, tp, EvName(H.last_event), EvName(L.last_event), room), true);
               if(DrawOnChart) GM_DrawText("GMS_S_"+TimeToString(bar), bar, entry, "▼ "+EvName(L.last_event), clrOrangeRed);
            }
         } else GM_Log("STRUCT", StringFormat("Venta descartada: soporte en %.2f a sólo %.1fR", lvl, room), Verbose);
      }
   }
}

void OnChartEvent(const int id,const long &l,const double &d,const string &s){ g_panel.OnEvent(id,l,d,s); }
