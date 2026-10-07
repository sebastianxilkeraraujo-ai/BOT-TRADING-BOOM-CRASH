#ifndef BCSO_OPERATIONS_MONITOR
#define BCSO_OPERATIONS_MONITOR

input int InpTouchLoadRetrySeconds=180;
input int InpTouchSyncGraceSeconds=120;
input bool InpExportTrades=true;
input int InpTradesBackfillDays=7;
input bool InpEnableDisciplineMonitor=false;
input int InpMaxOpenPositions=2;
input int InpMaxTradesPerDay=8;
input int InpMaxConsecutiveLosses=3;
input int InpDisciplineCooldownMin=30;

input bool InpExportTrades2=true;
input int InpTrades2BackfillDays=14; // original exporter retains its existing 7-day default
input double InpMaxRiskPerTradeUSD=2.00;
input double InpMaxDailyLossUSD=0.0;
input bool InpContextSnapshots=true;
input bool InpRejectionFollowup=true;
input int InpRejectionFollowMinutes=15;
input bool InpEnableCrashTrendEvaluable=false;

enum TouchStallAction { WAIT, GAP_LOAD, GAP_SYNC };
long g_touch_load_fail_since=0;

// Pure: all timing and configuration is supplied by the caller.
TouchStallAction TouchStallDecision(const bool loaded,const bool replay_ok,
   const long now_msc,const long deadline_msc,const long fail_since_msc,
   const int retry_seconds=180,const int grace_seconds=120)
  {
   if(!loaded && ((fail_since_msc>0 && now_msc-fail_since_msc>(long)MathMax(0,retry_seconds)*1000) ||
                  now_msc>deadline_msc+(long)MathMax(0,retry_seconds)*1000)) return GAP_LOAD;
   if(!replay_ok && now_msc>deadline_msc+(long)MathMax(0,grace_seconds)*1000) return GAP_SYNC;
   return WAIT;
  }

void OperationsTouchLoadState(const bool loaded,const long now_msc)
  {
   if(loaded) g_touch_load_fail_since=0;
   else if(g_touch_load_fail_since==0) g_touch_load_fail_since=now_msc;
  }

bool OperationsTouchStall(TouchSpikeEpisode &episode,const bool loaded,
                         const bool replay_ok,const MqlTick &quote,const MqlTick &recovered[])
  {
   if(loaded && replay_ok) return false;
   TouchStallAction action=TouchStallDecision(loaded,replay_ok,quote.time_msc,
      episode.deadline_msc,g_touch_load_fail_since,InpTouchLoadRetrySeconds,InpTouchSyncGraceSeconds);
   if(!loaded)
     {
      for(int k=0;k<ArraySize(recovered);k++)
         if(recovered[k].time_msc>episode.last_tick_msc && recovered[k].time_msc<=episode.deadline_msc &&
            recovered[k].bid>0.0 && recovered[k].ask>=recovered[k].bid)
           {
            double move=episode.zone.kind==ZONE_SUPPORT ? recovered[k].bid-episode.bid : episode.bid-recovered[k].bid;
            episode.mfe=MathMax(episode.mfe,move); episode.mae=MathMax(episode.mae,-move);
           }
      if(quote.time_msc<=episode.deadline_msc)
        {
         double move=episode.zone.kind==ZONE_SUPPORT ? quote.bid-episode.bid : episode.bid-quote.bid;
         episode.mfe=MathMax(episode.mfe,move); episode.mae=MathMax(episode.mae,-move);
        }
      episode.last_tick_msc=quote.time_msc;
     }
   if(action!=WAIT)
     {
      episode.resolved=true; episode.result="DATA_GAP";
      episode.detail=action==GAP_LOAD ? "Historial M1 no disponible tras reintentos" :
                                       "Sincronización de ticks no disponible tras vencimiento";
     }
   return true;
  }

string g_operations_experts_seen[];
datetime g_operations_scan_time=0,g_operations_m1=0,g_operations_poll_time=0;
string g_operations_trades_file="";
ulong g_operations_deal_tickets[];
datetime g_operations_history_until=0;
bool g_operations_trades_ready=false;

void OperationsScanExperts()
  {
   for(long id=ChartFirst();id>=0;id=ChartNext(id))
     {
      if(id==ChartID() || ChartSymbol(id)!=_Symbol) continue;
      string name=ChartGetString(id,CHART_EXPERT_NAME);
      if(StringLen(name)==0) continue;
      string key=name+"|"+IntegerToString(id);
      bool seen=false;
      for(int i=0;i<ArraySize(g_operations_experts_seen);i++)
         if(g_operations_experts_seen[i]==key) { seen=true; break; }
      if(seen) continue;
      int n=ArraySize(g_operations_experts_seen); ArrayResize(g_operations_experts_seen,n+1);
      g_operations_experts_seen[n]=key;
      Print("OTRO_EXPERTO_EN_SIMBOLO: ",name," | gráfico ",id," | ",EnumToString(ChartPeriod(id)));
     }
   g_operations_scan_time=TimeLocal();
  }

string OperationsTradesHeader()
  {
   return "deal_ticket;position_id;time_server;time_msc;symbol;type;entry;volume;price;sl;tp;profit;commission;swap;comment;writer_session";
  }

// Identity hash: a deal ticket is already a unique ulong, without collisions.
int OperationsTicketIndex(const ulong &tickets[],const ulong ticket)
  {
   if(ArraySize(tickets)==0) return -1;
   int p=ArrayBsearch(tickets,ticket);
   return p>=0 && tickets[p]==ticket ? p : -1;
  }

int OperationsRememberTicket(ulong &tickets[],const ulong ticket)
  {
   int old=OperationsTicketIndex(tickets,ticket); if(old>=0) return old;
   int n=ArraySize(tickets),p=n;
   if(n>0) { p=ArrayBsearch(tickets,ticket); if(tickets[p]<ticket) p++; }
   if(ArrayResize(tickets,n+1)!=n+1) return -1;
   for(int i=n;i>p;i--) tickets[i]=tickets[i-1];
   tickets[p]=ticket; return p;
  }

string OperationsCsvCell(string value)
  {
   StringReplace(value,"\r"," "); StringReplace(value,"\n"," "); StringReplace(value,"\"","\"\"");
   return "\""+value+"\"";
  }

