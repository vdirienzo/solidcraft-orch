#!/usr/bin/env bash
# The watchdog of the COMPLETE gate: it decides whether the gate that is
# running has to be killed, and it says why.
#
# THE AGE ALONE DOES NOT DECIDE. The complete gate takes about 2 h 50 min
# and it PRINTS while it works (nextest lists its slow tests every minute,
# so the log grows every 60 s). It was killed TWICE by the age alone while
# it was making progress: 2 h 50 min of CPU thrown away twice, and the
# issue that was in flight stayed without a verdict for hours.
#
# There are three ways to say that the gate is not worth the machine:
#
#   * stale:   the sha it is gating is no longer in the history of the
#              branch the loop works on. The branch was REWRITTEN (a
#              rebase, an amend) and the gate is verifying code that does
#              not exist any more: its verdict could never be used. This
#              is the waste that was measured: 2 h 50 min of CPU for a
#              commit that the branch threw away.
#   * stuck:   its log has not moved for GATE_SILENT_MIN minutes. The gate
#              holds ten cores and thirty gigabytes: a gate that says
#              nothing for an hour and a half is not going to say more,
#              and it blocks every other heavy phase of the machine.
#   * expired: it is older than the hard ceiling (GATE_TIMEOUT_MIN). This
#              is the BACKSTOP: it applies even to a gate that prints.
#
# A gate that is making progress and is younger than the ceiling is LEFT
# ALONE. The decision is a property of the gate itself: it never depends on
# the load, on the state of the machine, on the slot or on the phase.
#
# IT FAILS OPEN. If the age cannot be measured, or the log cannot be read,
# or the branch cannot be resolved, the verdict is `alive`: the watchdog
# never kills a gate it cannot judge.
#
# Usage:
#   gate-watchdog.sh --pid N --started EPOCH --now EPOCH --log PATH \
#                    [--sha SHA] [--branch NAME] [--repo DIR] \
#                    [--timeout-min N] [--silent-min N]
#
# Output (stdout, key=value):
#   VERDICT=alive|stale|stuck|expired
#   REASON=<text>
#   AGE_MIN=<n>
#   SILENT_MIN=<n>
#   LOG=<path>
set -uo pipefail

PID=0
STARTED=0
NOW=0
LOG=""
SHA=""
BRANCH=""
REPO=""
TIMEOUT_MIN=300
SILENT_MIN=90

while [ $# -gt 0 ]; do
  case "$1" in
    --pid) PID="${2:-0}"; shift 2 ;;
    --started) STARTED="${2:-0}"; shift 2 ;;
    --now) NOW="${2:-0}"; shift 2 ;;
    --log) LOG="${2:-}"; shift 2 ;;
    --sha) SHA="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --timeout-min) TIMEOUT_MIN="${2:-300}"; shift 2 ;;
    --silent-min) SILENT_MIN="${2:-90}"; shift 2 ;;
    *) shift ;;
  esac
done

is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

is_num "$TIMEOUT_MIN" || TIMEOUT_MIN=300
is_num "$SILENT_MIN" || SILENT_MIN=90
is_num "$NOW" || NOW="$(date +%s)"
is_num "$STARTED" || STARTED=0

# --- the age --------------------------------------------------------------
# The age is measured from the START (gate.started), never from the mtime of
# the log: the log is written by the gate, the start is written by the one
# that launched it.
AGE_MIN=-1
if [ "$STARTED" -gt 0 ] && [ "$NOW" -gt "$STARTED" ]; then
  AGE_MIN=$(( (NOW - STARTED) / 60 ))
fi

# --- the silence ----------------------------------------------------------
# The mtime of the log is the clock of the progress: nextest prints its slow
# tests every minute, so a gate that works refreshes it every 60 s.
#
# A log that cannot be read says NOTHING about the progress (-1 = unknown):
# the watchdog does not read the log, it only asks for its date. A log that
# does not exist, or that exists but cannot be read (the mode of the file was
# changed, the path is a directory, the mount went away), is NOT a silence:
# a silence is a PROOF that the gate said nothing, and a log that cannot be
# read is no proof at all. The watchdog fails open: it never kills a gate it
# cannot judge.
SILENT_MIN_AGE=-1
if [ -n "$LOG" ] && [ -f "$LOG" ] && [ -r "$LOG" ]; then
  m="$(stat -c %Y "$LOG" 2>/dev/null || echo 0)"
  is_num "$m" || m=0
  if [ "$m" -gt 0 ] && [ "$NOW" -gt "$m" ]; then
    SILENT_MIN_AGE=$(( (NOW - m) / 60 ))
  fi
