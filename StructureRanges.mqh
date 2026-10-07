// Context only. Series arrays: index 0 is forming and is never inspected.
#ifndef BCSO_STRUCTURE_RANGES
#define BCSO_STRUCTURE_RANGES

struct StructureBounds
  {
   bool valid;
   datetime start_time;
   datetime end_time;
   datetime known_at;
   datetime high_time;
   datetime low_time;
   double high;
   double low;
  };

// Scale at the moment the candidate pivot could first be known. This avoids
// using the current bar's range to retroactively qualify an older swing.
double StructureRangeAt(const MqlRates &rates[],const int shift,const int lookback,const bool median=false)
  {
   if(shift<1 || lookback<1 || shift+lookback>=ArraySize(rates)) return 0.0;
   double total=0.0;
   double samples[];
   if(ArrayResize(samples,lookback)!=lookback) return 0.0;
   for(int i=shift;i<shift+lookback;i++)
     {
      samples[i-shift]=MathMax(rates[i].high-rates[i].low,
                    MathMax(MathAbs(rates[i].high-rates[i+1].close),
                            MathAbs(rates[i].low-rates[i+1].close)));
      total+=samples[i-shift];
     }
   if(median)
     {
      ArraySort(samples);
      int middle=lookback/2;
      return lookback%2==1 ? samples[middle] : (samples[middle-1]+samples[middle])/2.0;
     }
   return total/lookback;
  }

bool StructurePivot(const MqlRates &rates[],const int shift,const int strength,const bool high)
  {
   if(strength<1 || shift-strength<1 || shift+strength>=ArraySize(rates)) return false;
   for(int offset=1;offset<=strength;offset++)
     {
      if(high && (rates[shift].high<=rates[shift-offset].high ||
                  rates[shift].high<=rates[shift+offset].high)) return false;
      if(!high && (rates[shift].low>=rates[shift-offset].low ||
                   rates[shift].low>=rates[shift+offset].low)) return false;
     }
   return true;
  }

// Chronological swings. Same-side candidates can extend until the next
// opposite swing is confirmed. A bar that is both extremes has unknown OHLC
// order, so it cannot establish the next leg.
int StructureSwings(const MqlRates &rates[],const int strength,const int lookback,
                    const double minimum_ranges,const double tick_size,
                    int &indices[],int &kinds[],int &first_confirmed[],const bool median=false)
  {
   ArrayResize(indices,0);
   ArrayResize(kinds,0);
   ArrayResize(first_confirmed,0);
   int count=0;
   for(int shift=ArraySize(rates)-strength-1;shift>=strength+1;shift--)
     {
      bool high=StructurePivot(rates,shift,strength,true);
      bool low=StructurePivot(rates,shift,strength,false);
      if(high==low) continue;
      double scale=StructureRangeAt(rates,shift-strength,lookback,median);
      if(scale<=0.0) continue;
      int kind=high ? 1 : -1;
      double price=high ? rates[shift].high : rates[shift].low;
      if(count>0)
        {
         int last=indices[count-1];
         double previous=kinds[count-1]==1 ? rates[last].high : rates[last].low;
         if(kinds[count-1]==kind)
           {
            if((high && price>previous) || (low && price<previous)) indices[count-1]=shift;
            continue;
           }
         double leg=high ? price-previous : previous-price;
         if(leg<MathMax(tick_size,minimum_ranges*scale)) continue;
        }
      if(ArrayResize(indices,count+1)!=count+1 || ArrayResize(kinds,count+1)!=count+1 ||
         ArrayResize(first_confirmed,count+1)!=count+1) return -1;
      indices[count]=shift;
      kinds[count]=kind;
      first_confirmed[count]=shift-strength;
      count++;
     }
   return count;
  }

// Envelope includes every closed candle between endpoints, even a spike that
// could not itself qualify as a swing. The extremes are observed, not targets.
bool StructureEnvelope(const MqlRates &rates[],const int oldest,const int newest,
                       const datetime known_at,StructureBounds &bounds)
  {
   ZeroMemory(bounds);
   if(newest<1 || oldest<newest || oldest>=ArraySize(rates)) return false;
   bounds.start_time=rates[oldest].time;
   bounds.end_time=rates[newest].time;
   bounds.known_at=known_at;
   bounds.high=rates[oldest].high;
   bounds.low=rates[oldest].low;
   bounds.high_time=rates[oldest].time;
   bounds.low_time=rates[oldest].time;
   for(int i=oldest-1;i>=newest;i--)
     {
      if(rates[i].high>bounds.high) { bounds.high=rates[i].high; bounds.high_time=rates[i].time; }
      if(rates[i].low<bounds.low) { bounds.low=rates[i].low; bounds.low_time=rates[i].time; }
     }
   bounds.valid=bounds.high>bounds.low;
   return bounds.valid;
  }

bool DetectStructureBounds(const MqlRates &rates[],const int strength,const int lookback,
                           const double minimum_ranges,const double tick_size,const int seconds,
                           StructureBounds &completed,StructureBounds &developing,const bool median=false)
  {
   ZeroMemory(completed);
   ZeroMemory(developing);
   if(strength<1 || lookback<1 || seconds<=0 || minimum_ranges<=0.0 || tick_size<=0.0 ||
      ArraySize(rates)<2*strength+lookback+3) return false;
   int indices[],kinds[],first_confirmed[];
   int count=StructureSwings(rates,strength,lookback,minimum_ranges,tick_size,indices,kinds,first_confirmed,median);
   if(count<0) return false;
   // Four swings finalize the third endpoint: floor/ceiling/floor followed
   // by a confirmed upswing, or the inverse. Latest swing is still extendable.
   int anchor=ArraySize(rates)-lookback-1;
   if(count>0) anchor=indices[0];
   if(count>=2) anchor=indices[count-2];
   if(count>=4)
     {
      int first=indices[count-4],last=indices[count-2];
      int confirmation=first_confirmed[count-1];
      StructureEnvelope(rates,first,last,rates[confirmation].time+seconds,completed);
      anchor=last;
     }
   StructureEnvelope(rates,anchor,1,rates[1].time+seconds,developing);
   return developing.valid;
  }

// Diagnostic alternative only. Exclude a candle when its true range exceeds
// k times the PREVIOUS closed bars' median (the spike cannot dilute its own test).
bool StructureTrimmedEnvelope(const MqlRates &rates[],const StructureBounds &raw,
                              const int lookback,const double multiple,
                              StructureBounds &trimmed,int &spikes)
  {
   ZeroMemory(trimmed);
   spikes=0;
   if(!raw.valid) return false;
   for(int i=ArraySize(rates)-2;i>=1;i--)
     {
      if(rates[i].time<raw.start_time || rates[i].time>raw.end_time) continue;
      double baseline=StructureRangeAt(rates,i+1,lookback,true);
      if(baseline<=0.0) { ZeroMemory(trimmed); return false; }
      double tr=MathMax(rates[i].high-rates[i].low,
                       MathMax(MathAbs(rates[i].high-rates[i+1].close),MathAbs(rates[i].low-rates[i+1].close)));
      if(tr>multiple*baseline) { spikes++; continue; }
      if(!trimmed.valid)
        { trimmed=raw; trimmed.high=rates[i].high; trimmed.low=rates[i].low; }
      else
        { trimmed.high=MathMax(trimmed.high,rates[i].high); trimmed.low=MathMin(trimmed.low,rates[i].low); }
     }
   trimmed.valid=trimmed.valid && trimmed.high>trimmed.low;
   return trimmed.valid;
  }

#endif
