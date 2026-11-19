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
# THE SIGNAL (two, and both are hard to fake):
#   1. the WORKING DIRECTORY of the process is inside the worktree of the
#      slot or inside its target directory;
#   2. the process has a FILE OPEN inside them (a descriptor).
#
# WHY NOT THE COMMAND LINE (it was the first version, and it was wrong): a
# command line that MENTIONS the path is not a process that WORKS in it. A
# shell that runs "ls -d <the worktree of a slot>" was enough to make the wave
# believe that the slot was alive, and a slot that is never closed is 7 GB
# that nobody frees. The command line is still used, but only as a CHEAP
# FILTER to know which processes are worth looking at.
#
# A false positive is SAFE (the slot is left alone for a while); a false
# negative is not (the work of a live agent is deleted). So the check is
# deliberately wide, but it asks for WORK, not for a mention.
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

inside() {
  # Is the path inside the worktree or inside the target dir?
  local path="$1"
  case "$path" in
    "$WT"/*|"$WT") return 0 ;;
  esac
  if [ -n "$TD" ]; then
    case "$path" in
      "$TD"/*|"$TD") return 0 ;;
    esac
  fi
  return 1
}

for proc in /proc/[0-9]*; do
  pid="${proc##*/}"
  [ "$pid" = "$$" ] && continue

  # 1. EL DIRECTORIO DE TRABAJO: el agente (hermes) esta ahi.
  cwd="$(readlink "$proc/cwd" 2>/dev/null || true)"
  if [ -n "$cwd" ] && inside "$cwd"; then
    echo "busy: pid $pid trabaja en $cwd"
    exit 0
  fi

  # 2. LA LINEA DE COMANDO: solo como filtro de los que hay que mirar.
  cmd="$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null)"
  case "$cmd" in
    *slot-busy.sh*) continue ;;
  esac
  case "$cmd" in
    *"$WT"*) ;;
    *) [ -n "$TD" ] && case "$cmd" in *"$TD"*) ;; *) continue ;; esac ;;
  esac

  # 3. LOS DESCRIPTORES: un archivo abierto ahi es trabajo de verdad.
  for fd in "$proc"/fd/*; do
    [ -e "$fd" ] || continue
    target="$(readlink "$fd" 2>/dev/null || true)"
    if [ -n "$target" ] && inside "$target"; then
      echo "busy: pid $pid tiene abierto $target"
      exit 0
    fi
  done
done

exit 1
