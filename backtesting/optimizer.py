"""
Parameter Optimizer – sweeps strategy parameters to find optimal settings
with walk-forward evaluation support.
"""

from __future__ import annotations

import copy
import itertools
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

import pandas as pd

from config.settings import BotConfig
from backtesting.backtester import Backtester
from backtesting.metrics import PerformanceMetrics
from core.logger import get_logger

logger = get_logger("optimizer")


@dataclass
class ParamRange:
    """Defines a parameter to sweep."""
    name: str               # dot-separated path, e.g. "poi.displacement_multiplier"
    values: List[Any] = field(default_factory=list)


@dataclass
class OptResult:
    """Result of a single parameter combination."""
    params: Dict[str, Any] = field(default_factory=dict)
    train_metrics: Optional[PerformanceMetrics] = None
    test_metrics: Optional[PerformanceMetrics] = None
    combined_score: float = 0.0

    def summary_line(self) -> str:
        tm = self.train_metrics
        ts = self.test_metrics
        return (
            f"score={self.combined_score:.2f} | "
            f"train: PF={tm.profit_factor:.2f} WR={tm.win_rate:.1f}% DD={tm.max_drawdown_pct:.1f}% | "
            f"test: PF={ts.profit_factor:.2f} WR={ts.win_rate:.1f}% DD={ts.max_drawdown_pct:.1f}% | "
            f"params={self.params}"
            if tm and ts else f"params={self.params}"
        )


class Optimizer:
    """
    Brute-force parameter optimizer with train/test split.

    Usage:
        opt = Optimizer(base_config, tf_data)
        opt.add_param("poi.displacement_multiplier", [1.0, 1.5, 2.0])
        opt.add_param("sweep.min_penetration_pips", [0.5, 1.0, 2.0])
        results = opt.run("XAUUSD")
    """

    def __init__(
        self,
        base_config: BotConfig,
        tf_data: Dict[str, pd.DataFrame],
    ) -> None:
        self.base_cfg = base_config
        self.tf_data = tf_data
        self.params: List[ParamRange] = []

    def add_param(self, name: str, values: List[Any]) -> None:
        """Add a parameter range to sweep."""
        self.params.append(ParamRange(name=name, values=values))

    def run(self, symbol: str, warmup_bars: int = 200) -> List[OptResult]:
        """
        Run all parameter combinations with train/test split.

        Returns results sorted by combined_score descending.
        """
        if not self.params:
            logger.warning("No parameters to optimize")
            return []

        # Generate all combinations
        names = [p.name for p in self.params]
        value_lists = [p.values for p in self.params]
        combos = list(itertools.product(*value_lists))

        logger.info(f"Optimizing {len(combos)} parameter combinations for {symbol}")

        # Split data
        df5 = self.tf_data.get("M5")
        if df5 is None or df5.empty:
            logger.error("No M5 data for optimization")
            return []

        split_idx = int(len(df5) * self.base_cfg.backtest.train_pct)
        train_data = {k: v.iloc[:split_idx].copy() if k == "M5" else v.copy()
                      for k, v in self.tf_data.items()}
        test_data = {k: v.iloc[split_idx:].reset_index(drop=True).copy() if k == "M5" else v.copy()
                     for k, v in self.tf_data.items()}

        results: List[OptResult] = []

        for i, combo in enumerate(combos):
            param_dict = dict(zip(names, combo))
            cfg = self._apply_params(param_dict)

            # Train
            bt_train = Backtester(cfg)
            bt_train.load_data(train_data)
            train_m = bt_train.run(symbol, warmup_bars)

            # Test
            bt_test = Backtester(cfg)
            bt_test.load_data(test_data)
            test_m = bt_test.run(symbol, warmup_bars)

            score = self._combined_score(train_m, test_m)

            result = OptResult(
                params=param_dict,
                train_metrics=train_m,
                test_metrics=test_m,
                combined_score=score,
            )
            results.append(result)

            if (i + 1) % 10 == 0:
                logger.info(f"Completed {i + 1}/{len(combos)} combinations")

        # Sort by score
        results.sort(key=lambda r: r.combined_score, reverse=True)

        logger.info("=== Top 5 Results ===")
        for r in results[:5]:
            logger.info(r.summary_line())

        return results

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _apply_params(self, param_dict: Dict[str, Any]) -> BotConfig:
        """Create a modified config with the given parameters."""
        cfg = copy.deepcopy(self.base_cfg)
        for dotted_name, value in param_dict.items():
            parts = dotted_name.split(".")
            obj = cfg
            for part in parts[:-1]:
                obj = getattr(obj, part)
            setattr(obj, parts[-1], value)
        return cfg

    @staticmethod
    def _combined_score(train: PerformanceMetrics, test: PerformanceMetrics) -> float:
        """
        Score that balances profitability and robustness.

        Penalizes:
        - Large discrepancy between train and test
        - High drawdown
        - Low trade count
        """
        if train.total_trades < 5 or test.total_trades < 3:
            return 0.0

        # Profit factor component (capped)
        pf_train = min(train.profit_factor, 5.0)
        pf_test = min(test.profit_factor, 5.0)

        # Consistency penalty
        pf_diff = abs(pf_train - pf_test)
        consistency = max(0.0, 1.0 - pf_diff / 3.0)

        # Drawdown penalty
        dd_penalty = max(0.0, 1.0 - test.max_drawdown_pct / 30.0)

        # Combined
        score = (pf_test * 2.0 + pf_train * 1.0) * consistency * dd_penalty
        return round(score, 4)
