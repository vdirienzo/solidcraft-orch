#!/usr/bin/env python3
"""Compare the spend of a day against the baseline of the spend.

WHAT IT COMPARES: the tokens and the dollars of a UTC day (the database of
OpenCode and the JSONL of the loop, counted once, through bin/oc-tokens)
against the numbers of metrics-baseline.md: the average of the days before
the change of the ceiling and the objective that was set for it.

    compare-baseline.py [--day YYYY-MM-DD] [--days N] [--baseline FILE]
                         [--loop-dir DIR] [--no-warn]

It writes the report to reports/baseline-<days>.md and it WARNS when the
objective is missed: the warning goes to the log of the supervisor, to the
report and to the journal of the unit that runs it. The exit code is 1 when
the objective is missed, so the timer that runs it shows the failure.

THE DAYS ARE UTC: the stamps of the database and of the JSONL are UTC, and
the baseline is written in UTC days too.

THE LEDGER IS SPLIT: the old rows live in the gzip chunks of the `ledger`
directory next to the ledger and the current rows live in ledger.md. Every
chunk is read, in chronological order, and a chunk that is broken is
reported on stderr and skipped instead of crashing the report.

THE QUALITY IS COMPARED TOO: a day that spends less because it did less is
not a success. The ledger says how many turns the loop ran and how many
pull requests it published that day, and a day that published nothing is
NOT a success even if it spent very little.
"""

import argparse
import datetime as dt
import gzip
import json
import os
import re
import subprocess
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_LOOP_DIR = os.path.expanduser("~/.local/share/solidcraft-loop")


def number(text):
    """A number written in Spanish: 751,8 means 751.8."""
    text = text.strip().replace(" ", "")
    if "," in text:
        text = text.replace(".", "").replace(",", ".")
    return float(text)


def human_tokens(value):
    if value >= 1e9:
        return "%.2f B" % (value / 1e9)
    if value >= 1e6:
        return "%.1f M" % (value / 1e6)
    if value >= 1e3:
        return "%.1f K" % (value / 1e3)
    return "%.0f" % value


def human_money(value):
    return "%.2f $" % value


def read_baseline(path):
    """The numbers of the baseline: the average of the days before, and the objective."""
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        sys.stderr.write("compare-baseline: the baseline is not readable: %s\n" % error)
        return None
    baseline = {}
    # The patterns stop before the accented word ("día"): the encoding of the
    # file is not something a regex should depend on.
    patterns = {
        "tokens": r"\|\s*\*\*Media\*\*\s*\|\s*\*\*([\d.,]+)\s*M/d\w*",
        "cost": r"\|\s*\*\*Media\*\*.*?\*\*([\d.,]+)\s*\$/d\w*",
        "target_tokens": r"\|\s*Tokens/d\w*\s*\|[^|]*\|\s*<\s*([\d.,]+)\s*M",
        "target_cost": r"\|\s*Coste/d\w*\s*\|[^|]*\|\s*<\s*([\d.,]+)\s*\$",
    }
    for key, pattern in patterns.items():
        found = re.search(pattern, text)
        if not found:
            sys.stderr.write(
                "compare-baseline: the baseline (%s) does not have the number '%s'\n"
                % (path, key)
            )
            return None
        value = number(found.group(1))
        baseline[key] = value * 1e6 if key.endswith("tokens") else value
    return baseline


def read_days(counter, hours):
    """The spend of each day, from the counter."""
    try:
        result = subprocess.run(
            [counter, "--json", "--hours", str(hours)],
            capture_output=True,
            text=True,
            timeout=300,
        )
    except (OSError, subprocess.SubprocessError) as error:
        sys.stderr.write("compare-baseline: the counter failed: %s\n" % error)
        return {}
    if result.returncode != 0:
        sys.stderr.write(
            "compare-baseline: the counter failed: %s\n" % result.stderr.strip()[:300]
        )
        return {}
    try:
        return json.loads(result.stdout).get("by_day") or {}
    except ValueError as error:
        sys.stderr.write("compare-baseline: the counter said nothing usable: %s\n" % error)
        return {}


# The phases of a turn that carry work: the ones that are not an idle turn
# (nothing to do) and not a failure.
WORK_PHASES = (
    "selected",
    "claimed",
    "implemented",
    "gating",
    "gated",
    "published",
    "install",
    "harden",
)


def chunk_sort_key(name):
    """The order of the archived chunks of the ledger: the oldest month first.

    The name of a chunk is ledger-YYYY-MM.md.gz. A file that does not
    follow that name goes last, sorted by its name.
    """
    match = re.match(r"ledger-(\d{4})-(\d{2})", name)
    if not match:
        return (9999, 99, name)
    return (int(match.group(1)), int(match.group(2)), name)


