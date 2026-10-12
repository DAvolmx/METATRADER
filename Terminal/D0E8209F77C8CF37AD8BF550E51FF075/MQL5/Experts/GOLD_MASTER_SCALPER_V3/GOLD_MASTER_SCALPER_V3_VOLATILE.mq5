//+──────────────────────────────────────────────────────────────────────────+
//│  GOLD_MASTER_SCALPER_EA  v3.1 — VOLATILE MODE                           │
//│  Optimizado para XAUUSD con velas de alta volatilidad (NFP/CPI/Fed/etc) │
//│                                                                          │
//│  CAMBIOS v3.1 (mejoras de tendencia):                                    │
//│  ─────────────────────────────────────────────────────────────────────  │
//│  1. HTF Trend Filter: EMA(20/50) en M15 + ADX(14) ≥ 22                  │
//│     Bloquea entradas contra la tendencia HTF — reduce señales falsas     │
//│  2. Trailing throttle: SL se actualiza sólo 1× por barra M1             │
//│     Elimina el loop de modificaciones tick-a-tick que saturaba el log    │
//│  3. Margin pre-check: OrderCalcMargin() × 1.3 antes de cada orden       │
//│     Previene error 10019 "not enough money" en cuentas micro             │
//│  4. M5 momentum confirm (opcional): precio vs EMA(20) en M5             │
//│     Segunda capa de confirmación de dirección intradía                   │
//│                                                                          │
//│  CAMBIOS v3.0 (herencia):                                                │
//│  ─────────────────────────────────────────────────────────────────────  │
//│  · VolatileMode AUTO: se activa cuando ATR > VolatileATR_USD            │
//│  · Filtro de cuerpo de vela: body ≤ MaxBody_ATR×ATR                    │
//│  · Spread dinámico, SL máximo absoluto, RSI adaptativo                  │
//│  · Cooldown dinámico, log de modo por barra                             │
//│                                                                          │
//│  ⚠️  PaperModeOnly = true por defecto — compilar en demo primero        │
//+──────────────────────────────────────────────────────────────────────────+
#property copyright "Gold Master System v3.1 — Volatile XAUUSD"
#property version   "3.10"
#property strict

#include <Trade\Trade.mqh>
#include <GoldMaster/GoldMaster_Core.mqh>
#include <GoldMaster/GoldMaster_Structure.mqh>
#include <GoldMaster/GoldMaster_DXY.mqh>
#include <GoldMaster/GoldMaster_Bridge.mqh>
#include <GoldMaster/GoldMaster_Panel.mqh>
CGMPanel g_panel;

//════════════════════════════════════════════════════════
//  INPUTS
//════════════════════════════════════════════════════════

input group "=== 🛡️  SEGURIDAD ==="
input bool   PaperModeOnly     = true;    // OFF = órdenes reales. ON por defecto.
input bool   ShowLogs          = true;
input ulong  MagicNumber       = 202630;
input bool   EnableBuy         = true;
input bool   EnableSell        = true;

input group "=== 💰 RIESGO ==="
input double RiskPercent       = 0.8;    // % balance por trade
input double MaxDailyLossPct   = 2.0;   // % pérdida máxima diaria
input double MinLotRiskTol     = 1.5;   // tolerancia cuentas micro

input group "=== 📊 INDICADORES (chart TF) ==="
input int    EMA_Fast          = 20;
input int    EMA_Slow          = 50;
input int    EMA_Trend         = 200;
input ENUM_TIMEFRAMES TrendTF  = PERIOD_M15;
input int    RSI_Period        = 7;
input int    ATR_Period        = 14;
input int    ATR_Smooth        = 5;     // media del ATR para detectar régimen

input group "=== 🔭 HTF TREND FILTER (M15) ==="
input bool   UseHTFTrendFilter = true;   // activar filtro tendencia HTF
input ENUM_TIMEFRAMES HTF_TF   = PERIOD_M15; // TF para EMAs del filtro
input int    HTF_EMA_Fast      = 20;    // EMA rápida HTF (debe cruzar encima/abajo de lenta)
input int    HTF_EMA_Slow      = 50;    // EMA lenta HTF
input int    HTF_ADX_Period    = 14;    // ADX — mide fuerza de tendencia
input double HTF_ADX_Min       = 22.0;  // ADX mínimo = tendencia válida (debajo = ranging)
input bool   UseM5Momentum     = true;  // confirmar con precio vs EMA(20) en M5

