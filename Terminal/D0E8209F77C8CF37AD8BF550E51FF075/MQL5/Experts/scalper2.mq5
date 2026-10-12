//+------------------------------------------------------------------+
//|                                          PiramideH1_v21.mq5      |
//|  Pirámide a favor de tendencia con STOP COMÚN y riesgo por %.     |
//+------------------------------------------------------------------+
//| CAMBIOS RESPECTO A v1                                            |
//|  1. Indicadores leídos en la vela CERRADA (v1 usaba la vela en    |
//|     formación: repintaba).                                        |
//|  2. OnTick en lugar de OnTimer(5s): la protección reacciona en   |
//|     cada tick.                                                    |
//|  3. Stop común: al añadir una posición, las anteriores suben su  |
//|     SL al del nuevo nivel -> el riesgo del grupo no se triplica. |
//|  4. Trailing del stop común (deja correr la tendencia).           |
//|  5. Lote por % de riesgo + tope de riesgo total del grupo.        |
//|  6. Pérdida diaria REAL (realizada + flotante). En v1 solo se     |
//|     medía lo flotante, así que casi nunca se activaba.            |
//|  7. Primera entrada en pullback a la EMA rápida (v1 compraba en   |
//|     cualquier vela, incluso en el extremo del movimiento).        |
//|  8. Pendiente de la EMA lenta como confirmación de tendencia.     |
//|  9. Cierra posiciones contrarias si la tendencia cambia.          |
//| 10. Dígitos del símbolo operado (v1 usaba _Digits del gráfico).   |
//| 11. Cooldown en velas reales (iBarShift), no en segundos/3600.    |
//| 12. Estado restaurado al reiniciar (última entrada).              |
//| v2.1 (tras backtest sep-2026: 12 primeras entradas, -162 USD;     |
//|       las ampliaciones de la pirámide dieron +32 USD):            |
//| 13. Filtro ADX mínimo: evita primeras entradas en rango.          |
//| 14. Filtro de timeframe superior (EMA H4 con pendiente y precio   |
//|     del lado correcto).                                           |
//| 15. Pausa de N velas tras un cierre en pérdida (evita reentrar    |
//|     1 hora después de un stop, como el 15/09).                    |
//+------------------------------------------------------------------+
#property copyright "PiramideH1 v2.1"
#property version   "2.10"

#include <Trade\Trade.mqh>

//--- Símbolo y timeframe
input group "=== Símbolo y control ==="
input string          InpSymbol  = "";         // Símbolo (vacío = el del gráfico)
input ENUM_TIMEFRAMES InpTF      = PERIOD_H1;  // Timeframe de trabajo
input ulong           InpMagic   = 20261010;   // Número mágico
input bool            InpDryRun  = false;      // Solo logs, sin operar

//--- Pirámide
input group "=== Pirámide ==="
input int    InpMaxPositions   = 3;    // Máximo de posiciones en la pirámide
input double InpEntryStepAtr   = 1.5;  // Avance mínimo (ATR) para añadir
input int    InpMinBarsBetween = 3;    // Velas mínimas entre entradas

//--- Tendencia
input group "=== Tendencia ==="
input int    InpEmaFast          = 20;   // EMA rápida
input int    InpEmaSlow          = 50;   // EMA lenta
input double InpMinEmaDiffAtr    = 0.5;  // Separación mínima EMA (ATR)
input int    InpSlopeBars        = 5;    // Pendiente EMA lenta a favor en N velas (0 = off)
input bool   InpRequierePullback = true; // 1ª entrada solo tras pullback a EMA rápida
input double InpPullbackTolAtr   = 0.2;  // Tolerancia del pullback (ATR)

//--- Stops
input group "=== Stops ==="
input int    InpAtrPeriod = 14;   // Periodo ATR
input double InpSLAtr     = 2.0;  // SL inicial (ATR)
input double InpTPAtr     = 4.0;  // TP por posición (ATR, 0 = sin TP)
input double InpTrailAtr  = 2.5;  // Trailing del stop común (ATR, 0 = off)

