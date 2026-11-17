#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# claim-guard.sh - the deterministic gate of a claim.
#
# WHAT IT IS: the rules that decide whether the loop may open a PR for an
# issue, IN CODE and not in the paragraph of a prompt. A model that reads
# "do not claim an issue that is already claimed" in a prompt forgets it once
# in a while; a script does not.
#
# THE RULES:
#   1. the issue is OPEN and carries no EXCLUDED label;
#   2. no OPEN pull request (of ANY author) holds the claim of the issue.
#      There are two sources and BOTH are consulted:
#        a. the TIMELINE of the issue: GitHub gathers there every PR that
#           cross-referenced it, and the OLDEST OPEN one wins. This is the
#           source the upstream uses ("the lowest numbered open PR wins"),
#           and it also catches the mentions made in the comments of a PR;
#        b. the BODIES of the open PRs: GitHub does NOT cross-reference a
#           `#N` written inside a code block, so a body scan finds the
#           mentions the timeline misses.
#      One of them is not enough: the timeline alone misses the code
#      blocks, the bodies alone miss the comments.
#   3. the queue of the loop has not reached the ceiling (MAINT_THRESHOLD):
#      the loop is here to fix issues, not to make the maintainer merge.
#      The queue is counted BY ORIGIN (the branches the loop opens,
#      CLAIM_LOOP_BRANCH_PREFIXES), not by author: a pull request opened by
#      hand is not the queue of the loop, and the retired pull requests
#      (RETIRED_PRS) do not keep it busy. A pull request whose origin is
#      UNKNOWN counts as of the loop: the guard does not know, and a brake
#      that lets go is no brake.
#   4. a list that comes back TRUNCATED is not a count: the guard does NOT
#      know and says so (exit 6). A list of 100 pull requests says "100"
#      when there are two hundred.
#
# THE LABELS AND THE CEILING COME FROM config.env: CLAIM_EXCLUDED_LABELS,
# CLAIM_WANTED_LABELS and MAINT_THRESHOLD. Changing the policy is changing
# the configuration, not the code.
#
# THE THREE MODES:
#   claim-guard.sh <issue>       the issue can be claimed? (one answer)
#   claim-guard.sh --candidates  the issues of the funnel that pass the
#                                 filters (the list for the triage)
#   claim-guard.sh --duplicates  the open pull requests of ours that LOST
#                                 the race of an issue against an open pull
#                                 request with a LOWER number (the rule of
#                                 the upstream: the lowest numbered open PR
#                                 wins)
#
# THE FLAG OF THE MODE OF ONE ISSUE:
#   claim-guard.sh --ours <pr> <issue>
#       the pull request <pr> is OUR OWN (the one that is being published):
#       it does not hold the claim of its own issue. The exclusion only
#       applies when the author of the pull request is OURS or UNKNOWN: a
#       pull request that demonstrably belongs to somebody else keeps the
#       claim.
#
# EXIT CODES:
#   0  the issue can be claimed (or the list is written)
#   2  the issue carries an excluded label (or the mode was called wrong)
#   3  an open PR already holds the claim of the issue
#   4  the issue is closed (or it does not exist)
#   5  the queue of open PRs reached the ceiling
#   6  GitHub could not be asked (no network, no auth) or the list that came
#      back was TRUNCATED: the guard does NOT know, and a claim without a
#      check is a duplicate waiting to happen
#
# THE EXIT CODES OF --duplicates (the race of an issue):
#   0  no race was lost: every open pull request of ours keeps its issue
#   1  one of our open pull requests LOST the race of an issue
#   2  the mode was called wrong
#   6  GitHub could not be read: the guard does NOT know
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
# The directory of this script: the RULE of the claim lives next to it and
# it is called by path, never by a guess.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
    echo "claim-guard: the config.env has a syntax error: $LOOP_DIR/config.env" >&2
    exit 2
  fi
fi

# shellcheck source=/dev/null
if [ -r "$LOOP_DIR/config.env" ]; then
  . "$LOOP_DIR/config.env"
fi

