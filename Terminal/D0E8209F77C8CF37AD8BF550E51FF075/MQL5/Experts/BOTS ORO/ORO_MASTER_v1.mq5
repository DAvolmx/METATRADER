//+------------------------------------------------------------------------+
//|                                                     ORO_MASTER_v1.mq5   |
//|  EA SMC OPTIMIZADO PARA EL ORO (XAUUSD) — Timeframe objetivo M15/M30    |
//|  ---------------------------------------------------------------------  |
//|  Consolida lo mejor de tus 6 EAs de oro en uno solo:                    |
//|                                                                          |
//|   [de unnn / SMC_Lean]  Motor de Estructura BOS/CHoCH con swings         |
//|        confirmados SIN look-ahead (buffer circular, cero "ver el         |
//|        futuro" en backtest) + Fair Value Gap (FVG) + salida real por     |
//|        CHoCH en contra + filtro EMA de momentum + filtro de spread +     |
//|        cooldown entre trades.                                            |
//|   [de ORO3 / v4.0]      Sesgo direccional por EMA200 + PROTECCION        |
//|        ESCALONADA (Parcial 1 @1R -> breakeven, Parcial 2 @2R -> lock     |
//|        +1R) + trailing agresivo por ATR + ajuste de lote por margen.     |
//|   [NUEVO en esta version] ORDER BLOCKS: detecta la ultima vela opuesta   |
//|        antes del impulso que rompio la estructura (zona de oferta/       |
//|        demanda institucional) y la usa como (a) zona de retest y (b)     |
//|        referencia de Stop Loss estructural.                              |
//|   [NUEVO] Confirmacion de "micro-variacion": vela de rechazo + RSI de    |
//|        momentum en el retest, para entrar con el giro y no en el aire.   |
//|                                                                          |
//|  FILOSOFIA: la ESTRUCTURA (BOS/CHoCH) solo cambia con una ruptura        |
//|  confirmada; las EMAs y el RSI reaccionan vela a vela (la "micro-        |
//|  variacion"); el Order Block/FVG dan el PUNTO de entrada de bajo riesgo. |
//|  El SL siempre se coloca detras de la estructura real, no a ciegas.      |
//|                                                                          |
//|  ADVERTENCIA: codigo bien escrito != estrategia rentable. Backtestea     |
//|  con "cada tick basado en ticks reales" y haz forward en DEMO antes de   |
//|  operar en real. En M15/M30 el spread del oro pesa menos que en M1, pero |
//|  igual debe incluirse en la validacion.                                  |
//+------------------------------------------------------------------------+
#property copyright "David - Proyecto ORO"
#property version   "1.00"
#property description "EA SMC para XAUUSD (M15/M30): BOS/CHoCH sin look-ahead + Order Blocks + FVG,"
#property description "sesgo EMA200, parciales escalonados (BE/+1R), trailing ATR, salida por CHoCH,"
#property description "sizing por riesgo con tope de margen (OrderCalcMargin). Consolida ORO3 + unnn."

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------------+
//| INPUTS                                                                   |
//+------------------------------------------------------------------------+
input group "=== General ==="
input ulong    InpMagic               = 20260904;  // Magic number (identifica las posiciones de este EA)
input bool     InpTradingEnabled      = true;      // false = solo analiza y dibuja, no opera
input int      InpMaxPositions        = 1;         // Maximo de posiciones simultaneas de este EA
input int      InpMinBarsEntreTrades  = 2;         // Velas minimas entre operaciones (cooldown)
input double   InpMaxSpreadPoints     = 60.0;      // Spread maximo en puntos para operar (0 = sin filtro)
input bool     InpPrintDebug          = true;      // Logs [ORO] en el Journal

input group "=== Riesgo y Margen ==="
input double   InpRiskPercent         = 1.0;       // Riesgo por operacion (% del balance)
input double   InpMargenSeguridadPct  = 80.0;      // % del margen libre usable como tope (cuentas 1:1)
input bool     InpPermitirLoteMinimo  = true;      // Abrir con lote minimo si el riesgo pide menos

input group "=== Estructura de Mercado (BOS/CHoCH) ==="
input int      InpSwingWindow         = 5;         // Velas a cada lado para confirmar un swing (fractal). 5 = robusto en M15/M30
input int      InpHistorialInicial    = 600;       // Velas historicas para precalentar la estructura al iniciar
input int      InpMaxHistorial        = 300;       // Maximo de swings guardados por lado
input bool     InpCerrarPorCHoCH      = true;      // Cerrar la posicion si aparece un CHoCH en contra

input group "=== Sesgo direccional (EMA200) ==="
input int      InpEMA_Filter          = 200;       // EMA de sesgo macro
input double   InpContraTendRiskFactor= 0.5;       // Riesgo relativo CONTRA la EMA200 (1=sin sesgo, 0.5=mitad, 0=no operar contra)

input group "=== Filtro EMA de momentum (corto plazo) ==="
input bool     InpUsarFiltroEMA       = true;      // Exigir que EMA20/50 confirmen la direccion
input int      InpEMA_Fast            = 20;        // EMA rapida
input int      InpEMA_Slow            = 50;        // EMA lenta

