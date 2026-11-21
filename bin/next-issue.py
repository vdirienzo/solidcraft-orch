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
# filters of docs/issue-selection.md, IN THAT ORDER; it asks the rule of the
# claim (bin/claim_rule.py, the same one bin/claim-verify.sh applies) who
# holds each candidate; it RANKS the ones that are left and gives the best.
#
# LA FOTO, NO 150 ISSUES (2026-11-21): antes leia `gh issue list --limit 150`
# (el upstream tiene ~6800 abiertos: veia el 2%) y llamaba a claim-verify.sh
# por candidato (cada llamada, ~11 paginas de GraphQL). Ahora lee la foto de
# bin/gh_snapshot.py (todos los issues y PRs abiertos; se reusa si tiene menos
# de GH_SNAPSHOT_MAX_AGE_MIN minutos, 15 por defecto, y si no se refresca con
# lo que cambio) y el claim se decide en memoria, para todos.
#
# EL ORDEN, NO "EL MAS NUEVO" (2026-11-21): los PRs de 80 lineas o menos se
# mergean en 20,7 h de mediana y los de mas de 300 en 96 h, y ui y doc son las
# areas que mas se mergean (reports/analisis-orquestador-2026-11-21.md, B1).
# Los que pasan los filtros se ordenan por un puntaje simple de "diff chico":
# etiqueta bug, pasos o script para reproducir, un texto de error citado, el
# area (ui/doc, despues sketch/io), reciente y con pocos comentarios. El mas
# nuevo solo desempata.
#
# LA FICHA (2026-11-21, bin/issue-card.py): si un issue tiene ficha, se usa
# (kernel_cause, varios temas, sin repro, lo decide el maintainer, crash sin
# replay, de plataforma, mas de 300 lineas: se deja). Con NEXT_ISSUE_TRIAGE=1
# se arman las fichas que faltan de los primeros NEXT_ISSUE_TRIAGE_TOP (5)
# candidatos, con a lo sumo NEXT_ISSUE_TRIAGE_MAX (5) llamadas al modelo cada
# NEXT_ISSUE_TRIAGE_WINDOW_MIN (10) minutos: la wave llama a este script una
# vez por slot libre, y el tope es de la wave, no de cada llamada.
#
# USAGE:
#   python3 bin/next-issue.py                # the next issue, on stdout
#   python3 bin/next-issue.py --list         # every candidate, why, and its score
#   python3 bin/next-issue.py --explain <N>  # why this one was kept or dropped
#   python3 bin/next-issue.py --exclude N,M  # skip these (the wave already tried them)
#   python3 bin/next-issue.py --snapshot FILE [--max-age-min N]
#
# EXIT CODES:
#   0  an issue is on stdout (and the reason for keeping it, on stderr)
#   1  there is no free issue worth an agent right now
#   2  the upstream could not be read
# ---------------------------------------------------------------------------
import fcntl
import importlib.util
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ORCH_DIR = os.environ.get("ORCH_DIR") or os.path.expanduser("~/.local/share/solidcraft-orch")
# The siblings live next to this script; ORCH_BIN is the fallback for a copy
# of it that runs outside bin/.
if os.path.exists(os.path.join(HERE, "claim_rule.py")):
    ORCH_BIN = HERE
else:
    ORCH_BIN = os.environ.get("ORCH_BIN") or os.path.join(ORCH_DIR, "bin")
sys.path.insert(0, ORCH_BIN)
import claim_rule  # noqa: E402
import gh_snapshot  # noqa: E402

