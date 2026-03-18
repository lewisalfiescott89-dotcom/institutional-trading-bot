//+------------------------------------------------------------------+
//| StructureEngine.mqh - Market structure detection                 |
//| Detects HH, HL, LH, LL, BOS, CHoCH and classifies trend bias   |
//+------------------------------------------------------------------+
#ifndef STRUCTURE_ENGINE_MQH
#define STRUCTURE_ENGINE_MQH

#include "../Core/Utils.mqh"
#include "../Models/Regime.mqh"

//--- Structure event types
enum ENUM_STRUCTURE_EVENT { STRUCT_HH, STRUCT_HL, STRUCT_LH, STRUCT_LL, STRUCT_BOS, STRUCT_CHOCH };

//--- Flip level: old support turned resistance (or vice versa)
struct FlipLevel
{
   double price;
   bool   is_resistance;  // true = former support now resistance
   int    origin_bar;     // bar where the swing point was
   int    break_bar;      // bar where it was broken

   void Init()
   {
      price         = 0;
      is_resistance = false;
      origin_bar    = 0;
      break_bar     = 0;
   }
};

#define MAX_FLIP_LEVELS 100

struct StructurePoint
{
   ENUM_STRUCTURE_EVENT event_type;
   int                  bar_index;
   double               price;
};

struct StructureResult
{
   int              swing_high_indices[];
   int              swing_high_count;
   int              swing_low_indices[];
   int              swing_low_count;
   ENUM_TREND_BIAS  bias;
   StructurePoint   events[100];
   int              event_count;
   int              bos_count;
   int              choch_count;

   void Init()
   {
      swing_high_count = 0;
      swing_low_count  = 0;
      bias             = BIAS_NEUTRAL;
      event_count      = 0;
      bos_count        = 0;
      choch_count      = 0;
   }
};

//+------------------------------------------------------------------+
//| Structure Engine Class                                            |
//+------------------------------------------------------------------+
class CStructureEngine
{
private:
   int m_swing_lookback;

public:
   CStructureEngine(int lookback = 5) : m_swing_lookback(lookback) {}

   void Analyse(const double &opens[], const double &highs[],
                const double &lows[], const double &closes[],
                int bar_count, StructureResult &result)
   {
      result.Init();
      if(bar_count < m_swing_lookback * 2 + 1) return;

      // Detect swing highs and lows
      result.swing_high_count = DetectSwingHighs(highs, bar_count, m_swing_lookback, result.swing_high_indices);
      result.swing_low_count  = DetectSwingLows(lows, bar_count, m_swing_lookback, result.swing_low_indices);

      if(result.swing_high_count < 2 && result.swing_low_count < 2)
      {
         result.bias = BIAS_NEUTRAL;
         return;
      }

      // Classify structure events
      int hh_count = 0, lh_count = 0, hl_count = 0, ll_count = 0;

      // Swing highs: HH or LH
      for(int i = 1; i < result.swing_high_count; i++)
      {
         int idx      = result.swing_high_indices[i];
         int prev_idx = result.swing_high_indices[i-1];
         if(highs[idx] > highs[prev_idx])
         {
            hh_count++;
            AddEvent(result, STRUCT_HH, idx, highs[idx]);
         }
         else
         {
            lh_count++;
            AddEvent(result, STRUCT_LH, idx, highs[idx]);
         }
      }

      // Swing lows: HL or LL
      for(int i = 1; i < result.swing_low_count; i++)
      {
         int idx      = result.swing_low_indices[i];
         int prev_idx = result.swing_low_indices[i-1];
         if(lows[idx] > lows[prev_idx])
         {
            hl_count++;
            AddEvent(result, STRUCT_HL, idx, lows[idx]);
         }
         else
         {
            ll_count++;
            AddEvent(result, STRUCT_LL, idx, lows[idx]);
         }
      }

      // Determine bias
      int bullish_score = hh_count + hl_count;
      int bearish_score = lh_count + ll_count;

      if(bullish_score > bearish_score * 1.5)
         result.bias = BIAS_BULLISH;
      else if(bearish_score > bullish_score * 1.5)
         result.bias = BIAS_BEARISH;
      else
         result.bias = BIAS_NEUTRAL;

      // Detect BOS and CHoCH
      DetectBOSandCHoCH(highs, lows, bar_count, result);
   }

private:
   void AddEvent(StructureResult &result, ENUM_STRUCTURE_EVENT type, int idx, double price)
   {
      if(result.event_count >= 100) return;
      result.events[result.event_count].event_type = type;
      result.events[result.event_count].bar_index  = idx;
      result.events[result.event_count].price      = price;
      result.event_count++;
   }

