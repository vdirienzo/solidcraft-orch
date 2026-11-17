# Brief — #2216 (CONTINUATION): finish the sweep-edge-path change and open the PR

## A previous agent already did 90% of this. Read this before touching anything.

The diagnosis is DONE. The implementation is DONE and COMPILES. The RED test is DONE and its
failure is a VALID behavioural RED. One wiring step is missing, then the publication.

**Do NOT re-derive the design. Do NOT explore the repo. Do NOT re-apply the patch. Do NOT
rebuild the RED.** Everything below is verified fact. Your job is: write the missing wiring,
get the test green, run the gate, publish.

### The worktree, exactly as it is now

- Path: `/home/user/solidcraft-wt/issue-2216`
- Branch: `fix/issue-2216-sweep-path`
- HEAD: `dbb51ba6a` — "test(ui): a sweep takes a body's edge as its path (#2216)". This is the
  RED test commit (the cherry-pick of `1eb8c3df6` onto the current base), already committed.
  Base is `origin/main` = `6d2465b52`.
- **The implementation is already applied in the working tree, partly staged:**

```
$ git diff --cached --stat        # STAGED (8 files)
 crates/doc/src/document.rs            | 14 +++++++++-
 crates/doc/src/eval.rs                | 42 ++++++++++++++++++++++++++++-
 crates/doc/src/eval_surface.rs        | 17 ++++++++++-
 crates/engine/src/cmd/features.rs      | 50 +++++++++++++++++++++++++++--------
 crates/engine/src/cmd/surface.rs       | 11 +++----
 crates/ui-egui/src/dialogs.rs          | 23 +++++++---
 crates/ui-egui/src/dialogs_surface.rs  | 26 ++++++++-----
 crates/ui-egui/src/dialogs_sweep.rs    | 21 +++++++++++

$ git diff --stat                  # ALSO STAGED-AND-EDITED (2 files, unstaged on top)
 crates/doc/src/eval.rs              |  8 ++++----
 crates/ui-egui/src/dialogs_sweep.rs | 29 +++++++++++++++------

$ git status --porcelain | grep '^??'
 crates/doc/src/format/pending/sweep-path-on-body-edges.rs
```

So: **8 modified files + 1 new file.** The RED test file
(`crates/ui-egui/src/sweep_dialog_tests.rs`) is already committed at HEAD and must NOT be
modified.

- The new pending-format file exists and its text is already correct:
  `crates/doc/src/format/pending/sweep-path-on-body-edges.rs`, a `//!` note-only file (no
  `pub fn step`) saying a sweep now saves `path_body` and `path_edges` beside the path sketch's
  curves, that an older design keeps its path of sketch curves, and that the last release
  refuses a design that has it. Do not rewrite it unless you have a concrete reason.

### The RED is valid — do not redo it

`/home/user/.local/share/solidcraft-orch/logs/2216-RED.log` holds the RED run. The failure:

```
thread 'sweep_dialog_tests::a_sweep_takes_a_body_edge_as_its_path' panicked at
crates/ui-egui/src/sweep_dialog_tests.rs:130:5:
the path took the edge: [SketchCurve { id: "l3", sketch: Some(2) }]
```

That is the assertion at the heart of the RED: the test picks the block's upright corner edge
and expects the Path input to hold `Sel::Edge { .. }`, but the Path input got a **curve of the
profile's own sketch** instead. The RED is behavioural (the assertion), not a compile error.

### THE MISSING WIRING — this is the whole remaining implementation

**The symptom:** with the Path input now accepting `CURVES | EDGES`, the click at the block's
corner edge lands on the profile sketch's own curve (`l3` of sketch `Q`) instead of the body's
edge, because the viewport offers sketch-curve hits BEFORE body-edge hits.

**The verified mechanics (all checked against the current `origin/main`):**

