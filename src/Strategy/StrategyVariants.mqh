// r3-demo: execution guards and measurement only. B/C/D/control never call OrderSend.
input bool InpEarlyZoneEntry=false;
input double InpEarlyMaxAboveZoneWidths=0.5;
input int InpEarlyZoneCooldownMinutes=10;
input int InpConfirmedCooldownMinutes=10;
input bool InpEnableVariants=true;
input double InpVariantStopWidths=2.0;
input double InpVariantTargetWidths=4.0;
input bool InpEnableControlEntries=true;
input int InpControlWindowMinutes=120;
input bool InpPlanRejectionFollowup=true;

struct ExecGuardState
  {
   bool demo,usd,sl_valid,kill,stopped,cooldown;
   int symbol_positions,total_positions,errors,max_errors,trades,max_trades,losses,max_losses;
   double net,loss_limit;
   datetime now,pause_until;
  };

string ExecGuardDecision(const ExecGuardState &s)
  {
   if(!s.demo) return "CUENTA_NO_DEMO";
   if(!s.usd) return "MONEDA_NO_USD";
   if(!s.sl_valid) return "SL_OBLIGATORIO_INVALIDO";
   if(s.kill || s.stopped) return "INTERRUPTOR_PARADA";
   if(s.symbol_positions>=1) return "MAX_POSICIONES_SIMBOLO";
   if(s.total_positions>=2) return "MAX_POSICIONES_TOTALES";
   if(s.errors>=s.max_errors) return "MAX_ERRORES_ORDEN";
   if(!MathIsValidNumber(s.net) || s.net<=-s.loss_limit) return "MAX_PERDIDA_DIARIA";
   if(s.trades>=s.max_trades) return "MAX_OPERACIONES_DIARIAS";
   if(s.losses>=s.max_losses && s.now<s.pause_until) return "PAUSA_RACHA_PERDIDAS";
   if(s.cooldown) return "ENFRIAMIENTO_ZONA_CONFIRMADA";
   return "";
  }

ExecGuardState VariantsGuardDefaults()
  {
   ExecGuardState s={}; s.demo=true; s.usd=true; s.sl_valid=true;
   s.max_errors=3; s.max_trades=12; s.max_losses=4; s.loss_limit=10.0; return s;
  }

double VariantsDailyLimit() { return InpExecMaxDailyLossUSD; }
ulong VariantsMagic() { return InpExecMagic; }
bool VariantsOwnMagic(const ulong observed,const ulong expected)
  { return expected!=0 && observed==expected; }
bool VariantsStopsValid(const bool buy,const double bid,const double ask,const double sl,const double tp,const double minimum)
  {
   if(bid<=0.0 || ask<bid || sl<=0.0 || tp<0.0 || minimum<0.0) return false;
   if(buy) return sl<bid && bid-sl>=minimum && (tp==0.0 || (tp>ask && tp-bid>=minimum));
   return sl>ask && sl-ask>=minimum && (tp==0.0 || (tp<bid && ask-tp>=minimum));
  }

double VariantsOpenRisk(const string symbol_filter)
  {
   double sum=0.0;
   for(int i=0;i<PositionsTotal();i++)
     {
      if(PositionGetTicket(i)==0) return DBL_MAX;
      if(!VariantsOwnMagic((ulong)PositionGetInteger(POSITION_MAGIC),VariantsMagic())) continue;
      string symbol=PositionGetString(POSITION_SYMBOL);
       if(symbol!=symbol_filter) continue;
      double sl=PositionGetDouble(POSITION_SL),profit=0.0;
      ENUM_ORDER_TYPE side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(sl<=0.0 || !OrderCalcProfit(side,symbol,PositionGetDouble(POSITION_VOLUME),
                                     PositionGetDouble(POSITION_PRICE_OPEN),sl,profit)) return DBL_MAX;
      sum+=MathMax(0.0,-profit);
     }
   return sum;
  }

