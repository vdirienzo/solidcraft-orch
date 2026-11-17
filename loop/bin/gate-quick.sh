#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gate-quick.sh: the SCOPED gate. It checks the packages the change touches
# and it is NOT the gate that publishes.
#
#   gate-quick.sh [--slot <name>] <base-ref> <sha>
#   gate-quick.sh --scope-probe
#
# Why a scoped gate: the complete gate (cargo xtask ci) takes 50-75 min and
# does not fit in a 55 min turn. This one checks only the packages the change
# touches (scripts/ci/affected.py) and takes 1-5 min.
#
# What it runs, in this order:
#   1. cargo fmt --all -- --check                    (the whole repository)
#   2. cargo xtask layers                            (the whole repository)
#   3. cargo clippy -p <pkg>... --all-targets --profile ci --locked -- -D warnings
#   4. cargo nextest run -p <pkg>... --cargo-profile ci --locked --profile local-ci
#      --no-tests=pass --retries 0 --test-threads <n> --ignore-default-filter -E '<filter>'
#
# The scope of the tests of the step 4 is the package whose directory holds
# the changed file. With NEXTEST_INCLUDE_DEPENDENTS=1 it is also the
# packages that DEPEND on it (the answer of scripts/ci/affected.py).
#
# The nextest command is the one of the upstream CI (.github/workflows/ci.yml)
# with the local profile: `local-ci` inherits `ci` and adds the priorities and
# the windows-gpu group. The filter is the one of a pull request: it leaves
# out the action matrix sample and the GPU path tests. The filter is checked
# against the metadata of the WHOLE workspace, so the expression is the same
# whatever the scope is.
#
# The clippy is scoped on purpose: the upstream does NOT run it for a pull
# request without the approved-for-ci label (ci.yml), and a lint failure
# published by the loop would be found too late.
#
# The belt: the run happens inside a TRANSIENT SCOPE of the user manager
# (systemd-run --user --scope), with the memory, the cpu, the io and the
# tasks of the run bounded. The supervisor launches this gate in the
# foreground, so it inherits the cgroup of the supervisor
# (solidcraft-loop@0.service), whose memory.high and memory.max are "max":
# without the scope a heavy test can take the whole host (62 GB, no swap)
# and the global OOM killer can kill the opencode of the loop (the brain of
# the turn) instead of the test. The complete gate has the same belt
# (bin/start-gate.sh creates a transient unit with MemoryHigh=32G and
# MemoryMax=40G): this one runs 19 times a day and it was the only one
# without a limit.
#
# The belt NEVER decides anything: it only bounds the run. When the scope
# cannot be created the gate runs without it (fail open), and the verdict
# of the run is the one it always was.
#
# The probe (--scope-probe) is the check of the belt without a gate: its exit
# code is the code of a diagnostic, 0 when the belt is in force and 1 when it
# is not. The probe does not judge the gate.
#
# The verdict: TWO files, one authoritative.
#
#   $LOOP_DIR/gates/<slot>/scope.verdict   (NEW, authoritative, per slot)
#     GATE_STATUS=finished|failed|skipped
#     SCOPE=<package names separated by spaces>
#     SCOPE_KIND=packages|full|empty
#     VERDICT=VERDE-SCOPE|ROJO-SCOPE|SKIP
#     NEW_FAILURES=<n>
#     FAILED_TESTS=<crate::test names, comma separated>
#     CHECKS=fmt:ok|layers:ok|clippy:ok|check:ok
#     SHA=<sha>
#     AT=<epoch>
#
#   $LOOP_DIR/gate.quick.verdict   (legacy, global, the format it always had)
#     GATE_STATUS, SCOPE, VERDICT (VERDE-PARCIAL|ROJO-PARCIAL|SKIP),
#     NEW_FAILURES, PUBLISHABLE=no, SHA, AT
#
# The legacy file is a MIRROR of the same run: the supervisor, the metrics and
# the dry run read it and keep working. PUBLISHABLE=no stays there: that file
# alone never publishes.
#
# The publication decision is NOT in these files: it is DERIVED by
# bin/state.py. A verdict file never carries a publish boolean.
#
# The verdict of the tests is NOT computed here: the log of the run is judged
# by bin/gate-check.sh, the only parser of the loop. A second parser is a
# second opinion about the same log, and the first one (the libtest parser
# that lived in this script) gave false greens.
# ---------------------------------------------------------------------------
set -uo pipefail

# The marker of the scope: the child of the scope touches it as its FIRST
# action, so the parent knows that the scope was really there. When the
# marker is there the child ran, so the parent NEVER runs the gate twice.
if [ -n "${SC_QUICK_SCOPE_MARKER:-}" ]; then
  : > "$SC_QUICK_SCOPE_MARKER" 2>/dev/null || true
fi

