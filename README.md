# Institutional Trading Bot

A production-structured Python algorithmic trading bot for **MetaTrader 5 / Pepperstone raw spread account** that trades using institutional/smart-money-style logic: multi-timeframe POIs, liquidity sweeps, traps, reversal candles, and 5-minute execution.

## Architecture

```
institutional_bot/
  main.py                          # CLI entry point (live / backtest / optimize / debug)
  requirements.txt
  README.md

  config/
    settings.py                    # All tunable parameters
    symbols.py                     # Instrument specs (pip size, contract size, etc.)

  core/
    orchestrator.py                # Central execution loop (20-step cycle)
    state_manager.py               # JSON-based state persistence
    logger.py                      # Structured logging
    utils.py                       # ATR, swing detection, overlap helpers

  data/
    mt5_connector.py               # MT5 connection lifecycle
    market_data.py                 # OHLCV fetcher + CSV fallback
    timeframes.py                  # TF mapping and bar estimation

  models/
    poi.py                         # Point of Interest (order blocks, zones)
    liquidity.py                   # Liquidity level model
    signal.py                      # Scored trade signal
    trade.py                       # Trade lifecycle model
    regime.py                      # Market regime classification
    state.py                       # Persistent bot state

  analysis/
    structure_engine.py            # HH/HL/LH/LL, BOS, CHoCH
    regime_engine.py               # Trend / Range / High-Vol / Low-Liq
    poi_engine.py                  # Order block detection + projection
    poi_cluster_engine.py          # Multi-TF POI merging
    fvg_engine.py                  # Fair Value Gap detection
    liquidity_map_engine.py        # Equal highs/lows, session levels, swings
    liquidity_forecast_engine.py   # Predicts next liquidity target
    liquidity_timing_engine.py     # Kill-zone / stale-setup rules
    session_engine.py              # Session identification + level tracking
    sweep_engine.py                # Wick sweep + close-reclaim detection
    trap_engine.py                 # Bull/bear trap detection
    reversal_engine.py             # Engulfing, pin bar, displacement, reclaim
    trade_quality_engine.py        # Multi-confluence scoring + grading

  risk/
    risk_engine.py                 # Grade-to-risk mapping + drawdown limits
    commission_engine.py           # Pepperstone commission model
    position_sizer.py              # Lot size calculation

  execution/
    executor.py                    # MT5 order placement + dry-run
    trade_manager.py               # SL/TP management + PnL accounting
    safety_engine.py               # Hard veto layer (spread, volatility, etc.)

  backtesting/
    backtester.py                  # Bar-by-bar historical replay
    optimizer.py                   # Parameter sweep with train/test split
    metrics.py                     # Performance statistics

  visualization/
    chart_debugger.py              # Interactive Plotly debug chart
    plotter.py                     # Equity curve, drawdown, distribution
```

## Quick Start

### 1. Install dependencies

```bash
pip install -r requirements.txt
```

> **Note:** The `MetaTrader5` package only works on Windows. For backtesting on Linux/macOS, use CSV files with `--csv-dir`.

### 2. Configure your broker

Edit `config/settings.py` → `MT5Settings`:

```python
@dataclass
class MT5Settings:
    path: str = r"C:\Program Files\Pepperstone MetaTrader 5\terminal64.exe"
    login: int = 12345678          # Your MT5 account number
    password: str = "your_pass"    # Your MT5 password
    server: str = "Pepperstone-Live"
```

### 3. Configure symbols

Edit `config/symbols.py` if your Pepperstone terminal uses different symbol names (e.g. `XAUUSD.r`):

```python
BROKER_SUFFIX: str = ""   # Change to ".r" if needed
```

### 4. Run in dry-run mode (recommended first)

```bash
python main.py live --dry-run
```

This connects to MT5, analyses all symbols, and logs what it **would** trade — without placing real orders.

### 5. Run a backtest

