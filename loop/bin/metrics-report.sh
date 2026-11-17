#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The expensive half of the measurement: how many turns and how many minutes
# of model per phase, in a window. Same method as the audit of 2026-10-24, so
# the numbers before and after the changes are comparable.
#
#   metrics-report.sh [since-epoch] [until-epoch]
# ---------------------------------------------------------------------------
set -uo pipefail
LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
since="${1:-0}"; until="${2:-$(date +%s)}"

python3 - "$LOOP_DIR" "$since" "$until" <<'PY'
import json, os, re, sys, glob, collections
loop, since, until = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

# 1. the duration of each turn from its log
durs = {}
for f in glob.glob(os.path.join(loop, "logs", "turns", "*.jsonl")):
    ts = []
    with open(f, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("timestamp"):
                ts.append(o["timestamp"])
    if len(ts) >= 2:
        durs[os.path.basename(f)] = ((min(ts)) // 1000, (max(ts)) // 1000)

# 2. the phase of each turn from the ledger (one row per turn)
rows = []
for line in open(os.path.join(loop, "ledger.md"), encoding="utf-8", errors="replace"):
    if not line.startswith("|"):
        continue
    c = [x.strip() for x in line.strip().strip("|").split("|")]
    if len(c) < 4 or not re.match(r"^\d{4}-\d\d-\d\dT", c[0]):
        continue
    t = int(re.sub(r"[-T:Z]", "", c[0])[:13].ljust(13, "0")[:13]) if False else 0
    m = re.match(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)", c[0])
    if not m:
        continue
    import calendar, time
    t = calendar.timegm((int(m.group(1)), int(m.group(2)), int(m.group(3)),
                          int(m.group(4)), int(m.group(5)), 0, 0, 0, 0))
    rows.append((t, c[1], c[2], c[3]))

rows = [r for r in rows if since <= r[0] <= until]
# the duration of the turn that closes in each row: the row's timestamp is the
# end of the turn, so the duration is the one of the log whose end is closest
ends = sorted(v[1] for v in durs.values())
by_phase = collections.Counter()
turns = collections.Counter()
total = 0.0
for t, issue, phase, verdict in rows:
    if not ends:
        continue
    end = min(ends, key=lambda e: abs(e - t))
    dur = durs[[k for k, v in durs.items() if v[1] == end][0]][1] - \
        durs[[k for k, v in durs.items() if v[1] == end][0]][0]
    by_phase[phase] += dur / 60.0
    turns[phase] += 1
    total += dur / 60.0

print(f"=== window {since} .. {until} ===")
print(f"turns in the ledger: {len(rows)}   minutes of model: {total:.0f}")
for phase, mins in by_phase.most_common():
    print(f"  {phase:<12} turns={turns[phase]:<4} minutes={mins:6.0f}  ({mins/max(total,1)*100:4.1f} %)")
code = by_phase.get("implemented", 0) + by_phase.get("published", 0)
print(f"  phases that write code: {code:.0f} min ({code/max(total,1)*100:.1f} %)")
PY
