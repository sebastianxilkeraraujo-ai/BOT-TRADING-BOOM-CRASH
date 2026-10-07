#define BCSO_VARIANTS_TEST
#define input
#define OnInit ObserverInit
#define OnDeinit ObserverDeinit
#define OnTick ObserverTick
#include "../XLK BOT.mq5"
#undef OnInit
#undef OnDeinit
#undef OnTick
#undef input

int test_checks=0,test_failures=0;
void Check1604(const bool passed,const string label)
  {
   test_checks++;
   if(!passed) test_failures++;
   Print("TEST1604 ",passed ? "PASS " : "FAIL ",label);
  }

#include "LevelsTests.mqh"
void OnStart()
  {
   TakeProfitRulesSelfTest();
   Check1604(OBSERVER_RULE_VERSION=="1.604" && OBSERVER_BUILD_VERSION=="1.604",
             "versión y reglas aisladas");
   Check1604(MathAbs(StrategyVolumeGrid(4.0,0.1,0.1,1.0,1.0,1.5)-0.3)<1e-8,
             "volumen cuantizado deja riesgo en 1-1.5 USD");
   Check1604(StrategyVolumeGrid(10.0,0.2,0.1,1.0,1.0,1.5)==0.0,
             "mínimo del símbolo excede 1.5 USD");
   Check1604(StrategyVolumeGrid(1.0,0.1,0.1,0.5,1.0,1.5)==0.0,
             "ningún volumen llega a 1 USD");
   Check1604(MathAbs(StrategyVolumeGrid(3.9,0.2,0.01,0.2,0.0,2.0)-0.2)<1e-8,
             "riesgo 0.78 USD permitido sin mínimo con tope 0.20 lotes");
   Check1604(MathAbs(StrategyVolumeGrid(4.0,0.1,0.1,1.0,0.0,2.00)-0.5)<1e-8,
             "lote se reduce para limitar riesgo a 2.00 USD");
   Check1604(StrategyVolumeGrid(10.01,0.2,0.01,1.0,0.0,2.0)==0.0,
             "mínimo de lote supera 2 USD: bloqueado");
   Check1604(StrategyVolumeGrid(4.0,0.1,0.1,1.0,0.0,0.0)==0.0,
             "máximo de riesgo cero inválido");
   Check1604(ExecRiskAllowed(0.91,0.0,2.00,0.0,10.0,false),
             "riesgo de 0.91 USD permitido bajo tope de 2.00 USD");
   Check1604(!ExecRiskAllowed(2.01,0.0,2.00,0.0,10.0,false),
             "riesgo superior a 2.00 USD bloqueado");
   Check1604(!ExecRiskAllowed(2.00,0.0,2.00,-9.2,10.0,false),
             "pérdida diaria más riesgo excedente bloquean la operación");
   int losses=0; datetime until=0;
   ExecLossPauseDecision(0,-1.0,true,1000,20,losses,until);
   Check1604(losses==1 && until==0,"primer stop deja contador en uno");
   ExecLossPauseDecision(losses,-1.0,true,1060,20,losses,until);
   Check1604(losses==0 && until==2260,"segundo stop pausa veinte minutos");
   ExecLossPauseDecision(1,0.10,false,1100,20,losses,until);
   Check1604(losses==0 && until==0,"cierre no negativo reinicia racha");
   Check1604(StrategyM15DirectionAllowed("Boom 1000 Index","BUY",TREND_UP),
             "Boom permite compra solo con M15 alcista");
   Check1604(!StrategyM15DirectionAllowed("Boom 1000 Index","BUY",TREND_DOWN) &&
             !StrategyM15DirectionAllowed("Boom 1000 Index","BUY",TREND_NONE),
             "Boom bloquea M15 bajista o indeterminado");
   Check1604(StrategyM15DirectionAllowed("Crash 1000 Index","SELL",TREND_DOWN),
             "Crash permite venta solo con M15 bajista");
   Check1604(!StrategyM15DirectionAllowed("Crash 1000 Index","SELL",TREND_UP) &&
             !StrategyM15DirectionAllowed("Crash 1000 Index","SELL",TREND_NONE),
             "Crash bloquea M15 alcista o indeterminado");
   Zone support=MakeZone(PERIOD_M5,ZONE_SUPPORT,100.0,1.0,2);
   MqlRates bars[]; ArrayResize(bars,12); ArraySetAsSeries(bars,true);
   for(int i=0;i<12;i++) { bars[i].open=100.0; bars[i].close=100.0; }
   bars[1].open=100.0; bars[1].close=102.0;
   bars[2].close=100.0; bars[3].close=101.0;
   bars[4].close=102.0; bars[5].close=103.0;
   bars[6].open=98.0; bars[6].close=105.0;
   Check1604(StrategyPatternN(support,bars,"BUY"),"N con impulso y retroceso confirmados");
   bars[6].open=104.0;
   Check1604(!StrategyPatternN(support,bars,"BUY"),"sin impulso no hay N");
   bars[6].open=98.0;
   for(int i=0;i<12;i++) { bars[i].open=200.0-bars[i].open; bars[i].close=200.0-bars[i].close; }
   Zone resistance=MakeZone(PERIOD_M5,ZONE_RESISTANCE,100.0,1.0,2);
   Check1604(StrategyPatternN(resistance,bars,"SELL"),"N Crash simétrico confirmado");
   MqlRates history[]; ArrayResize(history,10); ArraySetAsSeries(history,true);
   for(int i=0;i<10;i++)
     {
      history[i].time=(datetime)(10000-i*300);
      history[i].open=122.0; history[i].close=123.0; history[i].low=120.0; history[i].high=125.0;
     }
   history[2].low=100.0; history[2].open=102.0; history[2].close=104.0; history[2].high=104.0;
   history[5].low=100.0; history[5].open=102.0; history[5].close=104.0; history[5].high=104.0;
   Check1604(StrategyPriorReactions(support,(datetime)10000,history)==2,"dos reacciones M5 ya cerradas");
   Check1604(StrategyPriorReactions(support,(datetime)9400,history)==1,"excluye reacción aún desconocida en el gatillo");
   VariantsSelfTest();
   LevelsSelfTest();
   ManualExecSelfTest();
   Print("TEST1604 SUMMARY checks=",test_checks," failures=",test_failures);
  }
