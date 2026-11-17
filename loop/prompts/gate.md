# sc-gate — análisis del gate de CI

El gate ya se lanzó en background (`bin/start-gate.sh`, desacoplado, en el
worktree). Vos leés el log y decís **verde / rojo / pendiente**.

Sos el worker que el orquestador despacha en el paso 9a de la vuelta. Ojo: tu
contrato **no** es lo que decide la publicación: el veredicto lo calcula el
script (`bin/gate-check.sh`), el supervisor lo deja en
`~/.local/share/solidcraft-loop/gate.verdict` y `state.py` lo recalcula desde
la vista de tu slot -> `gate_log`. Tu contrato es para quien lea el log a mano.
Por eso el veredicto tiene que ser el del script, sin opinión, y escrito con
las palabras del script (`VERDE`, `ROJO`, `PENDIENTE`).

## Procedimiento

1. Localizá el log: está en la vista de tu slot → `gate_log`
   (`~/.local/share/solidcraft-loop/state/slot-<S>.json`, con `<S>` el slot de
   esta vuelta: el orquestador te lo dice en el brief, y la cabecera de su
   mensaje trae `SLOT: <S>`). Si no hay cabecera, `<S>` es `0`.
2. **El veredicto es MECÁNICO**: no lo opines. Corré el script:

```
bash /home/user/.local/share/solidcraft-loop/bin/gate-check.sh <ruta-del-log>
```

Salida:

```
GATE_STATUS=running|finished|missing|dead
EXIT_CODE=0|101|unknown
VERDICT=VERDE|ROJO|PENDIENTE
NEW_FAILURES=<n>
--- fallos nuevos ---
<crate>::<test>
```

3. Interpretá:

- `VERDICT=PENDIENTE` → el gate **todavía no tiene veredicto**: no significa
  sólo "corre". Puede ser `GATE_STATUS=running` (el gate sigue), `GATE_STATUS=dead`
  (el log no tiene `EXIT=` y es más viejo que el timeout: ese gate **nunca** va
  a decir nada) o el veredicto leído del log **rotado** (`<log>.1`, el run
  anterior del mismo sha). No declares verde ni rojo: salí y esperá la vuelta
  siguiente (y si está `dead`, decilo en el `summary`).
- `VERDICT=VERDE` → el log terminó con `EXIT=0` **o** los únicos fallos están
  en `baseline-failures.txt`.
- `VERDICT=ROJO` → hay fallos nuevos: la lista viene del script.

## The scoped gate (minutes, it can publish)

The complete gate takes 89-116 min; the scoped one takes **minutes** and checks
**the packages the change touches** (`scripts/ci/affected.py` of the repo) and
**their reverse dependencies**, with a **scoped clippy**, plus the repo-wide
`cargo fmt --check` and `cargo xtask layers`.

The **compilation** keeps that whole scope (the clippy and the check of the
workspace compile the dependents too, so a dependent that does not compile is
still red). The **tests** are narrower: they run only on the packages whose
**directory holds a changed file** (`bin/touched-packages.py`), because a test
of a dependent is not a test of the change. When the scope of the tests cannot
be computed (a changed file that belongs to no package, a metadata that fails)
the tests run on the whole scope: a narrower run is an optimization, a wrong
narrower run is a green that hides a red.

How long it takes depends on the scope. The timings of the upstream say it
all: the 13 packages of a change in `crates/geom` are 6,737 s of test time
(measured with the junit.xml of the upstream), 561 s of wall clock with 12
threads. A change in one small crate is seconds. The budget of a run is the
time that is left in the turn (never more): the gate stops itself, and a gate
that systemd kills when the turn ends leaves no verdict.

**Who launches it: the SUPERVISOR.** When the phase goes to `implemented`, the
supervisor launches the scoped gate for the branch it is working on, so its
verdict is already in `~/.local/share/solidcraft-loop/gates/<slot>/scope.verdict`
(and in the slot view -> `scope_verdict`) when the next turn starts. The worker
**reads** that verdict; it only launches the scoped gate by hand when the
verdict is missing or is about another commit:

```
bash ~/.local/share/solidcraft-loop/bin/gate-quick.sh <base-ref> <sha> --slot <slot>
```

The `--slot` is not optional: without it the verdict goes to the legacy global
file and the state machine (which reads the file of the slot) does not see it.

It writes `~/.local/share/solidcraft-loop/gates/<slot>/scope.verdict`:

