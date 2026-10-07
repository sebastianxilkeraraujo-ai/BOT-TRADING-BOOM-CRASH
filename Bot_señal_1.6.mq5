#property copyright "Personal demo research tool"
#property version   "1.604"
#property description "Bot señal: observa configuraciones Boom/Crash y registra señales en CSV."
#property description "Ejecución opcional solo Demo USD; InpDemoExecution=false por defecto."

#define OBSERVER_RULE_VERSION "1.604"
#define OBSERVER_BUILD_VERSION "1.604"
#define OBSERVER_REVISION "r3-demo-levels-ownpos-risk2"
#define OBSERVER_BUILD_TAG "1.604-r3-demo-levels-manexec-ownpos-risk2-tp-retrace25"
#define OBSERVER_SIGNAL_COLUMNS 85
#include "src/Market/StructureRanges.mqh"

// Attach to a Boom or Crash M1 chart in a DEMO MT5 terminal.
// Full signals use closed candles. Experimental candidates use current quotes
// only near their setup and NEVER open a position.

enum RulePack { RULES_1500, RULES_1600 };
input RulePack InpRulePack = RULES_1600;
input bool InpShadowLegacyRules = false;
input bool InpRecoverV1520Pending = true;

input int    InpPivotStrength       = 2;
input int    InpScanBarsM5          = 180;
input int    InpScanBarsM15         = 120;
input int    InpScanBarsH1          = 180;
input int    InpScanBarsM1          = 40;
input int    InpMinZoneTouches      = 2;
input int    InpZoneRangeLookback   = 24;
input double InpZoneRangeFactor     = 0.25;
input double InpZoneMinWidthPrice   = 0.50;
input double InpZoneMaxWidthPrice   = 2.00;
input bool   InpWatchClosedM5Reactions = true;
input int    InpReactionMinSeparationM5Bars = 2;
input double InpReactionMinReboundWidths = 1.0;
input double InpReactionMinExcursionWidths = 2.0;
input double InpBreakMarginPoints   = 10.0;
input double InpStopBufferPoints    = 20.0;
input double InpMinimumRewardRisk   = 1.20;
input bool   InpDrawDetectedZones   = true;
input bool   InpDrawM15Zones        = false;
input int    InpMaxDrawnZonesPerType = 4;
input double InpMaxVisibleZoneDistancePrice = 40.0;
input bool   InpDrawHistoricalSupports = true;
input int    InpHistoricalScanBarsM5 = 360;
input int    InpMaxHistoricalSupports = 4;
input bool   InpDrawStructureM5 = true;
input bool   InpDrawStructureM15 = true;
input int    InpStructureBarsM5 = 360;
input int    InpStructureBarsM15 = 240;
input int    InpStructurePivotStrength = 3;
input int    InpStructureRangeLookback = 24;
input double InpStructureMinLegRanges = 3.0;
input bool   InpUseMedianRangeScale = false; // A/B variant; also applies to zones
input double InpStructureSpikeMultiple = 6.0; // diagnostic trimmed envelope
input string InpStructureEpoch = "default"; // change explicitly to start a new anchored history
input int    InpStructureHistoryLimit = 100000;
input bool   InpUseStructurePositionFilter = false;
input ENUM_TIMEFRAMES InpStructureFilterTimeframe = PERIOD_M5;
input double InpStructureEdgePercent = 10.0;
input int    InpCandidateObservationMinutes = 15;
input bool   InpRecoverV1500Pending = true;
input bool   InpEnableZoneApproachAlerts = true;
input int    InpZoneAlertCooldownMinutes = 15;
input bool   InpEnableEarlyZoneWarnings = true;
input double InpEarlyWarningDistancePrice = 1.50;
input bool   InpEnableBoomEarlyNCandidate = true;
input int    InpBoomNLookbackM1 = 40;
input double InpBoomNMinImpulseZoneWidths = 3.0;
input double InpBoomNMinBounceZoneWidths = 0.50;
input bool   InpEnableCrashTrendCandidate = true;
input int    InpCrashContextM5Bars = 120; // 10 hours of closed M5 candles
input int    InpCrashBreakLookbackM5 = 12;
input bool   InpLogCrashCandidateDiagnostics = true;
input int    InpCandidateCooldownMinutes = 20;
input double InpMaxSignalGapZoneWidths = 1.0;
input int    InpRetestLookbackBars  = 8;
input bool   InpEnableNModule       = true;
input bool   InpUseM5ReactionStrategy = true; // M1 gatillo, M5 >=2 reacciones, M15 contexto
input double InpPlanRiskMinUSD = 0.00;
input double InpPlanRiskMaxUSD = 2.00;
input int    InpNMinimumPullbackBars = 3;
input double InpNImpulseZoneWidths = 3.0;
input bool   InpEnableCrashDriftBuy = false; // Experimental, exposed to downward spikes
input bool   InpEnableBoomDriftSell = false; // Experimental, exposed to upward spikes
input bool   InpEnableCrashResistanceSell = true;
input bool   InpEnableDoubleTopBottomCandidate = false;
input bool   InpEnableDesktopAlerts = true;
input bool   InpSpanishSimpleAlerts = true;
input bool   InpPlayAlertSound       = true;
input string InpAlertSoundFile       = "alert.wav";
input int    InpAlertCooldownSeconds = 30;
input int    InpOutcomeMaxBars      = 180;
input int    InpMaxTickGapSeconds   = 10; // Missing coverage is not a win/loss
input bool   InpLegacyPriceDistances = false;
input double InpVisibleDistanceRanges = 10.0;
input double InpEarlyWarningWidths = 1.5;
input double InpBreakMarginRanges = 0.05;
input double InpStopBufferRanges = 0.10;
input string InpCsvFileName = "";
input string InpOutcomeCsvFileName = "";

input string InpCandidateCsvFileName = "";
input string InpCandidateOutcomeCsvFileName = "";

string g_signals_file,g_outcomes_file,g_candidates_file,g_candidate_outcomes_file;

enum ZoneKind
  {
   ZONE_SUPPORT,
   ZONE_RESISTANCE
  };

struct Zone
  {
   bool     valid;
   ZoneKind kind;
   double   center;
   double   lower;
   double   upper;
   int      touches;
   ENUM_TIMEFRAMES timeframe;
  };

struct PendingSignal
  {
   bool     active;
   string   id;
   datetime signal_time;
   string   module;
   string   side;
   double   entry;
   double   stop;
   double   target;
   int      bars_waited;
   long     entry_msc;
   long     cursor_msc;
   long     last_quote_msc;
   long     deadline_msc;
   long     max_gap_msc;
   double   point_size;
   string   outcome_file;
   string   rule_version;
   string   rule_pack;
   string observation_kind;
   double zone_lower,zone_upper,break_margin;
   bool spike_during,is_control;
   string spike_dir;
   long control_seed,last_spike_checked_m1,last_zone_checked_m5;
   int zone_broke;
   bool     measurement_only;
   double   mfe_points;
   double   mae_points;
   bool     resolved;
   string   resolved_outcome;
   long     resolved_msc;
   ulong    resolved_wait_start;
   double   resolved_fill,resolved_bid,resolved_ask;
  };

void InitZone(Zone &z)
  {
   z.valid=false; z.kind=ZONE_SUPPORT; z.center=0.0; z.lower=0.0; z.upper=0.0;
   z.touches=0; z.timeframe=PERIOD_CURRENT;
  }

void InitPendingSignal(PendingSignal &p)
  {
   p.active=false; p.id=""; p.signal_time=0; p.module=""; p.side="";
   p.entry=0.0; p.stop=0.0; p.target=0.0; p.bars_waited=0;
   p.entry_msc=0; p.cursor_msc=0; p.last_quote_msc=0; p.deadline_msc=0; p.max_gap_msc=0;
   p.point_size=0.0; p.outcome_file=""; p.rule_version=""; p.rule_pack=""; p.observation_kind="";
   p.zone_lower=0.0; p.zone_upper=0.0; p.break_margin=0.0;
   p.spike_during=false; p.is_control=false; p.spike_dir=""; p.control_seed=0;
   p.last_spike_checked_m1=0; p.last_zone_checked_m5=0; p.zone_broke=0;
   p.measurement_only=false; p.mfe_points=0.0; p.mae_points=0.0; p.resolved=false;
   p.resolved_outcome=""; p.resolved_msc=0; p.resolved_wait_start=0;
   p.resolved_fill=0.0; p.resolved_bid=0.0; p.resolved_ask=0.0;
  }

enum Trend
  {
   TREND_NONE,
   TREND_UP,
   TREND_DOWN
  };

datetime g_last_m1_bar = 0;
datetime g_last_signal_bar = 0;
datetime g_last_alert_time = 0;
datetime g_last_zone_alert_time = 0;
datetime g_last_zone_alert_bar = 0;
datetime g_last_early_warning_time = 0;
datetime g_last_candidate_time = 0;
datetime g_last_crash_context_m5 = 0;
datetime g_last_crash_missing_history_m5 = 0;
datetime g_last_crash_break_diagnostic_m5 = 0;
bool     g_crash_context_down = false;
double   g_crash_floor = 0.0;
double   g_crash_average_range = 0.0;
int      g_crash_context_minutes = 0;
string   g_zone_alert_keys[64];
datetime g_zone_alert_times[64];
int      g_zone_alert_count = 0;
double   g_early_support_centers[];
int      g_early_support_reactions[];
double   g_early_support_tolerance = 0.0;
double   g_early_resistance_centers[];
int      g_early_resistance_reactions[];
double   g_early_resistance_tolerance = 0.0;
datetime g_last_rejection_notice_time = 0;
string   g_last_rejection_notice_key = "";
string   g_last_signal_rejection_reason = "";
int      g_last_m5_support_count = -2;
int      g_last_m5_resistance_count = -2;
int      g_last_historical_support_count = -2;
PendingSignal g_pending[];
RulePack g_eval_pack=RULES_1600;
string RulePackText() { return g_eval_pack==RULES_1500 ? "RULES_1500" : "RULES_1600"; }
bool ActivePack() { return g_eval_pack==InpRulePack; }
double g_m5_range=0.0;
MqlRates g_boom_m1[];
datetime g_structure_bar_m5=0;
datetime g_structure_bar_m15=0;
string g_structure_key_m5="";
string g_structure_key_m15="";
datetime g_boom_cache_bar=0;
double g_boom_live_low=0.0;
StructureBounds g_structure_done[2];
StructureBounds g_structure_trimmed[2];
bool g_structure_ready[2];
int g_structure_spikes[2];
datetime g_structure_asof[2];
datetime g_structure_anchor[2];
#include "src/Observability/Observability.mqh"
#include "src/Market/Market.mqh"
#include "src/Strategy/Strategy.mqh"
#include "src/Execution/Execution.mqh"

double BreakMargin()
  {
   return InpLegacyPriceDistances ? InpBreakMarginPoints*_Point
                                 : MathMax(_Point,g_m5_range*InpBreakMarginRanges);
  }
double StopBuffer()
  {
   return InpLegacyPriceDistances ? InpStopBufferPoints*_Point
                                 : MathMax(_Point,g_m5_range*InpStopBufferRanges);
  }
double VisibleDistance()
  {
   return InpLegacyPriceDistances ? InpMaxVisibleZoneDistancePrice
                                 : g_m5_range*InpVisibleDistanceRanges;
  }
double EarlyDistance()
  {
   return InpLegacyPriceDistances ? InpEarlyWarningDistancePrice
                                 : g_m5_range*InpZoneRangeFactor*InpEarlyWarningWidths;
  }

bool IsNewM1Bar()
  {
   datetime current_bar = iTime(_Symbol, PERIOD_M1, 0);
   if(current_bar == 0)
      return false;
   if(current_bar == g_last_m1_bar)
      return false;
   g_last_m1_bar = current_bar;
   return true;
  }

bool LoadRates(const ENUM_TIMEFRAMES timeframe,const int requested,MqlRates &rates[])
  {
   ArraySetAsSeries(rates,true);
   int copied = CopyRates(_Symbol,timeframe,0,requested,rates);
   return (copied >= requested);
  }

// Zone half-width is expressed in actual price units.  A fixed number of _Point
// was only 0.008 on a four-decimal symbol and missed visibly repeated M5 highs.
double MeanTrueRange(const MqlRates &rates[])
  {
   if(InpUseMedianRangeScale) return StructureRangeAt(rates,1,InpZoneRangeLookback,true);
   int count=MathMin(InpZoneRangeLookback,ArraySize(rates)-2);
   if(count<1) return 0.0;
   double total=0.0;
   for(int i=1;i<=count;i++)
      total+=MathMax(rates[i].high-rates[i].low,
                    MathMax(MathAbs(rates[i].high-rates[i+1].close),
                            MathAbs(rates[i].low-rates[i+1].close)));
   return total/count;
  }

double ZoneHalfWidth(const MqlRates &rates[])
  {
   double width=MeanTrueRange(rates)*InpZoneRangeFactor;
   double tick_size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double minimum=MathMax(_Point,tick_size);
   if(InpLegacyPriceDistances)
      return MathMax(InpZoneMinWidthPrice,MathMin(InpZoneMaxWidthPrice,width));
   return MathMax(minimum,width);
  }

bool RefreshScale()
  {
   MqlRates rates[];
   if(!LoadRates(PERIOD_M5,MathMax(3,InpZoneRangeLookback+2),rates)) return false;
   g_m5_range=MeanTrueRange(rates);
   return g_m5_range>0.0;
  }

bool IsPivotHigh(const MqlRates &rates[],const int shift,const int strength)
  {
   int total = ArraySize(rates);
   if(shift-strength < 1 || shift+strength >= total)
      return false;
   for(int offset=1; offset<=strength; offset++)
      if(rates[shift].high <= rates[shift-offset].high || rates[shift].high <= rates[shift+offset].high)
         return false;
   return true;
  }

bool IsPivotLow(const MqlRates &rates[],const int shift,const int strength)
  {
   int total = ArraySize(rates);
   if(shift-strength < 1 || shift+strength >= total)
      return false;
   for(int offset=1; offset<=strength; offset++)
      if(rates[shift].low >= rates[shift-offset].low || rates[shift].low >= rates[shift+offset].low)
         return false;
   return true;
  }

// Uses two confirmed highs and two confirmed lows. Anything else is deliberately treated as neutral.
Trend DetectTrend(const ENUM_TIMEFRAMES timeframe,const int bars)
  {
   MqlRates rates[];
   if(!LoadRates(timeframe,bars,rates))
      return TREND_NONE;

   double high1=0.0,high2=0.0,low1=0.0,low2=0.0;
   int found_high=0,found_low=0;
   for(int shift=InpPivotStrength+1; shift<ArraySize(rates)-InpPivotStrength; shift++)
     {
      if(found_high<2 && IsPivotHigh(rates,shift,InpPivotStrength))
        {
         if(found_high==0) high1=rates[shift].high; else high2=rates[shift].high;
         found_high++;
        }
      if(found_low<2 && IsPivotLow(rates,shift,InpPivotStrength))
        {
         if(found_low==0) low1=rates[shift].low; else low2=rates[shift].low;
         found_low++;
        }
      if(found_high==2 && found_low==2)
         break;
     }
   if(found_high<2 || found_low<2)
      return TREND_NONE;
   if(high1>high2 && low1>low2)
      return TREND_UP;
   if(high1<high2 && low1<low2)
      return TREND_DOWN;
   return TREND_NONE;
  }

