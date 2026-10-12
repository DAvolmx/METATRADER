//+------------------------------------------------------------------+
//| GOLD_MASTER_PULLBACK_EA.mq5                                       |
//| Estrategia ganadora del laboratorio (M15, 4.2 años de datos):     |
//|  Tendencia: EMA50>EMA200 en M15 y EMA50 de H4 subiendo (ventas    |
//|  al revés). Gatillo: RSI(14) cruza de vuelta el nivel 30 (70).    |
//|  SL: detrás del último mínimo/máximo + 0.25 ATR (1–4 ATR).        |
//|  TP: 1.5R. Una posición a la vez. Sesión 07–20 servidor.          |
//+------------------------------------------------------------------+
#property copyright "GOLD MASTER SYSTEM"
#property version   "1.00"
#include <Trade\Trade.mqh>
#include <GoldMaster/GoldMaster_Core.mqh>
#include <GoldMaster/GoldMaster_Panel.mqh>
#include <GoldMaster/GoldMaster_Bridge.mqh>
#include <GoldMaster/GoldMaster_Assets.mqh>

GM_AssetProfile g_asset;   // perfil del activo detectado automáticamente

enum GM_MODE { MODE_VALIDADO=0, // Parámetros base; rentabilidad no certificada
               MODE_AGRESIVO=1  // Agresivo: más señales, más riesgo, 2 posiciones
             };
input group "=== MODO ==="
input GM_MODE Mode            = MODE_VALIDADO;
input group "=== ESTRATEGIA (valores optimizados) ==="
input ENUM_TIMEFRAMES TF      = PERIOD_M15;
input ENUM_TIMEFRAMES HTF     = PERIOD_H4;
input int    RSI_Level        = 30;      // compra al cruzar hacia arriba; venta al cruzar 100-N hacia abajo
input double TP_R             = 1.5;
input double MinSL_ATR        = 1.0;
input double MaxSL_ATR        = 4.0;
input double SLPadATR         = 0.25;
input double BE_R             = 1.5;     // a partir de N R, stop a +LockR
input double LockR            = 0.3;
input int    MaxBarsInTrade   = 96;      // cierre por tiempo (24 h en M15)
input int    SessionStart     = 7;
input int    SessionEnd       = 20;
input group "=== RIESGO ==="
input double RiskPct          = 2.0;     // % del balance por operación
input double RiskCashPerTrade = 0.0;     // 0: porcentual; >0: tope de pérdida al SL en moneda de cuenta
input double MinLotRiskTol    = 2.5;     // acepta lote mínimo hasta N× el riesgo objetivo
input double MaxSpreadPts     = 60;
input int    MagicNumber      = 900020;
input int    MaxPositions     = 1;       // modo agresivo usa 2 (la 2ª sólo si la 1ª ya está asegurada)
input group "=== INTELIGENCIA (servicio Python gm_service.py) ==="
input bool   UseIntel         = true;    // bloqueo por noticias / gobernador de riesgo / multiplicador de volatilidad
input bool   SkipRangeRegime  = false;
input bool   RequireAutonomous= true;    // sólo abre si el dashboard tiene MODO AUTÓNOMO = ON (en vivo)   // no operar si el régimen cuantitativo es RANGE o HIGH_VOL

CTrade trade; CGMPanel g_panel; CGMBridge g_br;
double g_risk, g_tp; int g_rsi, g_ss, g_se, g_maxpos;
bool g_nofilt=false; string BTN="GM_PB_BTN", GVF;
void DrawBtn(){ GM_Button(BTN,10,40,230,g_nofilt?"⚠ SIN FILTROS (opera siempre)":"✔ FILTROS DE RIESGO: ON",g_nofilt?clrFireBrick:C'20,110,60'); }
int hE50,hE200,hRSI,hATR,hHE; datetime g_last=0; string g_status="";

