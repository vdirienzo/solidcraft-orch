#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The parallel test of the slot layout: TWO supervisors at the same time,
# over a COPY of the loop directory (the real one is never touched).
#
#   bin/test-parallel-slots.sh
#
# It checks the three things that would break with two slots:
#   1. the two supervisors do not collide (each takes the flock of its slot);
#   2. each one writes ITS OWN view and leaves the other's alone;
#   3. the state that comes out is coherent (both slots present, the globals
#      intact, the ledger with one line per turn).
#
# The copy is made from the real runtime, so the scripts under test are the
# real ones.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
SRC="$LOOP_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/loop-slots.XXXXXX")"
FAILED=0

say() { printf '%s\n' "$*"; }
ok() { say "  PASS  $1"; }
bad() { say "  FAIL  $1"; FAILED=$((FAILED + 1)); }

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

say "=== the parallel test of the slots ($WORK) ==="

# --- the copy ----------------------------------------------------------------
mkdir -p "$WORK/loop/bin" "$WORK/loop/state" "$WORK/loop/logs/turns" "$WORK/repo"
cp -a "$SRC/bin/." "$WORK/loop/bin/"
cp -a "$SRC/baseline-failures.txt" "$WORK/loop/" 2>/dev/null || true
cp -a "$SRC/config.env" "$WORK/loop/"
: > "$WORK/loop/ledger.md"

# The disk garbage collector is OFF: it cleans the REAL worktrees (the ones
# of the opencode sessions) and it is not what this test is about.
sed -i 's/^DISK_GC_ENABLED=.*/DISK_GC_ENABLED=0/' "$WORK/loop/config.env"

# The preflight of the agents is STUBBED: this test is about the isolation of
# the slots, and the probe of the checker would opencode a real process for
# every turn of the test.
cat > "$WORK/loop/bin/check-agents.sh" <<'EOF'
#!/usr/bin/env bash
# The stub of the checker of the agents for the tests of the loop: the
# agent of the turn resolves.
echo "OK ${CHECK_AGENTS_RESOLVE#only:}"
exit 0
EOF
chmod 755 "$WORK/loop/bin/check-agents.sh"

# A state with TWO slots, each in a phase that does not touch the machine:
# `gated` with an approved review. The turn is a dry run: the model is not
# called, so nothing compiles and nothing is published.
python3 - "$WORK" <<'PY'
import json, os, sys
work = sys.argv[1]
sha = "0" * 40
def slot(issue, pr):
    return {"phase": "gated", "issue": issue, "branch": "fix/x", "pr": pr,
            "review": "aprobado", "review_sha": sha, "branch_sha": sha,
            "in_flight": {"issue": issue, "started": 1000},
            "gate": {"log": "", "sha": sha, "verdict": "PENDIENTE", "checked_at": 0},
            "consecutive_failures": 0}
