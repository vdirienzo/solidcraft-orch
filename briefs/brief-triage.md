# Brief: triage the next issue and claim it (orchestrator's role, delegated)

You are the triage agent of the SolidCraft orchestrator. Nobody is watching and you cannot ask
questions. Your job: pick ONE issue worth fixing, prove it still happens on `main`, claim it, and
write the brief that the implementer agent will follow. You do NOT implement the fix.

## The machine and the rules (they are the law)

- 12 cores, 15 GB RAM, no swap. One heavy build at a time. Use `nice -n 19` and `--profile ci`.
- Your scratch target dir (build the CLI here, not in a slot's): `/home/user/.local/share/solidcraft-orch/targets/triage`
- Around a big build take the heavy token:
  `bash /home/user/.local/share/solidcraft-orch/bin/slot-lock.sh --heavy --take --wait 3600`
  and release it with `bash /home/user/.local/share/solidcraft-orch/bin/slot-lock.sh --heavy --release`
- Push ONLY to the fork (`fork` = vdirienzo/solidcraft). NEVER push to `origin` (upstream is
  read-only here).
- English in everything public.
- The orchestrator's tools are in `/home/user/Projects/solidcraft-orch/solidcraft-orch` (bin/).
  The upstream checkout is `/home/user/Projects/solidcraft-orch` (remotes: `origin` = upstream,
  `fork` = ours).
- NEVER merge, never add or ask for `approved-for-ci` or `ready to merge`, never comment on the
  issue or the PR, never open more than one PR.

## The candidates (in the order you should try them)

1. **#22522** — "Can't extrude a sketch that is obscured by a solid" (area:sketch, reported on
   0.49.1). The design is attached to the issue:
   https://github.com/user-attachments/files/35460892/Miele.Triflex.Netzteilkorb.sc.zip
   The user wants the whole sketch to be selectable even when a solid body is in front of it;
   today SolidCraft picks the solid's faces instead ("SolidCraft always picks the to or side faces
   of said solid").
2. **#9223** — "EXTRUDE: operation failed" with the error "the design changed while the feature
   editor was open" (canonical of a group of three; still open). The engine raises it in
   `crates/engine/src/lib.rs` (`compute_editor_commands` / `restore_editor`, the
   `same_document_context` check). The user had the extrude editor open, selected features and
   pressed OK, and the apply was refused.
3. **#9477** — "Not able to click on a dimension to use it as input for an operation (e.g.
   extrusion)". The user wants to click a dimension in the view while the operation's field is
   focused, and have it fill the field ("d3"); today the field gets an empty value and the command
   says "`distance` must be a number or an expression".
4. **#15716** — "EMBOSS: operation failed": "invalid input: cylinder emboss: profile crosses a
   cylinder seam or endcap boundary".
5. **#11406** — "Convert Mesh fails on STL with degenerate triangles instead of skipping them".
   The canonical of a group of four. The message comes from `solidcore/crates/solidcore/src/mesh_reconstruction/mod.rs`.

**Reject without trying** anything whose fix would land in `solidcore/` or `crates/kernel`: this
box does not build the kernel, so such a PR is vetoed by the machine's policy (candidate 5 is very
likely such a case: verify where the fix would have to go before spending time on it).

## What to do

### 1. Prove the issue still happens on `main`

For each candidate you intend to try (start with 1, then 2, then 3):

- Get the issue and its discussion. `gh issue view <N> -R tangency-labs/solidcraft` works, but
  `gh issue view --comments` does NOT work on this repo (GraphQL "Projects (classic)"): read the
  comments with `gh api repos/tangency-labs/solidcraft/issues/<N>/comments`.
- Download any attached design into a scratch dir of your own (`/tmp/opencode/triage-<N>/`), never
  into the repo.
- Build the CLI in your scratch target dir (`apps/solidcraft-cli`, `--profile ci`) and reproduce
  the failure headlessly. `solidcraft-cli run <script.json> --in "<design.sc>" --results` and
  `solidcraft-cli eval <script.json> --in "<design.sc>"` are the tools; `solidcraft-cli script
  <design.sc>` prints the design's history as a command script, which is often the fastest way to
  see what to replay.
- **If the symptom does not reproduce on the current `main`, drop that candidate** and say so with
  the evidence. A candidate that does not reproduce is not worth a PR: do not claim it.
