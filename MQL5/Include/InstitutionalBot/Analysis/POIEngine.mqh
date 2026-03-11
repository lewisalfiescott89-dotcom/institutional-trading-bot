//+------------------------------------------------------------------+
//| POIEngine.mqh - Order Block / POI detection engine               |
//| Detects supply/demand zones via displacement candles              |
//+------------------------------------------------------------------+
#ifndef POI_ENGINE_MQH
#define POI_ENGINE_MQH

#include "../Core/Utils.mqh"
#include "../Models/POI.mqh"
#include "../Config.mqh"

class CPOIEngine
{
private:
   POISettings m_cfg;
   int         m_next_id;

public:
   CPOIEngine() : m_next_id(1) { m_cfg.Init(); }
   void SetConfig(const POISettings &cfg) { m_cfg = cfg; }

   //--- Detect order blocks on OHLCV arrays
   int DetectOrderBlocks(const double &opens[], const double &highs[],
                         const double &lows[], const double &closes[],
                         const datetime &times[], int bar_count,
                         string symbol, ENUM_TIMEFRAMES tf,
                         POIData &pois[], int max_pois)
   {
      int count = 0;
      if(bar_count < m_cfg.atr_period + 5) return 0;

      double atr_arr[];
      ComputeATRArray(highs, lows, closes, m_cfg.atr_period, bar_count, atr_arr);

      for(int i = m_cfg.atr_period + 1; i < bar_count - 1 && count < max_pois; i++)
      {
         if(atr_arr[i] <= 0) continue;
         double current_atr = atr_arr[i];

         double disp_body  = CandleBody(opens[i], closes[i]);
         double disp_range = CandleRange(highs[i], lows[i]);

         // Check displacement strength
         if(disp_body < current_atr * m_cfg.displacement_multiplier) continue;
         if(disp_range == 0) continue;
         if(BodyRatio(opens[i], closes[i], highs[i], lows[i]) < m_cfg.min_body_ratio) continue;

         // Bearish displacement -> find last bullish candle = supply zone
         if(IsBearish(opens[i], closes[i]))
         {
            for(int j = i - 1; j >= MathMax(i - 10, 0); j--)
            {
               if(IsBullish(opens[j], closes[j]))
               {
                  pois[count].Init();
                  pois[count].id              = m_next_id++;
                  pois[count].symbol          = symbol;
                  pois[count].timeframe       = tf;
                  pois[count].direction       = POI_BEARISH;
                  pois[count].poi_type        = POI_ORDER_BLOCK;
                  pois[count].zone_low        = lows[j];
                  pois[count].zone_high       = highs[j];
                  pois[count].origin_bar_index= j;
                  pois[count].origin_time     = times[j];
                  pois[count].score           = BaseScore(tf, current_atr, disp_body);
                  pois[count].AddConfluence("OB_supply_" + TimeframeToString(tf));
                  count++;
                  break;
               }
            }
         }
         // Bullish displacement -> find last bearish candle = demand zone
         else if(IsBullish(opens[i], closes[i]))
         {
            for(int j = i - 1; j >= MathMax(i - 10, 0); j--)
            {
               if(IsBearish(opens[j], closes[j]))
               {
                  pois[count].Init();
                  pois[count].id              = m_next_id++;
                  pois[count].symbol          = symbol;
                  pois[count].timeframe       = tf;
                  pois[count].direction       = POI_BULLISH;
                  pois[count].poi_type        = POI_ORDER_BLOCK;
                  pois[count].zone_low        = lows[j];
                  pois[count].zone_high       = highs[j];
                  pois[count].origin_bar_index= j;
                  pois[count].origin_time     = times[j];
                  pois[count].score           = BaseScore(tf, current_atr, disp_body);
                  pois[count].AddConfluence("OB_demand_" + TimeframeToString(tf));
                  count++;
                  break;
               }
            }
         }
      }
      return count;
   }

   //--- Detect all POIs across a timeframe
   int DetectAll(const double &opens[], const double &highs[],
                 const double &lows[], const double &closes[],
                 const datetime &times[], int bar_count,
                 string symbol, ENUM_TIMEFRAMES tf,
                 POIData &pois[], int max_pois)
   {
      return DetectOrderBlocks(opens, highs, lows, closes, times,
                               bar_count, symbol, tf, pois, max_pois);
   }

   //--- Tag POIs as projected from higher TFs
   void ProjectPOIs(POIData &pois[], int count)
   {
      for(int i = 0; i < count; i++)
      {
         if(!pois[i].active) continue;
         if(pois[i].timeframe != EXECUTION_TF)
            pois[i].AddConfluence("projected_from_" + TimeframeToString(pois[i].timeframe));
      }
   }

   //--- Update freshness based on touch count
   void UpdateFreshness(POIData &poi)
   {
      if(poi.touches > 0)
      {
         double decay = m_cfg.freshness_decay_per_touch * poi.touches;
         poi.score = MathMax(0.0, poi.score * (1.0 - decay));
      }
   }

private:
   double BaseScore(ENUM_TIMEFRAMES tf, double atr, double displacement)
   {
      double tf_weight = GetTimeframeWeight(tf);
      double disp_strength = (atr > 0) ? displacement / atr : 1.0;
      return NormalizeDouble(tf_weight * disp_strength * 5.0, 2);
   }
};

#endif
