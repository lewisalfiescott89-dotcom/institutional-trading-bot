//+------------------------------------------------------------------+
//| AdaptiveTPEngine.mqh - Self-optimizing partial TP management     |
//| Monitors trade outcomes and adapts the partial TP R-multiple     |
//| to maximize profit factor across rolling trade windows            |
//+------------------------------------------------------------------+
#ifndef ADAPTIVE_TP_ENGINE_MQH
#define ADAPTIVE_TP_ENGINE_MQH

#include "../Models/Trade.mqh"
#include "../Core/Logger.mqh"
#include "../Config.mqh"

//--- Performance bucket: tracks stats for a specific partial TP R-multiple
struct TPBucket
{
   double   r_multiple;        // The partial TP level (e.g. 1.0, 1.5, 2.0)
   int      total_trades;      // Trades closed at this level
   int      wins;              // Winning trades
   int      losses;            // Losing trades
   double   total_profit;      // Sum of winning trade PnL
   double   total_loss;        // Sum of losing trade PnL (positive number)
   double   profit_factor;     // total_profit / total_loss

   void Init(double r_mult)
   {
      r_multiple     = r_mult;
      total_trades   = 0;
      wins           = 0;
      losses         = 0;
      total_profit   = 0;
      total_loss     = 0;
      profit_factor  = 0;
   }

   void Update()
   {
      if(total_loss > 0)
         profit_factor = total_profit / total_loss;
      else if(total_profit > 0)
         profit_factor = 99.0;  // No losses = great
      else
         profit_factor = 0;
   }
};

//--- Rolling trade record for adaptive analysis
struct TPTradeRecord
{
   double   net_pnl;
   double   r_multiple_result;  // Actual R-multiple outcome
   double   partial_r_used;     // What partial TP R-level was active
   double   risk_distance;      // Original SL distance in price
   bool     partial_was_taken;  // Whether partial actually triggered
   datetime close_time;
};

#define MAX_TP_HISTORY    200
#define TP_BUCKET_COUNT     5   // 1.0R, 1.5R, 2.0R, 2.5R, 3.0R

class CAdaptiveTPEngine
{
private:
   TPBucket      m_buckets[TP_BUCKET_COUNT];
   TPTradeRecord m_history[MAX_TP_HISTORY];
   int           m_history_count;
   int           m_history_index;       // Circular buffer index

   double        m_current_r_mult;      // Current active partial TP R-multiple
   double        m_min_r_mult;          // Floor (never go below this)
   double        m_max_r_mult;          // Ceiling (never go above this)
   int           m_eval_interval;       // Re-evaluate every N trades
   int           m_trades_since_eval;   // Counter since last evaluation
   int           m_min_trades_to_adapt; // Min trades before adapting
   bool          m_enabled;             // Whether adaptive mode is active

public:
   CAdaptiveTPEngine()
   {
      m_current_r_mult      = 1.5;   // Start at 1.5R (middle ground)
      m_min_r_mult          = 1.0;
      m_max_r_mult          = 3.0;
      m_eval_interval       = 10;    // Re-evaluate every 10 trades
      m_trades_since_eval   = 0;
      m_min_trades_to_adapt = 15;    // Need at least 15 trades before adapting
      m_history_count       = 0;
      m_history_index       = 0;
      m_enabled             = true;

      // Initialize buckets at 1.0, 1.5, 2.0, 2.5, 3.0
      double levels[TP_BUCKET_COUNT] = {1.0, 1.5, 2.0, 2.5, 3.0};
      for(int i = 0; i < TP_BUCKET_COUNT; i++)
         m_buckets[i].Init(levels[i]);
   }

   void SetEnabled(bool enabled)          { m_enabled = enabled; }
   void SetStartMultiplier(double r_mult) { m_current_r_mult = r_mult; }
   void SetRange(double min_r, double max_r) { m_min_r_mult = min_r; m_max_r_mult = max_r; }
   void SetEvalInterval(int interval)     { m_eval_interval = interval; }

   //--- Get current optimal partial TP R-multiple
   double GetPartialTPMultiplier() const { return m_current_r_mult; }

   //--- Get partial TP distance in price for a specific trade
   double GetPartialTPDistance(double risk_distance)
   {
      if(risk_distance <= 0) return 0;
      return risk_distance * m_current_r_mult;
   }

   //--- Record a closed trade for performance tracking
   void RecordTrade(const TradeData &trade)
   {
      if(!m_enabled) return;

      double risk_dist = MathAbs(trade.entry_price - trade.original_sl_price);
      if(risk_dist <= 0)
         risk_dist = MathAbs(trade.entry_price - trade.sl_price);
      if(risk_dist <= 0) return;

      // Store in circular buffer
      int idx = m_history_index % MAX_TP_HISTORY;
      m_history[idx].net_pnl           = trade.net_pnl;
      m_history[idx].r_multiple_result  = trade.r_multiple;
      m_history[idx].partial_r_used     = m_current_r_mult;
      m_history[idx].risk_distance      = risk_dist;
      m_history[idx].partial_was_taken  = trade.partial_taken;
      m_history[idx].close_time         = trade.close_time;
      m_history_index++;
      if(m_history_count < MAX_TP_HISTORY)
         m_history_count++;

      // Assign to the nearest bucket for tracking
      int bucket_idx = FindNearestBucket(m_current_r_mult);
      if(bucket_idx >= 0)
      {
         m_buckets[bucket_idx].total_trades++;
         if(trade.net_pnl > 0)
         {
            m_buckets[bucket_idx].wins++;
            m_buckets[bucket_idx].total_profit += trade.net_pnl;
         }
         else if(trade.net_pnl < 0)
         {
            m_buckets[bucket_idx].losses++;
            m_buckets[bucket_idx].total_loss += MathAbs(trade.net_pnl);
         }
         m_buckets[bucket_idx].Update();
      }

      m_trades_since_eval++;

      // Periodically re-evaluate and adapt
      if(m_trades_since_eval >= m_eval_interval)
      {
         Evaluate();
         m_trades_since_eval = 0;
      }
   }

