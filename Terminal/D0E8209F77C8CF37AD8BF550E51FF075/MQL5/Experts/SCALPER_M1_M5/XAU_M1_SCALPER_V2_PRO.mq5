//+──────────────────────────────────────────────────────────────────────────+
//│  XAU_M1_SCALPER_V2_PRO.mq5                                              │
//│  Scalping XAUUSD M1 — Auto-Detect MICRO/NORMAL + Multi-Filter Trend     │
//│                                                                          │
//│  MEJORAS vs V1:                                                          │
//│  ─────────────────────────────────────────────────────────────────────  │
//│  1. AUTO-DETECT cuenta: si lote mín broker ≥ 0.1 → modo MICRO           │
//│     En micro: MinLot=0.10, cálculo de riesgo ajustado, panel avisa      │
//│  2. HTF Trend Cascade (3 capas):                                         │
//│     · M15: EMA(20/50) + ADX(14) — tendencia primaria                   │
//│     · H1 : EMA(50/200) — sesgo macro                                   │
//│     · M5 : EMA(9/21) + MACD — momentum intermedio                      │
//│     Las 3 deben coincidir para permitir entrada                          │
//│  3. Bollinger Bands — no entrar cuando precio en banda media (rango)    │
//│  4. Stochastic(5,3,3) — confirmación sobrecompra/sobreventa             │
//│  5. Vela de confirmación: body > wick (vela limpia, sin trampas)        │
//│  6. Filtro de sesión UTC: London 07-11, NY 13-17                        │
//│  7. Trailing throttle: modifica SL sólo 1× por barra M1                │
//│  8. Margin pre-check antes de abrir orden (evita error 10019)           │
//│  9. Cooldown: barra de espera tras cerrar posición                      │
//│ 10. ATR máximo: no operar en caos (ATR > MaxATR_USD)                   │
//│ 11. Daily loss limit: para cuando pérdida diaria excede límite          │
//│ 12. Divergencia ADX/DI: +DI/-DI deben superar umbral mínimo            │
//+──────────────────────────────────────────────────────────────────────────+
#property copyright "XAU M1 Scalper v2 PRO — XAUUSD"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//════════════════════════════════════════════════════════
//  INPUTS
//════════════════════════════════════════════════════════

input group "=== 🛡️  SEGURIDAD ==="
input bool   PaperMode         = true;   // true = simulación, sin órdenes reales
input bool   ShowLogs          = true;
input ulong  MagicNumber       = 26061002;
input bool   EnableBuy         = true;
input bool   EnableSell        = true;

input group "=== 💰 RIESGO ==="
input double RiskPercent       = 0.50;   // % balance por operación
input double MaxLot            = 1.00;   // techo de lote (normal=1.0, micro depende del broker)
input int    MaxSpreadPoints   = 80;
input int    SlippagePoints    = 30;
input double MaxDailyLossPct   = 3.0;   // % pérdida diaria máxima

input group "=== 📊 EMAs M1 (entrada) ==="
input int    FastEMA           = 9;
input int    SlowEMA           = 21;
input int    TrendEMA          = 100;

input group "=== 🔭 HTF LAYER 1 — M15 Tendencia primaria ==="
input bool   UseM15Filter      = true;
input int    M15_EMA_Fast      = 20;
input int    M15_EMA_Slow      = 50;
input int    M15_ADX_Period    = 14;
input double M15_ADX_Min       = 22.0;

input group "=== 🔭 HTF LAYER 2 — H1 Sesgo macro ==="
input bool   UseH1Filter       = true;
input int    H1_EMA_Fast       = 50;
input int    H1_EMA_Slow       = 200;

input group "=== 🔭 HTF LAYER 3 — M5 Momentum intermedio ==="
input bool   UseM5Filter       = true;
input int    M5_EMA_Fast       = 9;
input int    M5_EMA_Slow       = 21;
input int    M5_MACD_Fast      = 12;
input int    M5_MACD_Slow      = 26;
input int    M5_MACD_Signal    = 9;

