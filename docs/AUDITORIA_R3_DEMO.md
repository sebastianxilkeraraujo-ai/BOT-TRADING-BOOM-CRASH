# 1.604 r3-demo — entrega y verificación

Los complementos de `D:\Varios\TRADING\BOT\CLAUDE PARA V1604` se incorporaron a la candidata de esta carpeta. La ruta anticipada queda en `StrategyVariants.mqh`, desactivada por defecto. Versiones de build y reglas: 1.604; revisión: r3-demo; etiqueta: 1.604-r3-demo.

## Auditoría del ejecutor

Las líneas siguientes corresponden al archivo final `DemoExecution.mqh` (DE) o `StrategyVariants.mqh` (SV). «Existía» describe el estado anterior; la línea señala la comprobación o gancho final.

| Control | Existía (sí/no, línea final) | Acción |
|---|---|---|
| Cuenta demo y USD | Sí, DE:141 | Conservado; también cubierto por decisión pura. |
| SL obligatorio; TP opcional | Parcial, DE:42 | SL obligatorio; se admite TP cero. |
| Rejilla y lote máximo configurable | Parcial, DE:188 / SV:152 | Tope `InpExecMaxLots=0.20`, redondeo y recálculo de riesgo. |
| 1 posición/símbolo y 2 totales | No con estos límites, DE:151 / SV:126 | Cuenta todas las posiciones; bloquea además si existen órdenes pendientes. |
| Enfriamiento confirmado por zona | No, DE:214 / SV:146 | 10 minutos, clave EXEC_CONFIRMED y persistencia entre reinicios. |
| Desviación, llenado, stops y freeze | Parcial, DE:167–183 | Conserva desviación/llenado; usa máximo de stops y freeze. |
| Retcodes y errores consecutivos | Parcial, DE:227 / SV:175 | Sin reintentos; parada tras 3 errores; resultado incierto conserva bloqueo. |
| Freno diario / operaciones / racha | Parcial, DE:151 / SV:126 | 10 USD, 12 entradas y 4 pérdidas con pausa de 30 minutos. |
| Interruptor y parada global temporal | No, SV:126 | Input apagado y variable temporal por cuenta. |
| Magic y vínculo con evento | Parcial, DE:163,213 / SV:175 | Comentario BCSO, diario nuevo y correlación de entrada con position_id. |

## Implementado

- Variantes B/C/D: observaciones con el mismo motor de seguimiento, IDs derivados de A, sin ejecución ni avisos emergentes. Riesgo teórico usando el volumen de A, con indicador de exceso de presupuesto.
- Control: una programación persistida por señal, semilla reproducible y plazo de hasta 120 minutos. Si no hay tick dentro de los 5 segundos posteriores al instante programado se marca DATA_GAP, sin inventar una entrada retrospectiva.
- Vigilancias y descartes del plan: conexión con el seguimiento existente de rechazos, horizonte predeterminado de 15 minutos y enfriamiento conservado.
- Nuevos archivos: exec, control_schedule y variant_discards. Se utiliza el helper de nombres existente, incluido el sufijo de separación de reglas cuando corresponda. No se alteraron esquemas ni nombres existentes.
- `InpDemoExecution=false` e `InpEarlyZoneEntry=false`, también en los tests. Variantes y controles son solo observación.

## Evidencia

Compilación de EA, Test_1604 y Test_DemoExecution: **0 errores y 0 advertencias** en cada uno. Logs `r3_*.log` en esta carpeta.

Ejecución en MT5, diario local `20261004.log`:

| Hora local del diario | Script | Resultado |
|---|---|---|
| 23:05:21.483 | Test_1604_r3 | 39 comprobaciones, 0 fallos |
| 23:05:31.536 | Test_DemoExecution_r3 | 28 comprobaciones, 0 fallos, mock_sends=0 |

Total: **67 comprobaciones, 0 fallos**. El reloj del gráfico/servidor mostraba aproximadamente cinco horas más que el diario local; no deben cruzarse como si fueran la misma hora.

Se comprobó visualmente que `Asesores Expertos > BCSO_1604_Demo > Bot_señal_1.6` está visible en el Navegador. Esa instalación es la anterior r2-demo: **la candidata r3-demo de esta carpeta no se sustituyó en los gráficos ni se activó**. No se enviaron, cerraron ni modificaron órdenes durante estas verificaciones.

## Límites y riesgos pendientes

- Las pruebas no son una validación extremo a extremo de llenados reales, recuperación tras desconexión ni de todos los CSV nuevos durante una sesión prolongada. Falta observar esa candidata en demo y contrastar dichos registros.
- El límite de lote 0.20 es una elección inicial conservadora; puede bloquear entradas si el mínimo del símbolo o el rango de riesgo 1–1.5 USD no permiten ese volumen.
- La pérdida diaria usa el neto de la cuenta; el contador de entradas y racha usa posiciones originadas con el magic del bot, incluyendo cierres manuales en el cálculo de resultados. Posiciones aún abiertas no se cuentan como pérdidas cerradas.
- Si el nuevo límite diario y el antiguo difieren, se aplica el menor. El magic antiguo se conserva cuando el nuevo permanece en su valor predeterminado; un nuevo magic explícito prevalece.
- Un SL y una desviación configurada no garantizan una pérdida máxima: gaps, deslizamiento y costes pueden superarla. Las variantes y controles no demuestran rentabilidad.
- Limitación de correlación: un cierre cuyo comentario sea reemplazado por el broker puede no conservar el event_id textual en su fila exec; el enlace de la entrada con trades2 debe hacerse por position_id. Los cierres manuales con otro magic no entran en el callback del ejecutor y se consultan en el exportador de operaciones.