_spec = importlib.util.spec_from_file_location("issue_card", os.path.join(ORCH_BIN, "issue-card.py"))
card_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(card_mod)

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
# The subjects whose cause lives in the PARKED code, even when the issue does
# not carry a paused label (filter 1: "an area the maintainer parked").
#
# WHY (2026-11-19): the STEP/IGES reader is `crates/kernel/src/step_in/`, and
# the kernel is PAUSED (RULES.md: no issue or pull request that touches
# crates/kernel - booleans, fillets, chamfers, shell, offsets, sweeps, lofts,
# threads, holes, STEP/IGES, tessellation). The upstream labels a STEP issue
# `area:io` more often than not, so the LABELS do not park it: the selector
# offered #19570 ("a half-sphere end cap is read inside out") to a wave. The
# honest outcome for an issue whose cause is in the parked code is to skip it,
# not to work around it (docs/issue-selection.md, "a filter that is about the
# CODE, not the issue text").
#
# "STEP" is matched in UPPER CASE on purpose: a lowercase "step" is a geometry
# step (the wall of a step), not the format.
PAUSED_SUBJECTS = ("STEP", "IGES")
# The subjects that ARE the parked code, by the way the upstream titles them.
# The kernel's own operations are parked too (RULES.md: booleans, fillets,
# chamfers, shell, offsets, sweeps, lofts, threads, holes), and the upstream
# labels most of them `area:sketch` or `area:io` instead of `area:kernel`, so
# the labels do not park them either: "Spline Boolean: a pocket returns two
# small cylinders" was in the pool with five more of its family.
#
# "Offset Plane" is NOT in the list: a plane is a datum, not a kernel offset.
PAUSED_PREFIXES = (
    "solidcore",
    "Local operation",
    "Tessellation",
    "Boolean",
    "Spline Boolean",
    "Fillet",
    "Chamfer",
    "Shell",
    "Sweep",
    "Loft",
    "Thread",
    "Hole",
    "Offset Face",
    "OffsetFacesFeature",
    "Render",
)
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
# DRAWINGS NO ES DE MAIN (2026-11-21): el upstream manda el trabajo de los
# planos a la rama `drawings`, y el orquestador solo trabaja sobre main. Un PR
# de planos contra main no se revisa: el agente quema su turno para nada. La
# lista del 21-11 tenia a #20181 ("Drawings: ...") entre los que se tomaban.
DRAWINGS_LABELS = {"area:drawings"}
# "Drawing sheets: ..." (#20481) es lo mismo con otro titulo; un "Drawing a
# line ..." de un sketch NO es de planos, por eso no basta con "Drawing".
DRAWINGS_PREFIXES = ("Drawings", "Drawing:", "Drawing sheet", "Drawing view")
# UNA FEATURE NO ES UN ARREGLO (2026-11-21, docs/issue-selection.md, "A feature
# request, not a bug"): lo que vale un agente es un bug con una reproduccion
# clara. #20223 ("Integrate the 3D sketching tools...") es un trabajo de
# diseno de varias semanas y estaba en la lista de los que se toman.
FEATURE_LABELS = {"enhancement", "feature", "type:feature", "feature request", "kind:feature"}
FEATURE_PREFIXES = ("Integrate", "Add support", "Feature request", "Implement", "[Feature")
# VARIOS TEMAS EN UN TITULO (2026-11-21, filtro 6): "Issues in v45 compared to
# v40 rc3" (#20178) son varios bugs en un issue, y un PR que los arregla todos
# no se revisa. El filtro viejo (" and " en un titulo largo) no lo veia.
MULTI_TOPIC_PHRASES = ("issues in", "several", "multiple bugs", "multiple issues", "and other")
# REPRO-FIRST DEL UPSTREAM (2026-11-21, .agents/skills/solidcraft-repro-first/
# SKILL.md en origin/main): los bugs de un sistema operativo, de un sistema de
# ventanas, de un backend grafico o un driver, del escalado de pantalla o del
# updater/instalador necesitan EVIDENCIA DE UN BUILD PUBLICADO (la version y
# el log) antes de cualquier fix. Esta caja no tiene esas maquinas: sin esa
# evidencia en el issue, el agente escribe un fix adivinado, que es justo lo
# que la regla prohibe. Las palabras van con bordes de palabra: "windows" no
# es "window" (una ventana de la UI es un bug normal). "Metal" no esta: "Sheet
# metal" es un area del producto. El escalado va como "display/ui scaling":
# "scaling" solo es escalar una geometria.
PLATFORM_WORDS = (
    "windows",
    "macos",
    "mac os",
    "wayland",
    "x11",
    "xwayland",
    "driver",
    "drivers",
    "gpu",
    "vulkan",
    "dx12",
    "directx",
    "opengl",
    "updater",
    "installer",
    "msi",
    "dmg",
    "flatpak",
    "appimage",
    "hidpi",
    "high dpi",
    "high-dpi",
    "display scaling",
    "ui scaling",
    "fractional scaling",
    "scale factor",
)
PLATFORM_RE = re.compile(r"\b(" + "|".join(re.escape(w) for w in PLATFORM_WORDS) + r")\b", re.IGNORECASE)
# La evidencia de un build publicado: una version (v45, 0.45.1, nightly) Y un
# log (un bloque de codigo, un adjunto .log, una traza).
VERSION_RE = re.compile(r"\b(v\d+(\.\d+)*|\d+\.\d+(\.\d+)?|nightly|rc\d+)\b", re.IGNORECASE)
LOG_RE = re.compile(r"(```|\.log\b|\blog:|\bstack ?trace\b|\bbacktrace\b|\bpanicked at\b)", re.IGNORECASE)


