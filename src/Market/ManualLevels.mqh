#ifndef BCSO_MANUAL_LEVELS
#define BCSO_MANUAL_LEVELS
input bool InpUseManualLevels=true;
input int InpManualLevelDelaySeconds=60;
struct ManualLevelState
  {
   long chart;
   string name;
   int type;
   double p1,p2;
   datetime created,first_seen,changed,active_from,last_written;
   bool seen,present,dirty;
  };
ManualLevelState g_manual_objects[];
bool ManualNameAllowed(const string name) { return StringFind(name,"BCSO_")!=0; }
datetime ManualActiveFrom(const datetime created,const datetime changed,const int delay)
  { return (datetime)MathMax((long)created,(long)changed)+delay; }
bool ManualEligible(const datetime active_from,const datetime touch)
  { return active_from>0 && active_from<=touch; }
bool WriteManualSnapshot(ManualLevelState &state,const Zone &zone,const datetime now)
  {
   string row[]; ArrayResize(row,10);
   row[0]=TimeToString(now,TIME_DATE|TIME_SECONDS); row[1]=state.name;
   row[2]=EnumToString((ENUM_OBJECT)state.type);
   row[3]=DoubleToString(zone.lower,_Digits); row[4]=DoubleToString(zone.upper,_Digits);
   row[5]=TimeToString(state.created,TIME_DATE|TIME_SECONDS);
   row[6]=TimeToString(state.first_seen,TIME_DATE|TIME_SECONDS);
   row[7]=TimeToString(state.changed,TIME_DATE|TIME_SECONDS);
   row[8]=TimeToString(state.active_from,TIME_DATE|TIME_SECONDS); row[9]=g_writer_session;
   return AppendDiagnostic(TaggedCsv("BCSO_"+SafeSymbolName()+"_manual_levels_v1604.csv"),
      "time_server;name;type;price_low;price_high;create_time;first_seen;last_changed;active_from;writer_session",row);
  }
void RefreshManualLevels(const MqlTick &q,const double half)
  {
   ArrayResize(g_manual_levels,0);
   if(!InpUseManualLevels) return;
   for(int i=0;i<ArraySize(g_manual_objects);i++) g_manual_objects[i].seen=false;
   // The attached M1 chart and open same-symbol M5 charts are explicit sources.
   for(long chart=ChartFirst();chart>=0;chart=ChartNext(chart))
     {
      if(ChartSymbol(chart)!=_Symbol || (chart!=ChartID() && ChartPeriod(chart)!=PERIOD_M5)) continue;
      int n=ObjectsTotal(chart,0,-1);
      for(int i=0;i<n;i++)
        {
         string name=ObjectName(chart,i,0,-1);
         if(!ManualNameAllowed(name)) continue;
         int type=(int)ObjectGetInteger(chart,name,OBJPROP_TYPE);
         if(type!=OBJ_HLINE && type!=OBJ_TREND && type!=OBJ_RECTANGLE) continue;
         double p1=ObjectGetDouble(chart,name,OBJPROP_PRICE,0);
         double p2=type==OBJ_HLINE ? p1 : ObjectGetDouble(chart,name,OBJPROP_PRICE,1);
         if(p1<=0.0 || p2<=0.0 || (type==OBJ_TREND && p1!=p2)) continue;
         datetime created=(datetime)ObjectGetInteger(chart,name,OBJPROP_CREATETIME);
         int index=-1;
         for(int j=0;j<ArraySize(g_manual_objects);j++)
            if(g_manual_objects[j].chart==chart && g_manual_objects[j].name==name) { index=j; break; }
         if(index<0)
           {
            index=ArraySize(g_manual_objects);
            if(ArrayResize(g_manual_objects,index+1)!=index+1) continue;
            ManualLevelState fresh={}; fresh.chart=chart; fresh.name=name; fresh.first_seen=q.time;
            g_manual_objects[index]=fresh;
           }
         ManualLevelState state=g_manual_objects[index];
         bool changed=!state.present || state.p1!=p1 || state.p2!=p2 || state.type!=type || state.created!=created;
         if(changed)
           {
            state.changed=q.time; state.created=created; state.p1=p1; state.p2=p2; state.type=type;
            // First observation after restart is deliberately conservative.
            state.active_from=ManualActiveFrom(created,state.changed,InpManualLevelDelaySeconds);
            state.dirty=true;
           }
         state.seen=true; state.present=true;
         double low=type==OBJ_RECTANGLE ? MathMin(p1,p2) : p1-half;
         double high=type==OBJ_RECTANGLE ? MathMax(p1,p2) : p1+half;
         if(high<=low) { g_manual_objects[index]=state; continue; }
         AdditionalLevel level; level.source="MANUAL"; level.manual=true; level.priority=0;
         level.zone=MakeZone(PERIOD_M5,LevelRole((low+high)/2.0,q.bid),(low+high)/2.0,(high-low)/2.0,0);
         level.known_at=state.active_from; level.formed_at=state.first_seen;
         level.age_bars=(int)MathMax(0,(q.time-state.active_from)/300); level.touches_after=0; level.flipped=false;
         level.key="MANUAL_"+(string)chart+"_"+name+"_"+(string)(long)state.changed;
         if(state.dirty || q.time-state.last_written>=3600)
            if(WriteManualSnapshot(state,level.zone,q.time)) { state.last_written=q.time; state.dirty=false; }
         g_manual_objects[index]=state;
         if(ManualEligible(state.active_from,q.time)) LevelPush(g_manual_levels,level);
        }
     }
   for(int i=0;i<ArraySize(g_manual_objects);i++)
      if(!g_manual_objects[i].seen) g_manual_objects[i].present=false;
  }
#endif
