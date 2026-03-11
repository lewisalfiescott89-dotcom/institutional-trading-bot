"""
Liquidity Sweep Engine – detects when price briefly runs a liquidity level
and fails (wick sweep or close-through-then-reclaim).
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import List, Optional

import numpy as np
import pandas as pd

from config.settings import SweepSettings
from config.symbols import price_to_pips, pips_to_price
from core.utils import candle_body, candle_range, candle_upper_wick, candle_lower_wick
from models.liquidity import LiquidityLevel, LiquiditySide
from models.poi import POI, POIDirection


class SweepType(str, Enum):
    WICK = "wick"                        # single candle wick through level then close back
    CLOSE_RECLAIM = "close_reclaim"      # close through then next candle reclaims


@dataclass
class SweepEvent:
    """A detected liquidity sweep."""
    symbol: str = ""
    sweep_type: SweepType = SweepType.WICK
    direction: str = ""          # "bullish" (swept below → reversal up) or "bearish"
    liquidity_price: float = 0.0
    penetration_pips: float = 0.0
    rejection_quality: float = 0.0  # 0-10
    bar_index: int = 0
    score: float = 0.0
    level_id: str = ""

    def to_dict(self) -> dict:
        return {
            "symbol": self.symbol,
            "sweep_type": self.sweep_type.value,
            "direction": self.direction,
            "liquidity_price": self.liquidity_price,
            "penetration_pips": self.penetration_pips,
            "rejection_quality": self.rejection_quality,
            "bar_index": self.bar_index,
            "score": self.score,
            "level_id": self.level_id,
        }


class SweepEngine:
    """Detects liquidity sweeps at the candle level."""

    def __init__(self, settings: Optional[SweepSettings] = None) -> None:
        self.cfg = settings or SweepSettings()

    def detect(
        self,
        df: pd.DataFrame,
        symbol: str,
        liquidity_levels: List[LiquidityLevel],
        active_pois: Optional[List[POI]] = None,
        bar_index: Optional[int] = None,
    ) -> List[SweepEvent]:
        """
        Scan the latest candle(s) for sweep events against known liquidity.

        Parameters
        ----------
        df : OHLCV DataFrame (at least 3 recent candles).
        symbol : instrument name.
        liquidity_levels : active liquidity levels.
        active_pois : optional POI list for distance filtering.
        bar_index : if set, only check this specific bar; else check the last 2 bars.
        """
        if df.empty or len(df) < 3:
            return []

        sweeps: List[SweepEvent] = []
        check_indices = [bar_index] if bar_index is not None else [len(df) - 2, len(df) - 1]

        for idx in check_indices:
            if idx < 1 or idx >= len(df):
                continue
            sweeps.extend(
                self._check_bar(df, idx, symbol, liquidity_levels, active_pois)
            )

        return sweeps

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _check_bar(
        self,
        df: pd.DataFrame,
        idx: int,
        symbol: str,
        levels: List[LiquidityLevel],
        pois: Optional[List[POI]],
    ) -> List[SweepEvent]:
        events: List[SweepEvent] = []
        row = df.iloc[idx]
        o, h, l, c = float(row["open"]), float(row["high"]), float(row["low"]), float(row["close"])
        body = candle_body(o, c)
        rng = candle_range(h, l)

        for lvl in levels:
            if not lvl.active:
                continue

            # --- Bearish sweep (buy-side liquidity above price) ---
            if lvl.side == LiquiditySide.BUY_SIDE:
                if h > lvl.price and c < lvl.price:
                    # Wick sweep above
                    pen = price_to_pips(symbol, h - lvl.price)
                    if self.cfg.min_penetration_pips <= pen <= self.cfg.max_penetration_pips:
                        rej = self._rejection_quality(h, l, o, c, is_bearish_sweep=True)
                        if self._near_poi(lvl.price, pois, symbol):
                            events.append(SweepEvent(
                                symbol=symbol,
                                sweep_type=SweepType.WICK,
                                direction="bearish",
                                liquidity_price=lvl.price,
                                penetration_pips=pen,
                                rejection_quality=rej,
                                bar_index=idx,
                                score=self._score(pen, rej),
                                level_id=lvl.id,
                            ))

                # Close-reclaim sweep
                if idx >= 2:
                    prev = df.iloc[idx - 1]
                    prev_c = float(prev["close"])
                    if prev_c > lvl.price and c < lvl.price:
                        pen = price_to_pips(symbol, prev_c - lvl.price)
                        if self.cfg.min_penetration_pips <= pen <= self.cfg.max_penetration_pips:
                            rej = 5.0  # moderate default for reclaim type
                            if self._near_poi(lvl.price, pois, symbol):
                                events.append(SweepEvent(
                                    symbol=symbol,
                                    sweep_type=SweepType.CLOSE_RECLAIM,
                                    direction="bearish",
                                    liquidity_price=lvl.price,
                                    penetration_pips=pen,
                                    rejection_quality=rej,
                                    bar_index=idx,
                                    score=self._score(pen, rej),
                                    level_id=lvl.id,
                                ))

            # --- Bullish sweep (sell-side liquidity below price) ---
            elif lvl.side == LiquiditySide.SELL_SIDE:
                if l < lvl.price and c > lvl.price:
                    pen = price_to_pips(symbol, lvl.price - l)
                    if self.cfg.min_penetration_pips <= pen <= self.cfg.max_penetration_pips:
                        rej = self._rejection_quality(h, l, o, c, is_bearish_sweep=False)
                        if self._near_poi(lvl.price, pois, symbol):
                            events.append(SweepEvent(
                                symbol=symbol,
                                sweep_type=SweepType.WICK,
                                direction="bullish",
                                liquidity_price=lvl.price,
                                penetration_pips=pen,
                                rejection_quality=rej,
                                bar_index=idx,
                                score=self._score(pen, rej),
                                level_id=lvl.id,
                            ))

                if idx >= 2:
                    prev = df.iloc[idx - 1]
                    prev_c = float(prev["close"])
                    if prev_c < lvl.price and c > lvl.price:
                        pen = price_to_pips(symbol, lvl.price - prev_c)
                        if self.cfg.min_penetration_pips <= pen <= self.cfg.max_penetration_pips:
                            rej = 5.0
                            if self._near_poi(lvl.price, pois, symbol):
                                events.append(SweepEvent(
                                    symbol=symbol,
                                    sweep_type=SweepType.CLOSE_RECLAIM,
                                    direction="bullish",
                                    liquidity_price=lvl.price,
                                    penetration_pips=pen,
                                    rejection_quality=rej,
                                    bar_index=idx,
                                    score=self._score(pen, rej),
                                    level_id=lvl.id,
                                ))

        return events

    def _rejection_quality(
        self, high: float, low: float, open_: float, close: float,
        is_bearish_sweep: bool,
    ) -> float:
        """Score how strong the rejection is (0-10)."""
        rng = candle_range(high, low)
        if rng == 0:
            return 0.0
        if is_bearish_sweep:
            wick = candle_upper_wick(open_, close, high)
        else:
            wick = candle_lower_wick(open_, close, low)
        ratio = wick / rng
        return round(min(ratio * 10.0, 10.0), 2)

    def _near_poi(
        self, price: float, pois: Optional[List[POI]], symbol: str,
    ) -> bool:
        """Return True if the level is within max_distance_from_poi of any active POI."""
        if pois is None:
            return True  # no filter
        max_dist = pips_to_price(symbol, self.cfg.max_distance_from_poi_pips)
        for poi in pois:
            if poi.active and abs(poi.mid_price() - price) <= max_dist + poi.zone_width():
                return True
        # If no POI is nearby, still allow if list was empty
        return len(pois) == 0

    @staticmethod
    def _score(penetration: float, rejection: float) -> float:
        """Combine penetration and rejection into a sweep score."""
        return round(rejection * 0.7 + min(penetration, 10.0) * 0.3, 2)
