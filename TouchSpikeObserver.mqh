#ifndef BCSO_TOUCH_SPIKE_OBSERVER
#define BCSO_TOUCH_SPIKE_OBSERVER

// Medición independiente: ninguna fila autoriza una entrada ni contiene P/L.
input bool InpMeasureTouchSpikes=true;
input int InpTouchSpikeWindowMinutes=15; // inicial, configurable; no calibrado
input double InpTouchSpikeRearmWidths=0.5;
input int InpTouchBandRetentionHours=24;

struct TouchSpikeEpisode
  {
   bool active,resolved;
   string id,key,result,detail,pack,origin_session;
   Zone zone;
   long touch_msc,deadline_msc,last_tick_msc;
   datetime last_closed_bar;
   double bid,ask,mfe,mae,margin;
   int hour,weekday,window;
   bool broken;
   MqlRates spike;
   double baseline;
  };
struct TouchSpikeBand
  {
   Zone zone;
   string key;
   bool armed,current;
   datetime last_seen;
  };
void InitTouchSpikeEpisode(TouchSpikeEpisode &e)
  {
   e.active=false; e.resolved=false; e.id=""; e.key=""; e.result=""; e.detail=""; e.pack="";
   e.origin_session="";
   InitZone(e.zone); e.touch_msc=0; e.deadline_msc=0; e.last_tick_msc=0; e.last_closed_bar=0;
   e.bid=0.0; e.ask=0.0; e.mfe=0.0; e.mae=0.0; e.margin=0.0;
   e.hour=0; e.weekday=0; e.window=0; e.broken=false;
   ZeroMemory(e.spike); // MqlRates no contiene strings.
   e.baseline=0.0;
  }
void InitTouchSpikeBand(TouchSpikeBand &b)
  {
   InitZone(b.zone); b.key=""; b.armed=false; b.current=false; b.last_seen=0;
  }
enum TouchWriteStatus { WRITTEN, ALREADY_SAME, CONFLICT, FAILED };
TouchSpikeEpisode g_touch_spikes[];
TouchSpikeBand g_touch_bands[];
string g_touch_spike_file;
bool g_touch_spike_ready=false;
ulong g_touch_written[]; // hashes ordenados; toda coincidencia se verifica contra el CSV
datetime g_touch_spike_cache_bar=0,g_touch_spike_checked_bar=0;

string TouchSpikeHeader()
  {
   return "event_id;event_type;symbol;build_version;schema_version;zone_key;zone_tf;zone_kind;zone_lower;zone_upper;zone_reactions;touch_time_server;touch_time_msc;touch_bid;touch_ask;hour_server;weekday;window_minutes;deadline_msc;result;spike_bar_time_server;spike_known_at_server;spike_direction;spike_range;spike_baseline_median;spike_ratio;seconds_touch_to_spike_close;same_bar_touch;zone_broken_m5;mfe_price;mae_price;detail;rule_pack;break_margin;detector_multiple;detector_previous_bars;writer_program;writer_chart;writer_period;writer_build;writer_session";
  }

// Una fila TOUCH abre el episodio; RESULT lo cierra con el mismo ID.
// Primero se verifica el libro para que un reintento nunca duplique la fila.
ulong TouchWrittenHash(const string key)
  {
   ulong hash=14695981039346656037;
   for(int i=0;i<StringLen(key);i++) { hash^=(ulong)StringGetCharacter(key,i); hash*=1099511628211; }
   return hash;
  }

int TouchWrittenIndex(const ulong hash)
  {
   return ArraySize(g_touch_written)>0 ? ArrayBsearch(g_touch_written,hash) : -1;
  }

void RememberTouchWritten(const string key)
  {
   ulong hash=TouchWrittenHash(key);
   int n=ArraySize(g_touch_written),at=TouchWrittenIndex(hash);
   if(at>=0 && g_touch_written[at]==hash) return;
   if(at<0) at=0; else if(g_touch_written[at]<hash) at++;
   if(ArrayResize(g_touch_written,n+1)!=n+1) { g_touch_spike_ready=false; return; }
   for(int i=n;i>at;i--) g_touch_written[i]=g_touch_written[i-1];
   g_touch_written[at]=hash;
  }

