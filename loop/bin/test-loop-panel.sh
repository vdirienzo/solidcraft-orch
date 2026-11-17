#!/usr/bin/env bash
# test-loop-panel.sh - the panel reads the state of the slots, not the state
# that nothing writes.
#
# The loop writes the state of its turn in the view of its slot
# (state/slot-<n>.json). state.json is the state of the loop before the
# slots: the supervisor never writes it any more. A panel that reads it
# shows a frozen phase and hides the issue that a slot is working on.
set -uo pipefail

PANEL="${PANEL:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/loop.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LOOP="$WORK/loop"
mkdir -p "$LOOP/state"

cat > "$LOOP/config.env" <<'ENV'
MAX_PR_PER_DAY=24
ALLOW_NEW_PRS=1
MAX_TURN_MIN=75
ENV

# The state of the loop before the slots: frozen, and it says nothing about
# the turn that is running.
cat > "$LOOP/state.json" <<'JSON'
{"phase":"failed","issue":0,"pr":0,"branch":"","mode":"normal",
 "counters":{"iterations":490,"failures":74,"consecutive":3},
 "in_flight":null,"gate_verdict":"PENDIENTE","gate_log":"",
 "report":{"pending":false,"last":"2026-10-27"}}
JSON

AT="$(date -u -d 'today 12:00' +%s)"

cat > "$LOOP/state/slot-0.json" <<JSON
{"slot":0,"phase":"gating","issue":7001,"pr":0,
 "branch":"fix/issue-7001-slot","mode":"normal","review":"",
 "counters":{"iterations":491,"failures":74,"consecutive":0},
 "in_flight":{"issue":7001,"started":$AT},
 "gate_verdict":"PENDIENTE","gate_log":"/tmp/gate-0.log",
 "report":{"pending":false,"last":"2026-10-28"},
 "published":{"2026-10-28":[{"pr":5100,"at":$AT}]}}
JSON

cat > "$LOOP/state/slot-1.json" <<JSON
{"slot":1,"phase":"published","issue":7002,"pr":5101,
 "branch":"fix/issue-7002-slot","mode":"normal","review":"aprobado",
 "counters":{"iterations":492,"failures":74,"consecutive":0},
 "in_flight":null,"gate_verdict":"VERDE","gate_log":"/tmp/gate-1.log",
 "report":{"pending":true,"last":"2026-10-27"},
 "published":{"2026-10-28":[{"pr":5101,"at":$AT}]}}
JSON

out="$(LOOP_DIR="$LOOP" bash "$PANEL" status 2>&1)"

fail() {
  echo "FALLO: $1"
  echo "--- la salida del panel ---"
  echo "$out"
  echo "---------------------------"
  exit 1
}

has() { grep -qF "$1" <<<"$out" || fail "$2"; }
hasnt() { grep -qF "$1" <<<"$out" && fail "$2"; return 0; }

# The state of every slot is on the panel.
has "slot 0: fase gating" "el panel no muestra la fase del slot 0"
has "issue #7001" "el panel no muestra el issue del slot 0"
has "slot 1: fase published" "el panel no muestra la fase del slot 1"
has "pr #5101" "el panel no muestra el pull request del slot 1"
has "fix/issue-7002-slot" "el panel no muestra la rama del slot 1"

# The issue that a slot is working on is in flight.
has "en vuelo: issue #7001" "el panel no dice que el slot 0 tiene un issue en vuelo"

# The phase of the frozen state is not the phase of the loop.
hasnt "fase      : failed" "el panel sigue mostrando la fase congelada de state.json"

# The publications of the day are the union of the maps of the slots.
has "publicaciones hoy: 2 de 24" "el panel no cuenta las publicaciones de los slots"

echo "ok   - el panel muestra el estado de cada slot"
echo "ok   - el panel no muestra la fase congelada de state.json"
echo "ok   - el panel cuenta las publicaciones de los slots"
echo "=== everything passed ==="
