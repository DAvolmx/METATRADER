//+------------------------------------------------------------------+
//|                                       BoomerHangLogic_Deriv.mq5  |
//|                          EA para Boom 1000 (Deriv) - v3.1        |
//|                          Lógica: Spike → Espera → Retroceso → SELL|
//+------------------------------------------------------------------+
#property copyright "Generado para el usuario"
#property version   "3.10"
#property description "Detecta spikes alcistas en Boom 1000 y opera el retroceso post-spike"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

//+------------------------------------------------------------------+
//| ENTRADA DE PARÁMETROS                                            |
//+------------------------------------------------------------------+
input group "=== Gestión de Riesgo ==="
input double   InpLotSize           = 0.2;     // Lote (Deriv mínimo: 0.2)
input double   InpSLPercent         = 0.30;    // Stop Loss (% del precio, 0=sin SL)
input double   InpTPPercent         = 0.20;    // Take Profit (% del precio, 0=sin TP)
input double   InpTrailStartPercent = 0.10;    // Inicio de trailing (% del precio)
input double   InpTrailStepPercent  = 0.05;    // Paso del trailing (% del precio)

input group "=== Detección del Spike (Vela M1) ==="
input double   InpSpikeCandlePercent = 0.05;   // Cuerpo mínimo de vela M1 (% del precio)
input int      InpSpikeLookback      = 3;      // Velas M1 a revisar
input bool     InpRequireCloseAbove  = true;   // Requerir vela alcista

input group "=== Confirmación de Retroceso ==="
input int      InpMinBarsAfterSpike  = 1;      // Velas M1 mínimas post-spike
input int      InpMaxBarsAfterSpike  = 30;     // Velas M1 máximas post-spike
input double   InpMinRetracePercent  = 0.02;   // Retroceso mínimo (%)
input double   InpMaxRetracePercent  = 0.50;   // Retroceso máximo (%)

input group "=== Filtros ==="
input int      InpMaxSpreadPoints    = 20000;  // Spread máximo (puntos)
input bool     InpSkipSpreadFilter   = true;   // *** CLAVE: Ignorar filtro de spread (para backtest) ***

input group "=== Protección ==="
input int      InpMaxTradesPerDay    = 3;      // Máximo operaciones/día
input double   InpDailyLossLimit     = 5.0;    // Pérdida máxima diaria (%)
input int      InpMaxConsecLosses    = 3;      // Pérdidas consecutivas antes de pausar
input int      InpPauseMinutes       = 120;    // Pausa en minutos

input group "=== Configuración ==="
input int      InpMaxMinutesInTrade  = 120;    // Tiempo máximo en operación (min)
input long     InpMagicNumber        = 20260424;
input bool     InpVerboseLog         = true;

//+------------------------------------------------------------------+
//| VARIABLES GLOBALES                                               |
//+------------------------------------------------------------------+
struct SStats
{
   int      spikesDetected;
   int      tradesOpened;
   int      tradesWon;
   int      tradesLost;
   double   grossProfit;
   double   grossLoss;
   int      consecutiveLosses;
   datetime lastLossTime;
   datetime lastTradeDay;
   int      tradesToday;
   double   dailyStartBalance;
   bool     dailyTargetReached;
   bool     dailyLimitReached;
};

