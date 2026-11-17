#!/usr/bin/env bash
# ------------------------------------------------------------------
# preflight.sh - what this machine needs before the loop can run.
#
# WHY THIS EXISTS (2026-11-17): the orchestrator is split in two
# directories. This repo is the ORCH half and it is in git. The LOOP
# half - agent-issue.sh (the publisher), claim-race.sh, claim-brake.sh,
# claim-salvage.sh, gate-quick.sh (the gate that compiles),
# pr-defaults-line.sh (the body validator), gc-disk.sh, supervisor.sh
# and config.env - lives in $LOOP_DIR and is NOT in git.
#
# That is why RULES.md:3 ("Source of truth: the repo") was not true,
# and why the repo's own audit found two arbitrators for the claim
# (B6) and a gate that could compile the wrong tree (B8).
#
# The dependency was never written down: README.md's "install it on
# another PC" section never mentions cloning the LOOP, so the
# documented install produces a repo whose gate cannot compile
# anything - bin/gate.sh:53 exits 2 with "the gate script is not
# there".
#
# This script says what is missing and where it should be, instead of
# failing later with a confusing message.
#
# USAGE:
#   bash bin/preflight.sh          -> checks, says what is missing
#   bash bin/preflight.sh --strict -> also fails on the soft items
#
# Exit code: 0 everything needed is there, 1 something is missing.
# ------------------------------------------------------------------
set -uo pipefail

ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
HERMES_SCRIPTS="${HERMES_SCRIPTS:-/home/user/.hermes/scripts}"

STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

missing=0
warned=0

say_missing() {
  printf 'FALTA- %s\n' "$1"
  printf '       %s\n' "$2"
  missing=$((missing + 1))
}

say_warn() {
  printf 'AVISO- %s\n' "$1"
  printf '       %s\n' "$2"
  warned=$((warned + 1))
}

# The loop's scripts. Each one is named by the script in this repo that
# needs it, so the message says what breaks without it.
for entry in \
  "agent-issue.sh|el publisher: sin el no se abre ningun PR|bin/run-issue-scope.sh, bin/launch-wave.sh, bin/launch-slot-service.sh, bin/launch-resume.sh" \
  "claim-race.sh|el arbitro del claim|bin/claim-verify.sh lo delega en el (ver RULES.md)" \
  "claim-brake.sh|el freno: convierte el veredicto del claim en exit codes|el publisher lo llama antes de publicar y en el push" \
  "claim-salvage.sh|el rescate del trabajo de un claim perdido|el publisher lo llama cuando el claim se perdio" \
  "gate-quick.sh|el gate que compila y escribe el verdict|bin/gate.sh:53 sale con rc=2 sin el" \
  "pr-defaults-line.sh|el validador del body del PR|bin/publish-pr.sh:254 y bin/verify-pr.sh:117 lo necesitan" \
  ; do
  file="${entry%%|*}"
  rest="${entry#*|}"
  what="${rest%%|*}"
  who="${rest#*|}"
  if [ -f "$LOOP_DIR/bin/$file" ]; then
    continue
  fi
  say_missing "$LOOP_DIR/bin/$file" "$what - lo necesitan: $who"
done

# The hermes scripts: the cron runs a COPY of ping-ready.sh from there,
# and the copy has to be byte-identical to the canonical one.
if [ ! -d "$HERMES_SCRIPTS" ]; then
  say_missing "$HERMES_SCRIPTS" "los scripts que corren los crons viven ahi (ver README.md, tabla de crons)"
elif [ ! -f "$HERMES_SCRIPTS/ping-ready.sh" ]; then
  say_missing "$HERMES_SCRIPTS/ping-ready.sh" "el cron solidcraft-ping-ready corre esa copia; tiene que ser identica a bin/ping-ready.sh"
elif ! diff -q "$HERMES_SCRIPTS/ping-ready.sh" "$(dirname "$0")/ping-ready.sh" >/dev/null 2>&1; then
  say_missing "$HERMES_SCRIPTS/ping-ready.sh" "la copia del cron NO es identica a bin/ping-ready.sh: el cron corre codigo viejo"
fi

# The checkout of SolidCraft: the gate runs there.
if [ ! -d "$SOLIDCRAFT_REPO" ]; then
  say_missing "$SOLIDCRAFT_REPO" "el checkout de SolidCraft: el gate compila ahi"
elif [ ! -d "$SOLIDCRAFT_REPO/.git" ]; then
  say_missing "$SOLIDCRAFT_REPO/.git" "el checkout de SolidCraft no es un checkout de git"
fi

# The worktrees: one per slot.
if [ ! -d "$WORKTREES_DIR" ]; then
  say_warn "$WORKTREES_DIR" "no hay worktrees: un slot sin worktree hace que el gate falle (por diseño)"
fi

# The orchestrator's own runtime state: it is regenerated on every PC,
# so its absence is normal - but the scripts that read it fail loudly.
if [ ! -d "$ORCH_DIR" ]; then
  say_warn "$ORCH_DIR" "no existe el estado del orquestador: se regenera en cada PC (ver README.md, seccion 5)"
fi

if [ "$missing" -eq 0 ]; then
  echo "preflight: todo lo necesario esta"
  [ "$warned" -gt 0 ] && exit 0
  exit 0
fi

echo "preflight: falta $missing cosa(s)" >&2
echo "  La mitad LOOP del orquestador no esta en este repo: vive en \$LOOP_DIR y no tiene git." >&2
echo "  Sin ella, el orquestador no publica, no gatea y no arbitra." >&2
exit 1