UPSTREAM="${UPSTREAM:-tangency-labs/solidcraft}"
FORK_OWNER="${FORK_OWNER:-vdirienzo}"
MAINT_THRESHOLD="${MAINT_THRESHOLD:-10}"
# The labels that take an issue OUT of the funnel. The space separates them
# and the label itself can have spaces ("in progress"), so the list is
# comma separated.
CLAIM_EXCLUDED_LABELS="${CLAIM_EXCLUDED_LABELS:-in progress,kernel-paused,status:decision,needs-info,area:kernel}"
# The label the funnel WANTS. The funnel can want more than one: the
# upstream reports the translations that are missing with `feature.yml` ->
# label `enhancement`, and those issues never reached the triage.
CLAIM_WANTED_LABEL="${CLAIM_WANTED_LABEL:-bug}"
CLAIM_WANTED_LABELS="${CLAIM_WANTED_LABELS:-${CLAIM_WANTED_LABEL:-bug}}"
# How many candidates the list mode prints.
CLAIM_CANDIDATE_LIMIT="${CLAIM_CANDIDATE_LIMIT:-20}"
# How many issues of the funnel the list mode consults the timeline of.
# The timeline of one issue is one call to the API: the scan is bounded so
# the list mode cannot spend minutes in the API.
CLAIM_SCAN_LIMIT="${CLAIM_SCAN_LIMIT:-25}"
# The open PRs of the upstream that are consulted: the mentions live in
# their bodies. The upstream had 637 open PRs (27-10-2026): a limit of 100
# truncated the list and the guard could not see a claim made by a PR of
# another author. The limit went to 1000 on 31-10-2026: with 700 the
# upstream had 749 open PRs and the guard answered "does not know" (blind)
# for EVERY duplicate check. 1000 is the ceiling of `gh pr list`; when the
# upstream reaches it the guard goes blind again and the strategy has to
# change (do NOT raise the limit).
CLAIM_PR_LIMIT="${CLAIM_PR_LIMIT:-1000}"
# The open PRs of OURS that are counted: the queue of the loop. It has its
# own limit: the limit of 100 that the guard used truncated the queue in
# silence (a list of 100 pull requests says "100" when there are two
# hundred).
CLAIM_OUR_PR_LIMIT="${CLAIM_OUR_PR_LIMIT:-200}"
# The branches the loop opens: a pull request of one of them is of the
# loop, whatever its author.
CLAIM_LOOP_BRANCH_PREFIXES="${CLAIM_LOOP_BRANCH_PREFIXES:-fix/issue-,spike/issue-}"
# The pull requests the loop RETIRED: they do not keep the queue busy.
RETIRED_PRS="${RETIRED_PRS:-}"

say() { echo "claim-guard: $*"; }

# --- the modes --------------------------------------------------------------
# The flags are read BEFORE anything else: a usage error is a usage error
# even when GitHub cannot be asked.
MODE="issue"
ISSUE=""
OURS_PR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ours)
      [ $# -ge 2 ] || { say "the usage is: claim-guard.sh --ours <pr> <issue>"; exit 2; }
      OURS_PR="$2"
      case "$OURS_PR" in
        ''|*[!0-9]*) say "--ours needs the number of a pull request"; exit 2 ;;
      esac
      shift 2 ;;
    --candidates) MODE="candidates"; shift ;;
    --duplicates) MODE="duplicates"; shift ;;
    -*) say "unknown option: $1"; exit 2 ;;
    *) ISSUE="$1"; shift ;;
  esac
done

if [ "$MODE" != "issue" ] && [ -n "$OURS_PR" ]; then
  say "--ours is only valid in the mode of one issue"
  exit 2
fi
if [ "$MODE" = "duplicates" ] && [ -n "$ISSUE" ]; then
  say "the usage is: claim-guard.sh --duplicates"
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  say "gh is not in the PATH: the guard cannot check anything"
  exit 6
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claim-guard.XXXXXX")" || exit 6
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- the helpers of GitHub -------------------------------------------------
# Every call goes through a timeout: a hanging API is a claim that never
# ends, and the turn of the slot has a budget.
gh_json() {
  timeout 120 gh api "$1" 2>/dev/null
}

