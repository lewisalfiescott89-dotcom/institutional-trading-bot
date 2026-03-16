//+------------------------------------------------------------------+
//| LiquidityTimingEngine.mqh - Qualifies setup timing               |
//| Determines when sweeps are most likely based on session windows   |
//+------------------------------------------------------------------+
#ifndef LIQUIDITY_TIMING_ENGINE_MQH
#define LIQUIDITY_TIMING_ENGINE_MQH

#include "../Config.mqh"
#include "SessionEngine.mqh"

struct TimingResult
{
   double quality;          // 0.0 to 1.0
   bool   allow_trade;
   string reason;
   bool   in_expansion;     // Session expansion window
   bool   is_stale;         // Setup has lingered too long
   int    bars_in_zone;     // How many bars price spent in POI zone

   void Init()
   {
      quality      = 0;
      allow_trade  = false;
      reason       = "";
      in_expansion = false;
      is_stale     = false;
      bars_in_zone = 0;
   }
};

class CLiquidityTimingEngine
{
private:
   TimingSettings m_cfg;

public:
   CLiquidityTimingEngine() { m_cfg.Init(); }
   void SetConfig(const TimingSettings &cfg) { m_cfg = cfg; }

   //--- Evaluate timing quality for a potential setup
   void Evaluate(const SessionState &session, double setup_grade_score,
                 int bars_in_zone, TimingResult &result)
   {
      result.Init();
      result.bars_in_zone = bars_in_zone;

      // Base timing quality from session
      double session_quality = GetSessionQuality(session);
      result.quality = session_quality;

      // Kill zone boost
      if(session.in_kill_zone)
      {
         result.quality *= 1.3;
         result.in_expansion = true;
      }

      // Overlap gets extra boost
      if(session.current_session == SESSION_OVERLAP)
         result.quality *= 1.2;

      // Stale check: if price has been in zone too long, degrade
      if(bars_in_zone > m_cfg.stale_bars_threshold)
      {
         result.is_stale = true;
         double stale_penalty = (double)(bars_in_zone - m_cfg.stale_bars_threshold) * 0.1;
         result.quality *= MathMax(0.0, 1.0 - stale_penalty);
      }

      // Clamp quality
      result.quality = MathMin(result.quality, 1.0);

      // Determine if trade is allowed
      // A+ and A setups allowed anytime (high score > 7)
      if(setup_grade_score >= 7.0)
      {
         result.allow_trade = true;
         result.reason = "High-grade setup allowed anytime";
      }
      // B setups allowed in any active session including Asian (score 5-7)
      else if(setup_grade_score >= 5.0)
      {
         if(session.in_kill_zone || session.current_session == SESSION_LONDON ||
            session.current_session == SESSION_NEW_YORK || session.current_session == SESSION_OVERLAP ||
            session.current_session == SESSION_ASIAN)
         {
            result.allow_trade = true;
            result.reason = "Mid-grade setup in active session";
         }
         else
         {
            result.allow_trade = false;
            result.reason = "Mid-grade setup outside active session";
         }
      }
      // C setups in any active session including Asian (score 3-5)
      else if(setup_grade_score >= 3.0)
      {
         if(session.in_kill_zone || session.current_session == SESSION_LONDON ||
            session.current_session == SESSION_NEW_YORK || session.current_session == SESSION_OVERLAP ||
            session.current_session == SESSION_ASIAN)
         {
            result.allow_trade = true;
            result.reason = "Low-grade setup in active session";
         }
         else
         {
            result.allow_trade = false;
            result.reason = "Low-grade setup outside active session";
         }
      }
      // D setups: allow in kill zones only
      else if(setup_grade_score >= 2.0)
      {
         if(session.in_kill_zone)
         {
            result.allow_trade = true;
            result.reason = "Minimal setup in kill zone";
         }
         else
         {
            result.allow_trade = false;
            result.reason = "Minimal setup outside kill zone";
         }
      }
      // Very low setups blocked
      else
      {
         result.allow_trade = false;
         result.reason = "Setup grade too low";
      }

      // Stale override: block if very stale
      if(result.is_stale && bars_in_zone > m_cfg.stale_bars_threshold * 2)
      {
         result.allow_trade = false;
         result.reason = "Setup is stale - price lingering too long";
      }
   }

private:
   double GetSessionQuality(const SessionState &session)
   {
      switch(session.current_session)
      {
         case SESSION_OVERLAP: return 1.0;
         case SESSION_LONDON:  return 0.9;
         case SESSION_NEW_YORK:return 0.85;
         case SESSION_ASIAN:   return 0.4;
         case SESSION_OFF:     return 0.2;
         default:              return 0.3;
      }
   }
};

#endif
