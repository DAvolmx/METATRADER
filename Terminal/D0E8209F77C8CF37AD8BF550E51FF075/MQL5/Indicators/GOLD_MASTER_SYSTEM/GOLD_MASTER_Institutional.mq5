//+------------------------------------------------------------------+
//| GOLD_MASTER_Institutional.mq5                                     |
//| Niveles que miran las mesas institucionales:                     |
//|  · VWAP diario + bandas ±1σ / ±2σ (ponderado por volumen)          |
//|  · Máx / Mín / Cierre del día anterior (PDH/PDL/PDC)               |
//|  · Apertura semanal y rango asiático (00–07 servidor)              |
//|  · Squeeze: Bollinger(20,2) dentro de Keltner(20,1.5) → compresión |
//| Sin repintado: todo se calcula con velas cerradas del pasado.     |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   6
#property indicator_type1 DRAW_LINE
#property indicator_color1 clrGold
#property indicator_width1 2
#property indicator_label1 "VWAP"
#property indicator_type2 DRAW_LINE
#property indicator_color2 C'90,120,160'
#property indicator_style2 STYLE_DOT
#property indicator_label2 "VWAP +1σ"
#property indicator_type3 DRAW_LINE
#property indicator_color3 C'90,120,160'
#property indicator_style3 STYLE_DOT
#property indicator_label3 "VWAP -1σ"
#property indicator_type4 DRAW_LINE
#property indicator_color4 C'160,80,100'
#property indicator_label4 "VWAP +2σ"
#property indicator_type5 DRAW_LINE
#property indicator_color5 C'60,150,120'
#property indicator_label5 "VWAP -2σ"
#property indicator_type6 DRAW_ARROW
#property indicator_color6 clrMagenta
#property indicator_label6 "Squeeze"

input int  AsiaEndHour = 7;
input bool ShowLevels  = true;
input bool ShowSqueeze = true;

double bV[],bU1[],bL1[],bU2[],bL2[],bSq[];
const string P="GMI_";

int OnInit(){
   SetIndexBuffer(0,bV); SetIndexBuffer(1,bU1); SetIndexBuffer(2,bL1); SetIndexBuffer(3,bU2); SetIndexBuffer(4,bL2); SetIndexBuffer(5,bSq);
   PlotIndexSetInteger(5,PLOT_ARROW,159);
   for(int i=0;i<6;i++) PlotIndexSetDouble(i,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   IndicatorSetString(INDICATOR_SHORTNAME,"GM Institucional");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int r){ ObjectsDeleteAll(0,P); }

void HLine(string n,double p,color c,string txt,ENUM_LINE_STYLE st=STYLE_DASH){
   if(p<=0) return;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_HLINE,0,0,p);
   ObjectSetDouble(0,n,OBJPROP_PRICE,p); ObjectSetInteger(0,n,OBJPROP_COLOR,c); ObjectSetInteger(0,n,OBJPROP_STYLE,st);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,n,OBJPROP_BACK,true); ObjectSetString(0,n,OBJPROP_TEXT,txt);
   string t=n+"T"; if(ObjectFind(0,t)<0) ObjectCreate(0,t,OBJ_TEXT,0,0,0);
   ObjectSetInteger(0,t,OBJPROP_TIME,0,iTime(_Symbol,PERIOD_CURRENT,0)+PeriodSeconds()*6); ObjectSetDouble(0,t,OBJPROP_PRICE,0,p);
   ObjectSetString(0,t,OBJPROP_TEXT,txt+" "+DoubleToString(p,_Digits)); ObjectSetInteger(0,t,OBJPROP_COLOR,c);
   ObjectSetInteger(0,t,OBJPROP_FONTSIZE,7); ObjectSetInteger(0,t,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER); ObjectSetInteger(0,t,OBJPROP_SELECTABLE,false);
}

