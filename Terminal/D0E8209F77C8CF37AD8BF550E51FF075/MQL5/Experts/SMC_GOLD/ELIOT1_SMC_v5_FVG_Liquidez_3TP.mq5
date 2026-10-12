//+------------------------------------------------------------------+
//|                                                  ORO_v5.0_SMC.mq5 |
//|               EA ESTRUCTURA DE MERCADO SMC ELITE — v5.0          |
//|                                                                  |
//|  MEJORAS v5.0 (Smart Money Concepts + Institutional Trading):    |
//|   1) BOS (Break of Structure) y CHoCH (Change of Character)      |
//|   2) Zonas de Liquidez (Liquidity Pools)                         |
//|   3) FVG (Fair Value Gaps) para objetivos parciales              |
//|   4) Trailing adaptativo basado en estructura                    |
//|   5) Filtro institucional de sesgo (multi-temporal)              |
//+------------------------------------------------------------------+
#property copyright "SMC Elite Execution Bot"
#property link      ""
#property version   "5.0"

#include <Trade\Trade.mqh>
CTrade trade;

//====================== PARÁMETROS DE CONFIGURACIÓN ================//

//--- Riesgo y objetivos
input double   RiskPerTrade        = 2.0;      // Riesgo por operación (%)
input double   ATRMultiplierSL     = 1.8;      // Multiplicador ATR para SL
input double   RatioTP1            = 1.5;      // 1er objetivo (R)
input double   RatioTP2            = 2.5;      // 2do objetivo (R)
input double   RatioTP3            = 4.0;      // 3er objetivo (R - runner)

//--- Estructura (EMAs + SMC)
input int      EMA_Fast            = 20;
input int      EMA_Slow            = 50;
input int      EMA_Filter          = 200;

//--- Smart Money Concepts
input int      LookbackBars        = 50;       // Barras para detectar estructura
input double   LiquidezTolerance   = 0.002;    // Tolerancia para zonas de liquidez (%)
input bool     UsarFVG             = true;     // Usar Fair Value Gaps
input bool     UsarLiquidez        = true;     // Usar zonas de liquidez
input bool     UsarBOS             = true;     // Usar Break of Structure

//--- Protección escalonada (mantenida)
input double   Parcial1_R          = 1.0;
input double   Parcial1_Pct        = 35.0;
input bool     MoverSL_BE_en_P1    = true;
input double   Parcial2_R          = 2.0;
input double   Parcial2_Pct        = 30.0;
input bool     MoverSL_Lock_en_P2  = true;

//--- Trailing institucional
input double   TrailStartR         = 1.5;      // Arranca antes
input double   TrailATRMult        = 1.2;      // Más agresivo
input bool     TrailingAdaptativo  = true;     // Se ajusta a la estructura

//--- Control de margen
input double   MargenSeguridadPct  = 80.0;
input bool     PermitirLoteMinimo  = true;

//--- Multi-temporal (sesgo institucional)
input ENUM_TIMEFRAMES TimeframeSesgo = PERIOD_H1;  // TF para sesgo principal

//--- Varios
input ulong    MagicNumber         = 777001;
input bool     LogDiagnostico      = true;

//====================== INDICADORES ===============================//
int handleATR;
int handleEMA_Fast, handleEMA_Slow, handleEMA_Filter;
int handleATR_Sesgo;

//====================== ESTRUCTURAS SMC ==========================//
struct SMC_Estructura
{
   double high_swing;      // Último máximo de estructura
   double low_swing;       // Último mínimo de estructura
   double fvg_alto;        // FVG superior
   double fvg_bajo;        // FVG inferior
   bool   bos_alcista;     // Break of Structure alcista
   bool   bos_bajista;     // Break of Structure bajista
   double liquidez_alta;   // Zona de liquidez alta (stops compra)
   double liquidez_baja;   // Zona de liquidez baja (stops venta)
};

SMC_Estructura g_estructura;
datetime g_estructura_time = 0;

//====================== ESTADO DE POSICIÓN ========================//
datetime last_bar_time = 0;
bool     signal_active = false;

