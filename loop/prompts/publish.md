# sc-publish — publicación del PR

Publicás un PR que ya pasó el gate (verde: el completo o el de alcance) y la
revisión (aprobado).

## Tu slot

Esta vuelta corre en **un slot**: un work item en vuelo, con su issue, su rama,
su PR y su veredicto de revisión. El loop puede correr dos slots (`0` y `1`) a
la vez.

El orquestador te dice el slot en la cabecera del brief (las tres primeras
líneas del brief):

```
SLOT: <S>
SLOT_VIEW: <.../state/slot-<S>.json>
```

`SLOT_VIEW` es la **vista de tu slot**: el fichero que tenés que leer. El
bloque de arriba es la FORMA de la cabecera, nunca un valor: el slot escrito
en ese ejemplo **no** es tu slot. `SLOT` es el id de tu slot (`0` o
`1`) y la ruta de la vista lleva ese mismo `<S>`. Si la cabecera no dice nada
(no debe pasar: el orquestador copia la cabecera del slot en cada brief), sos el
slot `0` y tu vista es
`~/.local/share/solidcraft-loop/state/slot-0.json`.

**Todo lo que leas del estado sale de esa vista**, no de `state.json` (el estado
durable lo lleva el supervisor). La vista tiene las mismas claves planas de
siempre (`phase`, `issue`, `branch`, `pr`, `review`, `review_sha`,
`published`, …) más las del gate de alcance (`scope_verdict`, `scope_status`,
`scope_kind`, `scope_packages`, `scope_new_failures`, `scope_sha`, `scope_at`,
`scope_stale`, `scope_reason`) más los globales (`triage`, `prs`, `skipped`,
`counters`, `mode`, `report`, `allow_new_prs`, `open_unmerged`, `attempts`).

**El veredicto es de tu slot**: el `aprobado` del slot 0 no habilita el PR del
slot 1. Publicá el issue y la rama que están en **tu** vista.

## El camino UNICO de abrir un pull request

Un pull request nuestro se abre **siempre** con el script del orquestador. Es
la **unica** forma de abrirlo:

```
bash /home/user/.local/share/solidcraft-orch/bin/publish-pr.sh --repo tangency-labs/solidcraft --base main --head vdirienzo:<rama> --title "<summary> (#<N>)" --body-file /tmp/pr-<N>-body.md --issue <N>
```

El título que se publica es el del **draft**: `<summary> (#<N>)`, con el número
del issue, porque el bot del reclamo lee el `#N` **en el título**. El pull
request que se pasa a **listo para revisión** NO lleva el número (la regla del
repo: el merge lo agrega, `(#N)`), y a ese título lo cambia el orquestador al
promoverlo: **no toques el título vos**.

El script arma el body **antes** de que el pull request exista: le agrega la
linea `Changes a default:` si falta, **valida** el body final con el parser del
upstream (`bin/pr-defaults-line.sh`), verifica el reclamo del issue, y recien ahi
abre el pull request (en draft). Si el body no pasa, **no abre nada**.

**Nunca `gh pr create` a mano.** Y no es una regla de estilo: es la causa
raiz del check rojo que el mantenedor ve.

### Por que el body tiene que llevar la linea ANTES de abrir

El check del upstream (`.github/workflows/pr-checks.yml`) corre con
`pull_request: types: [opened, edited, synchronize, ...]`: el job
**"Defaults line check"** se dispara **al abrir** el pull request, contra el
body que existe **en ese momento**. Si ese body no lleva la linea
`Changes a default:`, el check queda **rojo** y sigue en pantalla hasta el
proximo push (asi se freno #12891 y #12574: el PR se abrio con el body viejo
y el rojo quedo ahi, mirando el mantenedor).

Por eso el **orden** es todo:

1. el body se escribe **primero**, en un archivo, **con la linea
   `Changes a default:` ya adentro**;
2. ese archivo se valida (el script lo hace, con el parser del upstream);
3. recien ahi se abre el pull request.

