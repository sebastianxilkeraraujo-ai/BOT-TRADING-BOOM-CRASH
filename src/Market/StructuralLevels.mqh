#ifndef BCSO_STRUCTURAL_LEVELS
#define BCSO_STRUCTURAL_LEVELS
input int InpStructLevelBarsM5=576;
input double InpStructMaxDistanceRanges=30.0;
input int InpStructMaxLevelsPerSide=4;
input bool InpExecStructural=false;

struct AdditionalLevel
  {
   Zone zone;
   string source,key;
   datetime known_at,formed_at;
   int age_bars,priority,touches_after;
   bool flipped,manual;
  };
AdditionalLevel g_struct_levels[],g_manual_levels[];
datetime g_levels_bar=0;
bool g_levels_struct_ready=false;

bool IsAdditionalLevelKey(const string key)
  { return StringFind(key,"STRUCT_")==0 || StringFind(key,"MANUAL_")==0; }
ZoneKind LevelRole(const double center,const double bid)
  { return center<=bid ? ZONE_SUPPORT : ZONE_RESISTANCE; }
bool LevelKnown(const AdditionalLevel &level,const datetime asof)
  { return level.known_at>0 && level.known_at<=asof; }
double LevelDistance(const Zone &zone,const double price)
  { return MathMax(0.0,MathMax(zone.lower-price,price-zone.upper)); }
void LevelPush(AdditionalLevel &levels[],const AdditionalLevel &level)
  { int n=ArraySize(levels); if(ArrayResize(levels,n+1)==n+1) levels[n]=level; }

// Priority merge keeps the winning source and its own availability timestamp.
// Width here means ZoneHalfWidth: merge radius = two half-widths.
int SelectStructuralLevels(const AdditionalLevel &raw[],const ZoneKind kind,
                          const double bid,const datetime asof,const double half_width,
                          const double max_distance,const int cap,AdditionalLevel &out[])
  {
   ArrayResize(out,0); AdditionalLevel sorted[];
   for(int i=0;i<ArraySize(raw);i++)
     {
      if(!LevelKnown(raw[i],asof) || LevelRole(raw[i].zone.center,bid)!=kind ||
         LevelDistance(raw[i].zone,bid)>max_distance) continue;
      AdditionalLevel level=raw[i]; level.zone.kind=kind; LevelPush(sorted,level);
     }
   for(int i=1;i<ArraySize(sorted);i++)
     {
      AdditionalLevel value=sorted[i]; int j=i-1;
      while(j>=0 && (sorted[j].priority<value.priority ||
            (sorted[j].priority==value.priority &&
             MathAbs(sorted[j].zone.center-bid)>MathAbs(value.zone.center-bid))))
        { sorted[j+1]=sorted[j]; j--; }
      sorted[j+1]=value;
     }
   for(int i=0;i<ArraySize(sorted);i++)
     {
      bool merged=false;
      for(int j=0;j<ArraySize(out);j++)
         if(MathAbs(out[j].zone.center-sorted[i].zone.center)<=2.0*half_width)
           { merged=true; break; }
      if(!merged) LevelPush(out,sorted[i]);
     }
   for(int i=1;i<ArraySize(out);i++)
     {
      AdditionalLevel value=out[i]; int j=i-1;
      while(j>=0 && LevelDistance(out[j].zone,bid)>LevelDistance(value.zone,bid))
        { out[j+1]=out[j]; j--; }
      out[j+1]=value;
     }
   if(ArraySize(out)>cap) ArrayResize(out,cap);
   return ArraySize(out);
  }

void StructuralMetadata(AdditionalLevel &level,const MqlRates &m5[],const double bid)
  {
   bool inside=false; level.touches_after=0; level.flipped=false; level.age_bars=0;
   for(int i=ArraySize(m5)-1;i>=1;i--)
     {
      if(m5[i].time<level.known_at) continue;
      level.age_bars++;
      bool touch=m5[i].low<=level.zone.upper && m5[i].high>=level.zone.lower;
      if(touch && !inside) level.touches_after++;
      inside=touch;
      if((bid>=level.zone.center && m5[i].close<level.zone.lower) ||
         (bid<level.zone.center && m5[i].close>level.zone.upper)) level.flipped=true;
     }
   level.zone.touches=level.touches_after;
  }

