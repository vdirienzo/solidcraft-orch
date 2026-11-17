#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ceiling-experiment.sh - the ladder of the experiment of the ceiling.
#
# WHAT IT DOES: at the start of every UTC day it looks at the ladder of
# config.env and applies the entry of the day, if there is one:
#
#   CEILING_LADDER="2026-10-27:175000 2026-10-28:200000 2026-10-29:150000"
#
# WHY A LADDER: each day of the ladder is a FULL day with ONE ceiling, so
# the days can be compared with each other (bin/cache-effect.py) and against
# the baseline (bin/compare-baseline.py). The change is one line of the
# config and it is reversible (bin/ceiling.sh restore), but a day that mixes
# two ceilings measures nothing: the ladder gives every day its own ceiling.
#
# The last entry of the ladder is a ceiling that is already measured, so the
# experiment never leaves the loop in a state nobody has validated.
#
# The change is written to logs/ceiling.log, which is where the analysis reads
# the history from.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOOP_DIR="${LOOP_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"

# The configuration is CHECKED before it is read: a value with spaces and
# no quotes breaks the source of the config.env in the middle of the file,
# so the variable is never set and the script goes on with HALF of the
# policy, in silence (set -e is not on). The check only READS the file: it
# is read twice and sourced once. If the config.env is broken, the script
# STOPS here instead of running with half of the policy.
if [ -r "$LOOP_DIR/config.env" ]; then
  if [ -x "$SCRIPT_DIR/config-preflight.sh" ]; then
    bash "$SCRIPT_DIR/config-preflight.sh" "$LOOP_DIR/config.env" || exit 2
  elif ! bash -n "$LOOP_DIR/config.env" >/dev/null 2>&1; then
    echo "ceiling-experiment: the config.env has a syntax error: $LOOP_DIR/config.env" >&2
    exit 2
  fi
fi

LADDER="$(grep -m1 '^CEILING_LADDER=' "$LOOP_DIR/config.env" 2>/dev/null | cut -d= -f2- | sed 's/ *#.*//' | tr -d '"')"
if [ -z "$LADDER" ]; then
  echo "ceiling-experiment: there is no ladder in the config (CEILING_LADGER): nothing to do"
  exit 0
fi

TODAY="$(date -u +%F)"
ENTRY=""
for item in $LADDER; do
  case "$item" in
    "$TODAY":*) ENTRY="$item" ;;
  esac
done
if [ -z "$ENTRY" ]; then
  echo "ceiling-experiment: today ($TODAY) is not in the ladder: the ceiling does not move"
  exit 0
fi

TARGET="${ENTRY#*:}"
case "$TARGET" in
  ''|*[!0-9]*)
    echo "ceiling-experiment: the entry of the day ($ENTRY) is not a number of tokens" >&2
    exit 1
    ;;
esac

echo "ceiling-experiment: today is $TODAY and the ladder says a ceiling of $TARGET tokens"
"$SCRIPT_DIR/ceiling.sh" set "$TARGET" "the ladder of the experiment moved the ceiling to $TARGET"