fi

emit() {
  printf 'VERDICT=%s\n' "$1"
  printf 'REASON=%s\n' "$2"
  printf 'AGE_MIN=%s\n' "$AGE_MIN"
  printf 'SILENT_MIN=%s\n' "$SILENT_MIN_AGE"
  printf 'LOG=%s\n' "$LOG"
}

# --- the drift of the tip -------------------------------------------------
# The gate gates ONE sha. If that sha is no longer in the history of the
# branch the loop works on, the branch was REWRITTED and the gate is
# verifying code that does not exist any more.
#
# It fails open: without a repo, without a branch, without a sha that
# exists in the repo, or with a git that cannot answer, there is no drift.
drift() {
  [ -n "$SHA" ] || return 1
  [ -n "$BRANCH" ] || return 1
  [ -n "$REPO" ] || return 1
  [ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || return 1
  # The sha has to be a commit of THIS repo: a stale gate.sha of a gate of
  # another repo is not a drift, it is garbage.
  git -C "$REPO" cat-file -e "${SHA}^{commit}" 2>/dev/null || return 1
  tip="$(git -C "$REPO" rev-parse --verify --quiet "${BRANCH}^{commit}" 2>/dev/null)"
  [ -n "$tip" ] || return 1
  [ "$tip" = "$SHA" ] && return 1
  # The sha is still in the history of the branch (the branch moved on top
  # of it): the verdict is old but the work is not thrown away.
  git -C "$REPO" merge-base --is-ancestor "$SHA" "$tip" 2>/dev/null && return 1
  # THE BRANCH WAS REWRITTEN. The proof is the REFLOG of the branch: the
  # sha was part of the branch (it is an ancestor of one of its PAST tips)
  # and the branch does not have it any more.
  #
  # The reflog is what makes this safe. Without it, "the sha is not an
  # ancestor of the tip" would also be true for the gate of ANOTHER pull
  # request (bin/gate-open-prs.sh gates the head of a foreign branch):
  # that gate would be killed for no reason. With it, the sha of a foreign
  # gate is not an ancestor of any past tip of this branch, so there is no
  # drift and the gate is left alone.
  #
  # This is the waste that was measured: a gate that took 2 h 50 min on a
  # commit that a rebase threw away.
  local old
  for old in $(git -C "$REPO" reflog show --format=%H "$BRANCH" 2>/dev/null | head -50); do
    [ "$old" = "$SHA" ] && { DRIFT_TIP="$tip"; DRIFT_OLD="$old"; return 0; }
    if git -C "$REPO" merge-base --is-ancestor "$SHA" "$old" 2>/dev/null; then
      DRIFT_TIP="$tip"; DRIFT_OLD="$old"; return 0
    fi
  done
  return 1
}

DRIFT_TIP=""
DRIFT_OLD=""
if drift; then
  emit "stale" "the sha $SHA was part of $BRANCH (it is in the history of its past tip ${DRIFT_OLD:0:9}) but the branch was rewritten and its tip is ${DRIFT_TIP:0:9} now: this gate verifies code that does not exist any more"
  exit 0
fi

# --- the silence ----------------------------------------------------------
# The age of the silence only counts when it can be measured.
if [ "$SILENT_MIN_AGE" -ge 0 ] && [ "$SILENT_MIN_AGE" -gt "$SILENT_MIN" ]; then
  emit "stuck" "its log has not moved for ${SILENT_MIN_AGE} min: the gate holds the machine and is not going to say anything"
  exit 0
fi

# --- the hard ceiling -----------------------------------------------------
# The backstop: it applies even to a gate that prints. It is the ONLY thing
# that the old watchdog had, and it was the wrong thing.
if [ "$AGE_MIN" -ge 0 ] && [ "$AGE_MIN" -gt "$TIMEOUT_MIN" ]; then
  emit "expired" "the gate is ${AGE_MIN} min old and the ceiling is ${TIMEOUT_MIN} min"
  exit 0
fi

if [ "$SILENT_MIN_AGE" -lt 0 ]; then
  emit "alive" "the gate is ${AGE_MIN} min old and its log cannot be read (or does not exist): it is left alone"
else
  emit "alive" "the gate is ${AGE_MIN} min old and its log moved ${SILENT_MIN_AGE} min ago: it is left alone"
fi
exit 0
