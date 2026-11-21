#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-verify-pr.sh - the tests of bin/verify-pr.sh.
#
# WHY THE TESTS EXIST: a pull request that closes no issue AND changes only
# documentation has no code to compile, so it has no slot and no gate. The
# verifier used to report a FAIL that NOBODY could fix ("no se puede
# verificar el gate de este PR") and a verifier that cries wolf is a verifier
# nobody reads. The rule is the UPSTREAM's own (scripts/pr-checks/pr-checks.js,
# isDocsOnly): every file of the pull request matches the DOC_FILE pattern
# (docs/, a .md, LICENSE, the templates of the issues).
#
# The SECOND reason the tests exist (2026-11-17): the verifier answered "todo
# en orden" about pull requests whose CI it never read, and it derived the
# SLOT of the gate from a sentence of prose ("This fix 3 problems." -> the
# slot 3 -> a FAIL that nobody could fix).
#
# WHAT IS TESTED (the cases are the rules, not the source):
#   a) a docs-only pull request with no issue and no slot is a
#      NOTE, not a FAIL: the verdict says that there is nothing to fix;
#   b) a pull request WITH CODE, with no issue and no slot, is still a FAIL:
#      the exemption does not leak;
#   c) a docs-only pull request that DOES close an issue verifies the gate of
#      that issue, exactly as before the change;
#   d) a pull request with code that closes an issue whose slot has NO
#      verdict is a FAIL;
#   e) a pull request with code that closes an issue whose slot has a green
#      verdict ABOUT THE HEAD of the pull request is OK;
#   f) the pattern of the upstream: .github/ISSUE_TEMPLATE/bug.md is
#      documentation, crates/engine/src/lib.rs is NOT, and a pull request with
#      one documentation file and one file of code is NOT docs-only;
#   g) a malformed "Changes a default:" line still FAILS the validator of the
#      upstream (the change did not break it);
#   h) the number given can be the ISSUE's, not the pull request's;
#   i) a pull request that can NOT be read is a FAIL, not a green;
#   j) the CI is decided by the STATE of each check, not by its name:
#      j1) a `gh pr checks` that FAILS is an UNKNOWN (exit code 6), never a
#           green;
#      j2) a red check of ANY name ("Native Linux tests") BLOCKS;
#      j3) a red check of the EXEMPT list does not block;
#      j4) a check whose NAME contains "fail" but that is GREEN does not
#           block;
#   k) the closing phrases follow the UPSTREAM's parser
#      (scripts/pr-checks/pr-checks.js:35-47): the '#' is REQUIRED and the
#      ISSUES are counted, not the lines:
#      k1) "This fix 3 problems." is prose: it closes nothing and it does
#           not derive the slot 3;
#      k2) "Closes 5 open bugs." is prose too: it does not derive the slot 5;
#      k3) "Fixes #10181, #10182" closes TWO issues;
#      k4) two lines, two issues: "Fixes #123" and "Fixes #124" close TWO;
#      k5) the SAME issue twice closes ONE.
#   l) (2026-11-21) the gate can be upstream's CI run on the FORK
#      (bin/fork-ci.sh): green on the head satisfies it without a local
#      verdict (and without a slot); red, running, or green on another sha
#      does not; a green local verdict of the head is still the alternative;
#      a fork that cannot be read is an UNKNOWN; GATE_MODE=local asks for the
#      local gate; a red job the merge queue does not run (RISC-V) does not
#      block.
#
# THE TESTS ARE HERMETIC: GitHub is NEVER contacted.
#   * the `gh` of the tests, OUTSIDE the PATH (the verifier reads GH_BIN):
#     the answers come from the fixtures of the test (a directory per pull
#     request: its body, its branch, its files, the rollup of its checks and
#     the JSON that `gh pr view` answers);
#   * their own LOOP_DIR: their own gates/<slot>/scope.verdict and their own
#     bin/pr-defaults-line.sh (the validator of the upstream, mirrored);
#   * their own HOME and their own SOLIDCRAFT_REPO: the checkout of the
#     product is never read.
#
# Run:  bash ~/.local/share/solidcraft-orch/bin/test-verify-pr.sh
# ---------------------------------------------------------------------------
set -uo pipefail

# The scripts under test are found BY THE LOCATION OF THIS SUITE (not by
# $HOME): the suite has to run the same way in a harness with a temporary
# HOME and from any directory.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$(dirname "$HERE")}"
VERIFY_PR="${VERIFY_PR:-$ORCH_DIR/bin/verify-pr.sh}"
PASS=0
FAIL=0

ok()  { PASS=$(( PASS + 1 )); printf 'ok   - %s\n' "$1"; }
bad() {
  FAIL=$(( FAIL + 1 ))
  printf 'FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '     %s\n' "$2"
  return 0
}

# jq is needed: the stub of `gh` applies the --json of `pr checks` FOR REAL
# (the model is the stub of bin/test-ci-status.sh: a stub that ignores the
# filter measures the stub, not the rule).
command -v jq >/dev/null || { printf 'FAIL no hay jq (el stub lo necesita)\n'; exit 1; }

# --- the fixtures -----------------------------------------------------------
# The slot (the issue) of the cases with an issue. It is a FIXTURE: a rule
# that names a real issue stops being general the day that issue is closed.
SLOT=7058
# The head of the pull requests of the tests. It is not a commit of anything.
HEAD_SHA=0123456789abcdef0123456789abcdef01234567
# The gate writes the SHORT sha (10 chars) and the pull request gives the
# FULL one: the comparison of the verifier is by prefix.
SHORT_SHA=0123456789
# A repository that is not ours: the name only travels to the stub of `gh`.
TEST_REPO=acme/one

# --- the scratch of the tests ------------------------------------------------
TESTDIR="$(mktemp -d "${TMPDIR:-/tmp}/verify-pr-test.XXXXXX")"
trap 'rm -rf "$TESTDIR"' EXIT
STUBBIN="$TESTDIR/bin"
mkdir -p "$STUBBIN" "$TESTDIR/home" "$TESTDIR/loop/bin" "$TESTDIR/orch" "$TESTDIR/repo"
# EL GUARDIA (2026-11-21): el ORCH_DIR del verificador (donde fork-ci.sh deja
# su cache) nunca es el orquestador vivo.
if [ -f "$HERE/test-guard.sh" ]; then
  # shellcheck disable=SC1091
  source "$HERE/test-guard.sh"
  test_guard_orch_dir "$TESTDIR/orch"
fi
export STUB_FIXTURES="$TESTDIR/fixtures"
mkdir -p "$STUB_FIXTURES"

