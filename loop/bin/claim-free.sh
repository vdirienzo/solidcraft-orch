#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# claim-free.sh - IS THE CLAIM OF THIS ISSUE STILL FREE?
#
# WHY THIS EXISTS (01-11-2026): the claim of an issue is not a label, it is a
# RECORD, and the record lives in the COMMENTS of the issue. The bot of the
# upstream applies the label 'in progress' with a DELAY, so the label of an
# issue that somebody else claimed can still be EMPTY minutes after the
# claim. We lost #10134, #10138, #10079 and #10306 exactly that way: the
# work was done (hours of the agent and a whole gate) and then another
# agent's pull request turned out to hold the claim.
#
# So the label alone is NOT enough, and this script reads what the label does
# not say:
#   * the ASSIGNEES of the issue (the bot assigns the claimant);
#   * the COMMENTS of the issue: the bot's "Claimed by @X through #Y", its
#     release ("this one is free again"), and the triage that says the issue
#     is already handled ("same root cause as #Z, fixed by #W", "please
#     reopen");
#   * the OPEN pull requests of another author that mention the issue: the
#     draft IS the claim of the upstream.
#
# The verdict is about ONE question: may we start (or continue) working on
# this issue? The race between two of OUR OWN pull requests is a different
# question, and it is answered by the arbiter (bin/claim-race.sh).
#
# EXIT CODES:
#   0  FREE      nobody holds the claim: the issue can be worked on
#   3  TAKEN     somebody else holds the claim: DO NOT work on it
#   4  MOOT      the issue is closed, already handled or out of the funnel:
#                the work would be thrown away
#   6  UNKNOWN   GitHub could not be read: the guard does NOT know, and a
#                work without a check is a work thrown away
#
# USAGE:
#   bash bin/claim-free.sh --issue N [--repo owner/name]
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# The arbiter: it knows the rule of the race and the rule of the open pull
# requests. This script only decides what to DO with the answer.
ARBITER="$SCRIPT_DIR/claim-race.sh"

ISSUE=""
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE="$2"; shift 2 ;;
    --repo)  REPO="$2"; shift 2 ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) echo "claim-free: unknown option: $1" >&2; exit 2 ;;
  esac
done

if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "claim-free: the issue has to be a number: '$ISSUE'" >&2
  exit 2
fi

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
    echo "claim-free: the config.env has a syntax error: $LOOP_DIR/config.env" >&2
    exit 2
  fi
fi

# config.env is the source of truth of the upstream, of the author of the
# loop and of the labels that take an issue out of the funnel.
if [ -r "$LOOP_DIR/config.env" ]; then
  # shellcheck source=/dev/null
  . "$LOOP_DIR/config.env"
fi

[ -n "$REPO" ] || REPO="${SC_REPO:-${UPSTREAM:-tangency-labs/solidcraft}}"
# Our own login: a claim that is OURS is not a claim against us, and our own
# comments do not take the issue out of our own funnel.
AUTHOR="${SC_FORK_OWNER:-${FORK_OWNER:-}}"
# The label the upstream puts on a claimed issue (scripts/claim/claim.js).
CLAIM_LABEL="${SC_CLAIM_LABEL:-in progress}"
# The labels that take an issue out of the funnel for a reason that is NOT
# somebody else's claim (the kernel is paused, a decision was taken, the
# issue needs information).
EXCLUDED_LABELS="${CLAIM_EXCLUDED_LABELS:-in progress,kernel-paused,status:decision,needs-info,area:kernel}"
# The label of a claim, in lower case: the comparison is done in lower case
# because GitHub does not guarantee the case of a label.
CLAIM_LABEL_LOWER="$(printf '%s' "$CLAIM_LABEL" | tr '[:upper:]' '[:lower:]')"

