//+------------------------------------------------------------------+
//|                        Bot_Liquidez_UltraRapido_4H_15M.mq5       |
//|                    v3.1 - Optimizado por Backtest                |
//+------------------------------------------------------------------+
#property copyright "Estrategia Liquidez 4H/15M"
#property version   "3.10"
#property description "Ejecución Asíncrona + BE Inteligente + Trailing + Filtros"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

// --- PARÁMETROS DE ENTRADA ---
input group "=== Configuración de Operativa ==="
input double   InpLotSize        = 0.01;
input ulong    InpMagicNumber    = 999154;

input group "=== Stop Loss / Take Profit ==="
input bool     InpUsarATRStop    = true;        // SL/TP dinámicos por ATR
input int      InpATRPeriodo     = 14;
input double   InpATRMultiSL     = 1.2;         // ↓ Reducido de 1.5 → SL más cerca
input double   InpATRMultiTP     = 3.0;         // ↑ Subido de 2.5 → TP más ambicioso
input double   InpStopLossPips   = 80.0;        // Fallback SL fijo
input double   InpTakeProfitPips = 200.0;       // Fallback TP fijo

input group "=== Gestión de Break Even (MEJORADA) ==="
input bool     InpUsarBreakEven  = true;
input double   InpBreakEvenPips  = 40.0;        // BE se activa a 40 pips
input double   InpBreakEvenOffset= 15.0;        // ⭐ BE en +15 pips (NO en $0!) - Bloquea pérdidas
input bool     InpUsarTrailing   = true;        // ⭐ NUEVO: Trailing stop después del BE
input double   InpTrailingPips   = 30.0;        // Distancia del trailing
input double   InpTrailingStep   = 10.0;        // Paso mínimo para actualizar

input group "=== Filtro de Tendencia ==="
input bool     InpUsarFiltroTendencia = true;
input int      InpEmaRapida      = 50;
input int      InpEmaLenta       = 200;
input int      InpAdxPeriodo     = 14;
input double   InpAdxMinimo      = 22.0;        // ↑ Subido de 20 → solo tendencias fuertes
input bool     InpUsarEmaM15     = true;

input group "=== Filtros de Sesión / Volatilidad ==="
input bool     InpFiltrarSpread  = true;
input double   InpSpreadMaxPips  = 3.0;         // ↓ Bajado de 5 → calidad de ejecución
input bool     InpFiltrarHorario = true;
input int      InpHoraInicio     = 8;           // ↑ Evita apertura asiática
input int      InpHoraFin        = 20;

input group "=== Filtro Anti-Sobreoperación ==="
input int      InpMaxOpsDia      = 2;           // ⭐ NUEVO: Máx 2 operaciones/día
input int      InpCooldownMin    = 60;          // ⭐ NUEVO: 60 min entre operaciones

// --- VARIABLES GLOBALES ---
datetime last_bar_time;
ENUM_ORDER_TYPE_FILLING g_filling_mode = ORDER_FILLING_FOK;
datetime g_ultima_operacion = 0;
int g_ops_hoy = 0;
datetime g_dia_actual = 0;

