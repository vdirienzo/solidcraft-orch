# SolidCraft — rule sheet for agents (read 2026-10-30, from AGENTS.md + skills/ + CONTRIBUTING.md)

Source of truth: the repo. This file is a cache of the rules, not a replacement.

## HARD RULES
- Clean-room: never copy another product's code, icons, text, templates; never drive or take data from commercial CAD.
- No GPL/LGPL/AGPL code, not even reading it (OpenCASCADE, FreeCAD, SolveSpace, CadQuery, LibreCAD, QCAD). `cargo xtask licences --check`.
- Every asset original or openly licensed with an ATTRIBUTION.md row; `assets/AGENTS.md` before icon work.
- Never crash: no unwrap/expect/panic/unsafe in non-test code; errors are Result; input is hostile; clippy `-D warnings`.
- Everything user-visible is a command; programmatic calls never open dialogs.
- Layering L0 geom -> L1 sketch/kernel/render -> L2 doc -> L3 io -> L4 engine -> L5 ui-egui -> apps; only crates/kernel uses truck (`cargo xtask layers`).
- One outer UI container, one camera path (`navigation::handle`), colours only from theme tokens (`cargo xtask ui-containers`).
- Product name is SolidCraft; sorted lists stay sorted (`cargo xtask lists`); never edit generated files in a PR.
- A design-format change is ONE new file in `crates/doc/src/format/pending/`; new UI strings -> `assets/locales/pending/<slug>.json`; ATTRIBUTION rows -> `attribution/pending/<slug>.md`.
- A changed default keeps the old behaviour behind a preference AND fills the PR's `Changes a default:` line.
- No second PR for an issue a lower-numbered PR closes.
- A regression test goes in the area's EXISTING test file, never a per-bug file (#3226).
- Kernel is PAUSED: no issues/PRs touching crates/kernel (booleans, fillets, chamfers, shell, offsets, sweeps, lofts, threads, holes, STEP/IGES, tessellation). Crashes/data loss are still in scope.

