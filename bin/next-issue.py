#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# next-issue.py - the next issue worth an agent, and why.
#
# WHY THIS EXISTS: the wave used to be dispatched by hand, and the hand is
# where the claims get lost. The rule of the repo (RULES.md, and the triage of
# the maintainer) is that a wrong pick costs an agent its whole budget on an
# issue that was never free: on 31-10-2026 three issues were lost that way.
#
# WHAT IT DOES: it walks the open issues of the upstream and applies the
# filters of docs/issue-selection.md, IN THAT ORDER, and it asks the ARBITER of
# the repo (bin/claim-verify.sh) who really holds each candidate. The arbiter is
# the only implementation of "who holds the claim": a label is not a claim (the
# bot puts "in progress" with a delay).
#
# USAGE:
#   bash bin/next-issue.py                # the next issue, on stdout
#   bash bin/next-issue.py --list         # every candidate and why it was kept
#   bash bin/next-issue.py --explain <N>  # why this one was kept or dropped
#
# EXIT CODES:
#   0  an issue is on stdout (and the reason for keeping it, on stderr)
#   1  there is no free issue worth an agent right now
#   2  the upstream could not be read
# ---------------------------------------------------------------------------
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ORCH_DIR = os.environ.get("ORCH_DIR") or os.path.expanduser("~/.local/share/solidcraft-orch")
# The claim arbiter lives with the other scripts of the orchestrator. The cron
# runs a COPY of this script from ~/.hermes/scripts/, where the arbiter is
# NOT: it lives in the orchestrator's bin.
if os.path.exists(os.path.join(HERE, "claim-verify.sh")):
    ORCH_BIN = HERE
else:
    ORCH_BIN = os.environ.get("ORCH_BIN") or os.path.join(ORCH_DIR, "bin")
REPO = os.environ.get("UPSTREAM_REPO", "tangency-labs/solidcraft")

# The labels that put an issue out of bounds (docs/issue-selection.md, filter 1).
VETO_LABELS = {
    "kernel-paused",
    "status:decision",
    "status:hold-sheetmetal",
    "in progress",
    "area:kernel",
    "area:render",
}
# The areas an agent can work on alone: the document layer, the commands, the
# sketch, the files, the tools. The UI needs a screen the box does not have.
AREAS = ("area:doc", "area:sketch", "area:io", "area:infra", "area:ui", "area:assemblies")
# The phrases in a triage that mean DEAD (filter 3).
DEAD_PHRASES = (
    "could not be reproduced",
    "could not reproduce",
    "not reproduced",
    "does not reproduce",
    "no longer reproduces",
    "already fixed",
    "fixed by #",
    "duplicate of #",
    "same as #",
    "superseded by #",
    "wontfix",
)
# The reproductions that need something this box does not have (filter 5).
NEEDS_HARDWARE = (
    "android",
    "iphone",
    "tablet",
    "touchscreen",
    "3dconnexion",
    "space mouse",
    "arduino",
    "raspberry",
)


def gh(*args):
    """gh with the repo, returning the stdout or None."""
    cmd = ["gh", *args, "-R", REPO]
    try:
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None
    if done.returncode != 0:
        return None
    return done.stdout


def issues():
    raw = gh(
        "issue",
        "list",
        "--state",
        "open",
        "--limit",
        "150",
        "--json",
        "number,title,body,labels,comments,assignees,createdAt",
    )
    if raw is None:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


