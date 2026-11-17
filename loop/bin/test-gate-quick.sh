#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Test bank of gate-quick.sh. It compiles NOTHING and touches no network: the
# cargo of the PATH is a stub that answers `cargo metadata` and prints a
# synthetic log, and the repository is a fake one made here.
#
#   bash bin/test-gate-quick.sh
#
# The cases of the legacy file (the format did not change):
#   1. the change touches the whole workspace -> SKIP, workspace
#   2. no code changed                          -> SKIP, empty
#   3. the tests pass                           -> VERDE-PARCIAL, 0 new failures
#   4. a test fails                             -> ROJO-PARCIAL, 1 new failure
#   5. a test of the baseline fails             -> NOT a new failure
#   6. clippy fails                            -> ROJO-PARCIAL, 1 new failure
#   7. the budget runs out                     -> failed, ROJO-PARCIAL
#   8. the help does nothing
#
# The cases of the SCOPED verdict (gates/<slot>/scope.verdict, the
# authoritative one):
#   9. a green scope run  -> VERDE-SCOPE, all the checks ok, no PUBLISHABLE
#  10. the verdict is in the slot of the scope and nowhere else
#  11. a failing test    -> ROJO-SCOPE, the name of the failure
#  12. a failing clippy  -> ROJO-SCOPE, clippy:fail
#  13. a failing fmt     -> ROJO-SCOPE, fmt:fail
#  14. a failing layers  -> ROJO-SCOPE, layers:fail
#  15. the whole workspace -> SKIP
#  16. no code changed      -> SKIP
#  17. the scope of a slot does not touch the file of another one
#  18. the budget runs out  -> ROJO-SCOPE
#
# The cases of the phases that are cut:
#  19. the compilation of the scope is bounded (one call, all the packages)
#  20. the lock of the build directory is taken: the scope is deferred
#  21. the orphans of a dead phase die with it
#  22. the timeout of the tests DEFERS the scope, it does not redden it
#  23. a real failure before the cut is still red
#  24. the cut of the linter is not a red gate
#  25. the knob of the dependents: OFF -> the owners only, ON -> the owners and the dependents
#
# The cases of the TARGET DIRECTORY of the slot (one directory per slot):
#  26. the slot compiles in <base>/slot-<slot>
#  27. a run without a slot compiles in <base>/noslot
#  28. the base is never the target directory of a run
#  29. the deferral NAMES the slot and the directory it waits for
#  30. the lock of the slot: two runs of the same slot do not run at the
#      same time, and two DIFFERENT slots do
# 31. the layout works without the helper deployed (the fallback)
#
# The case of the DESCRIPTORS of the lock:
# 33. the children of the gate do NOT inherit the descriptors of the lock: an
#     orphan does not keep the lock taken (a slot that never gates again)
#
# The exit code is 1 when a case fails.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${GATE:-$SCRIPT_DIR/gate-quick.sh}"
# The real affected.py is copied into the fake repository: the cases exercise
# the real scope selection, not a stub of it.
REAL_REPO="${REPO:-/home/user/solidcraft}"
REAL_AFFECTED="$REAL_REPO/scripts/ci/affected.py"

if [ ! -f "$GATE" ]; then
  echo "FALLO - gate-quick.sh is not found: $GATE"
  exit 1
fi
if [ ! -f "$REAL_AFFECTED" ]; then
  echo "FALLO - the real affected.py is not found: $REAL_AFFECTED"
  exit 1
fi

TMP_TEST="$(mktemp -d "${TMPDIR:-/tmp}/test-gate-quick.XXXXXX" 2>/dev/null)" || {
  echo "FALLO - a temporary directory cannot be created"
  exit 1
}
cleanup() { rm -rf "$TMP_TEST"; }
trap cleanup EXIT

REPO_TEST="$TMP_TEST/repo"
LOOP_TEST="$TMP_TEST/loop"
STUB_DIR="$TMP_TEST/bin"
BASELINE_TEST="$TMP_TEST/baseline-failures.txt"
mkdir -p "$REPO_TEST" "$LOOP_TEST" "$STUB_DIR" "$LOOP_TEST/bin"
# The helper of the layout of the target directories is DEPLOYED in the
# loop directory: the gate looks for it there. The cases that need the
# fallback remove it.
if [ -f "$SCRIPT_DIR/gate-target-dir.sh" ]; then
  cp "$SCRIPT_DIR/gate-target-dir.sh" "$LOOP_TEST/bin/gate-target-dir.sh"
  chmod +x "$LOOP_TEST/bin/gate-target-dir.sh"
fi

# --- the stub of cargo ----------------------------------------------------
cat > "$STUB_DIR/cargo" <<'STUB'
#!/usr/bin/env bash
# A fake cargo: it compiles nothing and runs nothing.
set -uo pipefail
# The environment of the call is recorded when the case asks for it: the gate
# has to bound the compilation (CARGO_BUILD_JOBS), and that is only visible
# from the inside of cargo. The target directory is recorded too: every slot
# compiles in a directory of its own and the cases have to prove it.
if [ -n "${STUB_ENV_LOG:-}" ]; then
  printf '%s\t%s\t%s\n' "${1:-}" "${CARGO_BUILD_JOBS:-<unset>}" \
    "${CARGO_TARGET_DIR:-<unset>}" >> "$STUB_ENV_LOG"
fi
case "${1:-}" in
  metadata)
    # The workspace is the current directory: affected.py runs cargo metadata
    # from the root of the repository.
    # The sleep knob makes the computation of the scope slow: the gate has
    # to skip the check of the workspace when the time that is left does not
    # pay for it (the case 14d).
    if [ -n "${STUB_METADATA_SLEEP:-}" ]; then
      sleep "${STUB_METADATA_SLEEP}"
    fi
    root="$(pwd)"
    printf '{"workspace_root":"%s","packages":[' "$root"
    printf '{"name":"alpha","manifest_path":"%s/crates/alpha/Cargo.toml",' "$root"
    printf '"targets":[{"kind":["lib"]}],"dependencies":[]},'
    printf '{"name":"beta","manifest_path":"%s/crates/beta/Cargo.toml",' "$root"
    printf '"targets":[{"kind":["lib"]}],'
    if [ -n "${STUB_BETA_DEPENDS_ALPHA:-}" ]; then
      # The edge of a dependent: beta USES alpha. The case 25 needs a
      # package that depends on the one that holds the change.
      printf '"dependencies":[{"name":"alpha","path":"%s/crates/alpha"}]}],' "$root"
    else
      printf '"dependencies":[]}],'
    fi
    printf '"workspace_members":[],"target_directory":"%s/target","version":1}\n' "$root"
    exit 0
    ;;
  clippy)
    # `cargo clippy --version` is the probe of the gate: it asks whether the
    # linter is there, not whether the code passes.
    if [ "${2:-}" = "--version" ]; then
      exit 0
    fi
    # The sleep knob makes the linter LATE: the gate cuts it and the case
    # proves that a cut of the linter is not a red gate.
    if [ -n "${STUB_CLIPPY_SLEEP:-}" ]; then
      sleep "${STUB_CLIPPY_SLEEP}"
    fi
    exit "${STUB_CLIPPY_EXIT:-0}"
    ;;
  fmt)
    # `cargo fmt --all -- --check`
    exit "${STUB_FMT_EXIT:-0}"
    ;;
  xtask)
    # `cargo xtask layers`
    exit "${STUB_LAYERS_EXIT:-0}"
    ;;
  run)
    # `cargo run --profile ci --package xtask -- layers`: the gate compiles the
    # xtask in the ci profile (the alias `cargo xtask` compiles in dev, and a
    # dev build of the world cost 20 GB per slot). The stub has to answer for
    # this form too, or the case of a failing layers would run the REAL
    # xtask and the test would say nothing.
    # The form is: run --profile ci --package xtask -- layers
    #                $1  $2       $3  $4        $5    $6  $7
    if [ "${2:-}" = "--profile" ] && [ "${4:-}" = "--package" ] \
       && [ "${5:-}" = "xtask" ]; then
      exit "${STUB_LAYERS_EXIT:-0}"
    fi
    exit 0
    ;;
  check)
    # `cargo check --workspace --all-targets --profile ci --locked`
    if [ -n "${STUB_CHECK_SLEEP:-}" ]; then
      sleep "${STUB_CHECK_SLEEP}"
    fi
    exit "${STUB_CHECK_EXIT:-0}"
    ;;
  nextest)
    # `cargo nextest run ...`: the log of the runner is the one of the case.
    log="${STUB_NEXTEST_LOG:-${STUB_TEST_LOG:-}}"
    if [ -n "$log" ] && [ -f "$log" ]; then
      cat "$log"
    fi
    exit "${STUB_NEXTEST_EXIT:-${STUB_TEST_EXIT:-0}}"
    ;;
  test)
    if [ -n "${STUB_TEST_LOG:-}" ] && [ -f "${STUB_TEST_LOG}" ]; then
      cat "${STUB_TEST_LOG}"
    fi
    exit "${STUB_TEST_EXIT:-0}"
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/cargo"

