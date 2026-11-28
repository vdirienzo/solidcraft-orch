# Brief: second round on #9223 (the review findings and the Cancel path)

You are fixing three things in an existing, already-reviewed pull request. Nobody is watching and
you cannot ask questions: decide yourself and report.

## The situation

- Worktree `/home/user/solidcraft-wt/issue-9223`, branch `fix-9223`, head
  `99a9d7043b7268021a858f0231e53aafb6176859`, pushed to the fork `vdirienzo/solidcraft`.
- Our PR against upstream: https://github.com/tangency-labs/solidcraft/pull/23431 (issue #9223).
  It is already "ready for review" and the upstream CI is GREEN on it. A maintainer added the
  labels `ready to merge` and `approved-for-ci`. **Push new commits when they build**; do not touch
  the PR's body, its labels or its state.
- What the PR fixes today: `Session::compute_editor_commands` (`crates/engine/src/lib.rs` ~4040)
  refused with "the design changed while the feature editor was open" whenever the design had
  changed at all, because `same_document_context` compares the document by identity (`Arc::ptr_eq`)
  and by the `design_revision` token. Now a design that only **gained parameters** since the editor
  opened is accepted (`same_editor_context_with_gained_parameters` ~4284,
  `design_gained_only_parameters` ~4305, `editor_base` ~4318), and the edit is computed on the design
  as it is now.
- Read `/tmp/opencode/findings-9223-q1.md` first: it traces every UI path that can produce either
  message, with file:line. The short version:
  - **OK** → `crates/ui-egui/src/dialogs.rs:846` → `compute_editor_commands` → "the design changed
    while the feature editor was open" (no suffix). The dialog stays open, there is no fallback.
  - **Cancel / Esc / X / closing without applying** → `crates/ui-egui/src/dialogs.rs:6261` →
    `restore_editor` → "the design changed while the feature editor was open; its current timeline
    was preserved" (WITH the suffix).
  - **Preparing the editor** (`crates/ui-egui/src/feature_edit.rs:155`) and **editing another
    feature while an editor is open** (`crates/ui-egui/src/lib.rs:3625` → `dialogs::cancel`) also
    go through `restore_editor`.
- The maintainer of the upstream issue (bherbruck, ticket T-225) quoted the message WITH the
  suffix, so his scenario is a **Cancel**, and our current fix does not cover it.

## The three things to fix

### 1. The Cancel path (`restore_editor`) must accept a design that only gained parameters

Cancelling a feature editor after the user added a parameter to the design must **roll the edit
back and keep the parameter**. Today `restore_editor` refuses outright (and the timeline is left
as it is). The parameter the user added is not part of the edit being cancelled, so it must survive
the cancel, exactly like it survives the OK.

- The engine call is `crates/engine/src/lib.rs` `restore_editor` (~4320). It restores `original`
  (the design as it was when the editor opened). With the gained parameters, the design it
  restores must keep them.
- Do NOT weaken the guard for a genuinely stale design: a feature that changed, a parameter that
  changed or was removed, another sketch/component/occurrence path, another document, a pending
  move: those must still refuse, for OK **and** for Cancel.

### 2. The undo history must not lose the gained parameters (the review's Major finding)

`accept_commands` calls `restore_editor_history(&prepared.source.doc, original)`
(`crates/engine/src/lib.rs` ~4206). `restore_editor_history` (~4361) replaces every undo/redo
snapshot whose document is pointer-equal to the source with `original.doc`, which has no gained
parameter. `browser.visibility` does not change the document's `Arc`, so the visibility undo step's
snapshot IS that very `Arc` and it gets replaced by the parameter-less original.

Sequence that loses the parameter: add the parameter while the editor is open → change
`browser.visibility` while the editor is open → press OK → undo the visibility change → the
parameter (and the edit that uses it) is silently gone.

Fix it, and cover it with a test.

### 3. The base's pose must stay consistent with the model it is paired with (the review's Minor finding)

`editor_base` (~4318) rewrites only `marker`, so the base document keeps the rolled-back occurrence
transforms and joint values while the same transaction pairs it with the **original's full-marker**
model and capture state; `accept_computed` installs document, model and `last_capture_state`
without a capture sync (~4506, ~4515, ~4553), and `sync_capture_position_state` then returns early
because the capture state already matches the model (~2537).

Fix it if it can be done without expanding the scope. If you judge that it cannot be fixed
cleanly, say so in your report and in the commit message, and leave the code as it is.

## The method

REPRODUCE FIRST, then a RED test in the EXISTING test module of the area, then the smallest fix,
then GREEN.

- The engine's test module for this area is `crates/engine/src/computed_commands_tests.rs` (the
  helper `extrusion_editor()` opens a feature's editor the way the window does). **Never** create a
  new test file.
- The existing tests in that module are the guard's teeth. They must all stay green:
  `visibility_does_not_make_a_stale_editor_current`,
  `an_editor_cannot_take_a_pinned_model_from_another_document`,
  `revision_context_selection_and_replaced_document_reject_old_work`,
  `editor_display_changes_allow_apply_and_cancel`,
  `editor_visibility_changes_allow_apply_and_preserve_separate_undo_steps`, and the rest (27 tests).
- Write the new tests in the same style as the existing ones, with a comment naming the issue.

## Hard rules (they are the law)

- English everywhere. No `unwrap`/`expect`/`panic` in non-test code. No new user-visible string
  without a line in `assets/locales/pending/<slug>.json`. Lists stay sorted. No generated file.
- Never crash, never weaken a guard to make a test pass, never change a default without a
  preference behind it.
- Commit and push to the fork after every commit that builds: `git push fork HEAD:fix-9223`.
  NEVER push to `origin` (upstream is read-only here).
- Do NOT touch the PR: no body edit, no label, no state change, no comment on the PR or the issue.
  Do NOT merge. Do NOT delete the worktree, the target dir or the locks.

## The machine

- 12 cores, 15 GB, one heavy build at a time. `nice -n 19`, `--profile ci`.
- Target dir: `export CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-9223`
- Around a big build take the heavy token
  (`bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/slot-lock.sh --heavy --take --wait 3600`)
  and release it with `--heavy --release`. Other jobs need it; release it as soon as you are done.
- Do NOT run `cargo xtask ci` (90-180 min here). Run the gate for the touched crate:
  `cargo clippy --profile ci -p solidcraft-engine --all-targets -- -D warnings` and
  `cargo test --profile ci -p solidcraft-engine --lib computed_commands -- --nocapture`.

## The deliverable

Your final message must be one JSON object and nothing else:
{"verdict": "ready|blocked", "pr": 23431, "head": "<sha>",
 "proof": "<the RED and GREEN commands and what they printed, for each of the three fixes>",
 "minor": "<what you did about finding 3, or why you left it>", "blocked": "<what blocks it, or empty>"}
