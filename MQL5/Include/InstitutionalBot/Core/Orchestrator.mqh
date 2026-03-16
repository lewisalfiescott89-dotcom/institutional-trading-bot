//+------------------------------------------------------------------+
//| Orchestrator.mqh - 20-step execution cycle per M5 candle         |
//| Central controller that runs the complete analysis pipeline      |
//+------------------------------------------------------------------+
#ifndef ORCHESTRATOR_MQH
#define ORCHESTRATOR_MQH

#include "../Config.mqh"
#include "Utils.mqh"
#include "Logger.mqh"
#include "../Models/POI.mqh"
#include "../Models/Liquidity.mqh"
#include "../Models/Signal.mqh"
#include "../Models/Trade.mqh"
#include "../Models/Regime.mqh"
#include "../Models/State.mqh"
#include "../Analysis/StructureEngine.mqh"
#include "../Analysis/RegimeEngine.mqh"
#include "../Analysis/POIEngine.mqh"
#include "../Analysis/POIClusterEngine.mqh"
#include "../Analysis/FVGEngine.mqh"
#include "../Analysis/LiquidityMapEngine.mqh"
#include "../Analysis/LiquidityForecastEngine.mqh"
#include "../Analysis/SessionEngine.mqh"
#include "../Analysis/LiquidityTimingEngine.mqh"
#include "../Analysis/SweepEngine.mqh"
#include "../Analysis/TrapEngine.mqh"
#include "../Analysis/ReversalEngine.mqh"
#include "../Analysis/TradeQualityEngine.mqh"
#include "../Analysis/OrderBlockEngine.mqh"
#include "../Analysis/LiquidityPoolEngine.mqh"
#include "../Risk/RiskEngine.mqh"
#include "../Risk/CommissionEngine.mqh"
#include "../Risk/PositionSizer.mqh"
#include "../Execution/SafetyEngine.mqh"
#include "../Execution/TradeManager.mqh"
#include "../Execution/Executor.mqh"

//--- Maximum symbols to track
#define MAX_SYMBOLS 10

//--- Analysis timeframes (MN1, W1, D1, H4, H1, M15, M5)
#define NUM_ANALYSIS_TFS 7

class COrchestrator
{
private:
   //--- Engines
   CStructureEngine         m_structure;
   CRegimeEngine            m_regime;
   CPOIEngine               m_poi;
   CPOIClusterEngine        m_cluster;
   CFVGEngine               m_fvg;
   CLiquidityMapEngine      m_liquidity_map;
   CLiquidityForecastEngine m_liquidity_forecast;
   CSessionEngine           m_session;
   CLiquidityTimingEngine   m_timing;
   CSweepEngine             m_sweep;
   CTrapEngine              m_trap;
   CReversalEngine          m_reversal;
   CTradeQualityEngine      m_quality;
   COrderBlockEngine        m_ob_engine;
   CLiquidityPoolEngine     m_liq_pool_engine;
   CRiskEngine              m_risk;
   CCommissionEngine        m_commission;
   CPositionSizer           m_sizer;
   CSafetyEngine            m_safety;
   CTradeManager            m_trade_mgr;
   CExecutor                m_executor;

   //--- State
   SymbolState     m_states[MAX_SYMBOLS];
   GlobalRiskState m_risk_state;
   string          m_symbols[MAX_SYMBOLS];
   int             m_symbol_count;
   datetime        m_last_bar_time[MAX_SYMBOLS];
   int             m_last_day;

   //--- Analysis timeframes
   ENUM_TIMEFRAMES m_timeframes[NUM_ANALYSIS_TFS];

   //--- Bars to load per timeframe
   int m_bars_to_load;

   //--- Entry filter toggles
   bool m_require_sweep_trap;
   bool m_allow_grade_d;
   bool m_long_only;
   bool m_require_fvg;
   bool m_require_ob;
   bool m_require_liq_conf;

   //--- Diagnostic counters (reset each bar for logging)
   int m_diag_price_in_zone;
   int m_diag_has_reversal;
   int m_diag_has_sweep_trap;
   int m_diag_meets_minimum;
   int m_diag_timing_blocked;
   int m_diag_grade_d;
   int m_diag_safety_blocked;
   int m_diag_risk_blocked;

   //--- Cumulative diagnostics (for periodic logging)
   int m_total_bars_processed;
   int m_total_zone_hits;
   int m_total_reversals;
   int m_total_passed;
   int m_total_trades;

public:
   COrchestrator() : m_symbol_count(0), m_bars_to_load(500), m_last_day(-1),
                     m_require_sweep_trap(false), m_allow_grade_d(false), m_long_only(false),
                     m_require_fvg(false), m_require_ob(false), m_require_liq_conf(false),
                     m_total_bars_processed(0), m_total_zone_hits(0),
                     m_total_reversals(0), m_total_passed(0), m_total_trades(0)
   {
      m_timeframes[0] = PERIOD_MN1;
      m_timeframes[1] = PERIOD_W1;
      m_timeframes[2] = PERIOD_D1;
      m_timeframes[3] = PERIOD_H4;
      m_timeframes[4] = PERIOD_H1;
      m_timeframes[5] = PERIOD_M15;
      m_timeframes[6] = PERIOD_M5;
   }

   //--- Initialise with symbols and config
   bool Init(const string &symbols[], int count, bool dry_run = true)
   {
      m_symbol_count = MathMin(count, MAX_SYMBOLS);
      for(int i = 0; i < m_symbol_count; i++)
      {
         m_symbols[i] = symbols[i];
         m_states[i].Init();
         m_states[i].symbol = symbols[i];
         m_last_bar_time[i] = 0;
      }

      m_risk_state.Init();
      // NOTE: Do NOT set peak_equity here. During backtesting, AccountInfoDouble()
      // returns the REAL account equity at OnInit() time, not the backtest deposit.
      // peak_equity starts at 0 and gets set correctly on the first tick via the
      // update code: if(cur_equity > peak_equity) peak_equity = cur_equity;

      m_executor.SetDryRun(dry_run);
      m_trade_mgr.SetDryRun(dry_run);
      ResetDiagnostics();

      LogMessage(LOG_INFO, "ORCHESTRATOR",
         StringFormat("Initialised with %d symbols, dry_run=%s, require_sweep_trap=%s",
            m_symbol_count, dry_run ? "true" : "false",
            m_require_sweep_trap ? "true" : "false"));

      return true;
   }

   //--- Toggle sweep/trap requirement
   void SetRequireSweepTrap(bool require) { m_require_sweep_trap = require; }
   void SetAllowGradeD(bool allow) { m_allow_grade_d = allow; }
   void SetLongOnly(bool long_only) { m_long_only = long_only; }
   void SetRequireFVG(bool require) { m_require_fvg = require; }
   void SetRequireOB(bool require) { m_require_ob = require; }
   void SetRequireLiqConf(bool require) { m_require_liq_conf = require; }