# --- the fake repository --------------------------------------------------
mkdir -p "$REPO_TEST/crates/alpha/src" "$REPO_TEST/crates/beta/src" \
  "$REPO_TEST/docs" "$REPO_TEST/scripts/ci"
cp "$REAL_AFFECTED" "$REPO_TEST/scripts/ci/affected.py"
printf 'pub fn alpha() {}\n' > "$REPO_TEST/crates/alpha/src/lib.rs"
printf 'pub fn beta() {}\n' > "$REPO_TEST/crates/beta/src/lib.rs"
printf '# docs\n' > "$REPO_TEST/docs/README.md"
printf '# workspace\n' > "$REPO_TEST/Cargo.toml"
git -C "$REPO_TEST" init -q -b main
git -C "$REPO_TEST" add -A
git -C "$REPO_TEST" -c user.name=gate -c user.email=gate@example.invalid \
  commit -qm "base"
BASE_SHA="$(git -C "$REPO_TEST" rev-parse HEAD)"

commit_change() {
  # commit_change <path> <content> -> the sha of the new commit
  printf '%s\n' "$2" > "$REPO_TEST/$1"
  git -C "$REPO_TEST" add -A
  git -C "$REPO_TEST" -c user.name=gate -c user.email=gate@example.invalid \
    commit -qm "change: $1" >/dev/null
  git -C "$REPO_TEST" rev-parse HEAD
}

# --- the baseline of the bank ---------------------------------------------
cat > "$BASELINE_TEST" <<'BASE'
# The known failures of the test bank.
alpha::tests::known_failure  # a failure that is already known
BASE

# --- the synthetic libtest logs -------------------------------------------
cat > "$TMP_TEST/green.log" <<'LOG'
running 2 tests
test tests::alpha_ok ... ok
test tests::other ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
LOG

cat > "$TMP_TEST/red.log" <<'LOG'
running 2 tests
test tests::good ... ok
test tests::boom ... FAILED

failures:

---- tests::boom stdout ----
thread 'tests::boom' panicked at crates/alpha/src/lib.rs:10:5:
assertion failed: false

failures:
    tests::boom

test result: FAILED. 1 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
LOG

cat > "$TMP_TEST/baseline.log" <<'LOG'
running 1 test
test tests::known_failure ... FAILED

failures:

---- tests::known_failure stdout ----
thread 'tests::known_failure' panicked at crates/alpha/src/lib.rs:20:5:
assertion failed: false

failures:
    tests::known_failure

test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
LOG

# The logs of nextest, the runner the scoped gate uses: one process per test
# and a line per test.
cat > "$TMP_TEST/nextest-green.log" <<'LOG'
    Starting 2 tests across 1 binary
        PASS [   0.005s] solidcraft-alpha tests::alpha_ok
        PASS [   0.006s] solidcraft-alpha tests::other

    Summary [   0.006s] 2 tests run: 2 passed, 0 failed, 0 skipped
LOG

cat > "$TMP_TEST/nextest-red.log" <<'LOG'
    Starting 1 test across 1 binary
        FAIL [   0.029s] (1/1) solidcraft-kernel boolean_props::scale_invariant
--- STDOUT:              solidcraft-kernel boolean_props::scale_invariant ---
thread 'boolean_props::scale_invariant' panicked at crates/kernel/src/lib.rs:10:5:
assertion failed: false
--- STDERR:              solidcraft-kernel boolean_props::scale_invariant ---

    Summary [   0.029s] 1 test run: 0 passed, 1 failed, 0 skipped
LOG

# --- the runner of a case -------------------------------------------------
FAILURES=0

field() {
  # field <key> : the value of a key of the verdict file
  sed -n "s/^$1=//p" "$LOOP_TEST/gate.quick.verdict" 2>/dev/null | head -1
}

scope_field() {
  # scope_field <slot> <key> : the value of a key of the scope verdict
  sed -n "s/^$2=//p" "$LOOP_TEST/gates/$1/scope.verdict" 2>/dev/null | head -1
}

run_gate() {
  # run_gate <base> <sha> [slot] ; the stub log and its exit code are in the
  # environment
  rm -f "$LOOP_TEST/gate.quick.verdict"
  # The gates directory is kept when the case asks for it: the case 20 holds
  # the lock of the build directory in a file of that directory, and the lock
  # has to survive until the gate asks for it.
  if [ "${KEEP_GATES:-0}" != "1" ]; then
    rm -rf "$LOOP_TEST/gates"
  fi
  local slot_args=()
  if [ -n "${3:-}" ]; then
    slot_args=(--slot "$3")
  fi
  REPO="$REPO_TEST" \
  LOOP_DIR="$LOOP_TEST" \
  BASELINE_FAILURES="$BASELINE_TEST" \
  GATE_QUICK_TARGET_DIR="$TMP_TEST/gate-target" \
  GATE_QUICK_TIMEOUT_MIN="${GATE_QUICK_TIMEOUT_MIN:-5}" \
  STUB_TEST_LOG="${STUB_TEST_LOG:-}" \
  STUB_TEST_EXIT="${STUB_TEST_EXIT:-0}" \
  STUB_NEXTEST_LOG="${STUB_NEXTEST_LOG:-}" \
  STUB_NEXTEST_EXIT="${STUB_NEXTEST_EXIT:-}" \
  STUB_CLIPPY_EXIT="${STUB_CLIPPY_EXIT:-0}" \
  STUB_CLIPPY_SLEEP="${STUB_CLIPPY_SLEEP:-}" \
  GATE_CHECK_WORKSPACE="${GATE_CHECK_WORKSPACE:-1}" \
  STUB_FMT_EXIT="${STUB_FMT_EXIT:-0}" \
  STUB_LAYERS_EXIT="${STUB_LAYERS_EXIT:-0}" \
  STUB_CHECK_EXIT="${STUB_CHECK_EXIT:-0}" \
  STUB_CHECK_SLEEP="${STUB_CHECK_SLEEP:-}" \
  STUB_METADATA_SLEEP="${STUB_METADATA_SLEEP:-}" \
  STUB_BETA_DEPENDS_ALPHA="${STUB_BETA_DEPENDS_ALPHA:-}" \
  NEXTEST_INCLUDE_DEPENDENTS="${NEXTEST_INCLUDE_DEPENDENTS:-0}" \
  PATH="$STUB_DIR:$PATH" \
    bash "$GATE" ${slot_args[@]+"${slot_args[@]}"} "$1" "$2" \
      >"$TMP_TEST/out.txt" 2>"$TMP_TEST/err.txt"
  GATE_RC=$?
}

