# Brief: rebase fix-9223 onto current main and re-validate

You are re-basing and re-validating an existing, finished fix. Nobody is watching and you cannot
ask questions: make the decisions yourself and report.

## The situation

- Worktree: `/home/user/solidcraft-wt/issue-9223`, branch `fix-9223`.
- Our draft PR against upstream: https://github.com/tangency-labs/solidcraft/pull/23431 (issue #9223).
- The fix is committed and pushed to the fork: head `2284e476dd9c84c98975e3c41f6767aae08faaeb`.
- The branch is based on `e05258b9e5`, but `origin/main` has moved on by 362 commits (now
  `01ce850acf`). Upstream's CI builds the merge result, so the branch must sit on the current
  `main` to be validated against it and to merge without surprises.
- `main` touched `crates/engine/src/lib.rs` in exactly two commits (`9ee86e6417` "Sketch: Cancel
  works after Undo reopens a finished sketch" and its merge `50a84f88da`). I checked: the
  `same_document_context` guard and the `extrusion_editor()` helper in
  `crates/engine/src/computed_commands_tests.rs` are byte-identical in the current `main`, so the
  fix should apply cleanly.

## What to do

### 1. Rebase

```bash
cd /home/user/solidcraft-wt/issue-9223
git fetch origin
git rebase origin/main
```

If there is a conflict, resolve it this way: take `main`'s version of every hunk EXCEPT the
hunks that implement the fix (the new `same_editor_context_with_gained_parameters`,
`design_gained_only_parameters` and `editor_base` helpers, the `base` parameter threaded through
`compute_commands_inner` / `compute_commands_under`, and the changed guard in
`compute_editor_commands`). In other words: the fix must survive, and nothing of `main`'s newer
work may be lost. If a conflict cannot be resolved that way, STOP and report it as blocked.

Then re-run the formatting the repo requires on the touched files:
`cargo fmt --all` and confirm `cargo fmt --all -- --check` is clean.

### 2. Re-validate on the NEW base, both directions

The RED evidence in the PR body was measured on the old base. Measure it again on the new base.

Around a big build take the heavy token and release it when you are done:

```bash
bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/slot-lock.sh --heavy --take --wait 3600
bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/slot-lock.sh --heavy --release
```

Use the slot's target dir and be gentle with the machine:

```bash
export CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-9223
nice -n 19 cargo test --profile ci -p solidcraft-engine --lib computed_commands -- --nocapture
```

- GREEN: with the fix in place, the module `computed_commands` must be fully green (27 tests).
- RED: temporarily restore ONLY the pre-fix engine implementation and run the new test alone:
  ```bash
  git stash push -- crates/engine/src/lib.rs   # or: git checkout <pre-fix-sha> -- crates/engine/src/lib.rs
  nice -n 19 cargo test --profile ci -p solidcraft-engine --lib a_parameter_added_while_the_editor_is_open_keeps_the_edit -- --nocapture
  ```
  It MUST fail with "the editor refused the edit: the design changed while the feature editor was
  open". Then put the fix back (`git checkout HEAD -- crates/engine/src/lib.rs`) and confirm the
  module is green again. If the RED does not reproduce on the new base, that is a blocker: report
  it, do not paper over it.

Do NOT run `cargo xtask ci` (90-180 min here). `cargo xtask fast` was already green on the
pre-rebase tree; a re-run of the whole gate is not required, but DO run clippy on the touched
crate so the rebase did not bring a lint:

```bash
nice -n 19 cargo clippy --profile ci -p solidcraft-engine --all-targets -- -D warnings
```

### 3. Push

Push ONLY to the fork, with a lease, so a force-push never clobbers someone else:

```bash
git push --force-with-lease fork HEAD:fix-9223
```

NEVER push to `origin` (upstream is read-only here). Do NOT touch the PR (no comments, no labels,
do not mark it ready, do not merge). Do NOT delete the worktree or the target dir.

### 4. Report

Your final message must be one JSON object and nothing else:
{"verdict": "ready|blocked", "pr": 23431, "head": "<the new sha>", "base": "<the origin/main sha you rebased onto>",
 "rebase": "clean|conflicts resolved how|failed", "red": "<the exact failing output on the new base>",
 "green": "<the test summary on the new base>", "clippy": "pass|fail", "blocked": "<what blocks it, or empty>"}
