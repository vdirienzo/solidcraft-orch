# Brief LITERAL: el botón "Dependents" de INSPECT > HISTORY (timeline.dependents)

**NO EXPLORES EL REPO.** El código que hay que escribir está más abajo, literal, con el archivo y
la línea. Tu trabajo es APLICAR, TESTEAR, COMMITEAR y PUSHEAR. Si algo no compila, el error te dice
qué cambiar. Perder 3 horas leyendo código es el modo de fallo conocido de este brief: no lo repitas.

Repo: `/home/user/solidcraft` (checkout principal: NO lo toques, nunca commitees ahí).
Worktree: `/home/user/solidcraft-wt/issue-dependents` — YA EXISTE, con la rama
`fix/issue-timeline-dependents-button` ya creada desde `origin/main`.
Remote: `fork` = `vdirienzo/solidcraft` (verificalo con `git remote -v` antes de pushear).
**Nunca push a `origin`.**

## 1. El bug (ya diagnosticado, no lo re-descubras)

La UI invoca `timeline.dependents` sin el parámetro `feature` y el engine responde:
`Feature Dependents: `feature` must be an id or name`.
Causa: `crates/engine/src/cmd/edit.rs:1937-1950` → `feature_id(s, p.get("feature"), cmd)?`.
El comando es de a UNA feature por vez.

## 2. El cambio (APLICÁ ESTE CÓDIGO)

En `crates/ui-egui/src/lib.rs`, dentro de `fn start_with_variant_memory(&mut self, id: &str, ...)`
(empieza en la línea 1552), agregá este bloque **justo después** del bloque `if id == "timeline.delete" { ... }`
(que termina alrededor de la línea 1593):

```rust
        // The Dependents button of INSPECT ▸ HISTORY asks for the dependents of ONE
        // feature, so it needs a target. With nothing selected it used to run the
        // command with no feature and the engine answered "Feature Dependents:
        // `feature` must be an id or name". It reports the dependents of what is
        // selected, one command call per selected feature.
        if id == "timeline.dependents" {
            let selected = timeline::selected_feature_ids(self);
            if selected.is_empty() {
                self.set_status(self.tr("ui.dependents_select_first"), false);
                return;
            }
            for feature_id in selected {
                if let Err(why) = self.run("timeline.dependents", json!({ "feature": feature_id })) {
                    self.set_status(why, true);
                }
            }
            return;
        }
```

Las APIs que usás ya existen y son `pub(crate)`:
- `timeline::selected_feature_ids(app: &SolveApp) -> Vec<u64>` — `crates/ui-egui/src/timeline.rs:328`.
- `self.set_status(self.tr("..."), false)` — el patrón exacto de `timeline.delete` (lib.rs:1585-1592).
- `self.run(id, json!({...}))` — el patrón exacto de `timeline.play` (lib.rs:1554-1558).

Si `timeline::selected_feature_ids` no compila desde ese módulo, usá `crate::timeline::selected_feature_ids(self)`.

## 3. El texto nuevo (un archivo, no el catálogo)

Creá `assets/locales/pending/timeline-dependents-button.json` con EXACTAMENTE este contenido:

```json
{
  "en": { "ui.dependents_select_first": "Select what to list the dependents of first" }
}
```

Las otras locales no hacen falta: una locale que dejes afuera cae al inglés (ver el README de
`assets/locales/pending/`). **No edites `assets/locales/en.json` ni ningún otro catálogo.**
El id `ui.dependents_select_first` es nuevo: no existe en ningún catálogo (ya está comprobado).

## 4. El test (el probe ya está escrito)

`crates/ui-egui/src/probe_dependents.rs` está en el worktree (untracked). Convértelo en test real:
- renombralo a `crates/ui-egui/src/timeline_dependents_tests.rs`
- sacale el prefijo `probe_` del nombre de la función y de los comentarios
- registralo como `mod timeline_dependents_tests;` bajo `#[cfg(test)]` en `crates/ui-egui/src/lib.rs`
  (junto a los otros `mod ..._tests;` que ya están ahí: buscá `mod sketch_snap_start_ui_tests;`
  y poné el tuyo al lado)

Si el probe no compila después del renombre, ajustá SOLO lo que el compilador diga.

## 5. Verificar (target dir propio, el de otro slot no se toca)

```
export CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-dependents
export CARGO_INCREMENTAL=0
cd /home/user/solidcraft-wt/issue-dependents
cargo test -p solidcraft-ui-egui timeline_dependents_tests     # en verde
cargo clippy -p solidcraft-ui-egui --all-targets --profile ci -- -D warnings   # limpio
cargo fmt -p solidcraft-ui-egui --check                          # limpio
```

Los 26 fallos de egui (`Dropped TexturesDelta`, orden de frames) del `cargo test -p solidcraft-ui-egui`
completo son preexistentes de `origin/main` (verificado): no los persigas. Si ves alguno NUEVO que
no sea de egui, avisá en el informe final.

## 6. Commit y push

```
git add -A
git commit -m "UI: the Dependents button of the INSPECT HISTORY ribbon no longer fails without a feature"
git push fork fix/issue-timeline-dependents-button
```

**No abras PR ni issue.**

## 7. Gate local

```
bash /home/user/.local/share/solidcraft-orch/bin/gate.sh dependents <SHA>
```

Fuera de systemd-run. Si dice `no free build slot`, esperá 5 minutos y reintentá (hasta 3 veces).
El gate mete `solidcraft-cli` en el scope para que la feature `smlib` se unifique: sin eso el kernel
se compila sin SMLib y TODOS los tests geométricos fallan con `this build has no SMLib` (falsos).

## 8. Lo que hay que devolver

- El SHA del commit y la confirmación de que está en el fork.
- La salida resumida de los 3 comandos del paso 5 (últimas líneas, no el log entero).
- El verdict del gate (el `scope.verdict`: `VERDICT=`, `NEW_FAILURES=`, `SHA=`).
- Si algo quedó sin hacer, decilo con el error exacto. **No inventes resultados.**

## Reglas que importan

- No edites un script que se está ejecutando.
- No toques `~/.cargo/config.toml`.
- No commitees en `/home/user/solidcraft` (el checkout principal).