//--- Riesgo
input group "=== Riesgo ==="
input double InpLoteFijo          = 0.0;  // >0 = lote fijo; 0 = por % de riesgo
input double InpRiesgoPct         = 1.0;  // % de riesgo por entrada
input double InpRiesgoMaxTotalPct = 3.0;  // % máximo de riesgo abierto del grupo
input double InpRiesgoMaxLoteMin  = 5.0;  // Si el lote mínimo arriesga más, no entra
input double InpGroupTPPct        = 0.0;  // Cierre del grupo en +X% (0 = off)
input double InpDailyMaxLossPct   = 3.0;  // Pérdida diaria máx. (realizada + flotante)

//--- Filtros
input group "=== Filtros ==="
input long   InpMaxSpreadPts     = 50;    // Spread máximo (puntos)
input bool   InpCerrarEnCambio   = true;  // Cerrar posiciones contrarias al cambiar la tendencia
input int    InpViernesCorteHora = 20;    // Sin entradas el viernes desde esta hora servidor (-1 = off)

//--- Filtros v2.1
input group "=== Calidad de tendencia (v2.1) ==="
input int             InpAdxPeriod        = 14;         // Periodo ADX
input double          InpAdxMin           = 20.0;       // ADX mínimo en el TF de trabajo (0 = off)
input ENUM_TIMEFRAMES InpHTF              = PERIOD_H4;  // Timeframe superior
input int             InpHTFEma           = 50;         // EMA del timeframe superior
input int             InpHTFSlopeBars     = 3;          // Pendiente EMA superior en N velas (0 = filtro off)
input int             InpVelasTrasPerdida = 6;          // Velas de pausa tras cerrar en pérdida (0 = off)

//--- Variables globales
CTrade   g_trade;
string   g_symbol       = "";
int      g_hFast        = INVALID_HANDLE;
int      g_hSlow        = INVALID_HANDLE;
int      g_hAtr         = INVALID_HANDLE;
int      g_digits       = 2;
double   g_point        = 0.0;
double   g_volMin       = 0.0;
double   g_volMax       = 0.0;
double   g_volStep      = 0.0;
int      g_volDigits    = 2;
int      g_stopsLevel   = 0;
datetime g_lastBar      = 0;
datetime g_day          = 0;
double   g_balanceDia   = 0.0;
double   g_realizadoHoy = 0.0;
datetime g_ultCalcReal  = 0;
bool     g_dayBlocked   = false;
datetime g_lastEntryBar = 0;
int      g_hAdx         = INVALID_HANDLE;
int      g_hHtf         = INVALID_HANDLE;
datetime g_ultimaPerdida = 0;   // vela en la que se cerró la última pérdida

//+------------------------------------------------------------------+
//| UTILIDADES                                                       |
//+------------------------------------------------------------------+
// Lee el valor de un buffer en el desplazamiento dado (1 = última vela cerrada)
double Leer(const int handle, const int shift)
  {
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(handle, 0, shift, 1, b) != 1)
      return 0.0;
   return b[0];
  }

// Selecciona la posición y verifica que sea de este EA
bool EsMia(const ulong t)
  {
   if(t == 0 || !PositionSelectByTicket(t))
      return false;
   if(PositionGetString(POSITION_SYMBOL) != g_symbol)
      return false;
   return (PositionGetInteger(POSITION_MAGIC) == (long)InpMagic);
  }

// Dirección de la posición seleccionada: +1 compra, -1 venta
int DirPos()
  {
   return ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
  }

int ContarPosiciones(const int dir)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!EsMia(PositionGetTicket(i)))
         continue;
      if(dir == 0 || DirPos() == dir)
         n++;
     }
   return n;
  }

// Precio de la entrada más reciente en la dirección dada
double UltimaEntrada(const int dir)
  {
   double precio = 0.0;
   datetime ult = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!EsMia(PositionGetTicket(i)) || DirPos() != dir)
         continue;
      datetime tt = (datetime)PositionGetInteger(POSITION_TIME);
      if(tt > ult)
        {
         ult = tt;
         precio = PositionGetDouble(POSITION_PRICE_OPEN);
        }
     }
   return precio;
  }

double Flotante()
  {
   double s = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(EsMia(PositionGetTicket(i)))
         s += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   return s;
  }

// Pérdida en dinero si una posición de 'vol' lotes abierta en 'apertura' toca 'stop' (0 si el stop está en ganancia)
double PerdidaDinero(const int dir, const double apertura, const double stop, const double vol)
  {
   double p = 0.0;
   ENUM_ORDER_TYPE tipo = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(tipo, g_symbol, vol, apertura, stop, p))
     {
      double ts = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
      double tv = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
      if(ts <= 0.0)
         return 0.0;
      p = (dir > 0 ? stop - apertura : apertura - stop) / ts * tv * vol;
     }
   return (p < 0.0) ? -p : 0.0;
  }

