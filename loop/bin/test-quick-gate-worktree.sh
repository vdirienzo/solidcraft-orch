#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-quick-gate-worktree.sh - the quick gate runs in a worktree of its own.
#
# The quick gate compiles a tree of the branch in flight. It used to compile
# the working tree of the worktree of the ISSUE, and it was SKIPPED when that
# worktree was not there ("the worktree of the issue is not there"). The
# issue is claimed inside the same turn that writes the code, so the
# worktree of the issue does not exist yet in those turns and the fast check
# never ran for them: the code reached the complete gate without it.
#
# The gate now has a worktree of its OWN (a detached one, at the sha that is
# checked), the worktree of the issue is never touched, and the worktree of
# the gate is removed when the gate ends.
#
# The test is HERMETIC:
#   * its own repository (a fake one, made here), its own worktree root and
#     its own loop directory: the live loop is never read nor written;
#   * the quick gate is a STUB that records the directory it runs in and
#     writes the verdict: no cargo, no network, no GitHub.
#
# Run:  bash bin/test-quick-gate-worktree.sh
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR="${SUPERVISOR:-$HERE/supervisor.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-quick-gate-worktree.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
FAILED=0

say() { printf '%s\n' "$*"; }
ok() { say "  PASS  $1"; }
bad() { say "  FAIL  $1"; FAILED=$((FAILED + 1)); }

say "=== the test of the worktree of the quick gate ($WORK) ==="

if [ ! -f "$SUPERVISOR" ]; then
  say "the supervisor under test is not there: $SUPERVISOR"
  exit 1
fi

# --- the functions under test ----------------------------------------------
# They are EXTRACTED from the supervisor: the test runs the real code, not a
# copy of it. The supervisor is the one next to this test, and it can be
# pointed at another one with SUPERVISOR=...
extract_function() {
  local name="$1"
  awk -v fn="$name" '
    index($0, fn "() {") == 1 { inside = 1 }
    inside { print }
    inside && $0 == "}" { inside = 0; exit }
  ' "$SUPERVISOR"
}

for fn in maybe_run_quick_gate issue_branch_sha scope_verdict_file \
          scope_verdict_field quick_gate_temp_path quick_gate_temp_forget \
          quick_gate_temp_create quick_gate_temp_remove leftover_is_ours; do
  if ! grep -q "^$fn() {" "$SUPERVISOR"; then
    bad "the supervisor under test has no $fn()"
  fi
done
if [ "$FAILED" -ne 0 ]; then
  say "=== the test of the worktree of the quick gate: $FAILED failure(s) ==="
  exit 1
fi

HARNESS="$WORK/harness.sh"
cat > "$HARNESS" <<'HARNESS'
set -uo pipefail

# The log of the supervisor: the same shape (the file of the errors and the
# standard error).
log() { echo "[$(date -Is)] $*" | tee -a "$ERR" >&2; }

# No complete gate is alive in the test: the machine is free.
live_gate_pid() { return 1; }

# The heavy phase is free.
heavy_available() { return 0; }

# The budget of the run: the minutes that are left of the turn.
gate_budget() { printf '%s' "${1:-1}"; }

# Another slot is active: the shared checkout is NOT ours (the test does not
# read the state of the loop).
can_reset_checkout() { return 1; }
HARNESS

for fn in scope_verdict_file scope_verdict_field issue_branch_sha \
          quick_gate_temp_path quick_gate_temp_forget \
          quick_gate_temp_create quick_gate_temp_remove \
          leftover_is_ours maybe_run_quick_gate; do
  extract_function "$fn" >> "$HARNESS"
  printf '\n' >> "$HARNESS"
done

# --- the world of the test --------------------------------------------------
LOOP="$WORK/loop"
REPO="$WORK/repo"
WT_ROOT="$WORK/wt"
ERR="$WORK/errors.log"
CALLS="$WORK/gate-calls.txt"
mkdir -p "$LOOP/bin" "$REPO" "$WT_ROOT"
: > "$ERR"
: > "$CALLS"

