#ifndef BCSO_TAKE_PROFIT_RULES
#define BCSO_TAKE_PROFIT_RULES

enum TpMode { NEAREST_ZONE, SPIKE_QUANTILE };
input TpMode InpTpMode=NEAREST_ZONE;
input int InpSpikeHistoryDays=3;
input int InpTpSpikeLookbackN=40;
input int InpTpMinSpikes=15;
input double InpTpFallbackWidths=3.3;
input double InpTpSpikeQuantile=0.25;
input double InpTpMinWidths=2.5;
input double InpTpMaxWidths=6.0;
input double InpTpMinRR=2.0;
input bool InpTpIgnoreIntermediateZones=true;

double g_tp_spike_sizes[];
datetime g_tp_last_m1=0;
int g_tp_spikes_loaded=0;

bool TpInputsValid()
  {
   return (InpTpMode==NEAREST_ZONE || InpTpMode==SPIKE_QUANTILE) && InpSpikeHistoryDays>=1 &&
          InpSpikeHistoryDays<=30 && InpTpSpikeLookbackN>=1 && InpTpSpikeLookbackN<=500 &&
          InpTpMinSpikes>=1 && InpTpMinSpikes<=InpTpSpikeLookbackN && InpTpFallbackWidths>0.0 &&
          InpTpSpikeQuantile>=0.0 && InpTpSpikeQuantile<=1.0 && InpTpMinWidths>0.0 &&
          InpTpMaxWidths>=InpTpMinWidths && InpTpMinRR>0.0;
  }

void TpPushSpike(double &sizes[],const double size,const int limit)
  {
   if(size<=0.0 || !MathIsValidNumber(size)) return;
   int n=ArraySize(sizes);
   if(n>=limit) { ArrayRemove(sizes,0,1); n=ArraySize(sizes); }
   if(ArrayResize(sizes,n+1)==n+1) sizes[n]=size;
  }

int TpCollectSpikeSizes(const MqlRates &rates[],const bool boom,const int limit,double &sizes[])
  {
   ArrayResize(sizes,0);
   for(int shift=ArraySize(rates)-InpSpikeMedianBars-1;shift>=1;shift--)
     {
      if(!IsSpikeM1(rates,shift)) continue;
      bool own_direction=boom ? rates[shift].close>rates[shift].open : rates[shift].close<rates[shift].open;
      if(own_direction) TpPushSpike(sizes,rates[shift].high-rates[shift].low,limit);
     }
   return ArraySize(sizes);
  }

double TpQuantileFrom(const double &values[],const double q,const int minimum)
  {
   int n=ArraySize(values);
   if(n<minimum || n<1 || q<0.0 || q>1.0) return 0.0;
   double sorted[]; ArrayResize(sorted,n); ArrayCopy(sorted,values,0,0,n); ArraySort(sorted);
   double pos=(n-1)*q; int lo=(int)MathFloor(pos),hi=(int)MathCeil(pos);
   return sorted[lo]+(sorted[hi]-sorted[lo])*(pos-lo);
  }

double SpikeSizeQuantile(const double q)
  { return TpQuantileFrom(g_tp_spike_sizes,q,InpTpMinSpikes); }

double TpClampedDistance(const double spike_size,const double width,const double fallback_widths,
                         const double min_widths,const double max_widths)
  {
   if(width<=0.0 || min_widths<=0.0 || max_widths<min_widths) return 0.0;
   double distance=spike_size>0.0 ? spike_size : fallback_widths*width;
   return MathMax(min_widths*width,MathMin(max_widths*width,distance));
  }

bool PlanTakeProfit(const int mode,const string side,const double entry,const double width,const double spread,
                    const double stop,const double current_target,const double spike_size,
                    const double fallback_widths,const double min_widths,const double max_widths,
                    const double min_rr,double &target,double &rr,string &reason)
  {
   target=0.0; rr=0.0; reason="";
   if((side!="BUY" && side!="SELL") || entry<=0.0 || width<=0.0 || stop<=0.0)
     { reason="TP_PLAN_INVALIDO"; return false; }
   if(mode==NEAREST_ZONE)
     {
      target=current_target;
      if(target<=0.0) { reason="TP_ZONA_NO_DISPONIBLE"; return false; }
      double gain=side=="BUY" ? target-entry : entry-target;
      rr=gain>0.0 ? gain/(MathAbs(entry-stop)+MathMax(0.0,spread)) : 0.0;
      if(gain<=0.0) { reason="TP_ZONA_DIRECCION_INVALIDA"; return false; }
      return true;
     }
   if(mode!=SPIKE_QUANTILE) { reason="TP_MODO_INVALIDO"; return false; }
   double distance=TpClampedDistance(spike_size,width,fallback_widths,min_widths,max_widths);
   if(distance<=0.0) { reason="TP_DISTANCIA_INVALIDA"; return false; }
   target=entry+(side=="BUY" ? distance : -distance);
   rr=distance/(MathAbs(entry-stop)+MathMax(0.0,spread));
   if(rr<min_rr) reason="TP_RR_INSUFICIENTE";
   return true;
  }

