#property strict
#property indicator_chart_window
#property indicator_plots 0
#property version "1.00"
#include <GoldMaster/GoldMaster_MacroLiquidity.mqh>
input int ChannelDays=7;
int OnInit(){if(ChannelDays<7)return INIT_PARAMETERS_INCORRECT;IndicatorSetString(INDICATOR_SHORTNAME,"GM Macro H3 Liquidity");return INIT_SUCCEEDED;}
int OnCalculate(const int rates_total,const int prev_calculated,const datetime &time[],const double &open[],const double &high[],const double &low[],const double &close[],const long &tick_volume[],const long &volume[],const int &spread[]){
 GMMacro m;if(GM_MacroRead(_Symbol,ChannelDays,m)){GM_MacroDraw(m);Comment("GM MACRO H3 · ",TimeToString(m.candle.time)," → ",TimeToString(m.end)," servidor\nCanal ",ChannelDays," días · tendencia ",m.direction," · niveles candidatos, no libro de órdenes");}
 else {ObjectsDeleteAll(0,"GMM_");Comment("GM Macro: esperando historial H3 de al menos una semana");}return rates_total;
}
void OnDeinit(const int reason){ObjectsDeleteAll(0,"GMM_");Comment("");}
