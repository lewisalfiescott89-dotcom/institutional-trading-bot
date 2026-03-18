//+------------------------------------------------------------------+
//| POIDiagnosticEngine.mqh - Diagnostic tracking for POI entries     |
//| Tracks why POIs are traded or rejected, missed opportunities      |
//+------------------------------------------------------------------+
#ifndef POI_DIAGNOSTIC_ENGINE_MQH
#define POI_DIAGNOSTIC_ENGINE_MQH

#include "../Core/Logger.mqh"
#include "../Models/POI.mqh"
#include "../Config.mqh"

//--- Rejection reason codes
enum ENUM_REJECTION_REASON
{
   REJ_NONE = 0,            // Not rejected (traded)
   REJ_HTF_FILTER,          // Counter-trend vs D1 bias
   REJ_NO_REVERSAL,         // No reversal candle or MSS detected
   REJ_NO_SWEEP_TRAP,       // No sweep/trap (strict mode)
   REJ_TIMING_BLOCKED,      // Timing/session gate
   REJ_GRADE_D,             // Grade D quality
   REJ_SAFETY_BLOCKED,      // Safety engine veto
   REJ_RISK_BLOCKED,        // Risk engine veto
   REJ_COOLDOWN,            // Cooldown period
   REJ_KILL_ZONE,           // Not in kill zone
   REJ_FVG_REQUIRED,        // No FVG confluence
   REJ_OB_REQUIRED,         // No OB confluence
   REJ_LIQ_CONF_REQUIRED,   // Insufficient liquidity confluence
   REJ_LONG_ONLY,           // Bearish POI in long-only mode
   REJ_POI_TF_TOO_LOW,      // POI from M5/M15 (below minimum TF)
   REJ_INVALIDATED,         // Zone was invalidated
   REJ_DAILY_LIMIT,         // Daily trade limit reached
   REJ_MAX_POSITIONS,       // Max concurrent positions
   REJ_MARGIN               // Margin insufficient
};

//--- Pending opportunity check
struct PendingOpportunity
{
   int                poi_id;
   ENUM_POI_DIRECTION direction;
   double             zone_mid;
   datetime           touch_time;
   double             touch_price;
   ENUM_REJECTION_REASON reason;
   ENUM_TIMEFRAMES    source_tf;
   bool               active;

   void Init()
   {
      poi_id      = 0;
      direction   = POI_BULLISH;
      zone_mid    = 0;
      touch_time  = 0;
      touch_price = 0;
      reason      = REJ_NONE;
      source_tf   = PERIOD_M5;
      active      = false;
   }
};

class CPOIDiagnosticEngine
{
private:
   // Summary counters (per reporting period)
   int m_zone_touches;
   int m_htf_filtered;
   int m_no_reversal;
   int m_no_sweep_trap;
   int m_timing_blocked;
   int m_grade_d_blocked;
   int m_safety_blocked;
   int m_risk_blocked;
   int m_cooldown_blocked;
   int m_kz_blocked;
   int m_fvg_filtered;
   int m_ob_filtered;
   int m_liq_conf_filtered;
   int m_long_only_filtered;
   int m_poi_tf_too_low;
   int m_invalidated;
   int m_daily_limit;
   int m_max_positions;
   int m_margin_blocked;
   int m_trades_taken;
   int m_trades_won;
   int m_trades_lost;
   int m_missed_opportunities;

   // HTF vs LTF touch breakdown
   int m_htf_touches;   // H1+
   int m_ltf_touches;   // M5/M15

   // Pending opportunity tracking
   PendingOpportunity m_pending[100];
   int m_pending_count;
   double m_opportunity_threshold_pips;

   int m_bar_counter;
   int m_summary_interval;

public:
   CPOIDiagnosticEngine() : m_pending_count(0), m_bar_counter(0),
                             m_summary_interval(200),
                             m_opportunity_threshold_pips(60.0)
   {
      ResetCounters();
   }

   void SetSummaryInterval(int bars)          { m_summary_interval = bars; }
   void SetOpportunityThreshold(double pips)  { m_opportunity_threshold_pips = pips; }

   void ResetCounters()
   {
      m_zone_touches       = 0;
      m_htf_filtered       = 0;
      m_no_reversal        = 0;
      m_no_sweep_trap      = 0;
      m_timing_blocked     = 0;
      m_grade_d_blocked    = 0;
      m_safety_blocked     = 0;
      m_risk_blocked       = 0;
      m_cooldown_blocked   = 0;
      m_kz_blocked         = 0;
      m_fvg_filtered       = 0;
      m_ob_filtered        = 0;
      m_liq_conf_filtered  = 0;
      m_long_only_filtered = 0;
      m_poi_tf_too_low     = 0;
      m_invalidated        = 0;
      m_daily_limit        = 0;
      m_max_positions      = 0;
      m_margin_blocked     = 0;
      m_trades_taken       = 0;
      m_trades_won         = 0;
      m_trades_lost        = 0;
      m_missed_opportunities = 0;
      m_htf_touches        = 0;
      m_ltf_touches        = 0;
   }

