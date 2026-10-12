//+──────────────────────────────────────────────────────────────────────────+
//│          GOLD MASTER SYSTEM — Expert Advisor v3.1                        │
//│  EA principal: SMC + ML ensemble + News filter + Confluence scoring       │
//│  Requiere: GoldMaster_Core.mqh, _SMC.mqh, _PendingOrders.mqh,            │
//│            _PositionManager.mqh, _ML.mqh                                 │
//+──────────────────────────────────────────────────────────────────────────+
#property copyright "Gold Master System v3.1"
#property version   "3.10"
#property strict

#include <GoldMaster/GoldMaster_Core.mqh>
#include <GoldMaster/GoldMaster_SMC.mqh>
#include <GoldMaster/GoldMaster_PendingOrders.mqh>
#include <GoldMaster/GoldMaster_PositionManager.mqh>
#include <GoldMaster/GoldMaster_ML.mqh>
#include <GoldMaster/GoldMaster_Bridge.mqh>

//════════════════════════════════════════════════════════
//  INPUTS
//════════════════════════════════════════════════════════
input group "=== RIESGO ==="
input double RiskPercent        = 0.5;    // % riesgo por trade
input double MaxDailyLossPct    = 2.0;    // % pérdida máxima diaria
input double MaxDrawdownPct     = 5.0;    // % drawdown máximo
input int    MaxPositions       = 3;      // posiciones simultáneas

input group "=== CONFLUENCIA ==="
input int    MinConfluenceScore = 6;      // score mínimo para entrar (0-17)
input int    MinMLVotes         = 2;      // votos ML mínimos (1-3)
input double MinMLConfidence    = 0.62;   // confianza ML mínima
input bool   RequireHTFBias     = true;   // exigir sesgo HTF alineado
input bool   UseMLFilter        = true;   // usar predicciones ML

input group "=== SMC ==="
input int    ATR_Period         = 14;
input double ATR_SL_Mult        = 1.5;    // SL = ATR * multiplicador
input double ATR_TP1_Mult       = 3.0;    // TP1
input double ATR_TP2_Mult       = 5.0;    // TP2
input double ATR_TP3_Mult       = 8.0;    // TP3 (runner)
input int    OB_Expiry_Candles  = 48;     // expiración órdenes en OB
input int    FVG_Expiry_Candles = 24;
input int    MinOBQuality       = 50;     // calidad mínima OB (0-100)

input group "=== NOTICIAS ==="
input bool   UseNewsFilter      = true;
input int    NewsFreezeMins     = 30;     // minutos a bloquear
input int    MinNewsImpact      = 3;      // 2=medio+, 3=solo alto

input group "=== SESIONES ==="
input bool   TradeLondon        = true;
input bool   TradeOverlap       = true;
input bool   TradeNY            = true;
input bool   TradeTokio         = false;

input group "=== MULTI-TF EMA ==="
input int    EMA_Fast           = 21;
input int    EMA_Slow           = 50;
input bool   UseEMABias         = true;

input group "=== ML BRIDGE ==="
input string MLPredictionsPath  = "GoldMaster\\ml_predictions.csv";
input string MLFeaturesPath     = "GoldMaster\\ml_features.csv";
input int    MLMaxAgeSecs       = 300;    // predicción válida 5 min

input group "=== INTEL BRIDGE (Python) ==="
input bool   UseIntelBridge     = true;   // usar sentimiento/flow/COT del dashboard
input int    IntelMaxAgeSecs    = 120;    // intel válida si tiene < N s
input int    IntelWeight        = 3;      // puntos de confluencia que aporta el compuesto
input double IntelVeto          = 0.55;   // |compuesto| > veto bloquea el lado contrario

input group "=== CUENTA MICRO / CENT ==="
input double MinLotRiskTol      = 1.5;   // acepta lote mínimo si su riesgo <= riesgo×tol

input group "=== MISC ==="
input bool   Verbose            = true;
input color  ColorBull          = clrDeepSkyBlue;
input color  ColorBear          = clrOrangeRed;

//════════════════════════════════════════════════════════
//  GLOBALS
//════════════════════════════════════════════════════════
string   g_symbol;
int      g_atr_handle=INVALID_HANDLE;
int      g_ema_fast=INVALID_HANDLE,g_ema_slow=INVALID_HANDLE,g_ema_200=INVALID_HANDLE;
int      g_magic;

