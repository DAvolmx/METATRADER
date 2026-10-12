
//+------------------------------------------------------------------+
//|                  ETHUSD_Hybrid_EA_V1.mq5                         |
//| H4 Regime -> H1 BOS -> M15 Pullback -> ATR Risk Management       |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================================
// INPUTS
//==================================================================

//--- General
input string InpSymbol              = "";       // Empty = current chart
input long   MagicNumber             = 260102;
input bool   AllowLong               = true;
input bool   AllowShort              = true;

//--- Risk
input double RiskPercent             = 0.75;
input double MaxDailyLossPercent     = 2.0;
input int    MaxConsecutiveLosses    = 3;
input int    MaxOpenPositions        = 1;

//--- H4 regime
input int    H4_EMA_Fast             = 50;
input int    H4_EMA_Slow             = 200;
input int    H4_ADX_Period           = 14;
input double H4_ADX_Min              = 20.0;

//--- H1 structure
input int    H1_SwingLookback        = 8;
input int    H1_BreakBufferPoints    = 50;

//--- M15 confirmation
input int    M15_EMA                 = 20;
input int    M15_ATR_Period          = 14;
input double M15_ATR_Min             = 0.0;
input double VolumeMultiplier        = 1.10;

//--- Stop / Take Profit
input double SL_ATR_Multiplier       = 1.50;
input double TP1_R                   = 1.00;
input double TP2_R                   = 2.00;

//--- Position management
input double TP1_ClosePercent        = 40.0;
input bool   MoveToBreakEven         = true;
input double BreakEvenOffsetPoints   = 20;
input bool   UseATRTrailing          = true;
input double TrailATRMultiplier      = 2.0;

//--- Spread
input double MaxSpreadPoints         = 2500;

//--- Execution
input int    DeviationPoints         = 100;

//==================================================================
// GLOBALS
//==================================================================

string SYMBOL;

int hH4EMA50  = INVALID_HANDLE;
int hH4EMA200 = INVALID_HANDLE;
int hH4ADX    = INVALID_HANDLE;
int hM15EMA   = INVALID_HANDLE;
int hM15ATR   = INVALID_HANDLE;

datetime lastM15Bar = 0;

double dayStartEquity = 0.0;
int    currentDay     = -1;

int consecutiveLosses = 0;

//==================================================================
// INIT
//==================================================================

