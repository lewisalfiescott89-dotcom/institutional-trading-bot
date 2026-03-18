"""
Market Structure Engine – detects swing highs/lows, HH/HL/LH/LL,
break of structure (BOS), and change of character (CHoCH).
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import List, Optional, Tuple

import numpy as np
import pandas as pd

from config.settings import StructureSettings
from core.utils import detect_swing_highs, detect_swing_lows
from models.regime import TrendBias


class StructureEvent(str, Enum):
    HH = "higher_high"
    HL = "higher_low"
    LH = "lower_high"
    LL = "lower_low"
    BOS_BULLISH = "bos_bullish"      # break of structure to the upside
    BOS_BEARISH = "bos_bearish"      # break of structure to the downside
    CHOCH_BULLISH = "choch_bullish"  # change of character – bearish → bullish
    CHOCH_BEARISH = "choch_bearish"  # change of character – bullish → bearish


@dataclass
class SwingPoint:
    index: int
    price: float
    is_high: bool  # True = swing high, False = swing low


@dataclass
class StructureResult:
    """Output of the structure analysis for a single symbol/timeframe."""
    bias: TrendBias = TrendBias.NEUTRAL
    swing_highs: List[SwingPoint] = None  # type: ignore[assignment]
    swing_lows: List[SwingPoint] = None   # type: ignore[assignment]
    events: List[Tuple[int, StructureEvent]] = None  # type: ignore[assignment]
    last_hh: Optional[float] = None
    last_hl: Optional[float] = None
    last_lh: Optional[float] = None
    last_ll: Optional[float] = None

    def __post_init__(self) -> None:
        if self.swing_highs is None:
            self.swing_highs = []
        if self.swing_lows is None:
            self.swing_lows = []
        if self.events is None:
            self.events = []


class StructureEngine:
    """Analyses market structure on a given DataFrame of candles."""

    def __init__(self, settings: Optional[StructureSettings] = None) -> None:
        self.cfg = settings or StructureSettings()

    def analyse(self, df: pd.DataFrame) -> StructureResult:
        """
        Run full structure analysis on *df*.

        Parameters
        ----------
        df : DataFrame with columns [open, high, low, close] at minimum.

        Returns
        -------
        StructureResult with swing points, events, and directional bias.
        """
        if df.empty or len(df) < self.cfg.swing_lookback * 3:
            return StructureResult()

        highs = df["high"].to_numpy(dtype=float)
        lows = df["low"].to_numpy(dtype=float)

        sh_indices = detect_swing_highs(highs, self.cfg.swing_lookback)
        sl_indices = detect_swing_lows(lows, self.cfg.swing_lookback)

        swing_highs = [SwingPoint(i, highs[i], True) for i in sh_indices]
        swing_lows = [SwingPoint(i, lows[i], False) for i in sl_indices]

        events = self._classify_swings(swing_highs, swing_lows)
        bias = self._determine_bias(events)

        result = StructureResult(
            bias=bias,
            swing_highs=swing_highs,
            swing_lows=swing_lows,
            events=events,
        )

        # Store last significant levels
        for idx, evt in reversed(events):
            if evt == StructureEvent.HH and result.last_hh is None:
                result.last_hh = highs[idx] if idx < len(highs) else None
            elif evt == StructureEvent.HL and result.last_hl is None:
                result.last_hl = lows[idx] if idx < len(lows) else None
            elif evt == StructureEvent.LH and result.last_lh is None:
                result.last_lh = highs[idx] if idx < len(highs) else None
            elif evt == StructureEvent.LL and result.last_ll is None:
                result.last_ll = lows[idx] if idx < len(lows) else None

        return result

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _classify_swings(
        self,
        swing_highs: List[SwingPoint],
        swing_lows: List[SwingPoint],
    ) -> List[Tuple[int, StructureEvent]]:
        """Walk through swing points in chronological order and label HH/HL/LH/LL + BOS/CHoCH."""
        # Merge and sort by bar index
        all_swings = sorted(
            [(s.index, s.price, s.is_high) for s in swing_highs]
            + [(s.index, s.price, s.is_high) for s in swing_lows],
            key=lambda x: x[0],
        )

        events: List[Tuple[int, StructureEvent]] = []
        prev_sh: Optional[float] = None
        prev_sl: Optional[float] = None
        prev_bias: Optional[TrendBias] = None

        for idx, price, is_high in all_swings:
            if is_high:
                if prev_sh is not None:
                    if price > prev_sh:
                        events.append((idx, StructureEvent.HH))
                        # Check for CHoCH: was bearish, now making HH
                        if prev_bias == TrendBias.BEARISH:
                            events.append((idx, StructureEvent.CHOCH_BULLISH))
                        else:
                            events.append((idx, StructureEvent.BOS_BULLISH))
                    else:
                        events.append((idx, StructureEvent.LH))
                        if prev_bias == TrendBias.BULLISH:
                            events.append((idx, StructureEvent.CHOCH_BEARISH))
                prev_sh = price
            else:
                if prev_sl is not None:
                    if price > prev_sl:
                        events.append((idx, StructureEvent.HL))
                    else:
                        events.append((idx, StructureEvent.LL))
                        if prev_bias == TrendBias.BULLISH:
                            events.append((idx, StructureEvent.BOS_BEARISH))
                prev_sl = price

            # Update running bias
            prev_bias = self._running_bias(events)

        return events

    @staticmethod
    def _running_bias(events: List[Tuple[int, StructureEvent]]) -> TrendBias:
        """Derive bias from the last few events."""
        recent = [e for _, e in events[-6:]]
        hh = recent.count(StructureEvent.HH)
        hl = recent.count(StructureEvent.HL)
        lh = recent.count(StructureEvent.LH)
        ll = recent.count(StructureEvent.LL)
        if hh + hl > lh + ll:
            return TrendBias.BULLISH
        elif lh + ll > hh + hl:
            return TrendBias.BEARISH
        return TrendBias.NEUTRAL

    @staticmethod
    def _determine_bias(events: List[Tuple[int, StructureEvent]]) -> TrendBias:
        """Overall bias from all events, weighted toward recent ones."""
        if not events:
            return TrendBias.NEUTRAL
        # Weight recent events more
        score = 0.0
        n = len(events)
        for i, (_, evt) in enumerate(events):
            weight = (i + 1) / n  # linearly increasing weight
            if evt in (StructureEvent.HH, StructureEvent.HL, StructureEvent.BOS_BULLISH, StructureEvent.CHOCH_BULLISH):
                score += weight
            elif evt in (StructureEvent.LH, StructureEvent.LL, StructureEvent.BOS_BEARISH, StructureEvent.CHOCH_BEARISH):
                score -= weight
        if score > 0.5:
            return TrendBias.BULLISH
        elif score < -0.5:
            return TrendBias.BEARISH
        return TrendBias.NEUTRAL
