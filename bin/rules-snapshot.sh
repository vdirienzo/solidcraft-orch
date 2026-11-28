#!/usr/bin/env bash
# ------------------------------------------------------------------
# rules-snapshot.sh - build, refresh or check the snapshot of the upstream
# rules.
#
# The snapshot is a manifest of hashes, versioned in this repo
# (rules-snapshot/SHA256SUMS), so that bin/rules-sync.sh can tell on any
# machine that upstream moved a rule the orchestrator follows.
#
# QUE SE MIDE (2026-11-21): el origin/main de upstream, NO el checkout. Antes
# se hasheaban los archivos del working tree de $SOLIDCRAFT_REPO, que esta en
# la rama que toque (hoy una rama de trabajo) y atrasado: un checkout viejo
# parecia "deriva" y un upstream que se movio no se veia hasta el proximo
# reset. Ahora cada corrida hace `git fetch origin` y hashea
# `git show origin/main:<path>`. Y upstream movio sus skills de desarrollo a
# .agents/skills/ (#19134): las de skills/ son las del MCP de la app, no
# reglas para agentes, y salieron del snapshot.
#
# LOS ARCHIVOS: AGENTS.md, CONTRIBUTING.md, cada .agents/skills/*/SKILL.md y
# scripts/pr-checks/pr-checks.js (el parser del body de un PR que el
# orquestador imita). La lista sale de origin/main: una skill nueva o una que
# se va tambien es un cambio.
#
# USAGE:
#   bash bin/rules-snapshot.sh --update   -> rewrites rules-snapshot/SHA256SUMS
#   bash bin/rules-snapshot.sh --check    -> what bin/rules-sync.sh runs
#   bash bin/rules-snapshot.sh --diff     -> the check plus `git diff --stat`
#                                            of what moved; writes nothing
#   ... [--no-fetch] [--verbose]
#
# --diff is what to read first: it says which upstream rules moved and by
# how much, so the change to RULES.md is made on purpose. Then --update.
#
# ENVIRONMENT:
#   SOLIDCRAFT_REPO  the clone of upstream (it only needs the remote)
#   RULES_REMOTE     the remote of upstream (default origin)
#   RULES_REF        the ref that is measured (default $RULES_REMOTE/main)
#   RULES_SNAPSHOT   the manifest (default rules-snapshot/SHA256SUMS)
#   RULES_NO_FETCH=1 the same as --no-fetch (offline, tests)
#
# EXIT CODES of --check and --diff:
#   0  the snapshot matches upstream
#   1  upstream moved (the list of the files is on stdout) or there is no
#      snapshot: a wave has to stop until RULES.md is checked against it
#   2  it could not be checked (no repo, no ref, or the fetch failed and
#      nothing visible moved)
# --update: 0 written, 2 it could not be built.
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# The machine's own paths know where the checkout is (bin/paths.sh, 2026-11-24): the default
# below is only the fallback for a machine without that file. Without this, the rules check
# answered "no hay un clon" on the machine that HAS the clone, and upstream could move its
# rules (AGENTS.md, the skills, the PR template) without anybody noticing: the check exits
# non-zero and is easy to miss in a wave.
if [ -z "${SOLIDCRAFT_REPO:-}" ] && [ -f "$HERE/paths.sh" ]; then
  # shellcheck disable=SC1090
  . "$HERE/paths.sh"
fi
REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
REMOTE="${RULES_REMOTE:-origin}"
REF="${RULES_REF:-$REMOTE/main}"
SNAPSHOT="${RULES_SNAPSHOT:-$HERE/../rules-snapshot/SHA256SUMS}"
FETCH=1
[ "${RULES_NO_FETCH:-0}" = "1" ] && FETCH=0
VERBOSE=0
MODE=""

for arg in "$@"; do
  case "$arg" in
    --update|--check|--diff) MODE="$arg" ;;
    --no-fetch) FETCH=0 ;;
    --verbose) VERBOSE=1 ;;
    *)
      echo "usage: bash bin/rules-snapshot.sh --update|--check|--diff [--no-fetch] [--verbose]" >&2
      exit 2
      ;;
  esac