// Aggregate by position, so partial fills/exits are not separate losses.
struct VariantPosition { ulong id; bool bot; double net,volume; datetime closed; };
bool VariantsHistoryStats(int &trades,int &losses,datetime &last_loss)
  {
   trades=0; losses=0; last_loss=0;
   if(!HistorySelect(0,TimeCurrent())) return false;
   MqlDateTime day; TimeToStruct(TimeCurrent(),day); day.hour=0; day.min=0; day.sec=0;
   datetime start=StructToTime(day); VariantPosition positions[]; ulong orders[];
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      ulong d=HistoryDealGetTicket(i); if(d==0) return false;
      long type=HistoryDealGetInteger(d,DEAL_TYPE);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;
      ulong id=(ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID);
      bool own=(ulong)HistoryDealGetInteger(d,DEAL_MAGIC)==VariantsMagic();
      long entry=HistoryDealGetInteger(d,DEAL_ENTRY);
      datetime when=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
      if(own && entry==DEAL_ENTRY_IN && when>=start)
        {
         ulong order=(ulong)HistoryDealGetInteger(d,DEAL_ORDER); bool seen=false;
         for(int k=0;k<ArraySize(orders);k++) if(orders[k]==order) { seen=true; break; }
         if(!seen) { int n=ArraySize(orders); ArrayResize(orders,n+1); orders[n]=order; trades++; }
        }
      int slot=-1;
      for(int k=0;k<ArraySize(positions);k++) if(positions[k].id==id) { slot=k; break; }
      if(slot<0) { slot=ArraySize(positions); ArrayResize(positions,slot+1); ZeroMemory(positions[slot]); positions[slot].id=id; }
      if(own && entry==DEAL_ENTRY_IN) positions[slot].bot=true;
      positions[slot].net+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_COMMISSION)+
                           HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_FEE);
      positions[slot].volume+=(type==DEAL_TYPE_BUY ? 1.0 : -1.0)*HistoryDealGetDouble(d,DEAL_VOLUME);
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY) positions[slot].closed=when;
     }
   // Sort closed positions by exit time, independent of opening order.
   for(int a=0;a<ArraySize(positions);a++)
      for(int b=a+1;b<ArraySize(positions);b++)
         if(positions[b].closed>positions[a].closed)
           { VariantPosition temp=positions[a]; positions[a]=positions[b]; positions[b]=temp; }
   for(int i=0;i<ArraySize(positions);i++)
     {
      if(!positions[i].bot || positions[i].closed==0 || MathAbs(positions[i].volume)>1e-7) continue;
      if(positions[i].net>=0.0) break;
      if(last_loss==0) last_loss=positions[i].closed;
      losses++;
     }
   return true;
  }

string VariantsZoneKey(const Zone &zone)
  { return g_exec_account+"zone_"+(string)ExecHash(ZoneAlertKey("EXEC_CONFIRMED",zone)); }

bool VariantsExecGuard(const Zone &zone,const double sl,string &reason)
  {
   ExecGuardState s=VariantsGuardDefaults(); s.demo=AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO;
   s.usd=AccountInfoString(ACCOUNT_CURRENCY)=="USD"; s.sl_valid=sl>0.0;
   s.kill=InpExecKillSwitch; s.stopped=GlobalVariableGet(g_exec_account+"stop")>0.0;
   for(int i=0;i<PositionsTotal();i++)
     {
      if(PositionGetTicket(i)==0) { reason="POSICIONES_NO_DISPONIBLES"; return false; }
      if(!VariantsOwnMagic((ulong)PositionGetInteger(POSITION_MAGIC),VariantsMagic())) continue;
      s.total_positions++;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol) s.symbol_positions++;
     }
   s.max_errors=InpExecMaxOrderErrors; s.errors=(int)GlobalVariableGet(g_exec_account+"errors");
   s.max_trades=InpExecMaxTradesPerDay; s.max_losses=InpExecMaxConsecutiveLosses; s.loss_limit=VariantsDailyLimit();
   s.now=TimeCurrent(); datetime last=0; bool hit=false;
   if(!ExecDailyNet(s.net,hit) || !VariantsHistoryStats(s.trades,s.losses,last)) { reason="HISTORIAL_NO_DISPONIBLE"; return false; }
   if(hit) s.net=-s.loss_limit;
   s.pause_until=last+InpExecPauseMinutes*60;
   s.cooldown=ZoneAlertInCooldown(ZoneAlertKey("EXEC_CONFIRMED",zone),s.now,InpConfirmedCooldownMinutes*60) ||
              GlobalVariableGet(VariantsZoneKey(zone))+InpConfirmedCooldownMinutes*60>(double)s.now;
   reason=ExecGuardDecision(s);
   if(reason=="") for(int i=0;i<OrdersTotal();i++)
     {
      if(OrderGetTicket(i)==0) { reason="ORDENES_NO_DISPONIBLES"; break; }
      if(VariantsOwnMagic((ulong)OrderGetInteger(ORDER_MAGIC),VariantsMagic()))
        { reason="ORDEN_PENDIENTE_EXISTENTE"; break; }
     }
   return reason=="";
  }

bool VariantsArmZone(const Zone &zone)
  {
   if(GlobalVariableSet(VariantsZoneKey(zone),(double)TimeCurrent())==0) return false;
   RememberZoneAlert(ZoneAlertKey("EXEC_CONFIRMED",zone),TimeCurrent()); GlobalVariablesFlush(); return true;
  }

