#!/usr/bin/env python3
"""What the ceiling of the context costs, measured.

THE MECHANISM: OpenCode compacts a session when its context reaches the
ceiling, and the ceiling is not a number of the config: it is the window of
the model minus the buffer that is kept free (`ceiling = window - buffer`).
Below the ceiling the context grows with every step and the prefix of the
prompt is read from the cache, which is cheap. Above it the session is
compacted: the prefix changes, so the next request is billed as FRESH input
(ten times the price of the cache) and the session starts again from the
summary.

A lower ceiling therefore does two opposite things: every step becomes
cheaper (a smaller context) and the session is compacted more often (more
fresh input). Where the balance is better is a question of measurement, not
of estimation, and this script measures it.

    cache-effect.py [--days N] [--loop-dir DIR] [--hourly]

It reads:
  - the database of OpenCode (the interactive sessions, plus the turns of the
    loop that are already in it) and the JSONL of the turns that are not;
  - the history of the ceiling (logs/ceiling.log), which says what the ceiling
    was at every moment.

The output is one row per regime (a period with the same ceiling): the spend,
the fresh input per step, the cache read per step, the size of the context
and the number of compactions. The regime with the lowest cost per hour is
the one to keep.
"""

import argparse
import collections
import datetime as dt
import glob
import json
import os
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.environ.get("OC_TOKENS_DB", os.path.expanduser("~/.local/share/opencode/opencode.db"))
PRICE_INPUT = 0.15 / 1e6
PRICE_OUTPUT = 0.60 / 1e6
PRICE_CACHE = 0.015 / 1e6
PRICE_REASONING = 0.15 / 1e6
HOUR = 3600


def to_seconds(value):
    """The epoch in seconds, from a stamp that may be in ms, us or ns."""
    for divisor in (1e9, 1e6, 1e3, 1):
        if abs(value) < 1e18 / divisor:
            return value / divisor
    return float(value)


class Bucket:
    """One hour of the spend."""

    def __init__(self):
        self.steps = 0
        self.context = []
        self.input = 0
        self.cache = 0
        self.output = 0
        self.cost = 0.0
        self.compactions = 0
        self.compaction_cost = 0.0
        self.compaction_tokens = 0

    def add(self, tokens, context):
        cache = tokens.get("cache") or {}
        self.steps += 1
        self.context.append(context)
        self.input += tokens.get("input", 0) or 0
        self.cache += cache.get("read", 0) or 0
        self.output += (tokens.get("output", 0) or 0) + (tokens.get("reasoning", 0) or 0)
        self.cost += (
            (tokens.get("input", 0) or 0) * PRICE_INPUT
            + (tokens.get("output", 0) or 0) * PRICE_OUTPUT
            + (tokens.get("reasoning", 0) or 0) * PRICE_REASONING
            + (cache.get("read", 0) or 0) * PRICE_CACHE
            + (cache.get("write", 0) or 0) * PRICE_CACHE
        )

    def merge(self, other):
        self.steps += other.steps
        self.context.extend(other.context)
        self.input += other.input
        self.cache += other.cache
        self.output += other.output
        self.cost += other.cost
        self.compactions += other.compactions
        self.compaction_cost += other.compaction_cost
        self.compaction_tokens += other.compaction_tokens


