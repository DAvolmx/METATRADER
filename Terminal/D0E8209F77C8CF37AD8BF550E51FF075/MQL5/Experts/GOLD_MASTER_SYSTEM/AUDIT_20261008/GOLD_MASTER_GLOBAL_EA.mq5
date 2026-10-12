//+──────────────────────────────────────────────────────────────────────────+
//│        GOLD MASTER SYSTEM — GLOBAL EA v1.0                               │
//│  Integración unificada de todos los mejores EAs del repositorio:         │
//│                                                                          │
//│  CORE (heredado de EA_v3):                                               │
//│   · SMC: BOS/CHoCH, Order Blocks, FVG, Estructura multi-TF              │
//│   · Score confluencia 0-17 + votos ML + Intel Bridge Python             │
//│   · News filter, spread monitor, volatility regime                       │
//│                                                                          │
//│  NUEVOS MÓDULOS (de los 23 EAs analizados):                             │
//│   · Filtro DXY (VARIOS2)         → veta dirección si dólar contradice   │
//│   · Parciales 1R/2R/runner        → SCALPER2_Piramide + COPILOT_v5      │
//│   · Sesiones + Asian range       → HUGO/HUGOx                          │
//│   · Score de sesión (+2 overlap)  → peso en confluencia                 │
//│   · Asian breakout como entrada   → expansión de liquidez               │
//│   · Spike retrace detector       → EA1_Boom1000, adaptado a XAUUSD     │
//│   · Rendimiento real 10y bias    → FRED DFII10 via gm_dxy.py           │
//│                                                                          │
//│  SEGURIDAD: PaperModeOnly = true en todo nuevo EA                       │
//│  Requiere: GoldMaster_Core.mqh, _SMC.mqh, _PendingOrders.mqh,          │
//│            _PositionManager.mqh, _ML.mqh, _Bridge.mqh                   │
//│            GoldMaster_DXY_Filter.mqh (nuevo)                            │
//│            GoldMaster_Partials.mqh   (nuevo)                            │
//│            GoldMaster_Sessions.mqh   (nuevo)                            │
//+──────────────────────────────────────────────────────────────────────────+
#property copyright "Gold Master System GLOBAL v1.0"
#property version   "1.00"
#property strict

#include <GoldMaster/GoldMaster_Core.mqh>
#include <GoldMaster/GoldMaster_SMC.mqh>
#include <GoldMaster/GoldMaster_PendingOrders.mqh>
#include <GoldMaster/GoldMaster_PositionManager.mqh>
#include <GoldMaster/GoldMaster_ML.mqh>
#include <GoldMaster/GoldMaster_Bridge.mqh>
#include <GoldMaster/GoldMaster_DXY_Filter.mqh>
#include <GoldMaster/GoldMaster_Partials.mqh>
#include <GoldMaster/GoldMaster_Sessions.mqh>

//════════════════════════════════════════════════════════
//  ⚙️  INPUTS
//════════════════════════════════════════════════════════

input group "=== [GLOBAL] SEGURIDAD ==="
input bool   PaperModeOnly        = true;     // TRUE = jamás ejecuta órdenes reales
input bool   Verbose              = true;

input group "=== [CORE] RIESGO ==="
input double RiskPercent          = 0.5;
input double MaxDailyLossPct      = 2.0;
input double MaxDrawdownPct       = 5.0;
input int    MaxPositions         = 3;

input group "=== [CORE] CONFLUENCIA ==="
input int    MinConfluenceScore   = 7;     // +1 vs v3 (sesiones aportan hasta +2)
input int    MinMLVotes           = 2;
input double MinMLConfidence      = 0.62;
input bool   RequireHTFBias       = true;
input bool   UseMLFilter          = true;

input group "=== [CORE] SMC ==="
input int    ATR_Period           = 14;
input double ATR_SL_Mult          = 1.5;
input double ATR_TP1_Mult         = 1.0;   // 1R → primer parcial
input double ATR_TP2_Mult         = 2.0;   // 2R → segundo parcial
input double ATR_TP3_Mult         = 4.0;   // runner libre
input int    OB_Expiry_Candles    = 48;
input int    FVG_Expiry_Candles   = 24;
input int    MinOBQuality         = 50;

