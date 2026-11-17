# 17052 — diagnóstico medido (subagente wave-20261115-0910, sin commit)

Issue: https://github.com/tangency-labs/solidcraft/issues/17052
('[bug] Can't keep infinity value during X-Line Construction line positioning in sketch mode')

Estado: SIN PR. El subagente se agotó de iteraciones con la causa raíz localizada y
medida, pero sin escribir el test RED definitivo ni el fix. El probe temporal que
agregó a `crates/ui-egui/src/sketch_construction_tests.rs` fue RESTAURADO desde
`/home/user/.hermes/cache/scratch/17052/sketch_construction_tests.rs.bak`; el diff
del probe quedó en `logs/17052-probe.diff` (92 líneas).

## Las dos causas raíz, con archivo y línea

### 1. El `∞` se pisa en cada frame

`crates/ui-egui/src/sketch_dims.rs:703-708`: el bloque `Length` de una construction
line se sobrescribe en cada frame con la constante `INFINITE = "\u{221e}"`
(definida en `sketch_dims.rs:22`) mientras `!b.locked`.

Ese `"∞"` es el VALOR REAL del `String` del `TextEdit`, no un placeholder ni un
hint: al tipear, egui inserta el dígito junto al `∞` en vez de reemplazarlo. Y el
`TextEditState` que selecciona todo el texto (líneas 764-769) corre solo cuando
`!b.locked`, o sea que nunca llega a seleccionar el `∞` que hay que borrar.

Arreglo probable: que `∞` sea un placeholder/hint del `TextEdit` (o que el texto se
seleccione siempre antes de escribir), no el contenido del `String`.

### 2. La línea se ancla en el extremo, no en el medio

`crates/engine/src/cmd/sketch_construction.rs:66-70`: `construction_segment` devuelve
`(line.start, line.start + direction * length)`. El segmento arranca en `line.start`
—el punto del puntero— y se extiende en una sola dirección: el puntero queda en el
EXTREMO de la línea, no en el medio.

La preview (`crates/engine/src/cmd/sketch_construction.rs:252-256`) usa exactamente
esa misma función, así que preview y geometría creada son consistentes entre sí
(el defecto es real, no un desincronismo entre preview y resultado).

## Contexto ya verificado

- La segunda caja (`Offset`) existe para `horizontal`/`vertical`/`parallel`
  (`sketch_dims::sync`, confirmado por el test existente
  `construction_offset_box_follows_the_modes_that_have_a_distance`).
- La captura del issue, leída visualmente: el puntero (≈x=305 en la imagen
  reducida) queda en el extremo izquierdo del tramo naranja; la caja de arriba
  muestra `100` y la de abajo `25.50` (esta última con foco).
- Build del crate verificado: `cargo test -p solidcraft-ui-egui --lib sketch --no-run`
  → `BUILD_EXIT=0` en 23 min con `CARGO_TARGET_DIR=targets/slot-17052`,
  `CARGO_BUILD_JOBS=4`, `CARGO_INCREMENTAL=0`, dentro de `systemd-run --user --scope
  --property=MemoryMax=40G`.

## El paso siguiente, literal

Con la causa raíz medida, el brief del fix es de una hora:

1. Test RED en el archivo de test EXISTENTE del área
   (`crates/ui-egui/src/sketch_construction_tests.rs`): afirmar que el `∞` no se
   pierde al tipear un número (el `String` del size no queda con `∞` pegado) y que
   un size tipeado ancla la línea alrededor del puntero.
2. Commit RED.
3. Fix en `crates/ui-egui/src/sketch_dims.rs` (el `∞` como placeholder/hint, y la
   selección del texto al enfocar) y en el anclaje del segmento, en
   `crates/engine/src/cmd/sketch_construction.rs`.
4. GREEN + commit.

El test va en `sketch_construction_tests.rs` (archivo existente del área), nunca en
un archivo nuevo por bug (AGENTS.md).

## Por qué no hay PR

Dos intentos del corredor con `minimax/MiniMax-M3.1-Flash` murieron sin escribir
nada (el primero en 2m23s, el segundo con `Transport: ECONNRESET`), y el subagente
de Hermes se agotó de iteraciones con el probe compilando. La regla del repo es
inequívoca: si el agente no puede reproducir el issue fielmente, no hay PR. No se
publicó un arreglo sin test RED medido.
