//+------------------------------------------------------------------+
//| ReversalEngine.mqh - Reversal candle confirmation                |
//| Detects engulfing, pin bar, displacement, reclaim patterns       |
//+------------------------------------------------------------------+
#ifndef REVERSAL_ENGINE_MQH
#define REVERSAL_ENGINE_MQH

#include "../Core/Utils.mqh"
#include "../Config.mqh"

enum ENUM_REVERSAL_TYPE
{
   REV_BULLISH_ENGULFING,
   REV_BEARISH_ENGULFING,
   REV_BULLISH_PIN_BAR,
   REV_BEARISH_PIN_BAR,
   REV_BULLISH_DISPLACEMENT,
   REV_BEARISH_DISPLACEMENT,
   REV_BULLISH_RECLAIM,
   REV_BEARISH_RECLAIM,
   REV_BULLISH_DOUBLE_BOTTOM,
   REV_BEARISH_DOUBLE_TOP,
   REV_NONE
};

struct ReversalData
{
   ENUM_REVERSAL_TYPE type;
   double             quality;      // 0.0 to 10.0
   int                bar_index;
   datetime           timestamp;
   double             entry_price;  // Close of reversal candle
   bool               valid;

   void Init()
   {
      type        = REV_NONE;
      quality     = 0;
      bar_index   = 0;
      timestamp   = 0;
      entry_price = 0;
      valid       = false;
   }
};

class CReversalEngine
{
private:
   ReversalSettings m_cfg;

public:
   CReversalEngine() { m_cfg.Init(); }
   void SetConfig(const ReversalSettings &cfg) { m_cfg = cfg; }

   //--- Check for reversal candle at bar index
   void DetectAt(const double &opens[], const double &highs[],
                 const double &lows[], const double &closes[],
                 const datetime &times[], int bar_count,
                 int bar_idx, bool look_for_bullish,
                 ReversalData &result)
   {
      result.Init();
      if(bar_idx < 1 || bar_idx >= bar_count) return;

      double o = opens[bar_idx], h = highs[bar_idx], l = lows[bar_idx], c = closes[bar_idx];
      double po = opens[bar_idx-1], ph = highs[bar_idx-1], pl = lows[bar_idx-1], pc = closes[bar_idx-1];
      double body = CandleBody(o, c);
      double range = CandleRange(h, l);
      double prev_body = CandleBody(po, pc);

      if(range == 0) return;

      if(look_for_bullish)
      {
         // Bullish engulfing
         if(IsBullish(o, c) && IsBearish(po, pc) && body > prev_body * m_cfg.engulfing_ratio)
         {
            result.type    = REV_BULLISH_ENGULFING;
            result.quality = ScoreEngulfing(body, prev_body, range);
         }
         // Bullish pin bar (hammer): small body, long lower wick
         else if(IsBullish(o, c) || CandleBody(o, c) < range * 0.3)
         {
            double lower_wick = CandleLowerWick(o, c, l);
            double upper_wick = CandleUpperWick(o, c, h);
            if(lower_wick >= range * m_cfg.pin_bar_wick_ratio && lower_wick > upper_wick * 2)
            {
               result.type    = REV_BULLISH_PIN_BAR;
               result.quality = ScorePinBar(lower_wick, range, body);
            }
         }

         // Bullish displacement
         if(result.type == REV_NONE && IsBullish(o, c))
         {
            double body_ratio = body / range;
            if(body_ratio >= m_cfg.displacement_body_ratio && body >= prev_body * 1.5)
            {
               result.type    = REV_BULLISH_DISPLACEMENT;
               result.quality = body_ratio * 8.0;
            }
         }

         // Bullish reclaim (close back above a level - checked externally)
         if(result.type == REV_NONE && IsBullish(o, c) && IsBearish(po, pc))
         {
            if(c > ph && body > range * 0.4)
            {
               result.type    = REV_BULLISH_RECLAIM;
               result.quality = 5.0;
            }
         }
      }
      else // Look for bearish
      {
         // Bearish engulfing
         if(IsBearish(o, c) && IsBullish(po, pc) && body > prev_body * m_cfg.engulfing_ratio)
         {
            result.type    = REV_BEARISH_ENGULFING;
            result.quality = ScoreEngulfing(body, prev_body, range);
         }
         // Bearish pin bar (shooting star): small body, long upper wick
         else if(IsBearish(o, c) || CandleBody(o, c) < range * 0.3)
         {
            double upper_wick = CandleUpperWick(o, c, h);
            double lower_wick = CandleLowerWick(o, c, l);
            if(upper_wick >= range * m_cfg.pin_bar_wick_ratio && upper_wick > lower_wick * 2)
            {
               result.type    = REV_BEARISH_PIN_BAR;
               result.quality = ScorePinBar(upper_wick, range, body);
            }
         }

         // Bearish displacement
         if(result.type == REV_NONE && IsBearish(o, c))
         {
            double body_ratio = body / range;
            if(body_ratio >= m_cfg.displacement_body_ratio && body >= prev_body * 1.5)
            {
               result.type    = REV_BEARISH_DISPLACEMENT;
               result.quality = body_ratio * 8.0;
            }
         }

         // Bearish reclaim
         if(result.type == REV_NONE && IsBearish(o, c) && IsBullish(po, pc))
         {
            if(c < pl && body > range * 0.4)
            {
               result.type    = REV_BEARISH_RECLAIM;
               result.quality = 5.0;
            }
         }
      }

      if(result.type != REV_NONE)
      {
         result.bar_index   = bar_idx;
         result.timestamp   = times[bar_idx];
         result.entry_price = closes[bar_idx];
         result.valid       = result.quality >= m_cfg.min_reversal_quality;
         result.quality     = MathMin(result.quality, 10.0);
      }
   }