SStats  stats;
datetime g_lastBarTime = 0;
double   g_spikeHigh   = 0.0;
int      g_barsSinceSpike = 0;
bool     g_spikeActive = false;
double   g_lastBid     = 0.0;

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!symInfo.Name(_Symbol))
   {
      Print("ERROR: No se pudo inicializar el símbolo");
      return(INIT_FAILED);
   }
   symInfo.RefreshRates();
   
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();
   
   ZeroMemory(stats);
   stats.dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   Print("╔══════════════════════════════════════════════════════════════╗");
   Print("║  BoomerHangLogic v3.1 — Deriv Boom 1000                    ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ Símbolo:        ", _Symbol);
   Print("║ Point:          ", _Point, " | Digits: ", _Digits);
   Print("║ Spread actual:  ", SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), " puntos");
   Print("║ Lote:           ", InpLotSize);
   Print("║ Spike umbral:   ", InpSpikeCandlePercent, "% del precio");
   Print("║ Skip Spread:    ", InpSkipSpreadFilter ? "SÍ (backtest)" : "NO");
   Print("╚══════════════════════════════════════════════════════════════╝");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("╔══════════════════════════════════════════════════════════════╗");
   Print("║  ESTADÍSTICAS FINALES                                       ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ Spikes detectados:  ", stats.spikesDetected);
   Print("║ Operaciones:        ", stats.tradesOpened);
   Print("║ Ganadas:            ", stats.tradesWon);
   Print("║ Perdidas:           ", stats.tradesLost);
   
   double winRate = (stats.tradesOpened > 0) 
      ? (double)stats.tradesWon / stats.tradesOpened * 100.0 : 0.0;
   Print("║ Win Rate:           ", DoubleToString(winRate, 2), "%");
   
   double pf = (stats.grossLoss != 0) ? MathAbs(stats.grossProfit / stats.grossLoss) : 0.0;
   Print("║ Profit Factor:      ", DoubleToString(pf, 2));
   Print("║ Balance final:      ", AccountInfoDouble(ACCOUNT_BALANCE));
   Print("╚══════════════════════════════════════════════════════════════╝");
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!symInfo.RefreshRates()) return;
   
   datetime currentBarTime = iTime(_Symbol, PERIOD_M1, 0);
   bool newBar = (currentBarTime != g_lastBarTime);
   
   ManageOpenPositions();
   CheckDailyReset();
   
   if(!newBar) return;
   g_lastBarTime = currentBarTime;
   
   if(!CanTrade()) return;
   if(HasOpenPosition()) return;
   
   if(!g_spikeActive)
      DetectSpikeOnCandle();
   
   if(g_spikeActive)
      MonitorRetracementOnCandle();
}

//+------------------------------------------------------------------+
//| Detecta spike en velas M1                                        |
//+------------------------------------------------------------------+
void DetectSpikeOnCandle()
{
   for(int i = 1; i <= InpSpikeLookback; i++)
   {
      double open  = iOpen(_Symbol, PERIOD_M1, i);
      double close = iClose(_Symbol, PERIOD_M1, i);
      double high  = iHigh(_Symbol, PERIOD_M1, i);
      
      if(open <= 0.0) continue;
      
      double bodyPercent = ((close - open) / open) * 100.0;
      bool isBullish = (close > open);
      bool isBigEnough = (bodyPercent >= InpSpikeCandlePercent);
      bool closeCondition = (!InpRequireCloseAbove || isBullish);
      
      if(isBigEnough && closeCondition)
      {
         stats.spikesDetected++;
         g_spikeActive = true;
         g_spikeHigh = high;
         g_barsSinceSpike = 0;
         g_lastBid = symInfo.Bid();
         
         if(InpVerboseLog)
            Print(">>> SPIKE #", stats.spikesDetected, 
                  " | Cuerpo: ", DoubleToString(bodyPercent, 3), 
                  "% | High: ", DoubleToString(high, _Digits));
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Monitorea retroceso                                              |
//+------------------------------------------------------------------+
void MonitorRetracementOnCandle()
{
   g_barsSinceSpike++;
   
   if(g_barsSinceSpike < InpMinBarsAfterSpike) return;
   
   if(g_barsSinceSpike > InpMaxBarsAfterSpike)
   {
      ResetSpike();
      return;
   }
   
   double currentBid = symInfo.Bid();
   double currentHigh = iHigh(_Symbol, PERIOD_M1, 0);
   if(currentHigh > g_spikeHigh) g_spikeHigh = currentHigh;
   
   double retracePercent = ((g_spikeHigh - currentBid) / g_spikeHigh) * 100.0;
   
   if(retracePercent < InpMinRetracePercent)
   {
      g_lastBid = currentBid;
      return;
   }
   
   if(retracePercent > InpMaxRetracePercent)
   {
      ResetSpike();
      return;
   }
   
   if(currentBid >= g_lastBid)
   {
      g_lastBid = currentBid;
      return;
   }
   g_lastBid = currentBid;
   
   // *** SPREAD FILTER - Se salta en backtest ***
   if(!InpSkipSpreadFilter)
   {
      double spreadPoints = (symInfo.Ask() - symInfo.Bid()) / _Point;
      if(spreadPoints > InpMaxSpreadPoints)
      {
         if(InpVerboseLog)
            Print("<<< Spread alto: ", DoubleToString(spreadPoints, 0), " pts");
         ResetSpike();
         return;
      }
   }
   
   ExecuteSell(retracePercent);
}

//+------------------------------------------------------------------+
//| Ejecuta SELL                                                     |
//+------------------------------------------------------------------+
void ExecuteSell(double retracePercent)
{
   double entryPrice = symInfo.Bid();
   double sl = 0.0;
   double tp = 0.0;
   
   if(InpSLPercent > 0)
      sl = NormalizeDouble(entryPrice * (1.0 + InpSLPercent / 100.0), _Digits);
   
   if(InpTPPercent > 0)
      tp = NormalizeDouble(entryPrice * (1.0 - InpTPPercent / 100.0), _Digits);
   
   if(trade.Sell(InpLotSize, _Symbol, entryPrice, sl, tp, "BoomerHang v3.1"))
   {
      stats.tradesOpened++;
      stats.tradesToday++;
      
      Print(">>> SELL #", stats.tradesOpened,
            " | Lote: ", InpLotSize,
            " | Precio: ", DoubleToString(entryPrice, _Digits),
            " | Retroceso: ", DoubleToString(retracePercent, 3), "%",
            " | SL: ", DoubleToString(sl, _Digits),
            " | TP: ", DoubleToString(tp, _Digits));
      
      ResetSpike();
   }
   else
   {
      Print("ERROR SELL: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      ResetSpike();
   }
}

//+------------------------------------------------------------------+
//| Gestión de posiciones (trailing + tiempo)                        |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic() != InpMagicNumber) continue;
      
      ulong ticket = posInfo.Ticket();
      
      if(InpMaxMinutesInTrade > 0)
      {
         int minutesOpen = (int)((TimeCurrent() - (datetime)posInfo.Time()) / 60);
         if(minutesOpen >= InpMaxMinutesInTrade)
         {
            trade.PositionClose(ticket);
            continue;
         }
      }
      
      if(InpTrailStartPercent > 0 && InpTrailStepPercent > 0)
         ApplyTrailingStop(ticket);
   }
}

//+------------------------------------------------------------------+
//| Trailing Stop                                                    |
//+------------------------------------------------------------------+
void ApplyTrailingStop(ulong ticket)
{
   if(!posInfo.SelectByTicket(ticket)) return;
   
   double entryPrice = posInfo.PriceOpen();
   double currentSL  = posInfo.StopLoss();
   double currentBid = symInfo.Bid();
   double profitPercent = ((entryPrice - currentBid) / entryPrice) * 100.0;
   
   if(profitPercent < InpTrailStartPercent) return;
   
   double newSL = NormalizeDouble(currentBid * (1.0 + InpTrailStepPercent / 100.0), _Digits);
   
   if((currentSL == 0.0 || newSL < currentSL) && newSL < entryPrice)
      trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
}

//+------------------------------------------------------------------+
//| Utilidades                                                       |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
         return true;
   }
   return false;
}