int OnInit()
{
   SYMBOL = InpSymbol;

   if(SYMBOL == "")
      SYMBOL = _Symbol;

   if(!SymbolSelect(SYMBOL,true))
   {
      Print("ERROR: No se pudo seleccionar ",SYMBOL);
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetTypeFillingBySymbol(SYMBOL);

   // H4
   hH4EMA50 = iMA(
      SYMBOL,
      PERIOD_H4,
      H4_EMA_Fast,
      0,
      MODE_EMA,
      PRICE_CLOSE
   );

   hH4EMA200 = iMA(
      SYMBOL,
      PERIOD_H4,
      H4_EMA_Slow,
      0,
      MODE_EMA,
      PRICE_CLOSE
   );

   hH4ADX = iADX(
      SYMBOL,
      PERIOD_H4,
      H4_ADX_Period
   );

   // M15
   hM15EMA = iMA(
      SYMBOL,
      PERIOD_M15,
      M15_EMA,
      0,
      MODE_EMA,
      PRICE_CLOSE
   );

   hM15ATR = iATR(
      SYMBOL,
      PERIOD_M15,
      M15_ATR_Period
   );

   if(
      hH4EMA50 == INVALID_HANDLE ||
      hH4EMA200 == INVALID_HANDLE ||
      hH4ADX == INVALID_HANDLE ||
      hM15EMA == INVALID_HANDLE ||
      hM15ATR == INVALID_HANDLE
   )
   {
      Print("ERROR creando indicadores.");
      return INIT_FAILED;
   }

   ResetDailyStats();

   Print("======================================");
   Print("ETHUSD HYBRID EA V1");
   Print("Symbol: ",SYMBOL);
   Print("Magic: ",MagicNumber);
   Print("Risk: ",RiskPercent,"%");
   Print("======================================");

   return INIT_SUCCEEDED;
}

//==================================================================
// DEINIT
//==================================================================

void OnDeinit(const int reason)
{
   if(hH4EMA50  != INVALID_HANDLE) IndicatorRelease(hH4EMA50);
   if(hH4EMA200 != INVALID_HANDLE) IndicatorRelease(hH4EMA200);
   if(hH4ADX    != INVALID_HANDLE) IndicatorRelease(hH4ADX);
   if(hM15EMA   != INVALID_HANDLE) IndicatorRelease(hM15EMA);
   if(hM15ATR   != INVALID_HANDLE) IndicatorRelease(hM15ATR);
}

//==================================================================
// ON TICK
//==================================================================

void OnTick()
{
   ResetDailyIfNeeded();

   ManagePositions();

   if(!IsNewM15Bar())
      return;

   if(!TradingAllowed())
      return;

   if(CountOpenPositions() >= MaxOpenPositions)
      return;

   if(CurrentSpreadPoints() > MaxSpreadPoints)
      return;

   int regime = GetH4Regime();

   if(regime == 0)
      return;

   if(regime == 1 && AllowLong)
   {
      if(LongSetup())
         OpenTrade(ORDER_TYPE_BUY);
   }

   if(regime == -1 && AllowShort)
   {
      if(ShortSetup())
         OpenTrade(ORDER_TYPE_SELL);
   }
}

//==================================================================
// H4 REGIME
//==================================================================

int GetH4Regime()
{
   double ema50[];
   double ema200[];
   double adx[];

   ArraySetAsSeries(ema50,true);
   ArraySetAsSeries(ema200,true);
   ArraySetAsSeries(adx,true);

   if(
      CopyBuffer(hH4EMA50,0,1,3,ema50) < 3 ||
      CopyBuffer(hH4EMA200,0,1,3,ema200) < 3 ||
      CopyBuffer(hH4ADX,0,1,3,adx) < 3
   )
      return 0;

   double close = iClose(SYMBOL,PERIOD_H4,1);

   bool bullish =
      close > ema200[0] &&
      ema50[0] > ema200[0] &&
      ema50[0] > ema50[1] &&
      adx[0] >= H4_ADX_Min;

   bool bearish =
      close < ema200[0] &&
      ema50[0] < ema200[0] &&
      ema50[0] < ema50[1] &&
      adx[0] >= H4_ADX_Min;

   if(bullish)
      return 1;

   if(bearish)
      return -1;

   return 0;
}

//==================================================================
// LONG SETUP
//==================================================================

bool LongSetup()
{
   // 1. H1 bullish BOS
   if(!BullishBOS())
      return false;

   // 2. M15 confirmation
   if(!M15BullishConfirmation())
      return false;

   return true;
}

//==================================================================
// SHORT SETUP
//==================================================================

bool ShortSetup()
{
   // 1. H1 bearish BOS
   if(!BearishBOS())
      return false;

   // 2. M15 confirmation
   if(!M15BearishConfirmation())
      return false;

   return true;
}

//==================================================================
// H1 BULLISH BOS
//==================================================================

bool BullishBOS()
{
   double previousHigh = GetH1SwingHigh();

   if(previousHigh <= 0)
      return false;

   double close1 = iClose(SYMBOL,PERIOD_H1,1);

   double buffer =
      H1_BreakBufferPoints *
      SymbolInfoDouble(SYMBOL,SYMBOL_POINT);

   return close1 > previousHigh + buffer;
}

//==================================================================
// H1 BEARISH BOS
//==================================================================

bool BearishBOS()
{
   double previousLow = GetH1SwingLow();

   if(previousLow <= 0)
      return false;

   double close1 = iClose(SYMBOL,PERIOD_H1,1);

   double buffer =
      H1_BreakBufferPoints *
      SymbolInfoDouble(SYMBOL,SYMBOL_POINT);

   return close1 < previousLow - buffer;
}

//==================================================================
// SWING HIGH
//==================================================================

double GetH1SwingHigh()
{
   double highest = -DBL_MAX;

   for(int i=2;i<=H1_SwingLookback+1;i++)
   {
      double high = iHigh(SYMBOL,PERIOD_H1,i);

      if(high > highest)
         highest = high;
   }

   if(highest == -DBL_MAX)
      return 0;

   return highest;
}

//==================================================================
// SWING LOW
//==================================================================

double GetH1SwingLow()
{
   double lowest = DBL_MAX;

   for(int i=2;i<=H1_SwingLookback+1;i++)
   {
      double low = iLow(SYMBOL,PERIOD_H1,i);

      if(low < lowest)
         lowest = low;
   }

   if(lowest == DBL_MAX)
      return 0;

   return lowest;
}

//==================================================================
// M15 LONG CONFIRMATION
//==================================================================

bool M15BullishConfirmation()
{
   double ema[];
   double atr[];

   ArraySetAsSeries(ema,true);
   ArraySetAsSeries(atr,true);

   if(
      CopyBuffer(hM15EMA,0,1,3,ema) < 3 ||
      CopyBuffer(hM15ATR,0,1,3,atr) < 3
   )
      return false;

   double close1 = iClose(SYMBOL,PERIOD_M15,1);
   double open1  = iOpen(SYMBOL,PERIOD_M15,1);
   double high1  = iHigh(SYMBOL,PERIOD_M15,1);
   double low1   = iLow(SYMBOL,PERIOD_M15,1);

   // Candle bullish
   bool bullishCandle = close1 > open1;

   // Above EMA
   bool aboveEMA = close1 > ema[0];

   // ATR filter
   double point = SymbolInfoDouble(SYMBOL,SYMBOL_POINT);

   if(M15_ATR_Min > 0)
   {
      if(atr[0] / point < M15_ATR_Min)
         return false;
   }

   // Volume confirmation
   double volume1 = (double)iVolume(SYMBOL,PERIOD_M15,1);

   double avgVolume = 0;

   for(int i=2;i<=21;i++)
      avgVolume += (double)iVolume(SYMBOL,PERIOD_M15,i);

   avgVolume /= 20.0;

   bool volumeOK =
      volume1 >= avgVolume * VolumeMultiplier;

   // Rejection/pullback style candle
   double body = MathAbs(close1-open1);
   double lowerWick =
      MathMin(open1,close1)-low1;

   bool rejection =
      lowerWick >= body * 0.30;

   return
      bullishCandle &&
      aboveEMA &&
      volumeOK &&
      rejection;
}

//==================================================================
// M15 SHORT CONFIRMATION
//==================================================================

bool M15BearishConfirmation()
{
   double ema[];
   double atr[];

   ArraySetAsSeries(ema,true);
   ArraySetAsSeries(atr,true);

   if(
      CopyBuffer(hM15EMA,0,1,3,ema) < 3 ||
      CopyBuffer(hM15ATR,0,1,3,atr) < 3
   )
      return false;

   double close1 = iClose(SYMBOL,PERIOD_M15,1);
   double open1  = iOpen(SYMBOL,PERIOD_M15,1);
   double high1  = iHigh(SYMBOL,PERIOD_M15,1);
   double low1   = iLow(SYMBOL,PERIOD_M15,1);

   bool bearishCandle = close1 < open1;

   bool belowEMA = close1 < ema[0];

   double point = SymbolInfoDouble(SYMBOL,SYMBOL_POINT);

   if(M15_ATR_Min > 0)
   {
      if(atr[0] / point < M15_ATR_Min)
         return false;
   }

   double volume1 = (double)iVolume(SYMBOL,PERIOD_M15,1);

   double avgVolume = 0;

   for(int i=2;i<=21;i++)
      avgVolume += (double)iVolume(SYMBOL,PERIOD_M15,i);

   avgVolume /= 20.0;

   bool volumeOK =
      volume1 >= avgVolume * VolumeMultiplier;

   double body = MathAbs(close1-open1);

   double upperWick =
      high1-MathMax(open1,close1);

   bool rejection =
      upperWick >= body * 0.30;

   return
      bearishCandle &&
      belowEMA &&
      volumeOK &&
      rejection;
}

//==================================================================
// OPEN TRADE
//==================================================================

void OpenTrade(ENUM_ORDER_TYPE type)
{
   double atr = GetATR();

   if(atr <= 0)
      return;

   double price;

   if(type == ORDER_TYPE_BUY)
      price = SymbolInfoDouble(SYMBOL,SYMBOL_ASK);
   else
      price = SymbolInfoDouble(SYMBOL,SYMBOL_BID);

   double slDistance = atr * SL_ATR_Multiplier;

   double sl;

   if(type == ORDER_TYPE_BUY)
      sl = price - slDistance;
   else
      sl = price + slDistance;

   sl = NormalizePrice(sl);

   double riskMoney =
      AccountInfoDouble(ACCOUNT_EQUITY)
      * RiskPercent
      / 100.0;

   double volume =
      CalculateVolume(
         riskMoney,
         slDistance
      );

   if(volume <= 0)
   {
      Print("Volumen calculado inválido.");
      return;
   }

   string comment;

   if(type == ORDER_TYPE_BUY)
      comment = "ETH-HYBRID-BUY";
   else
      comment = "ETH-HYBRID-SELL";

   bool result=false;

   if(type == ORDER_TYPE_BUY)
   {
      result =
         trade.Buy(
            volume,
            SYMBOL,
            price,
            sl,
            0,
            comment
         );
   }
   else
   {
      result =
         trade.Sell(
            volume,
            SYMBOL,
            price,
            sl,
            0,
            comment
         );
   }

   if(result)
   {
      Print(
         "TRADE OPENED | ",
         comment,
         " | Volume=",volume,
         " | Entry=",price,
         " | SL=",sl
      );
   }
   else
   {
      Print(
         "ERROR TRADE: ",
         trade.ResultRetcode(),
         " ",
         trade.ResultRetcodeDescription()
      );
   }
}

//==================================================================
// ATR
//==================================================================

double GetATR()
{
   double atr[];

   ArraySetAsSeries(atr,true);

   if(CopyBuffer(hM15ATR,0,1,2,atr) < 2)
      return 0;

   return atr[0];
}

//==================================================================
// VOLUME CALCULATION
//==================================================================

double CalculateVolume(
   double riskMoney,
   double slDistance
)
{
   double tickSize =
      SymbolInfoDouble(
         SYMBOL,
         SYMBOL_TRADE_TICK_SIZE
      );

   double tickValue =
      SymbolInfoDouble(
         SYMBOL,
         SYMBOL_TRADE_TICK_VALUE
      );

   if(
      tickSize <= 0 ||
      tickValue <= 0 ||
      slDistance <= 0
   )
      return 0;

   double lossPerLot =
      (slDistance / tickSize)
      * tickValue;

   if(lossPerLot <= 0)
      return 0;

   double volume =
      riskMoney /
      lossPerLot;

   double minLot =
      SymbolInfoDouble(
         SYMBOL,
         SYMBOL_VOLUME_MIN
      );

   double maxLot =
      SymbolInfoDouble(
         SYMBOL,
         SYMBOL_VOLUME_MAX
      );

   double step =
      SymbolInfoDouble(
         SYMBOL,
         SYMBOL_VOLUME_STEP
      );

   volume =
      MathFloor(volume/step)*step;

   volume =
      MathMax(volume,minLot);

   volume =
      MathMin(volume,maxLot);

   return NormalizeVolume(volume);
}

//==================================================================
// POSITION MANAGEMENT
//==================================================================

void ManagePositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol =
         PositionGetString(POSITION_SYMBOL);

      long magic =
         PositionGetInteger(POSITION_MAGIC);

      if(symbol != SYMBOL || magic != MagicNumber)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)
         PositionGetInteger(POSITION_TYPE);

      double openPrice =
         PositionGetDouble(POSITION_PRICE_OPEN);

      double sl =
         PositionGetDouble(POSITION_SL);

      double volume =
         PositionGetDouble(POSITION_VOLUME);

      double currentPrice;

      if(type == POSITION_TYPE_BUY)
         currentPrice =
            SymbolInfoDouble(
               SYMBOL,
               SYMBOL_BID
            );
      else
         currentPrice =
            SymbolInfoDouble(
               SYMBOL,
               SYMBOL_ASK
            );

      double riskDistance =
         MathAbs(openPrice-sl);

      if(riskDistance <= 0)
         continue;

      double profitDistance;

      if(type == POSITION_TYPE_BUY)
         profitDistance =
            currentPrice-openPrice;
      else
         profitDistance =
            openPrice-currentPrice;

      double R =
         profitDistance /
         riskDistance;

      //============================================================
      // TP1
      //============================================================

      if(R >= TP1_R)
      {
         PartialClose(ticket,volume);

         if(MoveToBreakEven)
         {
            MoveToBreakEvenPosition(
               ticket,
               type,
               openPrice
            );
         }
      }

      //============================================================
      // ATR TRAILING
      //============================================================

      if(
         UseATRTrailing &&
         R >= TP2_R
      )
      {
         TrailPosition(
            ticket,
            type,
            currentPrice
         );
      }
   }
}

