#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# slot-stale.sh - WHICH SLOTS ARE STUCK? A slot is stuck when its lock is old
# and the branch has not moved: the agent is alive but it is not writing code.
#
# WHY THIS EXISTS: four agents in one session burned 5h30m, 6h15m, 7h and 4h20m
# on features and finished with zero commits and a clean worktree. All of them
# were alive the whole time, with the lock held, reading code. Nothing in the
# loop noticed: the lock said "in use" and the agent said "running".
#
# The liveness of a lock is NOT its owner and NOT its PID: it is its AGE plus
# whether the work moved. A slot whose lock is old AND whose branch has not
# changed since the lock was taken is an agent that is stuck.
#
# THE TWO MODES (2026-11-17): the watchdog asked GitHub five times (one call
# per pull request) and took 3m22s measured, and the summary of the state
# (orch-state.sh) paid that price every single time. So the script is split:
#
#   --locks   ONLY the state of the locks. It does NOT talk to GitHub at all:
#             milliseconds. It prints the lock lines and the count of the
#             stuck ones (and nothing else).
#   --prs     ONLY the part that needs GitHub: the worktrees without a lock
#             (whether they are residue is decided with the pull requests)
#             and the pull requests that wait for our answer.
#   (none)    BOTH, which is what the script always did.
#
# usage: bin/slot-stale.sh [--hours N] [--json] [--locks | --prs]
#   --hours N   how old a lock must be to count (default: 2)
#   --json      one JSON object per stuck slot
#
# EXIT CODES:
#   0  the verdict is known
#   2  bad usage
#   6  UNKNOWN: something could not be read (a lock, the state, GitHub). A
#      check that could not run is NOT a "no" (README, rule 7).
# ---------------------------------------------------------------------------
set -uo pipefail

# The paths come from the environment, with the default of THIS
# machine: the other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
REPO="${REPO:-$SOLIDCRAFT_REPO}"
LOCKS="$ORCH_DIR/locks"
SC_REPO="${SC_REPO:-tangency-labs/solidcraft}"
SC_OWNER="${SC_OWNER:-${SC_REPO%%/*}}"
SC_NAME="${SC_NAME:-${SC_REPO#*/}}"
AUTHOR="${AUTHOR:-vdirienzo}"
# The gh of the machine, or the one of a test (the stub lives OUTSIDE the
# PATH: README rule 4).
GH_BIN="${GH_BIN:-gh}"
PR_LIMIT="${SC_PR_LIMIT:-2000}"
HOURS=2
JSON=""
MODE=both

usage() {
  echo "usage: bin/slot-stale.sh [--hours N] [--json] [--locks | --prs]" >&2
}

want_locks=1
want_prs=1
seen_locks=0
seen_prs=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) [ $# -ge 2 ] || { usage; exit 2; }; HOURS="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    --locks) seen_locks=1; shift ;;
    --prs) seen_prs=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
if [ "$seen_locks" = "1" ] && [ "$seen_prs" = "1" ]; then
  echo "slot-stale: --locks and --prs are two different things" >&2
  exit 2
fi
case "$HOURS" in
  ''|*[!0-9]*) echo "slot-stale: --hours needs a number of hours" >&2; exit 2 ;;
esac
if [ "$seen_locks" = "1" ]; then
  MODE=locks; want_prs=0
elif [ "$seen_prs" = "1" ]; then
  MODE=prs; want_locks=0
else
  MODE=both
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/slot-stale.XXXXXX")" || exit 6
trap 'rm -rf "$TMP"' EXIT
ERRFILE="$TMP/err"
LAST_ERROR=""
# UNKNOWN: something could not be read. The verdict is NOT "no" (rule 7).
UNKNOWN=0
# How many slots could not be read. The boolean alone was not enough: with one
# stuck slot and one unknown slot, the summary said "1 slot(s) atascado(s)"
# and said nothing about the other, so the reader took the verdict for
# complete when it was not.
unknown_n=0

