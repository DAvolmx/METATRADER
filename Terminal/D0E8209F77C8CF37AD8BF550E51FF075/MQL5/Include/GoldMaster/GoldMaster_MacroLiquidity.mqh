#ifndef GM_MACRO_LIQUIDITY_MQH
#define GM_MACRO_LIQUIDITY_MQH
#include <GoldMaster/GoldMaster_Structure.mqh>
struct GMMacro { MqlRates candle; datetime end,start; double slope,mid,upper,lower; int direction; bool valid; };
bool GM_MacroRead(string symbol,int days,GMMacro &m) {
 ZeroMemory(m); if(days<7) return false;
 MqlRates latest[]; if(CopyRates(symbol,PERIOD_H3,1,1,latest)!=1) return false;
 m.candle=latest[0];m.end=m.candle.time+10800;m.start=m.end-days*86400;
 if(m.end>TimeCurrent()) return false;
 MqlRates r[];ArraySetAsSeries(r,false);
 int n=CopyRates(symbol,PERIOD_H3,m.start,m.end-1,r);
 if(n<30 || r[0].time>m.start+86400) return false;
 double sx=0,sy=0,sxx=0,sxy=0;
 for(int i=0;i<n;i++){double x=(double)(r[i].time-m.start)/10800.0;sx+=x;sy+=r[i].close;sxx+=x*x;sxy+=x*r[i].close;}
 double den=n*sxx-sx*sx;if(den<=0) return false;
 m.slope=(n*sxy-sx*sy)/den;double intercept=(sy-m.slope*sx)/n;
 double above=0,below=0;
 for(int i=0;i<n;i++){double base=intercept+m.slope*(double)(r[i].time-m.start)/10800.0;above=MathMax(above,r[i].high-base);below=MathMax(below,base-r[i].low);}
 m.mid=intercept+m.slope*(double)(m.candle.time-m.start)/10800.0;m.upper=m.mid+above;m.lower=m.mid-below;
 m.direction=m.slope>0?1:m.slope<0?-1:0;m.valid=true;return true;
}
int GM_MacroH1(string symbol,datetime after,datetime &confirmed) {
 MqlRates r[];ArraySetAsSeries(r,false);int n=CopyRates(symbol,PERIOD_H1,0,250,r);if(n<30)return 0;
 GMSSwing sw[];GMSEvent ev[];int trend=0;
 int ns=GMS_Swings(r,n,2,sw),ne=GMS_Events(r,n,2,sw,ns,ev,trend);
 if(ne<1)return 0;GMSEvent e=ev[ne-1];confirmed=e.t_break+3600;
 if(confirmed<after || confirmed>TimeCurrent())return 0;return e.dir;
}
void GM_MacroLine(string name,double price,color col,string text){
 if(ObjectFind(0,name)<0)ObjectCreate(0,name,OBJ_HLINE,0,0,price);
 ObjectSetDouble(0,name,OBJPROP_PRICE,price);ObjectSetInteger(0,name,OBJPROP_COLOR,col);
 ObjectSetString(0,name,OBJPROP_TEXT,text);ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}
void GM_MacroDraw(const GMMacro &m){
 if(!m.valid)return;
 GM_MacroLine("GMM_HIGH",m.candle.high,clrOrangeRed,"H3 MAX · liquidez candidata");
 GM_MacroLine("GMM_LOW",m.candle.low,clrDeepSkyBlue,"H3 MIN · liquidez candidata");
 GM_MacroLine("GMM_OPEN",m.candle.open,clrSilver,"H3 APERTURA");
 GM_MacroLine("GMM_CLOSE",m.candle.close,clrGold,"H3 CIERRE");
 for(int i=0;i<2;i++){string name=i==0?"GMM_TIME_OPEN":"GMM_TIME_CLOSE";datetime t=i==0?m.candle.time:m.end;
 if(ObjectFind(0,name)<0)ObjectCreate(0,name,OBJ_VLINE,0,t,0);ObjectMove(0,name,0,t,0);ObjectSetInteger(0,name,OBJPROP_COLOR,clrDimGray);}
 double x=(double)(m.candle.time-m.start)/10800.0;
 double ends[3];ends[0]=m.upper;ends[1]=m.mid;ends[2]=m.lower;
 for(int i=0;i<3;i++){string name="GMM_CHANNEL_"+IntegerToString(i);
 if(ObjectFind(0,name)<0)ObjectCreate(0,name,OBJ_TREND,0,m.start,ends[i]-m.slope*x,m.candle.time,ends[i]);
 ObjectMove(0,name,0,m.start,ends[i]-m.slope*x);ObjectMove(0,name,1,m.candle.time,ends[i]);
 ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,true);ObjectSetInteger(0,name,OBJPROP_COLOR,clrMediumPurple);ObjectSetInteger(0,name,OBJPROP_STYLE,i==1?STYLE_DASH:STYLE_SOLID);}
}
#endif
