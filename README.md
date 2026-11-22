# solidcraft-orch

El orquestador que convierte issues de SolidCraft en PRs mergeados. Bash, Python y un par de
crons: no es una app, es un proceso. Todo el estado vive en disco, asi que sobrevive a un crash,
a un `/new` de sesion y a un SIGKILL.

Este README es tambien la guia de onboarding: **la seccion "Lo que NO hay que hacer" es la parte
mas importante del archivo** y esta escrita con las lecciones que costaron horas de trabajo.
Para arrancar una sesión: [`HANDOFF.md`](HANDOFF.md). Los resultados reales, las causas de
fondo y las decisiones del 2026-11-21:
[`reports/analisis-orquestador-2026-11-21.md`](reports/analisis-orquestador-2026-11-21.md).

---

## 1. El flujo, en una linea

Del issue al PR (2026-11-21): elegir -> claim (draft) -> causa raiz -> test RED -> fix ->
`cargo xtask fast` -> push -> gate (el CI de upstream en el fork) -> ready.
Cada paso es un proceso que puede morir y ser retomado; las aristas son condiciones sobre
archivos y sobre GitHub.

| paso | que hace | quien lo hace |
|---|---|---|
| elegir | el siguiente issue que vale un agente | `bin/next-issue.py`, desde la wave (cron 10 min) |
| preparar | lock, worktree, target y brief del slot | `bin/prepare-slot.sh` |
| claim | commit vacío, draft y verificación | el agente, con `bin/claim-verify.sh` |
| causa raiz, RED, fix | el trabajo, hasta `cargo xtask fast` en verde | el agente del slot (opencode) |
| gate | el CI de upstream sobre el head | `bin/fork-ci.sh`, despachado por `bin/pipeline.py` (cron 5 min) |
| ready | el PR pasa a revisión | el agente, o `bin/pipeline.py` |
| comentarios | los pedidos del maintainer, a una cola | `bin/comment_watch.py` (cron 15 min) -> `state/pending_tasks.json` |
| cerrar | borra worktree y target cuando el PR está arriba | `bin/close-slot.sh`, desde la wave |
| merge | review, `approved-for-ci`, merge queue | el maintainer |

El grafo esta DECLARADO en `workflow.yaml` (15 nodos, 18 aristas, 8 senales), se valida con
`bin/workflow-validate.py` y `bin/workflow-runner.sh --list` dice que nodos serian elegibles
ahora. El runner NUNCA ejecuta los nodos que compilan: esos los llevan los crons.
**Ojo (2026-11-21):** el grafo declarado todavía tiene el orden viejo (el draft después del
fix, el gate local como único gate, un pipeline que edita bodies). El validador comprueba los
crons y que los scripts existan, no el orden: lo que corre es lo de la tabla de arriba.

### Pausar y reanudar el loop (cuando necesitás la PC)

`bin/loop-pause.sh` (alias: `pausar`, `reanudar`, `estado`) toca solo los procesos del loop
—las sesiones de `bin/agent-turn.sh` y los gates—, nunca los builds propios del usuario:

```bash
bash bin/loop-pause.sh pause            # nada nuevo; lo que corre sigue corriendo
bash bin/loop-pause.sh pause --freeze   # ademas congela agentes y gates (SIGSTOP)
bash bin/loop-pause.sh pause --stop     # ademas los termina (SIGTERM)
bash bin/loop-pause.sh resume           # SIGCONT a lo congelado, borra la marca, reinstala el crontab
bash bin/loop-pause.sh status
```

- `pause` saca el bloque del crontab (`bin/install-crontab.sh --remove`) y escribe la marca
  `locks/loop-paused`; con la marca puesta, `bin/wave.sh` sale enseguida.
- `--freeze` libera la CPU al instante y no pierde nada, pero la RAM sigue tomada. Un
  congelamiento mas largo que el techo del agente (`AGENT_TIMEOUT_MIN`) termina ese turno al
  reanudar; lo pusheado queda.
- `--stop` libera CPU y RAM; se pierde lo que el turno no pusheo, y la wave retoma el slot
  guardado mas tarde.

---

## 2. Lo que NO hay que hacer

Cada punto es una leccion con su porque. Esta lista es la parte que hay que leer antes de tocar nada.

**Antes de cualquier cambio** en el fork, en upstream, en este repo, en el crontab o en
`$LOOP_DIR/config.env`, se le pregunta al usuario: vale para personas y para agentes. Un cambio
chico ahí tiene efectos que no se ven: al habilitar Actions en el fork se activaron los 17
workflows copiados de upstream, y en octubre uno creó una pre-release nightly en el fork y otros
actuaron sobre sus 57 issues.

### Sobre la maquina compartida

1. **No compiles fuera del token pesado.** El agente corre `cargo xtask fast` (lo pide el brief)
   y nunca el workspace entero a mano, con `nice -n 19`, `--profile ci` y el token:
   `bash bin/slot-lock.sh --heavy --take --wait 3600` antes y `--heavy --release` despues. Sin
   token se ha visto a 3-9 procesos de Cargo compitiendo por los locks y a dos agentes gastar
   2h29m cada uno sin dejar un solo commit.
