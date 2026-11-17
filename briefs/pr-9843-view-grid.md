# Brief: PR #9843 - los dos hallazgos mayores de CodeRabbit (issue #7114)

## Contexto
PR abierto: https://github.com/tangency-labs/solidcraft/pull/9843 (head 9c7f595d).
Worktree: /home/user/solidcraft-wt/issue-9843 (verificar a que rama apunta).
NO abras un PR nuevo. Push SOLO al fork (vdirienzo/solidcraft). NUNCA a origin.
El body del PR ya esta corregido (frase del draft + capturas embebidas): NO lo toques.

## Hallazgo 1 (Mayor) - crates/engine/src/view.rs:422
`sketch_grid_step` sigue devolviendo `minor` a secas (lineas 420-423) sin derivar las cruces
elegibles de las lineas que `grid_lines` dibuja de verdad. En la zona de blend 2->5 se puede
hacer snap a una cruza SIN linea dibujada. Ademas `no_snap` devuelve el puntero crudo en vez
de conservar el lattice fino.
FIX: derivar el paso de la grilla de las lineas que `grid_lines` realmente dibuja, y que
`no_snap` conserve el lattice fino (devuelva el punto del lattice, no el puntero crudo).

## Hallazgo 2 (Mayor) - crates/engine/src/view.rs:468
`sketch_grid_takes_crossing` mantiene `d <= fine || (l > fine/4.0 && d <= minor/4.0)`. Con
minor=5 y fine=0.5, un puntero en (21.2, 20) (a 1.2 mm de la cruza) cae en (20,20), moviendo el
punto mas de dos pasos finos. Eso contradice `Changes a default: no`.
FIX: ajustar la tolerancia para que el snap a la cruza solo aplique cuando la cruza este dentro
de lo que se muestra, y que el desplazamiento no exceda lo que el lattice fino permite.

## REGLA CRITICA (pre-merge check "Existing Defaults Unchanged" en rojo)
El PR declara `Changes a default: no`, asi que el comportamiento por defecto NO puede cambiar.
Si el fix que pide CodeRabbit obliga a cambiar el default, NO lo apliques: ponelo detras de una
preferencia explicita, mantené el default actual, y REPORTA la decision. Si el fix correcto
exige cambiar el default, paralo y decilo: es una decision del maintainer.

## Tests
- RED primero: en el archivo de tests EXISTENTE del area (PROHIBIDO un archivo nuevo por bug:
  AGENTS.md:24). El area es la vista/engine: busca el archivo de tests de view o el modulo
  `mod tests` de crates/engine/src/view.rs.
  - Test 1: un punto en la zona de blend 2->5 NO debe hacer snap a una cruza que `grid_lines`
    no dibuja.
  - Test 2: con minor=5 y fine=0.5, un puntero en (21.2, 20) NO debe moverse a (20,20).
  - Test 3: `no_snap` debe devolver el punto del lattice fino, no el puntero crudo.
- Correlos:
  cd /home/user/solidcraft-wt/issue-9843
  CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-loop/targets/slot-9843 CARGO_BUILD_JOBS=4 CARGO_INCREMENTAL=0 nice -n 19 cargo test -p solidcraft-engine grid --lib
  Si el build se pasa de 4 GiB de RAM, no es fallo tuyo. NO corras el gate entero.

## Commits (uno por hallazgo, con el RED primero si lo commiteaste)
  1. `test: a point snaps only to a crossing the grid draws`
  2. `fix: snap only to the crossings the grid actually draws`
  3. `fix: keep the fine lattice when the snap is refused`
Push: git push fork HEAD:<rama-del-pr>

## Entrega
SHA de cada commit, la salida de los tests en RED y en GREEN, y si tuviste que mantener el
default por el check. Si algo necesita una decision del maintainer, decilo explicitamente.
