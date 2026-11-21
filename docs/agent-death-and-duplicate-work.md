# An agent that dies still leaves work, and someone else may have done it first

## A dead agent is not an empty slot
An agent can die with a tool pending and no summary at all: the `opencode run` of the
slot is cut by its time ceiling, by the OOM killer or by a reboot. That is NOT the same
as "the slot produced nothing".

On #10747 the dead agent had left, in its worktree:
- the commit (`e1a5c4435`, 8 files, 192 insertions),
- the PR body file (`pr-body-10747.md`),
- the RED log (`red-10747.log`).

Before closing a slot as lost, ALWAYS look at:
- the branch: `git log --oneline origin/main..BRANCH` and `git diff --stat origin/main...BRANCH`,
- the worktree: `git status --short` (untracked files are often the evidence),
- the transcript: its last ten events in `logs/<N>-wave.jsonl` (`--format json`), and
  the exit line that `bin/dispatch-slot.sh` wrote in `logs/<N>-wave.log`.

## An agent that hits the TIME CEILING has usually already finished the work
(2026-11-21) The ceiling is time now, not iterations: `AGENT_TIMEOUT_MIN` (`bin/agent-env.sh`,
180 min unless `config.env` says otherwise), applied by `bin/dispatch-slot.sh` with `timeout`.
An agent cut by it exits with rc=124 and its log line says "techo de tiempo". The ceiling is
reached at the END of a run, so what is lost is the VERDICT, not the work: the agent may have
committed, pushed, gated and verified everything already, one step before writing the JSON.

So the reading of a turn with no verdict is: go and LOOK, do not re-dispatch. `git status
--porcelain` in the worktree and `git ls-remote` for the published head are the ground truth;
an agent that pushed a commit is done with the implementation, and a replacement would
re-derive a settled design and burn its own budget before writing anything. Never `--continue`
the cut session either: its cache is cold after ~15 minutes and upstream's `CONTRIBUTING.md`
says not to resume one ("it re-reads the whole history at full price").

Two corollaries that follow from the same fact:
- the ORCHESTRATOR finishes the last mile itself (the push, the body, the ready switch) when
  the agent stopped one command away — it is cheaper than a replacement;
- the durable form of the agent's conclusion is its COMMIT MESSAGE, not its report: require
  the diagnosis to be committed, so a cut turn still leaves the reasoning on disk.

## Someone else may have done the same work while it was running
On #10747 the same fix landed as PR #10812 by another author, with the SAME title
and 7 of the same 8 files. The maintainer had already approved it (`ready to
merge`, `owner-approved`, `approved-for-ci`).

The comparison has to be file by file. The rule of the repo decides the outcome:
the open pull request with the LOWEST number wins, so a PR opened now loses.

## When your work is a strict superset of an approved PR
The extra part usually DEPENDS on the other PR: it calls the functions that PR
adds (here `round_reported` and `reported_value` in `crates/doc/src/expr.rs`), so
it does not compile against main.

Do not open it. A pull request that does not compile is worse than no pull
request: it burns a review cycle and it cannot be approved.

Preserve it in the fork instead:
- `git push fork BRANCH:refs/heads/wip/issue-NNNN-<what-it-adds>`
- the RED log on `evidence/issue-NNNN-<name>` with the files it has
- note in `state.json` that it has to be rebased onto the competing PR once that
  merges, and which files it adds.

## The same rule, for the issue itself
`Fixes #NNNN` in a body means the pull request claims the issue. When another PR
already carries that line, the issue is not available, no matter how good the work
is. The upstream bot's `in progress` label is applied with a delay and is not
authoritative; the claim that counts is the one in the body of an open PR.
