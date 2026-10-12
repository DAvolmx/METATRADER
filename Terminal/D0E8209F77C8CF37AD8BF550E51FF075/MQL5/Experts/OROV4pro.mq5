//+------------------------------------------------------------------+
//|                                   SMC_BOS_CHoCH_Indicator.mq5     |
//|  Indicador visual de estructura de mercado (SMC) para MT5         |
//|                                                                   |
//|   - Detecta swings con Fractals (ventana ajustable)              |
//|   - Marca BOS  (Break of Structure  = continuación)              |
//|   - Marca CHoCH(Change of Character = cambio de tendencia)       |
//|                                                                   |
//|   Colores por defecto:                                           |
//|     BOS alcista = azul   / BOS bajista = rojo-naranja            |
//|     CHoCH alcista = verde / CHoCH bajista = magenta             |
//|                                                                   |
//|   Sin repintado: confirma swings solo con velas cerradas y       |
//|   marca la ruptura en el cierre de la vela que rompe.            |
//+------------------------------------------------------------------+
#property copyright "Hugo"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   4

//--- Plot 1: BOS alcista
#property indicator_label1  "BOS Alcista"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue
#property indicator_width1  2
//--- Plot 2: BOS bajista
#property indicator_label2  "BOS Bajista"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrOrangeRed
#property indicator_width2  2
//--- Plot 3: CHoCH alcista
#property indicator_label3  "CHoCH Alcista"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrLime
#property indicator_width3  2
//--- Plot 4: CHoCH bajista
#property indicator_label4  "CHoCH Bajista"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrMagenta
#property indicator_width4  2

//====================== PARÁMETROS =================================
input int  FractalRange = 3;      // velas a cada lado para validar el swing
input bool ShowLabels   = true;   // mostrar etiquetas "BOS" / "CHoCH"
input bool ShowLevelLine= true;   // dibujar la línea del nivel roto

//====================== BUFFERS ====================================
double BosBull[], BosBear[], ChochBull[], ChochBear[];

//====================== ESTADO PERSISTENTE =========================
double   lastSwingHigh = 0, lastSwingLow = 0;
datetime lastSwingHighTime = 0, lastSwingLowTime = 0;
bool     lastSwingHighSet = false, lastSwingLowSet = false;
string   trend = "none";
int      g_lastBar = -1;

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BosBull,   INDICATOR_DATA);
   SetIndexBuffer(1, BosBear,   INDICATOR_DATA);
   SetIndexBuffer(2, ChochBull, INDICATOR_DATA);
   SetIndexBuffer(3, ChochBear, INDICATOR_DATA);

   PlotIndexSetInteger(0, PLOT_ARROW, 233);   // flecha arriba
   PlotIndexSetInteger(1, PLOT_ARROW, 234);   // flecha abajo
   PlotIndexSetInteger(2, PLOT_ARROW, 233);
   PlotIndexSetInteger(3, PLOT_ARROW, 234);

   for(int i = 0; i < 4; i++)
      PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, 0.0);

   IndicatorSetString(INDICATOR_SHORTNAME, "SMC BOS/CHoCH");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, "SMCIND_");
  }

//+------------------------------------------------------------------+
//| Etiqueta de texto                                                 |
//+------------------------------------------------------------------+
void DrawLabel(datetime t, double price, string txt, color col, bool bullish)
  {
   string name = "SMCIND_tx_" + txt + "_" + IntegerToString((long)t);
   if(ObjectFind(0, name) >= 0) return;
   if(ObjectCreate(0, name, OBJ_TEXT, 0, t, price))
     {
      ObjectSetString (0, name, OBJPROP_TEXT, " " + txt);
      ObjectSetInteger(0, name, OBJPROP_COLOR, col);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, bullish ? ANCHOR_UPPER : ANCHOR_LOWER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
     }
  }

