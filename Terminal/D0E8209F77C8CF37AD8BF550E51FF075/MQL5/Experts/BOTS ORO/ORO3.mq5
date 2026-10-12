//+------------------------------------------------------------------+
//|                                                       ORO_v4.0.mq5 |
//|         EA ESTRUCTURA DE MERCADO (SMC Matemático) — v4.0          |
//|                                                                  |
//|  Cambios sobre v3.0 (pedidos por el usuario):                    |
//|   1) EMA200 como SESGO DIRECCIONAL (permite ambos lados, pero    |
//|      prioriza a favor de la EMA200 con un factor de riesgo).     |
//|   2) PROTECCIÓN ESCALONADA del capital ganado:                   |
//|         - Parcial 1 en 1R  -> SL a breakeven                     |
//|         - Parcial 2 en 2R  -> SL a +1R (lock)                    |
//|         - Trailing agresivo por ATR sobre el remanente          |
//|      Con FALLBACK: si el lote es demasiado chico para partir    |
//|      (típico en cuentas 1:1), omite el parcial pero igual        |
//|      protege moviendo el SL (breakeven / +1R / trailing).        |
//|   3) AJUSTE POR MARGEN (OrderCalcMargin) para evitar el error    |
//|      "not enough money" (retcode 10019) en apalancamiento 1:1.   |
//|                                                                  |
//|  La lógica de entrada COMPRA/VENTA se mantiene simétrica (espejo)|
//+------------------------------------------------------------------+
#property copyright "SMC Execution Bot"
#property link      ""
#property version   "4.0"

#include <Trade\Trade.mqh>
CTrade trade;

//====================== PARÁMETROS DE CONFIGURACIÓN ================//

//--- Riesgo y objetivos
input double   RiskPerTrade      = 2.0;      // Riesgo por operación (%)
input double   ATRMultiplierSL   = 2.0;      // Multiplicador ATR para SL (define 1R)
input double   RatioTP           = 3.0;      // Multiplicador ATR para TP final (techo del runner)

//--- Estructura (EMAs)
input int      EMA_Fast          = 20;       // EMA Rápida (Estructura Micro)
input int      EMA_Slow          = 50;       // EMA Lenta (Estructura Macro)
input int      EMA_Filter        = 200;      // EMA de SESGO DIRECCIONAL (nueva)

//--- Sesgo direccional por EMA200
input double   ContraTendRiskFactor = 0.5;   // Riesgo relativo en trades CONTRA la EMA200
                                             //   1.0 = sin sesgo | 0.5 = mitad de riesgo | 0.0 = no operar contra

//--- Protección escalonada del capital ganado
input double   Parcial1_R        = 1.0;      // Nivel 1 (en múltiplos de R)
input double   Parcial1_Pct      = 40.0;     // % del lote ORIGINAL a cerrar en nivel 1
input bool     MoverSL_BE_en_P1  = true;     // Mover SL a breakeven al alcanzar P1
input double   Parcial2_R        = 2.0;      // Nivel 2 (en múltiplos de R)
input double   Parcial2_Pct      = 30.0;     // % del lote ORIGINAL a cerrar en nivel 2
input bool     MoverSL_Lock_en_P2= true;     // Mover SL a +1R (lock de ganancia) al alcanzar P2

//--- Trailing agresivo (sobre el remanente / runner)
input double   TrailStartR       = 2.0;      // A partir de cuántos R arranca el trailing
input double   TrailATRMult      = 1.0;      // Distancia del trailing en ATR (agresivo)

//--- Control de margen (CRÍTICO en cuentas 1:1)
input double   MargenSeguridadPct= 80.0;     // % del margen libre usable como tope
input bool     PermitirLoteMinimo= true;     // Abrir con lote mínimo si el riesgo pide menos

//--- Varios
input ulong    MagicNumber       = 777000;   // Número mágico
input bool     LogDiagnostico    = true;     // Log [DIAG] por vela nueva

//====================== INDICADORES ===============================//
int handleATR;
int handleEMA_Fast;
int handleEMA_Slow;
int handleEMA_Filter;