int OnInit(){
   g_asset = GM_GetProfile(_Symbol);
   GM_LogProfile(g_asset);
   GM_TFBadgeAsset("PULLBACK EA", g_asset.tf_daytrade, g_asset.name, g_asset.icon);
   if(!MQLInfoInteger(MQL_TESTER) && GM_IsDuplicateInstance()){ ExpertRemove(); return INIT_SUCCEEDED; }
   hE50=iMA(_Symbol,TF,50,0,MODE_EMA,PRICE_CLOSE); hE200=iMA(_Symbol,TF,200,0,MODE_EMA,PRICE_CLOSE);
   hRSI=iRSI(_Symbol,TF,14,PRICE_CLOSE); hATR=iATR(_Symbol,TF,14); hHE=iMA(_Symbol,HTF,50,0,MODE_EMA,PRICE_CLOSE);
   if(hE50<0||hE200<0||hRSI<0||hATR<0||hHE<0) return INIT_FAILED;
   trade.SetExpertMagicNumber(MagicNumber); trade.SetTypeFilling(GM_FillingMode(_Symbol)); trade.SetDeviationInPoints(50);
   g_gm_minlot_risk_tol=MinLotRiskTol;
   g_risk=RiskPct; g_tp=TP_R; g_rsi=RSI_Level; g_ss=SessionStart; g_se=SessionEnd; g_maxpos=MaxPositions;
   if(Mode==MODE_AGRESIVO){ g_risk=MathMax(RiskPct,3.0); g_rsi=MathMax(RSI_Level,38); g_tp=MathMax(TP_R,2.0); g_ss=0; g_se=24; g_maxpos=MathMax(MaxPositions,2);
      Print("[PULLBACK] MODO AGRESIVO: riesgo ",g_risk,"% · RSI ",g_rsi," · TP ",g_tp,"R · 24h · hasta ",g_maxpos," posiciones (NO validado en backtest)"); }
   g_panel.InitWithAsset("PB",g_asset,10,120); g_br.Init(180);
   // Detectar modo replay automáticamente
   if(MQLInfoInteger(MQL_TESTER)) g_panel.SetReplayMode(true,_Symbol);
   GVF="GM_PB_NOFILT_"+_Symbol; g_nofilt = !MQLInfoInteger(MQL_TESTER) && GlobalVariableCheck(GVF) && GlobalVariableGet(GVF)>0; DrawBtn();
   return INIT_SUCCEEDED;
}
void OnDeinit(const int r){ g_panel.Destroy(); ObjectDelete(0,BTN); }
void OnChartEvent(const int id,const long &l,const double &d,const string &s){
   g_panel.OnEvent(id,l,d,s);
   if(id==CHARTEVENT_OBJECT_CLICK && s==BTN){
      g_nofilt=!g_nofilt; GlobalVariableSet(GVF,g_nofilt?1:0); DrawBtn();
      Print(g_nofilt?"[PULLBACK] MODO SIN FILTROS: se ignoran noticias, gobernador de riesgo, régimen, DXY shock, sesión, spread y el tope de riesgo del lote mínimo. El SL y el TP se siguen poniendo."
                    :"[PULLBACK] Filtros de riesgo reactivados.");
   }
}

double B(int h,int sh){ double v[]; return CopyBuffer(h,0,sh,1,v)>0?v[0]:0; }
double SwingStop(int dir){
   for(int i=3;i<100;i++){
      bool ok=true;
      if(dir>0){ double l=iLow(_Symbol,TF,i); for(int j=1;j<=2&&ok;j++) if(iLow(_Symbol,TF,i-j)<l||iLow(_Symbol,TF,i+j)<l) ok=false; if(ok) return l; }
      else     { double h=iHigh(_Symbol,TF,i); for(int j=1;j<=2&&ok;j++) if(iHigh(_Symbol,TF,i-j)>h||iHigh(_Symbol,TF,i+j)>h) ok=false; if(ok) return h; }
   }
   return 0;
}
int MyCount(bool &allSecured){ int n=0; allSecured=true;
   for(int i=PositionsTotal()-1;i>=0;i--){ ulong tk=PositionGetTicket(i);
      if(PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC)==MagicNumber && PositionGetString(POSITION_SYMBOL)==_Symbol){
         n++; int d=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
         if((PositionGetDouble(POSITION_SL)-PositionGetDouble(POSITION_PRICE_OPEN))*d<0) allSecured=false; } }
   return n; }
bool MyPos(ulong &t){ for(int i=PositionsTotal()-1;i>=0;i--){ ulong tk=PositionGetTicket(i); if(PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC)==MagicNumber && PositionGetString(POSITION_SYMBOL)==_Symbol){ t=tk; return true; } } return false; }

void Manage(ulong t){
   if(!PositionSelectByTicket(t)) return;
   int dir = PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
   double op=PositionGetDouble(POSITION_PRICE_OPEN), sl=PositionGetDouble(POSITION_SL), tp=PositionGetDouble(POSITION_TP);
   double px = dir>0?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   string cm=PositionGetString(POSITION_COMMENT); double r0=StringToDouble(StringSubstr(cm,StringFind(cm,"R=")+2)); if(r0<=0) r0=MathAbs(op-sl);
   if(r0>0 && (px-op)*dir>=BE_R*r0 && (sl-op)*dir<LockR*r0-_Point)
      trade.PositionModify(t,NormalizeDouble(op+dir*LockR*r0,_Digits),tp);
   datetime ot=(datetime)PositionGetInteger(POSITION_TIME);
   int age=iBarShift(_Symbol,TF,ot);  // P11 — proteger retorno -1
   if(age>0 && age>=MaxBarsInTrade) trade.PositionClose(t);
}

