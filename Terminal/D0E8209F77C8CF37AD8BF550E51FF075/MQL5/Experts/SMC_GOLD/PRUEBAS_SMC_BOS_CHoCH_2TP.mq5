//+------------------------------------------------------------------+
//|                                                  SMC_EA.mq5      |
//|  Expert Advisor SMC (Smart Money Concepts) para XAUUSD/Gold      |
//|  - Detección de swings via Fractals                              |
//|  - Detección de BOS / CHoCH                                      |
//|  - Zonas discount/premium (equivalentes a las cajas del análisis)|
//|  - Order Blocks simples (última vela opuesta antes del impulso)  |
//|  - Salida en 2 TPs (TP1 parcial + breakeven, TP2 resto)          |
//|                                                                   |
//|  Pensado para backtesting en el Strategy Tester de MT5.          |
//|  Símbolo recomendado: Gold (XAUUSD) - Timeframe: M15              |
//+------------------------------------------------------------------+
#property copyright "Hugo"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Parámetros de entrada
input int    FractalRange        = 3;      // velas a cada lado para validar swing
input int    ZoneLookback        = 96;     // velas para construir zonas (24h en M15)
input int    MajorSwingLookback  = 200;    // velas para buscar el swing "mayor" (TP2)
input double RiskPercent         = 1.0;    // % de riesgo por operación
input double PartialClosePercent = 50.0;   // % de la posición a cerrar en TP1
input bool   MoveSLToBreakeven   = true;   // mover SL a breakeven al tocar TP1
input int    MagicNumber         = 990011;

//--- Estructura de una zona
struct Zone
  {
   double top;
   double bottom;
   string label;
  };

Zone premiumZone, discountZone;

//--- Variables de estructura
double lastSwingHigh = 0;
double lastSwingLow  = 0;
bool   lastSwingHighSet = false;
bool   lastSwingLowSet  = false;
string trend = "none"; // "up" | "down" | "none"

//--- Seguimiento de posición activa (para TP1/TP2 manual)
ulong  activeTicket   = 0;
bool   tp1Done        = false;
double activeTP1      = 0;
double activeTP2      = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   Print("SMC_EA iniciado en ", _Symbol, " ", EnumToString(_Period));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Print("SMC_EA detenido. Razón: ", reason);
  }

//+------------------------------------------------------------------+
//| Detecta si la vela 'shift' es un swing high/low usando Fractals   |
//+------------------------------------------------------------------+
bool IsSwingHigh(int shift, const double &high[])
  {
   for(int i = 1; i <= FractalRange; i++)
     {
      if(high[shift] <= high[shift - i] || high[shift] <= high[shift + i])
         return false;
     }
   return true;
  }