bool VariantsCapVolume(const string side,const double price,const double stop,double &volume,double &risk,string &reason)
  {
   double minimum=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0.0 || minimum<=0.0 || InpExecMaxLots<minimum) { reason="MAX_LOTE_INFERIOR_AL_MINIMO"; return false; }
   volume=NormalizeDouble(minimum+MathFloor((MathMin(volume,InpExecMaxLots)-minimum)/step+1e-8)*step,8);
   double p=0.0;
   if(volume<minimum || !OrderCalcProfit(side=="BUY" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,volume,price,stop,p) || p>=0.0)
     { reason="LOTE_O_RIESGO_INVALIDO"; return false; }
   risk=-p;
   if(risk<InpPlanRiskMinUSD-1e-8 || risk>InpPlanRiskMaxUSD+1e-8) { reason="RIESGO_TRAS_TOPE_LOTE"; return false; }
   return true;
  }

struct VariantExecLink { string id,comment; double price,spread; };
VariantExecLink g_variant_links[];
string VariantsExecFile() { return TaggedCsv("BCSO_"+SafeSymbolName()+"_exec_v1604.csv"); }
int VariantsLink(const string id)
  {
   for(int i=0;i<ArraySize(g_variant_links);i++) if(g_variant_links[i].id==id || g_variant_links[i].comment==id) return i;
   int n=ArraySize(g_variant_links); ArrayResize(g_variant_links,n+1);
   g_variant_links[n].id=id; g_variant_links[n].comment="BCSO|"+(string)ExecHash(id);
   g_variant_links[n].price=0.0; g_variant_links[n].spread=0.0; return n;
  }
bool VariantsExecLog(const string id,const string state,const string detail,const MqlTradeRequest &req,
                     const uint code,const ulong order,const ulong deal)
  {
   bool fill=StringFind(state,"DEAL_")==0; int link=VariantsLink(id);
   if(!fill && req.price>0.0)
     {
      g_variant_links[link].price=req.price; MqlTick q;
      if(SymbolInfoTick(_Symbol,q) && _Point>0.0) g_variant_links[link].spread=(q.ask-q.bid)/_Point;
     }
   bool error=state=="RECHAZADA_BROKER" || state=="ESTADO_INCIERTO_BLOQUEADO" || StringFind(detail,"ORDERCHECK:")==0;
   if(error)
     {
      double n=GlobalVariableGet(g_exec_account+"errors")+1;
      GlobalVariableSet(g_exec_account+"errors",n);
      if(n>=InpExecMaxOrderErrors) GlobalVariableSet(g_exec_account+"stop",1.0);
      GlobalVariablesFlush();
     }
   else if(state=="ACEPTADA_ESPERANDO_DEAL" || state=="DEAL_ENTRADA_CONFIRMADO") GlobalVariableSet(g_exec_account+"errors",0.0);
   string row[]; ArrayResize(row,17);
   row[0]=g_variant_links[link].id; row[1]=TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS);
   row[2]=req.type==ORDER_TYPE_BUY ? "BUY" : "SELL"; row[3]=DoubleToString(req.volume,8);
   row[4]=DoubleToString(g_variant_links[link].price,_Digits); row[5]=DoubleToString(req.sl,_Digits); row[6]=DoubleToString(req.tp,_Digits);
   row[7]=(string)code; row[8]=(string)order; row[9]=(string)deal;
   row[10]=deal>0 ? (string)HistoryDealGetInteger(deal,DEAL_POSITION_ID) : "";
   row[11]=fill ? DoubleToString(req.price,_Digits) : "";
   row[12]=fill && state=="DEAL_ENTRADA_CONFIRMADO" && g_variant_links[link].price>0.0 && _Point>0.0 ?
           DoubleToString((req.price-g_variant_links[link].price)*(req.type==ORDER_TYPE_BUY ? 1.0 : -1.0)/_Point,5) : "";
   row[13]=DoubleToString(g_variant_links[link].spread,5); row[14]=state+"|"+detail;
   row[15]=OBSERVER_BUILD_TAG; row[16]=g_writer_session;
   return AppendDiagnostic(VariantsExecFile(),"event_id;time_server;side;volume;req_price;sl;tp;retcode;order_ticket;deal_ticket;position_id;fill_price;slippage_points;spread_points;block_reason;writer_build;writer_session",row);
  }
bool VariantsPendingMatches(const string comment,const double pending)
  {
   int prefix=StringFind(comment,"BCSO|")==0 ? 5 : (StringFind(comment,"B1604_")==0 ? 6 : 0);
   return prefix>0 && (double)StringToInteger(StringSubstr(comment,prefix))+1.0==pending;
  }

void VariantLevels(const bool buy,const double entry,const double edge,const double width,const double buffer,
                   const double stop_widths,const double target_widths,double &wide_stop,double &long_target)
  {
   wide_stop=edge+(buy ? -1.0 : 1.0)*MathMax(buffer,stop_widths*width);
   long_target=entry+(buy ? 1.0 : -1.0)*target_widths*width;
  }
long VariantControlDelay(const uint seed,const int minutes)
  { return minutes>0 ? 1+(long)(seed%(uint)(minutes*60)) : 0; }

