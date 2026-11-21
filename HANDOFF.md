# SolidCraft — handoff para la próxima sesión

Actualizado: 2026-11-21

## Dónde estamos

- **El análisis del 2026-11-21** está en `reports/analisis-orquestador-2026-11-21.md`: los
  resultados reales (117 PRs, 88 mergeados), lo que estaba caído, las causas de fondo, los tokens
  y la deuda. Lo que quedó pendiente está en sus §2 a §4.
- **Dos commits lo aplicaron:**
  - `08a4ee5`: el agente de los slots es **opencode** (`bin/dispatch-slot.sh`, con el runtime
    de `bin/agent-env.sh`) y los crons son el **crontab del usuario** (`bin/install-crontab.sh`
    los instala desde `bin/crons.txt`). Hermes se fue para siempre: `~/.hermes` no existe.
  - `517857d`: la wave vuelve a despachar, con el flujo de upstream. El crontab tiene PATH, la
    cola de gates usa `flock` y la wave corta a los tres fallos. El claim va primero (commit
    vacío, draft y `claim-verify`) y el brief sigue `solidcraft-full-stop`. El agente corre con
    techo de tiempo y `--format json`. No hay ping de `approved-for-ci` ni comentarios de estado.
- **Las reglas** viven en upstream (`AGENTS.md`, `CONTRIBUTING.md`, `.agents/skills/`).
  `RULES.md` solo apunta ahí y lista las seis reglas propias del orquestador.
- El estado vivo (slots, PRs, gates) **no** está en este archivo: sale de `bin/orch-state.sh`.

## Cómo arrancar

```bash
cd ~/.local/share/solidcraft-orch   # es este repo (un symlink)
bash bin/preflight.sh               # qué le falta a la máquina (opencode, gh, el PATH del crontab)
bash bin/rules-sync.sh              # exit 1 + lista = upstream movió reglas: leerlas antes de despachar
bash bin/test-all.sh --fast         # 0 fallos antes de tocar nada
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
