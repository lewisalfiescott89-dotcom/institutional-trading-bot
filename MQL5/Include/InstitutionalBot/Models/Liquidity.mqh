//+------------------------------------------------------------------+
//| Liquidity.mqh - Liquidity level model                            |
//+------------------------------------------------------------------+
#ifndef LIQUIDITY_MQH
#define LIQUIDITY_MQH

//--- Liquidity types (12 types as per spec)
enum ENUM_LIQUIDITY_TYPE
{
   LIQ_EQUAL_HIGHS,
   LIQ_EQUAL_LOWS,
   LIQ_PREV_DAY_HIGH,
   LIQ_PREV_DAY_LOW,
   LIQ_PREV_WEEK_HIGH,
   LIQ_PREV_WEEK_LOW,
   LIQ_SESSION_HIGH,
   LIQ_SESSION_LOW,
   LIQ_SWING_HIGH,
   LIQ_SWING_LOW,
   LIQ_RANGE_HIGH,
   LIQ_RANGE_LOW
};

enum ENUM_LIQUIDITY_SIDE { LIQ_BUY_SIDE, LIQ_SELL_SIDE };

//+------------------------------------------------------------------+
//| Liquidity Level Structure                                         |
//+------------------------------------------------------------------+
struct LiquidityLevel
{
   string              symbol;
   double              price;
   ENUM_LIQUIDITY_TYPE level_type;
   ENUM_LIQUIDITY_SIDE side;
   double              strength;
   ENUM_TIMEFRAMES     timeframe;
   bool                active;
   bool                swept;
   datetime            timestamp;

   void Init()
   {
      symbol    = "";
      price     = 0;
      level_type= LIQ_SWING_HIGH;
      side      = LIQ_BUY_SIDE;
      strength  = 1.0;
      timeframe = PERIOD_M5;
      active    = true;
      swept     = false;
      timestamp = 0;
   }

   void MarkSwept()
   {
      swept  = true;
      active = false;
   }
};

//+------------------------------------------------------------------+
//| Liquidity Forecast                                                |
//+------------------------------------------------------------------+
struct LiquidityTarget
{
   double              price;
   ENUM_LIQUIDITY_SIDE side;
   double              strength;
   double              distance;
   double              priority;
};

struct LiquidityForecast
{
   double           current_price;
   LiquidityTarget  above_targets[10];
   int              above_count;
   LiquidityTarget  below_targets[10];
   int              below_count;
   LiquidityTarget  primary_target;
   LiquidityTarget  secondary_target;
   bool             draw_is_above;
   double           confidence;

   void Init()
   {
      current_price = 0;
      above_count   = 0;
      below_count   = 0;
      draw_is_above = false;
      confidence    = 0;
      primary_target.price = 0;
      primary_target.strength = 0;
      primary_target.distance = 0;
      primary_target.priority = 0;
      secondary_target.price = 0;
      secondary_target.strength = 0;
      secondary_target.distance = 0;
      secondary_target.priority = 0;
   }
};

#endif
