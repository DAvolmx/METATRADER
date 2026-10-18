//+------------------------------------------------------------------+
//|  GM_InventarioSimbolos.mq5                                       |
//|                                                                  |
//|  Interroga a TU terminal y responde con datos, no con suposi-    |
//|  ciones: que simbolos ofrece de verdad tu broker, cuanta         |
//|  historia hay de cada uno, y cuales sirven para el laboratorio   |
//|  de Python.                                                      |
//|                                                                  |
//|  Para que existe: averiguar "si mi broker tiene DXY" buscando    |
//|  en internet da respuestas contradictorias y desactualizadas.    |
//|  La unica fuente fiable es el propio terminal. Este script la    |
//|  consulta y escribe un CSV con el inventario completo.           |
//|                                                                  |
//|  OJO con el indice dolar en Deriv: lo que Deriv ofrece es un     |
//|  "USD Basket" EQUIPONDERADO (20% por divisa), que NO es el DXY   |
//|  de ICE (el DXY pesa el EUR al 57,6% y es una media GEOMETRICA). |
//|  Son dos cosas distintas con correlaciones distintas frente al   |
//|  oro, y ademas el producto es reciente, asi que no esperes 21    |
//|  anos de historia. Este script te dira exactamente cuanta hay.   |
//|                                                                  |
//|  SOLO LECTURA: no crea simbolos, no modifica nada, no opera.     |
//|                                                                  |
//|  SALIDA: MQL5/Files/GoldMaster/inventario_simbolos.csv           |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict
#property description "Inventario de simbolos del broker con profundidad de historia"

input string InpFiltro      = "";     // Filtro de nombre (vacio = todos)
input bool   InpSoloVisibles = false; // true = solo los de Observacion de mercado
input bool   InpSoloConHist   = true; // true = omitir simbolos sin historia
input ENUM_TIMEFRAMES InpTF   = PERIOD_D1; // Temporalidad para medir la historia

