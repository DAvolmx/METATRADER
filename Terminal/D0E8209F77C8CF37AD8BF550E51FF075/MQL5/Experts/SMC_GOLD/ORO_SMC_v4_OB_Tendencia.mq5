//+------------------------------------------------------------------+
//|  ORO_SMC_v4_OB_Tendencia.mq5                                     |
//|                                                                  |
//|  Evolucion de ORO.mq5 con tres anadidos pedidos:                 |
//|    1. FILTRO DE TENDENCIA de varias capas (temporalidad superior |
//|       + alineacion local + fuerza con ADX)                       |
//|    2. ORDER BLOCKS reales (desplazamiento, vela contraria, BOS,  |
//|       mitigacion) en vez de un cruce de medias disfrazado        |
//|    3. TRAILING mejorado (break-even + arrastre por ATR con paso  |
//|       minimo, y filtrado por simbolo y magic)                    |
//|                                                                  |
//|  QUE SE ARREGLO DEL ORIGINAL (cinco defectos reales):            |
//|    a) CalculateLotSize devolvia el LOTE MINIMO cuando el lote    |
//|       por riesgo salia por debajo. Eso hace que el riesgo real   |
//|       lo imponga el broker y no tu plan: con oro y 50 USD puede  |
//|       ser el 8% por operacion en vez del 2%. Ahora pasa por      |
//|       GoldMaster_LotGuard.mqh, que BLOQUEA en vez de inflar.     |
//|    b) Se comparaba el cierre de la vela CERRADA contra la EMA de |
//|       la vela EN FORMACION (CopyBuffer con shift 0). Eso repinta.|
//|       Ahora todo se evalua sobre la vela 1, ya cerrada.          |
//|    c) PositionsTotal() cuenta TODAS las posiciones de la cuenta. |
//|       Con otro EA o una orden manual abierta, este no operaba    |
//|       nunca. Ahora se filtra por simbolo y magic.                |
//|    d) En compra el SL/TP se calculaban desde el BID y la entrada |
//|       era al ASK (y al reves en venta): un error del tamano del  |
//|       spread en cada operacion. Ahora cada lado usa su precio.   |
//|    e) OnChartEvent declaraba 'int32_t', que no es un tipo de     |
//|       MQL5 y no compila. Y los OnTester* vacios interfieren con  |
//|       la optimizacion. Eliminados.                               |
//|                                                                  |
//|  FRECUENCIA DE OPERACION (simulada sobre velas generadas con la      |
//|  ecuacion maestra calibrada del oro, ~7 anos de H1):                 |
//|                                                                      |
//|    desplaz.  BOS  tendencia   bloques   ops/ano   1 cada             |
//|       2.0     si   estricto      425       7.1     35 dias  <- POR  |
//|                                                              DEFECTO |
//|       2.0     si   medio         425      17.1     15 dias           |
//|       1.5     si   estricto      890      20.2     12 dias           |
//|       1.5     si   medio         890      40.8      6 dias           |
//|       1.5     no   medio        1361      56.2      4 dias           |
//|       1.2     no   medio        2541     114.0      2 dias           |
//|                                                                      |
//|  Los valores por defecto son DELIBERADAMENTE restrictivos: 7-8       |
//|  operaciones al ano. Si te parecen pocas, afloja en este orden:      |
//|    1. UseADX = false  o  ADX_MinLevel mas bajo                       |
//|    2. UseHTFFilter = false   (la capa que mas rechaza)               |
//|    3. OB_DisplacementATR de 2.0 a 1.5                                |
//|    4. OB_RequireBOS = false   (el ultimo recurso: sin BOS deja de    |
//|       ser estructura y pasa a ser cualquier vela contraria)          |
//|  Cada paso multiplica las operaciones, y tambien el ruido.           |
//|                                                                      |
//|  HONESTIDAD SOBRE LOS ORDER BLOCKS: medido en este mismo sistema |
//|  sobre 21 anos de oro real, las estrategias de order block NO    |
//|  superaron el contraste de realidad de White (p=0.835) y el      |
//|  96.4% de los caminos sinteticos SIN estructura institucional    |
//|  dieron mejor resultado que el mejor real. Esto NO es una maquina|
//|  de ganar: es un marco de ejecucion coherente y con el riesgo    |
//|  controlado. Pruebalo en demo y mira docs/HALLAZGOS.md.          |
//+------------------------------------------------------------------+
#property copyright "GOLD MASTER SYSTEM"
#property version   "4.00"
#property description "SMC con order blocks reales, filtro de tendencia multicapa y guarda de lote"

