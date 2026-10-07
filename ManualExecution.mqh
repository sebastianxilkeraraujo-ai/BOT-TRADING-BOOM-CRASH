#ifndef BCSO_MANUAL_EXECUTION
#define BCSO_MANUAL_EXECUTION

input bool InpExecManual=false;
input double InpManualApproachWidths=0.5;
input int InpManualCooldownMinutes=30;
input double InpManualStopWidths=1.0;
enum ManualTargetMode { FIXED_WIDTHS, NEAREST_LEVEL };
input ManualTargetMode InpManualTargetMode=FIXED_WIDTHS;
input double InpManualTargetWidths=4.0;
input int InpExecTimeStopMinutes=0;
input bool InpRetraceExitEnabled=true;
input double InpRetraceExitPercent=25.0;
input double InpRetraceActivationR=1.0;
input double InpRetraceMinVolatilityFraction=0.25;

struct ManualApproach
  {
   string key;
   bool armed,seen;
   double previous,reference;
  };
ManualApproach g_manual_approaches[];
string g_manual_exec_detail="";

bool ManualExecInputsValid()
  {
   return InpManualApproachWidths>0.0 && InpManualCooldownMinutes>=1 &&
          InpManualStopWidths>0.0 && InpPlanRiskMaxUSD>0.0 && InpPlanRiskMaxUSD<=2.0 &&
          InpManualTargetWidths>0.0 && InpExecTimeStopMinutes>=0 &&
          InpExecTimeStopMinutes<=1440 &&
          InpRetraceExitPercent>0.0 && InpRetraceExitPercent<100.0 &&
          InpRetraceActivationR>0.0 && InpRetraceMinVolatilityFraction>=0.0 &&
          (InpManualTargetMode==FIXED_WIDTHS || InpManualTargetMode==NEAREST_LEVEL);
  }
bool ManualEarlyEnabled(const string id)
  {
   if(StringFind(id,"LEVEL_EARLY_")!=0) return false;
   return StringFind(id,"_MANUAL_")>=0 ? InpExecManual : InpExecStructural;
  }
string ManualExecDetail(const string id,const string detail)
  { return StringFind(id,"LEVEL_EARLY_")==0 && g_manual_exec_detail!="" ? detail+"|"+g_manual_exec_detail : detail; }
bool ManualQuoteFresh(const long quote_msc)
  {
   long now=(long)TimeCurrent()*1000+999;
   return quote_msc>0 && now>=quote_msc && now-quote_msc<=5000;
  }
bool ManualExecArmRequest(const string id)
  {
   string key=g_exec_account+"manreq_"+(string)ExecHash(id);
   bool ok=GlobalVariableSet(key,(double)TimeCurrent())!=0;
   if(ok) GlobalVariablesFlush();
   return ok;
  }

// The first observed quote inside the band cannot trigger. The arming quote
// must be at least approach_widths full band widths away on the correct side.
bool ManualTriggerDecision(const bool buy,const double lower,const double upper,
                           const double previous,const double price,const double approach_widths,
                           const datetime active_from,const datetime tick_time,
                           const datetime last_attempt,const int cooldown,bool &armed)
  {
   if(upper<=lower || active_from<=0 || tick_time<active_from)
     { armed=false; return false; }
   double width=upper-lower;
   bool far=buy ? previous>=upper+approach_widths*width
                : previous<=lower-approach_widths*width;
   if(far) armed=true;
   bool inside=price>=lower && price<=upper;
   bool approached=buy ? previous>upper : previous<lower;
   if(!inside || !approached || !armed) return false;
   armed=false;
   return last_attempt<=0 || tick_time-last_attempt>=cooldown*60;
  }
void ManualStopTarget(const bool buy,const Zone &zone,const double entry,
                      const double buffer,const double stop_widths,const double target_widths,
                      double &stop,double &fixed_target)
  {
   double width=MathMax(_Point,zone.upper-zone.lower);
   stop=(buy ? zone.lower : zone.upper)+(buy ? -1.0 : 1.0)*MathMax(buffer,stop_widths*width);
   fixed_target=entry+(buy ? 1.0 : -1.0)*target_widths*width;
  }
bool ManualRiskTooHigh(const double min_lot_risk,const double limit)
  { return !MathIsValidNumber(min_lot_risk) || min_lot_risk>limit+1e-8; }