bool OperationsLoadTradeTickets()
  {
   ArrayResize(g_operations_deal_tickets,0);
   if(!FileIsExist(g_operations_trades_file,FILE_COMMON)) return true;
   int file=FileOpen(g_operations_trades_file,FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ,';',CP_UTF8);
   if(file==INVALID_HANDLE) return false;
   string row[],expected[]; StringSplit(OperationsTradesHeader(),';',expected);
   bool valid=ReadCsvRow(file,row) && ArraySize(row)==16;
   if(valid) for(int i=0;i<16;i++) if(row[i]!=expected[i]) { valid=false; break; }
   while(valid && !FileIsEnding(file))
     {
      if(!ReadCsvRow(file,row)) break;
      if(ArraySize(row)!=16 || StringToInteger(row[0])<=0) { valid=false; break; }
      if(OperationsRememberTicket(g_operations_deal_tickets,(ulong)StringToInteger(row[0]))<0) valid=false;
     }
   FileClose(file); return valid;
  }

bool OperationsWriteTradeRow(const string &values[])
  {
   if(ArraySize(values)!=16) return false;
   ulong ticket=(ulong)StringToInteger(values[0]); if(ticket==0) return false;
   if(OperationsTicketIndex(g_operations_deal_tickets,ticket)>=0) return true;
   int file=FileOpen(g_operations_trades_file,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ,0,CP_UTF8);
   if(file==INVALID_HANDLE) { Print("OPERACIONES_CSV_ERROR: ",g_operations_trades_file," | ",GetLastError()); return false; }
   bool ok=true;
   if(FileSize(file)==0) ok=FileWriteString(file,OperationsTradesHeader()+"\r\n")>0;
   FileSeek(file,0,SEEK_END);
   string line="";
   for(int i=0;i<16;i++) { if(i>0) line+=";"; line+=OperationsCsvCell(values[i]); }
   if(ok) ok=FileWriteString(file,line+"\r\n")>0;
   ResetLastError(); FileFlush(file); if(GetLastError()!=0) ok=false;
   FileClose(file);
   if(ok) ok=OperationsRememberTicket(g_operations_deal_tickets,ticket)>=0;
   if(!ok) Print("OPERACIONES_CSV_ERROR: escritura de deal ",ticket);
   return ok;
  }

void OperationsExportTrades()
  {
   if(!InpExportTrades || !g_operations_trades_ready) return;
   datetime now=TimeCurrent(); if(now<=0) return;
   datetime from=(datetime)(g_operations_history_until>0 ? MathMax(0,g_operations_history_until-60) :
                                               MathMax(0,now-(long)MathMax(0,InpTradesBackfillDays)*86400));
   if(!HistorySelect(from,now)) { Print("OPERACIONES_HISTORIAL_NO_DISPONIBLE: ",GetLastError()); return; }
   bool complete=true;
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      ulong ticket=HistoryDealGetTicket(i); if(ticket==0) { complete=false; continue; }
      if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol) continue;
      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket,DEAL_TYPE);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;
      if(OperationsTicketIndex(g_operations_deal_tickets,ticket)>=0) continue;
      string row[]; ArrayResize(row,16); for(int c=0;c<16;c++) row[c]="";
      row[0]=IntegerToString(ticket); row[1]=IntegerToString(HistoryDealGetInteger(ticket,DEAL_POSITION_ID));
      row[2]=TimeToString((datetime)HistoryDealGetInteger(ticket,DEAL_TIME),TIME_DATE|TIME_SECONDS);
      row[3]=IntegerToString(HistoryDealGetInteger(ticket,DEAL_TIME_MSC)); row[4]=_Symbol;
      row[5]=EnumToString(type); row[6]=EnumToString((ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY));
      row[7]=DoubleToString(HistoryDealGetDouble(ticket,DEAL_VOLUME),8);
      row[8]=DoubleToString(HistoryDealGetDouble(ticket,DEAL_PRICE),_Digits);
      row[9]=DoubleToString(HistoryDealGetDouble(ticket,DEAL_SL),_Digits);
      row[10]=DoubleToString(HistoryDealGetDouble(ticket,DEAL_TP),_Digits);
      row[11]=DoubleToString(HistoryDealGetDouble(ticket,DEAL_PROFIT),8);
      row[12]=DoubleToString(HistoryDealGetDouble(ticket,DEAL_COMMISSION),8);
      row[13]=DoubleToString(HistoryDealGetDouble(ticket,DEAL_SWAP),8);
      row[14]=HistoryDealGetString(ticket,DEAL_COMMENT); row[15]=g_writer_session;
      if(!OperationsWriteTradeRow(row)) { complete=false; break; }
     }
   if(complete) g_operations_history_until=now;
  }

// Account-wide limits; only the combined directional exposure is Boom/Crash specific.
int DisciplineEvaluate(const int open_positions,const bool boom_buy,const bool crash_sell,
   const int closed_today,const double &net_newest_first[],const int max_open=2,
   const int max_trades=8,const int max_losses=3)
  {
   int flags=0,losses=0;
   if(open_positions>max_open) flags|=1;
   if(boom_buy && crash_sell) flags|=2;
   if(closed_today>=max_trades) flags|=4;
   for(int i=0;i<ArraySize(net_newest_first) && net_newest_first[i]<0.0;i++) losses++;
   if(losses>=max_losses) flags|=8;
   return flags;
  }

struct OperationsClosedPosition
  {
   double net;
   long last_exit_msc;
  };

void OperationsDisciplineAlert(const string code,const string message)
  {
   string key="BCSO_DISC_"+code;
   if(!GlobalVariableCheck(key) && !GlobalVariableTemp(key)) return;
   double previous=GlobalVariableGet(key),now=(double)TimeLocal();
   if(previous>0 && now-previous<(long)MathMax(0,InpDisciplineCooldownMin)*60) return;
   if(!GlobalVariableSetOnCondition(key,now,previous)) return;
   Print("DISCIPLINA: ",message); Alert("DISCIPLINA: ",message);
  }

