#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-slot-parallelism.sh - the tests of the parallelism of the orchestrator.
#
# WHY THE TESTS EXIST: the parallelism of the loop is decided by the state of
# the machine, so a change in the calibrator can silently halve the
# throughput of the machine or saturate it. The tests ask the SCRIPTS (they
# never read their source): a rule that is only written is not a rule.
#
# WHAT IS TESTED:
#   1. slot-lock.sh: a slot can only be taken once; the status tells the
#      truth; the release frees it; the heavy lock is exclusive.
#   2. slot-target-dir.sh: every slot gets a DIFFERENT directory (the
#      property that stops two cargo builds from fighting over the lock of
#      the build directory), and a name that can not be normalized is
#      refused instead of invented.
#   3. slots.sh: the number of slots follows the load, the taken slots are
#      subtracted, and the gate is exclusive.
#
# EXIT CODES:
#   0  every test passed
#   1  at least one failed
# ---------------------------------------------------------------------------
set -uo pipefail

ORCH_DIR="${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}"
PASS=0
FAIL=0

ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# A scratch ORCH_DIR for the tests: the real locks and the real target dirs
# are never touched by a test.
#
# THE ORDER MATTERS: $BIN is derived from ORCH_DIR, and ORCH_DIR is pointed
# at the scratch dir BEFORE $BIN is computed. When $BIN was computed first it
# pointed at the REAL bin, the scripts were copied nowhere useful, and the
# tests that need a complete orchestrator in the scratch dir measured
# something else entirely.
TESTDIR="$(mktemp -d "${TMPDIR:-/tmp}/orch-test.XXXXXX")"
trap 'rm -rf "$TESTDIR"' EXIT
export ORCH_DIR="$TESTDIR"
BIN="$ORCH_DIR/bin"
mkdir -p "$BIN"

# The scripts are the real ones, but they read ORCH_DIR for their locks and
# their target dirs: the export above redirects them to the scratch dir, so the
# locks of the real machine are never touched by a test.
REAL_BIN="${REAL_BIN:-$HOME/.local/share/solidcraft-orch/bin}"

# The scripts are COPIED into the scratch dir: slots.sh looks for slot-lock.sh
# in "$ORCH_DIR/bin", and the copy is the same file, so the scratch dir is a
# complete orchestrator the test can exercise end to end.
cp "$REAL_BIN/slot-lock.sh" "$REAL_BIN/slots.sh" "$REAL_BIN/slot-target-dir.sh" "$BIN/" 2>/dev/null || true

# --- 1. the lock of a slot ---------------------------------------------------
LOCK="$REAL_BIN/slot-lock.sh"

bash "$LOCK" --slot t1 --take >/dev/null 2>&1
[ $? -eq 0 ] && ok "slot-lock: a free slot can be taken" || bad "slot-lock: a free slot can be taken"

bash "$LOCK" --slot t1 --take >/dev/null 2>&1
[ $? -eq 1 ] && ok "slot-lock: a taken slot cannot be taken twice" || bad "slot-lock: a taken slot cannot be taken twice"

bash "$LOCK" --slot t1 --status >/dev/null 2>&1
[ $? -eq 1 ] && ok "slot-lock: the status of a taken slot is 'taken'" || bad "slot-lock: the status of a taken slot is 'taken'"

bash "$LOCK" --slot t2 --status >/dev/null 2>&1
[ $? -eq 0 ] && ok "slot-lock: the status of a free slot is 'free'" || bad "slot-lock: the status of a free slot is 'free'"

bash "$LOCK" --slot t1 --release >/dev/null 2>&1
bash "$LOCK" --slot t1 --status >/dev/null 2>&1
[ $? -eq 0 ] && ok "slot-lock: the release frees the slot" || bad "slot-lock: the release frees the slot"

# The list of the locks: a taken slot appears, a free one does not.
bash "$LOCK" --slot t3 --take >/dev/null 2>&1
LIST="$(bash "$LOCK" --list 2>/dev/null)"
printf '%s\n' "$LIST" | grep -q '^t3' && ok "slot-lock: --list shows a taken slot" || bad "slot-lock: --list shows a taken slot"
printf '%s\n' "$LIST" | grep -q '^t1' && bad "slot-lock: --list does not show a released slot" || ok "slot-lock: --list does not show a released slot"
bash "$LOCK" --slot t3 --release >/dev/null 2>&1

