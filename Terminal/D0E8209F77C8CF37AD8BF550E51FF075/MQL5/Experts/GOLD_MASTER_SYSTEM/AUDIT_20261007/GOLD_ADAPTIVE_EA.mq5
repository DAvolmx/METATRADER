//+──────────────────────────────────────────────────────────────────────────+
//│  GOLD ADAPTIVE EA v1.0                                                   │
//│  Sistema adaptativo: carga reglas desde rules_db.json, filtra sesión     │
//│  Londres, gestión de riesgo micro-cuenta ($10), PaperMode=true por def.  │
//+──────────────────────────────────────────────────────────────────────────+
#property strict
#property copyright "GoldMaster System"
#property version   "1.01"
#property tester_file "GoldMaster\\rules_db.json"

#include <Trade\Trade.mqh>
#include <GoldMaster\GoldMaster_Logger.mqh>

//─── Inputs ──────────────────────────────────────────────────────────────────
input double   RiskPctPerTrade  = 3.0;    // % de balance por trade
input double   RiskCashPerTrade = 0.0;   // 0: porcentual; >0: tope de pérdida al SL en moneda de cuenta
input double   MinLot           = 0.01;   // Lote mínimo micro-cuenta
input double   MaxLot           = 0.10;   // Lote máximo
input double   MinRuleScore     = 0.60;   // Score mínimo para activar regla
input int      LondonOpenHour   = 7;      // UTC hora apertura Londres
input int      LondonCloseHour  = 10;     // UTC hora cierre filtro
input bool     PaperModeOnly    = true;   // NUNCA abrir trades reales
input string   RulesDBPath      = "GoldMaster\\rules_db.json";
input bool     RulesUseCommon   = false;  // false: MQL5/Files + snapshot del tester
input int      RuleReloadMins   = 15;     // Recargar reglas cada N minutos
input double   SL_ATR_Mult      = 1.5;    // SL = 1.5 × ATR(14)
input double   TP_RR_Ratio      = 2.0;    // TP = SL × RR ratio
input int      MagicNumber      = 20241;


//─── Globales ─────────────────────────────────────────────────────────────────
CTrade   g_trade;
datetime g_lastRuleLoad   = 0;
int      g_activeRules    = 0;
string   g_ruleNames[];
double   g_ruleScores[];
double   g_ruleWR[];
double   g_rulePF[];
bool     g_rulesLoaded    = false;
int      g_atrHandle      = INVALID_HANDLE;
ulong    g_lastBarTime    = 0;

//─── OnInit ───────────────────────────────────────────────────────────────────
int OnInit() {
   g_gm_logger.SetName("AdaptiveEA");
   g_gm_logger.SetMinLevel(GM_LOG_INFO);
   g_gm_logger.EnableFile();
   GM_LOG_I("Init", StringFormat("PaperMode=%s MinLot=%.2f RiskPct=%.1f%%",
            PaperModeOnly?"ON":"OFF", MinLot, RiskPctPerTrade));

   if(PaperModeOnly)
      GM_LOG_W("Init", "*** PAPER MODE ACTIVO — sin trades reales ***");

   g_trade.SetExpertMagicNumber(MagicNumber);
   g_trade.SetDeviationInPoints(30);

   g_atrHandle = iATR(_Symbol, PERIOD_H1, 14);
   if(g_atrHandle == INVALID_HANDLE) {
      GM_LOG_E("Init", "No se pudo crear handle ATR");
      return INIT_FAILED;
   }

   LoadRulesFromJSON();
   GM_LOG_I("Init", StringFormat("Reglas cargadas: %d activas (score>=%.2f)",
            g_activeRules, MinRuleScore));
   return INIT_SUCCEEDED;
}