string g_variant_parent="",g_variant_override="";
string VariantsRecordID(const string id,const string module)
  {
   if(g_variant_override!="") return g_variant_override;
   if(module=="M5_REACTION_N" || module=="M5_REACTION_REJECTION") g_variant_parent=id;
   return id;
  }
void VariantsDiscard(const string id,const string module,const string reason)
  {
   string row[]; ArrayResize(row,5); row[0]=id; row[1]=TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS);
   row[2]=module; row[3]=reason; row[4]=OBSERVER_BUILD_TAG;
   AppendDiagnostic(TaggedCsv("BCSO_"+SafeSymbolName()+"_variant_discards_v1604.csv"),"event_id;time_server;module;reason;writer_build",row);
  }

bool VariantsObserve(const string id,const string module,const string side,const Zone &zone,const Trend m5,const Trend m15,
                     const MqlTick &quote,const double stop,const double target,const double volume,const datetime bar,
                     const string detail,const bool control=false,const long seed=0)
  {
   if(FreePendingSlot()<0) { VariantsDiscard(id,module,"CAPACIDAD_PENDIENTES"); return false; }
   double entry=side=="BUY" ? quote.ask : quote.bid,profit=0.0;
   if(volume<=0.0 || stop<=0.0 || target<=0.0 ||
      (side=="BUY" ? stop>=entry || target<=entry : stop<=entry || target>=entry) ||
      !OrderCalcProfit(side=="BUY" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,volume,entry,stop,profit))
     { VariantsDiscard(id,module,"PRECIO_O_RIESGO_NO_CALCULABLE"); return false; }
   double oldvol=g_record_volume,oldrisk=g_record_risk_usd,oldstop=g_record_legacy_stop;
   bool oldbudget=g_record_risk_exceeds,oldcontrol=g_record_control,oldleg=g_record_leg_spike,oldalert=g_record_zone_alert;
   long oldseed=g_record_seed;
   g_record_volume=volume; g_record_risk_usd=MathMax(0.0,-profit); g_record_risk_exceeds=g_record_risk_usd>InpPlanRiskMaxUSD;
   g_record_control=control; g_record_seed=seed; g_record_zone_alert=false; g_record_leg_spike=StringFind(module,"REACTION_N")>=0;
   g_record_legacy_stop=stop; g_variant_override=id;
   bool ok=RecordObservation(module,side,zone,m5,m15,TREND_NONE,detail,quote,stop,target,bar,false);
   string gate=g_last_gate;
   g_variant_override=""; g_record_volume=oldvol; g_record_risk_usd=oldrisk; g_record_legacy_stop=oldstop;
   g_record_risk_exceeds=oldbudget; g_record_control=oldcontrol; g_record_seed=oldseed; g_record_leg_spike=oldleg; g_record_zone_alert=oldalert;
   if(!ok && gate!="DUPLICATE") VariantsDiscard(id,module,gate);
   return ok || gate=="DUPLICATE";
  }

struct VariantControl
  {
   bool active; string event_id,id,side,module; Zone zone;
   long created,due,seed; double stop_distance,target_distance,volume;
  };
VariantControl g_variant_controls[];
string VariantsControlFile() { return TaggedCsv("BCSO_"+SafeSymbolName()+"_control_schedule_v1604.csv"); }
bool VariantsControlWrite(const VariantControl &c,const string state)
  {
   string r[]; ArrayResize(r,17);
   r[0]=c.event_id; r[1]=c.id; r[2]=c.side; r[3]=(string)c.created; r[4]=(string)c.due; r[5]=(string)c.seed;
   r[6]=DoubleToString(c.stop_distance,_Digits); r[7]=DoubleToString(c.target_distance,_Digits); r[8]=DoubleToString(c.volume,8);
   r[9]=DoubleToString(c.zone.lower,_Digits); r[10]=DoubleToString(c.zone.upper,_Digits); r[11]=(string)c.zone.touches;
   r[12]=c.module; r[13]=state; r[14]=TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS); r[15]=OBSERVER_BUILD_TAG; r[16]=g_writer_session;
   return AppendDiagnostic(VariantsControlFile(),"event_id;control_id;side;created_msc;due_msc;seed;stop_distance;target_distance;volume;zone_lower;zone_upper;touches;parent_module;state;time_server;writer_build;writer_session",r);
  }
