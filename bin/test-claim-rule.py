#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# test-claim-rule.py - la regla del claim (bin/claim_rule.py) es la de los dos
# bots del upstream, y lo PRUEBA contra el codigo de ellos.
#
# QUE PRUEBA:
#   1. con node: el claim.js y el pr-checks.js DE VERDAD (los de origin/main
#      del checkout, `git show`) corren sobre las mismas entradas que el
#      modulo, y referencedIssues, parseClosing y stripNoise tienen que dar lo
#      mismo. Sin node (o sin el checkout) esa parte se salta con un aviso: la
#      regla se sigue probando con los casos escritos a mano de abajo;
#   2. la union: lo que cualquiera de los dos bots cuenta es un claim (un
#      `Fixes #N` en un bloque de codigo ES un claim: claim.js no saca nada);
#   3. quien gana: el numero mas bajo que compite; lo nuestro no compite; la
#      etiqueta `in progress` y el asignado retienen el issue.
#
# NUNCA toca GitHub. Corre: python3 bin/test-claim-rule.py
# ---------------------------------------------------------------------------
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import claim_rule as cr  # noqa: E402

CHECKOUT = os.environ.get("SOLIDCRAFT_REPO", "/home/user/Projects/solidcraft-orch")
PASS = 0
FAIL = 0


def ok(name):
    global PASS
    PASS += 1
    print(f"ok   - {name}")


def no(name, detail=""):
    global FAIL
    FAIL += 1
    print(f"FALLA- {name}")
    if detail:
        print(f"       {detail}")


def check(name, got, want):
    if got == want:
        ok(name)
    else:
        no(name, f"dio {got!r}, se esperaba {want!r}")


# The shared fixtures: (title, body). Each one is a corner of one of the two
# parsers; the node half asserts the module and the upstream agree on ALL.
FIXTURES = [
    ("Correct mouse and trackpad navigation presets (#361)", "the body says nothing about the issue"),
    ("x", "Fixes #361"),
    ("x", "```\nFixes #361\n```"),
    ("x", "<!-- Fixes #361 -->"),
    ("x", "`Fixes #361`"),
    ("x", "~~~\nCloses #361\n~~~"),
    ("x", "antes\n```\nFixes #362\n```\ndespues\nFixes #361"),
    ("x", "Fixes #10181, #10182"),
    ("x", "Fixes #1 and #2 & #3"),
    ("x", "Fixes #1,#2"),
    ("x", "Fixes other/repo#361"),
    ("x", "Fixes tangency-labs/solidcraft#361"),
    ("x", "Fixes TANGENCY-LABS/SolidCraft#361"),
    ("x", "Resolved owner/repo#3 and #4"),
    ("x", "Fixes: #8834"),
    ("x", "Fixes:#8834"),
    ("x", "Fixes\n#8834"),
    ("x", "Fixes #9"),
    ("x", "fixed #5, closed #6, resolves #7"),
    ("x", "FIXES #44"),
    ("x", "prefixes #1 unfixed #2"),
    ("x", "fixing #3"),
    ("x", "This fix 3 problems."),
    ("x", "Claim for #743."),
    ("Claim for the issue (#743)", "Claim for #743."),
    ("#1 #2 #3 #4", "Fixes #5 Fixes #6 Fixes #7"),
    ("x", "Fixes #07058"),
    ("x", "Fixes #12345678"),
    ("abc#12 (#13)", ""),
    ("#12a", ""),
    ("x", "Fixes #0"),
    ("x", "Fixes https://github.com/tangency-labs/solidcraft/issues/55"),
    ("[Fix] x (#1)\n(#2)", ""),
    ("x", "<!-- unclosed comment Fixes #9"),
    ("x", "```\nFixes #9"),
    ("x", "closes #1\r\nfixes #2"),
    ("Unicode título (#77)", "Fixé #78"),
    ("x", "ﬁxes #3"),
    ("x", "Fixes #3_"),
    ("x", "Fixes #3610"),
    ("", ""),
    (None, None),
]

NODE_PROGRAM = r"""
'use strict';
const fs = require('fs');
const claim = require(process.argv[2]);
const checks = require(process.argv[3]);
const fixtures = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
const repo = process.argv[5];
const out = fixtures.map(([title, body]) => ({
  ref: claim.referencedIssues(title, body),
  closing: checks.parseClosing(body, repo),
  strip: checks.stripNoise(body),
  stripKeepInline: checks.stripNoise(body, { inlineCode: false }),
}));
process.stdout.write(JSON.stringify(out));
"""


