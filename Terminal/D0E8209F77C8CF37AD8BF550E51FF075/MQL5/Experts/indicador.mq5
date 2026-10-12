//+------------------------------------------------------------------+
//|                                        SMC_SLTP_Indicator.mq5     |
//|  Indicador visual: dibuja en el gráfico las líneas de Entrada,    |
//|  Stop Loss, TP1 y TP2 cada vez que se detecta un BOS/CHoCH,       |
//|  usando la misma lógica de swings/zonas del SMC_EA.               |
//|                                                                    |
//|  Sirve para ver el nivel de SL/TP directo en el chart, sin        |
//|  necesidad de que el EA esté ejecutando operaciones (útil para    |
//|  seguimiento manual, igual que el bot de alertas en Python).      |
//+------------------------------------------------------------------+
#property copyright "Hugo"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//--- Parámetros de entrada (mismos nombres que el EA para mantener consistencia)
input int    FractalRange       = 3;    // velas a cada lado para validar swing
input int    ZoneLookback       = 96;   // velas para construir zonas (24h en M15)
input int    MajorSwingLookback = 200;  // velas para el swing mayor (TP2)
input color  ColorEntry         = clrWhite;
input color  ColorSL            = clrRed;
input color  ColorTP1           = clrDodgerBlue;
input color  ColorTP2           = clrLime;
input bool   ShowZones          = true; // dibujar también las cajas discount/premium

//--- Estado de estructura (igual que en el EA)
double lastSwingHigh = 0;
double lastSwingLow  = 0;
bool   lastSwingHighSet = false;
bool   lastSwingLowSet  = false;
string trend = "none";

datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                          |
//+------------------------------------------------------------------+
int OnInit()
  {
   IndicatorSetString(INDICATOR_SHORTNAME, "SMC SL/TP");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, "SMC_");
  }

//+------------------------------------------------------------------+
//| Swing detection (idéntico al EA)                                  |
//+------------------------------------------------------------------+
bool IsSwingHigh(int shift, const double &high[])
  {
   for(int i = 1; i <= FractalRange; i++)
      if(high[shift] <= high[shift - i] || high[shift] <= high[shift + i])
         return false;
   return true;
  }

bool IsSwingLow(int shift, const double &low[])
  {
   for(int i = 1; i <= FractalRange; i++)
      if(low[shift] >= low[shift - i] || low[shift] >= low[shift + i])
         return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Construye zonas discount/premium                                  |
//+------------------------------------------------------------------+
void BuildZones(double &premiumTop, double &premiumBottom,
                double &discountTop, double &discountBottom)
  {
   double highestHigh = iHigh(_Symbol, _Period, iHighest(_Symbol, _Period, MODE_HIGH, ZoneLookback, 1));
   double lowestLow   = iLow(_Symbol, _Period, iLowest(_Symbol, _Period, MODE_LOW, ZoneLookback, 1));
   double span = highestHigh - lowestLow;

   premiumTop    = highestHigh;
   premiumBottom = highestHigh - span * 0.33;

   discountTop    = lowestLow + span * 0.33;
   discountBottom = lowestLow;
  }

//+------------------------------------------------------------------+
//| Dibuja una línea horizontal con etiqueta                          |
//+------------------------------------------------------------------+
void DrawLevel(string name, double price, color clr, string text)
  {
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetString(0, name, OBJPROP_TEXT, text);

   string labelName = name + "_lbl";
   ObjectDelete(0, labelName);
   ObjectCreate(0, labelName, OBJ_TEXT, 0, TimeCurrent(), price);
   ObjectSetString(0, labelName, OBJPROP_TEXT, "  " + text + " " + DoubleToString(price, _Digits));
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_LEFT);
  }

//+------------------------------------------------------------------+
//| Dibuja una caja (zona) semitransparente entre dos precios          |
//+------------------------------------------------------------------+
void DrawZoneBox(string name, double top, double bottom, color clr, datetime fromTime)
  {
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, fromTime, top, TimeCurrent() + PeriodSeconds(_Period) * 20, bottom);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
  }