say() { echo "claim-free: $*" >&2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claim-free.XXXXXX")" || {
  say "a temporary directory could not be created"
  exit 6
}
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- the record of the issue -------------------------------------------------
# The state, the labels, the assignees AND the comments in one call: the
# comments are the part that the label cannot replace.
if ! timeout 120 gh issue view "$ISSUE" --repo "$REPO" \
        --json number,state,stateReason,labels,assignees,comments \
        > "$WORK/issue.json" 2> "$WORK/issue.err"; then
  # An issue that does not exist is not ignorance, it is a fact: there is
  # nothing to work on. A network that does not answer is ignorance.
  if grep -qi '404\|not found\|could not resolve' "$WORK/issue.err"; then
    say "the issue #$ISSUE does not exist: there is nothing to work on"
    exit 4
  fi
  say "the issue #$ISSUE could not be read: the guard does not know"
  exit 6
fi
if [ ! -s "$WORK/issue.json" ]; then
  say "the issue #$ISSUE could not be read: the guard does not know"
  exit 6
fi

# --- what the record says ---------------------------------------------------
# The verdict is computed in ONE place, so the comments, the labels and the
# assignees can never disagree about who holds the claim.
ANSWER="$(python3 - "$WORK/issue.json" "$AUTHOR" "$CLAIM_LABEL" "$EXCLUDED_LABELS" <<'PY'
import json
import re
import sys

path, author, claim_label, excluded_csv = sys.argv[1:5]
author = str(author or "")
claim_label = str(claim_label or "")
excluded = {t.strip().lower() for t in str(excluded_csv or "").split(",") if t.strip()}

try:
    with open(path, encoding="utf-8") as fh:
        issue = json.load(fh)
except Exception:
    issue = {}
if not isinstance(issue, dict):
    issue = {}

labels = []
for label in (issue.get("labels") or []):
    name = str(label.get("name", "") if isinstance(label, dict) else label)
    if name:
        labels.append(name.strip())
lowered = {name.lower() for name in labels}

assignees = []
for assignee in (issue.get("assignees") or []):
    login = str((assignee or {}).get("login", "") if isinstance(assignee, dict) else assignee)
    if login:
        assignees.append(login.strip())

comments = []
for comment in (issue.get("comments") or []):
    if not isinstance(comment, dict):
        continue
    who = str((comment.get("author") or {}).get("login", "") or "")
    body = str(comment.get("body") or "")
    when = str(comment.get("createdAt") or "")
    comments.append((when, who, body))
comments.sort(key=lambda item: item[0])

# The bot of the upstream writes "Claimed by @X through #Y" when a pull
# request takes the issue, and "this one is free again" when it releases it.
# The release wins when it comes LATER: the claim of a lapsed issue is not a
# claim (the upstream does the same with the 'unlabeled' event).
CLAIMED_BY = re.compile(r"^Claimed by @([A-Za-z0-9-]+)\b", re.IGNORECASE)
RELEASED = re.compile(r"\bfree again\b|\bReleased\.\b", re.IGNORECASE)
# The triage that says the issue is already handled. These are the sentences
# of the house: the issue is not free, the work would be thrown away.
HANDLED = re.compile(
    r"\balready (?:fixed|resolved|handled|done)\b"
    r"|\bfixed by\s+#\d+"
    r"|\bsame root cause\b"
    r"|\bduplicate of\s+#\d+"
    r"|\bplease reopen\b",
    re.IGNORECASE)

holder = ""
holder_evidence = ""
handled_evidence = ""
for _when, _who, body in comments:
    match = CLAIMED_BY.search(body.strip())
    if match:
        holder = match.group(1)
        holder_evidence = "the bot of the upstream recorded the claim"
        continue
    if RELEASED.search(body):
        holder = ""
        holder_evidence = ""
        continue
    if not handled_evidence and HANDLED.search(body):
        handled_evidence = body.strip().splitlines()[0][:160]

# Our OWN claim is not a claim against us, and our own comments do not take
# the issue out of our own funnel.
if holder and author and holder.lower() == author.lower():
    holder = ""
    holder_evidence = ""

# An assignment to US is our own claim, not somebody else's.
ours = [login for login in assignees if author and login.lower() == author.lower()]
others = [login for login in assignees if login not in ours]

print("state=%s" % str(issue.get("state", "")))
print("labels=%s" % ",".join(sorted(lowered)))
print("assignees=%s" % ",".join(others))
print("holder=%s" % holder)
print("holder_evidence=%s" % holder_evidence)
print("handled=%s" % handled_evidence)
PY
)"

field() { printf '%s\n' "$ANSWER" | sed -n "s/^$1=//p" | head -1; }

STATE="$(field state)"
LABELS="$(field labels)"
ASSIGNEES="$(field assignees)"
HOLDER="$(field holder)"
HOLDER_EVIDENCE="$(field holder_evidence)"
HANDLED="$(field handled)"

if [ -z "$STATE" ]; then
  say "the record of the issue #$ISSUE could not be read: the guard does not know"
  exit 6
fi

