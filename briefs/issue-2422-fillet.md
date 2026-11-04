# Brief: el issue #2422 (FILLET: operation failed) en el kernel

**Un solo objetivo: que el test `issue2422_vertical_after_separate_bottom_rounds` pase.** El issue
#2422 esta ABIERTO y LIBRE (el claim anterior se vencio el 31-10-2026). El test ya existe en el
repo: `crates/kernel/src/blend_corner.rs:425`.

## Lo que ya esta sabes (no lo re-descubras)

- El issue: "FILLET: operation failed", con el error `not supported yet: the ball doesn't fit along
  the edge` (reportado en 0.15.0) y el motivo que el propio repo cataloga en
  `tests/KNOWN_FAILING_TESTS`: *"SMLib's check refuses the fillet: edge and vertex tolerance 0.97
  against the body's 0.01"*.
- La cadena de llamadas, toda en este repo:
  `crates/kernel/src/blend_corner.rs` -> `pub fn fillet(body, edges, radius)`
  -> `crates/smlib/src/ffi.rs:255` -> `pub fn fillet_radii(body, edges)` -> `crate::blend_smlib::fillet_each(body, &points, &radii)`.
- El test hace: una caja 40 x 80 x 27, las cuatro aristas de abajo con R2 una por una (con
  tangencia propagada), y despues una arista vertical R2; despues compara el volumen con el valor
  analitico, con una tolerancia de 1e-6. Tambien hace la variante con la cavidad (shelled).
- La geometria es CORRECTA: el calculo analitico esta en el comentario del test. Lo que falla es
  que SMLib RECHAZA la operacion.

## El paso 1 (obligatorio): ver el error real

```
cd /home/user/solidcraft-wt/issue-2422
export CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-2422
export CARGO_INCREMENTAL=0
export CARGO_BUILD_JOBS=4
cargo test -p solidcraft-kernel issue2422_vertical_after_separate_bottom_rounds -- --nocapture
```
Copiá el mensaje EXACTO del fallo y pegalo en tu informe. Ese mensaje dice que tolerance se
pasa y contra que se compara: es el dato que decide el fix.

## El paso 2: el fix

El objetivo es que SMLib acepte la operacion. La tolerancia que se le pasa al check de SMLib
tiene que ser coherente con la del cuerpo (el motivo dice 0.97 contra 0.01). Busca donde
`blend_smlib::fillet_each` arma esa tolerancia y ajustala.

**Reglas del fix**:
- El cambio tiene que estar en el wrapper o en el kernel de ESTE repo, no en solidcore.
- No cambies la tolerancia del cuerpo para que el check pase: eso seria maquillar el sintoma.
  Lo que se ajusta es la tolerancia que se le PIDE a SMLib, si la peticion es incoherente con la
  geometria. Si el error demuestra que el fix va en otro lado, REPORTA eso y no lo fuerces.
- El test tiene que quedar en verde SIN bajar su tolerancia (1e-6) ni tocar sus asserts.
- Los otros tests del kernel no pueden romperse: corré `cargo test -p solidcraft-kernel` y
  reportá el numero de fallos antes y despues (hay fallos preexistentes de SMLib: son los del
  catalogo `tests/KNOWN_FAILING_TESTS`, no los persigas).

## Los pasos 3 a 5

3. ```
   cargo fmt -p solidcraft-kernel --check
   cargo clippy -p solidcraft-kernel --all-targets --profile ci -- -D warnings
   ```
4. ```
   git add <los archivos que tocaste, uno por uno, NO git add -A>
   git commit -m "Kernel: the fillet of #2422 asks SMLib a tolerance that matches the body"
   git push fork fix/issue-2422-fillet-tolerance
   ```
   (`fork` = `vdirienzo/solidcraft`; **nunca push a `origin`**; el checkout principal
   `/home/user/solidcraft` NO se toca: usá `/home/user/solidcraft-wt/issue-2422`, que tenés que
   crear con `git -C /home/user/solidcraft worktree add /home/user/solidcraft-wt/issue-2422 -b fix/issue-2422-fillet-tolerance origin/main`.)

5. Gate local:
   ```
   bash /home/user/.local/share/solidcraft-orch/bin/gate.sh 2422 <SHA>
   ```
   Fuera de systemd-run. Si dice `no free build slot`, esperá 5 min y reintentá (hasta 3 veces).

**No abras PR**: el orquestador lo publica. El issue #2422 ya esta reclamado.

## Lo que hay que devolver

- El mensaje EXACTO del fallo que viste (copiado, no parafraseado).
- Que cambiaste y por que (con el archivo y la linea).
- El resultado de `cargo test -p solidcraft-kernel` antes y despues (el numero).
- El `scope.verdict` del gate.
- Si el fix no es atacable desde este repo, decilo con la evidencia y NO fuerces nada.

## Reglas

- No edites un script que se esta ejecutando. No toques `~/.cargo/config.toml`.
- La caja es COMPARTIDA: `CARGO_BUILD_JOBS=4` y target dir propio.
