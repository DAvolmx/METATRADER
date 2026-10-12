//+──────────────────────────────────────────────────────────────────────────+
//│      GOLD MASTER SYSTEM — Módulo de Órdenes Pendientes v3.0             │
//│  Buy Limit / Sell Limit / Buy Stop / Sell Stop programadas              │
//│  con gestión automática, expiración, cancelación y reentrada            │
//+──────────────────────────────────────────────────────────────────────────+
#ifndef GOLDMASTER_PENDING_MQH
#define GOLDMASTER_PENDING_MQH
#include "GoldMaster_Core.mqh"
#include "GoldMaster_SMC.mqh"

class CGoldMasterPending {
private:
   CTrade       m_trade;
   COrderInfo   m_order;
   string       m_symbol;
   int          m_magic;
   bool         m_verbose;

   bool SendPending(MqlTradeRequest &req,MqlTradeResult &res,double original_entry,double original_sl,double original_lot) {
      double step=SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_SIZE);
      int digits=(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS);
      bool buy=(req.type==ORDER_TYPE_BUY_LIMIT || req.type==ORDER_TYPE_BUY_STOP);
      ENUM_ORDER_TYPE side=buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      double old_loss=0,new_loss=0;
      if(step<=0 || original_lot<=0 || original_sl<=0 ||
         !OrderCalcProfit(side,m_symbol,original_lot,original_entry,original_sl,old_loss) || old_loss>=0) return false;
      req.price=NormalizeDouble(MathRound(req.price/step)*step,digits);
      req.sl=NormalizeDouble(MathRound(req.sl/step)*step,digits);
      req.tp=NormalizeDouble(MathRound(req.tp/step)*step,digits);
      if(req.price<=0 || req.sl<=0 || (buy && req.sl>=req.price) || (!buy && req.sl<=req.price)) return false;
      if(!OrderCalcProfit(side,m_symbol,original_lot,req.price,req.sl,new_loss) || new_loss>=0) return false;
      // If broker stop-distance adjustments enlarge the stop, reduce volume to preserve risk.
      req.volume=GM_NormalizeLot(m_symbol,original_lot*MathMin(1.0,MathAbs(old_loss/new_loss)));
      if(req.volume<=0) return false;
      req.type_filling=ORDER_FILLING_RETURN;
      MqlTradeCheckResult check={};
      if(!OrderCheck(req,check) || check.retcode!=0) { GM_Log("PENDING","OrderCheck: "+check.comment,m_verbose); return false; }
      return OrderSend(req,res) && (res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_PLACED);
   }

