# Brief: PR #9843 y #11074 - arreglar los hallazgos de CodeRabbit (issues #7114 y #5237)

## Contexto
Dos PRs abiertos del fork con hallazgos SIN RESOLVER de CodeRabbit (2026-11-04).
NO abras PRs nuevos: estos dos ya existen. NO toques origin. Push SOLO al fork.

## PR #9843 (issue #7114) - https://github.com/tangency-labs/solidcraft/pull/9843 (head 9c7f595d)
Rama: fix/issue-9843-grid-crossing (o la que tenga en el fork). Worktree: /home/user/solidcraft-wt/issue-9843 (verificar que existe y a que rama apunta).

Hallazgo 1 (Major) - crates/engine/src/view.rs:422 - `sketch_grid_step` sigue devolviendo `minor` a secas (lineas 420-423) sin derivar las cruces elegibles de las lineas que `grid_lines` dibuja de verdad. En la zona de blend 2->5 se puede hacer snap a una cruza SIN linea dibujada. Ademas `no_snap` devuelve el puntero crudo en vez de conservar el lattice fino.
   FIX: derivar el paso de la grilla de las lineas que `grid_lines` realmente dibuja, y que `no_snap` conserve el lattice fino (devuelva el punto del lattice, no el puntero crudo).
   OJO: el pre-merge check "Existing Defaults Unchanged" esta en rojo. Si el comportamiento por defecto cambia de verdad, NO lo cambies: ponelo detras de una preferencia explicita y mantené el default actual. El PR declara `Changes a default: no`, asi que el default NO puede cambiar.

Hallazgo 2 (Major) - crates/engine/src/view.rs:468 - `sketch_grid_takes_crossing` mantiene `d <= fine || (l > fine/4.0 && d <= minor/4.0)`. Con minor=5 y fine=0.5, un puntero en (21.2, 20) (a 1.2 mm de la cruza) cae en (20,20), moviendo el punto mas de dos pasos finos. Eso contradice `Changes a default: no`.
   FIX: ajustar la tolerancia para que el snap a la cruza solo aplique cuando la cruza este dentro de lo que se muestra, y que el desplazamiento no exceda lo que el lattice fino permite.

Ademas del body (no son codigo pero el PR esta roto):
   - El body dice "The PR stays a draft" pero el PR NO es draft (isDraft=false). Corregir el texto del body.
   - Las 2 capturas son links sueltos a raw.githubusercontent.com, NO imagenes embebidas. El check `hasPicture` del upstream (que reconoce `![](...)`, `<img src>` o `user-attachments`) devuelve false. Embeber las imagenes de verdad en el body.

## PR #11074 (issue #5237) - https://github.com/tangency-labs/solidcraft/pull/11074 (head 8f35b629)
Rama del fork del PR. Worktree: /home/user/solidcraft-wt/issue-5237 (verificar).
Hallazgo 1 - xtask/src/book.rs:177 - la celda de descripcion usa `table_cell(&row.description)`, que escapa backslash y pipe pero NO la sintaxis Markdown inline (backticks, `*`, `_`, `[t](u)`). El resto del archivo usa `prose()` para texto literal.
   FIX: usar `prose(&row.description)`.
Hallazgo 2 - xtask/src/params.rs:216 - `scan_type` no corta el tipo en el punto final antes de `Returns sides`. Afecta a `sketch.rectangle.center` (crates/engine/src/cmd/sketch.rs:90): el tipo mostrado llega a ser `bool. Returns sides {bottom, right, top, left}`.
   FIX: cortar el tipo en el punto final antes de `Returns sides`.
Ademas del body:
   - Dice `Fixes #5237` pero el issue pide ademas tips, ejemplos, capturas y crowd-sourcing de snippets: el PR solo entrega la tabla de parametros. Cambiar a `Addresses #5237`.
   - El bloque del gate pegado en el body cita `SHA=fd9b1fbc...` que NO es el head (8f35b629). Corregir el SHA o sacar el bloque.

## Tests
Los dos cambios son de presentacion/parametros. Para #11074:
   cd /home/user/solidcraft-wt/issue-5237
   CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-loop/targets/slot-5237 CARGO_BUILD_JOBS=4 CARGO_INCREMENTAL=0 nice -n 19 cargo test -p xtask --lib
Para #9843:
   cd /home/user/solidcraft-wt/issue-9843
   CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-loop/targets/slot-9843 CARGO_BUILD_JOBS=4 CARGO_INCREMENTAL=0 nice -n 19 cargo test -p solidcraft-engine grid --lib
Si el build se pasa de 4 GiB de RAM, no es fallo tuyo: la wave tiene slots. Deja el codigo commiteado y reportalo.

## Commits y push
- PR #9843: dos commits separados (uno por hallazgo) + un tercero si tocaste el body. Mensajes:
  `fix: snap only to the crossings the grid actually draws`
  `fix: keep the fine lattice when the snap is refused`
- PR #11074: dos commits separados:
  `fix: render the parameter description as prose`
  `fix: cut the parameter type at the end of the sentence`
- Push SOLO al fork: git push fork HEAD:<rama-del-pr>
  Verificar con `git remote -v` que 'fork' = vdirienzo/solidcraft. Si no existe, NO lo crees: reporta.
- Los bodies de los PRs se actualizan con: gh pr edit <N> --repo tangency-labs/solidcraft --body-file <archivo>
  (guarda el body actual antes, no lo reescribas de memoria)

## Entrega
Por PR: SHA de cada commit, salida de los tests, y confirmacion de que el body quedo corregido (diff del body).
