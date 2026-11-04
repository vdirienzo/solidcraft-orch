#!/usr/bin/env bash
# ------------------------------------------------------------------
# gate-baseline.sh - the EFFECTIVE verdict of a slot: the raw verdict of
# the gate minus the failures that were already failing in origin/main.
#
# WHY THIS EXISTS (2026-11-03): upstream merged the SMLib v1.1.0-alpha
# kernel migration (#11351, ea772a043 / 147b4049c) and left 26 tests of
# the workspace broken in main: 16 of the kernel (blend_corner,
# corner_g2, issue_851, smooth_edges, blend_smlib), 9 of the engine and
# 1 of the cli. Verified in a clean worktree of origin/main: all 26 fail
# there with the SAME message, byte for byte.
#
# The gate counts every failure of its scope as NEW_FAILURES, so every
# pull request of ours is ROJO for reasons that have nothing to do with
# the change, and nothing can be published while upstream is broken.
# The baseline (baseline/failures-origin-main.txt) holds that list, and
# this script subtracts it.
#
# It never touches the raw verdict: the gate-quick.sh verdict stays as
# it is, and the effective one is written next to it. The raw verdict is
# what the gate said; the effective one is what the branch did.
#
# USAGE:
#   bash gate-baseline.sh <slot>       -> writes the effective verdict
#   bash gate-baseline.sh <slot> --show -> prints it
# ------------------------------------------------------------------
set -uo pipefail

SLOT="${1:-}"
[ -z "$SLOT" ] && { echo "usage: gate-baseline.sh <slot> [--show]" >&2; exit 2; }

ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
RAW="$LOOP_DIR/gates/$SLOT/scope.verdict"
BASE="$ORCH_DIR/baseline/failures-origin-main.txt"
EFF="$LOOP_DIR/gates/$SLOT/scope.effective.verdict"

[ -f "$RAW" ] || { echo "gate-baseline: no verdict for the slot $SLOT" >&2; exit 1; }

# The failures of the raw verdict.
FAILED="$(grep -E '^FAILED_TESTS=' "$RAW" | head -1 | cut -d= -f2- | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$')"
NEW_N="$(grep -E '^NEW_FAILURES=' "$RAW" | head -1 | cut -d= -f2 | tr -d '[:space:]')"
case "$NEW_N" in ''|*[!0-9]*) NEW_N=0 ;; esac

# The failures that were already there in origin/main. TWO sources:
#   1. the upstream's own catalogue, tests/KNOWN_FAILING_TESTS: the tests that
#      fail today in main, with the reason, maintained by them and refreshed
#      with every merge. Their names carry the crate ("solidcraft-engine::...")
#      and nextest reports them without it ("engine::...").
#   2. the baseline we measured ourselves, for the failures the upstream
#      catalogue does not have (it is refreshed by hand, not by every merge).
BASE_N=""
if [ -f "$BASE" ]; then
  BASE_N="$(grep -vE '^[[:space:]]*(#|$)' "$BASE" | sort -u)"
fi
# The temporary file has a FIXED name: "$BASE_N.tmp" was a path with the whole
# list of failures inside it (a multiline name), so the append failed and the
# catalogue was never joined: nothing was discounted at all.
TMP_LIST="$(mktemp 2>/dev/null || echo "/tmp/gate-baseline.$$.tmp")"
: > "$TMP_LIST" 2>/dev/null || true
# The catalogue of the failures that were already failing in the BASE. There
# is no single fresh copy: the ref of origin/main can be behind the checkout
# principal (which is only reset by hand) and the worktree of the slot can be
# hundreds of commits behind. So ALL of them are joined, and a catalogue that
# is behind only misses failures: the effective verdict came out ROJO with
# one FALSE failure because of exactly that.
#   1. the file the caller points at (KNOWN_FAILING_TESTS)
#   2. origin/main, through the ref shared by every worktree
#   3. the checkout principal
#   4. the worktree of the slot
KNOWN_LIST=""
TMP_KNOWN="$(mktemp 2>/dev/null || echo "/tmp/kft.$$")"
: > "$TMP_KNOWN" 2>/dev/null || true
for known in "${KNOWN_FAILING_TESTS:-}"; do
  [ -n "$known" ] && [ -f "$known" ] && grep -vE '^[[:space:]]*(#|$)' "$known" 2>/dev/null >> "$TMP_KNOWN"
done
for repo in "${GATE_REPO:-}" "$HOME/solidcraft"; do
  [ -n "$repo" ] && [ -d "$repo" ] || continue
  git -C "$repo" show origin/main:tests/KNOWN_FAILING_TESTS 2>/dev/null >> "$TMP_KNOWN"
  [ -f "$repo/tests/KNOWN_FAILING_TESTS" ] && grep -vE '^[[:space:]]*(#|$)' "$repo/tests/KNOWN_FAILING_TESTS" 2>/dev/null >> "$TMP_KNOWN"
done
awk '{print $1}' "$TMP_KNOWN" | sed 's/^solidcraft-//' | grep -v '^$' | sort -u > "$TMP_LIST"

# THE LIST IS ONLY USEFUL IF IT IS JOINED: this block was lost while the
# sources were being joined, and the catalogue was built and never read:
# the failures that the upstream catalogues came out as NEW failures.
if [ -s "$TMP_LIST" ]; then
  BASE_N="$(printf '%s\n%s\n' "$BASE_N" "$(cat "$TMP_LIST")" | grep -v '^$' | sort -u)"
fi
rm -f "$TMP_LIST" "$TMP_KNOWN" 2>/dev/null || true

REAL_NEW=""
for t in $FAILED; do
  if ! printf '%s\n' "$BASE_N" | grep -qxF "$t"; then
    REAL_NEW="${REAL_NEW:+$REAL_NEW,}$t"
  fi
done

COUNT=0
[ -n "$REAL_NEW" ] && COUNT="$(printf '%s\n' "$REAL_NEW" | tr ',' '\n' | grep -c .)"

VERDICT="$(grep -E '^VERDICT=' "$RAW" | head -1 | cut -d= -f2-)"
# A ROJO whose failures are all preexisting is not a red of the branch.
if [ "$VERDICT" != "VERDE-SCOPE" ] && [ "$COUNT" -eq 0 ] && [ "$NEW_N" -gt 0 ]; then
  VERDICT="VERDE-SCOPE"
fi

{
  echo "GATE_STATUS=$(grep -E '^GATE_STATUS=' "$RAW" | head -1 | cut -d= -f2-)"
  echo "VERDICT=$VERDICT"
  echo "NEW_FAILURES=$COUNT"
  echo "PREEXISTING_FAILURES=$(( NEW_N - COUNT ))"
  echo "FAILED_TESTS=$REAL_NEW"
  echo "SHA=$(grep -E '^SHA=' "$RAW" | head -1 | cut -d= -f2-)"
  echo "AT=$(date +%s)"
  echo "BASE=baseline/failures-origin-main.txt"
} > "$EFF"

if [ "${2:-}" = "--show" ]; then
  cat "$EFF"
else
  printf 'slot=%s verdict=%s new_failures=%s preexisting=%s\n' \
    "$SLOT" "$VERDICT" "$COUNT" "$(( NEW_N - COUNT ))"
fi
exit 0