int h_ema_fast_h4 = INVALID_HANDLE;
int h_ema_slow_h4 = INVALID_HANDLE;
int h_adx_h4      = INVALID_HANDLE;
int h_atr_h4      = INVALID_HANDLE;
int h_ema_m15     = INVALID_HANDLE;

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectarFillingMode()
  {
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(15);
   last_bar_time = 0;
   g_filling_mode = DetectarFillingMode();

   h_ema_fast_h4 = iMA(_Symbol, PERIOD_H4, InpEmaRapida, 0, MODE_EMA, PRICE_CLOSE);
   h_ema_slow_h4 = iMA(_Symbol, PERIOD_H4, InpEmaLenta,  0, MODE_EMA, PRICE_CLOSE);
   h_adx_h4      = iADX(_Symbol, PERIOD_H4, InpAdxPeriodo);
   h_atr_h4      = iATR(_Symbol, PERIOD_H4, InpATRPeriodo);
   h_ema_m15     = iMA(_Symbol, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);

   if(h_ema_fast_h4 == INVALID_HANDLE || h_ema_slow_h4 == INVALID_HANDLE ||
      h_adx_h4 == INVALID_HANDLE || h_atr_h4 == INVALID_HANDLE || h_ema_m15 == INVALID_HANDLE)
     {
      Print(">>> ERROR: Handles de indicadores inválidos");
      return(INIT_FAILED);
     }

   Print(">>> Bot v3.1 Inicializado | Filling: ", EnumToString(g_filling_mode));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(h_ema_fast_h4 != INVALID_HANDLE) IndicatorRelease(h_ema_fast_h4);
   if(h_ema_slow_h4 != INVALID_HANDLE) IndicatorRelease(h_ema_slow_h4);
   if(h_adx_h4      != INVALID_HANDLE) IndicatorRelease(h_adx_h4);
   if(h_atr_h4      != INVALID_HANDLE) IndicatorRelease(h_atr_h4);
   if(h_ema_m15     != INVALID_HANDLE) IndicatorRelease(h_ema_m15);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. GESTIÓN DINÁMICA (BE + Trailing)
   GestionarBreakEvenYTrailing();

   // 2. Reset diario de contadores
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime hoy = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   if(hoy != g_dia_actual)
     {
      g_dia_actual = hoy;
      g_ops_hoy = 0;
     }

   // 3. Solo evaluar al cierre de vela M15
   datetime current_bar_time = iTime(_Symbol, PERIOD_M15, 0);
   if(current_bar_time == last_bar_time) return;
   last_bar_time = current_bar_time;

   // 4. Filtros previos
   if(!FiltrosOK()) return;
   if(TengoPosicionAbierta()) return;

   // 5. Anti-sobreoperación
   if(g_ops_hoy >= InpMaxOpsDia)
     {
      static datetime ultimo_log = 0;
      if(current_bar_time != ultimo_log)
        {
         Print(">>> Límite diario alcanzado (", InpMaxOpsDia, " ops). Esperando mañana.");
         ultimo_log = current_bar_time;
        }
      return;
     }
   if(g_ultima_operacion > 0 &&
      (TimeCurrent() - g_ultima_operacion) < (InpCooldownMin * 60))
      return;

   // 6. Niveles H4 y M15
   double h4_high  = iHigh(_Symbol, PERIOD_H4, 1);
   double h4_low   = iLow(_Symbol, PERIOD_H4, 1);
   double h4_close = iClose(_Symbol, PERIOD_H4, 1);

   double m15_low_prev  = iLow(_Symbol, PERIOD_M15, 1);
   double m15_high_prev = iHigh(_Symbol, PERIOD_M15, 1);
   double m15_close_cur = iClose(_Symbol, PERIOD_M15, 1);

   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pip_value = point * 10.0;

   // 7. Gatillos
   bool liquidez_abajo  = (m15_low_prev <= h4_close) && (m15_low_prev >= h4_low);
   bool gatillo_compra  = liquidez_abajo && (m15_close_cur > h4_close);

   bool liquidez_arriba = (m15_high_prev >= h4_close) && (m15_high_prev <= h4_high);
   bool gatillo_venta   = liquidez_arriba && (m15_close_cur < h4_close);

   // 8. Filtro de tendencia
   int tendencia = DetectarTendencia();
   if(InpUsarFiltroTendencia)
     {
      if(gatillo_compra && tendencia < 0) gatillo_compra = false;
      if(gatillo_venta  && tendencia > 0) gatillo_venta  = false;
     }

   // 9. SL/TP
   double sl_pips, tp_pips;
   if(InpUsarATRStop)
     {
      double atr = ObtenerATR_H4();
      if(atr <= 0) { sl_pips = InpStopLossPips; tp_pips = InpTakeProfitPips; }
      else
        {
         sl_pips = (atr * InpATRMultiSL) / pip_value;
         tp_pips = (atr * InpATRMultiTP) / pip_value;
        }
     }
   else
     {
      sl_pips = InpStopLossPips;
      tp_pips = InpTakeProfitPips;
     }

   // 10. Ejecutar
   if(gatillo_compra)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - (sl_pips * pip_value), _Digits);
      double tp  = NormalizeDouble(ask + (tp_pips * pip_value), _Digits);
      if(EnviarOrdenAsincrona(ORDER_TYPE_BUY, ask, sl, tp))
        { g_ultima_operacion = TimeCurrent(); g_ops_hoy++; }
     }
   else if(gatillo_venta)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + (sl_pips * pip_value), _Digits);
      double tp  = NormalizeDouble(bid - (tp_pips * pip_value), _Digits);
      if(EnviarOrdenAsincrona(ORDER_TYPE_SELL, bid, sl, tp))
        { g_ultima_operacion = TimeCurrent(); g_ops_hoy++; }
     }
  }

//+------------------------------------------------------------------+
bool FiltrosOK()
  {
   if(InpFiltrarSpread)
     {
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double pip_value = point * 10.0;
      long spread_points = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      double spread_pips = (spread_points * point) / pip_value;
      if(spread_pips > InpSpreadMaxPips) return false;
     }
   if(InpFiltrarHorario)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour < InpHoraInicio || dt.hour >= InpHoraFin) return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