void OperationsCheckDiscipline()
  {
   if(!InpEnableDisciplineMonitor) return;
   int opened=PositionsTotal(); bool boom_buy=false,crash_sell=false;
   ulong active[];
   for(int i=0;i<opened;i++)
     {
      if(PositionGetTicket(i)==0) return;
      OperationsRememberTicket(active,(ulong)PositionGetInteger(POSITION_IDENTIFIER));
      string symbol=PositionGetString(POSITION_SYMBOL);
      long type=PositionGetInteger(POSITION_TYPE);
      if(StringFind(symbol,"Boom 1000")>=0 && type==POSITION_TYPE_BUY) boom_buy=true;
      if(StringFind(symbol,"Crash 1000")>=0 && type==POSITION_TYPE_SELL) crash_sell=true;
     }
   datetime now=TimeCurrent();
   if(!HistorySelect(0,now)) { Print("DISCIPLINA: historial no disponible para evaluar cierres"); return; }
   ulong ids[]; OperationsClosedPosition positions[];
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      ulong ticket=HistoryDealGetTicket(i); if(ticket==0) return;
      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket,DEAL_TYPE);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;
      ulong id=(ulong)HistoryDealGetInteger(ticket,DEAL_POSITION_ID); if(id==0) continue;
      int p=OperationsTicketIndex(ids,id);
      if(p<0)
        {
         int n=ArraySize(ids); p=OperationsRememberTicket(ids,id); if(p<0) return;
         ArrayResize(positions,n+1);
         for(int k=n;k>p;k--) positions[k]=positions[k-1];
         positions[p].net=0.0; positions[p].last_exit_msc=0;
        }
      positions[p].net+=HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_COMMISSION)+HistoryDealGetDouble(ticket,DEAL_SWAP);
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)
         positions[p].last_exit_msc=MathMax(positions[p].last_exit_msc,HistoryDealGetInteger(ticket,DEAL_TIME_MSC));
     }
   MqlDateTime day; TimeToStruct(now,day); day.hour=0; day.min=0; day.sec=0;
   long midnight=(long)StructToTime(day)*1000;
   double nets[]; long closes[]; int closed_today=0;
   for(int i=0;i<ArraySize(ids);i++)
     {
      if(positions[i].last_exit_msc<=0 || OperationsTicketIndex(active,ids[i])>=0) continue;
      if(positions[i].last_exit_msc>=midnight) closed_today++;
      int n=ArraySize(nets); ArrayResize(nets,n+1); ArrayResize(closes,n+1); int p=n;
      while(p>0 && closes[p-1]<positions[i].last_exit_msc) { nets[p]=nets[p-1]; closes[p]=closes[p-1]; p--; }
      nets[p]=positions[i].net; closes[p]=positions[i].last_exit_msc;
     }
   int flags=DisciplineEvaluate(opened,boom_buy,crash_sell,closed_today,nets,
                               InpMaxOpenPositions,InpMaxTradesPerDay,InpMaxConsecutiveLosses);
   if((flags&1)!=0) OperationsDisciplineAlert("OPEN","más de "+IntegerToString(InpMaxOpenPositions)+" posiciones abiertas");
   if((flags&2)!=0) OperationsDisciplineAlert("DIRECTION","Boom en compra y Crash en venta: misma apuesta contra la deriva en dos símbolos");
   if((flags&4)!=0) OperationsDisciplineAlert("DAILY",IntegerToString(InpMaxTradesPerDay)+" o más posiciones cerradas en el día del servidor");
   if((flags&8)!=0) OperationsDisciplineAlert("LOSSES",IntegerToString(InpMaxConsecutiveLosses)+" o más cierres seguidos con resultado neto negativo");
  }

void OperationsInitialize()
  {
   OperationsR3Initialize();
   OperationsScanExperts();
   g_operations_trades_file=TaggedCsv("BCSO_"+SafeSymbolName()+"_trades_v1603.csv");
   if(InpExportTrades)
     {
      g_operations_trades_ready=OperationsLoadTradeTickets();
      if(!g_operations_trades_ready) Print("OPERACIONES_CSV_ERROR: archivo incompatible o ilegible | ",g_operations_trades_file);
     }
   g_operations_m1=iTime(_Symbol,PERIOD_M1,0);
   g_operations_poll_time=TimeLocal();
   OperationsExportTrades(); OperationsCheckDiscipline();
  }

void OperationsPoll()
  {
   datetime bar=iTime(_Symbol,PERIOD_M1,0),now=TimeLocal();
   bool new_bar=bar>0 && bar!=g_operations_m1;
   if(new_bar)
     {
      g_operations_m1=bar;
      if(now-g_operations_scan_time>=600) OperationsScanExperts();
     }
   if(new_bar || now-g_operations_poll_time>=30)
     {
      g_operations_poll_time=now;
      OperationsExportTrades(); OperationsCheckDiscipline();
      OperationsExportTrades2(); OperationsRiskPoll();
     }
  }
// New r3 files own their headers and handles. Existing CSV schemas are unchanged.
int g_ops_trades2=INVALID_HANDLE,g_ops_context=INVALID_HANDLE,g_ops_follow=INVALID_HANDLE;
ulong g_ops_tickets2[];
string g_ops_follow_written[];
datetime g_ops_history2=0,g_ops_context_bar=0,g_ops_risk_start=0,g_ops_crash_last=0;
Trend g_ops_trend_m5=TREND_NONE,g_ops_trend_m15=TREND_NONE,g_ops_trend_h1=TREND_NONE;
datetime g_ops_trend_bar=0;
string g_ops_last_alert="";
long g_ops_last_alert_msc=0;

string DealReasonToOrigin(const ENUM_DEAL_REASON reason,const ENUM_DEAL_ENTRY entry)
  {
   switch(reason)
     {
      case DEAL_REASON_CLIENT: return "MANUAL_TERMINAL";
      case DEAL_REASON_MOBILE: return "MANUAL_MOBILE";
      case DEAL_REASON_WEB: return "MANUAL_WEB";
      case DEAL_REASON_EXPERT: return "EA";
      case DEAL_REASON_SL: return "SL";
      case DEAL_REASON_TP: return "TP";
      case DEAL_REASON_SO: return "STOPOUT";
     }
   return "OTRO";
  }

double PlannedRiskUSD(const double price,const double sl,const double volume,
                      const double tick_size,const double tick_value)
  {
   if(price<=0 || sl<=0 || volume<=0 || tick_size<=0 || tick_value<=0) return -1.0;
   return MathAbs(price-sl)/tick_size*tick_value*volume;
  }

// Bits: 1 no stop, 2 excess planned risk, 4 adverse spike, 8 excess realized loss.
int RiskWarningDecision(const bool sl_missing,const double planned,const double limit,
                        const bool adverse_spike,const bool closed=false,const double net=0)
  {
   if(closed) return limit>0 && net<-limit ? 8 : 0;
   return (sl_missing ? 1 : 0) | (limit>0 && planned>limit ? 2 : 0) | (adverse_spike ? 4 : 0);
  }

string RiskLossDetail(const double net,const double planned,const double limit)
  {
   if(planned<0) return "riesgo planificado desconocido";
   if(planned>limit) return "dimensionamiento por encima del limite";
   if(-net>planned) return "posible salto de precio, costes o cambio de SL; requiere contraste";
   return "perdida dentro del riesgo estimado";
  }

bool RiskAdverseSpike(const string symbol,const bool buy)
  { return (StringFind(symbol,"Boom")>=0 && !buy) || (StringFind(symbol,"Crash")>=0 && buy); }

double OperationsRiskFor(const string symbol,const double price,const double sl,const double volume)
  {
   double value=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(value<=0) value=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
   return PlannedRiskUSD(price,sl,volume,SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE),value);
  }

