#!/usr/bin/env python3
"""El reporte diario de SolidCraft, SIN LLM.

El cron de las 10:00 y las 22:00 (Argentina) gastaba ~1.5M de prompt tokens por
corrida: abria una sesion de Hermes, corria 6 comandos, redactaba el reporte a
mano y cada llamada reenviaba el contexto entero. Este script hace TODA la
recoleccion y la redaccion, y escribe el reporte ya listo. El cron solo lo lee
y lo entrega: una llamada, ~15k de prompt.

Salida: reports/latest.md y reports/daily-<fecha>-<hora>.md

EL VEREDICTO LLEGA AL EXIT CODE (RULES.md): if something could not be collected,
the report says "?" (never a 0 that lies) and the script exits with rc=1. A
swallowed error is worse than no try/except at all.
"""
import json, os, re, shlex, subprocess, sqlite3, datetime, sys

# The paths come from the environment, with the default of THIS machine: the
# other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR = os.environ.get("ORCH_DIR", os.path.expanduser("~/.local/share/solidcraft-orch"))
# The gates of the loop live in the LOOP's directory, not next to the
# orchestrator's: the report used to read a hardcoded path and the second PC
# read the wrong directory (it always said "0 gates").
LOOP_DIR = os.environ.get("LOOP_DIR", os.path.expanduser("~/.local/share/solidcraft-loop"))
# The home of Hermes: its state.db says how many agents are alive.
HERMES_HOME = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
# The gh binary: the tests point it at a stub OUTSIDE the PATH, so the tests
# never touch GitHub.
GH_BIN = os.environ.get("GH_BIN") or "gh"
ORCH = ORCH_DIR
BIN = f"{ORCH}/bin"
REPORTS = f"{ORCH}/reports"
GATES = f"{LOOP_DIR}/gates"
REPO = "tangency-labs/solidcraft"
AUTH = "vdirienzo"
TZ = "America/Argentina/Buenos_Aires"

try:
    os.makedirs(REPORTS, exist_ok=True)
except Exception as e:
    print(f"daily-report: no se pudo crear {REPORTS}: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(1)

# Every failure is recorded WITH WHAT FAILED: a swallowed exception is worse
# than no exception at all.
fallos = []


def sh(cmd, label, timeout=180):
    """Run a command and return (rc, stdout).

    A command that fails is a failure of the REPORT, not a zero: the number it
    was supposed to produce is UNKNOWN, and the report says "?" instead of
    lying with a 0. The output is returned even when the command failed: a
    command that printed what it could and then failed is still worth reading.
    """
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        fallos.append(f"{label}: {type(e).__name__}: {e}")
        return 1, ""
    if p.returncode != 0:
        err = (p.stderr or "").strip().replace("\n", " ")[:120]
        fallos.append(f"{label}: rc={p.returncode}" + (f": {err}" if err else ""))
    return p.returncode, p.stdout


def now_ar():
    return datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=-3)))


def escribir_atomico(ruta, texto):
    """The cron delivers this file: a crash in the middle of an in-place write
    would leave a TRUNCATED latest.md, and the cron would deliver it."""
    tmp = ruta + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(texto)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, ruta)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise


# ---------------------------------------------------------------- los PRs
prs = []
prs_ok = True
rc, out = sh(f"{shlex.quote(GH_BIN)} pr list --repo {REPO} --author {AUTH} --state all "
             f"--limit 100 --json number,state,isDraft,createdAt,title", "gh pr list")
if rc != 0:
    prs_ok = False
else:
    try:
        prs = json.loads(out) if out.strip() else []
        if not isinstance(prs, list):
            raise ValueError(f"la lista de PRs no es una lista: {type(prs).__name__}")
    except Exception as e:
        prs_ok = False
        fallos.append(f"gh pr list: la respuesta no es una lista de PRs: {type(e).__name__}: {e}")

