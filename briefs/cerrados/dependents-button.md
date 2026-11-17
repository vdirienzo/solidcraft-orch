> **Este brief esta retirado (2026-11-17): el trabajo ya esta en upstream.** El
> boton de dependientes esta implementado (`timeline.dependents` en
> `crates/ui-egui/src/timeline.rs`), el texto `ui.dependents_select_first` esta
> en los catalogos, y el test real es `crates/ui-egui/src/timeline_dependents_tests.rs`.
> El probe que este brief decia convertir ya no existe.
# Brief: el botón "Dependents" de INSPECT > HISTORY (timeline.dependents)

Contexto: repo en `/home/user/solidcraft`, worktrees en `/home/user/solidcraft-wt/issue-<n>`,
fork = `vdirienzo/solidcraft` (el remote se llama `fork`), upstream = `origin` = `tangency-labs/solidcraft`.
**Nunca pushes a `origin`. Nunca commitees en el checkout principal** (`/home/user/solidcraft`): usá tu worktree.

## El bug (el RED ya está confirmado, no lo re-descubras)

La UI invoca `timeline.dependents` sin el parámetro `feature` y el engine lo rechaza:

```
status after: "Feature Dependents: `feature` must be an id or name"
```

Causa raíz (trazada):
- `crates/ui-egui/src/workspace.rs:210` — `Section { tab: "INSPECT", panel: "HISTORY", promoted: 3, ids: &["timeline.play", "timeline.dependents", "document.inspect"] }` promueve el botón.
- `crates/engine/src/cmd/edit.rs:95-97` — el command spec declara `.params("feature: id|name → ...")`, sin default.
- `crates/engine/src/cmd/edit.rs:1937-1950` — `fn dependents` llama `feature_id(s, p.get("feature"), cmd)?` → error.

El comando es estrictamente de a una feature por vez: no tiene modo "listar todas".

## El patrón a seguir (mismo repo, ya existe)

`timeline.delete` en `crates/ui-egui/src/lib.rs:1585-1592` es exactamente el patrón de un comando de
sección que necesita un destino: redirige a la selección y, si no hay nada seleccionado, pone un
mensaje de estado en vez de fallar. `crates/ui-egui/src/timeline.rs:282-320` muestra `timeline.dependents`
conducido correctamente por feature desde `delete_features`, y `crates/ui-egui/src/timeline.rs:328`
tiene `timeline::selected_feature_ids`.

Plan: interceptar `timeline.dependents` en `start_with_variant_memory` (`crates/ui-egui/src/lib.rs`),
resolver el destino desde la selección del timeline, correr el comando por feature seleccionada con
`{"feature": id}` y mostrar el reporte. Si no hay selección, un mensaje de estado (no un error).

## Los pasos (en este orden, sin desvíos)

1. `git fetch origin && git checkout -b fix/issue-timeline-dependents-button origin/main`
   en `/home/user/solidcraft-wt/issue-dependents` (creá el worktree si no existe:
   `git -C /home/user/solidcraft worktree add /home/user/solidcraft-wt/issue-dependents -b fix/issue-timeline-dependents-button origin/main`).
2. Implementá la intercepción mínima de arriba.
3. Convertí el probe en un test real del crate:
   `crates/ui-egui/src/probe_dependents.rs` → `crates/ui-egui/src/timeline_dependents_tests.rs`,
   sacá `probe_` del nombre de la función y de los comentarios, y registralo como
   `mod timeline_dependents_tests;` bajo `#[cfg(test)]` en `crates/ui-egui/src/lib.rs`.
4. **Un texto nuevo visible para el usuario** (el mensaje de "nada seleccionado") tiene que ir en un
   archivo NUEVO de `assets/locales/pending/`, **no** editando `assets/locales/en.json`. El test de
   completitud exige las locales completas: `en`, `ar`, `he`, `ja`, `vi`, `zh`.
5. Corré, cada uno con su propio target dir (NO compartas el target dir de otro slot):
   - `cargo test -p solidcraft-ui-egui timeline_dependents_tests` (en verde)
   - `cargo test -p solidcraft-ui-egui` (en verde; los 26 fallos de egui `Dropped TexturesDelta` y de orden de frames son preexistentes en `origin/main`: verificalo si aparecen y no los persigas)
   - `cargo clippy -p solidcraft-ui-egui --all-targets --profile ci -- -D warnings` (limpio)
   - `cargo fmt -p solidcraft-ui-egui --check` (limpio)
   Target dir: `CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-dependents`.
6. Commit con el mensaje EXACTO:
   `UI: the Dependents button of the INSPECT HISTORY ribbon no longer fails without a feature`
7. `git push fork fix/issue-timeline-dependents-button` (verificá con `git remote -v` que `fork` es
   `vdirienzo/solidcraft` ANTES de pushear). **No abras PR ni issue.**
8. Gate local: `bash /home/user/.local/share/solidcraft-orch/bin/gate.sh dependents <SHA>`
   (fuera de systemd-run; si dice "no free build slot", esperá 5 min y reintentá, hasta 3 veces).
   El gate ahora mete `solidcraft-cli` en el scope para que la feature `smlib` se unifique: sin eso
   el kernel se compila sin SMLib y TODOS los tests geométricos fallan con "this build has no SMLib".

## Reglas que importan

- **No edites un script que se está ejecutando** (bash lee por offset de bytes).
- Si el build falla por falta de SMLib, el mensaje es `this build has no SMLib`: eso es un bug del
  scope, no tuyo; reportalo y seguí.
- No toques `~/.cargo/config.toml`.
- Los tests que fallan en `origin/main` sin que los toques NO son tuyos: verificalo y seguí.
- **No persigas el verde a costa de perder el fix**: si algo no entra, reportalo con el error exacto.

## Lo que hay que devolver

- El SHA del commit y la confirmación de que está en el fork.
- La salida de los 4 comandos del paso 5 (resumen, no el log entero).
- El verdict del gate (el `scope.verdict`).
- Si algo quedó sin hacer, decilo con el error exacto. No inventes resultados.
