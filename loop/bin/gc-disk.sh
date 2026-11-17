#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gc-disk.sh - the disk garbage collector of the SolidCraft loop.
#
# WHY: the disk filled up without anybody noticing. The cargo caches grow
# without bound: the `incremental` caches (20 GB), the `deps` of the gate
# (106 GB in three days) and the worktrees of dead sessions. Nothing in the
# loop ever removed them, and the GC that was supposed to do it reported
# FREED_GB=0 in the 27 runs of 2026-10-25.
#
# WHAT IT DELETES:
#   - the `incremental` caches of cargo (main, gate and evidence trees): they
#     are a cache and cargo rebuilds them, and they are worthless across
#     branches (that is why they grew to 94 GB);
#   - the worktrees of dead sessions: no open pull request on their branch, no
#     process working in them, untouched for DISK_GC_WT_MIN_AGE_H, and CLEAN.
#     A dirty worktree is NEVER removed: it can hold uncommitted work that
#     exists nowhere else. The worktrees under a PROTECTED root (the one of
#     the supervisor and the one of opencode) are NEVER removed: the worktree
#     of a live session lives there.
#   - the local branches of pull requests that are already merged or closed,
#     and the local copies of the published `evidence/*` branches;
#   - the dead branches of the FORK (the pull requests that are closed). The
#     `evidence/*` branches of the fork are NEVER touched: the raw links in
#     the body of a pull request point at them.
#   - with --deep: the artifacts of our crates older than
#     DISK_GC_ARTIFACT_DAYS. It costs a rebuild, so it is not automatic.
#   - always: the OLDEST artifacts of the `deps` of the gate, of the scoped
#     gate and of the main checkout, until they are under DISK_DEPS_MAX_GB.
#     That cap is what keeps the disk bounded: the gate rebuilt 106 GB of
#     deps in 3.5 days.
#   - always: the OLDEST target dirs of the tree of the ORCHESTRATOR
#     ($ORCH_TARGET_BASE), until the tree is under DISK_ORCH_TARGET_MAX_GB.
#     That tree grows by ~18 GB per slot (a whole build of the workspace)
#     and the retention of the orchestrator ("the slot stays while its pull
#     request is open") had no bound at all: six open pull requests
#     retained 73 GB of it. The cap is what keeps THAT tree bounded too.
#     The guards are the ones of a live slot (a live cargo, the lock of
#     the orchestrator, an issue in flight, a worktree in use) and a
#     target dir that was touched less than DISK_ORCH_TARGET_MAX_AGE_H ago
#     is HOT (it is the cache of a pull request that is going to be
#     re-gated): the cap reclaims the OLD ones, not the useful ones. The
#     base of the tree is never removed: the dirs go one by one.
#   - with --deep: the target dirs of the SLOTS of the SCOPED gate
#     (<GATE_QUICK_TARGET_DIR>/slot-<slot>, one by one: the base is the
#     container of them and is never removed as a whole). They are caches of
#     their own (the scoped gate does not share the build lock of the main
#     repository) and cargo rebuilds them on demand: it is the price of
#     keeping that cache bounded.
#   - with --stale-targets: the target dirs that are OLD and NOT IN USE, of
#     BOTH trees: the tree of the LOOP (the scoped gate of the loop) and the
#     tree of the ORCHESTRATOR (the delegated agents and the gate of a slot
#     compile there since the unification of 31-10-2026). It is a MODE of its
#     own: it does not obey the daily cooldown and it does nothing else.
#   - the `target` dir of the worktrees that STAY (the target of the main
#     checkout and the one of the gate worktree are NOT touched). A target is
#     a cache that cargo rebuilds on demand. The guards are the ones of the
#     removal of a worktree (no process working in it, untouched for
#     DISK_GC_WT_MIN_AGE_H, its issue not in flight) plus the ones of a live
#     build (no cargo writing in it).
#   - the branches of `backup/` and `archive/` that are older than
#     DISK_GC_BRANCH_TTL_DAYS: they are exported to a bundle FIRST (the only
#     copy that survives, under $LOOP_DIR/bin/bundles) and then deleted.
#
# WHAT IT NEVER TOUCHES: the worktrees of the issues in flight, the branches
# with an open pull request, the `evidence/*` branches of the fork, the target
# DIRECTORY of the main checkout and of the gate worktree (only the files
# inside them are removed; the cache of the scoped gate and the target of the
# worktrees are the exceptions), the artifacts of a tree with a live cargo,
# the data of opencode, the state, the ledger and the reports. A
# GATE_QUICK_TARGET_DIR that points at one of those dirs is never touched,
# not even file by file.
#
# THE ENVIRONMENT:
#   DISK_GC_ENABLED=1        0 = the cleanup never runs
#   DISK_GC_INTERVAL_H=24    the cleanup runs once a day
#   DISK_GC_MIN_FREE_GB=120  under this the deep trim runs on its own
#   DISK_GC_ARTIFACT_DAYS=14 the age of the artifacts that --deep removes
#   DISK_GC_WT_MIN_AGE_H=12  a worktree touched less than this ago is kept
#   DISK_GC_KEEP_PREFIXES=.. the branches that are never removed
#   DISK_GC_BRANCH_TTL_DAYS=30 the age of the `backup/*` and `archive/*`
#                            branches: they are exported to a bundle and
#                            deleted when they are older than this
#   DISK_GC_BUNDLE_DIR=..    where the bundle of an expired branch is
#                            written (it must live under $LOOP_DIR/bin)
#   DISK_DEPS_MAX_GB=60      the cap of the `deps` of the gate, of the
#                            scoped gate and of the main checkout (0 = the
#                            cap is off)
#   DISK_DEPS_GRACE_S=600    an artifact younger than this is never removed
#   DISK_ORCH_TARGET_MAX_GB=60
#                            the cap of the tree of target dirs of the
#                            ORCHESTRATOR (0 = the cap is off). When the
#                            tree is over the cap the OLDEST target dirs
#                            are reclaimed, one by one, and the guards of
#                            a live slot are respected (the lock of the
#                            orchestrator, a live cargo, an issue in
#                            flight, a worktree in use)
#   DISK_ORCH_TARGET_MAX_AGE_H=6
#                            a target dir of the orchestrator that was
#                            touched less than this ago is HOT (the cache
#                            of a pull request that is going to be
#                            re-gated) and the cap never reclaims it
#   GATE_QUICK_TARGET_DIR=.. the BASE of the target dirs of the scoped gate
#                            (a cache: the GC may remove the dirs of the
#                            slots when the disk is low; the base itself is
#                            never removed)
#   ORCH_DIR=..               the home of the ORCHESTRATOR of the delegated
#                            agents (the tree where THEY compile). Its
#                            helper (bin/slot-target-dir.sh) is the source
#                            of truth of the target dirs that exist there
#   ORCH_TARGET_BASE=..      the BASE of the target dirs of the orchestrator
#                            (overrides ORCH_DIR/targets)
#
# USAGE:
#   gc-disk.sh [--dry-run] [--deep] [--force]
#     --dry-run  print what it would do, delete nothing
#     --deep     also delete the old artifacts of our crates (costs a rebuild)
#     --force    ignore the "once a day" guard (a manual run)
#
# The supervisor calls it once per turn; the daily guard makes it run once a
# day. It always exits 0: a cleanup that fails must never break a turn.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"

# The directory of this script: the checker of the configuration
# (bin/config-preflight.sh) lives next to it and it is called by path,
# never by a guess.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/.opencode/bin:$PATH"

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
    echo "gc-disk: the config.env has a syntax error: $LOOP_DIR/config.env" >&2
    exit 2
  fi
fi

if [ -f "$LOOP_DIR/config.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$LOOP_DIR/config.env"
  set +a
fi

REPO="${REPO:-$HOME/solidcraft}"
GATE_WORKTREE="${GATE_WORKTREE:-$HOME/solidcraft-gate}"
EVIDENCE_WORKTREE="${EVIDENCE_WORKTREE:-$HOME/solidcraft-evidence}"
WT_ROOT="${SOLIDCRAFT_WT_ROOT:-$HOME/solidcraft-wt}"
TARGET_DIR="${CARGO_TARGET_DIR:-$REPO/target}"
# The target dir of the SCOPED gate (bin/gate-quick.sh): it has its own so
# its `ci` artifacts do not contend for the build lock of the main
# repository. Nothing but cargo writes there and cargo rebuilds it on
# demand, so it is a CACHE and the GC may remove it.
GATE_QUICK_TARGET_DIR="${GATE_QUICK_TARGET_DIR:-$HOME/solidcraft-gate-quick/target}"
# The tree of the ORCHESTRATOR of the delegated agents. Since the
# unification of the target dir (31-10-2026) the AGENT and the gate of a
# slot compile THERE and not in the tree of the loop: the tree of the
# loop is dead (nobody compiles there any more) and this one is the one
# that grows.
#
# The GC has to know BOTH: a GC that only knows the tree of the loop
# sweeps a tree nobody uses and never touches the one that is filling
# the disk.
ORCH_DIR="${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}"
ORCH_TARGET_BASE="${ORCH_TARGET_BASE:-$ORCH_DIR/targets}"
FORK_REMOTE="${FORK_REMOTE:-fork}"
UPSTREAM="${UPSTREAM:-tangency-labs/solidcraft}"
FORK_OWNER="${FORK_OWNER:-vdirienzo}"

# The roots of the worktrees that are NEVER removed. The first one belongs to
# the supervisor (the worktrees of the issues in flight). The second one
# belongs to opencode: its sessions live in
# `~/.local/share/opencode/worktree/<session>/` and the root that the GC
# checked was `$HOME/solidcraft-wt`, where there is nothing: the GC was
# deleting the worktree of a LIVE session.
WT_ROOTS=("$WT_ROOT" "${OPENCODE_WT_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/worktree}")

# The cap of growth of the `deps` (L0.d), in GB. 0 turns the cap off.
DEPS_MAX_GB="${DISK_DEPS_MAX_GB:-60}"
case "$DEPS_MAX_GB" in
  ''|*[!0-9]*) DEPS_MAX_GB=60 ;;
esac
# The grace window: an artifact younger than this is never removed (a build
# could have started between the check of the live cargo and the deletion).
DEPS_GRACE_S="${DISK_DEPS_GRACE_S:-600}"
case "$DEPS_GRACE_S" in
  ''|*[!0-9]*) DEPS_GRACE_S=600 ;;
esac

# The cap of growth of the tree of target dirs of the ORCHESTRATOR, in GB.
# 0 turns the cap off.
#
# WHY IT EXISTS (01-11-2026): the retention of the orchestrator ("the slot
# stays while its pull request is open") had no bound of size and no bound
# of age. Six open pull requests retained 73 GB of target dirs, every new
# slot costs ~18 GB more (a whole build of the workspace) and the disk was
# at 50% with nothing able to stop it.
ORCH_TARGET_MAX_GB="${DISK_ORCH_TARGET_MAX_GB:-60}"
case "$ORCH_TARGET_MAX_GB" in
  ''|*[!0-9]*) ORCH_TARGET_MAX_GB=60 ;;
esac

# The age of a HOT cache of the orchestrator, in hours: a target dir that
# was touched less than this ago is the cache of a pull request that is
# going to be re-gated soon, and the cap never reclaims it.
ORCH_TARGET_MAX_AGE_H="${DISK_ORCH_TARGET_MAX_AGE_H:-6}"
case "$ORCH_TARGET_MAX_AGE_H" in
  ''|*[!0-9]*) ORCH_TARGET_MAX_AGE_H=6 ;;
esac

