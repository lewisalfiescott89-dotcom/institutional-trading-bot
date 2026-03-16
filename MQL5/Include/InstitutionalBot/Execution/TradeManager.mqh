//+------------------------------------------------------------------+
//| TradeManager.mqh - Trade lifecycle management                    |
//| SL/TP management, PnL accounting, R-multiple tracking            |
//+------------------------------------------------------------------+
#ifndef TRADE_MANAGER_MQH
#define TRADE_MANAGER_MQH

#include <Trade/Trade.mqh>
#include "../Models/Trade.mqh"
#include "../Models/State.mqh"
#include "../Risk/CommissionEngine.mqh"
#include "../Core/Logger.mqh"
#include "../Config.mqh"

class CTradeManager
{
private:
   CCommissionEngine m_commission;
   CTrade            m_trade;
   bool              m_dry_run;

public:
   CTradeManager() : m_dry_run(true)
   {
      m_trade.SetDeviationInPoints(10);
      m_trade.SetTypeFilling(ORDER_FILLING_IOC);
   }
   void SetCommissionEngine(const CommissionSettings &cfg) { m_commission.SetConfig(cfg); }
   void SetDryRun(bool dry_run) { m_dry_run = dry_run; }

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

      // In live/backtest mode, check if MT5 already closed this position
      // (e.g. SL/TP hit between ticks). If position gone, sync our state.
      if(!m_dry_run && trade.ticket > 0)
      {
         if(!PositionSelectByTicket(trade.ticket))
         {
            // Position was closed by MT5 (SL/TP hit or manual close)
            // Use current price as approximate close price
            CloseTrade(trade, current_price, "MT5 Closed");
            return;
         }
      }

      // In dry-run mode, manually check SL/TP
      if(m_dry_run)
      {
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
      }

      // Breakeven: move SL to entry when trade reaches 1.5R profit
      MoveToBreakeven(trade, current_price);

      // Trailing stop: at 2R profit, trail SL to lock in 1R
      TrailingStop(trade, current_price);

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

      // R-multiple (use original SL distance, not current which may be at breakeven)
      double risk_dist = trade.OriginalRiskDistance();
      if(risk_dist <= 0) risk_dist = trade.RiskDistance();  // fallback
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
   //--- Move SL to breakeven when trade reaches 1.5R profit
   void MoveToBreakeven(TradeData &trade, double current_price)
   {
      if(trade.sl_price <= 0 || trade.entry_price <= 0) return;

      // Use original risk distance so this works correctly even if SL was already moved
      double risk_dist = trade.OriginalRiskDistance();
      if(risk_dist <= 0) risk_dist = trade.RiskDistance();  // fallback
      if(risk_dist <= 0) return;

      if(trade.direction == TRADE_BUY)
      {
         // Already at or past breakeven?
         if(trade.sl_price >= trade.entry_price) return;
         // Price moved 1.5R in our favor?
         if(current_price >= trade.entry_price + risk_dist * 1.5)
         {
            double new_sl = trade.entry_price;
            trade.sl_price = new_sl;
            ModifyPositionSL(trade, new_sl);
            LogMessage(LOG_INFO, "TRADEMGR",
               StringFormat("%s BUY #%d SL moved to breakeven @ %.5f",
                  trade.symbol, trade.id, new_sl));
         }
      }
      else // SELL
      {
         // Already at or past breakeven?
         if(trade.sl_price <= trade.entry_price) return;
         // Price moved 1.5R in our favor?
         if(current_price <= trade.entry_price - risk_dist * 1.5)
         {
            double new_sl = trade.entry_price;
            trade.sl_price = new_sl;
            ModifyPositionSL(trade, new_sl);
            LogMessage(LOG_INFO, "TRADEMGR",
               StringFormat("%s SELL #%d SL moved to breakeven @ %.5f",
                  trade.symbol, trade.id, new_sl));
         }
      }
   }

   //--- Trailing stop: at 2R profit, trail SL to lock in 1R
   void TrailingStop(TradeData &trade, double current_price)
   {
      if(trade.entry_price <= 0) return;

      // Use original risk distance — after breakeven, RiskDistance() returns 0
      double risk_dist = trade.OriginalRiskDistance();
      if(risk_dist <= 0) return;

      if(trade.direction == TRADE_BUY)
      {
         // Only trail after breakeven
         if(trade.sl_price < trade.entry_price) return;
         // At 2R+, trail SL to (current_price - 1R)
         double profit_dist = current_price - trade.entry_price;
         if(profit_dist >= risk_dist * 2.0)
         {
            double new_sl = current_price - risk_dist;
            if(new_sl > trade.sl_price)
            {
               trade.sl_price = new_sl;
               ModifyPositionSL(trade, new_sl);
               LogMessage(LOG_INFO, "TRADEMGR",
                  StringFormat("%s BUY #%d trailing SL to %.5f (locking %.1fR)",
                     trade.symbol, trade.id, new_sl,
                     (new_sl - trade.entry_price) / risk_dist));
            }
         }
      }
      else // SELL
      {
         if(trade.sl_price > trade.entry_price) return;
         double profit_dist = trade.entry_price - current_price;
         if(profit_dist >= risk_dist * 2.0)
         {
            double new_sl = current_price + risk_dist;
            if(new_sl < trade.sl_price)
            {
               trade.sl_price = new_sl;
               ModifyPositionSL(trade, new_sl);
               LogMessage(LOG_INFO, "TRADEMGR",
                  StringFormat("%s SELL #%d trailing SL to %.5f (locking %.1fR)",
                     trade.symbol, trade.id, new_sl,
                     (trade.entry_price - new_sl) / risk_dist));
            }
         }
      }
   }

   //--- Modify the actual MT5 position SL (for live/backtest mode)
   void ModifyPositionSL(const TradeData &trade, double new_sl)
   {
      if(m_dry_run || trade.ticket <= 0) return;

      int digits = (int)SymbolInfoInteger(trade.symbol, SYMBOL_DIGITS);
      new_sl = NormalizeDouble(new_sl, digits);
      double tp = NormalizeDouble(trade.tp_price, digits);

      if(!m_trade.PositionModify(trade.ticket, new_sl, tp))
      {
         LogMessage(LOG_WARNING, "TRADEMGR",
            StringFormat("Failed to modify SL for ticket %d: %s",
               trade.ticket, m_trade.ResultRetcodeDescription()));
      }
   }

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
