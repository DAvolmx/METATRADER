//+------------------------------------------------------------------+
//|                                          GoldTradeProtector.mq5  |
//|                                           Optimizado para XAUUSD |
//|                                                   Versión 5.0     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property link      ""
#property version   "5.00"

//--- PARÁMETROS PRINCIPALES
input double   InpStopLoss     = 300;   // Stop Loss (en puntos)
input double   InpTakeProfit   = 600;   // Take Profit (en puntos)
input double   InpTrailingStop = 150;   // Trailing Stop (en puntos)
input double   InpBreakeven    = 80;    // Breakeven (puntos de ganancia)
input bool     InpUseTrailing  = true;  // Activar Trailing Stop
input bool     InpUseBreakeven = true;  // Activar Breakeven

//--- PARÁMETROS AVANZADOS PARA VOLATILIDAD DEL ORO
input double   InpVolatilityFilter = 1.5;   // Multiplicador por volatilidad
input int      InpMinSLPoints      = 100;   // SL mínimo en puntos
input int      InpMaxSLPoints      = 800;   // SL máximo en puntos
input int      InpTrailingStep     = 50;    // Paso mínimo para trailing
input double   InpRiskRewardRatio  = 2.0;   // Ratio Riesgo/Beneficio
input bool     InpDynamicTP        = true;  // TP dinámico según volatilidad
input int      InpATRPeriod        = 14;    // Período ATR para ajuste dinámico

//--- PARÁMETROS DE PROTECCIÓN DE CAPITAL
input double   InpMaxRiskPercent    = 2.0;   // Riesgo máximo por operación (% del balance)
input double   InpMaxDailyLoss      = 5.0;   // Pérdida máxima diaria (% del balance)
input double   InpMaxDrawdown       = 10.0;  // Drawdown máximo permitido (%)
input double   InpMaxLotSize        = 1.0;   // Tamaño máximo de lote permitido
input bool     InpUseRiskManagement = true;  // Activar gestión de riesgo
input double   InpProfitLockPercent = 50.0;  // % de ganancia a bloquear
input bool     InpUseProfitLock     = true;  // Activar bloqueo de ganancias

//--- PARÁMETROS DE SEGURIDAD
input bool     InpLockBreakeven    = true;  // Bloquear breakeven (no permite retroceso)
input double   InpPartialClose     = 0.0;   // Cierre parcial (0 = desactivado)
input bool     InpUseTimeFilter    = false; // Filtrar por horas de alta volatilidad

//--- PARÁMETROS DE NOTIFICACIÓN
input bool     InpSendNotifications = false;// Enviar notificaciones push
input bool     InpPrintLog          = true; // Mostrar logs detallados

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

//--- VARIABLES DE PROTECCIÓN DE CAPITAL
double g_initialBalance = 0;
double g_dailyStartBalance = 0;
double g_maxEquity = 0;
double g_dailyLoss = 0;
datetime g_lastDayReset = 0;
bool   g_tradingEnabled = true;
double g_lockedProfit = 0;

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
   
   //--- Inicializar protección de capital
   g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dailyStartBalance = g_initialBalance;
   g_maxEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_lastDayReset = TimeCurrent();
   
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
   Print("💰 GOLD TRADE PROTECTOR v5.0 INICIADO");
   Print("⚡ Optimizado para XAUUSD y mercados volátiles");
   Print("🛡️ PROTECCIÓN DE CAPITAL ACTIVADA");
   Print("=========================================");
   Print("SL: ", InpStopLoss, " pts | TP: ", InpTakeProfit, " pts");
   Print("Trailing: ", InpTrailingStop, " pts | Breakeven: ", InpBreakeven, " pts");
   Print("ATR: ", DoubleToString(g_atrValue, 2), " | Volatilidad: ", DoubleToString(g_volatility, 2));
   Print("--- PROTECCIÓN DE CAPITAL ---");
   Print("Riesgo máx/operación: ", InpMaxRiskPercent, "%");
   Print("Pérdida máx diaria: ", InpMaxDailyLoss, "%");
   Print("Drawdown máx: ", InpMaxDrawdown, "%");
   Print("Balance inicial: ", DoubleToString(g_initialBalance, 2));
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
   
   //--- Reset diario de pérdidas
   ResetDailyStats();
   
   //--- Actualizar volatilidad cada 10 segundos
   if(TimeCurrent() % 10 == 0)
      UpdateVolatility();
   
   //--- Verificar protección de capital ANTES de cualquier operación
   if(!CheckCapitalProtection())
   {
      if(g_tradingEnabled)
      {
         g_tradingEnabled = false;
         Print("🛑 TRADING DESHABILITADO POR PROTECCIÓN DE CAPITAL");
         if(InpSendNotifications)
            SendNotification("🛑 Trading deshabilitado - Protección de capital activada");
      }
      return;
   }
   else if(!g_tradingEnabled)
   {
      g_tradingEnabled = true;
      Print("✅ Trading rehabilitado");
   }
   
   CheckAllTrades();
}

