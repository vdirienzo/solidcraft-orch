#!/usr/bin/env bash
# Lanza el corredor de un issue como SERVICIO systemd transitorio (--unit),
# no como --scope. Motivo (medido el 2026-11-10): los agentes lanzados con
# setsid/nohup desde la sesion de Hermes heredan su cgroup; cuando el turno de
# Hermes termina, systemd tira ese cgroup y el opencode recibe SIGTERM a los
# ~9 minutos. Como servicio transitorio, el agente vive en su propio cgroup
# bajo user@1001.service y sobrevive al fin del turno.
#
# Uso: launch-slot-service.sh <issue> [timeout_min] [log-sufijo]
set -u
ISSUE="${1:?falta el issue}"
TIMEOUT="${2:-45}"
SUFFIX="${3:-$(date -u +%Y%m%d-%H%M)}"
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"

# The belt of the scope, from the policy of the box.
#
# THE BELT IS NOT WRITTEN HERE (2026-11-21): this script used to carry
# MemoryHigh=12G and MemoryMax=16G, and the box has 15 GB. A belt bigger
# than the box is no belt: the scope could ask for more RAM than the
# machine has, and the OOM killer takes whatever it finds FIRST. That was
# the gateway of Hermes, and with it every session of the box.
#
# The policy is read with a small parser and NOT sourced: the LAST
# definition wins, because the policy is read in order and its last block
# is the one that describes THIS box.
policy_value() {
  local key="$1" found=""
  [ -r "$LOOP_DIR/config.env" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "$key"=*) found="${line#*=}" ;;
    esac
  done < "$LOOP_DIR/config.env"
  found="${found%%#*}"
  found="$(printf '%s' "$found" | tr -d '"'"'" | tr -d '[:space:]')"
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

SLOT_MEMORY_HIGH="${SLOT_MEMORY_HIGH:-$(policy_value SLOT_MEMORY_HIGH || true)}"
SLOT_MEMORY_MAX="${SLOT_MEMORY_MAX:-$(policy_value SLOT_MEMORY_MAX || true)}"
# Without a policy the scope gets NO ceiling of its own: the belt of the
# worker scope (4 GiB) applies and the agent dies alone. A wrong ceiling is
# worse than a missing one, so the launcher refuses to guess.
if [ -z "$SLOT_MEMORY_HIGH" ] || [ -z "$SLOT_MEMORY_MAX" ]; then
  echo "launch-slot-service: the policy of the box does not say how much RAM a slot may ask for:" \
    "SLOT_MEMORY_HIGH / SLOT_MEMORY_MAX are missing from $LOOP_DIR/config.env" >&2
  exit 2
fi

TD="$(bash "$ORCH_DIR/bin/slot-target-dir.sh" --slot "$ISSUE")" || exit 1
mkdir -p "$TD"
LOG="$ORCH_DIR/logs/${ISSUE}-wave-${SUFFIX}.log"
UNIT="sc${ISSUE}.service"

systemd-run --user --unit="$UNIT" --collect \
  --property="MemoryHigh=$SLOT_MEMORY_HIGH" --property="MemoryMax=$SLOT_MEMORY_MAX" \
  --property=CPUWeight=100 --property=IOWeight=50 \
  --property=StandardOutput="append:$LOG" \
  --property=StandardError="append:$LOG" \
  --setenv=CARGO_TARGET_DIR="$TD" \
  --setenv=CARGO_BUILD_JOBS=4 \
  --setenv=CARGO_INCREMENTAL=0 \
  --working-directory="$SOLIDCRAFT_REPO" \
  bash "$LOOP_DIR/bin/agent-issue.sh" "$ISSUE" \
    --repo tangency-labs/solidcraft --work "$WORKTREES_DIR" \
    --timeout "$TIMEOUT" >/dev/null 2>&1
RC=$?
echo "launched issue=$ISSUE unit=$UNIT rc=$RC target=$TD log=$LOG"
exit $RC