- For an issue whose failure is a dialog interaction (candidates 1 and 3 are partly a pick in the
  3D view), find the engine-level decision that produces it and reproduce THAT headlessly: the
  command that is sent with the wrong parameters (candidate 1's issue shows the exact
  `solid.extrude` parameters the app sent) or the code path that refuses it (candidate 2). If you
  cannot reproduce it headlessly at all, say so and drop it: an issue we cannot verify is an issue
  we cannot fix with evidence.

### 2. Claim the one you picked

```bash
cd /home/user/Projects/solidcraft-orch/solidcraft-orch
bash bin/prepare-slot.sh <N> orch-session      # claim verify + lock + worktree + target dir
```
It creates `/home/user/solidcraft-wt/issue-<N>` on branch `fix-<N>` from `origin/main` and prints
the path of the brief it rendered. If it exits 3 the issue is not free (someone else has it): pick
another. If it exits 6 the cause is in the kernel: pick another.

Then, in that worktree:

```bash
git commit --allow-empty -m "claim: #N"
git push fork HEAD:fix-<N>
```
and open the DRAFT pull request against upstream:
```bash
gh pr create -R tangency-labs/solidcraft --head vdirienzo:fix-<N> --base main --draft \
  --title "<Area>: <what the user now gets> (#N)" --body-file <your body file>
```
The body must have, in this order: a `## Change` section saying what the user gets now and what
happened before, in plain English, without the names of internal functions; the line
`Fixes #N`; the line `Changes a default: no` (if the change alters behaviour users rely on, it is
`yes - <what>, old behaviour kept behind preference <name>` — decide honestly and say which you
chose in your report); a `## Validation` section with the reproduction you measured (leave a
placeholder line, the implementer fills it in); and the `## Screenshots of the behavior` heading
from the upstream template (`.github/pull_request_template.md` in the worktree has the whole
template: read it and keep its headings).

The title's form is `Area: what the user or caller now gets, in plain words` — the area is what
people recognise (Sketch, Sheet metal, Patterns, STEP import, ...), the behaviour is in the present
tense, no issue number other than the `(#N)` the merge adds, under about 100 characters, important
words first. Examples of merged titles:
- `Shell: a feature narrower than twice the wall stays solid instead of refusing the shell`
- `Split Body: an open sheet of one face splits a body`

Then verify the claim:
```bash
bash bin/claim-verify.sh <N> --our-pr <PR>     # exit 0 = ours
```
Exit 1 means someone else won: close your draft PR (leave a one-line English comment saying the
claim was lost to the lower-numbered PR) and pick another candidate. Exit 2 means it could not be
checked: report that and stop.

### 3. Write the implementer's brief

Write `/tmp/opencode/brief-<N>.md` with everything the implementer needs and nothing it can read
on disk for itself: the issue number and title, the PR number, the worktree path, the branch, the
target dir (`bash bin/slot-target-dir.sh --slot <N>`), the exact reproduction command and the exact
error it gives today, the measured evidence (face counts, volumes, error strings), the place in the
code where you found the cause and what you think is wrong (with file and line), the method
(REPRODUCE FIRST, then a RED test in the EXISTING test module of the area, then the smallest fix,
then GREEN), the hard rules from `AGENTS.md` (never crash: no unwrap/expect/panic in non-test
code; layering; a regression test goes in the area's existing test file, never a per-bug file;
English everywhere; no generated files; a new user-visible string goes to
`assets/locales/pending/<slug>.json`), the machine limits, and the deliverable: commit and push to
the fork after every commit that builds, never push to origin, never merge, never mark the PR
ready, never comment, never clean up the worktree or the target dir, and end with the JSON verdict
`{"verdict": "ready|blocked", "pr": <PR>, "head": "<sha>", "proof": "...",
"fast": "...", "blocked": "..."}`.

## What to report

One JSON object and nothing else:
{"issue": <N>, "title": "<the issue title>", "pr": <PR>, "claim": "<the claim-verify verdict>",
 "reproduce": "<the exact command and the exact error it gives today>",
 "cause": "<file and line where you think the cause is, and why>",
 "rejected": "<the candidates you dropped and why: already fixed, by design, kernel, or not verifiable headlessly>",
 "brief": "/tmp/opencode/brief-<N>.md"}