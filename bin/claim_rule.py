#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# claim_rule.py - LA regla de "quien tiene el claim del issue N". Una sola.
#
# POR QUE EXISTE (2026-11-21): la regla tenia varias copias (un jq dentro de
# bin/claim-verify.sh, y las de loop/bin/claim-race.sh y claim-guard.sh), y la
# de claim-verify sacaba el "ruido" (los bloques de codigo, los comentarios
# HTML) como lo hace pr-checks.js ANTES de leer el body. El bot del claim del
# upstream (scripts/claim/claim.js) NO lo saca: un `Fixes #N` dentro de un
# bloque de codigo ES un claim para el bot y era "libre" para nosotros. Esa es
# la direccion cara: el orquestador gasta un slot en un issue que otro tiene.
#
# LA REGLA es la UNION de los dos bots del upstream (lo que cualquiera de los
# dos cuenta como claim, es un claim):
#   * claim.js, referencedIssues: `#N` en el TITULO (al principio, despues de
#     un espacio o de un parentesis) y `<verbo de cierre>[:] #N` en el BODY,
#     SIN sacar nada del body, y solo los primeros MAX_REFS = 5 numeros;
#   * pr-checks.js, parseClosing: el body SIN el ruido (stripNoise), y despues
#     el verbo de cierre con una LISTA ("Fixes #1, #2 and #3") y las
#     referencias `owner/repo#N` cuando el repo es el nuestro.
# Un PR no se reclama a si mismo (claim.js: `if (n === pull.number) continue`).
#
# QUIEN GANA: el PR abierto de numero MAS BAJO que compite. Los PRs nuestros
# (autor vdirienzo, FORK_OWNER) no compiten con nosotros (claim.js y
# pr-checks.js saltan los del mismo autor). Y el issue lo RETIENE quien esta
# asignado, o quien tiene la etiqueta `in progress` (claim.js: `held =
# assignees.length > 0 || hasLabel(issue)`), aunque no haya PR.
#
# Las expresiones son las del upstream, traducidas con cuidado: re.ASCII hace
# que \b, \d y \w sean los de JavaScript sin la bandera `u`, y el \s de JS
# (que incluye el espacio duro y los espacios de Unicode) va escrito a mano.
# bin/test-claim-rule.py corre el claim.js y el pr-checks.js de verdad con
# node sobre las mismas entradas y exige el mismo resultado.
#
# USO (lo llama bin/claim-verify.sh; la salida es SU contrato):
#   python3 bin/claim_rule.py verify --issue N [--our-pr P] [--me LOGIN]
#           [--repo owner/name] (--snapshot FILE [--max-age-min M] | --prs-lines FILE)
#           [--issue-json FILE]
#
# CODIGOS DE SALIDA de `verify`: 0 nuestro/libre, 1 ocupado/perdido,
# 2 no se sabe, 10 la foto no sirve (el que llama va a GitHub en vivo).
# ---------------------------------------------------------------------------
import json
import os
import re
import sys

REPO = "tangency-labs/solidcraft"
LABEL = "in progress"
MAX_REFS = 5
OUR_LOGIN_DEFAULT = "vdirienzo"
# The bot of the upstream: REST calls it github-actions[bot], GraphQL (and
# so `gh issue view --json comments`) calls it github-actions.
BOT_LOGINS = {"github-actions[bot]", "github-actions"}

# JavaScript's \s, without the `u` flag (ECMAScript WhiteSpace + LineTerminator).
_JS_WS = "".join(
    chr(c)
    for c in (0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, *range(0x2000, 0x200B),
              0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF)
)

# claim.js, referencedIssues.
_TITLE_RE = re.compile(r"(?:^|[" + _JS_WS + r"(])#(\d{1,7})\b", re.ASCII)
_CLAIM_BODY_RE = re.compile(
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[" + _JS_WS + r"]*:?[" + _JS_WS + r"]+#(\d{1,7})\b",
    re.ASCII | re.IGNORECASE,
)
# pr-checks.js, stripNoise and parseClosing.
_COMMENT_RE = re.compile(r"<!--[\s\S]*?-->")
_FENCE_RE = re.compile(r"```[\s\S]*?```")
_TILDE_RE = re.compile(r"~~~[\s\S]*?~~~")
_INLINE_RE = re.compile(r"`[^`\n]*`")
_CLOSING_RE = re.compile(
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?[ \t]+"
    r"((?:(?:[\w.-]+/[\w.-]+)?#\d+(?:[ \t]*(?:,|and|&)[ \t]*)?)+)",
    re.ASCII | re.IGNORECASE,
)
_REF_RE = re.compile(r"(?:([\w.-]+/[\w.-]+))?#(\d+)", re.ASCII)
# claim.js, recordedClaimant.
_CLAIMED_BY_RE = re.compile(r"^Claimed by @([A-Za-z0-9-]+)")