bool ValidTouchResult(const string result)
  {
   return result=="SPIKE_REACTION" || result=="SPIKE_AFTER_BREAK" || result=="SPIKE_NOT_FAVORABLE" ||
          result=="SPIKE_SAME_BAR_UNCERTAIN" || result=="NO_SPIKE" || result=="BROKE_NO_SPIKE" || result=="DATA_GAP";
  }

TouchWriteStatus WriteTouchSpike(TouchSpikeEpisode &event,const string type)
  {
   // No debe llegar un cierre sin clasificación. Si una ruta futura/degradada
   // deja el estado vacío, conservar el episodio como censurado en vez de
   // escribir un RESULT indistinguible de un fallo del CSV.
   string outcome=(type=="TOUCH" ? "PENDING" : event.result);
   string detail=event.detail;
   if(type=="RESULT" && !ValidTouchResult(outcome))
     {
      detail="RESULT_INVALIDO:"+(StringLen(outcome)>0 ? outcome : "");
      outcome="DATA_GAP";
      event.result=outcome; event.detail=detail; event.resolved=true;
      Print(detail," | ",event.id);
     }
   string key=event.id+"|"+type;
   ulong hash=TouchWrittenHash(key);
   int at=TouchWrittenIndex(hash);
   bool known=at>=0 && g_touch_written[at]==hash;
   int handle=OpenCsvRetry(g_touch_spike_file,FILE_TXT|FILE_READ|FILE_WRITE|FILE_ANSI|FILE_COMMON,';',CP_UTF8);
   if(handle==INVALID_HANDLE) return FAILED;
   bool empty=FileSize(handle)==0;
   string values[]; ArrayResize(values,41);
   for(int i=0;i<ArraySize(values);i++) values[i]="";
   values[0]=event.id; values[1]=type; values[2]=_Symbol;
   values[3]=OBSERVER_BUILD_TAG; values[4]="touch_spike.2";
   values[5]=event.key; values[6]=EnumToString(event.zone.timeframe); values[7]=EnumToString(event.zone.kind);
   values[8]=DoubleToString(event.zone.lower,_Digits); values[9]=DoubleToString(event.zone.upper,_Digits);
   values[10]=IntegerToString(event.zone.touches);
   values[11]=TimeToString((datetime)(event.touch_msc/1000),TIME_DATE|TIME_SECONDS);
   values[12]=IntegerToString(event.touch_msc); values[13]=DoubleToString(event.bid,_Digits); values[14]=DoubleToString(event.ask,_Digits);
   values[15]=IntegerToString(event.hour); values[16]=IntegerToString(event.weekday);
   values[17]=IntegerToString(event.window); values[18]=IntegerToString(event.deadline_msc);
   values[19]=outcome;
   if(type=="RESULT" && event.spike.time>0)
     {
      values[20]=TimeToString(event.spike.time,TIME_DATE|TIME_SECONDS);
      values[21]=TimeToString(event.spike.time+60,TIME_DATE|TIME_SECONDS);
      values[22]=event.spike.close>event.spike.open ? "UP" : (event.spike.close<event.spike.open ? "DOWN" : "FLAT");
      values[23]=DoubleToString(event.spike.high-event.spike.low,_Digits);
      values[24]=DoubleToString(event.baseline,_Digits);
      values[25]=event.baseline>0.0 ? DoubleToString((event.spike.high-event.spike.low)/event.baseline,5) : "";
      values[26]=DoubleToString(((long)(event.spike.time+60)*1000-event.touch_msc)/1000.0,3);
      values[27]=(long)event.spike.time*1000<event.touch_msc ? "1" : "0";
     }
   values[28]=event.broken ? "1" : "0";
   // Un hueco no produce excursiones supuestamente completas.
   values[29]=outcome=="DATA_GAP" ? "" : DoubleToString(event.mfe,_Digits);
   values[30]=outcome=="DATA_GAP" ? "" : DoubleToString(event.mae,_Digits);
   values[31]=detail; values[32]=event.pack;
   values[33]=DoubleToString(event.margin,_Digits);
   values[34]=DoubleToString(InpSpikeM1RangeMultiple,5); values[35]=IntegerToString(InpSpikeMedianBars);
   FillWriterFields(values,36);
   string row[];
   if(!empty)
     {
      string expected[]; StringSplit(TouchSpikeHeader(),';',expected);
      if(!ReadCsvRow(handle,row) || ArraySize(row)!=ArraySize(expected)) { FileClose(handle); Print("TOUCH_SPIKE: esquema incompatible"); return FAILED; }
      for(int j=0;j<ArraySize(row);j++) if(row[j]!=expected[j]) { FileClose(handle); Print("TOUCH_SPIKE: esquema incompatible"); return FAILED; }
     }
   if(known)
     {
      bool same=false;
      while(ReadCsvRow(handle,row))
        {
         if(ArraySize(row)<2 || row[0]!=event.id || row[1]!=type) continue;
         bool equal=ArraySize(row)==ArraySize(values);
         if(equal) for(int j=0;j<ArraySize(values);j++) if(row[j]!=values[j]) { equal=false; break; }
         if(!equal) { FileClose(handle); Print("RESULT_CONFLICTO: ",key); return CONFLICT; }
         same=true;
        }
      if(same) { FileClose(handle); return ALREADY_SAME; }
     }
   FileSeek(handle,0,SEEK_END);
   bool ok=(!empty || FileWriteString(handle,TouchSpikeHeader()+"\r\n")>0) && FileWriteString(handle,CsvLine(values))>0;
   FileFlush(handle); FileClose(handle);
   if(ok) RememberTouchWritten(key);
   return ok ? WRITTEN : FAILED;
  }

