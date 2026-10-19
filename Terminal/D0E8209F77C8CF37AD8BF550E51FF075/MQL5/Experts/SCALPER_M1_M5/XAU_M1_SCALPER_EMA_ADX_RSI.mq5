//+------------------------------------------------------------------+
//|                 XAU_M1_SCALPER_V1.mq5                            |
//|          Scalping XAUUSD M1 - EMA/ADX/RSI/ATR                    |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>
#include <GoldMaster\GoldMaster_LotGuard.mqh>

//--- Guarda de lote (GoldMaster_LotGuard.mqh) -----------------------
// El suelo de lote minimo del broker puede forzar MUCHO mas riesgo del
// planeado sin avisar. Estos dos limites hacen que el EA prefiera NO
// operar antes que operar con un riesgo que no eligio el usuario.
input double InpLG_MaxRiskPct    = 5.0;  // Guarda: riesgo max. por operacion (% equity, 0=off)
input double InpLG_MaxOverTarget = 2.0;  // Guarda: multiplo max. del riesgo objetivo (0=off)

CTrade trade;

//======================= INPUTS =====================================
input group "=== RIESGO ==="
input double RiskPercent       = 0.50;   // Riesgo % por operación
input double MaxLot            = 0.10;
input double MinLotManual      = 0.01;
input int    MaxSpreadPoints   = 80;
input int    SlippagePoints    = 30;

input group "=== TENDENCIA ==="
input int FastEMA              = 9;
input int SlowEMA              = 21;
input int TrendEMA             = 100;

input group "=== FILTROS ==="
input int    RSIPeriod         = 14;
input double RSI_Buy_Min       = 52.0;
input double RSI_Buy_Max       = 72.0;
input double RSI_Sell_Min      = 28.0;
input double RSI_Sell_Max      = 48.0;

input int    ADXPeriod         = 14;
input double MinADX            = 20.0;

input group "=== SL / TP ==="
input int    ATRPeriod         = 14;
input double SL_ATR            = 1.50;
input double TP_ATR            = 2.00;

input group "=== GESTION ==="
input bool   UseBreakEven      = true;
input double BreakEvenATR      = 0.80;
input bool   UseTrailing       = true;
input double TrailStartATR     = 1.00;
input double TrailATR          = 0.70;

input group "=== CONTROL ==="
input ulong  MagicNumber       = 26061001;
input bool   OnlyNewCandle     = true;

//======================= HANDLES ====================================
int hFastEMA;
int hSlowEMA;
int hTrendEMA;
int hRSI;
int hADX;
int hATR;

datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Period != PERIOD_M1)
      Print("ADVERTENCIA: Este EA fue diseñado para M1.");

   hFastEMA  = iMA(_Symbol, PERIOD_M1, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA  = iMA(_Symbol, PERIOD_M1, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hTrendEMA = iMA(_Symbol, PERIOD_M1, TrendEMA,0, MODE_EMA, PRICE_CLOSE);

   hRSI = iRSI(_Symbol, PERIOD_M1, RSIPeriod, PRICE_CLOSE);
   hADX = iADX(_Symbol, PERIOD_M1, ADXPeriod);
   hATR = iATR(_Symbol, PERIOD_M1, ATRPeriod);

   if(hFastEMA  == INVALID_HANDLE ||
      hSlowEMA  == INVALID_HANDLE ||
      hTrendEMA == INVALID_HANDLE ||
      hRSI      == INVALID_HANDLE ||
      hADX      == INVALID_HANDLE ||
      hATR      == INVALID_HANDLE)
   {
      Print("ERROR creando indicadores.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   Print("XAU M1 Scalper iniciado correctamente.");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DEINIT                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hFastEMA);
   IndicatorRelease(hSlowEMA);
   IndicatorRelease(hTrendEMA);
   IndicatorRelease(hRSI);
   IndicatorRelease(hADX);
   IndicatorRelease(hATR);
}

//+------------------------------------------------------------------+
//| Obtener valor indicador                                          |
//+------------------------------------------------------------------+
double GetValue(int handle,int buffer,int shift)
{
   double data[];

   ArraySetAsSeries(data,true);

   if(CopyBuffer(handle,buffer,shift,1,data) <= 0)
      return EMPTY_VALUE;

   return data[0];
}

//+------------------------------------------------------------------+
//| Nueva vela                                                       |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime time = iTime(_Symbol,PERIOD_M1,0);

   if(time != lastBarTime)
   {
      lastBarTime = time;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Spread                                                           |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);

   if(ask <= 0 || bid <= 0)
      return false;

   double spread = (ask-bid)/_Point;

   return (spread <= MaxSpreadPoints);
}

//+------------------------------------------------------------------+
//| ¿Existe posición de este EA?                                     |
//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Normalizar lotaje                                                |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLotSymbol = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(minLot < MinLotManual)
      minLot = MinLotManual;

   double maxAllowed = MathMin(MaxLot,maxLotSymbol);

   lot = MathMax(lot,minLot);
   lot = MathMin(lot,maxAllowed);

   if(step > 0)
      lot = MathFloor(lot/step)*step;

   return NormalizeDouble(lot,2);
}

//+------------------------------------------------------------------+
//| Lotaje según riesgo                                              |
//+------------------------------------------------------------------+
double CalculateLot(double entry,double stop)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   double riskMoney = balance * RiskPercent / 100.0;

   double distance = MathAbs(entry-stop);

   if(distance <= 0)
      return 0.0;   // fallo de datos: NO operar (antes devolvia un lote operable)

   double tickSize =
      SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);

   double tickValue =
      SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0 || tickValue <= 0)
      return 0.0;   // fallo de datos: NO operar (antes devolvia un lote operable)

   double moneyPerLot =
      (distance/tickSize)*tickValue;

   if(moneyPerLot <= 0)
      return 0.0;   // fallo de datos: NO operar (antes devolvia un lote operable)

   // La guarda decide el lote y bloquea (devuelve 0) si el lote minimo
   // forzaria mas riesgo del planeado. NormalizeLot solo redondea.
   // MinLotManual se le pasa a la guarda: este EA puede imponer un minimo
   // MAYOR que el del broker, y NormalizeLot lo aplicaria despues. Sin
   // decirselo, la guarda aprobaria un lote que luego se subiria por encima
   // del techo de riesgo.
   double lot = GMLotGuard(distance, riskMoney,
                           InpLG_MaxRiskPct, InpLG_MaxOverTarget,
                           "XAU_M1_SCALPER", false, "", MinLotManual);
   if(lot <= 0.0) return 0.0;

   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Stops mínimos broker                                             |
//+------------------------------------------------------------------+
double MinimumStopDistance()
{
   long stops =
      SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);

   return stops*_Point;
}

//+------------------------------------------------------------------+
//| BUY                                                              |
//+------------------------------------------------------------------+
void OpenBuy(double atr)
{
   double ask =
      SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   double minStop = MinimumStopDistance();

   double slDistance =
      MathMax(atr*SL_ATR,minStop);

   double tpDistance =
      MathMax(atr*TP_ATR,minStop);

   double sl =
      NormalizeDouble(ask-slDistance,_Digits);

   double tp =
      NormalizeDouble(ask+tpDistance,_Digits);

   double lot =
      CalculateLot(ask,sl);

   if(lot <= 0)
      return;

   if(!trade.Buy(
      lot,
      _Symbol,
      0,
      sl,
      tp,
      "XAU M1 BUY"))
   {
      Print("BUY ERROR: ",
            trade.ResultRetcode(),
            " ",
            trade.ResultRetcodeDescription());
   }
   else
   {
      Print("BUY abierta | Lot: ",
            lot,
            " SL: ",
            sl,
            " TP: ",
            tp);
   }
}

//+------------------------------------------------------------------+
//| SELL                                                             |
//+------------------------------------------------------------------+
void OpenSell(double atr)
{
   double bid =
      SymbolInfoDouble(_Symbol,SYMBOL_BID);

   double minStop = MinimumStopDistance();

   double slDistance =
      MathMax(atr*SL_ATR,minStop);

   double tpDistance =
      MathMax(atr*TP_ATR,minStop);

   double sl =
      NormalizeDouble(bid+slDistance,_Digits);

   double tp =
      NormalizeDouble(bid-tpDistance,_Digits);

   double lot =
      CalculateLot(bid,sl);

   if(lot <= 0)
      return;

   if(!trade.Sell(
      lot,
      _Symbol,
      0,
      sl,
      tp,
      "XAU M1 SELL"))
   {
      Print("SELL ERROR: ",
            trade.ResultRetcode(),
            " ",
            trade.ResultRetcodeDescription());
   }
   else
   {
      Print("SELL abierta | Lot: ",
            lot,
            " SL: ",
            sl,
            " TP: ",
            tp);
   }
}

