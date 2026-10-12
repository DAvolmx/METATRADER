//+------------------------------------------------------------------+
//|  GOLD_MASTER_Indicador_v4.mq5 — Estructura limpia + DXY          |
//|                                                                  |
//|  Diseño "menos es más": cada elemento tiene ETIQUETA y sólo se    |
//|  dibuja lo relevante cerca del precio actual.                    |
//|   · Swings HH/HL/LH/LL (texto pequeño)                           |
//|   · BOS / CHoCH: línea desde el swing hasta la vela de ruptura   |
//|     con su nombre en el centro (sólo los últimos N)              |
//|   · Order Blocks y FVG: sólo los N más cercanos sin mitigar,     |
//|     con etiqueta y precio al borde derecho                       |
//|   · Liquidez EQH/EQL (iguales máximos/mínimos sin barrer)        |
//|   · Niveles estructurales multi-toque (R/S ×toques)              |
//|   · Premium / Equilibrio / Discount en el rango actual           |
//|   · Panel en la esquina: tendencia H1 y LTF, último evento,      |
//|     DXY (valor, Δ24h, tendencia, correlación) y señal            |
//|   · Flechas de señal: evento LTF a favor de HTF y DXY no en contra|
//+------------------------------------------------------------------+
#property copyright "David Domez — GOLD MASTER SYSTEM"
#property version   "4.00"
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2
#property indicator_label1  "Señal COMPRA"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_width1  3
#property indicator_label2  "Señal VENTA"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  3

#include <GoldMaster/GoldMaster_Structure.mqh>
#include <GoldMaster/GoldMaster_DXY.mqh>

input group "=== ESTRUCTURA ==="
input ENUM_TIMEFRAMES HTF        = PERIOD_H1;   // tendencia mayor
input int    SwingStrength       = 3;           // velas a cada lado (TF del gráfico)
input int    SwingStrengthHTF    = 3;
input int    BarsToAnalyze       = 600;

input group "=== QUÉ MOSTRAR ==="
input bool   ShowSwingLabels     = true;
input int    MaxSwingLabels      = 12;
input bool   ShowBOSCHoCH        = true;
input int    MaxEvents           = 6;
input bool   ShowOB              = true;
input int    MaxOBPerSide        = 2;
input bool   ShowFVG             = true;
input int    MaxFVGPerSide       = 2;
input bool   ShowLiquidity       = true;
input bool   ShowLevels          = true;
input ENUM_TIMEFRAMES LevelsTF   = PERIOD_H4;
input int    LevelMinTouches     = 3;
input int    MaxLevels           = 6;
input bool   ShowPremiumDiscount = true;
input bool   ShowPanel           = true;
input bool   ShowSignals         = true;

input group "=== DXY ==="
input bool   UseDXY              = true;
input bool   SignalsRequireDXY   = true;        // no dar señales contra el dólar

input group "=== ESTILO ==="
input int    FontSize            = 8;
input int    PanelFontSize       = 9;
input ENUM_BASE_CORNER PanelCorner = CORNER_LEFT_UPPER;
input color  ColBull             = clrDodgerBlue;
input color  ColBear             = clrTomato;
input color  ColCHoCH            = clrGold;
input color  ColOBBull           = C'0,70,40';
input color  ColOBBear           = C'90,20,20';
input color  ColFVGBull          = C'20,50,90';
input color  ColFVGBear          = C'90,60,10';
input color  ColText             = clrSilver;

double bufBuy[], bufSell[];
string P = "GM4_";
CGMDXY g_dxy;
datetime g_last_bar = 0;

