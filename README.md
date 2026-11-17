# solidcraft-orch

El orquestador que convierte issues de SolidCraft en PRs mergeados. Bash, Python y un par de
crons: no es una app, es un proceso. Todo el estado vive en disco, asi que sobrevive a un crash,
a un `/new` de sesion y a un SIGKILL.

Este README es tambien la guia de onboarding: **la seccion "Lo que NO hay que hacer" es la parte
mas importante del archivo** y esta escrita con las lecciones que costaron horas de trabajo.

---

## 1. El flujo, en una linea

Del issue al PR: buscar -> libre -> causa raiz -> test RED -> fix -> PR en draft -> gate -> ready.
Cada paso es un proceso que puede morir y ser retomado; las aristas son condiciones sobre archivos.

El grafo esta DECLARADO en `workflow.yaml` (15 nodos, 18 aristas, 8 senales), se valida con
`bin/workflow-validate.py` y se ejecuta con `bin/workflow-runner.sh --list` (que dice que nodos
serian elegibles ahora). El runner NUNCA ejecuta los nodos que compilan: esos los llevan los crons.

| nodo | que hace | quien lo hace |
|---|---|---|
| buscar-issue | barre el pool por API y filtra (sin kernel, sin triage, con contenido) | un agente |
| claim-verify | el issue esta libre? | `bin/claim-verify.sh` |
| causa-raiz | donde esta el defecto | un agente, con brief literal |
| test-red | el test que falla antes del fix | un agente |
| fix | la implementacion | un agente, con brief literal |
| draft-pr | abre el PR en DRAFT | el agente, en el commit |
| dup-scan | este PR es duplicado de otro abierto? | `bin/dup-scan.sh` |
| comment-watch | lee los comentarios del maintainer | `bin/comment_watch.py` (cron 15 min) |
| revisar-comentarios | atiende el pedido del maintainer | un agente |
| pipeline | corrige bodies, encola gates, pasa a ready | `bin/pipeline.py` (cron 5 min) |
| gate-queue | drena la cola de gates | `bin/gate-queue.sh` (cron 3 min) |
| gate | compila y da el veredicto | `bin/gate.sh` |
| gate-baseline | separa lo preexistente de lo nuevo | `bin/gate-baseline.sh` |
| verify-pr | valida el PR listo | `bin/verify-pr.sh` |
| ci-upstream | espera al CI y al maintainer | el maintainer (la merge queue es suya) |

---

## 2. Lo que NO hay que hacer

Cada punto es una.leccion con su porque. Esta lista es la parte que hay que leer antes de tocar nada.

### Sobre la maquina compartida

1. **No compiles Rust desde un agente.** La cola de gates compila, a 2 por vez. Un agente que
   compila toma un slot y compite por los locks de Cargo: se ha visto a 3-9 procesos concurrentes y
   a dos agentes gastar 2h29m cada uno sin dejar un solo commit.
2. **No uses `pkill`, `killall` ni `kill -9`.** Uno lo uso un subagente y mato una medicion de 3,5 h;
   en una maquina compartida un pkill puede matar gates, compilaciones y cronjobs ajenos. Para
   cortar TU build: guardá el PID cuando lo lanzas y hacele `kill -TERM` solo a ese. Para esperar a
   que se libere la caja: un loop con `pgrep -x cargo` / `pgrep -x rustc`, o `bin/build-slot.sh --status`.
3. **No edites in-place un script que se este ejecutando.** Los crons corren `pipeline.py` cada 5
   minutos y `gate-queue.sh` cada 3. Editar un script mientras Bash lo lee produce errores de
   sintaxis a mitad de ejecucion. Siempre reemplazo atomico: `os.replace` o `mv`.
4. **No pongas un stub de una herramienta en un directorio que pueda estar en el PATH.** Un `gh`
   falso en un scratch hacia no-op en `pr create`: PRs que no existen y un pipeline que no publica
   nada sin avisar. Si testeas con stubs, que vivan fuera del PATH, y usá `GH_BIN` para fijar cual
   `gh` se usa.
