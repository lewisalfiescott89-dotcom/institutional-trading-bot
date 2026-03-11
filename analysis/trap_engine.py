"""
Liquidity Trap Engine – detects bull traps and bear traps.

A bull trap: price breaks above highs/resistance, fails, reverses down.
A bear trap: price breaks below lows/support, fails, reverses up.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import List, Optional

import pandas as pd

from config.settings import TrapSettings
from config.symbols import price_to_pips
from core.utils import candle_body, is_bullish, is_bearish
from models.liquidity import LiquidityLevel, LiquiditySide


class TrapType(str, Enum):
    BULL_TRAP = "bull_trap"
    BEAR_TRAP = "bear_trap"


@dataclass
class TrapEvent:
    """A detected liquidity trap."""
    symbol: str = ""
    trap_type: TrapType = TrapType.BULL_TRAP
    level_price: float = 0.0
    break_pips: float = 0.0
    reversal_strength: float = 0.0   # 0-10
    bar_index: int = 0
    score: float = 0.0
    level_id: str = ""

    def to_dict(self) -> dict:
        return {
            "symbol": self.symbol,
            "trap_type": self.trap_type.value,
            "level_price": self.level_price,
            "break_pips": self.break_pips,
            "reversal_strength": self.reversal_strength,
            "bar_index": self.bar_index,
            "score": self.score,
            "level_id": self.level_id,
        }


class TrapEngine:
    """Detects bull and bear traps relative to liquidity levels."""

    def __init__(self, settings: Optional[TrapSettings] = None) -> None:
        self.cfg = settings or TrapSettings()

    def detect(
        self,
        df: pd.DataFrame,
        symbol: str,
        liquidity_levels: List[LiquidityLevel],
    ) -> List[TrapEvent]:
        """
        Check the last few candles for trap patterns.

        A trap requires:
        1. Break beyond a liquidity level.
        2. Failure to sustain (close back within max_reclaim_bars).
        3. Reversal body strength meets threshold.
        """
        if df.empty or len(df) < self.cfg.max_reclaim_bars + 2:
            return []

        traps: List[TrapEvent] = []
        n = len(df)

        for lvl in liquidity_levels:
            if not lvl.active:
                continue

            # Check each bar in the tail window
            for i in range(max(0, n - self.cfg.max_reclaim_bars - 1), n - 1):
                row = df.iloc[i]
                o_i = float(row["open"])
                h_i = float(row["high"])
                l_i = float(row["low"])
                c_i = float(row["close"])

                # Bull trap: break above buy-side liquidity then fail
                if lvl.side == LiquiditySide.BUY_SIDE:
                    if h_i > lvl.price or c_i > lvl.price:
                        break_dist = price_to_pips(symbol, max(h_i, c_i) - lvl.price)
                        if break_dist < self.cfg.min_break_pips:
                            continue
                        # Look for reclaim in subsequent bars
                        for j in range(i + 1, min(i + self.cfg.max_reclaim_bars + 1, n)):
                            row_j = df.iloc[j]
                            c_j = float(row_j["close"])
                            o_j = float(row_j["open"])
                            if c_j < lvl.price and is_bearish(o_j, c_j):
                                body = candle_body(o_j, c_j)
                                rng = float(row_j["high"]) - float(row_j["low"])
                                ratio = body / rng if rng > 0 else 0.0
                                if ratio >= self.cfg.min_reversal_body_ratio:
                                    strength = min(ratio * 10.0, 10.0)
                                    traps.append(TrapEvent(
                                        symbol=symbol,
                                        trap_type=TrapType.BULL_TRAP,
                                        level_price=lvl.price,
                                        break_pips=break_dist,
                                        reversal_strength=round(strength, 2),
                                        bar_index=j,
                                        score=round(strength * 0.7 + min(break_dist, 10.0) * 0.3, 2),
                                        level_id=lvl.id,
                                    ))
                                break

                # Bear trap: break below sell-side liquidity then fail
                elif lvl.side == LiquiditySide.SELL_SIDE:
                    if l_i < lvl.price or c_i < lvl.price:
                        break_dist = price_to_pips(symbol, lvl.price - min(l_i, c_i))
                        if break_dist < self.cfg.min_break_pips:
                            continue
                        for j in range(i + 1, min(i + self.cfg.max_reclaim_bars + 1, n)):
                            row_j = df.iloc[j]
                            c_j = float(row_j["close"])
                            o_j = float(row_j["open"])
                            if c_j > lvl.price and is_bullish(o_j, c_j):
                                body = candle_body(o_j, c_j)
                                rng = float(row_j["high"]) - float(row_j["low"])
                                ratio = body / rng if rng > 0 else 0.0
                                if ratio >= self.cfg.min_reversal_body_ratio:
                                    strength = min(ratio * 10.0, 10.0)
                                    traps.append(TrapEvent(
                                        symbol=symbol,
                                        trap_type=TrapType.BEAR_TRAP,
                                        level_price=lvl.price,
                                        break_pips=break_dist,
                                        reversal_strength=round(strength, 2),
                                        bar_index=j,
                                        score=round(strength * 0.7 + min(break_dist, 10.0) * 0.3, 2),
                                        level_id=lvl.id,
                                    ))
                                break

        return traps
