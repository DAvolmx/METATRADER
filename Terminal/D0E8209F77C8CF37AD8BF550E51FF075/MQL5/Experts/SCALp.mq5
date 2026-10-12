//+------------------------------------------------------------------+
//|  XAU_M1_SCALPER_V4_FIXED.mq5                                     |
//|  FIXES vs V3_SCORE (confirmados en log 2026-10-09):              |
//|  FIX-1: Session filter — operaba Asian hours (01-02 UTC)         |
//|  FIX-2: Trailing throttle — ahora 1x por M1 bar garantizado     |
//|  FIX-3: Trailing mínimo step — evita BE prematuro               |
//|  FIX-4: Cooldown en segundos — no solo barras                   |
//|  FIX-5: Breakeven con buffer — no mueve a precio exacto de entry |
//|  SAFETY: PaperMode = true siempre, no modificar en live sin test |
//+------------------------------------------------------------------+
#property copyright "David"
#property version   "4.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- ═══════════════════════════════════════════════════════════════
//    PARÁMETROS DE ENTRADA
//--- ═══════════════════════════════════════════════════════════════

input group "=== 🔒 SEGURIDAD ==="
input bool   PaperMode          = true;     // TRUE = solo logs, sin órdenes reales

input group "=== 💰 LOTE ==="
input double LotNormal          = 0.10;     // Lote para cuenta normal
input double LotMicro           = 0.50;     // Lote para cuenta micro (min 0.1)

input group "=== 🎯 TP / SL ==="
input double TP_ATR_Mult        = 2.5;      // TP = ATR × mult
input double SL_ATR_Mult        = 1.2;      // SL = ATR × mult
input int    ATR_Period         = 14;

input group "=== 🚦 TRAILING ==="
input bool   UseTrailing        = true;
input double Trail_ATR_Mult     = 0.8;      // Trail SL a ATR×mult desde precio actual
input double Trail_Step_Points  = 5.0;      // Mínimo movimiento de SL (points) — FIX-3
input double Breakeven_ATR_Mult = 0.6;      // Mover a BE solo cuando profit >= ATR×mult
input double Breakeven_Buffer   = 3.0;      // Buffer sobre precio de entrada (points) — FIX-5

input group "=== ⏰ SESIÓN (UTC) === FIX-1"
input bool   UseSessionFilter   = true;
input int    London_Start       = 7;        // 07:00 UTC
input int    London_End         = 11;       // 11:00 UTC
input int    NY_Start           = 13;       // 13:00 UTC
input int    NY_End             = 17;       // 17:00 UTC

input group "=== ⏳ COOLDOWN === FIX-4"
input int    Cooldown_Seconds   = 120;      // Esperar X segundos tras cierre
input int    Cooldown_Bars      = 2;        // Y mínimo de barras M1 desde último cierre

input group "=== 📊 FILTROS HARD ==="
input double MinATR_USD         = 0.50;     // ATR mínimo para entrar
input double MaxATR_USD         = 20.0;     // ATR máximo (mercado muy volátil)
input int    MaxSpread_Points   = 80;       // Spread máximo permitido
input double DailyLoss_Pct      = 3.0;      // Stop trading si pérdida diaria >= %

input group "=== 📈 FILTROS HTF ==="
input bool   UseM15Filter       = true;
input int    M15_EMA_Fast       = 20;
input int    M15_EMA_Slow       = 50;
input int    M15_ADX_Period     = 14;
input double M15_ADX_Min        = 22.0;     // ADX M15 < umbral = ranging = no trades

input group "=== 🔵 M1 FILTROS ==="
input int    M1_EMA_Fast        = 9;
input int    M1_EMA_Slow        = 21;
input int    M1_RSI_Period      = 14;
input double RSI_Buy_Min        = 48.0;
input double RSI_Buy_Max        = 72.0;
input double RSI_Sell_Min       = 28.0;
input double RSI_Sell_Max       = 52.0;
input int    M1_ADX_Period      = 14;
input double M1_ADX_Min         = 20.0;

