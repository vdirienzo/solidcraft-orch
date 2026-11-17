#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-gate-claim.sh - the tests of the check of the claim of bin/gate.sh.
#
# WHY THE TESTS EXIST (31-10-2026): the gate checks the claim of the issue
# BEFORE it compiles (a scoped gate is 8+ minutes of the CPU of the machine,
# and the work is thrown away when the claim is lost). The check used to call
# bin/claim-verify.sh with the issue ALONE: without saying which pull request
# is OURS, our own pull request was read as "the competitor that already
# claims the issue", so the gate aborted with exit 4 in EVERY pull request of
# ours, BEFORE compiling anything. A gate that aborts before compiling does
# not compile: the bug blocked the publication of everything we do.
#
# The fix: gate.sh takes a FOURTH argument (our pull request) and, when it is
# not given, DISCOVERS it from the branch of the worktree
# (gh pr list --head <branch>). The worktree of a slot has .git as a FILE,
# not as a directory: the condition is [ -d "$REPO/.git" ] || [ -f "$REPO/.git" ].
#
# WHAT IS TESTED (the cases are the rules, not the source):
#   1. our pull request (given OR discovered) -> the gate does NOT abort with
#      exit 4, and the log says our_pr=<n> and "claim: VEREDICTO=OK el claim
#      es nuestro";
#   2. a pull request of ANOTHER author with a LOWER number -> the gate DOES
#      abort with exit 4 and says so: the gate does not run;
#   3. an issue that no pull request claims -> the gate does NOT abort;
#   4. UNKNOWN (GitHub can not be read) -> the gate runs anyway (what is not
#      known does not stop the work) and warns in the log;
#   5. the discovery of our pull request from the branch of the worktree
#      finds the right number.
#
# AND (2026-11-17) THE GATE AND THE RUNNER:
#   6. the gate WITHOUT the worktree of the slot FAILS (rc != 0), writes NO
#      verdict and says WHERE the worktree was expected: a verdict that
#      describes the main checkout is worse than no verdict;
#   7. the gate WITH the worktree of the slot goes on its way;
#   8. the runner does NOT take the verdict of "SHA=0d74d8ca" as the verdict
#      of the commit "0d74d8cae" (the comparison was not anchored);
#   9. the runner DOES take the verdict of "SHA=0d74d8cae" as the verdict of
#      the commit "0d74d8cae";
#   10. the runner WITHOUT arguments and with a state that has nothing
#      pending does NOTHING (rc=0): no work is not an error;
#   11. the runner WITHOUT arguments gates the pending slot OF THE STATE,
#      not the slot that was written in the script;
#   12. the same, with the pending slot coming from the "slots" of the state.
#
# THE TESTS ARE HERMETIC: the real gate NEVER compiles Rust. The BLOCK of
# the check of the claim is extracted from bin/gate.sh (the same
# technique as the block of the brake in the loop: the block between two
# anchors, run on its own) and run against:
#   * a `gh` of the tests, FIRST in the PATH: the pull requests come from
#     STUB_PRS and GitHub is never contacted;
#   * the REAL bin/claim-verify.sh (it is only READ, never modified), so the
#     verdict is the one the publisher will read;
#   * a `claim-verify.sh` of the tests for the contract between the gate and
#     it (which arguments, which exit code);
#   * their own HOME and their own worktree: the checkout of the product and
#     its worktrees are never touched.
#
# The cases 6 to 12 run the REAL bin/gate.sh (and the REAL bin/gate-runner.sh)
# against a world of their own: a `cargo` and un `gh` STUB in the HOME of the
# tests (bin/gate.sh builds its PATH out of $HOME/.cargo/bin), a gate script
# of the loop that writes the verdict and nothing else, and un gate.sh STUB
# for the runner that writes down what it was asked to gate. Nothing of the
# machine is touched: no Rust is compiled and GitHub is never contacted.
#
# Run:  bash ~/.local/share/solidcraft-orch/bin/test-gate-claim.sh
# ---------------------------------------------------------------------------
set -uo pipefail

# The script under test is found BY THE LOCATION OF THIS SUITE (not by
# $HOME): the suite has to run the same way in a harness with a temporary
# HOME and from any directory.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$(dirname "$HERE")}"
GATE_SH="${GATE_SH:-$ORCH_DIR/bin/gate.sh}"
PASS=0
FAIL=0

ok()  { PASS=$(( PASS + 1 )); printf 'ok   - %s\n' "$1"; }
bad() {
  FAIL=$(( FAIL + 1 ))
  printf 'FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '     %s\n' "$2"
  return 0
}

