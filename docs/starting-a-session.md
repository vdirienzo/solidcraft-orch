# Starting a session: the loop without a human in the middle

This repo is an orchestrator: it holds the state of a loop that works on issues
of the upstream (https://github.com/tangency-labs/solidcraft) from the fork
`vdirienzo/solidcraft`. A session is one turn of that loop. This file is what a
session reads FIRST, because the loop has to survive the end of a session: the
state is on disk, the branches are in the fork, and the pull requests are
upstream.

## THE PROMPT TO START A SESSION

Paste this, in one message, in a session whose working directory is the
orchestrator's repo:

    You are the ORCHESTRATOR of the solidcraft-orch loop. Read
    AGENTS.md, then docs/starting-a-session.md, then
    /home/user/.local/share/solidcraft-orch/state.json, and run
    `bash bin/loop-status.py` and `bash bin/wave.sh --dry-run`. Then do what
    the wave prompt (prompts/wave-prompt.md) says: dispatch the agents, verify
    their pull requests, close their slots, and report in plain text.

What that prompt does, and why each piece is there:

- **AGENTS.md and this file**: the rules are in the repo, not in the chat. A
  session that starts without them repeats work that is already done.
- **the state**: `state.json` is the memory of the loop (the slots in flight, the
  pull requests opened, the claims held, the issues abandoned). It survives the
  session; the chat does not.
- **`loop-status.py`**: what is running right now, and what is waiting.
- **`wave.sh --dry-run`**: what the wave would do, without doing it. A dry run
  is how a session finds out that the pool is empty (the free issues of the
  upstream run out: its own agents take them) before it spends an hour proving
  it.

## THE TWO WAYS A SESSION WORKS

**As the orchestrator (the default).** The session does not touch the crates of
SolidCraft and does not compile anything:

1. `bash bin/next-issue.py` says which issue is worth an agent and why.
2. `bash bin/prepare-slot.sh <issue>` takes the lock of the slot, creates the
   worktree and the branch, renders the brief (`prompts/agent-<issue>.md`) and
   writes the slot in the state.
3. `bash bin/dispatch-slot.sh <issue>` starts the agent with that brief, in
   that worktree, with that slot's target directory.
4. When the agent reports, `bash bin/close-slot.sh <issue> <pr>` verifies the
   pull request, records it, deletes the target directory and the worktree, and
   releases the lock. If the claim was lost, it closes our pull request, saves
   the work in `logs/claims-lost/` and offers it on the pull request that won.
5. And again from 1: the next issue, another agent.

**As one agent of the wave (the subagent).** A session can also be ONE agent:
take one issue, work it, open the pull request. The brief
(`prompts/agent-brief.md`) has everything: the rules, the claim, the cycle, the
gate for this box, the shape of the pull request, the cleanup and the report.

## WHAT SURVIVES THE END OF A SESSION

| What | Where |
|---|---|
| the slots in flight, the pull requests, the claims | `state.json` (and `state/` by concept) |
| the work of an agent that died | its worktree, and `logs/claims-lost/` for a lost claim |
| the branches | the fork (`vdirienzo/solidcraft`) |
| the briefs | `prompts/agent-<issue>.md` |
| the log of each agent | `logs/<issue>-wave.log` |
| what each wave did | `reports/` (the daily report reads it) |

What does NOT survive: the chat, and the worktrees of the slots that were closed
on purpose (that is the disk hygiene: 5.6 GB of target per slot).

## THE RULES OF THIS BOX (they are not the upstream's, they are ours)

- One heavy build at a time: the token of the heavy phase, and
  `MAX_HEAVY_TOKENS=1` on a box with 15.3 GB of RAM. Two builds of the engine
  need about 10 GB of rustc between them.
- Every slot compiles in its own target directory (`bin/slot-target-dir.sh`), or
  cargo queues the builds in front of each other.
- The cache of compiles is 60 GiB (`~/.config/sccache/config`): with the old
  10 GiB the cache was full after two builds and every build was cold (22
  minutes instead of 6).
- The gate of a slot is the scoped one: the full `cargo xtask ci` does not fit
  in this box.
- The claim is decided by `bin/claim-verify.sh`, never by a label: the bot puts
  "in progress" with a delay, and the lowest-numbered open pull request wins.

## WHEN A SESSION DIES IN THE MIDDLE

The worktree is the truth, not the summary: read
`docs/agent-handover.md` and rescue the notes, the diff and the lock before
dispatching the replacement. A session that reads the state and the worktrees
picks up exactly where the last one stopped.
