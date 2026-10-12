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
input int      MaxEntries        = 5;        // Número máximo de entradas en el mismo punto

//--- INDICADORES
int handleATR;
int handleEMA_Fast;
int handleEMA_Slow;

//--- VARIABLES DE ESTADO
double vela_apertura = 0;
datetime last_bar_time = 0;
bool signal_active = false;
int entry_count = 0;           // Contador de entradas en la señal actual
int total_entries_in_signal = 0; // Total de entradas ejecutadas para esta señal

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
   Print("📊 Máximo de entradas por señal: ", MaxEntries);
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
   // 1. Verificar si hay posiciones abiertas del EA
   bool has_open_positions = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == 777000)
        {
         has_open_positions = true;
         break;
        }
     }

   // 2. Gestionar Trailing Stop si hay posiciones abiertas
   if(has_open_positions)
     {
      ManageTrailingStop();
     }

   // 3. Detectar nueva vela M1
   datetime current_time = iTime(_Symbol, _Period, 0);
   if(current_time != last_bar_time)
     {
      vela_apertura = iOpen(_Symbol, _Period, 0);
      last_bar_time = current_time;
      signal_active = false;
      entry_count = 0;          // Resetear contador en nueva vela
      total_entries_in_signal = 0;
     }

   // 4. Si ya alcanzamos el máximo de entradas o la señal está inactiva, salir
   if(signal_active || entry_count >= MaxEntries)
     {
      return;
     }

   // 5. Obtener datos de indicadores
   double atr[1], ema_fast[1], ema_slow[1];
   CopyBuffer(handleATR, 0, 0, 1, atr);
   CopyBuffer(handleEMA_Fast, 0, 0, 1, ema_fast);
   CopyBuffer(handleEMA_Slow, 0, 0, 1, ema_slow);

   if(atr[0] == 0) return;

   double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // 6. Lógica de Estructura de Mercado (SMC Matemático)
   bool buy_signal = false;
   bool sell_signal = false;

   // Condición para COMPRA (Estructura Alcista):
   if(ema_fast[0] > ema_slow[0])
     {
      if(iClose(_Symbol, _Period, 1) > ema_fast[0])
        {
         buy_signal = true;
        }
     }

   // Condición para VENTA (Estructura Bajista):
   if(ema_fast[0] < ema_slow[0])
     {
      if(iClose(_Symbol, _Period, 1) < ema_fast[0])
        {
         sell_signal = true;
        }
     }

   // 7. Ejecutar órdenes mientras haya señal y no se haya alcanzado el máximo
   if(buy_signal && !signal_active)
     {
      // Verificar si hemos alcanzado el número máximo de entradas
      if(entry_count < MaxEntries)
        {
         double sl = NormalizeDouble(current_bid - (atr[0] * ATRMultiplierSL), _Digits);
         double tp = NormalizeDouble(current_bid + (atr[0] * RatioTP), _Digits);
         double lot = CalculateLotSize(atr[0] * ATRMultiplierSL);

         if(lot > 0)
           {
            Print("🚀 SEÑAL DE COMPRA (BOS Alcista). Entrada #", entry_count + 1, "/", MaxEntries, " en: ", current_ask);
            if(trade.Buy(lot, _Symbol, current_ask, sl, tp, "SMC Buy"))
              {
               Print("✅ Orden de Compra ejecutada. Entrada #", entry_count + 1);
               entry_count++;
               total_entries_in_signal++;
               
               // Si alcanzamos el máximo, desactivamos la señal
               if(entry_count >= MaxEntries)
                 {
                  signal_active = true;
                  Print("🔒 Límite máximo de entradas alcanzado (", MaxEntries, ").");
                 }
              }
            else
              {
               Print("❌ Error al ejecutar orden de compra. Error: ", GetLastError());
              }
           }
        }
     }
   else if(sell_signal && !signal_active)
     {
      if(entry_count < MaxEntries)
        {
         double sl = NormalizeDouble(current_ask + (atr[0] * ATRMultiplierSL), _Digits);
         double tp = NormalizeDouble(current_ask - (atr[0] * RatioTP), _Digits);
         double lot = CalculateLotSize(atr[0] * ATRMultiplierSL);

         if(lot > 0)
           {
            Print("🚀 SEÑAL DE VENTA (BOS Bajista). Entrada #", entry_count + 1, "/", MaxEntries, " en: ", current_bid);
            if(trade.Sell(lot, _Symbol, current_bid, sl, tp, "SMC Sell"))
              {
               Print("✅ Orden de Venta ejecutada. Entrada #", entry_count + 1);
               entry_count++;
               total_entries_in_signal++;
               
               if(entry_count >= MaxEntries)
                 {
                  signal_active = true;
                  Print("🔒 Límite máximo de entradas alcanzado (", MaxEntries, ").");
                 }
              }
            else
              {
               Print("❌ Error al ejecutar orden de venta. Error: ", GetLastError());
              }
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