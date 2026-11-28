# Digest de las reglas de upstream que cambiaron (2026-11-28)

Work: /home/user/Projects/solidcraft-orch · orch: solidcraft-orch/ · upstream: tangency-labs/solidcraft

- **Base (lo que el orquestador tiene hojeado)**: upstream `fe20baabd9c` (2026-11-21), que es lo
  que dice `rules-snapshot/SHA256SUMS`.
- **Head medido**: `origin/main` = `92455d4f6b`. El `48cdd5f5a5` que menciona el brief es un
  ancestro de ese head, no el head: el diff real es `fe20baabd9c..92455d4f6b`.
- **Cómo se comprobó**: `SOLIDCRAFT_REPO=/home/user/Projects/solidcraft-orch RULES_NO_FETCH=1
  bash bin/rules-snapshot.sh --diff` → 14 archivos, +121/−67. Después, `git diff
  fe20baabd9c..origin/main -- <archivo>` y lectura completa de los que importan.
- **No se modificó ningún archivo**: este reporte es el único escrito. No se corrió cargo.
- **Ojo con la hora**: mientras este digest se escribía (10:17–10:20 del 2026-11-28) **otra sesión
  editó `RULES.md`, `README.md` y los tres `prompts/agent-*.md`** del orquestador (el encabezado de
  `RULES.md` pasó a "2026-11-28", `README.md` creció de 507 a 524 líneas con un bloque nuevo, y los
  prompts pasaron a decir que el título NO lleva el número de issue). Todo lo de §6 cita **ese
  estado (10:20)**: los números de línea de `README.md` son los de las 524 líneas, los de
  `RULES.md` los de las 49. Si otra sesión vuelve a tocarlos, hay que releer antes de aplicar.

## 0. La línea, en una frase

Lo que cambió de verdad son tres cosas: **(a)** upstream cambió el comando de prepush de
`cargo xtask fast` a `cargo xtask ci` — que es el gate COMPLETO, el que esta caja no aguanta;
**(b)** el parser de `Changes a default:` ahora acepta muchas más formas y el bot del claim ya no
reporta como "de otro" un issue que el propio autor tiene; **(c)** upstream **invirtió** la regla de
rebase vs merge (ahora merge es lo barato). Todo lo demás es redacción, evidencia más estrecha y
dos listas nuevas.

## 1. Los 14 archivos, uno por uno

### 1.1 `AGENTS.md` (el router, la ley)
Reescrito casi entero en forma más corta y con dos reglas nuevas:

- Nueva: `- Kernel ops and math go in `solidcore/`; features call its API: `.agents/skills/solidcraft-layers/SKILL.md`.`
- Nueva/ajustada: `- Only `crates/kernel` uses truck; solidcore only via `solidcore-ops`/`-tess`/`-record` (`xtask/solidcore-seam.txt`): `cargo xtask layers`/`app-geometry`, `docs/layers.md`.`
- **La línea del gate cambió**:
  - antes: `- Run `cargo xtask fast` before each commit; CI runs the full gate.`
  - ahora: `- Before pushing: `cargo xtask ci`, which runs what your change needs. `cargo xtask skills` checks router and both skill folders.`
- Commit: `13a4fd5e17` "xtask ci: run the checks the branch needs, picked from its changed paths".

### 1.2 `CONTRIBUTING.md`
- **Paso 3 de "Sending a change" reescrito**:
  - antes: "Run `cargo xtask fast` before pushing: it checks what your change touches (for a kernel
    change in `solidcore/`, add `--units <id,...>` from your PR's `Units:` line to run their
    goldens). CI runs the rest of `cargo xtask ci` (fmt, the asset, licence and layer checks,
    clippy `-D warnings`, the tests and the wasm build check), so you need not run that locally."
  - ahora: "Run `cargo xtask ci` before pushing: it runs what your change needs, including the
    i18n and kernel-case coverage checks when your change touches their paths, and prints what it
    skipped and why (`--all` runs everything)."
  - y en la lista de comandos de §Desarrollo: `cargo xtask fast` **desapareció**; queda solo
    `cargo xtask ci   # before pushing: runs what your change needs`.
- **Rebase → merge invertido**: "bring your branch up to date with the latest `main` by merging
  `main` in or by rebasing; both are fine. **Merging costs less**: when the PR already passed and
  the merge leaves your own change as it was, CI carries the passing run and repeats only the
  repository checks (`scripts/ci/main_merge.py`). A rebase always re-runs the full suite, and you
  must push it with `--force-with-lease`." (antes: "Rebasing is preferred").
- **Sección nueva de migración a solidcore** (desde 0.40): SolidCraft = aplicación (comandos,
  timeline, sketches, UI, archivos); **solidcore = la geometría** (evaluadores, intersecciones,
  booleanas, blends, shells, sweeps, tessellation). "If a feature needs kernel functionality
  solidcore does not have yet, add it in `solidcore/` first, then use it from the app." Y el
  trabajo empieza antes de 0.40: "port it onto today's code, calling solidcore for the geometry,
  before it can land."
