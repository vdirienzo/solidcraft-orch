# Brief — #12125: a hidden sketch's auto-projected outline is still drawn

## What is ALREADY DONE (do not redo it)

The reporter's design is on this machine and the mechanism is already located. Do NOT explore
the repo looking for the bug.

### The issue

Upstream issue **#12125**, "Hidden sketch on a body face (automatic face projection) keeps
drawing its outline". Labels: `area:sketch`, `needs-triage`. **No comments** — no maintainer
triage, no bot claim. `claim-verify.sh 12125` returned **0** (the claim is free) and no open PR
mentions it.

### The reporter's own words (from the issue body)

> **What happens:** In the attached design, Sketch8 is hidden (eye off in the browser), but its
> purple outline stays drawn on Body3's top face. Hiding it again changes nothing. Rolling the
> timeline back to before Sketch8 removes the outline, so the outline is Sketch8's. Once a
> feature uses the sketch, the outline goes.
>
> **Difference from a sketch that hides fine:** Sketch7 is also unused and hides correctly. It
> sits on a construction plane with a manual projection. Sketch8 sits on a body face, and its
> curves come from the automatic face projection (`auto_face: true`). So the auto-projected
> outline of an unused sketch seems to be drawn whatever the sketch's visibility.
>
> **Steps:** 1. Open the attached design. 2. Look at the top face of Body3: Sketch8's outline
> is drawn though Sketch8 is hidden.
>
> **File:** MonitorRiser.zip (the design; opens on the official rc.2).

### The design is already on this machine

```
/home/user/.local/share/solidcraft-orch/repro/MonitorRiser-12125.zip
/home/user/.local/share/solidcraft-orch/repro/m12125/MonitorRiser.sc   (extracted)
```

It is the SAME design as #12124 (both issues are the reporter's `MonitorRiser`), so the
extracted `document.json` under `/home/user/.local/share/solidcraft-orch/repro/m12124/x/` is
the same document. Its format is `solidcraft/50`, the current upstream format, so it loads with
no migration.

**The two sketches the reporter contrasts** (from the extracted document.json):
- `Sketch7` — plane is a **construction** plane (`{"type": "construction", "feature": 21}`),
  its link has a **manual** projection with `face_name: "F20:bottom#2"`. It hides correctly.
- `Sketch8` — plane is a **face** (`{"type": "face", ...}`), its link has
  **`auto_face: true`**. It does NOT hide.

### Where the decision is made (verified upstream — do not go looking)

**`crates/engine/src/view.rs:1113` — `pub fn sketch_shown(s: &Session, id: u64) -> bool`:**

```rust
/// Is a sketch drawn? The sketch being edited always is; otherwise not in a hidden component,
/// Sketches folder or group (even one shown on its own). The sketch immediately before a
/// rollback marker is shown regardless of its individual visibility; other hidden sketches, and
/// ones used by a feature unless shown on their own, retain their stored visibility.
pub fn sketch_shown(s: &Session, id: u64) -> bool {
    let v = &s.visibility;
    if s.active_sketch == Some(id) || s.feature_edit_sketch == Some(id) {
        return true;
    }
    if !s.feature_placement_visible(id) || s.feature_folder_hidden(id, "sketches") {
        return false;
    }
    if s.doc
        .marker
        .and_then(|position| position.checked_sub(1))
        .and_then(|index| s.doc.features.get(index))
        .is_some_and(|f| f.id == id && matches!(f.kind, solidcraft_doc::FeatureKind::Sketch { .. }))
    {
        return true;
    }
    if v.hidden_sketches.contains(&id) {
        return false;
    }
    v.shown_sketches.contains(&id) || !sketch_consumed(s, id)
}
```

Note the order: the **rollback-marker** check comes BEFORE the `hidden_sketches` check. The
reporter said "Rolling the timeline back to before Sketch8 removes the outline" — that is the
marker branch behaving as documented, and is NOT the bug. The bug is that the hidden sketch is
drawn at all.

Other relevant code:
- `crates/engine/src/occurrences.rs:841` — `feature_placement_visible(id)`.
- `crates/engine/src/view.rs:615` — `sketch_curve_visible(sk, i)`: a curve with a link
  (`c.link.is_some()`) is **projected reference geometry** and is drawn unless
  `sk.view.hide_projected`. That is the "purple outline" — the auto-projected curves of
  `Sketch8` are linked curves.
