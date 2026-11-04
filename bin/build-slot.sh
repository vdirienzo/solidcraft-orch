#!/usr/bin/env bash
# ------------------------------------------------------------------
# build-slot.sh - the token of a BUILD SLOT of the machine.
#
# WHY THIS EXISTS (2026-11-03): the box has 16 cores and 62 GB and it is
# SHARED. Six compilations were running at the same time (2 gates, 3
# agent tests and a check), and every one of them asked for a share of the
# cores: the load average went to 74, the gate of the slot 3599 spent its
# whole 60 minutes of budget in the clippy phase and ended deferred, and
# the big crates died of OOM-killed.
#
# Dividing the cores between the compilations keeps the box from
# collapsing, but it does NOT shorten the total time: two compilations
# with 8 jobs each take twice as long as one with 16. What shortens the
# time is FEWER compilations at a time, each one with all the cores it
# can have. So the compilations take a token: only BUILD_SLOTS of them
# run at the same time, and the others wait.
#
# The token is a directory: mkdir is atomic, so two processes cannot take
# the same one. A token left behind by a killed run is reclaimed after
# BUILD_STALE_MIN minutes.
#
# USAGE:
#   bash build-slot.sh --take [--wait <seconds>]   -> prints the token, 0 ok
#   bash build-slot.sh --release <token>            -> gives it back
#   bash build-slot.sh --status                    -> how many are free
#   bash build-slot.sh --list                      -> the tokens in use
#
# The number of slots: BUILD_SLOTS (default 2). Two is the measured
# sweet spot: with 16 cores, two compilations with 8 jobs each finish in
# about the same wall clock as one with 16, and the machine keeps two
# cores per compilation for the rest of the system.
# ------------------------------------------------------------------
set -uo pipefail

LOCK_DIR="${BUILD_SLOT_DIR:-/home/user/.local/share/solidcraft-loop/build-slots}"
SLOTS="${BUILD_SLOTS:-2}"
STALE_MIN="${BUILD_STALE_MIN:-180}"

mkdir -p "$LOCK_DIR" 2>/dev/null || true

# A token of a run that died: its directory is older than the limit.
reap_stale() {
  local d age
  for d in "$LOCK_DIR"/slot-*; do
    [ -d "$d" ] || continue
    age=$(( $(date +%s) - $(stat -c %Y "$d" 2>/dev/null || echo 0) ))
    if [ "$age" -gt "$(( STALE_MIN * 60 ))" ]; then
      rm -rf "$d" 2>/dev/null || true
    fi
  done
}

take() {
  local wait_s="${1:-0}" waited=0 token
  reap_stale
  while :; do
    local i
    for i in $(seq 1 "$SLOTS"); do
      if mkdir "$LOCK_DIR/slot-$i" 2>/dev/null; then
        printf '%s\n' "$LOCK_DIR/slot-$i"
        return 0
      fi
    done
    [ "$waited" -ge "$wait_s" ] && return 1
    sleep 15
    waited=$(( waited + 15 ))
    reap_stale
  done
}

case "${1:-}" in
  --take)
    wait_s=0
    [ "${2:-}" = "--wait" ] && wait_s="${3:-0}"
    tok="$(take "$wait_s")" || { echo "build-slot: no free slot" >&2; exit 1; }
    printf '%s\n' "$tok"
    ;;
  --release)
    # THE TOKEN LIVES IN THE LOCK DIRECTORY (2026-11-03): this used to do
    # `rm -rf "$2"`, a relative path that never existed, so NO token was ever
    # released: the two slots of the box stayed taken forever and every gate
    # died with "no free build slot". The token is a name; the lock is a
    # directory under $LOCK_DIR.
    if [ -n "${2:-}" ]; then
      # The token can arrive as its NAME ("slot-1") or as its full PATH
      # ("/…/build-slots/slot-1"): an agent that took the token by hand
      # releases it with the path it was given. Both have to work.
      case "$2" in
        /*) rm -rf "$2" 2>/dev/null || true ;;
        *)  rm -rf "$LOCK_DIR/$2" 2>/dev/null || true ;;
      esac
    fi
    echo "build-slot: released ${2:-}"
    ;;
  --status)
    used=$(ls -d "$LOCK_DIR"/slot-* 2>/dev/null | wc -l | tr -d ' ')
    echo "build-slots: $used used of $SLOTS"
    ;;
  --list)
    ls -d "$LOCK_DIR"/slot-* 2>/dev/null | while read -r d; do
      echo "$d $(cat "$d/owner" 2>/dev/null || echo '?') $(stat -c %y "$d" 2>/dev/null | cut -d. -f1)"
    done
    ;;
  *)
    echo "usage: build-slot.sh --take [--wait s] | --release <token> | --status | --list" >&2
    exit 2
    ;;
esac
exit 0
