"""
Plotter – quick utility functions for generating common charts
(equity curve, drawdown, trade distribution, etc.).
"""

from __future__ import annotations

from typing import List, Optional

try:
    import plotly.graph_objects as go  # type: ignore
    PLOTLY_AVAILABLE = True
except ImportError:
    PLOTLY_AVAILABLE = False

from models.trade import Trade, TradeStatus
from backtesting.metrics import PerformanceMetrics


class Plotter:
    """Static utility methods for generating performance charts."""

    @staticmethod
    def equity_curve(
        trades: List[Trade],
        initial_balance: float = 100_000.0,
        title: str = "Equity Curve",
    ) -> "go.Figure":
        """Plot cumulative equity curve from a list of closed trades."""
        if not PLOTLY_AVAILABLE:
            raise RuntimeError("Plotly is not installed")

        equity = [initial_balance]
        for t in trades:
            equity.append(equity[-1] + t.net_pnl)

        fig = go.Figure()
        fig.add_trace(go.Scatter(
            y=equity, mode="lines", name="Equity",
            line=dict(color="cyan", width=2),
        ))
        fig.update_layout(
            title=title, yaxis_title="Equity ($)",
            xaxis_title="Trade #", template="plotly_dark",
        )
        return fig

    @staticmethod
    def drawdown_curve(
        trades: List[Trade],
        initial_balance: float = 100_000.0,
        title: str = "Drawdown Curve",
    ) -> "go.Figure":
        """Plot drawdown percentage over trades."""
        if not PLOTLY_AVAILABLE:
            raise RuntimeError("Plotly is not installed")

        equity = initial_balance
        peak = equity
        dd_pcts: List[float] = []

        for t in trades:
            equity += t.net_pnl
            if equity > peak:
                peak = equity
            dd = (peak - equity) / peak * 100.0 if peak > 0 else 0.0
            dd_pcts.append(dd)

        fig = go.Figure()
        fig.add_trace(go.Scatter(
            y=dd_pcts, mode="lines", name="Drawdown %",
            fill="tozeroy", line=dict(color="red", width=1),
        ))
        fig.update_layout(
            title=title, yaxis_title="Drawdown %",
            xaxis_title="Trade #", template="plotly_dark",
            yaxis=dict(autorange="reversed"),
        )
        return fig

    @staticmethod
    def trade_distribution(
        trades: List[Trade],
        title: str = "Trade PnL Distribution",
    ) -> "go.Figure":
        """Histogram of trade PnL values."""
        if not PLOTLY_AVAILABLE:
            raise RuntimeError("Plotly is not installed")

        pnls = [t.net_pnl for t in trades]
        colors = ["green" if p >= 0 else "red" for p in pnls]

        fig = go.Figure()
        fig.add_trace(go.Histogram(
            x=pnls, nbinsx=40, name="PnL",
            marker_color="cyan",
        ))
        fig.update_layout(
            title=title, xaxis_title="Net PnL ($)",
            yaxis_title="Count", template="plotly_dark",
        )
        return fig

    @staticmethod
    def r_multiple_distribution(
        trades: List[Trade],
        title: str = "R-Multiple Distribution",
    ) -> "go.Figure":
        """Histogram of R-multiple values."""
        if not PLOTLY_AVAILABLE:
            raise RuntimeError("Plotly is not installed")

        r_vals = [t.r_multiple for t in trades]
        fig = go.Figure()
        fig.add_trace(go.Histogram(
            x=r_vals, nbinsx=30, name="R",
            marker_color="gold",
        ))
        fig.update_layout(
            title=title, xaxis_title="R Multiple",
            yaxis_title="Count", template="plotly_dark",
        )
        return fig

    @staticmethod
    def grade_breakdown(
        trades: List[Trade],
        title: str = "Trades by Grade",
    ) -> "go.Figure":
        """Bar chart showing trade count per grade."""
        if not PLOTLY_AVAILABLE:
            raise RuntimeError("Plotly is not installed")

        grades = ["A+", "A", "B", "C", "D"]
        counts = [sum(1 for t in trades if t.grade == g) for g in grades]

        fig = go.Figure()
        fig.add_trace(go.Bar(
            x=grades, y=counts, name="Trades",
            marker_color=["gold", "lime", "cyan", "orange", "red"],
        ))
        fig.update_layout(
            title=title, xaxis_title="Grade",
            yaxis_title="Count", template="plotly_dark",
        )
        return fig

    @staticmethod
    def save_all(
        trades: List[Trade],
        initial_balance: float = 100_000.0,
        prefix: str = "bt",
    ) -> None:
        """Generate and save all charts to HTML files."""
        if not PLOTLY_AVAILABLE:
            return
        Plotter.equity_curve(trades, initial_balance).write_html(f"{prefix}_equity.html")
        Plotter.drawdown_curve(trades, initial_balance).write_html(f"{prefix}_drawdown.html")
        Plotter.trade_distribution(trades).write_html(f"{prefix}_pnl_dist.html")
        Plotter.r_multiple_distribution(trades).write_html(f"{prefix}_r_dist.html")
        Plotter.grade_breakdown(trades).write_html(f"{prefix}_grades.html")