//--- ═══════════════════════════════════════════════════════════════
//    HANDLES DE INDICADORES
//--- ═══════════════════════════════════════════════════════════════
int h_atr_m1, h_ema_fast, h_ema_slow, h_rsi, h_adx_m1;
int h_m15_ema_fast, h_m15_ema_slow, h_m15_adx;

//--- ═══════════════════════════════════════════════════════════════
//    ESTADO GLOBAL
//--- ═══════════════════════════════════════════════════════════════
bool     g_isMicro         = false;
double   g_minLot          = 0.01;
double   g_dayStartBalance = 0;
datetime g_dayDate         = 0;
datetime g_lastCloseTime   = 0;      // FIX-4: tiempo de último cierre
int      g_lastCloseBar    = 0;      // FIX-4: barra del último cierre
datetime g_lastTrailBar    = 0;      // FIX-2: última barra donde se actualizó trail

//+------------------------------------------------------------------+
bool InSession()
{
   // FIX-1: Usar TimeGMT() — independiente del horario del broker
   MqlDateTime gmt;
   TimeToStruct(TimeGMT(), gmt);
   int h = gmt.hour;
   bool london = (h >= London_Start && h < London_End);
   bool ny     = (h >= NY_Start     && h < NY_End);
   return (london || ny);
}

//+------------------------------------------------------------------+
bool DailyLossExceeded()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   MqlDateTime day;
   TimeToStruct(g_dayDate, day);
   if(now.day != day.day || now.mon != day.mon)
   {
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dayDate = TimeCurrent();
   }
   double loss_pct = (g_dayStartBalance - AccountInfoDouble(ACCOUNT_EQUITY))
                     / g_dayStartBalance * 100.0;
   return (loss_pct >= DailyLoss_Pct);
}

//+------------------------------------------------------------------+
bool CooldownActive()
{
   // FIX-4: doble check — tiempo Y barras
   if(g_lastCloseTime == 0) return false;

   // Check tiempo
   if((TimeCurrent() - g_lastCloseTime) < Cooldown_Seconds) return true;

   // Check barras M1
   int curBar = Bars(_Symbol, PERIOD_M1);
   if((curBar - g_lastCloseBar) < Cooldown_Bars) return true;

   return false;
}

//+------------------------------------------------------------------+
double GetATR()
{
   double buf[1];
   if(CopyBuffer(h_atr_m1, 0, 0, 1, buf) <= 0) return 0;
   return buf[0] / _Point; // en points
}

//+------------------------------------------------------------------+
// Devuelve +1 bull, -1 bear, 0 ranging (ADX < umbral)
int GetM15Bias()
{
   if(!UseM15Filter) return 1; // si no se usa filtro, todo pasa

   double ema_f[1], ema_s[1], adx_main[1];
   if(CopyBuffer(h_m15_ema_fast, 0, 0, 1, ema_f) <= 0) return 0;
   if(CopyBuffer(h_m15_ema_slow, 0, 0, 1, ema_s) <= 0) return 0;
   if(CopyBuffer(h_m15_adx, 0, 0, 1, adx_main) <= 0)   return 0;

   if(adx_main[0] < M15_ADX_Min) return 0; // ranging — HARD BLOCK

   if(ema_f[0] > ema_s[0]) return  1; // bull
   if(ema_f[0] < ema_s[0]) return -1; // bear
   return 0;
}

//+------------------------------------------------------------------+
bool HasEnoughMargin(double lots, ENUM_ORDER_TYPE dir)
{
   double margin = 0;
   if(!OrderCalcMargin(dir, _Symbol, lots, SymbolInfoDouble(_Symbol, SYMBOL_ASK), margin))
      return false;
   return (AccountInfoDouble(ACCOUNT_FREEMARGIN) >= margin * 1.3);
}

