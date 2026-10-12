//+------------------------------------------------------------------+
//| GOLD_MASTER_PRO_Signals.mq5                                       |
//| Señales profesionales M1/M5/M15: ENTRADA + SL + TP1/TP2/TP3       |
//| - Estructura sin repintado (BOS/CHoCH) + tendencia EMA50/200      |
//| - Confluencia multi-temporalidad (M1·M5·M15·H1·H4) → grado A+/A/B |
//| - Caja de operación gráfica, lote sugerido y estadística real     |
//|   (tasa de acierto TP1/TP2/TP3 sobre el historial del gráfico)    |
//+------------------------------------------------------------------+
#property copyright "GOLD MASTER SYSTEM"
#property version   "2.00"
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2
#property indicator_type1 DRAW_ARROW
#property indicator_color1 clrDodgerBlue
#property indicator_width1 3
#property indicator_label1 "Señal COMPRA"
#property indicator_type2 DRAW_ARROW
#property indicator_color2 clrTomato
#property indicator_width2 3
#property indicator_label2 "Señal VENTA"

#include <GoldMaster/GoldMaster_Structure.mqh>
#include <GoldMaster/GoldMaster_Panel.mqh>
#include <GoldMaster/GoldMaster_Assets.mqh>

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
enum ENTRY_MODE { ENTRY_OTE=2,    // OTE: retroceso 50-62% del impulso (recomendado)
                  ENTRY_RETEST=0, // Retesteo del nivel roto (límite)
                  ENTRY_CLOSE=1   // Cierre de la vela de ruptura (mercado)
                };

input group "=== SEÑAL ==="
input ENTRY_MODE EntryMode     = ENTRY_OTE;
input double OTE_Level          = 0.5;      // 0.5 = mitad del impulso, 0.618 = OTE profundo

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "=== MODO EN VIVO (señal siempre activa) ==="
input bool   LiveMode           = true;     // siempre una posición Buy/Sell activa (estilo flip), ideal M1
input int    DEMAFast           = 21;
input int    DEMASlow           = 89;       // optimizado (walk-forward 3 meses M1)
input int    ChannelLen         = 50;       // canal de regresión lineal
input double ChannelDev         = 2.0;      // no perseguir: fuera de ±N desvíos no hay señal
input int    LiveMinScore       = 3;        // puntuación mínima (de 6) a favor de la dirección
input double LiveSL_ATR         = 1.2;
input bool   LiveUseSession     = false;    // false = señales 24h (antes se perdían los movimientos de Asia)
input bool   SweepSignals       = true;
input bool   UseAutoParams      = true;     // usar los parámetros re-entrenados por gm_service.py (signal_params.txt)     // reversión: barrido de liquidez de una zona + recuperación (atrapa suelos/techos en V)      // SL mínimo en ATR si el swing queda muy cerca

input group "=== FILTROS PROFESIONALES ==="
input bool   UseHTFFilter       = true;     // EMA50 del TF superior a favor (M1→M15, M5→H1, M15→H4)
input double MinDisplacementATR = 0.8;      // cuerpo de la vela de ruptura ≥ X·ATR (desplazamiento real)
input int    ER_Period          = 20;       // Kaufman Efficiency Ratio (filtro anti-rango)
input double MinER              = 0.30;     // <0.30 = mercado lateral → no operar
input bool   UseSession         = true;
input int    SessionStart       = 7;        // hora servidor (Deriv = UTC): Londres
input int    SessionEnd         = 20;       // fin de Nueva York
input int    CooldownBarsAfterSL= 10;       // pausa tras un stop
input int    SwingStrength      = 2;
input int    MaxSpreadPts       = 40;       // spread máximo permitido en puntos (filtro de calidad)
input int    BarsToAnalyze      = 1500;     // mínimo; se amplía a HistoryDays
input int    HistoryDays        = 30;       // historial mínimo analizado (días)
input bool   AllowCHoCH         = true;     // aceptar CHoCH a favor de la tendencia EMA
input int    EMAFast            = 50;
input int    EMASlow            = 200;
input int    RetestExpiryBars   = 10;       // velas para que llegue al retesteo
input double SLPadATR           = 0.25;
input double MinSL_ATR          = 0.6;
input double MaxSL_ATR          = 3.5;
input double TP1_R              = 1.0;
input double TP2_R              = 2.0;
input double TP3_R              = 3.0;
input int    MinGrade           = 1;        // 0=todas, 1=B o mejor, 2=A o mejor, 3=solo A+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "=== ZONAS DE COMPRA / VENTA (1 mes, H1) ==="
input bool   ShowZones          = true;
input int    ZoneDays           = 30;
input int    ZoneSwingStrength  = 3;
input double ZoneTolATR         = 0.30;     // ancho de zona en ATR(H1)
input int    ZoneMinTouches     = 2;
input int    ZonesPerSide       = 4;
input double MinRoomR           = 1.2;      // espacio mínimo hasta la zona contraria (en R)
input color  ColDemand          = C'0,70,90';
input color  ColSupply          = C'90,20,50';

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "=== RIESGO (lote sugerido) ==="
input double RiskPct            = 1.0;

input group "=== TIEMPO REAL / TEMPORALIDAD ==="
input bool   RealTimePreview    = true;     // aviso "señal formándose" en la vela actual (cada tick)
input int    TimerMs            = 500;      // refresco independiente de ticks (ms)
input int    MaxBarsM1          = 12000;    // tope de velas en M1 (latencia)
input string RecommendedTFs     = "M1,M5,M15"; // temporalidades válidas para este indicador

input group "=== VISUAL / ALERTAS ==="
input int    ExtendBars         = 25;
input int    HistoryBoxes       = 5;        // cajas pasadas visibles
input bool   AlertPopup         = true;
input bool   AlertPush          = true;     // notificación al móvil
input color  ColEntry           = clrWhite;
input color  ColSL              = C'120,25,35';
input color  ColTP              = C'15,90,55';

double bufBuy[], bufSell[];
int g_pF=21, g_pS=89, g_pMS=3;
double g_pTP1=1, g_pTP2=2, g_pTP3=3, g_pSL=1.2;
string g_pInfo="manual";
datetime g_pChk=0;
void LoadAutoParams()
  {
   if(!UseAutoParams || TimeCurrent()-g_pChk<300)
      return;
   g_pChk=TimeCurrent();
   int h=FileOpen("GoldMaster\\signal_params.txt",FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ);
   if(h==INVALID_HANDLE)
      return;
   int f=g_pF,sl=g_pS,ms=g_pMS;
   double tp=g_pTP2,sa=g_pSL;
   bool upd=false;
   string oos="";
   while(!FileIsEnding(h))
     {
      string ln=FileReadString(h);
      int p=StringFind(ln,"=");
      if(p<0)
         continue;
      string k=StringSubstr(ln,0,p), v=StringSubstr(ln,p+1);
      if(k=="updated")
         upd=(v=="True");
      else
         if(k=="fast")
            f=(int)StringToInteger(v);
         else
            if(k=="slow")
               sl=(int)StringToInteger(v);
            else
               if(k=="minscore")
                  ms=(int)StringToInteger(v);
               else
                  if(k=="tp")
                     tp=StringToDouble(v);
                  else
                     if(k=="slatr")
                        sa=StringToDouble(v);
                     else
                        if(k=="oos_exp")
                           oos=v;
     }
   FileClose(h);
   if(!upd)
      return;
   if(f!=g_pF || sl!=g_pS)
     {
      g_pF=f;
      g_pS=sl;
      IndicatorRelease(hDF);
      IndicatorRelease(hDS);
      hDF=iDEMA(_Symbol,PERIOD_CURRENT,g_pF,0,PRICE_CLOSE);
      hDS=iDEMA(_Symbol,PERIOD_CURRENT,g_pS,0,PRICE_CLOSE);
     }
   g_pMS=ms;
   g_pTP2=tp;
   g_pTP1=tp/2;
   g_pTP3=tp*1.5;
   g_pSL=sa;
   g_pInfo=StringFormat("auto %d/%d s%d tp%.1f (OOS %sR)",g_pF,g_pS,g_pMS,g_pTP2,oos);
  }