2. **No uses `pkill`, `killall` ni `kill -9`.** Uno lo uso un subagente y mato una medicion de 3,5 h;
   en una maquina compartida un pkill puede matar gates, compilaciones y cronjobs ajenos. Para
   cortar TU build: guardá el PID cuando lo lanzas y hacele `kill -TERM` solo a ese. Para esperar a
   que se libere la caja: un loop con `pgrep -x cargo` / `pgrep -x rustc`, o `bin/build-slot.sh --status`.
3. **No edites in-place un script que se este ejecutando.** Los crons corren `pipeline.py` y
   `gate-queue.sh` cada 5 minutos y `wave.sh` cada 10. Editar un script mientras Bash lo lee
   produce errores de sintaxis a mitad de ejecucion. Siempre reemplazo atomico: `os.replace` o `mv`.
4. **No pongas un stub de una herramienta en un directorio que pueda estar en el PATH.** Un `gh`
   falso en un scratch hacia no-op en `pr create`: PRs que no existen y un pipeline que no publica
   nada sin avisar. Si testeas con stubs, que vivan fuera del PATH, y usá `GH_BIN` para fijar cual
   `gh` se usa.
5. **Una compilacion pesada a la vez en esta caja, y cada slot con su `CARGO_TARGET_DIR` propio.**
   El tope es `MAX_HEAVY_TOKENS=1` en `config.env`: con 15 GB de RAM, dos builds del motor piden
   ~10 GB de rustc entre los dos y el OOM killer se lleva el turno de un agente. Un target
   compartido hace que una compilacion borre los artefactos de otra en caliente
   (`failed to exec .../deps/...`): 2423 falsos fallos de una vez.
6. **`CARGO_INCREMENTAL=0`, siempre.** Con incremental los `rustc` no son cacheables y cada slot
   recompila las mismas dependencias: el sccache pasa de 0 hits a 19 con incremental apagado.

### Sobre los veredictos

7. **Un veredicto que no llega al exit code es peor que no tener veredicto.** El gate escribia
   ROJO (crudo) y el pipeline leia el efectivo; `merge-state.sh --check` reportaba diferencias y
   salia con rc=0; un test decia "3 casos fallan" y salia con rc=0. Regla: **todo script que falla
   devuelve rc distinto de 0**, y el que informa propaga el rc.
8. **Un fallo preexistente en `origin/main` NO es una regresion.** Si un test falla en
   `origin/main` con el mismo mensaje, no lo persigas: contalo como preexistente. En el gate
   propio (`LOCAL_GATE=quick`, el que nombra tests) el veredicto crudo sale ROJO por fallos que ya
   estan en la base, y el que cuenta es el **efectivo** (`scope.effective.verdict`), que
   `gate-baseline.sh` calcula separando lo preexistente de lo nuevo.
9. **El baseline se UNE, nunca se reemplaza.** Una union no puede reducir preexistentes. Y hay que
   unir todas las fuentes (el catalogo oficial `tests/KNOWN_FAILING_TESTS` + `origin/main` + el
   checkout principal + el worktree del slot): una fuente atrasada solo puede OMITIR fallos, y eso
   produce un rojo falso.
10. **El gate es el de upstream, no uno propio (2026-11-21).** El gate propio (`gate-quick.sh`:
    nextest con su scope y un baseline de 18 dias) dio un rojo falso en el PR #20017 mientras el
    "Native Linux tests" de upstream pasaba sobre el mismo head; antes ya habia sacado 1321 fallos
    falsos ("this build has no SMLib") por un scope sin `solidcraft-cli`. Por eso el gate es el CI
    de upstream corrido en el fork, o `cargo xtask fast`: que compilar y con que features lo
    decide upstream.
11. **Verifica los hechos contra el codigo, no de memoria.** Por ejemplo, los plazos del claim
    no son uno: son dos, y no son el mismo. En `scripts/claim/claim.js`: `CLAIM_HOURS = 72`
    (el bot libera un `/claim` sin PR a las 72 h) y `PR_IDLE_DAYS = 14` (libera un claim con
    draft despues de **14 dias sin pushes**). Aparte esta la regla para personas del
    CONTRIBUTING: un draft **sin pushes por 72 h** puede ser tomado por otro, que comenta
    primero. El CONTRIBUTING de hoy dice que son cosas separadas (verificado en `origin/main`
    el 2026-11-21). Conclusion: push diario.

### Sobre el trabajo

12. **El draft es el claim, y va PRIMERO.** Antes de una linea de codigo: commit vacio
    `claim: #N`, push al fork, draft `<resumen> (#N)` con `Fixes #N` y `Changes a default: no`
    en el body, y `bash bin/claim-verify.sh N --our-pr P` (0 nuestro; 1 perdido: se cierra el
    draft y se para; 2 no se sabe: se para). Por que: con el draft al final, la ventana de
    carrera duraba toda la corrida del agente (40 min o mas), y asi se perdieron #18686 y
    #18691; de los 20 PRs cerrados sin merge, unos 11 fueron claims ganados por otro PR,
    duplicados o "ya cubierto".