## CLAIM -> PR -> PUBLISH
1. Survey first: `gh pr list --state open --limit 500` AND `gh issue list --state open --limit 500` (drafts included). Comment on an existing PR instead of opening a second.
2. Skip an issue if ANY open PR mentions "#N" (Fixes/Closes/Refs #N in the body, or #N in the title), or if the issue carries 'in progress', 'kernel-paused' or 'status:decision'.
3. READ THE ISSUE'S COMMENTS before taking it. A closed bot claim ("Claimed by @X through #Y"), a "please reopen", a "same root cause as #Z, fixed by #W" or a triage comment that says it is already fixed means the issue is NOT free. The label is NOT enough: the bot applies 'in progress' with a delay, so between the survey and the claim another agent can take the issue. On 31-10-2026 we lost #10134, #10138 and #10079 exactly this way (cfaulkingham, dahakbuilds via #10183, kaltenbrunnermarkus via #10213) after working on them for hours.
4. Claim ATOMICALLY: take the slot lock FIRST, then open the DRAFT PR titled "SUMMARY (#N)" with "Fixes #N" in the body (the draft IS the claim; the bot reads #N in the title and Fixes #N in the body). Lowest-numbered open PR for an issue wins: if the duplicate check flags ours, CLOSE ours and move on (`gh pr close` works). Keep about 10 open PRs at most, and rebase our own open PRs before opening new ones.
5. RE-VERIFY THE CLAIM right after opening the draft: re-run the PR survey for #N. If another PR with a LOWER number mentions #N, ours lost: close ours (`gh pr close`) and release the slot. The gap between the survey and the draft is where the work gets lost.
   The check is a SCRIPT, not a rule to remember: `bash bin/claim-verify.sh <issue> [our_pr]` returns 0 when the claim is ours, 1 when it is lost and 2 when it could not be checked (a claim that was never checked is not a free claim). The gate calls it before it compiles and refuses to run when the claim is lost: eight minutes of compilation for a pull request that will never be published is the most expensive way to lose a race.
   THE ONE RULE: `bin/claim-verify.sh` is the only implementation of "who holds the claim". It asks GitHub once and answers VEREDICTO=OK|OCUPADO|PERDIDO|ERROR, and its exit code IS the verdict (0 ours, 1 lost, 2 could not be checked). The exit codes are never translated by the caller: the gate reads 1 as "the claim is lost" and 2 as "unknown, the gate runs anyway".
   THE RULE ITSELF is the UNION of the two rules of upstream, which do not agree with each other (and the upstream bot applies both): `#N` in the TITLE of the pull request (`scripts/claim/claim.js`, referencedIssues) OR a closing verb followed by `#N` in the BODY (`scripts/pr-checks/pr-checks.js`, parseClosing). The noise of the body (HTML comments, code blocks) is stripped before parsing, a reference to another repository is not a claim on ours, and a pull request does not claim its own number.
   OUR OWN PULL REQUESTS do not compete with us: the winner is the lowest number of ANOTHER author's pull request. Without this rule two of ours on one issue made the higher-numbered one lose, and the orchestrator CLOSED it.
   WHERE THE CHECK RUNS: (a) in the publisher, BEFORE the model starts, so a race that is already lost costs one call to GitHub and nothing else (the upstream bot applies the label 'in progress' with a DELAY, so the race is lost between the survey and the draft); (b) in the publisher, at the push, so nothing is published without a check. The gate ALSO checks the claim before it compiles (exit 4 when it is lost).
   When the claim is lost, the WORK IS SAVED, not thrown away: the diff of the branch against its base, the list of the commits, a note in words and the same thing as JSON go into `logs/claims-lost/`. The branch and the worktree are NOT deleted. The work of a lost claim is worth MORE than a lost claim: it is a fix that can be re-targeted, or an offer on the pull request that won the race.
   THE DEADLINE OF A CLAIM: the upstream bot has TWO and the text of CONTRIBUTING mixes them. `CLAIM_HOURS = 72` is the window of the `/claim` comment; `PR_IDLE_DAYS = 14` is the window of a DRAFT without pushes (`scripts/claim/claim.js:8-9`). For a draft, the number is 14 days.
6. Implement one topic, one issue. Body file written BEFORE claiming. Regression test in the area's existing test file; prove it fails before the fix and passes after.
7. Gate, then push. Push daily (a draft idle 14 days without pushes may be taken over: `PR_IDLE_DAYS` in `scripts/claim/claim.js`, NOT the 72 hours of the `/claim` comment). Never force-push main; never push only to catch up with main. If rebasing: rebase onto latest main and push the branch with --force-with-lease; never merge main into a PR.
8. Evidence, then `gh pr ready N`. Maintainer adds `approved-for-ci` (never the agent). Merge is the maintainer's queue.

## WHAT IS WORTH AN AGENT (the maintainer's list, 31-10-2026)
WORTH it: bugs with a clear repro, crash reports that come with a replay, sketch/UI/import fixes, missing translations, docs and tests.
NOT worth it right now: kernel and modelling operations, STEP and tessellation (paused while kernels move); the Render workspace (area:render: Nate's area, moving fast); cloud, sync and sharing (frozen); anything that changes default behaviour; big refactors of hot files like viewport.rs or eval.rs.

## PR BODY
- `Fixes #N` exactly (bot reads `#N` in the title and `Fixes #N` in the body).
- Exactly one line: `Changes a default: no` or `Changes a default: yes - <what>, old behaviour kept behind preference <name>`.
- Problem, resulting behaviour, validation (expected vs measured numbers for geometry).

## EVIDENCE
- Required for observable CAD/UI/model behaviour. Capture it yourself, never ask a human.
- Attach to the issue/PR or link an accessible recording. Public-safe synthetic example; strip private paths/tokens.
- No observable change -> no evidence needed.

## SKILLS ROUTER
| work type | skill |
|---|---|
| PR, claim, review, CI, evidence | skills/solidcraft-contributing/SKILL.md |
| panel, dialog, camera, icon, colour | skills/solidcraft-ui/SKILL.md |
| CLI, commands, crate boundaries | skills/solidcraft-commands/SKILL.md |
| tests: placement, running | skills/solidcraft-tests/SKILL.md |
| non-test Rust, hostile input, crash | skills/solidcraft-crash-safety/SKILL.md |
| design format, import/export | skills/solidcraft-file-formats/SKILL.md |
| deps, assets, wording, name | skills/solidcraft-ground-rules/SKILL.md |

## GATE
- NEVER the full `cargo xtask ci` before publishing: the CI of the upstream runs the
  full suite when a maintainer adds `approved-for-ci`, and the merge queue runs it
  again on top of main. A fair local gate (the maintainer's own recipe):
    cargo fmt --all --check
    cargo check --workspace --all-targets --profile ci
    cargo clippy -D warnings on the packages the change touches
    nextest on the crates that `scripts/ci/affected.py` selects
  A scoped gate is fine: if it misses something, CI catches it before merge, and
  that costs a red check, not a broken main.
- ONE persistent CARGO_TARGET_DIR per slot, shared by the agent and the gate of
  that slot (with sccache), instead of a fresh build every time:
    bash bin/gate.sh <issue> <sha> [base]
  It compiles in `targets/slot-<issue>` (the one the agent used) and in the
  worktree of the slot. The verdict file is authoritative:
  `~/.local/share/solidcraft-loop/gates/<slot>/scope.verdict`.
- The GPU path tests are skipped: as of #7742 they only run when render code
  changes or a PR has the `render-tests` label. The dielectric flake is fixed
  (#7722).
- A check that could not run is NOT a red: exit code 6 = UNKNOWN, never "no".

## OPERATING ON THIS BOX (added 2026-10-31)
The machine: 16 cores, 62 GB of RAM, 492 GB of disk. It exists for this work only.

- Slots: `bash bin/slots.sh report`. The number follows the hardware (`CORES_PER_SLOT=3`
  cores per slot, `MAX_IMPLEMENT_SLOTS=6` as the cap) and the free RAM. One slot per issue, each with its own worktree and its own CARGO_TARGET_DIR.
- The GATE is serialized: it compiles seven packages and saturates the machine. Take the turn
  with `bash bin/slot-lock.sh --heavy --take --wait 3600` and release it afterwards. One gate
  at a time, always.
- Disk per slot: the dev profile fills 66 GB for a seven-package scope; the ci profile is
  1.5 GB. Use the ci profile. Delete a slot's target when the slot finishes, after verifying
  the fix is upstream.
- The release app takes 49 min to link (LTO) and is 3.3 GB: do not rebuild it casually.
- The headless graphics setup is `source ~/.local/x/env.sh` (Xvfb :99 + lavapipe). Without it
  the app does not open a window.
- The state is read by PARTS: `bash bin/orch-state.sh [slots|prs|gates|issue N|keys|history N]`.
  Never read state.json whole: it is context that gets re-sent on every turn.
- A PR is checked in ONE call: `bash bin/verify-pr.sh <n>`.

## DISCREPANCIES vs local checkout (the local is behind origin/main; re-check before acting)
- Upstream CONTRIBUTING.md adds: a PR touching Cargo.lock/Cargo.toml runs cargo-deny advisories;
  `cargo xtask lists` rejects non-test const/static arrays with >10 entries (use slices);
  a new English message must also ship in every COMPLETE catalog (ar, he, ja, vi, zh) in the same pending file.
- AGENTS.md and all skills/ files are byte-identical to upstream.
- Test placement safe reading: reuse the area's existing file; never a file named after the bug.
