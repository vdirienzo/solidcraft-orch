# Brief: validate and push the follow-up branch for #9223

You are validating an already-written commit on a new base and pushing it. Nobody is watching and
you cannot ask questions: decide yourself and report.

## The situation

- Worktree `/home/user/solidcraft-wt/issue-9223`, branch `fix-9223-cancel-undo`, head
  `9a74f297e9` (a cherry-pick of `e952ded0bb` onto the current `origin/main` = `48cdd5f5a5`).
- The commit fixes three things for upstream issue #9223 (the feature editor refuses the edit when
  the design gained a parameter while the editor was open):
  1. the **Cancel** path (`Session::restore_editor`) now accepts a design that only gained
     parameters: cancelling rolls the edit back and KEEPS the parameter;
  2. the **undo history** no longer loses the gained parameter (undoing a `browser.visibility`
     change made while the editor was open used to restore the parameter-less document);
  3. the editor's **base** keeps a consistent pose (the base document, its model and its capture
     state now describe the same design).
- Three new tests were added in `crates/engine/src/computed_commands_tests.rs`:
  `cancelling_after_a_parameter_was_added_keeps_the_parameter`,
  `undoing_a_visibility_change_keeps_the_parameter_the_design_gained` and
  `a_parameter_added_while_the_editor_is_open_keeps_the_designs_poses`.
- These were already measured GREEN on the previous base (30 tests passed in that module) and RED
  with the fix reverted (27 passed, the 3 new ones failed). **Your job is to measure it again on
  this new base**, because `main` moved and touched `crates/engine/src/lib.rs` twice since.

## What to do

1. Take the heavy token (another job holds it now, so expect to wait):
   ```bash
   bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/slot-lock.sh --heavy --take --wait 3600
   ```
   Release it with `--heavy --release` as soon as you are done.

2. Build and test in the slot's target dir:
   ```bash
   cd /home/user/solidcraft-wt/issue-9223
   export CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-9223
   nice -n 19 cargo test --profile ci -p solidcraft-engine --lib computed_commands -- --nocapture
   ```
   The module must be fully green (30 tests). Report the summary line.

3. Clippy on the touched crate:
   ```bash
   nice -n 19 cargo clippy --profile ci -p solidcraft-engine --all-targets -- -D warnings
   ```

4. Then the whole engine library suite, to prove no new failure on this base:
   ```bash
   nice -n 19 cargo test --profile ci -p solidcraft-engine --lib 2>&1 | tail -60
   ```
   A previous run of this suite on the previous base gave "8741 passed; 17 failed; 22 ignored",
   where the 17 are known pre-existing failures (kernel booleans/fillets/shells/lofts and drawing
   fonts that need an installed font). Report the summary line and the list of the failing test
   names, and say whether any of them is NEW (i.e. not in that known set). If a failure is new,
   do NOT try to fix it: report it with the name and the output.

5. Push ONLY to the fork, and only this branch:
   ```bash
   git push fork fix-9223-cancel-undo:fix-9223-cancel-undo
   ```
   NEVER push to `origin` (upstream is read-only here).

## Hard rules

- Do NOT change any code, do NOT commit anything new, do NOT touch any pull request (no body, no
  label, no state, no comment), do NOT merge, do NOT delete the worktree, the target dir or the
  locks. Your job is only: measure, and push.
- `nice -n 19` and `--profile ci`. Do NOT run `cargo xtask ci` (90-180 min here).

## Deliverable

Your final message must be one JSON object and nothing else:
{"base": "48cdd5f5a5", "head": "<the sha you pushed>", "module": "<the summary line of the
computed_commands module>", "clippy": "pass|fail", "suite": "<the summary line of the whole engine
lib suite>", "failed_tests": ["<name>", "..."], "new_failures": ["<the names that are NOT in the
known pre-existing set, empty if none>"], "pushed": "yes|no", "blocked": "<what blocks it, or empty>"}
