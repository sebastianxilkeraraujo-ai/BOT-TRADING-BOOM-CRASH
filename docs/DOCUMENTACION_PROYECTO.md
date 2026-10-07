# BCSO "XLK BOT" 1.604 (antes "Bot señal 1.6") — Inventario y mapa del proyecto

Fecha del análisis: 2026-10-07 · Alcance: carpeta `MQL5/Experts/BCSO_1604_RISK2_PAUSE/v1.6 f4/v1604` (repositorio git) y `Common/Files` (salidas CSV).
Estado de este documento: **fase 1 (inventario y diagnóstico estructural)**. Se leyeron por completo el encabezado, `OnInit`, `OnTick`, `EvaluatePackSignals` y los puntos de ejecución de órdenes; el resto se mapeó por estructura (funciones, inputs, globales, llamadas). La lectura línea por línea de cada función es la fase 2.

## 1. Qué es

Un Expert Advisor de MT5 (MQL5) para **Boom 1000 Index** y **Crash 1000 Index** (gráfico M1, cuenta DEMO USD). Es sobre todo un **observador/instrumento de medición**: detecta zonas de soporte/resistencia en M5/M15, busca rechazos o patrones (N) en M1, registra señales y su resultado (MFE/MAE, acierto/fallo) en CSV, y de forma **opcional** ejecuta órdenes reales en demo.

Hipótesis de estrategia vigente (`InpUseM5ReactionStrategy=true`): gatillo M1, zona M5 con ≥2 reacciones previas, M15 solo como contexto. Compra en Boom / venta en Crash.

## 2. Mapa de archivos

Tamaño total del código: **~6 800 líneas, 296 funciones, ~165 `input`, ~210 variables globales**.

Organización por capas (desde 2026-10-07). Cada carpeta de `src/` tiene un archivo de capa (`Config.mqh`, `Market.mqh`, …) que incluye sus módulos; el EA incluye `Config` al inicio y las demás capas en un único punto (tras sus globales). En MQL5 el orden de las **funciones** no importa; solo deben declararse antes de usarse los tipos, `input`, globales y `#define`.

| Archivo | Líneas | Rol |
|---|---|---|
| `XLK BOT.mq5` (antes `Bot_señal_1.6.mq5`) | 2385 | EA principal: inputs base, zonas, señales, resultados pendientes, alertas, dibujo, `OnInit/OnTick`. Incluye las capas. |
| `src/Config/InputsRisk.mqh` | 32 | **Todos** los `input` de ejecución y riesgo, en tres grupos: Ejecución, Riesgo — bloqueo, Riesgo — avisos. |
| `src/Market/StructureRanges.mqh` | 172 | Swings/envolventes de estructura (solo contexto). |
| `src/Market/StructuralLevels.mqh` | 311 | Niveles estructurales (swings/ciclos) como zonas extra. |
| `src/Market/ManualLevels.mqh` | 90 | Lee líneas/rectángulos del gráfico como niveles. |
| `src/Strategy/Strategy1604.mqh` | 245 | `EvaluateM5ReactionStrategy`: la estrategia M5/M1 y su plan (SL/TP/volumen). |
| `src/Strategy/StrategyVariants.mqh` | 508 | Variantes B/C/D y controles (solo observación), **guardas de ejecución**, entrada temprana de zona. |
| `src/Strategy/TakeProfitRules.mqh` | 198 | TP: zona más cercana o cuantil de spikes. |
| `src/Execution/DemoExecution.mqh` | 367 | Envío real de órdenes (`DemoExecuteConfirmed`), pausa por pérdidas. |
| `src/Execution/ManualExecution.mqh` | 580 | Entradas en niveles dibujados a mano, salida por retroceso 25 %, time-stop, resumen. |
| `src/Observability/Instrumentation.mqh` | 337 | Bloqueo de escritor único, nombres de CSV con etiqueta (`_R1604`), rechazos, spikes, caché de zonas. |
| `src/Observability/TouchSpikeObserver.mqh` | 424 | Mide qué ocurre (spike) tras tocar una banda. |
| `src/Observability/OperationsMonitor.mqh` | 847 | Exporta operaciones (trades/trades2), contexto, seguimiento de rechazos, **avisos de disciplina/riesgo** y autotests. |
| `tests/` | 48/91/66 | `LevelsTests.mqh`, `Test_1604.mq5`, `Test_DemoExecution.mq5`. Hacen `#define input` (vacío); por eso los grupos usan la macro `BCSO_INPUT_GROUP`. |
| `presets/` | — | `boom_risk2.set`, `crash_risk2.set` (UTF-16). |
| `docs/` | — | Este documento y las notas de entrega. |

Los `.ex5`, los logs (`build/`) y los respaldos manuales ya no se versionan; los respaldos anteriores siguen en el tag `pre-restructure`.

## 3. Flujo de ejecución