input group "=== Order Blocks + FVG (zona de entrada) ==="
input bool     InpUsarOrderBlocks     = true;      // Detectar y usar Order Blocks como zona/SL
input int      InpOB_MaxLookback      = 30;        // Velas hacia atras para buscar el Order Block del impulso
input bool     InpUsarFVG             = true;      // Aceptar un Fair Value Gap como confirmacion alternativa
input double   InpRetestBufferATR     = 0.35;      // Colchon ATR alrededor del nivel/zona de retest
input int      InpRetestMaxVelas      = 20;        // Velas maximas esperando el retest antes de cancelar
input bool     InpUsarRetest          = true;      // false = entra apenas confirma BOS/CHoCH (sin esperar retroceso)

input group "=== Micro-confirmacion en el retest ==="
input bool     InpUsarRSI             = true;      // Exigir cruce de RSI (momentum) en la vela de entrada
input int      InpRSI_Period          = 14;        // Periodo RSI
input double   InpRSI_Nivel           = 50.0;      // Nivel medio del RSI

input group "=== Salida: SL/TP, parciales y trailing (ATR) ==="
input int      InpATR_Period          = 14;        // Periodo ATR
input double   InpATR_SL_Mult         = 1.8;       // SL = ATR x este factor (o detras del Order Block, el mas amplio)
input double   InpTP_RatioSL          = 3.0;       // TP final = SL x este ratio (techo del runner)
input double   InpParcial1_R          = 1.0;       // Nivel 1 en multiplos de R
input double   InpParcial1_Pct        = 40.0;      // % del lote ORIGINAL a cerrar en P1
input bool     InpMoverBE_en_P1       = true;      // Mover SL a breakeven al alcanzar P1
input double   InpParcial2_R          = 2.0;       // Nivel 2 en multiplos de R
input double   InpParcial2_Pct        = 30.0;      // % del lote ORIGINAL a cerrar en P2
input bool     InpMoverLock_en_P2     = true;      // Mover SL a +1R al alcanzar P2
input double   InpTrailStartR         = 2.0;       // A partir de cuantos R arranca el trailing
input double   InpTrailATRMult        = 1.0;       // Distancia del trailing en ATR

input group "=== Panel visual ==="
input bool     InpMostrarPanel        = true;      // Mostrar panel de estado en el grafico

//+------------------------------------------------------------------------+
//| TIPOS Y ESTADO DE LA ESTRUCTURA (port validado de unnn/SMC_Lean)        |
//+------------------------------------------------------------------------+
enum ENUM_SWING_KIND { EST_LOW = 0, EST_HIGH = 1 };

struct SwingPoint
{
   int    barIdx;
   double price;
   int    kind;
   string label;
   bool   broken;
   bool   valido;
};

struct EstructuraEvento
{
   bool   hay;
   string tipo;        // "BOS" | "CHoCH" | "TENDENCIA_INICIAL"
   string direccion;   // "ALCISTA" | "BAJISTA"
   double nivel;       // precio del nivel roto
   double cierre;      // cierre de la vela que rompio
   int    idxRuptura;  // indice interno de la vela que rompio
};

int         g_estIndiceActual      = -1;
int         g_estProximoCandidato  = 0;
int         g_estBufSize           = 0;
int         g_estVentana           = 5;
double      g_estBufH[];
double      g_estBufL[];
SwingPoint  g_estSwingHighs[];
SwingPoint  g_estSwingLows[];
SwingPoint  g_estHighWatch;
SwingPoint  g_estLowWatch;
string      g_estTendencia = "";

//--- Zona pendiente de retest (incluye Order Block)
bool        g_pendActivo         = false;
string      g_pendDireccion      = "";
double      g_pendNivelRoto       = 0;
double      g_pendZonaMin         = 0;
double      g_pendZonaMax         = 0;
double      g_pendOB_min          = 0;   // limites del Order Block (0 = no hay OB)
double      g_pendOB_max          = 0;
double      g_pendStructSL        = 0;   // SL estructural sugerido (detras del OB / swing)
int         g_pendVelasEsperando  = 0;

//--- Handles de indicadores
int         g_hATR    = INVALID_HANDLE;
int         g_hEMAf   = INVALID_HANDLE;
int         g_hEMAs   = INVALID_HANDLE;
int         g_hEMA200 = INVALID_HANDLE;
int         g_hRSI    = INVALID_HANDLE;

datetime    g_ultimaVelaTime  = 0;
int         g_ultimaVelaSenal = -1000000;
int         g_totalOperaciones = 0;

//--- Estado de la posicion gestionada (1 posicion por vez por diseno)
ulong       g_ticket      = 0;
double      g_riskDist     = 0.0;
double      g_openPrice    = 0.0;
double      g_origVolume   = 0.0;
bool        g_p1_done      = false;
bool        g_p2_done      = false;

//+------------------------------------------------------------------------+
//| MOTOR DE ESTRUCTURA (identico a unnn: swings confirmados con retraso)   |
//+------------------------------------------------------------------------+
void EstEtiquetar(SwingPoint &sp, const SwingPoint &hist[])
{
   int n = ArraySize(hist);
   if(n == 0) { sp.label = (sp.kind == EST_HIGH) ? "H0" : "L0"; return; }
   SwingPoint ant = hist[n - 1];
   if(sp.kind == EST_HIGH) sp.label = (sp.price > ant.price) ? "HH" : "LH";
   else                    sp.label = (sp.price > ant.price) ? "HL" : "LL";
}

void EstActualizarPuntero(SwingPoint &sp)
{
   if(sp.kind == EST_HIGH)
   {
      if(g_estTendencia != "ALCISTA") g_estHighWatch = sp;
      else if(!g_estHighWatch.valido || g_estHighWatch.broken) g_estHighWatch = sp;
   }
   else
   {
      if(g_estTendencia != "BAJISTA") g_estLowWatch = sp;
      else if(!g_estLowWatch.valido || g_estLowWatch.broken) g_estLowWatch = sp;
   }
}

