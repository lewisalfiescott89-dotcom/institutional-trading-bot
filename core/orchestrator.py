"""
Execution Orchestrator – runs the full analysis-to-execution cycle
on every new 5M candle for all configured symbols.
"""

from __future__ import annotations

import time
import traceback
from typing import Dict, List, Optional

import pandas as pd

from config.settings import BotConfig, ANALYSIS_TIMEFRAMES, EXECUTION_TIMEFRAME
from config.symbols import get_symbol_spec, price_to_pips, pips_to_price
from core.logger import get_logger, log_trade_context
from core.state_manager import StateManager
from core.utils import now_utc, epoch_now
from data.mt5_connector import MT5Connector
from data.market_data import MarketData
from models.poi import POI, POIDirection
from models.signal import Signal, SetupGrade
from models.trade import Trade, TradeStatus
from models.state import SymbolState

from analysis.structure_engine import StructureEngine
from analysis.regime_engine import RegimeEngine
from analysis.poi_engine import POIEngine
from analysis.poi_cluster_engine import POIClusterEngine
from analysis.fvg_engine import FVGEngine
from analysis.liquidity_map_engine import LiquidityMapEngine
from analysis.liquidity_forecast_engine import LiquidityForecastEngine
from analysis.liquidity_timing_engine import LiquidityTimingEngine
from analysis.session_engine import SessionEngine
from analysis.sweep_engine import SweepEngine
from analysis.trap_engine import TrapEngine
from analysis.reversal_engine import ReversalEngine
from analysis.trade_quality_engine import TradeQualityEngine

from risk.risk_engine import RiskEngine
from risk.position_sizer import PositionSizer
from execution.executor import Executor
from execution.trade_manager import TradeManager
from execution.safety_engine import SafetyEngine

logger = get_logger("orchestrator")