//─── LoadRulesFromJSON ────────────────────────────────────────────────────────
// Lee rules_db.json producido por gm_rules_db.py
// Formato esperado: {"rules":[{"name":"...","score":0.8,"win_rate":0.55,...},...]}
void LoadRulesFromJSON() {
   // Record every attempt, including failures; otherwise missing files retry per tick.
   g_lastRuleLoad = TimeCurrent();
   int flags = FILE_READ|FILE_TXT|FILE_ANSI;
   if(RulesUseCommon) flags |= FILE_COMMON;
   int fh = FileOpen(RulesDBPath, flags, 0, CP_UTF8);
   if(fh == INVALID_HANDLE) {
      GM_LOG_W("Rules", StringFormat("rules_db.json no encontrado: %s (common=%s). Exportar con python/gm_rules_bridge.py; reintento en %d min.", RulesDBPath, RulesUseCommon?"SI":"NO", MathMax(1,RuleReloadMins)));
      g_activeRules = 0;
      g_rulesLoaded = false;
      return;
   }
   string raw = "";
   while(!FileIsEnding(fh))
      raw += FileReadString(fh);
   FileClose(fh);

   // Reset arrays
   ArrayResize(g_ruleNames,  0);
   ArrayResize(g_ruleScores, 0);
   ArrayResize(g_ruleWR,     0);
   ArrayResize(g_rulePF,     0);
   g_activeRules = 0;

   // Parse manual: buscar bloques {"name":"...","score":N,"win_rate":N,"profit_factor":N}
   int pos = 0;
   while(true) {
      int nameStart = StringFind(raw, "\"name\":", pos);
      if(nameStart < 0) break;
      nameStart += 7;
      int q1 = StringFind(raw, "\"", nameStart);
      int q2 = StringFind(raw, "\"", q1+1);
      if(q1 < 0 || q2 < 0) break;
      string rName = StringSubstr(raw, q1+1, q2-q1-1);
      int objEnd = StringFind(raw, "}", q2);
      if(objEnd < 0) break;
      string object = StringSubstr(raw, nameStart-7, objEnd-(nameStart-7));
      double rScore = _ExtractDouble(object, "\"score\":", 0);
      double rWR    = _ExtractDouble(object, "\"win_rate\":", 0);
      double rPF    = _ExtractDouble(object, "\"profit_factor\":", 0);
      // Only the implemented signal may be consumed; BOS/news rules are not EMA rules.
      bool eligible = _ExtractBool(object,"active") && _ExtractBool(object,"validated")
                      && !_ExtractBool(object,"test_only")
                      && _ExtractString(object,"asset") == _Symbol
                      && _ExtractString(object,"tf") == "M15"
                      && _ExtractString(object,"implementation") == "EMA_CROSS_M15_H1"
                      && _ExtractDouble(object,"\"evidence_trades\":",0) >= 30
                      && _ExtractDouble(object,"\"validated_at\":",0) > 0
                      && _ExtractDouble(object,"\"validated_at\":",0) <= (double)TimeCurrent();
      if(eligible && rScore >= MinRuleScore && rScore <= 1.0) {
         int sz = ArraySize(g_ruleNames);
         ArrayResize(g_ruleNames,  sz+1);
         ArrayResize(g_ruleScores, sz+1);
         ArrayResize(g_ruleWR,     sz+1);
         ArrayResize(g_rulePF,     sz+1);
         g_ruleNames[sz]  = rName;
         g_ruleScores[sz] = rScore;
         g_ruleWR[sz]     = rWR;
         g_rulePF[sz]     = rPF;
         g_activeRules++;
      }
      pos = objEnd+1;
   }
   g_rulesLoaded = true;
   g_lastRuleLoad = TimeCurrent();
   GM_LOG_I("Rules", StringFormat("JSON parseado: %d reglas activas", g_activeRules));
}


//─── Helpers ──────────────────────────────────────────────────────────────────
double _ExtractDouble(const string &s, string key, int startPos) {
   int k = StringFind(s, key, startPos);
   if(k < 0) return 0.0;
   k += StringLen(key);
   // Skip spaces/colon
   while(k < StringLen(s) && (StringGetCharacter(s,k)==' ' || StringGetCharacter(s,k)==':'))
      k++;
   string numStr = "";
   while(k < StringLen(s)) {
      ushort c = StringGetCharacter(s, k);
      if((c>='0' && c<='9') || c=='.' || c=='-') { numStr += ShortToString(c); k++; }
      else break;
   }
   return (numStr == "") ? 0.0 : StringToDouble(numStr);
}