// All signal/target selectors consume the same role-aware collector as drawings.
Zone MakeZone(const ENUM_TIMEFRAMES tf,const ZoneKind kind,const double center,
              const double tolerance,const int touches)
  {
   Zone zone;
   zone.valid=true; zone.kind=kind; zone.timeframe=tf;
   zone.center=center; zone.lower=center-tolerance; zone.upper=center+tolerance;
   zone.touches=touches;
   return zone;
  }

Zone FindNearestTargetZone(const ENUM_TIMEFRAMES timeframe,const ZoneKind kind,const int bars,
                           const double reference_price,const bool above_price)
  {
   Zone result;
   InitZone(result);
   double centers[],tolerance=0.0;
   int touches[];
   int count=CollectQualifiedZones(timeframe,kind,bars,centers,touches,tolerance,timeframe==PERIOD_M5);
   double best=DBL_MAX;
   for(int i=0;i<MathMin(count,InpMaxDrawnZonesPerType);i++)
     {
      double edge=above_price ? centers[i]-tolerance : centers[i]+tolerance;
      if((above_price && edge<=reference_price) || (!above_price && edge>=reference_price)) continue;
      double distance=MathAbs(edge-reference_price);
      if(distance<best)
        {
         best=distance;
         result=MakeZone(timeframe,kind,centers[i],tolerance,touches[i]);
        }
     }
   return result;
  }

bool IsCrashSymbol()
  {
   string name=_Symbol;
   StringToUpper(name);
   return StringFind(name,"CRASH")>=0;
  }

bool IsBoomSymbol()
  {
   string name=_Symbol;
   StringToUpper(name);
   return StringFind(name,"BOOM")>=0;
  }

bool ClosedM1RejectsBelow(const Zone &zone,const MqlRates &m1[])
  {
   // The closed candle touched a former support from below and closed back below it.
   return (m1[1].high>=zone.lower && m1[1].close<zone.lower && m1[1].close<m1[1].open);
  }

bool ClosedM1RejectsAbove(const Zone &zone,const MqlRates &m1[])
  {
   // The closed candle touched a former resistance from above and closed back above it.
   return (m1[1].low<=zone.upper && m1[1].close>zone.upper && m1[1].close>m1[1].open);
  }

bool BrokeBelowRecently(const Zone &zone,MqlRates &m1[])
  {
   const double price_margin=BreakMargin();
   int last=MathMin(InpRetestLookbackBars+1,ArraySize(m1)-2);
   for(int shift=2; shift<=last; shift++)
      if(m1[shift].close<zone.lower-price_margin && m1[shift+1].close>=zone.lower)
         return true;
   return false;
  }

bool BrokeAboveRecently(const Zone &zone,MqlRates &m1[])
  {
   const double price_margin=BreakMargin();
   int last=MathMin(InpRetestLookbackBars+1,ArraySize(m1)-2);
   for(int shift=2; shift<=last; shift++)
      if(m1[shift].close>zone.upper+price_margin && m1[shift+1].close<=zone.upper)
         return true;
   return false;
  }

double NearestTargetPrice(const string side,const double entry)
  {
   Zone m5_target;
   Zone m15_target;
   Zone h1_target;
   if(side=="SELL")
     {
      m5_target=FindNearestTargetZone(PERIOD_M5,ZONE_SUPPORT,InpScanBarsM5,entry,false);
      m15_target=FindNearestTargetZone(PERIOD_M15,ZONE_SUPPORT,InpScanBarsM15,entry,false);
      h1_target=FindNearestTargetZone(PERIOD_H1,ZONE_SUPPORT,InpScanBarsH1,entry,false);
     }
   else
     {
      m5_target=FindNearestTargetZone(PERIOD_M5,ZONE_RESISTANCE,InpScanBarsM5,entry,true);
      m15_target=FindNearestTargetZone(PERIOD_M15,ZONE_RESISTANCE,InpScanBarsM15,entry,true);
      h1_target=FindNearestTargetZone(PERIOD_H1,ZONE_RESISTANCE,InpScanBarsH1,entry,true);
     }

   if(!m5_target.valid && !m15_target.valid && !h1_target.valid)
      return 0.0;
   double target=0.0;
   if(m5_target.valid)
      target=(side=="SELL" ? m5_target.upper : m5_target.lower);
   if(m15_target.valid && (target==0.0 || MathAbs((side=="SELL" ? m15_target.upper : m15_target.lower)-entry)<MathAbs(target-entry)))
      target=(side=="SELL" ? m15_target.upper : m15_target.lower);
   // H1 is context, not a trigger.  It may nevertheless cap a target if it is reached first.
   if(h1_target.valid && (target==0.0 || MathAbs((side=="SELL" ? h1_target.upper : h1_target.lower)-entry)<MathAbs(target-entry)))
      target=(side=="SELL" ? h1_target.upper : h1_target.lower);
   return target;
  }

bool IsNearZone(const double price,const Zone &zone)
  {
   if(!zone.valid)
      return false;
   return (price>=zone.lower && price<=zone.upper);
  }

void DeleteDrawnZones(const string prefix)
  {
   for(int index=ObjectsTotal(0,0,-1)-1; index>=0; index--)
     {
      string name=ObjectName(0,index,0,-1);
      if(StringFind(name,prefix)==0)
         ObjectDelete(0,name);
     }
  }

// The last decisive closed candle determines the current side of a band.
// A former support below which M5 closed is only a possible resistance now;
// a former resistance above which M5 closed is only a possible support.
ZoneKind CurrentZoneRole(const MqlRates &rates[],const double lower,const double upper,
                         const ZoneKind original_kind)
  {
   double price_margin=BreakMargin();
   for(int shift=1; shift<ArraySize(rates); shift++)
     {
      if(rates[shift].close<lower-price_margin)
         return ZONE_RESISTANCE;
      if(rates[shift].close>upper+price_margin)
         return ZONE_SUPPORT;
     }
   return original_kind;
  }

// Reaction: a local extreme, directional close in the outer 35% of the
// candle, and a measurable rejection wick; only completed candles qualify.
bool IsClosedM5Reaction(const MqlRates &rates[],const int shift,
                        const ZoneKind kind,const double minimum_rebound)
  {
   if(shift<1 || shift+2>=ArraySize(rates)) return false;
   double span=rates[shift].high-rates[shift].low;
   if(span<=0.0) return false;
   if(kind==ZONE_SUPPORT)
      return rates[shift].low<rates[shift+1].low &&
             rates[shift].low<rates[shift+2].low &&
             rates[shift].close>rates[shift].open &&
             rates[shift].close-rates[shift].low>=MathMax(minimum_rebound,0.65*span) &&
             MathMin(rates[shift].open,rates[shift].close)-rates[shift].low>=0.25*span;
   return rates[shift].high>rates[shift+1].high &&
          rates[shift].high>rates[shift+2].high &&
          rates[shift].close<rates[shift].open &&
          rates[shift].high-rates[shift].close>=MathMax(minimum_rebound,0.65*span) &&
          rates[shift].high-MathMax(rates[shift].open,rates[shift].close)>=0.25*span;
  }

bool MovedAwayBetweenM5Reactions(const MqlRates &rates[],const int newer_shift,
                                 const int older_shift,const ZoneKind kind,
                                 const double level,const double excursion)
  {
   // The older rejection candle itself may have provided the departure.
   if(kind==ZONE_SUPPORT && rates[older_shift].high>=level+excursion)
      return true;
   if(kind==ZONE_RESISTANCE && rates[older_shift].low<=level-excursion)
      return true;
   for(int shift=newer_shift+1; shift<older_shift; shift++)
      {
       if(kind==ZONE_SUPPORT && rates[shift].high>=level+excursion)
          return true;
       if(kind==ZONE_RESISTANCE && rates[shift].low<=level-excursion)
          return true;
      }
   return false;
  }

bool IsObservedZoneExtreme(const MqlRates &rates[],const int shift,
                           const ZoneKind kind,const bool include_reactions,
                           const double minimum_rebound)
  {
   bool pivot=(kind==ZONE_SUPPORT ? IsPivotLow(rates,shift,InpPivotStrength)
                                  : IsPivotHigh(rates,shift,InpPivotStrength));
   return pivot || (include_reactions &&
                    IsClosedM5Reaction(rates,shift,kind,minimum_rebound));
  }

// Unified nearby universe for drawings, warnings and closed-candle signals.
int CollectQualifiedZonesRaw(const ENUM_TIMEFRAMES timeframe,const ZoneKind kind,
                                     const int bars,double &centers[],int &reaction_counts[],
                                     double &tolerance,const bool include_closed_reactions,
                                     const double max_distance_price)
  {
   ArrayResize(centers,0);
   ArrayResize(reaction_counts,0);
   MqlRates rates[];
   if(!LoadRates(timeframe,bars,rates))
      return -1;

   tolerance=ZoneHalfWidth(rates);
   bool watch_reactions=(include_closed_reactions && timeframe==PERIOD_M5 &&
                         InpWatchClosedM5Reactions);
   double rebound=MathMax(_Point,tolerance*MathMax(0.0,InpReactionMinReboundWidths));
   double excursion=tolerance*MathMax(0.0,InpReactionMinExcursionWidths);
   double reference=iClose(_Symbol,PERIOD_M1,1);
   if(reference<=0.0)
      reference=rates[1].close;
   bool support_extreme[],resistance_extreme[];
   ArrayResize(support_extreme,ArraySize(rates)); ArrayResize(resistance_extreme,ArraySize(rates));
   for(int i=1;i<ArraySize(rates);i++)
     {
      support_extreme[i]=IsObservedZoneExtreme(rates,i,ZONE_SUPPORT,watch_reactions,rebound);
      resistance_extreme[i]=IsObservedZoneExtreme(rates,i,ZONE_RESISTANCE,watch_reactions,rebound);
     }
   int count=0;
   for(int source=0; source<2; source++)
     {
      ZoneKind original_kind=(source==0 ? ZONE_SUPPORT : ZONE_RESISTANCE);
       int first=(watch_reactions ? 1 : InpPivotStrength+1);
       int last=(watch_reactions ? ArraySize(rates) : ArraySize(rates)-InpPivotStrength);
       for(int candidate=first; candidate<last; candidate++)
        {
          if(!(source==0 ? support_extreme[candidate] : resistance_extreme[candidate]))
            continue;
         double seed=(original_kind==ZONE_SUPPORT ? rates[candidate].low : rates[candidate].high);
         int touches=0;
         double sum=0.0;
          int last_counted=-1;
          for(int check=first; check<last; check++)
           {
             if(!(source==0 ? support_extreme[check] : resistance_extreme[check]))
               continue;
            double test_price=(original_kind==ZONE_SUPPORT ? rates[check].low : rates[check].high);
            if(MathAbs(test_price-seed)<=tolerance)
              {
                if(watch_reactions && last_counted>=0)
                  {
                   if(check-last_counted<MathMax(1,InpReactionMinSeparationM5Bars) ||
                      !MovedAwayBetweenM5Reactions(rates,last_counted,check,
                                                    original_kind,seed,excursion))
                      continue;
                  }
               touches++;
               sum+=test_price;
                last_counted=check;
              }
           }
         if(touches<InpMinZoneTouches)
            continue;

         double center=sum/touches;
         if(CurrentZoneRole(rates,center-tolerance,center+tolerance,original_kind)!=kind)
            continue;
         if(max_distance_price>0.0 &&
            MathAbs(center-reference)>max_distance_price+tolerance)
            continue;

         int duplicate=-1;
         for(int existing=0; existing<count; existing++)
            if(MathAbs(centers[existing]-center)<=2.0*tolerance)
              {
               duplicate=existing;
               break;
              }
         if(duplicate>=0)
           {
            if(touches>reaction_counts[duplicate])
              {
               centers[duplicate]=center;
               reaction_counts[duplicate]=touches;
              }
            continue;
           }
         if(ArrayResize(centers,count+1)!=count+1 || ArrayResize(reaction_counts,count+1)!=count+1)
            return -1;
         centers[count]=center;
         reaction_counts[count]=touches;
         count++;
        }
     }

   for(int i=0; i<count; i++)
      for(int j=i+1; j<count; j++)
         if(MathAbs(centers[j]-reference)<MathAbs(centers[i]-reference) ||
            (MathAbs(centers[j]-reference)==MathAbs(centers[i]-reference) &&
             reaction_counts[j]>reaction_counts[i]))
           {
            double center_swap=centers[i];
            centers[i]=centers[j];
            centers[j]=center_swap;
            int touch_swap=reaction_counts[i];
            reaction_counts[i]=reaction_counts[j];
            reaction_counts[j]=touch_swap;
           }
   return count;
  }

// Alerts and complete signals keep their existing nearby-zone filter. Only the
// separate historical drawings call the unfiltered collector below.
int CollectQualifiedZones(const ENUM_TIMEFRAMES timeframe,const ZoneKind kind,const int bars,
                          double &centers[],int &reaction_counts[],double &tolerance,
                          const bool include_closed_reactions)
  {
   return CollectQualifiedZonesAtDistance(timeframe,kind,bars,centers,reaction_counts,
                                          tolerance,include_closed_reactions,
                                          VisibleDistance());
  }

// Rebuilt only once per M1 bar so the tick-level warning is inexpensive.
void RefreshEarlyWarningCache()
  {
   if(!InpEnableEarlyZoneWarnings && !InpEnableBoomEarlyNCandidate)
      return;
   int support_count=CollectQualifiedZones(PERIOD_M5,ZONE_SUPPORT,InpScanBarsM5,
                                           g_early_support_centers,g_early_support_reactions,
                                            g_early_support_tolerance,true);
   int resistance_count=CollectQualifiedZones(PERIOD_M5,ZONE_RESISTANCE,InpScanBarsM5,
                                              g_early_resistance_centers,g_early_resistance_reactions,
                                               g_early_resistance_tolerance,true);
   if(support_count<0)
     {
      ArrayResize(g_early_support_centers,0);
      ArrayResize(g_early_support_reactions,0);
     }
   if(resistance_count<0)
     {
      ArrayResize(g_early_resistance_centers,0);
      ArrayResize(g_early_resistance_reactions,0);
     }
  }

// Targets use exactly the same nearby M5 bands as drawings and signals.
double NearestCurrentM5SupportTarget(const double entry)
  {
   double centers[];
   int reaction_counts[];
   double tolerance=0.0;
   int count=CollectQualifiedZones(PERIOD_M5,ZONE_SUPPORT,InpScanBarsM5,
                                    centers,reaction_counts,tolerance,true);
   if(count<=0)
      return 0.0;
   int maximum=MathMin(InpMaxDrawnZonesPerType,count);
   double nearest=0.0;
   for(int selected=0; selected<maximum; selected++)
     {
      double upper=centers[selected]+tolerance;
      if(upper<entry && (nearest==0.0 || upper>nearest))
         nearest=upper;
     }
   return nearest;
  }

