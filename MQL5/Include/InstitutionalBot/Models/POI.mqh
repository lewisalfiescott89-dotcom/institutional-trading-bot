//+------------------------------------------------------------------+
//| POI.mqh - Point of Interest model                                |
//+------------------------------------------------------------------+
#ifndef POI_MQH
#define POI_MQH

//--- POI Direction
enum ENUM_POI_DIRECTION { POI_BULLISH, POI_BEARISH };

//--- POI Type
enum ENUM_POI_TYPE { POI_ORDER_BLOCK, POI_FVG_ZONE, POI_LIQUIDITY_REVERSAL };

//--- POI Freshness
enum ENUM_POI_FRESHNESS { POI_FRESH, POI_ONCE_TESTED, POI_MULTIPLE_TESTED, POI_BROKEN };

//+------------------------------------------------------------------+
//| POI Structure                                                     |
//+------------------------------------------------------------------+
struct POIData
{
   int               id;
   string            symbol;
   ENUM_TIMEFRAMES   timeframe;
   ENUM_POI_DIRECTION direction;
   ENUM_POI_TYPE     poi_type;
   ENUM_POI_FRESHNESS freshness;
   double            zone_low;
   double            zone_high;
   double            score;
   bool              active;
   bool              invalidated;
   int               touches;
   int               origin_bar_index;
   datetime          origin_time;
   string            cluster_id;
   string            confluences[20];
   int               confluence_count;
   bool              wick_probe_pending;
   int               wick_probe_bar_index;

   void Init()
   {
      id                   = 0;
      symbol               = "";
      timeframe            = PERIOD_M5;
      direction            = POI_BULLISH;
      poi_type             = POI_ORDER_BLOCK;
      freshness            = POI_FRESH;
      zone_low             = 0;
      zone_high            = 0;
      score                = 0;
      active               = true;
      invalidated          = false;
      touches              = 0;
      origin_bar_index     = 0;
      origin_time          = 0;
      cluster_id           = "";
      confluence_count     = 0;
      wick_probe_pending   = false;
      wick_probe_bar_index = 0;
   }

   double MidPrice()      { return (zone_low + zone_high) / 2.0; }
   double ZoneWidth()     { return zone_high - zone_low; }
   bool   ContainsPrice(double price) { return price >= zone_low && price <= zone_high; }

   void AddConfluence(string conf)
   {
      if(confluence_count < 20)
      {
         confluences[confluence_count] = conf;
         confluence_count++;
      }
   }

   void RecordTouch()
   {
      touches++;
      if(touches == 1)      freshness = POI_ONCE_TESTED;
      else if(touches >= 2) freshness = POI_MULTIPLE_TESTED;
   }

   void Invalidate()
   {
      active      = false;
      invalidated = true;
      freshness   = POI_BROKEN;
   }
};

#endif
