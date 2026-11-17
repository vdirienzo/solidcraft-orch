#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Checks that the tip commit of a rebased branch carries the very same patch as
# the tip that was published, and only then force-pushes it to the fork.
#
#   push-rebased.sh <worktree> <branch>
#
# WHY: rebasing onto `main` moves the code around the change, so the patch of
# the rebased commit and the patch of the published one differ in the `index`
# line and in the line numbers of the hunk headers, and nothing else. The
# check below ignores exactly those two, so anything else that differs stops
# the push: a change that was never reviewed must not reach the fork.
#
# It also refuses to push a branch whose worktree was behind the published
# tip: the patch of the worktree's commit is then not the patch that was
# reviewed (measured on #6917, whose local worktree still had an older
# version of the helper).
# ---------------------------------------------------------------------------
set -u

WT="${1:-}"
BR="${2:-}"

if [ -z "$WT" ] || [ -z "$BR" ]; then
  echo "usage: $0 <worktree> <branch>" >&2
  exit 1
fi

cd "$WT" || exit 1
git fetch fork --quiet || exit 3
git fetch origin main --quiet || exit 3

OLD=$(git rev-parse "fork/$BR")
NEW=$(git rev-parse HEAD)

echo "########## $BR ##########"
echo "  publicado: $OLD"
echo "  rebasado:  $NEW"

if [ "$OLD" = "$NEW" ]; then
  echo "  ya estaba: no se pushea"
  exit 0
fi

# The tip commit is the one that carries the change: its patch must be the
# very same, byte for byte, apart from the blob hashes in the index lines and
# the line numbers of the hunk headers (upstream may have moved the code).
if diff <(git show "$OLD" --format="" | sed -E 's/^index .*$/index/; s/^@@ -[0-9,]+ \+[0-9,]+ @@/@@ @@/') \
        <(git show "$NEW" --format="" | sed -E 's/^index .*$/index/; s/^@@ -[0-9,]+ \+[0-9,]+ @@/@@ @@/') \
     | grep -vE '^(---|\+\+\+)' | grep -q .; then
  echo "  !!! EL PARCHE CAMBIO: NO SE PUSHEA"
  exit 2
fi
echo "  parche identico -> push"

git push --force-with-lease fork "$BR" 2>&1 | tail -3
