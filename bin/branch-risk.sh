#!/usr/bin/env bash
# ------------------------------------------------------------------
# branch-risk.sh - the branches whose work exists on NO GitHub.
#
# WHY THIS EXISTS (2026-11-17): docs/work-at-risk.md said that two
# branches of the SolidCraft fork were only on the maintainer's
# laptop, and it was WRONG about one of them:
#
#   * fix/issue-5505-sketch-constraint-dof = 77665cb5b
#
# The commit 77665cb5b IS on the fork, under another name:
# `wip/issue-5505-sketch-constraint-dof`. The doc called it lost.
# It was not lost: the branch NAME was gone, the work was not.
#
# That is the bug this script fixes. The doc had the gate written in
# prose:
#
#     git rev-list --count fork/main..<rama>
#
# but that command only answers "is the tip reachable from fork/main".
# A branch that was merged under another name, or that is reachable
# from a DIFFERENT branch of the fork, is not reachable from fork/main
# and the prose called it at risk. It is not: the commit is on
# GitHub.
#
# The question that matters is: does the COMMIT exist on any ref of
# the fork? If not, it exists nowhere and it dies with the disk.
#
# USAGE:
#   bash bin/branch-risk.sh            -> the list, and rc=1 if there is risk
#   bash bin/branch-risk.sh --no-fetch -> do not fetch the fork first
#
# Exit code: 0 nothing at risk, 1 there is work only on this disk,
# 2 the script could not answer (not a checkout, no fork remote).
# ------------------------------------------------------------------
set -uo pipefail

# The checkout of SolidCraft: the one with the branches.
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
# The remote of the fork. The push goes there and ONLY there
# (README rule 19).
FORK_REMOTE="${FORK_REMOTE:-fork}"

fetch=1
[ "${1:-}" = "--no-fetch" ] && fetch=0

if [ ! -d "$SOLIDCRAFT_REPO/.git" ]; then
  echo "branch-risk: $SOLIDCRAFT_REPO no es un checkout de git" >&2
  echo "  (SOLIDCRAFT_REPO=${SOLIDCRAFT_REPO})" >&2
  exit 2
fi

cd "$SOLIDCRAFT_REPO" || { echo "branch-risk: no se puede entrar a $SOLIDCRAFT_REPO" >&2; exit 2; }

if ! git remote get-url "$FORK_REMOTE" >/dev/null 2>&1; then
  echo "branch-risk: el remoto '$FORK_REMOTE' no existe en $SOLIDCRAFT_REPO" >&2
  echo "  (FORK_REMOTE=${FORK_REMOTE})" >&2
  exit 2
fi

if [ "$fetch" -eq 1 ]; then
  # Without the fetch the answer is about the refs of the LAST fetch:
  # a branch pusheado hace un dia seeria "at risk" sin serlo.
  if ! git fetch --quiet "$FORK_REMOTE" 2>/dev/null; then
    echo "branch-risk: no se pudo actualizar '$FORK_REMOTE': el informe es del ultimo fetch" >&2
  fi
fi

# The base: what the fork's main has. A branch that is an ancestor of
# it was merged and its work is upstream.
base="$FORK_REMOTE/main"
if ! git rev-parse --verify --quiet "$base" >/dev/null; then
  echo "branch-risk: no existe $base: no se puede comparar" >&2
  exit 2
fi

at_risk=0
renamed=0
merged=0

echo "branch-risk: el checkout es $SOLIDCRAFT_REPO"
echo "branch-risk: el fork es '$FORK_REMOTE' ($(git remote get-url "$FORK_REMOTE"))"
echo

# Only the local branches: the risk is the work that only exists here.
while read -r tip branch; do
  [ -n "$tip" ] || continue
  # 1. merged in the fork's main: the work is upstream, nothing to save.
  if git merge-base --is-ancestor "$tip" "$base" 2>/dev/null; then
    merged=$((merged + 1))
    continue
  fi
  # 2. reachable from ANOTHER ref of the fork: the commit is on
  #    GitHub, under another name. The work is safe; the name is not.
  others="$(git for-each-ref --format='%(refname:short)' --contains "$tip" \
              "refs/remotes/$FORK_REMOTE/" 2>/dev/null)"
  if [ -n "$others" ]; then
    renamed=$((renamed + 1))
    echo "SALVADA- $branch ($tip) esta en GitHub, bajo otro nombre:"
    printf '%s\n' "$others" | sed 's/^/         /'
    echo "         el TRABAJO esta a salvo; lo que se perdio es el NOMBRE de la rama"
    echo
    continue
  fi
  # 3. not on any ref of the fork: the commit exists ONLY here.
  at_risk=$((at_risk + 1))
  n="$(git rev-list --count "$base".."$tip" 2>/dev/null || echo '?')"
  echo "EN RIESGO- $branch ($tip) - $n commit(s) que el fork no tiene"
  git log --oneline --no-decorate "$base".."$tip" 2>/dev/null | sed 's/^/           /' | head -5
  echo "           para salvarlo:  git push $FORK_REMOTE $branch"
  echo
done <<EOF
$(git for-each-ref --format='%(objectname) %(refname:short)' refs/heads/ 2>/dev/null)
EOF

echo "branch-risk: $at_risk en riesgo, $renamed salvadas con otro nombre, $merged mergeadas en $base"
if [ "$at_risk" -gt 0 ]; then
  echo "branch-risk: HAY TRABAJO QUE SOLO EXISTE EN ESTE DISCO" >&2
  echo "  (pushalo al fork antes de que la maquina se apague)" >&2
  exit 1
fi
exit 0