double TpSelectedTarget(const string side,const double entry,const double width,const double spread,
                        const double stop,const double current_target)
  {
   if(InpTpMode==NEAREST_ZONE) return current_target;
   double target=0.0,rr=0.0; string reason="";
   PlanTakeProfit((int)InpTpMode,side,entry,width,spread,stop,current_target,
                  SpikeSizeQuantile(InpTpSpikeQuantile),InpTpFallbackWidths,InpTpMinWidths,
                  InpTpMaxWidths,InpTpMinRR,target,rr,reason);
   return target;
  }

bool TpIsOwnSpike(const MqlRates &bar)
  { return IsBoomSymbol() ? bar.close>bar.open : IsCrashSymbol() && bar.close<bar.open; }

bool TakeProfitInitialize()
  {
   ArrayResize(g_tp_spike_sizes,0); g_tp_spikes_loaded=0;
   int requested=InpSpikeHistoryDays*1440+InpSpikeMedianBars+2;
   MqlRates rates[];
   if(LoadRates(PERIOD_M1,requested,rates))
      g_tp_spikes_loaded=TpCollectSpikeSizes(rates,IsBoomSymbol(),InpTpSpikeLookbackN,g_tp_spike_sizes);
   g_tp_last_m1=iTime(_Symbol,PERIOD_M1,1);
   Print("TP_SPIKES: cargados ",g_tp_spikes_loaded," | ventana ",InpSpikeHistoryDays,
         " días | tope ",InpTpSpikeLookbackN," | modo ",EnumToString(InpTpMode));
   return true;
  }

void TakeProfitOnNewM1()
  {
   MqlRates rates[];
   if(!LoadRates(PERIOD_M1,InpSpikeMedianBars+3,rates) || ArraySize(rates)<InpSpikeMedianBars+2) return;
   if(rates[1].time<=0 || rates[1].time==g_tp_last_m1) return;
   g_tp_last_m1=rates[1].time;
   if(IsSpikeM1(rates,1) && TpIsOwnSpike(rates[1]))
     { TpPushSpike(g_tp_spike_sizes,rates[1].high-rates[1].low,InpTpSpikeLookbackN); g_tp_spikes_loaded=ArraySize(g_tp_spike_sizes); }
  }

string TpPlansFile() { return TaggedCsv("BCSO_"+SafeSymbolName()+"_tp_plans_v1604.csv"); }

void RecordTakeProfitPlan(const string event_id,const string module,const string side,const Zone &zone,
                          const Trend m5,const Trend m15,const MqlTick &quote,const double stop,
                          const double current_target,const double volume,const datetime bar)
  {
   double entry=side=="BUY" ? quote.ask : quote.bid,width=MathMax(_Point,zone.upper-zone.lower);
   double spread=MathMax(0.0,quote.ask-quote.bid),q25=SpikeSizeQuantile(0.25),q50=SpikeSizeQuantile(0.50);
   double zone_tp=current_target,chosen=0.0,chosen_rr=0.0; string chosen_reason="";
   double tp25=0.0,tp50=0.0,tp3=0.0,tp4=0.0,rr=0.0; string reason="";
   PlanTakeProfit((int)InpTpMode,side,entry,width,spread,stop,current_target,
                  SpikeSizeQuantile(InpTpSpikeQuantile),InpTpFallbackWidths,InpTpMinWidths,
                  InpTpMaxWidths,InpTpMinRR,chosen,chosen_rr,chosen_reason);
   PlanTakeProfit((int)SPIKE_QUANTILE,side,entry,width,spread,stop,zone_tp,q25,InpTpFallbackWidths,InpTpMinWidths,InpTpMaxWidths,InpTpMinRR,tp25,rr,reason);
   PlanTakeProfit((int)SPIKE_QUANTILE,side,entry,width,spread,stop,zone_tp,q50,InpTpFallbackWidths,InpTpMinWidths,InpTpMaxWidths,InpTpMinRR,tp50,rr,reason);
   PlanTakeProfit((int)SPIKE_QUANTILE,side,entry,width,spread,stop,zone_tp,3.0*width,InpTpFallbackWidths,InpTpMinWidths,InpTpMaxWidths,InpTpMinRR,tp3,rr,reason);
   PlanTakeProfit((int)SPIKE_QUANTILE,side,entry,width,spread,stop,zone_tp,4.0*width,InpTpFallbackWidths,InpTpMinWidths,InpTpMaxWidths,InpTpMinRR,tp4,rr,reason);
   string row[]; ArrayResize(row,20);
   row[0]=event_id; row[1]=TimeToString((datetime)(quote.time_msc/1000),TIME_DATE|TIME_SECONDS); row[2]=side;
   row[3]=DoubleToString(entry,_Digits); row[4]=DoubleToString(width,_Digits); row[5]=DoubleToString(spread,_Digits);
   row[6]=zone_tp>0.0 ? DoubleToString(zone_tp,_Digits) : ""; row[7]=DoubleToString(tp25,_Digits); row[8]=DoubleToString(tp50,_Digits);
   row[9]=DoubleToString(tp3,_Digits); row[10]=DoubleToString(tp4,_Digits); row[11]=(string)ArraySize(g_tp_spike_sizes);
   row[12]=q25>0.0 ? DoubleToString(q25,_Digits) : ""; row[13]=q50>0.0 ? DoubleToString(q50,_Digits) : "";
   row[14]=EnumToString(InpTpMode); row[15]=chosen>0.0 ? DoubleToString(chosen,_Digits) : "";
   row[16]=DoubleToString(chosen_rr,5); row[17]="module="+module+"|"+(chosen_reason=="" ? "shadow_only" : chosen_reason)+
      "|ignore_intermediate="+(InpTpIgnoreIntermediateZones ? "true" : "false")+
      (ArraySize(g_tp_spike_sizes)<InpTpMinSpikes ? "|fallback_widths="+DoubleToString(InpTpFallbackWidths,2) : "");
   row[18]=OBSERVER_BUILD_TAG; row[19]=g_writer_session;
   AppendDiagnostic(TpPlansFile(),"event_id;time_server;side;entry;width;spread;tp_zone;tp_q25;tp_q50;tp_3w;tp_4w;n_spikes;q25;q50;tp_mode;tp_chosen;rr_net;note;writer_build;writer_session",row);
   double targets[5]={zone_tp,tp25,tp50,tp3,tp4}; string tags[5]={"TPZONE","TPQ25","TPQ50","TP3W","TP4W"};
   for(int i=0;i<5;i++)
      VariantsObserve(event_id+"_"+tags[i],module+"_"+tags[i],side,zone,m5,m15,quote,stop,targets[i],volume,bar,
                      "shadow_only|tp_variant="+tags[i]+"|base_event_id="+event_id);
  }

