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
#   4. it NEVER deletes the branch, and (without --release) it never deletes
#      the worktree either: the work of a lost claim is worth MORE than a
#      lost claim: it is a fix that can be re-targeted to another issue, or
#      an offer on the pull request that won the race.
#
# THE RELEASE (--release): freeing the slot of a lost claim, in the ONLY
# order that does not throw the work away:
#
#   1. THE BRAKE FIRST (bin/claim-brake.sh, with --no-salvage so it does not
#      call this script back). The brake is the only one that knows whether
#      the claim is really lost. If it does not answer, or if it answers
#      that the claim is still OURS, NOTHING is deleted: the worktree stays
#      exactly where it is. A check that fails is not a check.
#   2. THE WORK THAT WAS NOT COMMITTED is saved into a rescue directory with
#      a timestamp: the patch of what the agent changed (staged and unstaged)
#      and a tarball of the files it created. The path is reported
#      (SALVAGE_RESCUE) and written in the note and in the JSON.
#   3. ONLY THEN the worktree is released, and it is released SAFELY:
#      `git worktree remove` WITHOUT --force, and when git refuses (the tree
#      is dirty, which is the normal case here) the directory is MOVED to a
#      quarantine directory instead of being deleted. Nothing is ever removed
#      with --force and nothing is ever removed with a blind `rm -rf`: this
#      is a shared machine.
#   4. The lock of the slot is released (bin/slot-lock.sh), the same way.
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
#        [--verdict LOST|RESOLVED|UNKNOWN] [--holder PR] [--holder-author LOGIN] \
#        [--holder-login LOGIN] \
#        [--work DIR] [--branch NAME] [--base REF] [--out DIR] \
#        [--note TEXT] [--title TEXT]
#
#   bash bin/claim-salvage.sh --issue N --work DIR --slot NAME [--release]
#
# EXIT CODES:
#   0  the work was collected and documented (and the slot was released, if
#      --release was asked for)
#   1  the arguments are wrong
#   2  the work could not be collected (the directory is not a repository):
#      the note is STILL written, because a lost claim with no saved work is
#      exactly the case that has to be reported
#   3  the release was NOT done: the brake says the claim is still OURS
#   4  the release was NOT done: the brake could not confirm that the claim
#      is lost (GitHub could not be read, or the brake could not run)
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# The orchestrator half: it knows how a slot lock is named and taken.
ORCH_DIR="${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}"

ISSUE=""
OUR_PR=""
VERDICT="LOST"
HOLDER=""
HOLDER_AUTHOR=""
HOLDER_LOGIN=""
WORK=""
BRANCH=""
BASE=""
OUT=""
NOTE=""
TITLE=""
RELEASE=0
SLOT=""
LOCK_DIR="${LOCK_DIR:-$ORCH_DIR/locks}"
LOCK_DIR_EXPLICIT=0
SLOT_LOCK_SCRIPT="${SLOT_LOCK_SCRIPT:-$ORCH_DIR/bin/slot-lock.sh}"
BRAKE="${BRAKE:-$SCRIPT_DIR/claim-brake.sh}"
QUARANTINE_DIR="${QUARANTINE_DIR:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)         ISSUE="$2"; shift 2 ;;
    --pr)            OUR_PR="$2"; shift 2 ;;
    --verdict)       VERDICT="$2"; shift 2 ;;
    --holder)        HOLDER="$2"; shift 2 ;;
    --holder-author) HOLDER_AUTHOR="$2"; shift 2 ;;
    --holder-login)  HOLDER_LOGIN="$2"; shift 2 ;;
    --work)          WORK="$2"; shift 2 ;;
    --branch)        BRANCH="$2"; shift 2 ;;
    --base)          BASE="$2"; shift 2 ;;
    --out)           OUT="$2"; shift 2 ;;
    --note)          NOTE="$2"; shift 2 ;;
    --title)         TITLE="$2"; shift 2 ;;
    --release)       RELEASE=1; shift ;;
    --slot)          SLOT="$2"; shift 2 ;;
    --lock-dir)      LOCK_DIR="$2"; LOCK_DIR_EXPLICIT=1; shift 2 ;;
    --slot-lock-script) SLOT_LOCK_SCRIPT="$2"; shift 2 ;;
    --brake)         BRAKE="$2"; shift 2 ;;
    --quarantine-dir) QUARANTINE_DIR="$2"; shift 2 ;;
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

