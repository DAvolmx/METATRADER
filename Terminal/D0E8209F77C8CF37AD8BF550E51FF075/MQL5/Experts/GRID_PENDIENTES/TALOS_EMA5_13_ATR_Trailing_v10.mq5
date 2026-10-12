//+------------------------------------------------------------------+
//|                                       EA_Agresivo_Micro_v10.mq5  |
//|                                  Copyright 2024, Asistente AI    |
//+------------------------------------------------------------------+
#property copyright "Asistente AI"
#property version   "10.00"
#include <Trade\Trade.mqh>

//--- Parámetros de Entrada
input double   InpLotSize     = 0.1;     // Tamaño del Lote
input int      InpFastEMA     = 5;       // EMA Rápida
input int      InpSlowEMA     = 13;      // EMA Lenta
input int      InpTP          = 110;     // Take Profit en puntos
input int      InpSL          = 60;      // Stop Loss en puntos
input int      InpMaxOrders   = 4;       // Máximo de órdenes
input int      InpMagic       = 20250912;// Número Mágico
input int      InpATR_Period  = 14;      // Periodo del ATR
input double   InpMinATR      = 0.30;    // ATR mínimo
input int      InpReversalWaitBars = 2;  // Velas a esperar tras cambio
input bool     InpCloseOnReversal  = true; // Cerrar al cambiar tendencia
input bool     InpUseDynamicSLTP   = true; // Usar SL/TP dinámico con ATR

//--- NUEVOS PARÁMETROS DE TRAILING STOP ---
input bool     InpUseTrailing      = true;  // Activar Trailing Stop
input double   InpTrailingStartATR = 1.5;   // Inicio del Trailing (x ATR)
input double   InpTrailingStepATR  = 0.5;   // Paso del Trailing (x ATR)
input int      InpTrailingStartMin = 800;   // Inicio mínimo en puntos ($0.80)
input int      InpTrailingStepMin  = 300;   // Paso mínimo en puntos ($0.30)

//--- Variables Globales
CTrade         trade;
int            hFastEMA, hSlowEMA, hATR;
datetime       lastBarTime = 0;
double         minVolume, maxVolume, stepVolume;
double         adjustedLotSize;
int            currentTrend = 0;
int            barsSinceReversal = 999;

//+------------------------------------------------------------------+
//| Inicialización                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   string symbolName = _Symbol;
   StringToUpper(symbolName);
   if(StringFind(symbolName, "XAU") < 0)
      Print("⚠️ ADVERTENCIA: El símbolo ", _Symbol, " no parece ser Oro (XAU).");

   minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   stepVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   Print("📊 Volumen Mínimo: ", minVolume, " | Máximo: ", maxVolume, " | Paso: ", stepVolume);

   adjustedLotSize = InpLotSize;
   if(adjustedLotSize < minVolume) adjustedLotSize = minVolume;
   if(adjustedLotSize > maxVolume) adjustedLotSize = maxVolume;
   adjustedLotSize = MathFloor(adjustedLotSize / stepVolume) * stepVolume;
   Print("✅ Lote Final: ", adjustedLotSize);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   hFastEMA = iMA(_Symbol, _Period, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol, _Period, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR     = iATR(_Symbol, _Period, InpATR_Period);
   
   if(hFastEMA == INVALID_HANDLE || hSlowEMA == INVALID_HANDLE || hATR == INVALID_HANDLE)
      return(INIT_FAILED);
      
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinicialización                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(hFastEMA);
   IndicatorRelease(hSlowEMA);
   IndicatorRelease(hATR);
  }

