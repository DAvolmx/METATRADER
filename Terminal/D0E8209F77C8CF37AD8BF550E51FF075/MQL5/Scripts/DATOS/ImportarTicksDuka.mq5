//+------------------------------------------------------------------+
//|  ImportarTicksDuka.mq5                                           |
//|  Importa ticks de Dukascopy en formato CSV a un simbolo         |
//|  personalizado de MetaTrader 5.                                  |
//|                                                                  |
//|  RESTRICCIONES DE SEGURIDAD:                                     |
//|  - Solo crea simbolos con sufijo _DUKA                           |
//|  - Solo lee de MQL5/Files                                        |
//|  - No toca simbolos reales del broker                            |
//|  - No abre ni cierra operaciones                                 |
//|  - No modifica configuracion del terminal                        |
//+------------------------------------------------------------------+
#property script_show_inputs

// --- Parametros de entrada -------------------------------------------
input string   InpSimbolo     = "XAUUSD";          // Simbolo fuente
input string   InpSufijo      = "_DUKA";            // Sufijo obligatorio
input string   InpArchivoCsv  = "ticks_XAUUSD_2018_01.csv"; // Archivo CSV en MQL5/Files
input int      InpBloqueTicks = 10000;              // Ticks por bloque de insercion

//+------------------------------------------------------------------+
//| Funcion principal del script                                     |
//+------------------------------------------------------------------+
void OnStart()
  {
   string simbolo_destino = InpSimbolo + InpSufijo;

   // Verificar que el sufijo sea _DUKA (restriccion de seguridad)
   if(StringFind(simbolo_destino, "_DUKA") < 0)
     {
      Print("ERROR: El sufijo debe ser _DUKA. Abortando.");
      return;
     }

   Print("=== ImportarTicksDuka iniciado ===");
   Print("Simbolo destino: ", simbolo_destino);
   Print("Archivo CSV: ", InpArchivoCsv);

   // --- Crear o verificar el simbolo personalizado -------------------
   if(!_CrearSimboloPersonalizado(InpSimbolo, simbolo_destino))
     {
      Print("ERROR: No se pudo crear el simbolo personalizado.");
      return;
     }

   // --- Abrir el archivo CSV -----------------------------------------
   int handle = FileOpen(InpArchivoCsv, FILE_READ|FILE_CSV|FILE_ANSI, '\t');
   if(handle == INVALID_HANDLE)
     {
      Print("ERROR: No se pudo abrir el archivo: ", InpArchivoCsv);
      Print("Coloca el CSV en: ", TerminalInfoString(TERMINAL_DATA_PATH), "\\MQL5\\Files\\");
      return;
     }

   // Saltar cabecera
   if(!FileIsEnding(handle))
      FileReadString(handle);  // linea de cabecera completa
   // En CSV con FILE_CSV cada campo es una columna; la cabecera ocupa una fila
   // Re-abrir sin FILE_CSV para leer linea a linea
   FileClose(handle);
   handle = FileOpen(InpArchivoCsv, FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      Print("ERROR: No se pudo reabrir el archivo en modo TXT.");
      return;
     }

   // Saltar primera linea (cabecera)
   FileReadString(handle);

   // --- Leer e importar por bloques ----------------------------------
   MqlTick bloque[];
   ArrayResize(bloque, InpBloqueTicks);
   int    idx          = 0;
   long   total_ticks  = 0;
   long   rechazados   = 0;
   string primera_hora = "";
   string ultima_hora  = "";
   datetime ts_ant     = 0;

   while(!FileIsEnding(handle))
     {
      string linea = FileReadString(handle);
      if(StringLen(linea) < 20) continue;

      // Parsear: AAAA.MM.DD\tHH:MM:SS.mmm\tBID\tASK\tLAST\tVOL
      string partes[];
      int n = StringSplit(linea, '\t', partes);
      if(n < 4) continue;

      // Construir datetime (sin milisegundos) + milisegundos aparte
      string fecha_hora = partes[0] + " " + partes[1]; // "2018.01.02 14:00:00.190"
      string ms_str = "";
      int punto = StringFind(partes[1], ".");
      if(punto >= 0)
         ms_str = StringSubstr(partes[1], punto + 1);
      else
         ms_str = "000";

      // Convertir fecha "AAAA.MM.DD HH:MM:SS" -> datetime
      string sin_ms = StringSubstr(fecha_hora, 0, StringFind(fecha_hora, ".") + punto > 0 ? punto + 11 : 19);
      // Reemplazar puntos de fecha por separadores reconocidos
      // StringToTime espera "YYYY.MM.DD HH:MM:SS"
      // partes[0] ya tiene puntos: "2018.01.02"
      string dt_str = partes[0] + " " + StringSubstr(partes[1], 0, 8);
      datetime ts_seg = StringToTime(dt_str);
      if(ts_seg == 0) { rechazados++; continue; }

      int ms = (int)StringToInteger(ms_str);
      long ts_msc = (long)ts_seg * 1000 + ms;

      double bid = StringToDouble(partes[2]);
      double ask = StringToDouble(partes[3]);
      if(bid <= 0 || ask <= 0 || ask < bid) { rechazados++; continue; }

      // Llenar tick
      bloque[idx].time     = ts_seg;
      bloque[idx].time_msc = ts_msc;
      bloque[idx].bid      = bid;
      bloque[idx].ask      = ask;
      bloque[idx].last     = 0;
      bloque[idx].volume   = 0;
      bloque[idx].flags    = TICK_FLAG_BID | TICK_FLAG_ASK;
      idx++;

      if(primera_hora == "") primera_hora = partes[0] + " " + partes[1];
      ultima_hora = partes[0] + " " + partes[1];

      // Cuando el bloque esta lleno, insertar en MT5
      if(idx >= InpBloqueTicks)
        {
         ArrayResize(bloque, idx);
         int ok = CustomTicksReplace(simbolo_destino, bloque[0].time, bloque[idx-1].time, bloque);
         if(ok < 0)
            Print("ADVERTENCIA CustomTicksReplace error: ", GetLastError());
         total_ticks += idx;
         idx = 0;
         ArrayResize(bloque, InpBloqueTicks);
         Print("Progreso: ", total_ticks, " ticks insertados...");
        }
     }

   // Insertar el ultimo bloque parcial
   if(idx > 0)
     {
      ArrayResize(bloque, idx);
      CustomTicksReplace(simbolo_destino, bloque[0].time, bloque[idx-1].time, bloque);
      total_ticks += idx;
     }

   FileClose(handle);

   Print("=== Importacion finalizada ===");
   Print("Ticks insertados:  ", total_ticks);
   Print("Ticks rechazados:  ", rechazados);
   Print("Primer instante:   ", primera_hora);
   Print("Ultimo instante:   ", ultima_hora);
   Print("Simbolo listo:     ", simbolo_destino);
  }