//+------------------------------------------------------------------+
//| INICIALIZACIÓN                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_symbol = (InpSymbol == "") ? _Symbol : InpSymbol;
   if(!SymbolSelect(g_symbol, true))
     {
      PrintFormat("ERROR: símbolo %s no disponible", g_symbol);
      return INIT_FAILED;
     }
   if(InpEmaFast >= InpEmaSlow)
     {
      Print("ERROR: la EMA rápida debe ser menor que la lenta");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_digits     = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   g_point      = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   g_volMin     = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   g_volMax     = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   g_volStep    = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   g_stopsLevel = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(g_volStep <= 0.0 || g_volMin <= 0.0)
      return INIT_FAILED;
   g_volDigits = 0;
   double st = g_volStep;
   while(st < 1.0 - 1e-9 && g_volDigits < 8)
     {
      st *= 10.0;
      g_volDigits++;
     }

   g_hFast = iMA(g_symbol, InpTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow = iMA(g_symbol, InpTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hAtr  = iATR(g_symbol, InpTF, InpAtrPeriod);
   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE || g_hAtr == INVALID_HANDLE)
      return INIT_FAILED;

   g_hAdx = iADX(g_symbol, InpTF, InpAdxPeriod);
   g_hHtf = iMA(g_symbol, InpHTF, InpHTFEma, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hAdx == INVALID_HANDLE || g_hHtf == INVALID_HANDLE)
      return INIT_FAILED;
   if(PeriodSeconds(InpHTF) <= PeriodSeconds(InpTF))
      Print("ADVERTENCIA: InpHTF debería ser mayor que InpTF.");

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFillingBySymbol(g_symbol);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_NETTING)
      Print("ADVERTENCIA: cuenta NETTING. Las entradas se fusionan en una sola posición; la pirámide requiere cuenta HEDGING.");

   // Restaurar la vela de la última entrada si el EA se reinicia con posiciones abiertas
   datetime ult = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(EsMia(PositionGetTicket(i)))
        {
         datetime tt = (datetime)PositionGetInteger(POSITION_TIME);
         if(tt > ult)
            ult = tt;
        }
   if(ult > 0)
     {
      int sh = iBarShift(g_symbol, InpTF, ult, false);
      if(sh >= 0)
         g_lastEntryBar = iTime(g_symbol, InpTF, sh);
     }

   PrintFormat("PiramideH1 v2.1 | %s %s | maxPos=%d paso=%.1fATR SL=%.1fATR TP=%.1fATR trail=%.1fATR | riesgo %.1f%%/entrada, %.1f%% total",
               g_symbol, EnumToString(InpTF), InpMaxPositions, InpEntryStepAtr, InpSLAtr, InpTPAtr,
               InpTrailAtr, InpRiesgoPct, InpRiesgoMaxTotalPct);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_hFast != INVALID_HANDLE)
      IndicatorRelease(g_hFast);
   if(g_hSlow != INVALID_HANDLE)
      IndicatorRelease(g_hSlow);
   if(g_hAtr != INVALID_HANDLE)
      IndicatorRelease(g_hAtr);
   if(g_hAdx != INVALID_HANDLE)
      IndicatorRelease(g_hAdx);
   if(g_hHtf != INVALID_HANDLE)
      IndicatorRelease(g_hHtf);
  }

//+------------------------------------------------------------------+
//| BUCLE PRINCIPAL                                                  |
//+------------------------------------------------------------------+
void OnTick()
  {
   ControlDiario();
   if(ControlGrupo())
      return;

   datetime bar = iTime(g_symbol, InpTF, 0);
   if(bar == 0 || bar == g_lastBar)
      return;
   g_lastBar = bar;
   ProcesarVela(bar);
  }