def node_half():
    node = shutil.which("node")
    if not node:
        print("SKIP- node no esta instalado: no se compara con el claim.js y el pr-checks.js de verdad")
        return
    tmp = tempfile.mkdtemp(prefix="test-claim-rule.")
    try:
        # The upstream sources, each in a directory of its own, and the
        # program that runs them in another one.
        sources = {}
        for name, path in (("claim", "scripts/claim/claim.js"), ("checks", "scripts/pr-checks/pr-checks.js")):
            done = subprocess.run(["git", "-C", CHECKOUT, "show", f"origin/main:{path}"],
                                  capture_output=True, text=True, timeout=60)
            if done.returncode != 0 or not done.stdout.strip():
                print(f"SKIP- no se pudo leer {path} de origin/main en {CHECKOUT}: no se compara con node")
                return
            d = os.path.join(tmp, name)
            os.makedirs(d)
            sources[name] = os.path.join(d, os.path.basename(path))
            with open(sources[name], "w", encoding="utf-8") as fh:
                fh.write(done.stdout)
        prog_dir = os.path.join(tmp, "prog")
        os.makedirs(prog_dir)
        prog = os.path.join(prog_dir, "run.js")
        with open(prog, "w", encoding="utf-8") as fh:
            fh.write(NODE_PROGRAM)
        fixtures = os.path.join(prog_dir, "fixtures.json")
        with open(fixtures, "w", encoding="utf-8") as fh:
            json.dump(FIXTURES, fh)
        done = subprocess.run([node, prog, sources["claim"], sources["checks"], fixtures, cr.REPO],
                              capture_output=True, text=True, timeout=60, cwd=prog_dir)
        if done.returncode != 0:
            no("node corre el claim.js y el pr-checks.js de verdad", done.stderr[-400:])
            return
        upstream = json.loads(done.stdout)
        # MAX_REFS is the upstream's own number, not a copy that drifts.
        with open(sources["claim"], encoding="utf-8") as fh:
            text = fh.read()
        check("MAX_REFS es el del claim.js", f"const MAX_REFS = {cr.MAX_REFS};" in text, True)
        bad = []
        for (title, body), want in zip(FIXTURES, upstream):
            got = {
                "ref": cr.referenced_issues(title, body),
                "closing": cr.parse_closing(body, cr.REPO),
                "strip": cr.strip_noise(body),
                "stripKeepInline": cr.strip_noise(body, inline_code=False),
            }
            if got != want:
                bad.append(f"{(title, body)!r}: modulo={got} upstream={want}")
        if bad:
            no(f"el modulo y el upstream dan lo mismo en los {len(FIXTURES)} casos", "; ".join(bad[:5]))
        else:
            ok(f"el modulo y el claim.js/pr-checks.js de verdad dan lo mismo en los {len(FIXTURES)} casos")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def pr(number, title="", body="", login="rival"):
    return {"number": number, "title": title, "body": body, "author": {"login": login}}


