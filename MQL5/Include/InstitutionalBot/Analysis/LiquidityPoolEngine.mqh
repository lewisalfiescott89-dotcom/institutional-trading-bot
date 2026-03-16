//+------------------------------------------------------------------+
//| LiquidityPoolEngine.mqh - Comprehensive ICT liquidity detection  |
//| Detects: BSL/SSL, equal H/L, external/internal liquidity,       |
//| trendline liq, liquidity voids, vacuum blocks, stop runs,       |
//| OB/BB liquidity, resting liquidity, range liquidity              |
//+------------------------------------------------------------------+
#ifndef LIQUIDITY_POOL_ENGINE_MQH
#define LIQUIDITY_POOL_ENGINE_MQH

#include "../Core/Utils.mqh"
#include "../Models/LiquidityPool.mqh"
#include "../Models/OrderBlock.mqh"
#include "../Config.mqh"

class CLiquidityPoolEngine
{
private:
   int    m_next_pool_id;
   int    m_next_vacuum_id;
   int    m_next_stoprun_id;
   int    m_swing_lookback;
   double m_equal_tolerance_pips;
   double m_trendline_tolerance_pips;
   double m_void_min_atr_mult;       // Min candle size for liquidity void (ATR multiple)

public:
   CLiquidityPoolEngine() : m_next_pool_id(1), m_next_vacuum_id(1), m_next_stoprun_id(1),
                             m_swing_lookback(5), m_equal_tolerance_pips(3.0),
                             m_trendline_tolerance_pips(5.0), m_void_min_atr_mult(2.0) {}

   void SetSwingLookback(int val)          { m_swing_lookback = val; }
   void SetEqualTolerancePips(double val)  { m_equal_tolerance_pips = val; }
   void SetVoidMinATRMult(double val)      { m_void_min_atr_mult = val; }

   //+------------------------------------------------------------------+
   //| Build complete liquidity pool map                                 |
   //| Detects all ICT liquidity types from price data                  |
   //+------------------------------------------------------------------+
   int BuildPools(const double &opens[], const double &highs[],
                  const double &lows[], const double &closes[],
                  const datetime &times[], int bar_count,
                  string symbol, ENUM_TIMEFRAMES tf,
                  LiquidityPoolData &pools[], int max_pools)
   {
      int count = 0;
      if(bar_count < m_swing_lookback * 2 + 1) return 0;

      SymbolSpec spec = GetSymbolSpec(symbol);

      // 1. BSL/SSL (Buy-Side / Sell-Side Liquidity)
      count = DetectBSL_SSL(highs, lows, times, bar_count, symbol, tf, spec, pools, count, max_pools);

      // 2. Equal Highs / Equal Lows
      count = DetectEqualHiLo(highs, lows, times, bar_count, symbol, tf, spec, pools, count, max_pools);

      // 3. External Liquidity (above/below current range)
      count = DetectExternalLiquidity(highs, lows, times, bar_count, symbol, tf, pools, count, max_pools);

      // 4. Internal Liquidity (within current range)
      count = DetectInternalLiquidity(highs, lows, closes, times, bar_count, symbol, tf, pools, count, max_pools);

      // 5. Range Liquidity (range high/low boundaries)
      count = DetectRangeLiquidity(highs, lows, times, bar_count, symbol, tf, pools, count, max_pools);

      // 6. Trendline Liquidity
      count = DetectTrendlineLiquidity(highs, lows, times, bar_count, symbol, tf, spec, pools, count, max_pools);

      // 7. Resting Liquidity (key round numbers and session levels)
      count = DetectRestingLiquidity(highs, lows, closes, times, bar_count, symbol, tf, spec, pools, count, max_pools);

      return count;
   }

