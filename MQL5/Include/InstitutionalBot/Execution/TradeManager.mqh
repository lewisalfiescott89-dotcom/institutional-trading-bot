//+------------------------------------------------------------------+
//| TradeManager.mqh - Trade lifecycle management                    |
//| SL/TP management, PnL accounting, R-multiple tracking            |
//+------------------------------------------------------------------+
#ifndef TRADE_MANAGER_MQH
#define TRADE_MANAGER_MQH

#include "../Models/Trade.mqh"
#include "../Models/State.mqh"
#include "../Risk/CommissionEngine.mqh"
#include "../Core/Logger.mqh"
#include "../Config.mqh"

class CTradeManager
{
private:
   CCommissionEngine m_commission;

public:
   CTradeManager() {}
   void SetCommissionEngine(const CommissionSettings &cfg) { m_commission.SetConfig(cfg); }

   //--- Update all open trades for a symbol
   void UpdateTrades(SymbolState &state, double current_bid, double current_ask)
   {
      for(int i = 0; i < state.open_trade_count; i++)
      {
         if(!state.open_trades[i].IsOpen()) continue;
         UpdateSingleTrade(state.open_trades[i], current_bid, current_ask);
      }

      // Move closed trades to recent_closed
      int j = 0;
      for(int i = 0; i < state.open_trade_count; i++)
      {
         if(state.open_trades[i].IsOpen())
         {
            if(j != i) state.open_trades[j] = state.open_trades[i];
            j++;
         }
         else
         {
            // Add to recent closed
            if(state.recent_closed_count < MAX_TRADES)
            {
               state.recent_closed[state.recent_closed_count] = state.open_trades[i];
               state.recent_closed_count++;
            }
         }
      }
      state.open_trade_count = j;
   }

   //--- Update a single trade
   void UpdateSingleTrade(TradeData &trade, double bid, double ask)
   {
      if(!trade.IsOpen()) return;

      double current_price = (trade.direction == TRADE_BUY) ? bid : ask;

      // Check SL hit
      if(trade.direction == TRADE_BUY)
      {
         if(bid <= trade.sl_price && trade.sl_price > 0)
         {
            CloseTrade(trade, trade.sl_price, "SL Hit");
            return;
         }
         if(trade.tp_price > 0 && bid >= trade.tp_price)
         {
            CloseTrade(trade, trade.tp_price, "TP Hit");
            return;
         }
      }
      else // SELL
      {
         if(ask >= trade.sl_price && trade.sl_price > 0)
         {
            CloseTrade(trade, trade.sl_price, "SL Hit");
            return;
         }
         if(trade.tp_price > 0 && ask <= trade.tp_price)
         {
            CloseTrade(trade, trade.tp_price, "TP Hit");
            return;
         }
      }

      // Update floating PnL
      UpdateFloatingPnL(trade, current_price);
   }

   //--- Close a trade at a specific price
   void CloseTrade(TradeData &trade, double close_price, string reason)
   {
      trade.close_price = close_price;
      trade.close_time  = TimeCurrent();

      // Calculate gross PnL
      SymbolSpec spec = GetSymbolSpec(trade.symbol);
      double pip_diff = 0;
      if(trade.direction == TRADE_BUY)
         pip_diff = (close_price - trade.entry_price) / spec.pip_size;
      else
         pip_diff = (trade.entry_price - close_price) / spec.pip_size;

      // Pip value
      double tick_size  = SymbolInfoDouble(trade.symbol, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(trade.symbol, SYMBOL_TRADE_TICK_VALUE);
      double pip_value  = 0;
      if(tick_size > 0 && tick_value > 0)
         pip_value = (spec.pip_size / tick_size) * tick_value;
      else
         pip_value = spec.contract_size * spec.pip_size;

      trade.gross_pnl = pip_diff * pip_value * trade.lot_size;

      // Commission
      trade.commission = m_commission.Calculate(trade.symbol, trade.lot_size, trade.entry_price);

      // Net PnL
      trade.net_pnl = trade.gross_pnl - trade.commission;

      // R-multiple
      double risk_dist = trade.RiskDistance();
      if(risk_dist > 0)
      {
         double risk_pips = risk_dist / spec.pip_size;
         trade.r_multiple = pip_diff / risk_pips;
      }

      // Status
      if(trade.net_pnl > 0)
         trade.status = STATUS_CLOSED_WIN;
      else if(trade.net_pnl < 0)
         trade.status = STATUS_CLOSED_LOSS;
      else
         trade.status = STATUS_CLOSED_BE;

      LogTrade(trade.symbol, "CLOSE",
         StringFormat("%s | PnL=%.2f Comm=%.2f Net=%.2f R=%.2fR | %s",
            (trade.direction == TRADE_BUY) ? "BUY" : "SELL",
            trade.gross_pnl, trade.commission, trade.net_pnl,
            trade.r_multiple, reason));
   }

   //--- Update global risk state from trade results
   void UpdateRiskState(const SymbolState &states[], int symbol_count,
                        GlobalRiskState &risk)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > risk.peak_equity)
         risk.peak_equity = equity;

      // Calculate daily stats from recent closed trades
      risk.daily_drawdown = (risk.peak_equity > 0) ?
         (risk.peak_equity - equity) / risk.peak_equity * 100.0 : 0;
   }

private:
   void UpdateFloatingPnL(TradeData &trade, double current_price)
   {
      SymbolSpec spec = GetSymbolSpec(trade.symbol);
      double pip_diff = 0;
      if(trade.direction == TRADE_BUY)
         pip_diff = (current_price - trade.entry_price) / spec.pip_size;
      else
         pip_diff = (trade.entry_price - current_price) / spec.pip_size;

      double tick_size  = SymbolInfoDouble(trade.symbol, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(trade.symbol, SYMBOL_TRADE_TICK_VALUE);
      double pip_value  = 0;
      if(tick_size > 0 && tick_value > 0)
         pip_value = (spec.pip_size / tick_size) * tick_value;
      else
         pip_value = spec.contract_size * spec.pip_size;

      trade.gross_pnl = pip_diff * pip_value * trade.lot_size;
   }
};

#endif