void OnTick(){
   for(int i=PositionsTotal()-1;i>=0;i--){ ulong tk=PositionGetTicket(i);
      if(PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC)==MagicNumber && PositionGetString(POSITION_SYMBOL)==_Symbol) Manage(tk); }
   bool sec=true; int npos=MyCount(sec); bool has = npos>=g_maxpos || (npos>0 && !sec);
   datetime bt=iTime(_Symbol,TF,0); if(bt==g_last) return; g_last=bt;
   double c=iClose(_Symbol,TF,1), e50=B(hE50,1), e200=B(hE200,1), r1=B(hRSI,1), r2=B(hRSI,2), a=B(hATR,1);
   double h1=B(hHE,1), h2=B(hHE,2);
   MqlDateTime dt; TimeToStruct(iTime(_Symbol,TF,1),dt);
   bool up = e50>e200 && h1>h2 && c>e200, dn = e50<e200 && h1<h2 && c<e200;
   int dir = (up && r2<g_rsi && r1>=g_rsi) ? 1 : (dn && r2>100-g_rsi && r1<=100-g_rsi) ? -1 : 0;
   g_status=StringFormat("GOLD MASTER · PULLBACK "+(Mode==MODE_AGRESIVO?"AGRESIVO ":"")+"%s\nTendencia: %s · RSI %.1f\nSesión: %s · %s",EnumToString(TF),up?"ALCISTA":dn?"BAJISTA":"sin tendencia",r1,
            (dt.hour>=g_ss&&dt.hour<g_se)?"abierta":"cerrada", has?"posición abierta":"esperando gatillo");
   g_panel.Show(g_status);
   string intelTxt="intel: sin servicio";
   double rmult=1.0;
   if(UseIntel && !MQLInfoInteger(MQL_TESTER) && (!g_br.ReadIntel() || !g_br.Valid())) {
      g_panel.Show(g_status+"\nINTEL ausente, caducada o de otro símbolo: entradas bloqueadas"); return;
   }
   if(UseIntel && !g_nofilt && !MQLInfoInteger(MQL_TESTER) && g_br.ReadIntel() && g_br.Valid()){
      GMIntel q=g_br.Data(); rmult=g_br.RiskMult();
      intelTxt=StringFormat("intel: %s · riesgo x%.2f · cartera %.1f%%%s%s",q.regime_q,rmult,q.port_risk_pct,g_br.BlockTrading()?" · BLOQUEO":"",q.override_on?" · SIN FILTROS":"");
      if(dir!=0 && g_br.BlockTrading()){ Print("[PULLBACK] señal ignorada: bloqueo (noticias o riesgo de cartera)"); dir=0; }
      if(dir!=0 && q.dxy_shock==-dir){ Print("[PULLBACK] señal ignorada: DXY SHOCK en contra"); dir=0; }
      if(dir!=0 && SkipRangeRegime && q.override_on==0 && (q.regime_q=="RANGE"||q.regime_q=="HIGH_VOL")){ Print("[PULLBACK] señal ignorada: régimen ",q.regime_q); dir=0; }
   }
   bool autoOK = MQLInfoInteger(MQL_TESTER) || !RequireAutonomous || (g_br.ReadIntel() && g_br.AutoTrade());
   if(!autoOK){ intelTxt+="\nMODO AUTÓNOMO OFF → sólo gestiona"; if(dir!=0) Print("[PULLBACK] señal ",dir>0?"BUY":"SELL"," no ejecutada: modo autónomo OFF"); dir=0; }
   g_panel.Show(g_status+"\n"+(g_nofilt?"⚠ SIN FILTROS — opera siempre":intelTxt));
   if(has || dir==0 || a<=0 || rmult<=0) return;
   if(!g_nofilt && (dt.hour<g_ss || dt.hour>=g_se)) return;
   if(!g_nofilt && SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)>MaxSpreadPts) return;
   double entry = dir>0?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sw=SwingStop(dir), risk = sw>0 ? (entry-(sw-dir*SLPadATR*a))*dir : MinSL_ATR*a;
   risk=MathMin(MathMax(risk,MinSL_ATR*a),MaxSL_ATR*a);
   double sl=entry-dir*risk, tp=entry+dir*risk*g_tp;
   g_gm_minlot_risk_tol = g_nofilt ? 1000.0 : MinLotRiskTol;      // sin filtros: siempre al menos el lote mínimo
   double lot=GM_CalcLot(_Symbol,g_risk*rmult,risk,RiskCashPerTrade);
   if(lot<=0){ Print("[PULLBACK] Skip: lote mínimo excede el riesgo permitido (SL ",DoubleToString(risk,2),")"); return; }
   string cmt="GM_PB R="+DoubleToString(risk,_Digits);
   bool ok = dir>0 ? trade.Buy(lot,_Symbol,0,NormalizeDouble(sl,_Digits),NormalizeDouble(tp,_Digits),cmt)
                   : trade.Sell(lot,_Symbol,0,NormalizeDouble(sl,_Digits),NormalizeDouble(tp,_Digits),cmt);
   PrintFormat("[PULLBACK] %s %.2f SL %.2f TP %.2f (%.2f$ de riesgo en precio) %s",dir>0?"BUY":"SELL",lot,sl,tp,risk,ok?"OK":"ERROR "+IntegerToString(trade.ResultRetcode()));
}
