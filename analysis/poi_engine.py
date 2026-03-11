"""
POI Detection Engine – identifies Order Blocks, FVG-backed zones,
and liquidity-reversal zones across any timeframe.
"""

from __future__ import annotations

from typing import List, Optional

import numpy as np
import pandas as pd

from config.settings import POISettings, TIMEFRAME_WEIGHTS
from core.utils import compute_atr, candle_body, candle_range, is_bullish, is_bearish, body_ratio, to_epoch
from core.logger import get_logger
from models.poi import POI, POIDirection, POIType, POIFreshness

logger = get_logger("poi_engine")


class POIEngine:
    """Detects institutional Points of Interest on a candle DataFrame."""

    def __init__(self, settings: Optional[POISettings] = None) -> None:
        self.cfg = settings or POISettings()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def detect_order_blocks(
        self,
        df: pd.DataFrame,
        symbol: str,
        timeframe: str,
    ) -> List[POI]:
        """
        Detect order-block POIs (supply & demand zones).

        Bearish OB: last bullish candle before strong bearish displacement.
        Bullish OB: last bearish candle before strong bullish displacement.
        """
        if df.empty or len(df) < self.cfg.atr_period + 5:
            return []

        opens = df["open"].to_numpy(dtype=float)
        highs = df["high"].to_numpy(dtype=float)
        lows = df["low"].to_numpy(dtype=float)
        closes = df["close"].to_numpy(dtype=float)
        times = df["time"].to_numpy() if "time" in df.columns else np.zeros(len(df))

        atr = compute_atr(highs, lows, closes, self.cfg.atr_period)

        pois: List[POI] = []

        for i in range(self.cfg.atr_period + 1, len(df) - 1):
            if np.isnan(atr[i]):
                continue
            current_atr = atr[i]
            if current_atr <= 0:
                continue

            disp_body = candle_body(opens[i], closes[i])
            disp_range = candle_range(highs[i], lows[i])

            # Check displacement strength
            if disp_body < current_atr * self.cfg.displacement_multiplier:
                continue
            if disp_range == 0:
                continue
            if body_ratio(opens[i], closes[i], highs[i], lows[i]) < self.cfg.min_body_ratio:
                continue

            # Bearish displacement → find last bullish candle = supply zone
            if is_bearish(opens[i], closes[i]):
                # Look back for the last bullish candle
                for j in range(i - 1, max(i - 10, 0), -1):
                    if is_bullish(opens[j], closes[j]):
                        poi = POI(
                            symbol=symbol,
                            timeframe=timeframe,
                            direction=POIDirection.BEARISH,
                            poi_type=POIType.ORDER_BLOCK,
                            zone_low=lows[j],
                            zone_high=highs[j],
                            origin_bar_index=j,
                            origin_timestamp=to_epoch(times[j]),
                        )
                        poi.score = self._base_score(timeframe, current_atr, disp_body)
                        poi.confluences.append(f"OB_supply_{timeframe}")
                        pois.append(poi)
                        break

            # Bullish displacement → find last bearish candle = demand zone
            elif is_bullish(opens[i], closes[i]):
                for j in range(i - 1, max(i - 10, 0), -1):
                    if is_bearish(opens[j], closes[j]):
                        poi = POI(
                            symbol=symbol,
                            timeframe=timeframe,
                            direction=POIDirection.BULLISH,
                            poi_type=POIType.ORDER_BLOCK,
                            zone_low=lows[j],
                            zone_high=highs[j],
                            origin_bar_index=j,
                            origin_timestamp=to_epoch(times[j]),
                        )
                        poi.score = self._base_score(timeframe, current_atr, disp_body)
                        poi.confluences.append(f"OB_demand_{timeframe}")
                        pois.append(poi)
                        break

        return pois

    def detect_all(
        self,
        df: pd.DataFrame,
        symbol: str,
        timeframe: str,
    ) -> List[POI]:
        """Run all POI detection methods and merge results."""
        pois = self.detect_order_blocks(df, symbol, timeframe)
        # Additional POI types are detected by the FVG and liquidity engines
        # and merged in the orchestrator.
        return pois

    # ------------------------------------------------------------------
    # Projection: map higher-TF POIs onto 5M chart
    # ------------------------------------------------------------------

    @staticmethod
    def project_pois_to_execution(
        pois: List[POI],
        execution_tf: str = "M5",
    ) -> List[POI]:
        """
        All higher-TF POIs are already expressed in absolute price.
        This method tags them as projected and ensures they reference
        the execution timeframe for the final decision layer.

        In practice, price zones are universal – a Weekly supply at
        2940-2950 is the same zone on the 5M chart.  We just mark them.
        """
        projected: List[POI] = []
        for p in pois:
            if not p.active:
                continue
            # Tag the POI as projected if it's from a higher TF
            if p.timeframe != execution_tf:
                p.confluences.append(f"projected_from_{p.timeframe}")
            projected.append(p)
        return projected

    # ------------------------------------------------------------------
    # Freshness & invalidation
    # ------------------------------------------------------------------

    def update_freshness(self, poi: POI) -> None:
        """Decay POI score based on touch count."""
        if poi.touches > 0:
            decay = self.cfg.freshness_decay_per_touch * poi.touches
            poi.score = max(0.0, poi.score * (1.0 - decay))

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _base_score(self, timeframe: str, atr: float, displacement: float) -> float:
        """Compute a raw score for a freshly detected POI."""
        tf_weight = TIMEFRAME_WEIGHTS.get(timeframe, 1.0)
        disp_strength = displacement / atr if atr > 0 else 1.0
        return round(tf_weight * disp_strength * 5.0, 2)  # scale to ~0-100 range
