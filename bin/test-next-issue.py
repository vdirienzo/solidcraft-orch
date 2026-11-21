#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# test-next-issue.py - the selector picks the right issue, and drops the rest.
#
# WHAT IT TESTS: the filters of docs/issue-selection.md, in order, on a
# fixture of issues that has one of every case:
#   - an issue with the 'kernel-paused' label      -> dropped (veto)
#   - an issue with an open PR of another author    -> dropped (the claim)
#   - an issue the triage says is dead             -> dropped (dead)
#   - an issue with no reproduction at all          -> dropped (no cause)
#   - an issue that needs hardware                 -> dropped (not headless)
#   - a free issue with a script and a cause       -> KEPT
#   - (2026-11-21) Drawings (rama drawings), a feature request, a title with
#     several topics, a platform bug without a released build's version and
#     log (upstream repro-first)                   -> dropped
#   - --exclude: the issues the wave already tried are not returned again
#   - (2026-11-21) the PHOTO (bin/gh_snapshot.py) is the source: every open
#     issue, not 150; the claim comes from the PRs of the photo (ours does not
#     count as free); the kept ones come out BEST FIRST by their score, not
#     newest first; the cards (bin/issue-card.py) drop what they say, and
#     NEXT_ISSUE_TRIAGE=1 builds them with a bounded number of model calls
#
# IT NEVER TOUCHES GITHUB: the photo is a fixture in a temporary ORCH_DIR and
# the gh of GH_BIN is a stub that fails and writes down every call.
#
# Run: python3 bin/test-next-issue.py
# ---------------------------------------------------------------------------
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
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


def issue(number, title, labels=(), comments=(), body="", assignees=()):
    return {
        "number": number,
        "title": title,
        "body": body,
        "labels": [{"name": n} for n in labels],
        "comments": [{"body": c} for c in comments],
        "assignees": [{"login": a} for a in assignees],
        "createdAt": "2026-11-01T00:00:00Z",
    }


SCRIPT = "solidcraft-cli run repro.json --results"
ISSUES = [
    issue(1, "el kernel esta pausado", labels=["kernel-paused"], body=SCRIPT),
    issue(2, "otro PR lo tiene", body=SCRIPT),
    issue(3, "el triage lo da por muerto", comments=["Could not be reproduced on main."], body=SCRIPT),
    issue(4, "sin repro", body="me pasa a veces"),
    issue(5, "necesita hardware", body=SCRIPT + " (solo en android)"),
    issue(6, "libre y con causa", body=SCRIPT),
    issue(7, "[RFC] algo nuevo", body=SCRIPT),
    issue(8, "tiene asignado", body=SCRIPT, assignees=["alguien"]),
    # The STEP reader is `crates/kernel/src/step_in/` and the kernel is PAUSED:
    # an issue about the format is dropped even when the label does not say so.
    issue(9, "STEP import: a half-sphere end cap is read inside out", body=SCRIPT),
    # The kernel's own operations are parked too, and the upstream labels most
    # of them `area:sketch`: the subject is what parks them.
    issue(10, "Spline Boolean: a pocket returns two small cylinders", body=SCRIPT),
    # A lowercase "step" is a geometry step (the wall of a step), not the
    # format: this one is kept.
    issue(0, "Sketch: the corner lookup refuses a clip at a step wall's edge", body=SCRIPT),
    # 2026-11-21: lo que la lista del 21-11 tomaba y no valia un agente.
    # Los planos se trabajan en la rama `drawings` del upstream, no en main.
    issue(11, "Drawings: the view label is clipped at the sheet border", body=SCRIPT),
    issue(18, "el planito", labels=["area:drawings"], body=SCRIPT),
    issue(19, "Drawing sheets: let plugins draw geometry in a sheet sketch", body=SCRIPT),
    # Una feature no es un bug: por el titulo y por la etiqueta.
    issue(12, "Integrate the 3D sketching tools into the sketch workspace", body=SCRIPT),
    issue(13, "Sketch: allow a slot by three points", labels=["enhancement"], body=SCRIPT),
    # Varios temas en un titulo.
    issue(14, "Issues in v45 compared to v40 rc3", body=SCRIPT),
    # Repro-first: plataforma sin la version y el log de un build publicado.
    issue(15, "Wayland: the window does not open", body=SCRIPT),
    # La misma plataforma CON version y log: se toma.
    issue(16, "Wayland: the window does not open", body=SCRIPT + "\nSolidCraft v45.1 (release)\n```\nerror: no surface\n```"),
    # "window" en singular es una ventana de la UI, no el sistema operativo.
    issue(17, "Sketch: the dimension window shows the wrong command name", body=SCRIPT),
]


