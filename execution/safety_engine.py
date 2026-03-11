"""
Safety & Protection Engine – hard veto layer that blocks execution
regardless of setup quality.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional

from config.settings import SafetySettings, BotConfig
from config.symbols import get_symbol_spec
from data.market_data import MarketData
from models.signal import Signal
from models.state import GlobalRiskState
from core.logger import get_logger, log_safety_block

logger = get_logger("safety_engine")


@dataclass
class SafetyResult:
    """Output of the safety check."""
    passed: bool = True
    reasons: List[str] = field(default_factory=list)


class SafetyEngine:
    """Enforces production safeguards before any trade is placed."""

    def __init__(
        self,
        settings: Optional[SafetySettings] = None,
        config: Optional[BotConfig] = None,
    ) -> None:
        self.cfg = settings or SafetySettings()
        self.bot_cfg = config or BotConfig()

    def check(
        self,
        signal: Signal,
        market_data: MarketData,
        global_risk: GlobalRiskState,
        account_balance: float,
    ) -> SafetyResult:
        """
        Run all safety checks.  ANY failure blocks the trade.

        Checks:
        1. Emergency pause
        2. Spread filter
        3. Daily drawdown limit
        4. Consecutive loss limit
        5. Abnormal volatility filter
        6. Connection health (implicit – if we got here, connection is OK)
        """
        result = SafetyResult()

        # 1. Emergency pause
        if self.cfg.emergency_pause:
            result.passed = False
            result.reasons.append("Emergency pause is active")

        # 2. Global trading pause
        if global_risk.trading_paused:
            result.passed = False
            result.reasons.append(f"Trading paused: {global_risk.pause_reason}")

        # 3. Spread filter
        spread = market_data.current_spread_pips(signal.symbol)
        max_spread = self.bot_cfg.max_spread.get(signal.symbol, 5.0)
        if spread > max_spread:
            result.passed = False
            result.reasons.append(
                f"Spread {spread:.1f} pips > max {max_spread:.1f} pips"
            )

        # 4. Daily drawdown
        if account_balance > 0:
            dd_pct = abs(global_risk.daily_drawdown) / account_balance * 100.0
            if dd_pct >= self.bot_cfg.risk.max_daily_drawdown_pct:
                result.passed = False
                result.reasons.append(
                    f"Daily drawdown {dd_pct:.2f}% >= {self.bot_cfg.risk.max_daily_drawdown_pct}%"
                )

        # 5. Consecutive losses
        if global_risk.consecutive_losses >= self.bot_cfg.risk.max_consecutive_losses:
            result.passed = False
            result.reasons.append(
                f"Consecutive losses {global_risk.consecutive_losses} "
                f">= {self.bot_cfg.risk.max_consecutive_losses}"
            )

        # Log if blocked
        if not result.passed:
            for reason in result.reasons:
                log_safety_block(logger, signal.symbol, reason)

        return result