input group "=== [CORE] NOTICIAS ==="
input bool   UseNewsFilter        = true;
input int    NewsFreezeMins       = 30;
input int    MinNewsImpact        = 3;

input group "=== [NUEVO] DXY — Filtro Correlación ==="
input bool   UseDXYFilter         = true;    // filtrar dirección si DXY contradice
input bool   UseDXYScoreAdjust    = true;    // +1/-1 al score según DXY
input bool   UseRealYieldBias     = true;    // rendimiento real 10y (FRED DFII10)
input int    DXY_MaxAgeSecs       = 90;      // antigüedad máxima del dato DXY
input string DXYStatePath         = "GoldMaster\\gm_state.json"; // escrito por gm_bridge.py

input group "=== [NUEVO] PARCIALES 1R/2R/RUNNER ==="
input bool   UsePartials          = true;
input double Partial1_Pct         = 0.50;    // % cierre en 1R
input double Partial2_Pct         = 0.30;    // % cierre en 2R (sobre restante)
input double RunnerTrail_ATR      = 1.5;     // multiplicador ATR trailing en runner

input group "=== [NUEVO] SESIONES + ASIAN RANGE ==="
input bool   TradeLondon          = true;
input bool   TradeOverlap         = true;
input bool   TradeNY              = true;
input bool   TradeDead            = false;   // 20:00-23:59 — prohibido
input bool   UseSessionScore      = true;    // aportar puntos al score según sesión
input bool   UseAsianBreakout     = true;    // señal extra: breakout del rango asiático
input double AsianBreakout_MinATR = 0.5;     // el breakout debe ser >= X·ATR para contar

input group "=== [NUEVO] SPIKE RETRACE (XAUUSD noticias) ==="
input bool   UseSpikeRetrace      = true;    // detectar spike + retroceso (NFP, CPI)
input double SpikeSize_ATR        = 3.0;     // spike ≥ X·ATR en una vela
input double SpikeRetrace_Pct     = 0.50;    // retroceso mínimo del 50% del spike

input group "=== [CORE] MTF EMA ==="
input int    EMA_Fast             = 21;
input int    EMA_Slow             = 50;
input bool   UseEMABias           = true;

input group "=== [CORE] ML + INTEL BRIDGE ==="
input string MLPredictionsPath    = "GoldMaster\\ml_predictions.csv";
input string MLFeaturesPath       = "GoldMaster\\ml_features.csv";
input int    MLMaxAgeSecs         = 300;
input bool   UseIntelBridge       = true;
input int    IntelMaxAgeSecs      = 120;
input int    IntelWeight          = 3;
input double IntelVeto            = 0.55;

input group "=== [CORE] CUENTA MICRO ==="
input double MinLotRiskTol        = 1.5;

//════════════════════════════════════════════════════════
//  🔧  GLOBALS
//════════════════════════════════════════════════════════
string   g_symbol;
int      g_magic;
int      g_atr_handle;

// Módulos core (EA_v3)
CGoldMasterSMC*             g_smc     = NULL;
CGoldMasterPending*          g_pending = NULL;
CGoldMasterPositionManager*  g_posmgr  = NULL;
CGMLBridge                  g_ml;
CGMNewsFilter               g_news;
CGMMTFBiasEngine            g_mtf;
CGMVolatilityRegime         g_vol;
CGMSpreadMonitor            g_spread;
CGMBridge                   g_bridge;

// Módulos nuevos
CGMDXYFilter                g_dxy;
CGMPartials                 g_partials;
CGMSessions                 g_sessions;

double   g_risk_pct;
int      g_min_score;
int      g_last_bull=0, g_last_bear=0;
double   g_day_start_balance;
datetime g_last_bar;
datetime g_trade_day;
int      g_trades_today;

// Spike retrace state
struct SpikeState { bool active; double spike_top; double spike_bot; int dir; datetime t; };
SpikeState g_spike = {};

double EffRisk() { return g_risk_pct * (UseIntelBridge ? g_bridge.RiskMult() : 1.0); }