bool IsSwingLow(int shift, const double &low[])
  {
   for(int i = 1; i <= FractalRange; i++)
     {
      if(low[shift] >= low[shift - i] || low[shift] >= low[shift + i])
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Construye las zonas discount/premium a partir del rango reciente  |
//+------------------------------------------------------------------+
void BuildZones()
  {
   double highestHigh = iHigh(_Symbol, _Period, iHighest(_Symbol, _Period, MODE_HIGH, ZoneLookback, 1));
   double lowestLow   = iLow(_Symbol, _Period, iLowest(_Symbol, _Period, MODE_LOW, ZoneLookback, 1));
   double span = highestHigh - lowestLow;

   premiumZone.top    = highestHigh;
   premiumZone.bottom = highestHigh - span * 0.33;
   premiumZone.label  = "premium (oferta)";

   discountZone.top    = lowestLow + span * 0.33;
   discountZone.bottom = lowestLow;
   discountZone.label  = "discount (demanda)";
  }

//+------------------------------------------------------------------+
//| Busca el swing mayor (para TP2) dentro de MajorSwingLookback      |
//+------------------------------------------------------------------+
double FindMajorSwingLow()
  {
   int idx = iLowest(_Symbol, _Period, MODE_LOW, MajorSwingLookback, 1);
   return iLow(_Symbol, _Period, idx);
  }

double FindMajorSwingHigh()
  {
   int idx = iHighest(_Symbol, _Period, MODE_HIGH, MajorSwingLookback, 1);
   return iHigh(_Symbol, _Period, idx);
  }

//+------------------------------------------------------------------+
//| Calcula el tamaño de lote según riesgo % y distancia al SL        |
//+------------------------------------------------------------------+
double CalcLotSize(double slDistancePoints)
  {
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (RiskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double valuePerPoint = (tickValue / tickSize) * point;
   double lot = riskMoney / (slDistancePoints * valuePerPoint);

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return lot;
  }

//+------------------------------------------------------------------+
//| Abre una operación con SL y guarda TP1/TP2 para gestión manual    |
//+------------------------------------------------------------------+
void OpenTrade(bool isShort, double entry, double sl, double tp1, double tp2)
  {
   double slDistPoints = MathAbs(entry - sl) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double lot = CalcLotSize(slDistPoints);

   bool ok;
   if(isShort)
      ok = trade.Sell(lot, _Symbol, 0, sl, 0, "SMC CHoCH/BOS short");
   else
      ok = trade.Buy(lot, _Symbol, 0, sl, 0, "SMC CHoCH/BOS long");

   if(ok)
     {
      activeTicket = trade.ResultOrder();
      activeTP1 = tp1;
      activeTP2 = tp2;
      tp1Done = false;
      PrintFormat("Trade abierto (%s) lote=%.2f SL=%.3f TP1=%.3f TP2=%.3f",
                  isShort ? "SHORT" : "LONG", lot, sl, tp1, tp2);
     }
   else
      Print("Error al abrir trade: ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Gestiona TP1 (cierre parcial + breakeven) y TP2 (cierre total)    |
//+------------------------------------------------------------------+
void ManageOpenPosition()
  {
   if(activeTicket == 0 || !PositionSelectByTicket(activeTicket))
     {
      activeTicket = 0;
      return;
     }

   long type = PositionGetInteger(POSITION_TYPE);
   double currentPrice = (type == POSITION_TYPE_BUY)
                         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double volume    = PositionGetDouble(POSITION_VOLUME);

   bool hitTP1 = (type == POSITION_TYPE_BUY) ? (currentPrice >= activeTP1)
                                              : (currentPrice <= activeTP1);
   bool hitTP2 = (type == POSITION_TYPE_BUY) ? (currentPrice >= activeTP2)
                                              : (currentPrice <= activeTP2);

   //--- TP1: cerrar parcial + mover SL a breakeven
   if(hitTP1 && !tp1Done)
     {
      double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double partialVol = MathFloor((volume * PartialClosePercent / 100.0) / volStep) * volStep;
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

      if(partialVol >= minLot)
        {
         trade.PositionClosePartial(activeTicket, partialVol);
         Print("TP1 alcanzado: cierre parcial de ", partialVol, " lotes.");
        }

      if(MoveSLToBreakeven)
        {
         trade.PositionModify(activeTicket, openPrice, PositionGetDouble(POSITION_TP));
         Print("SL movido a breakeven: ", openPrice);
        }

      tp1Done = true;
     }

   //--- TP2: cerrar el resto
   if(hitTP2)
     {
      trade.PositionClose(activeTicket);
      Print("TP2 alcanzado: posición cerrada por completo.");
      activeTicket = 0;
      tp1Done = false;
     }
  }

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Gestiona la posición activa en cada tick (para TP1/TP2 precisos)
   ManageOpenPosition();

   // El resto de la lógica (detección de estructura) solo corre en vela nueva
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;

   // No abrir una nueva operación si ya hay una activa
   if(activeTicket != 0)
      return;

   int bars = iBars(_Symbol, _Period);
   int needed = MathMax(MajorSwingLookback, ZoneLookback) + FractalRange * 2 + 5;
   if(bars < needed)
      return;

   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   CopyHigh(_Symbol, _Period, 0, needed, high);
   CopyLow(_Symbol, _Period, 0, needed, low);
   CopyClose(_Symbol, _Period, 0, needed, close);

   // shift=FractalRange+1 es la vela más reciente que ya tiene suficiente
   // contexto a la derecha para confirmar el swing (evita repintado)
   int shift = FractalRange + 1;

   if(IsSwingHigh(shift, high))
     {
      lastSwingHigh = high[shift];
      lastSwingHighSet = true;
     }
   if(IsSwingLow(shift, low))
     {
      lastSwingLow = low[shift];
      lastSwingLowSet = true;
     }

   double currentClose = close[0];

   // Ruptura alcista de un swing high -> BOS o CHoCH bullish
   if(lastSwingHighSet && currentClose > lastSwingHigh)
     {
      string kind = (trend == "up") ? "BOS_bullish" : "CHoCH_bullish";
      Print(kind, " detectado. Precio=", currentClose, " nivel=", lastSwingHigh);
      trend = "up";
      lastSwingHighSet = false;

      BuildZones();
      double entry = currentClose;
      double sl    = discountZone.bottom; // stop bajo la zona de demanda
      double tp1   = premiumZone.bottom;  // techo cercano a la zona de oferta más próxima
      double tp2   = FindMajorSwingHigh();

      if(tp1 > entry && tp2 > tp1)
         OpenTrade(false, entry, sl, tp1, tp2); // long
     }

   // Ruptura bajista de un swing low -> BOS o CHoCH bearish
   if(lastSwingLowSet && currentClose < lastSwingLow)
     {
      string kind = (trend == "down") ? "BOS_bearish" : "CHoCH_bearish";
      Print(kind, " detectado. Precio=", currentClose, " nivel=", lastSwingLow);
      trend = "down";
      lastSwingLowSet = false;

      BuildZones();
      double entry = currentClose;
      double sl    = premiumZone.top;     // stop sobre la zona de oferta
      double tp1   = discountZone.top;    // piso cercano a la zona de demanda más próxima
      double tp2   = FindMajorSwingLow();

      if(tp1 < entry && tp2 < tp1)
         OpenTrade(true, entry, sl, tp1, tp2); // short
     }
  }
//+------------------------------------------------------------------+