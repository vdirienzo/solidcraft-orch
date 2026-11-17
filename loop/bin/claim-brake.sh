#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# claim-brake.sh - THE BRAKE OF THE CLAIM: the script that decides if a pull
# request may be published, and that saves the work when the claim is gone.
#
# WHY THIS EXISTS (01-11-2026): the claim of an issue is a RACE and the
# upstream label loses it (the bot applies 'in progress' with a DELAY). We
# lost the work of four issues that way: the code was written, the gate ran,
# the draft was opened, and then another agent's pull request turned out to
# hold the claim. The rule was in a PROMPT ("re-verify the claim") and a
# prompt is remembered once in a while. A script is not.
#
# So the rule lives in ONE script (bin/claim-race.sh) and everything that
# publishes calls THIS brake, which asks the rule and then ACTS on the
# answer:
#
#   exit 0   OK        the claim is ours (or the issue is free): publish.
#   exit 10  TAKEN     somebody else holds the claim: our pull request LOST
#                      the race (or the issue was taken before we started).
#                      The work is SAVED (not thrown away) and the publish is
#                      REFUSED.
#   exit 11  RESOLVED  the issue is not open any more: it was closed or fixed
#                      by somebody else. NOBODY won a race against us: the
#                      work is MOOT for this issue, not lost. The publish is
#                      REFUSED and the work is SAVED (it can be re-targeted).
#   exit 12  UNKNOWN   GitHub could not be read: the guard does NOT know, and
#                      a publish without a check is a duplicate waiting to
#                      happen. The publish is REFUSED and the work is SAVED.
#
# The VERDICT of the rule (OK, TAKEN, LOST, RESOLVED, UNKNOWN) and its keys
# (REASON, HOLDER, HOLDER_AUTHOR, ...) are printed on STDOUT, one per line:
# the publisher reads them and says out loud WHO holds the claim.
#
# OPTIONS:
#   --issue N       the issue (required)
#   --pr P          our pull request: the race is decided against it
#   --mode M        selection | race | funnel | auto (the default). 'auto'
#                   picks the race when we have a pull request for the issue
#                   and the selection otherwise. 'selection' is the loose
#                   house rule (any open pull request of another author that
#                   mentions the issue, plus the RECORD of the issue: its
#                   assignees and its comments). 'race' is the rule of the
#                   upstream (the lowest numbered open pull request that
#                   claims the issue wins). 'funnel' is the question of the
#                   triage: may a NEW claim be made on this issue?
#   --work DIR      the worktree of the work (the patch is collected from it)
#   --branch NAME   the branch of the work
#   --base REF      the base of the diff (default: the remote main)
#   --out DIR       where the salvaged work goes (default: the logs of the
#                   loop)
#   --repo REPO     the repository of the issue and of the pull requests
#   --close         close our pull request when the claim is lost (the
#                   upstream asks for it: the lowest numbered pull request
#                   stays, the other one is closed)
#   --no-salvage    do not collect the work (the verdict alone)
#
# THE WORK IS NEVER DELETED: the branch, the worktree and the patch stay
# where they are. The salvage ADDS a copy of the work (the patch) and a note
# that says what happened and what can be done with it.
#
# THE EXIT CODES OF THE BRAKE ARE THE EXIT CODES OF THE RULE (0/10/11/12):
# the brake does not invent a vocabulary of its own, it only acts on the
# one of the rule. A caller that needs its OWN codes (the publisher, the
# orchestrator) translates them, and the translation is written down where
# it happens.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARBITER="$SCRIPT_DIR/claim-race.sh"
SALVAGE="$SCRIPT_DIR/claim-salvage.sh"

ISSUE=""
OUR_PR=""
MODE=""
WORK=""
BRANCH=""
BASE=""
OUT=""
GH_REPO=""
CLOSE=0
SALVAGE_IT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)   ISSUE="$2"; shift 2 ;;
    --pr)      OUR_PR="$2"; shift 2 ;;
    --mode)    MODE="$2"; shift 2 ;;
    --work)    WORK="$2"; shift 2 ;;
    --branch)  BRANCH="$2"; shift 2 ;;
    --base)    BASE="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    --repo)    GH_REPO="$2"; shift 2 ;;
    --close)   CLOSE=1; shift ;;
    --no-salvage) SALVAGE_IT=0; shift ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "claim-brake: unknown option: $1" >&2; exit 2 ;;
  esac
