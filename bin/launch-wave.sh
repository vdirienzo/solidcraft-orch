#!/usr/bin/env bash
# Launch the loop's agent runner for each issue given on the command line.
# Each runner gets its own per-slot CARGO_TARGET_DIR so two cargo builds
# never fight over the build directory lock.
set -u
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
for i in "$@"; do
  TD="$(bash "$ORCH_DIR/bin/slot-target-dir.sh" --slot "$i")"
  mkdir -p "$TD"
  LOG="$ORCH_DIR/logs/$i-wave.log"
  setsid nohup env CARGO_TARGET_DIR="$TD" CARGO_BUILD_JOBS=4 CARGO_INCREMENTAL=0 \
    bash "$LOOP_DIR/bin/agent-issue.sh" "$i" \
      --repo tangency-labs/solidcraft --work "$WORKTREES_DIR" --timeout 45 \
      > "$LOG" 2>&1 < /dev/null &
  echo "launched issue=$i target=$TD log=$LOG pid=$!"
  sleep 2
done
sleep 8
echo "--- alive ---"
pgrep -af 'agent-issue.sh' | head -10
