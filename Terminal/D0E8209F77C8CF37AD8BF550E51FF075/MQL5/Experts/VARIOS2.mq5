//+------------------------------------------------------------------+
//|                                          MultiAssetSMC_Deriv.mq5 |
//|   MultiAsset SMC EA v3.7 - XAUUSD + XAGUSD + GBPUSD + DXY Filtro |
//+------------------------------------------------------------------+
#property copyright "MultiAsset SMC Deriv"
#property version   "3.70"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade trade;

//--- SIMBOLOS
input group "=== SIMBOLOS ==="
input bool   UseXAUUSD  = true;
input bool   UseXAGUSD  = true;
input bool   UseGBPUSD  = true;
input string SufijoXAU  = "";
input string SufijoXAG  = "";
input string SufijoGBP  = "";

//--- DXY
input group "=== DXY (Correlacion Oro) ==="
input bool   UseDXYFilter = true;
input string NombreDXY    = "USDX";
input ENUM_TIMEFRAMES TF_DXY = PERIOD_H4;
input int    EMA_DXY_Period = 50;

//--- ESTRATEGIA
input group "=== ESTRATEGIA SMC ==="
input ENUM_TIMEFRAMES TF_Estructura = PERIOD_H1;
input ENUM_TIMEFRAMES TF_Entrada    = PERIOD_M15;
input int    CandlasEstructura = 50;
input int    CandlasOB         = 5;
input double OB_MinBody        = 0.4;
input int    SwingConfirmBars  = 2;

//--- RIESGO
input group "=== GESTION DE RIESGO ==="
input double RiesgoPorcentaje  = 1.0;
input double SL_ATR_Multiplier = 1.5;
input double TP_RR_Ratio       = 2.0;
input int    MaxTradesPorSimbolo = 1;
input int    MaxTradesTotales    = 3;
input bool   UsarTrailing        = false;
input double TrailingATR         = 2.0;
input double TrailingUmbralATR   = 2.0;
input int    CooldownSL_Minutos  = 15;

//--- FILTROS
input group "=== FILTROS ==="
input int    RSI_Periodo  = 14;
input double RSI_OB       = 65.0;
input double RSI_OS       = 35.0;
input bool   FiltrarSesion = true;
input int    SesionInicioH = 7;
input int    SesionFinH    = 20;
input double MaxSpreadMultiplier = 4.0;
input double MaxATRMultiplier    = 2.5;
input double MaxDailyDrawdown    = 12.0;
input bool   EvitarViernesTarde  = true;

//--- CORRELACION
input group "=== CORRELACION ==="
input bool   FiltrarXAU_XAG = true;
input bool   FiltrarXAU_GBP = true;
input bool   CorrMode_Block = false;

//--- LOG
input group "=== LOG ==="
input bool   VerboseLog = true;

//--- MAGIC
input long   MagicNumber = 20260917;

//--- GLOBALES
string symbols[3];
int    symbolCount = 0;

struct SymbolHandles {
   int atr_h1;
   int atr_m15;
   int rsi_m15;
   bool valid;
};

struct SymbolState {
   string   name;
   bool     biasAlcista;
   bool     bosDetectado;
   bool     chochDetectado;
   double   obHigh;
   double   obLow;
   bool     obAlcista;
   double   atr;
   double   rsi;
   datetime lastTradeTime;
   datetime lastSLTime;
   datetime lastTrailingBar;
   datetime lastBarProcesada;
   double   spreadMedian;
};

SymbolState   states[3];
SymbolHandles handles[3];

//--- DXY
int    hDXY_EMA = INVALID_HANDLE;
bool   dxyAvailable = false;
string dxyTrend = "NONE";

double   balanceInicioDia = 0;
datetime diaActual = 0;
bool     dailyKillSwitch = false;