void EstRecortar(SwingPoint &arr[])
{
   int n = ArraySize(arr);
   if(InpMaxHistorial < 2 || n <= InpMaxHistorial) return;
   int exceso = n - InpMaxHistorial;
   for(int i = 0; i < InpMaxHistorial; i++) arr[i] = arr[i + exceso];
   ArrayResize(arr, InpMaxHistorial);
}

void EstAppend(SwingPoint &arr[], SwingPoint &sp)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = sp;
   EstRecortar(arr);
}

void EstConfirmarCandidato(int cand)
{
   int ventana = g_estVentana;
   if(cand < ventana) return;
   int bufSize = g_estBufSize;

   double maxV = g_estBufH[cand % bufSize];
   double minV = g_estBufL[cand % bufSize];
   for(int k = cand - ventana; k <= cand + ventana; k++)
   {
      double hh = g_estBufH[k % bufSize];
      double ll = g_estBufL[k % bufSize];
      if(hh > maxV) maxV = hh;
      if(ll < minV) minV = ll;
   }
   int cMax = 0, cMin = 0;
   for(int k = cand - ventana; k <= cand + ventana; k++)
   {
      if(g_estBufH[k % bufSize] == maxV) cMax++;
      if(g_estBufL[k % bufSize] == minV) cMin++;
   }
   double vH = g_estBufH[cand % bufSize];
   double vL = g_estBufL[cand % bufSize];

   if(vH == maxV && cMax == 1)
   {
      SwingPoint sp; sp.barIdx = cand; sp.price = vH; sp.kind = EST_HIGH; sp.broken = false; sp.valido = true; sp.label = "";
      EstEtiquetar(sp, g_estSwingHighs);
      EstAppend(g_estSwingHighs, sp);
      EstActualizarPuntero(sp);
   }
   if(vL == minV && cMin == 1)
   {
      SwingPoint sp; sp.barIdx = cand; sp.price = vL; sp.kind = EST_LOW; sp.broken = false; sp.valido = true; sp.label = "";
      EstEtiquetar(sp, g_estSwingLows);
      EstAppend(g_estSwingLows, sp);
      EstActualizarPuntero(sp);
   }
}

EstructuraEvento EstRevisarRuptura(double close)
{
   EstructuraEvento ev;
   ev.hay = false; ev.tipo = ""; ev.direccion = ""; ev.nivel = 0; ev.cierre = close; ev.idxRuptura = g_estIndiceActual;

   if(g_estHighWatch.valido && !g_estHighWatch.broken && close > g_estHighWatch.price)
   {
      g_estHighWatch.broken = true;
      ev.tipo = (g_estTendencia == "") ? "TENDENCIA_INICIAL" : (g_estTendencia == "ALCISTA" ? "BOS" : "CHoCH");
      ev.hay = true; ev.direccion = "ALCISTA"; ev.nivel = g_estHighWatch.price;
      g_estTendencia = "ALCISTA";
      return ev;
   }
   if(g_estLowWatch.valido && !g_estLowWatch.broken && close < g_estLowWatch.price)
   {
      g_estLowWatch.broken = true;
      ev.tipo = (g_estTendencia == "") ? "TENDENCIA_INICIAL" : (g_estTendencia == "BAJISTA" ? "BOS" : "CHoCH");
      ev.hay = true; ev.direccion = "BAJISTA"; ev.nivel = g_estLowWatch.price;
      g_estTendencia = "BAJISTA";
      return ev;
   }
   return ev;
}

EstructuraEvento EstActualizar(double o, double h, double l, double c)
{
   g_estIndiceActual++;
   int bufIdx = g_estIndiceActual % g_estBufSize;
   g_estBufH[bufIdx] = h;
   g_estBufL[bufIdx] = l;
   while(g_estProximoCandidato + g_estVentana <= g_estIndiceActual)
   {
      EstConfirmarCandidato(g_estProximoCandidato);
      g_estProximoCandidato++;
   }
   return EstRevisarRuptura(c);
}

void EstInicializarHistorial()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copiadas = CopyRates(_Symbol, _Period, 1, InpHistorialInicial, rates);
   if(copiadas <= 0)
   {
      Print("[ORO] Aviso: no se pudo precalentar la estructura (CopyRates=0).");
      return;
   }
   for(int i = 0; i < copiadas; i++)
      EstActualizar(rates[i].open, rates[i].high, rates[i].low, rates[i].close);
   PrintFormat("[ORO] Estructura precalentada con %d velas -> tendencia=%s, altos=%d, bajos=%d",
               copiadas, (g_estTendencia == "") ? "sin definir" : g_estTendencia,
               ArraySize(g_estSwingHighs), ArraySize(g_estSwingLows));
}

