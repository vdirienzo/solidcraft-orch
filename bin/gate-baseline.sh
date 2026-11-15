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

# The paths come from the environment, with the default of THIS
# machine: the other PC exports its own (see docs/portable-orchestrator.md).
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
for repo in "${GATE_REPO:-}" "${SOLIDCRAFT_REPO:-$HOME/solidcraft}"; do
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

# THE MATCH OF A FAILURE AGAINST THE CATALOGUE (2026-11-14).
#
# TWO FALSE REDS ARE FIXED HERE.
#
# 1. THE NAME IN THE CATALOGUE IS NOT ALWAYS THE NAME IN THE VERDICT.
#    The catalogue holds "solidcraft-cli::naming_corpus::corpus_designs_..."
#    and nextest reports the failure as "solidcraft-cli::corpus_designs_...":
#    the module in the middle of the path is not always there. The match
#    was EXACT (grep -qxF), so a failure that was already failing in
#    origin/main was counted as a NEW failure of the branch. NOW a
#    failure is preexisting when the catalogue holds an entry with the
#    SAME CRATE and the SAME LAST SEGMENT of the path. The crate is
#    compared WITHOUT its "solidcraft-" prefix on BOTH sides: the
#    catalogue of the upstream has the prefix stripped ("cli") and ours
#    has it ("solidcraft-cli"), and they are the same crate. The exact
#    match still counts too.
#
# 2. A FLAKY TEST IS NOT A REGRESSION. The gate runs nextest and, when
#    the run fails, it runs it AGAIN (without sccache): the FAILED_TESTS
#    of the raw verdict is the UNION of the failures of the two runs. A
#    test that failed in one run and PASSED in the other one is a flake
#    of the load, not a failure of the branch. NOW a failure that
#    appears as a PASS in the log of the SAME sha is not counted as a
#    new failure. The comparison is by the path AFTER the crate (the
#    crate of the log is the binary of nextest and the separator of the
#    two forms is not the same), never by the whole line.
#
# THE LOG IS THE ONE OF THE RUN THAT PRODUCED THE VERDICT: the newest
# file of the log directory whose name starts with "gate-quick-" and the
# first ten characters of the sha of the verdict.
SHA_RAW="$(grep -E '^SHA=' "$RAW" | head -1 | cut -d= -f2- | tr -d '[:space:]')"
SHA_PRE="$(printf '%s' "$SHA_RAW" | cut -c1-10)"
GATE_LOG=""
if [ -n "$SHA_PRE" ]; then
  GATE_LOG="$(ls -t "$LOOP_DIR"/logs/gate-quick-"$SHA_PRE"*.log 2>/dev/null | head -1)"
  [ -f "${GATE_LOG:-/nonexistent}" ] || GATE_LOG=""
fi