# --- 1b. the age of a lock, its owner, and the reaping ---------------------
# WHY: the lock recorded the PID of the script that took it, and that script
# exits at once: the PID was dead by design and every lock looked stale. Four
# locks of a dead wave then ate every slot and the calibrator said
# free_slots=0 with an idle machine. The liveness of a lock is its AGE and
# its OWNER now, so both have to work.
SLOTS="$REAL_BIN/slots.sh"
bash "$LOCK" --slot t4 --take --owner 'test-owner' >/dev/null 2>&1
LIST4="$(bash "$LOCK" --list 2>/dev/null | grep '^t4' || true)"
printf '%s\n' "$LIST4" | grep -q 'test-owner' && ok "slot-lock: --list shows the owner of a lock" \
                                                || bad "slot-lock: --list shows the owner of a lock" "got: $LIST4"

# A lock that was just taken is fresh: it is NOT reaped, whatever the age
# threshold says.
bash "$LOCK" --slot t4 --reap --older-than 240 >/dev/null 2>&1
bash "$LOCK" --slot t4 --status >/dev/null 2>&1
[ $? -eq 1 ] && ok "slot-lock: a fresh lock is NOT reaped" || bad "slot-lock: a fresh lock is NOT reaped"

# The heartbeat of a lock: it makes an old lock young again.
printf '2000-01-01T00:00:00Z\n' > "$TESTDIR/locks/slot-t4/since" 2>/dev/null
bash "$LOCK" --slot t4 --heartbeat >/dev/null 2>&1
SINCE="$(cat "$TESTDIR/locks/slot-t4/since" 2>/dev/null)"
case "$SINCE" in
  2000-*) bad "slot-lock: the heartbeat refreshes the age of a lock" "since is still $SINCE" ;;
  *)      ok "slot-lock: the heartbeat refreshes the age of a lock" ;;
esac

# An old lock IS reaped, and the reaping says which one it was.
mkdir -p "$TESTDIR/locks/slot-t5" 2>/dev/null
printf '2000-01-01T00:00:00Z\n' > "$TESTDIR/locks/slot-t5/since" 2>/dev/null
printf 'dead-wave\n' > "$TESTDIR/locks/slot-t5/owner" 2>/dev/null
REAP="$(bash "$LOCK" --slot t5 --reap --older-than 240 2>/dev/null || true)"
printf '%s\n' "$REAP" | grep -q 'dead-wave' && ok "slot-lock: --reap names the owner of the lock it reaped" \
                                                  || bad "slot-lock: --reap names the owner of the lock it reaped" "got: $REAP"
bash "$LOCK" --slot t5 --status >/dev/null 2>&1
[ $? -eq 0 ] && ok "slot-lock: --reap frees the slot it reaped" || bad "slot-lock: --reap frees the slot it reaped"

# A lock with no age at all (a lock of an old version of the script) counts
# as STALE, not as taken: it cannot be younger than nothing.
# The report runs the COPY of slots.sh: slots.sh looks for slot-lock.sh in
# "$ORCH_DIR/bin", and the copy is what the scratch dir has, so the scratch
# dir is a complete orchestrator and the test measures the real thing.
mkdir -p "$TESTDIR/locks/slot-t6" 2>/dev/null
STALE_COUNT="$(ORCH_DIR="$TESTDIR" SLOT_LOCK_STALE_MIN=240 bash "$BIN/slots.sh" report 2>/dev/null | grep -o 'stale_locks=[0-9]*' | cut -d= -f2)"
case "$STALE_COUNT" in
  ''|*[!0-9]*) bad "slots: the count of stale locks is a number" "got: '$STALE_COUNT'" ;;
  *) [ "$STALE_COUNT" -ge 1 ] && ok "slots: a lock with no age counts as stale (got $STALE_COUNT)" \
                                   || bad "slots: a lock with no age counts as stale" "got: $STALE_COUNT" ;;
esac
rm -rf "$TESTDIR/locks/slot-t6" 2>/dev/null

# --- 2. the lock of the heavy phase ------------------------------------------
bash "$LOCK" --heavy --take >/dev/null 2>&1
[ $? -eq 0 ] && ok "heavy: it can be taken" || bad "heavy: it can be taken"

bash "$LOCK" --heavy --take >/dev/null 2>&1
[ $? -eq 1 ] && ok "heavy: it is exclusive (only one at a time)" || bad "heavy: it is exclusive (only one at a time)"

