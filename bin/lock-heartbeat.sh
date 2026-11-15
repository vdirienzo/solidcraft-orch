#!/usr/bin/env bash
# --------------------------------------------------------------------------
# lock-heartbeat.sh <slot>...
#
# WHY (14-11-2026, wave wave-20261114-1850): the liveness of a slot lock is
# its AGE and its owner, not its PID (the script that took it exits at once).
# A lock that nobody refreshes for SLOT_LOCK_STALE_MIN (default 240) minutes
# counts as stale and can be reaped, EVEN IF THE AGENT IS STILL WORKING. So a
# slot whose agent is waiting for the machine (for the GO file) still has to
# refresh its lock until the agent is done.
#
# This unit refreshes the locks of the slots of this wave every 30 minutes.
# --------------------------------------------------------------------------
set -uo pipefail
ORCH=/home/user/.local/share/solidcraft-orch
LOCK="$ORCH/bin/slot-lock.sh"
INTERVAL="${INTERVAL:-1800}"

while true; do
  for slot in "$@"; do
    bash "$LOCK" --slot "$slot" --heartbeat 2>/dev/null && \
      printf '%s lock-heartbeat: %s renovado\n' "$(date -u +%FT%TZ)" "$slot"
  done
  sleep "$INTERVAL"
done