   string ReversalTypeToString(ENUM_REVERSAL_TYPE type)
   {
      switch(type)
      {
         case REV_BULLISH_ENGULFING:     return "BullEngulf";
         case REV_BEARISH_ENGULFING:     return "BearEngulf";
         case REV_BULLISH_PIN_BAR:       return "BullPin";
         case REV_BEARISH_PIN_BAR:       return "BearPin";
         case REV_BULLISH_DISPLACEMENT:  return "BullDisp";
         case REV_BEARISH_DISPLACEMENT:  return "BearDisp";
         case REV_BULLISH_RECLAIM:       return "BullReclaim";
         case REV_BEARISH_RECLAIM:       return "BearReclaim";
         case REV_BULLISH_DOUBLE_BOTTOM:  return "BullDblBot";
         case REV_BEARISH_DOUBLE_TOP:     return "BearDblTop";
         default:                        return "None";
      }
   }

   //--- Detect double top/bottom pattern at a zone
   //    ICT: price tests the same level twice, fails both times = strong reversal
   //    look_for_bullish=true: detect double bottom (two lows at similar level)
   //    look_for_bullish=false: detect double top (two highs at similar level)
   bool DetectDoubleTopBottom(const double &highs[], const double &lows[],
                              const double &closes[], const datetime &times[],
                              int bar_count, bool look_for_bullish,
                              double zone_low, double zone_high,
                              int lookback, ReversalData &result)
   {
      result.Init();
      if(bar_count < lookback + 2) return false;

      int end_bar   = bar_count - 2;  // Last completed bar
      int start_bar = end_bar - lookback;
      if(start_bar < 1) start_bar = 1;

      double tolerance = (zone_high - zone_low) * 0.5;  // Half zone width as tolerance
      if(tolerance < 0.01) tolerance = 0.01;

      if(!look_for_bullish)  // Bearish double top
      {
         // Find two highs that touch/enter the zone within tolerance
         int first_touch_bar = -1;
         double first_touch_high = 0;

         for(int i = start_bar; i <= end_bar; i++)
         {
            // High is at or near the zone top
            if(highs[i] >= zone_low && highs[i] <= zone_high + tolerance)
            {
               if(first_touch_bar < 0)
               {
                  first_touch_bar = i;
                  first_touch_high = highs[i];
               }
               else if(i - first_touch_bar >= 3)  // At least 3 bars apart
               {
                  // Second touch found — check both rejected (closed below zone)
                  if(closes[first_touch_bar] < zone_high &&
                     closes[i] < zone_high &&
                     MathAbs(highs[i] - first_touch_high) <= tolerance)
                  {
                     result.type        = REV_BEARISH_DOUBLE_TOP;
                     result.quality     = 8.0;  // High quality pattern
                     result.bar_index   = i;
                     result.timestamp   = times[i];
                     result.entry_price = closes[i];
                     result.valid       = true;
                     return true;
                  }
               }
            }
         }
      }
      else  // Bullish double bottom
      {
         int first_touch_bar = -1;
         double first_touch_low = 0;

         for(int i = start_bar; i <= end_bar; i++)
         {
            if(lows[i] <= zone_high && lows[i] >= zone_low - tolerance)
            {
               if(first_touch_bar < 0)
               {
                  first_touch_bar = i;
                  first_touch_low = lows[i];
               }
               else if(i - first_touch_bar >= 3)
               {
                  if(closes[first_touch_bar] > zone_low &&
                     closes[i] > zone_low &&
                     MathAbs(lows[i] - first_touch_low) <= tolerance)
                  {
                     result.type        = REV_BULLISH_DOUBLE_BOTTOM;
                     result.quality     = 8.0;
                     result.bar_index   = i;
                     result.timestamp   = times[i];
                     result.entry_price = closes[i];
                     result.valid       = true;
                     return true;
                  }
               }
            }
         }
      }
      return false;
   }

