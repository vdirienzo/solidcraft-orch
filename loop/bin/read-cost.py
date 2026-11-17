#!/usr/bin/env python3
"""What the loop's reads cost, and what could replace them.

THE MECHANISM: the orchestrator of the loop runs with `--standalone`, so it
has no memory between turns: every turn it re-reads the machinery it needs
(`bin/state.py`, `ledger.md`, the slot view, the gate verdict). A tool output
does not cost once. It is appended to the context of the turn, and every
later step of the same turn re-sends the whole context, so the output is paid
once per remaining step.

This script measures that cost on the real turn logs and simulates what
different ways of serving the same information would cost:

  baseline  what really happened
  xerj      every read of a loop file replaced by an XERJ search answer
            (3.362 chars, the measured median at `-k 5 --full 600`)
  chunked   every read honours offset/limit (5.991 chars, the measured
            median of the reads that DID pass it)
  digest    `bin/state.py` and `ledger.md` are out of the agent's reach and
            the supervisor injects a digest once per turn
  combined  digest + chunked

The simulation reconstructs the context of every step from the real one:

    ctx[i] = ctx[i-1] + tool_output_chars_before_step_i / 4 + model_output[i-1]

and prints the error of that reconstruction on the untouched baseline. If the
error is not small, the numbers below it are garbage.

    read-cost.py [--turns DIR] [--top N]
    read-cost.py --marginal BEFORE AFTER [--since DATE] [--until DATE]

`--turns` is the directory with the turn JSONL of the loop (by default the
runtime one). The script needs nothing else: no database, no network.

`--marginal` compares TWO sets of turns (before and after a change) and
prints the numbers per live turn: the ones that are comparable when the two
sides did not have the same number of turns. The dead turns are counted
apart (the agent, the transport, the rest).
"""

import argparse
import collections
import glob
import hashlib
import json
import os
import re
import statistics
import sys

DEFAULT_TURNS = os.path.expanduser("~/.local/share/solidcraft-loop/logs/turns")
LOOP = "/home/user/.local/share/solidcraft-loop/"
CHARS_PER_TOKEN = 4.0

# Measured on the real logs: the median chars of a read that DID pass
# offset/limit, and the median chars of an XERJ answer at `-k 5 --full 600`.
CHUNKED_CHARS = 5991
XERJ_CHARS = 3362

# The files the supervisor would replace with a digest.
DIGEST_FILES = ("bin/state.py", "ledger.md")

# Why the agent reads `bin/state.py`, told by the text that asks for it.
STATE_READ_REASONS = (
    ("the transitions of the state machine", r"transition|transici|state machine"),
    ("the rules that accept the delta", r"\bdelta\b|merge|accept|schema|reglas"),
    ("the phases and the terminal ones", r"phase|fase|terminal|work_in_progress"),
    ("loading the context (noise)", r"load|context|start|leer|read"),
)


def load_turns(turns_dir):
    """Read every turn JSONL into a list of turns.

    A turn keeps its events in file order: the texts, the tool outputs and
    the steps. The tools of a step are the ones that come before its
    `step_finish`, so the buckets are exact and need no heuristic.
    """
    turns = []
    for path in sorted(glob.glob(os.path.join(turns_dir, "*.jsonl"))):
        events = []
        try:
            handle = open(path, errors="replace")
        except OSError:
            continue
        with handle:
            for line in handle:
                if (
                    '"step_finish"' not in line
                    and '"tool_use"' not in line
                    and '"text"' not in line
                ):
                    continue
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                kind = event.get("type")
                part = event.get("part") or {}
                if kind == "tool_use":
                    state = part.get("state") or {}
                    output = state.get("output") or ""
                    if not isinstance(output, str):
                        output = json.dumps(output)
                    inp = state.get("input") or {}
                    events.append(
                        {
                            "kind": "tool",
                            "tool": part.get("tool") or "?",
                            "chars": len(output),
                            # The arguments of the call stay in the context too.
                            "args": len(json.dumps(inp, ensure_ascii=False)),
                            "file": inp.get("filePath") or inp.get("path") or "",
                            "limit": inp.get("limit"),
                            "offset": inp.get("offset"),
                            "digest": hashlib.md5(output.encode()).hexdigest(),
                        }
                    )
                elif kind == "step_finish":
                    tokens = part.get("tokens") or {}
                    cache = tokens.get("cache") or {}
                    events.append(
                        {
                            "kind": "step",
                            "ctx": (tokens.get("input") or 0)
                            + (cache.get("read") or 0)
                            + (cache.get("write") or 0),
                            "out": (tokens.get("output") or 0)
                            + (tokens.get("reasoning") or 0),
                        }
                    )
                elif kind == "text":
                    text = (part.get("text") or "").strip()
                    if text:
                        events.append({"kind": "text", "text": text})
        steps = [event for event in events if event["kind"] == "step"]
        if len(steps) < 2:
            continue
        turns.append({"path": path, "events": events, "steps": steps})
    return turns


