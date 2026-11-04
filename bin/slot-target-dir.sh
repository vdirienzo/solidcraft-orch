#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# slot-target-dir.sh - the target directory of a slot, one per slot.
#
# WHY THIS EXISTS (30-10-2026): three agents were working in parallel on
# three issues and two of them compiled with the SAME CARGO_TARGET_DIR
# (the target dir of the checkout). Cargo takes an exclusive lock on the
# build directory of a target: the second cargo does not run in parallel,
# it WAITS for the first one with the message "Blocking waiting for file
# lock on build directory". The agents were not competing for the CPU,
# they were queued in front of each other: the wall clock of the wave was
# the SUM of the compiles and not the maximum.
#
# The original loop had already solved this (bin/gate-target-dir.sh of
# the loop): every slot compiles in a
# directory of its own. This script is the same idea for the orchestrator
# of the delegated agents: the slot of the agent is the name of the issue,
# and every agent gets its own target dir.
#
# The layout:
#   <base>/slot-<name>/   the target directory of the slot
#   <base>/noslot/        the target directory of a run without a slot
#
# <base> is the CONTAINER of the directories, never the target directory of
# a run: the disk collector removes the directories one by one and never the
# container as a whole.
#
# USAGE:
#   bash slot-target-dir.sh --slot <name>   # the target dir of the slot
#   bash slot-target-dir.sh --noslot        # the target dir of no slot
#   bash slot-target-dir.sh --base          # the container
#   bash slot-target-dir.sh --list          # the dirs that exist
#
# EXIT CODES:
#   0  the path (on stdout)
#   2  bad usage, or a slot name that can not be normalized
# ---------------------------------------------------------------------------
set -uo pipefail

# The base of the target directories.
#
# WHY IT IS NOT A CONSTANT (30-10-2026): the script had the base hardcoded
# as $ORCH_DIR/targets, while the orchestrator's own state
# lives in $ORCH_DIR (default ~/.local/share/solidcraft-orch) and the warm
# build caches of the slots are in $ORCH_DIR/targets. An agent that asked
# this script for its target directory therefore got an EMPTY directory
# instead of the cache of its slot: it recompiled the world (30 GB of builds)
# for nothing. The base is now the orchestrator's own, and ORCH_TARGET_BASE
# still overrides it.
DEFAULT_BASE="${ORCH_TARGET_BASE:-${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}/targets}"

base_dir() {
  printf '%s\n' "${ORCH_TARGET_BASE:-$DEFAULT_BASE}"
}

# The normalization of the name of a slot: the name is a FILE NAME. It is
# lower case, only [a-z0-9._-], no "..", not hidden, 60 characters at most.
# A name that can not be normalized is NOT invented: the exit code is 2.
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

MODE=""
ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slot) [ $# -ge 2 ] || { echo "slot-target-dir: --slot needs the name of the slot" >&2; exit 2; }
            MODE="slot"; ARG="$2"; shift 2 ;;
    --slot=*) MODE="slot"; ARG="${1#--slot=}"; shift ;;
    --noslot) MODE="noslot"; shift ;;
    --base)   MODE="base";   shift ;;
    --list)   MODE="list";   shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "slot-target-dir: unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$MODE" in
  base)    base_dir ;;
  noslot)  printf '%s\n' "$(base_dir)/noslot" ;;
  slot)
    if [ -z "$ARG" ]; then
      echo "slot-target-dir: the slot name is not usable: $ARG" >&2
      exit 2
    fi
    name="$(normalize_slot "$ARG")" || {
      echo "slot-target-dir: the slot name is not usable: $ARG" >&2
      exit 2
    }
    printf '%s\n' "$(base_dir)/slot-$name"
    ;;
  list)
    b="$(base_dir)"
    for dir in "$b"/slot-*; do
      [ -d "$dir" ] || continue
      raw="${dir##*/slot-}"
      [ -n "$raw" ] || continue
      [ "$(normalize_slot "$raw" 2>/dev/null || true)" = "$raw" ] || continue
      printf '%s\n' "$dir"
    done
    ;;
  *)
    echo "slot-target-dir: usage: --slot <name> | --noslot | --base | --list" >&2
    exit 2
    ;;
esac
