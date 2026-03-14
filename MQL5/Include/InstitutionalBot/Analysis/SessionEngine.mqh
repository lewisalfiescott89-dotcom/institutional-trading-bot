//+------------------------------------------------------------------+
//| SessionEngine.mqh - Trading session identification               |
//| Identifies Asian, London, New York sessions and kill zones       |
//+------------------------------------------------------------------+
#ifndef SESSION_ENGINE_MQH
#define SESSION_ENGINE_MQH

#include "../Config.mqh"

enum ENUM_SESSION { SESSION_ASIAN, SESSION_LONDON, SESSION_NEW_YORK, SESSION_OVERLAP, SESSION_OFF };

struct SessionState
{
   ENUM_SESSION  current_session;
   bool          in_kill_zone;
   string        session_name;
   double        asian_high;
   double        asian_low;
   double        london_high;
   double        london_low;
   double        ny_high;
   double        ny_low;

   void Init()
   {
      current_session = SESSION_OFF;
      in_kill_zone    = false;
      session_name    = "OFF";
      asian_high  = -DBL_MAX; asian_low  = DBL_MAX;
      london_high = -DBL_MAX; london_low = DBL_MAX;
      ny_high     = -DBL_MAX; ny_low     = DBL_MAX;
   }
};

class CSessionEngine
{
private:
   SessionSettings m_cfg;

public:
   CSessionEngine() { m_cfg.Init(); }
   void SetConfig(const SessionSettings &cfg) { m_cfg = cfg; }

   //--- Update session state from current time
   void Update(datetime current_time, SessionState &state)
   {
      MqlDateTime dt;
      TimeToStruct(current_time, dt);
      int hour = dt.hour;
      int minute = dt.min;
      int time_mins = hour * 60 + minute;

      // Determine current session (UTC times)
      int asian_start  = m_cfg.asian_start_hour * 60;
      int asian_end    = m_cfg.asian_end_hour * 60;
      int london_start = m_cfg.london_start_hour * 60;
      int london_end   = m_cfg.london_end_hour * 60;
      int ny_start     = m_cfg.ny_start_hour * 60;
      int ny_end       = m_cfg.ny_end_hour * 60;

      if(time_mins >= london_start && time_mins < ny_end && time_mins >= ny_start)
      {
         if(time_mins < london_end)
         {
            state.current_session = SESSION_OVERLAP;
            state.session_name    = "LDN/NY Overlap";
         }
         else
         {
            state.current_session = SESSION_NEW_YORK;
            state.session_name    = "New York";
         }
      }
      else if(time_mins >= london_start && time_mins < london_end)
      {
         state.current_session = SESSION_LONDON;
         state.session_name    = "London";
      }
      else if(time_mins >= ny_start && time_mins < ny_end)
      {
         state.current_session = SESSION_NEW_YORK;
         state.session_name    = "New York";
      }
      else if(time_mins >= asian_start && time_mins < asian_end)
      {
         state.current_session = SESSION_ASIAN;
         state.session_name    = "Asian";
      }
      else
      {
         state.current_session = SESSION_OFF;
         state.session_name    = "OFF";
      }

      // Kill zone detection
      int london_kz_start = m_cfg.london_kz_start_hour * 60 + m_cfg.london_kz_start_min;
      int london_kz_end   = m_cfg.london_kz_end_hour * 60 + m_cfg.london_kz_end_min;
      int ny_kz_start     = m_cfg.ny_kz_start_hour * 60 + m_cfg.ny_kz_start_min;
      int ny_kz_end       = m_cfg.ny_kz_end_hour * 60 + m_cfg.ny_kz_end_min;

      state.in_kill_zone = (time_mins >= london_kz_start && time_mins < london_kz_end) ||
                           (time_mins >= ny_kz_start && time_mins < ny_kz_end);
   }

   //--- Track session highs and lows
   void TrackSessionLevels(const double &highs[], const double &lows[],
                           const datetime &times[], int bar_count,
                           SessionState &state)
   {
      if(bar_count == 0) return;

      MqlDateTime dt;
      for(int i = 0; i < bar_count; i++)
      {
         TimeToStruct(times[i], dt);
         int time_mins = dt.hour * 60 + dt.min;

         int asian_start = m_cfg.asian_start_hour * 60;
         int asian_end   = m_cfg.asian_end_hour * 60;
         int london_start= m_cfg.london_start_hour * 60;
         int london_end  = m_cfg.london_end_hour * 60;
         int ny_start    = m_cfg.ny_start_hour * 60;
         int ny_end      = m_cfg.ny_end_hour * 60;

         // Asian session range
         if(time_mins >= asian_start && time_mins < asian_end)
         {
            if(highs[i] > state.asian_high) state.asian_high = highs[i];
            if(lows[i] < state.asian_low)   state.asian_low  = lows[i];
         }
         // London session range
         if(time_mins >= london_start && time_mins < london_end)
         {
            if(highs[i] > state.london_high) state.london_high = highs[i];
            if(lows[i] < state.london_low)   state.london_low  = lows[i];
         }
         // NY session range
         if(time_mins >= ny_start && time_mins < ny_end)
         {
            if(highs[i] > state.ny_high) state.ny_high = highs[i];
            if(lows[i] < state.ny_low)   state.ny_low  = lows[i];
         }
      }
   }

   //--- Reset session levels at start of each day
   void ResetDailyLevels(SessionState &state)
   {
      state.asian_high  = -DBL_MAX; state.asian_low  = DBL_MAX;
      state.london_high = -DBL_MAX; state.london_low = DBL_MAX;
      state.ny_high     = -DBL_MAX; state.ny_low     = DBL_MAX;
   }
};

#endif