def tools_of(turn):
    """The tool outputs of the turn, with the step they belong to.

    A tool belongs to the step that closes after it: the number of steps
    seen so far is the index of the step it feeds.
    """
    buckets = collections.defaultdict(list)
    flat = []
    seen_steps = 0
    for event in turn["events"]:
        if event["kind"] == "step":
            seen_steps += 1
            continue
        if event["kind"] != "tool":
            continue
        event["step"] = seen_steps
        buckets[seen_steps].append(event)
        flat.append(event)
    return flat, buckets


def reason_of_reads(turn):
    """The text that asked for each read, from the order of the events."""
    reasons = {}
    last_text = ""
    for event in turn["events"]:
        if event["kind"] == "text":
            last_text = (last_text + " " + event["text"]).strip()
        elif event["kind"] == "tool" and event["tool"] == "read":
            reasons[id(event)] = last_text[-600:]
    return reasons


def tool_breakdown(turns):
    """Chars and calls per tool."""
    calls = collections.Counter()
    chars = collections.Counter()
    for turn in turns:
        for tool in tools_of(turn)[0]:
            calls[tool["tool"]] += 1
            chars[tool["tool"]] += tool["chars"]
    return calls, chars


def read_duplication(turns):
    """How many reads return a byte-identical output to an earlier one."""
    total = 0
    repeated = 0
    repeated_chars = 0
    seen = set()
    for turn in turns:
        for tool in tools_of(turn)[0]:
            if tool["tool"] != "read":
                continue
            total += 1
            if tool["digest"] in seen:
                repeated += 1
                repeated_chars += tool["chars"]
            else:
                seen.add(tool["digest"])
    return total, repeated, repeated_chars


def top_files(turns):
    """The files the agent reads, by chars."""
    by_file = collections.defaultdict(lambda: [0, 0, set()])
    for turn in turns:
        for tool in tools_of(turn)[0]:
            if tool["tool"] != "read":
                continue
            name = tool["file"].replace(LOOP, "loop/")
            entry = by_file[name]
            entry[0] += tool["chars"]
            entry[1] += 1
            entry[2].add(tool["digest"])
    return by_file


def state_read_purposes(turns):
    """Classify every read of `bin/state.py` by the text that asked for it."""
    classes = collections.Counter()
    for turn in turns:
        reasons = reason_of_reads(turn)
        for tool in tools_of(turn)[0]:
            if tool["tool"] != "read" or not tool["file"].endswith("bin/state.py"):
                continue
            reason = reasons.get(id(tool), "")
            for label, pattern in STATE_READ_REASONS:
                if re.search(pattern, reason, re.I):
                    classes[label] += 1
                    break
            else:
                classes["other"] += 1
    return classes


def context_split(turns):
    """How much of the cache read is the fixed base and how much is growth."""
    fixed = 0
    total = 0
    steps = []
    for turn in turns:
        base = turn["steps"][0]["ctx"]
        fixed += base * len(turn["steps"])
        total += sum(step["ctx"] for step in turn["steps"])
        steps.append(len(turn["steps"]))
    return fixed, total, steps


def apply_scenario(tool, scenario):
    """The chars a tool output would have under a scenario.

    The arguments of the call are not scenario-dependent: they are what the
    model asked for, and they stay in the context whatever the answer is.
    """
    size = tool["chars"]
    if tool["tool"] != "read" or not tool["file"].startswith(LOOP):
        return size
    digested = scenario in ("digest", "combined") and any(
        tool["file"].endswith(name) for name in DIGEST_FILES
    )
    if digested:
        return 0
    if scenario == "xerj":
        return min(size, XERJ_CHARS)
    if scenario in ("chunked", "combined") and (
        tool["limit"] is None and tool["offset"] is None
    ):
        return min(size, CHUNKED_CHARS)
    return size


def simulate(turns, scenario):
    """Reconstruct the context of every step under a scenario."""
    total = 0
    tool_chars = 0
    for turn in turns:
        steps = turn["steps"]
        buckets = tools_of(turn)[1]
        ctx = steps[0]["ctx"]
        for index in range(1, len(steps)):
            chars = 0.0
            for tool in buckets.get(index, []):
                chars += apply_scenario(tool, scenario)
                chars += tool["args"]
            tool_chars += chars
            ctx = ctx + chars / CHARS_PER_TOKEN + steps[index - 1]["out"]
            total += ctx
    return total, tool_chars


