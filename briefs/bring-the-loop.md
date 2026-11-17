# Brief: traer la mitad LOOP del orquestador a este repo

**Para el agente de la PC que tiene el orquestador completo** (la maquina donde corren los
crons, donde esta `$LOOP_DIR` y donde el publisher abre los pull requests).

**Un solo objetivo:** que este repo tenga **todo** el orquestador, versionado, y que la
maquina quede andando como antes. La mitad que falta es la que vive fuera de git.

---

## 1. Que hay y que falta

El repo `vdirienzo/solidcraft-orch` tiene la mitad **ORCH** (la que esta versionada). La
mitad **LOOP** vive en `$LOOP_DIR` (por defecto
`/home/user/.local/share/solidcraft-loop`) y **no esta en git**: por eso el repo se puede
clonar en otra PC y no puede publicar, ni gatear, ni arbitrar.

**El inventario de lo que falta esta en `docs/la-otra-mitad.md` de este repo.** Leelo
primero: es la lista con lo que hace cada cosa, quien la necesita y que se rompe sin ella.

| Falta | Que hace | Quien lo necesita |
|---|---|---|
| `bin/agent-issue.sh` | **el publisher**: corre el modelo, toma el lock, hace el fix, abre el PR | `bin/run-issue-scope.sh`, `bin/launch-wave.sh`, `bin/launch-slot-service.sh`, `bin/launch-resume.sh` |
| `bin/claim-race.sh` | arbitro del claim (hoy con su propia regla, que NO es la del repo) | `bin/claim-verify.sh` |
| `bin/claim-brake.sh` | el freno: convierte el veredicto en exit codes | el publisher, antes del modelo y en el push |
| `bin/claim-salvage.sh` | el rescate: guarda el trabajo de un claim perdido | el publisher, cuando el freno dice que se perdio |
| `bin/gate-quick.sh` | **el gate que compila** y escribe el verdict | `bin/gate.sh:53` sale con rc=2 sin el |
| `bin/pr-defaults-line.sh` | el validador del body del PR | `bin/publish-pr.sh`, `bin/verify-pr.sh` |
| `bin/gc-disk.sh` | el GC de disco (el tope de GB de `targets/`) | el supervisor |
| `bin/supervisor.sh` | el supervisor de los corredores | los crons |
| `config.env` | la configuracion de la maquina | todos |
| `prompts/agent-issue.md` | el prompt que recibe el agente del publisher | `agent-issue.sh` |
| `bin/test-gate-quick.sh`, `bin/test-rules.py` | las suites del LOOP | el gate |

---

## 2. Las reglas (no son negociables, y son las del repo donde vas a trabajar)

De `RULES.md` y `README.md` de este repo. **Leelos enteros antes de tocar nada.**

1. **Nunca `pkill`, `killall` ni `kill -9`** (maquina compartida: matan gates y crons
   ajenos). Para cortar TU build: guardá el PID y `kill -TERM` solo a ese.
2. **Nunca edites in-place un script que se este ejecutando.** Reemplazo atomico
   (`os.replace` / `mv`). Los crons corren `pipeline.py` cada 5 min y `gate-queue.sh`
   cada 3.
3. **No compiles Rust desde un agente.** La cola de gates compila, de a dos. Un agente que
   compila compite por los locks de Cargo: se ha visto a 3-9 procesos concurrentes y a dos
   agentes gastar 2h29m cada uno sin dejar un solo commit.
4. **El GATE es serializado.** Turno con `bash bin/slot-lock.sh --heavy --take --wait 3600`,
   y se suelta despues. **Un gate a la vez, siempre.**
5. **`CARGO_INCREMENTAL=0` siempre**, y **un `CARGO_TARGET_DIR` por slot** (el del agente y
   el del gate de ese slot). Un target compartido hace que una compilacion borre los
   artefactos de otra en caliente.
6. **El veredicto tiene que llegar al exit code.** Todo script que falla devuelve rc != 0, y
   el que informa propaga el rc. Un check que no pudo correr **no es un rojo**: rc=6 es
   UNKNOWN, nunca "no".
