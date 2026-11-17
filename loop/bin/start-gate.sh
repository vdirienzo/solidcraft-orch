#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Starts the CI gate in the background and records its PID, its log and its
# start marker, so the supervisor knows whether it is still alive. The
# orchestrator runs this and leaves the turn with `phase: gating`: the gate is
# NOT part of the turn (it runs for 58-90 min, the turn is capped at
# MAX_TURN_MIN).
#
#   start-gate.sh <sha> <issue> <slug> [--slot <slot>] [--worktree <path>]
#   start-gate.sh --from-request --slot <slot>
#
# THE SLOT IS THE IDENTITY OF A GATE. A slot is a worktree (the name of its
# directory: `issue-5302`), and every slot has its own files under
# $LOOP_DIR/gates/<slot>/: pid, sha, verdict, log (plus started, worktree and
# request). The gate of one slot never touches the files of another.
#
# The DEFAULT slot (no --slot) is the slot the loop uses today: it keeps
# writing EXACTLY where the loop reads it ($LOOP_DIR/gate.pid, gate.sha,
# gate.path, gate.verdict and $LOOP_DIR/logs/gate-<issue>-<slug>-<sha>.log),
# so state.py's gate_verdict()/gate_sha() and the supervisor's tick do not
# change.
#
# ONE GATE AT A TIME, MANY SLOTS WAITING. The gate is the heaviest thing
# this machine runs: two gates at the same time do not go faster, they take
# twice as long. So there is at most ONE live gate in the whole machine. A
# slot that asks for a gate while another one is running does NOT get it: it
# leaves a REQUEST ($LOOP_DIR/gates/<slot>/request) and waits its turn. The
# supervisor drains the queue (one gate at a time) with
# `start-gate.sh --from-request --slot <slot>`.
#
# THE TEST POOL OF THE GATE IS BOUNDED. The gate runs the whole test suite
# of the workspace (~80 test binaries). Without a bound, xtask starts ALL of
# them at once and the machine saturates (load 231 on 16 vCPU), and the
# tests that assert on wall-clock time fail for that reason alone (the UI
# test with a 250 ms budget measured 449 ms under that load and 190 ms
# alone): FALSE REDS caused by the machine, not by the code. The gate
# exports SOLIDCRAFT_TEST_JOBS and RUST_TEST_THREADS, so the tests run in a
# bounded pool of about one thread per core. The numbers come from
# config.env (GATE_TEST_JOBS, GATE_TEST_THREADS) and can be changed without
# touching this script.
#
# THE GLOBAL SIDECAR IS "THE LIVE GATE", NOT "A SLOT". gate.pid, gate.sha
# and gate.path are rewritten by EVERY gate, whatever slot it belongs to:
# they say that a gate is alive, not which slot it belonged to. The sha and
# the verdict of a slot live in $LOOP_DIR/gates/<slot>/ and the owner of
# that slot freezes them in the state.
#
# Prints the log path on stdout (for the orchestrator to put in the state
# delta). Everything else goes to stderr, so the orchestrator only reads the
# log path. When the gate is only QUEUED there is no log yet: stdout stays
# empty and the exit code says what happened.
#
# THE LOG IS ROTATED, NEVER TRUNCATED. The log of the previous run of the
# same SHA becomes <log>.1 and the new run writes a clean <log>. Truncating
# it (what `StandardOutput=truncate:` does) erased the EXIT= of the run that
# had already finished, and with it the verdict the loop already had: the
# phase went back to 'gated' and the loop published the same PR over and
# over (2026-10-24: PR #5835).
#
# A SHA THAT WAS ALREADY GATED IS NOT GATED AGAIN. The tree did not change,
# so the verdict of the run that already finished IS the verdict of that
# SHA: relaunching it burns an hour of CPU and throws the verdict away.
#
# A RED QUICK GATE REFUSES THE COMPLETE ONE. The quick gate
# (bin/gate-quick.sh) checks the packages the change touches in 1-5 min: if
# it is red for THIS SHA, the complete gate would spend 50-75 min on code
# that is already known to be broken, so it is not launched. The refusal has
# its own exit code (10): it is not a failure of the turn, the phase stays
# `implemented` and the next turn fixes the code.
#
# Exit codes:
#   0  the gate started (its log path is on stdout)
#   2  usage error
#   3  the worktree of the slot does not exist
#   4  the checkout of the SHA failed
#   5  THIS SLOT already has a live gate (nothing was launched)
#   6  the gate was QUEUED: another gate is running (the request is in
#      $LOOP_DIR/gates/<slot>/request)
#   7  the worktree is in use by the live gate of another slot
#   8  this SHA was already gated (its log has a finished run): nothing was
#      launched and that verdict is still the verdict of this SHA
#  10  the QUICK gate is RED for this SHA: the complete gate was NOT
#      launched (an hour of CI on code that is already known to be broken)
#
# The PID of the gate is written by the gate itself, in its own session: the
# old pid file is removed BEFORE the launch and the wait below looks for a
# NEW file, so the supervisor never reads the PID of the previous gate as if
# it were this one's.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"

# The directory of this script: the checker of the configuration
# (bin/config-preflight.sh) lives next to it and it is called by path,
# never by a guess.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GATES_DIR="$LOOP_DIR/gates"

# The command the gate runs. SOLIDCRAFT_GATE_CMD exists to exercise this
# script without waiting for the real CI (58-90 min): the default is the
# real one.
GATE_CMD="${SOLIDCRAFT_GATE_CMD:-cargo xtask ci}"

usage() {
  echo "usage: start-gate.sh <sha> <issue> <slug> [--slot <slot>] [--worktree <path>]" >&2
  echo "       start-gate.sh --from-request --slot <slot>" >&2
}

# --- the arguments --------------------------------------------------------
SHA=""
ISSUE="0"
SLUG="unknown"
SLOT=""
WORKTREE=""
FROM_REQUEST=0
POSITIONAL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --slot)
      if [ $# -lt 2 ]; then echo "--slot needs a name" >&2; exit 2; fi
      SLOT="$2"; shift 2 ;;
    --slot=*) SLOT="${1#--slot=}"; shift ;;
    --worktree)
      if [ $# -lt 2 ]; then echo "--worktree needs a path" >&2; exit 2; fi
      WORKTREE="$2"; shift 2 ;;
    --worktree=*) WORKTREE="${1#--worktree=}"; shift ;;
    --from-request) FROM_REQUEST=1; shift ;;
    -h|--help) usage; exit 2 ;;
    --*) echo "unknown option: $1" >&2; usage; exit 2 ;;
    *)
      case "$POSITIONAL" in
        0) SHA="$1" ;;
        1) ISSUE="$1" ;;
        2) SLUG="$1" ;;
        *) echo "too many arguments" >&2; usage; exit 2 ;;
      esac
      POSITIONAL=$((POSITIONAL + 1))
      shift ;;
  esac
done

