//+------------------------------------------------------------------+
//| State.mqh - Persistent state model                               |
//+------------------------------------------------------------------+
#ifndef STATE_MQH
#define STATE_MQH

#include "POI.mqh"
#include "Liquidity.mqh"
#include "Trade.mqh"
#include "Regime.mqh"
#include "OrderBlock.mqh"
#include "LiquidityPool.mqh"
#include "../Analysis/SessionEngine.mqh"
#include "../Analysis/FVGEngine.mqh"

#define MAX_POIS       200
#define MAX_LIQUIDITY  200
#define MAX_TRADES     50
#define MAX_ALL_FVGS   500

//+------------------------------------------------------------------+
//| Per-Symbol State                                                  |
//+------------------------------------------------------------------+
struct SymbolState
{
   string         symbol;

   // POIs
   POIData        active_pois[MAX_POIS];
   int            active_poi_count;
   POIData        invalidated_pois[MAX_POIS];
   int            invalidated_poi_count;

   // Liquidity
   LiquidityLevel active_liquidity[MAX_LIQUIDITY];
   int            active_liq_count;

   // Session
   string         session_name;
   bool           in_kill_zone;
   double         forecast_price;
   string         forecast_direction;

   // Wick probe
   string         wick_probe_pending_poi_id;

   // Trades
   TradeData      open_trades[MAX_TRADES];
   int            open_trade_count;
   TradeData      recent_closed[MAX_TRADES];
   int            recent_closed_count;

   // Regime
   MarketRegime   regime;

   // Re-entry
   int            reentry_poi_ids[MAX_POIS];
   int            reentry_count;

   // Multi-TF FVGs (all timeframes merged)
   FVGData        all_fvgs[MAX_ALL_FVGS];
   int            all_fvg_count;

   // Order Blocks (ICT)
   OrderBlockData   order_blocks[MAX_ORDER_BLOCKS];
   int              ob_count;

   // Breaker Blocks (failed OBs with flipped polarity)
   BreakerBlockData breaker_blocks[MAX_BREAKER_BLOCKS];
   int              bb_count;

   // Liquidity Pools (comprehensive ICT liquidity)
   LiquidityPoolData liq_pools[MAX_LIQ_POOLS];
   int               liq_pool_count;

   // Vacuum Blocks / Liquidity Voids
   VacuumBlockData  vacuum_blocks[MAX_VACUUM_BLOCKS];
   int              vacuum_count;

   // Stop Runs
   StopRunData      stop_runs[MAX_STOP_RUNS];
   int              stop_run_count;

   // Persistent session state per symbol
   SessionState   session_state;

   void Init()
   {
      symbol                    = "";
      active_poi_count          = 0;
      invalidated_poi_count     = 0;
      active_liq_count          = 0;
      session_name              = "";
      in_kill_zone              = false;
      forecast_price            = 0;
      forecast_direction        = "";
      wick_probe_pending_poi_id = "";
      open_trade_count          = 0;
      recent_closed_count       = 0;
      regime.Init();
      reentry_count             = 0;
      all_fvg_count             = 0;
      ob_count                  = 0;
      bb_count                  = 0;
      liq_pool_count            = 0;
      vacuum_count              = 0;
      stop_run_count            = 0;
      session_state.Init();
   }
};

//+------------------------------------------------------------------+
//| Global Risk State                                                 |
//+------------------------------------------------------------------+
struct GlobalRiskState
{
   double daily_pnl;
   double daily_drawdown;
   double peak_equity;
   int    consecutive_losses;
   bool   trading_paused;
   string pause_reason;
   int    total_trades_today;

   void Init()
   {
      daily_pnl          = 0;
      daily_drawdown     = 0;
      peak_equity        = 0;
      consecutive_losses = 0;
      trading_paused     = false;
      pause_reason       = "";
      total_trades_today = 0;
   }

   void ResetDaily()
   {
      daily_pnl          = 0;
      daily_drawdown     = 0;
      total_trades_today = 0;
      consecutive_losses = 0;
      if(trading_paused && StringFind(pause_reason, "daily") >= 0)
      {
         trading_paused = false;
         pause_reason   = "";
      }
   }
};

#endif