bool CanTrade()
{
   if(stats.tradesToday >= InpMaxTradesPerDay) return false;
   if(stats.dailyTargetReached || stats.dailyLimitReached) return false;
   
   if(stats.consecutiveLosses >= InpMaxConsecLosses)
   {
      int minutesSinceLoss = (int)((TimeCurrent() - stats.lastLossTime) / 60);
      if(minutesSinceLoss < InpPauseMinutes) return false;
      stats.consecutiveLosses = 0;
   }
   return true;
}

void CheckDailyReset()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   
   if(today != stats.lastTradeDay)
   {
      stats.lastTradeDay = today;
      stats.tradesToday = 0;
      stats.dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      stats.dailyTargetReached = false;
      stats.dailyLimitReached = false;
      stats.consecutiveLosses = 0;
   }
   
   double dailyPnLPercent = ((AccountInfoDouble(ACCOUNT_BALANCE) - stats.dailyStartBalance) 
                             / stats.dailyStartBalance) * 100.0;
   
   if(dailyPnLPercent <= -InpDailyLossLimit) stats.dailyLimitReached = true;
}

void ResetSpike()
{
   g_spikeActive = false;
   g_spikeHigh = 0.0;
   g_barsSinceSpike = 0;
   g_lastBid = 0.0;
}

//+------------------------------------------------------------------+
//| OnTradeTransaction — estadísticas                                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;
   
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   profit += HistoryDealGetDouble(trans.deal, DEAL_SWAP);
   profit += HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   
   if(profit > 0)
   {
      stats.tradesWon++;
      stats.grossProfit += profit;
      stats.consecutiveLosses = 0;
   }
   else if(profit < 0)
   {
      stats.tradesLost++;
      stats.grossLoss += MathAbs(profit);
      stats.consecutiveLosses++;
      stats.lastLossTime = TimeCurrent();
   }
}