int DetectarTendencia()
  {
   double ema_fast[2], ema_slow[2];
   if(CopyBuffer(h_ema_fast_h4, 0, 1, 2, ema_fast) < 2) return 0;
   if(CopyBuffer(h_ema_slow_h4, 0, 1, 2, ema_slow) < 2) return 0;

   bool ema_alcista = (ema_fast[0] > ema_slow[0]);
   bool ema_bajista = (ema_fast[0] < ema_slow[0]);

   double adx[1];
   if(CopyBuffer(h_adx_h4, 0, 1, 1, adx) < 1) return 0;
   bool adx_fuerte = (adx[0] >= InpAdxMinimo);

   double precio_h4 = iClose(_Symbol, PERIOD_H4, 1);
   bool precio_sobre = (precio_h4 > ema_slow[0]);
   bool precio_bajo  = (precio_h4 < ema_slow[0]);

   double ema_m15[1];
   bool m15_alcista = false, m15_bajista = false;
   if(InpUsarEmaM15 && CopyBuffer(h_ema_m15, 0, 1, 1, ema_m15) == 1)
     {
      double cierre_m15 = iClose(_Symbol, PERIOD_M15, 1);
      m15_alcista = (cierre_m15 > ema_m15[0]);
      m15_bajista = (cierre_m15 < ema_m15[0]);
     }

   bool alcista = ema_alcista && adx_fuerte && precio_sobre;
   bool bajista = ema_bajista && adx_fuerte && precio_bajo;
   if(InpUsarEmaM15)
     {
      alcista = alcista && m15_alcista;
      bajista = bajista && m15_bajista;
     }
   if(alcista) return 1;
   if(bajista) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
double ObtenerATR_H4()
  {
   double atr[1];
   if(CopyBuffer(h_atr_h4, 0, 1, 1, atr) < 1) return 0.0;
   return atr[0];
  }

//+------------------------------------------------------------------+
bool EnviarOrdenAsincrona(ENUM_ORDER_TYPE tipo_orden, double precio, double sl, double tp)
  {
   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};
   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = _Symbol;
   request.volume       = InpLotSize;
   request.type         = tipo_orden;
   request.price        = precio;
   request.sl           = sl;
   request.tp           = tp;
   request.deviation    = 15;
   request.type_filling = g_filling_mode;
   request.magic        = InpMagicNumber;
   request.comment      = "Gatillo 4H/15M v3.1";

   bool enviado = OrderSendAsync(request, result);
   if(enviado)
      Print(">>> Orden enviada | ", EnumToString(tipo_orden), " | @", precio,
            " | SL: ", sl, " | TP: ", tp);
   else
      Print(">>> Error orden | Code: ", GetLastError(),
            " | Retcode: ", result.retcode);
   return enviado;
  }

//+------------------------------------------------------------------+
//| GESTIÓN DE BREAK EVEN + TRAILING STOP                            |
//+------------------------------------------------------------------+
void GestionarBreakEvenYTrailing()
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pip_value = point * 10.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      long type    = PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);

      // ============ COMPRAS ============
      if(type == POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ganancia_pips = (bid - open) / pip_value;

         // 1. Break Even con OFFSET (bloquea +15 pips en lugar de $0)
         if(InpUsarBreakEven && ganancia_pips >= InpBreakEvenPips)
           {
            double be_price = NormalizeDouble(open + (InpBreakEvenOffset * pip_value), _Digits);
            if(sl < be_price)
              {
               if(trade.PositionModify(ticket, be_price, tp))
                  Print(">>> BE+OFFSET activado (BUY) #", ticket,
                        " | SL: ", be_price, " (+", InpBreakEvenOffset, " pips)");
              }
           }

         // 2. Trailing Stop (solo si ya superó el BE)
         if(InpUsarTrailing && ganancia_pips >= (InpBreakEvenPips + InpTrailingPips))
           {
            double nuevo_sl = NormalizeDouble(bid - (InpTrailingPips * pip_value), _Digits);
            if(nuevo_sl > sl + (InpTrailingStep * pip_value))
              {
               if(trade.PositionModify(ticket, nuevo_sl, tp))
                  Print(">>> TRAILING (BUY) #", ticket, " | SL: ", nuevo_sl);
              }
           }
        }
      // ============ VENTAS ============
      else if(type == POSITION_TYPE_SELL)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double ganancia_pips = (open - ask) / pip_value;

         // 1. Break Even con OFFSET
         if(InpUsarBreakEven && ganancia_pips >= InpBreakEvenPips)
           {
            double be_price = NormalizeDouble(open - (InpBreakEvenOffset * pip_value), _Digits);
            if(sl > be_price || sl == 0)
              {
               if(trade.PositionModify(ticket, be_price, tp))
                  Print(">>> BE+OFFSET activado (SELL) #", ticket,
                        " | SL: ", be_price, " (+", InpBreakEvenOffset, " pips)");
              }
           }

         // 2. Trailing Stop
         if(InpUsarTrailing && ganancia_pips >= (InpBreakEvenPips + InpTrailingPips))
           {
            double nuevo_sl = NormalizeDouble(ask + (InpTrailingPips * pip_value), _Digits);
            if(nuevo_sl < sl - (InpTrailingStep * pip_value) || sl == 0)
              {
               if(trade.PositionModify(ticket, nuevo_sl, tp))
                  Print(">>> TRAILING (SELL) #", ticket, " | SL: ", nuevo_sl);
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
bool TengoPosicionAbierta()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol)
        {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            return true;
        }
     }
   return false;
  }
//+------------------------------------------------------------------+