abiertos = [p for p in prs if p.get("state") == "OPEN"]
mergeados = [p for p in prs if p.get("state") == "MERGED"]
cerrados = [p for p in prs if p.get("state") == "CLOSED"]
hoy = now_ar().date().isoformat()
nuevos_hoy = [p for p in prs if str(p.get("createdAt", "")).startswith(hoy)]
drafts = [p for p in abiertos if p.get("isDraft")]

# ---------------------------------------------------------------- en marcha
en_marcha = []
slots = {}
state_ok = True
try:
    with open(f"{ORCH}/state.json", encoding="utf-8") as fh:
        state = json.load(fh)
    slots = state.get("slots") or {}
    for slot, s in slots.items():
        if isinstance(s, dict) and s.get("status") not in ("done", None):
            issue = s.get("issue")
            rol = s.get("role") or slot
            en_marcha.append(f"#{issue} ({rol})" if issue else f"{rol}")
except Exception as e:
    state_ok = False
    fallos.append(f"state.json: {type(e).__name__}: {e}")

# ---------------------------------------------------------------- agentes vivos
vivos = 0
vivos_ok = True
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
    c.close()
except Exception as e:
    vivos_ok = False
    fallos.append(f"state.db: {type(e).__name__}: {e}")

# ---------------------------------------------------------------- pendientes
pendientes = []
resumen_ok = True
rc, resumen = sh(f"ORCH_DIR={shlex.quote(ORCH)} bash {shlex.quote(BIN + '/orch-state.sh')} summary",
                 "orch-state.sh summary")
# A summary that printed something is worth reading even if it failed at the
# end (orch-state.sh exits 1 when a key of the state is missing): the pendings
# it DID print are the pendings. But the failure is not hidden: the report
# says so and the exit code says it too.
if rc != 0 or not resumen:
    resumen_ok = False
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
            # THE ACTION IS ON THE NEXT LINE. orch-state.sh prints every
            # pending item as TWO lines: the item and then "      hacer: <the
            # action>". The parser used to look at i + 2 and NEVER found it:
            # the report said WHAT was pending and never WHAT TO DO (B9).
            if i + 1 < len(lineas):
                accion = lineas[i + 1].strip()
                if accion.startswith("hacer:"):
                    pendientes[-1] += " -> " + accion[len("hacer:"):].strip()[:70]
        i += 1

# ---------------------------------------------------------------- los issues
issues_abiertos = 0
issues_ok = True
rc, out = sh(f"{shlex.quote(GH_BIN)} api --paginate 'repos/{REPO}/issues?state=open&per_page=100' "
             f"--jq '.[] | select(.pull_request == null) | .number'", "gh api issues")
if rc != 0:
    issues_ok = False
else:
    issues_abiertos = len([x for x in out.split() if x.strip().isdigit()])

# los issues que estamos atacando: los slots del orquestador + las ramas vivas
issues_trabajados = []
for slot, sl in (slots or {}).items():
    if isinstance(sl, dict) and sl.get("status") == "running":
        n = sl.get("issue")
        if n and str(n).isdigit():
            issues_trabajados.append(str(n))
issues_trabajados = sorted(set(issues_trabajados))

# ---------------------------------------------------------------- los verdicts
verdicts = []
try:
    for d in sorted(os.listdir(GATES)) if os.path.isdir(GATES) else []:
        f = os.path.join(GATES, d, "scope.effective.verdict")
        if not os.path.exists(f):
            continue
        try:
            with open(f, errors="replace") as fh:
                txt = fh.read()
        except Exception as e:
            fallos.append(f"veredicto {d}: {type(e).__name__}: {e}")
            continue
        v = re.search(r"^VERDICT=(.+)$", txt, re.M)
        n = re.search(r"^NEW_FAILURES=(\d+)$", txt, re.M)
        sha = re.search(r"^SHA=([0-9a-f]{9})", txt, re.M)
        if v:
            verdicts.append((d, v.group(1).strip(), n.group(1) if n else "?", sha.group(1) if sha else "-"))
except Exception as e:
    fallos.append(f"verdicts: {type(e).__name__}: {e}")

