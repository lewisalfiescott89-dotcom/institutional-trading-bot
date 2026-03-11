"""
Trade model – represents a live or historical trade with full accounting.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class TradeStatus(str, Enum):
    PENDING = "pending"
    OPEN = "open"
    CLOSED_WIN = "closed_win"
    CLOSED_LOSS = "closed_loss"
    CLOSED_BE = "closed_be"       # break-even
    CANCELLED = "cancelled"


class TradeDirection(str, Enum):
    BUY = "buy"
    SELL = "sell"


@dataclass
class Trade:
    """Full representation of a trade lifecycle."""

    # Identity
    id: str = ""
    mt5_ticket: int = 0
    symbol: str = ""
    direction: TradeDirection = TradeDirection.BUY

    # Prices
    entry_price: float = 0.0
    sl_price: float = 0.0
    tp_price: float = 0.0
    close_price: float = 0.0

    # Sizing
    lot_size: float = 0.0
    risk_pct: float = 0.0

    # Status
    status: TradeStatus = TradeStatus.PENDING

    # PnL
    gross_pnl: float = 0.0
    commission: float = 0.0
    net_pnl: float = 0.0
    r_multiple: float = 0.0     # net PnL expressed in R

    # Metadata
    grade: str = ""
    score: float = 0.0
    poi_id: str = ""
    signal_confluences: list = field(default_factory=list)

    # Timestamps (epoch seconds)
    open_timestamp: float = 0.0
    close_timestamp: float = 0.0

    # Re-entry tracking
    is_reentry: bool = False
    parent_poi_id: str = ""

    def risk_distance(self) -> float:
        """Absolute distance between entry and SL."""
        return abs(self.entry_price - self.sl_price)

    def reward_distance(self) -> float:
        """Absolute distance between entry and TP."""
        return abs(self.tp_price - self.entry_price)

    def rr_ratio(self) -> float:
        rd = self.risk_distance()
        if rd == 0:
            return 0.0
        return self.reward_distance() / rd

    def is_open(self) -> bool:
        return self.status == TradeStatus.OPEN

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "mt5_ticket": self.mt5_ticket,
            "symbol": self.symbol,
            "direction": self.direction.value,
            "entry_price": self.entry_price,
            "sl_price": self.sl_price,
            "tp_price": self.tp_price,
            "close_price": self.close_price,
            "lot_size": self.lot_size,
            "risk_pct": self.risk_pct,
            "status": self.status.value,
            "gross_pnl": self.gross_pnl,
            "commission": self.commission,
            "net_pnl": self.net_pnl,
            "r_multiple": self.r_multiple,
            "grade": self.grade,
            "score": self.score,
            "poi_id": self.poi_id,
            "signal_confluences": self.signal_confluences,
            "open_timestamp": self.open_timestamp,
            "close_timestamp": self.close_timestamp,
            "is_reentry": self.is_reentry,
            "parent_poi_id": self.parent_poi_id,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "Trade":
        t = cls()
        for k, v in d.items():
            if k == "direction":
                t.direction = TradeDirection(v)
            elif k == "status":
                t.status = TradeStatus(v)
            elif hasattr(t, k):
                setattr(t, k, v)
        return t