**Un `gh pr edit` despues NO arregla un check rojo**: el check que fallo al
abrir ya quedo en pantalla, y el rojo se va solo con el proximo push. Si
falta la linea, el arreglo es **reabrir con el body completo**, no editar.

El script decide la linea de forma **honesta**:

- si el body **ya** trae una linea `Changes a default:`, **no la pisa**
  (ni un "yes" valido): una linea existente nunca se reescribe;
- si el body **no** trae la linea y el cambio **no toca** defaults, agrega
  `Changes a default: no` (que es la verdad);
- si el body **no** trae la linea y el cambio **si toca** defaults o
  preferencias, **no inventa un "no"**: no abre el pull request y te dice
  que la escribas vos, con la forma larga. El loop **no publica** un cambio
  de default: eso lo decide una **persona**.

Ademas el script es **idempotente**: si ya hay un pull request abierto
nuestro para ese issue, lo imprime y no abre un segundo. Y verifica el
**reclamo** antes de abrir: si el issue ya lo reclama otro pull request, no
abre nada.

### Si el pull request todavia NO esta abierto

Lo abris con el camino unico de arriba (nunca a mano). El body va en un
archivo que **ya lleva** la linea `Changes a default:` desde la primera linea:
es el mismo body que se publicaria, y el script lo valida antes de abrir.

### Si el pull request YA esta abierto

Lo normal es que el reclamo lo haya abierto en draft: en ese caso tu trabajo
**no** es abrir otro, es escribir el cuerpo final. El cuerpo va en un archivo
que **ya lleva** la linea `Changes a default:` desde la primera linea, y se
escribe entero:

```
gh pr edit <n> -R tangency-labs/solidcraft --body-file /tmp/pr-<N>-body.md
```

Un `gh pr edit` **despues** de abrir **no arregla** un check que ya fallo al
abrir: si el body con el que se abrio no tenia la linea, el rojo sigue en
pantalla y solo se va con el proximo push. En ese caso **no digas que el PR
esta listo para revisar**: decilo en el `summary`.

### Lo que no se abre a mano

```
# DENIED: el pull request se abre con publish-pr.sh, nunca a mano
gh pr create
```

## Precondiciones

- `phase == gated` en la vista de tu slot, y el gate fue **verde**. Hay **dos**
  gates que pueden estar verdes, y el cuerpo del PR dice cuál corrió:
  - el **completo**: `bin/gate-check.sh` dijo `VERDE` (gate.verdict). Cubrió
    todo el workspace.
  - el **de alcance** (scoped): la vista de tu slot → `scope_verdict` dice
    `VERDE-SCOPE`, con `scope_kind` = `packages` y `scope_new_failures` = 0.
    Cubrió **los paquetes que toca el cambio y sus dependencias inversas**, más
    `cargo fmt --check`, `cargo xtask layers` y un clippy acotado: **no corrió
    todo el workspace**, y el cuerpo del PR tiene que decirlo así.
- La revisión fue **aprobada**: la vista de tu slot → `review` dice `aprobado`
  (y `review_sha` es el tip de tu rama). Si dice `vetado`, **no publiques**:
  un veto es bloqueante.
- Cuota diaria: menos de `MAX_PR_PER_DAY` publicaciones hoy (vista de tu slot →
  `published`).
- `MIN_MINUTES_BETWEEN_PUBLISH` respected desde la última publicación: con `0` no hay separación — publicá en cuanto `phase: gated` y la revisión aprobada.

Si alguna precondición falla, **no publiques**: devolvé el motivo.

> **El `ci` del upstream NO es una precondición.** Un pull request en draft no
> corre CI (los jobs del upstream excluyen los drafts), así que el contexto `ci`
> no existe hasta que se hace `gh pr ready`. La publicación la autorizan el
> gate local y la revisión, nunca el CI del upstream.

