#!/usr/bin/env bash
# Launch an issue runner for the orchestrator with the belt that the Hermes
# worker scope does not have.
#
# WHY THIS EXISTS (10-11-2026): the runner used to be launched straight from
# the cron turn, so it inherited the Hermes worker scope, whose memory.max is
# 4 GiB (4294967296). The agent's own cargo build blew that cap and the OOM
# killer took the WHOLE scope: the agent died mid-work with a transport error
# and left no commit (dmesg: hermes-worker-proc_*.scope: Failed with result
# 'oom-kill', 4G memory peak). A transient scope with its own memory.max
# moves the belt to the runner: an OOM now kills the runner, not the turn.
#
# The scope is created in app.slice as a SIBLING of the Hermes worker scope
# (verified: /user.slice/user-1001.slice/user@1001.service/app.slice/<unit>),
# so the 4 GiB cap of the worker scope does not apply to it.
#
# THE BELT IS NOT WRITTEN HERE (2026-11-21): this script used to carry
# MemoryHigh=12G and MemoryMax=16G, and the box has 15 GB. A belt bigger
# than the box is no belt: the scope could ask for more RAM than the
# machine has, and the OOM killer takes whatever it finds FIRST. That was
# the gateway of Hermes, and with it every session of the box.
#
# The numbers come from the POLICY of the box (config.env): that file is
# the only place that says how much RAM this machine has, and the numbers
# follow the box and not the day the script was written.
#
# Usage: run-issue-scope.sh <issue> <target-dir> <unit> [timeout-min]
set -uo pipefail

ISSUE="$1"
TARGET_DIR="$2"
UNIT="$3"
TIMEOUT_MIN="${4:-40}"

LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"

# The belt of the scope, from the policy of the box.
#
# The policy is read with a small parser and NOT sourced: the file has
# comments and lines this script does not need, and sourcing a file that
# changed shape would run whatever it says. The LAST definition wins,
# because the policy is read in order and its last block is the one that
# describes THIS box.
policy_value() {
  local key="$1" found=""
  [ -r "$LOOP_DIR/config.env" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "$key"=*) found="${line#*=}" ;;
    esac
  done < "$LOOP_DIR/config.env"
  found="${found%%#*}"
  found="$(printf '%s' "$found" | tr -d '"'"'" | tr -d '[:space:]')"
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

SLOT_MEMORY_HIGH="${SLOT_MEMORY_HIGH:-$(policy_value SLOT_MEMORY_HIGH || true)}"
SLOT_MEMORY_MAX="${SLOT_MEMORY_MAX:-$(policy_value SLOT_MEMORY_MAX || true)}"
# Without a policy the scope gets NO ceiling of its own: the belt of the
# worker scope (4 GiB) applies and the agent dies alone, which is the
# failure this script exists to avoid. A wrong ceiling is worse than a
# missing one, so the launcher refuses to guess.
if [ -z "$SLOT_MEMORY_HIGH" ] || [ -z "$SLOT_MEMORY_MAX" ]; then
  echo "run-issue-scope: the policy of the box does not say how much RAM a slot may ask for:" \
    "SLOT_MEMORY_HIGH / SLOT_MEMORY_MAX are missing from $LOOP_DIR/config.env" >&2
  exit 2
fi

# A per-slot CARGO_TARGET_DIR keeps two agents off one cargo build lock.
# NOTE: agent-issue.sh sources config.env with `set -a`, and config.env pins
# CARGO_TARGET_DIR=<repo>/target, so the export below is
# OVERRIDDEN for the runner's own shell. It is exported anyway so the agent
# inherits it if config.env ever stops pinning it.
export CARGO_TARGET_DIR="$TARGET_DIR"
export CARGO_BUILD_JOBS=4
export CARGO_INCREMENTAL=0
export CARGO_PROFILE_DEV_DEBUG=0
export CARGO_PROFILE_TEST_DEBUG=0

LOG="$ORCH_DIR/logs/$ISSUE-wave.log"

exec systemd-run --user --scope --quiet --unit="$UNIT" \
  -p "MemoryHigh=$SLOT_MEMORY_HIGH" -p "MemoryMax=$SLOT_MEMORY_MAX" \
  -p CPUWeight=100 -p IOWeight=50 \
  /bin/bash -c "cd $SOLIDCRAFT_REPO && exec nice -n 19 bash $LOOP_DIR/bin/agent-issue.sh $ISSUE --repo tangency-labs/solidcraft --work $WORKTREES_DIR --timeout $TIMEOUT_MIN >> $LOG 2>&1"
