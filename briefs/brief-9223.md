# Brief: fix #9223 — "EXTRUDE: operation failed" (the feature editor throws the edit away)

## The job in one paragraph

Editing a feature in SolidCraft opens that feature's editor. The editor pins the design it
opened on, and when the user presses OK the engine checks that the design has not moved on
underneath it; if it has, the editor refuses the edit with **"the design changed while the
feature editor was open"**. Adding a *parameter* while the editor is open — a normal part of
editing (you give the feature's length a parameter name, so the parameter is added next to the
open editor) — is such a move, and today it makes the editor throw the edit away: the OK is
refused, the edit is lost, and the user has to do it all again. Make the editor keep the edit
in that case, while it still refuses an edit when the design really changed underneath it.

## The facts

| what | value |
|---|---|
| issue | **#9223** — "EXTRUDE: operation failed" |
| labels | `bug`, `area:kernel`, `needs-triage` |
| PR | **#23431** (draft, against upstream `main`) |
| branch | `fix-9223` (fork `vdirienzo/solidcraft`) |
| worktree | `/home/user/solidcraft-wt/issue-9223` |
| target dir | `/home/user/.local/share/solidcraft-orch/targets/slot-9223` |
| upstream commit the branch is based on | `e05258b9e5` (origin/main) |
| claim | `bash bin/claim-verify.sh 9223 --our-pr 23431` → `VEREDICTO=OK el claim es nuestro (PR #23431)` |

Two reporters, two paths to the same refusal:

