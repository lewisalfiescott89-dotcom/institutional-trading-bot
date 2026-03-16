//+------------------------------------------------------------------+
//| OrderBlock.mqh - Order Block and Breaker Block models            |
//| ICT/SMC: OB = last opposing candle before impulsive move         |
//|          BB = OB that failed (broken through) now opposite zone  |
//+------------------------------------------------------------------+
#ifndef ORDER_BLOCK_MQH
#define ORDER_BLOCK_MQH

//--- Order Block direction
enum ENUM_OB_DIRECTION { OB_BULLISH, OB_BEARISH };

//--- Order Block status
enum ENUM_OB_STATUS
{
   OB_FRESH,        // Not yet retested
   OB_TESTED,       // Price returned to OB zone
   OB_MITIGATED,    // OB has been partially filled/used
   OB_BROKEN        // Price closed through OB (becomes breaker candidate)
};

//+------------------------------------------------------------------+
//| Order Block Structure                                             |
//| Last opposing candle before an impulsive displacement move        |
//| Bullish OB = last bearish candle before bullish impulse           |
//| Bearish OB = last bullish candle before bearish impulse           |
//+------------------------------------------------------------------+
struct OrderBlockData
{
   int               id;
   string            symbol;
   ENUM_TIMEFRAMES   timeframe;
   ENUM_OB_DIRECTION direction;
   ENUM_OB_STATUS    status;
   double            zone_high;
   double            zone_low;
   double            impulse_size;     // Size of the displacement move that created this OB
   double            quality;          // 0-10 quality score
   int               origin_bar;       // Bar index of the OB candle
   datetime          origin_time;
   bool              active;

   void Init()
   {
      id           = 0;
      symbol       = "";
      timeframe    = PERIOD_M5;
      direction    = OB_BULLISH;
      status       = OB_FRESH;
      zone_high    = 0;
      zone_low     = 0;
      impulse_size = 0;
      quality      = 0;
      origin_bar   = 0;
      origin_time  = 0;
      active       = true;
   }

   double MidPrice()  const { return (zone_low + zone_high) / 2.0; }
   double ZoneWidth() const { return zone_high - zone_low; }

   bool ContainsPrice(double price) const
   {
      return price >= zone_low && price <= zone_high;
   }
};

//+------------------------------------------------------------------+
//| Breaker Block Structure                                           |
//| A failed Order Block that was broken through by price             |
//| Now acts as OPPOSITE polarity zone                                |
//| e.g. Bullish OB broken to downside = Bearish Breaker Block       |
//+------------------------------------------------------------------+
struct BreakerBlockData
{
   int               id;
   string            symbol;
   ENUM_TIMEFRAMES   timeframe;
   ENUM_OB_DIRECTION direction;     // Direction AFTER breaking (opposite of original OB)
   double            zone_high;
   double            zone_low;
   double            quality;
   int               ob_origin_bar;  // Bar where the original OB was
   int               break_bar;      // Bar where the OB was broken
   datetime          break_time;
   bool              active;
   bool              mitigated;      // Price has returned and reacted to the breaker

   void Init()
   {
      id            = 0;
      symbol        = "";
      timeframe     = PERIOD_M5;
      direction     = OB_BULLISH;
      zone_high     = 0;
      zone_low      = 0;
      quality       = 0;
      ob_origin_bar = 0;
      break_bar     = 0;
      break_time    = 0;
      active        = true;
      mitigated     = false;
   }

   double MidPrice()  const { return (zone_low + zone_high) / 2.0; }
   double ZoneWidth() const { return zone_high - zone_low; }

   bool ContainsPrice(double price) const
   {
      return price >= zone_low && price <= zone_high;
   }
};

#define MAX_ORDER_BLOCKS  200
#define MAX_BREAKER_BLOCKS 100

#endif
