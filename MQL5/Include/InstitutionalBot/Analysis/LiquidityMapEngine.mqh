//+------------------------------------------------------------------+
//| LiquidityMapEngine.mqh - Builds and maintains liquidity map      |
//| Detects: swing H/L, equal H/L, session levels, range levels     |
//+------------------------------------------------------------------+
#ifndef LIQUIDITY_MAP_ENGINE_MQH
#define LIQUIDITY_MAP_ENGINE_MQH

#include "../Core/Utils.mqh"
#include "../Models/Liquidity.mqh"
#include "../Config.mqh"

class CLiquidityMapEngine
{
private:
   LiquiditySettings m_cfg;

public:
   CLiquidityMapEngine() { m_cfg.Init(); }
   void SetConfig(const LiquiditySettings &cfg) { m_cfg = cfg; }

   //--- Build complete liquidity map
   int BuildMap(const double &opens[], const double &highs[],
                const double &lows[], const double &closes[],
                const datetime &times[], int bar_count,
                string symbol, ENUM_TIMEFRAMES tf,
                LiquidityLevel &levels[], int max_levels)
   {
      int count = 0;
      if(bar_count < m_cfg.swing_lookback * 2 + 1) return 0;

      // 1. Swing highs/lows
      count = DetectSwingLevels(highs, lows, times, bar_count, symbol, tf, levels, count, max_levels);

      // 2. Equal highs/lows
      count = DetectEqualLevels(highs, lows, times, bar_count, symbol, tf, levels, count, max_levels);

      // 3. Range levels
      count = DetectRangeLevels(highs, lows, times, bar_count, symbol, tf, levels, count, max_levels);

      return count;
   }

   //--- Build map from live symbol data
   int BuildMapFromSymbol(string symbol, ENUM_TIMEFRAMES tf, int bar_count,
                          LiquidityLevel &levels[], int max_levels)
   {
      double opens[], highs[], lows[], closes[];
      long volumes[];
      datetime times[];
      int copied = LoadOHLCV(symbol, tf, bar_count, opens, highs, lows, closes, volumes, times);
      if(copied <= 0) return 0;
      return BuildMap(opens, highs, lows, closes, times, copied, symbol, tf, levels, max_levels);
   }

   //--- Mark levels as swept
   void UpdateSweptStatus(LiquidityLevel &levels[], int count,
                          double current_high, double current_low)
   {
      for(int i = 0; i < count; i++)
      {
         if(!levels[i].active || levels[i].swept) continue;
         if(levels[i].side == LIQ_BUY_SIDE && current_high >= levels[i].price)
            levels[i].MarkSwept();
         else if(levels[i].side == LIQ_SELL_SIDE && current_low <= levels[i].price)
            levels[i].MarkSwept();
      }
   }

private:
   int DetectSwingLevels(const double &highs[], const double &lows[],
                         const datetime &times[], int bar_count,
                         string symbol, ENUM_TIMEFRAMES tf,
                         LiquidityLevel &levels[], int count, int max_levels)
   {
      int sh_indices[];
      int sh_count = DetectSwingHighs(highs, bar_count, m_cfg.swing_lookback, sh_indices);
      for(int i = 0; i < sh_count && count < max_levels; i++)
      {
         int idx = sh_indices[i];
         levels[count].Init();
         levels[count].symbol     = symbol;
         levels[count].price      = highs[idx];
         levels[count].level_type = LIQ_SWING_HIGH;
         levels[count].side       = LIQ_BUY_SIDE;
         levels[count].strength   = 1.0;
         levels[count].timeframe  = tf;
         levels[count].timestamp  = times[idx];
         count++;
      }

      int sl_indices[];
      int sl_count = DetectSwingLows(lows, bar_count, m_cfg.swing_lookback, sl_indices);
      for(int i = 0; i < sl_count && count < max_levels; i++)
      {
         int idx = sl_indices[i];
         levels[count].Init();
         levels[count].symbol     = symbol;
         levels[count].price      = lows[idx];
         levels[count].level_type = LIQ_SWING_LOW;
         levels[count].side       = LIQ_SELL_SIDE;
         levels[count].strength   = 1.0;
         levels[count].timeframe  = tf;
         levels[count].timestamp  = times[idx];
         count++;
      }
      return count;
   }

