#!/usr/bin/env bash
# ------------------------------------------------------------------
# rules-verdict.sh - the verdict of the upstream rules check, in one block.
#
# WHY THIS EXISTS (2026-11-28): upstream rewrote its AGENTS.md and moved its
# skills to .agents/skills/, and this orchestrator did not notice for three
# days: bin/rules-sync.sh could not run on this machine (its default pointed
# at a path that does not exist here). A check that cannot run is worse than
# no check. This script is what the recurring automation runs: it only READS
# (a fetch, some hashes and some `git cat-file` probes), it never changes
# anything, and it prints what a human (or a subagent) has to do next.
#
# WHAT IT CHECKS, in order:
#   1. the snapshot: does upstream still match rules-snapshot/SHA256SUMS?
#      0 current / 1 upstream moved / 2 could not be checked.
#   2. the citations: every path of upstream that OUR documents name (the
#      skills, the scripts, the kernel files) has to EXIST at the snapshot
#      commit. This is the mechanical half of "our rules are the upstream's
#      rules": a path that upstream moved is a rule we are quoting wrongly.
#   3. the briefs: do the briefs our agents read still cite paths that are
#      there? (bin/test-briefs.sh)
#   4. the review: were our documents reviewed after the last snapshot
#      refresh, or did somebody refresh the manifest without reading them?
#      (rules-snapshot/REVIEWED holds the hashes of the documents at the
#      moment of the refresh.)
#
# IT CHANGES NOTHING: no file of the repo is written, no pull request is
# touched, no branch is pushed.
#
# USAGE:
#   bash bin/rules-verdict.sh            # fetch + check + verdict
#   bash bin/rules-verdict.sh --no-fetch # without the fetch (offline)
#
# EXIT: 0 always (the verdict is in the output; a job that "fails" every time
# is noise). The text always says what the verdict is.
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"

# The machine's own paths know where the checkout of upstream is.
if [ -z "${SOLIDCRAFT_REPO:-}" ] && [ -f "$HERE/paths.sh" ]; then
  # shellcheck disable=SC1090
  . "$HERE/paths.sh"
fi
REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
BRIEFS="${ORCH_BRIEFS_DIR:-$HOME/.local/share/solidcraft-orch/briefs}"

SNAPSHOT="$ORCH/rules-snapshot/SHA256SUMS"
REVIEWED="$ORCH/rules-snapshot/REVIEWED"
FETCH=1
[ "${1:-}" = "--no-fetch" ] && FETCH=0

cd "$ORCH" || { echo "rules-verdict: no se puede entrar al repo del orquestador ($ORCH)"; exit 0; }

# The verdict is ALSO written down: a job that runs every six hours has to
# leave a trace where a person can find it without waiting for the delivery
# of the job (and the state of the machine survives the session).
STATE_DIR="${ORCH_STATE_DIR:-$HOME/.local/share/solidcraft-orch/state}"
VERDICT_FILE="$STATE_DIR/rules-verdict.txt"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# Everything below writes to stdout; a tee keeps a copy in the state file
# without changing what the job prints.
exec > >(tee "$VERDICT_FILE.tmp" 2>/dev/null) 3>&1

args=(--check)
[ "$FETCH" = "0" ] && args+=(--no-fetch)
out="$(bash "$HERE/rules-snapshot.sh" "${args[@]}" 2>&1)"
rc=$?

# The commit the snapshot was taken from: the truth our documents are
# measured against.
snap_sha="$(awk '$1 == "#" && $2 == "upstream" {print $3; exit}' "$SNAPSHOT" 2>/dev/null || true)"

case "$rc" in
  0)
    echo "rules-verdict: OK — el snapshot coincide con origin/main; las reglas de upstream no se movieron."
    ;;
  1)
    echo "rules-verdict: CAMBIÓ — upstream movió sus reglas. Los ficheros que se movieron:"
    printf '%s\n' "$out" | grep -E '^(CAMBIO|NUEVO|SE-FUE)' || true
    echo "  Qué hacer: 'bash bin/rules-snapshot.sh --diff' (el detalle), revisar RULES.md y"
    echo "  prompts/ contra el cambio, y solo entonces 'bash bin/rules-snapshot.sh --update'."
    echo "  Nadie fusiona, nadie publica: esto es un aviso."
    # The stat of what moved: the map a subagent needs to start without
    # reading 14 files.
    diffout="$(bash "$HERE/rules-snapshot.sh" --diff "${args[@]:1}" 2>&1)"
    printf '%s\n' "$diffout" | grep -E '^\s*[0-9]+ files? changed|^diff --git' | head -30 || true
    ;;
  *)
    echo "rules-verdict: NO SE PUDO COMPROBAR (exit $rc) — el check no corrió; no lo tomes por 'al día'."
    printf '%s\n' "$out" | tail -5
    ;;
esac

