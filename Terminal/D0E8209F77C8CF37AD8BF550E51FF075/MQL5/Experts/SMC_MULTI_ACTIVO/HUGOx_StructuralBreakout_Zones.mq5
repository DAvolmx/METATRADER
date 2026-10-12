//+------------------------------------------------------------------+
//| XAUUSD - Consolidation Structural Breakout EA                    |
//| Estrategia: Acción del precio / Consolidación / Ruptura          |
//| Sin indicadores                                                   |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

//========================= PARAMETROS ===============================

input string InpSymbol              = "";       // Vacío = símbolo del gráfico
input ENUM_TIMEFRAMES InpTF         = PERIOD_M15;

// Gestión
input double LotSize                = 0.01;
input double StopLossPips           = 150.0;
input double TakeProfitPips         = 100.0;
input double BreakEvenPips          = 50.0;

// XAUUSD: 1 pip = 0.01 por defecto
input double PipSize                = 0.01;

// Consolidación
input int    ConsolidationBars      = 8;

// Máximo rango total de la consolidación
// expresado en múltiplos del tamaño medio de las velas
input double MaxZoneRangeFactor     = 3.0;

// Una vela de consolidación no debe tener cuerpo dominante
input double MaxBodyPercent         = 0.45;

// Mecha mínima para considerar búsqueda de liquidez
input double MinWickBodyRatio       = 0.80;

// Ruptura
input double MinBreakoutBodyPercent = 0.55;

// La vela debe cerrar fuera de la zona
input double MinCloseOutsidePercent = 0.60;

// Evitar repetir la misma ruptura
input int    BreakoutMemoryBars     = 20;

// Magic
input long   MagicNumber             = 26092601;

// Permitir operaciones simultáneas
input bool   AllowMultiplePositions  = true;

input bool   AllowBuy                = true;
input bool   AllowSell               = true;

//========================= VARIABLES ================================

string SymbolToTrade;
datetime LastBarTime = 0;
datetime LastBreakoutTime = 0;

double LastZoneHigh = 0.0;
double LastZoneLow  = 0.0;

//+------------------------------------------------------------------+
//| Inicialización                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   SymbolToTrade = InpSymbol;

   if(SymbolToTrade == "")
      SymbolToTrade = _Symbol;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(50);

   Print("EA iniciado: ", SymbolToTrade);
   Print("TF ejecución: M15");
   Print("Sin indicadores.");
   Print("Lotaje: ", LotSize);
   Print("SL: ", StopLossPips, " pips");
   Print("TP: ", TakeProfitPips, " pips");
   Print("BE: ", BreakEvenPips, " pips");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   ManageBreakEven();

   if(!IsNewBar())
      return;

   EvaluateMarket();
}

