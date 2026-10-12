//+──────────────────────────────────────────────────────────────────────────+
//│  XAU_M1_SCALPER_V3_SCORE.mq5                                            │
//│  Scalping XAUUSD M1 — Sistema de Puntuación de Confluencia              │
//│                                                                          │
//│  PROBLEMA V2: AND de 8 filtros → EA nunca entraba / entraba tarde       │
//│  SOLUCIÓN  V3: scoring — entrar cuando puntos ≥ MinScore (default 5/8)  │
//│                                                                          │
//│  PUNTOS DISPONIBLES (max 8):                                             │
//│  ① HTF M15: EMA(20/50) + ADX alineados                  → 2 pts        │
//│  ② HTF H1 : EMA(50/200) mismo sesgo                      → 1 pt         │
//│  ③ M5  momentum: EMA(9/21) cruzadas correctamente        → 1 pt         │
//│  ④ M1  EMA stack (fast>slow>trend / close>trend)         → 1 pt         │
//│  ⑤ RSI en zona correcta (zona neutra-momentum)           → 1 pt         │
//│  ⑥ ADX M1 ≥ umbral + DI spread mínimo                   → 1 pt         │
//│  ⑦ Stochastic no sobreextendido                          → 1 pt         │
//│  ⑧ Bollinger: precio del lado correcto de la media        → 1 pt         │  (no exige ancho)
//│                                                                          │
//│  Filtros HARD (bloqueo absoluto, sin importar puntos):                  │
//│  · ADX M15 < M15_ADX_Min → ranging → no hay tendencia → stop total     │
//│  · ATR fuera de rango [Min,Max]                                         │
//│  · Spread excesivo                                                      │
//│  · Fuera de sesión                                                      │
//│  · Cooldown, Daily Loss, PaperMode                                      │
//│                                                                          │
//│  Auto-detect MICRO: si lote mín broker ≥ 0.10 → modo micro             │
//│  Trailing throttle: 1× por barra M1                                     │
//│  Margin pre-check: OrderCalcMargin×1.3 antes de cada orden             │
//│  PaperMode = true por defecto                                           │
//+──────────────────────────────────────────────────────────────────────────+
#property copyright "XAU M1 Scalper v3 SCORE — XAUUSD"
#property version   "3.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//════════════════════════════════════════════════════════
//  INPUTS
//════════════════════════════════════════════════════════

input group "=== 🛡️  SEGURIDAD ==="
input bool   PaperMode         = true;
input bool   ShowLogs          = true;
input ulong  MagicNumber       = 26061003;
input bool   EnableBuy         = true;
input bool   EnableSell        = true;

input group "=== 💰 RIESGO ==="
input double RiskPercent       = 0.50;
input double MaxLot            = 1.00;
input int    MaxSpreadPoints   = 80;
input int    SlippagePoints    = 30;
input double MaxDailyLossPct   = 3.0;

input group "=== 🎯 CONFLUENCIA ==="
input int    MinScore          = 5;    // puntos mínimos para entrar (de 8 posibles)
// Pesos por componente (1 = cuenta, 0 = ignorar)
input int    W_M15             = 2;    // peso capa M15 (vale más — tendencia primaria)
input int    W_H1              = 1;
input int    W_M5              = 1;
input int    W_M1_EMA          = 1;
input int    W_RSI             = 1;
input int    W_ADX             = 1;
input int    W_STOCH           = 1;   // poner 0 para ignorar Stochastic
input int    W_BB              = 1;   // poner 0 para ignorar Bollinger

input group "=== 📊 EMAs M1 ==="
input int    FastEMA           = 9;
input int    SlowEMA           = 21;
input int    TrendEMA          = 100;

input group "=== 🔭 HTF M15 (tendencia primaria — HARD si ADX bajo) ==="
input int    M15_EMA_Fast      = 20;
input int    M15_EMA_Slow      = 50;
input int    M15_ADX_Period    = 14;
input double M15_ADX_Min       = 20.0;  // HARD BLOCK si ADX < este valor

input group "=== 🔭 HTF H1 (sesgo macro) ==="
input int    H1_EMA_Fast       = 50;
input int    H1_EMA_Slow       = 200;

input group "=== 🔭 M5 (momentum intermedio) ==="
input int    M5_EMA_Fast       = 9;
input int    M5_EMA_Slow       = 21;

input group "=== 📐 RSI M1 ==="
input int    RSIPeriod         = 14;
input double RSI_Buy_Min       = 48.0;   // más permisivo que V2
input double RSI_Buy_Max       = 75.0;
input double RSI_Sell_Min      = 25.0;
input double RSI_Sell_Max      = 52.0;