# The open PRs of the upstream with their bodies and their author: the set
# of the open PRs (to know which one is still open), the mentions of their
# bodies and the author (to know which pull request is ours).
open_prs() {
  timeout 180 gh pr list --repo "$UPSTREAM" --state open \
    --limit "$CLAIM_PR_LIMIT" --json number,title,body,author 2>/dev/null
}

# The open PRs of ours: the queue of the loop. They are written to a FILE
# because the count is made by origin and the origin is the branch.
our_open_prs_to_file() {
  timeout 180 gh pr list --repo "$UPSTREAM" --author "$FORK_OWNER" \
    --state open --limit "$CLAIM_OUR_PR_LIMIT" \
    --json number,headRefName,author >"$1" 2>/dev/null
}

# The open PRs of ours WITH their bodies: the race of an issue is decided by
# the mentions of the title and of the body. The helper above asks only for
# the origin (it counts the queue), this one asks for the bodies as well.
our_open_prs_bodies() {
  timeout 180 gh pr list --repo "$UPSTREAM" --author "$FORK_OWNER" \
    --state open --limit "$CLAIM_OUR_PR_LIMIT" \
    --json number,title,body,author 2>/dev/null
}

# The PRs that cross-referenced the issue, one number per line. The
# timeline gathers the mentions made anywhere in the PR (body, comments,
# commits), not only in the body.
cross_referenced_prs() {
  timeout 120 gh api "repos/$UPSTREAM/issues/$1/timeline" --paginate \
    --jq '.[] | select(.event=="cross-referenced")
           | select(.source.issue.pull_request != null)
           | .source.issue.number' 2>/dev/null
}

# How many pull requests a JSON list holds, and whether it is a list at all:
# an empty answer and a failed call are not the same thing.
count_of_list() {
  python3 -c 'import json,sys
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(1)
print(len(data))' 2>/dev/null
}

# --- the queue of the loop, counted BY ORIGIN ------------------------------
# The queue is the pull requests of the branches the loop opens. The retired
# pull requests (RETIRED_PRS) do not keep it busy, and a pull request whose
# origin is unknown counts as of the loop: the guard does not know, and a
# brake that lets go is no brake.
queue_counts() {
  python3 - "$1" "$CLAIM_LOOP_BRANCH_PREFIXES" "$RETIRED_PRS" <<'PY'
import json
import sys

path, prefixes_csv, retired_csv = sys.argv[1:4]
prefixes = [p for p in (x.strip() for x in prefixes_csv.split(",")) if p]
retired = {x.strip() for x in retired_csv.split(",") if x.strip()}

with open(path, encoding="utf-8") as fh:
    prs = json.load(fh)
if not isinstance(prs, list):
    sys.exit(1)

loop = 0
author = 0
total = 0
for pr in prs:
    total += 1
    if str(pr.get("number") or "") in retired:
        continue
    author += 1
    head = str(pr.get("headRefName") or "").strip()
    if not head or any(head.startswith(p) for p in prefixes):
        loop += 1
print("%d %d %d" % (loop, author, total))
PY
}

QUEUE_LOOP=0
QUEUE_AUTHOR=0
QUEUE_TOTAL=0

# The queue of the loop, and the ceiling. A list that comes back truncated
# is NOT a count: the guard does not know.
queue_of_the_loop() {
  local file="$1" counts=""
  if ! counts="$(queue_counts "$file")"; then
    say "our open pull requests could not be counted: the guard does not know"
    exit 6
  fi
  QUEUE_LOOP="$(printf '%s' "$counts" | cut -d' ' -f1)"
  QUEUE_AUTHOR="$(printf '%s' "$counts" | cut -d' ' -f2)"
  QUEUE_TOTAL="$(printf '%s' "$counts" | cut -d' ' -f3)"
  if [ "$QUEUE_TOTAL" -ge "$CLAIM_OUR_PR_LIMIT" ]; then
    say "our open pull requests are truncated ($QUEUE_TOTAL of $CLAIM_OUR_PR_LIMIT): the guard does not know"
    exit 6
  fi
}

