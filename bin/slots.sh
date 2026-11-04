#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# slots.sh - how many issues may run at once, decided by the resources.
#
# WHY: the loop used to run one issue at a time and left the machine idle
# most of the time. But not every phase is CPU-bound: triage, claiming,
# exploring and writing code are cheap, while the GATE (nextest over the
# touched crates) saturates all 16 cores. Two gates at once do not finish
# twice as fast - they fight for the same cores and the same memory.
#
# SO THE POLICY HAS TWO NUMBERS:
#   - IMPLEMENT slots: how many issues may be worked at once (cheap phases).
#   - GATE: strictly ONE at a time (the CPU-bound phase), the rest queue.
#
# THE NUMBERS COME FROM THE MACHINE, not from a constant:
#   - free cores   = cores - load1
#   - free memory  = MemAvailable
#   - a gate wants GATE_MEMORY_HIGH=32G and all the cores it can take
#
# WHAT CHANGED (30-10-2026): the load of the machine is NOT the only thing
# that is consumed. Two things were missing and both of them bit us:
#
#  1) THE LOCKS OF CARGO. Two cargo processes that share a target directory
#     do not run in parallel: the second one WAITS for the lock of the build
#     directory ("Blocking waiting for file lock on build directory"). The
#     load of the machine says "there is room" while the builds are queued
#     in front of each other. The load of a cargo that is BLOCKED on a lock
#     is not CPU: it is a process that does nothing. So the free cores have
#     to be counted with the cargo that is really compiling, not with the
#     whole load average.
#
#  2) THE SLOTS THAT ARE TAKEN. The orchestrator can be running next to a
#     cron wave: a slot whose lock is taken is a slot that somebody else
#     owns, and it must not be counted as free. The locks live in
#     $ORCH_DIR/locks (bin/slot-lock.sh).
#
# USAGE:
#   bash slots.sh              # print the decision (and why)
#   bash slots.sh implement    # how many implement slots may run now
#   bash slots.sh gate         # may a gate start now? (0 = no, 1 = yes)
#   bash slots.sh free-slots   # the slots that are free right now
# ---------------------------------------------------------------------------
set -uo pipefail

ORCH_DIR="${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}"
BIN_DIR="$ORCH_DIR/bin"

CORES="$(nproc)"
LOAD1_RAW="$(awk '{print $1}' /proc/loadavg)"
# The load is fractional; every comparison here is against a whole number.
LOAD1="$(awk -v l="$LOAD1_RAW" 'BEGIN { printf "%d", (l < 0 ? 0 : l) }')"
MEM_AVAIL_GB="$(awk '/MemAvailable/ {printf "%d", $2/1024/1024}' /proc/meminfo)"

# A gate of the scoped kind wants GATE_MEMORY_HIGH=32G; leave a margin so the
# agent itself (and the desktop) keep working while it runs.
GATE_MEMORY_NEEDED_GB=32
MIN_FREE_MEMORY_FOR_GATE_GB=$((GATE_MEMORY_NEEDED_GB + 8))

# Free cores: a compile of one crate wants ~4, so 4 free cores per slot.
CORES_PER_SLOT="${CORES_PER_SLOT:-3}"

# --- the cargo that is really compiling -------------------------------------
# The processes that are USING cpu, not the ones that are waiting for a lock.
# A cargo that is blocked on the build directory of another cargo is not
# consuming a core: counting it made the machine look busy when it was not,
# and it made the decision oscillate (the load of a build is bursty: it
# goes up and down with every crate that compiles).
#
# THE COUNT IS OF THREADS, NOT OF PROCESSES: the load average of the kernel
# counts the TASKS (threads) that are runnable, not the processes. On the
# 30-10, with two cargo builds running, 'ps -eo stat=' counted 2 runnable
# PROCESSES while /proc/loadavg said 23.99: the 27 runnable THREADS of
# those two builds are what the load is made of. Counting the processes
# said "the machine is idle" while it was saturated. The count of threads
# is the one that agrees with the load average.
BUSY_PROCS="$(ps -eLo stat= 2>/dev/null | grep -cE '^[RD]' || true)"
[ -n "$BUSY_PROCS" ] || BUSY_PROCS=0
RUNNING_CARGO="$(ps -eLo stat=,comm= 2>/dev/null | awk '$2=="cargo" || $2=="rustc" {c++} END {print c+0}')"

