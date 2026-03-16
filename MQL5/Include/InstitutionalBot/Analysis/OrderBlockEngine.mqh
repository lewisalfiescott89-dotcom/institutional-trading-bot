//+------------------------------------------------------------------+
//| OrderBlockEngine.mqh - ICT Order Block + Breaker Block detection |
//| Order Block: last opposing candle before impulsive move          |
//| Breaker Block: OB that was broken through (polarity reversal)    |
//+------------------------------------------------------------------+
#ifndef ORDER_BLOCK_ENGINE_MQH
#define ORDER_BLOCK_ENGINE_MQH

#include "../Core/Utils.mqh"
#include "../Models/OrderBlock.mqh"
#include "../Config.mqh"

class COrderBlockEngine
{
private:
   int m_next_ob_id;
   int m_next_bb_id;
   double m_min_impulse_atr;     // Min impulse size as ATR multiple
   double m_min_body_ratio;      // Min body/range ratio for displacement candle

public:
   COrderBlockEngine() : m_next_ob_id(1), m_next_bb_id(1),
                          m_min_impulse_atr(1.2), m_min_body_ratio(0.5) {}

   void SetMinImpulseATR(double val) { m_min_impulse_atr = val; }
   void SetMinBodyRatio(double val)  { m_min_body_ratio = val; }

   //+------------------------------------------------------------------+
   //| Detect Order Blocks                                               |
   //| Scans for displacement candles and marks the last opposing       |
   //| candle before the move as the OB zone                            |
   //+------------------------------------------------------------------+
   int DetectOrderBlocks(const double &opens[], const double &highs[],
                         const double &lows[], const double &closes[],
                         const datetime &times[], int bar_count,
                         string symbol, ENUM_TIMEFRAMES tf,
                         OrderBlockData &obs[], int max_obs)
   {
      int count = 0;
      if(bar_count < 20) return 0;

      double atr_arr[];
      ComputeATRArray(highs, lows, closes, 14, bar_count, atr_arr);

      for(int i = 15; i < bar_count - 1 && count < max_obs; i++)
      {
         if(atr_arr[i] <= 0) continue;
         double current_atr = atr_arr[i];

         double body  = CandleBody(opens[i], closes[i]);
         double range = CandleRange(highs[i], lows[i]);
         if(range == 0) continue;

         // Check for impulsive displacement candle
         if(body < current_atr * m_min_impulse_atr) continue;
         if(body / range < m_min_body_ratio) continue;

         // Bearish displacement -> Bearish OB (last bullish candle before move)
         if(IsBearish(opens[i], closes[i]))
         {
            for(int j = i - 1; j >= MathMax(i - 10, 0); j--)
            {
               if(IsBullish(opens[j], closes[j]))
               {
                  obs[count].Init();
                  obs[count].id           = m_next_ob_id++;
                  obs[count].symbol       = symbol;
                  obs[count].timeframe    = tf;
                  obs[count].direction    = OB_BEARISH;
                  obs[count].zone_high    = highs[j];
                  obs[count].zone_low     = lows[j];
                  obs[count].impulse_size = body;
                  obs[count].quality      = ScoreOB(body, current_atr, tf);
                  obs[count].origin_bar   = j;
                  obs[count].origin_time  = times[j];
                  count++;
                  break;
               }
            }
         }
         // Bullish displacement -> Bullish OB (last bearish candle before move)
         else if(IsBullish(opens[i], closes[i]))
         {
            for(int j = i - 1; j >= MathMax(i - 10, 0); j--)
            {
               if(IsBearish(opens[j], closes[j]))
               {
                  obs[count].Init();
                  obs[count].id           = m_next_ob_id++;
                  obs[count].symbol       = symbol;
                  obs[count].timeframe    = tf;
                  obs[count].direction    = OB_BULLISH;
                  obs[count].zone_high    = highs[j];
                  obs[count].zone_low     = lows[j];
                  obs[count].impulse_size = body;
                  obs[count].quality      = ScoreOB(body, current_atr, tf);
                  obs[count].origin_bar   = j;
                  obs[count].origin_time  = times[j];
                  count++;
                  break;
               }
            }
         }
      }
      return count;
   }

   //+------------------------------------------------------------------+
   //| Update OB status based on price action                           |
   //| Marks OBs as tested, mitigated, or broken                       |
   //+------------------------------------------------------------------+
   void UpdateOBStatus(OrderBlockData &obs[], int ob_count,
                       const double &highs[], const double &lows[],
                       const double &closes[], int bar_count)
   {
      for(int i = 0; i < ob_count; i++)
      {
         if(!obs[i].active) continue;
         int start = obs[i].origin_bar + 2;
         if(start >= bar_count) continue;

         for(int k = start; k < bar_count; k++)
         {
            // Check if price entered the OB zone
            bool touched = (lows[k] <= obs[i].zone_high && highs[k] >= obs[i].zone_low);

            if(obs[i].direction == OB_BULLISH)
            {
               // Bullish OB broken if price closes below zone
               if(closes[k] < obs[i].zone_low)
               {
                  obs[i].status = OB_BROKEN;
                  obs[i].active = false;
                  break;
               }
               if(touched && obs[i].status == OB_FRESH)
                  obs[i].status = OB_TESTED;
            }
            else // OB_BEARISH
            {
               // Bearish OB broken if price closes above zone
               if(closes[k] > obs[i].zone_high)
               {
                  obs[i].status = OB_BROKEN;
                  obs[i].active = false;
                  break;
               }
               if(touched && obs[i].status == OB_FRESH)
                  obs[i].status = OB_TESTED;
            }
         }
      }
   }