def _text(value):
    # JS `String(x || '')`.
    return value if isinstance(value, str) else ("" if not value else str(value))


def strip_noise(body, inline_code=True):
    """pr-checks.js stripNoise: template comments and code blocks hold
    examples, not claims (for pr-checks; claim.js does NOT strip)."""
    text = _TILDE_RE.sub("", _FENCE_RE.sub("", _COMMENT_RE.sub("", _text(body))))
    return _INLINE_RE.sub("", text) if inline_code else text


def referenced_issues(title, body):
    """claim.js referencedIssues: the issue numbers a PR claims for the bot."""
    found = {}
    for m in _TITLE_RE.finditer(_text(title)):
        found.setdefault(int(m.group(1)), None)
    for m in _CLAIM_BODY_RE.finditer(_text(body)):
        found.setdefault(int(m.group(1)), None)
    return [n for n in found if n > 0][:MAX_REFS]


def parse_closing(body, repo_full_name=REPO):
    """pr-checks.js parseClosing: the issues a PR closes, for the Duplicate
    PR check."""
    found = set()
    for m in _CLOSING_RE.finditer(strip_noise(body)):
        for ref in _REF_RE.finditer(m.group(1)):
            if ref.group(1) and repo_full_name and ref.group(1).lower() != repo_full_name.lower():
                continue
            found.add(int(ref.group(2)))
    return sorted(found)


def _number(pr):
    n = pr.get("number")
    return n if isinstance(n, int) else None


def author(pr):
    a = pr.get("author")
    if isinstance(a, dict):
        return a.get("login") or ""
    return a if isinstance(a, str) else ""


def claimed_issues(pr, repo=REPO):
    """Every issue the PR claims for EITHER bot (the conservative union)."""
    if pr.get("_judged"):
        # A PR that gh's filter already judged and whose text did not come
        # (the stubs of the tests answer only the number): it claims.
        return {pr.get("_issue")}
    nums = set(referenced_issues(pr.get("title"), pr.get("body")))
    nums |= set(parse_closing(pr.get("body"), repo))
    nums.discard(_number(pr))
    return nums


def claims(pr, issue, repo=REPO):
    return _number(pr) is not None and int(issue) in claimed_issues(pr, repo)


class ClaimIndex(dict):
    """issue -> {pr number: pr}: every claim of every PR, parsed ONCE. Asking
    the list of PRs about each issue is issues x PRs regexps (6800 x 1050:
    minutes); the index is one pass over the PRs."""


def index(prs, repo=REPO):
    idx = ClaimIndex()
    for pr in prs or []:
        if isinstance(pr, dict) and _number(pr) is not None:
            for n in claimed_issues(pr, repo):
                idx.setdefault(n, {}).setdefault(_number(pr), pr)
    return idx


def claimants(prs, issue, repo=REPO):
    """The open PRs that claim the issue, lowest number first (one per
    number). `prs` is a list of PRs or a ClaimIndex of them."""
    if isinstance(prs, ClaimIndex):
        found = prs.get(int(issue)) or {}
        return [found[n] for n in sorted(found)]
    out = {}
    for pr in prs or []:
        if isinstance(pr, dict) and claims(pr, issue, repo):
            out.setdefault(_number(pr), pr)
    return [out[n] for n in sorted(out)]


def same_login(a, b):
    return bool(a) and bool(b) and a.lower() == b.lower()


def recorded_claimant(comments):
    """claim.js recordedClaimant, over the comments we have: who the bot's
    latest "Claimed by @user" names (GitHub does not assign people who are
    not collaborators, so for them this reply is the only record)."""
    who = None
    for c in comments or []:
        if not isinstance(c, dict):
            continue
        a = c.get("author")
        login = a.get("login") if isinstance(a, dict) else a
        if login in BOT_LOGINS:
            m = _CLAIMED_BY_RE.match(_text(c.get("body")))
            if m:
                who = m.group(1)
    return who


def hold(issue, me):
    """claim.js: an issue is HELD when somebody is assigned or it carries the
    `in progress` label, PR or no PR. None, or {who, ours, why}."""
    if not isinstance(issue, dict):
        return None
    logins = [a.get("login") or "" for a in issue.get("assignees") or [] if isinstance(a, dict)]
    logins = [l for l in logins if l]
    if logins:
        ours = any(same_login(l, me) for l in logins)
        return {"who": ", ".join(logins), "ours": ours, "why": "asignado"}
    labels = {(l.get("name") if isinstance(l, dict) else l) for l in issue.get("labels") or []}
    if LABEL in labels:
        who = recorded_claimant(issue.get("comments"))
        return {"who": who or "alguien", "ours": same_login(who, me), "why": f"etiqueta '{LABEL}'"}
    return None