5. **Dos compilaciones pesadas como maximo, y cada una con su `CARGO_TARGET_DIR` propio** (por
   slot). Un target compartido hace que una compilacion borre los artefactos de otra en caliente
   (`failed to exec .../deps/...`): 2423 falsos fallos de una vez.
6. **`CARGO_INCREMENTAL=0`, siempre.** Con incremental los `rustc` no son cacheables y cada slot
   recompila las mismas dependencias: el sccache pasa de 0 hits a 19 con incremental apagado.

### Sobre los veredictos

7. **Un veredicto que no llega al exit code es peor que no tener veredicto.** El gate escribia
   ROJO (crudo) y el pipeline leia el efectivo; `merge-state.sh --check` reportaba diferencias y
   salia con rc=0; un test decia "3 casos fallan" y salia con rc=0. Regla: **todo script que falla
   devuelve rc distinto de 0**, y el que informa propaga el rc.
8. **Un fallo preexistente en `origin/main` NO es una regresion.** El veredicto crudo sale ROJO por
   fallos que ya estan en la base. El que cuenta es el **efectivo** (`scope.effective.verdict`),
   que `gate-baseline.sh` calcula separando lo preexistente de lo nuevo. Si un test falla en
   `origin/main` con el mismo mensaje, no lo persigas: contalo como preexistente.
9. **El baseline se UNE, nunca se reemplaza.** Una union no puede reducir preexistentes. Y hay que
   unir todas las fuentes (el catalogo oficial `tests/KNOWN_FAILING_TESTS` + `origin/main` + el
   checkout principal + el worktree del slot): una fuente atrasada solo puede OMITIR fallos, y eso
   produce un rojo falso.
