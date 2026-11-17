#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# claim-salvage.sh - the work of a claim that was lost is NOT thrown away.
#
# WHY THIS EXISTS (01-11-2026): we lost the work of four issues because the
# claim of the issue was taken by another agent while we were working on it
# (#10134, #10138, #10079 and #10306). The work of #10306 survived only as a
# RED diff that a human saved by hand in logs/. A rule that is not in a
# script is a rule that is forgotten, and the same thing happened four times.
#
# WHAT IT DOES, in one call:
#   1. it COLLECTS the work (the diff of the branch against its base, and the
#      list of the commits) and writes it to a patch that survives the
#      removal of the worktree;
#   2. it DOCUMENTS what happened, in words a human and another agent can
#      read: who holds the claim now, what the work was, and the three ways
#      forward;
#   3. it writes the same thing as JSON, so the orchestrator can show it
#      without reading the prose;
#   4. it NEVER deletes anything: not the branch, not the worktree, not the
#      patch. The work of a lost claim is worth MORE than a lost claim: it is
#      a fix that can be re-targeted to another issue, or an offer on the
#      pull request that won the race.
#
# THE TWO CASES ARE DIFFERENT AND THEY GET DIFFERENT NOTES:
#   * LOST     somebody else holds the claim with a LOWER number: our work
#              is a DUPLICATE of theirs. The next step is to offer it there
#              or to re-target it to another free issue.
#   * RESOLVED the issue is not open any more: it was fixed by somebody
#              else. Nobody won a race against us: the work is MOOT for that
#              issue, and the next step is to re-target it, or to let it go
#              with the reason written down.
#
# USAGE:
#   bash bin/claim-salvage.sh --issue N --pr OUR_PR \
#        [--verdict LOST|RESOLVED] [--holder PR] [--holder-author LOGIN] \
#        [--work DIR] [--branch NAME] [--base REF] [--out DIR] \
#        [--note TEXT] [--title TEXT]
#
# EXIT CODES:
#   0  the work was collected and documented
#   1  the arguments are wrong
#   2  the work could not be collected (the directory is not a repository):
#      the note is STILL written, because a lost claim with no saved work is
#      exactly the case that has to be reported
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"

ISSUE=""
OUR_PR=""
VERDICT="LOST"
HOLDER=""
HOLDER_AUTHOR=""
WORK=""
BRANCH=""
BASE=""
OUT=""
NOTE=""
TITLE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)         ISSUE="$2"; shift 2 ;;
    --pr)            OUR_PR="$2"; shift 2 ;;
    --verdict)       VERDICT="$2"; shift 2 ;;
    --holder)        HOLDER="$2"; shift 2 ;;
    --holder-author) HOLDER_AUTHOR="$2"; shift 2 ;;
    --work)          WORK="$2"; shift 2 ;;
    --branch)        BRANCH="$2"; shift 2 ;;
    --base)          BASE="$2"; shift 2 ;;
    --out)           OUT="$2"; shift 2 ;;
    --note)          NOTE="$2"; shift 2 ;;
    --title)         TITLE="$2"; shift 2 ;;
    -h|--help)       awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "claim-salvage: unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "claim-salvage: --issue needs the number of the issue" >&2
  exit 1
fi
case "$VERDICT" in
  LOST|RESOLVED|UNKNOWN) ;;
  *) echo "claim-salvage: --verdict has to be LOST, RESOLVED or UNKNOWN" >&2; exit 1 ;;
esac

# The directory of the salvaged work. The default is the logs of the loop,
# because the loop is where the shared scripts live; the orchestrator passes
# its own directory.
[ -n "$OUT" ] || OUT="$LOOP_DIR/logs/claims-lost"
mkdir -p "$OUT" || { echo "claim-salvage: $OUT could not be created" >&2; exit 2; }

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STEM="issue-$ISSUE-pr${OUR_PR:-none}-claim-$VERDICT"
DIFF_FILE="$OUT/$STEM.diff"
NOTE_FILE="$OUT/$STEM.md"
JSON_FILE="$OUT/$STEM.json"

