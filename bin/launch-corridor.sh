#!/usr/bin/env bash
# Launch the loop corridor for one issue, fully detached, with its own target dir.
# Usage: launch-corridor.sh <issue> <model> <logname>
set -uo pipefail

ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"

ISSUE="$1"; MODEL="$2"; LOGNAME="$3"
ORCH=${ORCH_DIR}
LOOP=${LOOP_DIR}
TARGET="$(bash "$ORCH/bin/slot-target-dir.sh" --slot "$ISSUE")"
mkdir -p "$ORCH/logs" "$TARGET"
export CARGO_TARGET_DIR="$TARGET"
export CARGO_BUILD_JOBS=4
export CARGO_INCREMENTAL=0
cd "$ORCH"
setsid nohup bash "$LOOP/bin/agent-issue.sh" "$ISSUE" \
  --repo tangency-labs/solidcraft \
  --work ${WORKTREES_DIR} \
  --timeout 30 \
  --model "$MODEL" \
  > "$ORCH/logs/$LOGNAME" 2>&1 < /dev/null &
echo "corridor_pid=$! issue=$ISSUE model=$MODEL target=$TARGET log=$ORCH/logs/$LOGNAME"
