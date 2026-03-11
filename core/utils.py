"""
General utility helpers used throughout the bot.
"""

from __future__ import annotations

import time
from datetime import datetime, timezone
from typing import List, Optional

import numpy as np
import pandas as pd


# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------

def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def epoch_now() -> float:
    return time.time()


def epoch_to_dt(epoch: float) -> datetime:
    return datetime.fromtimestamp(epoch, tz=timezone.utc)


# ---------------------------------------------------------------------------
# Price / candle helpers
# ---------------------------------------------------------------------------

def candle_body(open_: float, close: float) -> float:
    """Absolute body size."""
    return abs(close - open_)


def candle_range(high: float, low: float) -> float:
    return high - low


def candle_upper_wick(open_: float, close: float, high: float) -> float:
    return high - max(open_, close)


def candle_lower_wick(open_: float, close: float, low: float) -> float:
    return min(open_, close) - low


def is_bullish(open_: float, close: float) -> bool:
    return close > open_


def is_bearish(open_: float, close: float) -> bool:
    return close < open_


def body_ratio(open_: float, close: float, high: float, low: float) -> float:
    """Body as fraction of total range."""
    r = candle_range(high, low)
    if r == 0:
        return 0.0
    return candle_body(open_, close) / r


# ---------------------------------------------------------------------------
# ATR calculation
# ---------------------------------------------------------------------------

def compute_atr(highs: np.ndarray, lows: np.ndarray, closes: np.ndarray,
                period: int = 14) -> np.ndarray:
    """Compute Average True Range using Wilder smoothing."""
    n = len(highs)
    tr = np.empty(n)
    tr[0] = highs[0] - lows[0]
    for i in range(1, n):
        tr[i] = max(
            highs[i] - lows[i],
            abs(highs[i] - closes[i - 1]),
            abs(lows[i] - closes[i - 1]),
        )
    atr = np.empty(n)
    atr[:period] = np.nan
    atr[period - 1] = np.mean(tr[:period])
    for i in range(period, n):
        atr[i] = (atr[i - 1] * (period - 1) + tr[i]) / period
    return atr


# ---------------------------------------------------------------------------
# Swing detection
# ---------------------------------------------------------------------------

def detect_swing_highs(highs: np.ndarray, lookback: int = 5) -> List[int]:
    """Return bar indices that are local swing highs."""
    swings: List[int] = []
    n = len(highs)
    for i in range(lookback, n - lookback):
        if all(highs[i] >= highs[i - j] for j in range(1, lookback + 1)) and \
           all(highs[i] >= highs[i + j] for j in range(1, lookback + 1)):
            swings.append(i)
    return swings


def detect_swing_lows(lows: np.ndarray, lookback: int = 5) -> List[int]:
    """Return bar indices that are local swing lows."""
    swings: List[int] = []
    n = len(lows)
    for i in range(lookback, n - lookback):
        if all(lows[i] <= lows[i - j] for j in range(1, lookback + 1)) and \
           all(lows[i] <= lows[i + j] for j in range(1, lookback + 1)):
            swings.append(i)
    return swings


# ---------------------------------------------------------------------------
# Overlap / clustering helpers
# ---------------------------------------------------------------------------

def zones_overlap(low1: float, high1: float, low2: float, high2: float) -> bool:
    """Return True if two price zones overlap at all."""
    return low1 <= high2 and low2 <= high1


def overlap_pct(low1: float, high1: float, low2: float, high2: float) -> float:
    """Return the overlap as a fraction of the smaller zone."""
    overlap_low = max(low1, low2)
    overlap_high = min(high1, high2)
    if overlap_high <= overlap_low:
        return 0.0
    overlap_size = overlap_high - overlap_low
    smaller = min(high1 - low1, high2 - low2)
    if smaller == 0:
        return 0.0
    return overlap_size / smaller


# ---------------------------------------------------------------------------
# DataFrame helpers
# ---------------------------------------------------------------------------

def df_to_numpy(df: pd.DataFrame, col: str) -> np.ndarray:
    """Safely extract a column as numpy array."""
    return df[col].to_numpy(dtype=float)