say() { echo "claim-salvage: $*" >&2; }

# --- the work ---------------------------------------------------------------
# The diff is the work: without it there is nothing to re-target and nothing
# to offer. It is written with --binary so that a change of a binary file
# survives the salvage too.
COMMITS=""
FILES=""
COLLECTED="no"
if [ -n "$WORK" ] && [ -d "$WORK" ] && git -C "$WORK" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -z "$BRANCH" ]; then
    BRANCH="$(git -C "$WORK" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [ "$BRANCH" = "HEAD" ] && BRANCH=""
  fi
  if [ -z "$BASE" ]; then
    # The base of the change: the main of the upstream when it is there, and
    # the main of the repository otherwise. The base is a guess, and a wrong
    # guess only makes the diff bigger, never wrong: a diff that carries
    # MORE of the change is still a fix.
    for candidate in origin/main main upstream/main; do
      if git -C "$WORK" rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
        BASE="$candidate"
        break
      fi
    done
    [ -n "$BASE" ] || BASE="HEAD"
  fi
  {
    echo "# the work of the issue #$ISSUE (the claim was $VERDICT)"
    echo "# branch: ${BRANCH:-<detached>}"
    echo "# base: $BASE"
    if [ -n "$BRANCH" ] && git -C "$WORK" rev-parse --verify --quiet "$BRANCH" >/dev/null 2>&1; then
      echo "# commits:"
      git -C "$WORK" log --oneline "$BASE..$BRANCH" 2>/dev/null | sed 's/^/#   /'
      git -C "$WORK" diff --binary "$BASE...$BRANCH" 2>/dev/null
    else
      git -C "$WORK" diff --binary "$BASE" 2>/dev/null
    fi
    # The work that is not committed yet is work too: it is what the agent
    # wrote in the last minutes before the claim was lost.
    git -C "$WORK" diff --binary 2>/dev/null
  } > "$DIFF_FILE" 2>/dev/null
  if [ -n "$BRANCH" ] && git -C "$WORK" rev-parse --verify --quiet "$BRANCH" >/dev/null 2>&1; then
    COMMITS="$(git -C "$WORK" log --oneline "$BASE..$BRANCH" 2>/dev/null | head -20)"
    FILES="$(git -C "$WORK" diff --name-only "$BASE...$BRANCH" 2>/dev/null | head -40)"
  else
    FILES="$(git -C "$WORK" diff --name-only "$BASE" 2>/dev/null | head -40)"
  fi
  COLLECTED="yes"
else
  # No work to collect (the worktree is already gone, or there never was
  # one). The note is written anyway: a lost claim with no saved work is
  # exactly the case that has to be REPORTED.
  : > "$DIFF_FILE"
  say "there is no work to collect (no repository at '${WORK:-<none>}')"
fi

