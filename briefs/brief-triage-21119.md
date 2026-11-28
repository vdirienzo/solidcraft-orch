# Brief: triage and claim issue #21119 (cycle 4)

You are the triage agent of the SolidCraft orchestrator. Nobody is watching and you cannot ask
questions. Your job: prove that #21119 still happens on the current `main`, claim it, and write the
brief that the implementer agent will follow. You do NOT implement the fix.

## The machine and the rules (they are the law)

- 12 cores, 15 GB RAM, no swap. One heavy build at a time. Use `nice -n 19` and `--profile ci`.
- Around a big build take the heavy token:
  `bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/slot-lock.sh --heavy --take --wait 3600`
  and release it with `bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/slot-lock.sh --heavy --release`
  Another job (a local gate run) may hold it for a while: wait for it, do not build in parallel.
- Your scratch target dir (build the CLI here, not in a slot's):
  `/home/user/.local/share/solidcraft-orch/targets/triage`
- Push ONLY to the fork (`fork` = vdirienzo/solidcraft). NEVER push to `origin`.
- English in everything public.
- The orchestrator's tools are in `/home/user/Projects/solidcraft-orch/solidcraft-orch` (bin/).
  The upstream checkout is `/home/user/Projects/solidcraft-orch` (remotes: `origin` = upstream,
  `fork` = ours).
- NEVER merge, never add or ask for `approved-for-ci` or `ready to merge`, never comment on the
  issue or the PR, never open more than one PR, and do NOT mark the PR ready.

## The issue

**#21119 — "Sketch: a radius dimension on an arc drawn as an exact half circle is called redundant
while the sketch still has 1 degree of freedom"**
https://github.com/tangency-labs/solidcraft/issues/21119
Labels: `area:sketch`, `needs-triage`. The claim from PR #21502 was released, so it should be
free — but VERIFY it with `claim-verify.sh`, do not assume it.

What the scout found (read the issue yourself and confirm):

- The symptom: the dimension reply says `"driven": true, "redundant": true, "measured": 10.0`
  while `"sketch": {"dof": 1}`. With an explicit value the command is refused with
  `that would over-constrain the sketch (conflicts with k1, k2, k3, k5)`
  (that string is raised at `crates/engine/src/cmd/sketch.rs:698`).
- The cause, traced by the maintainer (WilliamHJKL) in the issue: for an exact half circle the arc
  centre sits at h = 0 on the chord, so dr/dh = h/r = 0 and the radius row is zero;
  `classify_rows` (`crates/sketch/src/redundancy.rs:109`, reached from `determined_by` at
  `crates/sketch/src/redundancy.rs:215`, which `crates/engine/src/cmd/sketch.rs:3352` and `:3464`
  call) sees a rank that does not grow and calls the dimension redundant, although the sketch still
  has 1 degree of freedom.
- The repro is a script of pure sketch commands (no UI):
  `sketch.create`, `sketch.line` (0,0)–(20,0), `sketch.arc.three_point` (20,0)–(0,0) through
  (10,10), `sketch.constraint.horizontal_vertical`, `sketch.dimension` 20 mm, then
  `sketch.dimension` of type radius.
- The boundary is exact: with the third point at (9,10) instead of (10,10) the same script gives a
  driving dimension (10.000125 mm, dof 0).
- The pattern to follow for the fix is `crates/sketch/src/solver.rs:2938` (`nudge_line_angles`),
  which nudges a wrapped angle off its singularity before Newton.
- Risk: medium — the solver change is delicate. The fix must (a) nudge a free arc centre off its
  chord before Newton, and (b) judge redundancy at a slightly moved copy of the variables, so a
  constraint that is only dependent at h = 0 is not called redundant. Genuine redundancy (two
  vertical constraints on one line) must still be detected, and the nudge must not move the
  solved geometry.

## What to do

### 1. Prove it still happens on the current `main`

- Read the issue and its comments. `gh issue view <N> -R tangency-labs/solidcraft` works, but
  `gh issue view --comments` does NOT work on this repo (GraphQL "Projects (classic)"): read the
  comments with `gh api repos/tangency-labs/solidcraft/issues/<N>/comments`.
- Build the CLI in your scratch target dir (`apps/solidcraft-cli`, `--profile ci`, `nice -n 19`).
- Reproduce the failure headlessly with a JSON script:
  `solidcraft-cli run repro.json --results` (and `solidcraft-cli eval repro.json`).
- **If the symptom does not reproduce on the current `main`, do NOT claim it**: report it as dropped
  with the evidence (what you ran, what it printed, what the correct behaviour would be).
- Measure the exact numbers to put in the brief: the reply's `dof`, `driven`, `redundant`,
  `measured` for the exact half circle, and the same for the third point at (9,10). Measure what a
  genuinely redundant constraint does (two vertical constraints on one line) so the fix can be shown
  not to break it.
- Check the cause in the current source (`crates/sketch/src/redundancy.rs`, `crates/sketch/src/
  solver.rs`) and report the real file:line on the current `main`, not the scout's numbers.

### 2. Claim it

```bash
cd /home/user/Projects/solidcraft-orch/solidcraft-orch
bash bin/prepare-slot.sh 21119 orch-session      # claim verify + lock + worktree + target dir
```
It creates `/home/user/solidcraft-wt/issue-21119` on branch `fix-21119` from `origin/main` and prints
the path of the brief it renders. If it exits 3 the issue is not free (someone else has it):
report that and stop. If it exits 6 the cause is in the kernel: report that and stop.

Then, in that worktree:
```bash
git commit --allow-empty -m "claim: #21119"
git push fork HEAD:fix-21119
```
and open the DRAFT pull request against upstream:
```bash
gh pr create -R tangency-labs/solidcraft --head vdirienzo:fix-21119 --base main --draft \
  --title "<Area>: <what the user now gets> (#21119)" --body-file <your body file>
```
The body must have, in this order: a `## Change` section saying what the user gets now and what
happened before, in plain English, without the names of internal functions; the line `Fixes #21119`;
the line `Changes a default: no` (decide honestly: does this change the behaviour users rely on? if
it does, it is `yes - <what>, old behaviour kept behind preference <name>` and you say so in your
report); a `## Validation` section with the reproduction you measured (leave a placeholder line, the
implementer fills it in); and the `## Screenshots of the behavior` heading from the upstream template
(`.github/pull_request_template.md` in the worktree has the whole template: read it and keep its
headings).

The title's form is `Area: what the user or caller now gets, in plain words` — the area is what
people recognise (Sketch, Sheet metal, Patterns, STEP import, ...), the behaviour is in the present
tense, no issue number other than the `(#N)` the merge adds, under about 100 characters, important
words first. A good shape for this one:
`Sketch: a radius dimension on an exact half circle is driving, not redundant (#21119)`.

Then verify the claim:
```bash
bash bin/claim-verify.sh 21119 --our-pr <PR>     # exit 0 = ours
```
Exit 1 means someone else won: close your draft PR (leave a one-line English comment saying the
claim was lost to the lower-numbered PR) and stop. Exit 2 means it could not be checked: report
that and stop.

### 3. Write the implementer's brief

Write `/tmp/opencode/brief-21119.md` with everything the implementer needs and nothing it can read
on disk for itself: the issue number and title, the PR number, the worktree path, the branch, the
target dir (`bash bin/slot-target-dir.sh --slot 21119`), the exact repro script and the exact
output it gives today, the measured evidence (the reply's dof / driven / redundant / measured for
both the exact half circle and the near one, plus what a genuinely redundant constraint does), the
place in the code where the cause is (file and line on the current `main`) and what you think is
wrong, the method (REPRODUCE FIRST, then a RED test in the EXISTING test module of the area —
find which one it is, `crates/sketch/src/` has its own tests and `crates/engine/src/cmd/sketch.rs`
has others; never a per-bug test file — then the smallest fix, then GREEN), the hard rules from
`AGENTS.md` (never crash: no unwrap/expect/panic in non-test code; a regression test goes in the
area's existing test file; English everywhere; no generated files; a new user-visible string goes
to `assets/locales/pending/<slug>.json`; lists stay sorted), the machine limits, and the
deliverable: commit and push to the fork after every commit that builds, never push to origin, never
merge, never mark the PR ready, never comment, never clean up the worktree or the target dir, and
end with the JSON verdict `{"verdict": "ready|blocked", "pr": <PR>, "head": "<sha>", "proof": "...",
"fast": "...", "blocked": "..."}`.

Say in the brief, in bold, the two traps of this fix: the nudge must NOT move the solved geometry
(the sketch's measurements must stay the same after the fix), and a genuinely redundant constraint
must STILL be reported as redundant (the existing redundancy tests must stay green).

### 4. If #21119 does not reproduce or is taken

Do not claim anything else. Report, and stop.

## What to report

One JSON object and nothing else:
{"issue": 21119, "title": "<the issue title>", "pr": <PR>, "claim": "<the claim-verify verdict>",
 "reproduce": "<the exact script and the exact reply it gives today>",
 "measurements": "<the numbers: dof, driven, redundant, measured, for the half circle and the near one>",
 "cause": "<file and line on the current main where the cause is, and why>",
 "rejected": "<what you dropped and why, or empty>",
 "brief": "/tmp/opencode/brief-21119.md"}
