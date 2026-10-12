//+------------------------------------------------------------------+
//|                                    EA_Pendientes_Deriv.mq5       |
//|                                  Copyright 2024, Asistente AI    |
//+------------------------------------------------------------------+
#property copyright "Asistente AI"
#property version   "2.10"
#include <Trade\Trade.mqh>

//--- Enumeración para elegir el tipo de orden pendiente
enum ENUM_TIPO_PENDIENTE
  {
   PENDIENTE_BUY_STOP = 0,   // Buy Stop (por encima del Ask)
   PENDIENTE_BUY_LIMIT = 1,  // Buy Limit (por debajo del Ask)
   PENDIENTE_SELL_STOP = 2,  // Sell Stop (por debajo del Bid)
   PENDIENTE_SELL_LIMIT = 3  // Sell Limit (por encima del Bid)
  };

//--- Parámetros de Entrada
input ENUM_TIPO_PENDIENTE InpTipoPendiente = PENDIENTE_BUY_STOP; // Tipo de orden pendiente
input double   InpLotSize        = 0.1;    // Tamaño del Lote
input int      InpFastEMA        = 5;       // EMA Rápida
input int      InpSlowEMA        = 13;      // EMA Lenta
input int      InpDistanciaPend  = 300;     // Distancia de la orden pendiente (en puntos)
input int      InpTP             = 2000;    // Take Profit en puntos
input int      InpSL             = 80;      // Stop Loss en puntos
input int      InpTrailingStart  = 250;     // Inicio del Trailing Stop
input int      InpTrailingStep   = 50;      // Paso del Trailing Stop
input int      InpMaxOrders      = 5;       // Máximo de órdenes simultáneas
input int      InpMagic          = 999888;  // Número Mágico
input int      InpATR_Period     = 14;      // Periodo del ATR
input double   InpMinATR         = 0.50;    // ATR mínimo para operar
input int      InpExpirationMin  = 60;      // Expiración de la orden pendiente (minutos, 0=sin expiración)

//--- Variables Globales
CTrade         trade;
int            hFastEMA, hSlowEMA, hATR;
datetime       lastBarTime = 0;

//+------------------------------------------------------------------+
//| Inicialización                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol);

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
   // 1. Gestión de Trailing Stop (solo para posiciones abiertas)
   ManageTrailingStop();

   // 2. Solo evaluar nuevas entradas al abrir una vela nueva
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // 3. Obtener datos de indicadores
   double fast[2], slow[2], atr[1];
   if(CopyBuffer(hFastEMA, 0, 0, 2, fast) <= 0) return;
   if(CopyBuffer(hSlowEMA, 0, 0, 2, slow) <= 0) return;
   if(CopyBuffer(hATR, 0, 0, 1, atr) <= 0) return;

   // 4. Filtro de Volatilidad
   if(atr[0] < InpMinATR) return;

   // 5. Determinar Tendencia
   bool isBullish = (fast[0] > slow[0]);
   bool isBearish = (fast[0] < slow[0]);

   // 6. Contar órdenes y posiciones actuales
   int buyCount = 0, sellCount = 0;
   int buyPend  = 0, sellPend  = 0;
   CountOrders(buyCount, sellCount, buyPend, sellPend);

   // 7. Precios actuales
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // 8. Expiración de la orden pendiente
   datetime expiration = 0;
   if(InpExpirationMin > 0)
      expiration = TimeCurrent() + InpExpirationMin * 60;

   // 9. Colocar orden pendiente según tendencia y tipo elegido
   //    Solo si no hemos alcanzado el máximo de órdenes totales
   if(isBullish && (buyCount + buyPend) < InpMaxOrders)
     {
      // Solo colocar si no hay ya una pendiente idéntica abierta
      if(!ExistePendienteSimilar(ORDER_TYPE_BUY_STOP) && 
         !ExistePendienteSimilar(ORDER_TYPE_BUY_LIMIT))
        {
         ColocarPendiente(true, ask, bid, point, digits, expiration);
        }
     }
   else if(isBearish && (sellCount + sellPend) < InpMaxOrders)
     {
      if(!ExistePendienteSimilar(ORDER_TYPE_SELL_STOP) && 
         !ExistePendienteSimilar(ORDER_TYPE_SELL_LIMIT))
        {
         ColocarPendiente(false, ask, bid, point, digits, expiration);
        }
     }
  }

