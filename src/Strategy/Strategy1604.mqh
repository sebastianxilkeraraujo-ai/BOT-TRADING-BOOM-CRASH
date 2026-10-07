// Observador de la hipótesis M5/M1. M15 se registra como contexto, no veta entradas.
// El importe del SL es planificado: un salto puede superar ese importe.

string StrategyTrendText(const Trend trend)
  {
   if(trend==TREND_UP) return "ALCISTA";
   if(trend==TREND_DOWN) return "BAJISTA";
   return "INDEFINIDA";
  }

bool StrategyM15DirectionAllowed(const string symbol,const string side,const Trend m15)
  {
   if(symbol=="Boom 1000 Index") return side=="BUY" && m15==TREND_UP;
   if(symbol=="Crash 1000 Index") return side=="SELL" && m15==TREND_DOWN;
   return false;
  }

// Selección pura de volumen sobre la rejilla del símbolo, antes de verificarlo con OrderCalcProfit.
double StrategyVolumeGrid(const double loss_per_lot,const double min_lots,
                          const double step_lots,const double max_lots,
                          const double min_usd,const double max_usd)
  {
   if(loss_per_lot<=0.0 || min_lots<=0.0 || step_lots<=0.0 || max_lots<min_lots ||
      min_usd<0.0 || max_usd<=0.0 || max_usd<min_usd) return 0.0;
   double cap=MathMin(max_lots,max_usd/loss_per_lot);
   if(cap+1e-9<min_lots) return 0.0;
   double steps=MathFloor((cap-min_lots)/step_lots+1e-8);
   double volume=NormalizeDouble(min_lots+steps*step_lots,8);
   if(volume*loss_per_lot+1e-8<min_usd) return 0.0;
   return volume;
  }

