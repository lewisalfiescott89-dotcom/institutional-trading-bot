"""
Backtesting Engine – replays historical candle data bar-by-bar using the
same strategy logic as live trading.
"""

from __future__ import annotations

import time
from typing import Dict, List, Optional

import pandas as pd

from config.settings import BotConfig, ANALYSIS_TIMEFRAMES, EXECUTION_TIMEFRAME
from config.symbols import get_symbol_spec, price_to_pips
from core.logger import get_logger, log_trade_context
from core.utils import compute_atr
from models.poi import POI, POIDirection
from models.trade import Trade, TradeStatus, TradeDirection
from models.signal import Signal, SignalDirection, SetupGrade
from models.regime import MarketRegime
from models.state import SymbolState, GlobalRiskState

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
from risk.commission_engine import CommissionEngine
from risk.position_sizer import PositionSizer
from execution.trade_manager import TradeManager

from backtesting.metrics import compute_metrics, PerformanceMetrics

logger = get_logger("backtester")


class Backtester:
    """
    Replays historical data and simulates trading.

    Usage:
        bt = Backtester(config)
        bt.load_data({"M5": df_m5, "H1": df_h1, ...})
        metrics = bt.run("XAUUSD")
    """

    def __init__(self, config: BotConfig) -> None:
        self.cfg = config
        self.balance = config.backtest.initial_balance

        # Engines
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
        self.risk_engine = RiskEngine(config.risk)
        self.position_sizer = PositionSizer(config.risk)
        self.trade_manager = TradeManager(CommissionEngine(config.commission))

        # Data
        self._data: Dict[str, pd.DataFrame] = {}

        # State
        self.trades: List[Trade] = []
        self.open_trades: List[Trade] = []
        self.global_risk = GlobalRiskState()

    # ------------------------------------------------------------------
    # Data loading
    # ------------------------------------------------------------------

    def load_data(self, tf_dataframes: Dict[str, pd.DataFrame]) -> None:
        """Load pre-fetched dataframes keyed by timeframe string."""
        self._data = tf_dataframes

    # ------------------------------------------------------------------
    # Run
    # ------------------------------------------------------------------

    def run(self, symbol: str, warmup_bars: int = 200) -> PerformanceMetrics:
        """
        Run the backtest for *symbol*.

        Parameters
        ----------
        symbol : instrument name.
        warmup_bars : number of initial bars to skip for indicator warm-up.
        """
        df5 = self._data.get(EXECUTION_TIMEFRAME)
        if df5 is None or df5.empty:
            logger.error("No M5 data loaded for backtesting")
            return PerformanceMetrics()

        logger.info(f"Backtesting {symbol} | bars={len(df5)} | warmup={warmup_bars}")
        self.balance = self.cfg.backtest.initial_balance
        self.trades = []
        self.open_trades = []
        self.global_risk = GlobalRiskState()

        active_pois: List[POI] = []
        all_fvgs = []

        # Pre-compute higher-TF analysis (static for backtest simplicity)
        for tf in ANALYSIS_TIMEFRAMES:
            df_tf = self._data.get(tf)
            if df_tf is None or df_tf.empty:
                continue
            new_pois = self.poi_engine.detect_all(df_tf, symbol, tf)
            active_pois.extend(new_pois)
            fvgs = self.fvg_engine.detect(df_tf, symbol, tf)
            all_fvgs.extend(fvgs)

        self.fvg_engine.boost_poi_with_fvgs(active_pois, all_fvgs)
        projected = self.poi_engine.project_pois_to_execution(active_pois)
        clustered = self.cluster_engine.cluster(projected)
        active_pois = [p for p in clustered if p.active]

        # Pre-compute structure and regime from H4/D1
        h4_df = self._data.get("H4", pd.DataFrame())
        d1_df = self._data.get("D1", pd.DataFrame())
        structure = self.structure_engine.analyse(h4_df if not h4_df.empty else df5)
        regime = self.regime_engine.classify(d1_df if not d1_df.empty else df5, symbol, structure)

        # Bar-by-bar replay on M5
        for bar_idx in range(warmup_bars, len(df5)):
            # Slice up to current bar (inclusive)
            df_slice = df5.iloc[:bar_idx + 1].copy()
            row = df5.iloc[bar_idx]
            o = float(row["open"])
            h = float(row["high"])
            l = float(row["low"])
            c = float(row["close"])
            bar_time = row["time"] if "time" in row.index else None
            utc_hour = bar_time.hour if hasattr(bar_time, "hour") else 12

            # Manage open trades first
            for trade in list(self.open_trades):
                closed = self.trade_manager.check_sl_tp(trade, l, h)
                if closed:
                    self.open_trades.remove(trade)
                    self.trades.append(trade)
                    self.balance += trade.net_pnl
                    is_win = trade.status == TradeStatus.CLOSED_WIN
                    self.risk_engine.update_after_trade(self.global_risk, trade.net_pnl, is_win)

            # Check each POI
            for poi in active_pois:
                if not poi.active:
                    continue

                # Invalidation check
                if poi.wick_probe_pending and poi.wick_probe_bar_index + 1 <= bar_idx:
                    next_open = float(df5.iloc[poi.wick_probe_bar_index + 1]["open"])
                    if poi.direction == POIDirection.BEARISH and next_open > poi.zone_high:
                        poi.invalidate()
                        continue
                    elif poi.direction == POIDirection.BULLISH and next_open < poi.zone_low:
                        poi.invalidate()
                        continue
                    poi.wick_probe_pending = False

                # Price in zone?
                in_zone = poi.contains_price(c) or poi.contains_price(o)
                wick_touch = (
                    (poi.direction == POIDirection.BEARISH and h >= poi.zone_low) or
                    (poi.direction == POIDirection.BULLISH and l <= poi.zone_high)
                )
                if not in_zone and not wick_touch:
                    continue

                poi.record_touch()

                # Build liquidity from recent data
                liq_levels = self.liquidity_map_engine.build_map(df_slice, symbol, EXECUTION_TIMEFRAME)

                # Sweep detection
                sweeps = self.sweep_engine.detect(df_slice, symbol, liq_levels, active_pois, bar_idx)
                traps = self.trap_engine.detect(df_slice, symbol, liq_levels)

                best_sweep = sweeps[0] if sweeps else None
                best_trap = traps[0] if traps else None

                # Reversal confirmation
                reversal = self.reversal_engine.detect(df_slice, poi, bar_idx)
                if reversal is None:
                    if poi.direction == POIDirection.BEARISH and h > poi.zone_high:
                        poi.wick_probe_pending = True
                        poi.wick_probe_bar_index = bar_idx
                    elif poi.direction == POIDirection.BULLISH and l < poi.zone_low:
                        poi.wick_probe_pending = True
                        poi.wick_probe_bar_index = bar_idx
                    continue

                # Timing
                bars_in_zone = 0
                for k in range(bar_idx, max(bar_idx - 50, -1), -1):
                    if poi.contains_price(float(df5.iloc[k]["close"])):
                        bars_in_zone += 1
                    else:
                        break

                timing = self.timing_engine.evaluate(utc_hour, bars_in_zone, SetupGrade.D)

                # Score
                mid_price = (h + l) / 2.0
                forecast = self.forecast_engine.forecast(symbol, mid_price, liq_levels, active_pois)
                cluster_count = len([p for p in active_pois if p.cluster_id == poi.cluster_id]) if poi.cluster_id else 1

                signal = self.quality_engine.score(
                    poi, regime, timing, best_sweep, best_trap, reversal,
                    forecast, cluster_count,
                )

                # Re-evaluate timing with grade
                timing = self.timing_engine.evaluate(utc_hour, bars_in_zone, signal.grade)
                if not timing.allow_trade:
                    continue

                if signal.grade == SetupGrade.D:
                    continue

                # Risk
                risk_pct = self.risk_engine.compute_risk_pct(
                    signal, regime, self.global_risk, self.balance
                )
                if risk_pct <= 0:
                    continue

                spec = get_symbol_spec(symbol)
                sl_pips = spec.default_sl_pips
                signal.entry_price = reversal.close_price
                signal.sl_price = self.position_sizer.calculate_sl_price(
                    symbol, signal.entry_price, signal.direction.value, sl_pips
                )

                # Simple TP: 2x SL distance
                sl_dist = abs(signal.entry_price - signal.sl_price)
                if signal.direction == SignalDirection.BUY:
                    signal.tp_price = signal.entry_price + sl_dist * 2.0
                else:
                    signal.tp_price = signal.entry_price - sl_dist * 2.0

                lot_size = self.position_sizer.calculate_lot_size(
                    symbol, self.balance, risk_pct, sl_pips
                )
                if lot_size <= 0:
                    continue

                # Create trade
                import uuid
                trade = Trade(
                    id=uuid.uuid4().hex[:12],
                    symbol=symbol,
                    direction=TradeDirection.BUY if signal.direction == SignalDirection.BUY else TradeDirection.SELL,
                    entry_price=signal.entry_price,
                    sl_price=signal.sl_price,
                    tp_price=signal.tp_price,
                    lot_size=lot_size,
                    risk_pct=risk_pct,
                    status=TradeStatus.OPEN,
                    grade=signal.grade.value,
                    score=signal.score,
                    poi_id=poi.id,
                    open_timestamp=float(bar_time.timestamp()) if hasattr(bar_time, "timestamp") else 0.0,
                )
                self.open_trades.append(trade)

                logger.debug(
                    f"BT TRADE | {trade.direction.value} {symbol} @ {trade.entry_price:.5f} | "
                    f"SL={trade.sl_price:.5f} TP={trade.tp_price:.5f} | "
                    f"lots={lot_size} grade={trade.grade} bar={bar_idx}"
                )

                # Only one trade per bar
                break

        # Close any remaining open trades at last price
        if self.open_trades:
            last_close = float(df5.iloc[-1]["close"])
            for trade in self.open_trades:
                self.trade_manager.check_sl_tp(trade, last_close, last_close)
                if trade.is_open():
                    trade.close_price = last_close
                    trade.status = TradeStatus.CLOSED_BE
                self.trades.append(trade)
            self.open_trades.clear()

        metrics = compute_metrics(self.trades, self.cfg.backtest.initial_balance)
        logger.info(metrics.summary())
        return metrics
