# Brief: #2721 - un STEP de 500 MB se rechaza como "File too Large"

**Objetivo unico: que el import de un STEP grande NO se rechace por el limite equivocado.**

El issue #2721 esta ABIERTO y LIBRE (lo confirmo el barrido del pool: sin claim, sin PR que lo
reclame, no es de kernel).

## La causa raiz (esta localizada; no la re-descubras)

- `crates/io/src/design.rs:195-196`: `check_step_storable` calcula `limit = max_design() - STEP_RESERVE`
  = 256 MB - 4 MB = **252 MB**, y lo aplica al STEP IMPORTADO.
- Pero el limite de IMPORT de STEP es de 512 MB: `crates/io/src/lib.rs:111` (`MAX_STEP_BYTES`), y el
  chequeo de import en `crates/io/src/lib.rs:238` (`limits::check(Kind::Step, ...)`) lo acepta.
- O sea: un STEP de 500 MB pasa el chequeo de import y despues lo rechaza el chequeo de DESIGN.
  El limite de almacenamiento del design no tiene que aplicarle a un archivo que todavia no es
  un design.

La regla: el limite de un archivo que se importa es el limite de IMPORT de ese formato; el limite
de design aplica al design ya guardado.

## Pasos

1. Escribi primero el TEST RED (aun no existe) en `crates/io/src/` (el archivo de tests que le
   corresponda, segun la convencion del crate): un test que importe (o simule el import de) un
   STEP de 500 MB y verifique que NO se rechaza por `check_step_storable`. Correlo y PEGA el fallo
   exacto. Si el crate no tiene forma de armar un STEP de 500 MB en un test, testeá la FUNCION
   `check_step_storable` con los parametros que producen el rechazo, y que el test falle con el
   error real.
2. ```
   cd /home/user/solidcraft-wt/issue-2721
   git fetch origin && git checkout -b fix/issue-2721-step-limit origin/main
   export CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-2721
   export CARGO_INCREMENTAL=0
   export CARGO_BUILD_JOBS=4
   cargo test -p solidcraft-io --profile ci --lib <nombre_del_test> -- --nocapture
   ```
   OJO: el crate `solidcraft-io` compila `solidcore` desde git y tarda 10+ min la primera vez.
   Compilá UNA vez y reusá ese target dir; no compiles dos cosas a la vez.
3. Implementa el fix y el test pasa. Corre `cargo test -p solidcraft-io --profile ci` y reportá el
   numero de fallos antes y despues.
4. ```
   cargo fmt -p solidcraft-io --check
   cargo clippy -p solidcraft-io --all-targets --profile ci -- -D warnings
   ```
5. ```
   git add <los archivos que tocaste, uno por uno, NO git add -A>
   git commit -m "IO: the STEP import limit is the import limit, not the design limit (#2721)"
   git push fork fix/issue-2721-step-limit
   ```
   NUNCA push a `origin`. NO abras PR: el orquestador lo publica.
6. Gate: `bash /home/user/.local/share/solidcraft-orch/bin/gate.sh 2721 <SHA>` (fuera de systemd-run;
   si dice `no free build slot`, esperá 5 min y reintentá hasta 3 veces).

## Lo que hay que devolver

El mensaje EXACTO del fallo del test RED antes del fix, el comando y la salida despues, el numero
de fallos de `solidcraft-io` antes y despues, el `scope.verdict` del gate y el SHA.
No inventes resultados: si algo no compila o no se puede, decilo con el error exacto.