   int DetectEqualLevels(const double &highs[], const double &lows[],
                         const datetime &times[], int bar_count,
                         string symbol, ENUM_TIMEFRAMES tf,
                         LiquidityLevel &levels[], int count, int max_levels)
   {
      SymbolSpec spec = GetSymbolSpec(symbol);
      double tol = m_cfg.equal_price_tolerance_pips * spec.pip_size;

      // Equal highs from swing highs
      int sh_indices[];
      int sh_count = DetectSwingHighs(highs, bar_count, m_cfg.swing_lookback, sh_indices);
      for(int i = 0; i < sh_count && count < max_levels; i++)
      {
         int matches = 0;
         for(int j = i + 1; j < sh_count; j++)
         {
            if(MathAbs(highs[sh_indices[i]] - highs[sh_indices[j]]) <= tol)
               matches++;
         }
         if(matches >= 1)
         {
            levels[count].Init();
            levels[count].symbol     = symbol;
            levels[count].price      = highs[sh_indices[i]];
            levels[count].level_type = LIQ_EQUAL_HIGHS;
            levels[count].side       = LIQ_BUY_SIDE;
            levels[count].strength   = 1.0 + matches;
            levels[count].timeframe  = tf;
            levels[count].timestamp  = times[sh_indices[i]];
            count++;
         }
      }

      // Equal lows from swing lows
      int sl_indices[];
      int sl_count = DetectSwingLows(lows, bar_count, m_cfg.swing_lookback, sl_indices);
      for(int i = 0; i < sl_count && count < max_levels; i++)
      {
         int matches = 0;
         for(int j = i + 1; j < sl_count; j++)
         {
            if(MathAbs(lows[sl_indices[i]] - lows[sl_indices[j]]) <= tol)
               matches++;
         }
         if(matches >= 1)
         {
            levels[count].Init();
            levels[count].symbol     = symbol;
            levels[count].price      = lows[sl_indices[i]];
            levels[count].level_type = LIQ_EQUAL_LOWS;
            levels[count].side       = LIQ_SELL_SIDE;
            levels[count].strength   = 1.0 + matches;
            levels[count].timeframe  = tf;
            levels[count].timestamp  = times[sl_indices[i]];
            count++;
         }
      }
      return count;
   }

   int DetectRangeLevels(const double &highs[], const double &lows[],
                         const datetime &times[], int bar_count,
                         string symbol, ENUM_TIMEFRAMES tf,
                         LiquidityLevel &levels[], int count, int max_levels)
   {
      if(count >= max_levels - 2) return count;
      int lookback = MathMin(100, bar_count);
      int start = bar_count - lookback;
      if(start < 0) start = 0;

      double range_high = -DBL_MAX, range_low = DBL_MAX;
      int rh_idx = start, rl_idx = start;
      for(int i = start; i < bar_count; i++)
      {
         if(highs[i] > range_high) { range_high = highs[i]; rh_idx = i; }
         if(lows[i] < range_low)   { range_low = lows[i]; rl_idx = i; }
      }

      levels[count].Init();
      levels[count].symbol     = symbol;
      levels[count].price      = range_high;
      levels[count].level_type = LIQ_RANGE_HIGH;
      levels[count].side       = LIQ_BUY_SIDE;
      levels[count].strength   = 2.0;
      levels[count].timeframe  = tf;
      levels[count].timestamp  = times[rh_idx];
      count++;

      levels[count].Init();
      levels[count].symbol     = symbol;
      levels[count].price      = range_low;
      levels[count].level_type = LIQ_RANGE_LOW;
      levels[count].side       = LIQ_SELL_SIDE;
      levels[count].strength   = 2.0;
      levels[count].timeframe  = tf;
      levels[count].timestamp  = times[rl_idx];
      count++;

      return count;
   }
};

#endif