//+------------------------------------------------------------------+
//| Función Principal (Tick)                                         |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- 1. Gestionar Trailing Stop (se ejecuta siempre)
   if(InpUseTrailing) ManageTrailingStop();

   //--- 2. Solo evaluar nuevas entradas al abrir vela nueva
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   barsSinceReversal++;

   double fast[3], slow[3], atr[1];
   if(CopyBuffer(hFastEMA, 0, 0, 3, fast) <= 0) return;
   if(CopyBuffer(hSlowEMA, 0, 0, 3, slow) <= 0) return;
   if(CopyBuffer(hATR, 0, 0, 1, atr) <= 0) return;

   int newTrend = 0;
   if(fast[0] > slow[0]) newTrend = 1;
   else if(fast[0] < slow[0]) newTrend = -1;

   bool trendChanged = (newTrend != currentTrend && currentTrend != 0);

   if(trendChanged)
     {
      Print("🔄 CAMBIO DE TENDENCIA: ", (currentTrend == 1 ? "ALCISTA → BAJISTA" : "BAJISTA → ALCISTA"));
      if(InpCloseOnReversal) ClosePositionsAgainstTrend(newTrend);
      barsSinceReversal = 0;
     }

   currentTrend = newTrend;

   if(barsSinceReversal < InpReversalWaitBars) return;
   if(atr[0] < InpMinATR) return;

   int buyCount = 0, sellCount = 0;
   CountOrders(buyCount, sellCount);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   //--- CÁLCULO DINÁMICO DE SL/TP BASADO EN ATR ---
   double slPoints, tpPoints;
   if(InpUseDynamicSLTP)
     {
      slPoints = (atr[0] * 1.5) / point;
      tpPoints = (atr[0] * 3.0) / point;
      if(slPoints < 300) slPoints = 300;
      if(slPoints > 1500) slPoints = 1500;
      if(tpPoints < 600) tpPoints = 600;
      if(tpPoints > 3000) tpPoints = 3000;
     }
   else
     {
      slPoints = InpSL;
      tpPoints = InpTP;
     }

   double slDistance = slPoints * point;
   double tpDistance = tpPoints * point;

   if(newTrend == 1 && buyCount < InpMaxOrders)
     {
      if(!CheckMargin(ORDER_TYPE_BUY, adjustedLotSize, ask)) return;
      double sl = ask - slDistance;
      double tp = ask + tpDistance;
      trade.Buy(adjustedLotSize, _Symbol, ask, sl, tp, "Buy Agresivo");
     }
   else if(newTrend == -1 && sellCount < InpMaxOrders)
     {
      if(!CheckMargin(ORDER_TYPE_SELL, adjustedLotSize, bid)) return;
      double sl = bid + slDistance;
      double tp = bid - tpDistance;
      trade.Sell(adjustedLotSize, _Symbol, bid, sl, tp, "Sell Agresivo");
     }
  }

//+------------------------------------------------------------------+
//| TRAILING STOP INTELIGENTE (con espacio para respirar)            |
//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   //--- Obtener ATR actual para calcular trailing dinámico
   double atr[1];
   if(CopyBuffer(hATR, 0, 0, 1, atr) <= 0) return;
   
   //--- Calcular distancias de trailing basadas en ATR
   double trailStartATR = atr[0] * InpTrailingStartATR;
   double trailStepATR  = atr[0] * InpTrailingStepATR;
   
   //--- Convertir a puntos, con mínimos para evitar trailing demasiado ajustado
   int trailStartPoints = (int)MathMax(trailStartATR / point, InpTrailingStartMin);
   int trailStepPoints  = (int)MathMax(trailStepATR / point, InpTrailingStepMin);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      //--- TRAILING PARA COMPRAS ---
      if(type == POSITION_TYPE_BUY)
        {
         // Solo activar si la ganancia supera el umbral de inicio
         double profitPoints = (bid - openPrice) / point;
         if(profitPoints < trailStartPoints) continue;
         
         // Calcular nuevo SL: seguimos al precio con distancia = trailStartPoints
         double newSL = bid - (trailStartPoints * point);
         
         // Solo modificar si el nuevo SL es mejor que el actual
         if(currentSL == 0 || newSL > currentSL + (trailStepPoints * point))
           {
            if(trade.PositionModify(ticket, newSL, currentTP))
               Print("📈 Trailing BUY: SL movido a ", newSL, " | Ganancia: ", profitPoints, " pts");
           }
        }
      //--- TRAILING PARA VENTAS ---
      else if(type == POSITION_TYPE_SELL)
        {
         double profitPoints = (openPrice - ask) / point;
         if(profitPoints < trailStartPoints) continue;
         
         double newSL = ask + (trailStartPoints * point);
         
         if(currentSL == 0 || newSL < currentSL - (trailStepPoints * point))
           {
            if(trade.PositionModify(ticket, newSL, currentTP))
               Print("📉 Trailing SELL: SL movido a ", newSL, " | Ganancia: ", profitPoints, " pts");
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Verificar margen libre                                           |
//+------------------------------------------------------------------+
bool CheckMargin(ENUM_ORDER_TYPE type, double lot, double price)
  {
   double marginRequired = 0.0;
   if(OrderCalcMargin(type, _Symbol, lot, price, marginRequired))
     {
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(freeMargin < marginRequired * 1.1)
        {
         Print("⚠️ Margen insuficiente. Libre: ", freeMargin, " | Requerido: ", marginRequired);
         return false;
        }
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Cerrar posiciones contra tendencia                                |
//+------------------------------------------------------------------+
void ClosePositionsAgainstTrend(int newTrend)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool shouldClose = false;
      if(newTrend == 1 && type == POSITION_TYPE_SELL) shouldClose = true;
      if(newTrend == -1 && type == POSITION_TYPE_BUY) shouldClose = true;
      
      if(shouldClose)
        {
         if(trade.PositionClose(ticket))
            Print("✅ Posición cerrada. Ticket: ", ticket);
        }
     }
  }

//+------------------------------------------------------------------+
//| Contar órdenes activas                                           |
//+------------------------------------------------------------------+
void CountOrders(int &buyCount, int &sellCount)
  {
   buyCount = 0;
   sellCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY) buyCount++;
      if(type == POSITION_TYPE_SELL) sellCount++;
     }
  }
//+------------------------------------------------------------------+