input group "=== 📈 ADX M1 ==="
input int    ADXPeriod         = 14;
input double MinADX_M1         = 20.0;
input double MinDI_Diff        = 2.0;    // diferencia mínima +DI/-DI

input group "=== 🎸 STOCHASTIC ==="
input int    StochK            = 5;
input int    StochD            = 3;
input int    StochSlowing      = 3;
input double Stoch_Buy_Max     = 78.0;   // BUY si Stoch ≤ este valor
input double Stoch_Sell_Min    = 22.0;

input group "=== 📉 BOLLINGER BANDS ==="
input int    BB_Period         = 20;
input double BB_Dev            = 2.0;

input group "=== ⚡ ATR / SL / TP ==="
input int    ATRPeriod         = 14;
input double SL_ATR            = 1.30;
input double TP_ATR            = 2.00;
input double MinATR_USD        = 0.50;
input double MaxATR_USD        = 22.0;

input group "=== 🔧 GESTIÓN ==="
input bool   UseBreakEven      = true;
input double BreakEvenATR      = 0.80;
input bool   UseTrailing       = true;
input double TrailStartATR     = 1.00;
input double TrailATR          = 0.65;

input group "=== 📅 SESIÓN UTC ==="
input bool   UseSessionFilter  = true;
input int    London_Start      = 7;
input int    London_End        = 11;
input int    NY_Start          = 13;
input int    NY_End            = 17;

input group "=== ♻️ CONTROL ==="
input bool   OnlyNewCandle     = true;
input int    CooldownBars      = 2;

//════════════════════════════════════════════════════════
//  HANDLES
//════════════════════════════════════════════════════════
int hFast, hSlow, hTrend, hRSI, hADX, hATR, hStoch, hBB;
int hM15f, hM15s, hM15adx;
int hH1f,  hH1s;
int hM5f,  hM5s;

//════════════════════════════════════════════════════════
//  ESTADO
//════════════════════════════════════════════════════════
datetime g_lastBar    = 0;
datetime g_trailBar   = 0;
int      g_cooldown   = 999;
double   g_dayBal     = 0;
datetime g_today      = 0;
bool     g_isMicro    = false;
double   g_minLot     = 0.01;

void Log(string s) { if(ShowLogs) PrintFormat("[SCV3] %s", s); }

double Val(int h, int buf, int shift) {
   double d[]; ArraySetAsSeries(d, true);
   return (CopyBuffer(h, buf, shift, 1, d) > 0) ? d[0] : EMPTY_VALUE;
}

