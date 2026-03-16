//+------------------------------------------------------------------+
//| Config.mqh - Configuration settings for Institutional Bot        |
//+------------------------------------------------------------------+
#ifndef CONFIG_MQH
#define CONFIG_MQH

//--- Timeframe constants
#define TF_COUNT 7
ENUM_TIMEFRAMES AnalysisTimeframes[TF_COUNT] = {
   PERIOD_MN1, PERIOD_W1, PERIOD_D1, PERIOD_H4, PERIOD_H1, PERIOD_M15, PERIOD_M5
};
#define EXECUTION_TF PERIOD_M5

//--- Timeframe weights for scoring
double GetTimeframeWeight(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_MN1: return 10.0;
      case PERIOD_W1:  return 8.0;
      case PERIOD_D1:  return 6.0;
      case PERIOD_H4:  return 4.0;
      case PERIOD_H1:  return 3.0;
      case PERIOD_M15: return 2.0;
      case PERIOD_M5:  return 1.0;
      default:         return 1.0;
   }
}

string TimeframeToString(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_MN1: return "MN1";
      case PERIOD_W1:  return "W1";
      case PERIOD_D1:  return "D1";
      case PERIOD_H4:  return "H4";
      case PERIOD_H1:  return "H1";
      case PERIOD_M15: return "M15";
      case PERIOD_M5:  return "M5";
      default:         return "??";
   }
}

//+------------------------------------------------------------------+
//| POI Settings                                                      |
//+------------------------------------------------------------------+
struct POISettings
{
   double   displacement_multiplier;
   double   min_body_ratio;
   int      atr_period;
   double   cluster_overlap_pct;
   double   freshness_decay_per_touch;

   void Init()
   {
      displacement_multiplier   = 1.5;
      min_body_ratio            = 0.5;
      atr_period                = 14;
      cluster_overlap_pct       = 0.3;
      freshness_decay_per_touch = 0.15;
   }
};

//+------------------------------------------------------------------+
//| FVG Settings                                                      |
//+------------------------------------------------------------------+
struct FVGSettings
{
   double min_gap_atr_ratio;
   double max_gap_atr_ratio;

   void Init()
   {
      min_gap_atr_ratio = 0.3;
      max_gap_atr_ratio = 5.0;
   }
};

//+------------------------------------------------------------------+
//| Liquidity Settings                                                |
//+------------------------------------------------------------------+
struct LiquiditySettings
{
   int    swing_lookback;
   double equal_price_tolerance_pips;
   int    session_level_lookback_bars;

   void Init()
   {
      swing_lookback              = 5;
      equal_price_tolerance_pips  = 3.0;
      session_level_lookback_bars = 200;
   }
};

//+------------------------------------------------------------------+
//| Sweep Settings                                                    |
//+------------------------------------------------------------------+
struct SweepSettings
{
   double min_penetration_pips;
   double max_penetration_pips;
   double min_rejection_ratio;
   double max_distance_from_poi_pips;
   int    lookback_bars;

   void Init()
   {
      min_penetration_pips       = 1.0;
      max_penetration_pips       = 30.0;
      min_rejection_ratio        = 0.3;
      max_distance_from_poi_pips = 50.0;
      lookback_bars              = 20;
   }
};

//+------------------------------------------------------------------+
//| Trap Settings                                                     |
//+------------------------------------------------------------------+
struct TrapSettings
{
   double min_penetration_pips;
   int    confirmation_bars;
   int    lookback_bars;
   double min_trap_score;

   void Init()
   {
      min_penetration_pips = 2.0;
      confirmation_bars    = 2;
      lookback_bars        = 30;
      min_trap_score       = 3.0;
   }
};

//+------------------------------------------------------------------+
//| Reversal Settings                                                 |
//+------------------------------------------------------------------+
struct ReversalSettings
{
   double engulfing_ratio;
   double pin_bar_wick_ratio;
   double displacement_body_ratio;
   double min_reversal_quality;

