# 1.604-r2-demo — ejecución opcional

Estado: ejecutable y test compilados con 0 errores y 0 advertencias. El 4-oct-2026 a las 19:08 (hora del diario local), MT5 ejecutó `Test_DemoExecution`: 28 comprobaciones, 0 fallos, 0 envíos simulados. OrderSend está sustituido por un mock en ese test; no comprueba llenados del broker. El ejecutable se entrega con `InpDemoExecution=false`. No habilita el botón Trading algorítmico del terminal.

También se ejecutó `Test_1604` a las 19:10: 9 comprobaciones, 0 fallos, incluyendo N de compra/venta, volumen y exclusión de reacciones M5 aún desconocidas. Total: 37 comprobaciones aprobadas. Instalado el ejecutable en `MQL5/Experts/BCSO_1604_Demo`; verificada su igualdad SHA-256 con el compilado del proyecto. No se adjuntó a los gráficos ni se activó el envío de órdenes.

## Reglas y alcance

- Solo cuentas DEMO denominadas en USD; gráficos M1 de `Boom 1000 Index` y `Crash 1000 Index`.
- Compra Boom y venta Crash tras una señal nueva confirmada (rechazo M1 o patrón N) en una zona M5 con al menos dos reacciones previas. M15 se registra como contexto.
- Recalcula la cotización, distancia a la zona, SL, TP y volumen antes de enviar. Descarta precio alejado, señal caducada, lote incompatible, margen insuficiente y restricciones del broker.
- Riesgo planificado entre 1 y 1,5 USD. El volumen se calcula con `OrderCalcProfit`; SL/TP se incluyen en la solicitud inicial. La relación mínima beneficio/riesgo sigue siendo 1,20.
- Límite diario de 10 USD sobre resultado neto de operaciones de toda la cuenta, incluidas las manuales, según el día del servidor. Comprueba también que quede presupuesto para el SL propuesto. No permite nuevas entradas si ya se alcanzó el límite ese día.
- Una sola operación en la cuenta: cualquier posición abierta u orden pendiente, incluso manual, bloquea nuevas entradas. No cierra ni modifica esas posiciones.
- No hay martingala, promedios, reintentos automáticos ni entrada al instalar el EA: espera una señal futura. Una vela M1 admite como máximo un intento por símbolo, con persistencia tras reinicios.
- Un timeout o resultado incierto bloquea los siguientes envíos. Consultar el diario y el historial antes de resolver ese bloqueo; no borrar variables globales para forzar una repetición.

## Instalación y activación por el usuario

1. Copiar `XLK BOT.ex5` en una carpeta nueva bajo `MQL5/Experts` (por ejemplo `BCSO_1604_Demo`) y actualizar el Navegador de MT5.
2. Sustituir el EA anterior en los gráficos M1 de Boom y Crash; no colocar ambos programas simultáneamente en el mismo símbolo.
3. Revisar cuenta Demo USD y los inputs. Para activar, establecer `InpDemoExecution=true`, permitir trading algorítmico en las propiedades del EA y activar el botón correspondiente de MT5.
4. Conservar `InpUseM5ReactionStrategy=true`, `InpRulePack=RULES_1600`, `InpShadowLegacyRules=false`, riesgo 1–1,5 USD y límite diario 10 USD. La opción RULES_1600 es el selector heredado; las reglas nuevas están identificadas como 1.604.
5. Revisar `DEMO_EXEC` en Expertos y el CSV `BCSO_<símbolo>_execution_v1604_R1604.csv`. `ACEPTADA_ESPERANDO_DEAL` no confirma una operación; `DEAL_ENTRADA_CONFIRMADO` sí registra un deal recibido del servidor.

Los CSV anteriores se conservan. El sufijo R1604 separa los registros de esta candidata.

El importe al SL es teórico: comisiones y saltos de precio pueden superar el planificado y el límite diario. El límite diario impide nuevas entradas; no liquida operaciones. Las pruebas de código no demuestran rentabilidad ni sustituyen una prueba de ejecución Demo.

## Referencias de implementación

- [OrderCheck: resultado exitoso con retcode 0](https://www.mql5.com/en/docs/trading/ordercheck).
- [OrderSend: aceptación y ejecución son estados distintos](https://www.mql5.com/en/docs/trading/ordersend).
- [Propiedades del símbolo y políticas FOK/IOC](https://www.mql5.com/en/docs/constants/environment_state/marketinfoconstants).