CGoldMasterSMC*            g_smc    = NULL;
CGoldMasterPending*         g_pending = NULL;
CGoldMasterPositionManager* g_posmgr  = NULL;
CGMLBridge              g_ml;
CGMNewsFilter           g_news;
CGMMTFBiasEngine        g_mtf;
CGMVolatilityRegime     g_vol;
CGMSpreadMonitor        g_spread;
CGMBridge               g_bridge;
double                  g_risk_pct;
int                     g_min_score;
int                     g_last_bull=0, g_last_bear=0;

double EffRisk() { return g_risk_pct * (UseIntelBridge ? g_bridge.RiskMult() : 1.0); }

// Control de riesgo diario
double   g_day_start_balance;
datetime g_last_bar;
datetime g_trade_day;
int      g_trades_today;

//════════════════════════════════════════════════════════
//  INICIALIZACIÓN
//════════════════════════════════════════════════════════
int OnInit() {
   if(RiskPercent<=0 || MaxDailyLossPct<=0 || MaxDrawdownPct<=0 || MaxPositions<1 ||
      ATR_Period<1 || EMA_Fast<1 || EMA_Slow<=EMA_Fast) return INIT_PARAMETERS_INCORRECT;
   g_symbol = Symbol();
   g_magic  = GM_MAGIC_BASE;

   // Handles indicadores
   g_atr_handle = iATR(g_symbol, PERIOD_CURRENT, ATR_Period);
   if(g_atr_handle == INVALID_HANDLE) {
      GM_Log("EA_v3", "Error creando handle ATR", true);
      return INIT_FAILED;
   }

   g_ema_fast=iMA(g_symbol,PERIOD_CURRENT,EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   g_ema_slow=iMA(g_symbol,PERIOD_CURRENT,EMA_Slow,0,MODE_EMA,PRICE_CLOSE);
   g_ema_200=iMA(g_symbol,PERIOD_CURRENT,200,0,MODE_EMA,PRICE_CLOSE);
   if(g_ema_fast==INVALID_HANDLE || g_ema_slow==INVALID_HANDLE || g_ema_200==INVALID_HANDLE) return INIT_FAILED;

   // Módulos
   if(g_smc)    { delete g_smc;    g_smc    = NULL; }
   if(g_pending){ delete g_pending; g_pending = NULL; }
   if(g_posmgr) { delete g_posmgr;  g_posmgr  = NULL; }
   g_smc    = new CGoldMasterSMC(g_symbol, PERIOD_CURRENT);
   g_pending = new CGoldMasterPending(g_symbol, g_magic, Verbose);
   g_posmgr  = new CGoldMasterPositionManager(g_magic, g_symbol);

   // ML
   g_ml.Init(MLPredictionsPath, MinMLConfidence, MLMaxAgeSecs, MinMLVotes, 60);

   // News filter
   if(UseNewsFilter) g_news.Init();

   // MTF bias
   g_mtf.Init(g_symbol, EMA_Fast, EMA_Slow);

   // Volatility regime
   g_vol.Init(g_symbol, ATR_Period, 100);

   // Spread monitor
   g_spread.Init(g_symbol, 60);

   // Bridge Python
   g_risk_pct  = RiskPercent;
   g_min_score = MinConfluenceScore;
   g_bridge.Init(IntelMaxAgeSecs);
   g_gm_minlot_risk_tol = MinLotRiskTol;
   GM_SymbolReport(g_symbol, RiskPercent, 10.0);
   EventSetTimer(1);

   // Recuperar referencia diaria por cuenta/símbolo/magic tras reiniciar.
   SyncDailyRisk();
   g_last_bar          = 0;
   g_trades_today      = 0;

   GM_Log("EA_v3", StringFormat("GoldMaster EA v3.1 iniciado | %s | Riesgo:%.1f%%", g_symbol, RiskPercent), true);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   if(g_smc)     { delete g_smc;     g_smc     = NULL; }
   if(g_pending) { delete g_pending; g_pending = NULL; }
   if(g_posmgr)  { delete g_posmgr;  g_posmgr  = NULL; }
   IndicatorRelease(g_atr_handle);
   IndicatorRelease(g_ema_fast); IndicatorRelease(g_ema_slow); IndicatorRelease(g_ema_200);
   ObjectsDeleteAll(0, "GM_");
   GM_Log("EA_v3", "Deinit reason: " + IntegerToString(reason), true);
}

//════════════════════════════════════════════════════════
//  TIMER 1s: comandos del dashboard + heartbeat + intel
//════════════════════════════════════════════════════════
void OnTimer() {
   if(MQLInfoInteger(MQL_TESTER)) return; // No consumir comandos/intel actuales en historia.
   GMCommand cmds[];
   int n = g_bridge.PollNew(cmds);
   for(int i=0;i<n;i++) {
      string c = cmds[i].cmd;
      if(c=="CLOSE_ALL")           { g_posmgr.CloseAll(); g_pending.CancelAllPending(); }
      else if(c=="CANCEL_PENDING") g_pending.CancelAllPending();
      else if(c=="SET_RISK")       g_risk_pct  = MathMax(0.05, MathMin(3.0, StringToDouble(cmds[i].a1)));
      else if(c=="SET_MINSCORE")   g_min_score = (int)StringToInteger(cmds[i].a1);
      GM_Log("BRIDGE", StringFormat("CMD #%d %s %s", cmds[i].id, c, cmds[i].a1), true);
   }
   static int k=0;
   if(++k % 5 == 0) g_bridge.ReadIntel();
   g_bridge.WriteState("RUNNING", g_posmgr.CountPositions(), g_pending.CountPending(), g_last_bull, g_last_bear);
}

//════════════════════════════════════════════════════════
//  TICK PRINCIPAL
//════════════════════════════════════════════════════════
void OnTick() {
   // Actualizar monitor de spread en cada tick
   g_spread.Tick();

   double manage_atr=GM_GetATR(g_atr_handle,1);
   if(manage_atr>0) g_posmgr.SetATR(manage_atr);
   g_posmgr.ManageAll();

   // Solo procesar en nueva barra
   datetime cur_bar = iTime(g_symbol, PERIOD_CURRENT, 0);
   if(cur_bar == g_last_bar) {
      // En cada tick: gestionar posiciones existentes
      double atr = GM_GetATR(g_atr_handle);
      g_posmgr.SetATR(atr);
      g_posmgr.ManageAll();
      return;
   }
   g_last_bar = cur_bar;

   // === 1. CONTROLES DE RIESGO ===
   if(!CheckRiskLimits()) { g_pending.CancelAllPending(); return; }
   if(MQLInfoInteger(MQL_TESTER) && (UseIntelBridge || UseMLFilter || UseNewsFilter)) {
      UpdateInfoPanel("TESTER: requiere filtros externos desactivados o snapshots historicos"); return;
   }
   if(g_bridge.IsPaused()) { g_pending.CancelAllPending(); UpdateInfoPanel("PAUSADO desde dashboard"); return; }
   if(UseIntelBridge && g_bridge.BlockTrading()) { g_pending.CancelAllPending(); UpdateInfoPanel("INTEL FREEZE: "+g_bridge.Intel().next_news); return; }
   if(UseIntelBridge && EffRisk() <= 0) return;

   // === 2. FILTROS PREVIOS ===
   // Spread
   if(!g_spread.CanTrade()) {
      GM_Log("EA_v3", StringFormat("Spread alto: %d pts", GM_GetSpread(g_symbol)), Verbose);
      return;
   }

   // Noticias
   if(UseNewsFilter && g_news.IsNewsTime(NewsFreezeMins, MinNewsImpact)) {
      string next_n = g_news.NextNewsName(MinNewsImpact);
      GM_Log("EA_v3", "Bloqueado por noticias: " + next_n, Verbose);
      UpdateInfoPanel("NEWS FREEZE: " + next_n);
      return;
   }

   // Sesión
   ENUM_GM_SESSION session = GM_GetSession();
   if(!IsSessionAllowed(session)) return;

   // Max posiciones
   if(g_posmgr.CountPositions() >= MaxPositions) return;
   if(g_pending.CountPending() >= MaxPositions * 2) return;

   // === 3. DATOS DE MERCADO ===
   double atr = GM_GetATR(g_atr_handle);
   if(atr < SymbolInfoDouble(g_symbol, SYMBOL_POINT) * 10) return; // ATR inválido

   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);

   // Gestionar posiciones abiertas
   g_posmgr.SetATR(atr);
   g_posmgr.ManageAll();

   // === 4. ANÁLISIS SMC ===
   GMBias bias = g_smc.GetFullBias(100);

   // Swings para detección de estructura
   GMSwing swings[];
   int sw_cnt = g_smc.GetSwings(swings, 100);
   int trend  = g_smc.GetMarketTrend(swings, sw_cnt);

   // Premium/Discount
   GMPremiumDiscount pd = g_smc.GetPremiumDiscount(50);
   bool in_discount = (bid <= pd.equilibrium);
   bool in_premium  = (bid >= pd.equilibrium);

   // Liquidez
   GMLiqLevel liqs[];
   int liq_cnt = g_smc.GetLiquidityLevels(liqs, 100);

   // Detectar sweeps
   bool liq_sweep_bull = g_smc.DetectLiquiditySweep(bid, false, 5); // sweep de lows → bull
   bool liq_sweep_bear = g_smc.DetectLiquiditySweep(bid, true,  5); // sweep de highs → bear

   // Inducements
   bool ind_bull = g_smc.DetectInducement_Bull(swings, sw_cnt, liqs, liq_cnt);
   bool ind_bear = g_smc.DetectInducement_Bear(swings, sw_cnt, liqs, liq_cnt);

   // === 5. SESGO MULTI-TF ===
   GMMTFBias mtf_bias; ZeroMemory(mtf_bias);
   if(UseEMABias) {
      mtf_bias = g_mtf.GetBias(PERIOD_H4, PERIOD_H1, PERIOD_M15);
   }

   // === 6. VOLATILIDAD ===
   ENUM_GM_VOLATILITY vol_regime = g_vol.GetRegime(PERIOD_H1);
   // Evitar operar en alta volatilidad sin estructura clara
   if(vol_regime == GM_VOL_HIGH && bias.confluence < 5) {
      GM_Log("EA_v3", "Alta volatilidad sin confluencia, esperando...", Verbose);
      return;
   }

   // === 7. SEÑAL ML ===
   int    ml_signal = 0;
   double ml_conf   = 0;
   if(UseMLFilter) {
      ml_signal = g_ml.GetFilteredSignal();
      ml_conf   = g_ml.GetConfidence();
      // Exportar features actuales para que Python las procese
      g_ml.WriteFeatures(g_symbol, bid, atr,
         GM_GetEMA(g_ema_fast, 1),
         GM_GetEMA(g_ema_slow, 1),
         GM_GetEMA(g_ema_200, 1),
         trend, 0.0, (int)session, bias.confluence);
   }

   // === 8. SCORING DE CONFLUENCIA ===
   // Señal BULL
   GMConfluenceScore bull_score = GM_CalcConfluence(
      1,
      mtf_bias.bias_htf, mtf_bias.bias_mtf, mtf_bias.bias_ltf,
      g_smc.DetectBOS_Bull(swings, sw_cnt),
      g_smc.DetectCHoCH_Bull(swings, sw_cnt, trend),
      false, false,  // OB/FVG se evalúan por separado (pendientes)
      liq_sweep_bull,
      in_discount,   // OTE proxy: en descuento = zona óptima bull
      ml_signal, ml_conf, vol_regime
   );

   GMConfluenceScore bear_score = GM_CalcConfluence(
      -1,
      mtf_bias.bias_htf, mtf_bias.bias_mtf, mtf_bias.bias_ltf,
      g_smc.DetectBOS_Bear(swings, sw_cnt),
      g_smc.DetectCHoCH_Bear(swings, sw_cnt, trend),
      false, false,
      liq_sweep_bear,
      in_premium,
      ml_signal, ml_conf, vol_regime
   );

   // === 8b. INTEL (sentimiento + order flow + COT + régimen) ===
   if(UseIntelBridge && g_bridge.Valid()) {
      double comp = g_bridge.Composite();
      int adj = (int)MathRound(comp * IntelWeight);
      bull_score.total += adj;
      bear_score.total -= adj;
      if(comp < -IntelVeto) bull_score.total = 0;   // flujo/sentimiento fuertemente bajista: no comprar
      if(comp >  IntelVeto) bear_score.total = 0;
      GM_Log("EA_v3", g_bridge.Status(), Verbose);
   }
   g_last_bull = bull_score.total; g_last_bear = bear_score.total;

   GM_Log("EA_v3", StringFormat("BULL_SCORE:%d BEAR_SCORE:%d | %s | Vol:%s",
      bull_score.total, bear_score.total,
      g_ml.StatusString(),
      GM_VolatilityName(vol_regime)), Verbose);

   // === 9. ÓRDENES PENDIENTES EN ORDER BLOCKS ===
   GMOB obs[];
   int ob_cnt = g_smc.GetOrderBlocks(obs, 30);

   for(int i=0; i<ob_cnt; i++) {
      if(g_posmgr.CountPositions()+g_pending.CountPending()>=MaxPositions) break;
      if(obs[i].mitigated) continue;
      if(obs[i].quality < MinOBQuality) continue;

      if(obs[i].is_bull && obs[i].top < bid && in_discount) {
         // OB bull debajo del precio en zona descuento
         int score_with_ob = bull_score.total + 2; // +2 por tener OB
         if(score_with_ob >= g_min_score) {
            if(RequireHTFBias && mtf_bias.bias_htf != 1) continue;
            double tp = obs[i].top + atr * ATR_TP3_Mult;
            g_pending.PlaceOBBuyLimit(obs[i], tp, EffRisk(), OB_Expiry_Candles);
            GM_Log("EA_v3", StringFormat("BuyLimit OB q:%d score:%d", obs[i].quality, score_with_ob), true);
            GM_DrawRect("GM_OB_B_"+IntegerToString(i), obs[i].t_start, obs[i].bottom, obs[i].t_end, obs[i].top, ColorBull);
         }
      }

      if(!obs[i].is_bull && obs[i].bottom > bid && in_premium) {
         // OB bear encima del precio en zona premium
         int score_with_ob = bear_score.total + 2;
         if(score_with_ob >= g_min_score) {
            if(RequireHTFBias && mtf_bias.bias_htf != -1) continue;
            double tp = obs[i].bottom - atr * ATR_TP3_Mult;
            g_pending.PlaceOBSellLimit(obs[i], tp, EffRisk(), OB_Expiry_Candles);
            GM_Log("EA_v3", StringFormat("SellLimit OB q:%d score:%d", obs[i].quality, score_with_ob), true);
            GM_DrawRect("GM_OB_S_"+IntegerToString(i), obs[i].t_start, obs[i].bottom, obs[i].t_end, obs[i].top, ColorBear);
         }
      }
   }

   // === 10. ÓRDENES PENDIENTES EN FVGs ===
   GMFVG fvgs[];
   int fvg_cnt = g_smc.GetFVGs(fvgs, 50);

   for(int i=0; i<fvg_cnt; i++) {
      if(g_posmgr.CountPositions()+g_pending.CountPending()>=MaxPositions) break;
      if(fvgs[i].filled) continue;
      if(fvgs[i].fill_pct > 50) continue; // ya muy llenado

      if(fvgs[i].is_bull && fvgs[i].top < bid && in_discount) {
         int score_with_fvg = bull_score.total + 1;
         if(score_with_fvg >= g_min_score) {
            if(RequireHTFBias && mtf_bias.bias_htf != 1) continue;
            double tp = fvgs[i].top + atr * ATR_TP3_Mult;
            g_pending.PlaceFVGBuyLimit(fvgs[i], tp, EffRisk(), FVG_Expiry_Candles);
            GM_Log("EA_v3", StringFormat("BuyLimit FVG fill:%.0f%% score:%d", fvgs[i].fill_pct, score_with_fvg), true);
         }
      }

      if(!fvgs[i].is_bull && fvgs[i].bottom > bid && in_premium) {
         int score_with_fvg = bear_score.total + 1;
         if(score_with_fvg >= g_min_score) {
            if(RequireHTFBias && mtf_bias.bias_htf != -1) continue;
            double tp = fvgs[i].bottom - atr * ATR_TP3_Mult;
            g_pending.PlaceFVGSellLimit(fvgs[i], tp, EffRisk(), FVG_Expiry_Candles);
            GM_Log("EA_v3", StringFormat("SellLimit FVG fill:%.0f%% score:%d", fvgs[i].fill_pct, score_with_fvg), true);
         }
      }
   }

   // === 11. INFO PANEL ===
   UpdateInfoPanel(StringFormat(
      "Session:%s Vol:%s Score B:%d S:%d | %s | %s",
      GM_SessionName(session),
      GM_VolatilityName(vol_regime),
      bull_score.total, bear_score.total,
      GM_MTFBiasStr(mtf_bias),
      g_ml.StatusString()
   ));
}

