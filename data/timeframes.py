"""
Timeframe utilities – mapping between string names and MT5 constants,
plus helpers for bar-count estimation.
"""

from __future__ import annotations

from typing import Dict, Optional

# We import MetaTrader5 constants lazily so the rest of the codebase can
# still be tested / backtested without MT5 installed.
try:
    import MetaTrader5 as mt5  # type: ignore

    MT5_TF_MAP: Dict[str, int] = {
        "M1":  mt5.TIMEFRAME_M1,
        "M5":  mt5.TIMEFRAME_M5,
        "M15": mt5.TIMEFRAME_M15,
        "M30": mt5.TIMEFRAME_M30,
        "H1":  mt5.TIMEFRAME_H1,
        "H4":  mt5.TIMEFRAME_H4,
        "D1":  mt5.TIMEFRAME_D1,
        "W1":  mt5.TIMEFRAME_W1,
        "MN1": mt5.TIMEFRAME_MN1,
    }
except ImportError:
    # Fallback integer values matching MT5 constants for offline usage
    MT5_TF_MAP: Dict[str, int] = {  # type: ignore[no-redef]
        "M1":  1,
        "M5":  5,
        "M15": 15,
        "M30": 30,
        "H1":  16385,
        "H4":  16388,
        "D1":  16408,
        "W1":  32769,
        "MN1": 49153,
    }


# Minutes per bar for each timeframe (approximate for W1/MN1)
TF_MINUTES: Dict[str, int] = {
    "M1":  1,
    "M5":  5,
    "M15": 15,
    "M30": 30,
    "H1":  60,
    "H4":  240,
    "D1":  1440,
    "W1":  10080,
    "MN1": 43200,
}

# Ordered from highest to lowest timeframe
TF_ORDER: list = ["MN1", "W1", "D1", "H4", "H1", "M15", "M5"]


def mt5_timeframe(tf_str: str) -> int:
    """Convert a string timeframe to its MT5 integer constant."""
    if tf_str not in MT5_TF_MAP:
        raise ValueError(f"Unknown timeframe: {tf_str}")
    return MT5_TF_MAP[tf_str]


def tf_to_minutes(tf_str: str) -> int:
    """Return approximate minutes per bar for *tf_str*."""
    return TF_MINUTES.get(tf_str, 5)


def bars_needed(tf_str: str, lookback_days: int = 180) -> int:
    """Estimate how many bars to request for *lookback_days* of data."""
    minutes = tf_to_minutes(tf_str)
    if minutes == 0:
        return 500
    total_minutes = lookback_days * 24 * 60
    return max(500, total_minutes // minutes)


def is_higher_timeframe(tf_a: str, tf_b: str) -> bool:
    """Return True if tf_a is a higher timeframe than tf_b."""
    return tf_to_minutes(tf_a) > tf_to_minutes(tf_b)
