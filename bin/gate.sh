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

# The PATH of cargo (2026-11-06): this script is launched by gate-queue.sh
# under `systemd-run --user --scope`, and a systemd unit does NOT read
# ~/.bashrc nor the login PATH. Without this, `cargo metadata` inside
# scripts/ci/affected.py fails with FileNotFoundError: 'cargo' and the gate
# ends with GATE_STATUS=failed VERDICT=SKIP without compiling anything.
export PATH="$HOME/.cargo/bin:$HOME/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# The paths come from the environment, with the default of THIS
# machine: the other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
GATE_SCRIPT="$LOOP_DIR/bin/gate-quick.sh"
# The gate and the baseline have to look at the SAME gates directory (the
# one of this slot) and the SAME orchestrator: the paths are exported so the
# two children resolve the same directories this script resolved. On the
# other PC they come from the environment, and this keeps them in one place.
export ORCH_DIR LOOP_DIR SOLIDCRAFT_REPO WORKTREES_DIR

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
WORKTREE="$WORKTREES_DIR/issue-$ISSUE"
if [ -d "$WORKTREE/.git" ] || [ -f "$WORKTREE/.git" ]; then
  export REPO="$WORKTREE"
else
  export REPO="$SOLIDCRAFT_REPO"
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

# El duplicado por PARCHE (11-11-2026).
#
# WHY: claim-verify.sh (y el Duplicate PR check del upstream) buscan solo el
# verbo de cierre (Fixes/Closes/Resolves #N). Un competidor que describe el
# fallo en prosa, sin el verbo, es INVISIBLE para los dos: asi nos paso con
# el PR #14822, duplicado byte a byte del #14811 de otro autor, que el guard
# dio por nuestro ("VEREDICTO=OCUPADO el PR #14822 ya reclama #14801")
# cuando el rival era el nuestro. El PR perdedor no se mergea nunca.
#
# Este check razona sobre el parche: si otro PR abierto agrega las MISMAS
# lineas que el nuestro, compiten por el mismo merge. No mira el issue, asi
# que no le escapa el competidor que no nombra el issue.
#
# Es un AVISO, no una parada: el gate es el trabajo y el freno de publicar
# vuelve a mirar antes de abrir el PR. Un rc=2 (no se pudo verificar) no
# detiene nada.
if [ -f "$ORCH_DIR/bin/dup-scan.sh" ] && [ -n "${OUR_PR:-}" ]; then
  dup_out="$(SC_OUR_PR="$OUR_PR" SC_WORKTREE="$REPO" \
               bash "$ORCH_DIR/bin/dup-scan.sh" "$ISSUE" "$SHA" 2>&1)"
  dup_rc=$?
  echo "gate.sh: duplicado: $(echo "$dup_out" | tail -3 | tr '\n' ' ')" >&2
  if [ "$dup_rc" -eq 1 ]; then
    echo "gate.sh: ATENCION: hay un PR abierto que replica NUESTRO parche." >&2
    echo "gate.sh: $dup_out" >&2
    echo "gate.sh: el numero mas bajo gana. Si el nuestro es el mayor, hay que cerrarlo." >&2
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

# NOT `exec` (2026-11-06): `exec bash "$GATE_SCRIPT"` REPLACES this shell, so
# the EXIT trap that gives the build token back NEVER RUNS. Every gate that
# ended that way left its token on the machine, and after two gates the whole
# build queue was blocked by tokens whose owner was dead. The gate is run as
# a child and this script exits with its code, so the trap fires and the
# token comes back whatever happens.
bash "$GATE_SCRIPT" --slot "$ISSUE" "$BASE" "$SHA"
GATE_RC=$?

# ---------------------------------------------------------------------------
# THE EFFECTIVE VERDICT (2026-11-07).
#
# The gate leaves the RAW verdict (scope.verdict) and NOTHING wrote the
# EFFECTIVE one (scope.effective.verdict): the raw one counts EVERY failure
# of the scope, including the ones that origin/main already had broken, so
# every pull request of ours came out ROJO for reasons that have nothing to
# do with the change, and the pipeline (and the daily report) read that raw
# verdict. gate-baseline.sh writes the effective one next to the raw one
# (the raw one minus the failures that were already failing in origin/main)
# and it is the one that counts. It is called HERE, at the end of the gate,
# because the gate is the thing that knows that the slot has a verdict.
#
# THE NAME OF THE SLOT: gate-quick.sh normalizes the name before it writes
# the verdict (lowercase, [a-z0-9._-], 60 characters at most), so the
# verdict is in $LOOP_DIR/gates/<nombre normalizado>/scope.verdict and NOT
# in gates/<$ISSUE>/. The normalized name is taken from the target
# directory of the slot, which is <base>/slot-<nombre normalizado>: the
# same rule, in the same helper (slot-target-dir.sh).
# ---------------------------------------------------------------------------
SLOT_REAL="$(basename "${CARGO_TARGET_DIR:-}")"
SLOT_REAL="${SLOT_REAL#slot-}"

# Two SHAs are the same commit when one is the prefix of the other: the
# gate writes the SHA it was given and the queue can carry an abbreviated
# one. A SHA that is a prefix of another is NOT the same commit (a SHA of
# 7 characters is a prefix of MANY commits), so only the long one can
# match the short one.
same_sha() {
  local a="${1:-}" b="${2:-}"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  case "$a" in "$b"*) [ ${#b} -ge 7 ] && return 0 ;; esac
  case "$b" in "$a"*) [ ${#a} -ge 7 ] && return 0 ;; esac
  return 1
}

# The effective verdict is only written for the verdict of THIS run: the
# raw file of the slot can be the one of a previous run (the gate that
# died before writing its own leaves the old one there), and the effective
# verdict of ANOTHER commit is worse than none.
verdict_is_ours() {
  local f="$1" sha
  [ -f "$f" ] || return 1
  sha="$(grep -E '^SHA=' "$f" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')"
  same_sha "$sha" "$SHA"
}

RAW_VERDICT="$LOOP_DIR/gates/$SLOT_REAL/scope.verdict"
if ! verdict_is_ours "$RAW_VERDICT"; then
  # The name did not hold our commit: the gate wrote its verdict
  # somewhere else (the normalization of the loop changed). The verdict
  # is looked up by the SHA of this run, which is what the pipeline does
  # too. The lookup only accepts a UNIQUE match: with two slots of the
  # same commit, picking one of them at random would leave the other one
  # without an effective verdict.
  SLOT_REAL=""
  for _cand in "$LOOP_DIR"/gates/*/scope.verdict; do
    [ -f "$_cand" ] || continue
    verdict_is_ours "$_cand" || continue
    if [ -n "$SLOT_REAL" ]; then
      SLOT_REAL=""
      break
    fi
    SLOT_REAL="$(basename "$(dirname "$_cand")")"
  done
  [ -n "$SLOT_REAL" ] && echo "gate.sh: el veredicto de $SHA esta en el slot '$SLOT_REAL'" >&2
fi

if [ -n "$SLOT_REAL" ]; then
  # gate-baseline.sh decides what the effective verdict is: a DEFERRED
  # scope (DEFERRED=) or a SKIP has NO effective verdict (and the one of
  # a previous run is removed), and a failure of the baseline does not
  # break the gate: the gate already said what it had to say.
  bash "$ORCH_DIR/bin/gate-baseline.sh" "$SLOT_REAL" >/dev/null 2>&1 || true
fi

# The exit code of the GATE is the exit code of this script (the trap of
# the build token runs on the way out, whatever it is).
exit $GATE_RC
