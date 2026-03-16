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

   //--- Diagnostic counters (reset each bar for logging)
   int m_diag_price_in_zone;
   int m_diag_has_reversal;
   int m_diag_has_sweep_trap;
   int m_diag_meets_minimum;
   int m_diag_timing_blocked;
   int m_diag_grade_d;
   int m_diag_safety_blocked;
   int m_diag_risk_blocked;

public:
   COrchestrator() : m_symbol_count(0), m_bars_to_load(500), m_last_day(-1),
                     m_require_sweep_trap(false), m_allow_grade_d(false), m_long_only(false)
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
      m_risk_state.peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);

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
      // STEP 3: Update higher timeframe analysis + detect POIs
      // ================================================================
      POIData all_pois[];
      int total_pois = 0;
      ArrayResize(all_pois, MAX_POIS);

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

         // Add to master list
         for(int p = 0; p < poi_count && total_pois < MAX_POIS; p++)
         {
            all_pois[total_pois] = tf_pois[p];
            total_pois++;
         }
      }

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
      // STEP 11: Detect FVGs and boost POIs
      // ================================================================
      FVGData fvgs[];
      ArrayResize(fvgs, MAX_FVGS);
      int fvg_count = m_fvg.Detect(m5_highs, m5_lows, m5_closes, m5_times,
                                    m5_count, symbol, PERIOD_M5, fvgs, MAX_FVGS);
      m_fvg.BoostPOIWithFVGs(m_states[si].active_pois, m_states[si].active_poi_count, fvgs, fvg_count);

      // ================================================================
      // STEP 12-15: Check each active POI for trade signals
      // ================================================================
      for(int p = 0; p < m_states[si].active_poi_count; p++)
      {
         if(!m_states[si].active_pois[p].active || m_states[si].active_pois[p].invalidated) continue;

         double last_close = m5_closes[m5_count - 1];
         double last_open  = m5_opens[m5_count - 1];
         double last_high  = m5_highs[m5_count - 1];
         double last_low   = m5_lows[m5_count - 1];

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

         // Check if price is in the zone
         bool price_in_zone = m_states[si].active_pois[p].ContainsPrice(last_close) ||
                              m_states[si].active_pois[p].ContainsPrice(last_low) ||
                              m_states[si].active_pois[p].ContainsPrice(last_high);

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

         // STEP 13: Detect reversal candle on recent COMPLETED bars
         //   m5_count-1 = current forming bar (skip - incomplete candle)
         //   m5_count-2 = last completed bar
         //   Check last 3 completed bars for best reversal
         bool look_for_bullish = (m_states[si].active_pois[p].direction == POI_BULLISH);
         ReversalData rev;
         rev.Init();
         for(int rb = 2; rb <= 4 && rb < m5_count; rb++)
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
         if(has_reversal) m_diag_has_reversal++;
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
                              best_trap, has_trap, rev, signal);

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

         // Calculate SL and TP
         double entry_price = rev.entry_price;
         bool is_buy = (signal.direction == SIGNAL_BUY);
         double sl_price = m_sizer.DefaultSLPrice(symbol, entry_price, is_buy);
         double tp_price = 0;
         if(has_nearest_liq)
            tp_price = m_sizer.TPFromLiquidity(entry_price, nearest_liq.price, is_buy);

         // Guarantee a TP exists — use 4:1 R:R if no liquidity target found
         double sl_dist = MathAbs(entry_price - sl_price);
         if(tp_price == 0 || MathAbs(tp_price - entry_price) < sl_dist * 2.0)
         {
            // No TP or TP too close — set to 4:1 R:R minimum
            if(is_buy)
               tp_price = entry_price + sl_dist * 4.0;
            else
               tp_price = entry_price - sl_dist * 4.0;
         }

         // Position size
         SizeResult size;
         m_sizer.Calculate(symbol, AccountInfoDouble(ACCOUNT_EQUITY),
                           risk_result.risk_pct, entry_price, sl_price, size);

         // ================================================================
         // STEP 17: Execute trade
         // ================================================================
         TradeData trade;
         bool executed = m_executor.Execute(signal, symbol, size.lot_size,
                                            sl_price, tp_price, trade);

         if(executed)
         {
            // Add to open trades
            if(m_states[si].open_trade_count < MAX_TRADES)
            {
               m_states[si].open_trades[m_states[si].open_trade_count] = trade;
               m_states[si].open_trade_count++;
            }

            m_risk_state.total_trades_today++;

            LogSignal(symbol, GradeToString(signal.grade),
                      signal.total_score,
                      is_buy ? "BUY" : "SELL");
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

      // Update daily drawdown (peak equity vs current equity)
      double cur_equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(cur_equity > m_risk_state.peak_equity)
         m_risk_state.peak_equity = cur_equity;
      m_risk_state.daily_drawdown = (m_risk_state.peak_equity > 0)
         ? (m_risk_state.peak_equity - cur_equity) / m_risk_state.peak_equity * 100.0
         : 0;

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
         StringFormat("%s | POIs=%d LIQ=%d Trades=%d | Session=%s KZ=%s | Regime=%s Bias=%s",
            symbol, m_states[si].active_poi_count, m_states[si].active_liq_count,
            m_states[si].open_trade_count, m_states[si].session_name,
            m_states[si].in_kill_zone ? "YES" : "NO",
            RegimeToString(regime.regime),
            BiasToString(regime.trend_bias)));

      ResetDiagnostics();
   }

   //--- Find nearest opposing liquidity for TP targeting
   bool FindNearestOpposingLiquidity(const LiquidityLevel &levels[], int count,
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
