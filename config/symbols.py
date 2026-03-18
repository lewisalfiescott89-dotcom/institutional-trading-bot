"""
Symbol-specific configuration for Pepperstone and instrument metadata.

Pepperstone may append suffixes (e.g. ".r" for raw accounts).  Adjust the
BROKER_SUFFIX or per-symbol overrides below to match your terminal.
"""

from dataclasses import dataclass, field
from typing import Dict


BROKER_SUFFIX: str = ""   # e.g. ".r" if Pepperstone appends a suffix


@dataclass
class SymbolSpec:
    """Instrument specification relevant to the trading bot."""
    name: str                       # canonical name used internally
    broker_name: str                # name as it appears in MT5 terminal
    asset_class: str                # "forex", "commodity", "crypto", "index"
    pip_size: float                 # value of 1 pip in price terms
    point_size: float               # minimum price increment
    contract_size: float            # units per standard lot
    digits: int                     # decimal places
    default_sl_pips: float = 30.0   # instrument-specific default SL
    max_spread_pips: float = 5.0    # instrument-specific spread filter


# ---------------------------------------------------------------------------
# Pre-configured symbol specs (edit broker_name if your terminal differs)
# ---------------------------------------------------------------------------
SYMBOL_SPECS: Dict[str, SymbolSpec] = {
    "XAUUSD": SymbolSpec(
        name="XAUUSD",
        broker_name=f"XAUUSD{BROKER_SUFFIX}",
        asset_class="commodity",
        pip_size=0.1,
        point_size=0.01,
        contract_size=100,      # 100 oz per lot
        digits=2,
        default_sl_pips=30.0,
        max_spread_pips=5.0,
    ),
    "GBPUSD": SymbolSpec(
        name="GBPUSD",
        broker_name=f"GBPUSD{BROKER_SUFFIX}",
        asset_class="forex",
        pip_size=0.0001,
        point_size=0.00001,
        contract_size=100_000,
        digits=5,
        default_sl_pips=30.0,
        max_spread_pips=2.0,
    ),
    "EURUSD": SymbolSpec(
        name="EURUSD",
        broker_name=f"EURUSD{BROKER_SUFFIX}",
        asset_class="forex",
        pip_size=0.0001,
        point_size=0.00001,
        contract_size=100_000,
        digits=5,
        default_sl_pips=30.0,
        max_spread_pips=1.5,
    ),
    "US30": SymbolSpec(
        name="US30",
        broker_name=f"US30{BROKER_SUFFIX}",
        asset_class="index",
        pip_size=1.0,
        point_size=0.1,
        contract_size=1,
        digits=1,
        default_sl_pips=30.0,
        max_spread_pips=5.0,
    ),
    "BTCUSD": SymbolSpec(
        name="BTCUSD",
        broker_name=f"BTCUSD{BROKER_SUFFIX}",
        asset_class="crypto",
        pip_size=1.0,
        point_size=0.01,
        contract_size=1,
        digits=2,
        default_sl_pips=30.0,
        max_spread_pips=50.0,
    ),
}


def get_symbol_spec(symbol: str) -> SymbolSpec:
    """Return the spec for *symbol*, raising KeyError if not configured."""
    if symbol not in SYMBOL_SPECS:
        raise KeyError(
            f"Symbol '{symbol}' not configured. Add it to config/symbols.py."
        )
    return SYMBOL_SPECS[symbol]


def pips_to_price(symbol: str, pips: float) -> float:
    """Convert a pip value to price distance for the given symbol."""
    spec = get_symbol_spec(symbol)
    return pips * spec.pip_size


def price_to_pips(symbol: str, price_distance: float) -> float:
    """Convert a price distance to pips for the given symbol."""
    spec = get_symbol_spec(symbol)
    if spec.pip_size == 0:
        return 0.0
    return price_distance / spec.pip_size