`OnTick` (cada tick):
1. `RenewWriterLock` — evita dos instancias escribiendo los mismos CSV.
2. `OperationsPoll`, `RefreshStructureContext`, `UpdatePendingOutcomes` (resuelve señales pendientes).
3. En **vela M1 nueva**: spikes → TP → redibujo de zonas → caché de aviso temprano → niveles adicionales/manuales → **estrategia** (`EvaluateM5ReactionStrategy`, o la ruta heredada `EvaluateSignals`).
4. Cada tick: `EvaluateEarlyZoneEntry`, entradas manuales, time-stop, salida por retroceso, resumen, variantes, `ObserveTouchSpikes`, avisos, `OperationsAfterTick`.

`OnTradeTransaction` reparte el evento a 4 manejadores (ejecución, pausa por pérdida, manual, retroceso) y a `OperationsRiskPoll`.

**Rutas que terminan en una orden real** (todas pasan por `DemoExecuteConfirmed`, lo cual es bueno):
- `src/Strategy/Strategy1604.mqh:234` — estrategia M5/M1
- `src/Strategy/StrategyVariants.mqh:453` — entrada temprana de zona
- `src/Market/StructuralLevels.mqh:309` — niveles estructurales (`InpExecStructural`)
- `src/Execution/ManualExecution.mqh:193` — niveles manuales (`InpExecManual`)

Además hay **dos `OrderSend` propios de cierre** en `src/Execution/ManualExecution.mqh` (salida por retroceso, línea ~366, y time-stop, ~429). Total de sitios `OrderSend`: 3.

## 4. Salidas (CSV en `Common/Files`)

Prefijo `BCSO_<símbolo>_…` con etiqueta `_R1604`. Familias: `signals`, `outcomes`, `alerts`/`alert_outcomes`, `candidates`, `context`, `touch_spikes`, `trades`/`trades2`, `plans`, `tp_plans`, `exec`/`execution`, `control_schedule`, `variant_discards`, `levels_cov`, `manual_levels`, `manual_exec_summary`, `rejection_followup`, `runs`, además de `history_*` (hasta 6.6 MB c/u) y `reference_*` (ticks, 7 MB). Los nombres arrastran sufijos de versión **v1600 / v1603 / v1604** mezclados (8 / 5 / 10 apariciones en el código). Hay archivos de pruebas (`TEST1603_…`, `TESTR3_…`) mezclados con datos reales. `_context_` y `_touch_spikes_` superan 1 MB por símbolo.

## 5. Hallazgos de la auditoría (fase 1)

Ordenados por riesgo. Todo lo listado fue verificado en el código o en los `.set`.

### Riesgo operativo (prioridad alta)

1. **El preset activa la ejecución real; la documentación dice lo contrario.** `boom_risk2.set` tiene `InpDemoExecution=true`, `InpExecManual=true`, `InpExecStructural=true`; los `.md` y los `#property` afirman "false por defecto". Es correcto para los valores por defecto del código, pero los presets que realmente se cargan en el gráfico los invierten. Hay que decidir cuál es la verdad y documentarla.
2. ~~**Parámetros de riesgo duplicados.**~~ **Resuelto el 2026-10-07.** Al revisarlos, solo dos eran duplicados reales y se unificaron: la pérdida diaria (queda `InpExecMaxDailyLossUSD`; se eliminó `InpExecutionDailyLossUSD`) y el magic (queda `InpExecMagic`; se eliminó `InpExecutionMagic` y el truco del 160402). El resto son **pares aviso/bloqueo** o reglas distintas, y se mantienen:
   - Pausas: `InpLossPauseMinutes` (20) tras 2 SL seguidos; `InpExecPauseMinutes` (30) al alcanzar `InpExecMaxConsecutiveLosses`.
   - Rachas: `InpExecMaxConsecutiveLosses` (4) **bloquea**; `InpMaxConsecutiveLosses` (3) solo **avisa**.
   - Riesgo por operación: `InpPlanRiskMaxUSD` **bloquea**; `InpMaxRiskPerTradeUSD` solo **avisa**. `InpMaxDailyLossUSD` es un aviso (0 = desactivado).
   Todos están en `src/Config/InputsRisk.mqh`, agrupados en la ventana del EA. Se quitaron de los presets las claves obsoletas (`InpExecutionDailyLossUSD`, `InpExecutionMagic`, `InpExecMaxRiskUSD`). A los presets les faltan 15 inputs más nuevos (TP, salida por retroceso, `InpLossPauseMinutes`), que toman el valor por defecto del código.
3. **Tres puntos de envío de órdenes y cuatro manejadores de `OnTradeTransaction`** con estado compartido en `GlobalVariable`s (55 usos). Funciona, pero es la zona donde un cambio pequeño tiene consecuencias de dinero.

### Estructura (el "espagueti")