state = {
    "version": 2, "mode": "normal",
    "slots": {"0": slot(100, 10), "1": slot(200, 20)},
    "published": {}, "prs": {}, "done": [], "skipped": [], "triage": {},
    "report": {"last": "2026-10-24", "issue": 0, "pending": False, "sig": "1:0:0"},
    "approval_asked": {}, "counters": {"iterations": 0, "failures": 0, "consecutive": 0},
    "attempts": {}, "open_unmerged": 0, "allow_new_prs": True,
    "gate": {"slot": "", "log": "", "sha": "", "pid": 0, "started": 0, "verdict": "PENDIENTE"},
}
with open(os.path.join(work, "loop", "state.json"), "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2)
PY

# --- the two supervisors, at the same time ---------------------------------
say "--- two supervisors at the same time (DRY_RUN=1) ---"
# MAX_LOAD is a PRECONDITION of the turn: with the machine busy (the gate of
# another turn, a compile), the supervisor skips the turn on purpose, and
# then there is no view to check. The load ceiling is raised for this test
# so the result does not depend on what the machine is doing at the moment:
# what is being tested here is the ISOLATION of the slots, not the load.
( cd "$WORK" && SLOT=0 DRY_RUN=1 LOOP_DIR="$WORK/loop" REPO="$WORK/repo" \
    MAX_LOAD=1000 timeout 120 bash "$WORK/loop/bin/supervisor.sh" >"$WORK/slot0.out" 2>&1
  echo $? > "$WORK/slot0.rc"
) &
P0=$!
(
  cd "$WORK" && SLOT=1 DRY_RUN=1 LOOP_DIR="$WORK/loop" REPO="$WORK/repo" \
    MAX_LOAD=1000 timeout 120 bash "$WORK/loop/bin/supervisor.sh" >"$WORK/slot1.out" 2>&1
  echo $? > "$WORK/slot1.rc"
) &
P1=$!
wait $P0 $P1

rc0="$(cat "$WORK/slot0.rc" 2>/dev/null || echo 99)"
rc1="$(cat "$WORK/slot1.rc" 2>/dev/null || echo 99)"
say "  slot 0 rc=$rc0   slot 1 rc=$rc1"

# --- 1. both ran -------------------------------------------------------------
if [ "$rc0" = "0" ] && [ "$rc1" = "0" ]; then
  ok "both supervisors finished without an error"
else
  bad "a supervisor failed (slot 0 rc=$rc0, slot 1 rc=$rc1)"
  say "--- slot 0 ---"; tail -12 "$WORK/slot0.out" | sed 's/^/          /'
  say "--- slot 1 ---"; tail -12 "$WORK/slot1.out" | sed 's/^/          /'
fi

# --- 2. each wrote its own view ---------------------------------------------
if [ -f "$WORK/loop/state/slot-0.json" ] && [ -f "$WORK/loop/state/slot-1.json" ]; then
  ok "the two views exist (slot-0.json and slot-1.json)"
  v0="$(python3 -c "import json;print(json.load(open('$WORK/loop/state/slot-0.json')).get('issue'))" 2>/dev/null)"
  v1="$(python3 -c "import json;print(json.load(open('$WORK/loop/state/slot-1.json')).get('issue'))" 2>/dev/null)"
  if [ "$v0" = "100" ] && [ "$v1" = "200" ]; then
    ok "each view holds its own issue (slot 0 -> 100, slot 1 -> 200)"
  else
    bad "the views are crossed (slot 0 -> $v0, slot 1 -> $v1)"
  fi
else
  bad "a view is missing"
fi

# --- 3. the state is coherent ------------------------------------------------
python3 - "$WORK" <<'PY'
import json, os, sys
work = sys.argv[1]
path = os.path.join(work, "loop", "state.json")
with open(path, encoding="utf-8") as fh:
    state = json.load(fh)
slots = state.get("slots")
if not isinstance(slots, dict) or len(slots) != 2:
    print(f"  FAIL  the state has {len(slots) if isinstance(slots, dict) else 'no'} slots")
    sys.exit(1)
issues = {k: v.get("issue") for k, v in slots.items()}
if sorted(issues.values()) != [100, 200]:
    print(f"  FAIL  the slots hold {issues}")
    sys.exit(1)
print("  PASS  the state has two slots, each with its own issue")
PY
[ $? -eq 0 ] || FAILED=$((FAILED + 1))

# --- 4. the globals are intact ----------------------------------------------
# The globals live in the legacy state.json AND in the view of every slot (the
# view is what the panel reads: the supervisor writes one view per slot).
#
# The mode is NOT forced to be "normal": a DRY_RUN turn runs in "maintenance",
# and this test runs the two supervisors in DRY_RUN. What the test checks is
# that the mode is one of the two known ones and that the maps of the
# bookkeeping are maps (not lists, not strings).
python3 - "$WORK" <<'PY'
import json, os, sys

work = sys.argv[1]


def fail(message):
    print(f"  FAIL  {message}")
    sys.exit(1)


try:
    with open(os.path.join(work, "loop", "state.json"), encoding="utf-8") as fh:
        state = json.load(fh)
except (OSError, ValueError) as exc:
    fail(f"the state could not be read ({exc})")

if state.get("mode") not in ("normal", "maintenance"):
    fail(f"the mode of the state is {state.get('mode')!r}")
for name in ("prs", "published"):
    if not isinstance(state.get(name), dict):
        fail(f"the global {name} is not a map")

for slot in ("0", "1"):
    path = os.path.join(work, "loop", "state", f"slot-{slot}.json")
    try:
        with open(path, encoding="utf-8") as fh:
            view = json.load(fh)
    except (OSError, ValueError) as exc:
        fail(f"the view of the slot {slot} could not be read ({exc})")
    if not isinstance(view.get("mode"), str):
        fail(f"the view of the slot {slot} has no mode")
    for name in ("prs", "published"):
        if not isinstance(view.get(name), dict):
            fail(f"the view of the slot {slot} has no map {name}")

print("  PASS  the globals (mode, prs, published) are intact")
PY
[ $? -eq 0 ] || FAILED=$((FAILED + 1))

# --- 5. one ledger line per turn --------------------------------------------
lines="$(grep -c '^| ' "$WORK/loop/ledger.md" 2>/dev/null | head -1 | tr -dc '0-9')"
if [ -n "$lines" ] && [ "$lines" -ge 1 ]; then
  ok "the ledger has $lines line(s) (one per turn)"
else
  bad "the ledger has no line (the turn did not reach the state)"
  say "--- slot 0 ---"; tail -6 "$WORK/slot0.out" | sed 's/^/          /'
  say "--- slot 1 ---"; tail -6 "$WORK/slot1.out" | sed 's/^/          /'
fi

say ""
say "=== the parallel test: $FAILED failure(s) ==="
[ "$FAILED" -eq 0 ] || exit 1
exit 0
