> **Este brief esta retirado (2026-11-17): el PR #11388 ya fue MERGEADO** en upstream
> ("Sketch: groundwork for pierce constraints, no UI yet", #3599). El probe que este
> brief mandaba borrar ya no existe: `crates/engine/tests/pierce_probe.rs` no esta.
# Brief: sacar el archivo de debug del PR #11388 (el pierce)

**Tarea mecánica de 6 comandos. No explores el repo.** El archivo a borrar está abajo y el
comando de cada paso está escrito.

## Por qué

El `git add -A` del brief anterior se llevó `crates/engine/tests/pierce_probe.rs` al commit:
es un **"Scratch probe"** que imprime nombres e inspecciones con `println!` y no asserta nada
(puro debug). No debe ir al upstream. El resto del commit está bien y hay que conservarlo:
- `crates/engine/src/cmd/sketch.rs` → el `#[path = "sketch_pierce_tests.rs"] mod pierce_tests;`
  (registra los tests: **NO lo toques**)
- `crates/engine/src/cmd/sketch_pierce_tests.rs` → los 3 tests con `#[ignore = "..."]`
  (**NO los toques**)

## Worktree

`/home/user/solidcraft-wt/issue-3599`, rama `feature/issue-3599-pierce`.
Remote `fork` = `vdirienzo/solidcraft`. **Nunca push a `origin`.**
El checkout principal `/home/user/solidcraft` NO se toca.

## Los pasos

1. Borrar el probe y dejar el commit limpio (amend, para que el PR quede con UN commit):
   ```
   cd /home/user/solidcraft-wt/issue-3599
   git rm crates/engine/tests/pierce_probe.rs
   git commit --amend --no-edit
   git status --short          # tiene que quedar vacío
   ```
   El mensaje del commit se conserva: `Engine: the pierce tests wait for the command that is not written yet`.

2. Publicar el commit corregido (la rama es nuestra y el PR no está mergeado):
   ```
   git push --force-with-lease fork feature/issue-3599-pierce
   ```
   Si el `--force-with-lease` es rechazado, NO fuerces a mano: reportá el error exacto.

3. Gate local (fuera de systemd-run; si dice `no free build slot`, esperá 5 min y reintentá, hasta 3 veces):
   ```
   bash /home/user/.local/share/solidcraft-orch/bin/gate.sh 3599 <SHA_NUEVO>
   ```
   Gate esperado: `VERDICT=VERDE-SCOPE`, `NEW_FAILURES=0`, `CHECKS=fmt:ok|layers:ok|clippy:ok|check:ok`.
   Ojo: el `scope.effective.verdict` puede quedar con el SHA viejo; recalculalo con
   `bash /home/user/.local/share/solidcraft-orch/bin/gate-baseline.sh 3599`.

4. Actualizar el body del PR `#11388` (`gh pr edit 11388 --repo tangency-labs/solidcraft --body-file <file>`):
   - la sección de Validation con el **SHA nuevo** y el verdict real del gate;
   - **conservá** la línea `Changes a default: no` (el CI la exige; nunca `Changes to default:`);
   - **conservá** la primera línea que referencia el issue `#3599`;
   - **ninguna ruta local** (nada de `/home/user/...`, ni `logs/...`);
   - no hace falta tocar nada más del body.

5. `gh pr ready 11388 --repo tangency-labs/solidcraft` (puede que ya esté ready: no rompe nada).

6. Verificación final:
   ```
   bash /home/user/.local/share/solidcraft-orch/bin/verify-pr.sh 11388
   ```
   tiene que decir `VEREDICTO: todo en orden`.

## Lo que hay que devolver

- El SHA nuevo, la confirmación del push y el resultado de `git status --short` (vacío).
- El `scope.verdict` del gate (VERDICT, NEW_FAILURES, SHA).
- El resultado del `verify-pr.sh`.
- Si algo quedó sin hacer, decilo con el error exacto. No inventes resultados.

## Reglas

- No commitees en `/home/user/solidcraft`.
- No edites un script que se está ejecutando.
- No toques `~/.cargo/config.toml`.