# --- 2. our citations against upstream -------------------------------------
# The documents that carry the rules we give to the agents. The reports are
# left out on purpose: they narrate the past and name paths that are gone
# BECAUSE they narrate a rule that moved.
DOCS=(
  "$ORCH/RULES.md"
  "$ORCH/README.md"
  "$ORCH/prompts/agent-brief.md"
  "$ORCH/docs/known-traps.md"
  "$ORCH/docs/verifying-a-delegated-pr.md"
)
for f in "$ORCH/prompts"/agent-*.md "$ORCH/loop/prompts"/*.md "$ORCH/briefs"/*.md "$BRIEFS"/*.md; do
  [ -f "$f" ] && DOCS+=("$f")
done

missing=""
if [ -n "$snap_sha" ] && git -C "$REPO" cat-file -e "$snap_sha^{commit}" 2>/dev/null; then
  for doc in "${DOCS[@]}"; do
    [ -f "$doc" ] || continue
    # The paths of upstream that the document names.
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if ! git -C "$REPO" cat-file -e "$snap_sha:$p" 2>/dev/null; then
        missing="$missing$p
"
      fi
    done < <(grep -oE '\.agents/skills/[A-Za-z0-9._-]+(/SKILL\.md)?|skills/[A-Za-z0-9._-]+/SKILL\.md|scripts/[A-Za-z0-9._/-]+\.(js|sh|py)|tests/KNOWN_FAILING_TESTS|\.github/pull_request_template\.md|crates/[A-Za-z0-9._/-]+\.(rs|toml)|solidcore/[A-Za-z0-9._/-]+\.(rs|toml)|xtask/src/[A-Za-z0-9._/-]+\.rs' "$doc" 2>/dev/null | sort -u)
  done
fi

if [ -n "$missing" ]; then
  echo "rules-verdict: OJO — nuestros documentos citan rutas que upstream NO tiene en ${snap_sha:0:9}:"
  printf '%s' "$missing" | sort -u | sed 's/^/    /'
  echo "  Cada una es una cita que nuestros agentes están leyendo mal: revisa el fichero donde"
  echo "  aparece (grep -rn '<ruta>' .) y ajusta la cita o el texto."
else
  echo "rules-verdict: OK — las rutas de upstream que citamos (skills, scripts, kernel) existen."
fi

# --- 3. the briefs -----------------------------------------------------------
if [ -x "$HERE/test-briefs.sh" ] || [ -f "$HERE/test-briefs.sh" ]; then
  b_out="$(bash "$HERE/test-briefs.sh" 2>&1)"
  b_rc=$?
  if [ "$b_rc" -eq 0 ]; then
    echo "rules-verdict: OK — los briefs citan rutas que existen ($(printf '%s' "$b_out" | grep -cE '^ok' || true) comprobaciones)."
  else
    echo "rules-verdict: OJO — los briefs citan rutas que ya no existen (test-briefs.sh, exit $b_rc):"
    printf '%s\n' "$b_out" | grep -E '^(FALLA|fail|not ok|[0-9]+ casos)' | head -10 | sed 's/^/    /'
  fi
fi

# --- 4. the review of our documents -----------------------------------------
# rules-snapshot/REVIEWED holds the hashes of our documents at the moment
# the manifest was refreshed: the claim "these exact bytes were read against
# the upstream diff". If a document changed after that, the claim is stale.
if [ -f "$REVIEWED" ]; then
  stale=""
  while IFS= read -r line; do
    case "$line" in \#*|"") continue ;; esac
    h="${line%% *}"; rel="${line#* }"
    rel="${rel# }"
    f="$ORCH/$rel"
    [ -f "$f" ] || continue
    now="$(sha256sum "$f" | cut -d' ' -f1)"
    [ "$now" = "$h" ] || stale="$stale$rel
"
  done < "$REVIEWED"
  if [ -n "$stale" ]; then
    echo "rules-verdict: OJO — estos documentos cambiaron DESPUÉS de la última revisión del snapshot:"
    printf '%s' "$stale" | sed 's/^/    /'
    echo "  Vuelve a leerlos contra 'bash bin/rules-snapshot.sh --diff' y refresca el snapshot."
  fi
else
  echo "rules-verdict: OJO — no hay registro de revisión (rules-snapshot/REVIEWED):"
  echo "  no se puede decir que nuestros documentos se leyeran contra el cambio de upstream."
fi

# The trace: the verdict with the moment it was taken. The job prints it and
# this file keeps it for whoever reads the state of the machine later.
{
  echo "# rules-verdict $(date -u +%Y-%m-%dT%H:%M:%SZ) (upstream ${snap_sha:-desconocido})"
  cat "$VERDICT_FILE.tmp" 2>/dev/null
} > "$VERDICT_FILE" 2>/dev/null
rm -f "$VERDICT_FILE.tmp" 2>/dev/null

exit 0