> **De dónde sale el veredicto.** El veredicto de la revisión vive en el **log
> de la vuelta** (el output del worker `sc-review`): el supervisor lo lee de ahí
> y lo deja en la **vista de tu slot** → `review`. Vale sólo si el worker
> declaró `sha revisado: <sha de 40 hex>` con el tip de la rama: **sin
> `sha revisado:` no hay veredicto** (fail-closed) — el supervisor descarta el
> veredicto y el PR no se publica. Si `review` no dice `aprobado`, o el sha no
> coincide con el tip de la rama, **no publiques**.
>
> **El veredicto es de su slot**: el `aprobado` del slot 0 no habilita el PR
> del slot 1. Sólo el `review`/`review_sha` de **tu** vista habilita el PR de
> **tu** slot; si tu vista no dice `aprobado`, no publiques.

### Las cuotas (forma de `published`)

La vista de tu slot → `published` es un **mapa por fecha**, y cada fecha tiene una **lista de objetos** (no números sueltos):

```json
"published": {"2026-10-23": [{"pr": 5130, "at": 1798000000}]}
```

`at` es el epoch (segundos) de la publicación.

```
epoch de hoy 00:00 UTC:  date -u -d "today 00:00" +%s
publicaciones de hoy:    jq -r --argjson d0 <epoch> '[.published[] | .[] | select(.at >= $d0)] | length' ~/.local/share/solidcraft-loop/state/slot-<S>.json
última publicación:       jq -r '[.published[] | .[] | .at] | max // 0' ~/.local/share/solidcraft-loop/state/slot-<S>.json
```

`<S>` es el id de tu slot (`0` o `1`): usá la ruta exacta de `SLOT_VIEW`.

- **Cuota diaria**: el número de entradas con `at` de hoy < `MAX_PR_PER_DAY`.
- **Separación**: `ahora - última.at >= MIN_MINUTES_BETWEEN_PUBLISH * 60`. Con `0` no hay separación: publicá en cuanto el PR esté `gated` y la revisión aprobada.

La **vista de tu slot** la escribe el supervisor: vos **no** la escribís (ni
`published` ni `review`). El estado durable (`state.json`) tampoco lo escribís
vos: es del supervisor.

## Tu shell

- **Un comando por llamada.** Nada de `&&`, ni de `|`, ni de `;`: cada llamada es
  un paso, y una cadena denegada gasta el paso entero.
- Tu sandbox es una lista corta de comandos. **No pruebes comandos para ver si
  pasan**: cada denegacion es un paso perdido. Si un comando no esta en la
  lista, no lo intentes: hacelo con los que si estan.
- En `sc-publish` no esta `git fetch`, ni `ls`, ni `cat`, ni git remote. El
  `git fetch` no hace falta para el push con lease: la lease de
  `--force-with-lease` se compara contra el ref remoto local, asi que el push
  funciona mientras nadie mas haya pusheado esa rama.
- What you can use: `git status`, `git log`, `git rev-parse`, `git push fork ...`,
  `git push --force-with-lease fork ...`, `gh pr view`, `gh pr list`, `gh pr edit`,
  `gh pr ready`, `gh pr comment`, `gh api ...`, `gh issue view`, `gh issue comment`,
  `jq`, `date`.
- The only bash script you can run is the one that opens a pull request:
  `bash /home/user/.local/share/solidcraft-orch/bin/publish-pr.sh --repo tangency-labs/solidcraft --base main --head vdirienzo:<branch> --title "<summary> (#<N>)" --body "<el cuerpo>" --issue <N>`.
  In `sc-publish` you cannot write files, so the body goes inline in `--body`.
  The title you publish is the DRAFT's title: `<summary> (#<N>)`, because the
  claim bot reads the issue number THERE. The pull request that goes ready for
  review does NOT carry the number (the merge adds `(#N)`), and the orchestrator
  renames it when it promotes it: do not touch the title yourself.
- The body of a pull request that is **already open** is written with
  `gh pr edit` (GraphQL):
  `gh pr edit <n> -R tangency-labs/solidcraft --body-file /tmp/pr-<n>-body.md`.
  If you cannot write files, the body goes **inline**:
  `gh pr edit <n> -R tangency-labs/solidcraft --body "<text>"`.
  The body ALWAYS carries the `Changes a default:` line from its first line:
  the upstream check reads the body that exists at the moment the pull request
  is opened, and an edit does not fix a check that already failed.
  A pull request that is **not open yet** is NEVER written this way: it is
  opened by `publish-pr.sh`, with the body already complete.