   //+------------------------------------------------------------------+
   //| Detect Liquidity Voids (large impulse candles with no opposing)  |
   //| Similar to FVG but focuses on the candle body itself             |
   //+------------------------------------------------------------------+
   int DetectVoids(const double &opens[], const double &highs[],
                   const double &lows[], const double &closes[],
                   const datetime &times[], int bar_count,
                   string symbol, ENUM_TIMEFRAMES tf,
                   VacuumBlockData &voids_out[], int max_voids)
   {
      int count = 0;
      if(bar_count < 20) return 0;

      double atr_arr[];
      ComputeATRArray(highs, lows, closes, 14, bar_count, atr_arr);

      for(int i = 15; i < bar_count && count < max_voids; i++)
      {
         if(atr_arr[i] <= 0) continue;
         double range = CandleRange(highs[i], lows[i]);
         double body  = CandleBody(opens[i], closes[i]);

         // Large impulse candle with strong body
         if(range < atr_arr[i] * m_void_min_atr_mult) continue;
         if(range == 0 || body / range < 0.6) continue;

         // Check that neighboring candles don't overlap much (true void)
         bool is_void = false;
         if(i > 0 && i < bar_count - 1)
         {
            if(IsBullish(opens[i], closes[i]))
            {
               // Bullish void: gap between prev high and current low area
               if(lows[i] > highs[i-1])
                  is_void = true;
            }
            else
            {
               // Bearish void: gap between current high area and prev low
               if(highs[i] < lows[i-1])
                  is_void = true;
            }
         }

         // Even without perfect gap, a massive candle is a liquidity void
         if(!is_void && range >= atr_arr[i] * 3.0)
            is_void = true;

         if(is_void)
         {
            voids_out[count].Init();
            voids_out[count].id           = m_next_vacuum_id++;
            voids_out[count].symbol       = symbol;
            voids_out[count].timeframe    = tf;
            voids_out[count].is_bullish   = IsBullish(opens[i], closes[i]);
            voids_out[count].impulse_size = range;
            voids_out[count].bar_index    = i;
            voids_out[count].timestamp    = times[i];

            if(voids_out[count].is_bullish)
            {
               voids_out[count].zone_low  = lows[i];
               voids_out[count].zone_high = opens[i]; // Body low area
            }
            else
            {
               voids_out[count].zone_low  = opens[i]; // Body high area
               voids_out[count].zone_high = highs[i];
            }
            count++;
         }
      }

      // Update fill status
      for(int v = 0; v < count; v++)
      {
         int start = voids_out[v].bar_index + 1;
         for(int k = start; k < bar_count; k++)
         {
            if(voids_out[v].is_bullish && lows[k] <= voids_out[v].zone_low)
            {
               voids_out[v].filled = true;
               break;
            }
            else if(!voids_out[v].is_bullish && highs[k] >= voids_out[v].zone_high)
            {
               voids_out[v].filled = true;
               break;
            }
         }
      }

      return count;
   }

