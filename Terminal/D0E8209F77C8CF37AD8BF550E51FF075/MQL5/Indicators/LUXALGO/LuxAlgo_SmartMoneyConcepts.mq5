//+------------------------------------------------------------------+
//|  LuxAlgo_SmartMoneyConcepts.mq5                                  |
//|                                                                  |
//|  Port a MQL5 de "Smart Money Concepts [LuxAlgo]" (Pine v5).      |
//|                                                                  |
//|  OBRA ORIGINAL:  (c) LuxAlgo                                     |
//|  LICENCIA:       CC BY-NC-SA 4.0                                 |
//|                  https://creativecommons.org/licenses/by-nc-sa/4.0/
//|                                                                  |
//|  Obra DERIVADA, hereda la misma licencia: atribucion a LuxAlgo,  |
//|  USO NO COMERCIAL, y compartir igual. Vender o comercializar un  |
//|  producto basado en esto incumple la licencia.                   |
//|                                                                  |
//|  QUE SE PORTO (y que no)                                         |
//|  Portado: estructura interna y de swing (BOS / CHoCH), order     |
//|    blocks internos y de swing con su mitigacion, EQH/EQL, fair   |
//|    value gaps, maximos/minimos fuertes y debiles, zonas de       |
//|    premium/descuento, y niveles del dia/semana/mes anteriores.   |
//|  NO portado: el coloreado de velas por tendencia (plotcandle de  |
//|    Pine no tiene equivalente directo sin sobreponer un indicador |
//|    de velas completo) y el modo MONOCHROME, que es solo estetico.|
//|                                                                  |
//|  SOBRE SU UTILIDAD, medido sobre 21 anos de oro real en este     |
//|  mismo sistema: las estrategias de order block NO superaron el   |
//|  contraste de realidad de White (p=0.835), el 96.4% de los       |
//|  caminos sinteticos SIN estructura institucional dieron mejor    |
//|  resultado que el mejor real, y un clasificador con 15 variables |
//|  de contexto dio AUC 0.426 (por debajo del azar) al intentar     |
//|  predecir que bloque funcionaria. Es una ayuda VISUAL para leer  |
//|  el grafico, no una senal de entrada. Ver docs/HALLAZGOS.md.     |
//+------------------------------------------------------------------+
#property copyright "Original (c) LuxAlgo - CC BY-NC-SA 4.0. Port MQL5."
#property link      "https://creativecommons.org/licenses/by-nc-sa/4.0/"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

//--- constantes (mismos nombres que en el Pine) ---------------------
#define BULLISH        +1
#define BEARISH        -1
#define BULLISH_LEG     1
#define BEARISH_LEG     0
#define PREFIX         "LUXSMC_"
#define MAX_OB          60

enum ENUM_SMC_MODE   { SMC_HISTORICAL, SMC_PRESENT };
enum ENUM_SMC_SHOW   { SMC_ALL, SMC_BOS, SMC_CHOCH };
enum ENUM_OB_FILTER  { OBF_ATR, OBF_RANGE };
enum ENUM_OB_MIT     { OBM_CLOSE, OBM_HIGHLOW };

input group "Smart Money Concepts"
input ENUM_SMC_MODE InpMode            = SMC_HISTORICAL; // Modo (historico o solo lo reciente)
input int           InpMaxBars         = 1500;           // Barras a analizar

input group "Estructura interna"
input bool          InpShowInternals   = true;           // Mostrar estructura interna
input ENUM_SMC_SHOW InpShowIntBull     = SMC_ALL;        // Estructura alcista interna
input color         InpIntBullColor    = C'8,153,129';   // Color alcista interno
input ENUM_SMC_SHOW InpShowIntBear     = SMC_ALL;        // Estructura bajista interna
input color         InpIntBearColor    = C'242,54,69';   // Color bajista interno
input bool          InpIntConfluence   = false;          // Filtro de confluencia