# A slot to free means a release. The two are the same decision: naming the
# slot is naming the worktree of that slot and the lock of that slot.
[ -n "$SLOT" ] && RELEASE=1

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

# The rescue directory: where the work that was NOT committed survives. It
# has the timestamp in its name, so two rescues of the same issue do not
# overwrite each other.
RESCUE_DIR="$OUT/rescue/$ISSUE-$STAMP"
# The quarantine: where a worktree that git refuses to remove goes. It is a
# MOVE, never a deletion. It defaults to a SIBLING of the worktree, so the
# move is a rename in the same filesystem and not a copy of a whole checkout
# (and it never lands in a directory that is cleaned up by a cron).
[ -n "$QUARANTINE_DIR" ] || QUARANTINE_DIR=""

say() { echo "claim-salvage: $*" >&2; }

# --- the brake ---------------------------------------------------------------
# THE BRAKE RUNS FIRST, BEFORE ANYTHING IS DELETED. It is the only one that
# knows whether the claim is really lost. The brake is called with
# --no-salvage so it does not call THIS script back (that would be a loop).
BRAKE_RC=0
BRAKE_VERDICT=""
BRAKE_OUT=""
if [ "$RELEASE" = 1 ]; then
  if [ -n "${CLAIM_SALVAGE_FROM_BRAKE:-}" ]; then
    # The brake is the caller (it set this variable): it already asked the
    # rule, so the brake is not asked again.
    BRAKE_VERDICT="$VERDICT"
    BRAKE_RC=0
  elif [ ! -f "$BRAKE" ]; then
    say "there is no brake to ask: $BRAKE"
    BRAKE_RC=4
  else
    BRAKE_ARGS=(--issue "$ISSUE" --mode auto --no-salvage)
    [ -n "$OUR_PR" ] && BRAKE_ARGS+=(--pr "$OUR_PR")
    [ -n "$WORK" ] && BRAKE_ARGS+=(--work "$WORK")
    [ -n "$BRANCH" ] && BRAKE_ARGS+=(--branch "$BRANCH")
    [ -n "$BASE" ] && BRAKE_ARGS+=(--base "$BASE")
    BRAKE_ERR="$(mktemp "${TMPDIR:-/tmp}/claim-salvage-brake.XXXXXX")"
    BRAKE_OUT="$(bash "$BRAKE" "${BRAKE_ARGS[@]}" 2>"$BRAKE_ERR")"
    BRAKE_RC=$?
    cat "$BRAKE_ERR" >&2
    rm -f "$BRAKE_ERR"
    BRAKE_VERDICT="$(printf '%s\n' "$BRAKE_OUT" | sed -n 's/^VERDICT=//p' | head -1)"
  fi
  say "the brake answered '$BRAKE_VERDICT' (rc=$BRAKE_RC)"
fi

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
    # wrote in the last minutes before the claim was lost. The staged half
    # is here too (`git diff` alone only shows the unstaged half), and the
    # files the agent CREATED are listed: a diff cannot carry a file that
    # git does not know about yet.
    echo "# the work that was NOT committed (staged and unstaged):"
    git -C "$WORK" diff --binary HEAD 2>/dev/null
    echo "# the files the agent created and did not add:"
    git -C "$WORK" ls-files --others --exclude-standard 2>/dev/null | sed 's/^/#   /'
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