//+------------------------------------------------------------------+
int OnStart()
  {
   string dir = "GoldMaster";
   if(!FolderCreate(dir, FILE_COMMON) && GetLastError() != 5019)
      PrintFormat("Aviso: no se pudo crear %s (error %d)", dir, GetLastError());
   ResetLastError();

   string path = dir + "\\inventario_simbolos.csv";
   int fh = FileOpen(path, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(fh == INVALID_HANDLE)
     {
      PrintFormat("ERROR: no se pudo abrir %s (error %d)", path, GetLastError());
      return(1);
     }

   FileWrite(fh, "symbol", "descripcion", "path", "visible", "digits", "point",
             "spread_actual", "spread_flotante", "vol_min", "vol_step", "vol_max",
             "contract_size", "tick_value", "moneda_beneficio", "modo_calculo",
             "barras_disponibles", "primera_fecha", "ultima_fecha", "anos_historia",
             "sesiones_cotiza");

   int total = SymbolsTotal(InpSoloVisibles);
   int escritos = 0, sin_hist = 0;
   string candidatos_dolar = "";
   string candidatos_oro   = "";

   PrintFormat("=== Inventario: %d simbolos (%s) ===", total,
               InpSoloVisibles ? "solo Observacion de mercado" : "todos los del broker");

   for(int i = 0; i < total; i++)
     {
      string s = SymbolName(i, InpSoloVisibles);
      if(s == "")
         continue;
      if(InpFiltro != "" && StringFind(s, InpFiltro) < 0)
         continue;

      // Para leer historia el simbolo debe estar seleccionado. Si no lo estaba,
      // se selecciona, se mide y se deja EXACTAMENTE como estaba: este script
      // no debe cambiarte la Observacion de mercado.
      bool estaba = (bool)SymbolInfoInteger(s, SYMBOL_VISIBLE);
      if(!estaba && !SymbolSelect(s, true))
         continue;

      datetime primera = 0, ultima = 0;
      int barras = 0;
      double anos = 0.0;

      // Pide la serie y espera a que el terminal la tenga lista. Sin esta
      // espera un simbolo con historia real se reporta como vacio.
      MqlRates r[];
      for(int intento = 0; intento < 20; intento++)
        {
         barras = Bars(s, InpTF);
         if(barras > 0)
            break;
         Sleep(100);
        }
      if(barras > 0)
        {
         primera = (datetime)SeriesInfoInteger(s, InpTF, SERIES_FIRSTDATE);
         ultima  = (datetime)SeriesInfoInteger(s, InpTF, SERIES_LASTBAR_DATE);
         if(primera > 0 && ultima > primera)
            anos = (double)(ultima - primera) / (365.25 * 86400.0);
        }

      if(!estaba)
         SymbolSelect(s, false);   // lo deja como estaba

      if(InpSoloConHist && barras <= 0)
        {
         sin_hist++;
         continue;
        }

      // sesiones de cotizacion del lunes: pista de si es sintetico 24/7
      int sesiones = 0;
      datetime desde, hasta;
      for(int k = 0; k < 8; k++)
         if(SymbolInfoSessionQuote(s, MONDAY, k, desde, hasta))
            sesiones++;

      FileWrite(fh, s,
                SymbolInfoString(s, SYMBOL_DESCRIPTION),
                SymbolInfoString(s, SYMBOL_PATH),
                (int)SymbolInfoInteger(s, SYMBOL_VISIBLE),
                (int)SymbolInfoInteger(s, SYMBOL_DIGITS),
                DoubleToString(SymbolInfoDouble(s, SYMBOL_POINT), 8),
                (int)SymbolInfoInteger(s, SYMBOL_SPREAD),
                (int)SymbolInfoInteger(s, SYMBOL_SPREAD_FLOAT),
                DoubleToString(SymbolInfoDouble(s, SYMBOL_VOLUME_MIN), 4),
                DoubleToString(SymbolInfoDouble(s, SYMBOL_VOLUME_STEP), 4),
                DoubleToString(SymbolInfoDouble(s, SYMBOL_VOLUME_MAX), 2),
                DoubleToString(SymbolInfoDouble(s, SYMBOL_TRADE_CONTRACT_SIZE), 2),
                DoubleToString(SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE), 6),
                SymbolInfoString(s, SYMBOL_CURRENCY_PROFIT),
                EnumToString((ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(s, SYMBOL_TRADE_CALC_MODE)),
                barras,
                (primera > 0 ? TimeToString(primera, TIME_DATE) : ""),
                (ultima  > 0 ? TimeToString(ultima,  TIME_DATE) : ""),
                DoubleToString(anos, 2),
                sesiones);
      escritos++;

      // marca los candidatos que le interesan al laboratorio
      string up = s;
      StringToUpper(up);
      string desc = SymbolInfoString(s, SYMBOL_DESCRIPTION);
      StringToUpper(desc);
      if(StringFind(up, "DX") >= 0 || StringFind(up, "USDX") >= 0 ||
         StringFind(up, "USDIND") >= 0 || StringFind(desc, "DOLLAR") >= 0 ||
         StringFind(desc, "USD BASKET") >= 0 || StringFind(desc, "INDICE DOLAR") >= 0)
         candidatos_dolar += StringFormat("   %-24s %-34s %6d barras  %5.1f anos\n",
                                          s, SymbolInfoString(s, SYMBOL_DESCRIPTION), barras, anos);
      if(StringFind(up, "XAU") >= 0 || StringFind(up, "GOLD") >= 0 ||
         StringFind(desc, "GOLD") >= 0 || StringFind(desc, "ORO") >= 0)
         candidatos_oro += StringFormat("   %-24s %-34s %6d barras  %5.1f anos\n",
                                        s, SymbolInfoString(s, SYMBOL_DESCRIPTION), barras, anos);
     }

   FileClose(fh);

   PrintFormat("Escritos %d simbolos (%d omitidos por no tener historia en %s)",
               escritos, sin_hist, EnumToString(InpTF));
   Print("Fichero: Common\\Files\\", path);
   Print("");
   Print("--- CANDIDATOS A INDICE DOLAR / DXY ---");
   Print(candidatos_dolar == "" ? "   NINGUNO: tu broker no publica indice dolar.\n"
         "   Para correlacionar el DXY usa el reconstruido con la formula ICE\n"
         "   (ver python/model/gm_dxy.py y data/README.md)." : candidatos_dolar);
   Print("--- CANDIDATOS A ORO ---");
   Print(candidatos_oro == "" ? "   NINGUNO." : candidatos_oro);
   Print("");
   Print("SIGUIENTE PASO: exporta el simbolo que te interese con");
   Print("  GM_ExportarHistorico.mq5  y cargalo con python/core/gm_data.py");
   Print("RECUERDA: si aparece un 'USD Basket', NO es el DXY de ICE.");
   Print("  USD Basket = 5 divisas al 20% cada una (media aritmetica).");
   Print("  DXY (ICE)  = 6 divisas, EUR al 57,6%, media GEOMETRICA.");
   Print("  Correlacionan distinto con el oro: no los mezcles.");
   return(0);
  }
//+------------------------------------------------------------------+