#include <Trade\Trade.mqh>
#include <GoldMaster\GoldMaster_LotGuard.mqh>

CTrade trade;

//=== RIESGO ========================================================
input group "Riesgo"
input double RiskPerTrade       = 2.0;    // Riesgo por operacion (% de equity)
input double InpLG_MaxRiskPct   = 5.0;    // Guarda: riesgo max. por operacion (% equity)
input double InpLG_MaxOverTarget= 2.0;    // Guarda: multiplo max. del riesgo objetivo
input int    MaxTradesPerDay    = 5;      // Tope de operaciones al dia (0 = sin tope)
input double MaxSpreadPoints    = 60;     // Spread maximo admitido (puntos, 0 = sin filtro)

//=== ORDER BLOCKS ==================================================
input group "Order Blocks"
input bool   UseOrderBlocks     = true;   // Exigir entrada en un order block
input double OB_DisplacementATR = 2.0;    // Desplazamiento minimo (multiplos de ATR)
input int    OB_Lookback        = 5;      // Velas hacia atras para hallar la vela del bloque
input int    OB_SwingK          = 3;      // k de los fractales para el BOS
input bool   OB_RequireBOS      = true;   // Exigir que el impulso rompa estructura
input int    OB_MaxAgeBars      = 240;    // Caducidad del bloque (barras, 0 = sin caducar)
input int    OB_ScanBars        = 600;    // Historico a escanear en cada barra
input double OB_SL_BufferATR    = 0.30;   // Colchon del stop bajo/sobre la zona (ATR)
input bool   OB_DrawZones       = true;   // Dibujar las zonas en el grafico

//=== TENDENCIA =====================================================
input group "Filtro de tendencia"
input bool             UseHTFFilter = true;        // Filtrar por temporalidad superior
input ENUM_TIMEFRAMES  HTF          = PERIOD_H4;   // Temporalidad superior
input int              HTF_EMA      = 50;          // EMA de la temporalidad superior
input int              EMA_Fast     = 20;          // EMA rapida (estructura micro)
input int              EMA_Slow     = 50;          // EMA lenta (estructura macro)
input bool             UseADX       = true;        // Exigir fuerza de tendencia
input int              ADX_Period   = 14;          // Periodo del ADX
input double           ADX_MinLevel = 20.0;        // ADX minimo para operar

//=== SALIDAS =======================================================
input group "Salidas"
input double TP_R_Multiple      = 2.0;    // Objetivo en multiplos de R (riesgo real)
input bool   UseBreakEven       = true;   // Mover a break-even
input double BE_TriggerR        = 1.0;    // R de beneficio para activar break-even
input double BE_OffsetATR       = 0.10;   // Colchon por encima de la entrada (ATR)
input bool   UseTrailing        = true;   // Arrastre de stop
input double TrailActivationR   = 1.5;    // R de beneficio para activar el arrastre
input double TrailDistanceATR   = 1.0;    // Distancia del arrastre (ATR)
input double TrailStepATR       = 0.25;   // Paso minimo para mover el stop (ATR)

input group "General"
input long   MagicNumber        = 777004; // Magic
input bool   Verbose            = true;   // Mensajes en el Journal

//--- indicadores
int hATR = INVALID_HANDLE, hEMAf = INVALID_HANDLE, hEMAs = INVALID_HANDLE;
int hADX = INVALID_HANDLE, hHTF = INVALID_HANDLE;

//--- order block
struct SOB
  {
   double            top;       // techo de la zona
   double            bot;       // suelo de la zona
   datetime          tOB;       // vela que forma el bloque
   int               dir;       // +1 alcista, -1 bajista
   int               confirmBar;// barra (serie) en que se confirmo
   bool              mitigated; // ya lo atraveso el precio
  };