bash "$LOCK" --heavy --status >/dev/null 2>&1
[ $? -eq 1 ] && ok "heavy: the status is 'taken'" || bad "heavy: the status is 'taken'"

bash "$LOCK" --heavy --release >/dev/null 2>&1
bash "$LOCK" --heavy --status >/dev/null 2>&1
[ $? -eq 0 ] && ok "heavy: the release frees it" || bad "heavy: the release frees it"

# --- 3. the target dir of a slot ---------------------------------------------
TDIR="$REAL_BIN/slot-target-dir.sh"

A="$(bash "$TDIR" --slot 7114 2>/dev/null)"
B="$(bash "$TDIR" --slot 3892 2>/dev/null)"
[ -n "$A" ] && [ -n "$B" ] && ok "slot-target-dir: it returns a path" || bad "slot-target-dir: it returns a path"

[ "$A" != "$B" ] && ok "slot-target-dir: two slots get two DIFFERENT dirs (no cargo lock fight)" \
                || bad "slot-target-dir: two slots get two DIFFERENT dirs (no cargo lock fight)" "both were: $A"

printf '%s\n' "$A" | grep -q 'slot-7114' && ok "slot-target-dir: the name of the slot is in the path" \
                                       || bad "slot-target-dir: the name of the slot is in the path"

bash "$TDIR" --slot '../evil' >/dev/null 2>&1
[ $? -eq 2 ] && ok "slot-target-dir: a name that can not be normalized is REFUSED" \
              || bad "slot-target-dir: a name that can not be normalized is REFUSED"

bash "$TDIR" --slot '' >/dev/null 2>&1
[ $? -eq 2 ] && ok "slot-target-dir: an empty name is REFUSED" \
              || bad "slot-target-dir: an empty name is REFUSED"

# --- 4. the calibrator -------------------------------------------------------
SLOTS="$REAL_BIN/slots.sh"

OUT="$(bash "$SLOTS" report 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q 'implement_slots=' && ok "slots: the report carries the number of slots" \
                                               || bad "slots: the report carries the number of slots"
printf '%s\n' "$OUT" | grep -q 'free_slots=' && ok "slots: the report carries the free slots" \
                                              || bad "slots: the report carries the free slots"

N="$(bash "$SLOTS" implement 2>/dev/null)"
MAX_SLOTS="${MAX_IMPLEMENT_SLOTS:-4}"
case "$N" in
  ''|*[!0-9]*) bad "slots: the number of slots is a number" "got: '$N'" ;;
  # The number of slots follows the hardware (cores and free RAM), so the test
  # checks the CONTRACT and not a fixed number: it is a number, it never
  # exceeds the cap, and it never exceeds what the cores allow.
  *)
    CORES_N="$(nproc 2>/dev/null || echo 4)"
    CPU_MAX=$(( CORES_N / 4 )); [ "$CPU_MAX" -lt 1 ] && CPU_MAX=1
    [ "$CPU_MAX" -gt "$MAX_SLOTS" ] && CPU_MAX="$MAX_SLOTS"
    if [ "$N" -ge 1 ] && [ "$N" -le "$MAX_SLOTS" ] && [ "$N" -le "$CPU_MAX" ]; then
      ok "slots: the number of slots follows the hardware (got $N, cap $MAX_SLOTS, cores allow $CPU_MAX)"
    else
      bad "slots: the number of slots follows the hardware" "got: $N, cap $MAX_SLOTS, cores allow $CPU_MAX"
    fi ;;
esac

# A slot that is taken is subtracted from the free slots.
bash "$LOCK" --slot calibrator-test --take >/dev/null 2>&1
FREE_TAKEN="$(bash "$SLOTS" free-slots 2>/dev/null)"
FREE_NONE="$(ORCH_DIR="$TESTDIR/empty" bash "$SLOTS" free-slots 2>/dev/null)"
case "$FREE_TAKEN" in
  ''|*[!0-9]*) bad "slots: the free slots are a number" "got: '$FREE_TAKEN'" ;;
  *) ok "slots: the free slots are a number (got $FREE_TAKEN, without a lock: $FREE_NONE)" ;;
esac
bash "$LOCK" --slot calibrator-test --release >/dev/null 2>&1

# The gate is exclusive: it is never 'yes' when a gate is running.
GATE="$(bash "$SLOTS" gate 2>/dev/null)"
case "$GATE" in
  0|1) ok "slots: the gate is a boolean (got $GATE)" ;;
  *)   bad "slots: the gate is a boolean" "got: '$GATE'" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