//+------------------------------------------------------------------------+
//| ORDER BLOCK: ultima vela opuesta antes del impulso que rompio          |
//| Devuelve true si encontro OB. Rellena obMin/obMax/structSL.            |
//| Alcista -> demanda: ultima vela BAJISTA (close<open) antes del alza.   |
//| Bajista -> oferta:  ultima vela ALCISTA (close>open) antes de la baja. |
//+------------------------------------------------------------------------+
bool DetectarOrderBlock(string direccion, double &obMin, double &obMax, double &structSL)
{
   obMin = 0; obMax = 0; structSL = 0;
   if(!InpUsarOrderBlocks) return false;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, _Period, 1, InpOB_MaxLookback, r); // desde la vela cerrada hacia atras
   if(n <= 2) return false;

   // Buscamos la ultima vela del color opuesto al impulso, empezando por la mas reciente.
   for(int i = 0; i < n; i++)
   {
      bool velaBajista = (r[i].close < r[i].open);
      bool velaAlcista = (r[i].close > r[i].open);

      if(direccion == "ALCISTA" && velaBajista)
      {
         obMin    = r[i].low;
         obMax    = r[i].high;
         structSL = r[i].low;   // SL estructural: debajo del Order Block de demanda
         return true;
      }
      if(direccion == "BAJISTA" && velaAlcista)
      {
         obMin    = r[i].low;
         obMax    = r[i].high;
         structSL = r[i].high;  // SL estructural: arriba del Order Block de oferta
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------------+
//| FAIR VALUE GAP de 3 velas (rates con ArraySetAsSeries(true))            |
//| Alcista: high[i-2] < low[i]  |  Bajista: low[i-2] > high[i]             |
//+------------------------------------------------------------------------+
bool HayFVGaFavor(string direccion, const MqlRates &rates[])
{
   if(ArraySize(rates) < 4) return false;
   if(direccion == "ALCISTA") return (rates[3].high < rates[1].low);
   if(direccion == "BAJISTA") return (rates[3].low  > rates[1].high);
   return false;
}

//+------------------------------------------------------------------------+
//| Arma la zona de retest tras un BOS/CHoCH: Fibonacci 50-61.8 + colchon   |
//| ATR + (si hay) el Order Block. Guarda tambien el SL estructural.        |
//+------------------------------------------------------------------------+
void ArmarPendiente(const EstructuraEvento &ev, double atr)
{
   double bufferATR = MathMax(atr, 0) * InpRetestBufferATR;
   double zonaMin = ev.nivel - bufferATR;
   double zonaMax = ev.nivel + bufferATR;

   // Zona Fibonacci del tramo impulsivo (descuento/premium SMC)
   bool hayLeg = false; double leg = 0;
   if(ev.direccion == "ALCISTA" && ArraySize(g_estSwingLows) > 0)
   { leg = ev.cierre - g_estSwingLows[ArraySize(g_estSwingLows) - 1].price; hayLeg = (leg > 0); }
   else if(ev.direccion == "BAJISTA" && ArraySize(g_estSwingHighs) > 0)
   { leg = g_estSwingHighs[ArraySize(g_estSwingHighs) - 1].price - ev.cierre; hayLeg = (leg > 0); }

   if(hayLeg)
   {
      double fibMin, fibMax;
      if(ev.direccion == "ALCISTA") { fibMin = ev.cierre - leg * 0.618; fibMax = ev.cierre - leg * 0.5; }
      else                          { fibMin = ev.cierre + leg * 0.5;   fibMax = ev.cierre + leg * 0.618; }
      zonaMin = MathMin(zonaMin, fibMin);
      zonaMax = MathMax(zonaMax, fibMax);
   }

   // Order Block: amplia la zona de retest para incluirlo y fija el SL estructural
   double obMin, obMax, structSL;
   bool hayOB = DetectarOrderBlock(ev.direccion, obMin, obMax, structSL);
   if(hayOB)
   {
      zonaMin = MathMin(zonaMin, obMin);
      zonaMax = MathMax(zonaMax, obMax);
      g_pendOB_min = obMin; g_pendOB_max = obMax; g_pendStructSL = structSL;
   }
   else { g_pendOB_min = 0; g_pendOB_max = 0; g_pendStructSL = 0; }

   g_pendDireccion     = ev.direccion;
   g_pendNivelRoto     = ev.nivel;
   g_pendZonaMin       = zonaMin;
   g_pendZonaMax       = zonaMax;
   g_pendVelasEsperando= 0;
   g_pendActivo        = true;

   if(InpPrintDebug)
      PrintFormat("[ORO] %s %s @ %.2f -> zona retest [%.2f-%.2f] %s",
                  ev.tipo, ev.direccion, ev.nivel, zonaMin, zonaMax,
                  hayOB ? StringFormat("| OB [%.2f-%.2f] SLstruct=%.2f", obMin, obMax, structSL) : "| sin OB");
}

//+------------------------------------------------------------------------+
//| Revisa la zona de retest. Devuelve true SOLO en la vela de confirmacion |
//| Confirmacion = toco la zona Y (reclamo del nivel O FVG O rechazo en OB) |
//| Y (si InpUsarRSI) cruce de RSI de momentum a favor.                     |
//+------------------------------------------------------------------------+
bool RevisarRetest(const MqlRates &rates[], string &direccionOut)
{
   direccionOut = "";
   if(!g_pendActivo) return false;

   g_pendVelasEsperando++;
   if(g_pendVelasEsperando > InpRetestMaxVelas)
   {
      if(InpPrintDebug)
         PrintFormat("[ORO] Zona %s [%.2f-%.2f] expiro tras %d velas.",
                     g_pendDireccion, g_pendZonaMin, g_pendZonaMax, InpRetestMaxVelas);
      g_pendActivo = false;
      return false;
   }

   MqlRates r1 = rates[1]; // vela cerrada
   bool tocoZona = (r1.low <= g_pendZonaMax && r1.high >= g_pendZonaMin);
   if(!tocoZona) return false;

   bool reclamoNivel = (g_pendDireccion == "ALCISTA") ? (r1.close > g_pendNivelRoto) : (r1.close < g_pendNivelRoto);
   bool fvg          = InpUsarFVG && HayFVGaFavor(g_pendDireccion, rates);

   // Vela de rechazo dentro/desde la zona (micro-variacion: el precio rechaza el OB)
   bool rechazo = (g_pendDireccion == "ALCISTA") ? (r1.close > r1.open) : (r1.close < r1.open);

   if(!(reclamoNivel || fvg || rechazo)) return false;

   // Micro-confirmacion por RSI (momentum girando a favor)
   if(InpUsarRSI)
   {
      double rsi[2];
      ArraySetAsSeries(rsi, true);                 // rsi[0]=vela cerrada (shift1), rsi[1]=anterior (shift2)
      if(CopyBuffer(g_hRSI, 0, 1, 2, rsi) < 2) return false;
      bool cruzaArriba = (rsi[1] <= InpRSI_Nivel) && (rsi[0] > InpRSI_Nivel);
      bool cruzaAbajo  = (rsi[1] >= InpRSI_Nivel) && (rsi[0] < InpRSI_Nivel);
      bool okRSI = (g_pendDireccion == "ALCISTA") ? (cruzaArriba || rsi[0] > InpRSI_Nivel)
                                                   : (cruzaAbajo  || rsi[0] < InpRSI_Nivel);
      if(!okRSI) return false;
   }

   if(InpPrintDebug)
      PrintFormat("[ORO] Retest %s CONFIRMADO en [%.2f-%.2f] (reclamo=%s FVG=%s rechazo=%s)",
                  g_pendDireccion, g_pendZonaMin, g_pendZonaMax,
                  reclamoNivel?"SI":"no", fvg?"SI":"no", rechazo?"SI":"no");
   direccionOut = g_pendDireccion;
   g_pendActivo = false;
   return true;
}

string RetestTexto()
{
   if(g_pendActivo)
      return "esperando (" + IntegerToString(g_pendVelasEsperando) + "/" + IntegerToString(InpRetestMaxVelas) +
             ") en [" + DoubleToString(g_pendZonaMin, 2) + "-" + DoubleToString(g_pendZonaMax, 2) + "]";
   return "sin zona activa";
}

//+------------------------------------------------------------------------+
//| RIESGO Y MARGEN (patron validado de unnn/ORO3)                          |
//+------------------------------------------------------------------------+
double NormalizarLote(double lot)
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st > 0) lot = MathFloor(lot / st) * st;
   if(lot < mn) lot = mn;
   if(lot > mx) lot = mx;
   return lot;
}