- `crates/engine/src/view.rs:591` — the wire loop that draws them:
  `for w in sk.wires.iter().filter(|w| !w.fit.is_empty() || !sk.view.hide_projected)`.
- `crates/doc/src/project.rs:1030-1072` — the `auto_face` branch of the projection's
  resolution: `l.auto_face` makes the link resolve against the face's ANCHOR
  (`resolve_anchored_face`), rather than by name.

**The likely root cause to check first:** the auto-projected outline of `Sketch8` is drawn
even though `sketch_shown(Sketch8)` is false, because the projected curves are drawn through a
different path than the sketch's own curves — the auto-face projection's geometry is resolved
from the face's anchor (`auto_face`) and drawn as part of the FACE's projected reference
geometry, not as part of the sketch. So hiding the sketch never reaches it.

**Verify this before fixing it.** It is the difference between a one-line fix in the right
place and a wrong fix. Read `crates/engine/src/view.rs` around lines 140-160, 555-600 and
1113-1135, and find the call path that draws `Sketch8`'s projected wires. Then find out WHY
the sketch's visibility is not consulted on that path.

### The fix must be

- In the **engine** (`crates/engine/`), not in the UI and NOT in `crates/render/`.
- Small and principled: a hidden sketch's auto-projected outline is not drawn, exactly like a
  hidden sketch's own curves are not drawn.
- It must NOT change what a VISIBLE sketch does, and must NOT change what happens to a sketch
  consumed by a feature (the reporter says "Once a feature uses the sketch, the outline goes",
  and that behaviour is correct and must stay).

## YOUR WORKTREE

- Worktree: `/home/user/solidcraft-wt/issue-12125` (ALREADY EXISTS, branch
  `fix/issue-12125-hidden-sketch-outline`, at `origin/main` = `6029a38ea`).
- `origin` is UPSTREAM (tangency-labs/solidcraft). `fork` is OURS (vdirienzo/solidcraft).
  **Push ONLY to `fork`.**
- **Other worktrees are OFF-LIMITS.** Do not touch `/home/user/solidcraft` (the main checkout
  is shared and drifting), `/home/user/solidcraft-wt/issue-2216`,
  `/home/user/solidcraft-wt/issue-12124`, `/home/user/solidcraft-wt/probe2216`, or any other
  `issue-*` worktree. Never `git push origin`. Never force-push `main`.

## ONE ARTEFACT: the GREEN commit + the draft PR

Your single deliverable is **one commit that makes a RED test pass, pushed to `fork`, plus a
draft PR claiming #12125**.

### Step 1 — RED: a regression test that fails on the current base

The regression test goes in the area's **EXISTING** test file. The area is "what is drawn", and
the existing files are:

```
crates/engine/src/view_display_tests.rs
```

Read it first — it already has tests that toggle `sk.view.hide_projected` and check what is
drawn, so it has the helpers and the shape of the assertions you need.

**Do NOT create a new test file.** AGENTS.md: "A regression test goes in the area's existing
test file, never a per-bug file."

The test must show that **a hidden sketch with an `auto_face` projected link has no projected
curve drawn**, while the same sketch when shown does. Build the model in the test:

- a body,
- a sketch on one of its faces with a link whose source is that face and whose `auto_face` is
  true (this is what `crates/engine/src/cmd/sketch_face_tests.rs` and
  `crates/engine/src/cmd/sketch_project.rs` exercise — read them for how such a sketch is
  created),
- hide the sketch (`s.visibility.hidden_sketches.push(id)` — the same field
  `crates/engine/src/cmd/browser.rs:700` writes),
- assert that the projected curve is NOT among the drawn curves, while the sketch's own
  (non-projected) curves behave as before.

Use the drawing helpers the existing test file uses (read `view_display_tests.rs` for how it
asks "what is drawn").

**If the test PASSES on the base, STOP** — the bug is already fixed upstream, no pull request
is owed. Report that and open NO PR.

**If the test fails for the wrong reason** (a compile error, a panic, a missing API), that is
NOT a valid RED: fix the test's setup until the failure is "the auto-projected outline of the
hidden sketch is still drawn".