//+------------------------------------------------------------------+
//| INICIALIZACION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(_Symbol);

   string tempSymbols[3];
   int tempCount = 0;

   if(UseXAUUSD) tempSymbols[tempCount++] = "XAUUSD" + SufijoXAU;
   if(UseXAGUSD) tempSymbols[tempCount++] = "XAGUSD" + SufijoXAG;
   if(UseGBPUSD) tempSymbols[tempCount++] = "GBPUSD" + SufijoGBP;

   symbolCount = 0;

   for(int i = 0; i < tempCount; i++)
   {
      string sym = tempSymbols[i];
      if(!SymbolSelect(sym, true)) { LogWarn("Simbolo no disponible: " + sym); continue; }
      SymbolInfoDouble(sym, SYMBOL_BID);
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      if(bid <= 0) { LogWarn("Sin precio: " + sym); continue; }

      symbols[symbolCount] = sym;
      states[symbolCount].name = sym;
      states[symbolCount].lastTradeTime = 0;
      states[symbolCount].lastSLTime = 0;
      states[symbolCount].lastTrailingBar = 0;
      states[symbolCount].lastBarProcesada = 0;
      states[symbolCount].spreadMedian = 0;
      states[symbolCount].biasAlcista = false;
      states[symbolCount].bosDetectado = false;
      states[symbolCount].chochDetectado = false;

      handles[symbolCount].atr_h1  = iATR(sym, TF_Estructura, 14);
      handles[symbolCount].atr_m15 = iATR(sym, TF_Entrada, 14);
      handles[symbolCount].rsi_m15 = iRSI(sym, TF_Entrada, RSI_Periodo, PRICE_CLOSE);
      handles[symbolCount].valid = (handles[symbolCount].atr_h1  != INVALID_HANDLE &&
                                     handles[symbolCount].atr_m15 != INVALID_HANDLE &&
                                     handles[symbolCount].rsi_m15 != INVALID_HANDLE);

      if(!handles[symbolCount].valid) LogError("Handles fallaron: " + sym);

      symbolCount++;
      LogInfo("Simbolo activo: " + sym + " | Digits=" + IntegerToString((int)SymbolInfoInteger(sym, SYMBOL_DIGITS)) +
              " | Spread=" + DoubleToString(SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID), 5) +
              " | VolMin=" + DoubleToString(SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), 3));
   }

   //--- Intentar cargar DXY
   if(UseDXYFilter)
   {
      if(SymbolSelect(NombreDXY, true))
      {
         double dxyBid = SymbolInfoDouble(NombreDXY, SYMBOL_BID);
         if(dxyBid > 0)
         {
            hDXY_EMA = iMA(NombreDXY, TF_DXY, EMA_DXY_Period, 0, MODE_EMA, PRICE_CLOSE);
            if(hDXY_EMA != INVALID_HANDLE)
            {
               dxyAvailable = true;
               LogInfo("DXY activo: " + NombreDXY + " | Bid=" + DoubleToString(dxyBid, 3) +
                       " | EMA" + IntegerToString(EMA_DXY_Period) + " en " + EnumToString(TF_DXY));
            }
            else LogWarn("DXY: no se pudo crear handle EMA para " + NombreDXY);
         }
         else LogWarn("DXY: simbolo " + NombreDXY + " sin precio. Filtro desactivado");
      }
      else LogWarn("DXY no disponible en tu broker: " + NombreDXY + ". Filtro desactivado");
   }

   if(symbolCount == 0) { Alert("Ningun simbolo disponible"); return INIT_FAILED; }

   for(int i = 0; i < symbolCount; i++)
   {
      string s = symbols[i];
      double bid = SymbolInfoDouble(s, SYMBOL_BID);
      double ask = SymbolInfoDouble(s, SYMBOL_ASK);
      int digits = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
      double point = SymbolInfoDouble(s, SYMBOL_POINT);
      double volMin = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
      double tickVal = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
      LogInfo("VERIF " + s +
              " | Bid=" + DoubleToString(bid, digits) +
              " | Ask=" + DoubleToString(ask, digits) +
              " | Digits=" + IntegerToString(digits) +
              " | Point=" + DoubleToString(point, 5) +
              " | VolMin=" + DoubleToString(volMin, 2) +
              " | TickVal=" + DoubleToString(tickVal, 4) +
              " | TickSize=" + DoubleToString(tickSize, 4));
   }

   balanceInicioDia = AccountInfoDouble(ACCOUNT_BALANCE);
   diaActual = GetDayStart();

   LogInfo("MultiAsset SMC v3.7 iniciado | " + IntegerToString(symbolCount) +
           " simbolos | DXY=" + (dxyAvailable ? "ON" : "OFF") +
           " | Trailing=" + (UsarTrailing ? "ON" : "OFF"));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < symbolCount; i++)
   {
      if(handles[i].atr_h1  != INVALID_HANDLE) IndicatorRelease(handles[i].atr_h1);
      if(handles[i].atr_m15 != INVALID_HANDLE) IndicatorRelease(handles[i].atr_m15);
      if(handles[i].rsi_m15 != INVALID_HANDLE) IndicatorRelease(handles[i].rsi_m15);
   }
   if(hDXY_EMA != INVALID_HANDLE) IndicatorRelease(hDXY_EMA);
   LogInfo("EA detenido. Razon: " + IntegerToString(reason));
}