now="$(date +%s)"
stuck=0
stuck_nolock=0
residue=0

# unknown <message>: something could not be read.
unknown() {
  UNKNOWN=1
  unknown_n=$(( unknown_n + 1 ))
  printf 'slot-stale: %s\n' "$1" >&2
}

# read_first_line <file>
#   0 -> it was read (the value may be empty)
#   1 -> the file does not exist
#   2 -> it exists and it could NOT be read
#
# WHY (B16): a tool that fails and a tool that answers "there is nothing
# here" look the same when the error goes to /dev/null. Here they are NOT the
# same: a lock that could not be read is a lock whose age we do NOT know, and
# "we do not know" is not "there is nothing there".
read_first_line() {
  local f="$1" out=""
  [ -e "$f" ] || return 1
  if ! out="$(head -1 "$f" 2>"$ERRFILE")"; then
    LAST_ERROR="$(head -1 "$ERRFILE" 2>/dev/null)"
    return 2
  fi
  printf '%s' "$out"
  return 0
}

# json_num <value>: a number for the JSON. "?" is not a number, and a JSON
# with a bare "?" is not JSON at all: the reader of the --json output is a
# program.
json_num() {
  case "$1" in
    ''|*[!0-9]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

emit() { # emit <slot> <owner> <lock_age_h> <branch> <commits> <changed_ago_h>
  if [ -n "${JSON:-}" ]; then
    printf '{"slot":"%s","owner":"%s","lock_age_h":%s,"branch":"%s","commits":%s,"changed_ago_h":%s}\n' \
      "$1" "$2" "$(json_num "$3")" "$4" "$(json_num "$5")" "$(json_num "$6")"
  else
    printf '  slot %-8s lock de hace %-5sh  owner %-28s rama %-46s commits=%-3s sin moverse hace %sh\n' \
      "$1" "$3" "$2" "$4" "$5" "$6"
  fi
}

# ---------------------------------------------------------------------------
# THE STATE OF A WORKTREE: the branch, the commits and WHEN THE WORK MOVED.
# It fills WORK_BRANCH, WORK_COMMITS, WORK_CHANGED and WORK_UNKNOWN.
# ---------------------------------------------------------------------------
WORK_BRANCH=""; WORK_COMMITS="?"; WORK_CHANGED="0"; WORK_UNKNOWN=0
analyze_worktree() { # analyze_worktree <worktree>
  local worktree="$1" f m last idx
  WORK_BRANCH=""; WORK_COMMITS="?"; WORK_CHANGED="0"; WORK_UNKNOWN=0
  # A lock whose worktree is GONE is not "not stuck": it is a slot whose
  # state could not be read. Skipping it made the summary say "ningun slot
  # atascado" without having looked at that slot - the same blindness the
  # audit found (B2), only narrower. The lock still blocks, so it has to
  # be visible.
  [ -d "$worktree" ] || { WORK_UNKNOWN=1; return 0; }
  WORK_BRANCH="$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>"$ERRFILE")" || WORK_BRANCH=""
  [ "$WORK_BRANCH" = "HEAD" ] && WORK_BRANCH="(detached)"
  [ -n "$WORK_BRANCH" ] || return 0
  [ "$WORK_BRANCH" = "(detached)" ] && return 0
  WORK_COMMITS="$(git -C "$REPO" rev-list --count "origin/main..$WORK_BRANCH" 2>"$ERRFILE")" || WORK_COMMITS="?"
  # WHEN DID THE WORK MOVE? Not "git log -1": on a branch with no commits of
  # its own that is the last upstream commit, which is always recent. The
  # real signal is the mtime of the files the agent has touched (the ones
  # git reports as changed) and of the index.
  #
  # --no-optional-locks: WITHOUT it, `git status` rewrites the index it just
  # read (it refreshes the stat cache) and the mtime of the index becomes
  # NOW: the signal the watchdog reads is the one the watchdog itself
  # destroys, and a slot that is really stuck looks like it moved a second
  # ago. With the flag, the index is only read.
  last=""
  for f in $(git --no-optional-locks -C "$worktree" status --porcelain 2>"$ERRFILE" | sed 's/^...//'); do
    case "$f" in
      *' -> '*) f=${f##* -> } ;;
    esac
    [ -f "$worktree/$f" ] || continue
    m="$(stat -c %Y "$worktree/$f" 2>/dev/null)" || continue
    case "$m" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ -z "$last" ] || [ "$m" -gt "$last" ]; then last="$m"; fi
  done
  idx="$(git -C "$worktree" rev-parse --git-path index 2>/dev/null)"
  if [ -f "$idx" ]; then
    m="$(stat -c %Y "$idx" 2>/dev/null)" || m=""
    case "$m" in
      ''|*[!0-9]*) ;;
      *) if [ -z "$last" ] || [ "$m" -gt "$last" ]; then last="$m"; fi ;;
    esac
  fi
  if [ -z "$last" ]; then
    # nothing uncommitted: the last commit of the branch is the signal
    last="$(git -C "$worktree" log -1 --format=%ct 2>"$ERRFILE")" || last=""
  fi
  case "$last" in
    ''|*[!0-9]*) WORK_CHANGED="?"; WORK_UNKNOWN=1 ;;
    *) WORK_CHANGED=$(( (now - last) / 3600 )) ;;
  esac
}

