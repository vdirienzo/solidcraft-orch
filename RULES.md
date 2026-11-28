# Reglas del orquestador (2026-11-28)

Las reglas de SolidCraft viven en upstream, no acá: `AGENTS.md`, `CONTRIBUTING.md` y
`.agents/skills/*/SKILL.md` en `origin/main` (las de desarrollo están en `.agents/skills/`; las de
`skills/` son las del MCP de la app). El checkout local (`/home/user/Projects/solidcraft-orch`)
está en `origin/main`; si se atrasa, `git merge --ff-only origin/main` lo pone al día (los
agentes leen código ahí).
Para un PR: `solidcraft-full-stop` (de punta a punta), `solidcraft-file-pr`,
`solidcraft-babysit-pr` (su `scripts/pr-wait`), `solidcraft-takeover`, `solidcraft-repro-first` y
`solidcraft-kernel-rules`.

`bash bin/rules-sync.sh` hace `git fetch origin` y dice si upstream movió alguna. Exit 1 con la
lista: la wave para, se lee `bash bin/rules-snapshot.sh --diff`, se revisan este archivo y
`prompts/`, y recién entonces `bash bin/rules-snapshot.sh --update`.

**Un job vigila esto solo**: la automatización `solidcraft-rules-watch` (`aut_2228f2ea80017aGM26OozSO5bM`)
corre `bash bin/rules-verdict.sh` cada 6 horas y trae el veredicto: OK, CAMBIÓ (con los ficheros y
el diff stat) o NO SE PUDO COMPROBAR. **Solo lee**: no cambia nada, no publica, no fusiona. Cuando
avisa que algo se movió, la actualización la ordena una persona y la hace un subagente con este
archivo y `prompts/` como destino.

## Lo que upstream cambió (2026-11-25 y 2026-11-28) y lo que el orquestador hace ahora

- **El título**: el **draft de reclamo** lleva el número (`<resumen> (#N)`), porque el bot del
  reclamo lee ahí el issue. El **PR listo para revisión no lo lleva**: `Area: qué recibe ahora el
  usuario`, en presente, sin `feat:`/`fix:`, sin emoji, ~100 caracteres. El merge añade el `(#N)`.
  Un seguimiento lo dice en el título: `(follow-up to #23431)`.
- **El cuerpo**: `Fixes #N` (una palabra de cierre; `Refs` no cierra) y la línea
  `Changes a default:`. El parser acepta `no` (también con una nota detrás, `no. Only a fix.`),
  el heading `## Changes a default` con el valor debajo, el valor entre comillas invertidas, y
  `yes - <qué>, el comportamiento viejo queda detrás de <ajuste>`. Un arreglo de jank o de
  comportamiento no intencionado es `no` y **no** deja un ajuste para conservar lo viejo; `yes` es
  solo un cambio deliberado de algo en lo que la gente ya confía.
- **`Test change: <por qué el valor viejo estaba mal>`** solo cuando el diff toca fuente del
  kernel (`solidcore/`, `crates/smlib/`) **y** cambia o borra una línea de un test o un golden
  existente. Tests nuevos no la necesitan.
- **Media**: upstream pide capturas solo en dos casos: un cambio visible de la UI, o un cambio en
  cómo se ve el modelo. Un fix de kernel o de geometría probado con tests no lleva media
  ("nothing else needs media"). Cuando sí hace falta, van en la descripción como enlaces, nunca
  en el diff, y sin datos privados (rutas del home, nombres de usuario, tokens).
- **`tests/KNOWN_FAILING_TESTS`**: si el fix hace pasar un test de la lista, su línea se borra en
  el mismo PR (el CI falla tanto por una regresión como por un test listado que ahora pasa).
- **El gate**: upstream dice "Before pushing: `cargo xtask ci`", pero ese `ci` corre SIEMPRE el
  clippy de todo el workspace, la suite completa (78 binarios de test, 56-90 min medidos en esta
  caja), el wasm de cada crate y los doc tests; solo cuatro checks se eligen por rutas tocadas
  (`i18n --check`, `kernel-cases --coverage`, `plugin-examples`,
  `scripts/test-format-pending.sh`). En esta caja el gate local es
  **`cargo xtask fast --base origin/main`** (prueba solo los paquetes que toca el cambio) más
  **`cargo xtask app-geometry`** (nuevo, `fast` no lo corre) y los path-gates que el cambio
  toque; el `ci` completo va al CI.
- **Estar al día con `main`**: lo barato es **mergear `main` dentro** (el CI arrastra el run verde
  si el merge deja el cambio como estaba); un rebase re-corre la suite entera. Rebasar también
  vale, con `--force-with-lease` y solo sobre tu rama.
- **El reclamo**: commit vacío `claim: #N` en `fix-N` desde el `origin/main` más reciente, PR
  draft con `Fixes #N` en el body, y `bash bin/claim-verify.sh N --our-pr <pr>` (0 nuestro, 1
  perdido, 2 no se sabe). Gana el PR abierto de número más bajo; si perdemos, cerramos el nuestro.
  El bot asigna, pone `in progress` y comenta "Claimed by @...": ese comentario es el registro de
  quién tiene el issue. Un reclamo sin PR caduca a las 72 h; con PR, a los 14 días sin pushes.
- **El PR se abre listo para revisión** cuando el cambio está hecho: el draft es solo el reclamo.

## Solo de este orquestador

1. Push solo al fork (`fork` = vdirienzo). `origin` es upstream: se lee, no se empuja.
2. El claim va primero (ver arriba), con el título del draft llevando el número del issue.
3. Inglés en todo lo público: títulos, bodies, commits y comentarios.
4. Sin comentarios de estado, y nunca pedir `approved-for-ci` (lo pone el maintainer).
5. Esta caja (12 cores, 15 GB) no compila el kernel: se vetan los issues de `crates/kernel` y
   `solidcore/`. Upstream los acepta; el veto es nuestro, por la máquina.
6. Un build pesado a la vez: `bash bin/slot-lock.sh --heavy --take --wait 3600`, con `nice`.
7. Nunca fusionar, nunca encolar, nunca poner `ready to merge` o `approved-for-ci` a nuestro PR
   (los pone el maintainer), ni pedirle a otro agente que lo haga.
8. Un PR nuestro ya fusionado al que le falta algo se sigue con un PR de seguimiento desde la
   rama, con su propio título; el issue ya cerrado se referencia con `Refs`.
9. Los briefs canónicos viven en `~/.local/share/solidcraft-orch/briefs/` (no en `/tmp`) y los
   valida `bash bin/test-briefs.sh`, que comprueba que las rutas que citan existen en upstream.
