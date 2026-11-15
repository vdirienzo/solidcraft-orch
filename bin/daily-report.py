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
slots = {}
try:
    state = json.load(open(f"{ORCH}/state.json"))
    slots = state.get("slots") or {}
    for slot, s in slots.items():
        if isinstance(s, dict) and s.get("status") not in ("done", None):
            issue = s.get("issue")
            rol = s.get("role") or slot
            en_marcha.append(f"#{issue} ({rol})" if issue else f"{rol}")
except Exception as e:
    fallos.append(f"state.json: {e}")

vivos = 0
try:
    c = sqlite3.connect(f"file:{HERMES_HOME}/state.db?mode=ro", uri=True)
    # Las subagentes se cierran (ended_at) apenas terminan, y las que viven
    # dentro de un turno aparecen como 'local' o 'cron': se cuentan TODAS las
    # sesiones sin ended_at cuya ultima actividad es reciente.
    import time as _t
    _limite = _t.time() - 900
    vivos = c.execute(
        "select count(*) from sessions where ended_at is null "
        "and (last_activity_at is null or last_activity_at > ?)", (_limite,)).fetchone()[0]
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

# ---------------------------------------------------------------- los issues
issues_abiertos = 0
issues_trabajados = []
try:
    out = sh(f"gh api --paginate 'repos/{REPO}/issues?state=open&per_page=100' "
             f"--jq '.[] | select(.pull_request == null) | .number'")
    issues_abiertos = len([x for x in out.split() if x.strip().isdigit()])
except Exception as e:
    fallos.append(f"issues: {e}")

# los issues que estamos atacando: los slots del orquestador + las ramas vivas
for slot, sl in (slots or {}).items():
    if isinstance(sl, dict) and sl.get("status") == "running":
        n = sl.get("issue")
        if n and str(n).isdigit():
            issues_trabajados.append(str(n))
issues_trabajados = sorted(set(issues_trabajados))

# ---------------------------------------------------------------- los verdicts
verdicts = []
try:
    gates = f"{ORCH}/../solidcraft-loop/gates"
    if not os.path.isdir(gates):
        gates = os.path.expanduser("~/.local/share/solidcraft-loop/gates")
    for d in sorted(os.listdir(gates)) if os.path.isdir(gates) else []:
        f = os.path.join(gates, d, "scope.effective.verdict")
        if not os.path.exists(f):
            continue
        try:
            txt = open(f, errors="replace").read()
        except Exception:
            continue
        v = re.search(r"^VERDICT=(.+)$", txt, re.M)
        n = re.search(r"^NEW_FAILURES=(\d+)$", txt, re.M)
        sha = re.search(r"^SHA=([0-9a-f]{9})", txt, re.M)
        if v:
            verdicts.append((d, v.group(1).strip(), n.group(1) if n else "?", sha.group(1) if sha else "-"))
except Exception as e:
    fallos.append(f"verdicts: {e}")

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
if issues_abiertos:
    L.append(f"Issues abiertos en upstream: {issues_abiertos}.")
if issues_trabajados:
    L.append("Issues que atacamos: " + ", ".join("#" + i for i in issues_trabajados[:10]))
if nuevos_hoy:
    L.append("PRs de hoy: " + ", ".join("#" + str(p["number"]) for p in nuevos_hoy[:10]))
verdes = [v for v in verdicts if v[1] == "VERDE-SCOPE"]
if verdes:
    L.append(f"Gates en verde: {len(verdes)}/{len(verdicts)} slots verificados "
             + ", ".join(f"{d}" for d, _, _, _ in verdes[:8]))
rojos = [v for v in verdicts if v[1] != "VERDE-SCOPE"]
if rojos:
    L.append("Gates con fallos nuevos: " + ", ".join(f"{d} ({n})" for d, _, n, _ in rojos[:6]))
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
