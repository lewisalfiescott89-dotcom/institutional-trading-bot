"""
Global configuration settings for the institutional trading bot.
All tunable parameters live here so the user can adjust without touching strategy code.
"""

from dataclasses import dataclass, field
from typing import Dict, List, Optional


# ---------------------------------------------------------------------------
# MT5 connection
# ---------------------------------------------------------------------------
@dataclass
class MT5Settings:
    """MetaTrader 5 connection settings."""
    path: str = ""                       # path to terminal64.exe (leave blank for default)
    login: int = 0                       # MT5 account number
    password: str = ""                   # MT5 password
    server: str = "Pepperstone-Demo"     # e.g. Pepperstone-Live / Pepperstone-Demo
    timeout: int = 10_000                # connection timeout ms


# ---------------------------------------------------------------------------
# Timeframe configuration
# ---------------------------------------------------------------------------
ANALYSIS_TIMEFRAMES: List[str] = [
    "MN1",   # Monthly  – macro liquidity
    "W1",    # Weekly   – major institutional zones
    "D1",    # Daily    – directional bias
    "H4",    # H4       – major POIs
    "H1",    # H1       – refinement
    "M15",   # M15      – local liquidity / local POIs
    "M5",    # M5       – execution only
]

EXECUTION_TIMEFRAME: str = "M5"


# ---------------------------------------------------------------------------
# Timeframe weights (used in scoring – higher = more significant)
# ---------------------------------------------------------------------------
TIMEFRAME_WEIGHTS: Dict[str, float] = {
    "MN1": 10.0,
    "W1":  8.0,
    "D1":  6.0,
    "H4":  4.0,
    "H1":  3.0,
    "M15": 2.0,
    "M5":  1.0,
}


# ---------------------------------------------------------------------------
# POI detection
# ---------------------------------------------------------------------------
@dataclass
class POISettings:
    displacement_multiplier: float = 1.5    # how many ATR the displacement candle must move
    atr_period: int = 14
    min_body_ratio: float = 0.5             # min body-to-range ratio for displacement candle
    cluster_overlap_pct: float = 0.30       # % overlap to merge into cluster
    max_poi_age_bars: int = 500             # bars after which a POI is considered stale
    freshness_decay_per_touch: float = 0.20 # score decay per re-test


# ---------------------------------------------------------------------------
# FVG detection
# ---------------------------------------------------------------------------
@dataclass
class FVGSettings:
    min_gap_atr_ratio: float = 0.3   # gap must be at least this fraction of ATR
    max_gap_atr_ratio: float = 5.0   # extremely wide gaps are noise


# ---------------------------------------------------------------------------
# Liquidity detection
# ---------------------------------------------------------------------------
@dataclass
class LiquiditySettings:
    equal_level_tolerance_pips: float = 3.0   # how close prices must be to count as "equal"
    swing_lookback: int = 10                   # bars each side for swing detection
    min_touches_for_equal: int = 2


# ---------------------------------------------------------------------------
# Sweep detection
# ---------------------------------------------------------------------------
@dataclass
class SweepSettings:
    min_penetration_pips: float = 1.0
    max_penetration_pips: float = 30.0
    rejection_body_ratio: float = 0.40   # wick vs body quality
    max_distance_from_poi_pips: float = 20.0


# ---------------------------------------------------------------------------
# Trap detection
# ---------------------------------------------------------------------------
@dataclass
class TrapSettings:
    min_break_pips: float = 2.0
    max_reclaim_bars: int = 3
    min_reversal_body_ratio: float = 0.50


# ---------------------------------------------------------------------------
# Reversal candle
# ---------------------------------------------------------------------------
@dataclass
class ReversalSettings:
    min_engulfing_ratio: float = 1.0     # how much the engulfing body must cover prior body
    min_pin_wick_ratio: float = 2.0      # wick length / body length
    min_displacement_atr: float = 1.2    # displacement candle in ATR terms


# ---------------------------------------------------------------------------
# Trade quality grading
# ---------------------------------------------------------------------------
@dataclass
class GradingSettings:
    a_plus_threshold: float = 85.0
    a_threshold: float = 70.0
    b_threshold: float = 55.0
    c_threshold: float = 40.0
    # below c_threshold → D (no trade)


# ---------------------------------------------------------------------------
# Risk management
# ---------------------------------------------------------------------------
@dataclass
class RiskSettings:
    grade_risk_map: Dict[str, float] = field(default_factory=lambda: {
        "A+": 2.00,
        "A":  1.00,
        "B":  0.50,
        "C":  0.25,
        "D":  0.00,
    })
    default_sl_pips: float = 30.0       # default stop-loss distance
    max_daily_drawdown_pct: float = 5.0
    max_consecutive_losses: int = 5
    high_vol_risk_multiplier: float = 0.5   # scale risk down in high-vol regime