//+------------------------------------------------------------------+
//| Detectar nueva vela                                              |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBar = iTime(SymbolToTrade, InpTF, 0);

   if(currentBar == 0)
      return false;

   if(currentBar != LastBarTime)
   {
      LastBarTime = currentBar;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Evaluación principal                                             |
//+------------------------------------------------------------------+
void EvaluateMarket()
{
   if(Bars(SymbolToTrade, InpTF) < ConsolidationBars + 10)
      return;

   double zoneHigh = 0.0;
   double zoneLow  = 0.0;

   // La consolidación termina en la vela 2.
   // La vela 1 será la vela de ruptura.
   if(!FindConsolidation(zoneHigh, zoneLow))
      return;

   double open1  = iOpen(SymbolToTrade, InpTF, 1);
   double close1 = iClose(SymbolToTrade, InpTF, 1);
   double high1  = iHigh(SymbolToTrade, InpTF, 1);
   double low1   = iLow(SymbolToTrade, InpTF, 1);

   //==============================================================
   // RUPTURA ALCISTA
   //==============================================================

   if(AllowBuy && close1 > zoneHigh)
   {
      if(IsValidBreakout(true,
                         open1,
                         close1,
                         high1,
                         low1,
                         zoneHigh,
                         zoneLow))
      {
         if(!AlreadyTradedThisBreakout(iTime(SymbolToTrade, InpTF, 1)))
         {
            OpenBuy();
            LastBreakoutTime = iTime(SymbolToTrade, InpTF, 1);
            LastZoneHigh = zoneHigh;
            LastZoneLow  = zoneLow;
         }

         return;
      }
   }

   //==============================================================
   // RUPTURA BAJISTA
   //==============================================================

   if(AllowSell && close1 < zoneLow)
   {
      if(IsValidBreakout(false,
                         open1,
                         close1,
                         high1,
                         low1,
                         zoneHigh,
                         zoneLow))
      {
         if(!AlreadyTradedThisBreakout(iTime(SymbolToTrade, InpTF, 1)))
         {
            OpenSell();
            LastBreakoutTime = iTime(SymbolToTrade, InpTF, 1);
            LastZoneHigh = zoneHigh;
            LastZoneLow  = zoneLow;
         }

         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Buscar consolidación                                             |
//+------------------------------------------------------------------+
bool FindConsolidation(double &zoneHigh, double &zoneLow)
{
   zoneHigh = -DBL_MAX;
   zoneLow  = DBL_MAX;

   double totalRange = 0.0;
   double totalBody  = 0.0;

   int validBars = 0;

   // Barras 2 ... N+1
   for(int i = 2; i < 2 + ConsolidationBars; i++)
   {
      double open  = iOpen(SymbolToTrade, InpTF, i);
      double close = iClose(SymbolToTrade, InpTF, i);
      double high  = iHigh(SymbolToTrade, InpTF, i);
      double low   = iLow(SymbolToTrade, InpTF, i);

      if(open == 0 || close == 0)
         return false;

      double range = high - low;
      double body  = MathAbs(close - open);

      if(range <= 0)
         return false;

      double bodyPercent = body / range;

      // La consolidación no debe estar formada por velas
      // fuertemente direccionales.
      if(bodyPercent > MaxBodyPercent)
         return false;

      // Actualizar límites
      if(high > zoneHigh)
         zoneHigh = high;

      if(low < zoneLow)
         zoneLow = low;

      totalRange += range;
      totalBody  += body;

      validBars++;
   }

   if(validBars != ConsolidationBars)
      return false;

   double zoneRange = zoneHigh - zoneLow;

   if(zoneRange <= 0)
      return false;

   double averageRange = totalRange / validBars;

   // Zona demasiado amplia = no es una consolidación limpia
   if(zoneRange > averageRange * MaxZoneRangeFactor)
      return false;

   // Comprobación adicional de acción de precio/liquidez
   int wickBars = 0;

   for(int i = 2; i < 2 + ConsolidationBars; i++)
   {
      double open  = iOpen(SymbolToTrade, InpTF, i);
      double close = iClose(SymbolToTrade, InpTF, i);
      double high  = iHigh(SymbolToTrade, InpTF, i);
      double low   = iLow(SymbolToTrade, InpTF, i);

      double body = MathAbs(close - open);

      if(body <= SymbolInfoDouble(SymbolToTrade, SYMBOL_POINT))
         body = SymbolInfoDouble(SymbolToTrade, SYMBOL_POINT);

      double upperWick = high - MathMax(open, close);
      double lowerWick = MathMin(open, close) - low;

      if(upperWick / body >= MinWickBodyRatio ||
         lowerWick / body >= MinWickBodyRatio)
      {
         wickBars++;
      }
   }

   // Necesitamos evidencia de rechazo/liquidez,
   // pero no exigimos que todas las velas tengan mechas.
   if(wickBars < 2)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Validar ruptura                                                  |
//+------------------------------------------------------------------+
bool IsValidBreakout(bool bullish,
                     double open,
                     double close,
                     double high,
                     double low,
                     double zoneHigh,
                     double zoneLow)
{
   double range = high - low;

   if(range <= 0)
      return false;

   double body = MathAbs(close - open);

   if(body <= 0)
      return false;

   // El cuerpo debe representar una parte importante
   // de toda la vela.
   double bodyPercent = body / range;

   if(bodyPercent < MinBreakoutBodyPercent)
      return false;

   //==============================================================
   // ALCISTA
   //==============================================================

   if(bullish)
   {
      if(close <= zoneHigh)
         return false;

      // Cuánto de la vela queda por encima de la zona
      double outsideDistance = close - zoneHigh;

      if(outsideDistance <= 0)
         return false;

      // El cierre debe encontrarse claramente fuera de la zona
      double closePosition = (close - zoneHigh) / range;

      if(closePosition < MinCloseOutsidePercent)
         return false;

      // La vela debe tener dirección alcista
      if(close <= open)
         return false;

      return true;
   }

   //==============================================================
   // BAJISTA
   //==============================================================

   if(!bullish)
   {
      if(close >= zoneLow)
         return false;

      double outsideDistance = zoneLow - close;

      if(outsideDistance <= 0)
         return false;

      double closePosition = (zoneLow - close) / range;

      if(closePosition < MinCloseOutsidePercent)
         return false;

      if(close >= open)
         return false;

      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Comprobar duplicación                                            |
//+------------------------------------------------------------------+
bool AlreadyTradedThisBreakout(datetime breakoutTime)
{
   if(LastBreakoutTime == 0)
      return false;

   if(breakoutTime == LastBreakoutTime)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| Abrir compra                                                     |
//+------------------------------------------------------------------+
void OpenBuy()
{
   if(!AllowMultiplePositions && CountMyPositions() > 0)
      return;

   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);

   if(ask <= 0)
      return;

   double sl = ask - StopLossPips * PipSize;
   double tp = ask + TakeProfitPips * PipSize;

   sl = NormalizePrice(sl);
   tp = NormalizePrice(tp);

   bool result = trade.Buy(
      LotSize,
      SymbolToTrade,
      ask,
      sl,
      tp,
      "Structural Breakout BUY"
   );

   if(result)
   {
      Print("BUY ejecutada | Precio: ", ask,
            " | SL: ", sl,
            " | TP: ", tp);
   }
   else
   {
      Print("Error BUY: ", trade.ResultRetcode(),
            " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Abrir venta                                                      |
//+------------------------------------------------------------------+
void OpenSell()
{
   if(!AllowMultiplePositions && CountMyPositions() > 0)
      return;

   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);

   if(bid <= 0)
      return;

   double sl = bid + StopLossPips * PipSize;
   double tp = bid - TakeProfitPips * PipSize;

   sl = NormalizePrice(sl);
   tp = NormalizePrice(tp);

   bool result = trade.Sell(
      LotSize,
      SymbolToTrade,
      bid,
      sl,
      tp,
      "Structural Breakout SELL"
   );

   if(result)
   {
      Print("SELL ejecutada | Precio: ", bid,
            " | SL: ", sl,
            " | TP: ", tp);
   }
   else
   {
      Print("Error SELL: ", trade.ResultRetcode(),
            " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Break-even                                                       |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long magic    = PositionGetInteger(POSITION_MAGIC);

      if(symbol != SymbolToTrade || magic != MagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
      double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);

      // BUY
      if(type == POSITION_TYPE_BUY)
      {
         double profitDistance = bid - openPrice;

         if(profitDistance >= BreakEvenPips * PipSize)
         {
            double newSL = NormalizePrice(openPrice);

            if(currentSL < newSL || currentSL == 0)
            {
               trade.PositionModify(
                  ticket,
                  newSL,
                  currentTP
               );
            }
         }
      }

      // SELL
      if(type == POSITION_TYPE_SELL)
      {
         double profitDistance = openPrice - ask;

         if(profitDistance >= BreakEvenPips * PipSize)
         {
            double newSL = NormalizePrice(openPrice);

            if(currentSL > newSL || currentSL == 0)
            {
               trade.PositionModify(
                  ticket,
                  newSL,
                  currentTP
               );
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Contar posiciones del EA                                         |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) == SymbolToTrade &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         count++;
      }
   }

   return count;
}

//+------------------------------------------------------------------+
//| Normalizar precio                                                |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   int digits = (int)SymbolInfoInteger(
      SymbolToTrade,
      SYMBOL_DIGITS
   );

   return NormalizeDouble(price, digits);
}
//+------------------------------------------------------------------+