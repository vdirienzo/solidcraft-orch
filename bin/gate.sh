#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gate.sh - the scoped local gate of ONE slot, in the target directory of
# that slot.
#
# WHY THIS EXISTS (31-10-2026): the gate and the agent of a slot compiled in
# TWO different target directories: the agent in the orchestrator's tree
# (<orch>/targets/slot-N) and the gate in the loop's tree
# (<loop>/gate-quick/target/slot-N). Both grew to 12 GB for the same slot
# (#7114) and neither could reuse the other's work: the gate recompiled the
# world that the agent had just compiled, and every rebuild paid the full
# price again.
#
# The maintainer's own recommendation (31-10-2026) is ONE persistent
# CARGO_TARGET_DIR per slot, with sccache, instead of a fresh build every
# time. That is what this script does: the gate of a slot compiles in the
# target directory of that slot, the same one the agent used, so the
# artifacts of the agent are the artifacts the gate checks.
#
# The gate runs in the WORKTREE of the slot (REPO), not in the main
# checkout: the change it has to judge lives there.
#
# USAGE:
#   bash bin/gate.sh <issue> <sha> [base]
#
#   <issue>  the slot: the number of the issue (the branch and the lock)
#   <sha>    the commit to check
#   <base>   the base of the diff (default: origin/main)
#
# IT DOES NOT RUN THE FULL `cargo xtask ci`: the CI of the upstream runs the
# full suite when a maintainer adds the label approved-for-ci, and the merge
# queue runs it again on top of main. A fair local gate is:
#   cargo fmt --all --check
#   cargo check --workspace --all-targets --profile ci
#   cargo clippy -D warnings on the packages the change touches
#   nextest on the crates that scripts/ci/affected.py selects
# ---------------------------------------------------------------------------
set -uo pipefail

ORCH_DIR="${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
GATE_SCRIPT="$LOOP_DIR/bin/gate-quick.sh"

ISSUE="${1:-}"
SHA="${2:-}"
BASE="${3:-origin/main}"
# OUR PR: the pull request of OURS that claims this issue. The gate checks
# the claim of the issue BEFORE it compiles, and the check has to know
# which pull request is ours: without it, our own pull request looks like
# the competitor that took the issue and the gate refuses to run on our
# own work (exit 4). It is discovered from the branch of the worktree when
# it is not given.
OUR_PR="${4:-}"

if [ -z "$ISSUE" ] || [ -z "$SHA" ]; then
  echo "usage: bash bin/gate.sh <issue> <sha> [base] [our_pr]" >&2
  exit 2
fi
if [ ! -x "$GATE_SCRIPT" ] && [ ! -f "$GATE_SCRIPT" ]; then
  echo "gate.sh: the gate script is not there: $GATE_SCRIPT" >&2
  exit 2
fi

# The target directory of the slot: THE SAME one the agent used. The gate
# helper of the loop resolves the layout from GATE_QUICK_TARGET_DIR, so the
# base is what has to be pointed here (the helper appends slot-<name>).
export GATE_QUICK_TARGET_DIR="$ORCH_DIR/targets"
export CARGO_TARGET_DIR="$(bash "$ORCH_DIR/bin/slot-target-dir.sh" --slot "$ISSUE")"
# The number of parallel jobs of the compilations, divided between the
# compilations that run at the same time. The machine has 16 cores and is
# shared: five concurrent compilations with 12 jobs each ask for 60 and the
# "system time x8" cliff of ~/.cargo/config.toml is reached. See
# bin/cargo-jobs.sh.
export CARGO_BUILD_JOBS="$(bash "$ORCH_DIR/bin/cargo-jobs.sh")"
# Without incremental, sccache can cache the compilation: with it, every
# rustc is non-cacheable and each slot compiles the same dependencies
# from scratch (measured: 383 misses and 0 hits, 7,4 s of compiler per
# miss). The cache is shared between the slots, so the dependencies are
# paid once for the whole box and not once per slot.
export CARGO_INCREMENTAL=0
# The token of a build slot: only BUILD_SLOTS compilations run at the same
# time on this box. Six at once (2 gates, 3 agent tests, a check) sent the
# load average to 74 and the gate of the slot 3599 spent its whole budget
# in the clippy phase. Fewer compilations, each one with more cores, is
# what shortens the total time: dividing the cores keeps the box from
# collapsing but does not shorten anything.
BUILD_TOKEN="$(bash "$ORCH_DIR/bin/build-slot.sh" --take --wait "${GATE_BUILD_SLOT_WAIT:-1800}")" || {
  echo "gate: no free build slot" >&2
  exit 1
}
# The token comes back with the gate, whatever happens.
trap 'bash "$ORCH_DIR/bin/build-slot.sh" --release "$BUILD_TOKEN" >/dev/null 2>&1 || true' EXIT