REPO="${SOLIDCRAFT_REPO:-${REPO:-/home/user/solidcraft}}"
LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
BASELINE="${BASELINE_FAILURES:-$LOOP_DIR/baseline-failures.txt}"
# The parser of the loop reads the known failures from the same place.
export BASELINE_FAILURES="$BASELINE"
VERDICT_FILE="$LOOP_DIR/gate.quick.verdict"
GATES_DIR="$LOOP_DIR/gates"
# The ceiling of the run. MEASURED (01-11-2026): the scoped gate of the slot
# 7114 took 33m43s with the narrow scope, and with a ceiling of 30 min it
# ended DEFERRED=nextest-timeout: the work of an hour thrown away because
# the clock ran out. The ceiling is 60 min, and the config.env says the same
# number (the test checks that the two agree).
TIMEOUT_MIN="${GATE_QUICK_TIMEOUT_MIN:-60}"
# The threads of the nextest are a SHARE when another gate is running at the
# same time. WHY (01-11-2026, measured): one gate alone takes 13 of the 16
# cores and a peak of 23.7 GB of RAM; two gates at the same time fit in the
# RAM (47.4 GB of 62) but they share the CPU, so each one takes half of the
# threads. Without this, two gates with 12 threads each fight for the cores
# and both finish later than they should.
#
# IT IS CALLED JUST BEFORE THE NEXTEST, and not at the top of the script: the
# other gate is only visible when it is RUNNING ITS TESTS. A gate that
# computes it at the beginning sees no nextest at all (its own has not
# started) and uses all the threads, and that is how two gates ended up with
# 12 threads each and the box at 99% of CPU with nothing gained.
gate_share_threads() {
  [ "${GATE_SHARE_THREADS:-auto}" = "auto" ] || return 0
  local _other=0 _p _cwd _args
  for _p in $(run_child pgrep -f "cargo nextest run" 2>/dev/null); do
    _cwd="$(run_child readlink "/proc/$_p/cwd" 2>/dev/null || true)"
    # the nextest of THIS gate is not another gate: it is the one this
    # script is about to launch, and it runs from the worktree of this slot
    case "$_cwd" in
      "$REPO"|"$REPO"/*) continue ;;
    esac
    _args="$(run_child tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null || true)"
    case "$_cwd$_args" in
      *solidcraft-orch/targets*|*solidcraft-wt*) _other=$(( _other + 1 )) ;;
    esac
  done
  if [ "$_other" -gt 0 ]; then
    NEXTEST_THREADS=$(( NEXTEST_THREADS / (1 + _other) ))
    [ "$NEXTEST_THREADS" -lt 2 ] && NEXTEST_THREADS=2
    echo "gate-quick: another gate is running: the tests use $NEXTEST_THREADS threads" >&2
  fi
}
# The threads of the nextest. MEASURED (01-11-2026, box of 16 cores): the
# gate alone with 12 threads takes 80% of the CPU, and the SLOWEST test of
# the scope (hole_face_tests::drilled_sketch_points_break_through_a_sloping_
# back_face, 337 s alone) is what decides the wall clock: the run is bounded
# by the slowest test, not by the number of threads. So the gate does NOT
# need 12 threads: 8 finish the scope in the same time that 12 would (the
# slowest test is a single process and no thread count makes it faster),
# and the 4 threads that are freed go to the agents that implement at the
# same time. That is where the throughput comes from: not more gates (the
# CPU is the limit) but more agents working while ONE gate runs.
NEXTEST_THREADS="${GATE_NEXTEST_THREADS:-8}"
# The compilation is bounded: without this, cargo compiles with one rustc per
# core, and the rustc of the engine is hungry (the complete gate has the same
# bound, for the same reason: sixteen rustc at once are tens of gigabytes of
# memory that this host does not have).
BUILD_JOBS="${GATE_BUILD_JOBS:-${CARGO_BUILD_JOBS:-4}}"
# The number of jobs follows the compilations that are running at the same
# time (bin/cargo-jobs.sh of the orchestrator): with a single gate the
# static 4 left 12 of the 16 cores idle, and with two gates it asked for
# 24 jobs. CARGO_BUILD_JOBS arrives from gate.sh, which divides the
# cores between the concurrent compilations.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
GATE_CHECK="${GATE_CHECK:-$SCRIPT_DIR/gate-check.sh}"
# The script that maps the changed files to the packages that hold them: the
# scope of the TESTS. It is a path and not a fixed name so that the harness
# of the tests can stub it.
TOUCHED_SCRIPT="${TOUCHED_SCRIPT:-$SCRIPT_DIR/touched-packages.py}"

case "$TIMEOUT_MIN" in ''|*[!0-9]*) TIMEOUT_MIN=30 ;; esac
case "$NEXTEST_THREADS" in ''|*[!0-9]*) NEXTEST_THREADS=8 ;; esac
case "$BUILD_JOBS" in ''|*[!0-9]*) BUILD_JOBS=4 ;; esac
export CARGO_BUILD_JOBS="$BUILD_JOBS"

# The scope of the TESTS can be WIDENED to the packages that DEPEND on the
# ones the change touches. It is OFF by default: the default scope of the
# tests is the package whose directory holds the changed file (the owners
# only) and that is the behaviour the loop knows. With the knob ON the tests
# also run on the dependents, the answer of scripts/ci/affected.py.
#
# A knob that is not exactly 1 is 0: a knob that is broken never widens
# anything, and the gate that is green without the knob stays green with it.
#
# WHY IT IS ON (31-10-2026): the maintainer asks for the nextest "on the
# crates scripts/ci/affected.py selects", and affected.py includes the
# DEPENDENTS of the touched package. With the narrow scope (only the owners)
# the gate of the slot 10138 ran 4174 tests and left out `solidcraft` and
# `solidcraft-web`, which are exactly the ones affected.py selects. MEASURED:
# the wide scope ran 4320 tests (146 more) in 462 s against 496 s of the
# narrow one: it does NOT cost more, because the binaries are already
# compiled in the target directory of the slot and the tests of the two extra
# packages are a fraction. The cost of widening is COMPILATION (a cold
# target dir), not tests.
#
# NOTE: this script does NOT read config.env (the knobs it reads come from
# the environment of the caller), so the value lives HERE, not there.
# The scope of the TESTS is the NARROW one: the packages whose directory
# holds a changed file. The dependents still have to COMPILE (the clippy and
# the check of the workspace keep the whole scope, so a dependent that does
# not compile is still red), but their tests are not the tests of the change.
#
# MEASURED (01-11-2026): with the dependents the gate of the slot 7114 ran
# 7724 tests over 7 packages and took 1360 s; with the narrow scope it runs
# the tests of the crate that was touched. The flag was ON by default and it
# contradicted the design of the gate (the rule is a test: "42. the tests run
# only on the crate that was touched"). It is OFF by default; the knob stays
# for the change that really touches the core of the workspace.
NEXTEST_INCLUDE_DEPENDENTS="${NEXTEST_INCLUDE_DEPENDENTS:-0}"
case "$NEXTEST_INCLUDE_DEPENDENTS" in 1) ;; *) NEXTEST_INCLUDE_DEPENDENTS=0 ;; esac

# --- the GPU stack of the run ------------------------------------------------
# The scoped gate runs the same tests as the complete gate and with the same
# policy (`SOLIDCRAFT_GPU=software`, `SOLIDCRAFT_REQUIRE_GPU=1`): a test that
# would skip for want of an adapter FAILS here instead of passing by
# accident. For that policy to have an adapter there must be ONE, and the only
# one on this host is lavapipe (the software Vulkan of Mesa).
#
# The loader finds the driver through the ICD, and the ICD of lavapipe
# (`lvp_icd.json`) names its library RELATIVE ("libvulkan_lvp.so"): the loader
# resolves that name through LD_LIBRARY_PATH. The library lives in X_LD
# (`$HOME/.local/x/usr/lib/x86_64-linux-gnu`) and that directory was NOT in the
# LD_LIBRARY_PATH of the scoped gate: without it there was NO adapter at all
# and the tests of `ui-egui` died with the panic "no GPU adapter qualifies
# under the software policy (SOLIDCRAFT_GPU)". That red was STRUCTURAL: it
# made every change that touches `solidcraft-ui-egui` look broken and left the
# complete gate (2 h 50 min) as the only way to a green verdict.
#
# So the environment of the scoped gate is ALIGNED with the one of the
# complete gate (bin/start-gate.sh): the same libraries, the same display and
# the same ICD. The policy is NOT relaxed: the tests keep asking for a
# software adapter and now they get one.
GPU_X_LD="${X_LD:-$HOME/.local/x/usr/lib/x86_64-linux-gnu}"
GPU_DISPLAY="${DISPLAY:-:99}"
GPU_ICD="${VK_ICD_FILENAMES:-$HOME/.local/x/usr/share/vulkan/icd.d/lvp_icd.json}"

# The LD of the run KEEPS what it had (the libraries of Chrome and the XKB
# data that the unit exports) and ADDS the one of lavapipe.
case ":${LD_LIBRARY_PATH:-}:" in
  *":$GPU_X_LD:"*) ;;
  *) export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$GPU_X_LD" ;;
esac
export DISPLAY="$GPU_DISPLAY"
# An ICD that does not exist would tell the loader "no ICD at all".
if [ -r "$GPU_ICD" ]; then
  export VK_ICD_FILENAMES="$GPU_ICD"
fi

# The adapter of the software policy has to be THERE. The ICD names its
# library relatively, so the loader resolves it through LD_LIBRARY_PATH: if
# that directory is missing there is NO adapter and the tests that need one
# panic with a message that has nothing to do with the change. This check only
# WARNS: the verdict of the run is always the one of the tests.
gpu_stack_warning() {
  local icd="${GPU_ICD}" lib d
  local -a dirs=()
  if [ ! -r "$icd" ]; then
    echo "the GPU stack: the ICD $icd is not readable: there will be no adapter"
    return 0
  fi
  lib="$(run_child sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$icd" | run_child head -1)"
  if [ -z "$lib" ]; then
    echo "the GPU stack: the ICD $icd does not name a library"
    return 0
  fi
  case "$lib" in
    /*)
      [ -r "$lib" ] && return 0
      echo "the GPU stack: the driver $lib of the ICD $icd is not there"
      return 0 ;;
  esac
  IFS=':' read -r -a dirs <<< "${LD_LIBRARY_PATH:-}"
  dirs+=(/usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib)
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    [ -r "$d/$lib" ] && return 0
  done
  echo "the GPU stack: the driver $lib of the ICD $icd is NOT resolvable:" \
       "no adapter will exist and the tests that need one will panic"
  return 0
}

# The budget of the WHOLE run, in seconds. Every phase has its own slice of
# it, so one phase can never eat the budget of the others, and the scope of
# the run takes it as its backstop (RuntimeMaxSec).
#
# The deadline is here, BEFORE anything is done, because the clock of the
# run is the whole run: the scope of the change (the diff, the metadata and
# affected.py) is part of the budget too. The deadline can not start later:
# the RuntimeMaxSec of the scope is the budget plus the grace, and the
# grace is for the teardown, not for the work that comes before the phases.
BUDGET=$(( TIMEOUT_MIN * 60 ))
DEADLINE=$(( $(date +%s) + BUDGET ))

# --- the belt of the run ----------------------------------------------------
# The limits of the scope the run lives in. The defaults are the ones of the
# complete gate (bin/start-gate.sh): the same memory, the same weight, so
# the two gates behave the same way.
#
# They are read with the default of the shell: an unbound variable must
# never abort the gate (this script runs `set -uo pipefail`, without -e).
GATE_QUICK_TARGET_DIR="${GATE_QUICK_TARGET_DIR:-${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}/targets/gate-quick}"
# The memory of the scope. MEASURED (01-11-2026): the peak of a gate is
# 23.7 GB. The high is 26G so that TWO gates at the same time fit in the 62
# GB of the box (2 x 26 = 52 GB of high, and 2 x 23.7 = 47.4 GB of real
# peak, with 14.6 GB of margin). The old high of 32G would have let a second
# gate ask for 32 and the kernel would have had 64 GB of demand on 62 of
# RAM: the OOM killer would have taken a test binary, and a killed test
# binary reads as a RED gate.
GATE_QUICK_MEMORY_HIGH="${GATE_QUICK_MEMORY_HIGH:-26G}"
GATE_QUICK_MEMORY_MAX="${GATE_QUICK_MEMORY_MAX:-32G}"
# The CPU weight of the scope. It is a SHARE under contention, not a limit:
# the weight of the scope against the weight of its siblings in the same
# slice. 100 is the parity with the loop's own service: with 50 the scope
# got half of the share of the loop's slice and the scope gate missed its
# 30 min budget (EXIT=124, 720 of 3112 tests never ran).
GATE_QUICK_CPU_WEIGHT="${GATE_QUICK_CPU_WEIGHT:-100}"

# --- the fair local gate (27-10-2026) ---------------------------------
# The complete gate is off by default (config.env: GATE_COMPLETE_MODE=off):
# the CI of the upstream runs the full suite when a maintainer reviews the
# PR and the merge queue runs it again on top of main. This gate of the
# scope is the fair one, and it gets two things the loop did not have:
#
# 1. `cargo check --workspace --all-targets`: the scope of a change is a
#    PACKAGE, so the gate of the scope never compiles the crates the
#    change does not touch, and a change that breaks the build of another
#    crate of the workspace was published with a green scope. The check
#    of the whole workspace catches that.
#
# 2. sccache: the CI of the upstream compiles with it
#    (.github/workflows/ci.yml) and the loop did not (0 requests until
#    27-10): every run rebuilt everything from scratch. A cache that
#    breaks is not a code that breaks, so a phase that fails WITH the
#    wrapper is retried ONCE without it (the ledger lost a whole gate to
#    a crash of sccache while the test binaries were built).
GATE_CHECK_WORKSPACE="${GATE_CHECK_WORKSPACE:-1}"
GATE_SCCACHE="${GATE_SCCACHE:-1}"
if [ "$GATE_SCCACHE" = "1" ] && command -v sccache >/dev/null 2>&1; then
  RUSTC_WRAPPER="$(command -v sccache)"
  export RUSTC_WRAPPER
  echo "gate-quick: the compilation goes through sccache ($RUSTC_WRAPPER)" >&2
else
  GATE_SCCACHE=0
fi
# The IO weight. It is accepted by the manager and applied by the kernel
# ONLY when the io controller is delegated to the user manager: on this host
# it is NOT (there is no io.weight file in the tree), so the property is
# inert. It is kept because it takes effect on a host that delegates it.
GATE_QUICK_IO_WEIGHT="${GATE_QUICK_IO_WEIGHT:-50}"
# The slice of the scope. It is the loop's OWN slice, the one that holds
# solidcraft-loop@0.service, and it matters: a scope created in app.slice
# is a THIRD peer of the complete gate, and asking for a CPU weight turns
# the cpu controller on for that subtree, so app.slice starts splitting its
# CPU between the three (the complete gate would lose a third of the share
# it has today, and the complete gate is the critical path of the loop).
# Inside the loop's slice the complete gate keeps the share it has today
# and the scope competes with the supervisor, as it did before the belt.
# The name is the ESCAPED one (the dash of "solidcraft-loop" is \x2d in the
# unit name of the slice); an empty value leaves the scope in the default
# place of the user manager.
GATE_QUICK_SLICE="${GATE_QUICK_SLICE-app-solidcraft\x2dloop.slice}"
GATE_QUICK_TASKS_MAX="${GATE_QUICK_TASKS_MAX:-4096}"
GATE_QUICK_OOM_POLICY="${GATE_QUICK_OOM_POLICY:-kill}"
# 0 disables the belt completely: the run is not bounded at all.
GATE_QUICK_CGROUP="${GATE_QUICK_CGROUP:-1}"
# The seconds added to the budget for the RuntimeMaxSec of the scope: the
# grace covers the work that happens before the budget starts (the diff and
# the scope of the change) and the teardown of the unit.
GATE_QUICK_RUNTIME_GRACE="${GATE_QUICK_RUNTIME_GRACE:-120}"
# The seconds that a scoped gate waits for the lock of the build directory:
# 0 (the default) does not wait at all: the scope is DEFERRED when another
# scoped gate is using the target directory. The target directory is SHARED
# by every slot, so two scoped gates at the same time fight for the cargo
# lock, and the loser of that fight does not wait: it dies with "Blocking
# waiting for file lock on build directory" (27-10-2026).
GATE_SCOPE_LOCK_WAIT="${GATE_SCOPE_LOCK_WAIT:-0}"
case "$GATE_SCOPE_LOCK_WAIT" in ''|*[!0-9]*) GATE_SCOPE_LOCK_WAIT=0 ;; esac
# The seconds that a scope has to be old before it is treated as debris: a
# scope that was created a moment ago can be in the middle of its own start
# (the gate of the child does not exist yet), and killing it would kill a
# run that is starting.
GATE_SCOPE_CLEAN_GRACE="${GATE_SCOPE_CLEAN_GRACE:-120}"
case "$GATE_SCOPE_CLEAN_GRACE" in ''|*[!0-9]*) GATE_SCOPE_CLEAN_GRACE=120 ;; esac
# The root of the hierarchy of the cgroups: it is /sys/fs/cgroup in a normal
# host, and a directory of the test in the tests (a test that can not build
# a tree of cgroups can only read the source of the gate, and the source is
# not the behaviour).
GATE_CGROUP_ROOT="${GATE_CGROUP_ROOT:-/sys/fs/cgroup}"

case "$GATE_QUICK_CPU_WEIGHT" in ''|*[!0-9]*) GATE_QUICK_CPU_WEIGHT=100 ;; esac
case "$GATE_QUICK_IO_WEIGHT" in ''|*[!0-9]*) GATE_QUICK_IO_WEIGHT=50 ;; esac
case "$GATE_QUICK_TASKS_MAX" in ''|*[!0-9]*) GATE_QUICK_TASKS_MAX=4096 ;; esac
case "$GATE_QUICK_RUNTIME_GRACE" in ''|*[!0-9]*) GATE_QUICK_RUNTIME_GRACE=120 ;; esac
case "$GATE_QUICK_OOM_POLICY" in
  continue|stop|kill) ;;
  *) GATE_QUICK_OOM_POLICY="kill" ;;
esac
case "$GATE_QUICK_CGROUP" in
  0|1) ;;
  *) GATE_QUICK_CGROUP=1 ;;
esac

# The runtime limit of the scope: the budget of the run plus the grace. The
# internal timeout of the phases fires FIRST (the budget is the clock of the
# gate); the RuntimeMaxSec is only the backstop of a run that hangs.
SCOPE_RUNTIME_MAX=$(( BUDGET + GATE_QUICK_RUNTIME_GRACE ))

# The target directory of the run is resolved AFTER the name of the slot is
# known (see the section of the slot, below): every slot compiles in a
# directory of its own.

usage() {
  cat <<'EOF'
usage: gate-quick.sh [--slot <name>] <base-ref> <sha>
usage: gate-quick.sh --scope-probe

Runs the scoped gate over the packages the change touches and writes
$LOOP_DIR/gate.quick.verdict (GATE_STATUS, SCOPE, VERDICT, NEW_FAILURES,
PUBLISHABLE=no, SHA, AT) and, when the slot is known, the authoritative
$LOOP_DIR/gates/<slot>/scope.verdict (GATE_STATUS, SCOPE, SCOPE_KIND,
VERDICT, NEW_FAILURES, FAILED_TESTS, CHECKS, SHA, AT).

The scoped gate runs `cargo fmt --all -- --check`, `cargo xtask layers`, a
scoped `cargo clippy` and a scoped `cargo nextest run`.

The verdict of the scope NEVER publishes on its own: the publication
decision is derived by bin/state.py. A change that touches the whole
workspace is skipped: the complete gate has to run.

The run happens inside a TRANSIENT SCOPE of the user manager
(systemd-run --user --scope) with its memory, cpu, io and tasks bounded: the
supervisor runs in the foreground and inherits a cgroup whose limits are
"max", so without the scope a heavy test can take the whole host and the
global OOM killer can kill the opencode of the loop (the brain of the turn).
The belt NEVER decides anything: it only bounds the run. When the scope can
not be created the gate runs without it (fail open) and the verdict of the
run is the one it always was.

The gate compiles into its OWN target directory: the complete gate and the
scoped gate share the host and cargo takes a lock of the target directory,
so without a target of its own one would wait for the other. Every slot
compiles in a directory of its own (<base>/slot-<slot>), so two slots do
not wait for each other either.

--scope-probe prints the limits that are REALLY in force inside a scope of
the same shape: it is the check of the belt without a gate. Its exit code is
the code of a DIAGNOSTIC: 0 when the belt is in force, 1 when it is not
(the scope could not be created, its limits are not applied, or the belt is
disabled). The probe never decides anything: the belt never fails the gate.

environment:
  REPO                 the repository (default: /home/user/solidcraft)
  LOOP_DIR             the loop directory (default: ~/.local/share/solidcraft-loop)
  BASELINE_FAILURES    the known failures (default: $LOOP_DIR/baseline-failures.txt)
  GATE_QUICK_TIMEOUT_MIN   the budget of the whole quick gate (default: 30)
  GATE_NEXTEST_THREADS     the threads of nextest (default: 12)
  GATE_BUILD_JOBS         the rustc at once while it compiles (default: 4)
  NEXTEST_INCLUDE_DEPENDENTS  1 adds the DEPENDENTS of the touched packages to the scope of the tests (default: 0)
  GATE_SLOT, SLOT      the slot of the run (the --slot option wins)
  CARGO_TARGET_DIR     the target directory cargo uses (the gate sets its own: <GATE_QUICK_TARGET_DIR>/slot-<slot>)
  GATE_QUICK_TARGET_DIR   the BASE of the target directories of the scoped gate (default: /home/user/solidcraft-gate-quick/target); every slot compiles in <base>/slot-<slot>
  GATE_QUICK_MEMORY_HIGH   the soft memory limit of the scope (default: 32G)
  GATE_QUICK_MEMORY_MAX    the hard memory limit of the scope (default: 40G)
  GATE_QUICK_CPU_WEIGHT    the cpu weight of the scope (default: 50)
  GATE_QUICK_IO_WEIGHT     the io weight of the scope (default: 50)
  GATE_QUICK_TASKS_MAX     the tasks at once of the scope (default: 4096)
  GATE_QUICK_OOM_POLICY    what the kernel does when the scope is out of memory: continue, stop or kill (default: kill)
  GATE_QUICK_CGROUP        0 disables the belt of the scope (default: 1)
  GATE_QUICK_RUNTIME_GRACE the seconds added to the budget for the RuntimeMaxSec of the scope (default: 120)
EOF
}

# --- the belt of the run ----------------------------------------------------
# The run lives inside a TRANSIENT SCOPE of the user manager: the memory, the
# cpu, the io and the tasks of the run are bounded. The supervisor launches
# this gate in the foreground, so it inherits the cgroup of the supervisor
# (solidcraft-loop@0.service), whose memory.high and memory.max are "max":
# without the scope a heavy test can take the whole host (62 GB, no swap) and
# the global OOM killer can kill the opencode of the loop (the brain of the
# turn). The complete gate has the same belt (bin/start-gate.sh).
#
# The belt NEVER decides anything: it only bounds the run. When the scope can
# not be created the gate runs without it (fail open) and the verdict of the
# run is the one it always was.
#
# The scope lives in the LOOP'S OWN slice (app-solidcraft\x2dloop.slice, the
# one that holds solidcraft-loop@0.service) and not in app.slice: a scope
# with a CPU weight in app.slice turns the cpu controller on for that
# subtree and the complete gate (the critical path of the loop) becomes a
# third peer of it, losing a third of the CPU it has today. Measured on this
# host: with the scope in app.slice, app.slice splits its CPU between three
# units (the complete gate 100, the loop slice 100 and the scope 50); inside
# the loop's slice the complete gate keeps the share it has today.
#
# The three states of the belt:
#
#   SC_QUICK_CGROUP=1     the process is the child of the scope already: it
#                         runs the gate (or the probe) inside the scope.
#   SC_QUICK_SCOPE_OFF=1  the scope could not be created: the run is direct.
#   GATE_QUICK_CGROUP=0   the belt is disabled: the run is direct.
#
# The marker: the child of the scope touches it as its first action. The
# parent reads it after systemd-run: when the marker is there the scope was
# really there and the child ran, so the parent NEVER runs the gate twice.

# The name of the transient unit of the scope. A systemd unit name is
# [a-z0-9-], so the name of the slot is sanitized again here: the name of a
# slot accepts dots and underscores too.
scope_unit_name() {
  local raw="$1" out
  out="$(printf '%s' "$raw" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | cut -c1-40)"
  out="${out#-}"
  out="${out%-}"
  [ -n "$out" ] || out="run"
  printf 'solidcraft-gate-quick-%s.scope' "$out"
}

# The directory of the cgroup of THIS process: the path of /proc/self/cgroup
# is relative to the root of the hierarchy of the user manager.
scope_cgroup_dir() {
  local line rel=""
  while IFS= read -r line; do
    case "$line" in
      0::*) rel="${line#0::}" ;;
    esac
  done < /proc/self/cgroup 2>/dev/null
  [ -n "$rel" ] || return 1
  printf '%s%s' "$GATE_CGROUP_ROOT" "$rel"
}

# The value of a file of the cgroup, or "unavailable" when it can not be
# read: a limit that is not there is a fact of the report, never a failure.
cgroup_file_value() {
  local dir="$1" name="$2" value=""
  if [ -n "$dir" ] && [ -r "$dir/$name" ]; then
    value="$(run_child head -n 1 "$dir/$name" 2>/dev/null || true)"
  fi
  [ -n "$value" ] || value="unavailable"
  printf '%s' "$value"
}

# The value of a key of a file of "key value" pairs of the cgroup
# (memory.events, cpu.stat).
cgroup_pair_value() {
  local dir="$1" name="$2" key="$3" line value=""
  if [ -n "$dir" ] && [ -r "$dir/$name" ]; then
    while IFS= read -r line; do
      case "$line" in
        "$key "*) value="${line#* }"; break ;;
      esac
    done < "$dir/$name"
  fi
  [ -n "$value" ] || value="unavailable"
  printf '%s' "$value"
}

# The value of a property of the unit, read from the manager: not every limit
# of a scope has a file in the cgroup (io.weight, oom.policy).
unit_property() {
  local unit="$1" name="$2" value=""
  value="$(run_child systemctl --user show "$unit" -p "$name" --value 2>/dev/null | run_child head -n 1 || true)"
  [ -n "$value" ] || value="unavailable"
  printf '%s' "$value"
}

# The name of the scope THIS process lives in: the cgroup of the process is
# named after the unit of the scope, so the probe can report the scope that
# is REALLY in force and not the one that was asked for.
scope_unit_of_cgroup() {
  local dir
  dir="$(scope_cgroup_dir 2>/dev/null || true)"
  [ -n "$dir" ] || return 1
  run_child basename "$dir"
}

# A transient scope of a previous run of the same unit can stay LOADED for a
# moment after the run: systemd refuses to create a unit that exists. The
# belt waits for the old one to go (it is a matter of a second) instead of
# running the gate without the belt. It waits only for a LOADED unit: any
# other state is free.
scope_wait_free() {
  local unit="$1" waited=0 state
  while [ "$waited" -lt 15 ]; do
    state="$(unit_property "$unit" LoadState)"
    [ "$state" = "loaded" ] || return 0
    sleep 1
    waited=$(( waited + 1 ))
  done
  return 1
}

# The pids of a cgroup: the ones that are in it right now.
cgroup_pids() {
  local dir="$1"
  [ -n "$dir" ] && [ -r "$dir/cgroup.procs" ] || return 1
  run_child cat "$dir/cgroup.procs" 2>/dev/null || true
}

# The command line of a process, with its arguments separated by spaces.
pid_cmdline() {
  local pid="$1"
  [ -r "/proc/$pid/cmdline" ] || return 1
  run_child tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true
}

# The state of a process: R (running), S (sleeping), Z (zombie)...
pid_state() {
  local pid="$1" rest="" state=""
  [ -r "/proc/$pid/stat" ] || return 1
  # The command name of a process can have spaces and parentheses, so the
  # line is cut at the LAST parenthesis before the fields are read.
  rest="$(run_child sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null)" || return 1
  state="$(printf '%s' "$rest" | run_child awk '{print $1}')"
  [ -n "$state" ] || return 1
  printf '%s' "$state"
}

# The father of a process: the field 4 of /proc/<pid>/stat.
ppid_of() {
  local pid="$1" rest="" parent=""
  [ -r "/proc/$pid/stat" ] || return 1
  rest="$(run_child sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null)" || return 1
  parent="$(printf '%s' "$rest" | run_child awk '{print $2}')"
  [ -n "$parent" ] || return 1
  printf '%s' "$parent"
}

# --- the leftovers of the scope ---------------------------------------------
# The processes of the scope of THIS run that are still alive when a phase
# ends.
#
# WHY: a phase runs under `timeout`, and `timeout` kills the process it
# started. The binaries of the tests are NOT that process: nextest runs
# every test in a process of its own, with a process group of its own, so
# they escape the kill of the group. An orphan of nextest keeps the cargo
# lock of the build directory, and the NEXT gate of the scope dies with
# "Blocking waiting for file lock on build directory" (27-10-2026: the
# clippy of the gate of 20:12 died because the nextest of the gate of
# 20:01 was still alive).
#
# The container that works is the CGROUP, not the group of processes: the
# leftovers of the scope are killed here, at the end of every phase and at
# the exit of the run.
#
# The daemon of sccache is NOT a leftover: it is a daemon that outlives the
# phase that started it, it does not hold the cargo lock, and killing it
# would throw away the cache of the run.
kill_leftovers_in() {
  # kill_leftovers_in <cgroup-dir>
  local dir="$1"
  [ -n "$dir" ] || return 0
  local unit pids pid state cmd victims="" ancestors="" a
  unit="$(run_child basename "$dir")"
  case "$unit" in
    solidcraft-gate-quick-*.scope) ;;
    *) return 0 ;;
  esac
  pids="$(cgroup_pids "$dir" 2>/dev/null || true)"
  [ -n "$pids" ] || return 0
  # The ancestors of this process are never killed: they are the run that
  # watches the scope and the scope itself.
  a="$$"
  while [ -n "$a" ] && [ "$a" != "0" ] && [ "$a" != "1" ]; do
    ancestors="$ancestors $a"
    a="$(ppid_of "$a" 2>/dev/null || true)"
  done
  for pid in $pids; do
    case " $ancestors " in
      *" $pid "*) continue ;;
    esac
    state="$(pid_state "$pid" 2>/dev/null || true)"
    # A zombie is already dead: it only waits for its father.
    [ "$state" = "Z" ] && continue
    cmd="$(pid_cmdline "$pid" 2>/dev/null || true)"
    case "$cmd" in
      *sccache*) continue ;;
    esac
    victims="$victims $pid"
  done
  [ -n "$victims" ] || return 0
  echo "gate-quick: the leftovers of the scope are killed:$victims" >&2
  kill -TERM $victims 2>/dev/null || true
  run_child sleep 1
  # Only the pids of the list that are STILL in the scope are killed with
  # SIGKILL: the processes that this function starts (the sleep, the kill)
  # are in the scope too, and killing them would kill the run.
  local alive=""
  for pid in $victims; do
    if cgroup_pids "$dir" 2>/dev/null | run_child grep -qx "$pid"; then
      alive="$alive $pid"
    fi
  done
  [ -n "$alive" ] || return 0
  kill -KILL $alive 2>/dev/null || true
  return 0
}

kill_scope_leftovers() {
  # The guard is double: the process has to be the child of a scope
  # (SC_QUICK_CGROUP=1) AND the scope has to be one of ours (its name
  # starts with solidcraft-gate-quick-). A run without a scope kills
  # nothing: the belt is not in force and the run is not bounded.
  [ "${SC_QUICK_CGROUP:-0}" = "1" ] || return 0
  local dir
  dir="$(scope_cgroup_dir 2>/dev/null || true)"
  kill_leftovers_in "$dir"
}

# --- the debris of the scopes of the previous runs --------------------------
# The scopes of the runs that died: their processes (the binaries of nextest,
# the cargo, the daemon of sccache) keep the memory of the box and the lock
# of the build directory. A scope whose gate-quick.sh is NOT alive is
# debris: it is killed and stopped.
#
# The guard of the age: a scope that was created a moment ago can be in the
# middle of its own start (the gate-quick.sh of the child does not exist
# yet), and killing it would kill a run that is starting. A scope younger
# than the grace is left alone.
cleanup_dead_scopes() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local units unit cg dir pids pid cmd alive entered now age
  units="$(systemctl --user list-units --type=scope --all --plain \
    --no-legend 2>/dev/null || true)"
  [ -n "$units" ] || return 0
  now="$(cut -d' ' -f1 /proc/uptime 2>/dev/null || true)"
  [ -n "$now" ] || return 0
  for unit in $units; do
    case "$unit" in
      solidcraft-gate-quick-*.scope) ;;
      *) continue ;;
    esac
    cg="$(unit_property "$unit" ControlGroup)"
    [ -n "$cg" ] && [ "$cg" != "unavailable" ] || continue
    dir="$GATE_CGROUP_ROOT$cg"
    [ -d "$dir" ] || continue
    # The age of the scope: a scope that is starting is not debris.
    entered="$(unit_property "$unit" ActiveEnterTimestampMonotonic)"
    case "$entered" in
      ''|unavailable|0) continue ;;
    esac
    age="$(awk -v now="$now" -v entered="$entered" \
      'BEGIN { d = now - entered / 1000000; if (d < 0) d = 0; print int(d) }')"
    case "$age" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$age" -ge "$GATE_SCOPE_CLEAN_GRACE" ] || continue
    pids="$(cgroup_pids "$dir" 2>/dev/null || true)"
    [ -n "$pids" ] || continue
    alive=""
    for pid in $pids; do
      cmd="$(pid_cmdline "$pid" 2>/dev/null || true)"
      case "$cmd" in
        *gate-quick.sh*) alive="$alive $pid" ;;
      esac
    done
    # A scope with a gate of its own is alive: it is not touched.
    [ -z "$alive" ] || continue
    echo "gate-quick: the scope $unit is dead (it has no gate of its own):" \
      "it is cleaned" >&2
    systemctl --user kill --kill-whom=all --signal=SIGKILL "$unit" \
      2>/dev/null || true
    systemctl --user stop "$unit" 2>/dev/null || true
  done
  return 0
}

# The complete gate that is alive RIGHT NOW, in any slot. It holds tens of
# GB of memory and saturates the CPU, so a scoped gate launched next to it
# competes with it for the memory: the loser of that competition is the
# complete gate (the OOM killer takes the biggest process), and the run it
# is in the middle of is lost.
#
# The detection is POSITIVE: only a pid that is PROVABLY a complete gate
# counts. A pid file of a dead process, a pid of another program, or a
# command line that can not be read do NOT defer anything: the scoped gate
# runs (fail open, the belt of the scope is always there).
complete_gate_pid() {
  local pid=0 file cmd
  for file in "$LOOP_DIR/gate.pid" "$LOOP_DIR"/gates/*/pid; do
    [ -r "$file" ] || continue
    pid="$(tr -dc '0-9' < "$file" 2>/dev/null | head -c 10)"
    case "${pid:-}" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" -gt 0 ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    # The command line can not be read: it is NOT a gate (the deferral is
    # only worth it when the machine is really busy).
    [ -n "$cmd" ] || continue
    case "$cmd" in
      *solidcraft-gate-slot:*|*"xtask ci"*)
        printf '%s' "$pid"
        return 0 ;;
    esac
  done
  return 1
}