input group "=== 📐 MODO NORMAL (ATR bajo) ==="
input double SL_ATR_Mult       = 1.5;
input double TP1_R             = 1.0;
input double TP2_R             = 2.5;
input double PartialPct        = 50.0;
input double TrailATR          = 1.5;
input double RSI_BullMin       = 45,  RSI_BullMax = 68;
input double RSI_BearMin       = 32,  RSI_BearMax = 55;
input int    CooldownBars      = 6;

input group "=== ⚡ MODO VOLÁTIL (ATR alto) ==="
input double VolatileATR_USD   = 6.0;
input double SL_ATR_Mult_V     = 0.8;
input double MaxSL_USD         = 5.0;   // tope absoluto SL en $ (anti-spike)
input double TP1_R_V           = 0.8;
input double TP2_R_V           = 1.5;
input double PartialPct_V      = 70.0;
input double TrailATR_V        = 0.7;
input double RSI_BullMin_V     = 40,  RSI_BullMax_V = 75;
input double RSI_BearMin_V     = 25,  RSI_BearMax_V = 60;
input int    CooldownBars_V    = 3;

input group "=== 🔍 FILTROS VOLATILIDAD ==="
input double MinATR_USD        = 0.8;
input double MaxATR_USD        = 25.0;
input double MaxBody_ATR       = 2.5;
input double MaxWick_BodyRatio = 2.0;
input int    MaxSpreadPts      = 60;
input int    MaxSpread_V_Pts   = 120;

input group "=== 🏗️ ESTRUCTURA ==="
input int    SwingStrength     = 3;
input ENUM_TIMEFRAMES HTF      = PERIOD_H1;
input bool   RequireHTFStructure = true;
input int    ConfirmBars       = 1;
input int    SignalExpiryBars  = 6;

input group "=== 🎯 ENTRADA ==="
input bool   UseStopEntry      = true;
input bool   ForceMarketInVol  = true;
input double StopBufferATR     = 0.10;
input int    StopExpiryBars    = 4;

input group "=== 📅 SESIONES (UTC) ==="
input bool   FilterSession     = true;
input int    London_Start=7, London_End=11, NY_Start=13, NY_End=17;

input group "=== 📰 DXY / NOTICIAS ==="
input bool   UseDXYFilter      = true;
input bool   UseIntelBridge    = true;
input double IntelVeto         = 0.45;
input bool   UseNewsFilter     = true;
input int    NewsFreezeMin     = 20;

input group "=== ♻️ LÍMITES ==="
input int    MaxTradesPerDay   = 5;

//════════════════════════════════════════════════════════
//  GLOBALS
//════════════════════════════════════════════════════════
CTrade   trade;
CGMDXY   g_dxy;
CGMBridge g_bridge;
CGMNewsFilter g_news;

// Handles de indicadores del chart TF
int hEF, hES, hET, hRSI, hATR;

// Handles HTF Trend Filter (M15)
int g_htf_ema_fast_h  = INVALID_HANDLE;
int g_htf_ema_slow_h  = INVALID_HANDLE;
int g_htf_adx_h       = INVALID_HANDLE;
int g_m5_ema_h        = INVALID_HANDLE;

// Estado de sesión
int    g_tradesToday=0, g_barsSinceClose=999, g_pending=0, g_confirm=0, g_sigAge=0;
datetime g_day=0, g_lastBar=0, g_lastEventT=0, g_stopTime=0;
double g_sigHigh=0, g_sigLow=0, g_dayStartBalance=0;
ulong  g_stopTicket=0;
bool   g_partialDone=false;
ulong  g_posTicket=0;
double g_initRisk=0;
bool   g_volatileMode=false;

// FIX v3.1: trailing throttle — actualizar SL sólo 1× por barra M1
datetime g_last_trail_bar = 0;

void Log(string s) { if(ShowLogs) PrintFormat("[SCALPv3] %s", s); }

double Buf(int h, int shift=1) {
   double b[1];
   return CopyBuffer(h, 0, shift, 1, b) > 0 ? b[0] : 0;
}

