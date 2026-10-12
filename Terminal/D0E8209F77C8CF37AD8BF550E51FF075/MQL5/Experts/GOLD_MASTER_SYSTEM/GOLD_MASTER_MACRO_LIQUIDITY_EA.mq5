#property strict
#property version "1.00"
#include <GoldMaster/GoldMaster_Core.mqh>
#include <GoldMaster/GoldMaster_MacroLiquidity.mqh>
#include <GoldMaster/GoldMaster_MacroRisk.mqh>
input bool PaperModeOnly=true;
input int ChannelDays=7;
input double RiskPct=0.5;
input double RiskCashPerTrade=0;
input double RewardRisk=2;
input int MaxSpreadPoints=50;
input double MaxDailyLossPct=2;
input double MinSlopeATR=0.02;
input double StopPadATR=0.2;
input int SweepExpiryBars=8;
input int MagicNumber=900030;
input bool UseDXYFilter=true;
input string DXYSymbol="DXYUSD";
input double MaxAccountStopRiskPct=3;
input double RiskReservePct=10;
CTrade trade;int atrHandle=INVALID_HANDLE,fastHandle=INVALID_HANDLE,slowHandle=INVALID_HANDLE;
datetime lastBar=0,macroTime=0,sweepTime=0,day=0;int sweepDir=0;double sweepExtreme=0,dayEquity=0;
int OnInit(){if(ChannelDays<7 || RiskPct<=0 || RiskCashPerTrade<0 || RewardRisk<1 || MaxDailyLossPct<=0 || SweepExpiryBars<1 || MinSlopeATR<0 || StopPadATR<0)return INIT_PARAMETERS_INCORRECT;
 atrHandle=iATR(_Symbol,PERIOD_M15,14);fastHandle=iMA(_Symbol,PERIOD_H1,50,0,MODE_EMA,PRICE_CLOSE);slowHandle=iMA(_Symbol,PERIOD_H1,200,0,MODE_EMA,PRICE_CLOSE);
 if(atrHandle==INVALID_HANDLE || fastHandle==INVALID_HANDLE || slowHandle==INVALID_HANDLE)return INIT_FAILED;
 g_gm_minlot_risk_tol=1.0;
 if(MaxAccountStopRiskPct<=0 || RiskReservePct<0)return INIT_PARAMETERS_INCORRECT;
 if(UseDXYFilter && (StringFind(_Symbol,"XAU")<0 || !SymbolSelect(DXYSymbol,true)))return INIT_PARAMETERS_INCORRECT;
 trade.SetExpertMagicNumber(MagicNumber);trade.SetTypeFilling(GM_FillingMode(_Symbol));trade.SetDeviationInPoints(10);return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){IndicatorRelease(atrHandle);IndicatorRelease(fastHandle);IndicatorRelease(slowHandle);ObjectsDeleteAll(0,"GMM_");Comment("");}