input group "Estructura de swing"
input bool          InpShowStructure   = true;           // Mostrar estructura de swing
input ENUM_SMC_SHOW InpShowSwingBull   = SMC_ALL;        // Estructura alcista
input color         InpSwingBullColor  = C'8,153,129';   // Color alcista
input ENUM_SMC_SHOW InpShowSwingBear   = SMC_ALL;        // Estructura bajista
input color         InpSwingBearColor  = C'242,54,69';   // Color bajista
input bool          InpShowSwings      = false;          // Etiquetas HH/HL/LH/LL
input int           InpSwingsLength    = 50;             // Tamano del swing (min 10)
input bool          InpShowHighLow     = true;           // Maximos/minimos fuerte-debil

input group "Order Blocks"
input bool          InpShowIntOB       = true;           // Order blocks internos
input int           InpIntOBCount      = 5;              // Cuantos internos mostrar
input bool          InpShowSwingOB     = false;          // Order blocks de swing
input int           InpSwingOBCount    = 5;              // Cuantos de swing mostrar
input ENUM_OB_FILTER InpOBFilter       = OBF_ATR;        // Filtro de volatilidad
input ENUM_OB_MIT   InpOBMitigation    = OBM_HIGHLOW;    // Criterio de mitigacion
input color         InpIntBullOBColor  = C'49,121,245';  // OB interno alcista
input color         InpIntBearOBColor  = C'247,124,128'; // OB interno bajista
input color         InpSwingBullOBColor= C'24,72,204';   // OB de swing alcista
input color         InpSwingBearOBColor= C'178,40,51';   // OB de swing bajista

input group "EQH / EQL"
input bool          InpShowEqual       = true;           // Mostrar maximos/minimos iguales
input int           InpEqualLength     = 3;              // Barras de confirmacion
input double        InpEqualThreshold  = 0.1;            // Umbral (0 a 0.5)

input group "Fair Value Gaps"
input bool          InpShowFVG         = false;          // Mostrar FVG
input bool          InpFVGAutoThreshold= true;           // Umbral automatico
input color         InpFVGBullColor    = C'0,255,104';   // FVG alcista
input color         InpFVGBearColor    = C'255,0,8';     // FVG bajista
input int           InpFVGExtend       = 1;              // Extender FVG (barras)

input group "Niveles superiores"
input bool          InpShowDaily       = false;          // Maximo/minimo del dia anterior
input bool          InpShowWeekly      = false;          // De la semana anterior
input bool          InpShowMonthly     = false;          // Del mes anterior
input color         InpLevelsColor     = C'33,87,243';   // Color de los niveles

input group "Zonas Premium / Descuento"
input bool          InpShowZones       = false;          // Mostrar zonas
input color         InpPremiumColor    = C'242,54,69';   // Premium
input color         InpEquilibriumColor= C'135,139,148'; // Equilibrio
input color         InpDiscountColor   = C'8,153,129';   // Descuento

//--- Pivote. Equivale al UDT `pivot` del Pine.
struct SPivot
  {
   double            currentLevel;
   double            lastLevel;
   bool              crossed;
   datetime          barTime;
   int               barIndex;
  };

//--- Order block. Equivale al UDT `orderBlock`.
struct SOrderBlock
  {
   double            barHigh;
   double            barLow;
   datetime          barTime;
   int               bias;
  };

//--- Extremos de arrastre. Equivale al UDT `trailingExtremes`.
struct STrailing
  {
   double            top;
   double            bottom;
   datetime          barTime;
   int               barIndex;
   datetime          lastTopTime;
   datetime          lastBottomTime;
  };

SPivot      g_swingHigh, g_swingLow, g_internalHigh, g_internalLow;
SPivot      g_equalHigh, g_equalLow;
int         g_swingTrend, g_internalTrend;
STrailing   g_trailing;
SOrderBlock g_swingOB[], g_internalOB[];
int         g_swingOBn = 0, g_internalOBn = 0;
int         g_objCount = 0;          // contador para nombres unicos de objeto
int         g_atrHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpSwingsLength < 10)
     {
      Print("LuxAlgo SMC: 'Tamano del swing' debe ser >= 10");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpEqualThreshold < 0.0 || InpEqualThreshold > 0.5)
     {
      Print("LuxAlgo SMC: 'Umbral' de EQH/EQL debe estar entre 0 y 0.5");
      return(INIT_PARAMETERS_INCORRECT);
     }
   ArrayResize(g_swingOB, MAX_OB);
   ArrayResize(g_internalOB, MAX_OB);
   g_atrHandle = iATR(_Symbol, _Period, 200);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("LuxAlgo SMC: no se pudo crear el ATR(200)");
      return(INIT_FAILED);
     }
   IndicatorSetString(INDICATOR_SHORTNAME, "LuxAlgo SMC");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PREFIX);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Ayudantes de dibujo. MQL5 no admite canal alfa en los objetos    |