done
if [ -z "$MODE" ]; then
  echo "usage: bash bin/rules-snapshot.sh --update|--check|--diff [--no-fetch] [--verbose]" >&2
  exit 2
fi
# The prefix of the messages: the check is what bin/rules-sync.sh runs.
PFX="rules-snapshot"
[ "$MODE" = "--check" ] && PFX="rules-sync"

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "$PFX: no hay un clon de SolidCraft en $REPO (SOLIDCRAFT_REPO)" >&2
  exit 2
fi

# 1. Traer upstream. Un fetch que falla no es un "esta al dia": se sigue con
# el $REF local (lo que ya se ve que cambio sigue siendo cierto), y si no se
# ve ningun cambio la respuesta es "no se sabe" (exit 2), no un verde.
fetch_failed=0
if [ "$FETCH" -eq 1 ]; then
  if ! timeout 120 git -C "$REPO" fetch --quiet "$REMOTE" 2>/dev/null; then
    fetch_failed=1
    echo "$PFX: AVISO: fallo 'git fetch $REMOTE' en $REPO: se mide el $REF local" >&2
  fi
fi

upstream_sha="$(git -C "$REPO" rev-parse --verify --quiet "$REF^{commit}" 2>/dev/null || true)"
if [ -z "$upstream_sha" ]; then
  echo "$PFX: no existe $REF en $REPO (falta el remote $REMOTE o el fetch)" >&2
  exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rules-snapshot.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# 2. Los hashes de upstream, en el formato de sha256sum ("<hash>  <path>").
