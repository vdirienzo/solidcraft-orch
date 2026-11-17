#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Test bank of merge-verdict.sh. It touches no network: the gh of the PATH is
# a stub that answers the two API calls of the script with a fixed JSON.
#
#   bash bin/test-merge-verdict.sh
#
# The cases:
#   1. the cheap lane is green       -> VERDE
#   2. a job is still running        -> PENDIENTE
#   3. a job failed                  -> ROJO (the job is listed)
#   4. there are no check runs       -> PENDIENTE
#   5. the head is not the commit    -> STALE
#   6. gh is not available           -> PENDIENTE (the script tolerates it)
#   7. the help does nothing         -> the usage
#   8. the lane is run twice         -> VERDE (the newest run of each name)
#   9. the oldest run of the lane was running -> VERDE (the newest is green)
#  10. the oldest run of the lane failed     -> VERDE (the newest is green)
#  11. the newest run of the lane failed     -> ROJO
#  12. the newest run of the lane runs       -> PENDIENTE
#  13. two runs of the same name with the same started_at -> deterministic
#  14. two runs of the same name, the newest finished last -> ROJO
#  15. the expected sha is the short prefix of the head -> not STALE
#  16. the expected sha is the short prefix of another commit -> STALE
#  17. the second page of the check runs fails -> ROJO (the call paginates)
#  18. the pages come as an array -> ROJO (the call paginates)
#  19. the response is not JSON       -> PENDIENTE (it fails safe)
#  20. gh fails on the check runs     -> PENDIENTE (it fails safe)
#  21. gh fails on the head of the PR -> PENDIENTE (it fails safe)
#
# The exit code is 1 when a case fails.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_VERDICT="${MERGE_VERDICT:-$SCRIPT_DIR/merge-verdict.sh}"

if [ ! -f "$MERGE_VERDICT" ]; then
  echo "FALLO - merge-verdict.sh is not found: $MERGE_VERDICT"
  exit 1
fi

TMP_TEST="$(mktemp -d "${TMPDIR:-/tmp}/test-merge-verdict.XXXXXX" 2>/dev/null)" || {
  echo "FALLO - a temporary directory cannot be created"
  exit 1
}
cleanup() { rm -rf "$TMP_TEST"; }
trap cleanup EXIT

LOOP_TEST="$TMP_TEST/loop"
STUB_DIR="$TMP_TEST/bin"
ARGS_LOG="$TMP_TEST/gh-args.log"
mkdir -p "$LOOP_TEST" "$STUB_DIR"

