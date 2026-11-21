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
#   bash bin/gate.sh <issue> <sha> [base] [our_pr]
#
#   <issue>  the slot: the number of the issue (the branch and the lock)
#   <sha>    the commit to check
#   <base>   the base of the diff (default: origin/main)
#
# EXIT CODES:
#   0   the gate ran and the gate script said what it had to say
#   2   the usage is wrong, or the gate script of the loop is not there
#   4   the claim of the issue is LOST: the gate did not run
#   5   there is NO worktree of the slot: the gate did not run (2026-11-17)
#   7   the worktree is NOT the requested commit (its HEAD is another sha, or
#       it has uncommitted or untracked changes): the gate did not run
#       (2026-11-21)
#   *   the exit code of the gate (cargo xtask fast, or the gate script of the loop)
#
# THE LOCAL GATE IS NOT THE DEFAULT GATE ANYMORE (2026-11-21): the pipeline
# gates a pull request with upstream's CI run on the fork (bin/fork-ci.sh,
# GATE_MODE=fork-ci) and only enqueues this script with GATE_MODE=local. And
# what this script runs is upstream's own pre-push check, `cargo xtask fast
# --base <base>` (CONTRIBUTING.md: "Run cargo xtask fast before pushing ... CI
# runs the rest"), not our gate-quick.sh: gate-quick (nextest with
# --ignore-default-filter, SOLIDCRAFT_REQUIRE_GPU=1 and a baseline 18 days
# old) gave a FALSE red on PR #20017 while upstream's "Native Linux tests"
# passed on the same head. LOCAL_GATE=quick keeps the old gate for
# compatibility. The verdict of `fast` is written where the readers look for
# it ($LOOP_DIR/gates/<slot>/scope.verdict, VERDICT=VERDE-SCOPE|ROJO-SCOPE,
# MODE=xtask-fast).
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
# The gh of the machine, or the one of a test (the stub lives OUTSIDE the
# PATH: README rule 4). Without this the only way to test the script is a
# fake gh on the PATH, which is exactly what rule 4 forbids.
GH_BIN="${GH_BIN:-gh}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
# SOLIDCRAFT_REPO is NOT the fallback of the gate anymore (2026-11-17): the
# gate compiles the worktree of the slot or it does not run. It stays
# exported because the children of the gate resolve their own paths with it.
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

# WHICH LOCAL GATE (2026-11-21): fast = upstream's `cargo xtask fast` (the
# default), quick = the gate-quick.sh of the loop (the old one).
LOCAL_GATE="${LOCAL_GATE:-fast}"

if [ -z "$ISSUE" ] || [ -z "$SHA" ]; then
  echo "usage: bash bin/gate.sh <issue> <sha> [base] [our_pr]" >&2
  exit 2
fi
case "$LOCAL_GATE" in
  fast|quick) ;;
  *) echo "gate.sh: LOCAL_GATE=$LOCAL_GATE no es un gate (fast o quick)" >&2; exit 2 ;;
esac
case "$SHA" in
  *[!0-9a-fA-F]*) echo "gate.sh: el sha '$SHA' no es un sha" >&2; exit 2 ;;
esac
if [ "$LOCAL_GATE" = "quick" ] && [ ! -x "$GATE_SCRIPT" ] && [ ! -f "$GATE_SCRIPT" ]; then
  echo "gate.sh: the gate script is not there: $GATE_SCRIPT" >&2
  exit 2
fi

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

# ---------------------------------------------------------------------------
# THE WORKTREE OF THE SLOT (2026-11-17): no worktree, no gate.
#
# WHY: the gate compiles the change it has to judge, and the change lives in
# the worktree of the slot. When the worktree was not there, the gate fell
# back to the MAIN CHECKOUT: it compiled a tree WITHOUT the change, it wrote
# the verdict of that tree, and bin/verify-pr.sh read that verdict as "the
# gate of this pull request" and accepted it. A verdict that describes
# another tree is WORSE than no verdict at all.
#
# So the gate FAILS when the worktree of the slot is not there, and the
# message says WHERE it expected it (the path), not a generic phrase. The
# same happens when the directory is there but it is not a checkout of git:
# there is nothing to judge.
#
# THE CHECK IS BEFORE THE BUILD TOKEN: the token can wait 30 minutes for a
# free slot, and there is no point in waiting for it when there is nothing
# to compile.
#
# EXIT CODE 5: the worktree of the slot is not there (the gate did not run).
# ---------------------------------------------------------------------------
WORKTREE=""
# The worktree of the slot lives in ONE of two places, and which one depends
# on who made it: the orchestrator's own slots use $WORKTREES_DIR, and the
# publisher (agent-issue.sh, in the loop) uses $LOOP_DIR/work. Before this
# check, the gate fell back to the main checkout when it found neither - and
# compiled a tree that did NOT contain the change, then wrote a verdict that
# read as if it did.
for candidate in "$WORKTREES_DIR/issue-$ISSUE" "$LOOP_DIR/work/issue-$ISSUE"; do
  if [ -d "$candidate/.git" ] || [ -f "$candidate/.git" ]; then
    WORKTREE="$candidate"
    break
  fi
