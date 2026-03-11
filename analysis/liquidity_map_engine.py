"""
Liquidity Map Engine – detects and maintains a live map of liquidity levels:
equal highs/lows, session levels, swing levels, range boundaries, etc.
"""

from __future__ import annotations

from typing import Dict, List, Optional

import numpy as np
import pandas as pd

from config.settings import LiquiditySettings
from config.symbols import price_to_pips
from core.utils import detect_swing_highs, detect_swing_lows, to_epoch
from models.liquidity import LiquidityLevel, LiquiditySide, LiquidityType


class LiquidityMapEngine:
    """Builds and maintains the full liquidity map for a symbol."""

    def __init__(self, settings: Optional[LiquiditySettings] = None) -> None:
        self.cfg = settings or LiquiditySettings()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def build_map(
        self,
        df: pd.DataFrame,
        symbol: str,
        timeframe: str = "M5",
        session_data: Optional[Dict] = None,
    ) -> List[LiquidityLevel]:
        """
        Build the full liquidity map from candle data.

        Parameters
        ----------
        df : OHLCV DataFrame.
        symbol : instrument name.
        timeframe : timeframe label.
        session_data : optional dict with keys like 'asian_high', 'london_low', etc.
        """
        levels: List[LiquidityLevel] = []

        if df.empty or len(df) < 20:
            return levels

        highs = df["high"].to_numpy(dtype=float)
        lows = df["low"].to_numpy(dtype=float)
        times = df["time"].to_numpy() if "time" in df.columns else np.zeros(len(df))

        # 1. Swing highs & lows
        levels.extend(self._detect_swing_levels(highs, lows, times, symbol, timeframe))

        # 2. Equal highs & lows
        levels.extend(self._detect_equal_levels(highs, lows, times, symbol, timeframe))

        # 3. Previous day high/low (if daily data available via session_data)
        if session_data:
            levels.extend(self._session_levels(session_data, symbol))

        # 4. Range high/low (recent N bars)
        levels.extend(self._range_levels(highs, lows, times, symbol, timeframe))

        return levels

    def update_swept_status(
        self,
        levels: List[LiquidityLevel],
        current_high: float,
        current_low: float,
        timestamp: float,
    ) -> List[LiquidityLevel]:
        """Mark levels as swept if price has traded through them."""
        for lvl in levels:
            if not lvl.active:
                continue
            if lvl.side == LiquiditySide.BUY_SIDE and current_high >= lvl.price:
                lvl.mark_swept(timestamp)
            elif lvl.side == LiquiditySide.SELL_SIDE and current_low <= lvl.price:
                lvl.mark_swept(timestamp)
        return levels

    # ------------------------------------------------------------------
    # Swing levels
    # ------------------------------------------------------------------

    def _detect_swing_levels(
        self,
        highs: np.ndarray,
        lows: np.ndarray,
        times: np.ndarray,
        symbol: str,
        timeframe: str,
    ) -> List[LiquidityLevel]:
        levels: List[LiquidityLevel] = []
        sh = detect_swing_highs(highs, self.cfg.swing_lookback)
        sl = detect_swing_lows(lows, self.cfg.swing_lookback)

        for idx in sh:
            ts = to_epoch(times[idx])
            levels.append(LiquidityLevel(
                symbol=symbol,
                price=float(highs[idx]),
                level_type=LiquidityType.SWING_HIGH,
                side=LiquiditySide.BUY_SIDE,
                strength=1.0,
                timeframe=timeframe,
                bar_index=idx,
                timestamp=ts,
            ))

        for idx in sl:
            ts = to_epoch(times[idx])
            levels.append(LiquidityLevel(
                symbol=symbol,
                price=float(lows[idx]),
                level_type=LiquidityType.SWING_LOW,
                side=LiquiditySide.SELL_SIDE,
                strength=1.0,
                timeframe=timeframe,
                bar_index=idx,
                timestamp=ts,
            ))

        return levels

    # ------------------------------------------------------------------
    # Equal highs / lows
    # ------------------------------------------------------------------

    def _detect_equal_levels(
        self,
        highs: np.ndarray,
        lows: np.ndarray,
        times: np.ndarray,
        symbol: str,
        timeframe: str,
    ) -> List[LiquidityLevel]:
        levels: List[LiquidityLevel] = []
        tol = self.cfg.equal_level_tolerance_pips

        # Equal highs
        sh_indices = detect_swing_highs(highs, self.cfg.swing_lookback)
        sh_prices = [float(highs[i]) for i in sh_indices]
        eq_highs = self._find_equal_prices(sh_prices, sh_indices, tol, symbol)
        for price, strength, idx in eq_highs:
            ts = to_epoch(times[idx])
            levels.append(LiquidityLevel(
                symbol=symbol,
                price=price,
                level_type=LiquidityType.EQUAL_HIGHS,
                side=LiquiditySide.BUY_SIDE,
                strength=strength,
                timeframe=timeframe,
                bar_index=idx,
                timestamp=ts,
            ))

        # Equal lows
        sl_indices = detect_swing_lows(lows, self.cfg.swing_lookback)
        sl_prices = [float(lows[i]) for i in sl_indices]
        eq_lows = self._find_equal_prices(sl_prices, sl_indices, tol, symbol)
        for price, strength, idx in eq_lows:
            ts = to_epoch(times[idx])
            levels.append(LiquidityLevel(
                symbol=symbol,
                price=price,
                level_type=LiquidityType.EQUAL_LOWS,
                side=LiquiditySide.SELL_SIDE,
                strength=strength,
                timeframe=timeframe,
                bar_index=idx,
                timestamp=ts,
            ))

        return levels

    def _find_equal_prices(
        self,
        prices: List[float],
        indices: List[int],
        tol_pips: float,
        symbol: str,
    ) -> List[tuple]:
        """Find groups of prices within *tol_pips* of each other."""
        from config.symbols import pips_to_price
        tol = pips_to_price(symbol, tol_pips)
        results: List[tuple] = []
        used = set()

        for i, p1 in enumerate(prices):
            if i in used:
                continue
            group = [i]
            for j in range(i + 1, len(prices)):
                if j in used:
                    continue
                if abs(p1 - prices[j]) <= tol:
                    group.append(j)
            if len(group) >= self.cfg.min_touches_for_equal:
                avg_price = sum(prices[g] for g in group) / len(group)
                strength = float(len(group))
                last_idx = indices[group[-1]]
                results.append((avg_price, strength, last_idx))
                used.update(group)

        return results

    # ------------------------------------------------------------------
    # Session levels
    # ------------------------------------------------------------------

    def _session_levels(self, session_data: Dict, symbol: str) -> List[LiquidityLevel]:
        levels: List[LiquidityLevel] = []
        mapping = {
            "prev_day_high": (LiquidityType.PREV_DAY_HIGH, LiquiditySide.BUY_SIDE),
            "prev_day_low": (LiquidityType.PREV_DAY_LOW, LiquiditySide.SELL_SIDE),
            "prev_week_high": (LiquidityType.PREV_WEEK_HIGH, LiquiditySide.BUY_SIDE),
            "prev_week_low": (LiquidityType.PREV_WEEK_LOW, LiquiditySide.SELL_SIDE),
            "asian_high": (LiquidityType.SESSION_HIGH, LiquiditySide.BUY_SIDE),
            "asian_low": (LiquidityType.SESSION_LOW, LiquiditySide.SELL_SIDE),
            "london_high": (LiquidityType.SESSION_HIGH, LiquiditySide.BUY_SIDE),
            "london_low": (LiquidityType.SESSION_LOW, LiquiditySide.SELL_SIDE),
            "ny_high": (LiquidityType.SESSION_HIGH, LiquiditySide.BUY_SIDE),
            "ny_low": (LiquidityType.SESSION_LOW, LiquiditySide.SELL_SIDE),
        }
        for key, (ltype, side) in mapping.items():
            price = session_data.get(key)
            if price is not None and price > 0:
                levels.append(LiquidityLevel(
                    symbol=symbol,
                    price=float(price),
                    level_type=ltype,
                    side=side,
                    strength=2.0,  # session levels are significant
                    timeframe="session",
                ))
        return levels

    # ------------------------------------------------------------------
    # Range levels
    # ------------------------------------------------------------------

    def _range_levels(
        self,
        highs: np.ndarray,
        lows: np.ndarray,
        times: np.ndarray,
        symbol: str,
        timeframe: str,
        lookback: int = 100,
    ) -> List[LiquidityLevel]:
        """Detect range high/low over the last *lookback* bars."""
        levels: List[LiquidityLevel] = []
        segment_h = highs[-lookback:] if len(highs) >= lookback else highs
        segment_l = lows[-lookback:] if len(lows) >= lookback else lows

        range_high = float(np.max(segment_h))
        range_low = float(np.min(segment_l))

        rh_idx = int(len(highs) - lookback + np.argmax(segment_h))
        rl_idx = int(len(lows) - lookback + np.argmin(segment_l))

        rh_ts = to_epoch(times[rh_idx]) if rh_idx < len(times) else 0.0
        rl_ts = to_epoch(times[rl_idx]) if rl_idx < len(times) else 0.0

        levels.append(LiquidityLevel(
            symbol=symbol,
            price=range_high,
            level_type=LiquidityType.RANGE_HIGH,
            side=LiquiditySide.BUY_SIDE,
            strength=1.5,
            timeframe=timeframe,
            bar_index=rh_idx,
            timestamp=rh_ts,
        ))
        levels.append(LiquidityLevel(
            symbol=symbol,
            price=range_low,
            level_type=LiquidityType.RANGE_LOW,
            side=LiquiditySide.SELL_SIDE,
            strength=1.5,
            timeframe=timeframe,
            bar_index=rl_idx,
            timestamp=rl_ts,
        ))
        return levels