def ledger_sources(path):
    """The files the ledger is split into, in chronological order.

    The ledger is split: the old rows live in the gzip chunks of the
    `ledger` directory next to the ledger (ledger-YYYY-MM.md.gz) and the
    current ledger.md holds the rows that are not archived yet. The oldest
    chunk comes first and the current file comes last.
    """
    directory = os.path.join(os.path.dirname(os.path.abspath(path)), "ledger")
    try:
        names = os.listdir(directory)
    except OSError:
        names = []
    sources = []
    for name in sorted(names, key=chunk_sort_key):
        if not name.endswith(".gz"):
            continue
        sources.append(os.path.join(directory, name))
    sources.append(path)
    return sources


def read_ledger_source(path, days):
    """The rows of one ledger file, added to the days that are already read.

    A file that cannot be opened or that is broken is reported on stderr
    and skipped: the rows that can be read are still worth counting, and a
    broken chunk must never crash the report.
    """
    try:
        if path.endswith(".gz"):
            handle = gzip.open(path, "rt", encoding="utf-8", errors="replace")
        else:
            handle = open(path, encoding="utf-8", errors="replace")
    except OSError as error:
        sys.stderr.write("compare-baseline: the ledger file was not opened: %s\n" % error)
        return
    try:
        with handle:
            for line in handle:
                match = re.match(r"\|\s*(\d{4}-\d{2}-\d{2})T", line)
                if not match:
                    continue
                fields = [field.strip() for field in line.strip().strip("|").split("|")]
                phase = fields[2] if len(fields) > 2 else ""
                detail = fields[4] if len(fields) > 4 else ""
                day = days.setdefault(
                    match.group(1),
                    {"turns": 0, "prs": set(), "productive": 0, "phases": {}},
                )
                day["turns"] += 1
                day["phases"][phase] = day["phases"].get(phase, 0) + 1
                if phase in WORK_PHASES:
                    day["productive"] += 1
                if phase == "published":
                    for number in re.findall(r"pr #(\d+)", detail):
                        day["prs"].add(int(number))
    except (OSError, EOFError, zlib.error) as error:
        sys.stderr.write("compare-baseline: the ledger file was not read: %s\n" % error)


def read_ledger(path):
    """The turns of each day, and the pull requests they published.

    The ledger is split into the archived chunks and the current file, and
    all of them are read, in chronological order.

    A turn that ends in the phase `published` is NOT a published pull
    request: the state stays in that phase until the next issue is claimed,
    so the turns of the same pull request are counted again and again. The
    pull requests are counted by their number, and the number is in the
    detail of the turn.
    """
    days = {}
    for source in ledger_sources(path):
        read_ledger_source(source, days)
    return days


def read_snapshots(path):
    """The rolling 24h numbers of metrics.log, by the day they were taken."""
    snapshots = {}
    try:
        handle = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return snapshots
    with handle:
        for line in handle:
            fields = dict(
                part.split("=", 1) for part in line.strip().split(" ") if "=" in part
            )
            iso = fields.get("iso")
            if not iso or "tokens_24h" not in fields:
                continue
            snapshots.setdefault(iso[:10], []).append(
                (int(fields.get("tokens_24h") or 0), float(fields.get("cost_24h") or 0))
            )
    return snapshots