# --- the fixtures ------------------------------------------------------------
# The issue and the pull requests of the tests. They are FIXTURES: a rule
# that names a real issue stops being general the day that issue is closed.
ISSUE=7058
OUR_PR=4242
COMPETITOR_PR=4100
BRANCH="feature/issue-$ISSUE-fix"
SHA=0123456789abcdef0123456789abcdef01234567

# --- the scratch of the tests ------------------------------------------------
TESTDIR="$(mktemp -d "${TMPDIR:-/tmp}/gate-claim-test.XXXXXX")"
trap 'rm -rf "$TESTDIR"' EXIT
STUBBIN="$TESTDIR/bin"
mkdir -p "$STUBBIN" "$TESTDIR/home" "$TESTDIR/orch-stub/bin"

# The `gh` of the tests: the pull requests come from STUB_PRS and GitHub is
# NEVER contacted. It answers the three questions that the block asks:
#   * pr list --head <branch> --json number  -> the pull requests of that
#     branch (the DISCOVERY of our own pull request);
#   * pr list --json number,title,body --jq  -> the pull requests that
#     mention the issue (the query of claim-verify.sh);
#   * pr list --limit 1 --json number         -> "can GitHub be read?".
cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_GH_LOG:-/dev/null}"
if [ -n "${STUB_GH_FAIL:-}" ]; then
  echo "gh: could not connect to github.com" >&2
  exit 1
fi
python3 - "$@" <<'PY'
import json, os, re, sys
args = sys.argv[1:]
prs = json.loads(os.environ.get("STUB_PRS", "[]"))

def val(flag):
    return args[args.index(flag) + 1] if flag in args else None

if args[:2] == ["pr", "list"]:
    if "--head" in args:
        head = val("--head")
        for pr in prs:
            if pr.get("head") == head:
                print(pr["number"])
    elif "number,title,body" in " ".join(args):
        jq = val("--jq") or ""
        m = re.search(r"#(\d+)", jq)
        pat = re.compile(r"#%s([^0-9]|$)" % (m.group(1) if m else ""))
        for pr in prs:
            text = (pr.get("title") or "") + " " + (pr.get("body") or "")
            if pat.search(text):
                print(pr["number"])
    else:
        for pr in prs:
            print(pr["number"])
PY
exit 0
STUB
chmod 755 "$STUBBIN/gh"

# The `claim-verify.sh` of the tests: it records its arguments and answers
# with the verdict of the environment. It is the CONTRACT between the gate
# and the verifier of the claim: WHICH arguments it gets and WHAT exit code
# it answers.
cat > "$TESTDIR/orch-stub/bin/claim-verify.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CLAIM_ARGS_LOG:-/dev/null}"
echo "VEREDICTO=${STUB_CLAIM_VERDICT:-OK el claim es nuestro} (PR #${2:-?})"
exit "${STUB_CLAIM_RC:-0}"
STUB
chmod 755 "$TESTDIR/orch-stub/bin/claim-verify.sh"

# --- the block of the claim, extracted from the real gate.sh ------------------
# THE TECHNIQUE (the same one as the block of the brake in the loop): the
# block BETWEEN TWO ANCHORS of the script is taken and run on its own, so
# the real gate is never run (it compiles Rust for eight minutes).
#
# The block starts where the script resolves OUR pull request (the discovery
# from the branch of the worktree) and ends where the phases of the gate
# begin. When the script has no discovery (an older gate, before the fix)
# the block starts at the line that names the slot, so the block is still
# extracted and the tests of the fix are RED instead of missing.
BLOCK="$TESTDIR/gate-claim-block.sh"
START="$(grep -n -m1 'The pull request of ours' "$GATE_SH" | cut -d: -f1)"
[ -n "$START" ] || START="$(grep -n -m1 '^echo "gate.sh: slot=' "$GATE_SH" | cut -d: -f1)"
END="$(grep -n -m1 '^# The phases of the gate' "$GATE_SH" | cut -d: -f1)"
if [ -z "$START" ] || [ -z "$END" ] || [ "$END" -le "$START" ]; then
  printf 'FAIL %s\n' "the block of the check of the claim was extracted from $GATE_SH"
  printf '1 caso(s) fallan\n'
  exit 1
fi
sed -n "${START},$((END-1))p" "$GATE_SH" > "$BLOCK"

if [ ! -s "$BLOCK" ]; then
  printf 'FAIL %s\n' "the block of the check of the claim is not empty"
  printf '1 caso(s) fallan\n'
  exit 1