13. **El test RED va antes del fix.** El entregable minimo de quien investiga es el test RED
    commiteado y pusheado. Con RED, el fix es corto; sin RED, el agente se come el turno
    explorando y no entrega nada.
14. **El brief es corto y no copia lo que el agente lee en disco.** `prompts/agent-brief.md`
    (~2,5 KB) manda a `.agents/skills/solidcraft-full-stop/SKILL.md` de upstream y dice solo lo
    que es distinto aca; el ultimo mensaje del agente es UN JSON `{"verdict":
    "ready|waiting|blocked", ...}`. El brief de cada slot (`prompts/agent-<N>.md`) se renderiza
    SIEMPRE desde la plantilla, nunca se reusa: el viejo del slot 19690 le pedia al agente
    `rm -rf` de su target y `git worktree remove --force`, con el gate en cola usandolos. Lo
    propio de un slot va en `prompts/repair-<N>.md`, que se agrega al final.
15. **El agente tiene techo de tiempo, no de iteraciones** (`AGENT_TIMEOUT_MIN`, ver §4): un
    agente de 250 iteraciones llego a costar ~$1,17 sin dejar un commit. Y un despacho nuevo
    NUNCA retoma una sesion vieja con la cache fria (lo dice el CONTRIBUTING de upstream).
16. **Solo issues, no features.** Medido en el loop: un issue cuesta $0,25 y 16 h de agente por
    entrega; una feature, $1,90 y 138 h, con un 86% de probabilidad de cancelarse. El motivo no es el
    precio: es que un issue llega con el RED test y la causa raiz (hay que IMPLEMENTAR) y una feature
    exige inventar la API, el command spec, la UI y los locales (el modelo se queda leyendo).
    `bin/next-issue.py` las descarta.