# The TTL of the branches whose retention is a TTL and not "for ever": the
# `backup/*` and the `archive/*` branches. When they are older than this they
# are exported to a bundle and then deleted. 0 turns the rule off.
BRANCH_TTL_DAYS="${DISK_GC_BRANCH_TTL_DAYS:-30}"
case "$BRANCH_TTL_DAYS" in
  ''|*[!0-9]*) BRANCH_TTL_DAYS=30 ;;
esac

# Where the bundle of an expired branch is written. It must live under
# $LOOP_DIR/bin: the bundle is the only copy that survives the deletion of
# the branch, and it has to live where the GC is allowed to write. The check
# is done after `log` exists (see below).
BUNDLE_DIR="${DISK_GC_BUNDLE_DIR:-$LOOP_DIR/bin/bundles}"

DAY="$(date -u +%F)"
LOG_DIR="$LOOP_DIR/logs"
LOG_FILE="$LOG_DIR/gc-disk-$DAY.log"
STATUS_FILE="$LOOP_DIR/disk.status"
LAST_FILE="$LOOP_DIR/.gc-disk.last"
LOCK_FILE="$LOOP_DIR/.lock.gc"

DRY_RUN=0
DEEP=0
FORCE=0
STALE_TARGETS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --deep)    DEEP=1 ;;
    --force)   FORCE=1 ;;
    # --stale-targets: ONLY the directed cleanup of the target dirs that are
    # old and not in use. It is NOT the daily cleanup and it does NOT obey
    # its cooldown (see the note at the guard of the day below).
    --stale-targets) STALE_TARGETS=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "gc-disk: argumento desconocido: $arg" >&2; exit 2 ;;
  esac
done

# A rehearsal writes in its own log: the log of the day is the one of the
# real cleanup and a dry run must not mix its "would delete" with the truth.
if [ "$DRY_RUN" -eq 1 ]; then
  LOG_FILE="$LOG_DIR/gc-disk-$DAY-dry-run.log"
fi

mkdir -p "$LOG_DIR" 2>/dev/null || true
log() { echo "gc-disk: $*" | tee -a "$LOG_FILE" >&2; }
say() { echo "gc-disk: $*"; }
# The report of the cap: it goes to the STDOUT (the operator reads it) AND
# to the log file (the record of the day).
#
# WHY IT IS NOT `log`: the stderr of the script is /dev/null (the exec of
# the lock redirects it), so a message of `log` only reaches the log file
# and the operator never sees WHY a target was kept. The report of the
# collector is half of the work: without the "why" nobody can trust it.
report() { echo "gc-disk: $*" | tee -a "$LOG_FILE"; }
# The size of a dir in the words of the operator: "1000 MB (1.0 GB)".
human_size() {
  local bytes="$1" mb gb
  mb=$(( bytes / 1024 / 1024 ))
  gb="$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1024 / 1024 / 1024 }')"
  printf '%s MB (%s GB)' "$mb" "$gb"
}

# The bundle of an expired branch is written under $LOOP_DIR/bin: the bundle
# is the only copy that survives the deletion of the branch and the GC may
# only write there.
case "$BUNDLE_DIR" in
  "$LOOP_DIR"/bin/*) ;;
  *)
    log "DISK_GC_BUNDLE_DIR no está bajo $LOOP_DIR/bin: se usa $LOOP_DIR/bin/bundles"
    BUNDLE_DIR="$LOOP_DIR/bin/bundles"
    ;;
esac

if [ "${DISK_GC_ENABLED:-1}" != "1" ]; then
  say "la limpieza está desactivada (DISK_GC_ENABLED=0)"
  exit 0
fi

# --- the lock: one cleanup at a time in the machine -------------------------
exec 9>"$LOCK_FILE" 2>/dev/null || true
if ! flock -n 9 2>/dev/null; then
  say "ya hay una limpieza en curso"
  exit 0
fi

# --- the daily guard ---------------------------------------------------------
# The guard only advances when NOTHING was skipped because the machine was
# busy: a run that could not clean the cargo caches has to be retried in the
# next turn, not in the next day.
#
# IT DOES NOT GUARD THE DIRECTED CLEANUP OF THE STALE TARGETS: that one is
# a MODE of its own (--stale-targets) and it has its own guards, which are
# stricter (age, no live cargo, the worktree is not in use). The guard is
# about the ROUTINE cleanup, whose work is the daily growth of the caches.
NOW="$(date +%s)"
if [ "$STALE_TARGETS" -eq 0 ] && [ "$FORCE" -eq 0 ] && [ -f "$LAST_FILE" ]; then
  LAST_RUN="$(tr -dc '0-9' < "$LAST_FILE" 2>/dev/null)"
  if [ -n "${LAST_RUN:-}" ] && [ "$LAST_RUN" -gt 0 ]; then
    AGE_H=$(( (NOW - LAST_RUN) / 3600 ))
    if [ "$AGE_H" -lt "${DISK_GC_INTERVAL_H:-24}" ]; then
      say "la última limpieza fue hace ${AGE_H}h (el guardia pide ${DISK_GC_INTERVAL_H:-24}h): nada que hacer"
      exit 0
    fi
  fi
fi

free_gb() { df --output=avail -BG /home 2>/dev/null | tail -1 | tr -dc '0-9'; }
size_bytes() { du -sb "$1" 2>/dev/null | awk '{print $1+0}'; }

# --- the guards of the machine ------------------------------------------------
# The target dirs that a live cargo is writing to. The tree of the main
# checkout is busy while the implement or the quick gate compiles, and the
# tree of the gate is busy while the gate runs: each one is judged by its
# own, so an idle tree can be cleaned while the other one works.
#
# The NAMES of the executables that WRITE into a target dir. The cargo
# family is more than `cargo`: the orchestrator runs the tests with
# `cargo nextest` (the binary is `cargo-nextest`), the linter is
# `cargo clippy` (the binary that compiles is `clippy-driver`), the
# documents are built by `rustdoc` and the compiler is wrapped by `sccache`
# (the server of the cache and the client both inherit the
# CARGO_TARGET_DIR of the build). A target dir that one of them is writing
# in is a build in progress and it is NEVER removed.
#
# The name is matched EXACTLY, never as a fragment of the command line:
# `~/.cargo/bin/rust-analyzer-mcp` has the word `cargo` in its path, so the
# old pattern matched it, it has no CARGO_TARGET_DIR and it fell back to
# `cwd/target` (= the main checkout). The main target was marked as busy
# FOREVER: the GC never touched it and always skipped the deep pass.
CARGO_WRITERS="cargo rustc rustdoc cargo-nextest cargo-watch cargo-clippy clippy-driver cargo-miri cargo-llvm-cov sccache"

is_cargo_writer() {
  # The empty name is not a writer: without the check the pattern of the
  # case would be a single space and it would match the list itself.
  [ -n "$1" ] || return 1
  case " $CARGO_WRITERS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

live_target_dirs() {
  local pid argv0 comm env cwd var
  for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    argv0=""
    IFS= read -r -d '' argv0 2>/dev/null < "/proc/$pid/cmdline" || true
    argv0="${argv0##*/}"
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || continue
    if ! is_cargo_writer "$argv0" && ! is_cargo_writer "$comm"; then continue; fi
    env=""
    while IFS= read -r -d '' var; do
      case "$var" in
        CARGO_TARGET_DIR=*) env="${var#CARGO_TARGET_DIR=}"; break ;;
      esac
    done 2>/dev/null < "/proc/$pid/environ" || true
    if [ -z "${env:-}" ]; then
      cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || continue
      [ -n "$cwd" ] || continue
      env="$cwd/target"
    fi
    printf '%s\n' "$env"
  done | sort -u
}

# Is the tree of a cache busy? The list of the live targets is computed once
# per pass and refreshed before the passes that delete a lot.
LIVE_TARGETS=""
target_live() {
  local base="$1" live
  while IFS= read -r live; do
    [ -n "$live" ] || continue
    case "$live" in
      "$base"|"$base"/*) return 0 ;;
    esac
  done <<< "$LIVE_TARGETS"
  return 1
}

# The target directories of the slots of the scoped gate. The layout is the
# one of bin/gate-target-dir.sh: GATE_QUICK_TARGET_DIR is the CONTAINER of
# them and every slot compiles in <base>/slot-<slot>. The helper is the
# source of truth of the layout; when it is not deployed the directories are
# found by their name.
gate_slot_dirs() {
  local helper="$LOOP_DIR/bin/gate-target-dir.sh" dir
  if [ -x "$helper" ]; then
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      printf '%s\n' "$dir"
    done < <("$helper" --list 2>/dev/null)
    return 0
  fi
  for dir in "$GATE_QUICK_TARGET_DIR"/slot-*; do
    [ -d "$dir" ] || continue
    printf '%s\n' "$dir"
  done
}

# A live cargo that writes in the BASE itself: the legacy layout, where the
# base was the target directory of every slot. A cargo in a slot says
# nothing about the legacy content of the base.
#
# It takes the base as an argument because there are TWO bases: the one of
# the loop and the one of the orchestrator. A cargo in the base of one tree
# says nothing about the other one.
base_live() {
  local base="$1" live
  [ -n "$base" ] || return 1
  while IFS= read -r live; do
    [ -n "$live" ] || continue
    if [ "$live" = "$base" ]; then
      return 0
    fi
  done <<< "$LIVE_TARGETS"
  return 1
}

gate_base_live() {
  base_live "$GATE_QUICK_TARGET_DIR"
}

# The target dirs of the slots of the ORCHESTRATOR: the ones that EXIST.
#
# Its helper (bin/slot-target-dir.sh of the orchestrator) is the source of
# truth of ITS layout and it answers with the dirs that are really there
# (the loop's helper answers with the slots the loop COULD use, which
# includes the ones of the slots that ended long ago). The two answers
# are both right: they are the layout of two different trees.
#
# The helper is called with the env it needs (ORCH_DIR, ORCH_TARGET_BASE),
# so it answers with the base the GC is looking at. It is called with bash
# and NOT with -x: the orchestrator does not mark its scripts executable
# (it calls them with bash), so a check of the executable bit would skip
# the helper and answer with the fallback.
#
# WITHOUT the helper the tree of the orchestrator is NOT touched: the GC
# does not invent the layout of a tree that belongs to somebody else and
# cleans a dir of it by its name. A missing helper means that tree is
# skipped, not that it is emptied.
orch_slot_dirs() {
  local helper="$ORCH_DIR/bin/slot-target-dir.sh" dir
  if [ ! -f "$helper" ]; then
    log "el helper del orquestador no está en $helper: su árbol de target dirs no se toca"
    return 0
  fi
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    printf '%s\n' "$dir"
  done < <(ORCH_DIR="$ORCH_DIR" ORCH_TARGET_BASE="$ORCH_TARGET_BASE" \
           bash "$helper" --list 2>/dev/null)
}

# Is the scoped gate working on that slot RIGHT NOW?
#
# The scoped gate (bin/gate-quick.sh) takes an exclusive lock on
# gates/<slot>/scope.lock while it compiles the scope of that slot: a
# slot whose lock is held is a slot that is building. The lock is the
# signal of the loop itself and it is more precise than the age of the
# target dir (a gate that is between two cargo calls leaves a target dir
# that looks old).
#
# The lock of the ORCHESTRATOR's gate is the SAME lock: the orchestrator
# runs the scoped gate of the loop (bin/gate-quick.sh --slot <issue>), so
# gates/<slot>/scope.lock answers for the slots of BOTH trees.
scope_lock_busy() {
  local name="$1" lock="$LOOP_DIR/gates/$1/scope.lock"
  [ -n "$name" ] || return 1
  [ -f "$lock" ] || return 1
  # The lock is free when it can be taken: a held lock cannot be taken and
  # the probe answers "busy".
  #
  # WHY A SHARED PROBE AND NOT AN EXCLUSIVE ONE (2026-11-17): `flock -n -x`
  # TAKES the lock. The probe of the GC was asking "is the lock free?" by
  # taking it for a moment, and that moment is enough for a gate that was
  # about to take it to lose the race: the gate gets deferred and the GC
  # wins it. A shared probe (`-s`) asks the same question WITHOUT taking
  # the lock: it succeeds only when nobody holds it exclusively.
  exec 8>>"$lock" 2>/dev/null || return 1
  if flock -n -s 8 2>/dev/null; then
    exec 8>&- 2>/dev/null || true
    return 1
  fi
  exec 8>&- 2>/dev/null || true
  return 0
}

# The same question, asked with the name that the loop uses (the name of
# the slot of the tree of the loop).
loop_slot_busy() {
  scope_lock_busy "$1"
}

# Is the target dir of a slot of the ORCHESTRATOR in use?
#
# The orchestrator holds a LOCK per slot for the whole life of the slot
# (bin/slot-lock.sh of the orchestrator): a slot whose lock is taken
# belongs to an agent and its target dir is the cache that the agent is
# building in. The answer is the one of the ORCHESTRATOR itself (its own
# helper), so the GC does not invent a rule about when a lock expires:
# the orchestrator reaps its own locks, on purpose, with the evidence
# that its owner died.
#
# The second signal is the WORKTREE of the issue: a process working in it
# means the agent of that issue is alive (the slot of the orchestrator is
# named after the issue it works on).
orch_slot_in_use() {
  local dir="$1" name issue
  name="${dir##*/}"
  name="${name#slot-}"
  [ -n "$name" ] || return 1
  if [ -f "$ORCH_DIR/bin/slot-lock.sh" ]; then
    # 0 = free, 1 = taken, 2 = the name is not usable. The last one is
    # treated as taken: a slot whose name can not be read is not a slot
    # that is free.
    if ORCH_DIR="$ORCH_DIR" bash "$ORCH_DIR/bin/slot-lock.sh" \
         --slot "$name" --status >/dev/null 2>&1; then
      :
    else
      return 0
    fi
  elif [ -d "$ORCH_DIR/locks/slot-$name" ]; then
    return 0
  fi
  case "$name" in
    ''|*[!0-9]*) return 1 ;;
  esac
  issue="$name"
  if [ -d "$WT_ROOT/issue-$issue" ] && worktree_in_use "$WT_ROOT/issue-$issue"; then
    return 0
  fi
  return 1
}

