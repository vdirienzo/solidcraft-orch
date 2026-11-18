#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# claim-race.sh - THE SHIM OF THE RULE OF THE CLAIM.
#
# WHAT THIS IS: an ADAPTER. The rule of the claim lives in ONE place, the
# arbiter of this repo (bin/claim-verify.sh), and this script only speaks its
# language. Before, this file WAS the rule: 780 lines of arbitration of its
# own, a copy of the logic of the arbiter, and a second answer to the same
# question. Two answers to the same question is how a duplicated pull request
# happens: the rule of the loop was blind to 193 rival pull requests that name
# the issue in the TITLE (the rule of the upstream), so it said "free" about
# an issue that was held (B6 of reports/loop-codigo.md).
#
# WHY THE ARBITER OF THE REPO WINS: it is the one that implements the UNION
# of the two rules of the upstream (the title that names the issue, and the
# body that closes it), with the noise out, the references to another
# repository out and the pull request's own number out. And it does not make
# OUR OWN pull requests compete with us (the rule of the same author), so a
# second pull request of ours does not lose against the first one.
#
# THE CONTRACT OF THIS FILE (the one of the rule of the LOOP, kept EXACTLY):
# the callers are bin/claim-brake.sh (the brake of the publisher
# bin/agent-issue.sh), bin/claim-free.sh and bin/claim-guard.sh. They read
# the answer on STDOUT, one KEY=VALUE per line, and they read the exit code.
#
#   VERDICT=OK|TAKEN|LOST|UNKNOWN
#   REASON=<slug>
#   ISSUE=<n>
#   OURS=<pr>                (the pull request the race is decided against)
#   HOLDER=<pr>              (the pull request that holds the claim)
#   HOLDER_AUTHOR=<login>
#   HOLDER_OURS=yes|no
#   HOLDER_CLAIMS=yes|no
#   OURS_HOLDER=<pr>         (our own pull request for this issue)
#
#   exit 0   OK        the claim is ours, or the issue is free
#   exit 10  TAKEN     somebody else holds the claim (TAKEN or LOST)
#   exit 12  UNKNOWN   it could NOT be verified: the guard does NOT know
#   exit 2   usage error
#
# THE TRANSLATION OF THE EXIT CODE (the arbiter speaks 0/1/2, this file
# speaks 0/10/12):
#
#   arbiter 0  ->  0   the claim is ours, or the issue is free
#   arbiter 1  ->  10  somebody else holds the claim (TAKEN or LOST)
#   arbiter 2  ->  12  it could not be verified (UNKNOWN)
#
# THE CASE 11 (RESOLVED) IS NOT PRODUCED HERE, ON PURPOSE: the arbiter does
# not read the state of the issue, and neither does this shim. The verdict
# "the issue is not OPEN any more" belongs to the check that the PUBLISHER
# already does ("is the issue open?"), not to the arbitration of the claim.
# The shim never answers 11; it answers 0, 10 or 12, and the brake maps them
# exactly like this.
#
# WHAT THIS SHIM DOES NOT DO (and the rule of the loop used to). These are
# the THREE gaps of the change, and each one is a question that is NOT the
# claim:
#
#   * it does not read the RECORD of the issue (its labels, its assignees,
#     the comments of the bot): the arbiter does not either, so a label
#     'in progress' or an assignee is NOT a claim here. The arbiter is the
#     rule of the upstream; the record of the issue is the proof that the
#     upstream bot left, and it is applied with a DELAY. It is also STALE:
#     when the pull request of the claim is merged, the upstream RELEASES the
#     claim (the sweep of scripts/claim/claim.js) but the label stays, and
#     the old rule kept refusing an issue whose claim was already free.
#   * it does not produce the RESOLVED verdict for an issue that is CLOSED,
#     for an EXCLUDED label ('area:kernel', 'needs-info', ...) or for an
#     issue that does not exist. The verdict "the issue is not OPEN any
#     more" belongs to the check that the PUBLISHER already does ("is the
#     issue open?"), not to the arbitration of the claim. The excluded
#     labels are the FUNNEL of the loop (the policy of config.env,
#     CLAIM_EXCLUDED_LABELS), and the funnel is decided where the issues
#     are PICKED, not where a claim is arbitrated.
#   * the MODE (selection|race|funnel) is accepted for the callers that pass
#     it, and it says which QUESTION is asked: the funnel ("may a new claim
#     be made on this issue?"), the selection (the same question, seen from
#     the record of the issue) or the race ("did our own pull request win
#     the race?"). The arbiter has ONE rule and it arbitrates the claim in
#     the three of them; what the mode changes is the pull request of ours
#     that is being published (in the funnel it is excluded only when it is
#     really ours) and whether the TIMELINE of the issue holds the claim
#     on its own (in the race the answer is the one of the arbiter).
# ---------------------------------------------------------------------------
set -uo pipefail