//+------------------------------------------------------------------+
//| Gestionar posición                                               |
//+------------------------------------------------------------------+
void ManagePosition()
{
   double atr = GetValue(hATR,0,0);

   if(atr == EMPTY_VALUE || atr <= 0)
      return;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC)
         != MagicNumber)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)
         PositionGetInteger(POSITION_TYPE);

      double open =
         PositionGetDouble(POSITION_PRICE_OPEN);

      double sl =
         PositionGetDouble(POSITION_SL);

      double tp =
         PositionGetDouble(POSITION_TP);

      double bid =
         SymbolInfoDouble(_Symbol,SYMBOL_BID);

      double ask =
         SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      double newSL = sl;

      //==============================================================
      // BUY
      //==============================================================

      if(type == POSITION_TYPE_BUY)
      {
         double profitDistance = bid-open;

         // Break Even
         if(UseBreakEven &&
            profitDistance >= atr*BreakEvenATR)
         {
            if(sl < open)
               newSL = open;
         }

         // Trailing
         if(UseTrailing &&
            profitDistance >= atr*TrailStartATR)
         {
            double trail =
               bid-(atr*TrailATR);

            if(trail > newSL &&
               trail > open)
            {
               newSL = trail;
            }
         }

         newSL =
            NormalizeDouble(newSL,_Digits);

         if(newSL > sl &&
            newSL < bid)
         {
            trade.PositionModify(
               ticket,
               newSL,
               tp);
         }
      }

      //==============================================================
      // SELL
      //==============================================================

      if(type == POSITION_TYPE_SELL)
      {
         double profitDistance = open-ask;

         // Break Even
         if(UseBreakEven &&
            profitDistance >= atr*BreakEvenATR)
         {
            if(sl > open || sl == 0)
               newSL = open;
         }

         // Trailing
         if(UseTrailing &&
            profitDistance >= atr*TrailStartATR)
         {
            double trail =
               ask+(atr*TrailATR);

            if((trail < newSL || newSL == 0) &&
               trail < open)
            {
               newSL = trail;
            }
         }

         newSL =
            NormalizeDouble(newSL,_Digits);

         if((newSL < sl || sl == 0) &&
            newSL > ask)
         {
            trade.PositionModify(
               ticket,
               newSL,
               tp);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Buscar entrada                                                   |
//+------------------------------------------------------------------+
void CheckEntry()
{
   if(HasPosition())
      return;

   if(!SpreadOK())
      return;

   // Trabajamos con vela cerrada
   int s = 1;

   double fast =
      GetValue(hFastEMA,0,s);

   double slow =
      GetValue(hSlowEMA,0,s);

   double trend =
      GetValue(hTrendEMA,0,s);

   double rsi =
      GetValue(hRSI,0,s);

   double adx =
      GetValue(hADX,0,s);

   double plusDI =
      GetValue(hADX,1,s);

   double minusDI =
      GetValue(hADX,2,s);

   double atr =
      GetValue(hATR,0,s);

   if(fast == EMPTY_VALUE ||
      slow == EMPTY_VALUE ||
      trend == EMPTY_VALUE ||
      rsi == EMPTY_VALUE ||
      adx == EMPTY_VALUE ||
      atr == EMPTY_VALUE)
      return;

   double close =
      iClose(_Symbol,PERIOD_M1,s);

   double open =
      iOpen(_Symbol,PERIOD_M1,s);

   //==============================================================
   // COMPRA
   //==============================================================

   bool buyTrend =
      fast > slow &&
      slow > trend &&
      close > trend;

   bool buyMomentum =
      rsi >= RSI_Buy_Min &&
      rsi <= RSI_Buy_Max &&
      adx >= MinADX &&
      plusDI > minusDI;

   bool bullishCandle =
      close > open;

   if(buyTrend &&
      buyMomentum &&
      bullishCandle)
   {
      OpenBuy(atr);
      return;
   }

   //==============================================================
   // VENTA
   //==============================================================

   bool sellTrend =
      fast < slow &&
      slow < trend &&
      close < trend;

   bool sellMomentum =
      rsi >= RSI_Sell_Min &&
      rsi <= RSI_Sell_Max &&
      adx >= MinADX &&
      minusDI > plusDI;

   bool bearishCandle =
      close < open;

   if(sellTrend &&
      sellMomentum &&
      bearishCandle)
   {
      OpenSell(atr);
      return;
   }
}

//+------------------------------------------------------------------+
//| TICK                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Gestión en cada tick
   ManagePosition();

   if(OnlyNewCandle)
   {
      if(!IsNewBar())
         return;
   }

   CheckEntry();
}
//+------------------------------------------------------------------+