void AddStructuralCandidate(AdditionalLevel &raw[],const string source,const int priority,
                            const ENUM_TIMEFRAMES tf,const double price,const double half,
                            const datetime formed,const datetime known,const MqlRates &m5[],
                            const double bid)
  {
   AdditionalLevel level; level.source=source; level.priority=priority; level.manual=false;
   level.formed_at=formed; level.known_at=known;
   level.zone=MakeZone(tf,LevelRole(price,bid),price,half,0);
   level.key="STRUCT_"+source+"_"+EnumToString(tf)+"_"+(string)(long)formed+"_"+DoubleToString(price,_Digits);
   StructuralMetadata(level,m5,bid);
   level.age_bars=iBarShift(_Symbol,tf,formed,true);
   LevelPush(raw,level);
  }

bool StructuralFromTimeframe(const ENUM_TIMEFRAMES tf,const int bars,const double half,
                             const MqlRates &m5[],const double bid,AdditionalLevel &raw[])
  {
   MqlRates rates[]; if(!LoadRates(tf,bars,rates)) return false;
   int indices[],kinds[],first[];
   double tick=MathMax(_Point,SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE));
   int n=StructureSwings(rates,InpStructurePivotStrength,InpStructureRangeLookback,
                        InpStructureMinLegRanges,tick,indices,kinds,first,InpUseMedianRangeScale);
   if(n<0) return false;
   int seconds=PeriodSeconds(tf);
   // The first pivot has no qualified incoming leg. An extended pivot's actual
   // confirmation must not inherit the earlier first_confirmed timestamp.
   for(int i=1;i<n;i++)
     {
      int shift=indices[i],confirmation=shift-InpStructurePivotStrength;
      datetime known=(datetime)MathMax((long)rates[first[i]].time+seconds,
                                       (long)rates[confirmation].time+seconds);
      AddStructuralCandidate(raw,tf==PERIOD_M5 ? "M5_SWING" : "M15_SWING",
                             tf==PERIOD_M5 ? 1 : 2,tf,
                             kinds[i]==1 ? rates[shift].high : rates[shift].low,
                             half,rates[shift].time,known,m5,bid);
     }
   StructureBounds done,forming;
   if(DetectStructureBounds(rates,InpStructurePivotStrength,InpStructureRangeLookback,
       InpStructureMinLegRanges,tick,seconds,done,forming,InpUseMedianRangeScale) && done.valid)
     {
      datetime known=done.known_at;
      if(n>=4) known=(datetime)MathMax((long)known,
                      (long)rates[indices[n-1]-InpStructurePivotStrength].time+seconds);
      AddStructuralCandidate(raw,"CYCLE_LOW",3,tf,done.low,half,done.low_time,known,m5,bid);
      AddStructuralCandidate(raw,"CYCLE_HIGH",3,tf,done.high,half,done.high_time,known,m5,bid);
     }
   return true;
  }

int CollectStructuralLevels(const ZoneKind kind,AdditionalLevel &levels[])
  {
   ArrayResize(levels,0);
   for(int i=0;i<ArraySize(g_struct_levels);i++)
      if(g_struct_levels[i].zone.kind==kind) LevelPush(levels,g_struct_levels[i]);
   return ArraySize(levels);
  }


bool LevelsInputsValid()
  {
   return InpStructLevelBarsM5>=2*InpStructurePivotStrength+InpStructureRangeLookback+3 &&
          InpStructLevelBarsM5<=10000 && InpStructMaxDistanceRanges>0.0 &&
          InpStructMaxLevelsPerSide>0 && InpStructMaxLevelsPerSide<=100 &&
          InpManualLevelDelaySeconds>=0;
  }
string NearestLevelDistance(const AdditionalLevel &levels[],const ZoneKind kind,
                            const double bid,string &source)
  {
   double best=DBL_MAX; source="";
   for(int i=0;i<ArraySize(levels);i++)
     {
      if(levels[i].zone.kind!=kind || !LevelKnown(levels[i],TimeCurrent())) continue;
      double d=LevelDistance(levels[i].zone,bid)/MathMax(_Point,levels[i].zone.upper-levels[i].zone.lower);
      if(d<best) { best=d; source=levels[i].source; }
     }
   return best==DBL_MAX ? "" : DoubleToString(best,6);
  }
void WriteLevelsCoverage(const MqlTick &q)
  {
   ZoneKind kind=IsBoomSymbol() ? ZONE_SUPPORT : ZONE_RESISTANCE;
   double centers[],half=0.0,best=DBL_MAX; int touches[];
   int n=CollectQualifiedZones(PERIOD_M5,kind,InpScanBarsM5,centers,touches,half,true);
   for(int i=0;i<n;i++) if(touches[i]>=2)
     {
      Zone z=MakeZone(PERIOD_M5,kind,centers[i],half,touches[i]);
      best=MathMin(best,LevelDistance(z,q.bid)/MathMax(_Point,2.0*half));
     }
   string row[]; ArrayResize(row,7); string source;
   row[0]=TimeToString(q.time,TIME_DATE|TIME_SECONDS);
   row[1]=best==DBL_MAX ? "" : DoubleToString(best,6);
   row[2]=NearestLevelDistance(g_struct_levels,kind,q.bid,source); row[3]=source;
   row[4]=NearestLevelDistance(g_manual_levels,kind,q.bid,source);
   row[5]=StrategyTrendText(DetectTrend(PERIOD_M5,InpScanBarsM5)); row[6]=g_writer_session;
   AppendDiagnostic(TaggedCsv("BCSO_"+SafeSymbolName()+"_levels_cov_v1604.csv"),
      "time_server;dist_reaction_widths;dist_struct_widths;struct_source;dist_manual_widths;trend_m5;writer_session",row);
  }