export LOOP_DIR="$LOOP" REPO="$REPO" WT_ROOT="$WT_ROOT" ERR="$ERR" CALLS="$CALLS"
export SLOT=0 MAX_SLOTS=1 UNIT_TIMEOUT_SEC=0 NOW_EPOCH="$(date -u +%s)"
export GATE_QUICK_MIN_MIN=12 GATE_QUICK_TIMEOUT_MIN=30

# --- the repository of the test ---------------------------------------------
git -C "$REPO" init -q
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" config user.email "test@example.invalid"
git -C "$REPO" config user.name "the test of the quick gate"
printf 'the code of the issue\n' > "$REPO/code.txt"
git -C "$REPO" add -A
git -C "$REPO" -c commit.gpgsign=false commit -qm "the commit of the issue"
git -C "$REPO" branch fix/issue-1
SHA="$(git -C "$REPO" rev-parse fix/issue-1)"

# --- the stub of the quick gate ---------------------------------------------
cat > "$LOOP/bin/gate-quick.sh" <<'STUB'
#!/usr/bin/env bash
# The stub of the quick gate: it compiles nothing, it touches no network and
# it writes the verdict that the supervisor reads.
set -uo pipefail
slot="${SLOT:-0}"
prev=""
for arg in "$@"; do
  if [ "$prev" = "--slot" ]; then slot="$arg"; fi
  prev="$arg"
done
printf '%s\t%s\n' "$PWD" "$*" >> "$CALLS"
dir="$LOOP_DIR/gates/$slot"
mkdir -p "$dir" 2>/dev/null || true
{
  printf 'GATE_STATUS=%s\n' "ok"
  printf 'SCOPE=%s\n' "scope"
  printf 'SCOPE_KIND=%s\n' "packages"
  printf 'VERDICT=%s\n' "VERDE-SCOPE"
  printf 'NEW_FAILURES=%s\n' "0"
  printf 'FAILED_TESTS=%s\n' ""
  printf 'CHECKS=%s\n' "ok"
  printf 'SHA=%s\n' "${2:-}"
  printf 'AT=%s\n' "$(date +%s)"
} > "$dir/scope.verdict"
exit 0
STUB
chmod 755 "$LOOP/bin/gate-quick.sh"

# shellcheck source=/dev/null
. "$HARNESS"

# The directory the gate ran in: the first column of the first call.
gate_cwd() { cut -f1 "$CALLS" 2>/dev/null | head -1; }

# --- 1. the worktree of the issue is NOT there -------------------------------
# The issue is claimed inside this turn: the worktree of the issue does not
# exist yet, and the gate has to run anyway.
say "--- the issue is claimed in this turn: the worktree of the issue is not there ---"
: > "$CALLS"
rm -f "$LOOP/gates/0/scope.verdict"
OUT="$WORK/case1.out"
maybe_run_quick_gate "$WT_ROOT/issue-1" "fix/issue-1" >"$OUT" 2>&1

if [ -s "$CALLS" ]; then
  ok "the quick gate ran without the worktree of the issue"
else
  bad "the quick gate did not run without the worktree of the issue"
  say "--- the output ---"; tail -12 "$OUT" | sed 's/^/          /'
fi

CWD="$(gate_cwd)"
if [ "$CWD" = "$WT_ROOT/gate-quick-0" ]; then
  ok "the gate ran in the worktree of the gate ($CWD)"
else
  bad "the gate ran in '${CWD:-?}' (it has to be $WT_ROOT/gate-quick-0)"
fi
if [ -n "$CWD" ] && [ "$CWD" != "$WT_ROOT/issue-1" ]; then
  ok "the gate did not run in the worktree of the issue"
else
  bad "the gate ran in the worktree of the issue"