//════════════════════════════════════════════════════════
//  ⚙️  INIT
//════════════════════════════════════════════════════════
int OnInit() {
   if(RiskPercent<=0 || MaxPositions<1 || MaxDailyLossPct<=0 || MaxDrawdownPct<=0) return INIT_PARAMETERS_INCORRECT;
   // Registro de parciales por ticket de pendiente no equivale a ticket de posición.
   if(!PaperModeOnly && UsePartials) { GM_Log("GLOBAL","Parciales requieren registro por deal: mantener PaperModeOnly",true); return INIT_PARAMETERS_INCORRECT; }
   g_symbol = Symbol();
   g_magic  = GM_MAGIC_BASE + 1000; // diferente al EA_v3 para coexistir

   g_atr_handle = iATR(g_symbol, PERIOD_CURRENT, ATR_Period);
   if(g_atr_handle == INVALID_HANDLE) {
      GM_Log("GLOBAL", "Error handle ATR", true); return INIT_FAILED;
   }

   // ── Módulos CORE ──────────────────────────────────────────────
   if(g_smc)    { delete g_smc;    g_smc    = NULL; }
   if(g_pending){ delete g_pending; g_pending = NULL; }
   if(g_posmgr) { delete g_posmgr;  g_posmgr  = NULL; }
   g_smc     = new CGoldMasterSMC(g_symbol, PERIOD_CURRENT);
   g_pending  = new CGoldMasterPending(g_symbol, g_magic, Verbose);
   g_posmgr   = new CGoldMasterPositionManager(g_magic, g_symbol);
   g_ml.Init(MLPredictionsPath, MinMLConfidence, MLMaxAgeSecs, MinMLVotes, 60);
   if(UseNewsFilter) g_news.Init();
   g_mtf.Init(g_symbol, EMA_Fast, EMA_Slow);
   g_vol.Init(g_symbol, ATR_Period, 100);
   g_spread.Init(g_symbol, 60);
   g_risk_pct  = RiskPercent;
   g_min_score = MinConfluenceScore;
   g_bridge.Init(IntelMaxAgeSecs);
   g_gm_minlot_risk_tol = MinLotRiskTol;

   // ── Módulos NUEVOS ────────────────────────────────────────────
   g_dxy.Init(DXYStatePath, DXY_MaxAgeSecs, UseDXYFilter);
   g_partials.Init(g_magic, g_atr_handle, RunnerTrail_ATR, Partial1_Pct, Partial2_Pct, UsePartials);
   g_sessions.Init(g_symbol);

   // ── Estado inicial ───────────────────────────────────────────
   GM_SymbolReport(g_symbol, RiskPercent, 10.0);
   EventSetTimer(1);
   g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_trade_day         = iTime(g_symbol, PERIOD_D1, 0);
   g_last_bar          = 0;
   g_trades_today      = 0;

   if(PaperModeOnly)
      GM_Log("GLOBAL", "⚠️  PAPER MODE — sin órdenes reales", true);

   GM_Log("GLOBAL", StringFormat(
      "GOLD MASTER GLOBAL v1.0 | %s | Riesgo:%.1f%% | DXY:%s | Parciales:%s | Sesiones:OK",
      g_symbol, RiskPercent,
      UseDXYFilter  ? "ON" : "OFF",
      UsePartials   ? "ON" : "OFF"), true);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   if(g_smc)     { delete g_smc;     g_smc     = NULL; }
   if(g_pending) { delete g_pending; g_pending = NULL; }
   if(g_posmgr)  { delete g_posmgr;  g_posmgr  = NULL; }
   IndicatorRelease(g_atr_handle);
   ObjectsDeleteAll(0, "GMG_");
   GM_Log("GLOBAL", "Deinit " + IntegerToString(reason), true);
}

