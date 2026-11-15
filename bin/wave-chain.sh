#!/usr/bin/env bash
# --------------------------------------------------------------------------
# wave-chain.sh - the SEQUENCER of this wave (14-11-2026, wave-20261114-1850).
#
# WHY: the previous wave ran two gates AND two agents at the same time on a
# 16-core box. The load hit 27 and EVERYTHING starved:
#   - the agent of issue 16784 sat with its probe compile BLOCKED on the
#     build-directory lock until its 45-minute timeout killed it;
#   - the gate of PR #16685 died with rustc exiting 254 under sccache
#     ("the sccache server looks like it shut down unexpectedly"), i.e. the
#     server was killed for memory while four big rustc ran at once. The
#     verdict was ROJO-SCOPE with an EMPTY FAILED_TESTS: a FALSE red.
#
# So this wave runs the heavy work ONE AT A TIME, in this order:
#   1. the gate of PR #16718 (it was already running: it finishes on its own);
#   2. the gate of PR #16685 AGAIN, without sccache, alone on the machine;
#   3. the two RESUME agents (16738 and 16784), which wait for their "go"
#      file and then run concurrently (each with its own target dir).
#
# The agents wait for a FILE, not for the load: a load-based wait races with
# the gate (the gate starts, the load is still low for a few seconds, and the
# agent starts in the middle of the gate's compile). The file is atomic and
# unambiguous.
# --------------------------------------------------------------------------
set -uo pipefail

ORCH=/home/user/.local/share/solidcraft-orch
GO_DIR="$ORCH/go"
mkdir -p "$GO_DIR" 2>/dev/null || true

log() { printf '%s wave-chain: %s\n' "$(date -u +%FT%TZ)" "$*"; }

wait_inactive() {
  local unit="$1" waited=0
  while [ "$waited" -lt 14400 ]; do
    [ "$(systemctl --user is-active "$unit" 2>/dev/null || echo inactive)" != "active" ] && return 0
    sleep 20
    waited=$((waited + 20))
  done
  return 1
}

# 1. the gate of PR #16718 finishes on its own
log "espero el gate de PR #16718 (scgate16318)"
wait_inactive scgate16318.service
log "el gate de PR #16718 termino"

# 2. the gate of PR #16685 again, WITHOUT sccache and alone on the machine
log "relanzo el gate de PR #16685 (sin sccache: el servidor murio y el rojo era falso)"
RUSTC_WRAPPER="" SCCACHE_DISABLE=1 GATE_QUICK_TIMEOUT_MIN="${GATE_QUICK_TIMEOUT_MIN:-240}" \
  bash "$ORCH/bin/gate.sh" 16186 fe64ea2179334ae8d1eae23951f679d2109c81aa origin/main 16685 \
  > "$ORCH/logs/gate-16186-chain.log" 2>&1
rc=$?
log "el gate de PR #16685 termino con rc=$rc (ver $ORCH/logs/gate-16186-chain.log)"

# 3. the two RESUME agents get their go file
log "libero los dos agentes de RESUME (16738 y 16784)"
: > "$GO_DIR/16738"
: > "$GO_DIR/16784"
log "wave-chain termina"
