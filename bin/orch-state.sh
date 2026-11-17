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
#
# EXIT CODES:
#   0  the part was printed
#   1  the state could not be read, or nothing is known about what was asked
#   2  wrong usage
#   A sub-command that fails is NOT hidden: the failure is said out loud and
#   the exit code says it too (rule 7: a verdict that does not reach the exit
#   code is worse than no verdict).
set -uo pipefail
# The paths come from the environment, with the default of THIS
# machine: the other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
export ORCH_DIR
STATE="$ORCH_DIR/state.json"
HISTORY="$ORCH_DIR/history.jsonl"

have_jq() { command -v jq >/dev/null 2>&1; }

# The first failure decides the exit code of the script: the rc of the thing
# that failed is PROPAGATED, not replaced by a generic 1 (rule 7).
FAIL_RC=0
fallo() { [ "$FAIL_RC" -eq 0 ] && FAIL_RC="$1"; return 0; }

# Read a key with python3 (always present here) and print a compact form.
#   pick <key>         the key; rc=1 if the key is not there
#   pick --soft <key>  the key; a key that is not there is NOT an error
# A state that cannot be read is ALWAYS an error, and it is said on stderr:
# a state that cannot be read is not a state without contents.
pick() {
  python3 - "$@" <<'PY'
import json, os, sys
path = os.environ["ORCH_DIR"] + "/state.json"
args = sys.argv[1:]
soft = bool(args) and args[0] == "--soft"
if soft:
    args = args[1:]
key = args[0] if args else None
try:
    with open(path, encoding="utf-8") as fh:
        s = json.load(fh)
except Exception as e:
    print(f"state.json unreadable: {e}", file=sys.stderr)
    raise SystemExit(1)
if key is None:
    for k in ("orchestrator", "version", "started_at", "updated_at"):
        if k in s: print(f"{k}: {s[k]}")
    raise SystemExit(0)
if key not in s:
    print(f"no such key: {key}")
    raise SystemExit(0 if soft else 1)
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
    fail=0
    pending="$(python3 - <<'PY'
import json, os, sys
try:
    with open(os.environ["ORCH_DIR"] + "/state.json", encoding="utf-8") as fh:
        s = json.load(fh)
except Exception as e:
    print(f"state.json unreadable: {e}", file=sys.stderr)
    raise SystemExit(1)
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
    [ $? -ne 0 ] && { fail=1; fallo 1; }
    if [ -n "$pending" ]; then
      echo "=== PENDIENTES (hay que mirarlos) ==="
      echo "$pending"
      echo
    fi
    echo "=== slots ==="
    pick --soft slots || { fail=1; fallo 1; }
    echo
    echo "=== open PRs ==="
    pick --soft open_prs || { fail=1; fallo 1; }
    echo
    echo "=== slots atascados (los locks, SIN llamar a GitHub) ==="
    # slot-stale.sh --locks is the mode that does NOT talk to GitHub. The old
    # call (--hours 1) made five calls to gh (one per PR) and took 3m22s
    # measured: the agent waited three and a half minutes to see the state.
    # The threshold stays the same (--hours 1): the summary shows the same
    # slots it always showed, it just does not pay GitHub for them.
    stale="$(bash "$ORCH_DIR/bin/slot-stale.sh" --locks --hours 1 2>&1)"
    stale_rc=$?
    if [ "$stale_rc" -ne 0 ]; then
      # RULE 7: the failure is not hidden. It is said (stderr) and the exit
      # code says it too: "no locks" and "I could not read the locks" are
      # not the same thing. What the watchdog said is printed as well, so
      # the section never reads like "there is nothing stuck".
      echo "  (no se pudo leer el estado de los locks: rc=$stale_rc)" >&2
      printf '%s\n' "$stale" | sed 's/^/  /'
      fail=1; fallo "$stale_rc"
    elif [ -n "$stale" ]; then
      printf '%s\n' "$stale" | sed 's/^/  /'
    fi
    echo
    echo "=== PRs que esperan una respuesta nuestra ==="
    echo "  (no se lista en el resumen: son 5 llamadas a GitHub y tardaba 3m22s)"
    echo "  a pedido: bash bin/slot-stale.sh --prs"
    echo
    echo "=== gates ==="
    pick --soft gates || { fail=1; fallo 1; }
    echo
    echo "=== updated_at ==="
    pick --soft updated_at || { fail=1; fallo 1; }
    [ "$fail" -eq 0 ] || exit "$FAIL_RC"
    exit 0
    ;;
  slots)   pick slots ;;
  prs)     pick open_prs ;;
  gates)   pick gates ;;
  issue)   shift
    if [ $# -lt 1 ]; then
      echo "usage: orch-state.sh issue <n>" >&2; exit 2
    fi
    python3 - "$@" <<'PY'
import json, os, sys

n = sys.argv[1]
try:
    with open(os.environ["ORCH_DIR"] + "/state.json", encoding="utf-8") as fh:
        s = json.load(fh)
except Exception as e:
    print(f"state.json unreadable: {e}", file=sys.stderr)
    raise SystemExit(1)


def pr_entries(value):
    """open_prs is a LIST of entries, but it was also written as a DICT of
    "PR number" -> entry. Both are normalized to a list of (number, entry):
    the number is the "number" key, the "pr" key, or the key of the dict.
    A reader that assumes one shape dies on the other one: it was the reason
    the issue command NEVER answered.
    """
    out = []
    if isinstance(value, list):
        for e in value:
            if isinstance(e, dict):
                out.append((e.get("number") or e.get("pr"), e))
            elif isinstance(e, (int, str)):
                out.append((e, {}))
    elif isinstance(value, dict):
        for key, e in value.items():
            if isinstance(e, dict):
                out.append((e.get("number") or e.get("pr") or key, e))
            else:
                out.append((key, {"value": e}))
    return out


def as_map(value):
    """slots and gates are DICTS; a list of entries is normalized too."""
    if isinstance(value, dict):
        return value
    out = {}
    if isinstance(value, list):
        for i, e in enumerate(value):
            if isinstance(e, dict):
                key = e.get("slot") or e.get("id") or e.get("name") or e.get("number") or i
                out[str(key)] = e
    return out


hits = []
for num, e in pr_entries(s.get("open_prs")):
    if str(e.get("issue", "")) == str(n):
        label = f"PR #{num}" if num is not None else "PR #?"
        hits.append(f"{label}: {json.dumps(e, ensure_ascii=False)}")
for sl, v in as_map(s.get("slots")).items():
    if isinstance(v, dict) and str(v.get("issue", "")) == str(n):
        hits.append(f"slot {sl}: {json.dumps(v, ensure_ascii=False)}")
for g, v in as_map(s.get("gates")).items():
    if str(g) == str(n):
        hits.append(f"gate {g}: {json.dumps(v, ensure_ascii=False)}")
if not hits:
    print(f"nothing recorded about issue #{n}")
    raise SystemExit(1)
for h in hits:
    print(h)
PY
    ;;
  keys)
    python3 - <<'PY'
