#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# agent-turn.sh - one turn of the agent of a slot, with its nudges.
#
# WHY (2026-11-21): the first agent of the new brief (slot 19690) ran 51
# minutes, 33 steps, $0.048, and its run ENDED with "Let me instrument all
# doc-level boolean calls with a backtrace." `opencode run` finishes when the
# model writes a text without calling a tool, even when that text announces
# the next step: no verdict, nothing pushed, and the wave closed the slot.
#
# So after the run, if its text has no JSON verdict ({"verdict": ...}), the
# SAME session gets a nudge right away: its prompt cache is still warm (it
# went quiet seconds ago), so the nudge costs the new tokens, not the whole
# history. Upstream warns against resuming a session whose cache has gone COLD
# (CONTRIBUTING.md); this is the warm case. At most AGENT_NUDGES nudges, all
# inside the same time ceiling as the turn.
#
# USAGE (bin/dispatch-slot.sh runs it in the worktree of the slot):
#   bash bin/agent-turn.sh <agent_bin> <model> <agent_name> <brief_file> \
#       <issue> <timeout_min> <jsonl>
# stdout: what happened, one line per run (dispatch-slot appends it to the
# .log of the slot); the agent's events go to <jsonl>.
# Exit code: the rc of the last run (124 = the time ceiling).
# ---------------------------------------------------------------------------
set -uo pipefail

AGENT_BIN="$1"; MODEL="$2"; AGENT_NAME="$3"; BRIEF="$4"; ISSUE="$5"
TIMEOUT_MIN="$6"; JSONL="$7"
NUDGES="${AGENT_NUDGES:-2}"
[[ "$NUDGES" =~ ^[0-9]+$ ]] || NUDGES=2
DEADLINE=$(( $(date +%s) + TIMEOUT_MIN * 60 ))

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

NUDGE_MSG="You ended your turn without the final JSON object the brief asks for.
If your last message said you would do something next, do it now with your tools.
Commit and push to the fork what builds. Then end with ONLY the JSON verdict object
from the brief (verdict ready, waiting or blocked)."

# What the events written after byte OFFSET say: "<verdict|-> <sessionID|->".
read_run() {
  python3 - "$JSONL" "$1" <<'PY'
import json, re, sys
path, offset = sys.argv[1], int(sys.argv[2])
texts, sid = [], "-"
try:
    with open(path, "rb") as fh:
        fh.seek(offset)
        data = fh.read().decode("utf-8", "replace")
except OSError:
    data = ""
for line in data.splitlines():
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if ev.get("sessionID"):
        sid = ev["sessionID"]
    if ev.get("type") == "text":
        texts.append(str((ev.get("part") or {}).get("text") or ""))
verdict = "-"
for m in re.finditer(r'"verdict"\s*:\s*"(ready|waiting|blocked)"', "\n".join(texts)):
    verdict = m.group(1)
print(verdict, sid)
PY
}

run_once() {  # $1 = message, $2 = session id or empty
  local left=$(( DEADLINE - $(date +%s) ))
  [ "$left" -gt 60 ] || return 124
  local args=(run --standalone --auto --format json --title "issue-$ISSUE" -m "$MODEL" --agent "$AGENT_NAME")
  [ -n "${2:-}" ] && args+=(--session "$2")
  timeout --kill-after=120 "$left" "$AGENT_BIN" "${args[@]}" "$1" >> "$JSONL"
}

MSG="$(cat "$BRIEF")"
attempt=0
session=""
while :; do
  offset=$(stat -c %s "$JSONL" 2>/dev/null || echo 0)
  if [ "$attempt" -eq 0 ]; then
    run_once "$MSG" ""; rc=$?
  else
    run_once "$NUDGE_MSG" "$session"; rc=$?
  fi
  read -r verdict sid <<<"$(read_run "$offset")"
  [ "$sid" != "-" ] && session="$sid"
  echo "===== $(stamp) agent-turn: issue $ISSUE, corrida $((attempt + 1)), rc=$rc, veredicto=${verdict}, sesion=${session:--} ====="
  [ "$verdict" != "-" ] && exit "$rc"
  [ "$rc" -eq 0 ] || exit "$rc"
  [ -n "$session" ] || exit "$rc"
  [ "$attempt" -lt "$NUDGES" ] || { echo "===== $(stamp) agent-turn: issue $ISSUE, sin veredicto despues de $NUDGES empujones ====="; exit "$rc"; }
  attempt=$((attempt + 1))
done
