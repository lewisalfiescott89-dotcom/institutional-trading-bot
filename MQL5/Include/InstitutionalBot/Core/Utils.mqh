//+------------------------------------------------------------------+
//| Utils.mqh - Utility functions for the bot                        |
//+------------------------------------------------------------------+
#ifndef UTILS_MQH
#define UTILS_MQH

//+------------------------------------------------------------------+
//| ATR Calculation (Wilder smoothing)                                |
//+------------------------------------------------------------------+
double ComputeATR(const double &highs[], const double &lows[], const double &closes[],
                  int period, int bar_count)
{
   if(bar_count < period + 1) return 0;

   double tr[];
   ArrayResize(tr, bar_count);
   tr[0] = highs[0] - lows[0];
   for(int i = 1; i < bar_count; i++)
      tr[i] = MathMax(highs[i] - lows[i],
              MathMax(MathAbs(highs[i] - closes[i-1]),
                      MathAbs(lows[i] - closes[i-1])));

   // Initial ATR = simple average of first 'period' TRs
   double sum = 0;
   for(int i = 0; i < period; i++) sum += tr[i];
   double atr = sum / period;

   // Wilder smoothing for remaining bars
   for(int i = period; i < bar_count; i++)
      atr = (atr * (period - 1) + tr[i]) / period;

   return atr;
}

//+------------------------------------------------------------------+
//| ATR at specific bar (returns array of ATR values)                 |
//+------------------------------------------------------------------+
void ComputeATRArray(const double &highs[], const double &lows[], const double &closes[],
                     int period, int bar_count, double &atr_out[])
{
   ArrayResize(atr_out, bar_count);
   ArrayInitialize(atr_out, 0);

   if(bar_count < period + 1) return;

   double tr[];
   ArrayResize(tr, bar_count);
   tr[0] = highs[0] - lows[0];
   for(int i = 1; i < bar_count; i++)
      tr[i] = MathMax(highs[i] - lows[i],
              MathMax(MathAbs(highs[i] - closes[i-1]),
                      MathAbs(lows[i] - closes[i-1])));

   double sum = 0;
   for(int i = 0; i < period; i++) sum += tr[i];
   atr_out[period - 1] = sum / period;
   for(int i = period; i < bar_count; i++)
      atr_out[i] = (atr_out[i-1] * (period - 1) + tr[i]) / period;
}

//+------------------------------------------------------------------+
//| Candle helpers                                                    |
//+------------------------------------------------------------------+
double CandleBody(double open_price, double close_price)
{
   return MathAbs(close_price - open_price);
}

double CandleRange(double high, double low)
{
   return high - low;
}

double CandleUpperWick(double open_price, double close_price, double high)
{
   return high - MathMax(open_price, close_price);
}

double CandleLowerWick(double open_price, double close_price, double low)
{
   return MathMin(open_price, close_price) - low;
}

bool IsBullish(double open_price, double close_price)
{
   return close_price > open_price;
}

bool IsBearish(double open_price, double close_price)
{
   return close_price < open_price;
}

double BodyRatio(double open_price, double close_price, double high, double low)
{
   double r = CandleRange(high, low);
   if(r == 0) return 0;
   return CandleBody(open_price, close_price) / r;
}

//+------------------------------------------------------------------+
//| Swing detection                                                   |
//+------------------------------------------------------------------+
int DetectSwingHighs(const double &highs[], int bar_count, int lookback, int &indices[])
{
   int count = 0;
   ArrayResize(indices, 0);
   for(int i = lookback; i < bar_count - lookback; i++)
   {
      bool is_swing = true;
      for(int j = 1; j <= lookback; j++)
      {
         if(highs[i] < highs[i-j] || highs[i] < highs[i+j])
         {
            is_swing = false;
            break;
         }
      }
      if(is_swing)
      {
         ArrayResize(indices, count + 1);
         indices[count] = i;
         count++;
      }
   }
   return count;
}

int DetectSwingLows(const double &lows[], int bar_count, int lookback, int &indices[])
{
   int count = 0;
   ArrayResize(indices, 0);
   for(int i = lookback; i < bar_count - lookback; i++)
   {
      bool is_swing = true;
      for(int j = 1; j <= lookback; j++)
      {
         if(lows[i] > lows[i-j] || lows[i] > lows[i+j])
         {
            is_swing = false;
            break;
         }
      }
      if(is_swing)
      {
         ArrayResize(indices, count + 1);
         indices[count] = i;
         count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Zone overlap helpers                                              |
//+------------------------------------------------------------------+
bool ZonesOverlap(double low1, double high1, double low2, double high2)
{
   return low1 <= high2 && low2 <= high1;
}

double OverlapPct(double low1, double high1, double low2, double high2)
{
   double overlap_low  = MathMax(low1, low2);
   double overlap_high = MathMin(high1, high2);
   if(overlap_high <= overlap_low) return 0;
   double overlap_size = overlap_high - overlap_low;
   double smaller = MathMin(high1 - low1, high2 - low2);
   if(smaller == 0) return 0;
   return overlap_size / smaller;
}

//+------------------------------------------------------------------+
//| Get OHLCV arrays for a timeframe                                  |
//+------------------------------------------------------------------+
int LoadOHLCV(string symbol, ENUM_TIMEFRAMES tf, int count,
              double &opens[], double &highs[], double &lows[],
              double &closes[], long &volumes[], datetime &times[])
{
   ArraySetAsSeries(opens, false);
   ArraySetAsSeries(highs, false);
   ArraySetAsSeries(lows, false);
   ArraySetAsSeries(closes, false);
   ArraySetAsSeries(volumes, false);
   ArraySetAsSeries(times, false);

   int copied = CopyOpen(symbol, tf, 0, count, opens);
   if(copied <= 0) return 0;
   CopyHigh(symbol, tf, 0, count, highs);
   CopyLow(symbol, tf, 0, count, lows);
   CopyClose(symbol, tf, 0, count, closes);
   CopyTickVolume(symbol, tf, 0, count, volumes);
   CopyTime(symbol, tf, 0, count, times);
   return copied;
}

#endif
