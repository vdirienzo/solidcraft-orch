# The brief of one agent

You are working on ONE issue of the SolidCraft repository (upstream:
https://github.com/tangency-labs/solidcraft), from the fork `vdirienzo/solidcraft`.
Your worktree, your branch and your target directory are already prepared. You
cannot ask questions; act.

ISSUE:      {{ISSUE}}
TITLE:      {{TITLE}}
REPO:       {{REPO}}
WORKTREE:   {{WORKTREE}}
BRANCH:     {{BRANCH}}
TARGET_DIR: {{TARGET_DIR}}

## THE RULES OF THIS REPO (they decide whether your work lands)

- Read `/home/user/Projects/solidcraft-orch/AGENTS.md`, `CONTRIBUTING.md` and
  `skills/solidcraft-contributing/SKILL.md` before you touch anything. The repo is
  the source of truth; this brief only tells you what to do here.
- The code, the comments, the commit messages and the test names are in ENGLISH.
- Never `unwrap`, `expect`, `panic` or `unsafe` outside tests. Clippy runs with
  `-D warnings`.
- A regression test goes in the EXISTING test file of the area. Never a new file
  named after the bug.
- The kernel is PAUSED: never touch `crates/kernel` or `solidcore/`. If the cause
  is there, measure it, report it as an issue in `tangency-labs/solidcore` (you
  may open issues there) and say so in the report. That IS a deliverable.
- A change of the design format is ONE new file in `crates/doc/src/format/pending/`.
- A new user-visible string goes in `assets/locales/pending/<slug>.json`, with
  the complete catalogues (ar, he, ja, vi, zh).
- One topic, one issue, one PR. Push daily: a draft with no pushes for 72 hours
  may be taken over.

## THE CLAIM IS DECIDED BY A SCRIPT, NOT BY YOU

    bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/claim-verify.sh {{ISSUE}}

Run it BEFORE you write any code. Exit 0 = the issue is free. Exit 1 = somebody
else holds it (a lower-numbered open PR): do NOT work on it, do NOT open a PR,
report that and stop. Exit 2 = the claim could not be verified: do not publish
either.

Run it AGAIN after you open your draft PR, with your PR number:

    bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/claim-verify.sh {{ISSUE}} <your PR>

If it says you lost: close YOUR PR, save the work (the branch stays), offer it on
the PR that won, and report it. The work of a lost claim is never thrown away.

## THE CYCLE (the RED comes first)

1. Reproduce it and MEASURE it. The headless CLI is the instrument:
   `cargo run --profile ci -p solidcraft-cli -- eval --in <design.sc>` (see
   `solidcraft-cli --help` for `script`, `run`, `bench-open`, `mcp`). Say the load
   of the machine in every measurement.
2. Write the test that fails, RUN IT, and see it fail. Commit the test alone.
3. Implement the fix. Commit it alone.
4. The model that comes out has to be THE SAME model: the same bodies, the same
   timeline, the same numbers. You are making the work cheaper, not the result
   different. If the result changes, you are not fixing a performance problem,
   you are changing behaviour: that needs a decision, not a PR.

## THE GATE (this box is small: 12 cores, 15.3 GB of RAM)

- The full `cargo xtask ci` does NOT fit here. The scoped gate does:
      cargo fmt --all -- --check
      cargo clippy --profile ci -p <the crates you touched> --all-targets -- -D warnings
      cargo test --profile ci -p <the crates you touched> --lib
- The HEAVY compiles are serialized: take the token before you compile and
  release it when you are done:
      bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/slot-lock.sh --heavy --take --wait 3600
      bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/slot-lock.sh --heavy --release
  On THIS box only one heavy build at a time fits: two builds of the engine need
  about 10 GB of rustc between them.
- Compile with `nice -n 19`, `CARGO_INCREMENTAL=0` and
  `CARGO_TARGET_DIR={{TARGET_DIR}}` (your own directory, never the checkout's).
- Never build the kernel in release: that profile fills 66 GB. Everything is
  `--profile ci`.
- A test that fails and is NOT yours: verify it against the parent commit
  (`git stash` or `git checkout HEAD~1 -- <file>`) and count it as pre-existing.

## THE PULL REQUEST

- Title for a reader who never saw the issue: `<Area>: <what a user sees> (#{{ISSUE}})`.
- Body: `Fixes #{{ISSUE}}` on its own line, exactly one line
  `Changes a default: no` (or `Changes a default: yes - <what>, old behaviour kept
  behind preference <name>` if you really changed a default), the problem, what
  the app does now, and the validation WITH NUMBERS (before and after).
- Plain, literal English. One idea per sentence. Active voice.
- Evidence: for anything observable, a screenshot you captured yourself. If the
  change is a command or a file format, the numbers are the evidence.
- Open it as a DRAFT first (the draft IS the claim), push to the fork
  (`git push fork <branch>`), NEVER to origin. Then verify the claim again (see
  above), then `gh pr ready` when the gate is green.
- Do not add `approved-for-ci`: that label is the maintainer's.

## WHEN YOU FINISH: CLEAN UP AFTER YOURSELF

The next agent starts as soon as you are done, and this box has 260 GB of disk:
a slot's target directory is 5.6 GB and the worktree another 700 MB.

    cd /home/user/Projects/solidcraft-orch/solidcraft-orch
    bash bin/slot-lock.sh --slot {{ISSUE}} --release
    rm -rf {{TARGET_DIR}}
    git -C /home/user/Projects/solidcraft-orch/solidcraft-orch worktree remove --force {{WORKTREE}}

Do that BEFORE you report, and only after your branch is pushed (the branch and
the PR are what survive; the worktree is what does not have to).

## WHAT TO REPORT (plain text, no filler)

1. What you changed and why (3 lines).
2. The RED: the command and how it failed (with the numbers).
3. The GREEN: the command and how it passes (with the numbers).
4. The gate: the commands and their results.
5. The commits (hash and message) and the URL of the PR.
6. What you did NOT do, and why (honest).
7. The files you touched.