# The convention of the paths of the repo: every script that uses a path
# takes it from the environment with a default, so the repo can be cloned
# anywhere. ORCH_DIR is the repo of the orchestrator (the arbiter lives in
# its bin/); LOOP_DIR is the half of the orchestrator that is not in git.
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR="."

usage() {
  cat <<'USAGE'
uso: bash bin/claim-race.sh <issue> [our_pr]
     bash bin/claim-race.sh --issue N [--pr P] [--mode selection|race|funnel]
                            [--repo R]

El shim de la regla del claim: la regla vive en bin/claim-verify.sh (el
arbitro de este repo) y este script traduce su veredicto y su exit code.

  VERDICT=OK|TAKEN|LOST|UNKNOWN   REASON=<slug>   ISSUE=<n>
  OURS=<pr>   HOLDER=<pr>   HOLDER_AUTHOR=<login>   OURS_HOLDER=<pr>

  exit 0   OK       el reclamo es nuestro, o el issue esta libre
  exit 10  TAKEN    lo tiene otro PR (TAKEN o LOST)
  exit 12  UNKNOWN  no se pudo verificar
  exit 2   uso incorrecto
USAGE
}

# --- the arbiter ------------------------------------------------------------
# It is found RELATIVE TO THIS SCRIPT first, so that a clone of the repo uses
# its own arbiter and not the one installed on the machine; the copy of
# ORCH_DIR is the fallback for the deployment in $LOOP_DIR, where this script
# lives alone in a bin/ that has no arbiter next to it.
find_arbiter() {
  local candidate
  for candidate in \
      "${CLAIM_VERIFY:-}" \
      "$SCRIPT_DIR/../../bin/claim-verify.sh" \
      "$SCRIPT_DIR/../bin/claim-verify.sh" \
      "$ORCH_DIR/bin/claim-verify.sh"
  do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# --- the configuration of the loop -------------------------------------------
# config.env is read, NOT sourced: a value with a space in it is a value, not
# a command. The environment is the second source.
#
# The INLINE COMMENT is cut ("2000            # cuantos PRs"): a value with a
# comment in it is not a number, and a number with a comment in it makes gh
# fail with an option it does not know. That is what the rule of the loop
# did (read_config, in python).
cfg_get() {
  local key="$1" file="$2" line value
  [ -r "$file" ] || return 0
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n 1)" || true
  [ -n "$line" ] || return 0
  line="${line#export }"
  value="${line#*=}"
  value="${value%%$'\n'*}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
    *) value="${value%% #*}"; value="${value%"${value##*[![:space:]]}"}" ;;
  esac
  printf '%s\n' "$value"
}

# --- the arguments ----------------------------------------------------------
ISSUE=""
OUR_PR=""
MODE=""
REPO_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      [ $# -ge 2 ] || { echo "claim-race: --issue necesita un numero" >&2; exit 2; }
      ISSUE="$2"; shift 2 ;;
    --pr|--our-pr)
      [ $# -ge 2 ] || { echo "claim-race: --pr necesita un numero" >&2; exit 2; }
      OUR_PR="$2"; shift 2 ;;
    --mode)
      [ $# -ge 2 ] || { echo "claim-race: --mode necesita un modo" >&2; exit 2; }
      MODE="$2"; shift 2 ;;
    --repo)
      [ $# -ge 2 ] || { echo "claim-race: --repo necesita owner/nombre" >&2; exit 2; }
      REPO_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      usage
      exit 0 ;;
    --*)
      echo "claim-race: unknown option: $1" >&2
      exit 2 ;;
    *)
      if [ -z "$ISSUE" ]; then ISSUE="$1"; shift
      elif [ -z "$OUR_PR" ]; then OUR_PR="$1"; shift
      else echo "claim-race: too many arguments: $1" >&2; exit 2
      fi ;;
  esac
