#!/usr/bin/env bash
# ------------------------------------------------------------------
# baseline-refresh.sh - refresh the failures we measured on origin/main.
#
# WHY THIS EXISTS (2026-11-17): the upstream catalogue
# (tests/KNOWN_FAILING_TESTS) is refreshed with every merge, by them, from
# their CI artifacts. OURS is measured by hand and it ages. A baseline that
# is behind can mask a regression that upstream already fixed: the failure
# is discounted as "preexisting" and it is not. bin/gate-baseline.sh warns
# when it goes past the age limit; this script is how you fix the warning.
#
# WHERE THE REPORT COMES FROM: a nextest junit report of a run on
# origin/main, in a clean worktree of it. The upstream way of getting one:
#
#   gh run download <run> -R tangency-labs/solidcraft -n <artifact> -D <dir>
#   cargo nextest run --profile ci --workspace --junit-xml <dir>/report.xml
#
# The list is graded with upstream's own tool, which knows the format and
# knows which failures the upstream catalogue already has:
#
#   cargo xtask known-failing --junit <dir>
#
# USAGE:
#   bash bin/baseline-refresh.sh --junit <file-or-dir> [--repo <path>]
#
# It PRINTS the new list. It does not write the file: the measurement is
# reviewed by a person, because a baseline that hides a regression is
# worse than no baseline.
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
REPO="${SOLIDCRAFT_REPO:-$HOME/solidcraft}"
BASE="${BASE:-$HERE/../baseline/failures-origin-main.txt}"

JUNIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --junit) JUNIT="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "baseline-refresh: opcion desconocida: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$JUNIT" ]; then
  echo "baseline-refresh: hace falta --junit <file-or-dir>" >&2
  exit 2
fi
if [ ! -e "$JUNIT" ]; then
  echo "baseline-refresh: no existe el reporte: $JUNIT" >&2
  exit 2
fi

# The list of tests that FAILED in the report, with the crate prefix the
# nextest id uses. The report names them "<binary id>::<test>"; the
# baseline uses the same form.
listar_fallidos() {
  local dir="$1"
  local out="$2"
  : > "$out"
  local f
  while IFS= read -r f; do
    python3 - "$f" >> "$out" <<'PY'
import sys
import xml.etree.ElementTree as ET

try:
    tree = ET.parse(sys.argv[1])
except Exception:
    sys.exit(0)
for case in tree.iter("testcase"):
    name = case.get("name")
    cls = case.get("classname") or ""
    failed = any(c.tag in ("failure", "error") for c in case)
    if failed and name:
        print(f"{cls}::{name}".replace("::", "::", 1))
PY
  done < <(find "$dir" -name '*.xml' -type f 2>/dev/null | sort)
  sort -u "$out" -o "$out"
}

TMP="$(mktemp)"
trap 'rm -f "$TMP" "$TMP.2"' EXIT

if [ -d "$JUNIT" ]; then
  listar_fallidos "$JUNIT" "$TMP"
else
  listar_fallidos "$(dirname "$JUNIT")" "$TMP"
fi

if [ ! -s "$TMP" ]; then
  echo "baseline-refresh: el reporte no tiene fallos: el baseline se deja como esta" >&2
  echo "  un reporte sin fallos significa que origin/main esta verde: no hay baseline que refrescar" >&2
  exit 1
fi

# The failures upstream's catalogue already has are NOT ours: they are in
# every run and they are not our business. Ours are the ones that upstream
# does not have yet.
OURS="$TMP.2"
: > "$OURS"
if [ -d "$REPO" ] && [ -f "$REPO/tests/KNOWN_FAILING_TESTS" ]; then
  known="$(mktemp)"
  trap 'rm -f "$TMP" "$TMP.2" "$known"' EXIT
  grep -vE '^[[:space:]]*(#|$)' "$REPO/tests/KNOWN_FAILING_TESTS" 2>/dev/null \
    | awk '{print $1}' | sed 's/^solidcraft-//' | sort -u > "$known"
  # The same match the gate uses: the upstream name carries the crate
  # ("solidcraft-engine::...") and nextest reports it without it.
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    short="${t#solidcraft-}"
    if ! grep -qxF "$t" "$known" && ! grep -qxF "$short" "$known"; then
      printf '%s\n' "$t" >> "$OURS"
    fi
  done < "$TMP"
else
  cp "$TMP" "$OURS"
fi

head_sha="unknown"
if [ -d "$REPO" ]; then
  head_sha="$(git -C "$REPO" rev-parse origin/main 2>/dev/null || echo unknown)"
fi

cat <<EOF
# Fallos PREEXISTENTES de origin/main, medidos el $(date -u +%Y-%m-%d).
# upstream ${head_sha:0:9}
# Contexto: medidos en un worktree limpio de origin/main con el reporte de nextest.
# Formato: un test por linea, con el prefijo del crate (nextest lo usa asi).
# El gate los cuenta como NEW_FAILURES: hay que descontarlos antes de
# declarar un PR ROJO, o ningun PR puede pasar mientras upstream este roto.
#
# Para refrescar: bash bin/baseline-refresh.sh --junit <reporte>
EOF
cat "$OURS"

echo >&2
echo "baseline-refresh: $(wc -l < "$OURS") fallo(s) que el catalogo de upstream no tiene" >&2
echo "  Revisa la lista ANTES de escribirla: un baseline que tapa una regresion es" >&2
echo "  peor que no tener baseline. Para escribirla:" >&2
echo "    cp <la lista de arriba> $BASE" >&2
