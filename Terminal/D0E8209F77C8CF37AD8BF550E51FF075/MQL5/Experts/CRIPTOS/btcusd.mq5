//+------------------------------------------------------------------+
//|           Deriv_BTC_ETH_v17_SMART.mq5                            |
//|    BTC + ETH - Detección de Régimen + Confluencia Múltiple       |
//+------------------------------------------------------------------+
#property copyright "Venice AI"
#property version   "17.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//=== SÍMBOLOS ===
input group "=== SIMBOLOS ==="
input string InpBTC_Name      = "BTCUSD";
input string InpETH_Name      = "ETHUSD";
input bool   InpUseBTC        = true;
input bool   InpUseETH        = true;

//=== LOTE ===
input group "=== LOTE ==="
input double InpBTC_Lot       = 0.01;
input double InpETH_Lot       = 0.10;

//=== DETECCIÓN DE RÉGIMEN ===
input group "=== DETECTOR DE REGIMEN ==="
input int    InpRegimeBars    = 150;     // Velas para analizar régimen
input double InpTrendThreshold= 0.5;    // % de eficiencia para tendencia
input double InpVolHighPct    = 1.5;    // Volatilidad alta (x media)
input double InpVolLowPct     = 0.6;    // Volatilidad baja (x media)

//=== INDICADORES PRINCIPALES ===
input group "=== INDICADORES ==="
input int    InpEMA_Fast      = 15;
input int    InpEMA_Slow      = 40;
input int    InpEMA_Trend     = 150;
input int    InpADX_Period    = 14;
input int    InpRSI_Period    = 14;
input int    InpStoch_K       = 5;
input int    InpStoch_D       = 3;
input int    InpBB_Period     = 20;
input double InpBB_Dev        = 2.0;

//=== SISTEMA DE PUNTUACIÓN ===
input group "=== SISTEMA DE PUNTUACION ==="
input int    InpMinScore      = 7;      // Score mínimo para entrar (máx 10)

//=== ENTRADAS ===
input group "=== ENTRADAS ==="
input int    InpMaxEntries    = 5;
input int    InpMaxPosPerSym  = 5;
input double InpEntryStepATR  = 0.6;
input double InpSL_ATR        = 1.5;
input double InpTP_ATR        = 5.0;
input double InpTrailStartATR = 2.0;
input double InpTrailDistATR  = 0.8;

//=== FILTROS ===
input group "=== FILTROS ==="
input bool   InpUseSession    = true;
input int    InpSessionStart  = 10;
input int    InpSessionEnd    = 23;
input bool   InpAllowAsian    = true;
input double InpMinATRPct     = 0.02;
input bool   InpTradeOnTrend  = true;   // Solo tendencias fuertes
input bool   InpTradeOnRange  = false;  // También rangos (mean reversion)

//=== DIAGNÓSTICO ===
input group "=== DIAGNOSTICO ==="
input bool   InpDebug         = true;
input ulong  InpMagic         = 20241115;

//=== ENUMS ===
enum ENUM_REGIME
{
   REGIME_NONE = 0,
   REGIME_TREND_UP = 1,
   REGIME_TREND_DN = -1,
   REGIME_RANGE = 2,
   REGIME_VOLATILE = 3
};

//=== ESTRUCTURA ===
struct SSymCtx
{
   string   name;
   double   point;
   int      digits;
   double   tickValue;
   double   tickSize;
   double   stopsLevel;
   double   minLot;
   double   maxLot;
   double   stepLot;
   double   fixedLot;
   int      hEMA_F;
   int      hEMA_S;
   int      hEMA_T;
   int      hATR;
   int      hADX;
   int      hRSI;
   int      hStoch;
   int      hBB;
   int      hMom;      // Momentum
   datetime lastBar;
   int      entriesInTrend;
   int      currentDir;
   double   lastEntryPrice;
   ENUM_REGIME currentRegime;
   double   atrAvg;
   int      regimeBars;
};

