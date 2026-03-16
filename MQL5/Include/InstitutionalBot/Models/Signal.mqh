//+------------------------------------------------------------------+
//| Signal.mqh - Trade signal model with scoring                     |
//+------------------------------------------------------------------+
#ifndef SIGNAL_MQH
#define SIGNAL_MQH

enum ENUM_SIGNAL_DIRECTION { SIGNAL_BUY, SIGNAL_SELL };

enum ENUM_SETUP_GRADE
{
   GRADE_A_PLUS = 0,  // A+
   GRADE_A      = 1,  // A
   GRADE_B      = 2,  // B
   GRADE_C      = 3,  // C
   GRADE_D      = 4   // D (no trade)
};

string GradeToString(ENUM_SETUP_GRADE grade)
{
   switch(grade)
   {
      case GRADE_A_PLUS: return "A+";
      case GRADE_A:      return "A";
      case GRADE_B:      return "B";
      case GRADE_C:      return "C";
      default:           return "D";
   }
}

//+------------------------------------------------------------------+
//| Score Breakdown                                                   |
//+------------------------------------------------------------------+
struct ScoreBreakdown
{
   double poi_strength;
   double cluster_strength;
   double liquidity_confluence;
   double forecast_alignment;
   double structure_alignment;
   double regime_suitability;
   double timing_quality;
   double sweep_quality;
   double trap_quality;
   double reversal_quality;
   double fvg_confluence;      // Multi-TF FVG overlap bonus
   double flip_level_bonus;    // Flip level (S/R polarity change) bonus

   void Init()
   {
      poi_strength          = 0;
      cluster_strength      = 0;
      liquidity_confluence  = 0;
      forecast_alignment    = 0;
      structure_alignment   = 0;
      regime_suitability    = 0;
      timing_quality        = 0;
      sweep_quality         = 0;
      trap_quality          = 0;
      reversal_quality      = 0;
      fvg_confluence        = 0;
      flip_level_bonus      = 0;
   }

   double Total() const
   {
      return poi_strength + cluster_strength + liquidity_confluence +
             forecast_alignment + structure_alignment + regime_suitability +
             timing_quality + sweep_quality + trap_quality + reversal_quality +
             fvg_confluence + flip_level_bonus;
   }
};

//+------------------------------------------------------------------+
//| Signal Structure                                                  |
//+------------------------------------------------------------------+
struct SignalData
{
   string               symbol;
   ENUM_SIGNAL_DIRECTION direction;
   double               entry_price;
   double               sl_price;
   double               tp_price;
   double               lot_size;
   double               total_score;
   ENUM_SETUP_GRADE     grade;
   ScoreBreakdown       score_breakdown;
   int                  poi_id;
   string               cluster_id;
   bool                 sweep_detected;
   bool                 trap_detected;
   string               reversal_type;
   double               risk_pct;
   bool                 approved;
   string               rejection_reason;
   string               confluences[20];
   int                  confluence_count;
   datetime             timestamp;

   void Init()
   {
      symbol           = "";
      direction        = SIGNAL_BUY;
      entry_price      = 0;
      sl_price         = 0;
      tp_price         = 0;
      lot_size         = 0;
      total_score      = 0;
      grade            = GRADE_D;
      score_breakdown.Init();
      poi_id           = 0;
      cluster_id       = "";
      sweep_detected   = false;
      trap_detected    = false;
      reversal_type    = "";
      risk_pct         = 0;
      approved         = false;
      rejection_reason = "";
      confluence_count = 0;
      timestamp        = 0;
   }

   void AddConfluence(string conf)
   {
      if(confluence_count < 20)
      {
         confluences[confluence_count] = conf;
         confluence_count++;
      }
   }
};

#endif