# The `gh` of the tests: the answers come from the FIXTURES of the test and
# GitHub is NEVER contacted. The fixture of a pull request is a directory
# with its body, its branch, its files, the rollup of its checks and the JSON
# that `gh pr view` answers.
#
# THE --json IS APPLIED FOR REAL (the model is the stub of bin/test-ci-status.sh:
# a stub that ignores the filter measures the stub, not the rule): the
# fixture of the checks is the RAW rollup and the stub answers only the
# fields that were asked for. And the closing phrases of `gh pr list` use the
# REGEX OF THE UPSTREAM (scripts/pr-checks/pr-checks.js:35-47), not a regex
# of the test's own: the '#' is required and a list counts every issue of it.
cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_GH_LOG:-/dev/null}"
cmd="${1:-}"; sub="${2:-}"; num="${3:-}"
FIX="${STUB_FIXTURES:?the fixtures of the test are needed}"

# The regex of the upstream (scripts/pr-checks/pr-checks.js:35-47): the '#'
# is REQUIRED ("This fix 3 problems." closes nothing) and a LIST of issues
# counts every one of them ("Fixes #1, #2" closes two).
CLOSING_RE='\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b:?[[:blank:]]+(([[:alnum:]_.-]+/[[:alnum:]_.-]+)?#[0-9]+([[:blank:]]*(,|and|&)[[:blank:]]*)?)+'