1. `crates/ui-egui/src/viewport.rs` builds the hit list and offers a **sketch-curve** hit
   (around line 2776/2790, `bestc.offer(...)`) before a **body-edge** hit (around line 2934,
   `beste.offer(...)`).
2. `crates/ui-egui/src/viewport.rs::candidate(app, hits)` (around line 3468) walks the hits in
   order and takes the FIRST one the open dialog's active input accepts:
   ```rust
   hits.iter().find_map(|h| d.candidate_on(&app.session, h, snap.as_ref()).map(...))
   ```
   So the first acceptable hit wins. With `CURVES | EDGES` both are acceptable, and the sketch
   curve comes first.
3. `crates/ui-egui/src/dialogs.rs::candidate_on` (line 1568) ends with
   `inp.accepts(h, s.active_sketch, ...)` — `crates/ui-egui/src/selection.rs::accepts`
   (line 127) maps `Hit::SketchCurve` to `Sel::SketchCurve` and `Hit::Edge` to `Sel::Edge`,
   and both pass when the input accepts `CURVES | EDGES`.
4. **The path of a sweep may never be in the profile's own sketch.** This is already enforced
   downstream: `crates/ui-egui/src/dialogs.rs` line ~5220 builds `solid.sweep`'s params with
   `picks_sketch(app, sels(d, 1), sketch.as_u64())` — the third argument is the PROFILE's
   sketch, and `picks_sketch` (line 5835) ends with `.filter(|k| Some(*k) != not)`, i.e. the
   path's sketch must DIFFER from the profile's sketch. `surface.sweep` does the same at
   `crates/ui-egui/src/dialogs_surface.rs:549` with the error text
   "the path curves must be in one other sketch".

**Therefore the correct fix is already half-written for you:** a curve of the profile's own
sketch is NOT a valid path, so the pick must not stop on it — it must fall through to the next
hit, which is the body's edge.

**The helper the previous agent already wrote** (in
`crates/ui-egui/src/dialogs_sweep.rs`, around line 118) — read it, it is your starting point:

```rust
/// The sketch a sweep's profile is in, when the profile is picked: the sketch of the
/// profile's regions, or the sketch of the curves picked as the profile. `None` when the
/// profile is not picked yet, or when it is in two sketches at once.
pub fn profile_sketch(items: &[Sel], active: Option<u64>) -> Option<u64> {
```

It is currently UNUSED (dead code) — wiring it in is your job.

**Where to wire it.** The pick must SKIP a `Hit::SketchCurve` whose sketch is the profile's
sketch, so `find_map` continues to the next hit. The natural place is in
`crates/ui-egui/src/dialogs.rs::candidate_on` (line 1568), in the branch that handles the
sweep dialogs — but ONLY for a sweep's Path input, and only when the profile is already
picked. `candidate_on` already has a precedent for a per-kind special case at its top:

```rust
if matches!(self.kind, Kind::SketchModify(_)) {
    return crate::sketch_modify_ui::candidate(self, s, h);
}
```

so a similar, sweep-specific early return is idiomatic here. The sweep kinds are
`Kind::Sweep { .. }` (solid.sweep, `crates/ui-egui/src/dialogs.rs` line 239) and
`Kind::Surface(Surf::Sweep(_))` (surface.sweep, `crates/ui-egui/src/dialogs_surface.rs`
line 195). In both, the Path input is **index 1** and the Profile input is **index 0**
(`solid.sweep`: `Profile`=0, `Path`=1, `Direction`=2, `Rail`=3, `Second Rail`=4;
`surface.sweep`: `Profiles or curves`=0, `Path`=1, `Direction`=2, `Rail`=3, `Second Rail`=4).

A workable shape (adapt it, do not paste it blind):

- In `candidate_on`, when the dialog is a sweep and `self.active == 1` (the Path input), get
  the profile's sketch from `self.inputs[0].items` with
  `crate::dialogs_sweep::profile_sketch(&self.inputs[0].items, s.active_sketch)`.
