#!/bin/bash
# El runner de los gates: uno a uno, sin la carrera del diferimiento.
#
# POR QUE EXISTE: gate-quick toma el lock de scope GLOBAL con GATE_SCOPE_LOCK_WAIT=0.
# Si dos gates se lanzan a la vez, CADA UNO cree que el otro tiene el lock, y los
# dos se difieren (GATE_STATUS=skipped, DEFERRED=scope-gate-alive). El resultado es
# que ningun gate corre y los dos PRs quedan sin veredicto.
#
# Este runner los recorre en serie: uno espera a que el anterior termine. Como es
# el unico que lanza gates, nunca se diferira por otro gate.
#
# Uso: gate-runner.sh <slot> <sha> [<worktree>] ...
#   sin argumentos: corre los gates pendientes que ya conoce.
set -u
# The paths come from the environment, with the default of THIS
# machine: the other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
B="$ORCH_DIR/bin"
L="$LOOP_DIR/gates"
LOGD="$ORCH_DIR/logs"
mkdir -p "$LOGD"

# el veredicto de este sha ya sirve? El vocabulario real de GATE_STATUS es
# finished|failed|skipped (NO passed/green/ok): con el vocabulario equivocado el
# served() nunca daba true y el runner relanzaba el 100% de los gates (39% del
# gasto medido: 30 core-h).
served() {
  local slot="$1" sha="$2" v="$L/$1/scope.verdict"
  [ -f "$v" ] || return 1
  grep -q "SHA=$sha" "$v" || return 1
  grep -qE '^GATE_STATUS=finished' "$v"
}

run_one() {
  local slot="$1" sha="$2" wt="$3"
  local v="$L/$slot/scope.verdict"
  if served "$slot" "$sha"; then
    echo "[$(date +%H:%M:%S)] $slot $sha ya tiene veredicto: $(grep -hE '^(GATE_STATUS|VERDICT)' "$v" | tr '\n' ' ')"
    return 0
  fi
  echo "[$(date +%H:%M:%S)] corro el gate de $slot ($sha) en $wt"
  cd "$wt" || { echo "  no existe el worktree $wt"; return 1; }
  bash "$B/gate.sh" "$slot" "$sha" > "/tmp/gate-$slot.log" 2>&1
  local rc=$?
  echo "[$(date +%H:%M:%S)] $slot termino (rc=$rc): $(grep -hE '^(GATE_STATUS|VERDICT|SHA|NEW_FAILURES|DEFERRED)' "$v" 2>/dev/null | tr '\n' ' ' | cut -c1-190)"
  tail -4 "/tmp/gate-$slot.log" | sed 's/^/    /'
}

if [ $# -ge 2 ]; then
  # pares slot sha [worktree]
  run_one "$1" "$2" "${3:-$WORKTREES_DIR/issue-$1}"
  exit $?
fi

# sin argumentos: los gates que el orquestador tiene pendientes, en orden de
# prioridad (el que tiene el PR esperando al mantenedor va primero).
run_one 10159 aee25f106 "$WORKTREES_DIR/issue-10159"
run_one 4712 0d74d8cae "$WORKTREES_DIR/issue-4712"
