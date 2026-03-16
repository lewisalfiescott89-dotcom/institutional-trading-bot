//+------------------------------------------------------------------+
//| Trade.mqh - Trade model with full accounting                     |
//+------------------------------------------------------------------+
#ifndef TRADE_MQH
#define TRADE_MQH

enum ENUM_TRADE_STATUS
{
   STATUS_PENDING,
   STATUS_OPEN,
   STATUS_CLOSED_WIN,
   STATUS_CLOSED_LOSS,
   STATUS_CLOSED_BE,
   STATUS_CANCELLED
};

enum ENUM_TRADE_DIRECTION { TRADE_BUY, TRADE_SELL };

struct TradeData
{
   int                  id;
   long                 ticket;
   string               symbol;
   ENUM_TRADE_DIRECTION direction;
   double               entry_price;
   double               sl_price;
   double               original_sl_price;
   double               tp_price;
   double               close_price;
   double               lot_size;
   double               risk_pct;
   ENUM_TRADE_STATUS    status;
   double               gross_pnl;
   double               commission;
   double               net_pnl;
   double               r_multiple;
   string               grade;
   double               setup_score;
   int                  poi_id;
   datetime             open_time;
   datetime             close_time;
   bool                 is_reentry;
   bool                 is_dry_run;
   int                  parent_poi_id;
   string               signal_id;

   void Init()
   {
      id            = 0;
      ticket        = 0;
      symbol        = "";
      direction     = TRADE_BUY;
      entry_price   = 0;
      sl_price      = 0;
      original_sl_price = 0;
      tp_price      = 0;
      close_price   = 0;
      lot_size      = 0;
      risk_pct      = 0;
      status        = STATUS_PENDING;
      gross_pnl     = 0;
      commission    = 0;
      net_pnl       = 0;
      r_multiple    = 0;
      grade         = "";
      setup_score   = 0;
      poi_id        = 0;
      open_time     = 0;
      close_time    = 0;
      is_reentry    = false;
      is_dry_run    = false;
      parent_poi_id = 0;
      signal_id     = "";
   }

   double RiskDistance()         { return MathAbs(entry_price - sl_price); }
   double OriginalRiskDistance()  { return MathAbs(entry_price - original_sl_price); }
   double RewardDistance()        { return MathAbs(tp_price - entry_price); }

   double RRRatio()
   {
      double rd = RiskDistance();
      if(rd == 0) return 0;
      return RewardDistance() / rd;
   }

   bool IsOpen() const { return status == STATUS_OPEN; }
};

#endif
