#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Appends ONE line with the state of the loop to metrics.log.
#
# WHY: to know whether the changes of 2026-10-24 (the quick gate, the merge
# signal, the publication latch) made the loop faster, the numbers of the new
# run have to be measured the same way the old ones were. This is the cheap
# half: a line every time, so there is a record even if nobody is watching.
# The expensive half (minutes per phase) is bin/metrics-report.sh.
#
# It reads only: state.json, gate.verdict, gate.quick.verdict, merge.verdict
# and the age of the current turn. It never writes to the state.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
LOG="$LOOP_DIR/metrics.log"
mkdir -p "$LOOP_DIR"

kv() { # file key -> the value of KEY=..., empty when the file is not there
  local file="$1" key="$2"
  [ -r "$file" ] || return 0
  sed -n "s/^${key}=\(.*\)$/\1/p" "$file" 2>/dev/null | head -1 | tr -d '\r'
}

STATE="$LOOP_DIR/state.json"
phase=""; issue=""; pr=""; iter=""; fails=""; consec=""; started=""
slot0_phase=""; slot0_issue=""; slot0_pr=""; slot1_phase=""; slot1_issue=""; slot1_pr=""
if [ -r "$STATE" ]; then
  # The schema v2: the per-issue fields live in the slots. The snapshot
  # reports the slot 0 (the reference) and both slots, so the measurement
  # can tell whether the work is spread or piled up.
  #
  # One python call prints the fields separated by a character that cannot
  # appear in them, and the shell splits them: a `read` with a heredoc does
  # not assign anything when the python fails, and the shell runs with
  # `set -u`.
  snapshot_fields="$(python3 -c "
import json,sys
s=json.load(open(sys.argv[1]))
slots=s.get('slots') if isinstance(s.get('slots'),dict) else {}
def g(i,k,d=''):
    v=slots.get(str(i))
    return (v.get(k,d) if isinstance(v,dict) else d)
c=s.get('counters') or {}
print('|'.join(str(x) for x in [
    s.get('phase',''), s.get('issue',''), s.get('pr',''),
    c.get('iterations',''), c.get('failures',''), c.get('consecutive',''),
    (s.get('in_flight') or {}).get('started',''),
    g(0,'phase'), g(0,'issue'), g(0,'pr'),
    g(1,'phase'), g(1,'issue'), g(1,'pr')]))
" "$STATE" 2>/dev/null)" || snapshot_fields=""
  if [ -n "$snapshot_fields" ]; then
    IFS='|' read -r phase issue pr iter fails consec started \
      slot0_phase slot0_issue slot0_pr slot1_phase slot1_issue slot1_pr \
      <<< "$snapshot_fields" || true
  fi
fi

now=$(date -u +%s)
age=0
[ -n "$started" ] && age=$(( (now - started) / 60 ))