//──────────────────────────────────────────────────────────────────
int OnInit() {
   SetIndexBuffer(0, bufBuy,  INDICATOR_DATA); PlotIndexSetInteger(0, PLOT_ARROW, 233);
   SetIndexBuffer(1, bufSell, INDICATOR_DATA); PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   ArraySetAsSeries(bufBuy, false); ArraySetAsSeries(bufSell, false);
   if(UseDXY) g_dxy.Init();
   if(GlobalVariableCheck(GVX())) g_pdx=(int)GlobalVariableGet(GVX());
   if(GlobalVariableCheck(GVY())) g_pdy=(int)GlobalVariableGet(GVY());
   IndicatorSetString(INDICATOR_SHORTNAME, "GM Estructura v4");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { ObjectsDeleteAll(0, P); ChartRedraw(); }

//──────────────────────── utilidades de dibujo ───────────────────
void Txt(string name, datetime t, double p, string s, color c, int size, ENUM_ANCHOR_POINT a=ANCHOR_LEFT) {
   string n=P+name;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_TEXT,0,t,p); else ObjectMove(0,n,0,t,p);
   ObjectSetString(0,n,OBJPROP_TEXT,s); ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,size); ObjectSetString(0,n,OBJPROP_FONT,"Arial");
   ObjectSetInteger(0,n,OBJPROP_ANCHOR,a); ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
}
void Seg(string name, datetime t1, double p1, datetime t2, double p2, color c, ENUM_LINE_STYLE st, int w=1) {
   string n=P+name;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_TREND,0,t1,p1,t2,p2);
   else { ObjectMove(0,n,0,t1,p1); ObjectMove(0,n,1,t2,p2); }
   ObjectSetInteger(0,n,OBJPROP_COLOR,c); ObjectSetInteger(0,n,OBJPROP_STYLE,st);
   ObjectSetInteger(0,n,OBJPROP_WIDTH,w); ObjectSetInteger(0,n,OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,n,OBJPROP_BACK,true);
}
void Box(string name, datetime t1, double p1, datetime t2, double p2, color c) {
   string n=P+name;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_RECTANGLE,0,t1,p1,t2,p2);
   else { ObjectMove(0,n,0,t1,p1); ObjectMove(0,n,1,t2,p2); }
   ObjectSetInteger(0,n,OBJPROP_COLOR,c); ObjectSetInteger(0,n,OBJPROP_FILL,true);
   ObjectSetInteger(0,n,OBJPROP_BACK,true); ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
}
int g_row=0;
int g_pdx=0, g_pdy=0;                                  // desplazamiento del panel (arrastrable)
string GVX(){ return "GM4_PNL_"+_Symbol+"_X"; }
string GVY(){ return "GM4_PNL_"+_Symbol+"_Y"; }
void PanelRow(string s, color c) {
   string n=P+"PNL_"+IntegerToString(g_row);
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,PanelCorner);
   bool right=(PanelCorner==CORNER_RIGHT_UPPER||PanelCorner==CORNER_RIGHT_LOWER);
   bool lower=(PanelCorner==CORNER_LEFT_LOWER||PanelCorner==CORNER_RIGHT_LOWER);
   ObjectSetInteger(0,n,OBJPROP_ANCHOR, right?(lower?ANCHOR_RIGHT_LOWER:ANCHOR_RIGHT_UPPER):(lower?ANCHOR_LEFT_LOWER:ANCHOR_LEFT_UPPER));
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,14+g_pdx);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,22+g_pdy+g_row*(PanelFontSize+7));
   ObjectSetString(0,n,OBJPROP_TEXT,s); ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,PanelFontSize); ObjectSetString(0,n,OBJPROP_FONT,"Consolas");
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   g_row++;
}
void PanelBg(int rows) {
   string n=P+"PNL_BG";
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,PanelCorner);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,6+g_pdx); ObjectSetInteger(0,n,OBJPROP_YDISTANCE,16+g_pdy);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,330); ObjectSetInteger(0,n,OBJPROP_YSIZE,rows*(PanelFontSize+7)+14);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'18,18,30'); ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_COLOR,C'60,60,90'); ObjectSetInteger(0,n,OBJPROP_BACK,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,true); ObjectSetString(0,n,OBJPROP_TOOLTIP,"Doble clic y arrastra para mover el panel"); ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
}

