#!/usr/bin/env bash
# Which slots are STUCK? A slot is stuck when its lock is old and the branch
# has not moved: the agent is alive but it is not writing code.
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
# usage: bin/slot-stale.sh [--hours N] [--json]
#   --hours N   how old a lock must be to count (default: 2)
#   --json      one JSON object per stuck slot

set -u

ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
REPO="${REPO:-$HOME/solidcraft}"
LOCKS="$ORCH_DIR/locks"
HOURS=2

while [ $# -gt 0 ]; do
  case "$1" in
    --hours) HOURS="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    *) echo "usage: bin/slot-stale.sh [--hours N] [--json]" >&2; exit 2 ;;
  esac
done
JSON="${JSON:-}"

now=$(date +%s)
stuck=0
residue=0

emit() { # emit <slot> <owner> <lock_age_h> <branch> <commits> <changed_ago_h>
  if [ -n "${JSON:-}" ]; then
    printf '{"slot":"%s","owner":"%s","lock_age_h":%s,"branch":"%s","commits":%s,"changed_ago_h":%s}\n' \
      "$1" "$2" "$3" "$4" "$5" "$6"
  else
    printf '  slot %-8s lock de hace %-5sh  owner %-28s rama %-46s commits=%-3s sin moverse hace %sh\n' \
      "$1" "$3" "$2" "$4" "$5" "$6"
  fi
}

[ -d "$LOCKS" ] || exit 0

