#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Test bank of gate-queue.sh, the drain of the queue of the gates.
#
#   bash bin/test-gate-queue.sh
#
# It touches no network and compiles NOTHING: the gate command is a stub that
# answers at once, and the repository is a fake one made here. The loop that
# is running is NOT touched: everything happens in an isolated LOOP_DIR.
#
# The cases:
#   1. a request in the queue is served: the gate is launched and the request
#      is gone afterwards
#   2. the `default` slot is served from its request too (it used to be
#      refused, and its request waited in the queue forever)
#   3. a request that can never be served (its worktree is gone) is removed:
#      it would be picked again on every tick and it would block the requests
#      behind it
#   4. with no request the drain does nothing
#   5. with the complete gate disabled the request is removed and NO gate is
#      launched (the mode `off` is the default of the real config.env)
#
# The exit code is 1 when a case fails.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE="${QUEUE:-$SCRIPT_DIR/gate-queue.sh}"
GATE="${GATE:-$SCRIPT_DIR/start-gate.sh}"

if [ ! -f "$QUEUE" ]; then
  echo "FALLO - gate-queue.sh is not found: $QUEUE"
  exit 1
fi
if [ ! -f "$GATE" ]; then
  echo "FALLO - start-gate.sh is not found: $GATE"
  exit 1
fi

TMP_TEST="$(mktemp -d "${TMPDIR:-/tmp}/test-gate-queue.XXXXXX" 2>/dev/null)" || {
  echo "FALLO - a temporary directory cannot be created"
  exit 1
}
cleanup() { rm -rf "$TMP_TEST"; }
trap cleanup EXIT

REPO_TEST="$TMP_TEST/repo"
LOOP_TEST="$TMP_TEST/loop"
mkdir -p "$REPO_TEST" "$LOOP_TEST/bin" "$LOOP_TEST/logs" "$LOOP_TEST/gates"

cp "$QUEUE" "$GATE" "$LOOP_TEST/bin/"

# The fake repository: the gate checks out the sha of the request there.
git -C "$REPO_TEST" init -q
git -C "$REPO_TEST" -c user.email=t@t -c user.name=t \
  commit -q --allow-empty -m "scratch"
SHA_ONE="$(git -C "$REPO_TEST" rev-parse HEAD)"
git -C "$REPO_TEST" -c user.email=t@t -c user.name=t \
  commit -q --allow-empty -m "scratch 2"
SHA_TWO="$(git -C "$REPO_TEST" rev-parse HEAD)"

# The complete gate is OFF by default in the real config.env: the CI of the
# upstream runs the full suite when a maintainer reviews the PR. This test
# exercises the QUEUE, and the queue needs the gate to be LAUNCHABLE: with the
# mode `off` start-gate.sh answers 11 ("disabled on purpose") and the queue
# removes the request without launching anything. Case 5 covers that mode.
cat > "$LOOP_TEST/config.env" <<EOF
REPO=$REPO_TEST
GATE_WORKTREE=$REPO_TEST
GATE_TARGET_DIR=$TMP_TEST/target
CHROME=/bin/true
CHROME_LD=
GATE_COMPLETE_MODE=auto
EOF

# The gate refuses to launch while a CI is running on the MACHINE: that check
# is global on purpose (two full suites on one host do not go faster, they
# take twice as long). But it makes this test depend on what the machine is
# doing: a `cargo xtask ci` running anywhere makes the gate answer 6 ("another
# gate is alive") and the case fails for a reason that has nothing to do with
# the queue. The stub of pgrep below makes that check see an empty machine.
mkdir -p "$TMP_TEST/stub"
cat > "$TMP_TEST/stub/pgrep" <<'STUB'
#!/usr/bin/env bash
# The stub of pgrep for this test: no process of this machine is a CI.
exit 1
STUB
chmod +x "$TMP_TEST/stub/pgrep"

# The request of the queue: the same shape that start-gate.sh writes.
write_request() {
  local slot="$1" sha="$2" worktree="$3"
  mkdir -p "$LOOP_TEST/gates/$slot"
  {
    echo "slot=$slot"
    echo "sha=$sha"
    echo "issue=999999"
    echo "slug=queue-test"
    echo "worktree=$worktree"
    echo "requested_at=$(date +%s)"
  } > "$LOOP_TEST/gates/$slot/request"
}