//════════════════════════════════════════════════════════
//  INIT
//════════════════════════════════════════════════════════
int OnInit() {
   g_minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_isMicro = (g_minLot >= 0.10);
   Log(StringFormat("Cuenta: %s | LoteMin=%.2f | MaxLot=%.2f | MinScore=%d/8",
       g_isMicro ? "MICRO" : "NORMAL", g_minLot, MaxLot, MinScore));

   // M1
   hFast  = iMA(_Symbol, PERIOD_M1, FastEMA,  0, MODE_EMA, PRICE_CLOSE);
   hSlow  = iMA(_Symbol, PERIOD_M1, SlowEMA,  0, MODE_EMA, PRICE_CLOSE);
   hTrend = iMA(_Symbol, PERIOD_M1, TrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI   = iRSI(_Symbol, PERIOD_M1, RSIPeriod, PRICE_CLOSE);
   hADX   = iADX(_Symbol, PERIOD_M1, ADXPeriod);
   hATR   = iATR(_Symbol, PERIOD_M1, ATRPeriod);
   hStoch = iStochastic(_Symbol, PERIOD_M1, StochK, StochD, StochSlowing, MODE_SMA, STO_LOWHIGH);
   hBB    = iBands(_Symbol, PERIOD_M1, BB_Period, 0, BB_Dev, PRICE_CLOSE);
   // M15
   hM15f  = iMA(_Symbol, PERIOD_M15, M15_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hM15s  = iMA(_Symbol, PERIOD_M15, M15_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hM15adx= iADX(_Symbol, PERIOD_M15, M15_ADX_Period);
   // H1
   hH1f   = iMA(_Symbol, PERIOD_H1, H1_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hH1s   = iMA(_Symbol, PERIOD_H1, H1_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   // M5
   hM5f   = iMA(_Symbol, PERIOD_M5, M5_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hM5s   = iMA(_Symbol, PERIOD_M5, M5_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(hFast==INVALID_HANDLE || hSlow==INVALID_HANDLE || hTrend==INVALID_HANDLE ||
      hRSI==INVALID_HANDLE  || hADX==INVALID_HANDLE  || hATR==INVALID_HANDLE  ||
      hStoch==INVALID_HANDLE|| hBB==INVALID_HANDLE   ||
      hM15f==INVALID_HANDLE || hM15s==INVALID_HANDLE || hM15adx==INVALID_HANDLE ||
      hH1f==INVALID_HANDLE  || hH1s==INVALID_HANDLE  ||
      hM5f==INVALID_HANDLE  || hM5s==INVALID_HANDLE) {
      Print("ERROR handles"); return INIT_FAILED;
   }
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   g_dayBal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(PaperMode) Log("⚠️  PAPER MODE");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r) {
   int handles[] = {hFast,hSlow,hTrend,hRSI,hADX,hATR,hStoch,hBB,
                    hM15f,hM15s,hM15adx,hH1f,hH1s,hM5f,hM5s};
   for(int i=0; i<ArraySize(handles); i++) IndicatorRelease(handles[i]);
}

//════════════════════════════════════════════════════════
//  HELPERS
//════════════════════════════════════════════════════════
bool IsNewBar() {
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t != g_lastBar) { g_lastBar = t; return true; }
   return false;
}

bool SpreadOK() {
   double sp = (SymbolInfoDouble(_Symbol,SYMBOL_ASK) - SymbolInfoDouble(_Symbol,SYMBOL_BID)) / _Point;
   return (sp > 0 && sp <= MaxSpreadPoints);
}

bool HasPosition() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber) return true;
   }
   return false;
}

bool InSession() {
   if(!UseSessionFilter) return true;
   MqlDateTime d; TimeToStruct(TimeGMT(), d);
   return (d.hour>=London_Start && d.hour<London_End) ||
          (d.hour>=NY_Start     && d.hour<NY_End);
}

double NormLot(double lot) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = MathMin(MaxLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));
   if(step > 0) lot = MathFloor(lot / step) * step;
   return NormalizeDouble(MathMax(minL, MathMin(lot, maxL)), 2);
}

double CalcLot(double entry, double sl_price) {
   double bal   = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk  = bal * RiskPercent / 100.0;
   double dist  = MathAbs(entry - sl_price);
   if(dist <= 0) return g_minLot;
   double tsz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tsz <= 0 || tv <= 0) return g_minLot;
   double mpl   = (dist / tsz) * tv;
   if(mpl <= 0) return g_minLot;
   return NormLot(risk / mpl);
}

double MinStop() {
   return SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
}