// Directly verify a cached object's geometry. This does not enumerate chart
// objects on every tick and prevents a moved/deleted line from firing stale.
bool ManualObjectCurrent(const AdditionalLevel &level)
  {
   if(!level.manual) return true;
   for(int i=0;i<ArraySize(g_manual_objects);i++)
     {
      ManualLevelState state=g_manual_objects[i];
      if("MANUAL_"+(string)state.chart+"_"+state.name+"_"+(string)(long)state.changed!=level.key)
         continue;
      if(!state.present || ObjectFind(state.chart,state.name)<0) return false;
      int type=(int)ObjectGetInteger(state.chart,state.name,OBJPROP_TYPE);
      double p1=ObjectGetDouble(state.chart,state.name,OBJPROP_PRICE,0);
      double p2=type==OBJ_HLINE ? p1 : ObjectGetDouble(state.chart,state.name,OBJPROP_PRICE,1);
      return type==state.type && p1==state.p1 && p2==state.p2 &&
             (datetime)ObjectGetInteger(state.chart,state.name,OBJPROP_CREATETIME)==state.created;
     }
   return false;
  }
int ManualApproachSlot(const string key)
  {
   for(int i=0;i<ArraySize(g_manual_approaches);i++) if(g_manual_approaches[i].key==key) return i;
   int n=ArraySize(g_manual_approaches);
   if(n>=2048 || ArrayResize(g_manual_approaches,n+1)!=n+1) return -1;
   ManualApproach fresh={}; fresh.key=key; g_manual_approaches[n]=fresh;
   return n;
  }
string ManualCooldownKey(const Zone &zone,const string level_id)
  { return g_exec_account+"man_cd_"+(string)ExecHash(ZoneAlertKey("EXEC_MANUAL",zone)+"|"+level_id); }
string ManualLevelSource(const AdditionalLevel &level)
  { return level.manual ? "MANUAL" : "STRUCT_"+level.source; }

void ManualEarlyAttempt(const AdditionalLevel &level,const string side,const MqlTick &q,
                        const double approach)
  {
   string id="LEVEL_EARLY_"+(level.manual ? "MANUAL_" : "STRUCT_")+
             (string)ExecHash(level.key)+"_"+(string)q.time_msc;
   string key=ManualCooldownKey(level.zone,level.key);
   // A failed durable cooldown is a blocked attempt, never a second order.
   if(GlobalVariableSet(key,(double)q.time)==0) return;
   GlobalVariablesFlush(); RememberZoneAlert(ZoneAlertKey("EXEC_MANUAL",level.zone),q.time);
   double entry=side=="BUY" ? q.ask : q.bid,stop=0.0,fixed=0.0;
   ManualStopTarget(side=="BUY",level.zone,entry,StopBuffer(),InpManualStopWidths,
                    InpManualTargetWidths,stop,fixed);
   double zone_target=InpManualTargetMode==FIXED_WIDTHS ? fixed : AdditionalTarget(side,entry,q.time);
   double width=MathMax(_Point,level.zone.upper-level.zone.lower),spread=MathMax(0.0,q.ask-q.bid);
   double target=TpSelectedTarget(side,entry,width,spread,stop,zone_target);
   double volume=0.0,risk=0.0,minrisk=0.0; string reason="";
   double minlot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double adverse=entry+(side=="BUY" ? 1.0 : -1.0)*InpExecutionDeviationPoints*point,profit=0.0;
   if(minlot<=0.0 || !OrderCalcProfit(side=="BUY" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                                      _Symbol,minlot,adverse,stop,profit) || profit>=0.0)
      reason="RIESGO_NO_CALCULABLE";
   else
     {
      minrisk=-profit;
      if(ManualRiskTooHigh(minrisk,InpPlanRiskMaxUSD)) reason="RIESGO_SUPERA_LIMITE";
      else if(!StrategyRiskVolume(side,adverse,stop,volume,risk,reason)) {}
      else if(risk>InpPlanRiskMaxUSD) reason="RIESGO_SUPERA_LIMITE";
     }
   double reward=side=="BUY" ? target-entry : entry-target;
   double rr=MathAbs(entry-stop)>_Point ? reward/(MathAbs(entry-stop)+spread) : 0.0;
   if(reason=="" && (target<=0.0 || reward<=0.0 ||
      (InpTpMode==NEAREST_ZONE && rr<InpMinimumRewardRisk))) reason="OBJETIVO_O_RR_INSUFICIENTE";
   if(reason=="" && InpTpMode==SPIKE_QUANTILE && rr<InpTpMinRR) reason="TP_RR_INSUFICIENTE";
   string source=ManualLevelSource(level);
   g_manual_exec_detail="level_id="+level.key+"|level_source="+source+
      "|first_seen="+TimeToString(level.formed_at,TIME_DATE|TIME_SECONDS)+
      "|active_from="+TimeToString(level.known_at,TIME_DATE|TIME_SECONDS)+
      "|approach_widths="+DoubleToString(approach,4)+
      "|planned_sl="+DoubleToString(stop,_Digits)+"|planned_tp="+DoubleToString(target,_Digits)+
      "|planned_risk_usd="+DoubleToString(risk>0.0 ? risk : minrisk,5);
   MqlTradeRequest req={}; req.type=side=="BUY" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.symbol=_Symbol; req.price=entry; req.sl=stop; req.tp=target; req.volume=volume;
   if(!ExecLog(id,"ATTEMPT","disparo_por_tick",req,risk,0.0))
     { g_manual_exec_detail=""; return; }
   datetime signal_bar=(datetime)(q.time_msc/60000*60);
   string stage=(level.manual ? "MANUAL_" : "ESTRUCTURAL_")+"ANTICIPADA_"+
                (reason=="" ? "EVALUADA" : "DESCARTADA");
   Trend m5=DetectTrend(PERIOD_M5,InpScanBarsM5),m15=DetectTrend(PERIOD_M15,InpScanBarsM15);
   if(!StrategyAppendPlan(id,signal_bar,stage,side,level.zone,m15,entry,stop,target,volume,risk,
                          reason+"|"+g_manual_exec_detail))
      reason="PLAN_NO_PERSISTIDO";
   else
     {
      g_record_zone_alert=false; g_record_volume=volume; g_record_risk_usd=risk;
      g_record_risk_exceeds=risk>InpPlanRiskMaxUSD; g_record_leg_spike=false; g_record_legacy_stop=stop;
      bool candidate=stop<=0.0 || target<=0.0 || reward<=0.0;
      bool saved=RecordObservation("M5_MANUAL_EARLY",side,level.zone,m5,m15,TREND_NONE,
                                  reason+"|"+g_manual_exec_detail,q,stop,target,signal_bar,candidate);
      if(saved) RecordTakeProfitPlan(id,"M5_MANUAL_EARLY",side,level.zone,m5,m15,q,stop,zone_target,volume,signal_bar);
      g_record_volume=0.0; g_record_risk_usd=0.0; g_record_risk_exceeds=false;
      if(!saved && reason=="") reason="OBSERVACION_NO_PERSISTIDA";
   }
   // The control is a shadow observation, including blocked attempts with a
   // calculable stop/target. It never sends an order.
   if(InpEnableControlEntries && stop>0.0 && target>0.0 && reward>0.0 && minlot>0.0)
      VariantsSchedule(id,id,"M5_MANUAL_EARLY",side,level.zone,q,stop,target,
                       volume>0.0 ? volume : minlot);
   else if(InpEnableControlEntries)
      VariantsDiscard(id+"_CONTROL","M5_MANUAL_EARLY","CONTROL_SIN_PRECIO_O_VOLUMEN_CALCULABLE");
   if(reason=="")
     {
      if(!ManualEarlyEnabled(id)) reason="INPUT_EXEC_LEVEL_OFF";
      else if(!InpDemoExecution) reason="INPUT_DEMO_EXEC_OFF";
   }
   if(reason!="") ExecLog(id,"DESCARTADA",reason,req,risk,0.0);
   else DemoExecuteConfirmed(id,side,level.zone,signal_bar,stop,target,true);
   g_manual_exec_detail="";
  }