done

if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "claim-race: the issue has to be a number: '$ISSUE'" >&2
  exit 2
fi
if [ -n "$OUR_PR" ] && ! [[ "$OUR_PR" =~ ^[0-9]+$ ]]; then
  echo "claim-race: our pull request has to be a number: '$OUR_PR'" >&2
  exit 2
fi
case "$MODE" in
  ""|selection|race|funnel|auto) ;;
  *) echo "claim-race: the mode has to be selection, race or funnel: '$MODE'" >&2; exit 2 ;;
esac

# The MODE that decides the QUESTION that is asked:
#   funnel     the triage: may a NEW claim be made on this issue?
#   selection  the same question, seen from the record of the issue
#   race       did our own pull request win the race of the issue?
# 'auto' (and the mode that is not given) is resolved here: the race when
# we have a pull request of our own and the selection otherwise. The brake
# resolves it the same way before it asks.
EFFECTIVE_MODE="$MODE"
case "$EFFECTIVE_MODE" in
  ""|auto)
    if [ -n "$OUR_PR" ]; then EFFECTIVE_MODE="race"; else EFFECTIVE_MODE="selection"; fi
    ;;
esac

# --- the repository where the claims live -----------------------------------
# The order is the one of the rule of the loop: the --repo of the caller
# wins; then SC_REPO and UPSTREAM of the config.env of the loop; then the
# same names of the environment; then the upstream.
REPO=""
for candidate in "$REPO_OVERRIDE" \
                 "$(cfg_get SC_REPO "$LOOP_DIR/config.env")" \
                 "${SC_REPO:-}" \
                 "$(cfg_get UPSTREAM "$LOOP_DIR/config.env")" \
                 "${UPSTREAM:-}"; do
  if [ -n "$candidate" ]; then REPO="$candidate"; break; fi
done
REPO="${REPO:-tangency-labs/solidcraft}"

# The limit of the list of pull requests: the arbiter reads 2000 by default
# (the upstream has more than 1000 open pull requests and with 1000 the guard
# went blind). The config.env of the loop can tighten it; it is not lowered
# here on purpose.
PR_LIMIT="$(cfg_get SC_PR_LIMIT "$LOOP_DIR/config.env")"
[ -n "$PR_LIMIT" ] || PR_LIMIT="${SC_PR_LIMIT:-}"
[ -n "$PR_LIMIT" ] || PR_LIMIT="$(cfg_get CLAIM_PR_LIMIT "$LOOP_DIR/config.env")"
[ -n "$PR_LIMIT" ] || PR_LIMIT="${CLAIM_PR_LIMIT:-}"
# The default is the one of the arbiter (2000): the list that the shim
# reads and the list that the arbiter reads are the SAME list, and a
# truncation is measured against the limit of that list.
[ -n "$PR_LIMIT" ] || PR_LIMIT="2000"
case "$PR_LIMIT" in
  ''|*[!0-9]*) PR_LIMIT="2000" ;;
esac

# Who we are: the arbiter needs it to apply the rule of the same author. It
# resolves it on its own (the environment, then the config.env of the loop,
# then the authenticated user of gh), but it is resolved HERE too so that the
# HOLDER_OURS of the answer is true, and it is resolved in the SAME order:
# the environment first, then the config.env of the loop.
FORK_OWNER="${FORK_OWNER:-}"
[ -n "$FORK_OWNER" ] || FORK_OWNER="$(cfg_get FORK_OWNER "$LOOP_DIR/config.env")"

# --- the record of the issue ------------------------------------------------
#
# WHY THE SHIM READS THE ISSUE ITSELF (2026-11-18): the arbiter decides WHO
# holds the claim. It does not decide whether the issue is still worth
# working on: that is the funnel, and the funnel is the guard's rule.
#
# The original rule (the one this shim replaced) answered RESOLVED for three
# cases that the arbiter does not know about:
#   - the issue does not exist (404): there is nothing to work on.
#   - the issue is CLOSED: the work is moot.
#   - the issue carries an excluded label (kernel-paused, needs-info,
#     status:decision, area:kernel): the work would be thrown away.
# The guard of the loop reads those three answers (exit 2 for the excluded
# label, exit 4 for the closed issue, and the "unknown" for a GitHub that
# does not answer). Without them the shim said OK for an issue that was
# closed, and the guard took it.
#
# The labels come from the config.env of the loop, in the same order and
# with the same default as the original rule read them.
EXCLUDED_LABELS="$(cfg_get CLAIM_EXCLUDED_LABELS "$LOOP_DIR/config.env")"
[ -n "$EXCLUDED_LABELS" ] || EXCLUDED_LABELS="in progress,kernel-paused,status:decision,needs-info,area:kernel"