#define MAX_OB 40
SOB      g_ob[MAX_OB];
int      g_obN = 0;

datetime g_lastBar  = 0;
int      g_dayTrades = 0;
int      g_dayStamp  = -1;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(EMA_Fast >= EMA_Slow)
     {
      Print("ERROR: la EMA rapida debe ser menor que la lenta.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(OB_SwingK < 1 || OB_Lookback < 1)
     {
      Print("ERROR: OB_SwingK y OB_Lookback deben ser >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   hATR  = iATR(_Symbol, _Period, 14);
   hEMAf = iMA(_Symbol, _Period, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMAs = iMA(_Symbol, _Period, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   if(UseADX)       hADX = iADX(_Symbol, _Period, ADX_Period);
   if(UseHTFFilter) hHTF = iMA(_Symbol, HTF, HTF_EMA, 0, MODE_EMA, PRICE_CLOSE);

   if(hATR == INVALID_HANDLE || hEMAf == INVALID_HANDLE || hEMAs == INVALID_HANDLE ||
      (UseADX && hADX == INVALID_HANDLE) || (UseHTFFilter && hHTF == INVALID_HANDLE))
     {
      Print("ERROR cargando indicadores.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   PrintFormat("EA ORO SMC v4 iniciado | OB=%s | HTF=%s | ADX=%s",
               UseOrderBlocks ? "si" : "no",
               UseHTFFilter ? EnumToString(HTF) : "no",
               UseADX ? "si" : "no");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hEMAf != INVALID_HANDLE) IndicatorRelease(hEMAf);
   if(hEMAs != INVALID_HANDLE) IndicatorRelease(hEMAs);
   if(hADX  != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hHTF  != INVALID_HANDLE) IndicatorRelease(hHTF);
   ObjectsDeleteAll(0, "OBv4_");
  }

//+------------------------------------------------------------------+
//| Lectura de un buffer en la barra `shift`. Siempre con shift>=1   |
//| para que la decision no dependa de una vela en formacion.        |
//+------------------------------------------------------------------+
bool Buf(const int handle, const int buffer, const int shift, double &out)
  {
   double tmp[];
   if(CopyBuffer(handle, buffer, shift, 1, tmp) != 1)
      return(false);
   out = tmp[0];
   return(true);
  }

//+------------------------------------------------------------------+
//| Posiciones de ESTE ea en ESTE simbolo. El original usaba         |
//| PositionsTotal(), que cuenta las de toda la cuenta.              |
//+------------------------------------------------------------------+
int MyPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         n++;
     }
   return(n);
  }

//+------------------------------------------------------------------+
//| Contador diario de operaciones.                                  |
//+------------------------------------------------------------------+
void RollDay()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_dayStamp)
     {
      g_dayStamp  = dt.day_of_year;
      g_dayTrades = 0;
     }
  }

//+------------------------------------------------------------------+
//| FILTRO DE TENDENCIA. Devuelve +1 alcista, -1 bajista, 0 sin      |
//| sesgo. Las tres capas tienen que coincidir: si una discrepa, no  |
//| se opera. Es deliberado que sea restrictivo: el coste de no      |
//| operar es cero, el de operar contra la tendencia no.             |
//+------------------------------------------------------------------+
int TrendBias()
  {
   double emaF, emaS, c1;
   if(!Buf(hEMAf, 0, 1, emaF)) return(0);
   if(!Buf(hEMAs, 0, 1, emaS)) return(0);
   c1 = iClose(_Symbol, _Period, 1);
   if(c1 <= 0) return(0);

   int local = 0;
   if(emaF > emaS && c1 > emaF) local = +1;
   if(emaF < emaS && c1 < emaF) local = -1;
   if(local == 0) return(0);

   // capa 2: temporalidad superior
   if(UseHTFFilter)
     {
      double htf;
      if(!Buf(hHTF, 0, 1, htf)) return(0);
      double cH = iClose(_Symbol, HTF, 1);
      if(cH <= 0) return(0);
      int htfBias = (cH > htf) ? +1 : -1;
      if(htfBias != local) return(0);        // discrepan: fuera
     }

   // capa 3: fuerza. Un ADX bajo significa rango, y en rango las
   // rupturas de estructura son casi todas falsas.
   if(UseADX)
     {
      double adx;
      if(!Buf(hADX, 0, 1, adx)) return(0);
      if(adx < ADX_MinLevel) return(0);
     }

   return(local);
  }

//+------------------------------------------------------------------+
//| Fractal: true si la barra `i` es swing alto (o bajo) con k velas |
//| a cada lado. Se confirma k barras despues, nunca antes.          |
//+------------------------------------------------------------------+
bool IsSwingHigh(const int i, const int k, const double &h[])
  {
   for(int j = 1; j <= k; j++)
      if(h[i] <= h[i - j] || h[i] <= h[i + j])
         return(false);
   return(true);
  }

bool IsSwingLow(const int i, const int k, const double &l[])
  {
   for(int j = 1; j <= k; j++)
      if(l[i] >= l[i - j] || l[i] >= l[i + j])
         return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| DETECCION DE ORDER BLOCKS.                                       |
//|                                                                  |
//| Un order block es la ultima vela contraria antes de un           |
//| desplazamiento que rompe estructura. Dos reglas importantes:     |
//|                                                                  |
//|  - El bloque NO es operable hasta que cierra la vela de          |
//|    desplazamiento. Se guarda `confirmBar` y la entrada solo se   |
//|    permite despues. Saltarse esto es comprar en el minimo        |
//|    sabiendo ya que venia el impulso, que es como se fabrican     |
//|    los backtests bonitos.                                        |
//|  - Se marca mitigado en cuanto el precio CIERRA al otro lado:    |
//|    un bloque atravesado ya no es soporte, es resistencia.        |
//+------------------------------------------------------------------+
void DetectOrderBlocks()
  {
   g_obN = 0;

   int bars = MathMin(OB_ScanBars, Bars(_Symbol, _Period) - OB_SwingK - OB_Lookback - 5);
   if(bars < 50) return;

   double h[], l[], o[], c[], atr[];
   ArraySetAsSeries(h, true); ArraySetAsSeries(l, true);
   ArraySetAsSeries(o, true); ArraySetAsSeries(c, true);
   ArraySetAsSeries(atr, true);

   int need = bars + OB_SwingK + OB_Lookback + 5;
   if(CopyHigh(_Symbol, _Period, 0, need, h)  != need) return;
   if(CopyLow(_Symbol, _Period, 0, need, l)   != need) return;
   if(CopyOpen(_Symbol, _Period, 0, need, o)  != need) return;
   if(CopyClose(_Symbol, _Period, 0, need, c) != need) return;
   if(CopyBuffer(hATR, 0, 0, need, atr)       != need) return;

   // De la barra mas antigua a la mas reciente (indice de serie decrece).
   for(int i = bars; i >= 1; i--)
     {
      if(atr[i] <= 0) continue;

      double body = c[i] - o[i];
      if(MathAbs(body) < OB_DisplacementATR * atr[i])
         continue;                                  // no hay desplazamiento

      int dir = (body > 0) ? +1 : -1;

      // vela contraria mas reciente antes del impulso = el bloque
      int ob = -1;
      for(int k = i + 1; k <= i + OB_Lookback; k++)
        {
         double b = c[k] - o[k];
         if((dir > 0 && b < 0) || (dir < 0 && b > 0)) { ob = k; break; }
        }
      if(ob < 0) continue;

      // BOS: el impulso tiene que romper el ultimo swing confirmado
      if(OB_RequireBOS)
        {
         bool bos = false;
         for(int s = i + OB_SwingK + 1; s <= i + 80 && s < need - OB_SwingK; s++)
           {
            if(dir > 0 && IsSwingHigh(s, OB_SwingK, h)) { bos = (c[i] > h[s]); break; }
            if(dir < 0 && IsSwingLow(s, OB_SwingK, l))  { bos = (c[i] < l[s]); break; }
           }
         if(!bos) continue;
        }

      if(OB_MaxAgeBars > 0 && i > OB_MaxAgeBars)
         continue;                                  // caducado

      // ¿lo mitigo el precio despues de confirmarse?
      bool mit = false;
      for(int k = i - 1; k >= 0; k--)
        {
         if(dir > 0 && c[k] < l[ob]) { mit = true; break; }
         if(dir < 0 && c[k] > h[ob]) { mit = true; break; }
        }
      if(mit) continue;                             // solo interesan los vivos

      if(g_obN >= MAX_OB) break;
      g_ob[g_obN].top        = h[ob];
      g_ob[g_obN].bot        = l[ob];
      g_ob[g_obN].tOB        = iTime(_Symbol, _Period, ob);
      g_ob[g_obN].dir        = dir;
      g_ob[g_obN].confirmBar = i;
      g_ob[g_obN].mitigated  = false;
      g_obN++;
     }

   if(OB_DrawZones)
      DrawZones();
  }

//+------------------------------------------------------------------+
void DrawZones()
  {
   ObjectsDeleteAll(0, "OBv4_");
   datetime right = iTime(_Symbol, _Period, 0) + PeriodSeconds() * 10;
   for(int i = 0; i < g_obN; i++)
     {
      string nm = "OBv4_" + IntegerToString(i);
      if(ObjectCreate(0, nm, OBJ_RECTANGLE, 0, g_ob[i].tOB, g_ob[i].top, right, g_ob[i].bot))
        {
         ObjectSetInteger(0, nm, OBJPROP_COLOR, g_ob[i].dir > 0 ? clrDodgerBlue : clrTomato);
         ObjectSetInteger(0, nm, OBJPROP_FILL, true);
         ObjectSetInteger(0, nm, OBJPROP_BACK, true);
         ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
        }
     }
  }

//+------------------------------------------------------------------+
//| Busca el order block vivo mas CERCANO al precio en la direccion  |
//| pedida, en el que el precio ya esta dentro. Devuelve indice o -1.|
//+------------------------------------------------------------------+
int FindActiveOB(const int dir, const double bid, const double ask)
  {
   int best = -1;
   double bestDist = DBL_MAX;
   for(int i = 0; i < g_obN; i++)
     {
      if(g_ob[i].dir != dir || g_ob[i].mitigated) continue;
      if(g_ob[i].confirmBar < 1) continue;          // aun no confirmado

      double px = (dir > 0) ? bid : ask;
      // el precio tiene que haber entrado en la zona
      if(px > g_ob[i].top || px < g_ob[i].bot) continue;

      double mid  = (g_ob[i].top + g_ob[i].bot) * 0.5;
      double dist = MathAbs(px - mid);
      if(dist < bestDist) { bestDist = dist; best = i; }
     }
   return(best);
  }

//+------------------------------------------------------------------+
//| TRAILING: break-even primero, arrastre por ATR despues. El paso  |
//| minimo evita machacar al servidor con modificaciones de un tick. |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   double atr;
   if(!Buf(hATR, 0, 1, atr) || atr <= 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)     continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      // R ORIGINAL, deducido del TP y no del stop actual.
      // Si se dedujera de (entry - sl), en cuanto el break-even mueve el
      // stop por encima de la entrada esa resta se vuelve NEGATIVA, R se
      // degradaria a ATR y el umbral de arrastre pasaria a medirse en otra
      // escala a mitad de la operacion. El TP no se mueve nunca, y por
      // construccion vale entry +/- TP_R_Multiple * riesgo, asi que
      // devuelve el R inicial exacto durante toda la vida de la posicion.
      double rDist = 0.0;
      if(tp > 0.0 && TP_R_Multiple > 0.0)
         rDist = MathAbs(tp - entry) / TP_R_Multiple;
      if(rDist <= 0.0)                              // posicion sin TP
         rDist = (type == POSITION_TYPE_BUY) ? (entry - sl) : (sl - entry);
      if(rDist <= 0.0) rDist = atr;                 // ultimo recurso

      double newSL = sl;

      if(type == POSITION_TYPE_BUY)
        {
         double profitR = (bid - entry) / rDist;
         if(UseBreakEven && profitR >= BE_TriggerR)
           {
            double be = entry + BE_OffsetATR * atr;
            if(be > newSL) newSL = be;
           }
         if(UseTrailing && profitR >= TrailActivationR)
           {
            double tr = bid - TrailDistanceATR * atr;
            if(tr > newSL + TrailStepATR * atr) newSL = tr;
           }
         if(newSL > sl && newSL < bid)
            trade.PositionModify(tk, NormalizeDouble(newSL, _Digits), tp);
        }
      else
         if(type == POSITION_TYPE_SELL)
           {
            double profitR = (entry - ask) / rDist;
            if(UseBreakEven && profitR >= BE_TriggerR)
              {
               double be = entry - BE_OffsetATR * atr;
               if(be < newSL || sl == 0) newSL = be;
              }
            if(UseTrailing && profitR >= TrailActivationR)
              {
               double tr = ask + TrailDistanceATR * atr;
               if(tr < newSL - TrailStepATR * atr || sl == 0) newSL = tr;
              }
            if((newSL < sl || sl == 0) && newSL > ask)
               trade.PositionModify(tk, NormalizeDouble(newSL, _Digits), tp);
           }
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(MyPositions() > 0)
     {
      ManagePositions();
      return;
     }

   // Todo lo demas se evalua UNA VEZ por vela cerrada.
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == g_lastBar) return;
   g_lastBar = t0;

   RollDay();
   if(MaxTradesPerDay > 0 && g_dayTrades >= MaxTradesPerDay)
      return;

   if(MaxSpreadPoints > 0)
     {
      long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(sp > (long)MaxSpreadPoints)
        {
         if(Verbose) PrintFormat("Spread %d > maximo %.0f: sin operar.", sp, MaxSpreadPoints);
         return;
        }
     }

   int bias = TrendBias();
   if(bias == 0) return;

   double atr;
   if(!Buf(hATR, 0, 1, atr) || atr <= 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;

   double entry, sl;

   if(UseOrderBlocks)
     {
      DetectOrderBlocks();
      int k = FindActiveOB(bias, bid, ask);
      if(k < 0) return;                    // no hay bloque activo: no se opera

      // El stop lo define la ZONA, no un ATR arbitrario: si el precio
      // cierra al otro lado del bloque, la idea era falsa.
      if(bias > 0)
        {
         entry = ask;
         sl    = g_ob[k].bot - OB_SL_BufferATR * atr;
        }
      else
        {
         entry = bid;
         sl    = g_ob[k].top + OB_SL_BufferATR * atr;
        }
     }
   else
     {
      // Sin order blocks: stop por ATR, como el original (pero con el
      // precio del lado correcto).
      if(bias > 0) { entry = ask; sl = ask - 2.0 * atr; }
      else         { entry = bid; sl = bid + 2.0 * atr; }
     }

   double risk = (bias > 0) ? (entry - sl) : (sl - entry);
   if(risk <= 0) return;

   // TP como multiplo REAL de R. En el original, RatioTP multiplicaba el
   // ATR, asi que el R:R efectivo era RatioTP/ATRMultiplierSL, no RatioTP.
   double tp = (bias > 0) ? (entry + TP_R_Multiple * risk)
                          : (entry - TP_R_Multiple * risk);

   double riskUsd = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPerTrade / 100.0;
   double lot = GMLotGuard(risk, riskUsd, InpLG_MaxRiskPct, InpLG_MaxOverTarget,
                           "ORO_SMC_v4", !Verbose);
   if(lot <= 0.0) return;                  // la guarda dijo que no

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   bool ok;
   if(bias > 0) ok = trade.Buy(lot, _Symbol, ask, sl, tp, "SMCv4 BUY");
   else         ok = trade.Sell(lot, _Symbol, bid, sl, tp, "SMCv4 SELL");

   if(ok)
     {
      g_dayTrades++;
      if(Verbose)
         PrintFormat("%s lote=%.2f entrada=%.5f SL=%.5f TP=%.5f riesgo=%.2f USD (%d/%d hoy)",
                     bias > 0 ? "COMPRA" : "VENTA", lot, entry, sl, tp,
                     lot * risk * GMLG_UsdPerPricePerLot(_Symbol),
                     g_dayTrades, MaxTradesPerDay);
     }
   else
      PrintFormat("Orden rechazada: retcode=%d (%s)",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