def validate(turns):
    """The error of the reconstruction on the untouched baseline."""
    ratios = []
    for turn in turns:
        steps = turn["steps"]
        buckets = tools_of(turn)[1]
        for index in range(1, len(steps)):
            actual = steps[index]["ctx"] - steps[index - 1]["ctx"]
            if actual <= 0:
                continue
            chars = sum(tool["chars"] + tool["args"] for tool in buckets.get(index, []))
            predicted = chars / CHARS_PER_TOKEN + steps[index - 1]["out"]
            ratios.append(predicted / actual)
    return statistics.median(ratios) if ratios else 0.0


def print_tool_breakdown(turns):
    calls, chars = tool_breakdown(turns)
    total_chars = sum(chars.values())
    total_calls = sum(calls.values())
    print("=" * 72)
    print(f"turns: {len(turns)}   tool calls: {total_calls:,}   chars: {total_chars:,}")
    print()
    print(f"{'tool':<12} {'calls':>8} {'chars':>13} {'% chars':>9} {'chars/call':>12}")
    for name, size in chars.most_common():
        print(
            f"{name:<12} {calls[name]:>8,} {size:>13,} "
            f"{100*size/max(total_chars,1):>8.1f}% {size//max(calls[name],1):>12,}"
        )


def print_reads(turns, top):
    reads, repeated, repeated_chars = read_duplication(turns)
    _, chars = tool_breakdown(turns)
    read_chars = chars.get("read", 0)
    print()
    print(
        f"reads: {reads:,}   identical to an earlier one: {repeated:,} "
        f"({100*repeated/max(reads,1):.1f}%)   chars: {repeated_chars:,} "
        f"({100*repeated_chars/max(read_chars,1):.1f}% of the read chars)"
    )
    print()
    print(f"{'file':<44} {'chars':>12} {'reads':>7} {'unique':>7} {'chars/read':>11}")
    for name, (size, count, unique) in sorted(
        top_files(turns).items(), key=lambda kv: -kv[1][0]
    )[:top]:
        print(
            f"{name[:44]:<44} {size:>12,} {count:>7,} {len(unique):>7,} "
            f"{size//max(count,1):>11,}"
        )


def print_state_reads(turns):
    classes = state_read_purposes(turns)
    total = sum(classes.values())
    if not total:
        return
    print()
    print(f"why the agent reads bin/state.py ({total} reads):")
    for label, count in classes.most_common():
        print(f"   {count:>4} ({100*count/total:>5.1f}%)  {label}")


def print_context(turns):
    fixed, cache_read, steps = context_split(turns)
    print()
    print(
        f"cache read: {cache_read:,} tokens   steps per turn: median "
        f"{statistics.median(steps):.0f}"
    )
    print(f"  the fixed base repeated in every step: {100*fixed/max(cache_read,1):.1f} %")
    print(f"  the growth (the tool outputs):        {100*(1-fixed/max(cache_read,1)):.1f} %")


def print_scenarios(turns):
    _, cache_read, _ = context_split(turns)
    print()
    print(f"validation of the reconstruction: {validate(turns):.3f} (1.000 = exact)")
    print()
    print(f"{'scenario':<10} {'cache read':>15} {'change':>9} {'tool chars':>13}")
    print("-" * 52)
    baseline = None
    for scenario in ("baseline", "xerj", "chunked", "digest"):
        total, tool_chars = simulate(turns, scenario)
        if baseline is None:
            baseline = total
        change = 100 * (total - baseline) / baseline
        print(f"{scenario:<10} {total:>15,.0f} {change:>8.1f}% {tool_chars:>13,.0f}")
    total, _ = simulate(turns, "combined")
    change = 100 * (total - baseline) / baseline
    print(f"{'combined':<10} {total:>15,.0f} {change:>8.1f}% {'':>13}")
    print()
    print(
        f"the reconstruction is {100*(baseline-cache_read)/cache_read:+.1f} % against the "
        f"real {cache_read:,.0f} tokens: the bias is in the model, not in the"
    )
    print(
        "scenarios, so the change of every scenario against the baseline is the"
    )
    print("comparable number.")


