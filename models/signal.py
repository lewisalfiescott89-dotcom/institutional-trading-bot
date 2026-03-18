"""
Signal model – represents a fully-scored trade setup ready for execution decision.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Dict, List, Optional


class SignalDirection(str, Enum):
    BUY = "buy"
    SELL = "sell"


class SetupGrade(str, Enum):
    A_PLUS = "A+"
    A = "A"
    B = "B"
    C = "C"
    D = "D"


@dataclass
class SignalScoreBreakdown:
    """Individual components that make up the final score."""
    poi_strength: float = 0.0
    cluster_strength: float = 0.0
    liquidity_confluence: float = 0.0
    liquidity_forecast_alignment: float = 0.0
    structure_alignment: float = 0.0
    regime_suitability: float = 0.0
    timing_quality: float = 0.0
    sweep_quality: float = 0.0
    trap_quality: float = 0.0
    reversal_quality: float = 0.0

    def total(self) -> float:
        return (
            self.poi_strength
            + self.cluster_strength
            + self.liquidity_confluence
            + self.liquidity_forecast_alignment
            + self.structure_alignment
            + self.regime_suitability
            + self.timing_quality
            + self.sweep_quality
            + self.trap_quality
            + self.reversal_quality
        )


@dataclass
class Signal:
    """A scored trade signal."""

    symbol: str = ""
    direction: SignalDirection = SignalDirection.BUY
    entry_price: float = 0.0
    sl_price: float = 0.0
    tp_price: float = 0.0
    lot_size: float = 0.0

    score: float = 0.0
    grade: SetupGrade = SetupGrade.D
    breakdown: SignalScoreBreakdown = field(default_factory=SignalScoreBreakdown)

    poi_id: str = ""
    cluster_id: Optional[str] = None
    sweep_detected: bool = False
    trap_detected: bool = False
    reversal_type: str = ""
    confluences: List[str] = field(default_factory=list)

    timestamp: float = 0.0
    bar_index: int = 0
    risk_pct: float = 0.0

    # Execution decision
    approved: bool = False
    rejection_reasons: List[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "symbol": self.symbol,
            "direction": self.direction.value,
            "entry_price": self.entry_price,
            "sl_price": self.sl_price,
            "tp_price": self.tp_price,
            "lot_size": self.lot_size,
            "score": self.score,
            "grade": self.grade.value,
            "poi_id": self.poi_id,
            "cluster_id": self.cluster_id,
            "sweep_detected": self.sweep_detected,
            "trap_detected": self.trap_detected,
            "reversal_type": self.reversal_type,
            "confluences": self.confluences,
            "timestamp": self.timestamp,
            "bar_index": self.bar_index,
            "risk_pct": self.risk_pct,
            "approved": self.approved,
            "rejection_reasons": self.rejection_reasons,
        }