# ---------------------------------------------------------------------------
# THE LOCK. The format is the one of the producer: slot-lock.sh writes
# $ORCH_DIR/locks/slot-<name>/{pid,since,owner} as SEPARATE files with a plain
# value each. The old watchdog looked for $LOCKS/*/lock, a single file with
# 'since=' and 'owner=' inside: that file does not exist, so it never found a
# single lock and every stuck slot went unnoticed (B2). The old format is
# still read, but the format of the producer is the one that counts.
#
# read_lock <dir>
#   0 -> it is a lock and it was read
#   1 -> it is not a lock of a slot
#   2 -> it is a lock and it could NOT be read
# ---------------------------------------------------------------------------
LOCK_SINCE=""; LOCK_OWNER=""; LOCK_PID=""
read_lock() {
  local d="$1" rc=0 out=""
  LOCK_SINCE=""; LOCK_OWNER=""; LOCK_PID=""
  if [ -e "$d/since" ]; then
    LOCK_SINCE="$(read_first_line "$d/since")" || rc=$?
    [ "$rc" = "2" ] && { LAST_ERROR="since: $LAST_ERROR"; return 2; }
    rc=0
    LOCK_OWNER="$(read_first_line "$d/owner")" || rc=$?
    [ "$rc" = "2" ] && { LAST_ERROR="owner: $LAST_ERROR"; return 2; }
    rc=0
    LOCK_PID="$(read_first_line "$d/pid")" || rc=$?
    [ "$rc" = "2" ] && { LAST_ERROR="pid: $LAST_ERROR"; return 2; }
    return 0
  fi
  if [ -e "$d/lock" ]; then
    # THE OLD FORMAT: one file with since= and owner= inside.
    out="$(awk -F= '/^since=/{print $2; exit}' "$d/lock" 2>"$ERRFILE")" || {
      LAST_ERROR="$(head -1 "$ERRFILE" 2>/dev/null)"; return 2; }
    LOCK_SINCE="$(printf '%s' "$out" | tr -d ' ')"
    out="$(awk -F= '/^owner=/{sub(/^owner=/,""); print; exit}' "$d/lock" 2>"$ERRFILE")" || {
      LAST_ERROR="$(head -1 "$ERRFILE" 2>/dev/null)"; return 2; }
    LOCK_OWNER="$out"
    return 0
  fi
  return 1
}

