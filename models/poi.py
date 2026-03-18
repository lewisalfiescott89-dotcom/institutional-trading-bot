"""
Point of Interest (POI) model – order blocks, FVG-backed zones, liquidity zones.

Every POI carries full lifecycle state: fresh → tested → broken.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import List, Optional


class POIDirection(str, Enum):
    BULLISH = "bullish"   # demand zone – expect price to bounce up
    BEARISH = "bearish"   # supply zone – expect price to reject down


class POIType(str, Enum):
    ORDER_BLOCK = "order_block"
    FVG_BACKED = "fvg_backed"
    LIQUIDITY_REVERSAL = "liquidity_reversal"
    CLUSTER = "cluster"


class POIFreshness(str, Enum):
    FRESH = "fresh"
    ONCE_TESTED = "once_tested"
    MULTIPLE_TESTED = "multiple_tested"
    BROKEN = "broken"


@dataclass
class POI:
    """Single Point of Interest zone."""

    # Identity
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])
    symbol: str = ""
    timeframe: str = ""

    # Zone boundaries (price)
    zone_low: float = 0.0
    zone_high: float = 0.0

    # Classification
    direction: POIDirection = POIDirection.BULLISH
    poi_type: POIType = POIType.ORDER_BLOCK
    freshness: POIFreshness = POIFreshness.FRESH

    # Scoring
    score: float = 0.0
    confluences: List[str] = field(default_factory=list)

    # Lifecycle
    active: bool = True
    invalidated: bool = False
    touches: int = 0
    cluster_id: Optional[str] = None

    # Metadata
    origin_bar_index: int = 0          # bar index where the POI was detected
    origin_timestamp: float = 0.0      # epoch seconds

    # Wick-probe / invalidation pending state (Pepperstone rule)
    wick_probe_pending: bool = False    # a wick breached the zone
    wick_probe_bar_index: int = -1     # which bar did the probe

    def mid_price(self) -> float:
        return (self.zone_low + self.zone_high) / 2.0

    def zone_width(self) -> float:
        return self.zone_high - self.zone_low

    def record_touch(self) -> None:
        """Register a test of the zone and update freshness."""
        self.touches += 1
        if self.touches == 1:
            self.freshness = POIFreshness.ONCE_TESTED
        elif self.touches >= 2:
            self.freshness = POIFreshness.MULTIPLE_TESTED

    def invalidate(self) -> None:
        """Mark the zone as broken / invalid."""
        self.active = False
        self.invalidated = True
        self.freshness = POIFreshness.BROKEN

    def contains_price(self, price: float) -> bool:
        """Check whether *price* falls inside the zone."""
        return self.zone_low <= price <= self.zone_high

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "symbol": self.symbol,
            "timeframe": self.timeframe,
            "direction": self.direction.value,
            "poi_type": self.poi_type.value,
            "freshness": self.freshness.value,
            "zone_low": self.zone_low,
            "zone_high": self.zone_high,
            "score": self.score,
            "active": self.active,
            "invalidated": self.invalidated,
            "touches": self.touches,
            "cluster_id": self.cluster_id,
            "confluences": self.confluences,
            "origin_bar_index": self.origin_bar_index,
            "origin_timestamp": self.origin_timestamp,
            "wick_probe_pending": self.wick_probe_pending,
            "wick_probe_bar_index": self.wick_probe_bar_index,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "POI":
        poi = cls()
        poi.id = d.get("id", poi.id)
        poi.symbol = d.get("symbol", "")
        poi.timeframe = d.get("timeframe", "")
        poi.direction = POIDirection(d.get("direction", "bullish"))
        poi.poi_type = POIType(d.get("poi_type", "order_block"))
        poi.freshness = POIFreshness(d.get("freshness", "fresh"))
        poi.zone_low = d.get("zone_low", 0.0)
        poi.zone_high = d.get("zone_high", 0.0)
        poi.score = d.get("score", 0.0)
        poi.active = d.get("active", True)
        poi.invalidated = d.get("invalidated", False)
        poi.touches = d.get("touches", 0)
        poi.cluster_id = d.get("cluster_id")
        poi.confluences = d.get("confluences", [])
        poi.origin_bar_index = d.get("origin_bar_index", 0)
        poi.origin_timestamp = d.get("origin_timestamp", 0.0)
        poi.wick_probe_pending = d.get("wick_probe_pending", False)
        poi.wick_probe_bar_index = d.get("wick_probe_bar_index", -1)
        return poi