# The worktree of the slot: the change lives there.
WORKTREE="$HOME/solidcraft-wt/issue-$ISSUE"
if [ -d "$WORKTREE/.git" ] || [ -f "$WORKTREE/.git" ]; then
  export REPO="$WORKTREE"
else
  export REPO="$HOME/solidcraft"
  echo "gate.sh: no hay worktree para el slot $ISSUE: el gate corre en el checkout principal" >&2
fi

echo "gate.sh: target dir: $CARGO_TARGET_DIR" >&2
echo "gate.sh: repo:       $REPO" >&2

# The pull request of ours: from the branch of the worktree (the branch of
# the slot is the branch of the PR) or from the argument. The check of the
# claim needs it: our own pull request must not be read as the competitor
# that took the issue.
if [ -z "$OUR_PR" ] && { [ -d "$REPO/.git" ] || [ -f "$REPO/.git" ]; }; then
  _branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -n "$_branch" ] && [ "$_branch" != "HEAD" ]; then
    OUR_PR="$(gh pr list --repo tangency-labs/solidcraft --state open \
                --head "$_branch" --json number --jq '.[].number' 2>/dev/null | head -1)"
  fi
fi


# ---------------------------------------------------------------------------
# THE CLAIM IS CHECKED BEFORE THE GATE RUNS (31-10-2026).
#
# WHY: the bot applies the label 'in progress' with a DELAY, so between the
# survey of the issues and the opening of the draft, another agent can take
# the issue. When that happens, our pull request would have a HIGHER number
# than the one that took it and it would LOSE (the lowest-numbered open PR
# wins). The gate is the last step before publishing, so it is the last
# place where the loss can still be avoided.
#
# The gate is NOT started when the claim is already lost: a scoped gate
# compiles the whole touched scope (8+ minutes of the machine's CPU) and
# that time is thrown away with the work. The exit code is 4, the same one
# the publisher uses for an issue that is no longer open, so a caller can
# tell "the gate did not run" from "the gate ran and was red".
#
# The claim that CANNOT be read (GitHub did not answer) does not stop the
# gate: the gate is the work, and the brake that publishes decides on the
# claim for the last time. What it does is say it out loud, in the log of
# the slot, where the orchestrator reads it.
# ---------------------------------------------------------------------------
echo "gate.sh: slot=$ISSUE sha=$SHA base=$BASE our_pr=${OUR_PR:-none}" >&2

if [ -x "$ORCH_DIR/bin/claim-verify.sh" ] || [ -f "$ORCH_DIR/bin/claim-verify.sh" ]; then
  claim_args=("$ISSUE")
  [ -n "$OUR_PR" ] && claim_args+=("$OUR_PR")
  claim_out="$(bash "$ORCH_DIR/bin/claim-verify.sh" "${claim_args[@]}" 2>&1)"
  claim_rc=$?
  echo "gate.sh: claim: $(echo "$claim_out" | grep -E 'VEREDICTO' | head -1)" >&2
  if [ "$claim_rc" -eq 1 ]; then
    echo "gate.sh: ATENCION: el issue $ISSUE ya lo reclama otro PR (numero menor)." >&2
    echo "gate.sh: Si el PR nuestro tiene un numero MAYOR, pierde el claim: hay que cerrar el nuestro." >&2
    echo "gate.sh: $claim_out" >&2
    echo "gate.sh: el gate NO se corre: su trabajo ya no se publicaria." >&2
    exit 4
  elif [ "$claim_rc" -eq 2 ]; then
    echo "gate.sh: ATENCION: no se pudo verificar el claim de $ISSUE: el gate corre igual, pero el freno de publicar tiene que decidir." >&2
  fi
fi

# The phases of the gate (fmt, xtask layers, clippy, check, nextest) run in
# the WORKING DIRECTORY of the process, not in $REPO: the gate uses $REPO for
# the diff and for the metadata, but the cargo commands read the manifest of
# the directory they run in. So the gate has to be started FROM the worktree
# of the slot, otherwise every phase fails with "could not find Cargo.toml"
# and the verdict is a ROJO that says nothing about the change.
cd "$REPO" || exit 2

# The xtask is built BEFORE the gate, in the ci profile, in the target
# directory of the slot. The phase "cargo xtask layers" of the gate compiles
# it: on a cold target directory that is 22 crates and it eats the whole
# slice of the phase (2% of the budget) and the gate gives up before it
# reaches the tests. Here it is paid once, and every later gate of the slot
# finds it warm. It is a small crate: it costs less than the phase it saves.
if ! cargo build --profile ci --package xtask >/dev/null 2>&1; then
  echo "gate.sh: xtask no se pudo pre-calentar: la fase layers lo compilara en frio" >&2
fi

exec bash "$GATE_SCRIPT" --slot "$ISSUE" "$BASE" "$SHA"