fi
# The block has to be the one of the check of the claim. A script that lost
# it is a script whose gate never checks the claim: the tests below are red.
for needle in 'claim-verify.sh' 'OUR_PR' 'gh pr list' 'exit 4'; do
  if grep -q -- "$needle" "$BLOCK"; then
    ok "the block of the claim contains: $needle"
  else
    bad "the block of the claim contains: $needle" \
        "(the block of the check of the claim was lost)"
  fi
done

# The harness of the block: it declares the variables that the block reads
# and it says "GATE-PROCEEDED" when the block did NOT abort. If the block
# aborts with exit 4 the harness never says it: that IS the difference
# between "the gate ran" and "the gate did not run".
cat > "$TESTDIR/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -uo pipefail
ISSUE="${1:-}"
SHA="${2:-}"
BASE="${3:-origin/main}"
OUR_PR="${4:-}"
REPO="${TEST_REPO:?the worktree of the test is needed}"
ORCH_DIR="${ORCH_DIR:?the orchestrator directory is needed}"
export REPO
HARNESS
cat "$BLOCK" >> "$TESTDIR/harness.sh"
cat >> "$TESTDIR/harness.sh" <<'HARNESS'
echo "GATE-PROCEEDED"
exit 0
HARNESS

# --- the worktree of the test ------------------------------------------------
# A REAL git worktree (not a directory with a .git inside: a worktree has
# .git as a FILE) so the condition of the block, [ -d "$REPO/.git" ] ||
# [ -f "$REPO/.git" ], is exercised the way it happens in the machine.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
MAIN_REPO="$TESTDIR/main"
WORKTREE="$TESTDIR/wt"
git init -q -b main "$MAIN_REPO" 2>/dev/null || git init -q "$MAIN_REPO"
git -C "$MAIN_REPO" commit -q --allow-empty -m "the base of the test" 2>/dev/null
git -C "$MAIN_REPO" worktree add -q -b "$BRANCH" "$WORKTREE" 2>/dev/null
# A directory that is NOT a git repository: the gate has no worktree there
# and the discovery of our pull request cannot happen.
NO_REPO="$TESTDIR/not-a-repo"
mkdir -p "$NO_REPO"

# --- the fixtures of the pull requests ---------------------------------------
# The pull requests of the tests: number, title, body and branch.
prs() {
  python3 - "$@" <<'PY'
import json, sys
out = []
for a in sys.argv[1:]:
    num, title, body, head = (a.split("|") + ["", "", "", ""])[:4]
    out.append({"number": int(num), "title": title, "body": body, "head": head})
print(json.dumps(out))
PY
}

# --- the run of the block ----------------------------------------------------
OUT=""
RC=0
run_block() {
  # $1 issue, $2 sha, $3 base, $4 our_pr (may be empty), $5 the repo
  local repo="$5"
  local orch="${ORCH_DIR_UNDER_TEST:-$ORCH_DIR}"
  OUT="$(env HOME="$TESTDIR/home" \
              PATH="$STUBBIN:$PATH" \
              ORCH_DIR="$orch" \
              TEST_REPO="$repo" \
              STUB_PRS="$STUB_PRS" \
              STUB_GH_FAIL="${STUB_GH_FAIL:-}" \
              STUB_CLAIM_RC="${STUB_CLAIM_RC:-}" \
              STUB_CLAIM_VERDICT="${STUB_CLAIM_VERDICT:-}" \
              CLAIM_ARGS_LOG="$TESTDIR/claim-args.log" \
              STUB_GH_LOG="$TESTDIR/gh.log" \
              bash "$TESTDIR/harness.sh" "$1" "$2" "$3" "$4" 2>&1)"
  RC=$?
}

aborted() { [ "$RC" -eq 4 ] && ! printf '%s' "$OUT" | grep -q 'GATE-PROCEEDED'; }
proceeded() { printf '%s' "$OUT" | grep -q 'GATE-PROCEEDED'; }

# =============================================================================
# THE CONTRACT BETWEEN THE GATE AND THE VERIFIER OF THE CLAIM
# (a stub of claim-verify.sh: what the gate does with each verdict)
# =============================================================================
ORCH_DIR_UNDER_TEST="$TESTDIR/orch-stub"

# --- our pull request, given: the gate asks the verifier WITH our number ---
: > "$TESTDIR/claim-args.log"
STUB_CLAIM_RC=0 STUB_CLAIM_VERDICT="OK el claim es nuestro" \
STUB_PRS="$(prs "$OUR_PR|Fix: something|Fixes #$ISSUE|$BRANCH")" \
  run_block "$ISSUE" "$SHA" origin/main "$OUR_PR" "$WORKTREE"
if [ "$RC" -eq 0 ] && proceeded; then
  ok "1. our pull request: the gate does NOT abort with exit 4"