# --- the working directory of the shim ---------------------------------------
# The files of the work (the record of the issue, the list of the open pull
# requests, the timeline, the answer of the arbiter) live in a directory of
# their own that is removed when the shim ends, whatever the verdict is.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/claim-race.XXXXXX")" || exit 12
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ISSUE_RECORD="$WORK/issue.json"
ISSUE_ERR="$WORK/issue.err"

# --- the gh of the arbiter: one that HONORS --jq ---------------------------
#
# WHY (2026-11-18): the arbiter asks gh for the list of the open pull
# requests FILTERED: the filter IS the rule of the claim (the title that
# names the issue and the body that closes it). A gh that IGNORES the
# filter answers with the raw JSON, the arbiter reads the digits of that
# JSON as numbers of pull requests and the rule says TAKEN for an issue
# that is FREE (and UNKNOWN for an issue that nobody holds).
#
# The gh of the machine honors the filter. This WRAPPER makes the rule
# work with a gh that does not (a stub of the tests, an old version): it
# applies the SAME program that the arbiter asked for, so the rule of the
# claim is NOT written twice and the arbiter stays the only one that says
# who holds the claim.
GH_REAL="$(command -v gh 2>/dev/null || true)"
GH_CMD="gh"
if [ -n "$GH_REAL" ]; then
  GH_CMD="$WORK/gh"
  cat >"$GH_CMD" <<'WRAPPER'
#!/usr/bin/env bash
# A gh that HONORS --jq, even when the gh of the machine does not.
set -uo pipefail
REAL_GH="${CLAIM_GH_REAL:?}"
filter=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then filter="$a"; fi
  case "$a" in --jq=*) filter="${a#--jq=}" ;; esac
  prev="$a"
done
out="$("$REAL_GH" "$@")"
rc=$?
# The answer is JSON: the gh ignored the filter and the program is
# applied HERE, with the same program the caller asked for.
if [ -n "$filter" ] && [ -n "$out" ]; then
  case "$out" in
    "["*|"{"*)
      if command -v jq >/dev/null 2>&1; then
        filtered="$(printf '%s' "$out" | jq -r "$filter" 2>/dev/null)"
        if [ $? -eq 0 ]; then
          printf '%s\n' "$filtered"
          exit "$rc"
        fi
      fi
      ;;
  esac
fi
printf '%s\n' "$out"
exit "$rc"
WRAPPER
  chmod +x "$GH_CMD"
  export CLAIM_GH_REAL="$GH_REAL"
  # The arbiter asks ITS gh (GH_BIN): it is the wrapper.
  export GH_BIN="$GH_CMD"
fi

read_issue_record() {
  "$GH_CMD" issue view "$ISSUE" --repo "$REPO" \
     --json number,state,stateReason,labels,assignees,comments >"$ISSUE_RECORD" 2>"$ISSUE_ERR"
}

emit_resolved() {
  # emit_resolved <reason> [<state>]
  printf 'VERDICT=RESOLVED\n'
  printf 'REASON=%s\n' "$1"
  printf 'ISSUE=%s\n' "$ISSUE"
  [ -n "${2:-}" ] && printf 'ISSUE_STATE=%s\n' "$2"
  rm -f "$ISSUE_RECORD" "$ISSUE_ERR"
  exit 11
}

emit_unknown() {
  printf 'VERDICT=UNKNOWN\n'
  printf 'REASON=%s\n' "${1:-unknown-github}"
  printf 'ISSUE=%s\n' "$ISSUE"
  rm -f "$ISSUE_RECORD" "$ISSUE_ERR"
  exit 12
}

if ! read_issue_record; then
  # An issue that does not exist is not ignorance, it is a fact: there is
  # nothing to work on. A network that does not answer IS ignorance.
  if grep -qiE "404|not found|could not resolve" "$ISSUE_ERR" 2>/dev/null; then
    emit_resolved "issue-not-found" "CLOSED"
  fi
  emit_unknown "unknown-github"
