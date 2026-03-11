"""
Trade Executor – sends orders to MT5 (or simulates in dry-run mode).
"""

from __future__ import annotations

import uuid
import time
from typing import Optional

from config.symbols import get_symbol_spec
from core.logger import get_logger
from models.signal import Signal, SignalDirection
from models.trade import Trade, TradeDirection, TradeStatus

logger = get_logger("executor")

try:
    import MetaTrader5 as mt5  # type: ignore
    MT5_AVAILABLE = True
except ImportError:
    mt5 = None  # type: ignore
    MT5_AVAILABLE = False


class Executor:
    """Places and verifies orders on MT5."""

    def __init__(self, dry_run: bool = True) -> None:
        self.dry_run = dry_run

    def execute(self, signal: Signal) -> Optional[Trade]:
        """
        Execute the signal as a market order.

        Returns a Trade object on success, None on failure.
        """
        if not signal.approved:
            logger.info(
                f"Signal not approved for {signal.symbol}: "
                f"{signal.rejection_reasons}"
            )
            return None

        if signal.lot_size <= 0:
            logger.warning(f"Lot size is 0 for {signal.symbol} – skipping")
            return None

        trade = Trade(
            id=uuid.uuid4().hex[:12],
            symbol=signal.symbol,
            direction=(
                TradeDirection.BUY
                if signal.direction == SignalDirection.BUY
                else TradeDirection.SELL
            ),
            entry_price=signal.entry_price,
            sl_price=signal.sl_price,
            tp_price=signal.tp_price,
            lot_size=signal.lot_size,
            risk_pct=signal.risk_pct,
            grade=signal.grade.value,
            score=signal.score,
            poi_id=signal.poi_id,
            signal_confluences=signal.confluences,
            open_timestamp=time.time(),
        )

        if self.dry_run:
            logger.info(
                f"[DRY RUN] {trade.direction.value.upper()} {trade.symbol} | "
                f"entry={trade.entry_price} SL={trade.sl_price} TP={trade.tp_price} | "
                f"lots={trade.lot_size} grade={trade.grade}"
            )
            trade.status = TradeStatus.OPEN
            trade.mt5_ticket = -1  # simulated
            return trade

        # --- Live execution ---
        if not MT5_AVAILABLE:
            logger.error("MT5 not available – cannot execute live order")
            return None

        spec = get_symbol_spec(signal.symbol)
        order_type = (
            mt5.ORDER_TYPE_BUY
            if signal.direction == SignalDirection.BUY
            else mt5.ORDER_TYPE_SELL
        )

        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": spec.broker_name,
            "volume": signal.lot_size,
            "type": order_type,
            "price": signal.entry_price,
            "sl": signal.sl_price,
            "tp": signal.tp_price,
            "deviation": 10,  # max slippage in points
            "magic": 202603,
            "comment": f"InstitutionalBot_{signal.grade.value}",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }

        result = mt5.order_send(request)

        if result is None:
            logger.error(f"Order send returned None for {signal.symbol}")
            return None

        if result.retcode != mt5.TRADE_RETCODE_DONE:
            logger.error(
                f"Order failed for {signal.symbol}: "
                f"retcode={result.retcode} comment={result.comment}"
            )
            return None

        trade.mt5_ticket = result.order
        trade.status = TradeStatus.OPEN
        trade.entry_price = result.price  # actual fill price

        logger.info(
            f"ORDER FILLED | {trade.direction.value.upper()} {trade.symbol} | "
            f"ticket={trade.mt5_ticket} price={trade.entry_price} "
            f"lots={trade.lot_size} grade={trade.grade}"
        )
        return trade

    def close_trade(self, trade: Trade) -> bool:
        """Close an open trade."""
        if self.dry_run:
            logger.info(f"[DRY RUN] Closing {trade.symbol} ticket={trade.mt5_ticket}")
            trade.status = TradeStatus.CLOSED_WIN  # placeholder
            trade.close_timestamp = time.time()
            return True

        if not MT5_AVAILABLE:
            logger.error("MT5 not available")
            return False

        spec = get_symbol_spec(trade.symbol)
        close_type = (
            mt5.ORDER_TYPE_SELL
            if trade.direction == TradeDirection.BUY
            else mt5.ORDER_TYPE_BUY
        )

        tick = mt5.symbol_info_tick(spec.broker_name)
        if tick is None:
            logger.error(f"Cannot get tick for {trade.symbol}")
            return False

        price = tick.bid if trade.direction == TradeDirection.BUY else tick.ask

        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": spec.broker_name,
            "volume": trade.lot_size,
            "type": close_type,
            "position": trade.mt5_ticket,
            "price": price,
            "deviation": 10,
            "magic": 202603,
            "comment": "InstitutionalBot_close",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }

        result = mt5.order_send(request)
        if result is None or result.retcode != mt5.TRADE_RETCODE_DONE:
            logger.error(f"Close failed for ticket {trade.mt5_ticket}")
            return False

        trade.close_price = result.price
        trade.close_timestamp = time.time()
        logger.info(f"Trade closed | ticket={trade.mt5_ticket} close_price={trade.close_price}")
        return True