double CalcularLotesPorRiesgo(double slDistPrecio, double riskPct)
{
   if(slDistPrecio <= 0 || riskPct <= 0) return 0;
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riesgoUSD = balance * (riskPct / 100.0);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0 || tv <= 0) return 0;
   double valorPorPrecio = tv / ts;
   if(valorPorPrecio <= 0) return 0;
   double lotes = riesgoUSD / (slDistPrecio * valorPorPrecio);
   return NormalizarLote(lotes);
}

double AjustarLotesPorMargen(double lotesDeseados, ENUM_ORDER_TYPE tipo, double precio)
{
   if(lotesDeseados <= 0) return 0;
   double margenNecesario = 0;
   if(!OrderCalcMargin(tipo, _Symbol, lotesDeseados, precio, margenNecesario))
   {
      if(InpPrintDebug) PrintFormat("[ORO] OrderCalcMargin fallo (%d); se usa lote sin ajustar.", GetLastError());
      return lotesDeseados;
   }
   double margenLibre  = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double margenUsable = margenLibre * (InpMargenSeguridadPct / 100.0);
   if(margenNecesario <= margenUsable) return lotesDeseados;

   double margenPorLote = margenNecesario / lotesDeseados;
   if(margenPorLote <= 0) return 0;
   double lotesAjust = NormalizarLote(margenUsable / margenPorLote);
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   if(lotesAjust < mn)
   {
      double margenMin = 0; OrderCalcMargin(tipo, _Symbol, mn, precio, margenMin);
      if(InpPermitirLoteMinimo && margenMin <= margenLibre)
      {
         if(InpPrintDebug) PrintFormat("[ORO] Ajustado al lote MINIMO %.2f (pedia %.2f).", mn, lotesDeseados);
         return mn;
      }
      if(InpPrintDebug) PrintFormat("[ORO] Cancelado: ni el lote minimo (%.2f) entra en margen (libre=%.2f).", mn, margenLibre);
      return 0;
   }
   if(InpPrintDebug) PrintFormat("[ORO] Lote recortado por margen: %.2f -> %.2f (usable=%.2f).", lotesDeseados, lotesAjust, margenUsable);
   return lotesAjust;
}

//+------------------------------------------------------------------------+
//| GESTION: parciales escalonados + breakeven/lock + trailing (de ORO3)    |
//+------------------------------------------------------------------------+
ulong ObtenerMiPosicion()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         return ticket;
   }
   return 0;
}

void ResetEstadoPosicion()
{
   g_ticket = 0; g_riskDist = 0.0; g_openPrice = 0.0; g_origVolume = 0.0;
   g_p1_done = false; g_p2_done = false;
}