**If you cannot reproduce it faithfully**, STOP, report that, and open NO PR. That is a good
outcome, not a failure. Never invent a fix to have something to show.

Save the RED output to `/home/user/.local/share/solidcraft-orch/logs/12125-RED.log`.

### Step 2 — GREEN: fix the cause

Fix it in the smallest place that is actually the cause, and make it consistent with how the
rest of the code answers "is this drawn?": `sketch_shown` and `sketch_curve_visible` are the
two answers the drawing code already uses, and drawing and picking are supposed to share one
answer so they cannot drift.

Run the test again; it must pass. Save the output to
`/home/user/.local/share/solidcraft-orch/logs/12125-GREEN.log`.

Also run the area's tests and the engine's, so a regression is visible:

```bash
cargo test -p solidcraft-engine --profile ci --lib view_display
cargo test -p solidcraft-engine --profile ci --lib
```

**Hard constraint: NEVER touch `crates/kernel/`.** This is a drawing/visibility decision in
the engine.

**Another hard constraint: do not touch `crates/render/`.** The Render workspace is the
maintainer's other area and is moving fast; this fix belongs in the engine.

Then check the gate for the lists:
```bash
cargo xtask lists
```
It must be clean. If you add a new user-visible string, it goes in
`assets/locales/pending/<slug>.json` — but a visibility fix usually needs no new string, so
check before adding one.

### Step 3 — commit

```bash
cd /home/user/solidcraft-wt/issue-12125
git add <the files you changed, named explicitly>
git status --short          # MUST show only your files
git commit -m "Sketch: a hidden sketch's projected outline is not drawn (#12125)"
```

Name the files EXPLICITLY — never `git add -A` in a worktree that holds scratch files.

Commit message body: one paragraph saying what changed and why, in plain literal English.

### Step 4 — push and open the DRAFT PR (this is the CLAIM)

```bash
git push fork fix/issue-12125-hidden-sketch-outline
```

Use the ABSOLUTE path to `gh` (`/home/user/.local/bin/gh`) — the `gh` on PATH may be a stub
that silently does nothing.

- Repo: `tangency-labs/solidcraft` (the PR goes to upstream; the BRANCH comes from our fork).
- **Title**: `Sketch: a hidden sketch's projected outline is not drawn (#12125)`
- **Draft**: yes. The draft IS the claim.
- **Base**: `main`. **Head**: `vdirienzo:fix/issue-12125-hidden-sketch-outline`.

Body — this structure, filling in the measured facts:

```
Fixes #12125

Changes a default: no

## The problem

A sketch on a body face, whose curves come from the automatic projection of that face, kept
its outline drawn even when the sketch was hidden. Hiding the sketch did nothing, while a
sketch on a construction plane with a manual projection hid correctly.

## The fix

<what changed, in plain words: which drawing path ignored the sketch's visibility and what
it now asks instead>

## The test

`crates/engine/src/view_display_tests.rs`, `<the test name>`: <the model it builds and what it
asserts>.

## Validation

RED (the test fails on the base):
<the exact failure line from 12125-RED.log>

GREEN (the same test passes with this change):
<the exact pass line from 12125-GREEN.log>

## Note for the reviewer

<if relevant: say what stays the same — a visible sketch draws as before, and a sketch used by
a feature keeps its outline>
```

**The `Changes a default:` line must be exactly `Changes a default: no`** — the exact wording
the upstream parser accepts. Do NOT put it in a code fence, do NOT comment it out with HTML, do
NOT put backticks around it. The position does not matter.

**Validate the body against the upstream parser BEFORE opening the PR:**

```bash
cat > /tmp/12125-body.md <<'EOF'
<the full body text>
EOF
bash /home/user/.local/share/solidcraft-loop/bin/pr-defaults-line.sh --body /tmp/12125-body.md
```

It must print `checked: 1 missing: 0` and exit 0.

### Step 5 — verify the claim AFTER opening the draft

```bash
bash /home/user/.local/share/solidcraft-orch/bin/claim-verify.sh 12125 <your_pr_number>
```