# Does the ORCHESTRATOR still WANT the target dir of that slot?
#
# The orchestrator keeps the warm cache of a slot whose work can still
# change: a pull request that is still open may come back with changes
# and the rebuild would cost the same again. Its own notes say so ("the
# slot-3892 target stays: PR #9823 is open"), so a collector that only
# looked at the age of the dir would throw away a cache that is kept on
# purpose.
#
# The answer is READ from the state of the orchestrator, never written:
# the GC does not touch that state. The read fails when the state is not
# there (the orchestrator is not deployed) and the answer is then "I do
# not know", which is NOT the answer "it is free".
#
# 0 = the issue has a pull request open (the cache is kept)
# 1 = no pull request open (the cache is a leftover)
# 2 = the state could not be read (the answer is unknown)
#
# The shape of `open_prs` is NOT the same in every state: the loop of the
# tests writes a DICT (pr -> entry) and the orchestrator writes a LIST
# (of entries). Both are read here: a state that cannot be parsed is
# the answer "I do not know" (2), never "there is no pull request" (1).
#
# The `state` of an entry is NOT the state of the pull request: the
# orchestrator writes "draft" and "ready" (the STAGE of the pull request)
# and the list is called `open_prs` because every entry in it is OPEN. So
# an entry is open unless it says that it is closed or merged.
orch_slot_kept() {
  local issue="$1"
  [ -n "$issue" ] || return 2
  python3 - "$ORCH_DIR/state.json" "$issue" <<'PY' 2>/dev/null
import json
import os
import sys

path, issue = sys.argv[1], sys.argv[2]
if not os.path.isfile(path):
    raise SystemExit(2)
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
except Exception:
    raise SystemExit(2)
prs = state.get("open_prs")
# A dict (pr -> entry) or a list (of entries): both are read.
if isinstance(prs, dict):
    entries = list(prs.values())
elif isinstance(prs, list):
    entries = list(prs)
else:
    raise SystemExit(2)
for entry in entries:
    if not isinstance(entry, dict):
        continue
    if str(entry.get("issue")) != issue:
        continue
    if str(entry.get("state", "open")).lower() in ("closed", "merged"):
        continue
    raise SystemExit(0)
raise SystemExit(1)
PY
}

# The state of the ORCHESTRATOR: is it READABLE?
#
# The answer is "I do not know" when it cannot be read, and that is NOT
# the answer "it is free": the collector does not touch a tree whose
# owner it cannot read.
orch_state_readable() {
  python3 - "$ORCH_DIR/state.json" 2>/dev/null <<'PY'
import json
import os
import sys

path = sys.argv[1]
if not os.path.isfile(path):
    raise SystemExit(1)
try:
    with open(path, encoding="utf-8") as handle:
        json.load(handle)
except Exception:
    raise SystemExit(1)
raise SystemExit(0)
PY
}

# The issues whose slot of the ORCHESTRATOR is still RUNNING.
#
# The orchestrator marks them in its own state: the target dir of a
# running slot is the cache of a build that is about to happen (or that
# is happening), and it is never a leftover.
orch_running_issues() {
  python3 - "$ORCH_DIR/state.json" 2>/dev/null <<'PY'
import json
import os
import sys

path = sys.argv[1]
if not os.path.isfile(path):
    raise SystemExit(0)
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
except Exception:
    raise SystemExit(0)
for entry in (state.get("slots") or {}).values():
    if not isinstance(entry, dict):
        continue
    if str(entry.get("status", "")).lower() != "running":
        continue
    issue = entry.get("issue")
    if isinstance(issue, int) and issue > 0:
        print(issue)
PY
}

# The slots whose LOCK of the ORCHESTRATOR is taken RIGHT NOW.
#
# The answer is the one of the ORCHESTRATOR itself (its own helper): the
# GC does not invent a rule about when a lock expires (the orchestrator
# reaps its own locks, on purpose, with the evidence that its owner
# died).
#
# The list is asked for ONCE (bin/slot-lock.sh --list): it is the
# question the orchestrator asks before it decides that a slot is free.
# The probe of one slot (--status) is the fallback for a helper that does
# not know how to list, and the two answers never disagree (both ask the
# orchestrator).
#
# The heavy phase is not a slot: it is filtered out of the list.
orch_live_locks() {
  local helper="$ORCH_DIR/bin/slot-lock.sh" out rc
  [ -f "$helper" ] || return 1
  out="$(ORCH_DIR="$ORCH_DIR" bash "$helper" --list 2>/dev/null)"
  rc=$?
  # The helper that does not know how to list answers with an error: the
  # answer is then "I do not know" and the probe of each slot decides.
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$out" | awk -F'\t' '$1 != "" && $1 !~ /^heavy/ { print $1 }'
  return 0
}

# Is the lock of that slot of the ORCHESTRATOR taken?
#
# 0 = taken (nobody touches it), 1 = free.
#
# The list is the first answer and the probe is the second: a slot that
# is not in the list can still be taken (the list is a snapshot and the
# probe is a probe of the same lock).
orch_slot_locked() {
  local name="$1"
  [ -n "$name" ] || return 1
  case " $LIVE_LOCKS " in
    *" $name "*) return 0 ;;
  esac
  if [ -f "$ORCH_DIR/bin/slot-lock.sh" ]; then
    # 0 = free, 1 = taken, 2 = the name is not usable. The last one is
    # treated as taken: a slot whose name can not be read is not a slot
    # that is free.
    if ORCH_DIR="$ORCH_DIR" bash "$ORCH_DIR/bin/slot-lock.sh" \
         --slot "$name" --status >/dev/null 2>&1; then
      return 1
    fi
    return 0
  fi
  [ -d "$ORCH_DIR/locks/slot-$name" ] && return 0
  return 1
}

# The last activity of a target dir: the mtime of the NEWEST file inside
# it (the mtime of the dir itself when it is empty).
#
# It is the signal of "this cache was used recently": a dir whose newest
# file is old is a leftover, not a cache that is being re-gated. It is
# the SAME signal as the one of the directed cleanup (a file newer than
# the age means the dir is in use).
#
# It answers 0 when it CANNOT tell: the age of a cache that it does not
# know is NOT an age, and "I do not know" is never an invitation to
# delete.
target_last_activity() {
  local dir="$1" t dt
  t="$(find "$dir" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)"
  t="${t%%.*}"
  case "$t" in ''|*[!0-9]*) t=0 ;; esac
  # A dir with no files at all: its own mtime is the only signal there is.
  if [ "$t" -le 0 ]; then
    dt="$(stat -c %Y "$dir" 2>/dev/null || echo 0)"
    case "$dt" in ''|*[!0-9]*) dt=0 ;; esac
    t="$dt"
  fi
  [ "$t" -gt 0 ] || return 1
  printf '%s\n' "$t"
}