int DrawQualifiedZones(const ENUM_TIMEFRAMES timeframe,const ZoneKind kind,const int bars,
                       const string prefix,const color zone_color)
  {
   DeleteDrawnZones(prefix);
   if(!InpDrawDetectedZones || InpMaxDrawnZonesPerType<=0)
      return 0;

   double centers[];
   int reaction_counts[];
   double tolerance=0.0;
   int count=CollectQualifiedZones(timeframe,kind,bars,centers,reaction_counts,tolerance,
                                   timeframe==PERIOD_M5);
   if(count<0)
      return -1;
   int maximum=MathMin(InpMaxDrawnZonesPerType,count);
   datetime left_time=iTime(_Symbol,timeframe,bars-1);
   if(left_time==0)
      left_time=TimeCurrent()-PeriodSeconds(timeframe)*bars;
   datetime right_time=TimeCurrent()+PeriodSeconds(PERIOD_M1)*360;

   for(int selected=0; selected<maximum; selected++)
     {
      double price=centers[selected];
      string name=prefix+IntegerToString(selected+1);
      if(ObjectCreate(0,name,OBJ_RECTANGLE,0,left_time,price-tolerance,right_time,price+tolerance))
        {
         ObjectSetInteger(0,name,OBJPROP_COLOR,zone_color);
         ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DOT);
         ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
         ObjectSetInteger(0,name,OBJPROP_FILL,false);
         ObjectSetInteger(0,name,OBJPROP_BACK,true);
         ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
         ObjectSetString(0,name,OBJPROP_TOOLTIP,
                         EnumToString(timeframe)+" "+(kind==ZONE_SUPPORT ? "soporte" : "resistencia")+
                         " | reacciones: "+IntegerToString(reaction_counts[selected]));
        }
     }
   return maximum;
  }

// Show a few previously confirmed M5 support bands below price even when the
// nearby filter hides them. These are visual context only: no alerts or signals.
int DrawHistoricalSupportContext()
  {
   const string prefix="BCSO_M5_HIST_SUPPORT_";
   DeleteDrawnZones(prefix);
   if(!InpDrawDetectedZones || !InpDrawHistoricalSupports ||
      InpMaxHistoricalSupports<=0 || VisibleDistance()<=0.0)
      return 0;

   double centers[];
   int reaction_counts[];
   double tolerance=0.0;
   int context_bars=MathMin(720,MathMax(InpScanBarsM5,InpHistoricalScanBarsM5));
   int count=CollectQualifiedZonesAtDistance(PERIOD_M5,ZONE_SUPPORT,context_bars,
                                              centers,reaction_counts,tolerance,true,0.0);
   if(count<0 && context_bars>InpScanBarsM5)
     {
      context_bars=InpScanBarsM5;
      count=CollectQualifiedZonesAtDistance(PERIOD_M5,ZONE_SUPPORT,context_bars,
                                             centers,reaction_counts,tolerance,true,0.0);
     }
   if(count<0)
      return -1;

   double reference=iClose(_Symbol,PERIOD_M1,1);
   if(reference<=0.0)
      reference=iClose(_Symbol,PERIOD_M5,1);
   if(reference<=0.0)
      return 0;
   datetime left_time=iTime(_Symbol,PERIOD_M5,context_bars-1);
   if(left_time==0)
      left_time=TimeCurrent()-PeriodSeconds(PERIOD_M5)*context_bars;
   datetime right_time=TimeCurrent()+PeriodSeconds(PERIOD_M1)*360;
   int drawn=0;
   for(int selected=0; selected<count && drawn<InpMaxHistoricalSupports; selected++)
     {
      double price=centers[selected];
      if(price+tolerance>=reference ||
         reference-price<=VisibleDistance()+tolerance)
         continue;
      string name=prefix+IntegerToString(drawn+1);
      if(ObjectCreate(0,name,OBJ_RECTANGLE,0,left_time,price-tolerance,
                      right_time,price+tolerance))
        {
         ObjectSetInteger(0,name,OBJPROP_COLOR,clrSteelBlue);
         ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DASH);
         ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
         ObjectSetInteger(0,name,OBJPROP_FILL,false);
         ObjectSetInteger(0,name,OBJPROP_BACK,true);
         ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
         ObjectSetString(0,name,OBJPROP_TOOLTIP,
                         "M5 soporte historico (contexto, NO entrada) | reacciones: "+
                         IntegerToString(reaction_counts[selected]));
         drawn++;
        }
     }
   return drawn;
  }

void RefreshDetectedZoneDrawings()
  {
   int support_count=DrawQualifiedZones(PERIOD_M5,ZONE_SUPPORT,InpScanBarsM5,"BCSO_M5_SUPPORT_",clrDeepSkyBlue);
   int resistance_count=DrawQualifiedZones(PERIOD_M5,ZONE_RESISTANCE,InpScanBarsM5,"BCSO_M5_RESISTANCE_",clrMediumPurple);
   int historical_support_count=DrawHistoricalSupportContext();
   if(support_count!=g_last_m5_support_count || resistance_count!=g_last_m5_resistance_count)
     {
      if(support_count<0 || resistance_count<0)
         Print("ZONAS M5: esperando historial suficiente (",InpScanBarsM5," velas M5).");
      else
         Print("ZONAS M5 CERCANAS: ",support_count," posibles soportes, ",resistance_count,
               " posibles resistencias. Las zonas rotas cambian de papel; las lejanas se ocultan.");
      g_last_m5_support_count=support_count;
      g_last_m5_resistance_count=resistance_count;
     }
   if(historical_support_count!=g_last_historical_support_count)
     {
      if(historical_support_count<0)
         Print("SOPORTES M5 HISTORICOS: esperando historial suficiente.");
      else
         Print("SOPORTES M5 HISTORICOS: ",historical_support_count,
               " bandas inferiores de contexto. No son señales de entrada.");
      g_last_historical_support_count=historical_support_count;
     }
   if(InpDrawM15Zones)
     {
      DrawQualifiedZones(PERIOD_M15,ZONE_SUPPORT,InpScanBarsM15,"BCSO_M15_SUPPORT_",clrAqua);
      DrawQualifiedZones(PERIOD_M15,ZONE_RESISTANCE,InpScanBarsM15,"BCSO_M15_RESISTANCE_",clrMagenta);
     }
   else
     {
      DeleteDrawnZones("BCSO_M15_SUPPORT_");
      DeleteDrawnZones("BCSO_M15_RESISTANCE_");
     }
  }

// CSV is the durable ledger: replay pending entries after a restart.
// Files are opened exclusively; an unavailable/corrupt ledger blocks new signals.
// Use FILE_TXT and parse delimiters/quotes explicitly for durable CSV replay.
int ParseCsvRecord(const string text,string &row[])
  {
   ArrayResize(row,0);
   string cell="";
   bool quoted=false,after_quote=false;
   for(int i=0;i<StringLen(text);i++)
     {
      ushort ch=StringGetCharacter(text,i);
      if(quoted)
        {
         if(ch==34)
           {
            if(i+1<StringLen(text) && StringGetCharacter(text,i+1)==34)
              { cell+=StringSubstr(text,i,1); i++; }
            else { quoted=false; after_quote=true; }
           }
         else cell+=StringSubstr(text,i,1);
        }
      else if(ch==59)
        {
         int n=ArraySize(row); ArrayResize(row,n+1); row[n]=cell;
         cell=""; after_quote=false;
        }
      else if(ch==34 && StringLen(cell)==0 && !after_quote) quoted=true;
      else
        {
         if(after_quote || ch==34) return -1;
         cell+=StringSubstr(text,i,1);
        }
     }
   if(quoted) return 0;
   int n=ArraySize(row); ArrayResize(row,n+1); row[n]=cell;
   return 1;
  }

bool ReadCsvRow(const int handle,string &row[])
  {
   ArrayResize(row,0);
   string record="";
   bool started=false;
   while(!FileIsEnding(handle))
     {
      if(started) record+="\n";
      record+=FileReadString(handle);
      started=true;
      int parsed=ParseCsvRecord(record,row);
      if(parsed==1) return true;
      if(parsed<0) break;
     }
   if(!started) return false;
   ArrayResize(row,1); row[0]="INVALID_CSV_RECORD";
   return true; // fail schema validation instead of skipping corruption
  }

int LedgerContains(const string filename,const string id,const int columns)
  {
   if(!FileIsExist(filename,FILE_COMMON)) return 0;
   int handle=OpenCsvRetry(filename,FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON,';',CP_UTF8);
   if(handle==INVALID_HANDLE) return -1;
   string row[];
   int found=0;
   while(ReadCsvRow(handle,row))
     {
      if(ArraySize(row)!=columns) { found=-1; break; }
      if(row[0]==id) found=1;
     }
   FileClose(handle);
   return found;
  }

int FreePendingSlot()
  {
   for(int i=0;i<ArraySize(g_pending);i++) if(!g_pending[i].active) { InitPendingSignal(g_pending[i]); return i; }
   int n=ArraySize(g_pending);
   if(ArrayResize(g_pending,n+300)!=n+300) return -1;
   for(int i=n;i<n+300;i++) InitPendingSignal(g_pending[i]);
   return n;
  }

bool RestorePendingFile(const string filename,const string outcome_file,const string version,
                        const int columns,const int outcome_columns)
  {
   if(!FileIsExist(filename,FILE_COMMON)) return true;
   int handle=OpenCsvRetry(filename,FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON,';',CP_UTF8);
   if(handle==INVALID_HANDLE) return false;
   string row[];
   bool ok=true;
   int row_number=0;
   while(ReadCsvRow(handle,row))
     {
      row_number++;
      if(ArraySize(row)!=columns) { RecoveryIssue(filename,row_number,"fila o esquema incompatible; se conserva el archivo"); continue; }
      if(row[0]=="signal_id") continue;
      if(row[2]!=_Symbol || row[3]!=version) continue;
      int completed=LedgerContains(outcome_file,row[0],outcome_columns);
      if(completed<0) { RecoveryIssue(outcome_file,row_number,"desenlace no disponible; pendiente aplazado"); continue; }
      if(completed==1) continue;
      int slot=FreePendingSlot();
      if(slot<0) { RecoveryIssue(filename,row_number,"memoria insuficiente; pendiente conservado en CSV"); continue; }
      PendingSignal signal;
      InitPendingSignal(signal);
      signal.active=true; signal.id=row[0];
      signal.signal_time=StringToTime(row[1]);
      signal.module=row[4]; signal.side=row[5];
      signal.entry=StringToDouble(row[12]);
      signal.stop=StringToDouble(row[13]); signal.target=StringToDouble(row[14]);
      signal.entry_msc=StringToInteger(row[22]);
      signal.cursor_msc=signal.entry_msc+1;
      signal.last_quote_msc=signal.entry_msc;
      signal.deadline_msc=StringToInteger(row[23]);
      signal.max_gap_msc=StringToInteger(row[25]);
      signal.point_size=StringToDouble(row[26]);
      signal.outcome_file=outcome_file; signal.rule_version=version;
      signal.rule_pack=(columns>58 ? row[58] : "REFERENCE_1520");
      signal.observation_kind=columns>76 ? row[76] : (columns>27 && row[27]=="CANDIDATE" ? "CANDIDATE" : "SIGNAL");
      // El aviso no publica TP de operación; su objetivo virtual vive en zone_target.
      if(signal.observation_kind=="ZONE_ALERT" && columns>78) signal.target=StringToDouble(row[78]);
      signal.zone_lower=StringToDouble(row[9]); signal.zone_upper=StringToDouble(row[10]);
      signal.break_margin=columns>77 ? StringToDouble(row[77]) : 0.0;
      signal.is_control=columns>72 && row[72]=="1"; signal.control_seed=columns>73 ? StringToInteger(row[73]) : 0;
      signal.spike_dir="NONE";
      signal.measurement_only=(columns>27 && row[27]=="CANDIDATE");
      signal.mae_points=(columns>54 ? StringToDouble(row[54]) : 0.0);
      if(signal.entry_msc<=0 || signal.deadline_msc<=signal.entry_msc ||
         signal.max_gap_msc<=0 || signal.point_size<=0.0 ||
         (signal.side!="BUY" && signal.side!="SELL"))
        { RecoveryIssue(filename,row_number,"campos de seguimiento inválidos"); continue; }
      g_pending[slot]=signal;
     }
   FileClose(handle);
   return ok;
  }

bool RestorePendingSignals()
  {
   if(!RestorePendingFile(g_signals_file,g_outcomes_file,OBSERVER_RULE_VERSION,OBSERVER_SIGNAL_COLUMNS,29)) return false;
   if(!RestorePendingFile(g_candidates_file,g_candidate_outcomes_file,OBSERVER_RULE_VERSION,OBSERVER_SIGNAL_COLUMNS,29)) return false;
   if(!RestorePendingFile(g_alerts_file,g_alert_outcomes_file,OBSERVER_RULE_VERSION,OBSERVER_SIGNAL_COLUMNS,29)) return false;
   if(InpRecoverV1520Pending &&
      (!RestorePendingFile(TaggedCsv("BoomCrashSignalObserver_v1520.csv"),TaggedCsv("BoomCrashSignalOutcomes_v1520.csv"),"1.520",58,20) ||
       !RestorePendingFile(TaggedCsv("BoomCrashCandidates_v1520.csv"),TaggedCsv("BoomCrashCandidateOutcomes_v1520.csv"),"1.520",58,20))) return false;
   return !InpRecoverV1500Pending ||
          RestorePendingFile(TaggedCsv("BoomCrashSignalObserver_v1500.csv"),TaggedCsv("BoomCrashSignalOutcomes_v1500.csv"),"1.500",27,17);
  }

bool WriteOutcome(const PendingSignal &signal,const string outcome,const long time_msc,
                  const double exit_price,const double bid,const double ask)
  {
   bool legacy=signal.rule_version=="1.500";
   int columns=legacy ? 17 : ((signal.rule_version=="1.600" || signal.rule_version=="1.604") ? 29 : 20);
   int handle=OpenCsvRetry(signal.outcome_file,FILE_TXT|FILE_READ|FILE_WRITE|FILE_ANSI|FILE_COMMON,';',CP_UTF8);
   if(handle==INVALID_HANDLE) return false;
   bool empty=FileSize(handle)==0;
   string row[];
   while(ReadCsvRow(handle,row))
     {
      if(ArraySize(row)!=columns) { FileClose(handle); return false; }
      if(row[0]==signal.id) { FileClose(handle); return true; }
     }
   FileSeek(handle,0,SEEK_END);
   string header="signal_id;signal_time;outcome_time;symbol;module;side;entry_theoretical;sl_theoretical;tp_theoretical;bars_waited;outcome;exit_quote_bid;exit_quote_ask;exit_theoretical;pnl_points;rule_version;execution_model";
   if(!legacy) header+=";mfe_points;mae_points;record_kind";
   if(columns>20) header+=";rule_pack;time_to_outcome_sec;r_multiple;spike_during;spike_dir;is_control;control_seed;observation_kind;schema_version";
   if(empty && FileWriteString(handle,header+"\r\n")==0) { FileClose(handle); return false; }
   double points=(signal.side=="BUY" ? exit_price-signal.entry : signal.entry-exit_price)/signal.point_size;
   string pnl=(outcome=="DATA_GAP" ? "" : DoubleToString(points,5));
   string model=signal.measurement_only ? "CANDIDATE_FIXED_HORIZON" : "TICK_QUOTES_NO_COMMISSION";
   string values[];
   ArrayResize(values,columns);
   values[0]=signal.id; values[1]=TimeToString(signal.signal_time,TIME_DATE|TIME_SECONDS);
   values[2]=TimeToString((datetime)(time_msc/1000),TIME_DATE|TIME_SECONDS);
   values[3]=_Symbol; values[4]=signal.module; values[5]=signal.side;
   values[6]=DoubleToString(signal.entry,_Digits); values[7]=DoubleToString(signal.stop,_Digits);
   values[8]=DoubleToString(signal.target,_Digits);
   values[9]=IntegerToString((time_msc-signal.entry_msc)/60000); values[10]=outcome;
   values[11]=DoubleToString(bid,_Digits); values[12]=DoubleToString(ask,_Digits);
   values[13]=outcome=="DATA_GAP" ? "" : DoubleToString(exit_price,_Digits);
   values[14]=pnl; values[15]=signal.rule_version; values[16]=model;
   if(!legacy)
     {
      values[17]=outcome=="DATA_GAP" ? "" : DoubleToString(signal.mfe_points,5);
      values[18]=outcome=="DATA_GAP" ? "" : DoubleToString(signal.mae_points,5);
      values[19]=(signal.rule_version=="1.600" || signal.rule_version=="1.604") ? signal.observation_kind : (signal.measurement_only ? "CANDIDATE" : "SIGNAL");
     }
   if(columns>20)
     {
      values[20]=signal.rule_pack; values[21]=DoubleToString((time_msc-signal.entry_msc)/1000.0,3);
      double risk=MathAbs(signal.entry-signal.stop)/signal.point_size;
      values[22]=(outcome=="DATA_GAP" || signal.observation_kind!="SIGNAL" || risk<=0.0) ? "" : DoubleToString(points/risk,5);
      values[23]=signal.spike_during ? "1" : "0"; values[24]=signal.spike_dir;
      values[25]=signal.is_control ? "1" : "0"; values[26]=IntegerToString(signal.control_seed);
      values[27]=signal.observation_kind; values[28]="1600.1";
     }
   uint written=FileWriteString(handle,CsvLine(values));
   FileFlush(handle);
   FileClose(handle);
   return written>0;
  }

