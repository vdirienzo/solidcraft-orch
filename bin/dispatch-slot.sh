#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# dispatch-slot.sh - start the agent of a prepared slot.
#
# WHAT IT DOES: it runs the agent with the brief of the slot, in the worktree
# of the slot, with the target directory of the slot, and leaves the log where
# the wave (and the next session) can read it. The agent is the same kind of
# agent the wave prompt describes: one issue, one worktree, one PR.
#
# WHY IT IS A SEPARATE SCRIPT: preparing a slot and running it are two acts
# with two owners. The preparation is fast and leaves everything written down
# (the worktree, the branch, the brief, the state). The agent takes minutes or
# hours. If the session that prepared it dies, the next one finds the slot in
# the state and dispatches it without preparing anything again.
#
# EL AGENTE ES UN opencode (2026-11-21): antes era `hermes --in <wt> -z
# "<brief>"`, y hermes no esta instalado en esta maquina: el script fallaba y
# la wave no despachaba NINGUN agente (los slots se acumulaban: 53 GB de
# worktrees y targets, tres slots "corriendo" sin agente). Ahora el agente es
# `opencode run` en el worktree del slot, con el brief como mensaje.
#
# `--standalone` (servidor privado del agente) y no el servicio compartido: el
# 20-11-2026 el gateway compartido se murio y se llevo por delante los turnos
# de los agentes (loop/bin/agent-issue.sh:416 usa lo mismo).
#
# EL AGENTE NO ES TIRA LA BASURA (2026-11-21): el brief ya NO le pide borrar
# el worktree ni el target (eso mataba el gate del propio slot). La limpieza
# la hace el orquestador, en bin/close-slot.sh, cuando el PR ya esta arriba.
#
# USAGE:
#   bash bin/dispatch-slot.sh <issue>
#
# EXIT CODES:
#   0  the agent is running (the log is on stdout)
#   3  the slot is not prepared (no brief)
#   4  the agent could not be started
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}"
# The siblings: the cron runs a COPY of this script from ~/.hermes/scripts/,
# where the siblings are NOT. They live in the orchestrator's bin. When this
# script runs from the repo, they are right here.
if [ -f "$HERE/claim-verify.sh" ]; then ORCH_BIN="$HERE"; else ORCH_BIN="${ORCH_BIN:-$ORCH_DIR/bin}"; fi
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
ISSUE="${1:-}"
[ -n "$ISSUE" ] || { echo "dispatch-slot: falta el issue" >&2; exit 2; }

BRIEF="$ORCH_DIR/prompts/agent-$ISSUE.md"
WT="$WORKTREES_DIR/issue-$ISSUE"
LOG="$ORCH_DIR/logs/$ISSUE-wave.log"
TD="$(bash "$ORCH_BIN/slot-target-dir.sh" --slot "$ISSUE" 2>/dev/null)"

[ -f "$BRIEF" ] || { echo "dispatch-slot: el slot $ISSUE no está preparado" >&2; exit 3; }
[ -d "$WT" ] || { echo "dispatch-slot: no hay worktree: $WT" >&2; exit 3; }
mkdir -p "$ORCH_DIR/logs"

# El agente hereda las reglas de la caja: un target por slot, poca prioridad,
# sin incremental, y el token pesado para las compilaciones grandes.
#
# EL AGENTE: `opencode run` con el brief como mensaje, en el worktree del
# slot (el repo de SolidCraft: ahi esta su AGENTS.md, que es la ley). El
# binario, el modelo y el nombre del agente salen de bin/agent-env.sh (la
# politica de la maquina, no el codigo).
eval "$(bash "$ORCH_BIN/agent-env.sh")" || {
  echo "dispatch-slot: no hay runtime de agente (bin/agent-env.sh)" >&2
  exit 4
}
MSG="$(cat "$BRIEF")"
setsid nohup env \
  CARGO_TARGET_DIR="$TD" \
  CARGO_BUILD_JOBS=4 \
  CARGO_INCREMENTAL=0 \
  SCCACHE_MAX_CACHE_SIZE=60G \
  MAX_HEAVY_TOKENS=1 \
  bash -c 'cd "$1" && exec "$2" run --standalone --auto -m "$3" --agent "$4" "$5"' \
  _ "$WT" "$AGENT_BIN" "$AGENT_MODEL" "$AGENT_NAME" "$MSG" \
  > "$LOG" 2>&1 < /dev/null &

# El estado: el slot deja de estar "preparado" y pasa a "corriendo". Una
# sesion que llega despues ve que hay un agente en vuelo.
python3 "$ORCH_BIN/state-set.py" --merge slots "$ISSUE" "$(python3 - "$ISSUE" <<'PY'
import json, sys
print(json.dumps({
    "issue": int(sys.argv[1]),
    "status": "running",
    "phase": "el agente arranco con el brief del slot",
}))
PY
)" >/dev/null 2>&1

echo "$LOG"
exit 0