void ModificarSL(ulong ticket, double nuevoSL, double tp, string motivo)
{
   nuevoSL = NormalizeDouble(nuevoSL, _Digits);
   if(PositionSelectByTicket(ticket))
   {
      double slCur = PositionGetDouble(POSITION_SL);
      if(MathAbs(slCur - nuevoSL) < _Point) return;
   }
   if(trade.PositionModify(ticket, nuevoSL, tp))
   { if(InpPrintDebug) PrintFormat("[ORO] SL -> %.2f (%s).", nuevoSL, motivo); }
   else
   { if(InpPrintDebug) PrintFormat("[ORO] No se pudo mover SL a %.2f (%s, err %d).", nuevoSL, motivo, GetLastError()); }
}

bool CerrarParcial(ulong ticket, double pctOriginal, string etiqueta)
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double cerrar = g_origVolume * (pctOriginal / 100.0);
   if(st > 0) cerrar = MathFloor(cerrar / st) * st;
   double volAct = PositionGetDouble(POSITION_VOLUME);
   double reman  = volAct - cerrar;
   if(cerrar < mn || reman < mn || cerrar > volAct)
   {
      if(InpPrintDebug)
         PrintFormat("[ORO] %s: lote %.2f no permite parcial %.0f%% (cerrar=%.2f reman=%.2f min=%.2f). Se protege solo con SL.",
                     etiqueta, volAct, pctOriginal, cerrar, reman, mn);
      return false;
   }
   if(trade.PositionClosePartial(ticket, cerrar))
   { if(InpPrintDebug) PrintFormat("[ORO] %s: parcial %.2f lotes (%.0f%%). Remanente=%.2f", etiqueta, cerrar, pctOriginal, reman); return true; }
   if(InpPrintDebug) PrintFormat("[ORO] %s: fallo parcial (err %d).", etiqueta, GetLastError());
   return false;
}

void GestionarPosicion(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;

   if(g_ticket != ticket)
   {
      g_ticket     = ticket;
      g_openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double slIni = PositionGetDouble(POSITION_SL);
      g_origVolume = PositionGetDouble(POSITION_VOLUME);
      g_riskDist   = (slIni > 0) ? MathAbs(g_openPrice - slIni) : 0.0;
      g_p1_done = false; g_p2_done = false;
      if(g_riskDist <= 0 && InpPrintDebug)
         Print("[ORO] Posicion sin SL valido: no se puede medir R.");
   }
   if(g_riskDist <= 0) return;

   double atrV[1];
   if(CopyBuffer(g_hATR, 0, 0, 1, atrV) < 1) return;

   long   tipo = PositionGetInteger(POSITION_TYPE);
   double tp   = PositionGetDouble(POSITION_TP);
   double slAct= PositionGetDouble(POSITION_SL);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(tipo == POSITION_TYPE_BUY)
   {
      double R = (bid - g_openPrice) / g_riskDist;
      if(!g_p1_done && R >= InpParcial1_R)
      { CerrarParcial(ticket, InpParcial1_Pct, "P1(1R)"); g_p1_done = true; if(InpMoverBE_en_P1) ModificarSL(ticket, g_openPrice, tp, "breakeven"); }
      if(!g_p2_done && R >= InpParcial2_R)
      { CerrarParcial(ticket, InpParcial2_Pct, "P2(2R)"); g_p2_done = true; if(InpMoverLock_en_P2) ModificarSL(ticket, g_openPrice + g_riskDist, tp, "lock +1R"); }
      if(R >= InpTrailStartR && atrV[0] > 0)
      {
         double nuevo = NormalizeDouble(bid - atrV[0] * InpTrailATRMult, _Digits);
         if(nuevo > slAct) ModificarSL(ticket, nuevo, tp, "trailing");
      }
   }
   else if(tipo == POSITION_TYPE_SELL)
   {
      double R = (g_openPrice - ask) / g_riskDist;
      if(!g_p1_done && R >= InpParcial1_R)
      { CerrarParcial(ticket, InpParcial1_Pct, "P1(1R)"); g_p1_done = true; if(InpMoverBE_en_P1) ModificarSL(ticket, g_openPrice, tp, "breakeven"); }
      if(!g_p2_done && R >= InpParcial2_R)
      { CerrarParcial(ticket, InpParcial2_Pct, "P2(2R)"); g_p2_done = true; if(InpMoverLock_en_P2) ModificarSL(ticket, g_openPrice - g_riskDist, tp, "lock +1R"); }
      if(R >= InpTrailStartR && atrV[0] > 0)
      {
         double nuevo = NormalizeDouble(ask + atrV[0] * InpTrailATRMult, _Digits);
         if(nuevo < slAct || slAct == 0) ModificarSL(ticket, nuevo, tp, "trailing");
      }
   }
}

//--- Salida real por CHoCH en contra
void CerrarSiContrario(string direccionNueva)
{
   ulong t = ObtenerMiPosicion();
   if(t == 0) return;
   if(!PositionSelectByTicket(t)) return;
   bool esCompra = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   if((esCompra && direccionNueva == "BAJISTA") || (!esCompra && direccionNueva == "ALCISTA"))
   {
      trade.PositionClose(t);
      if(InpPrintDebug) PrintFormat("[ORO] Posicion cerrada por CHoCH %s en contra.", direccionNueva);
   }
}