string CsvLine(const string &values[])
  {
   string line="";
   for(int i=0;i<ArraySize(values);i++)
     {
      string cell=values[i];
      StringReplace(cell,"\"","\"\"");
      if(i>0) line+=";";
      line+="\""+cell+"\"";
     }
   return line+"\r\n";
  }

// Quote-based simulation, never an execution claim. BUY exits on bid, SELL on
// ask. A stop crossed by a spike is filled at the first available quote.
int QuoteOutcome(const bool buy,const double stop,const double target,
                 const double bid,const double ask,double &fill)
  {
   fill=buy ? bid : ask;
   if(bid<=0.0 || ask<bid) return -1;
   if(buy ? bid<=stop : ask>=stop) return 1;
   if(buy ? bid>=target : ask<=target)
     { fill=target; return 2; } // no optimistic target-gap improvement
   return 0;
  }

void UpdatePendingOutcomes()
  {
   static datetime last_pass=0;
   datetime now=TimeCurrent();
   if(last_pass==now) return;
   last_pass=now;
   long until=(long)now*1000-1; // exclude a still-growing millisecond
   for(int i=0;i<ArraySize(g_pending);i++)
     {
      if(!g_pending[i].active) continue;
      if(g_pending[i].resolved)
        {
         long close_msc=(g_pending[i].resolved_msc/60000+1)*60000;
         bool closed=(long)iTime(_Symbol,PERIOD_M1,0)*1000>=close_msc;
         if(!closed && GetTickCount64()-g_pending[i].resolved_wait_start<120000) continue;
         if(closed)
           {
            string direction=ClosedSpikeAt(close_msc,g_pending[i].entry_msc);
            if(direction!="NONE") { g_pending[i].spike_during=true; g_pending[i].spike_dir=direction; }
           }
         if(WriteOutcome(g_pending[i],g_pending[i].resolved_outcome,g_pending[i].resolved_msc,
                         g_pending[i].resolved_fill,g_pending[i].resolved_bid,g_pending[i].resolved_ask))
            g_pending[i].active=false;
         continue;
        }
      // Bound work per pass; subsequent ticks continue catch-up chronologically.
      for(int chunk=0;chunk<4 && g_pending[i].active;chunk++)
        {
         long from=g_pending[i].cursor_msc;
         long to=MathMin(until,MathMin(from+59999,g_pending[i].deadline_msc));
         if(to<from) break;
         MqlTick ticks[];
         ResetLastError();
         int count=CopyTicksRange(_Symbol,ticks,COPY_TICKS_ALL,(ulong)from,(ulong)to);
         if(count<0 || GetLastError()!=0) break; // partial sync is not complete coverage
         string outcome="";
         double fill=0.0,bid=0.0,ask=0.0;
         long outcome_time=to,last_quote=g_pending[i].last_quote_msc;
         for(int k=0;k<count;k++)
           {
            if(ticks[k].time_msc-last_quote>g_pending[i].max_gap_msc)
              { outcome="DATA_GAP"; outcome_time=ticks[k].time_msc; break; }
            bid=ticks[k].bid; ask=ticks[k].ask;
            if((g_pending[i].rule_version=="1.600" || g_pending[i].rule_version=="1.604") && ticks[k].time_msc/60000!=g_pending[i].last_spike_checked_m1)
              {
               string direction=ClosedSpikeAt(ticks[k].time_msc,g_pending[i].entry_msc);
               if(direction!="NONE") { g_pending[i].spike_during=true; g_pending[i].spike_dir=direction; }
               g_pending[i].last_spike_checked_m1=ticks[k].time_msc/60000;
              }
            int hit;
            bool zone_alert=g_pending[i].observation_kind=="ZONE_ALERT";
            if(zone_alert)
              {
               fill=g_pending[i].side=="BUY" ? bid : ask;
               if(ticks[k].time_msc/300000!=g_pending[i].last_zone_checked_m5)
                 {
                  g_pending[i].zone_broke=ZoneClosedBreak(g_pending[i],ticks[k].time_msc);
                  g_pending[i].last_zone_checked_m5=ticks[k].time_msc/300000;
                 }
               hit=(bid<=0.0 || ask<bid || g_pending[i].zone_broke<0) ? -1 :
                    (g_pending[i].zone_broke>0 ? 1 : (g_pending[i].side=="BUY" ? (bid>=g_pending[i].target ? 2 : 0) : (ask<=g_pending[i].target ? 2 : 0)));
              }
            else if(g_pending[i].measurement_only)
              {
               fill=g_pending[i].side=="BUY" ? bid : ask;
               hit=(bid<=0.0 || ask<bid) ? -1 : 0;
              }
            else
               hit=QuoteOutcome(g_pending[i].side=="BUY",g_pending[i].stop,g_pending[i].target,bid,ask,fill);
            if(hit>=0)
              {
               double move=(g_pending[i].side=="BUY" ? fill-g_pending[i].entry : g_pending[i].entry-fill)/g_pending[i].point_size;
               g_pending[i].mfe_points=MathMax(g_pending[i].mfe_points,move);
               g_pending[i].mae_points=MathMax(g_pending[i].mae_points,-move);
              }
            if(hit<0) { outcome="DATA_GAP"; outcome_time=ticks[k].time_msc; break; }
            last_quote=ticks[k].time_msc;
            if(hit>0)
              {
               outcome=zone_alert ? (hit==1 ? "BROKE" : "REACTION") : (hit==1 ? "SL_FIRST" : "TP_FIRST");
               outcome_time=ticks[k].time_msc;
               break;
              }
           }
         if(StringLen(outcome)==0 && to-last_quote>g_pending[i].max_gap_msc) outcome="DATA_GAP";
         if(StringLen(outcome)==0 && to>=g_pending[i].deadline_msc)
           {
            // Require a quote in the final chunk to mark-to-market at expiry.
            outcome=(count>0 ? (g_pending[i].observation_kind=="ZONE_ALERT" ? "NEUTRAL" : (g_pending[i].measurement_only ? "HORIZON_REACHED" : "EXPIRED_NO_LEVEL")) : "DATA_GAP");
           }
         if(StringLen(outcome)>0)
           {
            if(g_pending[i].rule_version=="1.600" || g_pending[i].rule_version=="1.604")
              {
               g_pending[i].resolved=true; g_pending[i].resolved_outcome=outcome;
               g_pending[i].resolved_msc=outcome_time; g_pending[i].resolved_wait_start=GetTickCount64();
               g_pending[i].resolved_fill=fill; g_pending[i].resolved_bid=bid; g_pending[i].resolved_ask=ask;
               long close_msc=(outcome_time/60000+1)*60000;
               if((long)iTime(_Symbol,PERIOD_M1,0)*1000<close_msc) break;
               string direction=ClosedSpikeAt(close_msc,g_pending[i].entry_msc);
               if(direction!="NONE") { g_pending[i].spike_during=true; g_pending[i].spike_dir=direction; }
              }
            if(WriteOutcome(g_pending[i],outcome,outcome_time,fill,bid,ask))
               g_pending[i].active=false;
            break; // retry same chunk if the output could not be persisted
           }
         g_pending[i].last_quote_msc=last_quote;
         g_pending[i].cursor_msc=to+1;
        }
     }
  }

void NotifySignal(const string module,const string side,const double entry,const Zone &zone)
  {
   if(!InpEnableDesktopAlerts || !ActivePack())
      return;
   datetime now=TimeCurrent();
   if(g_last_alert_time>0 && (now-g_last_alert_time)<InpAlertCooldownSeconds)
      return;
   g_last_alert_time=now;
   string signal_text=(InpSpanishSimpleAlerts ? SimpleModuleText(module,side) : module+" "+side);
   string message="SEÑAL OBSERVADA — NO ABRE OPERACIONES\n"+
                  _Symbol+" | "+signal_text+
                  "\nEntrada de referencia: "+DoubleToString(entry,_Digits)+
                  "\nZona: "+DoubleToString(zone.lower,_Digits)+" - "+DoubleToString(zone.upper,_Digits)+
                  "\nRevisa M1, M5 y M15 antes de decidir.";
   Alert(message);
   if(InpPlayAlertSound)
      PlaySound(InpAlertSoundFile);
  }

string SimpleSideText(const string side)
  {
   if(side=="BUY")
      return "compra";
   return "venta";
  }

string SimpleModuleText(const string module,const string side)
  {
   string direction=SimpleSideText(side);
   if(module=="N_BREAK_RETEST")
      return "Patrón N: posible "+direction+" tras retesteo";
   if(module=="CRASH_DRIFT")
      return "Crash en subida: rebote en soporte para posible compra";
   if(module=="BOOM_DRIFT")
      return "Boom en bajada: rechazo en resistencia para posible venta";
   if(module=="CRASH_RESISTANCE_REJECTION")
      return "Crash: rechazo bajista en resistencia M5 para posible venta";
   if(module=="DOUBLE_TOP_BOTTOM_CANDIDATE")
      return "Doble techo/piso experimental: posible "+direction;
   return "Configuración observada: posible "+direction;
  }

bool ClosedM1TouchesZone(const Zone &zone,const MqlRates &m1[])
  {
   if(!zone.valid || ArraySize(m1)<2)
      return false;
   return (m1[1].high>=zone.lower && m1[1].low<=zone.upper);
  }

string ZoneAlertKey(const string stage,const Zone &zone)
  {
   return stage+"_"+EnumToString(zone.timeframe)+"_"+EnumToString(zone.kind)+"_"+
          DoubleToString(zone.center,_Digits);
  }

bool ZoneAlertInCooldown(const string key,const datetime now,const int seconds)
  {
   for(int index=0; index<g_zone_alert_count; index++)
      if(g_zone_alert_keys[index]==key && now-g_zone_alert_times[index]<seconds)
         return true;
   return false;
  }

void RememberZoneAlert(const string key,const datetime now)
  {
   for(int index=0; index<g_zone_alert_count; index++)
      if(g_zone_alert_keys[index]==key)
        {
         g_zone_alert_times[index]=now;
         return;
        }
   int slot=g_zone_alert_count;
   if(slot>=64)
     {
      slot=0;
      for(int index=1; index<64; index++)
         if(g_zone_alert_times[index]<g_zone_alert_times[slot])
            slot=index;
     }
   else
      g_zone_alert_count++;
   g_zone_alert_keys[slot]=key;
   g_zone_alert_times[slot]=now;
  }

// A zone alert is intentionally not an entry alert.  It calls attention to a
// pre-existing M5 area so the trader can then check whether M1 rejects or breaks it.
void NotifyZoneReached(const Zone &zone,const MqlRates &m1[])
  {
   if(!InpEnableZoneApproachAlerts || !ClosedM1TouchesZone(zone,m1))
      return;
   datetime now=TimeCurrent();
   if(g_last_candidate_time>0 && now-g_last_candidate_time<60)
      return;
   datetime closed_bar=iTime(_Symbol,PERIOD_M1,1);
   if(closed_bar==g_last_zone_alert_bar ||
      (g_last_zone_alert_time>0 && now-g_last_zone_alert_time<60))
      return;
   string key=ZoneAlertKey("REACHED",zone);
   int cooldown_seconds=MathMax(1,InpZoneAlertCooldownMinutes)*60;
   if(ZoneAlertInCooldown(key,now,cooldown_seconds) ||
      ZoneAlertInCooldown(ZoneAlertKey("EARLY",zone),now,120))
      return;

   string zone_type=(zone.kind==ZONE_RESISTANCE ? "resistencia" : "soporte");
   string message="ZONA M5 ALCANZADA — NO ES ENTRADA\n"+
                  _Symbol+" | posible "+zone_type+
                  "\nZona: "+DoubleToString(zone.lower,_Digits)+" - "+DoubleToString(zone.upper,_Digits)+
                  "\nReacciones M5 detectadas: "+IntegerToString(zone.touches)+
                  "\nObserva si M1 rechaza la zona o la rompe. La zona sola no confirma el movimiento.";
   ObserveZoneAlert("M5_REACHED",zone);
   if(InpEnableDesktopAlerts) Alert(message);
   if(InpPlayAlertSound && InpEnableDesktopAlerts)
      PlaySound(InpAlertSoundFile);
   Print("ZONA ALCANZADA: posible ",zone_type," M5 | reacciones: ",zone.touches,
         " | espera confirmación M1; no es una entrada.");
   RememberZoneAlert(key,now);
   g_last_zone_alert_time=now;
   g_last_zone_alert_bar=closed_bar;
  }

// One M1 candle may span several bands during a spike. Alert only the band
// nearest the previous close, rather than flooding MT5 with every crossed zone.
void NotifyClosestQualifiedZoneReached(const MqlRates &m1[])
  {
   if(!InpEnableZoneApproachAlerts || InpMaxDrawnZonesPerType<=0 || ArraySize(m1)<3)
      return;
   Zone best;
   best.valid=false;
   double best_distance=DBL_MAX;
   for(int type=0; type<2; type++)
     {
      ZoneKind kind=(type==0 ? ZONE_SUPPORT : ZONE_RESISTANCE);
      double centers[];
      int reaction_counts[];
      double tolerance=0.0;
      int count=CollectQualifiedZones(PERIOD_M5,kind,InpScanBarsM5,
                                       centers,reaction_counts,tolerance,true);
      int maximum=MathMin(InpMaxDrawnZonesPerType,count);
      for(int selected=0; selected<maximum; selected++)
        {
         Zone zone;
         zone.valid=true;
         zone.kind=kind;
         zone.center=centers[selected];
         zone.lower=zone.center-tolerance;
         zone.upper=zone.center+tolerance;
         zone.touches=reaction_counts[selected];
         zone.timeframe=PERIOD_M5;
         if(!ClosedM1TouchesZone(zone,m1))
            continue;
         double distance=0.0;
         if(m1[2].close<zone.lower)
            distance=zone.lower-m1[2].close;
         else if(m1[2].close>zone.upper)
            distance=m1[2].close-zone.upper;
         if(!best.valid || distance<best_distance ||
            (distance==best_distance && zone.touches>best.touches))
           {
            best=zone;
            best_distance=distance;
           }
        }
     }
   if(best.valid)
      NotifyZoneReached(best,m1);
  }