# --- the marginal effect of a change -------------------------------------------
# The analysis above answers "what does the loop spend on its reads". This
# one answers "what did the change save": two sets of turns, before and
# after, compared turn by turn.
#
# The totals of the two sets are NOT comparable when they cover different
# windows or a different number of turns: the numbers that ARE comparable
# are the ones PER TURN. The dead turns are counted apart: a turn that
# died before the model was called is not a turn that reads anything.


def scan_turns(turns_dir, since="", until=""):
    """Every turn file of the directory, with the numbers a comparison needs.

    Unlike `load_turns`, this one does NOT drop the turns that died before
    their second step: a dead turn is exactly what the preflight of the
    agent was added to kill, so it has to be counted, not ignored.
    """
    scans = []
    for path in sorted(glob.glob(os.path.join(turns_dir, "*.jsonl"))):
        stamp = os.path.basename(path)[:10]          # YYYY-MM-DD of the name
        if since and stamp < since:
            continue
        if until and stamp > until:
            continue
        steps = 0
        cost = 0.0
        tokens = {"input": 0, "output": 0, "reasoning": 0,
                  "cache_read": 0, "cache_write": 0}
        errors = []
        reads = 0
        read_chars = 0
        file_chars = collections.Counter()
        try:
            handle = open(path, errors="replace")
        except OSError:
            continue
        with handle:
            for line in handle:
                if ('"step_finish"' not in line and '"error"' not in line
                        and '"tool_use"' not in line):
                    continue
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                kind = event.get("type")
                part = event.get("part") or {}
                if kind == "step_finish":
                    steps += 1
                    cost += float(part.get("cost") or 0)
                    tk = part.get("tokens") or {}
                    cache = tk.get("cache") or {}
                    tokens["input"] += tk.get("input") or 0
                    tokens["output"] += tk.get("output") or 0
                    tokens["reasoning"] += tk.get("reasoning") or 0
                    tokens["cache_read"] += cache.get("read") or 0
                    tokens["cache_write"] += cache.get("write") or 0
                elif kind == "error":
                    error = event.get("error") or {}
                    errors.append(str(error.get("message") or ""))
                elif kind == "tool_use":
                    state = part.get("state") or {}
                    output = state.get("output") or ""
                    if not isinstance(output, str):
                        output = json.dumps(output)
                    inp = state.get("input") or {}
                    name = inp.get("filePath") or inp.get("path") or ""
                    if part.get("tool") == "read" and name:
                        reads += 1
                        read_chars += len(output)
                        file_chars[name] += len(output)
        scans.append({
            "path": path, "steps": steps, "cost": cost, "tokens": tokens,
            "errors": errors, "reads": reads, "read_chars": read_chars,
            "file_chars": file_chars,
        })
    return scans


def dead_cause(errors):
    """Why a turn died: the agent, the transport or something else.

    The agent comes first: it is the one the preflight kills before the
    model is called, and a turn that ends with it says nothing about the
    reads of the loop.
    """
    for message in errors:
        if "Agent not found" in message:
            return "agent"
    for message in errors:
        if "ECONNRESET" in message or "Transport:" in message:
            return "transport"
    for message in errors:
        if message.strip():
            return "other"
    return ""


def marginal_metrics(scans):
    """The numbers of a set of turns: the totals and the ones per live turn."""
    causes = collections.Counter(dead_cause(scan["errors"]) for scan in scans)
    live = [scan for scan in scans if not dead_cause(scan["errors"])]

    def median(values):
        return statistics.median(values) if values else 0.0

    tokens = {}
    for key in ("input", "output", "reasoning", "cache_read", "cache_write"):
        tokens[key] = sum(scan["tokens"][key] for scan in scans)
    files = collections.Counter()
    for scan in scans:
        files.update(scan["file_chars"])

    return {
        "turns": len(scans),
        "live": len(live),
        "dead_agent": causes.get("agent", 0),
        "dead_transport": causes.get("transport", 0),
        "dead_other": causes.get("other", 0),
        "steps": sum(scan["steps"] for scan in scans),
        "cost": sum(scan["cost"] for scan in scans),
        "tokens": tokens,
        "reads": sum(scan["reads"] for scan in scans),
        "read_chars": sum(scan["read_chars"] for scan in scans),
        "files": files,
        # The comparable numbers: per LIVE turn, and the median (a turn that
        # publishes is not a turn that triages).
        "per_turn": {
            "steps": median([scan["steps"] for scan in live]),
            "cost": median([scan["cost"] for scan in live]),
            "input": median([scan["tokens"]["input"] for scan in live]),
            "output": median([scan["tokens"]["output"] for scan in live]),
            "cache_read": median([scan["tokens"]["cache_read"] for scan in live]),
            "reads": median([scan["reads"] for scan in live]),
            "read_chars": median([scan["read_chars"] for scan in live]),
        },
    }


