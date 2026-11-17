#!/usr/bin/env bash
# ------------------------------------------------------------------
# rules-snapshot.sh - build or refresh the snapshot of the upstream rules.
#
# The counterpart of rules-sync.sh. The snapshot is a manifest of
# hashes, versioned in this repo, so that rules-sync.sh can tell on
# any machine that upstream moved a rule the orchestrator quotes.
#
# USAGE:
#   bash bin/rules-snapshot.sh --update    -> rewrites rules-snapshot/SHA256SUMS
#   bash bin/rules-snapshot.sh --diff      -> shows what changed, writes nothing
#
# --diff is what to read first: it says which upstream rules moved and
# by how much, so the change to RULES.md can be made on purpose.
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
OUT="$HERE/../rules-snapshot/SHA256SUMS"
MODE="${1:-}"

if [ ! -d "$REPO" ]; then
  echo "rules-snapshot: the SolidCraft checkout is not there: $REPO" >&2
  exit 2
fi
case "$MODE" in
  --update|--diff) ;;
  *)
    echo "usage: bash bin/rules-snapshot.sh [--update|--diff]" >&2
    exit 2
    ;;
esac

FILES=(
  AGENTS.md
  CONTRIBUTING.md
  CLAUDE.md
  scripts/pr-checks/pr-checks.js
)
while IFS= read -r skill; do
  FILES+=("skills/$skill/SKILL.md")
done < <(find "$REPO/skills" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort)

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# The upstream commit the snapshot was taken from. Without it, a checkout
# that is simply OLDER than the snapshot looks like drift. With it, the
# two cases can be told apart.
upstream_sha="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
printf '# upstream %s\n' "$upstream_sha" > "$tmp"
printf '# taken %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$tmp"
for rel in "${FILES[@]}"; do
  src="$REPO/$rel"
  [ -f "$src" ] || continue
  printf '%s  %s\n' "$(sha256sum "$src" | cut -d' ' -f1)" "$rel" >> "$tmp"
done

if [ "$MODE" = "--update" ]; then
  mkdir -p "$(dirname "$OUT")"
  # Atomic: the manifest is read by rules-sync.sh, which may run while
  # this writes. A half-written manifest would report false drift.
  mv "$tmp" "$OUT"
  trap - EXIT
  echo "rules-snapshot: snapshot escrito con $(wc -l < "$OUT") archivos"
  exit 0
fi

# --diff: what moved since the snapshot.
if [ ! -f "$OUT" ]; then
  echo "rules-snapshot: no hay snapshot todavia: $OUT" >&2
  echo "  bash bin/rules-snapshot.sh --update" >&2
  exit 1
fi
changed=0
while IFS= read -r line; do
  want="${line%%  *}"
  rel="${line#*  }"
  src="$REPO/$rel"
  if [ ! -f "$src" ]; then
    printf 'FALTA- %s\n' "$rel"
    changed=$((changed + 1))
    continue
  fi
  have="$(sha256sum "$src" | cut -d' ' -f1)"
  if [ "$want" != "$have" ]; then
    printf 'DRIFT- %s\n' "$rel"
    changed=$((changed + 1))
  fi
done < "$OUT"
echo "rules-snapshot: $changed archivo(s) de upstream cambiaron desde el snapshot"
exit 0