void ObserveManualEarlyTicks()
  {
   if(!InpUseM5ReactionStrategy || !ActivePack()) return;
   MqlTick q; if(!SymbolInfoTick(_Symbol,q) || q.bid<=0.0 || q.ask<q.bid || q.time_msc<=0) return;
   bool buy=IsBoomSymbol(); if(!buy && !IsCrashSymbol()) return;
   ZoneKind kind=buy ? ZONE_SUPPORT : ZONE_RESISTANCE;
   for(int group=0;group<2;group++)
     {
      int n=group==0 ? ArraySize(g_manual_levels) : ArraySize(g_struct_levels);
      for(int i=0;i<n;i++)
        {
         AdditionalLevel level;
         if(group==0) level=g_manual_levels[i]; else level=g_struct_levels[i];
         if(level.zone.kind!=kind || !LevelKnown(level,q.time) || !ManualObjectCurrent(level)) continue;
         int slot=ManualApproachSlot(level.key);
         if(slot<0) { Print("MANEXEC: limite de niveles; medicion incompleta"); return; }
         double price=q.bid,prev=g_manual_approaches[slot].previous;
         if(!g_manual_approaches[slot].seen)
           { g_manual_approaches[slot].seen=true; g_manual_approaches[slot].previous=price; continue; }
         double width=MathMax(_Point,level.zone.upper-level.zone.lower);
         bool far=buy ? prev>=level.zone.upper+InpManualApproachWidths*width
                      : prev<=level.zone.lower-InpManualApproachWidths*width;
         if(far && !g_manual_approaches[slot].armed) g_manual_approaches[slot].reference=prev;
         datetime last=(datetime)GlobalVariableGet(ManualCooldownKey(level.zone,level.key));
         bool fire=ManualTriggerDecision(buy,level.zone.lower,level.zone.upper,prev,price,
                        InpManualApproachWidths,level.known_at,q.time,last,InpManualCooldownMinutes,
                        g_manual_approaches[slot].armed);
         g_manual_approaches[slot].previous=price;
         if(fire)
           {
            double approach=buy ? (g_manual_approaches[slot].reference-level.zone.upper)/width
                                : (level.zone.lower-g_manual_approaches[slot].reference)/width;
            ManualEarlyAttempt(level,buy ? "BUY" : "SELL",q,MathMax(0.0,approach));
           }
        }
     }
  }

