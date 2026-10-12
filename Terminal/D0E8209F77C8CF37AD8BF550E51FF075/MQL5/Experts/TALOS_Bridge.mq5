//+------------------------------------------------------------------+
//|                       TALOS_Bridge.mq5                          |
//|        TALOS GOLD — Bridge JSON ↔ Python Bot                    |
//|  Lee:  Common\Files\talos_signal.json    (señal del bot)        |
//|  Lee:  Common\Files\talos_prediccion.json (predicción ML)       |
//|  Lee:  Common\Files\talos_sentimiento.json (sentimiento)        |
//|  Escribe: Common\Files\talos_result.json  (resultado trade)     |
//|  Escribe: Common\Files\talos_estado.json  (estado EA live)      |
//+------------------------------------------------------------------+
#property copyright   "TALOS Intelligence"
#property version     "3.00"
#property description "Bridge JSON bidireccional MT5 ↔ Python TALOS"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//═══════════════════════════════════════════════════════════════════
//  PARÁMETROS
//═══════════════════════════════════════════════════════════════════
input int    InpMagic        = 20250912;   // Magic number
input int    InpPollMs       = 1000;       // Polling JSON (ms)
input int    InpSpreadLimit  = 80;         // Spread máximo puntos
input double InpMinLot       = 0.01;       // Lote mínimo
input double InpMaxLot       = 5.0;        // Lote máximo
input double InpDailyDDLimit = 0.10;       // Kill-switch diario
input bool   InpDemoMode     = false;      // true = simular sin abrir trades
input string InpComment      = "TALOS-v3"; // Comentario trades

//═══════════════════════════════════════════════════════════════════
//  RUTAS JSON — Common\Files\ (accesible por todos los terminales)
//═══════════════════════════════════════════════════════════════════
#define FILE_SIGNAL    "talos_signal.json"
#define FILE_RESULT    "talos_result.json"
#define FILE_ESTADO    "talos_estado.json"
#define FILE_PRED      "talos_prediccion.json"
#define FILE_SENT      "talos_sentimiento.json"

//═══════════════════════════════════════════════════════════════════
//  OBJETOS Y VARIABLES GLOBALES
//═══════════════════════════════════════════════════════════════════
CTrade        Trade;
CPositionInfo PositionInfo;
CAccountInfo  AccountInfo;

double g_StartDayBalance = 0;
int    g_DailyTrades     = 0;
bool   g_KillSwitch      = false;
string g_LastSignalId    = "";
datetime g_LastDay       = 0;

int h_ATR;

//═══════════════════════════════════════════════════════════════════
//  UTILIDAD: leer archivo JSON completo como string
//═══════════════════════════════════════════════════════════════════
string LeerJSON(string nombre)
{
    int h = FileOpen(nombre, FILE_READ|FILE_TXT|FILE_COMMON|FILE_ANSI);
    if(h == INVALID_HANDLE) return "";
    string contenido = "";
    while(!FileIsEnding(h))
        contenido += FileReadString(h);
    FileClose(h);
    return contenido;
}

//═══════════════════════════════════════════════════════════════════
//  UTILIDAD: escribir string a JSON (sobrescribe)
//═══════════════════════════════════════════════════════════════════
bool EscribirJSON(string nombre, string contenido)
{
    // Escritura atómica: tmp → rename
    string tmp = nombre + ".tmp";
    int h = FileOpen(tmp, FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_ANSI);
    if(h == INVALID_HANDLE) return false;
    FileWriteString(h, contenido);
    FileClose(h);
    // MT5 no tiene rename directo en FILE_COMMON, sobreescribimos
    h = FileOpen(nombre, FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_ANSI);
    if(h == INVALID_HANDLE) return false;
    FileWriteString(h, contenido);
    FileClose(h);
    FileDelete(tmp, FILE_COMMON);
    return true;
}