# ---------------------------------------------------------------- maquina
rc, load = sh("cut -d' ' -f1-3 /proc/loadavg", "loadavg")
load = load.strip() if rc == 0 else "?"
rc, disco = sh("df -h / | tail -1 | awk '{print $4\" libres de \"$2\" (\"$5\")\"}'", "df")
disco = disco.strip() if rc == 0 else "?"
rc, ram = sh("free -m | awk 'NR==2{print $3\"MB de \"$2\"MB en uso\"}'", "free")
ram = ram.strip() if rc == 0 else "?"

# ---------------------------------------------------------------- el reporte
ts = now_ar()
titulo = f"Reporte SolidCraft - {ts.strftime('%d-%m %H:%M')}"
L = [f"**{titulo}**", ""]
if prs_ok:
    L.append(f"PRs: {len(abiertos)} abiertos ({len(drafts)} draft), {len(mergeados)} mergeados, "
             f"{len(cerrados)} cerrados sin merge, {len(nuevos_hoy)} creados hoy.")
else:
    L.append("PRs: ? (no se pudo leer la lista de PRs).")
if issues_ok:
    if issues_abiertos:
        L.append(f"Issues abiertos en upstream: {issues_abiertos}.")
else:
    L.append("Issues abiertos en upstream: ? (no se pudo leer la lista).")
if issues_trabajados:
    L.append("Issues que atacamos: " + ", ".join("#" + i for i in issues_trabajados[:10]))
if nuevos_hoy:
    L.append("PRs de hoy: " + ", ".join("#" + str(p["number"]) for p in nuevos_hoy[:10]))
verdes = [v for v in verdicts if v[1] == "VERDE-SCOPE"]
L.append(f"Gates en verde: {len(verdes)}/{len(verdicts)} slots verificados"
         + (", " + ", ".join(f"{d}" for d, _, _, _ in verdes[:8]) if verdes else "") + ".")
rojos = [v for v in verdicts if v[1] != "VERDE-SCOPE"]
if rojos:
    L.append("Gates con fallos nuevos: " + ", ".join(f"{d} ({n})" for d, _, n, _ in rojos[:6]))
if state_ok:
    if en_marcha:
        L.append("En marcha: " + ", ".join(en_marcha[:8]) +
                 (f" (+{len(en_marcha)-8})" if len(en_marcha) > 8 else ""))
    else:
        L.append("En marcha: nada.")
else:
    L.append("En marcha: ? (no se pudo leer el estado).")
L.append(f"Agentes vivos: {vivos if vivos_ok else '?'}. "
         f"Maquina: load {load}, disco {disco}, RAM {ram}.")
# The pendings are shown when there are any. When the summary could NOT be
# read the section says "?": an empty section reads as "there are no pendings",
# and that is a thing we do not know.
if pendientes:
    L.append("Pendientes:")
    for p in pendientes:
        L.append("  - " + p)
elif not resumen_ok:
    L.append("Pendientes: ? (no se pudo leer el resumen del estado).")
if fallos:
    L.append("Fallos: " + "; ".join(fallos)[:200])
# "Sin nada nuevo" is only said when EVERYTHING was read and nothing failed:
# with a failure the silence would read as "nothing happened", and the
# failures (or a red gate) would be lost.
if not fallos and not nuevos_hoy and not en_marcha and not pendientes and not rojos:
    L = [f"**{titulo}**", "", "Sin nada nuevo: ningun PR nuevo, ningun pendiente."]

texto = "\n".join(L)
archivo = f"{REPORTS}/daily-{ts.strftime('%Y-%m-%d-%H%M')}.md"
try:
    escribir_atomico(archivo, texto + "\n")
    escribir_atomico(f"{REPORTS}/latest.md", texto + "\n")
except Exception as e:
    print(f"daily-report: no se pudo escribir el reporte: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(1)
print(texto)

if fallos:
    for f in fallos:
        print(f"fallo: {f}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