# The seconds of a timespan of systemd ("32min", "1min 30s", "500ms").
timespan_seconds() {
  local text="$1" total=0 rest num unit lead
  rest="$text"
  while :; do
    lead="${rest%%[![:space:]]*}"
    rest="${rest#"$lead"}"
    [ -n "$rest" ] || break
    num="${rest%%[!0-9]*}"
    [ -n "$num" ] || return 1
    rest="${rest#"$num"}"
    unit="${rest%% *}"
    rest="${rest#"$unit"}"
    case "$unit" in
      h|hour|hours) total=$(( total + num * 3600 )) ;;
      min|minute|minutes) total=$(( total + num * 60 )) ;;
      s|sec|second|seconds) total=$(( total + num )) ;;
      ms|msec) total=$(( total + num / 1000 )) ;;
      us|usec) total=$(( total + num / 1000000 )) ;;
      *) return 1 ;;
    esac
  done
  printf '%s' "$total"
}

# A limit of the scope that has no file in the cgroup (io.weight and
# oom.policy): the manager knows it, and the configuration is the last
# resort.
scope_probe_fallback() {
  # scope_probe_fallback <dir> <file> <property> <configured> <unit>
  local dir="$1" file="$2" property="$3" configured="$4" unit="$5" value
  value="$(cgroup_file_value "$dir" "$file")"
  if [ "$value" = "unavailable" ]; then
    value="$(unit_property "$unit" "$property")"
  fi
  if [ "$value" = "unavailable" ]; then value="$configured"; fi
  printf '%s' "$value"
}