   void DetectBOSandCHoCH(const double &highs[], const double &lows[],
                           int bar_count, StructureResult &result)
   {
      // BOS: price breaks past a swing point in the direction of trend
      // CHoCH: price breaks past a swing point against the trend
      for(int i = 1; i < result.swing_high_count; i++)
      {
         int sh_idx = result.swing_high_indices[i];
         int prev   = result.swing_high_indices[i-1];
         // Check if any bar between them broke the previous swing high
         for(int k = prev + 1; k <= sh_idx && k < bar_count; k++)
         {
            if(highs[k] > highs[prev])
            {
               if(result.bias == BIAS_BULLISH)
               {
                  AddEvent(result, STRUCT_BOS, k, highs[prev]);
                  result.bos_count++;
               }
               else
               {
                  AddEvent(result, STRUCT_CHOCH, k, highs[prev]);
                  result.choch_count++;
               }
               break;
            }
         }
      }

      for(int i = 1; i < result.swing_low_count; i++)
      {
         int sl_idx = result.swing_low_indices[i];
         int prev   = result.swing_low_indices[i-1];
         for(int k = prev + 1; k <= sl_idx && k < bar_count; k++)
         {
            if(lows[k] < lows[prev])
            {
               if(result.bias == BIAS_BEARISH)
               {
                  AddEvent(result, STRUCT_BOS, k, lows[prev]);
                  result.bos_count++;
               }
               else
               {
                  AddEvent(result, STRUCT_CHOCH, k, lows[prev]);
                  result.choch_count++;
               }
               break;
            }
         }
      }
   }

public:
   //--- Detect flip levels: old support turned resistance (and vice versa)
   //    A swing low that was broken (close below it) is now resistance.
   //    A swing high that was broken (close above it) is now support.
   int DetectFlipLevels(const double &highs[], const double &lows[],
                        const double &closes[], int bar_count,
                        FlipLevel &flips[], int max_flips)
   {
      int count = 0;
      if(bar_count < m_swing_lookback * 2 + 1) return 0;

      // Find swing points
      int sh_indices[];
      int sl_indices[];
      int sh_count = DetectSwingHighs(highs, bar_count, m_swing_lookback, sh_indices);
      int sl_count = DetectSwingLows(lows, bar_count, m_swing_lookback, sl_indices);

      // Check swing lows: if broken (close below), it becomes resistance
      for(int i = 0; i < sl_count && count < max_flips; i++)
      {
         int idx = sl_indices[i];
         double level = lows[idx];
         bool broken = false;
         int break_bar = 0;

         // Look for a bar that closed below this swing low
         for(int k = idx + m_swing_lookback; k < bar_count; k++)
         {
            if(closes[k] < level)
            {
               broken = true;
               break_bar = k;
               break;
            }
         }

         if(broken)
         {
            flips[count].Init();
            flips[count].price         = level;
            flips[count].is_resistance = true;  // Old support = new resistance
            flips[count].origin_bar    = idx;
            flips[count].break_bar     = break_bar;
            count++;
         }
      }

      // Check swing highs: if broken (close above), it becomes support
      for(int i = 0; i < sh_count && count < max_flips; i++)
      {
         int idx = sh_indices[i];
         double level = highs[idx];
         bool broken = false;
         int break_bar = 0;

         // Look for a bar that closed above this swing high
         for(int k = idx + m_swing_lookback; k < bar_count; k++)
         {
            if(closes[k] > level)
            {
               broken = true;
               break_bar = k;
               break;
            }
         }

         if(broken)
         {
            flips[count].Init();
            flips[count].price         = level;
            flips[count].is_resistance = false;  // Old resistance = new support
            flips[count].origin_bar    = idx;
            flips[count].break_bar     = break_bar;
            count++;
         }
      }

      return count;
   }

   //--- Check if a price level is near a flip level
   bool IsNearFlipLevel(const FlipLevel &flips[], int flip_count,
                        double zone_low, double zone_high, double tolerance)
   {
      for(int i = 0; i < flip_count; i++)
      {
         // Flip level price is within or near the zone
         if(flips[i].price >= zone_low - tolerance &&
            flips[i].price <= zone_high + tolerance)
            return true;
      }
      return false;
   }
};

#endif
