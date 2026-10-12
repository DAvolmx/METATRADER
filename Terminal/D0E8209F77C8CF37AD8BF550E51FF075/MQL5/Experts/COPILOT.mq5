//+------------------------------------------------------------------+
//|                                          GoldTradeProtector.mq5  |
//|                                           Optimizado para XAUUSD |
//|                                                   Versión 4.0     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property link      ""
#property version   "4.00"

//--- PARÁMETROS PRINCIPALES
input double   InpStopLoss     = 300;   // Stop Loss (en puntos)
input double   InpTakeProfit   = 600;   // Take Profit (en puntos)
input double   InpTrailingStop = 150;   // Trailing Stop (en puntos)
input double   InpBreakeven    = 80;    // Breakeven (puntos de ganancia)
input bool     InpUseTrailing  = true;  // Activar Trailing Stop
input bool     InpUseBreakeven = true;  // Activar Breakeven

//--- PARÁMETROS AVANZADOS PARA VOLATILIDAD
input double   InpVolatilityFilter = 1.5;  // Multiplicador por volatilidad
input int      InpMinSLPoints      = 100;  // SL mínimo en puntos
input int      InpMaxSLPoints      = 800;  // SL máximo en puntos
input int      InpTrailingStep     = 50;   // Paso mínimo para trailing
input double   InpRiskRewardRatio  = 2.0;  // Ratio Riesgo/Beneficio
input bool     InpDynamicTP        = true; // TP dinámico según volatilidad
input int      InpATRPeriod        = 14;   // Período ATR para ajuste dinámico

//--- PARÁMETROS DE SEGURIDAD
input bool     InpLockBreakeven    = true; // Bloquear breakeven (no permite retroceso)
input double   InpPartialClose     = 0.0;  // Cierre parcial (0 = desactivado)
input bool     InpUseTimeFilter    = false;// Filtrar por horas de alta volatilidad

//--- PARÁMETROS DE NOTIFICACIÓN
input bool     InpSendNotifications = false;// Enviar notificaciones push
input bool     InpPrintLog         = true; // Mostrar logs detallados

//--- VARIABLES GLOBALES
ulong  g_ticket = 0;
double g_sl = 0;
double g_tp = 0;
double g_openPrice = 0;
double g_breakevenPrice = 0;
bool   g_isBreakevenActivated = false;
bool   g_isPartialClosed = false;
datetime g_lastCheck = 0;
double g_atrValue = 0;
double g_volatility = 0;
int    g_magicNumber = 999;
double g_highestPrice = 0;
double g_lowestPrice = 0;

//--- HANDLE PARA ATR
int g_atrHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Verificar parámetros
   if(InpStopLoss <= 0 || InpTakeProfit <= 0)
   {
      Print("ERROR: SL y TP deben ser > 0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   //--- Calcular ATR
   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: No se pudo crear el indicador ATR");
      return(INIT_FAILED);
   }
   
   //--- Actualizar valores de volatilidad
   UpdateVolatility();
   
   Print("=========================================");
   Print("💰 GOLD TRADE PROTECTOR INICIADO");
   Print("⚡ Optimizado para XAUUSD y mercados volátiles");
   Print("=========================================");
   Print("SL: ", InpStopLoss, " pts | TP: ", InpTakeProfit, " pts");
   Print("Trailing: ", InpTrailingStop, " pts | Breakeven: ", InpBreakeven, " pts");
   Print("ATR: ", DoubleToString(g_atrValue, 2), " | Volatilidad: ", DoubleToString(g_volatility, 2));
   Print("=========================================");
   
   g_lastCheck = 0;
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Verificar cada 1 segundo
   if(TimeCurrent() - g_lastCheck < 1)
      return;
   g_lastCheck = TimeCurrent();
   
   //--- Actualizar volatilidad cada 10 segundos
   if(TimeCurrent() % 10 == 0)
      UpdateVolatility();
   
   CheckAllTrades();
}

//+------------------------------------------------------------------+
//| Actualizar valores de volatilidad                                |
//+------------------------------------------------------------------+
void UpdateVolatility()
{
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   
   if(CopyBuffer(g_atrHandle, 0, 0, 2, atrBuffer) < 2)
      return;
   
   g_atrValue = atrBuffer[0];
   
   //--- Calcular volatilidad en puntos
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_volatility = g_atrValue / point;
}