//+------------------------------------------------------------------+
//| LÓGICA EN CADA VELA NUEVA                                        |
//+------------------------------------------------------------------+
void ProcesarVela(const datetime bar)
  {
   double A  = Leer(g_hAtr, 1);
   double f1 = Leer(g_hFast, 1);
   double s1 = Leer(g_hSlow, 1);
   double sN = (InpSlopeBars > 0) ? Leer(g_hSlow, 1 + InpSlopeBars) : s1;
   if(A <= 0.0 || f1 <= 0.0 || s1 <= 0.0 || sN <= 0.0)
      return;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(g_symbol, InpTF, 1, 1, r) != 1)
      return;

   int bias = FiltroCalidad(Sesgo(f1, s1, sN, A));

   // 1) Cambio de tendencia: cerrar la pirámide contraria
   if(InpCerrarEnCambio && bias != 0 && ContarPosiciones(-bias) > 0)
      CerrarDireccion(-bias, "cambio de tendencia");

   // 2) Trailing del stop común sobre el cierre de la vela anterior
   if(InpTrailAtr > 0.0)
     {
      if(ContarPosiciones(1) > 0)
         AjustarStopComun(1, r[0].close - InpTrailAtr * A);
      if(ContarPosiciones(-1) > 0)
         AjustarStopComun(-1, r[0].close + InpTrailAtr * A);
     }

   // 3) Nueva entrada
   if(bias == 0 || g_dayBlocked)
      return;
   if(!EntradaPermitida(bias, r[0], f1, A))
      return;
   AbrirPosicion(bias, A, bar);
  }

// Sesgo: separación mínima entre EMAs y pendiente de la lenta a favor
int Sesgo(const double f1, const double s1, const double sN, const double A)
  {
   if(MathAbs(f1 - s1) < A * InpMinEmaDiffAtr)
      return 0;
   bool pendAlcista = (InpSlopeBars <= 0) || (s1 > sN);
   bool pendBajista = (InpSlopeBars <= 0) || (s1 < sN);
   if(f1 > s1 && pendAlcista)
      return 1;
   if(f1 < s1 && pendBajista)
      return -1;
   return 0;
  }

// Anula el sesgo si la tendencia es débil (ADX) o va contra el timeframe superior
int FiltroCalidad(const int bias)
  {
   if(bias == 0)
      return 0;
   if(InpAdxMin > 0.0)
     {
      double adx = Leer(g_hAdx, 1);
      if(adx <= 0.0 || adx < InpAdxMin)
         return 0;
     }
   if(InpHTFSlopeBars > 0)
     {
      double e1 = Leer(g_hHtf, 1);
      double eN = Leer(g_hHtf, 1 + InpHTFSlopeBars);
      double c1 = iClose(g_symbol, InpHTF, 1);
      if(e1 <= 0.0 || eN <= 0.0 || c1 <= 0.0)
         return 0;
      if(bias > 0 && !(e1 > eN && c1 > e1))
         return 0;
      if(bias < 0 && !(e1 < eN && c1 < e1))
         return 0;
     }
   return bias;
  }

bool EntradaPermitida(const int bias, const MqlRates &v, const double f1, const double A)
  {
   // Pausa tras una pérdida
   if(InpVelasTrasPerdida > 0 && g_ultimaPerdida > 0)
     {
      int desde = iBarShift(g_symbol, InpTF, g_ultimaPerdida, false);
      if(desde >= 0 && desde < InpVelasTrasPerdida)
         return false;
     }

   if(SymbolInfoInteger(g_symbol, SYMBOL_SPREAD) > InpMaxSpreadPts)
      return false;

   if(InpViernesCorteHora >= 0)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.day_of_week == 5 && dt.hour >= InpViernesCorteHora)
         return false;
     }

   int nPos = ContarPosiciones(bias);
   if(nPos >= InpMaxPositions || ContarPosiciones(-bias) > 0)
      return false;

   // Cooldown contado en velas reales
   if(g_lastEntryBar > 0)
     {
      int velas = iBarShift(g_symbol, InpTF, g_lastEntryBar, false);
      if(velas >= 0 && velas < InpMinBarsBetween)
         return false;
     }

   if(nPos == 0)
     {
      // Primera entrada: pullback a la EMA rápida y cierre de rechazo a favor
      if(!InpRequierePullback)
         return true;
      if(bias > 0)
         return (v.low <= f1 + InpPullbackTolAtr * A && v.close > f1 && v.close > v.open);
      return (v.high >= f1 - InpPullbackTolAtr * A && v.close < f1 && v.close < v.open);
     }

   // Entradas adicionales: el precio avanzó el paso y la vela cerró a favor de la EMA rápida
   double ultima = UltimaEntrada(bias);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(bias > 0)
      return (bid - ultima >= InpEntryStepAtr * A && v.close > f1);
   return (ultima - ask >= InpEntryStepAtr * A && v.close < f1);
  }

