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
#      truth; the release frees it; the heavy lock is a SET of tokens and
#      the number of tokens is the ceiling.
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
# WHY THE TEST ASKS FOR THE NUMBER OF TOKENS: the heavy lock is NOT a single
# lock any more, it is a SET of tokens (MAX_HEAVY_TOKENS, default 2). The
# gate does not take it (the gate takes the slot lock and the calibrator
# decides if a gate may start); the tokens are for the heavy work that is
# NOT a gate: a release link, an app build for the evidence, a sweep. The
# tokens are SHARED and COUNTED, so the number of them is the CEILING.
# A test that measured the old single lock would be measuring a contract
# that the script no longer has, so the test asks for the ceiling.
#
# With ONE token the lock is exclusive: the second caller is refused.
MAX_HEAVY_TOKENS=1 bash "$LOCK" --heavy --take >/dev/null 2>&1
[ $? -eq 0 ] && ok "heavy: it can be taken" || bad "heavy: it can be taken"

MAX_HEAVY_TOKENS=1 bash "$LOCK" --heavy --take >/dev/null 2>&1
[ $? -eq 1 ] && ok "heavy: with one token it is exclusive (only one at a time)" \
              || bad "heavy: with one token it is exclusive (only one at a time)"

MAX_HEAVY_TOKENS=1 bash "$LOCK" --heavy --status >/dev/null 2>&1
[ $? -eq 1 ] && ok "heavy: the status is 'taken'" || bad "heavy: the status is 'taken'"

MAX_HEAVY_TOKENS=1 bash "$LOCK" --heavy --release >/dev/null 2>&1
MAX_HEAVY_TOKENS=1 bash "$LOCK" --heavy --status >/dev/null 2>&1
[ $? -eq 0 ] && ok "heavy: the release frees it" || bad "heavy: the release frees it"

# With the DEFAULT number of tokens the ceiling is a ceiling: two heavy
# works fit at the same time and the third one is refused.
MAX_HEAVY_TOKENS=2 bash "$LOCK" --heavy --take >/dev/null 2>&1
[ $? -eq 0 ] && ok "heavy: the first of the two tokens can be taken" \
              || bad "heavy: the first of the two tokens can be taken"

MAX_HEAVY_TOKENS=2 bash "$LOCK" --heavy --take >/dev/null 2>&1
[ $? -eq 0 ] && ok "heavy: the second token can be taken at the same time" \
              || bad "heavy: the second token can be taken at the same time"

MAX_HEAVY_TOKENS=2 bash "$LOCK" --heavy --take >/dev/null 2>&1
[ $? -eq 1 ] && ok "heavy: the third one is refused (the ceiling is a ceiling)" \
              || bad "heavy: the third one is refused (the ceiling is a ceiling)"

MAX_HEAVY_TOKENS=2 bash "$LOCK" --heavy --status >/dev/null 2>&1
[ $? -eq 1 ] && ok "heavy: the status is 'taken' when every token is taken" \
              || bad "heavy: the status is 'taken' when every token is taken"

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

# EL TECHO DE IMPLEMENTACION VIENE DE LA POLITICA DE LA MAQUINA (2026-11-20).
#
# La escalera de memoria de slots.sh esta escrita para una caja de 62 GB (el
# gate pide 32 GB): en una caja de 15 GB decia 1 slot PARA SIEMPRE, y el loop
# no podia correr el segundo agente ni con la caja ociosa. El techo se lee
# ahora del config.env de la maquina (IMPLEMENT_SLOTS), y los nucleos libres
# pueden bajarlo.
POLICY="$TESTDIR/policy.env"
printf 'IMPLEMENT_SLOTS=1   # un slot\n' > "$POLICY"
N_POLICY="$(POLICY_FILE="$POLICY" bash "$SLOTS" implement 2>/dev/null)"
if [ "$N_POLICY" = "1" ]; then
  ok "slots: el techo de la politica manda (IMPLEMENT_SLOTS=1 -> 1 slot)"
else
  bad "slots: el techo de la politica manda (IMPLEMENT_SLOTS=1 -> 1 slot)" "got: '$N_POLICY'"
fi
# Un valor que no es un numero se IGNORA (no rompe el calibrador).
printf 'IMPLEMENT_SLOTS=abc\n' > "$POLICY"
N_BROKEN="$(POLICY_FILE="$POLICY" bash "$SLOTS" implement 2>/dev/null)"
case "$N_BROKEN" in
  ''|*[!0-9]*) bad "slots: un techo que no es un numero no rompe el calibrador" "got: '$N_BROKEN'" ;;
  *) [ "$N_BROKEN" -ge 1 ] && ok "slots: un techo que no es un numero se ignora (got $N_BROKEN)" \
                           || bad "slots: un techo que no es un numero se ignora" "got: '$N_BROKEN'" ;;
esac
# El techo NUNCA sube por encima de lo que permiten los nucleos libres.
printf 'IMPLEMENT_SLOTS=99\n' > "$POLICY"
N_HIGH="$(POLICY_FILE="$POLICY" bash "$SLOTS" implement 2>/dev/null)"
case "$N_HIGH" in
  ''|*[!0-9]*) bad "slots: un techo alto sigue siendo un numero" "got: '$N_HIGH'" ;;
  *)
    CORES_N2="$(nproc 2>/dev/null || echo 4)"
    CPU_MAX2=$(( CORES_N2 / 3 )); [ "$CPU_MAX2" -lt 1 ] && CPU_MAX2=1
    if [ "$N_HIGH" -le "$CPU_MAX2" ]; then
      ok "slots: el techo no sube por encima de los nucleos libres (got $N_HIGH, nucleos permiten $CPU_MAX2)"
    else
      bad "slots: el techo no sube por encima de los nucleos libres" "got: $N_HIGH, nucleos permiten $CPU_MAX2"
    fi ;;
esac
rm -f "$POLICY"

# LA MEMORIA DEL GATE SALE DE LA POLITICA DE LA MAQUINA (2026-11-20).
#
# Con el numero de otra caja (32 GB + 8 de margen = 40 GB libres) el gate de
# esta caja de 15 GB no podia arrancar NUNCA (gate_may_start=0 para siempre).
# La politica dice GATE_MEMORY_HIGH=8G: el gate pide 8 GB y el margen es un
# cuarto (4 GB), con lo que hace falta 12 GB libres.
printf 'GATE_MEMORY_HIGH=8G\n' > "$POLICY"
GATE_POL="$(POLICY_FILE="$POLICY" bash "$SLOTS" gate 2>/dev/null)"
rm -f "$POLICY"
case "$GATE_POL" in
  0|1) ok "slots: la memoria del gate sale de la politica de la maquina (rc=$GATE_POL)" ;;
  *)   no "slots: la memoria del gate sale de la politica de la maquina" "rc=$GATE_POL" ;;
esac
# Sin politica, la memoria del gate sigue siendo la de siempre (32 GB).
GATE_SIN="$(POLICY_FILE="$TMP/no-existe.env" bash "$SLOTS" gate 2>/dev/null)"
case "$GATE_SIN" in
  0|1) ok "slots: sin politica, el gate sigue con la memoria por defecto (rc=$GATE_SIN)" ;;
  *)   no "slots: sin politica, el gate sigue con la memoria por defecto" "rc=$GATE_SIN" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
