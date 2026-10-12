//+------------------------------------------------------------------+
//|  XAU_M1_SCALPER_V5_ML.mq5                                        |
//|  V4 + Capa de Machine Learning (XGBoost → ONNX)                  |
//|  FIXES incluidos (V4): FIX-1..5                                   |
//|  NUEVO (V5): Filtro ML — prob_buy>=0.60 para BUY, <=0.40 SELL    |
//|  Modelo: xau_signal_model.onnx (H1 XGBoost, 16 features)         |
//|  SAFETY: PaperMode = true siempre, no activar live sin demo 48h  |
//+------------------------------------------------------------------+
#property copyright "David Domez — GOLD MASTER SYSTEM"
#property version   "5.00"
#property strict

#include <Trade\Trade.mqh>
#include <GoldMaster\GoldMaster_ML_ONNX.mqh>

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
input double Trail_ATR_Mult     = 0.8;
input double Trail_Step_Points  = 5.0;
input double Breakeven_ATR_Mult = 0.6;
input double Breakeven_Buffer   = 3.0;

input group "=== ⏰ SESIÓN (UTC) === FIX-1"
input bool   UseSessionFilter   = true;
input int    London_Start       = 7;
input int    London_End         = 11;
input int    NY_Start           = 13;
input int    NY_End             = 17;

input group "=== ⏳ COOLDOWN === FIX-4"
input int    Cooldown_Seconds   = 120;
input int    Cooldown_Bars      = 2;

input group "=== 📊 FILTROS HARD ==="
input double MinATR_USD         = 0.50;
input double MaxATR_USD         = 20.0;
input int    MaxSpread_Points   = 80;
input double DailyLoss_Pct      = 3.0;

input group "=== 📈 FILTROS HTF ==="
input bool   UseM15Filter       = true;
input int    M15_EMA_Fast       = 20;
input int    M15_EMA_Slow       = 50;
input int    M15_ADX_Period     = 14;
input double M15_ADX_Min        = 22.0;

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

input group "=== 🧠 ML FILTER (ONNX) ==="
input bool   UseMLFilter        = true;     // Activar filtro de Machine Learning
input string MLModelFile        = "xau_signal_model.onnx"; // Ruta en MQL5/Files/
input double ML_Threshold       = 0.60;     // prob_buy >= umbral confirma BUY

//--- ═══════════════════════════════════════════════════════════════
//    HANDLES DE INDICADORES
//--- ═══════════════════════════════════════════════════════════════
// M1 / M15 (estrategia base)
int h_atr_m1, h_ema_fast, h_ema_slow, h_rsi, h_adx_m1;
int h_m15_ema_fast, h_m15_ema_slow, h_m15_adx;

// H1 — exclusivos para el modelo ONNX
int h_ml_atr14_h1, h_ml_ema8_h1, h_ml_ema21_h1;

//--- ═══════════════════════════════════════════════════════════════
//    ESTADO GLOBAL
//--- ═══════════════════════════════════════════════════════════════
bool     g_isMicro         = false;
double   g_minLot          = 0.01;
double   g_dayStartBalance = 0;
datetime g_dayDate         = 0;
datetime g_lastCloseTime   = 0;
int      g_lastCloseBar    = 0;
datetime g_lastTrailBar    = 0;

//+------------------------------------------------------------------+
bool InSession()
{
   MqlDateTime gmt;
   TimeToStruct(TimeGMT(), gmt);
   int h = gmt.hour;
   return ((h >= London_Start && h < London_End) || (h >= NY_Start && h < NY_End));
}

//+------------------------------------------------------------------+
bool DailyLossExceeded()
{
   MqlDateTime now, day;
   TimeToStruct(TimeCurrent(), now);
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
   if(g_lastCloseTime == 0) return false;
   if((TimeCurrent() - g_lastCloseTime) < Cooldown_Seconds) return true;
   int curBar = Bars(_Symbol, PERIOD_M1);
   if((curBar - g_lastCloseBar) < Cooldown_Bars) return true;
   return false;
}

//+------------------------------------------------------------------+
double GetATR()
{
   double buf[1];
   if(CopyBuffer(h_atr_m1, 0, 0, 1, buf) <= 0) return 0;
   return buf[0] / _Point;
}