# The runtime limit of the scope: it has no file in the cgroup, the manager
# knows it as a timespan.
scope_probe_runtime() {
  local unit="$1" value seconds=""
  value="$(unit_property "$unit" RuntimeMaxUSec)"
  if [ "$value" != "unavailable" ]; then
    seconds="$(timespan_seconds "$value" 2>/dev/null || true)"
  fi
  [ -n "$seconds" ] || seconds="$SCOPE_RUNTIME_MAX"
  printf '%s' "$seconds"
}

# The limits that are REALLY in force inside the scope: they are read from
# the cgroup of this process, so the probe shows what the kernel applies and
# not what the configuration asks for.
scope_probe() {
  # scope_probe <unit>
  local unit="$1" dir high max
  dir="$(scope_cgroup_dir 2>/dev/null || true)"
  high="$(cgroup_file_value "$dir" memory.high)"
  max="$(cgroup_file_value "$dir" memory.max)"
  printf 'unit=%s\n' "$unit"
  printf 'cgroup.path=%s\n' "${dir:-unavailable}"
  # Where the scope landed: it MUST be in the slice of the loop. A scope in
  # app.slice turns the cpu controller on for that subtree and the complete
  # gate becomes a third peer of it, losing a third of its CPU.
  if [ -n "$GATE_QUICK_SLICE" ] && [ -n "$dir" ]; then
    case "$dir" in
      *"$GATE_QUICK_SLICE"*) printf 'slice.placement=ok\n' ;;
      *) printf 'slice.placement=unexpected\n' ;;
    esac
  else
    printf 'slice.placement=default\n'
  fi
  printf 'memory.high=%s\n' "$high"
  printf 'memory.max=%s\n' "$max"
  printf 'cpu.weight=%s\n' "$(cgroup_file_value "$dir" cpu.weight)"
  printf 'io.weight=%s\n' \
    "$(scope_probe_fallback "$dir" io.weight IOWeight "$GATE_QUICK_IO_WEIGHT" "$unit")"
  printf 'tasks.max=%s\n' "$(cgroup_file_value "$dir" pids.max)"
  printf 'oom.policy=%s\n' \
    "$(scope_probe_fallback "$dir" memory.oom.policy OOMPolicy "$GATE_QUICK_OOM_POLICY" "$unit")"
  printf 'memory.swap.max=%s\n' "$(cgroup_file_value "$dir" memory.swap.max)"
  printf 'runtime.max=%s\n' "$(scope_probe_runtime "$unit")"
  # The probe succeeds only when the limits are really applied: a scope
  # without them is a belt that does not exist.
  case "$high" in ''|max|unavailable) return 1 ;; esac
  case "$max" in ''|max|unavailable) return 1 ;; esac
  return 0
}

# --- the children of the run ------------------------------------------------
# Every child of the gate runs with the descriptors of the lock CLOSED.
#
# WHY (17-11-2026): the lock of the slot (fd 8) and the global one (fd 9) are
# OPEN in the gate, and a child INHERITS them. A child that outlives the gate
# (an orphan of a phase, a parser that hangs, a script that is killed with its
# father) keeps the lock taken, and the NEXT gate of that slot can not take
# it: it is DEFERRED. It is deferred FOREVER: the slot never gates again,
# and the symptom is a slot that stopped gating with no error anywhere.
#
# The closing is in the CHILD, never in the gate: the gate needs ITS
# descriptors ALIVE while the run lasts (it is the gate that holds the lock
# and that releases it when the run ends).
#
# `exec 8>&- 9>&-` inside the subshell of the child closes the descriptors
# in the child AND in everything the child spawns (a fork inherits the
# CLOSED descriptors and an exec keeps them closed), so the two ways of
# launching a child (a subshell `( ... )` and a `bash -c`) are covered by
# the same wrapper.
#
# This function is defined BEFORE the belt of the run (the first child of
# the gate is the scope of the run), and it is used by every child that the
# gate launches while the lock is taken.
run_child() {
  # run_child <command> [args...]
  # The exit code of the child is the exit code of this function. A command
  # that does not exist is the failure of the child (127), not of the gate.
  [ "$#" -gt 0 ] || return 127
  ( exec 8>&- 9>&-; exec "$@" )
}

# run_in_scope <unit> <marker> <command> [args...]
# The command runs inside a transient scope of the user manager, with the
# limits of the belt. The exit code of the command is the exit code of this
# function.
run_in_scope() {
  local unit="$1" marker="$2"
  shift 2
  local slice_arg=()
  if [ -n "$GATE_QUICK_SLICE" ]; then
    slice_arg=( "--slice=$GATE_QUICK_SLICE" )
  fi
  run_child env SC_QUICK_CGROUP=1 SC_QUICK_SCOPE_MARKER="$marker" \
    systemd-run --user --scope --quiet --expand-environment=no \
      --unit="$unit" \
      "${slice_arg[@]}" \
      -p "MemoryHigh=$GATE_QUICK_MEMORY_HIGH" \
      -p "MemoryMax=$GATE_QUICK_MEMORY_MAX" \
      -p "CPUWeight=$GATE_QUICK_CPU_WEIGHT" \
      -p "IOWeight=$GATE_QUICK_IO_WEIGHT" \
      -p "TasksMax=$GATE_QUICK_TASKS_MAX" \
      -p "OOMPolicy=$GATE_QUICK_OOM_POLICY" \
      -p "MemorySwapMax=0" \
      -p "RuntimeMaxSec=$SCOPE_RUNTIME_MAX" \
      -- "$@"
}

# The metrics of the scope the run lived in. They are appended to the LOG of
# the run, never to the verdict file: the format of the verdict file is the
# contract of the loop and the metrics are not part of it.
append_scope_metrics() {
  [ "${SC_QUICK_CGROUP:-0}" = "1" ] || return 0
  [ -n "${LOG_FILE:-}" ] || return 0
  [ "${SCOPE_METRICS_WRITTEN:-0}" = "0" ] || return 0
  SCOPE_METRICS_WRITTEN=1
  local dir
  dir="$(scope_cgroup_dir 2>/dev/null || true)"
  {
    printf '\n--- scope metrics ---\n'
    printf 'cgroup.path=%s\n' "${dir:-unavailable}"
    printf 'memory.high=%s\n' "$(cgroup_file_value "$dir" memory.high)"
    printf 'memory.max=%s\n' "$(cgroup_file_value "$dir" memory.max)"
    printf 'memory.peak=%s\n' "$(cgroup_file_value "$dir" memory.peak)"
    printf 'memory.events.low=%s\n' "$(cgroup_pair_value "$dir" memory.events low)"
    printf 'memory.events.high=%s\n' "$(cgroup_pair_value "$dir" memory.events high)"
    printf 'memory.events.max=%s\n' "$(cgroup_pair_value "$dir" memory.events max)"
    printf 'memory.events.oom=%s\n' "$(cgroup_pair_value "$dir" memory.events oom)"
    printf 'memory.events.oom_kill=%s\n' "$(cgroup_pair_value "$dir" memory.events oom_kill)"
    printf 'cpu.stat.nr_throttled=%s\n' "$(cgroup_pair_value "$dir" cpu.stat nr_throttled)"
    printf 'cpu.stat.throttled_usec=%s\n' "$(cgroup_pair_value "$dir" cpu.stat throttled_usec)"
    printf 'pids.max=%s\n' "$(cgroup_file_value "$dir" pids.max)"
    printf 'pids.peak=%s\n' "$(cgroup_file_value "$dir" pids.peak)"
    printf '--- end scope metrics ---\n'
  } >> "$LOG_FILE" 2>/dev/null || true
  return 0
}

BASE=""
SHA=""
SLOT_OPTION=""
PROBE=0
# The arguments of the caller, kept as they are: the belt re-executes this
# script with them, and the slot is a part of them.
ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --scope-probe) PROBE=1; shift ;;
    --slot)
      if [ $# -lt 2 ]; then echo "gate-quick: --slot needs a name" >&2; exit 2; fi
      SLOT_OPTION="$2"; shift 2 ;;
    --slot=*) SLOT_OPTION="${1#--slot=}"; shift ;;
    --) shift; break ;;
    -*) echo "gate-quick: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -z "$BASE" ]; then
        BASE="$1"
      elif [ -z "$SHA" ]; then
        SHA="$1"
      else
        echo "gate-quick: too many arguments" >&2
        usage >&2
        exit 2
      fi
      shift ;;
  esac
done
# The arguments of the caller are restored: the loop of the options above
# consumed them, and the belt needs them for the re-execution.
set -- ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
if [ "$PROBE" -eq 0 ] && { [ -z "$BASE" ] || [ -z "$SHA" ]; }; then
  echo "gate-quick: <base-ref> and <sha> are needed" >&2
  usage >&2
  exit 2
fi

# --- the slot --------------------------------------------------------------
# The name of a slot is a FILE NAME: it has to be safe inside a path. The
# rules are the ones of gate-check.sh: lower case, [a-z0-9._-] only, no "..",
# not empty, not hidden, 60 characters at most. A name that cannot be
# normalized is NEVER invented: a name that is not the slot's would write the
# verdict of the run in the file of another slot.
normalize_slot() {
  local raw="$1" out
  out="$(printf '%s' "$raw" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '-' | cut -c1-60)"
  case "$out" in
    ""|.|..) return 1 ;;
    *..*) return 1 ;;
    .*|-*) return 1 ;;
  esac
  printf '%s' "$out"
}

# The slot of this run: the --slot option, then GATE_SLOT, then SLOT (the
# supervisor exports it), then the name of the worktree the gate runs in.
SLOT_NAME=""
SLOT_RAW="$SLOT_OPTION"
if [ "$PROBE" -eq 1 ]; then
  # The probe does not use the slot: it writes no verdict and the unit of the
  # scope has a name of its own.
  SLOT_RAW=""
else
  [ -n "$SLOT_RAW" ] || SLOT_RAW="${GATE_SLOT:-}"
  [ -n "$SLOT_RAW" ] || SLOT_RAW="${SLOT:-}"
  [ -n "$SLOT_RAW" ] || SLOT_RAW="$(basename "$PWD" 2>/dev/null || true)"
fi
if [ -n "$SLOT_RAW" ]; then
  SLOT_NAME="$(normalize_slot "$SLOT_RAW" 2>/dev/null)" || SLOT_NAME=""
  if [ -z "$SLOT_NAME" ]; then
    if [ -n "$SLOT_OPTION" ]; then
      echo "gate-quick: the slot name is not usable: $SLOT_OPTION" >&2
      exit 2
    fi
    echo "gate-quick: the slot name is not usable ($SLOT_RAW): only the" \
      "global verdict file is written" >&2
  fi
fi

# --- the target directory of the slot ---------------------------------------
# Every slot compiles in a target directory of its OWN: two scoped gates that
# run at the same time fight for the cargo lock of the build directory, and
# the loser of that fight does not wait: it dies with "Blocking waiting for
# file lock on build directory" (20-10-2026: the clippy of the gate of 20:12
# died because the nextest of the gate of 20:01 was still alive).
#
# The layout is the one of bin/gate-target-dir.sh: GATE_QUICK_TARGET_DIR is
# the BASE, the container of the directories, and the slot writes in
# <base>/slot-<slot> (a run without a slot writes in <base>/noslot). The
# base is never the target directory of a run: the disk collector removes the
# directories one by one and never the base as a whole.
#
# The helper is the source of truth of the layout. When it is not deployed
# (a run from a checkout that does not have it) the layout is computed here,
# the same way the helper computes it.
export GATE_QUICK_TARGET_DIR
GATE_TARGET_HELPER="$LOOP_DIR/bin/gate-target-dir.sh"
CARGO_TARGET_DIR=""
if [ -x "$GATE_TARGET_HELPER" ]; then
  if [ -n "$SLOT_NAME" ]; then
    CARGO_TARGET_DIR="$("$GATE_TARGET_HELPER" --slot "$SLOT_NAME" 2>/dev/null \
      || true)"
  else
    CARGO_TARGET_DIR="$("$GATE_TARGET_HELPER" --noslot 2>/dev/null || true)"
  fi
fi
if [ -z "$CARGO_TARGET_DIR" ]; then
  if [ -n "$SLOT_NAME" ]; then
    CARGO_TARGET_DIR="$GATE_QUICK_TARGET_DIR/slot-$SLOT_NAME"
  else
    CARGO_TARGET_DIR="$GATE_QUICK_TARGET_DIR/noslot"
  fi
fi
export CARGO_TARGET_DIR
# The directory is created here: a target directory that does not exist is
# not an error for cargo, but a directory that can not be created is a
# failure of the run, and this one is not fatal (cargo will say it).
mkdir -p "$CARGO_TARGET_DIR" 2>/dev/null || true

# The scratch slot of the run: the files gate-check.sh reads (the sha and the
# path of the log) and the verdict it writes. It is NOT the slot of the
# complete gate: the verdict of the scope never lands in gates/<slot>/verdict
# nor in $LOOP_DIR/gate.verdict.
SCRATCH_SLOT="scope-noslot"
if [ -n "$SLOT_NAME" ]; then
  # 54 characters of the slot name: "scope-" and the name fit in the 60
  # characters that gate-check.sh accepts.
  SCRATCH_SLOT="scope-$(printf '%s' "$SLOT_NAME" | cut -c1-54)"
fi