   //+------------------------------------------------------------------+
   //| Detect Stop Runs (price swept a level then reversed)             |
   //+------------------------------------------------------------------+
   int DetectStopRuns(const double &opens[], const double &highs[],
                      const double &lows[], const double &closes[],
                      const datetime &times[], int bar_count,
                      LiquidityPoolData &pools[], int pool_count,
                      string symbol, StopRunData &runs[], int max_runs)
   {
      int count = 0;
      if(bar_count < 5 || pool_count == 0) return 0;

      SymbolSpec spec = GetSymbolSpec(symbol);
      double min_pen = 1.0 * spec.pip_size;

      // Check last 30 bars for stop runs
      int lookback = MathMin(30, bar_count - 1);
      int start = bar_count - lookback;
      if(start < 1) start = 1;

      for(int i = start; i < bar_count && count < max_runs; i++)
      {
         for(int p = 0; p < pool_count && count < max_runs; p++)
         {
            if(!pools[p].active || pools[p].swept) continue;

            // Buy-side stop run: price goes above level then reverses down
            if(pools[p].side == POOL_BUY_SIDE)
            {
               if(highs[i] > pools[p].price + min_pen && closes[i] < pools[p].price)
               {
                  double pen = highs[i] - pools[p].price;
                  double rev = pools[p].price - closes[i];

                  runs[count].Init();
                  runs[count].id            = m_next_stoprun_id++;
                  runs[count].symbol        = symbol;
                  runs[count].swept_level   = pools[p].price;
                  runs[count].penetration   = pen;
                  runs[count].reversal_size = rev;
                  runs[count].is_buy_side   = true;
                  runs[count].sweep_bar     = i;
                  runs[count].timestamp     = times[i];
                  runs[count].quality       = ScoreStopRun(pen, rev, spec);
                  count++;
               }
            }
            // Sell-side stop run: price goes below level then reverses up
            else if(pools[p].side == POOL_SELL_SIDE)
            {
               if(lows[i] < pools[p].price - min_pen && closes[i] > pools[p].price)
               {
                  double pen = pools[p].price - lows[i];
                  double rev = closes[i] - pools[p].price;

                  runs[count].Init();
                  runs[count].id            = m_next_stoprun_id++;
                  runs[count].symbol        = symbol;
                  runs[count].swept_level   = pools[p].price;
                  runs[count].penetration   = pen;
                  runs[count].reversal_size = rev;
                  runs[count].is_buy_side   = false;
                  runs[count].sweep_bar     = i;
                  runs[count].timestamp     = times[i];
                  runs[count].quality       = ScoreStopRun(pen, rev, spec);
                  count++;
               }
            }
         }
      }
      return count;
   }

   //+------------------------------------------------------------------+
   //| Add OB/BB liquidity pools                                        |
   //| Liquidity rests at order block and breaker block zones           |
   //+------------------------------------------------------------------+
   int AddOBLiquidity(OrderBlockData &obs[], int ob_count,
                      string symbol, ENUM_TIMEFRAMES tf,
                      LiquidityPoolData &pools[], int count, int max_pools)
   {
      for(int i = 0; i < ob_count && count < max_pools; i++)
      {
         if(!obs[i].active) continue;

         pools[count].Init();
         pools[count].id        = m_next_pool_id++;
         pools[count].symbol    = symbol;
         pools[count].pool_type = LPOOL_OB_LIQUIDITY;
         pools[count].side      = (obs[i].direction == OB_BULLISH) ? POOL_SELL_SIDE : POOL_BUY_SIDE;
         pools[count].price     = obs[i].MidPrice();
         pools[count].zone_high = obs[i].zone_high;
         pools[count].zone_low  = obs[i].zone_low;
         pools[count].strength  = obs[i].quality * 0.3;
         pools[count].timeframe = tf;
         pools[count].timestamp = obs[i].origin_time;
         pools[count].bar_index = obs[i].origin_bar;
         count++;
      }
      return count;
   }

   int AddBBLiquidity(BreakerBlockData &bbs[], int bb_count,
                      string symbol, ENUM_TIMEFRAMES tf,
                      LiquidityPoolData &pools[], int count, int max_pools)
   {
      for(int i = 0; i < bb_count && count < max_pools; i++)
      {
         if(!bbs[i].active) continue;

         pools[count].Init();
         pools[count].id        = m_next_pool_id++;
         pools[count].symbol    = symbol;
         pools[count].pool_type = LPOOL_BB_LIQUIDITY;
         pools[count].side      = (bbs[i].direction == OB_BULLISH) ? POOL_SELL_SIDE : POOL_BUY_SIDE;
         pools[count].price     = bbs[i].MidPrice();
         pools[count].zone_high = bbs[i].zone_high;
         pools[count].zone_low  = bbs[i].zone_low;
         pools[count].strength  = bbs[i].quality * 0.3;
         pools[count].timeframe = tf;
         pools[count].timestamp = bbs[i].break_time;
         pools[count].bar_index = bbs[i].break_bar;
         count++;
      }
      return count;
   }