input group "=== 📐 RSI M1 ==="
input int    RSIPeriod         = 14;
input double RSI_Buy_Min       = 50.0;
input double RSI_Buy_Max       = 72.0;
input double RSI_Sell_Min      = 28.0;
input double RSI_Sell_Max      = 50.0;

input group "=== 📈 ADX M1 ==="
input int    ADXPeriod         = 14;
input double MinADX            = 22.0;
input double MinDI_Diff        = 3.0;   // diferencia mínima +DI/-DI para confirmar dirección

input group "=== 🎸 STOCHASTIC (confirmación sobrecompra/venta) ==="
input bool   UseStoch          = true;
input int    StochK            = 5;
input int    StochD            = 3;
input int    StochSlowing      = 3;
input double Stoch_Buy_Max     = 75.0;  // BUY sólo si Stoch < este valor (no sobrecomprado)
input double Stoch_Sell_Min    = 25.0;  // SELL sólo si Stoch > este valor (no sobrevendido)

input group "=== 📉 BOLLINGER BANDS (filtro de rango) ==="
input bool   UseBB             = true;
input int    BB_Period         = 20;
input double BB_Dev            = 2.0;
input double BB_Width_Min_ATR  = 0.5;   // BB debe ser > X×ATR para no estar en rango

input group "=== ⚡ ATR / VOLATILIDAD ==="
input int    ATRPeriod         = 14;
input double SL_ATR            = 1.30;
input double TP_ATR            = 2.20;
input double MinATR_USD        = 0.60;  // ATR mínimo (mercado activo)
input double MaxATR_USD        = 20.0;  // ATR máximo (caos, no operar)

input group "=== 🔧 GESTIÓN DE POSICIÓN ==="
input bool   UseBreakEven      = true;
input double BreakEvenATR      = 0.80;
input bool   UseTrailing       = true;
input double TrailStartATR     = 1.00;
input double TrailATR          = 0.70;

input group "=== 📅 SESIÓN UTC ==="
input bool   UseSessionFilter  = true;
input int    London_Start      = 7;
input int    London_End        = 11;
input int    NY_Start          = 13;
input int    NY_End            = 17;

input group "=== ♻️ CONTROL ==="
input bool   OnlyNewCandle     = true;
input int    CooldownBars      = 3;     // barras M1 de espera tras cerrar

//════════════════════════════════════════════════════════
//  HANDLES
//════════════════════════════════════════════════════════
// M1
int hFastEMA, hSlowEMA, hTrendEMA;
int hRSI, hADX, hATR;
int hStoch;
int hBB;

// M15
int hM15_EMAFast, hM15_EMASlow, hM15_ADX;

// H1
int hH1_EMAFast, hH1_EMASlow;

// M5
int hM5_EMAFast, hM5_EMASlow, hM5_MACD;

//════════════════════════════════════════════════════════
//  ESTADO GLOBAL
//════════════════════════════════════════════════════════
datetime g_lastBarTime  = 0;
datetime g_lastTrailBar = 0;
int      g_barsSinceClose = 999;
double   g_dayStartBalance = 0;
datetime g_today = 0;
bool     g_isMicro = false;   // auto-detectado en OnInit
double   g_minLot  = 0.01;

void Log(string s) { if(ShowLogs) PrintFormat("[XAU_V2] %s", s); }