- If that is `Some(sk)` and the hit is `Hit::SketchCurve { sketch: Some(other), .. }` with
  `other == sk`, return `None` (do not accept this hit) — so the pick falls through.
- The profile's own curve can NEVER be a valid path (proved in point 4 above), so refusing it
  loses nothing and matches what the command would have rejected anyway.

**Guard against over-reach.** This must change the behaviour of a SWEEP's Path pick only.
Do not reorder the viewport's hit list globally. Do not change how other dialogs pick. If you
find yourself editing `viewport.rs`'s hit ordering, you are going too far — stop and use the
`candidate_on` route.

**If the `candidate_on` route does not work**, an acceptable alternative is to make the
sweep's Path input accept the edge but have the sweep's param builder (`dialogs.rs` ~5220
and `dialogs_surface.rs` ~549) prefer an edge pick when one is present in the same input. But
try the `candidate_on` route first — it is the smaller, more principled change.

### What the test proves

`crates/ui-egui/src/sweep_dialog_tests.rs`, `a_sweep_takes_a_body_edge_as_its_path`: a block
whose upright corner edge is the path, the edge picked in the Path input of the sweep dialog
(the profile is picked first, so the profile's sketch IS known), and then the sweep is built
with it. It asserts the Path input holds `Sel::Edge { .. }`, that the dialog closes with no
error, and that the last feature is a `FeatureKind::Sweep`.

## STEP-BY-STEP

### 1. Write the wiring

Edit `crates/ui-egui/src/dialogs.rs` (and, if your approach needs it,
`crates/ui-egui/src/dialogs_sweep.rs`). Keep it small and commented in the style of the file
(English, one line per idea, explaining WHY).

### 2. GREEN

```bash
cd /home/user/solidcraft-wt/issue-2216
export CARGO_TARGET_DIR="$(bash /home/user/.local/share/solidcraft-orch/bin/slot-target-dir.sh --slot 2216)"
export CARGO_BUILD_JOBS="$(bash /home/user/.local/share/solidcraft-orch/bin/cargo-jobs.sh)"
export CARGO_INCREMENTAL=0
systemd-run --user --scope --quiet --unit=sc2216-green -p MemoryMax=24G bash -lc \
  'cd /home/user/solidcraft-wt/issue-2216 && \
   CARGO_TARGET_DIR='"$CARGO_TARGET_DIR"' CARGO_BUILD_JOBS='"$CARGO_BUILD_JOBS"' CARGO_INCREMENTAL=0 \
   cargo test -p solidcraft-ui-egui --profile ci --lib a_sweep_takes_a_body_edge_as_its_path -- --nocapture'
```

Save the output to `/home/user/.local/share/solidcraft-orch/logs/2216-GREEN.log`. It must show
the test passing (`... ok`).

Also run the whole sweep-dialog test file and the doc/engine crates, so a regression is visible:

```bash
cargo test -p solidcraft-ui-egui --profile ci --lib sweep_dialog
cargo test -p solidcraft-doc --profile ci --lib
cargo test -p solidcraft-engine --profile ci --lib
```

**If the test still fails the same way**, the wiring did not take effect: check that the
profile's sketch is actually resolved (`profile_sketch` returns `None` when the profile is not
picked or is in two sketches — in the test the profile IS picked, as `Sel::Profile { sketch,
index: 0 }`, so it must resolve to that sketch).

**If the test fails for a DIFFERENT reason** (a compile error, a panic elsewhere), that is not
a valid GREEN: fix it until the test passes for the right reason.

### 3. The scoped gate

```bash
cd /home/user/solidcraft-wt/issue-2216
export CARGO_TARGET_DIR="$(bash /home/user/.local/share/solidcraft-orch/bin/slot-target-dir.sh --slot 2216)"
cargo fmt --all -- --check
cargo check --workspace --all-targets --profile ci
cargo clippy -D warnings -p solidcraft-doc -p solidcraft-engine -p solidcraft-ui-egui
```

