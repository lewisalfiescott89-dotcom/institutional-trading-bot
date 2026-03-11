"""
Market regime model – trend, range, high-vol, low-liquidity.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class RegimeType(str, Enum):
    TREND = "trend"
    RANGE = "range"
    HIGH_VOLATILITY = "high_volatility"
    LOW_LIQUIDITY = "low_liquidity"


class TrendBias(str, Enum):
    BULLISH = "bullish"
    BEARISH = "bearish"
    NEUTRAL = "neutral"


@dataclass
class MarketRegime:
    """Snapshot of the current market regime for a symbol."""

    symbol: str = ""
    regime: RegimeType = RegimeType.RANGE
    trend_bias: TrendBias = TrendBias.NEUTRAL
    atr_value: float = 0.0
    atr_ma: float = 0.0          # moving average of ATR for comparison
    volatility_ratio: float = 1.0  # atr / atr_ma
    volume_ratio: float = 1.0     # current vol / avg vol
    confidence: float = 0.0       # 0-1 how confident the classification is

    def is_tradeable(self) -> bool:
        """Low-liquidity regime blocks all trading."""
        return self.regime != RegimeType.LOW_LIQUIDITY

    def risk_multiplier(self) -> float:
        """Scale risk down in high-vol conditions."""
        if self.regime == RegimeType.HIGH_VOLATILITY:
            return 0.5
        return 1.0

    def to_dict(self) -> dict:
        return {
            "symbol": self.symbol,
            "regime": self.regime.value,
            "trend_bias": self.trend_bias.value,
            "atr_value": self.atr_value,
            "atr_ma": self.atr_ma,
            "volatility_ratio": self.volatility_ratio,
            "volume_ratio": self.volume_ratio,
            "confidence": self.confidence,
        }