//════════════════════════════════════════════════════════
//  ⏱️  TIMER — comandos Bridge + heartbeat
//════════════════════════════════════════════════════════
void OnTimer() {
   if(PaperModeOnly || MQLInfoInteger(MQL_TESTER)) return;
   GMCommand cmds[];
   int n = g_bridge.PollNew(cmds);
   for(int i=0;i<n;i++) {
      string c = cmds[i].cmd;
      if(c=="CLOSE_ALL")           { g_posmgr.CloseAll(); g_pending.CancelAllPending(); }
      else if(c=="CANCEL_PENDING") g_pending.CancelAllPending();
      else if(c=="SET_RISK")       g_risk_pct  = MathMax(0.05, MathMin(3.0, StringToDouble(cmds[i].a1)));
      else if(c=="SET_MINSCORE")   g_min_score = (int)StringToInteger(cmds[i].a1);
      GM_Log("BRIDGE", StringFormat("CMD %s %s", c, cmds[i].a1), true);
   }
   static int k=0;
   if(++k % 5 == 0) g_bridge.ReadIntel();
   g_bridge.WriteState("RUNNING", g_posmgr.CountPositions(), g_pending.CountPending(),
                        g_last_bull, g_last_bear);
}

//════════════════════════════════════════════════════════
//  🔍  SPIKE RETRACE — adaptado de EA1_Boom1000
//  Detecta vela spike enorme (≥ SpikeSize_ATR) y espera
//  retroceso ≥ 50% para entrar en contra del spike.
//  En XAU = reacción a NFP/CPI/Fed. PaperMode vetado.
//════════════════════════════════════════════════════════
void _detectSpike() {
   if(!UseSpikeRetrace) return;
   double atr_buf[1];
   if(CopyBuffer(g_atr_handle, 0, 1, 1, atr_buf) <= 0) return;
   double atr = atr_buf[0];
   MqlRates r[2];
   if(CopyRates(g_symbol, PERIOD_CURRENT, 1, 2, r) < 2) return;

   double body   = MathAbs(r[0].close - r[0].open);
   double range  = r[0].high - r[0].low;
   if(range < SpikeSize_ATR * atr) return; // no es spike

   bool spike_up   = (r[0].close > r[0].open) && (body > range * 0.7);
   bool spike_down = (r[0].close < r[0].open) && (body > range * 0.7);
   if(!spike_up && !spike_down) return;

   g_spike.active    = true;
   g_spike.spike_top = r[0].high;
   g_spike.spike_bot = r[0].low;
   g_spike.dir       = spike_up ? 1 : -1;
   g_spike.t         = r[0].time;
   GM_Log("GLOBAL", StringFormat("⚡ Spike detectado dir=%+d range=%.0f pts",
           g_spike.dir, range/_Point), true);
}

bool _checkSpikeRetrace(int &dir_out) {
   if(!UseSpikeRetrace || !g_spike.active) return false;
   // expirar spike tras 10 barras
   if(iBarShift(g_symbol, PERIOD_CURRENT, g_spike.t) > 10) {
      g_spike.active = false; return false;
   }
   double bid  = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double size = g_spike.spike_top - g_spike.spike_bot;
   if(size <= 0) return false;
   // Spike alcista → esperamos retroceso bajista ≥ 50% → SELL en retrace
   if(g_spike.dir == 1) {
      double retrace = (g_spike.spike_top - bid) / size;
      if(retrace >= SpikeRetrace_Pct) { dir_out = -1; g_spike.active = false; return true; }
   }
   // Spike bajista → retroceso alcista ≥ 50% → BUY en retrace
   if(g_spike.dir == -1) {
      double retrace = (bid - g_spike.spike_bot) / size;
      if(retrace >= SpikeRetrace_Pct) { dir_out = 1; g_spike.active = false; return true; }
   }
   return false;
}

//════════════════════════════════════════════════════════
//  📊  SCORE GLOBAL — suma score core + nuevos módulos
//════════════════════════════════════════════════════════
struct GMGlobalScore {
   int core;       // score de GMConfluenceScore (SMC + MTF + swings)
   int session;    // +0/+1/+2 según sesión
   int dxy;        // +1 confirma / -1 contra / 0 neutro
   int ry;         // rendimiento real: -1 si subiendo (presión bajista oro)
   int asian_bo;   // +1 si breakout del rango asiático a favor
   int total;
};

