# Brief: dejar publicable el PR #11388 (el pierce) marcando los 3 tests RED del engine

**Tarea mecánica. No explores el repo: los 3 tests y el archivo están abajo.** Solo: editar 3
líneas, testear, commitear, pushear, gate, actualizar el body del PR.

## Contexto

- Worktree: `/home/user/solidcraft-wt/issue-3599` — YA EXISTE, rama `feature/issue-3599-pierce`.
- El PR es el `#11388` (draft) en `tangency-labs/solidcraft`, head `c1a3fb6d9`.
- El gate del slot 3599 dio `ROJO-SCOPE` con **3 fallos**, y son exactamente los 3 tests del propio
  cambio: la geometría, la constraint y el solver están hechos y verdes (350 tests del crate
  sketch), pero **el comando del engine todavía no está implementado**. El body del PR ya lo dice.
- Un draft con tests en rojo no es publicable, y el CI lo mata. La salida es la que ya usó el
  PR #11486 del mismo repo: los tests que todavía no tienen implementación se marcan `#[ignore]`
  **con el motivo**, para que el PR sea honesto y el trabajo pendiente quede trazable.

## Qué hacer

1. Editá `crates/engine/src/cmd/sketch_pierce_tests.rs` (o el archivo donde estén esos 3 tests;
   confirmá con `grep -rn "a_pierce_constraint_holds_a_point" crates/engine/src/`) y agregá el
   atributo `#[ignore = "..."]` a estos 3 tests, cada uno con un motivo en inglés:

   - `a_pierce_constraint_holds_a_point_where_another_sketches_curve_crosses_this_plane`
   - `a_pierce_constraint_needs_a_curve_of_another_sketch`
   - `a_pierced_point_follows_the_curve_of_the_other_sketch`

   El motivo debe decir que el comando del engine todavía no está implementado
   (algo como `#[ignore = "the engine command is not implemented yet"]`).
   Usá el MISMO formato de `#[ignore = "..."]` que ya usa el repo (fijate en
   `crates/engine/src/cmd/measure_surface_tests.rs`, que tiene tests ignorados con motivo).

2. Verificá (target dir propio, el del slot 3599):
   ```
   cd /home/user/solidcraft-wt/issue-3599
   export CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-3599
   export CARGO_INCREMENTAL=0
   cargo test -p solidcraft-engine pierce    # verde (los ignorados no corren)
   cargo fmt -p solidcraft-engine --check    # limpio
   ```

3. Commit y push:
   ```
   git add -A
   git commit -m "Engine: the pierce tests wait for the command that is not written yet"
   git push fork feature/issue-3599-pierce
   ```
   (`fork` = `vdirienzo/solidcraft`; verificá con `git remote -v`. **Nunca push a `origin`.**)

4. Gate local:
   ```
   bash /home/user/.local/share/solidcraft-orch/bin/gate.sh 3599 <SHA_NUEVO>
   ```
   Fuera de systemd-run. Si dice `no free build slot`, esperá 5 min y reintentá (hasta 3 veces).
   Gate esperado: `VERDE-SCOPE` con `NEW_FAILURES=0`.

5. **Actualizá el body del PR #11388** (`gh pr edit 11388 --repo tangency-labs/solidcraft --body-file <file>`):
   - la sección de Validation, con el SHA nuevo y el verdict real del gate;
   - una línea que diga que los 3 tests del comando del engine están ignorados con el motivo
     porque el comando todavía no está implementado;
   - **dejá la línea `Changes a default: no`** (el CI la exige; NO escribas `Changes to default:`);
   - **no cites rutas locales** (nada de `/home/user/...`, ni `logs/...`);
   - la primera línea sigue siendo la que closes/referencia el issue: conservala.

   Después: `gh pr ready 11388 --repo tangency-labs/solidcraft` (el PR deja de ser draft: ya tiene
   código, gate, body y evidencia, y no hay nada más que aportar ahora).

6. Verificación final:
   ```
   bash /home/user/.local/share/solidcraft-orch/bin/verify-pr.sh 11388
   ```
   tiene que decir `VEREDICTO: todo en orden`.

## Lo que hay que devolver

- El SHA nuevo y la confirmación de que está en el fork.
- La salida resumida del `cargo test` y del gate (el `scope.verdict`).
- El resultado del `verify-pr.sh`.
- Si algo quedó sin hacer, decilo con el error exacto. No inventes resultados.

## Reglas

- No commitees en `/home/user/solidcraft` (el checkout principal).
- No edites un script que se está ejecutando.
- No toques `~/.cargo/config.toml`.
