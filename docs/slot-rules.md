# Slot rules

(The body of the `## Slot rules` section of the orchestrator skill. Kept in a
reference so the SKILL.md stays inside the size limit.)

- One issue per slot, max 2-3 concurrent implementation slots.
### Each subagent gets its OWN worktree named for its issue. Two agents never share a directory.
- An agent that changes branches in the MAIN checkout (/home/user/solidcraft) leaves the whole
  system on its branch: every later verification then reads the wrong code. The agent's own
  worktree is the only place it may change branches. If the main checkout is found on a
  feature branch, the orchestrator moves it back to main (after checking the tree is clean)
  and fast-forwards it to origin/main.
- A main checkout with hundreds of files STAGED and nothing committed is an agent's
  `git add -A`, not a change anyone decided to make. It is not ours to commit and it is not
  ours to discard: preserve it as a diff under the orchestrator's logs and leave the index
  alone. A commit there puts a change of unknown authorship onto main, and `git reset`
  destroys the only copy of the work.
- The orchestrator must not move the main checkout while an agent is working IN it: the
  agent's next commit then lands on the branch the orchestrator just moved to, and the
  commit ends up on `main` instead of the agent's branch. Before moving it, check whose
  worktree it is. The recovery when it already happened is cheap and does not lose the
  commit: `git branch -f <agent-branch> <sha>` to put the commit back on its branch, then
  reset the shared branch to the commit it should be on, and let the agent push it itself.
  The agent will usually notice and repair it on its own; do not fight it for the tree.
- The STASH is shared by every worktree of the repo: `refs/stash` is ONE ref per repository,
  not per worktree. So an agent that runs `git stash` to park its work, and another agent
  (or the orchestrator) that runs `git stash pop`, takes the FIRST entry of a list the other
  one put there — the parked work lands in the wrong worktree, and the agent that parked it
  finds an empty tree. Never `git stash` in a repo other agents share: park the work as a
  COMMIT on the agent's own branch instead (`git add -A && git commit`), which is
  recoverable and cannot be popped by anyone else.
- A slot whose work died without a PR: note it in state.json and free the slot.

### The number of slots follows the hardware, not a fixed number
`slots.sh` used to cap the implementation slots at 3 and to want 40 GB of RAM for three: on a
16-core box with 62 GB that left 13 cores idle while the orchestrator waited for a free slot.
The limits that actually bind are RAM and the gate, not a number someone typed:
- CPU: `free_cores / CORES_PER_SLOT` (4), capped by `MAX_IMPLEMENT_SLOTS` (4) as a margin.
- RAM: scale it — 56 GB -> 5 slots, 40 -> 4, 32 -> 3, 24 -> 2. A scoped gate needs 32 GB
  and a release link alone peaked at 10.9 GB of RSS, so a slot must leave room for the gate.
- The GATE is the serialized part: it compiles seven packages and saturates the machine, so
  one gate at a time. The `--heavy` lock is that turn token, and the calibrator now reports
  `gate_may_start=0` while it is held.
- The load the gate respects is the MAXIMUM of the runnable threads and the one-minute
  average, not the minimum: the average remembers a build that is over, so with four agents
  compiling at once the minimum read 6 while the real load was 30, and the gate started into
  a saturated machine. `MAX_GATE_LOAD` (default 6) raises the bar for a bigger box.

When you raise the cap, update the test that checks it: assert the CONTRACT (a number, within
the cap, within what the cores allow), not the literal number, or it fails again on a bigger
box.

### MEASURED: what a gate really costs, and why ONE gate at a time was wrong
The numbers of a scoped gate on this box (16 cores, 62 GB), measured 01-11-2026:
- CPU: 80% of the 16 cores (12 nextest threads), verified with `top` and not with the
  loadavg.
- RAM: a PEAK of 23.7 GB (`memory.peak` of its cgroup). The box has 62 GB, so TWO gates fit
  (47.4 GB of peak, 14.6 GB of margin) — the RAM was never the limit.
- The loadavg reads 47-55 while the gate runs, and that is REAL: `D`-state processes are 0,
  so it is not an I/O artifact.
- The wall clock does NOT scale with the number of tests: 2553 tests took 1060 s and 7724
  took 1360 s. The gate is bounded by the SLOWEST test (377 s for
  `hole_face_tests::drilled_sketch_points_break_through_a_sloping_back_face`) and by the
  clippy+check of the workspace, not by the count.
