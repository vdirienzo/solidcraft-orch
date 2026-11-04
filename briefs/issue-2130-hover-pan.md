# Brief: #2130 - la highlight de la cara se apaga mientras se panea

**Objetivo unico: que el test `hover_pan_tests` de `crates/ui-egui/src/viewport_hover_pan_tests.rs` pase.**

El issue #2130 esta ABIERTO y LIBRE. El test RED ya esta escrito y VERIFICADO (falla):
`assertion failed: the highlight under the pointer must stay on while the view is panned (#2130): None`

- Rama del test: `test/issue-2130-hover-pan` en el fork (ya pusheada).
- Worktree: `/home/user/solidcraft-wt/issue-2130`, con el test y el `mod viewport_hover_pan_tests;`
  ya en `crates/ui-egui/src/viewport.rs`. NO vuelvas a escribir el test.

## La causa raiz (esta localizada; no la re-descubras)

`crates/ui-egui/src/viewport.rs:4463-4479`: el bucle de frames calcula `navigating` (true mientras
`pan != egui::Vec2::ZERO`) y con eso FILTRA el pick de hover con `!navigating`, dejando
`app.viewport.hover = None` durante todo el gesto de navegacion. La misma supresion esta en
`crates/ui-egui/src/render_workspace.rs:2084-2096` (el viewport de RENDER).

El reporter (voki6) hoverio una cara y paneo con dos dedos en el trackpad: la highlight blanca
empezo a parpadear.

## Como lo tiene que resolver (el criterio, no el codigo)

El highlight debe SEGUIR ENCENDIDO durante el gesto de navegacion, sobre el objeto que estaba
bajo el cursor. Ojo con la tentacion de borrar el filtro a pelo: durante el paneo el pick se
recalcula y por eso el filtro existe. Lo que NO puede pasar es que el highlight se apague.
La forma canonica de decirlo: durante la navegacion el hover se CONGELA (se conserva el ultimo
valor, no se recalcula ni se borra), en vez de apagarse.

Si al implementarlo te aparece que congelar el hover rompe otro comportamiento (por ejemplo, que
al soltar el gesto quede un highlight sobre una cara que ya no esta bajo el cursor), resolvelo
ASI: al terminar el gesto, el hover se vuelve a calcular. El test te dice cuando el highlight
debe estar encendido; no inventes criterios extra.

## Pasos

1. ```
   cd /home/user/solidcraft-wt/issue-2130
   git fetch fork && git checkout -b fix/issue-2130-hover-pan && git reset --soft test/issue-2130-hover-pan
   ```
   Si la rama de test ya esta en el worktree, solo crea la rama de fix desde el mismo commit.
2. Implementa el fix. Despues:
   ```
   export CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-2130
   export CARGO_INCREMENTAL=0
   export CARGO_BUILD_JOBS=4
   cargo test -p solidcraft-ui-egui --profile ci --lib hover_pan_tests -- --nocapture
   ```
   Debe pasar. Ademas corre los tests de la zona: `cargo test -p solidcraft-ui-egui --profile ci --lib viewport`
   y reportá cuantos fallan antes y despues (hay fallos preexistentes del kernel: son los del
   catalogo `tests/KNOWN_FAILING_TESTS`, no los persigas).
3. ```
   cargo fmt -p solidcraft-ui-egui --check
   cargo clippy -p solidcraft-ui-egui --all-targets --profile ci -- -D warnings
   ```
4. ```
   git add <los archivos que tocaste, uno por uno, NO git add -A>
   git commit -m "UI: the face highlight stays on while the view is panned (#2130)"
   git push fork fix/issue-2130-hover-pan
   ```
   NUNCA push a `origin`. NO abras PR: el orquestador lo publica.
5. Gate: `bash /home/user/.local/share/solidcraft-orch/bin/gate.sh 2130 <SHA>` (fuera de systemd-run;
   si dice `no free build slot`, esperá 5 min y reintentá hasta 3 veces).

## Lo que hay que devolver

El comando del test y su salida (que tests pasan, cuantos), el `scope.verdict` del gate, y el SHA.
Si el fix no se puede hacer sin romper otra cosa, decilo con el error exacto. No inventes resultados.
