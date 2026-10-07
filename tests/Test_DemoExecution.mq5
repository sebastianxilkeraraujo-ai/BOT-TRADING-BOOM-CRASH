// This script CANNOT send orders: OrderSend is substituted in the entire EA.
int mock_sends=0;
bool MockOrderSend(const MqlTradeRequest &req,MqlTradeResult &result)
  { mock_sends++; result.retcode=TRADE_RETCODE_REJECT; return false; }
long mock_mode=ACCOUNT_TRADE_MODE_DEMO;
long TestAccountInfoInteger(const ENUM_ACCOUNT_INFO_INTEGER property)
  {
   if(property==ACCOUNT_TRADE_MODE) return mock_mode;
   return AccountInfoInteger(property);
  }
#define OrderSend MockOrderSend
#define AccountInfoInteger TestAccountInfoInteger
#define input
#define OnInit ObserverInit
#define OnDeinit ObserverDeinit
#define OnTick ObserverTick
#include "../XLK BOT.mq5"
#undef OnInit
#undef OnDeinit
#undef OnTick
#undef input
#undef AccountInfoInteger
#undef OrderSend

int checks=0,failures=0;
void AssertDemo(const bool ok,const string label)
  {
   checks++; if(!ok) failures++;
   Print("TEST_DEMO_EXEC ",ok ? "PASS " : "FAIL ",label);
  }
void OnStart()
  {
   AssertDemo(!InpDemoExecution,"ejecución desactivada por defecto");
   Zone zone=MakeZone(PERIOD_M5,ZONE_SUPPORT,100.0,1.0,2);
   DemoExecuteConfirmed("unit-disabled","BUY",zone,TimeCurrent()-60,99.0,110.0);
   AssertDemo(mock_sends==0,"modo observador no invoca envío");
   ExecGuardState guard=VariantsGuardDefaults(); guard.demo=false;
   AssertDemo(ExecGuardDecision(guard)=="CUENTA_NO_DEMO","cuenta real rechazada por guardia pura");
   AssertDemo(ExecRiskAllowed(1.0,1.0,1.5,0.0,10.0,false),"mínimo 1 USD aceptado");
   AssertDemo(ExecRiskAllowed(1.5,1.0,1.5,-8.5,10.0,false),"presupuesto exacto 10 USD");
   AssertDemo(!ExecRiskAllowed(1.5,1.0,1.5,-8.6,10.0,false),"reserva excedería presupuesto diario");
   AssertDemo(!ExecRiskAllowed(1.51,1.0,1.5,0.0,10.0,false),"riesgo sobre máximo rechazado");
   AssertDemo(!ExecRiskAllowed(0.99,1.0,1.5,0.0,10.0,false),"riesgo bajo mínimo rechazado");
   AssertDemo(!ExecRiskAllowed(1.1,1.0,1.5,2.0,10.0,true),"límite alcanzado sigue bloqueado tras recuperación");
   AssertDemo(!ExecRiskAllowed(1.5,1.0,1.5,0.0,11.0,false),"límite configurado mayor a 10 rechazado");
   datetime bar=1000;
   AssertDemo(ExecFresh(1060999,1060000,bar),"primer tick tras cierre permitido");
   AssertDemo(!ExecFresh(1060000,1059999,bar),"vela abierta rechazada");
   AssertDemo(!ExecFresh(1120999,1120000,bar),"señal de hace otra vela rechazada");
   AssertDemo(!ExecFresh(1066000,1060000,bar),"cotización atrasada rechazada");
   AssertDemo(MathAbs(ExecGridPrice(99.97,0.05,2,false)-99.95)<1e-8,"SL compra a rejilla inferior");
   AssertDemo(MathAbs(ExecGridPrice(100.03,0.05,2,true)-100.05)<1e-8,"SL venta a rejilla superior");
   AssertDemo(ExecStopsValid(true,100.0,100.2,99.0,103.0,0.5),"compra con SL TP válidos");
   AssertDemo(ExecStopsValid(false,100.0,100.2,101.0,97.0,0.5),"venta con SL TP válidos");
   AssertDemo(!ExecStopsValid(true,100.0,100.2,100.1,103.0,0.0),"SL compra dentro de spread rechazado");
   AssertDemo(!ExecStopsValid(false,100.0,100.2,100.4,97.0,0.5),"stops level venta respetado");
   AssertDemo(!ExecStopsValid(true,100.0,100.2,0.0,103.0,0.0),"orden sin SL rechazada");
   AssertDemo(ExecCheckPassed(true,0),"OrderCheck éxito retcode 0");
   AssertDemo(!ExecCheckPassed(false,0),"OrderCheck fallido bloquea aunque retcode cero");
   AssertDemo(!ExecCheckPassed(true,TRADE_RETCODE_NO_MONEY),"margen insuficiente bloquea");
   AssertDemo(!ExecDefiniteReject(TRADE_RETCODE_TIMEOUT),"timeout conserva bloqueo sin reintento");
   AssertDemo(!ExecDefiniteReject(TRADE_RETCODE_PLACED),"aceptada no equivale a deal confirmado");
   AssertDemo(ExecDefiniteReject(TRADE_RETCODE_INVALID_STOPS),"rechazo definitivo reconocido");
   AssertDemo(mock_sends==0,"cero intentos de envío en la prueba");
   Print("TEST_DEMO_EXEC SUMMARY checks=",checks," failures=",failures," mock_sends=",mock_sends);
  }