4. **Un monolito con includes que no son bibliotecas.** Los `.mqh` declaran sus propios `input` y globales. *Parcialmente resuelto el 2026-10-07:* ya no hay `#include` a mitad de archivo ni declaraciones adelantadas (sobraban: MQL5 no exige orden entre funciones); las capas se incluyen en un solo punto. Sigue pendiente que los módulos dependan de las globales declaradas en el `.mq5` principal antes de ese punto.
5. **Estado global masivo**: ~69 globales `g_` en el EA principal + ~40 en `OperationsMonitor` + 28 en `Instrumentation` + 19 en `ManualExecution`, etc. Casi cualquier función lee o escribe el estado de otra.
6. **Funciones largas**: 4 pasan de 100 líneas (`UpdatePendingOutcomes` 111, `CollectQualifiedZonesRaw` 108, `ObserveTouchSpikes` 107, `RecordObservation` 104) y unas 18 pasan de 60 (algunas son pruebas).
7. **Struct `PendingSignal` con ~38 campos** que mezcla identidad, precios, estado de seguimiento, control, medición y resultado; `InitPendingSignal` los pone a mano uno por uno (fácil olvidar uno al añadir campos).
8. **84 `input` en el archivo principal + ~80 en módulos.** Mezcla parámetros de estrategia, de dibujo, de alertas, de nombres de archivo y de depuración sin agrupar.
9. **Validación de inputs en un `if` de 15 condiciones** dentro de `OnInit` (líneas 2267–2302), repartida además en 5 funciones `*InputsValid`.

### Código heredado / conmutadores

10. **Dos estrategias conviven** detrás de `InpUseM5ReactionStrategy`: la nueva (`EvaluateM5ReactionStrategy`) y la heredada (`EvaluateSignals` + `NotifyBoomEarlyNCandidate` + `NotifyCrashTrendCandidate`), más `InpRulePack` (RULES_1500/1600) y `InpShadowLegacyRules`. Con los valores actuales la heredada no corre, pero sigue compilándose y manteniéndose. Candidata a retirarse o aislarse.
11. **Cinco "generaciones" de nombre**: archivo "Bot_señal_1.6", versión `1.604`, revisión `r3-demo-levels-ownpos-risk2`, tag `1.604-r3-demo-levels-manexec-ownpos-risk2-tp-retrace25`, carpeta `BCSO_1604_RISK2_PAUSE`, CSV `v1600/v1603/v1604`. El tag crece con cada característica añadida.

### Pruebas

12. **Las pruebas incluyen el EA entero con macros** (`#define input`, `#define OnInit ObserverInit`, `#define OrderSend MockOrderSend` y luego `#include "../XLK BOT.mq5"`). Es ingenioso pero frágil: reemplaza `OrderSend` globalmente y desactiva todos los `input`. Las notas reportan 67 y 55 comprobaciones aprobadas, pero no hay pruebas de integración de llenados reales (las propias notas lo reconocen).

### Repositorio

13. Hay un único commit (`first commit`), remoto `github.com/sebastianxilkeraraujo-ai/v1604`, rama `main`. Faltan `.gitignore` (`*.ex5`, `*.log`, `compile_*`), y los `.set` están en **UTF-16**, así que git los trata como binarios y no mostrará diferencias legibles (convendría guardarlos en UTF-8 o declarar `*.set -text diff` con un filtro). El nombre de autor del commit (`sebastianxilkearaujo-ai`) no coincide con el usuario del remoto (`sebastianxilkeraraujo-ai`).

## 6. Qué está bien (conservar)

- Un solo punto de salida de órdenes de entrada (`DemoExecuteConfirmed`) con `OrderCheck` previo, SL obligatorio, sin reintentos y bloqueo ante resultado incierto.
- Bloqueo de escritor único y CSV con etiqueta: evita corromper datos entre instancias.
- Funciones de decisión "puras" (`*Decision`, `ExecGuardDecision`) testeables sin broker.
- Los `.md` de entrega registran límites y riesgos con honestidad.

## 7. Plan propuesto (para discutir antes de tocar código)

1. **Congelar línea base**: commit con `.gitignore`, mover logs y `.ex5` de respaldo fuera del repo, etiquetar `v1.604-baseline`. No cambia comportamiento.
2. **Decidir la fuente de verdad del riesgo** (punto 2) y unificar parámetros duplicados, manteniendo compatibilidad con los `.set` actuales.
3. **Mapa de dependencias detallado** (qué función usa qué global) para decidir cortes seguros.
4. **Extraer sin cambiar lógica**: primero `RiskConfig`/guardas, luego CSV/IO, luego la ruta heredada.
5. Tras cada paso: compilar, correr `Test_1604` y `Test_DemoExecution` y comparar los CSV de una sesión demo antes/después.

## 8. Preguntas abiertas

- ¿La ruta heredada (RULES_1500/1600, N-candidate de Boom, tendencia de Crash) se sigue usando o se puede retirar?
- ¿Cuál de los límites de pérdida/racha/pausa es el que realmente quieres que mande?
- ¿Los presets `*_risk2.set` con ejecución activada son la configuración deseada en demo?
- ¿Se pueden archivar los CSV `v1600`/`v1603` y los `TEST*`?