check_case() {
  # check_case <label> <want status> <want verdict> <want scope> <want failures>
  local label="$1" want_status="$2" want_verdict="$3" want_scope="$4"
  local want_failures="$5"
  local got_status got_verdict got_scope got_failures got_publishable
  got_status="$(field GATE_STATUS)"
  got_verdict="$(field VERDICT)"
  # The gate adds solidcraft-cli to the scope so the feature smlib (on by
  # default in the cli) unifies with the crates under test: without SMLib
  # every geometric test fails with "this build has no SMLib" (2210 false
  # failures in one gate). The added package is NOT part of the scope of the
  # change, so it does not take part in the comparison here; a case of its own
  # checks that it IS there.
  got_scope="$(field SCOPE | sed 's/solidcraft-cli//; s/[[:space:]]*$//; s/^[[:space:]]*//' | tr -s ' ')"
  got_failures="$(field NEW_FAILURES)"
  got_publishable="$(field PUBLISHABLE)"
  if [ "$GATE_RC" -ne 0 ]; then
    echo "FALLO - $label: gate-quick.sh exited with $GATE_RC"
    sed 's/^/    /' "$TMP_TEST/err.txt" | head -5
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [ "$got_status" = "$want_status" ] && [ "$got_verdict" = "$want_verdict" ] \
     && [ "$got_scope" = "$want_scope" ] && [ "$got_failures" = "$want_failures" ] \
     && [ "$got_publishable" = "no" ]; then
    echo "ok   - $label: $got_status/$got_verdict SCOPE=$got_scope NEW_FAILURES=$got_failures"
  else
    echo "FALLO - $label: $got_status/$got_verdict SCOPE=$got_scope"
    echo "         NEW_FAILURES=$got_failures PUBLISHABLE=$got_publishable"
    echo "         wanted: $want_status/$want_verdict SCOPE=$want_scope"
    echo "                  NEW_FAILURES=$want_failures PUBLISHABLE=no"
    FAILURES=$((FAILURES + 1))
  fi
}

check_scope() {
  # check_scope <label> <slot> <want verdict> <want kind> <want failures>
  # <want checks>
  local label="$1" slot="$2" want_verdict="$3" want_kind="$4"
  local want_failures="$5" want_checks="$6"
  local file="$LOOP_TEST/gates/$slot/scope.verdict"
  local got_verdict got_kind got_failures got_checks
  if [ ! -f "$file" ]; then
    echo "FALLO - $label: the scope verdict is not there: $file"
    FAILURES=$((FAILURES + 1))
    return
  fi
  got_verdict="$(scope_field "$slot" VERDICT)"
  got_kind="$(scope_field "$slot" SCOPE_KIND)"
  got_failures="$(scope_field "$slot" NEW_FAILURES)"
  got_checks="$(scope_field "$slot" CHECKS)"
  if [ "$got_verdict" = "$want_verdict" ] && [ "$got_kind" = "$want_kind" ] \
     && [ "$got_failures" = "$want_failures" ] \
     && [ "$got_checks" = "$want_checks" ]; then
    echo "ok   - $label: $got_verdict/$got_kind NEW_FAILURES=$got_failures CHECKS=$got_checks"
  else
    echo "FALLO - $label: $got_verdict/$got_kind NEW_FAILURES=$got_failures CHECKS=$got_checks"
    echo "         wanted: $want_verdict/$want_kind NEW_FAILURES=$want_failures CHECKS=$want_checks"
    FAILURES=$((FAILURES + 1))
  fi
}

check_absent() {
  # check_absent <label> <path> : the file must not be there
  if [ -e "$2" ]; then
    echo "FALLO - $1: the file should not be there: $2"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok   - $1: $2 is not there"
  fi
}

check_no_publishable() {
  # check_no_publishable <label> <slot> : the scope verdict never carries a
  # publish boolean: the decision is derived by bin/state.py
  if grep -q '^PUBLISHABLE=' "$LOOP_TEST/gates/$2/scope.verdict" 2>/dev/null; then
    echo "FALLO - $1: the scope verdict carries a PUBLISHABLE key"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok   - $1: the scope verdict has no PUBLISHABLE key"
  fi
}