# Does the slot have a lock? The format of the producer: the lock IS the
# directory $LOCKS/slot-<name>/ (slot-lock.sh asks for the directory, not for
# a file inside it). The old format: the lock is the file $LOCKS/<name>/lock.
#
# WHY THIS IS THE LINE THAT MATTERS (B2): the old one looked for
# $LOCKS/<slot>/lock, a file that nobody writes. It NEVER matched, so a slot
# with a LIVE lock was reported as "without lock" and classified as residue
# instead of stuck.
slot_has_lock() {
  local slot="$1"
  [ -d "$LOCKS/slot-$slot" ] && return 0
  [ -f "$LOCKS/$slot/lock" ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# THE LOCKS. The name of the slot is what comes after the "slot-" of the
# directory (the producer names it slot-<name>), and its worktree is
# issue-<name>.
# ---------------------------------------------------------------------------
locks_seen=""
if [ "$want_locks" = "1" ]; then
for slot_dir in "$LOCKS"/*; do
  [ -d "$slot_dir" ] || continue
  name="${slot_dir##*/}"
  case "$name" in
    heavy|heavy-token-*) continue ;;   # the heavy phase is not a slot
  esac
  slot="${name#slot-}"
  rc=0
  read_lock "$slot_dir" || rc=$?
  case "$rc" in
    1) continue ;;                        # it is not a lock of a slot
    2) unknown "the lock of the slot $slot could not be read: $LAST_ERROR"; continue ;;
  esac
  # the same slot can be in two formats at the same time: it is reported
  # once.
  case "$locks_seen" in
    *"|$slot|"*) continue ;;
  esac
  locks_seen="$locks_seen|$slot|"
  if [ -z "$LOCK_SINCE" ]; then
    unknown "the lock of the slot $slot has no 'since': its age is unknown"
    continue
  fi
  since_epoch="$(date -d "$LOCK_SINCE" +%s 2>"$ERRFILE")" || {
    unknown "the 'since' of the lock of the slot $slot is not a date: $LOCK_SINCE"
    continue
  }
  lock_age_h=$(( (now - since_epoch) / 3600 ))
  [ "$lock_age_h" -lt 0 ] && lock_age_h=0
  analyze_worktree "$WORKTREES_DIR/issue-$slot"
  # The UNKNOWN check comes FIRST: a slot whose work could not be read
  # (no worktree, unreadable) has no branch and no commits, and used to
  # fall through the "no branch" line and vanish.
  if [ "$WORK_UNKNOWN" = "1" ]; then
    # the lock is old and the work could not be read: the verdict of this
    # slot is unknown, and "unknown" is not "not stuck".
    [ "$lock_age_h" -ge "$HOURS" ] && \
      unknown "the work of the slot $slot could not be read: the verdict is unknown"
    continue
  fi
  # STUCK: the lock is old and the work has not moved for at least as long
  if [ "$lock_age_h" -ge "$HOURS" ] && [ "$WORK_CHANGED" -ge "$HOURS" ]; then
    stuck=$((stuck + 1))
    emit "$slot" "${LOCK_OWNER:-?}" "$lock_age_h" "$WORK_BRANCH" "$WORK_COMMITS" "$WORK_CHANGED"
  fi
done
fi

# ---------------------------------------------------------------------------
# THE LIST OF PULL REQUESTS, ASKED ONCE. The old script asked GitHub twice
# per worktree (and once per pull request of ours for the comments): with
# five worktrees that is ten calls, and it took 3m22s measured (B11). The
# list is cached and the filter runs locally.
# ---------------------------------------------------------------------------
PR_LIST_FILE=""
PR_LIST_TRIED=0
pr_list() {
  [ "$PR_LIST_TRIED" = "1" ] && { [ -n "$PR_LIST_FILE" ] && return 0; return 1; }
  PR_LIST_TRIED=1
  local f="$TMP/prs.json"
  if ! "$GH_BIN" pr list --repo "$SC_REPO" --state all --limit "$PR_LIMIT" \
        --json number,title,body,state,headRefName >"$f" 2>"$ERRFILE"; then
    LAST_ERROR="$(head -1 "$ERRFILE" 2>/dev/null)"
    return 1
  fi
  if [ ! -s "$f" ]; then
    # "there are none" and "I could not read them" are NOT the same thing
    # (rule 7): the list is read again before concluding that it is empty.
    if ! "$GH_BIN" pr list --repo "$SC_REPO" --state open --limit 1 --json number >/dev/null 2>"$ERRFILE"; then
      LAST_ERROR="$(head -1 "$ERRFILE" 2>/dev/null)"
      return 1
    fi
    printf '[]\n' >"$f"
  fi
  PR_LIST_FILE="$f"
  return 0
}