# The cap of the tree of target dirs of the ORCHESTRATOR.
#
# WHY (01-11-2026): the retention of the orchestrator ("the slot stays
# while its pull request is open") had no limit of age and no limit of
# size. Six open pull requests retained 73 GB of target dirs, every new
# slot costs ~18 GB more (a whole build of the workspace) and the disk
# was at 50% with nothing able to stop it. The cap is what keeps THAT
# tree bounded, the same way DISK_DEPS_MAX_GB keeps the deps bounded.
#
# The preference to KEEP a target dir, in order:
#   a) the slot whose LOCK of the orchestrator is taken: the agent owns
#      it and nobody touches it;
#   b) the target dir a live cargo is writing in: a build is in progress;
#   c) the target dir of an issue IN FLIGHT (the loop) or of a slot still
#      RUNNING (the orchestrator): the cache is about to be used;
#   d) the target dir whose worktree is in use;
#   e) the HOT cache: a target dir touched less than
#      DISK_ORCH_TARGET_MAX_AGE_H ago is the cache of a pull request that
#      is going to be re-gated soon, so it is kept even over the cap.
# What is left is reclaimed OLDEST FIRST until the tree is under the cap.
# The BASE of the tree is NEVER a candidate: the dirs of the slots go one
# by one.
#
# The cap is an ADDITIONAL mechanism: it only acts when the tree is over
# the cap, and under the cap it touches nothing at all.
#
# It answers with RECLAIM_COUNT (the dirs it reclaimed) and
# RECLAIM_FREED (their bytes), and never deletes anything itself in the
# rehearsal: the caller decides what it does with the numbers.
RECLAIM_FREED=0
RECLAIM_COUNT=0
reclaim_orch_tree() {
  local total cap_bytes need dir name issue age_h bytes freed=0 count=0
  local last pr_open orch_keep_rc
  local -a cands=()
  RECLAIM_FREED=0
  RECLAIM_COUNT=0
  [ "$ORCH_TARGET_MAX_GB" -gt 0 ] || return 0
  [ -d "$ORCH_TARGET_BASE" ] || return 0
  # A base that is not a disposable cache (the target of the main
  # checkout, the data of opencode, a protected worktree root) is never
  # reclaimed: it is not a cache.
  if cache_protected "$ORCH_TARGET_BASE"; then
    report "se conserva $ORCH_TARGET_BASE: no es una caché descartable"
    SKIPPED=$(( SKIPPED + 1 ))
    return 0
  fi
  cap_bytes=$(( ORCH_TARGET_MAX_GB * 1024 * 1024 * 1024 ))
  total="$(size_bytes "$ORCH_TARGET_BASE")"
  if [ "${total:-0}" -le "$cap_bytes" ]; then
    report "el árbol de targets del orquestador ocupa $(human_size "$total") (tope: $(( cap_bytes / 1024 / 1024 / 1024 )) GB): el tope NO está pasado, no se toca nada"
    return 0
  fi
  need=$(( total - cap_bytes ))
  report "el árbol de targets del orquestador ocupa $(human_size "$total") (tope: $(( cap_bytes / 1024 / 1024 / 1024 )) GB): el tope está pasado, se reclaim los targets más viejos"
  # The state of the orchestrator has to be READABLE: without it the GC
  # does not know which slots are alive, and "I do not know" is not the
  # answer "it is free".
  if ! orch_state_readable; then
    report "se conserva el árbol del orquestador (no se pudo leer el estado del orquestador)"
    SKIPPED=$(( SKIPPED + 1 ))
    return 0
  fi
  LIVE_TARGETS="$(live_target_dirs)"
  IN_FLIGHT_ISSUES="$(in_flight_issues)"
  RUNNING_ISSUES="$(orch_running_issues)"
  LIVE_LOCKS=" $(orch_live_locks | tr '\n' ' ')"
  # The candidates: the dirs of the slots of the tree (the helper of the
  # orchestrator is the source of truth of the layout). The BASE is never
  # a candidate: it is the container of them and the dirs go one by one.
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    case "$dir" in
      "$ORCH_TARGET_BASE") continue ;;
    esac
    last="$(target_last_activity "$dir")" || continue
    cands+=("$last"$'\t'"$dir")
  done < <(orch_slot_dirs 2>/dev/null)
  # OLDEST FIRST.
  while IFS=$'\t' read -r last dir; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    case "$dir" in
      "$ORCH_TARGET_BASE") continue ;;
    esac
    name="${dir##*/}"
    name="${name#slot-}"
    issue=""
    case "$name" in
      ''|*[!0-9]*) ;;
      *) issue="$name" ;;
    esac
    # Does its pull request still exist? It is asked BEFORE the age: the
    # report has to say WHY the target is kept or released, and a pull
    # request that is open is the reason the orchestrator keeps a cache.
    pr_open="sin PR abierto"
    if [ -n "$issue" ]; then
      orch_keep_rc=0
      orch_slot_kept "$issue" || orch_keep_rc=$?
      case "$orch_keep_rc" in
        0) pr_open="PR abierto" ;;
        2)
          # The state does not answer: "I do not know" is NOT the answer
          # "it is free". The target is kept.
          report "se conserva $dir (no se pudo saber si su PR sigue abierto)"
          SKIPPED=$(( SKIPPED + 1 ))
          continue
          ;;
      esac
    fi
    # (a) the lock of the orchestrator.
    if orch_slot_locked "$name"; then
      report "se conserva $dir (tiene un lock vivo)"
      SKIPPED=$(( SKIPPED + 1 ))
      continue
    fi
    # (b) a live cargo is writing in it.
    if target_live "$dir"; then
      report "se conserva $dir (hay un cargo vivo)"
      SKIPPED=$(( SKIPPED + 1 ))
      continue
    fi
    # (c) an issue in flight (the loop) or a slot running (the
    #     orchestrator): the cache is about to be used.
    if [ -n "$issue" ]; then
      if printf '%s\n' "$IN_FLIGHT_ISSUES" | grep -qx "$issue"; then
        report "se conserva $dir (su issue está en vuelo)"
        SKIPPED=$(( SKIPPED + 1 ))
        continue
      fi
      if printf '%s\n' "$RUNNING_ISSUES" | grep -qx "$issue"; then
        report "se conserva $dir (su slot del orquestador está corriendo)"
        SKIPPED=$(( SKIPPED + 1 ))
        continue
      fi
      # (d) the worktree that owns it has to be free too.
      if [ -d "$WT_ROOT/issue-$issue" ] && worktree_in_use "$WT_ROOT/issue-$issue"; then
        report "se conserva $dir (su worktree está en uso)"
        SKIPPED=$(( SKIPPED + 1 ))
        continue
      fi
    fi
    # (e) the HOT cache: the age of the newest file inside it. A cache
    #     that was written hours ago is the cache of a pull request that
    #     is going to be re-gated, and it is worth more than the space.
    #     THIS is where the retention by pull request has an AGE: a pull
    #     request of yesterday does not need its cache for ever.
    age_h=$(( (NOW - last) / 3600 ))
    if [ "$age_h" -lt "$ORCH_TARGET_MAX_AGE_H" ]; then
      report "se conserva $dir (su caché está caliente: hace ${age_h}h, $pr_open)"
      SKIPPED=$(( SKIPPED + 1 ))
      continue
    fi
    # The target is a candidate: it has no lock, no cargo, no issue in
    # flight and no hot cache.
    bytes="$(size_bytes "$dir")"
    [ "${bytes:-0}" -gt 0 ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      report "BORRARÍA $dir ($(human_size "$bytes"), el tope del árbol está pasado, sin lock, sin cargo, $pr_open)"
    else
      # The list of the live targets is REFRESHED right before the
      # deletion: a cargo can start in the middle of the pass.
      LIVE_TARGETS="$(live_target_dirs)"
      if target_live "$dir"; then
        report "se conserva $dir (un cargo empezó a escribir ahí durante la pasada)"
        SKIPPED=$(( SKIPPED + 1 ))
        continue
      fi
      rm -rf "$dir" 2>/dev/null || true
      if [ -e "$dir" ]; then
        report "no se pudo borrar $dir: no se cuenta como liberado"
        SKIPPED=$(( SKIPPED + 1 ))
        continue
      fi
      report "borrado $dir ($(human_size "$bytes"), el tope del árbol está pasado, sin lock, sin cargo, $pr_open)"
    fi
    freed=$(( freed + bytes ))
    count=$(( count + 1 ))
    need=$(( need - bytes ))
    [ "$need" -le 0 ] && break
  done < <(printf '%s\n' "${cands[@]}" | sort -n)
  RECLAIM_FREED=$freed
  RECLAIM_COUNT=$count
  if [ "$count" -eq 0 ]; then
    report "el tope del árbol del orquestador no se puede cumplir: todos sus targets están en uso"
    SKIPPED=$(( SKIPPED + 1 ))
  else
    report "el tope del árbol del orquestador: $count targets, $(human_size "$freed") liberados"
  fi
  return 0
}

# The target dirs that the directed cleanup considers, one per line, with
# the kind of tree they belong to: "<kind>\t<dir>".
#
#   loop    a slot of the scoped gate of the loop
#   orch    a slot of the orchestrator of the delegated agents
#   noslot  the target dir of a run without a slot
#   legacy  the legacy content of a base (the layout before the slot dirs)
#   shared  the target of the main checkout or of the gate worktree
#   wt      the target of a worktree
#
# The BASE of a tree is NEVER a candidate: it is the container of the dirs
# of the slots and the collector removes the dirs one by one. The kind
# says which rules apply to each dir: the slot of the orchestrator is
# guarded by the lock of the orchestrator, the shared trees are only
# removed when the disk is low and the worktrees keep the guards of the
# daily pass.
#
# A dir that is in both trees (the same base pointed twice) is only
# considered once: the same dir deleted twice is counted twice and the
# report would lie about the space that was freed.
stale_candidates() {
  local dir base sub wt seen=" "
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    case "$seen" in *" $dir "*) continue ;; esac
    seen="$seen$dir "
    printf 'loop\t%s\n' "$dir"
  done < <(gate_slot_dirs 2>/dev/null)
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    case "$seen" in *" $dir "*) continue ;; esac
    seen="$seen$dir "
    printf 'orch\t%s\n' "$dir"
  done < <(orch_slot_dirs 2>/dev/null)
  # The run without a slot writes in <base>/noslot: it is a target dir
  # like any other (the cache of every run without a slot).
  for base in "$GATE_QUICK_TARGET_DIR" "$ORCH_TARGET_BASE"; do
    dir="$base/noslot"
    [ -d "$dir" ] || continue
    case "$seen" in *" $dir "*) continue ;; esac
    seen="$seen$dir "
    printf 'noslot\t%s\n' "$dir"
  done
  # The legacy layout: the base WAS the target directory of every slot.
  # That content is the cache of EVERY build of that tree, so it follows
  # the rule of the shared trees (only when the disk is low).
  for base in "$GATE_QUICK_TARGET_DIR" "$ORCH_TARGET_BASE"; do
    for sub in ci debug release tmp; do
      dir="$base/$sub"
      [ -d "$dir" ] || continue
      case "$seen" in *" $dir "*) continue ;; esac
      seen="$seen$dir "
      printf 'legacy\t%s\n' "$dir"
    done
  done
  # The shared trees: the target of the main checkout and the one of the
  # gate worktree are the cache of EVERY build.
  printf 'shared\t%s\n' "$TARGET_DIR"
  printf 'shared\t%s\n' "$GATE_WORKTREE/target"
  # The target of the worktrees.
  for wt in "$WT_ROOT"/*; do
    [ -d "$wt/target" ] || continue
    dir="$wt/target"
    case "$seen" in *" $dir "*) continue ;; esac
    seen="$seen$dir "
    printf 'wt\t%s\n' "$dir"
  done
}

gate_alive() {
  local f pid
  for f in "$LOOP_DIR/gate.pid" "$LOOP_DIR"/gates/*/pid; do
    [ -f "$f" ] || continue
    pid="$(tr -dc '0-9' < "$f" 2>/dev/null)"
    [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null; then return 0; fi
  done
  return 1
}

# A process working in the worktree: its cwd is inside it.
worktree_in_use() {
  local path="$1" pid cwd
  for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || continue
    case "$cwd" in
      "$path"|"$path"/*) return 0 ;;
    esac
  done
  return 1
}

# The issues that are in flight: the global state and the state of each slot.
# The cache of the worktree of an issue in flight is about to be used: it is
# never removed.
in_flight_issues() {
  python3 - "$LOOP_DIR/state.json" "$LOOP_DIR"/state/slot-*.json 2>/dev/null <<'PY'
import json
import os
import sys

for path in sys.argv[1:]:
    if not os.path.isfile(path):
        continue
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        continue
    inflight = data.get("in_flight")
    if isinstance(inflight, dict):
        issue = inflight.get("issue")
        if isinstance(issue, int) and issue > 0:
            print(issue)
PY
}

# The issue of a worktree, when it carries one. The signals, in order of
# trust: the branch (`fix/issue-7912-x`), the name of the directory
# (`issue-7912`) and, as a last resort, the number at the end of the branch
# (`feat/7912-x`): the numbers of the issues of this repository are large, so
# a small number is not an issue.
#
# A worktree whose issue cannot be told is treated as "no issue": it is not
# protected by the rule of the issues in flight, but the other guards (the
# live cargo, the process that works in it, the age) still apply.
issue_of_worktree() {
  local path="$1" branch issue name
  branch="$(git -C "$path" branch --show-current 2>/dev/null)" || branch=""
  issue=""
  case "$branch" in
    *issue-*) issue="${branch#*issue-}"; issue="${issue%%-*}" ;;
  esac
  case "$issue" in
    ''|*[!0-9]*) issue="" ;;
  esac
  if [ -z "$issue" ]; then
    name="${path%/}"; name="${name##*/}"
    issue="$(printf '%s\n' "$name" | grep -oE 'issue-[0-9]+' | head -1 | cut -d- -f2)"
  fi
  if [ -z "$issue" ]; then
    case "$branch" in
      *-[0-9][0-9][0-9][0-9]*|-[0-9][0-9][0-9][0-9][0-9]*)
        issue="${branch##*-}"; issue="${issue%%-*}"
        ;;
    esac
  fi
  case "$issue" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # The numbers of the issues of this repository are big: a small one is not
  # an issue (it is a version, a count or a coincidence).
  [ "$issue" -ge 100 ] || return 1
  printf '%s\n' "$issue"
}