   //+------------------------------------------------------------------+
   //| Update swept status of all pools                                 |
   //+------------------------------------------------------------------+
   void UpdateSweptStatus(LiquidityPoolData &pools[], int count,
                          double current_high, double current_low)
   {
      for(int i = 0; i < count; i++)
      {
         if(!pools[i].active || pools[i].swept) continue;
         if(pools[i].side == POOL_BUY_SIDE && current_high >= pools[i].price)
            pools[i].MarkSwept();
         else if(pools[i].side == POOL_SELL_SIDE && current_low <= pools[i].price)
            pools[i].MarkSwept();
      }
   }

   //+------------------------------------------------------------------+
   //| Check if a zone has nearby liquidity pools                       |
   //+------------------------------------------------------------------+
   int CountNearbyPools(LiquidityPoolData &pools[], int pool_count,
                        double zone_low, double zone_high, double tolerance)
   {
      int nearby = 0;
      for(int i = 0; i < pool_count; i++)
      {
         if(!pools[i].active || pools[i].swept) continue;
         if(pools[i].price >= zone_low - tolerance &&
            pools[i].price <= zone_high + tolerance)
            nearby++;
      }
      return nearby;
   }

private:
   //+------------------------------------------------------------------+
   //| BSL/SSL: Buy-Side and Sell-Side Liquidity                        |
   //| Stops resting above swing highs (BSL) and below swing lows (SSL)|
   //+------------------------------------------------------------------+
   int DetectBSL_SSL(const double &highs[], const double &lows[],
                     const datetime &times[], int bar_count,
                     string symbol, ENUM_TIMEFRAMES tf, SymbolSpec &spec,
                     LiquidityPoolData &pools[], int count, int max_pools)
   {
      int sh_indices[];
      int sh_count = DetectSwingHighs(highs, bar_count, m_swing_lookback, sh_indices);
      for(int i = 0; i < sh_count && count < max_pools; i++)
      {
         int idx = sh_indices[i];
         pools[count].Init();
         pools[count].id        = m_next_pool_id++;
         pools[count].symbol    = symbol;
         pools[count].pool_type = LPOOL_BSL;
         pools[count].side      = POOL_BUY_SIDE;
         pools[count].price     = highs[idx];
         pools[count].zone_high = highs[idx] + 2.0 * spec.pip_size;
         pools[count].zone_low  = highs[idx] - 2.0 * spec.pip_size;
         pools[count].strength  = 1.5;
         pools[count].timeframe = tf;
         pools[count].timestamp = times[idx];
         pools[count].bar_index = idx;
         count++;
      }

      int sl_indices[];
      int sl_count = DetectSwingLows(lows, bar_count, m_swing_lookback, sl_indices);
      for(int i = 0; i < sl_count && count < max_pools; i++)
      {
         int idx = sl_indices[i];
         pools[count].Init();
         pools[count].id        = m_next_pool_id++;
         pools[count].symbol    = symbol;
         pools[count].pool_type = LPOOL_SSL;
         pools[count].side      = POOL_SELL_SIDE;
         pools[count].price     = lows[idx];
         pools[count].zone_high = lows[idx] + 2.0 * spec.pip_size;
         pools[count].zone_low  = lows[idx] - 2.0 * spec.pip_size;
         pools[count].strength  = 1.5;
         pools[count].timeframe = tf;
         pools[count].timestamp = times[idx];
         pools[count].bar_index = idx;
         count++;
      }
      return count;
   }

