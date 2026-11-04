#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-verify-pr.sh - the tests of the exemption of the docs-only pull
# requests in bin/verify-pr.sh.
#
# WHY THE TESTS EXIST: a pull request that closes no issue AND changes only
# documentation has no code to compile, so it has no slot and no gate. The
# verifier used to report a FAIL that NOBODY could fix ("no se puede
# verificar el gate de este PR") and a verifier that cries wolf is a verifier
# nobody reads. The rule is the UPSTREAM's own (scripts/pr-checks/pr-checks.js,
# isDocsOnly): every file of the pull request matches the DOC_FILE pattern
# (docs/, a .md, LICENSE, the templates of the issues).
#
# WHAT IS TESTED (the cases are the rules, not the source):
#   a) a docs-only pull request with no issue and no slot in the branch is a
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
#      upstream (the change did not break it).
#
# THE TESTS ARE HERMETIC: GitHub is NEVER contacted.
#   * a `gh` of the tests, FIRST in the PATH: the answers come from the
#     fixtures of the test (a directory per pull request: its body, its
#     branch, its files and the JSON that `gh pr view` answers);
#   * a `git` of the tests: the fork is never asked either;
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
export STUB_FIXTURES="$TESTDIR/fixtures"
mkdir -p "$STUB_FIXTURES"

# The `gh` of the tests: the answers come from the FIXTURES of the test and
# GitHub is NEVER contacted. The fixture of a pull request is a directory
# with its body, its branch, its files and the JSON that `gh pr view`
# answers. The stub is PURE BASH on purpose: the suite runs the verifier
# thirty times and a python startup per call made it twenty times slower
# than it has to be.
cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_GH_LOG:-/dev/null}"
cmd="${1:-}"; sub="${2:-}"; num="${3:-}"
FIX="${STUB_FIXTURES:?the fixtures of the test are needed}"

case "$cmd $sub" in
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
    if [ -d "$FIX/$num" ] && [ -s "$FIX/$num/checks" ]; then
      cat "$FIX/$num/checks"
    fi
    ;;
  "pr list")
    # The lookup of the pull request that CLOSES an issue: the numbers of the
    # pull requests whose body closes it.
    issue=""
    prev=""
    for a in "$@"; do
      case "$prev" in
        --jq) issue="$(printf '%s' "$a" | grep -oE '#[0-9]+' | head -1 | tr -d '#')" ;;
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
        if [ -s "$d/body" ] && grep -qiE "(fixes|closes|resolve)[[:space:]]*#$issue([^0-9]|$)" "$d/body"; then
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

# The `git` of the tests: the fork is never asked. `ls-remote` answers
# nothing, which the verifier reads as "the branch is not in the fork" (a
# note, never a failure).
cat > "$STUBBIN/git" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = "ls-remote" ] && exit 0
done
exit 0
STUB
chmod 755 "$STUBBIN/git"

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
    fh.write("ci pass 12s https://example.invalid/ci/1\n")
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
  OUT="$(env HOME="$TESTDIR/home" \
              PATH="$STUBBIN:$PATH" \
              LOOP_DIR="$TESTDIR/loop" \
              ORCH_DIR="$TESTDIR/orch" \
              SOLIDCRAFT_REPO="$TESTDIR/repo" \
              STUB_FIXTURES="$STUB_FIXTURES" \
              STUB_GH_LOG="$TESTDIR/gh.log" \
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

# --- the control: the stub answered and GitHub was never contacted -----------
if [ -s "$TESTDIR/gh.log" ] && grep -q 'pr view 4201' "$TESTDIR/gh.log" \
   && grep -q -- '--json files' "$TESTDIR/gh.log"; then
  ok "the gh of the tests answered (GitHub was never contacted)"
else
  bad "the gh of the tests answered (GitHub was never contacted)" \
      "$(head -3 "$TESTDIR/gh.log" 2>/dev/null | tr '\n' ' ')"
fi

TOTAL=$(( PASS + FAIL ))
printf '%s casos, %s fallan\n' "$TOTAL" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf 'todos los casos pasan\n'
  exit 0
fi
printf '%s caso(s) fallan\n' "$FAIL"
exit 1