GMGlobalScore _calcGlobalScore(const GMConfluenceScore &core, int dir) {
   GMGlobalScore g;
   g.core    = core.total;
   g.session = UseSessionScore ? g_sessions.SessionScore() : 0;
   g.dxy     = UseDXYScoreAdjust ? g_dxy.ScoreAdjust(dir) : 0;
   g.ry      = (UseRealYieldBias && g_dxy.RealYieldBias() != 0)
               ? (dir == 1 ? -g_dxy.RealYieldBias() : g_dxy.RealYieldBias()) : 0;

   // Asian breakout extra: +1 si el precio acaba de romper el rango en dirección dir
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   g.asian_bo = 0;
   if(UseAsianBreakout && g_sessions.AsianRangeValid()) {
      double atr_buf[1];
      if(CopyBuffer(g_atr_handle,0,1,1,atr_buf)>0) {
         double min_move = AsianBreakout_MinATR * atr_buf[0];
         if(g_sessions.AsianBreakout(bid, dir)) {
            double overshoot = (dir==1) ? bid - g_sessions.AsianHigh()
                                        : g_sessions.AsianLow() - bid;
            if(overshoot >= min_move) g.asian_bo = 1;
         }
      }
   }
   g.total = g.core + g.session + g.dxy + g.ry + g.asian_bo;
   return g;
}

//════════════════════════════════════════════════════════
//  ✅  FILTROS PREVIOS A ENTRADA
//════════════════════════════════════════════════════════
bool _prefilter(int dir) {
   if(g_posmgr.CountPositions()+g_pending.CountPending()>=MaxPositions) return false;
   // DXY veto duro (no ajuste de score, sino bloqueo total)
   if(UseDXYFilter && g_dxy.DXYVeto(dir)) {
      if(Verbose) GM_Log("GLOBAL", StringFormat(
         "DXY veto dir=%+d | %s", dir, g_dxy.Summary()), false);
      return false;
   }
   // Sesión no operable
   bool sess_ok = false;
   switch(g_sessions.CurrentSession()) {
      case GMG_SESSION_LONDON:  sess_ok = TradeLondon;  break;
      case GMG_SESSION_OVERLAP: sess_ok = TradeOverlap; break;
      case GMG_SESSION_NY:      sess_ok = TradeNY;      break;
      case GMG_SESSION_DEAD:    sess_ok = TradeDead;    break;
      default:                 sess_ok = false; // Asia: no operar SMC
   }
   if(!sess_ok) return false;
   return true;
}

//════════════════════════════════════════════════════════
//  🏦  ENVÍO DE ORDEN (con PaperModeOnly)
//════════════════════════════════════════════════════════
ulong _sendOrder(int dir, double lot, double price, double sl, double tp1, double tp2) {
   if(lot<=0 || price<=0 || sl<=0 || (dir==1 && sl>=price) || (dir==-1 && sl<=price)) return 0;
   if(PaperModeOnly) {
      GM_Log("GLOBAL", StringFormat(
         "[PAPER] dir=%+d lot=%.2f price=%.3f sl=%.3f tp1=%.3f tp2=%.3f",
         dir, lot, price, sl, tp1, tp2), true);
      return 0;
   }
   // Esta ruta es de LIMIT: no transformar entradas de mercado en pendientes desplazadas.
   double ask=SymbolInfoDouble(g_symbol,SYMBOL_ASK),bid=SymbolInfoDouble(g_symbol,SYMBOL_BID);
   if(ask<=0 || bid<=0 || (dir==1 && price>=ask) || (dir==-1 && price<=bid)) return 0;
   // Enviar orden real (delegar a CGoldMasterPending)
   // tp externo = tp2 (runner se gestiona por Partials)
   ulong ticket = ((dir==1) ? g_pending.PlaceBuyLimit(price,sl,tp2,0,lot,"GLOBAL") : g_pending.PlaceSellLimit(price,sl,tp2,0,lot,"GLOBAL"));
   if(ticket > 0 && UsePartials) {
      g_partials.Register(ticket, price, sl, tp1, tp2, dir);
   }
   return ticket;
}