else
  bad "1. our pull request: the gate does NOT abort with exit 4" \
      "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q "our_pr=$OUR_PR"; then
  ok "1. the log says which pull request is ours (our_pr=$OUR_PR)"
else
  bad "1. the log says which pull request is ours (our_pr=$OUR_PR)" \
      "$(printf '%s' "$OUT" | grep 'our_pr' | head -1)"
fi
if printf '%s' "$OUT" | grep -q 'claim: VEREDICTO=OK el claim es nuestro'; then
  ok "1. the log says that the claim is ours (VEREDICTO=OK el claim es nuestro)"
else
  bad "1. the log says that the claim is ours (VEREDICTO=OK el claim es nuestro)" \
      "$(printf '%s' "$OUT" | grep 'claim:' | head -1)"
fi
if [ "$(cat "$TESTDIR/claim-args.log" 2>/dev/null)" = "$ISSUE $OUR_PR" ]; then
  ok "1. the verifier of the claim is told the issue AND our pull request"
else
  bad "1. the verifier of the claim is told the issue AND our pull request" \
      "got: $(cat "$TESTDIR/claim-args.log" 2>/dev/null)"
fi

# --- the claim is LOST: the gate aborts with exit 4 and says so -------------
STUB_CLAIM_RC=1 STUB_CLAIM_VERDICT="PERDIDO el PR #$OUR_PR perdio contra el #$COMPETITOR_PR" \
STUB_PRS="$(prs "$OUR_PR|Fix: something|Fixes #$ISSUE|$BRANCH")" \
  run_block "$ISSUE" "$SHA" origin/main "$OUR_PR" "$WORKTREE"
if aborted; then
  ok "2. the claim is lost: the gate aborts with exit 4"
else
  bad "2. the claim is lost: the gate aborts with exit 4" \
      "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q "el gate NO se corre"; then
  ok "2. the log says that the gate does NOT run"
else
  bad "2. the log says that the gate does NOT run" \
      "$(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# --- UNKNOWN (GitHub can not be read): the gate runs anyway -----------------
STUB_CLAIM_RC=2 STUB_CLAIM_VERDICT="ERROR no se pudo leer los PRs" \
STUB_PRS="$(prs "$OUR_PR|Fix: something|Fixes #$ISSUE|$BRANCH")" \
  run_block "$ISSUE" "$SHA" origin/main "$OUR_PR" "$WORKTREE"
if [ "$RC" -eq 0 ] && proceeded; then
  ok "4. UNKNOWN: the gate runs anyway (what is not known does not stop the work)"
else
  bad "4. UNKNOWN: the gate runs anyway (what is not known does not stop the work)" \
      "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q 'no se pudo verificar el claim'; then
  ok "4. UNKNOWN: the log warns that the claim could not be verified"
else
  bad "4. UNKNOWN: the log warns that the claim could not be verified" \
      "$(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# =============================================================================
# THE REAL VERIFIER OF THE CLAIM (the real claim-verify.sh, only read)
# =============================================================================
ORCH_DIR_UNDER_TEST="$ORCH_DIR"

# --- 1. our pull request, DISCOVERED from the branch of the worktree --------
STUB_PRS="$(prs "$OUR_PR|Fix: something|Fixes #$ISSUE|$BRANCH")" \
  run_block "$ISSUE" "$SHA" origin/main "" "$WORKTREE"
if [ "$RC" -eq 0 ] && proceeded; then
  ok "1. our pull request, discovered from the branch: the gate does NOT abort"
else
  bad "1. our pull request, discovered from the branch: the gate does NOT abort" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q "our_pr=$OUR_PR"; then
  ok "5. the discovery finds OUR pull request from the branch of the worktree"
else
  bad "5. the discovery finds OUR pull request from the branch of the worktree" \
      "$(printf '%s' "$OUT" | grep 'our_pr' | head -1)"
fi
if printf '%s' "$OUT" | grep -q 'claim: VEREDICTO=OK el claim es nuestro'; then
  ok "1. our own pull request is NOT read as the competitor that took the issue"
else
  bad "1. our own pull request is NOT read as the competitor that took the issue" \
      "$(printf '%s' "$OUT" | grep 'claim:' | head -1)"
fi

# --- 1b. the same, but WITHOUT our pull request: the old bug ---------------
# Without the number of our pull request, the verifier reads our OWN pull
# request as "the competitor that already claims the issue" and the gate
# aborts with exit 4 in EVERY pull request of ours.
STUB_PRS="$(prs "$OUR_PR|Fix: something|Fixes #$ISSUE|$BRANCH")" \
  run_block "$ISSUE" "$SHA" origin/main "" "$NO_REPO"