fi

if [ ! -s "$ISSUE_RECORD" ]; then
  emit_unknown "unknown-github"
fi

# The state and the labels of the issue, read with jq when it is there and
# with a shell fallback when it is not (the machine of the loop has jq).
ISSUE_STATE=""
ISSUE_LABEL_LIST=""
if command -v jq >/dev/null 2>&1; then
  ISSUE_STATE="$(jq -r '.state // ""' <"$ISSUE_RECORD" 2>/dev/null)"
  ISSUE_LABEL_LIST="$(jq -r '[.labels[]? | (.name // "")] | join("\n")' <"$ISSUE_RECORD" 2>/dev/null)"
else
  ISSUE_STATE="$(sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([A-Z]*\)".*/\1/p' "$ISSUE_RECORD" | head -1)"
  ISSUE_LABEL_LIST="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ISSUE_RECORD")"
fi

if [ "$ISSUE_STATE" != "OPEN" ]; then
  emit_resolved "issue-closed" "${ISSUE_STATE:-CLOSED}"
fi

# The label of a claim IS one of the excluded ones (the issue is being worked
# on): in the funnel, an issue that carries it cannot be claimed AGAIN.
# The comparison is on the NORMALIZED label: the excluded labels come from
# a comma-separated list and some of them carry a space ("in progress",
# "status:decision"), and a label of an issue can carry one too ("area:kernel"
# does not, "in progress" does). Comparing the raw strings compared "in
# progress" with "inprogress" and never matched.
normalize_label() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//'; }

LABELS_NORMALIZED=""
while IFS= read -r raw; do
  norm="$(normalize_label "$raw")"
  [ -n "$norm" ] || continue
  LABELS_NORMALIZED="$LABELS_NORMALIZED$norm
"
done <<EOF
$(printf '%s' "$EXCLUDED_LABELS" | tr ',' '\n')
EOF

ISSUE_LABELS_NORMALIZED=""
while IFS= read -r raw; do
  norm="$(normalize_label "$raw")"
  [ -n "$norm" ] || continue
  ISSUE_LABELS_NORMALIZED="$ISSUE_LABELS_NORMALIZED$norm
"
done <<EOF
$(printf '%s' "$ISSUE_LABEL_LIST" | tr ',' '\n')
EOF

while IFS= read -r excl; do
  [ -n "$excl" ] || continue
  if printf '%s' "$ISSUE_LABELS_NORMALIZED" | grep -qxF "$excl"; then
    emit_resolved "excluded-label" "$ISSUE_STATE"
  fi
done <<EOF
$LABELS_NORMALIZED
EOF

rm -f "$ISSUE_RECORD" "$ISSUE_ERR"

# --- the list of the open pull requests and the timeline of the issue ------
#
# WHY THE SHIM READS THEM (2026-11-18): the arbiter decides WHO holds the
# claim. There are three questions that it does not answer and that the
# guard of the loop needs:
#
#   * the TIMELINE of the issue: the pull requests that CROSS-REFERENCED
#     it. The mentions made in the comments of a pull request are only
#     there, and the upstream looks for the claim in the timeline. The
#     oldest OPEN one wins.
#   * whether the list is TRUNCATED: a list of N pull requests when the
#     limit is N is not a list. The guard does NOT know and says so (the
#     arbiter would answer "nobody holds it", and that is the most
#     expensive direction there is).
#   * whether GitHub ANSWERED at all: an empty answer is not an empty
#     list.
#
# The list is read with the numbers and the authors only: the bodies are
# the business of the arbiter.
OPEN_JSON="$WORK/open.json"
if ! "$GH_CMD" pr list --repo "$REPO" --state open --limit "$PR_LIMIT" \
      --json number,author >"$OPEN_JSON" 2>"$WORK/open.err"; then
  emit_unknown "unknown-github"
fi
if [ ! -s "$OPEN_JSON" ]; then
  # An empty answer is not an empty list: GitHub did not answer.
  emit_unknown "unknown-github"
fi