# The moment a branch was touched for the last time: the YOUNGEST of its
# signals (the mtime of its ref, the mtime of its reflog, the date of its
# last commit). The branch is only expired when EVERY signal is old: a branch
# that was created today from an old commit is not an old branch.
branch_last_touch() {
  local br="$1" gitdir ts=0 t
  gitdir="$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$gitdir" in
    /*) ;;
    *) gitdir="$REPO/$gitdir" ;;
  esac
  for f in "$gitdir/refs/heads/$br" "$gitdir/logs/refs/heads/$br"; do
    [ -f "$f" ] || continue
    t="$(stat -c %Y "$f" 2>/dev/null)" || continue
    case "$t" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$t" -gt "$ts" ] && ts="$t"
  done
  t="$(git -C "$REPO" log -1 --format=%ct "refs/heads/$br" 2>/dev/null)" || t=""
  case "$t" in
    ''|*[!0-9]*) t=0 ;;
  esac
  [ "$t" -gt "$ts" ] && ts="$t"
  [ "$ts" -gt 0 ] || return 1
  printf '%s\n' "$ts"
}

# The bundle of a branch: the only copy that survives its deletion. It is
# written to a temporary file and renamed only when git verified it, so a
# failed export never leaves a broken bundle behind. The bundle is NEVER
# deleted by the GC: it is the backup of a branch that is not in the
# repository anymore.
export_branch_bundle() {
  local br="$1" bundle tmp sha
  mkdir -p "$BUNDLE_DIR" 2>/dev/null || return 1
  sha="$(git -C "$REPO" rev-parse --short=12 "refs/heads/$br" 2>/dev/null)" || sha=""
  [ -n "$sha" ] || sha="unknown"
  bundle="$BUNDLE_DIR/$(printf '%s' "$br" | tr '/' '_')-$sha.bundle"
  tmp="$bundle.tmp.$$"
  git -C "$REPO" bundle create "$tmp" "refs/heads/$br" >/dev/null 2>&1 \
    || { rm -f "$tmp" 2>/dev/null; return 1; }
  git -C "$REPO" bundle verify "$tmp" >/dev/null 2>&1 \
    || { rm -f "$tmp" 2>/dev/null; return 1; }
  git -C "$REPO" bundle list-heads "$tmp" 2>/dev/null | grep -q . \
    || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$bundle" 2>/dev/null \
    || { rm -f "$tmp" 2>/dev/null; return 1; }
  printf '%s\n' "$bundle"
}

# The worktrees that are NEVER removed: the ones of the supervisor (the
# issues in flight) and the ones of opencode (the sessions in flight). The
# root that the GC checked was `$HOME/solidcraft-wt`, where there is nothing:
# the worktrees of the live sessions live under
# `~/.local/share/opencode/worktree/<session>/`.
PROTECTED_ROOT=""
worktree_protected() {
  local path="$1" root
  PROTECTED_ROOT=""
  for root in "${WT_ROOTS[@]}"; do
    [ -n "$root" ] || continue
    case "$path" in
      "$root"|"$root"/*)
        PROTECTED_ROOT="$root"
        return 0
        ;;
    esac
  done
  return 1
}

# The dirs that the cache of the scoped gate must NEVER reach: the target of
# the main repository (the GC only trims the files inside it), the checkout
# itself, the data of opencode (59 GB of sessions and caches) and the
# protected worktree roots (a live session works there).
#
# It exists because GATE_QUICK_TARGET_DIR comes from the environment and that
# cache IS removed as a directory (and trimmed file by file): without an
# explicit guard a wrong value would take the main repository or the data of
# opencode with it.
cache_protected() {
  local path="$1" root
  case "$path" in
    "$TARGET_DIR"|"$TARGET_DIR"/*) return 0 ;;
    "$REPO"|"$REPO"/*) return 0 ;;
    "${XDG_DATA_HOME:-$HOME/.local/share}"/opencode|"${XDG_DATA_HOME:-$HOME/.local/share}"/opencode/*) return 0 ;;
  esac
  for root in "${WT_ROOTS[@]}"; do
    [ -n "$root" ] || continue
    case "$path" in
      "$root"|"$root"/*) return 0 ;;
    esac
  done
  return 1
}

# The branches that are never deleted (DISK_GC_KEEP_PREFIXES).
#
# `backup/` and `archive/` are NOT part of that list, even when the
# configuration puts them there: their retention is a TTL (see the TTL
# section), not "for ever". A backup that is never cleaned is a backup that
# fills the disk, and the GC could not reclaim the space it promised.
keep_prefix() {
  local br="$1" p
  local old_ifs="$IFS"
  IFS=','
  for p in ${DISK_GC_KEEP_PREFIXES:-main,backup/,feat/}; do
    p="$(printf '%s' "$p" | tr -d ' ')"
    [ -n "$p" ] || continue
    case "$p" in backup/|archive/) continue ;; esac
    case "$br" in "$p"*) IFS="$old_ifs"; return 0 ;; esac
  done
  IFS="$old_ifs"
  return 1
}

# The prefixes whose retention is a TTL: the branches of these prefixes are
# exported to a bundle and deleted when they are too old. The TTL rule owns
# them: the other rules (merged, closed, evidence) never touch them.
ttl_managed() {
  case "$1" in
    backup/*|archive/*) return 0 ;;
  esac
  return 1
}

# The names of the binaries of our integration tests. They are named after the
# TEST FILE (`scenarios`, `run_strict`, ...), not after the crate, so a
# pattern of names alone never sees them: and they are the heaviest artifacts
# of the tree (67 GB of the 106 GB of the gate's ci/deps).
our_test_names() {
  local tree="$1" f name
  for f in "$tree"/crates/*/tests/*.rs "$tree"/apps/*/tests/*.rs "$tree"/xtask/tests/*.rs; do
    [ -f "$f" ] || continue
    f="${f##*/}"
    name="${f%.rs}"
    case "$name" in
      ''|*[!A-Za-z0-9_-]*) continue ;;
    esac
    printf '%s\n' "$name"
  done
}

# The cap of growth of a `deps` directory: the OLDEST artifacts are removed
# until the directory is under the cap. The files are removed one by one, the
# oldest first, and the removal is only counted when the file is gone.
#
# The log does not have one line per file: the cap can delete ten thousand of
# them and every line is a process (tee). The first ones and then one every
# 250 are logged, and the summary says how many were removed.
trim_deps() {
  local deps="$1" target="$2" cap_bytes="$3"
  local total need freed=0 size mtime path rest grace entry removed=0
  [ -d "$deps" ] || return 0
  if target_live "$target"; then
    log "se conserva $deps (hay un cargo vivo escribiendo en $target)"
    SKIPPED=$((SKIPPED + 1))
    BUSY=1
    return 0
  fi
  total="$(size_bytes "$deps")"
  [ "${total:-0}" -gt "$cap_bytes" ] || return 0
  need=$(( total - cap_bytes ))
  log "$deps ocupa $(( total / 1024 / 1024 / 1024 )) GB (tope: $(( cap_bytes / 1024 / 1024 / 1024 )) GB): se borran los artifacts más viejos"
  grace=$(( NOW - DEPS_GRACE_S ))
  while IFS= read -r -d '' entry; do
    mtime="${entry%% *}"
    rest="${entry#* }"
    size="${rest%% *}"
    path="${rest#* }"
    # An artifact younger than the grace window may be in use: the stop here.
    if [ "${mtime%%.*}" -ge "$grace" ]; then
      log "los artifacts de $deps son demasiado recientes: el tope no se puede cumplir sin tocar trabajo en curso"
      break
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      if [ "$removed" -lt 50 ] || [ $(( removed % 250 )) -eq 0 ]; then
        log "se borraría el artifact viejo de $deps: $path ($(( size / 1024 / 1024 )) MB)"
      fi
    else
      rm -f "$path" 2>/dev/null || true
      if [ -e "$path" ]; then
        log "no se pudo borrar $path: no se cuenta como liberado"
        SKIPPED=$((SKIPPED + 1))
        continue
      fi
      if [ "$removed" -lt 50 ] || [ $(( removed % 250 )) -eq 0 ]; then
        log "borrado el artifact viejo de $deps: $path ($(( size / 1024 / 1024 )) MB)"
      fi
    fi
    freed=$(( freed + size ))
    need=$(( need - size ))
    removed=$(( removed + 1 ))
    ACTIONS=$((ACTIONS + 1))
    [ "$need" -le 0 ] && break
  done < <(find "$deps" -maxdepth 1 -type f -printf '%T@ %s %p\0' 2>/dev/null | sort -z -n)
  if [ "$removed" -gt 0 ]; then
    FREED_BYTES=$(( FREED_BYTES + freed ))
    log "el tope de $deps se recupera: $removed artifacts, $(( freed / 1024 / 1024 )) MB"
  fi
}

FREED_BYTES=0
ACTIONS=0
SKIPPED=0
BUSY=0

# The accounting of what was freed. A removal only counts when it is VERIFIED
# (the path is gone): the log of 2026-10-25 counted a worktree that did not
# exist three times (309 MB each), and `disk.status` reported a disk that had
# not been touched.
remove_and_count() {
  local path="$1" bytes="$2" verb="$3"
  local mb=$(( bytes / 1024 / 1024 ))
  if [ "$DRY_RUN" -eq 1 ]; then
    log "se borraría $verb: $path (${mb} MB)"
    FREED_BYTES=$((FREED_BYTES + bytes))
    ACTIONS=$((ACTIONS + 1))
    return 0
  fi
  log "borrando $verb: $path (${mb} MB)"
  rm -rf "$path" 2>/dev/null || true
  if [ -e "$path" ]; then
    log "no se pudo borrar $path: no se cuenta como liberado"
    SKIPPED=$((SKIPPED + 1))
    return 1
  fi
  FREED_BYTES=$((FREED_BYTES + bytes))
  ACTIONS=$((ACTIONS + 1))
  return 0
}

# The rehearsal (bin/dry-run.sh) runs the supervisor against a COPY of the
# loop dir: the git worktrees and the fork are the real ones there, and a
# rehearsal must not delete them. The cargo caches are safe: the rehearsal
# points CARGO_TARGET_DIR at its own temporary directory.
REAL_MACHINE=1
CANONICAL="$HOME/.local/share/solidcraft-loop"
if [ "$(cd "$LOOP_DIR" 2>/dev/null && pwd -P)" != "$(cd "$CANONICAL" 2>/dev/null && pwd -P)" ]; then
  REAL_MACHINE=0
fi

BEFORE_GB="$(free_gb)"
say "libres antes: ${BEFORE_GB} GB"

