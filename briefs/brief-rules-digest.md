# Brief: digest what changed in upstream's rules, for the orchestrator's docs

You are producing a precise, itemised digest of a change in upstream's rules, so the orchestrator's
own documentation can be updated on purpose. Nobody is watching and you cannot ask questions.

## The situation

- The upstream checkout is `/home/user/Projects/solidcraft-orch`, now at `origin/main`
  (`48cdd5f5a5`). The orchestrator's own repo is `/home/user/Projects/solidcraft-orch/solidcraft-orch`
  (its `RULES.md`, `prompts/agent-brief.md`, `prompts/agent-9223.md`, `prompts/agent-21119.md`,
  `README.md`, `HANDOFF.md`).
- The orchestrator's snapshot of the upstream rules is stale: `bash bin/rules-snapshot.sh --check`
  (with `SOLIDCRAFT_REPO=/home/user/Projects/solidcraft-orch`) reports these 14 changed files:

  ```
  .agents/skills/solidcraft-babysit-pr/SKILL.md
  .agents/skills/solidcraft-contributing/SKILL.md
  .agents/skills/solidcraft-file-pr/SKILL.md
  .agents/skills/solidcraft-layers/SKILL.md
  .agents/skills/solidcraft-packaging/SKILL.md
  .agents/skills/solidcraft-performance/SKILL.md
  .agents/skills/solidcraft-preferences/SKILL.md
  .agents/skills/solidcraft-repro-first/SKILL.md
  .agents/skills/solidcraft-ui/SKILL.md
  .github/pull_request_template.md
  AGENTS.md
  CONTRIBUTING.md
  scripts/claim/claim.js
  scripts/pr-checks/pr-checks.js
  ```

## What to do

1. For each of those 14 files, find out **what changed** and **what it now requires**. Use the git
   history of the upstream checkout: `git -C /home/user/Projects/solidcraft-orch log --oneline -6
   -- <file>` and then `git -C /home/user/Projects/solidcraft-orch diff <older-commit>..origin/main
   -- <file>` to see the change itself. Read the CURRENT version in full for the ones that matter
   most (AGENTS.md, .github/pull_request_template.md, scripts/pr-checks/pr-checks.js,
   scripts/claim/claim.js, .agents/skills/solidcraft-file-pr/SKILL.md,
   .agents/skills/solidcraft-babysit-pr/SKILL.md, .agents/skills/solidcraft-contributing/SKILL.md,
   .agents/skills/solidcraft-preferences/SKILL.md).
2. Then compare with what the orchestrator's documents say today: read
   `solidcraft-orch/RULES.md`, `solidcraft-orch/prompts/agent-brief.md`,
   `solidcraft-orch/prompts/agent-9223.md`, `solidcraft-orch/prompts/agent-21119.md` and grep
   `solidcraft-orch/README.md` for the parts that talk about how a PR is titled, what the body must
   contain, how the claim is made, what the gate is, which skills exist and what `cargo xtask
   ci`/`fast` do.
3. Produce the digest below.

## What the digest must contain

- **Per changed upstream file**: what it now says, in one or two lines, with the exact requirement
  that an agent has to follow (a quote when the wording matters).
- **Per orchestrator document that is now wrong**: the file and the line/paragraph that no longer
  matches upstream, and what it must say instead. Be concrete: quote the current wrong text.
- **The PR body and title rules as they are NOW** (from `.github/pull_request_template.md` and
  `scripts/pr-checks/pr-checks.js`): which lines the parser reads, which are mandatory, and whether
  the title may carry the issue number.
- **The claim rules as they are NOW** (from `scripts/claim/claim.js` and
  `.agents/skills/solidcraft-contributing/SKILL.md`): what a claim needs (commit message, branch,
  PR title, body line), who wins, and what to do when the claim is lost.
- **The gate**: what `cargo xtask fast` and `cargo xtask ci` do now (read `xtask/src/fast.rs` and
  `xtask/src/ci.rs` headers), and what a change should run before pushing.
- **Anything that affects a small machine** (12 cores, 15 GB, one heavy build at a time): which
  upstream check is now cheap or expensive.

## Hard rules

- Do NOT modify any file. You only read and you write ONE new file:
  `/home/user/Projects/solidcraft-orch/solidcraft-orch/reports/upstream-rules-2026-11-28.md`.
- Do not build anything (no cargo). Reading and git history only.

## Deliverable

Your final message must be one JSON object and nothing else:
{"digest": "/home/user/Projects/solidcraft-orch/solidcraft-orch/reports/upstream-rules-2026-11-28.md",
 "must_change": ["<the orchestrator documents that are wrong and what they must say, one line each>"],
 "title_rule": "<the title rule as it is now, in one line>",
 "body_rule": "<the mandatory body lines as they are now, one line each>",
 "claim_rule": "<the claim rule as it is now, one line>",
 "gate": "<what to run before pushing, one line>",
 "surprise": "<the one thing that surprised you most, or empty>"}
