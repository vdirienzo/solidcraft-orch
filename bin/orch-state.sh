#!/usr/bin/env bash
# orch-state.sh - the state of the orchestrator, READ THE WAY YOU NEED IT.
#
# state.json is the canonical memory, but reading it whole costs context that is
# re-sent on every turn. This script prints only the part you asked for.
#
#   bash orch-state.sh                 -> the summary (a dozen lines)
#   bash orch-state.sh slots           -> the slots and their locks
#   bash orch-state.sh prs             -> the open PRs and what each waits for
#   bash orch-state.sh gates           -> the gate verdicts
#   bash orch-state.sh issue <n>       -> everything known about one issue
#   bash orch-state.sh keys            -> the top-level keys, with their sizes
#   bash orch-state.sh history [n]     -> the last n history entries (default 5)
#   bash orch-state.sh raw <key>       -> one top-level key, verbatim
set -uo pipefail
# The paths come from the environment, with the default of THIS
# machine: the other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
export ORCH_DIR
STATE="$ORCH_DIR/state.json"
HISTORY="$ORCH_DIR/history.jsonl"

have_jq() { command -v jq >/dev/null 2>&1; }

# Read a key with python3 (always present here) and print a compact form.
pick() {
  python3 - "$@" <<'PY'
import json, os, sys
path = os.environ["ORCH_DIR"] + "/state.json"
key = sys.argv[1] if len(sys.argv) > 1 else None
try:
    s = json.load(open(path))
except Exception as e:
    print(f"state.json unreadable: {e}"); raise SystemExit(1)
if key is None:
    for k in ("orchestrator", "version", "started_at", "updated_at"):
        if k in s: print(f"{k}: {s[k]}")
    raise SystemExit(0)
if key not in s:
    print(f"no such key: {key}"); raise SystemExit(1)
v = s[key]
if isinstance(v, dict):
    for k, val in v.items():
        line = val if isinstance(val, str) else json.dumps(val, ensure_ascii=False)
        if len(line) > 400:
            line = line[:400] + " ...(truncated)"
        print(f"{k}: {line}")
elif isinstance(v, list):
    for i, item in enumerate(v):
        line = item if isinstance(item, str) else json.dumps(item, ensure_ascii=False)
        if len(line) > 400:
            line = line[:400] + " ...(truncated)"
        print(f"[{i}] {line}")
else:
    print(v)
PY
}

case "${1:-summary}" in
  summary)
    # The PENDING things come FIRST: they are the ones that need a decision
    # and they are the ones a session that only reads the summary would
    # otherwise miss.
    pending="$(python3 - <<'PY'
import json, os
try:
    s = json.load(open(os.environ["ORCH_DIR"] + "/state.json"))
except Exception:
    raise SystemExit(0)
pend = s.get("pending") or []
for p in pend:
    what = p.get("what", "?")
    action = p.get("action", "")
    # The summary is context that is re-sent on every turn: a pending item
    # is printed SHORT. The whole thing lives in state.json.
    if len(what) > 220:
        what = what[:220] + " ..."
    print(f"  [{p.get('kind','?')}] {what}")
    if action:
        if len(action) > 160:
            action = action[:160] + " ..."
        print(f"      hacer: {action}")
PY
)"
    if [ -n "$pending" ]; then
      echo "=== PENDIENTES (hay que mirarlos) ==="
      echo "$pending"
      echo
    fi
    echo "=== slots ==="
    pick slots
    echo
    echo "=== open PRs ==="
    pick open_prs
    echo
    echo "=== PRs que esperan una respuesta nuestra ==="
    bash "$ORCH_DIR/bin/slot-stale.sh" --hours 1 2>/dev/null \
      | sed -n '/los PRs que esperan una respuesta nuestra/,$p' \
      | tail -n +2 | sed 's/^/  /'
    echo
    echo "=== gates ==="
    pick gates
    echo
    echo "=== updated_at ==="
    pick updated_at
    ;;
  slots)   pick slots ;;
  prs)     pick open_prs ;;
  gates)   pick gates ;;
  issue)   shift; python3 - "$@" <<'PY'
import json, os, sys
n = sys.argv[1]
s = json.load(open(os.environ["ORCH_DIR"] + "/state.json"))
hits = []
for pr, v in (s.get("open_prs") or {}).items():
    if str(v.get("issue")) == n: hits.append(f"PR #{pr}: {json.dumps(v, ensure_ascii=False)}")
for sl, v in (s.get("slots") or {}).items():
    if str(v.get("issue")) == n: hits.append(f"slot {sl}: {json.dumps(v, ensure_ascii=False)}")
for g, v in (s.get("gates") or {}).items():
    if str(g) == n: hits.append(f"gate {g}: {json.dumps(v, ensure_ascii=False)}")
if not hits: print(f"nothing recorded about issue #{n}")
for h in hits: print(h)
PY
    ;;
  keys)
    python3 - <<'PY'
import json, os
p = os.environ["ORCH_DIR"] + "/state.json"
s = json.load(open(p)); tot = os.path.getsize(p)
print(f"state.json = {tot:,} bytes")
for k, v in sorted(s.items(), key=lambda kv: -len(json.dumps(kv[1]))):
    print(f"  {k:<22} {len(json.dumps(v)):>7,} bytes")
PY
    ;;
  history)
    n="${2:-5}"
    tail -n "$n" "$HISTORY" 2>/dev/null | python3 -c '
import sys, json
for line in sys.stdin:
    try: h = json.loads(line)
    except Exception: continue
    print(f"{h.get(\"at\",\"\")}  {h.get(\"action\",\"\")}")
'
    ;;
  raw)     shift; pick "$1" ;;
  *)       echo "usage: orch-state.sh [summary|slots|prs|gates|issue N|keys|history N|raw KEY]" >&2; exit 2 ;;
esac