# The report of the queue: the loop and the author are two different
# numbers and both are said out loud.
queue_report() {
  printf 'our-open-prs: %s/%s\n' "$QUEUE_LOOP" "$MAINT_THRESHOLD"
  printf 'our-open-prs-by-author: %s\n' "$QUEUE_AUTHOR"
  printf 'ceiling: %s\n' "$MAINT_THRESHOLD"
}

# --- the mode of the list --------------------------------------------------
if [ "$MODE" = "candidates" ]; then
  # The ceiling is checked FIRST: it is one cheap call and it saves the
  # whole scan when the loop is in maintenance mode.
  if ! our_open_prs_to_file "$WORK/ours.json"; then
    say "our open PRs could not be counted: the list is not written"
    exit 6
  fi
  queue_of_the_loop "$WORK/ours.json"
  if [ "$QUEUE_LOOP" -ge "$MAINT_THRESHOLD" ]; then
    say "our open PRs of the loop are $QUEUE_LOOP and the ceiling is $MAINT_THRESHOLD:"
    say "the loop is in maintenance mode: no new claim until the maintainer merges some"
    exit 5
  fi

  prs="$(open_prs)"
  if [ -z "$prs" ]; then
    say "the open PRs of the upstream could not be read: the list is not written"
    exit 6
  fi
  if ! prs_count="$(printf '%s' "$prs" | count_of_list)"; then
    say "the open PRs of the upstream could not be read: the list is not written"
    exit 6
  fi
  if [ "$prs_count" -ge "$CLAIM_PR_LIMIT" ]; then
    say "the open PRs of the upstream are truncated ($prs_count of $CLAIM_PR_LIMIT): the list is not written"
    exit 6
  fi
  printf '%s' "$prs" > "$WORK/prs.json"

  # The funnel is asked LABEL BY LABEL: the list of the candidates is the
  # MERGE of the answers, without repetitions.
  : > "$WORK/labels.txt"
  index=0
  for label in $(printf '%s' "$CLAIM_WANTED_LABELS" | tr ',' ' '); do
    [ -n "$label" ] || continue
    index=$((index + 1))
    printf '%s\n' "$label" >> "$WORK/labels.txt"
    if ! timeout 120 gh issue list --repo "$UPSTREAM" --state open \
        --label "$label" --limit 100 --json number,title,labels \
        > "$WORK/issues-label-$index.json" 2>/dev/null; then
      say "the issues of the upstream could not be read: the list is not written"
      exit 6
    fi
    if [ ! -s "$WORK/issues-label-$index.json" ]; then
      say "the issues of the upstream could not be read: the list is not written"
      exit 6
    fi
  done

  # The merge: the same issue can carry two labels of the funnel and it is
  # ONE candidate, not two.
  if ! python3 - "$WORK/issues.json" "$CLAIM_WANTED_LABELS" \
      "$CLAIM_EXCLUDED_LABELS" "$WORK"/issues-label-*.json <<'PY'
import json
import sys

out_path, wanted_csv, excluded_csv = sys.argv[1:4]
paths = sys.argv[4:]
wanted = {x.strip().lower() for x in wanted_csv.split(",") if x.strip()}
excluded = {x.strip().lower() for x in excluded_csv.split(",") if x.strip()}

merged = {}
order = []
for path in paths:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        continue
    if not isinstance(data, list):
        continue
    for issue in data:
        num = str(issue.get("number") or "")
        if not num:
            continue
        names = [str(l.get("name") or "") for l in (issue.get("labels") or [])
                 if isinstance(l, dict)]
        if num not in merged:
            merged[num] = dict(issue)
            order.append(num)
        known = {str(l.get("name") or "") for l in (merged[num].get("labels") or [])
                 if isinstance(l, dict)}
        for name in names:
            if name not in known:
                known.add(name)
                merged[num].setdefault("labels", []).append({"name": name})

