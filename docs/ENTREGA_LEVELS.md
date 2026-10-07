# Revisión levels — 5 de octubre de 2026

Implementación de r4-levels con etiqueta `1.604-r3-demo-levels` y revisión `r3-demo-levels`, manteniendo build y reglas 1.604.

Código nuevo: `StructuralLevels.mqh`, `ManualLevels.mqh`, `LevelsTests.mqh`. Ganchos mínimos en EA, estrategia, observador de toques y pruebas. Se actualizó la aserción de etiqueta de la prueba anterior para admitir la revisión instalada.

- Swings M5/M15 confirmados, ciclos completados, prioridad ciclo > M15 > M5, distancia y tope por lado. El timestamp de un pivote extendido considera su confirmación real.
- Niveles manuales del gráfico del EA y de gráficos M5 abiertos del mismo símbolo en este terminal. HLINE, TREND horizontal y RECTANGLE; objetos BCSO_ excluidos. Activación conservadora desde primera detección/cambio más 60 segundos, también después de reiniciar. Las marcas del navegador no son objetos del terminal de escritorio.
- Caché y cobertura por nueva M1. Bandas STRUCT_/MANUAL_ comparten el motor de toques existente; no se mezclan con las bandas de reacciones históricas.
- Planes de reserva cuando no hay zona de reacciones seleccionada. Gatillo M1 existente, riesgo/stop existentes, objetivo más próximo entre las clases disponibles; confirmaciones con RecordObservation sin alertas emergentes.
- Los nuevos niveles no ejecutan: `InpExecStructural=false`. La ejecución demo de la estrategia anterior se conserva mediante los presets particulares de cada gráfico.

Compilación final de EA y Test_1604: 0 errores, 0 advertencias. Test_1604_levels ejecutado en MT5: 55 comprobaciones, 0 fallos (16 de niveles y 39 existentes), diario local 04:33:23. El primer pase detectó una aserción de versión antigua; se corrigió y repitió.

Instalación: `MQL5/Experts/BCSO_1604_R4_Levels`. Presets previos: `Crash_pre_levels.set`, `Boom_pre_levels.set`. Inicio de Crash verificado a las 04:35:05 y Boom a las 04:38:06, horas del diario local. Ambos conservan InpDemoExecution=true y muestran InpExecStructural=false.

Los archivos nuevos usan TaggedCsv, por lo que el perfil actual añade `_R1604`: `BCSO_<símbolo>_levels_cov_v1604_R1604.csv` y, al detectar objetos elegibles, `BCSO_<símbolo>_manual_levels_v1604_R1604.csv`. No se migran ni reescriben CSV anteriores.

Límites: la inspección de objetos ocurre por minuto; movimientos intermedios que se reviertan antes de la siguiente inspección no se pueden reconstruir. Las líneas existentes al iniciar esperan nuevamente el retraso; no se reconstruyen toques anteriores. Sin objetos elegibles no se escribe manual_levels. Las pruebas no demuestran rentabilidad ni sustituyen la observación de nuevas reacciones completas en demo.