void ManualTradeTransaction(const MqlTradeTransaction &trans)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0 ||
      !HistoryDealSelect(trans.deal) ||
      (ulong)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=VariantsMagic() ||
      HistoryDealGetInteger(trans.deal,DEAL_ENTRY)!=DEAL_ENTRY_IN) return;
   ulong order=(ulong)HistoryDealGetInteger(trans.deal,DEAL_ORDER);
   string comment=HistoryDealGetString(trans.deal,DEAL_COMMENT);
   if(HistoryOrderSelect(order)) comment=HistoryOrderGetString(order,ORDER_COMMENT);
   if(StringFind(comment,"BCSO|")!=0) return;
   string hash=StringSubstr(comment,5);
   if(!GlobalVariableCheck(g_exec_account+"manreq_"+hash)) return;
   long position=HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
   if(position>0 && GlobalVariableSet(g_exec_account+"manpos_"+(string)position,1.0)!=0)
      GlobalVariablesFlush();
  }

bool RetraceExitDecision(const bool buy,const double entry,const double stop,const double best,
                         const double current,const double spread,const double m5_width,
                         const double retrace_pct,const double activation_r,
                         const double min_vol_fraction,const Trend trend_m5,
                         double &mfe_r,double &actual_pct,double &pullback,string &reason)
  {
   mfe_r=0.0; actual_pct=0.0; pullback=0.0; reason="";
   double risk=MathAbs(entry-stop),favorable=buy ? best-entry : entry-best;
   if(risk<=0.0 || favorable<=0.0) { reason="SIN_R_O_AVANCE_FAVORABLE"; return false; }
   mfe_r=favorable/risk; pullback=MathMax(0.0,buy ? best-current : current-best);
   actual_pct=100.0*pullback/favorable;
   if(mfe_r<activation_r) { reason="MFE_MENOR_A_ACTIVACION_R"; return false; }
   if(actual_pct<retrace_pct) { reason="RETROCESO_MENOR_AL_PORCENTAJE"; return false; }
   if(pullback<MathMax(spread,m5_width*min_vol_fraction))
     { reason="RETROCESO_MENOR_A_SPREAD_VOLATILIDAD"; return false; }
   bool broken=buy ? trend_m5==TREND_DOWN : trend_m5==TREND_UP;
   if(!broken) { reason="ESTRUCTURA_M5_NO_GIRADA"; return false; }
   reason="CIERRE_POR_RETRACEMENT_25"; return true;
  }

string RetraceStateKey(const string suffix,const long id)
  { return g_exec_account+"rx_"+suffix+"_"+(string)id; }
string RetraceExitFile()
  { return TaggedCsv("BCSO_"+SafeSymbolName()+"_retrace_exit_v1604.csv"); }

void RetraceExitWrite(const string event_id,const long position_id,const string side,
                      const double entry,const double sl,const double tp,const double volume,
                      const double best,const double mfe_r,const double pullback,const double pct,
                      const double min_pullback,const Trend m5,const Trend m15,
                      const string decision,const string detail,const uint retcode)
  {
   string row[]; ArrayResize(row,20);
   row[0]=event_id; row[1]=TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS);
   row[2]=(string)position_id; row[3]=side; row[4]=DoubleToString(entry,_Digits);
   row[5]=DoubleToString(sl,_Digits); row[6]=DoubleToString(tp,_Digits);
   row[7]=DoubleToString(volume,8); row[8]=DoubleToString(best,_Digits);
   row[9]=DoubleToString(mfe_r,4); row[10]=DoubleToString(pullback,_Digits);
   row[11]=DoubleToString(pct,3); row[12]=DoubleToString(InpRetraceExitPercent,2);
   row[13]=DoubleToString(min_pullback,_Digits); row[14]=StrategyTrendText(m5);
   row[15]=StrategyTrendText(m15); row[16]=decision; row[17]=detail;
   row[18]=(string)retcode; row[19]=OBSERVER_BUILD_TAG;
   AppendDiagnostic(RetraceExitFile(),
      "event_id;time_server;position_id;side;entry;sl;tp;volume;best_favorable_price;mfe_r;pullback_price;pullback_pct;configured_pct;minimum_pullback;m5_trend;m15_context;decision;detail;retcode;writer_build",row);
  }

