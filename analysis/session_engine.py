"""
Session Engine – identifies trading sessions, tracks session highs/lows,
and determines the current kill zone.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, List, Optional

import pandas as pd

from config.settings import SessionSettings
from core.utils import now_utc


@dataclass
class SessionState:
    """Tracks the current session and key session levels."""

    current_session: str = "off_hours"       # asian / london / newyork / overlap / off_hours
    in_kill_zone: bool = False
    kill_zone_name: str = ""

    # Session highs and lows
    asian_high: float = 0.0
    asian_low: float = float("inf")
    london_high: float = 0.0
    london_low: float = float("inf")
    ny_high: float = 0.0
    ny_low: float = float("inf")

    # Previous day / week levels (populated externally)
    prev_day_high: float = 0.0
    prev_day_low: float = 0.0
    prev_week_high: float = 0.0
    prev_week_low: float = 0.0

    def session_levels_dict(self) -> Dict[str, float]:
        """Return all session-related levels as a flat dict for the liquidity map."""
        return {
            "asian_high": self.asian_high if self.asian_high > 0 else 0.0,
            "asian_low": self.asian_low if self.asian_low < float("inf") else 0.0,
            "london_high": self.london_high if self.london_high > 0 else 0.0,
            "london_low": self.london_low if self.london_low < float("inf") else 0.0,
            "ny_high": self.ny_high if self.ny_high > 0 else 0.0,
            "ny_low": self.ny_low if self.ny_low < float("inf") else 0.0,
            "prev_day_high": self.prev_day_high,
            "prev_day_low": self.prev_day_low,
            "prev_week_high": self.prev_week_high,
            "prev_week_low": self.prev_week_low,
        }


class SessionEngine:
    """Manages session identification and session-level tracking."""

    def __init__(self, settings: Optional[SessionSettings] = None) -> None:
        self.cfg = settings or SessionSettings()

    def identify_session(self, utc_hour: Optional[int] = None) -> SessionState:
        """
        Determine the current trading session based on UTC hour.

        Returns a SessionState with the session name and kill-zone flag.
        """
        if utc_hour is None:
            utc_hour = now_utc().hour

        state = SessionState()

        # Overlap takes priority
        if self.cfg.overlap_start <= utc_hour < self.cfg.overlap_end:
            state.current_session = "overlap"
            state.in_kill_zone = True
            state.kill_zone_name = "overlap"
        elif self.cfg.london_start <= utc_hour < self.cfg.london_end:
            state.current_session = "london"
            if self.cfg.london_kz_start <= utc_hour < self.cfg.london_kz_end:
                state.in_kill_zone = True
                state.kill_zone_name = "london_kz"
        elif self.cfg.newyork_start <= utc_hour < self.cfg.newyork_end:
            state.current_session = "newyork"
            if self.cfg.ny_kz_start <= utc_hour < self.cfg.ny_kz_end:
                state.in_kill_zone = True
                state.kill_zone_name = "ny_kz"
        elif self.cfg.asian_start <= utc_hour < self.cfg.asian_end:
            state.current_session = "asian"
        else:
            state.current_session = "off_hours"

        return state

    def update_session_levels(
        self,
        state: SessionState,
        df: pd.DataFrame,
        utc_hour: Optional[int] = None,
    ) -> SessionState:
        """
        Update session highs/lows from recent candle data.

        Assumes *df* contains 5M candles with a 'time' column (datetime).
        """
        if df.empty or "time" not in df.columns:
            return state

        if utc_hour is None:
            utc_hour = now_utc().hour

        # Filter today's candles
        today = now_utc().date()

        for _, row in df.iterrows():
            bar_time = row["time"]
            if hasattr(bar_time, "date"):
                if bar_time.date() != today:
                    continue
                h = bar_time.hour
            else:
                continue

            high = float(row["high"])
            low = float(row["low"])

            # Asian
            if self.cfg.asian_start <= h < self.cfg.asian_end:
                state.asian_high = max(state.asian_high, high)
                state.asian_low = min(state.asian_low, low)

            # London
            if self.cfg.london_start <= h < self.cfg.london_end:
                state.london_high = max(state.london_high, high)
                state.london_low = min(state.london_low, low)

            # New York
            if self.cfg.newyork_start <= h < self.cfg.newyork_end:
                state.ny_high = max(state.ny_high, high)
                state.ny_low = min(state.ny_low, low)

        return state

    def compute_prev_day_levels(self, daily_df: pd.DataFrame) -> Dict[str, float]:
        """Extract previous day high/low from a daily DataFrame."""
        if daily_df.empty or len(daily_df) < 2:
            return {"prev_day_high": 0.0, "prev_day_low": 0.0}
        prev = daily_df.iloc[-2]
        return {
            "prev_day_high": float(prev["high"]),
            "prev_day_low": float(prev["low"]),
        }

    def compute_prev_week_levels(self, weekly_df: pd.DataFrame) -> Dict[str, float]:
        """Extract previous week high/low from a weekly DataFrame."""
        if weekly_df.empty or len(weekly_df) < 2:
            return {"prev_week_high": 0.0, "prev_week_low": 0.0}
        prev = weekly_df.iloc[-2]
        return {
            "prev_week_high": float(prev["high"]),
            "prev_week_low": float(prev["low"]),
        }