check_equal() {
  # check_equal <label> <got> <want>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1: $2"
  else
    echo "FALLO - $1: got '$2', wanted '$3'"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- the cases ------------------------------------------------------------
# Every case is a commit of its own, compared with its own parent: the diff
# of a case has to contain ONLY the file of that case, or the scope of the
# case would be the scope of every case before it.

# 1. the change touches the whole workspace
SHA_FULL="$(commit_change Cargo.toml "# workspace
# touched")"
BASE_FULL="$(git -C "$REPO_TEST" rev-parse "$SHA_FULL^")"
STUB_TEST_LOG=""
run_gate "$BASE_FULL" "$SHA_FULL"
check_case "caso 1 (full=true)" skipped SKIP workspace 0

# 2. no code changed
SHA_EMPTY="$(commit_change docs/README.md "# docs
# touched")"
BASE_EMPTY="$(git -C "$REPO_TEST" rev-parse "$SHA_EMPTY^")"
run_gate "$BASE_EMPTY" "$SHA_EMPTY"
check_case "caso 2 (no code changed)" skipped SKIP empty 0

# 3. the tests pass
SHA_CODE="$(commit_change crates/alpha/src/lib.rs "pub fn alpha() { /* 3 */ }")"
BASE_CODE="$(git -C "$REPO_TEST" rev-parse "$SHA_CODE^")"
STUB_TEST_LOG="$TMP_TEST/green.log"
STUB_TEST_EXIT=0
run_gate "$BASE_CODE" "$SHA_CODE"
check_case "caso 3 (tests in green)" finished VERDE-PARCIAL alpha 0

# 4. a test fails
STUB_TEST_LOG="$TMP_TEST/red.log"
STUB_TEST_EXIT=101
run_gate "$BASE_CODE" "$SHA_CODE"
check_case "caso 4 (a test fails)" finished ROJO-PARCIAL alpha 1

# caso 3b: el scope lleva el cli, para que la feature smlib se unifique
run_gate "$BASE_CODE" "$SHA_CODE"
if field SCOPE | grep -qw solidcraft-cli; then
  echo "ok   - caso 3b (el scope lleva el cli para la feature smlib): $(field SCOPE)"
else
  echo "FALLO - caso 3b (el scope lleva el cli para la feature smlib): $(field SCOPE)"
  FAILURES=$((FAILURES + 1))
fi

# 5. a failure that is in the baseline is not a new failure
STUB_TEST_LOG="$TMP_TEST/baseline.log"
STUB_TEST_EXIT=101
run_gate "$BASE_CODE" "$SHA_CODE"
check_case "caso 5 (a failure of the baseline)" finished VERDE-PARCIAL alpha 0

# 6. clippy fails: the run finished, but the scope has a new problem
STUB_TEST_LOG="$TMP_TEST/green.log"
STUB_TEST_EXIT=0
STUB_CLIPPY_EXIT=101
run_gate "$BASE_CODE" "$SHA_CODE"
check_case "caso 6 (clippy fails)" finished ROJO-PARCIAL alpha 1
STUB_CLIPPY_EXIT=0

# 7. the budget runs out: nothing was compiled and nothing was tested, so the
#    scope was NOT judged. It is a POSTPONEMENT, not a red: the agent has
#    nothing to fix and the supervisor runs the gate again.
GATE_QUICK_TIMEOUT_MIN=0
run_gate "$BASE_CODE" "$SHA_CODE"
check_case "caso 7 (the budget runs out)" skipped SKIP alpha 0
check_equal "caso 7 (the reason of the postponement)" "$(field DEFERRED)" \
  "budget-exhausted"
GATE_QUICK_TIMEOUT_MIN=5

# 8. the help does nothing
if bash "$GATE" --help >"$TMP_TEST/help.txt" 2>&1; then
  if grep -q "usage: gate-quick.sh" "$TMP_TEST/help.txt"; then
    echo "ok   - caso 8 (--help)"
  else
    echo "FALLO - caso 8 (--help): the usage is not printed"
    FAILURES=$((FAILURES + 1))
  fi
else
  echo "FALLO - caso 8 (--help): gate-quick.sh exited with $?"
  FAILURES=$((FAILURES + 1))
fi

# --- the scoped verdict ---------------------------------------------------
# The cases below are the ones of the SCOPED gate: the authoritative verdict
# is $LOOP_DIR/gates/<slot>/scope.verdict, and the legacy file is its mirror.

# 9. a green scope run: the scope verdict is green and the legacy file is its
#    mirror
STUB_TEST_LOG=""
STUB_TEST_EXIT=0
STUB_NEXTEST_LOG="$TMP_TEST/nextest-green.log"
STUB_NEXTEST_EXIT=0
STUB_CLIPPY_EXIT=0
STUB_FMT_EXIT=0
STUB_LAYERS_EXIT=0
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
check_case "caso 9 (el espejo verde)" finished VERDE-PARCIAL alpha 0
check_scope "caso 9 (el veredicto del scope)" "s0" VERDE-SCOPE packages 0 \
  "fmt:ok|layers:ok|clippy:ok|check:ok"
check_no_publishable "caso 9 (sin PUBLISHABLE)" "s0"

# 10. the scope verdict lands in the slot of the scope, never in the file of
#     the complete gate nor in the global one
check_absent "caso 10 (no gates/s0/verdict)" "$LOOP_TEST/gates/s0/verdict"
check_absent "caso 10 (no gate.verdict)" "$LOOP_TEST/gate.verdict"
# the parser of the loop judges the log of the scope in its OWN scratch slot:
# the verdict of the complete gate is never touched
if [ -f "$LOOP_TEST/gates/scope-s0/verdict" ]; then
  echo "ok   - caso 10 (el veredicto del parser está en su propio slot)"
else
  echo "FALLO - caso 10: the verdict of the parser is not in gates/scope-s0/verdict"
  FAILURES=$((FAILURES + 1))
fi

# 11. a failing test: the scope verdict is red and it names the failure
STUB_NEXTEST_LOG="$TMP_TEST/nextest-red.log"
STUB_NEXTEST_EXIT=100
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
check_case "caso 11 (un test falla)" finished ROJO-PARCIAL alpha 1
check_scope "caso 11 (el veredicto del scope)" "s0" ROJO-SCOPE packages 1 \
  "fmt:ok|layers:ok|clippy:ok|check:ok"
check_equal "caso 11 (el nombre del fallo)" \
  "$(scope_field s0 FAILED_TESTS)" "kernel::boolean_props::scale_invariant"

# 12. a failing clippy: the scope verdict is red even when the tests are green
STUB_NEXTEST_LOG="$TMP_TEST/nextest-green.log"
STUB_NEXTEST_EXIT=0
STUB_CLIPPY_EXIT=101
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
check_case "caso 12 (clippy falla)" finished ROJO-PARCIAL alpha 1
check_scope "caso 12 (el veredicto del scope)" "s0" ROJO-SCOPE packages 1 \
  "fmt:ok|layers:ok|clippy:fail|check:ok"

# 13. a failing fmt: the scope verdict is red
STUB_CLIPPY_EXIT=0
STUB_FMT_EXIT=1
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
check_case "caso 13 (fmt falla)" finished ROJO-PARCIAL alpha 1
check_scope "caso 13 (el veredicto del scope)" "s0" ROJO-SCOPE packages 1 \
  "fmt:fail|layers:ok|clippy:ok|check:ok"

# 14. a failing layers: the scope verdict is red
STUB_FMT_EXIT=0
STUB_LAYERS_EXIT=1
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
check_case "caso 14 (layers falla)" finished ROJO-PARCIAL alpha 1
check_scope "caso 14 (el veredicto del scope)" "s0" ROJO-SCOPE packages 1 \
  "fmt:ok|layers:fail|clippy:ok|check:ok"
STUB_LAYERS_EXIT=0

# 14b. a failing check of the WHOLE workspace: the scope verdict is red
#      even when the scope itself is green. The scope of a change is a
#      PACKAGE, so a change that breaks the build of another crate of
#      the workspace was published with a green scope until the check of
#      the workspace was added (27-10-2026).
STUB_FMT_EXIT=0
STUB_LAYERS_EXIT=0
STUB_CLIPPY_EXIT=0
STUB_CHECK_EXIT=1
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
check_case "caso 14b (el check del workspace falla)" finished ROJO-PARCIAL alpha 1
check_scope "caso 14b (el veredicto del scope)" "s0" ROJO-SCOPE packages 1 \
  "fmt:ok|layers:ok|clippy:ok|check:fail"
STUB_CHECK_EXIT=0

# 14c. the check of the workspace does NOT finish in its slice: that is NOT
#      "the workspace does not compile", it is "we did not get to know". The
#      phase is soft: it is skipped, the tests of the scope still run, and
#      the scope is green. A phase that stopped the run here would leave
#      the scope without tests (red) and the gate would publish nothing.
GATE_QUICK_TIMEOUT_MIN=1
STUB_CHECK_SLEEP=30
STUB_NEXTEST_LOG="$TMP_TEST/nextest-green.log"
STUB_NEXTEST_EXIT=0
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
check_scope "caso 14c (el check del workspace no termina: skipped)" "s0" \
  VERDE-SCOPE packages 0 \
  "fmt:ok|layers:ok|clippy:ok|check:skipped"
STUB_CHECK_SLEEP=""
GATE_QUICK_TIMEOUT_MIN=5

# 14d. the check of the workspace only runs when it FITS: the time that is
#      left has to pay for the check AND for the tests of the scope. The
#      computation of the scope (cargo metadata + affected.py) is part of
#      the budget and takes 1-5 min, so a slow turn can arrive at the check
#      with less time than the check needs. A check that eats the time of
#      the tests leaves the scope without tests, and a scope without tests
#      is red: the gate of the scope would publish nothing, ever.
#      Here the metadata takes 30 s of a budget of 60 s: the check does not
#      fit, it is skipped WITHOUT running, and the tests of the scope still
#      run (the scope keeps its tests).
GATE_QUICK_TIMEOUT_MIN=1
STUB_METADATA_SLEEP=30
STUB_NEXTEST_LOG="$TMP_TEST/nextest-green.log"
STUB_NEXTEST_EXIT=0
export STUB_ENV_LOG="$TMP_TEST/env-14d.log"
: > "$STUB_ENV_LOG"
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
check_scope "caso 14d (el check no cabe: skipped sin correr)" "s0" \
  VERDE-SCOPE packages 0 \
  "fmt:ok|layers:ok|clippy:ok|check:skipped"
check_calls="$(awk -F'\t' '$1 == "check" { n++ } END { print n+0 }' "$STUB_ENV_LOG")"
check_equal "caso 14d (el check del workspace no se ejecuto)" "$check_calls" "0"
nextest_calls="$(awk -F'\t' '$1 == "nextest" { n++ } END { print n+0 }' "$STUB_ENV_LOG")"
if [ "$nextest_calls" -ge 1 ]; then
  echo "ok   - caso 14d (los tests del alcance corrieron): $nextest_calls"
else
  echo "FALLO - caso 14d (los tests del alcance corrieron): $nextest_calls"
  FAILURES=$((FAILURES + 1))
fi
unset STUB_ENV_LOG
STUB_METADATA_SLEEP=""
GATE_QUICK_TIMEOUT_MIN=5

# 15. the change touches the whole workspace: the scope verdict says SKIP
STUB_NEXTEST_LOG="$TMP_TEST/nextest-green.log"
STUB_NEXTEST_EXIT=0
run_gate "$BASE_FULL" "$SHA_FULL" "s0"
check_case "caso 15 (full=true)" skipped SKIP workspace 0
check_scope "caso 15 (el veredicto del scope)" "s0" SKIP full 0 \
  "fmt:skipped|layers:skipped|clippy:skipped|check:skipped"

# 16. no code changed: the scope verdict says SKIP
run_gate "$BASE_EMPTY" "$SHA_EMPTY" "s0"
check_case "caso 16 (no code changed)" skipped SKIP empty 0
check_scope "caso 16 (el veredicto del scope)" "s0" SKIP empty 0 \
  "fmt:skipped|layers:skipped|clippy:skipped|check:skipped"

# 17. the scope of the slot is the one of the option: another slot's file is
#     not touched
STUB_NEXTEST_LOG="$TMP_TEST/nextest-green.log"
STUB_NEXTEST_EXIT=0
run_gate "$BASE_CODE" "$SHA_CODE" "s1"
check_scope "caso 17 (otro slot)" "s1" VERDE-SCOPE packages 0 \
  "fmt:ok|layers:ok|clippy:ok|check:ok"
check_absent "caso 17 (no gates/s0/scope.verdict)" "$LOOP_TEST/gates/s0/scope.verdict"

# 18. the budget of the scope runs out BEFORE the phases start: nothing was
#     compiled and nothing was tested, so the scope was NOT judged. That is
#     not a red: it is a POSTPONEMENT (the supervisor runs the gate again
#     when the machine is free) and it invents no failure.
GATE_QUICK_TIMEOUT_MIN=0
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
check_case "caso 18 (el presupuesto se acaba)" skipped SKIP alpha 0
check_equal "caso 18 (el motivo del aplazamiento)" "$(field DEFERRED)" \
  "budget-exhausted"
check_equal "caso 18 (el archivo del scope lo dice tambien)" \
  "$(scope_field s0 DEFERRED)" "budget-exhausted"
check_scope "caso 18 (el veredicto del scope)" "s0" SKIP packages 0 \
  "fmt:skipped|layers:skipped|clippy:skipped|check:skipped"
GATE_QUICK_TIMEOUT_MIN=5

# 19. the compilation is bounded: the gate exports CARGO_BUILD_JOBS to cargo.
#     Without it, cargo compiles with one rustc per core, and the rustc of the
#     engine is hungry: sixteen rustc at once are tens of gigabytes of memory
#     that this host does not have.
export STUB_ENV_LOG="$TMP_TEST/env.log"
: > "$STUB_ENV_LOG"
export GATE_BUILD_JOBS=3
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
unset GATE_BUILD_JOBS
clippy_jobs="$(awk -F'\t' '$1 == "clippy" { print $2 }' "$STUB_ENV_LOG" | sort -u | tr '\n' ' ')"
check_equal "caso 19 (la compilacion esta acotada)" "$clippy_jobs" "3 "
nextest_jobs="$(awk -F'\t' '$1 == "nextest" { print $2 }' "$STUB_ENV_LOG" | sort -u | tr '\n' ' ')"
check_equal "caso 19 (la compilacion esta acotada en el nextest)" "$nextest_jobs" "3 "

# 19b. without a value in the environment, the gate bounds the compilation
#      with its own default (four rustc at once, like the complete gate).
: > "$STUB_ENV_LOG"
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
clippy_jobs="$(awk -F'\t' '$1 == "clippy" { print $2 }' "$STUB_ENV_LOG" | sort -u | tr '\n' ' ')"
check_equal "caso 19b (la compilacion esta acotada por defecto)" "$clippy_jobs" "4 "
unset STUB_ENV_LOG

# 20. the lock of the build directory: two scoped gates at the same time fight
#     for the cargo lock of the SHARED target directory (the target directory
#     of the scoped gate is the same for every slot). The loser of that fight
#     does not wait: it dies with "Blocking waiting for file lock on build
#     directory" (27-10-2026: the clippy of the gate of 20:12 died because the
#     nextest of the gate of 20:01 was still alive). Now the loser is
#     DEFERRED: the scope is postponed, not judged (DEFERRED=scope-gate-alive).
#
#     The sha of this case is its OWN: a verdict of another sha that is left
#     in the slot is not fresh, and the deferral is written. With the sha of
#     another case the gate would keep the verdict that is already there (the
#     deferral never throws a verdict away).
SHA_LOCK="$(commit_change crates/alpha/src/lib.rs "pub fn alpha() { /* 4 */ }")"
BASE_LOCK="$(git -C "$REPO_TEST" rev-parse "$SHA_LOCK^")"
mkdir -p "$LOOP_TEST/gates"
rm -f "$LOOP_TEST/gates/s0/scope.verdict"
LOCK_FILE="$LOOP_TEST/gates/scope.lock"
: > "$LOCK_FILE"
rm -f "$TMP_TEST/lock.ready"
# The holder of the lock is the gate that is running: it keeps the lock and
# does not let it go until the case is over.
(
  exec 8>"$LOCK_FILE" || exit 1
  flock -w 10 8 || exit 1
  : > "$TMP_TEST/lock.ready"
  exec sleep 120
) &
LOCK_HOLDER=$!
# The holder is not a job of the shell: the shell does not have to report its
# death when the case kills it.
disown "$LOCK_HOLDER" 2>/dev/null || true
for _ in $(seq 1 50); do
  [ -f "$TMP_TEST/lock.ready" ] && break
  sleep 0.2
done
export STUB_ENV_LOG="$TMP_TEST/env-20.log"
: > "$STUB_ENV_LOG"
KEEP_GATES=1 run_gate "$BASE_LOCK" "$SHA_LOCK" "s0"
check_equal "caso 20 (el gate responde bien)" "$GATE_RC" "0"
check_equal "caso 20 (el alcance se aplaza)" "$(field GATE_STATUS)" "skipped"
check_equal "caso 20 (el veredicto no juzga)" "$(field VERDICT)" "SKIP"
check_equal "caso 20 (el motivo del aplazamiento)" "$(field DEFERRED)" \
  "scope-gate-alive"
check_equal "caso 20 (el archivo del scope lo dice tambien)" \
  "$(scope_field s0 DEFERRED)" "scope-gate-alive"
compiled="$(awk -F'\t' '$1 == "clippy" || $1 == "nextest" || $1 == "check" { n++ } END { print n+0 }' "$STUB_ENV_LOG")"
check_equal "caso 20 (nada se compila con el lock ocupado)" "$compiled" "0"
kill -KILL "$LOCK_HOLDER" 2>/dev/null || true
unset STUB_ENV_LOG

# 21. the leftovers of the scope: the binaries of the tests escape the kill of
#     the group of processes (nextest runs every test in a process of its own,
#     with a process group of its own) and they keep the cargo lock of the
#     build directory: the NEXT gate of the scope dies with "Blocking waiting
#     for file lock on build directory". The container that works is the
#     CGROUP: the leftovers of the scope are killed at the end of every phase
#     and at the exit of the run.
#
#     The kill is checked HERE with the functions of the gate: they are
#     extracted and RUN (the case asks the module, not its source).
#     The snippet needs the wrapper of the children (run_child) too: the
#     functions of the gate call it, and a snippet without it would fail for
#     a reason that has nothing to do with the orphans.
{
  awk '/^run_child\(\) \{/{on=1} on{print} /^\}$/{if(on){on=0}}' "$GATE"
  awk '/^cgroup_pids\(\) \{/{on=1} /^kill_scope_leftovers\(\) \{/{on=0} on{print}' "$GATE"
} > "$TMP_TEST/leftovers.sh"
if [ ! -s "$TMP_TEST/leftovers.sh" ]; then
  echo "FALLO - caso 21 (las funciones de los restos no estan en el gate)"
  FAILURES=$((FAILURES + 1))
else
  cat > "$TMP_TEST/leftovers-case.sh" <<'LEFTOVERS'
#!/usr/bin/env bash
set -uo pipefail
. "$LEFTOVERS_FUNCS"
FAKE="$FAKE_CGROUP"
# The orphan: a process that escaped the kill of the group of processes.
sleep 300 &
ORPHAN=$!
# The daemon of sccache: it outlives the phase that started it, it does not
# hold the cargo lock, and killing it would throw away the cache of the run.
bash -c 'exec -a sccache sleep 300' &
DAEMON=$!
printf '%s\n%s\n' "$ORPHAN" "$DAEMON" > "$FAKE/cgroup.procs"
kill_leftovers_in "$FAKE"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$ORPHAN" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$ORPHAN" 2>/dev/null; then echo "ORPHAN_ALIVE"; else echo "ORPHAN_DEAD"; fi
if kill -0 "$DAEMON" 2>/dev/null; then echo "DAEMON_ALIVE"; else echo "DAEMON_DEAD"; fi
kill -KILL "$DAEMON" 2>/dev/null || true
LEFTOVERS
  mkdir -p "$TMP_TEST/cgroup/solidcraft-gate-quick-0-999.scope"
  LEFTOVERS_FUNCS="$TMP_TEST/leftovers.sh" \
  FAKE_CGROUP="$TMP_TEST/cgroup/solidcraft-gate-quick-0-999.scope" \
    bash "$TMP_TEST/leftovers-case.sh" > "$TMP_TEST/leftovers.out" 2>&1
  if grep -q '^ORPHAN_DEAD$' "$TMP_TEST/leftovers.out"; then
    echo "ok   - caso 21 (el huerfano del scope muere)"
  else
    echo "FALLO - caso 21 (el huerfano del scope muere)"
    sed 's/^/    /' "$TMP_TEST/leftovers.out" | head -5
    FAILURES=$((FAILURES + 1))
  fi
  if grep -q '^DAEMON_ALIVE$' "$TMP_TEST/leftovers.out"; then
    echo "ok   - caso 21 (el daemon de sccache no se mata)"
  else
    echo "FALLO - caso 21 (el daemon de sccache no se mata)"
    sed 's/^/    /' "$TMP_TEST/leftovers.out" | head -5
    FAILURES=$((FAILURES + 1))
  fi
fi

# 22. the timeout of the tests is a POSTPONEMENT, not a red. The timeout of
#     the gate kills the runner with the tests that were running: the log
#     says "SIGTERM" and the summary counts one failure that never happened.
#     The scope was NOT judged: it is DEFERRED, the agent has nothing to fix
#     and the supervisor runs the gate again when the machine is free. This
#     is the case that made the loop answer ROJO-SCOPE with two INVENTED
#     failures and an empty list of failed tests (27-10-2026).
cat > "$TMP_TEST/nextest-cut.log" <<'LOG'
    Starting 3262 tests across 3 binaries
        SIGTERM [ 449.327s] (3262/3262) solidcraft-ui-egui render_workspace::tests::progressive_image_controls_route_to_the_registered_host

    Summary [ 624.981s] 3262 tests run: 3261 passed (10 slow), 1 failed, 18 skipped
LOG
STUB_NEXTEST_LOG="$TMP_TEST/nextest-cut.log"
STUB_NEXTEST_EXIT=124
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
check_case "caso 22 (el timeout de los tests aplaza el scope)" skipped SKIP alpha 0
check_equal "caso 22 (el motivo del aplazamiento)" "$(field DEFERRED)" \
  "nextest-timeout"
check_equal "caso 22 (el archivo del scope lo dice tambien)" \
  "$(scope_field s0 DEFERRED)" "nextest-timeout"
check_scope "caso 22 (el veredicto del scope)" "s0" SKIP packages 0 \
  "fmt:ok|layers:ok|clippy:ok|check:ok"

# 23. a REAL failure that happened BEFORE the cut is still red: the cut does
#     not hide it. The scope is not judged, but the failure is a fact.
cat > "$TMP_TEST/nextest-cut-red.log" <<'LOG'
    Starting 3262 tests across 3 binaries
        FAIL [   0.029s] (1/3262) solidcraft-kernel boolean_props::scale_invariant
--- STDOUT:              solidcraft-kernel boolean_props::scale_invariant ---
thread 'boolean_props::scale_invariant' panicked at crates/kernel/src/lib.rs:10:5:
assertion failed: false
--- STDERR:              solidcraft-kernel boolean_props::scale_invariant ---

    Summary [ 624.981s] 3262 tests run: 3260 passed, 2 failed, 18 skipped
LOG
STUB_NEXTEST_LOG="$TMP_TEST/nextest-cut-red.log"
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
check_case "caso 23 (un fallo real antes del corte sigue siendo rojo)" \
  finished ROJO-PARCIAL alpha 1
check_scope "caso 23 (el veredicto del scope)" "s0" ROJO-SCOPE packages 1 \
  "fmt:ok|layers:ok|clippy:ok|check:ok"
STUB_NEXTEST_LOG="$TMP_TEST/nextest-green.log"
STUB_NEXTEST_EXIT=0

# 24. the LINTER is cut: the phase is soft, so the scope is NOT red for it.
#     The linter is the phase that grows with the scope (130s for three
#     packages, measured the 27-10-2026), so its share of the budget is
#     thin and a cut linter is "we did not get to know", NOT "the code is
#     wrong": the scope keeps the verdict of the phases that did finish.
#     A red gate that says "the code is wrong" when the truth is "we ran
#     out of time" is the auto-sabotage this package is about.
#     The check of the workspace is off here so the case does not depend on
#     how long the scope took to be computed.
GATE_QUICK_TIMEOUT_MIN=2
GATE_CHECK_WORKSPACE=0
STUB_CLIPPY_SLEEP=60
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
check_case "caso 24 (el corte del linter no es un gate rojo)" \
  finished VERDE-PARCIAL alpha 0
check_scope "caso 24 (el veredicto del scope)" "s0" VERDE-SCOPE packages 0 \
  "fmt:ok|layers:ok|clippy:skipped|check:skipped"
GATE_QUICK_TIMEOUT_MIN=5
GATE_CHECK_WORKSPACE=1
STUB_CLIPPY_SLEEP=""

# 25. the knob of the DEPENDENTS of the touched packages. With the knob OFF
#     (the default) the tests run on the OWNERS: the package whose directory
#     holds the changed file. With the knob ON the tests also run on the
#     packages that DEPEND on them. The scope of the COMPILATION does not
#     move: the knob only widens the tests.
#     The fixture: beta depends on alpha, so a change in alpha has beta as
#     a dependent. The scope of the change (the compilation) is "alpha beta"
#     in both runs: only the scope of the tests changes.
STUB_BETA_DEPENDS_ALPHA=1
NEXTEST_INCLUDE_DEPENDENTS=0
run_gate "$BASE_CODE" "$SHA_CODE"
check_case "case 25 (knob 0: the scope of the tests is the owners only)" \
  finished VERDE-PARCIAL "alpha beta" 0
if grep -qxF 'gate-quick: nextest (alpha solidcraft-cli)' "$TMP_TEST/err.txt"; then
  echo "ok   - case 25 (knob 0: the nextest scope is alpha only)"
else
  echo "FALLO - case 25 (knob 0: the nextest scope is alpha only)"
  grep '^gate-quick:' "$TMP_TEST/err.txt" | head -10
  FAILURES=$((FAILURES + 1))
fi

NEXTEST_INCLUDE_DEPENDENTS=1
run_gate "$BASE_CODE" "$SHA_CODE"
check_case "case 25 (knob 1: the scope of the tests has the dependents)" \
  finished VERDE-PARCIAL "alpha beta" 0
if grep -qxF 'gate-quick: nextest (alpha beta solidcraft-cli)' "$TMP_TEST/err.txt"; then
  echo "ok   - case 25 (knob 1: the nextest scope is alpha and beta)"
else
  echo "FALLO - case 25 (knob 1: the nextest scope is alpha and beta)"
  grep '^gate-quick:' "$TMP_TEST/err.txt" | head -10
  FAILURES=$((FAILURES + 1))
fi
NEXTEST_INCLUDE_DEPENDENTS=0
STUB_BETA_DEPENDS_ALPHA=""

# --- the target directory of the slot --------------------------------------
# Every slot compiles in a target directory of its OWN: two scoped gates at
# the same time fight for the cargo lock of the build directory, and the
# loser of that fight does not wait (27-10-2026: the clippy of the gate of
# 20:12 died because the nextest of the gate of 20:01 was still alive).
#
# The layout is the one of bin/gate-target-dir.sh: GATE_QUICK_TARGET_DIR is
# the BASE, the container of the directories, and every slot writes in
# <base>/slot-<slot>. The base is never the target directory of a run: the
# disk collector removes the directories one by one and never the base as a
# whole.

# 26. the slot compiles in <base>/slot-<slot>. EVERY cargo call of the run
#     uses that directory: the layout is not a promise in a comment, it is
#     the environment that cargo sees.
export STUB_ENV_LOG="$TMP_TEST/env-26.log"
: > "$STUB_ENV_LOG"
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
targets_s0="$(awk -F'\t' 'NF >= 3 { print $3 }' "$STUB_ENV_LOG" | sort -u)"
check_equal "caso 26 (el slot s0 compila en su propio directorio)" \
  "$targets_s0" "$TMP_TEST/gate-target/slot-s0"
calls_s0="$(awk -F'\t' 'NF >= 3 { n++ } END { print n+0 }' "$STUB_ENV_LOG")"
if [ "$calls_s0" -gt 0 ]; then
  echo "ok   - caso 26 (el cargo de la carrera compila: $calls_s0 llamadas)"
else
  echo "FALLO - caso 26 (el cargo de la carrera no compila)"
  FAILURES=$((FAILURES + 1))
fi
unset STUB_ENV_LOG

# 27. another slot compiles in a directory of its OWN: the two slots do not
#     share the build directory (that is the whole point of the layout).
export STUB_ENV_LOG="$TMP_TEST/env-27.log"
: > "$STUB_ENV_LOG"
run_gate "$BASE_CODE" "$SHA_CODE" "s1"
targets_s1="$(awk -F'\t' 'NF >= 3 { print $3 }' "$STUB_ENV_LOG" | sort -u)"
check_equal "caso 27 (el slot s1 compila en un directorio que no es el de s0)" \
  "$targets_s1" "$TMP_TEST/gate-target/slot-s1"
unset STUB_ENV_LOG

# 28. the BASE is never the target directory of a run: it is the container
#     of the directories of the slots. The disk collector removes the
#     directories one by one and never the base as a whole.
export STUB_ENV_LOG="$TMP_TEST/env-28.log"
: > "$STUB_ENV_LOG"
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
run_gate "$BASE_CODE" "$SHA_CODE" "s1"
base_real="$(awk -F'\t' 'NF >= 3 { print $3 }' "$STUB_ENV_LOG" | sort -u \
  | grep -c "^$TMP_TEST/gate-target$" || true)"
check_equal "caso 28 (ninguna carrera compila en la base)" \
  "${base_real:-0}" "0"
unset STUB_ENV_LOG

# 29. the deferral NAMES the slot and the directory it waits for: an
#     operator that reads the log has to know which run is waiting and why.
SHA_SLOT="$(commit_change crates/alpha/src/lib.rs "pub fn alpha() { /* 5 */ }")"
BASE_SLOT="$(git -C "$REPO_TEST" rev-parse "$SHA_SLOT^")"
mkdir -p "$LOOP_TEST/gates/s0"
SLOT_LOCK_FILE="$LOOP_TEST/gates/s0/scope.lock"
: > "$SLOT_LOCK_FILE"
rm -f "$TMP_TEST/slot-lock.ready"
(
  exec 8>"$SLOT_LOCK_FILE" || exit 1
  flock -w 10 8 || exit 1
  : > "$TMP_TEST/slot-lock.ready"
  exec sleep 120
) &
SLOT_LOCK_HOLDER=$!
disown "$SLOT_LOCK_HOLDER" 2>/dev/null || true
for _ in $(seq 1 50); do
  [ -f "$TMP_TEST/slot-lock.ready" ] && break
  sleep 0.2
done
export STUB_ENV_LOG="$TMP_TEST/env-29.log"
: > "$STUB_ENV_LOG"
KEEP_GATES=1 run_gate "$BASE_SLOT" "$SHA_SLOT" "s0"
check_equal "caso 29 (el gate responde bien)" "$GATE_RC" "0"
check_equal "caso 29 (el alcance se aplaza)" "$(field GATE_STATUS)" "skipped"
check_equal "caso 29 (el veredicto no juzga)" "$(field VERDICT)" "SKIP"
check_equal "caso 29 (el motivo del aplazamiento)" "$(field DEFERRED)" \
  "scope-gate-alive"
if grep -q "slot s0" "$TMP_TEST/err.txt"; then
  echo "ok   - caso 29 (el aplazamiento nombra el slot)"
else
  echo "FALLO - caso 29 (el aplazamiento no nombra el slot)"
  grep '^gate-quick:' "$TMP_TEST/err.txt" | head -5
  FAILURES=$((FAILURES + 1))
fi
if grep -q "$TMP_TEST/gate-target/slot-s0" "$TMP_TEST/err.txt"; then
  echo "ok   - caso 29 (el aplazamiento nombra el directorio)"
else
  echo "FALLO - caso 29 (el aplazamiento no nombra el directorio)"
  grep '^gate-quick:' "$TMP_TEST/err.txt" | head -5
  FAILURES=$((FAILURES + 1))
fi
compiled29="$(awk -F'\t' '$1 == "clippy" || $1 == "nextest" || $1 == "check" { n++ } END { print n+0 }' "$STUB_ENV_LOG")"
check_equal "caso 29 (nada se compila con el lock del slot ocupado)" \
  "$compiled29" "0"
unset STUB_ENV_LOG
kill "$SLOT_LOCK_HOLDER" 2>/dev/null || true
wait "$SLOT_LOCK_HOLDER" 2>/dev/null || true

# 30. the lock of the SLOT: two runs of the same slot do not run at the same
#     time (they would write the same verdict and the same target
#     directory), and two runs of DIFFERENT slots do (each one compiles in a
#     directory of its own).
SHA_SLOT2="$(commit_change crates/alpha/src/lib.rs "pub fn alpha() { /* 6 */ }")"
BASE_SLOT2="$(git -C "$REPO_TEST" rev-parse "$SHA_SLOT2^")"
mkdir -p "$LOOP_TEST/gates/s0"
SLOT_LOCK_FILE="$LOOP_TEST/gates/s0/scope.lock"
: > "$SLOT_LOCK_FILE"
rm -f "$TMP_TEST/slot-lock2.ready"
(
  exec 8>"$SLOT_LOCK_FILE" || exit 1
  flock -w 10 8 || exit 1
  : > "$TMP_TEST/slot-lock2.ready"
  exec sleep 120
) &
SLOT_LOCK_HOLDER2=$!
disown "$SLOT_LOCK_HOLDER2" 2>/dev/null || true
for _ in $(seq 1 50); do
  [ -f "$TMP_TEST/slot-lock2.ready" ] && break
  sleep 0.2
done
export STUB_ENV_LOG="$TMP_TEST/env-30.log"
: > "$STUB_ENV_LOG"
KEEP_GATES=1 run_gate "$BASE_SLOT2" "$SHA_SLOT2" "s0"
check_equal "caso 30 (el mismo slot se aplaza)" "$(field GATE_STATUS)" "skipped"
KEEP_GATES=1 run_gate "$BASE_SLOT2" "$SHA_SLOT2" "s1"
check_equal "caso 30 (otro slot no se aplaza)" "$(field GATE_STATUS)" "finished"
compiled30="$(awk -F'\t' '$1 == "clippy" || $1 == "nextest" || $1 == "check" { n++ } END { print n+0 }' "$STUB_ENV_LOG")"
if [ "$compiled30" -gt 0 ]; then
  echo "ok   - caso 30 (el otro slot compila: $compiled30 llamadas)"
else
  echo "FALLO - caso 30 (el otro slot no compila)"
  FAILURES=$((FAILURES + 1))
fi
unset STUB_ENV_LOG
kill "$SLOT_LOCK_HOLDER2" 2>/dev/null || true
wait "$SLOT_LOCK_HOLDER2" 2>/dev/null || true

# 31. the layout works WITHOUT the helper deployed: a run from a checkout
#     that does not have it computes the same directory.
HELPER="$LOOP_TEST/bin/gate-target-dir.sh"
HELPER_SAVED="$TMP_TEST/gate-target-dir.sh.saved"
if [ -f "$HELPER" ]; then
  mv "$HELPER" "$HELPER_SAVED"
fi
export STUB_ENV_LOG="$TMP_TEST/env-31.log"
: > "$STUB_ENV_LOG"
run_gate "$BASE_CODE" "$SHA_CODE" "s0"
targets_fallback="$(awk -F'\t' 'NF >= 3 { print $3 }' "$STUB_ENV_LOG" | sort -u)"
check_equal "caso 31 (sin el helper el layout es el mismo)" \
  "$targets_fallback" "$TMP_TEST/gate-target/slot-s0"
unset STUB_ENV_LOG
if [ -f "$HELPER_SAVED" ]; then
  mv "$HELPER_SAVED" "$HELPER"
fi

# 32. the disk collector knows the target dir of the scoped gate, and it
#     does not remove the one that is being used.
#
# WHY (31-10-2026): the target dir of the scoped gate is the tree of the
# ORCHESTRATOR (the orchestrator runs the scoped gate of the loop and
# points the base at its own tree), so that is the tree that fills the
# disk. A collector that only knew the tree of the loop swept a tree
# nobody used and never touched the one that grows.
#
# The rule is GENERAL: it does not name any issue, any slot and any pull
# request. The gate writes in <base>/slot-<slot> and the collector asks
# the helper of the orchestrator for the layout of that tree, so the two
# agree on WHERE the build of a slot lands.
GC="$SCRIPT_DIR/gc-disk.sh"
ORCH_TEST="$TMP_TEST/orch"
ORCH_BASE_TEST="$TMP_TEST/orch-target"
LOOP_BASE_TEST="$TMP_TEST/loop-target"
mkdir -p "$ORCH_TEST/bin" "$ORCH_BASE_TEST/slot-s0" "$LOOP_BASE_TEST" \
  "$LOOP_TEST/gates/s0" "$LOOP_TEST/logs"
# The helper of the orchestrator: it answers with the dirs that exist.
cat > "$ORCH_TEST/bin/slot-target-dir.sh" <<'HELPER'
#!/usr/bin/env bash
set -uo pipefail
BASE="${ORCH_TARGET_BASE:-${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}/targets}"
case "${1:-}" in
  --base) printf '%s\n' "$BASE"; exit 0 ;;
  --list) for d in "$BASE"/slot-*; do [ -d "$d" ] && printf '%s\n' "$d"; done; exit 0 ;;
