//+------------------------------------------------------------------+
//| SweepEngine.mqh - Liquidity sweep detection                      |
//| Detects wick sweeps and close-through-reclaim sweeps             |
//+------------------------------------------------------------------+
#ifndef SWEEP_ENGINE_MQH
#define SWEEP_ENGINE_MQH

#include "../Core/Utils.mqh"
#include "../Models/Liquidity.mqh"
#include "../Models/POI.mqh"
#include "../Config.mqh"

enum ENUM_SWEEP_TYPE { SWEEP_WICK, SWEEP_CLOSE_RECLAIM };
enum ENUM_SWEEP_SIDE { SWEEP_BUY_SIDE, SWEEP_SELL_SIDE };

struct SweepData
{
   ENUM_SWEEP_TYPE type;
   ENUM_SWEEP_SIDE side;
   double          level_price;
   double          penetration;
   double          rejection_quality;
   double          score;
   int             bar_index;
   datetime        timestamp;
   bool            valid;

   void Init()
   {
      type              = SWEEP_WICK;
      side              = SWEEP_BUY_SIDE;
      level_price       = 0;
      penetration       = 0;
      rejection_quality = 0;
      score             = 0;
      bar_index         = 0;
      timestamp         = 0;
      valid             = false;
   }
};

#define MAX_SWEEPS 50

class CSweepEngine
{
private:
   SweepSettings m_cfg;

public:
   CSweepEngine() { m_cfg.Init(); }
   void SetConfig(const SweepSettings &cfg) { m_cfg = cfg; }

   //--- Detect sweeps on recent bars against liquidity levels
   int Detect(const double &opens[], const double &highs[],
              const double &lows[], const double &closes[],
              const datetime &times[], int bar_count,
              const LiquidityLevel &levels[], int level_count,
              string symbol, SweepData &sweeps[], int max_sweeps)
   {
      int count = 0;
      if(bar_count < 3 || level_count == 0) return 0;

      SymbolSpec spec = GetSymbolSpec(symbol);
      double min_pen = m_cfg.min_penetration_pips * spec.pip_size;

      // Check last N bars for sweeps
      int lookback = MathMin(m_cfg.lookback_bars, bar_count - 1);
      int start = bar_count - lookback;
      if(start < 1) start = 1;

      for(int i = start; i < bar_count && count < max_sweeps; i++)
      {
         for(int lv = 0; lv < level_count && count < max_sweeps; lv++)
         {
            if(!levels[lv].active || levels[lv].swept) continue;

            double lev_price = levels[lv].price;

            // Buy-side sweep: price goes above level then fails
            if(levels[lv].side == LIQ_BUY_SIDE)
            {
               // Wick sweep: high above level but close below
               if(highs[i] > lev_price + min_pen && closes[i] < lev_price)
               {
                  double pen = highs[i] - lev_price;
                  double rej = (CandleRange(highs[i], lows[i]) > 0) ?
                               CandleUpperWick(opens[i], closes[i], highs[i]) /
                               CandleRange(highs[i], lows[i]) : 0;

                  if(rej >= m_cfg.min_rejection_ratio)
                  {
                     sweeps[count].Init();
                     sweeps[count].type              = SWEEP_WICK;
                     sweeps[count].side              = SWEEP_BUY_SIDE;
                     sweeps[count].level_price       = lev_price;
                     sweeps[count].penetration       = pen;
                     sweeps[count].rejection_quality = rej;
                     sweeps[count].bar_index         = i;
                     sweeps[count].timestamp         = times[i];
                     sweeps[count].score             = ScoreSweep(pen, rej, levels[lv].strength, spec);
                     sweeps[count].valid             = true;
                     count++;
                  }
               }
               // Close-through then reclaim: prev bar closed above, current below
               else if(i >= 2 && closes[i-1] > lev_price && closes[i] < lev_price)
               {
                  double pen = closes[i-1] - lev_price;
                  if(pen >= min_pen)
                  {
                     sweeps[count].Init();
                     sweeps[count].type              = SWEEP_CLOSE_RECLAIM;
                     sweeps[count].side              = SWEEP_BUY_SIDE;
                     sweeps[count].level_price       = lev_price;
                     sweeps[count].penetration       = pen;
                     sweeps[count].rejection_quality = 0.7;
                     sweeps[count].bar_index         = i;
                     sweeps[count].timestamp         = times[i];
                     sweeps[count].score             = ScoreSweep(pen, 0.7, levels[lv].strength, spec);
                     sweeps[count].valid             = true;
                     count++;
                  }
               }
            }
            // Sell-side sweep: price goes below level then fails
            else if(levels[lv].side == LIQ_SELL_SIDE)
            {
               // Wick sweep: low below level but close above
               if(lows[i] < lev_price - min_pen && closes[i] > lev_price)
               {
                  double pen = lev_price - lows[i];
                  double rej = (CandleRange(highs[i], lows[i]) > 0) ?
                               CandleLowerWick(opens[i], closes[i], lows[i]) /
                               CandleRange(highs[i], lows[i]) : 0;

                  if(rej >= m_cfg.min_rejection_ratio)
                  {
                     sweeps[count].Init();
                     sweeps[count].type              = SWEEP_WICK;
                     sweeps[count].side              = SWEEP_SELL_SIDE;
                     sweeps[count].level_price       = lev_price;
                     sweeps[count].penetration       = pen;
                     sweeps[count].rejection_quality = rej;
                     sweeps[count].bar_index         = i;
                     sweeps[count].timestamp         = times[i];
                     sweeps[count].score             = ScoreSweep(pen, rej, levels[lv].strength, spec);
                     sweeps[count].valid             = true;
                     count++;
                  }
               }
               // Close-through then reclaim
               else if(i >= 2 && closes[i-1] < lev_price && closes[i] > lev_price)
               {
                  double pen = lev_price - closes[i-1];
                  if(pen >= min_pen)
                  {
                     sweeps[count].Init();
                     sweeps[count].type              = SWEEP_CLOSE_RECLAIM;
                     sweeps[count].side              = SWEEP_SELL_SIDE;
                     sweeps[count].level_price       = lev_price;
                     sweeps[count].penetration       = pen;
                     sweeps[count].rejection_quality = 0.7;
                     sweeps[count].bar_index         = i;
                     sweeps[count].timestamp         = times[i];
                     sweeps[count].score             = ScoreSweep(pen, 0.7, levels[lv].strength, spec);
                     sweeps[count].valid             = true;
                     count++;
                  }
               }
            }
         }
      }
      return count;
   }

   //--- Check if a sweep is near a POI
   bool SweepNearPOI(const SweepData &sweep, const POIData &poi, double max_distance_atr)
   {
      double mid = poi.MidPrice();
      double dist = MathAbs(sweep.level_price - mid);
      return dist <= max_distance_atr;
   }

private:
   double ScoreSweep(double penetration, double rejection, double level_strength,
                     const SymbolSpec &spec)
   {
      double pen_score = MathMin(penetration / (spec.pip_size * 20.0), 1.0) * 3.0;
      double rej_score = rejection * 4.0;
      double str_score = MathMin(level_strength, 3.0);
      return pen_score + rej_score + str_score;
   }
};

#endif