def warn(loop_dir, message):
    """The warning, in the log of the supervisor and in the journal."""
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = "[%s] WARNING: %s" % (stamp, message)
    day = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    try:
        with open(os.path.join(loop_dir, "logs", "%s.err" % day), "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    except OSError:
        pass
    print(line)


def main():
    parser = argparse.ArgumentParser(description="compare a day against the baseline of the spend")
    parser.add_argument("--day", action="append", default=[], help="the day to compare (YYYY-MM-DD, UTC)")
    parser.add_argument("--days", type=int, default=1, help="how many days to compare, ending yesterday")
    parser.add_argument("--baseline", default=os.path.join(ROOT, "metrics-baseline.md"))
    parser.add_argument("--loop-dir", default=os.environ.get("LOOP_DIR", DEFAULT_LOOP_DIR))
    parser.add_argument(
        "--counter",
        default="",
        help="the counter of tokens (the default: bin/oc-tokens of the repository)",
    )
    parser.add_argument("--no-warn", action="store_true", help="the report, but no warning")
    args = parser.parse_args()

    baseline = read_baseline(args.baseline)
    if not baseline:
        return 2

    today = dt.datetime.now(dt.timezone.utc).date()
    if args.day:
        days = args.day
    else:
        days = [(today - dt.timedelta(days=offset)).isoformat() for offset in range(args.days, 0, -1)]

    counter = args.counter
    if not counter:
        counter = os.path.join(ROOT, "bin", "oc-tokens")
    if not os.path.exists(counter):
        counter = os.path.join(args.loop_dir, "bin", "oc-tokens")
    by_day = read_days(counter, max(168, args.days + 2))
    ledger = read_ledger(os.path.join(args.loop_dir, "ledger.md"))
    snapshots = read_snapshots(os.path.join(args.loop_dir, "metrics.log"))

    lines = []
    lines.append("## La comparación contra la línea base — %s" % ", ".join(days))
    lines.append("")
    lines.append("Línea base (media de los días antes del cambio): **%s tokens/día**, **%s/día**."
                 % (human_tokens(baseline["tokens"]), human_money(baseline["cost"])))
    lines.append("Objetivo: **< %s tokens/día** y **< %s/día**."
                 % (human_tokens(baseline["target_tokens"]), human_money(baseline["target_cost"])))
    lines.append("")

    header = "| día | tokens | coste | input fresco | caché | pasos | vueltas | PRs | veredicto |"
    lines.append(header)
    lines.append("|---|---|---|---|---|---|---|---|---|")

    missed = []
    for day in days:
        data = by_day.get(day)
        if not data:
            lines.append("| %s | - | - | - | - | - | - | - | SIN DATOS |" % day)
            missed.append((day, "there are no data of that day: the counter did not see it"))
            continue
        tokens = data.get("tokens") or 0
        cost = data.get("cost") or 0.0
        turns = ledger.get(day, {})
        prs = len(turns.get("prs") or ())
        # A day that spends less because it delivered less is not a success:
        # the objective is the spend AND the work.
        cheap = tokens < baseline["target_tokens"] and cost < baseline["target_cost"]
        worked = prs > 0
        if cheap and worked:
            verdict = "OK"
        elif not cheap:
            verdict = "FUERA"
        else:
            verdict = "SIN PRs"
        lines.append(
            "| %s | %s | %s | %s | %s | %d | %d | %d | %s |"
            % (
                day,
                human_tokens(tokens),
                human_money(cost),
                human_tokens(data.get("input") or 0),
                human_tokens(data.get("cache_read") or 0),
                data.get("steps") or 0,
                turns.get("turns", 0),
                prs,
                verdict,
            )
        )
        if not cheap:
            missed.append(
                (
                    day,
                    "the spend is outside the objective: %s tokens (objective: < %s) "
                    "and %s (objective: < %s)"
                    % (
                        human_tokens(tokens),
                        human_tokens(baseline["target_tokens"]),
                        human_money(cost),
                        human_money(baseline["target_cost"]),
                    ),
                )
            )
        elif not worked:
            missed.append(
                (
                    day,
                    "the loop published no pull request that day: the spend of %s "
                    "does not count as a success" % human_money(cost),
                )
            )

    lines.append("")
    lines.append("### Los últimos días (el contexto)")
    lines.append("")
    lines.append("Un día que gasta menos porque entregó menos no es un éxito: "
                 "las columnas 'vueltas' y 'PRs' dicen lo que hizo el loop.")
    lines.append("")
    lines.append("| día | tokens | coste | pasos | vueltas | PRs |")
    lines.append("|---|---|---|---|---|---|")
    for day in sorted(by_day)[-7:]:
        data = by_day[day]
        turns = ledger.get(day, {})
        lines.append(
            "| %s | %s | %s | %d | %d | %d |"
            % (
                day,
                human_tokens(data.get("tokens") or 0),
                human_money(data.get("cost") or 0),
                data.get("steps") or 0,
                turns.get("turns", 0),
                len(turns.get("prs") or ()),
            )
        )

    for day in days:
        snapshot = snapshots.get(day) or []
        if snapshot:
            tokens, cost = snapshot[-1]
            lines.append("")
            lines.append(
                "- La última foto de metrics.log del %s (24 h móviles): %s tokens, %s."
                % (day, human_tokens(tokens), human_money(cost))
            )

    report = "\n".join(lines) + "\n"
    print(report)

    label = days[0] if len(days) == 1 else "%s..%s" % (days[0], days[-1])
    destination = os.path.join(args.loop_dir, "reports", "baseline-%s.md" % label)
    try:
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        with open(destination, "w", encoding="utf-8") as handle:
            handle.write(report)
    except OSError as error:
        sys.stderr.write("compare-baseline: the report was not written: %s\n" % error)

    if missed and not args.no_warn:
        for day, reason in missed:
            warn(args.loop_dir, "%s: %s" % (day, reason))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
