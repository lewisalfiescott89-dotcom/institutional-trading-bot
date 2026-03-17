//+------------------------------------------------------------------+
//| InstitutionalBot.mq5 - Main Expert Advisor entry point           |
//| Institutional/Smart-Money Trading Bot for MetaTrader 5           |
//|                                                                  |
//| Multi-timeframe POI detection, liquidity mapping, sweep/trap     |
//| detection, reversal confirmation, and 5M execution.              |
//|                                                                  |
//| Author: lewis scott                                              |
//| Session: https://app.devin.ai/sessions/ee3c969062d34b788cb81a85fe281b33 |
//+------------------------------------------------------------------+
#property copyright "Institutional Trading Bot"
#property link      "https://app.devin.ai/sessions/ee3c969062d34b788cb81a85fe281b33"
#property version   "1.00"
#property description "Institutional/Smart-Money Trading EA"
#property description "Multi-timeframe POI + Liquidity + Sweep/Trap + Reversal"
#property description "Executes only on 5M chart with full institutional logic"

//--- Include the orchestrator (which includes everything else)
#include <InstitutionalBot/Core/Orchestrator.mqh>

//+------------------------------------------------------------------+
//| Input parameters                                                  |
//+------------------------------------------------------------------+
input group "=== General Settings ==="
input bool     InpDryRun           = false;    // Dry Run Mode (no real trades)
input ENUM_LOG_LEVEL InpLogLevel   = LOG_INFO;  // Log Level
input bool     InpRequireSweepTrap = false;     // Require sweep/trap (false=reversal only OK)
input bool     InpLongOnly         = false;     // Long only mode (disable short trades)
input bool     InpRequireFVG       = false;     // Require multi-TF FVG confluence (ICT method)
input bool     InpRequireOB        = false;     // Require Order Block confluence
input bool     InpRequireLiqConf   = false;     // Require liquidity pool confluence

input group "=== Symbols ==="
input string   InpSymbol1          = "XAUUSD";  // Symbol 1
input string   InpSymbol2          = "GBPUSD";  // Symbol 2
input string   InpSymbol3          = "EURUSD";  // Symbol 3
input string   InpSymbol4          = "US30";    // Symbol 4
input string   InpSymbol5          = "BTCUSD";  // Symbol 5
input int      InpSymbolCount      = 5;         // Number of symbols to trade (1-5)

input group "=== POI Settings ==="
input double   InpDisplacementMult = 1.5;       // Displacement ATR multiplier
input double   InpMinBodyRatio     = 0.6;       // Min body-to-range ratio
input double   InpFreshnessDecay   = 0.15;      // Freshness decay per touch

input group "=== FVG Settings ==="
input double   InpFVGMinRatio      = 0.3;       // Min FVG gap/ATR ratio
input double   InpFVGMaxRatio      = 5.0;       // Max FVG gap/ATR ratio

input group "=== Sweep Settings ==="
input double   InpMinPenetration   = 2.0;       // Min sweep penetration (pips)
input double   InpMinRejection     = 0.5;       // Min rejection ratio
input int      InpSweepLookback    = 20;        // Sweep lookback bars

input group "=== Trap Settings ==="
input double   InpTrapPenetration  = 3.0;       // Min trap penetration (pips)
input int      InpTrapConfirmBars  = 2;         // Trap confirmation bars
input double   InpMinTrapScore     = 3.0;       // Min trap score

input group "=== Reversal Settings ==="
input double   InpEngulfingRatio   = 1.0;       // Engulfing body ratio
input double   InpPinBarWickRatio  = 0.6;       // Pin bar wick ratio
input double   InpDispBodyRatio    = 0.7;       // Displacement body ratio
input double   InpMinRevQuality    = 2.5;       // Min reversal quality (higher = more selective)

input group "=== Session Settings (UTC hours) ==="
input int      InpAsianStart       = 0;         // Asian session start
input int      InpAsianEnd         = 8;         // Asian session end
input int      InpLondonStart      = 7;         // London session start
input int      InpLondonEnd        = 16;        // London session end
input int      InpNYStart          = 12;        // New York session start
input int      InpNYEnd            = 21;        // New York session end

input group "=== Grading Thresholds ==="
input double   InpAPlusThreshold   = 7.0;       // A+ grade threshold
input double   InpAThreshold       = 5.5;       // A grade threshold
input double   InpBThreshold       = 4.0;       // B grade threshold
input double   InpCThreshold       = 2.5;       // C grade threshold
input bool     InpAllowGradeD      = false;     // Allow Grade D trades (lowest quality)

input group "=== Risk Settings ==="
input double   InpAPlusRisk        = 2.0;       // A+ risk %
input double   InpARisk            = 1.0;       // A risk %
input double   InpBRisk            = 0.5;       // B risk %
input double   InpCRisk            = 0.25;      // C risk %
input double   InpMaxDailyDD       = 5.0;       // Max daily drawdown %
input int      InpMaxConsecLosses  = 5;         // Max consecutive losses
input double   InpDefaultSLPips    = 300.0;     // Default SL (pips) — 300×0.1=$30 for gold
input double   InpPartialTPPips    = 0;          // Partial TP distance: 0=auto (1:1 R:R), or fixed pips
input double   InpPartialClosePct  = 50.0;      // Partial close % (50 = close 50% at partial TP)