import json, os, sys
p = os.environ["ORCH_DIR"] + "/state.json"
try:
    with open(p, encoding="utf-8") as fh:
        s = json.load(fh)
except Exception as e:
    print(f"state.json unreadable: {e}", file=sys.stderr)
    raise SystemExit(1)
tot = os.path.getsize(p)
print(f"state.json = {tot:,} bytes")
for k, v in sorted(s.items(), key=lambda kv: -len(json.dumps(kv[1]))):
    print(f"  {k:<22} {len(json.dumps(v)):>7,} bytes")
PY
    ;;
  history)
    n="${2:-5}"
    # The Python is in single quotes, so it cannot use single quotes inside:
    # the f-string used to be written with escaped double quotes, which is a
    # SyntaxError before Python 3.12 (backslash inside an f-string
    # expression). The command the HANDOFF documents died with a traceback.
    tail -n "$n" "$HISTORY" 2>/dev/null | python3 -c '
import sys, json
for line in sys.stdin:
    try: h = json.loads(line)
    except Exception: continue
    print(h.get("at", "") + "  " + h.get("action", ""))
'
    ;;
  raw)     shift
    if [ $# -lt 1 ]; then
      echo "usage: orch-state.sh raw <key>" >&2; exit 2
    fi
    pick "$1"
    ;;
  *)       echo "usage: orch-state.sh [summary|slots|prs|gates|issue N|keys|history N|raw KEY]" >&2; exit 2 ;;
esac
