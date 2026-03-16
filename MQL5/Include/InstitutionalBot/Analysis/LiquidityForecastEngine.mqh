//+------------------------------------------------------------------+
//| LiquidityForecastEngine.mqh - Forecasts next liquidity draw      |
//| Ranks liquidity above/below price, predicts likely target        |
//+------------------------------------------------------------------+
#ifndef LIQUIDITY_FORECAST_ENGINE_MQH
#define LIQUIDITY_FORECAST_ENGINE_MQH

#include "../Models/Liquidity.mqh"
#include "../Models/Regime.mqh"
#include "../Config.mqh"

class CLiquidityForecastEngine
{
public:
   CLiquidityForecastEngine() {}

   //--- Build a liquidity forecast from current levels and price
   void Forecast(LiquidityLevel &levels[], int level_count,
                 double current_price, const MarketRegime &regime,
                 LiquidityForecast &forecast)
   {
      forecast.Init();
      forecast.current_price = current_price;

      if(level_count == 0) return;

      // Separate buy-side (above) and sell-side (below) liquidity
      LiquidityTarget above_targets[];
      LiquidityTarget below_targets[];
      int above_count = 0, below_count = 0;
      ArrayResize(above_targets, level_count);
      ArrayResize(below_targets, level_count);

      for(int i = 0; i < level_count; i++)
      {
         if(!levels[i].active || levels[i].swept) continue;

         LiquidityTarget tgt;
         tgt.price    = levels[i].price;
         tgt.side     = levels[i].side;
         tgt.strength = levels[i].strength;
         tgt.distance = MathAbs(levels[i].price - current_price);
         tgt.priority = ScoreTarget(levels[i], current_price, regime);

         if(levels[i].price > current_price)
         {
            above_targets[above_count] = tgt;
            above_count++;
         }
         else
         {
            below_targets[below_count] = tgt;
            below_count++;
         }
      }

      // Sort by priority (descending) - simple bubble sort
      SortTargets(above_targets, above_count);
      SortTargets(below_targets, below_count);

      // Fill forecast
      forecast.above_count = MathMin(above_count, 10);
      for(int i = 0; i < forecast.above_count; i++)
         forecast.above_targets[i] = above_targets[i];

      forecast.below_count = MathMin(below_count, 10);
      for(int i = 0; i < forecast.below_count; i++)
         forecast.below_targets[i] = below_targets[i];

      // Determine primary draw on liquidity
      if(above_count > 0 && below_count > 0)
      {
         double above_best = above_targets[0].priority;
         double below_best = below_targets[0].priority;

         if(regime.trend_bias == BIAS_BULLISH)
            above_best *= 1.3;
         else if(regime.trend_bias == BIAS_BEARISH)
            below_best *= 1.3;

         if(above_best >= below_best)
         {
            forecast.primary_target = above_targets[0];
            forecast.draw_is_above  = true;
            if(below_count > 0)
               forecast.secondary_target = below_targets[0];
         }
         else
         {
            forecast.primary_target = below_targets[0];
            forecast.draw_is_above  = false;
            if(above_count > 0)
               forecast.secondary_target = above_targets[0];
         }
         forecast.confidence = MathAbs(above_best - below_best) /
                               MathMax(above_best, below_best);
      }
      else if(above_count > 0)
      {
         forecast.primary_target = above_targets[0];
         forecast.draw_is_above  = true;
         forecast.confidence     = 0.7;
      }
      else if(below_count > 0)
      {
         forecast.primary_target = below_targets[0];
         forecast.draw_is_above  = false;
         forecast.confidence     = 0.7;
      }
   }

private:
   double ScoreTarget(const LiquidityLevel &level, double current_price,
                      const MarketRegime &regime)
   {
      double score = level.strength;

      // Distance factor: nearer = higher priority (but not too close)
      double distance = MathAbs(level.price - current_price);
      if(distance > 0)
      {
         double proximity = 1.0 / (1.0 + distance * 0.001);
         score *= (0.5 + proximity * 0.5);
      }

      // Type weighting
      switch(level.level_type)
      {
         case LIQ_EQUAL_HIGHS:
         case LIQ_EQUAL_LOWS:    score *= 1.5; break;
         case LIQ_PREV_DAY_HIGH:
         case LIQ_PREV_DAY_LOW:  score *= 1.3; break;
         case LIQ_PREV_WEEK_HIGH:
         case LIQ_PREV_WEEK_LOW: score *= 1.4; break;
         case LIQ_SESSION_HIGH:
         case LIQ_SESSION_LOW:   score *= 1.1; break;
         default:                score *= 1.0; break;
      }

      // Trend alignment bonus
      if(regime.trend_bias == BIAS_BULLISH && level.side == LIQ_BUY_SIDE)
         score *= 1.2;
      else if(regime.trend_bias == BIAS_BEARISH && level.side == LIQ_SELL_SIDE)
         score *= 1.2;

      return score;
   }

   void SortTargets(LiquidityTarget &targets[], int count)
   {
      for(int i = 0; i < count - 1; i++)
      {
         for(int j = i + 1; j < count; j++)
         {
            if(targets[j].priority > targets[i].priority)
            {
               LiquidityTarget temp = targets[i];
               targets[i] = targets[j];
               targets[j] = temp;
            }
         }
      }
   }
};

#endif