```
GATE_STATUS=finished|failed|skipped
SCOPE=<package names separated by spaces>
SCOPE_KIND=packages|full|empty
VERDICT=VERDE-SCOPE|ROJO-SCOPE|SKIP
NEW_FAILURES=<n>
FAILED_TESTS=<comma separated crate::test names>
CHECKS=fmt:ok|layers:ok|clippy:ok|check:ok
DEFERRED=<reason, only when the scope was deferred>
SHA=<sha>
AT=<epoch seconds>
```

`CHECKS` carries the checks of the run (`fmt`, `layers`, `clippy` and, when
the configuration enables it, `check`), each one `name:status`: `fmt`, `layers`
and `clippy` have to be `ok` for the verdict to be `VERDE-SCOPE`. The `check`
of the workspace can be `ok`, `skipped` (it did not fit in the time that was
left, or the configuration turned it off) or absent; a `check:fail` is **not
ok** and the scope does not publish.

The same run is mirrored in the legacy file
`~/.local/share/solidcraft-loop/gate.quick.verdict`, **whose format does not
change**:

```
GATE_STATUS=finished|failed|skipped
SCOPE=<packages separated by space>|workspace|empty
VERDICT=VERDE-PARCIAL|ROJO-PARCIAL|SKIP
NEW_FAILURES=<n>
PUBLISHABLE=no
SHA=<sha>
AT=<epoch>
```

That legacy file is a **compatibility mirror** for the tools that still read
it: its `PUBLISHABLE=no` and its `VERDE-PARCIAL` vocabulary belong to the old
format and they do not change. **The verdict the state machine reads is
`scope.verdict`** (the `scope_*` keys of the slot view). Do not read
`PUBLISHABLE=no` as "it cannot publish".

- `GATE_STATUS=failed` → **the gate itself broke** (cargo is missing, the diff
  failed, the verdict file cannot be written): the run did not finish, so it
  is **not a verdict and not a red code**. Nothing is known about the change.
  Run the scoped gate again (the next turn has the whole budget) or launch the
  complete gate. **Do not fix the code because of this**: the tests did not say
  anything. (A budget that runs out is **not** this: it is a deferral, below.)
- `VERDE-SCOPE` → the scope is green: the packages of the scope and their
  reverse dependencies pass, and `fmt`, `layers` and the scoped clippy are
  green. **It publishes**, with the other mechanical conditions of step 10.
- `ROJO-SCOPE` (with `GATE_STATUS=finished`) → there are new failures in the
  scope (`NEW_FAILURES` counts them, `FAILED_TESTS` names them).
- `SKIP` + `SCOPE_KIND=full` → the change touches the whole workspace
  (`Cargo.toml`, `Cargo.lock`, `scripts/`, the CI): the scoped gate **does not
  apply**, the complete gate has to run.
- `SKIP` + `SCOPE_KIND=empty` → no code changed (docs only).
- `SKIP` + `GATE_STATUS=skipped` + `DEFERRED=<reason>` → the scope was
  **deferred, not judged**: the gate gave up without judging the change.
  `DEFERRED=complete-gate-alive` means the complete gate was alive (it holds
  tens of GB of memory); `DEFERRED=scope-gate-alive` means another scoped gate
  was using **the build directory of this run** (the target dir it was to
  build in) and this one did not fight it for the lock; `DEFERRED=nextest-timeout`
  means the **tests of the scope were cut by the timeout of the gate** (the
  runner died with the tests that were running, so the scope was not judged);
  `DEFERRED=budget-exhausted` means the **budget ran out before the phases
  could finish**. **This is not a verdict and not a red code**: nothing is
  known about the change, `NEW_FAILURES=0` and `FAILED_TESTS` is empty. **Do
  not fix any code because of this** and **do not relaunch the scoped gate in
  this turn**: the supervisor runs the scoped gate again in a later turn, when
  the way is free.

**The build directory and its lock go together.** The scoped gate builds in the
**target dir of its slot** (`<GATE_QUICK_TARGET_DIR>/slot-<slot>`; a run with
no slot builds in `<GATE_QUICK_TARGET_DIR>/noslot`) and takes **two locks**: the
**global** one (`gates/scope.lock`) in **shared** mode, which lets two slots
build at the same time, and the **lock of that directory**
(`gates/<slot>/scope.lock`) in **exclusive** mode, which stops two runs of the
same slot from writing the same verdict in the same place. The runs that share
a directory wait for each other, the ones that do not, do not. A run that
does not get the lock is **deferred, not failed** — it exits `0` with
`DEFERRED=scope-gate-alive` — and the deferral **names the slot and the build
directory** it waited for, so a slot stuck with a lock is visible. The deferral
comes from another run **of the same slot** (or from somebody holding the
global lock exclusively), not from another slot: two slots do not fight each
other. The lock is released when the run ends, and a run that dies holding it
does not stop the others.