done
if [ -z "$WORKTREE" ]; then
  echo "gate.sh: no hay worktree del slot $ISSUE: se esperaba uno de estos dos" >&2
  echo "gate.sh:   $WORKTREES_DIR/issue-$ISSUE" >&2
  echo "gate.sh:   $LOOP_DIR/work/issue-$ISSUE" >&2
  echo "gate.sh: el gate NO corre: un veredicto del checkout principal no describe este cambio." >&2
  exit 5
fi
export REPO="$WORKTREE"

# ---------------------------------------------------------------------------
# THE TREE THAT IS JUDGED IS THE REQUESTED COMMIT (2026-11-21).
#
# WHY: the gate compiles the WORKING TREE of the worktree and writes a verdict
# that names the SHA it was GIVEN. When the agent had pushed another commit
# since, or had edits that were not committed, the verdict said "VERDE for
# <sha>" about a tree that was not <sha>, and the pipeline promoted <sha> with
# it. So the HEAD of the worktree has to BE the requested commit and the tree
# has to be clean (no change and no untracked file: `cargo xtask fast` reads
# uncommitted and untracked files too), or the gate does not run.
#
# THE CHECK IS BEFORE THE BUILD TOKEN, like the one of the worktree: there is
# no point in waiting for a token to compile the wrong tree. EXIT CODE 7.
# ---------------------------------------------------------------------------
WT_HEAD="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)"
if ! same_sha "$WT_HEAD" "$SHA"; then
  echo "gate.sh: el worktree $WORKTREE esta en ${WT_HEAD:-un HEAD que no se pudo leer}, NO en $SHA" >&2
  echo "gate.sh: el gate NO corre: su veredicto nombraria $SHA y describiria otro arbol." >&2
  exit 7
fi
WT_DIRTY="$(git -C "$WORKTREE" status --porcelain --untracked-files=normal 2>/dev/null | head -20)"
if [ -n "$WT_DIRTY" ]; then
  echo "gate.sh: el worktree $WORKTREE tiene cambios sin commitear (o archivos sin seguimiento):" >&2
  printf '%s\n' "$WT_DIRTY" | sed 's/^/gate.sh:   /' >&2
  echo "gate.sh: el gate NO corre: el arbol no es el commit $SHA." >&2
  exit 7
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
# A gate killed with a signal ALSO gives the token back (the EXIT trap alone
# does not run when bash dies of a SIGTERM): without this the box answered
# "no free build slot" until the token aged out, and no gate could run.
trap 'bash "$ORCH_DIR/bin/build-slot.sh" --release "$BUILD_TOKEN" >/dev/null 2>&1 || true; exit 143' TERM
trap 'bash "$ORCH_DIR/bin/build-slot.sh" --release "$BUILD_TOKEN" >/dev/null 2>&1 || true; exit 130' INT

# The worktree of the slot was resolved (and CHECKED) above: the gate runs in
# the worktree of the slot, never in the main checkout.

echo "gate.sh: target dir: $CARGO_TARGET_DIR" >&2
echo "gate.sh: repo:       $REPO" >&2

# The pull request of ours: from the branch of the worktree (the branch of
# the slot is the branch of the PR) or from the argument. The check of the
# claim needs it: our own pull request must not be read as the competitor
# that took the issue.
if [ -z "$OUR_PR" ] && { [ -d "$REPO/.git" ] || [ -f "$REPO/.git" ]; }; then
  _branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -n "$_branch" ] && [ "$_branch" != "HEAD" ]; then
    OUR_PR="$("$GH_BIN" pr list --repo tangency-labs/solidcraft --state open \
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