# La lista sale del arbol de $REF: lo que upstream agrega o borra cuenta.
CURRENT="$TMP/current"
: > "$CURRENT"
while IFS= read -r rel; do
  case "$rel" in
    AGENTS.md|CONTRIBUTING.md|scripts/pr-checks/pr-checks.js|scripts/claim/claim.js|.github/pull_request_template.md) ;;
    .agents/skills/*/SKILL.md)
      # Solo el SKILL.md de primer nivel de cada skill.
      rest="${rel#.agents/skills/}"
      case "$rest" in */*/*) continue ;; esac
      ;;
    *) continue ;;
  esac
  hash="$(git -C "$REPO" show "$upstream_sha:$rel" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  printf '%s  %s\n' "$hash" "$rel" >> "$CURRENT"
done < <(git -C "$REPO" ls-tree -r --name-only "$upstream_sha" -- \
           AGENTS.md CONTRIBUTING.md scripts/pr-checks/pr-checks.js scripts/claim/claim.js \
           .github/pull_request_template.md .agents/skills 2>/dev/null \
         | LC_ALL=C sort)

if [ ! -s "$CURRENT" ]; then
  echo "$PFX: $REF no tiene ninguno de los archivos de reglas: no se toma un snapshot vacio" >&2
  exit 2
fi

# --- --update ---------------------------------------------------------------
if [ "$MODE" = "--update" ]; then
  mkdir -p "$(dirname "$SNAPSHOT")"
  out="$TMP/SHA256SUMS"
  {
    printf '# upstream %s\n' "$upstream_sha"
    printf '# ref %s\n' "$REF"
    printf '# taken %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat "$CURRENT"
  } > "$out"
  # Atomic: the manifest is read by rules-sync.sh, which may run while this
  # writes. A half-written manifest would report false drift.
  mv "$out" "$SNAPSHOT"
  echo "$PFX: snapshot escrito con $(grep -vc '^#' "$SNAPSHOT") archivos de $REF ($upstream_sha)"

  # 3. El registro de la revision (2026-11-28). El manifiesto dice QUE se midio;
  # este dice que los documentos del orquestador se LEYERON contra ese cambio.
  # Es la afirmacion que bin/rules-verdict.sh puede comprobar: si un documento
  # cambio despues de esta marca, la afirmacion esta vieja y hay que releerlo.
  # Se escribe al final del protocolo (despues de revisar), que es cuando la
  # afirmacion es cierta.
  ORCH_ROOT="$(cd "$HERE/.." && pwd)"
  REVIEWED="$(dirname "$SNAPSHOT")/REVIEWED"
  {
    printf '# documentos revisados contra %s el %s\n' "$upstream_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for rel in RULES.md README.md prompts/agent-brief.md prompts/agent-*.md \
               docs/*.md loop/prompts/*.md briefs/*.md; do
      [ -f "$ORCH_ROOT/$rel" ] || continue
      printf '%s  %s\n' "$(sha256sum "$ORCH_ROOT/$rel" | cut -d' ' -f1)" "$rel"
    done
  } > "$REVIEWED.tmp"
  mv "$REVIEWED.tmp" "$REVIEWED"
  echo "$PFX: revision registrada en $(basename "$(dirname "$REVIEWED")")/REVIEWED"
  exit 0
fi

# --- --check / --diff ---------------------------------------------------------
if [ ! -f "$SNAPSHOT" ]; then
  echo "$PFX: no hay snapshot: $SNAPSHOT" >&2
  echo "  construilo con: bash bin/rules-snapshot.sh --update" >&2
  exit 1
fi

snapshot_sha="$(awk '$1 == "#" && $2 == "upstream" {print $3; exit}' "$SNAPSHOT")"
WANT="$TMP/want"
grep -v '^#' "$SNAPSHOT" | grep -v '^[[:space:]]*$' > "$WANT" || true

# Los cambios: CAMBIO (el hash se movio), NUEVO (upstream lo agrego) y SE-FUE
# (upstream lo borro o lo movio). Una linea por archivo, en stdout: es la
# lista que lee la wave.
CHANGED="$TMP/changed"
awk '
  NR == FNR { want[$2] = $1; next }
  {
    have[$2] = $1
    if (!($2 in want))          printf "NUEVO   %s\n", $2
    else if (want[$2] != $1)    printf "CAMBIO  %s\n", $2
    else if (verbose == "1")    printf "ok      %s\n", $2 > "/dev/stderr"
  }
  END { for (f in want) if (!(f in have)) printf "SE-FUE  %s\n", f }
' verbose="$VERBOSE" "$WANT" "$CURRENT" | LC_ALL=C sort -k2 > "$CHANGED"

n="$(grep -c . "$CHANGED" || true)"
if [ "$n" -eq 0 ]; then
  if [ "$fetch_failed" -eq 1 ]; then
    echo "$PFX: el snapshot coincide con el $REF LOCAL, pero el fetch fallo: no se sabe si upstream se movio" >&2
    exit 2
  fi
  echo "$PFX: las reglas de upstream no cambiaron desde el snapshot ($REF ${upstream_sha:0:9})"
  exit 0
fi

cat "$CHANGED"
{
  echo "$PFX: $n archivo(s) de reglas de upstream cambiaron desde el snapshot"
  echo "  snapshot: ${snapshot_sha:-desconocido}   $REF: $upstream_sha"
  echo "  1. leelos: bash bin/rules-snapshot.sh --diff"
  echo "  2. revisa RULES.md y los prompts contra lo que cambio"
  echo "  3. recien entonces: bash bin/rules-snapshot.sh --update"
} >&2

if [ "$MODE" = "--diff" ]; then
  if [ -n "$snapshot_sha" ] && git -C "$REPO" cat-file -e "$snapshot_sha^{commit}" 2>/dev/null; then
    # shellcheck disable=SC2046
    git -C "$REPO" diff --stat "$snapshot_sha" "$upstream_sha" -- \
      $(awk '{print $2}' "$CHANGED") 2>/dev/null
  else
    echo "$PFX: el commit del snapshot (${snapshot_sha:-ninguno}) no esta en $REPO: no hay diff" >&2
  fi
fi
exit 1
