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
   a DRAFT titled `<summary> (#{{ISSUE}})` whose body has `Fixes #{{ISSUE}}` and
   `Changes a default: no`. Then run
   `bash ~/.local/share/solidcraft-orch/bin/claim-verify.sh {{ISSUE}} --our-pr <PR>`.
   Exit 1 means you lost the claim: close your draft and stop with verdict `blocked`.
   Exit 2 means it could not be checked: stop with verdict `blocked`.
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
   what to build.
4. **Kernel cause:** if the root cause is in `solidcore/` or `crates/kernel`, measure it,
   write it down and stop with verdict `blocked`. This box does not build the kernel.
5. **Push after every commit that builds** (the RED test first, then the fix). A turn that
   dies keeps only what is in the fork.
6. **Waiting for CI:** run `pr-wait` from babysit-pr once, with `--until green --max-hours 1`.
   Do not wait for `approved-for-ci` and never ask for it.
7. **Do not clean up.** Leave the worktree, the target dir and the locks alone: the
   orchestrator removes them. If you opened a browser through chrome-devtools, close its
   pages before you finish.

## Your last message
One JSON object and nothing else:

```json
{"verdict": "ready|waiting|blocked", "pr": 0, "head": "<sha>",
 "proof": "<the RED and GREEN commands, and what they printed>",
 "fast": "<the cargo xtask fast result>", "blocked": "<what blocks it, or empty>"}
```