# The pull requests that close the issue <n>: a verb of closing in the title
# or in the body, like the parser of the upstream
# (scripts/pr-checks/pr-checks.js, parseClosing).
prs_closing_issue() {
  local issue="$1" out=""
  [ -n "$PR_LIST_FILE" ] || return 0
  out="$(jq -r --arg re "(?i)(fixes|closes|refs|supersede|part of|addresses)[[:space:]]*#?${issue}\\b" \
      '.[] | select(((.body // "") + " " + (.title // "")) | test($re)) | .number' \
      "$PR_LIST_FILE" 2>"$ERRFILE")" || {
    LAST_ERROR="$(head -1 "$ERRFILE" 2>/dev/null)"; return 1; }
  printf '%s' "$out"
}

# The OPEN pull requests with this head branch.
prs_with_branch() {
  local branch="$1" out=""
  [ -n "$PR_LIST_FILE" ] || return 0
  out="$(jq -r --arg b "$branch" \
      '.[] | select(.state == "OPEN" and .headRefName == $b) | .number' \
      "$PR_LIST_FILE" 2>"$ERRFILE")" || {
    LAST_ERROR="$(head -1 "$ERRFILE" 2>/dev/null)"; return 1; }
  printf '%s' "$out"
}

# The state of the slot in state.json: "running", "closed", "absent" or
# "unknown" (the state could not be read).
slot_state() {
  local slot="$1" out=""
  out="$(python3 - "$ORCH_DIR/state.json" "$slot" <<'PY' 2>"$ERRFILE"
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        st = json.load(fh)
except Exception:
    print("unknown")
    raise SystemExit(0)
slot = sys.argv[2]
for key, val in (st.get("slots") or {}).items():
    if not isinstance(val, dict):
        continue
    if str(val.get("issue", "")) == slot or str(key) == slot:
        print("running" if val.get("status") == "running" else "closed")
        break
else:
    print("absent")
PY
)"
  [ -n "$out" ] || out="unknown"
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# THE WORKTREES WITHOUT A LOCK. An agent that never took the lock is invisible
# to the loop: the slot looks free and the worktree just sits there. Half of
# the agents that burned hours were in this state.
#
# Whether that work is residue (published) or stuck (an agent that is still
# there) is decided with the PULL REQUESTS, so this part needs GitHub.
# ---------------------------------------------------------------------------
if [ "$want_prs" = "1" ]; then
for worktree in "$WORKTREES_DIR"/*; do
  [ -d "$worktree" ] || continue
  name="${worktree##*/}"
  case "$name" in issue-*) ;; *) continue ;; esac
  slot="${name#issue-}"
  # the lock is ACTIVE while it is there: the worktree of a slot with a lock
  # was already read above (in the producer's format AND in the old one).
  slot_has_lock "$slot" && continue
  [ -f "$worktree/.git" ] || continue

  analyze_worktree "$worktree"
  [ -n "$WORK_BRANCH" ] || continue
  if [ "$WORK_UNKNOWN" = "1" ]; then
    unknown "the work of the slot $slot could not be read: the verdict is unknown"
    continue
  fi
  [ "$WORK_CHANGED" -ge "$HOURS" ] || continue

  # A worktree without a lock is only STUCK if its work is NOT published. The
  # pull request rarely has the same branch name (the publisher renames it, or
  # the work went out with another branch), so the reliable test is the ISSUE:
  # if some open pull request already closes the issue of this branch, the work
  # is out and this is residue of a finished slot.
  published=0
  prs=""
  issue="$(printf '%s' "$WORK_BRANCH" | grep -oE '(issue|problem)-?[0-9]{3,6}' | grep -oE '[0-9]+' | head -1)"
  if [ -n "$issue" ]; then
    # open AND merged: a merged pull request is published work too, and the
    # slots of the merged pull requests are exactly the ones that would
    # otherwise show up as false alarms
    if pr_list; then
      prs="$(prs_closing_issue "$issue")" || {
        unknown "the list of pull requests could not be filtered: $LAST_ERROR"; prs=""; }
      [ -n "$prs" ] && published=1
    else
      unknown "the pull requests could not be read: $LAST_ERROR"
    fi
  fi
  # THE SLOT IS NOT RUNNING ANY MORE. A worktree without a lock belongs to a
  # slot whose agent finished (or died): that is residue, not a stuck agent.
  # The orchestrator's own state is the source of truth for that.
  if [ "$published" != "1" ] && [ -f "$ORCH_DIR/state.json" ]; then
    running="$(slot_state "$slot")"
    case "$running" in
      closed) published=1; prs="(slot cerrado)" ;;
      unknown) unknown "the state of the slot $slot could not be read" ;;
    esac
  fi
  if [ "$published" != "1" ]; then
    if pr_list; then
      prs="$(prs_with_branch "$WORK_BRANCH")" || {
        unknown "the list of pull requests could not be filtered: $LAST_ERROR"; prs=""; }
      [ -n "$prs" ] && published=1
    else
      unknown "the pull requests could not be read: $LAST_ERROR"
    fi
  fi
  if [ "$published" = "1" ]; then
    residue=$((residue + 1))
    [ -n "${JSON:-}" ] && \
      printf '{"slot":"%s","state":"residuo","branch":"%s","prs":"%s","changed_ago_h":%s}\n' \
        "$slot" "$WORK_BRANCH" "$(echo $prs | tr ' ' ',')" "$WORK_CHANGED"
    continue
  fi

  stuck=$((stuck + 1))
  stuck_nolock=$((stuck_nolock + 1))
  emit "$slot" "(SIN LOCK)" "?" "$WORK_BRANCH" "$WORK_COMMITS" "$WORK_CHANGED"