if aborted; then
  ok "1b. without our pull request the claim reads ours as a competitor (the bug)"
else
  bad "1b. without our pull request the claim reads ours as a competitor (the bug)" \
      "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi

# --- 2. a pull request of ANOTHER author with a LOWER number ---------------
STUB_PRS="$(prs "$COMPETITOR_PR|Fix: the same thing (another author)|Fixes #$ISSUE|other-branch" \
                "$OUR_PR|Fix: something|Fixes #$ISSUE|$BRANCH")" \
  run_block "$ISSUE" "$SHA" origin/main "$OUR_PR" "$WORKTREE"
if aborted; then
  ok "2. a competitor with a LOWER number: the gate aborts with exit 4"
else
  bad "2. a competitor with a LOWER number: the gate aborts with exit 4" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q "ATENCION: el issue $ISSUE ya lo reclama otro PR"; then
  ok "2. the log says that the issue is claimed by another pull request"
else
  bad "2. the log says that the issue is claimed by another pull request" \
      "$(printf '%s' "$OUT" | grep 'ATENCION' | head -1)"
fi

# --- 3. an issue that no pull request claims --------------------------------
STUB_PRS="$(prs "$OUR_PR|Docs: something|documentation only|$BRANCH")" \
  run_block "$ISSUE" "$SHA" origin/main "$OUR_PR" "$WORKTREE"
if [ "$RC" -eq 0 ] && proceeded; then
  ok "3. an issue that no pull request claims: the gate does NOT abort"
else
  bad "3. an issue that no pull request claims: the gate does NOT abort" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# --- 4. UNKNOWN: GitHub can not be read -------------------------------------
STUB_GH_FAIL=1 STUB_PRS="$(prs "$OUR_PR|Fix: something|Fixes #$ISSUE|$BRANCH")" \
  run_block "$ISSUE" "$SHA" origin/main "$OUR_PR" "$WORKTREE"
if [ "$RC" -eq 0 ] && proceeded; then
  ok "4. UNKNOWN (GitHub can not be read): the gate runs anyway"
else
  bad "4. UNKNOWN (GitHub can not be read): the gate runs anyway" \
      "rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q 'no se pudo verificar el claim'; then
  ok "4. UNKNOWN (GitHub can not be read): the log warns about it"
else
  bad "4. UNKNOWN (GitHub can not be read): the log warns about it" \
      "$(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"
fi

# --- 5. the discovery asks GitHub about the branch of the worktree ----------
: > "$TESTDIR/gh.log"
STUB_PRS="$(prs "$OUR_PR|Fix: something|Fixes #$ISSUE|$BRANCH")" \
  run_block "$ISSUE" "$SHA" origin/main "" "$WORKTREE"
if grep -q -- "--head $BRANCH" "$TESTDIR/gh.log"; then
  ok "5. the discovery asks GitHub about the branch of the worktree"
else
  bad "5. the discovery asks GitHub about the branch of the worktree" \
      "$(head -3 "$TESTDIR/gh.log" 2>/dev/null | tr '\n' ' ')"
fi
if grep -q 'pr list' "$TESTDIR/gh.log" 2>/dev/null && grep -q "pr list --repo tangency-labs/solidcraft" "$TESTDIR/gh.log"; then
  ok "the gh of the tests answered (GitHub was never contacted)"
else
  bad "the gh of the tests answered (GitHub was never contacted)" \
      "$(head -3 "$TESTDIR/gh.log" 2>/dev/null | tr '\n' ' ')"
fi

# --- the control: the worktree of the test has .git as a FILE ---------------
if [ -f "$WORKTREE/.git" ] && [ ! -d "$WORKTREE/.git" ]; then
  ok "the worktree of the test has .git as a FILE (like a real worktree)"
else
  bad "the worktree of the test has .git as a FILE (like a real worktree)" \
      "$(ls -ld "$WORKTREE/.git" 2>&1)"
fi