# --- the slot -------------------------------------------------------------
# The name of a slot is a FILE NAME: it has to be safe inside a path. Lower
# case, [a-z0-9._-] only, no "..", not empty, not hidden. When the name
# cannot be normalized the script ABORTS: it never invents a name (a name
# that is not the slot's would put the gate's files in another slot).
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

if [ -n "$SLOT" ]; then
  SLOT_NAME="$(normalize_slot "$SLOT")" || {
    echo "the slot name is not usable: $SLOT" >&2
    exit 2
  }
elif [ -n "$WORKTREE" ]; then
  # The slot of a worktree is the name of its directory: the worktree
  # /…/issue-5302 belongs to the slot `issue-5302`.
  SLOT_NAME="$(normalize_slot "$(basename "$WORKTREE")")" || {
    echo "the worktree path cannot be turned into a slot name: $WORKTREE" >&2
    exit 2
  }
else
  SLOT_NAME="default"
fi

# The configuration is CHECKED before it is sourced: a value with spaces
# and no quotes breaks the source in the middle of the file, so the
# variable is never set and the script goes on with HALF of the policy, in
# silence (set -e is not on). The check only READS the file: the config.env
# is read twice and sourced once. If the config.env is broken, the script
# STOPS here instead of running with half of the policy.
if [ -r "$LOOP_DIR/config.env" ]; then
  if [ -x "$SCRIPT_DIR/config-preflight.sh" ]; then
    bash "$SCRIPT_DIR/config-preflight.sh" "$LOOP_DIR/config.env" || exit 2
  elif ! bash -n "$LOOP_DIR/config.env" >/dev/null 2>&1; then
    echo "start-gate: the config.env has a syntax error: $LOOP_DIR/config.env" >&2
    exit 2
  fi
fi

# config.env: REPO, GATE_WORKTREE, GATE_TARGET_DIR, CHROME, etc.
if [ -r "$LOOP_DIR/config.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$LOOP_DIR/config.env"
  set +a
fi

GATE_WORKTREE="${GATE_WORKTREE:-$LOOP_DIR/../solidcraft-gate}"
GATE_TARGET_DIR="${GATE_TARGET_DIR:-$GATE_WORKTREE/target}"
CHROME="${CHROME:-$HOME/.local/chrome/chrome-linux64/chrome}"
CHROME_LD="${CHROME_LD:-$HOME/.local/chrome-deps/usr/lib/x86_64-linux-gnu:$HOME/.local/chrome-deps/lib/x86_64-linux-gnu}"

# --- the policy of the complete gate (27-10-2026) --------------------------
# The upstream CI runs the FULL suite when a maintainer reviews the PR and
# adds `approved-for-ci`, and the merge queue runs it again on top of main.
# Running `cargo xtask ci` here before publishing costs ~90-180 min of CPU and
# ~35 GB of RAM (the OOM killer took a whole gate on 27-10) and it does NOT
# prevent a single red check: the CI catches it anyway, and what that costs is
# a red check, not a broken main.
#
# So the complete gate is OFF by default and the fair local gate is the one of
# the scope (bin/gate-quick.sh: fmt + check + clippy of the scope + nextest of
# the scope). Its verdict (VERDE-SCOPE) DOES publish.
#
# `SOLIDCRAFT_GATE_FORCE=1` is the manual override: a human, not the loop.
# The exit code 11 says "disabled on purpose": it is not a failure of the
# gate and the callers must not treat it as one.
GATE_COMPLETE_MODE="${GATE_COMPLETE_MODE:-off}"
case "$GATE_COMPLETE_MODE" in
  off|manual|auto) ;;
  *) GATE_COMPLETE_MODE="off" ;;
esac
if [ "$GATE_COMPLETE_MODE" != "auto" ] && [ "${SOLIDCRAFT_GATE_FORCE:-0}" != "1" ]; then
  echo "the complete gate is disabled (GATE_COMPLETE_MODE=$GATE_COMPLETE_MODE):" \
    "the CI of the upstream runs the full suite when a maintainer reviews the" \
    "PR (approved-for-ci) and the merge queue runs it again on main. The local" \
    "gate of the scope (bin/gate-quick.sh) is the fair one. Nothing was launched." >&2
  exit 11
fi

# --- the GPU of the gate ------------------------------------------------------
# The upstream CI draws the pictures with Mesa's lavapipe (software Vulkan) and
# asks for a GPU to be there: `SOLIDCRAFT_GPU: software` and
# `SOLIDCRAFT_REQUIRE_GPU: "1"`, "a test that would skip for want of an
# adapter fails instead" (ci.yml, the Linux test job).
#
# The gate has to be the SAME gate, or it does not predict the heavy lane:
# without an adapter the unit test of the multisampled startup check panics
# (it needs one, it does not skip), and the integration tests of crates/gpu
# skip in silence, so a broken GPU would pass the gate and stop the merge
# queue.
#
# `systemd-run` does NOT pass the environment of the caller to the unit: it
# only gets what `--setenv` names. So everything the gate needs is named
# here, explicitly. The libraries of lavapipe live in X_LD, so that goes on
# the library path AFTER the ones of Chrome (they share libX11 and libdrm,
# and Chrome's own ones must win).
#
# The policy is `software`, NOT the `cpu` of config.env: the policy `cpu`
# admits no adapter at all (the CPU rasterizer is where a policy LANDS, not
# an adapter), and `open_headless()` would fail with NoAdapter.
GATE_X_LD="${X_LD:-$HOME/.local/x/usr/lib/x86_64-linux-gnu}"
GATE_LD="${CHROME_LD}:${GATE_X_LD}"
GATE_GPU="${GATE_GPU:-software}"
GATE_REQUIRE_GPU="${GATE_REQUIRE_GPU:-1}"
GATE_DISPLAY="${DISPLAY:-:99}"
GATE_VK_ICD="${VK_ICD_FILENAMES:-}"