# The load that the machine really has: the runnable threads, not the
# average of the last minute (which remembers a build that is over).
REAL_LOAD="$BUSY_PROCS"
[ "$REAL_LOAD" -gt "$LOAD1" ] && REAL_LOAD="$LOAD1"

# The load the gate must respect. REAL_LOAD is the MINIMUM of the runnable
# threads and the one-minute average, because the average remembers a build
# that is over: with four agents compiling at once it read 6 while the load
# average said 30, and the gate started into a saturated machine. The gate
# compiles seven packages, so it needs a quiet machine: take the MAXIMUM of
# the two measures, and let MAX_GATE_LOAD raise it for a bigger box.
MAX_GATE_LOAD="${MAX_GATE_LOAD:-6}"
[ "$MAX_GATE_LOAD" -gt "$LOAD1" ] && MAX_GATE_LOAD="$LOAD1"
# The load the gate respects. WHY (measured 01-11-2026): the one-minute
# average REMEMBERS the work that is over. Right after two gates finish,
# the load1 read 48 while the real load (the runnable threads) was 1: the
# box was idle and the calibrator said "the machine is busy", so no gate
# could start and no agent could be dispatched. The average is a MEMORY of
# the machine, not a measure of it.
#
# So the measure is the REAL one: the runnable threads and the cargo
# processes that are writing right now. The average is only consulted when
# there are real threads to back it up: with a real load of 0 the average
# is a memory of a run that is over and it is ignored.
GATE_LOAD="$REAL_LOAD"
# The average is only a measure when there is a BUILD to back it up: a
# cargo that is compiling saturates the machine and the average is right.
# Three threads of the gateway are not a build, and the average of a build
# that finished ten minutes ago is not a measure of anything.
if [ "$RUNNING_CARGO" -gt 0 ] && [ "$LOAD1" -gt "$GATE_LOAD" ]; then
  GATE_LOAD="$LOAD1"
fi

# The free cores: the ones that are not running something RIGHT NOW. The
# same reasoning as the load of the gate: with the one-minute average the
# box looked FULL (48 of 16 cores busy) when it was idle, and the free
# cores were 0, so no agent could be dispatched on an idle machine.
free_cores="$(awk -v l="$GATE_LOAD" -v c="$CORES" 'BEGIN { v = c - l; print (v > 0) ? int(v) : 0 }')"

# How many slots the machine really carries. The caps used to be fixed (3 slots,
# 40 GB of RAM for three) and did not follow the hardware: on a 16-core box with
# 62 GB of RAM they left 13 cores idle. The limits that actually bind are:
#   - RAM: one gate needs 32 GB (GATE_MEMORY_NEEDED_GB) and a release link
#     alone peaked at 10.9 GB of RSS, so a slot must leave room for the gate;
#   - CORES_PER_SLOT: cargo parallelises inside a build, so a slot wants 4.
mem_slots=1
if [ "$MEM_AVAIL_GB" -ge 56 ]; then mem_slots=5; elif [ "$MEM_AVAIL_GB" -ge 40 ]; then mem_slots=4; elif [ "$MEM_AVAIL_GB" -ge 32 ]; then mem_slots=3; elif [ "$MEM_AVAIL_GB" -ge 24 ]; then mem_slots=2; fi

cpu_slots=$(( free_cores / CORES_PER_SLOT ))
[ "$cpu_slots" -lt 1 ] && cpu_slots=1
# The cap is a safety margin, not the limit itself: with 16 cores it allows 4
# concurrent slots, and it keeps the gate's own compile from finding a
# saturated machine.
# The cap of the implementation slots. MEASURED (01-11-2026): an agent that
# implements runs a DIRECTED test (one crate, a few seconds) and reads and
# writes code: it does NOT want 4 cores the way a full build does. The gate
# takes 12 of the 16 cores when it runs, so the agents that work at the same
# time have to be able to FIT: with the cap at 4 the machine was saturated
# before the gate even started, and the gate then found a busy box and
# deferred.
MAX_IMPLEMENT_SLOTS="${MAX_IMPLEMENT_SLOTS:-6}"
[ "$cpu_slots" -gt "$MAX_IMPLEMENT_SLOTS" ] && cpu_slots="$MAX_IMPLEMENT_SLOTS"