* **jheck7** (issue #9223, 0.27.0, Windows): he extruded 3 of 10 circles, pressed OK, went back
  into the extrude, clicked the rectangular pattern in the view (it highlighted the instances
  but did not select them), selected the circles one by one and pressed OK → *"the design changed
  while the feature editor was open"*. What in that flow changes the document is **not known**
  (the triage note on the issue could not reproduce it either, not even in the app).
* **bherbruck** (comment on the issue, 0.43.0, ticket T-225): *"while editing an extrude, the
  user added a new parameter (`Y_axis_Rod_Size_Rith`) to drive its distance, and the editor then
  refused with 'the design changed while the feature editor was open; its current timeline was
  preserved'. Adding a parameter for the open feature to use is part of editing it; it shouldn't
  count as an outside change that throws the edit away."*

**The second path is the one reproduced and fixed below.** It is the same defect: the editor's
guard cannot tell "the design changed in a way that makes this edit stale" from "the design
gained a parameter that the edit itself uses".

## REPRODUCE FIRST (exact commands, exact output today)

The defect lives in the engine, so it is reproduced in the engine's own test module. This test
was run on current `main` (`origin/main` = `e05258b9e5`, engine v0.51.1) and it **passes**,
which is the proof that the editor refuses the edit today.

Append this to the **existing** test module `crates/engine/src/computed_commands_tests.rs`
(a copy is kept at `/tmp/opencode/triage-9223/repro_test.rs`):

```rust
/// TRIAGE REPRODUCTION for #9223 ("EXTRUDE: operation failed" — "the design changed while the
/// feature editor was open").
#[test]
fn triage_a_parameter_added_while_the_editor_is_open_refuses_the_edit() {
    let (mut session, source, original, commands) = extrusion_editor();
    // The user adds a parameter to drive the open feature's distance.
    session.execute("parameters.add", &json!({"name": "len", "expression": "20 mm"})).unwrap();
    let error = session
        .scratch()
        .compute_editor_commands(&commands, &source, original)
        .err()
        .map(|e| e.to_string())
        .unwrap_or_default();
    println!("the editor refused the edit with: {error}");
    assert_eq!(error, "the design changed while the feature editor was open");
}
```

Run it:

```bash
cd /home/user/solidcraft-wt/issue-9223
CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-9223 \
  nice -n 19 cargo test --profile ci -p solidcraft-engine --lib \
  triage_a_parameter_added_while_the_editor_is_open_refuses_the_edit -- --nocapture
```

What it prints **today** (measured on `origin/main`, saved in
`/tmp/opencode/triage-9223/repro-test-output.txt`):

```
running 1 test
the editor refused the edit with: the design changed while the feature editor was open
test computed_commands_tests::triage_a_parameter_added_while_the_editor_is_open_refuses_the_edit ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 8650 filtered out; finished in 0.04s
```

(The test *passes* because it asserts the refusal: that is the defect. Your RED test asserts the
opposite — that the edit is accepted — so it must fail before the fix and pass after it.)

`extrusion_editor()` is the helper already in that module (line 194): it builds a box, a sketch
and an extrude, then does exactly what the window does when it opens a feature's editor — it
takes the editor's pinned `source`, rolls the timeline back to the feature, and pins the rolled
back `original`.

### The control: outside the editor the very same commands work

The CLI proves the *commands* are fine and only the editor's guard refuses them
(`/tmp/opencode/triage-9223/control.json`):

```json
[
  {"command": "sketch.create", "params": {"plane": "XY", "name": "Profile"}},
  {"command": "sketch.circle.two_point", "params": {"p0": [0, 0], "p1": [5, 0]}},
  {"command": "sketch.finish", "params": {}},
  {"command": "solid.extrude", "params": {"distance": "10 mm", "operation": "new", "name": "Boss"}},
  {"command": "parameters.add", "params": {"name": "len", "expression": "20 mm"}},
  {"command": "timeline.redefine", "params": {"feature": "Boss", "command": "solid.extrude",
                                              "params": {"distance": "len", "operation": "new"}}}
]
```

```bash
/home/user/.local/share/solidcraft-orch/targets/triage/ci/solidcraft-cli run \
  /tmp/opencode/triage-9223/control.json --results
```

Measured today: **all six steps succeed** — `solid.extrude` makes `Body1`, `parameters.add`
adds `len` = 20 mm, and `timeline.redefine` rebuilds the extrude with `distance: "len"`
(`{"feature": 2, "recomputed": 1, "restored": 0, "rolled_back": false}`). The same design, the
same commands, the same parameter: no refusal. The refusal is the editor's own guard.

## Where the cause is, and what I think is wrong

All line numbers are on `origin/main` = `e05258b9e5`.

1. **The refusal** — `crates/engine/src/lib.rs:4042` (in `Session::compute_editor_commands`):

   ```rust
   pub fn compute_editor_commands(self, commands: &[(String, Value)], source: &Session, original: Session) -> Result<ComputedCommands> {
       if !self.same_document_context(source) {
           return Err(EngineError::Other("the design changed while the feature editor was open".into()));
       }
   ```

   The same guard, with the longer wording, is at `crates/engine/src/lib.rs:4266` in
   `Session::restore_editor` (the Cancel path: *"the design changed while the feature editor
   was open; its current timeline was preserved"*).

2. **The guard** — `crates/engine/src/lib.rs:4240` (`fn same_document_context`):

   ```rust
   fn same_document_context(&self, source: &Session) -> bool {
       Arc::ptr_eq(&self.doc, &source.doc)
           && self.document_id == source.document_id
           && self.design_revision == source.design_revision
           && self.ids.seed() == source.ids.seed()
           && self.revision.checked_sub(source.revision)
               .is_some_and(|delta| self.visibility_revision.checked_sub(source.visibility_revision) == Some(delta))
           && self.active_sketch == source.active_sketch
           && ... active_component, active_occurrence_path, pending_moves ...
   }
   ```

   It compares the **whole design by identity**: the same document (`Arc::ptr_eq`), the same
   design token (`design_revision`, regenerated whenever the document changes —
   `crates/engine/src/lib.rs:2187` `commit_design_token`) and the same id seed. `parameters.add`
   changes the document, so the document pointer and the design token differ → the guard says
   "the design changed" → the editor refuses.

3. **Why the refusal is wrong here.** The editor pins *two* things when it opens
   (`crates/ui-egui/src/lib.rs:2907`, `open_feature_edit`):

   ```rust
   self.editing_state = Some(dialogs::EditingState { source: self.session.scratch(), original });
   ```

   and the engine checks them separately: `same_document_context(self, source)` (the live design
   against the pinned source — the blanket check that refuses) and then, at
   `crates/engine/src/lib.rs:4080`, `expected != *source.doc` (the pinned **original** against
   the pinned **source** — the editor's own model). A parameter added *after* the editor opened
   is in neither the pinned original nor the pinned source, so the editor's own model is still
   perfectly consistent; only the blanket identity check fires. In other words: the guard
   cannot tell "the design changed in a way that makes this edit stale" from "the design gained a
   parameter that this very edit uses".

4. **How the user gets there.** The Parameters panel is a floating panel, so it stays open next
   to the open feature editor, and it adds parameters straight to the live session:
   `crates/ui-egui/src/params_dialog.rs:1520` → `app.run("parameters.add", params)`. The
   editor's OK goes through `crates/ui-egui/src/dialogs.rs:679` →
   `self.session.compute_editor_commands(&self.cmds, &state.source, state.original)`.

### What I think the fix should look like (choose one, justify it in the PR)

The smallest fix that keeps the guard's teeth: the editor must survive a change that leaves the
**edited feature's own inputs** alone (at least: a parameter added), and must still refuse an
edit whose design moved underneath it. Options, in the order I would try them:

* **(a) Engine, content instead of identity.** In `same_document_context` (or a new helper next
  to it), compare what the edit depends on rather than the identity of the whole document: the
  timeline up to and including the edited feature, and the feature's own parameters. A
  parameter added elsewhere in the design then does not invalidate the editor. The
  `expected != *source.doc` check (line 4080) is unaffected: it compares the pinned original
  with the pinned source, both of which are unchanged by the parameter.
* **(b) UI, re-pin the editor.** When the design changes while a feature editor is open, and the
  change is one the editor can absorb, re-pin `editing_state.source` (and the editor's `original`
  if needed) so the editor stays valid — `crates/ui-egui/src/lib.rs:2907` /
  `crates/ui-egui/src/dialogs.rs:679`. The engine API then stays as it is.
* **(c) Engine, merge at accept time.** Let the editor compute against the pinned source and
  merge the live design's extra parameter in when the edit is accepted.

Do **not** weaken the guard for real changes. These existing tests must stay green:

* `crates/engine/src/computed_commands_tests.rs` → `visibility_does_not_make_a_stale_editor_current`
  (a stale editor must stay stale: a changed revision, another active sketch, another
  component, another occurrence path, a feature added, a pending move, another document),
* `... → an_editor_cannot_take_a_pinned_model_from_another_document`,
* `... → revision_context_selection_and_replaced_document_reject_old_work`,
* `... → editor_display_changes_allow_apply_and_cancel` (the #10687 behaviour: a selection, a
  section or an analysis changing while the editor is open must still let OK and Cancel work),
* `... → editor_visibility_changes_allow_apply_and_preserve_separate_undo_steps`.

### The other reporter's path (not reproduced, do not chase it)

jheck7's flow (clicking a rectangular pattern in the view while the extrude editor is open,
then selecting the circles) is **not** reproduced by the parameter path and the triage note on
the issue could not reproduce it either, not even in the app. What changes the document there
is unknown (a guess: the click leaves a pending move, `pending_moves`, which the guard also
compares — `crates/engine/src/lib.rs` `same_document_context`, last clause). Do not chase it;
fix the parameter path, which is the one with a second reporter and a ticket (T-225).

## The method (in this order)

1. **REPRODUCE** with the test above, exactly as written, on the branch. Keep the output.
2. **RED test in the EXISTING test module of the area** — `crates/engine/src/computed_commands_tests.rs`
   (never a new per-bug file: AGENTS.md, issue #3226). The RED test asserts that the edit is
   **accepted** after a parameter is added while the editor is open, and that the parameter
   survives the edit (the design keeps `len` and the feature's distance becomes `len`). If your
   fix lands in `crates/ui-egui`, the RED test goes in that crate's existing test module for the
   area (`crates/ui-egui/src/apply_off_thread_tests.rs` or `dialogs_all_tests.rs`), same rule.
3. **The smallest fix** that makes the RED test green, with the guard's teeth intact (the tests
   listed above).
4. **GREEN**: the whole area's test module passes
   (`cargo test --profile ci -p solidcraft-engine --lib computed_commands` and, if you touched
   the UI, `cargo test --profile ci -p solidcraft-ui-egui --lib`).
5. **Fill in the PR**: the `## Validation` section with the measurements above and the new
   output, the `## Screenshots of the behavior` section with the before/after you captured in
   the app (the editor's error message before, the applied edit after), and the
   `## Integration status` section. Then run `cargo xtask ci` before the final commit.

## The hard rules (AGENTS.md)

* **Never crash**: no `unwrap`/`expect`/`panic`/`unsafe` in non-test code; errors are `Result`;
  the input is hostile; clippy with `-D warnings`; the `hostile_params_never_panic` test.
* **Layering**: only `crates/kernel` uses truck; solidcore is reached only through
  `solidcore-ops` / `-tess` / `-record` (`cargo xtask layers`). **Do not touch `solidcore/` or
  `crates/kernel` for this fix** — the machine does not build the kernel and such a change is
  vetoed.
* One outer UI container, one camera path (`navigation::handle`), colours from theme tokens
  (`cargo xtask ui-containers`).
* The application code is Rust only and builds for wasm (`cargo xtask wasm`).
* English everywhere, in the code, the tests, the commit messages and the PR.
* Lists (message catalogs, `mod` lines) stay sorted (`cargo xtask lists`). A new user-visible
  string goes into `assets/locales/pending/<slug>.json`; an ATTRIBUTION row into
  `attribution/pending/<slug>.md`.
* **A changed default keeps the old behaviour behind a preference**, and the PR's
  `Changes a default:` line says so honestly. The draft PR currently says **`Changes a default: no`**
  (this is a bug fix: the refusal of an edit that is part of the edit is not behaviour anybody
  relies on). If your fix ends up keeping the old refusal behind a preference, change the line
  to `Changes a default: yes - <what>, old behaviour kept behind preference <name>` and say so in
  your report.
* A regression test goes in the area's existing test file, never a per-bug file.
* Never edit generated files (`docs/features.md`, `THIRD-PARTY-LICENSES.txt`).
* One topic per PR. Never merge, never ask for or add `approved-for-ci` / `ready to merge`,
  never comment on the issue or on the PR.
* Show observable changes with screenshots or a recording you captured yourself.
* Run `cargo xtask ci` before every commit.

## The machine

* 12 cores, 15 GB RAM, **no swap**. **One heavy build at a time.**
* Build in the slot's own target dir, with `nice -n 19` and `--profile ci`:
  `CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-9223`.
* Around the big build take the heavy token and release it afterwards:

  ```bash
  bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/slot-lock.sh --heavy --take --wait 3600
  bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/slot-lock.sh --heavy --release
  ```

* Push **only** to the fork (`fork` = `vdirienzo/solidcraft`). `origin` (tangency-labs/solidcraft)
  is read-only here.
* A CLI built from current `main` is already in
  `/home/user/.local/share/solidcraft-orch/targets/triage/ci/solidcraft-cli` (v0.51.1, built from
  `origin/main` = `4b559ca428`) — useful for quick checks without a second build.

## What to do with your work

* Work in `/home/user/solidcraft-wt/issue-9223` on the branch `fix-9223`.
* Commit and push to the fork **after every commit that builds**:
  `git push fork HEAD:fix-9223`. Never push to `origin`.
* Never merge, never mark the PR ready for merge, never comment on the issue or on the PR.
* Never clean up the worktree or the target dir: the orchestrator reuses them.
* Do not open a second PR. The PR is #23431.
* When you are done, report with exactly this JSON object and nothing else:

```json
{"verdict": "ready|blocked", "pr": 23431, "head": "<sha of your last push>",
 "proof": "<what you measured: the test names, the before/after error strings, the volumes>",
 "fast": "<the one command that re-checks it in under a minute>",
 "blocked": "<what stops you, if anything>"}
```
