#!/usr/bin/env python3
"""Regression tests for the prompts of the loop: the "worth an agent" list.

The plan (`docs/plan-gate-claims-worth-an-agent.md`, verdicts C1-C8) decided
what the prompts have to say. These tests are the executable form of those
verdicts: they read the prompts of this repository and check that the words
that matter are there and that the words that went stale are gone.

What is checked:

  * C1: the prose of `docs/` is a category of its own, with the explicit
    exception to the rule of "not verifiable";
  * C2: the upstream format of the translations, and the knob that opens the
    funnel (a decision of the maintainer, never of the loop);
  * C3: the current name of the crash report (`design.sc`);
  * C4: the references cite the SECTIONS of the other prompts and never a line
    number, and the list of the categories lives in ONE prompt;
  * C5: the time-box names the knob and never the number;
  * C6: the tie-break of a crash report whose cause is in a paused area;
  * C7: the inventory of the README is generated and carries bytes, not mtime;
  * C8: the categories of the prompt are the ones the prompt says (the plan
    describes the same list, but the plan is not in this tree: the prompt
    wins and this test is the witness);
  * the mechanical brakes of the two code pull requests that run in parallel:
    the gate (target dir per slot, lock per target dir, the loser of the lock
    is deferred and not failed) and the claims (the guard decides, a change of
    a default is never published by the loop, a failed rebase aborts the
    publication and the defaults line blocks it).

THE TESTS ARE HERMETIC: they read the prompts of this repository and nothing
else. There is no network, no GitHub, no compilation and no running loop: a
test that needs a loop would test the loop and not the prompts.

Run:  python3 bin/test-worth-an-agent.py
"""

from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PROMPTS = os.path.join(ROOT, "prompts")

OK = "ok"
FAIL = "FALLO"
RESULTS = []

# The fences of a prompt: a block of shell is a block of commands, and a
# block of any other language is not. The pairing is done LINE BY LINE.
FENCE_LINE = re.compile(r"^(\s*)(`{3,})[ \t]*([A-Za-z0-9_+.-]*)[ \t]*$")
INLINE_SPAN = re.compile(r"`([^`\n]+)`")

# A number of minutes: the time-box must not carry one.
MINUTES = re.compile(r"\d+\s*(?:min\b|minutos\b|minutes\b)")

# The sections of `prompts/triage.md` that the other prompts cite.
TRIAGE_SECTIONS = ("Filtros", "Los candidatos", "Qué vale la pena",
                   "Orden de preferencia", "Los 5 chequeos", "Veredicto",
                   "Contrato de salida")

# The categories of the list. They live in `prompts/triage.md` and NOWHERE
# else: a list repeated in two prompts is a list that goes stale in one.
CATEGORIES = ("CLI/headless", "UI de texto/estado", "sketch/doc/io")


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


def read(name):
    """The text of one prompt of the repository."""
    with open(os.path.join(PROMPTS, name), encoding="utf-8") as fh:
        return fh.read()


def fenced_bodies(text):
    """The bodies of the fenced blocks of a text, with their language."""
    lines = text.splitlines()
    out = []
    i = 0
    while i < len(lines):
        m = FENCE_LINE.match(lines[i])
        if not m:
            i += 1
            continue
        marker = len(m.group(2))
        lang = m.group(3)
        j = i + 1
        while j < len(lines):
            c = FENCE_LINE.match(lines[j])
            if c and not c.group(3) and len(c.group(2)) >= marker:
                break
            j += 1
        out.append((lang, "\n".join(lines[i + 1:j])))
        i = j + 1
    return out


def inline_spans(text):
    """The inline code spans of a text, the fenced blocks left out."""
    lines = text.splitlines()
    keep = []
    i = 0
    while i < len(lines):
        m = FENCE_LINE.match(lines[i])
        if not m:
            keep.append(lines[i])
            i += 1
            continue
        marker = len(m.group(2))
        j = i + 1
        while j < len(lines):
            c = FENCE_LINE.match(lines[j])
            if c and not c.group(3) and len(c.group(2)) >= marker:
                break
            j += 1
        i = j + 1
    return [m.group(1) for m in INLINE_SPAN.finditer("\n".join(keep))]


def prose_only(text, needle):
    """True when the needle is in the prose and in no block of code."""
    if needle not in text:
        return False
    for _, body in fenced_bodies(text):
        if needle in body:
            return False
    for span in inline_spans(text):
        if needle in span:
            return False
    return True


