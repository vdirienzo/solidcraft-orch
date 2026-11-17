#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The test of the token budget of a turn.
#
#   bin/test-turn-token-budget.sh
#
# It checks the three things that would break with the watchdog:
#   1. a turn that goes over the budget is STOPPED and the marker is written
#      (the supervisor reads the marker: the turn is handled like a killed
#      turn, because a turn stopped in the middle produces no delta);
#   2. a turn that stays under the budget is NOT stopped and leaves no marker
#      (the normal turn is not affected);
#   3. the supervisor really reads the marker: the phase ends in `failed`.
#
# The model is never called: the turn is a fake `opencode` that writes steps
# with a lot of tokens. The copy of the loop directory is what is tested, the
# real one is never touched.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
SRC="$LOOP_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/loop-budget.XXXXXX")"
FAILED=0

say() { printf '%s\n' "$*"; }
ok() { say "  PASS  $1"; }
bad() { say "  FAIL  $1"; FAILED=$((FAILED + 1)); }

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

say "=== the test of the token budget ($WORK) ==="

# --- the copy ----------------------------------------------------------------
mkdir -p "$WORK/loop/bin" "$WORK/loop/state" "$WORK/loop/logs/turns" "$WORK/loop/prompts" \
         "$WORK/repo" "$WORK/bin" "$WORK/wt"
cp -a "$SRC/bin/." "$WORK/loop/bin/"
cp -a "$SRC/prompts/." "$WORK/loop/prompts/" 2>/dev/null || true
cp -a "$SRC/baseline-failures.txt" "$WORK/loop/" 2>/dev/null || true
cp -a "$SRC/config.env" "$WORK/loop/"
: > "$WORK/loop/ledger.md"
: > "$WORK/loop/gh.env"

# The disk garbage collector is OFF: it cleans the REAL worktrees (the ones
# of the opencode sessions) and it is not what this test is about.
sed -i 's/^DISK_GC_ENABLED=.*/DISK_GC_ENABLED=0/' "$WORK/loop/config.env"

# The preflight of the agents is STUBBED: the fake turn of this test would
# answer the probe of the checker with 200 steps of tokens (the probe of the
# checker is a turn like any other), and the test is about the budget of the
# turn, not about the agents.
cat > "$WORK/loop/bin/check-agents.sh" <<'EOF'
#!/usr/bin/env bash
# The stub of the checker of the agents for the tests of the loop: the
# agent of the turn resolves.
echo "OK ${CHECK_AGENTS_RESOLVE#only:}"
exit 0
EOF
chmod 755 "$WORK/loop/bin/check-agents.sh"

# The fake turn. It writes `step_finish` events with a lot of tokens, one
# every two seconds, and it stays alive until it is stopped.
#
# It re-execs itself with its own path as argv[0] (the kernel replaces
# argv[0] with the interpreter when a script runs through a shebang, and the
# watchdog matches the turn by the name of the program and by the session id).
cat > "$WORK/bin/opencode" <<'STUB'
#!/usr/bin/env python3
"""The fake turn of the test."""
import os
import sys

CODE = """
import sys, time
sid = sys.argv[1]
tokens = int(sys.argv[2])
i = 0
while i < 200:
    sys.stdout.write('{"type":"step_finish","sessionID":"%s","part":'
                     '{"tokens":{"input":%d,"output":1000,"reasoning":0,'
                     '"cache":{"read":0,"write":0}},"cost":0.1}}\\n' % (sid, tokens))
    sys.stdout.flush()
    time.sleep(2)
    i += 1
"""

args = sys.argv[1:]
if args and args[0] == "session":
    # The janitor of the supervisor (session list / session delete): the test
    # has no sessions, and it must not touch the real ones.
    sys.exit(0)
session = ""
for index, arg in enumerate(args):
    if arg == "--session" and index + 1 < len(args):
        session = args[index + 1]
os.execv(sys.executable, [sys.argv[0], "-c", CODE, session, os.environ.get("FAKE_TOKENS", "900000")])
STUB
chmod +x "$WORK/bin/opencode"

# --- 1. the watchdog stops a turn that goes over the budget ------------------
say "--- 1. a turn over the budget is stopped ---"
LOG1="$WORK/turn1.jsonl"
MARK1="$WORK/turn1.budget"
SID1="ses_test_over_budget"
FAKE_TOKENS=900000 "$WORK/bin/opencode" run --session "$SID1" >"$LOG1" 2>&1 &
FAKE1=$!
"$WORK/loop/bin/turn-token-watchdog.py" "$LOG1" "$SID1" 100000 "$MARK1" 1 \
  >"$WORK/wd1.out" 2>"$WORK/wd1.err" &
WD1=$!

waited=0
while [ "$waited" -lt 40 ]; do
  [ -f "$MARK1" ] && break
  sleep 1
  waited=$((waited + 1))
done
if [ -f "$MARK1" ]; then
  ok "the watchdog wrote the marker (the turn was stopped)"
  spent="$(tr -dc '0-9' < "$MARK1" | head -c 14)"
  if [ "${spent:-0}" -ge 900000 ]; then
    ok "the marker holds the tokens of the turn ($spent)"
  else
    bad "the marker holds $spent tokens, which is not what the turn spent"
  fi
else
  bad "the watchdog did not write the marker"
  say "--- stderr ---"; sed 's/^/          /' "$WORK/wd1.err"
