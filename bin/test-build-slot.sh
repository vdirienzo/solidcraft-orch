#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-build-slot.sh - the tests of the build slots of the orchestrator.
#
# WHY THE TESTS EXIST: the build slot is the gate that lets ONE compilation at
# a time. A token left behind by a gate that died (killed, or a shell that
# went away mid-compile) used to block the box for BUILD_STALE_MIN minutes
# (3 h by default): the box answered "no free build slot" and NO gate could
# run again. The tests ask the SCRIPT (they never read its source): a rule
# that is only written is not a rule.
#
# WHAT IS TESTED:
#   1. build-slot.sh: the token records the owner that took it.
#   2. a token whose owner is DEAD is reaped at the next take.
#   3. a token whose owner is ALIVE survives, however old it is.
#   4. the release frees the slot it names.
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

TESTDIR="$(mktemp -d "${TMPDIR:-/tmp}/build-slot-test.XXXXXX")"
trap 'rm -rf "$TESTDIR"' EXIT

BS="$ORCH_DIR/bin/build-slot.sh"
[ -x "$BS" ] || BS="$ORCH_DIR/build-slot.sh"

# A scratch directory of tokens: the real build slots of the box are never
# touched by a test.
export BUILD_SLOT_DIR="$TESTDIR/slots"
export BUILD_SLOTS=1
mkdir -p "$BUILD_SLOT_DIR"

# 1. THE TOKEN RECORDS ITS OWNER ----------------------------------------------------
# The token is taken from a child process, so the owner recorded is the pid
# of that child: it has to be a pid, not empty.
OWNER_PID=$$
TOKEN="$(bash "$BS" --take 2>/dev/null)"
if [ -n "$TOKEN" ] && [ -d "$TOKEN" ]; then
  REC="$(cat "$TOKEN/pid" 2>/dev/null | tr -dc '0-9')"
  if [ -n "$REC" ]; then
    ok "build-slot: el token guarda el pid que lo tomo (pid=$REC)"
  else
    bad "build-slot: el token guarda el pid que lo tomo" "el pid no esta en el token"
  fi
  # 2. THE OWNER DEAD -> THE TOKEN GOES AT THE NEXT TAKE ---------------------------
  # A token whose owner does not exist any more is a corpse: the next take
  # reaps it and the box can compile again.
  DEAD_PID="$TESTDIR/dead.pid"
  bash -c 'echo $$ > "'"$DEAD_PID"'"' 2>/dev/null
  DEAD="$(cat "$DEAD_PID" 2>/dev/null | tr -dc '0-9')"
  rm -f "$TOKEN"; mkdir -p "$TOKEN"; printf '%s\n' "$DEAD" > "$TOKEN/pid"
  TOKEN2="$(bash "$BS" --take 2>/dev/null)"
  if [ -n "$TOKEN2" ] && [ -d "$TOKEN2" ]; then
    ok "build-slot: el token de un dueno muerto se reap en el siguiente take"
  else
    bad "build-slot: el token de un dueno muerto se reap en el siguiente take" \
        "no quedo ningun token libre"
  fi
  # 3. THE OWNER ALIVE -> THE TOKEN SURVIVES, HOWEVER OLD ------------------------
  rm -rf "$TOKEN2"
  mkdir -p "$TOKEN"; printf '%s\n' "$$" > "$TOKEN/pid"
  # Make it look old: the age rule would reap it, the owner rule must not.
  touch -d '4 hours ago' "$TOKEN" 2>/dev/null || touch -t 202601010000 "$TOKEN" 2>/dev/null || true
  bash "$BS" --take >/dev/null 2>&1
  if [ -d "$TOKEN" ]; then
    ok "build-slot: el token de un dueno vivo sobrevive, por viejo que sea"
  else
    bad "build-slot: el token de un dueno vivo sobrevive, por viejo que sea" \
        "el token de un gate vivo se reap"
  fi
  # 4. THE RELEASE FREES IT --------------------------------------------------------
  bash "$BS" --release "$TOKEN" >/dev/null 2>&1
  if [ ! -d "$TOKEN" ]; then
    ok "build-slot: el release devuelve el token que nombra"
  else
    bad "build-slot: el release devuelve el token que nombra" "el token sigue ahi"
  fi
else
  bad "build-slot: el token guarda el pid que lo tomo" "no se pudo tomar un token"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
