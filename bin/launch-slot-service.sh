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

TD="$(bash "$ORCH_DIR/bin/slot-target-dir.sh" --slot "$ISSUE")" || exit 1
mkdir -p "$TD"
LOG="$ORCH_DIR/logs/${ISSUE}-wave-${SUFFIX}.log"
UNIT="sc${ISSUE}.service"

systemd-run --user --unit="$UNIT" --collect \
  --property=MemoryHigh=12G --property=MemoryMax=16G \
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