//════════════════════════════════════════════════════════
//  FIX v3.1 — HTF TREND BIAS
//  Retorna: +1 = tendencia alcista válida
//            0 = sin tendencia (ranging o ADX bajo)
//           -1 = tendencia bajista válida
//════════════════════════════════════════════════════════
int HTF_TrendBias() {
   if(!UseHTFTrendFilter) return 0;  // 0 = no filtrar
   if(g_htf_ema_fast_h == INVALID_HANDLE || g_htf_ema_slow_h == INVALID_HANDLE ||
      g_htf_adx_h == INVALID_HANDLE) return 0;

   double ema_f[], ema_s[], adx_main[];
   ArraySetAsSeries(ema_f,    true);
   ArraySetAsSeries(ema_s,    true);
   ArraySetAsSeries(adx_main, true);

   if(CopyBuffer(g_htf_ema_fast_h, 0, 0, 3, ema_f)    < 3) return 0;
   if(CopyBuffer(g_htf_ema_slow_h, 0, 0, 3, ema_s)    < 3) return 0;
   if(CopyBuffer(g_htf_adx_h,      0, 0, 3, adx_main) < 3) return 0;

   // ADX bajo → mercado en rango, no confirmar dirección
   if(adx_main[1] < HTF_ADX_Min) {
      if(ShowLogs) Log(StringFormat("HTF ADX=%.1f < %.1f → ranging, sin sesgo", adx_main[1], HTF_ADX_Min));
      return 0;
   }

   bool bull = (ema_f[1] > ema_s[1]) && (ema_f[1] > ema_f[2]);  // EMA rápida encima y subiendo
   bool bear = (ema_f[1] < ema_s[1]) && (ema_f[1] < ema_f[2]);  // EMA rápida abajo y bajando

   if(bull) return  1;
   if(bear) return -1;
   return 0;
}

//════════════════════════════════════════════════════════
//  FIX v3.1 — M5 MOMENTUM CONFIRM
//  Precio de cierre M5 vs EMA(20) M5
//  Retorna true si la dirección "dir" coincide con el momentum M5
//════════════════════════════════════════════════════════
bool M5MomentumOK(int dir) {
   if(!UseM5Momentum) return true;  // sin filtro = siempre ok
   if(g_m5_ema_h == INVALID_HANDLE) return true;

   double ema_m5[];
   ArraySetAsSeries(ema_m5, true);
   if(CopyBuffer(g_m5_ema_h, 0, 0, 3, ema_m5) < 3) return true;

   double close_m5 = iClose(_Symbol, PERIOD_M5, 1);
   if(dir == 1  && close_m5 <= ema_m5[1]) return false;  // alcista pero precio debajo EMA M5
   if(dir == -1 && close_m5 >= ema_m5[1]) return false;  // bajista pero precio encima EMA M5
   return true;
}

