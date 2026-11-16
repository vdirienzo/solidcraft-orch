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
  -p MemoryHigh=12G -p MemoryMax=16G \
  -p CPUWeight=100 -p IOWeight=50 \
  /bin/bash -c "cd $SOLIDCRAFT_REPO && exec nice -n 19 bash $LOOP_DIR/bin/agent-issue.sh $ISSUE --repo tangency-labs/solidcraft --work $WORKTREES_DIR --timeout $TIMEOUT_MIN >> $LOG 2>&1"