string ClassifyTouchSpike(const TouchSpikeEpisode &event,const MqlRates &spike)
  {
   // Una vela que ya había empezado al tocar puede haber hecho su spike ANTES.
   if((long)spike.time*1000<event.touch_msc) return "SPIKE_SAME_BAR_UNCERTAIN";
   bool favorable=event.zone.kind==ZONE_SUPPORT ?
      spike.close>spike.open && spike.close>event.bid : spike.close<spike.open && spike.close<event.bid;
   if(favorable) return event.broken ? "SPIKE_AFTER_BREAK" : "SPIKE_REACTION";
   return "SPIKE_NOT_FAVORABLE";
  }

int TouchSpikeSlot()
  {
   for(int i=0;i<ArraySize(g_touch_spikes);i++) if(!g_touch_spikes[i].active) { InitTouchSpikeEpisode(g_touch_spikes[i]); return i; }
   int n=ArraySize(g_touch_spikes);
   if(ArrayResize(g_touch_spikes,n+100)!=n+100) return -1;
   for(int i=n;i<n+100;i++) InitTouchSpikeEpisode(g_touch_spikes[i]);
   return n;
  }

bool StartTouchSpike(const TouchSpikeBand &band,const MqlTick &quote)
  {
   // El rearme exige salir de la banda; una reentrada es otro toque, aunque
   // el episodio anterior aún esté pendiente. Comparten clave, no son independientes.
   int slot=TouchSpikeSlot(); if(slot<0) return false;
   TouchSpikeEpisode event; InitTouchSpikeEpisode(event);
   event.active=true; event.zone=band.zone; event.key=band.key; event.pack=RulePackText();
   event.origin_session=g_writer_session;
   event.touch_msc=quote.time_msc; event.last_tick_msc=quote.time_msc;
   event.window=InpTouchSpikeWindowMinutes; event.deadline_msc=quote.time_msc+(long)event.window*60000;
   event.bid=quote.bid; event.ask=quote.ask;
   event.margin=BreakMargin();
   event.id=_Symbol+"_TOUCH_"+band.key+"_"+IntegerToString(quote.time_msc);
   event.last_closed_bar=(datetime)(quote.time_msc/60000*60-60);
   MqlDateTime calendar; TimeToStruct((datetime)(quote.time_msc/1000),calendar);
   event.hour=calendar.hour; event.weekday=calendar.day_of_week;
   event.detail="Primer tick observado dentro de banda M5; no implica orden; precio BID";
   TouchWriteStatus written=WriteTouchSpike(event,"TOUCH");
   if(written==FAILED || written==CONFLICT) return false;
   g_touch_spikes[slot]=event;
   if(written==WRITTEN) Print("TOQUE M5 REGISTRADO: ",EnumToString(band.zone.kind)," | ",event.id," | solo medición");
   return true;
  }