bool _ExtractBool(const string &s, string key) {
   int k=StringFind(s,"\""+key+"\":");
   if(k<0) return false;
   k+=StringLen(key)+3;
   while(k<StringLen(s) && StringGetCharacter(s,k)==' ') k++;
   return StringSubstr(s,k,4)=="true";
}

string _ExtractString(const string &s, string key) {
   int k=StringFind(s,"\""+key+"\":");
   if(k<0) return "";
   int a=StringFind(s,"\"",k+StringLen(key)+3);
   int b=StringFind(s,"\"",a+1);
   if(a<0 || b<0) return "";
   return StringSubstr(s,a+1,b-a-1);
}

bool IsLondonSession() {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= LondonOpenHour && dt.hour < LondonCloseHour);
}

double GetATR() {
   double atrBuf[1];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, atrBuf) < 1) return 0.0;
   return atrBuf[0];
}

double CalcLotSize(double slPoints) {
   if(slPoints <= 0) return 0.0;   // señal inválida → rechazar, no forzar mínimo
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskUSD    = balance * RiskPctPerTrade / 100.0;
   if(RiskCashPerTrade > 0) riskUSD = RiskCashPerTrade;
   if(riskUSD <= 0 || riskUSD >= AccountInfoDouble(ACCOUNT_EQUITY)) return 0.0;
   double tickVal    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0) return 0.0;
   double lotRaw     = riskUSD / (slPoints / tickSize * tickVal);
   double step       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double brokerMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double brokerMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0 || brokerMin <= 0 || brokerMax < brokerMin) return 0.0;
   double effectiveMin = MathMax(MinLot,brokerMin);
   double lot = MathFloor(MathMin(lotRaw,MathMin(MaxLot,brokerMax)) / step + 1e-9) * step;
   // Si el lot calculado < MinLot, el riesgo real excede el presupuesto → rechazar
   // (no forzar MinLot: eso ignora el riesgo y viola la gestión de capital)
   if(lot < effectiveMin){
      double costAtMinLot = (slPoints / tickSize * tickVal) * effectiveMin;
      double riskPct      = balance > 0 ? costAtMinLot / balance * 100.0 : 999;
      GM_LOG_W("CalcLot", StringFormat(
         "SL=%.1f pts → lote requerido %.4f < mínimo %.2f (riesgo real %.2f%% > presupuesto %.2f%%) → señal rechazada",
         slPoints, lotRaw, effectiveMin, riskPct, balance>0 ? riskUSD/balance*100.0 : 0));
      return 0.0;  // 0.0 = señal rechazada por riesgo excesivo
   }
   return lot;
}


