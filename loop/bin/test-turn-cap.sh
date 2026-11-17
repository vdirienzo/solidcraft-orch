#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-turn-cap.sh - the daily turn cap counts the turns of THIS slot.
#
# The cap is a GLOBAL cost split between the slots: each slot may do
# MAX_TURNS_PER_DAY / MAX_SLOTS turns of the day. It counted EVERY turn of
# the day (the name of the log of a turn did not carry the slot) and
# compared the total against the SHARE of one slot: with two slots the loop
# stopped at 144 turns of the day, half of the 288 that config.env
# documents. On the 25-10 that cost 176 skipped turns and 4 h 22 min of
# machine time.
#
# The test is HERMETIC:
#   * its own loop directory: its own config.env, its own state, its own
#     logs. The live loop is never read nor written;
#   * its own HOME: the worktree of an issue is never found in the real one;
#   * a fake `gh` first in the PATH: GitHub is never contacted.
#
# It runs the supervisor that RUNS (the one of the runtime directory), not a
# copy of it, so it tests the deployed script. Override it with
# SUPERVISOR=/path/to/supervisor.sh.
#
# Run:  bash ~/.local/share/solidcraft-loop/bin/test-turn-cap.sh
# ---------------------------------------------------------------------------
set -uo pipefail

SRC="${SRC:-$HOME/.local/share/solidcraft-loop}"
SUPERVISOR="${SUPERVISOR:-$SRC/bin/supervisor.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/loop-turn-cap.XXXXXX")"
FAILED=0

say() { printf '%s\n' "$*"; }
ok() { say "  PASS  $1"; }
bad() { say "  FAIL  $1"; FAILED=$((FAILED + 1)); }

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

say "=== the test of the daily turn cap ($WORK) ==="

if [ ! -f "$SUPERVISOR" ]; then
  say "the supervisor under test is not there: $SUPERVISOR"
  exit 1
fi

# --- the copy ----------------------------------------------------------------
mkdir -p "$WORK/loop/bin" "$WORK/loop/state" "$WORK/loop/logs/turns" \
         "$WORK/bin" "$WORK/home" "$WORK/repo"
cp -a "$SRC/bin/." "$WORK/loop/bin/" 2>/dev/null || true
# The supervisor under test goes LAST: the copy of the runtime above brings
# its own supervisor.sh, and the SUPERVISOR of the command line is the one
# that has to be tested (the override only worked if it was copied after).
cp -a "$SUPERVISOR" "$WORK/loop/bin/supervisor.sh"
cp -a "$SRC/config.env" "$WORK/loop/config.env" 2>/dev/null || true
cp -a "$SRC/baseline-failures.txt" "$WORK/loop/" 2>/dev/null || true
: > "$WORK/loop/gh.env"
: > "$WORK/loop/ledger.md"

# The preflight of the agents is STUBBED: this test is about the cap of the
# turns, and the HOME of the test has no agents (opencode would not resolve
# them and every turn would stop at the preflight). The stub says that the
# agent of the turn resolves; the case that checks the opposite installs its
# own stub further down.
cat > "$WORK/loop/bin/check-agents.sh" <<'EOF'
#!/usr/bin/env bash
# The stub of the checker of the agents for the tests of the loop: the
# agent of the turn resolves.
echo "OK ${CHECK_AGENTS_RESOLVE#only:}"
exit 0
EOF
chmod 755 "$WORK/loop/bin/check-agents.sh"

