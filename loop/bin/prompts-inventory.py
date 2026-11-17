#!/usr/bin/env python3
"""The GENERATED inventory of the loop's prompts.

`prompts/README.md` lists the live prompts with their weight. The weight of
a prompt is a number that changes every time the prompt is edited, so a
table written by hand is a table that lies. This script MEASURES the prompts
and writes the table: the README can never drift away from the prompts.

  * every `.md` of the prompts directory is a prompt, except `README.md` and
    `CHANGELOG.md`: those two describe the prompts, they are not prompts;
  * the table carries the BYTES and never the mtime: the mtime moves when a
    prompt is copied to the runtime, and a table that moves without the
    prompt moving is a table nobody trusts;
  * `--write` regenerates the block between the markers of the README;
  * `--check` (the default) verifies that block and fails, NAMING the stale
    row, when it is out of date.

Run:
    python3 bin/prompts-inventory.py --check
    python3 bin/prompts-inventory.py --write
"""

from __future__ import annotations

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PROMPTS = os.path.join(os.path.dirname(HERE), "prompts")

MARK_START = "<!-- prompts-inventory:start -->"
MARK_END = "<!-- prompts-inventory:end -->"

# The two files of the directory that DESCRIBE the prompts are not prompts.
EXCLUDED = ("README.md", "CHANGELOG.md")

ROW_RE = re.compile(r"^\|\s*`([^`]+)`\s*\|\s*([0-9][0-9.]*)\s*\|\s*$")
TOTAL_RE = re.compile(
    r"^Total de los (\d+) prompts vivos: \*\*([0-9][0-9.]*) bytes\*\*\.\s*$"
)


def thousands(number):
    """The number with the thousands separated by dots, as the README does."""
    return f"{number:,}".replace(",", ".")


def discover(prompts_dir):
    """The live prompts of a directory, with their measured bytes."""
    found = []
    for name in sorted(os.listdir(prompts_dir)):
        if not name.endswith(".md") or name in EXCLUDED:
            continue
        path = os.path.join(prompts_dir, name)
        if not os.path.isfile(path):
            continue
        found.append((name, os.path.getsize(path)))
    return found


def render(rows):
    """The generated block: the table of the prompts and the total."""
    lines = ["| Archivo | Bytes |", "|---|---:|"]
    for name, size in rows:
        lines.append(f"| `{name}` | {thousands(size)} |")
    lines.append("")
    total = sum(size for _, size in rows)
    lines.append(f"Total de los {len(rows)} prompts vivos: **{thousands(total)} bytes**.")
    return "\n".join(lines)


def read_readme(prompts_dir):
    """The text of the README of the prompts directory."""
    path = os.path.join(prompts_dir, "README.md")
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def parse_block(text):
    """The rows and the total the README carries now (None without markers)."""
    start = text.find(MARK_START)
    end = text.find(MARK_END)
    if start < 0 or end < 0:
        return None
    rows = {}
    total = None
    for line in text[start:end].splitlines():
        stripped = line.strip()
        row = ROW_RE.match(stripped)
        if row:
            rows[row.group(1)] = int(row.group(2).replace(".", ""))
            continue
        found = TOTAL_RE.match(stripped)
        if found:
            total = (int(found.group(1)), int(found.group(2).replace(".", "")))
    return rows, total


def differences(rows, total, measured):
    """Every row of the README that does not match the measured bytes."""
    problems = []
    measured_map = dict(measured)
    for name, size in measured:
        if name not in rows:
            problems.append(
                f"falta la fila de {name} ({thousands(size)} bytes)"
            )
        elif rows[name] != size:
            problems.append(
                f"{name} pesa {thousands(size)} bytes y la tabla dice "
                f"{thousands(rows[name])}"
            )
    for name in sorted(rows):
        if name not in measured_map:
            problems.append(f"la tabla tiene {name} y ese prompt ya no existe")
    want = (len(measured), sum(size for _, size in measured))
    if total != want:
        count, total_bytes = total if total else (0, 0)
        problems.append(
            f"el total dice {count} prompts y {thousands(total_bytes)} bytes, "
            f"y los prompts son {want[0]} y {thousands(want[1])} bytes"
        )
    return problems


def do_check(prompts_dir):
    """Verify the block of the README against the measured prompts."""
    text = read_readme(prompts_dir)
    parsed = parse_block(text)
    if parsed is None:
        print(
            f"ERROR: {os.path.join(prompts_dir, 'README.md')} no tiene los "
            f"marcadores {MARK_START} y {MARK_END}: no hay bloque generado "
            f"que verificar."
        )
        return 1
    rows, total = parsed
    measured = discover(prompts_dir)
    problems = differences(rows, total, measured)
    if problems:
        print("el inventario está viejo:")
        for problem in problems:
            print(f"  - {problem}")
        print(f"corré `python3 {os.path.relpath(__file__)} --write` "
              f"para regenerarlo.")
        return 1
    total_bytes = sum(size for _, size in measured)
    print(
        f"el inventario está al día: {len(measured)} prompts, "
        f"{thousands(total_bytes)} bytes."
    )
    return 0


def do_write(prompts_dir):
    """Regenerate the block of the README with the measured prompts."""
    text = read_readme(prompts_dir)
    start = text.find(MARK_START)
    end = text.find(MARK_END)
    if start < 0 or end < 0:
        print(
            f"ERROR: {os.path.join(prompts_dir, 'README.md')} no tiene los "
            f"marcadores {MARK_START} y {MARK_END}: no sé dónde escribir el "
            f"bloque generado."
        )
        return 1
    measured = discover(prompts_dir)
    block = f"{MARK_START}\n{render(measured)}\n{MARK_END}"
    new_text = text[:start] + block + text[end + len(MARK_END):]
    if new_text == text:
        print("el inventario ya estaba al día: no se cambió nada.")
        return 0
    with open(os.path.join(prompts_dir, "README.md"), "w", encoding="utf-8") as fh:
        fh.write(new_text)
    total_bytes = sum(size for _, size in measured)
    print(
        f"escrito: {len(measured)} prompts, {thousands(total_bytes)} bytes."
    )
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Mide los prompts y mantiene el inventario de "
                    "prompts/README.md al día."
    )
    parser.add_argument(
        "--prompts", default=DEFAULT_PROMPTS,
        help="el directorio de los prompts (por defecto, el del repo)",
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--check", action="store_true",
        help="verifica el bloque generado (por defecto)",
    )
    group.add_argument(
        "--write", action="store_true",
        help="regenera el bloque generado del README",
    )
    args = parser.parse_args(argv)
    if not os.path.isdir(args.prompts):
        print(f"ERROR: {args.prompts} no es un directorio.")
        return 2
    if args.write:
        return do_write(args.prompts)
    return do_check(args.prompts)


if __name__ == "__main__":
    sys.exit(main())