#ifdef BCSO_VARIANTS_TEST
void TakeProfitRulesSelfTest()
  {
   double known[4]={1.0,2.0,3.0,4.0};
   Check1604(MathAbs(TpQuantileFrom(known,0.25,4)-1.75)<1e-8,"TP cuantil conocido q25");
   double few[2]={2.0,4.0};
   Check1604(TpQuantileFrom(few,0.25,3)==0.0,"TP cuantil insuficiente activa respaldo");
   double target=0.0,rr=0.0; string reason="";
   Check1604(PlanTakeProfit((int)SPIKE_QUANTILE,"BUY",100.0,2.0,0.5,97.0,101.0,8.0,3.3,2.5,6.0,2.0,target,rr,reason) &&
             target==108.0 && rr>2.0,"TP compra cuantílico incluye spread y omite zona cercana");
   Check1604(PlanTakeProfit((int)SPIKE_QUANTILE,"SELL",100.0,2.0,0.5,103.0,99.0,8.0,3.3,2.5,6.0,2.0,target,rr,reason) &&
             target==92.0 && rr>2.0,"TP venta cuantílico incluye spread");
   PlanTakeProfit((int)SPIKE_QUANTILE,"BUY",100.0,2.0,0.0,97.0,0.0,0.5,3.3,2.5,6.0,1.0,target,rr,reason);
   Check1604(target==105.0,"TP aplica ancho mínimo");
   PlanTakeProfit((int)SPIKE_QUANTILE,"BUY",100.0,2.0,0.0,97.0,0.0,100.0,3.3,2.5,6.0,1.0,target,rr,reason);
   Check1604(target==112.0,"TP aplica ancho máximo");
   PlanTakeProfit((int)SPIKE_QUANTILE,"BUY",100.0,2.0,0.5,97.0,0.0,5.0,3.3,2.5,6.0,2.0,target,rr,reason);
   Check1604(reason=="TP_RR_INSUFICIENTE","TP puerta RR bloquea insuficiente");
   PlanTakeProfit((int)SPIKE_QUANTILE,"BUY",100.0,2.0,0.0,97.0,0.0,0.0,3.3,2.5,6.0,1.0,target,rr,reason);
   Check1604(MathAbs(target-106.6)<1e-8,"TP fallback 3.3 anchos con pocos spikes");
   Check1604(InpTpMode==NEAREST_ZONE,"TP modo predeterminado conserva zona cercana");
   MqlRates rates[]; ArrayResize(rates,120); ArraySetAsSeries(rates,true);
   for(int i=0;i<ArraySize(rates);i++) { rates[i].open=100.0; rates[i].close=100.1; rates[i].low=99.5; rates[i].high=100.5; }
   rates[10].high=110.0; rates[10].close=109.0; rates[5].low=90.0; rates[5].close=91.0; rates[2].high=111.0; rates[2].close=110.0;
   double recovered[]; int boom=TpCollectSpikeSizes(rates,true,40,recovered);
   Check1604(boom==2,"TP recupera solo spikes Boom ascendentes conocidos");
   int crash=TpCollectSpikeSizes(rates,false,40,recovered);
   Check1604(crash==1,"TP recupera spike Crash descendente conocido");
  }
#endif

#endif