# The age of the turn that is running: the newest turn log.
turn_age=0
newest=$(ls -1t "$LOOP_DIR"/logs/turns/*.jsonl 2>/dev/null | head -1)
if [ -n "$newest" ]; then
  t=$(stat -c %Y "$newest" 2>/dev/null || echo 0)
  [ "$t" -gt 0 ] && turn_age=$(( (now - t) / 60 ))
fi

# --- the token counter ----------------------------------------------------
# The spend of OpenCode, in tokens and in dollars. It is a separate program
# because the accounting spans two sources: the database of OpenCode (the
# interactive sessions) and the JSONL of the loop (the turns, whose sessions
# are swept from the database when the turn is over).
#
# The counter is read-only but it is NOT free: it sweeps the whole database
# of OpenCode, so running it on every beat (every five minutes) spends CPU
# on a number that does not move in five minutes. The snapshot therefore
# SAMPLES it: METRICS_TOKEN_SAMPLE_MIN says how many minutes have to pass
# between two readings (60 by default, 0 reads it on every beat). Between two
# readings the LAST VALUE is carried forward, so the daily report
# (bin/compare-baseline.py) keeps finding the field it reads.
#
# It must NEVER break the snapshot: a counter that is down does not stop the
# metrics, so its failure leaves the field empty (or the carried value) and
# the script goes on.
tokens=""
# The counter travels with the loop: bin/oc-tokens is the versioned copy. The
# one in ~/.local/bin is the fallback, for an installation that keeps it there.
TOKEN_COUNTER="$LOOP_DIR/bin/oc-tokens"
[ -x "$TOKEN_COUNTER" ] || TOKEN_COUNTER="$HOME/.local/bin/oc-tokens"
[ -x "$TOKEN_COUNTER" ] || TOKEN_COUNTER="$(command -v oc-tokens 2>/dev/null || true)"

# The knob of the sampling. A knob that is broken is the default: it never
# turns the sampling off by surprise and it never turns it on by surprise.
sample_min="${METRICS_TOKEN_SAMPLE_MIN:-60}"
case "$sample_min" in
  ''|*[!0-9]*) sample_min=60 ;;
esac

# The state of the last reading: when it was taken and what it said.
TOKEN_STATE="$LOOP_DIR/tokens-sample.state"
last_at=0
last_tokens=""
if [ -r "$TOKEN_STATE" ]; then
  last_at="$(kv "$TOKEN_STATE" at)"
  last_tokens="$(kv "$TOKEN_STATE" tokens)"
fi
case "$last_at" in
  ''|*[!0-9]*) last_at=0 ;;
esac

# Is the reading due? The first beat always reads; after that, the minutes of
# the knob have to pass.
due=1
if [ "$sample_min" -gt 0 ] && [ "$last_at" -gt 0 ]; then
  if [ $(( now - last_at )) -lt $(( sample_min * 60 )) ]; then
    due=0
  fi
fi

if [ "$due" -eq 1 ] && [ -n "$TOKEN_COUNTER" ] && [ -x "$TOKEN_COUNTER" ]; then
  read_tokens="$(timeout 120 "$TOKEN_COUNTER" --record 2>/dev/null || true)"
  if [ -n "$read_tokens" ]; then
    tokens="$read_tokens"
    # The state is written atomically (a temporary file and a rename), so a
    # snapshot that dies in the middle leaves no half-written state behind.
    tmp_state="$TOKEN_STATE.tmp.$$"
    if printf 'at=%s\ntokens=%s\n' "$now" "$tokens" > "$tmp_state" 2>/dev/null; then
      mv -f "$tmp_state" "$TOKEN_STATE" 2>/dev/null || true
    else
      rm -f "$tmp_state" 2>/dev/null || true
    fi
  else
    # The counter is down: the last known value is carried forward and the
    # reading is tried again on the next beat.
    tokens="$last_tokens"
  fi
else
  # Not due (or there is no counter at all): the last known value is carried
  # forward, so the field never disappears from the log.
  tokens="$last_tokens"
fi

printf 'at=%s iso=%s iter=%s phase=%s issue=%s pr=%s fails=%s consec=%s inflight_min=%s turn_min=%s gate=%s gate_status=%s quick=%s quick_scope=%s merge=%s s0_phase=%s s0_issue=%s s0_pr=%s s1_phase=%s s1_issue=%s s1_pr=%s %s\n' \
  "$now" "$(date -u +%FT%H:%M:%SZ)" "${iter:-0}" "${phase:-?}" "${issue:-0}" "${pr:-0}" \
  "${fails:-0}" "${consec:-0}" "$age" "$turn_age" \
  "$(kv "$LOOP_DIR/gate.verdict" VERDICT)" "$(kv "$LOOP_DIR/gate.verdict" GATE_STATUS)" \
  "$(kv "$LOOP_DIR/gate.quick.verdict" VERDICT)" "$(kv "$LOOP_DIR/gate.quick.verdict" SCOPE)" \
  "$(kv "$LOOP_DIR/merge.verdict" MERGE_VERDICT)" \
  "${slot0_phase:-}" "${slot0_issue:-}" "${slot0_pr:-}" \
  "${slot1_phase:-}" "${slot1_issue:-}" "${slot1_pr:-}" \
  "$tokens" \
  >> "$LOG"