- `memory.high` of 32G with `memory.max` of 40G means a SECOND gate asks for 64 GB of
  demand on 62 GB of RAM and the OOM killer takes a test binary — which reads as a RED
  gate. The belt of the gate is now 26G/32G so two gates fit.
- `GATE_QUICK_TIMEOUT_MIN=30` was too small: the gate of the slot 7114 took 33m43s and
  ended `DEFERRED=nextest-timeout`. A deferral is not a red, but it throws away an hour of
  work. The ceiling is now 60.

**TWO GATES AT THE SAME TIME DO NOT DOUBLE THE THROUGHPUT.** Measured: two gates take the
CPU to 97-99% (loadavg 99) and each one runs 3x slower, because the slowest test of the
scope is a single process and no thread count makes it faster. The CPU is the limit and the
CPU does not grow by sharing it. So the calibration is ONE gate (`MAX_CONCURRENT_GATES=1`)
with the nextest at 8 threads (the scope finishes in the same time as with 12), and the
freed cores go to the AGENTS that implement at the same time. The throughput comes from
more agents working while one gate runs, not from more gates.

The heavy lock is now a SET OF TOKENS (`MAX_HEAVY_TOKENS`, default 2) and not a single lock:
a token named after the caller would never collide, and then the ceiling would not be a
ceiling. The tokens are shared and counted, and the release frees the token that the caller
recorded in `locks/heavy/token`.

### The load average is a MEMORY of the machine, not a measure of it
The calibrator used the one-minute average as the load of the box. Right after two gates
finished, the average read 48 while the real load (the runnable threads) was 1: the box was
IDLE and the calibrator said "the machine is busy", so `free_cores=0`, `implement_slots=1`
and `gate_may_start=0`. On a box that had just finished its work, the orchestrator refused
to dispatch an agent and refused to start a gate.

The measure is the REAL one: the runnable threads that are burning a core RIGHT NOW. The
average is only consulted when there is a BUILD to back it up (`RUNNING_CARGO > 0`), because
a cargo that compiles saturates the machine and the average is right about it, while the
average of a build that finished ten minutes ago is a memory of a run that is over. With
that fix, an idle box reports `free_cores=15`, `implement_slots=5`, `gate_may_start=1`.

### The scope of the TESTS is narrower than the scope of the COMPILATION, and that is the design
`affected.py` with the dependents answers 3 packages for a change of 4 files; the NARROW
scope (the packages whose directory holds a changed file) is 1. The nextest must run on the
narrow one: the dependents still have to COMPILE (the clippy and the check of the workspace
keep the whole scope, so a dependent that does not compile is still red), but their TESTS
are not the tests of the change. Running them is what makes the gate of a small change cost
as much as the whole workspace: 8400 tests instead of 4477.

The knob `NEXTEST_INCLUDE_DEPENDENTS=1` widens the scope of the tests to the dependents. It
was turned ON by default and it contradicted the design of the gate. It is OFF by default,
and the rule that says so is a test (`42. the tests run only on the crate that was touched`).

**MEASURED, AND IT IS NOT THE WIN IT LOOKS LIKE.** The same commit gated twice:
- the wide scope (7 packages, 12 threads): 7724 tests, nextest 1360 s, gate 33m43s;
- the narrow scope (2 packages, 8 threads): 7278 tests, gate 35m56s.

The narrow scope ran 446 FEWER tests and took TWO MINUTES LONGER. The reason: the narrow
scope of a change in `crates/engine` or `crates/ui-egui` is STILL most of the tests (7278 of
7724), because `solidcraft-engine` alone carries them. The narrowing pays off when the
touched crate is small; when it is the big one, the gate costs the same and the scope
argument is decoration. So the narrowing is the RIGHT default (it is the design, and it does
help on the small crates) but it is NOT where the time of the gate goes.

**Where the time of the gate goes: the clippy and the check of the workspace**, which are
not narrowable (a dependent that does not compile is still red). The nextest is bounded by
its slowest test (`hole_face_tests::drilled_sketch_points_break_through_a_sloping_back_face`
took 337 s alone), and no thread count makes a single slow test faster. That is why the
gate needs 60 minutes and not 30, and why the throughput comes from more agents working
while ONE gate runs, not from a faster gate.