//═══════════════════════════════════════════════════════════════════
//  UTILIDAD: extraer valor string de JSON plano
//  Soporta: "clave":"valor"  y  "clave":123.4  y "clave":true
//═══════════════════════════════════════════════════════════════════
string JsonGet(string json, string clave)
{
    string buscar = "\"" + clave + "\"";
    int pos = StringFind(json, buscar);
    if(pos < 0) return "";
    pos += StringLen(buscar);
    // Avanzar al ':'
    while(pos < StringLen(json) && StringSubstr(json, pos, 1) != ":") pos++;
    pos++; // saltar ':'
    // Saltar espacios
    while(pos < StringLen(json) && StringSubstr(json, pos, 1) == " ") pos++;
    // ¿String o número/bool?
    string inicio = StringSubstr(json, pos, 1);
    if(inicio == "\"")
    {
        pos++;
        string resultado = "";
        while(pos < StringLen(json))
        {
            string c = StringSubstr(json, pos, 1);
            if(c == "\"") break;
            resultado += c;
            pos++;
        }
        return resultado;
    }
    else
    {
        string resultado = "";
        while(pos < StringLen(json))
        {
            string c = StringSubstr(json, pos, 1);
            if(c == "," || c == "}" || c == "]" || c == "\n" || c == "\r") break;
            resultado += c;
            pos++;
        }
        // Trim manual — StringTrimRight/Left modifican in-place en MQL5
        string r2 = resultado;
        StringTrimRight(r2);
        StringTrimLeft(r2);
        return r2;
    }
}

//═══════════════════════════════════════════════════════════════════
//  CALCULAR LOTE desde el campo "lote" del JSON (con clamp)
//═══════════════════════════════════════════════════════════════════
double ClampLote(double lote)
{
    lote = MathMax(InpMinLot, MathMin(InpMaxLot, lote));
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if(step > 0)
        lote = MathFloor(lote / step) * step;
    return NormalizeDouble(lote, 2);
}

//═══════════════════════════════════════════════════════════════════
//  ESCRIBIR ESTADO ACTUAL DEL EA (para el bot y el dashboard)
//═══════════════════════════════════════════════════════════════════
void EscribirEstado(string ultimo_evento)
{
    double balance  = AccountInfo.Balance();
    double equity   = AccountInfo.Equity();
    double profit   = AccountInfo.Profit();
    long   spread_l = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    double spread   = (double)spread_l;
    double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    string kill_str = g_KillSwitch ? "true" : "false";

    string estado = StringFormat(
        "{\"timestamp\":\"%s\","
        "\"balance\":%.2f,"
        "\"equity\":%.2f,"
        "\"profit\":%.2f,"
        "\"trades_hoy\":%d,"
        "\"kill_switch\":%s,"
        "\"spread\":%.0f,"
        "\"bid\":%.3f,"
        "\"ask\":%.3f,"
        "\"ultimo_evento\":\"%s\","
        "\"version\":\"3.00\"}",
        TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
        balance, equity, profit,
        g_DailyTrades, kill_str, spread, bid, ask,
        ultimo_evento
    );
    EscribirJSON(FILE_ESTADO, estado);
}

//═══════════════════════════════════════════════════════════════════
//  CERRAR POSICIÓN ABIERTA DEL MAGIC
//═══════════════════════════════════════════════════════════════════
bool CerrarPosicion(string motivo)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!PositionInfo.SelectByIndex(i)) continue;
        if(PositionInfo.Symbol() != _Symbol) continue;
        if(PositionInfo.Magic() != InpMagic) continue;
        bool ok = Trade.PositionClose(PositionInfo.Ticket());
        if(ok) Print("[TALOS] Posición cerrada: ", motivo);
        return ok;
    }
    return false;
}