# --- the memory of the gate ---------------------------------------------------
# The gate is the biggest cgroup of the machine: it compiles the whole
# workspace and it runs the whole test suite. On the 26-10-2026 the OOM
# killer killed a process of the gate at 10:33:51 and the unit ended with
# a 47.4 GB peak, while the rest of the machine (the loop's own build, the
# agents, the page cache of the target tree) was using the rest of the RAM
# of a host with NO swap. The kernel picks the victim by RSS, so the gate
# paid for everybody.
#
# Three limits, so the gate fails inside its own cgroup instead of taking
# the machine down with it:
#
# - CARGO_BUILD_JOBS bounds the COMPILATION of the gate. Without it cargo
#   compiles with one job per core: sixteen rustc of the engine crate at
#   once is tens of gigabytes of anon memory. The test pool was already
#   bounded; the build was not.
# - LP_NUM_THREADS bounds the rasterizer of lavapipe: it spawns one thread
#   per core by default, and every one of them takes a scratch buffer.
# - MemoryMax is the belt: the unit has its own cgroup, so when the gate
#   goes over the limit the kernel reclaims its page cache and, in the
#   worst case, kills the gate and NOT the loop. (The limit is NOT on the
#   user slice: there the page cache of the whole machine is charged and
#   the limit would kill something else, see the RUNBOOK, section L4'.)
GATE_BUILD_JOBS="${GATE_BUILD_JOBS:-4}"
GATE_LP_THREADS="${GATE_LP_THREADS:-4}"
# The belt and the throttle of the unit of the gate:
#
# - MemoryMax is the hard belt: when the gate goes over it the kernel
#   reclaims its page cache and, in the worst case, kills the gate and
#   NOT the loop (the unit has a cgroup of its own).
# - MemoryHigh is the throttle: above it the kernel starts reclaiming
#   the page cache of the gate AGGRESSIVELY and keeps the cgroup near
#   the threshold. It is what makes the difference, because the page
#   cache of the build (the libraries it reads and the binaries it
#   writes) is about 10 GB of the budget, and the anon memory of the
#   heavy geometry tests is about 15 GB more. With only the belt the
#   two add up to the limit at the worst moment (measured: the gate died
#   three times, at 47 GB without a limit, at 32 GB and at 28 GB).
#
# The throttle was 20G until 2026-10-27: measured that night, the anon
# memory of the gate reached 21.9 GB and the kernel logged 5,951,828
# `high` events (the PSI of memory went to 96.7 %): the gate was
# throttled almost all of its life and the 12 nextest threads crawled
# (the gate took 2 h 50 min instead of 50-75 min). The throttle is now
# 32G, above the 21.9 GB peak, and MemoryMax stays at 40G as the belt.
#
# The limit is NOT on the user slice: there the page cache of the whole
# machine is charged and the limit would kill something else (see the
# RUNBOOK, section L4').
GATE_MEMORY_HIGH="${GATE_MEMORY_HIGH:-32G}"
GATE_MEMORY_MAX="${GATE_MEMORY_MAX:-40G}"

# --- the size of the test pool of the gate ---------------------------------
# The gate runs the whole test suite of the workspace: ~80 test binaries.
# Without a bound, `cargo xtask ci` starts ALL of them at once (the xtask
# computes jobs = batches.len()) and each of them runs with libtest's
# default thread count: more than a thousand threads on 16 cores. The
# machine saturates (load 231 measured on this host) and the tests that
# assert on wall-clock time fail for that reason alone: the UI test
# `opening_a_large_design_never_stalls_the_window` budgets 250 ms per
# frame and measured 449 ms under that load, while it measures 190 ms
# alone. Those are FALSE REDS: the code is right, the machine is drowned.
#
# So the gate runs a BOUNDED pool: SOLIDCRAFT_TEST_JOBS test binaries at a
# time, each of them with RUST_TEST_THREADS threads. The product is the
# number of threads that run at once, and it is aimed at ONE THREAD PER
# CORE: no oversubscription, and no timing assertion lost to the scheduler.
#
# The 26-10-2026 measured that the pool of 4x4 (sixteen tests at once) is
# ALSO too much for the RAM of this host: each test builds its own model
# (a STEP assembly of 200 bodies is hundreds of MB), and sixteen of them
# at once took the gate over its 32 GB cgroup limit and the OOM killer
# killed it. The pool is now 3x2: six tests at once, about a third of
# the memory, and the gate runs with the machine LESS loaded than before,
# so the assertions on wall-clock time keep passing.
#
# The two numbers come from config.env (GATE_TEST_JOBS, GATE_TEST_THREADS)
# so they can be changed without touching this script; the defaults below
# are the ones the measurement chose.
DEFAULT_GATE_TEST_JOBS=3
DEFAULT_GATE_TEST_THREADS=2

# A positive integer, or the default when the value is empty or is not one.
# A typo in config.env must not stop the gate: it falls back and says so.
positive_int() {
  local name="$1" value="$2" fallback="$3" out
  case "$value" in
    '')
      out="$fallback" ;;
    *[!0-9]*)
      out="$fallback"
      echo "warning: $name='$value' is not a positive integer: the gate uses $out" >&2 ;;
    *)
      if [ "$value" -ge 1 ]; then
        out="$value"
      else
        out="$fallback"
        echo "warning: $name='$value' is not a positive integer: the gate uses $out" >&2
      fi ;;
  esac
  printf '%s' "$out"
}

GATE_TEST_JOBS="$(positive_int GATE_TEST_JOBS "${GATE_TEST_JOBS:-}" "$DEFAULT_GATE_TEST_JOBS")"
GATE_TEST_THREADS="$(positive_int GATE_TEST_THREADS "${GATE_TEST_THREADS:-}" \
  "$DEFAULT_GATE_TEST_THREADS")"
GATE_TEST_THREADS_TOTAL=$((GATE_TEST_JOBS * GATE_TEST_THREADS))
GATE_CORES="$(nproc 2>/dev/null || echo 0)"
echo "the gate test pool is bounded: $GATE_TEST_JOBS test binaries at a time," \
  "each with $GATE_TEST_THREADS threads ($GATE_TEST_THREADS_TOTAL threads at once," \
  "$GATE_CORES cores on this host)" >&2

# --- the runner of the tests of the gate -----------------------------------
# The gate runs the suite with nextest, the runner of the upstream CI, and
# not with `cargo test`:
#
# - `cargo test` runs EVERY test of a binary in ONE PROCESS. Measured on the
#   26-10-2026: the binary of the GPU tests reached 21.7 GB of anon memory
#   (140 tests, about 155 MB each that the process never gives back) and
#   that is what the OOM killer used to kill the gate, three times. A single
#   test of that binary uses 217 MB.
# - nextest runs ONE PROCESS PER TEST, so the memory of a test dies with
#   it. It is also faster, and it is what the merge queue of the upstream
#   runs (`cargo nextest run --profile ci`), so the local gate becomes a
#   truer proxy of that CI. It also removes a class of false reds: the
#   upstream CI never saw the frame-order failures that the local gate
#   reported, because a test alone in its process draws its frame in a
#   deterministic order.
#
# The runner is chosen by `SOLIDCRAFT_TEST_RUNNER` (the xtask reads it) and
# the concurrency by `NEXTEST_TEST_THREADS` (the xtask passes it to nextest
# as --test-threads). The upstream CI leaves nextest at one thread per
# core; here the number is bounded, because six heavy tests at once do not
# fit in the memory of the gate.
DEFAULT_GATE_NEXTEST_THREADS=6
GATE_TEST_RUNNER="${GATE_TEST_RUNNER:-nextest}"
GATE_NEXTEST_THREADS="$(positive_int GATE_NEXTEST_THREADS "${GATE_NEXTEST_THREADS:-}" \
  "$DEFAULT_GATE_NEXTEST_THREADS")"
echo "the gate runs the tests with $GATE_TEST_RUNNER" \
  "($GATE_NEXTEST_THREADS nextest threads at a time)" >&2