All three must be clean. Use the same `systemd-run --scope -p MemoryMax=24G` wrapper for the
cargo ones (the Hermes cgroup is capped at 4 GiB). `cargo xtask lists` must also be clean if
it is quick — run it and fix nothing about the locale catalogs (the new dialog strings are
plain literals, NOT localized, so there is NO `assets/locales/pending/*.json` to add).

**Do NOT run the full `cargo xtask ci`. Do NOT run the GPU/path tests** (this change is not
render code, so upstream does not run them either).

### 4. Commit

```bash
cd /home/user/solidcraft-wt/issue-2216
git add crates/doc/src/document.rs crates/doc/src/eval.rs crates/doc/src/eval_surface.rs \
        crates/engine/src/cmd/features.rs crates/engine/src/cmd/surface.rs \
        crates/ui-egui/src/dialogs.rs crates/ui-egui/src/dialogs_surface.rs \
        crates/ui-egui/src/dialogs_sweep.rs \
        crates/doc/src/format/pending/sweep-path-on-body-edges.rs
git status --short     # MUST show exactly those 9 paths and nothing else
git commit -m "Sweep: a body's edge can be the path of a sweep (#2216)"
```

Name the files EXPLICITLY. Never `git add -A` (the worktree holds scratch files).
The commit message body: one paragraph, plain literal English, saying what changed and why.

### 5. Push and open the DRAFT PR (this is the CLAIM)

```bash
git push fork fix/issue-2216-sweep-path
```

Use the ABSOLUTE path to `gh` (`/home/user/.local/bin/gh`) — the `gh` on PATH may be a stub
that silently does nothing.

- Repo: `tangency-labs/solidcraft` (the PR goes to upstream; the BRANCH comes from our fork).
- **Title**: `Sweep: a body's edge can be the path of a sweep (#2216)`
- **Draft**: yes. The draft IS the claim.
- **Base**: `main`. **Head**: `vdirienzo:fix/issue-2216-sweep-path`.

Body:

```
Fixes #2216

Changes a default: no

## The problem

A sweep's path could only be the curves of a sketch. The Path input of the Sweep dialog
accepted only curves, so a user who picked an edge of the model — the natural thing to do when
the edge is the shape the profile should follow — got "select the path first" and the sweep was
refused.

## The fix

The Path input of the sweep dialog now accepts a body's edges as well as a sketch's curves.
When the picks are edges of one body, the sweep is built with that chain of edges as its path:
the edges are chained end to end, each one is followed by the curve it is, and the path starts
at the end nearest the profile. The command takes the path as `path_body` (the body) and
`path_edges` (a point on each edge of the chain); a path of sketch curves is unchanged.

A curve of the profile's own sketch is not a valid path — the command has always refused it
("the path curves must be in one other sketch") — so the pick no longer stops on one and now
falls through to the edge under the cursor.

## The test

`crates/ui-egui/src/sweep_dialog_tests.rs`, `a_sweep_takes_a_body_edge_as_its_path`: a block
whose upright corner edge is the path, the edge picked in the Path input of the sweep dialog,
and the sweep built with it.

## Validation

RED (the test fails on the base, because the Path input accepted only curves):
the path took the edge: [SketchCurve { id: "l3", sketch: Some(2) }]

GREEN (the same test passes with this change):
<the exact pass line from 2216-GREEN.log>

## Note for the reviewer

The saved design gains two optional fields, `path_body` and `path_edges`, on a sweep. A design
saved by this build and opened by an older build loses the path.

This PR does not address the inside-corner behaviour the reporter compared against Fusion;
that is a separate request upstream, and it is not closed here.
```

**The `Changes a default:` line must be exactly `Changes a default: no`** — the exact wording
the upstream parser accepts. No code fence, no HTML comment, no backticks. The position does
not matter.

**Validate the body BEFORE opening the PR:**