int    hFast=INVALID_HANDLE, hSlow=INVALID_HANDLE, hHTF=INVALID_HANDLE, hDF=INVALID_HANDLE, hDS=INVALID_HANDLE;
datetime g_last_bar=0, g_last_alert=0;
const string P="GMPS_";
CGMPanel g_panel;

struct Setup
  {
   int               dir;
   int               bar;
   datetime          t;
   double            entry, sl, tp1, tp2, tp3, risk;
   int               filled_bar;
   int               result;   // result: -1 SL, 0 abierto/pendiente, 1..3 TP alcanzado, -9 expirado
   bool              be_after_tp1;
   int               grade;
   bool              choch;
   int               hb1,hb2,hb3,slb;
   bool              closed;
   bool              mkt;
   int               score;
  };
Setup g_s[];
int g_ns=0;

//──────────────────────────────────────────────────────────────────
ENUM_TIMEFRAMES HigherTF()
  {
   switch(_Period)
     {
      case PERIOD_M1:
         return PERIOD_M15;
      case PERIOD_M5:
         return PERIOD_H1;
      case PERIOD_M15:
         return PERIOD_H4;
      default:
         return PERIOD_D1;
     }
  }
string TFName(ENUM_TIMEFRAMES tf) { string s=EnumToString(tf); return StringSubstr(s,7); }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0,bufBuy,INDICATOR_DATA);
   PlotIndexSetInteger(0,PLOT_ARROW,233);
   SetIndexBuffer(1,bufSell,INDICATOR_DATA);
   PlotIndexSetInteger(1,PLOT_ARROW,234);
   PlotIndexSetDouble(0,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(1,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   ArraySetAsSeries(bufBuy,false);
   ArraySetAsSeries(bufSell,false);
   g_pF=DEMAFast;
   g_pS=DEMASlow;
   g_pMS=LiveMinScore;
   g_pTP1=TP1_R;
   g_pTP2=TP2_R;
   g_pTP3=TP3_R;
   g_pSL=LiveSL_ATR;
   hDF=iDEMA(_Symbol,PERIOD_CURRENT,DEMAFast,0,PRICE_CLOSE);
   hDS=iDEMA(_Symbol,PERIOD_CURRENT,DEMASlow,0,PRICE_CLOSE);
   hFast=iMA(_Symbol,PERIOD_CURRENT,EMAFast,0,MODE_EMA,PRICE_CLOSE);
   hSlow=iMA(_Symbol,PERIOD_CURRENT,EMASlow,0,MODE_EMA,PRICE_CLOSE);
   hHTF=iMA(_Symbol,HigherTF(),50,0,MODE_EMA,PRICE_CLOSE);
   if(hFast==INVALID_HANDLE||hSlow==INVALID_HANDLE||hHTF==INVALID_HANDLE)
      return INIT_FAILED;
   for(int j=0;j<10;j++)
      g_tbl_h[j]=iMA(_Symbol,g_tbl_tf[j],50,0,MODE_EMA,PRICE_CLOSE);
   if(GlobalVariableCheck("GMPS_TB2X_"+_Symbol))
     {
      g_tx=(int)GlobalVariableGet("GMPS_TB2X_"+_Symbol);
      g_ty=(int)GlobalVariableGet("GMPS_TB2Y_"+_Symbol);
     }
   // ── Auto-detección de activo ─────────────────────────────────
   GM_AssetProfile g_asset = GM_GetProfile(_Symbol);
   GM_LogProfile(g_asset);
   // El indicador siempre muestra el nombre del activo detectado en el shortname
   string asset_tag = g_asset.name;
   IndicatorSetString(INDICATOR_SHORTNAME,"GM PRO Signals ["+asset_tag+" · "+TFName((ENUM_TIMEFRAMES)_Period)+"]");
   EventSetMillisecondTimer(MathMax(200,TimerMs));
   TFBadge();
   return INIT_SUCCEEDED;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int r) { EventKillTimer(); ObjectsDeleteAll(0,P); Comment(""); }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool TFValid() { return StringFind(","+RecommendedTFs+",",","+TFName((ENUM_TIMEFRAMES)_Period)+",")>=0; }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void TFBadge()
  {
   string n=P+"TFBADGE";
   if(ObjectFind(0,n)<0)
      ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_ANCHOR,ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,10);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,22);
   bool ok=TFValid();
   GM_AssetProfile _ap = GM_GetProfile(_Symbol);
   string _aname = _ap.name;
   ObjectSetString(0,n,OBJPROP_TEXT,ok?"GM Signals ["+_aname+"] · "+TFName((ENUM_TIMEFRAMES)_Period)+" ✔ (válido: "+RecommendedTFs+")"
                   :"⚠ GM Signals ["+_aname+"]: usar en "+RecommendedTFs+" — estás en "+TFName((ENUM_TIMEFRAMES)_Period));
   ObjectSetInteger(0,n,OBJPROP_COLOR,ok?C'38,166,91':clrOrange);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,ok?8:11);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }
