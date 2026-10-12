//+------------------------------------------------------------------+
//|                                                          ORO.mq5 |
//|              EA ESTRUCTURA DE MERCADO (SMC Matemático)           |
//+------------------------------------------------------------------+
#property copyright "SMC Execution Bot"
#property link      ""
#property version   "3.0"

#include <Trade\Trade.mqh>
CTrade trade;

//--- PARÁMETROS DE CONFIGURACIÓN
input double   RiskPerTrade      = 2.0;      // Riesgo por operación (%)
input double   ATRMultiplierSL   = 2.0;      // Multiplicador ATR para SL (Amplio)
input double   RatioTP           = 3.0;      // Multiplicador ATR para TP
input double   TrailActivation   = 0.8;      // ATR para activar Trailing Stop
input int      EMA_Fast          = 20;       // EMA Rápida (Estructura Micro)
input int      EMA_Slow          = 50;       // EMA Lenta (Estructura Macro)

//--- INDICADORES
int handleATR;
int handleEMA_Fast;
int handleEMA_Slow;

//--- VARIABLES DE ESTADO
double vela_apertura = 0;
datetime last_bar_time = 0;
bool signal_active = false;

//+------------------------------------------------------------------+
//| Inicialización                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   handleATR       = iATR(_Symbol, _Period, 14);
   handleEMA_Fast  = iMA(_Symbol, _Period, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA_Slow  = iMA(_Symbol, _Period, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(handleATR == INVALID_HANDLE || handleEMA_Fast == INVALID_HANDLE || handleEMA_Slow == INVALID_HANDLE)
     {
      Print("❌ Error cargando indicadores.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(777000);
   Print("✅ EA SMC Operativo Iniciado.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Desinicialización                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(handleATR);
   IndicatorRelease(handleEMA_Fast);
   IndicatorRelease(handleEMA_Slow);
  }

//+------------------------------------------------------------------+
//| OnTick: Lógica de Entrada                                        |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Si hay operación abierta, gestionamos Trailing
   if(PositionsTotal() > 0)
     {
      ManageTrailingStop();
      return;
     }

   // 2. Detectar nueva vela M1
   datetime current_time = iTime(_Symbol, _Period, 0);
   if(current_time != last_bar_time)
     {
      vela_apertura = iOpen(_Symbol, _Period, 0);
      last_bar_time = current_time;
      signal_active = false;
     }

   // 3. Obtener datos de indicadores
   double atr[1], ema_fast[1], ema_slow[1];
   CopyBuffer(handleATR, 0, 0, 1, atr);
   CopyBuffer(handleEMA_Fast, 0, 0, 1, ema_fast);
   CopyBuffer(handleEMA_Slow, 0, 0, 1, ema_slow);

   if(atr[0] == 0) return;

   double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // 4. Lógica de Estructura de Mercado (SMC Matemático)
   // "BOS" (Break of Structure) = Ruptura de la EMA Rápida en dirección de la EMA Lenta.
   
   bool buy_signal = false;
   bool sell_signal = false;

   // Condición para COMPRA (Estructura Alcista):
   // 1. Tendencia Macro Alcista (EMA20 > EMA50)
   // 2. Precio CIERRA por encima de EMA20 (Confirmación de quiebre)
   if(ema_fast[0] > ema_slow[0])
     {
      if(iClose(_Symbol, _Period, 1) > ema_fast[0]) // Quiebre validado en vela anterior
        {
         buy_signal = true;
        }
     }

   // Condición para VENTA (Estructura Bajista):
   // 1. Tendencia Macro Bajista (EMA20 < EMA50)
   // 2. Precio CIERRA por debajo de EMA20
   if(ema_fast[0] < ema_slow[0])
     {
      if(iClose(_Symbol, _Period, 1) < ema_fast[0])
        {
         sell_signal = true;
        }
     }

   // 5. Ejecución de la Orden
   if(buy_signal && !signal_active)
     {
      double sl = NormalizeDouble(current_bid - (atr[0] * ATRMultiplierSL), _Digits);
      double tp = NormalizeDouble(current_bid + (atr[0] * RatioTP), _Digits);
      double lot = CalculateLotSize(atr[0] * ATRMultiplierSL);

      if(lot > 0)
        {
         Print("🚀 SEÑAL DE COMPRA (BOS Alcista). Entrada: ", current_ask);
         if(trade.Buy(lot, _Symbol, current_ask, sl, tp, "SMC Buy"))
           {
            Print("✅ Orden de Compra ejecutada.");
            signal_active = true;
           }
        }
     }
   else if(sell_signal && !signal_active)
     {
      double sl = NormalizeDouble(current_ask + (atr[0] * ATRMultiplierSL), _Digits);
      double tp = NormalizeDouble(current_ask - (atr[0] * RatioTP), _Digits);
      double lot = CalculateLotSize(atr[0] * ATRMultiplierSL);

      if(lot > 0)
        {
         Print("🚀 SEÑAL DE VENTA (BOS Bajista). Entrada: ", current_bid);
         if(trade.Sell(lot, _Symbol, current_bid, sl, tp, "SMC Sell"))
           {
            Print("✅ Orden de Venta ejecutada.");
            signal_active = true;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Cálculo de lote por riesgo                                       |
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
   
   if(lot_size < min_lot) return min_lot;
   if(lot_size > max_lot) lot_size = max_lot;

   return lot_size;
  }

//+------------------------------------------------------------------+
//| Trailing Stop para SMC                                           |
//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
   double atr_val[1];
   CopyBuffer(handleATR, 0, 0, 1, atr_val);
   if(atr_val[0] == 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != 777000) continue;

      double sl = PositionGetDouble(POSITION_SL);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
        {
         // Si el precio baja 0.8 ATR a nuestro favor, movemos SL a 1.0 ATR por encima
         if(current_bid < open_price - (atr_val[0] * TrailActivation))
           {
            double new_sl = NormalizeDouble(current_bid + atr_val[0], _Digits);
            if(new_sl < sl || sl == 0) trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP));
           }
        }
      else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
         if(current_ask > open_price + (atr_val[0] * TrailActivation))
           {
            double new_sl = NormalizeDouble(current_ask - atr_val[0], _Digits);
            if(new_sl > sl || sl == 0) trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP));
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Funciones requeridas vacías                                      |
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