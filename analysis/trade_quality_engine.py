"""
Trade Quality Engine – combines all confluences into a final setup score and grade.
"""

from __future__ import annotations

from typing import List, Optional

from config.settings import GradingSettings, TIMEFRAME_WEIGHTS
from models.signal import Signal, SignalDirection, SignalScoreBreakdown, SetupGrade
from models.poi import POI, POIDirection
from models.regime import MarketRegime, RegimeType, TrendBias
from analysis.sweep_engine import SweepEvent
from analysis.trap_engine import TrapEvent
from analysis.reversal_engine import ReversalEvent
from analysis.liquidity_forecast_engine import LiquidityForecast
from analysis.liquidity_timing_engine import TimingResult


class TradeQualityEngine:
    """Scores setups and assigns grades."""

    def __init__(self, settings: Optional[GradingSettings] = None) -> None:
        self.cfg = settings or GradingSettings()

    def score(
        self,
        poi: POI,
        regime: MarketRegime,
        timing: TimingResult,
        sweep: Optional[SweepEvent],
        trap: Optional[TrapEvent],
        reversal: Optional[ReversalEvent],
        forecast: Optional[LiquidityForecast] = None,
        cluster_member_count: int = 1,
    ) -> Signal:
        """
        Build a fully-scored Signal from all confluence inputs.

        Each component contributes to a 0-100 total score, which is then
        mapped to a letter grade.
        """
        bd = SignalScoreBreakdown()

        # 1. POI strength (max 15)
        bd.poi_strength = min(poi.score, 15.0)

        # 2. Cluster strength (max 10)
        if cluster_member_count > 1:
            bd.cluster_strength = min(cluster_member_count * 3.0, 10.0)

        # 3. Liquidity confluence (max 10)
        liq_confs = [c for c in poi.confluences if "liq" in c.lower() or "equal" in c.lower()]
        bd.liquidity_confluence = min(len(liq_confs) * 3.0, 10.0)

        # 4. Forecast alignment (max 10)
        if forecast and forecast.primary_target:
            if poi.direction == POIDirection.BEARISH and forecast.draw_direction == "down":
                # Supply POI, liquidity draw below = good for sells (toward TP)
                bd.liquidity_forecast_alignment = 8.0
            elif poi.direction == POIDirection.BULLISH and forecast.draw_direction == "up":
                # Demand POI, liquidity draw above = good for buys (toward TP)
                bd.liquidity_forecast_alignment = 8.0
            elif forecast.draw_direction == "neutral":
                bd.liquidity_forecast_alignment = 3.0

        # 5. Structure alignment (max 15)
        if regime.trend_bias == TrendBias.BULLISH and poi.direction == POIDirection.BULLISH:
            bd.structure_alignment = 15.0
        elif regime.trend_bias == TrendBias.BEARISH and poi.direction == POIDirection.BEARISH:
            bd.structure_alignment = 15.0
        elif regime.trend_bias == TrendBias.NEUTRAL:
            bd.structure_alignment = 7.0
        else:
            # Counter-trend
            bd.structure_alignment = 2.0

        # 6. Regime suitability (max 10)
        if regime.regime == RegimeType.TREND:
            bd.regime_suitability = 10.0
        elif regime.regime == RegimeType.RANGE:
            bd.regime_suitability = 7.0  # range → sweep/reversal setups are good
        elif regime.regime == RegimeType.HIGH_VOLATILITY:
            bd.regime_suitability = 4.0
        else:
            bd.regime_suitability = 0.0  # low liquidity

        # 7. Timing quality (max 10)
        bd.timing_quality = timing.timing_score

        # 8. Sweep quality (max 10)
        if sweep:
            bd.sweep_quality = min(sweep.score, 10.0)

        # 9. Trap quality (max 5)
        if trap:
            bd.trap_quality = min(trap.score * 0.5, 5.0)

        # 10. Reversal quality (max 10)
        if reversal:
            bd.reversal_quality = min(reversal.quality, 10.0)

        total = bd.total()
        grade = self._grade(total)

        # Build the signal
        direction = (
            SignalDirection.SELL
            if poi.direction == POIDirection.BEARISH
            else SignalDirection.BUY
        )

        signal = Signal(
            symbol=poi.symbol,
            direction=direction,
            score=round(total, 2),
            grade=grade,
            breakdown=bd,
            poi_id=poi.id,
            cluster_id=poi.cluster_id,
            sweep_detected=sweep is not None,
            trap_detected=trap is not None,
            reversal_type=reversal.reversal_type.value if reversal else "",
        )

        # Determine approval
        if grade == SetupGrade.D:
            signal.approved = False
            signal.rejection_reasons.append("Grade D – below minimum quality")
        elif not timing.allow_trade:
            signal.approved = False
            signal.rejection_reasons.append(timing.block_reason)
        elif not regime.is_tradeable():
            signal.approved = False
            signal.rejection_reasons.append("Low-liquidity regime – trading blocked")
        else:
            signal.approved = True

        # Confluences list
        signal.confluences = list(poi.confluences)
        if sweep:
            signal.confluences.append(f"sweep_{sweep.sweep_type.value}")
        if trap:
            signal.confluences.append(f"trap_{trap.trap_type.value}")
        if reversal:
            signal.confluences.append(f"reversal_{reversal.reversal_type.value}")

        return signal

    # ------------------------------------------------------------------
    # Grading
    # ------------------------------------------------------------------

    def _grade(self, total: float) -> SetupGrade:
        if total >= self.cfg.a_plus_threshold:
            return SetupGrade.A_PLUS
        elif total >= self.cfg.a_threshold:
            return SetupGrade.A
        elif total >= self.cfg.b_threshold:
            return SetupGrade.B
        elif total >= self.cfg.c_threshold:
            return SetupGrade.C
        else:
            return SetupGrade.D
