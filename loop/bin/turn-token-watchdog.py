#!/usr/bin/env python3
"""Stop a loop turn that goes over its token budget.

WHY: `TURN_BUDGET_MIN` bounds the wall clock of a turn, not its spend. A turn
that runs 240 steps at a 200k context costs 50M tokens and about a dollar, and
the loop runs unattended 24/7. This watchdog reads the tokens the turn has
already spent (the same numbers the audit counts) and stops the turn when it
goes over the budget.

It kills only the `opencode run` process of THIS turn, matched by the session
id, which is unique per turn. When it trips it also writes the marker file,
so the supervisor does not have to guess why the turn stopped: the exit code
of a killed turn depends on how the process died.

    turn-token-watchdog.py <turn-log> <session-id> <budget-tokens> <marker-file> [poll-seconds]

The watchdog exits by itself when the turn is over.
"""

import json
import os
import signal
import sys
import time

GRACE_SECONDS = 120
WAIT_FOR_PID_SECONDS = 300
IDLE_POLLS = 2  # polls without growth before the turn is considered over


def find_turn_pids(session_id):
    """The pids of the `opencode run` processes of this turn.

    The command line of the turn carries the whole prompt, so it is read from
    /proc instead of matched with pgrep: the session id tells the turns apart,
    and this way the watchdog never matches itself.
    """
    pids = []
    needle = session_id.encode()
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid == os.getpid():
            continue
        try:
            with open("/proc/%s/cmdline" % entry, "rb") as handle:
                cmdline = handle.read()
        except OSError:
            continue
        if not cmdline or needle not in cmdline:
            continue
        # Only the model run, not a shell that happens to quote the id.
        if b"opencode" not in cmdline.split(b"\x00")[0]:
            continue
        pids.append(pid)
    return pids


def tokens_in_log(path, offset):
    """Tokens spent so far, and the offset to resume from.

    Only the `step_finish` events carry tokens. The file grows while the turn
    runs, so it is read from the last offset instead of from the start.
    """
    total = 0
    try:
        with open(path, "rb") as handle:
            handle.seek(offset)
            for line in handle:
                if not line.endswith(b"\n"):
                    break  # a partial line: it is read again on the next poll
                offset += len(line)
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if event.get("type") != "step_finish":
                    continue
                tokens = (event.get("part") or {}).get("tokens") or {}
                cache = tokens.get("cache") or {}
                total += (
                    (tokens.get("input", 0) or 0)
                    + (tokens.get("output", 0) or 0)
                    + (tokens.get("reasoning", 0) or 0)
                    + (cache.get("read", 0) or 0)
                    + (cache.get("write", 0) or 0)
                )
    except FileNotFoundError:
        return 0, offset
    return total, offset


def file_size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def stop_turn(pids, session_id, spent):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.time() + GRACE_SECONDS
    while time.time() < deadline:
        if not find_turn_pids(session_id):
            break
        time.sleep(2)
    for pid in find_turn_pids(session_id):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    sys.stderr.write(
        "turn %s went over its token budget (%d tokens): it was stopped\n"
        % (session_id, spent)
    )


def write_marker(path, spent):
    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("%d\n" % spent)
    except OSError:
        pass


def main():
    if len(sys.argv) < 5:
        sys.stderr.write(__doc__)
        return 2
    log_path, session_id, budget_raw, marker = sys.argv[1:5]
    poll = float(sys.argv[5]) if len(sys.argv) > 5 else 15.0
    try:
        budget = int(budget_raw)
    except ValueError:
        return 2
    if budget <= 0:
        return 0  # the budget is disabled

    offset = 0
    spent = 0
    started = time.time()
    last_size = file_size(log_path)
    idle = 0
    warned = False

    while True:
        pids = find_turn_pids(session_id)
        if not pids:
            # The turn has not started yet, or it is over.
            size = file_size(log_path)
            idle = idle + 1 if size == last_size else 0
            last_size = size
            if idle >= IDLE_POLLS:
                return 0
            if time.time() - started > WAIT_FOR_PID_SECONDS:
                return 0
            time.sleep(poll)
            continue

        spent, offset = tokens_in_log(log_path, offset)
        if spent > budget:
            # The turn may have finished between the read and this check: a
            # turn that is over is not a turn that was stopped, so it is not
            # marked as killed.
            if not find_turn_pids(session_id):
                return 0
            # The marker is written BEFORE the turn is stopped: the supervisor
            # reads it as soon as the turn is over, and it must not miss it.
            write_marker(marker, spent)
            stop_turn(pids, session_id, spent)
            return 0

        if not warned and spent > budget * 0.8:
            warned = True
            sys.stderr.write(
                "turn %s is at %d tokens, over 80%% of its budget (%d)\n"
                % (session_id, spent, budget)
            )
        time.sleep(poll)


if __name__ == "__main__":
    sys.exit(main())
