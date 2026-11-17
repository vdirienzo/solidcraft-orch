# House rules of the loop (untracked)

This file is **not** part of the repository. The loop writes it in the root of
the worktree and excludes it from git, so it is never committed and never
pushed. It exists because the loop used to inject these rules with a patch
over `AGENTS.md`: that modified a tracked file, the tree was left dirty and a
failed rebase could leave `main` in conflict. Nothing versioned is touched
anymore.

## The rules of the repository are the source of truth

`AGENTS.md` is a router: it carries the hard rules and points at the skill to
read for the task (`skills/solidcraft-*/SKILL.md`). Read `AGENTS.md` first and
then the skill it points to. This file only adds the rules of the house of the
loop: what the loop expects from an agent that works in this worktree. When
this file and the repository disagree, the repository wins.

## Working as an agent

- **The code is English. The comments are English. Always.** Identifiers, doc
  comments, inline comments, commit messages, branch names, test names, error
  messages and documentation are all in English. This is not a preference: a
  comment in another language is a defect, it is not reviewable by the people
  who maintain this code, and a reviewer rejects it. If something is not
  obvious, write it in English and keep it short. Translations belong to the
  message catalogs in `assets/locales/`, nowhere else.
- **Parallel work runs in parallel.** When a task splits into independent
  parts — several files, several areas, several checks that do not depend on
  each other — dispatch one subagent per part and let them run concurrently
  instead of walking the list one item at a time. Give every subagent a
  self-contained brief: what to change, what not to touch, and what to report
  back. Read the answers before you continue; a subagent's report is not a
  result you can assume.
- **Do not parallelize what depends on itself.** A fix and the test that proves
  it, a refactor and the callers it breaks, two edits to the same file: those
  stay sequential. One subagent per independent unit of work, and no two units
  may write the same file.

## Non-negotiables

- **How an agent works**: English code and English comments, and parallel
  subagents for independent work — see "Working as an agent".
- **The loop does not touch the rules nor the CI.** `AGENTS.md`,
  `.github/workflows/*`, `xtask/*` and `patches/*` are not yours: an agent
  that edits them is rejected and the work is thrown away.
