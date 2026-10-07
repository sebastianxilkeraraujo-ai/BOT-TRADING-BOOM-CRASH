void LevelsSelfTest()
  {
   Check1604(!InpExecStructural,"levels nunca ejecuta por defecto");
   Check1604(OBSERVER_BUILD_VERSION=="1.604" && StringFind(OBSERVER_BUILD_TAG,"-levels")>=0,"tag levels sin cambio de version");
   Check1604(LevelRole(100,101)==ZONE_SUPPORT && LevelRole(100,99)==ZONE_RESISTANCE,"rol y cambio de rol");
   AdditionalLevel raw[],out[]; ArrayResize(raw,5);
   double prices[5]={100,101,110,130,105}; int priorities[5]={1,3,2,3,3};
   for(int i=0;i<5;i++)
     {
      raw[i].zone=MakeZone(PERIOD_M5,ZONE_SUPPORT,prices[i],1,0);
      raw[i].known_at=1000; raw[i].priority=priorities[i]; raw[i].manual=false;
      raw[i].source=i==0 ? "M5_SWING" : "CYCLE_LOW";
     }
   raw[4].known_at=2001;
   int count=SelectStructuralLevels(raw,ZONE_SUPPORT,120,2000,1,50,4,out);
   Check1604(count==2,"fusion y exclusion swing futuro");
   Check1604(count==2 && out[1].zone.center==101 && out[1].priority==3,"ciclo gana fusion sobre swing M5");
   count=SelectStructuralLevels(raw,ZONE_SUPPORT,120,2000,1,10,4,out);
   Check1604(count==1 && out[0].zone.center==110,"filtro distancia");
   count=SelectStructuralLevels(raw,ZONE_SUPPORT,120,2000,1,50,1,out);
   Check1604(count==1 && out[0].zone.center==110,"tope selecciona mas cercano");
   count=SelectStructuralLevels(raw,ZONE_RESISTANCE,120,2000,1,50,4,out);
   Check1604(count==1 && out[0].zone.center==130,"lados independientes");
   raw[1].priority=2;
   count=SelectStructuralLevels(raw,ZONE_SUPPORT,120,2000,1,50,4,out);
   Check1604(count==2 && out[1].priority==2,"M15 gana fusion sobre M5");
   Check1604(!ManualNameAllowed("BCSO_STRUCT_1") && ManualNameAllowed("mi soporte"),"excluye objetos BCSO");
   datetime active=ManualActiveFrom(1000,1010,60);
   Check1604(active==1070 && !ManualEligible(active,1050) && ManualEligible(active,1070),"creacion y retraso sin retrospectiva");
   active=ManualActiveFrom(1000,1200,60);
   Check1604(active==1260 && !ManualEligible(active,1259),"movimiento reinicia activacion");
   Check1604(ManualActiveFrom(1300,1200,60)==1360,"respeta creacion posterior");
   MqlRates m5[]; ArrayResize(m5,5); ArraySetAsSeries(m5,true);
   for(int i=0;i<5;i++) { m5[i].time=2000-i*300; m5[i].low=99; m5[i].high=101; m5[i].close=98; }
   AdditionalLevel level=raw[0]; level.known_at=1000;
   StructuralMetadata(level,m5,105);
   Check1604(level.flipped && level.touches_after==1 && level.age_bars==3,"metadatos: contactos consecutivos y flip");
   ArrayResize(g_struct_levels,1); g_struct_levels[0]=raw[0];
   g_struct_levels[0].key="STRUCT_M5_SWING_TEST";
   ArrayResize(g_manual_levels,1); g_manual_levels[0]=raw[1];
   g_manual_levels[0].key="MANUAL_TEST";
   ArrayResize(g_touch_bands,1); InitTouchSpikeBand(g_touch_bands[0]);
   g_touch_bands[0].key="ZONE_SUPPORT_EXISTING"; g_touch_bands[0].current=true;
   AppendAdditionalTouchBands(); AppendAdditionalTouchBands();
   Check1604(ArraySize(g_touch_bands)==3 && g_touch_bands[0].key=="ZONE_SUPPORT_EXISTING","bandas idempotentes conservan clase existente");
   Check1604(IsAdditionalLevelKey(g_touch_bands[1].key) && IsAdditionalLevelKey(g_touch_bands[2].key),"zone_key identifica ambas clases");
   ArrayResize(g_manual_levels,0); ArrayResize(g_struct_levels,0); ArrayResize(g_touch_bands,0);
  }