//+------------------------------------------------------------------+
//| RIESGO Y EJECUCIÓN                                               |
//+------------------------------------------------------------------+
double CalcularLote(const int dir, const double px, const double sl)
  {
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0.0)
      return 0.0;

   double lote;
   if(InpLoteFijo > 0.0)
      lote = InpLoteFijo;
   else
     {
      double perdida1 = PerdidaDinero(dir, px, sl, 1.0);
      if(perdida1 <= 0.0)
         return 0.0;
      lote = bal * InpRiesgoPct / 100.0 / perdida1;
     }
   lote = MathFloor(lote / g_volStep + 1e-9) * g_volStep;
   lote = NormalizeDouble(MathMin(MathMax(lote, g_volMin), g_volMax), g_volDigits);

   double riesgo = PerdidaDinero(dir, px, sl, lote) / bal * 100.0;
   if(riesgo > InpRiesgoMaxLoteMin)
     {
      PrintFormat("Entrada omitida: lote %.2f arriesga %.2f%% (máx %.1f%%). Cuenta pequeña para este SL.",
                  lote, riesgo, InpRiesgoMaxLoteMin);
      return 0.0;
     }
   return lote;
  }

// Riesgo total del grupo si el stop común de 'dir' pasa a 'nuevoStop'
double RiesgoGrupoProyectado(const int dir, const double nuevoStop)
  {
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!EsMia(PositionGetTicket(i)))
         continue;
      int d = DirPos();
      double sl = PositionGetDouble(POSITION_SL);
      if(d == dir)
         sl = (sl == 0.0) ? nuevoStop : ((dir > 0) ? MathMax(sl, nuevoStop) : MathMin(sl, nuevoStop));
      if(sl == 0.0)
         continue;
      total += PerdidaDinero(d, PositionGetDouble(POSITION_PRICE_OPEN), sl, PositionGetDouble(POSITION_VOLUME));
     }
   return total;
  }

void AbrirPosicion(const int dir, const double A, const datetime bar)
  {
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick))
      return;
   double px = (dir > 0) ? tick.ask : tick.bid;
   double sl = NormalizeDouble(px - dir * InpSLAtr * A, g_digits);
   double tp = (InpTPAtr > 0.0) ? NormalizeDouble(px + dir * InpTPAtr * A, g_digits) : 0.0;

   double lote = CalcularLote(dir, px, sl);
   if(lote <= 0.0)
      return;

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double riesgoTotal = RiesgoGrupoProyectado(dir, sl) + PerdidaDinero(dir, px, sl, lote);
   if(riesgoTotal / bal * 100.0 > InpRiesgoMaxTotalPct)
     {
      PrintFormat("Entrada omitida: riesgo del grupo %.2f%% > %.1f%%", riesgoTotal / bal * 100.0, InpRiesgoMaxTotalPct);
      return;
     }

   int nPos = ContarPosiciones(dir);
   PrintFormat("ENTRADA %d/%d %s %.2f lotes @ %.2f | SL %.2f TP %.2f | ATR %.2f | riesgo grupo %.2f%%",
               nPos + 1, InpMaxPositions, dir > 0 ? "COMPRA" : "VENTA", lote, px, sl, tp, A,
               riesgoTotal / bal * 100.0);
   if(InpDryRun)
      return;

   bool ok = (dir > 0) ? g_trade.Buy(lote, g_symbol, 0.0, sl, tp, "pir v2")
             : g_trade.Sell(lote, g_symbol, 0.0, sl, tp, "pir v2");
   uint rc = g_trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
     {
      g_lastEntryBar = bar;
      AjustarStopComun(dir, sl);   // las posiciones anteriores suben al nuevo stop
     }
   else
      PrintFormat("Fallo al abrir: retcode=%u %s", rc, g_trade.ResultComment());
  }

