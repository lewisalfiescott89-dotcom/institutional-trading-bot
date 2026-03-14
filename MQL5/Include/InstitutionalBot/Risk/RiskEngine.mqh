//+------------------------------------------------------------------+
//| RiskEngine.mqh - Grade-based dynamic risk allocation             |
//| Maps setup grades to risk percentages, applies regime modifiers  |
//+------------------------------------------------------------------+
#ifndef RISK_ENGINE_MQH
#define RISK_ENGINE_MQH

#include "../Models/Signal.mqh"
#include "../Models/Regime.mqh"
#include "../Config.mqh"

struct RiskResult
{
   double risk_pct;
   bool   allow_trade;
   string reason;

   void Init()
   {
      risk_pct    = 0;
      allow_trade = false;
      reason      = "";
   }
};

class CRiskEngine
{
private:
   RiskSettings m_cfg;

public:
   CRiskEngine() { m_cfg.Init(); }
   void SetConfig(const RiskSettings &cfg) { m_cfg = cfg; }

   //--- Calculate risk percentage for a given signal and regime
   void CalculateRisk(const SignalData &signal, const MarketRegime &regime,
                      double daily_pnl, double daily_drawdown_pct,
                      int consecutive_losses, double account_equity,
                      RiskResult &result)
   {
      result.Init();

      // Base risk from grade
      double base_risk = GradeToRisk(signal.grade);
      if(base_risk <= 0)
      {
         // Grade D gets minimum risk if it passed other filters
         base_risk = m_cfg.c_risk_pct * 0.5;  // Half of C-grade risk
         if(base_risk <= 0) base_risk = 0.1;
      }

      // Regime modifier
      double regime_mult = regime.RiskMultiplier();
      double adjusted_risk = base_risk * regime_mult;

      // Daily drawdown protection - convert daily_pnl (USD) to percentage of equity
      double daily_pnl_pct = (account_equity > 0) ? MathAbs(daily_pnl) / account_equity * 100.0 : 0;
      if(daily_pnl_pct > m_cfg.max_daily_drawdown_pct)
      {
         result.allow_trade = false;
         result.reason = StringFormat("Daily drawdown exceeded: %.2f%%", daily_pnl_pct);
         return;
      }

      // Consecutive loss reduction
      if(consecutive_losses >= m_cfg.max_consecutive_losses)
      {
         result.allow_trade = false;
         result.reason = StringFormat("Max consecutive losses: %d", consecutive_losses);
         return;
      }
      else if(consecutive_losses >= 2)
      {
         adjusted_risk *= (1.0 - 0.2 * (consecutive_losses - 1));
      }

      // Daily drawdown reduction as we approach limit (daily_drawdown_pct is already %)
      double dd_ratio = (m_cfg.max_daily_drawdown_pct > 0) ? daily_drawdown_pct / m_cfg.max_daily_drawdown_pct : 0;
      if(dd_ratio > 0.5)
         adjusted_risk *= (1.0 - (dd_ratio - 0.5));

      // Clamp
      adjusted_risk = MathMax(adjusted_risk, 0.1);
      adjusted_risk = MathMin(adjusted_risk, m_cfg.a_plus_risk_pct);

      result.risk_pct    = adjusted_risk;
      result.allow_trade = true;
      result.reason      = StringFormat("Grade %s, risk=%.2f%%, regime_mult=%.2f",
                             GradeToString(signal.grade), adjusted_risk, regime_mult);
   }

private:
   double GradeToRisk(ENUM_SETUP_GRADE grade)
   {
      switch(grade)
      {
         case GRADE_A_PLUS: return m_cfg.a_plus_risk_pct;
         case GRADE_A:      return m_cfg.a_risk_pct;
         case GRADE_B:      return m_cfg.b_risk_pct;
         case GRADE_C:      return m_cfg.c_risk_pct;
         case GRADE_D:      return 0;
         default:           return 0;
      }
   }
};

#endif