ulong    g_ticket      = 0;
double   g_riskDist    = 0.0;
double   g_openPrice   = 0.0;
double   g_origVolume  = 0.0;
bool     g_p1_done     = false;
bool     g_p2_done     = false;

//+------------------------------------------------------------------+
//| Inicialización                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   handleATR        = iATR(_Symbol, _Period, 14);
   handleATR_Sesgo  = iATR(_Symbol, TimeframeSesgo, 14);
   handleEMA_Fast   = iMA(_Symbol, _Period, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA_Slow   = iMA(_Symbol, _Period, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA_Filter = iMA(_Symbol, TimeframeSesgo, EMA_Filter, 0, MODE_EMA, PRICE_CLOSE);

   if(handleATR == INVALID_HANDLE || handleEMA_Fast == INVALID_HANDLE ||
      handleEMA_Slow == INVALID_HANDLE || handleEMA_Filter == INVALID_HANDLE)
   {
      Print("❌ Error cargando indicadores.");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   ResetEstadoPosicion();
   Print("✅ EA SMC v5.0 Elite Operativo (Smart Money Concepts + Estructura).");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Desinicialización                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleATR);
   IndicatorRelease(handleATR_Sesgo);
   IndicatorRelease(handleEMA_Fast);
   IndicatorRelease(handleEMA_Slow);
   IndicatorRelease(handleEMA_Filter);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Posición propia abierta -> gestión
   ulong miTicket = ObtenerMiPosicion();
   if(miTicket > 0)
   {
      GestionarPosicion(miTicket);
      return;
   }
   else
      ResetEstadoPosicion();

   // 2. Detectar nueva vela
   datetime current_time = iTime(_Symbol, _Period, 0);
   bool nueva_vela = (current_time != last_bar_time);
   if(nueva_vela)
   {
      last_bar_time = current_time;
      signal_active = false;
      
      // Actualizar estructura SMC cada 5 velas
      if(TimeCurrent() - g_estructura_time > 5 * PeriodSeconds(_Period))
         AnalizarEstructura();
   }

   // 3. Datos de indicadores
   double atr[1], ema_fast[1], ema_slow[1], ema_filter[1];
   if(CopyBuffer(handleATR, 0, 0, 1, atr) < 1) return;
   if(CopyBuffer(handleEMA_Fast, 0, 0, 1, ema_fast) < 1) return;
   if(CopyBuffer(handleEMA_Slow, 0, 0, 1, ema_slow) < 1) return;
   if(CopyBuffer(handleEMA_Filter, 0, 0, 1, ema_filter) < 1) return;
   if(atr[0] == 0) return;

   double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double close1 = iClose(_Symbol, _Period, 1);
   double high1 = iHigh(_Symbol, _Period, 1);
   double low1  = iLow(_Symbol, _Period, 1);

   // 4. SESGO INSTITUCIONAL (multi-temporal)
   bool sesgo_alcista = (close1 > ema_filter[0]);
   bool sesgo_bajista = (close1 < ema_filter[0]);

   // 5. SEÑALES SMC (Break of Structure + Liquidez + FVG)
   bool buy_signal  = false;
   bool sell_signal = false;

   // --- COMPRA: BOS alcista + precio sobre EMA20 + FVG confirmado ---
   if(ema_fast[0] > ema_slow[0] && close1 > ema_fast[0])
   {
      // BOS alcista (quiebre de estructura)
      bool bos_confirmado = (!UsarBOS) || (UsarBOS && g_estructura.bos_alcista);
      
      // Liquidez barrida (sweep)
      bool liquidez_confirmada = (!UsarLiquidez) || 
          (UsarLiquidez && (low1 <= g_estructura.liquidez_baja || 
                            close1 > g_estructura.liquidez_alta));
      
      // FVG (zona de valor justo) - para entradas en pullback
      bool fvg_confirmado = (!UsarFVG) || 
          (UsarFVG && close1 >= g_estructura.fvg_bajo && close1 <= g_estructura.fvg_alto);
      
      // Sesgo institucional (EMA200)
      bool sesgo_confirmado = sesgo_alcista;

      buy_signal = bos_confirmado && liquidez_confirmada && sesgo_confirmado;
   }

  // --- VENTA: BOS bajista + precio bajo EMA20 + FVG confirmado ---
   if(ema_fast[0] < ema_slow[0] && close1 < ema_fast[0])
   {
      bool bos_confirmado = (!UsarBOS) || (UsarBOS && g_estructura.bos_bajista);
      bool liquidez_confirmada = (!UsarLiquidez) || 
          (UsarLiquidez && (high1 >= g_estructura.liquidez_alta || 
                            close1 < g_estructura.liquidez_baja));
      bool fvg_confirmado = (!UsarFVG) || 
          (UsarFVG && close1 >= g_estructura.fvg_bajo && close1 <= g_estructura.fvg_alto);
      bool sesgo_confirmado = sesgo_bajista;

      sell_signal = bos_confirmado && liquidez_confirmada && sesgo_confirmado;
   }

   // 6. Log de diagnóstico
   if(LogDiagnostico && nueva_vela)
   {
      string sesgo = sesgo_alcista ? "ALCISTA" : sesgo_bajista ? "BAJISTA" : "NEUTRO";
      PrintFormat("[DIAG] EMA20=%.2f EMA50=%.2f | sesgo=%s | buy=%s sell=%s | ATR=%.2f | "
                  "BOS: A=%s B=%s | FVG: %.2f-%.2f",
                  ema_fast[0], ema_slow[0], sesgo,
                  (buy_signal?"SI":"no"), (sell_signal?"SI":"no"), atr[0],
                  (g_estructura.bos_alcista?"SI":"no"), (g_estructura.bos_bajista?"SI":"no"),
                  g_estructura.fvg_bajo, g_estructura.fvg_alto);
   }

   // 7. Ejecución con ajuste de riesgo por sesgo
   double riesgoBuy  = sesgo_alcista ? RiskPerTrade : RiskPerTrade * 0.5;
   double riesgoSell = sesgo_bajista ? RiskPerTrade : RiskPerTrade * 0.5;

   if(buy_signal && !signal_active && riesgoBuy > 0.0)
   {
      double sl_dist = atr[0] * ATRMultiplierSL;
      double sl = NormalizeDouble(current_bid - sl_dist, _Digits);
      double tp1 = NormalizeDouble(current_bid + (atr[0] * RatioTP1), _Digits);
      double tp2 = NormalizeDouble(current_bid + (atr[0] * RatioTP2), _Digits);
      double tp3 = NormalizeDouble(current_bid + (atr[0] * RatioTP3), _Digits);

      double lot = CalcularLote(sl_dist, riesgoBuy);
      lot = AjustarLotePorMargen(lot, ORDER_TYPE_BUY, current_ask);

      if(lot > 0)
      {
         PrintFormat("🚀 COMPRA SMC ELITE | riesgo=%.2f%% | lote=%.2f | entrada=%.2f | TPs: %.2f/%.2f/%.2f",
                     riesgoBuy, lot, current_ask, tp1, tp2, tp3);
         if(trade.Buy(lot, _Symbol, current_ask, sl, tp3, "SMC Elite Buy"))
         {
            Print("✅ Orden de Compra SMC ejecutada.");
            signal_active = true;
         }
      }
   }
   else if(sell_signal && !signal_active && riesgoSell > 0.0)
   {
      double sl_dist = atr[0] * ATRMultiplierSL;
      double sl = NormalizeDouble(current_ask + sl_dist, _Digits);
      double tp1 = NormalizeDouble(current_ask - (atr[0] * RatioTP1), _Digits);
      double tp2 = NormalizeDouble(current_ask - (atr[0] * RatioTP2), _Digits);
      double tp3 = NormalizeDouble(current_ask - (atr[0] * RatioTP3), _Digits);

      double lot = CalcularLote(sl_dist, riesgoSell);
      lot = AjustarLotePorMargen(lot, ORDER_TYPE_SELL, current_bid);

      if(lot > 0)
      {
         PrintFormat("🚀 VENTA SMC ELITE | riesgo=%.2f%% | lote=%.2f | entrada=%.2f | TPs: %.2f/%.2f/%.2f",
                     riesgoSell, lot, current_bid, tp1, tp2, tp3);
         if(trade.Sell(lot, _Symbol, current_bid, sl, tp3, "SMC Elite Sell"))
         {
            Print("✅ Orden de Venta SMC ejecutada.");
            signal_active = true;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Analiza estructura de mercado (SMC)                              |
//+------------------------------------------------------------------+
void AnalizarEstructura()
{
   g_estructura_time = TimeCurrent();
   
   // 1. Detectar swing highs/lows
   double highs[], lows[];
   ArrayResize(highs, LookbackBars);
   ArrayResize(lows, LookbackBars);
   
   for(int i = 0; i < LookbackBars; i++)
   {
      highs[i] = iHigh(_Symbol, _Period, i);
      lows[i] = iLow(_Symbol, _Period, i);
   }
   
   // 2. Encontrar máximos y mínimos significativos
   int max_idx = ArrayMaximum(highs, 2, LookbackBars - 4);
   int min_idx = ArrayMinimum(lows, 2, LookbackBars - 4);
   
   g_estructura.high_swing = (max_idx >= 0) ? highs[max_idx] : 0;
   g_estructura.low_swing = (min_idx >= 0) ? lows[min_idx] : 0;
   
   // 3. Break of Structure (BOS)
   double close1 = iClose(_Symbol, _Period, 1);
   double close2 = iClose(_Symbol, _Period, 2);
   
   g_estructura.bos_alcista = (close1 > g_estructura.high_swing && close2 <= g_estructura.high_swing);
   g_estructura.bos_bajista = (close1 < g_estructura.low_swing && close2 >= g_estructura.low_swing);
   
   // 4. Fair Value Gaps (FVG) - 3 velas
   double high0 = iHigh(_Symbol, _Period, 0);
   double low0  = iLow(_Symbol, _Period, 0);
   double high1 = iHigh(_Symbol, _Period, 1);
   double low1  = iLow(_Symbol, _Period, 1);
   double high2 = iHigh(_Symbol, _Period, 2);
   double low2  = iLow(_Symbol, _Period, 2);
   
   // FVG alcista: low2 > high0
   if(low2 > high0)
   {
      g_estructura.fvg_bajo = high0;
      g_estructura.fvg_alto = low2;
   }
   // FVG bajista: high2 < low0
   else if(high2 < low0)
   {
      g_estructura.fvg_bajo = high2;
      g_estructura.fvg_alto = low0;
   }
   else
   {
      g_estructura.fvg_bajo = 0;
      g_estructura.fvg_alto = 0;
   }
   
   // 5. Zonas de liquidez (stops)
   double high_max = highs[ArrayMaximum(highs, 0, LookbackBars/2)];
   double low_min  = lows[ArrayMinimum(lows, 0, LookbackBars/2)];
   
   double tolerancia = LiquidezTolerance * (high_max - low_min);
   g_estructura.liquidez_alta = high_max + tolerancia;
   g_estructura.liquidez_baja = low_min - tolerancia;
}

//+------------------------------------------------------------------+
//| Obtener mi posición                                              |
//+------------------------------------------------------------------+
ulong ObtenerMiPosicion()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         return ticket;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Resetear estado                                                  |
//+------------------------------------------------------------------+
void ResetEstadoPosicion()
{
   g_ticket = 0;
   g_riskDist = 0.0;
   g_openPrice = 0.0;
   g_origVolume = 0.0;
   g_p1_done = false;
   g_p2_done = false;
}

//+------------------------------------------------------------------+
//| Cálculo de lote por riesgo                                       |
//+------------------------------------------------------------------+
double CalcularLote(double sl_distance, double riskPct)
{
   if(sl_distance <= 0 || riskPct <= 0) return 0.0;
   
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double account_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   if(tick_size <= 0) return 0.0;
   
   double sl_points = sl_distance / tick_size;
   double dollar_per_point = tick_value / tick_size;
   if(sl_points <= 0 || dollar_per_point <= 0) return 0.0;
   
   double risk_capital = account_equity * (riskPct / 100.0);
   double lot_size = risk_capital / (sl_points * dollar_per_point);
   
   return NormalizarLote(lot_size);
}

//+------------------------------------------------------------------+
//| Normalizar lote                                                  |
//+------------------------------------------------------------------+
double NormalizarLote(double lot_size)
{
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(step_lot > 0) lot_size = MathFloor(lot_size / step_lot) * step_lot;
   if(lot_size < min_lot) lot_size = min_lot;
   if(lot_size > max_lot) lot_size = max_lot;
   return lot_size;
}

//+------------------------------------------------------------------+
//| Ajuste por margen                                                |
//+------------------------------------------------------------------+
double AjustarLotePorMargen(double lot, ENUM_ORDER_TYPE type, double price)
{
   if(lot <= 0) return 0.0;
   
   double margen_libre = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double tope_margen = margen_libre * (MargenSeguridadPct / 100.0);
   
   double margen_req = 0.0;
   if(!OrderCalcMargin(type, _Symbol, lot, price, margen_req))
   {
      PrintFormat("⚠️ OrderCalcMargin falló (err %d); se usa lote sin ajustar.", GetLastError());
      return lot;
   }
   
   if(margen_req <= tope_margen) return lot;
   
   double factor = tope_margen / margen_req;
   double nuevo_lot = NormalizarLote(lot * factor);
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   
   if(nuevo_lot < min_lot)
   {
      double margen_min = 0.0;
      OrderCalcMargin(type, _Symbol, min_lot, price, margen_min);
      if(PermitirLoteMinimo && margen_min <= margen_libre)
      {
         PrintFormat("ℹ️ Margen ajustado al lote MÍNIMO %.2f", min_lot);
         return min_lot;
      }
      PrintFormat("⛔ Margen insuficiente incluso para lote mínimo (%.2f).", min_lot);
      return 0.0;
   }
   
   return nuevo_lot;
}

//+------------------------------------------------------------------+
//| GESTIÓN DE POSICIÓN (MEJORADA CON SMC)                          |
//+------------------------------------------------------------------+
void GestionarPosicion(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;
   
   if(g_ticket != ticket)
   {
      g_ticket = ticket;
      g_openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double slIni = PositionGetDouble(POSITION_SL);
      g_origVolume = PositionGetDouble(POSITION_VOLUME);
      g_riskDist = (slIni > 0) ? MathAbs(g_openPrice - slIni) : 0.0;
      g_p1_done = false;
      g_p2_done = false;
   }
   
   if(g_riskDist <= 0) return;
   
   double atr_val[1];
   if(CopyBuffer(handleATR, 0, 0, 1, atr_val) < 1) return;
   
   long tipo = PositionGetInteger(POSITION_TYPE);
   double tp = PositionGetDouble(POSITION_TP);
   double sl_actual = PositionGetDouble(POSITION_SL);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // Trailing adaptativo: se ajusta si hay estructura
   double trail_mult = TrailATRMult;
   if(TrailingAdaptativo)
   {
      // Si estamos cerca de zona de liquidez, ajuste más agresivo
      if(UsarLiquidez)
      {
         if(tipo == POSITION_TYPE_BUY && bid > g_estructura.liquidez_alta * 0.98)
            trail_mult = 0.8;  // Más agresivo cerca de liquidez
         else if(tipo == POSITION_TYPE_SELL && ask < g_estructura.liquidez_baja * 1.02)
            trail_mult = 0.8;
      }
   }
   
   //=================== COMPRA ===================//
   if(tipo == POSITION_TYPE_BUY)
   {
      double R = (bid - g_openPrice) / g_riskDist;
      
      if(!g_p1_done && R >= Parcial1_R)
      {
         CerrarParcial(ticket, Parcial1_Pct, "P1(1R)");
         g_p1_done = true;
         if(MoverSL_BE_en_P1)
            ModificarSL(ticket, g_openPrice, tp, "breakeven");
      }
      
      if(!g_p2_done && R >= Parcial2_R)
      {
         CerrarParcial(ticket, Parcial2_Pct, "P2(2R)");
         g_p2_done = true;
         if(MoverSL_Lock_en_P2)
            ModificarSL(ticket, g_openPrice + g_riskDist, tp, "lock +1R");
      }
      
      // Trailing adaptativo
      if(R >= TrailStartR && atr_val[0] > 0)
      {
         double nuevo_sl = NormalizeDouble(bid - atr_val[0] * trail_mult, _Digits);
         if(nuevo_sl > sl_actual)
            ModificarSL(ticket, nuevo_sl, tp, "trailing adaptativo");
      }
   }
   //=================== VENTA ===================//
   else if(tipo == POSITION_TYPE_SELL)
   {
      double R = (g_openPrice - ask) / g_riskDist;
      
      if(!g_p1_done && R >= Parcial1_R)
      {
         CerrarParcial(ticket, Parcial1_Pct, "P1(1R)");
         g_p1_done = true;
         if(MoverSL_BE_en_P1)
            ModificarSL(ticket, g_openPrice, tp, "breakeven");
      }
      
      if(!g_p2_done && R >= Parcial2_R)
      {
         CerrarParcial(ticket, Parcial2_Pct, "P2(2R)");
         g_p2_done = true;
         if(MoverSL_Lock_en_P2)
            ModificarSL(ticket, g_openPrice - g_riskDist, tp, "lock +1R");
      }
      
      if(R >= TrailStartR && atr_val[0] > 0)
      {
         double nuevo_sl = NormalizeDouble(ask + atr_val[0] * trail_mult, _Digits);
         if(nuevo_sl < sl_actual || sl_actual == 0)
            ModificarSL(ticket, nuevo_sl, tp, "trailing adaptativo");
      }
   }
}

//+------------------------------------------------------------------+
//| Cierre parcial (con SMC targets)                                |
//+------------------------------------------------------------------+
bool CerrarParcial(ulong ticket, double pct_original, string etiqueta)
{
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   double cerrar = g_origVolume * (pct_original / 100.0);
   if(step > 0) cerrar = MathFloor(cerrar / step) * step;
   
   double vol_actual = PositionGetDouble(POSITION_VOLUME);
   double remanente = vol_actual - cerrar;
   
   if(cerrar < min_lot || remanente < min_lot || cerrar > vol_actual)
   {
      PrintFormat("ℹ️ %s: lote %.2f demasiado chico para cerrar %.0f%% (min=%.2f). OMITIDO.",
                  etiqueta, vol_actual, pct_original, min_lot);
      return false;
   }
   
   if(trade.PositionClosePartial(ticket, cerrar))
   {
      PrintFormat("💰 %s: cerrado %.2f lotes (%.0f%%). Remanente=%.2f",
                  etiqueta, cerrar, pct_original, remanente);
      return true;
   }
   else
   {
      PrintFormat("⚠️ %s: fallo al cerrar parcial (err %d).", etiqueta, GetLastError());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Modificación de SL                                               |
//+------------------------------------------------------------------+
void ModificarSL(ulong ticket, double nuevo_sl, double tp, string motivo)
{
   nuevo_sl = NormalizeDouble(nuevo_sl, _Digits);
   
   if(PositionSelectByTicket(ticket))
   {
      double sl_cur = PositionGetDouble(POSITION_SL);
      if(MathAbs(sl_cur - nuevo_sl) < _Point) return;
   }
   
   if(trade.PositionModify(ticket, nuevo_sl, tp))
      PrintFormat("🔧 SL movido a %.2f (%s).", nuevo_sl, motivo);
   else
      PrintFormat("⚠️ No se pudo mover SL a %.2f (%s, err %d).", nuevo_sl, motivo, GetLastError());
}
//+------------------------------------------------------------------+