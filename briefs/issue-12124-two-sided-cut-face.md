# Brief — #12124: a sketch on a face of a two-sided cut keeps its attachment

## What is ALREADY DONE (do not redo it)

The diagnosis is done. Do NOT explore the repo looking for the bug. The reproduction, the
failing command and the design file are all given below.

### The issue

Upstream issue **#12124**, "Create Sketch on a face of a Two Sides extrude cut: 'this face can't
keep an attachment'". Labels: `bug`, `area:sketch`, `needs-triage`. It has **no comments** — no
maintainer triage, no bot claim. `claim-verify.sh 12124` returned **0** (the claim is free) and
no open PR mentions it.

### The reporter's own words (from the issue body)

> ### Actual behavior
> Create Sketch on a face of a Two Sides extrude cut fails with "this face can't keep an
> attachment: its history can't tell it apart from other faces".
>
> ### Steps to reproduce
> 1. Open the attached design (`MonitorRiser.sc`).
> 2. Extrude8 is a cut with Direction Two Sides (-13.2 mm and -5 mm), two profiles from Sketch6,
>    targets Body2 and Body3.
> 3. Click a face of the cut result in Body3.
> 4. Create Sketch. It fails.
>
> A sketch that projects the same face (Sketch7) records it as `F20:bottom#2`, so the second side
> seems to give its faces a duplicate history name.
>
> ### SolidCraft version and OS
> 0.40.0-rc.2, Windows 11
>
> A plain box with the same two-sided cut (one or two profiles, one or two targets) sketches
> fine, so the body matters too: Body3 is an offset-boundary extrude with rounded corners.

### The reproduction is LITERAL — use these exact commands

The reporter's design file is already on this machine:

```
/home/user/.local/share/solidcraft-orch/repro/MonitorRiser-12124.zip   (the .sc inside it)
/home/user/.local/share/solidcraft-orch/repro/m12124/MonitorRiser.sc    (already extracted)
```

The reporter gave the exact failing command in the issue body:

```json
{"command":"sketch.create","params":{"plane":{"face":[9.45,-2.719,12.2947],"body":"Body3","index":10}}}
```

So the whole reproduction is:

```bash
cd /home/user/solidcraft-wt/issue-12124
cat > /tmp/12124-repro.json <<'EOF'
[{"command":"sketch.create","params":{"plane":{"face":[9.45,-2.719,12.2947],"body":"Body3","index":10}}}]
EOF

export CARGO_TARGET_DIR="$(bash /home/user/.local/share/solidcraft-orch/bin/slot-target-dir.sh --slot 12124)"
# build the CLI once, then:
cargo run --profile ci --bin solidcraft-cli -- \
  run /tmp/12124-repro.json --in /home/user/.local/share/solidcraft-orch/repro/m12124/MonitorRiser.sc
```

The expected failure (this is the message the issue reports):

```
this face can't keep an attachment: its history can't tell it apart from other faces
(an edit reshaped it, or more than one face could claim its name).
Pick another face, or use a fixed plane here (fixed:true), which won't follow later changes to the face
```

**Where that message comes from** (verified upstream, do not go looking):

- `crates/engine/src/cmd/sketch_face.rs:220` — the `bad(cmd, ...)` call that emits it.
- It is reached when `doc.capture_face_anchor(body, index, &plane, &path, s.active_component,
  &author_path)` returns `Err(DocError::Invalid(..))` whose message is one of
  `"this face has no exact planar source; choose a fixed plane instead"` or
  `"this face has no supported construction certificate; choose a fixed plane instead"`.
- `capture_face_anchor` lives in the **doc** crate (`crates/doc/`), in the code that resolves a
  face's *certificate* — the record of which face of which feature this face is — into an anchor
  the sketch can keep. The naming/certificate code is `crates/doc/src/history_names.rs`
  (functions `from_origins`, `merged`, `common_piece`, `piece_name`, `split_piece`,
  `tie_number`) and the certificate kinds are in `crates/doc/src/` as `FaceOrigin` variants
  (`Face`, `Edge`, `Offset`, `Profile`, `Cap`).

**The root cause the reporter already identified**: a cut with **two sides** (the `distance2`
field of `FeatureKind::Extrude`) produces faces whose *history names collide* — the reporter
observed `F20:bottom#2` in the design, i.e. two faces of the same body ended up claiming one
name with a `#2` tie number. When two faces claim the same name, the certificate cannot say
which one the user picked, and `capture_face_anchor` refuses.

