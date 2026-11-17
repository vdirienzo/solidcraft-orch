#!/usr/bin/env bash
# Waits for the machine to free up and runs the FIRST turn by hand.
#
#   first-run.sh [--skip-baseline]
#
# Sequence:
#   1. waits for the baseline CI to finish (if it is running) and REGENERATES
#      baseline-failures.txt from the COMPLETE log (gap G1: with a half list
#      the gate is never green and the loop never publishes);
#   2. waits for the load to drop;
#   3. runs one turn by hand and shows the state.
set -uo pipefail
LOOP_DIR="$HOME/.local/share/solidcraft-loop"
BASELINE_LOG="${BASELINE_LOG:-/tmp/opencode/ci-baseline.log}"

if [ "${1:-}" != "--skip-baseline" ]; then
  echo "[watch] waiting for the baseline CI to finish..."
  for _ in $(seq 1 270); do   # up to 90 min
    pgrep -f "xtask ci" >/dev/null || break
    sleep 20
  done
  echo "[watch] baseline CI finished"
  if [ -f "$BASELINE_LOG" ]; then
    bash "$LOOP_DIR/bin/regen-baseline.sh" "$BASELINE_LOG"
  else
    echo "[watch] no baseline log at $BASELINE_LOG: the list stays as it is"
  fi
fi

# wait for the load to drop (the 1-minute load average)
echo "[watch] waiting for the load to drop..."
for i in $(seq 1 120); do   # up to 40 min
  load=$(cut -d' ' -f1 /proc/loadavg)
  if awk -v l="$load" -v m=24 'BEGIN{exit !(l<m)}'; then
    echo "[watch] load OK ($load) after $((i*20))s"
    break
  fi
  sleep 20
done

echo "[watch] === first manual turn: $(date -Is) ==="
bash "$LOOP_DIR/bin/supervisor.sh"
echo "[watch] === supervisor finished with rc=$? ==="

echo "[watch] --- state.json ---"
cat "$LOOP_DIR/state.json"
echo "[watch] --- last log lines ---"
tail -40 "$LOOP_DIR/logs/$(date -u +%F).err" 2>/dev/null
echo "[watch] --- ledger ---"
tail -5 "$LOOP_DIR/ledger.md"
