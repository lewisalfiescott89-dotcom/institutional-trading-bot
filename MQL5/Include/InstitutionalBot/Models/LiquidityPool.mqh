//+------------------------------------------------------------------+
//| LiquidityPool.mqh - Comprehensive ICT liquidity pool model       |
//| Covers all liquidity types: BSL/SSL, equal H/L, external,       |
//| internal, resting, range, trendline, void, stop run, OB/BB liq  |
//+------------------------------------------------------------------+
#ifndef LIQUIDITY_POOL_MQH
#define LIQUIDITY_POOL_MQH

//--- Liquidity pool types (ICT/SMC taxonomy)
enum ENUM_LIQ_POOL_TYPE
{
   LPOOL_BSL,              // Buy-Side Liquidity (stops above swing highs)
   LPOOL_SSL,              // Sell-Side Liquidity (stops below swing lows)
   LPOOL_EQUAL_HIGHS,      // Equal highs (double/triple top - stops above)
   LPOOL_EQUAL_LOWS,       // Equal lows (double/triple bottom - stops below)
   LPOOL_EXTERNAL_HIGH,    // External liquidity above range high
   LPOOL_EXTERNAL_LOW,     // External liquidity below range low
   LPOOL_INTERNAL,         // Internal liquidity (FVGs/OBs within range)
   LPOOL_RANGE_HIGH,       // Range high boundary liquidity
   LPOOL_RANGE_LOW,        // Range low boundary liquidity
   LPOOL_TRENDLINE,        // Trendline liquidity (stops beyond trendline)
   LPOOL_VOID,             // Liquidity void (large impulse candle, no opposing orders)
   LPOOL_STOP_RUN,         // Stop run (swept liquidity then reversed)
   LPOOL_OB_LIQUIDITY,     // Liquidity resting at order block zones
   LPOOL_BB_LIQUIDITY,     // Liquidity resting at breaker block zones
   LPOOL_RESTING           // Generic resting liquidity at key levels
};

//--- Liquidity pool side
enum ENUM_POOL_SIDE { POOL_BUY_SIDE, POOL_SELL_SIDE };

//+------------------------------------------------------------------+
//| Liquidity Pool Structure                                          |
//+------------------------------------------------------------------+
struct LiquidityPoolData
{
   int                 id;
   string              symbol;
   ENUM_LIQ_POOL_TYPE  pool_type;
   ENUM_POOL_SIDE      side;
   double              price;          // Main price level
   double              zone_high;      // Upper bound of liquidity zone
   double              zone_low;       // Lower bound of liquidity zone
   double              strength;       // How strong (touches, confluence)
   ENUM_TIMEFRAMES     timeframe;
   datetime            timestamp;
   int                 bar_index;
   bool                active;
   bool                swept;          // Liquidity has been taken/swept
   int                 touch_count;    // Number of times price tested this level

   void Init()
   {
      id          = 0;
      symbol      = "";
      pool_type   = LPOOL_BSL;
      side        = POOL_BUY_SIDE;
      price       = 0;
      zone_high   = 0;
      zone_low    = 0;
      strength    = 1.0;
      timeframe   = PERIOD_M5;
      timestamp   = 0;
      bar_index   = 0;
      active      = true;
      swept       = false;
      touch_count = 0;
   }

   void MarkSwept()
   {
      swept  = true;
      active = false;
   }
};

//--- Vacuum Block: rapid price gap with no opposing orders
struct VacuumBlockData
{
   int               id;
   string            symbol;
   ENUM_TIMEFRAMES   timeframe;
   double            zone_high;
   double            zone_low;
   bool              is_bullish;    // Direction of the vacuum move
   double            impulse_size;  // Size of the rapid move
   int               bar_index;
   datetime          timestamp;
   bool              filled;        // Has price returned to fill the vacuum

   void Init()
   {
      id           = 0;
      symbol       = "";
      timeframe    = PERIOD_M5;
      zone_high    = 0;
      zone_low     = 0;
      is_bullish   = true;
      impulse_size = 0;
      bar_index    = 0;
      timestamp    = 0;
      filled       = false;
   }

   double ZoneWidth() const { return zone_high - zone_low; }
};

//--- Stop Run data: price swept a level then reversed
struct StopRunData
{
   int               id;
   string            symbol;
   double            swept_level;     // The liquidity level that was swept
   double            penetration;     // How far past the level price went
   double            reversal_size;   // Size of the reversal after sweep
   bool              is_buy_side;     // true = swept above (buy-side), false = swept below (sell-side)
   int               sweep_bar;       // Bar where the sweep happened
   datetime          timestamp;
   double            quality;         // 0-10 quality of the stop run

   void Init()
   {
      id             = 0;
      symbol         = "";
      swept_level    = 0;
      penetration    = 0;
      reversal_size  = 0;
      is_buy_side    = true;
      sweep_bar      = 0;
      timestamp      = 0;
      quality        = 0;
   }
};

#define MAX_LIQ_POOLS     300
#define MAX_VACUUM_BLOCKS 100
#define MAX_STOP_RUNS     50

#endif
