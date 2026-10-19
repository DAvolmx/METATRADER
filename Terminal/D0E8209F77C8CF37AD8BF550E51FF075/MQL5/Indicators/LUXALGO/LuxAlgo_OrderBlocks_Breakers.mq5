//+------------------------------------------------------------------+
//|  LuxAlgo_OrderBlocks_Breakers.mq5                                |
//|                                                                  |
//|  Port a MQL5 de "Order Blocks & Breaker Blocks [LuxAlgo]"        |
//|  (Pine Script v5).                                               |
//|                                                                  |
//|  OBRA ORIGINAL:  (c) LuxAlgo                                     |
//|  LICENCIA:       Attribution-NonCommercial-ShareAlike 4.0        |
//|                  International (CC BY-NC-SA 4.0)                 |
//|                  https://creativecommons.org/licenses/by-nc-sa/4.0/
//|                                                                  |
//|  Este port es una OBRA DERIVADA y hereda la misma licencia:      |
//|    - Atribucion: hay que mantener el credito a LuxAlgo.          |
//|    - NoComercial: NO se puede usar con fines comerciales. Vender  |
//|      o comercializar un producto basado en esto incumple la      |
//|      licencia.                                                   |
//|    - CompartirIgual: cualquier redistribucion debe llevar esta   |
//|      misma licencia.                                             |
//|                                                                  |
//|  NOTA SOBRE SU UTILIDAD, medida sobre 21 anos de oro real:       |
//|  los order blocks NO mostraron ventaja estadistica (contraste de |
//|  White p=0.835, y el 96.4% de caminos SIN estructura             |
//|  institucional superaron el mejor resultado real). Esto es una   |
//|  herramienta de LECTURA DISCRECIONAL del grafico, no una senal   |
//|  de entrada. Ver docs/HALLAZGOS.md del sistema.                  |
//+------------------------------------------------------------------+
#property copyright "Original (c) LuxAlgo - CC BY-NC-SA 4.0. Port MQL5."
#property link      "https://creativecommons.org/licenses/by-nc-sa/4.0/"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

//--- entradas (equivalentes a los input del Pine) -------------------
input int    InpLength   = 10;     // Swing Lookback (minimo 3)
input int    InpShowBull = 3;      // Mostrar ultimos OB alcistas
input int    InpShowBear = 3;      // Mostrar ultimos OB bajistas
input bool   InpUseBody  = false;  // Usar cuerpo de vela en vez de mechas
input group  "Estilo"
input color  InpBullCss      = C'33,87,243';   // OB alcista
input color  InpBullBreakCss = C'255,17,0';    // Ruptura alcista (breaker)
input color  InpBearCss      = C'255,93,0';    // OB bajista
input color  InpBearBreakCss = C'12,181,26';   // Ruptura bajista (breaker)
input bool   InpShowLabels   = false;          // Marcar cambios de polaridad
input int    InpMaxBars      = 2000;           // Barras a analizar (0 = todas)

#define PREFIX "LUXOB_"
#define MAX_OB 100

//--- Order block. Equivale al UDT `ob` del Pine.
struct SOb
  {
   double            top;
   double            btm;
   datetime          loc;        // tiempo de la vela que forma el bloque
   bool              breaker;    // true cuando el precio lo ha roto
   datetime          break_loc;  // tiempo de la ruptura
  };

//--- Swing. Equivale al UDT `swing` del Pine.
struct SSwing
  {
   double            y;
   int               x;          // indice de barra (serie: 0 = actual)
   bool              crossed;
  };

SOb   g_bull[];      // pila de OB alcistas (indice 0 = el mas reciente)
SOb   g_bear[];
int   g_bullN = 0;
int   g_bearN = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpLength < 3)
     {
      Print("LuxAlgo OB: 'Swing Lookback' debe ser >= 3");
      return(INIT_PARAMETERS_INCORRECT);
     }
   ArrayResize(g_bull, MAX_OB);
   ArrayResize(g_bear, MAX_OB);
   IndicatorSetString(INDICATOR_SHORTNAME, "LuxAlgo OB & Breakers");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Mete un OB al principio de la pila (equivale a array.unshift).   |
//+------------------------------------------------------------------+
void PushOb(SOb &arr[], int &n, const SOb &item)
  {
   if(n >= MAX_OB)
      n = MAX_OB - 1;                       // descarta el mas antiguo
   for(int i = n; i > 0; i--)
      arr[i] = arr[i - 1];
   arr[0] = item;
   n++;
  }