void VariantsSchedule(const string event_id,const string parent,const string module,const string side,const Zone &zone,
                      const MqlTick &q,const double stop,const double target,const double volume)
  {
   for(int i=0;i<ArraySize(g_variant_controls);i++) if(g_variant_controls[i].id==parent+"_CONTROL") return;
   VariantControl c={}; c.active=true; c.event_id=event_id; c.id=parent+"_CONTROL"; c.module=module; c.side=side; c.zone=zone;
   c.created=q.time_msc; c.seed=(long)ExecHash(event_id+"|control1604");
   c.due=c.created+VariantControlDelay((uint)c.seed,InpControlWindowMinutes)*1000;
   double entry=side=="BUY" ? q.ask : q.bid;
   c.stop_distance=MathAbs(entry-stop); c.target_distance=MathAbs(target-entry); c.volume=volume;
   int active=0; for(int i=0;i<ArraySize(g_variant_controls);i++) if(g_variant_controls[i].active) active++;
   if(active>=300) { VariantsDiscard(c.id,"CONTROL_M5_REACTION","CAPACIDAD_CONTROLES"); return; }
   if(!VariantsControlWrite(c,"SCHEDULED")) { VariantsDiscard(c.id,"CONTROL_M5_REACTION","PERSISTENCIA"); return; }
   int n=ArraySize(g_variant_controls); ArrayResize(g_variant_controls,n+1); g_variant_controls[n]=c;
  }

void VariantsConfirmed(const string event_id,const string module,const string side,const Zone &zone,const Trend m5,const Trend m15,
                       const MqlTick &q,const MqlRates &bar,const double stop,const double target,const double volume)
  {
   string parent=g_variant_parent;
   if(parent=="") { VariantsDiscard(event_id,module,"SIN_ID_PADRE"); return; }
   if(InpEnableVariants)
     {
      double wide=0.0,longtp=0.0,entry=side=="BUY" ? q.ask : q.bid;
      double edge=side=="BUY" ? MathMin(bar.low,zone.lower) : MathMax(bar.high,zone.upper);
      VariantLevels(side=="BUY",entry,edge,zone.upper-zone.lower,StopBuffer(),InpVariantStopWidths,InpVariantTargetWidths,wide,longtp);
      string detail="shadow_only|base_event_id="+event_id+"|base_signal_id="+parent;
      VariantsObserve(parent+"_B",module+"_B",side,zone,m5,m15,q,wide,target,volume,bar.time,detail);
      VariantsObserve(parent+"_C",module+"_C",side,zone,m5,m15,q,stop,longtp,volume,bar.time,detail);
      VariantsObserve(parent+"_D",module+"_D",side,zone,m5,m15,q,wide,longtp,volume,bar.time,detail);
     }
   if(InpEnableControlEntries) VariantsSchedule(event_id,parent,module,side,zone,q,stop,target,volume);
  }

void VariantsPoll()
  {
   if(!InpEnableControlEntries) return;
   MqlTick q; if(!SymbolInfoTick(_Symbol,q) || q.time_msc<=0) return;
   for(int i=0;i<ArraySize(g_variant_controls);i++)
     {
      if(!g_variant_controls[i].active || q.time_msc<g_variant_controls[i].due) continue;
      VariantControl c=g_variant_controls[i]; string state="DATA_GAP";
      if(q.time_msc-c.due<=5000 && q.bid>0.0 && q.ask>=q.bid)
        {
         double entry=c.side=="BUY" ? q.ask : q.bid,sign=c.side=="BUY" ? 1.0 : -1.0;
         bool ok=VariantsObserve(c.id,"CONTROL_M5_REACTION",c.side,c.zone,TREND_NONE,TREND_NONE,q,
                       entry-sign*c.stop_distance,entry+sign*c.target_distance,c.volume,(datetime)(q.time_msc/1000),
                       "control_only|base_event_id="+c.event_id+"|due_msc="+(string)c.due,true,c.seed);
         state=ok ? "ENTERED" : "DISCARDED";
        }
      if(!VariantsControlWrite(c,state)) VariantsDiscard(c.id,"CONTROL_M5_REACTION","ESTADO_NO_PERSISTIDO_"+state);
      g_variant_controls[i].active=false;
     }
  }

void VariantsPlanFollow(const string id,const string stage,const string side,const Zone &zone)
  {
   if(!InpPlanRejectionFollowup || !(stage=="VIGILANCIA" || stage=="DESCARTADO_RIESGO" || stage=="DESCARTADO_OBJETIVO" ||
                                   StringFind(stage,"ANTICIPADA_DESCARTADA_")==0)) return;
   OperationsRejectionWritten(id,"M5_PLAN_"+stage,side,stage,zone);
  }