//+------------------------------------------------------------------+
//| Coloca la orden pendiente según el tipo elegido                  |
//+------------------------------------------------------------------+
void ColocarPendiente(bool esCompra, double ask, double bid, double point, int digits, datetime expiration)
  {
   double precioEntrada = 0.0;
   double sl = 0.0;
   double tp = 0.0;
   string comentario = "";

   if(esCompra)
     {
      // --- BUY ---
      if(InpTipoPendiente == PENDIENTE_BUY_STOP)
        {
         precioEntrada = NormalizeDouble(ask + InpDistanciaPend * point, digits);
         sl = NormalizeDouble(precioEntrada - InpSL * point, digits);
         tp = NormalizeDouble(precioEntrada + InpTP * point, digits);
         comentario = "Buy Stop";
         trade.BuyStop(InpLotSize, precioEntrada, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiration, comentario);
        }
      else if(InpTipoPendiente == PENDIENTE_BUY_LIMIT)
        {
         precioEntrada = NormalizeDouble(ask - InpDistanciaPend * point, digits);
         sl = NormalizeDouble(precioEntrada - InpSL * point, digits);
         tp = NormalizeDouble(precioEntrada + InpTP * point, digits);
         comentario = "Buy Limit";
         trade.BuyLimit(InpLotSize, precioEntrada, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiration, comentario);
        }
     }
   else
     {
      // --- SELL ---
      if(InpTipoPendiente == PENDIENTE_SELL_STOP)
        {
         precioEntrada = NormalizeDouble(bid - InpDistanciaPend * point, digits);
         sl = NormalizeDouble(precioEntrada + InpSL * point, digits);
         tp = NormalizeDouble(precioEntrada - InpTP * point, digits);
         comentario = "Sell Stop";
         trade.SellStop(InpLotSize, precioEntrada, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiration, comentario);
        }
      else if(InpTipoPendiente == PENDIENTE_SELL_LIMIT)
        {
         precioEntrada = NormalizeDouble(bid + InpDistanciaPend * point, digits);
         sl = NormalizeDouble(precioEntrada + InpSL * point, digits);
         tp = NormalizeDouble(precioEntrada - InpTP * point, digits);
         comentario = "Sell Limit";
         trade.SellLimit(InpLotSize, precioEntrada, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiration, comentario);
        }
     }
  }

//+------------------------------------------------------------------+
//| Verifica si ya existe una orden pendiente del tipo indicado      |
//+------------------------------------------------------------------+
bool ExistePendienteSimilar(ENUM_ORDER_TYPE tipo)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == tipo)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Función para gestionar el Trailing Stop                          |
//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

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

      if(type == POSITION_TYPE_BUY)
        {
         double newSL = bid - (InpTrailingStart * point);
         if(bid - openPrice > InpTrailingStart * point)
           {
            if(newSL > currentSL + InpTrailingStep * point)
               trade.PositionModify(ticket, newSL, currentTP);
           }
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double newSL = ask + (InpTrailingStart * point);
         if(openPrice - ask > InpTrailingStart * point)
           {
            if(currentSL == 0 || newSL < currentSL - InpTrailingStep * point)
               trade.PositionModify(ticket, newSL, currentTP);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Cuenta posiciones y órdenes pendientes                           |
//+------------------------------------------------------------------+
void CountOrders(int &buyCount, int &sellCount, int &buyPend, int &sellPend)
  {
   buyCount = 0; sellCount = 0; buyPend = 0; sellPend = 0;

   // Posiciones abiertas
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

   // Órdenes pendientes
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_LIMIT) buyPend++;
      if(type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_LIMIT) sellPend++;
     }
  }
//+------------------------------------------------------------------+