// vista previa en la vela que se está formando (cruce DEMA o barrido aún sin cerrar)
datetime g_prev_alert_bar=0;
void Preview()
  {
   if(!RealTimePreview || !LiveMode)
      return;
   string n=P+"PREVIEW";
   double f[2],s2[2];
   if(CopyBuffer(hDF,0,0,2,f)<2 || CopyBuffer(hDS,0,0,2,s2)<2)
      return;   // [0]=vela anterior [1]=actual
   int d=0;
   if(f[1]>s2[1] && f[0]<=s2[0])
      d=1;
   else
      if(f[1]<s2[1] && f[0]>=s2[0])
         d=-1;
   if(d==0)
     {
      if(ObjectFind(0,n)>=0)
         ObjectDelete(0,n);
      return;
     }
   double px=d>0?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   datetime t0=iTime(_Symbol,PERIOD_CURRENT,0);
   if(ObjectFind(0,n)<0)
      ObjectCreate(0,n,OBJ_TEXT,0,t0,px);
   ObjectSetInteger(0,n,OBJPROP_TIME,0,t0);
   ObjectSetDouble(0,n,OBJPROP_PRICE,0,px);
   ObjectSetString(0,n,OBJPROP_TEXT,d>0?"  ▲ BUY formándose (confirma al cierre)":"  ▼ SELL formándose (confirma al cierre)");
   ObjectSetInteger(0,n,OBJPROP_COLOR,d>0?clrDeepSkyBlue:clrOrangeRed);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,9);
   ObjectSetInteger(0,n,OBJPROP_ANCHOR,ANCHOR_LEFT);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   if(g_prev_alert_bar!=t0 && AlertPopup)
     {
      g_prev_alert_bar=t0;
      PlaySound("tick.wav");
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnTimer()
  {
   static datetime kicked=0;
   datetime t0=iTime(_Symbol,PERIOD_CURRENT,0);
   if(g_last_bar!=0 && t0!=g_last_bar && kicked!=t0)
     {
      kicked=t0;   // forzar recálculo si no llegó tick
      ChartSetSymbolPeriod(0,_Symbol,_Period);
     }
   LiveTick();
   Preview();
   ChartRedraw();
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &l,const double &d,const string &s)
  {
   if(id==CHARTEVENT_OBJECT_DRAG && s==P+"TB_BG")
     {
      g_tx=(int)ObjectGetInteger(0,s,OBJPROP_XDISTANCE);
      g_ty=(int)ObjectGetInteger(0,s,OBJPROP_YDISTANCE);
      GlobalVariableSet("GMPS_TB2X_"+_Symbol,g_tx);
      GlobalVariableSet("GMPS_TB2Y_"+_Symbol,g_ty);
      ObjectSetInteger(0,s,OBJPROP_SELECTED,false);
      DrawTable();
     }
  }

//──────────────────────────────────────────────────────────────────
// Dibujo
void Rect(string n,datetime t1,double p1,datetime t2,double p2,color c)
  {
   if(ObjectFind(0,n)<0)
      ObjectCreate(0,n,OBJ_RECTANGLE,0,t1,p1,t2,p2);
   ObjectSetInteger(0,n,OBJPROP_TIME,0,t1);
   ObjectSetDouble(0,n,OBJPROP_PRICE,0,p1);
   ObjectSetInteger(0,n,OBJPROP_TIME,1,t2);
   ObjectSetDouble(0,n,OBJPROP_PRICE,1,p2);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_FILL,true);
   ObjectSetInteger(0,n,OBJPROP_BACK,true);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void Seg(string n,datetime t1,datetime t2,double p,color c,int w,ENUM_LINE_STYLE st)
  {
   if(ObjectFind(0,n)<0)
      ObjectCreate(0,n,OBJ_TREND,0,t1,p,t2,p);
   ObjectSetInteger(0,n,OBJPROP_TIME,0,t1);
   ObjectSetInteger(0,n,OBJPROP_TIME,1,t2);
   ObjectSetDouble(0,n,OBJPROP_PRICE,0,p);
   ObjectSetDouble(0,n,OBJPROP_PRICE,1,p);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_WIDTH,w);
   ObjectSetInteger(0,n,OBJPROP_STYLE,st);
   ObjectSetInteger(0,n,OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void Txt(string n,datetime t,double p,string s,color c,int fs=8,ENUM_ANCHOR_POINT a=ANCHOR_LEFT)
  {
   if(ObjectFind(0,n)<0)
      ObjectCreate(0,n,OBJ_TEXT,0,t,p);
   ObjectSetInteger(0,n,OBJPROP_TIME,0,t);
   ObjectSetDouble(0,n,OBJPROP_PRICE,0,p);
   ObjectSetString(0,n,OBJPROP_TEXT,s);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
   ObjectSetString(0,n,OBJPROP_FONT,"Arial Bold");
   ObjectSetInteger(0,n,OBJPROP_ANCHOR,a);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string ResTxt(int r) { return r==-1?"✖ SL":r==-9?"expiró":r==0?"activa":r==1?"✔ TP1":r==2?"✔ TP2":"✔ TP3"; }
string Grade(int g) { return g>=3?"A+":g==2?"A":g==1?"B":"C"; }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawSetup(int k,const Setup &s,datetime tEnd,bool full)
  {
   string id=P+IntegerToString(k)+"_";
   int d=_Digits;
   datetime t0=s.t;
   Rect(id+"SLB",t0,s.entry,tEnd,s.sl,ColSL);
   Rect(id+"TPB",t0,s.entry,tEnd,s.tp3,ColTP);
   color ce=s.dir>0?clrDodgerBlue:clrTomato;
   Seg(id+"EN",t0,tEnd,s.entry,ColEntry,2,STYLE_SOLID);
   Seg(id+"SL",t0,tEnd,s.sl,clrRed,1,STYLE_SOLID);
   Seg(id+"T1",t0,tEnd,s.tp1,clrLime,1,STYLE_DOT);
   Seg(id+"T2",t0,tEnd,s.tp2,clrLime,1,STYLE_DASH);
   Seg(id+"T3",t0,tEnd,s.tp3,clrLime,2,STYLE_SOLID);
   string head=StringFormat("%s %s [%s]%s",s.dir>0?"▲ COMPRA":"▼ VENTA",EntryMode==ENTRY_CLOSE?"MKT":"LIMIT",Grade(s.grade),s.result!=0?"  "+ResTxt(s.result):"");
   if(!full)
     {
      Txt(id+"LR",tEnd,s.entry," "+ResTxt(s.result),s.result>0?clrLime:s.result==-1?clrTomato:clrSilver,8);
      return;
     }
   Txt(id+"LH",t0,s.dir>0?s.tp3:s.tp3,head,ce,9,s.dir>0?ANCHOR_LEFT_LOWER:ANCHOR_LEFT_UPPER);
   Txt(id+"LE",tEnd,s.entry,StringFormat(" ENTRADA %s",DoubleToString(s.entry,d)),ColEntry);
   Txt(id+"LS",tEnd,s.sl,   StringFormat(" SL %s  (-1R · %.2f$)",DoubleToString(s.sl,d),s.risk),clrTomato);
   Txt(id+"L1",tEnd,s.tp1,  StringFormat(" TP1 %s  (+%.1fR · cerrar 50%% + BE)",DoubleToString(s.tp1,d),TP1_R),clrLime);
   Txt(id+"L2",tEnd,s.tp2,  StringFormat(" TP2 %s  (+%.1fR · cerrar 30%%)",DoubleToString(s.tp2,d),TP2_R),clrLime);
   Txt(id+"L3",tEnd,s.tp3,  StringFormat(" TP3 %s  (+%.1fR · resto)",DoubleToString(s.tp3,d),(MathAbs(s.tp3-s.entry)/s.risk)),clrLime);
  }

//──────────────────────────────────────────────────────────────────
double LotFor(double dist,double &riskMoney,bool &minOnly)
  {
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE), ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN), st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(tv<=0||ts<=0||dist<=0||st<=0)
     {
      riskMoney=0;
      minOnly=true;
      return mn;
     }
   double perLot=dist/ts*tv, budget=AccountInfoDouble(ACCOUNT_BALANCE)*RiskPct/100.0;
   double lot=MathFloor(budget/perLot/st)*st;
   minOnly=(lot<mn);
   if(minOnly)
      lot=mn;
   riskMoney=lot*perLot;
   return lot;
  }

// Simula el resultado sobre las velas posteriores (conservador: SL antes que TP en la misma vela)
void Resolve(Setup &s,const MqlRates &r[],int n)
  {
   s.result=0;
   s.filled_bar=-1;
   s.hb1=s.hb2=s.hb3=s.slb=-1;
   s.closed=false;
   for(int i=s.bar+1;i<n;i++)                        // incluye la vela en curso: un TP/SL tocado ya es un hecho
     {
      if(s.filled_bar<0)
        {
         if(EntryMode==ENTRY_CLOSE || s.mkt)
           {
            s.filled_bar=s.bar;   // RETEST/OTE = orden límite
            i--;
            continue;
           }
         bool touch = s.dir>0 ? r[i].low<=s.entry : r[i].high>=s.entry;
         bool inval = s.dir>0 ? r[i].low<=s.sl    : r[i].high>=s.sl;
         if(touch)
           {
            s.filled_bar=i;
            if(inval)
              {
               s.result=-1;
               s.slb=i;
               s.closed=true;
               return;
              }
            continue;
           }
         if(i-s.bar>RetestExpiryBars)
           {
            s.result=-9;
            s.closed=true;
            return;
           }
         continue;
        }
      double sl = (s.result>=1) ? s.entry : s.sl;     // tras TP1 → stop a breakeven
      bool hitSL = s.dir>0 ? r[i].low<=sl : r[i].high>=sl;   // conservador: el SL se evalúa antes que los TP
      if(hitSL)
        {
         if(s.result<=0)
            s.result=-1;
         s.slb=i;
         s.closed=true;
         return;
        }
      double fav = s.dir>0 ? r[i].high : r[i].low;
      bool h1 = s.dir>0 ? fav>=s.tp1 : fav<=s.tp1, h2 = s.dir>0 ? fav>=s.tp2 : fav<=s.tp2, h3 = s.dir>0 ? fav>=s.tp3 : fav<=s.tp3;
      if(h1 && s.hb1<0)
        {
         s.hb1=i;
         s.result=MathMax(s.result,1);
        }
      if(h2 && s.hb2<0)
        {
         s.hb2=i;
         s.result=MathMax(s.result,2);
        }
      if(h3)
        {
         s.hb3=i;
         s.result=3;
         s.closed=true;
         return;
        }
     }
  }

//──────────────────────────────────────────────────────────────────
// Estilo "pro": etiquetas Buy/Sell, marcas TP, tags de precio a la derecha y tabla MTF
GMSLevel g_zones[];
int g_nz=0;
double g_ztol=0;
void BuildZones()
  {
   g_nz=0;
   ArrayResize(g_zones,0);
   int nh=ZoneDays*24+50;
   MqlRates h[];
   ArraySetAsSeries(h,false);
   int got=CopyRates(_Symbol,PERIOD_H1,0,nh,h);
   if(got<100)
      return;
   double a=0;
   for(int i=got-200;i<got;i++)
      if(i>0)
         a+=h[i].high-h[i].low;
   a/=200.0;
   g_ztol=ZoneTolATR*a;
   GMSSwing sw[];
   int ns=GMS_Swings(h,got,ZoneSwingStrength,sw);
   g_nz=GMS_Levels(sw,ns,g_ztol,ZoneMinTouches,g_zones);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawZones(datetime tNow)
  {
   if(!ShowZones||g_nz==0)
      return;
   double px=SymbolInfoDouble(_Symbol,SYMBOL_BID);
// las más cercanas por lado
   for(int side=-1;side<=1;side+=2)
     {
      int used=0;
      for(int pass=0;pass<g_nz && used<ZonesPerSide;pass++)
        {
         int best=-1;
         double bd=DBL_MAX;
         for(int i=0;i<g_nz;i++)
           {
            double d=(g_zones[i].p-px)*side;
            if(d<=0||d>=bd)
               continue;
            string nm=P+"Z"+IntegerToString(i);
            if(ObjectFind(0,nm)>=0)
               continue;
            bd=d;
            best=i;
           }
         if(best<0)
            break;
         GMSLevel z=g_zones[best];
         string nm=P+"Z"+IntegerToString(best);
         color c= side>0 ? ColSupply : ColDemand;
         Rect(nm,z.first_t,z.p+g_ztol*0.5,tNow+PeriodSeconds()*40,z.p-g_ztol*0.5,c);
         Txt(nm+"T",tNow+PeriodSeconds()*40,z.p,StringFormat(" %s %s · %dx",side>0?"Supply":"Demand",DoubleToString(z.p,_Digits),z.touches),side>0?C'240,98,146':C'77,208,225',7,ANCHOR_RIGHT);
         used++;
        }
     }
  }
// distancia (en precio) a la zona contraria más cercana existente antes de t
double RoomTo(int dir,double entry,datetime t)
  {
   double best=DBL_MAX;
   for(int i=0;i<g_nz;i++)
     {
      if(g_zones[i].first_t>t)
         continue;
      double d=(g_zones[i].p-entry)*dir - g_ztol*0.5;
      if(d>0 && d<best)
         best=d;
     }
   return best;
  }
ENUM_TIMEFRAMES g_tbl_tf[10]= {PERIOD_M1,PERIOD_M3,PERIOD_M5,PERIOD_M15,PERIOD_M30,PERIOD_H1,PERIOD_H2,PERIOD_H4,PERIOD_H8,PERIOD_D1};
string          g_tbl_nm[10]= {"1 min:","3 min:","5 min:","15 min:","30 min:","1H:","2H:","4H:","8H:","Daily:"};
int             g_tbl_h[10];
int  g_tx=-1,g_ty=-1;
string g_rowL[], g_rowR[];
color g_rowC[];

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void Badge(string n,datetime t,double p,string txt,color bg,bool above)
  {
// etiqueta tipo "botón": rectángulo de precio + texto encima
   Txt(n,t,p,txt,bg,9,above?ANCHOR_LOWER:ANCHOR_UPPER);
   ObjectSetString(0,n,OBJPROP_FONT,"Arial Black");
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void Tag(string n,datetime t,double p,string txt,color bg)
  {
   string a=n+"_A";
   if(ObjectFind(0,a)<0)
      ObjectCreate(0,a,OBJ_ARROW_LEFT_PRICE,0,t,p);
   ObjectSetInteger(0,a,OBJPROP_TIME,0,t);
   ObjectSetDouble(0,a,OBJPROP_PRICE,0,p);
   ObjectSetInteger(0,a,OBJPROP_COLOR,bg);
   ObjectSetInteger(0,a,OBJPROP_WIDTH,2);
   ObjectSetInteger(0,a,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,a,OBJPROP_HIDDEN,true);
   Txt(n,t+PeriodSeconds()*7,p,txt,bg,8,ANCHOR_LEFT);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int TFTrend(int j)
  {
   GMSState st=GMS_Analyze(_Symbol,g_tbl_tf[j],2,300);
   if(st.ok && st.trend!=0)
      return st.trend;
   double e[];
   if(CopyBuffer(g_tbl_h[j],0,1,2,e)<2)
      return 0;
   double c=iClose(_Symbol,g_tbl_tf[j],1);
   return (c>e[1] && e[1]>=e[0]) ? 1 : (c<e[1] && e[1]<=e[0]) ? -1 : (c>e[1]?1:-1);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawTable()
  {
   int rows=ArraySize(g_rowL);
   if(rows==0)
      return;
   int rh=17, wL=118, wR=78;
   if(g_tx<0)
     {
      g_tx=8;
      g_ty=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS)-rows*rh-30;
      if(g_tx<0)
         g_tx=10;
      if(g_ty<0)
         g_ty=30;
     }
   string bg=P+"TB_BG";
   if(ObjectFind(0,bg)<0)
     {
      ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,bg,OBJPROP_SELECTABLE,true);
      ObjectSetInteger(0,bg,OBJPROP_HIDDEN,true);
      ObjectSetString(0,bg,OBJPROP_TOOLTIP,"Doble clic y arrastra para mover");
     }
   ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,C'14,14,18');
   ObjectSetInteger(0,bg,OBJPROP_COLOR,C'50,50,60');
   ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,g_tx);
   ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,g_ty);
   ObjectSetInteger(0,bg,OBJPROP_XSIZE,wL+wR+6);
   ObjectSetInteger(0,bg,OBJPROP_YSIZE,rows*rh+6);
   for(int i=0;i<rows;i++)
     {
      int y=g_ty+3+i*rh;
      string c=P+"TB_C"+IntegerToString(i), l=P+"TB_L"+IntegerToString(i), v=P+"TB_V"+IntegerToString(i);
      if(ObjectFind(0,c)<0)
        {
         ObjectCreate(0,c,OBJ_RECTANGLE_LABEL,0,0,0);
         ObjectSetInteger(0,c,OBJPROP_BORDER_TYPE,BORDER_FLAT);
         ObjectSetInteger(0,c,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,c,OBJPROP_HIDDEN,true);
        }
      ObjectSetInteger(0,c,OBJPROP_XDISTANCE,g_tx+3+wL);
      ObjectSetInteger(0,c,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,c,OBJPROP_XSIZE,wR);
      ObjectSetInteger(0,c,OBJPROP_YSIZE,rh-2);
      ObjectSetInteger(0,c,OBJPROP_BGCOLOR,g_rowC[i]);
      ObjectSetInteger(0,c,OBJPROP_COLOR,g_rowC[i]);
      if(ObjectFind(0,l)<0)
        {
         ObjectCreate(0,l,OBJ_LABEL,0,0,0);
         ObjectSetInteger(0,l,OBJPROP_ANCHOR,ANCHOR_RIGHT_UPPER);
         ObjectSetInteger(0,l,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,l,OBJPROP_HIDDEN,true);
         ObjectSetString(0,l,OBJPROP_FONT,"Arial");
         ObjectSetInteger(0,l,OBJPROP_FONTSIZE,8);
        }
      ObjectSetInteger(0,l,OBJPROP_XDISTANCE,g_tx+wL-4);
      ObjectSetInteger(0,l,OBJPROP_YDISTANCE,y+1);
      ObjectSetString(0,l,OBJPROP_TEXT,g_rowL[i]);
      ObjectSetInteger(0,l,OBJPROP_COLOR,clrWhiteSmoke);
      if(ObjectFind(0,v)<0)
        {
         ObjectCreate(0,v,OBJ_LABEL,0,0,0);
         ObjectSetInteger(0,v,OBJPROP_ANCHOR,ANCHOR_UPPER);
         ObjectSetInteger(0,v,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,v,OBJPROP_HIDDEN,true);
         ObjectSetString(0,v,OBJPROP_FONT,"Arial Bold");
         ObjectSetInteger(0,v,OBJPROP_FONTSIZE,8);
        }
      ObjectSetInteger(0,v,OBJPROP_XDISTANCE,g_tx+3+wL+wR/2);
      ObjectSetInteger(0,v,OBJPROP_YDISTANCE,y+1);
      ObjectSetString(0,v,OBJPROP_TEXT,g_rowR[i]);
      ObjectSetInteger(0,v,OBJPROP_COLOR,clrWhite);
     }
   ChartRedraw();
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void AddRow(string l,string r,color c) { int k=ArraySize(g_rowL); ArrayResize(g_rowL,k+1); ArrayResize(g_rowR,k+1); ArrayResize(g_rowC,k+1); g_rowL[k]=l; g_rowR[k]=r; g_rowC[k]=c; }
color TrendCol(int t) { return t>0?C'38,166,91':t<0?C'214,48,64':C'90,90,100'; }
string TrendTxt(int t) { return t>0?"Bullish":t<0?"Bearish":"Neutral"; }

//──────────────────────────────────────────────────────────────────
// MODO EN VIVO: confluencia de 6 factores en cada vela cerrada, señal al cruzar DEMA
//  1 DEMA rápida vs lenta        2 EMA50/200 + precio       3 pendiente del canal de regresión
//  4 estructura SMC (último BOS/CHoCH)   5 EMA50 del TF superior   6 zona (descuento/premium del mes)
bool BuildLive(const MqlRates &r[],int n,const double &atr[],const double &ef[],const double &es[],
               const GMSSwing &sw[],int nsw,const GMSEvent &ev[],int ne,
               const double &hE[],const datetime &hT[],int gotT,bool htfOk)
  {
   double df[],ds[];
   ArraySetAsSeries(df,false);
   ArraySetAsSeries(ds,false);
   if(BarsCalculated(hDF)<n || BarsCalculated(hDS)<n)
      return false;
   if(CopyBuffer(hDF,0,0,n,df)<n || CopyBuffer(hDS,0,0,n,ds)<n)
      return false;
// rango del mes (premium/discount)
   double mHi=-DBL_MAX,mLo=DBL_MAX;
   int start=MathMax(EMASlow+ChannelLen,50), lastDir=0, k=0, hp=0;
   int structDir=0;
   // Pre-compute Order Blocks and Fair Value Gaps for this batch
   GMOrderBlock g_obs[]; int nob=GMS_OrderBlocks(r,n,SwingStrength,g_obs);
   GMFairValueGap g_fvgs[]; int nfvg=GMS_FairValueGaps(r,n,g_fvgs);
   for(int b=1;b<n-1;b++)
     {
      while(k<ne && ev[k].bar_break<=b)
        {
         structDir=ev[k].dir;
         k++;
        }
      mHi=MathMax(mHi,r[b].high);
      mLo=MathMin(mLo,r[b].low);
      if(b<start)
         continue;
      bool crossUp = df[b]>ds[b] && df[b-1]<=ds[b-1];
      bool crossDn = df[b]<ds[b] && df[b-1]>=ds[b-1];
      bool sweep=false;
      int sdir=0;
      if(SweepSignals && g_nz>0)
        {
         for(int z=0;z<g_nz;z++)
           {
            if(g_zones[z].first_t>r[b].time)
               continue;
            double zp=g_zones[z].p, tol=g_ztol*0.5;
            if(r[b].low<zp-tol && r[b].close>zp && r[b].close>r[b].open && df[b]>df[b-1])
              {
               sweep=true;   // barrió demanda y recuperó
               sdir=1;
               break;
              }
            if(r[b].high>zp+tol && r[b].close<zp && r[b].close<r[b].open && df[b]<df[b-1])
              {
               sweep=true;   // barrió oferta y perdió
               sdir=-1;
               break;
              }
           }
        }
      if(!crossUp && !crossDn && !sweep)
         continue;
      int dir = sweep ? sdir : (crossUp?1:-1);
      if(dir==lastDir)                                             // misma dirección: sólo si la anterior ya cerró (TP3/SL)
        {
         if(g_ns==0)
            continue;
         Setup pv=g_s[g_ns-1];
         int cb=MathMax(pv.hb3,pv.slb);
         if(!pv.closed || cb<0 || cb>=b)
            continue;
        }
      // canal de regresión
      double sx=0,sy=0,sxx=0,sxy=0;
      int L=ChannelLen;
      for(int q=0;q<L;q++)
        {
         double x=q,y=r[b-L+1+q].close;
         sx+=x;
         sy+=y;
         sxx+=x*x;
         sxy+=x*y;
        }
      double slope=(L*sxy-sx*sy)/MathMax(1e-9,(L*sxx-sx*sx)), icpt=(sy-slope*sx)/L;
      double mid=icpt+slope*(L-1), dev=0;
      for(int q=0;q<L;q++)
        {
         double e2=r[b-L+1+q].close-(icpt+slope*q);
         dev+=e2*e2;
        }
      dev=MathSqrt(dev/L);
      if(dir>0 && r[b].close>mid+ChannelDev*dev)
         continue;           // no comprar en el techo del canal
      if(dir<0 && r[b].close<mid-ChannelDev*dev)
         continue;
      if(LiveUseSession)
        {
         MqlDateTime dt;
         TimeToStruct(r[b].time,dt);
         if(dt.hour<SessionStart||dt.hour>=SessionEnd)
            continue;
        }
      // ── Confluencia 10 puntos (OB+FVG+SMC) ──────────────────────
      bool ema_align = (dir>0) ? (ef[b]>es[b] && r[b].close>ef[b]) : (ef[b]<es[b] && r[b].close<ef[b]);
      bool slope_ok  = (slope*dir>0);
      bool struct_ok = (structDir==dir);
      bool htf_ok2   = false;
      if(htfOk)
        {
         while(hp+1<gotT && hT[hp+1]<=r[b].time) hp++;
         int k2=hp-1;
         if(k2>=1 && (hE[k2]-hE[k2-1])*dir>0) htf_ok2=true;
        }
      double eq=(mHi+mLo)/2;
      bool discount_ok = (dir>0) ? (r[b].close<eq) : (r[b].close>eq);
      // OB detection
      int ob_idx=-1;
      bool ob_hit = (nob>0) && GMS_InOrderBlock(r[b].close, g_obs, nob, dir, 3*_Point, ob_idx);
      // FVG detection
      int fvg_idx=-1;
      bool fvg_hit = (nfvg>0) && GMS_InFVG(r[b].close, g_fvgs, nfvg, dir, fvg_idx);
      // Session filter
      bool session_ok2 = true;
      if(LiveUseSession)
        {
         MqlDateTime dt2; TimeToStruct(r[b].time,dt2);
         session_ok2 = (dt2.hour>=SessionStart && dt2.hour<SessionEnd);
        }
      bool spread_ok  = (SymbolInfoInteger(_Symbol,SYMBOL_SPREAD) <= MaxSpreadPts);
      // Build confluence score
      GMConfluence conf = GMConf_Build(htf_ok2||slope_ok, ob_hit, fvg_hit, sweep,
                                       ema_align, struct_ok || discount_ok,
                                       session_ok2, spread_ok,
                                       false, false);
      int sc = conf.score;
      if(sc < g_pMS) continue;
      // SL detrás del último swing contrario (SMC), mínimo g_pSL
      double a=atr[b], swp=0;
      for(int q=nsw-1;q>=0;q--)
         if(sw[q].bar<b && sw[q].high==(dir<0))
           {
            swp=sw[q].p;
            break;
           }
      double entry=r[b].close, sl = swp>0 ? swp-dir*SLPadATR*a : entry-dir*g_pSL*a;
      double risk=(entry-sl)*dir;
      if(risk<g_pSL*a)
        {
         risk=g_pSL*a;
         sl=entry-dir*risk;
        }
      if(risk>MaxSL_ATR*a)
        {
         risk=MaxSL_ATR*a;
         sl=entry-dir*risk;
        }
      Setup s;
      s.dir=dir;
      s.bar=b;
      s.t=r[b].time;
      s.entry=entry;
      s.sl=sl;
      s.risk=risk;
      s.choch=false;
      s.mkt=true;
      s.score=sc;
      s.tp1=entry+dir*risk*g_pTP1;
      s.tp2=entry+dir*risk*g_pTP2;
      s.tp3=entry+dir*risk*g_pTP3;
      s.grade = sc>=8?3: sc>=6?2: sc>=4?1:0;  // A+(>=8) A(>=6) B(>=4) C(<4)
      s.be_after_tp1=true;
      Resolve(s,r,n);
      ArrayResize(g_s,g_ns+1);
      g_s[g_ns++]=s;
      lastDir=dir;
     }
   return true;
  }

//──────────────────────────────────────────────────────────────────
// Cada tick: si el precio toca TP1/TP2/TP3/SL de la operación actual, se marca al instante
void LiveTick()
  {
   if(g_ns==0)
      return;
   Setup c=g_s[g_ns-1];
   if(c.closed)
      return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID), ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double px = c.dir>0 ? bid : ask;
   if(c.filled_bar<0)
     {
      if((c.dir>0 && ask<=c.entry) || (c.dir<0 && bid>=c.entry))
         c.filled_bar=0;
      else
        {
         g_s[g_ns-1]=c;
         return;
        }
     }
   int old=c.result;
   double slNow = c.result>=1 ? c.entry : c.sl;
   if((c.dir>0 && px<=slNow) || (c.dir<0 && px>=slNow))
     {
      if(c.result<=0)
         c.result=-1;
      c.closed=true;
     }
   else
     {
      if((px-c.tp3)*c.dir>=0)
        {
         c.result=3;
         c.closed=true;
        }
      else
         if((px-c.tp2)*c.dir>=0)
            c.result=MathMax(c.result,2);
         else
            if((px-c.tp1)*c.dir>=0)
               c.result=MathMax(c.result,1);
     }
   if(c.result==old && !c.closed)
      return;
   g_s[g_ns-1]=c;
   datetime tR=iTime(_Symbol,PERIOD_CURRENT,0)+PeriodSeconds()*3;
   Txt(P+"CUR_RES",tR,c.tp3,"  "+ResTxt(c.result)+(c.closed?"  · esperando nueva señal":""),c.result>0?clrLime:clrTomato,9,ANCHOR_LEFT_LOWER);
   if(c.result!=old)
     {
      string msg=StringFormat("GM %s %s: %s %s",_Symbol,TFName((ENUM_TIMEFRAMES)_Period),c.dir>0?"BUY":"SELL",ResTxt(c.result));
      if(AlertPopup)
         Alert(msg);
      if(AlertPush)
         SendNotification(msg);
     }
   ChartRedraw();
  }

