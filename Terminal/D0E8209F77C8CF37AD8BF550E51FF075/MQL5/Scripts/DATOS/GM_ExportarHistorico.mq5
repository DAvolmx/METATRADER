//+------------------------------------------------------------------+
//|  GM_ExportarHistorico.mq5                                        |
//|                                                                  |
//|  Exporta TODA la historia disponible de un simbolo a CSV, en el  |
//|  formato que lee python/core/gm_data.py sin configuracion.       |
//|                                                                  |
//|  Es el puente de datos del sistema: lo que exportes aqui es lo    |
//|  que calibra la ecuacion maestra, alimenta el detector de order  |
//|  blocks y corre en el Monte Carlo. Usa el simbolo QUE VAS A       |
//|  OPERAR, no un proxy: el spread, el horario y los huecos de tu    |
//|  broker forman parte del resultado.                              |
//|                                                                  |
//|  SOLO LECTURA sobre el mercado: unicamente escribe un fichero.   |
//|                                                                  |
//|  SALIDA: MQL5/Files/GoldMaster/<SIMBOLO>_<TF>.csv                |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict
#property description "Exporta el historico de un simbolo a CSV para el laboratorio Python"

input string          InpSimbolo = "";              // Simbolo (vacio = el del grafico)
input ENUM_TIMEFRAMES InpTF      = PERIOD_H1;       // Temporalidad
input datetime        InpDesde   = D'2004.01.01';   // Desde
input datetime        InpHasta   = 0;               // Hasta (0 = ahora)
input int             InpMaxBarras = 2000000;       // Tope de barras

//+------------------------------------------------------------------+
int OnStart()
  {
   string sym = (InpSimbolo == "" ? _Symbol : InpSimbolo);
   datetime hasta = (InpHasta == 0 ? TimeCurrent() : InpHasta);

   if(!SymbolSelect(sym, true))
     {
      PrintFormat("ERROR: el simbolo '%s' no existe en este broker. "
                  "Ejecuta GM_InventarioSimbolos.mq5 para ver los disponibles.", sym);
      return(1);
     }

   // El terminal descarga la historia de forma perezosa: hay que pedirla y
   // esperar. Sin esta espera un simbolo con 20 anos devuelve 0 barras y
   // parece que no hay datos.
   PrintFormat("Pidiendo historia de %s %s…", sym, EnumToString(InpTF));
   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copiadas = -1;
   for(int intento = 0; intento < 60 && copiadas <= 0; intento++)
     {
      copiadas = CopyRates(sym, InpTF, InpDesde, hasta, rates);
      if(copiadas <= 0)
        {
         Sleep(500);
         if(intento % 10 == 9)
            PrintFormat("  … sincronizando (%d s)", (intento + 1) / 2);
        }
     }
   if(copiadas <= 0)
     {
      PrintFormat("ERROR: 0 barras de %s %s (error %d). Abre un grafico de ese "
                  "simbolo y desplazate hacia atras para forzar la descarga.",
                  sym, EnumToString(InpTF), GetLastError());
      return(1);
     }
   if(copiadas > InpMaxBarras)
     {
      PrintFormat("Aviso: %d barras exceden el tope (%d); se exportan las mas recientes.",
                  copiadas, InpMaxBarras);
      // conserva la cola, que es la informacion mas relevante para operar
      int sobran = copiadas - InpMaxBarras;
      ArrayRemove(rates, 0, sobran);
      copiadas = InpMaxBarras;
     }

   string dir = "GoldMaster";
   if(!FolderCreate(dir, FILE_COMMON) && GetLastError() != 5019)
      PrintFormat("Aviso: FolderCreate devolvio %d", GetLastError());
   ResetLastError();

   string tfs = EnumToString(InpTF);
   StringReplace(tfs, "PERIOD_", "");
   string path = StringFormat("%s\\%s_%s.csv", dir, sym, tfs);
   int fh = FileOpen(path, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(fh == INVALID_HANDLE)
     {
      PrintFormat("ERROR: no se pudo abrir %s (error %d)", path, GetLastError());
      return(1);
     }

   // Cabecera con el mismo formato que exporta MetaTrader, que gm_data.py ya
   // entiende: separador TAB y marcas <CAMPO>.
   FileWrite(fh, "<DATE>\t<TIME>\t<OPEN>\t<HIGH>\t<LOW>\t<CLOSE>\t<TICKVOL>\t<VOL>\t<SPREAD>");

   int dig = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   int malas = 0;
   for(int i = 0; i < copiadas; i++)
     {
      // Descarta barras corruptas en vez de exportarlas: una vela con minimo
      // por encima del maximo, o con precio cero, envenena la calibracion y
      // es dificil de detectar aguas abajo.
      if(rates[i].close <= 0.0 || rates[i].open <= 0.0 ||
         rates[i].high < rates[i].low ||
         rates[i].high < rates[i].close || rates[i].low > rates[i].close)
        {
         malas++;
         continue;
        }
      FileWrite(fh, StringFormat("%s\t%s\t%s\t%s\t%s\t%s\t%I64d\t%I64d\t%d",
                                 TimeToString(rates[i].time, TIME_DATE),
                                 TimeToString(rates[i].time, TIME_MINUTES | TIME_SECONDS),
                                 DoubleToString(rates[i].open,  dig),
                                 DoubleToString(rates[i].high,  dig),
                                 DoubleToString(rates[i].low,   dig),
                                 DoubleToString(rates[i].close, dig),
                                 rates[i].tick_volume,
                                 rates[i].real_volume,
                                 rates[i].spread));
     }
   FileClose(fh);

   double anos = (double)(rates[copiadas - 1].time - rates[0].time) / (365.25 * 86400.0);
   PrintFormat("OK: %d barras de %s %s  (%s → %s, %.1f anos)%s",
               copiadas - malas, sym, tfs,
               TimeToString(rates[0].time, TIME_DATE),
               TimeToString(rates[copiadas - 1].time, TIME_DATE), anos,
               malas > 0 ? StringFormat("  [%d barras corruptas descartadas]", malas) : "");
   Print("Fichero: Common\\Files\\", path);
   Print("");
   Print("Para usarlo en el laboratorio:");
   PrintFormat("  python gm_calibrate.py \"<ruta>\\%s_%s.csv\" --split 0.75 --out out_model", sym, tfs);
   if(anos < 5.0)
      PrintFormat("AVISO: solo %.1f anos. Para calibrar la ecuacion maestra y "
                  "validar fuera de muestra hacen falta 5 anos como minimo, y "
                  "lo deseable son 15-20.", anos);
   return(0);
  }
//+------------------------------------------------------------------+
