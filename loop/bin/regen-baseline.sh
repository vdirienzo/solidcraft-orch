#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Regenerates `baseline-failures.txt` from the COMPLETE baseline log.
#
#   regen-baseline.sh <log> [--out <file>]
#
# Why it exists (gap G1): the list had been generated from a PARTIAL log, and
# an incomplete list means the gate is NEVER green: every pre-existing failure
# that is not in the list shows up as "new", the gate is always red and the
# loop never publishes.
#
# The list does NOT prune itself: a timing test that fails today and does not
# tomorrow stays in the list (with its reason). If a test in the list stops
# failing, it can be removed during a maintenance turn, with the reason noted.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
LOG="${1:-}"
OUT="$LOOP_DIR/baseline-failures.txt"

if [ "${2:-}" = "--out" ]; then
  OUT="${3:-$OUT}"
fi

if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
  echo "the log does not exist: $LOG" >&2
  exit 2
fi

if ! grep -qE '^EXIT=[0-9]+' "$LOG"; then
  echo "WARNING: the log has no EXIT=: the CI did not finish. The list may be incomplete." >&2
fi

ENTRIES="$(bash "$LOOP_DIR/bin/gate-check.sh" --emit-baseline "$LOG")"

mkdir -p "$(dirname "$OUT")"
{
  echo "# Pre-existing failures of this repo on this machine: the ones that are not ours."
  echo "#"
  echo "# A failure that is NOT in this list is NEW: it has to be fixed."
  echo "# Format: <crate>::<test_path>"
  echo "#"
  echo "# Generated from $LOG with bin/regen-baseline.sh."
  echo "# The gate is considered green if ALL of its failures appear here."
  echo "#"
  echo "# TIME assertion failures: they fail because the gate saturates the CPU"
  echo "# (16 vCPUs, load ~250). They are not repo bugs."
  echo ""
  if [ -n "$ENTRIES" ]; then
    echo "$ENTRIES"
  else
    echo "# (no failures: the baseline was green)"
  fi
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "baseline regenerated: $OUT"
grep -vE '^(#|$)' "$OUT" | wc -l | xargs -I{} echo "entries: {}"