def read_db(path, since):
    """The steps and the compactions of the database, bucketed by hour."""
    buckets = collections.defaultdict(Bucket)
    sessions = set()
    if not os.path.exists(path):
        return buckets, sessions
    try:
        conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    except sqlite3.Error as error:
        sys.stderr.write("cache-effect: the database is not readable: %s\n" % error)
        return buckets, sessions
    try:
        rows = conn.execute(
            "SELECT session_id, type, time_created, data FROM session_message "
            "WHERE type IN ('assistant','compaction') AND time_created >= ?",
            (since * 1000,),
        )
        for session_id, kind, created, data in rows:
            try:
                obj = json.loads(data)
            except ValueError:
                continue
            stamp = to_seconds(created)
            hour = int(stamp // HOUR)
            bucket = buckets[hour]
            sessions.add(session_id)
            if kind == "compaction":
                bucket.compactions += 1
                bucket.compaction_cost += float(obj.get("cost") or 0)
                tokens = obj.get("tokens") or {}
                cache = tokens.get("cache") or {}
                bucket.compaction_tokens += (
                    (tokens.get("input", 0) or 0)
                    + (tokens.get("output", 0) or 0)
                    + (tokens.get("reasoning", 0) or 0)
                    + (cache.get("read", 0) or 0)
                    + (cache.get("write", 0) or 0)
                )
                continue
            tokens = obj.get("tokens") or {}
            cache = tokens.get("cache") or {}
            context = (
                (tokens.get("input", 0) or 0)
                + (cache.get("read", 0) or 0)
                + (cache.get("write", 0) or 0)
            )
            bucket.add(tokens, context)
    except sqlite3.Error as error:
        sys.stderr.write("cache-effect: the database could not be read: %s\n" % error)
    finally:
        conn.close()
    return buckets, sessions


def read_loop(directory, since, known):
    """The steps of the turns of the loop that are not in the database yet."""
    buckets = collections.defaultdict(Bucket)
    if not os.path.isdir(directory):
        return buckets
    for path in sorted(glob.glob(os.path.join(directory, "*.jsonl"))):
        name = os.path.basename(path)[:10]
        try:
            day = dt.datetime.strptime(name, "%Y-%m-%d").replace(tzinfo=dt.timezone.utc)
        except ValueError:
            continue
        if day.timestamp() + 86400 < since:
            continue
        try:
            handle = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with handle:
            for line in handle:
                if '"step_finish"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if obj.get("type") != "step_finish":
                    continue
                part = obj.get("part") or {}
                tokens = part.get("tokens") or {}
                cache = tokens.get("cache") or {}
                session_id = part.get("sessionID") or obj.get("sessionID")
                if not session_id or session_id in known:
                    continue
                created = (part.get("time") or {}).get("completed") or obj.get("timestamp")
                stamp = to_seconds(created) if created else 0
                if stamp < since:
                    continue
                context = (
                    (tokens.get("input", 0) or 0)
                    + (cache.get("read", 0) or 0)
                    + (cache.get("write", 0) or 0)
                )
                buckets[int(stamp // HOUR)].add(tokens, context)
    return buckets


def read_regimes(path):
    """The history of the ceiling: a list of (since, ceiling, note)."""
    regimes = []
    if not os.path.exists(path):
        return regimes
    try:
        handle = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return regimes
    with handle:
        for line in handle:
            if not line.startswith("iso="):
                continue
            line = line.strip()
            # The note is the last field and it may have spaces: it is read
            # as the remainder of the line.
            note = ""
            if " note=" in line:
                line, note = line.split(" note=", 1)
            fields = dict(
                part.split("=", 1) for part in line.split(" ") if "=" in part
            )
            try:
                since = dt.datetime.strptime(
                    fields["iso"], "%Y-%m-%dT%H:%M:%SZ"
                ).replace(tzinfo=dt.timezone.utc)
            except (KeyError, ValueError):
                continue
            regimes.append(
                (
                    since,
                    int(fields.get("ceiling") or 0),
                    note,
                )
            )
    regimes.sort(key=lambda item: item[0])
    return regimes


def regime_of(regimes, moment):
    """The ceiling in force at a moment."""
    current = (dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc), 0, "")
    for since, ceiling, note in regimes:
        if since <= moment:
            current = (since, ceiling, note)
        else:
            break
    return current


def human_money(value):
    return "%.2f $" % value


def main():
    parser = argparse.ArgumentParser(description="the cost of the ceiling of the context")
    parser.add_argument("--days", type=int, default=7, help="the window of the analysis (default: 7)")
    parser.add_argument(
        "--loop-dir",
        default=os.environ.get("LOOP_DIR", os.path.expanduser("~/.local/share/solidcraft-loop")),
        help="where the logs of the loop live",
    )
    parser.add_argument("--hourly", action="store_true", help="the table by hour, not by regime")
    args = parser.parse_args()

    now = dt.datetime.now(dt.timezone.utc)
    since = now.timestamp() - args.days * 86400
    buckets, sessions = read_db(DB, since)
    for hour, bucket in read_loop(
        os.path.join(args.loop_dir, "logs", "turns"), since, sessions
    ).items():
        buckets[hour].merge(bucket)

    regimes = read_regimes(os.path.join(args.loop_dir, "logs", "ceiling.log"))
    if not regimes:
        sys.stderr.write(
            "cache-effect: there is no history of the ceiling (%s): the analysis "
            "cannot say which ceiling was in force\n" % os.path.join(args.loop_dir, "logs", "ceiling.log")
        )
        return 2

    if args.hourly:
        print("hour (UTC)              steps   ctx med   ctx max      fresh in    cache read       out    cost  ceiling")
        for hour in sorted(buckets):
            bucket = buckets[hour]
            if not bucket.steps:
                continue
            moment = dt.datetime.fromtimestamp(hour * HOUR, dt.timezone.utc)
            ceiling = regime_of(regimes, moment)[1]
            context = sorted(bucket.context)
            print(
                "%s %7d %10d %9d %13d %13d %9d %7.2f %8d"
                % (
                    moment.strftime("%Y-%m-%d %H"),
                    bucket.steps,
                    context[len(context) // 2],
                    context[-1],
                    bucket.input,
                    bucket.cache,
                    bucket.output,
                    bucket.cost,
                    ceiling,
                )
            )
        return 0

    # The regimes: a period with the same ceiling.
    groups = collections.OrderedDict()
    for hour in sorted(buckets):
        bucket = buckets[hour]
        if not bucket.steps and not bucket.compactions:
            continue
        moment = dt.datetime.fromtimestamp(hour * HOUR, dt.timezone.utc)
        since, ceiling, note = regime_of(regimes, moment)
        key = (since, ceiling)
        if key not in groups:
            groups[key] = {"ceiling": ceiling, "since": since, "hours": set(), "data": Bucket()}
        groups[key]["hours"].add(hour)
        groups[key]["data"].merge(bucket)

    print("ceiling   from                 hours  steps      tokens        cost   $/h  fresh/step  cache/step  cache%  ctx med   ctx max  compactions")
    rows = []
    for (since, ceiling), group in groups.items():
        data = group["data"]
        hours = len(group["hours"])
        if not data.steps:
            continue
        context = sorted(data.context)
        total = data.input + data.cache + data.output
        cache_share = (100.0 * data.cache / total) if total else 0.0
        per_hour = data.cost / hours if hours else 0.0
        rows.append(
            (
                ceiling,
                since,
                hours,
                data.steps,
                total,
                data.cost,
                per_hour,
                data.input / data.steps,
                data.cache / data.steps,
                cache_share,
                context[len(context) // 2],
                context[-1],
                data.compactions,
                data.compaction_cost,
            )
        )
        print(
            "%7d   %s %5d %6d %13d %8.2f %6.2f %11.0f %12.0f %6.1f %8d %9d %12d"
            % (
                ceiling,
                since.strftime("%Y-%m-%d %H:%MZ"),
                hours,
                data.steps,
                total,
                data.cost,
                per_hour,
                data.input / data.steps,
                data.cache / data.steps,
                cache_share,
                context[len(context) // 2],
                context[-1],
                data.compactions,
            )
        )

    if not rows:
        print("there is no data in the window")
        return 0

    print("")
    cheapest = min(rows, key=lambda row: row[6])
    print(
        "the cheapest regime is the ceiling of %d tokens (%.2f $/h, from %s)"
        % (cheapest[0], cheapest[6], cheapest[1].strftime("%Y-%m-%d %H:%MZ"))
    )
    for row in rows:
        if row[13]:
            print(
                "  the ceiling of %d: %d compactions, %.2f $ of summaries"
                % (row[0], row[12], row[13])
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