datetime g_retrace_m5_bar=0,g_retrace_m15_bar=0;
Trend g_retrace_m5_trend=TREND_NONE,g_retrace_m15_trend=TREND_NONE;
void RetraceRefreshTrends()
  {
   datetime bar=iTime(_Symbol,PERIOD_M5,0);
   if(bar>0 && bar!=g_retrace_m5_bar)
     { g_retrace_m5_trend=DetectTrend(PERIOD_M5,InpScanBarsM5); g_retrace_m5_bar=bar; }
   bar=iTime(_Symbol,PERIOD_M15,0);
   if(bar>0 && bar!=g_retrace_m15_bar)
     { g_retrace_m15_trend=DetectTrend(PERIOD_M15,InpScanBarsM15); g_retrace_m15_bar=bar; }
  }

void RetraceExitPoll()
  {
   if(!InpRetraceExitEnabled || !InpDemoExecution || !ActivePack() ||
      AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO ||
      AccountInfoString(ACCOUNT_CURRENCY)!="USD" || AccountInfoInteger(ACCOUNT_LOGIN)!=g_exec_login ||
      !TerminalInfoInteger(TERMINAL_CONNECTED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_EXPERT) || InpExecKillSwitch ||
      GlobalVariableGet(g_exec_account+"stop")>0.0) return;
   if(!((IsBoomSymbol() || IsCrashSymbol()) && VariantsMagic()>0)) return;
   RetraceRefreshTrends();
   MqlTick q; if(!SymbolInfoTick(_Symbol,q) || !ManualQuoteFresh(q.time_msc)) return;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=VariantsMagic()) continue;
      bool buy=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
      if((IsBoomSymbol() && !buy) || (IsCrashSymbol() && buy)) continue;
      long id=PositionGetInteger(POSITION_IDENTIFIER);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP),volume=PositionGetDouble(POSITION_VOLUME);
      if(id<=0 || entry<=0.0 || sl<=0.0 || tp<=0.0 || volume<=0.0) continue;
      string peakkey=RetraceStateKey("peak",id),closekey=RetraceStateKey("close",id);
      double best=GlobalVariableCheck(peakkey) ? GlobalVariableGet(peakkey) : entry;
      double mark=buy ? q.bid : q.ask;
      bool new_best=buy ? mark>best : mark<best;
      if(new_best) { best=mark; if(GlobalVariableSet(peakkey,best)==0) continue; }
      double mfe_r=0.0,pct=0.0,pullback=0.0; string reason="";
      double spread=MathMax(0.0,q.ask-q.bid),min_pullback=MathMax(spread,MathMax(0.0,g_m5_range)*InpRetraceMinVolatilityFraction);
      if(!RetraceExitDecision(buy,entry,sl,best,mark,spread,g_m5_range,
                              InpRetraceExitPercent,InpRetraceActivationR,
                              InpRetraceMinVolatilityFraction,g_retrace_m5_trend,
                              mfe_r,pct,pullback,reason)) continue;
      if(GlobalVariableCheck(closekey) || OrdersTotal()>0) continue;
      double token=0.0; if(!ExecLock(token)) continue;
      MqlTick fresh; if(!SymbolInfoTick(_Symbol,fresh) || !ManualQuoteFresh(fresh.time_msc))
        { ExecUnlock(token); continue; }
      mark=buy ? fresh.bid : fresh.ask;
      if(!RetraceExitDecision(buy,entry,sl,best,mark,MathMax(0.0,fresh.ask-fresh.bid),g_m5_range,
                              InpRetraceExitPercent,InpRetraceActivationR,
                              InpRetraceMinVolatilityFraction,g_retrace_m5_trend,
                              mfe_r,pct,pullback,reason)) { ExecUnlock(token); continue; }
      MqlTradeRequest req={}; req.action=TRADE_ACTION_DEAL; req.position=ticket;
      req.symbol=_Symbol; req.magic=VariantsMagic(); req.volume=volume;
      req.type=buy ? ORDER_TYPE_SELL : ORDER_TYPE_BUY; req.price=buy ? fresh.bid : fresh.ask;
      req.deviation=InpExecutionDeviationPoints; req.comment="BCSO|RETRACE25";
      long filling=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
      if((filling&SYMBOL_FILLING_FOK)!=0) req.type_filling=ORDER_FILLING_FOK;
      else if((filling&SYMBOL_FILLING_IOC)!=0) req.type_filling=ORDER_FILLING_IOC;
      else { ExecUnlock(token); continue; }
      string event="RETRACE25_"+(string)id; MqlTradeCheckResult check={};
      bool checked=OrderCheck(req,check);
      if(!ExecCheckPassed(checked,check.retcode) ||
         !ExecLog(event,"PREPARADA","CIERRE_RETRACEMENT_25",req,0.0,0.0,check.retcode) ||
         GlobalVariableSet(closekey,(double)TimeCurrent())==0)
        { ExecUnlock(token); continue; }
      GlobalVariablesFlush(); MqlTradeResult result={}; bool sent=OrderSend(req,result);
      bool accepted=sent && (result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL ||
                             result.retcode==TRADE_RETCODE_PLACED);
      ExecLog(event,accepted ? "CIERRE_ACEPTADO" : "CIERRE_NO_CONFIRMADO",result.comment,req,0.0,0.0,
              result.retcode,result.order,result.deal);
      RetraceExitWrite(event,id,buy ? "BUY" : "SELL",entry,sl,tp,volume,best,mfe_r,pullback,pct,
                       min_pullback,g_retrace_m5_trend,g_retrace_m15_trend,
                       accepted ? "CLOSE_SENT" : "CLOSE_FAILED",reason,result.retcode);
      if(!accepted) GlobalVariableDel(closekey);
      ExecUnlock(token);
     }
  }