bool MarginOK(double lots, int dir) {
   double price = (dir>0) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                           : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double req = 0;
   if(!OrderCalcMargin((dir>0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL, _Symbol, lots, price, req)) return false;
   double free = AccountInfoDouble(ACCOUNT_FREEMARGIN);
   if(free < req * 1.3) { Log(StringFormat("Margen insuf: %.2f < %.2f", free, req*1.3)); return false; }
   return true;
}

//════════════════════════════════════════════════════════
//  SISTEMA DE PUNTUACIÓN
//  dir: +1 = evaluar BUY, -1 = evaluar SELL
//  Retorna puntos obtenidos y escribe detalle en reason
//════════════════════════════════════════════════════════
int CalcScore(int dir, double atr, string &reason) {
   int score = 0;
   string parts = "";

   // ①  M15 — tendencia primaria (vale W_M15 puntos)
   double m15f  = Val(hM15f,  0, 1);
   double m15s  = Val(hM15s,  0, 1);
   double m15f2 = Val(hM15f,  0, 2);
   double adx15 = Val(hM15adx,0, 1);
   if(m15f!=EMPTY_VALUE && m15s!=EMPTY_VALUE && adx15!=EMPTY_VALUE) {
      bool bull15 = (m15f > m15s) && (m15f >= m15f2);
      bool bear15 = (m15f < m15s) && (m15f <= m15f2);
      if((dir>0 && bull15) || (dir<0 && bear15)) {
         score += W_M15;
         parts += StringFormat("M15✓(%d) ", W_M15);
      } else parts += "M15✗ ";
   }

   // ②  H1 — sesgo macro (vale W_H1 puntos)
   double h1f = Val(hH1f, 0, 1);
   double h1s = Val(hH1s, 0, 1);
   if(h1f!=EMPTY_VALUE && h1s!=EMPTY_VALUE) {
      bool h1ok = (dir>0) ? (h1f > h1s) : (h1f < h1s);
      if(h1ok) { score += W_H1; parts += StringFormat("H1✓(%d) ", W_H1); }
      else        parts += "H1✗ ";
   }

   // ③  M5 — momentum intermedio (vale W_M5 puntos)
   double m5f = Val(hM5f, 0, 1);
   double m5s = Val(hM5s, 0, 1);
   if(m5f!=EMPTY_VALUE && m5s!=EMPTY_VALUE) {
      bool m5ok = (dir>0) ? (m5f > m5s) : (m5f < m5s);
      if(m5ok) { score += W_M5; parts += StringFormat("M5✓(%d) ", W_M5); }
      else        parts += "M5✗ ";
   }

   // ④  M1 EMA stack (vale W_M1_EMA puntos)
   double ef = Val(hFast,  0, 1);
   double es = Val(hSlow,  0, 1);
   double et = Val(hTrend, 0, 1);
   double cl = iClose(_Symbol, PERIOD_M1, 1);
   if(ef!=EMPTY_VALUE && es!=EMPTY_VALUE && et!=EMPTY_VALUE) {
      bool m1ok = (dir>0) ? (ef>es && es>et && cl>et)
                           : (ef<es && es<et && cl<et);
      // Relajado: acepta también EMA fast/slow alineadas sin TrendEMA
      bool m1soft = (dir>0) ? (ef>es && cl>es) : (ef<es && cl<es);
      if(m1ok)        { score += W_M1_EMA; parts += StringFormat("EMA✓(%d) ", W_M1_EMA); }
      else if(m1soft) { score += (int)(W_M1_EMA * 0.5); parts += "EMA~(0) "; }
      else              parts += "EMA✗ ";
   }

   // ⑤  RSI (vale W_RSI puntos)
   double rsi = Val(hRSI, 0, 1);
   if(rsi != EMPTY_VALUE) {
      bool rsiOk = (dir>0) ? (rsi>=RSI_Buy_Min  && rsi<=RSI_Buy_Max)
                            : (rsi>=RSI_Sell_Min && rsi<=RSI_Sell_Max);
      if(rsiOk) { score += W_RSI; parts += StringFormat("RSI%.0f✓(%d) ", rsi, W_RSI); }
      else        parts += StringFormat("RSI%.0f✗ ", rsi);
   }

   // ⑥  ADX M1 + DI spread (vale W_ADX puntos)
   double adx1 = Val(hADX, 0, 1);
   double pDI  = Val(hADX, 1, 1);
   double mDI  = Val(hADX, 2, 1);
   if(adx1!=EMPTY_VALUE && pDI!=EMPTY_VALUE && mDI!=EMPTY_VALUE) {
      bool diOk = (dir>0) ? (pDI - mDI >= MinDI_Diff) : (mDI - pDI >= MinDI_Diff);
      if(adx1 >= MinADX_M1 && diOk) {
         score += W_ADX;
         parts += StringFormat("ADX%.0f✓(%d) ", adx1, W_ADX);
      } else parts += StringFormat("ADX%.0f✗ ", adx1);
   }

   // ⑦  Stochastic (vale W_STOCH puntos)
   if(W_STOCH > 0) {
      double sk = Val(hStoch, 0, 1);
      if(sk != EMPTY_VALUE) {
         bool stOk = (dir>0) ? (sk <= Stoch_Buy_Max) : (sk >= Stoch_Sell_Min);
         if(stOk) { score += W_STOCH; parts += StringFormat("Stoch%.0f✓(%d) ", sk, W_STOCH); }
         else        parts += StringFormat("Stoch%.0f✗ ", sk);
      }
   }

   // ⑧  Bollinger: precio vs media BB (vale W_BB puntos)
   if(W_BB > 0) {
      double bb_mid = Val(hBB, 0, 1);
      if(bb_mid != EMPTY_VALUE) {
         bool bbOk = (dir>0) ? (cl > bb_mid) : (cl < bb_mid);
         if(bbOk) { score += W_BB; parts += StringFormat("BB✓(%d) ", W_BB); }
         else        parts += "BB✗ ";
      }
   }

   reason = parts;
   return score;
}

//════════════════════════════════════════════════════════
//  ABRIR ORDEN
//════════════════════════════════════════════════════════
void OpenOrder(int dir, double atr) {
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double msd  = MinStop();
   double slD  = MathMax(atr * SL_ATR, msd);
   double tpD  = MathMax(atr * TP_ATR, msd);
   double price, sl, tp;

   if(dir > 0) {
      price = ask;
      sl    = NormalizeDouble(price - slD, _Digits);
      tp    = NormalizeDouble(price + tpD, _Digits);
   } else {
      price = bid;
      sl    = NormalizeDouble(price + slD, _Digits);
      tp    = NormalizeDouble(price - tpD, _Digits);
   }

   double lot = CalcLot(price, sl);
   if(lot <= 0) return;
   if(!MarginOK(lot, dir)) return;

   Log(StringFormat("%s %s lot=%.2f price=%.3f sl=%.3f tp=%.3f atr=%.2f [%s]",
       PaperMode?"[PAPER]":"",
       dir>0?"BUY":"SELL",
       lot, price, sl, tp, atr,
       g_isMicro ? "MICRO" : "NORMAL"));

   if(PaperMode) return;

   bool ok;
   if(dir > 0) ok = trade.Buy (lot, _Symbol, 0, sl, tp, "SCV3_B");
   else         ok = trade.Sell(lot, _Symbol, 0, sl, tp, "SCV3_S");

   if(!ok) Log(StringFormat("ERR %d: %s", trade.ResultRetcode(), trade.ResultRetcodeDescription()));
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
         if(UseBreakEven && prof >= atr*BreakEvenATR && sl < open)
            newSL = open;
         if(UseTrailing && prof >= atr*TrailStartATR) {
            datetime cur = iTime(_Symbol, PERIOD_M1, 0);
            if(cur != g_trailBar) {
               g_trailBar = cur;
               double t = bid - atr*TrailATR;
               if(t > newSL && t > open) newSL = t;
            }
         }
         newSL = NormalizeDouble(newSL, _Digits);
         if(newSL > sl && newSL < bid && !PaperMode)
            trade.PositionModify(ticket, newSL, tp);
      }

      if(type == POSITION_TYPE_SELL) {
         double prof = open - ask;
         if(UseBreakEven && prof >= atr*BreakEvenATR && (sl > open || sl == 0))
            newSL = open;
         if(UseTrailing && prof >= atr*TrailStartATR) {
            datetime cur = iTime(_Symbol, PERIOD_M1, 0);
            if(cur != g_trailBar) {
               g_trailBar = cur;
               double t = ask + atr*TrailATR;
               if((t < newSL || newSL==0) && t < open) newSL = t;
            }
         }
         newSL = NormalizeDouble(newSL, _Digits);
         if((newSL < sl || sl==0) && newSL > ask && !PaperMode)
            trade.PositionModify(ticket, newSL, tp);
      }
   }
}