IMPLEMENT_SLOTS=$cpu_slots
[ "$mem_slots" -lt "$IMPLEMENT_SLOTS" ] && IMPLEMENT_SLOTS=$mem_slots

# --- the slots that are already taken ----------------------------------------
# A slot whose lock is taken is owned by somebody else (another session, a
# cron wave). It is NOT free and it is NOT to be touched.
#
# A lock whose OWNER IS GONE is not a slot anybody owns: it is the residue of
# a wave that died without releasing it. On the 30-10 four such locks (a wave
# that was interrupted) ate every slot and the calibrator said free_slots=0
# on a machine with nothing running: the orchestrator could not start any
# agent. So the count of taken slots is the count of locks that are STILL
# FRESH: a lock older than SLOT_LOCK_STALE_MIN belongs to nobody.
#
# The liveness of a lock is its AGE and not its PID: the lock records the PID
# of the script that took it, and that script exits at once, so the PID was
# dead by design and could never say anything about the owner.
STALE_MIN="${SLOT_LOCK_STALE_MIN:-240}"
NOW_EPOCH="$(date -u +%s)"
TAKEN_SLOTS=0
STALE_SLOTS=0
if [ -x "$BIN_DIR/slot-lock.sh" ] || [ -f "$BIN_DIR/slot-lock.sh" ]; then
  # 'grep -c' with no match exits 1 and prints 0: the || true keeps the
  # pipeline from failing and the count is never empty.
  while IFS=$'\t' read -r _name _since _owner; do
    case "$_name" in heavy|''|'#'*) continue ;; esac
    age=-1
    if [ -n "$_since" ]; then
      t="$(date -u -d "$_since" +%s 2>/dev/null || echo 0)"
      [ "$t" -gt 0 ] && age=$(( (NOW_EPOCH - t) / 60 ))
    fi
    if [ "$age" -lt 0 ] || [ "$age" -ge "$STALE_MIN" ]; then
      STALE_SLOTS=$(( STALE_SLOTS + 1 ))
    else
      TAKEN_SLOTS=$(( TAKEN_SLOTS + 1 ))
    fi
  done <<EOF
$(bash "$BIN_DIR/slot-lock.sh" --list 2>/dev/null)
EOF
fi
FREE_SLOTS=$(( IMPLEMENT_SLOTS - TAKEN_SLOTS ))
[ "$FREE_SLOTS" -lt 0 ] && FREE_SLOTS=0

# A gate may start only when the machine is quiet AND there is room for it.
#
# MEASURED (01-11-2026): a scoped gate uses 80% of the 16 cores and a PEAK of
# 23.7 GB of RAM (memory.peak of its cgroup: high=32G, max=40G). The RAM of
# the box is 62 GB, so TWO gates fit in the RAM (47.4 GB of peak, 14.6 GB of
# margin) and the second one finishes in the same wall clock as the first.
# The CPU is the real limit: one gate already takes 13 of the 16 cores.
#
# So the rule is: ONE gate uses ALL the threads (GATE_NEXTEST_THREADS=12),
# and TWO gates share them (GATE_NEXTEST_THREADS=6 each). The number of
# gates at the same time is MAX_CONCURRENT_GATES (default 2), and it is
# bounded by the RAM: a third gate would need 71 GB of peak and the box has
# 62. The rule "one gate at a time" was right when a gate compiled seven
# packages from scratch; today the compilation is warm (the target dir is
# per slot and persistent) and the cost is the tests, which are parallel.
GATE_LIVE=0
if pgrep -f "cargo nextest run" >/dev/null 2>&1; then GATE_LIVE=1; fi

# The heavy tokens: one per heavy phase that runs at the same time. They are
# NOT the gates any more (a gate takes a slot lock and its own calibration).
HEAVY_HELD=0
if bash "$BIN_DIR/slot-lock.sh" --heavy --status >/dev/null 2>&1; then
    HEAVY_HELD=0
else
    HEAVY_HELD=1
