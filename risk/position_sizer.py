"""
Position Sizer – calculates lot size from risk percentage, stop-loss distance,
and instrument specification.
"""

from __future__ import annotations

from typing import Optional

from config.settings import RiskSettings
from config.symbols import get_symbol_spec, pips_to_price
from core.logger import get_logger

logger = get_logger("position_sizer")


class PositionSizer:
    """Computes lot size for a given risk budget and SL distance."""

    def __init__(self, settings: Optional[RiskSettings] = None) -> None:
        self.cfg = settings or RiskSettings()

    def calculate_lot_size(
        self,
        symbol: str,
        account_balance: float,
        risk_pct: float,
        sl_distance_pips: float,
    ) -> float:
        """
        Calculate lot size.

        Parameters
        ----------
        symbol : instrument name.
        account_balance : account balance in USD.
        risk_pct : % of balance to risk (e.g. 1.0 = 1%).
        sl_distance_pips : distance from entry to SL in pips.

        Returns
        -------
        Lot size rounded to 2 decimal places (0.01 minimum if trade is allowed).
        """
        if risk_pct <= 0 or sl_distance_pips <= 0 or account_balance <= 0:
            return 0.0

        spec = get_symbol_spec(symbol)

        risk_amount = account_balance * (risk_pct / 100.0)

        # Pip value per standard lot
        # For most forex pairs quoted in USD: pip_value = contract_size * pip_size
        # For XAUUSD: 1 pip = 0.1, contract = 100 oz → pip_value = 100 * 0.1 = $10
        pip_value_per_lot = spec.contract_size * spec.pip_size

        if pip_value_per_lot <= 0:
            logger.error(f"Invalid pip value for {symbol}")
            return 0.0

        lots = risk_amount / (sl_distance_pips * pip_value_per_lot)

        # Round down to 2 decimals (micro lots)
        lots = round(lots, 2)

        # Enforce minimum
        if lots < 0.01:
            lots = 0.0  # too small to trade

        logger.debug(
            f"Position size: {symbol} | balance={account_balance:.2f} | "
            f"risk={risk_pct:.2f}% | SL={sl_distance_pips:.1f} pips | "
            f"pip_value/lot={pip_value_per_lot:.4f} | lots={lots:.2f}"
        )
        return lots

    def calculate_sl_price(
        self,
        symbol: str,
        entry_price: float,
        direction: str,
        sl_pips: Optional[float] = None,
    ) -> float:
        """
        Calculate the stop-loss price from entry and pip distance.

        Parameters
        ----------
        direction : "buy" or "sell".
        sl_pips : SL distance in pips; defaults to config default.
        """
        if sl_pips is None:
            spec = get_symbol_spec(symbol)
            sl_pips = spec.default_sl_pips

        sl_price_dist = pips_to_price(symbol, sl_pips)

        if direction == "buy":
            return round(entry_price - sl_price_dist, 8)
        else:
            return round(entry_price + sl_price_dist, 8)

    def calculate_tp_price(
        self,
        entry_price: float,
        direction: str,
        tp_target_price: float,
    ) -> float:
        """
        Return the take-profit price.

        Typically the nearest opposing liquidity level or POI.
        """
        # Just pass through the target – validation is done upstream
        return tp_target_price