### The worker's own scope caps the memory: a big cargo test gets OOM-killed
Hermes caps every worker scope at 4 GiB (`_WORKER_MEMORY_MAX_CAP_BYTES`) and the OOM killer
takes the build down with SIGTERM (exit 143) and NO error message. That is why a `cargo test` of
`solidcraft-ui-egui` in the `ci` profile dies with 143 and no error message: the agent reads it
as a timeout and burns its budget on it again. Read `journalctl` and you will find `oom-kill`
there, which is how the agent that confirmed it found it.
The gateway scope itself is NOT capped (`MemoryMax=infinity` on hermes-gateway.service), so the
fix is to run the heavy command in its own scope:
    systemd-run --user --scope --quiet --unit=orch-<issue>-<what> \
      -p MemoryMax=24G -p MemorySwapMax=0 -p OOMPolicy=continue \
      -- cargo test -p solidcraft-ui-egui --profile ci --lib <test>
(24 GB is enough for solidcraft-ui-egui in the ci profile; the build takes about 7 minutes.)
The gate already does this for itself (it has its own scope with MemoryMax=40G), which is why
the gate survives a build that kills the agent's own cargo.
Give this to the agents in the brief: a build that dies with 143 is the scope, not the code.

### A cold slot target can be warmed from another slot's cache
A slot whose target dir is empty pays the full build again (~11m40s measured). The `ci` profile
of the SAME repo can be copied from another slot that already has it:
    cp -a targets/slot-6449/ci/. targets/slot-<n>/ci/
The crate paths are the same (same repo, same profile), so cargo reuses the artifacts instead of
recompiling the world. That is the same saving the per-slot target dir was invented for, applied
once to a slot that starts cold.