def our_login():
    """Who WE are: the same sources as bin/claim-verify.sh, without asking gh
    (FORK_OWNER, then the config.env of the loop, then the fork's owner)."""
    me = os.environ.get("FORK_OWNER") or ""
    if not me:
        config = os.path.join(os.environ.get("LOOP_DIR") or os.path.expanduser("~/.local/share/solidcraft-loop"), "config.env")
        try:
            with open(config, encoding="utf-8") as fh:
                for line in fh:
                    m = re.match(r"\s*(?:export\s+)?FORK_OWNER=[\"']?([A-Za-z0-9-]+)", line)
                    if m:
                        me = m.group(1)
        except OSError:
            pass
    return me if re.fullmatch(r"[A-Za-z0-9-]+", me or "") else claim_rule.OUR_LOGIN_DEFAULT


def snapshot(path=None, max_age_min=None):
    """The photo of GitHub (bin/gh_snapshot.py), fresh enough, or None."""
    if max_age_min is None:
        max_age_min = float(os.environ.get("GH_SNAPSHOT_MAX_AGE_MIN", "15"))
    snap, reused, err = gh_snapshot.ensure(path, max_age_min, REPO)
    if snap is None:
        print(f"next-issue: la foto de GitHub no se pudo sacar ({err})", file=sys.stderr)
        return None
    print(f"next-issue: {gh_snapshot.summary(snap, reused)}", file=sys.stderr)
    return snap


def claim_reason(issue, idx, me):
    """None when the issue is free for a NEW slot; the reason otherwise."""
    h = claim_rule.holder(issue, idx, me)
    state = h["state"]
    if state == "free":
        return None
    if state == "taken":
        return f"el claim lo tiene otro PR (#{h['pr']} de {h['author'] or '?'}, el mas bajo)"
    if state == "ours":
        if h.get("pr"):
            return f"ya es nuestro (PR #{h['pr']})"
        return f"ya es nuestro ({h.get('why')})"
    return f"lo retiene {h.get('who')} ({h.get('why')})"


# --- the score: issues likely to give a SMALL diff first ---------------------
BUG_LABELS = {"bug", "type:bug", "kind:bug"}
AREA_POINTS = {"area:ui": 2, "area:doc": 2, "area:sketch": 1, "area:io": 1}
REPRO_RE = re.compile(
    r"(steps to reproduce|to reproduce|reproduction|\brepro\b|^\s*1[.)]\s|solidcraft-cli|```)",
    re.IGNORECASE | re.MULTILINE,
)


