//+------------------------------------------------------------------+
//| TradeQualityEngine.mqh - Setup scoring and grading               |
//| Combines all confluences into A+ to D grade                      |
//+------------------------------------------------------------------+
#ifndef TRADE_QUALITY_ENGINE_MQH
#define TRADE_QUALITY_ENGINE_MQH

#include "../Models/Signal.mqh"
#include "../Models/POI.mqh"
#include "../Models/Regime.mqh"
#include "../Models/Liquidity.mqh"
#include "StructureEngine.mqh"
#include "SessionEngine.mqh"
#include "SweepEngine.mqh"
#include "TrapEngine.mqh"
#include "ReversalEngine.mqh"
#include "LiquidityTimingEngine.mqh"
#include "FVGEngine.mqh"
#include "../Config.mqh"

class CTradeQualityEngine
{
private:
   GradingSettings m_cfg;

public:
   CTradeQualityEngine() { m_cfg.Init(); }
   void SetConfig(const GradingSettings &cfg) { m_cfg = cfg; }

   //--- Score a complete setup
   void ScoreSetup(const POIData &poi,
                   bool has_cluster, double cluster_score,
                   const LiquidityLevel &nearest_liq, bool has_liq,
                   const LiquidityForecast &forecast,
                   const StructureResult &structure,
                   const MarketRegime &regime,
                   const TimingResult &timing,
                   const SweepData &sweep, bool has_sweep,
                   const TrapData &trap, bool has_trap,
                   const ReversalData &reversal,
                   SignalData &signal)
   {
      signal.Init();

      signal.score_breakdown.Init();

      // 1. POI strength (0-10)
      signal.score_breakdown.poi_strength = MathMin(poi.score, 10.0);

      // 2. Cluster strength (0-10)
      if(has_cluster)
         signal.score_breakdown.cluster_strength = MathMin(cluster_score * 2.0, 10.0);

      // 3. Liquidity confluence (0-10)
      if(has_liq)
      {
         double dist_factor = (nearest_liq.strength > 0) ? nearest_liq.strength : 1.0;
         signal.score_breakdown.liquidity_confluence = MathMin(dist_factor * 3.0, 10.0);
      }

      // 4. Forecast alignment (0-10)
      if(forecast.confidence > 0)
      {
         bool aligned = false;
         if(poi.direction == POI_BEARISH && forecast.draw_is_above)
            aligned = true;  // Supply POI, liquidity draw above = good for sells
         else if(poi.direction == POI_BULLISH && !forecast.draw_is_above)
            aligned = true;  // Demand POI, liquidity draw below = good for buys

         if(aligned)
            signal.score_breakdown.forecast_alignment = forecast.confidence * 10.0;
         else
            signal.score_breakdown.forecast_alignment = (1.0 - forecast.confidence) * 3.0;
      }

      // 5. Structure alignment (0-10)
      if(poi.direction == POI_BULLISH && structure.bias == BIAS_BULLISH)
         signal.score_breakdown.structure_alignment = 8.0;
      else if(poi.direction == POI_BEARISH && structure.bias == BIAS_BEARISH)
         signal.score_breakdown.structure_alignment = 8.0;
      else if(structure.bias == BIAS_NEUTRAL)
         signal.score_breakdown.structure_alignment = 4.0;
      else
         signal.score_breakdown.structure_alignment = 2.0;  // Counter-trend

      // 6. Regime suitability (0-10)
      if(regime.regime == REGIME_TREND && structure.bias != BIAS_NEUTRAL)
         signal.score_breakdown.regime_suitability = 8.0;
      else if(regime.regime == REGIME_RANGE)
         signal.score_breakdown.regime_suitability = 6.0;
      else if(regime.regime == REGIME_HIGH_VOLATILITY)
         signal.score_breakdown.regime_suitability = 4.0;
      else if(regime.regime == REGIME_LOW_LIQUIDITY)
         signal.score_breakdown.regime_suitability = 2.0;

      // 7. Timing quality (0-10)
      signal.score_breakdown.timing_quality = timing.quality * 10.0;

      // 8. Sweep quality (0-10)
      if(has_sweep && sweep.valid)
         signal.score_breakdown.sweep_quality = MathMin(sweep.score, 10.0);

      // 9. Trap quality (0-10)
      if(has_trap && trap.valid)
         signal.score_breakdown.trap_quality = MathMin(trap.score, 10.0);

      // 10. Reversal quality (0-10)
      if(reversal.valid)
         signal.score_breakdown.reversal_quality = reversal.quality;

      // Calculate total and grade
      double total = signal.score_breakdown.Total();
      signal.total_score = total;

      // Apply weights
      double weighted = signal.score_breakdown.poi_strength * m_cfg.poi_weight +
                        signal.score_breakdown.cluster_strength * m_cfg.cluster_weight +
                        signal.score_breakdown.liquidity_confluence * m_cfg.liquidity_weight +
                        signal.score_breakdown.forecast_alignment * m_cfg.forecast_weight +
                        signal.score_breakdown.structure_alignment * m_cfg.structure_weight +
                        signal.score_breakdown.regime_suitability * m_cfg.regime_weight +
                        signal.score_breakdown.timing_quality * m_cfg.timing_weight +
                        signal.score_breakdown.sweep_quality * m_cfg.sweep_weight +
                        signal.score_breakdown.trap_quality * m_cfg.trap_weight +
                        signal.score_breakdown.reversal_quality * m_cfg.reversal_weight;

      signal.total_score = weighted;

      // Assign grade
      if(weighted >= m_cfg.a_plus_threshold)
         signal.grade = GRADE_A_PLUS;
      else if(weighted >= m_cfg.a_threshold)
         signal.grade = GRADE_A;
      else if(weighted >= m_cfg.b_threshold)
         signal.grade = GRADE_B;
      else if(weighted >= m_cfg.c_threshold)
         signal.grade = GRADE_C;
      else
         signal.grade = GRADE_D;

      // Set direction
      if(poi.direction == POI_BULLISH)
         signal.direction = SIGNAL_BUY;
      else
         signal.direction = SIGNAL_SELL;

      // Set entry from reversal
      if(reversal.valid)
         signal.entry_price = reversal.entry_price;
   }

   //--- Quick check if minimum requirements are met
   bool MeetsMinimumRequirements(const ReversalData &reversal,
                                 bool has_sweep_or_trap)
   {
      // Must have reversal confirmation
      if(!reversal.valid) return false;
      // Must have at least sweep or trap
      if(!has_sweep_or_trap) return false;
      return true;
   }
};

#endif
