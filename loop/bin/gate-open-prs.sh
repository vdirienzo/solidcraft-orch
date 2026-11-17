#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gate-open-prs.sh - runs the COMPLETE gate on the open pull requests of ours.
#
# WHY: the merge queue of the upstream needs the `ci` context of the head of
# the PR to be green. The light lane of that context (quick compile, format
# and repository checks, select checks) does NOT run the test suite, and the
# heavy lane waits for the `approved-for-ci` label, which only a maintainer
# can add. So a PR whose head passes the light lane can still fail the heavy
# one, and the merge stops there with a red `ci`.
#
# This script runs the heavy lane LOCALLY, on the head of each of our open
# PRs, so that a red is found here and not on the upstream. It is the same
# gate the loop runs (bin/start-gate.sh), on the same worktree, with the same
# bounded test pool.
#
# ONE GATE AT A TIME. The gate saturates the machine (load 231 over 16 vCPU),
# and two of them at the same time take twice as long and make the tests that
# assert on wall-clock time fail for that reason alone. The gate of this
# script is a gate of the `manual` slot, so the gates of the loop queue
# behind it (start-gate.sh exits with 6 and leaves the request), and the
# drain of the queue (bin/gate-queue.sh, with its own timer) serves them
# when this one finishes. The loop keeps the priority: this script waits
# while there is a live gate or a request in the queue.
#
#   bash bin/gate-open-prs.sh <pr> [<pr> ...]
#
# The exit code is 0 when every PR was gated, and 1 when one of them was not.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"

# The directory of this script: the checker of the configuration
# (bin/config-preflight.sh) lives next to it and it is called by path,
# never by a guess.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ERR="$LOOP_DIR/logs/gate-open-prs-$(date +%Y-%m-%d).log"

# The configuration is CHECKED before it is sourced: a value with spaces
# and no quotes breaks the source in the middle of the file, so the
# variable is never set and the script goes on with HALF of the policy, in
# silence (set -e is not on). The check only READS the file: the config.env
# is read twice and sourced once. If the config.env is broken, the script
# STOPS here instead of running with half of the policy.
if [ -r "$LOOP_DIR/config.env" ]; then
  if [ -x "$SCRIPT_DIR/config-preflight.sh" ]; then
    bash "$SCRIPT_DIR/config-preflight.sh" "$LOOP_DIR/config.env" || exit 2
  elif ! bash -n "$LOOP_DIR/config.env" >/dev/null 2>&1; then
    echo "gate-open-prs: the config.env has a syntax error: $LOOP_DIR/config.env" >&2
    exit 2
  fi
fi

# shellcheck source=/dev/null
[ -r "$LOOP_DIR/config.env" ] && . "$LOOP_DIR/config.env"

UPSTREAM="${UPSTREAM:-tangency-labs/solidcraft}"
GATE_WORKTREE="${GATE_WORKTREE:-$LOOP_DIR/../solidcraft-gate}"
SLOT="manual"
POLL_SEC="${POLL_SEC:-30}"

say() { echo "[$(date -Is)] $*" | tee -a "$ERR" >&2; }

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <pr> [<pr> ...]" >&2
  exit 2
fi

mkdir -p "$LOOP_DIR/logs"

# --- the state of the gates of the machine -----------------------------------
# A gate is alive when its pid is alive. The sidecar (gate.pid) is the live
# gate of the machine; the gates/<slot>/pid are the gates of the slots.
live_gate_pid() {
  local file pid
  for file in "$LOOP_DIR/gate.pid" "$LOOP_DIR"/gates/*/pid; do
    [ -r "$file" ] || continue
    pid="$(tr -dc '0-9' < "$file" 2>/dev/null | head -c 10)"
    [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null; then
      printf '%s' "$pid"
      return 0
    fi
  done
  return 1
}

queued_requests() {
  local n=0 file
  for file in "$LOOP_DIR"/gates/*/request; do
    [ -r "$file" ] || continue
    n=$(( n + 1 ))
  done
  printf '%s' "$n"
}

# --- the head of a pull request ----------------------------------------------
# gh prints the error of the API as JSON on stdout when the call fails, so the
# value is checked: a sha is 40 hex characters and nothing else.
pr_head() {
  local sha
  sha="$(gh api "repos/$UPSTREAM/pulls/$1" --jq '.head.sha' 2>/dev/null)"
  case "${sha:-}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) printf '%s' "$sha" ;;
    *) printf '' ;;
  esac
}

pr_branch() {
  local branch
  branch="$(gh api "repos/$UPSTREAM/pulls/$1" --jq '.head.ref' 2>/dev/null)"
  case "${branch:-}" in
    *'{'*|*'"'*) printf '' ;;
    '') printf '' ;;
    *) printf '%s' "$branch" ;;
  esac
}

# --- wait for the machine ----------------------------------------------------
# The loop has the priority: while it has a gate alive, or a request waiting
# in its queue, this script does nothing.
wait_for_the_machine() {
  while :; do
    if pid="$(live_gate_pid)"; then
      say "the gate $pid of the machine is alive: waiting"
      sleep "$POLL_SEC"
      continue
    fi
    if [ "$(queued_requests)" -gt 0 ]; then
      say "there are requests in the queue of the gates: waiting"
      sleep "$POLL_SEC"
      continue
    fi
    return 0
  done
}

# --- wait for a gate to finish ------------------------------------------------
wait_for_the_gate() {
  local pid_file="$LOOP_DIR/gates/$SLOT/pid" pid
  while :; do
    pid="$(tr -dc '0-9' < "$pid_file" 2>/dev/null | head -c 10)"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep "$POLL_SEC"
  done
}

FAILED=0
for pr in "$@"; do
  sha="$(pr_head "$pr")"
  branch="$(pr_branch "$pr")"
  if [ -z "$sha" ] || [ -z "$branch" ]; then
    say "PR #$pr: the head could not be read: it is skipped"
    FAILED=1
    continue
  fi
  slug="$(printf '%s' "$branch" | tr -c 'a-zA-Z0-9._-' '-')"

  wait_for_the_machine

  say "PR #$pr ($branch, ${sha:0:8}): the complete gate is launched"
  bash "$LOOP_DIR/bin/start-gate.sh" "$sha" "$pr" "$slug" \
    --slot "$SLOT" --worktree "$GATE_WORKTREE" >>"$ERR" 2>&1
  rc=$?
  case "$rc" in
    0) ;;
    6)
      # Another gate took the machine in the race: the request that
      # start-gate.sh left is ours and nobody else has to serve it.
      rm -f "$LOOP_DIR/gates/$SLOT/request"
      say "PR #$pr: the machine was taken: it is tried again later"
      sleep "$POLL_SEC"
      continue
      ;;
    *)
      say "PR #$pr: the gate was not launched (exit $rc): it is skipped"
      FAILED=1
      continue
      ;;
  esac

  wait_for_the_gate
  verdict="$(bash "$LOOP_DIR/bin/gate-check.sh" "$LOOP_DIR/gate.path" 2>/dev/null | tr '\n' ' ')"
  say "PR #$pr: the gate of ${sha:0:8} finished: $verdict"
  case "$verdict" in
    *"VERDICT=VERDE"*) ;;
    *) FAILED=1 ;;
  esac
done

say "done ($FAILED problems)"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