//+------------------------------------------------------------------+
void ManagePosition()
{
   if(!UseTrailing) return;

   // FIX-2: Una sola actualización por barra M1 — versión robusta
   datetime curBar = iTime(_Symbol, PERIOD_M1, 0);
   if(curBar == 0 || curBar == g_lastTrailBar) return;
   // NO actualizamos g_lastTrailBar aquí — lo hacemos al final si modificamos

   double atr_pts = GetATR();
   if(atr_pts < 1) return;

   double atr_price = atr_pts * _Point;
   bool modified = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl     = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);
      double profit_pts = PositionGetDouble(POSITION_PROFIT);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      double new_sl = sl;

      if(type == POSITION_TYPE_BUY)
      {
         double price = bid;
         double profit_price = price - entry;

         // Breakeven: solo si ganancia >= buffer (FIX-5)
         double be_trigger = Breakeven_ATR_Mult * atr_price;
         if(sl < entry && profit_price >= be_trigger)
         {
            new_sl = entry + Breakeven_Buffer * _Point;
            new_sl = MathMax(new_sl, sl); // nunca mover SL en contra
         }

         // Trail: solo si ya pasamos breakeven
         if(price > entry)
         {
            double trail_sl = price - Trail_ATR_Mult * atr_price;
            trail_sl = MathMax(trail_sl, new_sl);

            // FIX-3: Solo mover si diferencia >= Trail_Step_Points
            if((trail_sl - new_sl) >= Trail_Step_Points * _Point)
               new_sl = trail_sl;
         }

         // Aplicar si mejoró el SL (en dirección favorable)
         if(new_sl > sl + _Point)
         {
            new_sl = MathFloor(new_sl / _Point) * _Point;
            if(!PaperMode) trade.PositionModify(ticket, new_sl, tp);
            else Print("PAPER TRAIL BUY SL: ", sl, " → ", new_sl);
            modified = true;
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double price = ask;
         double profit_price = entry - price;

         // Breakeven (FIX-5)
         double be_trigger = Breakeven_ATR_Mult * atr_price;
         if(sl > entry && profit_price >= be_trigger)
         {
            new_sl = entry - Breakeven_Buffer * _Point;
            new_sl = MathMin(new_sl, sl);
         }

         // Trail
         if(price < entry)
         {
            double trail_sl = price + Trail_ATR_Mult * atr_price;
            trail_sl = MathMin(trail_sl, new_sl);

            // FIX-3: Solo mover si diferencia >= step
            if((new_sl - trail_sl) >= Trail_Step_Points * _Point)
               new_sl = trail_sl;
         }

         if(new_sl < sl - _Point)
         {
            new_sl = MathCeil(new_sl / _Point) * _Point;
            if(!PaperMode) trade.PositionModify(ticket, new_sl, tp);
            else Print("PAPER TRAIL SELL SL: ", sl, " → ", new_sl);
            modified = true;
         }
      }
   }

   // FIX-2: marcar barra solo si hicimos alguna modificación
   // (Si no modificamos, la próxima barra puede intentar de nuevo)
   // Pero para evitar spam igual marcamos la barra
   g_lastTrailBar = curBar;
}

