"""
Market Regime Engine – classifies the current market condition as
trend / range / high-volatility / low-liquidity.
"""

from __future__ import annotations

from typing import Optional

import numpy as np
import pandas as pd

from config.settings import RegimeSettings
from core.utils import compute_atr
from models.regime import MarketRegime, RegimeType, TrendBias
from analysis.structure_engine import StructureEngine, StructureResult


class RegimeEngine:
    """Classifies the current market regime for a symbol."""

    def __init__(self, settings: Optional[RegimeSettings] = None) -> None:
        self.cfg = settings or RegimeSettings()
        self._structure_engine = StructureEngine()

    def classify(
        self,
        df: pd.DataFrame,
        symbol: str = "",
        structure: Optional[StructureResult] = None,
    ) -> MarketRegime:
        """
        Classify regime from a candle DataFrame (typically D1 or H4).

        Parameters
        ----------
        df : OHLCV DataFrame.
        symbol : instrument name for labelling.
        structure : pre-computed StructureResult (optional – will compute if None).
        """
        regime = MarketRegime(symbol=symbol)

        if df.empty or len(df) < self.cfg.atr_period * 2:
            return regime

        highs = df["high"].to_numpy(dtype=float)
        lows = df["low"].to_numpy(dtype=float)
        closes = df["close"].to_numpy(dtype=float)

        # -- ATR & volatility ratio --
        atr = compute_atr(highs, lows, closes, self.cfg.atr_period)
        valid_atr = atr[~np.isnan(atr)]
        if len(valid_atr) < 2:
            return regime

        current_atr = valid_atr[-1]
        atr_ma = float(np.mean(valid_atr[-self.cfg.atr_period * 2:]))
        vol_ratio = current_atr / atr_ma if atr_ma > 0 else 1.0

        regime.atr_value = float(current_atr)
        regime.atr_ma = atr_ma
        regime.volatility_ratio = vol_ratio

        # -- Volume ratio (if available) --
        if "volume" in df.columns:
            vols = df["volume"].to_numpy(dtype=float)
            avg_vol = float(np.mean(vols[-50:])) if len(vols) >= 50 else float(np.mean(vols))
            cur_vol = float(vols[-1]) if len(vols) > 0 else 0.0
            regime.volume_ratio = cur_vol / avg_vol if avg_vol > 0 else 1.0

        # -- Structure bias --
        if structure is None:
            structure = self._structure_engine.analyse(df)
        regime.trend_bias = structure.bias

        # -- Regime classification --
        if regime.volume_ratio < self.cfg.low_liquidity_volume_pct:
            regime.regime = RegimeType.LOW_LIQUIDITY
            regime.confidence = 0.8
        elif vol_ratio >= self.cfg.trend_atr_threshold:
            # High ATR relative to average
            if structure.bias == TrendBias.NEUTRAL:
                regime.regime = RegimeType.HIGH_VOLATILITY
                regime.confidence = min(1.0, vol_ratio / 2.0)
            else:
                regime.regime = RegimeType.TREND
                regime.confidence = min(1.0, vol_ratio / 2.0)
        elif vol_ratio <= self.cfg.range_atr_threshold:
            regime.regime = RegimeType.RANGE
            regime.confidence = 1.0 - vol_ratio
        else:
            # Moderate volatility – lean on structure
            if structure.bias != TrendBias.NEUTRAL:
                regime.regime = RegimeType.TREND
                regime.confidence = 0.5
            else:
                regime.regime = RegimeType.RANGE
                regime.confidence = 0.5

        return regime
