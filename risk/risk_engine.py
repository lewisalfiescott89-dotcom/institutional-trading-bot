"""
Risk Engine – maps setup grade to risk percentage, applies regime adjustments,
and enforces daily drawdown / consecutive loss limits.
"""

from __future__ import annotations

from typing import Optional

from config.settings import RiskSettings
from models.signal import Signal, SetupGrade
from models.regime import MarketRegime
from models.state import GlobalRiskState
from core.logger import get_logger

logger = get_logger("risk_engine")


class RiskEngine:
    """Determines risk allocation per trade."""

    def __init__(self, settings: Optional[RiskSettings] = None) -> None:
        self.cfg = settings or RiskSettings()

    def compute_risk_pct(
        self,
        signal: Signal,
        regime: MarketRegime,
        global_risk: GlobalRiskState,
        account_balance: float,
    ) -> float:
        """
        Return the risk percentage of account balance for this trade.

        Returns 0.0 if the trade is blocked by drawdown / loss limits.
        """
        # 1. Base risk from grade
        base_risk = self.cfg.grade_risk_map.get(signal.grade.value, 0.0)
        if base_risk <= 0:
            logger.info(f"Grade {signal.grade.value} → risk 0% (no trade)")
            return 0.0

        # 2. Regime adjustment
        regime_mult = regime.risk_multiplier()
        adjusted_risk = base_risk * regime_mult

        # 3. Daily drawdown check
        if account_balance > 0:
            dd_pct = abs(global_risk.daily_drawdown) / account_balance * 100.0
            if dd_pct >= self.cfg.max_daily_drawdown_pct:
                logger.warning(
                    f"Daily drawdown {dd_pct:.2f}% >= limit {self.cfg.max_daily_drawdown_pct}% – blocking"
                )
                return 0.0

        # 4. Consecutive loss check
        if global_risk.consecutive_losses >= self.cfg.max_consecutive_losses:
            logger.warning(
                f"Consecutive losses {global_risk.consecutive_losses} >= limit "
                f"{self.cfg.max_consecutive_losses} – blocking"
            )
            return 0.0

        # 5. Trading paused check
        if global_risk.trading_paused:
            logger.warning(f"Trading paused: {global_risk.pause_reason}")
            return 0.0

        return round(adjusted_risk, 4)

    def update_after_trade(
        self,
        global_risk: GlobalRiskState,
        net_pnl: float,
        is_win: bool,
    ) -> None:
        """Update global risk state after a trade closes."""
        global_risk.daily_pnl += net_pnl
        global_risk.total_trades_today += 1

        if is_win:
            global_risk.consecutive_losses = 0
        else:
            global_risk.consecutive_losses += 1

        # Update drawdown
        if global_risk.daily_pnl < 0:
            global_risk.daily_drawdown = min(
                global_risk.daily_drawdown, global_risk.daily_pnl
            )

    def reset_daily(self, global_risk: GlobalRiskState) -> None:
        """Reset daily counters (call at start of new trading day)."""
        global_risk.daily_pnl = 0.0
        global_risk.daily_drawdown = 0.0
        global_risk.total_trades_today = 0
        global_risk.consecutive_losses = 0
        if global_risk.trading_paused and global_risk.pause_reason.startswith("daily"):
            global_risk.trading_paused = False
            global_risk.pause_reason = ""