//════════════════════════════════════════════════════════
//  INIT
//════════════════════════════════════════════════════════
int OnInit() {
   // ── Auto-detect MICRO vs NORMAL ─────────────────────
   g_minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_isMicro = (g_minLot >= 0.10);
   Log(StringFormat("Cuenta detectada: %s | Lote mín: %.2f",
       g_isMicro ? "🔬 MICRO (min 0.10)" : "📊 NORMAL (min 0.01)", g_minLot));

   if(_Period != PERIOD_M1)
      Print("ADVERTENCIA: diseñado para M1.");

   // Handles M1
   hFastEMA  = iMA(_Symbol, PERIOD_M1, FastEMA,  0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA  = iMA(_Symbol, PERIOD_M1, SlowEMA,  0, MODE_EMA, PRICE_CLOSE);
   hTrendEMA = iMA(_Symbol, PERIOD_M1, TrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI      = iRSI(_Symbol, PERIOD_M1, RSIPeriod, PRICE_CLOSE);
   hADX      = iADX(_Symbol, PERIOD_M1, ADXPeriod);
   hATR      = iATR(_Symbol, PERIOD_M1, ATRPeriod);
   hStoch    = iStochastic(_Symbol, PERIOD_M1, StochK, StochD, StochSlowing, MODE_SMA, STO_LOWHIGH);
   hBB       = iBands(_Symbol, PERIOD_M1, BB_Period, 0, BB_Dev, PRICE_CLOSE);

   // Handles M15
   hM15_EMAFast = iMA(_Symbol, PERIOD_M15, M15_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hM15_EMASlow = iMA(_Symbol, PERIOD_M15, M15_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hM15_ADX     = iADX(_Symbol, PERIOD_M15, M15_ADX_Period);

   // Handles H1
   hH1_EMAFast = iMA(_Symbol, PERIOD_H1, H1_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hH1_EMASlow = iMA(_Symbol, PERIOD_H1, H1_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   // Handles M5
   hM5_EMAFast = iMA(_Symbol, PERIOD_M5, M5_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hM5_EMASlow = iMA(_Symbol, PERIOD_M5, M5_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hM5_MACD    = iMACD(_Symbol, PERIOD_M5, M5_MACD_Fast, M5_MACD_Slow, M5_MACD_Signal, PRICE_CLOSE);

   if(hFastEMA==INVALID_HANDLE || hSlowEMA==INVALID_HANDLE || hTrendEMA==INVALID_HANDLE ||
      hRSI==INVALID_HANDLE || hADX==INVALID_HANDLE || hATR==INVALID_HANDLE ||
      hStoch==INVALID_HANDLE || hBB==INVALID_HANDLE ||
      hM15_EMAFast==INVALID_HANDLE || hM15_EMASlow==INVALID_HANDLE || hM15_ADX==INVALID_HANDLE ||
      hH1_EMAFast==INVALID_HANDLE  || hH1_EMASlow==INVALID_HANDLE ||
      hM5_EMAFast==INVALID_HANDLE  || hM5_EMASlow==INVALID_HANDLE || hM5_MACD==INVALID_HANDLE) {
      Print("ERROR creando handles de indicadores.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(PaperMode) Log("⚠️  PAPER MODE — sin órdenes reales");
   Log(StringFormat("Iniciado | Balance: %.2f | MaxLot: %.2f", g_dayStartBalance, MaxLot));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   IndicatorRelease(hFastEMA);  IndicatorRelease(hSlowEMA);  IndicatorRelease(hTrendEMA);
   IndicatorRelease(hRSI);      IndicatorRelease(hADX);       IndicatorRelease(hATR);
   IndicatorRelease(hStoch);    IndicatorRelease(hBB);
   IndicatorRelease(hM15_EMAFast); IndicatorRelease(hM15_EMASlow); IndicatorRelease(hM15_ADX);
   IndicatorRelease(hH1_EMAFast);  IndicatorRelease(hH1_EMASlow);
   IndicatorRelease(hM5_EMAFast);  IndicatorRelease(hM5_EMASlow);  IndicatorRelease(hM5_MACD);
}

//════════════════════════════════════════════════════════
//  HELPER: obtener valor de buffer
//════════════════════════════════════════════════════════
double Val(int handle, int buffer, int shift) {
   double data[];
   ArraySetAsSeries(data, true);
   if(CopyBuffer(handle, buffer, shift, 1, data) <= 0) return EMPTY_VALUE;
   return data[0];
}

//════════════════════════════════════════════════════════
//  HELPER: nueva barra M1
//════════════════════════════════════════════════════════
bool IsNewBar() {
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t != g_lastBarTime) { g_lastBarTime = t; return true; }
   return false;
}

//════════════════════════════════════════════════════════
//  HELPER: spread OK
//════════════════════════════════════════════════════════
bool SpreadOK() {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return false;
   return ((ask - bid) / _Point <= MaxSpreadPoints);
}

//════════════════════════════════════════════════════════
//  HELPER: ¿hay posición de este EA?
//════════════════════════════════════════════════════════
bool HasPosition() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber) return true;
   }
   return false;
}

//════════════════════════════════════════════════════════
//  HELPER: sesión activa
//════════════════════════════════════════════════════════
bool InSession() {
   if(!UseSessionFilter) return true;
   MqlDateTime d; TimeToStruct(TimeGMT(), d);
   return (d.hour >= London_Start && d.hour < London_End) ||
          (d.hour >= NY_Start     && d.hour < NY_End);
}

//════════════════════════════════════════════════════════
//  HELPER: normalizar lote (respeta micro)
//════════════════════════════════════════════════════════
double NormalizeLot(double lot) {
   double minL  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL  = MathMin(MaxLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));
   double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0) lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, minL);
   lot = MathMin(lot, maxL);
   return NormalizeDouble(lot, 2);
}

//════════════════════════════════════════════════════════
//  HELPER: calcular lote según riesgo
//════════════════════════════════════════════════════════
double CalculateLot(double entry, double stop) {
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * RiskPercent / 100.0;
   double distance  = MathAbs(entry - stop);
   if(distance <= 0) return g_minLot;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return g_minLot;
   double moneyPerLot = (distance / tickSize) * tickValue;
   if(moneyPerLot <= 0) return g_minLot;
   return NormalizeLot(riskMoney / moneyPerLot);
}

//════════════════════════════════════════════════════════
//  HELPER: distancia stop mínima broker
//════════════════════════════════════════════════════════
double MinStopDist() {
   return SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
}

//════════════════════════════════════════════════════════
//  HELPER: margin pre-check (evita error 10019)
//════════════════════════════════════════════════════════
bool HasEnoughMargin(double lots, int dir) {
   double price = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double req = 0;
   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcMargin(ot, _Symbol, lots, price, req)) return false;
   double free = AccountInfoDouble(ACCOUNT_FREEMARGIN);
   if(free < req * 1.3) {
      Log(StringFormat("⚠️  Margen insuf: libre=%.2f req=%.2f×1.3=%.2f", free, req, req*1.3));
      return false;
   }
   return true;
}

//════════════════════════════════════════════════════════
//  HTF CASCADE FILTER
//  Retorna: +1 alcista, -1 bajista, 0 sin tendencia (bloquear)
//════════════════════════════════════════════════════════
int HTF_CascadeBias() {
   int score = 0;

   // ── LAYER 1: M15 EMA(20/50) + ADX ──────────────────
   if(UseM15Filter) {
      double m15f = Val(hM15_EMAFast, 0, 1);
      double m15s = Val(hM15_EMASlow, 0, 1);
      double m15f2= Val(hM15_EMAFast, 0, 2);
      double adx15= Val(hM15_ADX, 0, 1);
      if(m15f==EMPTY_VALUE || m15s==EMPTY_VALUE || adx15==EMPTY_VALUE) return 0;
      if(adx15 < M15_ADX_Min) {
         Log(StringFormat("M15 ADX=%.1f < %.0f → ranging", adx15, M15_ADX_Min));
         return 0;  // sin tendencia = bloqueo total
      }
      bool m15bull = (m15f > m15s) && (m15f > m15f2);
      bool m15bear = (m15f < m15s) && (m15f < m15f2);
      if(m15bull)       score++;
      else if(m15bear)  score--;
      else return 0;
   }

   // ── LAYER 2: H1 EMA(50/200) ─────────────────────────
   if(UseH1Filter) {
      double h1f = Val(hH1_EMAFast, 0, 1);
      double h1s = Val(hH1_EMASlow, 0, 1);
      if(h1f==EMPTY_VALUE || h1s==EMPTY_VALUE) return 0;
      bool h1bull = (h1f > h1s);
      bool h1bear = (h1f < h1s);
      if(h1bull && score > 0)       {}               // confirma alcista
      else if(h1bear && score < 0)  {}               // confirma bajista
      else return 0;                                  // H1 y M15 no coinciden → bloqueo
   }

   // ── LAYER 3: M5 EMA(9/21) + MACD ───────────────────
   if(UseM5Filter) {
      double m5f  = Val(hM5_EMAFast, 0, 1);
      double m5s  = Val(hM5_EMASlow, 0, 1);
      double macd = Val(hM5_MACD, 0, 1);   // línea MACD
      double sig  = Val(hM5_MACD, 1, 1);   // línea señal
      if(m5f==EMPTY_VALUE || m5s==EMPTY_VALUE || macd==EMPTY_VALUE) return 0;
      bool m5bull = (m5f > m5s) && (macd > sig);
      bool m5bear = (m5f < m5s) && (macd < sig);
      if(score > 0 && !m5bull) { Log("M5 momentum no confirma alcista"); return 0; }
      if(score < 0 && !m5bear) { Log("M5 momentum no confirma bajista"); return 0; }
   }

   return (score > 0) ? 1 : (score < 0) ? -1 : 0;
}

//════════════════════════════════════════════════════════
//  GESTIÓN DE POSICIÓN — trailing 1× por barra M1
//════════════════════════════════════════════════════════
void ManagePosition() {
   double atr = Val(hATR, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0) return;

   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double newSL = sl;

      if(type == POSITION_TYPE_BUY) {
         double prof = bid - open;
         if(UseBreakEven && prof >= atr * BreakEvenATR && sl < open)
            newSL = open;
         // Trailing: throttle 1× por barra M1
         if(UseTrailing && prof >= atr * TrailStartATR) {
            datetime cur = iTime(_Symbol, PERIOD_M1, 0);
            if(cur != g_lastTrailBar) {
               g_lastTrailBar = cur;
               double trail = bid - atr * TrailATR;
               if(trail > newSL && trail > open) newSL = trail;
            }
         }
         newSL = NormalizeDouble(newSL, _Digits);
         if(newSL > sl && newSL < bid && !PaperMode)
            trade.PositionModify(ticket, newSL, tp);
      }

      if(type == POSITION_TYPE_SELL) {
         double prof = open - ask;
         if(UseBreakEven && prof >= atr * BreakEvenATR && (sl > open || sl == 0))
            newSL = open;
         if(UseTrailing && prof >= atr * TrailStartATR) {
            datetime cur = iTime(_Symbol, PERIOD_M1, 0);
            if(cur != g_lastTrailBar) {
               g_lastTrailBar = cur;
               double trail = ask + atr * TrailATR;
               if((trail < newSL || newSL == 0) && trail < open) newSL = trail;
            }
         }
         newSL = NormalizeDouble(newSL, _Digits);
         if((newSL < sl || sl == 0) && newSL > ask && !PaperMode)
            trade.PositionModify(ticket, newSL, tp);
      }
   }
}

//════════════════════════════════════════════════════════
//  ABRIR BUY
//════════════════════════════════════════════════════════
void OpenBuy(double atr) {
   if(!EnableBuy) return;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double slD  = MathMax(atr * SL_ATR, MinStopDist());
   double tpD  = MathMax(atr * TP_ATR, MinStopDist());
   double sl   = NormalizeDouble(ask - slD, _Digits);
   double tp   = NormalizeDouble(ask + tpD, _Digits);
   double lot  = CalculateLot(ask, sl);
   if(lot <= 0) return;
   if(!HasEnoughMargin(lot, 1)) return;

   Log(StringFormat("%s BUY lot=%.2f ask=%.3f sl=%.3f tp=%.3f | cuenta=%s",
       PaperMode?"[PAPER]":"", lot, ask, sl, tp, g_isMicro?"MICRO":"NORMAL"));
   if(PaperMode) return;

   if(!trade.Buy(lot, _Symbol, 0, sl, tp, "XAU_V2_BUY"))
      Log(StringFormat("BUY ERR %d: %s", trade.ResultRetcode(), trade.ResultRetcodeDescription()));
}

//════════════════════════════════════════════════════════
//  ABRIR SELL
//════════════════════════════════════════════════════════
void OpenSell(double atr) {
   if(!EnableSell) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slD  = MathMax(atr * SL_ATR, MinStopDist());
   double tpD  = MathMax(atr * TP_ATR, MinStopDist());
   double sl   = NormalizeDouble(bid + slD, _Digits);
   double tp   = NormalizeDouble(bid - tpD, _Digits);
   double lot  = CalculateLot(bid, sl);
   if(lot <= 0) return;
   if(!HasEnoughMargin(lot, -1)) return;

   Log(StringFormat("%s SELL lot=%.2f bid=%.3f sl=%.3f tp=%.3f | cuenta=%s",
       PaperMode?"[PAPER]":"", lot, bid, sl, tp, g_isMicro?"MICRO":"NORMAL"));
   if(PaperMode) return;

   if(!trade.Sell(lot, _Symbol, 0, sl, tp, "XAU_V2_SELL"))
      Log(StringFormat("SELL ERR %d: %s", trade.ResultRetcode(), trade.ResultRetcodeDescription()));
}

//════════════════════════════════════════════════════════
//  BUSCAR ENTRADA — multi-filtro
//════════════════════════════════════════════════════════
void CheckEntry() {
   if(HasPosition()) { g_barsSinceClose = 0; return; }
   g_barsSinceClose++;

   // ── Pre-filtros ────────────────────────────────────
   if(!SpreadOK())   { Log("Spread alto"); return; }
   if(!InSession())  { Log("Fuera de sesión"); return; }
   if(g_barsSinceClose < CooldownBars) {
      Log(StringFormat("Cooldown %d/%d", g_barsSinceClose, CooldownBars)); return;
   }

   // Control pérdida diaria
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != g_today) {
      g_today = today;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if((g_dayStartBalance - eq) / g_dayStartBalance * 100 >= MaxDailyLossPct) {
      Log("Daily loss limit alcanzado"); return;
   }

   // ATR
   double atr = Val(hATR, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0) return;
   if(atr < MinATR_USD) { Log(StringFormat("ATR %.2f bajo", atr)); return; }
   if(atr > MaxATR_USD) { Log(StringFormat("ATR %.2f caos", atr)); return; }

   // ── HTF CASCADE — debe coincidir las 3 capas ───────
   int htf = HTF_CascadeBias();
   if(htf == 0) { Log("HTF sin tendencia clara — skip"); return; }

   // ── Indicadores M1 (vela cerrada shift=1) ──────────
   double fast  = Val(hFastEMA,  0, 1);
   double slow  = Val(hSlowEMA,  0, 1);
   double trend = Val(hTrendEMA, 0, 1);
   double rsi   = Val(hRSI,      0, 1);
   double adx   = Val(hADX,      0, 1);
   double plusDI  = Val(hADX,    1, 1);
   double minusDI = Val(hADX,    2, 1);
   double stochK  = Val(hStoch,  0, 1);
   double bb_up   = Val(hBB,     1, 1);
   double bb_dn   = Val(hBB,     2, 1);
   double bb_mid  = Val(hBB,     0, 1);

   if(fast==EMPTY_VALUE || slow==EMPTY_VALUE || trend==EMPTY_VALUE || rsi==EMPTY_VALUE ||
      adx==EMPTY_VALUE  || stochK==EMPTY_VALUE) return;

   double close  = iClose(_Symbol, PERIOD_M1, 1);
   double openC  = iOpen (_Symbol, PERIOD_M1, 1);
   double high   = iHigh (_Symbol, PERIOD_M1, 1);
   double lowC   = iLow  (_Symbol, PERIOD_M1, 1);
   double body   = MathAbs(close - openC);
   double wick_u = high - MathMax(close, openC);
   double wick_d = MathMin(close, openC) - lowC;

   // Filtro BB: mercado en rango si banda < MinWidth
   bool bb_trending = true;
   if(UseBB && bb_up != EMPTY_VALUE && bb_dn != EMPTY_VALUE) {
      double bb_width = bb_up - bb_dn;
      if(bb_width < atr * BB_Width_Min_ATR) {
         Log(StringFormat("BB width %.2f < %.1f×ATR — rango", bb_width, BB_Width_Min_ATR));
         bb_trending = false;
      }
   }
   if(!bb_trending) return;

   // Vela limpia: body > wick máximo
   double max_wick = MathMax(wick_u, wick_d);
   bool cleanCandle = (body > max_wick * 0.5);  // body al menos 50% del wick

   //══════════════════════════════════════════
   //  BUY: todas las capas alcistas
   //══════════════════════════════════════════
   if(htf == 1) {
      bool m1Trend = (fast > slow) && (slow > trend) && (close > trend);
      bool rsiOk   = (rsi >= RSI_Buy_Min && rsi <= RSI_Buy_Max);
      bool adxOk   = (adx >= MinADX) && (plusDI - minusDI >= MinDI_Diff);
      bool stochOk = (!UseStoch) || (stochK <= Stoch_Buy_Max);
      bool bbOk    = (!UseBB)    || (close > bb_mid);    // precio encima de media BB
      bool bullCandle = (close > openC) && cleanCandle;

      Log(StringFormat("BUY eval | M1trend:%s RSI:%.1f[%s] ADX:%.1f+DI:%.1f[%s] Stoch:%.1f[%s] BB:%s vela:%s",
          m1Trend?"✓":"✗", rsi, rsiOk?"✓":"✗",
          adx, plusDI, adxOk?"✓":"✗",
          stochK, stochOk?"✓":"✗",
          bbOk?"✓":"✗", bullCandle?"✓":"✗"));

      if(m1Trend && rsiOk && adxOk && stochOk && bbOk && bullCandle) {
         OpenBuy(atr); return;
      }
   }

   //══════════════════════════════════════════
   //  SELL: todas las capas bajistas
   //══════════════════════════════════════════
   if(htf == -1) {
      bool m1Trend = (fast < slow) && (slow < trend) && (close < trend);
      bool rsiOk   = (rsi >= RSI_Sell_Min && rsi <= RSI_Sell_Max);
      bool adxOk   = (adx >= MinADX) && (minusDI - plusDI >= MinDI_Diff);
      bool stochOk = (!UseStoch) || (stochK >= Stoch_Sell_Min);
      bool bbOk    = (!UseBB)    || (close < bb_mid);    // precio debajo de media BB
      bool bearCandle = (close < openC) && cleanCandle;

      Log(StringFormat("SELL eval | M1trend:%s RSI:%.1f[%s] ADX:%.1f-DI:%.1f[%s] Stoch:%.1f[%s] BB:%s vela:%s",
          m1Trend?"✓":"✗", rsi, rsiOk?"✓":"✗",
          adx, minusDI, adxOk?"✓":"✗",
          stochK, stochOk?"✓":"✗",
          bbOk?"✓":"✗", bearCandle?"✓":"✗"));

      if(m1Trend && rsiOk && adxOk && stochOk && bbOk && bearCandle) {
         OpenSell(atr); return;
      }
   }
}

//════════════════════════════════════════════════════════
//  OnTick
//════════════════════════════════════════════════════════
void OnTick() {
   ManagePosition();

   if(OnlyNewCandle && !IsNewBar()) return;

   CheckEntry();
}
//+------------------------------------------------------------------+