7. **La liveness de un lock es su EDAD y su DUENO, nunca su PID.**
8. **Push SOLO al fork** de SolidCraft (el `origin` de SolidCraft da 403). Nunca a
   `tangency-labs/solidcraft`, nunca force-push a `main`.
9. **Un tema y un commit por cosa.** Y el mensaje de commit, en ingles.
10. **Todo script que uses tiene que hablar el mismo idioma de variables** que el repo:
    `ORCH_DIR`, `LOOP_DIR`, `SOLIDCRAFT_REPO`, `WORKTREES_DIR`, `HERMES_SCRIPTS`, con
    default. **`config.env` puede traer secretos: revisalo ANTES de versionarlo.** Si trae
    secretos, versiona una **plantilla** (`config.env.example`) y deja el real fuera de git.
    El repo tiene `.env` y `*.env` en el `.gitignore`: no los saques de ahi.

---

## 3. Que hay hecho ya (NO lo repitas)

En la rama `fix/orchestrator-truthfulness` de este repo (26 commits) ya se corrigieron,
con test de regresion cada uno:

- `pipeline.py` (el cron de 5 min) dejo de mentir: un `gh` que falla ya no es "no hay
  PRs", el verdict se busca por SHA con prefijo, el comentario del verdict es idempotente,
  la lista no esta truncada a 30.
- `verify-pr.sh` decide el CI por **estado**, no por nombre; y el parser de cierre es el de
  upstream (`scripts/pr-checks/pr-checks.js`).
- `orch-state.sh issue <N>` no crashea; `orch-state.sh history` no crashea.
- `slot-stale.sh` ve los locks en el formato del productor y destruye mas su propia senal.
- `gate.sh` falla (rc=5) si no hay worktree del slot, en vez de compilar el checkout
  principal.
- `claim-verify.sh` es el **unico** arbitro del claim: la **union** de las dos reglas de
  upstream (`#N` en el titulo, o verbo de cierre + `#N` en el body, con el ruido fuera y
  las referencias a otro repo fuera), mas la regla de mismo autor. Exit codes **0/1/2**.
- `merge-state.sh --split` no pierde la edicion mas nueva y `published.sha256` es
  obligatorio.
- `comment_watch.py` tiene lock, siembra la primera corrida, distingue a un humano de un
  bot, y la cola de pedidos tiene tope (3 por PR, 12 en total) y deadline.
- El grafo (`workflow.yaml`) esta cruzado con el registro de crons (`bin/crons.txt`).
- Hay CI (`.github/workflows/ci.yml`) y un runner de suites (`bin/test-all.sh`).

**El arbitro del repo es `claim-verify.sh` (0/1/2).** El del LOOP es `claim-race.sh`, que
responde `VERDICT=OK|TAKEN|LOST|RESOLVED|UNKNOWN` y que el freno traduce a exit codes
0/10/11/12.

---

## 4. Los pasos

### Paso 1 — Traer los archivos, sin tocarlos

Copiá los archivos de `$LOOP_DIR/bin/` (y `prompts/`, `config.env`) al repo, en `loop/`:

```bash
cd /path/al/repo/solidcraft-orch
mkdir -p loop/bin loop/prompts
cp "$LOOP_DIR"/bin/agent-issue.sh "$LOOP_DIR"/bin/claim-race.sh \
   "$LOOP_DIR"/bin/claim-brake.sh "$LOOP_DIR"/bin/claim-salvage.sh \
   "$LOOP_DIR"/bin/gate-quick.sh "$LOOP_DIR"/bin/pr-defaults-line.sh \
   "$LOOP_DIR"/bin/gc-disk.sh "$LOOP_DIR"/bin/supervisor.sh \
   "$LOOP_DIR"/bin/test-gate-quick.sh "$LOOP_DIR"/bin/test-rules.py \
   loop/bin/
cp "$LOOP_DIR"/prompts/agent-issue.md loop/prompts/ 2>/dev/null || true
```

**Este commit es de MOVIMIENTO, sin cambios de contenido.** La idea es que el diff del
commit siguiente sea solo lo que cambia.

```bash
git add loop/
git commit -m "orchestrator: the loop half of the orchestrator, versioned"
```

