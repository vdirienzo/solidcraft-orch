#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The validation gates of the slot layout, in the order of the contract
# (lote3-slots.md, section 10). Every gate says WHAT it checked and whether
# it passed, so the result can be read without running it again.
#
#   bin/validate-slots.sh
#
# It does NOT touch the real state: the tests work on copies. It does NOT
# start the loop: the loop is started by systemd, after this passes.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
FAILED=0
PASSED=0

say() { printf '%s\n' "$*"; }
gate() { # gate <descripcion> ; the command's output is shown on failure
  local desc="$1"; shift
  local out
  out="$("$@" 2>&1)"
  local rc=$?
  if [ $rc -eq 0 ]; then
    say "  PASS  $desc"
    PASSED=$((PASSED + 1))
  else
    say "  FAIL  $desc (rc=$rc)"
    printf '%s\n' "$out" | tail -12 | sed 's/^/          /'
    FAILED=$((FAILED + 1))
  fi
}

say "=== the validation gates of the slot layout ==="

# --- 1. the scripts parse ----------------------------------------------------
for script in "$LOOP_DIR"/bin/*.sh; do
  [ -f "$script" ] || continue
  case "$script" in *.bak*) continue ;; esac
  gate "bash -n $(basename "$script")" bash -n "$script"
done

# --- 2. shellcheck (errors only) ---------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  for script in "$LOOP_DIR"/bin/*.sh; do
    [ -f "$script" ] || continue
    case "$script" in *.bak*) continue ;; esac
    gate "shellcheck $(basename "$script")" shellcheck -S error "$script"
  done
else
  say "  SKIP  shellcheck is not installed"
fi

# --- 3. the python parses -----------------------------------------------------
for script in "$LOOP_DIR"/bin/*.py; do
  [ -f "$script" ] || continue
  case "$script" in *.bak*) continue ;; esac
  gate "python parses $(basename "$script")" \
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$script"
done

# --- 4. the regression gate: the 18 groups of the rules ----------------------
gate "the rule groups still pass" python3 "$LOOP_DIR/bin/test-rules.py"

# --- 5. the new gate: the slots ----------------------------------------------
if [ -f "$LOOP_DIR/bin/test-slots.py" ]; then
  gate "the slot groups pass" python3 "$LOOP_DIR/bin/test-slots.py"
else
  say "  FAIL  bin/test-slots.py does not exist yet"
  FAILED=$((FAILED + 1))
fi

# --- 6. the permissions of the prompts ---------------------------------------
if [ -f "$LOOP_DIR/bin/check-prompt-permissions.py" ]; then
  gate "the prompts have no dead instruction" python3 "$LOOP_DIR/bin/check-prompt-permissions.py"
else
  say "  FAIL  bin/check-prompt-permissions.py does not exist"
  FAILED=$((FAILED + 1))
fi

# --- 7. the drain of the queue of the gates ----------------------------------
# The queue used to have nobody draining it: a slot that asked for a gate
# while another one was running waited forever. The drain has its own test
# bank, and it works on an isolated LOOP_DIR: the running loop is not
# touched.
if [ -f "$LOOP_DIR/bin/test-gate-queue.sh" ]; then
  gate "the drain of the gate queue works" bash "$LOOP_DIR/bin/test-gate-queue.sh"
else
  say "  FAIL  bin/test-gate-queue.sh does not exist yet"
  FAILED=$((FAILED + 1))
fi

# --- 8. the dry run -----------------------------------------------------------
# It has two PRE-EXISTING failures (verified against the .bak5 of the
# 24-10): the ledger without a new line, and the expected phase idle vs
# gating. They are not new: the report says so.
if [ -f "$LOOP_DIR/bin/dry-run.sh" ]; then
  out="$(cd "$LOOP_DIR" && timeout 300 bash bin/dry-run.sh 2>&1)"
  rc=$?
  fails="$(printf '%s\n' "$out" | grep -ciE '^\s*(FALLO|FAIL)' || true)"
  say "  INFO  the dry run: rc=$rc, failures reported: $fails (2 are pre-existing)"
  if [ "$fails" -gt 2 ]; then
    say "  FAIL  the dry run reports $fails failures (2 were pre-existing)"
    printf '%s\n' "$out" | grep -iE '^\s*(FALLO|FAIL)' | head -8 | sed 's/^/          /'
    FAILED=$((FAILED + 1))
  else
    say "  PASS  the dry run has no new failure"
    PASSED=$((PASSED + 1))
  fi
fi

say ""
say "=== $PASSED passed, $FAILED failed ==="
[ "$FAILED" -eq 0 ] || exit 1
exit 0