# --- the request of the queue ---------------------------------------------
# The drain of the queue: the supervisor launches the gate of a slot that
# asked for it while another gate was running.
if [ "$FROM_REQUEST" -eq 1 ]; then
  # THE DEFAULT SLOT IS SERVED FROM ITS REQUEST TOO. It used to be refused
  # here, and that refusal left the request of the default slot in the queue
  # forever: the drain could not serve it, so the slot waited for a gate that
  # nobody was going to launch. The request carries the worktree of the slot
  # (`worktree=`), so the default slot is served exactly like any other one.
  REQUEST_FILE="$GATES_DIR/$SLOT_NAME/request"
  if [ ! -r "$REQUEST_FILE" ]; then
    echo "the slot $SLOT_NAME has no request to launch" >&2
    exit 2
  fi
  req_sha=""
  req_issue=""
  req_slug=""
  req_worktree=""
  while IFS='=' read -r req_key req_value; do
    case "$req_key" in
      sha) req_sha="$req_value" ;;
      issue) req_issue="$req_value" ;;
      slug) req_slug="$req_value" ;;
      worktree) req_worktree="$req_value" ;;
    esac
  done < "$REQUEST_FILE"
  if [ -z "$req_sha" ]; then
    echo "the request of the slot $SLOT_NAME has no sha" >&2
    exit 2
  fi
  SHA="$req_sha"
  ISSUE="${req_issue:-0}"
  SLUG="${req_slug:-unknown}"
  if [ -n "$req_worktree" ]; then
    WORKTREE="$req_worktree"
  fi
  echo "the request of the slot $SLOT_NAME is launched (sha $SHA)" >&2
fi

# Two SHAs are the same commit when their common prefix (the shortest of the
# two) is long enough: the verdict may carry the short sha and the gate the
# full one. It is the same rule that state.py uses to tie a verdict to a
# commit.
same_commit() {
  local left="${1:-}" right="${2:-}" size
  left="$(printf '%s' "$left" | tr '[:upper:]' '[:lower:]')"
  right="$(printf '%s' "$right" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$left" ] || [ -z "$right" ]; then
    return 1
  fi
  size=${#left}
  if [ "${#right}" -lt "$size" ]; then
    size=${#right}
  fi
  [ "$size" -ge 7 ] || return 1
  [ "${left:0:$size}" = "${right:0:$size}" ]
}

# --- 0. the quick gate of this sha: a red one refuses the complete gate ---
# The quick gate (bin/gate-quick.sh) checks the packages the change touches
# in 1-5 min. When it is RED for THIS sha, the complete gate would spend
# 50-75 min on code that is already known to be broken, so it is not
# launched.
#
# It never blocks anything: a missing verdict, a verdict of another sha, a
# green one or a skipped one all launch the complete gate as usual.
#
# GATE_STATUS=failed is NOT a verdict: that run did not finish (timeout,
# cargo missing, diff error) and its scope was NOT checked, so it does not
# block the complete gate (the prompt says the same about it).
QUICK_VERDICT_FILE="$LOOP_DIR/gate.quick.verdict"
if [ -r "$QUICK_VERDICT_FILE" ]; then
  quick_sha="$(sed -n 's/^SHA=//p' "$QUICK_VERDICT_FILE" 2>/dev/null | head -1)"
  quick_verdict="$(sed -n 's/^VERDICT=//p' "$QUICK_VERDICT_FILE" 2>/dev/null | head -1)"
  quick_status="$(sed -n 's/^GATE_STATUS=//p' "$QUICK_VERDICT_FILE" 2>/dev/null | head -1)"
  if [ "$quick_verdict" = "ROJO-PARCIAL" ] && [ "$quick_status" != "failed" ] \
     && same_commit "$quick_sha" "$SHA"; then
    echo "the quick gate is red for this sha: fix it before spending an hour" \
      "on the complete gate" >&2
    echo "(the quick verdict of ${SHA:0:12}: ${quick_verdict}, ${quick_status:-?}:" \
      "$QUICK_VERDICT_FILE)" >&2
    if [ "$FROM_REQUEST" -eq 1 ]; then
      # The request is for THIS sha and this sha is known broken: it can
      # never be served, so it does not stay in the queue.
      rm -f "$GATES_DIR/$SLOT_NAME/request"
    fi
    exit 10
  fi
fi

# --- the worktree of the slot ---------------------------------------------
if [ -z "$WORKTREE" ]; then
  if [ "$SLOT_NAME" = "default" ]; then
    WORKTREE="$GATE_WORKTREE"
  else
    WORKTREE="$LOOP_DIR/worktrees/$SLOT_NAME"
  fi
fi

if [ ! -d "$WORKTREE/.git" ] && [ ! -f "$WORKTREE/.git" ]; then
  echo "the gate worktree does not exist: $WORKTREE" >&2
  exit 3
fi

# --- the files of the slot ------------------------------------------------
SLOT_DIR="$GATES_DIR/$SLOT_NAME"
REQUEST_FILE="$SLOT_DIR/request"
mkdir -p "$SLOT_DIR"

# THE GLOBAL SIDECAR: it always points to the LIVE gate, whatever its slot
# is. Every gate rewrites it, so reading it LATER says nothing about which
# slot that gate belonged to (the next gate has already overwritten it):
# the verdict and the sha of a slot live in gates/<slot>/ and the owner of
# the slot freezes them in the state.
GLOBAL_PID_FILE="$LOOP_DIR/gate.pid"
GLOBAL_STARTED_FILE="$LOOP_DIR/gate.started"
GLOBAL_SHA_FILE="$LOOP_DIR/gate.sha"
GLOBAL_LOG_PATH_FILE="$LOOP_DIR/gate.path"

if [ "$SLOT_NAME" = "default" ]; then
  # The default slot keeps the legacy files: they are the ones state.py and
  # the supervisor read today. The copy under gates/default/ is the same
  # state, in the place the other slots use.
  PID_FILE="$GLOBAL_PID_FILE"
  STARTED_FILE="$GLOBAL_STARTED_FILE"
  SHA_FILE="$GLOBAL_SHA_FILE"
  LOG_PATH_FILE="$GLOBAL_LOG_PATH_FILE"
  MIRROR_PID="$SLOT_DIR/pid"
  MIRROR_STARTED="$SLOT_DIR/started"
  MIRROR_SHA="$SLOT_DIR/sha"
  MIRROR_LOG="$SLOT_DIR/log"
else
  PID_FILE="$SLOT_DIR/pid"
  STARTED_FILE="$SLOT_DIR/started"
  SHA_FILE="$SLOT_DIR/sha"
  LOG_PATH_FILE="$SLOT_DIR/log"
  MIRROR_PID=""
  MIRROR_STARTED=""
  MIRROR_SHA=""
  MIRROR_LOG=""
fi

SLUG_SAFE="$(printf '%s' "$SLUG" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-60)"
SHA_SHORT="$(printf '%s' "$SHA" | cut -c1-12)"
if [ "$SLOT_NAME" = "default" ]; then
  LOG="$LOOP_DIR/logs/gate-${ISSUE}-${SLUG_SAFE}-${SHA_SHORT}.log"
else
  LOG="$LOOP_DIR/logs/gate-${SLOT_NAME}-${ISSUE}-${SLUG_SAFE}-${SHA_SHORT}.log"
fi
mkdir -p "$LOOP_DIR/logs"

# The log the slot recorded the last time (the path of its last gate). It is
# looked at as well when the sha is checked: the slug can change between two
# runs of the same sha and the path of the log carries the slug.
#
# The slot's OWN record comes first (gates/<slot>/log): the global sidecar is
# rewritten by every gate, so it may already point to the log of another slot.
RECORDED_LOG=""
for recorded_source in "$SLOT_DIR/log" "$LOG_PATH_FILE"; do
  [ -r "$recorded_source" ] || continue
  RECORDED_LOG="$(head -1 "$recorded_source" 2>/dev/null | tr -d '\r\n')"
  [ -n "$RECORDED_LOG" ] && break
done

# --- is a process alive? --------------------------------------------------
# `kill -0` asks the kernel; /proc is the backup (a sandbox can forbid the
# signal). A recycled pid is not alive for us: the caller also checks the
# command line.
pid_alive() {
  local pid="$1"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if kill -0 "$pid" 2>/dev/null; then return 0; fi
  [ -d "/proc/$pid" ]
}

# The command line of a process (empty when it is gone).
cmdline_of() {
  local pid="$1"
  [ -r "/proc/$pid/cmdline" ] || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || return 1
}

# The pid of the LIVE gate of a slot (empty when the slot has no live gate).
#
# The pid alone proves nothing: it can be recycled. The command line decides:
# the gate of a slot carries its marker (`solidcraft-gate-slot:<slot>`) in
# its argv. The gates launched before the slots existed carry no marker: for
# the default slot they are recognised by the command they run (`xtask ci`)
# or by the log they write.
slot_gate_pid_of_file() {
  local file="$1" slot="$2" pid cmd log
  [ -r "$file" ] || return 1
  pid="$(tr -dc '0-9' < "$file" 2>/dev/null | head -c 10)"
  [ -n "$pid" ] || return 1
  pid_alive "$pid" || return 1
  cmd="$(cmdline_of "$pid")" || return 1
  case "$cmd" in
    *"solidcraft-gate-slot:$slot"*) printf '%s' "$pid"; return 0 ;;
  esac
  # The gate of ANOTHER slot: the global sidecar holds the pid of the live
  # gate whatever its slot is, so a pid read from it can be the gate of
  # another slot. The marker says whose it is, and it is not this slot's:
  # without this check the default slot would adopt the gate of the other
  # slot (it runs the same `xtask ci`) and would refuse to launch its own.
  case "$cmd" in
    *"solidcraft-gate-slot:"*) return 1 ;;
  esac
  if [ "$slot" = "default" ]; then
    case "$cmd" in
      *"xtask ci"*) printf '%s' "$pid"; return 0 ;;
    esac
    log="$(head -1 "$LOG_PATH_FILE" 2>/dev/null | tr -d '\r\n')"
    if [ -n "$log" ]; then
      case "$cmd" in *"$log"*) printf '%s' "$pid"; return 0 ;; esac
    fi
  fi
  return 1
}