def holder(issue, prs, me, repo=REPO):
    """For the SELECTION of a new issue: who holds it.

    {"state": "free"} | {"state": "ours", ...} | {"state": "taken", ...} |
    {"state": "held", ...}. "ours" is not free either: we already have it."""
    number = issue["number"] if isinstance(issue, dict) else int(issue)
    hits = claimants(prs, number, repo)
    if hits:
        mine = [p for p in hits if same_login(author(p), me)]
        others = [p for p in hits if not same_login(author(p), me)]
        if others and (not mine or _number(others[0]) < _number(mine[0])):
            return {"state": "taken", "pr": _number(others[0]), "author": author(others[0])}
        return {"state": "ours", "pr": _number(mine[0])}
    h = hold(issue, me)
    if h:
        return {"state": "ours" if h["ours"] else "held", "who": h["who"], "why": h["why"]}
    return {"state": "free"}


def verify(issue, prs, our_pr=None, me=None, issue_obj=None, repo=REPO):
    """The arbiter of bin/claim-verify.sh: (rc, stdout lines, stderr lines).

    With our PR: the lowest-numbered COMPETING claimant wins; our other PRs do
    not compete, ours always does. Without it there is no way to know which
    PR is ours, so EVERY claimant blocks (the contract of the callers: the
    selection must not start an issue we already have), and the hold
    (assignee, `in progress`) blocks too. The hold is NOT applied with our PR:
    after our draft the bot labels the issue for US, and close-slot.sh closes
    our PR on rc=1."""
    issue = int(issue)
    out = []
    hits = claimants(prs, issue, repo)
    if not hits:
        out.append(f"issue={issue} PRs que lo mencionan: (ninguno)")
        if our_pr:
            out.append(f"VEREDICTO=OK el claim es nuestro (PR #{our_pr}, nadie mas lo menciona)")
            return 0, out, []
        h = hold(issue_obj, me)
        if h and not h["ours"]:
            out.append(f"issue={issue} lo retiene {h['who']} ({h['why']})")
            out.append(f"VEREDICTO=OCUPADO el issue #{issue} lo retiene {h['who']} ({h['why']})")
            return 1, out, []
        out.append("VEREDICTO=OK el issue esta libre (nadie lo menciona)")
        return 0, out, []

    our_holder = None
    winner = None
    for pr in hits:
        num = _number(pr)
        if our_pr and num != our_pr and same_login(author(pr), me):
            if our_holder is None or num < our_holder:
                our_holder = num
            continue
        if winner is None or num < _number(winner):
            winner = pr
    winner_num = _number(winner) if winner else None
    listed = " ".join(str(_number(p)) for p in hits)
    out.append(f"issue={issue} PRs que lo mencionan: {listed} (gana el {winner_num if winner_num else our_holder})")
    if our_holder:
        out.append(f"issue={issue} PRs nuestros (no compiten con nosotros): {our_holder}")
    if our_pr:
        if winner is None:
            out.append(f"issue={issue} el claim lo tiene nuestro PR #{our_holder}: no se pierde")
            out.append(f"VEREDICTO=OK el claim es nuestro (PR #{our_pr})")
            return 0, out, []
        if winner_num == our_pr:
            out.append(f"VEREDICTO=OK el claim es nuestro (PR #{our_pr})")
            return 0, out, []
        out.append(f"VEREDICTO=PERDIDO el PR #{our_pr} perdio contra el #{winner_num}")
        if author(winner):
            out.append(f"  el PR #{winner_num} es de {author(winner)}")
        out.append(f"  cerralo con: gh pr close {our_pr}")
        out.append(f"  libera el slot con: bash bin/slot-lock.sh --slot {issue} --release")
        return 1, out, []
    out.append(f"VEREDICTO=OCUPADO el PR #{winner_num} ya reclama #{issue}")
    return 1, out, []


# --- the inputs of claim-verify.sh -------------------------------------------