//+------------------------------------------------------------------+
void ActualizarTendenciaDXY()
{
   if(!dxyAvailable) return;

   double emaDXY[1], emaDXY_2[1];
   if(CopyBuffer(hDXY_EMA, 0, 1, 1, emaDXY) <= 0) return;
   CopyBuffer(hDXY_EMA, 0, 3, 1, emaDXY_2);
   double dxyClose = iClose(NombreDXY, TF_DXY, 1);
   if(dxyClose <= 0) return;

   double emaSlope = emaDXY[0] - emaDXY_2[0];

   if(dxyClose > emaDXY[0] && emaSlope > 0)
      dxyTrend = "UP";
   else if(dxyClose < emaDXY[0] && emaSlope < 0)
      dxyTrend = "DOWN";
   else
      dxyTrend = "FLAT";
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime hoy = GetDayStart();
   if(hoy != diaActual)
   {
      diaActual = hoy;
      balanceInicioDia = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyKillSwitch = false;
      LogInfo("Nuevo dia. Balance inicio: " + DoubleToString(balanceInicioDia, 2));
   }

   if(!dailyKillSwitch)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double dd_pct = (balanceInicioDia > 0) ? ((balanceInicioDia - balance) / balanceInicioDia) * 100.0 : 0;
      if(dd_pct >= MaxDailyDrawdown)
      {
         dailyKillSwitch = true;
         LogError("KILL SWITCH DIARIO: DD " + DoubleToString(dd_pct, 2) + "%");
         CerrarTodoEA();
         return;
      }
   }
   if(dailyKillSwitch) return;

   if(EvitarViernesTarde && EsViernesTarde()) return;
   if(FiltrarSesion && !EnSesion()) return;

   static datetime lastDXYBar = 0;
   datetime dxyBar = iTime(NombreDXY, TF_DXY, 0);
   if(dxyBar != lastDXYBar)
   {
      lastDXYBar = dxyBar;
      ActualizarTendenciaDXY();
      if(dxyAvailable && VerboseLog)
         LogInfo("DXY " + NombreDXY + " tendencia: " + dxyTrend);
   }

   if(UsarTrailing) GestionarTradesAbiertos();

   int totalTrades = ContarTradesEA();
   if(totalTrades >= MaxTradesTotales) return;

   for(int i = 0; i < symbolCount; i++)
      ProcesarSimbolo(i);
}