kept = []
for num in order:
    issue = merged[num]
    names = {str(l.get("name") or "").strip().lower()
             for l in (issue.get("labels") or []) if isinstance(l, dict)}
    if names & excluded:
        continue
    if names and not (names & wanted):
        continue
    kept.append(issue)

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(kept, fh)
PY
  then
    say "the issues of the upstream could not be read: the list is not written"
    exit 6
  fi

  # The timeline of the issues of the funnel that pass the labels: the
  # mentions in the comments of a PR are only there.
  : > "$WORK/timeline.txt"
  scanned=0
  while read -r issue_num; do
    [ -n "$issue_num" ] || continue
    [ "$scanned" -lt "$CLAIM_SCAN_LIMIT" ] || break
    scanned=$((scanned + 1))
    printf '%s ' "$issue_num" >> "$WORK/timeline.txt"
    cross_referenced_prs "$issue_num" | tr '\n' ' ' >> "$WORK/timeline.txt"
    printf '\n' >> "$WORK/timeline.txt"
  done < <(python3 - "$WORK/issues.json" "$CLAIM_EXCLUDED_LABELS" <<'PY'
import json
import sys

excluded = {x.strip().lower() for x in sys.argv[2].split(",") if x.strip()}
with open(sys.argv[1], encoding="utf-8") as fh:
    issues = json.load(fh)
for issue in issues:
    labels = {str(l.get("name", "")).strip().lower() for l in (issue.get("labels") or [])}
    if labels & excluded:
        continue
    print(issue.get("number"))
PY
)

  python3 - "$WORK/prs.json" "$WORK/issues.json" "$WORK/timeline.txt" \
    "$MAINT_THRESHOLD" "$CLAIM_EXCLUDED_LABELS" "$CLAIM_CANDIDATE_LIMIT" \
    "$CLAIM_SCAN_LIMIT" "$QUEUE_LOOP" "$QUEUE_AUTHOR" <<'PY'
import json
import re
import sys

prs_path, issues_path, timeline_path = sys.argv[1:4]
ceiling = int(sys.argv[4])
excluded = {x.strip().lower() for x in sys.argv[5].split(",") if x.strip()}
limit = int(sys.argv[6])
scan_limit = int(sys.argv[7])
ours = int(sys.argv[8])
author = int(sys.argv[9])

with open(prs_path, encoding="utf-8") as fh:
    prs = json.load(fh)
with open(issues_path, encoding="utf-8") as fh:
    issues = json.load(fh)

open_numbers = {str(p.get("number")) for p in prs}
mentioned = {}
for pr in prs:
    text = "%s\n%s" % (pr.get("title") or "", pr.get("body") or "")
    for num in re.findall(r"#(\d+)", text):
        mentioned.setdefault(num, set()).add(str(pr.get("number")))

# The timeline: the PRs that cross-referenced the issue, and only the open
# ones hold the claim. `scanned` is the set of the issues whose timeline was
# actually consulted: an issue that was not consulted cannot be listed as a
# candidate (its claim is not known).
timeline = {}
scanned = set()
with open(timeline_path, encoding="utf-8") as fh:
    for line in fh:
        parts = line.split()
        if not parts:
            continue
        issue_num = parts[0]
        scanned.add(issue_num)
        holders = {p for p in parts[1:] if p in open_numbers}
        if holders:
            timeline.setdefault(issue_num, set()).update(holders)

kept = []
for issue in issues:
    num = str(issue.get("number"))
    labels = {str(l.get("name", "")).strip().lower() for l in (issue.get("labels") or [])}
    if labels & excluded:
        continue
    if num not in scanned:
        continue
    holders = set(mentioned.get(num, set())) | set(timeline.get(num, set()))
    if holders:
        continue
    kept.append((num, issue.get("title") or "", sorted(labels)))