// Intrabar warning: price is close to a confirmed M5 band, but there is no
// candle confirmation or trading signal yet. The cached list avoids scanning
// 180 M5 candles on every tick.
void NotifyEarlyZoneWarning()
  {
   if(!InpEnableEarlyZoneWarnings ||
      InpMaxDrawnZonesPerType<=0 || EarlyDistance()<0.0)
      return;
   if(g_last_signal_bar==iTime(_Symbol,PERIOD_M1,1))
      return;
   if(g_last_candidate_time>0 && TimeCurrent()-g_last_candidate_time<60)
      return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0.0)
      return;
   Zone best;
   best.valid=false;
   double best_distance=DBL_MAX;
   for(int type=0; type<2; type++)
     {
      ZoneKind kind=(type==0 ? ZONE_SUPPORT : ZONE_RESISTANCE);
      int available=(type==0 ? ArraySize(g_early_support_centers)
                             : ArraySize(g_early_resistance_centers));
      int maximum=MathMin(InpMaxDrawnZonesPerType,available);
      for(int selected=0; selected<maximum; selected++)
        {
         Zone zone;
         zone.valid=true;
         zone.kind=kind;
         zone.center=(type==0 ? g_early_support_centers[selected]
                               : g_early_resistance_centers[selected]);
         double tolerance=(type==0 ? g_early_support_tolerance
                                    : g_early_resistance_tolerance);
         zone.lower=zone.center-tolerance;
         zone.upper=zone.center+tolerance;
         zone.touches=(type==0 ? g_early_support_reactions[selected]
                               : g_early_resistance_reactions[selected]);
         zone.timeframe=PERIOD_M5;
         bool near=(kind==ZONE_SUPPORT
                    ? tick.bid>=zone.lower && tick.bid<=zone.upper+EarlyDistance()
                    : tick.bid<=zone.upper && tick.bid>=zone.lower-EarlyDistance());
         if(!near)
            continue;
         double distance=MathAbs(tick.bid-zone.center);
         if(!best.valid || distance<best_distance)
           {
            best=zone;
            best_distance=distance;
           }
        }
     }
   if(!best.valid)
      return;
   datetime now=TimeCurrent();
   if(g_last_zone_alert_time>0 && now-g_last_zone_alert_time<60)
      return;
   if(g_last_early_warning_time>0 && now-g_last_early_warning_time<60)
      return;
   string key=ZoneAlertKey("EARLY",best);
   if(ZoneAlertInCooldown(key,now,MathMax(1,InpZoneAlertCooldownMinutes)*60))
      return;
   string zone_type=(best.kind==ZONE_RESISTANCE ? "resistencia" : "soporte");
   string message="ZONA M5 CERCA — VIGILA, NO ES ENTRADA\n"+
                  _Symbol+" | posible "+zone_type+
                  "\nPrecio: "+DoubleToString(tick.bid,_Digits)+
                  " | zona: "+DoubleToString(best.lower,_Digits)+" - "+
                  DoubleToString(best.upper,_Digits)+
                  "\nAviso anticipado; espera la reacción y confirmación M1.";
   ObserveZoneAlert("M5_NEAR",best);
   if(InpEnableDesktopAlerts) Alert(message);
   if(InpPlayAlertSound && InpEnableDesktopAlerts)
      PlaySound(InpAlertSoundFile);
   Print("ZONA M5 CERCA: posible ",zone_type," | ",
         DoubleToString(best.lower,_Digits)," - ",DoubleToString(best.upper,_Digits),
         " | aviso anticipado; no es entrada.");
   RememberZoneAlert(key,now);
   g_last_early_warning_time=now;
  }

// Experimental Boom N: a previous upswing, return to an observed M5 support,
// then a small live bounce. The second upswing has NOT been confirmed.
void NotifyBoomEarlyNCandidate()
  {
   if(!InpEnableBoomEarlyNCandidate || !IsBoomSymbol())
      return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0.0 || tick.ask<=0.0)
      return;
   int available=MathMin(InpMaxDrawnZonesPerType,ArraySize(g_early_support_centers));
   if(available<=0)
      return;
   int bars=MathMax(12,InpBoomNLookbackM1);
   datetime current_bar=iTime(_Symbol,PERIOD_M1,0);
   if(current_bar!=g_boom_cache_bar)
     {
      if(!LoadRates(PERIOD_M1,bars,g_boom_m1)) return;
      g_boom_cache_bar=current_bar;
      g_boom_live_low=g_boom_m1[0].low;
     }
   g_boom_live_low=MathMin(g_boom_live_low,tick.bid);
   for(int selected=0; selected<available; selected++)
     {
      Zone zone;
      zone.valid=true;
      zone.kind=ZONE_SUPPORT;
      zone.timeframe=PERIOD_M5;
      zone.center=g_early_support_centers[selected];
      zone.lower=zone.center-g_early_support_tolerance;
      zone.upper=zone.center+g_early_support_tolerance;
      zone.touches=g_early_support_reactions[selected];
      double width=MathMax(_Point,zone.upper-zone.lower);
      double recent_low=MathMin(g_boom_live_low,g_boom_m1[1].low);
      if(recent_low<zone.lower-0.25*width || recent_low>zone.upper ||
         tick.bid<recent_low+InpBoomNMinBounceZoneWidths*width ||
         tick.ask>zone.upper+width || tick.bid>zone.upper+width)
         continue;
      double prior_high=0.0;
      for(int shift=3; shift<bars; shift++)
         prior_high=MathMax(prior_high,g_boom_m1[shift].high);
      if(prior_high<zone.upper+InpBoomNMinImpulseZoneWidths*width)
         continue;
      datetime now=TimeCurrent();
      string key=ZoneAlertKey("BOOM_N_EARLY",zone);
      int cooldown=MathMax(1,InpCandidateCooldownMinutes)*60;
      if((g_last_candidate_time>0 && now-g_last_candidate_time<cooldown) ||
         ZoneAlertInCooldown(key,now,cooldown))
         continue;
      if(!RecordObservation("BOOM_N_EARLY","BUY",zone,TREND_NONE,TREND_NONE,TREND_NONE,
                            "Candidato provisional; medición a horizonte fijo",tick,0.0,0.0,
                            iTime(_Symbol,PERIOD_M5,0),true)) continue;
      RememberZoneAlert(key,now);
      g_last_candidate_time=now;
      if(!InpEnableDesktopAlerts) return;
      string message="POSIBLE ENTRADA N EN BOOM — DEMO, SIN CONFIRMAR\n"+
                     _Symbol+" | rebote inicial en soporte M5 ("+IntegerToString(zone.touches)+" reacciones)\n"+
                     "Zona: "+DoubleToString(zone.lower,_Digits)+" - "+DoubleToString(zone.upper,_Digits)+
                     " | precio compra: "+DoubleToString(tick.ask,_Digits)+
                     "\nHubo subida previa y retroceso. Una nueva subida NO esta garantizada; no abre operaciones.";
      Print("CANDIDATO N BOOM: rebote temprano en soporte M5 | precio ",
            DoubleToString(tick.ask,_Digits)," | zona ",DoubleToString(zone.lower,_Digits),
            " - ",DoubleToString(zone.upper,_Digits)," | no confirmado.");
      Alert(message);
      if(InpPlayAlertSound)
         PlaySound(InpAlertSoundFile);
      return;
     }
  }

// Crash can fall without retesting a broken context_floor. Use the last ten hours of
// CLOSED M5 candles as context, but warn on the first live, nearby break.
// This is a provisional continuation candidate, not a spike forecast.
void LogCrashBreakDiagnostic(const string reason,const double price)
  {
   if(!InpLogCrashCandidateDiagnostics)
      return;
   datetime current_m5=iTime(_Symbol,PERIOD_M5,0);
   if(current_m5==0 || current_m5==g_last_crash_break_diagnostic_m5)
      return;
   g_last_crash_break_diagnostic_m5=current_m5;
   Print("CRASH_CANDIDATE_DIAG: ",reason,
         " | piso M5 ",DoubleToString(g_crash_floor,_Digits),
         " | precio ",DoubleToString(price,_Digits),
         " | rango medio M5 ",DoubleToString(g_crash_average_range,_Digits));
  }

void RefreshCrashTrendContext()
  {
   if(!InpEnableCrashTrendCandidate || !IsCrashSymbol())
      return;
   datetime current_m5=iTime(_Symbol,PERIOD_M5,0);
   if(current_m5==0 || current_m5==g_last_crash_context_m5)
      return;
   g_crash_context_down=false;
   g_crash_floor=0.0;
   int context=MathMax(24,InpCrashContextM5Bars);
   int lookback=MathMax(4,MathMin(InpCrashBreakLookbackM5,context-2));
   MqlRates m5[];
   if(!LoadRates(PERIOD_M5,context+1,m5))
     {
      if(InpLogCrashCandidateDiagnostics && current_m5!=g_last_crash_missing_history_m5)
        {
         g_last_crash_missing_history_m5=current_m5;
         Print("CRASH_CONTEXT_DIAG: historial M5 insuficiente | se requieren ",
               context," velas M5 cerradas");
        }
      return;
     }
   g_last_crash_context_m5=current_m5;
   if(m5[1].close>=m5[13].close || m5[1].close>=m5[4].close)
     {
      if(InpLogCrashCandidateDiagnostics)
         Print("CRASH_CONTEXT_DIAG: sin debilidad reciente en cierres M5 (15/60 min)");
      return;
     }
   double context_high=-DBL_MAX,context_low=DBL_MAX;
   for(int shift=1; shift<=context; shift++)
     {
      context_high=MathMax(context_high,m5[shift].high);
      context_low=MathMin(context_low,m5[shift].low);
     }
   if(context_high<=context_low || m5[1].close>=(context_high+context_low)/2.0)
     {
      if(InpLogCrashCandidateDiagnostics)
         Print("CRASH_CONTEXT_DIAG: cierre M5 fuera de la mitad inferior del rango de contexto");
      return;
     }
   double context_floor=DBL_MAX,average_range=0.0;
   for(int shift=1; shift<=lookback; shift++)
     {
      context_floor=MathMin(context_floor,m5[shift].low);
      average_range+=m5[shift].high-m5[shift].low;
     }
   average_range/=lookback;
   if(InpUseMedianRangeScale) average_range=StructureRangeAt(m5,1,lookback,true);
   if(average_range<=_Point)
     {
      if(InpLogCrashCandidateDiagnostics)
         Print("CRASH_CONTEXT_DIAG: rango M5 medio insuficiente");
      return;
     }
   g_crash_floor=context_floor;
   g_crash_average_range=average_range;
   g_crash_context_minutes=context*5;
   g_crash_context_down=true;
   if(InpLogCrashCandidateDiagnostics)
      Print("CRASH_CONTEXT_DIAG: contexto bajista habilitado | piso M5 ",
            DoubleToString(g_crash_floor,_Digits)," | ",g_crash_context_minutes,
            " minutos cerrados");
  }

void NotifyCrashTrendCandidate()
  {
   if(!InpEnableCrashTrendCandidate || !IsCrashSymbol() ||
      !g_crash_context_down)
      return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0.0)
      return;
   double price_margin=MathMax(_Point,MathMax(BreakMargin(),
                                        0.10*g_crash_average_range));
   if(tick.bid>=g_crash_floor-price_margin)
      return;
   // Only diagnose a breached context_floor. No alerts or orders are generated here.
   if(iOpen(_Symbol,PERIOD_M5,0)<g_crash_floor-price_margin)
     {
      LogCrashBreakDiagnostic("ruptura previa al inicio de la vela M5",tick.bid);
      return;
     }
   if(g_crash_floor-tick.bid>0.50*g_crash_average_range)
     {
      LogCrashBreakDiagnostic("caida ya alejada del piso M5",tick.bid);
      return;
     }
   if(iHigh(_Symbol,PERIOD_M5,0)-iLow(_Symbol,PERIOD_M5,0)>1.50*g_crash_average_range)
     {
      LogCrashBreakDiagnostic("vela M5 excepcionalmente amplia",tick.bid);
      return;
     }
   datetime now=TimeCurrent();
   string key="CRASH_TREND_"+DoubleToString(g_crash_floor,_Digits);
   int cooldown=MathMax(1,InpCandidateCooldownMinutes)*60;
   if((g_last_candidate_time>0 && now-g_last_candidate_time<cooldown) ||
      ZoneAlertInCooldown(key,now,cooldown))
     {
      LogCrashBreakDiagnostic("en enfriamiento de avisos",tick.bid);
      return;
     }
   Zone candidate_zone=MakeZone(PERIOD_M5,ZONE_SUPPORT,g_crash_floor,price_margin,0);
   if(!RecordObservation("CRASH_TREND_EARLY","SELL",candidate_zone,TREND_DOWN,TREND_NONE,TREND_NONE,
                         "Ruptura provisional; medición a horizonte fijo",tick,0.0,0.0,
                         iTime(_Symbol,PERIOD_M5,0),true)) return;
   RememberZoneAlert(key,now);
   g_last_candidate_time=now;
   if(!InpEnableDesktopAlerts) return;
   string message="POSIBLE ENTRADA BAJISTA EN CRASH — DEMO, SIN CONFIRMAR\n"+
                  _Symbol+" | tendencia bajista; acaba de romper piso M5\n"+
                  "Piso: "+DoubleToString(g_crash_floor,_Digits)+" | precio: "+DoubleToString(tick.bid,_Digits)+
                  "\nContexto: "+IntegerToString(g_crash_context_minutes/60)+" h de velas M5 cerradas. Puede ser falsa ruptura; no abre operaciones.";
   Print("CANDIDATO CRASH BAJISTA: ruptura temprana de piso M5 ",
         DoubleToString(g_crash_floor,_Digits)," | precio ",DoubleToString(tick.bid,_Digits),
         " | contexto ",g_crash_context_minutes," minutos | no confirmado.");
   Alert(message);
   if(InpPlayAlertSound)
      PlaySound(InpAlertSoundFile);
  }

// A rejection without all gates remains a partial observation, never a full signal.
void NotifyRejectedCrashCandidate(const Zone &zone,const string reason)
  {
   if(!ActivePack()) return;
   Print("RECHAZO M1 EN RESISTENCIA M5: candidato Crash venta descartado | ",reason);
   if(!InpEnableDesktopAlerts)
      return;
   datetime now=TimeCurrent();
   string key=DoubleToString(zone.center,_Digits);
   int cooldown_seconds=MathMax(1,InpZoneAlertCooldownMinutes)*60;
   if(key==g_last_rejection_notice_key && g_last_rejection_notice_time>0 &&
      now-g_last_rejection_notice_time<cooldown_seconds)
      return;
   string message="RECHAZO M1 EN RESISTENCIA — SIN SEÑAL COMPLETA\n"+
                  _Symbol+" | venta candidata, no es una entrada\n"+
                  "Zona: "+DoubleToString(zone.lower,_Digits)+" - "+DoubleToString(zone.upper,_Digits)+
                  "\nMotivo: "+reason;
   Alert(message);
   if(InpPlayAlertSound)
      PlaySound(InpAlertSoundFile);
   g_last_rejection_notice_key=key;
   g_last_rejection_notice_time=now;
  }

