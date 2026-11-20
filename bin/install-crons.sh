#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-crons.sh - the crons of the loop, installed from bin/crons.txt.
#
# WHY THIS EXISTS (2026-11-20): the crons of hermes run COPIES of the scripts
# of bin/, in ~/.hermes/scripts/ (hermes refuses a path that leaves that
# folder). Nothing synced them: a change in bin/ reached the crons only when
# somebody remembered to copy the file. On 20-11-2026 the wave had been
# running the OLD wave.sh for hours (the one that does not push the branch of
# a dead slot to the fork) and the only sign of it was an AVISO of
# bin/preflight.sh, printed under a "todo lo necesario esta" that reads like
# an ok.
#
# So: ONE command installs every cron of the registry, with its copy
# byte-identical to the repo. bin/crons.txt is the registry (the README says
# so too); the wave's own installer stays for the wave alone.
#
# WHAT IT DOES, per job of bin/crons.txt:
#   1. copies bin/<script> to ~/.hermes/scripts/<script> (byte-identical, +x);
#   2. creates the job, or edits it if it is already there (the job is
#      looked up BY NAME: the id changes every time it is installed);
#   3. every job is --no-agent (the crons do not think) and --deliver local.
#
# USAGE:
#   bash bin/install-crons.sh              # install (and refresh) every cron
#   bash bin/install-crons.sh --dry-run    # say what it would do
#
# EXIT CODES:
#   0  every job of the registry is installed with a copy that matches
#   2  the registry could not be read
#   3  hermes refused one of the jobs
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$HERE/.." && pwd)"
HERMES_SCRIPTS="${HERMES_SCRIPTS:-$HOME/.hermes/scripts}"
REGISTRY="$REPO_DIR/bin/crons.txt"
DRY=""

[ "${1:-}" = "--dry-run" ] && DRY="--dry-run"

[ -r "$REGISTRY" ] || { echo "install-crons: no se puede leer el registro: $REGISTRY" >&2; exit 2; }
mkdir -p "$HERMES_SCRIPTS" || exit 2

# The id of a job, by its name (the id changes on every install).
job_id() {
  hermes cron list 2>/dev/null | awk -v name="$1" '
    /^  [^ ]+ +\[/ { id = $1 }
    /Name:/ { if (index($0, name)) { print id; exit } }'
}

FAILED=0
COUNT=0
while IFS='|' read -r job schedule script node what; do
  job="$(printf '%s' "$job" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  # The schedule KEEPS its spaces: '*/3 * * * *' is a cron, '*/3****' is not.
  schedule="$(printf '%s' "$schedule" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  script="$(printf '%s' "$script" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$job" ] || continue
  case "$job" in \#*) continue ;; esac
  [ -n "$schedule" ] && [ -n "$script" ] || continue
  COUNT=$((COUNT + 1))

  SRC="$REPO_DIR/$script"
  if [ ! -f "$SRC" ]; then
    echo "install-crons: $job: el script no existe: $SRC" >&2
    FAILED=1
    continue
  fi
  DST="$HERMES_SCRIPTS/$(basename "$script")"

  if [ -n "$DRY" ]; then
    echo "install-crons: (seco) copiaría $SRC a $DST y dejaría el job $job cada '$schedule'"
    continue
  fi

  cp "$SRC" "$DST" || { echo "install-crons: $job: no se pudo copiar $SRC" >&2; FAILED=1; continue; }
  chmod +x "$DST" 2>/dev/null || true
  if ! diff -q "$SRC" "$DST" >/dev/null 2>&1; then
    echo "install-crons: $job: la copia NO es identica a la del repo" >&2
    FAILED=1
    continue
  fi

  ID="$(job_id "$job")"
  if [ -n "$ID" ]; then
    if hermes cron edit "$ID" --schedule "$schedule" --script "$(basename "$script")" \
        --no-agent --deliver local --workdir "$REPO_DIR" >/dev/null 2>&1; then
      echo "install-crons: $job: el job $ID queda cada '$schedule' (script: $(basename "$script"))"
    else
      echo "install-crons: $job: no se pudo editar el job $ID" >&2
      FAILED=1
    fi
  elif hermes cron create "$schedule" --name "$job" --script "$(basename "$script")" \
      --no-agent --deliver local --workdir "$REPO_DIR" >/dev/null 2>&1; then
    echo "install-crons: $job: creado, cada '$schedule' (script: $(basename "$script"))"
  else
    echo "install-crons: $job: hermes no registro el job" >&2
    FAILED=1
  fi
done < "$REGISTRY"

[ "$FAILED" -eq 0 ] && echo "install-crons: los $COUNT crons del registro estan instalados y sus copias son identicas al repo"
exit "$FAILED"