print("open-prs-upstream: %d" % len(prs))
print("our-open-prs: %d/%d" % (ours, ceiling))
print("our-open-prs-by-author: %d" % author)
print("ceiling: %d" % ceiling)
print("scanned: %d issues of the funnel (the cap is %d)" % (len(scanned), scan_limit))
print("candidates: %d" % len(kept))
for num, title, labels in kept[:limit]:
    print("candidate: #%s %s [%s]" % (num, title, ",".join(labels)))
if len(kept) > limit:
    print("more: %d" % (len(kept) - limit))
PY
  exit $?
fi

# --- the mode of the duplicates -------------------------------------------
# The upstream applies "the lowest numbered open pull request wins": when
# two OPEN pull requests mention the same issue, the one with the LOWER
# number holds the claim. This mode finds the open pull requests of OURS
# that LOST that race: another OPEN pull request with a lower number
# mentions the same issue.
#
# The loop CAN close the duplicate (`gh pr close` works: verified 31-10-2026
# on the fork with a draft throwaway). The rule of the upstream is that the
# LOWEST numbered open pull request holds the claim, so the one that LOST
# has to be closed: leaving it open is a second claim on the same issue.
# It DETECTS it, it REPORTS it, and it CLOSES it.
if [ "$MODE" = "duplicates" ]; then
  ours_json="$(our_open_prs_bodies)"
  if [ -z "$ours_json" ]; then
    say "our open pull requests could not be read: the guard does not know"
    exit 6
  fi
  if ! ours_count="$(printf '%s' "$ours_json" | count_of_list)"; then
    say "our open pull requests could not be read: the guard does not know"
    exit 6
  fi
  if [ "$ours_count" -ge "$CLAIM_OUR_PR_LIMIT" ]; then
    say "our open pull requests are truncated ($ours_count of $CLAIM_OUR_PR_LIMIT): the guard does not know"
    exit 6
  fi
  printf '%s' "$ours_json" > "$WORK/ours.json"

  prs_json="$(open_prs)"
  if [ -z "$prs_json" ]; then
    say "the open pull requests of the upstream could not be read: the guard does not know"
    exit 6
  fi
  if ! prs_count="$(printf '%s' "$prs_json" | count_of_list)"; then
    say "the open pull requests of the upstream could not be read: the guard does not know"
    exit 6
  fi
  if [ "$prs_count" -ge "$CLAIM_PR_LIMIT" ]; then
    say "the open pull requests of the upstream are truncated ($prs_count of $CLAIM_PR_LIMIT): the guard does not know"
    exit 6
  fi
  printf '%s' "$prs_json" > "$WORK/prs.json"

  dupes="$(python3 - "$WORK/ours.json" "$WORK/prs.json" "$WORK/sentences.txt" <<'PY'
import json
import re
import sys

ours_path, prs_path, sentences_path = sys.argv[1:4]


def number_of(pr):
    try:
        return int(pr.get("number"))
    except (TypeError, ValueError):
        return None


def mentions(pr):
    text = "%s\n%s" % (pr.get("title") or "", pr.get("body") or "")
    return set(re.findall(r"#(\d+)", text))


with open(ours_path, encoding="utf-8") as fh:
    ours = json.load(fh)
with open(prs_path, encoding="utf-8") as fh:
    prs = json.load(fh)

sentences = []
for pr in ours:
    ours_number = number_of(pr)
    if ours_number is None:
        continue
    ours_issues = mentions(pr)
    if not ours_issues:
        continue
    for other in prs:
        other_number = number_of(other)
        if other_number is None or other_number >= ours_number:
            continue
        for issue in sorted(ours_issues & mentions(other), key=int):
            print("duplicate: ours=%d other=%d issue=#%s"
                  % (ours_number, other_number, issue))
            sentences.append(
                "our pull request #%d lost the race for the issue #%s: the open "
                "pull request #%d has a lower number and it wins"
                % (ours_number, issue, other_number))

with open(sentences_path, "w", encoding="utf-8") as fh:
    for sentence in sentences:
        fh.write(sentence + "\n")
