"""
Liquidity Timing Engine – determines WHEN sweeps are most likely,
degrades stale setups, and enforces kill-zone trading rules.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from config.settings import TimingSettings, SessionSettings
from models.signal import SetupGrade


@dataclass
class TimingResult:
    """Output of timing analysis for the current moment."""
    in_kill_zone: bool = False
    kill_zone_name: str = ""       # e.g. "london_kz", "ny_kz", "overlap"
    timing_score: float = 0.0      # 0-10
    is_stale: bool = False
    stale_bars: int = 0
    allow_trade: bool = True
    block_reason: str = ""


class LiquidityTimingEngine:
    """Evaluates whether the current time window favours execution."""

    def __init__(
        self,
        timing_cfg: Optional[TimingSettings] = None,
        session_cfg: Optional[SessionSettings] = None,
    ) -> None:
        self.t_cfg = timing_cfg or TimingSettings()
        self.s_cfg = session_cfg or SessionSettings()

    def evaluate(
        self,
        utc_hour: int,
        bars_in_zone: int = 0,
        grade: SetupGrade = SetupGrade.D,
    ) -> TimingResult:
        """
        Assess timing quality.

        Parameters
        ----------
        utc_hour : current UTC hour (0-23).
        bars_in_zone : how many 5M bars price has spent inside the active POI.
        grade : current setup grade (used to decide if weak setups are blocked).
        """
        result = TimingResult()

        # Determine kill zone
        if self.s_cfg.overlap_start <= utc_hour < self.s_cfg.overlap_end:
            result.in_kill_zone = True
            result.kill_zone_name = "overlap"
            result.timing_score = 10.0
        elif self.s_cfg.london_kz_start <= utc_hour < self.s_cfg.london_kz_end:
            result.in_kill_zone = True
            result.kill_zone_name = "london_kz"
            result.timing_score = 8.0
        elif self.s_cfg.ny_kz_start <= utc_hour < self.s_cfg.ny_kz_end:
            result.in_kill_zone = True
            result.kill_zone_name = "ny_kz"
            result.timing_score = 9.0
        elif self.s_cfg.london_start <= utc_hour < self.s_cfg.london_end:
            result.timing_score = 5.0
        elif self.s_cfg.newyork_start <= utc_hour < self.s_cfg.newyork_end:
            result.timing_score = 5.0
        elif self.s_cfg.asian_start <= utc_hour < self.s_cfg.asian_end:
            result.timing_score = 3.0
        else:
            result.timing_score = 2.0

        # Stale setup detection
        if bars_in_zone > self.t_cfg.stale_setup_bars:
            result.is_stale = True
            result.stale_bars = bars_in_zone
            # Degrade timing score by 50%
            result.timing_score *= 0.5

        # Block weak setups outside kill zones
        if self.t_cfg.weak_setup_outside_kz and not result.in_kill_zone:
            if grade in (SetupGrade.C, SetupGrade.D):
                result.allow_trade = False
                result.block_reason = f"Grade {grade.value} blocked outside kill zone"

        # A+ setups are always allowed regardless of timing
        if grade == SetupGrade.A_PLUS:
            result.allow_trade = True
            result.block_reason = ""

        return result