```bash
# From MT5 (requires Windows + MT5 running):
python main.py backtest --symbol XAUUSD --lookback-days 180

# From CSV files (any OS):
python main.py backtest --symbol XAUUSD --csv-dir ./data/csv/
```

CSV files should be named `{SYMBOL}_{TIMEFRAME}.csv` (e.g. `XAUUSD_M5.csv`) with columns: `time, open, high, low, close, volume`.

### 6. Optimize parameters

```bash
python main.py optimize --symbol XAUUSD --csv-dir ./data/csv/
```

### 7. Generate a debug chart

```bash
python main.py debug --symbol XAUUSD --csv-dir ./data/csv/
```

Opens an interactive Plotly chart showing POIs, liquidity, FVGs, sweeps, and more.

### 8. Enable live trading

```bash
python main.py live --live-trade
```

> **WARNING:** This places real orders with real money. Ensure you have tested thoroughly first.

## Strategy Overview

### Execution Flow (per 5M candle)

1. Sync MT5 data for all timeframes (MN1 → M5)
2. Detect POIs (order blocks) on every timeframe
3. Detect FVGs and boost overlapping POIs
4. Project all higher-TF POIs onto the 5M chart
5. Cluster overlapping POIs into stronger zones
6. Build the liquidity map (equal highs/lows, session levels, swings)
7. Forecast the next likely liquidity target
8. Analyse market structure (HH/HL/LH/LL, BOS, CHoCH)
9. Classify market regime (trend/range/high-vol/low-liq)
10. Identify session and kill zone
11. For each active POI on the 5M chart:
    - Check Pepperstone invalidation rule (wick OK, next-open-beyond = blown)
    - Detect liquidity sweeps and traps
    - Wait for reversal candle confirmation
    - Score the full setup (POI + cluster + liquidity + structure + regime + timing + sweep + trap + reversal)
    - Grade: A+ / A / B / C / D
12. Run safety checks (spread, volatility, drawdown, consecutive losses)
13. Calculate risk % and lot size based on grade
14. Execute or wait
15. Manage open trades (SL/TP)
16. Save state to disk

### Grading → Risk Mapping

| Grade | Risk % | Description |
|-------|--------|-------------|
| A+    | 2.00%  | Highest conviction setup |
| A     | 1.00%  | Strong multi-confluence |
| B     | 0.50%  | Decent setup |
| C     | 0.25%  | Marginal (blocked outside kill zones) |
| D     | 0.00%  | No trade |

### Commission Model (Pepperstone Raw Spread)

| Asset Class | Commission |
|-------------|------------|
| Forex       | $7 per standard lot |
| Commodities | 0.0016% of position value |
| Crypto      | 0.04% of position value |
| Indices     | $0 |

### Safety Protections

- Spread filter (configurable per symbol)
- Daily drawdown limit (default 5%)
- Consecutive loss limit (default 5)
- Abnormal volatility filter
- Emergency pause switch
- Connection monitoring with auto-reconnect

## Key Design Decisions

- **All trades execute on the 5M chart only** — higher timeframes are for analysis
- **Pepperstone 5M invalidation rule**: a wick beyond the zone is allowed, but if the next 5M candle *opens* beyond the zone, the zone is blown
- **No entry on touch** — every trade requires a reversal candle confirmation
- **Re-entry allowed** — if a zone remains valid after a stop-out, a fresh sweep + reversal can trigger a new trade
- **State persists across restarts** via JSON file
- **Modular architecture** — every engine is independently testable

## Customization

All parameters are in `config/settings.py`. Key knobs:

- `POISettings.displacement_multiplier` — how strong the displacement must be
- `SweepSettings.min_penetration_pips` — minimum sweep depth
- `ReversalSettings.min_engulfing_ratio` — engulfing body coverage
- `GradingSettings.*_threshold` — score thresholds for each grade
- `RiskSettings.grade_risk_map` — risk allocation per grade
- `TimingSettings.stale_setup_bars` — bars before a setup is degraded
- `SafetySettings.emergency_pause` — manual kill switch

## License

Private / proprietary. Not for redistribution.