// A double top/bottom remains a separately measured hypothesis.  It only returns a
// candidate after two confirmed swings on M15 and a closed M1 neckline break.
bool FindDoublePattern(const bool top,Zone &pattern_zone,double &neckline)
  {
   pattern_zone.valid=false;
   pattern_zone.kind=(top ? ZONE_RESISTANCE : ZONE_SUPPORT);
   pattern_zone.timeframe=PERIOD_M15;
   neckline=0.0;

   MqlRates rates[];
   if(!LoadRates(PERIOD_M15,InpScanBarsM15,rates))
      return false;

   int recent_shift=-1;
   int older_shift=-1;
   for(int shift=InpPivotStrength+1; shift<ArraySize(rates)-InpPivotStrength; shift++)
     {
      bool pivot=(top ? IsPivotHigh(rates,shift,InpPivotStrength) : IsPivotLow(rates,shift,InpPivotStrength));
      if(!pivot)
         continue;
      if(recent_shift<0)
         recent_shift=shift;
      else
        {
         older_shift=shift;
         break;
        }
     }
   if(recent_shift<0 || older_shift<0)
      return false;

   double recent_price=(top ? rates[recent_shift].high : rates[recent_shift].low);
   double older_price=(top ? rates[older_shift].high : rates[older_shift].low);
   const double tolerance=ZoneHalfWidth(rates);
   if(MathAbs(recent_price-older_price)>tolerance)
      return false;

   double middle=(top ? DBL_MAX : -DBL_MAX);
   for(int shift=recent_shift; shift<=older_shift; shift++)
     {
      if(top && rates[shift].low<middle)
         middle=rates[shift].low;
      if(!top && rates[shift].high>middle)
         middle=rates[shift].high;
     }
   if(middle==DBL_MAX || middle==-DBL_MAX)
      return false;

   pattern_zone.valid=true;
   pattern_zone.center=(recent_price+older_price)/2.0;
   pattern_zone.lower=pattern_zone.center-tolerance;
   pattern_zone.upper=pattern_zone.center+tolerance;
   pattern_zone.touches=2;
   neckline=middle;
   return true;
  }

bool ClosedM1BreaksNeckline(const bool top,const double neckline,const MqlRates &m1[])
  {
   const double price_margin=BreakMargin();
   if(top)
      return (m1[2].close>=neckline-price_margin && m1[1].close<neckline-price_margin && m1[1].close<m1[1].open);
   return (m1[2].close<=neckline+price_margin && m1[1].close>neckline+price_margin && m1[1].close>m1[1].open);
  }

// Shared durable observation writer. One module/side/TF event per candle;
// overlapping bands and band-width drift cannot manufacture extra episodes.
bool RecordObservation(const string module,const string side,const Zone &zone,
                       const Trend m5,const Trend m15,const Trend h1,const string details,
                       const MqlTick &quote,const double stop,const double target,
                       const datetime event_bar,const bool candidate)
  {
   if(quote.bid<=0.0 || quote.ask<quote.bid || quote.time_msc<=0 || _Point<=0.0 ||
      (side!="BUY" && side!="SELL"))
     { g_last_gate="QUOTE_OR_STALE"; g_last_signal_rejection_reason="cotización o dirección inválida"; return false; }
   int slot=FreePendingSlot();
   if(slot<0) { g_last_gate="OTHER"; g_last_signal_rejection_reason="capacidad de seguimiento agotada"; return false; }
   bool alert=g_record_zone_alert;
   string filename=alert ? g_alerts_file : (candidate ? g_candidates_file : g_signals_file);
   string id=_Symbol+"_"+OBSERVER_RULE_VERSION+"_"+RulePackText()+"_"+module+"_"+side+"_"+
             IntegerToString((long)event_bar)+"_"+EnumToString(zone.timeframe);
   double zone_quantum=MathMax(_Point,zone.upper-zone.lower);
   id+="_"+IntegerToString((long)MathFloor(zone.center/zone_quantum));
   id=VariantsRecordID(id,module);
   string values[];
   ArrayResize(values,OBSERVER_SIGNAL_COLUMNS);
   double entry=side=="BUY" ? quote.ask : quote.bid;
   double risk=candidate ? 0.0 : MathAbs(entry-stop)/_Point;
   double reward=candidate ? 0.0 : MathAbs(target-entry)/_Point;
   long deadline=quote.time_msc+(long)(alert ? InpZoneObservationMinutes : (candidate ? InpCandidateObservationMinutes : InpOutcomeMaxBars))*60000;
   values[0]=id; values[1]=TimeToString(event_bar,TIME_DATE|TIME_SECONDS);
   values[2]=_Symbol; values[3]=OBSERVER_RULE_VERSION; values[4]=module; values[5]=side;
   values[6]=EnumToString(zone.timeframe); values[7]=EnumToString(zone.kind);
   values[8]=DoubleToString(zone.center,_Digits); values[9]=DoubleToString(zone.lower,_Digits);
   values[10]=DoubleToString(zone.upper,_Digits); values[11]=IntegerToString(zone.touches);
   values[12]=DoubleToString(entry,_Digits); values[13]=(candidate || alert) ? "" : DoubleToString(stop,_Digits);
   values[14]=(candidate || alert) ? "" : DoubleToString(target,_Digits);
   values[15]=(candidate || alert) ? "" : DoubleToString(risk,5);
   values[16]=(candidate || alert) ? "" : DoubleToString(reward,5);
   values[17]=(candidate || alert) ? "" : DoubleToString(reward/risk,5);
   values[18]=EnumToString(m5); values[19]=EnumToString(m15); values[20]=EnumToString(h1);
   values[21]=details; values[22]=IntegerToString(quote.time_msc);
   values[23]=IntegerToString(deadline);
   values[24]=alert ? "ZONE_REACTION_CLOSE_M5" : (candidate ? "CANDIDATE_FIXED_HORIZON" : "TICK_QUOTES_NO_COMMISSION");
   values[25]=IntegerToString((long)InpMaxTickGapSeconds*1000); values[26]=DoubleToString(_Point,10);
   values[27]=alert ? "ZONE_ALERT" : (candidate ? "CANDIDATE" : "SIGNAL");
   string context5[],context15[];
   StructureCsvValues(entry,0,context5); StructureCsvValues(entry,1,context15);
   for(int k=0;k<12;k++) { values[28+k]=context5[k]; values[40+k]=context15[k]; }
   values[52]=InpUseMedianRangeScale ? "MEDIAN" : "MEAN";
   values[53]=_Symbol+"_"+side+"_"+IntegerToString((long)event_bar); // correlated modules share event
   values[54]=DoubleToString((quote.ask-quote.bid)/_Point,5);
   values[55]=candidate ? "MEASURE_ONLY" : (InpUseStructurePositionFilter ? "ON" : "OFF");
   values[56]=EnumToString(InpStructureFilterTimeframe);
   values[57]=DoubleToString(InpStructureEdgePercent,5);
   values[58]=RulePackText(); values[59]="1600.1";
   MqlRates metadata_rates[];
   double median=LoadRates(PERIOD_M5,InpZoneRangeLookback+2,metadata_rates) ? StructureRangeAt(metadata_rates,1,InpZoneRangeLookback,true) : 0.0;
   values[60]=median>0.0 ? DoubleToString((zone.upper-zone.lower)/median,5) : "";
   values[61]=IntegerToString(BarsSinceLastZoneTouch(zone)); values[62]=median>0.0 ? DoubleToString(median,_Digits) : "";
   values[63]=g_last_spike_time>0 && quote.time_msc>=(long)g_last_spike_time*1000 ? DoubleToString((quote.time_msc/1000.0-g_last_spike_time)/60.0,3) : "";
   MqlDateTime calendar; TimeToStruct((datetime)(quote.time_msc/1000),calendar);
   values[64]=IntegerToString(calendar.hour); values[65]=IntegerToString(calendar.day_of_week);
   values[66]=DoubleToString(g_record_sweep_depth,5); values[67]=candidate || alert ? "" : DoubleToString(g_record_legacy_stop>0.0 ? g_record_legacy_stop : stop,_Digits);
   values[68]=g_record_volume>0.0 ? DoubleToString(g_record_volume,8) : ""; values[69]=g_record_volume>0.0 ? DoubleToString(g_record_risk_usd,5) : "";
   values[70]=g_record_risk_exceeds ? "1" : "0"; values[71]=g_record_leg_spike ? "1" : "0";
   values[72]=g_record_control ? "1" : "0"; values[73]=IntegerToString(g_record_seed);
   values[74]=DoubleToString(zone.center,_Digits); values[75]=RulePackText()+"|"+DoubleToString(InpMinimumRewardRisk,5);
   values[76]=values[27]; values[77]=DoubleToString(BreakMargin(),_Digits); values[78]=DoubleToString(target,_Digits);
   values[79]=IntegerToString(g_spike_seeds_excluded);
   values[80]=context5[0]=="CONFIRMED" ? "1" : "0"; values[81]=context15[0]=="CONFIRMED" ? "1" : "0";
   values[82]=context5[6]; values[83]=context15[6]; values[84]=values[53];
   int handle=OpenCsvRetry(filename,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON,';',CP_UTF8);
   if(handle==INVALID_HANDLE) { g_last_gate="PERSISTENCE"; g_last_signal_rejection_reason="CSV no disponible"; return false; }
   bool empty=FileSize(handle)==0;
   string row[];
   while(ReadCsvRow(handle,row))
     {
      if(ArraySize(row)!=OBSERVER_SIGNAL_COLUMNS) { RecoveryIssue(filename,0,"fila incompatible ignorada al deduplicar"); continue; }
      bool duplicate=row[0]==id;
      if(candidate && row[2]==_Symbol && row[4]==module && row[5]==side &&
         row[6]==EnumToString(zone.timeframe) && MathFloor(StringToDouble(row[8])/zone_quantum)==MathFloor(zone.center/zone_quantum) &&
         quote.time_msc-StringToInteger(row[22])<(long)MathMax(1,InpCandidateCooldownMinutes)*60000)
         duplicate=true;
      if(duplicate) { FileClose(handle); g_last_gate="DUPLICATE"; g_last_signal_rejection_reason="episodio ya registrado"; return false; }
     }
   FileSeek(handle,0,SEEK_END);
   string header="signal_id;timestamp;symbol;rule_version;module;side;zone_tf;zone_kind;zone_center;zone_lower;zone_upper;touches;entry_theoretical;sl_theoretical;tp_theoretical;risk_points;reward_points;reward_risk;trend_m5;trend_m15;trend_h1;details;entry_time_msc;deadline_msc;execution_model;max_tick_gap_msc;point_size;record_kind";
   header+=";m5_context_status;m5_cycle_id;m5_known_at;m5_floor;m5_ceiling;m5_width;m5_position_pct;m5_distance_floor;m5_distance_ceiling;m5_trimmed_floor;m5_trimmed_ceiling;m5_spike_bars";
   header+=";m15_context_status;m15_cycle_id;m15_known_at;m15_floor;m15_ceiling;m15_width;m15_position_pct;m15_distance_floor;m15_distance_ceiling;m15_trimmed_floor;m15_trimmed_ceiling;m15_spike_bars";
   header+=";range_scale;event_id;entry_spread_points;structure_filter;structure_filter_tf;structure_edge_pct;rule_pack;schema_version;zone_width_ranges;bars_since_last_touch;m5_range_median;minutes_since_last_spike;hour_server;weekday;sweep_depth_widths;sl_legacy;volume_ref;risk_usd_ref;risk_exceeds_budget;leg_is_spike;is_control;control_seed;zone_key;signal_config;observation_kind;break_margin;zone_target;spike_seed_excluded;struct_cycle_confirmed_m5;struct_cycle_confirmed_m15;struct_pos_m5_pct;struct_pos_m15_pct;cluster_id";
   if(empty && FileWriteString(handle,header+"\r\n")==0) { FileClose(handle); g_last_gate="PERSISTENCE"; g_last_signal_rejection_reason="error escribiendo cabecera"; return false; }
   uint written=FileWriteString(handle,CsvLine(values));
   FileFlush(handle); FileClose(handle);
   if(written==0) { g_last_gate="PERSISTENCE"; g_last_signal_rejection_reason="error escribiendo observación"; return false; }
   PendingSignal pending;
   InitPendingSignal(pending);
   pending.active=true; pending.id=id; pending.signal_time=event_bar;
   pending.module=module; pending.side=side; pending.entry=entry; pending.stop=stop; pending.target=target;
   pending.entry_msc=quote.time_msc; pending.cursor_msc=quote.time_msc+1;
   pending.last_quote_msc=quote.time_msc; pending.deadline_msc=deadline;
   pending.max_gap_msc=(long)InpMaxTickGapSeconds*1000; pending.point_size=_Point;
   pending.rule_version=OBSERVER_RULE_VERSION; pending.rule_pack=RulePackText();
   pending.outcome_file=alert ? g_alert_outcomes_file : (candidate ? g_candidate_outcomes_file : g_outcomes_file);
   pending.observation_kind=values[76]; pending.zone_lower=zone.lower; pending.zone_upper=zone.upper; pending.break_margin=BreakMargin();
   pending.is_control=g_record_control; pending.control_seed=g_record_seed; pending.spike_dir="NONE";
   pending.measurement_only=candidate; pending.mae_points=(quote.ask-quote.bid)/_Point;
   g_pending[slot]=pending;
   if(alert) { g_ops_last_alert=id; g_ops_last_alert_msc=quote.time_msc; }
   return true;
  }