input group "=== Trade Frequency Controls ==="
input int      InpMaxTradesPerDay  = 5;         // Max trades per day (all symbols)
input int      InpCooldownBars     = 4;         // Min M5 bars between trades (4=20min)
input bool     InpRequireHTF       = false;      // Require D1 trend alignment (false=allow counter-trend trades)
input bool     InpRequireKZ        = false;      // Only trade during kill zones

input group "=== Diagnostic / ICT Enhancements ==="
input bool     InpUseMSS           = true;       // Use Market Structure Shift detection (ICT method)
input bool     InpFilterLowTFPOIs  = false;      // Skip M5/M15 POIs (focus on H1+ institutional levels)
input int      InpDiagInterval     = 200;        // Diagnostic summary interval (bars)

input group "=== Safety Settings ==="
input double   InpMaxSpread        = 5.0;       // Max spread (pips)
input double   InpMaxVolATR        = 500.0;     // Max volatility ATR (pips)

input group "=== Commission (Pepperstone Raw) ==="
input double   InpForexComm        = 7.0;       // Forex commission $/lot
input double   InpCommodityComm    = 0.000016;  // Commodity commission %
input double   InpCryptoComm       = 0.0004;    // Crypto commission %
input double   InpIndexComm        = 0.0;       // Index commission $/lot

//+------------------------------------------------------------------+
//| Global orchestrator instance                                      |
//+------------------------------------------------------------------+
COrchestrator orchestrator;