   void Init()
   {
      engulfing_ratio         = 1.0;
      pin_bar_wick_ratio      = 0.6;
      displacement_body_ratio = 0.7;
      min_reversal_quality    = 3.0;
   }
};

//+------------------------------------------------------------------+
//| Session Settings (UTC hours and minutes)                          |
//+------------------------------------------------------------------+
struct SessionSettings
{
   int asian_start_hour;
   int asian_end_hour;
   int london_start_hour;
   int london_end_hour;
   int ny_start_hour;
   int ny_end_hour;
   int london_kz_start_hour;
   int london_kz_start_min;
   int london_kz_end_hour;
   int london_kz_end_min;
   int ny_kz_start_hour;
   int ny_kz_start_min;
   int ny_kz_end_hour;
   int ny_kz_end_min;

   void Init()
   {
      asian_start_hour     = 0;
      asian_end_hour       = 8;
      london_start_hour    = 7;
      london_end_hour      = 16;
      ny_start_hour        = 12;
      ny_end_hour          = 21;
      london_kz_start_hour = 7;
      london_kz_start_min  = 0;
      london_kz_end_hour   = 10;
      london_kz_end_min    = 0;
      ny_kz_start_hour     = 12;
      ny_kz_start_min      = 0;
      ny_kz_end_hour       = 15;
      ny_kz_end_min        = 0;
   }
};

//+------------------------------------------------------------------+
//| Timing Settings                                                   |
//+------------------------------------------------------------------+
struct TimingSettings
{
   int  stale_bars_threshold;
   bool weak_setup_outside_kz;

   void Init()
   {
      stale_bars_threshold    = 20;
      weak_setup_outside_kz   = true;
   }
};

//+------------------------------------------------------------------+
//| Grading Settings (thresholds and scoring weights)                 |
//+------------------------------------------------------------------+
struct GradingSettings
{
   double a_plus_threshold;
   double a_threshold;
   double b_threshold;
   double c_threshold;

   // Scoring weights
   double poi_weight;
   double cluster_weight;
   double liquidity_weight;
   double forecast_weight;
   double structure_weight;
   double regime_weight;
   double timing_weight;
   double sweep_weight;
   double trap_weight;
   double reversal_weight;
   double fvg_weight;
   double flip_weight;
   double ob_weight;         // Order block weight
   double bb_weight;         // Breaker block weight
   double liq_pool_weight;   // Liquidity pool confluence weight
   double void_weight;       // Liquidity void weight
   double stop_run_weight;   // Stop run weight

   void Init()
   {
      a_plus_threshold = 8.0;
      a_threshold      = 6.5;
      b_threshold      = 5.0;
      c_threshold      = 3.5;

      poi_weight       = 0.07;
      cluster_weight   = 0.05;
      liquidity_weight = 0.05;
      forecast_weight  = 0.05;
      structure_weight = 0.05;
      regime_weight    = 0.03;
      timing_weight    = 0.06;
      sweep_weight     = 0.06;
      trap_weight      = 0.03;
      reversal_weight  = 0.10;
      fvg_weight       = 0.10;   // Multi-TF FVG confluence
      flip_weight      = 0.08;   // Flip level bonus
      ob_weight        = 0.08;   // Order block confluence
      bb_weight        = 0.06;   // Breaker block confluence
      liq_pool_weight  = 0.07;   // Liquidity pool type confluence
      void_weight      = 0.03;   // Liquidity void bonus
      stop_run_weight  = 0.03;   // Stop run bonus
   }
};

//+------------------------------------------------------------------+
//| Risk Settings                                                     |
//+------------------------------------------------------------------+
struct RiskSettings
{
   double a_plus_risk_pct;
   double a_risk_pct;
   double b_risk_pct;
   double c_risk_pct;
   double max_daily_drawdown_pct;
   int    max_consecutive_losses;
   double default_sl_pips;

