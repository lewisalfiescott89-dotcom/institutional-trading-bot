"""
Liquidity Forecast Engine – predicts where price is most likely to target next
by ranking nearby liquidity pools above and below the current price.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional

from config.symbols import price_to_pips
from models.liquidity import LiquidityLevel, LiquiditySide
from models.poi import POI, POIDirection


@dataclass
class LiquidityTarget:
    """A ranked liquidity target with score and metadata."""
    level: LiquidityLevel
    distance_pips: float = 0.0
    score: float = 0.0
    is_primary: bool = False


@dataclass
class LiquidityForecast:
    """The forecast output: where is price likely drawn to?"""
    symbol: str = ""
    current_price: float = 0.0
    primary_target: Optional[LiquidityTarget] = None
    secondary_target: Optional[LiquidityTarget] = None
    targets_above: List[LiquidityTarget] = None  # type: ignore[assignment]
    targets_below: List[LiquidityTarget] = None   # type: ignore[assignment]
    draw_direction: str = ""   # "up", "down", "neutral"

    def __post_init__(self) -> None:
        if self.targets_above is None:
            self.targets_above = []
        if self.targets_below is None:
            self.targets_below = []


class LiquidityForecastEngine:
    """Forecasts the next likely liquidity draw."""

    def forecast(
        self,
        symbol: str,
        current_price: float,
        liquidity_levels: List[LiquidityLevel],
        active_pois: Optional[List[POI]] = None,
    ) -> LiquidityForecast:
        """
        Rank liquidity targets above and below *current_price*.

        Parameters
        ----------
        symbol : instrument name (for pip conversion).
        current_price : latest bid/ask mid.
        liquidity_levels : all active liquidity levels for the symbol.
        active_pois : current active POIs (used to boost targets near POIs).
        """
        fc = LiquidityForecast(symbol=symbol, current_price=current_price)

        if not liquidity_levels:
            return fc

        above: List[LiquidityTarget] = []
        below: List[LiquidityTarget] = []

        for lvl in liquidity_levels:
            if not lvl.active:
                continue
            dist = price_to_pips(symbol, abs(lvl.price - current_price))
            score = self._score_target(lvl, dist, active_pois)
            target = LiquidityTarget(level=lvl, distance_pips=dist, score=score)

            if lvl.price > current_price:
                above.append(target)
            else:
                below.append(target)

        # Sort by score descending
        above.sort(key=lambda t: t.score, reverse=True)
        below.sort(key=lambda t: t.score, reverse=True)

        fc.targets_above = above
        fc.targets_below = below

        # Determine draw direction
        top_above = above[0].score if above else 0.0
        top_below = below[0].score if below else 0.0

        if top_above > top_below * 1.2:
            fc.draw_direction = "up"
        elif top_below > top_above * 1.2:
            fc.draw_direction = "down"
        else:
            fc.draw_direction = "neutral"

        # Assign primary / secondary
        all_targets = sorted(above + below, key=lambda t: t.score, reverse=True)
        if all_targets:
            all_targets[0].is_primary = True
            fc.primary_target = all_targets[0]
        if len(all_targets) > 1:
            fc.secondary_target = all_targets[1]

        return fc

    # ------------------------------------------------------------------
    # Internal scoring
    # ------------------------------------------------------------------

    def _score_target(
        self,
        lvl: LiquidityLevel,
        distance_pips: float,
        pois: Optional[List[POI]],
    ) -> float:
        """
        Score a liquidity target based on:
        - type significance
        - distance (closer = higher short-term probability)
        - strength (equal highs with 3 touches > single swing)
        - proximity to an active POI
        """
        # Base score from type significance
        type_scores = {
            "equal_highs": 8.0,
            "equal_lows": 8.0,
            "prev_day_high": 7.0,
            "prev_day_low": 7.0,
            "prev_week_high": 9.0,
            "prev_week_low": 9.0,
            "session_high": 5.0,
            "session_low": 5.0,
            "swing_high": 4.0,
            "swing_low": 4.0,
            "range_high": 6.0,
            "range_low": 6.0,
        }
        base = type_scores.get(lvl.level_type.value, 3.0)

        # Distance penalty (closer targets score higher)
        dist_factor = max(0.1, 1.0 - (distance_pips / 200.0))

        # Strength bonus
        strength_bonus = lvl.strength * 1.5

        # POI proximity bonus
        poi_bonus = 0.0
        if pois:
            for poi in pois:
                if poi.active and poi.contains_price(lvl.price):
                    poi_bonus += 5.0
                    break
                elif poi.active and abs(poi.mid_price() - lvl.price) < poi.zone_width() * 2:
                    poi_bonus += 2.0
                    break

        return round((base + strength_bonus + poi_bonus) * dist_factor, 2)