//─── EvalSignal ───────────────────────────────────────────────────────────────
// Devuelve: +1=BUY, -1=SELL, 0=NADA
// Lógica: si hay ≥1 regla activa con score alto, votación por dirección
// basada en MAs (M15: fast>slow=BUY) + confirmación H1
int EvalSignal() {
   if(!g_rulesLoaded || g_activeRules == 0) return 0;

   // MA rápida/lenta M15
   double maFast[], maSlow[];
   int hFast = iMA(_Symbol, PERIOD_M15, 20, 0, MODE_EMA, PRICE_CLOSE);
   int hSlow = iMA(_Symbol, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
   if(hFast==INVALID_HANDLE || hSlow==INVALID_HANDLE) {
      if(hFast!=INVALID_HANDLE) IndicatorRelease(hFast);
      if(hSlow!=INVALID_HANDLE) IndicatorRelease(hSlow);
      return 0;
   }
   if(CopyBuffer(hFast,0,1,2,maFast)<2 || CopyBuffer(hSlow,0,1,2,maSlow)<2) {
      IndicatorRelease(hFast); IndicatorRelease(hSlow); return 0;
   }
   IndicatorRelease(hFast); IndicatorRelease(hSlow);

   bool crossUp   = (maFast[1] > maSlow[1] && maFast[0] <= maSlow[0]);
   bool crossDown = (maFast[1] < maSlow[1] && maFast[0] >= maSlow[0]);

   // Filtro H1: precio sobre/bajo MA50
   double maH1[];
   int hH1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   double close = iClose(_Symbol, PERIOD_H1, 1);
   if(hH1 == INVALID_HANDLE) return 0;
   if(CopyBuffer(hH1,0,1,1,maH1)<1 || close<=0) { IndicatorRelease(hH1); return 0; }
   bool trendUp = close > maH1[0];
   IndicatorRelease(hH1);

   // Peso de reglas activas (score ponderado)
   double totalScore = 0;
   for(int i=0; i<g_activeRules; i++) totalScore += g_ruleScores[i];
   if(totalScore < MinRuleScore) return 0;

   if(crossUp  && trendUp)  return  1;
   if(crossDown && !trendUp) return -1;
   return 0;
}


//─── OnTick ───────────────────────────────────────────────────────────────────
void OnTick() {
   // Recargar reglas periódicamente
   // Tester keeps its initial snapshot immutable for the entire historical run.
   if(!MQLInfoInteger(MQL_TESTER) && TimeCurrent() - g_lastRuleLoad >= MathMax(1,RuleReloadMins) * 60)
      LoadRulesFromJSON();

   // Solo operar en nueva vela M15
   ulong barTime = (ulong)iTime(_Symbol, PERIOD_M15, 0);
   if(barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;

   // Filtro de sesión Londres
   if(!IsLondonSession()) return;

   // Verificar que no hay posición abierta en este símbolo
   if(PositionsTotal() > 0) {
      for(int i=0; i<PositionsTotal(); i++) {
         if(PositionGetSymbol(i) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber) return;
      }
   }

   // Evaluar señal
   int sig = EvalSignal();
   if(sig == 0) return;

   double atr = GetATR();
   if(atr <= 0) { GM_LOG_W("Tick","ATR=0, skip"); return; }

   double slDist = atr * SL_ATR_Mult;
   double tpDist = slDist * TP_RR_Ratio;
   double lot    = CalcLotSize(slDist);
   if(lot <= 0.0){
      GM_LOG_I("OnNewBar", "Señal descartada — lote inviable con el riesgo configurado");
      return;
   }
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double slPrice, tpPrice, entryPrice;
   if(sig == 1) {
      entryPrice = ask;
      slPrice    = NormalizeDouble(ask - slDist, digits);
      tpPrice    = NormalizeDouble(ask + tpDist, digits);
   } else {
      entryPrice = bid;
      slPrice    = NormalizeDouble(bid + slDist, digits);
      tpPrice    = NormalizeDouble(bid - tpDist, digits);
   }

   string dir = (sig==1) ? "BUY" : "SELL";
   GM_LOG_I("Signal", StringFormat("%s | ATR=%.5f SL=%.5f TP=%.5f Lot=%.2f [PAPER=%s]",
            dir, atr, slPrice, tpPrice, lot, PaperModeOnly?"ON":"OFF"));

   if(PaperModeOnly) {
      // Log paper trade — sin ejecución real
      g_gm_logger.Trade(dir+"_PAPER", _Symbol, lot, entryPrice, slPrice, tpPrice,
                        StringFormat("Rules=%d Score=%.2f", g_activeRules,
                        g_activeRules>0 ? g_ruleScores[0] : 0.0));
      return;
   }

   // Ejecución real (solo si PaperModeOnly=false explícitamente)
   bool ok = (sig==1) ? g_trade.Buy(lot, _Symbol, ask, slPrice, tpPrice, "GM_Adaptive")
                      : g_trade.Sell(lot, _Symbol, bid, slPrice, tpPrice, "GM_Adaptive");
   if(ok)
      g_gm_logger.Trade(dir, _Symbol, lot, entryPrice, slPrice, tpPrice,
                        StringFormat("RetCode=%d", g_trade.ResultRetcode()));
   else
      GM_LOG_E("Order", StringFormat("Fallo %s: %d - %s", dir,
               g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
}

//─── OnDeinit ─────────────────────────────────────────────────────────────────
void OnDeinit(const int reason) {
   GM_LOG_I("Deinit", StringFormat("Razón=%d Reglas=%d", reason, g_activeRules));
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   g_gm_logger.Close();
}

// END GOLD_ADAPTIVE_EA.mq5