   //--- Detect Market Structure Shift (MSS) on M5 timeframe
   //    ICT methodology: after price sweeps into a POI zone, look for a
   //    break of recent structure in the opposite direction.
   //    Bullish MSS: price drops into zone (makes low), then closes above
   //                 the most recent swing high before that low.
   //    Bearish MSS: price rises into zone (makes high), then closes below
   //                 the most recent swing low before that high.
   bool DetectMSS(const double &highs[], const double &lows[],
                  const double &closes[], int bar_count,
                  bool look_for_bullish, int lookback = 10)
   {
      if(bar_count < lookback + 3) return false;

      int end_bar   = bar_count - 2;  // Last completed bar
      int start_bar = end_bar - lookback;
      if(start_bar < 1) start_bar = 1;

      if(look_for_bullish)
      {
         // Step 1: Find the lowest low in lookback (the manipulation/sweep into demand zone)
         int low_bar = start_bar;
         for(int i = start_bar + 1; i <= end_bar; i++)
            if(lows[i] < lows[low_bar]) low_bar = i;

         // Need bars before the low for structure, and at least 1 bar after for the shift
         if(low_bar <= start_bar + 1 || low_bar >= end_bar) return false;

         // Step 2: Find the highest high BEFORE the low bar (the structure to break)
         double structure_high = highs[start_bar];
         for(int i = start_bar + 1; i < low_bar; i++)
            if(highs[i] > structure_high) structure_high = highs[i];

         // Structure high must be meaningfully above the low
         if(structure_high <= lows[low_bar]) return false;

         // Step 3: Check if any bar AFTER the low closed above the structure high
         for(int i = low_bar + 1; i <= end_bar; i++)
            if(closes[i] > structure_high) return true;
      }
      else  // Bearish MSS
      {
         // Step 1: Find the highest high in lookback (the manipulation/sweep into supply zone)
         int high_bar = start_bar;
         for(int i = start_bar + 1; i <= end_bar; i++)
            if(highs[i] > highs[high_bar]) high_bar = i;

         if(high_bar <= start_bar + 1 || high_bar >= end_bar) return false;

         // Step 2: Find the lowest low BEFORE the high bar
         double structure_low = lows[start_bar];
         for(int i = start_bar + 1; i < high_bar; i++)
            if(lows[i] < structure_low) structure_low = lows[i];

         if(structure_low >= highs[high_bar]) return false;

         // Step 3: Check if any bar AFTER the high closed below the structure low
         for(int i = high_bar + 1; i <= end_bar; i++)
            if(closes[i] < structure_low) return true;
      }
      return false;
   }

private:
   double ScoreEngulfing(double body, double prev_body, double range)
   {
      double ratio = (prev_body > 0) ? body / prev_body : 1.0;
      double body_pct = body / range;
      return MathMin(ratio * 2.0 + body_pct * 5.0, 10.0);
   }

   double ScorePinBar(double wick, double range, double body)
   {
      double wick_ratio = wick / range;
      double body_ratio = (range > 0) ? body / range : 0;
      return MathMin(wick_ratio * 6.0 + (1.0 - body_ratio) * 4.0, 10.0);
   }
};

#endif