# --- the rescue of the work that was NOT committed --------------------------
# The rescue directory: the work that the agent left uncommitted is saved
# HERE, with the timestamp in the name, BEFORE the worktree is touched.
# Three pieces, because one is not enough:
#   * uncommitted.patch  - the changes of the tracked files (staged and
#                          unstaged), ready to be applied with `git apply`
#   * untracked.tar.gz   - the files the agent CREATED and never added: a
#                          patch cannot carry them
#   * committed.patch    - a copy of the diff of the branch, so the rescue
#                          directory is self-contained
#   * status.txt         - what git saw, for a human that has to read it
RESCUE_STATUS="not asked"
RESCUE_PATCH=""
RESCUE_TARBALL=""
RESCUE_STATUS_FILE=""
if [ "$RELEASE" = 1 ] && [ "$COLLECTED" = "yes" ]; then
  if mkdir -p "$RESCUE_DIR" 2>/dev/null; then
    RESCUE_PATCH="$RESCUE_DIR/uncommitted.patch"
    RESCUE_TARBALL="$RESCUE_DIR/untracked.tar.gz"
    RESCUE_STATUS_FILE="$RESCUE_DIR/status.txt"
    git -C "$WORK" diff --binary HEAD > "$RESCUE_PATCH" 2>/dev/null
    if [ ! -s "$RESCUE_PATCH" ]; then
      # An unborn HEAD (the agent did not commit anything) has no diff
      # against HEAD: the staged and the unstaged halves are taken apart.
      {
        git -C "$WORK" diff --binary --cached 2>/dev/null
        git -C "$WORK" diff --binary 2>/dev/null
      } > "$RESCUE_PATCH" 2>/dev/null
    fi
    cp -f "$DIFF_FILE" "$RESCUE_DIR/committed.patch" 2>/dev/null || true
    git -C "$WORK" status --porcelain=v1 > "$RESCUE_STATUS_FILE" 2>/dev/null
    # The files the agent CREATED. There are two kinds and the rescue needs
    # both: the ones git does not know about (never added) and the ones that
    # were added but never committed. The second kind is in the patch
    # already, but the raw bytes of both are in the tarball, because a
    # patch cannot carry a file that was never committed.
    {
      git -C "$WORK" ls-files --others --exclude-standard -z 2>/dev/null
      git -C "$WORK" diff --cached --name-only --diff-filter=A -z 2>/dev/null
    } | sort -zu > "$RESCUE_DIR/untracked.list" 2>/dev/null
    if [ -s "$RESCUE_DIR/untracked.list" ]; then
      tar --null -czf "$RESCUE_TARBALL" -C "$WORK" -T "$RESCUE_DIR/untracked.list" 2>/dev/null \
        || RESCUE_TARBALL=""
    else
      rm -f "$RESCUE_TARBALL"
    fi
    RESCUE_STATUS="saved"
    say "the work that was not committed is saved in $RESCUE_DIR"
  else
    RESCUE_STATUS="could not be saved ($RESCUE_DIR)"
    say "the rescue directory could not be created: $RESCUE_DIR"
  fi
elif [ "$RELEASE" = 1 ]; then
  RESCUE_STATUS="there was no work to save"
fi

# --- the release of the worktree ---------------------------------------------
# The worktree is released AFTER the brake and AFTER the rescue: those two
# are above this line, and that is the whole point of the order.
#
# It is released SAFELY: `git worktree remove` WITHOUT --force (git refuses
# to remove a tree with changes, which is what we want: we do not delete a
# tree that still holds work), and when git refuses, the directory is MOVED
# to the quarantine instead of being deleted. A shared machine does not
# deserve a blind `rm -rf`.
WORKTREE_ACTION="not asked"
# Only a brake that CONFIRMS that the claim is lost authorizes a release.
# rc 0 is "the claim is still ours" and rc 12 is "the brake does not know":
# in both cases the slot is left alone, because a check that fails is not a
# check and a claim that is ours is not lost.
RELEASE_ALLOWED=0
if [ "$RELEASE" = 1 ]; then
  case "$BRAKE_RC" in
    0)
      if [ "$BRAKE_VERDICT" = "OK" ] || [ -z "$BRAKE_VERDICT" ]; then
        WORKTREE_ACTION="kept: the brake says the claim is still ours"
        say "the claim of the issue #$ISSUE is still ours: the worktree is NOT touched"
      else
        WORKTREE_ACTION="removed"
        RELEASE_ALLOWED=1
      fi
      ;;
    10|11)
      WORKTREE_ACTION="to be released"
      RELEASE_ALLOWED=1
      ;;
    *)
      WORKTREE_ACTION="kept: the brake could not confirm that the claim is lost"
      ;;
  esac

  if [ "$WORKTREE_ACTION" = "to be released" ]; then
    if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
      WORKTREE_ACTION="there was no worktree to release"
    else
      # The repository that owns the worktree: the common git dir is the
      # .git of the main checkout, and its parent is the checkout itself.
      REPO_ROOT="$(git -C "$WORK" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
      [ -n "$REPO_ROOT" ] && REPO_ROOT="$(dirname "$REPO_ROOT")"
      if [ -z "$REPO_ROOT" ]; then
        WORKTREE_ACTION="kept: the repository of the worktree is unknown"
      elif git -C "$REPO_ROOT" worktree remove "$WORK" >/dev/null 2>&1; then
        # git removed it: the tree was clean, so nothing was lost.
        WORKTREE_ACTION="removed ($WORK)"
        say "the worktree of the issue #$ISSUE was removed ($WORK)"
      else
        # git refused (the tree has changes). The directory is MOVED to the
        # quarantine: the work stays on this machine and the path of the
        # worktree is free for the next turn. The quarantine is a SIBLING of
        # the worktree unless the caller named one, so the move is a rename
        # and not a copy of a whole checkout.
        QD="${QUARANTINE_DIR:-$(dirname "$WORK")/.quarantine}"
        mkdir -p "$QD" 2>/dev/null || true
        QTARGET="$QD/$(basename "$WORK")-$STAMP"
        if mv "$WORK" "$QTARGET" 2>/dev/null; then
          # The bookkeeping of the worktree goes with it: the entry of a
          # worktree whose directory is gone is stale.
          git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
          WORKTREE_ACTION="quarantined ($QTARGET)"
          say "the worktree was moved to the quarantine: $QTARGET"
        else
          WORKTREE_ACTION="kept ($WORK): it could not be released and it could not be quarantined"
          say "the worktree of the issue #$ISSUE could NOT be released: $WORK"
        fi
      fi
    fi
  fi
