"""
Commission Engine – models exact Pepperstone raw-spread commissions.

Forex:       $7 per standard lot (round-turn)
Commodities: 0.0016% of position value per lot
Crypto:      0.04% of position value per lot
Indices:     $0 commission
"""

from __future__ import annotations

from typing import Optional

from config.settings import CommissionSettings
from config.symbols import get_symbol_spec


class CommissionEngine:
    """Calculates commission for a trade."""

    def __init__(self, settings: Optional[CommissionSettings] = None) -> None:
        self.cfg = settings or CommissionSettings()

    def calculate(
        self,
        symbol: str,
        lot_size: float,
        entry_price: float,
    ) -> float:
        """
        Return total commission in account currency (USD) for a round-turn trade.

        Parameters
        ----------
        symbol : instrument name.
        lot_size : trade volume in standard lots.
        entry_price : entry price (used for value-based commissions).
        """
        spec = get_symbol_spec(symbol)
        asset_class = spec.asset_class.lower()

        if asset_class == "forex":
            # Fixed per lot
            return self.cfg.forex_per_lot * lot_size

        elif asset_class == "commodity":
            # % of position value (round-trip = 2x)
            position_value = entry_price * spec.contract_size * lot_size
            return position_value * (self.cfg.commodity_pct / 100.0) * 2.0

        elif asset_class == "crypto":
            position_value = entry_price * spec.contract_size * lot_size
            return position_value * (self.cfg.crypto_pct / 100.0) * 2.0

        elif asset_class == "index":
            return self.cfg.index_per_lot * lot_size

        # Fallback: treat as forex
        return self.cfg.forex_per_lot * lot_size
