# La otra mitad: qué vive fuera de este repo

**Fecha:** 2026-11-17

> **ACTUALIZADO (2026-11-19):** este inventario describe la mitad LOOP como algo que
> **no está en git**. Ya no es así: desde `149f7fa` la mitad LOOP está **versionada en este
> repo**, en [`loop/`](../loop/) (`loop/bin/`, `loop/prompts/` y la plantilla
> `loop/config.env.example`). Lo que sigue fuera de git es el **runtime de cada máquina**
> (`$LOOP_DIR/gates/`, los logs, los worktrees y el `config.env` real). El README dice cómo
> apuntar el runtime al código versionado. El inventario de abajo se conserva como la lista
> de **qué necesita la mitad ORCH** (esa parte sigue siendo verdad).

Este repo (`vdirienzo/solidcraft-orch`) es **la mitad ORCH** del orquestador. La otra
mitad —**LOOP**— vive en `$LOOP_DIR` (por defecto
`/home/user/.local/share/solidcraft-loop`), **no está en git**, y **no se puede
reconstruir desde aquí**: en la máquina donde se escribió no queda ni una copia.

`RULES.md:3` dice *"Source of truth: the repo. This file is a cache of the rules, not a
replacement."* Eso era verdad para las reglas de upstream y **falso para el propio
orquestador**: la mitad que publica, la que arbitra los claims y la que compila el gate
está fuera del control de versiones.

Este archivo es el inventario de esa mitad: qué es cada cosa, qué la necesita y qué se
rompe sin ella. Sirve para dos cosas:

1. **Recuperar el LOOP** de la máquina del mantenedor (o de un backup) y traerlo al
   repo, que es lo que el plan llama Fase 0.
2. **Entender por qué** el orquestador hace lo que hace: varios comportamientos que
   parecían arbitrarios son consecuencia de que esta mitad esté fuera.

`bin/preflight.sh` comprueba, en esta máquina, qué de esto falta y qué se rompe sin
ello.

---

## 1. Lo que hay en `$LOOP_DIR/bin/`

| Archivo | Qué hace | Quién lo necesita |
|---|---|---|
| `agent-issue.sh` | **El publisher.** Corre el modelo (`opencode run`), toma el lock del slot, hace el fix, abre el PR. | `bin/run-issue-scope.sh:46`, `bin/launch-wave.sh:14`, `bin/launch-slot-service.sh:33`, `bin/launch-resume.sh:81` |
| `claim-race.sh` | **El árbitro del claim.** Pregunta a GitHub una vez y responde `VERDICT=OK\|TAKEN\|LOST\|RESOLVED\|UNKNOWN`. | `bin/claim-verify.sh` lo delega (según `RULES.md:27`); el publisher lo llama en el freno |
| `claim-brake.sh` | **El freno.** Actúa sobre ese veredicto. Sus exit codes **son** el veredicto: 0 OK, 10 TAKEN/LOST, 11 RESOLVED, 12 UNKNOWN. Nunca se traducen. | el publisher, antes de que arranque el modelo y otra vez en el push |
| `claim-salvage.sh` | **El rescate.** Cuando el claim se pierde, escribe el diff de la rama contra su base, la lista de commits, una nota y lo mismo en JSON en `logs/claims-lost/`. La rama y el worktree **no** se borran. | el publisher, cuando el freno dice que el claim se perdió |
| `gate-quick.sh` | **El gate que compila.** Las fases (`fmt`, `layers`, `clippy`, `check`, `nextest`), el veredicto `scope.verdict` y el efectivo `scope.effective.verdict`. | `bin/gate.sh:53` — sin él el gate sale con rc=2 |
| `pr-defaults-line.sh` | **El validador del body.** Decide si el body lleva la línea `Changes a default:` bien formada. | `bin/publish-pr.sh`, `bin/verify-pr.sh` |
| `gc-disk.sh` | **El GC de disco.** Aplica el tope de GB de `targets/`. | el supervisor; el cap nunca se aplicaba porque su único llamador no estaba en ningún cron |
| `supervisor.sh` | **El supervisor.** Levanta y baja los corredores. | los crons |
| `test-gate-quick.sh` | Suite del LOOP. | el gate |
| `test-rules.py` | Suite de reglas del LOOP. | el gate |

Y en `$LOOP_DIR/`: `config.env` (la configuración de la máquina), `prompts/agent-issue.md`
(el prompt que recibe el agente), `gates/<slot>/scope.verdict` y
`scope.effective.verdict` (los veredictos), `work/issue-<N>` (los worktrees donde
trabaja el publisher).

---

## 2. Por qué importa: los cuatro bugs que la partición causa

Los cuatro están en la auditoría del propio repo (`reports/loop-codigo.md`, 2026-11-02),
y los cuatro son consecuencia de que el código no esté en git.

### B6 — dos árbitros del claim, y el que está aquí no ve 193 competidores

