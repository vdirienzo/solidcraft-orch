#!/usr/bin/env python3
"""El estado del loop de SolidCraft, SIN LLM.

Lo mismo que el reporte diario pero para el loop: que slots estan tomados, que
agentes viven, que gates corrieron, que PRs hay. Un cron `no_agent` entrega el
stdout de este script al chat de Telegram sin abrir una sesion de Hermes (un
turno de agente por un estado que se lee de archivos cuesta ~15k de prompt).

La fuente de verdad es el estado en disco, no la memoria de ninguna sesion:
- locks/         -> quien esta trabajando en que slot
- state.json     -> el estado del orquestador
- state.db       -> que subagentes viven de verdad
- reports/       -> los ultimos veredictos de gate

Salida: un resumen corto para el celu.
"""
import json
import os
import shlex
import subprocess
import sqlite3
import datetime
import sys

ORCH_DIR = os.environ.get("ORCH_DIR", os.path.expanduser("~/.local/share/solidcraft-orch"))
HERMES_HOME = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
# The gh binary: the tests point it at a stub OUTSIDE the PATH, so the tests
# never touch GitHub.
GH_BIN = os.environ.get("GH_BIN") or "gh"
LOCKS = f"{ORCH_DIR}/locks"
STATE = f"{ORCH_DIR}/state.json"
# The worktrees of the slots: the cwd of the sessions of the agents of the loop.
WORKTREES = os.environ.get("WORKTREES_DIR", os.path.expanduser("~/solidcraft-wt"))
DB = f"{HERMES_HOME}/state.db"
REPORTS = f"{ORCH_DIR}/reports"
TZ = datetime.timezone(datetime.timedelta(hours=-3))


def now_ar():
    return datetime.datetime.now(TZ)


def sh(cmd, timeout=120):
    """Run a command and return (rc, stdout).

    A command that failed is NOT an empty answer: the caller has to be able
    to say "I do not know" instead of "there is nothing".
    """
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=timeout)
    except Exception:
        return 1, ""
    return p.returncode, p.stdout


def locks():
    """Los locks tomados: el work en vuelo. La edad es la liveness, no el PID."""
    out = []
    try:
        for name in sorted(os.listdir(LOCKS)):
            d = os.path.join(LOCKS, name)
            if not os.path.isdir(d):
                continue
            owner = ""
            since = ""
            try:
                owner = open(os.path.join(d, "owner")).read().strip()
                since = open(os.path.join(d, "since")).read().strip()
            except Exception:
                pass
            age = ""
            if since:
                try:
                    t = datetime.datetime.fromisoformat(since.replace("Z", "+00:00"))
                    age = f"{(now_ar() - t.astimezone(TZ)).total_seconds() / 60:.0f}m"
                except Exception:
                    age = ""
            out.append((name, owner, age))
    except Exception:
        pass
    return out


def agents():
    """Los subagentes vivos: de verdad, leyendo la base.

    A database that can NOT be read is NOT a live agent. Counting the failure
    as one said "Agentes vivos: 1" and hid the branch that says the loop is
    stopped: the report has to say what it does NOT know (D5).

    Returns (agents, error): the error is None when the database was read.
    """
    out = []
    error = None
    try:
        c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
        c.row_factory = sqlite3.Row
        for r in c.execute(
            "select id, source, title, cwd, parent_session_id, last_activity_at "
            "from sessions where ended_at is null and cwd is not null and cwd like ? "
            "order by started_at desc",
            (f"{WORKTREES}/issue-%",),
        ):
            out.append(
                {
                    "id": r["id"],
                    "title": (str(r["title"] or "") or str(r["cwd"] or ""))[:70],
                    "parent": str(r["parent_session_id"] or "")[:12],
                    "age": (now_ar().timestamp() - float(r["last_activity_at"])) / 60.0,
                }
            )
        c.close()
    except Exception as e:
        error = f"{type(e).__name__}: {e}"
    return out, error


def slots():
    """El estado del orquestador: que se esta trabajando y con que resultado."""
    try:
        d = json.load(open(STATE))
    except Exception:
        return []
    slots = d.get("slots", {})
    out = []
    for name, v in slots.items():
        if not isinstance(v, dict):
            continue
        st = str(v.get("status", ""))
        if st in ("running", "paused", "queued", "pending"):
            out.append((name, st, str(v.get("phase", ""))[:110]))
    return out


def gates():
    """Los ultimos veredictos de gate que hay en reports/."""
    out = []
    try:
        files = sorted(
            (f for f in os.listdir(REPORTS) if f.endswith(".md")),
            key=lambda f: os.path.getmtime(os.path.join(REPORTS, f)),
            reverse=True,
        )
        for f in files[:6]:
            path = os.path.join(REPORTS, f)
            ver = ""
            try:
                for line in open(path):
                    if "VERDICT" in line or "VERDE" in line or "ROJO" in line:
                        ver = line.strip()[:110]
                        break
            except Exception:
                pass
            if ver:
                out.append((f.replace(".md", ""), ver))
    except Exception:
        pass
    return out