def change_of(before, after):
    """The change of a number, as a percentage of the first one."""
    if not before:
        return "n/a"
    return f"{100 * (after - before) / before:+.1f}%"


def print_marginal(before_scans, after_scans, top=8):
    """The comparison of two sets of turns."""
    before = marginal_metrics(before_scans)
    after = marginal_metrics(after_scans)

    print("=" * 72)
    print("the marginal effect of the change (the comparable numbers are the")
    print("ones per LIVE turn: the totals depend on the window and on how")
    print("many turns each side had)")
    print()
    header = f"{'':26}{'before':>14}{'after':>14}{'change':>12}"
    print(header)
    print("-" * len(header))

    def row(label, key, fmt="{:,.0f}"):
        b = before[key]
        a = after[key]
        print(f"{label:<26}{fmt.format(b):>14}{fmt.format(a):>14}"
              f"{change_of(b, a):>12}")

    row("turns", "turns")
    row("live turns", "live")
    row("dead (the agent)", "dead_agent")
    row("dead (the transport)", "dead_transport")
    row("dead (other)", "dead_other")
    print("-" * len(header))
    print("per live turn (the median)")
    for label, key, fmt in (
            ("steps", "steps", "{:,.1f}"),
            ("cost (USD)", "cost", "{:,.5f}"),
            ("tokens in", "input", "{:,.0f}"),
            ("tokens out", "output", "{:,.0f}"),
            ("cache read", "cache_read", "{:,.0f}"),
            ("reads", "reads", "{:,.1f}"),
            ("read chars", "read_chars", "{:,.0f}")):
        b = before["per_turn"][key]
        a = after["per_turn"][key]
        print(f"{label:<26}{fmt.format(b):>14}{fmt.format(a):>14}"
              f"{change_of(b, a):>12}")

    # The files: the read chars per live turn of each one. This is where
    # the digest shows up: the ledger and the view are not read whole.
    print()
    print("the read chars per live turn, by file")
    names = set()
    for side in (before, after):
        live = max(side["live"], 1)
        for name in side["files"]:
            names.add(name)
    rows = []
    for name in names:
        b = before["files"].get(name, 0) / max(before["live"], 1)
        a = after["files"].get(name, 0) / max(after["live"], 1)
        rows.append((b + a, name, b, a))
    rows.sort(reverse=True)
    print(f"{'file':<44}{'before':>12}{'after':>12}{'change':>12}")
    for _, name, b, a in rows[:top]:
        print(f"{name[-44:]:<44}{b:>12,.0f}{a:>12,.0f}{change_of(b, a):>12}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--turns", default=DEFAULT_TURNS)
    parser.add_argument("--top", type=int, default=12)
    parser.add_argument("--marginal", nargs=2, metavar=("BEFORE", "AFTER"),
                        help="compare two directories of turns (before/after)")
    parser.add_argument("--since", default="",
                        help="only the turns of this date (YYYY-MM-DD) or later")
    parser.add_argument("--until", default="",
                        help="only the turns up to this date (YYYY-MM-DD)")
    args = parser.parse_args()

    # The marginal mode is a mode of its own: it compares two sets of
    # turns and it does not need the analysis of `--turns`.
    if args.marginal:
        before_dir, after_dir = args.marginal
        for directory in (before_dir, after_dir):
            if not os.path.isdir(directory):
                print(f"no such directory: {directory}", file=sys.stderr)
                return 2
        before_scans = scan_turns(before_dir, args.since, args.until)
        after_scans = scan_turns(after_dir, args.since, args.until)
        if not before_scans or not after_scans:
            print("one of the two sets has no turns", file=sys.stderr)
            return 2
        print(f"before: {before_dir} ({len(before_scans)} turn files)")
        print(f"after:  {after_dir} ({len(after_scans)} turn files)")
        print()
        print_marginal(before_scans, after_scans, args.top)
        return 0

    if not os.path.isdir(args.turns):
        print(f"no such directory: {args.turns}", file=sys.stderr)
        return 2

    turns = load_turns(args.turns)
    if not turns:
        print(f"no turns in {args.turns}", file=sys.stderr)
        return 2

    print_tool_breakdown(turns)
    print_reads(turns, args.top)
    print_state_reads(turns)
    print_context(turns)
    print_scenarios(turns)
    return 0


if __name__ == "__main__":
    sys.exit(main())