//+------------------------------------------------------------------+
//| Pinta el set completo de niveles para una señal detectada          |
//+------------------------------------------------------------------+
void PlotSignal(bool isShort, double entry, double sl, double tp1, double tp2,
                double premiumTop, double premiumBottom,
                double discountTop, double discountBottom, datetime signalTime)
  {
   DrawLevel("SMC_Entry", entry, ColorEntry, isShort ? "Entrada SHORT" : "Entrada LONG");
   DrawLevel("SMC_SL",    sl,    ColorSL,    "SL");
   DrawLevel("SMC_TP1",   tp1,   ColorTP1,   "TP1");
   DrawLevel("SMC_TP2",   tp2,   ColorTP2,   "TP2");

   if(ShowZones)
     {
      DrawZoneBox("SMC_ZonePremium",  premiumTop,  premiumBottom,  ColorLighten(clrTomato), signalTime);
      DrawZoneBox("SMC_ZoneDiscount", discountTop, discountBottom, ColorLighten(clrSeaGreen), signalTime);
     }

   Comment(StringFormat(
      "SMC SL/TP\nDirección: %s\nEntrada: %.3f\nSL: %.3f\nTP1: %.3f\nTP2: %.3f",
      isShort ? "SHORT" : "LONG", entry, sl, tp1, tp2));
  }

//+------------------------------------------------------------------+
//| Helper: color aproximado más claro (para las cajas de zona)       |
//+------------------------------------------------------------------+
color ColorLighten(color c)
  {
   // MQL5 no soporta alpha real en OBJ_RECTANGLE, se usa un color plano suave
   return c;
  }

//+------------------------------------------------------------------+
//| Custom indicator iteration function                               |
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
   datetime currentBarTime = time[rates_total - 1];
   if(currentBarTime == lastBarTime)
      return(rates_total);
   lastBarTime = currentBarTime;

   int needed = MathMax(MajorSwingLookback, ZoneLookback) + FractalRange * 2 + 5;
   if(rates_total < needed)
      return(rates_total);

   int shift = rates_total - 1 - (FractalRange + 1); // equivalente a shift=FractalRange+1 en serie invertida

   // Convertimos a arrays "como serie" para reutilizar la misma lógica que el EA
   double h[], l[];
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   ArrayResize(h, needed);
   ArrayResize(l, needed);
   for(int i = 0; i < needed; i++)
     {
      h[i] = high[rates_total - 1 - i];
      l[i] = low[rates_total - 1 - i];
     }

   int sShift = FractalRange + 1;

   if(IsSwingHigh(sShift, h))
     {
      lastSwingHigh = h[sShift];
      lastSwingHighSet = true;
     }
   if(IsSwingLow(sShift, l))
     {
      lastSwingLow = l[sShift];
      lastSwingLowSet = true;
     }

   double currentClose = close[rates_total - 1];
   double premiumTop, premiumBottom, discountTop, discountBottom;

   if(lastSwingHighSet && currentClose > lastSwingHigh)
     {
      trend = "up";
      lastSwingHighSet = false;
      BuildZones(premiumTop, premiumBottom, discountTop, discountBottom);

      double entry = currentClose;
      double sl    = discountBottom;
      double tp1   = premiumBottom;
      double tp2   = iHigh(_Symbol, _Period, iHighest(_Symbol, _Period, MODE_HIGH, MajorSwingLookback, 1));

      if(tp1 > entry && tp2 > tp1)
         PlotSignal(false, entry, sl, tp1, tp2, premiumTop, premiumBottom, discountTop, discountBottom, currentBarTime);
     }

   if(lastSwingLowSet && currentClose < lastSwingLow)
     {
      trend = "down";
      lastSwingLowSet = false;
      BuildZones(premiumTop, premiumBottom, discountTop, discountBottom);

      double entry = currentClose;
      double sl    = premiumTop;
      double tp1   = discountTop;
      double tp2   = iLow(_Symbol, _Period, iLowest(_Symbol, _Period, MODE_LOW, MajorSwingLookback, 1));

      if(tp1 < entry && tp2 < tp1)
         PlotSignal(true, entry, sl, tp1, tp2, premiumTop, premiumBottom, discountTop, discountBottom, currentBarTime);
     }

   return(rates_total);
  }
//+------------------------------------------------------------------+