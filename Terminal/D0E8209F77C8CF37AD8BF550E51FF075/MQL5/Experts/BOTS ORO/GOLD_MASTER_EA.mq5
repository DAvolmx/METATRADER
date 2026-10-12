//+──────────────────────────────────────────────────────────────────────────+
//│              GOLD MASTER EA  v2.0 — David Domez                         │
//│  Combina lo mejor de: ORO3/ORO4 (SMC+EMA200) + TALOS (agresivo)         │
//│  + Scalper (multi-posición) + Filtro DXY + Gestión avanzada             │
//│                                                                          │
//│  Broker: Deriv · Símbolos: XAUUSD / XAUUSDm                            │
//│  Timeframes recomendados: M5, M15                                        │
//+──────────────────────────────────────────────────────────────────────────+
#property copyright "Gold Master System — David Domez"
#property version   "2.00"
#property description "EA SMC + DXY + Scalping + Day Trade para XAUUSD/Deriv"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
CTrade         trade;
CPositionInfo  posInfo;

//════════════════════════════════════════════════════════
//  PARÁMETROS DE ENTRADA
//════════════════════════════════════════════════════════

//─── Modo de operación
input group "═══ MODO DE OPERACIÓN ═══"
input bool   InpScalpMode     = true;     // Scalping (M1-M15)
input bool   InpDayTradeMode  = true;     // Day Trade (H1-H4)
input bool   InpSemiAuto      = true;     // Semi-auto: sigue señales del Python dashboard
input int    InpMaxPositions  = 3;        // Posiciones simultáneas máximas

//─── Riesgo
input group "═══ GESTIÓN DE RIESGO ═══"
input double InpRiskPct        = 1.5;    // Riesgo por operación (%)
input double InpATR_SL_Mult    = 2.0;    // Multiplicador ATR para SL
input double InpTP_RR          = 2.5;    // Ratio TP/SL (RR)
input double InpMaxDrawdownPct = 5.0;    // DD máximo diario (% balance inicial)

//─── Protección escalonada (de ORO3/ORO4)
input group "═══ PROTECCIÓN CAPITAL ═══"
input double InpParcial1_R     = 1.0;    // Primer parcial en 1R
input double InpParcial1_Pct   = 40.0;   // % del lote a cerrar en P1
input double InpParcial2_R     = 2.0;    // Segundo parcial en 2R
input double InpParcial2_Pct   = 30.0;   // % del lote a cerrar en P2
input bool   InpBE_en_P1       = true;   // SL a BE al tocar P1
input bool   InpLock_en_P2     = true;   // SL a +1R al tocar P2
input double InpTrailStartR    = 2.0;    // Trailing arranca en X*R
input double InpTrailATRMult   = 1.0;    // Trailing distancia en ATR

//─── EMAs
input group "═══ EMAs ═══"
input int    InpEMA_Fast   = 5;          // EMA Rápida  (scalp)
input int    InpEMA_Mid    = 13;         // EMA Media   (scalp)
input int    InpEMA_Slow   = 50;         // EMA Lenta   (trend)
input int    InpEMA_Filter = 200;        // EMA Filtro  (sesgo)
input double InpContraTendFactor = 0.5; // Factor riesgo contra EMA200

//─── DXY
input group "═══ FILTRO DXY ═══"
input bool   InpUseDXY        = true;    // Activar filtro DXY
input string InpDXYSymbol     = "DX-Y.NYB"; // Símbolo DXY en tu broker
input int    InpDXY_EMA       = 20;     // Periodo EMA del DXY
input int    InpDXY_LookBack  = 5;      // Barras de comparación DXY

//─── Sesiones
input group "═══ SESIONES ═══"
input bool   InpTokyo         = false;   // Operar sesión Tokio
input bool   InpLondres       = true;    // Operar sesión Londres
input bool   InpNY            = true;    // Operar sesión Nueva York
input bool   InpOverlap       = true;    // Operar overlap Lon/NY

//─── ATR y filtros
input group "═══ FILTROS ═══"
input int    InpATR_Period    = 14;      // Periodo ATR
input double InpMinATR_Pips   = 0.30;   // ATR mínimo (filtro lateralidad)
input int    InpMaxSpread      = 35;    // Spread máximo en puntos
input int    InpSlippage       = 20;    // Slippage máximo en puntos

//─── Magic y comentario
input group "═══ IDENTIFICACIÓN ═══"
input ulong  InpMagic         = 888888;
input string InpComment       = "GoldMasterEA";
input bool   InpVerboseLog    = true;   // Log detallado

