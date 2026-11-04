#!/usr/bin/env python3
"""El reporte diario de SolidCraft, SIN LLM.

El cron de las 10:00 y las 22:00 (Argentina) gastaba ~1.5M de prompt tokens por
corrida: abria una sesion de Hermes, corria 6 comandos, redactaba el reporte a
mano y cada llamada reenviaba el contexto entero. Este script hace TODA la
recoleccion y la redaccion, y escribe el reporte ya listo. El cron solo lo lee
y lo entrega: una llamada, ~15k de prompt.

Salida: reports/latest.md y reports/daily-<fecha>-<hora>.md
"""
import json, os, re, subprocess, sqlite3, datetime, sys

# The paths come from the environment, with the default of THIS machine: the
# other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR = os.environ.get("ORCH_DIR", os.path.expanduser("~/.local/share/solidcraft-orch"))
# The home of Hermes: its state.db says how many agents are alive.
HERMES_HOME = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
ORCH = ORCH_DIR
BIN = f"{ORCH}/bin"
REPORTS = f"{ORCH}/reports"
REPO = "tangency-labs/solidcraft"
AUTH = "vdirienzo"
TZ = "America/Argentina/Buenos_Aires"

os.makedirs(REPORTS, exist_ok=True)
fallos = []


def sh(cmd, timeout=180):
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=timeout)
        return p.stdout if p.returncode == 0 else ""
    except Exception:
        return ""


def now_ar():
    return datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=-3)))


# ---------------------------------------------------------------- los PRs
prs = []
try:
    out = sh(f"gh pr list --repo {REPO} --author {AUTH} --state all --limit 100 "
             f"--json number,state,isDraft,createdAt,title")
    prs = json.loads(out) if out.strip() else []
except Exception as e:
    fallos.append(f"gh pr list fallo: {e}")

abiertos = [p for p in prs if p["state"] == "OPEN"]
mergeados = [p for p in prs if p["state"] == "MERGED"]
cerrados = [p for p in prs if p["state"] == "CLOSED"]
hoy = now_ar().date().isoformat()
nuevos_hoy = [p for p in prs if str(p.get("createdAt", "")).startswith(hoy)]
drafts = [p for p in abiertos if p.get("isDraft")]

# ---------------------------------------------------------------- en marcha
en_marcha = []
try:
    state = json.load(open(f"{ORCH}/state.json"))
    for slot, s in (state.get("slots") or {}).items():
        if isinstance(s, dict) and s.get("status") not in ("done", None):
            issue = s.get("issue")
            rol = s.get("role") or slot
            en_marcha.append(f"#{issue} ({rol})" if issue else f"{rol}")
except Exception as e:
    fallos.append(f"state.json: {e}")

vivos = 0
try:
    c = sqlite3.connect(f"file:{HERMES_HOME}/state.db?mode=ro", uri=True)
    vivos = c.execute(
        "select count(*) from sessions where parent_session_id is not null "
        "and source='subagent' and ended_at is null").fetchone()[0]
except Exception as e:
    fallos.append(f"state.db: {e}")

# ---------------------------------------------------------------- pendientes
pendientes = []
resumen = sh(f"bash {BIN}/orch-state.sh summary")
if resumen:
    lineas = resumen.splitlines()
    i = 0
    while i < len(lineas) and len(pendientes) < 3:
        m = re.match(r"^  \[(.+?)\] (.+)$", lineas[i])
        if m:
            texto = m.group(2)
            if len(texto) > 150:
                texto = texto[:147] + "..."
            pendientes.append(f"[{m.group(1)}] {texto}")
            if i + 2 < len(lineas) and lineas[i + 2].strip().startswith("hacer:"):
                pendientes[-1] += " -> " + lineas[i + 2].strip()[6:].strip()[:70]
        i += 1

# ---------------------------------------------------------------- maquina
load = sh("cut -d' ' -f1-3 /proc/loadavg").strip()
disco = sh("df -h / | tail -1 | awk '{print $4\" libres de \"$2\" (\"$5\")\"}'").strip()
ram = sh("free -m | awk 'NR==2{print $3\"MB de \"$2\"MB en uso\"}'").strip()

# ---------------------------------------------------------------- el reporte
ts = now_ar()
titulo = f"Reporte SolidCraft - {ts.strftime('%d-%m %H:%M')}"
L = [f"**{titulo}**", ""]
L.append(f"PRs: {len(abiertos)} abiertos ({len(drafts)} draft), {len(mergeados)} mergeados, "
         f"{len(cerrados)} cerrados sin merge, {len(nuevos_hoy)} creados hoy.")
if en_marcha:
    L.append("En marcha: " + ", ".join(en_marcha[:8]) +
             (f" (+{len(en_marcha)-8})" if len(en_marcha) > 8 else ""))
else:
    L.append("En marcha: nada.")
L.append(f"Agentes vivos: {vivos}. Maquina: load {load}, disco {disco}, RAM {ram}.")
if pendientes:
    L.append("Pendientes:")
    for p in pendientes:
        L.append("  - " + p)
if fallos:
    L.append("Fallos: " + "; ".join(fallos)[:200])
if not nuevos_hoy and not en_marcha and not pendientes:
    L = [f"**{titulo}**", "", "Sin nada nuevo: ningun PR nuevo, ningun pendiente."]

texto = "\n".join(L)
archivo = f"{REPORTS}/daily-{ts.strftime('%Y-%m-%d-%H%M')}.md"
open(archivo, "w").write(texto + "\n")
open(f"{REPORTS}/latest.md", "w").write(texto + "\n")
print(texto)