mkdir -p "$LOOP_DIR" 2>/dev/null || true

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-quick.XXXXXX" 2>/dev/null)" || {
  echo "gate-quick: a temporary directory cannot be created" >&2
  exit 1
}
cleanup() {
  # The metrics of the scope are written before the temporary directory
  # goes: they are the last trace of the run.
  if declare -F append_scope_metrics >/dev/null 2>&1; then
    append_scope_metrics
  fi
  # The leftovers of the scope die with the run: an orphan of the nextest
  # keeps the cargo lock of the build directory, and the next gate of the
  # scope dies with "Blocking waiting for file lock on build directory".
  if declare -F kill_scope_leftovers >/dev/null 2>&1; then
    kill_scope_leftovers || true
  fi
  # The lock of the build directory is released here: the run is over.
  if declare -F scope_lock_release >/dev/null 2>&1; then
    scope_lock_release || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- the probe of the belt --------------------------------------------------
# The probe does not run a gate: it creates a scope of the same shape and
# prints the limits that are REALLY in force inside it. It is the check of
# the belt without a gate.
if [ "$PROBE" -eq 1 ]; then
  # The name of the unit of the probe carries the pid of the probe: two
  # probes of the same moment do not fight for the same unit (systemd
  # refuses to create a unit that exists).
  PROBE_UNIT="$(scope_unit_name "probe-$$")"
  if [ "$GATE_QUICK_CGROUP" = "0" ]; then
    # The belt is disabled: no scope is created at all. The probe says so
    # and its exit code says that the belt is NOT in force.
    echo "scope-probe: the belt is disabled (GATE_QUICK_CGROUP=0): no scope" \
      "was created"
    exit 1
  fi
  if [ "${SC_QUICK_CGROUP:-0}" = "1" ]; then
    # The child of the scope: the limits that are really in force.
    # The name of the scope of THIS process: the cgroup of the child is
    # named after the unit of the scope (the unit the parent asked for is
    # the one with the pid of the parent).
    PROBE_REAL_UNIT="$(scope_unit_of_cgroup 2>/dev/null || true)"
    [ -n "$PROBE_REAL_UNIT" ] || PROBE_REAL_UNIT="$PROBE_UNIT"
    echo "scope-probe: the scope is $PROBE_REAL_UNIT" >&2
    scope_probe "$PROBE_REAL_UNIT"
    PROBE_RC=$?
    if [ "$PROBE_RC" -ne 0 ]; then
      # The scope exists but its limits are not in force: the probe says so.
      # The exit code of the probe is the code of a DIAGNOSTIC: 0 when the
      # belt is in force, 1 when it is not. The probe never decides
      # anything: the belt never fails the gate.
      echo "scope-probe: the limits are NOT in force: the belt is not there" >&2
      exit 1
    fi
    exit 0
  fi
  if [ "${SC_QUICK_SCOPE_OFF:-0}" = "1" ]; then
    echo "scope-probe: no belt: the scope can not be created: the limits are" \
      "not in force" >&2
    exit 1
  fi
  # The parent of the probe: it creates the scope and the child prints.
  PROBE_MARKER="$TMP/scope.marker"
  scope_wait_free "$PROBE_UNIT" || true
  run_in_scope "$PROBE_UNIT" "$PROBE_MARKER" bash "$0" "$@"
  PROBE_RC=$?
  if [ "$PROBE_RC" -ne 0 ] && [ ! -e "$PROBE_MARKER" ]; then
    # The scope could not be created (no user bus, a name that is taken, a
    # limit that the kernel refuses): the belt is not there. The probe says
    # so and does NOT hide it: its exit code says that the belt is not in
    # force. The GATE, on the other hand, runs anyway (the belt never fails
    # the gate).
    echo "scope-probe: no belt: the scope can not be created: the limits are" \
      "not in force" >&2
    exit 1
  fi
  exit "$PROBE_RC"
fi

# The debris of the scopes of the previous runs is cleaned BEFORE the scope
# of this run is created: the debris holds the memory of the box and the
# lock of the build directory. Only the copy that is OUTSIDE the scope
# cleans: the copy inside the scope is the run that is working.
if [ "${SC_QUICK_CGROUP:-0}" != "1" ]; then
  cleanup_dead_scopes || true
fi

# --- the belt of the run ----------------------------------------------------
# The three states of the belt (the section of the belt above explains them):
#
#   the child of the scope (SC_QUICK_CGROUP=1) runs the gate inside it;
#   the run whose scope could not be created (SC_QUICK_SCOPE_OFF=1) runs
#   directly;
#   the belt disabled (GATE_QUICK_CGROUP=0) runs directly.
#
# The parent is the only one that creates the scope, and it does it BEFORE
# any compilation: the child of the scope does the whole run.
BELT="off"
if [ "$GATE_QUICK_CGROUP" = "1" ] && [ "${SC_QUICK_CGROUP:-0}" != "1" ] \
    && [ "${SC_QUICK_SCOPE_OFF:-0}" != "1" ]; then
  BELT="on"
fi

if [ "$BELT" = "on" ]; then
  if [ -n "$SLOT_NAME" ]; then
    # The name of the unit carries the pid of the run: systemd refuses to
    # create a unit that exists, and that refusal is SILENT (the belt is
    # not there and the gate runs unbounded). Two runs of the same slot
    # never share a unit.
    SCOPE_UNIT="$(scope_unit_name "$SLOT_NAME-$$")"
  else
    # Without a slot the name of the unit carries the sha of the run and
    # its pid: two runs of two slots never share a unit.
    SCOPE_UNIT="$(scope_unit_name "$(printf '%s' "$SHA" | cut -c1-12)-$$")"
  fi
  SCOPE_MARKER="$TMP/scope.marker"

  # The gate: the scope runs the gate itself. The exit code of the child is
  # the exit code of this script.
  scope_wait_free "$SCOPE_UNIT" || true
  run_in_scope "$SCOPE_UNIT" "$SCOPE_MARKER" bash "$0" "$@"
  BELT_RC=$?
  if [ "$BELT_RC" -ne 0 ] && [ ! -e "$SCOPE_MARKER" ]; then
    # The scope could not be created (no user manager, a name that is taken,
    # a limit that the kernel refuses): the belt is not there. The gate runs
    # WITHOUT it (fail open) and its verdict is the one it always was.
    echo "gate-quick: no belt: the scope can not be created: the run is not" \
      "bounded" >&2
    SC_QUICK_SCOPE_OFF=1 bash "$0" "$@"
    exit $?
  fi
  exit "$BELT_RC"
fi

# --- the lock of the build directory ----------------------------------------
# The target directory of the scoped gate is SHARED by every slot
# (GATE_QUICK_TARGET_DIR): two scoped gates at the same time fight for the
# cargo lock of the build directory, and the loser of that fight does not
# wait: it dies with "Blocking waiting for file lock on build directory"
# (27-10-2026: the clippy of the gate of 20:12 died because the nextest of
# the gate of 20:01 was still alive).
#
# The lock is a flock on a file of the gates directory. It is taken by the
# copy of the gate that runs INSIDE the scope (the one that compiles) and it
# is released when the run ends. The descriptors are closed in the phases
# (9>&- 8>&-): a phase that leaves an orphan behind must not keep the lock.
#
# There are TWO locks, and they answer two different questions:
#
#   1. The GLOBAL one ($GATES_DIR/scope.lock), in SHARED mode. It is the
#      lock of the belt: whoever takes it in EXCLUSIVE mode (the complete
#      gate, an operator, another tool) stops every scoped gate, and the
#      scoped gate postpones itself. Two scoped gates SHARE it: they do not
#      fight with each other, because every slot compiles in a target
#      directory of its own.
#   2. The one of the SLOT ($GATES_DIR/<slot>/scope.lock), in EXCLUSIVE
#      mode: two runs of the SAME slot do not run at the same time (they
#      would write the same verdict and the same target directory).
#
# When a lock is busy the scope is DEFERRED: the run is postponed, not
# judged (like the deferral of the complete gate).
SCOPE_LOCK_FILE="$GATES_DIR/scope.lock"

scope_lock_acquire() {
  local global_file="${SCOPE_LOCK_FILE:-}"
  local slot_file="${SCOPE_SLOT_LOCK_FILE:-}"
  if [ -z "$global_file" ]; then
    global_file="$GATES_DIR/scope.lock"
  fi
  mkdir -p "$GATES_DIR" 2>/dev/null || true
  # The descriptor is opened in WRITE mode: an exclusive flock needs a
  # writable descriptor. The writability is checked in a subshell (the
  # redirections of an `exec` without a command stay in the shell: the
  # stderr of the gate can not be sent to /dev/null by accident). A failure
  # here is NOT fatal: the run goes on without the lock (the belt never
  # fails the gate).
  if ! ( : >>"$global_file" ) 2>/dev/null; then
    return 1
  fi
  exec 9>>"$global_file" || return 1
  # The global lock is SHARED: two scoped gates of two slots can run at the
  # same time. It only fails when somebody holds it in exclusive mode.
  if ! flock -s -w "$GATE_SCOPE_LOCK_WAIT" 9 2>/dev/null; then
    exec 9>&- || true
    return 1
  fi
  # The lock of the slot: exclusive, and only when the slot is known (a run
  # without a slot has no verdict of its own to protect).
  if [ -n "${SLOT_NAME:-}" ]; then
    if [ -z "$slot_file" ]; then
      slot_file="$GATES_DIR/$SLOT_NAME/scope.lock"
      mkdir -p "$GATES_DIR/$SLOT_NAME" 2>/dev/null || true
    fi
    if ! ( : >>"$slot_file" ) 2>/dev/null; then
      exec 9>&- || true
      return 1
    fi
    exec 8>>"$slot_file" || { exec 9>&- || true; return 1; }
    if ! flock -x -w "$GATE_SCOPE_LOCK_WAIT" 8 2>/dev/null; then
      exec 8>&- || true
      exec 9>&- || true
      return 1
    fi
  fi
  return 0
}

scope_lock_release() {
  exec 8>&- || true
  exec 9>&- || true
  return 0
}

# A verdict of THIS slot about THIS sha that is not a postponement: it is a
# verdict, and a deferral does not throw it away.
scope_verdict_is_fresh() {
  local file sha="" verdict="" status=""
  [ -n "$SLOT_NAME" ] || return 1
  file="$GATES_DIR/$SLOT_NAME/scope.verdict"
  [ -f "$file" ] || return 1
  sha="$(awk -F= '/^SHA=/{print $2; exit}' "$file" 2>/dev/null || true)"
  verdict="$(awk -F= '/^VERDICT=/{print $2; exit}' "$file" 2>/dev/null || true)"
  status="$(awk -F= '/^GATE_STATUS=/{print $2; exit}' "$file" 2>/dev/null || true)"
  [ "$sha" = "$SHA" ] || return 1
  [ "$status" = "finished" ] || return 1
  case "$verdict" in
    VERDE-SCOPE|ROJO-SCOPE) return 0 ;;
  esac
  return 1
}

# --- the verdicts ----------------------------------------------------------
# The scope verdict is authoritative; the legacy file is its mirror, with the
# vocabulary it has always had. Both are written by ONE function, so they can
# never disagree about the run they are about.
write_scope_file() {
  # write_scope_file <status> <scope> <kind> <verdict> <failures> <tests> <checks> [deferred]
  local status="$1" scope="$2" kind="$3" verdict="$4" failures="$5"
  local tests="$6" checks="$7" deferred="${8:-}"
  local dir="$GATES_DIR/$SLOT_NAME"
  local file="$dir/scope.verdict"
  local tmp="$file.tmp"
  mkdir -p "$dir" 2>/dev/null || true
  # The verdict of the PREVIOUS run of this slot is removed BEFORE the new one
  # is written. The file is named after the SLOT and the slot is named after
  # the issue, so a slot that dies and is taken again finds the verdict of
  # the dead one: a green verdict of another commit, still on disk, that
  # reads as "this one is green" to whoever looks at it. The file is written
  # atomically at the end of the run, so the window between the removal and
  # the write is the window in which there is NO verdict: that is the honest
  # state ("the gate has not judged this commit yet").
  run_child rm -f "$file" 2>/dev/null || true
  if ! {
    printf 'GATE_STATUS=%s\n' "$status"
    printf 'SCOPE=%s\n' "$scope"
    printf 'SCOPE_KIND=%s\n' "$kind"
    printf 'VERDICT=%s\n' "$verdict"
    printf 'NEW_FAILURES=%s\n' "$failures"
    printf 'FAILED_TESTS=%s\n' "$tests"
    printf 'CHECKS=%s\n' "$checks"
    printf 'SHA=%s\n' "$SHA"
    printf 'AT=%s\n' "$(run_child date +%s)"
    if [ -n "$deferred" ]; then
      printf 'DEFERRED=%s\n' "$deferred"
    fi
  } > "$tmp" 2>/dev/null; then
    run_child rm -f "$tmp" 2>/dev/null || true
    echo "gate-quick: the verdict file cannot be written: $file" >&2
    return 1
  fi
  if ! run_child mv -f "$tmp" "$file" 2>/dev/null; then
    run_child rm -f "$tmp" 2>/dev/null || true
    echo "gate-quick: the verdict file cannot be replaced: $file" >&2
    return 1
  fi
  return 0
}

write_legacy_file() {
  # write_legacy_file <status> <scope> <verdict> <failures> [deferred]
  local status="$1" scope="$2" verdict="$3" failures="$4" deferred="${5:-}"
  local tmp="$VERDICT_FILE.tmp"
  if ! {
    printf 'GATE_STATUS=%s\n' "$status"
    printf 'SCOPE=%s\n' "$scope"
    printf 'VERDICT=%s\n' "$verdict"
    printf 'NEW_FAILURES=%s\n' "$failures"
    printf 'PUBLISHABLE=no\n'
    printf 'SHA=%s\n' "$SHA"
    printf 'AT=%s\n' "$(run_child date +%s)"
    if [ -n "$deferred" ]; then
      printf 'DEFERRED=%s\n' "$deferred"
    fi
  } > "$tmp" 2>/dev/null; then
    run_child rm -f "$tmp" 2>/dev/null || true
    echo "gate-quick: the verdict file cannot be written: $VERDICT_FILE" >&2
    return 1
  fi
  if ! run_child mv -f "$tmp" "$VERDICT_FILE" 2>/dev/null; then
    run_child rm -f "$tmp" 2>/dev/null || true
    echo "gate-quick: the verdict file cannot be replaced: $VERDICT_FILE" >&2
    return 1
  fi
  return 0
}

