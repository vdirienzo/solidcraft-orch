#!/usr/bin/env python3
"""XERJ against the searches the loop really runs.

XERJ (https://github.com/xerj-org/xerj) is a local-first search engine: one
Rust binary that indexes a folder (code, docs, JSONL, CSV, PDFs) with BM25,
vector and hybrid search, and serves it over an Elasticsearch-compatible API
and an MCP stdio server. The claim is fewer output tokens than grep.

The script measures that claim on THIS workload instead of taking it on
trust. It takes the `grep`/`rg` commands the loop really ran (from the turn
JSONL), runs each one verbatim, runs the equivalent XERJ search, and compares
the three things that matter: the chars of the answer (the token cost), the
wall clock, and whether the answer actually contains what was asked for.

    xerj-bench.py [--turns DIR] [--prefix P] [--url URL]

It needs a XERJ node listening and the `xerj` binary on PATH. Without them
it says so and exits 2: the benchmark is a measurement, and a measurement
that cannot run says nothing.
"""

import argparse
import collections
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

DEFAULT_TURNS = os.path.expanduser("~/.local/share/solidcraft-loop/logs/turns")
GREP = re.compile(r"^(grep|rg)\s")
# One row per kind of search: the pattern that recognises the command, the
# token the answer has to bring back, and the plain-words XERJ query.
KINDS = (
    (r"grep -n.*TRANSITIONS", "TRANSITIONS", "state machine phase transitions allowed transitions"),
    (r"grep -n.*published", "published", "published phase handling"),
    (r"grep -n.*phase", "phase", "phase of a slot in the state machine"),
    (r"grep -n.*failed", "failed", "failed phase handling"),
    (r"grep -n.*triage_from_summary", "triage_from_summary", "triage_from_summary function"),
    (r"grep -n.*ALLOWED", "ALLOWED", "allowed transitions between phases in the state machine"),
    (r"grep -n.*token.*hosts", "oauth", "token hosts.yml oauth credentials in the runbook"),
    (r"grep -n.*review", "review", "review procedure in the runbook"),
    (r"grep -n.*gate-quick", "gate-quick", "gate-quick invocation in the supervisor"),
    (r"grep -n.*quick", "quick", "quick gate invocation in the supervisor"),
    (r"grep -n.*stalls_the_window", "stalls_the_window", "stalls_the_window file_load_ui known baseline failures"),
    (r"grep -n.*name:", "name:", "names of the CI jobs in the workflow"),
)


def real_searches(turns_dir):
    """The grep/rg commands the loop really ran, with how many times."""
    found = collections.Counter()
    for path in sorted(glob.glob(os.path.join(turns_dir, "*.jsonl"))):
        try:
            handle = open(path, errors="replace")
        except OSError:
            continue
        with handle:
            for line in handle:
                if '"tool_use"' not in line:
                    continue
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                part = event.get("part") or {}
                if part.get("tool") not in ("shell", "execute"):
                    continue
                command = (part.get("state") or {}).get("input", {}).get("command", "")
                if not isinstance(command, str):
                    continue
                for raw in command.split("\n"):
                    line_text = raw.strip()
                    if GREP.match(line_text):
                        found[line_text] += 1
    return found


def pick(counter):
    """One representative search per kind, so every kind is measured."""
    chosen = {}
    for command in counter:
        for pattern, expected, query in KINDS:
            if re.search(pattern, command) and expected not in chosen:
                chosen[expected] = (command, query)
    return chosen


def run(command, timeout=90):
    start = time.monotonic()
    try:
        proc = subprocess.run(
            command, capture_output=True, text=True, timeout=timeout, shell=True
        )
        output = proc.stdout
    except subprocess.TimeoutExpired:
        output = ""
    return output, time.monotonic() - start


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--turns", default=DEFAULT_TURNS)
    parser.add_argument("--prefix", default="loop")
    parser.add_argument("--url", default=os.environ.get("XERJ_URL", "http://127.0.0.1:9200"))
    args = parser.parse_args()

    binary = shutil.which("xerj")
    if not binary:
        print("xerj is not on PATH: nothing to compare", file=sys.stderr)
        return 2

    env = dict(os.environ)
    env["XERJ_DISABLE_FEEDBACK"] = "true"
    probe = subprocess.run(
        ["curl", "-s", "--max-time", "5", args.url], capture_output=True, text=True
    )
    if probe.returncode != 0 or not probe.stdout.strip():
        print(f"no XERJ node at {args.url}", file=sys.stderr)
        return 2

    if not os.path.isdir(args.turns):
        print(f"no such directory: {args.turns}", file=sys.stderr)
        return 2

    searches = pick(real_searches(args.turns))
    if not searches:
        print("no grep/rg in the turns: nothing to compare", file=sys.stderr)
        return 2

    print(f"searches measured: {len(searches)}   node: {args.url}   index: {args.prefix}")
    print()
    print(f"{'key':<22} {'grep chars':>11} {'xerj chars':>11} {'ratio':>7} {'grep s':>7} {'xerj s':>7}  hit")
    print("-" * 88)
    totals = {"grep": 0, "xerj": 0, "grep_t": 0.0, "xerj_t": 0.0}
    hits = 0
    for key, (command, query) in sorted(searches.items()):
        grep_out, grep_time = run(command)
        xerj_out, xerj_time = run(
            f"{binary} search --prefix {args.prefix} -k 5 --full 600 {json.dumps(query)}",
            timeout=90,
        )
        grep_ok = key.lower() in grep_out.lower()
        xerj_ok = key.lower() in xerj_out.lower()
        verdict = "OK" if (grep_ok and xerj_ok) else ("XERJ-MISS" if grep_ok else "BOTH-MISS")
        if grep_ok and xerj_ok:
            hits += 1
        ratio = len(xerj_out) / len(grep_out) if grep_out else float("nan")
        print(
            f"{key:<22} {len(grep_out):>11,} {len(xerj_out):>11,} {ratio:>6.2f}x "
            f"{grep_time:>7.2f} {xerj_time:>7.2f}  {verdict}"
        )
        totals["grep"] += len(grep_out)
        totals["xerj"] += len(xerj_out)
        totals["grep_t"] += grep_time
        totals["xerj_t"] += xerj_time

    print("-" * 88)
    print(
        f"total: grep {totals['grep']:,} chars / {totals['grep_t']:.2f} s    "
        f"xerj {totals['xerj']:,} chars / {totals['xerj_t']:.2f} s"
    )
    if totals["grep"]:
        print(
            f"chars: {100*(totals['xerj']-totals['grep'])/totals['grep']:+.1f} %    "
            f"time: {totals['xerj_t']/max(totals['grep_t'],1e-9):.2f}x"
        )
    print(f"usable answers (both contain the key): {hits}/{len(searches)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
