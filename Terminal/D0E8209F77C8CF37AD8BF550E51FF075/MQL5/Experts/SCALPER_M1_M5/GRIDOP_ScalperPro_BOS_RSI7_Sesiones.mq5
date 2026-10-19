//+------------------------------------------------------------------+
//|                         ORO_SCALPER_PRO.mq5                      |
//|              Sistema Completo de Scalping para XAUUSD             |
//|   Estrategia: BOS + RSI(7) + EMA Trend + Sesión Londres/NY       |
//|                        Version 1.0                                |
//+------------------------------------------------------------------+
#property copyright   "ORO Scalper Pro"
#property version     "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <GoldMaster\GoldMaster_LotGuard.mqh>

//--- Guarda de lote (GoldMaster_LotGuard.mqh) -----------------------
// El suelo de lote minimo del broker puede forzar MUCHO mas riesgo del
// planeado sin avisar. Estos dos limites hacen que el EA prefiera NO
// operar antes que operar con un riesgo que no eligio el usuario.
input double InpLG_MaxRiskPct    = 5.0;  // Guarda: riesgo max. por operacion (% equity, 0=off)
input double InpLG_MaxOverTarget = 2.0;  // Guarda: multiplo max. del riesgo objetivo (0=off)


CTrade        trade;
CPositionInfo posInfo;

//--- PARÁMETROS DE ENTRADA
input group "=== GESTIÓN DE RIESGO ==="
input double  RiskPercent       = 1.0;     // Riesgo por trade (% del balance)
input double  SL_ATR_Mult       = 2.0;     // Multiplicador ATR para Stop Loss
input double  TP1_ATR_Mult      = 2.0;     // Multiplicador ATR para TP1 (50% posición)
input double  TP2_ATR_Mult      = 4.0;     // Multiplicador ATR para TP2 (50% restante)
input bool    UsePartialClose   = true;    // Activar cierre parcial en TP1

input group "=== INDICADORES ==="
input int     EMA_Fast          = 20;      // EMA rápida (tendencia local)
input int     EMA_Slow          = 50;      // EMA lenta (tendencia principal)
input int     EMA_Trend         = 200;     // EMA de tendencia macro (en TF superior)
input int     RSI_Period        = 7;       // Período RSI (7 = scalping)
input double  RSI_BullMin       = 45.0;   // RSI mínimo para compra
input double  RSI_BullMax       = 65.0;   // RSI máximo para compra
input double  RSI_BearMin       = 35.0;   // RSI mínimo para venta
input double  RSI_BearMax       = 55.0;   // RSI máximo para venta
input int     ATR_Period        = 14;      // Período ATR

input group "=== FILTROS DE CALIDAD ==="
input double  Min_ATR_Pips      = 25.0;   // ATR mínimo para operar (volatilidad)
input double  Max_ATR_Pips      = 150.0;  // ATR máximo (evitar noticias extremas)
input double  Min_EMA_Distance  = 10.0;   // Distancia mínima entre EMA20-50 (pips)
input int     SwingWindow       = 3;       // Velas para detectar swing high/low
input int     ConfirmBars       = 2;       // Velas de confirmación tras BOS
input int     MaxTradesPerDay   = 5;       // Máximo trades por día
input int     CooldownBars      = 8;       // Velas de espera tras cierre de trade

input group "=== FILTRO DE SESIÓN ==="
input bool    FilterSession     = true;    // Activar filtro de sesión horaria
input int     London_Start      = 8;       // Inicio sesión Londres (hora UTC)
input int     London_End        = 12;      // Fin sesión Londres (hora UTC)
input int     NY_Start          = 13;      // Inicio sesión NY (hora UTC)
input int     NY_End            = 20;      // Fin sesión NY (hora UTC)
input bool    TradeLondon       = true;    // Operar sesión Londres
input bool    TradeNY           = true;    // Operar sesión NY

input group "=== CONFIGURACIÓN ==="
input ulong   MagicNumber       = 202600;  // Magic number
input bool    EnableBuy         = true;    // Habilitar compras
input bool    EnableSell        = true;    // Habilitar ventas
input bool    ShowLogs          = true;    // Mostrar logs detallados

//--- HANDLES DE INDICADORES
int handleEMA_Fast;
int handleEMA_Slow;
int handleEMA_Trend;
int handleRSI;
int handleATR;

//--- BUFFERS
double bufEMA_Fast[];
double bufEMA_Slow[];
double bufEMA_Trend[];
double bufRSI[];
double bufATR[];

