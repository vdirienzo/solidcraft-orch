#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-wave-cron.sh - the wave, as a cron of this machine.
#
# WHY THIS EXISTS: the wave has to run with the session closed. A cron is the
# only thing on this box that keeps running when nobody is talking to it.
#
# WHAT THE CRON RUNS: a COPY of bin/wave.sh, in ~/.hermes/scripts/ (that is
# where hermes looks for the script of a job, and it refuses a path that
# leaves that folder). The copy has to be byte-identical to the repo's: the
# preflight warns when it is not, because a cron that runs old code is a cron
# that does the wrong thing quietly. The OTHER scripts of the wave are NOT
# copied: wave.sh finds them in the orchestrator's bin (ORCH_BIN), so the cron
# always runs the current code of the repo.
#
# THE JOB: --no-agent, because the wave itself does not think: it closes the
# slots that finished and dispatches the agents (each agent is its own
# hermes -z, with its own budget). --deliver local, because the output of a
# turn of the wave is a fact about the machine, not a message for a human.
#
# USAGE:
#   bash bin/install-wave-cron.sh            # install the copy and the cron
#   bash bin/install-wave-cron.sh --dry-run  # say what it would do
#   bash bin/install-wave-cron.sh --remove   # take the cron out
#
# EXIT CODES:
#   0  the cron is installed (or was already installed and is up to date)
#   2  the copy could not be installed
#   3  hermes refused to register the job
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$HERE/.." && pwd)"
HERMES_SCRIPTS="${HERMES_SCRIPTS:-$HOME/.hermes/scripts}"
JOB_NAME="solidcraft-wave"
SCHEDULE="${SCHEDULE:-*/10 * * * *}"
SCRIPT_NAME="wave.sh"
DRY=""
REMOVE=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY="--dry-run" ;;
    --remove) REMOVE="--remove" ;;
    *) echo "install-wave-cron: no entiendo $arg" >&2; exit 2 ;;
  esac
done

# El id del job, si ya existe (por nombre). El cron se edita, no se duplica.
# El listado de hermes es un bloque por job: la linea del id y, debajo, las
# filas ("Name:", "Schedule:", ...). El id de un job cuyo nombre es el
# nuestro es el de la linea que esta justo encima de su fila "Name:".
job_id() {
  hermes cron list 2>/dev/null | awk -v name="$JOB_NAME" '
    /^  [^ ]+ +\[/ { id = $1 }
    /Name:/ { if (index($0, name)) { print id; exit } }'
}

if [ -n "$REMOVE" ]; then
  ID="$(job_id)"
  if [ -z "$ID" ]; then
    echo "install-wave-cron: el cron $JOB_NAME no estaba instalado"
  else
    hermes cron remove "$ID" && echo "install-wave-cron: el cron $JOB_NAME ya no esta"
  fi
  rm -f "$HERMES_SCRIPTS/$SCRIPT_NAME"
  echo "install-wave-cron: la copia $HERMES_SCRIPTS/$SCRIPT_NAME se fue"
  exit 0
fi

# 1. LA COPIA DEL SCRIPT, byte-identica a la del repo.
if [ -n "$DRY" ]; then
  echo "install-wave-cron: (seco) copiaría $HERE/$SCRIPT_NAME a $HERMES_SCRIPTS/$SCRIPT_NAME"
else
  mkdir -p "$HERMES_SCRIPTS" || { echo "install-wave-cron: no se pudo crear $HERMES_SCRIPTS" >&2; exit 2; }
  if ! cp "$HERE/$SCRIPT_NAME" "$HERMES_SCRIPTS/$SCRIPT_NAME"; then
    echo "install-wave-cron: no se pudo copiar el script" >&2
    exit 2
  fi
  chmod +x "$HERMES_SCRIPTS/$SCRIPT_NAME"
  if ! diff -q "$HERE/$SCRIPT_NAME" "$HERMES_SCRIPTS/$SCRIPT_NAME" >/dev/null 2>&1; then
    echo "install-wave-cron: la copia NO es identica al script del repo" >&2
    exit 2
  fi
  echo "install-wave-cron: la copia esta en $HERMES_SCRIPTS/$SCRIPT_NAME (identica al repo)"
fi

# 2. EL JOB.
ID="$(job_id)"
if [ -n "$ID" ]; then
  if [ -n "$DRY" ]; then
    echo "install-wave-cron: (seco) editaría el job $ID ($JOB_NAME)"
    exit 0
  fi
  if hermes cron edit "$ID" --schedule "$SCHEDULE" --script "$SCRIPT_NAME" --no-agent \
      --deliver local --workdir "$REPO_DIR" >/dev/null 2>&1; then
    echo "install-wave-cron: el job $ID ($JOB_NAME) queda cada $SCHEDULE"
    exit 0
  fi
  echo "install-wave-cron: no se pudo editar el job $ID" >&2
  exit 3
fi

if [ -n "$DRY" ]; then
  echo "install-wave-cron: (seco) crearía el job $JOB_NAME cada $SCHEDULE"
  exit 0
fi

if hermes cron create "$SCHEDULE" --name "$JOB_NAME" --script "$SCRIPT_NAME" \
    --no-agent --deliver local --workdir "$REPO_DIR" >/dev/null 2>&1; then
  echo "install-wave-cron: el job $JOB_NAME corre cada $SCHEDULE (script: $SCRIPT_NAME)"
  exit 0
fi

echo "install-wave-cron: hermes no registro el job (mirar 'hermes cron create' a mano)" >&2
exit 3
