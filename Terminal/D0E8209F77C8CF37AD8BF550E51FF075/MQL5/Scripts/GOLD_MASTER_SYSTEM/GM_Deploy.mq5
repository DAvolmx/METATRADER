//+------------------------------------------------------------------+
//| GM_Deploy.mq5 - Monta GOLD MASTER completo                        |
//|  · Detecta automáticamente el símbolo del gráfico activo          |
//|  · Gráficos + plantillas (Guardian, Pullback EA, señales M1/M5/M15)|
//|  · Lanza el servicio Python + dashboard interactivo (navegador)    |
//|    → requiere marcar "Permitir importar DLL" al ejecutar el script |
//+------------------------------------------------------------------+
#property script_show_inputs
#import "shell32.dll"
int ShellExecuteW(int hwnd,string op,string file,string params,string dir,int show);
#import

// "" = usa el símbolo del gráfico donde se arrastra el script (RECOMENDADO)
// Puedes escribir "XAUUSD" o "XAUUSDmicro" para forzar un símbolo concreto
input string Sym             = "";        // Símbolo: vacío = detectar automáticamente
input bool   DeployMacroLiquidity = true; // H3 niveles + H1 confirmación + M15 (paper por defecto)
input bool   MacroExclusive = true; // no añadir otros motores de entrada a este despliegue
input bool   DeployGuardian  = true;     // protector (SL/TP/BE/trailing + límites)
input bool   DeployPullback  = true;     // EA Pullback (validación nativa pendiente) + indicador institucional
input bool   DeployStructure = false;    // EA de estructura (M5) — opcional
input bool   DeployScalper   = false;    // 2º motor de entradas (más riesgo)
input bool   DeploySignals   = true;     // señales PRO 24/7 en M1/M5/M15
input bool   LaunchDashboard = true;     // observatorio + replay + dashboard web (http://127.0.0.1:8766)
input bool   SkipExisting    = true;     // no duplicar gráficos que ya tienen esa plantilla/EA

string gSym = "";   // símbolo resuelto en OnStart

bool HasChart(ENUM_TIMEFRAMES tf,string ea){
   for(long c=ChartFirst();c>=0;c=ChartNext(c))
      if(ChartSymbol(c)==gSym && ChartPeriod(c)==tf && (ea=="" || ChartGetString(c,CHART_EXPERT_NAME)==ea)) return true;
   return false;
}
bool HasIndicator(ENUM_TIMEFRAMES tf,string shortname){
   for(long c=ChartFirst();c>=0;c=ChartNext(c)){
      if(ChartSymbol(c)!=gSym || ChartPeriod(c)!=tf) continue;
      for(int i=0;i<ChartIndicatorsTotal(c,0);i++) if(StringFind(ChartIndicatorName(c,0,i),shortname)>=0) return true;
   }
   return false;
}
bool Mount(ENUM_TIMEFRAMES tf,string tpl,string ea=""){
   if(SkipExisting && ea=="" && StringFind(tpl,"GM_MACRO_")==0 && HasIndicator(tf,"GM Macro H3 Liquidity")) return true;
   if(SkipExisting && ea=="" && tpl=="GM_SIGNALS.tpl" && HasIndicator(tf,"GM PRO Signals")){ PrintFormat("[DEPLOY] señales %s ya existen → omitido",EnumToString(tf)); return true; }
   if(SkipExisting && ea!="" && HasChart(tf,ea)){ PrintFormat("[DEPLOY] %s %s ya existe → omitido",ea,EnumToString(tf)); return true; }
   long id=ChartOpen(gSym,tf);
   if(id==0){ PrintFormat("[DEPLOY] no se pudo abrir %s (%d)",gSym,GetLastError()); return false; }
   if(!ChartApplyTemplate(id,tpl)){ PrintFormat("[DEPLOY] error plantilla %s (%d)",tpl,GetLastError()); return false; }
   PrintFormat("[DEPLOY] %s %s ← %s",gSym,EnumToString(tf),tpl); return true;
}
void OnStart(){
   // ── 1. Resolver símbolo ──────────────────────────────────────────
   if(Sym == "" || Sym == "auto"){
      // Detectar desde el gráfico activo (donde se arrastró el script)
      gSym = ChartSymbol(ChartID());
      if(gSym == "") gSym = _Symbol;   // fallback al símbolo del contexto
   } else {
      gSym = Sym;
   }

   PrintFormat("[DEPLOY] Símbolo objetivo: %s", gSym);

   // ── 2. Validaciones ──────────────────────────────────────────────
   if(!SymbolSelect(gSym,true)){
      Alert("Símbolo no disponible en Market Watch: ",gSym,
            "\nEjecuta el script desde un gráfico de XAUUSD o escribe el símbolo exacto en el input Sym.");
      return;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Alert("Activa 'Trading algorítmico' en la barra de MT5");

   // ── 3. Desplegar EAs e indicadores ───────────────────────────────
   if(DeployGuardian)  Mount(PERIOD_M1 ,"GM_GUARDIAN.tpl","GOLD_MASTER_GUARDIAN_EA");
   if(DeployMacroLiquidity){
      Mount(PERIOD_H3,"GM_MACRO_H3.tpl");
      Mount(PERIOD_H1,"GM_MACRO_H1.tpl");
      Mount(PERIOD_M15,"GM_MACRO_M15.tpl","GOLD_MASTER_MACRO_LIQUIDITY_EA");
   }
   bool legacyEntries=!(DeployMacroLiquidity && MacroExclusive);
   if(DeployPullback && legacyEntries)  Mount(PERIOD_M15,"GM_PULLBACK.tpl","GOLD_MASTER_PULLBACK_EA");
   if(DeployStructure && legacyEntries) Mount(PERIOD_M5 ,"GM_STRUCTURE.tpl","GOLD_MASTER_STRUCTURE_EA");
   if(DeployScalper && legacyEntries)   Mount(PERIOD_M15,"GM_SCALPER.tpl","GOLD_MASTER_SCALPER_EA");
   if(DeploySignals){
      Mount(PERIOD_M1, "GM_SIGNALS.tpl");
      Mount(PERIOD_M5, "GM_SIGNALS.tpl");
      Mount(PERIOD_M15,"GM_SIGNALS.tpl");
   }

   // ── 4. Dashboard Python ──────────────────────────────────────────
   if(LaunchDashboard){
      string dir=TerminalInfoString(TERMINAL_DATA_PATH)+"\\MQL5\\Scripts\\GOLD_MASTER_SYSTEM";
      if(!TerminalInfoInteger(TERMINAL_DLLS_ALLOWED) && !MQLInfoInteger(MQL_DLLS_ALLOWED)){
         Alert("Para abrir el dashboard marca 'Permitir importar DLL' al ejecutar GM_Deploy, o ejecuta a mano:\n",dir,"\\GM_START_ALL.bat");
         return;
      }
      int r=ShellExecuteW(0,"open",dir+"\\GM_START_ALL.bat","",dir,7);
      if(r <= 32) PrintFormat("[DEPLOY] fallo al lanzar dashboard: ShellExecute=%d",r);
      else Print("[DEPLOY] observatorio + replay + dashboard → http://127.0.0.1:8766");
   }

   PrintFormat("[DEPLOY] ✔ GOLD MASTER montado sobre %s", gSym);
}