`bin/claim-verify.sh` (este repo) exige un verbo de cierre en el título + body.
`claim-race.sh` (el LOOP) acepta también `#N` **en el título**, como hace el bot de
upstream (`scripts/claim/claim.js:278-284`).

Medido sobre los 836 PRs abiertos de aquel día: **193 PRs competidores que
`claim-verify.sh` no ve**. Para todos ellos, `claim-verify.sh` decía *"el issue está
libre"* y el gate corría como si nadie lo tuviera.

**La regla correcta es el union de las dos**, y el union más conservador de las dos
reglas de upstream (que tampoco coinciden entre sí: `claim.js` acepta el título,
`pr-checks.js:35` sólo el body). Es lo que hace `bin/claim-verify.sh` desde el 2026-11-17.

### B8 — el gate puede compilar el árbol equivocado

Había **dos árboles de worktrees**: el del orquestador (`$WORKTREES_DIR/issue-<N>`) y el
del publisher (`$LOOP_DIR/work/issue-<N>`). Un PR publicado por `agent-issue.sh` tenía
su worktree en el segundo; `gate.sh` buscaba el primero, no lo encontraba, caía al
checkout principal —**que no contiene el cambio**— y escribía un verdict que
`verify-pr.sh` leía como *"el gate de este PR"*.

Desde el 2026-11-17 el publisher usa `--work $WORKTREES_DIR` (los dos árboles son el
mismo) y `gate.sh` **falla** si no encuentra el worktree, en vez de compilar otra cosa.

### B10 — el trabajo del agente se perdía en el re-run

`agent-issue.sh:416-419` corría el modelo con `timeout` y **guardaba el exit code sólo
para imprimirlo**: un timeout (rc=124) o un crash publicaba igual, si había dejado un
commit. Y si había dejado **cambios sin commitear**, el script lo anunciaba por stderr y
seguía: el siguiente re-run borraba el worktree con `--force` y el trabajo se perdía.

Se ve en los artefactos: los 4 conjuntos de `logs/claims-lost/*.json` del LOOP dicen
`"collected": false` y sus `.diff` están **vacíos (0 bytes)** — el mecanismo de rescate
existía pero nunca recogió nada, porque el worktree ya se había borrado.

### B1 — los descriptores del lock se heredaban a los hijos

`gate-quick.sh:1253,1271` abre los fd 8 (lock del slot) y 9 (lock global) con
`exec N>>file`. Bash **no** pone `FD_CLOEXEC`, así que `cargo`, `rustc`, `nextest` y el
`systemd-run` heredan los descriptores. Un `flock` pertenece al *open file
description*: si un hijo sobrevive, **el lock sigue tomado** aunque el `gate.sh` padre
haya muerto.

Con `GATE_SCOPE_LOCK_WAIT=0` el gate no espera: se difiere al instante. Y como el lock
no se libera nunca, **el diferimiento es eterno**: los gates nunca corren.

Sólo se arregla cerrando el fd en cada hijo (`run_child() { ( exec 8>&- 9>&-; "$@" ); }`)
**y** con un watchdog que mate un gate colgado. Las dos medidas: sólo la primera deja
vivo un `nextest` de 45 min; sólo la segunda deja el lock tomado por otro hijo.

---

## 3. Qué hay que hacer con esto

**Traer el LOOP al repo** (Fase 0 del plan). Con el LOOP a la vista:

- `agent-issue.sh`, `claim-race.sh`, `claim-brake.sh`, `claim-salvage.sh`,
  `gate-quick.sh`, `pr-defaults-line.sh`, `gc-disk.sh`, `supervisor.sh` y `config.env`
  se versionan (el estado de máquina —`gates/`, `logs/`, `locks/`, `targets/`— sigue
  gitignorado, como ya está aquí).
- `config.env` deja de ser un archivo de máquina y pasa a una **plantilla** con defaults
  de variables de entorno, como el resto de los scripts de este repo. **Antes de
  versionarlo hay que revisarlo**: `README.md:153` documenta que ahí va `FORK_OWNER` y
  `bin/publish-pr.sh:276` lo lee, así que hay que confirmar que no trae secretos.
- Los scripts pasan a usar `ORCH_DIR`/`LOOP_DIR`/`SOLIDCRAFT_REPO`/`WORKTREES_DIR`/
  `HERMES_SCRIPTS` con default, **incluidos los que hoy tienen rutas absolutas**
  (`gate-quick.sh:93,293`).
- Los exit codes del freno (0/10/11/12) pasan a ser un contrato **documentado y testeado**,
  no una convención de otro directorio.

**Mientras tanto**, `bin/preflight.sh` dice qué falta. Y el README (§4, "Instalarlo en
otra PC") tiene que mencionar el LOOP: el procedimiento documentado hoy produce un repo
cuyo gate no compila nada.
