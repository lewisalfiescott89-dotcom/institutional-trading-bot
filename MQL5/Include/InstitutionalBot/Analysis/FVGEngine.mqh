//+------------------------------------------------------------------+
//| FVGEngine.mqh - Fair Value Gap detection and tracking            |
//| Detects 3-candle FVGs (bullish & bearish) with fill tracking     |
//+------------------------------------------------------------------+
#ifndef FVG_ENGINE_MQH
#define FVG_ENGINE_MQH

#include "../Core/Utils.mqh"
#include "../Models/POI.mqh"
#include "../Config.mqh"

enum ENUM_FVG_DIRECTION { FVG_BULLISH, FVG_BEARISH };
enum ENUM_FVG_FILL_STATE { FVG_UNFILLED, FVG_PARTIALLY_FILLED, FVG_FULLY_FILLED };

struct FVGData
{
   int               id;
   string            symbol;
   ENUM_TIMEFRAMES   timeframe;
   ENUM_FVG_DIRECTION direction;
   double            gap_low;
   double            gap_high;
   ENUM_FVG_FILL_STATE fill_state;
   double            quality;
   int               bar_index;
   datetime          timestamp;

   void Init()
   {
      id         = 0;
      symbol     = "";
      timeframe  = PERIOD_M5;
      direction  = FVG_BULLISH;
      gap_low    = 0;
      gap_high   = 0;
      fill_state = FVG_UNFILLED;
      quality    = 0;
      bar_index  = 0;
      timestamp  = 0;
   }

   double GapSize() { return gap_high - gap_low; }
   bool ContainsPrice(double price) { return price >= gap_low && price <= gap_high; }
};

#define MAX_FVGS 200

class CFVGEngine
{
private:
   FVGSettings m_cfg;
   int         m_next_id;

public:
   CFVGEngine() : m_next_id(1) { m_cfg.Init(); }
   void SetConfig(const FVGSettings &cfg) { m_cfg = cfg; }

   //--- Detect FVGs
   int Detect(const double &highs[], const double &lows[],
              const double &closes[], const datetime &times[],
              int bar_count, string symbol, ENUM_TIMEFRAMES tf,
              FVGData &fvgs[], int max_fvgs)
   {
      int count = 0;
      if(bar_count < 20) return 0;

      double atr_arr[];
      double opens_dummy[];  // Not needed for ATR but required by signature
      ArrayResize(opens_dummy, bar_count);
      ArrayCopy(opens_dummy, closes);  // Approximate
      ComputeATRArray(highs, lows, closes, 14, bar_count, atr_arr);

      for(int i = 0; i < bar_count - 2 && count < max_fvgs; i++)
      {
         if(atr_arr[i] <= 0) continue;
         double current_atr = atr_arr[i];

         double c1_high = highs[i];
         double c1_low  = lows[i];
         double c3_high = highs[i + 2];
         double c3_low  = lows[i + 2];

         // Bullish FVG: candle 3 low > candle 1 high
         if(c3_low > c1_high)
         {
            double gap_size = c3_low - c1_high;
            double ratio = gap_size / current_atr;
            if(ratio >= m_cfg.min_gap_atr_ratio && ratio <= m_cfg.max_gap_atr_ratio)
            {
               fvgs[count].Init();
               fvgs[count].id        = m_next_id++;
               fvgs[count].symbol    = symbol;
               fvgs[count].timeframe = tf;
               fvgs[count].direction = FVG_BULLISH;
               fvgs[count].gap_low   = c1_high;
               fvgs[count].gap_high  = c3_low;
               fvgs[count].quality   = MathMin(ratio * 10.0, 10.0);
               fvgs[count].bar_index = i + 1;
               fvgs[count].timestamp = times[i + 1];
               count++;
            }
         }

         // Bearish FVG: candle 3 high < candle 1 low
         if(c3_high < c1_low)
         {
            double gap_size = c1_low - c3_high;
            double ratio = gap_size / current_atr;
            if(ratio >= m_cfg.min_gap_atr_ratio && ratio <= m_cfg.max_gap_atr_ratio)
            {
               fvgs[count].Init();
               fvgs[count].id        = m_next_id++;
               fvgs[count].symbol    = symbol;
               fvgs[count].timeframe = tf;
               fvgs[count].direction = FVG_BEARISH;
               fvgs[count].gap_low   = c3_high;
               fvgs[count].gap_high  = c1_low;
               fvgs[count].quality   = MathMin(ratio * 10.0, 10.0);
               fvgs[count].bar_index = i + 1;
               fvgs[count].timestamp = times[i + 1];
               count++;
            }
         }
      }
      return count;
   }

   //--- Update FVG fill state based on subsequent price action
   void UpdateFillState(FVGData &fvgs[], int fvg_count,
                        const double &highs[], const double &lows[], int bar_count)
   {
      for(int f = 0; f < fvg_count; f++)
      {
         if(fvgs[f].fill_state == FVG_FULLY_FILLED) continue;
         int start = fvgs[f].bar_index + 2;
         if(start >= bar_count) continue;

         for(int i = start; i < bar_count; i++)
         {
            if(fvgs[f].direction == FVG_BULLISH)
            {
               if(lows[i] <= fvgs[f].gap_low)       { fvgs[f].fill_state = FVG_FULLY_FILLED; break; }
               else if(lows[i] <= fvgs[f].gap_high)    fvgs[f].fill_state = FVG_PARTIALLY_FILLED;
            }
            else
            {
               if(highs[i] >= fvgs[f].gap_high)      { fvgs[f].fill_state = FVG_FULLY_FILLED; break; }
               else if(highs[i] >= fvgs[f].gap_low)    fvgs[f].fill_state = FVG_PARTIALLY_FILLED;
            }
         }
      }
   }

   //--- Boost POI score if FVG overlaps
   void BoostPOIWithFVGs(POIData &pois[], int poi_count,
                         const FVGData &fvgs[], int fvg_count)
   {
      for(int p = 0; p < poi_count; p++)
      {
         for(int f = 0; f < fvg_count; f++)
         {
            if(fvgs[f].fill_state == FVG_FULLY_FILLED) continue;
            if(!DirectionsAlign(pois[p], fvgs[f])) continue;
            if(fvgs[f].gap_low <= pois[p].zone_high && pois[p].zone_low <= fvgs[f].gap_high)
            {
               pois[p].score += fvgs[f].quality * 0.5;
               pois[p].AddConfluence("fvg_" + TimeframeToString(fvgs[f].timeframe));
            }
         }
      }
   }

private:
   bool DirectionsAlign(const POIData &poi, const FVGData &fvg)
   {
      return (poi.direction == POI_BULLISH && fvg.direction == FVG_BULLISH) ||
             (poi.direction == POI_BEARISH && fvg.direction == FVG_BEARISH);
   }
};

#endif
