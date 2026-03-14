//+------------------------------------------------------------------+
//| PositionSizer.mqh - Calculate lot size from risk parameters      |
//| Accounts for SL distance, account equity, and symbol specs       |
//+------------------------------------------------------------------+
#ifndef POSITION_SIZER_MQH
#define POSITION_SIZER_MQH

#include "../Config.mqh"

struct SizeResult
{
   double lot_size;
   double risk_amount;
   double sl_distance;
   double pip_value;
   string description;

   void Init()
   {
      lot_size    = 0;
      risk_amount = 0;
      sl_distance = 0;
      pip_value   = 0;
      description = "";
   }
};

class CPositionSizer
{
private:
   double m_default_sl_pips;
   double m_min_lot;
   double m_max_lot;
   double m_lot_step;

public:
   CPositionSizer(double default_sl=30, double min_lot=0.01,
                  double max_lot=100.0, double lot_step=0.01)
      : m_default_sl_pips(default_sl), m_min_lot(min_lot),
        m_max_lot(max_lot), m_lot_step(lot_step) {}

   //--- Calculate position size
   void Calculate(string symbol, double equity, double risk_pct,
                  double entry_price, double sl_price, SizeResult &result)
   {
      result.Init();

      SymbolSpec spec = GetSymbolSpec(symbol);

      // Risk amount in account currency
      result.risk_amount = equity * risk_pct / 100.0;

      // SL distance in price
      result.sl_distance = MathAbs(entry_price - sl_price);
      if(result.sl_distance == 0)
         result.sl_distance = m_default_sl_pips * spec.pip_size;

      // SL distance in pips
      double sl_pips = result.sl_distance / spec.pip_size;
      if(sl_pips <= 0) sl_pips = m_default_sl_pips;

      // Get pip value from MT5
      double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double min_volume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double max_volume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      double vol_step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

      // Use MT5 values if available, otherwise use spec defaults
      if(tick_size > 0 && tick_value > 0)
      {
         result.pip_value = (spec.pip_size / tick_size) * tick_value;
      }
      else
      {
         // Fallback: estimate pip value
         result.pip_value = spec.contract_size * spec.pip_size;
      }

      if(result.pip_value <= 0)
      {
         result.lot_size = m_min_lot;
         result.description = "Fallback to min lot (pip value unknown)";
         return;
      }

      // Lot size = risk_amount / (sl_pips * pip_value_per_lot)
      double raw_lots = result.risk_amount / (sl_pips * result.pip_value);

      // Apply MT5 constraints (use local vars to avoid mutating member state)
      double eff_min_lot = (min_volume > 0) ? min_volume : m_min_lot;
      double eff_max_lot = (max_volume > 0) ? max_volume : m_max_lot;
      double eff_lot_step = (vol_step > 0) ? vol_step : m_lot_step;

      // Round to lot step
      if(eff_lot_step > 0)
         raw_lots = MathFloor(raw_lots / eff_lot_step) * eff_lot_step;

      // Clamp
      result.lot_size = MathMax(eff_min_lot, MathMin(raw_lots, eff_max_lot));
      result.lot_size = NormalizeDouble(result.lot_size, 2);

      result.description = StringFormat("Equity=%.2f Risk=%.2f%% SL=%.1f pips Lots=%.2f",
                                         equity, risk_pct, sl_pips, result.lot_size);
   }

   //--- Calculate SL price from default pips
   double DefaultSLPrice(string symbol, double entry_price, bool is_buy)
   {
      SymbolSpec spec = GetSymbolSpec(symbol);
      double sl_dist = m_default_sl_pips * spec.pip_size;
      if(is_buy)
         return entry_price - sl_dist;
      else
         return entry_price + sl_dist;
   }

   //--- Calculate TP price from nearest liquidity
   double TPFromLiquidity(double entry_price, double liquidity_price, bool is_buy)
   {
      if(is_buy && liquidity_price > entry_price)
         return liquidity_price;
      else if(!is_buy && liquidity_price < entry_price)
         return liquidity_price;
      return 0;  // No valid TP
   }
};

#endif
