# One SolidCraft issue, all the way to a PR ready for review

ISSUE:      #{{ISSUE}} {{TITLE}}
OUR PR:     {{PR}}
WORKTREE:   {{WORKTREE}}  (branch `{{BRANCH}}`, already checked out)
TARGET_DIR: {{TARGET_DIR}}

Nobody is watching and you cannot ask questions. Follow
`.agents/skills/solidcraft-full-stop/SKILL.md` in the worktree; it routes to the
file-pr, babysit-pr and area skills. `AGENTS.md` is the law. If `.agents/skills/` is
missing, the branch is old: rebase it onto `origin/main` first.

## What is different here
1. **Claim first, before any code**, unless OUR PR above is a number:
   `git commit --allow-empty -m "claim: #{{ISSUE}}"`, `git push fork HEAD:{{BRANCH}}`, then open
   a DRAFT titled `<summary> (#{{ISSUE}})` (the claim bot reads the issue number there) whose body
   has `Fixes #{{ISSUE}}` and `Changes a default: no`. Then run
   `bash ~/.local/share/solidcraft-orch/bin/claim-verify.sh {{ISSUE}} --our-pr <PR>`.
   Exit 1 means you lost the claim: close your draft and stop with verdict `blocked`.
   Exit 2 means it could not be checked: stop with verdict `blocked`.
   When the change is done the PR goes **ready for review** and **the title loses the issue
   number**: `Area: what the user now gets, in plain words` (the merge adds the `(#N)`).
   (`HEAD:{{BRANCH}}` and `{{BRANCH}}` son lo mismo cuando la rama esta checkouteada;
   la forma con HEAD tambien funciona cuando el worktree del slot nace pegado a un
   commit, que es lo que pasa cuando la rama del PR ya esta checkouteada en otro
   worktree.)
2. **Remotes:** push only to `fork` (vdirienzo/solidcraft). Never push to `origin`.
3. **This box is small** (12 cores, 15 GB). Use `--profile ci`, `nice -n 19` and
   `CARGO_TARGET_DIR={{TARGET_DIR}}`. Take the heavy-build token around `cargo xtask fast`
   and other big builds:
   `bash ~/.local/share/solidcraft-orch/bin/slot-lock.sh --heavy --take --wait 3600`, then
   `--heavy --release`. Never build the whole workspace by hand; `cargo xtask fast` decides
   what to build, and it now tests only the packages the change touches. **The local gate is
   `cargo xtask fast --base origin/main` plus `cargo xtask app-geometry` (which `fast` does
   not run) and the path gates the change touches**: upstream's own prepush check is
   `cargo xtask ci`, which always runs the whole suite (78 test binaries, 56-90 min here) and
   belongs in the CI.
   To be up to date with `main`, merging `main` in is the cheap way (the CI carries a
   passing run when the merge leaves the change as it was); rebasing is fine too, with
   `--force-with-lease` and only on your own branch.
4. **Kernel cause:** if the root cause is in `solidcore/` or `crates/kernel`, measure it,
   write it down and stop with verdict `blocked`. This box does not build the kernel.
5. **Push after every commit that builds** (the RED test first, then the fix). A turn that
   dies keeps only what is in the fork.
6. **Waiting for CI:** run `pr-wait` from babysit-pr once, with `--until green --max-hours 1`,
   and again with `--until ready` for the final gate (the heavy tests, the review bot and no
   open thread). Do not wait for `approved-for-ci` and never ask for it.
7. **Do not clean up.** Leave the worktree, the target dir and the locks alone: the
   orchestrator removes them. If you opened a browser through chrome-devtools, close its
   pages before you finish.

## The body and the pictures
- The body follows `.github/pull_request_template.md`: `## Change` (the problem as the user
  meets it, then the result), `Fixes #N`, `Changes a default: no` (or the long `yes` form),
  `## Validation` (what you ran and what came out, expected and measured values),
  `## Screenshots of the behavior (when observable)` and `## Integration status`.
- **The `Changes a default:` line**: a fix of jank or of unintended behaviour is `no`, and it
  adds **no** setting to keep the old behaviour nobody would choose; `yes` is only a
  deliberate change to established behaviour people rely on. The parser also accepts `no` with
  a note behind it, the heading form `## Changes a default` with the value under it, and
  `yes - <what>, approved by the owner` (that one needs the owner-approved label).
- **`Test change: <why the old expectation was wrong>`** only when the diff touches kernel
  source (`solidcore/`, `crates/smlib/`) AND changes or deletes a line of an existing test or
  golden expectation. New tests need no line.
- If the fix makes a test that is listed in `tests/KNOWN_FAILING_TESTS` pass, **remove that
  line in this same pull request**: the CI fails on a listed test that now passes.
- **Media only when it is about something to look at**: a change visible in the UI, or a change
  in how the model looks. A kernel or geometry fix proven by its tests needs none. When media
  is needed, it goes in the description as links, never in the diff, and it must not show
  private details (home paths, user names, tokens). Capture it yourself from the app.
- The PR is opened **ready for review** once the change is done: the draft is only the claim.

## Your last message
One JSON object and nothing else:

```json
{"verdict": "ready|waiting|blocked", "pr": 0, "head": "<sha>",
 "proof": "<the RED and GREEN commands, and what they printed>",
 "gate": "<the cargo xtask fast (+ app-geometry) result>", "blocked": "<what blocks it, or empty>"}
```