//═══════════════════════════════════════════════════════════════════
//  PROCESAR SEÑAL JSON
//═══════════════════════════════════════════════════════════════════
void ProcesarSenal()
{
    string json = LeerJSON(FILE_SIGNAL);
    if(json == "") return;

    // Leer campos principales
    string signal_id = JsonGet(json, "signal_id");
    string accion    = JsonGet(json, "accion");   // BUY / SELL / WAIT / CLOSE
    string estado_s  = JsonGet(json, "estado");   // pendiente / ejecutado / error

    if(signal_id == "" || accion == "") return;
    if(signal_id == g_LastSignalId) return;       // ya procesada

    Print("[TALOS] Nueva señal: ", signal_id, " | ", accion);

    // Kill-switch diario
    if(g_KillSwitch)
    {
        Print("[TALOS] Kill-switch activo — ignorando señal");
        EscribirEstado("kill_switch_activo");
        return;
    }

    // Spread check
    double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    if(spread > InpSpreadLimit)
    {
        Print("[TALOS] Spread alto: ", spread, " > ", InpSpreadLimit, " pts");
        EscribirEstado("spread_alto_" + DoubleToString(spread, 0));
        return;
    }

    double lote    = StringToDouble(JsonGet(json, "lote"));
    double sl_pts  = StringToDouble(JsonGet(json, "sl_pts"));
    double tp_pts  = StringToDouble(JsonGet(json, "tp_pts"));
    double confianza = StringToDouble(JsonGet(json, "confianza"));

    lote = ClampLote(lote > 0 ? lote : InpMinLot);
    double punto = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    string result_json = "";
    bool   ok = false;

    // CLOSE
    if(accion == "CLOSE")
    {
        ok = CerrarPosicion("señal_CLOSE");
        result_json = StringFormat(
            "{\"signal_id\":\"%s\",\"accion\":\"CLOSE\","
            "\"ejecutado\":%s,\"ticket\":0,\"ts\":\"%s\"}",
            signal_id, ok ? "true" : "false",
            TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)
        );
    }
    // BUY
    else if(accion == "BUY")
    {
        double sl = sl_pts > 0 ? ask - sl_pts * punto : 0;
        double tp = tp_pts > 0 ? ask + tp_pts * punto : 0;

        if(!InpDemoMode)
            ok = Trade.Buy(lote, _Symbol, 0, sl, tp, InpComment);
        else
            ok = true;

        ulong ticket = ok ? Trade.ResultOrder() : 0;
        result_json  = StringFormat(
            "{\"signal_id\":\"%s\",\"accion\":\"BUY\","
            "\"ejecutado\":%s,\"ticket\":%d,"
            "\"lote\":%.2f,\"price\":%.3f,"
            "\"sl\":%.3f,\"tp\":%.3f,"
            "\"confianza\":%.4f,"
            "\"ts\":\"%s\"}",
            signal_id, ok ? "true" : "false",
            (int)ticket, lote, ask, sl, tp, confianza,
            TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)
        );
        if(ok) { g_DailyTrades++; Print("[TALOS] BUY ejecutado lote=", lote, " sl=", sl, " tp=", tp); }
    }
    // SELL
    else if(accion == "SELL")
    {
        double sl = sl_pts > 0 ? bid + sl_pts * punto : 0;
        double tp = tp_pts > 0 ? bid - tp_pts * punto : 0;

        if(!InpDemoMode)
            ok = Trade.Sell(lote, _Symbol, 0, sl, tp, InpComment);
        else
            ok = true;

        ulong ticket = ok ? Trade.ResultOrder() : 0;
        result_json  = StringFormat(
            "{\"signal_id\":\"%s\",\"accion\":\"SELL\","
            "\"ejecutado\":%s,\"ticket\":%d,"
            "\"lote\":%.2f,\"price\":%.3f,"
            "\"sl\":%.3f,\"tp\":%.3f,"
            "\"confianza\":%.4f,"
            "\"ts\":\"%s\"}",
            signal_id, ok ? "true" : "false",
            (int)ticket, lote, bid, sl, tp, confianza,
            TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)
        );
        if(ok) { g_DailyTrades++; Print("[TALOS] SELL ejecutado lote=", lote, " sl=", sl, " tp=", tp); }
    }
    // WAIT
    else if(accion == "WAIT")
    {
        result_json = StringFormat(
            "{\"signal_id\":\"%s\",\"accion\":\"WAIT\","
            "\"ejecutado\":true,\"ticket\":0,\"ts\":\"%s\"}",
            signal_id,
            TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)
        );
        ok = true;
    }

    // Escribir resultado
    if(result_json != "")
        EscribirJSON(FILE_RESULT, result_json);

    g_LastSignalId = signal_id;
    EscribirEstado("ejecutado_" + accion);
}

//═══════════════════════════════════════════════════════════════════
//  ENVIAR DATOS OHLCV + INDICADORES AL BOT (para el análisis)
//═══════════════════════════════════════════════════════════════════
void EnviarDatosMercado()
{
    // Construir JSON con datos del mercado actual
    double atr[];
    ArraySetAsSeries(atr, true);
    if(CopyBuffer(h_ATR, 0, 0, 1, atr) <= 0) return;

    double atr_val = atr[0];
    double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double spread  = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

    // Últimas velas M15 (para indicadores)
    double close[], high[], low[], open_p[];
    ArraySetAsSeries(close, true);
    ArraySetAsSeries(high,  true);
    ArraySetAsSeries(low,   true);
    ArraySetAsSeries(open_p, true);
    if(CopyClose(_Symbol, PERIOD_M15, 0, 3, close) <= 0) return;
    CopyHigh (_Symbol, PERIOD_M15, 0, 3, high);
    CopyLow  (_Symbol, PERIOD_M15, 0, 3, low);
    CopyOpen (_Symbol, PERIOD_M15, 0, 3, open_p);

    string mkdata = StringFormat(
        "{\"ts\":\"%s\","
        "\"bid\":%.3f,\"ask\":%.3f,\"spread\":%.0f,"
        "\"atr\":%.3f,"
        "\"c0\":%.3f,\"h0\":%.3f,\"l0\":%.3f,\"o0\":%.3f,"
        "\"c1\":%.3f,\"h1\":%.3f,\"l1\":%.3f,"
        "\"balance\":%.2f,\"equity\":%.2f,"
        "\"trades_hoy\":%d,\"kill\":%s}",
        TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
        bid, ask, spread, atr_val,
        close[0], high[0], low[0], open_p[0],
        close[1], high[1], low[1],
        AccountInfo.Balance(), AccountInfo.Equity(),
        g_DailyTrades, g_KillSwitch ? "true" : "false"
    );

    // Lo escribimos en talos_estado.json (el bot lo lee también)
    EscribirJSON(FILE_ESTADO, mkdata);
}

