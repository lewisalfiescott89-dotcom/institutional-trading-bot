"""
Interactive Chart Debugger – visualizes candles, POIs, clusters, FVGs,
liquidity, sweeps, traps, reversals, and trade markers using Plotly.
"""

from __future__ import annotations

from typing import Dict, List, Optional

import pandas as pd

try:
    import plotly.graph_objects as go  # type: ignore
    from plotly.subplots import make_subplots  # type: ignore
    PLOTLY_AVAILABLE = True
except ImportError:
    PLOTLY_AVAILABLE = False

from models.poi import POI, POIDirection
from models.liquidity import LiquidityLevel, LiquiditySide
from models.trade import Trade, TradeDirection
from analysis.fvg_engine import FVG, FVGDirection
from analysis.sweep_engine import SweepEvent
from analysis.trap_engine import TrapEvent
from analysis.reversal_engine import ReversalEvent
from core.logger import get_logger

logger = get_logger("chart_debugger")


class ChartDebugger:
    """
    Builds an interactive Plotly chart for visual strategy debugging.

    Usage:
        dbg = ChartDebugger()
        dbg.set_candles(df5)
        dbg.add_pois(pois)
        dbg.add_liquidity(levels)
        dbg.add_trades(trades)
        dbg.show()           # opens in browser
        dbg.save("debug.html")
    """

    def __init__(self, title: str = "Institutional Bot Debug Chart") -> None:
        if not PLOTLY_AVAILABLE:
            logger.warning("Plotly not installed – chart debugging disabled")
        self.title = title
        self._candles: Optional[pd.DataFrame] = None
        self._pois: List[POI] = []
        self._liquidity: List[LiquidityLevel] = []
        self._fvgs: List[FVG] = []
        self._sweeps: List[SweepEvent] = []
        self._traps: List[TrapEvent] = []
        self._reversals: List[ReversalEvent] = []
        self._trades: List[Trade] = []

    # ------------------------------------------------------------------
    # Data setters
    # ------------------------------------------------------------------

    def set_candles(self, df: pd.DataFrame) -> None:
        self._candles = df

    def add_pois(self, pois: List[POI]) -> None:
        self._pois.extend(pois)

    def add_liquidity(self, levels: List[LiquidityLevel]) -> None:
        self._liquidity.extend(levels)

    def add_fvgs(self, fvgs: List[FVG]) -> None:
        self._fvgs.extend(fvgs)

    def add_sweeps(self, sweeps: List[SweepEvent]) -> None:
        self._sweeps.extend(sweeps)

    def add_traps(self, traps: List[TrapEvent]) -> None:
        self._traps.extend(traps)

    def add_reversals(self, reversals: List[ReversalEvent]) -> None:
        self._reversals.extend(reversals)

    def add_trades(self, trades: List[Trade]) -> None:
        self._trades.extend(trades)

    # ------------------------------------------------------------------
    # Build & render
    # ------------------------------------------------------------------

    def build(self) -> "go.Figure":
        """Build and return the Plotly figure."""
        if not PLOTLY_AVAILABLE:
            raise RuntimeError("Plotly is not installed")

        fig = go.Figure()

        # 1. Candlestick
        if self._candles is not None and not self._candles.empty:
            df = self._candles
            x_axis = df["time"] if "time" in df.columns else df.index
            fig.add_trace(go.Candlestick(
                x=x_axis,
                open=df["open"],
                high=df["high"],
                low=df["low"],
                close=df["close"],
                name="Price",
            ))

        x_vals = self._candles["time"] if self._candles is not None and "time" in self._candles.columns else None

        # 2. POI zones
        for poi in self._pois:
            color = "rgba(255,0,0,0.15)" if poi.direction == POIDirection.BEARISH else "rgba(0,128,0,0.15)"
            border = "red" if poi.direction == POIDirection.BEARISH else "green"
            label = f"{poi.poi_type.value} {poi.direction.value} ({poi.timeframe}) score={poi.score:.1f}"

            if x_vals is not None and len(x_vals) > 0:
                x0 = x_vals.iloc[min(poi.origin_bar_index, len(x_vals) - 1)]
                x1 = x_vals.iloc[-1]
                fig.add_shape(
                    type="rect", x0=x0, x1=x1,
                    y0=poi.zone_low, y1=poi.zone_high,
                    fillcolor=color, line=dict(color=border, width=1),
                )
                fig.add_annotation(
                    x=x0, y=poi.zone_high, text=label,
                    showarrow=False, font=dict(size=9),
                )

        # 3. Liquidity levels
        for lvl in self._liquidity:
            color = "blue" if lvl.side == LiquiditySide.BUY_SIDE else "orange"
            style = "dash" if lvl.swept else "solid"
            if x_vals is not None and len(x_vals) > 0:
                fig.add_hline(
                    y=lvl.price, line_dash=style, line_color=color,
                    annotation_text=f"{lvl.level_type.value}",
                    annotation_font_size=8,
                )

        # 4. FVGs
        for fvg in self._fvgs:
            color = "rgba(0,200,0,0.08)" if fvg.direction == FVGDirection.BULLISH else "rgba(200,0,0,0.08)"
            if x_vals is not None and len(x_vals) > 0:
                x0 = x_vals.iloc[min(fvg.bar_index, len(x_vals) - 1)]
                x1 = x_vals.iloc[min(fvg.bar_index + 20, len(x_vals) - 1)]
                fig.add_shape(
                    type="rect", x0=x0, x1=x1,
                    y0=fvg.gap_low, y1=fvg.gap_high,
                    fillcolor=color, line=dict(width=0),
                )

        # 5. Sweep markers
        for sw in self._sweeps:
            if x_vals is not None and sw.bar_index < len(x_vals):
                marker_color = "red" if sw.direction == "bearish" else "green"
                fig.add_trace(go.Scatter(
                    x=[x_vals.iloc[sw.bar_index]],
                    y=[sw.liquidity_price],
                    mode="markers",
                    marker=dict(symbol="diamond", size=12, color=marker_color),
                    name=f"Sweep {sw.direction}",
                    showlegend=False,
                    hovertext=f"Sweep {sw.sweep_type.value} pen={sw.penetration_pips:.1f}",
                ))

        # 6. Trap markers
        for tr in self._traps:
            if x_vals is not None and tr.bar_index < len(x_vals):
                fig.add_trace(go.Scatter(
                    x=[x_vals.iloc[tr.bar_index]],
                    y=[tr.level_price],
                    mode="markers",
                    marker=dict(symbol="x", size=14, color="purple"),
                    name=f"Trap {tr.trap_type.value}",
                    showlegend=False,
                    hovertext=f"Trap {tr.trap_type.value} str={tr.reversal_strength:.1f}",
                ))

        # 7. Reversal markers
        for rev in self._reversals:
            if x_vals is not None and rev.bar_index < len(x_vals):
                fig.add_trace(go.Scatter(
                    x=[x_vals.iloc[rev.bar_index]],
                    y=[rev.close_price],
                    mode="markers",
                    marker=dict(symbol="star", size=14, color="gold"),
                    name=f"Reversal {rev.reversal_type.value}",
                    showlegend=False,
                    hovertext=f"Reversal {rev.reversal_type.value} q={rev.quality:.1f}",
                ))

        # 8. Trade entries/exits
        for trade in self._trades:
            entry_color = "lime" if trade.direction == TradeDirection.BUY else "red"
            # Entry marker
            fig.add_trace(go.Scatter(
                x=[pd.Timestamp(trade.open_timestamp, unit="s", tz="UTC")] if trade.open_timestamp else [],
                y=[trade.entry_price],
                mode="markers+text",
                marker=dict(symbol="triangle-up" if trade.direction == TradeDirection.BUY else "triangle-down",
                            size=14, color=entry_color),
                text=[f"{trade.grade}"],
                textposition="top center",
                name=f"Entry {trade.direction.value}",
                showlegend=False,
            ))
            # SL line
            if trade.sl_price > 0:
                fig.add_hline(y=trade.sl_price, line_dash="dot", line_color="red",
                              annotation_text="SL", annotation_font_size=8)
            # TP line
            if trade.tp_price > 0:
                fig.add_hline(y=trade.tp_price, line_dash="dot", line_color="green",
                              annotation_text="TP", annotation_font_size=8)

        fig.update_layout(
            title=self.title,
            xaxis_rangeslider_visible=False,
            height=800,
            template="plotly_dark",
        )
        return fig

    def show(self) -> None:
        """Display the chart in the default browser."""
        fig = self.build()
        fig.show()

    def save(self, path: str = "debug_chart.html") -> None:
        """Save the chart to an HTML file."""
        fig = self.build()
        fig.write_html(path)
        logger.info(f"Debug chart saved to {path}")