def cited_minutes(text):
    """The numbers of minutes that a prompt cites next to the time-box knob."""
    lines = text.splitlines()
    found = []
    for i, line in enumerate(lines):
        if "MAX_WORK_MINUTES_PER_ISSUE" not in line:
            continue
        window = " ".join(lines[max(0, i - 1):i + 1])
        found.extend(m.group(0) for m in MINUTES.finditer(window))
    return found


def has_all(text, needles):
    """True when the text has every one of the needles."""
    return [n for n in needles if n not in text]


def main():
    triage = read("triage.md")
    iteration = read("iteration.md")
    implement = read("implement.md")
    claim = read("claim.md")
    gate = read("gate.md")
    publish = read("publish.md")
    readme = read("README.md")

    print("1. C1: los docs de prosa son una categoría con su excepción")
    missing = has_all(triage, ("docs de prosa", "area:infra", "docs/"))
    check("the triage prompt has the category of the prose docs",
          not missing, missing)
    check("the triage prompt names the directory and the label of the prose",
          "area:infra" in triage and "docs/" in triage)
    check("the triage prompt states the exception of the prose docs",
          "no verificable" in triage and "Excepci" in triage
          or "excepci" in triage.lower(), "")
    check("the triage prompt says how a doc is verified",
          "checks" in triage and "verde" in triage)
    check("the triage prompt names the check that reads the docs",
          prose_only(triage, "cargo xtask skills"))

    print("2. C2: el formato de las traducciones y el knob del funnel")
    check("the implement prompt does not rewrite the locale catalogues",
          "cargo xtask lists --fix" not in implement)
    check("the implement prompt writes a new pending file per change",
          "assets/locales/pending/" in implement, "")
    check("the implement prompt forbids editing a locale catalogue",
          "assets/locales/<locale>.json" in implement
          and "Nunca" in implement or "nunca" in implement, "")
    check("the implement prompt folds the pending files only on main",
          "fold-pending" in implement and "main" in implement, "")
    check("the triage prompt names the knob of the wanted labels",
          "CLAIM_WANTED_LABELS" in triage)
    check("the triage prompt states the default of the knob",
          "${CLAIM_WANTED_LABELS:-$CLAIM_WANTED_LABEL}" in triage)
    check("the triage prompt says that widening the funnel is the maintainer's",
          "maintainer" in triage and "CLAIM_WANTED_LABELS" in triage)

    print("3. C3: el formato vigente del crash report")
    check("the triage prompt asks for the current crash format",
          "design.sc" in triage)
    check("the triage prompt says that design.solidcraft is the old format",
          "design.solidcraft" in triage
          and ("vieja" in triage or "viejas" in triage
               or "old" in triage.lower()), "")

    print("4. C4: las referencias citan secciones, no líneas")
    for name in ("triage.md", "iteration.md", "implement.md", "claim.md",
                 "gate.md", "publish.md", "review.md", "evidence.md",
                 "agent-issue.md"):
        text = read(name)
        check(f"the prompt {name} cites no line number",
              not re.search(r"\(L\d", text),
              re.findall(r".{0,30}\(L\d.{0,10}", text)[:3])
    missing = has_all(iteration, tuple("§" + s for s in TRIAGE_SECTIONS))
    check("the iteration prompt cites every section of the triage prompt",
          not missing, missing)
    repeated = [c for c in CATEGORIES if c in iteration]
    check("the iteration prompt does not repeat the categories",
          not repeated, repeated)
    check("the triage prompt is the one that lists the categories",
          all(c in triage for c in CATEGORIES),
          [c for c in CATEGORIES if c not in triage])

    print("5. C5: el time-box nombra la knob y no el número")
    for name, text in (("triage.md", triage), ("iteration.md", iteration)):
        cited = cited_minutes(text)
        check(f"the prompt {name} does not cite a number of minutes",
              not cited, cited)
        check(f"the prompt {name} names the knob of the time-box",
              "MAX_WORK_MINUTES_PER_ISSUE" in text)

    print("6. C6: el desempate de los crash reports")
    check("the triage prompt says that a crash report is claimable",
          "tomable" in triage, "")
    check("the triage prompt ties the tie-break to a paused area",
          "pausada" in triage, "")
    check("the triage prompt says that the work is the regression test",
          "test de regresión" in triage, "")

    print("7. C7: el inventario es generado y pesa bytes")
    check("the README of the prompts has the generated block",
          "<!-- prompts-inventory:start -->" in readme
          and "<!-- prompts-inventory:end -->" in readme)
    check("the README of the prompts has no mtime column",
          "mtime" not in readme and "mtime" not in readme.lower())
    check("the README of the prompts lists every live prompt",
          all(f"`{name}`" in readme for name in
              ("agent-issue.md", "claim.md", "evidence.md", "gate.md",
               "implement.md", "iteration.md", "publish.md", "review.md",
               "triage.md")))

    print("8. C8: la lista del prompt es la lista que el prompt dice")
    check("the triage prompt says the category of the crash reports",
          "crash report" in triage)
    check("the triage prompt does not open a category of tests",
          not re.search(r"categor[íi]a[^\n]*tests", triage))
    check("the triage prompt has one list of categories",
          triage.count("Vale la pena") == 1
          and triage.count("Orden de preferencia") == 1, "")

    print("9. los frenos del gate (target dir por slot, lock por target dir)")
    check("the iteration prompt says that the target dir is per slot",
          re.search(r"target dir[^\n]*per slot", iteration)
          or re.search(r"per slot[^\n]*target dir", iteration), "")
    check("the iteration prompt says that the lock is per target dir",
          re.search(r"lock[^\n]*per target dir", iteration)
          or re.search(r"per target dir[^\n]*lock", iteration), "")
    check("the iteration prompt says that the two go together",
          "together" in iteration, "")
    check("the iteration prompt says that the loser of the lock is deferred",
          re.search(r"DEFERRED", iteration) and "lock" in iteration, "")
    check("the iteration prompt says that a deferral exits 0",
          re.search(r"exit[s]? \*\*?0\*\*?", iteration)
          or re.search(r"exit[s]? 0", iteration), "")
    check("the iteration prompt says that the deferral names the slot",
          re.search(r"names? the slot", iteration), "")
    check("the iteration prompt says that the deferral names the target dir",
          re.search(r"names? the[^\n]*target dir", iteration), "")

    # The prompt of the gate is the one the worker reads when the gate
    # answers: if it says that the build directory is shared by every slot,
    # the prompt says a lie as soon as the gate has a directory per slot.
    check("the gate prompt does not say that the target dir is shared",
          not re.search(r"target dir is shared by every", gate), "")
    check("the gate prompt says that the lock is the one of the directory",
          re.search(r"lock[^\n]*of that directory", gate), "")
    check("the gate prompt says that the loser of the lock is deferred",
          re.search(r"deferred, not failed", gate), "")
    check("the gate prompt says that the deferral names the slot and the dir",
          re.search(r"names? the slot and the build\s+directory", gate), "")

    print("10. los frenos de los claims (el guard decide, el loop no publica)")
    check("the claim prompt says that the guard runs before publishing",
          "claim-guard.sh" in claim and re.search(r"antes de publica", claim), "")
    check("the claim prompt says that the exit code of the guard decides",
          re.search(r"c[óo]digo[^\n]*decide", claim), "")
    check("the claim prompt says that the loop never publishes a default change",
          re.search(r"default", claim) and re.search(r"no publica", claim), "")
    check("the claim prompt says that a yes is never the loop's decision",
          re.search(r"yes", claim) and re.search(r"nunca", claim), "")
    check("the claim prompt says that a person decides",
          re.search(r"persona", claim), "")
    check("the claim prompt aborts the publication when the rebase fails",
          re.search(r"rebase", claim) and re.search(r"aborta", claim), "")
    check("the claim prompt says that the branch stays local",
          re.search(r"local", claim), "")
    check("the claim prompt blocks the publication when the defaults line fails",
          "pr-defaults-line.sh" in claim and re.search(r"bloquea", claim), "")
    check("the claim prompt emits the line of the default in the body",
          "Changes a default: no" in claim, "")
    check("the claim prompt never writes a yes",
          "<yes|no>" not in claim, "")
    check("the publish prompt emits the line of the default as a no",
          "Changes a default: no" in publish, "")
    check("the publish prompt does not offer a yes to the loop",
          "Changes a default: yes" not in publish, "")
    check("the publish prompt says that the loop does not publish a default change",
          re.search(r"no publica", publish) and re.search(r"default", publish), "")
    check("the publish prompt says that a person decides",
          re.search(r"persona", publish), "")
    for code in (0, 2, 3, 4, 5, 6):
        check(f"the claim prompt documents the exit code {code}",
              re.search(r"\|\s*%d\s*\|" % code, claim) is not None)

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