bool VariantsInitialize()
  {
   if(InpEarlyMaxAboveZoneWidths<0.0 || InpEarlyZoneCooldownMinutes<1 || InpExecMaxLots<=0.0 || InpConfirmedCooldownMinutes<1 || InpExecMaxOrderErrors<1 ||
      InpExecMaxDailyLossUSD<=0.0 || InpExecMaxDailyLossUSD>10.0 || InpExecMaxTradesPerDay<1 ||
      InpExecMaxConsecutiveLosses<1 || InpExecPauseMinutes<1 || VariantsMagic()==0 ||
      InpVariantStopWidths<=0.0 || InpVariantTargetWidths<=0.0 || InpControlWindowMinutes<1 || InpControlWindowMinutes>1440)
     { Print("r3-demo: parámetros de control inválidos"); return false; }
   string stop_key=g_exec_account+"stop";
   if(!GlobalVariableCheck(stop_key) && !GlobalVariableTemp(stop_key)) return false;
   string row[];
   if(FileIsExist(VariantsExecFile(),FILE_COMMON))
     {
      int h=OpenCsvRetry(VariantsExecFile(),FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON,';',CP_UTF8);
      if(h==INVALID_HANDLE) return false;
      while(ReadCsvRow(h,row))
        {
         if(ArraySize(row)!=17 || row[0]=="event_id") continue;
         int k=VariantsLink(row[0]);
         g_variant_links[k].price=StringToDouble(row[4]); g_variant_links[k].spread=StringToDouble(row[13]);
        }
      FileClose(h);
     }
   if(FileIsExist(VariantsControlFile(),FILE_COMMON))
     {
      int h=OpenCsvRetry(VariantsControlFile(),FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON,';',CP_UTF8);
      if(h==INVALID_HANDLE) return false;
      while(ReadCsvRow(h,row))
        {
         if(ArraySize(row)!=17 || row[0]=="event_id") continue;
         int k=-1; for(int i=0;i<ArraySize(g_variant_controls);i++) if(g_variant_controls[i].id==row[1]) { k=i; break; }
         if(k<0) { k=ArraySize(g_variant_controls); ArrayResize(g_variant_controls,k+1); }
         VariantControl c={}; c.event_id=row[0]; c.id=row[1]; c.side=row[2]; c.created=StringToInteger(row[3]);
         c.due=StringToInteger(row[4]); c.seed=StringToInteger(row[5]); c.stop_distance=StringToDouble(row[6]);
         c.target_distance=StringToDouble(row[7]); c.volume=StringToDouble(row[8]);
         double lower=StringToDouble(row[9]),upper=StringToDouble(row[10]);
         c.zone=MakeZone(PERIOD_M5,c.side=="BUY" ? ZONE_SUPPORT : ZONE_RESISTANCE,(lower+upper)/2,(upper-lower)/2,(int)StringToInteger(row[11]));
         c.module=row[12]; c.active=row[13]=="SCHEDULED"; g_variant_controls[k]=c;
        }
      FileClose(h);
     }
   return true;
  }

// Complement supplied by the user. Defaults remain off; same execution guard as A.
Zone g_early_zones[];
datetime g_early_cache_bar=0;
void EarlyRefreshZones(const ZoneKind kind,const datetime bar0)
  {
   g_early_cache_bar=bar0; ArrayResize(g_early_zones,0);
   double centers[],tolerance=0.0; int reactions[];
   int count=CollectQualifiedZones(PERIOD_M5,kind,InpScanBarsM5,centers,reactions,tolerance,true);
   MqlRates m5[]; if(count<=0 || !LoadRates(PERIOD_M5,InpScanBarsM5,m5)) return;
   for(int i=0;i<count;i++)
     {
      Zone z=MakeZone(PERIOD_M5,kind,centers[i],tolerance,reactions[i]);
      z.touches=StrategyPriorReactions(z,bar0,m5); if(z.touches<2) continue;
      int n=ArraySize(g_early_zones); ArrayResize(g_early_zones,n+1); g_early_zones[n]=z;
     }
  }
