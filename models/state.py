"""
Persistent state model – everything the bot must remember across restarts.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional

from models.poi import POI
from models.liquidity import LiquidityLevel
from models.trade import Trade
from models.regime import MarketRegime


@dataclass
class SymbolState:
    """Per-symbol runtime state."""

    symbol: str = ""

    # POIs
    active_pois: List[POI] = field(default_factory=list)
    invalidated_pois: List[POI] = field(default_factory=list)

    # Liquidity
    active_liquidity: List[LiquidityLevel] = field(default_factory=list)
    swept_liquidity: List[LiquidityLevel] = field(default_factory=list)

    # Session / forecast
    session_name: str = ""
    in_kill_zone: bool = False
    forecast_target_price: float = 0.0
    forecast_direction: str = ""

    # Signal progression
    wick_probe_pending_poi_id: Optional[str] = None

    # Trades
    open_trades: List[Trade] = field(default_factory=list)
    recent_closed_trades: List[Trade] = field(default_factory=list)

    # Regime
    regime: Optional[MarketRegime] = None

    # Re-entry
    reentry_eligible_poi_ids: List[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "symbol": self.symbol,
            "active_pois": [p.to_dict() for p in self.active_pois],
            "invalidated_pois": [p.to_dict() for p in self.invalidated_pois],
            "active_liquidity": [l.to_dict() for l in self.active_liquidity],
            "swept_liquidity": [l.to_dict() for l in self.swept_liquidity],
            "session_name": self.session_name,
            "in_kill_zone": self.in_kill_zone,
            "forecast_target_price": self.forecast_target_price,
            "forecast_direction": self.forecast_direction,
            "wick_probe_pending_poi_id": self.wick_probe_pending_poi_id,
            "open_trades": [t.to_dict() for t in self.open_trades],
            "recent_closed_trades": [t.to_dict() for t in self.recent_closed_trades],
            "regime": self.regime.to_dict() if self.regime else None,
            "reentry_eligible_poi_ids": self.reentry_eligible_poi_ids,
        }


@dataclass
class GlobalRiskState:
    """Cross-symbol risk tracking."""

    daily_pnl: float = 0.0
    daily_drawdown: float = 0.0
    peak_equity: float = 0.0
    consecutive_losses: int = 0
    trading_paused: bool = False
    pause_reason: str = ""
    total_trades_today: int = 0

    def to_dict(self) -> dict:
        return {
            "daily_pnl": self.daily_pnl,
            "daily_drawdown": self.daily_drawdown,
            "peak_equity": self.peak_equity,
            "consecutive_losses": self.consecutive_losses,
            "trading_paused": self.trading_paused,
            "pause_reason": self.pause_reason,
            "total_trades_today": self.total_trades_today,
        }


@dataclass
class BotState:
    """Top-level persistent state for the entire bot."""

    symbols: Dict[str, SymbolState] = field(default_factory=dict)
    global_risk: GlobalRiskState = field(default_factory=GlobalRiskState)
    last_update_epoch: float = 0.0

    def get_symbol_state(self, symbol: str) -> SymbolState:
        if symbol not in self.symbols:
            self.symbols[symbol] = SymbolState(symbol=symbol)
        return self.symbols[symbol]

    def to_dict(self) -> dict:
        return {
            "symbols": {s: st.to_dict() for s, st in self.symbols.items()},
            "global_risk": self.global_risk.to_dict(),
            "last_update_epoch": self.last_update_epoch,
        }
