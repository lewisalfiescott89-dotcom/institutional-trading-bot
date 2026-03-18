"""
Reversal Candle Engine – confirms entries via bearish/bullish reversal patterns.

The bot does NOT enter on touch – it waits for a reversal candle.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import List, Optional

import pandas as pd

from config.settings import ReversalSettings
from core.utils import (
    candle_body, candle_range, candle_upper_wick, candle_lower_wick,
    is_bullish, is_bearish, compute_atr,
)
from models.poi import POI, POIDirection
import numpy as np


class ReversalType(str, Enum):
    BEARISH_ENGULFING = "bearish_engulfing"
    BEARISH_PIN_BAR = "bearish_pin_bar"
    BEARISH_DISPLACEMENT = "bearish_displacement"
    BEARISH_RECLAIM = "bearish_reclaim"
    BULLISH_ENGULFING = "bullish_engulfing"
    BULLISH_PIN_BAR = "bullish_pin_bar"
    BULLISH_DISPLACEMENT = "bullish_displacement"
    BULLISH_RECLAIM = "bullish_reclaim"
    NONE = "none"


@dataclass
class ReversalEvent:
    """A confirmed reversal candle at a POI."""
    reversal_type: ReversalType = ReversalType.NONE
    quality: float = 0.0          # 0-10
    bar_index: int = 0
    close_price: float = 0.0
    direction: str = ""           # "bullish" or "bearish" (the trade direction)

    def to_dict(self) -> dict:
        return {
            "reversal_type": self.reversal_type.value,
            "quality": self.quality,
            "bar_index": self.bar_index,
            "close_price": self.close_price,
            "direction": self.direction,
        }


class ReversalEngine:
    """Detects reversal candle patterns at POIs."""

    def __init__(self, settings: Optional[ReversalSettings] = None) -> None:
        self.cfg = settings or ReversalSettings()

    def detect(
        self,
        df: pd.DataFrame,
        poi: POI,
        bar_index: Optional[int] = None,
    ) -> Optional[ReversalEvent]:
        """
        Check for a reversal candle at *poi*.

        The candle must be at or very near the POI zone.
        Entry is at the CLOSE of the reversal candle.

        Parameters
        ----------
        df : 5M OHLCV DataFrame.
        poi : the active POI being tested.
        bar_index : specific bar to check (default: last completed bar).
        """
        if df.empty or len(df) < 3:
            return None

        idx = bar_index if bar_index is not None else len(df) - 1
        if idx < 1 or idx >= len(df):
            return None

        row = df.iloc[idx]
        prev = df.iloc[idx - 1]

        o = float(row["open"])
        h = float(row["high"])
        l = float(row["low"])
        c = float(row["close"])
        po = float(prev["open"])
        ph = float(prev["high"])
        pl = float(prev["low"])
        pc = float(prev["close"])

        body = candle_body(o, c)
        rng = candle_range(h, l)
        prev_body = candle_body(po, pc)

        # Compute ATR for displacement check
        highs = df["high"].to_numpy(dtype=float)
        lows = df["low"].to_numpy(dtype=float)
        closes = df["close"].to_numpy(dtype=float)
        atr_arr = compute_atr(highs, lows, closes, 14)
        atr_val = atr_arr[idx] if not np.isnan(atr_arr[idx]) else rng

        # --- SELL reversals (at bearish / supply POI) ---
        if poi.direction == POIDirection.BEARISH:
            # Check price is in or near zone
            if h < poi.zone_low:
                return None  # candle didn't reach the zone

            # 1. Bearish engulfing
            if is_bearish(o, c) and is_bullish(po, pc):
                if body >= prev_body * self.cfg.min_engulfing_ratio:
                    quality = min(body / (prev_body + 1e-10) * 5.0, 10.0)
                    return ReversalEvent(
                        reversal_type=ReversalType.BEARISH_ENGULFING,
                        quality=round(quality, 2),
                        bar_index=idx,
                        close_price=c,
                        direction="bearish",
                    )

            # 2. Bearish pin bar (shooting star)
            if rng > 0 and (is_bearish(o, c) or body < rng * 0.3):
                upper_wick = candle_upper_wick(o, c, h)
                lower_wick = candle_lower_wick(o, c, l)
                if body > 0 and upper_wick / body >= self.cfg.min_pin_wick_ratio and upper_wick > lower_wick * 2:
                    quality = min(upper_wick / body * 3.0, 10.0)
                    return ReversalEvent(
                        reversal_type=ReversalType.BEARISH_PIN_BAR,
                        quality=round(quality, 2),
                        bar_index=idx,
                        close_price=c,
                        direction="bearish",
                    )

            # 3. Bearish displacement candle
            if is_bearish(o, c) and body >= atr_val * self.cfg.min_displacement_atr:
                quality = min(body / atr_val * 5.0, 10.0)
                return ReversalEvent(
                    reversal_type=ReversalType.BEARISH_DISPLACEMENT,
                    quality=round(quality, 2),
                    bar_index=idx,
                    close_price=c,
                    direction="bearish",
                )

            # 4. Reclaim close back below zone
            if o > poi.zone_high and c < poi.zone_high and is_bearish(o, c):
                quality = min(body / rng * 8.0 if rng > 0 else 5.0, 10.0)
                return ReversalEvent(
                    reversal_type=ReversalType.BEARISH_RECLAIM,
                    quality=round(quality, 2),
                    bar_index=idx,
                    close_price=c,
                    direction="bearish",
                )

        # --- BUY reversals (at bullish / demand POI) ---
        elif poi.direction == POIDirection.BULLISH:
            if l > poi.zone_high:
                return None

            # 1. Bullish engulfing
            if is_bullish(o, c) and is_bearish(po, pc):
                if body >= prev_body * self.cfg.min_engulfing_ratio:
                    quality = min(body / (prev_body + 1e-10) * 5.0, 10.0)
                    return ReversalEvent(
                        reversal_type=ReversalType.BULLISH_ENGULFING,
                        quality=round(quality, 2),
                        bar_index=idx,
                        close_price=c,
                        direction="bullish",
                    )

            # 2. Bullish pin bar (hammer)
            if rng > 0 and (is_bullish(o, c) or body < rng * 0.3):
                lower_wick = candle_lower_wick(o, c, l)
                upper_wick = candle_upper_wick(o, c, h)
                if body > 0 and lower_wick / body >= self.cfg.min_pin_wick_ratio and lower_wick > upper_wick * 2:
                    quality = min(lower_wick / body * 3.0, 10.0)
                    return ReversalEvent(
                        reversal_type=ReversalType.BULLISH_PIN_BAR,
                        quality=round(quality, 2),
                        bar_index=idx,
                        close_price=c,
                        direction="bullish",
                    )

            # 3. Bullish displacement candle
            if is_bullish(o, c) and body >= atr_val * self.cfg.min_displacement_atr:
                quality = min(body / atr_val * 5.0, 10.0)
                return ReversalEvent(
                    reversal_type=ReversalType.BULLISH_DISPLACEMENT,
                    quality=round(quality, 2),
                    bar_index=idx,
                    close_price=c,
                    direction="bullish",
                )

            # 4. Reclaim close back above zone
            if o < poi.zone_low and c > poi.zone_low and is_bullish(o, c):
                quality = min(body / rng * 8.0 if rng > 0 else 5.0, 10.0)
                return ReversalEvent(
                    reversal_type=ReversalType.BULLISH_RECLAIM,
                    quality=round(quality, 2),
                    bar_index=idx,
                    close_price=c,
                    direction="bullish",
                )

        return None