fi

# --- the release of the lock of the slot -------------------------------------
LOCK_STATUS="not asked"
if [ "$RELEASE" = 1 ] && [ -n "$SLOT" ]; then
  if [ "$RELEASE_ALLOWED" != "1" ]; then
    # The brake did not confirm that the claim is lost: the lock of the
    # slot stays taken, because a slot that is still working is a slot that
    # is still busy.
    LOCK_STATUS="kept: the brake did not confirm that the claim is lost"
  else
    # The name of the lock is normalized the same way bin/slot-lock.sh
    # normalizes it, so both paths free the SAME lock.
  LOCK_NAME="$(printf '%s' "$SLOT" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '-' | cut -c1-60)"
  case "$LOCK_NAME" in
    ""|.|..|*..*|.*|-*)
      LOCK_STATUS="the name of the slot is not usable: $SLOT"
      ;;
    *)
      LOCK_PATH="$LOCK_DIR/slot-$LOCK_NAME"
      if [ ! -d "$LOCK_PATH" ]; then
        LOCK_STATUS="free (there was no lock)"
      elif [ "$LOCK_DIR_EXPLICIT" = "1" ]; then
        # The caller named the directory of the locks, so the lock is freed
        # HERE and not wherever the helper script would look: a shared
        # machine does not get its locks freed by accident. It is done
        # WITHOUT a blind `rm -rf`: the lock is a directory with the
        # identity of its owner inside, and it is emptied file by file and
        # removed.
        for f in "$LOCK_PATH"/*; do
          [ -f "$f" ] || continue
          rm -f "$f" 2>/dev/null || true
        done
        if rmdir "$LOCK_PATH" 2>/dev/null; then
          LOCK_STATUS="released"
        else
          LOCK_STATUS="could not be released ($LOCK_PATH)"
        fi
      elif [ -f "$SLOT_LOCK_SCRIPT" ]; then
        # The orchestrator knows how a slot lock is taken and released: it
        # is used when it is there, and it is the one that frees it.
        if bash "$SLOT_LOCK_SCRIPT" --slot "$SLOT" --release >/dev/null 2>&1; then
          if [ -d "$LOCK_PATH" ]; then
            LOCK_STATUS="could not be released ($LOCK_PATH)"
          else
            LOCK_STATUS="released"
          fi
        else
          LOCK_STATUS="could not be released"
        fi
      else
        # The same thing by hand, and WITHOUT a blind `rm -rf`.
        for f in "$LOCK_PATH"/*; do
          [ -f "$f" ] || continue
          rm -f "$f" 2>/dev/null || true
        done
        if rmdir "$LOCK_PATH" 2>/dev/null; then
          LOCK_STATUS="released"
        else
          LOCK_STATUS="could not be released ($LOCK_PATH)"
        fi
      fi
      ;;
  esac
  say "the lock of the slot $SLOT: $LOCK_STATUS"
  fi
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
  [ -n "$HOLDER_LOGIN" ] && echo "- who holds it: @$HOLDER_LOGIN"
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
  if [ "$RELEASE" = 1 ]; then
    echo
    echo "## The release of the slot"
    echo
    echo "- the brake said: $BRAKE_VERDICT (rc=$BRAKE_RC)"
    echo "- the work that was NOT committed: $RESCUE_STATUS"
    if [ -n "$RESCUE_DIR" ] && [ "$RESCUE_STATUS" = "saved" ]; then
      echo "- the rescue directory: $RESCUE_DIR"
      [ -n "$RESCUE_PATCH" ] && echo "    - the uncommitted changes (patch): $RESCUE_PATCH"
      [ -n "$RESCUE_TARBALL" ] && echo "    - the files the agent created (tarball): $RESCUE_TARBALL"
      [ -n "$RESCUE_STATUS_FILE" ] && echo "    - what git saw: $RESCUE_STATUS_FILE"
    fi
    echo "- the worktree: $WORKTREE_ACTION"
    [ -n "$SLOT" ] && echo "- the lock of the slot $SLOT: $LOCK_STATUS"
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
  if [ "$RELEASE" = 1 ]; then
    echo "The branch was NOT deleted: the work is still there."
    echo "The worktree was released only after the brake answered and after the"
    echo "work that was not committed was saved (see the rescue directory above)."
  else
    echo "The branch and the worktree were NOT deleted: the work is still there."
  fi
} > "$NOTE_FILE"

# --- the record -------------------------------------------------------------
# The same thing as JSON, so that the orchestrator can list the salvaged
# claims without reading the prose of the notes.
python3 - "$JSON_FILE" "$ISSUE" "$OUR_PR" "$VERDICT" "$HOLDER" "$HOLDER_AUTHOR" \
          "$WORK" "$BRANCH" "$BASE" "$DIFF_FILE" "$NOTE_FILE" "$COLLECTED" \
          "$STAMP" "$TITLE" "$HOLDER_LOGIN" "$RESCUE_DIR" "$RESCUE_STATUS" \
          "$RESCUE_PATCH" "$RESCUE_TARBALL" "$RESCUE_STATUS_FILE" \
          "$WORKTREE_ACTION" "$SLOT" "$LOCK_STATUS" "$BRAKE_VERDICT" "$BRAKE_RC" <<'PY'
import json
import sys

(path, issue, pr, verdict, holder, holder_author, work, branch, base,
 diff, note, collected, stamp, title, holder_login, rescue_dir, rescue_status,
 rescue_patch, rescue_tarball, rescue_status_file,
 worktree_action, slot, lock_status, brake_verdict, brake_rc) = sys.argv[1:26]

record = {
    "issue": int(issue),
    "pr": int(pr) if pr.isdigit() else None,
    "verdict": verdict,
    "holder_pr": int(holder) if holder.isdigit() else None,
    "holder_author": holder_author or None,
    "holder_login": holder_login or None,
    "at": stamp,
    "title": title or None,
    "work": {
        "collected": collected == "yes",
        "worktree": work or None,
        "branch": branch or None,
        "base": base or None,
        "patch": diff,
    },
    "rescue": {
        "status": rescue_status,
        "dir": rescue_dir or None,
        "uncommitted_patch": rescue_patch or None,
        "untracked_tarball": rescue_tarball or None,
        "status_file": rescue_status_file or None,
    },
    "release": {
        "brake_verdict": brake_verdict or None,
        "brake_rc": int(brake_rc) if brake_rc.isdigit() else None,
        "worktree": worktree_action,
        "slot": slot or None,
        "lock": lock_status,
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
[ "$RESCUE_STATUS" = "saved" ] && printf 'SALVAGE_RESCUE=%s\n' "$RESCUE_DIR"
say "the work of the issue #$ISSUE ($VERDICT) was saved in $OUT"

# The exit code says what happened, and it says it AFTER everything was
# written: the note and the JSON are there even when the release did not
# happen, because a lost claim with no saved work is exactly the case that
# has to be reported.
if [ "$RELEASE" = 1 ]; then
  case "$BRAKE_RC" in
    0)
      if [ "$BRAKE_VERDICT" = "OK" ] || [ -z "$BRAKE_VERDICT" ]; then
        say "the claim of the issue #$ISSUE is still ours: nothing was released"
        exit 3
      fi
      ;;
    10|11) ;;
    *)
      say "the brake could not confirm that the claim of the issue #$ISSUE is lost (rc=$BRAKE_RC): nothing was released"
      exit 4
      ;;
  esac
  [ "$COLLECTED" = "yes" ] || exit 2
fi
exit 0