//════════════════════════════════════════════════════════
//  FIX v3.1 — MARGIN PRE-CHECK
//  Verifica margen libre × 1.3 antes de cualquier orden
//════════════════════════════════════════════════════════
bool HasEnoughMargin(double lots, int dir) {
   double price     = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                 : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double margin_req = 0.0;
   ENUM_ORDER_TYPE otype = (dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if(!OrderCalcMargin(otype, _Symbol, lots, price, margin_req)) {
      Log(StringFormat("OrderCalcMargin falló — lot=%.2f", lots));
      return false;
   }
   double free_margin = AccountInfoDouble(ACCOUNT_FREEMARGIN);
   if(free_margin < margin_req * 1.3) {
      Log(StringFormat("⚠️  MARGEN INSUFICIENTE — Libre:%.2f Req:%.2f×1.3=%.2f (lot=%.2f)",
                       free_margin, margin_req, margin_req*1.3, lots));
      return false;
   }
   return true;
}

//════════════════════════════════════════════════════════
//  INIT
//════════════════════════════════════════════════════════
int OnInit() {
   GM_TFBadge("SCALPER v3.1 VOLATILE","M1,M5");
   if(!MQLInfoInteger(MQL_TESTER) && GM_IsDuplicateInstance()) {
      Print("[GM] Instancia duplicada → saliendo"); ExpertRemove(); return INIT_SUCCEEDED;
   }
   g_panel.Init("SCALPv3.1", 10, 200);

   // Handles chart TF
   hEF  = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast,  0, MODE_EMA, PRICE_CLOSE);
   hES  = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow,  0, MODE_EMA, PRICE_CLOSE);
   hET  = iMA(_Symbol, TrendTF,        EMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
   hRSI = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   hATR = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   if(hEF==INVALID_HANDLE||hES==INVALID_HANDLE||hET==INVALID_HANDLE||
      hRSI==INVALID_HANDLE||hATR==INVALID_HANDLE) { Print("Handle error (chart TF)"); return INIT_FAILED; }

   // FIX v3.1: Handles HTF Trend Filter
   if(UseHTFTrendFilter) {
      g_htf_ema_fast_h = iMA(_Symbol, HTF_TF, HTF_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      g_htf_ema_slow_h = iMA(_Symbol, HTF_TF, HTF_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
      g_htf_adx_h      = iADX(_Symbol, HTF_TF, HTF_ADX_Period);
      if(g_htf_ema_fast_h==INVALID_HANDLE || g_htf_ema_slow_h==INVALID_HANDLE || g_htf_adx_h==INVALID_HANDLE) {
         Print("Handle error (HTF filter) — desactivando filtro HTF");
         UseHTFTrendFilter = false;
      } else {
         Log(StringFormat("HTF Trend Filter iniciado: %s EMA(%d/%d) ADX(%d)≥%.0f",
             EnumToString(HTF_TF), HTF_EMA_Fast, HTF_EMA_Slow, HTF_ADX_Period, HTF_ADX_Min));
      }
   }

   // FIX v3.1: Handle M5 momentum
   if(UseM5Momentum) {
      g_m5_ema_h = iMA(_Symbol, PERIOD_M5, 20, 0, MODE_EMA, PRICE_CLOSE);
      if(g_m5_ema_h == INVALID_HANDLE) {
         Print("Handle error (M5 EMA) — desactivando M5 momentum");
         UseM5Momentum = false;
      } else {
         Log("M5 Momentum confirmación: activo");
      }
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(40);
   trade.SetTypeFilling(GM_FillingMode(_Symbol));
   g_gm_minlot_risk_tol = MinLotRiskTol;
   if(UseDXYFilter)    Log(g_dxy.Init() ? "DXY: "+g_dxy.Mode() : "DXY no disponible");
   if(UseIntelBridge)  g_bridge.Init(180);
   if(UseNewsFilter)   g_news.Init();
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   GM_SymbolReport(_Symbol, RiskPercent, 5.0);
   if(PaperModeOnly) Log("⚠️  PAPER MODE activo — sin órdenes reales");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r) {
   g_panel.Destroy();
   IndicatorRelease(hEF); IndicatorRelease(hES);
   IndicatorRelease(hET); IndicatorRelease(hRSI); IndicatorRelease(hATR);
   // FIX v3.1: liberar handles HTF
   if(g_htf_ema_fast_h != INVALID_HANDLE) IndicatorRelease(g_htf_ema_fast_h);
   if(g_htf_ema_slow_h != INVALID_HANDLE) IndicatorRelease(g_htf_ema_slow_h);
   if(g_htf_adx_h      != INVALID_HANDLE) IndicatorRelease(g_htf_adx_h);
   if(g_m5_ema_h       != INVALID_HANDLE) IndicatorRelease(g_m5_ema_h);
}

//════════════════════════════════════════════════════════
//  HELPERS
//════════════════════════════════════════════════════════
bool MyPosition(ulong &ticket) {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC)==(long)MagicNumber &&
         PositionGetString(POSITION_SYMBOL)==_Symbol) { ticket=t; return true; }
   }
   return false;
}

bool InSession() {
   if(!FilterSession) return true;
   MqlDateTime d; TimeToStruct(TimeGMT(), d);
   return (d.hour>=London_Start && d.hour<London_End) ||
          (d.hour>=NY_Start     && d.hour<NY_End);
}

double SmoothedATR() {
   double buf[];
   if(CopyBuffer(hATR, 0, 1, ATR_Smooth, buf) < ATR_Smooth) return Buf(hATR);
   double sum=0; for(int i=0;i<ATR_Smooth;i++) sum+=buf[i];
   return sum / ATR_Smooth;
}