fi
if [ -d "$WT_ROOT/issue-1" ]; then
  bad "the worktree of the issue was created by the gate"
else
  ok "the worktree of the issue was not created"
fi
if [ -d "$WT_ROOT/gate-quick-0" ]; then
  bad "the worktree of the gate was not removed when the gate ended"
else
  ok "the worktree of the gate was removed when the gate ended"
fi
if git -C "$REPO" worktree list 2>/dev/null | grep -q "gate-quick-0"; then
  bad "the worktree of the gate is still registered in the repository"
else
  ok "the worktree of the gate is not registered in the repository any more"
fi
if grep -q "origin/main $SHA" "$CALLS" 2>/dev/null; then
  ok "the gate checked the sha of the branch in flight"
else
  bad "the gate did not check the sha of the branch in flight"
fi
if grep -q "^VERDICT=VERDE-SCOPE" "$LOOP/gates/0/scope.verdict" 2>/dev/null; then
  ok "the verdict of the gate was written in the slot"
else
  bad "the verdict of the gate was not written in the slot"
fi

# --- 2. the worktree of the issue IS there -----------------------------------
# The behavior of today is kept: the gate compiles the tree of the issue.
say "--- the worktree of the issue is there: the gate uses it ---"
if git -C "$REPO" worktree add --detach "$WT_ROOT/issue-1" "$SHA" >/dev/null 2>&1; then
  ok "the worktree of the issue was created"
else
  bad "the worktree of the issue could not be created"
fi
: > "$CALLS"
rm -f "$LOOP/gates/0/scope.verdict"
OUT="$WORK/case2.out"
maybe_run_quick_gate "$WT_ROOT/issue-1" "fix/issue-1" >"$OUT" 2>&1

CWD="$(gate_cwd)"
if [ "$CWD" = "$WT_ROOT/issue-1" ]; then
  ok "the gate ran in the worktree of the issue"
else
  bad "the gate ran in '${CWD:-?}' (it has to be $WT_ROOT/issue-1)"
fi
if [ -d "$WT_ROOT/gate-quick-0" ]; then
  bad "a worktree of the gate was created when the issue had one"
else
  ok "no worktree of the gate was created when the issue had one"
fi

# --- 3. the tip of the branch cannot be read ---------------------------------
# Without a sha there is nothing to check: the gate is not launched (the
# behavior of today is kept).
say "--- the tip of the branch in flight cannot be read ---"
: > "$CALLS"
rm -f "$LOOP/gates/0/scope.verdict"
OUT="$WORK/case3.out"
maybe_run_quick_gate "$WT_ROOT/issue-9" "fix/issue-9-does-not-exist" >"$OUT" 2>&1

if [ -s "$CALLS" ]; then
  bad "the gate ran without a sha to check"
else
  ok "the gate did not run without a sha to check"
fi
if grep -q "the tip of the branch in flight cannot be read" "$OUT"; then
  ok "the reason of the skip is in the log"
else
  bad "the reason of the skip is not in the log"
fi
if [ -d "$WT_ROOT/gate-quick-0" ]; then
  bad "a worktree of the gate was created for a gate that did not run"
else
  ok "no worktree of the gate was created for a gate that did not run"
fi

# --- 4. the leftover of a run that died --------------------------------------
# The worktree of a run that was killed is still there (and registered): the
# next run has to be able to use that path again.
say "--- the leftover of a run that died ---"
if git -C "$REPO" worktree add --detach "$WT_ROOT/gate-quick-0" "$SHA" >/dev/null 2>&1; then
  printf 'the run that died\n' > "$WT_ROOT/gate-quick-0/stale.txt"
  ok "the leftover of a dead run was simulated"
else
  bad "the leftover of a dead run could not be simulated"
fi
: > "$CALLS"
rm -f "$LOOP/gates/0/scope.verdict"
OUT="$WORK/case4.out"
maybe_run_quick_gate "$WT_ROOT/issue-2" "fix/issue-1" >"$OUT" 2>&1