void RefreshTouchSpikeBands()
  {
   datetime bar=iTime(_Symbol,PERIOD_M1,0);
   if(bar<=0 || bar==g_touch_spike_cache_bar) return;
   static datetime limit_notice=0;
   for(int i=ArraySize(g_touch_bands)-1;i>=0;i--)
     {
      if(g_touch_bands[i].current || bar-g_touch_bands[i].last_seen<=(long)InpTouchBandRetentionHours*3600) continue;
      bool active=false;
      for(int j=0;j<ArraySize(g_touch_spikes);j++) if(g_touch_spikes[j].active && g_touch_spikes[j].key==g_touch_bands[i].key) { active=true; break; }
      if(!active) { int n=ArraySize(g_touch_bands); for(int j=i;j<n-1;j++) g_touch_bands[j]=g_touch_bands[j+1]; ArrayResize(g_touch_bands,n-1); }
     }
   for(int i=0;i<ArraySize(g_touch_bands);i++) g_touch_bands[i].current=false;
   for(int kind=0;kind<2;kind++)
     {
      double centers[],tolerance=0.0; int touches[];
      int count=CollectQualifiedZones(PERIOD_M5,(ZoneKind)kind,InpScanBarsM5,centers,touches,tolerance,true);
      if(count<0) return; // no se marca caché completa si falta historial
      for(int j=0;j<count;j++)
        {
         Zone zone=MakeZone(PERIOD_M5,(ZoneKind)kind,centers[j],tolerance,touches[j]);
         int found=-1; double nearest=DBL_MAX;
         for(int i=0;i<ArraySize(g_touch_bands);i++)
            if(g_touch_bands[i].zone.kind==zone.kind && !g_touch_bands[i].current && !IsAdditionalLevelKey(g_touch_bands[i].key))
              {
               double distance=MathAbs(g_touch_bands[i].zone.center-zone.center);
               if(distance<=MathMin(tolerance,(g_touch_bands[i].zone.upper-g_touch_bands[i].zone.lower)/2.0) && distance<nearest)
                 { nearest=distance; found=i; }
              }
         if(found<0)
           {
            found=ArraySize(g_touch_bands);
            if(found>=2048 || ArrayResize(g_touch_bands,found+1)!=found+1) { if(limit_notice!=bar) { Print("TOUCH_SPIKE: límite de bandas; observación incompleta"); limit_notice=bar; } continue; }
            InitTouchSpikeBand(g_touch_bands[found]);
            g_touch_bands[found].armed=true;
            g_touch_bands[found].key=EnumToString(zone.kind)+"_"+IntegerToString((long)MathFloor(zone.center/MathMax(_Point,2*tolerance)));
           }
         g_touch_bands[found].zone=zone; g_touch_bands[found].current=true;
         g_touch_bands[found].last_seen=bar;
        }
     }
   AppendAdditionalTouchBands();
   g_touch_spike_cache_bar=bar;
  }

