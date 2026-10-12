//+------------------------------------------------------------------+
//|                                          ScalpingBot_SMC.mq5      |
//|              EA ESTRUCTURA DE MERCADO (SMC) + 5 POSICIONES       |
//+------------------------------------------------------------------+
#property copyright "SMC Scalping Bot"
#property link      ""
#property version   "3.0"

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| PARÁMETROS DE CONFIGURACIÓN                                       |
//+------------------------------------------------------------------+
input double   RiskPerTrade      = 2.0;      // Riesgo por operación (%)
input double   ATRMultiplierSL   = 2.0;      // Multiplicador ATR para SL
input double   RatioTP           = 3.0;      // Multiplicador ATR para TP
input double   TrailActivation   = 0.8;      // ATR para activar Trailing
input int     InpMaxPositions   = 5;        // Máximo posiciones simultáneas
input int     EMA_Fast          = 20;       // EMA Rápida (Estructura Micro)
input int     EMA_Slow          = 50;       // EMA Lenta (Estructura Macro)
input int     InpSlippage       = 50;       // Slippage en puntos
input int     InpMagicNumber    = 777000;   // Magic Number
input bool    InpUseTrailing    = true;     // Usar Trailing Stop

//+------------------------------------------------------------------+
//| VARIABLES GLOBALES                                               |
//+------------------------------------------------------------------+
int handleATR;
int handleEMA_Fast;
int handleEMA_Slow;
datetime last_bar_time = 0;
bool signal_active = false;
bool isNewBar = false;
int positionsOpenedInBar = 0;
double pointSize = 0;
double entryPrice = 0;
double currentTP = 0;
double currentSL = 0;
int tradeCounter = 0;

//+------------------------------------------------------------------+
//| INICIALIZACIÓN                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   pointSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   handleATR       = iATR(_Symbol, PERIOD_CURRENT, 14);
   handleEMA_Fast  = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA_Slow  = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(handleATR == INVALID_HANDLE || handleEMA_Fast == INVALID_HANDLE || handleEMA_Slow == INVALID_HANDLE)
   {
      Print("❌ Error cargando indicadores.");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   
   Print("========================================");
   Print("✅ SMC Scalping Bot Iniciado");
   Print("========================================");
   Print("📊 Símbolo: ", _Symbol);
   Print("📊 EMA Rápida: ", EMA_Fast);
   Print("📊 EMA Lenta: ", EMA_Slow);
   Print("📊 Multiplicador SL: ", ATRMultiplierSL);
   Print("📊 Ratio TP: ", RatioTP);
   Print("📊 Máximo posiciones: ", InpMaxPositions);
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| DESINICIALIZACIÓN                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleATR);
   IndicatorRelease(handleEMA_Fast);
   IndicatorRelease(handleEMA_Slow);
   Print("🛑 Bot detenido. Total operaciones: ", tradeCounter);
}

//+------------------------------------------------------------------+
//| TICK PRINCIPAL                                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Gestionar trailing de posiciones abiertas
   if(PositionsTotal() > 0 && InpUseTrailing)
   {
      ManageTrailingStop();
   }
   
   // 2. Monitorear posiciones (SL a BE)
   if(PositionsTotal() > 0)
   {
      MonitorPositions();
   }

   // 3. Verificar nueva barra
   CheckNewBar();
   
   // 4. Si es nueva vela y no hay posiciones, intentar abrir
   if(isNewBar && CountOpenPositions() == 0)
   {
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      positionsOpenedInBar = 0;
      OpenMultiplePositions();
   }
}

//+------------------------------------------------------------------+
//| VERIFICAR NUEVA BARRA                                            |
//+------------------------------------------------------------------+
void CheckNewBar()
{
   datetime current_time = iTime(_Symbol, PERIOD_CURRENT, 0);
   
   if(current_time != last_bar_time)
   {
      last_bar_time = current_time;
      isNewBar = true;
      signal_active = false;
   }
   else
   {
      isNewBar = false;
   }
}