void RetraceExitTradeTransaction(const MqlTradeTransaction &trans)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0 || !HistoryDealSelect(trans.deal) ||
      HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol ||
      (ulong)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=VariantsMagic()) return;
   long entry=HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) return;
   long id=HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID); if(id<=0) return;
   for(int i=0;i<PositionsTotal();i++)
      if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_IDENTIFIER)==id) return;
   GlobalVariableDel(RetraceStateKey("peak",id));
   GlobalVariableDel(RetraceStateKey("close",id));
  }

void ManualTimeStopPoll()
  {
   if(InpExecTimeStopMinutes<=0 || !InpDemoExecution ||
      AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO ||
      AccountInfoString(ACCOUNT_CURRENCY)!="USD" || !TerminalInfoInteger(TERMINAL_CONNECTED) ||
      !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT) ||
      InpExecKillSwitch || GlobalVariableGet(g_exec_account+"stop")>0.0) return;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i); if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=VariantsMagic()) continue;
      long id=PositionGetInteger(POSITION_IDENTIFIER);
      if(!GlobalVariableCheck(g_exec_account+"manpos_"+(string)id) ||
         TimeCurrent()<PositionGetInteger(POSITION_TIME)+InpExecTimeStopMinutes*60) continue;
      string closekey=g_exec_account+"manclose_"+(string)id;
      if(GlobalVariableCheck(closekey) || OrdersTotal()>0) continue;
      double token=0.0; if(!ExecLock(token)) continue;
      MqlTick q; if(!SymbolInfoTick(_Symbol,q) || !ManualQuoteFresh(q.time_msc)) { ExecUnlock(token); continue; }
      MqlTradeRequest req={}; req.action=TRADE_ACTION_DEAL; req.position=ticket;
      req.symbol=_Symbol; req.magic=VariantsMagic(); req.volume=PositionGetDouble(POSITION_VOLUME);
      req.type=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price=req.type==ORDER_TYPE_SELL ? q.bid : q.ask;
      req.deviation=InpExecutionDeviationPoints; req.comment="BCSO|TIME_STOP";
      long filling=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
      if((filling&SYMBOL_FILLING_FOK)!=0) req.type_filling=ORDER_FILLING_FOK;
      else if((filling&SYMBOL_FILLING_IOC)!=0) req.type_filling=ORDER_FILLING_IOC;
      else { ExecUnlock(token); continue; }
      string event="MANUAL_TIME_STOP_"+(string)id;
      MqlTradeCheckResult check={}; bool checked=OrderCheck(req,check);
      if(!ExecCheckPassed(checked,check.retcode) ||
         !ExecLog(event,"PREPARADA","CIERRE_POR_TIEMPO",req,0.0,0.0) ||
         GlobalVariableSet(closekey,(double)TimeCurrent())==0)
        { ExecUnlock(token); continue; }
      GlobalVariablesFlush();
      MqlTradeResult result={}; bool sent=OrderSend(req,result);
      ExecLog(event,sent && (result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL ||
              result.retcode==TRADE_RETCODE_PLACED) ? "CIERRE_ACEPTADO" : "CIERRE_NO_CONFIRMADO",
              result.comment,req,0.0,0.0,result.retcode,result.order,result.deal);
      ExecUnlock(token);
     }
  }

string ManualSummaryFile()
  { return TaggedCsv("BCSO_"+SafeSymbolName()+"_manual_exec_summary_v1604.csv"); }