def prs():
    """Los PRs abiertos del fork, con su estado de CI.

    Returns (rows, error): a failed query is NOT "there are no PRs".
    """
    rc, out = sh(
        f"{shlex.quote(GH_BIN)} pr list --repo tangency-labs/solidcraft --author vdirienzo "
        "--state open --limit 20 --json number,title,mergeable,statusCheckRollup",
        timeout=90,
    )
    if rc != 0:
        return [], f"rc={rc}"
    try:
        data = json.loads(out or "[]")
    except Exception as e:
        return [], f"{type(e).__name__}: {e}"
    rows = []
    for p in data:
        checks = p.get("statusCheckRollup") or []
        state = "?"
        if checks:
            bad = [c for c in checks if str(c.get("conclusion") or "").upper() not in ("SUCCESS", "NEUTRAL", "SKIPPED")]
            state = "VERDE" if not bad else f"ROJO({len(bad)})"
        rows.append((p.get("number"), str(p.get("title", ""))[:52], p.get("mergeable"), state))
    return rows, None


def main():
    ahora = now_ar().strftime("%H:%M")
    ls = locks()
    ag, ag_error = agents()
    sl = slots()
    gt = gates()
    pp, prs_error = prs()

    lineas = []
    lineas.append(f"SolidCraft - estado del loop ({ahora})")

    # 1. Lo que esta trabajando ahora
    #
    # LOS AGENTES DEL LOOP SON LAS SESIONES CON EL WORKTREE COMO CWD
    # (2026-11-19): el agente del loop se lanza con `hermes --in <worktree>`
    # y su sesion queda con ese cwd, pero su `source` NO es 'subagent' (es
    # 'oneshot'), asi que la consulta de antes no lo veia nunca: el estado
    # decia "Agentes vivos: 0 (el loop esta parado)" con un agente
    # compilando en el slot 19523. La sesion abierta no prueba que el proceso
    # siga vivo (una sesion queda abierta para poder reanudarla), asi que la
    # linea dice sesiones, no vida: el que dice si el loop esta parado son los
    # slots del estado.
    running = [s for s in sl if s[1] == "running"]
    if ag_error:
        # The database could NOT be read: the number of live agents is
        # UNKNOWN. It is not 0 and it is not 1 (D5).
        lineas.append("")
        lineas.append(f"Agentes: ? (no se pudo leer la base: {ag_error})")
    elif ag:
        lineas.append("")
        lineas.append(f"Agentes (sesiones abiertas del loop): {len(ag)}")
        for a in ag:
            linea = f"  · {a['title']}"
            if a["age"] >= 1:
                linea += f" (hace {a['age']:.0f}m)"
            lineas.append(linea)
    elif running:
        lineas.append("")
        lineas.append("Agentes: 0 sesiones abiertas (hay slots corriendo)")
    else:
        lineas.append("")
        lineas.append("Agentes: 0 (no hay ninguna sesion abierta del loop)")

    if sl:
        lineas.append("")
        lineas.append("Slots:")
        for name, st, phase in sl:
            lineas.append(f"  · {name} [{st}]")
            if phase:
                lineas.append(f"      {phase}")

    if ls:
        lineas.append("")
        lineas.append("Locks tomados:")
        for name, owner, age in ls:
            linea = f"  · {name}"
            if owner:
                linea += f" (owner {owner})"
            if age:
                linea += f" - {age}"
            lineas.append(linea)

    if gt:
        lineas.append("")
        lineas.append("Ultimos gates:")
        for name, ver in gt:
            lineas.append(f"  · {name}: {ver}")

    if prs_error:
        lineas.append("")
        lineas.append(f"PRs abiertos: ? (no se pudo leer la lista: {prs_error})")
    elif pp:
        lineas.append("")
        lineas.append(f"PRs abiertos: {len(pp)}")
        for num, title, mergeable, state in pp:
            mm = "" if mergeable == "MERGEABLE" else f" [{mergeable}]"
            lineas.append(f"  · #{num}{mm} {state} - {title}")

    if ag_error:
        # Without the database we do not know if the loop is running: saying
        # "it is stopped" would be a guess, and this is read as a verdict.
        lineas.append("")
        lineas.append("No se puede afirmar si el loop esta parado: no se pudo leer la base.")
    elif not ag and not sl:
        lineas.append("")
        lineas.append("Para arrancar el loop: escribile al bot desde Telegram.")
        lineas.append("'activá el orquestador para los fixes de SolidCraft'.")
    elif sl and not ag:
        lineas.append("")
        lineas.append("La wave esta trabajando (los locks son suyos) pero todavia no "
                      "despacho subagentes.")

    print("\n".join(lineas))

    # The verdict reaches the exit code: a report that could not be collected
    # is NOT a clean report (RULES.md).
    if ag_error or prs_error:
        print(f"fallo: {ag_error or prs_error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
