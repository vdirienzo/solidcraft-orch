#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# agent-env.sh - the agent runtime of this machine, as shell variables.
#
# WHY THIS EXISTS (2026-11-21): the loop used to run its agents with hermes
# (`hermes --in <worktree> -z "<brief>"`) and its crons were jobs of hermes.
# hermes is NOT installed on this machine: `~/.hermes/` does not exist, so
# there were no crons at all (the wave did not run, the pipeline ran only
# while a session was alive) and `bin/dispatch-slot.sh` could not start a
# single agent. The agents of the loop are now OPENCODE sessions
# (`opencode run`), and the crons of the loop are a USER CRONTAB
# (bin/install-crontab.sh) instead of the jobs of hermes.
#
# WHY THE MODEL IS NOT IN THE CODE: the binary, the model and the name of the
# agent are the POLICY of this machine, not code. They come from
# $LOOP_DIR/config.env (the file that holds the policy of this machine) and
# fall back to the values that work here. A repo that pins a model breaks on
# the machine whose provider is not the same one.
#
# USAGE:
#   eval "$(bash bin/agent-env.sh)"    # sets AGENT_BIN, AGENT_MODEL, AGENT_NAME
#   bash bin/agent-env.sh             # prints them
#
# EXIT CODES:
#   0  the three variables are on stdout
#   2  the binary is not there (the loop cannot dispatch an agent)
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
CONFIG="${AGENT_CONFIG:-$LOOP_DIR/config.env}"

# The policy file is a shell-ish file with comments after the value:
#   MODEL=minimax/MiniMax-M3.1-Flash   # a comment
read_policy() {
  [ -f "$CONFIG" ] || return 1
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$CONFIG" 2>/dev/null | tail -1 \
    | cut -d= -f2- | cut -d'#' -f1 \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

AGENT_BIN="${AGENT_BIN:-$(read_policy AGENT_BIN 2>/dev/null || true)}"
[ -n "$AGENT_BIN" ] || AGENT_BIN="opencode"
AGENT_MODEL="${AGENT_MODEL:-$(read_policy MODEL 2>/dev/null || true)}"
[ -n "$AGENT_MODEL" ] || AGENT_MODEL="minimax/MiniMax-M3.1-Flash"
AGENT_NAME="${AGENT_NAME:-$(read_policy AGENT_NAME 2>/dev/null || true)}"
[ -n "$AGENT_NAME" ] || AGENT_NAME="build"

# EL TECHO DE TIEMPO DEL AGENTE (2026-11-21): dispatch-slot.sh lanzaba el
# opencode sin techo, y un agente trabado quemaba tokens y tenia el slot (y su
# lock) tomado hasta que alguien lo viera. full-stop incluye compilar, probar y
# capturar evidencia, asi que el techo es holgado; la politica de la maquina lo
# puede bajar con AGENT_TIMEOUT_MIN en config.env.
AGENT_TIMEOUT_MIN="${AGENT_TIMEOUT_MIN:-$(read_policy AGENT_TIMEOUT_MIN 2>/dev/null || true)}"
[[ "$AGENT_TIMEOUT_MIN" =~ ^[0-9]+$ ]] || AGENT_TIMEOUT_MIN=180

printf 'AGENT_BIN=%s\n' "$AGENT_BIN"
printf 'AGENT_TIMEOUT_MIN=%s\n' "$AGENT_TIMEOUT_MIN"
printf 'AGENT_MODEL=%s\n' "$AGENT_MODEL"
printf 'AGENT_NAME=%s\n' "$AGENT_NAME"

# The binary has to be there: a loop that cannot start an agent is a loop that
# looks alive and does nothing.
command -v "$AGENT_BIN" >/dev/null 2>&1 || {
  echo "agent-env: el binario del agente no esta: $AGENT_BIN" >&2
  exit 2
}
exit 0