# The timeline of the issue: the pull requests that cross-referenced it.
# The answer is a list of numbers (the filter of gh) and it can also be
# the list of the events (a gh that does not honor the filter): both are
# read here.
TIMELINE_FILE="$WORK/timeline.txt"
if ! "$GH_CMD" api "repos/$REPO/issues/$ISSUE/timeline?per_page=100" --paginate \
      --jq '.[] | select(.event=="cross-referenced")
             | select(.source.issue.pull_request != null)
             | .source.issue.number' >"$TIMELINE_FILE" 2>/dev/null; then
  emit_unknown "unknown-github"
fi

# WHO WE ARE: the author of our own pull requests. The same order as the
# arbiter (the environment, then the config.env of the loop, then the
# authenticated user of gh).
OUR_AUTHOR="$FORK_OWNER"
if [ -z "$OUR_AUTHOR" ]; then
  OUR_AUTHOR="$("$GH_CMD" api user --jq .login 2>/dev/null | head -1)"
fi

# The pull request that is being published is OURS only when its author is
# ours or UNKNOWN: a pull request that demonstrably belongs to somebody
# else keeps the claim (the guard of the loop says so, and it is right:
# the number of a pull request is not a proof of who wrote it).
#
# The three questions are answered by ONE pass over the two lists.
CLAIM_INFO="$(python3 - "$OPEN_JSON" "$TIMELINE_FILE" "$OUR_PR" \
                     "$OUR_AUTHOR" "$PR_LIMIT" <<'PY'
import json
import sys

open_path, timeline_path, our_pr, our_author, limit = sys.argv[1:6]

with open(open_path, encoding="utf-8") as fh:
    prs = json.load(fh)
if not isinstance(prs, list):
    sys.exit(1)

numbers = []
authors = {}
for pr in prs:
    if not isinstance(pr, dict):
        continue
    number = str(pr.get("number") or "").strip()
    if not number:
        continue
    numbers.append(number)
    author = pr.get("author")
    if isinstance(author, dict):
        authors[number] = str(author.get("login") or "")

# The list of N pull requests when the limit is N is not a list.
truncated = "1" if len(prs) >= int(limit) else "0"

ours_author = authors.get(our_pr, "") if our_pr else ""

# The pull request that is being published is OURS only when its author is
# ours or UNKNOWN: a pull request that demonstrably belongs to somebody
# else keeps the claim.
exclude_ours = "yes"
if our_pr and ours_author and our_author:
    if ours_author.lower() != our_author.lower():
        exclude_ours = "no"

# The timeline: the pull requests that cross-referenced the issue. The
# answer is a list of numbers (the filter of gh) or the list of the
# events (a gh that does not honor the filter): both are read here.
with open(timeline_path, encoding="utf-8") as fh:
    raw = fh.read()
timeline = []
data = None
try:
    data = json.loads(raw)
except ValueError:
    data = None
if isinstance(data, list):
    flat = []
    for item in data:
        if isinstance(item, list):
            flat.extend(item)
        else:
            flat.append(item)
    for item in flat:
        if isinstance(item, dict):
            if item.get("event") != "cross-referenced":
                continue
            source = item.get("source") or {}
            issue = source.get("issue") or {}
            if not issue.get("pull_request"):
                continue
            number = issue.get("number")
        else:
            number = item
        if number is not None:
            timeline.append(str(number).strip())
else:
    for line in raw.splitlines():
        line = line.strip()
        if line.isdigit():
            timeline.append(line)

# The holders of the timeline: the cross-referenced pull requests that are
# STILL OPEN (a closed pull request does not hold a claim) and that are
# not the pull request of ours that is being published.
open_numbers = set(numbers)
holders = []
for number in timeline:
    if not number.isdigit() or number not in open_numbers:
        continue
    if our_pr and exclude_ours == "yes" and number == our_pr:
        continue
    if number not in holders:
        holders.append(number)
holders.sort(key=int)

holder = holders[0] if holders else ""
holder_author = authors.get(holder, "") if holder else ""
print("%s|%s|%s|%s|%s|%s" % (len(prs), ours_author, exclude_ours, holder,
                             holder_author, truncated))
PY
)" || emit_unknown "unknown-github"

IFS='|' read -r OPEN_COUNT OURS_PR_AUTHOR EXCLUDE_OURS TIMELINE_HOLDER \
     TIMELINE_HOLDER_AUTHOR TRUNCATED <<< "$CLAIM_INFO"