- `gh api` **is** in your allow-list (`gh api *`), but the mutating verbs are
  denied (`PATCH`, `PUT`, `DELETE`, the merge endpoint and `graphql`): the REST
  way to write the body of an upstream PR is **not available in your sandbox**.
- The sandbox is more generous than GitHub: `gh pr edit` and `gh pr comment` are
  allowed, and **GitHub accepts them too**, because the loop is the **author** of
  its own pull requests (see the notice of the procedure). What GitHub does not
  let the loop do is merge, close, label, attach or push upstream.
- The **merge signal** is the orchestrator's job: it runs
  `bash ~/.local/share/solidcraft-loop/bin/merge-verdict.sh <pr> <sha>` and
  gives you the result in the brief. If the brief does not bring a signal, do
  not run it: describe only what you know.

## Un intento por cosa, y seguí

- **Un intento por cosa, y seguí.** No reintentes lo que GitHub rechazó por
  permisos: cada reintento quema pasos de la vuelta (el presupuesto es de 55
  minutos) y no puede pasar.
- Si el **cuerpo** del PR no se puede actualizar: dejá el texto corregido
  listo para pegar en `/tmp/pr-<N>-body.md` y decilo en el `summary` (el
  supervisor lo lleva al ledger y al reporte diario).
- El **comentario en el PR con el estado del CI no lo escribís vos**: lo
  escribe el loop (`bin/pr-comment.sh`) en la fase 2, cuando el `ci` del head
  esté verde de verdad. Todo lo que quieras contarle al maintainer va en el
  **comentario del issue** (`gh issue comment`), que es el canal que el humano
  sigue.
- Lo que **no** se puede escribir tiene que quedar escrito **en el reporte
  diario del fork**: así el humano lo ve sin tener que leer el log.

## Procedimiento

> **OJO: el token de la vuelta ya no es el PAT de sólo lectura.** Con el
> OAuth de `~/.config/gh/hosts.yml` (scope `repo`) el loop es la **autora** de
> sus propios PRs: por eso GitHub le deja **editar el cuerpo** (`gh pr edit`) y
> **comentar en el PR** (`gh pr comment`). Lo que **no** puede es mergear ni
> cerrar: no tiene write access en el upstream. Lo que **sí** funciona:
> pushear la rama al fork, `gh pr edit`, `gh pr comment`, `gh pr ready`, y
> comentar en el **issue**.

> **La publicación tiene DOS fases, y cada una dice lo suyo.**
>
> - **Fase 1 (esta vuelta):** push de la rama al fork → `gh pr ready` → cuerpo
>   del PR → comentario en el **issue** con la evidencia. Nada de esto dice
>   cómo está el CI.
> - **Fase 2 (la hace el loop, más tarde):** cuando el contexto `ci` del head
>   esté **verde de verdad**, `bin/pr-comment.sh` publica (o edita) el
>   **comentario del pull request** con el estado real del CI y con el gate
>   local que corrió.
>
> Por eso el **cuerpo del PR no dice cómo está el CI**: el cuerpo se lee
> cuando quiera el maintainer y el head se mueve, así que cualquier estado del
> CI escrito ahí se queda viejo. El estado del CI vive en el **comentario**,
> que se escribe en un momento y con ese momento.

1. **Push al remoto `fork`** (nunca `origin`):

```
git push fork refs/heads/<rama>
```

El push va **por refspec completo**: la rama puede estar checkouteada en un
worktree y entonces no se puede pushear por nombre.

Si venís de un **rebase** (modo maintenance, conflicto real), el push va con
`--force-with-lease` y **nunca** sobre `main`. La lease se compara contra el ref
remoto **local**: **la única forma que el sandbox acepta es
`git push --force-with-lease fork <rama>`** (la expectation explícita
`--force-with-lease=<rama>:<head_sha>` está DENEGADA). Es **un intento**: si
falla, decilo en el `summary` (no lo fuerces a mano).

