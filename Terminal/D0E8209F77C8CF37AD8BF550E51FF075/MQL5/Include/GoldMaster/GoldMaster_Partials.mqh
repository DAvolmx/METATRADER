//+------------------------------------------------------------------+
//| GoldMaster_Partials.mqh                                          |
//| Sistema de cierres parciales escalonados: 1R / 2R / runner       |
//| Extraído y mejorado de SCALPER2_Piramide.mq5 + COPILOT_v4/v5    |
//|                                                                  |
//| Flujo:                                                           |
//|  1. En TP1 (1R): cierra Pct1 (default 50%), mueve SL a BE       |
//|  2. En TP2 (2R): cierra Pct2 (default 30%), deja Pct3 correr    |
//|  3. Runner (resto): trailing ATR dinámico (hereda de COPILOT_v5) |
//|                                                                  |
//| Uso:                                                             |
//|   CGMPartials p;                                                 |
//|   p.Init(magic, atr_handle, atr_mult_trail, pct1, pct2);        |
//|   p.Manage(); // llamar en cada barra nueva                      |
//+------------------------------------------------------------------+
#ifndef GOLDMASTER_PARTIALS_MQH
#define GOLDMASTER_PARTIALS_MQH

struct GMPartialState {
   ulong    ticket;
   double   entry;
   double   sl0;        // SL inicial en apertura
   double   tp1;        // precio TP1
   double   tp2;        // precio TP2
   bool     tp1_hit;
   bool     tp2_hit;
   bool     be_applied; // SL movido a breakeven
   int      dir;        // +1 BUY / -1 SELL
};

class CGMPartials {
private:
   int      m_magic;
   int      m_atr_handle;
   double   m_atr_trail_mult;   // multiplicador del trailing en el runner
   double   m_pct1;             // fracción a cerrar en TP1 (0.0-1.0)
   double   m_pct2;             // fracción a cerrar en TP2
   bool     m_enabled;
   int      m_max_positions;

   GMPartialState m_states[50];
   int            m_count;

   // ── helpers ──────────────────────────────────────────────────

   double _atr() {
      double buf[1];
      if(CopyBuffer(m_atr_handle, 0, 1, 1, buf) <= 0) return 0;
      return buf[0];
   }

   int _idx(ulong ticket) {
      for(int i=0; i<m_count; i++)
         if(m_states[i].ticket == ticket) return i;
      return -1;
   }

   bool _closePartial(ulong ticket, double fraction) {
      if(!PositionSelectByTicket(ticket)) return false;
      double vol   = PositionGetDouble(POSITION_VOLUME);
      double lot   = NormalizeDouble(vol * fraction, 2);
      double min_l = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      lot = MathFloor(lot / step) * step;
      if(lot < min_l) return false;           // demasiado pequeño
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action    = TRADE_ACTION_DEAL;
      req.symbol    = _Symbol;
      req.volume    = lot;
      req.type      = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
                      ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price     = (req.type==ORDER_TYPE_BUY)
                      ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                      : SymbolInfoDouble(_Symbol,SYMBOL_BID);
      req.deviation = 20;
      req.magic     = m_magic;
      req.position  = ticket;
      req.comment   = "GM_partial";
      return OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE;
   }

   bool _modifySL(ulong ticket, double new_sl) {
      if(!PositionSelectByTicket(ticket)) return false;
      double cur_sl = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);
      double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(MathAbs(new_sl - cur_sl) < point) return true; // sin cambio
      // validar que el nuevo SL sea mejor (más lejos del precio actual)
      double price  = PositionGetDouble(POSITION_PRICE_CURRENT);
      int    dir    = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ? 1 : -1;
      if(dir==1 && new_sl <= cur_sl) return false;  // BUY: nuevo SL debe ser mayor
      if(dir==-1 && new_sl >= cur_sl) return false; // SELL: nuevo SL debe ser menor
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action   = TRADE_ACTION_SLTP;
      req.symbol   = _Symbol;
      req.position = ticket;
      req.sl       = NormalizeDouble(new_sl, _Digits);
      req.tp       = tp;
      return OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE;
   }