//════════════════════════════════════════════════════════
//  HANDLES DE INDICADORES
//════════════════════════════════════════════════════════
int h_ATR, h_EMA_Fast, h_EMA_Mid, h_EMA_Slow, h_EMA_Filter;
int h_ATR_DXY, h_EMA_DXY;

//════════════════════════════════════════════════════════
//  ESTADO GLOBAL
//════════════════════════════════════════════════════════
datetime g_LastBar   = 0;
double   g_DayStartBalance = 0;

// Para gestión de parciales por ticket
struct TradeState {
    ulong  ticket;
    double origVolume;
    double riskDist;     // 1R en precio
    double openPrice;
    bool   p1_done;
    bool   p2_done;
    bool   trail_on;
};
TradeState g_Trades[10];
int g_TradeCount = 0;

//════════════════════════════════════════════════════════
//  INIT
//════════════════════════════════════════════════════════
int OnInit()
  {
   if(StringFind(StringToLower(_Symbol),"xau") < 0)
      Print("⚠️ Símbolo no es XAU — verificar");

   h_ATR        = iATR(_Symbol, _Period, InpATR_Period);
   h_EMA_Fast   = iMA(_Symbol, _Period, InpEMA_Fast,   0, MODE_EMA, PRICE_CLOSE);
   h_EMA_Mid    = iMA(_Symbol, _Period, InpEMA_Mid,    0, MODE_EMA, PRICE_CLOSE);
   h_EMA_Slow   = iMA(_Symbol, _Period, InpEMA_Slow,   0, MODE_EMA, PRICE_CLOSE);
   h_EMA_Filter = iMA(_Symbol, _Period, InpEMA_Filter, 0, MODE_EMA, PRICE_CLOSE);

   if(h_ATR==INVALID_HANDLE || h_EMA_Fast==INVALID_HANDLE ||
      h_EMA_Mid==INVALID_HANDLE || h_EMA_Slow==INVALID_HANDLE || h_EMA_Filter==INVALID_HANDLE)
     { Print("❌ Error handles indicadores"); return INIT_FAILED; }

   if(InpUseDXY)
     {
      h_EMA_DXY = iMA(InpDXYSymbol, _Period, InpDXY_EMA, 0, MODE_EMA, PRICE_CLOSE);
      if(h_EMA_DXY == INVALID_HANDLE)
         Print("⚠️ DXY no disponible en este broker — filtro DXY desactivado");
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   ArrayInitialize(g_Trades, TradeState());
   g_TradeCount = 0;

   Print("✅ GOLD MASTER EA v2.0 iniciado │ ", _Symbol, " │ TF:", EnumToString(_Period));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(h_ATR);  IndicatorRelease(h_EMA_Fast);
   IndicatorRelease(h_EMA_Mid); IndicatorRelease(h_EMA_Slow);
   IndicatorRelease(h_EMA_Filter);
   if(InpUseDXY) IndicatorRelease(h_EMA_DXY);
   Print("🛑 GOLD MASTER EA detenido");
  }

//════════════════════════════════════════════════════════
//  TICK PRINCIPAL
//════════════════════════════════════════════════════════
void OnTick()
  {
   // ─ 1. Control diario de drawdown
   double currBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double ddPct = (g_DayStartBalance - currBalance) / g_DayStartBalance * 100.0;
   if(ddPct > InpMaxDrawdownPct)
     {
      if(InpVerboseLog) Print("⛔ Drawdown máximo alcanzado: ", ddPct, "% → EA pausado");
      return;
     }

   // ─ 2. Gestionar posiciones abiertas
   GestionarPosiciones();

   // ─ 3. Solo buscar nuevas entradas en vela nueva
   datetime curBar = iTime(_Symbol, _Period, 0);
   if(curBar == g_LastBar) return;
   g_LastBar = curBar;

   // ─ 4. Verificar sesión
   if(!SesionActiva()) return;

   // ─ 5. Verificar spread
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpread)
     {
      if(InpVerboseLog) Print("⚠️ Spread alto: ", spread, " pts");
      return;
     }

   // ─ 6. Verificar posiciones máximas
   if(ContarMisPosiciones() >= InpMaxPositions) return;

   // ─ 7. Obtener datos de indicadores
   double atr[1], ema_fast[2], ema_mid[2], ema_slow[2], ema_filter[2];
   if(CopyBuffer(h_ATR,        0, 1, 1, atr)       < 1) return;
   if(CopyBuffer(h_EMA_Fast,   0, 1, 2, ema_fast)  < 1) return;
   if(CopyBuffer(h_EMA_Mid,    0, 1, 2, ema_mid)   < 1) return;
   if(CopyBuffer(h_EMA_Slow,   0, 1, 2, ema_slow)  < 1) return;
   if(CopyBuffer(h_EMA_Filter, 0, 1, 2, ema_filter)< 1) return;
   if(atr[0] == 0) return;

   // ─ 8. Filtro de volatilidad mínima
   if(atr[0] < InpMinATR_Pips) { if(InpVerboseLog) Print("📉 Volatilidad baja"); return; }

   // ─ 9. Señal base: cruce EMA
   int signal = 0;  // 1=BUY -1=SELL
   // Scalping: EMA5 x EMA13 confirmado por EMA50
   if(InpScalpMode)
     {
      if(ema_fast[0] > ema_mid[0] && ema_fast[1] <= ema_mid[1] && ema_fast[0] > ema_slow[0])
         signal = 1;
      else if(ema_fast[0] < ema_mid[0] && ema_fast[1] >= ema_mid[1] && ema_fast[0] < ema_slow[0])
         signal = -1;
     }
   // Day trade: solo si hay sesgo EMA200
   if(InpDayTradeMode && signal == 0)
     {
      double price = iClose(_Symbol, _Period, 1);
      if(price > ema_filter[0] && ema_fast[0] > ema_slow[0]) signal = 1;
      if(price < ema_filter[0] && ema_fast[0] < ema_slow[0]) signal = -1;
     }

   if(signal == 0) return;

   // ─ 10. Filtro EMA200 (sesgo)
   double factor = 1.0;
   double price_cur = iClose(_Symbol, _Period, 1);
   if(signal == 1  && price_cur < ema_filter[0]) factor = InpContraTendFactor;
   if(signal == -1 && price_cur > ema_filter[0]) factor = InpContraTendFactor;
   if(factor == 0) { if(InpVerboseLog) Print("🚫 Contra tendencia EMA200 bloqueado"); return; }

   // ─ 11. Filtro DXY
   if(InpUseDXY && h_EMA_DXY != INVALID_HANDLE)
     {
      double dxy_ema[2];
      if(CopyBuffer(h_EMA_DXY, 0, 0, 2, dxy_ema) == 2)
        {
         bool dxy_up = dxy_ema[0] > dxy_ema[1];
         // DXY sube → oro baja (correlación inversa)
         if(dxy_up && signal == 1)
           { if(InpVerboseLog) Print("🚫 DXY ↑ cancela BUY oro"); return; }
         if(!dxy_up && signal == -1)
           { if(InpVerboseLog) Print("🚫 DXY ↓ cancela SELL oro"); return; }
        }
     }

   // ─ 12. Calcular SL/TP y lote
   double sl_dist = atr[0] * InpATR_SL_Mult;
   double tp_dist = sl_dist * InpTP_RR;
   double lot     = CalcularLote(sl_dist, factor);
   if(lot <= 0) { Print("❌ Lote 0 — sin margen"); return; }

   // ─ 13. Ejecutar orden
   if(signal == 1)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - sl_dist, _Digits);
      double tp  = NormalizeDouble(ask + tp_dist, _Digits);
      if(trade.Buy(lot, _Symbol, ask, sl, tp, InpComment + "_BUY"))
        {
         RegistrarPosicion(trade.ResultOrder(), lot, sl_dist, ask);
         Print("📈 BUY │ Lote:", lot, " │ SL:", sl, " │ TP:", tp, " │ ATR:", atr[0]);
        }
     }
   else if(signal == -1)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + sl_dist, _Digits);
      double tp  = NormalizeDouble(bid - tp_dist, _Digits);
      if(trade.Sell(lot, _Symbol, bid, sl, tp, InpComment + "_SELL"))
        {
         RegistrarPosicion(trade.ResultOrder(), lot, sl_dist, bid);
         Print("📉 SELL│ Lote:", lot, " │ SL:", sl, " │ TP:", tp, " │ ATR:", atr[0]);
        }
     }
  }

