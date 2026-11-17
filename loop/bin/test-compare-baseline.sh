#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The test of the comparison against the baseline of the spend.
#
#   bin/test-compare-baseline.sh
#
# It checks the four verdicts of bin/compare-baseline.py:
#   1. a day inside the objective that published something is OK;
#   2. a day outside the objective is not OK;
#   3. a day inside the objective that published NOTHING is not OK: a day
#      that spends less because it delivered less is not a success;
#   4. a day the counter did not see is not OK.
#
# The spend comes from a FAKE counter (the real one reads the database of
# OpenCode, and a test must not depend on the spend of the machine) and the
# work comes from a synthetic ledger. The copy of the loop directory is what
# is tested, the real one is never touched.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$SCRIPT_DIR/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/loop-baseline.XXXXXX")"
FAILED=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=1; }
check() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$1', got '$2')"; fi; }

mkdir -p "$WORK/loop/logs" "$WORK/loop/reports" "$WORK/bin"

# --- the fake counter ------------------------------------------------------
# It answers like bin/oc-tokens --json: a day of spend per day.
cat > "$WORK/bin/oc-tokens" <<'COUNTER'
#!/usr/bin/env python3
import json

days = {
    "2026-10-20": {"tokens": 100000000, "cost": 2.0, "input": 5000000,
                   "cache_read": 94000000, "output": 1000000, "steps": 100},
    "2026-10-21": {"tokens": 900000000, "cost": 18.0, "input": 20000000,
                   "cache_read": 870000000, "output": 10000000, "steps": 900},
    "2026-10-22": {"tokens": 100000000, "cost": 2.0, "input": 5000000,
                   "cache_read": 94000000, "output": 1000000, "steps": 100},
}
print(json.dumps({"by_day": days}))
COUNTER
chmod +x "$WORK/bin/oc-tokens"

# --- the synthetic ledger --------------------------------------------------
# The 20th published one pull request in two turns (the state stays in the
# phase 'published'), the 21st published one too, and the 22nd published
# nothing (the loop was blocked).
cat > "$WORK/loop/ledger.md" <<'LEDGER'
# Bitácora del loop de SolidCraft

| 2026-10-20T03:10Z | 100 | claimed | en curso | issue 100 · pr #9001 |
| 2026-10-20T04:10Z | 100 | published | ok | issue 100 · pr #9001 · fase published |
| 2026-10-20T05:10Z | 100 | published | ok | issue 100 · pr #9001 · fase published |
| 2026-10-21T03:10Z | 101 | claimed | en curso | issue 101 · pr #9002 |
| 2026-10-21T04:10Z | 101 | published | ok | issue 101 · pr #9002 · fase published |
| 2026-10-22T03:10Z | 102 | claimed | en curso | issue 102 · pr #9003 |
| 2026-10-22T04:10Z | 102 | gating | en curso | issue 102 · pr #9003 · fase gating |
| 2026-10-22T05:10Z | 102 | failed | rojo | issue 102 · fase implemented · pr #9003 |
LEDGER

run_compare() {
  python3 "$REPO/bin/compare-baseline.py" \
    --counter "$WORK/bin/oc-tokens" \
    --loop-dir "$WORK/loop" \
    --baseline "$REPO/metrics-baseline.md" \
    --day "$1" > "$WORK/out.md" 2> "$WORK/out.err"
  echo $?
}

echo "=== the test of the comparison against the baseline ($WORK) ==="

echo "--- 1. a day inside the objective that published something ---"
rc="$(run_compare 2026-10-20)"
check "$rc" "0" "the comparison succeeds"
grep -q "| 2026-10-20 | 100.0 M | 2.00 \$ |" "$WORK/out.md" \
  && pass "the row of the day has its spend" \
  || fail "the row of the day does not have its spend"
grep -q "| 2026-10-20 |.*| 3 | 1 | OK |" "$WORK/out.md" \
  && pass "the row counts 3 turns and 1 pull request (the same PR in two turns is one)" \
  || fail "the row does not count the turns and the pull requests well"

echo "--- 2. a day outside the objective ---"
rc="$(run_compare 2026-10-21)"
check "$rc" "1" "the comparison fails"
grep -q "| 2026-10-21 |.*| FUERA |" "$WORK/out.md" \
  && pass "the verdict says that the spend is outside the objective" \
  || fail "the verdict does not say that the spend is outside the objective"
grep -q "the spend is outside the objective" "$WORK/loop/logs/"*.err \
  && pass "the warning is in the log of the supervisor" \
  || fail "the warning is not in the log of the supervisor"

echo "--- 3. a day inside the objective that published nothing ---"
rc="$(run_compare 2026-10-22)"
check "$rc" "1" "the comparison fails"
grep -q "| 2026-10-22 |.*| SIN PRs |" "$WORK/out.md" \
  && pass "the verdict says that the day published nothing" \
  || fail "the verdict does not say that the day published nothing"

echo "--- 4. a day the counter did not see ---"
rc="$(run_compare 2026-10-23)"
check "$rc" "1" "the comparison fails"
grep -q "| 2026-10-23 |.*| SIN DATOS |" "$WORK/out.md" \
  && pass "the verdict says that there are no data of that day" \
  || fail "the verdict does not say that there are no data of that day"

echo "--- 5. the report is written ---"
[ -f "$WORK/loop/reports/baseline-2026-10-20.md" ] \
  && pass "the report of the day is written" \
  || fail "the report of the day is not written"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "=== everything passed ==="
  exit 0
fi
echo "=== there are checks that failed ==="
exit 1