//+------------------------------------------------------------------+
//| ABRIR MÚLTIPLES POSICIONES (5 EN LA MISMA VELA)                  |
//+------------------------------------------------------------------+
void OpenMultiplePositions()
{
   int currentPositions = CountOpenPositions();
   int positionsToOpen = InpMaxPositions - currentPositions;
   
   if(positionsToOpen <= 0) return;
   
   if(CheckSpread() > 100)
   {
      Print("⚠️ Spread demasiado alto: ", CheckSpread());
      return;
   }
   
   // Obtener señal SMC
   int signal = GetSMCSignal();
   
   if(signal == 0)
   {
      Print("⏳ Sin señal SMC, esperando...");
      return;
   }
   
   ENUM_ORDER_TYPE orderType = (signal == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   // Obtener ATR para calcular SL/TP
   double atr[1];
   if(CopyBuffer(handleATR, 0, 0, 1, atr) < 1 || atr[0] == 0)
   {
      Print("❌ Error obteniendo ATR");
      return;
   }
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   entryPrice = (orderType == ORDER_TYPE_BUY) ? ask : bid;
   entryPrice = NormalizeDouble(entryPrice, _Digits);
   
   // Calcular SL y TP usando ATR
   double slDistance = atr[0] * ATRMultiplierSL;
   double tpDistance = atr[0] * RatioTP;
   
   // Asegurar distancia mínima de 80 puntos para XAUUSD
   double minDistPts = 80.0 * pointSize;
   if(slDistance < minDistPts)
      slDistance = minDistPts;
   if(tpDistance < minDistPts * 1.5)
      tpDistance = minDistPts * 1.5;
   
   if(orderType == ORDER_TYPE_BUY)
   {
      currentSL = NormalizeDouble(entryPrice - slDistance, _Digits);
      currentTP = NormalizeDouble(entryPrice + tpDistance, _Digits);
   }
   else
   {
      currentSL = NormalizeDouble(entryPrice + slDistance, _Digits);
      currentTP = NormalizeDouble(entryPrice - tpDistance, _Digits);
   }
   
   // Calcular lote por riesgo
   double lot = CalculateLotSize(slDistance);
   lot = MathMin(lot, 0.01); // Límite máximo para pruebas
   
   Print("🎯 Abriendo ", positionsToOpen, " posiciones");
   Print("   Dirección: ", orderType == ORDER_TYPE_BUY ? "COMPRA ↑" : "VENTA ↓");
   Print("   Precio: ", DoubleToString(entryPrice, _Digits));
   Print("   TP: ", DoubleToString(currentTP, _Digits), " (", DoubleToString(MathAbs(currentTP - entryPrice)/pointSize, 0), " pts)");
   Print("   SL: ", DoubleToString(currentSL, _Digits), " (", DoubleToString(MathAbs(currentSL - entryPrice)/pointSize, 0), " pts)");
   Print("   Lote: ", DoubleToString(lot, 2));
   
   for(int i = 0; i < positionsToOpen; i++)
   {
      if(OpenPosition(orderType, entryPrice, lot))
      {
         positionsOpenedInBar++;
         tradeCounter++;
         Print("✅ Posición #", i+1, " abierta (Total: ", tradeCounter, ")");
      }
      else
      {
         Print("❌ Error posición #", i+1);
         break;
      }
      Sleep(100);
   }
}

//+------------------------------------------------------------------+
//| ABRIR POSICIÓN INDIVIDUAL                                        |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE orderType, double price, double lot)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   if(orderType == ORDER_TYPE_BUY)
   {
      if(!trade.Buy(lot, _Symbol, ask, currentSL, currentTP, "SMC Scalp #" + IntegerToString(tradeCounter + 1)))
      {
         Print("❌ Error Buy: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
         return false;
      }
   }
   else
   {
      if(!trade.Sell(lot, _Symbol, bid, currentSL, currentTP, "SMC Scalp #" + IntegerToString(tradeCounter + 1)))
      {
         Print("❌ Error Sell: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
         return false;
      }
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| SEÑAL SMC - ESTRUCTURA DE MERCADO                                |
//+------------------------------------------------------------------+
int GetSMCSignal()
{
   double atr[1], ema_fast[1], ema_slow[1];
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);
   
   if(CopyBuffer(handleATR, 0, 0, 1, atr) < 1) return 0;
   if(CopyBuffer(handleEMA_Fast, 0, 0, 1, ema_fast) < 1) return 0;
   if(CopyBuffer(handleEMA_Slow, 0, 0, 1, ema_slow) < 1) return 0;
   
   if(atr[0] == 0) return 0;
   
   // BOS (Break of Structure) - Quiebre de estructura
   // Tendencia alcista: EMA20 > EMA50 Y precio cierra por encima de EMA20
   if(ema_fast[0] > ema_slow[0])
   {
      if(close1 > ema_fast[0] && close2 <= ema_fast[0])
      {
         Print("📊 Señal SMC: COMPRA (BOS Alcista)");
         return 1;
      }
   }
   
   // Tendencia bajista: EMA20 < EMA50 Y precio cierra por debajo de EMA20
   if(ema_fast[0] < ema_slow[0])
   {
      if(close1 < ema_fast[0] && close2 >= ema_fast[0])
      {
         Print("📊 Señal SMC: VENTA (BOS Bajista)");
         return -1;
      }
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| CÁLCULO DE LOTE POR RIESGO                                       |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_distance)
{
   if(sl_distance <= 0) return 0.0;
   
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double account_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   double sl_points = sl_distance / tick_size;
   double dollar_per_point = tick_value / tick_size;
   double risk_capital = account_equity * (RiskPerTrade / 100.0);
   double lot_size = risk_capital / (sl_points * dollar_per_point);
   
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(step_lot > 0) lot_size = MathFloor(lot_size / step_lot) * step_lot;
   
   if(lot_size < min_lot) lot_size = min_lot;
   if(lot_size > max_lot) lot_size = max_lot;
   
   return lot_size;
}

//+------------------------------------------------------------------+
//| CONTAR POSICIONES ABIERTAS                                       |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| TRAILING STOP SMC                                                |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double atr[1];
   if(CopyBuffer(handleATR, 0, 0, 1, atr) < 1 || atr[0] == 0) return;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i)))
         continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ulong ticket = PositionGetTicket(i);
      double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                           SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
      {
         // Cuando el precio baja 0.8 ATR, movemos SL
         if(currentPrice < openPrice - (atr[0] * TrailActivation))
         {
            double new_sl = NormalizeDouble(currentPrice + atr[0], _Digits);
            if(new_sl < sl || sl == 0)
            {
               if(trade.PositionModify(ticket, new_sl, tp))
               {
                  static int updateCount = 0;
                  updateCount++;
                  if(updateCount % 5 == 0)
                     Print("🔄 Trailing SELL #", ticket, " SL: ", DoubleToString(new_sl, _Digits));
               }
            }
         }
      }
      else // BUY
      {
         if(currentPrice > openPrice + (atr[0] * TrailActivation))
         {
            double new_sl = NormalizeDouble(currentPrice - atr[0], _Digits);
            if(new_sl > sl || sl == 0)
            {
               if(trade.PositionModify(ticket, new_sl, tp))
               {
                  static int updateCount = 0;
                  updateCount++;
                  if(updateCount % 5 == 0)
                     Print("🔄 Trailing BUY #", ticket, " SL: ", DoubleToString(new_sl, _Digits));
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| MONITOREAR POSICIONES - SL A BREAK EVEN                          |
//+------------------------------------------------------------------+
void MonitorPositions()
{
   double atr[1];
   if(CopyBuffer(handleATR, 0, 0, 1, atr) < 1 || atr[0] == 0) return;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i)))
         continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ulong ticket = PositionGetTicket(i);
      double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                           SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      double profitPoints;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         profitPoints = (currentPrice - openPrice) / pointSize;
      else
         profitPoints = (openPrice - currentPrice) / pointSize;
      
      // Mover SL a Break Even cuando hay ganancia > 0.5 ATR
      if(profitPoints > (atr[0] / pointSize) * 0.5 && sl != openPrice)
      {
         if(MathAbs(openPrice - currentPrice) >= atr[0] * 0.5)
         {
            if(trade.PositionModify(ticket, NormalizeDouble(openPrice, _Digits), tp))
            {
               Print("✅ SL a BE #", ticket, " (", DoubleToString(profitPoints, 1), " pts)");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| VERIFICAR SPREAD                                                 |
//+------------------------------------------------------------------+
int CheckSpread()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   if(bid == 0 || ask == 0) return 1000;
   
   int spread = (int)((ask - bid) / pointSize);
   return spread;
}

//+------------------------------------------------------------------+
//| FUNCIONES REQUERIDAS VACÍAS                                      |
//+------------------------------------------------------------------+
void OnTimer() {}
void OnTrade() {}
void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result) {}
double OnTester() { return 0.0; }
void OnTesterInit() {}
void OnTesterPass() {}
void OnTesterDeinit() {}
void OnChartEvent(const int32_t id, const long &lparam, const double &dparam, const string &sparam) {}
void OnBookEvent(const string &symbol) {}
//+------------------------------------------------------------------+