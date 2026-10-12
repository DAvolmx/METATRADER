//+------------------------------------------------------------------+
//|  GoldMaster_PositionManager.mqh                                   |
//|  Gestión de posiciones: parciales, trailing, BE, riesgo          |
//|  GOLD MASTER SYSTEM v3.0 — David Domez / Deriv                  |
//+------------------------------------------------------------------+
#ifndef GOLDMASTER_POSMGR_MQH
#define GOLDMASTER_POSMGR_MQH

#include "GoldMaster_Core.mqh"

class CGoldMasterPositionManager
{
private:
   int      m_magic;
   string   m_symbol;
   double   m_atr;
   
   struct TradeState {
      ulong  ticket;
      double open_price;
      double sl_original;
      double lot_original;
      bool   p1_done;
      bool   p2_done;
      bool   be_done;
   };
   TradeState m_states[50];
   int        m_state_count;
   
   int FindIdx(ulong ticket) {
      for(int i=0;i<m_state_count;i++) if(m_states[i].ticket==ticket) return i;
      return -1;
   }
   
   bool ModifySL(ulong ticket, double new_sl) {
      if(!PositionSelectByTicket(ticket)) return false;
      int digits=(int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      double tp = PositionGetDouble(POSITION_TP);
      double cur = PositionGetDouble(POSITION_SL);
      double pt  = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      new_sl = NormalizeDouble(new_sl, digits);
      ENUM_POSITION_TYPE pt_type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      // 1) Nunca empeorar el SL (el SL sólo se mueve a favor)
      if(cur > 0) {
         if(pt_type==POSITION_TYPE_BUY  && new_sl <= cur + pt/2) return false;
         if(pt_type==POSITION_TYPE_SELL && new_sl >= cur - pt/2) return false;
      }
      // 2) Respetar distancia mínima del broker al precio actual
      double lvl = MathMax((double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL),
                           (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * pt;
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID), ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      if(pt_type==POSITION_TYPE_BUY  && new_sl > bid - lvl - pt) return false;
      if(pt_type==POSITION_TYPE_SELL && new_sl < ask + lvl + pt) return false;
      MqlTradeRequest req={}; MqlTradeResult res={};
      req.action=TRADE_ACTION_SLTP; req.symbol=m_symbol;
      req.position=ticket; req.sl=NormalizeDouble(new_sl,digits); req.tp=tp;
      bool ok=OrderSend(req,res);
      if(!ok) GM_Log("GM_PosMgr","ModifySL err "+IntegerToString(res.retcode));
      return ok;
   }
   
   bool PartialClose(ulong ticket, double lot_close) {
      if(!PositionSelectByTicket(ticket)) return false;
      ENUM_POSITION_TYPE t=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double price=(t==POSITION_TYPE_BUY)?SymbolInfoDouble(m_symbol,SYMBOL_BID):SymbolInfoDouble(m_symbol,SYMBOL_ASK);
      if(lot_close<=0) return false;               // no divisible (lote mínimo) → no cerrar
      double vol=PositionGetDouble(POSITION_VOLUME);
      if(lot_close>=vol) return false;             // nunca cerrar la posición completa como "parcial"
      MqlTradeRequest req={}; MqlTradeResult res={};
      req.action=TRADE_ACTION_DEAL; req.symbol=m_symbol; req.position=ticket;
      req.volume=lot_close; req.price=price;
      req.type=(t==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
      req.type_filling=GM_FillingMode(m_symbol); req.deviation=30; req.comment="GM_P";
      bool ok=OrderSend(req,res);
      if(!ok) GM_Log("GM_PosMgr","PartialClose err "+IntegerToString(res.retcode));
      return ok;
   }

public:
   CGoldMasterPositionManager(int magic, string symbol) {
      m_magic=magic; m_symbol=symbol; m_atr=0; m_state_count=0; m_be_r=1.0; m_be_nodiv_r=1.5; m_nodiv_lock_r=0.3;
   }
   
   double m_be_r;
   void SetATR(double atr) { m_atr=atr; }
   void SetBreakevenR(double r) { m_be_r=r; }
   double m_be_nodiv_r, m_nodiv_lock_r;
   void SetNoDivBE(double trig_r,double lock_r){ m_be_nodiv_r=trig_r; m_nodiv_lock_r=lock_r; }   // 0 = desactivar BE/parciales
   
   void RegisterPosition(ulong ticket, double open_price, double sl, double lot) {
      int idx=FindIdx(ticket);
      if(idx<0) { if(m_state_count>=50) return; idx=m_state_count++; }
      m_states[idx].ticket=ticket; m_states[idx].open_price=open_price;
      m_states[idx].sl_original=sl; m_states[idx].lot_original=lot;
      m_states[idx].p1_done=false; m_states[idx].p2_done=false; m_states[idx].be_done=false;
   }
   
   void ManageAll() {
      if(m_atr<=0) return;
      for(int i=PositionsTotal()-1;i>=0;i--) {
         ulong ticket=PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=m_magic) continue;
         if(PositionGetString(POSITION_SYMBOL)!=m_symbol) continue;
         ManageOne(ticket);
      }
      for(int i=m_state_count-1;i>=0;i--) {
         if(!PositionSelectByTicket(m_states[i].ticket)) {
            m_states[i]=m_states[--m_state_count];
         }
      }
   }
   
   void ManageOne(ulong ticket) {
      if(!PositionSelectByTicket(ticket)) return;
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open_p = PositionGetDouble(POSITION_PRICE_OPEN);
      double cur_sl = PositionGetDouble(POSITION_SL);
      double lot    = PositionGetDouble(POSITION_VOLUME);
      double price  = PositionGetDouble(POSITION_PRICE_CURRENT);
      
      int idx=FindIdx(ticket);
      if(idx<0) { RegisterPosition(ticket,open_p,cur_sl,lot); idx=FindIdx(ticket); }
      if(idx<0) return;
      // R se mide SIEMPRE contra el riesgo inicial (si se usara el SL actual, cada
      // trailing cambiaría R y el gestor entraría en bucle BE ⇄ trailing)
      double sl_dist = MathAbs(open_p - m_states[idx].sl_original);
      if(sl_dist<=0) sl_dist = (m_atr>0 ? m_atr*2.0 : MathAbs(open_p-cur_sl));
      double profit  = (type==POSITION_TYPE_BUY)?(price-open_p):(open_p-price);
      double r       = (sl_dist>0)?profit/sl_dist:0;
      
      // P1: con lote divisible → 40% en BE_R y stop a BE.
      //     con lote NO divisible (micro 0.1) → esperar a BE_NoDiv_R y asegurar +LockR
      //     (el backtest mostró que el BE a 1R sin parcial cerraba en 0 muchas operaciones ganadoras)
      double p1_lot=GM_PartialLot(m_symbol, PositionGetDouble(POSITION_VOLUME), 0.40);
      double p1_trig=(p1_lot>0)?m_be_r:m_be_nodiv_r;
      if(m_be_r>0 && !m_states[idx].p1_done && r>=p1_trig) {
         if(p1_lot<=0) GM_Log("GM_PosMgr",StringFormat("P1 @%.1fR: lote no divisible → asegurar +%.1fR",p1_trig,m_nodiv_lock_r));
         else if(PartialClose(ticket,p1_lot)) GM_Log("GM_PosMgr","P1 40% @"+DoubleToString(p1_trig,1)+"R");
         else GM_Log("GM_PosMgr","P1 parcial falló — se continúa con BE (sin reintentar)");
         m_states[idx].p1_done=true;              // un solo intento: evita spam cada tick
         double spread=GM_GetSpread(m_symbol)*SymbolInfoDouble(m_symbol,SYMBOL_POINT);
         double off = (p1_lot>0) ? spread : MathMax(spread, sl_dist*m_nodiv_lock_r);
         double be_sl=(type==POSITION_TYPE_BUY)?open_p+off:open_p-off;
         if(ModifySL(ticket,be_sl)) m_states[idx].be_done=true;
      }
      
      // P2: 30% en 2R → SL a +1R
      if(!m_states[idx].p2_done && r>=2.0) {
         double close_lot=GM_PartialLot(m_symbol, PositionGetDouble(POSITION_VOLUME), 0.50);
         if(close_lot<=0) { m_states[idx].p2_done=true; GM_Log("GM_PosMgr","P2 @2R: lote no divisible → lock +1R"); }
         else if(PartialClose(ticket,close_lot)) GM_Log("GM_PosMgr","P2 @2R");
         else GM_Log("GM_PosMgr","P2 parcial falló — sólo lock +1R");
         m_states[idx].p2_done=true;
         double lock_sl=(type==POSITION_TYPE_BUY)?open_p+sl_dist:open_p-sl_dist;
         ModifySL(ticket,lock_sl);
      }
      
      // Trailing desde 2R (1.5 ATR, paso mín 0.25 ATR)
      if(m_states[idx].p2_done && r>=2.0 && m_atr>0) {
         double trail_sl;
         if(type==POSITION_TYPE_BUY) {
            trail_sl=price-m_atr*1.5;
            if(trail_sl>cur_sl+MathMax(m_atr*0.25,SymbolInfoDouble(m_symbol,SYMBOL_POINT)*20)) ModifySL(ticket,trail_sl);
         } else {
            trail_sl=price+m_atr*1.5;
            if(cur_sl<=0||trail_sl<cur_sl-MathMax(m_atr*0.25,SymbolInfoDouble(m_symbol,SYMBOL_POINT)*20)) ModifySL(ticket,trail_sl);
         }
      }
      
      // Trailing suave desde 1.5R si no hay parciales
      if(m_be_r>0 && !m_states[idx].p1_done && r>=1.5 && m_atr>0) {
         double trail_sl;
         if(type==POSITION_TYPE_BUY) {
            trail_sl=price-m_atr*1.5;
            if(trail_sl>cur_sl+SymbolInfoDouble(m_symbol,SYMBOL_POINT)*20) ModifySL(ticket,trail_sl);
         } else {
            trail_sl=price+m_atr*1.5;
            if(cur_sl<=0||trail_sl<cur_sl-SymbolInfoDouble(m_symbol,SYMBOL_POINT)*20) ModifySL(ticket,trail_sl);
         }
      }
   }
   
   bool ClosePosition(ulong ticket) {
      if(!PositionSelectByTicket(ticket)) return false;
      ENUM_POSITION_TYPE t=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double lot=PositionGetDouble(POSITION_VOLUME);
      double price=(t==POSITION_TYPE_BUY)?SymbolInfoDouble(m_symbol,SYMBOL_BID):SymbolInfoDouble(m_symbol,SYMBOL_ASK);
      MqlTradeRequest req={}; MqlTradeResult res={};
      req.action=TRADE_ACTION_DEAL; req.symbol=m_symbol; req.position=ticket;
      req.volume=lot; req.price=price;
      req.type=(t==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
      req.type_filling=GM_FillingMode(m_symbol); req.deviation=30; req.comment="GM_Close";
      return OrderSend(req,res);
   }
   
   void CloseAll() {
      for(int i=PositionsTotal()-1;i>=0;i--) {
         ulong ticket=PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetInteger(POSITION_MAGIC)==m_magic&&PositionGetString(POSITION_SYMBOL)==m_symbol)
            ClosePosition(ticket);
      }
   }
   
   int CountPositions() {
      int n=0;
      for(int i=0;i<PositionsTotal();i++) {
         ulong t=PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC)==m_magic&&PositionGetString(POSITION_SYMBOL)==m_symbol) n++;
      }
      return n;
   }
   
   double TotalPnL() {
      double total=0;
      for(int i=0;i<PositionsTotal();i++) {
         ulong t=PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC)==m_magic&&PositionGetString(POSITION_SYMBOL)==m_symbol)
            total+=PositionGetDouble(POSITION_PROFIT);
      }
      return total;
   }
};

#endif // GOLDMASTER_POSMGR_MQH