//+------------------------------------------------------------------+
//| Crea el simbolo personalizado clonando propiedades del original  |
//+------------------------------------------------------------------+
bool _CrearSimboloPersonalizado(string simbolo_base, string simbolo_dest)
  {
   // Verificar que no existe ya (idempotente)
   if(SymbolSelect(simbolo_dest, true))
     {
      Print("Simbolo ya existe: ", simbolo_dest, " -- se sobreescribiran los ticks (idempotente)");
      return true;
     }

   // Crear nuevo simbolo personalizado
   if(!CustomSymbolCreate(simbolo_dest, "\\Custom\\Dukascopy", simbolo_base))
     {
      int err = GetLastError();
      if(err == 4305) // Ya existe
        {
         Print("Simbolo ya existe (cod 4305), continuando.");
         SymbolSelect(simbolo_dest, true);
         return true;
        }
      Print("ERROR CustomSymbolCreate: ", err);
      return false;
     }

   // Copiar propiedades clave del simbolo base si esta disponible
   if(SymbolSelect(simbolo_base, true))
     {
      int digits = (int)SymbolInfoInteger(simbolo_base, SYMBOL_DIGITS);
      CustomSymbolSetInteger(simbolo_dest, SYMBOL_DIGITS, digits);

      double tick_size = SymbolInfoDouble(simbolo_base, SYMBOL_TRADE_TICK_SIZE);
      if(tick_size > 0) CustomSymbolSetDouble(simbolo_dest, SYMBOL_TRADE_TICK_SIZE, tick_size);

      double tick_val = SymbolInfoDouble(simbolo_base, SYMBOL_TRADE_TICK_VALUE);
      if(tick_val > 0) CustomSymbolSetDouble(simbolo_dest, SYMBOL_TRADE_TICK_VALUE, tick_val);

      double lot_size = SymbolInfoDouble(simbolo_base, SYMBOL_TRADE_CONTRACT_SIZE);
      if(lot_size > 0) CustomSymbolSetDouble(simbolo_dest, SYMBOL_TRADE_CONTRACT_SIZE, lot_size);

      Print("Propiedades copiadas de ", simbolo_base, ": digits=", digits,
            " tick_size=", tick_size, " tick_val=", tick_val, " lot=", lot_size);
     }
   else
      Print("Simbolo base ", simbolo_base, " no disponible en broker -- usando defaults");

   SymbolSelect(simbolo_dest, true);
   Print("Simbolo personalizado creado: ", simbolo_dest);
   return true;
  }
//+------------------------------------------------------------------+