slot_gate_pid() {
  local slot="$1"
  if [ "$slot" = "default" ]; then
    slot_gate_pid_of_file "$LOOP_DIR/gate.pid" "$slot" && return 0
    slot_gate_pid_of_file "$GATES_DIR/default/pid" "$slot" && return 0
  else
    slot_gate_pid_of_file "$GATES_DIR/$slot/pid" "$slot" && return 0
  fi
  return 1
}

# The worktree a slot gates (the file it was launched with).
slot_worktree() {
  local slot="$1" file="$GATES_DIR/$slot/worktree"
  if [ -r "$file" ]; then
    head -1 "$file" | tr -d '\r\n'
    return 0
  fi
  if [ "$slot" = "default" ]; then
    printf '%s' "${GATE_WORKTREE:-}"
  fi
}

canonical_path() {
  local path="$1"
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$path" 2>/dev/null || printf '%s' "$path"
  else
    printf '%s' "$path"
  fi
}

# The slot whose LIVE gate is using this worktree. The gate does
# `checkout --detach` in its worktree: two builds in the same worktree fight,
# each one changing the files under the other.
worktree_owner() {
  local want="$1" dir slot owner
  want="$(canonical_path "$want")"
  for dir in "$GATES_DIR"/*/; do
    [ -d "$dir" ] || continue
    slot="$(basename "$dir")"
    if slot_gate_pid "$slot" >/dev/null 2>&1; then
      owner="$(slot_worktree "$slot")"
      if [ -n "$owner" ] && [ "$(canonical_path "$owner")" = "$want" ]; then
        printf '%s' "$slot"
        return 0
      fi
    fi
  done
  return 1
}

# The gate of ANOTHER slot that is alive right now (there is at most one live
# gate in the machine).
other_live_gate() {
  local dir slot pid
  for dir in "$GATES_DIR"/*/; do
    [ -d "$dir" ] || continue
    slot="$(basename "$dir")"
    [ "$slot" = "$SLOT_NAME" ] && continue
    if pid="$(slot_gate_pid "$slot")"; then
      printf '%s %s' "$slot" "$pid"
      return 0
    fi
  done
  if [ "$SLOT_NAME" != "default" ]; then
    if pid="$(slot_gate_pid default)"; then
      printf '%s %s' "default" "$pid"
      return 0
    fi
  fi
  return 1
}

# A CI that we do not track (the baseline of the loop, a gate launched before
# the slots existed): the match is on the PROCESS, not on the command line of
# everything: `pgrep -f "xtask ci"` also matches the loop's own
# `opencode run`, whose argv carries the turn spec (and the spec mentions
# `cargo xtask ci`), so the check would wait forever. And the running process
# is NOT named "cargo": `cargo xtask ci` execs the xtask binary, so its comm
# is "xtask".
ci_running() {
  local pid name
  for name in xtask cargo; do
    for pid in $(pgrep -x "$name" 2>/dev/null); do
      if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "xtask ci"; then
        echo "$pid"
        return 0
      fi
    done
  done
  return 1
}

# The request of the queue: the supervisor drains it, one gate at a time.
write_request() {
  mkdir -p "$SLOT_DIR"
  {
    echo "slot=$SLOT_NAME"
    echo "sha=$SHA"
    echo "issue=$ISSUE"
    echo "slug=$SLUG"
    echo "worktree=$WORKTREE"
    echo "requested_at=$(date +%s)"
  } > "$REQUEST_FILE"
}