// Mueve el SL de todas las posiciones de 'dir' a 'stop' solo si mejora
void AjustarStopComun(const int dir, double stop)
  {
   stop = NormalizeDouble(stop, g_digits);
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick))
      return;
   double minDist = g_stopsLevel * g_point;
   if(dir > 0 && tick.bid - stop < minDist)
      return;
   if(dir < 0 && stop - tick.ask < minDist)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(!EsMia(t) || DirPos() != dir)
         continue;
      double cur = PositionGetDouble(POSITION_SL);
      double tp  = PositionGetDouble(POSITION_TP);
      bool mejora = (dir > 0) ? (cur == 0.0 || stop > cur + g_point) : (cur == 0.0 || stop < cur - g_point);
      if(!mejora)
         continue;
      if(InpDryRun)
        {
         PrintFormat("[DRY] SL #%I64u %.2f -> %.2f", t, cur, stop);
         continue;
        }
      if(!g_trade.PositionModify(t, stop, tp))
         PrintFormat("Fallo al mover SL #%I64u: %u", t, g_trade.ResultRetcode());
     }
  }

void CerrarDireccion(const int dir, const string motivo)
  {
   PrintFormat("Cerrando %s: %s", dir > 0 ? "compras" : (dir < 0 ? "ventas" : "todo"), motivo);
   if(InpDryRun)
      return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(!EsMia(t))
         continue;
      if(dir != 0 && DirPos() != dir)
         continue;
      if(!g_trade.PositionClose(t))
         PrintFormat("Fallo al cerrar #%I64u: %u", t, g_trade.ResultRetcode());
     }
  }

//+------------------------------------------------------------------+
//| PROTECCIONES                                                     |
//+------------------------------------------------------------------+
// Cierre del grupo en ganancia (opcional, en % del balance)
bool ControlGrupo()
  {
   if(InpGroupTPPct <= 0.0 || ContarPosiciones(0) == 0)
      return false;
   double pnl = Flotante();
   double objetivo = AccountInfoDouble(ACCOUNT_BALANCE) * InpGroupTPPct / 100.0;
   if(pnl >= objetivo)
     {
      CerrarDireccion(0, StringFormat("TP de grupo %.2f >= %.2f", pnl, objetivo));
      return true;
     }
   return false;
  }

// Resultado realizado hoy por este EA (beneficio + swap + comisiones)
double CalcularRealizadoHoy()
  {
   if(!HistorySelect(g_day, TimeCurrent() + 60))
      return 0.0;
   double s = 0.0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetString(d, DEAL_SYMBOL) != g_symbol)
         continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != (long)InpMagic)
         continue;
      s += HistoryDealGetDouble(d, DEAL_COMMISSION);
      long e = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY || e == DEAL_ENTRY_INOUT)
         s += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP);
     }
   return s;
  }

// Pérdida diaria = realizada + flotante, en % del balance al inicio del día
void ControlDiario()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime hoy = StructToTime(dt);
   if(hoy != g_day)
     {
      g_day          = hoy;
      g_balanceDia   = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dayBlocked   = false;
      g_realizadoHoy = 0.0;
      g_ultCalcReal  = 0;
     }
   if(g_dayBlocked || g_balanceDia <= 0.0 || InpDailyMaxLossPct <= 0.0)
      return;

   // El historial se consulta como mucho cada 10 segundos (rendimiento)
   if(TimeCurrent() - g_ultCalcReal >= 10)
     {
      g_realizadoHoy = CalcularRealizadoHoy();
      g_ultCalcReal = TimeCurrent();
     }

   double resultado = g_realizadoHoy + Flotante();
   double limite = g_balanceDia * InpDailyMaxLossPct / 100.0;
   if(resultado <= -limite)
     {
      PrintFormat("PÉRDIDA DIARIA %.2f (límite -%.2f): se cierra todo y se bloquea el día", resultado, limite);
      CerrarDireccion(0, "pérdida diaria máxima");
      g_dayBlocked = true;
     }
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Registra la vela del último cierre en pérdida (para la pausa)    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)InpMagic)
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != g_symbol)
      return;
   long e = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(e != DEAL_ENTRY_OUT && e != DEAL_ENTRY_OUT_BY)
      return;
   double res = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   if(res < 0.0)
     {
      g_ultimaPerdida = iTime(g_symbol, InpTF, 0);
      g_ultCalcReal = 0;   // fuerza a recalcular la pérdida diaria
      if(InpVelasTrasPerdida > 0)
         PrintFormat("Cierre en pérdida %.2f: pausa de %d velas para nuevas entradas", res, InpVelasTrasPerdida);
     }
  }
//+------------------------------------------------------------------+