//════════════════════════════════════════════════════════
//  FILTRO DE VELA — detecta entradas tardías y trampas
//════════════════════════════════════════════════════════
bool CandleQualityOK(const MqlRates &bar, double atr) {
   double body     = MathAbs(bar.close - bar.open);
   double wick_up  = bar.high - MathMax(bar.open, bar.close);
   double wick_dn  = MathMin(bar.open, bar.close) - bar.low;
   double max_wick = MathMax(wick_up, wick_dn);
   if(body > atr * MaxBody_ATR) {
      Log(StringFormat("Vela extendida body=%.2f$ > %.1f×ATR — skip", body, MaxBody_ATR));
      return false;
   }
   if(body > 0 && max_wick > body * MaxWick_BodyRatio) {
      Log(StringFormat("Wick/body ratio %.1f — posible trampa, skip", max_wick/body));
      return false;
   }
   return true;
}

//════════════════════════════════════════════════════════
//  GESTIÓN DE POSICIÓN — con trailing throttle (FIX v3.1)
//════════════════════════════════════════════════════════
void ManagePosition(ulong ticket, double atr) {
   if(!PositionSelectByTicket(ticket)) return;
   if(ticket != g_posTicket) {
      g_posTicket    = ticket;
      g_partialDone  = false;
      g_initRisk     = MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - PositionGetDouble(POSITION_SL));
      g_last_trail_bar = 0;  // reset throttle al abrir nueva posición
   }
   int    type = (int)PositionGetInteger(POSITION_TYPE);
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = PositionGetDouble(POSITION_TP);
   double vol  = PositionGetDouble(POSITION_VOLUME);
   double px   = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                                            : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double r    = (g_initRisk > 0) ? ((type==POSITION_TYPE_BUY ? px-open : open-px) / g_initRisk) : 0;
   double pt   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double tp1_r = g_volatileMode ? TP1_R_V     : TP1_R;
   double pct   = g_volatileMode ? PartialPct_V : PartialPct;
   double trail = g_volatileMode ? TrailATR_V   : TrailATR;

   // TP1 — cierre parcial (se ejecuta en cada tick al alcanzar el nivel)
   if(!g_partialDone && r >= tp1_r) {
      double cl = GM_PartialLot(_Symbol, vol, pct / 100.0);
      if(cl > 0) {
         if(!PaperModeOnly) trade.PositionClosePartial(ticket, cl);
         Log(StringFormat("%s TP1 %.1fR: cerrado %.2f lotes (%.0f%%) modo=%s",
             PaperModeOnly?"[PAPER]":"", tp1_r, cl, pct, g_volatileMode?"VOLÁTIL":"normal"));
      }
      double be = open + (type==POSITION_TYPE_BUY ? 1 : -1) * GM_GetSpread(_Symbol) * pt;
      bool better_be = (type==POSITION_TYPE_BUY) ? (be > sl) : (sl==0 || be < sl);
      if(better_be && !PaperModeOnly)
         trade.PositionModify(ticket, NormalizeDouble(be,_Digits), tp);
      g_partialDone = true;
   }

   // FIX v3.1 — TRAILING THROTTLE: sólo una vez por barra M1
   if(g_partialDone && atr > 0) {
      datetime cur_m1_bar = iTime(_Symbol, PERIOD_M1, 0);
      if(cur_m1_bar == g_last_trail_bar) return;  // ya actualizamos en esta barra
      g_last_trail_bar = cur_m1_bar;

      double nsl = (type==POSITION_TYPE_BUY) ? px - atr*trail : px + atr*trail;
      nsl = NormalizeDouble(nsl, _Digits);
      bool better = (type==POSITION_TYPE_BUY) ? (nsl > sl + pt*10 && nsl > open)
                                               : ((sl==0||nsl < sl-pt*10) && nsl < open);
      if(better && !PaperModeOnly) {
         trade.PositionModify(ticket, nsl, tp);
         if(ShowLogs) Log(StringFormat("Trailing SL → %.5f (barra M1: %s)", nsl,
                          TimeToString(cur_m1_bar, TIME_MINUTES)));
      }
   }
}

