"""
Backtesting metrics – calculates performance statistics from a list of trades.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List

from models.trade import Trade, TradeStatus


@dataclass
class PerformanceMetrics:
    """Summary statistics for a backtest run."""

    total_trades: int = 0
    wins: int = 0
    losses: int = 0
    breakeven: int = 0
    win_rate: float = 0.0
    profit_factor: float = 0.0
    gross_profit: float = 0.0
    gross_loss: float = 0.0
    total_commission: float = 0.0
    net_profit: float = 0.0
    max_drawdown: float = 0.0
    max_drawdown_pct: float = 0.0
    average_r: float = 0.0
    best_trade: float = 0.0
    worst_trade: float = 0.0
    avg_win: float = 0.0
    avg_loss: float = 0.0
    max_consecutive_wins: int = 0
    max_consecutive_losses: int = 0

    def summary(self) -> str:
        return (
            f"=== Backtest Performance ===\n"
            f"Total Trades:          {self.total_trades}\n"
            f"Wins / Losses / BE:    {self.wins} / {self.losses} / {self.breakeven}\n"
            f"Win Rate:              {self.win_rate:.1f}%\n"
            f"Profit Factor:         {self.profit_factor:.2f}\n"
            f"Net Profit:            ${self.net_profit:,.2f}\n"
            f"Total Commission:      ${self.total_commission:,.2f}\n"
            f"Max Drawdown:          ${self.max_drawdown:,.2f} ({self.max_drawdown_pct:.1f}%)\n"
            f"Average R:             {self.average_r:.2f}\n"
            f"Best Trade:            ${self.best_trade:,.2f}\n"
            f"Worst Trade:           ${self.worst_trade:,.2f}\n"
            f"Avg Win / Avg Loss:    ${self.avg_win:,.2f} / ${self.avg_loss:,.2f}\n"
            f"Max Consec Wins:       {self.max_consecutive_wins}\n"
            f"Max Consec Losses:     {self.max_consecutive_losses}\n"
        )


def compute_metrics(
    trades: List[Trade],
    initial_balance: float = 100_000.0,
) -> PerformanceMetrics:
    """
    Compute full performance metrics from a list of closed trades.
    """
    m = PerformanceMetrics()
    if not trades:
        return m

    m.total_trades = len(trades)

    wins_pnl: List[float] = []
    losses_pnl: List[float] = []
    r_values: List[float] = []

    for t in trades:
        m.total_commission += t.commission
        if t.status == TradeStatus.CLOSED_WIN:
            m.wins += 1
            wins_pnl.append(t.net_pnl)
        elif t.status == TradeStatus.CLOSED_LOSS:
            m.losses += 1
            losses_pnl.append(t.net_pnl)
        else:
            m.breakeven += 1
        r_values.append(t.r_multiple)

    m.gross_profit = sum(wins_pnl) if wins_pnl else 0.0
    m.gross_loss = abs(sum(losses_pnl)) if losses_pnl else 0.0
    m.net_profit = m.gross_profit - m.gross_loss
    m.win_rate = (m.wins / m.total_trades * 100.0) if m.total_trades > 0 else 0.0
    m.profit_factor = (m.gross_profit / m.gross_loss) if m.gross_loss > 0 else float("inf")
    m.average_r = sum(r_values) / len(r_values) if r_values else 0.0
    m.avg_win = sum(wins_pnl) / len(wins_pnl) if wins_pnl else 0.0
    m.avg_loss = sum(losses_pnl) / len(losses_pnl) if losses_pnl else 0.0
    m.best_trade = max(t.net_pnl for t in trades) if trades else 0.0
    m.worst_trade = min(t.net_pnl for t in trades) if trades else 0.0

    # Drawdown
    equity = initial_balance
    peak = equity
    max_dd = 0.0
    max_dd_pct = 0.0
    for t in trades:
        equity += t.net_pnl
        if equity > peak:
            peak = equity
        dd = peak - equity
        dd_pct = (dd / peak * 100.0) if peak > 0 else 0.0
        if dd > max_dd:
            max_dd = dd
            max_dd_pct = dd_pct
    m.max_drawdown = max_dd
    m.max_drawdown_pct = max_dd_pct

    # Consecutive wins/losses
    consec_w = 0
    consec_l = 0
    for t in trades:
        if t.status == TradeStatus.CLOSED_WIN:
            consec_w += 1
            consec_l = 0
        elif t.status == TradeStatus.CLOSED_LOSS:
            consec_l += 1
            consec_w = 0
        m.max_consecutive_wins = max(m.max_consecutive_wins, consec_w)
        m.max_consecutive_losses = max(m.max_consecutive_losses, consec_l)

    return m