def write_snapshot(path, issues, prs, age_min=1.0):
    now = time.time() - age_min * 60
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"version": 1, "complete": True, "repo": "tangency-labs/solidcraft", "mode": "full",
                   "generated_epoch": now, "started_epoch": now, "full_epoch": now,
                   "issues": issues, "prs": prs}, fh)


def iso_days_ago(days):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - days * 86400))


def main():
    tmp = tempfile.mkdtemp(prefix="test-next-issue.")
    orch = os.path.join(tmp, "orch")
    # The PR of another author that claims #2 (in the title and the body).
    prs = [
        {
            "number": 4242,
            "title": "otro (#2)",
            "body": "Fixes #2",
            "author": {"login": "otro"},
            "headRefName": "fix-2",
            "isDraft": True,
        }
    ]
    write_snapshot(os.path.join(orch, "state", "cache", "gh-snapshot.json"), ISSUES, prs)
    # The gh of the tests: it FAILS and writes down the call. With a fresh
    # photo nobody has to call it.
    gh_log = os.path.join(tmp, "gh.log")
    stub = os.path.join(tmp, "gh")
    with open(stub, "w", encoding="utf-8") as fh:
        fh.write(f"#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> {gh_log!r}\nexit 1\n")
    os.chmod(stub, 0o755)
    env = dict(os.environ)
    for k in ("GH_SNAPSHOT", "NEXT_ISSUE_TRIAGE", "FORK_OWNER", "GH_SNAPSHOT_MAX_AGE_MIN"):
        env.pop(k, None)
    env["ORCH_DIR"] = orch
    env["GH_BIN"] = stub
    env["UPSTREAM_REPO"] = "tangency-labs/solidcraft"
    env["LOOP_DIR"] = os.path.join(tmp, "loop")
    env["SOLIDCRAFT_REPO"] = os.path.join(tmp, "no-checkout")
    env["TRIAGE_MODEL"] = "stub/model"

    def run(*args, extra=None):
        return subprocess.run(
            [sys.executable, os.path.join(HERE, "next-issue.py"), *args],
            capture_output=True,
            text=True,
            env=dict(env, **(extra or {})),
            timeout=300,
        )

    done = run("--list")
    listing = done.stdout
    for number, reason in (
        (1, "el kernel esta pausado"),
        (2, "otro PR lo tiene"),
        (3, "el triage lo da por muerto"),
        (4, "sin repro"),
        (5, "necesita hardware"),
        (7, "es un RFC"),
        (8, "tiene asignado"),
        (9, "el STEP esta en el codigo aparcado"),
        (10, "el Boolean es una operacion del kernel aparcado"),
        (11, "Drawings va en la rama drawings, no en main (titulo)"),
        (18, "Drawings va en la rama drawings, no en main (etiqueta)"),
        (19, "Drawing sheets tambien es de planos"),
        (12, "una feature por el titulo (Integrate)"),
        (13, "una feature por la etiqueta enhancement"),
        (14, "varios temas en un titulo (Issues in)"),
        (15, "repro-first: plataforma sin version ni log"),
    ):
        line = [l for l in listing.splitlines() if l.startswith(f"#{number} ")]
        if line and "SE DEJA" in line[0]:
            ok(f"#{number} se deja ({reason})")
        else:
            no(f"#{number} se deja ({reason})", line[0] if line else "no esta en la lista")
    line = [l for l in listing.splitlines() if l.startswith("#6 ")]
    if line and "SE TOMA" in line[0]:
        ok("#6 se toma (libre, con causa y verificable headless)")
    else:
        no("#6 se toma (libre, con causa y verificable headless)", line[0] if line else "no esta en la lista")

    line = [l for l in listing.splitlines() if l.startswith("#0 ")]
    if line and "SE TOMA" in line[0]:
        ok("#0 se toma (un 'step' en minusculas es la geometria, no el formato)")
    else:
        no("#0 se toma (un 'step' en minusculas es la geometria, no el formato)", line[0] if line else "no esta en la lista")

    for number, reason in (
        (16, "repro-first: plataforma CON version y log"),
        (17, "'window' en singular no es el sistema operativo"),
    ):
        line = [l for l in listing.splitlines() if l.startswith(f"#{number} ")]
        if line and "SE TOMA" in line[0]:
            ok(f"#{number} se toma ({reason})")
        else:
            no(f"#{number} se toma ({reason})", line[0] if line else "no esta en la lista")

    # EL MEJOR, NO EL MAS NUEVO (2026-11-21): este caso decia "17" (el mas
    # nuevo de los que se toman). Ahora los que se toman salen por puntaje, y
    # el #16 cita un texto de error ("error: no surface") que los otros no
    # citan: error+2. Entre 17, 6 y 0 (el mismo puntaje) desempata el mas nuevo.
    done = run()
    if done.returncode == 0 and done.stdout.strip() == "16":
        ok("el modo normal imprime el issue que se toma (el de mejor puntaje)")
    else:
        no("el modo normal imprime el issue que se toma (el de mejor puntaje)", f"rc={done.returncode} out={done.stdout!r}")

    # --exclude (2026-11-21): la wave le pasa los que ya probo en el turno, y
    # el selector NO le devuelve el mismo (el bucle sin fin de la wave).
    done = run("--exclude", "17,16")
    if done.returncode == 0 and done.stdout.strip() == "6":
        ok("--exclude N,M salta los que la wave ya probo")
    else:
        no("--exclude N,M salta los que la wave ya probo", f"rc={done.returncode} out={done.stdout!r}")
    done = run("--exclude=17", "--exclude", "16,6")
    if done.returncode == 0 and done.stdout.strip() == "0":
        ok("--exclude se puede repetir y acepta la forma --exclude=N")
    else:
        no("--exclude se puede repetir y acepta la forma --exclude=N", f"rc={done.returncode} out={done.stdout!r}")
    done = run("--exclude", "")
    if done.returncode == 0 and done.stdout.strip() == "16":
        ok("--exclude vacio no excluye nada")
    else:
        no("--exclude vacio no excluye nada", f"rc={done.returncode} out={done.stdout!r}")
    done = run("--exclude", "17,16,6,0")
    if done.returncode == 1 and not done.stdout.strip():
        ok("con todos excluidos no hay issue (rc=1)")
    else:
        no("con todos excluidos no hay issue (rc=1)", f"rc={done.returncode} out={done.stdout!r}")
    done = run("--list", "--exclude", "17")
    line = [l for l in done.stdout.splitlines() if l.startswith("#17 ")]
    if line and "SE DEJA" in line[0] and "exclude" in line[0]:
        ok("--list con --exclude dice que el issue se deja por la wave")
    else:
        no("--list con --exclude dice que el issue se deja por la wave", line[0] if line else done.stdout[-300:])

    done = run("--explain", "6")
    if done.returncode == 0 and "SE TOMA" in done.stdout:
        ok("--explain dice por que se toma")
    else:
        no("--explain dice por que se toma", f"rc={done.returncode} out={done.stdout!r}")

    done = run("--explain", "2")
    if done.returncode == 1 and "SE DEJA" in done.stdout:
        ok("--explain dice por que se deja")
    else:
        no("--explain dice por que se deja", f"rc={done.returncode} out={done.stdout!r}")

    if not os.path.exists(gh_log):
        ok("con la foto fresca nadie le pregunto nada a GitHub")
    else:
        no("con la foto fresca nadie le pregunto nada a GitHub", open(gh_log).read()[:200])

    more(tmp, orch, run, gh_log)
    print(f"\n{PASS + FAIL} casos, {FAIL} fallan")
    return 1 if FAIL else 0


