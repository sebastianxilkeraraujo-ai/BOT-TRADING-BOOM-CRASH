// Capa de configuración: parámetros agrupados por tema.
#ifndef BCSO_LAYER_CONFIG
#define BCSO_LAYER_CONFIG

// Las pruebas hacen "#define input" (vacío) para poder modificar los parámetros;
// ahí "input group" no es válido, así que el grupo desaparece.
#ifdef input
#define BCSO_INPUT_GROUP(name)
#else
#define BCSO_INPUT_GROUP(name) input group name
#endif

#include "InputsRisk.mqh"
// Los input que aún viven en los módulos quedan bajo este grupo en la ventana del EA.
BCSO_INPUT_GROUP("General")
#endif