//+------------------------------------------------------------------+
void ProcesarSimbolo(int idx)
{
   string sym = symbols[idx];
   if(!handles[idx].valid) return;

   datetime currentBar = iTime(sym, TF_Entrada, 0);
   if(states[idx].lastBarProcesada == currentBar) return;
   states[idx].lastBarProcesada = currentBar;

   if(ContarTradesSimbolo(sym) >= MaxTradesPorSimbolo) return;

   if(states[idx].lastSLTime > 0)
   {
      int segundosCooldown = CooldownSL_Minutos * 60;
      if((int)(TimeCurrent() - states[idx].lastSLTime) < segundosCooldown)
      {
         if(VerboseLog) LogInfo("Cooldown " + sym + " - faltan " +
                                 IntegerToString((segundosCooldown - (int)(TimeCurrent() - states[idx].lastSLTime)) / 60) + " min");
         return;
      }
   }

   // --- Correlacion XAU/XAG/GBP ---
   if(FiltrarXAU_XAG || FiltrarXAU_GBP)
   {
      string correlativo = "";
      bool isXAU = (StringFind(sym, "XAU") >= 0);
      bool isXAG = (StringFind(sym, "XAG") >= 0);
      bool isGBP = (StringFind(sym, "GBP") >= 0);

      for(int p = PositionsTotal()-1; p >= 0 && correlativo == ""; p--)
      {
         ulong tk = PositionGetTicket(p);
         if(!PositionSelectByTicket(tk)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         string posSym = PositionGetString(POSITION_SYMBOL);

         if(isXAU && FiltrarXAU_XAG && StringFind(posSym, "XAG") >= 0)
            correlativo = "XAG";
         else if(isXAU && FiltrarXAU_GBP && StringFind(posSym, "GBP") >= 0)
            correlativo = "GBP";
         else if(isXAG && FiltrarXAU_XAG && StringFind(posSym, "XAU") >= 0)
            correlativo = "XAU";
         else if(isGBP && FiltrarXAU_GBP && StringFind(posSym, "XAU") >= 0)
            correlativo = "XAU";
      }

      if(correlativo != "")
      {
         bool posAlcista = false;
         bool found = false;
         for(int p = PositionsTotal()-1; p >= 0; p--)
         {
            ulong tk = PositionGetTicket(p);
            if(!PositionSelectByTicket(tk)) continue;
            if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
            string posSym = PositionGetString(POSITION_SYMBOL);
            if(StringFind(posSym, correlativo) < 0) continue;
            posAlcista = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
            found = true;
            break;
         }
         if(found)
         {
            if(CorrMode_Block)
            {
               if(VerboseLog) LogInfo("Correlacion bloquea " + sym);
               return;
            }
            if(posAlcista != states[idx].biasAlcista)
            {
               if(VerboseLog) LogInfo("Correlacion opuesta bloquea " + sym);
               return;
            }
         }
      }
   }

   // --- Filtro DXY para XAUUSD ---
   if(dxyAvailable && StringFind(sym, "XAU") >= 0)
   {
      bool esLong = states[idx].biasAlcista;
      if(dxyTrend == "UP" && esLong)
      {
         if(VerboseLog) LogInfo("DXY UP bloquea LONG en " + sym);
         return;
      }
      if(dxyTrend == "DOWN" && !esLong)
      {
         if(VerboseLog) LogInfo("DXY DOWN bloquea SHORT en " + sym);
         return;
      }
   }

   // --- Filtro de spread ---
   double spread = SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID);
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   double spreadPoints = spread / point;

   UpdateSpreadMedian(idx);
   if(states[idx].spreadMedian > 0 && spreadPoints > states[idx].spreadMedian * MaxSpreadMultiplier)
   {
      if(VerboseLog) LogInfo("Spread alto en " + sym + ": " + DoubleToString(spreadPoints, 1));
      return;
   }

   states[idx].atr = GetBufferValue(handles[idx].atr_h1, 1);
   if(states[idx].atr <= 0) return;

   double atrMedian = GetATRMedian(idx);
   if(atrMedian > 0 && states[idx].atr > atrMedian * MaxATRMultiplier)
   {
      if(VerboseLog) LogInfo("ATR anomalo en " + sym);
      return;
   }

   states[idx].rsi = GetBufferValue(handles[idx].rsi_m15, 1);

   DetectarEstructura(idx);
   if(states[idx].bosDetectado || states[idx].chochDetectado)
      BuscarOrderBlock(idx);

   EvaluarEntrada(idx);
}

