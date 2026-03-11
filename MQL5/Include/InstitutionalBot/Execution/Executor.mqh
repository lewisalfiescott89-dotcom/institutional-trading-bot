//+------------------------------------------------------------------+
//| Executor.mqh - Trade execution (dry-run and live)                |
//| Places orders via MQL5 Trade class, verifies results             |
//+------------------------------------------------------------------+
#ifndef EXECUTOR_MQH
#define EXECUTOR_MQH

#include <Trade/Trade.mqh>
#include "../Models/Trade.mqh"
#include "../Models/Signal.mqh"
#include "../Core/Logger.mqh"
#include "../Config.mqh"

class CExecutor
{
private:
   CTrade  m_trade;
   bool    m_dry_run;
   int     m_slippage;
   int     m_next_trade_id;

public:
   CExecutor(bool dry_run = true, int slippage = 10)
      : m_dry_run(dry_run), m_slippage(slippage), m_next_trade_id(1)
   {
      m_trade.SetDeviationInPoints(slippage);
      m_trade.SetTypeFilling(ORDER_FILLING_IOC);
   }

   void SetDryRun(bool dry_run) { m_dry_run = dry_run; }
   bool IsDryRun()              { return m_dry_run; }

   //--- Execute a trade from signal data
   bool Execute(const SignalData &signal, string symbol,
                double lot_size, double sl_price, double tp_price,
                TradeData &trade_result)
   {
      trade_result.Init();
      trade_result.id         = m_next_trade_id++;
      trade_result.symbol     = symbol;
      trade_result.lot_size   = lot_size;
      trade_result.sl_price   = sl_price;
      trade_result.tp_price   = tp_price;
      trade_result.grade      = GradeToString(signal.grade);
      trade_result.setup_score= signal.total_score;
      trade_result.open_time  = TimeCurrent();

      if(signal.direction == SIGNAL_BUY)
         trade_result.direction = TRADE_BUY;
      else
         trade_result.direction = TRADE_SELL;

      if(m_dry_run)
         return ExecuteDryRun(trade_result);
      else
         return ExecuteLive(trade_result);
   }

private:
   bool ExecuteDryRun(TradeData &trade)
   {
      // Simulate fill at current market price
      if(trade.direction == TRADE_BUY)
         trade.entry_price = SymbolInfoDouble(trade.symbol, SYMBOL_ASK);
      else
         trade.entry_price = SymbolInfoDouble(trade.symbol, SYMBOL_BID);

      if(trade.entry_price <= 0)
      {
         // Fallback: use last close
         double closes[];
         ArraySetAsSeries(closes, false);
         int copied = CopyClose(trade.symbol, PERIOD_M5, 0, 1, closes);
         if(copied > 0)
            trade.entry_price = closes[0];
         else
         {
            LogMessage(LOG_ERROR, "EXECUTOR", "Cannot get price for " + trade.symbol);
            return false;
         }
      }

      trade.status   = STATUS_OPEN;
      trade.ticket   = -trade.id;  // Negative ticket = dry run
      trade.is_dry_run = true;

      LogTrade(trade.symbol, "DRY_RUN_OPEN",
         StringFormat("%s %.2f lots @ %.5f SL=%.5f TP=%.5f Grade=%s Score=%.1f",
            (trade.direction == TRADE_BUY) ? "BUY" : "SELL",
            trade.lot_size, trade.entry_price,
            trade.sl_price, trade.tp_price,
            trade.grade, trade.setup_score));
      return true;
   }

   bool ExecuteLive(TradeData &trade)
   {
      bool success = false;

      // Normalise prices
      int digits = (int)SymbolInfoInteger(trade.symbol, SYMBOL_DIGITS);
      double entry = 0;
      double sl = NormalizeDouble(trade.sl_price, digits);
      double tp = NormalizeDouble(trade.tp_price, digits);

      if(trade.direction == TRADE_BUY)
      {
         entry = SymbolInfoDouble(trade.symbol, SYMBOL_ASK);
         entry = NormalizeDouble(entry, digits);
         success = m_trade.Buy(trade.lot_size, trade.symbol, entry, sl, tp,
                               "InstitutionalBot");
      }
      else
      {
         entry = SymbolInfoDouble(trade.symbol, SYMBOL_BID);
         entry = NormalizeDouble(entry, digits);
         success = m_trade.Sell(trade.lot_size, trade.symbol, entry, sl, tp,
                                "InstitutionalBot");
      }

      if(success)
      {
         trade.entry_price = entry;
         trade.status      = STATUS_OPEN;
         trade.ticket      = (long)m_trade.ResultOrder();
         trade.is_dry_run  = false;

         // Verify the order result
         uint retcode = m_trade.ResultRetcode();
         if(retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_PLACED)
         {
            LogMessage(LOG_ERROR, "EXECUTOR",
               StringFormat("Order placed but retcode=%d: %s",
                  retcode, m_trade.ResultRetcodeDescription()));
         }

         LogTrade(trade.symbol, "LIVE_OPEN",
            StringFormat("%s %.2f lots @ %.5f SL=%.5f TP=%.5f Ticket=%d",
               (trade.direction == TRADE_BUY) ? "BUY" : "SELL",
               trade.lot_size, trade.entry_price,
               trade.sl_price, trade.tp_price, trade.ticket));
      }
      else
      {
         uint retcode = m_trade.ResultRetcode();
         LogMessage(LOG_ERROR, "EXECUTOR",
            StringFormat("Order FAILED: %s (retcode=%d)",
               m_trade.ResultRetcodeDescription(), retcode));
         trade.status = STATUS_CANCELLED;
      }

      return success;
   }
};

#endif