//+------------------------------------------------------------------------+
//| APERTURA: SL = max(ATR, estructural del OB) ; TP = SL x ratio           |
//+------------------------------------------------------------------------+
void AbrirOperacion(ENUM_ORDER_TYPE tipo, double atr, double ask, double bid, double riskPct, double structSL)
{
   bool esCompra = (tipo == ORDER_TYPE_BUY);
   double precio = esCompra ? ask : bid;

   double slDistATR = atr * InpATR_SL_Mult;
   double slDist    = slDistATR;

   // Si hay SL estructural (Order Block), usa el mas amplio de los dos (mas seguro)
   if(structSL > 0)
   {
      double distStruct = esCompra ? (precio - structSL) : (structSL - precio);
      if(distStruct > 0) slDist = MathMax(slDistATR, distStruct);
   }
   if(slDist <= 0) return;

   double sl = NormalizeDouble(esCompra ? (precio - slDist) : (precio + slDist), _Digits);
   double tp = NormalizeDouble(esCompra ? (precio + slDist * InpTP_RatioSL) : (precio - slDist * InpTP_RatioSL), _Digits);

   double lotes = CalcularLotesPorRiesgo(slDist, riskPct);
   lotes = AjustarLotesPorMargen(lotes, tipo, precio);
   if(lotes <= 0) { if(InpPrintDebug) Print("[ORO] Cancelado: lotaje invalido (ver margen)."); return; }

   bool ok = esCompra ? trade.Buy(lotes, _Symbol, ask, sl, tp, "ORO_MASTER")
                       : trade.Sell(lotes, _Symbol, bid, sl, tp, "ORO_MASTER");
   if(!ok)
   { PrintFormat("[ORO] Error al abrir %s: %d - %s", esCompra?"COMPRA":"VENTA", trade.ResultRetcode(), trade.ResultRetcodeDescription()); return; }

   g_totalOperaciones++;
   if(InpPrintDebug)
      PrintFormat("[ORO] %s: entrada=%.2f SL=%.2f TP=%.2f lotes=%.2f (riesgo=%.2f%%, distSL=%.2f)",
                  esCompra?"COMPRA":"VENTA", precio, sl, tp, lotes, riskPct, slDist);
}

//+------------------------------------------------------------------------+
//| PANEL                                                                    |
//+------------------------------------------------------------------------+
void ActualizarPanel(double atr, string dirSenal)
{
   if(!InpMostrarPanel) return;
   string linea = (dirSenal != "") ? ("SENAL " + dirSenal + " esta vela")
                : (InpUsarRetest ? RetestTexto() : "esperando BOS/CHoCH");
   double emaF[1], emaS[1], ema200[1];
   CopyBuffer(g_hEMAf, 0, 1, 1, emaF);
   CopyBuffer(g_hEMAs, 0, 1, 1, emaS);
   CopyBuffer(g_hEMA200, 0, 1, 1, ema200);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   string sesgo = (bid > ema200[0]) ? "ALCISTA (precio>EMA200)" : "BAJISTA (precio<EMA200)";
   double spreadPts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - bid) / _Point;

   string txt = "=== ORO MASTER v1.0 (M15/M30) ===\n";
   txt += StringFormat("Estructura: %s\n", (g_estTendencia=="")?"sin definir":g_estTendencia);
   txt += "Retest/Senal: " + linea + "\n";
   txt += StringFormat("Sesgo EMA200: %s\n", sesgo);
   txt += StringFormat("EMA %d/%d: %s\n", InpEMA_Fast, InpEMA_Slow, (emaF[0]>emaS[0])?"alcista":"bajista");
   if(g_pendOB_max > 0) txt += StringFormat("Order Block: [%.2f-%.2f]\n", g_pendOB_min, g_pendOB_max);
   txt += StringFormat("Spread: %.0f pts | Pos: %d/%d | ATR: %.2f\n", spreadPts, (ObtenerMiPosicion()>0)?1:0, InpMaxPositions, atr);
   txt += StringFormat("Balance: %.2f | Margen libre: %.2f | Trading: %s",
                       AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_MARGIN_FREE),
                       InpTradingEnabled?"ON":"SOLO ANALISIS");
   Comment(txt);
}

//+------------------------------------------------------------------------+
//| CICLO DE VIDA                                                            |
//+------------------------------------------------------------------------+
int OnInit()
{
   // Aviso de timeframe recomendado (no bloquea, solo informa)
   if(_Period != PERIOD_M15 && _Period != PERIOD_M30)
      Print("[ORO] AVISO: EA disenado para M15/M30. TF actual = ", EnumToString((ENUM_TIMEFRAMES)_Period));

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_hATR    = iATR(_Symbol, _Period, InpATR_Period);
   g_hEMAf   = iMA(_Symbol, _Period, InpEMA_Fast,   0, MODE_EMA, PRICE_CLOSE);
   g_hEMAs   = iMA(_Symbol, _Period, InpEMA_Slow,   0, MODE_EMA, PRICE_CLOSE);
   g_hEMA200 = iMA(_Symbol, _Period, InpEMA_Filter, 0, MODE_EMA, PRICE_CLOSE);
   g_hRSI    = iRSI(_Symbol, _Period, InpRSI_Period, PRICE_CLOSE);
   if(g_hATR==INVALID_HANDLE || g_hEMAf==INVALID_HANDLE || g_hEMAs==INVALID_HANDLE ||
      g_hEMA200==INVALID_HANDLE || g_hRSI==INVALID_HANDLE)
   { Print("[ORO] Error cargando indicadores."); return(INIT_FAILED); }

   // Reinicio explicito de todo el estado (re-init suave del Tester al cambiar inputs)
   g_estIndiceActual = -1; g_estProximoCandidato = 0; g_estTendencia = "";
   g_estHighWatch.valido = false; g_estLowWatch.valido = false;
   ArrayResize(g_estSwingHighs, 0); ArrayResize(g_estSwingLows, 0);
   g_pendActivo = false; g_pendOB_min = 0; g_pendOB_max = 0; g_pendStructSL = 0;
   g_ultimaVelaTime = 0; g_ultimaVelaSenal = -1000000; g_totalOperaciones = 0;
   ResetEstadoPosicion();

   g_estVentana = MathMax(1, InpSwingWindow);
   g_estBufSize = 2 * g_estVentana + 1;
   ArrayResize(g_estBufH, g_estBufSize);
   ArrayResize(g_estBufL, g_estBufSize);

   EstInicializarHistorial();
   PrintFormat("[ORO] ORO_MASTER v1.0 iniciado en %s %s. Trading=%s",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period), InpTradingEnabled?"ON":"OFF");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   IndicatorRelease(g_hATR);
   IndicatorRelease(g_hEMAf);
   IndicatorRelease(g_hEMAs);
   IndicatorRelease(g_hEMA200);
   IndicatorRelease(g_hRSI);
   Comment("");
   PrintFormat("[ORO] Detenido. Operaciones abiertas esta sesion: %d", g_totalOperaciones);
}