//+------------------------------------------------------------------+
//| Expert initialisation function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validate chart timeframe
   if(Period() != PERIOD_M5)
   {
      Alert("InstitutionalBot requires M5 chart! Current: " +
            TimeframeToString((ENUM_TIMEFRAMES)Period()));
      return INIT_FAILED;
   }

   // Set log level
   SetLogLevel(InpLogLevel);

   LogMessage(LOG_INFO, "INIT", "=== Institutional Trading Bot v1.00 ===");
   LogMessage(LOG_INFO, "INIT", StringFormat("Mode: %s", InpDryRun ? "DRY RUN" : "LIVE"));

   // Build symbol list
   string symbols[];
   int count = MathMin(InpSymbolCount, 5);
   ArrayResize(symbols, count);
   if(count >= 1) symbols[0] = InpSymbol1;
   if(count >= 2) symbols[1] = InpSymbol2;
   if(count >= 3) symbols[2] = InpSymbol3;
   if(count >= 4) symbols[3] = InpSymbol4;
   if(count >= 5) symbols[4] = InpSymbol5;

   // Validate symbols exist
   for(int i = 0; i < count; i++)
   {
      if(!SymbolSelect(symbols[i], true))
      {
         LogMessage(LOG_WARNING, "INIT",
            StringFormat("Symbol %s not available - will skip", symbols[i]));
      }
   }

   // Build configuration structs from inputs
   POISettings poi_cfg;
   poi_cfg.Init();
   poi_cfg.displacement_multiplier = InpDisplacementMult;
   poi_cfg.min_body_ratio          = InpMinBodyRatio;
   poi_cfg.freshness_decay_per_touch = InpFreshnessDecay;

   FVGSettings fvg_cfg;
   fvg_cfg.Init();
   fvg_cfg.min_gap_atr_ratio = InpFVGMinRatio;
   fvg_cfg.max_gap_atr_ratio = InpFVGMaxRatio;

   LiquiditySettings liq_cfg;
   liq_cfg.Init();

   SweepSettings sweep_cfg;
   sweep_cfg.Init();
   sweep_cfg.min_penetration_pips = InpMinPenetration;
   sweep_cfg.min_rejection_ratio  = InpMinRejection;
   sweep_cfg.lookback_bars        = InpSweepLookback;

   TrapSettings trap_cfg;
   trap_cfg.Init();
   trap_cfg.min_penetration_pips  = InpTrapPenetration;
   trap_cfg.confirmation_bars     = InpTrapConfirmBars;
   trap_cfg.min_trap_score        = InpMinTrapScore;

   ReversalSettings rev_cfg;
   rev_cfg.Init();
   rev_cfg.engulfing_ratio        = InpEngulfingRatio;
   rev_cfg.pin_bar_wick_ratio     = InpPinBarWickRatio;
   rev_cfg.displacement_body_ratio= InpDispBodyRatio;
   rev_cfg.min_reversal_quality   = InpMinRevQuality;

   SessionSettings sess_cfg;
   sess_cfg.Init();
   sess_cfg.asian_start_hour      = InpAsianStart;
   sess_cfg.asian_end_hour        = InpAsianEnd;
   sess_cfg.london_start_hour     = InpLondonStart;
   sess_cfg.london_end_hour       = InpLondonEnd;
   sess_cfg.ny_start_hour         = InpNYStart;
   sess_cfg.ny_end_hour           = InpNYEnd;

   TimingSettings tim_cfg;
   tim_cfg.Init();

   GradingSettings grade_cfg;
   grade_cfg.Init();
   grade_cfg.a_plus_threshold = InpAPlusThreshold;
   grade_cfg.a_threshold      = InpAThreshold;
   grade_cfg.b_threshold      = InpBThreshold;
   grade_cfg.c_threshold      = InpCThreshold;

   RiskSettings risk_cfg;
   risk_cfg.Init();
   risk_cfg.a_plus_risk_pct       = InpAPlusRisk;
   risk_cfg.a_risk_pct            = InpARisk;
   risk_cfg.b_risk_pct            = InpBRisk;
   risk_cfg.c_risk_pct            = InpCRisk;
   risk_cfg.max_daily_drawdown_pct= InpMaxDailyDD;
   risk_cfg.max_consecutive_losses= InpMaxConsecLosses;
   risk_cfg.default_sl_pips       = InpDefaultSLPips;
   risk_cfg.partial_tp_pips       = InpPartialTPPips;
   risk_cfg.partial_close_pct     = InpPartialClosePct / 100.0;  // Convert from % to decimal

   CommissionSettings comm_cfg;
   comm_cfg.Init();
   comm_cfg.forex_per_lot  = InpForexComm;
   comm_cfg.commodity_pct  = InpCommodityComm;
   comm_cfg.crypto_pct     = InpCryptoComm;
   comm_cfg.index_per_lot  = InpIndexComm;

   SafetySettings safe_cfg;
   safe_cfg.Init();
   safe_cfg.max_spread_pips         = InpMaxSpread;
   safe_cfg.max_volatility_atr_pips = InpMaxVolATR;
   safe_cfg.max_daily_drawdown_pct  = InpMaxDailyDD;
   safe_cfg.max_consecutive_losses  = InpMaxConsecLosses;

   // Configure and initialise orchestrator
   orchestrator.Configure(poi_cfg, fvg_cfg, liq_cfg, sweep_cfg, trap_cfg,
                          rev_cfg, sess_cfg, tim_cfg, grade_cfg, risk_cfg,
                          comm_cfg, safe_cfg);

   orchestrator.SetRequireSweepTrap(InpRequireSweepTrap);
   orchestrator.SetAllowGradeD(InpAllowGradeD);
   orchestrator.SetLongOnly(InpLongOnly);
   orchestrator.SetRequireFVG(InpRequireFVG);
   orchestrator.SetRequireOB(InpRequireOB);
   orchestrator.SetRequireLiqConf(InpRequireLiqConf);
   orchestrator.SetMaxTradesPerDay(InpMaxTradesPerDay);
   orchestrator.SetMinBarsBetweenTrades(InpCooldownBars);
   orchestrator.SetHTFMode(InpRequireHTF ? 2 : 0);  // 0=off, 2=block counter-trend
   orchestrator.SetRequireKillZone(InpRequireKZ);
   orchestrator.SetUseMSS(InpUseMSS);
   if(InpFilterLowTFPOIs)
      orchestrator.SetMinPOITimeframe(PERIOD_H1);
   else
      orchestrator.SetMinPOITimeframe(PERIOD_M5);
   orchestrator.SetDiagInterval(InpDiagInterval);

   if(!orchestrator.Init(symbols, count, InpDryRun))
   {
      LogMessage(LOG_ERROR, "INIT", "Failed to initialise orchestrator");
      return INIT_FAILED;
   }

   LogMessage(LOG_INFO, "INIT", "=== Initialisation complete ===");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   orchestrator.OnTick();
}

//+------------------------------------------------------------------+
//| Expert deinitialisation function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   string reason_str = "";
   switch(reason)
   {
      case REASON_PROGRAM:     reason_str = "Program ended"; break;
      case REASON_REMOVE:      reason_str = "EA removed"; break;
      case REASON_RECOMPILE:   reason_str = "Recompiled"; break;
      case REASON_CHARTCHANGE: reason_str = "Chart changed"; break;
      case REASON_CHARTCLOSE:  reason_str = "Chart closed"; break;
      case REASON_PARAMETERS:  reason_str = "Parameters changed"; break;
      case REASON_ACCOUNT:     reason_str = "Account changed"; break;
      default:                 reason_str = "Other"; break;
   }

   LogMessage(LOG_INFO, "DEINIT",
      StringFormat("Shutting down: %s (code=%d)", reason_str, reason));
}

//+------------------------------------------------------------------+
//| Tester function (for Strategy Tester)                             |
//+------------------------------------------------------------------+
double OnTester()
{
   // Return custom optimisation criterion
   // Can be modified for walk-forward analysis
   double profit = TesterStatistics(STAT_PROFIT);
   double dd     = TesterStatistics(STAT_EQUITY_DD_RELATIVE);
   double trades = TesterStatistics(STAT_TRADES);

   if(dd == 0 || trades < 10) return 0;

   // Profit factor weighted by trade count and drawdown
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   return pf * MathSqrt(trades) / (1.0 + dd);
}
//+------------------------------------------------------------------+
