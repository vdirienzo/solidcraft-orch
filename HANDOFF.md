# SolidCraft — handoff para la próxima sesión

Actualizado: 2026-11-28

## Dónde estamos

- **El análisis del 2026-11-21** está en `reports/analisis-orquestador-2026-11-21.md`: los
  resultados reales (117 PRs, 88 mergeados), lo que estaba caído, las causas de fondo, los tokens
  y la deuda. Lo que quedó pendiente está en sus §2 a §4.
- **Las lecciones del 2026-11-22/23** están en `reports/lecciones-2026-11-22.md` (22 lecciones
  con las mediciones) y **lo que hizo la sesion del 23-11** en
  `reports/sesion-2026-11-23.md` (23 PRs mergeados en 48 h, el disco de 124 GB a 174 GB libres).
- **El runtime ya no es hermes**: el agente de un slot es **opencode**
  (`bin/dispatch-slot.sh` con el runtime de `bin/agent-env.sh`) y los crons son el **crontab del
  usuario** (`bin/install-crontab.sh` los instala desde `bin/crons.txt`). `~/.hermes` no existe.
  El README esta reescrito en ingles con el mapa de las piezas.
- **La limpieza es del orquestador** (`bin/close-slot.sh`: target, worktree, brief y lock), no
  del agente: el brief ya no le pide borrar su worktree (eso mataba el gate del propio slot).
- **El gate es el CI del fork** (`GATE_MODE=fork-ci` en `$LOOP_DIR/config.env`). En el fork
  `vdirienzo/solidcraft`: solo `ci.yml` activo (los otros 16 workflows de upstream estan
  apagados con `gh workflow disable`). **Ojo: los Actions del fork hay que habilitarlos en la
  web** (si estan apagados, el despacho responde `422 Actions has been disabled for this
  repository` y las corridas mueren con "runner shutdown": no son fallos de codigo). Para
  volver a compilar en esta maquina: `GATE_MODE=local`.
- **El loop esta PAUSADO** (`bash bin/loop-pause.sh pause`): el bloque del crontab salio y
  quedo la marca `locks/loop-paused`. Para volver: `bash bin/loop-pause.sh resume`.
- **El kernel sigue pausado** (15 GB de RAM, un solo build pesado a la vez): `bin/issue-card.py`
  marca `kernel_cause` y `bin/prepare-slot.sh` sale con 6. Los dos issues que esperan al
  kernel son el #18629 (solidcore#3352) y el #19690 (solidcore#3371).
- **Las reglas** viven en upstream (`AGENTS.md`, `CONTRIBUTING.md`, `.agents/skills/`).
  `RULES.md` solo apunta ahi y lista las reglas propias del orquestador.
- **Un job vigila las reglas**: la automatización `solidcraft-rules-watch`
  (`aut_2228f2ea80017aGM26OozSO5bM`) corre `bash bin/rules-verdict.sh` cada 6 h y deja el
  veredicto en `state/rules-verdict.txt`. Trae OK / CAMBIÓ (con los ficheros que se movieron) /
  NO SE PUDO COMPROBAR, y además comprueba que las rutas de upstream que citamos sigan existiendo
  y que los briefs no citen rutas muertas. Si dice CAMBIÓ: `bash bin/rules-snapshot.sh --diff`,
  revisar `RULES.md` y `prompts/`, y solo entonces `bash bin/rules-snapshot.sh --update`.
- **El checkout local de upstream va al día**: `git merge --ff-only origin/main` en
  `/home/user/Projects/solidcraft-orch`. Los agentes leen código ahí.
- El estado vivo (slots, PRs, gates) **no** esta en este archivo: sale de `bin/orch-state.sh`.

## Cómo arrancar

```bash
cd ~/.local/share/solidcraft-orch   # es este repo (un symlink)
bash bin/preflight.sh               # qué le falta a la máquina (opencode, gh, el PATH del crontab)
bash bin/rules-sync.sh              # exit 1 + lista = upstream movió reglas: leerlas antes de despachar
bash bin/rules-verdict.sh           # el mismo check como un veredicto (lo corre el job de las 6 h)
bash bin/test-all.sh --fast         # 0 fallos antes de tocar nada
bash bin/loop-pause.sh status       # ¿pausado o corriendo?
crontab -l | grep -c solidcraft     # los crons del loop; si faltan: bash bin/install-crontab.sh
bash bin/orch-state.sh              # slots, PRs y gates (NUNCA state.json entero)
bash bin/slots.sh report            # cores, RAM y slots libres
bash bin/wave.sh --dry-run          # qué haría la wave; el cron la corre cada 10 min
```

## Qué es este directorio

La memoria del orquestador. **Todo el estado vive acá, no en el contexto de la sesión.**