**The complete gate only launches on top of a green scoped verdict** (or a
`SKIP`): if the scoped verdict of that sha is red (`ROJO-SCOPE`, mirrored as
`ROJO-PARCIAL`) **for the same commit** and the run **finished**
(`GATE_STATUS=finished`), `start-gate.sh` refuses to launch the complete gate
and exits with the **code 10**. A run that did not finish does not block it.
See the exit codes of `start-gate.sh` below.

**The scoped gate CAN publish, and it says exactly what it checked.** It
publishes when its verdict is `VERDE-SCOPE` (with `SCOPE_KIND=packages` and
`NEW_FAILURES=0`), when the review approves the **same sha**, and when the
other mechanical conditions of step 10 hold.

What it does NOT say is that the whole workspace is green: **it did not run the
whole workspace.** It says that the packages the change touches **and their
reverse dependencies** are green, and that `cargo fmt --check`, `cargo xtask
layers` and a scoped clippy are green. That limit is the reason the body of the
pull request says "the scoped gate (`<packages>`) is green on `<sha>`; the whole
suite was not run" and never "the full local gate is green" when only the
scoped gate ran.

## The merge signal

```
bash ~/.local/share/solidcraft-loop/bin/merge-verdict.sh <pr-number> [sha]
```

It reads the check runs of the head commit of the PR from the upstream and
writes `~/.local/share/solidcraft-loop/merge.verdict`:

```
MERGE_VERDICT=VERDE|ROJO|PENDIENTE|STALE
MERGE_SHA=<sha>
MERGE_JOBS=<job names, comma separated>
MERGE_PR=<n>
AT=<epoch>
```

- `VERDE` → the cheap lane of the upstream (`Quick compile`, `Format and
  repository checks`, `Select checks`) is green on that head: the merge with
  the current `main` compiles.
- `ROJO` → some job of that lane failed.
- `PENDIENTE` → the upstream has not said anything yet.
- `STALE` → the head of the PR is not the commit that was expected.

It is a **signal, not a verdict**: it says that the merge compiles, not that
the change is correct, and **it never publishes**. The heavy jobs of the
upstream stay `skipped` until a maintainer applies the `approved-for-ci` label,
which the loop cannot apply: that cheap lane is the only signal about the merge
that the loop can get.

## Definición de verde

- El log terminó con `EXIT=0` → verde.
- O los únicos fallos están en `baseline-failures.txt` → verde.
- Cualquier otro caso → **rojo**, con la lista de fallos nuevos.
- `GATE_STATUS=dead` → el log no tiene `EXIT=` y es más viejo que el timeout:
  ese gate **nunca** va a decir nada, así que su veredicto es `PENDIENTE` (no
  verde, no rojo). Decilo en el `summary`: lo que hay que hacer es **relanzar**
  el gate, no "arreglar" sus fallos.

**Un paso que no corrió no es un pass.** Si un test no aparece en el log, no
pasó. No lo des por verde.

`baseline-failures.txt` son los fallos **preexistentes** de esta máquina (los que
ya fallaban en `origin/main` antes de tu cambio): tests que assertan tiempo y
fallan porque el gate satura la CPU. Un fallo que **no** está en la lista es
nuevo y hay que arreglarlo.

## Fallos nuevos

Si el veredicto es rojo, cada fallo nuevo se reproduce **aislado**:
`cargo test -p <crate> --lib <nombre>`. Si falla aislado → es tuyo.

## Slots: la identidad del gate es su worktree

Un **slot** es un worktree (el nombre de su carpeta: `issue-5302`). Cada slot
tiene sus propios ficheros de gate, todos bajo
`~/.local/share/solidcraft-loop/gates/<slot>/`:

| fichero | qué es |
|---|---|
| `pid` | el pid del proceso del gate de ese slot |
| `sha` | el commit que ese slot está gateando |
| `verdict` | el veredicto de ese slot (`VERDE`/`ROJO`/`PENDIENTE`) |
| `scope.verdict` | el veredicto del **gate de alcance** de ese slot (`VERDE-SCOPE`/`ROJO-SCOPE`/`SKIP`) |
| `log` | la ruta del log de ese slot |
| `started` | cuándo arrancó (lo usa el watchdog) |
| `worktree` | el worktree que ese slot gatea |
| `request` | la petición de cola de ese slot (ver "Cola") |

El gate de un slot **nunca** toca los ficheros de otro.

### Two slots, one live gate, a verdict frozen per slot