FAILED=0
check() { # check <descripcion> <condicion 0/1>
  if [ "$2" -eq 0 ]; then
    echo "  OK   $1"
  else
    echo "  FALLA $1"
    FAILED=1
  fi
}

drain() {
  PATH="$TMP_TEST/stub:$PATH" SOLIDCRAFT_GATE_CMD="true" LOOP_DIR="$LOOP_TEST" \
    bash "$LOOP_TEST/bin/gate-queue.sh" >/dev/null 2>&1
}

echo "=== 1. un request en la cola se sirve ==="
write_request default "$SHA_ONE" "$REPO_TEST"
drain
rc=$?
[ "$rc" -eq 0 ]; check "el drenado sale con 0" $?
[ ! -e "$LOOP_TEST/gates/default/request" ]
check "el request desaparece tras servirse" $?
[ -s "$LOOP_TEST/gates/default/pid" ]
check "el gate se lanza (hay pid)" $?
sleep 3
grep -qsE '^EXIT=[0-9]+[[:space:]]*$' "$LOOP_TEST/logs/"gate-999999-queue-test-*.log
check "el gate termina y escribe EXIT=" $?

echo "=== 2. el slot default tambien se sirve ==="
# A DIFFERENT sha: the same one would be refused with the code 8 (already
# gated) and its request removed anyway, so the case would pass without the
# default slot ever being served.
rm -f "$LOOP_TEST/gates/default/pid" "$LOOP_TEST/gates/default/started" \
  "$LOOP_TEST/gates/default/sha"
write_request default "$SHA_TWO" "$REPO_TEST"
drain
rc=$?
[ "$rc" -eq 0 ]; check "el drenado sale con 0" $?
[ ! -e "$LOOP_TEST/gates/default/request" ]
check "el request del slot default desaparece" $?
sleep 3
grep -qsE '^EXIT=[0-9]+[[:space:]]*$' "$LOOP_TEST/logs/"gate-999999-queue-test-*.log
check "el gate del slot default se lanza de verdad" $?

echo "=== 3. un request que nunca se puede servir se quita ==="
rm -f "$LOOP_TEST/gates/default/pid" "$LOOP_TEST/gates/default/started" \
  "$LOOP_TEST/gates/default/sha"
write_request default "$SHA_TWO" "$TMP_TEST/no-existe"
drain
[ ! -e "$LOOP_TEST/gates/default/request" ]
check "el request imposible se quita (no bloquea la cola)" $?

echo "=== 4. sin requests el drenado no hace nada ==="
drain
rc=$?
[ "$rc" -eq 0 ]; check "el drenado vacio sale con 0" $?

echo "=== 5. con el gate completo desactivado el request se quita sin lanzar nada ==="
# The complete gate is off by default (config.env): start-gate.sh answers 11
# ("disabled on purpose", NOT a failure) and the request can never be served.
# The queue must remove it: leaving it there would make the timer retry it
# every two minutes, forever.
cat > "$LOOP_TEST/config.env" <<EOF
REPO=$REPO_TEST
GATE_WORKTREE=$REPO_TEST
GATE_TARGET_DIR=$TMP_TEST/target
CHROME=/bin/true
CHROME_LD=
GATE_COMPLETE_MODE=off
EOF
write_request offmode "$SHA_TWO" "$REPO_TEST"
drain
rc=$?
[ "$rc" -eq 0 ]; check "el drenado sale con 0" $?
[ ! -e "$LOOP_TEST/gates/offmode/request" ]
check "el request se quita (el gate no se puede lanzar)" $?
[ ! -e "$LOOP_TEST/gates/offmode/pid" ]
check "no se lanza ningun gate" $?
grep -qs "the complete gate is disabled" "$LOOP_TEST/logs/"*.err
check "el log dice que el gate completo esta desactivado" $?

if [ "$FAILED" -eq 0 ]; then
  echo "TODO OK"
  exit 0
fi
echo "HAY CASOS QUE FALLAN"
exit 1
