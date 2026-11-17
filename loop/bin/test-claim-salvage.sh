#!/usr/bin/env bash
# test-claim-salvage.sh - the tests of the rescue of the work of a lost claim.
#
# WHY THIS FILE EXISTS: the publisher (agent-issue.sh) asks the brake of the
# claim at TWO points: before the model starts, and before the publication.
# The second one is the expensive one: the model has already written an
# implementation with its tests, and the claim can be lost in between (the
# upstream applies the label 'in progress' with a delay, and a rival pull
# request can appear while the model works).
#
# The publisher used to exit on that brake WITHOUT collecting anything, so a
# whole run (an implementation with its tests) was lost with the exit. The
# rescue (claim-salvage.sh) existed and worked, but NOTHING called it.
#
# These tests cover the two halves:
#   * the rescue itself collects the work (commits AND the uncommitted diff);
#   * the publisher CALLS it at both points, so the work is never thrown away.
#
# The tests NEVER touch the real repository: they build a throwaway worktree
# in a temporary directory and a fake publisher that sources the real
# function.
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
BIN="$LOOP_DIR/bin"
PASS=0
FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-claim-salvage.XXXXXX")"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
ko()   { FAIL=$((FAIL+1)); printf '  FALLO - %s\n' "$1"; }
check() { if [ "$2" = "0" ]; then ok "$1"; else ko "$1"; fi; }

# --- a worktree with real work ------------------------------------------------

make_worktree() {
  local wt="$1" branch="$2"
  git -C /home/user/solidcraft worktree add -f "$wt" -b "$branch" origin/main >/dev/null 2>&1
  printf '\n// probe del rescate\n' >> "$wt/crates/doc/src/lib.rs"
  git -C "$wt" add -A
  git -C "$wt" commit -qm "probe: trabajo commiteado" >/dev/null 2>&1
  printf '\n// trabajo SIN commitear\n' >> "$wt/crates/doc/src/lib.rs"
}

# --- the rescue collects the work ----------------------------------------------

echo "== el rescate guarda el trabajo =="

WT="$TMP/wt"
make_worktree "$WT" tmp/salvage-test-$$ >/dev/null 2>&1
if [ ! -d "$WT" ]; then
  ko "se puede crear un worktree de prueba"
else
  ok "se puede crear un worktree de prueba"

  OUT="$TMP/out"
  bash "$BIN/claim-salvage.sh" \
    --issue 99999 --verdict LOST --holder "PR #12345" \
    --work "$WT" --branch tmp/salvage-test-$$ --base origin/main \
    --out "$OUT" >/dev/null 2>&1
  check "el rescate termina bien" $?

  DIFF="$(ls "$OUT"/*.diff 2>/dev/null | head -1)"
  NOTE="$(ls "$OUT"/*.md 2>/dev/null | head -1)"
  [ -n "$DIFF" ]; check "el rescate escribe el parche" $?
  [ -n "$NOTE" ]; check "el rescate escribe la nota" $?

  grep -q "trabajo SIN commitear" "$DIFF" 2>/dev/null
  check "el parche conserva el trabajo SIN commitear" $?

  grep -q "trabajo commiteado" "$NOTE" 2>/dev/null
  check "la nota lista los commits del trabajo" $?

  grep -q "crates/doc/src/lib.rs" "$NOTE" 2>/dev/null
  check "la nota lista los archivos que cambiaron" $?

  # the JSON is the machine-readable part: another agent can read it
  JSON="$(ls "$OUT"/*.json 2>/dev/null | head -1)"
  [ -n "$JSON" ]; check "el rescate escribe el resumen en JSON" $?
  grep -q '"verdict"' "$JSON" 2>/dev/null
  check "el JSON dice el veredicto" $?
fi

git -C /home/user/solidcraft worktree remove --force "$WT" >/dev/null 2>&1
git -C /home/user/solidcraft branch -D tmp/salvage-test-$$ >/dev/null 2>&1

# --- the publisher calls it ------------------------------------------------------

echo
echo "== el publisher llama al rescate =="

PUB="$BIN/agent-issue.sh"
[ -f "$PUB" ]; check "el publisher existe" $?

# both points of the brake have to rescue the work BEFORE they exit
# The rescue lives in ONE place: the brake (claim-brake.sh) calls
# claim-salvage.sh when the claim is gone. The publisher does NOT call the
# rescue itself: it hands the brake the worktree and the branch, and the
# brake collects the work.
#
# (A first version of this suite checked that the publisher called the
# rescue directly. That was a DUPLICATE: the brake has always done it, and
# the publisher has always passed --work and --branch for exactly that
# reason. The test now checks the real contract.)

BRAKE="$BIN/claim-brake.sh"
[ -f "$BRAKE" ]; check "el freno existe" $?

grep -q 'claim-salvage.sh' "$BRAKE"
check "el freno es el que invoca al rescate (claim-salvage.sh)" $?

grep -q 'salvage LOST' "$BRAKE"
check "el freno salva el trabajo cuando el reclamo se pierde" $?

grep -q 'salvage RESOLVED' "$BRAKE"
check "el freno salva el trabajo cuando el issue ya no esta abierto" $?

# the publisher has to give the brake the context of the work, or the brake
# cannot collect the patch
grep -q 'CLAIM_CHECK_ARGS+=(--work "\$WORK")' "$PUB"
check "el publisher pasa el worktree al freno (check temprano)" $?
grep -q 'BRAKE_ARGS+=(--work "\$WORK")' "$PUB"
check "el publisher pasa el worktree al freno (check de publicacion)" $?
grep -q 'BRAKE_ARGS+=(--branch "\$BRANCH")' "$PUB"
check "el publisher pasa la rama al freno" $?

# the brake has to be told NOT to save when the caller does not want it
grep -q -- '--no-salvage' "$BRAKE"
check "el freno sabe como no salvar (--no-salvage)" $?

# --- the verdicts that do NOT save ---------------------------------------------

echo
echo "== los veredictos que no son una perdida no salvan nada =="

# The brake saves the work when the claim is LOST, RESOLVED or UNKNOWN, and
# NOT when the claim is OK (there is nothing to save: the publication goes
# ahead). The brake must therefore have a branch that saves and one that
# does not, and the OK path must not call the salvage.
BRAKE="$BIN/claim-brake.sh"
grep -q 'salvage OK' "$BRAKE"
if [ $? -ne 0 ]; then
  ok "un reclamo OK no dispara el rescate"
else
  ko "un reclamo OK no dispara el rescate"
fi

# the brake has to refuse the salvage when the caller asks for the verdict
# alone (--no-salvage): that is the switch a caller uses when it wants to
# know the verdict without touching the work
grep -q 'SALVAGE_IT=0' "$BRAKE"
check "el freno respeta --no-salvage" $?

# --- the rule stays in ONE place ---------------------------------------------------

echo
echo "== la regla del reclamo vive en un solo script =="

for f in claim-guard.sh claim-brake.sh claim-free.sh; do
  grep -q 'claim-race.sh' "$BIN/$f" 2>/dev/null
  check "$f consulta al arbitro unico (claim-race.sh)" $?
done

# --- the syntax --------------------------------------------------------------------

echo
echo "== la sintaxis =="
for f in agent-issue.sh claim-salvage.sh claim-brake.sh claim-race.sh; do
  bash -n "$BIN/$f" 2>/dev/null
  check "$f tiene sintaxis valida" $?
done

echo
echo "== el resumen =="
printf '  %d caso(s) pasan, %d fallan\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