public:
   CGoldMasterPending(string symbol, int magic, bool verbose=true) {
      m_symbol  = symbol;
      m_magic   = magic;
      m_verbose = verbose;
      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints(20);
      m_trade.SetTypeFilling(GM_FillingMode(symbol));
   }

   //════════════════════════════════════════════════════════
   //  COLOCAR BUY LIMIT (entrada en zona de descuento/OB)
   //  Typical SMC: precio retrocede a OB/FVG → entrar largo
   //════════════════════════════════════════════════════════
   ulong PlaceBuyLimit(double entry, double sl, double tp1, double tp2=0,
                        double lot=0, string comment="GM_BuyLimit",
                        datetime expiry=0) {
      double original_entry=entry,original_sl=sl,original_lot=lot;
      if(lot<=0) { GM_Log("PENDING", "Orden omitida: lote 0 (riesgo/margen)", m_verbose); return 0; }
      if(entry >= SymbolInfoDouble(m_symbol, SYMBOL_ASK)) {
         GM_Log("PENDING", "BuyLimit ignorado: entry("+DoubleToString(entry,2)+") >= ask", m_verbose);
         return 0;
      }
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action    = TRADE_ACTION_PENDING;
      req.symbol    = m_symbol;
      req.type      = ORDER_TYPE_BUY_LIMIT;
      req.volume    = lot;
      req.price     = NormalizeDouble(entry, _Digits);
      req.sl        = NormalizeDouble(sl, _Digits);
      req.tp        = NormalizeDouble(tp1, _Digits);
      req.deviation = 20;
      req.magic     = m_magic;
      req.comment   = comment;
      if(expiry > 0) { req.type_time = ORDER_TIME_SPECIFIED; req.expiration = expiry; }
      else             req.type_time = ORDER_TIME_GTC;
      if(SendPending(req,res,original_entry,original_sl,original_lot)) {
         GM_Log("PENDING", StringFormat("✅ BUY LIMIT #%d @ %.2f | SL:%.2f TP:%.2f Lot:%.2f", res.order, entry, sl, tp1, lot), m_verbose);
         return res.order;
      }
      GM_Log("PENDING", StringFormat("❌ BuyLimit FAIL retcode:%d %s", res.retcode, res.comment), m_verbose);
      return 0;
   }

   //════════════════════════════════════════════════════════
   //  COLOCAR SELL LIMIT (entrada en zona premium/OB bajista)
   //════════════════════════════════════════════════════════
   ulong PlaceSellLimit(double entry, double sl, double tp1, double tp2=0,
                         double lot=0, string comment="GM_SellLimit",
                         datetime expiry=0) {
      double original_entry=entry,original_sl=sl,original_lot=lot;
      if(lot<=0) { GM_Log("PENDING", "Orden omitida: lote 0 (riesgo/margen)", m_verbose); return 0; }
      if(entry <= SymbolInfoDouble(m_symbol, SYMBOL_BID)) {
         GM_Log("PENDING", "SellLimit ignorado: entry <= bid", m_verbose);
         return 0;
      }
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action    = TRADE_ACTION_PENDING;
      req.symbol    = m_symbol;
      req.type      = ORDER_TYPE_SELL_LIMIT;
      req.volume    = lot;
      req.price     = NormalizeDouble(entry, _Digits);
      req.sl        = NormalizeDouble(sl, _Digits);
      req.tp        = NormalizeDouble(tp1, _Digits);
      req.deviation = 20;
      req.magic     = m_magic;
      req.comment   = comment;
      if(expiry > 0) { req.type_time = ORDER_TIME_SPECIFIED; req.expiration = expiry; }
      else             req.type_time = ORDER_TIME_GTC;
      if(SendPending(req,res,original_entry,original_sl,original_lot)) {
         GM_Log("PENDING", StringFormat("✅ SELL LIMIT #%d @ %.2f | SL:%.2f TP:%.2f Lot:%.2f", res.order, entry, sl, tp1, lot), m_verbose);
         return res.order;
      }
      GM_Log("PENDING", StringFormat("❌ SellLimit FAIL retcode:%d %s", res.retcode, res.comment), m_verbose);
      return 0;
   }

   //════════════════════════════════════════════════════════
   //  COLOCAR BUY STOP (breakout alcista)
   //════════════════════════════════════════════════════════
   ulong PlaceBuyStop(double entry, double sl, double tp1,
                       double lot=0, string comment="GM_BuyStop",
                       datetime expiry=0) {
      double original_entry=entry,original_sl=sl,original_lot=lot;
      if(lot<=0) { GM_Log("PENDING", "Orden omitida: lote 0 (riesgo/margen)", m_verbose); return 0; }
      double ask     = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double point   = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(point <= 0) point = 0.01;
      int    stops_l = (int)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double min_dist = (stops_l > 0 ? stops_l : 10) * point;

      // Protección: si el precio de mercado no está disponible (backtest init) usar entry tal cual
      if(ask <= 0) ask = entry;
      double rr0 = (tp1 > 0 && entry - sl > 0) ? (tp1 - entry) / (entry - sl) : 2.0;   // RR pedido

      // BuyStop entry debe estar SOBRE ask + mínima distancia
      if(entry < ask + min_dist)
         entry = NormalizeDouble(ask + min_dist + point, _Digits);

      // SL debe estar BAJO entry — si no, rechazar
      if(sl <= 0 || sl >= entry) {
         GM_Log("PENDING", StringFormat("BuyStop SL inválido (sl=%.2f entry=%.2f) — abortado", sl, entry), m_verbose);
         return 0;
      }
      double risk_dist = entry - sl;
      // SL y TP también deben respetar min_dist desde entry
      if(entry - sl < min_dist) sl = NormalizeDouble(entry - min_dist - point, _Digits);
      // Recalcular TP 2:1 RR
      tp1 = NormalizeDouble(entry + (entry - sl) * rr0, _Digits);
      GM_Log("PENDING", StringFormat("BuyStop params → entry:%.2f sl:%.2f tp:%.2f lot:%.2f", entry, sl, tp1, lot), m_verbose);
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action    = TRADE_ACTION_PENDING;
      req.symbol    = m_symbol;
      req.type      = ORDER_TYPE_BUY_STOP;
      req.volume    = lot;
      req.price     = NormalizeDouble(entry, _Digits);
      req.sl        = NormalizeDouble(sl, _Digits);
      req.tp        = NormalizeDouble(tp1, _Digits);
      req.deviation = 20;
      req.magic     = m_magic;
      req.comment   = comment;
      if(expiry > 0) { req.type_time = ORDER_TIME_SPECIFIED; req.expiration = expiry; }
      else             req.type_time = ORDER_TIME_GTC;
      if(SendPending(req,res,original_entry,original_sl,original_lot)) {
         GM_Log("PENDING", StringFormat("✅ BUY STOP #%d @ %.2f", res.order, entry), m_verbose);
         return res.order;
      }
      return 0;
   }

   //════════════════════════════════════════════════════════
   //  COLOCAR SELL STOP (breakout bajista)
   //════════════════════════════════════════════════════════
   ulong PlaceSellStop(double entry, double sl, double tp1,
                        double lot=0, string comment="GM_SellStop",
                        datetime expiry=0) {
      double original_entry=entry,original_sl=sl,original_lot=lot;
      if(lot<=0) { GM_Log("PENDING", "Orden omitida: lote 0 (riesgo/margen)", m_verbose); return 0; }
      double bid     = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double point   = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(point <= 0) point = 0.01;
      int    stops_l = (int)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double min_dist = (stops_l > 0 ? stops_l : 10) * point;

      // Protección: si el precio de mercado no está disponible (backtest init) usar entry tal cual
      if(bid <= 0) bid = entry;
      double rr0 = (tp1 > 0 && sl - entry > 0) ? (entry - tp1) / (sl - entry) : 2.0;   // RR pedido

      // SellStop entry debe estar BAJO bid - mínima distancia
      if(entry > bid - min_dist)
         entry = NormalizeDouble(bid - min_dist - point, _Digits);

      // Sanidad: entry debe ser positivo
      if(entry <= 0) {
         GM_Log("PENDING", StringFormat("SellStop entry inválida (%.2f) — abortado", entry), m_verbose);
         return 0;
      }
      // SL debe estar SOBRE entry
      if(sl <= 0 || sl <= entry) {
         GM_Log("PENDING", StringFormat("SellStop SL inválido (sl=%.2f entry=%.2f) — abortado", sl, entry), m_verbose);
         return 0;
      }
      double risk_dist = sl - entry;
      // SL también debe respetar min_dist desde entry
      if(sl - entry < min_dist) sl = NormalizeDouble(entry + min_dist + point, _Digits);
      // Recalcular TP 2:1 RR
      tp1 = NormalizeDouble(entry - (sl - entry) * rr0, _Digits);
      // Sanidad TP: no puede ser negativo
      if(tp1 <= 0) tp1 = NormalizeDouble(entry - min_dist * 2.0, _Digits);
      GM_Log("PENDING", StringFormat("SellStop params → entry:%.2f sl:%.2f tp:%.2f lot:%.2f", entry, sl, tp1, lot), m_verbose);
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action    = TRADE_ACTION_PENDING;
      req.symbol    = m_symbol;
      req.type      = ORDER_TYPE_SELL_STOP;
      req.volume    = lot;
      req.price     = NormalizeDouble(entry, _Digits);
      req.sl        = NormalizeDouble(sl, _Digits);
      req.tp        = NormalizeDouble(tp1, _Digits);
      req.deviation = 20;
      req.magic     = m_magic;
      req.comment   = comment;
      if(expiry > 0) { req.type_time = ORDER_TIME_SPECIFIED; req.expiration = expiry; }
      else             req.type_time = ORDER_TIME_GTC;
      if(SendPending(req,res,original_entry,original_sl,original_lot)) {
         GM_Log("PENDING", StringFormat("✅ SELL STOP #%d @ %.2f", res.order, entry), m_verbose);
         return res.order;
      }
      return 0;
   }

   //════════════════════════════════════════════════════════
   //  CANCELAR ORDEN PENDIENTE POR TICKET
   //════════════════════════════════════════════════════════
   bool CancelOrder(ulong ticket) {
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action = TRADE_ACTION_REMOVE;
      req.order  = ticket;
      if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) {
         GM_Log("PENDING", StringFormat("🗑 Orden #%d cancelada", ticket), m_verbose);
         return true;
      }
      return false;
   }

   //════════════════════════════════════════════════════════
   //  CANCELAR TODAS LAS ÓRDENES PENDIENTES DEL MAGIC
   //════════════════════════════════════════════════════════
   int CancelAllPending() {
      int cancelled = 0;
      for(int i = OrdersTotal()-1; i >= 0; i--) {
         ulong ticket = OrderGetTicket(i);
         if(!OrderSelect(ticket)) continue;
         if(OrderGetString(ORDER_SYMBOL) != m_symbol) continue;
         if((int)OrderGetInteger(ORDER_MAGIC) != m_magic) continue;
         if(CancelOrder(ticket)) cancelled++;
      }
      if(cancelled>0) GM_Log("PENDING", StringFormat("🗑 Canceladas %d órdenes pendientes", cancelled), m_verbose);
      return cancelled;
   }

   //════════════════════════════════════════════════════════
   //  CONTAR ÓRDENES PENDIENTES ACTIVAS
   //════════════════════════════════════════════════════════
   int CountPending() {
      int cnt = 0;
      for(int i = OrdersTotal()-1; i >= 0; i--) {
         ulong ticket = OrderGetTicket(i);
         if(!OrderSelect(ticket)) continue;
         if(OrderGetString(ORDER_SYMBOL) == m_symbol &&
            (int)OrderGetInteger(ORDER_MAGIC) == m_magic) cnt++;
      }
      return cnt;
   }

   //════════════════════════════════════════════════════════
   //  SETUP AUTOMÁTICO: OB Entry (Buy Limit en OB alcista)
   //  Coloca BL en 50% del OB con SL bajo el OB y TP en próxima liquidez
   //════════════════════════════════════════════════════════
   ulong PlaceOBBuyLimit(GMOB &ob, double tp_target, double risk_pct=1.5,
                          int candles_expiry=20, string comment="GM_OB_BL") {
      double entry   = (ob.top + ob.bottom) / 2.0;  // 50% del OB
      double sl      = ob.bottom - (ob.top - ob.bottom) * 0.1; // 10% bajo OB
      double sl_dist = entry - sl;
      if(sl_dist <= 0) return 0;
      double lot = GM_CalcLot(m_symbol, risk_pct, sl_dist);
      datetime expiry = TimeCurrent() + candles_expiry * PeriodSeconds(_Period);
      return PlaceBuyLimit(entry, sl, tp_target, 0, lot, comment, expiry);
   }

   ulong PlaceOBSellLimit(GMOB &ob, double tp_target, double risk_pct=1.5,
                           int candles_expiry=20, string comment="GM_OB_SL") {
      double entry   = (ob.top + ob.bottom) / 2.0;
      double sl      = ob.top  + (ob.top - ob.bottom) * 0.1;
      double sl_dist = sl - entry;
      if(sl_dist <= 0) return 0;
      double lot = GM_CalcLot(m_symbol, risk_pct, sl_dist);
      datetime expiry = TimeCurrent() + candles_expiry * PeriodSeconds(_Period);
      return PlaceSellLimit(entry, sl, tp_target, 0, lot, comment, expiry);
   }

   //════════════════════════════════════════════════════════
   //  SETUP FVG Entry (Buy Limit al 50% del FVG)
   //════════════════════════════════════════════════════════
   ulong PlaceFVGBuyLimit(GMFVG &fvg, double tp_target, double risk_pct=1.5,
                           int candles_expiry=15, string comment="GM_FVG_BL") {
      double entry   = (fvg.top + fvg.bottom) / 2.0;
      double sl      = fvg.bottom - (fvg.top - fvg.bottom) * 0.5;
      double sl_dist = entry - sl;
      if(sl_dist <= 0) return 0;
      double lot = GM_CalcLot(m_symbol, risk_pct, sl_dist);
      datetime expiry = TimeCurrent() + candles_expiry * PeriodSeconds(_Period);
      return PlaceBuyLimit(entry, sl, tp_target, 0, lot, comment, expiry);
   }

   ulong PlaceFVGSellLimit(GMFVG &fvg, double tp_target, double risk_pct=1.5,
                            int candles_expiry=15, string comment="GM_FVG_SL") {
      double entry   = (fvg.top + fvg.bottom) / 2.0;
      double sl      = fvg.top  + (fvg.top - fvg.bottom) * 0.5;
      double sl_dist = sl - entry;
      if(sl_dist <= 0) return 0;
      double lot = GM_CalcLot(m_symbol, risk_pct, sl_dist);
      datetime expiry = TimeCurrent() + candles_expiry * PeriodSeconds(_Period);
      return PlaceSellLimit(entry, sl, tp_target, 0, lot, comment, expiry);
   }

   //════════════════════════════════════════════════════════
   //  SETUP ORB: Buy Stop en high + x*ATR, Sell Stop en low - x*ATR
   //  Para el Open Range Breakout de la sesión
   //════════════════════════════════════════════════════════
   void PlaceORBOrders(double range_high, double range_low, double atr,
                        double risk_pct=1.5, double atr_buffer=0.2,
                        string comment="GM_ORB", double rr=2.0, bool sl_mid=false,
                        double sl_pad_atr=0.5, bool allow_buy=true, bool allow_sell=true, double fixed_risk_cash=0.0) {
      double point   = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(point <= 0) point = 0.01;
      int    stops_l = (int)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double min_dist = MathMax((stops_l > 0 ? stops_l : 10), 20) * point;
      double range    = range_high - range_low;

      // ─── BUY STOP ───
      double buy_entry  = range_high + atr * atr_buffer;
      // SL debe estar min_dist debajo de buy_entry (no solo range_low)
      double mid_rng    = (range_high + range_low) / 2.0;
      double buy_sl_raw = (sl_mid ? mid_rng : range_low) - atr * sl_pad_atr;
      double buy_sl     = MathMin(buy_sl_raw, buy_entry - min_dist - point);
      double buy_tp     = buy_entry + (buy_entry - buy_sl) * rr;
      double lot_b      = GM_CalcLot(m_symbol, risk_pct, buy_entry - buy_sl, fixed_risk_cash);

      // ─── SELL STOP ───
      double sell_entry_raw = range_low - atr * atr_buffer;
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      if(bid <= 0) bid = (ask > 0 ? ask : range_low);
      // SellStop entry debe estar bajo bid - min_dist
      double sell_entry = sell_entry_raw;
      if(sell_entry > bid - min_dist)
         sell_entry = NormalizeDouble(bid - min_dist - point, _Digits);
      // SL debe estar min_dist sobre sell_entry
      double sell_sl_raw = (sl_mid ? mid_rng : range_high) + atr * sl_pad_atr;
      double sell_sl     = MathMax(sell_sl_raw, sell_entry + min_dist + point);
      double sell_tp     = sell_entry - (sell_sl - sell_entry) * rr;
      if(sell_tp <= 0) sell_tp = NormalizeDouble(sell_entry - min_dist * 2.0, _Digits);
      double lot_s = GM_CalcLot(m_symbol, risk_pct, sell_sl - sell_entry, fixed_risk_cash);

      // Expiran al final del día
      MqlDateTime eod;
      TimeToStruct(TimeCurrent(), eod);
      eod.hour=21; eod.min=0; eod.sec=0;
      datetime expiry = StructToTime(eod);

      GM_Log("PENDING", StringFormat("ORB → BS entry:%.2f sl:%.2f tp:%.2f | SS entry:%.2f sl:%.2f tp:%.2f",
             buy_entry, buy_sl, buy_tp, sell_entry, sell_sl, sell_tp), m_verbose);
      if(allow_buy)  PlaceBuyStop (buy_entry,  buy_sl,  buy_tp,  lot_b, comment+"_BUY",  expiry);
      if(allow_sell) PlaceSellStop(sell_entry, sell_sl, sell_tp, lot_s, comment+"_SELL", expiry);
   }

   //════════════════════════════════════════════════════════
   //  MODIFICAR ORDEN PENDIENTE (cambiar precio / SL / TP)
   //════════════════════════════════════════════════════════
   bool ModifyOrder(ulong ticket, double new_price, double new_sl=0, double new_tp=0) {
      if(!OrderSelect(ticket)) return false;
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action = TRADE_ACTION_MODIFY;
      req.order  = ticket;
      req.price  = NormalizeDouble(new_price, _Digits);
      req.sl     = (new_sl  > 0) ? NormalizeDouble(new_sl,  _Digits) : OrderGetDouble(ORDER_SL);
      req.tp     = (new_tp  > 0) ? NormalizeDouble(new_tp,  _Digits) : OrderGetDouble(ORDER_TP);
      req.type_time  = (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
      req.expiration = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) {
         GM_Log("PENDING", StringFormat("✏️ Orden #%d modificada → precio:%.2f", ticket, new_price), m_verbose);
         return true;
      }
      return false;
   }
};

#endif