# The deep trim (the old artifacts of our crates) is automatic when the disk
# is low: that is what DISK_GC_MIN_FREE_GB promises. It costs a rebuild, so
# it only happens when the space is actually scarce.
if [ "$DEEP" -eq 0 ] && [ "${BEFORE_GB:-999}" -lt "${DISK_GC_MIN_FREE_GB:-120}" ]; then
  DEEP=1
  log "el disco está bajo (${BEFORE_GB} GB < ${DISK_GC_MIN_FREE_GB:-120} GB): el trim profundo se activa solo"
fi

# --- the directed cleanup of the STALE TARGET DIRS --------------------------
# WHY THIS IS SEPARATE FROM THE DAILY CLEANUP (30-10-2026):
# The daily guard below stops EVERYTHING when the last cleanup was less
# than 24h ago. On the 30-10 that left 170 GB of a target dir from the 28-10
# sitting on the disk: the guard reported "la última limpieza fue hace 6h:
# nada que hacer" while the disk was at 43% used with a stale 170 GB tree.
# The guard is right for the ROUTINE cleanup (the caches of cargo grow
# every day and a cleanup every day is enough) and it is wrong for a
# TARGET DIR THAT IS NOT BEING USED: a dir of 170 GB that no cargo has
# touched for two days is not a daily growth, it is a leftover.
#
# So: the directed cleanup of the stale targets does NOT obey the daily
# cooldown, and it has its OWN guards, which are STRICTER than the ones of
# the daily pass:
#   - the dir must not have been touched for DISK_GC_STALE_TARGET_H (3h by
#     default: long enough that a build that is between two cargo calls is
#     not mistaken for a leftover);
#   - no live cargo may be writing to it (the same check of the daily pass,
#     by the CARGO_TARGET_DIR of the process, not by a fragment of its
#     command line);
#   - it must NOT be the target of the main checkout when the main checkout
#     is the one that builds (the main target is the one that the quick
#     gate and the agents use: it is only removed when it is stale AND the
#     disk is low);
#   - the dir must belong to a worktree that is not in use.
#
# IT KNOWS THE TWO TREES (31-10-2026): the one of the loop (the scoped
# gate) and the one of the ORCHESTRATOR (the agents and their gate). Since
# the unification of the target dir the agents compile in the tree of the
# orchestrator, so that is the tree that fills the disk; the tree of the
# loop is the one that is left behind. A GC that only knew the tree of the
# loop swept a tree nobody used and never touched the one that grows.
#
# The layout of EACH tree is read from ITS helper (the loop's
# bin/gate-target-dir.sh and the orchestrator's bin/slot-target-dir.sh):
# a layout that lives in two places is a layout that disagrees with itself.
# The BASE of a tree is never a candidate: it is the container of the dirs
# of the slots and the collector removes the dirs one by one.
#
# It is a MODE (--stale-targets): it does nothing else, so it can be run
# at any moment without touching the caches, the worktrees or the branches.
#
# IT DOES NOT GO TO THE NETWORK (31-10-2026): the block is BEFORE the list
# of the open pull requests, because the list of the branches is not one of
# its guards and the call spends the quota of the API. The mode works with
# the network down, which is when a disk that is filling up has to be
# cleaned.
if [ "$STALE_TARGETS" -eq 1 ]; then
  STALE_MIN_AGE_H="${DISK_GC_STALE_TARGET_H:-3}"
  # The disk is "low" with the threshold of the daily pass, so the two
  # passes mean the same thing by "low".
  STALE_MIN_FREE_GB="${DISK_GC_STALE_TARGET_MIN_FREE_GB:-${DISK_GC_MIN_FREE_GB:-120}}"
  # The worktrees keep the age of the daily pass: the directed cleanup does
  # NOT relax the guard of the routine one.
  STALE_WT_MIN_AGE_H="${DISK_GC_WT_MIN_AGE_H:-12}"
  LIVE_TARGETS="$(live_target_dirs)"
  IN_FLIGHT_ISSUES="$(in_flight_issues)"
  STALE_FOUND=0
  STALE_FREED=0

  # The target dirs of the two trees, one by one. The kind says which
  # rules apply: the slot of the orchestrator is a warm cache that its own
  # lock guards, and the shared trees are only removed when the disk is
  # low.
  while IFS=$'\t' read -r kind tdir; do
    [ -n "$tdir" ] || continue
    [ -d "$tdir" ] || continue
    # The BASE of a tree is never removed as a whole: it is the container
    # of the dirs of the slots. The guard is here as well and not only in
    # the list of the candidates: a base that is pointed twice (the same
    # dir in the two trees) would be a candidate of the list.
    case "$tdir" in
      "$GATE_QUICK_TARGET_DIR"|"$ORCH_TARGET_BASE")
        say "se conserva $tdir (es la base de un árbol de target dirs: los dirs se borran uno por uno)"
        continue
        ;;
    esac
    # The live ones are not ours to remove.
    if target_live "$tdir"; then
      say "se conserva $tdir (hay un cargo vivo escribiendo ahí)"
      continue
    fi
    # The name of the slot: it is the name of the dir and it is the name
    # of the lock of the scoped gate (gates/<slot>/scope.lock).
    slot="${tdir##*/}"
    slot="${slot#slot-}"
    # The base of the tree the dir belongs to.
    base="${tdir%/*}"
    # The age: the newest file of the tree. A dir whose newest file is old
    # is a leftover, not a cache that is growing. The worktrees keep the
    # age of the daily pass.
    min_age_h="$STALE_MIN_AGE_H"
    [ "$kind" = "wt" ] && min_age_h="$STALE_WT_MIN_AGE_H"
    newest="$(find "$tdir" -type f -newermt "-${min_age_h} hours" -print -quit 2>/dev/null || true)"
    if [ -n "$newest" ]; then
      say "se conserva $tdir (tiene un archivo de menos de ${min_age_h}h)"
      continue
    fi
    bytes="$(size_bytes "$tdir")"
    [ "${bytes:-0}" -gt 0 ] || continue
    # The rules of each kind of tree.
    case "$kind" in
      orch)
        # The slot of the orchestrator is guarded by ITS lock: the
        # orchestrator holds the lock of a slot for the whole life of the
        # slot, and the worktree of the issue is the other signal that the
        # agent of that slot is alive. A slot whose lock is taken is a slot
        # that somebody else owns: nobody touches it.
        if orch_slot_in_use "$tdir"; then
          say "se conserva $tdir (su slot del orquestador está en uso)"
          continue
        fi
        # And by ITS OWN decision to keep it: while the pull request of
        # the issue is open the orchestrator keeps the warm cache on
        # purpose, because a rebuild would cost the same again. The
        # answer is read from its state; if the state cannot be read the
        # answer is "I do not know" and the dir is kept.
        orch_keep_rc=0
        orch_slot_kept "$slot" || orch_keep_rc=$?
        if [ "$orch_keep_rc" -eq 0 ]; then
          say "se conserva $tdir (el orquestador lo guarda: su pull request sigue abierto)"
          continue
        fi
        if [ "$orch_keep_rc" -eq 2 ]; then
          say "se conserva $tdir (no se pudo leer el estado del orquestador)"
          continue
        fi
        ;;
      legacy|shared)
        # The legacy content of a base (the layout before the slots) and
        # the shared trees (the main checkout and the gate worktree) are
        # the cache of EVERY build: they are only removed when the disk
        # is low, never because they are old.
        if [ "$(free_gb)" -gt "$STALE_MIN_FREE_GB" ]; then
          say "se conserva $tdir (el disco no está bajo: ${STALE_MIN_FREE_GB} GB)"
          continue
        fi
        ;;
    esac
    # A cargo that writes in the BASE itself (the legacy layout, where
    # the base was the target dir of every slot) makes the whole base
    # busy: its content is being written. The question only makes sense
    # for the dirs that live in the base of a tree of slots: the shared
    # trees and the targets of the worktrees have no base of slots.
    case "$kind" in
      loop|orch|noslot|legacy)
        if base_live "$base"; then
          say "se conserva $tdir (hay un cargo vivo escribiendo en la base $base)"
          continue
        fi
        ;;
    esac
    # The scoped gate of that slot: while it holds the lock of the slot
    # it is compiling in that tree, even between two cargo calls (the age
    # of the dir does not see that). The lock of the ORCHESTRATOR's gate
    # is this same lock: the orchestrator runs the scoped gate of the
    # loop, so it answers for the slots of both trees.
    if scope_lock_busy "$slot"; then
      say "se conserva $tdir (el gate de scope de su slot está corriendo)"
      continue
    fi
    # An issue that is in flight is about to be compiled: its cache is
    # not a leftover.
    if [ -n "$slot" ] && printf '%s\n' "$IN_FLIGHT_ISSUES" | grep -qx "$slot"; then
      say "se conserva $tdir (su issue $slot está en vuelo)"
      continue
    fi
    # The worktree that owns it has to be free too.
    owner="$(dirname "$tdir")"
    if [ -d "$owner" ] && [ -e "$owner/.git" ]; then
      if worktree_in_use "$owner"; then
        say "se conserva $tdir (su worktree está en uso)"
        continue
      fi
    fi
    STALE_FOUND=$(( STALE_FOUND + 1 ))
    if [ "$DRY_RUN" -eq 1 ]; then
      say "BORRARÍA $tdir ($(( bytes / 1024 / 1024 / 1024 )) GB, sin uso desde hace más de ${min_age_h}h)"
    else
      # The list of the live targets is REFRESHED right before the
      # deletion: the pass takes minutes (a tree of 12 GB takes a while to
      # measure) and a cargo can start in the middle of it. The dir that
      # was free a minute ago can be the dir of a build that just began.
      LIVE_TARGETS="$(live_target_dirs)"
      if target_live "$tdir"; then
        say "se conserva $tdir (un cargo empezó a escribir ahí durante la pasada)"
        STALE_FOUND=$(( STALE_FOUND - 1 ))
        continue
      fi
      rm -rf "$tdir" 2>/dev/null || true
      if [ -e "$tdir" ]; then
        say "no se pudo borrar $tdir: no se cuenta como liberado"
        STALE_FOUND=$(( STALE_FOUND - 1 ))
        continue
      fi
      say "borrado $tdir ($(( bytes / 1024 / 1024 / 1024 )) GB, sin uso desde hace más de ${min_age_h}h)"
    fi
    STALE_FREED=$(( STALE_FREED + bytes ))
  done < <(stale_candidates)

  # The cap of the tree of the orchestrator: it is the mechanism that
  # bounds THAT tree. It runs AFTER the rules above (they have the first
  # word: a dir that they would remove is removed by them) and it only
  # acts when the tree is over the cap.
  #
  # It does not go to the network: the state of the orchestrator and its
  # locks are local. The mode works with the network down, which is when
  # a disk that is filling up has to be cleaned.
  reclaim_orch_tree
  STALE_FOUND=$(( STALE_FOUND + RECLAIM_COUNT ))
  STALE_FREED=$(( STALE_FREED + RECLAIM_FREED ))

  if [ "$STALE_FOUND" -eq 0 ]; then
    say "no hay target dirs obsoletos (la maquina esta limpia)"
  else
    say "target dirs obsoletos: $STALE_FOUND (liberados $(( STALE_FREED / 1024 / 1024 / 1024 )) GB)"
  fi
  say "espacio libre: $(free_gb) GB"
  exit 0
fi