//| estandar, asi que la "transparencia" del Pine se aproxima        |
//| mandando los rectangulos al fondo (OBJPROP_BACK).                |
//+------------------------------------------------------------------+
string NextName(const string tag)
  {
   g_objCount++;
   return(PREFIX + tag + "_" + IntegerToString(g_objCount));
  }

void MkBox(const string name, datetime t1, double p1, datetime t2, double p2,
           color clr, bool fill, bool back)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, fill);
   ObjectSetInteger(0, name, OBJPROP_BACK, back);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void MkLine(const string name, datetime t1, double p1, datetime t2, double p2,
            color clr, ENUM_LINE_STYLE style, bool ray)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, ray);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void MkText(const string name, datetime t, double p, const string txt,
            color clr, int anchor, int fontsize)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, p);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontsize);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| leg(): 1 si el tramo es alcista, 0 si bajista. Igual que el Pine:|
//| se mira si la barra de hace `size` supera el extremo de las      |
//| ultimas `size` barras.                                           |
//+------------------------------------------------------------------+
int Leg(const int i, const int size, const double &high[], const double &low[], int prevLeg)
  {
   double upper = high[i], lower = low[i];
   for(int k = 1; k < size; k++)
     {
      if(high[i + k] > upper) upper = high[i + k];
      if(low[i + k]  < lower) lower = low[i + k];
     }
   if(high[i + size] > upper)
      return(BEARISH_LEG);
   if(low[i + size] < lower)
      return(BULLISH_LEG);
   return(prevLeg);
  }

//+------------------------------------------------------------------+
//| Dibuja la linea y la etiqueta de una ruptura de estructura.      |
//+------------------------------------------------------------------+
void DrawStructure(const SPivot &p, const string tag, color clr,
                   ENUM_LINE_STYLE style, datetime nowTime, int fontsize)
  {
   string base = NextName("ST");
   MkLine(base + "_l", p.barTime, p.currentLevel, nowTime, p.currentLevel, clr, style, false);
   datetime mid = (datetime)((long)p.barTime + ((long)nowTime - (long)p.barTime) / 2);
   MkText(base + "_t", mid, p.currentLevel, tag, clr, ANCHOR_CENTER, fontsize);
  }

//+------------------------------------------------------------------+
//| Guarda un order block, buscando dentro del tramo la vela con el  |
//| extremo mas pronunciado (igual que storeOrdeBlock del Pine).     |
//+------------------------------------------------------------------+
void StoreOrderBlock(const SPivot &p, const bool internal, const int bias,
                     const int iNow, const datetime &time[],
                     const double &pHigh[], const double &pLow[])
  {
   int from = p.barIndex;                 // indice de serie del pivote
   if(from <= iNow)
      return;

   int best = from;
   if(bias == BEARISH)
     {
      double mx = pHigh[from];
      for(int k = iNow; k <= from; k++)
         if(pHigh[k] > mx) { mx = pHigh[k]; best = k; }
     }
   else
     {
      double mn = pLow[from];
      for(int k = iNow; k <= from; k++)
         if(pLow[k] < mn) { mn = pLow[k]; best = k; }
     }

   SOrderBlock ob;
   ob.barHigh = pHigh[best];
   ob.barLow  = pLow[best];
   ob.barTime = time[best];
   ob.bias    = bias;

   if(internal)
     {
      if(g_internalOBn >= MAX_OB) g_internalOBn = MAX_OB - 1;
      for(int i = g_internalOBn; i > 0; i--) g_internalOB[i] = g_internalOB[i - 1];
      g_internalOB[0] = ob;
      g_internalOBn++;
     }
   else
     {
      if(g_swingOBn >= MAX_OB) g_swingOBn = MAX_OB - 1;
      for(int i = g_swingOBn; i > 0; i--) g_swingOB[i] = g_swingOB[i - 1];
      g_swingOB[0] = ob;
      g_swingOBn++;
     }
  }