   void Init()
   {
      a_plus_risk_pct         = 2.00;
      a_risk_pct              = 1.00;
      b_risk_pct              = 0.50;
      c_risk_pct              = 0.25;
      max_daily_drawdown_pct  = 5.0;
      max_consecutive_losses  = 5;
      default_sl_pips         = 30.0;
   }
};

//+------------------------------------------------------------------+
//| Commission Settings (Pepperstone raw spread)                      |
//+------------------------------------------------------------------+
struct CommissionSettings
{
   double forex_per_lot;    // $7 per lot round-trip
   double commodity_pct;    // 0.0016% per lot
   double crypto_pct;       // 0.04% per lot
   double index_per_lot;    // $0

   void Init()
   {
      forex_per_lot  = 7.0;
      commodity_pct  = 0.000016;  // 0.0016%
      crypto_pct     = 0.0004;    // 0.04%
      index_per_lot  = 0.0;
   }
};

//+------------------------------------------------------------------+
//| Safety Settings                                                   |
//+------------------------------------------------------------------+
struct SafetySettings
{
   double max_spread_pips;
   double max_volatility_atr_pips;
   double max_daily_drawdown_pct;
   int    max_consecutive_losses;
   bool   emergency_pause;
   bool   abnormal_vol_filter;

   void Init()
   {
      max_spread_pips          = 5.0;
      max_volatility_atr_pips  = 500.0;
      max_daily_drawdown_pct   = 5.0;
      max_consecutive_losses   = 5;
      emergency_pause          = false;
      abnormal_vol_filter      = true;
   }
};

//+------------------------------------------------------------------+
//| Asset class enum                                                  |
//+------------------------------------------------------------------+
enum ENUM_ASSET_CLASS { ASSET_FOREX, ASSET_COMMODITY, ASSET_CRYPTO, ASSET_INDEX };

//+------------------------------------------------------------------+
//| Symbol Specification Helper                                       |
//+------------------------------------------------------------------+
struct SymbolSpec
{
   string           symbol;
   ENUM_ASSET_CLASS asset_class;
   double           pip_size;
   double           contract_size;
   double           default_sl_pips;
   double           max_spread_pips;
};

SymbolSpec GetSymbolSpec(string symbol)
{
   SymbolSpec spec;
   spec.symbol = symbol;

   if(symbol == "XAUUSD")
   {
      spec.asset_class    = ASSET_COMMODITY;
      spec.pip_size       = 0.1;
      spec.contract_size  = 100.0;
      spec.default_sl_pips= 30.0;
      spec.max_spread_pips= 5.0;
   }
   else if(symbol == "GBPUSD" || symbol == "EURUSD")
   {
      spec.asset_class    = ASSET_FOREX;
      spec.pip_size       = 0.0001;
      spec.contract_size  = 100000.0;
      spec.default_sl_pips= 30.0;
      spec.max_spread_pips= 2.0;
   }
   else if(symbol == "US30")
   {
      spec.asset_class    = ASSET_INDEX;
      spec.pip_size       = 1.0;
      spec.contract_size  = 1.0;
      spec.default_sl_pips= 30.0;
      spec.max_spread_pips= 5.0;
   }
   else if(symbol == "BTCUSD")
   {
      spec.asset_class    = ASSET_CRYPTO;
      spec.pip_size       = 1.0;
      spec.contract_size  = 1.0;
      spec.default_sl_pips= 300.0;
      spec.max_spread_pips= 50.0;
   }
   else
   {
      // Default forex-like
      spec.asset_class    = ASSET_FOREX;
      spec.pip_size       = 0.0001;
      spec.contract_size  = 100000.0;
      spec.default_sl_pips= 30.0;
      spec.max_spread_pips= 3.0;
   }
   return spec;
}

double PipsToPrice(string symbol, double pips)
{
   SymbolSpec spec = GetSymbolSpec(symbol);
   return pips * spec.pip_size;
}

double PriceToPips(string symbol, double price_distance)
{
   SymbolSpec spec = GetSymbolSpec(symbol);
   if(spec.pip_size <= 0) return 0;
   return price_distance / spec.pip_size;
}

#endif
