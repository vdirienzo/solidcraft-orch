#!/usr/bin/env bash
# The reaper of the COMPLETE gate: it records the death of a gate that died
# WITHOUT writing its EXIT=.
#
# WHY (27-10): the watchdog is the only authority that KILLS the complete
# gate, and when it kills it, it writes EXIT=124 in the log: the state then
# knows the gate did not pass. But the gate can die in other ways: a hand
# kill (the model killing the group of processes), a crash, the OOM killer.
# In those cases nobody writes EXIT= and the log keeps saying "running" for
# ever: the state waits GATE_TIMEOUT_MIN for a verdict that is never coming
# and the phase of the issue stays stuck with no explanation.
#
# The reaper does NOT kill anything: the gate is already dead when it is
# called. It only writes the record of a death that already happened:
#   EXIT=124, the code of `timeout`: the gate was killed, it did not pass.
#
# IT FAILS OPEN. If the pid cannot be read, if the pid is alive (the gate is
# still working), if the log cannot be read, if the log already has an EXIT=
# or if the log does not belong to the sha of the pid file, nothing is
# written: the reaper never invents a verdict.
#
# Usage:
#   gate-reap.sh --pid-file PATH --log PATH [--sha SHA]
#
# Output (stdout, key=value):
#   VERDICT=none|alive|already-recorded|reaped|no-log|other-run
#   REASON=<text>
#   EXIT=<code written or empty>
set -uo pipefail

PID_FILE=""
LOG=""
SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pid-file) PID_FILE="${2:-}"; shift 2 ;;
    --log)      LOG="${2:-}"; shift 2 ;;
    --sha)      SHA="${2:-}"; shift 2 ;;
    *)          shift ;;
  esac
done

say() { printf '%s\n' "$*"; }

if [ -z "$PID_FILE" ] || [ -z "$LOG" ]; then
  say "VERDICT=none"
  say "REASON=the pid file or the log was not given: nothing is written"
  exit 0
fi

[ -r "$PID_FILE" ] || {
  say "VERDICT=none"
  say "REASON=there is no pid file: the gate never started"
  exit 0
}

PID="$(tr -dc '0-9' < "$PID_FILE" 2>/dev/null | head -c 10)"
case "${PID:-}" in ''|*[!0-9]*) PID=0 ;; esac
if [ "$PID" -le 0 ]; then
  say "VERDICT=none"
  say "REASON=the pid file does not hold a pid: nothing is written"
  exit 0
fi

# The gate is alive: it is still working and it will write its own EXIT=.
if kill -0 "$PID" 2>/dev/null; then
  say "VERDICT=alive"
  say "REASON=the gate (pid $PID) is alive: it will write its own EXIT="
  exit 0
fi

if [ ! -f "$LOG" ] || [ ! -r "$LOG" ]; then
  say "VERDICT=no-log"
  say "REASON=the log of the dead gate cannot be read: nothing is written"
  exit 0
fi

# The log already says how the run ended: nothing to add.
if grep -q '^EXIT=[0-9][0-9]*[[:space:]]*$' "$LOG" 2>/dev/null; then
  say "VERDICT=already-recorded"
  say "REASON=the log already has an EXIT=: the death is already recorded"
  exit 0
fi

# The log has to belong to the run of this pid: the name of the log carries
# the short sha of the run (start-gate.sh writes logs/gate-<issue>-<slug>-
# <sha12>.log). If the sha does not match, the log belongs to another run
# and it is not touched.
SHA_SHORT="$(printf '%s' "$SHA" | cut -c1-12)"
if [ -n "$SHA_SHORT" ]; then
  case "$(basename "$LOG")" in
    *"$SHA_SHORT"*) : ;;
    *)
      say "VERDICT=other-run"
      say "REASON=the log does not belong to the sha of the pid file: nothing is written"
      exit 0
      ;;
  esac
fi

if printf 'EXIT=124\n' >> "$LOG" 2>/dev/null; then
  say "VERDICT=reaped"
  say "REASON=the gate (pid $PID) died without writing EXIT=: it is recorded as killed (124)"
  say "EXIT=124"
  exit 0
fi

say "VERDICT=none"
say "REASON=the log could not be written: nothing is recorded"
exit 0
