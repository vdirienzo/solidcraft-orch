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
#
# IT NEVER TOUCHES GITHUB: the gh of the PATH is a stub that reads the fixture.
#
# Run: python3 bin/test-next-issue.py
# ---------------------------------------------------------------------------
import json
import os
import subprocess
import sys
import tempfile

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


def main():
    tmp = tempfile.mkdtemp(prefix="test-next-issue.")
    # El gh de mentira: la lista de issues, y un PR abierto que menciona el #2.
    issues_json = json.dumps(ISSUES)
    prs_json = json.dumps(
        [
            {
                "number": 4242,
                "title": "otro (#2)",
                "body": "Fixes #2",
                "author": {"login": "otro"},
                "headRefName": "fix-2",
                "isDraft": True,
            }
        ]
    )
    issues_file = os.path.join(tmp, "issues.json")
    prs_file = os.path.join(tmp, "prs.json")
    with open(issues_file, "w", encoding="utf-8") as fh:
        fh.write(issues_json)
    with open(prs_file, "w", encoding="utf-8") as fh:
        fh.write(prs_json)
    # El gh de mentira: el listado de issues, y el de PRs FILTRADO por el
    # numero del issue (el gh de verdad aplica el filtro --jq; este lo hace
    # con la misma idea: el issue esta en el texto del filtro).
    issues_file = os.path.join(tmp, "issues.json")
    prs_file = os.path.join(tmp, "prs.json")
    with open(issues_file, "w", encoding="utf-8") as fh:
        fh.write(issues_json)
    with open(prs_file, "w", encoding="utf-8") as fh:
        fh.write(prs_json)
    stub = os.path.join(tmp, "gh")
    with open(stub, "w", encoding="utf-8") as fh:
        fh.write(
            "#!/usr/bin/env python3\n"
            "import json, os, re, sys\n"
            "args = sys.argv[1:]\n"
            f"issues = open({issues_file!r}, encoding='utf-8').read()\n"
            f"prs = json.load(open({prs_file!r}, encoding='utf-8'))\n"
            "if args[:1] == ['api'] and args[1:2] == ['user']:\n"
            "    print('vdirienzo')\n"
            "    raise SystemExit(0)\n"
            "if args[:2] == ['issue', 'list']:\n"
            "    print(issues)\n"
            "    raise SystemExit(0)\n"
            "if args[:2] == ['pr', 'list']:\n"
            "    joined = ' '.join(args)\n"
            "    numbers = set(re.findall(r'#(\\d+)', joined))\n"
            "    if numbers:\n"
            "        wanted = {n for n in numbers}\n"
            "        keep = [p for p in prs if any(('#' + n) in (p.get('body') or '') or ('(#' + n + ')') in (p.get('title') or '') for n in wanted)]\n"
            "        print(json.dumps(keep) if keep else '')\n"
            "    else:\n"
            "        print(json.dumps(prs))\n"
            "    raise SystemExit(0)\n"
            "print('[]')\n"
        )
    os.chmod(stub, 0o755)
    env = dict(os.environ)
    env["PATH"] = tmp + os.pathsep + env.get("PATH", "")
    env["UPSTREAM_REPO"] = "vdirienzo/solidcraft"

    def run(*args):
        return subprocess.run(
            [sys.executable, os.path.join(HERE, "next-issue.py"), *args],
            capture_output=True,
            text=True,
            env=env,
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

    done = run()
    if done.returncode == 0 and done.stdout.strip() == "17":
        ok("el modo normal imprime el issue que se toma (el mas nuevo)")
    else:
        no("el modo normal imprime el issue que se toma (el mas nuevo)", f"rc={done.returncode} out={done.stdout!r}")

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
    if done.returncode == 0 and done.stdout.strip() == "17":
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

    print(f"\n{PASS + FAIL} casos, {FAIL} fallan")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
