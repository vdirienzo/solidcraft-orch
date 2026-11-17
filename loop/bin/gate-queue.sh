#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gate-queue.sh - drains the queue of the gates.
#
# WHAT THE QUEUE IS: there is at most ONE live gate in the machine. The gate
# is CPU-bound (it saturates the 16 cores: load 231 over 16 vCPU), so two
# gates at the same time do not go faster, they take twice as long. A slot
# that asks for a gate while another one is running does NOT get it:
# start-gate.sh leaves a REQUEST in gates/<slot>/request and exits with code
# 6, and the turn goes on with the phase `gating`.
#
# WHY THIS SCRIPT EXISTS: until now NOTHING drained that queue. The slot that
# asked waited for a gate that nobody was going to launch: its turn ended
# with the phase `gating` and the machine idled while the request waited.
# This script launches the gate of the oldest request, one at a time.
#
# IT IS A TIMER OF ITS OWN, NOT PART OF A TURN: the supervisor's tick takes
# the lock of its slot and returns at once when the turn of that slot is
# running (a turn lasts up to 55 min), so a drain inside the tick would only
# happen in the gaps between turns. The queue has to be served WHILE the
# other slot works, otherwise the gate of the queued slot waits for a whole
# turn for a gate that could have started minutes earlier.
#
# THE DECISION IS NOT REPEATED HERE: start-gate.sh checks again that no other
# gate is alive, that this slot has no gate of its own, and that the sha was
# not gated already. If a gate started in the meantime the request stays in
# the queue and the next tick serves it: the queue is never lost.
#
# A REQUEST THAT CAN NEVER BE SERVED IS REMOVED: one whose worktree is gone
# (exit 3) or whose file is malformed (exit 2) would be picked again on every
# tick, forever, and it would block the requests behind it.
#
# EXIT CODES OF start-gate.sh, and what they mean here:
#   0  the gate is launched: nothing else to do
#   2  the request is malformed: it is removed
#   3  the worktree of the slot is gone: the request is removed
#   5  the slot already has a live gate: the next request is tried
#   6  another gate is alive (or a CI is running): the queue waits
#   8  the sha was already gated: start-gate.sh removed the request itself
#  11  the complete gate is disabled by configuration (GATE_COMPLETE_MODE=off,
#      27-10-2026): the request is removed, because it can never be served and
#      leaving it there would make the timer retry it every two minutes,
#      forever. The fair local gate is the one of the scope (bin/gate-quick.sh).
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
GATES_DIR="$LOOP_DIR/gates"
ERR="$LOOP_DIR/logs/$(date +%Y-%m-%d).err"

say() { echo "[$(date -Is)] $*" | tee -a "$ERR" >&2; }

mkdir -p "$LOOP_DIR/logs"

# ONE DRAIN AT A TIME: two drains would launch two gates.
exec 9>"$LOOP_DIR/.gate-queue.lock"
flock -n 9 || exit 0

# The oldest request wins: the queue is served in the order the slots asked.
requests=()
for request in "$GATES_DIR"/*/request; do
  [ -r "$request" ] || continue
  slot="$(basename "$(dirname "$request")")"
  at="$(grep -E '^requested_at=' "$request" 2>/dev/null | tail -1 | cut -d= -f2)"
  case "${at:-0}" in ''|*[!0-9]*) at=0 ;; esac
  requests+=("$at|$slot|$request")
done

if [ "${#requests[@]}" -eq 0 ]; then
  exit 0
fi

# The oldest first: the list is sorted by the epoch of the request.
sorted=()
while IFS='|' read -r at slot request; do
  sorted+=("$at|$slot|$request")
done < <(printf '%s\n' "${requests[@]}" | sort -t'|' -k1,1n)

for entry in "${sorted[@]}"; do
  at="${entry%%|*}"
  rest="${entry#*|}"
  slot="${rest%%|*}"
  request="${rest#*|}"

  say "the gate queue has a request from the slot $slot (asked at $at): the gate is launched"
  bash "$LOOP_DIR/bin/start-gate.sh" --from-request --slot "$slot" >>"$ERR" 2>&1
  rc=$?
  case "$rc" in
    0)
      say "the gate of the slot $slot is launched from its request"
      exit 0
      ;;
    2|3)
      say "the request of the slot $slot can never be served (exit $rc): it is removed"
      rm -f "$request"
      ;;
    5)
      say "the slot $slot already has a live gate: the next request is tried"
      ;;
    11)
      # The complete gate is disabled on purpose (GATE_COMPLETE_MODE=off): the
      # request can never be served, so it leaves the queue. Leaving it there
      # would make the timer retry it every two minutes, forever.
      say "the complete gate is disabled (exit 11): the request of the slot $slot is removed"
      rm -f "$request"
      ;;
    6)
      say "another gate is alive: the queue waits"
      exit 0
      ;;
    *)
      say "the gate of the slot $slot was not launched (exit $rc): the request stays in the queue"
      ;;
  esac
done

exit 0