   //--- Record a zone touch with TF breakdown
   void RecordTouch(const POIData &poi)
   {
      m_zone_touches++;
      if(poi.timeframe >= PERIOD_H1)
         m_htf_touches++;
      else
         m_ltf_touches++;
   }

   //--- Record a rejection with reason
   void RecordRejection(ENUM_REJECTION_REASON reason)
   {
      switch(reason)
      {
         case REJ_HTF_FILTER:        m_htf_filtered++; break;
         case REJ_NO_REVERSAL:       m_no_reversal++; break;
         case REJ_NO_SWEEP_TRAP:     m_no_sweep_trap++; break;
         case REJ_TIMING_BLOCKED:    m_timing_blocked++; break;
         case REJ_GRADE_D:           m_grade_d_blocked++; break;
         case REJ_SAFETY_BLOCKED:    m_safety_blocked++; break;
         case REJ_RISK_BLOCKED:      m_risk_blocked++; break;
         case REJ_COOLDOWN:          m_cooldown_blocked++; break;
         case REJ_KILL_ZONE:         m_kz_blocked++; break;
         case REJ_FVG_REQUIRED:      m_fvg_filtered++; break;
         case REJ_OB_REQUIRED:       m_ob_filtered++; break;
         case REJ_LIQ_CONF_REQUIRED: m_liq_conf_filtered++; break;
         case REJ_LONG_ONLY:         m_long_only_filtered++; break;
         case REJ_POI_TF_TOO_LOW:    m_poi_tf_too_low++; break;
         case REJ_INVALIDATED:       m_invalidated++; break;
         case REJ_DAILY_LIMIT:       m_daily_limit++; break;
         case REJ_MAX_POSITIONS:     m_max_positions++; break;
         case REJ_MARGIN:            m_margin_blocked++; break;
         default: break;
      }
   }

   //--- Record a rejected zone touch for later opportunity checking
   void RecordPendingOpportunity(const POIData &poi, double current_price,
                                  datetime current_time, ENUM_REJECTION_REASON reason)
   {
      if(m_pending_count >= 100)
      {
         // Shift array, drop oldest
         for(int i = 0; i < 99; i++)
            m_pending[i] = m_pending[i + 1];
         m_pending_count = 99;
      }
      m_pending[m_pending_count].Init();
      m_pending[m_pending_count].poi_id      = poi.id;
      m_pending[m_pending_count].direction   = poi.direction;
      m_pending[m_pending_count].zone_mid    = poi.MidPrice();
      m_pending[m_pending_count].touch_time  = current_time;
      m_pending[m_pending_count].touch_price = current_price;
      m_pending[m_pending_count].reason      = reason;
      m_pending[m_pending_count].source_tf   = poi.timeframe;
      m_pending[m_pending_count].active      = true;
      m_pending_count++;
   }

   //--- Record a trade execution
   void RecordTrade() { m_trades_taken++; }

   //--- Record trade outcome
   void RecordOutcome(bool won)
   {
      if(won) m_trades_won++;
      else    m_trades_lost++;
   }

   //--- Check pending opportunities for missed moves
   void CheckOpportunities(double current_price, string symbol, double pip_size)
   {
      if(pip_size <= 0) return;

      for(int i = 0; i < m_pending_count; i++)
      {
         if(!m_pending[i].active) continue;

         double move_pips = 0;
         if(m_pending[i].direction == POI_BULLISH)
            move_pips = (current_price - m_pending[i].touch_price) / pip_size;
         else
            move_pips = (m_pending[i].touch_price - current_price) / pip_size;

         if(move_pips >= m_opportunity_threshold_pips)
         {
            m_missed_opportunities++;
            LogMessage(LOG_WARNING, "DIAG_MISSED",
               StringFormat("%s POI#%d %s from %s | Price moved %.0f pips in our favor! | Blocked by: %s",
                  symbol, m_pending[i].poi_id,
                  m_pending[i].direction == POI_BULLISH ? "BUY" : "SELL",
                  TimeframeToString(m_pending[i].source_tf),
                  move_pips,
                  RejectionToString(m_pending[i].reason)));
            m_pending[i].active = false;
         }
         else if(move_pips < -m_opportunity_threshold_pips)
         {
            // Price went against us - rejection was correct
            m_pending[i].active = false;
         }
      }

      // Compact array: remove inactive entries
      int write_idx = 0;
      for(int i = 0; i < m_pending_count; i++)
      {
         if(m_pending[i].active)
         {
            if(write_idx != i) m_pending[write_idx] = m_pending[i];
            write_idx++;
         }
      }
      m_pending_count = write_idx;
   }

