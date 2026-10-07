#ifndef BCSO_INSTRUMENTATION_1600
#define BCSO_INSTRUMENTATION_1600

// Parámetros iniciales de medición; los casos manuales no calibran umbrales.
input bool InpMeasureZoneAlerts=true;
input int InpZoneObservationMinutes=30;
input double InpSpikeM1RangeMultiple=8.0;
input int InpSpikeMedianBars=100;
input bool InpLogRejections=true;
input int InpDiagnosticMaxBytes=20000000;
input bool InpProfileM1=true;
input int InpProfileEveryBars=60;
input bool InpDebugZoneCache=false;
input string InpFileTag="R1604"; // archivos separados de la observación 1.603
string g_last_gate="OTHER";
string g_writer_program="",g_writer_chart="",g_writer_period="",g_writer_session="";
string g_writer_lock="",g_writer_lock_prefix="";
bool g_writer_lock_owned=false;
datetime g_writer_lock_renewed=0;

bool OtherWriterAlive()
  {
   datetime now=TimeLocal();
   for(int i=0;i<GlobalVariablesTotal();i++)
     {
      string name=GlobalVariableName(i);
      if(StringFind(name,g_writer_lock_prefix)!=0 || name==g_writer_lock) continue;
      double stamp=GlobalVariableGet(name);
      if(stamp<=0.0 || (double)now-stamp>=20.0) continue;
      long owner=StringToInteger(StringSubstr(name,StringLen(g_writer_lock_prefix)));
      Print("WRITER_LOCK: programa ",ChartGetString(owner,CHART_EXPERT_NAME)," | gráfico ",owner,
            " | símbolo ",ChartSymbol(owner)," | periodo ",EnumToString(ChartPeriod(owner)));
      return true;
     }
   return false;
  }

bool AcquireWriterLock()
  {
   g_writer_program=MQLInfoString(MQL_PROGRAM_NAME); g_writer_chart=IntegerToString(ChartID());
   g_writer_period=EnumToString((ENUM_TIMEFRAMES)_Period);
   g_writer_session=StringFormat("%I64X-%I64X-%I64X",(ulong)TimeLocal(),(ulong)ChartID(),GetMicrosecondCount());
   g_writer_lock_prefix="BCSO_LOCK_"+_Symbol+"_"; g_writer_lock=g_writer_lock_prefix+g_writer_chart;
   if(OtherWriterAlive()) return false;
   if(!GlobalVariableTemp(g_writer_lock) || GlobalVariableSet(g_writer_lock,(double)TimeLocal())==0) return false;
   if(OtherWriterAlive()) { GlobalVariableDel(g_writer_lock); return false; }
   g_writer_lock_owned=true; g_writer_lock_renewed=TimeLocal();
   return true;
  }

bool RenewWriterLock()
  {
   if(!g_writer_lock_owned) return false;
   datetime now=TimeLocal();
   if(now>=g_writer_lock_renewed && now-g_writer_lock_renewed<5) return true;
   if(OtherWriterAlive() || GlobalVariableSet(g_writer_lock,(double)now)==0)
     {
      Print("WRITER_LOCK: propiedad perdida; observación detenida");
      GlobalVariableDel(g_writer_lock); g_writer_lock_owned=false;
      return false;
     }
   g_writer_lock_renewed=now;
   return true;
  }

void FillWriterFields(string &values[],const int start)
  {
   values[start]=g_writer_program; values[start+1]=g_writer_chart; values[start+2]=g_writer_period;
   values[start+3]=OBSERVER_BUILD_TAG; values[start+4]=g_writer_session;
  }

bool ValidFileTag()
  {
   string allowed="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";
   for(int i=0;i<StringLen(InpFileTag);i++)
      if(StringFind(allowed,StringSubstr(InpFileTag,i,1))<0) return false;
   return true;
  }

string TaggedCsv(const string filename)
  {
   if(StringLen(InpFileTag)==0) return filename;
   int n=StringLen(filename);
   if(n>=4 && (StringSubstr(filename,n-4)==".csv" || StringSubstr(filename,n-4)==".CSV"))
      return StringSubstr(filename,0,n-4)+"_"+InpFileTag+StringSubstr(filename,n-4);
   return filename+"_"+InpFileTag;
  }

string g_alerts_file,g_alert_outcomes_file,g_rejections_file;
bool g_record_zone_alert=false;
double g_record_legacy_stop=0.0,g_record_sweep_depth=0.0;
double g_record_volume=0.0,g_record_risk_usd=0.0;
bool g_record_risk_exceeds=false,g_record_leg_spike=false;
bool g_record_control=false;
long g_record_seed=0;
datetime g_last_spike_time=0;
string g_last_spike_dir="NONE";
int g_spike_seeds_excluded=0;
string g_rejection_recent[512];
int g_rejection_cursor=0;

