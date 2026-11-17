#!/usr/bin/env bash
# ------------------------------------------------------------------
# rules-sync.sh - the snapshot of the upstream rules must not age.
#
# WHY THIS EXISTS (2026-11-17): RULES.md:1 says "read 2026-10-30" and
# RULES.md:98-103 lists the "DISCREPANCIAS" with upstream. Nothing
# verified that snapshot, and upstream moves: 81 commits in five hours
# (README.md:257). It already showed. The README claimed the position
# of the `Changes a default:` line matters; the upstream parser
# (scripts/pr-checks/pr-checks.js:50, flag /im) says it does not. An
# agent that follows a stale rule produces pull requests the upstream
# CI rejects.
#
# The snapshot is a manifest of hashes, versioned in this repo, so the
# check is reproducible on any machine: if a hash moved, upstream
# changed a rule the orchestrator is quoting.
#
# USAGE:
#   bash bin/rules-sync.sh              -> checks the snapshot
#   bash bin/rules-sync.sh --verbose    -> also says which files moved
#
# Exit code: 0 the snapshot is current, 1 it is not, 2 the upstream
# checkout is not there.
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
SNAPSHOT="$HERE/../rules-snapshot/SHA256SUMS"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

if [ ! -d "$REPO" ]; then
  echo "rules-sync: the SolidCraft checkout is not there: $REPO" >&2
  exit 2
fi
if [ ! -f "$SNAPSHOT" ]; then
  echo "rules-sync: there is no snapshot: $SNAPSHOT" >&2
  echo "  build it with: bash bin/rules-snapshot.sh --update" >&2
  exit 1
fi

# The files the orchestrator quotes a rule from. AGENTS.md is the router
# to every skill; CONTRIBUTING.md holds the PR rules; pr-checks.js is
# the authority for the body of a pull request.
FILES=(
  AGENTS.md
  CONTRIBUTING.md
  CLAUDE.md
  scripts/pr-checks/pr-checks.js
)
while IFS= read -r skill; do
  FILES+=("skills/$skill/SKILL.md")
done < <(find "$REPO/skills" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort)

drifted=0
missing=0
for rel in "${FILES[@]}"; do
  src="$REPO/$rel"
  if [ ! -f "$src" ]; then
    printf 'FALTA- %s (no esta en el checkout de upstream)\n' "$rel"
    missing=$((missing + 1))
    continue
  fi
  want="$(awk -v f="$rel" '$2 == f {print $1}' "$SNAPSHOT")"
  if [ -z "$want" ]; then
    printf 'SIN-  %s (no estaba en el snapshot: regeneralo)\n' "$rel"
    drifted=$((drifted + 1))
    continue
  fi
  have="$(sha256sum "$src" | cut -d' ' -f1)"
  if [ "$want" != "$have" ]; then
    printf 'DRIFT- %s\n' "$rel"
    drifted=$((drifted + 1))
  elif [ "$VERBOSE" -eq 1 ]; then
    printf 'ok   - %s\n' "$rel"
  fi
done

# A checkout that is simply OLDER than the snapshot is not drift. The
# snapshot records the upstream commit it was taken from; when the
# checkout is at another commit, a mismatch may just be an older
# checkout, and saying "the rules changed" would be a lie.
snapshot_sha="$(awk '$1 == "#" && $2 == "upstream" {print $3}' "$SNAPSHOT")"
checkout_sha="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
same_commit=0
if [ -n "$snapshot_sha" ] && [ "$snapshot_sha" = "$checkout_sha" ]; then
  same_commit=1
fi

if [ "$drifted" -eq 0 ] && [ "$missing" -eq 0 ]; then
  echo "rules-sync: el snapshot de las reglas esta al dia"
  exit 0
fi

if [ "$drifted" -gt 0 ] && [ "$same_commit" -eq 0 ]; then
  # The rules did not move: the checkout is somewhere else. Saying
  # "the rules changed" would be a lie.
  echo "rules-sync: $drifted archivo(s) no coinciden" >&2
  echo "  OJO: el snapshot es del upstream $snapshot_sha y tu checkout esta en $checkout_sha." >&2
  echo "  Un checkout mas viejo NO es un cambio de las reglas. Trae upstream al dia" >&2
  echo "  (git -C \"$REPO\" fetch origin && git -C \"$REPO\" reset --hard origin/main)" >&2
  echo "  y volve a correr esto antes de tocar RULES.md." >&2
  exit 1
fi

if [ "$drifted" -gt 0 ]; then
  echo "rules-sync: $drifted archivo(s) de upstream cambiaron" >&2
  echo "  RULES.md dice que fecha leyo: regeneralo con el SHA de upstream del log" >&2
  echo "  bash bin/rules-snapshot.sh --update   (despues de revisar el diff)" >&2
  exit 1
fi

# Nothing drifted: the files that are missing are simply not in this
# checkout (an older upstream, or a sparse one).
echo "rules-sync: $missing archivo(s) del snapshot no estan en el checkout" >&2
echo "  el snapshot es del upstream $snapshot_sha y tu checkout esta en $checkout_sha" >&2
echo "  si tu checkout esta al dia, el snapshot esta viejo: regeneralo" >&2
echo "  bash bin/rules-snapshot.sh --update" >&2
exit 1