bool ManualSummaryExists(const datetime day)
  {
   string filename=ManualSummaryFile(); if(!FileIsExist(filename,FILE_COMMON)) return false;
   int handle=OpenCsvRetry(filename,FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON,';',CP_UTF8);
   if(handle==INVALID_HANDLE) return true; // fail closed, never duplicate a day
   string row[],key=TimeToString(day,TIME_DATE);
   bool found=false;
   while(ReadCsvRow(handle,row)) if(ArraySize(row)>0 && row[0]==key) { found=true; break; }
   FileClose(handle); return found;
  }
void ManualSummaryPoll()
  {
   static datetime checked_day=0,retry_after=0;
   MqlDateTime t; TimeToStruct(TimeCurrent(),t); t.hour=0; t.min=0; t.sec=0;
   datetime today=StructToTime(t);
   if(today<=0 || today==checked_day || TimeCurrent()<retry_after) return;
   retry_after=TimeCurrent()+60;
   datetime day=today-86400;
   if(ManualSummaryExists(day)) { checked_day=today; return; }
   int attempts=0,blocked=0,operations=0,hits=0;
   string reasons[],row[]; int counts[];
   string file=VariantsExecFile();
   int handle=INVALID_HANDLE;
   if(FileIsExist(file,FILE_COMMON))
      handle=OpenCsvRetry(file,FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON,';',CP_UTF8);
   if(handle!=INVALID_HANDLE)
     {
      while(ReadCsvRow(handle,row))
        {
         if(ArraySize(row)<15 || StringFind(row[0],"LEVEL_EARLY_")!=0 ||
            StringFind(row[1],TimeToString(day,TIME_DATE))!=0) continue;
         string state=row[14]; int sep=StringFind(state,"|");
         string status=sep>=0 ? StringSubstr(state,0,sep) : state;
         if(status=="ATTEMPT") attempts++;
         if(status!="DESCARTADA" && status!="RECHAZADA_BROKER" && status!="ESTADO_INCIERTO_BLOQUEADO") continue;
         blocked++;
         string tail=sep>=0 ? StringSubstr(state,sep+1) : "";
         int end=StringFind(tail,"|"); string reason=end>=0 ? StringSubstr(tail,0,end) : tail;
         int index=-1; for(int j=0;j<ArraySize(reasons);j++) if(reasons[j]==reason) { index=j; break; }
         if(index<0) { index=ArraySize(reasons); ArrayResize(reasons,index+1); ArrayResize(counts,index+1); reasons[index]=reason; counts[index]=0; }
         counts[index]++;
        }
      FileClose(handle);
     }
   double net=0.0;
   if(!HistorySelect(day-30*86400,today)) return;
   long positions[];
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      ulong deal=HistoryDealGetTicket(i); if(deal==0 || HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol ||
         (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=VariantsMagic()) continue;
      long pos=HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      datetime when=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);
      if(pos<=0 || !GlobalVariableCheck(g_exec_account+"manpos_"+(string)pos) ||
         when<day || when>=today || HistoryDealGetInteger(deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      bool duplicate=false; for(int j=0;j<ArraySize(positions);j++) if(positions[j]==pos) { duplicate=true; break; }
      if(!duplicate) { int n=ArraySize(positions); ArrayResize(positions,n+1); positions[n]=pos; }
     }
   for(int j=0;j<ArraySize(positions);j++)
     {
      double result=0.0;
      for(int i=0;i<HistoryDealsTotal();i++)
        {
         ulong deal=HistoryDealGetTicket(i); if(deal==0 ||
            HistoryDealGetInteger(deal,DEAL_POSITION_ID)!=positions[j]) continue;
         result+=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_COMMISSION)+
                 HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_FEE);
        }
      operations++; if(result>0.0) hits++; net+=result;
     }
   string histogram=""; for(int i=0;i<ArraySize(reasons);i++) histogram+=(i>0 ? "|" : "")+reasons[i]+":"+(string)counts[i];
   string values[]; ArrayResize(values,9);
   values[0]=TimeToString(day,TIME_DATE); values[1]=(string)attempts; values[2]=(string)blocked;
   values[3]=histogram; values[4]=(string)operations; values[5]=(string)hits;
   values[6]=DoubleToString(net,5); values[7]=OBSERVER_BUILD_TAG; values[8]=g_writer_session;
   if(AppendDiagnostic(ManualSummaryFile(),
      "day_server;attempts;blocked;block_reasons;closed_positions;wins;net_usd;writer_build;writer_session",values))
      checked_day=today;
  }