bool StrategyRiskVolume(const string side,const double entry,const double stop,
                        double &volume,double &risk_usd,string &reason)
  {
   volume=0.0; risk_usd=0.0; reason="";
   if(AccountInfoString(ACCOUNT_CURRENCY)!="USD") { reason="CUENTA_NO_USD"; return false; }
   if(entry<=0.0 || stop<=0.0 ||
      (side=="BUY" && stop>=entry) || (side=="SELL" && stop<=entry))
     { reason="SL_INVALIDO"; return false; }
   double minimum=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maximum=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(minimum<=0.0 || maximum<minimum || step<=0.0)
     { reason="VOLUMEN_SIMBOLO_INVALIDO"; return false; }
   ENUM_ORDER_TYPE order_type=(side=="BUY" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double profit=0.0;
   if(!OrderCalcProfit(order_type,_Symbol,minimum,entry,stop,profit) || profit>=0.0)
     { reason="RIESGO_NO_CALCULABLE"; return false; }
   double loss_per_lot=-profit/minimum;
   volume=StrategyVolumeGrid(loss_per_lot,minimum,step,maximum,
                             InpPlanRiskMinUSD,InpPlanRiskMaxUSD);
   if(volume<=0.0) { reason="SIN_LOTE_EN_RANGO_USD"; return false; }
   if(!OrderCalcProfit(order_type,_Symbol,volume,entry,stop,profit) || profit>=0.0)
     { volume=0.0; reason="RIESGO_NO_CALCULABLE"; return false; }
   risk_usd=-profit;
   if(risk_usd+1e-6<InpPlanRiskMinUSD || risk_usd>InpPlanRiskMaxUSD+1e-6)
     { volume=0.0; reason="RIESGO_FUERA_DE_RANGO"; return false; }
   return true;
  }

// Impulso en la dirección del spike, retroceso de al menos tres M1 y nuevo rechazo.
// Todas las velas inspeccionadas están cerradas antes de la cotización de referencia.
bool StrategyPatternN(const Zone &zone,const MqlRates &m1[],const string side)
  {
   int total=ArraySize(m1);
   if(total<InpNMinimumPullbackBars+5) return false;
   int drift=0;
   int limit=MathMin(total-2,MathMax(12,InpBoomNLookbackM1));
   for(int shift=2;shift<limit;shift++)
     {
      bool against=(side=="BUY" ? m1[shift].close<m1[shift+1].close
                                 : m1[shift].close>m1[shift+1].close);
      if(!against) break;
      drift++;
     }
   if(drift<InpNMinimumPullbackBars) return false;
   double required=InpNImpulseZoneWidths*MathMax(_Point,zone.upper-zone.lower);
   for(int shift=drift+2;shift<limit;shift++)
     {
      double body=(side=="BUY" ? m1[shift].close-m1[shift].open
                               : m1[shift].open-m1[shift].close);
      double width=MathMax(_Point,zone.upper-zone.lower);
      bool began_near=(m1[shift].open>=zone.lower-width &&
                       m1[shift].open<=zone.upper+width);
      if(body>=required && began_near) return true;
     }
   return false;
  }

// No cuenta la vela M5 que contiene al gatillo M1 ni pivotes aún sin confirmar.
int StrategyPriorReactions(const Zone &zone,const datetime signal_bar,const MqlRates &rates[])
  {
   double half=MathMax(_Point,zone.upper-zone.center);
   double rebound=MathMax(_Point,half*MathMax(0.0,InpReactionMinReboundWidths));
   double excursion=half*MathMax(0.0,InpReactionMinExcursionWidths);
   int count=0,last_counted=-1;
   for(int shift=1;shift<ArraySize(rates);shift++)
     {
      if(rates[shift].time+300>signal_bar) continue;
      bool reaction=IsClosedM5Reaction(rates,shift,zone.kind,rebound);
      bool pivot=(zone.kind==ZONE_SUPPORT ? IsPivotLow(rates,shift,InpPivotStrength)
                                          : IsPivotHigh(rates,shift,InpPivotStrength));
      if(pivot && rates[shift-InpPivotStrength].time+300>signal_bar) pivot=false;
      if(!reaction && !pivot) continue;
      double price=zone.kind==ZONE_SUPPORT ? rates[shift].low : rates[shift].high;
      if(MathAbs(price-zone.center)>half) continue;
      if(last_counted>=0 &&
         (shift-last_counted<MathMax(1,InpReactionMinSeparationM5Bars) ||
          !MovedAwayBetweenM5Reactions(rates,last_counted,shift,zone.kind,
                                       zone.center,excursion))) continue;
      count++; last_counted=shift;
     }
   return count;
  }

double StrategyM5Target(const string side,const double entry)
  {
   Zone target=FindNearestTargetZone(PERIOD_M5,
                   side=="BUY" ? ZONE_RESISTANCE : ZONE_SUPPORT,
                   InpScanBarsM5,entry,side=="BUY");
   if(!target.valid) return 0.0;
   return side=="BUY" ? target.lower : target.upper;
  }

bool StrategyAppendPlan(const string event_id,const datetime bar,const string stage,
                        const string side,const Zone &zone,const Trend m15,
                        const double entry,const double stop,const double target,
                        const double volume,const double risk_usd,const string reason)
  {
   string row[]; ArrayResize(row,17);
   row[0]=event_id; row[1]=TimeToString(bar,TIME_DATE|TIME_SECONDS);
   row[2]=_Symbol; row[3]=stage; row[4]=side;
   row[5]=DoubleToString(zone.lower,_Digits); row[6]=DoubleToString(zone.upper,_Digits);
   row[7]=IntegerToString(zone.touches); row[8]=StrategyTrendText(m15);
   row[9]=DoubleToString(entry,_Digits); row[10]=DoubleToString(stop,_Digits);
   row[11]=target>0.0 ? DoubleToString(target,_Digits) : "";
   row[12]=volume>0.0 ? DoubleToString(volume,8) : "";
   row[13]=risk_usd>0.0 ? DoubleToString(risk_usd,5) : "";
   row[14]=reason; row[15]=OBSERVER_BUILD_TAG; row[16]=g_writer_session;
   string filename=TaggedCsv("BCSO_"+SafeSymbolName()+"_plans_v1604.csv");
   bool saved=AppendDiagnostic(filename,
      "event_id;time_server;symbol;stage;side;zone_lower;zone_upper;m5_reactions;trend_m15;entry_ref;sl_ref;tp_ref;volume_ref;risk_usd_ref;reason;writer_build;writer_session",row);
   if(saved) VariantsPlanFollow(event_id,stage,side,zone);
   return saved;
  }


void EvaluateM5ReactionStrategy()
  {
   MqlRates m1[];
   if(!LoadRates(PERIOD_M1,MathMax(InpScanBarsM1,InpBoomNLookbackM1+5),m1)) return;
   MqlTick quote;
   if(!SymbolInfoTick(_Symbol,quote) || quote.ask<=quote.bid || quote.bid<=0.0) return;
   datetime signal_bar=iTime(_Symbol,PERIOD_M1,1);
   if(signal_bar<=0 || quote.time_msc<(long)(signal_bar+60)*1000 ||
      quote.time_msc>(long)(signal_bar+120)*1000) return;
   string side=""; ZoneKind kind=ZONE_SUPPORT;
   if(IsBoomSymbol()) { side="BUY"; kind=ZONE_SUPPORT; }
   else if(IsCrashSymbol()) { side="SELL"; kind=ZONE_RESISTANCE; }
   else return;
   double centers[],tolerance=0.0; int reactions[];
   int count=CollectQualifiedZones(PERIOD_M5,kind,InpScanBarsM5,
                                   centers,reactions,tolerance,true);
   MqlRates m5_history[];
   if(!LoadRates(PERIOD_M5,InpScanBarsM5,m5_history)) return;
   int selected=-1; double nearest=DBL_MAX;
   for(int i=0;i<count;i++)
     {
      if(reactions[i]<2) continue;
      Zone test=MakeZone(PERIOD_M5,kind,centers[i],tolerance,reactions[i]);
      int previous=StrategyPriorReactions(test,signal_bar,m5_history);
      if(previous<2) continue;
      double width=MathMax(_Point,test.upper-test.lower);
      if(m1[1].high<test.lower-width || m1[1].low>test.upper+width) continue;
      double distance=MathAbs(m1[1].close-test.center);
      if(distance<nearest) { nearest=distance; selected=i; }
     }
   if(selected<0) { EvaluateAdditionalLevels(side,kind,m1,quote,signal_bar); return; }
   Zone zone=MakeZone(PERIOD_M5,kind,centers[selected],tolerance,reactions[selected]);
   zone.touches=StrategyPriorReactions(zone,signal_bar,m5_history);
   Trend m15=DetectTrend(PERIOD_M15,InpScanBarsM15);
   Trend m5=DetectTrend(PERIOD_M5,InpScanBarsM5);
   double entry=side=="BUY" ? quote.ask : quote.bid;
   double stop=side=="BUY" ? MathMin(m1[1].low,zone.lower)-StopBuffer()
                           : MathMax(m1[1].high,zone.upper)+StopBuffer();
   double target=StrategyM5Target(side,entry),width=MathMax(_Point,zone.upper-zone.lower);
   double spread=MathMax(0.0,quote.ask-quote.bid);
   target=TpSelectedTarget(side,entry,width,spread,stop,target);
   double volume=0.0,risk=0.0; string reason="";
   bool size_ok=StrategyRiskVolume(side,entry,stop,volume,risk,reason);
   double reward=(target>0.0 ? (side=="BUY" ? target-entry : entry-target) : 0.0);
   double rr=(MathAbs(entry-stop)>_Point ? reward/(MathAbs(entry-stop)+spread) : 0.0);
   bool tp_rr_fail=InpTpMode==SPIKE_QUANTILE && rr<InpTpMinRR;
   bool rejection=side=="BUY" ? ClosedM1RejectsAbove(zone,m1)
                                : ClosedM1RejectsBelow(zone,m1);
   bool n_pattern=rejection && InpEnableNModule && StrategyPatternN(zone,m1,side);
   string stage=n_pattern ? "N_CONFIRMADO" : (rejection ? "RECHAZO_CONFIRMADO" : "VIGILANCIA");
   if(!size_ok) stage="DESCARTADO_RIESGO";
   else if(target<=0.0 || (InpTpMode==NEAREST_ZONE && rr<InpMinimumRewardRisk))
     { stage="DESCARTADO_OBJETIVO"; reason="SIN_OBJETIVO_M5_O_RR_BAJO"; }
   else if(tp_rr_fail) reason="TP_RR_INSUFICIENTE";
   string event_id=_Symbol+"_1604_"+side+"_"+IntegerToString((long)signal_bar)+"_"+
                   DoubleToString(zone.center,_Digits);
   string key=ZoneAlertKey("PLAN_1604",zone);
   bool watch=(!rejection || stage=="DESCARTADO_RIESGO" || stage=="DESCARTADO_OBJETIVO");
   if(tp_rr_fail && rejection) watch=false;
   if(watch && ZoneAlertInCooldown(key,TimeCurrent(),MathMax(1,InpZoneAlertCooldownMinutes)*60)) return;
   if(!StrategyAppendPlan(event_id,signal_bar,stage,side,zone,m15,entry,stop,target,
                          volume,risk,reason)) return;
   if(watch)
     {
      RememberZoneAlert(key,TimeCurrent());
      if(InpEnableDesktopAlerts && !InpEnableEarlyZoneWarnings && stage=="VIGILANCIA")
        {
         Alert("PLAN M5 EN VIGILANCIA — NO ES ENTRADA\n",_Symbol," ",side,
               " | ",zone.touches," reacciones M5 | M15 ",StrategyTrendText(m15),
               "\nSL ",DoubleToString(stop,_Digits)," | volumen ",DoubleToString(volume,8),
               " | riesgo teórico USD ",DoubleToString(risk,2),". Espera confirmación M1.");
        }
      return;
     }
   string module=n_pattern ? "M5_REACTION_N" : "M5_REACTION_REJECTION";
   string details="M5 "+IntegerToString(zone.touches)+" reacciones | M15 "+StrategyTrendText(m15)+
                  " | volumen "+DoubleToString(volume,8)+" | riesgo USD "+DoubleToString(risk,2);
   g_record_zone_alert=false; g_record_volume=volume; g_record_risk_usd=risk;
   g_record_risk_exceeds=false; g_record_leg_spike=n_pattern; g_record_legacy_stop=stop;
   bool saved=RecordObservation(module,side,zone,m5,m15,TREND_NONE,details,
                                quote,stop,target,signal_bar,false);
   g_record_volume=0.0; g_record_risk_usd=0.0; g_record_leg_spike=false;
   if(!saved) return;
   RecordTakeProfitPlan(event_id,module,side,zone,m5,m15,quote,stop,StrategyM5Target(side,entry),volume,signal_bar);
   VariantsConfirmed(event_id,module,side,zone,m5,m15,quote,m1[1],stop,target,volume);
   if(!tp_rr_fail) DemoExecuteConfirmed(event_id,side,zone,signal_bar,stop,target);
   Print("PLAN_1604_CONFIRMADO: ",module," ",side," | ",details);
   if(InpEnableDesktopAlerts && ActivePack())
     {
      Alert(InpDemoExecution ? "SEÑAL M1 CONFIRMADA — VER DIARIO DEMO_EXEC\n" : "SEÑAL M1 OBSERVADA — NO ABRE OPERACIONES\n",_Symbol," ",module,
            " | M5 ",zone.touches," reacciones | M15 ",StrategyTrendText(m15),
            "\nEntrada ",DoubleToString(entry,_Digits)," | SL ",DoubleToString(stop,_Digits),
            " | TP ",DoubleToString(target,_Digits)," | volumen ",DoubleToString(volume,8),
            " | riesgo planificado USD ",DoubleToString(risk,2));
      if(InpPlayAlertSound) PlaySound(InpAlertSoundFile);
     }
  }