string SafeSymbolName()
  {
   string name=_Symbol;
   string chars=" /\\:*?\"<>|";
   for(int i=0;i<StringLen(chars);i++) StringReplace(name,StringSubstr(chars,i,1),"_");
   return name;
  }

int OpenCsvRetry(const string filename,const int flags,const short delimiter,const uint codepage)
  {
   for(int attempt=0;attempt<3;attempt++)
     {
      int handle=FileOpen(filename,flags,delimiter,codepage);
      if(handle!=INVALID_HANDLE) return handle;
      if(attempt<2 && !IsStopped()) Sleep(20);
     }
   Print("CSV_NO_DISPONIBLE: ",filename," | error ",GetLastError());
   return INVALID_HANDLE;
  }

bool AppendDiagnostic(const string filename,const string header,const string &values[])
  {
   int handle=OpenCsvRetry(filename,FILE_TXT|FILE_READ|FILE_WRITE|FILE_ANSI|FILE_COMMON,';',CP_UTF8);
   if(handle==INVALID_HANDLE) return false;
   if(FileSize(handle)>(ulong)InpDiagnosticMaxBytes)
     { FileClose(handle); Print("DIAGNOSTICO_LIMITE: ",filename); return false; }
   bool empty=FileSize(handle)==0;
   FileSeek(handle,0,SEEK_END);
   bool ok=(!empty || FileWriteString(handle,header+"\r\n")>0) && FileWriteString(handle,CsvLine(values))>0;
   FileFlush(handle); FileClose(handle);
   return ok;
  }

string RejectionGate()
  {
   return g_last_gate;
  }

bool RejectSignal(const string module,const string side,const Zone &zone,const datetime bar,const string detail)
  {
   if(!InpLogRejections) return false;
   string key=RulePackText()+"|"+module+"|"+side+"|"+IntegerToString((long)bar)+"|"+
              EnumToString(zone.timeframe)+"|"+DoubleToString(zone.lower,_Digits)+"|"+DoubleToString(zone.upper,_Digits);
   for(int i=0;i<512;i++) if(g_rejection_recent[i]==key) return false;
   string values[]; ArrayResize(values,13);
   values[0]=key; values[1]=TimeToString(bar,TIME_DATE|TIME_SECONDS); values[2]=_Symbol;
   values[3]=module; values[4]=side; values[5]=EnumToString(zone.timeframe);
   values[6]=DoubleToString(zone.lower,_Digits); values[7]=DoubleToString(zone.upper,_Digits);
   values[8]=IntegerToString(zone.touches); values[9]=RejectionGate(); values[10]=detail;
   values[11]=RulePackText(); values[12]="1600.1";
   if(AppendDiagnostic(g_rejections_file,"rejection_id;time;symbol;module;side;zone_tf;zone_lower;zone_upper;touches;gate_failed;detail;rule_pack;schema_version",values))
     { g_rejection_recent[g_rejection_cursor%512]=key; g_rejection_cursor++;
       OperationsRejectionWritten(key,module,side,RejectionGate(),zone); }
   return false;
  }

void RecoveryIssue(const string filename,const int row,const string reason)
  {
   string values[]; ArrayResize(values,5);
   values[0]=TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS); values[1]=filename;
   values[2]=IntegerToString(row); values[3]=reason; values[4]="1600.1";
   Print("RECUPERACION: ",filename," fila ",row," | ",reason);
   AppendDiagnostic(TaggedCsv("BCSO_"+SafeSymbolName()+"_recovery_v1600.csv"),"time;file;row;issue;schema_version",values);
  }

double RangeMedian(const MqlRates &rates[],const int first,const int count)
  {
   if(first<1 || count<1 || first+count>ArraySize(rates)) return 0.0;
   double spans[]; ArrayResize(spans,count);
   for(int i=0;i<count;i++) spans[i]=rates[first+i].high-rates[first+i].low;
   ArraySort(spans);
   int middle=count/2;
   return count%2==1 ? spans[middle] : (spans[middle-1]+spans[middle])/2.0;
  }

bool IsSpikeM1(const MqlRates &rates[],const int shift)
  {
   double median=RangeMedian(rates,shift+1,InpSpikeMedianBars);
   return median>0.0 && rates[shift].high-rates[shift].low>InpSpikeM1RangeMultiple*median;
  }