//+------------------------------------------------------------------+
void DetectarEstructura(int idx)
{
   string sym = symbols[idx];
   int n = CandlasEstructura;

   double highs[], lows[], closes[];
   ArraySetAsSeries(highs,  true);
   ArraySetAsSeries(lows,   true);
   ArraySetAsSeries(closes, true);

   if(CopyHigh(sym,  TF_Estructura, 0, n, highs)  < n) return;
   if(CopyLow(sym,   TF_Estructura, 0, n, lows)   < n) return;
   if(CopyClose(sym, TF_Estructura, 0, n, closes) < n) return;

   int lookback = MathMin(30, n - SwingConfirmBars - 2);
   double swingHigh = 0, swingLow = 999999;
   int swingHighIdx = -1, swingLowIdx = -1;

   for(int i = SwingConfirmBars + 1; i < lookback; i++)
   {
      bool esHigh = true;
      bool esLow  = true;
      for(int k = 1; k <= SwingConfirmBars; k++)
      {
         if(highs[i] <= highs[i-k] || highs[i] <= highs[i+k]) esHigh = false;
         if(lows[i]  >= lows[i-k]  || lows[i]  >= lows[i+k])  esLow  = false;
      }
      if(esHigh && highs[i] > swingHigh) { swingHigh = highs[i]; swingHighIdx = i; }
      if(esLow  && lows[i]  < swingLow)  { swingLow  = lows[i];  swingLowIdx  = i; }
   }

   double precioActual = closes[0];

   if(swingHighIdx > 0 && precioActual > swingHigh)
   {
      if(!states[idx].biasAlcista)
      {
         states[idx].chochDetectado = true;
         LogInfo("CHoCH ALCISTA " + sym + " @ " + DoubleToString(swingHigh, 5));
      }
      else
      {
         states[idx].bosDetectado = true;
         LogInfo("BOS ALCISTA " + sym + " @ " + DoubleToString(swingHigh, 5));
      }
      states[idx].biasAlcista = true;
   }
   else if(swingLowIdx > 0 && precioActual < swingLow)
   {
      if(states[idx].biasAlcista)
      {
         states[idx].chochDetectado = true;
         LogInfo("CHoCH BAJISTA " + sym + " @ " + DoubleToString(swingLow, 5));
      }
      else
      {
         states[idx].bosDetectado = true;
         LogInfo("BOS BAJISTA " + sym + " @ " + DoubleToString(swingLow, 5));
      }
      states[idx].biasAlcista = false;
   }
}

