#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Publishes the evidence PNGs of an issue into a branch of the fork, so the PR
# body can link them raw.
#
#   publish-evidence.sh <fix-branch> <png> [png...]
#
# From a fork, `gh pr edit --attach` does not work (the asset goes to the base
# repo, where the fork has no write access) and a gist does not render a PNG
# inline (ghist rejects binaries). What works, and what the repo maintainers
# do, is a branch of the fork with the raw links.
#
# The branch is `evidence/<issue>-<slug>`: a branch no PR tracks. The PNGs
# NEVER touch the branch of the fix.
#
# It prints the raw URLs, one per line: the caller puts them in the PR body.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
REPO="${REPO:-/home/user/solidcraft}"
FORK="${FORK_REMOTE:-fork}"
WT="${EVIDENCE_PUBLISH_WORKTREE:-$LOOP_DIR/evidence-publish}"

FIX_BRANCH="${1:-}"
shift || true
PNGS=("$@")

if [ -z "$FIX_BRANCH" ] || [ "${#PNGS[@]}" -eq 0 ]; then
  echo "usage: publish-evidence.sh <fix-branch> <png> [png...]" >&2
  exit 2
fi

for png in "${PNGS[@]}"; do
  if [ ! -f "$png" ]; then
    echo "missing picture: $png" >&2
    exit 3
  fi
done

# `fix/issue-5302-extrude-sketch-on-side` -> `evidence/5302-extrude-sketch-on-side`
# The prefixes are stripped BEFORE the `evidence/` one. Stripping `issue-`
# after prefixing never matches, and the branch comes out as
# `evidence/evidence/issue-...`: a branch nobody links to, so the raw URLs
# 404 and the pictures of the PR are lost.
SLUG="${FIX_BRANCH#fix/}"
SLUG="${SLUG#issue/}"
SLUG="${SLUG#issue-}"
SLUG="${SLUG#evidence/}"
EB="evidence/$SLUG"

git -C "$REPO" fetch "$FORK" >/dev/null 2>&1 || true
git -C "$REPO" fetch origin main >/dev/null 2>&1 || true

rm -rf "$WT"
if ! git -C "$REPO" worktree add --force --detach "$WT" origin/main >/dev/null 2>&1; then
  echo "could not create the publish worktree at $WT" >&2
  exit 4
fi
cleanup() {
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
}
trap cleanup EXIT

# `--ignore-other-worktrees`: the evidence branch can still be checked out in
# a worktree left behind by an earlier run, and a plain `checkout -B` would
# refuse to take it.
git -C "$WT" checkout --ignore-other-worktrees -B "$EB" >/dev/null 2>&1 || {
  echo "could not create the branch $EB" >&2
  exit 5
}

for png in "${PNGS[@]}"; do
  cp "$png" "$WT/$(basename "$png")" || exit 6
done

git -C "$WT" add -A >/dev/null 2>&1
git -C "$WT" commit -q -m "evidence: pictures for $FIX_BRANCH" >/dev/null 2>&1

NEW_SHA=$(git -C "$WT" rev-parse HEAD 2>/dev/null || echo "")
# `--verify --quiet`: a plain `rev-parse` of a ref that does not exist prints
# the ARGUMENT on stdout and fails, so REMOTE_SHA would be the ref name
# itself instead of the empty sha.
REMOTE_SHA=$(git -C "$REPO" rev-parse --verify --quiet "refs/remotes/$FORK/$EB" 2>/dev/null || echo "")
if [ "$NEW_SHA" != "$REMOTE_SHA" ]; then
  # The error of the push goes to stderr on purpose: the supervisor appends
  # it to its log, and "it failed" without the reason is not diagnosable.
  PUSH_ERR=$(mktemp 2>/dev/null || echo "$WT/push.err")
  if ! git -C "$WT" push --force-with-lease "$FORK" "HEAD:refs/heads/$EB" >/dev/null 2>"$PUSH_ERR"; then
    # A concurrent git operation can hold the ref lock for a moment: one
    # retry before giving up. The push is idempotent (force-with-lease).
    sleep 3
    if ! git -C "$WT" push --force-with-lease "$FORK" "HEAD:refs/heads/$EB" >/dev/null 2>"$PUSH_ERR"; then
      echo "could not push $EB to $FORK" >&2
      cat "$PUSH_ERR" >&2
      rm -f "$PUSH_ERR"
      exit 7
    fi
  fi
  rm -f "$PUSH_ERR"
fi

# The raw URL is `https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<file>`:
# it needs the owner AND the name of the repository. The basename of the
# remote URL is only the repository (`solidcraft`), and a URL without the
# owner in it does not resolve.
REPO_SLUG=$(git -C "$REPO" remote get-url "$FORK" 2>/dev/null | sed -e "s,.*github.com[:/],," -e "s,\.git$,,")
if [ -z "$REPO_SLUG" ]; then
  echo "could not read the URL of the remote $FORK from $REPO" >&2
  exit 8
fi
for png in "${PNGS[@]}"; do
  echo "https://raw.githubusercontent.com/$REPO_SLUG/$EB/$(basename "$png")"
done