//════════════════════════════════════════════════════════
//  GESTIÓN DE POSICIONES (parciales + trailing)
//════════════════════════════════════════════════════════
void GestionarPosiciones()
  {
   for(int i = 0; i < g_TradeCount; i++)
     {
      TradeState &ts = g_Trades[i];
      if(!posInfo.SelectByTicket(ts.ticket)) continue;
      if(posInfo.Magic() != InpMagic) continue;

      double price_cur = (posInfo.PositionType() == POSITION_TYPE_BUY)
                         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double open_p    = ts.openPrice;
      double R         = ts.riskDist;
      bool   is_buy    = (posInfo.PositionType() == POSITION_TYPE_BUY);

      double profit_R  = is_buy  ? (price_cur - open_p) / R
                                 : (open_p - price_cur) / R;

      // Parcial 1
      if(!ts.p1_done && profit_R >= InpParcial1_R)
        {
         double vol_close = NormalizeVolume(ts.origVolume * InpParcial1_Pct / 100.0);
         if(vol_close > 0 && trade.PositionClosePartial(ts.ticket, vol_close))
           {
            ts.p1_done = true;
            if(InpBE_en_P1)
              {
               double new_sl = NormalizeDouble(open_p + (is_buy ? _Point : -_Point) * 2, _Digits);
               trade.PositionModify(ts.ticket, new_sl, posInfo.TakeProfit());
              }
            Print("🔶 P1 cerrado │ Ticket:", ts.ticket, " │ Vol:", vol_close);
           }
        }

      // Parcial 2
      if(ts.p1_done && !ts.p2_done && profit_R >= InpParcial2_R)
        {
         double vol_close = NormalizeVolume(ts.origVolume * InpParcial2_Pct / 100.0);
         if(vol_close > 0 && trade.PositionClosePartial(ts.ticket, vol_close))
           {
            ts.p2_done = true;
            if(InpLock_en_P2)
              {
               double lock_sl = is_buy ? open_p + R : open_p - R;
               lock_sl = NormalizeDouble(lock_sl, _Digits);
               trade.PositionModify(ts.ticket, lock_sl, posInfo.TakeProfit());
              }
            Print("🔷 P2 cerrado │ Ticket:", ts.ticket, " │ Vol:", vol_close);
           }
        }

      // Trailing stop agresivo
      if(ts.p2_done && profit_R >= InpTrailStartR)
        {
         double atr_buf[1];
         if(CopyBuffer(h_ATR, 0, 0, 1, atr_buf) < 1) continue;
         double trail_dist = atr_buf[0] * InpTrailATRMult;
         double new_sl, cur_sl = posInfo.StopLoss();

         if(is_buy)
           {
            new_sl = NormalizeDouble(price_cur - trail_dist, _Digits);
            if(new_sl > cur_sl && new_sl > open_p)
               trade.PositionModify(ts.ticket, new_sl, posInfo.TakeProfit());
           }
         else
           {
            new_sl = NormalizeDouble(price_cur + trail_dist, _Digits);
            if(new_sl < cur_sl && new_sl < open_p)
               trade.PositionModify(ts.ticket, new_sl, posInfo.TakeProfit());
           }
        }
     }
  }