# THE FORMAT OF THE LOCKS: slot-lock.sh writes $LOCKS/<slot>/{pid,since,owner} as
# SEPARATE files with a plain value each. This watchdog used to look for
# $LOCKS/*/lock, a single file with 'since=' and 'owner=' inside (the format of
# an older script): it never found a single lock, so it was BLIND, and every
# stuck slot went unnoticed. Both formats are read now.
for slot_dir in "$LOCKS"/*; do
  [ -d "$slot_dir" ] || continue
  slot=$(basename "$slot_dir")
  lockfile="$slot_dir/lock"
  if [ -f "$slot_dir/since" ]; then
    since=$(head -1 "$slot_dir/since" 2>/dev/null | tr -d ' ')
    owner=$(head -1 "$slot_dir/owner" 2>/dev/null | tr -d ' ')
    lock_pid=$(head -1 "$slot_dir/pid" 2>/dev/null | tr -d ' ')
  else
    [ -e "$lockfile" ] || continue
    since=$(awk -F= '/^since=/{print $2; exit}' "$lockfile" 2>/dev/null | tr -d ' ')
    owner=$(awk -F= '/^owner=/{sub(/^owner=/,""); print; exit}' "$lockfile" 2>/dev/null)
    lock_pid=""
  fi
  [ -n "$since" ] || continue

  # the age of the lock, in hours
  since_epoch=$(date -d "$since" +%s 2>/dev/null || echo "$since")
  case "$since_epoch" in
    ''|*[!0-9]*) continue ;;
  esac
  lock_age_h=$(( (now - since_epoch) / 3600 ))

  # the branch of the worktree of the slot, and when it last moved
  worktree="$HOME/solidcraft-wt/issue-$slot"
  branch=""
  changed_ago_h="0"
  commits="?"
  if [ -d "$worktree" ]; then
    branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null)
    [ "$branch" = "HEAD" ] && branch="(detached)"
    if [ -n "$branch" ] && [ "$branch" != "(detached)" ]; then
      commits=$(git -C "$REPO" rev-list --count "origin/main..$branch" 2>/dev/null || echo "?")
      # WHEN DID THE WORK MOVE? Not "git log -1": on a branch with no commits of
      # its own that is the last upstream commit, which is always recent. The
      # real signal is the mtime of the files the agent has touched (the ones
      # git reports as changed) and of the index.
      last=""
      for f in $(git -C "$worktree" status --porcelain 2>/dev/null | sed 's/^...//'); do
        case "$f" in
          *' -> '*) f=${f##* -> } ;;
        esac
        [ -f "$worktree/$f" ] || continue
        m=$(stat -c %Y "$worktree/$f" 2>/dev/null || echo "")
        case "$m" in
          ''|*[!0-9]*) continue ;;
        esac
        if [ -z "$last" ] || [ "$m" -gt "$last" ]; then last="$m"; fi
      done
      idx=$(git -C "$worktree" rev-parse --git-path index 2>/dev/null)
      if [ -f "$idx" ]; then
        m=$(stat -c %Y "$idx" 2>/dev/null || echo "")
        case "$m" in
          ''|*[!0-9]*) ;;
          *) if [ -z "$last" ] || [ "$m" -gt "$last" ]; then last="$m"; fi ;;
        esac
      fi
      if [ -z "$last" ]; then
        # nothing uncommitted: the last commit of the branch is the signal
        last=$(git -C "$worktree" log -1 --format=%ct 2>/dev/null || echo "")
      fi
      case "$last" in
        ''|*[!0-9]*) changed_ago_h="?" ;;
        *) changed_ago_h=$(( (now - last) / 3600 )) ;;
      esac
    fi
  fi
  [ -n "$branch" ] || continue

  # STUCK: the lock is old and the work has not moved for at least as long
  if [ "$lock_age_h" -ge "$HOURS" ] && [ "$changed_ago_h" != "?" ] && [ "$changed_ago_h" -ge "$HOURS" ]; then
    stuck=$((stuck + 1))
    emit "$slot" "${owner:-?}" "$lock_age_h" "$branch" "$commits" "$changed_ago_h"
  fi
done

# ---------------------------------------------------------------------------
# THE WORKTREES WITHOUT A LOCK. An agent that never took the lock is invisible
# to the loop: the slot looks free and the worktree just sits there. Half of
# the agents that burned hours were in this state.
# ---------------------------------------------------------------------------
for worktree in "$HOME"/solidcraft-wt/*; do
  [ -d "$worktree" ] || continue
  name=$(basename "$worktree")
  # only the worktrees of a slot: a directory named otherwise (evidence-*, and
  # any other scratch worktree) is not a slot and must not raise an alarm
  case "$name" in issue-*) ;; *) continue ;; esac
  slot=$(echo "$name" | sed 's/^issue-//')
  # the lock is ACTIVE only while the file is there: the directory outlives it
  [ -f "$LOCKS/$slot/lock" ] && continue   # it has an active lock: covered above
  [ -f "$worktree/.git" ] || continue

  branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ "$branch" = "HEAD" ] && branch="(detached)"
  [ -n "$branch" ] || continue

  commits=$(git -C "$REPO" rev-list --count "origin/main..$branch" 2>/dev/null || echo "?")
  last=""
  for f in $(git -C "$worktree" status --porcelain 2>/dev/null | sed 's/^...//'); do
    case "$f" in *' -> '*) f=${f##* -> } ;; esac
    [ -f "$worktree/$f" ] || continue
    m=$(stat -c %Y "$worktree/$f" 2>/dev/null || echo "")
    case "$m" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$last" ] || [ "$m" -gt "$last" ]; then last="$m"; fi
  done
  idx=$(git -C "$worktree" rev-parse --git-path index 2>/dev/null)
  if [ -f "$idx" ]; then
    m=$(stat -c %Y "$idx" 2>/dev/null || echo "")
    case "$m" in ''|*[!0-9]*) ;; *) if [ -z "$last" ] || [ "$m" -gt "$last" ]; then last="$m"; fi ;; esac
  fi
  if [ -z "$last" ]; then
    last=$(git -C "$worktree" log -1 --format=%ct 2>/dev/null || echo "")
  fi
  case "$last" in
    ''|*[!0-9]*) continue ;;
  esac
  changed_ago_h=$(( (now - last) / 3600 ))
  [ "$changed_ago_h" -ge "$HOURS" ] || continue

  # A worktree without a lock is only STUCK if its work is NOT published. The
  # pull request rarely has the same branch name (the publisher renames it, or
  # the work went out with another branch), so the reliable test is the ISSUE:
  # if some open pull request already closes the issue of this branch, the work
  # is out and this is residue of a finished slot.
  published=0
  prs=""
  issue=$(echo "$branch" | grep -oE '(issue|problem)-?[0-9]{3,6}' | grep -oE '[0-9]+' | head -1)
  if [ -n "$issue" ]; then
    # open AND merged: a merged pull request is published work too, and the
    # slots of the merged pull requests are exactly the ones that would
    # otherwise show up as false alarms
    prs=$(gh pr list --repo tangency-labs/solidcraft --state all --limit 1200 \
            --json number,title,body,state --jq ".[] | select(((.body // \"\") + \" \" + .title) | test(\"(?i)(fixes|closes|refs|supersede|part of|addresses)[[:space:]]*#?$issue\\\\b\")) | .number" 2>/dev/null)
    [ -n "$prs" ] && published=1
  fi
  # THE SLOT IS NOT RUNNING ANY MORE. A worktree without a lock belongs to a
  # slot whose agent finished (or died): that is residue, not a stuck agent.
  # The orchestrator's own state is the source of truth for that.
  if [ "$published" != "1" ] && [ -f "$ORCH_DIR/state.json" ]; then
    running=$(python3 - "$ORCH_DIR/state.json" "$slot" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        st = json.load(fh)
except Exception:
    print(""); raise SystemExit(0)
slot = sys.argv[2]
for key, val in (st.get("slots") or {}).items():
    if not isinstance(val, dict):
        continue
    if str(val.get("issue", "")) == slot or str(key) == slot:
        print("running" if val.get("status") == "running" else "closed")
        break
PY
)
    [ "$running" = "closed" ] && published=1 && prs="(slot cerrado)"
  fi
  if [ "$published" != "1" ]; then
    prs=$(gh pr list --repo tangency-labs/solidcraft --state open --limit 200 \
            --json number,headRefName --jq ".[] | select(.headRefName == \"$branch\") | .number" 2>/dev/null)
    [ -n "$prs" ] && published=1
  fi
  if [ "$published" = "1" ]; then
    residue=$((residue + 1))
    [ -n "${JSON:-}" ] && \
      printf '{"slot":"%s","state":"residuo","branch":"%s","prs":"%s","changed_ago_h":%s}\n' \
        "$slot" "$branch" "$(echo $prs | tr ' ' ',')" "$changed_ago_h"
    continue
  fi

  stuck=$((stuck + 1))
  emit "$slot" "(SIN LOCK)" "?" "$branch" "$commits" "$changed_ago_h"
done

if [ -z "${JSON:-}" ]; then
  if [ "$stuck" -eq 0 ]; then
    echo "  ningun slot atascado (lock de mas de ${HOURS}h sin que el trabajo se mueva)"
  else
    echo "  $stuck slot(s) atascado(s)"
  fi
  [ "$residue" -gt 0 ] && echo "  $residue residuo(s): worktree sin lock, pero con su PR ya publicado"
fi

# ---------------------------------------------------------------------------
# THE PULL REQUESTS WAITING FOR US. The maintainer's comment is the most
# actionable signal in the loop: a pull request with no comment is waiting for
# a review, a pull request WITH a comment is waiting for US. On #10618 the
# maintainer asked for two small changes and the pull request sat there with
# the gate green.
# ---------------------------------------------------------------------------
if [ "${WATCH_PRS:-1}" = "1" ] && command -v gh >/dev/null 2>&1; then
  echo
  echo "  los PRs que esperan una respuesta nuestra:"
  for pr in $(gh pr list --repo tangency-labs/solidcraft --author vdirienzo --state open \
                --limit 50 --json number --jq '.[].number' 2>/dev/null); do
    last=$(gh api "repos/tangency-labs/solidcraft/issues/$pr/comments" --jq \
            '[.[] | {who: .user.login, at: .created_at}] | last | "\(.who) \(.at)"' 2>/dev/null)
    case "$last" in
      ""|null*) continue ;;
      vdirienzo*) continue ;;   # the last word is ours: we answered
    esac
    who=$(echo "$last" | cut -d' ' -f1)
    echo "    #$pr  el ultimo comentario es de $who  ($last | sin nuestra respuesta)"
  done
fi
exit 0