# The cap of the test: 4 turns of the day, 2 slots, so the share of a slot
# is 2. The values live in the config.env, which the supervisor sources OVER
# the environment, so they are changed there.
sed -i 's/^MAX_TURNS_PER_DAY=.*/MAX_TURNS_PER_DAY=4/' "$WORK/loop/config.env"
sed -i 's/^MAX_SLOTS=.*/MAX_SLOTS=2/' "$WORK/loop/config.env"
# The disk garbage collector is OFF: it is a cleanup of the REAL worktrees
# (it deletes the ones of the opencode sessions), it is not what this test
# is about, and on a busy machine it takes more than the timeout of the
# test.
sed -i 's/^DISK_GC_ENABLED=.*/DISK_GC_ENABLED=0/' "$WORK/loop/config.env"
MAX_TURNS="$(sed -n 's/^MAX_TURNS_PER_DAY=\([0-9][0-9]*\).*/\1/p' "$WORK/loop/config.env")"
MAX_SLOTS="$(sed -n 's/^MAX_SLOTS=\([0-9][0-9]*\).*/\1/p' "$WORK/loop/config.env")"
case "$MAX_TURNS" in ''|*[!0-9]*) MAX_TURNS=4 ;; esac
case "$MAX_SLOTS" in ''|*[!0-9]*) MAX_SLOTS=2 ;; esac
SHARE=$(( MAX_TURNS / MAX_SLOTS ))
[ "$SHARE" -ge 1 ] || SHARE=1
say "  the cap of the test: $MAX_TURNS turns of the day, $MAX_SLOTS slots, share $SHARE"

# --- the fake `gh` ------------------------------------------------------------
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
# The `gh` of the tests: no GitHub, no network.
case "$1 $2" in
  "api user") printf '%s\n' "vdirienzo"; exit 0 ;;
  "pr list")  printf '%s\n' "[]"; exit 0 ;;
  "pr view")  printf '%s\n' "[]"; exit 0 ;;
  "issue list") printf '%s\n' "[]"; exit 0 ;;
  "issue create") printf '%s\n' "1"; exit 0 ;;
esac
exit 1
EOF
chmod 755 "$WORK/bin/gh"

# --- the state ----------------------------------------------------------------
python3 - "$WORK" <<'PY'
import json, os, sys
work = sys.argv[1]
sha = "0" * 40
slot = {"phase": "gated", "issue": 100, "branch": "fix/x", "pr": 10,
        "review": "aprobado", "review_sha": sha, "branch_sha": sha,
        "in_flight": {"issue": 100, "started": 1000},
        "gate": {"log": "", "sha": sha, "verdict": "PENDIENTE", "checked_at": 0},
        "consecutive_failures": 0}