```bash
bash /home/user/.local/share/solidcraft-loop/bin/pr-defaults-line.sh --body /tmp/2216-body.md
```

It must print `checked: 1 missing: 0` and exit 0. Write the body to `/tmp/2216-body.md`
first with the exact text above.

### 6. Verify the claim AFTER opening the draft

```bash
bash /home/user/.local/share/solidcraft-orch/bin/claim-verify.sh 2216 <your_pr_number>
```

- Exit 0 → the claim is yours.
- Exit 1 → you LOST it (another PR with a LOWER number mentions #2216): `gh pr close` yours,
  push the work to a `wip/issue-2216` branch on the fork so nothing is lost, and report that.
- Exit 2 → unverifiable: do not publish further work on it; report it.

### 7. Report (FIVE things, no more)

1. The commit SHA pushed, and the PR number and URL.
2. The exact `Changes a default:` line used.
3. The exact RED failure line (from `2216-RED.log`).
4. The exact GREEN pass line (from `2216-GREEN.log`).
5. The claim-verify exit code and verdict.

Plus: the exact list of files in the commit (9), and confirmation that the pending-format file
is among them.

If you run out of budget before the PR exists: commit what you have as a wip commit on a
`wip/issue-2216` branch, push it to `fork`, and report the SHA and what is missing.

## HARD RULES (never break)

- Push ONLY to `fork`. Never to upstream. Never force-push `main`.
- Never open a second PR for an issue an open PR already claims.
- **Never touch `crates/kernel/`.** The change only CALLS the kernel's public API
  (`kernel::chain`, `kernel::edge_path`), which already exists upstream and is already used by
  `crates/doc/src/construct.rs` for a body edge's record curve.
- No `unwrap`/`expect`/`panic`/`unsafe` in non-test code.
- One topic and one issue per PR. The regression test stays in the EXISTING file
  `crates/ui-egui/src/sweep_dialog_tests.rs` — do NOT create a new test file, and do NOT
  modify that file (its content is committed and correct).
- Do NOT add the label `approved-for-ci`.
- Do NOT add an `assets/locales/pending/*.json` file (the new strings are plain literals, as
  the neighbouring ones already are).
- The design-format change needs EXACTLY ONE new file in `crates/doc/src/format/pending/` —
  it already exists (`sweep-path-on-body-edges.rs`). Do not add a second one.
- Other worktrees are OFF-LIMITS: do not touch `/home/user/solidcraft` (the main checkout is
  shared), `/home/user/solidcraft-wt/issue-12124`, `/home/user/solidcraft-wt/probe2216`, or any
  other `issue-*` worktree.
- NEVER `pkill`, `killall` or `kill -9` — a subagent once killed a 3.5-hour measurement with
  that. To stop your own build, record the PID and `kill -TERM` only that PID.
- Do NOT restart the Hermes service from inside (it kills this session and every subagent).

## COMPILE DISCIPLINE (the box is shared)

- Take a build slot before compiling:
  `bash /home/user/.local/share/solidcraft-orch/bin/build-slot.sh --take --wait 1800`
  and release it with `--release <the token it printed>` when you are done.
- `export CARGO_TARGET_DIR="$(bash /home/user/.local/share/solidcraft-orch/bin/slot-target-dir.sh --slot 2216)"`
  for EVERY cargo command — never share it, and never use `/home/user/solidcraft/target`.
- `export CARGO_BUILD_JOBS="$(bash /home/user/.local/share/solidcraft-orch/bin/cargo-jobs.sh)"`,
  `export CARGO_INCREMENTAL=0`.
- Wrap cargo in `systemd-run --user --scope --quiet --unit=sc2216 -p MemoryMax=24G bash -lc '...'`
  (the Hermes cgroup is capped at 4 GiB and a plain cargo build gets OOM-killed).
- The target dir for slot 2216 is already WARM (the RED run built it) — the GREEN run should
  be much faster than the RED's 19m32s.