# THE PROGRAM OF THE MATCH (in a file of its own: the program is long and
# it is read with -f so that the shell does not have to quote it).
TMP_AWK="$(mktemp 2>/dev/null || echo "/tmp/gate-baseline.$$.awk")"
cat > "$TMP_AWK" <<'GATE_BASELINE_AWK'
function canon(c,   p) {
  p = index(c, "::")
  if (p > 0) c = substr(c, 1, p - 1)
  sub(/^solidcraft-/, "", c)
  return c
}
function last_seg(s,   p, k) {
  p = 0
  for (k = length(s) - 1; k >= 1; k--) if (substr(s, k, 2) == "::") { p = k; break }
  return (p > 0) ? substr(s, p + 2) : s
}
function crate_of(s,   p) {
  p = index(s, "::")
  return (p > 0) ? substr(s, 1, p - 1) : s
}
function name_of(s,   p) {
  p = index(s, "::")
  return (p > 0) ? substr(s, p + 2) : s
}
BEGIN {
  while ((getline line < catf) > 0) {
    if (line == "") continue
    exact[line] = 1
    catkey[canon(crate_of(line)) "\t" last_seg(line)] = 1
  }
  close(catf)
  n = 0
  while ((getline line < failf) > 0) {
    if (line == "") continue
    if (line in exact) continue
    if ((canon(line) "\t" last_seg(line)) in catkey) continue
    pending[++n] = line
  }
  close(failf)
  if (n > 0 && logf != "") {
    while ((getline line < logf) > 0) {
      gsub(/\033\[[0-9;]*[A-Za-z]/, "", line)
      sub(/\r$/, "", line)
      if (line !~ /^[ \t]*PASS[ \t]+\[/) continue
      rest = line
      sub(/^[ \t]*PASS[ \t]+\[[^]]*\][ \t]*/, "", rest)
      sub(/^\([ \t]*[0-9]+[ \t]*\/[ \t]*[0-9]+[ \t]*\)[ \t]*/, "", rest)
      sub(/^[ \t]+/, "", rest)
      sp = index(rest, " ")
      if (sp > 0) {
        b = substr(rest, 1, sp - 1)
        nm = substr(rest, sp + 1)
      } else {
        q = index(rest, "::")
        if (q == 0) continue
        b = substr(rest, 1, q - 1)
        nm = substr(rest, q + 2)
      }
      sub(/[ \t]+$/, "", nm)
      if (nm == "") continue
      passkey[canon(b) "\t" nm] = 1
    }
    close(logf)
  }
  out = ""
  m = 0
  for (i = 1; i <= n; i++) {
    if ((canon(pending[i]) "\t" name_of(pending[i])) in passkey) continue
    m++
    out = (m > 1) ? out "," pending[i] : pending[i]
  }
  print out
}
GATE_BASELINE_AWK

# The catalogue and the failures of the verdict, one per line.
TMP_CAT="$(mktemp 2>/dev/null || echo "/tmp/gate-baseline.$$.cat")"
TMP_FAIL="$(mktemp 2>/dev/null || echo "/tmp/gate-baseline.$$.fail")"
printf '%s\n' "$BASE_N" | grep -v '^$' > "$TMP_CAT"
printf '%s\n' "$FAILED" | grep -v '^$' > "$TMP_FAIL"

REAL_NEW="$(awk -v catf="$TMP_CAT" -v failf="$TMP_FAIL" -v logf="$GATE_LOG" -f "$TMP_AWK" 2>/dev/null)"

rm -f "$TMP_AWK" "$TMP_CAT" "$TMP_FAIL" 2>/dev/null || true

COUNT=0
[ -n "$REAL_NEW" ] && COUNT="$(printf '%s\n' "$REAL_NEW" | tr ',' '\n' | grep -c .)"

# HOW MANY OF THE FAILURES OF THE RAW VERDICT HAVE A NAME (2026-11-07).
#
# The NEW_FAILURES of the raw verdict is the sum of two things: the new
# FAILING TESTS (which have a name and are the ones listed in FAILED_TESTS)
# and the PROBLEMS of the phases (a fmt that fails, a clippy that fails, a
# check that fails, a test run that could not be judged). A PROBLEM HAS NO
# NAME: it is not in FAILED_TESTS and it can not be looked up in the
# catalogue of the failures of origin/main, which only has names.
#
# WHY IT MATTERS: the discount used to be "COUNT == 0 means every failure
# was preexisting", and with a failure WITHOUT a name COUNT is 0 while the
# raw verdict says NEW_FAILURES=1: the slot 6738 (fmt:fail) came out
# VERDE-SCOPE with NEW_FAILURES=0, a GREEN that the branch never earned. A
# failure without a name is a failure OF THE BRANCH and it is not
# discounted.
NAMED_N=0
[ -n "$FAILED" ] && NAMED_N="$(printf '%s\n' "$FAILED" | grep -c .)"
UNNAMED=$(( NEW_N - NAMED_N ))
[ "$UNNAMED" -lt 0 ] && UNNAMED=0
# The failures of the branch: the named ones that are not in the catalogue
# plus the ones without a name.
NEW_EFFECTIVE=$(( COUNT + UNNAMED ))
# The failures that were ALREADY failing in origin/main: the named ones that
# ARE in the catalogue. The unnamed ones are not counted here: nobody knows
# that they were failing before.
PREEXISTING=$(( NAMED_N - COUNT ))

VERDICT="$(grep -E '^VERDICT=' "$RAW" | head -1 | cut -d= -f2- | tr -d '[:space:]')"

# A DEFERRED SCOPE IS NOT A VERDICT (2026-11-07).
#
# The gate says it out loud when it postpones a scope: "the scope was
# deferred (nextest-timeout): it is not a verdict". There is nothing to
# discount and nothing to publish, so the effective verdict of a deferred
# slot is NOT written. The one of a previous run IS removed: it is the
# verdict of ANOTHER commit and reading it as the verdict of this one is
# exactly the bug this script exists to avoid.
DEFERRED="$(grep -E '^DEFERRED=' "$RAW" | head -1 | cut -d= -f2- | tr -d '[:space:]')"
if [ -n "$DEFERRED" ] || [ "$VERDICT" = "SKIP" ]; then
  rm -f "$EFF" 2>/dev/null || true
  echo "gate-baseline: el scope del slot $SLOT quedo diferido (${DEFERRED:-sin motivo}): no hay veredicto efectivo" >&2
  exit 0
fi

if [ -z "$VERDICT" ]; then
  echo "gate-baseline: el veredicto crudo del slot $SLOT no dice VERDICT: no se calcula el efectivo" >&2
  exit 1
fi

# A ROJO whose failures are ALL preexisting is not a red of the branch. But
# only if there is not ONE failure of the branch: the unnamed ones count
# too, so the brake is not loosened.
if [ "$VERDICT" != "VERDE-SCOPE" ] && [ "$NEW_EFFECTIVE" -eq 0 ] && [ "$NEW_N" -gt 0 ]; then
  VERDICT="VERDE-SCOPE"
fi

# The file is written and THEN moved: a reader (the pipeline, the report)
# never sees a half-written verdict.
{
  echo "GATE_STATUS=$(grep -E '^GATE_STATUS=' "$RAW" | head -1 | cut -d= -f2-)"
  echo "VERDICT=$VERDICT"
  echo "NEW_FAILURES=$NEW_EFFECTIVE"
  echo "PREEXISTING_FAILURES=$PREEXISTING"
  echo "FAILED_TESTS=$REAL_NEW"
  echo "SHA=$(grep -E '^SHA=' "$RAW" | head -1 | cut -d= -f2-)"
  echo "AT=$(date +%s)"
  echo "BASE=baseline/failures-origin-main.txt"
} > "$EFF.tmp" 2>/dev/null && mv -f "$EFF.tmp" "$EFF" 2>/dev/null || {
  rm -f "$EFF.tmp" 2>/dev/null || true
  echo "gate-baseline: el veredicto efectivo no se pudo escribir: $EFF" >&2
  exit 1
}

if [ "${2:-}" = "--show" ]; then
  cat "$EFF"
else
  printf 'slot=%s verdict=%s new_failures=%s preexisting=%s\n' \
    "$SLOT" "$VERDICT" "$NEW_EFFECTIVE" "$PREEXISTING"
fi
exit 0