done
fi

# ---------------------------------------------------------------------------
# THE COUNTS. In --locks mode only the locks were read, so only their count
# is said; in --prs mode only the worktrees without a lock were read.
# ---------------------------------------------------------------------------
if [ -z "${JSON:-}" ]; then
  if [ "$MODE" = "prs" ]; then
    if [ "$stuck_nolock" -gt 0 ]; then
      echo "  $stuck_nolock slot(s) atascado(s) sin lock"
    elif [ "$UNKNOWN" = "1" ]; then
      echo "  no se pudo leer el estado de todos los slots: el veredicto es UNKNOWN"
    else
      echo "  ningun slot atascado sin lock (worktree sin lock y trabajo sin publicar)"
    fi
  elif [ "$stuck" -gt 0 ]; then
    echo "  $stuck slot(s) atascado(s)"
  fi
  if [ "$UNKNOWN" = "1" ]; then
    # "there is no stuck slot" is only said when EVERYTHING was read, and a
    # count of stuck slots is not a complete verdict while a slot is unknown.
    echo "  $unknown_n slot(s) sin veredicto: su estado no se pudo leer (UNKNOWN)"
  fi
  if [ "$stuck" -eq 0 ] && [ "$UNKNOWN" != "1" ]; then
    echo "  ningun slot atascado (lock de mas de ${HOURS}h sin que el trabajo se mueva)"
  fi
  [ "$residue" -gt 0 ] && echo "  $residue residuo(s): worktree sin lock, pero con su PR ya publicado"
  [ "$UNKNOWN" = "1" ] && [ "$residue" -gt 0 ] && \
    echo "  (el numero de residuos tambien es INCERTO: no se pudo leer todo)"