//==================================================================
// PARTIAL CLOSE
//==================================================================

void PartialClose(
   ulong ticket,
   double volume
)
{
   static ulong processedTickets[];

   for(int i=0;i<ArraySize(processedTickets);i++)
   {
      if(processedTickets[i] == ticket)
         return;
   }

   double closeVolume =
      volume *
      TP1_ClosePercent /
      100.0;

   double minLot =
      SymbolInfoDouble(
         SYMBOL,
         SYMBOL_VOLUME_MIN
      );

   if(closeVolume < minLot)
      return;

   closeVolume =
      NormalizeVolume(closeVolume);

   if(closeVolume >= volume)
      return;

   if(trade.PositionClosePartial(
      ticket,
      closeVolume
   ))
   {
      int size =
         ArraySize(processedTickets);

      ArrayResize(
         processedTickets,
         size+1
      );

      processedTickets[size]=ticket;

      Print(
         "TP1 partial close: ",
         closeVolume
      );
   }
}

//==================================================================
// BREAK EVEN
//==================================================================

void MoveToBreakEvenPosition(
   ulong ticket,
   ENUM_POSITION_TYPE type,
   double openPrice
)
{
   if(!PositionSelectByTicket(ticket))
      return;

   double point =
      SymbolInfoDouble(
         SYMBOL,
         SYMBOL_POINT
      );

   double newSL;

   if(type == POSITION_TYPE_BUY)
      newSL =
         openPrice +
         BreakEvenOffsetPoints*point;
   else
      newSL =
         openPrice -
         BreakEvenOffsetPoints*point;

   newSL = NormalizePrice(newSL);

   double currentSL =
      PositionGetDouble(POSITION_SL);

   bool improve=false;

   if(type == POSITION_TYPE_BUY)
      improve =
         currentSL < newSL;
   else
      improve =
         currentSL == 0 ||
         currentSL > newSL;

   if(!improve)
      return;

   trade.PositionModify(
      ticket,
      newSL,
      PositionGetDouble(POSITION_TP)
   );
}

