#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gate-target-dir.sh - the target directory of the scoped gate, per slot.
#
# WHY (28-10-2026): the scoped gate (bin/gate-quick.sh) used ONE target
# directory for every slot (GATE_QUICK_TARGET_DIR). Two scoped gates that
# ran at the same time fought for the cargo lock of that directory, and the
# loser of that fight did not wait: it died with "Blocking waiting for file
# lock on build directory" (20-10-2026: the clippy of the gate of 20:12
# died because the nextest of the gate of 20:01 was still alive).
#
# The layout is:
#
#   <base>/slot-<slot>/   the target directory of the slot
#   <base>/noslot/        the target directory of a run without a slot
#
# <base> is GATE_QUICK_TARGET_DIR: it is the CONTAINER of the directories,
# never the target directory of a run. The disk collector removes the
# directories one by one and never the container as a whole.
#
# WHAT IT IS: the single source of truth of the layout. The gate and the
# disk collector (bin/gc-disk.sh) read the layout from here: a layout that
# lives in two places is a layout that disagrees with itself.
#
#   bash bin/gate-target-dir.sh --slot s0
#   bash bin/gate-target-dir.sh --noslot
#   bash bin/gate-target-dir.sh --base
#   bash bin/gate-target-dir.sh --list
#   bash bin/gate-target-dir.sh --legacy
#
# The exit code is 2 when the name of the slot is not usable.
# ---------------------------------------------------------------------------
set -uo pipefail

# The default is the one of the gate (bin/gate-quick.sh) and the one of the
# config.env: the two have to be the same number, like every other default
# of the belt.
DEFAULT_BASE="/home/user/solidcraft-gate-quick/target"

usage() {
  cat <<'EOF'
usage: gate-target-dir.sh --slot <name> | --noslot | --base | --list | --legacy

  --slot <name>  the target directory of the slot (<base>/slot-<name>)
  --noslot       the target directory of a run without a slot (<base>/noslot)
  --base         the base of the directories (GATE_QUICK_TARGET_DIR)
  --list         the target directories of the slots that exist, one per line
  --legacy       the shared target directory of the old layout (the base)

The name of a slot is a FILE NAME: it is normalized the way the gate
normalizes it (lower case, [a-z0-9._-] only, no "..", not hidden, 60
characters at most). A name that can not be normalized is NOT invented:
the exit code is 2.
EOF
}

# The base of the directories. The environment wins: the operator points it
# somewhere else with the config.env.
base_dir() {
  printf '%s\n' "${GATE_QUICK_TARGET_DIR:-$DEFAULT_BASE}"
}

# The normalization of the name of a slot: the rules of the gate
# (bin/gate-quick.sh) and of gate-check.sh. The gate and this script have
# to agree: a slot that is named in two ways is two slots.
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

# The name of the slot is not usable: the exit code is 2 (the same one the
# gate uses for a slot name it can not use).
bad_slot() {
  echo "gate-target-dir: the slot name is not usable: $1" >&2
  exit 2
}

MODE=""
ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slot)
      if [ $# -lt 2 ]; then
        echo "gate-target-dir: --slot needs the name of the slot" >&2
        exit 2
      fi
      MODE="slot"
      ARG="$2"
      shift 2
      ;;
    --slot=*)
      MODE="slot"
      ARG="${1#--slot=}"
      shift
      ;;
    --noslot) MODE="noslot"; shift ;;
    --base)   MODE="base";   shift ;;
    --list)   MODE="list";   shift ;;
    --legacy) MODE="legacy"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "gate-target-dir: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$MODE" in
  base|legacy)
    # The old layout wrote in the base itself: the shared directory of
    # every slot. The base is now the container, and this is the directory
    # the disk collector has to treat as legacy.
    base_dir
    ;;
  noslot)
    printf '%s\n' "$(base_dir)/noslot"
    ;;
  slot)
    if [ -z "$ARG" ]; then
      bad_slot "$ARG"
    fi
    name="$(normalize_slot "$ARG")" || bad_slot "$ARG"
    printf '%s\n' "$(base_dir)/slot-$name"
    ;;
  list)
    b="$(base_dir)"
    for dir in "$b"/slot-*; do
      [ -d "$dir" ] || continue
      raw="${dir##*/slot-}"
      # Only the canonical names are listed: a directory that is not the
      # directory of a slot is not the target of anybody.
      [ -n "$raw" ] || continue
      [ "$(normalize_slot "$raw" 2>/dev/null || true)" = "$raw" ] || continue
      printf '%s\n' "$dir"
    done
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