//════════════════════════════════════════════════════════
//  FUNCIONES AUXILIARES
//════════════════════════════════════════════════════════

double CalcularLote(double sl_dist, double risk_factor = 1.0)
  {
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_money= balance * InpRiskPct / 100.0 * risk_factor;
   double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot_raw   = risk_money / (sl_dist / tick_size * tick_val);
   double lot_min   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot_max   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lot       = MathFloor(lot_raw / lot_step) * lot_step;
   lot = MathMax(lot_min, MathMin(lot_max, lot));
   // Verificar margen
   double margin_req = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot,
                      SymbolInfoDouble(_Symbol, SYMBOL_ASK), margin_req))
     {
      double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(margin_req > free_margin * 0.8) lot = lot_min;
     }
   return lot;
  }

double NormalizeVolume(double vol)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   vol = MathFloor(vol / step) * step;
   return MathMax(minv, MathMin(maxv, vol));
  }

void RegistrarPosicion(ulong ticket, double vol, double sl_dist, double open_price)
  {
   if(g_TradeCount >= ArraySize(g_Trades)) return;
   g_Trades[g_TradeCount].ticket     = ticket;
   g_Trades[g_TradeCount].origVolume = vol;
   g_Trades[g_TradeCount].riskDist   = sl_dist;
   g_Trades[g_TradeCount].openPrice  = open_price;
   g_Trades[g_TradeCount].p1_done    = false;
   g_Trades[g_TradeCount].p2_done    = false;
   g_Trades[g_TradeCount].trail_on   = false;
   g_TradeCount++;
  }

int ContarMisPosiciones()
  {
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i) && posInfo.Magic() == InpMagic &&
         posInfo.Symbol() == _Symbol) cnt++;
     }
   return cnt;
  }

bool SesionActiva()
  {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;
   if(InpTokyo   && h >= 0  && h < 7)  return true;
   if(InpLondres && h >= 8  && h < 12) return true;
   if(InpOverlap && h >= 12 && h < 16) return true;
   if(InpNY      && h >= 16 && h < 21) return true;
   return false;
  }
//+──────────────────────────────────────────────────────────────────────────+
