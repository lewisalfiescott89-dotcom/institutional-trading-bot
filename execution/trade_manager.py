"""
Trade Manager – manages open trades, checks SL/TP hits, calculates PnL,
handles re-entry eligibility.
"""

from __future__ import annotations

from typing import List, Optional

from config.symbols import get_symbol_spec, price_to_pips
from core.logger import get_logger
from models.trade import Trade, TradeStatus, TradeDirection
from risk.commission_engine import CommissionEngine

logger = get_logger("trade_manager")


class TradeManager:
    """Manages the lifecycle of open trades."""

    def __init__(self, commission_engine: Optional[CommissionEngine] = None) -> None:
        self.commission = commission_engine or CommissionEngine()

    def check_sl_tp(
        self,
        trade: Trade,
        current_bid: float,
        current_ask: float,
    ) -> bool:
        """
        Check if the trade has hit SL or TP.

        Returns True if the trade was closed, False if still open.
        """
        if not trade.is_open():
            return False

        # For buys: current price is bid
        # For sells: current price is ask
        if trade.direction == TradeDirection.BUY:
            current_price = current_bid
            # SL hit
            if current_price <= trade.sl_price:
                self._close_trade(trade, trade.sl_price, is_sl=True)
                return True
            # TP hit
            if trade.tp_price > 0 and current_price >= trade.tp_price:
                self._close_trade(trade, trade.tp_price, is_sl=False)
                return True
        else:
            current_price = current_ask
            # SL hit
            if current_price >= trade.sl_price:
                self._close_trade(trade, trade.sl_price, is_sl=True)
                return True
            # TP hit
            if trade.tp_price > 0 and current_price <= trade.tp_price:
                self._close_trade(trade, trade.tp_price, is_sl=False)
                return True

        return False

    def _close_trade(self, trade: Trade, close_price: float, is_sl: bool) -> None:
        """Finalize a trade with PnL and commission."""
        trade.close_price = close_price
        spec = get_symbol_spec(trade.symbol)

        # Gross PnL
        if trade.direction == TradeDirection.BUY:
            price_diff = close_price - trade.entry_price
        else:
            price_diff = trade.entry_price - close_price

        pip_diff = price_diff / spec.pip_size if spec.pip_size > 0 else 0.0
        pip_value_per_lot = spec.contract_size * spec.pip_size
        trade.gross_pnl = price_diff * spec.contract_size * trade.lot_size

        # Commission
        trade.commission = self.commission.calculate(
            trade.symbol, trade.lot_size, trade.entry_price
        )
        trade.net_pnl = trade.gross_pnl - trade.commission

        # R multiple
        risk_dist = trade.risk_distance()
        if risk_dist > 0:
            risk_value = risk_dist * spec.contract_size * trade.lot_size
            trade.r_multiple = trade.net_pnl / risk_value if risk_value > 0 else 0.0
        else:
            trade.r_multiple = 0.0

        # Status
        if trade.net_pnl > 0:
            trade.status = TradeStatus.CLOSED_WIN
        elif trade.net_pnl < 0:
            trade.status = TradeStatus.CLOSED_LOSS
        else:
            trade.status = TradeStatus.CLOSED_BE

        import time
        trade.close_timestamp = time.time()

        logger.info(
            f"Trade {'SL' if is_sl else 'TP'} | {trade.symbol} {trade.direction.value} | "
            f"gross={trade.gross_pnl:.2f} comm={trade.commission:.2f} "
            f"net={trade.net_pnl:.2f} R={trade.r_multiple:.2f}"
        )

    def check_reentry_eligibility(self, trade: Trade) -> bool:
        """
        After a trade is stopped out, determine if the POI is still valid
        for re-entry.

        Re-entry requires a fresh sweep/trap + reversal (handled by orchestrator).
        This method just checks that the POI wasn't broken.
        """
        # A stopped-out trade doesn't automatically invalidate the POI.
        # The orchestrator checks the Pepperstone invalidation rule separately.
        return True

    def manage_open_trades(
        self,
        trades: List[Trade],
        bid: float,
        ask: float,
    ) -> List[Trade]:
        """
        Check all open trades for SL/TP.

        Returns the list of trades that were closed this cycle.
        """
        closed: List[Trade] = []
        for trade in trades:
            if trade.is_open():
                if self.check_sl_tp(trade, bid, ask):
                    closed.append(trade)
        return closed