//+------------------------------------------------------------------+
//| Quita el OB de la posicion idx (equivale a array.remove).        |
//+------------------------------------------------------------------+
void RemoveOb(SOb &arr[], int &n, const int idx)
  {
   if(idx < 0 || idx >= n)
      return;
   for(int i = idx; i < n - 1; i++)
      arr[i] = arr[i + 1];
   n--;
  }

//+------------------------------------------------------------------+
//| Dibuja un rectangulo. OBJPROP_BACK lo manda detras de las velas, |
//| que es lo mas parecido a la transparencia del Pine: MQL5 no      |
//| admite canal alfa en los objetos estandar del grafico.           |
//+------------------------------------------------------------------+
void DrawBox(const string name, datetime t1, double p1, datetime t2, double p2,
             color clr, bool fill)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   else
     {
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, fill);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawLine(const string name, datetime t1, double p1, datetime t2, double p2,
              color clr, ENUM_LINE_STYLE style, bool ray)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   else
     {
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, ray);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawText(const string name, datetime t, double p, const string txt,
              color clr, int anchor)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, p);
   else
     {
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p);
     }
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| Pinta un OB con el mismo criterio que `method display` del Pine: |
//| si ya es breaker, se parte en dos zonas (antes y despues de la   |
//| ruptura) con el color invertido en la segunda.                   |
//+------------------------------------------------------------------+
void DisplayOb(const SOb &id, const string tag, color css, color breakCss,
               datetime rightEdge)
  {
   if(id.breaker)
     {
      DrawBox(PREFIX + tag + "_a", id.loc, id.top, id.break_loc, id.btm, css, true);
      DrawBox(PREFIX + tag + "_b", id.break_loc, id.top, rightEdge, id.btm, breakCss, true);
      DrawLine(PREFIX + tag + "_lt", id.loc, id.top, id.break_loc, id.top, css, STYLE_SOLID, false);
      DrawLine(PREFIX + tag + "_lb", id.loc, id.btm, id.break_loc, id.btm, css, STYLE_SOLID, false);
      DrawLine(PREFIX + tag + "_bt", id.break_loc, id.top, rightEdge, id.top, breakCss, STYLE_DASH, true);
      DrawLine(PREFIX + tag + "_bb", id.break_loc, id.btm, rightEdge, id.btm, breakCss, STYLE_DASH, true);
     }
   else
     {
      DrawBox(PREFIX + tag + "_a", id.loc, id.top, rightEdge, id.btm, css, true);
      DrawLine(PREFIX + tag + "_lt", id.loc, id.top, rightEdge, id.top, css, STYLE_SOLID, true);
      DrawLine(PREFIX + tag + "_lb", id.loc, id.btm, rightEdge, id.btm, css, STYLE_SOLID, true);
     }
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
   int need = InpLength * 3 + 10;
   if(rates_total < need)
      return(0);

   // Series: indice 0 = vela actual, igual que en Pine.
   ArraySetAsSeries(time,  true);
   ArraySetAsSeries(open,  true);
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);

   // El Pine borra TODAS las cajas y lineas en cada barra y vuelve a
   // dibujar solo las N ultimas. Aqui se hace lo mismo: se recalcula el
   // historico acotado y se redibuja. Es mas caro que un calculo
   // incremental, pero reproduce exactamente su comportamiento y evita
   // que queden objetos huerfanos de bloques ya mitigados.
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
   g_bullN = 0;
   g_bearN = 0;

   int limit = (InpMaxBars > 0) ? MathMin(InpMaxBars, rates_total - need) : rates_total - need;
   if(limit < 1)
      return(0);

   SSwing top, btm;
   top.y = 0.0; top.x = -1; top.crossed = false;
   btm.y = 0.0; btm.x = -1; btm.crossed = false;
   int os = 0, osPrev = 0;

   // Recorrido de la barra mas antigua a la mas reciente (i decreciente
   // porque el array es serie).
   for(int i = limit; i >= 0; i--)
     {
      // --- deteccion de swing, equivalente a la funcion swings(len) ---
      // upper/lower son el maximo/minimo de las ultimas `len` barras
      // CONTANDO la actual; high[len] es la barra de hace `len`.
      double upper = high[i];
      double lower = low[i];
      for(int k = 1; k < InpLength; k++)
        {
         if(high[i + k] > upper) upper = high[i + k];
         if(low[i + k]  < lower) lower = low[i + k];
        }

      osPrev = os;
      if(high[i + InpLength] > upper)
         os = 0;
      else
         if(low[i + InpLength] < lower)
            os = 1;

      if(os == 0 && osPrev != 0)
        {
         top.y = high[i + InpLength];
         top.x = i + InpLength;
         top.crossed = false;
        }
      if(os == 1 && osPrev != 1)
        {
         btm.y = low[i + InpLength];
         btm.x = i + InpLength;
         btm.crossed = false;
        }

      double maxSrc = InpUseBody ? MathMax(close[i], open[i]) : high[i];
      double minSrc = InpUseBody ? MathMin(close[i], open[i]) : low[i];

      // --- OB ALCISTA: el precio cierra por encima del swing high ---
      if(top.x >= 0 && close[i] > top.y && !top.crossed)
        {
         top.crossed = true;

         // Se busca, entre el swing y la barra actual, la vela de minimo
         // mas bajo: esa es la que forma el bloque.
         double minima = InpUseBody ? MathMin(close[i + 1], open[i + 1]) : low[i + 1];
         double maxima = InpUseBody ? MathMax(close[i + 1], open[i + 1]) : high[i + 1];
         datetime loc  = time[i + 1];

         for(int k = 1; k <= (top.x - i) - 1; k++)
           {
            double lo = InpUseBody ? MathMin(close[i + k], open[i + k]) : low[i + k];
            double hi = InpUseBody ? MathMax(close[i + k], open[i + k]) : high[i + k];
            if(lo < minima)
              {
               minima = lo;
               maxima = hi;
               loc    = time[i + k];
              }
           }

         SOb nb;
         nb.top = maxima; nb.btm = minima; nb.loc = loc;
         nb.breaker = false; nb.break_loc = 0;
         PushOb(g_bull, g_bullN, nb);
        }

      // --- OB BAJISTA: el precio cierra por debajo del swing low ---
      if(btm.x >= 0 && close[i] < btm.y && !btm.crossed)
        {
         btm.crossed = true;

         double maxima = InpUseBody ? MathMax(close[i + 1], open[i + 1]) : high[i + 1];
         double minima = InpUseBody ? MathMin(close[i + 1], open[i + 1]) : low[i + 1];
         datetime loc  = time[i + 1];

         for(int k = 1; k <= (btm.x - i) - 1; k++)
           {
            double hi = InpUseBody ? MathMax(close[i + k], open[i + k]) : high[i + k];
            double lo = InpUseBody ? MathMin(close[i + k], open[i + k]) : low[i + k];
            if(hi > maxima)
              {
               maxima = hi;
               minima = lo;
               loc    = time[i + k];
              }
           }

         SOb nb;
         nb.top = maxima; nb.btm = minima; nb.loc = loc;
         nb.breaker = false; nb.break_loc = 0;
         PushOb(g_bear, g_bearN, nb);
        }

      // --- mitigacion y conversion en breaker (alcistas) ---
      for(int j = g_bullN - 1; j >= 0; j--)
        {
         if(!g_bull[j].breaker)
           {
            if(MathMin(close[i], open[i]) < g_bull[j].btm)
              {
               g_bull[j].breaker   = true;
               g_bull[j].break_loc = time[i];
              }
           }
         else
            if(close[i] > g_bull[j].top)
               RemoveOb(g_bull, g_bullN, j);
        }

      // --- mitigacion y conversion en breaker (bajistas) ---
      for(int j = g_bearN - 1; j >= 0; j--)
        {
         if(!g_bear[j].breaker)
           {
            if(MathMax(close[i], open[i]) > g_bear[j].top)
              {
               g_bear[j].breaker   = true;
               g_bear[j].break_loc = time[i];
              }
           }
         else
            if(close[i] < g_bear[j].btm)
               RemoveOb(g_bear, g_bearN, j);
        }
     }

   // --- pintado: solo los N mas recientes de cada lado ---
   datetime rightEdge = time[0] + PeriodSeconds() * 10;

   int nb2 = MathMin(InpShowBull, g_bullN);
   for(int i = 0; i < nb2; i++)
      DisplayOb(g_bull[i], "BULL" + IntegerToString(i), InpBullCss, InpBullBreakCss, rightEdge);

   int ns = MathMin(InpShowBear, g_bearN);
   for(int i = 0; i < ns; i++)
      DisplayOb(g_bear[i], "BEAR" + IntegerToString(i), InpBearCss, InpBearBreakCss, rightEdge);

   if(InpShowLabels)
     {
      if(top.x >= 0 && top.x < rates_total)
         DrawText(PREFIX + "POL_T", time[top.x], top.y, "▼", InpBearCss, ANCHOR_LOWER);
      if(btm.x >= 0 && btm.x < rates_total)
         DrawText(PREFIX + "POL_B", time[btm.x], btm.y, "▲", InpBullCss, ANCHOR_UPPER);
     }

   ChartRedraw();
   return(rates_total);
  }
//+------------------------------------------------------------------+
