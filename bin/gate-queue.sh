#!/usr/bin/env bash
# ------------------------------------------------------------------
# gate-queue.sh - the queue of gates that are waiting for a build slot.
#
# WHY THIS EXISTS (2026-11-03): the gate takes a build token with
# "--take --wait 1800", so when the two slots of the box are busy it
# waits half an hour and then gives up with "no free build slot". With
# four gates pending and two slots, the queue never advanced: every
# gate expired on its own and had to be relaunched by hand.
#
# The queue lives in a file, the runner drains it, and the wait happens
# HERE and not in the gate: the runner is the only one that waits, so
# two gates can never fight over the same slot and a gate never dies
# with its own timeout while its turn is legitimate.
#
# USAGE:
#   bash gate-queue.sh --enqueue <issue> <sha>   -> adds a gate to the queue
#   bash gate-queue.sh --list                    -> shows the queue
#   bash gate-queue.sh --run [max_wait_minutes]  -> drains the queue
#
# The runner is safe to run from a cron every few minutes: it takes a
# lock (an atomic mkdir) so only one runner works at a time.
# ------------------------------------------------------------------
set -uo pipefail

# The paths come from the environment, with the default of THIS
# machine: the other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
BIN="$ORCH_DIR/bin"
QUEUE="$ORCH_DIR/gates/queue.txt"
LOCK="$ORCH_DIR/gates/queue.lock"
LOGDIR="$ORCH_DIR/logs"
mkdir -p "$ORCH_DIR/gates" "$LOGDIR"

enqueue(){
  local issue="$1" sha="$2"
  # an entry that is already queued is not queued twice
  if [ -f "$QUEUE" ] && grep -qE "^${issue}[[:space:]]" "$QUEUE"; then
    echo "gate-queue: el slot $issue ya esta en la cola"
    return 0
  fi
  printf '%s %s\n' "$issue" "$sha" >> "$QUEUE"
  echo "gate-queue: encolado el gate del slot $issue ($sha)"
}

list(){
  if [ ! -f "$QUEUE" ] || [ ! -s "$QUEUE" ]; then echo "gate-queue: la cola esta vacia"; return 0; fi
  echo "gate-queue: $(wc -l < "$QUEUE" | tr -d ' ') gate(s) en la cola"
  sed 's/^/  /' "$QUEUE"
}

run(){
  local max_wait="${1:-240}"
  # one runner at a time. A lock left behind by a runner that was killed
  # (the same thing happened to the build tokens: a trap that does not run
  # leaves the lock forever) is released here when it is old and no runner
  # is alive: the liveness of a lock is its AGE and its owner, never its pid.
  if ! mkdir "$LOCK" 2>/dev/null; then
    local lock_age=0
    [ -d "$LOCK" ] && lock_age=$(( ( $(date +%s) - $(stat -c %Y "$LOCK") ) / 60 ))
    local alive
    alive="$(pgrep -f 'gate-queue.sh' 2>/dev/null | grep -v "^$$\$" | head -3 | tr '\n' ' ')"
    if [ "$lock_age" -ge 20 ] && [ -z "$alive" ]; then
      rmdir "$LOCK" 2>/dev/null || true
      if ! mkdir "$LOCK" 2>/dev/null; then
        echo "gate-queue: otro runner esta trabajando (lock $(basename "$LOCK"))"
        return 0
      fi
      echo "gate-queue: se libero un lock viejo (${lock_age} min sin runner vivo)"
    else
      echo "gate-queue: otro runner esta trabajando (lock $(basename "$LOCK"))"
      return 0
    fi
  fi
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
  trap 'rmdir "$LOCK" 2>/dev/null || true; exit 143' TERM INT
  echo "gate-queue: $(date +%H:%M:%S) runner activo (espera maxima ${max_wait} min)"
  local waited=0
  while [ -s "$QUEUE" ]; do
    # "build-slots: 0 used of 2" -> used=0, total=2. The old parse took the
    # LAST number for both, so it read "2 used of 2" and the queue never
    # started a gate even with the box empty.
    local used total
    read -r used total <<< "$(bash "$BIN/build-slot.sh" --status 2>/dev/null \
        | awk '{print $(NF-3), $NF}')"
    local free=$(( total - used ))
    # free is the number of FREE slots (total - used): there is no slot when
    # there are none free. The condition was the other way round and the
    # queue never started a gate with the box empty.
    if [ -z "$free" ] || [ -z "$total" ] || [ "$free" -le 0 ]; then
      echo "gate-queue: no hay slot libre todavia (esperando; van ${waited} min)"
      [ "$waited" -ge "$max_wait" ] && { echo "gate-queue: se agoto la espera de la cola"; break; }
      sleep 60; waited=$((waited+1)); continue
    fi
    local entry; entry="$(head -1 "$QUEUE")"
    local issue sha
    issue="$(printf '%s' "$entry" | awk '{print $1}')"
    sha="$(printf '%s' "$entry" | awk '{print $2}')"
    [ -z "$issue" ] && { sed -i '1d' "$QUEUE"; continue; }
    # the gate takes the token itself: there is a free slot right now
    echo "gate-queue: lanzando el gate del slot $issue ($sha) (hay $free de $total slots libres)"
    sed -i '1d' "$QUEUE"
    ( cd "$WORKTREES_DIR/issue-$issue" 2>/dev/null || cd "$SOLIDCRAFT_REPO"
      # The scoped gate gives the fmt phase 2% of the budget: with the 60 min default that
      # is 72 s, and `cargo fmt --all -- --check` over the whole workspace takes ~67 s
      # on an idle box and more when the agents are compiling. The phase is then killed
      # by timeout and the gate reports ROJO-SCOPE with fmt:fail and NO failed test:
      # a false red that keeps the pull request in draft for nothing. 120 min gives the
      # phase 144 s and it passes. (skill: solidcraft-gate-fmt-slice)
      GATE_QUICK_TIMEOUT_MIN="${GATE_QUICK_TIMEOUT_MIN:-120}" \
      bash "$BIN/gate.sh" "$issue" "$sha" > "$LOGDIR/gate-queue-$issue.log" 2>&1
    ) &
    sleep "${GATE_STAGGER:-90}"   # delay medido: con 90 s el 2do gate encuentra el sccache caliente
    waited=0
  done
  echo "gate-queue: $(date +%H:%M:%S) runner terminado; cola: $( [ -s "$QUEUE" ] && wc -l < "$QUEUE" | tr -d ' ' || echo 0) pendiente(s)"
}

case "${1:-}" in
  --enqueue) enqueue "${2:-}" "${3:-}" ;;
  --list)    list ;;
  --run)     run "${2:-240}" ;;
  # WITHOUT ARGUMENTS IT RUNS THE QUEUE: this is how the cron calls it
  # (a cron job runs a script with no arguments), and a script that only
  # printed the usage would leave the queue standing still.
  "")        run 240 ;;
  *) echo "usage: gate-queue.sh --enqueue <issue> <sha> | --list | --run [min]" >&2; exit 2 ;;
esac
exit 0
