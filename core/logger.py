"""
Structured logging for the institutional trading bot.

Provides both console (human-readable) and file output with contextual fields
like symbol, POI, grade, etc.
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path
from typing import Any, Dict, Optional


_LOGGERS: Dict[str, logging.Logger] = {}


def _build_formatter() -> logging.Formatter:
    return logging.Formatter(
        fmt="%(asctime)s | %(levelname)-7s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )


def get_logger(
    name: str,
    log_file: Optional[str] = None,
    level: int = logging.DEBUG,
) -> logging.Logger:
    """Return (or create) a named logger with console + optional file output."""
    if name in _LOGGERS:
        return _LOGGERS[name]

    logger = logging.getLogger(name)
    logger.setLevel(level)
    logger.propagate = False

    fmt = _build_formatter()

    # Console handler
    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(level)
    ch.setFormatter(fmt)
    logger.addHandler(ch)

    # File handler
    if log_file:
        fh = logging.FileHandler(log_file, encoding="utf-8")
        fh.setLevel(level)
        fh.setFormatter(fmt)
        logger.addHandler(fh)

    _LOGGERS[name] = logger
    return logger


def log_trade_context(
    logger: logging.Logger,
    symbol: str,
    **fields: Any,
) -> None:
    """
    Emit a structured context line for a trade cycle.

    Example output:
        XAUUSD | poi=H4_supply_2930 | liq_target=2945.5 | timing=london_kz |
        sweep=wick | reversal=bearish_engulfing | score=82.5 | grade=A |
        risk=1.00% | action=EXECUTE_SELL
    """
    parts = [symbol]
    for k, v in fields.items():
        parts.append(f"{k}={v}")
    logger.info(" | ".join(parts))


def log_safety_block(
    logger: logging.Logger,
    symbol: str,
    reason: str,
) -> None:
    """Log when a safety check vetoes a trade."""
    logger.warning(f"SAFETY VETO | {symbol} | {reason}")


def log_error(
    logger: logging.Logger,
    symbol: str,
    error: Exception,
    context: str = "",
) -> None:
    """Log an error with optional context."""
    logger.error(f"ERROR | {symbol} | {context} | {type(error).__name__}: {error}")