//+------------------------------------------------------------------+
void BuscarOrderBlock(int idx)
{
   string sym = symbols[idx];
   double opens[], highs[], lows[], closes[];
   ArraySetAsSeries(opens,  true);
   ArraySetAsSeries(highs,  true);
   ArraySetAsSeries(lows,   true);
   ArraySetAsSeries(closes, true);

   int n = 30;
   if(CopyOpen(sym,  TF_Entrada, 0, n, opens)  < n) return;
   if(CopyHigh(sym,  TF_Entrada, 0, n, highs)  < n) return;
   if(CopyLow(sym,   TF_Entrada, 0, n, lows)   < n) return;
   if(CopyClose(sym, TF_Entrada, 0, n, closes) < n) return;

   states[idx].obHigh = 0;
   states[idx].obLow  = 0;

   if(states[idx].biasAlcista)
   {
      for(int i = 3; i < 20; i++)
      {
         bool velaImpulso = closes[i-1] > opens[i-1];
         bool velaBajista = closes[i]   < opens[i];
         double cImp = MathAbs(closes[i-1] - opens[i-1]);
         double rImp = highs[i-1] - lows[i-1];
         double cOB  = MathAbs(closes[i]   - opens[i]);
         double rOB  = highs[i] - lows[i];

         if(velaBajista && velaImpulso && rImp > 0 && rOB > 0)
         {
            if(cImp/rImp > 0.6 && cOB/rOB > OB_MinBody)
            {
               states[idx].obHigh = highs[i];
               states[idx].obLow  = lows[i];
               states[idx].obAlcista = true;
               break;
            }
         }
      }
   }
   else
   {
      for(int i = 3; i < 20; i++)
      {
         bool velaImpulso = closes[i-1] < opens[i-1];
         bool velaAlcista = closes[i]   > opens[i];
         double cImp = MathAbs(closes[i-1] - opens[i-1]);
         double rImp = highs[i-1] - lows[i-1];
         double cOB  = MathAbs(closes[i]   - opens[i]);
         double rOB  = highs[i] - lows[i];

         if(velaAlcista && velaImpulso && rImp > 0 && rOB > 0)
         {
            if(cImp/rImp > 0.6 && cOB/rOB > OB_MinBody)
            {
               states[idx].obHigh = highs[i];
               states[idx].obLow  = lows[i];
               states[idx].obAlcista = false;
               break;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void EvaluarEntrada(int idx)
{
   string sym = symbols[idx];
   if(states[idx].obHigh == 0 || states[idx].obLow == 0) return;

   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double atr = states[idx].atr;
   double rsi = states[idx].rsi;

   if(states[idx].biasAlcista && states[idx].obAlcista)
   {
      if(bid >= states[idx].obLow && bid <= states[idx].obHigh && rsi < RSI_OB)
      {
         double sl = states[idx].obLow - (atr * SL_ATR_Multiplier);
         double tp = ask + (MathAbs(ask - sl) * TP_RR_Ratio);
         double lote = CalcularLote(sym, ask, sl);
         if(lote > 0 && trade.Buy(lote, sym, ask, sl, tp, "SMC_BUY_" + sym))
         {
            LogInfo("BUY " + sym + " | Lote:" + DoubleToString(lote,2) +
                    " | E:" + DoubleToString(ask,5) +
                    " | SL:" + DoubleToString(sl,5) +
                    " | TP:" + DoubleToString(tp,5));
            states[idx].bosDetectado = false;
            states[idx].chochDetectado = false;
            states[idx].lastTradeTime = TimeCurrent();
         }
      }
   }

   if(!states[idx].biasAlcista && !states[idx].obAlcista)
   {
      if(bid >= states[idx].obLow && bid <= states[idx].obHigh && rsi > RSI_OS)
      {
         double sl = states[idx].obHigh + (atr * SL_ATR_Multiplier);
         double tp = bid - (MathAbs(sl - bid) * TP_RR_Ratio);
         double lote = CalcularLote(sym, bid, sl);
         if(lote > 0 && trade.Sell(lote, sym, bid, sl, tp, "SMC_SELL_" + sym))
         {
            LogInfo("SELL " + sym + " | Lote:" + DoubleToString(lote,2) +
                    " | E:" + DoubleToString(bid,5) +
                    " | SL:" + DoubleToString(sl,5) +
                    " | TP:" + DoubleToString(tp,5));
            states[idx].bosDetectado = false;
            states[idx].chochDetectado = false;
            states[idx].lastTradeTime = TimeCurrent();
         }
      }
   }
}

//+------------------------------------------------------------------+
double CalcularLote(string sym, double entrada, double sl)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riesgoUSD = balance * RiesgoPorcentaje / 100.0;
   double slPoints  = MathAbs(entrada - sl);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double lotMin    = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double lotMax    = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double lotStep   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   if(tickSize == 0 || tickValue == 0 || slPoints == 0) return 0;

   double valorPunto = tickValue / tickSize;
   double lote = riesgoUSD / (slPoints * valorPunto);

   lote = MathFloor(lote / lotStep) * lotStep;
   lote = MathMax(lotMin, MathMin(lotMax, lote));

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginPerLot = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, sym, 1.0, entrada, marginPerLot) && marginPerLot > 0)
   {
      double maxLotsMargin = (freeMargin * 0.5) / marginPerLot;
      if(lote > maxLotsMargin) lote = MathFloor(maxLotsMargin / lotStep) * lotStep;
   }

   return lote;
}

//+------------------------------------------------------------------+
void GestionarTradesAbiertos()
{
   if(!UsarTrailing) return;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      int symIdx = BuscarIndice(sym);
      if(symIdx < 0) continue;

      datetime barActual = iTime(sym, TF_Entrada, 0);
      if(states[symIdx].lastTrailingBar == barActual) continue;

      double atr = states[symIdx].atr;
      if(atr <= 0) atr = GetBufferValue(handles[symIdx].atr_h1, 1);
      if(atr <= 0) continue;

      double sl      = PositionGetDouble(POSITION_SL);
      double tp      = PositionGetDouble(POSITION_TP);
      double entrada = PositionGetDouble(POSITION_PRICE_OPEN);
      double precio  = PositionGetDouble(POSITION_PRICE_CURRENT);
      long   tipo    = PositionGetInteger(POSITION_TYPE);
      double trailing = atr * TrailingATR;
      double umbral   = atr * TrailingUmbralATR;

      double spread = SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID);
      double minStep = MathMax(spread * 3, atr * 0.5);

      if(tipo == POSITION_TYPE_BUY)
      {
         double ganancia = precio - entrada;
         if(ganancia < umbral) continue;
         double newSL = precio - trailing;
         if(newSL < entrada) newSL = entrada;
         if(newSL > sl + minStep)
         {
            if(trade.PositionModify(ticket, newSL, tp))
            {
               states[symIdx].lastTrailingBar = barActual;
               LogInfo("Trailing BUY " + sym + " SL:" + DoubleToString(sl,5) + "->" + DoubleToString(newSL,5));
            }
         }
      }
      else if(tipo == POSITION_TYPE_SELL)
      {
         double ganancia = entrada - precio;
         if(ganancia < umbral) continue;
         double newSL = precio + trailing;
         if(newSL > entrada) newSL = entrada;
         if(newSL < sl - minStep)
         {
            if(trade.PositionModify(ticket, newSL, tp))
            {
               states[symIdx].lastTrailingBar = barActual;
               LogInfo("Trailing SELL " + sym + " SL:" + DoubleToString(sl,5) + "->" + DoubleToString(newSL,5));
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong dealTicket = trans.deal;
   if(!HistoryDealSelect(dealTicket)) return;

   long dealMagic  = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   long dealReason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
   string dealSym  = HistoryDealGetString(dealTicket, DEAL_SYMBOL);

   if(dealMagic == MagicNumber && dealReason == DEAL_REASON_SL)
   {
      int idx = BuscarIndice(dealSym);
      if(idx >= 0)
      {
         states[idx].lastSLTime = TimeCurrent();
         LogWarn("SL activado en " + dealSym + " - cooldown " + IntegerToString(CooldownSL_Minutos) + " min");
      }
   }
}

//+------------------------------------------------------------------+
double GetBufferValue(int handle, int shift)
{
   if(handle == INVALID_HANDLE) return 0;
   double buf[1];
   if(CopyBuffer(handle, 0, shift, 1, buf) <= 0) return 0;
   return buf[0];
}

void UpdateSpreadMedian(int idx)
{
   string sym = symbols[idx];
   double spreads[];
   ArrayResize(spreads, 100);
   for(int i = 0; i < 100; i++)
   {
      MqlTick tick;
      if(SymbolInfoTick(sym, tick))
         spreads[i] = (tick.ask - tick.bid) / SymbolInfoDouble(sym, SYMBOL_POINT);
      else
         spreads[i] = 0;
   }
   ArraySort(spreads);
   states[idx].spreadMedian = spreads[50];
}

double GetATRMedian(int idx)
{
   double atr_vals[];
   ArrayResize(atr_vals, 100);
   for(int i = 0; i < 100; i++)
      atr_vals[i] = GetBufferValue(handles[idx].atr_h1, i + 1);
   ArraySort(atr_vals);
   return atr_vals[50];
}

int ContarTradesEA()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong tk = PositionGetTicket(i);
      if(PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

int ContarTradesSimbolo(string sym)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong tk = PositionGetTicket(i);
      if(PositionSelectByTicket(tk) &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == sym)
         count++;
   }
   return count;
}

int BuscarIndice(string sym)
{
   for(int i = 0; i < symbolCount; i++)
      if(symbols[i] == sym) return i;
   return -1;
}

bool EnSesion()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   return (dt.hour >= SesionInicioH && dt.hour < SesionFinH);
}

bool EsViernesTarde()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return (dt.day_of_week == 5 && dt.hour >= 18);
}

datetime GetDayStart()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

void CerrarTodoEA()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      trade.PositionClose(tk);
   }
}

void LogInfo(string msg)  { if(VerboseLog) Print("[INFO] ", msg); }
void LogWarn(string msg)  { Print("[WARN] ", msg); }
void LogError(string msg) { Print("[ERROR] ", msg); }
//+------------------------------------------------------------------+