string OperationsTrades2Header()
  {
   return OperationsTradesHeader()+";deal_magic;deal_reason;deal_order;origin;risk_usd_planned;sl_missing;hold_seconds;exit_reason;writer_build";
  }

string OperationsContextHeader()
  {
   return "time_server;time_msc;bid;ask;sup_lower;sup_upper;sup_touches;sup_dist_widths;res_lower;res_upper;res_touches;res_dist_widths;trend_m5;trend_m15;trend_h1;struct_pos_m5_pct;struct_pos_m15_pct;minutes_since_last_spike;spike_last_bar;last_alert_id;last_alert_age_s;last_touch_id;last_touch_age_s;writer_session;writer_build";
  }

string OperationsFollowHeader()
  {
   return "rejection_id;time_server;module;side;gate;zone_lower;zone_upper;ref_price;mfe_price;mae_price;mfe_widths;mae_widths;spike_during;spike_dir;spike_known_at;result;detail;writer_program;writer_chart;writer_build;writer_session";
  }

int OperationsOpenNew(const string suffix,const string header)
  {
   string path=TaggedCsv("BCSO_"+SafeSymbolName()+"_"+suffix+"_v1603.csv");
   int h=FileOpen(path,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ,0,CP_UTF8);
   if(h==INVALID_HANDLE) { Print("R3_CSV_ERROR: ",path," | ",GetLastError()); return h; }
   if(FileSize(h)==0)
     { if(FileWriteString(h,header+"\r\n")==0) { FileClose(h); return INVALID_HANDLE; } FileFlush(h); }
   FileSeek(h,0,SEEK_SET);
   string actual=FileReadString(h);
   if(actual!=header) { Print("R3_CSV_ERROR: esquema incompatible | ",path); FileClose(h); return INVALID_HANDLE; }
   return h;
  }

bool OperationsAppendNew(const int h,const string &row[])
  {
   if(h==INVALID_HANDLE) return false;
   FileSeek(h,0,SEEK_END); ResetLastError();
   string line="";
   for(int i=0;i<ArraySize(row);i++) { if(i>0) line+=";"; line+=OperationsCsvCell(row[i]); }
   bool ok=FileWriteString(h,line+"\r\n")>0;
   FileFlush(h); ok=ok && GetLastError()==0;
   if(!ok) Print("R3_CSV_ERROR: append/flush | ",GetLastError());
   return ok;
  }

bool OperationsEntry(const ulong id,long &time_msc,double &planned)
  {
   time_msc=0; planned=-1;
   // HistorySelectByPosition replaces the terminal's selection; callers snapshot tickets first.
   if(!HistorySelectByPosition(id)) return false;
   double sum=0; bool valid=true;
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      ulong t=HistoryDealGetTicket(i);
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(t,DEAL_ENTRY);
      if(e!=DEAL_ENTRY_IN) continue;
      long when=HistoryDealGetInteger(t,DEAL_TIME_MSC);
      if(time_msc==0 || when<time_msc) time_msc=when;
      double risk=OperationsRiskFor(HistoryDealGetString(t,DEAL_SYMBOL),HistoryDealGetDouble(t,DEAL_PRICE),
                                   HistoryDealGetDouble(t,DEAL_SL),HistoryDealGetDouble(t,DEAL_VOLUME));
      if(risk<0) valid=false; else sum+=risk;
     }
   if(valid && time_msc>0) planned=sum;
   return time_msc>0;
  }

void OperationsExportTrades2()
  {
   if(!InpExportTrades2 || g_ops_trades2==INVALID_HANDLE) return;
   datetime now=TimeCurrent();
   datetime from=g_ops_history2>0 ? (datetime)MathMax(0,(long)g_ops_history2-60) :
                                   (datetime)MathMax(0,(long)now-(long)MathMax(0,InpTrades2BackfillDays)*86400);
   if(!HistorySelect(from,now)) { Print("R3_HISTORIAL_ERROR: trades2"); return; }
   ulong tickets[]; int count=HistoryDealsTotal(); ArrayResize(tickets,count);
   for(int i=0;i<count;i++) tickets[i]=HistoryDealGetTicket(i);
   for(int i=0;i<count;i++)
     {
      ulong t=tickets[i]; if(t==0) return;
      if(OperationsTicketIndex(g_ops_tickets2,t)>=0) continue;
      if(!HistoryDealSelect(t)) return;
      if(HistoryDealGetString(t,DEAL_SYMBOL)!=_Symbol) continue;
      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(t,DEAL_TYPE);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(t,DEAL_ENTRY);
      ENUM_DEAL_REASON reason=(ENUM_DEAL_REASON)HistoryDealGetInteger(t,DEAL_REASON);
      ulong id=(ulong)HistoryDealGetInteger(t,DEAL_POSITION_ID);
      long when=HistoryDealGetInteger(t,DEAL_TIME_MSC);
      double price=HistoryDealGetDouble(t,DEAL_PRICE),sl=HistoryDealGetDouble(t,DEAL_SL),volume=HistoryDealGetDouble(t,DEAL_VOLUME);
      string row[]; ArrayResize(row,25);
      for(int c=0;c<25;c++) row[c]="";
      row[0]=IntegerToString(t); row[1]=IntegerToString(id);
      row[2]=TimeToString((datetime)(when/1000),TIME_DATE|TIME_SECONDS); row[3]=IntegerToString(when);
      row[4]=_Symbol; row[5]=EnumToString(type); row[6]=EnumToString(entry);
      row[7]=DoubleToString(volume,8); row[8]=DoubleToString(price,_Digits); row[9]=DoubleToString(sl,_Digits);
      row[10]=DoubleToString(HistoryDealGetDouble(t,DEAL_TP),_Digits);
      row[11]=DoubleToString(HistoryDealGetDouble(t,DEAL_PROFIT),8);
      row[12]=DoubleToString(HistoryDealGetDouble(t,DEAL_COMMISSION),8);
      row[13]=DoubleToString(HistoryDealGetDouble(t,DEAL_SWAP),8);
      row[14]=HistoryDealGetString(t,DEAL_COMMENT); row[15]=g_writer_session;
      row[16]=IntegerToString(HistoryDealGetInteger(t,DEAL_MAGIC)); row[17]=EnumToString(reason);
      row[18]=IntegerToString(HistoryDealGetInteger(t,DEAL_ORDER)); row[19]=DealReasonToOrigin(reason,entry);
      double risk=OperationsRiskFor(_Symbol,price,sl,volume);
      if(entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_INOUT)
        { row[20]=risk>=0 ? DoubleToString(risk,8) : ""; row[21]=sl<=0 ? "1" : "0"; }
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)
        {
         long opened; double planned;
         if(OperationsEntry(id,opened,planned) && when>=opened) row[22]=DoubleToString((when-opened)/1000.0,3);
         row[23]=DealReasonToOrigin(reason,entry);
        }
      row[24]=OBSERVER_BUILD_TAG;
      if(!OperationsAppendNew(g_ops_trades2,row)) return;
      if(OperationsRememberTicket(g_ops_tickets2,t)<0) return;
     }
   g_ops_history2=now;
  }