public:
   CGMPartials() : m_magic(0), m_atr_handle(INVALID_HANDLE), m_atr_trail_mult(1.5),
                   m_pct1(0.50), m_pct2(0.30), m_enabled(true), m_count(0),
                   m_max_positions(50) {}

   void Init(int magic, int atr_handle, double atr_trail_mult=1.5,
             double pct1=0.50, double pct2=0.30, bool enabled=true) {
      m_magic          = magic;
      m_atr_handle     = atr_handle;
      m_atr_trail_mult = atr_trail_mult;
      m_pct1           = pct1;
      m_pct2           = pct2;
      m_enabled        = enabled;
   }

   // ── Registrar una nueva posición para seguimiento ──
   void Register(ulong ticket, double entry, double sl0, double tp1, double tp2, int dir) {
      if(_idx(ticket) >= 0) return;       // ya registrado
      if(m_count >= m_max_positions) return;
      int idx=m_count++;
      m_states[idx].ticket     = ticket;
      m_states[idx].entry      = entry;
      m_states[idx].sl0        = sl0;
      m_states[idx].tp1        = tp1;
      m_states[idx].tp2        = tp2;
      m_states[idx].tp1_hit    = false;
      m_states[idx].tp2_hit    = false;
      m_states[idx].be_applied = false;
      m_states[idx].dir        = dir;
   }

   // ── Llamar en cada barra nueva / tick ────────────────────────
   void Manage() {
      if(!m_enabled || m_count == 0) return;
      double atr = _atr();

      for(int i=m_count-1; i>=0; i--) {

         if(!PositionSelectByTicket(m_states[i].ticket)) {
            // posición cerrada — purgar
            for(int j=i; j<m_count-1; j++) m_states[j] = m_states[j+1];
            m_count--;
            continue;
         }
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double cur = (m_states[i].dir==1) ? bid : ask;

         // ── TP1: primer parcial (50%) + mover SL a BE ───────────
         if(!m_states[i].tp1_hit) {
            bool at_tp1 = (m_states[i].dir==1) ? (cur >= m_states[i].tp1) : (cur <= m_states[i].tp1);
            if(at_tp1) {
               if(_closePartial(m_states[i].ticket, m_pct1)) {
                  m_states[i].tp1_hit = true;
                  // SL a breakeven + 1 pip buffer
                  double be = m_states[i].entry + m_states[i].dir * SymbolInfoDouble(_Symbol,SYMBOL_POINT) * 2;
                  if(_modifySL(m_states[i].ticket, be)) m_states[i].be_applied = true;
               }
            }
         }

         // ── TP2: segundo parcial (30%) ────────────────────────────
         if(m_states[i].tp1_hit && !m_states[i].tp2_hit) {
            bool at_tp2 = (m_states[i].dir==1) ? (cur >= m_states[i].tp2) : (cur <= m_states[i].tp2);
            if(at_tp2) {
               double pct2_adj = m_pct2 / (1.0 - m_pct1); // ajustar al lote restante
               if(_closePartial(m_states[i].ticket, pct2_adj)) m_states[i].tp2_hit = true;
            }
         }

         // ── Runner: trailing ATR dinámico (hereda de COPILOT_v5) ─
         if(m_states[i].tp2_hit && atr > 0) {
            double trail_dist  = atr * m_atr_trail_mult;
            double new_sl      = cur - m_states[i].dir * trail_dist;
            // solo avanzar, nunca retroceder
            _modifySL(m_states[i].ticket, new_sl);
         }
      }
   }

   int Count() { return m_count; }
   bool IsTracking(ulong ticket) { return _idx(ticket) >= 0; }

   // Purgar estados de tickets ya inexistentes
   void Purge() {
      for(int i=m_count-1; i>=0; i--) {
         if(!PositionSelectByTicket(m_states[i].ticket)) {
            for(int j=i; j<m_count-1; j++) m_states[j] = m_states[j+1];
            m_count--;
         }
      }
   }

   string Summary() {
      return StringFormat("Partials: %d posiciones | pct1=%.0f%% pct2=%.0f%% trail=%.1f×ATR",
         m_count, m_pct1*100, m_pct2*100, m_atr_trail_mult);
   }
};

#endif
