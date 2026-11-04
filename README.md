# solidcraft-orch

El orquestador que convierte issues de SolidCraft en PRs mergeados. Es codigo de Bash, Python y
un par de crons: no es una app, es un proceso.

## Que hace

1. Barre el pool de issues del repo por la API (paginado, sin truncar) y filtra: sin kernel, sin
   triage, con cuerpo con contenido real.
2. Verifica que el issue este libre (sin claim, sin PR que lo reclame).
3. Localiza la causa raiz en el codigo. Si la causa esta en solidcore/SMLib, el issue se descarta.
4. Escribe el TEST RED y lo commitea y pushea. Este es el entregable minimo del que busca.
5. Le da al que implementa un brief literal con el codigo a aplicar.
6. El agente commitea, pushea al fork y abre el PR EN DRAFT: el draft es el claim (la regla del
   repo: un draft sin pushes por 72 h puede ser tomado).
7. La cola de gates compila a 2 por vez, con su CARGO_TARGET_DIR propio por slot.
8. gate-baseline.sh separa lo preexistente (KNOWN_FAILING_TESTS + origin/main) de lo nuevo: cuenta
   el veredicto efectivo, no el crudo.
9. pipeline.py pasa el PR a ready y comenta el veredicto.

## Que NO se incluye en el repo (se regenera en cada PC)

`targets/ logs/ locks/ gates/ state/ state.json history.jsonl` — son el estado de una maquina
concreta, no codigo.

## Instalarlo en otra PC

```bash
git clone <este-repo> ~/.local/share/solidcraft-orch
cd ~/.local/share/solidcraft-orch
mkdir -p targets logs locks gates state reports briefs baseline
cp bin/slot-target-dir.sh bin/ 2>/dev/null
```

Variables de entorno (NO van al repo, van en el entorno o en un .env ignorado por git):

```
GH_TOKEN=<un token de GitHub con permiso de push y de abrir PRs>
SOLIDCRAFT_CONTROL_TOKEN=<el token del control del daemon de SolidCraft>
```

### Las rutas salen del entorno, con default de esta maquina

Ningun script lleva una ruta absoluta hardcodeada: cada una sale de una variable, con el default
de ESTA maquina. Asi esta maquina sigue funcionando sin cambiar nada, y la otra PC exporta las
suyas y corre el mismo codigo.

```bash
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"   # el orquestador: estado, locks, targets
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"     # el loop: los veredictos de los gates
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"        # el checkout del producto
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"         # los worktrees de los slots
HERMES_SCRIPTS="${HERMES_SCRIPTS:-/home/user/.hermes/scripts}"      # los scripts que corren los crons
```

En la otra PC se exportan las suyas antes de registrar los crons:

```bash
export ORCH_DIR="$HOME/.local/share/solidcraft-orch"
export LOOP_DIR="$HOME/.local/share/solidcraft-loop"
export SOLIDCRAFT_REPO="$HOME/solidcraft"
export WORKTREES_DIR="$HOME/solidcraft-wt"
export HERMES_SCRIPTS="$HOME/.hermes/scripts"
```

Los crons corren las COPIAS de los scripts que estan en `HERMES_SCRIPTS` (en esta maquina,
`~/.hermes/scripts/`): hay que copiar ahi los scripts del repo para que el cron los encuentre.

El criterio de portabilidad es un grep, y es un test del repo (`bin/test-portability.sh`):

```bash
grep -rn '/home/user' bin/ | grep -v ':-/home/user'    # tiene que salir VACIO
```

Los crons que hay que registrar (todos con --no-agent: no gastan tokens de LLM):

| cron | cada | script | para que |
|---|---|---|---|
| solidcraft-gate-queue | 3 min | gate-queue.sh | drena la cola de gates (2 a la vez) |
| solidcraft-pipeline | 5 min | pipeline.py | corrige bodies, encola gates, pasa a ready |
| solidcraft-nice-compilations | 2 min | nice-compilations.sh | baja la prioridad de las compilaciones nuevas |
| solidcraft-reporte-diario | 10 y 22 | daily-report.py | el reporte, sin LLM |

```bash
hermes cron create --name solidcraft-gate-queue --schedule '*/3 * * * *' \
  --script gate-queue.sh --no-agent --deliver local
hermes cron create --name solidcraft-pipeline --schedule '*/5 * * * *' \
  --script pipeline.py --no-agent --deliver local
```

## Las reglas, los traps y las lecciones (docs/)

La skill del orquestador vive en el directorio de skills de Hermes, que en la otra PC NO esta.
Sus `references/` (las reglas, los traps conocidos y las lecciones) estan COPIADOS en `docs/`
del repo, y el repo es lo que la otra PC clona:

| doc | que hay |
|---|---|
| `docs/portable-orchestrator.md` | como se publica el orquestador y como corre en la segunda maquina |
| `docs/slot-rules.md` | las reglas de los slots, los worktrees y el lock de la fase pesada |
| `docs/known-traps.md` | los traps conocidos: lo que ya rompio una vez y como se evita |
| `docs/feature-agent-briefs.md` | como se escribe un brief para un agente |
| `docs/issue-selection.md` | como se elige el issue que se ataca |
| `docs/duplicate-claims-and-contributing-instead.md` | que hacer cuando el issue ya esta tomado |
| `docs/agent-handover.md` | como se entrega el contexto a otro agente |
| `docs/agent-death-and-duplicate-work.md` | que hacer cuando un agente muere |
| `docs/before-dispatching-a-wave-check-for-a-pr.md` | la comprobacion antes de despachar una ola |
| `docs/checking-a-rule-against-real-numbers.md` | como se verifica una regla con numeros reales |
| `docs/costo-de-tokens.md` | el costo de los tokens y como se recorta |
| `docs/disk-hygiene.md` | la higiene del disco |
| `docs/loop-vs-graph.md` | la diferencia entre el loop y el grafo |
| `docs/status-report-pushes-and-load.md` | el reporte de estado, los pushes y la carga |
| `docs/verifying-a-delegated-pr.md` | como se verifica un PR delegado |
| `docs/visual-evidence-capture.md` | como se captura la evidencia visual |

La copia es de una sola direccion: `docs/` es una copia, y el directorio de skills sigue siendo
la fuente.

## Las reglas que importan (y que estan en RULES.md)

- Un fallo preexistente en origin/main NO es una regresion: el gate separa lo preexistente de lo
  nuevo y lo que cuenta es el veredicto efectivo.
- El gate usa el mismo set de features que upstream (por eso el scope incluye solidcraft-cli:
  sin el, la feature smlib no esta activada y salen miles de fallos falsos).
- `Changes a default: no` es la forma EXACTA que exige el CI upstream.
- Un test de regresion va en el archivo de test del AREA, nunca en un archivo por bug (#3226).
- Dos compilaciones pesadas como maximo, y cada una con su CARGO_TARGET_DIR.
- CARGO_INCREMENTAL=0, o el sccache no sirve de nada.
- Nada de force-push a origin, nunca cambiar de rama en el checkout principal, y nunca editar un
  script que se este ejecutando.

## Pruebas

Las suites de `bin/test-*.sh` y `bin/test-rules.py` tienen que dar rc=0. Correlos antes de
commitear cualquier cambio del orquestador.

`bin/test-portability.sh` es la suite de la portabilidad: verifica que ningun script de `bin/`
tenga una ruta absoluta de esta maquina fuera de los defaults, que los scripts que usan las
variables de rutas las definan, y que las reglas y los traps esten en `docs/`.