void OperationsRiskOnce(const string code,const ulong ticket,const string text)
  {
   string key="BCSO_DISC_"+code+"_"+IntegerToString(ticket);
   if(!GlobalVariableCheck(key) && !GlobalVariableTemp(key)) return;
   if(!GlobalVariableSetOnCondition(key,1.0,0.0)) return;
   Print("DISCIPLINA: ",text); Alert("DISCIPLINA: ",text);
  }

void OperationsRiskPoll()
  {
   if(!InpEnableDisciplineMonitor) return;
   ulong active[];
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket=PositionGetTicket(i); if(ticket==0) return;
      OperationsRememberTicket(active,(ulong)PositionGetInteger(POSITION_IDENTIFIER));
      string symbol=PositionGetString(POSITION_SYMBOL);
      bool buy=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
      double sl=PositionGetDouble(POSITION_SL);
      double risk=OperationsRiskFor(symbol,PositionGetDouble(POSITION_PRICE_OPEN),sl,PositionGetDouble(POSITION_VOLUME));
      bool adverse=RiskAdverseSpike(symbol,buy);
      int flags=RiskWarningDecision(sl<=0,risk,InpMaxRiskPerTradeUSD,adverse);
      if((flags&1)!=0) OperationsRiskOnce("NO_SL",ticket,symbol+" posicion "+IntegerToString(ticket)+" sin SL");
      if((flags&2)!=0) OperationsRiskOnce("RISK",ticket,symbol+" riesgo planificado "+DoubleToString(risk,2)+" > limite "+DoubleToString(InpMaxRiskPerTradeUSD,2));
      if((flags&4)!=0) OperationsRiskOnce("SPIKE",ticket,symbol+": el stop puede ejecutarse tras un salto de precio; la perdida real puede superar el planificado");
     }
   datetime now=TimeCurrent(); MqlDateTime parts; TimeToStruct(now,parts);
   parts.hour=0; parts.min=0; parts.sec=0; datetime midnight=StructToTime(parts);
   if(!HistorySelect(midnight,now)) return;
   double day_net=0; ulong ids[];
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      ulong ticket=HistoryDealGetTicket(i); if(ticket==0) return;
      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket,DEAL_TYPE);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;
      day_net+=HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_COMMISSION)+HistoryDealGetDouble(ticket,DEAL_SWAP);
      ulong id=(ulong)HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
      if(id>0 && OperationsTicketIndex(active,id)<0) OperationsRememberTicket(ids,id);
     }
   if(InpMaxDailyLossUSD>0 && day_net<-InpMaxDailyLossUSD)
      OperationsRiskOnce("DAY",(ulong)midnight,"neto diario "+DoubleToString(day_net,2)+"; limite "+DoubleToString(InpMaxDailyLossUSD,2));
   for(int i=0;i<ArraySize(ids);i++)
     {
      if(!HistorySelectByPosition(ids[i])) continue;
      double net=0; long last=0; ENUM_DEAL_REASON reason=DEAL_REASON_CLIENT;
      for(int k=0;k<HistoryDealsTotal();k++)
        {
         ulong t=HistoryDealGetTicket(k);
         net+=HistoryDealGetDouble(t,DEAL_PROFIT)+HistoryDealGetDouble(t,DEAL_COMMISSION)+HistoryDealGetDouble(t,DEAL_SWAP);
         ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(t,DEAL_ENTRY);
         long at=HistoryDealGetInteger(t,DEAL_TIME_MSC);
         if(e!=DEAL_ENTRY_IN && at>=last) { last=at; reason=(ENUM_DEAL_REASON)HistoryDealGetInteger(t,DEAL_REASON); }
        }
      if(last<(long)g_ops_risk_start*1000 || RiskWarningDecision(false,0,InpMaxRiskPerTradeUSD,false,true,net)==0) continue;
      long opened; double planned; OperationsEntry(ids[i],opened,planned);
      OperationsRiskOnce("REAL",ids[i],"posicion "+IntegerToString(ids[i])+" neto "+DoubleToString(net,2)+
         "; riesgo estimado "+(planned<0 ? "desconocido" : DoubleToString(planned,2))+"; exit_reason "+
         DealReasonToOrigin(reason,DEAL_ENTRY_OUT)+"; "+RiskLossDetail(net,planned,InpMaxRiskPerTradeUSD));
     }
  }

void OperationsCacheTrends(const Trend m5,const Trend m15,const Trend h1)
  {
   g_ops_trend_m5=m5; g_ops_trend_m15=m15; g_ops_trend_h1=h1; g_ops_trend_bar=iTime(_Symbol,PERIOD_M1,0);
  }

void OperationsZoneSnapshot(const double &centers[],const int &touches[],const double tolerance,
                            const double bid,const bool support,string &row[],const int offset)
  {
   int best=-1; double distance=DBL_MAX;
   for(int i=0;i<ArraySize(centers) && i<ArraySize(touches);i++)
     {
      if(tolerance<=0 || (support ? centers[i]>bid : centers[i]<bid)) continue;
      double gap=MathAbs(bid-centers[i]);
      if(gap<distance) { distance=gap; best=i; }
     }
   if(best<0) return;
   row[offset]=DoubleToString(centers[best]-tolerance,_Digits);
   row[offset+1]=DoubleToString(centers[best]+tolerance,_Digits);
   row[offset+2]=IntegerToString(touches[best]);
   row[offset+3]=DoubleToString(MathMax(0.0,distance-tolerance)/(2*tolerance),5);
  }