# --- the open pull requests: their branches are in use -----------------------
# ONLY our own pull requests: the upstream has hundreds of open pull requests
# and a truncated list would leave our branches (the old ones) outside it.
#
# NOTE: this call goes to the network and spends the quota of the API, also
# in --dry-run. The behaviour is NOT changed here, but it has a consequence
# to know: with the network down the list comes back EMPTY, so OPEN_BRANCH has
# no branch and every branch of a pull request that is still open is reported
# as deletable. The other guards (the worktree in use, the age, the dirty
# tree) still hold, but a branch whose pull request is open can be deleted
# when the machine is offline.
declare -A OPEN_BRANCH=()
while IFS= read -r br; do
  [ -n "$br" ] || continue
  OPEN_BRANCH["$br"]=1
done < <(gh pr list --repo "$UPSTREAM" --author "$FORK_OWNER" --state open --limit 100 --json headRefName --jq '.[].headRefName' 2>/dev/null)


# --- the caches that the GC trims --------------------------------------------
# The cache of the scoped gate is a candidate ONLY when it is really a
# disposable cache: GATE_QUICK_TARGET_DIR comes from the environment and a
# wrong value (the target of the main repository, the data of opencode) must
# not make the GC write inside a dir that is never touched
# (cache_protected). The other bases are hardcoded and cannot mispoint.
GATE_QUICK_IS_CACHE=1
CACHE_BASES=("$TARGET_DIR" "$GATE_WORKTREE/target")
if cache_protected "$GATE_QUICK_TARGET_DIR"; then
  GATE_QUICK_IS_CACHE=0
  log "se conserva $GATE_QUICK_TARGET_DIR: no es una caché descartable"
  SKIPPED=$(( SKIPPED + 1 ))
else
  CACHE_BASES+=("$GATE_QUICK_TARGET_DIR")
  # Every slot compiles in a directory of its own: each one is a cache of
  # its own and each one is trimmed as a cache (a live cargo in one slot
  # does not stop the trim of the others).
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    CACHE_BASES+=("$dir")
  done < <(gate_slot_dirs)
fi

# --- 1. the incremental caches of cargo --------------------------------------
LIVE_TARGETS="$(live_target_dirs)"
for base in "${CACHE_BASES[@]}" "$EVIDENCE_WORKTREE"/target*; do
  [ -d "$base" ] || continue
  if target_live "$base"; then
    log "se conserva $base (hay un cargo vivo escribiendo ahí)"
    SKIPPED=$((SKIPPED + 1))
    BUSY=1
    continue
  fi
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    bytes="$(size_bytes "$dir")"
    [ "${bytes:-0}" -gt 0 ] || continue
    remove_and_count "$dir" "$bytes" "la caché incremental"
  done < <(find "$base" -maxdepth 5 -type d -name incremental -prune 2>/dev/null)
done

# --- 2. the worktrees of dead sessions ---------------------------------------
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    "$REPO"|"$GATE_WORKTREE"|"$EVIDENCE_WORKTREE") continue ;;
  esac
  if worktree_protected "$path"; then
    log "se conserva el worktree $path (vive bajo la raíz protegida $PROTECTED_ROOT)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  [ -d "$path" ] || continue
  branch="$(git -C "$path" branch --show-current 2>/dev/null)"
  if [ -n "$branch" ] && [ -n "${OPEN_BRANCH[$branch]:-}" ]; then
    log "se conserva el worktree $path (su rama $branch tiene un PR abierto)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  if worktree_in_use "$path"; then
    log "se conserva el worktree $path (hay un proceso trabajando en él)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  mtime="$(stat -c %Y "$path" 2>/dev/null || echo "$NOW")"
  age_h=$(( (NOW - mtime) / 3600 ))
  if [ "$age_h" -lt "${DISK_GC_WT_MIN_AGE_H:-12}" ]; then
    log "se conserva el worktree $path (tocado hace ${age_h}h)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  dirty="$(git -C "$path" status --porcelain 2>/dev/null | head -3)"
  if [ -n "$dirty" ]; then
    log "se conserva el worktree $path (tiene trabajo sin commitear: $(printf '%s' "$dirty" | head -1))"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  bytes="$(size_bytes "$path")"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "se borraría el worktree $path ($(( bytes / 1024 / 1024 )) MB)"
    FREED_BYTES=$((FREED_BYTES + bytes))
    ACTIONS=$((ACTIONS + 1))
    continue
  fi
  log "borrando el worktree $path ($(( bytes / 1024 / 1024 )) MB)"
  if [ "$REAL_MACHINE" -eq 1 ]; then
    git -C "$REPO" worktree remove --force "$path" >/dev/null 2>&1 || rm -rf "$path" 2>/dev/null || true
    git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  fi
  # The removal only counts when it is verified: the path must be gone.
  if [ -e "$path" ]; then
    log "no se pudo borrar el worktree $path: no se cuenta como liberado"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  FREED_BYTES=$((FREED_BYTES + bytes))
  ACTIONS=$((ACTIONS + 1))
done < <(git -C "$REPO" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')

# --- 3. the target dir of the worktrees that stay ----------------------------
# The target dir of a worktree is a CACHE: cargo rebuilds it on demand. The
# GC never removed it (the roots of the worktrees are protected roots, so the
# whole worktree survives) and the disk filled up with those caches.
#
# The guards are the ones of the removal of a dead worktree plus the ones of
# a live build:
#   - no cargo is writing in it (target_live) and no process has its cwd
#     inside the worktree (worktree_in_use);
#   - the target has not been touched for DISK_GC_WT_MIN_AGE_H;
#   - the issue of the worktree is not in flight (the state of the loop);
#   - the worktree does not live under the root of opencode (a live session
#     of the agent works there).
LIVE_TARGETS="$(live_target_dirs)"
IN_FLIGHT_ISSUES="$(in_flight_issues)"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    "$REPO"|"$GATE_WORKTREE"|"$EVIDENCE_WORKTREE") continue ;;
  esac
  target="$path/target"
  [ -d "$target" ] || continue
  case "$path" in
    "${OPENCODE_WT_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/worktree}"/*)
      log "se conserva el target de $path (vive bajo la raíz de opencode)"
      SKIPPED=$((SKIPPED + 1))
      continue
      ;;
  esac
  if target_live "$target"; then
    log "se conserva el target de $path (hay un cargo vivo escribiendo ahí)"
    SKIPPED=$((SKIPPED + 1))
    BUSY=1
    continue
  fi
  if worktree_in_use "$path"; then
    log "se conserva el target de $path (hay un proceso trabajando en el worktree)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  issue="$(issue_of_worktree "$path")" || issue=""
  if [ -n "$issue" ] && printf '%s\n' "$IN_FLIGHT_ISSUES" | grep -qx "$issue"; then
    log "se conserva el target de $path (su issue $issue está en vuelo)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  mtime="$(stat -c %Y "$target" 2>/dev/null || echo "$NOW")"
  age_h=$(( (NOW - mtime) / 3600 ))
  if [ "$age_h" -lt "${DISK_GC_WT_MIN_AGE_H:-12}" ]; then
    log "se conserva el target de $path (tocado hace ${age_h}h)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  bytes="$(size_bytes "$target")"
  remove_and_count "$target" "$bytes" "el target del worktree"
done < <(git -C "$REPO" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')

# --- 4. the local branches of the pull requests already closed ----------------
CLOSED_BRANCHES="$(gh pr list --repo "$UPSTREAM" --author "$FORK_OWNER" --state closed --limit 100 --json headRefName --jq '.[].headRefName' 2>/dev/null | sort -u)"

while IFS= read -r br; do
  [ -n "$br" ] || continue
  keep_prefix "$br" && continue
  ttl_managed "$br" && continue
  [ -n "${OPEN_BRANCH[$br]:-}" ] && continue
  git -C "$REPO" show-ref --verify --quiet "refs/heads/$br" || continue
  log "borrando la rama local $br (ya está en origin/main)"
  if [ "$DRY_RUN" -eq 0 ]; then
    git -C "$REPO" branch -d "$br" >/dev/null 2>&1 || true
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$br"; then
      log "no se pudo borrar la rama local $br: sigue ahí"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi
  ACTIONS=$((ACTIONS + 1))
done < <(git -C "$REPO" branch --merged origin/main --format='%(refname:short)' 2>/dev/null)

while IFS= read -r br; do
  [ -n "$br" ] || continue
  keep_prefix "$br" && continue
  ttl_managed "$br" && continue
  [ -n "${OPEN_BRANCH[$br]:-}" ] && continue
  git -C "$REPO" show-ref --verify --quiet "refs/heads/$br" || continue
  log "borrando la rama local $br (su PR ya está cerrado)"
  if [ "$DRY_RUN" -eq 0 ]; then
    git -C "$REPO" branch -D "$br" >/dev/null 2>&1 || true
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$br"; then
      log "no se pudo borrar la rama local $br: sigue ahí"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi
  ACTIONS=$((ACTIONS + 1))
done <<< "$CLOSED_BRANCHES"

while IFS= read -r br; do
  [ -n "$br" ] || continue
  keep_prefix "$br" && continue
  [ -n "${OPEN_BRANCH[$br]:-}" ] && continue
  git -C "$REPO" show-ref --verify --quiet "refs/heads/$br" || continue
  log "borrando la copia local de la rama de evidencia $br (está publicada en el fork)"
  if [ "$DRY_RUN" -eq 0 ]; then
    git -C "$REPO" branch -D "$br" >/dev/null 2>&1 || true
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$br"; then
      log "no se pudo borrar la copia local de la rama de evidencia $br: sigue ahí"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi
  ACTIONS=$((ACTIONS + 1))
done < <(git -C "$REPO" branch --list 'evidence/*' --format='%(refname:short)' 2>/dev/null)

# --- 5. the dead branches of the fork ----------------------------------------
# The `evidence/*` branches of the fork are NEVER deleted: the raw links in
# the body of a pull request point at them.
while IFS= read -r br; do
  [ -n "$br" ] || continue
  case "$br" in evidence/*) continue ;; esac
  keep_prefix "$br" && continue
  ttl_managed "$br" && continue
  [ -n "${OPEN_BRANCH[$br]:-}" ] && continue
  git -C "$REPO" ls-remote --exit-code --heads "$FORK_REMOTE" "refs/heads/$br" >/dev/null 2>&1 || continue
  log "borrando la rama $br del fork (su PR está cerrado)"
  if [ "$DRY_RUN" -eq 0 ] && [ "$REAL_MACHINE" -eq 1 ]; then
    git -C "$REPO" push "$FORK_REMOTE" --delete "$br" >/dev/null 2>&1 \
      || log "no se pudo borrar $br del fork"
  fi
  ACTIONS=$((ACTIONS + 1))
done <<< "$CLOSED_BRANCHES"

# --- 6. the branches with a TTL: backup/* and archive/* ----------------------
# These prefixes are NOT retained for ever: when a branch of them is older
# than DISK_GC_BRANCH_TTL_DAYS it is exported to a bundle and then deleted.
# The bundle is the only copy that survives: it is written under
# $LOOP_DIR/bin/bundles and the GC NEVER deletes a bundle.
#
# The TTL rule owns these branches: the other rules (merged, closed, evidence,
# the fork) never touch them.
if [ "$BRANCH_TTL_DAYS" -gt 0 ]; then
  while IFS= read -r br; do
    [ -n "$br" ] || continue
    ttl_managed "$br" || continue
    [ -n "${OPEN_BRANCH[$br]:-}" ] && continue
    git -C "$REPO" show-ref --verify --quiet "refs/heads/$br" || continue
    # A branch that a worktree has checked out is in use.
    if git -C "$REPO" worktree list --porcelain 2>/dev/null | grep -Fqx "branch refs/heads/$br"; then
      log "se conserva la rama $br (un worktree la tiene checked out)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    ts="$(branch_last_touch "$br")" || continue
    age_d=$(( (NOW - ts) / 86400 ))
    if [ "$age_d" -lt "$BRANCH_TTL_DAYS" ]; then
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      log "se borraría la rama $br (${age_d} días) después de exportarla a un bundle"
      ACTIONS=$((ACTIONS + 1))
      continue
    fi
    bundle="$(export_branch_bundle "$br")" || bundle=""
    if [ -z "$bundle" ]; then
      log "no se pudo exportar la rama $br a un bundle: se conserva"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    log "la rama $br tiene ${age_d} días: se exportó a $bundle y se borra"
    git -C "$REPO" branch -D "$br" >/dev/null 2>&1 || true
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$br"; then
      log "no se pudo borrar la rama $br: sigue ahí"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    ACTIONS=$((ACTIONS + 1))
  done < <(git -C "$REPO" branch --list 'backup/*' 'archive/*' --format='%(refname:short)' 2>/dev/null)
fi

# --- 7. the git repository: the unreachable objects --------------------------
if pgrep -x git >/dev/null 2>&1; then
  log "hay otro proceso git vivo: no se compacta el repositorio"
  SKIPPED=$((SKIPPED + 1))
  BUSY=1
else
  log "compactando el repositorio git"
  if [ "$DRY_RUN" -eq 0 ]; then
    git -C "$REPO" reflog expire --expire=now --all >/dev/null 2>&1 || true
    git -C "$REPO" gc --prune=now --quiet >/dev/null 2>&1 || true
  fi
  ACTIONS=$((ACTIONS + 1))
fi

# --- 8. --deep: the old artifacts of our crates ------------------------------
# Our crates are the ones whose package name starts with `solidcraft-` (plus
# `solvecraft-` and `xtask`): the pattern cannot hit a third-party crate. The
# integration tests are the exception: their binary is named after the test
# file, so the name alone never sees them and they are the heaviest artifacts
# of the tree. The list of the test names comes from the tree that owns the
# cache.
if [ "$DEEP" -eq 1 ]; then
  ART_DAYS="${DISK_GC_ARTIFACT_DAYS:-14}"
  LIVE_TARGETS="$(live_target_dirs)"
  for base in "${CACHE_BASES[@]}" "$EVIDENCE_WORKTREE"/target*; do
    [ -d "$base" ] || continue
    if target_live "$base"; then
      log "se conserva $base (hay un cargo vivo escribiendo ahí): el trim profundo no lo toca"
      SKIPPED=$((SKIPPED + 1))
      BUSY=1
      continue
    fi
    case "$base" in
      "$GATE_WORKTREE"/*)     tree="$GATE_WORKTREE" ;;
      "$EVIDENCE_WORKTREE"/*) tree="$EVIDENCE_WORKTREE" ;;
      *)                      tree="$REPO" ;;
    esac
    names_re="$(our_test_names "$tree" | paste -sd'|' -)"
    for profile in debug release ci; do
      deps="$base/$profile/deps"
      [ -d "$deps" ] || continue
      if [ -n "$names_re" ]; then
        find_art=(find "$deps" -maxdepth 1 -type f -mtime "+$ART_DAYS" -regextype posix-extended
          \( -name 'libsolidcraft*-*' -o -name 'solidcraft*-[0-9a-f]*'
             -o -name 'libsolvecraft*-*' -o -name 'solvecraft*-[0-9a-f]*'
             -o -name 'libxtask-*' -o -name 'xtask-[0-9a-f]*'
             -o -regex ".*/(lib)?($names_re)-[0-9a-f]+.*" \) -printf '%s %p\n')
      else
        find_art=(find "$deps" -maxdepth 1 -type f -mtime "+$ART_DAYS"
          \( -name 'libsolidcraft*-*' -o -name 'solidcraft*-[0-9a-f]*'
             -o -name 'libsolvecraft*-*' -o -name 'solvecraft*-[0-9a-f]*'
             -o -name 'libxtask-*' -o -name 'xtask-[0-9a-f]*' \) -printf '%s %p\n')
      fi
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        remove_and_count "${line#* }" "${line%% *}" "el artifact viejo"
      done < <("${find_art[@]}" 2>/dev/null)
    done
  done