//──────────────────────────────────────────────────────────────────
int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[]) {
   if(rates_total < 100) return rates_total;
   if(time[rates_total-1] == g_last_bar && prev_calculated > 0) return rates_total;   // 1 vez por vela
   g_last_bar = time[rates_total-1];
   ArraySetAsSeries(time,false); ArraySetAsSeries(high,false); ArraySetAsSeries(low,false); ArraySetAsSeries(close,false);
   ObjectsDeleteAll(0, P);
   ArrayInitialize(bufBuy, EMPTY_VALUE); ArrayInitialize(bufSell, EMPTY_VALUE);

   int n = MathMin(BarsToAnalyze, rates_total);
   MqlRates r[]; if(CopyRates(_Symbol, PERIOD_CURRENT, 0, n, r) < n) return 0;
   int off = rates_total - n;                       // índice de r[0] en los buffers
   int psec = PeriodSeconds();
   datetime tNow = r[n-1].time, tRight = tNow + psec*6, tLbl = tNow + psec*8;
   double atr=0; for(int i=n-15;i<n-1;i++) atr += r[i].high-r[i].low; atr/=14.0;
   double px = r[n-1].close;

   GMSSwing sw[]; int ns = GMS_Swings(r, n, SwingStrength, sw);
   GMSEvent ev[]; int trend; int ne = GMS_Events(r, n, SwingStrength, sw, ns, ev, trend);
   GMSState H = GMS_Analyze(_Symbol, HTF, SwingStrengthHTF, 400);

   // ─ DXY ─
   int dxyTrend=0, dxyBias=0; double dxyVal=0, dxyChg=0, dxyCorr=0;
   if(UseDXY && g_dxy.Ready()) {
      dxyVal = g_dxy.Value(PERIOD_H1,0); dxyChg = g_dxy.ChangePct(PERIOD_H1,24);
      dxyTrend = g_dxy.Trend(PERIOD_H1); dxyCorr = g_dxy.Correlation(_Symbol,PERIOD_H1,60);
      dxyBias = (dxyCorr < -0.2) ? -dxyTrend : 0;
   }

   // ─ Swings HH/HL/LH/LL ─
   if(ShowSwingLabels) {
      int from = MathMax(0, ns-MaxSwingLabels);
      for(int i=from;i<ns;i++) {
         if(sw[i].label==0) continue;
         string s = sw[i].label==GMS_HH?"HH":sw[i].label==GMS_HL?"HL":sw[i].label==GMS_LH?"LH":"LL";
         color c = (sw[i].label==GMS_HH||sw[i].label==GMS_HL) ? ColBull : ColBear;
         Txt("SW"+IntegerToString(i), sw[i].t, sw[i].high ? sw[i].p+atr*0.25 : sw[i].p-atr*0.25, s, c, FontSize-1,
             sw[i].high ? ANCHOR_LOWER : ANCHOR_UPPER);
      }
   }

   // ─ BOS / CHoCH (últimos N) + señales ─
   if(ShowBOSCHoCH) {
      int from = MathMax(0, ne-MaxEvents);
      for(int i=from;i<ne;i++) {
         color c = ev[i].choch ? ColCHoCH : (ev[i].dir>0 ? ColBull : ColBear);
         Seg("EV"+IntegerToString(i), ev[i].t_swing, ev[i].price, ev[i].t_break, ev[i].price, c,
             ev[i].choch ? STYLE_SOLID : STYLE_DASH, ev[i].choch ? 2 : 1);
         datetime mid = ev[i].t_swing + (ev[i].t_break-ev[i].t_swing)/2;
         Txt("EVL"+IntegerToString(i), mid, ev[i].price, ev[i].choch?"CHoCH":"BOS", c, FontSize,
             ev[i].dir>0 ? ANCHOR_LOWER : ANCHOR_UPPER);
      }
   }
   if(ShowSignals) {
      for(int i=0;i<ne;i++) {
         int dir = ev[i].dir;
         if(H.trend != dir) continue;                         // micro a favor de la mayor
         if(SignalsRequireDXY && dxyBias == -dir) continue;   // DXY en contra
         int b = off + ev[i].bar_break;
         if(b<0 || b>=rates_total) continue;
         if(dir>0) bufBuy[b]  = low[b]  - atr*0.6;
         else      bufSell[b] = high[b] + atr*0.6;
      }
   }

   // ─ Order Blocks: última vela contraria antes de cada ruptura, sin mitigar ─
   if(ShowOB) {
      int nb=0, nsl=0;
      for(int i=ne-1;i>=0 && (nb<MaxOBPerSide || nsl<MaxOBPerSide);i--) {
         int dir=ev[i].dir, bb=ev[i].bar_break, ob=-1;
         for(int j=bb;j>MathMax(0,bb-30);j--) {
            bool opp = dir>0 ? (r[j].close<r[j].open) : (r[j].close>r[j].open);
            if(opp) { ob=j; break; }
         }
         if(ob<0) continue;
         double top=r[ob].high, bot=r[ob].low; bool mitig=false;
         for(int j=bb+1;j<n;j++) if(dir>0 ? r[j].low<bot : r[j].high>top) { mitig=true; break; }
         if(mitig) continue;
         if(dir>0 && nb>=MaxOBPerSide) continue;
         if(dir<0 && nsl>=MaxOBPerSide) continue;
         string id="OB"+IntegerToString(i);
         Box(id, r[ob].time, top, tRight, bot, dir>0?ColOBBull:ColOBBear);
         Txt(id+"L", tLbl, (top+bot)/2, StringFormat("OB %s %.2f", dir>0?"compra":"venta", (top+bot)/2),
             dir>0?ColBull:ColBear, FontSize-1);
         if(dir>0) nb++; else nsl++;
      }
   }

   // ─ FVG sin rellenar más cercanos ─
   if(ShowFVG) {
      int nb=0, nsl=0;
      for(int i=n-2;i>=2 && (nb<MaxFVGPerSide || nsl<MaxFVGPerSide);i--) {
         bool bull = r[i].low > r[i-2].high, bear = r[i].high < r[i-2].low;
         if(!bull && !bear) continue;
         double top = bull ? r[i].low : r[i-2].low, bot = bull ? r[i-2].high : r[i].high;
         if(top-bot < atr*0.15) continue;                           // huecos ridículos fuera
         bool filled=false;
         for(int j=i+1;j<n;j++) if(bull ? r[j].low<=bot : r[j].high>=top) { filled=true; break; }
         if(filled) continue;
         if(bull && nb>=MaxFVGPerSide) continue;
         if(bear && nsl>=MaxFVGPerSide) continue;
         string id="FVG"+IntegerToString(i);
         Box(id, r[i-1].time, top, tRight, bot, bull?ColFVGBull:ColFVGBear);
         Txt(id+"L", tLbl, (top+bot)/2, StringFormat("FVG %s", bull?"alcista":"bajista"), bull?ColBull:ColBear, FontSize-1);
         if(bull) nb++; else nsl++;
      }
   }

   // ─ Liquidez: máximos/mínimos iguales aún no barridos ─
   if(ShowLiquidity) {
      double tol = atr*0.15; int shown=0;
      for(int i=ns-1;i>=1 && shown<4;i--) for(int j=i-1;j>=MathMax(0,i-6);j--) {
         if(sw[i].high!=sw[j].high || MathAbs(sw[i].p-sw[j].p)>tol) continue;
         double lv = MathMax(sw[i].p,sw[j].p)*(sw[i].high?1:0) + MathMin(sw[i].p,sw[j].p)*(sw[i].high?0:1);
         bool swept=false;
         for(int k=sw[i].bar+1;k<n;k++) if(sw[i].high ? r[k].high>lv : r[k].low<lv) { swept=true; break; }
         if(swept) continue;
         string id="LQ"+IntegerToString(i);
         Seg(id, sw[j].t, lv, tRight, lv, sw[i].high?ColBull:ColBear, STYLE_DOT);
         Txt(id+"L", tLbl, lv, sw[i].high?"EQH · liquidez arriba":"EQL · liquidez abajo", sw[i].high?ColBull:ColBear, FontSize-1);
         shown++; break;
      }
   }

   // ─ Niveles estructurales multi-toque (TF mayor) ─
   if(ShowLevels) {
      MqlRates rl[]; int nl=CopyRates(_Symbol, LevelsTF, 0, 400, rl);
      if(nl>50) {
         GMSSwing swl[]; int nsl=GMS_Swings(rl,nl,2,swl);
         double atrL=0; for(int i=nl-15;i<nl-1;i++) atrL+=rl[i].high-rl[i].low; atrL/=14.0;
         GMSLevel lv[]; int nlv=GMS_Levels(swl,nsl,atrL*0.3,LevelMinTouches,lv);
         // ordenar por cercanía al precio y mostrar los MaxLevels más cercanos
         for(int a=0;a<nlv;a++) for(int b=a+1;b<nlv;b++)
            if(MathAbs(lv[b].p-px)<MathAbs(lv[a].p-px)) { GMSLevel t=lv[a]; lv[a]=lv[b]; lv[b]=t; }
         for(int i=0;i<MathMin(nlv,MaxLevels);i++) {
            bool res = lv[i].p > px;
            string id="LV"+IntegerToString(i);
            Seg(id, r[0].time, lv[i].p, tRight, lv[i].p, res?C'170,70,70':C'70,150,90', STYLE_SOLID, lv[i].touches>=4?2:1);
            Txt(id+"L", tLbl, lv[i].p, StringFormat("%s ×%d  %.2f", res?"Resistencia":"Soporte", lv[i].touches, lv[i].p),
                res?C'220,110,110':C'110,200,130', FontSize-1);
         }
      }
   }

   // ─ Premium / Equilibrio / Discount del rango (último swing alto y bajo) ─
   double rH=0, rL=0;
   for(int i=ns-1;i>=0 && (rH==0||rL==0);i--) { if(sw[i].high && rH==0) rH=sw[i].p; if(!sw[i].high && rL==0) rL=sw[i].p; }
   string zona="—";
   if(rH>rL && rL>0) {
      double eq=(rH+rL)/2;
      zona = px>eq ? "PREMIUM (caro → buscar ventas)" : "DISCOUNT (barato → buscar compras)";
      if(ShowPremiumDiscount) {
         datetime t0 = r[MathMax(0,n-60)].time;
         Seg("PD_H", t0, rH, tRight, rH, C'120,60,120', STYLE_DOT);
         Seg("PD_E", t0, eq, tRight, eq, clrGray, STYLE_DASHDOT);
         Seg("PD_L", t0, rL, tRight, rL, C'60,120,120', STYLE_DOT);
         Txt("PD_HL", tLbl, rH, "Premium", C'190,120,190', FontSize-1);
         Txt("PD_EL", tLbl, eq, "Equilibrio 50%", clrGray, FontSize-1);
         Txt("PD_LL", tLbl, rL, "Discount", C'120,190,190', FontSize-1);
      }
   }

   // ─ Panel ─
   if(ShowPanel) {
      g_row=0;
      PanelBg((UseDXY && g_dxy.Ready()) ? 10 : 7);    // fondo primero (queda detrás del texto)
      int last_dir = ne>0?ev[ne-1].dir:0; bool last_ch = ne>0?ev[ne-1].choch:false;
      int sig = 0;
      if(H.trend!=0 && trend==H.trend && last_dir==H.trend && !(SignalsRequireDXY && dxyBias==-H.trend)) sig=H.trend;
      PanelRow("GOLD MASTER · Estructura v4", clrWhite);
      PanelRow(StringFormat("Tendencia %-4s : %s", EnumToString(HTF)=="PERIOD_H1"?"H1":StringSubstr(EnumToString(HTF),7), GMS_TrendName(H.trend)),
               H.trend>0?ColBull:H.trend<0?ColBear:ColText);
      PanelRow(StringFormat("Micro (graf.) : %s", GMS_TrendName(trend)), trend>0?ColBull:trend<0?ColBear:ColText);
      PanelRow(StringFormat("Último evento : %s", GMS_EventName(last_dir,last_ch)), last_ch?ColCHoCH:ColText);
      PanelRow("Zona          : "+zona, ColText);
      if(UseDXY && g_dxy.Ready()) {
         PanelRow(StringFormat("DXY %.3f  Δ24h %+.2f%%", dxyVal, dxyChg), dxyChg>0?ColBear:ColBull);
         PanelRow(StringFormat("Dólar %s · corr %+.2f", dxyTrend>0?"FUERTE":dxyTrend<0?"DÉBIL":"neutro", dxyCorr), ColText);
         PanelRow("Efecto oro    : "+(dxyBias>0?"a favor de COMPRAS":dxyBias<0?"a favor de VENTAS":"sin influencia"),
                  dxyBias>0?ColBull:dxyBias<0?ColBear:ColText);
         PanelRow("Fuente DXY    : "+g_dxy.Mode(), clrDimGray);
      } else PanelRow("DXY           : no disponible", clrDimGray);
      PanelRow(sig>0?"SEÑAL ▲ COMPRA (estructura alineada)":sig<0?"SEÑAL ▼ VENTA (estructura alineada)":"SEÑAL — esperar alineación",
               sig>0?clrLime:sig<0?clrRed:clrGray);
   }
   ChartRedraw();
   return rates_total;
}

void OnChartEvent(const int id,const long &l,const double &d,const string &sp) {
   if(id!=CHARTEVENT_OBJECT_DRAG || sp!=P+"PNL_BG") return;
   int nx=(int)ObjectGetInteger(0,sp,OBJPROP_XDISTANCE)-6, ny=(int)ObjectGetInteger(0,sp,OBJPROP_YDISTANCE)-16;
   int dx=nx-g_pdx, dy=ny-g_pdy; g_pdx=nx; g_pdy=ny;
   GlobalVariableSet(GVX(),g_pdx); GlobalVariableSet(GVY(),g_pdy);
   for(int i=0;i<40;i++){ string n=P+"PNL_"+IntegerToString(i); if(ObjectFind(0,n)<0) break;
      ObjectSetInteger(0,n,OBJPROP_XDISTANCE,ObjectGetInteger(0,n,OBJPROP_XDISTANCE)+dx);
      ObjectSetInteger(0,n,OBJPROP_YDISTANCE,ObjectGetInteger(0,n,OBJPROP_YDISTANCE)+dy); }
   ObjectSetInteger(0,sp,OBJPROP_SELECTED,false); ChartRedraw();
}