   //+------------------------------------------------------------------+
   //| Equal Highs / Equal Lows                                         |
   //| Double/triple tops/bottoms where stops accumulate                |
   //+------------------------------------------------------------------+
   int DetectEqualHiLo(const double &highs[], const double &lows[],
                       const datetime &times[], int bar_count,
                       string symbol, ENUM_TIMEFRAMES tf, SymbolSpec &spec,
                       LiquidityPoolData &pools[], int count, int max_pools)
   {
      double tol = m_equal_tolerance_pips * spec.pip_size;

      // Equal highs
      int sh_indices[];
      int sh_count = DetectSwingHighs(highs, bar_count, m_swing_lookback, sh_indices);
      for(int i = 0; i < sh_count && count < max_pools; i++)
      {
         int matches = 0;
         for(int j = i + 1; j < sh_count; j++)
         {
            if(MathAbs(highs[sh_indices[i]] - highs[sh_indices[j]]) <= tol)
               matches++;
         }
         if(matches >= 1)
         {
            pools[count].Init();
            pools[count].id          = m_next_pool_id++;
            pools[count].symbol      = symbol;
            pools[count].pool_type   = LPOOL_EQUAL_HIGHS;
            pools[count].side        = POOL_BUY_SIDE;
            pools[count].price       = highs[sh_indices[i]];
            pools[count].zone_high   = highs[sh_indices[i]] + tol;
            pools[count].zone_low    = highs[sh_indices[i]] - tol;
            pools[count].strength    = 1.0 + matches * 1.5;  // Stronger with more touches
            pools[count].timeframe   = tf;
            pools[count].timestamp   = times[sh_indices[i]];
            pools[count].bar_index   = sh_indices[i];
            pools[count].touch_count = matches + 1;
            count++;
         }
      }

      // Equal lows
      int sl_indices[];
      int sl_count = DetectSwingLows(lows, bar_count, m_swing_lookback, sl_indices);
      for(int i = 0; i < sl_count && count < max_pools; i++)
      {
         int matches = 0;
         for(int j = i + 1; j < sl_count; j++)
         {
            if(MathAbs(lows[sl_indices[i]] - lows[sl_indices[j]]) <= tol)
               matches++;
         }
         if(matches >= 1)
         {
            pools[count].Init();
            pools[count].id          = m_next_pool_id++;
            pools[count].symbol      = symbol;
            pools[count].pool_type   = LPOOL_EQUAL_LOWS;
            pools[count].side        = POOL_SELL_SIDE;
            pools[count].price       = lows[sl_indices[i]];
            pools[count].zone_high   = lows[sl_indices[i]] + tol;
            pools[count].zone_low    = lows[sl_indices[i]] - tol;
            pools[count].strength    = 1.0 + matches * 1.5;
            pools[count].timeframe   = tf;
            pools[count].timestamp   = times[sl_indices[i]];
            pools[count].bar_index   = sl_indices[i];
            pools[count].touch_count = matches + 1;
            count++;
         }
      }
      return count;
   }

   //+------------------------------------------------------------------+
   //| External Liquidity (above range high / below range low)          |
   //| Liquidity outside the current dealing range                      |
   //+------------------------------------------------------------------+
   int DetectExternalLiquidity(const double &highs[], const double &lows[],
                               const datetime &times[], int bar_count,
                               string symbol, ENUM_TIMEFRAMES tf,
                               LiquidityPoolData &pools[], int count, int max_pools)
   {
      if(count >= max_pools - 2) return count;

      int lookback = MathMin(200, bar_count);
      int start = bar_count - lookback;
      if(start < 0) start = 0;

      double range_high = -DBL_MAX;
      double range_low = DBL_MAX;
      int rh_idx = start, rl_idx = start;

      for(int i = start; i < bar_count; i++)
      {
         if(highs[i] > range_high) { range_high = highs[i]; rh_idx = i; }
         if(lows[i] < range_low)   { range_low = lows[i]; rl_idx = i; }
      }

      // External high liquidity (above range)
      pools[count].Init();
      pools[count].id        = m_next_pool_id++;
      pools[count].symbol    = symbol;
      pools[count].pool_type = LPOOL_EXTERNAL_HIGH;
      pools[count].side      = POOL_BUY_SIDE;
      pools[count].price     = range_high;
      pools[count].zone_high = range_high;
      pools[count].zone_low  = range_high;
      pools[count].strength  = 3.0;  // External liquidity is high-value target
      pools[count].timeframe = tf;
      pools[count].timestamp = times[rh_idx];
      pools[count].bar_index = rh_idx;
      count++;

      // External low liquidity (below range)
      pools[count].Init();
      pools[count].id        = m_next_pool_id++;
      pools[count].symbol    = symbol;
      pools[count].pool_type = LPOOL_EXTERNAL_LOW;
      pools[count].side      = POOL_SELL_SIDE;
      pools[count].price     = range_low;
      pools[count].zone_high = range_low;
      pools[count].zone_low  = range_low;
      pools[count].strength  = 3.0;
      pools[count].timeframe = tf;
      pools[count].timestamp = times[rl_idx];
      pools[count].bar_index = rl_idx;
      count++;

      return count;
   }