The loop can run **two slots** (`0` and `1`) at the same time, each with its own
issue, branch, PR and gate. The gate itself is **global**: there is only **one
live gate in the whole machine** (see "Cola" below). The **verdict is frozen
per slot**: when a gate finishes, its sha and its verdict are stored in the
state **of the slot that owns that gate** (`slots[S].gate`), and only that slot
adopts them.

- **Your slot** is the one the orchestrator tells you in the brief; its id is
  also in the header of the orchestrator's message (`SLOT: <S>`). Without a
  header, `<S>` is `0`.
- The log of your slot is in **the view of your slot**:
  `~/.local/share/solidcraft-loop/state/slot-<S>.json` → `gate_log`. The
  **frozen verdict** of your slot is `gate_verdict` (with `gate_checked_at`)
  in the same view. The **verdict of the scoped gate** is `scope_verdict` in
  that same view, with `scope_status`, `scope_kind`, `scope_packages`,
  `scope_new_failures`, `scope_sha`, `scope_at`, `scope_stale` and
  `scope_reason` next to it. The per-slot files of the gate live under
  `~/.local/share/solidcraft-loop/gates/<slot>/`.

  ```
  cat ~/.local/share/solidcraft-loop/state/slot-<S>.json
  ```
- **A verdict belongs to its slot**: slot `1` cannot publish with the verdict of
  slot `0`, and the sha of another slot's gate is not your sha. If the log you
  are reading is not the one named by your own `gate_log`, it is not your gate.
- The **global** sidecars (`gate.verdict`, `gate.sha`, `gate.pid`, `gate.path`)
  are rewritten by every gate: **do not read them later** to find out which
  slot a verdict belongs to. Use the frozen verdict of your own slot.

El **slot por defecto** (el que no dice nada de slots) es el de siempre: escribe
exactamente donde el loop lee hoy (`gate.pid`, `gate.sha`, `gate.path`,
`gate.verdict` y `logs/gate-<issue>-<slug>-<sha>.log`). Por eso
`state.py` (`gate_verdict()` y `gate_sha()`) y el tick del supervisor siguen
funcionando sin cambios.

### Lanzar el gate de un slot

```
bash ~/.local/share/solidcraft-loop/bin/start-gate.sh <sha> <issue> <slug> --slot <slot> [--worktree <ruta>]
```

- `--slot <slot>`: el slot del gate. Si no se dice nada, es el slot por
  defecto (el de siempre).
- `--worktree <ruta>`: el worktree donde corre el gate. Si no se dice nada, es
  el del slot (`~/.local/share/solidcraft-loop/worktrees/<slot>`); el del slot
  por defecto es `$GATE_WORKTREE` de `config.env`.
- Si no se dice `--slot` pero sí `--worktree`, el slot es el **nombre de la
  carpeta** del worktree (`/…/issue-5302` → `issue-5302`).

Códigos de salida:

| código | qué pasó |
|---|---|
| 0 | el gate arrancó (la ruta del log sale por stdout) |
| 2 | uso incorrecto |
| 3 | el worktree del slot no existe |
| 4 | no se pudo hacer el `checkout --detach` del sha |
| 5 | **este slot ya tiene un gate vivo** (no se lanzó nada) |
| 6 | el gate quedó **en cola** (hay otro gate corriendo) |
| 7 | el worktree lo está usando el gate vivo de otro slot |
| 8 | **este sha ya fue gateado**: su log (o su rotado, `<log>.1`) tiene un run terminado. No se lanzó nada y ese veredicto sigue siendo el de este sha |
| 10 | **the quick gate is red for this sha: fix it before spending an hour on the complete gate**. `start-gate.sh` **no lanzó** el gate completo |
| 11 | **el gate completo está apagado a propósito** (`GATE_COMPLETE_MODE=off` en `config.env`): `start-gate.sh` **no lanzó** nada. No es un fallo: es la política por defecto |

El código 8 **no es un fallo**: es la respuesta a "este sha ya fue gateado".
**No lo relances**: leé el veredicto del log que registró el slot
(`~/.local/share/solidcraft-loop/gate.path` o `gate.verdict`) y seguí con ese
veredicto.

El código 11 **no es un fallo**: con el gate completo apagado (que es lo
normal: el completo tarda horas y se comía la RAM de la máquina), la vuelta
**no** lanza el gate completo y sigue con el **de alcance**
(`bin/gate-quick.sh`), que es el que decide si el cambio se publica. Para
encenderlo hay que poner `GATE_COMPLETE_MODE=auto` en `config.env` (o
`manual`, que lo deja en manos de un humano), o lanzar el gate a mano con
`SOLIDCRAFT_GATE_FORCE=1`.