void RefreshAdditionalLevels()
  {
   datetime bar=iTime(_Symbol,PERIOD_M1,0);
   if(bar<=0 || bar==g_levels_bar) return;
   g_levels_bar=bar; ArrayResize(g_struct_levels,0);
   MqlTick q; if(!SymbolInfoTick(_Symbol,q) || q.bid<=0) return;
   MqlRates m5[];
   bool ready=LoadRates(PERIOD_M5,MathMax(InpStructLevelBarsM5,InpStructureBarsM15*3+3),m5);
   double half=ready ? ZoneHalfWidth(m5) : MathMax(_Point,g_m5_range*InpZoneRangeFactor);
   g_levels_struct_ready=false;
   if(ready)
     {
      AdditionalLevel raw[],selected[];
      bool a=StructuralFromTimeframe(PERIOD_M5,InpStructLevelBarsM5,half,m5,q.bid,raw);
      bool b=StructuralFromTimeframe(PERIOD_M15,InpStructureBarsM15,half,m5,q.bid,raw);
      g_levels_struct_ready=a && b;
      for(int kind=0;kind<2;kind++)
        {
         SelectStructuralLevels(raw,(ZoneKind)kind,q.bid,q.time,half,
                                InpStructMaxDistanceRanges*g_m5_range,InpStructMaxLevelsPerSide,selected);
         for(int i=0;i<ArraySize(selected);i++) LevelPush(g_struct_levels,selected[i]);
        }
     }
   RefreshManualLevels(q,half);
   WriteLevelsCoverage(q);
  }

void AppendLevelBands(const AdditionalLevel &levels[])
  {
   for(int i=0;i<ArraySize(levels);i++)
     {
      if(!LevelKnown(levels[i],TimeCurrent())) continue;
      // Role is part of identity: a flipped band rearms independently.
      string key=levels[i].key+"_"+EnumToString(levels[i].zone.kind);
      int found=-1;
      for(int j=0;j<ArraySize(g_touch_bands);j++) if(g_touch_bands[j].key==key) { found=j; break; }
      if(found<0)
        {
         found=ArraySize(g_touch_bands);
         if(found>=2048 || ArrayResize(g_touch_bands,found+1)!=found+1)
           { Print("LEVELS: límite de bandas; observación incompleta"); return; }
         InitTouchSpikeBand(g_touch_bands[found]); g_touch_bands[found].armed=true;
         g_touch_bands[found].key=key;
        }
      g_touch_bands[found].zone=levels[i].zone; g_touch_bands[found].current=true;
      g_touch_bands[found].last_seen=TimeCurrent();
     }
  }
void AppendAdditionalTouchBands()
  { AppendLevelBands(g_struct_levels); AppendLevelBands(g_manual_levels); }

double AdditionalTarget(const string side,const double entry,const datetime asof)
  {
   double best=StrategyM5Target(side,entry);
   for(int group=0;group<2;group++)
     {
      int n=group==0 ? ArraySize(g_struct_levels) : ArraySize(g_manual_levels);
      for(int i=0;i<n;i++)
        {
         AdditionalLevel level;
         if(group==0) level=g_struct_levels[i]; else level=g_manual_levels[i];
         if(!LevelKnown(level,asof)) continue;
         double value=side=="BUY" ? level.zone.lower : level.zone.upper;
         if((side=="BUY" && value>entry && (best<=entry || value<best)) ||
            (side=="SELL" && value<entry && (best<=0 || best>=entry || value>best))) best=value;
        }
     }
   return best;
  }