//──────────────────────────────────────────────────────────────────
int OnCalculate(const int rates_total,const int prev_calculated,const datetime &time[],
                const double &open[],const double &high[],const double &low[],const double &close[],
                const long &tick_volume[],const long &volume[],const int &spread[])
  {
   if(rates_total<EMASlow+50)
      return rates_total;
   ArraySetAsSeries(time,false);
   if(time[rates_total-1]==g_last_bar && prev_calculated>0)
     {
      LiveTick();
      Preview();
      return rates_total;
     }
   g_last_bar=time[rates_total-1];

   int need=MathMax(BarsToAnalyze,HistoryDays*86400/PeriodSeconds()*5/7+EMASlow);
   if(_Period==PERIOD_M1)
      need=MathMin(need,MathMax(BarsToAnalyze,MaxBarsM1));
   int n=MathMin(need,rates_total);
   BuildZones();
   MqlRates r[];
   ArraySetAsSeries(r,false);
   if(CopyRates(_Symbol,PERIOD_CURRENT,0,n,r)<n)
     {
      g_last_bar=0;
      return 0;
     }
   double ef[],es[];
   ArraySetAsSeries(ef,false);
   ArraySetAsSeries(es,false);
   if(CopyBuffer(hFast,0,0,n,ef)<n || CopyBuffer(hSlow,0,0,n,es)<n)
     {
      g_last_bar=0;
      return 0;
     }
   int off=rates_total-n;
   ArrayInitialize(bufBuy,EMPTY_VALUE);
   ArrayInitialize(bufSell,EMPTY_VALUE);

// ATR(14) simple
   double atr[];
   ArrayResize(atr,n);
   atr[0]=r[0].high-r[0].low;
   for(int i=1;i<n;i++)
     {
      double tr=MathMax(r[i].high,r[i-1].close)-MathMin(r[i].low,r[i-1].close);
      atr[i]=(i<14)?tr:(atr[i-1]*13+tr)/14.0;
     }

// EMA50 del TF superior alineada por tiempo (sin mirar al futuro: vela HTF cerrada)
   int hn=n/ MathMax(1,PeriodSeconds(HigherTF())/PeriodSeconds()) + 120;
   double hE[];
   datetime hT[];
   ArraySetAsSeries(hE,false);
   ArraySetAsSeries(hT,false);
   int gotE=CopyBuffer(hHTF,0,0,hn,hE), gotT=CopyTime(_Symbol,HigherTF(),0,hn,hT);
   bool htfOk = gotE>3 && gotT==gotE;

   GMSSwing sw[];
   int nsw=GMS_Swings(r,n,SwingStrength,sw);
   GMSEvent ev[];
   int trend=0;
   int ne=GMS_Events(r,n,SwingStrength,sw,nsw,ev,trend);

// Confluencia MTF (estado actual)
   ENUM_TIMEFRAMES tfs[5]= {PERIOD_M1,PERIOD_M5,PERIOD_M15,PERIOD_H1,PERIOD_H4};
   int tr5[5];
   for(int j=0;j<5;j++)
     {
      GMSState st=GMS_Analyze(_Symbol,tfs[j],2,300);
      tr5[j]=st.ok?st.trend:0;
     }
   GMSState hs=GMS_Analyze(_Symbol,HigherTF(),2,300);
   int htf=hs.ok?hs.trend:0;

   ArrayResize(g_s,0);
   g_ns=0;
   int busyUntil=-1, hp=0;
   LoadAutoParams();
   if(LiveMode)
     {
      if(!BuildLive(r,n,atr,ef,es,sw,nsw,ev,ne,hE,hT,gotT,htfOk))
        {
         g_last_bar=0;
         return 0;
        }
     }
   else
      for(int e=0;e<ne;e++)
        {
         int b=ev[e].bar_break;
         if(b<EMASlow || b>=n-1)
            continue;
         if(b<=busyUntil)
            continue;
         if(ev[e].choch && !AllowCHoCH)
            continue;
         int dir=ev[e].dir;
         bool emaOk = dir>0 ? (ef[b]>es[b] && r[b].close>ef[b]) : (ef[b]<es[b] && r[b].close<ef[b]);
         if(!emaOk)
            continue;
         // 1) Sesión Londres/NY
         if(UseSession)
           {
            MqlDateTime dt;
            TimeToStruct(r[b].time,dt);
            if(dt.hour<SessionStart||dt.hour>=SessionEnd)
               continue;
           }
         // 2) Desplazamiento: ruptura con vela de cuerpo grande, no un pinchazo
         if(MathAbs(r[b].close-r[b].open) < MinDisplacementATR*atr[b])
            continue;
         // 3) Anti-rango: Kaufman Efficiency Ratio
         if(b>ER_Period)
           {
            double net=MathAbs(r[b].close-r[b-ER_Period].close), path=0;
            for(int q=b-ER_Period+1;q<=b;q++)
               path+=MathAbs(r[q].close-r[q-1].close);
            if(path>0 && net/path<MinER)
               continue;
           }
         // 4) Tendencia del TF superior (última vela HTF CERRADA antes de r[b])
         if(UseHTFFilter && htfOk)
           {
            while(hp+1<gotT && hT[hp+1]<=r[b].time)
               hp++;
            int k2=hp-1;
            if(k2<1)
               continue;
            bool up=hE[k2]>hE[k2-1], dn=hE[k2]<hE[k2-1];
            if((dir>0 && !up) || (dir<0 && !dn))
               continue;
           }
         // SL detrás del último swing contrario
         double swp=0;
         for(int k=nsw-1;k>=0;k--)
            if(sw[k].bar<b && sw[k].high==(dir<0))
              {
               swp=sw[k].p;
               break;
              }
         if(swp==0)
            continue;
         double a=atr[b];
         double ext = dir>0 ? r[b].high : r[b].low;            // extremo del impulso
         for(int q=b-1;q>=0 && q>b-30;q--)
           {
            if(dir>0? r[q].low<=swp : r[q].high>=swp)
               break;
            ext = dir>0? MathMax(ext,r[q].high) : MathMin(ext,r[q].low);
           }
         double entry = EntryMode==ENTRY_RETEST ? ev[e].price : EntryMode==ENTRY_CLOSE ? r[b].close
                        : ext - dir*OTE_Level*MathAbs(ext-swp);
         double sl = dir>0 ? swp-SLPadATR*a : swp+SLPadATR*a;
         double risk=MathAbs(entry-sl);
         if(risk<MinSL_ATR*a)
           {
            risk=MinSL_ATR*a;
            sl= dir>0?entry-risk:entry+risk;
           }
         if(risk>MaxSL_ATR*a)
            continue;
         double room=RoomTo(dir,entry,r[b].time);
         if(room<MinRoomR*risk)
            continue;                    // zona contraria demasiado cerca
         bool inZone=false;                                  // entrada dentro/junto a zona a favor = +calidad
         for(int z=0;z<g_nz;z++)
            if(g_zones[z].first_t<=r[b].time && MathAbs(g_zones[z].p-sl)<=g_ztol*1.5)
              {
               inZone=true;
               break;
              }
         Setup s;
         s.dir=dir;
         s.bar=b;
         s.t=r[b].time;
         s.entry=entry;
         s.sl=sl;
         s.risk=risk;
         s.choch=ev[e].choch;
         s.mkt=false;
         s.score=0;
         s.tp1=entry+dir*risk*TP1_R;
         s.tp2=entry+dir*risk*TP2_R;
         s.tp3=entry+dir*risk*TP3_R;
         // grado: EMA ya alineada =1; +1 tendencia estructural del gráfico; +1 TF superior a favor (solo evaluable en vivo)
         int g=1;
         if(trend==dir || !s.choch)
            g++;
         if(inZone)
            g++;
         if(b>=n-3 && htf==dir)
            g++;
         if(g>3)
            g=3;
         s.grade=g;
         s.be_after_tp1=true;
         if(g<MinGrade)
            continue;
         Resolve(s,r,n);
         ArrayResize(g_s,g_ns+1);
         g_s[g_ns++]=s;
         busyUntil = (!s.closed) ? n : (s.result==-1 ? b+CooldownBarsAfterSL : b+3);                 // no apilar señales mientras hay una viva
        }

// ── Dibujo estilo pro ──
   ObjectsDeleteAll(0,P);
   TFBadge();
   int psec=PeriodSeconds();
   DrawZones(r[n-1].time);
   for(int k=MathMax(0,g_ns-HistoryBoxes*4);k<g_ns;k++)
     {
      Setup h=g_s[k];
      string id=P+IntegerToString(k)+"_";
      double a0=atr[h.bar];
      bool plus=(h.grade>=2);
      if(h.dir>0)
         Badge(id+"B",h.t,r[h.bar].low-0.6*a0,plus?"Buy+":"Buy",C'0,188,212',false);
      else
         Badge(id+"B",h.t,r[h.bar].high+0.6*a0,plus?"Sell+":"Sell",C'233,30,99',true);
      // marcas de TP alcanzados / stop
      if(h.hb1>=0)
         Txt(id+"H1",r[h.hb1].time,h.dir>0?r[h.hb1].high+0.3*a0:r[h.hb1].low-0.3*a0,"TP1",clrSilver,7,h.dir>0?ANCHOR_LOWER:ANCHOR_UPPER);
      if(h.hb2>=0 && h.hb2!=h.hb1)
         Txt(id+"H2",r[h.hb2].time,h.dir>0?r[h.hb2].high+0.3*a0:r[h.hb2].low-0.3*a0,"TP2",clrSilver,7,h.dir>0?ANCHOR_LOWER:ANCHOR_UPPER);
      if(h.hb3>=0)
         Txt(id+"H3",r[h.hb3].time,h.dir>0?r[h.hb3].high+0.3*a0:r[h.hb3].low-0.3*a0,"TP3",clrGold,7,h.dir>0?ANCHOR_LOWER:ANCHOR_UPPER);
      if(h.slb>=0 && h.result==-1)
         Txt(id+"HS",r[h.slb].time,h.dir>0?r[h.slb].low-0.3*a0:r[h.slb].high+0.3*a0,"SL",clrTomato,7,h.dir>0?ANCHOR_UPPER:ANCHOR_LOWER);
     }
// operación actual: zona tenue + tags de precio a la derecha
   if(g_ns>0)
     {
      Setup c=g_s[g_ns-1];
      bool live=!c.closed;
      if(live || c.bar>=n-ExtendBars)
        {
         datetime t0=c.t, tR=r[n-1].time+psec*3;
         Rect(P+"CUR_TP",t0,c.entry,tR,c.tp3,C'10,45,30');
         Rect(P+"CUR_SL",t0,c.entry,tR,c.sl,C'60,15,20');
         string vv=P+"CUR_VL";
         ObjectCreate(0,vv,OBJ_TREND,0,tR,c.sl,tR,c.tp3);
         ObjectSetInteger(0,vv,OBJPROP_COLOR,C'60,180,90');
         ObjectSetInteger(0,vv,OBJPROP_WIDTH,2);
         ObjectSetInteger(0,vv,OBJPROP_RAY_RIGHT,false);
         ObjectSetInteger(0,vv,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,vv,OBJPROP_HIDDEN,true);
         int d=_Digits;
         Tag(P+"CUR_T3",tR,c.tp3,"TP3 ("+DoubleToString(c.tp3,d)+")",C'38,166,91');
         Tag(P+"CUR_T2",tR,c.tp2,"TP2 ("+DoubleToString(c.tp2,d)+")",C'38,166,91');
         Tag(P+"CUR_T1",tR,c.tp1,"TP1 ("+DoubleToString(c.tp1,d)+")",C'38,166,91');
         Tag(P+"CUR_EN",tR,c.entry,"Entry ("+DoubleToString(c.entry,d)+")"+(c.filled_bar<0&&live?" · limit":""),clrSilver);
         Tag(P+"CUR_SL",tR,c.sl,"SL ("+DoubleToString(c.sl,d)+")",C'214,48,64');
         if(!live)
            Txt(P+"CUR_RES",tR,c.dir>0?c.tp3:c.tp3,"  "+ResTxt(c.result),c.result>0?clrLime:clrTomato,9,ANCHOR_LEFT_LOWER);
        }
     }

// Estadística (gestión 50/30/20, BE tras TP1)
   int tot=0,w1=0,w2=0,w3=0,sl=0;
   double rsum=0;
   for(int k=0;k<g_ns;k++)
     {
      int rr=g_s[k].result;
      if(!g_s[k].closed||rr==-9)
         continue;
      tot++;
      if(rr>=1)
         w1++;
      if(rr>=2)
         w2++;
      if(rr>=3)
         w3++;
      if(rr==-1)
         sl++;
      rsum += rr==-1 ? -1.0 : rr==1 ? 0.5*TP1_R : rr==2 ? 0.5*TP1_R+0.3*TP2_R : 0.5*TP1_R+0.3*TP2_R+0.2*TP3_R;
     }

// Tabla MTF
   ArrayResize(g_rowL,0);
   ArrayResize(g_rowR,0);
   ArrayResize(g_rowC,0);
   int posDir=0;
   double rm=0;
   bool mo=false;
   double lot=0;
   if(g_ns>0)
     {
      Setup c=g_s[g_ns-1];
      if(!c.closed || LiveMode)
         posDir=c.dir;
      lot=LotFor(c.risk,rm,mo);
      if(!c.closed && c.bar>=n-2 && c.t!=g_last_alert)
        {
         g_last_alert=c.t;
         string msg=StringFormat("GM %s %s %s%s Entry %s SL %s TP1 %s TP2 %s TP3 %s",_Symbol,TFName((ENUM_TIMEFRAMES)_Period),c.dir>0?"BUY":"SELL",c.grade>=2?"+":"",
                                 DoubleToString(c.entry,_Digits),DoubleToString(c.sl,_Digits),DoubleToString(c.tp1,_Digits),DoubleToString(c.tp2,_Digits),DoubleToString(c.tp3,_Digits));
         if(AlertPopup)
            Alert(msg);
         if(AlertPush)
            SendNotification(msg);
        }
     }
   AddRow("Current Position",posDir>0?"Buy":posDir<0?"Sell":"Flat",posDir>0?C'38,166,91':posDir<0?C'214,48,64':C'90,90,100');
   AddRow("Current Trend",TrendTxt(trend),TrendCol(trend));

   for(int j=0;j<10;j++)
     {
      int t=TFTrend(j);
      AddRow(g_tbl_nm[j],TrendTxt(t),TrendCol(t));
     }
   if(tot>0)
     {
      AddRow("Win TP1",StringFormat("%.0f%%",100.0*w1/tot),w1*2>=tot?C'38,166,91':C'214,48,64');
      AddRow("Expectancy",StringFormat("%+.2fR",rsum/tot),rsum>0?C'38,166,91':C'214,48,64');
     }
   if(LiveMode)
      AddRow("Params",g_pInfo,C'60,60,75');
   if(g_ns>0)
      AddRow("Lot / risk",StringFormat("%.2f · %.2f$",lot,rm),mo?C'214,120,30':C'60,60,75');
   DrawTable();
   return rates_total;
  }
//+------------------------------------------------------------------+