//====================== ESTADO DE POSICIÓN ========================//
datetime last_bar_time = 0;
bool     signal_active = false;

// Estado de la posición gestionada (esta EA opera 1 posición por vez)
ulong    g_ticket      = 0;      // ticket de la posición viva
double   g_riskDist    = 0.0;    // distancia 1R en precio (capturada al detectarla)
double   g_openPrice   = 0.0;    // precio de apertura
double   g_origVolume  = 0.0;    // volumen original (antes de parciales)
bool     g_p1_done     = false;  // parcial 1 ya procesado
bool     g_p2_done     = false;  // parcial 2 ya procesado

//+------------------------------------------------------------------+
//| Inicialización                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   handleATR        = iATR(_Symbol, _Period, 14);
   handleEMA_Fast   = iMA(_Symbol, _Period, EMA_Fast,   0, MODE_EMA, PRICE_CLOSE);
   handleEMA_Slow   = iMA(_Symbol, _Period, EMA_Slow,   0, MODE_EMA, PRICE_CLOSE);
   handleEMA_Filter = iMA(_Symbol, _Period, EMA_Filter, 0, MODE_EMA, PRICE_CLOSE);

   if(handleATR == INVALID_HANDLE || handleEMA_Fast == INVALID_HANDLE ||
      handleEMA_Slow == INVALID_HANDLE || handleEMA_Filter == INVALID_HANDLE)
     {
      Print("❌ Error cargando indicadores.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(MagicNumber);
   ResetEstadoPosicion();
   Print("✅ EA SMC v4.0 Operativo (EMA200 + protección escalonada + ajuste de margen).");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Desinicialización                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(handleATR);
   IndicatorRelease(handleEMA_Fast);
   IndicatorRelease(handleEMA_Slow);
   IndicatorRelease(handleEMA_Filter);
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Si tenemos posición propia abierta -> gestión (parciales/trailing)
   ulong miTicket = ObtenerMiPosicion();
   if(miTicket > 0)
     {
      GestionarPosicion(miTicket);
      return;
     }
   else
     {
      ResetEstadoPosicion(); // quedamos planos: limpiar estado
     }

   // 2. Detectar nueva vela
   datetime current_time = iTime(_Symbol, _Period, 0);
   bool nueva_vela = (current_time != last_bar_time);
   if(nueva_vela)
     {
      last_bar_time = current_time;
      signal_active = false;
     }

   // 3. Datos de indicadores
   double atr[1], ema_fast[1], ema_slow[1], ema_filter[1];
   if(CopyBuffer(handleATR,        0, 0, 1, atr)        < 1) return;
   if(CopyBuffer(handleEMA_Fast,   0, 0, 1, ema_fast)   < 1) return;
   if(CopyBuffer(handleEMA_Slow,   0, 0, 1, ema_slow)   < 1) return;
   if(CopyBuffer(handleEMA_Filter, 0, 0, 1, ema_filter) < 1) return;
   if(atr[0] == 0) return;

   double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double close1      = iClose(_Symbol, _Period, 1); // último cierre confirmado

   // 4. Lógica de Estructura (idéntica en compra y venta — espejo)
   bool buy_signal  = false;
   bool sell_signal = false;

   // COMPRA: EMA20 > EMA50  y  cierre por encima de EMA20
   if(ema_fast[0] > ema_slow[0] && close1 > ema_fast[0])
      buy_signal = true;

   // VENTA: EMA20 < EMA50  y  cierre por debajo de EMA20
   if(ema_fast[0] < ema_slow[0] && close1 < ema_fast[0])
      sell_signal = true;

   // 5. SESGO DIRECCIONAL por EMA200: factor de riesgo según alineación
   //    (a favor de la EMA200 -> riesgo completo; en contra -> ContraTendRiskFactor)
   double riesgoBuy  = (close1 > ema_filter[0]) ? RiskPerTrade : RiskPerTrade * ContraTendRiskFactor;
   double riesgoSell = (close1 < ema_filter[0]) ? RiskPerTrade : RiskPerTrade * ContraTendRiskFactor;

   // Log de diagnóstico (una línea por vela nueva)
   if(LogDiagnostico && nueva_vela)
     {
      string sesgo = (close1 > ema_filter[0]) ? "ALCISTA(precio>EMA200)" :
                     (close1 < ema_filter[0]) ? "BAJISTA(precio<EMA200)" : "NEUTRO";
      PrintFormat("[DIAG] EMA20=%.2f EMA50=%.2f EMA200=%.2f | sesgo=%s | buy=%s sell=%s | ATR=%.2f",
                  ema_fast[0], ema_slow[0], ema_filter[0], sesgo,
                  (buy_signal?"SI":"no"), (sell_signal?"SI":"no"), atr[0]);
     }

   // 6. Ejecución
   if(buy_signal && !signal_active && riesgoBuy > 0.0)
     {
      double sl_dist = atr[0] * ATRMultiplierSL;
      double sl = NormalizeDouble(current_bid - sl_dist, _Digits);
      double tp = NormalizeDouble(current_bid + (atr[0] * RatioTP), _Digits);

      double lot = CalcularLote(sl_dist, riesgoBuy);
      lot = AjustarLotePorMargen(lot, ORDER_TYPE_BUY, current_ask);

      if(lot > 0)
        {
         PrintFormat("🚀 COMPRA (BOS Alcista) | riesgo=%.2f%% | lote=%.2f | entrada=%.2f",
                     riesgoBuy, lot, current_ask);
         if(trade.Buy(lot, _Symbol, current_ask, sl, tp, "SMC Buy v4"))
           {
            Print("✅ Orden de Compra ejecutada.");
            signal_active = true;
           }
        }
     }
   else if(sell_signal && !signal_active && riesgoSell > 0.0)
     {
      double sl_dist = atr[0] * ATRMultiplierSL;
      double sl = NormalizeDouble(current_ask + sl_dist, _Digits);
      double tp = NormalizeDouble(current_ask - (atr[0] * RatioTP), _Digits);

      double lot = CalcularLote(sl_dist, riesgoSell);
      lot = AjustarLotePorMargen(lot, ORDER_TYPE_SELL, current_bid);

      if(lot > 0)
        {
         PrintFormat("🚀 VENTA (BOS Bajista) | riesgo=%.2f%% | lote=%.2f | entrada=%.2f",
                     riesgoSell, lot, current_bid);
         if(trade.Sell(lot, _Symbol, current_bid, sl, tp, "SMC Sell v4"))
           {
            Print("✅ Orden de Venta ejecutada.");
            signal_active = true;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Devuelve el ticket de MI posición (magic+símbolo) o 0            |
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
//| Limpia el estado cuando quedamos planos                          |
//+------------------------------------------------------------------+
void ResetEstadoPosicion()
  {
   g_ticket     = 0;
   g_riskDist   = 0.0;
   g_openPrice  = 0.0;
   g_origVolume = 0.0;
   g_p1_done    = false;
   g_p2_done    = false;
  }

//+------------------------------------------------------------------+
//| Cálculo de lote por riesgo                                       |
//+------------------------------------------------------------------+
double CalcularLote(double sl_distance, double riskPct)
  {
   if(sl_distance <= 0 || riskPct <= 0) return 0.0;

   double tick_value     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double account_equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(tick_size <= 0) return 0.0;

   double sl_points       = sl_distance / tick_size;
   double dollar_per_point= tick_value / tick_size;
   if(sl_points <= 0 || dollar_per_point <= 0) return 0.0;

   double risk_capital = account_equity * (riskPct / 100.0);
   double lot_size     = risk_capital / (sl_points * dollar_per_point);

   return NormalizarLote(lot_size);
  }

//+------------------------------------------------------------------+
//| Normaliza un lote al step/min/max del símbolo                    |
//+------------------------------------------------------------------+
double NormalizarLote(double lot_size)
  {
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step_lot > 0) lot_size = MathFloor(lot_size / step_lot) * step_lot;
   if(lot_size < min_lot) lot_size = min_lot;
   if(lot_size > max_lot) lot_size = max_lot;
   return lot_size;
  }

//+------------------------------------------------------------------+
//| Ajusta el lote al margen libre disponible (clave en 1:1)         |
//|  - Usa OrderCalcMargin (única forma fiable de saber el margen    |
//|    real que exige el bróker para ESE símbolo/lote).              |
//|  - Recorta al tope (MargenSeguridadPct del margen libre).        |
//|  - Si ni el mínimo entra -> devuelve 0 y lo explica.             |
//+------------------------------------------------------------------+
double AjustarLotePorMargen(double lot, ENUM_ORDER_TYPE type, double price)
  {
   if(lot <= 0) return 0.0;

   double margen_libre = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double tope_margen  = margen_libre * (MargenSeguridadPct / 100.0);

   double margen_req = 0.0;
   if(!OrderCalcMargin(type, _Symbol, lot, price, margen_req))
     {
      PrintFormat("⚠️ OrderCalcMargin falló (err %d); se usa lote sin ajustar.", GetLastError());
      return lot;
     }

   // Cabe dentro del tope
   if(margen_req <= tope_margen) return lot;

   // Recorte proporcional al margen disponible
   double factor    = tope_margen / margen_req;
   double nuevo_lot = NormalizarLote(lot * factor);
   double min_lot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   if(nuevo_lot < min_lot)
     {
      // ¿Entra al menos el lote mínimo en el margen LIBRE (no el tope)?
      double margen_min = 0.0;
      OrderCalcMargin(type, _Symbol, min_lot, price, margen_min);
      if(PermitirLoteMinimo && margen_min <= margen_libre)
        {
         PrintFormat("ℹ️ Margen ajustado al lote MÍNIMO %.2f (pedía %.2f). Margen libre=%.2f",
                     min_lot, lot, margen_libre);
         return min_lot;
        }
      PrintFormat("⛔ Margen insuficiente incluso para el lote mínimo (%.2f). No se abre. Margen libre=%.2f",
                  min_lot, margen_libre);
      return 0.0;
     }

   PrintFormat("ℹ️ Lote recortado por margen: %.2f -> %.2f (margen libre=%.2f, tope=%.2f)",
               lot, nuevo_lot, margen_libre, tope_margen);
   return nuevo_lot;
  }

//+------------------------------------------------------------------+
//| GESTIÓN de la posición: parciales escalonados + trailing         |
//+------------------------------------------------------------------+
void GestionarPosicion(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;

   // Capturar estado la primera vez que vemos esta posición
   if(g_ticket != ticket)
     {
      g_ticket     = ticket;
      g_openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double slIni = PositionGetDouble(POSITION_SL);
      g_origVolume = PositionGetDouble(POSITION_VOLUME);
      g_riskDist   = (slIni > 0) ? MathAbs(g_openPrice - slIni) : 0.0;
      g_p1_done    = false;
      g_p2_done    = false;

      if(g_riskDist <= 0)
        {
         // Sin SL válido no podemos medir R; salimos sin gestionar por R.
         Print("⚠️ Posición sin SL válido: no se puede medir R para la protección escalonada.");
        }
     }

   if(g_riskDist <= 0) return; // no podemos medir R

   double atr_val[1];
   if(CopyBuffer(handleATR, 0, 0, 1, atr_val) < 1) return;

   long   tipo        = PositionGetInteger(POSITION_TYPE);
   double tp          = PositionGetDouble(POSITION_TP);
   double sl_actual   = PositionGetDouble(POSITION_SL);
   double bid         = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask         = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //=================== COMPRA ===================//
   if(tipo == POSITION_TYPE_BUY)
     {
      double avance_precio = bid - g_openPrice;      // ganancia en precio
      double R = avance_precio / g_riskDist;         // en múltiplos de R

      // Parcial 1 en 1R -> breakeven
      if(!g_p1_done && R >= Parcial1_R)
        {
         bool cerrado = CerrarParcial(ticket, Parcial1_Pct, "P1(1R)");
         g_p1_done = true; // se marca aunque el fallback omita el cierre
         if(MoverSL_BE_en_P1)
            ModificarSL(ticket, g_openPrice, tp, "breakeven");
        }

      // Parcial 2 en 2R -> lock a +1R
      if(!g_p2_done && R >= Parcial2_R)
        {
         bool cerrado = CerrarParcial(ticket, Parcial2_Pct, "P2(2R)");
         g_p2_done = true;
         if(MoverSL_Lock_en_P2)
            ModificarSL(ticket, g_openPrice + g_riskDist, tp, "lock +1R");
        }

      // Trailing agresivo por ATR a partir de TrailStartR
      if(R >= TrailStartR && atr_val[0] > 0)
        {
         double nuevo_sl = NormalizeDouble(bid - atr_val[0] * TrailATRMult, _Digits);
         if(nuevo_sl > sl_actual) // sólo mejorar
            ModificarSL(ticket, nuevo_sl, tp, "trailing");
        }
     }
   //=================== VENTA (espejo) ===================//
   else if(tipo == POSITION_TYPE_SELL)
     {
      double avance_precio = g_openPrice - ask;
      double R = avance_precio / g_riskDist;

      if(!g_p1_done && R >= Parcial1_R)
        {
         bool cerrado = CerrarParcial(ticket, Parcial1_Pct, "P1(1R)");
         g_p1_done = true;
         if(MoverSL_BE_en_P1)
            ModificarSL(ticket, g_openPrice, tp, "breakeven");
        }

      if(!g_p2_done && R >= Parcial2_R)
        {
         bool cerrado = CerrarParcial(ticket, Parcial2_Pct, "P2(2R)");
         g_p2_done = true;
         if(MoverSL_Lock_en_P2)
            ModificarSL(ticket, g_openPrice - g_riskDist, tp, "lock +1R");
        }

      if(R >= TrailStartR && atr_val[0] > 0)
        {
         double nuevo_sl = NormalizeDouble(ask + atr_val[0] * TrailATRMult, _Digits);
         if(nuevo_sl < sl_actual || sl_actual == 0) // sólo mejorar
            ModificarSL(ticket, nuevo_sl, tp, "trailing");
        }
     }
  }

//+------------------------------------------------------------------+
//| Cierra un % del lote ORIGINAL. Con FALLBACK: si el lote es muy   |
//| chico para partir sin violar el mínimo, omite el cierre (pero    |
//| la protección de SL sí se aplica igual desde GestionarPosicion). |
//| Devuelve true si efectivamente cerró volumen.                    |
//+------------------------------------------------------------------+
bool CerrarParcial(ulong ticket, double pct_original, string etiqueta)
  {
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double cerrar = g_origVolume * (pct_original / 100.0);
   if(step > 0) cerrar = MathFloor(cerrar / step) * step;

   double vol_actual = PositionGetDouble(POSITION_VOLUME);
   double remanente  = vol_actual - cerrar;

   // FALLBACK (típico en 1:1): no se puede partir sin violar el mínimo
   if(cerrar < min_lot || remanente < min_lot || cerrar > vol_actual)
     {
      PrintFormat("ℹ️ %s: lote %.2f demasiado chico para cerrar parcial %.0f%% "
                  "(cerrar=%.2f, remanente=%.2f, min=%.2f). Se OMITE el parcial y "
                  "se protege sólo con el SL.",
                  etiqueta, vol_actual, pct_original, cerrar, remanente, min_lot);
      return false;
     }

   if(trade.PositionClosePartial(ticket, cerrar))
     {
      PrintFormat("💰 %s: cerrado parcial %.2f lotes (%.0f%% del original). Remanente=%.2f",
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
//| Modifica el SL de forma segura (respeta stops level, sólo log)   |
//+------------------------------------------------------------------+
void ModificarSL(ulong ticket, double nuevo_sl, double tp, string motivo)
  {
   nuevo_sl = NormalizeDouble(nuevo_sl, _Digits);

   // Evitar modificaciones redundantes
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