class Orchestrator:
    """Central loop that drives the institutional trading bot."""

    def __init__(self, config: BotConfig) -> None:
        self.cfg = config

        # Infrastructure
        self.connector = MT5Connector(config.mt5)
        self.market_data = MarketData()
        self.state_mgr = StateManager(config.state_file)

        # Analysis engines
        self.structure_engine = StructureEngine(config.structure)
        self.regime_engine = RegimeEngine(config.regime)
        self.poi_engine = POIEngine(config.poi)
        self.cluster_engine = POIClusterEngine(config.poi)
        self.fvg_engine = FVGEngine(config.fvg)
        self.liquidity_map_engine = LiquidityMapEngine(config.liquidity)
        self.forecast_engine = LiquidityForecastEngine()
        self.timing_engine = LiquidityTimingEngine(config.timing, config.sessions)
        self.session_engine = SessionEngine(config.sessions)
        self.sweep_engine = SweepEngine(config.sweep)
        self.trap_engine = TrapEngine(config.trap)
        self.reversal_engine = ReversalEngine(config.reversal)
        self.quality_engine = TradeQualityEngine(config.grading)

        # Risk & execution
        self.risk_engine = RiskEngine(config.risk)
        self.position_sizer = PositionSizer(config.risk)
        self.executor = Executor(dry_run=config.dry_run)
        self.trade_manager = TradeManager()
        self.safety_engine = SafetyEngine(config.safety, config)

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------

    def run_forever(self) -> None:
        """Block and run the bot until interrupted."""
        logger.info("=" * 60)
        logger.info("Institutional Trading Bot starting")
        logger.info(f"Mode: {'DRY RUN' if self.cfg.dry_run else 'LIVE'}")
        logger.info(f"Symbols: {self.cfg.symbols}")
        logger.info("=" * 60)

        # Connect to MT5
        if not self.connector.connect():
            logger.warning("MT5 connection failed – running in offline/dry-run mode")

        # Load persisted state
        self.state_mgr.load()

        last_bar_time: Dict[str, float] = {}

        try:
            while True:
                for symbol in self.cfg.symbols:
                    try:
                        # Fetch latest 5M bar to detect new candle
                        df5 = self.market_data.fetch_candles(symbol, EXECUTION_TIMEFRAME, count=5)
                        if df5.empty:
                            continue

                        latest_time = float(df5.iloc[-1]["time"].timestamp()) if hasattr(df5.iloc[-1]["time"], "timestamp") else 0.0
                        prev_time = last_bar_time.get(symbol, 0.0)

                        if latest_time <= prev_time:
                            # No new candle yet
                            # Still manage open trades
                            self._manage_trades(symbol)
                            continue

                        last_bar_time[symbol] = latest_time
                        logger.info(f"--- New 5M candle: {symbol} ---")

                        # Run full cycle
                        self.run_cycle(symbol)

                    except Exception as e:
                        logger.error(
                            f"Error processing {symbol}: {e}\n"
                            f"{traceback.format_exc()}"
                        )

                # Sleep until next check (poll every 15 seconds)
                time.sleep(15)

        except KeyboardInterrupt:
            logger.info("Shutting down gracefully...")
        finally:
            self.state_mgr.save()
            self.connector.disconnect()

    # ------------------------------------------------------------------
    # Single cycle for one symbol
    # ------------------------------------------------------------------

    def run_cycle(self, symbol: str) -> Optional[Signal]:
        """
        Execute the full 20-step orchestration for *symbol*.

        Returns the generated Signal (or None).
        """
        ss = self.state_mgr.get_symbol_state(symbol)

        # 1. Sync MT5 data
        tf_data = self.market_data.fetch_all_timeframes(symbol, ANALYSIS_TIMEFRAMES)
        df5 = tf_data.get(EXECUTION_TIMEFRAME)
        if df5 is None or df5.empty:
            return None

        # 2-3. Higher-timeframe analysis: detect POIs on each TF
        all_pois: List[POI] = list(ss.active_pois)  # carry forward existing
        all_fvgs = []
        for tf in ANALYSIS_TIMEFRAMES:
            df_tf = tf_data.get(tf)
            if df_tf is None or df_tf.empty:
                continue
            new_pois = self.poi_engine.detect_all(df_tf, symbol, tf)
            # Avoid duplicates by checking existing IDs
            existing_ids = {p.id for p in all_pois}
            for p in new_pois:
                if p.id not in existing_ids:
                    all_pois.append(p)
            fvgs = self.fvg_engine.detect(df_tf, symbol, tf)
            all_fvgs.extend(fvgs)

        # Boost POIs with FVG overlap
        self.fvg_engine.boost_poi_with_fvgs(all_pois, all_fvgs)

        # 4. Project all POIs onto the 5M chart
        projected = self.poi_engine.project_pois_to_execution(all_pois, EXECUTION_TIMEFRAME)

        # 5. Cluster overlapping POIs
        clustered = self.cluster_engine.cluster(projected)
        ss.active_pois = [p for p in clustered if p.active]
        ss.invalidated_pois = [p for p in clustered if not p.active]

        # 6. Build liquidity map
        session_state = self.session_engine.identify_session()
        session_state = self.session_engine.update_session_levels(session_state, df5)

        # Add prev day/week levels
        daily_df = tf_data.get("D1")
        weekly_df = tf_data.get("W1")
        if daily_df is not None and not daily_df.empty:
            pdl = self.session_engine.compute_prev_day_levels(daily_df)
            session_state.prev_day_high = pdl["prev_day_high"]
            session_state.prev_day_low = pdl["prev_day_low"]
        if weekly_df is not None and not weekly_df.empty:
            pwl = self.session_engine.compute_prev_week_levels(weekly_df)
            session_state.prev_week_high = pwl["prev_week_high"]
            session_state.prev_week_low = pwl["prev_week_low"]

        liq_levels = self.liquidity_map_engine.build_map(
            df5, symbol, EXECUTION_TIMEFRAME, session_state.session_levels_dict()
        )

        # Update swept status
        current_high = float(df5.iloc[-1]["high"])
        current_low = float(df5.iloc[-1]["low"])
        current_close = float(df5.iloc[-1]["close"])
        current_open = float(df5.iloc[-1]["open"])
        ts_now = epoch_now()
        liq_levels = self.liquidity_map_engine.update_swept_status(
            liq_levels, current_high, current_low, ts_now
        )
        ss.active_liquidity = [l for l in liq_levels if l.active]
        ss.swept_liquidity = [l for l in liq_levels if l.swept]

        # 7. Liquidity forecast
        mid_price = (current_high + current_low) / 2.0
        forecast = self.forecast_engine.forecast(
            symbol, mid_price, ss.active_liquidity, ss.active_pois
        )
        ss.forecast_target_price = forecast.primary_target.level.price if forecast.primary_target else 0.0
        ss.forecast_direction = forecast.draw_direction

        # 8. Structure
        h4_df = tf_data.get("H4")
        structure = self.structure_engine.analyse(h4_df if h4_df is not None and not h4_df.empty else df5)

        # 9. Regime
        regime = self.regime_engine.classify(
            daily_df if daily_df is not None and not daily_df.empty else df5,
            symbol, structure,
        )
        ss.regime = regime

        # 10. Session / timing
        utc_hour = now_utc().hour
        ss.session_name = session_state.current_session
        ss.in_kill_zone = session_state.in_kill_zone

        # 11-14. Check each active POI for entry setup
        best_signal: Optional[Signal] = None

        for poi in ss.active_pois:
            if not poi.active:
                continue

            # 11. Zone invalidation (Pepperstone 5M rule)
            invalidated = self._check_invalidation(poi, df5)
            if invalidated:
                poi.invalidate()
                continue

            # Check if price is in the zone
            if not poi.contains_price(current_close) and not poi.contains_price(current_open):
                # Also check wick probes
                if poi.direction == POIDirection.BEARISH and current_high >= poi.zone_low:
                    pass  # wick into supply zone
                elif poi.direction == POIDirection.BULLISH and current_low <= poi.zone_high:
                    pass  # wick into demand zone
                else:
                    continue

            # Record touch
            poi.record_touch()
            self.poi_engine.update_freshness(poi)

            # 12. Detect sweep/trap
            sweeps = self.sweep_engine.detect(df5, symbol, ss.active_liquidity, ss.active_pois)
            traps = self.trap_engine.detect(df5, symbol, ss.active_liquidity)

            # Pick the best sweep/trap near this POI
            relevant_sweep = None
            for s in sweeps:
                if poi.contains_price(s.liquidity_price) or abs(poi.mid_price() - s.liquidity_price) < poi.zone_width() * 2:
                    if relevant_sweep is None or s.score > relevant_sweep.score:
                        relevant_sweep = s

            relevant_trap = None
            for t in traps:
                if poi.contains_price(t.level_price) or abs(poi.mid_price() - t.level_price) < poi.zone_width() * 2:
                    if relevant_trap is None or t.score > relevant_trap.score:
                        relevant_trap = t

            # 13. Reversal candle confirmation
            reversal = self.reversal_engine.detect(df5, poi)
            if reversal is None:
                # No reversal yet – mark wick probe pending if applicable
                if poi.direction == POIDirection.BEARISH and current_high > poi.zone_high:
                    poi.wick_probe_pending = True
                    poi.wick_probe_bar_index = len(df5) - 1
                elif poi.direction == POIDirection.BULLISH and current_low < poi.zone_low:
                    poi.wick_probe_pending = True
                    poi.wick_probe_bar_index = len(df5) - 1
                continue

            # 14. Count bars in zone for staleness
            bars_in_zone = self._count_bars_in_zone(df5, poi)
            timing = self.timing_engine.evaluate(utc_hour, bars_in_zone, SetupGrade.D)

            # 15. Score the setup
            cluster_count = len([p for p in ss.active_pois if p.cluster_id == poi.cluster_id]) if poi.cluster_id else 1
            signal = self.quality_engine.score(
                poi, regime, timing, relevant_sweep, relevant_trap, reversal,
                forecast, cluster_count,
            )

            # Re-evaluate timing with actual grade
            timing = self.timing_engine.evaluate(utc_hour, bars_in_zone, signal.grade)
            if not timing.allow_trade:
                signal.approved = False
                signal.rejection_reasons.append(timing.block_reason)

            # Set entry at reversal close
            signal.entry_price = reversal.close_price
            signal.timestamp = ts_now
            signal.bar_index = reversal.bar_index

            if best_signal is None or signal.score > best_signal.score:
                best_signal = signal

        if best_signal is None:
            self._manage_trades(symbol)
            self.state_mgr.save()
            return None

        # 16. Safety checks
        account_balance = self.connector.account_balance() or self.cfg.backtest.initial_balance
        safety = self.safety_engine.check(
            best_signal, self.market_data, self.state_mgr.global_risk, account_balance
        )
        if not safety.passed:
            best_signal.approved = False
            best_signal.rejection_reasons.extend(safety.reasons)

        # 17. Risk & position sizing
        risk_pct = self.risk_engine.compute_risk_pct(
            best_signal, regime, self.state_mgr.global_risk, account_balance
        )
        best_signal.risk_pct = risk_pct

        spec = get_symbol_spec(symbol)
        sl_pips = spec.default_sl_pips
        best_signal.sl_price = self.position_sizer.calculate_sl_price(
            symbol, best_signal.entry_price,
            best_signal.direction.value, sl_pips,
        )

        # TP targeting: nearest opposing liquidity
        tp_price = self._find_tp_target(
            best_signal, forecast, ss.active_liquidity
        )
        best_signal.tp_price = tp_price

        lot_size = self.position_sizer.calculate_lot_size(
            symbol, account_balance, risk_pct, sl_pips
        )
        best_signal.lot_size = lot_size

        # Log the setup
        log_trade_context(
            logger, symbol,
            poi=best_signal.poi_id,
            liq_target=f"{ss.forecast_target_price:.2f}",
            timing=ss.session_name,
            sweep="yes" if best_signal.sweep_detected else "no",
            trap="yes" if best_signal.trap_detected else "no",
            reversal=best_signal.reversal_type,
            score=best_signal.score,
            grade=best_signal.grade.value,
            risk=f"{risk_pct:.2f}%",
            action="EXECUTE" if best_signal.approved else "BLOCKED",
        )

        # 18. Execute
        trade: Optional[Trade] = None
        if best_signal.approved and lot_size > 0:
            trade = self.executor.execute(best_signal)
            if trade:
                ss.open_trades.append(trade)

        # 19. Manage open trades
        self._manage_trades(symbol)

        # 20. Save state
        self.state_mgr.save()

        return best_signal

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _check_invalidation(self, poi: POI, df5: pd.DataFrame) -> bool:
        """
        Custom Pepperstone 5M invalidation rule:

        - A wick beyond the zone is allowed.
        - If the NEXT 5M candle opens with its body beyond the zone → blown.

        For sell (supply) zone: next candle opens above zone_high → invalid.
        For buy (demand) zone: next candle opens below zone_low → invalid.
        """
        if not poi.wick_probe_pending:
            return False

        # The wick probe happened on bar poi.wick_probe_bar_index.
        # We need to check the NEXT bar's open.
        next_idx = poi.wick_probe_bar_index + 1
        if next_idx >= len(df5):
            return False  # next bar hasn't formed yet

        next_open = float(df5.iloc[next_idx]["open"])

        if poi.direction == POIDirection.BEARISH:
            # Supply zone: blown if next candle opens above zone_high
            if next_open > poi.zone_high:
                logger.info(
                    f"POI {poi.id} INVALIDATED | supply zone blown | "
                    f"next_open={next_open} > zone_high={poi.zone_high}"
                )
                poi.wick_probe_pending = False
                return True
        elif poi.direction == POIDirection.BULLISH:
            # Demand zone: blown if next candle opens below zone_low
            if next_open < poi.zone_low:
                logger.info(
                    f"POI {poi.id} INVALIDATED | demand zone blown | "
                    f"next_open={next_open} < zone_low={poi.zone_low}"
                )
                poi.wick_probe_pending = False
                return True

        # Zone survived – reset probe
        poi.wick_probe_pending = False
        return False

    def _count_bars_in_zone(self, df: pd.DataFrame, poi: POI) -> int:
        """Count how many recent bars have been inside the POI zone."""
        count = 0
        for i in range(len(df) - 1, max(len(df) - 50, -1), -1):
            if i < 0:
                break
            c = float(df.iloc[i]["close"])
            if poi.contains_price(c):
                count += 1
            else:
                break
        return count

    def _find_tp_target(
        self,
        signal: Signal,
        forecast: "LiquidityForecast",
        liquidity: list,
    ) -> float:
        """Find the best TP target from opposing liquidity."""
        from models.liquidity import LiquiditySide

        if signal.direction.value == "buy":
            # Target buy-side liquidity above entry
            targets = [
                l for l in liquidity
                if l.active and l.side == LiquiditySide.BUY_SIDE
                and l.price > signal.entry_price
            ]
            targets.sort(key=lambda l: l.price)
            if targets:
                return targets[0].price
            # Fallback: use forecast primary target
            if forecast.primary_target and forecast.primary_target.level.price > signal.entry_price:
                return forecast.primary_target.level.price
        else:
            # Target sell-side liquidity below entry
            targets = [
                l for l in liquidity
                if l.active and l.side == LiquiditySide.SELL_SIDE
                and l.price < signal.entry_price
            ]
            targets.sort(key=lambda l: l.price, reverse=True)
            if targets:
                return targets[0].price
            if forecast.primary_target and forecast.primary_target.level.price < signal.entry_price:
                return forecast.primary_target.level.price

        # Fallback: 2x SL distance as TP
        sl_dist = abs(signal.entry_price - signal.sl_price)
        if signal.direction.value == "buy":
            return signal.entry_price + sl_dist * 2.0
        else:
            return signal.entry_price - sl_dist * 2.0

    def _manage_trades(self, symbol: str) -> None:
        """Check open trades for SL/TP and update state."""
        ss = self.state_mgr.get_symbol_state(symbol)
        if not ss.open_trades:
            return

        tick = self.market_data.fetch_latest_tick(symbol)
        if tick is None:
            # Use last candle close as proxy
            df5 = self.market_data.get_cached(symbol, EXECUTION_TIMEFRAME)
            if df5 is None or df5.empty:
                return
            bid = ask = float(df5.iloc[-1]["close"])
        else:
            bid = tick["bid"]
            ask = tick["ask"]

        closed = self.trade_manager.manage_open_trades(ss.open_trades, bid, ask)

        for trade in closed:
            ss.open_trades.remove(trade)
            ss.recent_closed_trades.append(trade)

            # Update global risk
            is_win = trade.status == TradeStatus.CLOSED_WIN
            self.risk_engine.update_after_trade(
                self.state_mgr.global_risk, trade.net_pnl, is_win
            )

            # Re-entry eligibility
            if self.trade_manager.check_reentry_eligibility(trade):
                if trade.poi_id not in ss.reentry_eligible_poi_ids:
                    ss.reentry_eligible_poi_ids.append(trade.poi_id)

        # Keep only last 50 closed trades
        if len(ss.recent_closed_trades) > 50:
            ss.recent_closed_trades = ss.recent_closed_trades[-50:]