void EvaluateEarlyZoneEntry()
  {
   if(!InpEarlyZoneEntry || !InpUseM5ReactionStrategy) return;
   string side=""; ZoneKind kind=ZONE_SUPPORT;
   if(IsBoomSymbol()) { side="BUY"; kind=ZONE_SUPPORT; }
   else if(IsCrashSymbol()) { side="SELL"; kind=ZONE_RESISTANCE; } else return;
   datetime bar0=iTime(_Symbol,PERIOD_M1,0),signal_bar=iTime(_Symbol,PERIOD_M1,1);
   if(bar0<=0 || signal_bar<=0) return;
   if(bar0!=g_early_cache_bar) EarlyRefreshZones(kind,bar0);
   MqlTick q;
   if(ArraySize(g_early_zones)==0 || !SymbolInfoTick(_Symbol,q) || q.ask<=q.bid || q.bid<=0.0 ||
      !ExecFresh((long)TimeCurrent()*1000+999,q.time_msc,signal_bar)) return;
   double entry=side=="BUY" ? q.ask : q.bid,prev=iClose(_Symbol,PERIOD_M1,1),nearest=DBL_MAX; int selected=-1;
   for(int i=0;i<ArraySize(g_early_zones);i++)
     {
      Zone z=g_early_zones[i]; double reach=MathMax(_Point,z.upper-z.lower)*InpEarlyMaxAboveZoneWidths;
      bool near=side=="BUY" ? entry>=z.lower && entry<=z.upper+reach && prev>=z.lower :
                             entry<=z.upper && entry>=z.lower-reach && prev<=z.upper;
      if(near && MathAbs(entry-z.center)<nearest) { selected=i; nearest=MathAbs(entry-z.center); }
     }
   if(selected<0) return;
   Zone zone=g_early_zones[selected];
   double stop=side=="BUY" ? zone.lower-StopBuffer() : zone.upper+StopBuffer(),target=StrategyM5Target(side,entry);
   double width=MathMax(_Point,zone.upper-zone.lower),spread=MathMax(0.0,q.ask-q.bid);
   target=TpSelectedTarget(side,entry,width,spread,stop,target);
   double volume=0.0,risk=0.0; string reason="";
   bool sized=StrategyRiskVolume(side,entry,stop,volume,risk,reason);
   double gain=target>0.0 ? (side=="BUY" ? target-entry : entry-target) : 0.0;
   double rr=MathAbs(entry-stop)>_Point ? gain/(MathAbs(entry-stop)+spread) : 0.0;
   bool tp_rr_fail=InpTpMode==SPIKE_QUANTILE && rr<InpTpMinRR;
   string id=_Symbol+"_1605_EARLY_"+side+"_"+(string)(long)signal_bar+"_"+DoubleToString(zone.center,_Digits);
   if(!sized || target<=0.0 || (InpTpMode==NEAREST_ZONE && rr<InpMinimumRewardRisk))
     {
      string key=ZoneAlertKey("EARLY_DISC",zone);
      if(ZoneAlertInCooldown(key,TimeCurrent(),60)) return;
      RememberZoneAlert(key,TimeCurrent());
      StrategyAppendPlan(id,signal_bar,!sized ? "ANTICIPADA_DESCARTADA_RIESGO" : "ANTICIPADA_DESCARTADA_OBJETIVO",side,zone,
                         DetectTrend(PERIOD_M15,InpScanBarsM15),entry,stop,target,volume,risk,!sized ? reason : "SIN_OBJETIVO_M5_O_RR_BAJO");
      return;
     }
   string key=ZoneAlertKey("EARLY_ENTRY",zone);
   if(ZoneAlertInCooldown(key,TimeCurrent(),InpEarlyZoneCooldownMinutes*60)) return;
   Trend m15=DetectTrend(PERIOD_M15,InpScanBarsM15),m5=DetectTrend(PERIOD_M5,InpScanBarsM5);
   string detail="ANTICIPADA en zona M5 | "+(string)zone.touches+" reacciones | M15 "+StrategyTrendText(m15);
   g_record_zone_alert=false; g_record_volume=volume; g_record_risk_usd=risk;
   g_record_risk_exceeds=false; g_record_leg_spike=false; g_record_legacy_stop=stop;
   bool saved=RecordObservation("M5_EARLY_ZONE",side,zone,m5,m15,TREND_NONE,detail,q,stop,target,signal_bar,false);
   g_record_volume=0.0; g_record_risk_usd=0.0;
   if(!saved) return;
   RecordTakeProfitPlan(id,"M5_EARLY_ZONE",side,zone,m5,m15,q,stop,StrategyM5Target(side,entry),volume,signal_bar);
   RememberZoneAlert(key,TimeCurrent());
   StrategyAppendPlan(id,signal_bar,"ANTICIPADA_CONFIRMADA",side,zone,m15,entry,stop,target,volume,risk,"");
   if(!tp_rr_fail) DemoExecuteConfirmed(id,side,zone,signal_bar,stop,target);
   Print("PLAN_1605_ANTICIPADA: ",side," | ",detail);
   if(InpEnableDesktopAlerts && ActivePack())
     {
      Alert(InpDemoExecution ? "ENTRADA ANTICIPADA EN ZONA M5 — VER DIARIO DEMO_EXEC\n" : "ENTRADA ANTICIPADA OBSERVADA — NO ABRE OPERACIONES\n",
            _Symbol," ",side," | M5 ",zone.touches," reacciones | Entrada ",DoubleToString(entry,_Digits),
            " | SL ",DoubleToString(stop,_Digits)," | TP ",DoubleToString(target,_Digits),
            " | volumen ",DoubleToString(volume,8)," | riesgo USD ",DoubleToString(risk,2));
      if(InpPlayAlertSound) PlaySound(InpAlertSoundFile);
     }
  }