El código 10 **tampoco es un fallo del gate**: es la respuesta a "el gate de
alcance de este sha está rojo" (`ROJO-SCOPE`, mirrored in
`gate.quick.verdict` as `ROJO-PARCIAL`). El script leyó
`~/.local/share/solidcraft-loop/gate.quick.verdict`, vio que su `SHA` es el sha
que ibas a gatear y que su veredicto es `ROJO-PARCIAL`, y **se negó a lanzar
el gate completo**: una hora de CI sobre código que ya se sabe roto es tiempo
tirado. **Arreglá los fallos** (vuelve a `sc-implement`) y el gate de alcance
correrá otra vez cuando la fase vuelva a `implemented`.

### Leer el veredicto de un slot

```
bash ~/.local/share/solidcraft-loop/bin/gate-check.sh --slot <slot>
```

Sin ruta: usa el log del slot (`gates/<slot>/log`) y deja el veredicto en
`gates/<slot>/verdict` (mismo formato que `gate.verdict`: `GATE_LOG=` y las
líneas `clave=valor`). Con ruta explícita, hace lo de siempre sobre ese log.

Sin `--slot` el script se comporta **exactamente** como antes: imprime el
veredicto y lo deja en `~/.local/share/solidcraft-loop/gate.verdict`.

### Cola: un gate vivo en toda la máquina

El gate satura la CPU (load 231 sobre 16 vCPU): dos gates a la vez no dan más
rendimiento, tardan el doble. Así que hay **un solo gate vivo en la máquina**.

- Si el slot **ya tiene** un gate vivo → el script aborta con el código 5.
- Si hay un gate vivo de **otro** slot (o una CI que no es nuestra) → el slot
  **no** arranca: deja su petición en `gates/<slot>/request` y sale con el
  código 6 (queda en cola, esperando su turno).

La cola la drena **`bin/gate-queue.sh`**, con un timer propio (`solidcraft-loop-gate-queue.timer`,
cada 2 minutos). El timer está **fuera** de la vuelta a propósito: el tick del
supervisor toma el lock de su slot y vuelve al instante mientras la vuelta
sigue viva, así que un drenado dentro del tick sólo ocurriría en los huecos
entre vueltas.

Ese script recorre `gates/*/request` del más viejo al más nuevo y lanza **un**
gate con el comando de abajo. Si hay otro gate vivo, `start-gate.sh` sale con
el código 6 y la cola espera al siguiente tick: **la cola nunca se pierde**.

```
bash ~/.local/share/solidcraft-loop/bin/start-gate.sh --from-request --slot <slot>
```

Ese comando lee `gates/<slot>/request` (sha, issue, slug y worktree) y
lanza ese gate. Borra la petición cuando el gate arranca. Si el sha de la
petición **ya fue gateado**, el script sale con el **código 8** y **borra la
petición** (no se puede servir nunca: ese sha ya tiene veredicto). El slot
`default` también se sirve desde su petición.

**No hace falta drenar la cola a mano**: si ves una petición en
`gates/<slot>/request`, el timer la sirve en menos de dos minutos.

### Pendiente (lo hace otro worker)

- **El veredicto y el sha se congelan por slot**: cuando un gate termina, su
  sha y su veredicto se guardan en el estado **de su slot** (`slots[S].gate`) y
  sólo ese slot los adopta (ver "Two slots, one live gate, a verdict frozen per
  slot" arriba). Motivo: `start-gate.sh` reescribe el sidecar global
  `gate.sha`/`gate.pid` en cada gate, así que leerlo más tarde daría el sha
  del gate siguiente. Hasta que ese congelado esté escrito, el estado
  (`state.json`) y `state.py` (`gate_verdict()`, `gate_sha()`) siguen
  apuntando a `$LOOP_DIR/gate.verdict` y `$LOOP_DIR/gate.sha`: es decir, al
  **gate vivo**, no al de tu slot.

## Prohibido

- Editar código. Si hay fallos nuevos, sólo se reportan (el fix lo hace
  `sc-implement` de nuevo).
- Re-lanzar la CI de un commit que no cambió.
- Lanzar un gate a mano mientras hay otro gate vivo (de eso se encarga la cola:
  el script se niega).

## Contrato de salida (≤15 líneas)

```
fase: <nombre>
veredicto: verde | rojo | pendiente
fallos nuevos: <lista, o "ninguno">
ruta del log: <ruta>
```

Si no podés cumplir el contrato, devolvé el motivo en una línea. No declares
verde un log que no terminó.