GOOD = SCRIPT + "\nSteps to reproduce: run it.\n```\nerror: the radius must be positive\n```"


def more(tmp, orch, run, gh_log):
    """2026-11-21: the photo, the ranking, the claim, the cards."""
    # --- every open issue, not 150 -----------------------------------------
    # 300 issues that the filters drop, and the only good one is the OLDEST:
    # the 150 newest of the old `gh issue list --limit 150` never saw it.
    filler = [issue(1000 + n, f"relleno {n}", labels=["area:kernel"], body=SCRIPT) for n in range(300)]
    old_good = issue(500, "Sketch: the trim leaves a dangling point", body=GOOD)
    snap = os.path.join(tmp, "snap-many.json")
    write_snapshot(snap, filler + [old_good], [])
    done = run("--snapshot", snap)
    if done.returncode == 0 and done.stdout.strip() == "500":
        ok("la foto tiene TODOS los issues abiertos: el bueno es el 301 mas nuevo y se toma")
    else:
        no("la foto tiene TODOS los issues abiertos", f"rc={done.returncode} out={done.stdout!r} {done.stderr[-200:]}")

    # --- the ranking ----------------------------------------------------------
    fresh = iso_days_ago(2)
    rank = [
        dict(issue(700, "Sketch: plain report, newest", body=SCRIPT), createdAt=fresh),
        dict(issue(600, "Sketch: a bug in the UI with its error", labels=["bug", "area:ui"], body=GOOD), createdAt=fresh),
        dict(issue(650, "Sketch: a long discussion", labels=["bug"], body=GOOD,
                   comments=[f"comentario {n}" for n in range(12)]), createdAt=iso_days_ago(200)),
    ]
    snap = os.path.join(tmp, "snap-rank.json")
    write_snapshot(snap, rank, [])
    done = run("--snapshot", snap)
    if done.returncode == 0 and done.stdout.strip() == "600":
        ok("gana el de mejor puntaje (bug, area:ui, repro, error, reciente), no el mas nuevo")
    else:
        no("gana el de mejor puntaje, no el mas nuevo", f"rc={done.returncode} out={done.stdout!r}")
    done = run("--snapshot", snap, "--list")
    toma = [l for l in done.stdout.splitlines() if "SE TOMA" in l]
    if [l.split()[0] for l in toma] == ["#600", "#650", "#700"] and "score=" in toma[0] and "bug+3" in toma[0]:
        ok("--list muestra el puntaje y el orden, el mejor primero")
    else:
        no("--list muestra el puntaje y el orden, el mejor primero", " | ".join(toma))

    # --- the claim, from the PRs of the photo --------------------------------
    claimed = [issue(801, "Sketch: ours already", body=GOOD), issue(802, "Sketch: in a code block", body=GOOD),
               issue(803, "Sketch: free one", body=SCRIPT)]
    prs = [
        {"number": 9001, "title": "Sketch fix (#801)", "body": "", "author": {"login": "vdirienzo"}},
        {"number": 9002, "title": "Other", "body": "```\nFixes #802\n```", "author": {"login": "rival"}},
    ]
    snap = os.path.join(tmp, "snap-claim.json")
    write_snapshot(snap, claimed, prs)
    done = run("--snapshot", snap, "--list")
    lines = {l.split()[0]: l for l in done.stdout.splitlines() if l.startswith("#")}
    if "SE DEJA" in lines.get("#801", "") and "ya es nuestro" in lines.get("#801", ""):
        ok("un issue con NUESTRO PR abierto no es libre para un slot nuevo")
    else:
        no("un issue con NUESTRO PR abierto no es libre para un slot nuevo", lines.get("#801", "(no esta)"))
    if "SE DEJA" in lines.get("#802", "") and "#9002" in lines.get("#802", ""):
        ok("un 'Fixes #N' en un bloque de codigo de un rival lo ocupa (claim.js)")
    else:
        no("un 'Fixes #N' en un bloque de codigo de un rival lo ocupa (claim.js)", lines.get("#802", "(no esta)"))

    # --- the cards --------------------------------------------------------------
    cards = os.path.join(orch, "state", "cards")
    os.makedirs(cards, exist_ok=True)

    def card(n, kernel=False, llm=None):
        with open(os.path.join(cards, f"{n}.json"), "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "issue": n, "kernel_cause": kernel, "crates": ["kernel"] if kernel else [],
                       "llm": llm}, fh)

    good_llm = {"one_topic": True, "bug_with_repro": True, "maintainer_decided": False,
                "crash_without_replay": False, "platform_specific": False, "est_diff_lines": 40, "reason": "small"}
    pool = [issue(n, f"Sketch: candidate {n}", body=GOOD) for n in (901, 902, 903, 904, 905)]
    snap = os.path.join(tmp, "snap-cards.json")
    write_snapshot(snap, pool, [])
    card(905, kernel=True)
    card(904, llm=dict(good_llm, one_topic=False))
    card(903, llm=dict(good_llm, est_diff_lines=400))
    card(902, llm=dict(good_llm, maintainer_decided=True))
    card(901, llm=good_llm)
    done = run("--snapshot", snap, "--list")
    lines = {l.split()[0]: l for l in done.stdout.splitlines() if l.startswith("#")}
    for n, why in ((905, "codigo aparcado"), (904, "varios temas"), (903, "400 lineas"), (902, "maintainer")):
        if "SE DEJA" in lines.get(f"#{n}", "") and why in lines.get(f"#{n}", ""):
            ok(f"la ficha deja el #{n} ({why})")
        else:
            no(f"la ficha deja el #{n} ({why})", lines.get(f"#{n}", "(no esta)"))
    if "SE TOMA" in lines.get("#901", "") and "diff-chico+2" in lines.get("#901", ""):
        ok("la ficha con un diff chico suma al puntaje (diff-chico+2)")
    else:
        no("la ficha con un diff chico suma al puntaje", lines.get("#901", "(no esta)"))
    done = run("--snapshot", snap)
    if done.returncode == 0 and done.stdout.strip() == "901":
        ok("el modo normal salta los que la ficha deja")
    else:
        no("el modo normal salta los que la ficha deja", f"rc={done.returncode} out={done.stdout!r}")

    # --- NEXT_ISSUE_TRIAGE=1: the cards that are missing, with a budget -------
    oc_log = os.path.join(tmp, "opencode.log")
    oc = os.path.join(tmp, "opencode")
    answer = json.dumps(dict(good_llm, one_topic=False, reason="two bugs"))
    with open(oc, "w", encoding="utf-8") as fh:
        fh.write("#!/usr/bin/env bash\n"
                 f"echo call >> {oc_log!r}\n"
                 "echo '{\"type\":\"step_start\",\"part\":{}}'\n"
                 f"printf '%s\\n' {json.dumps(json.dumps({'type': 'text', 'part': {'id': 'p1', 'text': answer}}))}\n"
                 "echo '{\"type\":\"step_finish\",\"part\":{\"cost\":0.001,\"tokens\":{\"input\":10,\"output\":5}}}'\n")
    os.chmod(oc, 0o755)
    pool = [issue(n, f"Sketch: triage {n}", body=GOOD) for n in range(1101, 1109)]
    snap = os.path.join(tmp, "snap-triage.json")
    write_snapshot(snap, pool, [])
    extra = {"NEXT_ISSUE_TRIAGE": "1", "OPENCODE_BIN": oc, "NEXT_ISSUE_TRIAGE_MAX": "3", "NEXT_ISSUE_TRIAGE_TOP": "5"}
    done = run("--snapshot", snap, extra=extra)
    calls = len(open(oc_log).read().split()) if os.path.exists(oc_log) else 0
    built = sorted(int(f[:-5]) for f in os.listdir(cards) if f[:-5].isdigit() and int(f[:-5]) > 1100)
    if calls == 3 and built == [1104, 1105, 1106, 1107, 1108]:
        ok("NEXT_ISSUE_TRIAGE=1 arma las fichas de los 5 primeros y llama al modelo a lo sumo 3 veces")
    else:
        no("NEXT_ISSUE_TRIAGE=1 arma las fichas de los 5 primeros, con tope de llamadas",
           f"llamadas={calls} fichas={built} {done.stderr[-300:]}")
    if done.returncode == 0 and done.stdout.strip() == "1105":
        ok("las fichas del modelo dejan a los de varios temas y se toma el siguiente")
    else:
        no("las fichas del modelo dejan a los de varios temas y se toma el siguiente", f"rc={done.returncode} out={done.stdout!r}")
    done = run("--snapshot", snap, extra=extra)
    calls2 = len(open(oc_log).read().split())
    if calls2 == calls:
        ok("la segunda llamada de la misma wave no pasa el tope (las fichas quedan, el modelo no se llama)")
    else:
        no("la segunda llamada de la misma wave no pasa el tope", f"llamadas={calls2}")

    # --- GitHub cannot be read, and there is no fresh photo ---------------------
    stale = os.path.join(tmp, "snap-stale.json")
    write_snapshot(stale, ISSUES, [], age_min=120)
    done = run("--snapshot", stale, "--max-age-min", "15")
    if done.returncode == 2 and os.path.exists(gh_log):
        ok("una foto vieja y GitHub que no responde: rc=2 (no se elige a ciegas)")
    else:
        no("una foto vieja y GitHub que no responde: rc=2", f"rc={done.returncode} {done.stderr[-200:]}")


if __name__ == "__main__":
    sys.exit(main())