# --- the sha that was already gated -----------------------------------------
# The verdict of a gate belongs to its sha, not to the file of its log: the
# path of the log carries the sha. So a run that already finished (its log
# has an EXIT=) IS the verdict of that sha, and the gate is not launched
# again: the tree did not change, so the answer would be the same.
#
# The log of this run is looked at, and the log the slot recorded the last
# time (the slug can change between two runs of the same sha).
log_has_finished_run() {
  local path="$1" file
  for file in "$path" "$path.1"; do
    [ -f "$file" ] || continue
    if grep -qE '^EXIT=[0-9]+[[:space:]]*$' "$file" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# The log of a FINISHED run of THIS sha (nothing when there is none).
gated_log_of_sha() {
  local path name tail
  for path in "$LOG" "$RECORDED_LOG"; do
    [ -n "$path" ] || continue
    name="$(basename "$path")"
    tail="${name%.log}"
    tail="${tail##*-}"
    [ "$tail" = "$SHA_SHORT" ] || continue
    if log_has_finished_run "$path"; then
      printf '%s' "$path"
      return 0
    fi
  done
  return 1
}

# The exit code of the last FINISHED run of a log (the log itself, or the
# rotated one when the run that is going on has not finished yet).
last_exit_code() {
  local path="$1" file code=""
  for file in "$path" "$path.1"; do
    [ -f "$file" ] || continue
    code="$(grep -hoE '^EXIT=[0-9]+[[:space:]]*$' "$file" 2>/dev/null | tail -1 |
      tr -dc '0-9' || true)"
    [ -n "$code" ] && break
  done
  printf '%s' "$code"
}

# --- 1. this slot already has a gate --------------------------------------
# The gate of a slot is identified by its pid (and its command line): the
# gates of the OTHER slots do not bother it.
if THIS_PID="$(slot_gate_pid "$SLOT_NAME")"; then
  echo "the slot $SLOT_NAME already has a live gate (pid $THIS_PID): not launching another one" >&2
  exit 5
fi

# --- 1.b. this sha was already gated ---------------------------------------
# The gate of a sha that already FINISHED is not launched again: the tree did
# not change, so the verdict of that run IS the verdict of this sha. It is
# checked BEFORE the queue: a gate that can never change the verdict does not
# deserve a place in it.
if GATED_LOG="$(gated_log_of_sha)"; then
  GATED_EXIT="$(last_exit_code "$GATED_LOG")"
  echo "the sha $SHA_SHORT was already gated (EXIT=${GATED_EXIT:-?} in $GATED_LOG):" \
    "not launching another gate (the tree did not change: that verdict is" \
    "the verdict of this sha)" >&2
  if [ "$FROM_REQUEST" -eq 1 ]; then
    # The request is for THIS sha and this sha is already gated: it can
    # never be served, so it does not stay in the queue.
    rm -f "$REQUEST_FILE"
  fi
  exit 8
fi

# --- 2. another gate is running: this one waits its turn -------------------
# The gate saturates the CPU: two gates at the same time take twice as
# long. The slot leaves a request and the supervisor drains the queue.
if OTHER="$(other_live_gate)"; then
  other_slot="${OTHER%% *}"
  other_pid="${OTHER##* }"
  write_request
  echo "the gate of the slot $other_slot is running (pid $other_pid): the gate of the slot $SLOT_NAME is queued (request: $REQUEST_FILE)" >&2
  exit 6
fi
if CI_PID="$(ci_running)"; then
  write_request
  echo "a CI is already running on this machine (xtask ci, pid $CI_PID): the gate of the slot $SLOT_NAME is queued (request: $REQUEST_FILE)" >&2
  exit 6
fi

# --- 3. the worktree is in use ---------------------------------------------
if WT_OWNER="$(worktree_owner "$WORKTREE")"; then
  echo "the worktree $WORKTREE is in use by the live gate of the slot $WT_OWNER: not launching another gate there" >&2
  exit 7
fi

# The gate compiles the WORKING TREE: if the worktree sits on another commit,
# it compiles another code and the verdict is not about the fix.
#
# And if a CI is ALREADY running in that worktree (e.g. the baseline): the
# `checkout --detach` would change the files underneath it and both builds
# would fight. A gate is never launched on top of another one in the SAME
# worktree: the check above refuses it.
if ! git -C "$WORKTREE" checkout --detach "$SHA" >/dev/null 2>&1; then
  echo "could not checkout --detach $SHA in $WORKTREE" >&2
  exit 4
fi

# The gate compiles the WORKING TREE: if the worktree carries local
# modifications, it compiles THAT code and the verdict is about the wrong
# thing (a `cargo fmt --check` failure on someone else's debug code looks like
# a failure of ours). So: save the local changes to a patch (nothing is lost),
# clean the tree, and only then check out the SHA to gate.
#
# `reset --hard` is NOT used: it is the command that throws away work without
# asking. `restore --source=HEAD --staged --worktree` puts the index and the
# working tree back at HEAD WITHOUT moving HEAD (the HEAD of the worktree is
# the SHA to gate), and `clean -qfd` removes the untracked files. The old
# `checkout -- .` + `reset -q` is the fallback for a git without `restore`.
if [ -n "$(git -C "$WORKTREE" status --porcelain 2>/dev/null)" ]; then
  DIRTY_PATCH="$LOOP_DIR/logs/gate-dirty-$(date -u +%FT%H%M%SZ).patch"
  git -C "$WORKTREE" diff > "$DIRTY_PATCH" 2>/dev/null || true
  echo "the gate worktree had local changes: saved to $DIRTY_PATCH and discarded" >&2
  if ! git -C "$WORKTREE" restore --source=HEAD --staged --worktree -- . 2>/dev/null; then
    git -C "$WORKTREE" checkout -q -- . 2>/dev/null || true
    git -C "$WORKTREE" reset -q 2>/dev/null || true
    git -C "$WORKTREE" checkout -q -- . 2>/dev/null || true
  fi
  git -C "$WORKTREE" clean -qfd 2>/dev/null || true
  git -C "$WORKTREE" checkout --detach "$SHA" >/dev/null 2>&1 || true
fi

# The PID of the PREVIOUS gate must not be mistaken for this one's: the
# supervisor reads gate.pid to know whether a gate is running, and a file
# left over from the previous run (not empty, perfectly readable) made the
# wait below return immediately with the OLD pid: the supervisor then
# believed the old gate was the new one. The old markers are removed BEFORE
# the launch and the wait looks for a NEW file (one created after it), not
# just for a non-empty one.
OLD_PID=""
if [ -r "$PID_FILE" ]; then
  OLD_PID="$(tr -dc '0-9' < "$PID_FILE" | head -c 10)"
fi
rm -f "$PID_FILE" "$STARTED_FILE" "$SHA_FILE"
LAUNCH_EPOCH="$(date +%s)"

