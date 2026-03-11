"""
Fair Value Gap (FVG) Engine – detects classic 3-candle FVGs and tracks fill state.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import List, Optional

import numpy as np
import pandas as pd

from config.settings import FVGSettings, TIMEFRAME_WEIGHTS
from core.utils import compute_atr, to_epoch
from models.poi import POI, POIDirection, POIType


class FVGDirection(str, Enum):
    BULLISH = "bullish"
    BEARISH = "bearish"


class FVGFillState(str, Enum):
    UNFILLED = "unfilled"
    PARTIALLY_FILLED = "partially_filled"
    FULLY_FILLED = "fully_filled"


@dataclass
class FVG:
    """Represents a single Fair Value Gap."""
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])
    symbol: str = ""
    timeframe: str = ""
    direction: FVGDirection = FVGDirection.BULLISH
    gap_low: float = 0.0
    gap_high: float = 0.0
    fill_state: FVGFillState = FVGFillState.UNFILLED
    quality: float = 0.0
    bar_index: int = 0
    timestamp: float = 0.0

    def gap_size(self) -> float:
        return self.gap_high - self.gap_low

    def contains_price(self, price: float) -> bool:
        return self.gap_low <= price <= self.gap_high

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "symbol": self.symbol,
            "timeframe": self.timeframe,
            "direction": self.direction.value,
            "gap_low": self.gap_low,
            "gap_high": self.gap_high,
            "fill_state": self.fill_state.value,
            "quality": self.quality,
            "bar_index": self.bar_index,
        }


class FVGEngine:
    """Detects and scores Fair Value Gaps."""

    def __init__(self, settings: Optional[FVGSettings] = None) -> None:
        self.cfg = settings or FVGSettings()

    def detect(
        self,
        df: pd.DataFrame,
        symbol: str,
        timeframe: str,
    ) -> List[FVG]:
        """
        Detect 3-candle FVGs on the provided DataFrame.

        Bullish FVG: candle[i+2].low > candle[i].high  (gap up)
        Bearish FVG: candle[i+2].high < candle[i].low  (gap down)
        """
        if df.empty or len(df) < 20:
            return []

        opens = df["open"].to_numpy(dtype=float)
        highs = df["high"].to_numpy(dtype=float)
        lows = df["low"].to_numpy(dtype=float)
        closes = df["close"].to_numpy(dtype=float)
        times = df["time"].to_numpy() if "time" in df.columns else np.zeros(len(df))

        atr = compute_atr(highs, lows, closes, period=14)

        fvgs: List[FVG] = []

        for i in range(len(df) - 2):
            if np.isnan(atr[i]):
                continue
            current_atr = atr[i]
            if current_atr <= 0:
                continue

            c1_high = highs[i]
            c1_low = lows[i]
            c3_high = highs[i + 2]
            c3_low = lows[i + 2]

            # Bullish FVG
            if c3_low > c1_high:
                gap_size = c3_low - c1_high
                ratio = gap_size / current_atr
                if self.cfg.min_gap_atr_ratio <= ratio <= self.cfg.max_gap_atr_ratio:
                    fvg = FVG(
                        symbol=symbol,
                        timeframe=timeframe,
                        direction=FVGDirection.BULLISH,
                        gap_low=c1_high,
                        gap_high=c3_low,
                        quality=min(ratio * 10.0, 10.0),
                        bar_index=i + 1,
                        timestamp=to_epoch(times[i + 1]),
                    )
                    fvgs.append(fvg)

            # Bearish FVG
            if c3_high < c1_low:
                gap_size = c1_low - c3_high
                ratio = gap_size / current_atr
                if self.cfg.min_gap_atr_ratio <= ratio <= self.cfg.max_gap_atr_ratio:
                    fvg = FVG(
                        symbol=symbol,
                        timeframe=timeframe,
                        direction=FVGDirection.BEARISH,
                        gap_low=c3_high,
                        gap_high=c1_low,
                        quality=min(ratio * 10.0, 10.0),
                        bar_index=i + 1,
                        timestamp=to_epoch(times[i + 1]),
                    )
                    fvgs.append(fvg)

        return fvgs

    def update_fill_state(self, fvgs: List[FVG], df: pd.DataFrame) -> None:
        """Update FVG fill state based on subsequent price action."""
        if df.empty:
            return
        for fvg in fvgs:
            if fvg.fill_state == FVGFillState.FULLY_FILLED:
                continue
            # Check all bars after the FVG was created
            start = fvg.bar_index + 2
            if start >= len(df):
                continue
            for i in range(start, len(df)):
                low = df.iloc[i]["low"]
                high = df.iloc[i]["high"]
                if fvg.direction == FVGDirection.BULLISH:
                    # Price needs to come down into the gap
                    if low <= fvg.gap_low:
                        fvg.fill_state = FVGFillState.FULLY_FILLED
                        break
                    elif low <= fvg.gap_high:
                        fvg.fill_state = FVGFillState.PARTIALLY_FILLED
                else:
                    # Price needs to come up into the gap
                    if high >= fvg.gap_high:
                        fvg.fill_state = FVGFillState.FULLY_FILLED
                        break
                    elif high >= fvg.gap_low:
                        fvg.fill_state = FVGFillState.PARTIALLY_FILLED

    def fvg_overlaps_poi(self, fvg: FVG, poi: POI) -> bool:
        """Return True if the FVG overlaps with the POI zone."""
        return fvg.gap_low <= poi.zone_high and poi.zone_low <= fvg.gap_high

    def boost_poi_with_fvgs(self, pois: List[POI], fvgs: List[FVG]) -> None:
        """Increase POI score if an unfilled FVG overlaps it."""
        for poi in pois:
            for fvg in fvgs:
                if fvg.fill_state == FVGFillState.FULLY_FILLED:
                    continue
                if not self._directions_align(poi, fvg):
                    continue
                if self.fvg_overlaps_poi(fvg, poi):
                    poi.score += fvg.quality * 0.5
                    poi.confluences.append(f"fvg_{fvg.direction.value}_{fvg.timeframe}")

    @staticmethod
    def _directions_align(poi: POI, fvg: FVG) -> bool:
        if poi.direction.value == "bullish" and fvg.direction == FVGDirection.BULLISH:
            return True
        if poi.direction.value == "bearish" and fvg.direction == FVGDirection.BEARISH:
            return True
        return False
