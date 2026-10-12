//+──────────────────────────────────────────────────────────────────────────+
//│  GOLD MASTER — Logger v1.0                                               │
//│  Logging profesional con niveles, timestamps y salida a archivo          │
//│  Uso: GM_LOG_I("MiMod","Mensaje"); GM_LOG_W(...); GM_LOG_E(...)          │
//+──────────────────────────────────────────────────────────────────────────+
#ifndef GOLDMASTER_LOGGER_MQH
#define GOLDMASTER_LOGGER_MQH

//─── Niveles de log ─────────────────────────────────────────────────────────
enum ENUM_GM_LOGLEVEL {
   GM_LOG_DEBUG = 0,
   GM_LOG_INFO  = 1,
   GM_LOG_WARN  = 2,
   GM_LOG_ERROR = 3,
   GM_LOG_NONE  = 4   // Desactiva todo
};

//─── Clase principal de logging ─────────────────────────────────────────────
class CGMLogger {
private:
   string            m_ea_name;
   ENUM_GM_LOGLEVEL  m_min_level;
   bool              m_file_enabled;
   string            m_file_path;
   int               m_fh;
   int               m_msg_count;
   int               m_max_file_kb;
   datetime          m_session_start;

   string LevelTag(ENUM_GM_LOGLEVEL lv) {
      switch(lv) {
         case GM_LOG_DEBUG: return "[DBG]";
         case GM_LOG_INFO:  return "[INF]";
         case GM_LOG_WARN:  return "[WRN]";
         case GM_LOG_ERROR: return "[ERR]";
         default:           return "[???]";
      }
   }

   string Timestamp() {
      MqlDateTime dt; TimeToStruct(TimeLocal(), dt);
      return StringFormat("%02d:%02d:%02d", dt.hour, dt.min, dt.sec);
   }

   void WriteToFile(string line) {
      if(!m_file_enabled || m_fh == INVALID_HANDLE) return;
      FileWriteString(m_fh, line + "\n");
      FileFlush(m_fh);
      m_msg_count++;
      if(m_msg_count % 100 == 0) {
         ulong sz = FileTell(m_fh);
         if(sz > (ulong)m_max_file_kb * 1024) {
            FileClose(m_fh);
            FileMove(m_file_path, FILE_COMMON, m_file_path+".bak", FILE_COMMON|FILE_REWRITE);
            m_fh = FileOpen(m_file_path, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
         }
      }
   }

public:
   CGMLogger() {
      m_ea_name      = "GM";
      m_min_level    = GM_LOG_INFO;
      m_file_enabled = false;
      m_fh           = INVALID_HANDLE;
      m_msg_count    = 0;
      m_max_file_kb  = 512;
      m_session_start = TimeLocal();
   }

   ~CGMLogger() { Close(); }

   void SetName(string name)             { m_ea_name = name; }
   void SetMinLevel(ENUM_GM_LOGLEVEL lv) { m_min_level = lv; }
   void SetMaxFileSizeKB(int kb)         { m_max_file_kb = kb; }

   bool EnableFile(string filename="") {
      if(MQLInfoInteger(MQL_TESTER)) return false;
      if(filename == "") filename = "GoldMaster\\" + m_ea_name + "_" + _Symbol + "_log.txt";
      m_file_path = filename;
      m_fh = FileOpen(m_file_path, FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(m_fh == INVALID_HANDLE) {
         PrintFormat("[GM-Logger] ERROR: No se pudo abrir archivo de log: %s", m_file_path);
         return false;
      }
      FileSeek(m_fh, 0, SEEK_END);
      m_file_enabled = true;
      Log(GM_LOG_INFO, "Sistema", StringFormat("=== SESION INICIADA | EA:%s | Simbolo:%s | Cuenta:%d ===",
          m_ea_name, _Symbol, (int)AccountInfoInteger(ACCOUNT_LOGIN)));
      return true;
   }

   void Close() {
      if(m_fh != INVALID_HANDLE) {
         Log(GM_LOG_INFO, "Sistema", StringFormat("=== SESION CERRADA | Duracion:%ds | Mensajes:%d ===",
             (int)(TimeLocal()-m_session_start), m_msg_count));
         FileClose(m_fh);
         m_fh = INVALID_HANDLE;
      }
      m_file_enabled = false;
   }

   void Log(ENUM_GM_LOGLEVEL lv, string module, string msg) {
      if(lv < m_min_level) return;
      string line = StringFormat("%s %s [%s][%s] %s",
                                 Timestamp(), LevelTag(lv), m_ea_name, module, msg);
      if(lv == GM_LOG_ERROR) Alert(line);
      else                   Print(line);
      WriteToFile(line);
   }

   void Debug(string module, string msg) { Log(GM_LOG_DEBUG, module, msg); }
   void Info (string module, string msg) { Log(GM_LOG_INFO,  module, msg); }
   void Warn (string module, string msg) { Log(GM_LOG_WARN,  module, msg); }
   void Error(string module, string msg) { Log(GM_LOG_ERROR, module, msg); }

   void Trade(string action, string symbol, double lot, double entry,
              double sl, double tp, string reason="") {
      Log(GM_LOG_INFO, "TRADE", StringFormat("%s %s | Lot:%.2f | Entry:%.5f | SL:%.5f | TP:%.5f%s",
          action, symbol, lot, entry, sl, tp,
          reason!="" ? " | "+reason : ""));
   }

   void Separator(string label="") {
      string line = "-----------------------------------------";
      if(label != "") line = "-- " + label + " " + line;
      Log(GM_LOG_INFO, "Sistema", line);
   }

   string GetStats() {
      return StringFormat("Logger[%s]: nivel=%d, archivo=%s, msgs=%d",
             m_ea_name, (int)m_min_level, m_file_enabled?"ON":"OFF", m_msg_count);
   }
};

CGMLogger g_gm_logger;

#define GM_LOG_D(mod,msg)  g_gm_logger.Debug(mod, msg)
#define GM_LOG_I(mod,msg)  g_gm_logger.Info (mod, msg)
#define GM_LOG_W(mod,msg)  g_gm_logger.Warn (mod, msg)
#define GM_LOG_E(mod,msg)  g_gm_logger.Error(mod, msg)

#define GM_ASSERT(cond, mod, msg) \
   if(!(cond)) { \
      g_gm_logger.Error(mod, StringFormat("ASSERT FAILED [%s:%d]: %s", __FUNCTION__, __LINE__, msg)); \
   }

#endif // GOLDMASTER_LOGGER_MQH