void ObserveTouchSpikes()
  {
   if(!InpMeasureTouchSpikes || !g_touch_spike_ready) return;
   MqlTick quote; if(!SymbolInfoTick(_Symbol,quote) || quote.bid<=0.0 || quote.ask<quote.bid || quote.time_msc<=0) return;
   datetime current=iTime(_Symbol,PERIOD_M1,0);
   bool new_bar=current>0 && current!=g_touch_spike_checked_bar;
   MqlRates rates[];
   bool loaded=!new_bar || LoadRates(PERIOD_M1,InpSpikeMedianBars+InpTouchSpikeWindowMinutes+3,rates);
   OperationsTouchLoadState(loaded,quote.time_msc);
   long replay_from=quote.time_msc;
   for(int i=0;i<ArraySize(g_touch_spikes);i++)
      if(g_touch_spikes[i].active && !g_touch_spikes[i].resolved && quote.time_msc-g_touch_spikes[i].last_tick_msc>2000)
         replay_from=MathMin(replay_from,g_touch_spikes[i].last_tick_msc+1);
   MqlTick recovered[];
   bool replay_ok=true;
   if(replay_from<quote.time_msc)
     {
      ResetLastError();
      int copied=OperationsCopyTicks(recovered,replay_from,quote.time_msc);
      replay_ok=copied>=0 && GetLastError()==0;
     }
   for(int i=0;i<ArraySize(g_touch_spikes);i++)
     {
      if(!g_touch_spikes[i].active) continue;
      if(!g_touch_spikes[i].resolved)
        {
         long gap=quote.time_msc-g_touch_spikes[i].last_tick_msc;
         if(OperationsTouchStall(g_touch_spikes[i],loaded,replay_ok,quote,recovered))
           { if(!g_touch_spikes[i].resolved) continue; }
         else {
         bool actual_gap=gap<0;
         long previous=g_touch_spikes[i].last_tick_msc;
         for(int k=0;k<ArraySize(recovered);k++)
           {
            if(recovered[k].time_msc<=g_touch_spikes[i].last_tick_msc) continue;
            if(recovered[k].time_msc>g_touch_spikes[i].deadline_msc) break;
            if(OperationsTickGap(previous,recovered[k].time_msc)) actual_gap=true;
            previous=recovered[k].time_msc;
            if(previous<=g_touch_spikes[i].deadline_msc && recovered[k].bid>0.0 && recovered[k].ask>=recovered[k].bid)
              {
               double move=g_touch_spikes[i].zone.kind==ZONE_SUPPORT ? recovered[k].bid-g_touch_spikes[i].bid : g_touch_spikes[i].bid-recovered[k].bid;
               g_touch_spikes[i].mfe=MathMax(g_touch_spikes[i].mfe,move); g_touch_spikes[i].mae=MathMax(g_touch_spikes[i].mae,-move);
              }
           }
         if(OperationsTickGap(previous,(long)MathMin(quote.time_msc,g_touch_spikes[i].deadline_msc))) actual_gap=true;
         if(actual_gap)
           { g_touch_spikes[i].resolved=true; g_touch_spikes[i].result="DATA_GAP"; g_touch_spikes[i].detail="Hueco de cotizaciones; no se presume éxito ni fracaso"; }
         else
           {
            if(quote.time_msc<=g_touch_spikes[i].deadline_msc)
              {
               double move=g_touch_spikes[i].zone.kind==ZONE_SUPPORT ? quote.bid-g_touch_spikes[i].bid : g_touch_spikes[i].bid-quote.bid;
               g_touch_spikes[i].mfe=MathMax(g_touch_spikes[i].mfe,move); g_touch_spikes[i].mae=MathMax(g_touch_spikes[i].mae,-move);
              }
            if(new_bar)
              {
               PendingSignal zone_probe; InitPendingSignal(zone_probe);
               zone_probe.entry_msc=g_touch_spikes[i].touch_msc;
               zone_probe.side=g_touch_spikes[i].zone.kind==ZONE_SUPPORT ? "BUY" : "SELL";
               zone_probe.zone_lower=g_touch_spikes[i].zone.lower; zone_probe.zone_upper=g_touch_spikes[i].zone.upper;
               zone_probe.break_margin=g_touch_spikes[i].margin;
               int broken=ZoneClosedBreak(zone_probe,MathMin(quote.time_msc,g_touch_spikes[i].deadline_msc));
               if(broken<0) { g_touch_spikes[i].resolved=true; g_touch_spikes[i].result="DATA_GAP"; g_touch_spikes[i].detail="Historial M5 insuficiente para comprobar ruptura"; }
               // La ruptura conocida ahora no debe contaminar retrospectivamente un spike anterior.
               for(int shift=ArraySize(rates)-InpSpikeMedianBars-1;shift>=1 && !g_touch_spikes[i].resolved;shift--)
                 {
                  long closed=(long)(rates[shift].time+60)*1000;
                  if(rates[shift].time<=g_touch_spikes[i].last_closed_bar || closed<=g_touch_spikes[i].touch_msc || closed>g_touch_spikes[i].deadline_msc || closed>quote.time_msc) continue;
                  g_touch_spikes[i].last_closed_bar=rates[shift].time;
                  if(IsSpikeM1(rates,shift))
                    {
                     int broke_at_spike=ZoneClosedBreak(zone_probe,closed);
                     if(broke_at_spike<0) { g_touch_spikes[i].resolved=true; g_touch_spikes[i].result="DATA_GAP"; g_touch_spikes[i].detail="Historial M5 insuficiente al cierre del spike"; break; }
                     g_touch_spikes[i].broken=broke_at_spike>0;
                     g_touch_spikes[i].spike=rates[shift]; g_touch_spikes[i].baseline=RangeMedian(rates,shift+1,InpSpikeMedianBars);
                     g_touch_spikes[i].result=ClassifyTouchSpike(g_touch_spikes[i],rates[shift]);
                     g_touch_spikes[i].resolved=true;
                     g_touch_spikes[i].detail="Primer spike M1 cerrado tras toque; asociación temporal, no causalidad";
                    }
                 }
               if(!g_touch_spikes[i].resolved) g_touch_spikes[i].broken=broken>0;
              }
            if(!g_touch_spikes[i].resolved && quote.time_msc>=g_touch_spikes[i].deadline_msc)
              { g_touch_spikes[i].resolved=true; g_touch_spikes[i].result=g_touch_spikes[i].broken ? "BROKE_NO_SPIKE" : "NO_SPIKE"; g_touch_spikes[i].detail="Ventana vencida; no hubo spike confirmado dentro de ella"; }
           }
         g_touch_spikes[i].last_tick_msc=quote.time_msc;
         }
        }
      if(g_touch_spikes[i].resolved)
        {
         TouchWriteStatus written=WriteTouchSpike(g_touch_spikes[i],"RESULT");
         if(written==WRITTEN) Print("TOQUE M5 RESULTADO: ",g_touch_spikes[i].result," | ",g_touch_spikes[i].id);
         if(written==WRITTEN || written==ALREADY_SAME) g_touch_spikes[i].active=false;
         if(written==CONFLICT) { g_touch_spike_ready=false; return; }
        }
     }
   if(loaded && new_bar && replay_ok) g_touch_spike_checked_bar=current;
   RefreshTouchSpikeBands();
   for(int i=0;i<ArraySize(g_touch_bands);i++)
     {
      if(!g_touch_bands[i].current) continue;
      double width=g_touch_bands[i].zone.upper-g_touch_bands[i].zone.lower;
      bool inside=quote.bid>=g_touch_bands[i].zone.lower && quote.bid<=g_touch_bands[i].zone.upper;
      if(!inside && (quote.bid<g_touch_bands[i].zone.lower-width*InpTouchSpikeRearmWidths || quote.bid>g_touch_bands[i].zone.upper+width*InpTouchSpikeRearmWidths)) g_touch_bands[i].armed=true;
      if(inside && g_touch_bands[i].armed && StartTouchSpike(g_touch_bands[i],quote)) g_touch_bands[i].armed=false;
     }
  }

