# SolidCraft — handoff para la próxima sesión

Actualizado: 2026-10-31 18:10 CET

## ⚠ PENDIENTE QUE NECESITA UNA DECISIÓN (31-10-2026 ~00:15)

**El slot del issue #10306 perdió el claim y su agente sigue trabajando.**
El PR #10307 de `austin62jake` (draft, creado a las 21:34, `Fixes #10306`) ya reclamaba el issue
cuando nuestro agente arrancó (21:54). Como el PR abierto con **número menor** gana, el nuestro
habría perdido. El agente solo llegó a escribir el test RED; el fix nunca llegó.

- Diff preservado: `logs/10306-perdido-claim.diff`
- `state.json` → `slots.5` está marcado `claim-perdido` con la acción a tomar.
- **El agente es hijo de la sesión central, así que no se puede steerear desde otra sesión.** Hay que
  pararlo desde la sesión que lo despachó, y liberar el lock: `bash bin/slot-lock.sh --slot 10306 --release`.

**Además: el slot #10331 se registró como `running` SIN tomar el lock.** Viola la regla del
31-10-2026 de tomar el lock *antes* de despachar. Marcado en `state.json` → `slots.7.lock_missing`.

La forma de evitar esto es el protocolo de claim nuevo (`RULES.md` pasos 3-5):
leer los **comentarios** del issue antes de tomarlo → tomar el lock **primero** → abrir el draft →
**re-verificar** con `bash bin/claim-verify.sh <issue> [nuestro_pr]` (0 gana / 1 perdió / 2 no verificable).

## Qué es este directorio

La memoria del orquestador multi-agente. **Todo el estado vive acá, no en el contexto de la
sesión**: el contexto se comprime y se pierde, el disco no.

| Archivo | Qué es | Cómo se lee |
|---|---|---|
| `state.json` | el estado canónico: slots, PRs, gates, capacidad | **con `bin/orch-state.sh`**, nunca entero |
| `state/` | el estado **partido por concepto** (`meta`, `prs`, `slots`, `gates`, `claims`, `policy`, `notes`) | `state.json` se **genera** desde acá con `bin/merge-state.sh`; ver `state/README.md` |
| `history.jsonl` | el registro append-only de lo que se hizo (una entrada por línea) | `bin/orch-state.sh history 10` |
| `RULES.md` | el resumen de AGENTS.md + skills + CONTRIBUTING.md | entero (es corto) |
| `bin/` | las herramientas | ver abajo |
| `logs/` | evidencia: RED/GREEN, bodies, capturas | por issue |
| `locks/` | los locks por slot | `bin/slot-lock.sh --list` |

## Las herramientas (usarlas, no improvisar)

```bash
# el estado, por partes (NUNCA leer state.json entero: son 30 KB que se reenvian en cada turno)
bash bin/orch-state.sh              # summary: slots, PRs, gates
bash bin/orch-state.sh slots        # solo los slots
bash bin/orch-state.sh prs          # solo los PRs
bash bin/orch-state.sh issue 10134  # todo lo que se sabe de un issue
bash bin/orch-state.sh keys         # las claves y su tamano
bash bin/orch-state.sh history 10   # las ultimas 10 acciones

# verificar un PR en UNA llamada (head vs fork, keywords, defaults, rutas locales, draft, checks, gate)
bash bin/verify-pr.sh 9843          # exit 0 = todo en orden

# los slots
bash bin/slots.sh report            # cores, RAM, implement_slots, free_slots, gate_may_start
bash bin/slot-lock.sh --list
bash bin/slot-lock.sh --slot N --take --owner "label"
bash bin/slot-lock.sh --slot N --reap --older-than 60
bash bin/slot-lock.sh --heavy --take --wait 3600   # el turno del gate (uno a la vez)
bash bin/slot-lock.sh --heavy --reap --older-than 60   # un heavy lock huerfano bloquea TODOS los gates
export CARGO_TARGET_DIR=$(bash bin/slot-target-dir.sh --slot N)   # NUNCA hardcodear la ruta

# el gate scoped (target dir UNIFICADO con el del slot: bin/gate.sh)
bash bin/gate.sh <issue> <sha>            # compila en targets/slot-<issue> y en el worktree del slot
cat ~/.local/share/solidcraft-loop/gates/<issue>/scope.verdict   # el veredicto; el exit code NO es el veredicto

# el body de un PR contra el parser del upstream
bash ~/.local/share/solidcraft-loop/bin/pr-defaults-line.sh --body <file>   # exit 0 = pasa

# la suite del orquestador
bash bin/test-slot-parallelism.sh    # 27 tests
```

