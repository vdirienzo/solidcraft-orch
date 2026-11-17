#!/usr/bin/env bash
# Builds the desktop app of a branch twice: the tip and the parent of the
# change, so the evidence can show what the change does.
#
#   build-app-pair.sh <worktree> <branch> <sha-before> [tag]
#
# The binaries land in $LOOP_DIR/evidence/<tag>-app-{before,after}. The tag
# defaults to the issue number of the branch name, so two issues do not
# overwrite each other's binaries.
set -uo pipefail

WT="${1:?worktree}"
BRANCH="${2:?branch}"
BEFORE="${3:?sha before}"
TAG="${4:-$(basename "$BRANCH" | sed -n 's/.*issue-\([0-9][0-9]*\).*/\1/p')}"
LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
OUT="$LOOP_DIR/evidence"
TARGET="${TARGET_DIR:-/home/user/solidcraft/target}"
JOBS="${JOBS:-2}"

mkdir -p "$OUT"
cd "$WT" || exit 1

# Builds the app. The exit status is cargo's: a FAILED build must not pass
# for a good one. The target dir keeps the binary of the previous build, so
# the file test alone would copy a stale binary and the evidence would show
# the same app twice (the "before" and the "after" would be the same file).
build() {
  nice -n 19 cargo build -j "$JOBS" --target-dir "$TARGET" -p solidcraft 2>&1 | tail -5
}

echo "=== building the tip ($BRANCH) ==="
if ! build; then
  echo "the build of the tip failed" >&2
  exit 1
fi
if [ ! -x "$TARGET/debug/solidcraft" ]; then
  echo "the build of the tip did not produce a binary" >&2
  exit 1
fi
cp -f "$TARGET/debug/solidcraft" "$OUT/${TAG}-app-after"
echo "after: $OUT/${TAG}-app-after"

echo "=== building the parent ($BEFORE) ==="
rc=0
if ! git checkout --detach "$BEFORE" 2>&1 | tail -2; then
  echo "could not check out $BEFORE" >&2
  git checkout "$BRANCH" 2>&1 | tail -2
  exit 1
fi
if ! build; then
  echo "the build of the parent failed" >&2
  rc=1
elif [ ! -x "$TARGET/debug/solidcraft" ]; then
  echo "the build of the parent did not produce a binary" >&2
  rc=1
else
  cp -f "$TARGET/debug/solidcraft" "$OUT/${TAG}-app-before"
  echo "before: $OUT/${TAG}-app-before"
fi

echo "=== back on the branch ==="
if ! git checkout "$BRANCH" 2>&1 | tail -2; then
  echo "could not go back to $BRANCH: the worktree is left detached" >&2
  rc=1
fi
git log --oneline -1
exit "$rc"