bool WriteSignal(const string module,const string side,const Zone &zone,const Trend m5,const Trend m15,
                 const Trend h1,const MqlRates &m1[],const string details)
  {
   g_last_signal_rejection_reason="";
   g_last_gate="OTHER";
   datetime signal_bar=iTime(_Symbol,PERIOD_M1,1);
   MqlTick quote;
   if(!SymbolInfoTick(_Symbol,quote) || quote.bid<=0.0 || quote.ask<quote.bid ||
      quote.time_msc<(long)(signal_bar+60)*1000 ||
      quote.time_msc>(long)(signal_bar+120)*1000)
     {
      g_last_signal_rejection_reason="cotización ausente o señal M1 obsoleta";
      g_last_gate="QUOTE_OR_STALE";
      return RejectSignal(module,side,zone,signal_bar,g_last_signal_rejection_reason);
     }
   double entry=(side=="BUY" ? quote.ask : quote.bid);
    if(!StrategyM15DirectionAllowed(_Symbol,side,m15))
     {
       g_last_signal_rejection_reason="tendencia M15 no confirma dirección del símbolo";
       g_last_gate="M15_DIRECTION";
      return RejectSignal(module,side,zone,signal_bar,g_last_signal_rejection_reason);
     }
   if(InpMaxSignalGapZoneWidths>0.0)
     {
      double zone_width=MathMax(_Point,zone.upper-zone.lower);
      double gap=(side=="SELL" ? MathMax(0.0,zone.lower-entry)
                               : MathMax(0.0,entry-zone.upper));
      if(gap>zone_width*InpMaxSignalGapZoneWidths)
        {
         g_last_signal_rejection_reason="el precio ya quedó lejos de la zona tras la vela M1";
         g_last_gate="ENTRY_DISTANCE";
         Print("SEÑAL TARDÍA DESCARTADA: ",SimpleModuleText(module,side)," | ",
               g_last_signal_rejection_reason," | distancia ",DoubleToString(gap,_Digits),
               " | máximo ",DoubleToString(zone_width*InpMaxSignalGapZoneWidths,_Digits));
         return RejectSignal(module,side,zone,signal_bar,g_last_signal_rejection_reason);
        }
     }
   double stop=(side=="SELL" ? MathMax(m1[1].high,zone.upper)+StopBuffer()
                                : MathMin(m1[1].low,zone.lower)-StopBuffer());
   g_record_legacy_stop=stop;
   double target=(module=="CRASH_RESISTANCE_REJECTION"
                  ? NearestCurrentM5SupportTarget(entry)
                  : NearestTargetPrice(side,entry));
   OperationsSignalLevels(module,entry,stop,target);
   g_record_legacy_stop=stop;
   double risk_points=MathAbs(entry-stop)/_Point;
   double reward_points=(target>0.0 ? MathAbs(target-entry)/_Point : 0.0);
   if(target<=0.0)
     {
      g_last_gate="TARGET_MISSING";
      if(module=="CRASH_RESISTANCE_REJECTION")
         g_last_signal_rejection_reason="no hay un soporte M5 activo y visible debajo como objetivo";
      else
         g_last_signal_rejection_reason=(side=="SELL" ? "no se encontró soporte objetivo inferior"
                                                       : "no se encontró resistencia objetivo superior");
      Print("CONFIGURACIÓN DESCARTADA: ",SimpleModuleText(module,side)," | ",g_last_signal_rejection_reason);
      return RejectSignal(module,side,zone,signal_bar,g_last_signal_rejection_reason);
     }
   if((side=="BUY" && (stop>=entry || target<=entry)) ||
      (side=="SELL" && (stop<=entry || target>=entry)) ||
      risk_points<=0.0 || reward_points/risk_points<InpMinimumRewardRisk)
     {
      g_last_signal_rejection_reason="la relación ganancia/riesgo teórica no alcanza "+DoubleToString(InpMinimumRewardRisk,2);
      g_last_gate="REWARD_RISK";
      Print("CONFIGURACIÓN DESCARTADA: ",SimpleModuleText(module,side),
            " | ",g_last_signal_rejection_reason);
      return RejectSignal(module,side,zone,signal_bar,g_last_signal_rejection_reason);
     }
   if(!StructurePositionAllowed(side,entry))
     { g_last_gate="STRUCTURE_POSITION"; g_last_signal_rejection_reason="filtro de posición: borde del rango o contexto no confirmado"; return RejectSignal(module,side,zone,signal_bar,g_last_signal_rejection_reason); }
   if(!RecordObservation(module,side,zone,m5,m15,h1,details,quote,stop,target,signal_bar,false)) return RejectSignal(module,side,zone,signal_bar,g_last_signal_rejection_reason);
   Print("SEÑAL OBSERVADA: ",SimpleModuleText(module,side)," | ",details);
   NotifySignal(module,side,entry,zone);
   if(ActivePack()) g_last_signal_bar=signal_bar;
   return true;
  }

void EvaluatePackSignals()
  {
   MqlRates m1[];
   if(!LoadRates(PERIOD_M1,InpScanBarsM1,m1))
      return;

   Trend trend_m5=DetectTrend(PERIOD_M5,InpScanBarsM5);
   Trend trend_m15=DetectTrend(PERIOD_M15,InpScanBarsM15);
   Trend trend_h1=DetectTrend(PERIOD_H1,InpScanBarsH1);
   if(ActivePack()) OperationsCacheTrends(trend_m5,trend_m15,trend_h1);
   if(ActivePack()) NotifyClosestQualifiedZoneReached(m1);

   // Every nearby drawn band is evaluated, with independent module/zone IDs.
   for(int tf_index=0;tf_index<2;tf_index++)
     {
      ENUM_TIMEFRAMES tf=(tf_index==0 ? PERIOD_M5 : PERIOD_M15);
      int bars=(tf_index==0 ? InpScanBarsM5 : InpScanBarsM15);
      for(int type=0;type<2;type++)
        {
         ZoneKind kind=(type==0 ? ZONE_SUPPORT : ZONE_RESISTANCE);
         double centers[],tolerance=0.0;
         int touches[];
         int count=CollectQualifiedZones(tf,kind,bars,centers,touches,tolerance,tf==PERIOD_M5);
         for(int z=0;z<MathMin(count,InpMaxDrawnZonesPerType);z++)
           {
            Zone zone=MakeZone(tf,kind,centers[z],tolerance,touches[z]);
            bool sell=ClosedM1RejectsBelow(zone,m1);
            bool buy=ClosedM1RejectsAbove(zone,m1);
            if(InpEnableNModule)
              {
               // Break must be a crossing, before the closed retest candle.
               if(sell && m1[2].close<zone.lower-BreakMargin() && BrokeBelowRecently(zone,m1))
                  WriteSignal("N_BREAK_RETEST","SELL",zone,trend_m5,trend_m15,trend_h1,m1,
                              "Cruce bajista previo y retest M1 cerrado de banda activa");
               if(buy && m1[2].close>zone.upper+BreakMargin() && BrokeAboveRecently(zone,m1))
                  WriteSignal("N_BREAK_RETEST","BUY",zone,trend_m5,trend_m15,trend_h1,m1,
                              "Cruce alcista previo y retest M1 cerrado de banda activa");
              }
            if(tf!=PERIOD_M5) continue;
            if(InpEnableCrashDriftBuy && IsCrashSymbol() && kind==ZONE_SUPPORT &&
               buy && trend_m5==TREND_UP && trend_m15==TREND_UP)
               WriteSignal("CRASH_DRIFT","BUY",zone,trend_m5,trend_m15,trend_h1,m1,
                           "EXPERIMENTAL: compra Crash expuesta a spikes bajistas");
            if(InpEnableBoomDriftSell && IsBoomSymbol() && kind==ZONE_RESISTANCE &&
               sell && trend_m5==TREND_DOWN && trend_m15==TREND_DOWN)
               WriteSignal("BOOM_DRIFT","SELL",zone,trend_m5,trend_m15,trend_h1,m1,
                           "EXPERIMENTAL: venta Boom expuesta a spikes alcistas");
            if(InpEnableCrashResistanceSell && IsCrashSymbol() && kind==ZONE_RESISTANCE &&
               sell && m1[2].close<=zone.upper+BreakMargin())
              {
               if(!WriteSignal("CRASH_RESISTANCE_REJECTION","SELL",zone,trend_m5,trend_m15,trend_h1,m1,
                               "Rechazo M1 cerrado debajo de resistencia M5 activa"))
                  NotifyRejectedCrashCandidate(zone,g_last_signal_rejection_reason);
              }
           }
        }
     }

   if(InpEnableDoubleTopBottomCandidate)
     {
      Zone pattern_zone;
      double neckline=0.0;
      if(FindDoublePattern(true,pattern_zone,neckline) && ClosedM1BreaksNeckline(true,neckline,m1))
         WriteSignal("DOUBLE_TOP_BOTTOM_CANDIDATE","SELL",pattern_zone,trend_m5,trend_m15,trend_h1,m1,"doble techo M15 y M1 rompió el nivel intermedio");
      if(FindDoublePattern(false,pattern_zone,neckline) && ClosedM1BreaksNeckline(false,neckline,m1))
         WriteSignal("DOUBLE_TOP_BOTTOM_CANDIDATE","BUY",pattern_zone,trend_m5,trend_m15,trend_h1,m1,"doble piso M15 y M1 rompió el nivel intermedio");
     }
  }

void EvaluateSignals()
  {
   g_eval_pack=InpRulePack;
   EvaluatePackSignals();
   if(InpShadowLegacyRules)
     {
      g_eval_pack=(InpRulePack==RULES_1500 ? RULES_1600 : RULES_1500);
      EvaluatePackSignals();
     }
   g_eval_pack=InpRulePack;
  }

// One immutable history origin per symbol/server and structure configuration.
// Replays extend this history; no oldest bar is silently dropped.
bool LoadAnchoredStructureRates(const ENUM_TIMEFRAMES tf,const int bars,MqlRates &rates[])
  {
   int index=(tf==PERIOD_M5 ? 0 : 1);
   if(g_structure_anchor[index]==0)
     {
      string config=AccountInfoString(ACCOUNT_SERVER)+"|"+_Symbol+"|"+EnumToString(tf)+"|"+
                    IntegerToString(bars)+"|"+IntegerToString(InpStructurePivotStrength)+"|"+
                    IntegerToString(InpStructureRangeLookback)+"|"+DoubleToString(InpStructureMinLegRanges,16)+"|"+
                    IntegerToString((int)InpUseMedianRangeScale)+"|"+InpStructureEpoch;
      uint hash=2166136261;
      for(int i=0;i<StringLen(config);i++) { hash^=StringGetCharacter(config,i); hash*=16777619; }
      string filename=TaggedCsv("BCSO_StructureAnchor_1520_"+IntegerToString(hash)+".csv");
      if(!FileIsExist(filename,FILE_COMMON) && !LoadRates(tf,bars,rates)) return false;
      int handle=OpenCsvRetry(filename,FILE_TXT|FILE_READ|FILE_WRITE|FILE_ANSI|FILE_COMMON,';',CP_UTF8);
      if(handle==INVALID_HANDLE) return false;
      if(FileSize(handle)==0)
        {
         if(ArraySize(rates)<bars) { FileClose(handle); return false; }
         datetime start=rates[ArraySize(rates)-1].time;
         string anchor_row[];
         ArrayResize(anchor_row,2); anchor_row[0]=config; anchor_row[1]=IntegerToString((long)start);
         if(FileWriteString(handle,CsvLine(anchor_row))==0) { FileClose(handle); return false; }
         FileFlush(handle);
         g_structure_anchor[index]=start;
        }
      else
        {
         string row[];
         if(!ReadCsvRow(handle,row) || ArraySize(row)!=2 || row[0]!=config)
           { FileClose(handle); return false; }
         g_structure_anchor[index]=(datetime)StringToInteger(row[1]);
        }
      FileClose(handle);
      if(g_structure_anchor[index]<=0) return false;
     }
   int age=iBarShift(_Symbol,tf,g_structure_anchor[index],true);
   if(age<0 || age>=InpStructureHistoryLimit) return false;
   ArraySetAsSeries(rates,true);
   int copied=CopyRates(_Symbol,tf,g_structure_anchor[index],TimeCurrent(),rates);
   return copied>=bars && rates[copied-1].time==g_structure_anchor[index] &&
          rates[0].time==iTime(_Symbol,tf,0);
  }

// Snapshot uses only fresh closed-period data. Missing/unconfirmed context is
// explicit, never represented as a numerical zero position.
void StructureCsvValues(const double price,const int index,string &values[])
  {
   ArrayResize(values,12);
   for(int i=0;i<12;i++) values[i]="";
   bool ready=g_structure_ready[index] &&
              g_structure_asof[index]==iTime(_Symbol,index==0 ? PERIOD_M5 : PERIOD_M15,1);
   values[0]=ready ? "UNCONFIRMED" : "UNAVAILABLE";
   if(!ready || !g_structure_done[index].valid) return;
   StructureBounds bounds=g_structure_done[index];
   double width=bounds.high-bounds.low;
   if(width<=0.0) return;
   values[0]="CONFIRMED";
   values[1]=IntegerToString((long)bounds.start_time)+"_"+IntegerToString((long)bounds.end_time);
   values[2]=TimeToString(bounds.known_at,TIME_DATE|TIME_SECONDS);
   values[3]=DoubleToString(bounds.low,_Digits);
   values[4]=DoubleToString(bounds.high,_Digits);
   values[5]=DoubleToString(width,_Digits);
   values[6]=DoubleToString(100.0*(price-bounds.low)/width,5); // intentionally not clamped
   values[7]=DoubleToString(price-bounds.low,_Digits);
   values[8]=DoubleToString(bounds.high-price,_Digits);
   if(g_structure_trimmed[index].valid)
     {
      values[9]=DoubleToString(g_structure_trimmed[index].low,_Digits);
      values[10]=DoubleToString(g_structure_trimmed[index].high,_Digits);
      values[11]=IntegerToString(g_structure_spikes[index]);
     }
  }

bool StructurePositionAllowed(const string side,const double price)
  {
   if(!InpUseStructurePositionFilter) return true;
   string context[];
   StructureCsvValues(price,InpStructureFilterTimeframe==PERIOD_M5 ? 0 : 1,context);
   if(context[0]!="CONFIRMED") return false;
   double position=StringToDouble(context[6]);
   if(side=="SELL" && position<=InpStructureEdgePercent) return false;
   if(side=="BUY" && position>=100.0-InpStructureEdgePercent) return false;
   return true;
  }

bool DrawStructureLevel(const string name,const string label,const double price,
                        const datetime left,const datetime right,const color ink,
                        const bool completed,const string details)
  {
   if(!ObjectCreate(0,name,OBJ_TREND,0,left,price,right,price)) return false;
   ObjectSetInteger(0,name,OBJPROP_COLOR,ink);
   ObjectSetInteger(0,name,OBJPROP_STYLE,completed ? STYLE_SOLID : STYLE_DOT);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,completed ? 2 : 1);
   ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,true);
   ObjectSetInteger(0,name,OBJPROP_RAY_LEFT,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,details);
   string text_name=name+"_TEXT";
   if(!ObjectCreate(0,text_name,OBJ_TEXT,0,right,price)) return false;
   ObjectSetInteger(0,text_name,OBJPROP_COLOR,ink);
   ObjectSetInteger(0,text_name,OBJPROP_FONTSIZE,8);
   ObjectSetInteger(0,text_name,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0,text_name,OBJPROP_SELECTABLE,false);
   ObjectSetString(0,text_name,OBJPROP_TEXT,label+" "+DoubleToString(price,_Digits));
   ObjectSetString(0,text_name,OBJPROP_TOOLTIP,details);
   return true;
  }

bool StructurePanelLine(const string name,const int row,const string text,const color ink)
  {
   if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0)) return false;
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,10);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,30+row*16);
   ObjectSetInteger(0,name,OBJPROP_COLOR,ink);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   return true;
  }

bool DrawStructureBounds(const string prefix,const string tf,const StructureBounds &bounds,
                         const bool completed,const color ink,const datetime right)
  {
   string state=completed ? "CICLO CONFIRMADO" : "EN FORMACION";
   string details=tf+" "+state+" | desde "+TimeToString(bounds.start_time,TIME_DATE|TIME_MINUTES)+
                  " hasta "+TimeToString(bounds.end_time,TIME_DATE|TIME_MINUTES)+
                  " | conocido desde "+TimeToString(bounds.known_at,TIME_DATE|TIME_MINUTES)+
                  " | amplitud "+DoubleToString(bounds.high-bounds.low,_Digits);
   bool top=DrawStructureLevel(prefix+"TOP",tf+" TECHO "+state,bounds.high,
                               bounds.start_time,right,ink,completed,details);
   bool bottom=DrawStructureLevel(prefix+"BOTTOM",tf+" PISO "+state,bounds.low,
                                  bounds.start_time,right,ink,completed,details);
   return top && bottom;
  }

