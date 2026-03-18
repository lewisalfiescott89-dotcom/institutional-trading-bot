//+------------------------------------------------------------------+
//| SessionEngine.mqh - Trading session identification               |
//| Identifies Asian, London, New York sessions and kill zones       |
//+------------------------------------------------------------------+
#ifndef SESSION_ENGINE_MQH
#define SESSION_ENGINE_MQH

#include "../Config.mqh"

enum ENUM_SESSION { SESSION_ASIAN, SESSION_LONDON, SESSION_NEW_YORK, SESSION_OVERLAP, SESSION_OFF };

enum ENUM_SESSION_BIAS { SESS_BIAS_NEUTRAL, SESS_BIAS_BULLISH, SESS_BIAS_BEARISH };

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
   double        london_open_price;     // Price at London session open
   double        ny_open_price;         // Price at NY session open
   ENUM_SESSION_BIAS london_bias;       // London session directional bias
   bool          asian_high_swept;      // Asian high was taken out (sell-side grab)
   bool          asian_low_swept;       // Asian low was taken out (buy-side grab)
   bool          london_open_set;       // Whether london_open_price has been recorded today
   bool          ny_open_set;           // Whether ny_open_price has been recorded today

   void Init()
   {
      current_session = SESSION_OFF;
      in_kill_zone    = false;
      session_name    = "OFF";
      asian_high  = -DBL_MAX; asian_low  = DBL_MAX;
      london_high = -DBL_MAX; london_low = DBL_MAX;
      ny_high     = -DBL_MAX; ny_low     = DBL_MAX;
      london_open_price = 0;
      ny_open_price     = 0;
      london_bias       = SESS_BIAS_NEUTRAL;
      asian_high_swept  = false;
      asian_low_swept   = false;
      london_open_set   = false;
      ny_open_set       = false;
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

   //--- Track session highs and lows (today's bars only)
   void TrackSessionLevels(const double &highs[], const double &lows[],
                           const datetime &times[], int bar_count,
                           SessionState &state)
   {
      if(bar_count == 0) return;

      // Only accumulate bars from today
      MqlDateTime today_dt;
      TimeToStruct(TimeCurrent(), today_dt);
      int today_day  = today_dt.day;
      int today_mon  = today_dt.mon;
      int today_year = today_dt.year;

      MqlDateTime dt;
      for(int i = 0; i < bar_count; i++)
      {
         TimeToStruct(times[i], dt);

         // Skip bars not from today
         if(dt.day != today_day || dt.mon != today_mon || dt.year != today_year)
            continue;

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

   //--- Record session open prices and detect Asian range sweeps
   void UpdateSessionBias(double current_price, SessionState &state)
   {
      // Record London open price on first bar of London session
      if((state.current_session == SESSION_LONDON || state.current_session == SESSION_OVERLAP)
         && !state.london_open_set && current_price > 0)
      {
         state.london_open_price = current_price;
         state.london_open_set   = true;
      }

      // Record NY open price on first bar of NY/overlap session
      if((state.current_session == SESSION_NEW_YORK || state.current_session == SESSION_OVERLAP)
         && !state.ny_open_set && current_price > 0)
      {
         state.ny_open_price = current_price;
         state.ny_open_set   = true;
      }

      // Update London directional bias based on session range
      if(state.london_open_set && state.london_open_price > 0)
      {
         double london_move = current_price - state.london_open_price;
         // Need at least some movement to establish bias
         if(london_move > 0 && state.london_high > state.london_open_price)
            state.london_bias = SESS_BIAS_BULLISH;
         else if(london_move < 0 && state.london_low < state.london_open_price)
            state.london_bias = SESS_BIAS_BEARISH;
      }

      // Detect Asian range sweeps (institutional liquidity grabs)
      if(state.asian_high > -DBL_MAX && !state.asian_high_swept)
      {
         if(current_price > state.asian_high)
            state.asian_high_swept = true;  // Buy-side liquidity above Asian high was grabbed
      }
      if(state.asian_low < DBL_MAX && !state.asian_low_swept)
      {
         if(current_price < state.asian_low)
            state.asian_low_swept = true;   // Sell-side liquidity below Asian low was grabbed
      }
   }

   //--- Get session momentum direction for trade filtering
   //    Returns: +1 for bullish session bias, -1 for bearish, 0 for neutral
   int GetSessionMomentum(const SessionState &state)
   {
      if(state.london_bias == SESS_BIAS_BULLISH)  return +1;
      if(state.london_bias == SESS_BIAS_BEARISH)  return -1;
      return 0;
   }

   //--- Check if we're in a late session (profit-taking window)
   bool IsLateSession(datetime current_time)
   {
      MqlDateTime dt;
      TimeToStruct(current_time, dt);
      int hour = dt.hour;
      // Late London: after 14:00 UTC (last 2hrs before London close)
      // Late NY: after 19:00 UTC (last 2hrs before NY close)
      return (hour >= 14 && hour < 16) || (hour >= 19 && hour < 21);
   }

   //--- Check if we're in London/NY overlap (highest volume period)
   bool IsOverlap(const SessionState &state)
   {
      return (state.current_session == SESSION_OVERLAP);
   }

   //--- Reset session levels at start of each day
   void ResetDailyLevels(SessionState &state)
   {
      state.asian_high  = -DBL_MAX; state.asian_low  = DBL_MAX;
      state.london_high = -DBL_MAX; state.london_low = DBL_MAX;
      state.ny_high     = -DBL_MAX; state.ny_low     = DBL_MAX;
      state.london_open_price = 0;
      state.ny_open_price     = 0;
      state.london_bias       = SESS_BIAS_NEUTRAL;
      state.asian_high_swept  = false;
      state.asian_low_swept   = false;
      state.london_open_set   = false;
      state.ny_open_set       = false;
   }
};

#endif