void EvaluateAdditionalLevels(const string side,const ZoneKind kind,const MqlRates &m1[],
                              const MqlTick &quote,const datetime signal_bar)
  {
   AdditionalLevel selected; bool found=false; double best=DBL_MAX;
   for(int group=0;group<2;group++)
     {
      int n=group==0 ? ArraySize(g_struct_levels) : ArraySize(g_manual_levels);
      for(int i=0;i<n;i++)
        {
         AdditionalLevel level;
         if(group==0) level=g_struct_levels[i]; else level=g_manual_levels[i];
         // Conservative: level was available before the entire trigger candle.
         if(level.zone.kind!=kind || !LevelKnown(level,signal_bar)) continue;
         double width=level.zone.upper-level.zone.lower;
         if(m1[1].high<level.zone.lower-width || m1[1].low>level.zone.upper+width) continue;
         double distance=MathAbs(m1[1].close-level.zone.center);
         if(distance<best) { best=distance; selected=level; found=true; }
        }
     }
   if(!found) return;
   Zone zone=selected.zone;
   double entry=side=="BUY" ? quote.ask : quote.bid;
   double stop=side=="BUY" ? MathMin(m1[1].low,zone.lower)-StopBuffer()
                           : MathMax(m1[1].high,zone.upper)+StopBuffer();
   double target=AdditionalTarget(side,entry,quote.time),volume=0.0,risk=0.0;
   double width=MathMax(_Point,zone.upper-zone.lower),spread=MathMax(0.0,quote.ask-quote.bid);
   target=TpSelectedTarget(side,entry,width,spread,stop,target);
   string reason=""; bool size_ok=StrategyRiskVolume(side,entry,stop,volume,risk,reason);
   double reward=side=="BUY" ? target-entry : entry-target;
   double rr=MathAbs(entry-stop)>_Point ? reward/(MathAbs(entry-stop)+spread) : 0.0;
   bool tp_rr_fail=InpTpMode==SPIKE_QUANTILE && rr<InpTpMinRR;
   bool rejection=side=="BUY" ? ClosedM1RejectsAbove(zone,m1) : ClosedM1RejectsBelow(zone,m1);
   bool pattern=rejection && InpEnableNModule && StrategyPatternN(zone,m1,side);
   string stage=pattern ? "N_CONFIRMADO" : (rejection ? "RECHAZO_CONFIRMADO" : "VIGILANCIA");
   if(!size_ok) stage="DESCARTADO_RIESGO";
   else if(target<=0.0 || (InpTpMode==NEAREST_ZONE && rr<InpMinimumRewardRisk))
     { stage="DESCARTADO_OBJETIVO"; reason="SIN_OBJETIVO_O_RR_BAJO"; }
   else if(tp_rr_fail) reason="TP_RR_INSUFICIENTE";
   string prefix=selected.manual ? "MANUAL_" : "ESTRUCTURAL_";
   string id=_Symbol+"_LEVEL_"+selected.key+"_"+(string)(long)signal_bar;
   bool confirmed=rejection && size_ok && target>0.0 && (InpTpMode==SPIKE_QUANTILE || rr>=InpMinimumRewardRisk);
   string key="LEVEL_PLAN_"+selected.key;
   if(!confirmed && ZoneAlertInCooldown(key,TimeCurrent(),MathMax(1,InpZoneAlertCooldownMinutes)*60)) return;
   Trend m5=DetectTrend(PERIOD_M5,InpScanBarsM5),m15=DetectTrend(PERIOD_M15,InpScanBarsM15);
   string detail=reason+" | "+selected.key+" | source="+selected.source+
                 " | age_bars="+(string)selected.age_bars+" | touches_after="+(string)selected.touches_after+
                 " | flipped="+(string)selected.flipped+" | known_at="+TimeToString(selected.known_at,TIME_DATE|TIME_SECONDS);
   if(!StrategyAppendPlan(id,signal_bar,prefix+stage,side,zone,m15,entry,stop,target,volume,risk,detail)) return;
   if(!confirmed) { RememberZoneAlert(key,TimeCurrent()); return; }
   g_record_zone_alert=false; g_record_volume=volume; g_record_risk_usd=risk;
   g_record_risk_exceeds=false; g_record_leg_spike=pattern; g_record_legacy_stop=stop;
   bool saved=RecordObservation(selected.manual ? "M5_MANUAL_REJECTION" : "M5_STRUCT_REJECTION",
                side,zone,m5,m15,TREND_NONE,detail,quote,stop,target,signal_bar,false);
   g_record_volume=0.0; g_record_risk_usd=0.0; g_record_leg_spike=false;
   if(saved) RecordTakeProfitPlan(id,selected.manual ? "M5_MANUAL_REJECTION" : "M5_STRUCT_REJECTION",
                                  side,zone,m5,m15,quote,stop,AdditionalTarget(side,entry,quote.time),volume,signal_bar);
   if(saved && InpExecStructural && !tp_rr_fail) DemoExecuteConfirmed(id,side,zone,signal_bar,stop,target);
  }
#endif