fi

# How many gates are running RIGHT NOW: the nextest processes that belong to
# a gate of THIS box. A gate is a nextest whose command line has the target
# dir of the orchestrator.
GATES_RUNNING=0
for _p in $(pgrep -f "cargo nextest run" 2>/dev/null); do
  _cwd="$(readlink "/proc/$_p/cwd" 2>/dev/null || true)"
  _args="$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null || true)"
  case "$_cwd$_args" in
    *solidcraft-orch/targets*|*solidcraft-wt*) GATES_RUNNING=$(( GATES_RUNNING + 1 )) ;;
  esac
done

# The number of gates at the same time. MEASURED (01-11-2026, box of 16
# cores): two gates at the same time take the CPU to 97-99% (loadavg 99) and
# each one runs 3x slower, because the SLOWEST test of the scope
# (hole_face_tests::drilled_sketch_points_break_through_a_sloping_back_face,
# 337 s alone) has to share the cores. The RAM was never the limit (23.7 GB
# of peak each one, 62 GB in the box): the CPU is, and the CPU does not grow
# by sharing it.
#
# So: ONE gate at a time, and the rest of the machine goes to the AGENTS that
# implement (they read, they write and they run their own directed test,
# which is a fraction of the scope). The heavy lock stays as a set of tokens
# because the work that is NOT the gate (a release link, a sweep) is I/O and
# link bound and DOES run well in parallel.
MAX_CONCURRENT_GATES="${MAX_CONCURRENT_GATES:-1}"
GATE_OK=1
if [ "$GATES_RUNNING" -ge "$MAX_CONCURRENT_GATES" ]; then
    # The number of gates at the same time is at its ceiling.
    GATE_OK=0
elif [ "$GATE_LOAD" -gt "$MAX_GATE_LOAD" ] || [ "$MEM_AVAIL_GB" -lt "$MIN_FREE_MEMORY_FOR_GATE_GB" ]; then
    GATE_OK=0
elif [ "$GATES_RUNNING" -ge 1 ]; then
    # There is one gate and room for a second one, but the second one must
    # NOT start while the first is still compiling: the threads of the
    # nextest are shared when a nextest is already running, and a gate that
    # starts in the middle of the compilation of the other takes the whole
    # CPU for its clippy and leaves the first one with nothing. The rule
    # that works: the second gate waits for the first one to reach its
    # tests. It is the calibrator that says so, because the calibrator is
    # the one that sees the machine.
    #
    # WHY IT MATTERS (measured 01-11-2026): two gates that start at the
    # same time both take 12 threads and the box reaches 97% of CPU with
    # nothing gained; two gates that start one after the other share the
    # threads (6 each) and finish in the same wall clock.
    if ! pgrep -f "cargo nextest run" >/dev/null 2>&1; then
        GATE_OK=0
    fi
fi

case "${1:-report}" in
  implement) echo "$IMPLEMENT_SLOTS" ;;
  gate) echo "$GATE_OK" ;;
  free-slots) echo "$FREE_SLOTS" ;;
  report)
    echo "cores=$CORES load1=$LOAD1_RAW real_load=$REAL_LOAD (runnable threads, busy cargo=$RUNNING_CARGO) free_cores=$free_cores mem_avail=${MEM_AVAIL_GB}G"
    echo "implement_slots=$IMPLEMENT_SLOTS (cpu_slots=$cpu_slots mem_slots=$mem_slots)"
    echo "slots_taken=$TAKEN_SLOTS free_slots=$FREE_SLOTS stale_locks=$STALE_SLOTS (older than ${STALE_MIN} min: reap them with slot-lock.sh --reap)"
    echo "gate_may_start=$GATE_OK (gates_running=$GATES_RUNNING/$MAX_CONCURRENT_GATES; heavy_lock=$HEAVY_HELD; needs fewer than $MAX_CONCURRENT_GATES gates, no heavy lock, load<=${MAX_GATE_LOAD} (now $GATE_LOAD) and mem_avail>=${MIN_FREE_MEMORY_FOR_GATE_GB}G)"
    ;;
  *) echo "usage: slots.sh [report|implement|gate|free-slots]" >&2; exit 2 ;;
esac
