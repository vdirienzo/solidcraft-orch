> **Este brief esta retirado (2026-11-17): el trabajo ya esta en upstream.** El
> texto `ui.dependents_select_first` esta en los catalogos y el modulo de los
> tests es `crates/ui-egui/src/timeline_dependents_tests.rs`.
# Brief: cerrar el fix del botón "Dependents" (commit, push, gate)

**Tarea mecánica: 5 comandos.** El código YA está escrito, testeado y verificado. No lo toques.
No explores el repo, no re-derives el bug, no re-corras la suite completa de ui-egui (tarda horas
y ya se corrió).

## Worktree

`/home/user/solidcraft-wt/issue-dependents`, rama `fix/issue-timeline-dependents-button`.
Remote `fork` = `vdirienzo/solidcraft` (**nunca push a `origin`**).
El checkout principal `/home/user/solidcraft` NO se toca.

## Estado ya verificado (no lo repitas)

- `crates/ui-egui/src/lib.rs` — el bloque de intercepción de `timeline.dependents` (línea ~1600) y el
  `mod timeline_dependents_tests;` (línea 134). **Ya compila.**
- `crates/ui-egui/src/timeline_dependents_tests.rs` — el probe convertido en test real. **2 tests en verde.**
- `assets/locales/pending/timeline-dependents-button.json` — el texto `ui.dependents_select_first` en 8 locales.
- Verificado antes: `cargo test -p solidcraft-ui-egui --lib timeline_dependents_tests` → 2 passed;
  `cargo fmt -p solidcraft-ui-egui --check` → limpio; `cargo clippy ... -D warnings` → limpio.
- **Sin commit y sin push todavía.** Eso es todo lo que falta.

## Los pasos

1. **Add con la lista explícita de archivos** (NO `git add -A`: en este worktree hay scratch, y una
   vez `git add -A` se llevó un archivo de debug al PR):
   ```
   cd /home/user/solidcraft-wt/issue-dependents
   git add crates/ui-egui/src/lib.rs \
           crates/ui-egui/src/timeline_dependents_tests.rs \
           assets/locales/pending/timeline-dependents-button.json
   git status --short
   ```
   Tiene que quedar SOLO esos 3 archivos. Si aparece algo más, NO lo agregues: reportalo.

2. Commit y push:
   ```
   git commit -m "UI: the Dependents button of the INSPECT HISTORY ribbon no longer fails without a feature"
   git push fork fix/issue-timeline-dependents-button
   ```
   (`fork` = `vdirienzo/solidcraft`: verificá con `git remote -v` antes.)

3. Gate local (fuera de systemd-run; si dice `no free build slot`, esperá 5 min y reintentá, hasta 3 veces):
   ```
   bash /home/user/.local/share/solidcraft-orch/bin/gate.sh dependents <SHA>
   ```
   Gate esperado: `VERDICT=VERDE-SCOPE`, `NEW_FAILURES=0`.
   Si el `scope.effective.verdict` queda con el SHA viejo, recalculalo:
   ```
   bash /home/user/.local/share/solidcraft-orch/bin/gate-baseline.sh dependents
   ```

4. **No abras PR ni issue.** Este trabajo se publica después, cuando el orquestador lo pida.

5. Verificación final:
   ```
   git status --short          # vacío
   git log --oneline -1
   ```
   Y el `scope.verdict` del gate.

## Notas operativas (importan)

- La caja es COMPARTIDA y se OOMea compilando los 21 binarios de `tests/` a la vez. Si el build
  muere con exit 143, es el link, no tu código: usá `CARGO_BUILD_JOBS=2` y `cargo test --lib`.
- Si tomás un build slot a mano, liberalo con
  `bash /home/user/.local/share/solidcraft-orch/bin/build-slot.sh --release <token>`
  (acepta el nombre "slot-1" o el path completo).
- No edites un script que se está ejecutando. No toques `~/.cargo/config.toml`.

## Lo que hay que devolver

- El SHA del commit, la confirmación del push y el `git status --short` final (vacío).
- El `scope.verdict` (VERDICT, NEW_FAILURES, SHA).
- Si algo quedó sin hacer, decilo con el error exacto. No inventes resultados.
