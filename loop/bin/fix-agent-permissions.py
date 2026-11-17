#!/usr/bin/env python3
"""Repairs the permission rules of the agents that have no `resource`.

Why it exists (gap G2, 26-10-2026): the V2 schema of opencode requires every
permission rule to carry the three fields (`action`, `resource`, `effect`).
An agent with a rule without `resource` is NOT registered: opencode answers
"Agent not found: sc-orchestrator" and the loop cannot dispatch anything.
The symptom is quiet (the turn log says only that) and the turn is lost.

The broken rule is repaired with `resource: "*"`: it is the value opencode
itself uses for the tools of an MCP server (`<server>_<tool>` with `*` as the
resource), which is exactly what these rules want to deny.

Usage:
    fix-agent-permissions.py [--check] <file.md> [more.md ...]
"""

from __future__ import annotations

import argparse
import re
import sys

# A permission rule: "- action: X" and, in the lines below it, "resource" and
# "effect". The resource goes right behind the action.
RULE_START = re.compile(r"^(?P<indent>[ ]*)- action: (?P<action>.+)$")
KEY = re.compile(r"^(?P<indent>[ ]*)(?P<key>[a-z_]+):(?P<value>.*)$")


def fix(text: str) -> tuple[str, list[str]]:
    """Returns the repaired text and the list of rules that were repaired."""
    lines = text.splitlines(keepends=True)
    repaired: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = RULE_START.match(line.rstrip("\n"))
        if not m:
            i += 1
            continue
        # The block of the rule: until the next key of the rule or the next
        # rule.
        j = i + 1
        keys: dict[str, str] = {}
        block: list[tuple[int, str]] = []
        while j < len(lines):
            km = KEY.match(lines[j].rstrip("\n"))
            if not km:
                break
            keys[km.group("key")] = km.group("value").strip()
            block.append((j, km.group("indent")))
            j += 1
        if "resource" in keys:
            i += 1
            continue
        if "effect" not in keys:
            # Not a permission rule with the three fields: it is left alone
            # (the validator says so).
            i += 1
            continue
        # The resource goes behind the action and before the effect.
        indent = block[0][1]
        insert_at = block[0][0]
        lines = lines[: insert_at + 1] + [f'{indent}resource: "*"\n'] + lines[insert_at + 1 :]
        repaired.append(m.group("action").strip())
        i = insert_at + 2
    return "".join(lines), repaired


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="does not write, only reports")
    ap.add_argument("files", nargs="+")
    args = ap.parse_args()

    rc = 0
    for path in args.files:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        fixed, repaired = fix(text)
        if not repaired:
            print(f"OK   {path}: every rule has a resource")
            continue
        if args.check:
            print(f"FALLA {path}: {len(repaired)} rule(s) without resource: {repaired}")
            rc = 1
            continue
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(fixed)
        print(f"OK   {path}: {len(repaired)} rule(s) repaired: {repaired}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
