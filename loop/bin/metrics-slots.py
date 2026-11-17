#!/usr/bin/env python3
"""MINS-PER-PHASE AND PER-SLOT: the measurement of the lot of 24-10.

Same method as the audit of 2026-10-24, so the numbers before and after the
changes are comparable:

  * a turn is a jsonl file under logs/turns/: its duration is the span between
    its first and its last timestamp;
  * a turn is attributed to a phase with the row of the ledger that closes it
    (the row's timestamp is the END of the turn);
  * the slot of a turn is read from the session id (`ses_loop-<stamp>-<slot>`)
    when it carries one, and from the state file otherwise.

Usage:
  metrics-report.py [since-epoch] [until-epoch]
  metrics-report.py --slot <id> [since-epoch] [until-epoch]

The window defaults to "everything": without arguments it reports the whole
history, which is what the baseline of the audit used.
"""

from __future__ import annotations

import calendar
import collections
import glob
import json
import os
import re
import sys

LOOP = os.environ.get("LOOP_DIR", os.path.expanduser("~/.local/share/solidcraft-loop"))


def turn_durations(turn_dir):
    """{file: (start_epoch, end_epoch)} for every turn log."""
    durs = {}
    for path in glob.glob(os.path.join(turn_dir, "*.jsonl")):
        stamps = []
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                ts = obj.get("timestamp")
                if ts:
                    stamps.append(ts)
        if len(stamps) >= 2:
            durs[os.path.basename(path)] = ((min(stamps)) // 1000, (max(stamps)) // 1000)
    return durs


def ledger_rows(ledger):
    """[(epoch, issue, phase, verdict)] of the ledger, in order."""
    rows = []
    try:
        handle = open(ledger, encoding="utf-8", errors="replace")
    except OSError:
        return rows
    with handle:
        for line in handle:
            if not line.startswith("|"):
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) < 4:
                continue
            match = re.match(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)", cells[0])
            if not match:
                continue
            year, month, day, hour, minute = (int(g) for g in match.groups())
            when = calendar.timegm((year, month, day, hour, minute, 0, 0, 0, 0))
            rows.append((when, cells[1], cells[2], cells[3]))
    return rows


def slot_of_turn(name, state=None):
    """The slot of a turn, from its file name or its session id.

    The session id is `ses_loop-<stamp>-slot<S>`: the slot is the last
    field. The name of the file of a turn carries it too
    (`<stamp>-slot<S>.jsonl`), since the supervisor writes the slot in it
    for the daily turn cap to count the turns of ONE slot. A turn without a
    slot is the single-slot layout: it is "-".
    """
    match = re.search(r"ses_loop-[0-9TZ]+-[0-9]+-slot(\d+)", name)
    if match:
        return match.group(1)
    match = re.search(r"-slot(\d+)\.jsonl$", name)
    if match:
        return match.group(1)
    if state:
        # The state has the slot of the last turn: it is only a hint, and it
        # is used when there is a single turn in the window (the common case
        # of the measurement).
        slots = state.get("slots")
        if isinstance(slots, dict) and len(slots) == 1:
            return next(iter(slots))
    return "-"


def state_slot_of_turn(log_path, state):
    """The slot of a turn, from the state file when the name does not say it.

    The state has the slot of the last turn: it is only a hint, and it is
    used when there is a single turn in the window (the common case of the
    measurement).
    """
    if not state:
        return "-"
    slots = state.get("slots")
    if isinstance(slots, dict) and len(slots) == 1:
        return next(iter(slots))
    return "-"


def main(argv):
    only_slot = None
    args = []
    for arg in argv[1:]:
        if arg == "--slot":
            only_slot = None  # the value is the next argument
            continue
        if only_slot == "" and not args:
            only_slot = arg
            continue
        args.append(arg)
    if only_slot is None and args and args[0].startswith("--slot="):
        only_slot = args.pop(0).split("=", 1)[1]

    since = int(args[0]) if args else 0
    until = int(args[1]) if len(args) > 1 else 2 ** 31

    turn_dir = os.path.join(LOOP, "logs", "turns")
    durs = turn_durations(turn_dir)
    rows = ledger_rows(os.path.join(LOOP, "ledger.md"))

    state = {}
    try:
        with open(os.path.join(LOOP, "state.json"), encoding="utf-8") as fh:
            state = json.load(fh)
    except (OSError, json.JSONDecodeError):
        state = {}

    rows = [r for r in rows if since <= r[0] <= until]
    ends = sorted(v[1] for v in durs.values())
    by_phase = collections.Counter()
    turns = collections.Counter()
    by_slot = collections.Counter()
    slots_turns = collections.Counter()
    total = 0.0
    for when, issue, phase, verdict in rows:
        if not ends:
            continue
        end = min(ends, key=lambda e: abs(e - when))
        name = next(k for k, v in durs.items() if v[1] == end)
        span = (durs[name][1] - durs[name][0]) / 60.0
        slot = slot_of_turn(name, state)
        by_phase[phase] += span
        turns[phase] += 1
        by_slot[slot] += span
        slots_turns[slot] += 1
        total += span

    print(f"=== window {since} .. {until} ===")
    print(f"turns in the ledger: {len(rows)}   minutes of model: {total:.0f}")
    for phase, mins in by_phase.most_common():
        print(f"  {phase:<12} turns={turns[phase]:<4} minutes={mins:6.0f}  "
              f"({mins / max(total, 1) * 100:4.1f} %)")
    code = by_phase.get("implemented", 0) + by_phase.get("published", 0)
    print(f"  phases that write code: {code:.0f} min ({code / max(total, 1) * 100:.1f} %)")

    gate = by_phase.get("gating", 0) + by_phase.get("gated", 0)
    print(f"  gate (gating + gated): {gate:.0f} min ({gate / max(total, 1) * 100:.1f} %)")

    print("  --- per slot ---")
    for slot, mins in by_slot.most_common():
        print(f"  slot {slot:<6} turns={slots_turns[slot]:<4} minutes={mins:6.0f}  "
              f"({mins / max(total, 1) * 100:4.1f} %)")
    if len(by_slot) <= 1:
        print("  (one slot: the parallel layout is not in use yet)")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