write_verdicts() {
  # write_verdicts <status> <scope> <kind> <verdict> <failures> <tests> <checks> [deferred]
  local status="$1" scope="$2" kind="$3" verdict="$4" failures="$5"
  local tests="$6" checks="$7" deferred="${8:-}"
  local legacy
  case "$verdict" in
    VERDE-SCOPE) legacy="VERDE-PARCIAL" ;;
    ROJO-SCOPE) legacy="ROJO-PARCIAL" ;;
    *) legacy="SKIP" ;;
  esac
  if [ -n "$SLOT_NAME" ]; then
    write_scope_file "$status" "$scope" "$kind" "$verdict" "$failures" \
      "$tests" "$checks" "$deferred" || return 1
  fi
  write_legacy_file "$status" "$scope" "$legacy" "$failures" "$deferred" \
    || return 1
  return 0
}

# --- the scope ------------------------------------------------------------
# The changed paths, NUL separated: that is what affected.py reads.
PATHS_FILE="$TMP/paths"
if ! git -C "$REPO" diff --no-renames --name-only -z "$BASE...$SHA" \
    > "$PATHS_FILE" 2>"$TMP/diff.err"; then
  echo "gate-quick: the diff $BASE...$SHA failed" >&2
  sed 's/^/gate-quick: /' "$TMP/diff.err" >&2
  # The scope is unknown: the conservative assumption is the whole workspace,
  # and the scoped gate does not apply to it.
  write_verdicts failed workspace full SKIP 0 "" "fmt:skipped|layers:skipped|clippy:skipped|check:skipped" \
    || exit 1
  exit 0
fi

# The metadata is read once: affected.py needs it to map the paths.
METADATA_FILE="$TMP/metadata.json"
METADATA_ARGS=()
if (cd "$REPO" && cargo metadata --no-deps --format-version 1 --locked) \
    > "$METADATA_FILE" 2>"$TMP/metadata.err"; then
  METADATA_ARGS=(--metadata "$METADATA_FILE")
fi

AFFECTED_OUT=""
if ! AFFECTED_OUT="$(cd "$REPO" && python3 -I scripts/ci/affected.py \
    --paths "$PATHS_FILE" ${METADATA_ARGS[@]+"${METADATA_ARGS[@]}"})"; then
  echo "gate-quick: scripts/ci/affected.py failed" >&2
  write_verdicts failed workspace full SKIP 0 "" "fmt:skipped|layers:skipped|clippy:skipped|check:skipped" \
    || exit 1
  exit 0
fi

FULL=""
PACKAGES=""
while IFS= read -r line; do
  case "$line" in
    full=*) FULL="${line#full=}" ;;
    packages=*) PACKAGES="${line#packages=}" ;;
  esac
done <<< "$AFFECTED_OUT"

if [ "$FULL" != "true" ] && [ "$FULL" != "false" ]; then
  # The scope could not be read: an unknown scope is not an empty scope.
  echo "gate-quick: scripts/ci/affected.py did not answer with a scope" >&2
  write_verdicts failed workspace full SKIP 0 "" "fmt:skipped|layers:skipped|clippy:skipped|check:skipped" \
    || exit 1
  exit 0
fi

if [ "$FULL" = "true" ]; then
  # The scoped gate does not apply: the change can move every package, so
  # only the complete gate can say something about the workspace.
  echo "gate-quick: the change touches the whole workspace: run the complete gate" >&2
  echo "gate-quick: (cargo xtask ci) to have a publishable verdict" >&2
  write_verdicts skipped workspace full SKIP 0 "" "fmt:skipped|layers:skipped|clippy:skipped|check:skipped" \
    || exit 1
  exit 0
fi
if [ -z "$PACKAGES" ]; then
  echo "gate-quick: no code changed: nothing to check" >&2
  write_verdicts skipped empty empty SKIP 0 "" "fmt:skipped|layers:skipped|clippy:skipped|check:skipped" \
    || exit 1
  exit 0
fi

# The complete gate is alive: the machine is busy (the complete gate holds
# tens of GB of memory and saturates the CPU). A scoped gate launched next
# to it competes with it for the memory, and the loser of that competition is
# the COMPLETE GATE (the OOM killer takes the biggest process): the run that
# is in the middle is lost. The scope is DEFERRED: nothing is compiled and
# nothing is tested.
#
# The deferral is NOT a red verdict and NOT a green one: the run is
# postponed, not judged. The verdict file says so with
# GATE_STATUS=skipped and DEFERRED=complete-gate-alive, and the state
# machine reads it as "no verdict" (a scope that is not finished).
#
# It is deferred in BOTH cases: with the same sha the work is redundant
# (the complete gate is already checking it) and with another sha the
# machine is busy.
DEFER_PID=""
DEFER_PID="$(complete_gate_pid 2>/dev/null || true)"
if [ -n "$DEFER_PID" ]; then
  echo "gate-quick: the complete gate is alive (pid $DEFER_PID): the scope is" \
    "deferred (it would compete with it for the memory)" >&2
  write_verdicts skipped "$PACKAGES" packages SKIP 0 "" \
    "fmt:skipped|layers:skipped|clippy:skipped|check:skipped" "complete-gate-alive" \
    || exit 1
  exit 0
fi

# The lock of the build directory: every slot compiles in a target directory
# of its own, but two runs of the SAME slot (the retry of a run, a slot that
# the supervisor starts twice) would fight for the cargo lock of that
# directory and write the same verdict. The loser of that fight does not
# wait: it is DEFERRED, exactly like the deferral of the complete gate.
#
# The deferral NAMES the slot and the directory it waits for: an operator
# that reads the log has to know which run is waiting and why.
if ! scope_lock_acquire; then
  if scope_verdict_is_fresh; then
    # The verdict of this sha is already there: the deferral does not throw
    # it away.
    echo "gate-quick: the slot ${SLOT_NAME:-<none>} is running elsewhere:" \
      "the verdict of this sha is kept" >&2
    exit 0
  fi
  echo "gate-quick: the scope of the slot ${SLOT_NAME:-<none>} is deferred:" \
    "another run holds the lock of its target directory" \
    "(${CARGO_TARGET_DIR:-<default>})" >&2
  write_verdicts skipped "$PACKAGES" packages SKIP 0 "" \
    "fmt:skipped|layers:skipped|clippy:skipped|check:skipped" \
    "scope-gate-alive" \
    || exit 1
  exit 0
fi

SCOPE="$PACKAGES"
echo "gate-quick: scope: $SCOPE" >&2

# The scope of the tests WITH the dependents: the same script that computed
# the scope of the change (scripts/ci/affected.py) knows the packages that
# depend on the ones that hold the changed files. The gate asks it a second
# time, with the same paths and the same metadata, and only when the knob
# asks for it.
#
# It fails OPEN: when the script does not answer, the scope of the tests
# stays the narrow one (the owners) and the verdict of the gate is the one
# it would have been. A knob that is broken never turns a green gate red.
affected_dependents_scope() {
  local out=""
  if ! out="$(cd "$REPO" && run_child python3 -I scripts/ci/affected.py \
      --paths "$PATHS_FILE" ${METADATA_ARGS[@]+"${METADATA_ARGS[@]}"} \
      2>"$TMP/dependents.err")"; then
    echo "gate-quick: the scope with the dependents could not be computed:" \
      "the tests run on the narrow scope" >&2
    if [ -f "$TMP/dependents.err" ]; then
      run_child sed 's/^/gate-quick: /' "$TMP/dependents.err" >&2
    fi
    return 1
  fi
  local full="" packages=""
  while IFS= read -r line; do
    case "$line" in
      full=*) full="${line#full=}" ;;
      packages=*) packages="${line#packages=}" ;;
    esac
  done <<< "$out"
  # full=true is the whole workspace: there is no narrower scope to widen to.
  if [ "$full" != "false" ] || [ -z "$packages" ]; then
    echo "gate-quick: the scope with the dependents is not a scope:" \
      "the tests run on the narrow scope" >&2
    return 2
  fi
  printf '%s\n' "$packages"
  return 0
}

# The scope of the TESTS is narrower than the scope of the COMPILATION: the
# tests that run are the ones of the crate whose directory holds the file
# that changed. The packages that DEPEND on it still have to compile (the
# clippy and the check of the workspace keep the whole scope), but their
# tests are not the tests of this change: running them is what makes the
# gate of a small change cost as much as the whole workspace.
#
# When the scope of the tests cannot be computed, the tests run on the whole
# scope: a narrower run is an optimization, a wrong narrower run is a green
# that hides a red.
TEST_SCOPE=""
TOUCHED_OUT=""
if [ -s "$METADATA_FILE" ]; then
  if TOUCHED_OUT="$(run_child python3 -I "$TOUCHED_SCRIPT" \
      --paths "$PATHS_FILE" --metadata "$METADATA_FILE" \
      2>"$TMP/touched.err")"; then
    TOUCHED_NARROW=""
    TEST_PACKAGES=""
    while IFS= read -r line; do
      case "$line" in
        packages=*) TEST_PACKAGES="${line#packages=}" ;;
        narrow=*) TOUCHED_NARROW="${line#narrow=}" ;;
      esac
    done <<< "$TOUCHED_OUT"
    if [ "$TOUCHED_NARROW" = "true" ] && [ -n "$TEST_PACKAGES" ]; then
      TEST_SCOPE="$TEST_PACKAGES"
    fi
  else
    echo "gate-quick: the scope of the tests could not be computed:" \
      "the tests run on the whole scope" >&2
    run_child sed 's/^/gate-quick: /' "$TMP/touched.err" >&2
  fi
fi
# The knob of the dependents: the scope of the TESTS may also be the packages
# that DEPEND on the ones that hold the changed files. It is OFF by default
# and it never widens the scope of the COMPILATION (the clippy and the check
# of the workspace keep the scope they have).
if [ "$NEXTEST_INCLUDE_DEPENDENTS" = "1" ] && [ -n "$TEST_SCOPE" ]; then
  DEPS_SCOPE=""
  if DEPS_SCOPE="$(affected_dependents_scope)"; then
    if [ "$DEPS_SCOPE" != "$TEST_SCOPE" ]; then
      echo "gate-quick: the scope of the tests includes the dependents:" \
        "$DEPS_SCOPE" >&2
      TEST_SCOPE="$DEPS_SCOPE"
    fi
  fi
fi
if [ -n "$TEST_SCOPE" ]; then
  echo "gate-quick: the tests run on: $TEST_SCOPE" >&2
else
  echo "gate-quick: the tests run on the whole scope: $SCOPE" >&2
fi
echo "gate-quick: budget: ${TIMEOUT_MIN} min, slot: ${SLOT_NAME:-<none>}, target dir: ${CARGO_TARGET_DIR:-<default>}" >&2

# --- the run --------------------------------------------------------------
LOG_DIR="$LOOP_DIR/logs"
run_child mkdir -p "$LOG_DIR" 2>/dev/null || true
STAMP="$(run_child date +%s)"
LOG_FILE="$LOG_DIR/gate-quick-${SHA:0:12}-${STAMP}.log"
NEXTEST_LOG="$LOG_DIR/gate-quick-nextest-${SHA:0:12}-${STAMP}.log"

# The GPU stack of the run, in the log: if the adapter is not resolvable
# the tests that need one will panic, and the panic has nothing to do with
# the change. The check only WARNS: the verdict is the one of the tests.
gpu_stack_warning >> "$LOG_FILE" 2>&1 || true