bool InitializeTouchSpikes()
  {
   g_touch_spike_ready=false;
   ArrayResize(g_touch_written,0);
   ArrayResize(g_touch_spikes,0); ArrayResize(g_touch_bands,0);
   g_touch_spike_cache_bar=0; g_touch_spike_checked_bar=0;
   g_touch_spike_file=TaggedCsv("BCSO_"+SafeSymbolName()+"_touch_spikes_v1603.csv");
   if(!InpMeasureTouchSpikes) return true;
   if(InpTouchSpikeWindowMinutes<1 || InpTouchSpikeWindowMinutes>120 || InpTouchSpikeRearmWidths<0.0 || InpTouchBandRetentionHours<1) return false;
   // Se conservan los episodios previos. Un reinicio sin replay completo se censura
   // explícitamente; no se inventa NO_SPIKE durante un intervalo no observado.
   int handle=OpenCsvRetry(g_touch_spike_file,FILE_TXT|FILE_READ|FILE_WRITE|FILE_ANSI|FILE_COMMON,';',CP_UTF8);
   if(handle==INVALID_HANDLE) return false;
   bool empty=FileSize(handle)==0; string row[];
   while(ReadCsvRow(handle,row))
     {
      if(ArraySize(row)!=41) { FileClose(handle); Print("TOUCH_SPIKE: libro incompatible conservado"); return false; }
      if(row[0]=="event_id")
        {
         string expected[]; StringSplit(TouchSpikeHeader(),';',expected);
         for(int j=0;j<ArraySize(expected);j++) if(row[j]!=expected[j]) { FileClose(handle); Print("TOUCH_SPIKE: esquema incompatible"); return false; }
         continue;
        }
      RememberTouchWritten(row[0]+"|"+row[1]);
      int slot=-1;
      for(int i=0;i<ArraySize(g_touch_spikes);i++) if(g_touch_spikes[i].id==row[0]) { slot=i; break; }
      if(row[1]=="RESULT") { if(slot>=0) g_touch_spikes[slot].active=false; continue; }
      if(row[1]!="TOUCH" || row[2]!=_Symbol) continue;
      if(slot>=0) continue;
      slot=ArraySize(g_touch_spikes);
      if(ArrayResize(g_touch_spikes,slot+1)!=slot+1) { FileClose(handle); return false; }
      InitTouchSpikeEpisode(g_touch_spikes[slot]);
      g_touch_spikes[slot].active=true; g_touch_spikes[slot].id=row[0]; g_touch_spikes[slot].key=row[5];
      g_touch_spikes[slot].zone=MakeZone(PERIOD_M5,row[7]=="ZONE_SUPPORT" ? ZONE_SUPPORT : ZONE_RESISTANCE,
           (StringToDouble(row[8])+StringToDouble(row[9]))/2.0,(StringToDouble(row[9])-StringToDouble(row[8]))/2.0,(int)StringToInteger(row[10]));
      g_touch_spikes[slot].touch_msc=StringToInteger(row[12]); g_touch_spikes[slot].bid=StringToDouble(row[13]); g_touch_spikes[slot].ask=StringToDouble(row[14]);
      g_touch_spikes[slot].hour=(int)StringToInteger(row[15]); g_touch_spikes[slot].weekday=(int)StringToInteger(row[16]);
      g_touch_spikes[slot].window=(int)StringToInteger(row[17]); g_touch_spikes[slot].deadline_msc=StringToInteger(row[18]); g_touch_spikes[slot].pack=row[32];
      g_touch_spikes[slot].margin=StringToDouble(row[33]);
      g_touch_spikes[slot].origin_session=row[40];
      g_touch_spikes[slot].last_tick_msc=g_touch_spikes[slot].touch_msc;
      g_touch_spikes[slot].last_closed_bar=(datetime)(g_touch_spikes[slot].touch_msc/60000*60-60);
      if(g_touch_spikes[slot].origin_session!=g_writer_session)
        {
         g_touch_spikes[slot].resolved=true; g_touch_spikes[slot].result="DATA_GAP";
         g_touch_spikes[slot].detail="Reinicio: sesión "+g_touch_spikes[slot].origin_session+"→"+g_writer_session;
        }
     }
   if(empty) { FileSeek(handle,0,SEEK_END); if(FileWriteString(handle,TouchSpikeHeader()+"\r\n")==0) { FileClose(handle); return false; } }
   FileFlush(handle); FileClose(handle);
   for(int i=0;i<ArraySize(g_touch_spikes);i++)
      if(g_touch_spikes[i].active && g_touch_spikes[i].resolved)
        {
         TouchWriteStatus written=WriteTouchSpike(g_touch_spikes[i],"RESULT");
         if(written==WRITTEN) Print("TOQUE M5 RESULTADO: ",g_touch_spikes[i].result," | ",g_touch_spikes[i].id);
         if(written==WRITTEN || written==ALREADY_SAME) g_touch_spikes[i].active=false;
         if(written==CONFLICT) return false;
        }
   g_touch_spike_ready=true;
   return true;
  }
#endif