def _days_since(stamp, now):
    try:
        t = time.mktime(time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
    except (TypeError, ValueError):
        return None
    return (now - t) / 86400.0


def score(issue, card=None, now=None):
    """(points, "bug+3 repro+2 ..."): the reasons are printed by --list."""
    now = now or time.time()
    labels = {l["name"] for l in issue.get("labels") or []}
    body = issue.get("body") or ""
    parts = []
    if labels & BUG_LABELS:
        parts.append(("bug", 3))
    if REPRO_RE.search(body):
        parts.append(("repro", 2))
    if card_mod.error_strings(issue, limit=1):
        parts.append(("error", 2))
    area = max(((AREA_POINTS[a], a) for a in labels if a in AREA_POINTS), default=None)
    if area:
        parts.append((area[1].split(":", 1)[1], area[0]))
    days = _days_since(issue.get("createdAt") or "", now)
    if days is not None and days <= 14:
        parts.append(("reciente", 2))
    elif days is not None and days <= 60:
        parts.append(("reciente", 1))
    comments = issue.get("commentsCount", len(issue.get("comments") or []))
    if comments <= 2:
        parts.append(("pocos-comentarios", 1))
    elif comments >= 10:
        parts.append(("muchos-comentarios", -1))
    llm = (card or {}).get("llm") if card_mod.has_llm(card) else None
    if llm and llm["est_diff_lines"] <= 80:
        parts.append(("diff-chico", 2))
    elif llm and llm["est_diff_lines"] > 150:
        parts.append(("diff-grande", -1))
    total = sum(p for _, p in parts)
    return total, " ".join(f"{name}{p:+d}" for name, p in parts) or "nada"


# --- the cards ----------------------------------------------------------------
class LlmBudget:
    """At most MAX model calls in WINDOW minutes, across the calls of this
    script (the wave calls it once per free slot). The calls are written
    down in state/cards/.llm-calls.json, under a lock."""

    def __init__(self):
        self.max = int(os.environ.get("NEXT_ISSUE_TRIAGE_MAX", "5"))
        self.window = float(os.environ.get("NEXT_ISSUE_TRIAGE_WINDOW_MIN", "10")) * 60
        self.path = os.path.join(card_mod.cards_dir(), ".llm-calls.json")

    def take(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path + ".lock", "w", encoding="utf-8") as lockfh:
            fcntl.flock(lockfh, fcntl.LOCK_EX)
            try:
                with open(self.path, encoding="utf-8") as fh:
                    calls = [float(t) for t in json.load(fh)]
            except (OSError, ValueError, TypeError):
                calls = []
            now = time.time()
            calls = [t for t in calls if now - t < self.window]
            if len(calls) >= self.max:
                return False
            calls.append(now)
            with open(self.path, "w", encoding="utf-8") as fh:
                json.dump(calls, fh)
            return True


def card_for(issue, idx, me, build, budget):
    """The card of the issue: the cached one, or (build=True) one built now,
    with the model half when the budget allows it."""
    card = card_mod.load_card(issue["number"])
    if not build or card_mod.has_llm(card):
        return card
    use_llm = budget.take()
    if card is not None and not use_llm:
        return card
    card, _, _ = card_mod.ensure_card(issue, idx, me, llm=use_llm)
    return card


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
    if labels & DRAWINGS_LABELS or any(title.strip().lower().startswith(p.lower()) for p in DRAWINGS_PREFIXES):
        return False, "es de planos: el upstream lo trabaja en la rama drawings, no en main"
    for subject in PAUSED_SUBJECTS:
        if subject in title:
            return False, f"el asunto esta en el codigo aparcado ({subject})"
    for prefix in PAUSED_PREFIXES:
        # The upstream writes the same subject in lower case, in caps and in
        # mixed case ("FILLET: SMLib fillet: operation: the blend failed" is
        # 950 issues), so the comparison cannot be case sensitive. The
        # SUBJECTS above are: there a lowercase "step" is a geometry step.
        if title.lower().startswith(prefix.lower()):
            return False, f"el asunto esta en el codigo aparcado ({prefix})"
    if issue.get("assignees"):
        return False, "ya tiene asignado a " + ", ".join(a["login"] for a in issue["assignees"])
    if title.strip().startswith("[RFC]"):
        return False, "es un RFC, no un arreglo"
    features = labels & FEATURE_LABELS
    if features:
        return False, "es una feature, no un bug (etiqueta: " + ", ".join(sorted(features)) + ")"
    for prefix in FEATURE_PREFIXES:
        if title.strip().lower().startswith(prefix.lower()):
            return False, f"es una feature, no un bug (el titulo empieza con '{prefix}')"

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
    # The upstream's repro-first rule: the TITLE and the LABELS say what the
    # bug is about (a body mentions "Windows" in its environment section for
    # every bug, so the body does not decide the subject); the BODY decides
    # whether the evidence from a released build is there.
    platform = PLATFORM_RE.search(" ".join([title, *sorted(labels)]))
    if platform:
        has_evidence = VERSION_RE.search(body) and LOG_RE.search(body)
        if not has_evidence:
            return False, (
                f"es de plataforma ({platform.group(1).lower()}): repro-first pide la version y el log "
                "de un build publicado, y el issue no los trae"
            )

    # 6. One topic.
    if " and " in title.lower() and len(title) > 70:
        return False, "el titulo parece más de un tema"
    low_title = title.lower()
    for phrase in MULTI_TOPIC_PHRASES:
        if re.search(r"\b" + re.escape(phrase) + r"\b", low_title):
            return False, f"el titulo junta varios temas ('{phrase}')"

    return True, "libre, con causa señalable y verificable headless"


def parse_exclude(args):
    """The issues the wave already tried in this turn (--exclude N,M or
    --exclude=N,M). An empty value is no exclusion: the wave passes the list
    as it is, also when it is still empty."""
    raw = []
    for i, arg in enumerate(args):
        if arg == "--exclude" and i + 1 < len(args):
            raw.append(args[i + 1])
        elif arg.startswith("--exclude="):
            raw.append(arg[len("--exclude="):])
    out = set()
    for chunk in raw:
        for part in re.split(r"[,\s]+", chunk):
            part = part.strip().lstrip("#")
            if part.isdigit():
                out.add(int(part))
    return out


def _arg(args, flag):
    for i, a in enumerate(args):
        if a == flag and i + 1 < len(args):
            return args[i + 1]
        if a.startswith(flag + "="):
            return a.split("=", 1)[1]
    return None


def evaluate(issue, idx, me, exclude):
    """(keep, reason) of the cheap filters and the claim."""
    if issue["number"] in exclude:
        return False, "la wave ya lo probo en este turno (--exclude)"
    keep, reason = classify(issue)
    if not keep:
        return False, reason
    # 2. Claimed by an open PR, or held: the rule of the claim decides, from
    # the photo (it costs nothing now, so it is asked for every candidate).
    why = claim_reason(issue, idx, me)
    if why:
        return False, why
    return True, reason


def main():
    args = sys.argv[1:]
    # POR QUE --exclude (2026-11-21): este script no tiene memoria, y la wave le
    # pedia "el siguiente" despues de un prepare-slot que fallaba: le devolvia
    # el MISMO issue, y la wave daba vueltas sin fin sin despachar nada. La
    # wave le pasa los que ya probo en el turno.
    exclude = parse_exclude(args)
    list_mode = "--list" in args
    max_age = _arg(args, "--max-age-min")
    snap = snapshot(_arg(args, "--snapshot"), float(max_age) if max_age else None)
    if snap is None:
        print("next-issue: no se pudo leer el upstream", file=sys.stderr)
        return 2
    all_issues = sorted(snap["issues"], key=lambda i: i["number"], reverse=True)  # the newest first
    idx = claim_rule.index(snap["prs"], REPO)
    me = our_login()
    build = os.environ.get("NEXT_ISSUE_TRIAGE") == "1"
    top = int(os.environ.get("NEXT_ISSUE_TRIAGE_TOP", "5"))
    budget = LlmBudget()

    if "--explain" in args:
        number = int(_arg(args, "--explain"))
        for issue in all_issues:
            if issue["number"] == number:
                keep, reason = evaluate(issue, idx, me, set())
                card = card_for(issue, idx, me, build and keep, budget) if keep else card_mod.load_card(number)
                if keep:
                    why = card_mod.drop_reason(card)
                    if why:
                        keep, reason = False, why
                points, parts = score(issue, card)
                print(f"#{number} {issue['title']}")
                print(f"  {'SE TOMA' if keep else 'SE DEJA'}: {reason}")
                print(f"  puntaje: {points} ({parts})")
                if card:
                    llm = card.get("llm") if card_mod.has_llm(card) else None
                    print(f"  ficha: kernel_cause={card.get('kernel_cause')} crates={','.join(card.get('crates') or []) or '-'}"
                          + (f" est_diff_lines={llm['est_diff_lines']}" if llm else ""))
                return 0 if keep else 1
        print(f"next-issue: el issue #{number} no esta abierto", file=sys.stderr)
        return 2

    dropped = []
    kept = []
    for issue in all_issues:
        keep, reason = evaluate(issue, idx, me, exclude)
        if keep:
            kept.append((issue, reason))
        else:
            dropped.append((issue, reason))

    # The best first; the newest breaks the ties. The cards (the cached ones
    # always, the new ones only for the first `top` candidates) can drop a
    # candidate and change its score.
    ranked = sorted(kept, key=lambda k: (-score(k[0])[0], -k[0]["number"]))
    chosen = []
    for pos, (issue, reason) in enumerate(ranked):
        # Normal mode: the first `top` are weighed with their cards; past
        # them, the first survivor is enough.
        if not list_mode and chosen and pos >= top:
            break
        card = card_for(issue, idx, me, build and pos < top, budget)
        why = card_mod.drop_reason(card)
        if why:
            dropped.append((issue, why))
            continue
        chosen.append((issue, reason, score(issue, card)))
    chosen.sort(key=lambda c: (-c[2][0], -c[0]["number"]))

    if list_mode:
        for issue, reason in sorted(dropped, key=lambda d: -d[0]["number"]):
            print(f"#{issue['number']:<6} {'SE DEJA':<8} {reason[:70]}")
        for issue, reason, (points, parts) in chosen:
            print(f"#{issue['number']:<6} {'SE TOMA':<8} score={points:<3} {parts[:60]:<60} {issue['title'][:50]}")
        return 0
    if not chosen:
        print("next-issue: no hay ningun issue libre que valga un agente ahora", file=sys.stderr)
        return 1
    issue, reason, (points, parts) = chosen[0]
    print(issue["number"])
    print(f"next-issue: #{issue['number']} {issue['title']} ({reason}; score={points}: {parts})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
