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
import subprocess
import sqlite3
import datetime

ORCH_DIR = os.environ.get("ORCH_DIR", os.path.expanduser("~/.local/share/solidcraft-orch"))
HERMES_HOME = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
LOCKS = f"{ORCH_DIR}/locks"
STATE = f"{ORCH_DIR}/state.json"
DB = f"{HERMES_HOME}/state.db"
REPORTS = f"{ORCH_DIR}/reports"
TZ = datetime.timezone(datetime.timedelta(hours=-3))


def now_ar():
    return datetime.datetime.now(TZ)


def sh(cmd, timeout=120):
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=timeout)
        return p.stdout if p.returncode == 0 else ""
    except Exception:
        return ""


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
    """Los subagentes vivos: de verdad, leyendo la base."""
    out = []
    try:
        c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
        c.row_factory = sqlite3.Row
        for r in c.execute(
            "select id, title, parent_session_id, last_activity_at "
            "from sessions where source='subagent' and ended_at is null order by started_at desc"
        ):
            out.append(
                {
                    "id": r["id"],
                    "title": str(r["title"] or "")[:70],
                    "parent": str(r["parent_session_id"] or "")[:12],
                    "age": (now_ar().timestamp() - float(r["last_activity_at"])) / 60.0,
                }
            )
        c.close()
    except Exception as e:
        out.append({"id": "?", "title": f"no se pudo leer la base: {e}", "parent": "", "age": 0})
    return out


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
    """Los PRs abiertos del fork, con su estado de CI."""
    out = sh(
        "gh pr list --repo tangency-labs/solidcraft --author vdirienzo "
        "--state open --limit 20 --json number,title,mergeable,statusCheckRollup 2>/dev/null",
        timeout=90,
    )
    try:
        data = json.loads(out or "[]")
    except Exception:
        return []
    rows = []
    for p in data:
        checks = p.get("statusCheckRollup") or []
        state = "?"
        if checks:
            bad = [c for c in checks if str(c.get("conclusion") or "").upper() not in ("SUCCESS", "NEUTRAL", "SKIPPED")]
            state = "VERDE" if not bad else f"ROJO({len(bad)})"
        rows.append((p.get("number"), str(p.get("title", ""))[:52], p.get("mergeable"), state))
    return rows


def main():
    ahora = now_ar().strftime("%H:%M")
    ls = locks()
    ag = agents()
    sl = slots()
    gt = gates()
    pp = prs()

    lineas = []
    lineas.append(f"SolidCraft - estado del loop ({ahora})")

    # 1. Lo que esta trabajando ahora
    if ag:
        lineas.append("")
        lineas.append(f"Agentes vivos: {len(ag)}")
        for a in ag:
            linea = f"  · {a['title']}"
            if a["age"] >= 1:
                linea += f" (hace {a['age']:.0f}m)"
            lineas.append(linea)
    else:
        lineas.append("")
        lineas.append("Agentes vivos: 0 (el loop esta parado)")

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

    if pp:
        lineas.append("")
        lineas.append(f"PRs abiertos: {len(pp)}")
        for num, title, mergeable, state in pp:
            mm = "" if mergeable == "MERGEABLE" else f" [{mergeable}]"
            lineas.append(f"  · #{num}{mm} {state} - {title}")

    if not ag and not sl:
        lineas.append("")
        lineas.append("Para arrancar el loop: escribile al bot desde Telegram.")
        lineas.append("'activá el orquestador para los fixes de SolidCraft'.")
    elif sl and not ag:
        lineas.append("")
        lineas.append("La wave esta trabajando (los locks son suyos) pero todavia no "
                      "despacho subagentes.")

    print("\n".join(lineas))


if __name__ == "__main__":
    main()