void OperationsContextSnapshot()
  {
   if(!InpContextSnapshots || g_ops_context==INVALID_HANDLE) return;
   datetime bar=iTime(_Symbol,PERIOD_M1,0);
   if(bar<=0 || bar<=g_ops_context_bar) return;
   MqlTick quote; if(!SymbolInfoTick(_Symbol,quote) || quote.bid<=0 || quote.ask<quote.bid) return;
   string row[]; ArrayResize(row,25); for(int i=0;i<25;i++) row[i]="";
   row[0]=TimeToString(bar,TIME_DATE|TIME_SECONDS); row[1]=IntegerToString(quote.time_msc);
   row[2]=DoubleToString(quote.bid,_Digits); row[3]=DoubleToString(quote.ask,_Digits);
   OperationsZoneSnapshot(g_early_support_centers,g_early_support_reactions,g_early_support_tolerance,quote.bid,true,row,4);
   OperationsZoneSnapshot(g_early_resistance_centers,g_early_resistance_reactions,g_early_resistance_tolerance,quote.bid,false,row,8);
   if(g_ops_trend_bar==bar) { row[12]=EnumToString(g_ops_trend_m5); row[13]=EnumToString(g_ops_trend_m15); row[14]=EnumToString(g_ops_trend_h1); }
   string context[]; StructureCsvValues(quote.bid,0,context); row[15]=context[6];
   StructureCsvValues(quote.bid,1,context); row[16]=context[6];
   if(g_last_spike_time>0) row[17]=DoubleToString((quote.time_msc/1000.0-g_last_spike_time)/60.0,3);
   row[18]=g_last_spike_time==bar ? "1" : "0";
   row[19]=g_ops_last_alert;
   if(g_ops_last_alert_msc>0) row[20]=DoubleToString((quote.time_msc-g_ops_last_alert_msc)/1000.0,3);
   long latest=0;
   for(int i=0;i<ArraySize(g_touch_spikes);i++)
      if(g_touch_spikes[i].touch_msc>latest) { latest=g_touch_spikes[i].touch_msc; row[21]=g_touch_spikes[i].id; }
   if(latest>0) row[22]=DoubleToString((quote.time_msc-latest)/1000.0,3);
   row[23]=g_writer_session; row[24]=OBSERVER_BUILD_TAG;
   if(OperationsAppendNew(g_ops_context,row)) g_ops_context_bar=bar;
  }

// Shared tick primitives: used by the existing touch replay and rejection follow-up.
int OperationsCopyTicks(MqlTick &ticks[],const long from,const long to)
  {
   ResetLastError(); return CopyTicksRange(_Symbol,ticks,COPY_TICKS_ALL,(ulong)from,(ulong)to);
  }
bool OperationsTickGap(const long previous,const long next)
  { return next<previous || next-previous>(long)InpMaxTickGapSeconds*1000; }

void FollowupExcursion(const bool buy,const double reference,const double executable_price,const double width,
                      double &mfe,double &mae,double &mfe_widths,double &mae_widths)
  {
   double move=buy ? executable_price-reference : reference-executable_price;
   mfe=MathMax(mfe,move); mae=MathMax(mae,-move);
   mfe_widths=width>0 ? mfe/width : 0; mae_widths=width>0 ? mae/width : 0;
  }

string FollowupCloseDecision(const bool covered,const bool final_bar_closed)
  { return !final_bar_closed ? "WAIT" : (covered ? "OBSERVED" : "DATA_GAP"); }

struct OperationsFollow
  {
   bool active,covered; string id,module,side,gate,detail,spike_dir;
   long start,deadline,cursor,last_spike_close,spike_known;
   double lower,upper,reference,mfe,mae,mfe_widths,mae_widths;
  };
OperationsFollow g_ops_follows[50];

bool OperationsFollowKnown(const string id)
  {
   for(int i=0;i<ArraySize(g_ops_follow_written);i++) if(g_ops_follow_written[i]==id) return true;
   for(int i=0;i<50;i++) if(g_ops_follows[i].active && g_ops_follows[i].id==id) return true;
   return false;
  }

void OperationsFollowRow(const OperationsFollow &e,const string result,const string detail,string &row[])
  {
   ArrayResize(row,21); for(int i=0;i<21;i++) row[i]="";
   row[0]=e.id; row[1]=TimeToString((datetime)(e.start/1000),TIME_DATE|TIME_SECONDS);
   row[2]=e.module; row[3]=e.side; row[4]=e.gate;
   row[5]=DoubleToString(e.lower,_Digits); row[6]=DoubleToString(e.upper,_Digits);
   if(e.reference>0) row[7]=DoubleToString(e.reference,_Digits);
   if(result=="OBSERVED")
     {
      row[8]=DoubleToString(e.mfe,_Digits); row[9]=DoubleToString(e.mae,_Digits);
      row[10]=DoubleToString(e.mfe_widths,5); row[11]=DoubleToString(e.mae_widths,5);
      row[12]=e.spike_known>0 ? "1" : "0"; row[13]=e.spike_dir;
      if(e.spike_known>0) row[14]=TimeToString((datetime)(e.spike_known/1000),TIME_DATE|TIME_SECONDS);
     }
   row[15]=result; row[16]=detail; row[17]=g_writer_program; row[18]=g_writer_chart;
   row[19]=OBSERVER_BUILD_TAG; row[20]=g_writer_session;
  }

bool OperationsFinishFollow(OperationsFollow &e,const string result,const string detail)
  {
   string row[]; OperationsFollowRow(e,result,detail,row);
   if(!OperationsAppendNew(g_ops_follow,row)) return false;
   int n=ArraySize(g_ops_follow_written); ArrayResize(g_ops_follow_written,n+1); g_ops_follow_written[n]=e.id;
   e.active=false; return true;
  }

void OperationsRejectionWritten(const string id,const string module,const string side,const string gate,const Zone &zone)
  {
   if(!InpRejectionFollowup || g_ops_follow==INVALID_HANDLE || OperationsFollowKnown(id)) return;
   int slot=-1,oldest=0;
   for(int i=0;i<50;i++)
     { if(!g_ops_follows[i].active) { slot=i; break; } if(g_ops_follows[i].start<g_ops_follows[oldest].start) oldest=i; }
   if(slot<0)
     { if(!OperationsFinishFollow(g_ops_follows[oldest],"DATA_GAP","Limite de 50 seguimientos; expulsado el mas antiguo")) return; slot=oldest; }
   OperationsFollow e; ZeroMemory(e); e.active=true; e.covered=true;
   e.id=id; e.module=module; e.side=side; e.gate=gate; e.lower=zone.lower; e.upper=zone.upper; e.spike_dir="NONE";
   MqlTick q; bool valid=SymbolInfoTick(_Symbol,q) && q.time_msc>0 && q.bid>0 && q.ask>=q.bid;
   e.start=valid ? q.time_msc : (long)TimeCurrent()*1000;
   e.cursor=e.start; e.deadline=e.start+(long)MathMax(1,InpRejectionFollowMinutes)*60000;
   e.last_spike_close=(e.start/60000)*60000;
   e.reference=valid ? (side=="SELL" ? q.bid : q.ask) : 0;
   e.covered=valid && e.upper>e.lower; e.detail=e.covered ? "" : "Cotizacion o ancho de zona no disponible";
   if(valid) FollowupExcursion(side=="BUY",e.reference,side=="BUY" ? q.bid : q.ask,e.upper-e.lower,e.mfe,e.mae,e.mfe_widths,e.mae_widths);
   g_ops_follows[slot]=e;
  }