# --- the verdict of the record ----------------------------------------------
# The order matters: a claim that is OURS comes first (it is not a claim
# against us), then the claim of somebody else, then the issue that is moot.
if [ -n "$HOLDER" ]; then
  say "the claim of the issue #$ISSUE is held by @$HOLDER: $HOLDER_EVIDENCE"
  echo "VERDICT=TAKEN"
  echo "ISSUE=$ISSUE"
  echo "HOLDER=$HOLDER"
  exit 3
fi

if [ -n "$ASSIGNEES" ]; then
  say "the issue #$ISSUE is assigned to @$ASSIGNEES: somebody is working on it"
  echo "VERDICT=TAKEN"
  echo "ISSUE=$ISSUE"
  echo "HOLDER=$ASSIGNEES"
  exit 3
fi

if [ -n "$HANDLED" ]; then
  say "the issue #$ISSUE is already handled ($HANDLED): the work would be thrown away"
  echo "VERDICT=MOOT"
  echo "ISSUE=$ISSUE"
  exit 4
fi

if [ "$STATE" != "OPEN" ]; then
  say "the issue #$ISSUE is $STATE, not OPEN: there is nothing to work on"
  echo "VERDICT=MOOT"
  echo "ISSUE=$ISSUE"
  exit 4
fi

# The labels that take the issue out of the funnel for a reason that is not
# somebody else's claim. The list is comma separated and a label may have
# spaces ("in progress"), so it is split on the comma and never on the
# space.
OLD_IFS="$IFS"
IFS=','
for label in $EXCLUDED_LABELS; do
  IFS="$OLD_IFS"
  lower="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  IFS=','
  [ -n "$lower" ] || continue
  # The claim label is handled above (it is somebody else's claim).
  [ "$lower" = "$CLAIM_LABEL_LOWER" ] && continue
  case ",$LABELS," in
    *",$lower,"*)
      say "the issue #$ISSUE carries the label '$lower': it is out of the funnel"
      echo "VERDICT=MOOT"
      echo "ISSUE=$ISSUE"
      exit 4
      ;;
  esac
done
IFS="$OLD_IFS"

# The label of a claim is the claim label applied to an issue that is NOT
# ours: the bot applies it with a delay, so its presence is proof and its
# absence is not.
case ",$LABELS," in
  *",$CLAIM_LABEL_LOWER,"*)
    say "the issue #$ISSUE carries the label '$CLAIM_LABEL': somebody is working on it"
    echo "VERDICT=TAKEN"
    echo "ISSUE=$ISSUE"
    exit 3
    ;;
esac

# --- the open pull requests --------------------------------------------------
# The last word is the arbiter: an open pull request of another author that
# mentions the issue IS a claim (the draft is the claim of the upstream).
if [ ! -f "$ARBITER" ]; then
  say "the arbiter is not there: $ARBITER"
  exit 6
fi
RACE=""
RACE_RC=0
if [ -n "$REPO" ]; then
  RACE="$(SC_REPO="$REPO" bash "$ARBITER" "$ISSUE" 2>/dev/null)" || RACE_RC=$?
else
  RACE="$(bash "$ARBITER" "$ISSUE" 2>/dev/null)" || RACE_RC=$?
fi
RACE_VERDICT="$(printf '%s\n' "$RACE" | sed -n 's/^VERDICT=//p' | head -1)"
RACE_HOLDER="$(printf '%s\n' "$RACE" | sed -n 's/^HOLDER=//p' | head -1)"

case "$RACE_VERDICT" in
  OK)
    echo "VERDICT=FREE"
    echo "ISSUE=$ISSUE"
    exit 0
    ;;
  TAKEN|LOST)
    say "the issue #$ISSUE is TAKEN by the open pull request #${RACE_HOLDER:-?}: somebody else is working on it"
    echo "VERDICT=TAKEN"
    echo "ISSUE=$ISSUE"
    echo "HOLDER=${RACE_HOLDER:-}"
    exit 3
    ;;
  RESOLVED)
    say "the issue #$ISSUE is not OPEN any more: there is nothing to work on"
    echo "VERDICT=MOOT"
    echo "ISSUE=$ISSUE"
    exit 4
    ;;
  *)
    say "the open pull requests could not be read (rc=$RACE_RC): the guard does not know"
    echo "VERDICT=UNKNOWN"
    echo "ISSUE=$ISSUE"
    exit 6
    ;;
esac