if [ -s "$CALLS" ]; then
  ok "the gate ran over the leftover of the dead run"
else
  bad "the gate did not run over the leftover of the dead run"
  say "--- the output ---"; tail -12 "$OUT" | sed 's/^/          /'
fi
if [ -d "$WT_ROOT/gate-quick-0" ]; then
  bad "the worktree of the gate was not removed after the leftover"
else
  ok "the worktree of the gate was removed after the leftover"
fi

# --- 5. the verdict of the sha is already there ------------------------------
# The gate is idempotent: when the verdict of the sha is already there the
# gate does not run, and no worktree is created for a gate that does not run.
say "--- the verdict of the sha is already there ---"
mkdir -p "$LOOP/gates/0"
printf 'GATE_STATUS=%s\nVERDICT=%s\nSHA=%s\n' "ok" "VERDE-SCOPE" "$SHA" \
  > "$LOOP/gates/0/scope.verdict"
: > "$CALLS"
OUT="$WORK/case5.out"
maybe_run_quick_gate "$WT_ROOT/issue-3" "fix/issue-1" >"$OUT" 2>&1

if [ -s "$CALLS" ]; then
  bad "the gate ran again with the verdict of the sha already there"
else
  ok "the gate did not run again with the verdict of the sha already there"
fi
if [ -d "$WT_ROOT/gate-quick-0" ]; then
  bad "a worktree of the gate was created for a gate that did not run"
else
  ok "no worktree of the gate was created for a gate that did not run"
fi

# --- 6. the leftover of the quick gate of this slot --------------------------
# With several slots the cargo of the quick gate of the OTHER slot has to
# survive (it is the implement that runs in parallel) and the cargo of the
# quick gate of THIS slot has to die with the turn: the quick gate can run in
# a worktree of its own, and that worktree is the one of this slot.
say "--- the leftover of the quick gate of this slot (several slots) ---"
MAX_SLOTS=2
THIS_GATE_WT="$(SLOT=0 quick_gate_temp_path)"
OTHER_GATE_WT="$(SLOT=1 quick_gate_temp_path)"

if leftover_is_ours "$THIS_GATE_WT/crates/thing" "$WT_ROOT/issue-1"; then
  ok "the cargo of the quick gate of this slot is ours"
else
  bad "the cargo of the quick gate of this slot is not ours"
fi
if leftover_is_ours "$WT_ROOT/issue-1" "$WT_ROOT/issue-1"; then
  ok "the cargo of the worktree of the issue of this slot is ours"
else
  bad "the cargo of the worktree of the issue of this slot is not ours"
fi
if leftover_is_ours "$OTHER_GATE_WT/crates/thing" "$WT_ROOT/issue-1"; then
  bad "the cargo of the quick gate of the other slot is ours (it has to survive)"
else
  ok "the cargo of the quick gate of the other slot is not ours"
fi
if leftover_is_ours "$REPO/crates" "$WT_ROOT/issue-1"; then
  bad "the cargo of the shared checkout is ours while another slot is active"
else
  ok "the cargo of the shared checkout is not ours while another slot is active"
fi

# With one slot every cargo of the loop is ours: that behavior is kept.
MAX_SLOTS=1
if leftover_is_ours "$THIS_GATE_WT/crates/thing" "$WT_ROOT/issue-1"; then
  ok "with one slot the cargo of the quick gate is ours"
else
  bad "with one slot the cargo of the quick gate is not ours"
fi
if leftover_is_ours "$OTHER_GATE_WT/crates/thing" "$WT_ROOT/issue-1"; then
  ok "with one slot every cargo of the worktree root is ours"
else
  bad "with one slot not every cargo of the worktree root is ours"
fi

say ""
say "=== the test of the worktree of the quick gate: $FAILED failure(s) ==="
[ "$FAILED" -eq 0 ] || exit 1
exit 0