   //--- Configure all engines
   void Configure(const POISettings &poi_cfg, const FVGSettings &fvg_cfg,
                  const LiquiditySettings &liq_cfg, const SweepSettings &sweep_cfg,
                  const TrapSettings &trap_cfg, const ReversalSettings &rev_cfg,
                  const SessionSettings &sess_cfg, const TimingSettings &tim_cfg,
                  const GradingSettings &grade_cfg, const RiskSettings &risk_cfg,
                  const CommissionSettings &comm_cfg, const SafetySettings &safe_cfg)
   {
      m_poi.SetConfig(poi_cfg);
      m_fvg.SetConfig(fvg_cfg);
      m_liquidity_map.SetConfig(liq_cfg);
      m_sweep.SetConfig(sweep_cfg);
      m_trap.SetConfig(trap_cfg);
      m_reversal.SetConfig(rev_cfg);
      m_session.SetConfig(sess_cfg);
      m_timing.SetConfig(tim_cfg);
      m_quality.SetConfig(grade_cfg);
      m_risk.SetConfig(risk_cfg);
      m_commission.SetConfig(comm_cfg);
      m_safety.SetConfig(safe_cfg);
      m_trade_mgr.SetCommissionEngine(comm_cfg);
      m_sizer.SetDefaultSLPips(risk_cfg.default_sl_pips);
   }

   //--- Main tick handler: run on every tick
   void OnTick()
   {
      // Check for new day - reset daily stats
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.day != m_last_day)
      {
         m_risk_state.ResetDaily();
         m_last_day = dt.day;
         for(int i = 0; i < m_symbol_count; i++)
         {
            m_session.ResetDailyLevels(m_states[i].session_state);
            m_states[i].recent_closed_count = 0;  // Reset so risk tracking stays active
         }
         LogMessage(LOG_INFO, "ORCHESTRATOR", "New day - risk state reset");
      }

      // Process each symbol
      for(int s = 0; s < m_symbol_count; s++)
      {
         ProcessSymbol(s);
      }
   }