//════════════════════════════════════════════════════════
//  CHECK ENTRY
//════════════════════════════════════════════════════════
void CheckEntry() {
   if(HasPosition()) { g_cooldown = 0; return; }
   g_cooldown++;

   // ── HARD FILTERS ─────────────────────────────────────
   if(!SpreadOK())   { Log("Spread"); return; }
   if(!InSession())  { Log("Sesión"); return; }
   if(g_cooldown < CooldownBars) { Log(StringFormat("CD %d/%d", g_cooldown, CooldownBars)); return; }

   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != g_today) { g_today = today; g_dayBal = AccountInfoDouble(ACCOUNT_BALANCE); }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if((g_dayBal - eq) / g_dayBal * 100 >= MaxDailyLossPct) { Log("DailyLoss"); return; }

   double atr = Val(hATR, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0) return;
   if(atr < MinATR_USD) { Log(StringFormat("ATR bajo %.2f", atr)); return; }
   if(atr > MaxATR_USD) { Log(StringFormat("ATR caos %.2f", atr)); return; }

   // HARD BLOCK: si M15 está en rango (ADX bajo), no operar
   double adx15 = Val(hM15adx, 0, 1);
   if(adx15 != EMPTY_VALUE && adx15 < M15_ADX_Min) {
      Log(StringFormat("M15 ranging ADX=%.1f — HARD BLOCK", adx15)); return;
   }

   // ── SCORING ──────────────────────────────────────────
   double close = iClose(_Symbol, PERIOD_M1, 1);
   double openC = iOpen (_Symbol, PERIOD_M1, 1);
   bool bullCandle = (close > openC);
   bool bearCandle = (close < openC);

   // BUY
   if(EnableBuy && bullCandle) {
      string reason = "";
      int sc = CalcScore(1, atr, reason);
      Log(StringFormat("BUY score=%d/%d | %s", sc, MinScore, reason));
      if(sc >= MinScore) { OpenOrder(1, atr); return; }
   }

   // SELL
   if(EnableSell && bearCandle) {
      string reason = "";
      int sc = CalcScore(-1, atr, reason);
      Log(StringFormat("SELL score=%d/%d | %s", sc, MinScore, reason));
      if(sc >= MinScore) { OpenOrder(-1, atr); return; }
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