//==================================================================
// ATR TRAILING
//==================================================================

void TrailPosition(
   ulong ticket,
   ENUM_POSITION_TYPE type,
   double currentPrice
)
{
   if(!PositionSelectByTicket(ticket))
      return;

   double atr = GetATR();

   if(atr <= 0)
      return;

   double distance =
      atr *
      TrailATRMultiplier;

   double newSL;

   if(type == POSITION_TYPE_BUY)
      newSL =
         currentPrice-distance;
   else
      newSL =
         currentPrice+distance;

   newSL =
      NormalizePrice(newSL);

   double currentSL =
      PositionGetDouble(POSITION_SL);

   bool improve=false;

   if(type == POSITION_TYPE_BUY)
      improve =
         newSL > currentSL;
   else
      improve =
         currentSL == 0 ||
         newSL < currentSL;

   if(!improve)
      return;

   trade.PositionModify(
      ticket,
      newSL,
      PositionGetDouble(POSITION_TP)
   );
}

//==================================================================
// OPEN POSITIONS COUNT
//==================================================================

int CountOpenPositions()
{
   int count=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket==0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(
         PositionGetString(POSITION_SYMBOL)
         == SYMBOL &&
         PositionGetInteger(POSITION_MAGIC)
         == MagicNumber
      )
      {
         count++;
      }
   }

   return count;
}

