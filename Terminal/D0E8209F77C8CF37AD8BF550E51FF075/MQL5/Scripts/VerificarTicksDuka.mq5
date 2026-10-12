//+------------------------------------------------------------------+
//|  VerificarTicksDuka.mq5                                          |
//|  Verifica que el simbolo XAUUSD_DUKA tiene ticks cargados        |
//|  y muestra estadisticas en el Diario (Journal).                  |
//+------------------------------------------------------------------+
#property script_show_inputs

input string InpSimbolo = "XAUUSD_DUKA";   // Simbolo a verificar
input int    InpDias    = 5;                // Dias a revisar desde el inicio

void OnStart()
  {
   Print("=== Verificacion XAUUSD_DUKA ===");

   // Verificar que el simbolo existe
   if(!SymbolSelect(InpSimbolo, true))
     {
      Print("ERROR: El simbolo '", InpSimbolo, "' no existe.");
      Print("Ejecuta primero ImportarTicksDuka.mq5");
      return;
     }

   Print("Simbolo encontrado: ", InpSimbolo);

   // Obtener rango de fechas disponibles
   datetime dt_inicio = (datetime)SymbolInfoInteger(InpSimbolo, SYMBOL_START_TIME);
   datetime dt_ahora  = TimeCurrent();

   if(dt_inicio == 0)
     {
      Print("ADVERTENCIA: No se pudo leer SYMBOL_START_TIME.");
      dt_inicio = StringToTime("2018.01.01 00:00:00");
     }

   Print("Fecha inicio datos: ", TimeToString(dt_inicio, TIME_DATE|TIME_SECONDS));

   // Leer los primeros ticks disponibles
   datetime dt_fin_prueba = dt_inicio + InpDias * 86400;
   MqlTick ticks_buf[];

   long n = CopyTicksRange(InpSimbolo, ticks_buf, COPY_TICKS_ALL,
                            (long)dt_inicio * 1000,
                            (long)dt_fin_prueba * 1000);

   if(n <= 0)
     {
      Print("RESULTADO: 0 ticks encontrados en los primeros ", InpDias, " dias.");
      Print("El simbolo existe pero no tiene datos cargados.");
      Print("Asegurate de haber ejecutado ImportarTicksDuka.mq5 correctamente.");
      return;
     }

   // Estadisticas
   MqlTick t_pri = ticks_buf[0];
   MqlTick t_ult = ticks_buf[n - 1];

   double spread_sum = 0;
   double bid_min = t_pri.bid, bid_max = t_pri.bid;
   double ask_min = t_pri.ask, ask_max = t_pri.ask;

   for(long i = 0; i < n; i++)
     {
      spread_sum += ticks_buf[i].ask - ticks_buf[i].bid;
      if(ticks_buf[i].bid < bid_min) bid_min = ticks_buf[i].bid;
      if(ticks_buf[i].bid > bid_max) bid_max = ticks_buf[i].bid;
      if(ticks_buf[i].ask < ask_min) ask_min = ticks_buf[i].ask;
      if(ticks_buf[i].ask > ask_max) ask_max = ticks_buf[i].ask;
     }

   double spread_medio = spread_sum / n;

   Print("==============================");
   Print("RESULTADO VERIFICACION:");
   Print("  Ticks cargados:    ", n);
   Print("  Primer tick:       ", TimeToString(t_pri.time, TIME_DATE|TIME_SECONDS),
         "  BID=", DoubleToString(t_pri.bid, 3),
         "  ASK=", DoubleToString(t_pri.ask, 3));
   Print("  Ultimo tick:       ", TimeToString(t_ult.time, TIME_DATE|TIME_SECONDS),
         "  BID=", DoubleToString(t_ult.bid, 3),
         "  ASK=", DoubleToString(t_ult.ask, 3));
   Print("  BID rango:         ", DoubleToString(bid_min,3), " - ", DoubleToString(bid_max,3));
   Print("  ASK rango:         ", DoubleToString(ask_min,3), " - ", DoubleToString(ask_max,3));
   Print("  Spread medio:      ", DoubleToString(spread_medio, 3), " USD");
   Print("==============================");

   if(n > 1000)
      Print("OK - Datos cargados correctamente. Listo para backtesting.");
   else
      Print("ADVERTENCIA - Pocos ticks (", n, "). Revisa la importacion.");
  }
//+------------------------------------------------------------------+