case "$cmd $sub" in
  "api "*)
    # THE CI OF THE FORK (2026-11-21): the runs of ci.yml and the jobs of a
    # run. Without a fixture the fork has NO run (the old cases did not know
    # the fork: for them the gate is the local verdict, as before).
    path="${sub%%\?*}"
    if [ -e "$FIX/forkci/fail" ]; then
      echo "gh: HTTP 502: the fork could not be read" >&2
      exit 1
    fi
    case "$path" in
      */actions/workflows/*/runs)
        if [ -s "$FIX/forkci/runs" ]; then cat "$FIX/forkci/runs"
        else printf '{"total_count":0,"workflow_runs":[]}\n'; fi ;;
      */actions/runs/*/jobs)
        rid="${path%/jobs}"; rid="${rid##*/}"
        # --paginate --slurp: a list of pages.
        if [ -s "$FIX/forkci/jobs-$rid" ]; then printf '[%s]\n' "$(cat "$FIX/forkci/jobs-$rid")"
        else printf '[{"total_count":0,"jobs":[]}]\n'; fi ;;
      *) echo "gh: the stub does not know the api path $path" >&2; exit 1 ;;
    esac
    exit 0
    ;;
  "pr view")
    jq_mode=0
    for a in "$@"; do
      [ "$a" = "--jq" ] && jq_mode=1
    done
    if [ -d "$FIX/$num" ]; then
      if [ "$jq_mode" = "1" ]; then
        [ -s "$FIX/$num/files" ] && cat "$FIX/$num/files"
      else
        cat "$FIX/$num/json"
      fi
    fi
    ;;
  "pr checks")
    # The fields that were asked for.
    fields=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "--json" ] && fields="$a"
      prev="$a"
    done
    # The exit code of the fixture: a `gh` that failed (auth, network, "no
    # checks reported") is a case the verifier has to survive.
    rc=0
    [ -s "$FIX/$num/checks_rc" ] && rc="$(cat "$FIX/$num/checks_rc")"
    if [ -s "$FIX/$num/checks_err" ]; then
      cat "$FIX/$num/checks_err" >&2
    fi
    if [ -s "$FIX/$num/checks" ]; then
      if [ -n "$fields" ]; then
        # THE FILTER IS APPLIED: like the real gh, the --json projects the
        # rollup onto the fields that were asked for.
        sel="$(printf '%s\n' "$fields" | tr ',' '\n' | jq -R . | jq -s -c .)"
        jq -c --argjson f "$sel" \
          '[.[] | with_entries(select(.key as $k | $f | index($k)))]' \
          < "$FIX/$num/checks" || exit 1
      else
        cat "$FIX/$num/checks"
      fi
    fi
    exit "$rc"
    ;;
  "pr list")
    # The lookup of the pull request that CLOSES an issue: the numbers of the
    # pull requests whose body closes it, with the regex of the upstream.
    issue=""
    prev=""
    for a in "$@"; do
      case "$prev" in
        --jq) issue="$(printf '%s\n' "$a" | grep -oE '#[0-9]+' | sed -n '1p' | tr -d '#')" ;;
      esac
      prev="$a"
    done
    limit=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "--limit" ] && limit="$a"
      prev="$a"
    done
    if [ -n "$issue" ]; then
      n_found=0
      for d in "$FIX"/*/; do
        [ -d "$d" ] || continue
        if [ -n "$limit" ] && [ "$n_found" -ge "$limit" ]; then
          break
        fi
        n="$(basename "$d")"
        if [ -s "$d/body" ] \
           && grep -oiE "$CLOSING_RE" "$d/body" | grep -qE "#$issue([^0-9]|$)"; then
          printf '%s\n' "$n"
          n_found=$(( n_found + 1 ))
        fi
      done
    fi
    ;;
esac
exit 0
STUB
chmod 755 "$STUBBIN/gh"

# The validator of the upstream, mirrored: it reads the body of a file and
# answers with the verdict of the line "Changes a default:". The REAL
# validator has its own suite in the loop (rule 47); what is tested here is
# the WIRING of the verifier: a validator that refuses the body is a FAIL of
# the verifier.
cat > "$TESTDIR/loop/bin/pr-defaults-line.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" != "--body" ] || [ ! -f "${2:-}" ]; then
  echo "uso: pr-defaults-line.sh --body <file>" >&2
  exit 2
fi
python3 - "${2}" <<'PY'
import re, sys
body = open(sys.argv[1], encoding="utf-8").read()
text = re.sub(r"<!--.*?-->", "", body, flags=re.S)
text = re.sub(r"```.*?```", "", text, flags=re.S)
text = re.sub(r"~~~.*?~~~", "", text, flags=re.S)
m = re.search(r"^[ \t]*(?:[-*][ \t]+)?Changes a default:[ \t]*(.*?)[ \t]*$",
              text, flags=re.I | re.M)
if not m:
    sys.exit(1)                      # missing
value = m.group(1).replace("**", "").strip()
if re.match(r"^no\.?$", value, flags=re.I):
    sys.exit(0)                      # 'no'
yes = re.match(r"^yes\b[ \t]*(?:—|–|->|→|-{1,2}|:)[ \t]*(.+)$", value, flags=re.I)
if yes:
    pref = re.match(
        r"^(.*?)[ ,;]*\bold (?:behaviou?r|value) kept behind "
        r"(?:preference|pref|setting)[ \t]+`?([\w.:/-]+)`?\.?$",
        yes.group(1), flags=re.I)
    if pref and pref.group(1).strip() and not re.match(r"^<.*>$", pref.group(2)):
        sys.exit(0)                  # 'yes' well formed
sys.exit(1)                          # malformed
PY
STUB
chmod 755 "$TESTDIR/loop/bin/pr-defaults-line.sh"

# config.env of the scratch loop: the tests never read the real one.
printf 'UPSTREAM=%s\nFORK_OWNER=testowner\n' "$TEST_REPO" > "$TESTDIR/loop/config.env"

# --- the fixtures of the pull requests ---------------------------------------
# The fixture of a pull request of the tests: a directory with its body, its
# branch, its files and the JSON that `gh pr view` answers. The JSON is
# rendered ONCE per fixture (a python startup per fixture, not per call).
# The rollup of the checks is JSON too: the stub of `gh` applies the --json
# of the verifier for real, so the fixture has the states of the checks.
fixture() {
  python3 - "$@" <<'PY'
import json, os, sys
num, body, branch, files, head = sys.argv[1:6]
d = os.path.join(os.environ["STUB_FIXTURES"], num)
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "body"), "w", encoding="utf-8") as fh:
    fh.write(body)
with open(os.path.join(d, "branch"), "w", encoding="utf-8") as fh:
    fh.write(branch)
with open(os.path.join(d, "files"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(f for f in files.split() if f))
    if files:
        fh.write("\n")
with open(os.path.join(d, "checks"), "w", encoding="utf-8") as fh:
    fh.write(json.dumps([
        {"name": "Defaults line check", "state": "SUCCESS", "bucket": "pass"},
        {"name": "Duplicate PR check", "state": "SUCCESS", "bucket": "pass"},
    ]))
with open(os.path.join(d, "json"), "w", encoding="utf-8") as fh:
    fh.write(json.dumps({
        "number": int(num),
        "state": "OPEN",
        "isDraft": False,
        "headRefOid": head,
        "headRefName": branch,
        "mergeable": "MERGEABLE",
        "mergeStateStatus": "CLEAN",
        "labels": [],
        "body": body,
    }))
PY
}

# The rollup of the checks of a pull request: the RAW one (the stub of `gh`
# applies the --json for real). $1 = the number, $2 = the JSON.
set_checks() {
  printf '%s\n' "$2" > "$STUB_FIXTURES/$1/checks"
}
# The `gh pr checks` that FAILS: $1 = the number, $2 = the exit code,
# $3 = what it writes in stderr.
set_checks_failing() {
  printf '%s\n' "$2" > "$STUB_FIXTURES/$1/checks_rc"
  printf '%s\n' "$3" > "$STUB_FIXTURES/$1/checks_err"
}

# The verdict of the gate of a slot, in the scratch LOOP_DIR.
write_verdict() {
  mkdir -p "$TESTDIR/loop/gates/$1"
  cat > "$TESTDIR/loop/gates/$1/scope.verdict" <<EOF
GATE_STATUS=finished
SCOPE=solidcraft
SCOPE_KIND=packages
VERDICT=VERDE-SCOPE
NEW_FAILURES=0
FAILED_TESTS=
CHECKS=fmt:ok|layers:ok|clippy:ok|check:ok
SHA=$2
AT=1793207822
EOF
}

# The run of the verifier: the output and the exit code are the verdict.
OUT=""
RC=0
run_verify() {
  local pr="$1"; shift
  # The stub of `gh` is OUTSIDE the PATH (the verifier reads GH_BIN): a fake
  # `gh` in the PATH would answer to `gh pr create` too.
  OUT="$(env HOME="$TESTDIR/home" \
              GH_BIN="$STUBBIN/gh" \
              LOOP_DIR="$TESTDIR/loop" \
              ORCH_DIR="$TESTDIR/orch" \
              SOLIDCRAFT_REPO="$TESTDIR/repo" \
              STUB_FIXTURES="$STUB_FIXTURES" \
              STUB_GH_LOG="$TESTDIR/gh.log" \
              GATE_MODE="${CASE_GATE_MODE:-}" \
              bash "$VERIFY_PR" "$pr" "$TEST_REPO" "$@" 2>&1)"
  RC=$?
}

fails_in() { printf '%s\n' "$1" | grep -c '^  FAIL' || true; }

# EVERY CASE IS SELF-CONTAINED: it declares its OWN pull request (the
# fixture is rebuilt for every run, so a case never inherits the pull
# request of the previous one) and its own gates.
run_pr() {
  # $1 number, $2 body, $3 branch, $4 files (space separated)
  rm -rf "$TESTDIR/loop/gates"
  rm -rf "$STUB_FIXTURES"
  # The cache of the jobs of the fork's runs: a case never reads the jobs of
  # the previous one.
  rm -rf "$TESTDIR/orch/gates/fork-ci"
  mkdir -p "$STUB_FIXTURES"
  fixture "$1" "$2" "$3" "$4" "$HEAD_SHA"
  run_verify "$1"
}

# --- the script under test ---------------------------------------------------
if [ ! -f "$VERIFY_PR" ]; then
  printf 'FAIL %s\n' "the verifier under test is there: $VERIFY_PR"
  printf '1 caso(s) fallan\n'
  exit 1
fi

# --- a) a docs-only pull request with no issue and no slot -------------------
run_pr 4201 \
  $'documentation only: this pull request explains the new flag of the loop.\n\nChanges a default: no\n' \
  "docs/update-the-guide" \
  "docs/guide.md README.md"
if [ "$RC" -eq 0 ]; then
  ok "a) a docs-only pull request with no issue and no slot is NOT a failure"
else
  bad "a) a docs-only pull request with no issue and no slot is NOT a failure" \
      "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q 'exencion de docs del upstream'; then
  ok "a) the verifier says that the docs-only pull request has no gate to run"
else
  bad "a) the verifier says that the docs-only pull request has no gate to run" \
      "$(printf '%s' "$OUT" | tail -5 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q 'no se puede verificar el gate'; then
  bad "a) the verifier does NOT demand a slot for a docs-only pull request" \
      "$(printf '%s' "$OUT" | grep 'no se puede verificar el gate' | head -1)"
else
  ok "a) the verifier does NOT demand a slot for a docs-only pull request"
fi
if [ "$(fails_in "$OUT")" = "0" ] && printf '%s' "$OUT" | grep -q 'VEREDICTO: todo en orden'; then
  ok "a) the final verdict of a docs-only pull request says that nothing has to be fixed"
else
  bad "a) the final verdict of a docs-only pull request says that nothing has to be fixed" \
      "fails=$(fails_in "$OUT") $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi

# --- b) a pull request WITH CODE, with no issue and no slot -----------------
run_pr 4202 \
  $'no issue: this pull request is an internal cleanup of the loop.\n\nChanges a default: no\n' \
  "chore/cleanup-the-loop" \
  "crates/engine/src/lib.rs"
if [ "$RC" -eq 1 ]; then
  ok "b) a pull request with code and no slot FAILS the gate"
else
  bad "b) a pull request with code and no slot FAILS the gate" \
      "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q 'no se puede verificar el gate'; then
  ok "b) the verifier says that the gate of a pull request with code cannot be verified"
else
  bad "b) the verifier says that the gate of a pull request with code cannot be verified" \
      "$(printf '%s' "$OUT" | tail -5 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q 'exencion de docs del upstream'; then
  bad "b) the exemption of the docs does NOT leak to a pull request with code" \
      "$(printf '%s' "$OUT" | grep 'exencion de docs' | head -1)"
else
  ok "b) the exemption of the docs does NOT leak to a pull request with code"
fi
if [ "$(fails_in "$OUT")" = "1" ]; then
  ok "b) the gate is the ONLY failure of that pull request"
else
  bad "b) the gate is the ONLY failure of that pull request" \
      "fails=$(fails_in "$OUT")"
fi

# --- c) a docs-only pull request that DOES close an issue -------------------
# The pull request HAS a slot (the issue it closes): the gate of that slot
# is verified, and the exemption of the docs does NOT apply.
run_pr 4203 \
  $'Fixes #7058\n\nChanges a default: no\n\nthe documentation of the fix\n' \
  "docs/clarify-the-fix" \
  "docs/guide.md"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "falta el veredicto del gate del slot $SLOT"; then
  ok "c) a docs-only pull request with a slot and no verdict FAILS the gate"
else
  bad "c) a docs-only pull request with a slot and no verdict FAILS the gate" \
      "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi
# The same pull request, with the green verdict of its slot.
write_verdict "$SLOT" "$SHORT_SHA"
run_verify 4203
if printf '%s' "$OUT" | grep -q "gate local (slot $SLOT"; then
  ok "c) a docs-only pull request that closes an issue verifies the gate of that issue"
else
  bad "c) a docs-only pull request that closes an issue verifies the gate of that issue" \
      "$(printf '%s' "$OUT" | tail -5 | tr '\n' ' ')"
fi
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "el gate local del slot $SLOT esta verde"; then
  ok "c) the gate of that issue is green: the pull request is in order"
else
  bad "c) the gate of that issue is green: the pull request is in order" \
      "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi

# --- d) a pull request with code that closes an issue, without a verdict -----
run_pr 4204 \
  $'Fixes #7058\n\nChanges a default: no\n\nthe fix\n' \
  "fix/issue-$SLOT-the-engine" \
  "crates/engine/src/lib.rs"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "falta el veredicto del gate del slot $SLOT"; then
  ok "d) a pull request with code whose slot has no verdict FAILS"
else
  bad "d) a pull request with code whose slot has no verdict FAILS" \
      "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi

# --- d2) the slot can also come from the BRANCH (the third place) ----------
# The body of this pull request closes no issue: the slot comes from the
# number of the branch ("fix/issue-NNNN-..."), and the gate of that slot is
# verified as usual. The exemption of the docs does NOT apply: this pull
# request HAS a slot.
run_pr 4210 \
  $'no issue\n\nChanges a default: no\n\nthe fix\n' \
  "fix/issue-$SLOT-the-engine" \
  "crates/engine/src/lib.rs"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "falta el veredicto del gate del slot $SLOT"; then
  ok "d2) the slot of the branch is used and its gate is verified"
else
  bad "d2) the slot of the branch is used and its gate is verified" \
      "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi
rm -rf "$TESTDIR/loop/gates"
write_verdict "$SLOT" "$SHORT_SHA"
run_verify 4210
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "el gate local del slot $SLOT esta verde"; then
  ok "d2) the slot of the branch, with a green verdict: the pull request is in order"
else
  bad "d2) the slot of the branch, with a green verdict: the pull request is in order" \
      "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi

# --- e) a pull request with code, a green verdict about the head -------------
run_pr 4204 \
  $'Fixes #7058\n\nChanges a default: no\n\nthe fix\n' \
  "fix/issue-$SLOT-the-engine" \
  "crates/engine/src/lib.rs"
write_verdict "$SLOT" "$SHORT_SHA"
run_verify 4204
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "el gate local del slot $SLOT esta verde (commit $SHORT_SHA)"; then
  ok "e) a green verdict about the head of the pull request is OK"
else
  bad "e) a green verdict about the head of the pull request is OK" \
      "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi
# The same verdict, but about ANOTHER commit: it does not serve.
rm -rf "$TESTDIR/loop/gates"
write_verdict "$SLOT" "9999999999"
run_verify 4204
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'el veredicto no sirve'; then
  ok "e) a green verdict about ANOTHER commit does not serve"
else
  bad "e) a green verdict about ANOTHER commit does not serve" \
      "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi

# --- f) the pattern of the upstream ------------------------------------------
# The criterion is the UPSTREAM's own (scripts/pr-checks/pr-checks.js,
# isDocsOnly): EVERY file of the pull request matches the DOC_FILE pattern
# (docs/, a .md, LICENSE, the templates of the issues).
#
# EACH RULE IS PROBED ALONE, with a file that ONLY that rule accepts
# (docs/architecture.txt is not a .md, .github/ISSUE_TEMPLATE/bug.yml is not
# a .md, LICENSE is not a .md): a rule that stops working is caught instead
# of being hidden by another rule that happens to accept the same file.
#
# The two verdicts of the verifier are told apart:
#   * docs-only  -> a NOTE: "no hay slot y no hay gate que correr";
#   * not docs   -> a FAIL: "no se puede verificar el gate de este PR".
PR_N=4205
expect_docs() {
  # $1 = the description, $2 = the files (space separated)
  local label="$1" files="$2"
  PR_N=$(( PR_N + 1 ))
  run_pr "$PR_N" \
    $'documentation only\n\nChanges a default: no\n' \
    "docs/probe" \
    "$files"
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'exencion de docs del upstream'; then
    ok "f) $label counts as documentation"
  else
    bad "f) $label counts as documentation" \
        "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
  fi
}
expect_not_docs() {
  # $1 = the description, $2 = the files (space separated)
  local label="$1" files="$2"
  PR_N=$(( PR_N + 1 ))
  run_pr "$PR_N" \
    $'no issue\n\nChanges a default: no\n' \
    "chore/probe" \
    "$files"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'no se puede verificar el gate'; then
    ok "f) $label is NOT documentation"
  else
    bad "f) $label is NOT documentation" \
        "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
  fi
}

# The rules of the pattern, one at a time.
expect_docs    "docs/architecture.txt (the rule docs/)"        "docs/architecture.txt"
expect_docs    "README.md (the rule *.md)"                      "README.md"
expect_docs    "LICENSE (the rule LICENSE)"                     "LICENSE"
expect_docs    "LICENSE-MIT (the rule LICENSE is a PREFIX)"     "LICENSE-MIT"
expect_docs    ".github/ISSUE_TEMPLATE/bug.yml (the templates)" ".github/ISSUE_TEMPLATE/bug.yml"
expect_docs    ".github/pull_request_template.md"               ".github/pull_request_template.md"
expect_docs    ".github/ISSUE_TEMPLATE/bug.md"                  ".github/ISSUE_TEMPLATE/bug.md"
# The files that are NOT documentation.
expect_not_docs "crates/engine/src/lib.rs"                     "crates/engine/src/lib.rs"
expect_not_docs "README.txt (a .txt is not a .md)"             "README.txt"
expect_not_docs "src/main.rs"                                  "src/main.rs"
expect_not_docs "THIRD-PARTY-LICENSES.txt (LICENSE is a prefix, not a substring)" \
                 "THIRD-PARTY-LICENSES.txt"
# A pull request with one documentation file and one file of code is NOT
# docs-only: one file of code is enough to demand the gate.
expect_not_docs "a pull request with one documentation file and one file of code" \
                 "docs/guide.md crates/engine/src/lib.rs"
# A pull request with NO files at all is not docs-only either (there is
# nothing to judge and no file to exempt).
expect_not_docs "a pull request with no files at all"           ""

# --- g) a malformed "Changes a default:" line --------------------------------
run_pr 4209 \
  $'documentation only\n\nChanges a default: yes\n' \
  "docs/a-malformed-default" \
  "docs/guide.md"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'el validador de defaults del upstream FALLA'; then
  ok "g) a malformed 'Changes a default:' line FAILS the validator of the upstream"
else
  bad "g) a malformed 'Changes a default:' line FAILS the validator of the upstream" \
      "rc=$RC $(printf '%s' "$OUT" | tail -5 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q 'exencion de docs del upstream'; then
  ok "g) the validator of the defaults is independent of the exemption of the docs"
else
  bad "g) the validator of the defaults is independent of the exemption of the docs" \
      "$(printf '%s' "$OUT" | tail -5 | tr '\n' ' ')"
fi

# --- h) the number given can be the ISSUE's ---------------------------------
# The verifier is given the number of the ISSUE and finds the pull request
# that closes it. The gate of that pull request is verified as usual.
rm -rf "$TESTDIR/loop/gates"
rm -rf "$STUB_FIXTURES"
mkdir -p "$STUB_FIXTURES"
fixture 4211 \
  $'Fixes #7058\n\nChanges a default: no\n\nthe fix\n' \
  "fix/issue-$SLOT-the-engine" \
  "crates/engine/src/lib.rs" \
  "$HEAD_SHA"
write_verdict "$SLOT" "$SHORT_SHA"
run_verify "$SLOT"
if printf '%s' "$OUT" | grep -q "el PR que lo cierra es #4211"; then
  ok "h) the number of the issue finds the pull request that closes it"
else
  bad "h) the number of the issue finds the pull request that closes it" \
      "$(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "el gate local del slot $SLOT esta verde"; then
  ok "h) the gate of that pull request is verified"
else
  bad "h) the gate of that pull request is verified" \
      "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi

# --- i) a pull request that CANNOT be read ----------------------------------
# The stub has no answer for this number (and no pull request closes it):
# the verifier has to say that it could not read it, and FAIL. A verifier
# that says "todo en orden" about a pull request it never read is a FALSE
# green.
rm -rf "$TESTDIR/loop/gates"
rm -rf "$STUB_FIXTURES"
mkdir -p "$STUB_FIXTURES"
run_verify 4299
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'no se pudo leer el PR'; then
  ok "i) a pull request that can not be read is a FAIL, not a green"
else
  bad "i) a pull request that can not be read is a FAIL, not a green" \
      "rc=$RC $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q 'VEREDICTO: todo en orden'; then
  bad "i) the verdict of an unreadable pull request is NOT 'todo en orden'"
else
  ok "i) the verdict of an unreadable pull request is NOT 'todo en orden'"
fi

# --- j) the CI: the STATE of the check, not its NAME ------------------------
# The CI of a pull request used to be read with a grep over the NAMES of the
# checks: a check whose name contains "fail" counted as a failure, the
# checks whose name says nothing were not counted at all (the three that
# decide if a pull request is mergeable were among them), and the exit code
# of `gh pr checks` was thrown away: a `gh` that failed left the text of its
# error in the output, that text does not contain "fail", and the verifier
# said "todo en orden" about a pull request whose CI it never read.

# j1) a `gh pr checks` that FAILS: the CI could not be read. That is NOT a
#     red (a check that could not run is not a red) but it is also NOT a
#     green: nobody knows. The exit code is 6 (UNKNOWN), never 0.
run_pr 4301 \
  $'Fixes #7058\n\nChanges a default: no\n\nthe fix\n' \
  "fix/issue-$SLOT-the-engine" \
  "crates/engine/src/lib.rs"
write_verdict "$SLOT" "$SHORT_SHA"
set_checks_failing 4301 1 "gh: could not resolve to a PullRequest"
run_verify 4301
if [ "$RC" -eq 6 ]; then
  ok "j1) a 'gh pr checks' that fails is an UNKNOWN (rc=6), not a green"
else
  bad "j1) a 'gh pr checks' that fails is an UNKNOWN (rc=6), not a green" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q 'VEREDICTO: todo en orden'; then
  bad "j1) the verdict of a pull request whose CI could not be read is NOT 'todo en orden'"
else
  ok "j1) the verdict of a pull request whose CI could not be read is NOT 'todo en orden'"
fi
if printf '%s' "$OUT" | grep -qi 'UNKNOWN'; then
  ok "j1) the verifier says that the CI could not be read"
else
  bad "j1) the verifier says that the CI could not be read" \
      "$(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi
if [ "$(fails_in "$OUT")" = "0" ]; then
  ok "j1) a CI that could not be read is NOT a FAIL (it is a 'nobody knows')"
else
  bad "j1) a CI that could not be read is NOT a FAIL (it is a 'nobody knows')" \
      "fails=$(fails_in "$OUT")"
fi

# j1b) `gh pr checks` exits 1 WHEN A CHECK FAILED: that is a KNOWN state
#      (the PR is red), not a "nobody knows". The red checks are reported
#      as the failure they are, and the verdict is NOT "UNKNOWN".
#      The code that cannot be read is the one with no payload at all.
run_pr 4303 \
  $'Fixes #7058\n\nChanges a default: no\n\nthe fix\n' \
  "fix/issue-$SLOT-the-engine" \
  "crates/engine/src/lib.rs"
write_verdict "$SLOT" "$SHORT_SHA"
set_checks 4303 '[{"name":"Native Linux tests","state":"FAILURE","bucket":"fail"}]'
set_checks_failing 4303 1 "some checks failed"
run_verify 4303
if [ "$RC" -eq 1 ] && ! printf '%s' "$OUT" | grep -qi 'UNKNOWN'; then
  ok "j1b) un 'gh pr checks' que sale con 1 por un check rojo es un FAIL conocido, no UNKNOWN"
else
  bad "j1b) un 'gh pr checks' que sale con 1 por un check rojo es un FAIL conocido, no UNKNOWN" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q 'Native Linux tests'; then
  ok "j1b) el check rojo queda nombrado"
else
  bad "j1b) el check rojo queda nombrado" "$(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# j2) a red check of ANY name blocks: "Native Linux tests" is one of the
#     three that decide if a pull request is mergeable, and the old filter
#     never looked at it.
run_pr 4302 \
  $'Fixes #7058\n\nChanges a default: no\n\nthe fix\n' \
  "fix/issue-$SLOT-the-engine" \
  "crates/engine/src/lib.rs"
write_verdict "$SLOT" "$SHORT_SHA"
set_checks 4302 '[
  {"name": "Defaults line check", "state": "SUCCESS", "bucket": "pass"},
  {"name": "Native Linux tests", "state": "FAILURE", "bucket": "fail"}
]'
run_verify 4302
if [ "$RC" -eq 1 ]; then
  ok "j2) a red check of any name blocks the pull request"
else
  bad "j2) a red check of any name blocks the pull request" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q 'Native Linux tests'; then
  ok "j2) the verifier names the check that is red"
else
  bad "j2) the verifier names the check that is red" \
      "$(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# j3) a red check of the EXEMPT list does not block (but it is reported).
run_pr 4303 \
  $'Fixes #7058\n\nChanges a default: no\n\nthe fix\n' \
  "fix/issue-$SLOT-the-engine" \
  "crates/engine/src/lib.rs"
write_verdict "$SLOT" "$SHORT_SHA"
set_checks 4303 '[
  {"name": "Defaults line check", "state": "SUCCESS", "bucket": "pass"},
  {"name": "Claim bot", "state": "FAILURE", "bucket": "fail"}
]'
run_verify 4303
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'VEREDICTO: todo en orden'; then
  ok "j3) a red check of the exempt list does not block the pull request"
else
  bad "j3) a red check of the exempt list does not block the pull request" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q 'Claim bot'; then
  ok "j3) the red check that does not block is still reported"
else
  bad "j3) the red check that does not block is still reported" \
      "$(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# j4) a check whose NAME contains "fail" but that is GREEN does not block.
run_pr 4304 \
  $'Fixes #7058\n\nChanges a default: no\n\nthe fix\n' \
  "fix/issue-$SLOT-the-engine" \
  "crates/engine/src/lib.rs"
write_verdict "$SLOT" "$SHORT_SHA"
set_checks 4304 '[
  {"name": "failing to provision the runner", "state": "SUCCESS", "bucket": "pass"},
  {"name": "Defaults line check", "state": "SUCCESS", "bucket": "pass"}
]'
run_verify 4304
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'VEREDICTO: todo en orden'; then
  ok "j4) a green check whose name contains 'fail' does not block"
else
  bad "j4) a green check whose name contains 'fail' does not block" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# j5) a check that is PENDING is not a red and not a green: the CI is still
#     running, which is a state the verifier knows (it does not block, and it
#     is not the "nobody knows" of an unreadable CI).
run_pr 4305 \
  $'Fixes #7058\n\nChanges a default: no\n\nthe fix\n' \
  "fix/issue-$SLOT-the-engine" \
  "crates/engine/src/lib.rs"
write_verdict "$SLOT" "$SHORT_SHA"
set_checks 4305 '[
  {"name": "Defaults line check", "state": "SUCCESS", "bucket": "pass"},
  {"name": "Native Linux tests", "state": "IN_PROGRESS", "bucket": "pending"}
]'
set_checks_failing 4305 8 ""
run_verify 4305
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'VEREDICTO: todo en orden'; then
  ok "j5) a check that is pending does not block the pull request"
else
  bad "j5) a check that is pending does not block the pull request" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# --- k) the closing phrases: the UPSTREAM's parser -------------------------
# The authority is scripts/pr-checks/pr-checks.js:35-47 (parseClosing): the
# '#' is REQUIRED (it is what tells a reference to an issue from prose that
# has a number in it) and the ISSUES are counted, not the lines.
#
# k1) "This fix 3 problems." is prose. The old regex matched "fix 3", took
#     the 3 as the SLOT of the gate and failed a perfectly valid pull
#     request looking for the gate of the slot 3.
run_pr 4310 \
  $'This fix 3 problems.\n\nno issue: this pull request is a cleanup of the loop.\n\nChanges a default: no\n' \
  "chore/cleanup-the-loop" \
  "crates/engine/src/lib.rs"
write_verdict "$SLOT" "$SHORT_SHA"
run_verify 4310 "$SLOT"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'VEREDICTO: todo en orden'; then
  ok "k1) a prose sentence does not break a valid pull request"
else
  bad "k1) a prose sentence does not break a valid pull request" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q 'slot 3'; then
  bad "k1) the number of a prose sentence does NOT become the slot" \
      "$(printf '%s' "$OUT" | grep 'slot 3' | head -1)"
else
  ok "k1) the number of a prose sentence does NOT become the slot"
fi
if printf '%s' "$OUT" | grep -q "gate local (slot $SLOT"; then
  ok "k1) the gate of the slot that was asked for is the one that is verified"
else
  bad "k1) the gate of the slot that was asked for is the one that is verified" \
      "$(printf '%s' "$OUT" | tail -5 | tr '\n' ' ')"
fi
# The same body WITHOUT the "no issue" line: the pull request has to say
# which issue it closes, but it must not be the "3" of the prose.
run_pr 4311 \
  $'This fix 3 problems.\n\nChanges a default: no\n' \
  "chore/cleanup-the-loop" \
  "crates/engine/src/lib.rs"
run_verify 4311 "$SLOT"
if printf '%s' "$OUT" | grep -q 'slot 3'; then
  bad "k1) a prose sentence is not a closing phrase (no slot 3)" \
      "$(printf '%s' "$OUT" | grep 'slot 3' | head -1)"
else
  ok "k1) a prose sentence is not a closing phrase (no slot 3)"
fi
if printf '%s' "$OUT" | grep -q 'ninguna frase de cierre'; then
  ok "k1) a body with no closing phrase is asked for one (and not for the gate of a slot made of prose)"
else
  bad "k1) a body with no closing phrase is asked for one (and not for the gate of a slot made of prose)" \
      "$(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# k2) "Closes 5 open bugs." is prose too: it does not derive the slot 5.
run_pr 4312 \
  $'Closes 5 open bugs.\n\nno issue: this pull request is a cleanup of the loop.\n\nChanges a default: no\n' \
  "chore/cleanup-the-loop" \
  "crates/engine/src/lib.rs"
write_verdict "$SLOT" "$SHORT_SHA"
run_verify 4312 "$SLOT"
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'slot 5'; then
  ok "k2) 'Closes 5 open bugs.' does not derive the slot 5"
else
  bad "k2) 'Closes 5 open bugs.' does not derive the slot 5" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# k3) a LIST closes more than one issue: "Fixes #10181, #10182" closes TWO.
run_pr 4313 \
  $'Fixes #10181, #10182\n\nChanges a default: no\n\nthe fix\n' \
  "fix/two-issues-at-once" \
  "crates/engine/src/lib.rs"
run_verify 4313
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'cierra 2 issues'; then
  ok "k3) a list of issues closes more than one issue and FAILS"
else
  bad "k3) a list of issues closes more than one issue and FAILS" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# k4) two lines, two issues: "Fixes #123" and "Fixes #124" close TWO.
run_pr 4314 \
  $'Fixes #123\n\nFixes #124\n\nChanges a default: no\n\nthe fix\n' \
  "fix/two-issues-in-two-lines" \
  "crates/engine/src/lib.rs"
run_verify 4314
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'cierra 2 issues'; then
  ok "k4) two closing phrases in two lines close two issues and FAIL"
else
  bad "k4) two closing phrases in two lines close two issues and FAIL" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# k5) the SAME issue twice closes ONE (the upstream counts issues, not
#     lines): it is not the "closes more than one issue" failure.
run_pr 4315 \
  $'Fixes #7058\n\nFixes #7058\n\nChanges a default: no\n\nthe fix\n' \
  "fix/issue-$SLOT-the-engine" \
  "crates/engine/src/lib.rs"
write_verdict "$SLOT" "$SHORT_SHA"
run_verify 4315
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'VEREDICTO: todo en orden'; then
  ok "k5) the same issue twice closes ONE issue"
else
  bad "k5) the same issue twice closes ONE issue" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# k6) a reference to ANOTHER repository closes nothing of ours (the rule of
#     the upstream: "Fixes other/repo#5" does not close an issue of ours).
run_pr 4316 \
  $'Fixes acme/other#123\n\nno issue: this pull request is a cleanup of the loop.\n\nChanges a default: no\n' \
  "chore/cleanup-the-loop" \
  "crates/engine/src/lib.rs"
write_verdict "$SLOT" "$SHORT_SHA"
run_verify 4316 "$SLOT"
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'slot 123'; then
  ok "k6) a reference to another repository does not close an issue of ours"
else
  bad "k6) a reference to another repository does not close an issue of ours" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# k7) the same reference, but to OUR repository: it closes the issue.
run_pr 4317 \
  $'Fixes acme/one#123\n\nChanges a default: no\n\nthe fix\n' \
  "fix/issue-123-the-engine" \
  "crates/engine/src/lib.rs"
run_verify 4317
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'falta el veredicto del gate del slot 123'; then
  ok "k7) a reference to OUR repository closes the issue (the slot is that one)"
else
  bad "k7) a reference to OUR repository closes the issue (the slot is that one)" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi
# And it is the BODY that says it (not the name of the branch).
if printf '%s' "$OUT" | grep -q 'de el body (cierra el issue #123)'; then
  ok "k7) the closing phrase of the body is the one that names the slot"
else
  bad "k7) the closing phrase of the body is the one that names the slot" \
      "$(printf '%s' "$OUT" | grep -E 'slot 123' | head -1)"
fi

# --- l) the gate can be the CI of the FORK on the head (2026-11-21) ---------
# The pipeline gates with upstream's ci.yml dispatched on the fork
# (bin/fork-ci.sh). Green on the head satisfies the gate; the local verdict
# is the alternative; a fork that cannot be read is an UNKNOWN, not a red.
fork_runs() {  # $1 = the list of runs (JSON)
  mkdir -p "$STUB_FIXTURES/forkci"
  printf '{"total_count":1,"workflow_runs":%s}\n' "$1" > "$STUB_FIXTURES/forkci/runs"
}
fork_jobs() {  # $1 = the id of the run, $2 = the list of its jobs (JSON)
  mkdir -p "$STUB_FIXTURES/forkci"
  printf '{"total_count":1,"jobs":%s}' "$2" > "$STUB_FIXTURES/forkci/jobs-$1"
}
fork_run() {  # $1 id, $2 status, $3 conclusion, [$4 head sha]
  local concl="null"
  [ -n "$3" ] && concl="\"$3\""
  printf '{"id":%s,"status":"%s","conclusion":%s,"html_url":"https://github.com/acme/fork/actions/runs/%s","head_sha":"%s","head_branch":"fix/issue-%s","event":"workflow_dispatch","created_at":"2026-11-21T10:00:00Z","updated_at":"2026-11-21T12:00:00Z","run_attempt":1}' \
    "$1" "$2" "$concl" "$1" "${4:-$HEAD_SHA}" "$SLOT"
}
fork_job() {  # $1 id, $2 name, $3 conclusion
  printf '{"id":%s,"name":"%s","status":"completed","conclusion":"%s","started_at":"2026-11-21T10:01:00Z","completed_at":"2026-11-21T11:00:00Z"}' "$1" "$2" "$3"
}
CODE_BODY="$(printf 'Fixes #%s\n\nChanges a default: no\n\nthe fix\n' "$SLOT")"

run_pr 4401 "$CODE_BODY" "fix/issue-$SLOT-the-engine" "crates/engine/src/lib.rs"
fork_runs "[$(fork_run 901 completed success)]"
run_verify 4401
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'el CI del fork esta VERDE en el head del PR (https://github.com/acme/fork/actions/runs/901)'; then
  ok "l1) the fork's CI green on the head satisfies the gate WITHOUT a local verdict"
else
  bad "l1) the fork's CI green on the head satisfies the gate WITHOUT a local verdict" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

run_pr 4402 $'no issue: an internal cleanup.\n\nChanges a default: no\n' \
  "chore/cleanup" "crates/engine/src/lib.rs"
fork_runs "[$(fork_run 902 completed success)]"
run_verify 4402
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'no se puede verificar el gate'; then
  ok "l2) with the fork's CI green on the head, a PR with no slot does not need one"
else
  bad "l2) with the fork's CI green on the head, a PR with no slot does not need one" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

run_pr 4403 "$CODE_BODY" "fix/issue-$SLOT-the-engine" "crates/engine/src/lib.rs"
fork_runs "[$(fork_run 903 completed failure)]"
fork_jobs 903 "[$(fork_job 1 'Native Linux tests' failure),$(fork_job 2 'Native Linux Clippy' success)]"
run_verify 4403
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'falta el veredicto del gate del slot' \
   && printf '%s' "$OUT" | grep -q 'ROJO.*fallan: Native Linux tests'; then
  ok "l3) the fork's CI RED and no local verdict FAILS, naming the job that fails"
else
  bad "l3) the fork's CI RED and no local verdict FAILS, naming the job that fails" \
      "rc=$RC $(printf '%s' "$OUT" | grep -E 'fork|FAIL' | tr '\n' ' ')"
fi
write_verdict "$SLOT" "$SHORT_SHA"
run_verify 4403
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "el gate local del slot $SLOT esta verde"; then
  ok "l4) the fork's CI red but a green LOCAL verdict of the head: the alternative holds"
else
  bad "l4) the fork's CI red but a green LOCAL verdict of the head: the alternative holds" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

run_pr 4404 "$CODE_BODY" "fix/issue-$SLOT-the-engine" "crates/engine/src/lib.rs"
mkdir -p "$STUB_FIXTURES/forkci"; : > "$STUB_FIXTURES/forkci/fail"
run_verify 4404
if [ "$RC" -eq 6 ] && printf '%s' "$OUT" | grep -q 'no se pudo leer el CI del fork'; then
  ok "l5) a fork that cannot be read and no local verdict is an UNKNOWN (rc=6), not a red"
else
  bad "l5) a fork that cannot be read and no local verdict is an UNKNOWN (rc=6), not a red" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

run_pr 4405 "$CODE_BODY" "fix/issue-$SLOT-the-engine" "crates/engine/src/lib.rs"
fork_runs "[$(fork_run 905 in_progress '')]"
run_verify 4405
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'el CI del fork esta PENDIENTE'; then
  ok "l6) the fork's CI still running is not a gate: FAIL, and it says PENDIENTE"
else
  bad "l6) the fork's CI still running is not a gate: FAIL, and it says PENDIENTE" \
      "rc=$RC $(printf '%s' "$OUT" | grep -E 'fork|FAIL' | tr '\n' ' ')"
fi

run_pr 4406 "$CODE_BODY" "fix/issue-$SLOT-the-engine" "crates/engine/src/lib.rs"
fork_runs "[$(fork_run 906 completed success 9999999999999999999999999999999999999999)]"
run_verify 4406
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'despachalo (bash bin/fork-ci.sh'; then
  ok "l7) a green run of ANOTHER sha is not the gate of the head: FAIL, and it says how to dispatch"
else
  bad "l7) a green run of ANOTHER sha is not the gate of the head: FAIL, and it says how to dispatch" \
      "rc=$RC $(printf '%s' "$OUT" | grep -E 'fork|FAIL' | tr '\n' ' ')"
fi

run_pr 4407 "$CODE_BODY" "fix/issue-$SLOT-the-engine" "crates/engine/src/lib.rs"
CASE_GATE_MODE=local run_verify 4407
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "corré el gate de este slot antes de publicar (bash bin/gate.sh $SLOT"; then
  ok "l8) with GATE_MODE=local the missing verdict asks for the local gate"
else
  bad "l8) with GATE_MODE=local the missing verdict asks for the local gate" \
      "rc=$RC $(printf '%s' "$OUT" | grep -E 'FAIL' | tr '\n' ' ')"
fi

run_pr 4408 "$CODE_BODY" "fix/issue-$SLOT-the-engine" "crates/engine/src/lib.rs"
fork_runs "[$(fork_run 908 completed failure)]"
fork_jobs 908 "[$(fork_job 1 'Native Linux tests' success),$(fork_job 2 'Compile RISC-V (manual)' failure)]"
run_verify 4408
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'el CI del fork esta VERDE'; then
  ok "l9) a red job the merge queue does not run (RISC-V) does not block the gate"
else
  bad "l9) a red job the merge queue does not run (RISC-V) does not block the gate" \
      "rc=$RC $(printf '%s' "$OUT" | grep -E 'fork|FAIL' | tr '\n' ' ')"
fi

# --- the control: the stub answered and GitHub was never contacted -----------
if [ -s "$TESTDIR/gh.log" ] && grep -q 'pr view 4201' "$TESTDIR/gh.log" \
   && grep -q -- '--json files' "$TESTDIR/gh.log"; then
  ok "the gh of the tests answered (GitHub was never contacted)"
else
  bad "the gh of the tests answered (GitHub was never contacted)" \
      "$(head -3 "$TESTDIR/gh.log" 2>/dev/null | tr '\n' ' ')"
fi
# The verifier asks for the checks WITH their state (not for a text to grep).
if grep -q -- 'pr checks 4302 .*--json name,state,bucket' "$TESTDIR/gh.log"; then
  ok "the verifier asks the gh for the STATE of the checks"
else
  bad "the verifier asks the gh for the STATE of the checks" \
      "$(grep 'pr checks' "$TESTDIR/gh.log" 2>/dev/null | head -2 | tr '\n' ' ')"
fi

TOTAL=$(( PASS + FAIL ))
printf '%s casos, %s fallan\n' "$TOTAL" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf 'todos los casos pasan\n'
  exit 0
fi
printf '%s caso(s) fallan\n' "$FAIL"
exit 1