- **`Changes a default:`** reescrito: "Fixing janky or unintended behaviour is a bug fix, so `no`
  (a drag that cancelled now floats). Don't add a setting to keep old behaviour nobody would
  choose. `yes` is only for a deliberate change to established, intentional behaviour users rely
  on (sketch endpoints now merge instead of getting a coincident constraint)."
- **Tema (Theme)**: "The Theme list shows Light and Dark first, then the theme files by name."
- **Licencia**: la marca cubre solo "`assets/branding`, `assets/icons/app`, the SVG masters in
  `crates/look/icons/design/svg`"; el código de UI vuelve a MIT OR Apache-2.0 (commit `615a4adc1f`).

### 1.3 `.github/pull_request_template.md`
- El comentario de `Changes a default:` ahora dice (texto exacto):
  "Required line. Fixing janky or unintended behaviour is a bug fix, so it stays "no" (example: a
  drag that cancelled now floats). **Don't add a setting to keep old behaviour nobody would
  choose.** Use "yes" only for a deliberate change to established, intentional behaviour users rely
  on: a default value, key binding, setting or tool behaviour (example: sketch endpoints now merge
  instead of getting a coincident constraint). UX only; a kernel result change is 'no'."
- **Integration status**: el texto de cierre cambió de "by rebasing (preferred; push your own
  branch with `--force-with-lease`) or by merging `main` in" a "by merging `main` in (**cheaper: CI
  carries a passing run when the merge leaves your change as it was**) or by rebasing (push your own
  branch with `--force-with-lease`; the full suite runs again)".
- El resto del template (secciones `## Change`, `## Validation`, `## Screenshots of the behavior
  (when observable)`, `## Integration status`, el `Test change:` y el `Changes a default:` de
  ejemplo) **no cambió**.

### 1.4 `scripts/pr-checks/pr-checks.js` (el parser que hay que imitar)
Cambia `parseDefaults(body)` → `parseDefaults(body, { ownerApproved })` y se ensancha:

1. **Acepta la forma de encabezado**: además de la línea `Changes a default: <valor>`, ahora
   acepta un heading `## Changes a default` con el valor en la primera línea no vacía de abajo.
2. **`no` con texto detrás**: la regex pasó de `^no\.?$` a
   `/^no\b[ \t]*(?:[.!]*|[\p{P}\p{S}]+[ \t]*\S.*)$/iu` → valen `no.`, `no, only a fix`,
   `no — a new button`, `no. Only a fix.`, `no (only a fix)`, `no) …`.
3. **`yes` con cualquier puntuación**: la regex pasó de `yes` + `—|–|->|→|-{1,2}|:` a
   `/^yes\b[ \t]*[\p{P}\p{S}]+[ \t]*(.+)$/iu` → vale `yes, …`, `yes. …`, `yes — …`.
