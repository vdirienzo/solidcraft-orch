#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-agents.sh: the agents of the loop are VALID and opencode RESOLVES them.
#
# Why it exists (gap G2, 26-10-2026): the file existing is not the agent
# working. The V2 schema of opencode asks every permission rule for the three
# fields (`action`, `resource`, `effect`). An agent with a rule without
# `resource` is not registered: opencode answers "Agent not found:
# sc-orchestrator", the turn dies before doing anything, and the loop loses
# the turns without saying why. The check of the loop only looked for the
# FILE, so it said OK while the loop was dead.
#
# Two checks:
#   1. the shape of the rules (cheap, no opencode process)
#   2. opencode RESOLVES the agent (the real thing). The probe asks for a
#      model that does not exist: the agent is resolved BEFORE the model is
#      looked up, so a broken agent says "Agent not found" and a good one
#      says "Model unavailable". No model is called, so it costs nothing.
#
# Usage:
#   check-agents.sh                      # both checks
#   CHECK_AGENTS_RESOLVE=0 ...           # only the shape
#   CHECK_AGENTS_RESOLVE=only:sc-orchestrator ...
#                                         # the shape of every agent and the
#                                         # probe of ONE of them
#
# The last mode is the one the supervisor uses before every turn: the probe
# of every agent is eight processes of opencode, too much for every turn and
# enough for a doctor. The turn only needs the agent it is going to use.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
AGENT_DIR="${AGENT_DIR:-$HOME/.config/opencode/agents}"
OPENCODE_BIN="${OPENCODE_BIN:-opencode}"
RESOLVE="${CHECK_AGENTS_RESOLVE:-1}"
# The helper lives next to this script: the installed copy in $LOOP_DIR/bin and
# the source of truth in the repo are the same file.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AGENTS=(
  sc-orchestrator sc-triage sc-claim sc-implement sc-evidence sc-review
  sc-gate sc-publish
)

rc=0

# The agents to look at: every one of them, or one of them.
#
# The mode `only:<agent>` looks at ONE agent and at nothing else: the
# supervisor asks about the agent of its turn before every turn, and an
# agent that is broken but is NOT the one of this turn must not stop it.
# The other agents are the business of the doctor (the full mode).
check_agents=()
case "$RESOLVE" in
  1|0) check_agents=("${AGENTS[@]}") ;;
  only:*)
    wanted="${RESOLVE#only:}"
    for a in "${AGENTS[@]}"; do
      [ "$a" = "$wanted" ] && check_agents=("$a")
    done
    if [ "${#check_agents[@]}" -eq 0 ]; then
      echo "AVISO: el agente '$wanted' no es uno de los del bucle: no se comprueba"
    fi
    ;;
  *)
    echo "AVISO: CHECK_AGENTS_RESOLVE='$RESOLVE' no es valido: se comprueban todos"
    check_agents=("${AGENTS[@]}")
    ;;
esac

files=()
for a in "${check_agents[@]}"; do
  f="$AGENT_DIR/$a.md"
  if [ ! -f "$f" ]; then
    echo "FALTA $f"
    rc=1
    continue
  fi
  files+=("$f")
done

# --- 1. the shape of the rules --------------------------------------------
if [ "${#files[@]}" -gt 0 ]; then
  if ! out="$(python3 "$HERE/fix-agent-permissions.py" --check "${files[@]}" 2>&1)"; then
    printf '%s\n' "$out"
    rc=1
  fi
fi

# --- 2. opencode resolves the agent ---------------------------------------
if [ "$RESOLVE" != "0" ] && [ "${#check_agents[@]}" -gt 0 ]; then
  if ! command -v "$OPENCODE_BIN" >/dev/null 2>&1; then
    echo "AVISO: $OPENCODE_BIN no esta en el PATH: no se puede comprobar que opencode resuelva los agentes"
  else
    for a in "${check_agents[@]}"; do
      # The session of the probe is in the namespace of the loop (`ses_loop-`):
      # the janitor of the supervisor and the sweeper of the orphans know
      # that namespace and delete those sessions. A probe with a session of
      # its own would leave an "Untitled session" in the list of the user
      # for every turn.
      out="$(timeout 120 "$OPENCODE_BIN" run --standalone \
        --session "ses_loop-preflight" --agent "$a" \
        --model "bogus/nonexistent" "ping" 2>&1 | tail -2 | tr '\n' ' ')"
      case "$out" in
        *"Agent not found"*)
          echo "OPENCODE NO RESUELVE $a: ${out:0:120}"
          rc=1
          ;;
        *"Model unavailable"*)
          echo "OK $a"
          ;;
        *)
          echo "AVISO $a: la prueba dio una respuesta inesperada: ${out:0:120}"
          ;;
      esac
    done
  fi
fi

exit "$rc"