//════════════════════════════════════════════════════════
//  📈  OnTick PRINCIPAL
//════════════════════════════════════════════════════════
void OnTick() {
   g_spread.Tick();

   datetime cur_bar = iTime(g_symbol, PERIOD_CURRENT, 0);
   if(cur_bar == g_last_bar) {
      // En cada tick: gestionar parciales (runner)
      if(UsePartials && !PaperModeOnly) g_partials.Manage();
      return;
   }
   g_last_bar = cur_bar;

   // ── Actualizar módulos nueva barra ──────────────────────────
   g_sessions.UpdateAsianRange();
   _detectSpike();
   if(UsePartials && !PaperModeOnly) { g_partials.Purge(); g_partials.Manage(); }

   // ── Control de riesgo diario ─────────────────────────────────
   datetime today = iTime(g_symbol, PERIOD_D1, 0);
   if(today != g_trade_day) {
      g_trade_day         = today;
      g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_trades_today      = 0;
   }
   if(MQLInfoInteger(MQL_TESTER) && (UseIntelBridge || UseMLFilter || UseNewsFilter || UseDXYFilter)) return;
   double cur_balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double cur_equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_day_start_balance<=0 || cur_balance<=0 || cur_equity<=0) return;
   if((g_day_start_balance - cur_equity) / g_day_start_balance * 100 >= MaxDailyLossPct) {
      if(!PaperModeOnly) g_pending.CancelAllPending();
      GM_Log("GLOBAL", "Daily loss limit alcanzado — sin nuevas entradas hoy", true); return;
   }
   if((cur_equity - g_day_start_balance) < -g_day_start_balance * MaxDrawdownPct / 100) {
      GM_Log("GLOBAL", "Max drawdown alcanzado — cerrando todo", true);
      if(!PaperModeOnly) { g_posmgr.CloseAll(); g_pending.CancelAllPending(); } return;
   }
   if(g_posmgr.CountPositions() + g_pending.CountPending() >= MaxPositions) return;

   // ── Filtros globales ──────────────────────────────────────────
   if(UseNewsFilter && g_news.IsNewsTime(NewsFreezeMins, MinNewsImpact)) return;
   if(!g_spread.CanTrade()) return;
   if((g_vol.GetRegime(PERIOD_H1)==GM_VOL_HIGH)) return;

   // ── ATR + precio ─────────────────────────────────────────────
   double atr_buf[1];
   if(CopyBuffer(g_atr_handle, 0, 1, 1, atr_buf) <= 0) return;
   double atr = atr_buf[0];
   if(atr <= 0) return;

   // ── SMC: score de confluencia base ──────────────────────────
   GMSwing swings[]; int n_sw=g_smc.GetSwings(swings,100);
   int trend=g_smc.GetMarketTrend(swings,n_sw);
   GMMTFBias mtf=g_mtf.GetBias(PERIOD_H4,PERIOD_H1,PERIOD_M15);
   GMPremiumDiscount pd=g_smc.GetPremiumDiscount(50);
   double bid_score=SymbolInfoDouble(g_symbol,SYMBOL_BID);
   int ml_signal=UseMLFilter?g_ml.GetFilteredSignal():0;
   double ml_conf=UseMLFilter?g_ml.GetConfidence():0;
   ENUM_GM_VOLATILITY vol=g_vol.GetRegime(PERIOD_H1);
   GMConfluenceScore bull_score=GM_CalcConfluence(1,mtf.bias_htf,mtf.bias_mtf,mtf.bias_ltf,
      g_smc.DetectBOS_Bull(swings,n_sw),g_smc.DetectCHoCH_Bull(swings,n_sw,trend),false,false,
      g_smc.DetectLiquiditySweep(bid_score,false,5),bid_score<=pd.equilibrium,ml_signal,ml_conf,vol);
   GMConfluenceScore bear_score=GM_CalcConfluence(-1,mtf.bias_htf,mtf.bias_mtf,mtf.bias_ltf,
      g_smc.DetectBOS_Bear(swings,n_sw),g_smc.DetectCHoCH_Bear(swings,n_sw,trend),false,false,
      g_smc.DetectLiquiditySweep(bid_score,true,5),bid_score>=pd.equilibrium,ml_signal,ml_conf,vol);

   // Ajuste Intel Bridge Python
   if(UseIntelBridge) {
      double comp = g_bridge.Composite();
      if(comp != 0) {
         int adj = (int)MathRound(comp * IntelWeight);
         bull_score.total += adj;
         bear_score.total -= adj;
         if(comp < -IntelVeto) bull_score.total = 0;
         if(comp >  IntelVeto) bear_score.total = 0;
      }
   }

   // ML filter
   if(UseMLFilter) {
      if(!(g_ml.GetFilteredSignal()==1)) bull_score.total -= 2;
      if(!(g_ml.GetFilteredSignal()==-1)) bear_score.total -= 2;
   }

   g_last_bull = bull_score.total;
   g_last_bear = bear_score.total;

   // ── Score global con módulos nuevos ──────────────────────────
   GMGlobalScore bull_g = _calcGlobalScore(bull_score, 1);
   GMGlobalScore bear_g = _calcGlobalScore(bear_score, -1);

   if(Verbose && (bull_g.total > 3 || bear_g.total > 3))
      GM_Log("GLOBAL", StringFormat(
         "BULL=%d(core=%d ses=%d dxy=%d ry=%d bo=%d) BEAR=%d | %s | %s",
         bull_g.total, bull_g.core, bull_g.session, bull_g.dxy, bull_g.ry, bull_g.asian_bo,
         bear_g.total, g_sessions.Summary(), g_dxy.Summary()), false);

   // ── SPIKE RETRACE (prioridad alta — en cualquier sesión) ──────
   int spike_dir = 0;
   if(_checkSpikeRetrace(spike_dir) && _prefilter(spike_dir)) {
      double entry = (spike_dir==1) ? SymbolInfoDouble(g_symbol,SYMBOL_ASK)
                                    : SymbolInfoDouble(g_symbol,SYMBOL_BID);
      double sl    = entry - spike_dir * ATR_SL_Mult  * atr;
      double tp1   = entry + spike_dir * ATR_TP1_Mult * atr;
      double tp2   = entry + spike_dir * ATR_TP2_Mult * atr;
      double lot   = GM_CalcLot(g_symbol, EffRisk(), MathAbs(entry-sl));
      GM_Log("GLOBAL", StringFormat("🎯 SPIKE RETRACE dir=%+d lot=%.2f", spike_dir, lot), true);
      _sendOrder(spike_dir, lot, entry, sl, tp1, tp2);
      return;
   }

   // ── ENTRADAS SMC NORMAL con score global ─────────────────────
   // Order Blocks
   GMOB obs[];
   g_smc.GetOrderBlocks(obs,30);
   for(int i=0; i<ArraySize(obs); i++) {
      if(obs[i].mitigated || !obs[i].is_bull || obs[i].quality<MinOBQuality) continue;
      if(!_prefilter(1)) break;
      int score = bull_g.total + 2; // +2 OB
      if(score >= g_min_score) {
         double lot = GM_CalcLot(g_symbol, EffRisk(), ATR_SL_Mult*atr);
         double sl  = obs[i].bottom  - ATR_SL_Mult  * atr;
         double tp1 = obs[i].top + ATR_TP1_Mult * atr;
         double tp2 = obs[i].top + ATR_TP2_Mult * atr;
         GM_Log("GLOBAL", StringFormat("BUY OB q:%d score:%d ses:%s dxy:%+d",
                obs[i].quality, score, g_sessions.SessionName(), bull_g.dxy), true);
         _sendOrder(1, lot, obs[i].bottom, sl, tp1, tp2);
      }
   }
   g_smc.GetOrderBlocks(obs,30);
   for(int i=0; i<ArraySize(obs); i++) {
      if(obs[i].mitigated || obs[i].is_bull || obs[i].quality<MinOBQuality) continue;
      if(!_prefilter(-1)) break;
      int score = bear_g.total + 2;
      if(score >= g_min_score) {
         double lot = GM_CalcLot(g_symbol, EffRisk(), ATR_SL_Mult*atr);
         double sl  = obs[i].top + ATR_SL_Mult  * atr;
         double tp1 = obs[i].bottom  - ATR_TP1_Mult * atr;
         double tp2 = obs[i].bottom  - ATR_TP2_Mult * atr;
         GM_Log("GLOBAL", StringFormat("SELL OB q:%d score:%d ses:%s dxy:%+d",
                obs[i].quality, score, g_sessions.SessionName(), bear_g.dxy), true);
         _sendOrder(-1, lot, obs[i].top, sl, tp1, tp2);
      }
   }

   // FVG fills
   GMFVG fvgs[];
   g_smc.GetFVGs(fvgs,50);
   for(int i=0; i<ArraySize(fvgs); i++) {
      if(fvgs[i].filled || !fvgs[i].is_bull) continue;
      if(!_prefilter(1)) break;
      int score = bull_g.total + 1;
      if(score >= g_min_score) {
         double sl  = fvgs[i].bottom  - ATR_SL_Mult  * atr;
         double tp1 = fvgs[i].top + ATR_TP1_Mult * atr;
         double tp2 = fvgs[i].top + ATR_TP2_Mult * atr;
         double lot = GM_CalcLot(g_symbol, EffRisk(), MathAbs(fvgs[i].bottom-sl));
         GM_Log("GLOBAL", StringFormat("BUY FVG fill:%.0f%% score:%d", fvgs[i].fill_pct, score), true);
         _sendOrder(1, lot, fvgs[i].bottom, sl, tp1, tp2);
      }
   }
   g_smc.GetFVGs(fvgs,50);
   for(int i=0; i<ArraySize(fvgs); i++) {
      if(fvgs[i].filled || fvgs[i].is_bull) continue;
      if(!_prefilter(-1)) break;
      int score = bear_g.total + 1;
      if(score >= g_min_score) {
         double sl  = fvgs[i].top + ATR_SL_Mult  * atr;
         double tp1 = fvgs[i].bottom  - ATR_TP1_Mult * atr;
         double tp2 = fvgs[i].bottom  - ATR_TP2_Mult * atr;
         double lot = GM_CalcLot(g_symbol, EffRisk(), MathAbs(fvgs[i].top-sl));
         GM_Log("GLOBAL", StringFormat("SELL FVG fill:%.0f%% score:%d", fvgs[i].fill_pct, score), true);
         _sendOrder(-1, lot, fvgs[i].top, sl, tp1, tp2);
      }
   }

   // ── ASIAN BREAKOUT directo (alta confianza, sin OB/FVG requerido) ─
   if(UseAsianBreakout && g_sessions.AsianRangeValid()) {
      double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
      // Breakout alcista del rango asiático → BUY en pullback
      if(g_sessions.AsianBreakout(ask, 1) && _prefilter(1)) {
         int score = bull_g.total + bull_g.asian_bo;
         if(score >= g_min_score && bull_g.asian_bo > 0) {
            double sl  = g_sessions.AsianHigh() - ATR_SL_Mult * atr;
            double tp1 = ask + ATR_TP1_Mult * atr;
            double tp2 = ask + ATR_TP2_Mult * atr;
            double lot = GM_CalcLot(g_symbol, EffRisk(), MathAbs(ask-sl));
            GM_Log("GLOBAL", StringFormat("BUY AsianBreakout score:%d asian_H:%.3f",
                   score, g_sessions.AsianHigh()), true);
            _sendOrder(1, lot, ask, sl, tp1, tp2);
         }
      }
      // Breakout bajista
      if(g_sessions.AsianBreakout(bid, -1) && _prefilter(-1)) {
         int score = bear_g.total + bear_g.asian_bo;
         if(score >= g_min_score && bear_g.asian_bo > 0) {
            double sl  = g_sessions.AsianLow() + ATR_SL_Mult * atr;
            double tp1 = bid - ATR_TP1_Mult * atr;
            double tp2 = bid - ATR_TP2_Mult * atr;
            double lot = GM_CalcLot(g_symbol, EffRisk(), MathAbs(bid-sl));
            GM_Log("GLOBAL", StringFormat("SELL AsianBreakout score:%d asian_L:%.3f",
                   score, g_sessions.AsianLow()), true);
            _sendOrder(-1, lot, bid, sl, tp1, tp2);
         }
      }
   }
}

//+------------------------------------------------------------------+