# The gate runs DETACHED from the turn, and there are TWO things to detach it:
#
#  * `setsid` detaches it from the terminal and the session, but
#  * **it does NOT detach it from the service's cgroup**. systemd kills every
#    process of a `oneshot` unit when the unit finishes, so a gate launched
#    with `setsid` from the turn died the moment the turn ended (it died in
#    the middle of `cargo clippy`, with no EXIT= in its log, and the phase
#    stayed `gating` forever).
#
# So the gate gets its OWN transient unit (`systemd-run --user`): a sibling of
# the loop's unit under the user manager, not a child of it. When the loop's
# turn ends, systemd tears down the loop's cgroup and the gate keeps running.
# `setsid` stays as the fallback for a machine without systemd-run.
#
# The unit name carries the slot: two slots never share a unit (there is at
# most one gate at a time, but a leftover unit would block the next launch).
SLOT_UNIT="$(printf '%s' "$SLOT_NAME" | tr '.' '-')"
if [ "$SLOT_NAME" = "default" ]; then
  GATE_UNIT="solidcraft-gate-${ISSUE}-${SLUG_SAFE}"
else
  GATE_UNIT="solidcraft-gate-${SLOT_UNIT}-${ISSUE}-${SLUG_SAFE}"
fi

# The marker of the slot in the command line of the gate: it is how the
# script knows that a pid belongs to the gate of THIS slot (a pid can be
# recycled by another process).
GATE_MARKER="solidcraft-gate-slot:${SLOT_NAME}"

run_gate_with_systemd() {
  # The environment of the gate is named one by one: systemd-run does not
  # pass the environment of the caller to the unit.
  local extra_env=()
  extra_env+=(--setenv="PATH=${HOME}/.cargo/bin:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin")
  extra_env+=(--setenv="CARGO_TARGET_DIR=${GATE_TARGET_DIR}")
  extra_env+=(--setenv="CHROME=${CHROME}")
  extra_env+=(--setenv="LD_LIBRARY_PATH=${GATE_LD}")
  extra_env+=(--setenv="SOLIDCRAFT_TEST_JOBS=${GATE_TEST_JOBS}")
  extra_env+=(--setenv="RUST_TEST_THREADS=${GATE_TEST_THREADS}")
  # The runner of the tests and its concurrency: nextest runs one process
  # per test, so the memory of a test dies with it.
  extra_env+=(--setenv="SOLIDCRAFT_TEST_RUNNER=${GATE_TEST_RUNNER}")
  extra_env+=(--setenv="NEXTEST_TEST_THREADS=${GATE_NEXTEST_THREADS}")
  extra_env+=(--setenv="DISPLAY=${GATE_DISPLAY}")
  extra_env+=(--setenv="SOLIDCRAFT_GPU=${GATE_GPU}")
  extra_env+=(--setenv="SOLIDCRAFT_REQUIRE_GPU=${GATE_REQUIRE_GPU}")
  # The compilation of the gate is bounded, and so is the rasterizer of
  # lavapipe: sixteen rustc at once (or sixteen rasterizer threads per
  # device) is tens of gigabytes of memory this host does not have.
  extra_env+=(--setenv="CARGO_BUILD_JOBS=${GATE_BUILD_JOBS}")
  extra_env+=(--setenv="LP_NUM_THREADS=${GATE_LP_THREADS}")
  # An empty VK_ICD_FILENAMES would tell the loader "no ICD at all", so it is
  # only named when it has a value.
  [ -n "$GATE_VK_ICD" ] && extra_env+=(--setenv="VK_ICD_FILENAMES=${GATE_VK_ICD}")
  systemd-run --user \
    --unit="$GATE_UNIT" \
    --collect \
    --property=Nice=10 \
    --property="MemoryHigh=${GATE_MEMORY_HIGH}" \
    --property="MemoryMax=${GATE_MEMORY_MAX}" \
    --property="StandardOutput=truncate:${LOG}" \
    --property="StandardError=truncate:${LOG}" \
    "${extra_env[@]}" \
    /bin/bash -c '
      # '"$GATE_MARKER"'
      cd "$2" || { echo "EXIT=127" >> "$3"; exit 127; }
      bash -c "$4"
      echo "EXIT=$?" >> "$3"
    ' _ "$LOOP_DIR" "$WORKTREE" "$LOG" "$GATE_CMD" 9>&- >/dev/null 2>&1
  # systemd expands the `$` of the command line, so the PID is taken from the
  # unit itself instead of from `$$` inside it.
  local pid=""
  for _ in $(seq 1 50); do
    pid="$(systemctl --user show "$GATE_UNIT" -p MainPID --value 2>/dev/null)"
    case "$pid" in 0|"") pid="";; *) break;; esac
    sleep 0.1
  done
  if [ -n "$pid" ]; then
    echo "$pid" > "$PID_FILE"
    date +%s > "$STARTED_FILE"
  fi
  # the SHA the gate runs on: the supervisor ties the verdict to it (a verdict
  # of another commit is not a verdict).
  echo "$SHA" > "$SHA_FILE"
}

run_gate_with_setsid() {
  setsid nohup bash -c '
    # '"$GATE_MARKER"'
    echo $$ > "$1"
    date +%s > "$2"
    cd "$3" || { echo "EXIT=127" >> "$4"; exit 127; }
    export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
    export CARGO_TARGET_DIR="$5"
    # Chrome: without $CHROME the web-offline-test of `cargo xtask ci` is
    # SKIPPED SILENTLY (find_chrome() only looks at $CHROME and google-chrome in
    # the PATH).
    export CHROME="$6"
    export LD_LIBRARY_PATH="$7"
    # The bounded test pool: the same numbers the systemd path sets, so both
    # launch paths run the tests the same way (see the pool note above).
    export SOLIDCRAFT_TEST_JOBS="$8"
    export RUST_TEST_THREADS="$9"
    # The runner of the tests and its concurrency: the same numbers the
    # systemd path sets, so both launch paths run the tests the same way.
    export SOLIDCRAFT_TEST_RUNNER="${17}"
    export NEXTEST_TEST_THREADS="${18}"
    # The GPU, exactly as the upstream CI has it: lavapipe draws the pictures
    # and a test that would skip for want of an adapter fails instead.
    export DISPLAY="${10}"
    export SOLIDCRAFT_GPU="${11}"
    export SOLIDCRAFT_REQUIRE_GPU="${12}"
    export VK_ICD_FILENAMES="${13}"
    # The same bounds as the systemd path: the compilation and the rasterizer
    # of lavapipe are bounded (the cgroup limit needs systemd, so this path
    # has no belt, only the two numbers).
    export CARGO_BUILD_JOBS="${14}"
    export LP_NUM_THREADS="${15}"
    bash -c "${16}"
    echo "EXIT=$?" >> "$4"
  ' _ "$PID_FILE" "$STARTED_FILE" "$WORKTREE" "$LOG" "$GATE_TARGET_DIR" "$CHROME" "$GATE_LD" \
    "$GATE_TEST_JOBS" "$GATE_TEST_THREADS" "$GATE_DISPLAY" "$GATE_GPU" "$GATE_REQUIRE_GPU" \
    "$GATE_VK_ICD" "$GATE_BUILD_JOBS" "$GATE_LP_THREADS" "$GATE_CMD" \
    "$GATE_TEST_RUNNER" "$GATE_NEXTEST_THREADS" \
    > "$LOG" 2>&1 9>&- &
}