//+------------------------------------------------------------------+
//| Línea del nivel roto                                              |
//+------------------------------------------------------------------+
void DrawLevelLine(datetime t1, datetime t2, double level, string txt, color col, bool isCHoCH)
  {
   if(!ShowLevelLine) return;
   string name = "SMCIND_ln_" + txt + "_" + IntegerToString((long)t2);
   if(ObjectFind(0, name) >= 0) return;
   if(ObjectCreate(0, name, OBJ_TREND, 0, t1, level, t2, level))
     {
      ObjectSetInteger(0, name, OBJPROP_COLOR, col);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_STYLE, isCHoCH ? STYLE_SOLID : STYLE_DASH);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
     }
  }

//+------------------------------------------------------------------+
//| OnCalculate                                                       |
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
   if(rates_total < 2 * FractalRange + 3)
      return(0);

   //--- Recalculo total (primera vez o cambio de histórico)
   if(prev_calculated == 0)
     {
      ArrayInitialize(BosBull,   0.0);
      ArrayInitialize(BosBear,   0.0);
      ArrayInitialize(ChochBull, 0.0);
      ArrayInitialize(ChochBear, 0.0);
      ObjectsDeleteAll(0, "SMCIND_");
      trend = "none";
      lastSwingHighSet = false;
      lastSwingLowSet  = false;
      lastSwingHigh = 0; lastSwingLow = 0;
      g_lastBar = 2 * FractalRange;   // primer bar a procesar = g_lastBar + 1
     }

   int firstClosed = rates_total - 2;   // último bar cerrado (rates_total-1 = en formación)

   for(int j = g_lastBar + 1; j <= firstClosed; j++)
     {
      //--- Confirmar swing centrado en la vela (j - FractalRange)
      int c = j - FractalRange;
      if(c - FractalRange >= 0)
        {
         bool sh = true, sl = true;
         for(int k = 1; k <= FractalRange; k++)
           {
            if(high[c] <= high[c - k] || high[c] <= high[c + k]) sh = false;
            if(low[c]  >= low[c - k]  || low[c]  >= low[c + k])  sl = false;
           }
         if(sh) { lastSwingHigh = high[c]; lastSwingHighTime = time[c]; lastSwingHighSet = true; }
         if(sl) { lastSwingLow  = low[c];  lastSwingLowTime  = time[c]; lastSwingLowSet  = true; }
        }

      double range = high[j] - low[j];
      double off   = (range > 0) ? range * 0.5 : 10 * _Point;

      //--- Ruptura alcista (cierre por encima del último swing high)
      if(lastSwingHighSet && close[j] > lastSwingHigh)
        {
         bool  isBOS = (trend == "up");
         color col   = isBOS ? clrDodgerBlue : clrLime;
         double y    = low[j] - off;
         if(isBOS) BosBull[j] = y; else ChochBull[j] = y;

         string txt = isBOS ? "BOS" : "CHoCH";
         if(ShowLabels)   DrawLabel(time[j], y, txt, col, true);
         DrawLevelLine(lastSwingHighTime, time[j], lastSwingHigh, txt + "u", col, !isBOS);

         trend = "up";
         lastSwingHighSet = false;
        }

      //--- Ruptura bajista (cierre por debajo del último swing low)
      if(lastSwingLowSet && close[j] < lastSwingLow)
        {
         bool  isBOS = (trend == "down");
         color col   = isBOS ? clrOrangeRed : clrMagenta;
         double y    = high[j] + off;
         if(isBOS) BosBear[j] = y; else ChochBear[j] = y;

         string txt = isBOS ? "BOS" : "CHoCH";
         if(ShowLabels)   DrawLabel(time[j], y, txt, col, false);
         DrawLevelLine(lastSwingLowTime, time[j], lastSwingLow, txt + "d", col, !isBOS);

         trend = "down";
         lastSwingLowSet = false;
        }
     }

   if(firstClosed > g_lastBar)
      g_lastBar = firstClosed;

   return(rates_total);
  }
//+------------------------------------------------------------------+