void OperationsFollowPoll()
  {
   if(!InpRejectionFollowup || g_ops_follow==INVALID_HANDLE) return;
   MqlTick quote; if(!SymbolInfoTick(_Symbol,quote) || quote.time_msc<=0) return;
   for(int i=0;i<50;i++)
     {
      if(!g_ops_follows[i].active) continue;
      OperationsFollow e=g_ops_follows[i]; long end=(long)MathMin(quote.time_msc,e.deadline);
      if(e.covered && end>e.cursor)
        {
         MqlTick ticks[]; int n=OperationsCopyTicks(ticks,e.cursor+1,end); int error=GetLastError();
         long previous=e.cursor;
         if(n<0 || error!=0) { e.covered=false; e.detail="CopyTicksRange no disponible"; }
         for(int k=0;k<n && e.covered;k++)
           {
            if(OperationsTickGap(previous,ticks[k].time_msc) || ticks[k].bid<=0 || ticks[k].ask<ticks[k].bid)
              { e.covered=false; e.detail="Cobertura real de ticks incompleta"; break; }
            previous=ticks[k].time_msc;
            FollowupExcursion(e.side=="BUY",e.reference,e.side=="BUY" ? ticks[k].bid : ticks[k].ask,e.upper-e.lower,e.mfe,e.mae,e.mfe_widths,e.mae_widths);
           }
         if(e.covered && OperationsTickGap(previous,end)) { e.covered=false; e.detail="Hueco al final del intervalo de ticks"; }
         e.cursor=previous;
        }
      long final_close=(e.deadline/60000+1)*60000;
      long ready=(quote.time_msc/60000)*60000;
      for(long close=e.last_spike_close+60000;close<=ready && close<=final_close && e.covered;close+=60000)
        {
         // Exact bar lookup uses its opening time; do not silently accept missing M1 history.
         int shift=iBarShift(_Symbol,PERIOD_M1,(datetime)(close/1000-60),true);
         MqlRates bars[];
         if(shift<1 || CopyRates(_Symbol,PERIOD_M1,shift,InpSpikeMedianBars+1,bars)<InpSpikeMedianBars+1)
           { e.covered=false; e.detail="Historial M1 insuficiente"; break; }
         string direction=ClosedSpikeAt(close,e.start);
         if(direction!="NONE" && e.spike_known==0)
           {
            if(close-60000<e.start || close>e.deadline)
              { e.covered=false; e.detail="Spike en vela frontera: instante intravela no identificable"; break; }
            e.spike_known=close; e.spike_dir=direction;
           }
         e.last_spike_close=close;
        }
      g_ops_follows[i]=e;
      string result=FollowupCloseDecision(e.covered,quote.time_msc>=final_close);
      if(result!="WAIT") OperationsFinishFollow(g_ops_follows[i],result,e.covered ? "Ventana observada; cotizacion de salida ejecutable; spike por vela cerrada" : e.detail);
     }
  }

void OperationsSignalLevels(const string module,const double entry,double &stop,double &target)
  {
   if(module!="CRASH_TREND_EARLY_R2") return;
   stop=g_crash_floor+MathMax(StopBuffer(),0.5*g_crash_average_range);
   target=NearestCurrentM5SupportTarget(entry);
  }

void OperationsCrashTrendCandidate()
  {
   if(!InpEnableCrashTrendEvaluable || !IsCrashSymbol() || !g_crash_context_down || !ActivePack()) return;
   MqlTick q; if(!SymbolInfoTick(_Symbol,q) || q.bid<=0) return;
   double margin=MathMax(_Point,MathMax(BreakMargin(),0.1*g_crash_average_range));
   if(q.bid>=g_crash_floor-margin || iOpen(_Symbol,PERIOD_M5,0)<g_crash_floor-margin ||
      g_crash_floor-q.bid>0.5*g_crash_average_range ||
      iHigh(_Symbol,PERIOD_M5,0)-iLow(_Symbol,PERIOD_M5,0)>1.5*g_crash_average_range) return;
   datetime bar=iTime(_Symbol,PERIOD_M1,1),now=TimeCurrent();
   if(g_ops_crash_last>0 && now-g_ops_crash_last<MathMax(1,InpCandidateCooldownMinutes)*60) return;
   MqlRates m1[]; if(!LoadRates(PERIOD_M1,InpScanBarsM1,m1) || g_ops_trend_bar!=iTime(_Symbol,PERIOD_M1,0)) return;
   Zone zone=MakeZone(PERIOD_M5,ZONE_SUPPORT,g_crash_floor,margin,0);
   WriteSignal("CRASH_TREND_EARLY_R2","SELL",zone,g_ops_trend_m5,g_ops_trend_m15,g_ops_trend_h1,m1,"Experimental R2; ruptura con SL y objetivo M5; no opera");
   g_ops_crash_last=now;
  }

void OperationsAfterTick()
  { OperationsFollowPoll(); OperationsContextSnapshot(); OperationsCrashTrendCandidate(); }

void OperationsR3Initialize()
  {
   g_ops_risk_start=TimeCurrent(); string row[];
   if(InpExportTrades2)
     {
      g_ops_trades2=OperationsOpenNew("trades2",OperationsTrades2Header());
      if(g_ops_trades2!=INVALID_HANDLE)
         while(ReadCsvRow(g_ops_trades2,row))
           {
            if(ArraySize(row)!=25 || StringToInteger(row[0])<=0) { Print("R3_CSV_ERROR: trades2 fila invalida"); FileClose(g_ops_trades2); g_ops_trades2=INVALID_HANDLE; break; }
            OperationsRememberTicket(g_ops_tickets2,(ulong)StringToInteger(row[0]));
           }
     }
   if(InpContextSnapshots)
     {
      g_ops_context=OperationsOpenNew("context",OperationsContextHeader());
      if(g_ops_context!=INVALID_HANDLE)
         while(ReadCsvRow(g_ops_context,row))
           {
            if(ArraySize(row)!=25) { Print("R3_CSV_ERROR: context fila invalida"); FileClose(g_ops_context); g_ops_context=INVALID_HANDLE; break; }
            g_ops_context_bar=(datetime)MathMax((long)g_ops_context_bar,(long)StringToTime(row[0]));
           }
     }
   if(InpRejectionFollowup)
     {
      g_ops_follow=OperationsOpenNew("rejection_followup",OperationsFollowHeader());
      if(g_ops_follow!=INVALID_HANDLE)
         while(ReadCsvRow(g_ops_follow,row))
           {
            if(ArraySize(row)!=21) { Print("R3_CSV_ERROR: followup fila invalida"); FileClose(g_ops_follow); g_ops_follow=INVALID_HANDLE; break; }
            int n=ArraySize(g_ops_follow_written); ArrayResize(g_ops_follow_written,n+1); g_ops_follow_written[n]=row[0];
           }
     }
   OperationsExportTrades2();
  }