# =============================================================================
# THE GATE WITHOUT THE WORKTREE OF THE SLOT, THE SHA ANCHORED AND THE PENDING
# SLOTS OF THE STATE (2026-11-17)
#
# WHAT IS TESTED HERE (the cases are the rules, not the source):
#   6. the gate WITHOUT the worktree of the slot FAILS (rc != 0) and writes
#      NO verdict: a verdict that describes another tree (the main checkout)
#      is worse than no verdict at all;
#   7. the gate WITH the worktree of the slot goes on its way;
#   8. the runner does NOT take the verdict of "SHA=0d74d8ca" as the verdict
#      of the commit "0d74d8cae" (the comparison was not anchored);
#   9. the runner DOES take the verdict of "SHA=0d74d8cae" as the verdict of
#      the commit "0d74d8cae";
#   10. the runner WITHOUT arguments and with a state that has nothing
#      pending does NOTHING (rc=0): no work is not an error;
#   11. the runner WITHOUT arguments gates the pending slot OF THE STATE,
#      not the slot that was written in the script;
#   12. the same, with the pending slot coming from the "slots" of the state.
#
# THE TESTS ARE HERMETIC: the real gate NEVER compiles Rust (the cargo of
# the tests is a STUB in the HOME of the tests, because bin/gate.sh builds
# its own PATH out of $HOME/.cargo/bin) and the gate.sh of the runner is a
# STUB that writes down what it was asked to gate. GitHub is never
# contacted: the gh of the tests is a stub that fails.
# =============================================================================

GATE_SH="${GATE_SH:-$ORCH_DIR/bin/gate.sh}"
RUNNER_SH="${RUNNER_SH:-$HERE/gate-runner.sh}"

# --- the world of the gate: its own orchestrator, its own loop ---------------
GATEROOT="$TESTDIR/gateworld"
GATEORCH="$GATEROOT/orch"
GATELOOP="$GATEROOT/loop"
GATEHOME="$GATEROOT/home"
GATETARGETS="$GATEROOT/targets"
GATEWT="$GATEROOT/worktrees"
mkdir -p "$GATEORCH/bin" "$GATEORCH/logs" "$GATELOOP/bin" "$GATELOOP/gates" \
         "$GATEHOME/.cargo/bin" "$GATETARGETS" "$GATEWT" \
         "$GATEROOT/checkout-principal"

# The cargo of the tests: the gate compiles Rust for 8+ minutes and the
# machine is shared. The stub says "it compiled" and does nothing else.
cat > "$GATEHOME/.cargo/bin/cargo" <<'STUB'
#!/usr/bin/env bash
echo "cargo $* (STUB de los tests)"
exit 0
STUB
chmod 755 "$GATEHOME/.cargo/bin/cargo"

# The gh of the tests: GitHub is NEVER contacted.
cat > "$GATEHOME/.cargo/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh: los tests no contactan GitHub" >&2
exit 1
STUB
chmod 755 "$GATEHOME/.cargo/bin/gh"

# The helpers of the gate: the target dir of the slot, los jobs de cargo, el
# token del build slot, el verificador del claim y el veredicto efectivo.
cat > "$GATEORCH/bin/slot-target-dir.sh" <<'STUB'
#!/usr/bin/env bash
slot=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slot) slot="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo "${GATE_TARGETS:-$PWD}/slot-$slot"
STUB
cat > "$GATEORCH/bin/cargo-jobs.sh" <<'STUB'
#!/usr/bin/env bash
echo 2
STUB
cat > "$GATEORCH/bin/build-slot.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --take) echo "token-de-los-tests" ;;
esac
exit 0
STUB
cat > "$GATEORCH/bin/claim-verify.sh" <<'STUB'
#!/usr/bin/env bash
echo "VEREDICTO=OK el claim es nuestro"
exit 0
STUB
cat > "$GATEORCH/bin/gate-baseline.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod 755 "$GATEORCH/bin/"*.sh

# El gate del loop (el que de verdad compila) es un STUB: escribe el
# veredicto del slot y nada mas.
cat > "$GATELOOP/bin/gate-quick.sh" <<'STUB'
#!/usr/bin/env bash
slot=""
rest=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slot) slot="$2"; shift 2 ;;
    *) rest="$rest $1"; shift ;;
  esac
done
set -- $rest
base="${1:-}"
sha="${2:-}"
mkdir -p "$LOOP_DIR/gates/$slot"
{
  echo "GATE_STATUS=finished"
  echo "VERDICT=VERDE-SCOPE"
  echo "SHA=$sha"
  echo "BASE=$base"
} > "$LOOP_DIR/gates/$slot/scope.verdict"
exit 0
STUB
chmod 755 "$GATELOOP/bin/gate-quick.sh"

# --- the run of the gate ----------------------------------------------------
GATE_OUT=""
GATE_RC=0
run_gate() {
  # $1 issue, $2 sha, $3 el directorio de los worktrees
  GATE_OUT="$(env HOME="$GATEHOME" \
                  ORCH_DIR="$GATEORCH" \
                  LOOP_DIR="$GATELOOP" \
                  WORKTREES_DIR="$3" \
                  SOLIDCRAFT_REPO="$GATEROOT/checkout-principal" \
                  GATE_TARGETS="$GATETARGETS" \
                  bash "$GATE_SH" "$1" "$2" 2>&1)"
  GATE_RC=$?
}