4. **Valor entre backticks**: `.replace(/^`([^`]*)`$/, '$1')` → `` Changes a default: `no` `` ahora
   se lee como `no`.
5. **Tercera forma de `yes`**: `Changes a default: yes - <what>, approved by the owner` (pasa
   `approvedByOwner`), y **con la etiqueta `owner-approved` cualquier `yes` pasa**, sin importar lo
   que siga ("The owner-approved label is the owner's approval: any `yes` line passes with it,
   whatever follows").
6. El `DEFAULTS_HELP` que se ve cuando el check falla ahora lista las tres formas.
- Commits: `16d1211309`, `85793dfae8`, `c004cb97fa`.
- **Lo que NO cambió**: los otros tres checks (`duplicate`, `picture`, `test change`) y las reglas
  de exención (bots, PR solo-docs, PR abiertos antes de 2026-10-25 / 2026-11-02).

### 1.5 `scripts/claim/claim.js`
Un solo cambio de comportamiento, en dos sitios, con el mismo motivo (commit `aa2d968689`,
"Claim bot: a contributor's own claimed issue is no longer reported as claimed by someone else",
#22986):

> "GitHub doesn't assign people who aren't collaborators: with nobody assigned, the bot's
> "Claimed by" reply is the record of who holds the issue, and it may name the commenter."

- En `claim()`: si nadie está asignado y el **último "Claimed by @X" del bot** es del que comenta,
  el bot responde con 👍 (`+1`) y **no** dice "Someone has claimed this already".
- En `handlePull()`: si nadie está asignado y el reclamante registrado es el **autor del PR**, el
  bot **no** comenta "#N is already claimed by someone else".
- Los plazos (`CLAIM_HOURS = 72`, `PR_IDLE_DAYS = 14`), la asignación, la etiqueta `in progress`,
  la regla "el PR abierto de número más bajo gana" y el `MAX_REFS = 5` **no cambiaron**.

### 1.6 `.agents/skills/solidcraft-contributing/SKILL.md` (el más cambiado)
- **Nuevo**: "**Search before you start.** Scan ALL issues and PRs, open and closed, for similar
  work (`gh issue list` and `gh pr list --state all --search`). New features are discussed on
  Discord, then get an issue. Kernel functionality goes in `solidcore/`, and features call its API
  …; work begun before 0.40 is ported onto today's code first."
- **Nuevo**: "**Check the scope before building.** A change that adds a dependency, background
  network or CPU work (polling, animation), or a new kind of feature rather than a fix is the kind
  most often declined after the work is done. Ask on the issue first, and build it once a
  maintainer agrees."
- **Nuevo**: "**Fix the cause.** When the right fix is in a lower layer (the kernel, cancellation, a
  shared helper), say so on the issue instead of building around it in the caller."
- **Gate**: "Run `cargo xtask ci` before pushing: it runs what your change needs." (antes
  "Run `cargo xtask fast` before every commit; CI runs the full gate (`cargo xtask ci`)").
- **Merge**: "Merging costs less: when the PR already passed and the merge leaves its own change
  as it was, CI carries the passing run and repeats only the repository checks, while a rebase
  re-runs the full suite".
- **Evidencia, ahora mucho más angosta** (commit `ea53c33068`, #17699): "Screenshots go in the PR
  up front, **only in these cases**: 1. A visible UI change (a new or changed dialog, panel, menu,
  control, label or layout): before and after, at 1280×720, plus a small-window check for a UI
  addition. 2. A change to what a model looks like (a feature that now builds, or builds
  differently): one image of the result from a small public-safe reproduction, before and after
  when there was a before. **Nothing else needs media**: kernel, geometry or backend fixes proven
  by tests, refactors, tests, documentation, error-message wording (quote the text in the body
  instead), a rebase or a merge of main, and review fixes that change nothing visible."
  Y: "**Reviewers ask for media only in those two cases**, and only when the PR has none."
- `gh repo fork tangency-labs/solidcraft --clone --remote` → `gh repo fork tangency-labs/solidcraft --clone`
  (commit `5934bfde0d`).

### 1.7 `.agents/skills/solidcraft-file-pr/SKILL.md`
Una línea: la forma del `Changes a default:` — "UX only: **a jank fix**, a kernel result, or new
behaviour on an input that did nothing is `no` **and keeps no setting**. `yes` is a deliberate
change to behaviour users rely on."
**El título no cambió** (ver §2).

### 1.8 `.agents/skills/solidcraft-babysit-pr/SKILL.md`
- Conflictos: "On a conflict, **merge the latest `main` in (cheaper: CI carries a passing run)** or
  rebase and push with `--force-with-lease`." (antes: rebase primero).
- Su script `scripts/pr-wait` ahora corre en Windows (lock con `msvcrt`, lectura UTF-8 de `gh` y de
  `git`); en Linux no cambia el comportamiento (commit `8591e94b3e`).

### 1.9 `.agents/skills/solidcraft-layers/SKILL.md`
- **Nuevo**: "`xtask/app-geometry.txt`: functions in the app crates that compute geometry
  (`cargo xtask app-geometry`). **A new one fails CI**; when you move one into `solidcore/`,
  delete its line."

### 1.10 `.agents/skills/solidcraft-packaging/SKILL.md`
- `packaging/` ahora incluye `packaging/python` (wheels; `pypi.yml`).

### 1.11 `.agents/skills/solidcraft-performance/SKILL.md`
- Nueva excepción a "Python nunca": "The one other exception is the Python client in `python/`
  (docs/python-api.md): standard library only, it runs in the user's own Python and drives
  `solidcraft-cli mcp`; the app never ships or imports Python."

### 1.12 `.agents/skills/solidcraft-preferences/SKILL.md`
- "A `yes` waits for a maintainer's decision. It is only for a deliberate change to intentional
  behaviour users rely on (sketch endpoints merging instead of a coincident constraint); **a jank fix
  is `no`**."
- "**Don't add a setting to keep old behaviour nobody would choose.**"

### 1.13 `.agents/skills/solidcraft-repro-first/SKILL.md`
- "`Changes a default: no` … If it also changes a shortcut or behaviour users there already rely on,
  that is `yes`, **but only for a deliberate change to behaviour they rely on, not for fixing
  something janky**."

### 1.14 `.agents/skills/solidcraft-ui/SKILL.md`
- Nuevo: "File previews: only `ui_kit::file_preview` (`docs/ui-kit.md`)."

## 2. El título del PR, ahora

**No cambió desde el snapshot.** La regla vigente (`.agents/skills/solidcraft-file-pr/SKILL.md`,
"The title"):

> "It becomes the commit on `main`. Form: `Area: what the user or caller now gets, in plain
> words`. … **No issue number (the merge adds `(#N)`)**, no `feat:`/`fix:`, no emoji, no "WIP"
> (open a draft). Under about 100 characters, important words first."

Y la excepción, que es del **reclamo**, no del PR final
(`solidcraft-contributing/SKILL.md` + `CONTRIBUTING.md`):

> "branch from the latest `origin/main`, `git commit --allow-empty -m "claim: #N"`, push, and open
> a **draft** PR titled `<summary> (#N)`. The lowest-numbered open PR for an issue wins; close yours
> if it lost."

O sea: **el `(#N)` va en el DRAFT del reclamo y no en el título del PR que se abre listo para
revisión**. El merge squash de GitHub ya pone "(#N)" en el mensaje de commit, así que un título con
el número produce "Título (#123) (#456)" en `main`.

## 3. El cuerpo del PR, ahora (qué lee `scripts/pr-checks/pr-checks.js`)

Cuatro cosas se leen del body. Solo dos son obligatorias siempre:

| línea | quién la lee | ¿obligatoria? | forma |
|---|---|---|---|
| `Fixes #N` | `parseClosing` (check de duplicados) y `claim.js` (`referencedIssues`) | **sí** (salvo PR solo-docs o sin issue, y salvo que se use `Refs`/referencia) | verbo de cierre + `#N`; acepta listas (`Fixes #1, #2 and #3`) y `owner/repo#N` del mismo repo; `Refs`/`Addresses`/`See` **no** cierran |
| `Changes a default: <valor>` | `parseDefaults` (check de defaults) | **sí** en todo PR que no sea solo-docs ni de bot (PR abiertos desde 2026-10-25) | `no` (o `no` + nota), `yes - <qué>, old behaviour kept behind preference <nombre>`, `yes - <qué>, approved by the owner` (con la etiqueta `owner-approved`), o la forma de heading `## Changes a default` con el valor abajo |
| `Test change: <razón>` | `testChangeReason` | **condicional**: solo si el PR toca fuente de kernel (`solidcore/`, `crates/smlib/`) **y** cambia o borra líneas de un test/golden existente | una línea con la razón (tests nuevos no la necesitan) |
| imagen/video | `hasPicture` | **condicional**: solo si el PR toca `docs/showcase.md` o `docs/screenshots/` | link visible en la descripción (un archivo en el diff no cuenta) |

Exenciones que siguen igual: PR de bot, PR solo-docs (`isDocsOnly`), y los PR abiertos antes de
2026-10-25 (defaults) o 2026-11-02 (imagen).

## 4. El claim, ahora

**El procedimiento no cambió** (mismo commit, mismo branch, mismo título de draft, misma regla de
ganar):

1. Buscar primero: PRs e issues abiertos **y cerrados** (`gh pr list --state all --search`).
2. `git commit --allow-empty -m "claim: #N"` sobre una rama desde el `origin/main` más nuevo, push.
3. Abrir un **draft** titulado `<summary> (#N)` con `Fixes #N` en el cuerpo.
4. **Gana el PR abierto de número más bajo**; si perdiste, se cierra el tuyo (o ayudás en el otro).
   Un PR tuyo no compite con otro tuyo.
5. El bot registra el reclamo: te asigna, pone `in progress` y lo dice en el issue ("Claimed by
   @vos"). Lee `#N` **en el título** y `Fixes #N` **en el cuerpo**. Si otro tiene el issue, o hay un
   PR abierto más viejo que lo referencia, lo dice **en tu PR**.
6. `/claim` en el issue sirve solo para stake'ar el reclamo **antes de tener rama**; `/unclaim` lo
   libera (solo vos o un maintainer).
7. Plazos: reclamo sin PR → 72 h; reclamo con PR → **14 días sin pushes**; un draft sin pushes
   puede ser tomado (comentar primero). Los issues de un maintainer nunca se liberan solos.

**Lo que cambió (commit `aa2d968689`):** GitHub no asigna a quien no es colaborador, así que para
nosotros el registro del reclamo es el **comentario "Claimed by @X" del propio bot**, no la lista de
assignees. Con ese cambio:
- Un `/claim` nuestro sobre un issue que ya tenemos **no** responde "Someone has claimed this
  already" sino 👍.
- Un PR nuestro que referencia un issue que ya tenemos **no** recibe el comentario "#N is already
  claimed by someone else" (que antes nos invitaba a cerrar nuestro propio PR).

## 5. El gate, ahora

`cargo xtask fast` y `cargo xtask ci` **existen los dos**. Lo que cambió es cuál es el comando de
prepush que upstream nombra.

**`cargo xtask ci`** (el que ahora manda upstream) — `xtask/src/ci.rs`:
- Siempre: `fmt --check`, `assets`, `icons`, `licences --check`, `lists`, `skills`, `layers`,
  `shared`, `ui-containers`, `mesh-decisions`, **`app-geometry`**,
  `cargo clippy --workspace --all-targets --profile ci -- -D warnings`,
  **los tests del workspace entero** (nextest perfil `local-ci`, o libtest), el **wasm check** de
  todas las crates de capa + la web app, los **doc tests**, y `web-offline-test` si hay Chrome.
- Path-gated (solo si el branch cambió esas rutas, `PATH_GATES`): `i18n --check`,
  `kernel-cases --coverage`, `plugin-examples`, `scripts/test-format-pending.sh`.
- Imprime qué corrió y qué salteó y por qué; `--all` corre todo; `--base REF` cambia la base
  (por defecto `origin/main`).

**`cargo xtask fast`** (el angosto, sigue existiendo) — `xtask/src/fast.rs`:
- Formato, los checks rápidos de `ci` (assets, lists, skills, layers, ui-containers,
  mesh-decisions; `shared`/`licences`/`icons` según rutas), **clippy del workspace** (reutiliza el
  build) y **los tests solo de los paquetes que el cambio toca** (`scripts/ci/affected.py
  --owners`; los tests pesados quedan fuera). Con kernel: clippy del workspace de solidcore, tests
  de solidcore salvo `goldens`/`solidcore-ops`, wasm de solidcore, y `--units <id,...>` para los
  goldens.
- `fast` **NO** corre `app-geometry`, ni `i18n --check`, ni `kernel-cases --coverage`, ni
  `plugin-examples`, ni el check de format-pending, ni el wasm del workspace, ni los doc tests.

**Lo que hay que correr antes de pushear, para esta caja**: el gate local se queda
`cargo xtask fast --base origin/main` **más los checks que `fast` no corre y que el cambio toque**
(`cargo xtask app-geometry` siempre; `i18n --check` / `kernel-cases --coverage` /
`plugin-examples` / `scripts/test-format-pending.sh` según rutas). El gate completo (`cargo xtask
ci`) **no entra en esta caja**: son 78 binarios de test y 56–90 min medidos acá
(`loop/bin/agent-issue.sh`), y solo puede correr uno a la vez. Va en el CI del fork.

## 6. Qué está mal en los documentos del orquestador (con el texto actual y el que debe decir)

### 6.1 `RULES.md` (49 líneas) — 3 bloques mal
- **L30-32** — actual: "**Los checks**: `cargo xtask fast` es el check antes de cada commit y push, y
  ahora prueba solo los paquetes que el cambio toca (antes corría todo). `cargo xtask ci` es el gate
  completo (repositorio + clippy + tests + wasm) y añade los checks que CI solo corre para ciertas
  rutas."
  → Debe decir: upstream ya no nombra `fast` como check de prepush; su router dice
  "Before pushing: `cargo xtask ci`". Pero `ci` es el gate COMPLETO (clippy del workspace + la
  suite entera del workspace + wasm + doc tests) y en esta caja no entra: el gate local sigue siendo
  `cargo xtask fast --base origin/main` **más** `cargo xtask app-geometry` (que `fast` no corre) y
  los path-gates que el cambio toque. Hay que dejar escrito que la desviación es **nuestra, por la
  máquina**, no la regla de upstream, y que el gate completo se corre en el CI del fork.
- **L27-29** — actual: "…El check de imagenes solo salta con `docs/showcase.md` o
  `docs/screenshots/`, pero el template pide la evidencia de lo observable."
  → Debe decir: la regla vigente (skill `solidcraft-contributing`, #17699) es **media solo en dos
  casos**: (1) cambio visible de UI (antes/después, 1280×720, y small-window si es una UI nueva),
  (2) cambio en cómo se ve el modelo (una imagen del resultado, antes/después si había antes).
  "Nothing else needs media: kernel, geometry or backend fixes proven by tests, refactors, tests,
  documentation, error-message wording (quote the text in the body instead), a rebase or a merge of
  main, and review fixes that change nothing visible." Y los reviewers solo piden media en esos dos
  casos y solo si el PR no tiene. El template sigue pidiendo más (no cambió), pero la skill manda.
- **L20-24** — actual: "…la línea `Changes a default: no` (o `yes - <qué>, el comportamiento viejo
  queda detrás de <ajuste>`; un arreglo de un comportamiento no intencionado es `no`)…"
  → Debe añadir: (a) `no` admite texto detrás (`no. Only a fix.`), (b) existe la forma de heading
  `## Changes a default` con el valor abajo, (c) existe una tercera forma de `yes`
  (`yes - <qué>, approved by the owner`, que exige la etiqueta `owner-approved`; con esa
  etiqueta **cualquier** `yes` pasa), (d) "no" además significa **"no agregar un ajuste para
  conservar el comportamiento viejo"**: un arreglo de jank es `no` y no deja preferencia.
- **L15** — el encabezado dice "Lo que upstream cambió el 2026-11-25": esa sección cubre solo la
  ola del 25 de noviembre. Esta ola (commits del 25 al 27: el gate, el parser de defaults, el bot
  del claim, la evidencia, el merge-vs-rebase, el ledger de `app-geometry`) **no está** en el
  archivo, y el L1 del archivo ya dice 2026-11-28.

### 6.2 `prompts/agent-brief.md`, `prompts/agent-9223.md`, `prompts/agent-21119.md` (65 líneas cada uno) — 3 bloques mal + 1 ya corregido
- **L27-32** — actual: "Take the heavy-build token around `cargo xtask fast` and other big builds:
  … Never build the whole workspace by hand; `cargo xtask fast` decides what to build, and it now
  tests only the packages the change touches."
  → Debe decir: upstream pide `cargo xtask ci` antes de pushear, pero ese comando no entra en esta
  caja (suite completa del workspace + wasm); el gate local es `cargo xtask fast --base
  origin/main` **más** `cargo xtask app-geometry` (chequeo nuevo, no lo corre `fast`) y los
  path-gates que el cambio toque. El gate completo se corre en el CI del fork.
- **L44-50 (cuerpo)** — actual: "The body follows `.github/pull_request_template.md`: …
  `Changes a default: no` (or the long `yes` form) …"
  → Debe decir: `no` para un arreglo de jank (y sin agregar preferencia para conservar el
  comportamiento viejo); `yes` solo para un cambio deliberado de comportamiento en el que la gente
  ya confía. Y el parser acepta `no` con nota, el heading `## Changes a default` y la forma
  `approved by the owner` (con etiqueta; no la pedimos nunca).
- **L53-56 (media)** — actual: "**No media or generated files in the diff** … Capture them yourself
  from the app, before and after."
  → Debe decir: la media solo se captura en los dos casos de upstream (UI visible; el modelo se ve
  distinto). En un fix de kernel/geometry que los tests prueban, **no** hay que capturar nada: eso
  ahora es tiempo perdido en esta caja (y una captura de más no la va a pedir nadie).
- **L16-18 (el título del draft) — YA ESTÁ CORREGIDO, pero no coincide con upstream.** Los tres
  prompts dicen hoy "open a DRAFT whose body has `Fixes #{{ISSUE}}` and `Changes a default: no`.
  **The title does NOT carry the issue number**: `Area: what the user now gets, in plain words`…".
  Eso sigue la regla de título de upstream ("No issue number (the merge adds `(#N)`)"), pero
  **se aparta de la instrucción literal del reclamo de upstream**: "open a **draft** PR titled
  `<summary> (#N)`, e.g. `Fillet: variable radius along a chain (#123)`" (`CONTRIBUTING.md` y
  `solidcraft-contributing/SKILL.md`). El bot lee el `#N` **del título o del cuerpo**, y el guard
  del orquestador (`bin/claim_rule.py`) es la unión de las dos, así que el reclamo se registra
  igual. No es un error: es una desviación que hay que **escribir** (en `RULES.md`), porque si no
  el próximo que lea los prompts cree que está copiando a upstream.
- **L64** — la clave del JSON es `"fast": "<the cargo xtask fast result>"`: si el gate local cambia,
  la clave o su valor tienen que nombrar el gate real (o el JSON tiene que explicar que "fast" =
  `xtask fast` + `app-geometry`).

### 6.3 `README.md` (524 líneas) — 4 bloques mal
- **L245-247 (bloque nuevo "Upstream moved its rules on 2026-11-25")** — actual: "**`cargo xtask
  fast` is the check before every push**, and it now tests only the packages the change touches.
  **`cargo xtask ci`** is the full gate (repository checks, clippy, tests, wasm) and adds the
  checks CI runs only for some paths."
  → Ahora el orden está invertido: el check de prepush que nombra upstream es `cargo xtask ci`
  ("Before pushing: `cargo xtask ci`, which runs what your change needs"), y `fast` es el check
  angosto que queda (lo siguen nombrando `babysit-pr`, `tests`, `full-stop`, `modernize`). Y hay
  que decir que en esta caja el local es `fast` (+ `app-geometry`) y el completo va al CI del fork.
  El bloque además tiene que cubrir esta ola (parser de defaults, bot del claim, evidencia, merge
  vs rebase, `app-geometry`), que no está.
- **L229-231 (regla 18)** — actual: "**`Changes a default: no` is the exact form** the upstream
  parser reads. Not "Changes to default: no". The position does not matter; a code fence, an HTML
  comment or backticks break it."
  → La forma exacta **existe**, pero el parser ahora acepta más: `no` con nota, el heading
  `## Changes a default` y el valor entre backticks (`` `no` `` ahora se lee como `no`, o sea la
  última frase —"backticks break it"— ya no es cierta para el valor; lo que sigue rompiendo la
  línea es estar **dentro** de un bloque de código o de un comentario HTML).
- **L506-507** — actual: "cargo xtask fast --base origin/main   # upstream's own pre-push check:
  fmt, layers, clippy, check, nextest (what the local gate runs)"
  → Ya no es "upstream's own pre-push check": upstream apunta a `cargo xtask ci`. Decir que es el
  **gate local angosto** de esta caja, que es lo que `fast` sigue siendo upstream (babysit-pr,
  tests, full-stop, modernize lo nombran), y que no es el gate completo.
- **L524** — actual: "the rules of upstream (the truth) | `AGENTS.md`, `CONTRIBUTING.md` and `skills/`
  in the SolidCraft repository"
  → `skills/` son las skills del MCP de la app; las reglas de agentes están en `.agents/skills/`
  (y `skills/` no estaba en el snapshot por eso).
- **L364** — "| `bin/gate.sh` | the local gate (`cargo xtask fast --base`) |" — la frase está bien (es
  el gate local), pero conviene que diga "local" y no "el gate", y que el pie de la tabla apunte al
  gate completo en el CI del fork.

### 6.4 Scripts del orquestador (no son documentos, pero se contradicen con upstream)
- **`bin/pipeline.py` L1229-1256** — la copia local del parser quedó **más estricta** que upstream:
  `RE_DEFAULTS_NO = ^no\.?$` y `RE_DEFAULTS_YES` exige `—|–|->|→|-{1,2}|:`. Con el parser nuevo de
  upstream, un body con `Changes a default: no. Only a fix.` o con `yes, …` (coma) es **válido
  upstream** y acá `linea_defaults_malformada()` lo marca mal formado → `bin/publish-pr.sh` muere
  con exit 3 y el PR queda en draft. Y el heading `## Changes a default` no lo ve (cuenta 0 líneas).
  Fix: usar el parser del upstream como hace `loop/bin/pr-defaults-line.sh` (que lo llama con
  `node`), o copiar las regex nuevas.
- **`bin/verify-pr.sh` L190-192** — cuenta las líneas `^Changes a default:` y exige exactamente 1;
  un body con la forma de heading cuenta 0 → "bad" aunque upstream lo acepte.
- **`bin/gate.sh` L43-44** — el comentario **cita textual** de upstream: "what this script runs is
  upstream's own pre-push check, `cargo xtask fast --base <base>` (CONTRIBUTING.md: "Run cargo xtask
  fast before pushing ... CI runs the rest")". Esa frase ya no existe en `CONTRIBUTING.md` (L418
  ahora dice `cargo xtask ci`) y `fast` ya no es "upstream's own pre-push check". La cita tiene que
  decir: "el gate local angosto de esta caja; upstream nombra `cargo xtask ci` para el prepush, que
  no entra acá".
- **`loop/prompts/publish.md` L342-347** (y L45 y L200, y `loop/prompts/claim.md` L68-80,
  `loop/prompts/iteration.md` L442) — publicamos **todos** los PRs con `--title "<summary>
  (#<N>)"` y dicen "**El título del PR no se toca, nunca.** … un título al que le sakó el `(#N)`
  es un PR que el bot no asocia con su issue". Eso contradice **dos** cosas: la regla de título de
  upstream ("No issue number (the merge adds `(#N)`)") y **los propios prompts del orquestador**,
  que desde las 10:20 de hoy dicen "The title does NOT carry the issue number". (El bot asocia por
  el cuerpo, `Fixes #N`: quitar el `(#N)` no rompe el reclamo.) Hay que elegir: renombrar el PR al
  pasarlo a listo, o dejar la desviación escrita a mano en `RULES.md` — pero no pueden quedar dos
  reglas opuestas en el mismo repo.
- **`docs/known-traps.md` L57-63** — describe el parser de upstream como si aceptara solo `no` o
  `yes - <qué>, old behaviour kept behind preference <nombre>`: hoy acepta más (ver §1.4).
- **`docs/verifying-a-delegated-pr.md` L23/57-77, `prompts/agent-*.md` L11,
  `briefs/brief-9223-rebase.md`** — mandan rebasar + `--force-with-lease`; upstream invirtió eso
  (mergear `main` es lo barato: el CI arrastra el run verde; un rebase re-corre la suite entera).
  Para el PR conviene mergear; para el árbol local de la máquina, rebase o merge da igual.

### 6.5 Lo que NO está mal (no hay que tocarlo)
- `RULES.md` L17-19 (el título **no** lleva el número; el merge lo agrega) — coincide con upstream.
- `RULES.md` L38-40 (el reclamo: commit vacío `claim: #N`, draft, `Fixes #N`, gana el número más
  bajo, si perdimos se cierra el nuestro) — coincide con upstream.
- `RULES.md` L22-26 (`Test change:`, `KNOWN_FAILING_TESTS`, capturas en la descripción) — coincide.
- `README.md` L216-218 (72 h del `/claim` vs 14 días del draft) — coincide con `claim.js`.
- El procedimiento del reclamo (commit, rama, `/claim`, plazos, quién gana) — no cambió; lo único
  que se aparta es el título del draft (ver §6.2).

## 7. Esta caja (12 cores, 15 GB, un build pesado a la vez)

| check | costo acá | veredicto |
|---|---|---|
| `cargo xtask app-geometry` | escaneo de fuentes, sin compilar | **barato** — pero es nuevo y `fast` NO lo corre: hay que correrlo siempre |
| `cargo xtask layers`, `skills`, `lists`, `assets`, `icons`, `mesh-decisions`, `ui-containers` | segundos | baratos (ya entran en `fast`) |
| `cargo xtask i18n --check`, `kernel-cases --coverage`, `plugin-examples`, `scripts/test-format-pending.sh` | necesitan la CLI compilada | **baratos por separado**, y son los que `fast` no corre: correrlos si el cambio toca `assets/locales/**`, `crates/ui-egui/**`, `crates/engine/src/cmd/**`, `apps/solidcraft-cli/**`, `xtask/src/i18n.rs`, `tests/kernel-cases/**`, `xtask/src/kernel_cases.rs`, `docs/book/plugin-examples/**`, `crates/craft-plugin/wit/**`, `crates/doc/src/format/**` |
| `cargo xtask fast --base origin/main` | clippy del workspace + tests de los paquetes tocados | **el gate local**: es lo que ya usa `bin/gate.sh` |
| `cargo xtask ci` | clippy del workspace + **suite completa (78 binarios, 56–90 min medidos)** + wasm de todas las crates + doc tests + web-offline-test | **no entra**: que lo corra el CI del fork (`GATE_MODE=fork-ci`) |
| `cargo xtask wasm` | build de todas las crates de capa para wasm32 | caro; solo lo pide `ci` |
| el bot del claim y el parser de defaults | nada (no compilan) | gratis: los cambios no exigen build |

Nuevo riesgo de CI que el gate local no ve: **`xtask/app-geometry.txt`** — una función NUEVA que
calcule geometría en las crates de la app (`crates/doc`, `engine`, `ui-egui`, `io`, `kernel`, `geom`)
**falla el CI de upstream**, y el gate local (`fast`) no lo mira. Con `app-geometry` en el gate local
se ve antes. Y la regla de fondo es nueva y dura: **la geometría va en `solidcore/`**, la app la
consume.

## 8. Orden de trabajo sugerido (para que la actualización sea a propósito)

1. `RULES.md`: el gate (L30-32), la evidencia (L27-29), las formas del `Changes a default:`
   (L20-24), y el encabezado de la sección (L15) que solo cubre la ola del 25.
2. `prompts/agent-brief.md` + `prompts/agent-9223.md` + `prompts/agent-21119.md`: el gate, la
   evidencia y el `Changes a default:` (mismo texto en los tres; el título **ya** está como upstream
   lo quiere, salvo la desviación del draft que hay que escribir).
3. `README.md`: el bloque nuevo L233-248 (el gate primero, y esta ola), L229-231 (el parser),
   L506-507 (el gate local), L524 (`skills/` → `.agents/skills/`).
4. Scripts: `bin/pipeline.py` (usar el parser de upstream), `bin/verify-pr.sh` (el heading),
   `bin/gate.sh` (la cita vieja, L43-44 y L101 y L337), `bin/test-gate-claim.sh` (L36 y L651: el
   caso 7b sigue siendo válido —el gate local es `xtask fast`— pero el comentario que lo llama
   "upstream's `cargo xtask fast`" hay que corregirlo), `loop/prompts/publish.md` / `claim.md` /
   `iteration.md` (el `(#N)` en el título, que hoy contradice a los prompts).
5. `docs/known-traps.md` L57-63 y `docs/verifying-a-delegated-pr.md` (rebase vs merge).
6. Solo al final: `bash bin/rules-snapshot.sh --update` (deja el snapshot en `92455d4f6b`).

## 9. Lo que más sorprendió

`cargo xtask ci` no es "el check que corre lo que tu cambio necesita": es el gate COMPLETO (clippy
del workspace + la suite entera del workspace + wasm + doc tests). La frase "runs what your change
needs" de upstream describe solo los **cuatro path-gates** (i18n, kernel-cases, plugin-examples,
format-pending). Y upstream se contradice: el router, `CONTRIBUTING.md` y el skill de contribuir
dicen `cargo xtask ci` antes de pushear, pero `babysit-pr`, `tests`, `full-stop` y `modernize`
siguen diciendo `cargo xtask fast`, y `fast` sigue siendo "the local check before a commit and a
push" en su propio encabezado. O sea: seguir la regla nueva al pie de la letra en esta caja es
imposible (78 binarios de test, 56–90 min, un build a la vez, 15 GB), y el gate local tiene que
quedarse siendo `fast` — más los checks que `fast` no corre.
