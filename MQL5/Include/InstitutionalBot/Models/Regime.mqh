//+------------------------------------------------------------------+
//| Regime.mqh - Market regime model                                 |
//+------------------------------------------------------------------+
#ifndef REGIME_MQH
#define REGIME_MQH

enum ENUM_REGIME_TYPE { REGIME_TREND, REGIME_RANGE, REGIME_HIGH_VOLATILITY, REGIME_LOW_LIQUIDITY };
enum ENUM_TREND_BIAS  { BIAS_BULLISH, BIAS_BEARISH, BIAS_NEUTRAL };

struct MarketRegime
{
   string           symbol;
   ENUM_REGIME_TYPE regime;
   ENUM_TREND_BIAS  trend_bias;
   double           atr_value;
   double           atr_ma;
   double           volatility_ratio;
   double           volume_ratio;
   double           confidence;

   void Init()
   {
      symbol           = "";
      regime           = REGIME_RANGE;
      trend_bias       = BIAS_NEUTRAL;
      atr_value        = 0;
      atr_ma           = 0;
      volatility_ratio = 1.0;
      volume_ratio     = 1.0;
      confidence       = 0;
   }

   bool IsTradeable() const { return regime != REGIME_LOW_LIQUIDITY; }

   double RiskMultiplier() const
   {
      if(regime == REGIME_HIGH_VOLATILITY) return 0.5;
      return 1.0;
   }
};

#endif