if [ "$TRUNCATED" = "1" ]; then
  # The list came back truncated: the guard does NOT know.
  emit_unknown "unknown-truncated"
fi

# --- the arbitration --------------------------------------------------------
ARBITER="$(find_arbiter)" || ARBITER=""
if [ -z "$ARBITER" ]; then
  # The rule is not there: the guard does NOT know. It is NOT "free": a
  # publish without a check is a duplicate waiting to happen.
  echo "VERDICT=UNKNOWN"
  echo "REASON=unknown-github"
  echo "ISSUE=$ISSUE"
  echo "claim-race: el arbitro del claim no esta ahi (ni $SCRIPT_DIR/../../bin/claim-verify.sh ni $ORCH_DIR/bin/claim-verify.sh)" >&2
  exit 12
fi

OUTFILE="$WORK/arbiter.out"
ERRFILE="$WORK/arbiter.err"

ARBITER_ARGS=("$ISSUE")
# The pull request of ours is only EXCLUDED from the competition when it
# is really ours (the funnel: may a NEW claim be made on this issue?). In
# the race the answer is the one of the arbiter: our pull request
# competes, whatever its author says.
if [ -n "$OUR_PR" ] && { [ "$EFFECTIVE_MODE" != "funnel" ] || [ "$EXCLUDE_OURS" = "yes" ]; }; then
  ARBITER_ARGS+=(--our-pr "$OUR_PR")
fi

# The stdout and the stderr of the arbiter are captured and put back out
# AS THEY ARE: the caller has to see WHICH issue and WHICH pull request were
# in the answer, that is the useful part of the message.
(
  export SC_REPO="$REPO"
  [ -n "$PR_LIMIT" ] && export SC_PR_LIMIT="$PR_LIMIT"
  [ -n "$FORK_OWNER" ] && export FORK_OWNER="$FORK_OWNER"
  bash "$ARBITER" "${ARBITER_ARGS[@]}"
) >"$OUTFILE" 2>"$ERRFILE"
ARBITER_RC=$?

# --- the answer, in the vocabulary of the rule ------------------------------
# The arbiter answers with its own words ("VEREDICTO=OK", "PRs que lo
# mencionan", "(gana el N)"). This is the translation to the vocabulary that
# the brake, the free-check and the guard of the loop read.
#
# The lines are read with sed WITHOUT a pipe: a pipe inside a $( ) with
# 'set -o pipefail' can return the failure of the head that closed the pipe
# first, and a lost answer is worse than a slow one.
first_line() { printf '%s' "${1%%$'\n'*}"; }

VERDICTO="$(first_line "$(sed -n 's/^VEREDICTO=\([A-Z]*\).*$/\1/p' "$OUTFILE")")"
HOLDER_AUTHOR="$(first_line "$(sed -n 's/^ *el PR #[0-9][0-9]* es de \(.*\)$/\1/p' "$OUTFILE")")"
OURS_HOLDER="$(first_line "$(sed -n 's/^issue=[0-9][0-9]* PRs nuestros (no compiten con nosotros): \([0-9][0-9]*\).*$/\1/p' "$OUTFILE")")"

# The holder: the pull request that the arbitro chose. It is read from the
# line that says who won ("(gana el N)") and, when it is there, from the
# verdict itself ("el PR #N ya reclama", "perdio contra el #N").
HOLDER=""
if [ "$ARBITER_RC" = "1" ]; then
  HOLDER="$(first_line "$(sed -n 's/^VEREDICTO=OCUPADO el PR #\([0-9][0-9]*\).*$/\1/p' "$OUTFILE")")"
  [ -n "$HOLDER" ] || HOLDER="$(first_line "$(sed -n 's/^VEREDICTO=PERDIDO el PR #[0-9][0-9]* perdio contra el #\([0-9][0-9]*\).*$/\1/p' "$OUTFILE")")"
  [ -n "$HOLDER" ] || HOLDER="$(first_line "$(sed -n 's/^issue=[0-9][0-9]* PRs que lo mencionan: .*(gana el \([0-9][0-9]*\)).*$/\1/p' "$OUTFILE")")"
fi

