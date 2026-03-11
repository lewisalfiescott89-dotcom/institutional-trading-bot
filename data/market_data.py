"""
Market data fetcher – pulls OHLCV candles and tick data from MT5.

Also provides an offline / CSV fallback for backtesting without MT5.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Dict, List, Optional

import numpy as np
import pandas as pd

from config.symbols import get_symbol_spec
from data.timeframes import mt5_timeframe, bars_needed
from core.logger import get_logger

logger = get_logger("market_data")

try:
    import MetaTrader5 as mt5  # type: ignore
    MT5_AVAILABLE = True
except ImportError:
    mt5 = None  # type: ignore
    MT5_AVAILABLE = False


class MarketData:
    """Fetches and caches candle data for all required timeframes."""

    def __init__(self) -> None:
        # cache: symbol -> tf -> DataFrame
        self._cache: Dict[str, Dict[str, pd.DataFrame]] = {}

    # ------------------------------------------------------------------
    # Fetch
    # ------------------------------------------------------------------

    def fetch_candles(
        self,
        symbol: str,
        timeframe: str,
        count: Optional[int] = None,
        lookback_days: int = 180,
    ) -> pd.DataFrame:
        """
        Fetch OHLCV candles from MT5.

        Returns a DataFrame with columns:
            time, open, high, low, close, tick_volume, spread
        indexed by integer position (not datetime).
        """
        if count is None:
            count = bars_needed(timeframe, lookback_days)

        spec = get_symbol_spec(symbol)

        if not MT5_AVAILABLE:
            logger.warning(f"MT5 not available – returning empty frame for {symbol}/{timeframe}")
            return self._empty_frame()

        tf_const = mt5_timeframe(timeframe)
        rates = mt5.copy_rates_from_pos(spec.broker_name, tf_const, 0, count)

        if rates is None or len(rates) == 0:
            logger.warning(f"No data returned for {symbol}/{timeframe}")
            return self._empty_frame()

        df = pd.DataFrame(rates)
        df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
        df.rename(columns={"tick_volume": "volume"}, inplace=True)

        # Keep only the columns we need
        cols = ["time", "open", "high", "low", "close", "volume", "spread"]
        for c in cols:
            if c not in df.columns:
                df[c] = 0
        df = df[cols].copy()
        df.reset_index(drop=True, inplace=True)

        # Cache
        self._cache.setdefault(symbol, {})[timeframe] = df
        return df

    def fetch_all_timeframes(
        self,
        symbol: str,
        timeframes: List[str],
        lookback_days: int = 180,
    ) -> Dict[str, pd.DataFrame]:
        """Fetch candles for every timeframe and return as dict."""
        result: Dict[str, pd.DataFrame] = {}
        for tf in timeframes:
            result[tf] = self.fetch_candles(symbol, tf, lookback_days=lookback_days)
        return result

    # ------------------------------------------------------------------
    # Tick data
    # ------------------------------------------------------------------

    def fetch_latest_tick(self, symbol: str) -> Optional[dict]:
        """Return the most recent tick as a dict with bid/ask/time."""
        if not MT5_AVAILABLE:
            return None
        spec = get_symbol_spec(symbol)
        tick = mt5.symbol_info_tick(spec.broker_name)
        if tick is None:
            return None
        return {
            "bid": tick.bid,
            "ask": tick.ask,
            "last": tick.last,
            "time": tick.time,
            "spread": tick.ask - tick.bid,
        }

    def current_spread_pips(self, symbol: str) -> float:
        """Return current spread in pips."""
        tick = self.fetch_latest_tick(symbol)
        if tick is None:
            return 999.0  # unknown → large to block trading
        spec = get_symbol_spec(symbol)
        return (tick["ask"] - tick["bid"]) / spec.pip_size

    # ------------------------------------------------------------------
    # Cache access
    # ------------------------------------------------------------------

    def get_cached(self, symbol: str, timeframe: str) -> Optional[pd.DataFrame]:
        return self._cache.get(symbol, {}).get(timeframe)

    def clear_cache(self) -> None:
        self._cache.clear()

    # ------------------------------------------------------------------
    # Offline helpers
    # ------------------------------------------------------------------

    def load_csv(self, path: str, symbol: str, timeframe: str) -> pd.DataFrame:
        """
        Load candle data from a CSV file (for backtesting).

        Expected columns: time, open, high, low, close, volume
        """
        df = pd.read_csv(path, parse_dates=["time"])
        if "volume" not in df.columns:
            df["volume"] = 0
        if "spread" not in df.columns:
            df["spread"] = 0
        df.reset_index(drop=True, inplace=True)
        self._cache.setdefault(symbol, {})[timeframe] = df
        return df

    @staticmethod
    def _empty_frame() -> pd.DataFrame:
        return pd.DataFrame(
            columns=["time", "open", "high", "low", "close", "volume", "spread"]
        )