//+------------------------------------------------------------------+
//| Elimina los order blocks ya mitigados por el precio.             |
//+------------------------------------------------------------------+
void DeleteMitigated(const bool internal, const double bearSrc, const double bullSrc)
  {
   if(internal)
     {
      for(int i = g_internalOBn - 1; i >= 0; i--)
        {
         bool gone = (bearSrc > g_internalOB[i].barHigh && g_internalOB[i].bias == BEARISH)
                  || (bullSrc < g_internalOB[i].barLow  && g_internalOB[i].bias == BULLISH);
         if(gone)
           {
            for(int j = i; j < g_internalOBn - 1; j++) g_internalOB[j] = g_internalOB[j + 1];
            g_internalOBn--;
           }
        }
     }
   else
     {
      for(int i = g_swingOBn - 1; i >= 0; i--)
        {
         bool gone = (bearSrc > g_swingOB[i].barHigh && g_swingOB[i].bias == BEARISH)
                  || (bullSrc < g_swingOB[i].barLow  && g_swingOB[i].bias == BULLISH);
         if(gone)
           {
            for(int j = i; j < g_swingOBn - 1; j++) g_swingOB[j] = g_swingOB[j + 1];
            g_swingOBn--;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Pinta los N order blocks mas recientes.                          |
//+------------------------------------------------------------------+
void DrawOrderBlocks(const bool internal, datetime rightEdge)
  {
   int n     = internal ? g_internalOBn : g_swingOBn;
   int want  = internal ? InpIntOBCount : InpSwingOBCount;
   int count = MathMin(want, n);

   for(int i = 0; i < count; i++)
     {
      SOrderBlock ob = internal ? g_internalOB[i] : g_swingOB[i];
      color clr;
      if(internal)
         clr = (ob.bias == BEARISH) ? InpIntBearOBColor : InpIntBullOBColor;
      else
         clr = (ob.bias == BEARISH) ? InpSwingBearOBColor : InpSwingBullOBColor;

      string nm = PREFIX + (internal ? "IOB" : "SOB") + IntegerToString(i);
      MkBox(nm, ob.barTime, ob.barHigh, rightEdge, ob.barLow, clr, true, true);
     }
  }

//+------------------------------------------------------------------+
//| Niveles del periodo superior anterior (dia, semana o mes).       |
//+------------------------------------------------------------------+
void DrawHtfLevel(ENUM_TIMEFRAMES tf, const string tag, datetime rightEdge)
  {
   if(PeriodSeconds(_Period) > PeriodSeconds(tf))
      return;                                  // solo en graficos menores

   double h[], l[];
   datetime t[];
   if(CopyHigh(_Symbol, tf, 1, 1, h) != 1) return;
   if(CopyLow(_Symbol, tf, 1, 1, l)  != 1) return;
   if(CopyTime(_Symbol, tf, 1, 1, t) != 1) return;

   MkLine(PREFIX + tag + "_H", t[0], h[0], rightEdge, h[0], InpLevelsColor, STYLE_SOLID, false);
   MkLine(PREFIX + tag + "_L", t[0], l[0], rightEdge, l[0], InpLevelsColor, STYLE_SOLID, false);
   MkText(PREFIX + tag + "_HT", rightEdge, h[0], "P" + tag + "H", InpLevelsColor, ANCHOR_LEFT, 8);
   MkText(PREFIX + tag + "_LT", rightEdge, l[0], "P" + tag + "L", InpLevelsColor, ANCHOR_LEFT, 8);
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   int need = InpSwingsLength * 2 + 220;
   if(rates_total < need)
      return(0);

   ArraySetAsSeries(time,  true);
   ArraySetAsSeries(open,  true);
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_atrHandle, 0, 0, rates_total, atr) <= 0)
      return(0);

   // Se recalcula todo el tramo visible y se redibuja. Es el mismo
   // enfoque del Pine (que en modo PRESENT borra y repinta), y evita
   // objetos huerfanos de estructuras ya invalidadas.
   // Recalcular en CADA tick seria carisimo: este indicador borra y
   // redibuja todos sus objetos, y recorre el historico con bucles
   // anidados. Como la estructura solo puede cambiar cuando cierra una
   // vela, se recalcula una vez por barra. El primer calculo tras
   // cargarlo si se hace entero.
   static datetime s_lastBar = 0;
   if(prev_calculated > 0 && time[0] == s_lastBar)
      return(rates_total);
   s_lastBar = time[0];

   ObjectsDeleteAll(0, PREFIX);
   g_objCount = 0;
   g_swingOBn = 0;
   g_internalOBn = 0;
   g_swingTrend = 0;
   g_internalTrend = 0;

   int limit = MathMin(InpMaxBars, rates_total - need);
   if(limit < 10)
      return(0);

   // --- series auxiliares: high/low "parseados" ---------------------
   // El Pine descarta el extremo de las velas de alta volatilidad para
   // que un pico aislado no defina el order block.
   double pHigh[], pLow[];
   ArrayResize(pHigh, rates_total);
   ArrayResize(pLow,  rates_total);
   ArraySetAsSeries(pHigh, true);
   ArraySetAsSeries(pLow,  true);

   double cumTr = 0.0;
   for(int i = rates_total - 1; i >= 0; i--)
     {
      double vol;
      if(InpOBFilter == OBF_ATR)
         vol = atr[i];
      else
        {
         double pc = (i + 1 < rates_total) ? close[i + 1] : close[i];
         double tr = MathMax(high[i] - low[i], MathMax(MathAbs(high[i] - pc), MathAbs(low[i] - pc)));
         cumTr += tr;
         vol = cumTr / (double)(rates_total - i);
        }
      bool hiVol = (vol > 0.0) && ((high[i] - low[i]) >= 2.0 * vol);
      pHigh[i] = hiVol ? low[i]  : high[i];
      pLow[i]  = hiVol ? high[i] : low[i];
     }

   // --- estado inicial ----------------------------------------------
   g_swingHigh.currentLevel = 0; g_swingHigh.crossed = true; g_swingHigh.barIndex = -1;
   g_swingLow.currentLevel  = 0; g_swingLow.crossed  = true; g_swingLow.barIndex  = -1;
   g_internalHigh = g_swingHigh;
   g_internalLow  = g_swingLow;
   g_equalHigh    = g_swingHigh;
   g_equalLow     = g_swingLow;

   g_trailing.top = high[limit]; g_trailing.bottom = low[limit];
   g_trailing.barTime = time[limit]; g_trailing.barIndex = limit;
   g_trailing.lastTopTime = time[limit]; g_trailing.lastBottomTime = time[limit];

   int legSwing = 0, legInt = 0, legEq = 0;
   int prevLegSwing = 0, prevLegInt = 0, prevLegEq = 0;

   double bearSrc, bullSrc;
   datetime nowTime = time[0];

   // --- recorrido de antiguo a reciente -----------------------------
   for(int i = limit; i >= 0; i--)
     {
      // ===== swings =====
      prevLegSwing = legSwing;
      legSwing = Leg(i, InpSwingsLength, high, low, legSwing);
      if(legSwing != prevLegSwing)
        {
         int si = i + InpSwingsLength;
         if(legSwing == BULLISH_LEG)   // se formo un minimo
           {
            g_swingLow.lastLevel    = g_swingLow.currentLevel;
            g_swingLow.currentLevel = low[si];
            g_swingLow.crossed      = false;
            g_swingLow.barTime      = time[si];
            g_swingLow.barIndex     = si;
            g_trailing.bottom         = low[si];
            g_trailing.barTime        = time[si];
            g_trailing.barIndex       = si;
            g_trailing.lastBottomTime = time[si];
            if(InpShowSwings)
               MkText(NextName("SW"), time[si], low[si],
                      (g_swingLow.currentLevel < g_swingLow.lastLevel) ? "LL" : "HL",
                      InpSwingBullColor, ANCHOR_UPPER, 8);
           }
         else                          // se formo un maximo
           {
            g_swingHigh.lastLevel    = g_swingHigh.currentLevel;
            g_swingHigh.currentLevel = high[si];
            g_swingHigh.crossed      = false;
            g_swingHigh.barTime      = time[si];
            g_swingHigh.barIndex     = si;
            g_trailing.top         = high[si];
            g_trailing.barTime     = time[si];
            g_trailing.barIndex    = si;
            g_trailing.lastTopTime = time[si];
            if(InpShowSwings)
               MkText(NextName("SW"), time[si], high[si],
                      (g_swingHigh.currentLevel > g_swingHigh.lastLevel) ? "HH" : "LH",
                      InpSwingBearColor, ANCHOR_LOWER, 8);
           }
        }

      // ===== estructura interna (tamano fijo 5, como el Pine) =====
      prevLegInt = legInt;
      legInt = Leg(i, 5, high, low, legInt);
      if(legInt != prevLegInt)
        {
         int si = i + 5;
         if(legInt == BULLISH_LEG)
           {
            g_internalLow.lastLevel    = g_internalLow.currentLevel;
            g_internalLow.currentLevel = low[si];
            g_internalLow.crossed      = false;
            g_internalLow.barTime      = time[si];
            g_internalLow.barIndex     = si;
           }
         else
           {
            g_internalHigh.lastLevel    = g_internalHigh.currentLevel;
            g_internalHigh.currentLevel = high[si];
            g_internalHigh.crossed      = false;
            g_internalHigh.barTime      = time[si];
            g_internalHigh.barIndex     = si;
           }
        }

      // ===== EQH / EQL =====
      if(InpShowEqual)
        {
         prevLegEq = legEq;
         legEq = Leg(i, InpEqualLength, high, low, legEq);
         if(legEq != prevLegEq)
           {
            int si = i + InpEqualLength;
            if(legEq == BULLISH_LEG)
              {
               if(g_equalLow.barIndex >= 0 &&
                  MathAbs(g_equalLow.currentLevel - low[si]) < InpEqualThreshold * atr[i])
                 {
                  string b = NextName("EQL");
                  MkLine(b + "_l", g_equalLow.barTime, g_equalLow.currentLevel,
                         time[si], low[si], InpSwingBullColor, STYLE_DOT, false);
                  MkText(b + "_t", time[si], low[si], "EQL", InpSwingBullColor, ANCHOR_UPPER, 7);
                 }
               g_equalLow.currentLevel = low[si];
               g_equalLow.barTime      = time[si];
               g_equalLow.barIndex     = si;
              }
            else
              {
               if(g_equalHigh.barIndex >= 0 &&
                  MathAbs(g_equalHigh.currentLevel - high[si]) < InpEqualThreshold * atr[i])
                 {
                  string b = NextName("EQH");
                  MkLine(b + "_l", g_equalHigh.barTime, g_equalHigh.currentLevel,
                         time[si], high[si], InpSwingBearColor, STYLE_DOT, false);
                  MkText(b + "_t", time[si], high[si], "EQH", InpSwingBearColor, ANCHOR_LOWER, 7);
                 }
               g_equalHigh.currentLevel = high[si];
               g_equalHigh.barTime      = time[si];
               g_equalHigh.barIndex     = si;
              }
           }
        }

      // ===== rupturas de estructura =====
      bool bullBar = true, bearBar = true;
      if(InpIntConfluence)
        {
         bullBar = (high[i] - MathMax(close[i], open[i])) > (MathMin(close[i], open[i]) - low[i]);
         bearBar = (high[i] - MathMax(close[i], open[i])) < (MathMin(close[i], open[i]) - low[i]);
        }

      // --- interna alcista ---
      if((InpShowInternals || InpShowIntOB) && g_internalHigh.barIndex > i &&
         !g_internalHigh.crossed && close[i] > g_internalHigh.currentLevel &&
         g_internalHigh.currentLevel != g_swingHigh.currentLevel && bullBar)
        {
         bool isChoch = (g_internalTrend == BEARISH);
         g_internalHigh.crossed = true;
         g_internalTrend = BULLISH;
         bool show = InpShowInternals &&
                     (InpShowIntBull == SMC_ALL ||
                      (InpShowIntBull == SMC_BOS && !isChoch) ||
                      (InpShowIntBull == SMC_CHOCH && isChoch));
         if(show)
            DrawStructure(g_internalHigh, isChoch ? "CHoCH" : "BOS", InpIntBullColor,
                          STYLE_DASH, time[i], 7);
         if(InpShowIntOB)
            StoreOrderBlock(g_internalHigh, true, BULLISH, i, time, pHigh, pLow);
        }

      // --- interna bajista ---
      if((InpShowInternals || InpShowIntOB) && g_internalLow.barIndex > i &&
         !g_internalLow.crossed && close[i] < g_internalLow.currentLevel &&
         g_internalLow.currentLevel != g_swingLow.currentLevel && bearBar)
        {
         bool isChoch = (g_internalTrend == BULLISH);
         g_internalLow.crossed = true;
         g_internalTrend = BEARISH;
         bool show = InpShowInternals &&
                     (InpShowIntBear == SMC_ALL ||
                      (InpShowIntBear == SMC_BOS && !isChoch) ||
                      (InpShowIntBear == SMC_CHOCH && isChoch));
         if(show)
            DrawStructure(g_internalLow, isChoch ? "CHoCH" : "BOS", InpIntBearColor,
                          STYLE_DASH, time[i], 7);
         if(InpShowIntOB)
            StoreOrderBlock(g_internalLow, true, BEARISH, i, time, pHigh, pLow);
        }

      // --- swing alcista ---
      if((InpShowStructure || InpShowSwingOB || InpShowHighLow) && g_swingHigh.barIndex > i &&
         !g_swingHigh.crossed && close[i] > g_swingHigh.currentLevel)
        {
         bool isChoch = (g_swingTrend == BEARISH);
         g_swingHigh.crossed = true;
         g_swingTrend = BULLISH;
         bool show = InpShowStructure &&
                     (InpShowSwingBull == SMC_ALL ||
                      (InpShowSwingBull == SMC_BOS && !isChoch) ||
                      (InpShowSwingBull == SMC_CHOCH && isChoch));
         if(show)
            DrawStructure(g_swingHigh, isChoch ? "CHoCH" : "BOS", InpSwingBullColor,
                          STYLE_SOLID, time[i], 9);
         if(InpShowSwingOB)
            StoreOrderBlock(g_swingHigh, false, BULLISH, i, time, pHigh, pLow);
        }

      // --- swing bajista ---
      if((InpShowStructure || InpShowSwingOB || InpShowHighLow) && g_swingLow.barIndex > i &&
         !g_swingLow.crossed && close[i] < g_swingLow.currentLevel)
        {
         bool isChoch = (g_swingTrend == BULLISH);
         g_swingLow.crossed = true;
         g_swingTrend = BEARISH;
         bool show = InpShowStructure &&
                     (InpShowSwingBear == SMC_ALL ||
                      (InpShowSwingBear == SMC_BOS && !isChoch) ||
                      (InpShowSwingBear == SMC_CHOCH && isChoch));
         if(show)
            DrawStructure(g_swingLow, isChoch ? "CHoCH" : "BOS", InpSwingBearColor,
                          STYLE_SOLID, time[i], 9);
         if(InpShowSwingOB)
            StoreOrderBlock(g_swingLow, false, BEARISH, i, time, pHigh, pLow);
        }

      // ===== mitigacion de order blocks =====
      bearSrc = (InpOBMitigation == OBM_CLOSE) ? close[i] : high[i];
      bullSrc = (InpOBMitigation == OBM_CLOSE) ? close[i] : low[i];
      if(InpShowIntOB)   DeleteMitigated(true,  bearSrc, bullSrc);
      if(InpShowSwingOB) DeleteMitigated(false, bearSrc, bullSrc);

      // ===== fair value gaps (imbalance de 3 velas) =====
      if(InpShowFVG && i >= 1 && (i + 2) < rates_total)
        {
         double thr = 0.0;
         if(InpFVGAutoThreshold && open[i + 1] != 0.0)
            thr = MathAbs((close[i + 1] - open[i + 1]) / (open[i + 1] * 100.0)) * 2.0;
         double delta = (open[i + 1] != 0.0) ? (close[i + 1] - open[i + 1]) / (open[i + 1] * 100.0) : 0.0;
         datetime rEdge = time[i] + PeriodSeconds() * InpFVGExtend;

         if(low[i] > high[i + 2] && close[i + 1] > high[i + 2] && delta > thr)
            MkBox(NextName("FVG"), time[i + 1], low[i], rEdge, high[i + 2],
                  InpFVGBullColor, true, true);
         if(high[i] < low[i + 2] && close[i + 1] < low[i + 2] && -delta > thr)
            MkBox(NextName("FVG"), time[i + 1], high[i], rEdge, low[i + 2],
                  InpFVGBearColor, true, true);
        }

      // extremos de arrastre
      if(high[i] > g_trailing.top)    { g_trailing.top = high[i];    g_trailing.lastTopTime = time[i]; }
      if(low[i]  < g_trailing.bottom) { g_trailing.bottom = low[i];  g_trailing.lastBottomTime = time[i]; }
     }

   // --- pintado final -----------------------------------------------
   datetime rightEdge = nowTime + PeriodSeconds() * 20;

   if(InpShowIntOB)   DrawOrderBlocks(true,  rightEdge);
   if(InpShowSwingOB) DrawOrderBlocks(false, rightEdge);

   if(InpShowHighLow)
     {
      MkLine(PREFIX + "TT", g_trailing.lastTopTime, g_trailing.top, rightEdge,
             g_trailing.top, InpSwingBearColor, STYLE_SOLID, false);
      MkText(PREFIX + "TTx", rightEdge, g_trailing.top,
             (g_swingTrend == BEARISH) ? "Strong High" : "Weak High",
             InpSwingBearColor, ANCHOR_LEFT, 8);
      MkLine(PREFIX + "TB", g_trailing.lastBottomTime, g_trailing.bottom, rightEdge,
             g_trailing.bottom, InpSwingBullColor, STYLE_SOLID, false);
      MkText(PREFIX + "TBx", rightEdge, g_trailing.bottom,
             (g_swingTrend == BULLISH) ? "Strong Low" : "Weak Low",
             InpSwingBullColor, ANCHOR_LEFT, 8);
     }

   if(InpShowZones)
     {
      double top = g_trailing.top, bot = g_trailing.bottom;
      MkBox(PREFIX + "ZP", g_trailing.barTime, top, rightEdge,
            0.95 * top + 0.05 * bot, InpPremiumColor, true, true);
      MkBox(PREFIX + "ZE", g_trailing.barTime, 0.525 * top + 0.475 * bot, rightEdge,
            0.525 * bot + 0.475 * top, InpEquilibriumColor, true, true);
      MkBox(PREFIX + "ZD", g_trailing.barTime, 0.95 * bot + 0.05 * top, rightEdge,
            bot, InpDiscountColor, true, true);
      MkText(PREFIX + "ZPt", rightEdge, top, "Premium", InpPremiumColor, ANCHOR_LEFT, 8);
      MkText(PREFIX + "ZEt", rightEdge, (top + bot) / 2.0, "Equilibrium",
             InpEquilibriumColor, ANCHOR_LEFT, 8);
      MkText(PREFIX + "ZDt", rightEdge, bot, "Discount", InpDiscountColor, ANCHOR_LEFT, 8);
     }

   if(InpShowDaily)   DrawHtfLevel(PERIOD_D1, "D", rightEdge);
   if(InpShowWeekly)  DrawHtfLevel(PERIOD_W1, "W", rightEdge);
   if(InpShowMonthly) DrawHtfLevel(PERIOD_MN1, "M", rightEdge);

   ChartRedraw();
   return(rates_total);
  }
//+------------------------------------------------------------------+
