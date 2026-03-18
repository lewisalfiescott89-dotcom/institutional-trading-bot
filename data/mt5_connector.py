"""
MetaTrader 5 connection manager.

Handles initialisation, reconnection, symbol validation, and graceful shutdown.
"""

from __future__ import annotations

import time
from typing import Optional

from config.settings import MT5Settings
from core.logger import get_logger

logger = get_logger("mt5_connector")

# Lazy import – allows the project to be loaded without MT5 installed
try:
    import MetaTrader5 as mt5  # type: ignore
    MT5_AVAILABLE = True
except ImportError:
    mt5 = None  # type: ignore
    MT5_AVAILABLE = False


class MT5Connector:
    """Manages the lifecycle of the MT5 terminal connection."""

    def __init__(self, settings: MT5Settings) -> None:
        self._settings = settings
        self._connected = False

    # ------------------------------------------------------------------
    # Connection lifecycle
    # ------------------------------------------------------------------

    def connect(self) -> bool:
        """Initialise MT5 and optionally log in."""
        if not MT5_AVAILABLE:
            logger.error("MetaTrader5 package not installed – running in offline mode")
            return False

        init_kwargs: dict = {}
        if self._settings.path:
            init_kwargs["path"] = self._settings.path
        if self._settings.timeout:
            init_kwargs["timeout"] = self._settings.timeout

        if not mt5.initialize(**init_kwargs):
            logger.error(f"MT5 initialize failed: {mt5.last_error()}")
            return False

        if self._settings.login:
            auth = mt5.login(
                self._settings.login,
                password=self._settings.password,
                server=self._settings.server,
            )
            if not auth:
                logger.error(f"MT5 login failed: {mt5.last_error()}")
                mt5.shutdown()
                return False

        self._connected = True
        info = mt5.account_info()
        if info:
            logger.info(
                f"Connected to MT5 | account={info.login} "
                f"server={info.server} balance={info.balance}"
            )
        return True

    def disconnect(self) -> None:
        if MT5_AVAILABLE and self._connected:
            mt5.shutdown()
            self._connected = False
            logger.info("MT5 disconnected")

    def ensure_connected(self, retries: int = 3, delay: float = 5.0) -> bool:
        """Re-connect if the connection has dropped."""
        if self._connected and MT5_AVAILABLE:
            # Quick health check
            info = mt5.account_info()
            if info is not None:
                return True
        # Attempt reconnect
        for attempt in range(1, retries + 1):
            logger.warning(f"MT5 reconnect attempt {attempt}/{retries}")
            if self.connect():
                return True
            time.sleep(delay)
        logger.error("MT5 reconnection failed after all retries")
        return False

    @property
    def connected(self) -> bool:
        return self._connected

    # ------------------------------------------------------------------
    # Symbol helpers
    # ------------------------------------------------------------------

    def symbol_exists(self, broker_name: str) -> bool:
        if not MT5_AVAILABLE:
            return False
        info = mt5.symbol_info(broker_name)
        return info is not None

    def enable_symbol(self, broker_name: str) -> bool:
        """Make sure the symbol is visible in Market Watch."""
        if not MT5_AVAILABLE:
            return False
        if not mt5.symbol_select(broker_name, True):
            logger.warning(f"Could not enable symbol {broker_name}")
            return False
        return True

    # ------------------------------------------------------------------
    # Account info
    # ------------------------------------------------------------------

    def account_balance(self) -> float:
        if not MT5_AVAILABLE:
            return 0.0
        info = mt5.account_info()
        return info.balance if info else 0.0

    def account_equity(self) -> float:
        if not MT5_AVAILABLE:
            return 0.0
        info = mt5.account_info()
        return info.equity if info else 0.0

    def account_info_dict(self) -> dict:
        if not MT5_AVAILABLE:
            return {}
        info = mt5.account_info()
        if not info:
            return {}
        return info._asdict()