### Heavy work is serialized: stop the app build before the gate runs
A scoped gate compiles the whole touched scope, and a release app build in parallel on top of
it drives the machine's load toward the OOM/disk-pressure zone. When a gate is running, stop
any other heavy build you started (an app build for visual evidence, another slot's build) and
let the gate finish first. Watch `/proc/loadavg`: past ~24 the machine is one parallel compile
away from thrashing, and a thrashing gate does not finish — it just burns its budget and comes
back deferred.

### Kill a build by PID, never by pattern
`pkill -f 'cargo build --release'` matches its own command line and kills the shell issuing it
(exit -15, the tool call dies, the build survives). Resolve the exact PID and signal that one:
`kill -TERM <pid>`. The pattern form is the trap because the shell's own argv contains the
pattern it is searching for.

### Two agents that share a CARGO_TARGET_DIR serialize on Cargo's build lock, SILENTLY
Cargo takes an EXCLUSIVE lock on a build directory. Two agents that compile in the same
target dir do not run in parallel: the second one waits for the first, and the symptom is
not an error — it is a `Blocking waiting for file lock on build directory` line in the log
followed by minutes of nothing, with no failure anywhere. The agent reads the silence as a
slow build and spends its budget waiting. So every agent gets its OWN target dir, named
after its issue, and the brief says so explicitly. A build that was still alive under a
scope that died leaves ORPHAN compiler processes running with no owner: after any agent or
scope dies, look for live `cargo`/`rustc` and end them by PID.

### A lock with no worktree behind it is a lock that a DEAD agent left, and it eats a slot
On 01-11-2026 an agent took the lock of the issue #9961 ("FLANGE: operation failed", `area:kernel`), and the kernel is PAUSED: the agent could not do anything and left the lock behind. There was no worktree, no branch and no commit: just the lock, taken, forever. The next agent for that slot would have found it busy and waited.

The check before reaping: a lock whose owner is dead AND whose slot has no worktree and no branch is a lock to release. `slot-lock.sh --slot <N> --release` does it. The reap by age would also do it, but it waits for SLOT_LOCK_STALE_MIN (4 hours) for nothing.

**The kernel pause has to be checked at the ISSUE level and at the FILE level, and they are not the same thing.** The issue #10719 ("A path flange doesn't actually follow the path") has NO `area:kernel` label, but `grep flange crates/` finds it in `crates/kernel/src/blend.rs`, `prism.rs`, `ops.rs` and `coplanar.rs`. An agent that reads the labels alone takes the issue and walks into the paused area. The check is: does the FIX belong to the paused area? The command that fails can live in `crates/engine/src/cmd/` and the primitive it uses in `crates/doc/`, and the fix can be in either of those without touching the kernel at all. So the rule is not "the issue is banned" but "the FILES of the fix are banned".

A subagent that has to be told this mid-flight will sometimes already have a lock on an issue it cannot work on. The steer has to say both: where the code actually is, and to release the lock if the issue turns out to be unworkable.


### A target dir is free only when NOTHING points at it, and the mtime lies
A `nextest` that runs already-built binaries only READS them and never touches the dir, so
a slot with a live agent looks idle and a target dir that was in use a second ago looks
free. The reliable test is a live `cargo`/`rustc` whose args point at that dir, OR an agent
that still owns the slot — NOT the timestamp.

Deleting the target of a live slot buys a few GB and costs a full rebuild of the world, and
it corrupts the run in progress: the test binaries disappear under the gate that is running,
and every test is reported as `double-spawn failed to exec ... No such file or directory`.
A gate that ends with thousands of those and no `panicked at` and no failed assertion is not
a red gate — it is infrastructure damage, and the honest move is to restore the target and
run the gate again, NOT to open a PR on that verdict.

### The gate needs a QUEUE, because its own wait is bounded
`gate.sh` takes the build token with `--take --wait 1800`: with the two slots of the box
busy it waits half an hour and then dies with `no free build slot`, having compiled
nothing. With four gates pending, every one of them expires on its own and has to be
relaunched by hand, and the failure looks like a problem with the change when it is a
problem with the queue.

So the wait belongs in the QUEUE, not inside the gate: `gates/queue.txt` plus
`bin/gate-queue.sh --enqueue <issue> <sha>` / `--list` / `--run`, where the runner waits for
a free slot and then starts the gate. Two gates then never fight over the same slot, and no
gate expires while its turn is legitimate. The runner takes a lock (atomic mkdir) because a
cron calls it repeatedly, and a cron calls a script with NO arguments — so the script's
DEFAULT branch has to be the useful one.

### A token or a lock whose holder died stays taken FOREVER
Two traps that make the queue look like it is WAITING when it is actually dead, both hit
on 2026-11-03:

- `build-slot.sh --release <token>` did `rm -rf "$2"`, a RELATIVE path that never existed,
  so NO token was ever released: the two slots of the box stayed taken from 02:18 on, with no
  owner and no build running, and every gate that waited for one died with
  `no free build slot`. The release has to delete the REAL path of the lock
  (`$LOCK_DIR/$2`), and it has to accept BOTH forms of the token: the NAME (`slot-1`) and
  the full PATH (`/…/build-slots/slot-1`), because an agent that takes the token by hand
  releases it with the path it was given. A release that understands only one of them
  leaves that token taken forever.
- The runner's lock was released by a `trap EXIT`, and a runner killed with SIGTERM or
  SIGKILL never runs it: the lock stayed taken and the queue stopped. A lock has to be
  releasable when it is OLD and its owner is GONE, and the trap needs a TERM/INT arm.

The liveness of a lock or a token is its AGE and its OWNER, never its PID: the PID belonged
to the script that took it and was dead by design. Before declaring the box busy, check
whether a live `cargo`/`rustc` points at that slot.

### A status line parsed with a greedy regex yields the WRONG field
`build-slots: 0 used of 2` read with `sed 's/.*used of \([0-9]*\)/\1/p'` for the free count
and the same pattern for the total returns 2 for BOTH: the runner concluded the box was full
and never started a gate, with the box empty. Parse a status line by FIELD POSITION
(`awk '{print $(NF-3), $NF}'`), and after renaming a variable check that the comparison that
uses it still means what the name says: renaming a count from "used" to "free" leaves its
comparison inverted, and the guard that announces "no slot free" fires exactly when there
are slots.

### The box is SHARED: the compilations are the FILLER and they sit at the bottom
The cargo config of the machine says it in a comment: it is shared, wait when the load is
high, and compile with `nice -n 19`. The orchestrator obeys the same rule: the interactive
work (the agent, the gateway, the phases of the gate) gets the CPU, and the compilations fill
the gaps. Nice only decides the order among the tasks that WANT the CPU, so a compilation at
19 still gets a whole core when the box is idle — priority does not cost idle time.

**A one-shot `renice` is not enough.** `rustc` processes are born and die continuously, so
every compilation started after the renice comes back at priority 0. Keep the priority with a
PERIODIC job instead: a small script that renices the `cargo`/`rustc` processes to 19, run
from a cron every couple of minutes with `--no-agent` (zero tokens).

**The cron that keeps the priority is a script with NO arguments.** A cron calls the script
with no arguments, so the script's DEFAULT branch has to be the useful one (a script that
only prints its usage leaves the job doing nothing, silently, forever), and the script has to
exist in `~/.hermes/scripts/` BEFORE the job is created: the file is resolved at creation
time and the create fails with "Script file not found". The path passed to `--script` is
RELATIVE to that directory.