fi

# --- 9. the cache of the scoped gate (only with --deep) ----------------------
# The scoped gate (bin/gate-quick.sh) has its OWN target dir: its `ci`
# artifacts do not contend for the build lock of the main repository and
# nothing but cargo writes there. It is a CACHE (cargo rebuilds it on
# demand) and it grows without bound: the `ci` of the main repository
# reached 61 GB and the scoped gate writes the same kind of artifacts.
#
# It costs a rebuild, so it follows the policy of the deep trim: it only
# happens with --deep, that is, when the disk is low (DISK_GC_MIN_FREE_GB
# turns the deep trim on by itself). The guards are the ones of the other
# caches: a GATE_QUICK_TARGET_DIR that is not a disposable cache is never
# touched (cache_protected) and a live cargo writing there keeps it.
#
# The age of the directory says nothing (the scoped gate writes there on
# every turn), so the live cargo is the only signal that a build is in
# progress: a scoped gate that finds the cache gone rebuilds it.
#
# The base is the CONTAINER of the directories of the slots, so it is never
# removed as a whole: the cache of a slot that is running would die with it.
# The directories are removed ONE BY ONE, and the legacy content of the old
# layout (the base was the target directory of every slot) is removed dir by
# dir too.
if [ "$DEEP" -eq 1 ] && [ "$GATE_QUICK_IS_CACHE" -eq 1 ] \
   && [ -d "$GATE_QUICK_TARGET_DIR" ]; then
  LIVE_TARGETS="$(live_target_dirs)"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if cache_protected "$dir"; then
      log "se conserva $dir: no es una caché descartable"
      SKIPPED=$(( SKIPPED + 1 ))
      continue
    fi
    if target_live "$dir"; then
      log "se conserva $dir (hay un cargo vivo escribiendo ahí)"
      SKIPPED=$(( SKIPPED + 1 ))
      BUSY=1
      continue
    fi
    bytes="$(size_bytes "$dir")"
    if [ "${bytes:-0}" -gt 0 ]; then
      remove_and_count "$dir" "$bytes" "la caché del gate de scope"
    fi
  done < <(gate_slot_dirs)
  # The legacy layout: the base was the target directory itself.
  if gate_base_live; then
    log "se conserva $GATE_QUICK_TARGET_DIR (hay un cargo vivo escribiendo ahí)"
    SKIPPED=$(( SKIPPED + 1 ))
    BUSY=1
  else
    for sub in ci debug release tmp; do
      dir="$GATE_QUICK_TARGET_DIR/$sub"
      [ -d "$dir" ] || continue
      if target_live "$dir"; then
        log "se conserva $dir (hay un cargo vivo escribiendo ahí)"
        SKIPPED=$(( SKIPPED + 1 ))
        BUSY=1
        continue
      fi
      bytes="$(size_bytes "$dir")"
      if [ "${bytes:-0}" -gt 0 ]; then
        remove_and_count "$dir" "$bytes" "la caché del gate de scope (layout antiguo)"
      fi
    done
  fi
fi

# --- 10. the cap of growth of the deps (L0.d) ---------------------------------
# The `deps` of a profile grow without bound: the gate rebuilt 106 GB of them
# in three days and they come back every day. The cap removes the OLDEST
# artifacts until the directory is under DISK_DEPS_MAX_GB.
#
# It is conservative: it never removes a target directory (only files inside
# `deps`), it never touches a tree with a live cargo, and it never removes an
# artifact younger than DISK_DEPS_GRACE_S (a build could have started between
# the check of the live cargo and the deletion).
if [ "$DEPS_MAX_GB" -gt 0 ]; then
  LIVE_TARGETS="$(live_target_dirs)"
  # The cap is in GB of 1024 (the same unit that df and du use).
  DEPS_SPECS=("$GATE_WORKTREE/target/ci/deps|$GATE_WORKTREE/target")
  if [ "$GATE_QUICK_IS_CACHE" -eq 1 ]; then
    # The legacy layout: the base was the target directory itself.
    DEPS_SPECS+=("$GATE_QUICK_TARGET_DIR/ci/deps|$GATE_QUICK_TARGET_DIR")
    # The layout of today: every slot compiles in a directory of its own.
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      DEPS_SPECS+=("$dir/ci/deps|$dir")
    done < <(gate_slot_dirs)
  fi
  DEPS_SPECS+=("$TARGET_DIR/debug/deps|$TARGET_DIR")
  for spec in "${DEPS_SPECS[@]}"; do
    trim_deps "${spec%%|*}" "${spec##*|}" "$(( DEPS_MAX_GB * 1024 * 1024 * 1024 ))"
  done
fi

# --- 11. the cap of growth of the tree of targets of the ORCHESTRATOR --------
# The tree of the ORCHESTRATOR ($ORCH_TARGET_BASE) grows by ~18 GB per
# slot (a whole build of the workspace) and the retention of the
# orchestrator ("the slot stays while its pull request is open") had no
# bound of size and no bound of age: six open pull requests retained
# 73 GB of it and the disk was at 50% with nothing able to stop it.
#
# The cap removes the OLDEST target dirs until the tree is under
# DISK_ORCH_TARGET_MAX_GB. It is the same spirit as the cap of the deps
# and it obeys the same rules:
#   - the guards of a live slot are NEVER relaxed (the lock of the
#     orchestrator, a live cargo, an issue in flight, a worktree in use);
#   - the base of the tree is never removed: the dirs go one by one;
#   - a HOT cache (touched less than DISK_ORCH_TARGET_MAX_AGE_H ago) is
#     kept even over the cap: it is the cache of a pull request that is
#     going to be re-gated, and it is worth more than the space.
#
# The cap is an ADDITIONAL mechanism: under the cap it touches nothing,
# and over the cap it touches only what it has to.
if [ "$ORCH_TARGET_MAX_GB" -gt 0 ]; then
  reclaim_orch_tree
  # The space the cap reclaimed counts like any other action of the
  # collector: the report of the day has to say it.
  FREED_BYTES=$(( FREED_BYTES + RECLAIM_FREED ))
  ACTIONS=$(( ACTIONS + RECLAIM_COUNT ))
fi

# --- the report ---------------------------------------------------------------
AFTER_GB="$(free_gb)"
FREED_MB=$(( FREED_BYTES / 1024 / 1024 ))
# The GB are reported with a decimal: the old integer division said 0 GB in the
# 27 runs of 2026-10-25 although the cleanup freed 400 MB each time.
FREED_GB="$(awk -v mb="$FREED_MB" 'BEGIN { printf "%.1f", mb / 1024 }')"
if [ "$DRY_RUN" -eq 0 ]; then
  {
    echo "FREE_GB=$AFTER_GB"
    echo "LAST_RUN=$NOW"
    echo "FREED_GB=$FREED_GB"
    echo "ACTIONS=$ACTIONS"
    echo "SKIPPED=$SKIPPED"
  } > "$STATUS_FILE" 2>/dev/null || true
  # The daily guard only advances when nothing was skipped for busy: a run
  # that could not clean the cargo caches has to be retried in the next turn.
  if [ "$BUSY" -eq 0 ]; then
    echo "$NOW" > "$LAST_FILE" 2>/dev/null || true
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  say "acciones: $ACTIONS · conservados: $SKIPPED · a liberar: ${FREED_GB} GB · libres ahora: ${AFTER_GB} GB"
  say "modo --dry-run: no se borró nada"
else
  say "acciones: $ACTIONS · conservados: $SKIPPED · liberados: ${FREED_GB} GB · libres ahora: ${AFTER_GB} GB"
fi
exit 0
