#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# slot-busy.sh - is somebody working in this slot right now?
#
# WHY THIS EXISTS (19-11-2026): the wave closes the slots whose work is done,
# and "the PR exists" is NOT "the work is done": an agent that opened the PR
# keeps working on it (the gate, the evidence, the fix of the gate). Closing
# that slot deletes the worktree UNDER a running compile, and the compile
# dies with it.
#
# THE SIGNAL: a process whose command line, or whose working directory, is
# inside the worktree of the slot or inside its target directory. The agent
# (hermes), the cargo, the rustc and the gate all show up there.
#
# A false positive is SAFE (the slot is left alone for a while); a false
# negative is not (the work of a live agent is deleted). So the check is
# deliberately wide.
#
# USAGE:
#   bash bin/slot-busy.sh <worktree> [target dir]
#
# EXIT CODES:
#   0  somebody is working in the slot (it is BUSY)
#   1  nobody is working in the slot
#   2  bad usage
# ---------------------------------------------------------------------------
set -uo pipefail

WT="${1:-}"
TD="${2:-}"

[ -n "$WT" ] || { echo "slot-busy: falta el worktree" >&2; exit 2; }
# Without a worktree there is nothing to be working in.
[ -d "$WT" ] || exit 1

for proc in /proc/[0-9]*; do
  pid="${proc##*/}"
  [ "$pid" = "$$" ] && continue
  cmd="$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null)"
  # This script, and anything that runs it, mentions the path by definition.
  case "$cmd" in
    *slot-busy.sh*) continue ;;
  esac
  cwd="$(readlink "$proc/cwd" 2>/dev/null || true)"
  haystack="$cmd $cwd"
  case "$haystack" in
    *"$WT"*)
      echo "busy: pid $pid (${cmd:0:120})"
      exit 0
      ;;
  esac
  if [ -n "$TD" ]; then
    case "$haystack" in
      *"$TD"*)
        echo "busy: pid $pid (${cmd:0:120})"
        exit 0
        ;;
    esac
  fi
done

exit 1