10. **Gatea el mismo set de features que upstream.** El scope tiene que incluir `solidcraft-cli`:
    sin el, la feature `smlib` no esta activada y salen 1321 fallos falsos ("this build has no
    SMLib").
11. **Verifica los hechos contra el codigo, no de memoria.** Por ejemplo, los plazos del repo
    no son uno: son dos, y no son el mismo. En `scripts/claim/claim.js`: `CLAIM_HOURS = 72`
    (el `/claim` del bot vence a las 72 h de haberlo escrito) y `PR_IDLE_DAYS = 14` (un
    draft **sin pushes** puede ser tomado a los **14 dias**). La regla del CONTRIBUTING
    ("a draft with no pushes for 72 hours may be taken over") mezcla los dos: el 72 h es del
    comment, y el draft va por 14 dias.

### Sobre el trabajo

12. **El PR en DRAFT es el claim.** La regla del repo: *"A draft with no pushes for 72 hours may be
    taken over"* — pero el codigo del bot tiene DOS plazos y el texto los mezcla: el `/claim`
    vence a las 72 h (`CLAIM_HOURS`) y el draft sin pushes se puede tomar a los **14 dias**
    (`PR_IDLE_DAYS`, `scripts/claim/claim.js:9`). El que cuenta para un draft es el de 14 dias.
    Por eso el draft se abre en el COMMIT, no despues del gate: el gate puede tardar
    40 minutos o colgarse, y el issue no se pierde igual. Tope de trabajo en vuelo: **6**.
13. **El test RED va antes del fix.** El entregable minimo de quien investiga es el test RED
    commiteado y pusheado. Con RED, el fix es un brief literal de una hora; sin RED, el agente se
    come las iteraciones explorando y no entrega nada.
14. **Los briefs tienen que ser literales**: el codigo a aplicar, la ruta, el mensaje del commit,
    el comando del test. Un brief con "busca el bug" produce exploracion, no codigo.
15. **`max_iterations: 120`.** Un agente de 250 iteraciones puede costar ~$1,17 y no dejar un commit.
    Ponete un tope propio y mas bajo: si en 60 iteraciones no lo tenes, devolvé lo que tengas.
16. **Solo issues, no features.** Medido en esta maquina: un issue cuesta $0,25 y 16 h de agente por
    entrega; una feature, $1,90 y 138 h, con un 86% de probabilidad de cancelarse. El motivo no es el
    precio: es que un issue llega con el RED test y la causa raiz (hay que IMPLEMENTAR) y una feature
    exige inventar la API, el command spec, la UI y los locales (el modelo se queda leyendo).
17. **El test de regresion va en el archivo de test del AREA**, nunca en un archivo por bug
    (`AGENTS.md:24`, issue #3226). No hay un check automatico que lo detecte: lo detecta el
    maintainer en la revision.
18. **`Changes a default: no` es la forma EXACTA** que exige el parser del upstream
    (`scripts/pr-checks/pr-checks.js`). "Changes to default: no" no sirve. Y la POSICION NO
    importa: el parser de upstream es multilinea (`/…/im`), asi que la linea puede estar donde
    sea; lo que lo rompe es un code fence, un comentario HTML o backticks.
    leé el parser, no supongas.

### Sobre git y el repo

19. **Push SOLO al fork.** Nunca a `origin`, nunca force-push a `main`, nunca cambies de rama en el
    checkout principal.
20. **No toques el checkout principal ni el worktree de otro slot.** Cada agente tiene su worktree.
21. **La liveness de un lock es su EDAD y su dueno, nunca su PID.** Y liberá los slots: un token de
    build tomado sin proceso vivo bloquea la cola entera.
22. **Antes de abrir un PR, mira comments, assignees, timeline y PRs abiertos.** En duplicados gana
    el PR con numero menor. Un claim perdido no se descarta: se preserva el diff y los commits.

### Sobre la medicion

23. **Un solo build con 16 jobs es la peor opcion** (13,0 builds/h): el paralelismo interno de Rust
    tiene fases seriales (codegen de los crates grandes y el linkeo). Con 2 en paralelo: 20,3.
    Y el caso real de la cola es mejor: el primer gate compila frio y el segundo pega en el sccache
    -> 24,0 builds/h. Por eso la cola escalona los gates **90 s** (`GATE_STAGGER`): con 20 s los dos
    compilan frio.
24. **No midas sobre una caja ocupada.** El experimento tiene que esperar a que la caja este libre
    en tres chequeos seguidos, y si no, el numero es una mezcla del reparto y de la competicion.

---

## 3. Las reglas del repo que hay que respetar

- El claim se hace con un PR en draft; el bot asigna y etiqueta `in progress`. `/claim` solo para
Hacé stake del claim antes de tener rama.
- Un PR por tema. Push diario. Nunca force-push a `main`.
- El titulo y la primera frase tienen que entenderse sin ver el chat ni el issue.
- Una regresion va en el archivo de test del area.
- `cargo xtask ci` antes de cada commit; no cambies de rama mientras corre.
- Si mostras cambios observables, van con capturas reales, hechas por vos.

## 4. Instalarlo en otra PC

```bash
git clone <este-repo> ~/.local/share/solidcraft-orch
cd ~/.local/share/solidcraft-orch
mkdir -p targets logs locks gates state reports briefs baseline
cp bin/slot-target-dir.sh bin/ 2>/dev/null
```

### ⚠ Falta la otra mitad: `$LOOP_DIR`

Este repo es **la mitad ORCH**. La mitad **LOOP** —el publisher (`agent-issue.sh`), el
árbitro del claim (`claim-race.sh`), el freno (`claim-brake.sh`), el rescate
(`claim-salvage.sh`), el gate que compila (`gate-quick.sh`), el validador del body
(`pr-defaults-line.sh`), el GC de disco y el supervisor— vive en `$LOOP_DIR` y **no está en
git**.

Sin él, este repo **no publica, no gatea y no arbitra**: `bin/gate.sh:53` sale con rc=2
("the gate script is not there"). El inventario completo de esa mitad, qué la necesita y
qué se rompe sin ella está en [`docs/la-otra-mitad.md`](docs/la-otra-mitad.md).

Para comprobar qué falta en una máquina:

```bash
bash bin/preflight.sh
```

Los scripts que los crons ejecutan tienen que existir **antes** de que se cree el job
(ver "Los scripts que los crons ejecutan", más abajo).

Variables de entorno (el valor va en el entorno o en un .env que git ignora; **nunca en un archivo
versionado**):

```
GH_TOKEN=<token de GitHub con push y apertura de PRs>
SOLIDCRAFT_CONTROL_TOKEN=<token del control del daemon de SolidCraft>
```

Los scripts toman las rutas de variables con default, asi que en otra PC alcanza con:

```
ORCH_DIR=...  LOOP_DIR=...  SOLIDCRAFT_REPO=...  WORKTREES_DIR=...  HERMES_SCRIPTS=...
```

El default de cada uno (el de esta maquina, que la otra PC exporta):

```
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
HERMES_SCRIPTS="${HERMES_SCRIPTS:-/home/user/.hermes/scripts}"
```

Los crons (todos con `--no-agent`: no gastan tokens de LLM):

| cron | cada | script | para que |
|---|---|---|---|
| solidcraft-gate-queue | 3 min | gate-queue.sh | drena la cola de gates (2 a la vez) |
| solidcraft-pipeline | 5 min | pipeline.py | corrige bodies, encola gates, pasa a ready |
| solidcraft-comment-watch | 15 min | comment_watch.py | lee los comentarios del maintainer y arma la cola de tareas |
| solidcraft-nice-compilations | 2 min | nice-compilations.sh | baja la prioridad de las compilaciones nuevas |
| solidcraft-ping-ready | 30 min | ping-ready.sh | pide el `approved-for-ci` en los PRs listos |
| solidcraft-reporte-diario | 10 y 22 | daily-report.py | el reporte, sin LLM |

**`bin/crons.txt` es la fuente de esta tabla.** El grafo dice a qué nodo pertenece cada
cron y `bin/workflow-validate.py` comprueba que los dos digan lo mismo: un cron que
corre y no está en el registro no existe, y un cron del registro que no está en esta
tabla es un error del suite (`bin/test-workflow.sh`, casos 11a-11f). Antes había dos
grafos — el que `workflow.yaml` declaraba (2 crons) y el que el loop ejecutaba (5) — y
nadie lo comprobaba.

```bash
hermes cron create --name solidcraft-gate-queue --schedule '*/3 * * * *' \
  --script gate-queue.sh --no-agent --deliver local
hermes cron create --name solidcraft-pipeline --schedule '*/5 * * * *' \
  --script pipeline.py --no-agent --deliver local
```

Los scripts que los crons ejecutan viven en `HERMES_SCRIPTS` (`~/.hermes/scripts/`): el cron
los busca ahi, y el script tiene que existir ANTES de que el job se cree.

### Pedirle al maintainer el `approved-for-ci`

El CI de upstream tiene dos lanes. El LIVIANO corre en cada push. El PESADO (native tests,
native clippy, el build de tests) corre SOLO cuando un maintainer agrega el label
`approved-for-ci`: hasta ese momento upstream le da un quick compile en su lugar. Ese label solo
lo puede poner un maintainer, asi que es LA UNICA accion que necesitamos de el.

| script | para que |
|---|---|
| `bin/ping-ready.sh` | deja UN comentario por PR (idempotente, por head sha) pidiendo el label, e imprime el resumen |
| `bin/ping-ready-report.sh` | el mismo resumen SIN tocar GitHub (solo lee) |

```bash
bash bin/ping-ready.sh              # comenta los PRs listos e imprime el resumen
bash bin/ping-ready.sh --dry-run    # imprime lo que haria, sin comentar
bash bin/ping-ready-report.sh       # solo el resumen, sin tocar GitHub
```

El estado del CI de un head, en UNA linea, sale con `bin/ci-status.sh`:

```bash
bash bin/ci-status.sh 15188         # un numero de PR (se resuelve a su head sha)
bash bin/ci-status.sh --sha <sha>   # un sha
```

```
ESTADO=VERDE|ROJO|PENDIENTE SHA=<sha> CHECKS=<n> ROJO=<nombres|-> \
  PENDIENTE=<nombres|-> SOBRA=<nombres|-> DETALLE=<que pasa>
```

`ROJO` son los checks que fallaron, `PENDIENTE` los que todavia no tienen veredicto
(FALTAN) y `SOBRA` los que tienen un run superado (el `cancelled` que cancela al run
nuevo del mismo nombre: no es un rojo, es un run de mas). El codigo de salida es 0 si
verde, 1 si rojo, 2 si pendiente, 3 si el uso esta mal. El veredicto lo dice
`pipeline.evaluar_check_runs` (la MISMA regla que usan `ping-ready.sh` y `gate.sh`): el
helper no tiene una copia de la regla, la usa.

El ping CORRE SOLO: el cron `solidcraft-ping-ready` (cada 30 min, `--no-agent`, entrega
`local`) ejecuta la COPIA de `bin/ping-ready.sh` que vive en `~/.hermes/scripts/`. La copia
tiene que ser IDENTICA al canonico (`diff -q`), porque el cron no usa el repo: usa esa. El
script resuelve el orquestador por la REGLA DEL CI (el directorio que tiene `bin/pipeline.py`),
no por su propia ubicacion, asi que funciona igual desde el repo y desde la copia.

El cron entrega a `local` a proposito: el ping es una ACCION HACIA GITHUB, no un aviso. Al
usuario no le llega nada por Telegram. El script es idempotente por head sha, asi que correr de
mas no genera ruido: el comentario se deja UNA vez por PR y por sha.

LA TANDA de los pedidos `approved-for-ci`: el maintainer mergea EN GRUPOS POR AREA, asi que nunca
hay mas de `MAX_PEDIDOS` (2) pedidos EN CURSO a la vez (un pedido en curso = nuestro comentario de
ping para su head sha ACTUAL y sin el label); cuando uno se resuelve (el maintainer pone el
label, o el PR se mergea/cierra) entra el siguiente, elegido por el area con MAS PRs listos
primero y dentro del area el MAS ANTIGUO, y una valvula de 72 h abre UN lugar mas si el pedido mas
viejo sigue sin label (para que la cola no se trabe). El resumen dice la decision de cada PR:
`LISTO` (entra en la tanda), `EN-TURNO` (ya tiene un pedido), `ESPERA` (listo, tanda llena) o
`FALTA` (le falta algo de nuestro lado).

El resumen es una linea por PR, y es lo que el agente lee para decidir a quien pinguear:

```
<pr> <sha-corto> <n-atras> <si|no|desconocido> <verde|rojo|pendiente> <si|no> LISTO|FALTA <que falta>
```

- `<n-atras>` son los commits que la rama esta atras de main. Es DATO, no un bloqueo: upstream
  mergea muy rapido (81 commits nuevos en cinco horas el 2026-11-07), asi que exigir "0 atras"
  es una carrera que se pierde siempre. Sale igual, para que el agente lo sepa.
- `<si|no|desconocido>` es el CONFLICTO con main: `si` hay conflicto, `no` la rama mergea
  limpio, `desconocido` no se pudo medir. Lo decide `git merge-tree --write-tree --name-only
  <head-sha> origin/main` en el clon local de SolidCraft (rc=0 limpio, rc=1 conflicto). Si no se
  puede medir, el PR NO se pinguea (fallo seguro) y el resumen lo dice.
- El `<si|no>` que sigue es si el PR ya tiene el label `approved-for-ci`.
- `LISTO` significa que se pinguea. `que falta` dice que falta: `falta el label
  approved-for-ci` o `nada, listo para revisar`.

Lo que BLOQUEA el ping es solo esto: el CI del head SHA esta rojo o tiene un check en curso, o la
rama CONFLICTA con `origin/main`. Un `FALTA` dice que falta de NUESTRO lado. El script NO pide
merge: la merge es del maintainer. El estado del CI se lee de los check-runs del HEAD SHA agrupados
por nombre (gana el mas reciente), nunca del rollup: el rollup mezcla el `cancelled` de un run viejo
con el `success` del nuevo y muestra rojo un PR que esta verde.

## 5. Que NO se versiona (se regenera en cada PC)

`targets/ logs/ locks/ gates/ state/ state.json history.jsonl` son el estado de una maquina
concreta, no codigo. El `state.json` se REGENERA desde `state/` con `bin/merge-state.sh`; el
`--check` tiene que dar IDENTICO o hay que correr `--split --prefer-artifact` para adoptar la
edicion manual del `state.json`. Sin `--prefer-artifact` gana `state/` (la fuente) y el
`--split` muestra el diff antes de escribir: se ve que se descarta.

## 6. Pruebas

Las suites tienen que dar rc=0 antes de commitear cualquier cambio del orquestador. Se
corren todas con un comando:

```bash
bash bin/test-all.sh          # todas
bash bin/test-all.sh --fast   # solo las herméticas: las que corren en otra máquina
```

`bin/test-all.sh` reporta como **fallo** la suite que no pudo correr, no como un "skip": una
suite que no se puede correr no es un verde. Las dos que viven en el loop —y que por eso no
corren en otra máquina— son `/home/user/.local/share/solidcraft-loop/bin/test-gate-quick.sh`
y `.../test-rules.py`.

`bin/test-dup-scan.sh` mide el detector de duplicados por parche, con el contraste contra
`claim-verify.sh`: el competidor que describe el fallo en prosa es invisible para el guard del
claim y visible para el detector.

`bin/test-ci-status.sh` mide el helper del estado del CI: verde/rojo/pendiente con el codigo
de salida que corresponde, la resolucion de un numero de PR a su head sha, y el caso de la casa
(un `cancelled` viejo + un `success` nuevo del mismo nombre NO es un rojo). El stub de `gh`
APLICA el `--jq` de verdad, como el gh real: un stub que lo ignorara mediria el stub y no la
regla.

## 7. Estructura

```
bin/        los scripts (el grafo, la cola, el pipeline, los gates, los tests)
briefs/     los briefs literales que se le dan a los agentes
prompts/    el prompt que recibe el agente (wave-prompt.md)
docs/       las reglas, los traps y las lecciones (copia de los references de la skill)
reports/    las mediciones (paralelismo, tokens, imagenes, metricas de agentes)
baseline/   el catalogo de fallos preexistentes medidos
rules-snapshot/  los hashes de las reglas de upstream que este repo cita (bin/rules-sync.sh)
workflow.yaml   el grafo declarado del proceso
RULES.md    las reglas del orquestador
HANDOFF.md  el estado al empezar una sesion
```

`state/`, `state.json`, `targets/`, `logs/`, `locks/` y `gates/` **no están en el repo**:
son el estado de una máquina concreta y se regeneran en cada PC (ver §5).

## 8. Donde esta la fuente de verdad de cada cosa

- El grafo del proceso: `workflow.yaml`.
- El estado: `state/` (y `state.json` se reconstruye desde ahi).
- La cola de gates: `gates/queue.txt`.
- Los veredictos: `$LOOP_DIR/gates/<slot>/scope.verdict` (crudo) y `scope.effective.verdict` (el que cuenta).
- Las reglas y los traps: `docs/` y `RULES.md`.
