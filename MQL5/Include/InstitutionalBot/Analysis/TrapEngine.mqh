//+------------------------------------------------------------------+
//| TrapEngine.mqh - Bull/Bear trap detection                        |
//| Detects false breakouts that reverse (institutional traps)       |
//+------------------------------------------------------------------+
#ifndef TRAP_ENGINE_MQH
#define TRAP_ENGINE_MQH

#include "../Core/Utils.mqh"
#include "../Models/Liquidity.mqh"
#include "../Config.mqh"

enum ENUM_TRAP_TYPE { TRAP_BULL, TRAP_BEAR };

struct TrapData
{
   ENUM_TRAP_TYPE type;
   double         break_price;
   double         reclaim_price;
   double         strength;
   double         score;
   int            bar_index;
   datetime       timestamp;
   bool           valid;

   void Init()
   {
      type          = TRAP_BULL;
      break_price   = 0;
      reclaim_price = 0;
      strength      = 0;
      score         = 0;
      bar_index     = 0;
      timestamp     = 0;
      valid         = false;
   }
};

#define MAX_TRAPS 50

class CTrapEngine
{
private:
   TrapSettings m_cfg;

public:
   CTrapEngine() { m_cfg.Init(); }
   void SetConfig(const TrapSettings &cfg) { m_cfg = cfg; }

   //--- Detect traps against liquidity levels
   int Detect(const double &opens[], const double &highs[],
              const double &lows[], const double &closes[],
              const datetime &times[], int bar_count,
              LiquidityLevel &levels[], int level_count,
              string symbol, TrapData &traps[], int max_traps)
   {
      int count = 0;
      if(bar_count < m_cfg.confirmation_bars + 2 || level_count == 0) return 0;

      SymbolSpec spec = GetSymbolSpec(symbol);
      double min_pen = m_cfg.min_penetration_pips * spec.pip_size;

      int lookback = MathMin(m_cfg.lookback_bars, bar_count - m_cfg.confirmation_bars - 1);
      int start = bar_count - lookback;
      if(start < 1) start = 1;

      for(int lv = 0; lv < level_count && count < max_traps; lv++)
      {
         if(!levels[lv].active) continue;
         double lev_price = levels[lv].price;

         for(int i = start; i < bar_count - m_cfg.confirmation_bars && count < max_traps; i++)
         {
            // Bull trap: break above resistance, fail to continue, reverse down
            if(levels[lv].side == LIQ_BUY_SIDE)
            {
               // Bar breaks above
               if(highs[i] > lev_price + min_pen || closes[i] > lev_price)
               {
                  // Check confirmation bars reverse
                  bool confirmed = true;
                  for(int c = 1; c <= m_cfg.confirmation_bars; c++)
                  {
                     int ci = i + c;
                     if(ci >= bar_count) { confirmed = false; break; }
                     if(closes[ci] >= lev_price) { confirmed = false; break; }
                  }
                  if(confirmed)
                  {
                     int ci = i + m_cfg.confirmation_bars;
                     traps[count].Init();
                     traps[count].type          = TRAP_BULL;
                     traps[count].break_price   = MathMax(highs[i], closes[i]);
                     traps[count].reclaim_price = closes[ci];
                     traps[count].bar_index     = ci;
                     traps[count].timestamp     = times[ci];
                     traps[count].strength      = levels[lv].strength;
                     traps[count].score         = ScoreTrap(traps[count], lev_price, spec);
                     traps[count].valid         = traps[count].score >= m_cfg.min_trap_score;
                     count++;
                  }
               }
            }
            // Bear trap: break below support, fail to continue, reverse up
            else if(levels[lv].side == LIQ_SELL_SIDE)
            {
               if(lows[i] < lev_price - min_pen || closes[i] < lev_price)
               {
                  bool confirmed = true;
                  for(int c = 1; c <= m_cfg.confirmation_bars; c++)
                  {
                     int ci = i + c;
                     if(ci >= bar_count) { confirmed = false; break; }
                     if(closes[ci] <= lev_price) { confirmed = false; break; }
                  }
                  if(confirmed)
                  {
                     int ci = i + m_cfg.confirmation_bars;
                     traps[count].Init();
                     traps[count].type          = TRAP_BEAR;
                     traps[count].break_price   = MathMin(lows[i], closes[i]);
                     traps[count].reclaim_price = closes[ci];
                     traps[count].bar_index     = ci;
                     traps[count].timestamp     = times[ci];
                     traps[count].strength      = levels[lv].strength;
                     traps[count].score         = ScoreTrap(traps[count], lev_price, spec);
                     traps[count].valid         = traps[count].score >= m_cfg.min_trap_score;
                     count++;
                  }
               }
            }
         }
      }
      return count;
   }

private:
   double ScoreTrap(TrapData &trap, double level_price, SymbolSpec &spec)
   {
      double pen_dist = MathAbs(trap.break_price - level_price);
      double pen_pips = pen_dist / spec.pip_size;
      double pen_score = MathMin(pen_pips / 10.0, 3.0);

      double reclaim_dist = MathAbs(trap.reclaim_price - level_price);
      double reclaim_pips = reclaim_dist / spec.pip_size;
      double reclaim_score = MathMin(reclaim_pips / 5.0, 3.0);

      double str_score = MathMin(trap.strength, 4.0);

      return pen_score + reclaim_score + str_score;
   }
};

#endif