bool RefreshStructureTimeframe(const ENUM_TIMEFRAMES timeframe,const int bars,const int panel_row,
                               const color ink,string &last_key)
  {
   string tf=timeframe==PERIOD_M5 ? "M5" : "M15";
   string prefix="BCSO_STRUCT_"+tf+"_";
   int index=timeframe==PERIOD_M5 ? 0 : 1;
   bool draw=index==0 ? InpDrawStructureM5 : InpDrawStructureM15;
   g_structure_ready[index]=false;
   if(draw) DeleteDrawnZones(prefix);
   MqlRates rates[];
   if(!LoadAnchoredStructureRates(timeframe,bars,rates))
     {
      if(draw) StructurePanelLine(prefix+"STATUS",panel_row,tf+" estructura: historial/ancla no disponible",ink);
      return false;
     }
   StructureBounds completed,developing;
   double tick_size=MathMax(_Point,SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE));
   if(!DetectStructureBounds(rates,InpStructurePivotStrength,InpStructureRangeLookback,
                             InpStructureMinLegRanges,tick_size,PeriodSeconds(timeframe),completed,developing,InpUseMedianRangeScale))
     {
      if(draw) StructurePanelLine(prefix+"STATUS",panel_row,tf+" estructura: datos insuficientes",ink);
      return false;
     }
   g_structure_done[index]=completed;
   g_structure_asof[index]=rates[1].time;
   g_structure_ready[index]=true;
   StructureTrimmedEnvelope(rates,completed,InpStructureRangeLookback,InpStructureSpikeMultiple,
                            g_structure_trimmed[index],g_structure_spikes[index]);
   if(!draw) return true;
   // No near-price filter: the complete envelope remains visible at a distance.
   datetime right=TimeCurrent()+PeriodSeconds(PERIOD_M1)*(timeframe==PERIOD_M5 ? 2 : 10);
   bool drawn=true;
   if(completed.valid)
     {
      drawn=DrawStructureBounds(prefix+"DONE_",tf,completed,true,ink,right);
      drawn=StructurePanelLine(prefix+"STATUS",panel_row,tf+" CICLO CONFIRMADO | piso "+
                    DoubleToString(completed.low,_Digits)+" | techo "+DoubleToString(completed.high,_Digits),ink) && drawn;
      string key=IntegerToString((long)completed.start_time)+"_"+IntegerToString((long)completed.end_time)+"_"+
                 DoubleToString(completed.low,_Digits)+"_"+DoubleToString(completed.high,_Digits);
      if(key!=last_key)
        {
         Print("STRUCTURE_CONTEXT | ",_Symbol," | ",tf," | build ",OBSERVER_BUILD_VERSION,
               " | ciclo ",key," | conocido desde ",TimeToString(completed.known_at,TIME_DATE|TIME_MINUTES));
         last_key=key;
        }
     }
   else
      drawn=StructurePanelLine(prefix+"STATUS",panel_row,tf+" SIN CICLO COMPLETO | extremos provisionales",ink);
   drawn=DrawStructureBounds(prefix+"LIVE_",tf,developing,false,ink,right) && drawn;
   drawn=StructurePanelLine(prefix+"FORMING",panel_row+1,tf+" EN FORMACION | piso "+
                 DoubleToString(developing.low,_Digits)+" | techo "+DoubleToString(developing.high,_Digits),ink) && drawn;
   drawn=StructurePanelLine(prefix+"ASOF",panel_row+2,tf+" ultima vela cerrada: "+
                 TimeToString(rates[1].time,TIME_DATE|TIME_MINUTES),ink) && drawn;
   if(!drawn) Print("No se pudieron dibujar todos los extremos de estructura ",tf,". Error ",GetLastError());
   ChartRedraw(0);
   return drawn;
  }

void RefreshStructureContext()
  {
   static datetime last_try=0;
   if(last_try==TimeCurrent()) return;
   last_try=TimeCurrent();
   datetime m5_bar=iTime(_Symbol,PERIOD_M5,0);
   datetime m15_bar=iTime(_Symbol,PERIOD_M15,0);
   if(m5_bar>0 && m5_bar!=g_structure_bar_m5)
     {
      g_structure_bar_m5=m5_bar; // at most one history attempt/panel refresh per TF candle
      RefreshStructureTimeframe(PERIOD_M5,InpStructureBarsM5,0,clrGold,g_structure_key_m5);
     }
   if(m15_bar>0 && m15_bar!=g_structure_bar_m15)
     {
      g_structure_bar_m15=m15_bar;
      RefreshStructureTimeframe(PERIOD_M15,InpStructureBarsM15,4,clrLightSkyBlue,g_structure_key_m15);
     }
  }

void RecordRun(const string event)
  {
   string values[]; ArrayResize(values,17);
   values[0]=TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS); values[1]=event;
   values[2]=OBSERVER_BUILD_TAG; values[3]=EnumToString(InpRulePack);
   values[4]=InpShadowLegacyRules ? "1" : "0";
   values[5]=InpUseMedianRangeScale ? "1" : "0";
   values[6]=InpUseStructurePositionFilter ? "1" : "0";
   values[7]=DoubleToString(InpSpikeM1RangeMultiple,8); values[8]=IntegerToString(InpSpikeMedianBars);
   values[9]=IntegerToString(InpTouchSpikeWindowMinutes); values[10]=IntegerToString(InpZoneObservationMinutes);
   values[11]=IntegerToString(InpMaxTickGapSeconds);
   FillWriterFields(values,12);
   if(!ValidFileTag()) return;
   AppendDiagnostic(TaggedCsv("BCSO_"+SafeSymbolName()+"_runs_v1603.csv"),
      "time_server;event;build;rule_pack;shadow;InpUseMedianRangeScale;InpUseStructurePositionFilter;InpSpikeM1RangeMultiple;InpSpikeMedianBars;InpTouchSpikeWindowMinutes;InpZoneObservationMinutes;InpMaxTickGapSeconds;writer_program;writer_chart;writer_period;writer_build;writer_session",values);
  }

int OnInit()
  {
   if(!ManualExecInputsValid()) return INIT_PARAMETERS_INCORRECT;
   if(!LevelsInputsValid()) return INIT_PARAMETERS_INCORRECT;
   if(!ExecInitialize()) return INIT_PARAMETERS_INCORRECT;
   g_eval_pack=InpRulePack;
   if(!ValidFileTag()) { Print("InpFileTag: use letras ASCII, números, guion o guion bajo"); return INIT_PARAMETERS_INCORRECT; }
   if(!AcquireWriterLock()) return INIT_FAILED;
   RecordRun("INIT");
   string prefix="BCSO_"+SafeSymbolName();
   g_signals_file=StringLen(InpCsvFileName)==0 ? prefix+"_signals_v1600.csv" : InpCsvFileName;
   g_outcomes_file=StringLen(InpOutcomeCsvFileName)==0 ? prefix+"_outcomes_v1600.csv" : InpOutcomeCsvFileName;
   g_candidates_file=StringLen(InpCandidateCsvFileName)==0 ? prefix+"_candidates_v1600.csv" : InpCandidateCsvFileName;
   g_candidate_outcomes_file=StringLen(InpCandidateOutcomeCsvFileName)==0 ? prefix+"_candidate_outcomes_v1600.csv" : InpCandidateOutcomeCsvFileName;
   g_alerts_file=prefix+"_alerts_v1600.csv"; g_alert_outcomes_file=prefix+"_alert_outcomes_v1600.csv";
   g_rejections_file=prefix+"_rejections_v1600.csv";
   g_signals_file=TaggedCsv(g_signals_file); g_outcomes_file=TaggedCsv(g_outcomes_file);
   g_candidates_file=TaggedCsv(g_candidates_file); g_candidate_outcomes_file=TaggedCsv(g_candidate_outcomes_file);
   g_alerts_file=TaggedCsv(g_alerts_file); g_alert_outcomes_file=TaggedCsv(g_alert_outcomes_file);
   g_rejections_file=TaggedCsv(g_rejections_file);
   if(InpSpikeMedianBars<10 || InpSpikeMedianBars>500 || InpSpikeM1RangeMultiple<=1.0 || InpZoneObservationMinutes<1 ||
      InpDiagnosticMaxBytes<1024 || InpProfileEveryBars<1) return INIT_PARAMETERS_INCORRECT;
   ArrayResize(g_pending,300);
   for(int i=0;i<ArraySize(g_pending);i++) InitPendingSignal(g_pending[i]);
   if(InpPivotStrength<1 || InpMinZoneTouches<2 || InpZoneRangeLookback<2 ||
      InpPlanRiskMinUSD<0.0 || InpPlanRiskMaxUSD<=0.0 || InpPlanRiskMaxUSD>2.00 || InpPlanRiskMaxUSD<InpPlanRiskMinUSD ||
      InpNMinimumPullbackBars<2 || InpNMinimumPullbackBars>10 ||
      InpNImpulseZoneWidths<=0.0 ||
      InpZoneRangeFactor<=0.0 || InpOutcomeMaxBars<1 || InpMaxTickGapSeconds<1 ||
      InpScanBarsM1<InpRetestLookbackBars+3 || InpRetestLookbackBars<1 ||
      InpScanBarsM5<InpZoneRangeLookback+2 || InpScanBarsM15<2*InpPivotStrength+3 ||
      InpScanBarsH1<2*InpPivotStrength+3 || InpMaxDrawnZonesPerType<1 ||
      InpVisibleDistanceRanges<=0.0 || InpEarlyWarningWidths<0.0 ||
      InpBreakMarginRanges<0.0 || InpStopBufferRanges<0.0 ||
      InpMinimumRewardRisk<=0.0 || g_signals_file==g_outcomes_file ||
      InpZoneMinWidthPrice<=0.0 || InpZoneMaxWidthPrice<InpZoneMinWidthPrice)
      return INIT_PARAMETERS_INCORRECT;
   // Context is recorded even when its drawings are disabled.
     {
      int minimum=2*InpStructurePivotStrength+InpStructureRangeLookback+3;
      if(InpStructurePivotStrength<1 || InpStructurePivotStrength>20 ||
         InpStructureRangeLookback<2 || InpStructureRangeLookback>200 || InpStructureMinLegRanges<=0.0 ||
         (InpStructureBarsM5<minimum || InpStructureBarsM5>5000) ||
         (InpStructureBarsM15<minimum || InpStructureBarsM15>5000))
         return INIT_PARAMETERS_INCORRECT;
     }
   if(InpStructureHistoryLimit<MathMax(InpStructureBarsM5,InpStructureBarsM15) ||
      InpStructureSpikeMultiple<=1.0 || InpCandidateObservationMinutes<1 ||
      InpStructureEdgePercent<0.0 || InpStructureEdgePercent>=50.0 ||
      (InpStructureFilterTimeframe!=PERIOD_M5 && InpStructureFilterTimeframe!=PERIOD_M15) ||
      g_candidates_file==g_signals_file || g_candidate_outcomes_file==g_outcomes_file ||
      g_candidates_file==g_outcomes_file || g_candidate_outcomes_file==g_signals_file ||
      g_candidates_file==g_candidate_outcomes_file ||
      StringLen(g_signals_file)==0 || StringLen(g_outcomes_file)==0 ||
      StringLen(g_candidates_file)==0 || StringLen(g_candidate_outcomes_file)==0)
      return INIT_PARAMETERS_INCORRECT;
   if(!TpInputsValid()) return INIT_PARAMETERS_INCORRECT;
   if(!RestorePendingSignals())
     {
      Print("No se pudo recuperar el seguimiento: CSV incompatible, bloqueado o capacidad excedida.");
      Print("El inicio continúa; revisar los diagnósticos de recuperación.");
     }
   InitializeSpikeContext();
   TakeProfitInitialize();
   if(!InitializeTouchSpikes())
      Print("TOUCH_SPIKE: registro no disponible o parámetros inválidos; revisar antes de usar estas mediciones");
   RefreshScale();
   Print("BoomCrashSignalObserver v",OBSERVER_BUILD_VERSION,
         " revisión ",OBSERVER_REVISION," iniciado. Reglas ",OBSERVER_RULE_VERSION,
         InpDemoExecution ? ". Ejecución DEMO habilitada por input; sujeta a permisos y límites." : ". Solo observación: ejecución desactivada.");
   // Do not replay the last completed M1 candle as a fresh signal on attach.
   g_last_m1_bar=iTime(_Symbol,PERIOD_M1,0);
   if(g_m5_range>0.0) RefreshDetectedZoneDrawings();
   if(g_m5_range>0.0) RefreshEarlyWarningCache();
   RefreshCrashTrendContext();
   RefreshStructureContext();
   OperationsInitialize();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   OperationsR3Shutdown();
   if(g_writer_lock_owned)
     {
      RecordRun("DEINIT_"+IntegerToString(reason));
      GlobalVariableDel(g_writer_lock); g_writer_lock_owned=false;
     }
   DeleteDrawnZones("BCSO_STRUCT_");
   DeleteDrawnZones("BCSO_M5_SUPPORT_");
   DeleteDrawnZones("BCSO_M5_RESISTANCE_");
   DeleteDrawnZones("BCSO_M5_HIST_SUPPORT_");
   DeleteDrawnZones("BCSO_M15_SUPPORT_");
   DeleteDrawnZones("BCSO_M15_RESISTANCE_");
  }

bool RefreshScaleIfNeeded()
  {
   static datetime scale_bar=0;
   datetime bar=iTime(_Symbol,PERIOD_M1,0);
   if(g_m5_range>0.0 && scale_bar==bar) return true;
   if(!RefreshScale()) return false;
   scale_bar=bar;
   return true;
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  { ExecTradeTransaction(trans); ExecLossPauseTransaction(trans); ManualTradeTransaction(trans); RetraceExitTradeTransaction(trans); OperationsRiskPoll(); }

void OnTick()
  {
   if(!RenewWriterLock()) return;
   OperationsPoll();
   RefreshStructureContext();
   UpdatePendingOutcomes();
   if(!RefreshScaleIfNeeded()) return;
   RefreshCrashTrendContext();
   if(IsNewM1Bar())
     {
      ulong began=GetMicrosecondCount();
      RefreshSpikeContext();
      TakeProfitOnNewM1();
      RefreshDetectedZoneDrawings();
      RefreshEarlyWarningCache();
      RefreshAdditionalLevels();
      ExplainManualZone();
      if(InpUseM5ReactionStrategy) EvaluateM5ReactionStrategy();
      else EvaluateSignals();
      static int profile_bars=0; profile_bars++;
      if(InpProfileM1 && profile_bars%InpProfileEveryBars==0)
         Print("M1_PERF: ",GetMicrosecondCount()-began," us | cachés ",ArraySize(g_zone_cache)," | pendientes ",ArraySize(g_pending));
     }
   if(InpUseM5ReactionStrategy) EvaluateEarlyZoneEntry();
   ObserveManualEarlyTicks(); ManualTimeStopPoll(); RetraceExitPoll(); ManualSummaryPoll();
   VariantsPoll();
   ObserveTouchSpikes();
   if(!InpUseM5ReactionStrategy)
     {
      NotifyBoomEarlyNCandidate();
      NotifyCrashTrendCandidate();
     }
   NotifyEarlyZoneWarning();
   OperationsAfterTick();
  }