   //+------------------------------------------------------------------+
   //| Internal Liquidity (FVGs, voids within the range)                |
   //| Price imbalances inside the current dealing range                |
   //+------------------------------------------------------------------+
   int DetectInternalLiquidity(const double &highs[], const double &lows[],
                               const double &closes[], const datetime &times[],
                               int bar_count, string symbol, ENUM_TIMEFRAMES tf,
                               LiquidityPoolData &pools[], int count, int max_pools)
   {
      // Internal liquidity = significant swing points within the range
      // that haven't been swept yet (potential targets)
      int lookback = MathMin(100, bar_count);
      int start = bar_count - lookback;
      if(start < 0) start = 0;

      // Find range boundaries
      double range_high = -DBL_MAX;
      double range_low = DBL_MAX;
      for(int i = start; i < bar_count; i++)
      {
         if(highs[i] > range_high) range_high = highs[i];
         if(lows[i] < range_low) range_low = lows[i];
      }

      double range_mid = (range_high + range_low) / 2.0;
      double range_25  = range_low + (range_high - range_low) * 0.25;
      double range_75  = range_low + (range_high - range_low) * 0.75;

      // Internal swing highs in lower half = internal BSL
      int sh_indices[];
      int sh_count = DetectSwingHighs(highs, bar_count, m_swing_lookback, sh_indices);
      for(int i = 0; i < sh_count && count < max_pools; i++)
      {
         int idx = sh_indices[i];
         if(idx < start) continue;
         // Only internal: between 25% and 75% of range
         if(highs[idx] > range_25 && highs[idx] < range_75)
         {
            pools[count].Init();
            pools[count].id        = m_next_pool_id++;
            pools[count].symbol    = symbol;
            pools[count].pool_type = LPOOL_INTERNAL;
            pools[count].side      = POOL_BUY_SIDE;
            pools[count].price     = highs[idx];
            pools[count].zone_high = highs[idx];
            pools[count].zone_low  = highs[idx];
            pools[count].strength  = 1.0;
            pools[count].timeframe = tf;
            pools[count].timestamp = times[idx];
            pools[count].bar_index = idx;
            count++;
         }
      }

      // Internal swing lows in upper half = internal SSL
      int sl_indices[];
      int sl_count = DetectSwingLows(lows, bar_count, m_swing_lookback, sl_indices);
      for(int i = 0; i < sl_count && count < max_pools; i++)
      {
         int idx = sl_indices[i];
         if(idx < start) continue;
         if(lows[idx] > range_25 && lows[idx] < range_75)
         {
            pools[count].Init();
            pools[count].id        = m_next_pool_id++;
            pools[count].symbol    = symbol;
            pools[count].pool_type = LPOOL_INTERNAL;
            pools[count].side      = POOL_SELL_SIDE;
            pools[count].price     = lows[idx];
            pools[count].zone_high = lows[idx];
            pools[count].zone_low  = lows[idx];
            pools[count].strength  = 1.0;
            pools[count].timeframe = tf;
            pools[count].timestamp = times[idx];
            pools[count].bar_index = idx;
            count++;
         }
      }
      return count;
   }