# --- 6. the gate WITHOUT the worktree of the slot --------------------------
rm -rf "$GATELOOP/gates"
mkdir -p "$GATELOOP/gates"
EMPTY_WT="$GATEROOT/worktrees-vacias"
mkdir -p "$EMPTY_WT"
run_gate "$ISSUE" "$SHA" "$EMPTY_WT"
if [ "$GATE_RC" -ne 0 ]; then
  ok "6. the gate without the worktree of the slot FAILS (rc=$GATE_RC)"
else
  bad "6. the gate without the worktree of the slot FAILS (rc=$GATE_RC)" \
      "the gate compiles the main checkout and writes the verdict of another tree"
fi
if [ -z "$(find "$GATELOOP/gates" -name scope.verdict 2>/dev/null)" ]; then
  ok "6. the gate without the worktree of the slot writes NO verdict"
else
  bad "6. the gate without the worktree of the slot writes NO verdict" \
      "$(find "$GATELOOP/gates" -name scope.verdict 2>/dev/null | tr '\n' ' ')"
fi
if printf '%s' "$GATE_OUT" | grep -q "issue-$ISSUE"; then
  ok "6. the message says WHERE the worktree of the slot was expected"
else
  bad "6. the message says WHERE the worktree of the slot was expected" \
      "$(printf '%s' "$GATE_OUT" | tail -3 | tr '\n' ' ')"
fi

# --- 7. the gate WITH the worktree of the slot: it goes on its way --------
rm -rf "$GATELOOP/gates"
mkdir -p "$GATELOOP/gates"
ln -sfn "$WORKTREE" "$GATEWT/issue-$ISSUE"
run_gate "$ISSUE" "$SHA" "$GATEWT"
if [ "$GATE_RC" -eq 0 ] && [ -f "$GATELOOP/gates/$ISSUE/scope.verdict" ]; then
  ok "7. the gate with the worktree of the slot goes on its way (rc=0, verdict written)"
else
  bad "7. the gate with the worktree of the slot goes on its way" \
      "rc=$GATE_RC $(printf '%s' "$GATE_OUT" | tail -3 | tr '\n' ' ')"
fi

# =============================================================================
# EL RUNNER: EL SHA ANCHORADO (F2) Y LOS SLOTS PENDIENTES DEL ESTADO (F3)
# =============================================================================
RUNROOT="$TESTDIR/runnerworld"
RUNORCH="$RUNROOT/orch"
RUNLOOP="$RUNROOT/loop"
RUNWT="$RUNROOT/worktrees"
RUNLOG="$RUNROOT/gate-calls.log"
mkdir -p "$RUNORCH/bin" "$RUNORCH/logs" "$RUNLOOP/gates" "$RUNWT"
: > "$RUNLOG"
mkdir -p "$RUNWT/issue-4712" "$RUNWT/issue-9999" "$RUNWT/issue-8888" "$RUNWT/issue-10159"

# El gate.sh del runner es un STUB que escribe lo que se le pidio gatear: el
# de verdad compila Rust.
cat > "$RUNORCH/bin/gate.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "${1:-}" "${2:-}" >> "${RUNNER_LOG:-/dev/null}"
exit 0
STUB
chmod 755 "$RUNORCH/bin/gate.sh"
# El accessor del estado es el REAL (solo se lee): el runner tiene que leer
# el estado por la misma puerta que todos los demás scripts.
cp "$HERE/orch-state.sh" "$RUNORCH/bin/orch-state.sh"
chmod 755 "$RUNORCH/bin/orch-state.sh"

RUNNER_OUT=""
RUNNER_RC=0
run_runner() {
  RUNNER_OUT="$(env ORCH_DIR="$RUNORCH" \
                     LOOP_DIR="$RUNLOOP" \
                     WORKTREES_DIR="$RUNWT" \
                     RUNNER_LOG="$RUNLOG" \
                     bash "$RUNNER_SH" "$@" 2>&1)"
  RUNNER_RC=$?
}

# --- 8. the verdict of ANOTHER commit is not served ------------------------
# The sha of the verdict has to be THE SAME commit that is asked for. The
# comparison was not anchored: the pattern "SHA=0d74d8ca" is found inside
# the line "SHA=0d74d8cae" of a verdict of ANOTHER commit, and the runner
# took that verdict as the gate of the commit it was asked for.
mkdir -p "$RUNLOOP/gates/4712"
cat > "$RUNLOOP/gates/4712/scope.verdict" <<'EOF'
GATE_STATUS=finished
VERDICT=VERDE-SCOPE
SHA=0d74d8ca
EOF
: > "$RUNLOG"
run_runner 4712 0d74d8cae
if grep -q '^4712 0d74d8cae$' "$RUNLOG"; then
  ok "8. the runner does NOT take the verdict of SHA=0d74d8ca as the one of 0d74d8cae"