17. **El test de regresion va en el archivo de test del AREA**, nunca en un archivo por bug
    (`AGENTS.md` de upstream, issue #3226). No hay un check automatico que lo detecte: lo detecta
    el maintainer en la revision.
18. **`Changes a default: no` es la forma EXACTA** que exige el parser del upstream
    (`scripts/pr-checks/pr-checks.js`). "Changes to default: no" no sirve. Y la POSICION NO
    importa: el parser de upstream es multilinea (`/…/im`), asi que la linea puede estar donde
    sea; lo que lo rompe es un code fence, un comentario HTML o backticks. Leé el parser, no
    supongas.

### Sobre git y el repo

19. **Push SOLO al fork.** Nunca a `origin`, nunca force-push a `main`, nunca cambies de rama en el
    checkout principal.
20. **No toques el checkout principal ni el worktree de otro slot.** Cada agente tiene su worktree.
21. **La liveness de un lock es su EDAD y su dueno, nunca su PID.** Y liberá los slots: un token de
    build tomado sin proceso vivo bloquea la cola entera.
22. **La regla del claim es UNA: `bin/claim_rule.py`**, la union de `scripts/claim/claim.js` y
    `scripts/pr-checks/pr-checks.js` de upstream, probada contra el JS de verdad con node
    (`bin/test-claim-rule.py`). Antes habia cuatro copias, y una contaba como libre un
    `Fixes #N` dentro de un bloque de codigo que el bot si cuenta. Gana el PR abierto de numero
    menor. Un claim perdido no se descarta: el diff y los commits quedan en el fork.

### Sobre la medicion

23. **El paralelismo se mide en la caja donde va a correr.** En la caja vieja (16 cores, 62 GB,
    2026-11-04, `reports/experimento-paralelismo-lectura.md`) un solo build con 16 jobs daba
    13,0 builds/h y dos en paralelo 20,3 (24,0 con el segundo pegando en el sccache, de ahi el
    `GATE_STAGGER` de **90 s** de la cola). En esta caja
    (12 cores, 15 GB) manda la RAM: un build pesado a la vez (regla 5).
24. **No midas sobre una caja ocupada.** El experimento tiene que esperar a que la caja este libre
    en tres chequeos seguidos, y si no, el numero es una mezcla del reparto y de la competicion.

### Sobre el trabajo que no esta en git

25. **El gate compila el worktree del slot, o no compila.** La cola caia al checkout principal
    cuando el worktree del slot no estaba (`cd "$WORKTREES_DIR/issue-$issue" || cd
    "$SOLIDCRAFT_REPO"`): el gate compilaba un arbol que NO contenia el cambio y escribia un
    veredicto que decia que si, y `bin/verify-pr.sh` lo leia como "el gate de este pull
    request". El gate se niega (rc=5) y la cola tambien: un gate que va a fallar no se
    lanza. Y desde el 2026-11-21 el gate exige que el HEAD del worktree sea el sha pedido y
    el arbol este limpio (rc=7). La cola **no sale con 0** si no pudo gatear: un cron verde
    sobre gates que no corrieron es peor que un rojo.
26. **Una maquina empieza con `--bootstrap`, no con un `state.json` escrito a mano.** El
    `--split` exige un `state/manifest.json` previo y, sin el, se negaba con un mensaje que
    no decia como arreglarlo. `bin/merge-state.sh --bootstrap` crea el estado, el manifiesto,
    un archivo por concepto (incluso los grupos vacios) y el hash, con los grupos en su
    lugar: sin el manifiesto con los grupos puestos, TODAS las claves caen en `notes.json`
    y el estado partido por concepto no sirve de nada. No pisa un estado que ya existe
    (rc=3).
27. **El trabajo que existe en una sola maquina es un commit que no existe para nadie.** La
    pregunta es **"este trabajo MIO esta en el fork?"**, y la base de la comparacion es el
    `main` del **upstream**, no el del fork: el `fork/main` esta miles de commits atrasado
    (el fork solo recibe lo que uno mergea en el), asi que medir contra el fork contaba
    toda la historia del upstream como trabajo nuestro — 83 ramas "en riesgo" con 4323
    commits cada una, cuando el trabajo real eran 5 commits de una. `bash
    bin/branch-risk.sh` dice las tres cosas sin confundirlas: **EN RIESGO** (el commit no
    esta en ningun ref del fork: existe solo en ese disco), **SALVADA** (el commit esta en
    GitHub bajo otro nombre: el trabajo esta a salvo, el nombre no) y **mergeada**. Sale con
    rc=1 si hay trabajo que solo existe en ese disco.

---

## 3. Las reglas del repo que hay que respetar

Las reglas son las de upstream y se leen ahi, no aca: `AGENTS.md`, `CONTRIBUTING.md` y
`.agents/skills/*/SKILL.md` en `origin/main` (`git -C "$SOLIDCRAFT_REPO" show origin/main:<ruta>`).
[`RULES.md`](RULES.md) es un puntero corto con las seis reglas propias del orquestador.
`rules-snapshot/SHA256SUMS` guarda los hashes de lo que el orquestador cita: `bash
bin/rules-sync.sh` dice si upstream lo movio, y `bash bin/rules-snapshot.sh --update` registra
el cambio despues de leerlo.

Las que mas muerden (verificadas en `origin/main` el 2026-11-21):

- El claim se hace con un PR en draft (`#N` en el titulo, `Fixes #N` en el body); el bot
  asigna y etiqueta `in progress`. Gana el PR abierto de numero mas bajo. Push diario.
- Un PR por tema. Nunca force-push a `main`.
- El titulo y la primera frase tienen que entenderse sin ver el chat ni el issue.
- Una regresion va en el archivo de test del area.
- `cargo xtask fast` antes de cada commit; el CI corre el gate entero (`AGENTS.md` ya no pide
  `cargo xtask ci` en local).
- Si mostras cambios observables, van con capturas reales, hechas por vos.
- `approved-for-ci` lo pone el maintainer despues de revisar: no se pide (ver §4).

## 4. Como corre hoy (2026-11-21)

### El agente del slot

`bin/dispatch-slot.sh` corre `bin/agent-turn.sh` en el worktree del slot, con las variables de
la caja (`CARGO_TARGET_DIR` del slot, `CARGO_INCREMENTAL=0`, `MAX_HEAVY_TOKENS=1`, poca
prioridad). El turno es un opencode:

```
opencode run --standalone --auto --format json --title issue-N -m <modelo> --agent <agente> "<brief>"
```

- El binario, el modelo y el agente salen de `bin/agent-env.sh`, que lee la politica de la
  maquina (`$LOOP_DIR/config.env`), y el techo del turno es `AGENT_TIMEOUT_MIN` (180; rc=124).
- Los eventos del agente (con sus tokens) van a `logs/<N>-wave.jsonl`; lo que dicen los
  scripts, a `logs/<N>-wave.log`. La sesion se encuentra con `opencode session list`.
- Los empujones: `opencode run` termina cuando el modelo escribe texto sin llamar a una
  herramienta, aunque anuncie el paso siguiente (el primer agente del brief nuevo, slot 19690,
  termino asi a los 51 minutos, sin veredicto ni push). Sin el JSON del veredicto, la MISMA
  sesion recibe hasta `AGENT_NUDGES` (2) empujones enseguida, con la cache todavia caliente.
- `--standalone` (un servidor privado): el 20-11 el gateway compartido se murio y se llevo los
  turnos de los agentes.

Hasta el 2026-11-21 el agente y los crons eran de hermes; hermes se fue para siempre.

### La wave: el loop que corre sin nadie

El cron `solidcraft-wave` (cada 10 minutos, `bin/wave.sh`) es la parte del loop que **no
necesita a una persona**. En cada turno, en orden:

1. **Cierra** los slots cuyo trabajo ya es un PR y cuyo agente ya no trabaja, y libera los
   locks de los slots muertos sin PR (la rama queda en el fork).
2. **Mira las reglas** con `bin/rules-sync.sh`. Si upstream cambio `scripts/claim/claim.js`,
   `scripts/pr-checks/pr-checks.js` o la plantilla del PR, **no despacha** hasta que alguien lo
   revise y corra `bin/rules-snapshot.sh --update`: esas reglas estan escritas en el codigo del
   orquestador. Si solo cambio `AGENTS.md`, `CONTRIBUTING.md` o las skills, registra el
   snapshot y sigue: el agente las lee en vivo de su worktree, que nace de `origin/main`.
3. **Retoma** los slots guardados: el trabajo a medias en el fork vale mas que un issue nuevo.
   Despues de 3 fallos seguidos (`WAVE_MAX_RESUME_FAILS`) deja de reintentar uno y lo mira un
   humano (`resume_last_error` en su estado). Un slot cuya ficha dice que la causa esta en el
   kernel se aparca (`parked-kernel`; `prepare-slot.sh` sale con 6): la rama y el PR quedan.
4. **Arranca** issues nuevos en los slots libres, con la lista TRIED de lo que ya probo en el
   turno (`next-issue.py --exclude`), y corta a los 3 fallos del turno (`WAVE_MAX_FAILS`).

Lo que la wave NO toca: un slot cuyo agente esta trabajando. "El PR existe" no es "el trabajo
esta terminado": un agente que abrio el PR sigue trabajando en el (el CI, la evidencia). La
vivencia se comprueba con `bin/slot-busy.sh`: un proceso dentro del worktree del slot o de su
target. `bash bin/wave.sh --dry-run` dice que haria.

### Como se elige el issue

- `bin/gh_snapshot.py`: una foto de TODOS los issues y PRs abiertos de upstream (GraphQL
  paginado) en `state/cache/gh-snapshot.json`; la completa tarda ~100 s y ~222 puntos, el
  refresco ~4 s. Antes el selector veia 150 de ~6800 issues (el 2 %).
- `bin/next-issue.py`: los filtros de [`docs/issue-selection.md`](docs/issue-selection.md)
  (kernel, labels, Drawings, features, varios temas, sin reproduccion) y un puntaje que
  prefiere los diffs chicos: los PRs de 80 lineas o menos se mergean en 20,7 h de mediana y los
  de mas de 300 en 96 h. `--list`, `--explain N`, `--exclude N,M`.
- `bin/issue-card.py`: la ficha de cada issue (`state/cards/<N>.json`). La mitad gratis busca
  con `git grep` los textos de error que cita el issue y da `kernel_cause` si caen en el codigo
  aparcado o si el error nombra a solidcore; la otra mitad es UN `opencode run` barato con un
  JSON fijo (~$0,002). El veto del maintainer solo cuenta con una cita textual de un comentario
  OWNER/MEMBER/COLLABORATOR. La wave exporta `NEXT_ISSUE_TRIAGE=1`: a lo sumo 5 fichas con
  modelo cada 10 minutos.

El claim: reglas 12 y 22. `bin/claim-verify.sh <issue> [--our-pr P] [--snapshot FILE]`
conserva su CLI: 0 nuestro, 1 perdido u ocupado, 2 no se sabe, y una linea `VEREDICTO=`.

### El gate

`GATE_MODE=fork-ci` (en `config.env`) es el gate de hoy: `bin/pipeline.py` despacha con
`bin/fork-ci.sh` el `ci.yml` de upstream en el fork `vdirienzo/solidcraft`, en los runners
gratis de GitHub (variables del fork `CI_RUNNER=ubuntu-24.04` y
`CI_RUNNER_WINDOWS=windows-latest`, como dice el CONTRIBUTING de upstream), UNA vez por head
sha. `bash bin/fork-ci.sh <issue|rama> --status` lo lee en una linea
(`FORKCI=VERDE|ROJO|PENDIENTE|NINGUNO`). En el fork solo esta activo `ci.yml`: los otros 16
workflows de upstream estan apagados con `gh workflow disable`, porque en octubre crearon una
pre-release nightly en el fork y etiquetaron sus issues.

`GATE_MODE=local` es la alternativa: el pipeline encola en `bin/gate-queue.sh` (un `flock`
sobre `gates/queue.flock`; un sha nuevo del mismo slot reemplaza al viejo en la cola) y
`bin/gate.sh` corre `cargo xtask fast --base origin/main` en el worktree del slot.
`LOCAL_GATE=quick` deja el `gate-quick.sh` viejo (reglas 8 a 10). El veredicto local queda en
`$LOOP_DIR/gates/<slot>/scope.verdict`.

### El pipeline

`bin/pipeline.py` (cada 5 minutos): para cada PR nuestro en draft, despacha el gate si su head
no tiene uno, y lo pasa a ready cuando el gate esta verde, el CI de GitHub del head esta verde
y el body tiene la linea `Changes a default:` (la escribe el autor, nunca el pipeline). Al
pasarlo a ready le saca el ` (#N)` del titulo (`solidcraft-file-pr`: el merge agrega `(#PR)`;
el `Fixes #N` del body sigue sosteniendo el claim). Lo que NO hace (2026-11-21): no edita
bodies (`gh pr edit --body` vuelve a correr los checks de upstream), no deja comentarios de
estado ("No status comments", `solidcraft-babysit-pr`) y no toca un PR que el agente ya paso
a ready.

### `approved-for-ci`: lo pone el maintainer, no se pide

El CI de upstream tiene dos lanes. El LIVIANO corre en cada push. El PESADO (native tests,
native clippy, el build de tests) corre SOLO cuando un maintainer agrega el label
`approved-for-ci`, despues de revisar. La guia de upstream
(`.agents/skills/solidcraft-babysit-pr/SKILL.md`) dice "Don't ask again and again" y "No status
comments": por eso el cron `solidcraft-ping-ready` salio del registro (2026-11-21) y el modo
de `bin/ping-ready.sh` que comenta no se usa. Para LEER, sin tocar GitHub:

```bash
bash bin/ping-ready.sh --report     # una linea por PR (o bin/ping-ready-report.sh)
bash bin/ci-status.sh 15188         # el CI de un head en una linea (o --sha <sha>)
```

En el resumen, los commits que la rama esta atras de main son DATO, no un bloqueo (81 commits
en cinco horas el 2026-11-07): lo que importa es el CONFLICTO, que mide `git merge-tree
--write-tree --name-only <head> origin/main`. `ci-status.sh` sale con 0 verde, 1 rojo, 2
pendiente, 3 uso mal.

El estado del CI se lee de los check-runs del HEAD SHA agrupados por nombre (gana el mas
reciente), nunca del rollup: el rollup mezcla el `cancelled` de un run viejo con el `success`
del nuevo y muestra rojo un PR que esta verde. La regla es UNA, `pipeline.evaluar_check_runs`,
y la usan `ci-status.sh`, `ping-ready.sh`, `fork-ci.sh` y `verify-pr.sh`.

### Metricas y alertas

- `bin/daily-report.py` cuenta los PRs desde GitHub (hasta 2000) y tiene una seccion de 7
  dias: mergeados, mediana de horas hasta el merge, claims perdidos, corridas de agente, tokens
  y $ por PR mergeado (de los eventos `step_finish` de opencode en `logs/<N>-wave.jsonl`) y
  los PRs que esperan al maintainer.
- `bin/loop-status.py` imprime `ALERTA` arriba de todo y sale con 2 cuando no se despacho nada
  en 2 h con slots libres, un cron repite el mismo error, un slot "corriendo" no tiene agente
  o quedan menos de 15 GB de disco. Antes el estado decia "todo bien" con el loop parado.

### La maquina

12 cores y 15 GB de RAM. `IMPLEMENT_SLOTS=1` por ahora: se sube a 2 cuando el primer PR del
brief nuevo se vea bien (y se mide con `daily-report.py` y `loop-status.py`). Una fase pesada
a la vez (regla 5). El kernel no se compila aca: se vetan los issues de `crates/kernel` y
`solidcore/`. Upstream si acepta ese trabajo; el veto es nuestro, por la maquina.

## 5. Instalarlo en otra PC

```bash
git clone <este-repo> ~/.local/share/solidcraft-orch
cd ~/.local/share/solidcraft-orch
mkdir -p targets logs locks gates state reports briefs baseline
# el estado de una maquina nueva (idempotente: no pisa uno que ya exista)
bash bin/merge-state.sh --bootstrap
bash bin/merge-state.sh --check     # tiene que dar rc=0
```

`--bootstrap` es el **unico** camino para empezar: antes habia que escribir el manifiesto a
mano, y sin los grupos en su lugar todas las claves caian en `notes.json`. Ver la regla 26.

### La otra mitad: `$LOOP_DIR` (dónde está el código y dónde el runtime)

La mitad **LOOP** —el publisher (`agent-issue.sh`), el árbitro viejo del claim
(`claim-race.sh`), el gate viejo (`gate-quick.sh`), el validador del body
(`pr-defaults-line.sh`) y el GC de disco— **está versionada en este repo**, en
[`loop/`](loop/) (desde `149f7fa`, 2026-11-18: antes vivía fuera de git, en `$LOOP_DIR`, y no
se podía reconstruir). Borrar `loop/` quedó para después: `gate.sh` (`LOCAL_GATE=quick`),
`publish-pr.sh` (`pr-defaults-line.sh`) y `run-issue-scope.sh` todavía lo usan.

Lo que sigue siendo **de cada máquina** es el runtime: los veredictos del gate
(`$LOOP_DIR/gates/`), los logs, los worktrees de los slots y el `config.env` (la política de
esta máquina: `GATE_MODE`, `IMPLEMENT_SLOTS`, el modelo, los techos). Por eso `$LOOP_DIR` sigue
siendo una variable con default, y por eso el runtime tiene que **apuntar** al código
versionado. En una máquina nueva, una vez:

```bash
LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
mkdir -p "$LOOP_DIR"
ln -s "$ORCH_DIR/loop/bin"     "$LOOP_DIR/bin"      # el codigo versionado
ln -s "$ORCH_DIR/loop/prompts" "$LOOP_DIR/prompts"  # los prompts del loop
cp "$ORCH_DIR/loop/config.env.example" "$LOOP_DIR/config.env"   # la politica de la maquina
```

Sin esos enlaces `bin/publish-pr.sh` sale con rc=6 ("el check de la linea de los defaults no
esta ahi"), `bin/verify-pr.sh` no puede validar esa linea y el gate viejo sale con rc=2. El
inventario de esa mitad, qué la necesita y qué se rompe sin ella está en
[`docs/la-otra-mitad.md`](docs/la-otra-mitad.md) (es el inventario del 2026-11-17, cuando la
mitad todavía no estaba en git). `bash bin/preflight.sh` dice qué falta en una máquina
(opencode, `gh`, el crontab y su PATH, la mitad LOOP).

El runtime del loop es **opencode** (el agente de los slots) y el **crontab del usuario**
(el planificador). El crontab se instala una vez, con el registro como fuente:

```bash
bash bin/install-crontab.sh            # instala los ocho jobs (idempotente)
bash bin/install-crontab.sh --dry-run  # dice lo que haria
bash bin/install-crontab.sh --remove   # saca los jobs
```

El bloque que instala define `PATH` con los directorios donde la maquina tiene `gh`,
`opencode` y `cargo` (cron arranca con `/usr/bin:/bin`, y sin ellos la wave arrancaba cero
agentes sin decir por que), corre los `.py` con `python3` y corre **el script del repo**, no
una copia: un cambio llega al cron al instante. Cada job escribe su log en
`logs/cron-<job>.log`: un cron que falla en silencio es un cron que no existe.

Variables de entorno (el valor va en el entorno o en un .env que git ignora; **nunca en un archivo
versionado**):

```
GH_TOKEN=<token de GitHub con push y apertura de PRs>
SOLIDCRAFT_CONTROL_TOKEN=<token del control del daemon de SolidCraft>
```

Los scripts toman las rutas de cuatro variables con default (el de esta maquina); la otra PC
exporta las suyas:

```
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
```

Los crons (ninguno llama a un modelo, salvo la wave: sus fichas y sus agentes):

| cron | cada | script | para que |
|---|---|---|---|
| solidcraft-gate-queue | 5 min (3,8,13…) | gate-queue.sh | drena la cola de gates locales (solo con `GATE_MODE=local` hay cola) |
| solidcraft-pipeline | 5 min (2,7,12…) | pipeline.py | despacha el gate, pasa a ready (sin editar bodies) |
| solidcraft-comment-watch | 15 min (4,19,34,49) | comment_watch.py | lee los comentarios del maintainer y arma la cola de tareas |
| solidcraft-nice-compilations | 10 min (1,11,21…) | nice-compilations.sh | baja la prioridad de las compilaciones nuevas |
| solidcraft-reporte-diario | 16 y 46 | daily-report.py | el reporte, sin LLM |
| solidcraft-gc-disk | 30 min (14,44) | gc-disk.sh | limpia el disco: artefactos y targets muertos |
| solidcraft-loop-status | 30 min (6,36) | loop-status.py | el estado del loop y sus alertas, sin LLM |
| solidcraft-wave | 10 min (0,10,20…) | wave.sh | la wave: cierra los slots terminados y arranca los agentes libres |

**Ningún par de crons cae en el mismo minuto** (2026-11-20): el orden dentro del
ciclo importa — la wave despacha a los `:00`, el pipeline despacha los gates a los `:02` y
la cola los saca a los `:03` — y los crons amontonados en el mismo minuto llegaron a tumbar
el planificador viejo (se iban los crons y los turnos de los agentes).

**`bin/crons.txt` es la fuente de esta tabla.** El grafo dice a qué nodo pertenece cada
cron y `bin/workflow-validate.py` comprueba que los dos digan lo mismo: un cron que
corre y no está en el registro no existe, y un cron del registro que no está en esta
tabla es un error del suite (`bin/test-workflow.sh`, casos 11a-11f). Antes había dos
grafos — el que `workflow.yaml` declaraba (2 crons) y el que el loop ejecutaba (5) — y
nadie lo comprobaba.

## 6. Que NO se versiona (se regenera en cada PC)

`targets/ logs/ locks/ gates/ state/ state.json history.jsonl` son el estado de una maquina
concreta, no codigo; tambien los briefs renderizados de cada slot (`prompts/agent-<N>.md`,
`prompts/repair-<N>.md`). El `state.json` se REGENERA desde `state/` con
`bin/merge-state.sh`; el `--check` tiene que dar IDENTICO o hay que correr `--split
--prefer-artifact` para adoptar la edicion manual del `state.json`. Sin `--prefer-artifact`
gana `state/` (la fuente) y el `--split` muestra el diff antes de escribir: se ve que se
descarta. Una maquina **nueva** empieza con `bash bin/merge-state.sh --bootstrap`, que no pisa
un estado que ya existe (rc=3; regla 26).

## 7. Pruebas

Las suites tienen que dar rc=0 antes de commitear cualquier cambio del orquestador. Se
corren todas con un comando:

```bash
bash bin/test-all.sh          # todas
bash bin/test-all.sh --fast   # solo las herméticas: las que corren en otra máquina
```

Con `--fast` (2026-11-21): 34 suites pasan, 0 fallan y se saltan 5 (las que necesitan un
checkout de SolidCraft o un directorio de deploy). Sin `--fast`, `bin/test-all.sh` reporta
como **fallo** la suite que no pudo correr, no como un "skip": una suite que no se puede correr
no es un verde.

`bin/test-guard.sh` hace que una suite que escribe estado se niegue a correr (rc=2) contra el
orquestador vivo: el 20-11-2026 `bin/test-orch-state.sh` escribio su fixture sobre el
`history.jsonl` de verdad y borro el historial del loop.

`bin/test-claim-rule.py` corre el `claim.js` y el `pr-checks.js` de upstream con node sobre
las mismas entradas que `bin/claim_rule.py` y exige el mismo resultado.

`bin/test-ci-status.sh` mide el caso de la casa (un `cancelled` viejo + un `success` nuevo del
mismo nombre NO es un rojo), con un stub de `gh` que APLICA el `--jq` de verdad: un stub que lo
ignorara mediria el stub y no la regla. `bin/test-dup-scan.sh` mide el detector de duplicados
por parche: el competidor que describe el fallo en prosa es invisible para el guard del claim.

`bin/test-portability.sh` mide la regla de **portabilidad**: todo script que use
`ORCH_DIR`, `LOOP_DIR`, `SOLIDCRAFT_REPO` o `WORKTREES_DIR` tiene que
definirla con un default. Un script que usa una de esas variables sin definirla corre con una
ruta VACIA en la otra PC, y falla ahi, no aca. El check mira tambien que el README y las
reglas esten donde el codigo dice.

`bash bin/rules-sync.sh` (`git fetch origin` y los hashes de `rules-snapshot/SHA256SUMS`) no
compila: exit 1 con la lista si upstream movio una regla citada, y `bin/rules-snapshot.sh
--diff` la muestra. Los checks estaticos de upstream (`cargo xtask layers`, `mesh-decisions`,
`ui-containers`, `lists`, `skills`) ya no tienen script propio: `bin/gate-structural.sh` se
borro el 2026-11-21 porque nadie lo llamaba, y esos checks corren en el CI de upstream, que con
`GATE_MODE=fork-ci` es el gate.

## 8. Estructura

```
bin/        los scripts (la wave, la seleccion, el claim, el pipeline, los gates, los tests)
loop/       la mitad LOOP, versionada (el publisher y el gate viejos; ver §5)
prompts/    la plantilla del brief (agent-brief.md); los briefs de cada slot se renderizan ahi
briefs/     los briefs escritos a mano del flujo viejo (hasta el 2026-11-18)
docs/       las reglas, los traps y las lecciones (copia de los references de la skill)
reports/    las mediciones y los analisis (paralelismo, tokens, imagenes, el del 2026-11-21)
baseline/   el catalogo de fallos preexistentes medidos
rules-snapshot/  los hashes de las reglas de upstream que este repo cita (bin/rules-sync.sh)
workflow.yaml   el grafo declarado del proceso
RULES.md    el puntero a las reglas de upstream y las seis propias
HANDOFF.md  el estado al empezar una sesion
```

`state/`, `state.json`, `targets/`, `logs/`, `locks/` y `gates/` **no están en el repo**:
son el estado de una máquina concreta y se regeneran en cada PC (ver §6).

## 9. Donde esta la fuente de verdad de cada cosa

- Las reglas: upstream (`AGENTS.md`, `CONTRIBUTING.md`, `.agents/skills/` en `origin/main`);
  `RULES.md` solo apunta ahi y lista las propias. Los hashes de lo que se cita:
  `rules-snapshot/` (lo verifica `bash bin/rules-sync.sh`).
- La regla del claim: `bin/claim_rule.py`.
- El grafo del proceso: `workflow.yaml` (con el orden viejo: ver §1).
- Los crones: `bin/crons.txt` (y la tabla del README tiene que coincidir: lo comprueba
  `bin/workflow-validate.py`).
- La politica de la maquina (gate, slots, modelo, techos): `$LOOP_DIR/config.env`.
- El estado: `state/` (y `state.json` se reconstruye desde ahi). Una maquina nueva se crea
  con `bash bin/merge-state.sh --bootstrap`. El estado vivo se lee con `bash bin/orch-state.sh`.
- Los veredictos: el CI del fork (`bash bin/fork-ci.sh <issue> --status`); el gate local en
  `$LOOP_DIR/gates/<slot>/scope.verdict` (y `scope.effective.verdict` con `LOCAL_GATE=quick`).
- La cola de gates locales: `gates/queue.txt`.
- Los traps y las lecciones: `docs/`.
- La mitad LOOP: [`loop/`](loop/) (su inventario: [`docs/la-otra-mitad.md`](docs/la-otra-mitad.md)).
  Que falta en esta maquina: `bash bin/preflight.sh`.
- El trabajo que solo existe en una maquina: [`docs/work-at-risk.md`](docs/work-at-risk.md).
  El gate que lo dice: `bash bin/branch-risk.sh` (rc=1 = hay commits que solo estan en
  ese disco; la base es el `main` del upstream, ver la regla 27).