PY
)"
  status=$?
  if [ "$status" -ne 0 ]; then
    say "the open pull requests could not be compared: the guard does not know"
    exit 6
  fi

  if [ -z "$dupes" ]; then
    say "no duplicate was found: every open pull request of ours keeps the claim of its issue"
    exit 0
  fi

  printf '%s\n' "$dupes"
  while IFS= read -r sentence; do
    [ -n "$sentence" ] || continue
    say "$sentence"
  done < "$WORK/sentences.txt"
  exit 1
fi

# --- the mode of one issue -------------------------------------------------
# THE CLAIM IS DECIDED BY THE RULE (bin/claim-race.sh) and by nobody else.
# The same question, the same answer and the same vocabulary as the brake
# of the publisher (bin/claim-brake.sh) and the verifier of the orchestrator
# (bin/claim-verify.sh): there is ONE implementation of the claim.
#
# This script only TRANSLATES the verdict of the rule into the codes that
# the guard has always returned (0/2/3/4/5/6), because the prompts and the
# callers of the guard read those codes:
#
#   OK        -> 0 (the claim can be made)
#   TAKEN     -> 3 (an open PR already holds the claim)
#   RESOLVED  -> 2 (the excluded label) or 4 (the issue is not open)
#   UNKNOWN   -> 6 (the guard does NOT know)
#
# The queue of the loop (the ceiling) is NOT part of the claim: it is the
# policy of the loop and it stays here.
case "$ISSUE" in
  ''|*[!0-9]*) say "the usage is: claim-guard.sh <issue> | --candidates | --duplicates"; exit 1 ;;
esac

RULE="$SCRIPT_DIR/claim-race.sh"
if [ ! -f "$RULE" ]; then
  say "the rule of the claim is not there: $RULE"
  exit 6
fi
RULE_ARGS=(--issue "$ISSUE" --mode funnel --repo "$UPSTREAM")
[ -n "$OURS_PR" ] && RULE_ARGS+=(--pr "$OURS_PR")
RULE_ERR="$(mktemp "${TMPDIR:-/tmp}/claim-guard-rule.XXXXXX")"
RULE_OUT="$(bash "$RULE" "${RULE_ARGS[@]}" 2>"$RULE_ERR")"
RULE_RC=$?
cat "$RULE_ERR" >&2
rm -f "$RULE_ERR"
RULE_VERDICT="$(printf '%s\n' "$RULE_OUT" | sed -n 's/^VERDICT=//p' | head -1)"
RULE_REASON="$(printf '%s\n' "$RULE_OUT" | sed -n 's/^REASON=//p' | head -1)"
RULE_HOLDER="$(printf '%s\n' "$RULE_OUT" | sed -n 's/^HOLDER=//p' | head -1)"
case "$RULE_VERDICT" in
  OK)
    ;;
  TAKEN|LOST)
    say "the open PR(s) ${RULE_HOLDER:-?} hold the claim of the issue #$ISSUE"
    exit 3
    ;;
  RESOLVED)
    if [ "$RULE_REASON" = "excluded-label" ]; then
      say "the issue #$ISSUE carries the excluded label(s): $RULE_REASON"
      exit 2
    fi
    say "the issue #$ISSUE is not OPEN any more ($RULE_REASON): the claim is dropped"
    exit 4
    ;;
  *)
    say "the claim of the issue #$ISSUE could not be verified ($RULE_REASON): the guard does not know"
    exit 6
    ;;
esac

# The ceiling of the queue: the loop opens PRs, it does not pile them up.
if ! our_open_prs_to_file "$WORK/ours.json"; then
  say "our open PRs could not be counted: the guard does not know"
  exit 6
fi
queue_of_the_loop "$WORK/ours.json"
queue_report
if [ "$QUEUE_LOOP" -ge "$MAINT_THRESHOLD" ]; then
  say "our open PRs of the loop are $QUEUE_LOOP and the ceiling is $MAINT_THRESHOLD:"
  say "the claim is dropped until the maintainer merges some"
  exit 5
fi

say "the issue #$ISSUE can be claimed (our open PRs of the loop: $QUEUE_LOOP/$MAINT_THRESHOLD)"
exit 0