void OnTick()
{
   // 1) Gestion de la posicion viva (corre en cada tick: parciales/BE/trailing)
   ulong miTicket = ObtenerMiPosicion();
   if(miTicket > 0) GestionarPosicion(miTicket);
   else             ResetEstadoPosicion();

   // 2) Resto de la logica: una vez por vela cerrada
   datetime tActual = iTime(_Symbol, _Period, 0);
   if(tActual == g_ultimaVelaTime) return;
   g_ultimaVelaTime = tActual;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 0, 5, rates) < 5) return;

   double atrBuf[1];
   if(CopyBuffer(g_hATR, 0, 1, 1, atrBuf) <= 0) return;
   double atr = atrBuf[0];
   if(atr <= 0) return;

   // 3) Alimentar la estructura con la vela recien cerrada (indice 1)
   EstructuraEvento ev = EstActualizar(rates[1].open, rates[1].high, rates[1].low, rates[1].close);

   // 4) Salida real si hay CHoCH en contra
   if(ev.hay && ev.tipo == "CHoCH" && InpCerrarPorCHoCH)
      CerrarSiContrario(ev.direccion);

   // 5) Al confirmarse un BOS/CHoCH, arma la zona de retest (con Order Block)
   bool zonaArmadaEstaVela = false;
   if(ev.hay) { ArmarPendiente(ev, atr); zonaArmadaEstaVela = true; }

   // 6) Determinar señal
   string dirSenal = "";
   if(InpUsarRetest)
   {
      if(!zonaArmadaEstaVela)
      {
         string dr;
         if(RevisarRetest(rates, dr)) dirSenal = dr;
      }
   }
   else if(ev.hay) dirSenal = ev.direccion;

   ActualizarPanel(atr, dirSenal);

   // 7) Filtros y ejecucion
   if(dirSenal == "" || !InpTradingEnabled) return;
   if(ObtenerMiPosicion() > 0 || PositionsTotal() >= InpMaxPositions) return;
   if(g_estIndiceActual - g_ultimaVelaSenal < InpMinBarsEntreTrades) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPts = (ask - bid) / _Point;
   if(InpMaxSpreadPoints > 0 && spreadPts > InpMaxSpreadPoints)
   { if(InpPrintDebug) PrintFormat("[ORO] Senal %s filtrada por spread (%.0f > %.0f).", dirSenal, spreadPts, InpMaxSpreadPoints); return; }

   // Filtro EMA20/50 (momentum de corto plazo)
   if(InpUsarFiltroEMA)
   {
      double emaF[1], emaS[1];
      CopyBuffer(g_hEMAf, 0, 1, 1, emaF);
      CopyBuffer(g_hEMAs, 0, 1, 1, emaS);
      bool emaAlcista = emaF[0] > emaS[0];
      if((dirSenal=="ALCISTA" && !emaAlcista) || (dirSenal=="BAJISTA" && emaAlcista))
      { if(InpPrintDebug) PrintFormat("[ORO] Senal %s filtrada: EMA %d/%d no confirma.", dirSenal, InpEMA_Fast, InpEMA_Slow); return; }
   }

   // Sesgo EMA200: define el riesgo (a favor = completo; en contra = reducido; 0 = no operar)
   double ema200[1];
   CopyBuffer(g_hEMA200, 0, 1, 1, ema200);
   double close1 = rates[1].close;
   bool aFavorEMA200 = (dirSenal=="ALCISTA") ? (close1 > ema200[0]) : (close1 < ema200[0]);
   double riskPct = aFavorEMA200 ? InpRiskPercent : (InpRiskPercent * InpContraTendRiskFactor);
   if(riskPct <= 0)
   { if(InpPrintDebug) PrintFormat("[ORO] Senal %s descartada: contra EMA200 y factor=0.", dirSenal); return; }

   // SL estructural del Order Block guardado al armar la zona
   double structSL = g_pendStructSL;

   AbrirOperacion(dirSenal=="ALCISTA" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, atr, ask, bid, riskPct, structSL);
   g_ultimaVelaSenal = g_estIndiceActual;
}

void OnTimer() {}
void OnTrade() {}
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result) {}
double OnTester() { return 0.0; }
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam) {}
//+------------------------------------------------------------------------+