| Qué | Para qué | Cómo se lee |
|---|---|---|
| `state/` → `state.json` | el estado por concepto; `state.json` se arma con `bin/merge-state.sh` | `bin/orch-state.sh <concepto>` |
| `history.jsonl` | lo que se hizo, una línea por acción | `bin/orch-state.sh history 10` |
| `RULES.md` | el puntero a las reglas de upstream y las propias | entero (es corto) |
| `rules-snapshot/` | los hashes de las reglas de upstream | `bin/rules-sync.sh` |
| `prompts/` | la plantilla del brief y el brief de cada slot | por issue |
| `logs/` | evidencia; el turno del agente en `<N>-wave.log` y sus eventos en `<N>-wave.jsonl` | por issue |
| `locks/` | los locks por slot | `bin/slot-lock.sh --list` |
| `reports/` | las mediciones y los análisis | por fecha |

## Las herramientas

```bash
bash bin/orch-state.sh issue 10134                    # todo lo que se sabe de un issue
bash bin/verify-pr.sh 9843                            # un PR en una llamada (0 ok, 1 falla, 6 no se sabe)
bash bin/prepare-slot.sh <issue>                      # lock, claim, worktree y brief
bash bin/dispatch-slot.sh <issue>                     # arranca el opencode del slot
bash bin/close-slot.sh <issue> [pr]                   # limpia el slot cuando el PR ya está arriba
bash bin/slot-lock.sh --slot N --reap --older-than 60 # un lock huérfano (edad y dueño, nunca el PID)
bash bin/slot-lock.sh --heavy --take --wait 3600      # el turno del build pesado (uno a la vez)
export CARGO_TARGET_DIR=$(bash bin/slot-target-dir.sh --slot N)   # nunca hardcodear la ruta
bash bin/gate.sh <issue> <sha>                        # el gate del slot; el veredicto está en
                                                      # $LOOP_DIR/gates/<slot>/scope.verdict
```

La sesión de opencode de un slot se encuentra con `opencode session list` (título `issue-N`).
No se retoma con `--continue`/`--session` una sesión con el cache frío (`CONTRIBUTING.md` de
upstream): el turno nuevo arranca del brief y de lo que ya está en el fork.

## La máquina

12 cores, 15 GB de RAM, 421 GB en `/home`.

- `implement_slots` lo decide `bin/slots.sh` según los cores y la RAM libres (hoy manda la RAM).
- **Un build pesado a la vez**, con `nice`. Los techos de memoria del slot y del gate salen de la
  política de la máquina (`$LOOP_DIR/config.env`: `SLOT_MEMORY_MAX`, `GATE_MEMORY_MAX`).
- **El kernel no se compila acá**: se vetan los issues de `crates/kernel` y `solidcore/`.
  Upstream sí acepta trabajo de kernel; el veto es nuestro, por la máquina.
- El agente tiene techo de tiempo: `AGENT_TIMEOUT_MIN` (180 min si `config.env` no dice otra
  cosa), que `bin/dispatch-slot.sh` aplica con `timeout`.

## Sobre los tokens

El costo no es el brief: es que cada resultado de herramienta queda en el contexto y se reenvía
en cada turno. Llamadas independientes en un mismo turno, filtrar en el origen (un resultado de
más de ~10 KB es un comando que no filtró) y leer el estado por partes. Al agente no se le manda
lo que puede leer en disco (`AGENTS.md`, las skills): se le manda el issue, el diagnóstico, los
números medidos y las decisiones. Más en `docs/costo-de-tokens.md`.

## Lo que la sesión del 23-11 dejó aprendido (las cinco que más costaron)

1. **El cuerpo de un PR se pega con el PATCH de la API**, nunca con `--body @fichero`
   (eso deja la cadena literal como cuerpo y el check "Defaults line check" cae):
   `gh api -X PATCH repos/tangency-labs/solidcraft/pulls/<n> -F body=@<fichero>`, y
   después se relee (`gh pr view <n> --json body --jq .body | head -3`).
2. **No se cierra un slot mientras su agente trabaja**: el orquestador le borró el worktree a
   un agente dos veces y le abortó el `cargo test`. Se cierra cuando el agente ha reportado.
3. **Un `signal 9` no es un error del cambio**: es la caja (15 GB, un build pesado a la vez).
   Se reintenta cuando la caja está descargada, y el token pesado se toma ANTES de compilar.
4. **`gh issue view --comments` no funciona en este repo** (GraphQL "Projects (classic)"): se
   lee con la API REST (`gh api repos/.../issues/<n>/comments`, `/pulls/<n>/reviews`,
   `/issues/<n>/timeline`).
5. **Una condición del maintainer es trabajo, no una nota**: el #20898 exigía un paso de
   formato pendiente más un test de diseño guardado, y el #21219 un paso de formato para las
   tangencias viejas. Sin las dos cosas, el PR no entra en la cola por más verde que esté.

El detalle con las mediciones está en `reports/lecciones-2026-11-22.md` (§2.4: L16 a L22).