//--- VARIABLES DE ESTADO
datetime lastTradeTime   = 0;
int      tradesThisDay   = 0;
datetime lastDayChecked  = 0;
int      barsAfterClose  = 0;
bool     partialClosed   = false;
ulong    currentTicket   = 0;
int      confirmCounter  = 0;
int      pendingSignal   = 0; // 1=buy, -1=sell, 0=ninguno

//--- VARIABLES DE ESTRUCTURA
double   lastSwingHigh   = 0;
double   lastSwingLow    = 0;
double   prevSwingHigh   = 0;
double   prevSwingLow    = 0;
bool     bosAlcista      = false;
bool     bosBajista      = false;
datetime bosTime         = 0;

double   pipValue        = 1.0;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validaciones básicas
   if(RiskPercent <= 0 || RiskPercent > 5)
   {
      Alert("ORO_SCALPER_PRO: RiskPercent debe ser entre 0.1 y 5.0");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Calcular valor del pip para XAUUSD
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   pipValue = (tickSize > 0) ? tickSize : 0.01;
   if(_Digits == 2) pipValue = 0.01; // XAUUSD típico

   // Crear handles de indicadores
   handleEMA_Fast  = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast,  0, MODE_EMA, PRICE_CLOSE);
   handleEMA_Slow  = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow,  0, MODE_EMA, PRICE_CLOSE);
   handleEMA_Trend = iMA(_Symbol, PERIOD_M15,     EMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI       = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   handleATR       = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(handleEMA_Fast  == INVALID_HANDLE ||
      handleEMA_Slow  == INVALID_HANDLE ||
      handleEMA_Trend == INVALID_HANDLE ||
      handleRSI       == INVALID_HANDLE ||
      handleATR       == INVALID_HANDLE)
   {
      Alert("ORO_SCALPER_PRO: Error creando indicadores: ", GetLastError());
      return INIT_FAILED;
   }

   // Configurar arrays como series (índice 0 = vela más reciente)
   ArraySetAsSeries(bufEMA_Fast,  true);
   ArraySetAsSeries(bufEMA_Slow,  true);
   ArraySetAsSeries(bufEMA_Trend, true);
   ArraySetAsSeries(bufRSI,       true);
   ArraySetAsSeries(bufATR,       true);

   // Configurar trade
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   if(ShowLogs)
      Print("ORO_SCALPER_PRO v1.0 iniciado. Simbolo: ", _Symbol,
            " | TF: ", EnumToString(Period()),
            " | Magic: ", MagicNumber);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleEMA_Fast);
   IndicatorRelease(handleEMA_Slow);
   IndicatorRelease(handleEMA_Trend);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleATR);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // Solo operar en vela nueva cerrada
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBar == lastBar) return;
   lastBar = currentBar;

   // Actualizar buffers
   if(!RefreshBuffers()) return;

   // Resetear contador de trades al cambiar de día
   ResetDailyCounter();

   // Manejar cierre parcial si hay posición abierta
   if(PositionExists())
   {
      ManageOpenPosition();
      barsAfterClose = 0; // hay posición activa, no incrementar cooldown
      return;
   }

   // Incrementar cooldown después de cerrar
   barsAfterClose++;

   // Filtro de máximo trades por día
   if(tradesThisDay >= MaxTradesPerDay)
   {
      if(ShowLogs && barsAfterClose == 1)
         Print("Máximo trades del día alcanzado (", MaxTradesPerDay, "). Esperando mañana.");
      return;
   }

   // Filtro de cooldown
   if(barsAfterClose < CooldownBars && barsAfterClose > 0)
   {
      if(ShowLogs && barsAfterClose == 1)
         Print("Cooldown activo. Velas restantes: ", CooldownBars - barsAfterClose);
      return;
   }

   // Filtro de sesión
   if(FilterSession && !IsSessionActive())
   {
      return;
   }

   // Filtro de volatilidad ATR
   double atrPips = bufATR[1] / pipValue;
   if(atrPips < Min_ATR_Pips)
   {
      if(ShowLogs) Print("ATR bajo (", DoubleToString(atrPips, 1), " pips). Min: ", Min_ATR_Pips);
      return;
   }
   if(atrPips > Max_ATR_Pips)
   {
      if(ShowLogs) Print("ATR muy alto (", DoubleToString(atrPips, 1), " pips) - posible noticia. Evitando.");
      return;
   }

   // Filtro de distancia EMA
   double emaDist = MathAbs(bufEMA_Fast[1] - bufEMA_Slow[1]) / pipValue;
   if(emaDist < Min_EMA_Distance)
   {
      if(ShowLogs) Print("EMAs muy juntas (", DoubleToString(emaDist, 1), " pips). Sin tendencia clara.");
      return;
   }

   // Detectar estructura BOS
   DetectBOS();

   // Evaluar señal de entrada
   EvaluateEntry();
}