# ---------------------------------------------------------------------------
# Commission model (Pepperstone raw spread)
# ---------------------------------------------------------------------------
@dataclass
class CommissionSettings:
    forex_per_lot: float = 7.0              # USD per standard lot round-turn
    commodity_pct: float = 0.0016           # % of position value per lot
    crypto_pct: float = 0.04               # % of position value per lot
    index_per_lot: float = 0.0             # zero commission


# ---------------------------------------------------------------------------
# Spread safety
# ---------------------------------------------------------------------------
DEFAULT_MAX_SPREAD: Dict[str, float] = {
    "XAUUSD": 5.0,
    "GBPUSD": 2.0,
    "EURUSD": 1.5,
    "US30":   5.0,
    "BTCUSD": 50.0,
}


# ---------------------------------------------------------------------------
# Session times (UTC)
# ---------------------------------------------------------------------------
@dataclass
class SessionSettings:
    asian_start: int = 0       # 00:00 UTC
    asian_end: int = 8         # 08:00 UTC
    london_start: int = 7      # 07:00 UTC
    london_end: int = 16       # 16:00 UTC
    newyork_start: int = 12    # 12:00 UTC
    newyork_end: int = 21      # 21:00 UTC
    # Kill zones (highest-probability windows)
    london_kz_start: int = 7
    london_kz_end: int = 10
    ny_kz_start: int = 12
    ny_kz_end: int = 15
    overlap_start: int = 12
    overlap_end: int = 16


# ---------------------------------------------------------------------------
# Safety / protection
# ---------------------------------------------------------------------------
@dataclass
class SafetySettings:
    max_slippage_pips: float = 5.0
    abnormal_vol_atr_multiplier: float = 3.0
    connection_retry_attempts: int = 3
    connection_retry_delay_sec: float = 5.0
    emergency_pause: bool = False          # manual kill switch


# ---------------------------------------------------------------------------
# Backtesting
# ---------------------------------------------------------------------------
@dataclass
class BacktestSettings:
    initial_balance: float = 100_000.0
    default_lookback_bars: int = 50_000
    train_pct: float = 0.70
    test_pct: float = 0.30


# ---------------------------------------------------------------------------
# Regime detection
# ---------------------------------------------------------------------------
@dataclass
class RegimeSettings:
    atr_period: int = 14
    trend_atr_threshold: float = 1.2     # ATR vs MA(ATR) ratio
    range_atr_threshold: float = 0.8
    low_liquidity_volume_pct: float = 0.3  # below 30% of avg volume = low liquidity


# ---------------------------------------------------------------------------
# Structure detection
# ---------------------------------------------------------------------------
@dataclass
class StructureSettings:
    swing_lookback: int = 5    # bars each side to confirm a swing


# ---------------------------------------------------------------------------
# Timing engine
# ---------------------------------------------------------------------------
@dataclass
class TimingSettings:
    stale_setup_bars: int = 12           # if price lingers >12 5M bars in POI without resolving
    weak_setup_outside_kz: bool = True   # block C-grade setups outside kill zones


# ---------------------------------------------------------------------------
# Global bot config (aggregates all sub-configs)
# ---------------------------------------------------------------------------
@dataclass
class BotConfig:
    mt5: MT5Settings = field(default_factory=MT5Settings)
    poi: POISettings = field(default_factory=POISettings)
    fvg: FVGSettings = field(default_factory=FVGSettings)
    liquidity: LiquiditySettings = field(default_factory=LiquiditySettings)
    sweep: SweepSettings = field(default_factory=SweepSettings)
    trap: TrapSettings = field(default_factory=TrapSettings)
    reversal: ReversalSettings = field(default_factory=ReversalSettings)
    grading: GradingSettings = field(default_factory=GradingSettings)
    risk: RiskSettings = field(default_factory=RiskSettings)
    commission: CommissionSettings = field(default_factory=CommissionSettings)
    sessions: SessionSettings = field(default_factory=SessionSettings)
    safety: SafetySettings = field(default_factory=SafetySettings)
    backtest: BacktestSettings = field(default_factory=BacktestSettings)
    regime: RegimeSettings = field(default_factory=RegimeSettings)
    structure: StructureSettings = field(default_factory=StructureSettings)
    timing: TimingSettings = field(default_factory=TimingSettings)
    max_spread: Dict[str, float] = field(default_factory=lambda: DEFAULT_MAX_SPREAD.copy())
    symbols: List[str] = field(default_factory=lambda: [
        "XAUUSD", "GBPUSD", "EURUSD", "US30", "BTCUSD",
    ])
    dry_run: bool = True                  # safety: start in dry-run mode
    state_file: str = "bot_state.json"    # persistence file
    log_file: str = "bot.log"
    debug_charts: bool = True