   //+------------------------------------------------------------------+
   //| Range Liquidity (range high and low boundaries)                  |
   //+------------------------------------------------------------------+
   int DetectRangeLiquidity(const double &highs[], const double &lows[],
                            const datetime &times[], int bar_count,
                            string symbol, ENUM_TIMEFRAMES tf,
                            LiquidityPoolData &pools[], int count, int max_pools)
   {
      if(count >= max_pools - 2) return count;

      int lookback = MathMin(100, bar_count);
      int start = bar_count - lookback;
      if(start < 0) start = 0;

      double range_high = -DBL_MAX;
      double range_low = DBL_MAX;
      int rh_idx = start, rl_idx = start;

      for(int i = start; i < bar_count; i++)
      {
         if(highs[i] > range_high) { range_high = highs[i]; rh_idx = i; }
         if(lows[i] < range_low)   { range_low = lows[i]; rl_idx = i; }
      }

      pools[count].Init();
      pools[count].id        = m_next_pool_id++;
      pools[count].symbol    = symbol;
      pools[count].pool_type = LPOOL_RANGE_HIGH;
      pools[count].side      = POOL_BUY_SIDE;
      pools[count].price     = range_high;
      pools[count].zone_high = range_high;
      pools[count].zone_low  = range_high;
      pools[count].strength  = 2.0;
      pools[count].timeframe = tf;
      pools[count].timestamp = times[rh_idx];
      pools[count].bar_index = rh_idx;
      count++;

      pools[count].Init();
      pools[count].id        = m_next_pool_id++;
      pools[count].symbol    = symbol;
      pools[count].pool_type = LPOOL_RANGE_LOW;
      pools[count].side      = POOL_SELL_SIDE;
      pools[count].price     = range_low;
      pools[count].zone_high = range_low;
      pools[count].zone_low  = range_low;
      pools[count].strength  = 2.0;
      pools[count].timeframe = tf;
      pools[count].timestamp = times[rl_idx];
      pools[count].bar_index = rl_idx;
      count++;

      return count;
   }

   //+------------------------------------------------------------------+
   //| Trendline Liquidity                                              |
   //| Stops accumulate just beyond trendlines connecting swing points  |
   //+------------------------------------------------------------------+
   int DetectTrendlineLiquidity(const double &highs[], const double &lows[],
                                const datetime &times[], int bar_count,
                                string symbol, ENUM_TIMEFRAMES tf,
                                SymbolSpec &spec,
                                LiquidityPoolData &pools[], int count, int max_pools)
   {
      // Rising trendline: connect recent swing lows
      int sl_indices[];
      int sl_count = DetectSwingLows(lows, bar_count, m_swing_lookback, sl_indices);

      if(sl_count >= 2)
      {
         // Use last two swing lows to project trendline
         int idx1 = sl_indices[sl_count - 2];
         int idx2 = sl_indices[sl_count - 1];
         if(idx2 > idx1 && lows[idx2] > lows[idx1])  // Rising
         {
            double slope = (lows[idx2] - lows[idx1]) / (double)(idx2 - idx1);
            // Project to current bar
            int current_bar = bar_count - 1;
            double tl_price = lows[idx2] + slope * (current_bar - idx2);

            if(tl_price > 0 && count < max_pools)
            {
               pools[count].Init();
               pools[count].id        = m_next_pool_id++;
               pools[count].symbol    = symbol;
               pools[count].pool_type = LPOOL_TRENDLINE;
               pools[count].side      = POOL_SELL_SIDE;  // Stops below rising trendline
               pools[count].price     = tl_price;
               pools[count].zone_high = tl_price + m_trendline_tolerance_pips * spec.pip_size;
               pools[count].zone_low  = tl_price - m_trendline_tolerance_pips * spec.pip_size;
               pools[count].strength  = 2.0;
               pools[count].timeframe = tf;
               pools[count].timestamp = times[current_bar];
               pools[count].bar_index = current_bar;
               count++;
            }
         }
      }

      // Falling trendline: connect recent swing highs
      int sh_indices[];
      int sh_count = DetectSwingHighs(highs, bar_count, m_swing_lookback, sh_indices);

      if(sh_count >= 2)
      {
         int idx1 = sh_indices[sh_count - 2];
         int idx2 = sh_indices[sh_count - 1];
         if(idx2 > idx1 && highs[idx2] < highs[idx1])  // Falling
         {
            double slope = (highs[idx2] - highs[idx1]) / (double)(idx2 - idx1);
            int current_bar = bar_count - 1;
            double tl_price = highs[idx2] + slope * (current_bar - idx2);

            if(tl_price > 0 && count < max_pools)
            {
               pools[count].Init();
               pools[count].id        = m_next_pool_id++;
               pools[count].symbol    = symbol;
               pools[count].pool_type = LPOOL_TRENDLINE;
               pools[count].side      = POOL_BUY_SIDE;  // Stops above falling trendline
               pools[count].price     = tl_price;
               pools[count].zone_high = tl_price + m_trendline_tolerance_pips * spec.pip_size;
               pools[count].zone_low  = tl_price - m_trendline_tolerance_pips * spec.pip_size;
               pools[count].strength  = 2.0;
               pools[count].timeframe = tf;
               pools[count].timestamp = times[current_bar];
               pools[count].bar_index = current_bar;
               count++;
            }
         }
      }

      return count;
   }