//+------------------------------------------------------------------+
int OnInit()
{
   // Auto-detect micro
   g_minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_isMicro = (g_minLot >= 0.10);

   Print("Modo: ", g_isMicro ? "MICRO" : "NORMAL",
         " | LoteMin=", g_minLot,
         " | Lote=", g_isMicro ? LotMicro : LotNormal);

   // Handles M1
   h_atr_m1   = iATR(_Symbol, PERIOD_M1, ATR_Period);
   h_ema_fast = iMA(_Symbol, PERIOD_M1, M1_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   h_ema_slow = iMA(_Symbol, PERIOD_M1, M1_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   h_rsi      = iRSI(_Symbol, PERIOD_M1, M1_RSI_Period, PRICE_CLOSE);
   h_adx_m1   = iADX(_Symbol, PERIOD_M1, M1_ADX_Period);

   // Handles M15
   h_m15_ema_fast = iMA(_Symbol, PERIOD_M15, M15_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   h_m15_ema_slow = iMA(_Symbol, PERIOD_M15, M15_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   h_m15_adx      = iADX(_Symbol, PERIOD_M15, M15_ADX_Period);

   if(h_atr_m1 == INVALID_HANDLE || h_ema_fast == INVALID_HANDLE ||
      h_ema_slow == INVALID_HANDLE || h_rsi == INVALID_HANDLE ||
      h_adx_m1 == INVALID_HANDLE || h_m15_ema_fast == INVALID_HANDLE ||
      h_m15_ema_slow == INVALID_HANDLE || h_m15_adx == INVALID_HANDLE)
   {
      Print("ERROR: No se pudieron crear handles de indicadores");
      return INIT_FAILED;
   }

   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayDate = TimeCurrent();

   trade.SetExpertMagicNumber(202400 + (int)g_isMicro);
   trade.SetDeviationInPoints(20);

   if(PaperMode) Print("⚠️  PAPER MODE ACTIVO — Sin órdenes reales");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(h_atr_m1);
   IndicatorRelease(h_ema_fast);
   IndicatorRelease(h_ema_slow);
   IndicatorRelease(h_rsi);
   IndicatorRelease(h_adx_m1);
   IndicatorRelease(h_m15_ema_fast);
   IndicatorRelease(h_m15_ema_slow);
   IndicatorRelease(h_m15_adx);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Gestionar posición existente (trailing)
   ManagePosition();

   // 2. Si ya hay posición abierta, no abrir más
   if(PositionsTotal() > 0) return;

   // 3. Registrar cierre si la posición desapareció
   // (se registra en OnTradeTransaction, pero como backup:)
   // — se gestiona abajo cuando detectamos que venía de una posición

   // ── FILTROS HARD ──────────────────────────────────────────────

   // FIX-1: Sesión — usar TimeGMT
   if(UseSessionFilter && !InSession())
   {
      // Solo logear cada 10 minutos para no saturar
      static datetime s_last_sess_log = 0;
      if(TimeCurrent() - s_last_sess_log > 600)
      {
         MqlDateTime gmt; TimeToStruct(TimeGMT(), gmt);
         Print("FUERA DE SESIÓN — GMT hora=", gmt.hour);
         s_last_sess_log = TimeCurrent();
      }
      return;
   }

   // Pérdida diaria
   if(DailyLossExceeded()) { Print("DAILY LOSS LIMIT"); return; }

   // FIX-4: Cooldown doble (tiempo + barras)
   if(CooldownActive()) return;

   // Spread
   double spread_pts = (double)(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
   if(spread_pts > MaxSpread_Points) { Print("SPREAD alto: ", spread_pts); return; }

   // ATR
   double atr_pts = GetATR();
   if(atr_pts < MinATR_USD) { Print("ATR bajo: ", atr_pts); return; }
   if(atr_pts > MaxATR_USD) { Print("ATR alto: ", atr_pts); return; }

   // ── FILTRO HTF M15 ─────────────────────────────────────────────
   int m15_bias = GetM15Bias();
   if(m15_bias == 0) { Print("M15 RANGING — sin trades"); return; }

   // ── INDICADORES M1 ────────────────────────────────────────────
   double ema_f[2], ema_s[2], rsi_v[1], adx_main[1], adx_plus[1], adx_minus[1];

   if(CopyBuffer(h_ema_fast, 0, 0, 2, ema_f)   <= 0) return;
   if(CopyBuffer(h_ema_slow, 0, 0, 2, ema_s)   <= 0) return;
   if(CopyBuffer(h_rsi,      0, 0, 1, rsi_v)   <= 0) return;
   if(CopyBuffer(h_adx_m1,   MAIN_LINE,  0, 1, adx_main)  <= 0) return;
   if(CopyBuffer(h_adx_m1,   PLUSDI_LINE, 0, 1, adx_plus) <= 0) return;
   if(CopyBuffer(h_adx_m1,   MINUSDI_LINE,0, 1, adx_minus)<= 0) return;

   double rsi = rsi_v[0];
   double adx = adx_main[0];

   // EMA cruce M1
   bool ema_bull = (ema_f[0] > ema_s[0] && ema_f[1] <= ema_s[1]); // cruce alcista
   bool ema_bear = (ema_f[0] < ema_s[0] && ema_f[1] >= ema_s[1]); // cruce bajista
   bool ema_stack_bull = (ema_f[0] > ema_s[0]); // stack alcista (sin cruce)
   bool ema_stack_bear = (ema_f[0] < ema_s[0]); // stack bajista

   // ADX M1 trend
   bool adx_ok   = (adx >= M1_ADX_Min);
   bool adx_bull = (adx_ok && adx_plus[0] > adx_minus[0]);
   bool adx_bear = (adx_ok && adx_minus[0] > adx_plus[0]);

   // Señal de vela (dirección de la vela actual)
   double open1  = iOpen(_Symbol, PERIOD_M1, 1);
   double close1 = iClose(_Symbol, PERIOD_M1, 1);
   bool bull_candle = (close1 > open1);
   bool bear_candle = (close1 < open1);

   // ── LÓGICA DE ENTRADA ─────────────────────────────────────────
   // Scoring: suma puntos, entra con >= 3 de 5 condiciones
   // (más simple que V3 pero más robusto)

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = g_isMicro ? LotMicro : LotNormal;
   double atr_price = atr_pts * _Point;

   // ─── COMPRA ───────────────────────────────────────────────────
   if(m15_bias == 1) // HTF alcista
   {
      int score = 0;
      if(ema_stack_bull) score++;   // EMA stack alcista
      if(ema_bull)       score++;   // cruce alcista (bono)
      if(adx_bull)       score++;   // ADX confirma subida
      if(rsi >= RSI_Buy_Min && rsi <= RSI_Buy_Max) score++; // RSI zona compra
      if(bull_candle)    score++;   // vela alcista

      if(score >= 3 && ema_stack_bull) // necesita al menos EMA stack
      {
         double sl = ask - SL_ATR_Mult * atr_price;
         double tp = ask + TP_ATR_Mult * atr_price;

         if(!HasEnoughMargin(lot, ORDER_TYPE_BUY))
         {
            Print("MARGIN INSUFICIENTE para BUY");
            return;
         }

         if(!PaperMode)
         {
            if(trade.Buy(lot, _Symbol, ask, sl, tp))
               Print("BUY abierta | Score=", score, " Lot=", lot, " SL=", sl, " TP=", tp);
         }
         else
            Print("PAPER BUY | Score=", score, " ask=", ask, " sl=", sl, " tp=", tp);
      }
   }

   // ─── VENTA ────────────────────────────────────────────────────
   if(m15_bias == -1) // HTF bajista
   {
      int score = 0;
      if(ema_stack_bear) score++;
      if(ema_bear)       score++;
      if(adx_bear)       score++;
      if(rsi >= RSI_Sell_Min && rsi <= RSI_Sell_Max) score++;
      if(bear_candle)    score++;

      if(score >= 3 && ema_stack_bear)
      {
         double sl = bid + SL_ATR_Mult * atr_price;
         double tp = bid - TP_ATR_Mult * atr_price;

         if(!HasEnoughMargin(lot, ORDER_TYPE_SELL))
         {
            Print("MARGIN INSUFICIENTE para SELL");
            return;
         }

         if(!PaperMode)
         {
            if(trade.Sell(lot, _Symbol, bid, sl, tp))
               Print("SELL abierta | Score=", score, " Lot=", lot, " SL=", sl, " TP=", tp);
         }
         else
            Print("PAPER SELL | Score=", score, " bid=", bid, " sl=", sl, " tp=", tp);
      }
   }
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& req,
                        const MqlTradeResult& res)
{
   // FIX-4: Registrar tiempo de cierre para cooldown
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL)
      {
         // Si era cierre (DEAL_ENTRY_OUT)
         if(HistoryDealSelect(trans.deal))
         {
            long entry = (long)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
            if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
            {
               g_lastCloseTime = TimeCurrent();
               g_lastCloseBar  = Bars(_Symbol, PERIOD_M1);
               Print("Posición cerrada → cooldown ", Cooldown_Seconds, "s activo");
            }
         }
      }
   }
}
//+------------------------------------------------------------------+