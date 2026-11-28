#!/usr/bin/env bash
# --------------------------------------------------------------------------
# launch-resume.sh <issue> <loop-overlay-dir> <timeout-min> <unit-name>
#
# WHY (14-11-2026, wave wave-20261114-1850): the two RESUME agents of the
# previous wave died together because the machine was saturated: the gates of
# two open draft PRs were compiling (load 27 on 16 cores) and the agent of
# issue 16784 sat with its probe compile BLOCKED on the build-directory lock
# until its 45-minute timeout killed it. The other one died on a provider
# transport error.
#
# So the agent does NOT start while the machine is busy: it WAITS for the
# gates to release the CPU and for the load to come down, and only then does
# the corridor (agent-issue.sh) run. The wait is bounded and it counts
# against nothing: the unit lives under systemd, so it survives the wave.
#
# The agent gets:
#   - its OWN lock (the orchestrator took it before launching this);
#   - its OWN CARGO_TARGET_DIR (the overlay brief sets it);
#   - the RESUME brief as its prompt (LOOP_DIR=the overlay);
#   - a timeout long enough to finish a compile and a test run.
# --------------------------------------------------------------------------
set -uo pipefail

ISSUE="${1:?falta el issue}"
OVERLAY="${2:?falta el overlay}"
TIMEOUT_MIN="${3:?falta el timeout}"
UNIT="${4:?falta el nombre de la unidad}"

ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
# El corredor SIEMPRE sale del loop canonico, no del overlay: el overlay es
# solo el prompt. El nombre es propio a proposito, porque mas abajo se
# exporta LOOP_DIR="$OVERLAY" y ese debe seguir siendo el overlay.
LOOP_BIN_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
MAX_WAIT_MIN="${MAX_WAIT_MIN:-150}"
MAX_LOAD="${MAX_LOAD:-8}"

# The machine's own paths know where the worktrees are (bin/paths.sh, 2026-11-24): the default
# below is only the fallback for a machine without that file.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${WORKTREES_DIR:-}" ] && [ -f "$HERE/paths.sh" ]; then
  # shellcheck disable=SC1090
  . "$HERE/paths.sh"
fi

log() { printf '%s launch-resume[%s]: %s\n' "$(date -u +%FT%TZ)" "$ISSUE" "$*"; }

load_now() { awk '{print int($1)}' /proc/loadavg; }

# ONLY the gate units count as "the machine is busy". The sibling RESUME unit
# of the other issue must NOT count: if it did, the two agents would wait for
# each other forever and neither would ever start (a deadlock).
gates_busy() {
  local u
  for u in $(systemctl --user list-units 'scgate*.service' --all --no-legend 2>/dev/null | awk '{print $1}'); do
    [ "$(systemctl --user is-active "$u" 2>/dev/null || echo inactive)" = "active" ] && return 0
  done
  return 1
}

# The GO FILE is the release signal: the wave's sequencer (bin/wave-chain.sh)
# writes it when the machine is free of gates. A load-based wait would race
# with a gate that is about to start (the load is still low for seconds after
# the gate launches), and two agents starting together with a gate is what
# starved this machine on 14-11-2026.
GO_FILE="${GO_DIR:-$ORCH_DIR/go}/$ISSUE"

waited=0
while [ "$waited" -lt "$((MAX_WAIT_MIN * 60))" ]; do
  if [ -f "$GO_FILE" ]; then
    log "hay señal de GO ($GO_FILE): arranca el corredor con timeout ${TIMEOUT_MIN}m"
    break
  fi
  load="$(load_now)"
  [ $((waited % 60)) -eq 0 ] && log "espera la señal de GO ($GO_FILE) load=$load gates_busy=$(gates_busy && echo si || echo no) (${waited}s de $((MAX_WAIT_MIN * 60))s)"
  sleep 15
  waited=$((waited + 15))
done

if [ "$waited" -ge "$((MAX_WAIT_MIN * 60))" ]; then
  log "la maquina no se libero en ${MAX_WAIT_MIN}m: el corredor arranca igual (con nice)"
  NICE="nice -n 19"
else
  NICE=""
fi

cd "$OVERLAY" || exit 1
export LOOP_DIR="$OVERLAY"
exec $NICE bash "$LOOP_BIN_DIR/bin/agent-issue.sh" "$ISSUE" \
  --repo tangency-labs/solidcraft \
  --work "${WORKTREES_DIR:-/home/user/solidcraft-wt}" \
  --timeout "$TIMEOUT_MIN"