def claim_state(number):
    """Who holds the claim: 0 ours/free, 1 somebody else, 2 unknown."""
    done = subprocess.run(
        ["bash", os.path.join(ORCH_BIN, "claim-verify.sh"), str(number)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    return done.returncode


def triage_text(issue):
    return "\n".join(c.get("body") or "" for c in issue.get("comments") or [])


def classify(issue):
    """The CHEAP filters, in order. Returns (keep, reason).

    The claim is checked apart (claim_state): it is the only filter that costs
    a call to GitHub, and asking it for three hundred issues took ten minutes.
    The order of the filters decides which one rejects, and the claim is the
    one that has to be asked about the few that survive the rest.
    """
    number = issue["number"]
    title = issue["title"] or ""
    body = issue.get("body") or ""
    labels = {l["name"] for l in issue.get("labels") or []}
    triage = triage_text(issue)

    # 1. Veto by area and state.
    vetoed = labels & VETO_LABELS
    if vetoed:
        return False, "vetado por etiqueta: " + ", ".join(sorted(vetoed))
    if issue.get("assignees"):
        return False, "ya tiene asignado a " + ", ".join(a["login"] for a in issue["assignees"])
    if title.strip().startswith("[RFC]"):
        return False, "es un RFC, no un arreglo"

    # 3. DEAD, by the triage comments.
    low = triage.lower()
    for phrase in DEAD_PHRASES:
        if phrase in low:
            return False, f"el triage lo da por muerto ({phrase})"

    # 4. A cause you can point at, in code: the issue has to carry something
    #    that points at the behaviour (a script, a command, an error message).
    evidence = " ".join(
        [
            title,
            body,
            triage,
        ]
    ).lower()
    pointers = (
        "solidcraft-cli",
        "invalid parameters",
        "invalid input",
        "operation failed",
        ".json",
        "command",
    )
    if not any(p in evidence for p in pointers):
        return False, "no dice como se reproduce: no hay una causa que señalar en el codigo"

    # 5. Verifiable headless.
    if any(h in evidence for h in NEEDS_HARDWARE):
        return False, "la reproduccion necesita hardware que esta caja no tiene"

    # 6. One topic.
    if " and " in title.lower() and len(title) > 70:
        return False, "el titulo parece más de un tema"

    return True, "libre, con causa señalable y verificable headless"


def main():
    args = sys.argv[1:]
    all_issues = issues()
    if all_issues is None:
        print("next-issue: no se pudo leer el upstream", file=sys.stderr)
        return 2
    all_issues.sort(key=lambda i: i["number"], reverse=True)  # the newest first

    if "--explain" in args:
        number = int(args[args.index("--explain") + 1])
        for issue in all_issues:
            if issue["number"] == number:
                keep, reason = classify(issue)
                if keep:
                    state = claim_state(number)
                    if state == 1:
                        reason = "el claim lo tiene otro PR (mas bajo)"
                        keep = False
                    elif state == 2:
                        reason = "el claim no se pudo verificar"
                        keep = False
                print(f"#{number} {issue['title']}")
                print(f"  {'SE TOMA' if keep else 'SE DEJA'}: {reason}")
                return 0 if keep else 1
        print(f"next-issue: el issue #{number} no esta abierto", file=sys.stderr)
        return 2

    # The cheap filters first, and the arbiter only about the ones that
    # survived them: asking GitHub for three hundred issues took five minutes.
    shortlist = []
    for issue in all_issues:
        keep, reason = classify(issue)
        if keep:
            shortlist.append((issue, reason))
        elif args == ["--list"]:
            print(f"#{issue['number']:<6} {'SE DEJA':<8} {reason[:70]}")

    kept = []
    for issue, reason in shortlist:
        # 2. Claimed by an open PR: the arbiter decides, not the labels.
        state = claim_state(issue["number"])
        if state == 1:
            reason = "el claim lo tiene otro PR (mas bajo)"
            keep = False
        elif state == 2:
            reason = "el claim no se pudo verificar"
            keep = False
        else:
            keep = True
        if args == ["--list"]:
            print(f"#{issue['number']:<6} {'SE TOMA' if keep else 'SE DEJA':<8} {reason[:70]:<70} {issue['title'][:50]}")
        if keep:
            kept.append((issue, reason))
            if args != ["--list"]:
                break

    if args == ["--list"]:
        return 0
    if not kept:
        print("next-issue: no hay ningun issue libre que valga un agente ahora", file=sys.stderr)
        return 1
    issue, reason = kept[0]
    print(issue["number"])
    print(f"next-issue: #{issue['number']} {issue['title']} ({reason})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