SSymCtx  g_sym[2];
int      g_numSym = 0;
datetime g_lastDay = 0;
datetime g_lastDiag = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpUseBTC && SymbolSelect(InpBTC_Name, true))
   {
      InitSym(g_sym[g_numSym], InpBTC_Name, InpBTC_Lot);
      g_numSym++;
   }
   if(InpUseETH && SymbolSelect(InpETH_Name, true))
   {
      InitSym(g_sym[g_numSym], InpETH_Name, InpETH_Lot);
      g_numSym++;
   }
   
   if(g_numSym == 0) { Print("!! Sin símbolos"); return INIT_FAILED; }
   
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(100);
   trade.SetTypeFillingBySymbol(_Symbol);
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_lastDay = dt.day;
   
   Print("═══════════════════════════════════════════");
   Print("   BTC + ETH v17 SMART DETECTOR");
   Print("═══════════════════════════════════════════");
   Print("Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("Score mínimo: ", InpMinScore, "/10");
   Print("Detector de régimen: ", InpRegimeBars, " velas");
   Print("Trade trend: ", InpTradeOnTrend ? "SÍ" : "NO");
   Print("Trade range: ", InpTradeOnRange ? "SÍ" : "NO");
   Print("───────────────────────────────────────────");
   
   for(int i = 0; i < g_numSym; i++)
   {
      Print(g_sym[i].name, " | MinLot: ", g_sym[i].minLot,
            " | Lote: ", g_sym[i].fixedLot,
            " | StopsLevel: ", DoubleToString(g_sym[i].stopsLevel, g_sym[i].digits));
   }
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void InitSym(SSymCtx &s, string name, double lot)
{
   s.name = name;
   s.point = SymbolInfoDouble(name, SYMBOL_POINT);
   s.digits = (int)SymbolInfoInteger(name, SYMBOL_DIGITS);
   s.tickValue = SymbolInfoDouble(name, SYMBOL_TRADE_TICK_VALUE);
   s.tickSize = SymbolInfoDouble(name, SYMBOL_TRADE_TICK_SIZE);
   s.stopsLevel = (double)SymbolInfoInteger(name, SYMBOL_TRADE_STOPS_LEVEL) * s.point;
   s.minLot = SymbolInfoDouble(name, SYMBOL_VOLUME_MIN);
   s.maxLot = SymbolInfoDouble(name, SYMBOL_VOLUME_MAX);
   s.stepLot = SymbolInfoDouble(name, SYMBOL_VOLUME_STEP);
   s.fixedLot = lot;
   
   if(s.fixedLot < s.minLot) s.fixedLot = s.minLot;
   if(s.fixedLot > s.maxLot) s.fixedLot = s.maxLot;
   
   s.hEMA_F = iMA(name, PERIOD_M5, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   s.hEMA_S = iMA(name, PERIOD_M5, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   s.hEMA_T = iMA(name, PERIOD_M5, InpEMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
   s.hATR   = iATR(name, PERIOD_M5, 14);
   s.hADX   = iADX(name, PERIOD_M5, InpADX_Period);
   s.hRSI   = iRSI(name, PERIOD_M5, InpRSI_Period, PRICE_CLOSE);
   s.hStoch = iStochastic(name, PERIOD_M5, InpStoch_K, InpStoch_D, 3, MODE_SMA, STO_LOWHIGH);
   s.hBB    = iBands(name, PERIOD_M5, InpBB_Period, 0, InpBB_Dev, PRICE_CLOSE);
   s.hMom   = iMomentum(name, PERIOD_M5, 14, PRICE_CLOSE);
   
   s.lastBar = 0;
   s.entriesInTrend = 0;
   s.currentDir = 0;
   s.lastEntryPrice = 0;
   s.currentRegime = REGIME_NONE;
   s.atrAvg = 0;
   s.regimeBars = 0;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < g_numSym; i++)
   {
      if(g_sym[i].hEMA_F != INVALID_HANDLE) IndicatorRelease(g_sym[i].hEMA_F);
      if(g_sym[i].hEMA_S != INVALID_HANDLE) IndicatorRelease(g_sym[i].hEMA_S);
      if(g_sym[i].hEMA_T != INVALID_HANDLE) IndicatorRelease(g_sym[i].hEMA_T);
      if(g_sym[i].hATR != INVALID_HANDLE)   IndicatorRelease(g_sym[i].hATR);
      if(g_sym[i].hADX != INVALID_HANDLE)   IndicatorRelease(g_sym[i].hADX);
      if(g_sym[i].hRSI != INVALID_HANDLE)   IndicatorRelease(g_sym[i].hRSI);
      if(g_sym[i].hStoch != INVALID_HANDLE) IndicatorRelease(g_sym[i].hStoch);
      if(g_sym[i].hBB != INVALID_HANDLE)    IndicatorRelease(g_sym[i].hBB);
      if(g_sym[i].hMom != INVALID_HANDLE)   IndicatorRelease(g_sym[i].hMom);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day != g_lastDay)
   {
      g_lastDay = dt.day;
      Print(">>> Nuevo día");
   }
   
   ManageAll();
   
   for(int i = 0; i < g_numSym; i++)
      ProcessSym(i);
}

//+------------------------------------------------------------------+
//| DETECCIÓN DE RÉGIMEN DE MERCADO                                 |
//+------------------------------------------------------------------+
ENUM_REGIME DetectRegime(SSymCtx &s)
{
   // Cargar datos
   double atr[], adx[], highArr[], lowArr[], closeArr[], emaF[], emaS[];
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(highArr, true);
   ArraySetAsSeries(lowArr, true);
   ArraySetAsSeries(closeArr, true);
   ArraySetAsSeries(emaF, true);
   ArraySetAsSeries(emaS, true);
   
   if(CopyBuffer(s.hATR, 0, 0, InpRegimeBars + 10, atr) < InpRegimeBars + 10) return REGIME_NONE;
   if(CopyBuffer(s.hADX, 0, 0, 5, adx) < 5) return REGIME_NONE;
   if(CopyBuffer(s.hEMA_F, 0, 0, 5, emaF) < 5) return REGIME_NONE;
   if(CopyBuffer(s.hEMA_S, 0, 0, 5, emaS) < 5) return REGIME_NONE;
   if(CopyHigh(s.name, PERIOD_M5, 0, InpRegimeBars, highArr) < InpRegimeBars) return REGIME_NONE;
   if(CopyLow(s.name, PERIOD_M5, 0, InpRegimeBars, lowArr) < InpRegimeBars) return REGIME_NONE;
   if(CopyClose(s.name, PERIOD_M5, 0, InpRegimeBars, closeArr) < InpRegimeBars) return REGIME_NONE;
   
   // Calcular rango total del período
   double highest = highArr[0];
   double lowest = lowArr[0];
   for(int i = 0; i < InpRegimeBars; i++)
   {
      if(highArr[i] > highest) highest = highArr[i];
      if(lowArr[i] < lowest) lowest = lowArr[i];
   }
   
   double totalRange = highest - lowest;
   if(totalRange <= 0) return REGIME_NONE;
   
   // Eficiencia direccional: |net move| / rango total
   double netMove = closeArr[0] - closeArr[InpRegimeBars - 1];
   double efficiency = MathAbs(netMove) / totalRange;
   
   // Volatilidad media
   double atrAvg = 0;
   for(int i = 0; i < InpRegimeBars; i++) atrAvg += atr[i];
   atrAvg /= InpRegimeBars;
   s.atrAvg = atrAvg;
   
   double currentATR = atr[0];
   double volRatio = currentATR / atrAvg;
   
   // Volatilidad extrema: no operar
   if(volRatio > 2.0) return REGIME_VOLATILE;
   
   // Tendencia fuerte: alta eficiencia + ADX alto
   if(efficiency > InpTrendThreshold && adx[0] > 20)
   {
      if(netMove > 0 && emaF[0] > emaS[0]) return REGIME_TREND_UP;
      if(netMove < 0 && emaF[0] < emaS[0]) return REGIME_TREND_DN;
   }
   
   // Rango: baja eficiencia + volatilidad normal
   if(efficiency < 0.2 && volRatio < InpVolHighPct)
      return REGIME_RANGE;
   
   return REGIME_NONE;
}

//+------------------------------------------------------------------+
//| SISTEMA DE PUNTUACIÓN (0-10)                                    |
//+------------------------------------------------------------------+
int CalculateScore(SSymCtx &s, int direction)
{
   int score = 0;
   string details = "";
   
   // Datos
   double emaF[], emaS[], emaT[], rsi[], stochK[], stochD[], adx[], mom[];
   double bbUpper[], bbLower[], bbMid[];
   
   ArraySetAsSeries(emaF, true);
   ArraySetAsSeries(emaS, true);
   ArraySetAsSeries(emaT, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(stochK, true);
   ArraySetAsSeries(stochD, true);
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(mom, true);
   ArraySetAsSeries(bbUpper, true);
   ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(bbMid, true);
   
   if(CopyBuffer(s.hEMA_F, 0, 0, 5, emaF) < 5) return 0;
   if(CopyBuffer(s.hEMA_S, 0, 0, 5, emaS) < 5) return 0;
   if(CopyBuffer(s.hEMA_T, 0, 0, 5, emaT) < 5) return 0;
   if(CopyBuffer(s.hRSI, 0, 0, 5, rsi) < 5) return 0;
   if(CopyBuffer(s.hStoch, 0, 0, 5, stochK) < 5) return 0;
   if(CopyBuffer(s.hStoch, 1, 0, 5, stochD) < 5) return 0;
   if(CopyBuffer(s.hADX, 0, 0, 5, adx) < 5) return 0;
   if(CopyBuffer(s.hMom, 0, 0, 5, mom) < 5) return 0;
   if(CopyBuffer(s.hBB, 1, 0, 5, bbUpper) < 5) return 0;
   if(CopyBuffer(s.hBB, 2, 0, 5, bbLower) < 5) return 0;
   if(CopyBuffer(s.hBB, 0, 0, 5, bbMid) < 5) return 0;
   
   double bid = SymbolInfoDouble(s.name, SYMBOL_BID);
   double ask = SymbolInfoDouble(s.name, SYMBOL_ASK);
   double price = (direction > 0) ? ask : bid;
   
   // 1. ALINEACIÓN DE EMAs (max 3 puntos)
   bool emaStack = false;
   if(direction > 0 && emaF[0] > emaS[0] && emaS[0] > emaT[0]) { score += 2; emaStack = true; details += "EMA✓ "; }
   if(direction < 0 && emaF[0] < emaS[0] && emaS[0] < emaT[0]) { score += 2; emaStack = true; details += "EMA✓ "; }
   if(emaStack && MathAbs(emaF[0] - emaS[0]) > s.atrAvg * 0.3) { score += 1; details += "EMA_dist✓ "; }
   
   // 2. ADX (max 2 puntos)
   if(adx[0] > 25) { score += 2; details += "ADX_fuerte✓ "; }
   else if(adx[0] > 20) { score += 1; details += "ADX_ok✓ "; }
   
   // 3. RSI (max 1 punto)
   if(direction > 0 && rsi[0] > 50 && rsi[0] < 75) { score += 1; details += "RSI✓ "; }
   if(direction < 0 && rsi[0] < 50 && rsi[0] > 25) { score += 1; details += "RSI✓ "; }
   
   // 4. STOCHASTIC (max 1 punto)
   if(direction > 0 && stochK[0] > stochD[0] && stochK[0] < 80) { score += 1; details += "Stoch✓ "; }
   if(direction < 0 && stochK[0] < stochD[0] && stochK[0] > 20) { score += 1; details += "Stoch✓ "; }
   
   // 5. MOMENTUM (max 1 punto)
   if(direction > 0 && mom[0] > 100 && mom[0] > mom[1]) { score += 1; details += "Mom✓ "; }
   if(direction < 0 && mom[0] < 100 && mom[0] < mom[1]) { score += 1; details += "Mom✓ "; }
   
   // 6. POSICIÓN vs BANDAS BOLLINGER (max 1 punto)
   if(direction > 0 && price > bbMid[0] && price < bbUpper[0]) { score += 1; details += "BB✓ "; }
   if(direction < 0 && price < bbMid[0] && price > bbLower[0]) { score += 1; details += "BB✓ "; }
   
   // 7. EFICIENCIA DE TENDENCIA (max 1 punto)
   if(s.currentRegime == REGIME_TREND_UP && direction > 0) { score += 1; details += "Reg✓ "; }
   if(s.currentRegime == REGIME_TREND_DN && direction < 0) { score += 1; details += "Reg✓ "; }
   
   if(InpDebug && TimeCurrent() - g_lastDiag > 60)
   {
      g_lastDiag = TimeCurrent();
      Print(s.name, " Score ", direction, ": ", score, "/10 | ", details,
            " | Régimen: ", RegimeToString(s.currentRegime));
   }
   
   return score;
}

//+------------------------------------------------------------------+
string RegimeToString(ENUM_REGIME r)
{
   switch(r)
   {
      case REGIME_TREND_UP: return "TREND_UP";
      case REGIME_TREND_DN: return "TREND_DN";
      case REGIME_RANGE:    return "RANGE";
      case REGIME_VOLATILE: return "VOLATILE";
      default:              return "NONE";
   }
}

//+------------------------------------------------------------------+
void ProcessSym(int idx)
{
   SSymCtx s = g_sym[idx];
   
   datetime bar = iTime(s.name, PERIOD_M5, 0);
   if(bar == s.lastBar) return;
   s.lastBar = bar;
   g_sym[idx].lastBar = bar;
   
   if(InpUseSession && !IsSessionOK()) return;
   
   int openPos = CountPositionsSym(s.name);
   if(openPos >= InpMaxPosPerSym) return;
   
   // Detectar régimen
   ENUM_REGIME regime = DetectRegime(s);
   s.currentRegime = regime;
   g_sym[idx].currentRegime = regime;
   
   // No operar en volatilidad extrema
   if(regime == REGIME_VOLATILE) 
   {
      if(InpDebug && TimeCurrent() - g_lastDiag > 60)
         Print(s.name, " VOLATILE - no operar");
      return;
   }
   
   // Verificar permiso de régimen
   bool canTrade = false;
   if(regime == REGIME_TREND_UP || regime == REGIME_TREND_DN)
      canTrade = InpTradeOnTrend;
   else if(regime == REGIME_RANGE)
      canTrade = InpTradeOnRange;
   
   if(!canTrade) return;
   
   // Indicadores para ATR
   double atr[], emaF[], emaS[];
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(emaF, true);
   ArraySetAsSeries(emaS, true);
   if(CopyBuffer(s.hATR, 0, 0, 5, atr) < 5) return;
   if(CopyBuffer(s.hEMA_F, 0, 0, 5, emaF) < 5) return;
   if(CopyBuffer(s.hEMA_S, 0, 0, 5, emaS) < 5) return;
   
   double bid = SymbolInfoDouble(s.name, SYMBOL_BID);
   double atrPct = atr[0] / bid * 100.0;
   if(atrPct < InpMinATRPct) return;
   
   // Determinar dirección según régimen
   int desiredDir = 0;
   if(regime == REGIME_TREND_UP) desiredDir = 1;
   else if(regime == REGIME_TREND_DN) desiredDir = -1;
   else if(regime == REGIME_RANGE)
   {
      // En rango: mean reversion contra los extremos
      double bbU[], bbL[];
      ArraySetAsSeries(bbU, true);
      ArraySetAsSeries(bbL, true);
      if(CopyBuffer(s.hBB, 1, 0, 3, bbU) < 3) return;
      if(CopyBuffer(s.hBB, 2, 0, 3, bbL) < 3) return;
      
      if(bid <= bbL[0]) desiredDir = 1;
      else if(bid >= bbU[0]) desiredDir = -1;
   }
   
   if(desiredDir == 0) return;
   
   // Reset si cambió el régimen
   if(s.currentDir != desiredDir)
   {
      if(s.currentDir != 0)
         Print(">> ", s.name, " Dir: ", s.currentDir, " -> ", desiredDir,
               " | Régimen: ", RegimeToString(regime));
      s.currentDir = desiredDir;
      s.entriesInTrend = 0;
      s.lastEntryPrice = 0;
      g_sym[idx] = s;
   }
   
   if(s.entriesInTrend >= InpMaxEntries) return;
   
   // CALCULAR SCORE
   int score = CalculateScore(s, desiredDir);
   if(score < InpMinScore)
   {
      if(InpDebug && TimeCurrent() - g_lastDiag > 60)
         Print(">> ", s.name, " Score bajo: ", score, "/", InpMinScore);
      return;
   }
   
   // Decidir entrada
   double atrVal = atr[0];
   double entryStep = atrVal * InpEntryStepATR;
   double price = (desiredDir > 0) ? SymbolInfoDouble(s.name, SYMBOL_ASK) : bid;
   
   bool shouldEnter = false;
   string reason = "";
   
   if(s.entriesInTrend == 0)
   {
      shouldEnter = true;
      reason = "Primera (score:" + IntegerToString(score) + ")";
   }
   else if(desiredDir > 0 && price >= s.lastEntryPrice + entryStep)
   {
      shouldEnter = true;
      reason = "Cont+ (score:" + IntegerToString(score) + ")";
   }
   else if(desiredDir < 0 && price <= s.lastEntryPrice - entryStep)
   {
      shouldEnter = true;
      reason = "Cont- (score:" + IntegerToString(score) + ")";
   }
   
   if(!shouldEnter) return;
   
   // SL/TP
   double slDist = MathMax(atrVal * InpSL_ATR, s.stopsLevel * 1.5 + s.point * 50);
   double tpDist = atrVal * InpTP_ATR;
   
   double lot = s.fixedLot;
   
   double sl = (desiredDir > 0) ? price - slDist : price + slDist;
   double tp = (desiredDir > 0) ? price + tpDist : price - tpDist;
   
   sl = NormalizeDouble(sl, s.digits);
   tp = NormalizeDouble(tp, s.digits);
   
   string comment = StringFormat("SMART_%s_%d_S%d", s.name, desiredDir, score);
   bool ok = false;
   
   if(desiredDir > 0)
      ok = trade.Buy(lot, s.name, price, sl, tp, comment);
   else
      ok = trade.Sell(lot, s.name, price, sl, tp, comment);
   
   if(ok)
   {
      s.entriesInTrend++;
      s.lastEntryPrice = price;
      g_sym[idx] = s;
      
      Print(">>> ", s.name, " #", s.entriesInTrend,
            " ", (desiredDir > 0 ? "BUY" : "SELL"),
            " Lot:", lot, " @", price,
            " | Score:", score, "/10",
            " | Régimen:", RegimeToString(regime),
            " | ", reason);
   }
   else
   {
      Print("!! Error ", s.name, ": ", trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
int CountPositionsSym(string sym)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
void ManageAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      
      string sym = PositionGetString(POSITION_SYMBOL);
      int idx = -1;
      for(int k = 0; k < g_numSym; k++)
         if(g_sym[k].name == sym) { idx = k; break; }
      if(idx < 0) continue;
      
      SSymCtx s = g_sym[idx];
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(s.hATR, 0, 0, 3, atr) < 3) continue;
      double atrVal = atr[0];
      
      double profitPts = (type == POSITION_TYPE_BUY) ? (bid - open) : (open - ask);
      
      // Breakeven
      if(profitPts >= atrVal * 1.0 && profitPts < atrVal * InpTrailStartATR)
      {
         double beSL = open + (type == POSITION_TYPE_BUY ? 1 : -1) * s.point * 30;
         beSL = NormalizeDouble(beSL, s.digits);
         
         if(type == POSITION_TYPE_BUY && sl < beSL)
            trade.PositionModify(ticket, beSL, tp);
         else if(type == POSITION_TYPE_SELL && (sl == 0 || sl > beSL))
            trade.PositionModify(ticket, beSL, tp);
      }
      
      // Trailing
      if(profitPts >= atrVal * InpTrailStartATR)
      {
         double trailDist = atrVal * InpTrailDistATR;
         double newSL;
         
         if(type == POSITION_TYPE_BUY)
         {
            newSL = NormalizeDouble(bid - trailDist, s.digits);
            if(newSL > sl + s.point * 10)
               trade.PositionModify(ticket, newSL, tp);
         }
         else
         {
            newSL = NormalizeDouble(ask + trailDist, s.digits);
            if(newSL < sl - s.point * 10 || sl == 0)
               trade.PositionModify(ticket, newSL, tp);
         }
      }
   }
}

//+------------------------------------------------------------------+
bool IsSessionOK()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(h >= InpSessionStart && h < InpSessionEnd) return true;
   if(InpAllowAsian && (h >= 23 || h < InpSessionStart)) return true;
   return false;
}
//+------------------------------------------------------------------+