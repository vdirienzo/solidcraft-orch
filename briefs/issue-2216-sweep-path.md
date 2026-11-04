# Brief: #2216 - el sweep de superficie no deja elegir el path

**Objetivo unico: que el sweep se pueda lanzar con el path que el usuario eligio.**

El issue #2216 esta ABIERTO y LIBRE (confirmado con claim-race.sh: sin claim, sin PR que lo
reclame, no es de kernel). Es un bug de la UI, no una feature.

## La causa raiz (esta localizada; no la re-derives)
- `crates/ui-egui/src/dialogs.rs` y `crates/ui-egui/src/dialogs_surface.rs`: el sweep toma el
  input del path con `accept: 256` (o sea, solo curvas), pero `surface.sweep` exige un PATH.
- El usuario elige las curvas y al confirmar el sweep responde "select the path first", aunque
  ya habia seleccionado lo que hace de path.

Revisa esos dos archivos, mira de verdad que se pasa al comando (el dialogo arma el comando y sus
params) y arregla el dialogo para que lo que el usuario elige llegue como path. Si al leerlo
resulta que el criterio esta en otro lado (por ejemplo, en como el comando surface.sweep valida
el parametro), el fix va ahi: no fuerces el dialogo si el problema es del comando.

## Pasos
1. TEST RED PRIMERO (aun no existe): un test en el crate que falle con el error real. Correlo y
   PEGA el mensaje exacto. Sin RED no hay entrega.
2. ```
   cd /home/user/solidcraft-wt/issue-2216
   git fetch origin && git checkout -b fix/issue-2216-sweep-path origin/main
   export CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-2216
   export CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=4
   ```
   Corré el test bajo systemd-run con memoria (el cgroup de Hermes es de 4 GiB y mata el build):
   systemd-run --user --scope --quiet --unit=sc2216 -p MemoryMax=24G bash -lc 'cd /home/user/solidcraft-wt/issue-2216 && ... cargo test -p solidcraft-ui-egui --profile ci --lib <test> -- --nocapture'
3. Implementa el fix; el test pasa; corre los tests del area y reporta cuantos pasan/fallan.
4. cargo fmt --check y cargo clippy -p solidcraft-ui-egui --all-targets --profile ci -- -D warnings
5. ```
   git add <los archivos que tocaste, uno por uno, NO git add -A>
   git commit -m "UI: the surface sweep takes the path the user chose (#2216)"
   git push fork fix/issue-2216-sweep-path
   ```
   NUNCA a origin. NO abras PR: el orquestador lo publica.
   Y si lo que tocaste es un comando del engine y no la UI, el commit se llama distinto, pero el
   PR sigue siendo de #2216.
6. NO corras el gate: lo corre la cola del orquestador. NO compiles Rust de mas.

## Reglas
- El test de regresion va en el archivo de test del AREA, nunca en un archivo por bug (AGENTS.md:24).
- Reemplazo atomico (os.replace / mv). No toques /home/user/solidcraft (el checkout principal), no
  hagas rebase, no toques origin, no toques los scripts del orquestador, no uses pkill.
- La maquina es compartida: CARGO_BUILD_JOBS=4, target dir propio, un build a la vez.
- Si el bug NO es atacable desde este repo (si el error viene de solidcore/SMLib), decilo con la
  evidencia y no lo fuerces.

## Que hay que devolver
El mensaje EXACTO del fallo del RED, el comando y la salida despues, cuantos tests del area pasan
y cuantos fallan, el SHA y la rama. No inventes resultados.