**Do NOT assume that is the whole story.** The reporter also says a plain box with the same
two-sided cut works, so the body matters (Body3 is an offset-boundary extrude with rounded
corners). Your job is to find the ACTUAL cause in the code and fix that. If the cause turns out
to be somewhere else, fix it where it is.

**A critical warning about scope**: our own open PR **#11359** ("Project: a nested face name is
written in parentheses so it reads one way") fixes upstream issue **#5857** — a *different* name
defect (a nested name `F?:blend:F1:+x|F1:+z#[…]` whose `#[…]` could point at different faces).
Both touch face naming. They must NOT collide:

- If your fix touches the *syntax* of a persistent name (the parentheses, the `#[…]`
  qualifier, the `#N` tie number) — **STOP and report**. That is #11359's territory and it is
  already open. Report what you found instead of writing the fix.
- If your fix is in the *certificate resolution* / *anchor capture* / the *two-sided extrude's
  face origins* — that is yours and it is disjoint from #11359.

## YOUR WORKTREE

- Worktree: `/home/user/solidcraft-wt/issue-12124` (ALREADY EXISTS, on branch
  `fix/issue-12124-face-attach-two-sided-cut`, at `origin/main` = `6d2465b52`).
- `origin` is UPSTREAM (tangency-labs/solidcraft). `fork` is OURS (vdirienzo/solidcraft).
  **Push ONLY to `fork`.**
- **Other worktrees are OFF-LIMITS.** Do not touch `/home/user/solidcraft` (the main checkout is
  shared), `/home/user/solidcraft-wt/issue-2216`, `/home/user/solidcraft-wt/probe2216`, or any
  other `issue-*` worktree. Never `git push origin`. Never force-push `main`.

## ONE ARTEFACT: the GREEN commit + the draft PR

Your single deliverable is **one commit that makes the RED test pass, pushed to `fork`, plus a
draft PR claiming #12124**.

### Step 1 — RED: a regression test that fails on the current base

The regression test goes in the area's **EXISTING** test file. The area is face naming and
anchoring, and the existing file is:

```
crates/engine/src/naming_history_tests.rs
```

It already has the helpers you need: `run(s, id, params)`, `id(s, name)`, `error(s, name)`,
`names(s, body)`, `block(s)`, `slot(s, floor)`, `body_at(s, p)`. Read it before writing.

**Do NOT create a new test file.** AGENTS.md: "A regression test goes in the area's existing
test file, never a per-bug file."

Build the test so it reproduces the ISSUE with the SMALLEST model that still shows the bug. The
reporter says a plain box does NOT show it, so the model needs the parts that matter:
a body that is an **offset-boundary extrude with rounded corners** and a **two-sided cut**
(`distance` + `distance2`) on it, then a `sketch.create` on one of the cut's faces.

Two ways to get there — use whichever lands first:

(a) **Replay the reporter's design.** The CLI command above reproduces it. Then read
`/home/user/.local/share/solidcraft-orch/repro/m12124/x/document.json` (already extracted) and
shrink it: the design has 23 features; find the smallest subset that still fails. This is the
most faithful route and it is the one to prefer.

(b) **Rebuild the model with commands** in the test, using the same shape:
`solid.extrude` with `profiles: {"type":"offset_boundaries", ...}` (that is the offset-boundary
extrude), rounded corners via `solid.fillet`, then `solid.extrude` with `operation: "cut"`,
`extent: {"distance": ..., "distance2": ...}` (the two-sided cut) on it, then `sketch.create`
with `plane: {"face": [x,y,z], "body": "<body>", "index": N}`.

Whichever route, the RED test must fail **for the reported reason**: the `sketch.create` must
fail with the "this face can't keep an attachment" message. Assert on that message, e.g. with
the existing `error(s, name)` helper.

**If you cannot reproduce it faithfully, STOP and report that, and open NO PR.** That is a good
outcome, not a failure. Never invent a fix to have something to show. A test that fails for a
different reason (a compile error, a panic, a missing API) is NOT a valid RED — fix the test's
setup until the failure is the reported one.

Save the RED output to `/home/user/.local/share/solidcraft-orch/logs/12124-RED.log`.

### Step 2 — GREEN: fix the cause

Fix it in the smallest place that is actually the cause. The likely places, in order:

- `crates/doc/src/history_names.rs` — how a face's name and its origins are derived
  (`from_origins`, `merged`, `common_piece`, `piece_name`). A two-sided cut makes faces whose
  origins point at the same piece, and the merge/common-piece logic then collapses two distinct
  faces onto one name.
- `crates/doc/src/` — where `capture_face_anchor` resolves a certificate into an anchor, and
  where the certificate kinds (`FaceOrigin`) are produced for an extrude's cut faces.
- `crates/doc/src/` — where an extrude's `distance2` (the second side) produces the faces of the
  second side; if the second side's faces get the same origin/certificate as the first side's,
  that is the bug.

Read `crates/doc/src/history_names.rs` and the `capture_face_anchor` implementation before
deciding. The fix must be small and principled, not a special case for "two-sided".

**Hard constraint: NEVER touch `crates/kernel/`.** This is a naming/certificate problem in the
doc crate; if you believe the fix belongs in the kernel, STOP and report that instead.

**Another hard constraint: do not change the SYNTAX of a persistent face name.** See the warning
above about #11359. If the only fix you can see is a name-syntax change, report it.

Then run the test again; it must pass. Save the output to
`/home/user/.local/share/solidcraft-orch/logs/12124-GREEN.log`.

Also run the whole area's test file, so a regression in the area is visible:

```bash
cargo test -p solidcraft-engine --profile ci --lib naming_history
```

and the doc crate's tests:

```bash
cargo test -p solidcraft-doc --profile ci --lib
```

**Compile discipline (the box is shared, 16 cores, other jobs run here):**
- Take a build slot before compiling: `bash /home/user/.local/share/solidcraft-orch/bin/build-slot.sh --take --wait 1800`
  and release it with `--release <token>` when done.
- `export CARGO_BUILD_JOBS="$(bash /home/user/.local/share/solidcraft-orch/bin/cargo-jobs.sh)"`
  and `export CARGO_INCREMENTAL=0`.
- The Hermes cgroup is capped at 4 GiB; a plain cargo build gets OOM-killed. Use
  `systemd-run --user --scope --quiet --unit=sc12124 -p MemoryMax=24G bash -lc '...'`.
- NEVER `pkill`, `killall` or `kill -9`. To stop your own build, record the PID and `kill -TERM`
  only that PID.
- Do NOT run the full `cargo xtask ci` and do NOT run the GPU/path tests.
- Keep the same `CARGO_TARGET_DIR` for every command in this worktree.

### Step 3 — commit

```bash
cd /home/user/solidcraft-wt/issue-12124
git add <the files you changed, named explicitly>
git status --short          # MUST show only your files
git commit -m "Sketch: a face of a two-sided cut keeps its attachment (#12124)"
```

Name the files EXPLICITLY — never `git add -A` in a worktree that holds scratch files.

Commit message body: one paragraph saying what changed and why, in plain literal English.

### Step 4 — push and open the DRAFT PR (this is the CLAIM)

```bash
git push fork fix/issue-12124-face-attach-two-sided-cut
```

Then open the draft PR. Use the ABSOLUTE path to `gh` (`/home/user/.local/bin/gh`) — the `gh` on
PATH may be a stub that silently does nothing.

- Repo: `tangency-labs/solidcraft` (the PR goes to upstream; the BRANCH comes from our fork).
- **Title**: `Sketch: a face of a two-sided cut keeps its attachment (#12124)`
- **Draft**: yes. The draft IS the claim.
- **Base**: `main`. **Head**: `vdirienzo:fix/issue-12124-face-attach-two-sided-cut`.

Body — this structure, filling in the measured facts:

```
Fixes #12124

Changes a default: no

## The problem

A sketch made on a face of a cut with two sides could not keep its attachment: SolidCraft
refused with "this face can't keep an attachment: its history can't tell it apart from other
faces".

<one or two sentences on the cause, in plain words: what the two-sided cut does to the face's
history that makes two faces claim one name>

## The fix

<what changed, in plain words: which decision was wrong and how it is decided now>

## The test

`crates/engine/src/naming_history_tests.rs`, `<the test name>`: <the model it builds and what it
asserts>.

## Validation

RED (the test fails on the base):
<the exact failure line from 12124-RED.log>

GREEN (the same test passes with this change):
<the exact pass line from 12124-GREEN.log>

## Note for the reviewer

The face history of a cut with two sides had two faces claiming one name, so the sketch could
not say which face it was attached to. This change decides which face a sketch on such a face
is attached to; it does not change the syntax of a persistent face name.
```