```
git push --force-with-lease fork <rama>
```

2. **Sacarlo de draft**:

```
gh pr ready <n>
```

> `gh pr ready` funcionó el 23-10 (el PR #5530 salió de draft). Es **un intento
> por publicación**, no uno por vuelta: si GitHub lo rechaza,
> **anotalo en el `summary`** ("el PR queda en draft: hace falta que un humano
> lo saque de draft") — un PR en draft **no se puede mergear**, y eso tiene que
> verse en el reporte diario, no perderse.

Si el PR **ya no es draft**, no corras esto: `gh pr ready` falla en un PR
que ya salio de draft, y ese fallo parece un error de publicacion. En ese
caso el paso ya esta hecho: seguí al cuerpo y al comentario del issue.

3. **Cuerpo del PR: entero, con la linea `Changes a default:` adentro desde la
   primera linea**. Si el PR **todavia no esta abierto**, el cuerpo va en el
   archivo que le pasas a `publish-pr.sh` (que lo valida antes de abrir). Si el
   PR **ya esta abierto**, se escribe con `gh pr edit`.

**El cuerpo del PR va en inglés**, como todo lo que se escribe en el repo, y
sigue la forma del PR #7004 (el que el maintainer lee): la primera línea
cierra el issue, la segunda dice si el cambio altera un default, y después van
las secciones.

```
Fixes #<N>.

Changes a default: no

## Problem

<qué falla, con el caso concreto>

## Root cause

<por qué falla: el código, el archivo, la línea>

## Fix

<qué cambia: el cambio, no el diff>

## Tests

<la prueba de regresión: su nombre y qué comprueba>

## Evidence

<las capturas, por URL de raw.githubusercontent.com de la rama
`evidence/<N>-<slug>` del fork. **Media sólo cuando el cambio se ve en la UI o
cambia cómo se ve el modelo**: un arreglo de kernel o de geometría que los tests
prueban NO lleva media, y el PR tampoco la pide>

## Gate

<la frase del gate que corrió: la de la tabla de abajo>
```

> **El título lleva el número del issue SOLO mientras es draft.** El PR se abre
> en draft con el título del issue y su número: `<summary> (#N)`. El bot del
> upstream busca el `#N` **en el título**, y el guard de reclamos del loop lo
> busca en el título **y** en el cuerpo: un título al que le sakó el `(#N)` es un
> PR que el bot no asocia con su issue. El PR que se pasa a **listo para
> revisión** NO lleva el número —la regla del repo es que el merge lo agrega,
> `(#N)`— y a ese título lo cambia el orquestador al promoverlo. `gh pr edit`
> escribe **sólo el cuerpo**: si te pidieran tocar el título, no lo hagas y
> decilo en el `summary`.
>
> **La línea `Changes a default:` va siempre, y es la segunda línea.** El
> check del upstream (`pr-checks.yml`) falla el PR que no la tiene. Su valor
> lo dice el cambio de verdad, y el loop **sólo publica** cambios que **no**
> tocan un default: entonces la línea que el loop escribe es siempre
> `Changes a default: no`. Un `yes - <qué cambia>` lo escribe una
> **persona**, que es quien decide dejar el comportamiento viejo detrás de
> una preferencia (la regla del repo). El loop **no publica** un cambio de
> default: lo deja en el issue, escribe el motivo y lo escala a una persona.
> La primera línea (`Fixes #<N>.`) y esta son **obligatorias**: sin las dos, el
> cuerpo no pasa el check del upstream.
>
> El check de esa línea lo hace `bin/pr-defaults-line.sh`, que es de **sólo
> lectura**: mira, cuenta y reporta, y **nunca** escribe en un PR. Imprime
> `missing: <pr>` por cada PR nuestro que **no** tiene la línea, y termina
> con `checked: <n> missing: <m>`. Sale con **0** si todos la tienen, **1** si
> a alguno le falta, **2** si el uso está mal, y **6** si GitHub no se pudo
> leer: el **6** es **UNKNOWN** (el check **no se hizo**), nunca "la línea
> falta".
>
> **Vos no lo podés correr** (tu sandbox no tiene `bash`). Confirmá el cuerpo
> con `gh pr view <n> --json body`, y si la línea no está, **agregala a ese
> PR** con `gh pr edit`: el `gh pr edit` va sobre **el PR que el `missing:
> <pr>` nombre**, con el cuerpo entero (la línea de `Fixes #<N>.`, la de
> `Changes a default:` y las secciones de arriba), no sobre otro PR.

> **How to talk about the gate in the body: only what you know, and only the
> gate.** The body says **which local gate ran** and nothing else about the CI:
>
> | gate that ran | the sentence the body can use |
> |---|---|
> | the **complete** one (`gate.verdict` says `VERDE`) | "the full local gate (`cargo xtask ci`) is green on `<sha>`" |
> | the **scoped** one (`scope_verdict` says `VERDE-SCOPE`) | "the scoped gate (`<packages>`) is green on `<sha>`; the whole suite was not run" |
>
> **El gate completo está apagado por defecto** (`GATE_COMPLETE_MODE=off` en
> `config.env`): lo normal es que la vuelta vaya por el **de alcance**, así que
> la frase del body es la del gate de alcance. La del gate completo sólo se
> usa si tu vista trae `gate.verdict` = `VERDE` **de esta vuelta**: un
> `VERDE` viejo es un dato de otro commit y no habilita la frase.
>
> **Never** write "the full local gate is green" when only the scoped gate ran:
> that is a claim about a run that did not happen. The scoped gate covers the
> packages the change touches **and their reverse dependencies**, plus
> `cargo fmt --check`, `cargo xtask layers`, `cargo check --workspace
> --all-targets` and a scoped clippy, and **not** the whole workspace. Put the
> package list in the sentence: `<packages>` is
> the `scope_packages` of your slot (the packages of the scope, separated by
> spaces).
>
> **And the body never claims the state of the CI.** The upstream's cheap lane
> says whether the merge compiles; that is a fact about one head, and the head
> moves:
>
> | signal | what the body can say |
> |---|---|
> | `VERDE` | nothing about the upstream: that state goes in the comment of the pull request |
> | `ROJO` | nothing about the upstream: the rebase is the orchestrator's job |
> | `PENDIENTE` | nothing about the upstream |
> | `STALE` | nothing about the upstream: the signal is about another commit |
> | no signal in the brief | only the local gate, nothing about the upstream |
>
> The body never promises a green CI that nobody has seen, and it never
> announces a red one: it describes a change, it is not a status page.

> El loop es la **autora** del PR, así que `gh pr edit` **sí** funciona con el
> token de la vuelta (el OAuth de `hosts.yml`, scope `repo`). La vía REST
> (`gh api` con `PATCH`) **no**: está **denegada** en tu sandbox, y además va contra
> el **upstream**, no contra el fork (lo que deja editarlo es ser la autora
> del PR, no que el token escriba en el fork).
>
> ```
> gh pr edit <n> -R tangency-labs/solidcraft --body "<el cuerpo>"
> ```
>
> Si el archivo `/tmp/pr-<N>-body.md` ya existe (te lo deja el orquestador),
> usá `--body-file /tmp/pr-<N>-body.md` en vez del cuerpo inline: es lo mismo
> sin el quoting. Si no podés escribir archivos, el cuerpo va **inline** en el
> `--body`. Un intento: si GitHub lo rechaza, dejá el texto en el `summary` y
> anotalo como pending write.
>
> Los adjuntos tampoco se pueden subir: `gh pr edit --attach` pide write en el
> repo base y responde *"attaching files requires write access to the
> repository"*. No es un permiso que se pueda pedir: es una restriccion de la
> plataforma. Van por **URL**, nunca por archivo.
>
> **La via que si funciona desde un PR de un fork es una rama en el fork**: el
> supervisor publica los PNG en `evidence/<N>-<slug>` al final de cada vuelta y
> deja las URLs en `~/.local/share/solidcraft-loop/evidence/urls-<N>.txt`.
> **Te las paso en el brief**: ponelas en el cuerpo del PR como
>
> ```
> ![Before: ...](<url del before>)
> ![After: ...](<url del after>)
> ```
>
> **Media sólo en dos casos** (la regla del repo, `.agents/skills/
> solidcraft-contributing/SKILL.md`): (1) un cambio visible de UI (un diálogo, un
> panel, un menú, un control, una etiqueta o un layout) — antes y después; (2)
> un cambio en cómo se ve el modelo — una imagen del resultado. **Nada más
> necesita media**: un arreglo de kernel, de geometría o de backend que los
> tests prueban, un refactor, los tests, la documentación, el texto de un
> mensaje de error (se cita en el body) y los arreglos de review que no cambian
> nada visible. Si tu cambio es de esos, **no captures nada**: el tiempo de la
> captura en esta caja no lo va a pedir nadie.
>
> Un gist **no** sirve para esto: `gh gist create` rechaza los binarios y con el
> PNG en base64 dentro de un README el gist borra el `data:` URI y la imagen
> queda sin `src`.
>
> El maintainer preferiria que las imagenes estuvieran **adjuntas al PR**, pero
> eso no se puede sin write en el repo base: conviene **decirlo en el PR** para
> que el maintainer las adjunte si lo prefiere.
>
> Los PNG **nunca** van commiteados en la rama del fix: van en la rama de
> evidencia del fork.
>
> Si el brief **no trae URLs**, no inventes links: segui sin imagenes y decilo
> (puede ser que el cambio no sea observable en pantalla, o que la evidencia
> todavia no este publicada).

4. **Comentar el issue**:

```
gh issue comment <N> --body "PR listo para revisión: <url>"
```

Mandá **todo** lo que tengas que decirle al maintainer **acá**: el link al PR,
la evidencia (los mismos raw links que van en el cuerpo) y lo que haga falta.
El **comentario del PR con el estado del CI no lo escribís vos**: lo escribe
el loop en la fase 2 (`bin/pr-comment.sh`), cuando el `ci` del head esté verde
de verdad.

Un comentario por publicacion: si ya hay un comentario tuyo en el issue con
el link a este PR, no lo repitas: **mira los comentarios recientes del issue** (`gh issue view <N> -R tangency-labs/solidcraft --json comments`) antes de postear.

5. La vista de tu slot (y el estado durable `state.json`) los escribe el
supervisor: vos **no** lo escribís. Publicá y devolvé el contrato.

## Prohibido, sin excepciones

- `gh pr merge` — jamás. El merge es del maintainer.
- `gh issue close` — nunca. El issue lo cierra el merge (y `vdirienzo` no tiene
  permiso: da 403).
- `gh pr close` — nunca.
- `git push origin` — jamás.
- Publicar un cambio de default — nunca: el loop lo deja en el issue y lo
  escala a una persona.

## Contrato de salida (≤15 líneas)

```
pr: <número>
url: <link>
fecha: <YYYY-MM-DD>
issue comentado: sí | no
pr listo para revisión: sí | no (si no: queda en draft, hace falta un humano)
cuerpo del PR: sí | no (<dónde quedó el texto, o el motivo>)
gate que corrió: completo | de alcance (<paquetes>)
comentario en el PR: lo escribe el loop en la fase 2 (con el estado real del CI)
pendiente: <lista de lo que no pudiste escribir, en una línea>
```

El `summary` **es** el contrato de lo pendiente: listá explícitamente qué no
pudiste escribir (**cuerpo** / **comentario en el issue** / **`gh pr ready`**)
y **dónde dejaste el texto**. El orquestador (que arma el delta) lo copia al
`report_lines` del reporte diario del fork: lo que no se puede escribir tiene
que quedar escrito **ahí**, que es el único sitio con escritura, para que el
humano lo vea sin leer el log.

Si no podés cumplir el contrato, devolvé el motivo en una línea.