# The budget of the WHOLE run (computed at the top of the script, before
# anything is done: the deadline is the clock of the whole run, the scope of
# the change included). Every phase has its own slice of it, so one phase can
# never eat the budget of the others. The budget is the clock of the gate:
# it is computed in the configuration above, because the scope of the run
# needs it for its RuntimeMaxSec (the internal timeout fires first).
# The slice of the fmt phase, with an ABSOLUTE FLOOR.
#
# WHY (14-11-2026): `cargo fmt --all -- --check` is a single-threaded walk of
# the whole tree. It takes ~67 s on an IDLE box and it takes SEVERAL MINUTES on
# a loaded one (two agents and a gate compiling at once: load 47, measured).
# The 2% slice of a 120 min budget is 144 s, so on a loaded machine the phase
# was killed by its timeout and the gate reported
#   ROJO-SCOPE, CHECKS=fmt:fail|layers:skipped|clippy:skipped|check:skipped
#   FAILED_TESTS=            <- empty: NO test failed
# which is a FALSE red that keeps a pull request in draft for a reason that
# does not exist. A bigger whole-budget does NOT fix it (a 240 min budget only
# buys 288 s for fmt). The floor does.
FMT_MIN_SLICE="${FMT_MIN_SLICE:-900}"
# The floor is ABSOLUTE: the fmt phase NEVER gets less than this many
# seconds, whatever the budget of the run is and whatever the environment
# says. Below this the phase is cut by its timeout on a loaded box and the
# gate publishes a false red.
case "$FMT_MIN_SLICE" in ''|*[!0-9]*) FMT_MIN_SLICE=900 ;; esac
if [ "$FMT_MIN_SLICE" -lt 600 ]; then FMT_MIN_SLICE=600; fi
FMT_SLICE=$(( BUDGET * 2 / 100 ))
if [ "$FMT_SLICE" -lt "$FMT_MIN_SLICE" ]; then FMT_SLICE="$FMT_MIN_SLICE"; fi
# The slice of the RETRY of the fmt phase: when the first attempt is cut
# by its timeout the phase runs AGAIN with a bigger slice (the deadline of
# the run still caps it: the retry never outlives the budget).
FMT_RETRY_SLICE="${FMT_RETRY_SLICE:-$(( FMT_SLICE * 2 ))}"
case "$FMT_RETRY_SLICE" in ''|*[!0-9]*) FMT_RETRY_SLICE=$(( FMT_SLICE * 2 )) ;; esac
if [ "$FMT_RETRY_SLICE" -lt "$FMT_SLICE" ]; then FMT_RETRY_SLICE=$(( FMT_SLICE * 2 )); fi
# The percentages are MEASURED, not guessed (27-10-2026, box of 16 vCPU):
# the clippy of the scope (3 packages) took 2m10s, the check of the whole
# workspace 1m53s, and the tests of the scope 21m41s: 11m17s to LINK the 21
# binaries of the tests of `ui-egui` (250 MB each one) plus 10m25s to RUN
# them. The old repartition (the tests with 40% of the budget) was measured
# on times that do not exist any more: it cut the block of the tests in the
# middle of its own link and answered "we did not get to know" about a
# scope that passes.
#
# The tests are the phase that decides the scope, so they take the lion's
# share: 80% of the budget with the check of the workspace on, 86% with it
# off. The clippy and the check keep a margin over what they measured
# (144s and 144s for 130s and 113s).
#
# The share of the tests is what is LEFT after the others: the sum of the
# slices is EXACTLY the budget whatever the budget is, and the rounding of
# the integer division never takes a second away from the tests.
#
# The check of the whole workspace only runs when it fits (see below): with
# the check on it needs 88% of the budget still free, because the tests
# come after it.
#
# THE CLIPPY SLICE (31-10-2026): 8% of a 30 min budget is 144 s and the
# clippy of a scope of three packages takes 125 s ON A COLD CLIPPY CACHE
# (measured on the slot 10138: 2m05s). The two are within a hair of each
# other, so the phase was cut in the middle of the scope and the gate
# published without a linter. The clippy compiles the scope a SECOND time
# (the artifacts of clippy are not the ones of `cargo check`), so its slice
# has to cover a whole compilation, not a fraction of one: 15% of the budget
# (270 s on 30 min) leaves the margin the measurement asks for.
if [ "$GATE_CHECK_WORKSPACE" = "1" ]; then
  LAYERS_SLICE=$(( BUDGET * 2 / 100 ))
  CLIPPY_SLICE=$(( BUDGET * 15 / 100 ))
  CHECK_SLICE=$(( BUDGET * 8 / 100 ))
else
  LAYERS_SLICE=$(( BUDGET * 2 / 100 ))
  CLIPPY_SLICE=$(( BUDGET * 20 / 100 ))
  CHECK_SLICE=0
fi
NEXTEST_SLICE=$(( BUDGET - FMT_SLICE - LAYERS_SLICE - CLIPPY_SLICE - CHECK_SLICE ))

TIMED_OUT=0
PHASE_STATE="skipped"

seconds_left() {
  echo $(( DEADLINE - $(run_child date +%s) ))
}

# phase <name> <slice-seconds> <log-file> <command> [args...]
# The command runs under `timeout`, so it cannot outlive its slice, and the
# slice is never longer than what is left of the budget. The state of the
# phase is left in PHASE_STATE: ok, fail or skipped (the budget was over
# before the phase could start).
phase() {
  local name="$1" slice="$2" log="$3"
  shift 3
  local remaining limit status
  remaining="$(seconds_left)"
  if [ "$remaining" -le 0 ]; then
    echo "gate-quick: the budget ran out before the $name phase" >&2
    TIMED_OUT=1
    PHASE_STATE="skipped"
    return 124
  fi
  limit="$slice"
  if [ "$limit" -gt "$remaining" ]; then limit="$remaining"; fi
  echo "gate-quick: $name" >&2
  # The output of the phase goes to a file of its own first: the safety
  # net of sccache has to know whether the failure of the phase names
  # the cache (and it must not read the phases that came before).
  out="$(run_child mktemp "${TMPDIR:-/tmp}/gate-quick-phase.XXXXXX" 2>/dev/null)" \
    || out="/dev/null"
  # The descriptors of the lock (8 and 9) are CLOSED in the phase: a phase
  # that leaves an orphan behind (the binaries of the tests escape the kill
  # of the group of processes) must not keep the lock taken, or the next
  # gate of the slot is deferred FOREVER.
  run_child timeout --kill-after=30 "$limit" "$@" > "$out" 2>&1
  status=$?
  run_child cat "$out" >> "$log" 2>/dev/null || true
  # The safety net of sccache: a cache that breaks is not a code that
  # breaks. The phase is retried ONCE without the wrapper, and ONLY when the
  # output of the phase names sccache: a lint that fails fails the
  # same way without the cache, and retrying it would only burn the
  # budget of the run.
  if [ "$status" -ne 0 ] && [ "$status" -ne 124 ] && [ "$status" -ne 137 ] \
     && [ "$GATE_SCCACHE" = "1" ] && [ -n "${RUSTC_WRAPPER:-}" ] \
     && run_child grep -qi "sccache" "$out" 2>/dev/null; then
    echo "gate-quick: the phase $name failed with sccache:" \
      "it is retried once without it" >&2
    remaining="$(seconds_left)"
    if [ "$remaining" -gt 0 ]; then
      limit="$slice"
      if [ "$limit" -gt "$remaining" ]; then limit="$remaining"; fi
      : > "$out"
      run_child env -u RUSTC_WRAPPER timeout --kill-after=30 "$limit" "$@" \
        > "$out" 2>&1
      status=$?
      run_child cat "$out" >> "$log" 2>/dev/null || true
    fi
  fi
  run_child rm -f "$out"
  # The leftovers of the scope die with the phase: the binaries of the tests
  # escape the kill of the group of processes and keep the cargo lock of the
  # build directory.
  kill_scope_leftovers || true
  if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
    echo "gate-quick: the budget ran out during the $name phase" >&2
    # A SOFT phase does not eat the run: it is skipped and the run goes on
    # with the phases that come after. The check of the workspace is soft
    # because a timeout of it is NOT "the workspace does not compile": it is
    # "we did not get to know". A phase that stops the run here would take
    # the tests of the scope with it, and a scope without tests is red: the
    # gate of the scope would not publish anything, ever.
    if [ "${PHASE_SOFT:-0}" = "1" ]; then
      echo "gate-quick: the phase $name did not finish: it is skipped" >&2
      PHASE_STATE="skipped"
      return "$status"
    fi
    TIMED_OUT=1
    PHASE_STATE="fail"
    return "$status"
  fi
  if [ "$status" -eq 0 ]; then PHASE_STATE="ok"; else PHASE_STATE="fail"; fi
  return "$status"
}

# SMLIB (2026-11-03): the feature smlib of the CLI is on BY DEFAULT
# (apps/solidcraft-cli/Cargo.toml: default = ["raytrace-cpu", "smlib", "profile"]).
# A scoped build WITHOUT the cli compiles the kernel without SMLib, and then EVERY
# geometric test fails with "SMLib extrude: not supported yet: this build has no
# SMLib": 2210 FALSE failures in the gate of the slot 9086, and the same shape of
# false red in every gate whose scope did not happen to include the cli. The
# upstream CI builds the whole workspace, so it always has SMLib, and its
# tests/KNOWN_FAILING_TESTS only lists 43 failures. The cli is added to the scope
# here so the feature unifies with the crates under test, exactly like upstream.
# Without this, a green branch reads as a red one and the agent goes to fix tests
# that the upstream does not even run.
SMLIB_PACKAGE=solidcraft-cli
if [ -n "${SCOPE:-}" ]; then
  case " $SCOPE " in
    *" $SMLIB_PACKAGE "*) : ;;
    *) SCOPE="$SCOPE $SMLIB_PACKAGE" ;;
  esac
fi
if [ -n "${TEST_SCOPE:-}" ]; then
  case " $TEST_SCOPE " in
    *" $SMLIB_PACKAGE "*) : ;;
    *) TEST_SCOPE="$TEST_SCOPE $SMLIB_PACKAGE" ;;
  esac
fi

# The scope of the two commands that take the packages: ONE invocation with a
# -p per package, never one invocation per package.
SCOPE_ARGS=()
for pkg in $SCOPE; do
  SCOPE_ARGS+=(-p "$pkg")
done

# The scope of the RUNNER: the crate whose directory holds the file that
# changed. When it is unknown, the runner gets the whole scope: a narrower
# run is an optimization, a wrong narrower run is a green that hides a red.
TEST_SCOPE_ARGS=()
if [ -n "$TEST_SCOPE" ]; then
  for pkg in $TEST_SCOPE; do
    TEST_SCOPE_ARGS+=(-p "$pkg")
  done
else
  TEST_SCOPE_ARGS=("${SCOPE_ARGS[@]}")
fi

# The filter of the runner: the one of a pull request of the upstream CI. It
# leaves out the action matrix sample (the merge queue runs it) and the tests
# of the GPU path tracer (they have a job of their own).
NEXTEST_FILTER='(default() & not (binary(action_matrix) & test(=action_matrix_sample)))'
NEXTEST_FILTER="$NEXTEST_FILTER & not (package(=solidcraft-gpu) & test(/^path::/))"

FMT_STATE="skipped"
LAYERS_STATE="skipped"
CLIPPY_STATE="skipped"
CHECK_STATE="skipped"
NEXTEST_STATE="skipped"
# The flag of a run of the tests that was CUT by the timeout of the gate.
NEXTEST_TIMED_OUT=0
# The reason of a DEFERRAL: the scope was postponed, not judged. It is
# written in the verdict file only when there is no real problem.
DEFERRED=""
STATUS="finished"
PROBLEMS=0

if ! command -v cargo >/dev/null 2>&1; then
  echo "gate-quick: cargo is not in the PATH: the scope is not checked" >&2
  STATUS="failed"
  PROBLEMS=$(( PROBLEMS + 1 ))
