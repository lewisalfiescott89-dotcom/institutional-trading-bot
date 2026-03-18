//+------------------------------------------------------------------+
//| Logger.mqh - Structured logging for the bot                      |
//+------------------------------------------------------------------+
#ifndef LOGGER_MQH
#define LOGGER_MQH

//--- Log levels
enum ENUM_LOG_LEVEL { LOG_DEBUG, LOG_INFO, LOG_WARNING, LOG_ERROR };

ENUM_LOG_LEVEL GlobalLogLevel = LOG_INFO;

void SetLogLevel(ENUM_LOG_LEVEL level) { GlobalLogLevel = level; }

void LogMessage(ENUM_LOG_LEVEL level, string module, string message)
{
   if(level < GlobalLogLevel) return;

   string prefix = "";
   switch(level)
   {
      case LOG_DEBUG:   prefix = "DEBUG"; break;
      case LOG_INFO:    prefix = "INFO"; break;
      case LOG_WARNING: prefix = "WARN"; break;
      case LOG_ERROR:   prefix = "ERROR"; break;
   }

   string log_line = StringFormat("[%s] %s | %s | %s",
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      prefix, module, message);

   Print(log_line);
}

void LogTrade(string symbol, string action, string details)
{
   LogMessage(LOG_INFO, "TRADE",
      StringFormat("%s | %s | %s", symbol, action, details));
}

void LogSafetyBlock(string symbol, string reason)
{
   LogMessage(LOG_WARNING, "SAFETY",
      StringFormat("VETO | %s | %s", symbol, reason));
}

void LogSignal(string symbol, string grade, double score, string direction)
{
   LogMessage(LOG_INFO, "SIGNAL",
      StringFormat("%s | %s grade=%.1f dir=%s", symbol, grade, score, direction));
}

#endif