//+------------------------------------------------------------------+
//| Refrescar todos los buffers de indicadores                        |
//+------------------------------------------------------------------+
bool RefreshBuffers()
{
   int bars = 10 + SwingWindow * 2;

   if(CopyBuffer(handleEMA_Fast,  0, 0, bars, bufEMA_Fast)  <= 0) return false;
   if(CopyBuffer(handleEMA_Slow,  0, 0, bars, bufEMA_Slow)  <= 0) return false;
   if(CopyBuffer(handleEMA_Trend, 0, 0, 3,    bufEMA_Trend) <= 0) return false;
   if(CopyBuffer(handleRSI,       0, 0, bars, bufRSI)       <= 0) return false;
   if(CopyBuffer(handleATR,       0, 0, bars, bufATR)       <= 0) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Detectar BOS (Break of Structure)                                 |
//+------------------------------------------------------------------+
void DetectBOS()
{
   // Buscar el último swing high y swing low usando fractal simple
   double swHigh = 0, swLow = DBL_MAX;
   double prevHigh = 0, prevLow = DBL_MAX;
   bool foundFirst = false;

   int lookback = SwingWindow * 2 + 1;

   for(int i = SwingWindow + 1; i < lookback + SwingWindow; i++)
   {
      // Detectar swing high
      bool isSwingHigh = true;
      bool isSwingLow  = true;

      for(int k = 1; k <= SwingWindow; k++)
      {
         if(iHigh(_Symbol, PERIOD_CURRENT, i) <= iHigh(_Symbol, PERIOD_CURRENT, i - k)) isSwingHigh = false;
         if(iHigh(_Symbol, PERIOD_CURRENT, i) <= iHigh(_Symbol, PERIOD_CURRENT, i + k)) isSwingHigh = false;
         if(iLow(_Symbol, PERIOD_CURRENT, i)  >= iLow(_Symbol, PERIOD_CURRENT, i - k))  isSwingLow  = false;
         if(iLow(_Symbol, PERIOD_CURRENT, i)  >= iLow(_Symbol, PERIOD_CURRENT, i + k))  isSwingLow  = false;
      }

      if(isSwingHigh)
      {
         double h = iHigh(_Symbol, PERIOD_CURRENT, i);
         if(!foundFirst)
         {
            swHigh = h;
            foundFirst = true;
         }
         else if(prevHigh == 0)
            prevHigh = h;
      }

      if(isSwingLow)
      {
         double l = iLow(_Symbol, PERIOD_CURRENT, i);
         if(swLow == DBL_MAX)
            swLow = l;
         else if(prevLow == DBL_MAX)
            prevLow = l;
      }
   }

   // Guardar swings
   if(swHigh > 0)   lastSwingHigh = swHigh;
   if(swLow < DBL_MAX && swLow > 0) lastSwingLow = swLow;
   if(prevHigh > 0) prevSwingHigh = prevHigh;
   if(prevLow < DBL_MAX && prevLow > 0) prevSwingLow = prevLow;

   // Detectar BOS: precio cierra por encima del último swing high = BOS alcista
   double closePrice = iClose(_Symbol, PERIOD_CURRENT, 1);

   if(lastSwingHigh > 0 && closePrice > lastSwingHigh && !bosAlcista)
   {
      bosAlcista  = true;
      bosBajista  = false;
      bosTime     = iTime(_Symbol, PERIOD_CURRENT, 1);
      confirmCounter = 0;
      pendingSignal = 1;
      if(ShowLogs) Print("BOS ALCISTA detectado. Precio: ", closePrice, " > SwingHigh: ", lastSwingHigh);
   }
   else if(lastSwingLow > 0 && closePrice < lastSwingLow && !bosBajista)
   {
      bosBajista  = true;
      bosAlcista  = false;
      bosTime     = iTime(_Symbol, PERIOD_CURRENT, 1);
      confirmCounter = 0;
      pendingSignal = -1;
      if(ShowLogs) Print("BOS BAJISTA detectado. Precio: ", closePrice, " < SwingLow: ", lastSwingLow);
   }
}

//+------------------------------------------------------------------+
//| Evaluar y ejecutar entrada                                        |
//+------------------------------------------------------------------+
void EvaluateEntry()
{
   if(pendingSignal == 0) return;

   // Incrementar confirmación
   confirmCounter++;

   // Esperar velas de confirmación
   if(confirmCounter < ConfirmBars)
   {
      if(ShowLogs) Print("Esperando confirmación. Velas: ", confirmCounter, "/", ConfirmBars);
      return;
   }

   double rsi     = bufRSI[1];
   double emaFast = bufEMA_Fast[1];
   double emaSlow = bufEMA_Slow[1];
   double emaTrend= bufEMA_Trend[1]; // EMA200 en M15
   double atr     = bufATR[1];
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // SEÑAL DE COMPRA
   if(pendingSignal == 1 && EnableBuy)
   {
      bool trendOk  = (emaFast > emaSlow);                          // EMA20 > EMA50 = tendencia alcista local
      bool macroOk  = (ask > emaTrend);                             // Precio por encima de EMA200 M15
      bool rsiOk    = (rsi >= RSI_BullMin && rsi <= RSI_BullMax);   // RSI en zona válida (no sobrecomprado)
      bool strucOk  = (bosAlcista);                                  // BOS alcista confirmado

      if(ShowLogs)
         Print("EVALUANDO BUY | Trend:", trendOk, " Macro:", macroOk,
               " RSI:", DoubleToString(rsi, 1), "(ok:", rsiOk, ")", " BOS:", strucOk);

      if(trendOk && macroOk && rsiOk && strucOk)
      {
         double sl = ask - (atr * SL_ATR_Mult);
         double tp = ask + (atr * TP2_ATR_Mult);
         double lots = CalculateLots(ask - sl);

         if(lots > 0)
         {
            if(trade.Buy(lots, _Symbol, ask, sl, tp, "ORO_SCALPER_PRO_BUY"))
            {
               currentTicket  = trade.ResultOrder();
               partialClosed  = false;
               tradesThisDay++;
               pendingSignal  = 0;
               bosAlcista     = false;
               confirmCounter = 0;
               barsAfterClose = 0;
               if(ShowLogs) Print("BUY abierto. Ticket: ", currentTicket,
                                  " | Lots: ", lots, " | SL: ", sl, " | TP: ", tp);
            }
            else
               if(ShowLogs) Print("Error abriendo BUY: ", GetLastError());
         }
      }
      else
      {
         // Señal inválida, resetear
         if(confirmCounter > ConfirmBars + 3)
         {
            pendingSignal = 0;
            bosAlcista = false;
            if(ShowLogs) Print("Señal BUY expirada. Condiciones no se cumplieron.");
         }
      }
   }

   // SEÑAL DE VENTA
   else if(pendingSignal == -1 && EnableSell)
   {
      bool trendOk  = (emaFast < emaSlow);                            // EMA20 < EMA50 = tendencia bajista local
      bool macroOk  = (bid < emaTrend);                               // Precio por debajo de EMA200 M15
      bool rsiOk    = (rsi >= RSI_BearMin && rsi <= RSI_BearMax);     // RSI en zona válida (no sobrevendido)
      bool strucOk  = (bosBajista);                                    // BOS bajista confirmado

      if(ShowLogs)
         Print("EVALUANDO SELL | Trend:", trendOk, " Macro:", macroOk,
               " RSI:", DoubleToString(rsi, 1), "(ok:", rsiOk, ")", " BOS:", strucOk);

      if(trendOk && macroOk && rsiOk && strucOk)
      {
         double sl   = bid + (atr * SL_ATR_Mult);
         double tp   = bid - (atr * TP2_ATR_Mult);
         double lots = CalculateLots(sl - bid);

         if(lots > 0)
         {
            if(trade.Sell(lots, _Symbol, bid, sl, tp, "ORO_SCALPER_PRO_SELL"))
            {
               currentTicket  = trade.ResultOrder();
               partialClosed  = false;
               tradesThisDay++;
               pendingSignal  = 0;
               bosBajista     = false;
               confirmCounter = 0;
               barsAfterClose = 0;
               if(ShowLogs) Print("SELL abierto. Ticket: ", currentTicket,
                                  " | Lots: ", lots, " | SL: ", sl, " | TP: ", tp);
            }
            else
               if(ShowLogs) Print("Error abriendo SELL: ", GetLastError());
         }
      }
      else
      {
         if(confirmCounter > ConfirmBars + 3)
         {
            pendingSignal = 0;
            bosBajista = false;
            if(ShowLogs) Print("Señal SELL expirada. Condiciones no se cumplieron.");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Gestionar posición abierta (trailing + cierre parcial)            |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   if(!PositionSelectByTicket(currentTicket)) return;

   double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl         = PositionGetDouble(POSITION_SL);
   double tp         = PositionGetDouble(POSITION_TP);
   double volume     = PositionGetDouble(POSITION_VOLUME);
   int    posType    = (int)PositionGetInteger(POSITION_TYPE);
   double atr        = bufATR[1];
   double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Cierre parcial al llegar a TP1 (primera meta)
   if(UsePartialClose && !partialClosed)
   {
      double tp1 = 0;
      if(posType == POSITION_TYPE_BUY)
         tp1 = openPrice + (atr * TP1_ATR_Mult);
      else
         tp1 = openPrice - (atr * TP1_ATR_Mult);

      bool tp1Reached = (posType == POSITION_TYPE_BUY && bid >= tp1) ||
                        (posType == POSITION_TYPE_SELL && ask <= tp1);

      if(tp1Reached && volume > 0.01)
      {
         double closeVolume = NormalizeDouble(volume / 2.0, 2);
         if(closeVolume < 0.01) closeVolume = 0.01;

         if(trade.PositionClosePartial(currentTicket, closeVolume))
         {
            partialClosed = true;
            // Mover SL a breakeven
            double newSL = openPrice + (posType == POSITION_TYPE_BUY ? 2 * pipValue : -2 * pipValue);
            trade.PositionModify(currentTicket, newSL, tp);
            if(ShowLogs) Print("Cierre parcial ejecutado. SL movido a breakeven: ", newSL);
         }
      }
   }

   // Trailing stop (activo solo después del cierre parcial)
   if(partialClosed)
   {
      double trailDist = atr * 1.5;
      double newSL     = 0;

      if(posType == POSITION_TYPE_BUY)
      {
         newSL = bid - trailDist;
         if(newSL > sl && newSL > openPrice)
         {
            newSL = NormalizeDouble(newSL, _Digits);
            trade.PositionModify(currentTicket, newSL, tp);
            if(ShowLogs) Print("Trailing BUY. Nuevo SL: ", newSL);
         }
      }
      else
      {
         newSL = ask + trailDist;
         if(newSL < sl && newSL < openPrice)
         {
            newSL = NormalizeDouble(newSL, _Digits);
            trade.PositionModify(currentTicket, newSL, tp);
            if(ShowLogs) Print("Trailing SELL. Nuevo SL: ", newSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calcular tamaño del lote según riesgo                             |
//+------------------------------------------------------------------+
double CalculateLots(double slDistance)
{
   if(slDistance <= 0) return 0;

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double useBalance = MathMin(balance, equity);
   double riskAmount = useBalance * RiskPercent / 100.0;

   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickVal <= 0 || tickSize <= 0) return 0;

   // El dimensionado y el techo de riesgo los decide la guarda compartida:
   // devuelve 0 si el lote minimo obligaria a arriesgar mas de lo permitido.
   double lotsCalc = GMLotGuard(slDistance, riskAmount,
                                InpLG_MaxRiskPct, InpLG_MaxOverTarget,
                                "GRIDOP", !ShowLogs);
   if(lotsCalc <= 0.0) return 0;

   if(ShowLogs) Print("Lotaje calculado: ", lotsCalc, " | Riesgo $", DoubleToString(riskAmount, 2),
                      " | SL dist: ", DoubleToString(slDistance / pipValue, 1), " pips");

   return NormalizeDouble(lotsCalc, 2);
}

//+------------------------------------------------------------------+
//| Verificar si hay posición activa del EA                           |
//+------------------------------------------------------------------+
bool PositionExists()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetTicket(i) > 0)
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            currentTicket = PositionGetTicket(i);
            return true;
         }
      }
   }
   currentTicket = 0;
   return false;
}

//+------------------------------------------------------------------+
//| Verificar si la sesión está activa                                |
//+------------------------------------------------------------------+
bool IsSessionActive()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;

   bool inLondon = TradeLondon && (h >= London_Start && h < London_End);
   bool inNY     = TradeNY     && (h >= NY_Start     && h < NY_End);

   return (inLondon || inNY);
}

//+------------------------------------------------------------------+
//| Resetear contador diario de trades                                |
//+------------------------------------------------------------------+
void ResetDailyCounter()
{
   MqlDateTime today;
   TimeToStruct(TimeGMT(), today);

   MqlDateTime lastDay;
   TimeToStruct(lastDayChecked, lastDay);

   if(today.day != lastDay.day || today.mon != lastDay.mon)
   {
      tradesThisDay  = 0;
      lastDayChecked = TimeGMT();
      bosAlcista     = false;
      bosBajista     = false;
      pendingSignal  = 0;
      confirmCounter = 0;
      if(ShowLogs) Print("Nuevo día. Contador de trades reseteado.");
   }
}
//+------------------------------------------a------------------------+