void InitializeSpikeContext()
  {
   MqlRates rates[];
   if(!LoadRates(PERIOD_M1,MathMax(500,InpSpikeMedianBars+2),rates)) return;
   for(int i=1;i+InpSpikeMedianBars<ArraySize(rates);i++)
      if(IsSpikeM1(rates,i))
        { g_last_spike_time=rates[i].time+60; g_last_spike_dir=rates[i].close>=rates[i].open ? "UP" : "DOWN"; return; }
  }

void RefreshSpikeContext()
  {
   MqlRates rates[];
   if(!LoadRates(PERIOD_M1,InpSpikeMedianBars+2,rates)) return;
   if(IsSpikeM1(rates,1))
     { g_last_spike_time=rates[1].time+60; g_last_spike_dir=rates[1].close>=rates[1].open ? "UP" : "DOWN"; }
  }

string ClosedSpikeAt(const long event_msc,const long entry_msc)
  {
   int forming=iBarShift(_Symbol,PERIOD_M1,(datetime)(event_msc/1000),false);
   if(forming<0) return "NONE";
   MqlRates rates[]; ArraySetAsSeries(rates,true);
   if(CopyRates(_Symbol,PERIOD_M1,forming+1,InpSpikeMedianBars+1,rates)<InpSpikeMedianBars+1) return "NONE";
   // Este array empieza en una vela ya cerrada: se añade un índice ficticio 0.
   MqlRates padded[]; ArrayResize(padded,ArraySize(rates)+1);
   for(int i=0;i<ArraySize(rates);i++) padded[i+1]=rates[i];
   if((long)(padded[1].time+60)*1000<entry_msc || !IsSpikeM1(padded,1)) return "NONE";
   return padded[1].close>=padded[1].open ? "UP" : "DOWN";
  }

int BarsSinceLastZoneTouch(const Zone &zone)
  {
   MqlRates rates[];
   if(!LoadRates(PERIOD_M5,InpScanBarsM5,rates)) return -1;
   double rebound=MathMax(_Point,(zone.upper-zone.lower)*0.5*InpReactionMinReboundWidths);
   for(int i=1;i<ArraySize(rates);i++)
      if(IsObservedZoneExtreme(rates,i,zone.kind,InpWatchClosedM5Reactions,rebound))
        {
         double price=zone.kind==ZONE_SUPPORT ? rates[i].low : rates[i].high;
         if(price>=zone.lower && price<=zone.upper) return i-1;
        }
   return -1;
  }

int ZoneClosedBreak(const PendingSignal &signal,const long event_msc)
  {
   MqlRates rates[];
   ResetLastError();
   int n=CopyRates(_Symbol,PERIOD_M5,(datetime)(signal.entry_msc/1000-300),(datetime)(event_msc/1000),rates);
   if(n<=0 || GetLastError()!=0) return -1;
   for(int i=0;i<n;i++)
     {
      long close_msc=(long)(rates[i].time+300)*1000;
      if(close_msc<signal.entry_msc || close_msc>event_msc) continue;
      if(signal.side=="BUY" && rates[i].close<signal.zone_lower-signal.break_margin) return 1;
      if(signal.side=="SELL" && rates[i].close>signal.zone_upper+signal.break_margin) return 1;
     }
   return 0;
  }

void ObserveZoneAlert(const string stage,const Zone &zone)
  {
   if(!InpMeasureZoneAlerts || !ActivePack()) return;
   MqlTick quote;
   if(!SymbolInfoTick(_Symbol,quote) || quote.bid<=0.0 || quote.ask<quote.bid) return;
   string side=zone.kind==ZONE_SUPPORT ? "BUY" : "SELL";
   double entry=side=="BUY" ? quote.ask : quote.bid;
   double target=entry+(side=="BUY" ? 1.0 : -1.0)*(zone.upper-zone.lower)*InpReactionMinExcursionWidths;
   g_record_zone_alert=true;
   RecordObservation("ZONE_"+stage,side,zone,TREND_NONE,TREND_NONE,TREND_NONE,
                     "Aviso informativo; reacción virtual por excursión, ruptura por cierre M5",quote,0.0,target,
                     iTime(_Symbol,PERIOD_M1,0),false);
   g_record_zone_alert=false;
  }

