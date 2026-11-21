# docs/

Las reglas propias, los traps y las lecciones del orquestador. Las reglas de SolidCraft no
están acá: viven en upstream (ver `RULES.md`).

## Datos históricos (2026-11-21)

- `reports/agentes-metricas.csv` es **histórico**: son 132 delegaciones a subagentes de hermes,
  versionadas el 2026-11-04 (el `estado` dice `interrupted`, `max_iterations`, `completed`).
  Sirve para comparar, no describe el loop de hoy: el agente es opencode con techo de tiempo
  (`AGENT_TIMEOUT_MIN`), y lo que hizo y lo que gastó cada turno se lee en
  `logs/<N>-wave.log` y `logs/<N>-wave.jsonl`. El CSV no se edita.
