//+------------------------------------------------------------------+
//| SafetyEngine.mqh - Pre-trade safety checks (hard veto)           |
//| Spread, slippage, volatility, connection, drawdown protection    |
//+------------------------------------------------------------------+
#ifndef SAFETY_ENGINE_MQH
#define SAFETY_ENGINE_MQH

#include "../Config.mqh"
#include "../Core/Logger.mqh"
#include "../Models/State.mqh"

struct SafetyCheckResult
{
   bool   passed;
   string veto_reason;
   double current_spread;
   double max_spread;
   bool   connection_ok;

   void Init()
   {
      passed         = true;
      veto_reason    = "";
      current_spread = 0;
      max_spread     = 0;
      connection_ok  = true;
   }
};

class CSafetyEngine
{
private:
   SafetySettings m_cfg;

public:
   CSafetyEngine() { m_cfg.Init(); }
   void SetConfig(const SafetySettings &cfg) { m_cfg = cfg; }

   //--- Run all safety checks before trade
   void Check(string symbol, const GlobalRiskState &risk_state,
              SafetyCheckResult &result)
   {
      result.Init();

      // 1. Connection check
      if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      {
         result.passed      = false;
         result.connection_ok = false;
         result.veto_reason = "Terminal not connected";
         LogSafetyBlock(symbol, result.veto_reason);
         return;
      }

      // 2. Trade allowed check
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      {
         result.passed      = false;
         result.veto_reason = "Trading not allowed in terminal";
         LogSafetyBlock(symbol, result.veto_reason);
         return;
      }

      // 3. Symbol trade mode check
      long trade_mode = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
      if(trade_mode == SYMBOL_TRADE_MODE_DISABLED)
      {
         result.passed      = false;
         result.veto_reason = "Symbol trading disabled";
         LogSafetyBlock(symbol, result.veto_reason);
         return;
      }

      // 4. Spread check
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      SymbolSpec spec = GetSymbolSpec(symbol);

      if(ask > 0 && bid > 0)
      {
         result.current_spread = (ask - bid) / spec.pip_size;
         result.max_spread     = m_cfg.max_spread_pips;

         if(result.current_spread > m_cfg.max_spread_pips)
         {
            result.passed      = false;
            result.veto_reason = StringFormat("Spread too wide: %.1f pips (max %.1f)",
                                              result.current_spread, m_cfg.max_spread_pips);
            LogSafetyBlock(symbol, result.veto_reason);
            return;
         }
      }

      // 5. Volatility check (via ATR proxy using recent bars)
      double high_arr[], low_arr[], close_arr[];
      ArraySetAsSeries(high_arr, false);
      ArraySetAsSeries(low_arr, false);
      ArraySetAsSeries(close_arr, false);
      int copied = CopyHigh(symbol, PERIOD_M5, 0, 20, high_arr);
      if(copied >= 20)
      {
         CopyLow(symbol, PERIOD_M5, 0, 20, low_arr);
         CopyClose(symbol, PERIOD_M5, 0, 20, close_arr);
         double atr = ComputeATR(high_arr, low_arr, close_arr, 14, 20);
         double atr_pips = atr / spec.pip_size;

         if(atr_pips > m_cfg.max_volatility_atr_pips)
         {
            result.passed      = false;
            result.veto_reason = StringFormat("Volatility too high: ATR=%.1f pips (max %.1f)",
                                              atr_pips, m_cfg.max_volatility_atr_pips);
            LogSafetyBlock(symbol, result.veto_reason);
            return;
         }
      }

      // 6. Daily drawdown protection
      // Skip if no trades have been placed today — drawdown from trading
      // is impossible with 0 trades (prevents false positives from
      // AccountInfoDouble returning real account values during backtesting)
      if(risk_state.total_trades_today > 0 &&
         risk_state.daily_drawdown > m_cfg.max_daily_drawdown_pct)
      {
         result.passed      = false;
         result.veto_reason = StringFormat("Daily drawdown exceeded: %.2f%% (max %.2f%%)",
                                           risk_state.daily_drawdown, m_cfg.max_daily_drawdown_pct);
         LogSafetyBlock(symbol, result.veto_reason);
         return;
      }

      // 7. Consecutive loss protection
      if(risk_state.consecutive_losses >= m_cfg.max_consecutive_losses)
      {
         result.passed      = false;
         result.veto_reason = StringFormat("Consecutive losses: %d (max %d)",
                                           risk_state.consecutive_losses,
                                           m_cfg.max_consecutive_losses);
         LogSafetyBlock(symbol, result.veto_reason);
         return;
      }

      // 8. Trading paused check
      if(risk_state.trading_paused)
      {
         result.passed      = false;
         result.veto_reason = "Trading paused: " + risk_state.pause_reason;
         LogSafetyBlock(symbol, result.veto_reason);
         return;
      }

      result.passed = true;
   }

   //--- Quick spread-only check
   bool SpreadOK(string symbol)
   {
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      if(ask <= 0 || bid <= 0) return false;
      SymbolSpec spec = GetSymbolSpec(symbol);
      double spread_pips = (ask - bid) / spec.pip_size;
      return spread_pips <= m_cfg.max_spread_pips;
   }
};

#endif
