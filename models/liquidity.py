"""
Liquidity level model – equal highs/lows, session levels, swing levels, etc.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class LiquiditySide(str, Enum):
    BUY_SIDE = "buy_side"     # liquidity sitting above price (stop-losses of shorts)
    SELL_SIDE = "sell_side"   # liquidity sitting below price (stop-losses of longs)


class LiquidityType(str, Enum):
    EQUAL_HIGHS = "equal_highs"
    EQUAL_LOWS = "equal_lows"
    PREV_DAY_HIGH = "prev_day_high"
    PREV_DAY_LOW = "prev_day_low"
    PREV_WEEK_HIGH = "prev_week_high"
    PREV_WEEK_LOW = "prev_week_low"
    SESSION_HIGH = "session_high"
    SESSION_LOW = "session_low"
    SWING_HIGH = "swing_high"
    SWING_LOW = "swing_low"
    RANGE_HIGH = "range_high"
    RANGE_LOW = "range_low"


@dataclass
class LiquidityLevel:
    """A single identified liquidity level on the chart."""

    id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])
    symbol: str = ""
    price: float = 0.0
    level_type: LiquidityType = LiquidityType.SWING_HIGH
    side: LiquiditySide = LiquiditySide.BUY_SIDE
    strength: float = 1.0          # higher = more significant
    timeframe: str = "M5"
    active: bool = True
    swept: bool = False
    swept_timestamp: Optional[float] = None
    bar_index: int = 0
    timestamp: float = 0.0

    def mark_swept(self, ts: float) -> None:
        """Flag this level as swept."""
        self.swept = True
        self.active = False
        self.swept_timestamp = ts

    def distance_from(self, current_price: float) -> float:
        return abs(self.price - current_price)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "symbol": self.symbol,
            "price": self.price,
            "level_type": self.level_type.value,
            "side": self.side.value,
            "strength": self.strength,
            "timeframe": self.timeframe,
            "active": self.active,
            "swept": self.swept,
            "swept_timestamp": self.swept_timestamp,
            "bar_index": self.bar_index,
            "timestamp": self.timestamp,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "LiquidityLevel":
        lvl = cls()
        lvl.id = d.get("id", lvl.id)
        lvl.symbol = d.get("symbol", "")
        lvl.price = d.get("price", 0.0)
        lvl.level_type = LiquidityType(d.get("level_type", "swing_high"))
        lvl.side = LiquiditySide(d.get("side", "buy_side"))
        lvl.strength = d.get("strength", 1.0)
        lvl.timeframe = d.get("timeframe", "M5")
        lvl.active = d.get("active", True)
        lvl.swept = d.get("swept", False)
        lvl.swept_timestamp = d.get("swept_timestamp")
        lvl.bar_index = d.get("bar_index", 0)
        lvl.timestamp = d.get("timestamp", 0.0)
        return lvl
