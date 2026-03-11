"""
Institutional Trading Bot – Main Entry Point

Modes:
    live     – connect to MT5 and trade (dry_run=True by default for safety)
    backtest – replay historical data through the strategy
    optimize – sweep parameters over historical data
    debug    – generate a visual debug chart from recent data

Usage:
    python main.py live
    python main.py backtest --symbol XAUUSD
    python main.py optimize --symbol XAUUSD
    python main.py debug --symbol XAUUSD
"""

from __future__ import annotations

import argparse
import sys
from typing import Dict

import pandas as pd

from config.settings import BotConfig
from core.logger import get_logger
from core.orchestrator import Orchestrator
from data.market_data import MarketData
from data.mt5_connector import MT5Connector

logger = get_logger("main", log_file="bot.log")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Institutional Trading Bot",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "mode",
        choices=["live", "backtest", "optimize", "debug"],
        help="Operating mode",
    )
    parser.add_argument("--symbol", default="XAUUSD", help="Symbol to process (backtest/optimize/debug)")
    parser.add_argument("--dry-run", action="store_true", default=True, help="Dry-run mode (no real orders)")
    parser.add_argument("--live-trade", action="store_true", default=False, help="Enable live trading (disables dry-run)")
    parser.add_argument("--lookback-days", type=int, default=180, help="Historical data lookback in days")
    parser.add_argument("--warmup-bars", type=int, default=200, help="Warm-up bars for backtest/optimize")
    parser.add_argument("--csv-dir", default="", help="Directory with CSV files for offline backtesting")
    parser.add_argument("--state-file", default="bot_state.json", help="State persistence file")
    return parser.parse_args()


def build_config(args: argparse.Namespace) -> BotConfig:
    """Build the bot configuration from CLI args."""
    cfg = BotConfig()
    cfg.dry_run = not args.live_trade
    cfg.state_file = args.state_file

    # User must edit MT5 settings for their account:
    # cfg.mt5.login = 12345678
    # cfg.mt5.password = "your_password"
    # cfg.mt5.server = "Pepperstone-Live"
    # cfg.mt5.path = r"C:\Program Files\Pepperstone MetaTrader 5\terminal64.exe"

    return cfg


def run_live(cfg: BotConfig) -> None:
    """Start the live trading loop."""
    logger.info("Starting LIVE mode" + (" (DRY RUN)" if cfg.dry_run else " (REAL ORDERS)"))
    if not cfg.dry_run:
        logger.warning("=" * 60)
        logger.warning("  LIVE TRADING ENABLED – REAL MONEY AT RISK")
        logger.warning("=" * 60)

    orch = Orchestrator(cfg)
    orch.run_forever()


def run_backtest(cfg: BotConfig, symbol: str, lookback_days: int, warmup_bars: int, csv_dir: str) -> None:
    """Run a backtest on historical data."""
    from config.settings import ANALYSIS_TIMEFRAMES
    from backtesting.backtester import Backtester
    from visualization.plotter import Plotter

    logger.info(f"Starting BACKTEST for {symbol}")

    # Load data
    tf_data: Dict[str, pd.DataFrame] = {}
    md = MarketData()

    if csv_dir:
        # Load from CSV files
        import os
        for tf in ANALYSIS_TIMEFRAMES:
            csv_path = os.path.join(csv_dir, f"{symbol}_{tf}.csv")
            if os.path.exists(csv_path):
                tf_data[tf] = md.load_csv(csv_path, symbol, tf)
                logger.info(f"Loaded {len(tf_data[tf])} bars from {csv_path}")
            else:
                logger.warning(f"CSV not found: {csv_path}")
    else:
        # Fetch from MT5
        connector = MT5Connector(cfg.mt5)
        if not connector.connect():
            logger.error("Cannot connect to MT5 for data – provide --csv-dir for offline backtest")
            return
        tf_data = md.fetch_all_timeframes(symbol, ANALYSIS_TIMEFRAMES, lookback_days)
        connector.disconnect()

    if not tf_data.get("M5") is not None or tf_data.get("M5").empty:
        logger.error("No M5 data available for backtesting")
        return

    bt = Backtester(cfg)
    bt.load_data(tf_data)
    metrics = bt.run(symbol, warmup_bars)

    print("\n" + metrics.summary())

    # Save charts
    if bt.trades:
        try:
            Plotter.save_all(bt.trades, cfg.backtest.initial_balance, prefix=f"bt_{symbol}")
            logger.info("Performance charts saved")
        except Exception as e:
            logger.warning(f"Could not generate charts: {e}")