- Exit 0 → the claim is yours. Continue.
- Exit 1 → you LOST the claim (another PR with a LOWER number mentions #12125). Then
  `gh pr close <your_pr_number>`, push your work to a `wip` branch on the fork so nothing is
  lost, and report that you lost the claim and what you saved.
- Exit 2 → the claim could not be verified. Do NOT publish further work on it; report it.

### Step 6 — report (FIVE things, no more)

1. The commit SHA you pushed, and the PR number and URL.
2. The exact `Changes a default:` line you used.
3. The RED output: the exact failing assertion/message line from `12125-RED.log`.
4. The GREEN output: the exact pass line from `12125-GREEN.log`.
5. The verdict of `claim-verify.sh` after opening the PR, with its exit code.

And, in one extra sentence: **the root cause you found** — which drawing path ignored the
sketch's visibility — so the maintainer knows where the fix sits.

If you run out of budget before the PR exists: commit what you have as a wip commit on a
`wip/issue-12125` branch, push it to `fork`, and report the SHA and what is missing. A `wip`
commit on the fork is recoverable; an uncommitted tree is lost work.

## HARD RULES (never break)

- Push ONLY to `fork`. Never to upstream. Never force-push `main`.
- Never open a second PR for an issue an open PR already claims.
- **Never touch `crates/kernel/`. Never touch `crates/render/`.**
- No `unwrap`/`expect`/`panic`/`unsafe` in non-test code. `cargo clippy -D warnings` must pass
  on the touched packages.
- One topic and one issue per PR. The regression test goes in the EXISTING file
  `crates/engine/src/view_display_tests.rs` — do NOT create a new test file.
- Do NOT add the label `approved-for-ci`.
- This change is NOT a change to what a design file SAVES, so it needs NO file in
  `crates/doc/src/format/pending/`. Only add one if your fix changes a saved field (unlikely
  here) — and then it is exactly ONE file.
- Real evidence for observable behaviour: **this change IS observable** (an outline disappears
  from the view), so upstream expects a screenshot or a short recording that you captured
  yourself. Read `skills/solidcraft-reporting/SKILL.md` for how the evidence is taken in this
  repo, and follow it. **Never fabricate a screenshot.** If you cannot capture real evidence,
  say so plainly in the PR body and in your report — do not invent one.

## COMPILE DISCIPLINE (the box is shared)

- Take a build slot before compiling:
  `bash /home/user/.local/share/solidcraft-orch/bin/build-slot.sh --take --wait 1800`
  and release it with `--release <the token it printed>` when you are done.
- `export CARGO_TARGET_DIR="$(bash /home/user/.local/share/solidcraft-orch/bin/slot-target-dir.sh --slot 12125)"`
  for EVERY cargo command — never share it with another agent, and never use
  `/home/user/solidcraft/target`.
- `export CARGO_BUILD_JOBS="$(bash /home/user/.local/share/solidcraft-orch/bin/cargo-jobs.sh)"`,
  `export CARGO_INCREMENTAL=0`.
- Wrap cargo in `systemd-run --user --scope --quiet --unit=sc12125 -p MemoryMax=24G bash -lc '...'`
  (the Hermes cgroup is capped at 4 GiB and a plain cargo build gets OOM-killed).
- NEVER `pkill`, `killall` or `kill -9` — a subagent once killed a 3.5-hour measurement with
  that. To stop your own build, record the PID and `kill -TERM` only that PID.
- Do NOT run the full `cargo xtask ci` and do NOT run the GPU/path tests (this change is not
  render code, so upstream does not run them either).
- Do NOT restart the Hermes service from inside (it kills this session and every subagent).

## FILES YOU MAY NEED TO READ (and nothing else)

- `crates/engine/src/view.rs` — lines 140-160, 555-600, 1113-1135 (the drawing of the
  projected wires and `sketch_shown`).
- `crates/engine/src/view_display_tests.rs` — the area's existing test file.
- `crates/engine/src/occurrences.rs` — `feature_placement_visible` (line 841).
- `crates/doc/src/project.rs` — lines 1030-1072 (the `auto_face` branch).
- `crates/engine/src/cmd/sketch_face_tests.rs` and `crates/engine/src/cmd/sketch_project.rs` —
  how a sketch on a face with an automatic projection is created.
- `skills/solidcraft-reporting/SKILL.md` — how the evidence is taken.
- `/home/user/.local/share/solidcraft-orch/repro/m12125/MonitorRiser.sc` — the reporter's design.

Read what you need to fix the bug. Do not read the whole repo.