### Paso 2 — Parametrizar las rutas

En cada archivo de `loop/`, las rutas absolutas pasan a variables con default. El patron
exacto esta en `bin/gate-queue.sh` (de este repo):

```bash
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
HERMES_SCRIPTS="${HERMES_SCRIPTS:-/home/user/.hermes/scripts}"
```

Las rutas que hay que cambiar (las del LOOP, revisalas con
`grep -rn '/home/user' loop/`):

- `gate-quick.sh:93` (el repo de SolidCraft) y `gate-quick.sh:293` (el target dir por
  defecto, que hoy es `/home/user/solidcraft-gate-quick/target` y **no** es el del
  orquestador: un gate lanzado sin `gate.sh` compila en un arbol distinto del que cree
  todo el resto).
- `gc-disk.sh:176` (el base de los targets) y `gc-disk.sh:209` (el tope).
- Los que aparezcan en el grep.

**El target dir de un slot tiene que ser SIEMPRE el del slot**
(`$ORCH_DIR/targets/slot-<issue>`), el mismo que usa el agente: lo da
`bin/slot-target-dir.sh`.

### Paso 3 — El arbitro del claim: uno solo

`bin/claim-verify.sh` (de este repo) es ahora el arbitro, con la regla de upstream y
exit codes 0/1/2. `loop/bin/claim-race.sh` tiene SU PROPIA regla, que es la que perdio 193
competidores (B6 de la auditoria del repo).

**Convertilo en un shim que delega** en `claim-verify.sh` y traduce el exit code, para que
`claim-brake.sh` (que consume 0/10/11/12) siga funcionando:

| `claim-verify.sh` | `claim-race.sh` (shim) | Significado |
|---|---|---|
| 0 | 0 | el reclamo es nuestro |
| 1 | 10 | lo tiene otro PR (TAKEN/LOST) |
| 2 | 12 | no se pudo verificar (UNKNOWN) |

El caso **RESOLVED (11)** no lo produce el arbitro: lo produce el chequeo que ya tiene el
publisher ("el issue esta abierto?"). Dejalo asi.

Y `claim-verify.sh` tiene que **poder delegar en el LOOP** si ahi esta el arbitro real: hoy
el del repo es el que gana, y el shim es el que se adapta.

### Paso 4 — El rescate, y el trabajo que se pierde

`claim-salvage.sh` existe pero **nunca rescato nada**: los 4 artefactos de
`logs/claims-lost/*.json` dicen `"collected": false` y sus `.diff` estan vacios, porque el
worktree ya se habia borrado (B10).

**El arreglo**: en `agent-issue.sh`, el borrado del worktree (la linea ~280) tiene que
pasar **despues** del freno y del rescate, nunca antes. Y lo que el agente dejo sin
commitear se tiene que **guardar** (`git diff --binary > <worktree>.diff`), no solo anunciar
por stderr.

### Paso 5 — El gate: los descriptores heredados (B1)

`gate-quick.sh:1253` y `:1271` abren los fd 8 (lock del slot) y 9 (lock global) con
`exec N>>file`. Bash **no** pone `FD_CLOEXEC`, asi que `cargo`, `rustc`, `nextest` y el
`systemd-run` los heredan: un `flock` pertenece al *open file description*, asi que si un
hijo sobrevive **el lock sigue tomado** aunque el `gate.sh` padre haya muerto. Con
`GATE_SCOPE_LOCK_WAIT=0` el gate no espera: se difiere al instante, y como el lock no se
libera nunca, **el diferimiento es eterno**.

El arreglo es **las dos medidas** (no una):

1. Que cada hijo cierre los fd: un wrapper `run_child() { ( exec 8>&- 9>&-; "$@" ); }` para
   cada invocacion de `cargo`/`nextest`/`systemd-run`/`cargo clippy`.
2. Un watchdog que mate un gate colgado (el que lleva mas de N minutos sin escribir en su
   log).

### Paso 6 — El disco (B12)

