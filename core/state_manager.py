"""
State Manager – persists and restores bot state across restarts using JSON.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Optional

from core.logger import get_logger
from models.state import BotState, SymbolState, GlobalRiskState
from models.poi import POI
from models.liquidity import LiquidityLevel
from models.trade import Trade

logger = get_logger("state_manager")


class StateManager:
    """Handles saving / loading the full bot state to/from disk."""

    def __init__(self, state_file: str = "bot_state.json") -> None:
        self.state_file = Path(state_file)
        self.state = BotState()

    # ------------------------------------------------------------------
    # Save
    # ------------------------------------------------------------------

    def save(self) -> None:
        """Persist the current state to JSON."""
        self.state.last_update_epoch = time.time()
        data = self.state.to_dict()
        try:
            tmp = self.state_file.with_suffix(".tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, default=str)
            tmp.replace(self.state_file)
            logger.debug(f"State saved to {self.state_file}")
        except Exception as e:
            logger.error(f"Failed to save state: {e}")

    # ------------------------------------------------------------------
    # Load
    # ------------------------------------------------------------------

    def load(self) -> BotState:
        """Load state from disk. Returns a fresh BotState if file doesn't exist."""
        if not self.state_file.exists():
            logger.info("No state file found – starting fresh")
            self.state = BotState()
            return self.state

        try:
            with open(self.state_file, "r", encoding="utf-8") as f:
                data = json.load(f)
            self.state = self._deserialize(data)
            logger.info(
                f"State loaded from {self.state_file} | "
                f"symbols={list(self.state.symbols.keys())} | "
                f"last_update={self.state.last_update_epoch}"
            )
        except Exception as e:
            logger.error(f"Failed to load state: {e} – starting fresh")
            self.state = BotState()

        return self.state

    # ------------------------------------------------------------------
    # Convenience accessors
    # ------------------------------------------------------------------

    def get_symbol_state(self, symbol: str) -> SymbolState:
        return self.state.get_symbol_state(symbol)

    @property
    def global_risk(self) -> GlobalRiskState:
        return self.state.global_risk

    # ------------------------------------------------------------------
    # Deserialisation
    # ------------------------------------------------------------------

    def _deserialize(self, data: dict) -> BotState:
        """Rebuild BotState from a JSON-compatible dict."""
        bot = BotState()
        bot.last_update_epoch = data.get("last_update_epoch", 0.0)

        # Global risk
        gr = data.get("global_risk", {})
        bot.global_risk = GlobalRiskState(
            daily_pnl=gr.get("daily_pnl", 0.0),
            daily_drawdown=gr.get("daily_drawdown", 0.0),
            peak_equity=gr.get("peak_equity", 0.0),
            consecutive_losses=gr.get("consecutive_losses", 0),
            trading_paused=gr.get("trading_paused", False),
            pause_reason=gr.get("pause_reason", ""),
            total_trades_today=gr.get("total_trades_today", 0),
        )

        # Per-symbol state
        for sym, sdata in data.get("symbols", {}).items():
            ss = SymbolState(symbol=sym)
            ss.active_pois = [POI.from_dict(p) for p in sdata.get("active_pois", [])]
            ss.invalidated_pois = [POI.from_dict(p) for p in sdata.get("invalidated_pois", [])]
            ss.active_liquidity = [LiquidityLevel.from_dict(l) for l in sdata.get("active_liquidity", [])]
            ss.swept_liquidity = [LiquidityLevel.from_dict(l) for l in sdata.get("swept_liquidity", [])]
            ss.open_trades = [Trade.from_dict(t) for t in sdata.get("open_trades", [])]
            ss.recent_closed_trades = [Trade.from_dict(t) for t in sdata.get("recent_closed_trades", [])]
            ss.session_name = sdata.get("session_name", "")
            ss.in_kill_zone = sdata.get("in_kill_zone", False)
            ss.forecast_target_price = sdata.get("forecast_target_price", 0.0)
            ss.forecast_direction = sdata.get("forecast_direction", "")
            ss.wick_probe_pending_poi_id = sdata.get("wick_probe_pending_poi_id")
            ss.reentry_eligible_poi_ids = sdata.get("reentry_eligible_poi_ids", [])
            bot.symbols[sym] = ss

        return bot