//═══════════════════════════════════════════════════════════════════
//  ON INIT
//═══════════════════════════════════════════════════════════════════
int OnInit()
{
    Print("╔══════════════════════════════════════════════╗");
    Print("║   TALOS BRIDGE v3.00 — XAUUSD ↔ Python      ║");
    Print("║   Common\\Files\\talos_*.json                 ║");
    Print("╚══════════════════════════════════════════════╝");

    Trade.SetExpertMagicNumber(InpMagic);
    Trade.SetDeviationInPoints(30);
    Trade.SetTypeFilling(ORDER_FILLING_IOC);

    h_ATR = iATR(_Symbol, PERIOD_M15, 14);
    if(h_ATR == INVALID_HANDLE)
    {
        Print("[ERROR] No se pudo crear handle ATR");
        return INIT_FAILED;
    }

    g_StartDayBalance = AccountInfo.Balance();
    g_LastDay         = TimeCurrent();

    // Crear archivos vacíos si no existen
    EscribirJSON(FILE_RESULT, "{\"estado\":\"esperando\"}");
    EscribirEstado("EA_iniciado");

    EventSetMillisecondTimer(InpPollMs);

    if(InpDemoMode)
        Print("[TALOS] ⚠️  MODO DEMO — no se abrirán trades reales");

    Print("[TALOS] Bridge listo. Escuchando: Common\\Files\\", FILE_SIGNAL);
    return INIT_SUCCEEDED;
}

//═══════════════════════════════════════════════════════════════════
//  ON DEINIT
//═══════════════════════════════════════════════════════════════════
void OnDeinit(const int reason)
{
    EventKillTimer();
    IndicatorRelease(h_ATR);
    EscribirEstado("EA_detenido");
    Print("[TALOS] Bridge detenido. Reason: ", reason);
}

//═══════════════════════════════════════════════════════════════════
//  ON TIMER — polling principal
//═══════════════════════════════════════════════════════════════════
void OnTimer()
{
    // Reset diario
    MqlDateTime hoy;
    TimeToStruct(TimeCurrent(), hoy);
    MqlDateTime ult;
    TimeToStruct(g_LastDay, ult);
    if(hoy.day != ult.day)
    {
        g_StartDayBalance = AccountInfo.Balance();
        g_DailyTrades     = 0;
        g_KillSwitch      = false;
        g_LastDay         = TimeCurrent();
        Print("[TALOS] Reset diario — Balance: ", g_StartDayBalance);
    }

    // Kill-switch por drawdown
    if(!g_KillSwitch)
    {
        double dd = (AccountInfo.Balance() - g_StartDayBalance) / MathMax(g_StartDayBalance, 1);
        if(dd <= -InpDailyDDLimit)
        {
            g_KillSwitch = true;
            CerrarPosicion("kill_switch_DD");
            Print("[TALOS] ⛔ KILL-SWITCH activado. DD: ", dd * 100, "%");
        }
    }

    // Procesar señal del bot
    ProcesarSenal();

    // Actualizar estado cada ciclo
    EnviarDatosMercado();
}

//═══════════════════════════════════════════════════════════════════
//  ON TICK — actualización rápida de estado
//═══════════════════════════════════════════════════════════════════
void OnTick()
{
    // Nada pesado aquí — el trabajo real va en OnTimer
}

//═══════════════════════════════════════════════════════════════════
//  ON TRADE — confirmar ejecución de orden
//═══════════════════════════════════════════════════════════════════
void OnTrade()
{
    EscribirEstado("trade_event");
}
