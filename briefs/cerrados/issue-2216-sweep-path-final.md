# Brief — #2216: a body's edge can be the path of a sweep

## What is ALREADY DONE (do not redo it)

The diagnosis is complete and the implementation is written. Do NOT explore the repo, do NOT
re-derive the design, do NOT write the fix from scratch.

Two things exist on disk:

1. **The RED test** — commit `1eb8c3df6` ("test(ui): a sweep takes a body's edge as its path
   (#2216)"), in `crates/ui-egui/src/sweep_dialog_tests.rs`. It is the ONLY file that commit
   touches. It builds a block, picks the block's upright corner edge in the sweep dialog's Path
   input, and asserts the pick lands there and the sweep builds.
2. **The implementation** — a patch file at
   `/home/user/.local/share/solidcraft-orch/logs/2216-impl.patch` (401 lines, 8 files):
   - `crates/doc/src/document.rs` — `FeatureKind::Sweep` and `FeatureKind::SurfaceSweep` gain two
     optional saved fields: `path_body: Option<BodyName>` and `path_edges: Vec<Position>`.
   - `crates/doc/src/eval.rs` — new `edge_path_segments()`: chains a body's edges with
     `kernel::chain`, turns each edge into its curve with `kernel::edge_path`, reverses the ones
     the chain runs against, and starts the path at the end nearest the profile.
   - `crates/doc/src/eval_surface.rs` — the same for `surface.sweep`.
   - `crates/engine/src/cmd/features.rs` — new `sweep_path()` reads either `path_body`/`path_edges`
     or `path_sketch`/`path`; the `solid.sweep` params string documents the two new params.
   - `crates/engine/src/cmd/surface.rs` — `surface.sweep` uses the same helper; params updated.
   - `crates/ui-egui/src/dialogs.rs`, `dialogs_surface.rs`, `dialogs_sweep.rs` — the Path input
     accepts `CURVES | EDGES`; new `dialogs_sweep::edge_path()` turns edge picks into
     `path_body`/`path_edges`.

**Verified against the CURRENT `origin/main` (`6d2465b52`) by the orchestrator, before this
brief was written.** All of these were checked to exist upstream, so the patch compiles:

- `kernel::chain(&Body, &[Vec3]) -> Result<Chain>` — `crates/kernel/src/bridge.rs:49`
- `kernel::edge_path(&Body, usize) -> Result<Vec<PathSeg>>` — `crates/kernel/src/point_path.rs:180`
- `kernel::PathSeg::reversed` / `::start()` / `::end()` — `crates/kernel/src/build.rs`
- `kernel::sweep_with` and `kernel::sweep_sheet_with` exist
- `crate::lineage::ProfileRoles::swept(...)`, `crate::lineage::ChainRoles { sketch, chains }`
- `crate::plain()` (`crates/doc/src/points.rs:59`), `crate::eval::rail_polylines`,
  `crate::eval::sweep_control`, `crate::eval::path_segments_at`
- `crate::names::BodyName: From<&str>`, `crate::points::Position: From<Vec3>`
- `crate::dialogs::edge_sel`, `crate::selection::point_value`
- The RED test's APIs: `Harness::new`, `h.app.run`, `h.step`, `h.at`, `h.frames`,
  `d.inputs[..].items`, `d.active`, `Kind::Sweep { operation, .. }`, `Sel::Edge { .. }`,
  `FeatureKind::Sweep { .. }`

**The orchestrator already proved the integration applies cleanly to the current base**: in a
scratch worktree at `origin/main`, `git cherry-pick --no-commit 1eb8c3df6` succeeded and
`git apply --3way /home/user/.local/share/solidcraft-orch/logs/2216-impl.patch` applied all 8
files cleanly ("Applied patch to ... cleanly" for each). You will redo this in the real worktree
because you must also build and test it.

## YOUR WORKTREE

- Worktree: `/home/user/solidcraft-wt/issue-2216` (ALREADY EXISTS, on branch
  `fix/issue-2216-sweep-path`, HEAD `1eb8c3df6`, based on the old base `d1927aac2`).
- `origin` is UPSTREAM (tangency-labs/solidcraft). `fork` is OURS (vdirienzo/solidcraft).
  **Push ONLY to `fork`.**
- The branch is 100+ commits behind `origin/main`. Rebuild it on the current base:

```bash
cd /home/user/solidcraft-wt/issue-2216
git fetch origin
git checkout -B fix/issue-2216-sweep-path origin/main
git cherry-pick 1eb8c3df6          # the RED test, onto the new base
git apply --3way /home/user/.local/share/solidcraft-orch/logs/2216-impl.patch
git status --short                  # must list exactly the 9 files below
```

The 9 files that must be modified (8 from the patch + the RED test file):

```
crates/doc/src/document.rs
crates/doc/src/eval.rs
crates/doc/src/eval_surface.rs
crates/engine/src/cmd/features.rs
crates/engine/src/cmd/surface.rs
crates/ui-egui/src/dialogs.rs
crates/ui-egui/src/dialogs_surface.rs
crates/ui-egui/src/dialogs_sweep.rs
crates/ui-egui/src/sweep_dialog_tests.rs
```

**Other worktrees are OFF-LIMITS.** Do not touch `/home/user/solidcraft` (the main checkout is
shared and drifting), `/home/user/solidcraft-wt/issue-2160`, `/home/user/solidcraft-wt/probe2216`,
or any other `issue-*` worktree. Never `git push origin`. Never force-push `main`.

## ONE ARTEFACT: the GREEN commit + the draft PR

Your single deliverable is **one commit that makes the RED test pass, pushed to `fork`, plus a
draft PR claiming #2216**. Do not stop at "the patch applies".

### Step 1 — RED proof (the test must fail on the base)

Before applying the implementation, prove the test is RED on the current base. The test file is
`crates/ui-egui/src/sweep_dialog_tests.rs`, the test is `a_sweep_takes_a_body_edge_as_its_path`.

The ui-egui test build is heavy and the Hermes cgroup is capped at 4 GiB, so a plain
`cargo test` gets OOM-killed. Use a systemd scope:

```bash
cd /home/user/solidcraft-wt/issue-2216
export CARGO_TARGET_DIR="$(bash /home/user/.local/share/solidcraft-orch/bin/slot-target-dir.sh --slot 2216)"
systemd-run --user --scope --quiet --unit=sc2216-red -p MemoryMax=24G bash -lc \
  'cd /home/user/solidcraft-wt/issue-2216 && \
   CARGO_TARGET_DIR='"$CARGO_TARGET_DIR"' CARGO_BUILD_JOBS=4 CARGO_INCREMENTAL=0 \
   cargo test -p solidcraft-ui-egui --profile ci --lib a_sweep_takes_a_body_edge_as_its_path -- --nocapture'
```

Save the output to `/home/user/.local/share/solidcraft-orch/logs/2216-RED.log`.

**The RED must fail for the RIGHT reason.** The expected failure: the pick does not land in the
Path input (upstream's Path input accepts only `CURVES`), so the assertion
`assert!(matches!(path.as_slice(), [Sel::Edge { .. }]), "the path took the edge: {path:?}")` fails.
If it fails for a DIFFERENT reason (a compile error, a missing API, a panic elsewhere), that is
NOT a valid RED: fix the test's setup until the failure is the missing feature. A RED that
measures the wrong thing protects nothing.

**If the test PASSES on the base, STOP.** The bug is already fixed upstream, no pull request is
owed. Report that and open NO PR. (The orchestrator believes it fails; you verify.)

### Step 2 — GREEN

Apply the implementation patch (the command block above), then run the same command again and
save the output to `/home/user/.local/share/solidcraft-orch/logs/2216-GREEN.log`. It must pass.

If the implementation does not compile or the test does not pass, fix it. The patch was written
against `d1927aac2`; the base moved. If a hunk conflicts, resolve it by hand in the file
(`git apply --3way` already did the merge for you — check the result with `git diff`).

Also run the OTHER tests of the two crates you touched, so a regression in the area is visible:

```bash
cargo test -p solidcraft-doc --profile ci --lib
cargo test -p solidcraft-engine --profile ci --lib
```

**Compile discipline (the box is shared, 16 cores, other jobs run here):**
- Take a build slot before compiling: `bash /home/user/.local/share/solidcraft-orch/bin/build-slot.sh --take --wait 1800`
  and release it with `--release <token>` when done.
- `export CARGO_BUILD_JOBS="$(bash /home/user/.local/share/solidcraft-orch/bin/cargo-jobs.sh)"`
  and `export CARGO_INCREMENTAL=0`.
- NEVER `pkill`, `killall` or `kill -9`. To stop your own build, record the PID and `kill -TERM`
  only that PID.
- Do NOT run the full `cargo xtask ci` and do NOT run the GPU/path tests.
- Keep the same `CARGO_TARGET_DIR` for every command in this worktree.

### Step 3 — commit

```bash
cd /home/user/solidcraft-wt/issue-2216
git add crates/doc/src/document.rs crates/doc/src/eval.rs crates/doc/src/eval_surface.rs \
        crates/engine/src/cmd/features.rs crates/engine/src/cmd/surface.rs \
        crates/ui-egui/src/dialogs.rs crates/ui-egui/src/dialogs_surface.rs \
        crates/ui-egui/src/dialogs_sweep.rs crates/ui-egui/src/sweep_dialog_tests.rs
git status --short          # MUST show only those 9 files, nothing else
git commit -m "Sweep: a body's edge can be the path of a sweep (#2216)"
```

Name the files EXPLICITLY. `git add -A` in a worktree that holds scratch files sweeps the
scratch into the commit, and a stray file in the diff is a reason for the maintainer to close
the pull request.

Commit message body: one paragraph saying what changed and why, in plain literal English.

### Step 4 — push and open the DRAFT PR (this is the CLAIM)

```bash
git push fork fix/issue-2216-sweep-path
```

Then open the draft PR. Use the ABSOLUTE path to `gh` (`/home/user/.local/bin/gh`) — the `gh` on
PATH may be a stub that silently does nothing.

- Repo: `tangency-labs/solidcraft` (the PR goes to upstream; the BRANCH comes from our fork).
- **Title**: `Sweep: a body's edge can be the path of a sweep (#2216)`
  (readable by someone who has never seen this chat or the issue: say which part of the app
  changes and what a user now sees.)
- **Draft**: yes. The draft IS the claim.
- **Base**: `main`.
- **Head**: `vdirienzo:fix/issue-2216-sweep-path`.

Body — use this structure, filling in the measured facts:

```
Fixes #2216

Changes a default: no

## The problem

A sweep's path could only be the curves of a sketch. The Path input of the Sweep dialog
accepted only curves, so a user who picked an edge of a body — the natural thing to do when the
edge is the shape the profile should follow — got "select the path first" and the sweep was
refused.

## The fix

The Path input of the sweep dialog now accepts a body's edges as well as a sketch's curves.
When the picks are edges of one body, the sweep is built with that chain of edges as its path:
the edges are chained end to end, each one is followed by the curve it is, and the path starts
at the end nearest the profile. The command takes the path as `path_body` (the body) and
`path_edges` (a point on each edge of the chain); a path of sketch curves is unchanged.

## The test

`crates/ui-egui/src/sweep_dialog_tests.rs`, `a_sweep_takes_a_body_edge_as_its_path`: a block
whose upright corner edge is the path, the edge picked in the Path input of the sweep dialog,
and the sweep built with it.

## Validation

RED (the test fails on the base, because the Path input accepted only curves):
<the exact failure line from 2216-RED.log>

GREEN (the same test passes with this change):
<the exact pass line from 2216-GREEN.log>

## Note for the reviewer

The saved design gains two optional fields, `path_body` and `path_edges`, on a sweep. A design
saved by this build and opened by an older build loses the path.
```

**The `Changes a default:` line must be exactly `Changes a default: no`** — that is the exact
wording the upstream parser accepts (it rejects `Changes to default:` and any malformed value).
Do NOT put it in a code fence, do NOT comment it out with HTML, do NOT put backticks around it.
The position does not matter.

**`Fixes #2216` — use the closing verb**, because this change fully delivers what the issue
asked (the path can be a body's edge). Note: the maintainer triaged a *different* aspect of this
issue ("Noted for the inside-corner request") as a request; that part is NOT what this PR does.
Mention in the body that the inside-corner behaviour the reporter compared against Fusion is a
separate request and is not touched here. Do NOT close that request from this PR — say so
plainly in the body instead.

**Before opening the PR, validate the body against the upstream parser:**

```bash
cat > /tmp/2216-body.md <<'EOF'
<the full body text>
EOF
bash /home/user/.local/share/solidcraft-loop/bin/pr-defaults-line.sh --body /tmp/2216-body.md
```

It must print `checked: 1 missing: 0` and exit 0.

### Step 5 — verify the claim AFTER opening the draft

The claim of an issue is a race and the lowest-numbered open PR wins. After the PR exists:

```bash
bash /home/user/.local/share/solidcraft-orch/bin/claim-verify.sh 2216 <your_pr_number>
```

- Exit 0 → the claim is yours. Continue.
- Exit 1 → you LOST the claim (another PR with a LOWER number mentions #2216). Then:
  `gh pr close <your_pr_number>`, push your work to a `wip` branch on the fork so nothing is
  lost, and report that you lost the claim and what you saved.
- Exit 2 → the claim could not be verified (GitHub did not answer). Do NOT publish further work
  on it; report it.

### Step 6 — report (FIVE things, no more)

1. The commit SHA you pushed, and the PR number and URL.
2. The exact `Changes a default:` line you used.
3. The RED output: the exact failing assertion line from `2216-RED.log`.
4. The GREEN output: the exact pass line from `2216-GREEN.log`.
5. The verdict of `claim-verify.sh` after opening the PR, with its exit code.

If you run out of budget before the PR exists: commit what you have as
`wip(#2216): <what exists>` on a `wip/issue-2216` branch, push it to `fork`, and report the
SHA and what is missing. A `wip` commit on the fork is recoverable; an uncommitted tree is lost
work.

## HARD RULES (never break)

- Push ONLY to `fork`. Never to upstream. Never force-push `main`.
- Never open a second PR for an issue an open PR already claims.
- **Never touch `crates/kernel/`.** This change only CALLS the kernel's public API; it does not
  change it. `kernel::chain` and `kernel::edge_path` already exist upstream and are already used
  by `crates/doc/src/construct.rs` for exactly this purpose (a body edge's record curve).
- No `unwrap`/`expect`/`panic`/`unsafe` in non-test code. `cargo clippy -D warnings` must pass
  on the touched packages (`solidcraft-doc`, `solidcraft-engine`, `solidcraft-ui-egui`).
- One topic and one issue per PR. The regression test goes in the area's EXISTING test file
  (`crates/ui-egui/src/sweep_dialog_tests.rs`) — do NOT create a new test file.
- Do NOT add the label `approved-for-ci`.
- The new error strings in `dialogs_sweep::edge_path` are plain Rust literals in an existing
  pattern (the dialogs already use plain literals like "the path curves must be in one sketch",
  which are NOT in the locale catalogs) — so they need NO `assets/locales/pending/*.json` file.
  Do not add one.
- The new saved fields on `FeatureKind::Sweep` / `FeatureKind::SurfaceSweep` ARE a change to
  what a design file saves. Per `AGENTS.md`, a design-format change is ONE new file in
  `crates/doc/src/format/pending/` — add exactly ONE file there (name it after the change, lower
  case with dashes, e.g. `sweep-path-on-body-edges.rs`), starting with a `//!` note saying what
  is saved, what an older design gets without it, and what the last release does with a design
  that has it. **You MUST add this file** — a design-format change without it breaks
  `cargo xtask ci`. Read
  `crates/doc/src/format/pending/README.md` and
  `crates/doc/src/format/pending/bridged-counterbore.rs` for the shape, and
  `crates/doc/src/format.rs` for the history list. If the change needs no rewrite step for old
  designs (it does not: the new fields are optional and default to absent), the file is a NOTE
  ONLY, exactly like `bridged-counterbore.rs` — no `pub fn step`.
  The file must be added to your `git add` list.
- Real evidence for observable behaviour: this change is about what a user can PICK in a dialog,
  so a screenshot would be nice but is NOT required (there is no visible rendering change).
  Never fabricate one.

## FILES YOU MAY NEED TO READ (and nothing else)

- `crates/doc/src/format/pending/README.md` — the shape of a pending-format file.
- `crates/doc/src/format/pending/bridged-counterbore.rs` — a note-only example.
- `crates/doc/src/format.rs` — the format history (first 80 lines).
- `/home/user/.local/share/solidcraft-orch/logs/2216-impl.patch` — the implementation.

Do NOT read the rest of the repo. Do not explore. The diagnosis is done.