state = {
    "version": 2, "mode": "normal",
    "slots": {"0": slot},
    "published": {}, "prs": {}, "done": [], "skipped": [], "triage": {},
    # the report is NEVER posted by the test
    "report": {"last": "2026-10-23", "issue": 1, "pending": False,
               "comment_id": 0, "sig": "0:0:0"},
    "approval_asked": {}, "counters": {"iterations": 0, "failures": 0, "consecutive": 0},
    "attempts": {}, "open_unmerged": 0, "allow_new_prs": True,
    "gate": {"slot": "", "log": "", "sha": "", "pid": 0, "started": 0, "verdict": "PENDIENTE"},
}
with open(os.path.join(work, "loop", "state.json"), "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2)
PY

# --- the helpers ---------------------------------------------------------------
DAY_UTC="$(date -u +%F)"
TURNS="$WORK/loop/logs/turns"

run_slot0() {
  local out="$1"
  ( cd "$WORK" && PATH="$WORK/bin:$PATH" HOME="$WORK/home" REPO="$WORK/repo" \
      SLOT=0 DRY_RUN=1 LOOP_DIR="$WORK/loop" MAX_LOAD=1000 \
      timeout 120 bash "$WORK/loop/bin/supervisor.sh" >"$out" 2>&1 )
}

fake_turns() {
  local slot="$1" count="$2" i=0
  while [ "$i" -lt "$count" ]; do
    i=$(( i + 1 ))
    : > "$TURNS/${DAY_UTC}T000000Z-9${i}-slot${slot}.jsonl"
  done
}

clear_turns() { rm -f "$TURNS"/*.jsonl 2>/dev/null || true; }

# --- 1. the turns of the OTHER slot do not count against this one -------------
say "--- the turns of the other slot ---"
clear_turns
fake_turns 1 "$SHARE"
run_slot0 "$WORK/a.out"
if grep -q 'daily turn cap reached' "$WORK/a.out" 2>/dev/null; then
  bad "the $SHARE turns of the other slot stopped this one (the cap is per slot)"
  say "--- the output ---"; tail -8 "$WORK/a.out" | sed 's/^/          /'
elif grep -q 'turn finished' "$WORK/a.out" 2>/dev/null; then
  ok "the $SHARE turns of the other slot did not stop this one"
else
  bad "the turn did not finish (the test needs a turn that runs)"
  say "--- the output ---"; tail -12 "$WORK/a.out" | sed 's/^/          /'
fi

# --- 2. the turns of THIS slot count -------------------------------------------
say "--- the turns of this slot ---"
clear_turns
fake_turns 0 "$SHARE"
run_slot0 "$WORK/b.out"
if grep -q 'daily turn cap reached' "$WORK/b.out" 2>/dev/null; then
  ok "the $SHARE turns of this slot stopped it (the cap still applies)"
else
  bad "the $SHARE turns of this slot did not stop it (the cap is gone)"
  say "--- the output ---"; tail -12 "$WORK/b.out" | sed 's/^/          /'
fi

# --- 3. the log of the turn carries the slot ----------------------------------
say "--- the name of the log of the turn ---"
clear_turns
run_slot0 "$WORK/c.out"
if ls "$TURNS"/*-slot0.jsonl >/dev/null 2>&1; then
  ok "the log of the turn carries the slot (the cap can count it)"
else
  bad "the log of the turn does not carry the slot"
  ls -1 "$TURNS" 2>/dev/null | sed 's/^/          /'
fi

# --- 4. the turn writes the digest of the slot --------------------------------
# The digest is what the model reads FIRST: the state of the slot and the
# last turns of the ledger, with a fixed ceiling. Without it the model
# reads the view whole and the ledger whole (3,41 M of tokens in 24 h).
say "--- the digest of the slot ---"
DIGEST="$WORK/loop/state/slot-0.digest.md"
if [ -s "$DIGEST" ]; then
  ok "the turn wrote the digest of the slot"
else
  bad "the turn did not write the digest of the slot"
  ls -1 "$WORK/loop/state" 2>/dev/null | sed 's/^/          /'
fi
if grep -q '^## Tu slot' "$DIGEST" 2>/dev/null; then
  ok "the digest carries the state of the slot"
else
  bad "the digest does not carry the state of the slot"
fi

# --- 4. the turn does not start when the agent does not resolve ---------------
# The agent of the turn is broken: opencode answers "Agent not found" and
# the turn dies before its first step. On the 26-10 that was 137 turns and
# 2 h 55 min of a loop that did nothing at all, with nothing in the log but
# the error of a turn that never ran. The preflight of the supervisor sees
# it BEFORE the worktree is touched, and says so.
say "--- the turn with an agent that does not resolve ---"
clear_turns
cat > "$WORK/loop/bin/check-agents.sh" <<'EOF'
#!/usr/bin/env bash
# The stub of a broken agent: opencode does not resolve it.
echo "OPENCODE NO RESUELVE ${CHECK_AGENTS_RESOLVE#only:}: Agent not found"
exit 1
EOF
chmod 755 "$WORK/loop/bin/check-agents.sh"
run_slot0 "$WORK/d.out"
rc=$?
if [ "$rc" = "1" ] && grep -q 'the turn is not started' "$WORK/d.out" 2>/dev/null; then
  ok "the turn did not start with an agent that does not resolve"
else
  bad "the turn started with an agent that does not resolve (rc=$rc)"
  say "--- the output ---"; tail -12 "$WORK/d.out" | sed 's/^/          /'
fi
if grep -q 'dry run: the model was not called' "$WORK/d.out" 2>/dev/null; then
  bad "the turn ran the model with an agent that does not resolve"
  say "--- the output ---"; tail -12 "$WORK/d.out" | sed 's/^/          /'
else
  ok "the model was not called with an agent that does not resolve"
fi

say ""
say "=== the test of the daily turn cap: $FAILED failure(s) ==="
[ "$FAILED" -eq 0 ] || exit 1
exit 0