#ifdef BCSO_VARIANTS_TEST
void VariantsSelfTest()
  {
   Check1604(!InpDemoExecution && !InpEarlyZoneEntry,"r3 ejecución y anticipada apagadas");
   Check1604(OBSERVER_BUILD_TAG=="1.604-r3-demo-levels-manexec-ownpos-risk2-tp-retrace25" && OBSERVER_RULE_VERSION=="1.604","r3 versiones compatibles");
   Check1604(VariantsOwnMagic(160402,160402) && !VariantsOwnMagic(0,160402) &&
             !VariantsOwnMagic(160403,160402),"solo posiciones y órdenes del EA cuentan");
   Check1604(MathAbs(StrategyVolumeGrid(6.0,0.2,0.01,1.0,1.0,1.5)-0.25)<1e-8,"r3 lote mínimo 0.2 cabe");
   Check1604(StrategyVolumeGrid(8.0,0.2,0.01,1.0,1.0,1.5)==0.0,"r3 lote mínimo no cabe");
   Check1604(MathAbs(StrategyVolumeGrid(6.0,0.2,0.01,0.2,1.0,1.5)-0.2)<1e-8,"r3 tope máximo lote");
   ExecGuardState s=VariantsGuardDefaults();
   Check1604(ExecGuardDecision(s)=="","r3 guardia caso válido");
   s.demo=false; Check1604(ExecGuardDecision(s)=="CUENTA_NO_DEMO","r3 cuenta no demo"); s=VariantsGuardDefaults();
   s.usd=false; Check1604(ExecGuardDecision(s)=="MONEDA_NO_USD","r3 cuenta no USD"); s=VariantsGuardDefaults();
   s.sl_valid=false; Check1604(ExecGuardDecision(s)=="SL_OBLIGATORIO_INVALIDO","r3 sin SL"); s=VariantsGuardDefaults();
   s.symbol_positions=1; Check1604(ExecGuardDecision(s)=="MAX_POSICIONES_SIMBOLO","r3 una posición por símbolo"); s=VariantsGuardDefaults();
   s.total_positions=2; Check1604(ExecGuardDecision(s)=="MAX_POSICIONES_TOTALES","r3 dos posiciones totales"); s=VariantsGuardDefaults();
   s.total_positions=1; Check1604(ExecGuardDecision(s)=="","r3 otra posición permite evaluar"); s=VariantsGuardDefaults();
   s.errors=3; Check1604(ExecGuardDecision(s)=="MAX_ERRORES_ORDEN","r3 tres errores bloquean"); s=VariantsGuardDefaults();
   s.net=-10.0; Check1604(ExecGuardDecision(s)=="MAX_PERDIDA_DIARIA","r3 límite diario"); s=VariantsGuardDefaults();
   s.kill=true; Check1604(ExecGuardDecision(s)=="INTERRUPTOR_PARADA","r3 kill switch"); s=VariantsGuardDefaults();
   s.stopped=true; Check1604(ExecGuardDecision(s)=="INTERRUPTOR_PARADA","r3 parada global"); s=VariantsGuardDefaults();
   s.cooldown=true; Check1604(ExecGuardDecision(s)=="ENFRIAMIENTO_ZONA_CONFIRMADA","r3 enfriamiento confirmado"); s=VariantsGuardDefaults();
   s.trades=12; Check1604(ExecGuardDecision(s)=="MAX_OPERACIONES_DIARIAS","r3 doce operaciones"); s=VariantsGuardDefaults();
   s.losses=4; s.now=100; s.pause_until=200;
   Check1604(ExecGuardDecision(s)=="PAUSA_RACHA_PERDIDAS","r3 pausa pérdidas");
   s.now=200; Check1604(ExecGuardDecision(s)=="","r3 pausa termina al vencimiento");
   double stop=0.0,target=0.0;
   VariantLevels(true,100,98,2,0.5,2,4,stop,target);
   Check1604(stop==94 && target==108,"r3 B/C/D compra stop94 objetivo108");
   VariantLevels(false,100,102,2,0.5,2,4,stop,target);
   Check1604(stop==106 && target==92,"r3 B/C/D venta stop106 objetivo92");
   VariantLevels(true,100,98,2,5,2,4,stop,target);
   Check1604(stop==93,"r3 buffer mayor que ancho prevalece");
   uint seed=ExecHash("fixture|control1604");
   Check1604(seed==3410733624 && VariantControlDelay(seed,120)==25,"r3 semilla conocida reproduce 25 segundos");
   Check1604(VariantControlDelay(seed,120)>=1 && VariantControlDelay(seed,120)<=7200,"r3 instante dentro ventana");
   Check1604(VariantsStopsValid(true,100,101,99,0,0.5),"r3 TP opcional compra");
   Check1604(VariantsStopsValid(false,100,101,102,0,0.5),"r3 TP opcional venta");
   Check1604(!VariantsStopsValid(true,100,101,0,0,0),"r3 SL obligatorio aun sin TP");
   Check1604(VariantsPendingMatches("BCSO|123",124),"r3 correlación comentario nuevo");
   Check1604(VariantsPendingMatches("B1604_123",124),"r3 correlación comentario anterior");
  }
#endif