**The `Changes a default:` line must be exactly `Changes a default: no`** — that is the exact
wording the upstream parser accepts. Do NOT put it in a code fence, do NOT comment it out with
HTML, do NOT put backticks around it. The position does not matter.

**Validate the body against the upstream parser BEFORE opening the PR:**

```bash
cat > /tmp/12124-body.md <<'EOF'
<the full body text>
EOF
bash /home/user/.local/share/solidcraft-loop/bin/pr-defaults-line.sh --body /tmp/12124-body.md
```

It must print `checked: 1 missing: 0` and exit 0.

### Step 5 — verify the claim AFTER opening the draft

```bash
bash /home/user/.local/share/solidcraft-orch/bin/claim-verify.sh 12124 <your_pr_number>
```

- Exit 0 → the claim is yours. Continue.
- Exit 1 → you LOST the claim (another PR with a LOWER number mentions #12124). Then
  `gh pr close <your_pr_number>`, push your work to a `wip` branch on the fork so nothing is
  lost, and report that you lost the claim and what you saved.
- Exit 2 → the claim could not be verified. Do NOT publish further work on it; report it.

### Step 6 — report (FIVE things, no more)

1. The commit SHA you pushed, and the PR number and URL.
2. The exact `Changes a default:` line you used.
3. The RED output: the exact failing assertion/message line from `12124-RED.log`.
4. The GREEN output: the exact pass line from `12124-GREEN.log`.
5. The verdict of `claim-verify.sh` after opening the PR, with its exit code.

And, in one extra sentence: **the root cause you found, and whether it touched the name
SYNTAX** (it must not) — the maintainer needs to know it is disjoint from #11359.

If you run out of budget before the PR exists: commit what you have as
`wip(#12124): <what exists>` on a `wip/issue-12124` branch, push it to `fork`, and report the
SHA and what is missing. A `wip` commit on the fork is recoverable; an uncommitted tree is lost
work.

## HARD RULES (never break)

- Push ONLY to `fork`. Never to upstream. Never force-push `main`.
- Never open a second PR for an issue an open PR already claims.
- **Never touch `crates/kernel/`.**
- **Never change the syntax of a persistent face name** (see the #11359 warning).
- No `unwrap`/`expect`/`panic`/`unsafe` in non-test code. `cargo clippy -D warnings` must pass
  on the touched packages.
- One topic and one issue per PR. The regression test goes in
  `crates/engine/src/naming_history_tests.rs` — do NOT create a new test file.
- Do NOT add the label `approved-for-ci`.
- The new/edited message strings: check whether the message you touch is in
  `assets/locales/*.json`. If you add a NEW user-visible string, it goes in
  `assets/locales/pending/<slug>.json` (one file, `{"<locale>": {"<id>": "<text>"}}`). If you
  only change an existing English literal that is already NOT localized, do not add a locale
  file. Run `cargo xtask lists` to check.
- A change to what a design file SAVES is a design-format change: it needs exactly ONE new file
  in `crates/doc/src/format/pending/`. If your fix changes a saved field (for example a new
  name or a new certificate), you MUST add that file. Read
  `crates/doc/src/format/pending/README.md` and
  `crates/doc/src/format/pending/bridged-counterbore.rs` for the shape. If no rewrite step for
  old designs is needed (likely), the file is a NOTE ONLY, exactly like
  `bridged-counterbore.rs` — no `pub fn step`.
- Real evidence for observable behaviour: this change is about whether a sketch keeps its
  attachment, which is not visible in a picture. A screenshot is NOT required. Never fabricate
  one.

## FILES YOU MAY NEED TO READ (and nothing else)

- `crates/engine/src/naming_history_tests.rs` — the area's existing test file.
- `crates/doc/src/history_names.rs` — how a face's name and origins are derived.
- `crates/engine/src/cmd/sketch_face.rs` (around line 195-240) — where the message is emitted.
- The `capture_face_anchor` implementation in `crates/doc/src/`.
- `crates/doc/src/format/pending/README.md` and `bridged-counterbore.rs` — the pending-format
  shape.
- `/home/user/.local/share/solidcraft-orch/repro/m12124/x/document.json` — the reporter's design.

Read what you need to fix the bug. Do not read the whole repo.
