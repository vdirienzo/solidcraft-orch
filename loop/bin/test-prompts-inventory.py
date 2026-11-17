#!/usr/bin/env python3
"""Regression tests for the GENERATED inventory of the loop's prompts.

`bin/prompts-inventory.py` keeps the table of `prompts/README.md` honest: the
bytes of every live prompt are MEASURED, never written by hand. The rules
the script has to obey:

  * it discovers every `.md` of the prompts directory except `README.md` and
    `CHANGELOG.md`: those two describe the prompts, they are not prompts;
  * it reports the BYTES and never the mtime: the mtime moves when a prompt
    is copied, and a table that moves without the prompt moving is a table
    nobody trusts;
  * `--write` regenerates the block between the markers of the README and
    `--check` fails, NAMING the stale row, when the block is out of date;
  * `--write` is idempotent: writing twice leaves the README byte-identical;
  * a README without the markers is an error, never a silent rewrite.

THE TESTS ARE HERMETIC: they run the real script against a temporary
directory of their own. There is no network, no GitHub and no loop: the only
thing they read of the repository is the prompts directory, and only to check
that the inventory of the repository is up to date.

Run:  python3 bin/test-prompts-inventory.py
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPT = os.path.join(HERE, "prompts-inventory.py")
PROMPTS = os.path.join(ROOT, "prompts")
README = os.path.join(PROMPTS, "README.md")

MARK_START = "<!-- prompts-inventory:start -->"
MARK_END = "<!-- prompts-inventory:end -->"

OK = "ok"
FAIL = "FALLO"
RESULTS = []

# The prompts of the fake world, with the bytes each one weighs.
FAKE = {
    "agent-issue.md": 1677,
    "claim.md": 3813,
    "evidence.md": 15040,
    "gate.md": 19820,
    "implement.md": 7333,
    "iteration.md": 64863,
    "publish.md": 19236,
    "review.md": 5511,
    "triage.md": 8079,
}


def check(name, condition, detail=""):
    """Record one check and print it."""
    status = OK if condition else FAIL
    RESULTS.append((status, name, detail))
    line = "  ok   " if condition else "  FALLO "
    if detail and not condition:
        line += f"{name}  [{detail}]"
    else:
        line += name
    print(line)


def run(args, prompts_dir):
    """Run the inventory script against a prompts directory."""
    return subprocess.run(
        [sys.executable, SCRIPT, "--prompts", prompts_dir] + args,
        capture_output=True, text=True, check=False,
    )


def readme_text(rows):
    """A README with the generated block and the given rows in it."""
    body = "\n".join(rows)
    return f"# Los prompts de la prueba\n\n{MARK_START}\n{body}\n{MARK_END}\n"


def block_of(text):
    """The generated block of a README, markers included."""
    start = text.find(MARK_START)
    end = text.find(MARK_END)
    if start < 0 or end < 0:
        return ""
    return text[start:end + len(MARK_END)]


def make_world(root):
    """A prompts directory of our own, with the fake prompts in it."""
    prompts = os.path.join(root, "prompts")
    os.makedirs(prompts, exist_ok=True)
    for name, size in FAKE.items():
        with open(os.path.join(prompts, name), "w", encoding="utf-8") as fh:
            fh.write("#" * size)
    return prompts


def main():
    if not os.path.exists(SCRIPT):
        check("the inventory script is there", False, SCRIPT)
        return summary()
    check("the inventory script is there", True)

    root = tempfile.mkdtemp(prefix="loop-prompts-inventory-")
    try:
        prompts = make_world(root)
        readme = os.path.join(prompts, "README.md")
        # the README of the fake world describes the prompts: it is not one
        with open(os.path.join(prompts, "CHANGELOG.md"), "w", encoding="utf-8") as fh:
            fh.write("# changelog\n")
        with open(readme, "w", encoding="utf-8") as fh:
            fh.write(readme_text([
                "| Archivo | Bytes |",
                "|---|---:|",
                "| `iteration.md` | 1.000 |",
            ]))

        # 1. an out-of-date block is caught and the stale row is NAMED
        out = run(["--check"], prompts)
        check("an out-of-date inventory fails the check", out.returncode != 0,
              out.returncode)
        check("the stale row is named", "triage.md" in out.stdout + out.stderr,
              (out.stdout + out.stderr)[-300:])
        check("the check does not write anything",
              "8.079" not in open(readme, encoding="utf-8").read())

        # 2. --write regenerates the block with the measured bytes
        out = run(["--write"], prompts)
        check("the write succeeds", out.returncode == 0,
              out.stdout + out.stderr)
        text = open(readme, encoding="utf-8").read()
        block = block_of(text)
        for name, size in FAKE.items():
            row = f"| `{name}` | {size:,}".replace(",", ".") + " |"
            check(f"the inventory has the row of {name}", row in block, block)
        check("the inventory does not list the README",
              "`README.md`" not in block, block)
        check("the inventory does not list the CHANGELOG",
              "`CHANGELOG.md`" not in block, block)
        check("the inventory has no mtime column", "mtime" not in block, block)
        check("the inventory has no date", re.search(r"\d{4}-\d{2}-\d{2}", block)
              is None, block)
        total = sum(FAKE.values())
        check("the inventory states the total", f"{total:,}".replace(",", ".")
              in block, block)

        # 3. after the write the check is green
        out = run(["--check"], prompts)
        check("the check is green after the write", out.returncode == 0,
              out.stdout + out.stderr)

        # 4. the write is idempotent
        before = open(readme, "rb").read()
        run(["--write"], prompts)
        after = open(readme, "rb").read()
        check("the write is idempotent", before == after)

        # 5. the mtime of a prompt does not move the inventory
        os.utime(os.path.join(prompts, "triage.md"), (1000000, 1000000))
        out = run(["--check"], prompts)
        check("the mtime of a prompt does not stale the inventory",
              out.returncode == 0, out.stdout + out.stderr)

        # 6. a README without the markers is an error, not a silent rewrite
        bare = os.path.join(root, "bare")
        os.makedirs(bare, exist_ok=True)
        for name, size in FAKE.items():
            with open(os.path.join(bare, name), "w", encoding="utf-8") as fh:
                fh.write("#" * size)
        with open(os.path.join(bare, "README.md"), "w", encoding="utf-8") as fh:
            fh.write("# Sin marcadores\n")
        out = run(["--check"], bare)
        check("a README without the markers fails the check",
              out.returncode != 0, out.returncode)
        check("the missing markers are said out loud",
              "marcador" in (out.stdout + out.stderr).lower(),
              (out.stdout + out.stderr)[-300:])
        out = run(["--write"], bare)
        check("a README without the markers refuses the write",
              out.returncode != 0, out.returncode)
        check("the README without the markers is untouched",
              open(os.path.join(bare, "README.md"), encoding="utf-8").read()
              == "# Sin marcadores\n")

        # 7. the inventory of the repository is up to date
        out = run(["--check"], PROMPTS)
        check("the inventory of the repository is up to date",
              out.returncode == 0, out.stdout + out.stderr)
    finally:
        shutil.rmtree(root, ignore_errors=True)

    return summary()


def summary():
    print()
    n_ok = sum(1 for status, _, _ in RESULTS if status == OK)
    n_fail = sum(1 for status, _, _ in RESULTS if status == FAIL)
    print(f"ok: {n_ok}   FALLO: {n_fail}")
    if n_fail:
        failed = [name for status, name, _ in RESULTS if status == FAIL]
        print(f"{len(failed)} prueba(s) fallan: {failed}")
        return 1
    print("todas las reglas pasan")
    return 0


if __name__ == "__main__":
    sys.exit(main())