def rule_half():
    # The union: what EITHER bot counts.
    check("un Fixes #N en un bloque de codigo ES un claim (claim.js no saca el ruido)",
          cr.claims(pr(1700, "un titulo sin issue", "```\nFixes #361\n```"), 361), True)
    check("un Fixes #N en un comentario HTML ES un claim (claim.js)",
          cr.claims(pr(1701, "t", "<!-- Fixes #361 -->"), 361), True)
    check("una lista reclama el segundo issue (pr-checks.js)", cr.claims(pr(500, "Fix", "Fixes #10181, #10182"), 10182), True)
    check("el sexto issue del titulo no lo cuenta claim.js (MAX_REFS) ni pr-checks.js",
          cr.claims(pr(500, "#1 #2 #3 #4 #5 #6", ""), 6), False)
    check("el sexto issue del BODY lo cuenta pr-checks.js",
          cr.claims(pr(500, "#1 #2 #3 #4 #5", "Fixes #6"), 6), True)
    check("owner/repo#N de nuestro repo es un claim", cr.claims(pr(1, "t", "Fixes tangency-labs/solidcraft#361"), 361), True)
    check("owner/repo#N de OTRO repo no es un claim", cr.claims(pr(1, "t", "Fixes other/repo#361"), 361), False)
    check("una mencion en prosa no es un claim", cr.claims(pr(6997, "Something", "since #10183 the UI"), 10183), False)
    check("un PR no se reclama a si mismo", cr.claims(pr(361, "propio", "Fixes #361"), 361), False)
    check("un numero mas largo no es este issue", cr.claims(pr(500, "Fix", "Fixes #3610"), 361), False)
    check("Fixes #3_ lo cuenta pr-checks.js (sin \\b) aunque claim.js no",
          (cr.referenced_issues("x", "Fixes #3_"), cr.claims(pr(9, "x", "Fixes #3_"), 3)), ([], True))

    # Who wins.
    prs = [pr(900, "New", "Fixes #7777"), pr(500, "Old", "Fixes #7777")]
    check("los claimants van del numero mas bajo al mas alto", [p["number"] for p in cr.claimants(prs, 7777)], [500, 900])
    rc, out, _ = cr.verify(7777, prs, our_pr=900, me="ourfork")
    check("nuestro #900 pierde contra el #500", (rc, out[-4] if len(out) >= 4 else out),
          (1, "VEREDICTO=PERDIDO el PR #900 perdio contra el #500"))
    rc, out, _ = cr.verify(7777, prs, our_pr=500, me="ourfork")
    check("nuestro #500 gana contra el #900", (rc, out[-1]), (0, "VEREDICTO=OK el claim es nuestro (PR #500)"))
    two_ours = [pr(9843, "N", "Fixes #361", "ourfork"), pr(11205, "N2", "Fixes #361", "ourfork")]
    rc, out, _ = cr.verify(361, two_ours, our_pr=11205, me="OurFork")
    check("dos PRs nuestros: el mas alto no pierde (y el login no distingue mayusculas)", rc, 0)
    rc, out, _ = cr.verify(361, two_ours, our_pr=None, me="ourfork")
    check("sin nuestro PR, cualquier claimant bloquea (el contrato de los que llaman)", (rc, out[-1]),
          (1, "VEREDICTO=OCUPADO el PR #9843 ya reclama #361"))
    rc, out, _ = cr.verify(361, [], our_pr=None, me="ourfork")
    check("nadie lo menciona: libre", (rc, out), (0, ["issue=361 PRs que lo mencionan: (ninguno)",
                                                     "VEREDICTO=OK el issue esta libre (nadie lo menciona)"]))

    # The hold (claim.js: assignees or the `in progress` label).
    issue = {"number": 361, "labels": [{"name": "in progress"}], "assignees": [], "comments": [
        {"author": {"login": "github-actions"}, "body": "Claimed by @alguien. Please open a draft PR..."}]}
    rc, out, _ = cr.verify(361, [], our_pr=None, me="ourfork", issue_obj=issue)
    check("la etiqueta in progress sin PR retiene el issue (OCUPADO)", (rc, out[-1]),
          (1, "VEREDICTO=OCUPADO el issue #361 lo retiene alguien (etiqueta 'in progress')"))
    ours = dict(issue, comments=[{"author": {"login": "github-actions[bot]"}, "body": "Claimed by @ourfork through #20081."}])
    check("la etiqueta puesta por NUESTRO claim no nos retiene", cr.verify(361, [], None, "ourfork", ours)[0], 0)
    rc, _, _ = cr.verify(361, [], our_pr=4242, me="ourfork", issue_obj=issue)
    check("con nuestro PR la etiqueta NO cuenta (close-slot cerraria nuestro trabajo)", rc, 0)
    assigned = {"number": 361, "labels": [], "assignees": [{"login": "otra"}], "comments": []}
    check("un asignado retiene el issue", cr.verify(361, [], None, "ourfork", assigned)[0], 1)
    check("asignado a nosotros: no nos retiene", cr.verify(361, [], None, "ourfork",
                                                         dict(assigned, assignees=[{"login": "ourfork"}]))[0], 0)

    # The selection (next-issue.py): ours is not free either.
    iss = {"number": 2, "labels": [], "assignees": [], "comments": []}
    check("holder: libre", cr.holder(iss, [], "vdirienzo")["state"], "free")
    check("holder: lo tiene otro", cr.holder(iss, [pr(4242, "otro (#2)", "", "otro")], "vdirienzo"),
          {"state": "taken", "pr": 4242, "author": "otro"})
    check("holder: ya es nuestro", cr.holder(iss, [pr(4242, "nuestro (#2)", "", "vdirienzo")], "vdirienzo"),
          {"state": "ours", "pr": 4242})
    check("holder: nuestro mas bajo que el rival sigue siendo nuestro",
          cr.holder(iss, [pr(4000, "(#2)", "", "vdirienzo"), pr(4242, "(#2)", "", "otro")], "vdirienzo")["state"], "ours")
    check("holder: el rival mas bajo gana", cr.holder(iss, [pr(4300, "(#2)", "", "vdirienzo"),
                                                           pr(4242, "(#2)", "", "otro")], "vdirienzo")["state"], "taken")
    check("holder: la etiqueta retiene", cr.holder(dict(iss, labels=[{"name": "in progress"}]), [], "vdirienzo")["state"], "held")

    # The answer of gh (the input of claim-verify.sh).
    lines = '{"number":5,"author":"x","title":"(#9)","body":""}\n4242\n4100\totro\n'
    got = cr.parse_pr_lines(lines, 9)
    check("las lineas de gh: JSON, numero solo y numero<TAB>autor",
          [(p["number"], cr.author(p), bool(p.get("_judged"))) for p in got],
          [(5, "x", False), (4242, "", True), (4100, "otro", True)])
    check("un numero solo cuenta como claim (el filtro de gh ya lo juzgo)", cr.claims(got[1], 9), True)
    try:
        cr.parse_pr_lines("gh: something went wrong\n", 9)
        no("una respuesta que no se entiende es un error, nunca 'libre'")
    except ValueError:
        ok("una respuesta que no se entiende es un error, nunca 'libre'")


def main():
    node_half()
    rule_half()
    print(f"\n{PASS + FAIL} casos, {FAIL} fallan")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