   //--- Called each bar to track timing and check opportunities
   void OnBar(string symbol, double current_price, double pip_size)
   {
      m_bar_counter++;
      CheckOpportunities(current_price, symbol, pip_size);

      if(m_bar_counter >= m_summary_interval)
      {
         LogSummary(symbol);
         m_bar_counter = 0;
      }
   }

   //--- Log detailed diagnostic summary
   void LogSummary(string symbol)
   {
      if(m_zone_touches == 0 && m_trades_taken == 0) return;

      double hit_rate = (m_trades_taken > 0)
                        ? (double)m_trades_won / (double)m_trades_taken * 100.0
                        : 0;

      LogMessage(LOG_INFO, "DIAG_SUMMARY",
         StringFormat("=== %s POI DIAGNOSTIC (last %d bars) ===", symbol, m_summary_interval));

      LogMessage(LOG_INFO, "DIAG_SUMMARY",
         StringFormat("Zone Touches: %d (HTF: %d, LTF: %d) | Trades: %d | Won: %d | Lost: %d | HitRate: %.0f%%",
            m_zone_touches, m_htf_touches, m_ltf_touches,
            m_trades_taken, m_trades_won, m_trades_lost, hit_rate));

      LogMessage(LOG_INFO, "DIAG_SUMMARY",
         StringFormat("MISSED OPPORTUNITIES: %d (rejected but price moved %.0f+ pips in our favor)",
            m_missed_opportunities, m_opportunity_threshold_pips));

      LogMessage(LOG_INFO, "DIAG_REJECTIONS",
         StringFormat("HTF_Filter=%d NoRev=%d NoSweep=%d Timing=%d GradeD=%d Safety=%d Risk=%d Cooldown=%d KZ=%d",
            m_htf_filtered, m_no_reversal, m_no_sweep_trap, m_timing_blocked,
            m_grade_d_blocked, m_safety_blocked, m_risk_blocked, m_cooldown_blocked, m_kz_blocked));

      LogMessage(LOG_INFO, "DIAG_REJECTIONS",
         StringFormat("FVG=%d OB=%d LiqConf=%d LongOnly=%d LowTF=%d Invalidated=%d DailyLim=%d MaxPos=%d Margin=%d",
            m_fvg_filtered, m_ob_filtered, m_liq_conf_filtered, m_long_only_filtered,
            m_poi_tf_too_low, m_invalidated, m_daily_limit, m_max_positions, m_margin_blocked));

      // Reset for next period
      ResetCounters();
   }

   //--- Force log summary (e.g. at deinit)
   void ForceSummary(string symbol) { LogSummary(symbol); }

   string RejectionToString(ENUM_REJECTION_REASON r)
   {
      switch(r)
      {
         case REJ_NONE:              return "NONE";
         case REJ_HTF_FILTER:        return "HTF_FILTER";
         case REJ_NO_REVERSAL:       return "NO_REVERSAL";
         case REJ_NO_SWEEP_TRAP:     return "NO_SWEEP_TRAP";
         case REJ_TIMING_BLOCKED:    return "TIMING";
         case REJ_GRADE_D:           return "GRADE_D";
         case REJ_SAFETY_BLOCKED:    return "SAFETY";
         case REJ_RISK_BLOCKED:      return "RISK";
         case REJ_COOLDOWN:          return "COOLDOWN";
         case REJ_KILL_ZONE:         return "KILL_ZONE";
         case REJ_FVG_REQUIRED:      return "FVG_REQUIRED";
         case REJ_OB_REQUIRED:       return "OB_REQUIRED";
         case REJ_LIQ_CONF_REQUIRED: return "LIQ_CONF";
         case REJ_LONG_ONLY:         return "LONG_ONLY";
         case REJ_POI_TF_TOO_LOW:    return "LOW_TF";
         case REJ_INVALIDATED:       return "INVALIDATED";
         case REJ_DAILY_LIMIT:       return "DAILY_LIMIT";
         case REJ_MAX_POSITIONS:     return "MAX_POSITIONS";
         case REJ_MARGIN:            return "MARGIN";
         default:                    return "UNKNOWN";
      }
   }
};

#endif