bool HasExposure(){for(int i=PositionsTotal()-1;i>=0;i--){if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==_Symbol)return true;}return false;}
void OnTick(){
 datetime bar=iTime(_Symbol,PERIOD_M15,0);if(bar<=0 || bar==lastBar)return;lastBar=bar;
 MqlDateTime now;TimeToStruct(TimeCurrent(),now);now.hour=0;now.min=0;now.sec=0;datetime today=StructToTime(now);
 string key="GMM_"+IntegerToString((long)GM_ServerIdentity())+"_"+IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))+"_"+IntegerToString(MagicNumber)+"_"+StringSubstr(_Symbol,0,12);
 if(today!=day){day=today;dayEquity=AccountInfoDouble(ACCOUNT_EQUITY);
 if(!MQLInfoInteger(MQL_TESTER)){if(GlobalVariableCheck(key+"T") && (datetime)GlobalVariableGet(key+"T")==today && GlobalVariableCheck(key+"E"))dayEquity=GlobalVariableGet(key+"E");else{GlobalVariableSet(key+"E",dayEquity);GlobalVariableSet(key+"T",(double)today);GlobalVariablesFlush();}}}
 GMMacro m;if(!GM_MacroRead(_Symbol,ChannelDays,m)){ObjectsDeleteAll(0,"GMM_");Comment("GM Macro: historial insuficiente");return;}GM_MacroDraw(m);
 if(m.candle.time!=macroTime){macroTime=m.candle.time;sweepDir=0;sweepTime=0;}
 if(dayEquity<=0 || AccountInfoDouble(ACCOUNT_EQUITY)<=dayEquity*(1-MaxDailyLossPct/100.0))return;
 MqlRates r[];ArraySetAsSeries(r,true);if(CopyRates(_Symbol,PERIOD_M15,1,2,r)!=2 || r[0].time<m.end)return;
 double atr=GM_GetATR(atrHandle,1),fast=GM_GetEMA(fastHandle,1),slow=GM_GetEMA(slowHandle,1);
 if(atr<=0 || fast<=0 || slow<=0 || MathAbs(m.slope)<MinSlopeATR*atr)return;
 int dxy=0;if(UseDXYFilter && !GM_DXYClosed(DXYSymbol,r[0].time+900,dxy)){Comment("GM Macro: DXY histórico ausente/antiguo; entrada bloqueada");return;}
 int dir=m.direction;if(UseDXYFilter && dxy==dir)return;if((dir==1 && fast<=slow)||(dir==-1 && fast>=slow))return;
 if(sweepDir && r[0].time-sweepTime>SweepExpiryBars*900)sweepDir=0;
 if(!sweepDir){
 if(dir==1 && r[0].low<m.candle.low && r[0].close>m.candle.low){sweepDir=1;sweepExtreme=r[0].low;sweepTime=r[0].time+900;}
 if(dir==-1 && r[0].high>m.candle.high && r[0].close<m.candle.high){sweepDir=-1;sweepExtreme=r[0].high;sweepTime=r[0].time+900;}
 }
 datetime confirmed=0;int h1=GM_MacroH1(_Symbol,sweepTime,confirmed);
 Comment("GM H3/H1/M15 · macro ",TimeToString(m.candle.time)," → ",TimeToString(m.end)," servidor\nCanal ",ChannelDays," días · tendencia ",dir," · sweep ",sweepDir," · H1 ",h1,"\n",PaperModeOnly?"ANÁLISIS: sin órdenes":"EJECUCIÓN habilitada por input");
 if(!sweepDir || h1!=sweepDir || r[0].time+900<confirmed || HasExposure() || GM_GetSpread(_Symbol)>MaxSpreadPoints)return;
 if((sweepDir==1 && r[0].close<=r[1].high)||(sweepDir==-1 && r[0].close>=r[1].low))return;
 MqlTick tick;if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0 || tick.bid<=0)return;
 double entry=sweepDir==1?tick.ask:tick.bid,sl=sweepExtreme-sweepDir*StopPadATR*atr;
 double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);if(step<=0)return;
 sl=NormalizeDouble((sweepDir==1?MathFloor(sl/step):MathCeil(sl/step))*step,_Digits);
 double risk=MathAbs(entry-sl),room=sweepDir==1?m.candle.high-entry:entry-m.candle.low;
 if(risk<=0 || room<risk*RewardRisk || (sweepDir==1 && sl>=entry)||(sweepDir==-1 && sl<=entry))return;
 double tp=NormalizeDouble(MathRound((entry+sweepDir*risk*RewardRisk)/step)*step,_Digits);
 double lot=GM_CalcLot(_Symbol,RiskPct,risk,RiskCashPerTrade);if(lot<=0)return;
 double money=0,existingRisk=0;string riskReason="";
 if(!OrderCalcProfit(sweepDir==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL,_Symbol,lot,entry,sl,money) || money>=0)return;
 if(!GM_AccountStopRisk(existingRisk,riskReason)){Comment("GM Macro riesgo: ",riskReason);return;}
 double budget=AccountInfoDouble(ACCOUNT_EQUITY)*MaxAccountStopRiskPct/100.0;
 if(existingRisk+MathAbs(money)*(1+RiskReservePct/100.0)>budget){Comment("GM Macro: presupuesto conjunto de stops excedido");return;}
 double minStop=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
 if((sweepDir==1 && (tick.bid-sl<minStop || tp-tick.bid<minStop))||(sweepDir==-1 && (sl-tick.ask<minStop || tick.ask-tp<minStop)))return;
 if(PaperModeOnly){Print("[GM_MACRO][PAPER] dirección=",sweepDir," lote=",lot," entrada=",entry," SL=",sl," TP=",tp);sweepDir=0;return;}
 double margin=0;
 ENUM_ORDER_TYPE type=sweepDir==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
 if(!OrderCalcMargin(type,_Symbol,lot,entry,margin) || margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE))return;
 MqlTradeRequest req={};MqlTradeCheckResult check={};
 req.action=TRADE_ACTION_DEAL;req.symbol=_Symbol;req.magic=MagicNumber;req.type=type;
 req.volume=lot;req.price=entry;req.sl=sl;req.tp=tp;req.deviation=10;req.type_filling=GM_FillingMode(_Symbol);
 if(!OrderCheck(req,check) || check.retcode!=0){Print("[GM_MACRO] OrderCheck: ",check.comment);return;}
 bool ok=sweepDir==1?trade.Buy(lot,_Symbol,0,sl,tp,"GM_MACRO"):trade.Sell(lot,_Symbol,0,sl,tp,"GM_MACRO");
 if(ok && trade.ResultRetcode()==TRADE_RETCODE_DONE)sweepDir=0;else Print("[GM_MACRO] envío rechazado: ",trade.ResultRetcodeDescription());
}