## La máquina

16 cores, 62 GB de RAM, 492 GB de disco. Es una VM dedicada a este trabajo: se puede limpiar.

- `implement_slots` lo decide `slots.sh` según los cores y la RAM libres (tope 4).
- **El gate es serializado**: compila 7 paquetes y satura la máquina. Turno con `--heavy`.
- **El perfil dev llena 66 GB por slot; el perfil `ci` son 1.5 GB.** Usar `ci`.
- Al terminar un slot, borrar su target (tras verificar que el fix está en upstream).
- La app release tarda **49 min** en linkear (LTO) y ocupa 3.3 GB: no se borra sin motivo.

## Estado actual (2026-10-31 18:10)

**Mergeados en upstream:** #9606 (#5858), #9823 (#3892), #8333, #9212, #7368, #8010.

**Abiertos:**

| PR | Issue | Estado | Qué espera |
|---|---|---|---|
| #9843 | #7114 | draft, gate verde, evidencia adjunta | la revisión del maintainer |
| #8059 | — | abierto | el merge del maintainer (la merge queue es suya) |

**En curso (4 agentes en paralelo):**

| Slot | Issue | Tema |
|---|---|---|
| 1 | #10134 | `sketch.move` no resuelve el id de un arco |
| 2 | #10116 | Preferences resetea `window_system` al guardar |
| 3 | #10138 | la app debe seguir el idioma del sistema |
| 4 | #10079 | renombrar la 2ª extrusión abre el sketch |

**Pendiente de esta sesión:** el rebase de #9843 sobre `origin/main` (estaba **114 commits
atrás**, y su CI estaba todo en `skipping`, o sea sin CI real). Rebase limpio, el fix intacto;
falta correr los tests dirigidos sobre el código rebasado y empujar con `--force-with-lease`.

## Reglas que no se negocian

- **El orquestador orquesta, no implementa.** Toda implementación va a un subagente con un
  brief autocontenido.
- Push **solo al fork** (`fork` = vdirienzo; `origin` = upstream y da 403).
- `Changes a default:` — exactamente una línea. `Fixes #N` y NADIE MÁS con close/fix/resolve.
- Un test de regresión en el archivo de tests **existente** del área.
- El **kernel está en pausa**: nada de `crates/kernel/` ni de labels `kernel-paused`.
- Nunca agregar `approved-for-ci` (solo los maintainers). La merge queue es del maintainer.
- Nunca editar archivos generados. Nunca `unwrap/expect/panic!` fuera de tests.
- Un tema y un issue por PR.
- Evidencia real (capturas propias) para cambios observables.
- El liveness de un lock es su **edad y su dueño**, nunca el PID.

## Sobre los tokens (leído de las mediciones, no de la teoría)

La sesión del orquestador: 5.1 M de input contra 460 K de output. **El costo no es el brief:
es que cada resultado de herramienta queda en el contexto y se reenvía en cada turno.**

- **Batching**: llamadas independientes en un mismo turno. La sesión hacía 1.1 tool calls por
  turno; eso multiplica el reenvío.
- **Filtrar en el origen**: un `grep` que imprime 14 KB, un `du` de todo, un `git log` sin
  `--max-count`: el lector paga cada byte, para siempre. Un resultado de más de ~10 KB
  significa que el comando no filtró bastante.
- **Leer el estado por partes** con `orch-state.sh`.
- **El estado tiene que ser cierto, no completo**: una entrada vieja (un PR mergeado que
  figuraba abierto) cuesta más que una que falta. GitHub manda; el disco se corrige.
- **No re-verificar lo que un subagente ya corrió**: las verificaciones que convierten un
  resumen en un hecho son las nombradas en la skill (head vs fork, body vs parser, archivo de
  veredicto, tests). Rederivar lo que el agente ya ejecutó es el gasto más caro y no agrega
  evidencia.
- **No mandar al subagente lo que puede leer en disco**: AGENTS.md, las skills y CONTRIBUTING.md
  están en el repo. Lo que no puede leer es la conversación: el issue, el diagnóstico, los
  números medidos y las decisiones tomadas. Eso es el brief.