private:
   //--- Process a single symbol through the 20-step cycle
   void ProcessSymbol(int sym_idx)
   {
      string symbol = m_symbols[sym_idx];

      // Check for new M5 bar
      datetime current_bar_time[];
      ArraySetAsSeries(current_bar_time, false);
      if(CopyTime(symbol, PERIOD_M5, 0, 1, current_bar_time) <= 0) return;
      if(current_bar_time[0] == m_last_bar_time[sym_idx]) return;  // Same bar
      m_last_bar_time[sym_idx] = current_bar_time[0];

      int si = sym_idx;  // index into m_states[]
      m_total_bars_processed++;

      // Periodic diagnostic log every 200 bars (always on, regardless of log level)
      if(m_total_bars_processed % 200 == 0)
      {
         Print(StringFormat("[DIAG] %s Bars=%d ZoneHits=%d Revs=%d Passed=%d Trades=%d | POIs=%d LIQ=%d",
            symbol, m_total_bars_processed, m_total_zone_hits, m_total_reversals,
            m_total_passed, m_total_trades,
            m_states[si].active_poi_count, m_states[si].active_liq_count));
      }

      // ================================================================
      // STEP 1: Sync MT5 data
      // ================================================================
      double m5_opens[], m5_highs[], m5_lows[], m5_closes[];
      long m5_volumes[];
      datetime m5_times[];
      int m5_count = LoadOHLCV(symbol, PERIOD_M5, m_bars_to_load,
                               m5_opens, m5_highs, m5_lows, m5_closes,
                               m5_volumes, m5_times);
      if(m5_count < 50)
      {
         LogMessage(LOG_WARNING, "ORCHESTRATOR",
            StringFormat("%s: Insufficient M5 data (%d bars)", symbol, m5_count));
         return;
      }

      // ================================================================
      // STEP 2: Refresh symbol state
      // ================================================================
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

      // ================================================================
      // STEP 3: Update higher timeframe analysis + detect POIs + FVGs
      // ================================================================
      POIData all_pois[];
      int total_pois = 0;
      ArrayResize(all_pois, MAX_POIS);

      // Multi-TF collection: FVGs, Order Blocks, Breaker Blocks, Liquidity Pools
      int total_fvgs = 0;
      m_states[si].all_fvg_count = 0;
      m_states[si].ob_count      = 0;
      m_states[si].bb_count      = 0;
      m_states[si].liq_pool_count = 0;

      for(int tf = 0; tf < NUM_ANALYSIS_TFS; tf++)
      {
         double tf_opens[], tf_highs[], tf_lows[], tf_closes[];
         long tf_volumes[];
         datetime tf_times[];
         int bars = (m_timeframes[tf] == PERIOD_MN1) ? 24 :
                    (m_timeframes[tf] == PERIOD_W1)  ? 52 :
                    (m_timeframes[tf] == PERIOD_D1)  ? 200 : m_bars_to_load;

         int tf_count = LoadOHLCV(symbol, m_timeframes[tf], bars,
                                  tf_opens, tf_highs, tf_lows, tf_closes,
                                  tf_volumes, tf_times);
         if(tf_count < 20) continue;

         // Detect POIs on this timeframe
         POIData tf_pois[];
         ArrayResize(tf_pois, 50);
         int poi_count = m_poi.DetectAll(tf_opens, tf_highs, tf_lows, tf_closes,
                                         tf_times, tf_count, symbol,
                                         m_timeframes[tf], tf_pois, 50);

         // Add to master POI list
         for(int p = 0; p < poi_count && total_pois < MAX_POIS; p++)
         {
            all_pois[total_pois] = tf_pois[p];
            total_pois++;
         }

         // Detect FVGs on this timeframe (multi-TF FVG detection)
         FVGData tf_fvgs[];
         ArrayResize(tf_fvgs, MAX_FVGS);
         int tf_fvg_count = m_fvg.Detect(tf_highs, tf_lows, tf_closes, tf_times,
                                          tf_count, symbol, m_timeframes[tf],
                                          tf_fvgs, MAX_FVGS);

         // Add to master FVG list
         for(int f = 0; f < tf_fvg_count && total_fvgs < MAX_ALL_FVGS; f++)
         {
            m_states[si].all_fvgs[total_fvgs] = tf_fvgs[f];
            total_fvgs++;
         }

         // Detect Order Blocks on this timeframe (multi-TF OB detection)
         OrderBlockData tf_obs[];
         ArrayResize(tf_obs, 50);
         int tf_ob_count = m_ob_engine.DetectOrderBlocks(
            tf_opens, tf_highs, tf_lows, tf_closes, tf_times, tf_count,
            symbol, m_timeframes[tf], tf_obs, 50);

         // Update OB status on this TF
         m_ob_engine.UpdateOBStatus(tf_obs, tf_ob_count,
                                     tf_highs, tf_lows, tf_closes, tf_count);

         // Add to master OB list (tagged with their timeframe)
         for(int ob = 0; ob < tf_ob_count && m_states[si].ob_count < MAX_ORDER_BLOCKS; ob++)
         {
            m_states[si].order_blocks[m_states[si].ob_count] = tf_obs[ob];
            m_states[si].ob_count++;
         }

         // Detect Breaker Blocks from broken OBs on this TF
         BreakerBlockData tf_bbs[];
         ArrayResize(tf_bbs, 30);
         int tf_bb_count = m_ob_engine.DetectBreakerBlocks(
            tf_obs, tf_ob_count, tf_closes, tf_times, tf_count, symbol,
            tf_bbs, 30);

         m_ob_engine.UpdateBBStatus(tf_bbs, tf_bb_count,
                                     tf_highs, tf_lows, tf_closes, tf_count);

         for(int bb = 0; bb < tf_bb_count && m_states[si].bb_count < MAX_BREAKER_BLOCKS; bb++)
         {
            m_states[si].breaker_blocks[m_states[si].bb_count] = tf_bbs[bb];
            m_states[si].bb_count++;
         }

         // Detect liquidity pools on this timeframe (multi-TF liquidity)
         LiquidityPoolData tf_pools[];
         ArrayResize(tf_pools, 100);
         int tf_pool_count = m_liq_pool_engine.BuildPools(
            tf_opens, tf_highs, tf_lows, tf_closes, tf_times, tf_count,
            symbol, m_timeframes[tf], tf_pools, 100);

         // Add OB/BB liquidity for this TF
         tf_pool_count = m_liq_pool_engine.AddOBLiquidity(
            tf_obs, tf_ob_count, symbol, m_timeframes[tf],
            tf_pools, tf_pool_count, 100);

         tf_pool_count = m_liq_pool_engine.AddBBLiquidity(
            tf_bbs, tf_bb_count, symbol, m_timeframes[tf],
            tf_pools, tf_pool_count, 100);

         for(int lp = 0; lp < tf_pool_count && m_states[si].liq_pool_count < MAX_LIQ_POOLS; lp++)
         {
            m_states[si].liq_pools[m_states[si].liq_pool_count] = tf_pools[lp];
            m_states[si].liq_pool_count++;
         }
      }
      m_states[si].all_fvg_count = total_fvgs;

      // Update FVG fill state against M5 price data (M5 is superset of all HTF action)
      m_fvg.UpdateFillState(m_states[si].all_fvgs, m_states[si].all_fvg_count,
                            m5_highs, m5_lows, m5_count);

      // Update swept status for all liquidity pools
      m_liq_pool_engine.UpdateSweptStatus(m_states[si].liq_pools, m_states[si].liq_pool_count,
                                           m5_highs[m5_count-1], m5_lows[m5_count-1]);

      // Detect liquidity voids on M5
      m_states[si].vacuum_count = m_liq_pool_engine.DetectVoids(
         m5_opens, m5_highs, m5_lows, m5_closes, m5_times, m5_count,
         symbol, PERIOD_M5, m_states[si].vacuum_blocks, MAX_VACUUM_BLOCKS);

      // Detect stop runs using all multi-TF pools
      m_states[si].stop_run_count = m_liq_pool_engine.DetectStopRuns(
         m5_opens, m5_highs, m5_lows, m5_closes, m5_times, m5_count,
         m_states[si].liq_pools, m_states[si].liq_pool_count,
         symbol, m_states[si].stop_runs, MAX_STOP_RUNS);

      // ================================================================
      // STEP 4: Project POIs to 5M chart
      // ================================================================
      m_poi.ProjectPOIs(all_pois, total_pois);

      // ================================================================
      // STEP 5: Cluster overlapping POIs
      // ================================================================
      total_pois = m_cluster.Cluster(all_pois, total_pois);

      // Update state POI list
      m_states[si].active_poi_count = MathMin(total_pois, MAX_POIS);
      for(int i = 0; i < m_states[si].active_poi_count; i++)
         m_states[si].active_pois[i] = all_pois[i];

      // ================================================================
      // STEP 6: Update liquidity map
      // ================================================================
      m_states[si].active_liq_count = m_liquidity_map.BuildMap(
         m5_opens, m5_highs, m5_lows, m5_closes, m5_times, m5_count,
         symbol, PERIOD_M5, m_states[si].active_liquidity, MAX_LIQUIDITY);

      // Update swept status
      m_liquidity_map.UpdateSweptStatus(m_states[si].active_liquidity,
         m_states[si].active_liq_count,
         m5_highs[m5_count-1], m5_lows[m5_count-1]);

      // ================================================================
      // STEP 7: Update liquidity forecast
      // ================================================================
      LiquidityForecast forecast;
      MarketRegime regime;

      // ================================================================
      // STEP 8: Update structure
      // ================================================================
      StructureResult structure;
      m_structure.Analyse(m5_opens, m5_highs, m5_lows, m5_closes,
                          m5_count, structure);

      // ================================================================
      // STEP 9: Update regime
      // ================================================================
      m_regime.Classify(m5_highs, m5_lows, m5_closes, m5_volumes,
                        m5_count, symbol, structure, regime);
      m_states[si].regime = regime;

      // Now build forecast (needs regime)
      m_liquidity_forecast.Forecast(m_states[si].active_liquidity, m_states[si].active_liq_count,
                                    bid, regime, forecast);
      m_states[si].forecast_price     = forecast.primary_target.price;
      m_states[si].forecast_direction = forecast.draw_is_above ? "ABOVE" : "BELOW";

      // ================================================================
      // STEP 10: Update session and timing
      // ================================================================
      m_session.Update(TimeCurrent(), m_states[si].session_state);
      m_session.TrackSessionLevels(m5_highs, m5_lows, m5_times, m5_count, m_states[si].session_state);
      m_states[si].session_name = m_states[si].session_state.session_name;
      m_states[si].in_kill_zone = m_states[si].session_state.in_kill_zone;

      // ================================================================
      // STEP 11: Mark POIs with multi-TF FVG confluence + flip levels
      // ================================================================
      // 11a: For each POI, check how many timeframes have overlapping unfilled FVGs
      for(int p = 0; p < m_states[si].active_poi_count; p++)
      {
         if(!m_states[si].active_pois[p].active) continue;

         int fvg_tf_hits = 0;
         ENUM_TIMEFRAMES counted_tfs[NUM_ANALYSIS_TFS];
         int counted_tf_count = 0;

         for(int f = 0; f < m_states[si].all_fvg_count; f++)
         {
            if(m_states[si].all_fvgs[f].fill_state == FVG_FULLY_FILLED) continue;

            // Check direction alignment
            bool dir_ok = (m_states[si].active_pois[p].direction == POI_BULLISH &&
                           m_states[si].all_fvgs[f].direction == FVG_BULLISH) ||
                          (m_states[si].active_pois[p].direction == POI_BEARISH &&
                           m_states[si].all_fvgs[f].direction == FVG_BEARISH);
            if(!dir_ok) continue;

            // Check zone overlap
            if(m_states[si].all_fvgs[f].gap_low <= m_states[si].active_pois[p].zone_high &&
               m_states[si].active_pois[p].zone_low <= m_states[si].all_fvgs[f].gap_high)
            {
               // Count unique timeframes
               bool already_counted = false;
               for(int c = 0; c < counted_tf_count; c++)
               {
                  if(counted_tfs[c] == m_states[si].all_fvgs[f].timeframe)
                  {
                     already_counted = true;
                     break;
                  }
               }
               if(!already_counted && counted_tf_count < NUM_ANALYSIS_TFS)
               {
                  counted_tfs[counted_tf_count] = m_states[si].all_fvgs[f].timeframe;
                  counted_tf_count++;
                  fvg_tf_hits++;
               }
            }
         }

         if(fvg_tf_hits > 0)
         {
            m_states[si].active_pois[p].has_fvg_confluence = true;
            m_states[si].active_pois[p].fvg_tf_count = fvg_tf_hits;
            m_states[si].active_pois[p].AddConfluence("multi_tf_fvg_x" + IntegerToString(fvg_tf_hits));
            // Also boost the POI score directly for FVG confluence
            m_states[si].active_pois[p].score += fvg_tf_hits * 2.0;
         }
      }

      // 11b: Detect flip levels (old support turned resistance / vice versa)
      FlipLevel flips[];
      ArrayResize(flips, MAX_FLIP_LEVELS);
      int flip_count = m_structure.DetectFlipLevels(m5_highs, m5_lows, m5_closes,
                                                     m5_count, flips, MAX_FLIP_LEVELS);

      // Mark POIs that sit at flip levels
      SymbolSpec spec_flip = GetSymbolSpec(symbol);
      double flip_tolerance = 10.0 * spec_flip.pip_size;  // 10 pip tolerance
      for(int p = 0; p < m_states[si].active_poi_count; p++)
      {
         if(!m_states[si].active_pois[p].active) continue;
         if(m_structure.IsNearFlipLevel(flips, flip_count,
               m_states[si].active_pois[p].zone_low,
               m_states[si].active_pois[p].zone_high, flip_tolerance))
         {
            m_states[si].active_pois[p].is_flip_level = true;
            m_states[si].active_pois[p].AddConfluence("flip_level");
            m_states[si].active_pois[p].score += 3.0;  // Flip level bonus
         }
      }

      // ================================================================
      // STEP 11c: Mark POIs with MULTI-TF OB/BB/liquidity confluence
      //           A level only counts as "multi-TF confluence" if it
      //           appears on M5 AND at least one higher timeframe.
      // ================================================================
      double ob_tol = 10.0 * spec_flip.pip_size;
      for(int p = 0; p < m_states[si].active_poi_count; p++)
      {
         if(!m_states[si].active_pois[p].active) continue;

         bool check_bull = (m_states[si].active_pois[p].direction == POI_BULLISH);
         double poi_lo = m_states[si].active_pois[p].zone_low;
         double poi_hi = m_states[si].active_pois[p].zone_high;

         // --- Multi-TF OB confluence: count unique TFs with OB overlapping this POI
         int ob_tf_hits = 0;
         bool ob_has_m5 = false;
         bool ob_has_htf = false;
         ENUM_TIMEFRAMES ob_counted_tfs[NUM_ANALYSIS_TFS];
         int ob_counted_tf_count = 0;

         for(int ob = 0; ob < m_states[si].ob_count; ob++)
         {
            if(!m_states[si].order_blocks[ob].active) continue;
            if(check_bull && m_states[si].order_blocks[ob].direction != OB_BULLISH) continue;
            if(!check_bull && m_states[si].order_blocks[ob].direction != OB_BEARISH) continue;

            // Check zone overlap
            if(m_states[si].order_blocks[ob].zone_low - ob_tol <= poi_hi &&
               poi_lo <= m_states[si].order_blocks[ob].zone_high + ob_tol)
            {
               // Count unique timeframes
               ENUM_TIMEFRAMES ob_tf = m_states[si].order_blocks[ob].timeframe;
               bool already = false;
               for(int c = 0; c < ob_counted_tf_count; c++)
               {
                  if(ob_counted_tfs[c] == ob_tf) { already = true; break; }
               }
               if(!already && ob_counted_tf_count < NUM_ANALYSIS_TFS)
               {
                  ob_counted_tfs[ob_counted_tf_count] = ob_tf;
                  ob_counted_tf_count++;
                  ob_tf_hits++;
                  if(ob_tf == PERIOD_M5) ob_has_m5 = true;
                  else                   ob_has_htf = true;
               }
            }
         }

         // OB confluence requires M5 + at least 1 higher TF
         if(ob_has_m5 && ob_has_htf)
         {
            m_states[si].active_pois[p].has_ob_confluence = true;
            m_states[si].active_pois[p].AddConfluence("multi_tf_ob_x" + IntegerToString(ob_tf_hits));
            m_states[si].active_pois[p].score += ob_tf_hits * 2.0;
         }
         else if(ob_tf_hits > 0)
         {
            // Single-TF OB still gives partial credit
            m_states[si].active_pois[p].has_ob_confluence = true;
            m_states[si].active_pois[p].AddConfluence("single_tf_ob");
            m_states[si].active_pois[p].score += 1.5;
         }

         // --- Multi-TF BB confluence: count unique TFs with BB overlapping
         int bb_tf_hits = 0;
         bool bb_has_m5 = false;
         bool bb_has_htf = false;
         ENUM_TIMEFRAMES bb_counted_tfs[NUM_ANALYSIS_TFS];
         int bb_counted_tf_count = 0;

         for(int bb = 0; bb < m_states[si].bb_count; bb++)
         {
            if(!m_states[si].breaker_blocks[bb].active) continue;
            if(check_bull && m_states[si].breaker_blocks[bb].direction != OB_BULLISH) continue;
            if(!check_bull && m_states[si].breaker_blocks[bb].direction != OB_BEARISH) continue;

            if(m_states[si].breaker_blocks[bb].zone_low - ob_tol <= poi_hi &&
               poi_lo <= m_states[si].breaker_blocks[bb].zone_high + ob_tol)
            {
               ENUM_TIMEFRAMES bb_tf = m_states[si].breaker_blocks[bb].timeframe;
               bool already = false;
               for(int c = 0; c < bb_counted_tf_count; c++)
               {
                  if(bb_counted_tfs[c] == bb_tf) { already = true; break; }
               }
               if(!already && bb_counted_tf_count < NUM_ANALYSIS_TFS)
               {
                  bb_counted_tfs[bb_counted_tf_count] = bb_tf;
                  bb_counted_tf_count++;
                  bb_tf_hits++;
                  if(bb_tf == PERIOD_M5) bb_has_m5 = true;
                  else                   bb_has_htf = true;
               }
            }
         }

         if(bb_has_m5 && bb_has_htf)
         {
            m_states[si].active_pois[p].has_bb_confluence = true;
            m_states[si].active_pois[p].AddConfluence("multi_tf_bb_x" + IntegerToString(bb_tf_hits));
            m_states[si].active_pois[p].score += bb_tf_hits * 1.5;
         }
         else if(bb_tf_hits > 0)
         {
            m_states[si].active_pois[p].has_bb_confluence = true;
            m_states[si].active_pois[p].AddConfluence("single_tf_bb");
            m_states[si].active_pois[p].score += 1.0;
         }

         // --- Multi-TF Liquidity Pool confluence:
         //     Count unique (pool_type, timeframe) pairs near this POI.
         //     A pool type that appears on M5 + higher TF = multi-TF confluence
         int pool_types_with_multi_tf = 0;
         int total_nearby_pools = 0;

         // Check each pool type for multi-TF presence
         for(int pt = 0; pt < 15; pt++)  // 15 ENUM_LIQ_POOL_TYPE values
         {
            ENUM_LIQ_POOL_TYPE pool_type = (ENUM_LIQ_POOL_TYPE)pt;
            bool has_on_m5 = false;
            bool has_on_htf = false;

            for(int lp = 0; lp < m_states[si].liq_pool_count; lp++)
            {
               if(!m_states[si].liq_pools[lp].active || m_states[si].liq_pools[lp].swept) continue;
               if(m_states[si].liq_pools[lp].pool_type != pool_type) continue;

               // Check if this pool's price is near the POI zone
               if(m_states[si].liq_pools[lp].price >= poi_lo - ob_tol &&
                  m_states[si].liq_pools[lp].price <= poi_hi + ob_tol)
               {
                  total_nearby_pools++;
                  if(m_states[si].liq_pools[lp].timeframe == PERIOD_M5)
                     has_on_m5 = true;
                  else
                     has_on_htf = true;
               }
            }

            if(has_on_m5 && has_on_htf)
               pool_types_with_multi_tf++;
         }

         m_states[si].active_pois[p].liq_pool_type_count = total_nearby_pools;
         if(pool_types_with_multi_tf > 0)
         {
            m_states[si].active_pois[p].AddConfluence("multi_tf_liq_x" + IntegerToString(pool_types_with_multi_tf));
            m_states[si].active_pois[p].score += pool_types_with_multi_tf * 1.5;
         }
         else if(total_nearby_pools > 0)
         {
            m_states[si].active_pois[p].AddConfluence("liq_pools_x" + IntegerToString(total_nearby_pools));
         }

         // Check vacuum/void confluence
         for(int v = 0; v < m_states[si].vacuum_count; v++)
         {
            if(m_states[si].vacuum_blocks[v].filled) continue;
            if(m_states[si].vacuum_blocks[v].zone_low <= poi_hi &&
               poi_lo <= m_states[si].vacuum_blocks[v].zone_high)
            {
               m_states[si].active_pois[p].has_void_confluence = true;
               m_states[si].active_pois[p].AddConfluence("liquidity_void");
               break;
            }
         }

         // Check stop run confluence (recent stop run near this POI)
         for(int sr = 0; sr < m_states[si].stop_run_count; sr++)
         {
            double sr_price = m_states[si].stop_runs[sr].swept_level;
            if(sr_price >= poi_lo - ob_tol && sr_price <= poi_hi + ob_tol)
            {
               m_states[si].active_pois[p].has_stop_run = true;
               m_states[si].active_pois[p].AddConfluence("stop_run");
               m_states[si].active_pois[p].score += 2.0;
               break;
            }
         }
      }

      // ================================================================
      // STEP 12-15: Check each active POI for trade signals
      // ================================================================
      bool traded_this_bar = false;  // Only one trade per bar per symbol
      for(int p = 0; p < m_states[si].active_poi_count; p++)
      {
         if(traded_this_bar) break;  // One trade per bar limit
         if(!m_states[si].active_pois[p].active || m_states[si].active_pois[p].invalidated) continue;

         // Max 2 concurrent open positions per symbol
         if(m_states[si].open_trade_count >= 2) break;

         double last_close = m5_closes[m5_count - 1];
         double last_open  = m5_opens[m5_count - 1];
         double last_high  = m5_highs[m5_count - 1];
         double last_low   = m5_lows[m5_count - 1];

         // Also check previous completed bar (critical for "Open prices only" mode
         // where bar 0 has O=H=L=C=open price, missing intra-bar range)
         double prev_high = (m5_count >= 2) ? m5_highs[m5_count - 2] : last_high;
         double prev_low  = (m5_count >= 2) ? m5_lows[m5_count - 2]  : last_low;
         double prev_close= (m5_count >= 2) ? m5_closes[m5_count - 2] : last_close;

         // STEP 11a: Check zone invalidation (Pepperstone 5M rule)
         if(m_states[si].active_pois[p].wick_probe_pending)
         {
            // Previous bar had a wick probe - check if THIS bar opens past the zone
            if(m_states[si].active_pois[p].direction == POI_BEARISH && last_open > m_states[si].active_pois[p].zone_high)
            {
               m_states[si].active_pois[p].Invalidate();
               LogMessage(LOG_INFO, "INVALIDATION",
                  StringFormat("%s POI #%d blown - candle opened above zone", symbol, m_states[si].active_pois[p].id));
               continue;
            }
            else if(m_states[si].active_pois[p].direction == POI_BULLISH && last_open < m_states[si].active_pois[p].zone_low)
            {
               m_states[si].active_pois[p].Invalidate();
               LogMessage(LOG_INFO, "INVALIDATION",
                  StringFormat("%s POI #%d blown - candle opened below zone", symbol, m_states[si].active_pois[p].id));
               continue;
            }
            m_states[si].active_pois[p].wick_probe_pending = false;
         }

         // Check if price is in the zone (current bar + previous completed bar)
         bool price_in_zone = m_states[si].active_pois[p].ContainsPrice(last_close) ||
                              m_states[si].active_pois[p].ContainsPrice(last_low) ||
                              m_states[si].active_pois[p].ContainsPrice(last_high) ||
                              m_states[si].active_pois[p].ContainsPrice(prev_high) ||
                              m_states[si].active_pois[p].ContainsPrice(prev_low) ||
                              m_states[si].active_pois[p].ContainsPrice(prev_close);

         if(!price_in_zone) continue;

         // Track wick probe for next bar evaluation
         if(m_states[si].active_pois[p].direction == POI_BEARISH && last_high > m_states[si].active_pois[p].zone_high && last_close <= m_states[si].active_pois[p].zone_high)
         {
            m_states[si].active_pois[p].wick_probe_pending   = true;
            m_states[si].active_pois[p].wick_probe_bar_index = m5_count - 1;
         }
         else if(m_states[si].active_pois[p].direction == POI_BULLISH && last_low < m_states[si].active_pois[p].zone_low && last_close >= m_states[si].active_pois[p].zone_low)
         {
            m_states[si].active_pois[p].wick_probe_pending   = true;
            m_states[si].active_pois[p].wick_probe_bar_index = m5_count - 1;
         }

         // Record touch
         m_states[si].active_pois[p].RecordTouch();
         m_poi.UpdateFreshness(m_states[si].active_pois[p]);

         // STEP 12: Detect sweep
         SweepData sweeps[];
         ArrayResize(sweeps, MAX_SWEEPS);
         int sweep_count = m_sweep.Detect(m5_opens, m5_highs, m5_lows, m5_closes,
                                          m5_times, m5_count,
                                          m_states[si].active_liquidity, m_states[si].active_liq_count,
                                          symbol, sweeps, MAX_SWEEPS);

         bool has_sweep = false;
         SweepData best_sweep;
         best_sweep.Init();
         for(int sw = 0; sw < sweep_count; sw++)
         {
            if(sweeps[sw].valid && m_sweep.SweepNearPOI(sweeps[sw], m_states[si].active_pois[p], regime.atr_value * 2))
            {
               if(sweeps[sw].score > best_sweep.score)
               {
                  best_sweep = sweeps[sw];
                  has_sweep = true;
               }
            }
         }

         // STEP 12b: Detect trap
         TrapData traps[];
         ArrayResize(traps, MAX_TRAPS);
         int trap_count = m_trap.Detect(m5_opens, m5_highs, m5_lows, m5_closes,
                                        m5_times, m5_count,
                                        m_states[si].active_liquidity, m_states[si].active_liq_count,
                                        symbol, traps, MAX_TRAPS);

         bool has_trap = false;
         TrapData best_trap;
         best_trap.Init();
         for(int t = 0; t < trap_count; t++)
         {
            if(traps[t].valid && traps[t].score > best_trap.score)
            {
               best_trap = traps[t];
               has_trap = true;
            }
         }

         // Long-only filter: skip bearish POIs if enabled
         if(m_long_only && m_states[si].active_pois[p].direction == POI_BEARISH)
            continue;

         // FVG confluence gate: if required, skip POIs without multi-TF FVG overlap
         if(m_require_fvg && !m_states[si].active_pois[p].has_fvg_confluence)
         {
            LogMessage(LOG_INFO, "FILTER",
               StringFormat("%s POI#%d no multi-TF FVG confluence - skipped",
                  symbol, m_states[si].active_pois[p].id));
            continue;
         }

         // OB confluence gate: if required, skip POIs without order block overlap
         if(m_require_ob && !m_states[si].active_pois[p].has_ob_confluence)
         {
            LogMessage(LOG_INFO, "FILTER",
               StringFormat("%s POI#%d no OB confluence - skipped",
                  symbol, m_states[si].active_pois[p].id));
            continue;
         }

         // Liquidity pool confluence gate: require at least 2 pool types overlapping
         if(m_require_liq_conf && m_states[si].active_pois[p].liq_pool_type_count < 2)
         {
            LogMessage(LOG_INFO, "FILTER",
               StringFormat("%s POI#%d insufficient liq pool confluence (%d types) - skipped",
                  symbol, m_states[si].active_pois[p].id,
                  m_states[si].active_pois[p].liq_pool_type_count));
            continue;
         }

         // STEP 13: Detect reversal candle on recent COMPLETED bars
         //   m5_count-1 = current forming bar (skip - incomplete candle)
         //   m5_count-2 = last completed bar
         //   Check last 3 completed bars for best reversal
         bool look_for_bullish = (m_states[si].active_pois[p].direction == POI_BULLISH);
         ReversalData rev;
         rev.Init();
         for(int rb = 2; rb <= 6 && rb < m5_count; rb++)
         {
            ReversalData candidate;
            m_reversal.DetectAt(m5_opens, m5_highs, m5_lows, m5_closes, m5_times,
                                m5_count, m5_count - rb, look_for_bullish, candidate);
            if(candidate.valid && candidate.quality > rev.quality)
               rev = candidate;
            // Also accept detected-but-below-threshold if nothing valid yet
            if(!rev.valid && candidate.type != REV_NONE && candidate.quality > rev.quality)
               rev = candidate;
         }

         // Check reversal
         bool has_reversal = rev.valid;
         bool has_sweep_or_trap = has_sweep || has_trap;

         // Diagnostic tracking
         m_diag_price_in_zone++;
         m_total_zone_hits++;
         if(has_reversal) { m_diag_has_reversal++; m_total_reversals++; }
         if(has_sweep_or_trap) m_diag_has_sweep_trap++;

         // Minimum requirements gate
         if(!has_reversal)
         {
            // No reversal = no trade regardless
            continue;
         }

         if(m_require_sweep_trap && !has_sweep_or_trap)
         {
            // Strict mode: need sweep/trap too
            LogMessage(LOG_INFO, "FILTER",
               StringFormat("%s POI#%d reversal found but no sweep/trap (strict mode)",
                  symbol, m_states[si].active_pois[p].id));
            continue;
         }

         m_diag_meets_minimum++;
         m_total_passed++;

         // If no sweep/trap, reduce the signal score slightly
         if(!has_sweep_or_trap)
         {
            LogMessage(LOG_INFO, "ENTRY",
               StringFormat("%s POI#%d reversal-only entry (no sweep/trap)",
                  symbol, m_states[si].active_pois[p].id));
         }

         // STEP 14: Score setup quality
         // Find nearest opposing liquidity for TP
         LiquidityLevel nearest_liq;
         nearest_liq.Init();
         bool has_nearest_liq = FindNearestOpposingLiquidity(
            m_states[si].active_liquidity, m_states[si].active_liq_count,
            bid, m_states[si].active_pois[p].direction, nearest_liq);

         // Evaluate timing
         TimingResult timing;
         m_timing.Evaluate(m_states[si].session_state, m_states[si].active_pois[p].score, 0, timing);

         // Build signal
         SignalData signal;
         m_quality.ScoreSetup(m_states[si].active_pois[p], false, 0,
                              nearest_liq, has_nearest_liq,
                              forecast, structure, regime, timing,
                              best_sweep, has_sweep,
                              best_trap, has_trap, rev,
                              m_states[si].active_pois[p].has_fvg_confluence,
                              m_states[si].active_pois[p].fvg_tf_count,
                              m_states[si].active_pois[p].is_flip_level,
                              m_states[si].active_pois[p].has_ob_confluence,
                              m_states[si].active_pois[p].has_bb_confluence,
                              m_states[si].active_pois[p].liq_pool_type_count,
                              m_states[si].active_pois[p].has_void_confluence,
                              m_states[si].active_pois[p].has_stop_run,
                              signal);

         // Check timing allows trade
         m_timing.Evaluate(m_states[si].session_state, signal.total_score, 0, timing);
         if(!timing.allow_trade)
         {
            m_diag_timing_blocked++;
            LogMessage(LOG_INFO, "TIMING",
               StringFormat("%s POI#%d blocked: %s (score=%.1f)", symbol, m_states[si].active_pois[p].id, timing.reason, signal.total_score));
            continue;
         }

         // Grade D = no trade (unless allowed)
         if(signal.grade == GRADE_D && !m_allow_grade_d)
         {
            m_diag_grade_d++;
            LogMessage(LOG_INFO, "QUALITY",
               StringFormat("%s POI#%d grade D - skipped (score=%.1f)",
                  symbol, m_states[si].active_pois[p].id, signal.total_score));
            continue;
         }

         // ================================================================
         // STEP 15: Safety checks
         // ================================================================
         SafetyCheckResult safety;
         m_safety.Check(symbol, m_risk_state, safety);
         if(!safety.passed)
         {
            m_diag_safety_blocked++;
            LogMessage(LOG_WARNING, "SAFETY",
               StringFormat("%s VETOED: %s", symbol, safety.veto_reason));
            continue;
         }

         // ================================================================
         // STEP 16: Calculate risk and position size
         // ================================================================
         RiskResult risk_result;
         double equity = AccountInfoDouble(ACCOUNT_EQUITY);
         m_risk.CalculateRisk(signal, regime,
                              m_risk_state.daily_pnl,
                              m_risk_state.daily_drawdown,
                              m_risk_state.consecutive_losses,
                              equity, risk_result);

         if(!risk_result.allow_trade)
         {
            m_diag_risk_blocked++;
            LogMessage(LOG_INFO, "RISK",
               StringFormat("%s blocked: %s", symbol, risk_result.reason));
            continue;
         }

         // Calculate SL and TP using ACTUAL entry price (current market),
         // not rev.entry_price which is the close of a bar 2-4 bars ago.
         // The Executor fills at current ask (buy) or bid (sell), so SL/TP
         // must be offset from that price to maintain correct R:R.
         bool is_buy = (signal.direction == SIGNAL_BUY);
         double entry_price = is_buy ? ask : bid;

         // Smart SL: use POI zone boundary + buffer if tighter than default
         double default_sl = m_sizer.DefaultSLPrice(symbol, entry_price, is_buy);
         double poi_sl = 0;
         SymbolSpec spec_sl = GetSymbolSpec(symbol);
         double sl_buffer = 5.0 * spec_sl.pip_size;  // 5 pip buffer beyond zone
         if(is_buy)
            poi_sl = m_states[si].active_pois[p].zone_low - sl_buffer;
         else
            poi_sl = m_states[si].active_pois[p].zone_high + sl_buffer;

         // Use POI-based SL if it's tighter (closer to entry) than default
         double sl_price;
         if(is_buy)
            sl_price = MathMax(poi_sl, default_sl);  // Higher = tighter for buys
         else
            sl_price = MathMin(poi_sl, default_sl);  // Lower = tighter for sells

         // Safety: ensure SL is at least 10 pips from entry
         double min_sl_dist = 10.0 * spec_sl.pip_size;
         if(MathAbs(entry_price - sl_price) < min_sl_dist)
            sl_price = default_sl;  // Fall back to default if POI SL too tight

         double tp_price = 0;
         if(has_nearest_liq)
            tp_price = m_sizer.TPFromLiquidity(entry_price, nearest_liq.price, is_buy);

         // Guarantee a TP exists — use 3:1 R:R if no liquidity target found
         double sl_dist = MathAbs(entry_price - sl_price);
         if(tp_price == 0 || MathAbs(tp_price - entry_price) < sl_dist * 2.0)
         {
            // No TP or TP too close — set to 3:1 R:R minimum
            if(is_buy)
               tp_price = entry_price + sl_dist * 3.0;
            else
               tp_price = entry_price - sl_dist * 3.0;
         }

         // Position size
         SizeResult size;
         double cur_equity = AccountInfoDouble(ACCOUNT_EQUITY);

         // Minimum equity floor - don't trade if account is too depleted
         if(cur_equity < 500.0)
         {
            LogMessage(LOG_WARNING, "SIZER",
               StringFormat("%s equity too low (%.2f) - stopping trades", symbol, cur_equity));
            traded_this_bar = true;
            break;
         }

         m_sizer.Calculate(symbol, cur_equity,
                           risk_result.risk_pct, entry_price, sl_price, size);

         // Cap lot size to prevent blowing account
         if(size.lot_size > 1.0)
            size.lot_size = 1.0;

         // Use MT5's OrderCalcMargin for accurate margin calculation
         ENUM_ORDER_TYPE order_type = is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         double margin_needed = 0;
         double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
         double min_vol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
         double vol_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
         if(vol_step <= 0) vol_step = 0.01;

         if(OrderCalcMargin(order_type, symbol, size.lot_size, entry_price, margin_needed))
         {
            // Need at least 20% buffer above margin requirement
            if(free_margin < margin_needed * 1.2)
            {
               // Scale down: what lot size can we afford?
               double ratio = (free_margin * 0.8) / margin_needed;
               double affordable = size.lot_size * ratio;
               affordable = MathFloor(affordable / vol_step) * vol_step;
               affordable = NormalizeDouble(affordable, 2);

               if(affordable < min_vol)
               {
                  LogMessage(LOG_WARNING, "SIZER",
                     StringFormat("%s can't afford min lot (free=%.2f need=%.2f)",
                        symbol, free_margin, margin_needed));
                  traded_this_bar = true;  // Stop trying this bar
                  break;
               }
               size.lot_size = affordable;
            }
         }
         else
         {
            // OrderCalcMargin failed — fallback: use 50% of free margin max
            // For XAUUSD, 1 lot ~= $5100 margin at 1:100 leverage
            double safe_lots = (free_margin * 0.5) / (entry_price * 100.0 /
               MathMax((double)AccountInfoInteger(ACCOUNT_LEVERAGE), 100.0));
            safe_lots = MathFloor(safe_lots / vol_step) * vol_step;
            safe_lots = NormalizeDouble(safe_lots, 2);
            if(safe_lots < min_vol)
            {
               LogMessage(LOG_WARNING, "SIZER",
                  StringFormat("%s margin calc failed, can't afford trade", symbol));
               traded_this_bar = true;
               break;
            }
            size.lot_size = MathMin(size.lot_size, safe_lots);
         }

         // Final sanity: lot size must be >= minimum and properly rounded
         size.lot_size = MathMax(min_vol, size.lot_size);
         size.lot_size = NormalizeDouble(size.lot_size, 2);

         // ================================================================
         // STEP 17: Execute trade
         // ================================================================
         TradeData trade;
         bool executed = m_executor.Execute(signal, symbol, size.lot_size,
                                            sl_price, tp_price, trade);

         // ALWAYS mark traded_this_bar after any execution attempt
         // This prevents hammering the server with repeated failed orders
         traded_this_bar = true;

         if(executed)
         {
            // Add to open trades
            if(m_states[si].open_trade_count < MAX_TRADES)
            {
               m_states[si].open_trades[m_states[si].open_trade_count] = trade;
               m_states[si].open_trade_count++;
            }

            m_risk_state.total_trades_today++;
            m_total_trades++;

            LogSignal(symbol, GradeToString(signal.grade),
                      signal.total_score,
                      is_buy ? "BUY" : "SELL");
         }
         else
         {
            LogMessage(LOG_WARNING, "EXECUTOR",
               StringFormat("%s trade failed (lots=%.2f free=%.2f) - skipping bar",
                  symbol, size.lot_size, free_margin));
         }
      }

      // ================================================================
      // STEP 18: Manage open trades
      // ================================================================
      int prev_closed_count = m_states[si].recent_closed_count;
      m_trade_mgr.UpdateTrades(m_states[si], bid, ask);

      // Update risk state from NEWLY closed trades only
      for(int i = prev_closed_count; i < m_states[si].recent_closed_count; i++)
      {
         m_risk_state.daily_pnl += m_states[si].recent_closed[i].net_pnl;
         if(m_states[si].recent_closed[i].status == STATUS_CLOSED_LOSS)
            m_risk_state.consecutive_losses++;
         else if(m_states[si].recent_closed[i].status == STATUS_CLOSED_WIN)
            m_risk_state.consecutive_losses = 0;
      }

      // Update daily drawdown using ACCOUNT_BALANCE as baseline (not stored peak).
      // In MT5 backtesting, ACCOUNT_EQUITY can return real-account values,
      // but ACCOUNT_BALANCE always reflects the backtest deposit + closed PnL.
      // Drawdown = floating unrealised loss as % of balance.
      double cur_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double cur_equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      if(cur_balance > 0 && cur_equity < cur_balance)
         m_risk_state.daily_drawdown = (cur_balance - cur_equity) / cur_balance * 100.0;
      else
         m_risk_state.daily_drawdown = 0;
      // Keep peak_equity updated for informational purposes
      if(cur_equity > m_risk_state.peak_equity)
         m_risk_state.peak_equity = cur_equity;

      // ================================================================
      // STEP 19: Save state (via global variables for persistence)
      // ================================================================
      SaveStateToGlobals(sym_idx);

      // ================================================================
      // STEP 20: Log/debug output with diagnostics
      // ================================================================
      // Always log diagnostics at INFO level if anything hit a POI zone
      if(m_diag_price_in_zone > 0)
      {
         LogMessage(LOG_INFO, "DIAG",
            StringFormat("%s | InZone=%d Rev=%d Sw/Tr=%d Pass=%d TimBlk=%d GrD=%d SafBlk=%d RskBlk=%d",
               symbol, m_diag_price_in_zone, m_diag_has_reversal, m_diag_has_sweep_trap,
               m_diag_meets_minimum, m_diag_timing_blocked, m_diag_grade_d,
               m_diag_safety_blocked, m_diag_risk_blocked));
      }

      LogMessage(LOG_INFO, "CYCLE",
         StringFormat("%s | POIs=%d LIQ=%d OBs=%d BBs=%d LiqPools=%d Voids=%d StopRuns=%d Trades=%d | Session=%s KZ=%s | Regime=%s Bias=%s",
            symbol, m_states[si].active_poi_count, m_states[si].active_liq_count,
            m_states[si].ob_count, m_states[si].bb_count,
            m_states[si].liq_pool_count, m_states[si].vacuum_count,
            m_states[si].stop_run_count,
            m_states[si].open_trade_count, m_states[si].session_name,
            m_states[si].in_kill_zone ? "YES" : "NO",
            RegimeToString(regime.regime),
            BiasToString(regime.trend_bias)));

      ResetDiagnostics();
   }

   //--- Find nearest opposing liquidity for TP targeting
   bool FindNearestOpposingLiquidity(LiquidityLevel &levels[], int count,
                                     double current_price, ENUM_POI_DIRECTION poi_dir,
                                     LiquidityLevel &nearest)
   {
      double min_dist = DBL_MAX;
      bool found = false;

      for(int i = 0; i < count; i++)
      {
         if(!levels[i].active || levels[i].swept) continue;

         // For bullish POI (buy), target buy-side liquidity above
         // For bearish POI (sell), target sell-side liquidity below
         bool valid = false;
         if(poi_dir == POI_BULLISH && levels[i].side == LIQ_BUY_SIDE &&
            levels[i].price > current_price)
            valid = true;
         else if(poi_dir == POI_BEARISH && levels[i].side == LIQ_SELL_SIDE &&
                 levels[i].price < current_price)
            valid = true;

         if(valid)
         {
            double dist = MathAbs(levels[i].price - current_price);
            if(dist < min_dist)
            {
               min_dist = dist;
               nearest = levels[i];
               found = true;
            }
         }
      }
      return found;
   }

   //--- Persist state to MQL5 global variables
   void SaveStateToGlobals(int sym_idx)
   {
      string prefix = "IB_" + m_symbols[sym_idx] + "_";

      GlobalVariableSet(prefix + "poi_count",  (double)m_states[sym_idx].active_poi_count);
      GlobalVariableSet(prefix + "liq_count",  (double)m_states[sym_idx].active_liq_count);
      GlobalVariableSet(prefix + "trade_count",(double)m_states[sym_idx].open_trade_count);
      GlobalVariableSet(prefix + "kill_zone",  m_states[sym_idx].in_kill_zone ? 1.0 : 0.0);

      // Global risk
      GlobalVariableSet("IB_daily_pnl",           m_risk_state.daily_pnl);
      GlobalVariableSet("IB_daily_drawdown",       m_risk_state.daily_drawdown);
      GlobalVariableSet("IB_consecutive_losses",   (double)m_risk_state.consecutive_losses);
      GlobalVariableSet("IB_total_trades_today",   (double)m_risk_state.total_trades_today);
   }

   //--- Helper: regime type to string
   string RegimeToString(ENUM_REGIME_TYPE r)
   {
      switch(r)
      {
         case REGIME_TREND:           return "TREND";
         case REGIME_RANGE:           return "RANGE";
         case REGIME_HIGH_VOLATILITY: return "HIGH_VOL";
         case REGIME_LOW_LIQUIDITY:   return "LOW_LIQ";
         default:                     return "UNKNOWN";
      }
   }

   //--- Reset diagnostic counters
   void ResetDiagnostics()
   {
      m_diag_price_in_zone  = 0;
      m_diag_has_reversal   = 0;
      m_diag_has_sweep_trap = 0;
      m_diag_meets_minimum  = 0;
      m_diag_timing_blocked = 0;
      m_diag_grade_d        = 0;
      m_diag_safety_blocked = 0;
      m_diag_risk_blocked   = 0;
   }

   //--- Helper: bias to string
   string BiasToString(ENUM_TREND_BIAS b)
   {
      switch(b)
      {
         case BIAS_BULLISH: return "BULLISH";
         case BIAS_BEARISH: return "BEARISH";
         case BIAS_NEUTRAL: return "NEUTRAL";
         default:           return "UNKNOWN";
      }
   }
};

#endif