# The holder that the arbitro named but did not attribute (it only names the
# author of the winner when the claim was LOST against us): one read of the
# pull request, to keep the answer of the rule of the loop complete. It does
# not decide anything: it only says who wrote the pull request that the
# arbitro already chose.
if [ -z "$HOLDER_AUTHOR" ] && [ -n "$HOLDER" ]; then
  HOLDER_AUTHOR="$(timeout 30 "$GH_CMD" pr view "$HOLDER" --repo "$REPO" \
                    --json author --jq '.author.login' 2>/dev/null)" || HOLDER_AUTHOR=""
  HOLDER_AUTHOR="$(first_line "$HOLDER_AUTHOR")"
fi

VERDICT="UNKNOWN"
REASON="unknown-github"
case "$ARBITER_RC" in
  0)
    VERDICT="OK"
    if [ -n "$OUR_PR" ] || [ -n "$OURS_HOLDER" ]; then REASON="ours"; else REASON="free"; fi
    ;;
  1)
    if [ "$VERDICTO" = "PERDIDO" ]; then
      VERDICT="LOST"
      REASON="lost-race"
    else
      VERDICT="TAKEN"
      REASON="claimed-by-pr"
    fi
    ;;
  2)
    VERDICT="UNKNOWN"
    REASON="unknown-github"
    ;;
  *)
    VERDICT="UNKNOWN"
    REASON="unknown-github"
    ;;
esac

# The TIMELINE, the third source of the claim: a pull request that
# CROSS-REFERENCED the issue holds it too, even when it does not name the
# issue in its title or in its body (the mentions made in the comments of
# a pull request are only there, and the upstream looks for the claim
# there).
#
# It is the question of the TRIAGE ("may a new claim be made on this
# issue?"), not the question of the RACE ("who won the race?"): in the
# race the answer is the one of the arbiter, that competes with our pull
# request.
if [ "$VERDICT" = "OK" ] && [ -n "$TIMELINE_HOLDER" ] \
   && [ "$EFFECTIVE_MODE" != "race" ]; then
  VERDICT="TAKEN"
  REASON="mentioned-by-pr"
  HOLDER="$TIMELINE_HOLDER"
  HOLDER_AUTHOR="$TIMELINE_HOLDER_AUTHOR"
fi

HOLDER_OURS=""
if [ -n "$HOLDER" ] && [ -n "$HOLDER_AUTHOR" ] && [ -n "$FORK_OWNER" ]; then
  if [ "${HOLDER_AUTHOR,,}" = "${FORK_OWNER,,}" ]; then HOLDER_OURS="yes"; else HOLDER_OURS="no"; fi
fi

printf 'VERDICT=%s\n' "$VERDICT"
printf 'REASON=%s\n' "$REASON"
printf 'ISSUE=%s\n' "$ISSUE"
[ -n "$OUR_PR" ] && printf 'OURS=%s\n' "$OUR_PR"
[ -n "$HOLDER" ] && printf 'HOLDER=%s\n' "$HOLDER"
[ -n "$HOLDER_AUTHOR" ] && printf 'HOLDER_AUTHOR=%s\n' "$HOLDER_AUTHOR"
[ -n "$HOLDER_OURS" ] && printf 'HOLDER_OURS=%s\n' "$HOLDER_OURS"
[ -n "$HOLDER" ] && printf 'HOLDER_CLAIMS=yes\n'
# HOLDER_LOGIN is the LOGIN of whoever holds the claim. The brake reads it
# for the sentence it says out loud and the salvage writes it in the note
# ("who holds it: @X"). In the rule of the loop it was the login that the
# RECORD of the issue named; here the holder is always a pull request and
# the one who holds the claim is its author, so it is the same name.
[ -n "$HOLDER_AUTHOR" ] && printf 'HOLDER_LOGIN=%s\n' "$HOLDER_AUTHOR"
[ -n "$OURS_HOLDER" ] && printf 'OURS_HOLDER=%s\n' "$OURS_HOLDER"

# The stdout of the arbitro, tal cual: el mensaje util (que issue, que PR lo
# tomo) es del arbitro, y el que lo llama tiene que verlo.
cat "$OUTFILE"
cat "$ERRFILE" >&2

# The exit code is the exit code of the VERDICT and not the one of the
# arbiter: the timeline can hold the claim on its own (the arbiter does
# not know it), and the verdict says TAKEN.
case "$VERDICT" in
  OK) exit 0 ;;
  TAKEN|LOST) exit 10 ;;
  RESOLVED) exit 11 ;;
  *) exit 12 ;;
esac