#ifdef BCSO_VARIANTS_TEST
void ManualExecSelfTest()
  {
   Check1604(!InpDemoExecution && !InpEarlyZoneEntry && !InpExecManual && !InpExecStructural,
             "manexec controles apagados por defecto");
   Check1604(StringFind(OBSERVER_BUILD_TAG,"-manexec")>=0,"manexec etiqueta de revisión");
   double mfe_r=0.0,pct=0.0,pullback=0.0; string why="";
   Check1604(RetraceExitDecision(true,100,99,102,101.4,0.1,1.0,25,1,0.25,TREND_DOWN,
                                 mfe_r,pct,pullback,why) && MathAbs(pct-30.0)<1e-8,
             "retracement 25% activa compra tras 1R y giro M5");
   Check1604(!RetraceExitDecision(true,100,99,102,101.4,0.1,1.0,25,1,0.25,TREND_UP,
                                  mfe_r,pct,pullback,why) && why=="ESTRUCTURA_M5_NO_GIRADA",
             "continuidad M5 conserva la posición");
   Check1604(!RetraceExitDecision(true,100,99,102,101.6,0.1,1.0,25,1,0.25,TREND_DOWN,
                                  mfe_r,pct,pullback,why),"retroceso menor a 25% no cierra");
   Check1604(!RetraceExitDecision(false,100,101,98,98.4,0.1,1.0,25,1,0.25,TREND_UP,
                                  mfe_r,pct,pullback,why) && MathAbs(pct-20.0)<1e-8,
             "venta Crash conserva con retroceso menor al 25%");
   ulong own_positions[]; ArrayResize(own_positions,1); own_positions[0]=44;
   Check1604(ExecOwnedDeal(160402,44,"Boom 1000 Index",own_positions) &&
             ExecOwnedDeal(0,44,"",own_positions) && !ExecOwnedDeal(0,45,"",own_positions),
             "neto diario excluye operación manual");
   Check1604(!ExecOwnedDeal(160402,45,"Crash 1000 Index",own_positions),
             "presupuesto diario del Boom no incluye operaciones del Crash");
   bool armed=false;
   Check1604(!ManualTriggerDecision(true,99,101,100,100,0.5,1000,1100,0,30,armed),
             "empieza dentro sin disparar");
   Check1604(!ManualTriggerDecision(true,99,101,103,102,0.5,1000,1100,0,30,armed) && armed,
             "entrada desde lejos prepara aproximacion");
   Check1604(ManualTriggerDecision(true,99,101,102,100,0.5,1000,1101,0,30,armed) && !armed,
             "primera entrada en banda dispara una vez");
   armed=false;
   Check1604(!ManualTriggerDecision(true,99,101,103,100,0.5,1200,1101,0,30,armed),
             "nivel posterior al toque no dispara");
   armed=false;
   Check1604(!ManualTriggerDecision(true,99,101,103,100,0.5,1000,1101,1100,30,armed),
             "segundo toque durante enfriamiento no dispara");
   armed=false;
   Check1604(ManualTriggerDecision(false,99,101,97,100,0.5,1000,3000,0,30,armed),
             "venta en resistencia desde abajo");
   Zone z=MakeZone(PERIOD_M5,ZONE_SUPPORT,100,1,0); double stop=0,target=0;
   ManualStopTarget(true,z,101,0.5,1,4,stop,target);
   Check1604(stop==97 && target==109 && MathAbs(StrategyVolumeGrid(4,0.1,0.1,1,1,1.5)-0.3)<1e-8,
             "compra: stop objetivo y rejilla de riesgo");
   ManualStopTarget(false,z,99,0.5,1,4,stop,target);
   Check1604(stop==103 && target==91 && MathAbs(StrategyVolumeGrid(4,0.1,0.1,1,1,1.5)-0.3)<1e-8,
             "venta: stop objetivo y rejilla de riesgo");
   Check1604(ManualRiskTooHigh(2.01,2.0) && !ManualRiskTooHigh(1.50,2.0),
             "lote minimo sobre 2 USD se descarta");
   ExecGuardState guard=VariantsGuardDefaults(); guard.demo=true; guard.usd=true; guard.sl_valid=true;
   guard.loss_limit=10; guard.max_errors=3; guard.max_trades=12; guard.max_losses=4;
   guard.now=1000; guard.kill=true;
   Check1604(ExecGuardDecision(guard)!="","interruptor bloquea nivel");
   guard.kill=false; guard.total_positions=1; guard.symbol_positions=1;
   Check1604(ExecGuardDecision(guard)!="","posición existente bloquea nivel");
   guard.total_positions=0; guard.symbol_positions=0; guard.net=-10;
   Check1604(ExecGuardDecision(guard)!="","pérdida diaria bloquea nivel");
   guard.net=0; guard.errors=3;
   Check1604(ExecGuardDecision(guard)!="","errores consecutivos bloquean nivel");
  }
#endif
#endif