//════════════════════════════════════════════════════════
//  OnTick PRINCIPAL
//════════════════════════════════════════════════════════
void OnTick() {
   double atr   = Buf(hATR);
   double atr_s = SmoothedATR();

   ulong pos = 0;
   bool hasPos = MyPosition(pos);
   if(hasPos) ManagePosition(pos, atr);

   // Detectar llenado de stop order pendiente
   if(g_stopTicket > 0 && !OrderSelect(g_stopTicket)) {
      if(hasPos) { g_tradesToday++; Log("Orden stop ejecutada"); }
      g_stopTicket = 0;
   }

   datetime bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(bar == g_lastBar) return;
   g_lastBar = bar;

   // ── Clasificar modo de volatilidad ────────────────────────────
   g_volatileMode = (atr_s >= VolatileATR_USD);

   // FIX v3.1: obtener sesgo HTF (calculado 1× por barra)
   int htf_bias = HTF_TrendBias();  // +1 / 0 / -1

   Log(StringFormat("── BARRA | ATR=%.2f$ ATR_avg=%.2f$ MODO=%s HTF=%s",
       atr, atr_s,
       g_volatileMode ? "⚡VOLÁTIL" : "normal",
       htf_bias == 1 ? "🐂BULL" : htf_bias == -1 ? "🐻BEAR" : "◼RANGE"));

   // ── Reset diario ──────────────────────────────────────────────
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != g_day) {
      g_day = today;
      g_tradesToday = 0;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   }

   // Control pérdida diaria
   double cur_eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if((g_dayStartBalance - cur_eq) / g_dayStartBalance * 100 >= MaxDailyLossPct) {
      Log("Daily loss limit — sin más entradas hoy"); return;
   }

   if(hasPos) { g_barsSinceClose = 0; return; }
   g_barsSinceClose++;
   if(UseIntelBridge) g_bridge.ReadIntel();

   // Expirar orden stop pendiente
   if(g_stopTicket > 0 && TimeCurrent() - g_stopTime > StopExpiryBars * PeriodSeconds()) {
      if(!PaperModeOnly) trade.OrderDelete(g_stopTicket);
      g_stopTicket = 0;
      Log("Orden stop expirada");
   }

   if(!MQLInfoInteger(MQL_TESTER) && UseIntelBridge && !g_bridge.AutoTrade()) return;

   // ── BOS / CHoCH (estructura) ───────────────────────────────────
   MqlRates r[]; int n = CopyRates(_Symbol, PERIOD_CURRENT, 0, 300, r);
   if(n < 100) return;
   GMSSwing sw[]; int ns = GMS_Swings(r, n, SwingStrength, sw);
   GMSEvent ev[]; int trend; int ne = GMS_Events(r, n, SwingStrength, sw, ns, ev, trend);

   if(ne > 0 && ev[ne-1].t_break != g_lastEventT && ev[ne-1].bar_break >= n-3) {
      g_lastEventT = ev[ne-1].t_break;
      g_pending    = ev[ne-1].dir;
      g_confirm    = 0; g_sigAge = 0;
      g_sigHigh    = r[ev[ne-1].bar_break].high;
      g_sigLow     = r[ev[ne-1].bar_break].low;
      Log(StringFormat("📍 %s en %.3f | cuerpo ok: %s",
          GMS_EventName(ev[ne-1].dir, ev[ne-1].choch),
          ev[ne-1].price,
          CandleQualityOK(r[ev[ne-1].bar_break], atr) ? "✓" : "✗"));
   }
   if(g_pending == 0) { _Panel(trend, atr, "sin señal", htf_bias); return; }
   g_confirm++; g_sigAge++;
   if(g_sigAge > SignalExpiryBars) { Log("Señal caducada"); g_pending=0; return; }

   int cooldown = g_volatileMode ? CooldownBars_V : CooldownBars;
   if(g_confirm < ConfirmBars) return;

   // ── Pre-filtros ───────────────────────────────────────────────
   string why = "";
   if(g_tradesToday >= MaxTradesPerDay) why = "máx. trades del día";
   else if(g_barsSinceClose < cooldown) why = StringFormat("cooldown (%d/%d)", g_barsSinceClose, cooldown);
   else if(!InSession())                why = "fuera de sesión";
   else if(atr < MinATR_USD)           why = StringFormat("ATR bajo %.2f$ < %.2f$", atr, MinATR_USD);
   else if(atr_s > MaxATR_USD)         why = StringFormat("ATR extremo %.2f$ > %.2f$ (caos)", atr_s, MaxATR_USD);
   else {
      int max_sp = g_volatileMode ? MaxSpread_V_Pts : MaxSpreadPts;
      if(GM_GetSpread(_Symbol) > max_sp)
         why = StringFormat("spread %d > %d pts", (int)GM_GetSpread(_Symbol), max_sp);
   }
   if(UseNewsFilter && why=="" && g_news.IsNewsTime(NewsFreezeMin, 3)) why = "noticia alto impacto";
   if(g_stopTicket>0 && OrderSelect(g_stopTicket) && why=="") why = "stop pendiente";

   // Filtro calidad vela de ruptura
   if(why=="" && ne>0) {
      if(!CandleQualityOK(r[ev[ne-1].bar_break], atr)) why = "vela: cuerpo extendido o wick/trampa";
   }

   // FIX v3.1 — GATE HTF TREND FILTER
   if(why == "" && UseHTFTrendFilter) {
      if(htf_bias == 0) {
         why = StringFormat("HTF ranging (ADX < %.0f o EMAs cruzadas) — esperar tendencia", HTF_ADX_Min);
      } else if(g_pending != 0 && htf_bias != g_pending) {
         why = StringFormat("Señal %s CONTRA tendencia HTF %s — bloqueada",
                            g_pending == 1 ? "BUY" : "SELL",
                            htf_bias  == 1 ? "BULL" : "BEAR");
      }
   }

   if(why != "") { _Panel(trend, atr, why, htf_bias); return; }

   // ── Indicadores chart TF ───────────────────────────────────────
   double ef = Buf(hEF), es = Buf(hES), et = Buf(hET), rsi = Buf(hRSI);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool emaGap = MathAbs(ef-es) >= atr * 0.15;
   GMSState H  = GMS_Analyze(_Symbol, HTF, 3, 300);
   int dxyBias = (UseDXYFilter && g_dxy.Ready()) ? g_dxy.GoldBias(_Symbol, PERIOD_H1) : 0;
   double comp = (UseIntelBridge && g_bridge.Valid()) ? g_bridge.Composite() : 0;

   double rsi_bull_min = g_volatileMode ? RSI_BullMin_V : RSI_BullMin;
   double rsi_bull_max = g_volatileMode ? RSI_BullMax_V : RSI_BullMax;
   double rsi_bear_min = g_volatileMode ? RSI_BearMin_V : RSI_BearMin;
   double rsi_bear_max = g_volatileMode ? RSI_BearMax_V : RSI_BearMax;

   int dir = g_pending;
   bool rsi_ok, ema_ok, htf_ok, dxy_ok, intel_ok, m5_ok;
   if(dir > 0) {
      rsi_ok   = (rsi >= rsi_bull_min && rsi <= rsi_bull_max);
      ema_ok   = (ef > es && ask > et);
      htf_ok   = !RequireHTFStructure || H.trend == 1;
      dxy_ok   = (dxyBias != -1);
      intel_ok = !(comp <= -IntelVeto);
      m5_ok    = M5MomentumOK(1);
   } else {
      rsi_ok   = (rsi >= rsi_bear_min && rsi <= rsi_bear_max);
      ema_ok   = (ef < es && bid < et);
      htf_ok   = !RequireHTFStructure || H.trend == -1;
      dxy_ok   = (dxyBias != 1);
      intel_ok = !(comp >= IntelVeto);
      m5_ok    = M5MomentumOK(-1);
   }
   bool ok = (dir>0?EnableBuy:EnableSell) && emaGap && rsi_ok && ema_ok && htf_ok && dxy_ok && intel_ok && m5_ok;

   Log(StringFormat("EVAL %s | EMA:%s RSI:%.1f[%s] HTF:%s M5:%s DXY:%+d intel:%.2f modo:%s → %s",
       dir>0?"BUY":"SELL",
       ema_ok?"ok":"✗", rsi, rsi_ok?"ok":"✗",
       GMS_TrendName(H.trend), m5_ok?"ok":"✗",
       dxyBias, comp,
       g_volatileMode?"⚡VOLÁTIL":"normal",
       ok?"✅ ENTRAR":"❌ no"));

   if(!ok) { _Panel(trend, atr, "condiciones incompletas", htf_bias); return; }

   // ── SL / TP ───────────────────────────────────────────────────
   double sl_mult = g_volatileMode ? SL_ATR_Mult_V : SL_ATR_Mult;
   double tp2_r   = g_volatileMode ? TP2_R_V       : TP2_R;
   double entry, sl;

   bool use_stop = UseStopEntry && !(ForceMarketInVol && g_volatileMode);

   if(dir > 0) {
      entry = use_stop ? g_sigHigh + atr*StopBufferATR : ask;
      if(use_stop && entry <= ask) entry = ask + atr*StopBufferATR;
      sl = entry - atr * sl_mult;
      for(int i=ns-1; i>=0; i--)
         if(!sw[i].high) { sl = MathMin(sl, sw[i].p - atr*0.2); break; }
   } else {
      entry = use_stop ? g_sigLow - atr*StopBufferATR : bid;
      if(use_stop && entry >= bid) entry = bid - atr*StopBufferATR;
      sl = entry + atr * sl_mult;
      for(int i=ns-1; i>=0; i--)
         if(sw[i].high) { sl = MathMax(sl, sw[i].p + atr*0.2); break; }
   }

   double risk = MathAbs(entry - sl);

   // Cap de SL en modo volátil
   if(g_volatileMode && risk > MaxSL_USD) {
      Log(StringFormat("⚡ SL cap: %.2f$ → %.2f$ (MaxSL_USD)", risk, MaxSL_USD));
      sl   = entry - dir * MaxSL_USD;
      risk = MaxSL_USD;
   }
   if(risk > atr * 4) { Log("SL demasiado lejos, señal descartada"); g_pending=0; return; }

   double tp   = entry + dir * risk * tp2_r;
   double lots = GM_CalcLot(_Symbol, RiskPercent, risk);
   if(lots <= 0) { g_pending=0; return; }

   entry = NormalizeDouble(entry, _Digits);
   sl    = NormalizeDouble(sl,    _Digits);
   tp    = NormalizeDouble(tp,    _Digits);

   // FIX v3.1 — MARGIN CHECK antes de enviar orden
   if(!HasEnoughMargin(lots, dir)) {
      Log("❌ Orden cancelada — margen insuficiente");
      _Panel(trend, atr, "margen insuficiente", htf_bias);
      return;
   }

   Log(StringFormat("%s %s dir=%+d modo=%s | lot=%.2f entry=%.3f sl=%.3f tp=%.3f (%.1fR) risk=%.2f$",
       PaperModeOnly?"[PAPER]":"", use_stop?"STOP":"MARKET",
       dir, g_volatileMode?"⚡VOLÁTIL":"normal",
       lots, entry, sl, tp, tp2_r, risk));

   if(PaperModeOnly) { g_pending=0; _Panel(trend, atr, "[PAPER] señal OK", htf_bias); return; }

   bool sent = false;
   if(use_stop) {
      sent = (dir > 0) ? trade.BuyStop(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "GMSv3_BS")
                       : trade.SellStop(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "GMSv3_SS");
      if(sent) { g_stopTicket=trade.ResultOrder(); g_stopTime=TimeCurrent(); }
   } else {
      sent = (dir > 0) ? trade.Buy(lots, _Symbol, ask, sl, tp, "GMSv3_BM")
                       : trade.Sell(lots, bid, _Symbol, sl, tp, "GMSv3_SM");
      if(sent) g_tradesToday++;
   }

   Log(StringFormat("%s order %s retcode=%d", sent?"✅":"❌", dir>0?"BUY":"SELL", (int)trade.ResultRetcode()));
   g_pending = 0;
   _Panel(trend, atr, sent ? "orden enviada" : "error al enviar", htf_bias);
}

//════════════════════════════════════════════════════════
void _Panel(int trend, double atr, string status, int htf_bias=0) {
   string dx = g_dxy.Ready()
      ? StringFormat("DXY %.3f (%+.2f%%) %s", g_dxy.Value(PERIOD_H1,0), g_dxy.ChangePct(PERIOD_H1,24), g_dxy.Mode())
      : "DXY no disponible";
   string in  = (UseIntelBridge && g_bridge.Valid()) ? g_bridge.Status() : "intel: sin datos";
   string htf_str = htf_bias == 1 ? "HTF:🐂BULL" : htf_bias == -1 ? "HTF:🐻BEAR" : "HTF:◼RANGE";
   g_panel.Show(StringFormat(
      "GOLD MASTER · SCALPER v3.1 %s\n%s · %s · ATR %.2f$ · Trades %d/%d\n%s\n%s\nEstado: %s",
      g_volatileMode?"⚡VOLÁTIL":"normal",
      GMS_TrendName(trend), htf_str, Buf(hATR), g_tradesToday, MaxTradesPerDay, dx, in, status));
}

void OnChartEvent(const int id, const long &l, const double &d, const string &s) {
   g_panel.OnEvent(id, l, d, s);
}
//+------------------------------------------------------------------+