//+------------------------------------------------------------------+
int GetM15Bias()
{
   if(!UseM15Filter) return 1;
   double ema_f[1], ema_s[1], adx_main[1];
   if(CopyBuffer(h_m15_ema_fast, 0, 0, 1, ema_f) <= 0) return 0;
   if(CopyBuffer(h_m15_ema_slow, 0, 0, 1, ema_s) <= 0) return 0;
   if(CopyBuffer(h_m15_adx,      0, 0, 1, adx_main) <= 0) return 0;
   if(adx_main[0] < M15_ADX_Min) return 0;
   if(ema_f[0] > ema_s[0]) return  1;
   if(ema_f[0] < ema_s[0]) return -1;
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

   datetime curBar = iTime(_Symbol, PERIOD_M1, 0);
   if(curBar == 0 || curBar == g_lastTrailBar) return;

   double atr_pts = GetATR();
   if(atr_pts < 1) return;
   double atr_price = atr_pts * _Point;
   bool modified = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double new_sl = sl;

      if(type == POSITION_TYPE_BUY)
      {
         double price = bid;
         double profit_price = price - entry;
         double be_trigger = Breakeven_ATR_Mult * atr_price;
         if(sl < entry && profit_price >= be_trigger)
         {
            new_sl = entry + Breakeven_Buffer * _Point;
            new_sl = MathMax(new_sl, sl);
         }
         if(price > entry)
         {
            double trail_sl = price - Trail_ATR_Mult * atr_price;
            trail_sl = MathMax(trail_sl, new_sl);
            if((trail_sl - new_sl) >= Trail_Step_Points * _Point)
               new_sl = trail_sl;
         }
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
         double be_trigger = Breakeven_ATR_Mult * atr_price;
         if(sl > entry && profit_price >= be_trigger)
         {
            new_sl = entry - Breakeven_Buffer * _Point;
            new_sl = MathMin(new_sl, sl);
         }
         if(price < entry)
         {
            double trail_sl = price + Trail_ATR_Mult * atr_price;
            trail_sl = MathMin(trail_sl, new_sl);
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

   // Handles H1 para el modelo ONNX
   h_ml_atr14_h1 = iATR(_Symbol, PERIOD_H1, 14);
   h_ml_ema8_h1  = iMA(_Symbol, PERIOD_H1,  8, 0, MODE_EMA, PRICE_CLOSE);
   h_ml_ema21_h1 = iMA(_Symbol, PERIOD_H1, 21, 0, MODE_EMA, PRICE_CLOSE);

   if(h_atr_m1 == INVALID_HANDLE || h_ema_fast == INVALID_HANDLE ||
      h_ema_slow == INVALID_HANDLE || h_rsi == INVALID_HANDLE ||
      h_adx_m1 == INVALID_HANDLE || h_m15_ema_fast == INVALID_HANDLE ||
      h_m15_ema_slow == INVALID_HANDLE || h_m15_adx == INVALID_HANDLE ||
      h_ml_atr14_h1 == INVALID_HANDLE || h_ml_ema8_h1 == INVALID_HANDLE ||
      h_ml_ema21_h1 == INVALID_HANDLE)
   {
      Print("ERROR: No se pudieron crear handles de indicadores");
      return INIT_FAILED;
   }

   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayDate = TimeCurrent();

   trade.SetExpertMagicNumber(202500 + (int)g_isMicro);
   trade.SetDeviationInPoints(20);

   // Inicializar modelo ONNX (falla silenciosamente — ML queda desactivado)
   if(UseMLFilter)
   {
      bool ml_ok = GM_ML_Init(MLModelFile);
      Print("[V5] ML Filter: ", ml_ok ? "ACTIVO ✓" : "DESACTIVADO (modelo no encontrado — sin filtro ML)");
   }

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
   IndicatorRelease(h_ml_atr14_h1);
   IndicatorRelease(h_ml_ema8_h1);
   IndicatorRelease(h_ml_ema21_h1);
   GM_ML_Deinit();
}

//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Gestionar posición existente (trailing)
   ManagePosition();

   // 2. Una posición a la vez
   if(PositionsTotal() > 0) return;

   // ── FILTROS HARD ──────────────────────────────────────────────

   if(UseSessionFilter && !InSession())
   {
      static datetime s_last_sess_log = 0;
      if(TimeCurrent() - s_last_sess_log > 600)
      {
         MqlDateTime gmt; TimeToStruct(TimeGMT(), gmt);
         Print("FUERA DE SESIÓN — GMT hora=", gmt.hour);
         s_last_sess_log = TimeCurrent();
      }
      return;
   }

   if(DailyLossExceeded()) { Print("DAILY LOSS LIMIT"); return; }
   if(CooldownActive()) return;

   double spread_pts = (double)(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
   if(spread_pts > MaxSpread_Points) { Print("SPREAD alto: ", spread_pts); return; }

   double atr_pts = GetATR();
   if(atr_pts < MinATR_USD) { Print("ATR bajo: ", atr_pts); return; }
   if(atr_pts > MaxATR_USD) { Print("ATR alto: ", atr_pts); return; }

   // ── FILTRO HTF M15 ─────────────────────────────────────────────
   int m15_bias = GetM15Bias();
   if(m15_bias == 0) { Print("M15 RANGING — sin trades"); return; }

   // ── INDICADORES M1 ────────────────────────────────────────────
   double ema_f[2], ema_s[2], rsi_v[1], adx_main[1], adx_plus[1], adx_minus[1];

   if(CopyBuffer(h_ema_fast, 0, 0, 2, ema_f)    <= 0) return;
   if(CopyBuffer(h_ema_slow, 0, 0, 2, ema_s)    <= 0) return;
   if(CopyBuffer(h_rsi,      0, 0, 1, rsi_v)    <= 0) return;
   if(CopyBuffer(h_adx_m1, MAIN_LINE,   0, 1, adx_main)  <= 0) return;
   if(CopyBuffer(h_adx_m1, PLUSDI_LINE, 0, 1, adx_plus)  <= 0) return;
   if(CopyBuffer(h_adx_m1, MINUSDI_LINE,0, 1, adx_minus) <= 0) return;

   double rsi = rsi_v[0];
   double adx = adx_main[0];

   bool ema_bull       = (ema_f[0] > ema_s[0] && ema_f[1] <= ema_s[1]);
   bool ema_bear       = (ema_f[0] < ema_s[0] && ema_f[1] >= ema_s[1]);
   bool ema_stack_bull = (ema_f[0] > ema_s[0]);
   bool ema_stack_bear = (ema_f[0] < ema_s[0]);

   bool adx_ok   = (adx >= M1_ADX_Min);
   bool adx_bull = (adx_ok && adx_plus[0]  > adx_minus[0]);
   bool adx_bear = (adx_ok && adx_minus[0] > adx_plus[0]);

   double open1  = iOpen(_Symbol, PERIOD_M1, 1);
   double close1 = iClose(_Symbol, PERIOD_M1, 1);
   bool bull_candle = (close1 > open1);
   bool bear_candle = (close1 < open1);

   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot       = g_isMicro ? LotMicro : LotNormal;
   double atr_price = atr_pts * _Point;

   // ── 🧠 PREDICCIÓN ML (una sola vez por tick) ──────────────────
   // Se llama aquí para no duplicar la predicción en BUY y SELL.
   // GM_ML_Predict retorna 0.5 si ONNX no disponible → GM_ML_Confirms=true
   double prob_buy = UseMLFilter
      ? GM_ML_Predict(_Symbol, PERIOD_H1, h_ml_atr14_h1, h_ml_ema8_h1, h_ml_ema21_h1, m15_bias)
      : GM_ML_DISABLED_PROB;

   // ─── COMPRA ───────────────────────────────────────────────────
   if(m15_bias == 1)
   {
      int score = 0;
      if(ema_stack_bull) score++;
      if(ema_bull)       score++;
      if(adx_bull)       score++;
      if(rsi >= RSI_Buy_Min && rsi <= RSI_Buy_Max) score++;
      if(bull_candle)    score++;

      if(score >= 3 && ema_stack_bull)
      {
         // ── Filtro ML ──
         if(UseMLFilter && !GM_ML_Confirms(prob_buy, 1))
         {
            Print("[V5] ML bloquea BUY — prob_buy=", DoubleToString(prob_buy,3),
                  " < threshold=", DoubleToString(ML_Threshold,2));
            return;
         }

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
               Print("BUY abierta | Score=", score, " ML=", DoubleToString(prob_buy,3),
                     " Lot=", lot, " SL=", sl, " TP=", tp);
         }
         else
            Print("PAPER BUY | Score=", score, " ML=", DoubleToString(prob_buy,3),
                  " ask=", ask, " sl=", sl, " tp=", tp);
      }
   }

   // ─── VENTA ────────────────────────────────────────────────────
   if(m15_bias == -1)
   {
      int score = 0;
      if(ema_stack_bear) score++;
      if(ema_bear)       score++;
      if(adx_bear)       score++;
      if(rsi >= RSI_Sell_Min && rsi <= RSI_Sell_Max) score++;
      if(bear_candle)    score++;

      if(score >= 3 && ema_stack_bear)
      {
         // ── Filtro ML ──
         if(UseMLFilter && !GM_ML_Confirms(prob_buy, -1))
         {
            Print("[V5] ML bloquea SELL — prob_buy=", DoubleToString(prob_buy,3),
                  " > threshold=", DoubleToString(1.0 - ML_Threshold,2));
            return;
         }

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
               Print("SELL abierta | Score=", score, " ML=", DoubleToString(prob_buy,3),
                     " Lot=", lot, " SL=", sl, " TP=", tp);
         }
         else
            Print("PAPER SELL | Score=", score, " ML=", DoubleToString(prob_buy,3),
                  " bid=", bid, " sl=", sl, " tp=", tp);
      }
   }
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& req,
                        const MqlTradeResult& res)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL)
      {
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