void ExplainManualZone()
  {
   if(ObjectFind(0,"BCSO_EXPLAIN")<0) return;
   double price=ObjectGetDouble(0,"BCSO_EXPLAIN",OBJPROP_PRICE);
   MqlRates rates[]; if(!LoadRates(PERIOD_M5,InpScanBarsM5,rates)) return;
   double tolerance=ZoneHalfWidth(rates),rebound=MathMax(_Point,tolerance*InpReactionMinReboundWidths);
   Print("BCSO_EXPLAIN: precio ",DoubleToString(price,_Digits)," | semiancho ",tolerance,
         " | mínimo tick ",SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE)," | distancia máxima ",VisibleDistance());
   for(int type=0;type<2;type++)
     {
      ZoneKind kind=type==0 ? ZONE_SUPPORT : ZONE_RESISTANCE;
      int last_counted=-1,touches=0;
      for(int i=1;i<ArraySize(rates);i++)
        {
         double test=kind==ZONE_SUPPORT ? rates[i].low : rates[i].high;
         bool extreme=IsObservedZoneExtreme(rates,i,kind,InpWatchClosedM5Reactions,rebound);
         if(MathAbs(test-price)>2.0*tolerance && !extreme) continue;
         string reason="CONTADO";
         if(!extreme) reason="SIN_EXTREMO_O_RECHAZO_CALIFICADO";
         else if(MathAbs(test-price)>tolerance) reason="FUERA_DE_TOLERANCIA";
         else if(last_counted>=0 && i-last_counted<InpReactionMinSeparationM5Bars) reason="SEPARACION";
         else if(last_counted>=0 && !MovedAwayBetweenM5Reactions(rates,last_counted,i,kind,price,tolerance*InpReactionMinExcursionWidths)) reason="SIN_ALEJAMIENTO";
         else { last_counted=i; touches++; }
         Print("BCSO_EXPLAIN: ",EnumToString(kind)," | ",TimeToString(rates[i].time)," | extremo ",test," | ",reason);
        }
      Print("BCSO_EXPLAIN: ",EnumToString(kind)," | toques ",touches," | rol ",EnumToString(CurrentZoneRole(rates,price-tolerance,price+tolerance,kind)),
            " | visible ",MathAbs(price-iClose(_Symbol,PERIOD_M1,1))<=VisibleDistance()+tolerance);
     }
  }

struct CachedZones
  {
   string key;
   double centers[];
   int touches[];
   double tolerance;
   int count;
  };
CachedZones g_zone_cache[];
void InitCachedZones(CachedZones &cache)
  {
   cache.key=""; ArrayResize(cache.centers,0); ArrayResize(cache.touches,0);
   cache.tolerance=0.0; cache.count=0;
  }
datetime g_zone_cache_bar=0;

int CollectQualifiedZonesAtDistance(const ENUM_TIMEFRAMES tf,const ZoneKind kind,const int bars,
                                   double &centers[],int &touches[],double &tolerance,
                                   const bool reactions,const double distance)
  {
   datetime bar=iTime(_Symbol,PERIOD_M1,0);
   if(bar!=g_zone_cache_bar) { ArrayResize(g_zone_cache,0); g_zone_cache_bar=bar; }
   string key=RulePackText()+"|"+EnumToString(tf)+"|"+EnumToString(kind)+"|"+IntegerToString(bars)+"|"+
              IntegerToString((int)reactions)+"|"+DoubleToString(distance,16);
   for(int i=0;i<ArraySize(g_zone_cache);i++)
      if(g_zone_cache[i].key==key)
        {
         ArrayCopy(centers,g_zone_cache[i].centers); ArrayCopy(touches,g_zone_cache[i].touches);
         int count=g_zone_cache[i].count;
         ArrayResize(centers,count); ArrayResize(touches,count);
         if(InpDebugZoneCache && (ArraySize(centers)!=count || ArraySize(touches)!=count)) Print("ZONE_CACHE: tamaño incorrecto tras copia");
         tolerance=g_zone_cache[i].tolerance; return g_zone_cache[i].count;
        }
   int count=CollectQualifiedZonesRaw(tf,kind,bars,centers,touches,tolerance,reactions,distance);
   if(count>=0)
     {
      int n=ArraySize(g_zone_cache);
      if(ArrayResize(g_zone_cache,n+1)==n+1)
        {
         InitCachedZones(g_zone_cache[n]);
         g_zone_cache[n].key=key; g_zone_cache[n].count=count; g_zone_cache[n].tolerance=tolerance;
         ArrayCopy(g_zone_cache[n].centers,centers); ArrayCopy(g_zone_cache[n].touches,touches);
         ArrayResize(g_zone_cache[n].centers,count); ArrayResize(g_zone_cache[n].touches,count);
         ArrayResize(centers,count); ArrayResize(touches,count);
         if(InpDebugZoneCache && (ArraySize(g_zone_cache[n].centers)!=count || ArraySize(g_zone_cache[n].touches)!=count || ArraySize(centers)!=count || ArraySize(touches)!=count)) Print("ZONE_CACHE: tamaño incorrecto tras copia");
        }
     }
   return count;
  }
#endif