`gc-disk.sh` tiene un tope de 60 GB, pero **el cap nunca se aplicaba**: 87 GB en
`targets/`, y el unico que lo llamaba era `supervisor.sh`, que no estaba en ningun cron ni
timer. Ademas `gc-disk.sh:488-501` prueba el lock del slot con un `flock -n -x` **exclusivo**:
si lo consigue, **toma** el lock del slot por un instante, y el GC puede ganar la carrera y
hacer que un gate se difiera.

El arreglo: un timer/cron real que corra `gc-disk.sh`, y que el sondeo del lock **no lo
tome** (preguntar sin tomar: `flock -n -s`, o `/proc/locks`).

### Paso 7 — El preflight y la instalacion

`bin/preflight.sh` (de este repo) dice que falta. Correlo:

```bash
bash bin/preflight.sh
```

Tiene que dar rc=0. Si dice que falta una copia de un cron, la copia va en
`$HERMES_SCRIPTS/` y tiene que ser **identica** al script del repo.

Y el `README.md` de este repo tiene que decir como se instala el LOOP (hoy solo dice que
falta).

---

## 5. La verificacion (esta es la parte que decide)

```bash
# 1. las suites del repo (las 16 que corren en cualquier maquina)
bash bin/test-all.sh --fast

# 2. el preflight: no falta nada
bash bin/preflight.sh

# 3. las suites del LOOP, que ahora estan en el repo
bash loop/bin/test-gate-quick.sh
python3 loop/bin/test-rules.py

# 4. el grafo y los crons siguen de acuerdo
python3 bin/workflow-validate.py

# 5. las reglas de upstream no envejecieron
SOLIDCRAFT_REPO=/home/user/solidcraft bash bin/rules-sync.sh

# 6. NO hay rutas absolutas fuera de los defaults
bash bin/test-portability.sh

# 7. el arbitro del claim: los dos dicen lo mismo
bash bin/test-claim-verify.sh
```

**El paso 3 corre el gate: eso compila Rust. Tomá el turno del gate pesado antes**
(`bash bin/slot-lock.sh --heavy --take --wait 3600`) y soltalo despues. Si la maquina esta
saturada, esperá: es la maquina de los gates.

---

## 6. Lo que devuelves

Un informe, en texto plano, con:

1. **La lista de archivos** que trajiste, con su tamaño, y **cuales** quedan fuera y por que
   (por ejemplo: `config.env` por secretos).
2. **El diff de los cambios de contenido**, agrupado por archivo, con el porque de cada
   cambio de ruta.
3. **La salida de los siete pasos de verificacion**, con el rc de cada uno.
4. **Lo que no pudiste hacer**, con el error exacto. Si algo del LOOP no se puede portar
   (depende de un servicio que no existe en la otra maquina, o de un formato interno), no lo
   inventes: **decilo**, y dejalo documentado en `loop/README.md` con la razon.
5. **Lo que rompio al traerlo**, si algo se rompio: el repo tiene 16 suites en verde y no
   pueden seguir en verde si el LOOP se trae con cambios de comportamiento.
6. **El commit**, con su SHA y su mensaje.

**Regla del repo que aplica a este brief**: un brief con "busca el bug" produce
exploracion, no codigo. Un brief con una ruta que ya no existe produce un callejon sin
salida. Si algo de este brief no aplica en esa maquina, **decilo y segui** — no lo fuerces
ni lo inventes.

---

## 7. Lo que NO hay que hacer

- **No abras PRs al upstream de SolidCraft desde este brief.** El objetivo es el repo del
  orquestador.
- **No corras el publisher contra GitHub de verdad** (no abras PRs, no comentes) para
  "probar" que funciona: `agent-issue.sh` publica de verdad. Probalo con `--help`, con un
  `--dry-run` si lo tiene, o con un issue de prueba tuyo.
- **No compiles Rust** para verificar los cambios de shell/python: las suites no compilan.
  El gate si, y es serializado.
- **No toques los 26 commits que ya estan** (`git rebase`, `reset`, `amend`): son la base y
  tienen sus tests. Tu trabajo va **encima**.
- **No borres los `.bak`** que pueda haber: son de otro trabajo. Si te estorban, dejalos
  y avisalos en el informe.
