#!/usr/bin/env bash
# Launch the loop's agent runner for each issue given on the command line.
# Each runner gets its own per-slot CARGO_TARGET_DIR so two cargo builds
# never fight over the build directory lock.
set -u
ORCH=/home/user/.local/share/solidcraft-orch
LOOP=/home/user/.local/share/solidcraft-loop
for i in "$@"; do
  TD="$(bash "$ORCH/bin/slot-target-dir.sh" --slot "$i")"
  mkdir -p "$TD"
  LOG="$ORCH/logs/$i-wave.log"
  setsid nohup env CARGO_TARGET_DIR="$TD" CARGO_BUILD_JOBS=4 CARGO_INCREMENTAL=0 \
    bash "$LOOP/bin/agent-issue.sh" "$i" \
      --repo tangency-labs/solidcraft --work /home/user/solidcraft-wt --timeout 45 \
      > "$LOG" 2>&1 < /dev/null &
  echo "launched issue=$i target=$TD log=$LOG pid=$!"
  sleep 2
done
sleep 8
echo "--- alive ---"
pgrep -af 'agent-issue.sh' | head -10
