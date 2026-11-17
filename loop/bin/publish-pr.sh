#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# publish-pr.sh - the wrapper of the LOOP over the single publish path.
#
# WHY THIS FILE EXISTS (2026-11-07, drift real):
#   The prompts of the loop open a pull request with `publish-pr.sh`, by an
#   ABSOLUTE path. The script that does the work lives in the ORCHESTRATOR
#   (solidcraft-orch/bin/publish-pr.sh). The loop's own directory used to
#   have NO copy of it: the deploy copies a FIXED list of files, and
#   `publish-pr.sh` was not in that list, so a deploy from the repo could
#   leave the loop without it and the prompts would point at nothing.
#
# WHAT THIS FILE IS: the entry point of the LOOP. It resolves the
#   orchestrator and hands the call over with `exec`, so the output and the
#   exit code are the ones of the real script:
#     * ORCH_DIR, if it is set, names the checkout of the orchestrator;
#     * otherwise the default checkout is used
#       (/home/user/.local/share/solidcraft-orch).
#
# WHEN THE ORCHESTRATOR IS NOT THERE: this script says so ON STDERR and
#   exits with a NON-ZERO code. It NEVER fails silently: a silent success
#   here would be a pull request that nobody opened, and the turn would
#   report that the publication happened.
#
# IT NEVER DELEGATES IN A LOOP (three guards, because a delegation that
#   loops is a hang, and a hang in a turn is a lost turn):
#     1. the resolved target is not this very file (same file, other path);
#     2. ORCH_DIR is not the loop's own directory;
#     3. the delegation happens AT MOST ONCE, marked with an environment
#        variable: if the target turns out to be another wrapper, that one
#        refuses instead of delegating again.
#
# USAGE: the same as the orchestrator's script.
#   bash bin/publish-pr.sh --repo <owner/name> --base <branch> --head <branch>
#                          --title "<summary> (#<N>)" \
#                          --body-file /tmp/pr-<N>-body.md --issue <N>
#   --body <texto> is the alternative to --body-file.
# ---------------------------------------------------------------------------
set -uo pipefail

ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
TARGET="$ORCH_DIR/bin/publish-pr.sh"
SELF="${BASH_SOURCE[0]}"

# The real path of a file, when it can be resolved: the guards compare the
# REAL paths, because the same file reached through a symlink or through
# another checkout is still the same file.
real_path() {
  local path="$1" resolved
  if command -v readlink >/dev/null 2>&1; then
    resolved="$(readlink -f -- "$path" 2>/dev/null)" && [ -n "$resolved" ] && {
      printf '%s\n' "$resolved"
      return 0
    }
  fi
  printf '%s\n' "$path"
}

SELF_REAL="$(real_path "$SELF")"
TARGET_REAL="$(real_path "$TARGET")"

# The ROOT of the loop: this script lives in <loop>/bin, so the loop is its
# grandparent. It is the ROOT and not the directory of the script, because
# ORCH_DIR names a root, and comparing a root with a `bin/` never matches.
LOOP_ROOT="$(cd -- "$(dirname -- "$(dirname -- "$SELF")")" 2>/dev/null && pwd)"
ORCH_REAL="$(cd -- "$ORCH_DIR" 2>/dev/null && pwd)"

# Guard 3: the delegation already happened. The target is another wrapper
# and this script refuses instead of starting a second hop.
if [ -n "${SOLIDCRAFT_PUBLISH_PR_DELEGATED:-}" ]; then
  echo "publish-pr.sh: la delegacion ya ocurrio una vez (ORCH_DIR=$ORCH_DIR)." >&2
  echo "publish-pr.sh: el destino ($TARGET) es OTRO wrapper, y delegar otra vez seria un bucle." >&2
  echo "publish-pr.sh: poné ORCH_DIR con el checkout del orquestador (solidcraft-orch), no con el del loop." >&2
  exit 66
fi

# Guard 1: the target is this very file.
if [ "$TARGET_REAL" = "$SELF_REAL" ]; then
  echo "publish-pr.sh: el destino es este mismo script ($TARGET)." >&2
  echo "publish-pr.sh: delegar a si mismo seria un bucle infinito, y no se delega." >&2
  echo "publish-pr.sh: poné ORCH_DIR con la ruta del checkout del orquestador (solidcraft-orch)." >&2
  exit 66
fi

# Guard 2: ORCH_DIR is the loop's own directory.
if [ -n "${ORCH_REAL:-}" ] && [ -n "${LOOP_ROOT:-}" ] && [ "$ORCH_REAL" = "$LOOP_ROOT" ]; then
  echo "publish-pr.sh: ORCH_DIR ($ORCH_DIR) es el directorio del loop." >&2
  echo "publish-pr.sh: delegar a si mismo seria un bucle infinito, y no se delega." >&2
  echo "publish-pr.sh: poné ORCH_DIR con la ruta del checkout del orquestador (solidcraft-orch)." >&2
  exit 66
fi

if [ ! -f "$TARGET" ]; then
  echo "publish-pr.sh: el script del orquestador no esta ahi: $TARGET" >&2
  echo "publish-pr.sh: el loop no puede abrir pull requests sin el (ORCH_DIR=$ORCH_DIR)." >&2
  echo "publish-pr.sh: instalalo, o poné ORCH_DIR con la ruta del checkout." >&2
  exit 66
fi

if [ ! -x "$TARGET" ]; then
  echo "publish-pr.sh: el script del orquestador no es ejecutable: $TARGET" >&2
  exit 66
fi

export SOLIDCRAFT_PUBLISH_PR_DELEGATED=1
exec "$TARGET" "$@"