   //+------------------------------------------------------------------+
   //| Resting Liquidity (round numbers, psychological levels)          |
   //+------------------------------------------------------------------+
   int DetectRestingLiquidity(const double &highs[], const double &lows[],
                              const double &closes[], const datetime &times[],
                              int bar_count, string symbol, ENUM_TIMEFRAMES tf,
                              SymbolSpec &spec,
                              LiquidityPoolData &pools[], int count, int max_pools)
   {
      if(bar_count < 2) return count;

      double current_price = closes[bar_count - 1];
      double round_interval = 0;

      // Determine round number interval based on asset
      if(spec.asset_class == ASSET_COMMODITY)
         round_interval = 10.0;    // Gold: every $10 (2050, 2060, 2070...)
      else if(spec.asset_class == ASSET_FOREX)
         round_interval = 0.01;    // Forex: every 100 pips
      else if(spec.asset_class == ASSET_INDEX)
         round_interval = 100.0;   // Indices: every 100 points
      else if(spec.asset_class == ASSET_CRYPTO)
         round_interval = 1000.0;  // Crypto: every $1000

      if(round_interval <= 0) return count;

      // Find round numbers near current price (within 5 intervals)
      double base = MathFloor(current_price / round_interval) * round_interval;

      for(int r = -3; r <= 3 && count < max_pools; r++)
      {
         double level = base + r * round_interval;
         if(level <= 0) continue;

         pools[count].Init();
         pools[count].id        = m_next_pool_id++;
         pools[count].symbol    = symbol;
         pools[count].pool_type = LPOOL_RESTING;
         pools[count].price     = level;
         pools[count].zone_high = level + spec.pip_size;
         pools[count].zone_low  = level - spec.pip_size;
         pools[count].timeframe = tf;
         pools[count].timestamp = times[bar_count - 1];
         pools[count].bar_index = bar_count - 1;

         if(level > current_price)
         {
            pools[count].side     = POOL_BUY_SIDE;
            pools[count].strength = 1.5;
         }
         else
         {
            pools[count].side     = POOL_SELL_SIDE;
            pools[count].strength = 1.5;
         }
         count++;
      }

      return count;
   }

   //--- Score a stop run
   double ScoreStopRun(double penetration, double reversal, SymbolSpec &spec)
   {
      double pen_score = MathMin(penetration / (spec.pip_size * 15.0), 1.0) * 4.0;
      double rev_score = MathMin(reversal / (spec.pip_size * 20.0), 1.0) * 4.0;
      return MathMin(pen_score + rev_score + 2.0, 10.0);
   }
};

#endif