//════════════════════════════════════════════════════════
//  FUNCIONES AUXILIARES
//════════════════════════════════════════════════════════

void SyncDailyRisk() {
   MqlDateTime now; TimeToStruct(TimeCurrent(),now);
   now.hour=0;now.min=0;now.sec=0;
   datetime today=StructToTime(now);
   string key="GM_DAILY_"+IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))+"_"+
              IntegerToString(g_magic)+"_"+StringSubstr(g_symbol,0,15);
   bool tester=(bool)MQLInfoInteger(MQL_TESTER);
   if(g_trade_day==today && g_day_start_balance>0) return;
   g_trade_day=today;
   g_trades_today=0;
   double reference=AccountInfoDouble(ACCOUNT_EQUITY);
   if(!tester && GlobalVariableCheck(key+"_DAY") &&
      (datetime)GlobalVariableGet(key+"_DAY")==today && GlobalVariableCheck(key+"_BASE")) {
      double saved=GlobalVariableGet(key+"_BASE");
      if(saved>0) reference=saved;
   }
   g_day_start_balance=reference;
   if(!tester && reference>0) {
      GlobalVariableSet(key+"_BASE",reference);
      GlobalVariableSet(key+"_DAY",(double)today);
      GlobalVariablesFlush();
   }
}

bool CheckRiskLimits() {
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);

   SyncDailyRisk();

   if(balance<=0 || g_day_start_balance<=0 || equity<=0) return false;

   // Daily loss limit
   double day_pnl_pct = (equity - g_day_start_balance) / g_day_start_balance * 100.0;
   if(day_pnl_pct < -MaxDailyLossPct) {
      GM_Log("EA_v3", StringFormat("Daily loss limit: %.2f%%", day_pnl_pct), true);
      return false;
   }

   // Drawdown limit
   double dd_pct = (equity - balance) / balance * 100.0;
   if(dd_pct < -MaxDrawdownPct) {
      GM_Log("EA_v3", StringFormat("Max drawdown: %.2f%%", dd_pct), true);
      return false;
   }

   return true;
}