   //+------------------------------------------------------------------+
   //| Detect Breaker Blocks from broken Order Blocks                   |
   //| When an OB fails, it becomes a zone of opposite polarity         |
   //+------------------------------------------------------------------+
   int DetectBreakerBlocks(OrderBlockData &obs[], int ob_count,
                           const double &closes[], const datetime &times[],
                           int bar_count, string symbol,
                           BreakerBlockData &bbs[], int max_bbs)
   {
      int count = 0;

      for(int i = 0; i < ob_count && count < max_bbs; i++)
      {
         if(obs[i].status != OB_BROKEN) continue;

         // Find the bar where the OB was broken
         int break_bar = -1;
         int start = obs[i].origin_bar + 2;
         if(start >= bar_count) continue;

         for(int k = start; k < bar_count; k++)
         {
            if(obs[i].direction == OB_BULLISH && closes[k] < obs[i].zone_low)
            {
               break_bar = k;
               break;
            }
            else if(obs[i].direction == OB_BEARISH && closes[k] > obs[i].zone_high)
            {
               break_bar = k;
               break;
            }
         }

         if(break_bar < 0) continue;

         bbs[count].Init();
         bbs[count].id            = m_next_bb_id++;
         bbs[count].symbol        = symbol;
         bbs[count].timeframe     = obs[i].timeframe;
         // Direction flips: bullish OB broken = bearish breaker, and vice versa
         bbs[count].direction     = (obs[i].direction == OB_BULLISH) ? OB_BEARISH : OB_BULLISH;
         bbs[count].zone_high     = obs[i].zone_high;
         bbs[count].zone_low      = obs[i].zone_low;
         bbs[count].quality       = obs[i].quality * 0.8;  // Slightly less than original OB
         bbs[count].ob_origin_bar = obs[i].origin_bar;
         bbs[count].break_bar     = break_bar;
         bbs[count].break_time    = (break_bar < bar_count) ? times[break_bar] : 0;
         count++;
      }
      return count;
   }

   //+------------------------------------------------------------------+
   //| Update Breaker Block status                                      |
   //+------------------------------------------------------------------+
   void UpdateBBStatus(BreakerBlockData &bbs[], int bb_count,
                       const double &highs[], const double &lows[],
                       const double &closes[], int bar_count)
   {
      for(int i = 0; i < bb_count; i++)
      {
         if(!bbs[i].active) continue;
         int start = bbs[i].break_bar + 1;
         if(start >= bar_count) continue;

         for(int k = start; k < bar_count; k++)
         {
            bool touched = (lows[k] <= bbs[i].zone_high && highs[k] >= bbs[i].zone_low);
            if(touched)
            {
               bbs[i].mitigated = true;
               // Breaker invalidated if price closes through it again
               if(bbs[i].direction == OB_BULLISH && closes[k] < bbs[i].zone_low)
               {
                  bbs[i].active = false;
                  break;
               }
               else if(bbs[i].direction == OB_BEARISH && closes[k] > bbs[i].zone_high)
               {
                  bbs[i].active = false;
                  break;
               }
            }
         }
      }
   }

   //+------------------------------------------------------------------+
   //| Check if a POI zone overlaps with any active Order Block         |
   //+------------------------------------------------------------------+
   bool IsNearOB(OrderBlockData &obs[], int ob_count,
                 double zone_low, double zone_high, double tolerance,
                 bool check_bullish)
   {
      for(int i = 0; i < ob_count; i++)
      {
         if(!obs[i].active) continue;
         if(check_bullish && obs[i].direction != OB_BULLISH) continue;
         if(!check_bullish && obs[i].direction != OB_BEARISH) continue;

         // Check overlap with tolerance
         if(obs[i].zone_low - tolerance <= zone_high &&
            zone_low <= obs[i].zone_high + tolerance)
            return true;
      }
      return false;
   }

   //+------------------------------------------------------------------+
   //| Check if a POI zone overlaps with any active Breaker Block       |
   //+------------------------------------------------------------------+
   bool IsNearBB(BreakerBlockData &bbs[], int bb_count,
                 double zone_low, double zone_high, double tolerance,
                 bool check_bullish)
   {
      for(int i = 0; i < bb_count; i++)
      {
         if(!bbs[i].active) continue;
         if(check_bullish && bbs[i].direction != OB_BULLISH) continue;
         if(!check_bullish && bbs[i].direction != OB_BEARISH) continue;

         if(bbs[i].zone_low - tolerance <= zone_high &&
            zone_low <= bbs[i].zone_high + tolerance)
            return true;
      }
      return false;
   }

private:
   double ScoreOB(double impulse_body, double atr, ENUM_TIMEFRAMES tf)
   {
      double impulse_score = MathMin((impulse_body / atr) * 3.0, 6.0);
      double tf_bonus = GetTimeframeWeight(tf) * 0.4;
      return MathMin(impulse_score + tf_bonus, 10.0);
   }
};

#endif
