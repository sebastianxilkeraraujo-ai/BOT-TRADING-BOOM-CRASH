// Único lugar donde se declaran los parámetros de ejecución y riesgo.
// "Bloqueo" impide enviar órdenes; "Avisos" solo genera alertas del monitor.
#ifndef BCSO_INPUTS_RISK
#define BCSO_INPUTS_RISK

BCSO_INPUT_GROUP("Ejecución (solo Demo USD)")
input bool   InpDemoExecution=false;
input bool   InpExecKillSwitch=false;
input ulong  InpExecMagic=160402;
input uint   InpExecutionDeviationPoints=10;
input double InpExecMaxLots=0.20;
input int    InpExecMaxOrderErrors=3;

BCSO_INPUT_GROUP("Riesgo — bloqueo")
input double InpPlanRiskMinUSD = 0.00;
input double InpPlanRiskMaxUSD = 2.00;      // riesgo máximo por operación
input double InpExecMaxDailyLossUSD=10.0;   // pérdida diaria por símbolo
input int    InpExecMaxTradesPerDay=12;
input int    InpExecMaxConsecutiveLosses=4;
input int    InpExecPauseMinutes=30;        // pausa al alcanzar InpExecMaxConsecutiveLosses
input int    InpLossPauseMinutes=20;        // pausa tras 2 SL seguidos

BCSO_INPUT_GROUP("Riesgo — avisos (no bloquean)")
input bool   InpEnableDisciplineMonitor=false;
input int    InpMaxOpenPositions=2;
input int    InpMaxTradesPerDay=8;
input int    InpMaxConsecutiveLosses=3;
input int    InpDisciplineCooldownMin=30;
input double InpMaxRiskPerTradeUSD=2.00;
input double InpMaxDailyLossUSD=0.0;        // 0 = desactivado

#endif