esac
exit 2
HELPER
chmod +x "$ORCH_TEST/bin/slot-target-dir.sh"
# The state of the orchestrator: no pull request is open, so the slots of
# its tree are leftovers and the collector may remove them.
printf '{"open_prs":{}}' > "$ORCH_TEST/state.json"
# The tree of the gate has to be the tree of the orchestrator: the gate
# compiles in the tree of the orchestrator, so the collector has to see
# the SAME dir.
GATE_QUICK_TARGET_DIR="$ORCH_BASE_TEST" \
  bash "$LOOP_TEST/bin/gate-target-dir.sh" --slot s0 > "$TMP_TEST/target-32.txt" 2>/dev/null
check_equal "caso 32 (el gate compila en el arbol del orquestador)" \
  "$(cat "$TMP_TEST/target-32.txt")" "$ORCH_BASE_TEST/slot-s0"
# The collector asks the helper of the orchestrator for that tree: the
# dir that the gate writes in is a candidate of the collector. The file
# inside is OLD: a dir that was touched a moment ago is not a leftover.
# The file has content: a dir with nothing in it frees nothing and the
# collector leaves it alone.
printf 'artifact\n' > "$ORCH_BASE_TEST/slot-s0/artifact"
touch -d "2 days ago" "$ORCH_BASE_TEST/slot-s0/artifact"
# The base of the loop is a DIFFERENT one: the dir of the orchestrator is
# only reachable through the helper of the orchestrator, so the collector
# can only see it if it asks that helper.
LOOP_DIR="$LOOP_TEST" \
ORCH_DIR="$ORCH_TEST" \
ORCH_TARGET_BASE="$ORCH_BASE_TEST" \
GATE_QUICK_TARGET_DIR="$LOOP_BASE_TEST" \
REPO="$REPO_TEST" \
HOME="$TMP_TEST" \
  bash "$GC" --stale-targets --dry-run > "$TMP_TEST/gc-32.txt" 2>&1