else
  bad "8. the runner does NOT take the verdict of SHA=0d74d8ca as the one of 0d74d8cae" \
      "the runner took the verdict of another commit as served"
fi

# --- 8b. the same, al reves: el veredicto del commit largo y el pedido del
#         corto (este es el caso que la comparacion sin anclar rompia) ------
cat > "$RUNLOOP/gates/4712/scope.verdict" <<'EOF'
GATE_STATUS=finished
VERDICT=VERDE-SCOPE
SHA=0d74d8cae
EOF
: > "$RUNLOG"
run_runner 4712 0d74d8ca
if grep -q '^4712 0d74d8ca$' "$RUNLOG"; then
  ok "8b. the runner does NOT take the verdict of SHA=0d74d8cae as the one of 0d74d8ca"
else
  bad "8b. the runner does NOT take the verdict of SHA=0d74d8cae as the one of 0d74d8ca" \
      "the runner took the verdict of another commit as served"
fi

# --- 9. the verdict of THIS commit is served ------------------------------
cat > "$RUNLOOP/gates/4712/scope.verdict" <<'EOF'
GATE_STATUS=finished
VERDICT=VERDE-SCOPE
SHA=0d74d8cae
EOF
: > "$RUNLOG"
run_runner 4712 0d74d8cae
if [ ! -s "$RUNLOG" ]; then
  ok "9. the runner takes the verdict of SHA=0d74d8cae as the one of 0d74d8cae (served)"
else
  bad "9. the runner takes the verdict of SHA=0d74d8cae as the one of 0d74d8cae (served)" \
      "the runner gateo de nuevo: $(cat "$RUNLOG")"
fi

# --- 10. no arguments and nothing pending: it does NOTHING ----------------
cat > "$RUNORCH/state.json" <<'EOF'
{
  "gates": {
    "4712": {"issue": 4712, "sha": "0d74d8cae", "status": "finished"}
  },
  "slots": {}
}
EOF
: > "$RUNLOG"
run_runner
if [ "$RUNNER_RC" -eq 0 ] && [ ! -s "$RUNLOG" ]; then
  ok "10. the runner without arguments and with nothing pending does NOTHING (rc=0)"
else
  bad "10. the runner without arguments and with nothing pending does NOTHING (rc=0)" \
      "rc=$RUNNER_RC calls: $(cat "$RUNLOG" | tr '\n' ' ')"
fi

# --- 11. no arguments and a pending slot: it gates THAT slot ---------------
cat > "$RUNORCH/state.json" <<'EOF'
{
  "gates": {
    "9999": {"issue": 9999, "sha": "abc123def456", "status": "pending"}
  },
  "slots": {}
}
EOF
: > "$RUNLOG"
run_runner
if grep -q '^9999 abc123def456$' "$RUNLOG"; then
  ok "11. the runner without arguments gates the pending slot OF THE STATE (9999)"
else
  bad "11. the runner without arguments gates the pending slot OF THE STATE (9999)" \
      "calls: $(cat "$RUNLOG" | tr '\n' ' ')"
fi
if ! grep -q '^10159 ' "$RUNLOG"; then
  ok "11. the runner without arguments does NOT gate the slot written in the script (10159)"
else
  bad "11. the runner without arguments does NOT gate the slot written in the script (10159)" \
      "the runner gateo el slot que estaba escrito en el codigo"
fi

# --- 12. the pending slot can come from the "slots" of the state ------------
cat > "$RUNORCH/state.json" <<'EOF'
{
  "gates": {},
  "slots": {
    "3": {"issue": 8888, "sha": "beefcafe1234", "status": "running"}
  }
}
EOF
: > "$RUNLOG"
run_runner
if grep -q '^8888 beefcafe1234$' "$RUNLOG"; then
  ok "12. the runner without arguments gates the pending slot of the 'slots' of the state"
else
  bad "12. the runner without arguments gates the pending slot of the 'slots' of the state" \
      "calls: $(cat "$RUNLOG" | tr '\n' ' ')"
fi

TOTAL=$(( PASS + FAIL ))
printf '%s casos, %s fallan\n' "$TOTAL" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf 'todos los casos pasan\n'
  exit 0
fi
printf '%s caso(s) fallan\n' "$FAIL"
exit 1