else
  # 1. the format of the whole repository (seconds)
  #
  #    WHY THE RETRY (15-11-2026): the fmt phase is the FIRST phase of the
  #    run and the first one to die on a loaded box: `cargo fmt --all
  #    -- --check` is a single-threaded walk of the whole tree (~67 s on an
  #    idle box, SEVERAL MINUTES on a loaded one). When the timeout of its
  #    slice killed it, the phase answered "fail" and the gate published
  #      ROJO-SCOPE, CHECKS=fmt:fail|layers:skipped|clippy:skipped|check:skipped
  #      FAILED_TESTS=            <- empty: NO test failed
  #    which is a FALSE red that keeps a pull request in draft for a reason
  #    that does not exist.
  #
  #    So a TIMEOUT of this phase is NOT a formatting difference: the phase
  #    is run AGAIN with a bigger slice, and only a REAL difference (cargo
  #    fmt exiting non-zero with a diff) is fmt:fail. A phase that does not
  #    finish even with the bigger slice is SKIPPED: the format was not
  #    judged, and the scope keeps the verdict of the phases that DID
  #    finish.
  fmt_status=0
  phase "fmt" "$FMT_SLICE" "$LOG_FILE" cargo fmt --all -- --check
  fmt_status=$?
  # 124/137 with the phase already in "skipped": the budget of the run was
  # over before the phase could start. There is nothing to retry: the run
  # is over and the scope was not judged.
  if { [ "$fmt_status" -eq 124 ] || [ "$fmt_status" -eq 137 ]; } \
     && [ "$PHASE_STATE" != "skipped" ]; then
    echo "gate-quick: the fmt phase was cut by its timeout: it is run again" \
      "with ${FMT_RETRY_SLICE}s" >&2
    TIMED_OUT=0
    phase "fmt (retry)" "$FMT_RETRY_SLICE" "$LOG_FILE" cargo fmt --all -- --check
    fmt_status=$?
    if [ "$fmt_status" -eq 124 ] || [ "$fmt_status" -eq 137 ]; then
      # The format was NOT judged, even with the bigger slice: that is not
      # a format error and it is not a green either. The scope is DEFERRED
      # (the run is cut and the gate runs again when the machine is free)
      # instead of publishing a red that does not exist.
      echo "gate-quick: the fmt phase did not finish even with ${FMT_RETRY_SLICE}s:" \
        "the format was not judged" >&2
      TIMED_OUT=1
      PHASE_STATE="skipped"
    fi
  fi
  FMT_STATE="$PHASE_STATE"
  if [ "$FMT_STATE" = "fail" ]; then PROBLEMS=$(( PROBLEMS + 1 )); fi

  # 2. the dependency layers of the whole repository (seconds)
  #    WHY THE ci PROFILE (31-10-2026): `cargo xtask layers` is an alias for
  #    `cargo run --package xtask --`, so it compiles in the DEFAULT profile
  #    (dev): a second build of the world in the same target directory, in
  #    debug, with incremental on. It cost 20 GB per slot and it ate the
  #    whole slice of the phase (36 s of a 30 min budget) compiling a crate
  #    whose result is a table of dependencies. The ci profile is the one the
  #    rest of the gate uses, it is already warm in the target directory of
  #    the slot, and it does not leave a debug tree behind.
  if [ "$TIMED_OUT" -eq 0 ]; then
    # The phase is SOFT: a timeout here is "we did not get to know", not "the
    # layers are wrong". The check of the layers is a table of dependencies
    # of the manifests: it does not depend on the change, and the CI of the
    # upstream runs it on every push. A HARD phase would take the scope with
    # it and a scope without tests is red: the gate would publish nothing.
    PHASE_SOFT=1
    phase "cargo xtask layers" "$LAYERS_SLICE" "$LOG_FILE" \
      cargo run --profile ci --package xtask -- layers
    unset PHASE_SOFT
    LAYERS_STATE="$PHASE_STATE"
    if [ "$LAYERS_STATE" = "fail" ]; then PROBLEMS=$(( PROBLEMS + 1 )); fi
  fi

  # 3. the linter, on the scope only
  #    The phase is SOFT: the clippy is the phase that GROWS with the scope
  #    (130s for three packages, measured the 27-10-2026), so a scope of
  #    five packages can need more than its slice. A cut linter is NOT "the
  #    code is wrong", it is "we did not get to know": the scope keeps its
  #    tests and the gate publishes on them. A HARD phase would take the
  #    scope with it, and a scope without a verdict is red: the agent would
  #    go and fix a linter that was only late. The FAILURES of the linter
  #    (its exit code) are still red: only its timeout is a postponement.
  if [ "$TIMED_OUT" -eq 0 ]; then
    PHASE_SOFT=1
    phase "clippy (${SCOPE})" "$CLIPPY_SLICE" "$LOG_FILE" \
      cargo clippy "${SCOPE_ARGS[@]}" --all-targets --profile ci --locked -- -D warnings
    unset PHASE_SOFT
    CLIPPY_STATE="$PHASE_STATE"
    if [ "$CLIPPY_STATE" = "fail" ]; then PROBLEMS=$(( PROBLEMS + 1 )); fi
  fi

  # 4. the check of the WHOLE workspace, not only of the scope: the scope
  #    of a change is a PACKAGE, so the gate of the scope never compiles
  #    the crates the change does not touch. It goes AFTER the clippy of
  #    the scope because the clippy leaves the dependencies of the scope
  #    compiled in the target dir: the check of the workspace is then
  #    incremental WITH RESPECT TO THE SCOPE, but the workspace has 13
  #    crates and the scope of a change is one or two of them, so the
  #    check still compiles the others: it is NOT cheap (4m31s cold,
  #    measured the 27-10-2026) and it needs a slice of its own.
  if [ "$GATE_CHECK_WORKSPACE" = "1" ] && [ "$TIMED_OUT" -eq 0 ]; then
    # The check only runs when it FITS: the time that is left has to pay
    # for the check AND for the tests of the scope. The computation of the
    # scope (cargo metadata + affected.py) is part of the budget and takes
    # 1-5 min, so a slow turn can arrive here with less time than the check
    # needs. A check that eats the time of the tests leaves the scope
    # without tests, and a scope without tests is red: the gate of the
    # scope would publish nothing, ever. Skipping the check is "we did not
    # get to know", and the scope still gets its tests.
    CHECK_NEEDED=$(( CHECK_SLICE + NEXTEST_SLICE ))
    CHECK_LEFT="$(seconds_left)"
    if [ "$CHECK_LEFT" -ge "$CHECK_NEEDED" ]; then
      # The phase is SOFT: a timeout here is a "skipped", not a failure of the
      # run (the tests of the scope still have to run). A compile error is
      # still a failure, and still red.
      PHASE_SOFT=1
      phase "check --workspace" "$CHECK_SLICE" "$LOG_FILE" \
        cargo check --workspace --all-targets --profile ci --locked
      unset PHASE_SOFT
      CHECK_STATE="$PHASE_STATE"
      if [ "$CHECK_STATE" = "fail" ]; then PROBLEMS=$(( PROBLEMS + 1 )); fi
    else
      echo "gate-quick: the check --workspace does not fit in the time that is left (${CHECK_LEFT}s < ${CHECK_NEEDED}s): it is skipped" >&2
      CHECK_STATE="skipped"
    fi
  fi

  # 5. the tests, with the runner of the upstream CI. The GPU is the software
  #    one and it is REQUIRED: a test that would skip for want of an adapter
  #    fails instead, exactly as in the upstream `tests` job.
  #
  #    The phase is SOFT: a timeout of the tests is NOT a failure of the
  #    change, it is "we did not get to know". The run is CUT, the scope is
  #    DEFERRED and the gate runs again when the machine is free. A hard
  #    phase would take the scope with it, and a scope without a verdict is
  #    red: the agent would go and fix tests that pass.
  if [ "$TIMED_OUT" -eq 0 ]; then
    # The share of the threads is decided HERE, at the last moment: the
    # other gate is only visible when it is running its own tests.
    gate_share_threads
    PHASE_SOFT=1
    phase "nextest (${TEST_SCOPE:-$SCOPE})" "$NEXTEST_SLICE" "$NEXTEST_LOG" \
      env SOLIDCRAFT_GPU=software SOLIDCRAFT_REQUIRE_GPU=1 \
      cargo nextest run "${TEST_SCOPE_ARGS[@]}" --cargo-profile ci --locked \
      --profile local-ci --no-tests=pass --retries 0 \
      --test-threads "$NEXTEST_THREADS" --ignore-default-filter \
      -E "$NEXTEST_FILTER"
    NEXTEST_STATUS=$?
    unset PHASE_SOFT
    if [ "$TIMED_OUT" -eq 1 ]; then
      # The budget was over before the phase could start: there is no run
      # and no log. The scope was NOT judged.
      NEXTEST_STATE="skipped"
    else
      NEXTEST_STATE="ran"
      # The exit code of the run goes to the log: the parser of the loop reads it.
      printf 'EXIT=%s\n' "$NEXTEST_STATUS" >> "$NEXTEST_LOG"
      run_child cat "$NEXTEST_LOG" >> "$LOG_FILE" 2>/dev/null || true
      if [ "$NEXTEST_STATUS" -eq 124 ] || [ "$NEXTEST_STATUS" -eq 137 ]; then
        # The run was CUT by the timeout of the gate: the tests that were
        # running died with it and the log says "SIGTERM". That is not a
        # failure of the change: the scope was NOT judged.
        NEXTEST_TIMED_OUT=1
        NEXTEST_STATE="cut"
        echo "gate-quick: the tests were cut by the timeout of the gate:" \
          "the scope is deferred, not red" >&2
      fi
    fi
  fi
fi

if [ "$TIMED_OUT" -eq 1 ]; then
  # The budget ran out. The scope was NOT judged: it was POSTPONED. Whether
  # that is a deferral or a red is decided at the end, when every problem is
  # known: a deferral never hides a real problem.
  if [ "$PROBLEMS" -gt 0 ]; then
    STATUS="failed"
  fi
  echo "gate-quick: the quick gate ran out of time (${TIMEOUT_MIN} min)" >&2
fi

CHECKS="fmt:$FMT_STATE|layers:$LAYERS_STATE|clippy:$CLIPPY_STATE"
CHECKS="$CHECKS|check:$CHECK_STATE"

# --- the verdict of the tests ----------------------------------------------
# The log of the run is judged by bin/gate-check.sh: the only parser of the
# loop. The scratch slot records the sha and the path of the log, so the
# verdict of the parser carries the sha of THIS run (and not the sha of the
# live complete gate) and lands in the scratch slot, never in the file of the
# complete gate.
NEW_TESTS=0
FAILED_TESTS=""
CHECK_VERDICT="ROJO"
CHECK_GATE_STATUS="failed"
CHECK_RUN_CUT="false"
# A run that was CUT is judged too: the log of a cut run holds the failures
# that happened BEFORE the cut, and those are real.
if [ "$NEXTEST_STATE" != "skipped" ] && [ -f "$NEXTEST_LOG" ]; then
  run_child mkdir -p "$GATES_DIR/$SCRATCH_SLOT" 2>/dev/null || true
  printf '%s\n' "$SHA" > "$GATES_DIR/$SCRATCH_SLOT/sha" 2>/dev/null || true
  printf '%s\n' "$NEXTEST_LOG" > "$GATES_DIR/$SCRATCH_SLOT/log" 2>/dev/null || true
  CHECK_OUT="$(run_child bash "$GATE_CHECK" --slot "$SCRATCH_SLOT" \
    "$NEXTEST_LOG" 2>"$TMP/check.err")"
  CHECK_RC=$?
  if [ "$CHECK_RC" -ne 0 ] || [ -z "$CHECK_OUT" ]; then
    echo "gate-quick: gate-check.sh did not answer" >&2
    run_child sed 's/^/gate-quick: /' "$TMP/check.err" >&2
    STATUS="failed"
    PROBLEMS=$(( PROBLEMS + 1 ))
  else
    IN_FAILURES=0
    while IFS= read -r line; do
      case "$line" in
        VERDICT=*) CHECK_VERDICT="${line#VERDICT=}" ;;
        NEW_FAILURES=*) NEW_TESTS="${line#NEW_FAILURES=}" ;;
        GATE_STATUS=*) CHECK_GATE_STATUS="${line#GATE_STATUS=}" ;;
        RUN_CUT=*) CHECK_RUN_CUT="${line#RUN_CUT=}" ;;
        "--- new failures ---") IN_FAILURES=1; continue ;;
      esac
      if [ "$IN_FAILURES" -eq 1 ] && [ -n "$line" ]; then
        if [ -z "$FAILED_TESTS" ]; then
          FAILED_TESTS="$line"
        else
          FAILED_TESTS="$FAILED_TESTS,$line"
        fi
      fi
    done <<< "$CHECK_OUT"
    case "$NEW_TESTS" in ''|*[!0-9]*) NEW_TESTS=0 ;; esac
    # A run that failed without a single identified failure is a problem of
    # the scope, not a green one: it counts as one. A run that was CUT is
    # NOT a problem: the tests that died with the cut are not failures of
    # the change, the scope was simply not judged.
    if [ "$CHECK_VERDICT" != "VERDE" ] && [ "$CHECK_VERDICT" != "SKIP" ] \
        && [ "$NEW_TESTS" -eq 0 ]; then
      PROBLEMS=$(( PROBLEMS + 1 ))
    fi
    # The parser says the run is still going, or that its log is missing: it
    # is not a verdict of a finished run.
    case "$CHECK_GATE_STATUS" in
      finished) ;;
      *) STATUS="failed"; PROBLEMS=$(( PROBLEMS + 1 )) ;;
    esac
  fi
fi

# --- was the scope judged? -------------------------------------------------
# The scope is judged when the tests left a log and the parser read it. A
# scope that was NOT judged is not a green one: the doubt is red. The two
# cases where the reason IS known are deferrals and not reds: the run that
# was CUT by the timeout of the gate, and the budget that ran out before the
# tests could start.
if [ "$NEXTEST_STATE" != "skipped" ] && [ ! -f "$NEXTEST_LOG" ]; then
  if [ "$NEXTEST_TIMED_OUT" -eq 1 ]; then
    echo "gate-quick: the tests were cut and their log is missing:" \
      "the scope was not judged" >&2
  else
    echo "gate-quick: the log of the tests is missing: the scope was not" \
      "judged" >&2
    STATUS="failed"
    PROBLEMS=$(( PROBLEMS + 1 ))
  fi
fi
if [ "$NEXTEST_STATE" = "skipped" ] && [ "$TIMED_OUT" -eq 0 ]; then
  # The tests did not run and the budget is not over: no reason is known.
  echo "gate-quick: the tests did not run and no reason is known:" \
    "the scope was not judged" >&2
  STATUS="failed"
  PROBLEMS=$(( PROBLEMS + 1 ))
fi

# --- the deferral ----------------------------------------------------------
# A DEFERRED scope is not red and it is not green: it was POSTPONED. The
# agent has nothing to fix and the supervisor runs the gate again when the
# machine is free. The deferral is decided HERE, at the end, when every
# problem is known: it is written only when there is no real problem, and it
# never hides a red.
if [ "$PROBLEMS" -eq 0 ] && [ "$NEW_TESTS" -eq 0 ]; then
  if [ "$NEXTEST_TIMED_OUT" -eq 1 ] || [ "$CHECK_VERDICT" = "SKIP" ]; then
    DEFERRED="nextest-timeout"
  elif [ "$TIMED_OUT" -eq 1 ]; then
    DEFERRED="budget-exhausted"
  fi
  if [ -n "$DEFERRED" ]; then
    STATUS="skipped"
    FAILED_TESTS=""
    echo "gate-quick: the scope is deferred (${DEFERRED}), not red" >&2
  fi
fi

NEW_FAILURES=$(( NEW_TESTS + PROBLEMS ))

# The verdict of the scope: green only when nothing FAILED. A phase that was
# CUT is not a failure: it is "we did not get to know", and the scope keeps
# the verdict of the phases that did finish. A phase that FAILED is red,
# always: the code is wrong and the agent has to fix it.
# A DEFERRED scope is not red either: it has no verdict at all, it was
# postponed, and the agent has nothing to fix.
SCOPE_VERDICT="ROJO-SCOPE"
if [ -n "$DEFERRED" ]; then
  SCOPE_VERDICT="SKIP"
  NEW_FAILURES=0
  FAILED_TESTS=""
elif [ "$STATUS" = "finished" ] && [ "$NEW_FAILURES" -eq 0 ] \
    && [ "$FMT_STATE" = "ok" ] && [ "$LAYERS_STATE" = "ok" ] \
    && [ "$CLIPPY_STATE" != "fail" ] \
    && [ "$CHECK_STATE" != "fail" ]; then
  SCOPE_VERDICT="VERDE-SCOPE"
fi

echo "gate-quick: $SCOPE_VERDICT, $NEW_FAILURES new failure(s) in the scope" >&2
if [ -n "$DEFERRED" ]; then
  echo "gate-quick: the scope was deferred (${DEFERRED}): it is not a verdict" >&2
fi
echo "gate-quick: the checks are $CHECKS" >&2
echo "gate-quick: the log is $LOG_FILE" >&2
if [ -z "$SLOT_NAME" ]; then
  echo "gate-quick: the slot is not known: only the global verdict file is written" >&2
fi
write_verdicts "$STATUS" "$SCOPE" packages "$SCOPE_VERDICT" "$NEW_FAILURES" \
  "$FAILED_TESTS" "$CHECKS" "$DEFERRED" || exit 1
# The metrics of the scope are written here, before the exit: the trap of the
# exit is the safety net for the paths that leave the script in another way.
if declare -F append_scope_metrics >/dev/null 2>&1; then
  append_scope_metrics
fi
exit 0
