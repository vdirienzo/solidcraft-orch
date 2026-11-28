#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# paths.sh - the paths of this machine, resolved once. SOURCED, not run.
#
# WHY THIS EXISTS (2026-11-24): eleven scripts of bin/ carried their own
# default for the checkout of SolidCraft, and the default was STALE: it
# pointed at the old checkout of the machine, which does not exist here any
# more (the checkout is at ~/Projects/solidcraft-orch). The portability test
# was green the whole time: it checks the SHAPE of a path (a path inside a
# default) and not the TRUTH (that the default points at something that is
# there). A default that does not exist is a bug only the machine can see,
# and it did: bin/branch-risk.sh answered "this is not a git checkout" about
# a checkout that was there all along.
#
# (the old path is not written here on purpose: bin/test-portability.sh fails
# a script of bin/ that carries a hardcoded path of this machine outside a
# default, and a comment is not a default)
#
# THE ORDER (the first one that answers wins):
#   1. the environment:      SOLIDCRAFT_REPO=... bash bin/gate.sh
#   2. the policy of the machine: $LOOP_DIR/config.env
#   3. the default of this machine
#
# WHY THE POLICY IS NOT THE ONLY SOURCE: that file is written by hand and a
# hand-written path rots. A policy that names a path which is not there is
# stale, so the default of the code answers instead, and bin/preflight.sh
# says that it did. The environment always wins: whoever exports a variable
# is asking for THAT path, even if it does not exist yet.
#
# USAGE:
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"
#
# IT DOES NOT FAIL WHEN A PATH IS MISSING: the resolver resolves, the script
# decides. bin/preflight.sh is the one that says what the machine lacks.
#
# WHAT IT DEFINES (and exports): ORCH_DIR, LOOP_DIR, SOLIDCRAFT_REPO,
# WORKTREES_DIR.
# ---------------------------------------------------------------------------

ORCH_DIR="${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
CONFIG="${ORCH_CONFIG:-$LOOP_DIR/config.env}"

# The value of a key of the policy file, without its comment and without the
# quotes around it.
read_policy() {
  [ -f "$CONFIG" ] || return 1
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$CONFIG" 2>/dev/null | tail -1 \
    | cut -d= -f2- | cut -d'#' -f1 \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s|^'"'"'||; s|'"'"'$||' \
    | sed "s|^~|$HOME|"
}

# The checkout of SolidCraft: the one with the branches, the one the gate
# compiles in. The policy names it with SOLIDCRAFT_REPO; REPO is the legacy
# name of the same thing (the scripts of loop/ still read that one).
resolve_checkout() {
  local value
  value="$(read_policy SOLIDCRAFT_REPO 2>/dev/null || true)"
  [ -n "$value" ] || value="$(read_policy REPO 2>/dev/null || true)"
  if [ -n "$value" ] && [ -d "$value" ]; then
    printf '%s' "$value"
    return 0
  fi
  printf '%s' "$HOME/Projects/solidcraft-orch"
}

# The worktrees of the slots. This one is created on demand, so "it does not
# exist" is not a reason to ignore the policy.
resolve_worktrees() {
  local value
  value="$(read_policy WORKTREES_DIR 2>/dev/null || true)"
  [ -n "$value" ] || value="$HOME/solidcraft-wt"
  printf '%s' "$value"
}

SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-$(resolve_checkout)}"
WORKTREES_DIR="${WORKTREES_DIR:-$(resolve_worktrees)}"

export ORCH_DIR LOOP_DIR SOLIDCRAFT_REPO WORKTREES_DIR