gc_rc=$?
check_equal "caso 32 (el collector corre)" "$gc_rc" "0"
if grep -q "BORRARÍA $ORCH_BASE_TEST/slot-s0" "$TMP_TEST/gc-32.txt"; then
  echo "ok   - caso 32 (el collector conoce el target dir del gate)"
else
  echo "FALLO - caso 32 (el collector no conoce el target dir del gate)"
  sed 's/^/    /' "$TMP_TEST/gc-32.txt" | head -8
  FAILURES=$((FAILURES + 1))
fi
# The base is the container of the dirs of the slots: it is NEVER the
# candidate.
if grep -q "BORRARÍA $ORCH_BASE_TEST (" "$TMP_TEST/gc-32.txt"; then
  echo "FALLO - caso 32 (el collector propone borrar la base del arbol)"
  FAILURES=$((FAILURES + 1))
else
  echo "ok   - caso 32 (la base del arbol no es candidata)"
fi

# 33. the descriptors of the lock are NOT inherited by the children of the
#     gate. The lock of the slot (fd 8) and the global one (fd 9) are OPEN
#     in the gate, and a child INHERITS them: a child that outlives the gate
#     keeps the lock taken, and the NEXT gate of that slot can not take it:
#     it is DEFERRED, and it is deferred FOREVER (the slot never gates
#     again, with no error anywhere).
#
#     The fixture: the parser of the log (gate-check.sh) is replaced by one
#     that leaves an ORPHAN behind (a sleep that lives 30 s) and answers the
#     verdict of a green run. After the gate exits, the lock of the slot and
#     the global one must be FREE: `flock -n -x` takes them at once.
#
#     The belt is OFF in this case (GATE_QUICK_CGROUP=0): without a scope
#     nothing kills the leftovers of the run, so an orphan that outlives the
#     gate is the real case (the same thing happens when the gate is killed
#     and its cleanup never runs).
#
#     WITHOUT the fix the orphan holds the two locks and this case FAILS.
SHA_FD="$(commit_change crates/alpha/src/lib.rs "pub fn alpha() { /* fd */ }")"
BASE_FD="$(git -C "$REPO_TEST" rev-parse "$SHA_FD^")"
cat > "$TMP_TEST/gate-check-orphan.sh" <<'ORPHAN'
#!/usr/bin/env bash
# A parser of the log that leaves an orphan behind: the sleep outlives the
# gate (nobody waits for it and nobody kills it).
# The output of the orphan goes to /dev/null: the parser is launched inside a
# substitution, and an orphan that holds the pipe of the substitution would
# keep the GATE waiting for it (that is another bug, not this one).
sleep 30 >/dev/null 2>&1 &
printf '%s\n' "$!" > "$ORPHAN_PID_FILE"
printf 'VERDICT=VERDE\n'
printf 'NEW_FAILURES=0\n'
printf 'GATE_STATUS=finished\n'
exit 0
ORPHAN
chmod +x "$TMP_TEST/gate-check-orphan.sh"
lock_free() {
  # lock_free <file> : 0 when the lock can be taken at once (exclusive)
  local file="$1"
  [ -f "$file" ] || return 1
  ( exec 8>"$file" 2>/dev/null && flock -n -x 8 ) 2>/dev/null
}
export GATE_CHECK="$TMP_TEST/gate-check-orphan.sh"
ORPHAN_PID="$TMP_TEST/orphan.pid"
export ORPHAN_PID_FILE="$ORPHAN_PID"
# The belt is off: nothing kills the leftovers of the run, so the orphan of
# the parser outlives the gate (the case of a gate that is killed).
export GATE_QUICK_CGROUP=0
rm -f "$ORPHAN_PID"
run_gate "$BASE_FD" "$SHA_FD" "sfd"
unset GATE_CHECK ORPHAN_PID_FILE GATE_QUICK_CGROUP
check_equal "caso 33 (el gate responde bien)" "$GATE_RC" "0"
if [ -f "$ORPHAN_PID" ]; then
  echo "ok   - caso 33 (el parser dejo un huerfano vivo)"
else
  echo "FALLO - caso 33 (el parser no dejo huerfano: el caso no prueba nada)"
  FAILURES=$((FAILURES + 1))
fi
if lock_free "$LOOP_TEST/gates/sfd/scope.lock"; then
  echo "ok   - caso 33 (el huerfano no deja tomado el lock del slot)"
else
  echo "FALLO - caso 33 (el huerfano deja tomado el lock del slot):" \
    "el slot no gatearia nunca mas"
  FAILURES=$((FAILURES + 1))
fi
if lock_free "$LOOP_TEST/gates/scope.lock"; then
  echo "ok   - caso 33 (el huerfano no deja tomado el lock global)"
else
  echo "FALLO - caso 33 (el huerfano deja tomado el lock global)"
  FAILURES=$((FAILURES + 1))
fi
# The orphan dies with the case: it must not keep the lock of the slot for
# the cases that come after.
if [ -f "$ORPHAN_PID" ]; then
  kill -KILL "$(cat "$ORPHAN_PID")" 2>/dev/null || true
fi

# --- the verdict ----------------------------------------------------------
if [ "$FAILURES" -eq 0 ]; then
  echo "todos los casos pasan"
  exit 0
fi
echo "$FAILURES caso(s) fallan"
exit 1