def parse_pr_lines(text, issue):
    """The answer of `gh pr list ... --jq <prefilter>`: one PR per line, as
    JSON. A line that is only a number (or "number<TAB>author") is a PR the
    filter of gh already judged without its text: it counts as a claim (the
    stubs of the tests answer like that, and so did the old filter). Anything
    else is an answer we do not understand: ValueError, never "free"."""
    prs = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        m = re.fullmatch(r"(\d+)(?:\t(\S*))?", raw.strip("\r\n "))
        if m:
            prs.append({"number": int(m.group(1)), "author": {"login": m.group(2) or ""},
                        "_judged": True, "_issue": int(issue)})
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            raise ValueError(f"una linea que no se entiende: {line[:80]!r}")
        items = obj if isinstance(obj, list) else [obj]
        for item in items:
            if isinstance(item, int):
                prs.append({"number": item, "author": {"login": ""}, "_judged": True, "_issue": int(issue)})
            elif isinstance(item, dict) and isinstance(item.get("number"), int):
                if isinstance(item.get("author"), str):
                    item = dict(item, author={"login": item["author"]})
                prs.append(item)
            else:
                raise ValueError(f"una linea que no se entiende: {line[:80]!r}")
    return prs


def _load_issue_json(path):
    """The record of `gh issue view --json labels,assignees,comments`, or None
    when it is not one (the stubs of the tests answer `[]` or nothing)."""
    try:
        with open(path, encoding="utf-8") as fh:
            obj = json.load(fh)
    except (OSError, ValueError):
        return None
    if isinstance(obj, dict) and ("labels" in obj or "assignees" in obj):
        return obj
    return None


def _cli_verify(argv):
    opts = {"--issue": None, "--our-pr": None, "--me": None, "--repo": REPO, "--snapshot": None,
            "--max-age-min": None, "--prs-lines": None, "--issue-json": None}
    i = 0
    while i < len(argv):
        if argv[i] in opts and i + 1 < len(argv):
            opts[argv[i]] = argv[i + 1]
            i += 2
        else:
            print(f"claim_rule: opcion desconocida: {argv[i]}", file=sys.stderr)
            return 2
    try:
        issue = int(opts["--issue"])
        our_pr = int(opts["--our-pr"]) if opts["--our-pr"] else None
    except (TypeError, ValueError):
        print("claim_rule: --issue (y --our-pr) tienen que ser numeros", file=sys.stderr)
        return 2
    me = opts["--me"] or OUR_LOGIN_DEFAULT
    repo = opts["--repo"]
    issue_obj = None
    if opts["--snapshot"]:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import gh_snapshot  # noqa: E402 - the sibling module

        max_age = float(opts["--max-age-min"]) if opts["--max-age-min"] else None
        snap, why = gh_snapshot.load(opts["--snapshot"], max_age, repo)
        if snap is None:
            print(f"claim-verify: la foto no sirve ({why}): se pregunta a GitHub en vivo", file=sys.stderr)
            return 10
        issue_obj = next((it for it in snap["issues"] if it.get("number") == issue), None)
        if issue_obj is None:
            # The photo does not know the issue (closed, or newer than the
            # photo, and then so are the PRs that claim it): it cannot say.
            print("claim-verify: el issue no esta entre los abiertos de la foto: se pregunta a GitHub en vivo",
                  file=sys.stderr)
            return 10
        prs = snap["prs"]
        print(f"claim-verify: fuente=foto de hace {gh_snapshot.age_min(snap):.0f} min ({opts['--snapshot']})",
              file=sys.stderr)
    else:
        try:
            with open(opts["--prs-lines"] or "/dev/null", encoding="utf-8") as fh:
                prs = parse_pr_lines(fh.read(), issue)
        except (OSError, ValueError) as exc:
            print(f"VEREDICTO=ERROR la respuesta de GitHub no se entiende ({exc})", file=sys.stderr)
            return 2
        if opts["--issue-json"]:
            issue_obj = _load_issue_json(opts["--issue-json"])
            if issue_obj is None and not our_pr:
                print("claim-verify: el issue no se pudo leer: no se mira quien lo tiene asignado", file=sys.stderr)
    rc, out, err = verify(issue, prs, our_pr, me, issue_obj, repo)
    for line in out:
        print(line)
    for line in err:
        print(line, file=sys.stderr)
    return rc


def main(argv):
    if argv[:1] == ["verify"]:
        # An exception is UNKNOWN (2), never the 1 of python's traceback:
        # close-slot.sh closes our pull request on rc=1.
        try:
            return _cli_verify(argv[1:])
        except Exception as exc:  # noqa: BLE001
            print(f"VEREDICTO=ERROR la regla del claim fallo ({exc.__class__.__name__}: {exc})", file=sys.stderr)
            return 2
    if argv[:1] == ["refs"] and len(argv) >= 2:
        # A quick look for a human: which issues does this title/body claim?
        title, body = argv[1], (argv[2] if len(argv) > 2 else "")
        print(json.dumps({"claim.js": referenced_issues(title, body), "pr-checks.js": parse_closing(body),
                          "union": sorted(claimed_issues({"title": title, "body": body}))}))
        return 0
    print("uso: claim_rule.py verify --issue N [...] | claim_rule.py refs <titulo> [<body>]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
