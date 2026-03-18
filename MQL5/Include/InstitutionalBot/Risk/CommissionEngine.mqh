//+------------------------------------------------------------------+
//| CommissionEngine.mqh - Pepperstone commission modelling           |
//| Forex: $7/lot, Commodities: 0.0016%, Crypto: 0.04%, Indices: $0 |
//+------------------------------------------------------------------+
#ifndef COMMISSION_ENGINE_MQH
#define COMMISSION_ENGINE_MQH

#include "../Config.mqh"

class CCommissionEngine
{
private:
   CommissionSettings m_cfg;

public:
   CCommissionEngine() { m_cfg.Init(); }
   void SetConfig(const CommissionSettings &cfg) { m_cfg = cfg; }

   //--- Calculate round-trip commission for a trade
   double Calculate(string symbol, double lot_size, double entry_price)
   {
      SymbolSpec spec = GetSymbolSpec(symbol);
      double commission = 0;

      switch(spec.asset_class)
      {
         case ASSET_FOREX:
            // Fixed commission per lot (round trip)
            commission = m_cfg.forex_per_lot * lot_size;
            break;

         case ASSET_COMMODITY:
         {
            // Percentage of position value (round trip = 2x)
            double position_value = entry_price * lot_size * spec.contract_size;
            commission = position_value * m_cfg.commodity_pct * 2.0;
            break;
         }

         case ASSET_CRYPTO:
         {
            // Percentage of position value (round trip = 2x)
            double position_value = entry_price * lot_size * spec.contract_size;
            commission = position_value * m_cfg.crypto_pct * 2.0;
            break;
         }

         case ASSET_INDEX:
            // No commission
            commission = m_cfg.index_per_lot * lot_size;
            break;
      }

      return NormalizeDouble(commission, 2);
   }

   //--- Get commission description
   string Description(string symbol)
   {
      SymbolSpec spec = GetSymbolSpec(symbol);
      switch(spec.asset_class)
      {
         case ASSET_FOREX:     return StringFormat("$%.0f/lot", m_cfg.forex_per_lot);
         case ASSET_COMMODITY: return StringFormat("%.4f%%", m_cfg.commodity_pct * 100);
         case ASSET_CRYPTO:    return StringFormat("%.2f%%", m_cfg.crypto_pct * 100);
         case ASSET_INDEX:     return "$0";
         default:              return "Unknown";
      }
   }
};

#endif