void OperationsR3Shutdown()
  {
   for(int i=0;i<50;i++) if(g_ops_follows[i].active) OperationsFinishFollow(g_ops_follows[i],"DATA_GAP","Observador detenido antes del cierre de seguimiento");
   if(g_ops_trades2!=INVALID_HANDLE) FileClose(g_ops_trades2);
   if(g_ops_context!=INVALID_HANDLE) FileClose(g_ops_context);
   if(g_ops_follow!=INVALID_HANDLE) FileClose(g_ops_follow);
   g_ops_trades2=INVALID_HANDLE; g_ops_context=INVALID_HANDLE; g_ops_follow=INVALID_HANDLE;
  }

#ifdef BCSO_R3_TESTS
void OperationsRunTests()
  {
   Check(DealReasonToOrigin(DEAL_REASON_CLIENT,DEAL_ENTRY_IN)=="MANUAL_TERMINAL","r3 CLIENT");
   Check(DealReasonToOrigin(DEAL_REASON_MOBILE,DEAL_ENTRY_IN)=="MANUAL_MOBILE","r3 MOBILE");
   Check(DealReasonToOrigin(DEAL_REASON_WEB,DEAL_ENTRY_IN)=="MANUAL_WEB","r3 WEB");
   Check(DealReasonToOrigin(DEAL_REASON_EXPERT,DEAL_ENTRY_IN)=="EA","r3 EXPERT");
   Check(DealReasonToOrigin(DEAL_REASON_SL,DEAL_ENTRY_OUT)=="SL","r3 SL");
   Check(DealReasonToOrigin(DEAL_REASON_TP,DEAL_ENTRY_OUT)=="TP","r3 TP");
   Check(DealReasonToOrigin(DEAL_REASON_SO,DEAL_ENTRY_OUT)=="STOPOUT","r3 SO");
   Check(MathAbs(PlannedRiskUSD(100,95,0.2,0.5,2)-4)<1e-9,"r3 riesgo conocido");
   Check(PlannedRiskUSD(100,0,0.2,0.5,2)<0,"r3 sin SL desconocido");
   Check((RiskWarningDecision(true,-1,2,false)&1)!=0,"r3 aviso sin SL");
   Check((RiskWarningDecision(false,3.1,2,false)&2)!=0,"r3 aviso 3.1 > 2");
   Check(RiskWarningDecision(false,1.5,2,false)==0,"r3 sin aviso 1.5");
   Check((RiskWarningDecision(false,1.5,2,RiskAdverseSpike("Boom 1000 Index",false))&4)!=0,"r3 exposicion adversa Boom venta");
   Check(RiskWarningDecision(false,1.8,2,false,true,-3.14)==8 && StringFind(RiskLossDetail(-3.14,1.8,2),"salto de precio")>=0,"r3 perdida real versus planificada");
   double mfe=0,mae=0,mfew=0,maew=0;
   FollowupExcursion(false,100,96,2,mfe,mae,mfew,maew); FollowupExcursion(false,100,102,2,mfe,mae,mfew,maew);
   Check(mfe==4 && mae==2 && mfew==2 && maew==1,"r3b excursion SELL");
   mfe=0; mae=0;
   FollowupExcursion(true,100,106,2,mfe,mae,mfew,maew); FollowupExcursion(true,100,98,2,mfe,mae,mfew,maew);
   Check(mfe==6 && mae==2 && mfew==3 && maew==1,"r3b excursion BUY");
   OperationsFollow fixture; ZeroMemory(fixture); fixture.spike_known=120000; fixture.spike_dir="DOWN";
   string row[]; OperationsFollowRow(fixture,FollowupCloseDecision(true,true),"fixture",row);
   Check(row[15]=="OBSERVED" && row[12]=="1" && row[13]=="DOWN" && row[14]!="","r3b cierre cubierto con spike");
   OperationsFollowRow(fixture,FollowupCloseDecision(false,true),"fixture",row);
   Check(row[15]=="DATA_GAP" && row[12]=="" && row[8]=="","r3b sin ticks DATA_GAP sin falso negativo");
   Check(FollowupCloseDecision(true,false)=="WAIT","r3b espera cierre M1 final");
   Check(StringFind(OBSERVER_BUILD_TAG,"-r3")>=0,"r3b tag");
   Check(OBSERVER_BUILD_VERSION=="1.603" && OBSERVER_RULE_VERSION=="1.600","r3b versiones compatibles");
   InpFileTag="TESTR3_"+IntegerToString((long)TimeLocal())+"_"+IntegerToString(GetTickCount());
   g_writer_program="Test_1603_r3"; g_writer_chart=IntegerToString(ChartID());
   g_writer_session=InpFileTag; g_writer_period=EnumToString((ENUM_TIMEFRAMES)_Period);
   OperationsR3Initialize();
   Check(g_ops_trades2!=INVALID_HANDLE && g_ops_context!=INVALID_HANDLE && g_ops_follow!=INVALID_HANDLE,"r3 archivos nuevos aislados");
   Check(ArraySize(g_ops_tickets2)>0,"r3 exportacion API historial demo");
   OperationsExportTrades2();
   int ledger=FileOpen(TaggedCsv("BCSO_"+SafeSymbolName()+"_trades2_v1603.csv"),FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE,0,CP_UTF8);
   ulong unique[]; bool valid=ledger!=INVALID_HANDLE;
   if(valid)
     {
      ReadCsvRow(ledger,row);
      while(ReadCsvRow(ledger,row))
        {
         if(ArraySize(row)!=25) { valid=false; break; }
         ulong ticket=(ulong)StringToInteger(row[0]);
         if(ticket==0 || OperationsTicketIndex(unique,ticket)>=0 || row[24]!=OBSERVER_BUILD_TAG || row[19]=="") { valid=false; break; }
         OperationsRememberTicket(unique,ticket);
        }
      FileClose(ledger);
     }
   Check(valid && ArraySize(unique)==ArraySize(g_ops_tickets2),"r3 esquema atribucion y deduplicacion real");
   int saved=ArraySize(g_ops_tickets2); OperationsR3Shutdown(); ArrayResize(g_ops_tickets2,0);
   OperationsR3Initialize();
   Check(g_ops_trades2!=INVALID_HANDLE && ArraySize(g_ops_tickets2)>=saved,"r3 recuperacion persistente de tickets");
   OperationsR3Shutdown();
   Print("TESTR3 FILE_TAG=",InpFileTag);
   Print("TESTR3 SUMMARY checks=",test_checks," failures=",test_failures);
  }
#endif
#endif