//==================================================================
// SPREAD
//==================================================================

double CurrentSpreadPoints()
{
   double ask =
      SymbolInfoDouble(
         SYMBOL,
         SYMBOL_ASK
      );

   double bid =
      SymbolInfoDouble(
         SYMBOL,
         SYMBOL_BID
      );

   double point =
      SymbolInfoDouble(
         SYMBOL,
         SYMBOL_POINT
      );

   if(point<=0)
      return 999999;

   return (ask-bid)/point;
}

//==================================================================
// NEW M15 BAR
//==================================================================

bool IsNewM15Bar()
{
   datetime currentBar =
      iTime(
         SYMBOL,
         PERIOD_M15,
         0
      );

   if(currentBar != lastM15Bar)
   {
      lastM15Bar=currentBar;
      return true;
   }

   return false;
}

//==================================================================
// TRADING PERMISSION
//==================================================================

bool TradingAllowed()
{
   if(consecutiveLosses >= MaxConsecutiveLosses)
      return false;

   double equity =
      AccountInfoDouble(
         ACCOUNT_EQUITY
      );

   double lossPercent =
      (dayStartEquity-equity)
      / dayStartEquity
      * 100.0;

   if(lossPercent >= MaxDailyLossPercent)
   {
      Print(
         "Daily loss limit reached: ",
         lossPercent,"%"
      );

      return false;
   }

   return true;
}