# --- the note ---------------------------------------------------------------
# The note is written for a reader that did not live the story: the next
# agent, or a human in a week. It says what happened, who holds the claim,
# what the work is, and what can be done with it.
{
  echo "# The claim of the issue #$ISSUE was lost"
  echo
  echo "- when: $STAMP"
  echo "- our pull request: ${OUR_PR:-<none>}"
  echo "- verdict: $VERDICT"
  if [ "$VERDICT" = "LOST" ]; then
    echo "- who holds the claim now: the open pull request #${HOLDER:-<unknown>}" \
         "${HOLDER_AUTHOR:+by $HOLDER_AUTHOR} (its number is LOWER: the lowest numbered open pull request wins)"
  elif [ "$VERDICT" = "UNKNOWN" ]; then
    echo "- who holds the claim now: UNKNOWN: GitHub could not be read, so the brake does not know" \
         "(the work is saved because a check that fails is not a check)"
  else
    echo "- who holds the claim now: nobody won a race against us: the issue is not open any more" \
         "(it was closed or fixed by somebody else). The work is MOOT for this issue, not lost."
  fi
  [ -n "$TITLE" ] && echo "- title: $TITLE"
  [ -n "$NOTE" ] && echo "- note: $NOTE"
  echo
  echo "## The work"
  echo
  if [ "$COLLECTED" = "yes" ]; then
    echo "- worktree: $WORK"
    echo "- branch: ${BRANCH:-<detached>}"
    echo "- base: $BASE"
    echo "- patch: $DIFF_FILE"
    if [ -n "$COMMITS" ]; then
      echo "- commits:"
      printf '%s\n' "$COMMITS" | sed 's/^/    /'
    fi
    if [ -n "$FILES" ]; then
      echo "- files changed:"
      printf '%s\n' "$FILES" | sed 's/^/    /'
    fi
  else
    echo "- there was no work to collect: the patch is empty"
    echo "- patch: $DIFF_FILE"
  fi
  echo
  echo "## What can be done with it"
  echo
  if [ "$VERDICT" = "LOST" ]; then
    echo "1. OFFER it: the pull request that won the race (#${HOLDER:-?}) may want the same fix."
    echo "   Comment there with the patch; do not open a second pull request for this issue."
  elif [ "$VERDICT" = "UNKNOWN" ]; then
    echo "1. VERIFY it: the claim could not be checked, so nobody knows who holds it."
    echo "   Re-run the claim check by hand before deciding what to do with the work."
  else
    echo "1. RE-TARGET it: the fix may still be needed for another open issue that nobody claimed."
  fi
  echo "2. RE-TARGET it: the change may apply to another free issue (the patch is the input)."
  echo "3. LET IT GO: the note says why, so nobody has to rediscover it."
  echo
  echo "The branch and the worktree were NOT deleted: the work is still there."
} > "$NOTE_FILE"

# --- the record -------------------------------------------------------------
# The same thing as JSON, so that the orchestrator can list the salvaged
# claims without reading the prose of the notes.
python3 - "$JSON_FILE" "$ISSUE" "$OUR_PR" "$VERDICT" "$HOLDER" "$HOLDER_AUTHOR" \
          "$WORK" "$BRANCH" "$BASE" "$DIFF_FILE" "$NOTE_FILE" "$COLLECTED" \
          "$STAMP" "$TITLE" <<'PY'
import json
import sys

(path, issue, pr, verdict, holder, holder_author, work, branch, base,
 diff, note, collected, stamp, title) = sys.argv[1:15]

record = {
    "issue": int(issue),
    "pr": int(pr) if pr.isdigit() else None,
    "verdict": verdict,
    "holder_pr": int(holder) if holder.isdigit() else None,
    "holder_author": holder_author or None,
    "at": stamp,
    "title": title or None,
    "work": {
        "collected": collected == "yes",
        "worktree": work or None,
        "branch": branch or None,
        "base": base or None,
        "patch": diff,
    },
    "note": note,
    "next": (["offer it on the pull request that won the race",
              "re-target the patch to another free issue",
              "let it go: the reason is written down"]
             if verdict == "LOST" else
             ["verify by hand who holds the claim: the check could not be read",
              "re-target the patch to another free issue",
              "let it go: the reason is written down"]
             if verdict == "UNKNOWN" else
             ["re-target the patch to another free issue",
              "let it go: the issue was fixed by somebody else"]),
}

with open(path, "w", encoding="utf-8") as fh:
    json.dump(record, fh, ensure_ascii=False, indent=1)
    fh.write("\n")
PY

printf 'SALVAGE_NOTE=%s\n' "$NOTE_FILE"
printf 'SALVAGE_DIFF=%s\n' "$DIFF_FILE"
printf 'SALVAGE_JSON=%s\n' "$JSON_FILE"
say "the work of the issue #$ISSUE ($VERDICT) was saved in $OUT"
exit 0
