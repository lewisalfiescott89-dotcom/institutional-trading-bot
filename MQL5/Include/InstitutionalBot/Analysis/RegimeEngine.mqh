//+------------------------------------------------------------------+
//| RegimeEngine.mqh - Market regime classification                  |
//| Classifies: trend, range, high-volatility, low-liquidity         |
//+------------------------------------------------------------------+
#ifndef REGIME_ENGINE_MQH
#define REGIME_ENGINE_MQH

#include "../Core/Utils.mqh"
#include "../Models/Regime.mqh"
#include "StructureEngine.mqh"
#include "../Config.mqh"

class CRegimeEngine
{
private:
   int m_atr_period;
   int m_atr_ma_period;
   double m_high_vol_threshold;
   double m_low_vol_threshold;

public:
   CRegimeEngine(int atr_period=14, int atr_ma=50,
                 double high_vol=1.5, double low_vol=0.5)
      : m_atr_period(atr_period), m_atr_ma_period(atr_ma),
        m_high_vol_threshold(high_vol), m_low_vol_threshold(low_vol) {}

   void Classify(const double &highs[], const double &lows[],
                 const double &closes[], const long &volumes[],
                 int bar_count, string symbol,
                 const StructureResult &structure,
                 MarketRegime &regime)
   {
      regime.Init();
      regime.symbol = symbol;

      if(bar_count < m_atr_ma_period + 10) return;

      // Compute ATR array
      double atr_arr[];
      ComputeATRArray(highs, lows, closes, m_atr_period, bar_count, atr_arr);

      double current_atr = atr_arr[bar_count - 1];
      regime.atr_value = current_atr;

      // ATR moving average
      double atr_sum = 0;
      int start = bar_count - m_atr_ma_period;
      if(start < 0) start = 0;
      int cnt = 0;
      for(int i = start; i < bar_count; i++)
      {
         if(atr_arr[i] > 0) { atr_sum += atr_arr[i]; cnt++; }
      }
      regime.atr_ma = (cnt > 0) ? atr_sum / cnt : current_atr;

      // Volatility ratio
      regime.volatility_ratio = (regime.atr_ma > 0) ? current_atr / regime.atr_ma : 1.0;

      // Volume ratio
      long vol_sum = 0;
      cnt = 0;
      for(int i = start; i < bar_count; i++)
      {
         vol_sum += volumes[i];
         cnt++;
      }
      double avg_vol = (cnt > 0) ? (double)vol_sum / cnt : 1.0;
      double cur_vol = (double)volumes[bar_count - 1];
      regime.volume_ratio = (avg_vol > 0) ? cur_vol / avg_vol : 1.0;

      // Classify regime
      if(regime.volatility_ratio >= m_high_vol_threshold)
         regime.regime = REGIME_HIGH_VOLATILITY;
      else if(regime.volume_ratio < 0.3 && regime.volatility_ratio < m_low_vol_threshold)
         regime.regime = REGIME_LOW_LIQUIDITY;
      else if(structure.bias != BIAS_NEUTRAL)
         regime.regime = REGIME_TREND;
      else
         regime.regime = REGIME_RANGE;

      // Trend bias from structure
      regime.trend_bias = structure.bias;

      // Confidence
      regime.confidence = MathMin(MathAbs(regime.volatility_ratio - 1.0) * 2.0, 1.0);
      if(regime.regime == REGIME_TREND)
         regime.confidence = MathMax(regime.confidence, 0.5);
   }
};

#endif