//==================================================================
// DAILY RESET
//==================================================================

void ResetDailyStats()
{
   MqlDateTime dt;

   TimeToStruct(
      TimeCurrent(),
      dt
   );

   currentDay=dt.day;

   dayStartEquity =
      AccountInfoDouble(
         ACCOUNT_EQUITY
      );
}

//==================================================================

void ResetDailyIfNeeded()
{
   MqlDateTime dt;

   TimeToStruct(
      TimeCurrent(),
      dt
   );

   if(dt.day != currentDay)
      ResetDailyStats();
}

//==================================================================
// TRANSACTION EVENT
//==================================================================

void OnTradeTransaction(
   const MqlTradeTransaction &trans,
   const MqlTradeRequest &request,
   const MqlTradeResult &result
)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal=trans.deal;

   if(deal==0)
      return;

   if(!HistoryDealSelect(deal))
      return;

   long magic =
      HistoryDealGetInteger(
         deal,
         DEAL_MAGIC
      );

   if(magic != MagicNumber)
      return;

   long entry =
      HistoryDealGetInteger(
         deal,
         DEAL_ENTRY
      );

   if(entry != DEAL_ENTRY_OUT)
      return;

   double profit =
      HistoryDealGetDouble(
         deal,
         DEAL_PROFIT
      );

   if(profit < 0)
      consecutiveLosses++;
   else if(profit > 0)
      consecutiveLosses=0;
}

//==================================================================
// NORMALIZE PRICE
//==================================================================

double NormalizePrice(double price)
{
   int digits =
      (int)SymbolInfoInteger(
         SYMBOL,
         SYMBOL_DIGITS
      );

   return NormalizeDouble(
      price,
      digits
   );
}

//==================================================================
// NORMALIZE VOLUME
//==================================================================

double NormalizeVolume(double volume)
{
   double step =
      SymbolInfoDouble(
         SYMBOL,
         SYMBOL_VOLUME_STEP
      );

   if(step<=0)
      return volume;

   int digits=0;

   double temp=step;

   while(temp<1.0 && digits<8)
   {
      temp*=10.0;
      digits++;
   }

   return NormalizeDouble(
      volume,
      digits
   );
}
//+------------------------------------------------------------------+