fi
wait "$WD1" 2>/dev/null
if kill -0 "$FAKE1" 2>/dev/null; then
  bad "the turn is still alive: the watchdog did not stop it"
  kill -9 "$FAKE1" 2>/dev/null
else
  ok "the turn was stopped"
fi

# --- 2. a turn under the budget is not touched -------------------------------
say "--- 2. a turn under the budget is not stopped ---"
LOG2="$WORK/turn2.jsonl"
MARK2="$WORK/turn2.budget"
SID2="ses_test_under_budget"
FAKE_TOKENS=1000 "$WORK/bin/opencode" run --session "$SID2" >"$LOG2" 2>&1 &
FAKE2=$!
"$WORK/loop/bin/turn-token-watchdog.py" "$LOG2" "$SID2" 999999999 "$MARK2" 1 \
  >"$WORK/wd2.out" 2>"$WORK/wd2.err" &
WD2=$!
sleep 8
if [ -f "$MARK2" ]; then
  bad "the watchdog wrote the marker of a turn that was under the budget"
else
  ok "the watchdog wrote no marker"
fi
if kill -0 "$FAKE2" 2>/dev/null; then
  ok "the turn is still alive"
else
  bad "the watchdog stopped a turn that was under the budget"
fi
kill -TERM "$WD2" 2>/dev/null
wait "$WD2" 2>/dev/null
kill -9 "$FAKE2" 2>/dev/null
wait "$FAKE2" 2>/dev/null

# --- 3. the supervisor reads the marker --------------------------------------
say "--- 3. the supervisor handles the turn that went over the budget ---"
python3 - "$WORK" <<'PY'
import json, os, sys
work = sys.argv[1]
sha = "0" * 40
slot = {"phase": "gated", "issue": 100, "branch": "fix/x", "pr": 10,
        "review": "aprobado", "review_sha": sha, "branch_sha": sha,
        "in_flight": {"issue": 100, "started": 1000},
        "gate": {"log": "", "sha": sha, "verdict": "PENDIENTE", "checked_at": 0},
        "consecutive_failures": 0}
state = {"version": 2, "mode": "normal", "slots": {"0": slot},
         "published": {}, "prs": {}, "done": [], "skipped": [], "triage": {},
         "report": {"last": "2026-10-24", "issue": 0, "pending": False, "sig": "1:0:0"},
         "approval_asked": {}, "counters": {"iterations": 0, "failures": 0, "consecutive": 0},
         "attempts": {}, "open_unmerged": 0, "allow_new_prs": True,
         "gate": {"slot": "", "log": "", "sha": "", "pid": 0, "started": 0, "verdict": "PENDIENTE"}}
with open(os.path.join(work, "loop", "state.json"), "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2)
PY

# The budget lives in the config of the loop, not in the environment: the
# supervisor sources config.env OVER the environment. The same is true of
# REPO: without this the test would create worktrees in the REAL repository.
# The FORK is faked too: without this the test would create the daily log
# issue in the REAL repository.
sed -i 's/^TURN_TOKEN_BUDGET=.*/TURN_TOKEN_BUDGET=100000/' "$WORK/loop/config.env"
sed -i "s|^REPO=.*|REPO=$WORK/repo|" "$WORK/loop/config.env"
sed -i "s|^GATE_WORKTREE=.*|GATE_WORKTREE=$WORK/gate|" "$WORK/loop/config.env"
sed -i "s|^FORK=.*|FORK=https://example.invalid/nonexistent/solidcraft|" "$WORK/loop/config.env"

# OPENCODE_BIN is the fake turn: the supervisor puts the real binary of
# OpenCode ($HOME/.opencode/bin) BEFORE the inherited PATH, so the PATH alone
# cannot replace it, and a real turn would spend money and touch the real
# repository.
PATH="$WORK/bin:$PATH" SLOT=0 LOOP_DIR="$WORK/loop" REPO="$WORK/repo" \
  SOLIDCRAFT_WT_ROOT="$WORK/wt" MAX_LOAD=1000 MAX_TURN_MIN=5 \
  FAKE_TOKENS=900000 \
  OPENCODE_BIN="$WORK/bin/opencode" \
  timeout 180 bash "$WORK/loop/bin/supervisor.sh" >"$WORK/sup.out" 2>&1
sup_rc=$?
say "  the supervisor finished with rc=$sup_rc"
if grep -q "went over its token budget" "$WORK/sup.out"; then
  ok "the supervisor saw the budget stop"
else
  bad "the supervisor did not see the budget stop"
  tail -20 "$WORK/sup.out" | sed 's/^/          /'
fi
phase="$(python3 -c "
import json
s=json.load(open('$WORK/loop/state.json'))
slots=s.get('slots') or {}
print((slots.get('0') or {}).get('phase',''))
" 2>/dev/null)"
if [ "$phase" = "failed" ]; then
  ok "the phase of the slot is 'failed' (the stopped turn produced no delta)"
else
  bad "the phase of the slot is '$phase', it should be 'failed'"
fi
if [ -z "$(find "$WORK/loop/logs/turns" -name '*.budget' 2>/dev/null)" ]; then
  ok "the marker was cleaned up"
else
  bad "the marker was left in the turn directory"
fi

say ""
if [ "$FAILED" -eq 0 ]; then
  say "=== everything passed ==="
else
  say "=== $FAILED check(s) failed ==="
fi
exit "$FAILED"