   //--- Force evaluation (can be called externally)
   void Evaluate()
   {
      if(!m_enabled) return;

      int total_tracked = 0;
      for(int i = 0; i < TP_BUCKET_COUNT; i++)
         total_tracked += m_buckets[i].total_trades;

      if(total_tracked < m_min_trades_to_adapt)
      {
         LogMessage(LOG_INFO, "ADAPTIVE_TP",
            StringFormat("Not enough trades to adapt yet (%d/%d). Current: %.1fR",
               total_tracked, m_min_trades_to_adapt, m_current_r_mult));
         return;
      }

      // Find the bucket with the best profit factor (min 3 trades)
      double best_pf     = -1;
      int    best_bucket = -1;

      for(int i = 0; i < TP_BUCKET_COUNT; i++)
      {
         if(m_buckets[i].total_trades >= 3)
         {
            if(m_buckets[i].profit_factor > best_pf)
            {
               best_pf     = m_buckets[i].profit_factor;
               best_bucket = i;
            }
         }
      }

      // Also analyze recent trend — are we improving or declining?
      double recent_pf = CalculateRecentPF(20);  // Last 20 trades

      double old_r = m_current_r_mult;

      if(best_bucket >= 0 && best_pf > 0)
      {
         double target_r = m_buckets[best_bucket].r_multiple;

         // Gradual adjustment: move 0.25R toward the best bucket
         if(target_r > m_current_r_mult)
            m_current_r_mult = MathMin(m_current_r_mult + 0.25, m_max_r_mult);
         else if(target_r < m_current_r_mult)
            m_current_r_mult = MathMax(m_current_r_mult - 0.25, m_min_r_mult);

         // If recent performance is bad (PF < 0.8), shift toward wider partials
         if(recent_pf > 0 && recent_pf < 0.8 && m_current_r_mult < m_max_r_mult)
            m_current_r_mult = MathMin(m_current_r_mult + 0.25, m_max_r_mult);
      }

      LogMessage(LOG_INFO, "ADAPTIVE_TP",
         StringFormat("EVAL | Trades=%d | Best bucket=%.1fR (PF=%.2f) | Recent PF=%.2f | Partial TP: %.1fR -> %.1fR",
            total_tracked,
            (best_bucket >= 0) ? m_buckets[best_bucket].r_multiple : 0.0,
            best_pf,
            recent_pf,
            old_r,
            m_current_r_mult));
   }

   //--- Get performance summary string for diagnostics
   string GetPerformanceSummary()
   {
      string summary = "ADAPTIVE_TP_SUMMARY | ";
      for(int i = 0; i < TP_BUCKET_COUNT; i++)
      {
         summary += StringFormat("%.1fR: %dW/%dL PF=%.2f | ",
            m_buckets[i].r_multiple,
            m_buckets[i].wins,
            m_buckets[i].losses,
            m_buckets[i].profit_factor);
      }
      summary += StringFormat("Active=%.1fR", m_current_r_mult);
      return summary;
   }

   //--- Log full performance report
   void LogPerformanceReport()
   {
      LogMessage(LOG_INFO, "ADAPTIVE_TP", GetPerformanceSummary());

      double recent_pf = CalculateRecentPF(20);
      double overall_pf = CalculateRecentPF(MAX_TP_HISTORY);

      LogMessage(LOG_INFO, "ADAPTIVE_TP",
         StringFormat("REPORT | Total tracked=%d | Recent PF(20)=%.2f | Overall PF=%.2f | Current multiplier=%.1fR",
            m_history_count, recent_pf, overall_pf, m_current_r_mult));
   }

private:
   //--- Find the bucket index nearest to a given R-multiple
   int FindNearestBucket(double r_mult)
   {
      int    best_idx  = 0;
      double best_dist = DBL_MAX;
      for(int i = 0; i < TP_BUCKET_COUNT; i++)
      {
         double dist = MathAbs(m_buckets[i].r_multiple - r_mult);
         if(dist < best_dist)
         {
            best_dist = dist;
            best_idx  = i;
         }
      }
      return best_idx;
   }

   //--- Calculate profit factor from recent N trades
   double CalculateRecentPF(int lookback)
   {
      if(m_history_count == 0) return 0;

      double wins_sum  = 0;
      double loss_sum  = 0;
      int count = MathMin(lookback, m_history_count);

      for(int i = 0; i < count; i++)
      {
         int idx = (m_history_index - 1 - i);
         if(idx < 0) idx += MAX_TP_HISTORY;
         idx = idx % MAX_TP_HISTORY;

         if(m_history[idx].net_pnl > 0)
            wins_sum += m_history[idx].net_pnl;
         else if(m_history[idx].net_pnl < 0)
            loss_sum += MathAbs(m_history[idx].net_pnl);
      }

      if(loss_sum > 0)
         return wins_sum / loss_sum;
      else if(wins_sum > 0)
         return 99.0;
      return 0;
   }
};

#endif