def run_optimize(cfg: BotConfig, symbol: str, lookback_days: int, warmup_bars: int, csv_dir: str) -> None:
    """Run parameter optimization."""
    from config.settings import ANALYSIS_TIMEFRAMES
    from backtesting.optimizer import Optimizer

    logger.info(f"Starting OPTIMIZATION for {symbol}")

    # Load data (same as backtest)
    tf_data: Dict[str, pd.DataFrame] = {}
    md = MarketData()

    if csv_dir:
        import os
        for tf in ANALYSIS_TIMEFRAMES:
            csv_path = os.path.join(csv_dir, f"{symbol}_{tf}.csv")
            if os.path.exists(csv_path):
                tf_data[tf] = md.load_csv(csv_path, symbol, tf)
    else:
        connector = MT5Connector(cfg.mt5)
        if not connector.connect():
            logger.error("Cannot connect to MT5 – provide --csv-dir")
            return
        tf_data = md.fetch_all_timeframes(symbol, ANALYSIS_TIMEFRAMES, lookback_days)
        connector.disconnect()

    if not tf_data.get("M5") is not None or tf_data.get("M5").empty:
        logger.error("No M5 data available")
        return

    opt = Optimizer(cfg, tf_data)
    # Example parameter ranges – customize as needed
    opt.add_param("poi.displacement_multiplier", [1.0, 1.5, 2.0, 2.5])
    opt.add_param("sweep.min_penetration_pips", [0.5, 1.0, 2.0])
    opt.add_param("reversal.min_engulfing_ratio", [0.8, 1.0, 1.2])

    results = opt.run(symbol, warmup_bars)
    if results:
        print(f"\nBest combination: {results[0].summary_line()}")


def run_debug(cfg: BotConfig, symbol: str, lookback_days: int, csv_dir: str) -> None:
    """Generate a debug chart with all analysis overlays."""
    from config.settings import ANALYSIS_TIMEFRAMES, EXECUTION_TIMEFRAME
    from analysis.poi_engine import POIEngine
    from analysis.poi_cluster_engine import POIClusterEngine
    from analysis.fvg_engine import FVGEngine
    from analysis.liquidity_map_engine import LiquidityMapEngine
    from analysis.session_engine import SessionEngine
    from visualization.chart_debugger import ChartDebugger

    logger.info(f"Generating DEBUG chart for {symbol}")

    md = MarketData()
    tf_data: Dict[str, pd.DataFrame] = {}

    if csv_dir:
        import os
        for tf in ANALYSIS_TIMEFRAMES:
            csv_path = os.path.join(csv_dir, f"{symbol}_{tf}.csv")
            if os.path.exists(csv_path):
                tf_data[tf] = md.load_csv(csv_path, symbol, tf)
    else:
        connector = MT5Connector(cfg.mt5)
        if not connector.connect():
            logger.error("Cannot connect to MT5 – provide --csv-dir")
            return
        tf_data = md.fetch_all_timeframes(symbol, ANALYSIS_TIMEFRAMES, lookback_days)
        connector.disconnect()

    df5 = tf_data.get(EXECUTION_TIMEFRAME)
    if df5 is None or df5.empty:
        logger.error("No M5 data")
        return

    # Run analysis
    poi_engine = POIEngine(cfg.poi)
    cluster_engine = POIClusterEngine(cfg.poi)
    fvg_engine = FVGEngine(cfg.fvg)
    liq_engine = LiquidityMapEngine(cfg.liquidity)
    session_engine = SessionEngine(cfg.sessions)

    all_pois = []
    all_fvgs = []
    for tf in ANALYSIS_TIMEFRAMES:
        df_tf = tf_data.get(tf)
        if df_tf is None or df_tf.empty:
            continue
        all_pois.extend(poi_engine.detect_all(df_tf, symbol, tf))
        all_fvgs.extend(fvg_engine.detect(df_tf, symbol, tf))

    fvg_engine.boost_poi_with_fvgs(all_pois, all_fvgs)
    projected = poi_engine.project_pois_to_execution(all_pois)
    clustered = cluster_engine.cluster(projected)

    session = session_engine.identify_session()
    session = session_engine.update_session_levels(session, df5)
    liq_levels = liq_engine.build_map(df5, symbol, EXECUTION_TIMEFRAME, session.session_levels_dict())

    # Build chart – show last 500 bars for readability
    chart_df = df5.tail(500).reset_index(drop=True)

    dbg = ChartDebugger(title=f"{symbol} Debug Chart")
    dbg.set_candles(chart_df)
    dbg.add_pois([p for p in clustered if p.active])
    dbg.add_liquidity(liq_levels)
    dbg.add_fvgs(all_fvgs[-50:])  # last 50 FVGs

    output_file = f"debug_{symbol}.html"
    dbg.save(output_file)
    print(f"Debug chart saved to {output_file}")


def main() -> None:
    args = parse_args()
    cfg = build_config(args)

    if args.mode == "live":
        run_live(cfg)
    elif args.mode == "backtest":
        run_backtest(cfg, args.symbol, args.lookback_days, args.warmup_bars, args.csv_dir)
    elif args.mode == "optimize":
        run_optimize(cfg, args.symbol, args.lookback_days, args.warmup_bars, args.csv_dir)
    elif args.mode == "debug":
        run_debug(cfg, args.symbol, args.lookback_days, args.csv_dir)
    else:
        print(f"Unknown mode: {args.mode}")
        sys.exit(1)


if __name__ == "__main__":
    main()
