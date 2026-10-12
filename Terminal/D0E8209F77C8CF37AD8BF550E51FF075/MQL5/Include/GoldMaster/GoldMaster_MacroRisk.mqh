#ifndef GM_MACRO_RISK_MQH
#define GM_MACRO_RISK_MQH
// Risk at SL in account currency. Missing stops/conversion blocks admission.
bool GM_AccountStopRisk(double &risk,string &reason){
 risk=0;reason="";
 for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0)continue;
 string sym=PositionGetString(POSITION_SYMBOL);double sl=PositionGetDouble(POSITION_SL),money=0;
 ENUM_ORDER_TYPE type=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
 if(sl<=0 || !OrderCalcProfit(type,sym,PositionGetDouble(POSITION_VOLUME),PositionGetDouble(POSITION_PRICE_OPEN),sl,money)){reason="Posición sin SL o valoración disponible";return false;}risk+=MathMax(0,-money);}
 for(int i=OrdersTotal()-1;i>=0;i--){ulong t=OrderGetTicket(i);if(t==0)continue;
 ENUM_ORDER_TYPE ot=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
 bool buy=(ot==ORDER_TYPE_BUY_LIMIT || ot==ORDER_TYPE_BUY_STOP || ot==ORDER_TYPE_BUY_STOP_LIMIT);
 bool sell=(ot==ORDER_TYPE_SELL_LIMIT || ot==ORDER_TYPE_SELL_STOP || ot==ORDER_TYPE_SELL_STOP_LIMIT);
 if(!buy && !sell)continue;
 double price=OrderGetDouble(ORDER_PRICE_OPEN);if(ot==ORDER_TYPE_BUY_STOP_LIMIT || ot==ORDER_TYPE_SELL_STOP_LIMIT)price=OrderGetDouble(ORDER_PRICE_STOPLIMIT);
 double sl=OrderGetDouble(ORDER_SL),money=0;
 if(sl<=0 || !OrderCalcProfit(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,OrderGetString(ORDER_SYMBOL),OrderGetDouble(ORDER_VOLUME_CURRENT),price,sl,money)){reason="Pendiente sin SL o valoración disponible";return false;}risk+=MathMax(0,-money);}
 return true;
}
bool GM_DXYClosed(string symbol,datetime clock,int &direction){
 direction=0;MqlRates r[];ArraySetAsSeries(r,false);
 int n=CopyRates(symbol,PERIOD_H1,clock-12*3600,clock,r);if(n<5)return false;
 double closes[5];int found=0;datetime latest=0;
 for(int i=n-1;i>=0 && found<5;i--)if(r[i].time+3600<=clock){if(r[i].close<=0)return false;closes[found++]=r[i].close;if(latest==0)latest=r[i].time+3600;}
 if(found<5 || clock-latest>7200)return false;
 double move=closes[0]/closes[4]-1;direction=move>0.0001?1:move<-0.0001?-1:0;return true;
}
uint GM_ServerIdentity(){string server=AccountInfoString(ACCOUNT_SERVER);uint hash=2166136261;for(int i=0;i<StringLen(server);i++)hash=(hash^(uint)StringGetCharacter(server,i))*16777619;return hash;}
#endif