done
# The issue and the pull request can also come as plain arguments.
if [ -z "$ISSUE" ] && [ $# -gt 0 ]; then
  ISSUE="$1"; shift
  if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then OUR_PR="$1"; shift; fi
fi

if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "claim-brake: the issue has to be a number: '$ISSUE'" >&2
  exit 2
fi
if [ -n "$OUR_PR" ] && ! [[ "$OUR_PR" =~ ^[0-9]+$ ]]; then
  echo "claim-brake: our pull request has to be a number: '$OUR_PR'" >&2
  exit 2
fi
if [ ! -f "$ARBITER" ]; then
  echo "claim-brake: the rule is not there: $ARBITER" >&2
  exit 12
fi

say() { echo "claim-brake: $*" >&2; }

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
    echo "claim-brake: the config.env has a syntax error: $LOOP_DIR/config.env" >&2
    exit 2
  fi
fi

# The configuration of the loop: the rule (bin/claim-race.sh) reads the
# repository and the upstream from it, and so does this script for the
# salvage. Without it the rule asks GitHub about the wrong repository and
# the answer is "the issue does not exist" (a RESOLVED that is not true).
if [ -f "$LOOP_DIR/config.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$LOOP_DIR/config.env"
  set +a
fi

# The mode 'auto' is resolved HERE, before the rule is asked: the rule knows
# three questions ('selection', 'race' and 'funnel') and the caller often
# does not know which one it is asking. With a pull request of ours the
# question is the RACE (who won the claim of the issue); without one it is
# the SELECTION (may a new claim be made on this issue at all).
# The rule does NOT know 'auto': the resolution happens here.
if [ "$MODE" = "auto" ] || [ -z "$MODE" ]; then
  if [ -n "$OUR_PR" ]; then
    MODE="race"
  else
    MODE="selection"
  fi
fi

# The repository of GitHub where the claims live. The configuration of the
# loop names it SC_REPO or UPSTREAM ('owner/name'). The variable REPO of the
# configuration is the LOCAL path of the checkout, so it is not used here:
# passing it as the repository makes the rule ask GitHub about a repository
# that does not exist and the answer is "the issue does not exist".
GH_REPO="${GH_REPO:-${SC_REPO:-${UPSTREAM:-tangency-labs/solidcraft}}}"

# --- the rule --------------------------------------------------------------
# The rule prints its answer on STDOUT (KEY=VALUE) and its sentences on
# STDERR. The brake is the only one that knows what to DO with the answer.
ERRFILE="$(mktemp "${TMPDIR:-/tmp}/claim-brake.XXXXXX")"
cleanup() { rm -f "$ERRFILE"; }
trap cleanup EXIT

ANSWER=""
ARBITER_RC=0
ARBITER_ARGS=(--issue "$ISSUE")
[ -n "$OUR_PR" ] && ARBITER_ARGS+=(--pr "$OUR_PR")
[ -n "$MODE" ] && ARBITER_ARGS+=(--mode "$MODE")
[ -n "$GH_REPO" ] && ARBITER_ARGS+=(--repo "$GH_REPO")
ANSWER="$(bash "$ARBITER" "${ARBITER_ARGS[@]}" 2>"$ERRFILE" || ARBITER_RC=$?)"
cat "$ERRFILE" >&2

field() { printf '%s\n' "$ANSWER" | sed -n "s/^$1=//p" | head -1; }

VERDICT="$(field VERDICT)"
REASON="$(field REASON)"
HOLDER="$(field HOLDER)"
HOLDER_AUTHOR="$(field HOLDER_AUTHOR)"
HOLDER_LOGIN="$(field HOLDER_LOGIN)"
OURS_HOLDER="$(field OURS_HOLDER)"

if [ -z "$VERDICT" ]; then
  # The rule did not answer: it does NOT know. A publish without a check
  # is a duplicate waiting to happen.
  say "the rule did not answer (rc=$ARBITER_RC): the publish is REFUSED"
  exit 12
fi

# The answer of the rule, in its vocabulary: the publisher reads it.
printf '%s\n' "$ANSWER"

# --- the salvage ------------------------------------------------------------
# The work is collected BEFORE the refusal is said out loud: a refusal
# without the work saved is the loss of a day of work.
salvage() {
  local verdict="$1"
  [ "$SALVAGE_IT" -eq 1 ] || return 0
  if [ ! -f "$SALVAGE" ]; then
    say "there is no salvage script: $SALVAGE"
    return 1
  fi
  local args=(--issue "$ISSUE" --verdict "$verdict")
  [ -n "$OUR_PR" ] && args+=(--pr "$OUR_PR")
  [ -n "$HOLDER" ] && args+=(--holder "$HOLDER")
  [ -n "$HOLDER_AUTHOR" ] && args+=(--holder-author "$HOLDER_AUTHOR")
  [ -n "$HOLDER_LOGIN" ] && args+=(--holder-login "$HOLDER_LOGIN")
  [ -n "$WORK" ] && args+=(--work "$WORK")
  [ -n "$BRANCH" ] && args+=(--branch "$BRANCH")
  [ -n "$BASE" ] && args+=(--base "$BASE")
  [ -n "$OUT" ] && args+=(--out "$OUT")
  bash "$SALVAGE" "${args[@]}" 2>/dev/null
}

# The pull request to close: ours, if we know it, or our own open pull
# request for the issue (the one that the rule found).
close_ours() {
  [ "$CLOSE" -eq 1 ] || return 0
  local target="${OUR_PR:-$OURS_HOLDER}"
  [ -n "$target" ] || return 0
  local repo="${REPO:-${SC_REPO:-${UPSTREAM:-tangency-labs/solidcraft}}}"
  if gh pr close "$target" -R "$repo" --comment \
      "The claim of this issue is held by #${HOLDER:-?}${HOLDER_AUTHOR:+ ($HOLDER_AUTHOR)}, whose number is lower: the lowest-numbered open pull request wins. Closing this one; the work is not lost and can be re-targeted." \
      >/dev/null 2>&1; then
    say "our pull request #$target was closed (the lowest numbered one stays)"
  else
    say "our pull request #$target could NOT be closed: it has to be closed by hand"
  fi
}

case "$VERDICT" in
  OK)
    exit 0
    ;;
  TAKEN)
    say "the issue #$ISSUE is TAKEN${HOLDER:+ by the open pull request #$HOLDER}${HOLDER_LOGIN:+ by @$HOLDER_LOGIN}: the publish is REFUSED"
    salvage LOST >/dev/null
    exit 10
    ;;
  LOST)
    say "the claim of the issue #$ISSUE is LOST: the open pull request #$HOLDER holds it and its number is lower"
    salvage LOST >/dev/null
    close_ours
    exit 10
    ;;
  RESOLVED)
    say "the issue #$ISSUE is not open any more (${REASON}): the work is MOOT for this issue, not lost"
    salvage RESOLVED >/dev/null
    exit 11
    ;;
  *)
    say "the rule answered '$VERDICT': the guard does not know, so the publish is REFUSED"
    salvage UNKNOWN >/dev/null
    exit 12
    ;;
esac