//+------------------------------------------------------------------+
//| Resetear estadísticas diarias                                    |
//+------------------------------------------------------------------+
void ResetDailyStats()
{
   MqlDateTime currentTime, lastTime;
   TimeToStruct(TimeCurrent(), currentTime);
   TimeToStruct(g_lastDayReset, lastTime);
   
   if(currentTime.day != lastTime.day)
   {
      g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyLoss = 0;
      g_lastDayReset = TimeCurrent();
      
      if(InpPrintLog)
         Print("📅 Reset diario - Nuevo balance base: ", DoubleToString(g_dailyStartBalance, 2));
   }
}

//+------------------------------------------------------------------+
//| Verificar protección de capital                                  |
//+------------------------------------------------------------------+
bool CheckCapitalProtection()
{
   if(!InpUseRiskManagement)
      return true;
   
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   //--- Actualizar máximo equity para drawdown
   if(currentEquity > g_maxEquity)
      g_maxEquity = currentEquity;
   
   //--- 1. Verificar pérdida diaria máxima
   double dailyLossPercent = 0;
   if(g_dailyStartBalance > 0)
   {
      dailyLossPercent = ((g_dailyStartBalance - currentEquity) / g_dailyStartBalance) * 100;
   }
   
   if(dailyLossPercent >= InpMaxDailyLoss)
   {
      Print("⚠️ LÍMITE DE PÉRDIDA DIARIA ALCANZADO: ", DoubleToString(dailyLossPercent, 2), "%");
      return false;
   }
   
   //--- 2. Verificar drawdown máximo
   double drawdownPercent = 0;
   if(g_maxEquity > 0)
   {
      drawdownPercent = ((g_maxEquity - currentEquity) / g_maxEquity) * 100;
   }
   
   if(drawdownPercent >= InpMaxDrawdown)
   {
      Print("⚠️ DRAWDOWN MÁXIMO ALCANZADO: ", DoubleToString(drawdownPercent, 2), "%");
      return false;
   }
   
   //--- 3. Verificar pérdida desde balance inicial
   double totalLossPercent = ((g_initialBalance - currentEquity) / g_initialBalance) * 100;
   if(totalLossPercent >= InpMaxDrawdown * 1.5)
   {
      Print("⚠️ PÉRDIDA TOTAL CRÍTICA: ", DoubleToString(totalLossPercent, 2), "%");
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Calcular lote seguro según riesgo                               |
//+------------------------------------------------------------------+
double CalculateSafeLotSize(double slPoints)
{
   if(!InpUseRiskManagement)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (InpMaxRiskPercent / 100.0);
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(tickValue <= 0 || tickSize <= 0 || slPoints <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   
   //--- Calcular valor por punto
   double valuePerPoint = (tickValue / tickSize) * point;
   
   //--- Calcular lote
   double lotSize = riskAmount / (slPoints * valuePerPoint);
   
   //--- Normalizar lote
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLotSize);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Bloquear ganancias                                               |
//+------------------------------------------------------------------+
void LockProfits()
{
   if(!InpUseProfitLock)
      return;
   
   double currentProfit = 0;
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   //--- Calcular ganancia total flotante
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)
            currentProfit += PositionGetDouble(POSITION_PROFIT);
      }
   }
   
   //--- Si hay ganancia significativa, bloquear un porcentaje
   if(currentProfit > 0 && currentEquity > g_dailyStartBalance)
   {
      double profitFromStart = currentEquity - g_dailyStartBalance;
      double profitToLock = profitFromStart * (InpProfitLockPercent / 100.0);
      
      if(profitToLock > g_lockedProfit)
      {
         g_lockedProfit = profitToLock;
         
         if(InpPrintLog)
            Print("🔐 GANANCIA BLOQUEADA: ", DoubleToString(g_lockedProfit, 2));
      }
   }
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
   
   //--- Bloquear ganancias periódicamente
   LockProfits();
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
   
   //--- Verificar que el lote sea seguro antes de aplicar
   double currentVolume = PositionGetDouble(POSITION_VOLUME);
   double safeLot = CalculateSafeLotSize(slPoints);
   
   if(currentVolume > safeLot && InpUseRiskManagement)
   {
      Print("⚠️ LOTE EXCEDE RIESGO MÁXIMO: ", currentVolume, " > ", safeLot);
      Print("   Considerar reducir posición manualmente");
      
      if(InpSendNotifications)
         SendNotification("⚠️ Lote excede riesgo máximo permitido");
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
         Print("Lote seguro calculado: ", DoubleToString(safeLot, 2));
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
   
   //--- Declarar trailingPoints AL INICIO para uso global en la función
   double trailingPoints = InpTrailingStop;
   if(g_volatility > 0)
   {
      trailingPoints = MathMax(InpTrailingStop, g_volatility * 0.3);
      trailingPoints = MathMin(trailingPoints, InpTrailingStop * 2);
   }
   
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
   
   //--- FILTRO DE VOLATILIDAD EXTREMA PARA ORO
   double volatilityThreshold = g_volatility * 3.0;  // Más permisivo para oro
   if(g_volatility > volatilityThreshold && profitPoints < InpBreakeven * 2)
   {
      if(InpPrintLog)
         Print("⚠️ Volatilidad extrema en ORO: ", DoubleToString(g_volatility, 1), " pts - Esperando...");
      return;
   }
   
   //--- DETECCIÓN DE SPIKES EN ORO
   double spikeThreshold = g_atrValue * 2.5;
   double priceChange = MathAbs(currentPrice - g_openPrice);
   if(priceChange > spikeThreshold && profitPoints < InpBreakeven)
   {
      if(InpPrintLog)
         Print("⚡ SPIKE DETECTADO en ORO - Protegiendo posición...");
      
      //--- Mover SL a breakeven inmediatamente si hay spike
      if(profitPoints > 0 && !g_isBreakevenActivated)
      {
         double newSL = openPrice;
         if(type == POSITION_TYPE_BUY && newSL > currentSL)
         {
            MqlTradeRequest request = {};
            MqlTradeResult result = {};
            request.action = TRADE_ACTION_SLTP;
            request.position = ticket;
            request.symbol = _Symbol;
            request.sl = newSL;
            request.tp = currentTP;
            request.deviation = 100;  // Mayor desviación para spikes
            request.magic = g_magicNumber;
            
            if(OrderSend(request, result))
            {
               g_isBreakevenActivated = true;
               Print("🛡️ SL movido a breakeven por SPIKE");
            }
         }
         else if(type == POSITION_TYPE_SELL && newSL < currentSL)
         {
            MqlTradeRequest request = {};
            MqlTradeResult result = {};
            request.action = TRADE_ACTION_SLTP;
            request.position = ticket;
            request.symbol = _Symbol;
            request.sl = newSL;
            request.tp = currentTP;
            request.deviation = 100;
            request.magic = g_magicNumber;
            
            if(OrderSend(request, result))
            {
               g_isBreakevenActivated = true;
               Print("🛡️ SL movido a breakeven por SPIKE");
            }
         }
      }
   }
   
   //--- BREAKEVEN DINÁMICO (con bloqueo y protección de capital)
   if(InpUseBreakeven && !g_isBreakevenActivated)
   {
      double breakevenTrigger = InpBreakeven;
      
      //--- Ajustar trigger según volatilidad del oro
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
   
   //--- TRAILING STOP INTELIGENTE (con paso mínimo y protección)
   if(InpUseTrailing && g_isBreakevenActivated)
   {
      double newSL = currentSL;
      
      //--- trailingPoints ya está declarado al inicio de la función
      
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
   
   //--- PROTECCIÓN ADICIONAL: Cerrar si la ganancia supera cierto umbral y hay reversión
   if(InpUseProfitLock && profitPoints > InpTakeProfit * 0.8)
   {
      //--- Verificar si hay reversión significativa
      double reversalThreshold = g_atrValue * 1.5;
      double maxProfitPrice = (type == POSITION_TYPE_BUY) ? g_highestPrice : g_lowestPrice;
      double reversal = MathAbs(currentPrice - maxProfitPrice);
      
      if(reversal > reversalThreshold && profitPoints > InpBreakeven * 3)
      {
         if(InpPrintLog)
            Print("🔐 PROTECCIÓN DE GANANCIA: Reversión detectada, asegurando ganancia");
         
         //--- Mover SL más agresivamente
         double aggressiveSL = 0;
         if(type == POSITION_TYPE_BUY)
            aggressiveSL = currentPrice - (trailingPoints * 0.5) * point;
         else
            aggressiveSL = currentPrice + (trailingPoints * 0.5) * point;
         
         bool improve = false;
         if(type == POSITION_TYPE_BUY && aggressiveSL > currentSL)
            improve = true;
         if(type == POSITION_TYPE_SELL && aggressiveSL < currentSL)
            improve = true;
         
         if(improve)
         {
            MqlTradeRequest request = {};
            MqlTradeResult result = {};
            
            request.action = TRADE_ACTION_SLTP;
            request.position = ticket;
            request.symbol = _Symbol;
            request.sl = aggressiveSL;
            request.tp = currentTP;
            request.deviation = 50;
            request.magic = g_magicNumber;
            
            if(OrderSend(request, result))
            {
               g_sl = aggressiveSL;
               Print("🔐 SL agresivo aplicado por reversión: ", DoubleToString(aggressiveSL, _Digits));
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
   
   //--- Mostrar resumen final
   double finalBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double totalReturn = 0;
   if(g_initialBalance > 0)
      totalReturn = ((finalBalance - g_initialBalance) / g_initialBalance) * 100;
   
   Print("=========================================");
   Print("💰 Gold Trade Protector v5.0 detenido");
   Print("Balance inicial: ", DoubleToString(g_initialBalance, 2));
   Print("Balance final: ", DoubleToString(finalBalance, 2));
   Print("Retorno total: ", DoubleToString(totalReturn, 2), "%");
   Print("Ganancia bloqueada: ", DoubleToString(g_lockedProfit, 2));
   Print("=========================================");
}
//+------------------------------------------------------------------+