# ---------------------------------------------------------------------------
# THE DEFAULT LOCAL GATE: upstream's `cargo xtask fast` (2026-11-21).
#
# It checks what the change touches against <base> (fmt, the quick checks of
# ci, workspace clippy and the tests of the packages whose files changed) and
# lists every failing step at the end ("fast: <step> failed: ..."). It is the
# check CONTRIBUTING.md asks for before a push, so its verdict is the one
# upstream's CI is going to agree with; gate-quick.sh was ours and it was the
# one that cried wolf (PR #20017).
#
# `fast` FORMATS the tree (cargo fmt writes): a commit that was not formatted
# comes out of it with modified files. That is a RED (upstream's fmt --check
# fails on that commit), and the tracked files are put back as they were (the
# tree was clean before, so every change is the gate's own): the worktree is
# the agent's, and a gate does not leave edits in it. A NEW untracked file is
# named and left alone (deleting files is not the gate's business).
# ---------------------------------------------------------------------------
if [ "$LOCAL_GATE" = "fast" ]; then
  SLOT_REAL="$(basename "${CARGO_TARGET_DIR:-slot-$ISSUE}")"
  SLOT_REAL="${SLOT_REAL#slot-}"
  GDIR="$LOOP_DIR/gates/$SLOT_REAL"
  mkdir -p "$GDIR" || exit 2
  FAST_LOG="$GDIR/fast.log"
  # The base has to be the one of today: with a stale origin/main the diff
  # also carries what upstream merged since, and fast tests packages that the
  # change never touched. A fetch that fails does not stop the gate.
  case "$BASE" in
    origin/*)
      timeout 180 git -C "$REPO" fetch -q origin "${BASE#origin/}" 2>/dev/null \
        || echo "gate.sh: no pude actualizar $BASE: el gate compara contra el que hay" >&2 ;;
  esac
  echo "gate.sh: corro cargo xtask fast --base $BASE (log: $FAST_LOG)" >&2
  START_S="$(date +%s)"
  nice -n 19 cargo xtask fast --base "$BASE" > "$FAST_LOG" 2>&1
  GATE_RC=$?
  DURATION_S=$(( $(date +%s) - START_S ))
  FAILED_STEPS="$(sed -nE 's/^fast: (.+) failed: .*$/\1/p' "$FAST_LOG" | sort -u | paste -sd, -)"
  CHANGED="$(git -C "$REPO" status --porcelain --untracked-files=normal 2>/dev/null)"
  CHECKS="fast:$([ "$GATE_RC" -eq 0 ] && echo ok || echo fail)"
  if [ -n "$CHANGED" ]; then
    echo "gate.sh: cargo xtask fast cambio el arbol (el commit no estaba formateado):" >&2
    printf '%s\n' "$CHANGED" | head -20 | sed 's/^/gate.sh:   /' >&2
    git -C "$REPO" checkout -q -- . 2>/dev/null \
      || echo "gate.sh: no pude devolver los archivos del worktree a $SHA" >&2
    CHECKS="$CHECKS|tree:changed"
    FAILED_STEPS="${FAILED_STEPS:+$FAILED_STEPS,}el arbol cambio (fmt)"
    [ "$GATE_RC" -eq 0 ] && GATE_RC=1
  fi
  if [ "$GATE_RC" -eq 0 ]; then
    VERDICT_FAST="VERDE-SCOPE"
    NEW_FAST=0
  else
    VERDICT_FAST="ROJO-SCOPE"
    # NEVER 0 on a red: a reader that sees GATE_STATUS=finished with no new
    # failure would take the red for a green.
    NEW_FAST="$(printf '%s' "$FAILED_STEPS" | tr ',' '\n' | grep -c . || true)"
    [ "${NEW_FAST:-0}" -ge 1 ] 2>/dev/null || NEW_FAST=1
  fi
  {
    echo "GATE_STATUS=finished"
    echo "MODE=xtask-fast"
    echo "VERDICT=$VERDICT_FAST"
    echo "NEW_FAILURES=$NEW_FAST"
    echo "FAILED_TESTS="
    echo "FAILED_STEPS=$FAILED_STEPS"
    echo "CHECKS=$CHECKS"
    echo "SHA=$SHA"
    echo "HEAD_SHA=$WT_HEAD"
    echo "BASE=$BASE"
    echo "AT=$(date +%s)"
    echo "DURATION_S=$DURATION_S"
    echo "LOG=$FAST_LOG"
  } > "$GDIR/scope.verdict.tmp" && mv -f "$GDIR/scope.verdict.tmp" "$GDIR/scope.verdict"
  # The effective verdict of a previous gate-quick run is about ANOTHER
  # commit and another gate: it goes away. gate-baseline.sh rewrites it from
  # this verdict when somebody asks (a fast verdict names no test, so there
  # is nothing to discount).
  rm -f "$GDIR/scope.effective.verdict"
  echo "gate.sh: VERDICT=$VERDICT_FAST NEW_FAILURES=$NEW_FAST${FAILED_STEPS:+ FAILED_STEPS=$FAILED_STEPS} (${DURATION_S}s)" >&2
  tail -n 5 "$FAST_LOG" | sed 's/^/gate.sh: fast: /' >&2
  exit $GATE_RC
fi

# LOCAL_GATE=quick: the gate-quick.sh of the loop, as before.
#
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

# (same_sha is defined at the top: the check of the worktree uses it too.)

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