# --- the stub of gh -------------------------------------------------------
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# A fake gh: it answers the API calls of merge-verdict.sh with a fixed JSON.
#
# It can serve TWO pages of check runs (STUB_CHECK_RUNS and
# STUB_CHECK_RUNS_PAGE2) in the two shapes that `gh api --paginate` uses:
# the pages concatenated (the shape of an object endpoint) or an array of
# pages (the shape of --slurp). It records its arguments in STUB_ARGS_LOG,
# so the tests can see that the call was paginated.
set -uo pipefail
if [ -n "${STUB_ARGS_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$STUB_ARGS_LOG"
fi
case "$*" in
  *check-runs*)
    if [ "${STUB_CHECKS_FAIL:-}" = "1" ]; then
      echo "gh: the network is not there" >&2
      exit 1
    fi
    page1='{"total_count":0,"check_runs":[]}'
    if [ -n "${STUB_CHECK_RUNS:-}" ] && [ -f "${STUB_CHECK_RUNS}" ]; then
      page1="$(cat "${STUB_CHECK_RUNS}")"
    fi
    page2=""
    if [ -n "${STUB_CHECK_RUNS_PAGE2:-}" ] && [ -f "${STUB_CHECK_RUNS_PAGE2}" ]; then
      page2="$(cat "${STUB_CHECK_RUNS_PAGE2}")"
    fi
    if [ -z "$page2" ]; then
      printf '%s\n' "$page1"
    elif [ "${STUB_SHAPE:-}" = "array" ]; then
      printf '[%s,%s]\n' "$page1" "$page2"
    else
      printf '%s%s\n' "$page1" "$page2"
    fi
    exit 0
    ;;
  */pulls/*)
    if [ "${STUB_GH_FAIL:-}" = "1" ]; then
      echo "gh: the network is not there" >&2
      exit 1
    fi
    printf '%s\n' "${STUB_PR_SHA:-0000000000000000000000000000000000000000}"
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# --- the fixtures of the check runs ---------------------------------------
cat > "$TMP_TEST/green.json" <<'JSON'
{
  "total_count": 5,
  "check_runs": [
    {"name": "Quick compile", "status": "completed", "conclusion": "success"},
    {"name": "Format and repository checks", "status": "completed", "conclusion": "success"},
    {"name": "Select checks", "status": "completed", "conclusion": "success"},
    {"name": "Native Linux Clippy", "status": "completed", "conclusion": "skipped"},
    {"name": "Native Linux tests", "status": "completed", "conclusion": "skipped"}
  ]
}
JSON

cat > "$TMP_TEST/pending.json" <<'JSON'
{
  "total_count": 3,
  "check_runs": [
    {"name": "Quick compile", "status": "in_progress", "conclusion": null},
    {"name": "Format and repository checks", "status": "completed", "conclusion": "success"},
    {"name": "Select checks", "status": "completed", "conclusion": "success"}
  ]
}
JSON

cat > "$TMP_TEST/red.json" <<'JSON'
{
  "total_count": 3,
  "check_runs": [
    {"name": "Quick compile", "status": "completed", "conclusion": "success"},
    {"name": "Format and repository checks", "status": "completed", "conclusion": "failure"},
    {"name": "Select checks", "status": "completed", "conclusion": "success"}
  ]
}
JSON

cat > "$TMP_TEST/empty.json" <<'JSON'
{"total_count": 0, "check_runs": []}
JSON

# The lane run twice: the OLD `Select checks` was skipped at 13:52 and the NEW
# one succeeded at 14:19. Measured on the real repository (26-10-2026).
cat > "$TMP_TEST/dup_skipped_then_success.json" <<'JSON'
{
  "total_count": 4,
  "check_runs": [
    {"name": "Quick compile", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:20:09Z", "completed_at": "2026-10-26T14:21:00Z"},
    {"name": "Format and repository checks", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:20:10Z", "completed_at": "2026-10-26T14:21:05Z"},
    {"name": "Select checks", "status": "completed", "conclusion": "skipped",
     "started_at": "2026-10-26T13:52:32Z", "completed_at": "2026-10-26T13:52:40Z"},
    {"name": "Select checks", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:19:44Z", "completed_at": "2026-10-26T14:20:00Z"}
  ]
}
JSON

# The lane run twice: the OLD `Select checks` was still running and the NEW
# one succeeded. The old run must not hide the new one.
cat > "$TMP_TEST/dup_running_then_success.json" <<'JSON'
{
  "total_count": 4,
  "check_runs": [
    {"name": "Quick compile", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:20:09Z", "completed_at": "2026-10-26T14:21:00Z"},
    {"name": "Format and repository checks", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:20:10Z", "completed_at": "2026-10-26T14:21:05Z"},
    {"name": "Select checks", "status": "in_progress", "conclusion": null,
     "started_at": "2026-10-26T13:50:00Z", "completed_at": null},
    {"name": "Select checks", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:19:44Z", "completed_at": "2026-10-26T14:20:00Z"}
  ]
}
JSON

# The lane run twice: the OLD `Select checks` failed and the NEW one
# succeeded. The old failure must not hide the new one.
cat > "$TMP_TEST/dup_failure_then_success.json" <<'JSON'
{
  "total_count": 4,
  "check_runs": [
    {"name": "Quick compile", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:20:09Z", "completed_at": "2026-10-26T14:21:00Z"},
    {"name": "Format and repository checks", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:20:10Z", "completed_at": "2026-10-26T14:21:05Z"},
    {"name": "Select checks", "status": "completed", "conclusion": "failure",
     "started_at": "2026-10-26T13:50:00Z", "completed_at": "2026-10-26T13:52:40Z"},
    {"name": "Select checks", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:19:44Z", "completed_at": "2026-10-26T14:20:00Z"}
  ]
}
JSON

# The lane run twice: the NEW `Quick compile` failed.
cat > "$TMP_TEST/dup_success_then_failure.json" <<'JSON'
{
  "total_count": 4,
  "check_runs": [
    {"name": "Quick compile", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:20:09Z", "completed_at": "2026-10-26T14:21:00Z"},
    {"name": "Quick compile", "status": "completed", "conclusion": "failure",
     "started_at": "2026-10-26T14:25:09Z", "completed_at": "2026-10-26T14:26:00Z"},
    {"name": "Format and repository checks", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:20:10Z", "completed_at": "2026-10-26T14:21:05Z"},
    {"name": "Select checks", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:19:44Z", "completed_at": "2026-10-26T14:20:00Z"}
  ]
}
JSON

# The lane run twice: the NEW `Select checks` is still running.
cat > "$TMP_TEST/dup_success_then_running.json" <<'JSON'
{
  "total_count": 4,
  "check_runs": [
    {"name": "Quick compile", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:20:09Z", "completed_at": "2026-10-26T14:21:00Z"},
    {"name": "Format and repository checks", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:20:10Z", "completed_at": "2026-10-26T14:21:05Z"},
    {"name": "Select checks", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:19:44Z", "completed_at": "2026-10-26T14:20:00Z"},
    {"name": "Select checks", "status": "in_progress", "conclusion": null,
     "started_at": "2026-10-26T14:26:00Z", "completed_at": null}
  ]
}
JSON

# Two runs of the same name with the SAME started_at and the same
# completed_at: the position in the response breaks the tie. The API returns
# the runs from the newest to the oldest, so the FIRST one wins.
cat > "$TMP_TEST/dup_tie.json" <<'JSON'
{
  "total_count": 2,
  "check_runs": [
    {"name": "Select checks", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:19:44Z", "completed_at": "2026-10-26T14:20:00Z"},
    {"name": "Select checks", "status": "completed", "conclusion": "failure",
     "started_at": "2026-10-26T14:19:44Z", "completed_at": "2026-10-26T14:20:00Z"}
  ]
}
JSON

# Two runs of the same name with the same started_at: the one that finished
# last is the newer one.
cat > "$TMP_TEST/dup_same_start.json" <<'JSON'
{
  "total_count": 2,
  "check_runs": [
    {"name": "Select checks", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:19:44Z", "completed_at": "2026-10-26T14:20:00Z"},
    {"name": "Select checks", "status": "completed", "conclusion": "failure",
     "started_at": "2026-10-26T14:19:44Z", "completed_at": "2026-10-26T14:20:30Z"}
  ]
}
JSON

# The first page of the check runs: the lane is green so far.
cat > "$TMP_TEST/page1.json" <<'JSON'
{
  "total_count": 3,
  "check_runs": [
    {"name": "Quick compile", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:20:09Z", "completed_at": "2026-10-26T14:21:00Z"},
    {"name": "Format and repository checks", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-26T14:20:10Z", "completed_at": "2026-10-26T14:21:05Z"}
  ]
}
JSON

# The second page: the lane job that failed is here.
cat > "$TMP_TEST/page2.json" <<'JSON'
{
  "total_count": 3,
  "check_runs": [
    {"name": "Select checks", "status": "completed", "conclusion": "failure",
     "started_at": "2026-10-26T14:19:44Z", "completed_at": "2026-10-26T14:20:00Z"}
  ]
}
JSON

# A response that is not JSON at all.
printf 'this is not JSON\n' > "$TMP_TEST/broken.json"

# --- the runner of a case -------------------------------------------------
FAILURES=0
SHA_PR="1111111111111111111111111111111111111111"

field() {
  sed -n "s/^$1=//p" "$LOOP_TEST/merge.verdict" 2>/dev/null | head -1
}

run_merge() {
  # run_merge [expected sha] ; the fixture is in STUB_CHECK_RUNS
  rm -f "$LOOP_TEST/merge.verdict" "$ARGS_LOG"
  LOOP_DIR="$LOOP_TEST" \
  UPSTREAM="tangency-labs/solidcraft" \
  GH_BIN="${GH_BIN:-}" \
  STUB_PR_SHA="$SHA_PR" \
  STUB_CHECK_RUNS="${STUB_CHECK_RUNS:-}" \
  STUB_CHECK_RUNS_PAGE2="${STUB_CHECK_RUNS_PAGE2:-}" \
  STUB_SHAPE="${STUB_SHAPE:-}" \
  STUB_GH_FAIL="${STUB_GH_FAIL:-}" \
  STUB_CHECKS_FAIL="${STUB_CHECKS_FAIL:-}" \
  STUB_ARGS_LOG="$ARGS_LOG" \
  PATH="$STUB_DIR:$PATH" \
    bash "$MERGE_VERDICT" 4242 "$@" >"$TMP_TEST/out.txt" 2>"$TMP_TEST/err.txt"
  MERGE_RC=$?
}

check_case() {
  # check_case <label> <want verdict> <want jobs> [want sha]
  local label="$1" want_verdict="$2" want_jobs="$3" want_sha="${4:-$SHA_PR}"
  local got_verdict got_jobs got_sha got_pr
  got_verdict="$(field MERGE_VERDICT)"
  got_jobs="$(field MERGE_JOBS)"
  got_sha="$(field MERGE_SHA)"
  got_pr="$(field MERGE_PR)"
  if [ "$MERGE_RC" -ne 0 ]; then
    echo "FALLO - $label: merge-verdict.sh exited with $MERGE_RC"
    sed 's/^/    /' "$TMP_TEST/err.txt" | head -5
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [ "$got_verdict" = "$want_verdict" ] && [ "$got_jobs" = "$want_jobs" ] \
     && [ "$got_sha" = "$want_sha" ] && [ "$got_pr" = "4242" ]; then
    echo "ok   - $label: MERGE_VERDICT=$got_verdict MERGE_JOBS=$got_jobs"
  else
    echo "FALLO - $label: MERGE_VERDICT=$got_verdict MERGE_JOBS=$got_jobs"
    echo "         MERGE_SHA=$got_sha MERGE_PR=$got_pr"
    echo "         wanted: MERGE_VERDICT=$want_verdict MERGE_JOBS=$want_jobs"
    echo "                  MERGE_SHA=$want_sha MERGE_PR=4242"
    FAILURES=$((FAILURES + 1))
  fi
}

check_paginated() {
  # check_paginated <label> : the call of gh must have been paginated
  local label="$1"
  if grep -q -- "--paginate" "$ARGS_LOG" 2>/dev/null; then
    echo "ok   - $label: la llamada de gh fue paginada"
  else
    echo "FALLO - $label: la llamada de gh NO fue paginada"
    sed 's/^/    /' "$ARGS_LOG" 2>/dev/null | head -5
    FAILURES=$((FAILURES + 1))
  fi
}

# --- the cases ------------------------------------------------------------
# 1. the cheap lane is green
STUB_CHECK_RUNS="$TMP_TEST/green.json"
run_merge
check_case "caso 1 (the lane is green)" VERDE \
  "Quick compile,Format and repository checks,Select checks"

# 2. a job is still running
STUB_CHECK_RUNS="$TMP_TEST/pending.json"
run_merge
check_case "caso 2 (a job is running)" PENDIENTE "Quick compile"

# 3. a job failed
STUB_CHECK_RUNS="$TMP_TEST/red.json"
run_merge
check_case "caso 3 (a job failed)" ROJO "Format and repository checks"

# 4. there are no check runs for that commit
STUB_CHECK_RUNS="$TMP_TEST/empty.json"
run_merge
check_case "caso 4 (no check runs)" PENDIENTE ""

# 5. the head of the PR is not the commit that was expected
STUB_CHECK_RUNS="$TMP_TEST/green.json"
run_merge "2222222222222222222222222222222222222222"
check_case "caso 5 (another commit)" STALE \
  "Quick compile,Format and repository checks,Select checks"

# 6. gh is not available: the signal is PENDIENTE and the script exits 0
GH_BIN="$TMP_TEST/no-such-gh"
run_merge
GH_BIN=""
check_case "caso 6 (gh is not available)" PENDIENTE "" "unknown"

# 7. the help does nothing
if bash "$MERGE_VERDICT" --help >"$TMP_TEST/help.txt" 2>&1; then
  if grep -q "usage: merge-verdict.sh" "$TMP_TEST/help.txt"; then
    echo "ok   - caso 7 (--help)"
  else
    echo "FALLO - caso 7 (--help): the usage is not printed"
    FAILURES=$((FAILURES + 1))
  fi
else
  echo "FALLO - caso 7 (--help): merge-verdict.sh exited with $?"
  FAILURES=$((FAILURES + 1))
fi

# 8. the lane ran twice: the OLD run was skipped and the NEW one succeeded
STUB_CHECK_RUNS="$TMP_TEST/dup_skipped_then_success.json"
run_merge
check_case "caso 8 (the lane ran twice: the newest is green)" VERDE \
  "Quick compile,Format and repository checks,Select checks"

# 9. the lane ran twice: the OLD run was still running and the NEW one
#    succeeded. The old run must not hide the new one.
STUB_CHECK_RUNS="$TMP_TEST/dup_running_then_success.json"
run_merge
check_case "caso 9 (the lane ran twice: the old run was running)" VERDE \
  "Quick compile,Format and repository checks,Select checks"

# 10. the lane ran twice: the OLD run failed and the NEW one succeeded. The
#     old failure must not hide the new one.
STUB_CHECK_RUNS="$TMP_TEST/dup_failure_then_success.json"
run_merge
check_case "caso 10 (the lane ran twice: the old run failed)" VERDE \
  "Quick compile,Format and repository checks,Select checks"

# 11. the lane ran twice: the NEW run failed
STUB_CHECK_RUNS="$TMP_TEST/dup_success_then_failure.json"
run_merge
check_case "caso 11 (the lane ran twice: the newest failed)" ROJO "Quick compile"

# 12. the lane ran twice: the NEW run is still running
STUB_CHECK_RUNS="$TMP_TEST/dup_success_then_running.json"
run_merge
check_case "caso 12 (the lane ran twice: the newest is running)" PENDIENTE \
  "Select checks"

# 13. two runs of the same name with the same moments: the position in the
#     response breaks the tie (the first one wins: the API returns the runs
#     from the newest to the oldest)
STUB_CHECK_RUNS="$TMP_TEST/dup_tie.json"
run_merge
check_case "caso 13 (the same started_at: the tie is broken)" VERDE \
  "Select checks"

# 14. two runs of the same name with the same started_at: the one that
#     finished last is the newer one
STUB_CHECK_RUNS="$TMP_TEST/dup_same_start.json"
run_merge
check_case "caso 14 (the same started_at: the last one that finished)" ROJO \
  "Select checks"

# 15. the expected sha is the short prefix of the head: it is the same commit
STUB_CHECK_RUNS="$TMP_TEST/green.json"
run_merge "${SHA_PR:0:7}"
check_case "caso 15 (the short expected sha of the head)" VERDE \
  "Quick compile,Format and repository checks,Select checks"

# 16. the expected sha is the short prefix of another commit
STUB_CHECK_RUNS="$TMP_TEST/green.json"
run_merge "2222222"
check_case "caso 16 (the short expected sha of another commit)" STALE \
  "Quick compile,Format and repository checks,Select checks"

# 17. the lane job that fails is in the SECOND page of the check runs
STUB_CHECK_RUNS="$TMP_TEST/page1.json"
STUB_CHECK_RUNS_PAGE2="$TMP_TEST/page2.json"
run_merge
check_case "caso 17 (the failing job is in the second page)" ROJO \
  "Select checks"
check_paginated "caso 17 (the second page)"

# 18. the same, with the pages as an array (the shape of --slurp)
STUB_CHECK_RUNS_PAGE2="$TMP_TEST/page2.json"
STUB_SHAPE="array"
run_merge
check_case "caso 18 (the pages come as an array)" ROJO "Select checks"
check_paginated "caso 18 (the pages as an array)"
STUB_SHAPE=""
STUB_CHECK_RUNS_PAGE2=""

# 19. the response is not JSON: the signal is PENDIENTE, never a false VERDE
STUB_CHECK_RUNS="$TMP_TEST/broken.json"
run_merge
check_case "caso 19 (the response is not JSON)" PENDIENTE ""

# 20. gh fails on the check runs: the signal is PENDIENTE and the script
#     exits 0
STUB_CHECK_RUNS="$TMP_TEST/green.json"
STUB_CHECKS_FAIL="1"
run_merge
STUB_CHECKS_FAIL=""
check_case "caso 20 (gh fails on the check runs)" PENDIENTE ""

# 21. gh fails on the head of the PR: the signal is PENDIENTE and the sha is
#     unknown
STUB_CHECK_RUNS="$TMP_TEST/green.json"
STUB_GH_FAIL="1"
run_merge
STUB_GH_FAIL=""
check_case "caso 21 (gh fails on the head of the PR)" PENDIENTE "" "unknown"

# --- the verdict ----------------------------------------------------------
if [ "$FAILURES" -eq 0 ]; then
  echo "todos los casos pasan"
  exit 0
fi
echo "$FAILURES caso(s) fallan"
exit 1