int OnCalculate(const int total,const int prev,const datetime &time[],const double &open[],const double &high[],const double &low[],
                const double &close[],const long &tick_volume[],const long &volume[],const int &spread[]){
   if(total<50) return total;
   int start = prev>0 ? prev-1 : 0;
   // VWAP diario: se reinicia al cambiar de día; σ = desvío ponderado por volumen
   static double sPV=0,sV=0,sP2V=0; static int lastDay=-1;
   if(prev==0){ sPV=sV=sP2V=0; lastDay=-1; }
   for(int i=start;i<total;i++){
      MqlDateTime d; TimeToStruct(time[i],d);
      if(i==start && prev>0){ // recalcular la vela en curso: restar su aporte previo no es posible → recomputar el día
         int j=i; while(j>0){ MqlDateTime dj; TimeToStruct(time[j-1],dj); if(dj.day_of_year!=d.day_of_year) break; j--; }
         sPV=sV=sP2V=0; for(int k=j;k<i;k++){ double tp=(high[k]+low[k]+close[k])/3, v=(double)MathMax(tick_volume[k],1); sPV+=tp*v; sV+=v; sP2V+=tp*tp*v; }
         lastDay=d.day_of_year;
      }
      if(d.day_of_year!=lastDay){ sPV=sV=sP2V=0; lastDay=d.day_of_year; }
      double tp=(high[i]+low[i]+close[i])/3, v=(double)MathMax(tick_volume[i],1);
      double PV=sPV+tp*v, V=sV+v, P2V=sP2V+tp*tp*v;
      double vw=PV/V, sd=MathSqrt(MathMax(P2V/V-vw*vw,0));
      bV[i]=vw; bU1[i]=vw+sd; bL1[i]=vw-sd; bU2[i]=vw+2*sd; bL2[i]=vw-2*sd;
      if(i<total-1){ sPV=PV; sV=V; sP2V=P2V; }                 // la vela en curso no se acumula hasta cerrar
      // Squeeze (Bollinger dentro de Keltner) con velas cerradas
      bSq[i]=EMPTY_VALUE;
      if(ShowSqueeze && i>=20){
         double m=0,s2=0,tr=0; for(int k=i-19;k<=i;k++){ m+=close[k]; }
         m/=20; for(int k=i-19;k<=i;k++){ s2+=(close[k]-m)*(close[k]-m); tr+=MathMax(high[k],close[k-1])-MathMin(low[k],close[k-1]); }
         double bb=2*MathSqrt(s2/20), kc=1.5*tr/20;
         if(bb<kc) bSq[i]=low[i]-tr/20*0.5;
      }
   }
   if(ShowLevels){
      double pdh=iHigh(_Symbol,PERIOD_D1,1), pdl=iLow(_Symbol,PERIOD_D1,1), pdc=iClose(_Symbol,PERIOD_D1,1), wo=iOpen(_Symbol,PERIOD_W1,0);
      HLine(P+"PDH",pdh,C'200,90,90',"PDH"); HLine(P+"PDL",pdl,C'90,180,120',"PDL"); HLine(P+"PDC",pdc,clrSilver,"PDC",STYLE_DOT);
      HLine(P+"WO",wo,clrDodgerBlue,"Apertura semanal",STYLE_DASHDOT);
      // rango asiático de hoy
      datetime d0=iTime(_Symbol,PERIOD_D1,0); double ah=0,al=DBL_MAX;
      for(int i=total-1;i>=0 && time[i]>=d0;i--){ MqlDateTime dt; TimeToStruct(time[i],dt); if(dt.hour<AsiaEndHour){ ah=MathMax(ah,high[i]); al=MathMin(al,low[i]); } }
      if(ah>0 && al<DBL_MAX){
         string n=P+"ASIA"; datetime t1=d0+AsiaEndHour*3600;
         if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_RECTANGLE,0,d0,ah,t1,al);
         ObjectSetInteger(0,n,OBJPROP_TIME,0,d0); ObjectSetDouble(0,n,OBJPROP_PRICE,0,ah); ObjectSetInteger(0,n,OBJPROP_TIME,1,t1); ObjectSetDouble(0,n,OBJPROP_PRICE,1,al);
         ObjectSetInteger(0,n,OBJPROP_COLOR,C'40,40,70'); ObjectSetInteger(0,n,OBJPROP_FILL,true); ObjectSetInteger(0,n,OBJPROP_BACK,true); ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
      }
   }
   return total;
}
