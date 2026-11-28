# Brief: finish SolidCraft issue #14305 (test + gate + push)

The fix is ALREADY committed and pushed. Your job is the wrap-up only. Do not re-investigate,
do not redesign, do not change the fix unless the test shows it is wrong.

## The slot

- Worktree: `/home/user/solidcraft-wt/issue-14305` (branch `fix-14305`)
- Target dir: `export CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-14305`
- Our draft PR: **#23207** (already open, the claim is done; never open a second PR)
- The fix is commit `c52938d9c1` "Pattern: a copy of a feature is built where the feature was built".
  It is in `crates/doc/src/eval.rs` (and a one-line change in `crates/doc/src/eval_parallel.rs`):
  - `pub type SourceStates = BTreeMap<u64, Arc<ModelState>>` and `before_states`, filled in the
    evaluation loop with the model as it was before each feature ran.
  - in `replay` / `build_replay_copies`: when the source feature's tools cannot be built against
    the current model, they are built against the state before the source feature ran, so the
    copy is the source's own tool, moved.
- The issue: a Circular Pattern that holds several features fails with "there is no body to cut or
  intersect" (or "nothing lies between the profile and the To object") instead of including them.
  The issue's design has Revolve1, Revolve2, Extrude3 and Chamfer1 in the pattern, where Chamfer1
  cuts Extrude3.
- The design file: `/tmp/opencode/issue14305/Twist Cap.sc`. Work on a COPY in your own scratch
  directory (e.g. `/tmp/opencode/scratch-14305/`), never in the repo.

## What to do

### 1. The regression test (RED then GREEN)

Put it in **`crates/doc/src/tests.rs`** — the existing test file of this area, never a new file.
Useful helpers already there:
- `add_in(&mut doc, parent, name, params)` to add a feature,
- `from_scratch(&doc)` to evaluate a document from scratch and get `summary(&ModelState)`,
- `summary(st)` gives `(name, component, volume, face names)` per body,
- a circular pattern is built at about line 837:
  `{"type": "pattern", "features": [slot], "pattern": {"type": "circular", "origin": [0.0, 0.0, 0.0], "axis": [0.0, 0.0, 1.0], "count": "4", "angle": "360 deg"}}`

The case: a pattern that holds several features, where one of them cuts or joins a body that
another one points at with its To Object — the source's own result took the face the copy needs,
so the copy found no body to cut. Build the smallest such case at the doc level (the design file
does not have to be in the repo).

The test must:
- FAIL on the code WITHOUT the fix and PASS with it. Prove both:
  `git stash` is not needed; the fix is a commit, so use
  `git checkout HEAD~1 -- crates/doc/src/eval.rs crates/doc/src/eval_parallel.rs` to remove it,
  run the test (record the failure), then `git checkout HEAD -- crates/doc/src/eval.rs crates/doc/src/eval_parallel.rs`
  to put it back and run the test again (record the pass).
- Assert the user-visible result (the pattern builds and holds all of its features), not an
  internal helper.
- Follow the style of the tests already in that file: English, a doc comment saying what the
  user gets and why, no `unwrap`/`expect`/`panic` outside test code.

Run it with:
`cargo test --profile ci -p solidcraft-doc --lib -- <test name>` (the crate is `solidcraft-doc`;
check its name in `crates/doc/Cargo.toml` if that fails).

### 2. The gate

`cargo xtask fast` with the target dir above, `nice -n 19`, `--profile ci`.
Around big builds take the heavy token:
`bash ~/.local/share/solidcraft-orch/bin/slot-lock.sh --heavy --take --wait 3600`
and release it with `bash ~/.local/share/solidcraft-orch/bin/slot-lock.sh --heavy --release`.
Do NOT run the whole `cargo xtask ci` (90-180 min on this box).

### 3. The end-to-end check with the CLI

Build the CLI in the same target dir (`apps/solidcraft-cli`, `--profile ci`) and run, against a
COPY of the design:

```json
{"commands":[{"command":"timeline.redefine","params":{"command":"solid.pattern.circular","feature":13,"params":{"alignment":"right","angle":"360 deg","axis":"Z","count":"3","features":["Revolve1","Revolve2","Extrude3","Chamfer1"],"reversed":false}}}]}
```

`solidcraft-cli run repro.json --in "Twist Cap.sc" --results`

Record the output for each of these four feature lists:
`["Revolve1","Revolve2","Extrude3","Chamfer1"]`, `["Revolve1","Revolve2"]`, `["Extrude3","Chamfer1"]`,
`["Revolve1"]`.

### 4. Commit and push

`git add` only the test file, commit with a message like
`Pattern: a pattern that holds several features builds with all of them`, then
`git push fork HEAD:fix-14305`. NEVER push to `origin`.

Do not merge, do not mark the PR ready, do not add or ask for `approved-for-ci`, do not comment on
the issue or the PR, do not clean up the worktree, the target dir or the locks.

If the test shows the fix is wrong or incomplete, say so plainly in your report and leave the
work committed; do not start a redesign.

## Your last message

One JSON object and nothing else:

```json
{"verdict": "ready|blocked", "pr": 23207, "head": "<sha>",
 "proof": "<the RED and GREEN commands and what they printed, and the CLI output for each of the four feature lists>",
 "fast": "<the cargo xtask fast result>",
 "blocked": "<what blocks it, or empty>"}
```