fi

# ---------------------------------------------------------------------------
# THE PULL REQUESTS WAITING FOR US. The maintainer's comment is the most
# actionable signal in the loop: a pull request with no comment is waiting for
# a review, a pull request WITH a comment is waiting for US. On #10618 the
# maintainer asked for two small changes and the pull request sat there with
# the gate green.
#
# TWO CALLS, NOT ONE PER PULL REQUEST. The old script asked for the comments
# of every pull request of ours, one call each (five calls, 3m22s measured).
# Now the list of our pull requests is ONE call and the last comment of ALL of
# them is ONE GraphQL query (an alias per pull request inside the same
# query). The REST endpoint of all the comments of the repository
# (repos/<repo>/issues/comments) was not used: it is tens of thousands of
# comments (hundreds of pages) and it would be SLOWER than the five calls it
# replaces.
# ---------------------------------------------------------------------------
if [ "$want_prs" = "1" ] && [ "${WATCH_PRS:-1}" = "1" ]; then
  echo
  echo "  los PRs que esperan una respuesta nuestra:"
  if ! command -v "$GH_BIN" >/dev/null 2>&1; then
    unknown "there is no gh to read the pull requests with"
    echo "    no se pudo leer la lista de PRs (UNKNOWN)"
  elif ! "$GH_BIN" pr list --repo "$SC_REPO" --author "$AUTHOR" --state open --limit 50 \
        --json number >"$TMP/mine.json" 2>"$ERRFILE"; then
    unknown "the pull requests of ours could not be read: $(head -1 "$ERRFILE" 2>/dev/null)"
    echo "    no se pudo leer la lista de PRs (UNKNOWN)"
  else
    mine="$(jq -r '.[].number' "$TMP/mine.json" 2>"$ERRFILE")" || {
      unknown "the list of pull requests could not be read: $(head -1 "$ERRFILE" 2>/dev/null)"
      echo "    no se pudo leer la lista de PRs (UNKNOWN)"
      mine=""
    }
    if [ -n "$mine" ]; then
      q="query(\$owner:String!,\$name:String!){repository(owner:\$owner,name:\$name){"
      for pr in $mine; do
        q="$q p$pr: pullRequest(number:$pr){comments(last:1){nodes{author{login} createdAt}}}"
      done
      q="$q}}"
      if ! "$GH_BIN" api graphql -f query="$q" -f owner="$SC_OWNER" -f name="$SC_NAME" \
            >"$TMP/waiting.json" 2>"$ERRFILE"; then
        unknown "the comments of the pull requests could not be read: $(head -1 "$ERRFILE" 2>/dev/null)"
        echo "    no se pudo leer la lista de PRs (UNKNOWN)"
      else
        waiting="$(jq -r '.data.repository | to_entries[] | select((.value.comments.nodes | length) > 0) | "\(.key | ltrimstr("p"))\t\(.value.comments.nodes[0].author.login // "null")\t\(.value.comments.nodes[0].createdAt // "")"' \
          "$TMP/waiting.json" 2>"$ERRFILE")" || {
            unknown "the answer of GitHub could not be read: $(head -1 "$ERRFILE" 2>/dev/null)"
            echo "    no se pudo leer la lista de PRs (UNKNOWN)"
            waiting=""
          }
        while IFS=$'\t' read -r pr who at; do
          [ -n "$pr" ] || continue
          case "$who" in
            ""|null) continue ;;        # nobody talked: there is nothing to answer
            "$AUTHOR") continue ;;      # the last word is ours: we answered
          esac
          printf '    #%s  el ultimo comentario es de %s  (%s %s | sin nuestra respuesta)\n' \
            "$pr" "$who" "$who" "$at"
        done <<<"$waiting"
      fi
    fi
  fi
fi

# The verdict reaches the exit code (rule 7): a check that could not run is
# UNKNOWN (6), never "no" (0).
if [ "$UNKNOWN" = "1" ]; then exit 6; fi
exit 0
