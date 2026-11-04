# Reclaiming disk and RAM on a dedicated build box

The box runs one long job, so every finished artifact is waste the moment its slot closes. The
order of magnitude is what tells you where to look first: a scoped gate compiles the whole
touched scope, so one slot's debug profile is tens of GB, the compilation cache is tens of GB
more, and the app's release build is a few GB.

The loop's own `gc-disk.sh --stale-targets [--dry-run]` collects the obvious targets. This
recipe is for what it misses: the release builds, the caches, the scratch of other tools, and
the rule for when a merged slot's work may be deleted.

## Audit before deleting anything
    df -h /home/user
    du -sh --max-depth=1 /home/user/.local/share /home/user/.cache 2>/dev/null | sort -rh
    du -sh /home/user/.local/share/solidcraft-orch/targets/*/ 2>/dev/null | sort -rh

`du` over a big tree can outlast a foreground timeout: run it with `timeout` and a generous
budget, or in the background. Never remove a path you have not just seen the size of, and
never remove a path a live build is writing into.

## What is safe to delete, and when
| Path | Delete when | Note |
|---|---|---|
| a slot's `debug/` profile | its PR is merged or abandoned | rebuilds in minutes |
| a slot's `release/` | the slot is closed AND nothing is owed | the LTO link takes tens of minutes; keep it while a screenshot is still owed |
| a slot's whole target dir | the slot is closed, OR the size cap is exceeded and its cache is cold | an open PR does NOT retain its target forever |
| the slot's worktree | the PR is merged or abandoned | `git worktree remove --force` |
| the fork branch | the PR is merged or abandoned | `git push fork --delete <branch>` |
| the compilation cache | its hit rate is ~0 | pure loss; stop the server first, it rewrites the dir |
| an unused rustup toolchain | nothing selects it: no toolchain file, no `cargo +<name>` | `rustup toolchain uninstall` |
| package caches (npm/pip/gh) | always | regenerable |
| stale scratch under /tmp | no live process holds it open | it is tmpfs: RAM, not disk |

## An OPEN PR does not retain its target forever
A target dir is tens of GB and an open PR can sit for days, so a rule that keeps the target of
every open PR pins the disk at the cost of every new slot. The reclaim is a CAP, not a
condition: when the whole target tree passes its size cap, the targets are released oldest
first, and only the ones that are safe to release — no live build writing into them, no slot
holding them, no work in flight, and their cache COLD (no activity for hours). A live lock or
a running build is never released, whatever the cap says.

The age threshold is what makes the cap safe: a cache touched minutes ago is the one a running
agent is using, and a target quiet for hours is rebuildable. The cap is about the TARGET
TREE exceeding its ceiling, not about a single slot being old.

Before deleting a target that a PR still points at, check that the PR's head is reachable
elsewhere (the fork branch, or a `wip` branch): the target is a cache, and the branch is the
work.

## Verify before deleting a merged slot's work
A merged PR does not prove the work survived. The maintainer squashes, so the upstream SHA
differs from yours and an ancestor check on the SHA reports a false negative. Compare the
CONTENT instead:
    git diff <your-sha> origin/main -- crates/<the files you touched>
An empty diff means the change is upstream, and only then delete the worktree, the target and
the branch. A non-empty diff means the change was reformatted or dropped upstream: keep the
branch and say so in the report.

## Verify before deleting a worktree whose PR is still OPEN
An open PR's work is not upstream yet, so the check above says nothing about it. Before
removing a worktree of an OPEN PR, prove the fix is somewhere durable — the fork's branch
for the PR, or a `wip` branch with the diagnosis:

    git ls-remote fork 'refs/heads/*' | grep <the-branch>

A worktree at a commit the fork does NOT have is work that exists ONLY there, and deleting
it loses it. This matters more than it looks because a rebased branch and the local worktree
carry DIFFERENT SHAs for the same change: the fork has the rebased commit and the worktree
sits on the pre-rebase one. The fork is the durable copy, so the worktree is disposable —
but check the FORK, never assume that the worktree's own HEAD is the thing that matters.

And the worktrees of ANOTHER session are not yours to remove. A worktree whose commit is on
no branch of the fork and whose PR is not yours is somebody's pending work: leave it, and
say in the report that it was left.

## Deleting the worktree is not deleting the branch
`git worktree remove` frees the directory; the branch and the fork copy of the work stay.
Remove the fork branch only when the PR is merged or the work is superseded, and never
remove a branch the PR still points at — a PR whose branch is deleted shows up upstream as
a PR that cannot be updated, and it cannot be marked ready.

## Keep
- the gate verdict files and the gate logs: they are the evidence behind every "VERDE-SCOPE";
- the RED/GREEN logs of issues whose PRs are still open;
- the release binary of any slot whose visual evidence is still owed;
- the tool binaries under the agent's tools dir (browser, chromium, node, python): they are the
  tooling, not a cache.

## The scratch of another tool is often the biggest win
A scratch dir left by a DIFFERENT tool can be the single largest consumer, and it stays
invisible if you only audit your own paths. Check whether anything holds it open before
removing it:
    pgrep -af <tool>
    lsof +D <dir> 2>/dev/null | head
A directory that reappears right after you delete it has a live writer: find that writer
before retrying, do not loop the deletion.

## Verify the machine is still healthy afterwards
    df -h /home/user
    bash bin/slots.sh report
    ps -eo pid,etimes,args | grep -E 'cargo (build|test)' | grep -v grep
A cleanup that interrupts a running build costs more than the space it frees. And `pkill -f`
also matches the shell issuing it (exit -15): signal the resolved PID instead.