# The log of this run starts EMPTY and the log of the previous run of this
# sha is KEPT (rotated into <log>.1). Truncating it (what the `truncate:`
# of systemd does) erased the EXIT= of the run that had already finished,
# and with it the verdict the loop had: the phase went back to 'gated' and the
# loop published the same PR over and over.
if [ -f "$LOG" ]; then
  if mv -f "$LOG" "$LOG.1" 2>/dev/null; then
    echo "the log of the previous run of this sha is kept in $LOG.1" >&2
  else
    echo "warning: the previous log ($LOG) could not be rotated: it will be truncated" >&2
  fi
fi
# The file is created empty so that a reader never sees the log missing (the
# window between the rotation and the first write of the gate).
: > "$LOG" 2>/dev/null || true

# --- the stale binaries of the previous sha ----------------------------------
# The target directory of the gate is a CACHE, not data: cargo keeps the
# binaries of every sha it compiled there. Measured on the 26-10-2026: 490
# executables of 64.6 GB (five shas) next to 6.2 GB of libraries. Two
# problems: the disk fills up (the chain of ten pull requests adds about
# 13 GB of binaries each) and the stale binaries are a page cache the
# machine cannot use.
#
# Only the EXECUTABLES are removed: the libraries (.rlib, .rmeta, .so) are
# what cargo reuses between shas (the crates that did not change), and they
# are only 6 GB. The executables are per sha anyway: cargo rebuilds them
# when the source of their crate changed, and a missing output is a dirty
# fingerprint for cargo, so removing them never breaks the build.
#
# It happens HERE, after the checks that decided that this gate runs (never
# while another gate of the machine is alive: there is at most one gate at
# a time and the executables of a live gate are in use).
prune_stale_binaries() {
  local deps="$GATE_TARGET_DIR/ci/deps" examples="$GATE_TARGET_DIR/ci/examples"
  [ -d "$deps" ] || return 0
  local before after
  before="$(du -sb "$deps" 2>/dev/null | cut -f1)"
  # The executables of cargo have NO extension: the libraries have .rlib,
  # .rmeta or .so, and the dep-info files have .d.
  find "$deps" -maxdepth 1 -type f ! -name '*.*' -delete 2>/dev/null
  [ -d "$examples" ] && find "$examples" -maxdepth 1 -type f ! -name '*.*' -delete 2>/dev/null
  after="$(du -sb "$deps" 2>/dev/null | cut -f1)"
  if [ -n "$before" ] && [ -n "$after" ]; then
    echo "the stale binaries of the previous sha are removed: $((before / 1048576)) MB -> $((after / 1048576)) MB" >&2
  fi
  return 0
}
prune_stale_binaries

if command -v systemd-run >/dev/null 2>&1 && run_gate_with_systemd; then
  :
else
  run_gate_with_setsid
fi
# The `9>&-` closes the supervisor's lock fd for the gate: the lock is
# inherited by every child of the turn (bash keeps the descriptor open), and
# the gate lives 40-90 min: while it held the lock, every tick of the timer
# found the lock taken and the loop answered "turn already running" without
# doing anything. The gate does not need the lock (it works in its own
# worktree) and the next turn has to be able to read its log while it runs.

# Wait for the child to record its PID (max 5 s): without this the supervisor
# could read a stale gate.pid and believe no gate is running. The wait is for
# a NEW file (created after the launch): the old one was removed above, so a
# leftover from the previous run can not be taken for this gate's PID.
NEW_PID=""
for _ in $(seq 1 50); do
  if [ -s "$PID_FILE" ]; then
    pid="$(tr -dc '0-9' < "$PID_FILE" | head -c 10)"
    if [ -n "$pid" ]; then
      mtime="$(stat -c %Y "$PID_FILE" 2>/dev/null || echo 0)"
      case "${mtime:-0}" in ''|*[!0-9]*) mtime=0;; esac
      # the old file was removed before the launch, so a file that exists
      # now is the new one. The mtime and the pid are checked anyway: a
      # reused pid is not an error, but it is worth saying.
      if [ "$mtime" -eq 0 ] || [ "$mtime" -ge "$LAUNCH_EPOCH" ] ||
         { [ -n "$OLD_PID" ] && [ "$pid" != "$OLD_PID" ]; }; then
        NEW_PID="$pid"
        break
      fi
    fi
  fi
  sleep 0.1
done

if [ -n "$NEW_PID" ]; then
  if [ -n "$OLD_PID" ] && [ "$NEW_PID" = "$OLD_PID" ]; then
    echo "the gate started (pid $NEW_PID: the same number as the previous gate)" >&2
  else
    echo "the gate started (pid $NEW_PID; the previous gate was ${OLD_PID:-none})" >&2
  fi
else
  echo "warning: the gate did not record its PID within 5 s: the supervisor will not see a running gate (the log is $LOG)" >&2
fi

# The state of the slot: the sha it gates, the log it writes and the
# worktree it runs in. The default slot also keeps its copy under
# gates/default/, so every slot looks the same from the outside.
echo "$SHA" > "$SHA_FILE"
echo "$LOG" > "$LOG_PATH_FILE"
echo "$WORKTREE" > "$SLOT_DIR/worktree"
if [ -n "$MIRROR_PID" ]; then
  [ -s "$PID_FILE" ] && cp -f "$PID_FILE" "$MIRROR_PID" 2>/dev/null
  [ -s "$STARTED_FILE" ] && cp -f "$STARTED_FILE" "$MIRROR_STARTED" 2>/dev/null
  cp -f "$SHA_FILE" "$MIRROR_SHA" 2>/dev/null
  cp -f "$LOG_PATH_FILE" "$MIRROR_LOG" 2>/dev/null
fi

# The global sidecar points to the LIVE gate whatever slot it belongs to
# (the default slot writes it directly: its own files ARE the global ones).
# Without this, a gate of another slot would leave the sidecar pointing to a
# dead gate and the supervisor would believe that no gate is running.
#
# It is REWRITTEN by every gate: read it to know that a gate is alive, never
# to know which slot it belonged to. The sha and the verdict of a slot live
# in gates/<slot>/ and are frozen by the owner of that slot.
if [ "$SLOT_NAME" != "default" ]; then
  [ -s "$PID_FILE" ] && cp -f "$PID_FILE" "$GLOBAL_PID_FILE" 2>/dev/null
  [ -s "$STARTED_FILE" ] && cp -f "$STARTED_FILE" "$GLOBAL_STARTED_FILE" 2>/dev/null
  cp -f "$SHA_FILE" "$GLOBAL_SHA_FILE" 2>/dev/null
  cp -f "$LOG_PATH_FILE" "$GLOBAL_LOG_PATH_FILE" 2>/dev/null
fi

# The gate of this slot is running: its request is served.
rm -f "$REQUEST_FILE"

echo "$LOG"
