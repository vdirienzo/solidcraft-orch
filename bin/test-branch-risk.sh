#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-branch-risk.sh - the classification of the branches.
#
# WHY THIS EXISTS: docs/work-at-risk.md called a branch at risk when
# the commit was on the fork under another name. The script has to
# tell the two apart, or the doc keeps lying.
#
# The cases:
#   * a branch merged in the fork's main: nothing to save;
#   * a branch whose commit is on ANOTHER branch of the fork: the
#     work is safe, only the name was lost;
#   * a branch whose commit is on NO ref of the fork: the work only
#     exists on this disk, and the script has to say so and exit != 0.
#
# NOTHING of the machine is touched: the "fork" is a bare repo in a
# temporary directory and no network is used (--no-fetch).
#
# Run:  bash bin/test-branch-risk.sh
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${BRANCH_RISK_SH:-$HERE/branch-risk.sh}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-branch-risk.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FALLA- %s\n' "$1"; fail=$((fail+1)); [ $# -gt 1 ] && printf '       %s\n' "$2"; }

# --- el mundo de mentira ----------------------------------------------------
WORK="$TMP/work"
FORK="$TMP/fork.git"
mkdir -p "$WORK"
git init -q --bare "$FORK"

git -C "$WORK" init -q -b main .
git -C "$WORK" config user.email "test@example.com"
git -C "$WORK" config user.name "test"
git -C "$WORK" remote add fork "$FORK"

# Un arbol vacio: los commits de mentira no tocan archivos.
TREE="$(git -C "$WORK" hash-object -w -t tree /dev/null)"

base="$(printf 'base\n' | git -C "$WORK" commit-tree "$TREE")"
git -C "$WORK" update-ref refs/heads/main "$base"
git -C "$WORK" push -q fork main

commit() {  # commit <mensaje> <rama> -> el sha
  local msg sha
  msg="$1"
  sha="$(printf '%s\n' "$msg" | git -C "$WORK" commit-tree "$TREE" -p HEAD)"
  git -C "$WORK" update-ref refs/heads/"$2" "$sha"
  echo "$sha"
}

# 1. mergeada: el commit esta en fork/main
merged="$(commit 'merged work' merged)"
git -C "$WORK" update-ref refs/heads/main "$merged"
git -C "$WORK" push -q fork main

# 2. renombrada: el commit esta en OTRA rama del fork, no en fork/main
renamed="$(commit 'renamed work' renamed)"
git -C "$WORK" push -q fork renamed:refs/heads/wip/renamed

# 3. en riesgo: el commit no esta en ninguna ref del fork
risk="$(commit 'risky work' risky)"

# Las refs de tracking: lo que un fetch deja. El fetch es de un repo
# LOCAL (no hay red) y el script se corre con --no-fetch, asi que las
# refs tienen que estar puestas antes.
git -C "$WORK" fetch -q fork

run_risk() {
  OUT="$(SOLIDCRAFT_REPO="$WORK" FORK_REMOTE=fork bash "$SRC" --no-fetch 2>&1)"
  RC=$?
}

echo "== la clasificacion de las ramas =="
run_risk

if printf '%s' "$OUT" | grep -q 'EN RIESGO- risky'; then
  ok "la rama cuyo commit no esta en el fork se reporta EN RIESGO"
else
  no "la rama cuyo commit no esta en el fork se reporta EN RIESGO" "$OUT"
fi

if printf '%s' "$OUT" | grep -q 'SALVADA- renamed'; then
  ok "la rama cuyo commit esta en OTRA rama del fork se reporta SALVADA"
else
  no "la rama cuyo commit esta en OTRA rama del fork se reporta SALVADA" "$OUT"
fi

if printf '%s' "$OUT" | grep -q 'wip/renamed'; then
  ok "el informe dice bajo que nombre esta el commit salvado"
else
  no "el informe dice bajo que nombre esta el commit salvado" "$OUT"
fi

if printf '%s' "$OUT" | grep -q 'EN RIESGO- merged\|SALVADA- merged'; then
  no "la rama mergeada en fork/main NO se reporta como en riesgo ni como salvada" "$OUT"
else
  ok "la rama mergeada en fork/main NO se reporta como en riesgo ni como salvada"
fi

if [ "$RC" -ne 0 ]; then
  ok "el script sale con rc distinto de cero cuando hay trabajo en riesgo (rc=$RC)"
else
  no "el script sale con rc distinto de cero cuando hay trabajo en riesgo (rc=0)"
fi

if printf '%s' "$OUT" | grep -q 'git push fork risky'; then
  ok "el informe dice el comando exacto que salva la rama"
else
  no "el informe dice el comando exacto que salva la rama" "$OUT"
fi

# --- sin trabajo en riesgo: rc=0 -------------------------------------------
echo "== sin trabajo en riesgo el script sale 0 =="
git -C "$WORK" update-ref -d refs/heads/risky
git -C "$WORK" push -q fork --delete risky 2>/dev/null || true
run_risk
if [ "$RC" -eq 0 ]; then
  ok "sin ramas en riesgo el script sale 0"
else
  no "sin ramas en riesgo el script sale 0" "rc=$RC $OUT"
fi

# --- un checkout que no es de git: rc=2 ------------------------------------
echo "== un directorio que no es un checkout: rc=2 =="
OUT="$(SOLIDCRAFT_REPO="$TMP" bash "$SRC" --no-fetch 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then
  ok "sin checkout de git el script sale 2 (no dice que no hay riesgo)"
else
  no "sin checkout de git el script sale 2 (no dice que no hay riesgo)" "rc=$RC $OUT"
fi

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