//+------------------------------------------------------------------+
//| Verificar todas las operaciones                                  |
//+------------------------------------------------------------------+
void CheckAllTrades()
{
   int totalPositions = PositionsTotal();
   
   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      
      if(!PositionSelectByTicket(ticket))
         continue;
      
      //--- Obtener datos de la posición
      string symbol = PositionGetString(POSITION_SYMBOL);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long magic = PositionGetInteger(POSITION_MAGIC);
      
      //--- Verificar que sea del símbolo actual
      if(symbol != _Symbol)
         continue;
      
      //--- Verificar que sea operación MANUAL
      if(magic != 0 && magic != g_magicNumber)
         continue;
      
      //--- Actualizar precios extremos para trailing agresivo
      double currentPrice = (type == POSITION_TYPE_BUY) ? 
                            SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                            SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      if(type == POSITION_TYPE_BUY)
      {
         if(g_highestPrice == 0 || currentPrice > g_highestPrice)
            g_highestPrice = currentPrice;
      }
      else
      {
         if(g_lowestPrice == 0 || currentPrice < g_lowestPrice)
            g_lowestPrice = currentPrice;
      }
      
      //--- Si la operación no tiene SL, aplicarlo con ajustes dinámicos
      if(currentSL == 0 && currentTP == 0)
      {
         Print("🎯 Operación MANUAL detectada! Ticket: ", ticket);
         Print("Tipo: ", (type == POSITION_TYPE_BUY ? "COMPRA" : "VENTA"));
         Print("Precio apertura: ", DoubleToString(openPrice, _Digits));
         
         ApplyDynamicSLTP(ticket, type, openPrice);
         continue;
      }
      
      //--- Si ya tiene SL, gestionar trailing y breakeven
      if(currentSL != 0)
      {
         ManageVolatileTrade(ticket, type, openPrice, currentSL, currentTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Aplicar SL y TP dinámicos según volatilidad                      |
//+------------------------------------------------------------------+
void ApplyDynamicSLTP(ulong ticket, ENUM_POSITION_TYPE type, double openPrice)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   //--- Calcular SL dinámico según volatilidad
   double slPoints = InpStopLoss;
   double tpPoints = InpTakeProfit;
   
   //--- Ajustar por volatilidad
   if(InpDynamicTP && g_volatility > 0)
   {
      slPoints = MathMax(InpMinSLPoints, g_volatility * InpVolatilityFilter);
      slPoints = MathMin(InpMaxSLPoints, slPoints);
      
      //--- TP = SL * Ratio Riesgo/Beneficio
      tpPoints = slPoints * InpRiskRewardRatio;
      
      //--- Ajustar por ATR
      if(g_atrValue > 0)
      {
         double atrPoints = g_atrValue / point;
         slPoints = MathMax(slPoints, atrPoints * 0.8);
         tpPoints = MathMax(tpPoints, atrPoints * 1.6);
      }
   }
   
   //--- Redondear a valores enteros
   slPoints = MathRound(slPoints);
   tpPoints = MathRound(tpPoints);
   
   double slPrice = 0, tpPrice = 0;
   
   if(type == POSITION_TYPE_BUY)
   {
      slPrice = openPrice - slPoints * point;
      tpPrice = openPrice + tpPoints * point;
   }
   else
   {
      slPrice = openPrice + slPoints * point;
      tpPrice = openPrice - tpPoints * point;
   }
   
   //--- Validar precios
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stopsLevel * point;
   
   if(MathAbs(slPrice - openPrice) < minDistance)
   {
      if(type == POSITION_TYPE_BUY)
         slPrice = openPrice - minDistance * 3;
      else
         slPrice = openPrice + minDistance * 3;
   }
   
   if(MathAbs(tpPrice - openPrice) < minDistance)
   {
      if(type == POSITION_TYPE_BUY)
         tpPrice = openPrice + minDistance * 4;
      else
         tpPrice = openPrice - minDistance * 4;
   }
   
   //--- Modificar la posición
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = _Symbol;
   request.sl = slPrice;
   request.tp = tpPrice;
   request.deviation = 50;  // Mayor desviación para oro
   request.magic = g_magicNumber;
   
   if(!OrderSend(request, result))
   {
      Print("ERROR al aplicar SL/TP: ", result.retcode);
   }
   else
   {
      if(InpPrintLog)
      {
         Print("✅ SL y TP dinámicos aplicados");
         Print("SL: ", DoubleToString(slPrice, _Digits), " (", DoubleToString(slPoints, 0), " pts)");
         Print("TP: ", DoubleToString(tpPrice, _Digits), " (", DoubleToString(tpPoints, 0), " pts)");
         Print("Volatilidad actual: ", DoubleToString(g_volatility, 1), " pts");
      }
      
      g_ticket = ticket;
      g_sl = slPrice;
      g_tp = tpPrice;
      g_openPrice = openPrice;
      g_isBreakevenActivated = false;
      g_isPartialClosed = false;
      g_highestPrice = 0;
      g_lowestPrice = 0;
   }
}

//+------------------------------------------------------------------+
//| Gestionar operación en mercado volátil                          |
//+------------------------------------------------------------------+
void ManageVolatileTrade(ulong ticket, ENUM_POSITION_TYPE type, 
                         double openPrice, double currentSL, double currentTP)
{
   //--- Obtener precios actuales
   double currentPrice = (type == POSITION_TYPE_BUY) ? 
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   //--- Calcular ganancia en puntos
   double profitPoints = 0;
   if(type == POSITION_TYPE_BUY)
      profitPoints = (currentPrice - openPrice) / point;
   else
      profitPoints = (openPrice - currentPrice) / point;
   
   //--- Calcular distancia al SL actual
   double slDistance = 0;
   if(type == POSITION_TYPE_BUY)
      slDistance = (currentPrice - currentSL) / point;
   else
      slDistance = (currentSL - currentPrice) / point;
   
   //--- FILTRO DE VOLATILIDAD: No mover SL en momentos de alta volatilidad extrema
   double volatilityThreshold = g_volatility * 2.5;
   if(g_volatility > volatilityThreshold && profitPoints < InpBreakeven * 2)
   {
      if(InpPrintLog)
         Print("⚠️ Volatilidad extrema: ", DoubleToString(g_volatility, 1), " pts - Esperando...");
      return;
   }
   
   //--- BREAKEVEN DINÁMICO (con bloqueo)
   if(InpUseBreakeven && !g_isBreakevenActivated)
   {
      double breakevenTrigger = InpBreakeven;
      
      //--- Ajustar trigger según volatilidad
      if(g_volatility > 0)
      {
         breakevenTrigger = MathMax(InpBreakeven, g_volatility * 0.5);
      }
      
      if(profitPoints >= breakevenTrigger)
      {
         double newSL = openPrice;
         
         //--- En mercados volátiles, añadir un pequeño buffer
         double buffer = 0;
         if(g_volatility > 100)
            buffer = 20 * point;  // 20 puntos de buffer extra
         
         if(type == POSITION_TYPE_BUY)
            newSL = openPrice + buffer;
         else
            newSL = openPrice - buffer;
         
         //--- Verificar si mejora la posición
         bool improve = false;
         if(type == POSITION_TYPE_BUY && newSL > currentSL)
            improve = true;
         if(type == POSITION_TYPE_SELL && newSL < currentSL)
            improve = true;
         
         if(improve && newSL != currentSL)
         {
            MqlTradeRequest request = {};
            MqlTradeResult result = {};
            
            request.action = TRADE_ACTION_SLTP;
            request.position = ticket;
            request.symbol = _Symbol;
            request.sl = newSL;
            request.tp = currentTP;
            request.deviation = 50;
            request.magic = g_magicNumber;
            
            if(OrderSend(request, result))
            {
               g_sl = newSL;
               g_isBreakevenActivated = true;
               g_breakevenPrice = newSL;
               g_ticket = ticket;
               
               if(InpPrintLog)
               {
                  Print("🔒 BREAKEVEN ACTIVADO - SL: ", DoubleToString(newSL, _Digits));
                  Print("Ganancia: ", DoubleToString(profitPoints, 1), " pts");
                  Print("Volatilidad: ", DoubleToString(g_volatility, 1), " pts");
               }
               
               //--- Enviar notificación
               if(InpSendNotifications)
                  SendNotification("🔒 Breakeven activado en XAUUSD - Ganancia: " + 
                                  DoubleToString(profitPoints, 1) + " pts");
            }
         }
      }
   }
   
   //--- TRAILING STOP INTELIGENTE (con paso mínimo)
   if(InpUseTrailing && g_isBreakevenActivated)
   {
      double newSL = currentSL;
      
      //--- Trailing dinámico según volatilidad
      double trailingPoints = InpTrailingStop;
      if(g_volatility > 0)
      {
         trailingPoints = MathMax(InpTrailingStop, g_volatility * 0.3);
         trailingPoints = MathMin(trailingPoints, InpTrailingStop * 2);
      }
      
      if(type == POSITION_TYPE_BUY && g_highestPrice > 0)
      {
         double candidateSL = g_highestPrice - trailingPoints * point;
         if(candidateSL > currentSL && candidateSL > openPrice)
         {
            //--- Verificar paso mínimo
            if(candidateSL - currentSL >= InpTrailingStep * point)
               newSL = candidateSL;
         }
      }
      else if(type == POSITION_TYPE_SELL && g_lowestPrice > 0)
      {
         double candidateSL = g_lowestPrice + trailingPoints * point;
         if(candidateSL < currentSL && candidateSL < openPrice)
         {
            if(currentSL - candidateSL >= InpTrailingStep * point)
               newSL = candidateSL;
         }
      }
      
      if(newSL != currentSL)
      {
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         
         request.action = TRADE_ACTION_SLTP;
         request.position = ticket;
         request.symbol = _Symbol;
         request.sl = newSL;
         request.tp = currentTP;
         request.deviation = 50;
         request.magic = g_magicNumber;
         
         if(OrderSend(request, result))
         {
            g_sl = newSL;
            g_ticket = ticket;
            
            if(InpPrintLog)
            {
               Print("📈 TRAILING - SL: ", DoubleToString(newSL, _Digits));
               Print("Ganancia: ", DoubleToString(profitPoints, 1), " pts");
               Print("Distancia SL: ", DoubleToString(slDistance, 1), " pts");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   
   Print("💰 Gold Trade Protector detenido");
}
//+------------------------------------------------------------------+