bool IsSessionAllowed(ENUM_GM_SESSION s) {
   switch(s) {
      case GM_SESSION_TOKIO:   return TradeTokio;
      case GM_SESSION_LONDON:  return TradeLondon;
      case GM_SESSION_OVERLAP: return TradeOverlap;
      case GM_SESSION_NY:      return TradeNY;
      default:                 return false;
   }
}

void UpdateInfoPanel(string info) {
   string name = "GM_PANEL";
   double ask  = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double atr  = GM_GetATR(g_atr_handle);
   if(ObjectFind(0, name) >= 0) {
      ObjectSetString(0, name, OBJPROP_TEXT, " " + info);
      ObjectSetInteger(0, name, OBJPROP_TIME, TimeCurrent());
      ObjectSetDouble(0, name, OBJPROP_PRICE, ask + atr * 2.0);
   } else {
      GM_DrawText(name, TimeCurrent(), ask + atr * 2.0, info, clrYellow, 8, true);
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &req,
                        const MqlTradeResult &res) {
   // Registrar slippage si es una nueva deal
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && trans.deal > 0) {
      double expected = req.price;
      double actual   = trans.price;
      if(expected > 0 && actual > 0) {
         bool is_buy = (trans.deal_type == DEAL_TYPE_BUY);
         g_spread.LogSlippage(expected, actual, is_buy);
      }
   }
}
