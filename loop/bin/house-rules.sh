#!/usr/bin/env bash
# The house rules of the loop, installed in a worktree WITHOUT touching a
# versioned file.
#
# WHY: the rules used to be injected with a patch over `AGENTS.md`. That
# modified a TRACKED file: the tree was left dirty, the rebase needed
# `--autostash` and the autostash of a failed rebase could leave `main` with
# `UU AGENTS.md`. Now the rules live in an UNTRACKED file in the root of the
# worktree (`.house-rules.md`) and that file is excluded from git with a
# per-worktree `core.excludesFile`: the tree stays clean, the rules travel
# with the worktree and no versioned file is ever modified.
#
# The exclusion is per worktree on purpose: `core.excludesFile` in the shared
# config is read by EVERY worktree (and two worktrees would fight over the
# same key). With `extensions.worktreeConfig` the value lives in the config
# of THIS worktree. Both settings live in `.git`, which is not versioned.
#
# The patterns of the excludes file are resolved from the top of the working
# tree, so the same file works in every worktree.
#
# Usage:
#   house-rules.sh install <worktree>   # install the rules, print their path
#   house-rules.sh path <worktree>      # print the path (nothing if there is none)
#   house-rules.sh check <worktree>     # verify the installation
set -u

RULES_NAME=".house-rules.md"
EXCLUDE_NAME=".house-rules.exclude"
HERE="$(cd "$(dirname "$0")" && pwd)"
RULES_SRC="$HERE/house-rules.md"
EXCLUDE_SRC="$HERE/house-rules.exclude"

usage() {
  echo "usage: house-rules.sh {install|path|check} <worktree>" >&2
  exit 2
}

# The directory must be a git work tree.
is_worktree() {
  [ -d "$1" ] && git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# The two files must NOT show up in the status of the worktree: a dirty tree
# is exactly what this whole change is about.
files_in_status() {
  git -C "$1" status --porcelain 2>/dev/null \
    | grep -F -e "$RULES_NAME" -e "$EXCLUDE_NAME" || true
}

install_rules() {
  local dir="$1" exclude_file shown
  if ! is_worktree "$dir"; then
    echo "house-rules: not a git work tree: $dir" >&2
    return 1
  fi
  if [ ! -f "$RULES_SRC" ] || [ ! -f "$EXCLUDE_SRC" ]; then
    echo "house-rules: the rules of the house are missing: $RULES_SRC" >&2
    return 1
  fi
  # The per-worktree config. `extensions.worktreeConfig` lives in the shared
  # config (it is a property of the repository) and makes the value BELOW
  # live in the config of THIS worktree.
  git -C "$dir" config extensions.worktreeConfig true >/dev/null 2>&1 || true
  exclude_file="$dir/$EXCLUDE_NAME"
  cp "$EXCLUDE_SRC" "$exclude_file" || return 1
  cp "$RULES_SRC" "$dir/$RULES_NAME" || return 1
  if ! git -C "$dir" config --worktree core.excludesFile "$exclude_file" >/dev/null 2>&1; then
    echo "house-rules: core.excludesFile could not be set in $dir" >&2
    rm -f "$dir/$RULES_NAME" "$exclude_file"
    return 1
  fi
  # The verification: the tree must NOT show the two files. If it shows them
  # the exclusion did not work: they are removed and it is a hard error (a
  # dirty tree is what broke the loop).
  shown="$(files_in_status "$dir")"
  if [ -n "$shown" ]; then
    echo "house-rules: the exclusion did not work in $dir: $shown" >&2
    git -C "$dir" config --worktree --unset core.excludesFile >/dev/null 2>&1 || true
    rm -f "$dir/$RULES_NAME" "$exclude_file"
    return 1
  fi
  printf '%s\n' "$dir/$RULES_NAME"
}

path_rules() {
  local dir="$1"
  if [ -f "$dir/$RULES_NAME" ]; then
    printf '%s\n' "$dir/$RULES_NAME"
  fi
}

check_rules() {
  local dir="$1" shown excludes ok=0
  if ! is_worktree "$dir"; then
    echo "house-rules: not a git work tree: $dir" >&2
    return 1
  fi
  [ -f "$dir/$RULES_NAME" ] && ok=$((ok + 1))
  [ -f "$dir/$EXCLUDE_NAME" ] && ok=$((ok + 1))
  excludes="$(git -C "$dir" config --worktree core.excludesFile 2>/dev/null || true)"
  [ "$excludes" = "$dir/$EXCLUDE_NAME" ] && ok=$((ok + 1))
  shown="$(files_in_status "$dir")"
  [ -z "$shown" ] && ok=$((ok + 1))
  if [ "$ok" -ne 4 ]; then
    echo "house-rules: the installation in $dir is not complete:" \
      "rules=$([ -f "$dir/$RULES_NAME" ] && echo yes || echo no)" \
      "exclude=$([ -f "$dir/$EXCLUDE_NAME" ] && echo yes || echo no)" \
      "excludesFile=${excludes:-none}" \
      "in_status=${shown:-none}" >&2
    return 1
  fi
  printf '%s\n' "$dir/$RULES_NAME"
}

[ "$#" -ge 2 ] || usage
cmd="$1"
dir="$2"
case "$cmd" in
  install) install_rules "$dir" ;;
  path) path_rules "$dir" ;;
  check) check_rules "$dir" ;;
  *) usage ;;
esac
