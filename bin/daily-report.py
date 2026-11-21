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

LAS METRICAS (2026-11-21): ademas del estado, el reporte trae lo que dice si el
loop RINDE: mergeados en 7 dias y la mediana de horas hasta el merge, los
claims perdidos (logs/claims-lost/), las corridas de los agentes y su tasa de
exito (el veredicto JSON final del agente: ready/waiting es exito,
blocked/sin veredicto no), lo que cuesta cada slot (tokens, $, turnos, rc,
techos de tiempo, de logs/<N>-wave.jsonl y logs/<N>-wave.log), tokens y $ por
PR mergeado, y los PRs que esperan al maintainer. Las cuentas de PRs salen de
GitHub, no del estado local: el estado local se pierde y GitHub no.
"""
import json, os, re, shlex, shutil, statistics, subprocess, sqlite3, datetime, sys

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
#
# EL gh DEL CRON (2026-11-21): el crontab corre con el PATH minimo
# (/usr/bin:/bin) y gh vive en ~/.local/bin: los crons decian "gh: command
# not found" (logs/cron-solidcraft-ping-ready.log) y el reporte habria dicho
# "PRs: ?" en cada corrida. Si gh no esta en el PATH se usa el de ~/.local/bin.
def _gh_por_defecto():
    encontrado = shutil.which("gh")
    if encontrado:
        return encontrado
    local = os.path.expanduser("~/.local/bin/gh")
    return local if os.access(local, os.X_OK) else "gh"


GH_BIN = os.environ.get("GH_BIN") or _gh_por_defecto()
ORCH = ORCH_DIR
LOGS = f"{ORCH}/logs"
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
#
# LA CUENTA ES LA DE GITHUB, ENTERA (2026-11-21): se pedian `--limit 100` PRs y
# el fork ya tiene mas de 100 (119 el 21-11): los mas viejos quedaban fuera de
# la pagina y el reporte decia 79 mergeados con 90 en GitHub. `gh pr list`
# pagina solo hasta el --limit; el limite es alto, y si la lista lo TOCA la
# cuenta puede estar corta: el reporte lo dice como fallo, no lo calla.
PR_LIMIT = 2000
prs = []
prs_ok = True
rc, out = sh(f"{shlex.quote(GH_BIN)} pr list --repo {REPO} --author {AUTH} --state all "
             f"--limit {PR_LIMIT} --json number,state,isDraft,createdAt,mergedAt,closedAt,title",
             "gh pr list")
if rc != 0:
    prs_ok = False
else:
    try:
        prs = json.loads(out) if out.strip() else []
        if not isinstance(prs, list):
            raise ValueError(f"la lista de PRs no es una lista: {type(prs).__name__}")
        prs = [p for p in prs if isinstance(p, dict)]
    except Exception as e:
        prs = []
        prs_ok = False
        fallos.append(f"gh pr list: la respuesta no es una lista de PRs: {type(e).__name__}: {e}")
if prs_ok and len(prs) >= PR_LIMIT:
    fallos.append(f"gh pr list: llegaron {len(prs)} PRs, el limite: la cuenta puede estar corta")

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
#
# SIN HERMES, LOS VIVOS SON LOS PROCESOS DEL AGENTE (2026-11-21): los agentes
# de los slots son `opencode run --title issue-N` (bin/dispatch-slot.sh) y
# ~/.hermes no existe en esta maquina. Leer una base que no existe era un
# fallo en CADA corrida: el reporte salia siempre con rc=1, y un fallo de
# siempre no avisa de nada. Si la base NO EXISTE se cuentan los procesos del
# agente; si existe y no se puede leer, sigue siendo un fallo (no se sabe).
def agentes_opencode():
    """The issues with a live `opencode run ... --title issue-N` process."""
    issues = set()
    try:
        pids = [p for p in os.listdir("/proc") if p.isdigit()]
    except OSError:
        return issues
    for pid in pids:
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                args = [a.decode("utf-8", "replace") for a in fh.read().split(b"\0") if a]
        except OSError:
            continue
        if "run" not in args or not any(os.path.basename(a).startswith("opencode") for a in args):
            continue
        for i in range(len(args) - 1):
            m = re.fullmatch(r"issue-(\d+)", args[i + 1]) if args[i] == "--title" else None
            if m:
                issues.add(m.group(1))
    return issues


vivos = 0
vivos_ok = True
if not os.path.exists(f"{HERMES_HOME}/state.db"):
    vivos = len(agentes_opencode())
else:
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

# ================================================================ las metricas
# QUE RINDE EL LOOP, NO SOLO QUE ESTA HACIENDO (2026-11-21). El reporte decia
# cuantos PRs habia y que slots estaban tomados, pero no cuanto cuesta un PR
# mergeado, cuantas corridas de agente terminan en nada ni cuanto espera un PR
# listo al maintainer: con eso no se puede decidir si el loop rinde o quema
# tokens. Todo sale de archivos y de GitHub, sin LLM.
AHORA = datetime.datetime.now(datetime.timezone.utc)
VENTANA = datetime.timedelta(days=7)
DESDE = AHORA - VENTANA


def a_fecha(valor):
    """An ISO date of GitHub or of a log, as an aware datetime (None if not one)."""
    if not isinstance(valor, str) or not valor:
        return None
    try:
        d = datetime.datetime.fromisoformat(valor.replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)


def numero(valor):
    """A count or an amount from a log: a hostile value is 0, never a crash."""
    if isinstance(valor, bool) or not isinstance(valor, (int, float)):
        return 0
    return valor if valor == valor and abs(valor) != float("inf") else 0


def fmt_tok(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(int(n))


def fmt_usd(x):
    return f"${x:.2f}" if x >= 1 else f"${x:.3f}"


def fmt_edad(td):
    horas = td.total_seconds() / 3600
    return f"{horas:.0f} h" if horas < 48 else f"{horas / 24:.1f} d"


# ---------------------------------------------------------------- merges (7 d)
merge_7d = []
for p in mergeados:
    creado, mergeado = a_fecha(p.get("createdAt")), a_fecha(p.get("mergedAt"))
    if creado and mergeado and mergeado >= DESDE:
        merge_7d.append((mergeado - creado).total_seconds() / 3600)
mediana_merge_h = statistics.median(merge_7d) if merge_7d else None

# ---------------------------------------------------------------- claims perdidos
# Cada claim perdido deja logs/claims-lost/<issue>-<AAAAMMDD-HHMMSS>/. Sin el
# directorio no se perdio ninguno todavia (se crea con el primero): es 0.
claims_perdidos = 0
claims_perdidos_7d = 0
_dir_claims = f"{LOGS}/claims-lost"
if os.path.isdir(_dir_claims):
    try:
        for nombre in os.listdir(_dir_claims):
            ruta = os.path.join(_dir_claims, nombre)
            if not os.path.isdir(ruta):
                continue
            claims_perdidos += 1
            m = re.fullmatch(r"\d+-(\d{8}-\d{6})", nombre)
            try:
                cuando = (datetime.datetime.strptime(m.group(1), "%Y%m%d-%H%M%S")
                          .replace(tzinfo=datetime.timezone.utc)) if m else None
            except ValueError:
                cuando = None
            if cuando is None:
                cuando = datetime.datetime.fromtimestamp(os.path.getmtime(ruta), datetime.timezone.utc)
            if cuando >= DESDE:
                claims_perdidos_7d += 1
    except OSError as e:
        claims_perdidos = None
        fallos.append(f"claims-lost: {type(e).__name__}: {e}")

# ---------------------------------------------------------------- las corridas de los agentes
# UNA CORRIDA = UN DESPACHO (2026-11-21). bin/dispatch-slot.sh escribe en
# logs/<N>-wave.log una linea al despachar y otra cuando el agente sale (con
# su rc; 124 es el techo de tiempo), y el agente (`opencode run --format
# json`) deja sus eventos en logs/<N>-wave.jsonl. Los eventos que importan:
#   step_finish: part.tokens.{input,output,reasoning,cache.read,cache.write},
#                part.cost (en $): uno por turno del modelo;
#   text:        part.text: lo que el agente escribe; el ULTIMO objeto JSON
#                con "verdict" es su veredicto ({"verdict":"ready|waiting|
#                blocked","pr":N,...}).
# Cada despacho es una sesion nueva (sessionID): la sesion se asigna al
# despacho que la precede. Una linea que no es JSON (un agente cortado a mitad
# de una linea) se salta: es el final normal de un turno matado.
DESPACHO_RE = re.compile(r"^===== (\S+) dispatch-slot: issue (\d+), modelo (\S+), techo (\d+) min =====")
SALIDA_RE = re.compile(r"^===== (\S+) dispatch-slot: el agente del issue (\d+) salio con rc=(-?\d+)( \(techo de tiempo\))? =====")


def ultimo_veredicto(textos):
    """The last JSON object with a "verdict" that the agent wrote, or None."""
    dec = json.JSONDecoder()
    for texto in reversed(textos):
        # El veredicto es el FINAL del mensaje: un texto enorme no se recorre entero.
        texto = texto[-20000:]
        hallado = None
        i = texto.find("{")
        while i != -1:
            try:
                obj, fin = dec.raw_decode(texto, i)
            except ValueError:
                i = texto.find("{", i + 1)
                continue
            if isinstance(obj, dict) and "verdict" in obj:
                hallado = obj
            i = texto.find("{", fin)
        if hallado is not None:
            return hallado
    return None


def corrida_nueva(issue, inicio):
    return {"issue": issue, "inicio": inicio, "techo_min": None, "rc": None, "techo": False,
            "turnos": 0, "entrada": 0, "salida": 0, "razonamiento": 0, "cache_r": 0, "cache_w": 0,
            "costo": 0.0, "con_costo": False, "textos": [], "sesiones": 0}


def leer_corridas(issue):
    """The runs of one slot: its dispatches (.log) with their sessions (.jsonl)."""
    corridas = []
    ruta_log = f"{LOGS}/{issue}-wave.log"
    if os.path.exists(ruta_log):
        with open(ruta_log, encoding="utf-8", errors="replace") as fh:
            for linea in fh:
                if not linea.startswith("====="):
                    continue
                m = DESPACHO_RE.match(linea)
                if m:
                    c = corrida_nueva(issue, a_fecha(m.group(1)))
                    c["techo_min"] = int(m.group(4))
                    corridas.append(c)
                    continue
                m = SALIDA_RE.match(linea)
                if m and corridas and corridas[-1]["rc"] is None:
                    corridas[-1]["rc"] = int(m.group(3))
                    corridas[-1]["techo"] = bool(m.group(4)) or m.group(3) == "124"
    ruta_jsonl = f"{LOGS}/{issue}-wave.jsonl"
    if not os.path.exists(ruta_jsonl):
        return corridas
    sesiones = {}
    with open(ruta_jsonl, encoding="utf-8", errors="replace") as fh:
        for linea in fh:
            linea = linea.strip()
            if not linea.startswith("{"):
                continue
            try:
                ev = json.loads(linea)
            except ValueError:
                continue
            if not isinstance(ev, dict):
                continue
            sid = str(ev.get("sessionID") or "?")
            ts = numero(ev.get("timestamp"))
            s = sesiones.get(sid)
            if s is None:
                cuando = (datetime.datetime.fromtimestamp(ts / 1000, datetime.timezone.utc)
                          if 0 < ts < 1e14 else None)
                s = sesiones[sid] = corrida_nueva(issue, cuando)
            parte = ev.get("part") if isinstance(ev.get("part"), dict) else {}
            if ev.get("type") == "step_finish":
                tok = parte.get("tokens") if isinstance(parte.get("tokens"), dict) else {}
                cache = tok.get("cache") if isinstance(tok.get("cache"), dict) else {}
                s["turnos"] += 1
                s["entrada"] += numero(tok.get("input"))
                s["salida"] += numero(tok.get("output"))
                s["razonamiento"] += numero(tok.get("reasoning"))
                s["cache_r"] += numero(cache.get("read"))
                s["cache_w"] += numero(cache.get("write"))
                if not isinstance(parte.get("cost"), bool) and isinstance(parte.get("cost"), (int, float)):
                    s["costo"] += numero(parte.get("cost"))
                    s["con_costo"] = True
            elif ev.get("type") == "text" and isinstance(parte.get("text"), str):
                s["textos"] = (s["textos"] + [parte["text"]])[-5:]
    # Cada sesion va al despacho que la precede (con un minuto de margen por
    # los relojes); una sesion sin despacho (un turno lanzado a mano, o de antes
    # de las lineas de despacho) es una corrida por si misma.
    margen = datetime.timedelta(minutes=1)
    despachos = list(corridas)
    for s in sesiones.values():
        dueno = None
        for c in despachos:
            if c["inicio"] and s["inicio"] and c["inicio"] - margen <= s["inicio"]:
                dueno = c
        if dueno is None:
            s["sesiones"] = 1
            corridas.append(s)
            continue
        dueno["sesiones"] += 1
        for k in ("turnos", "entrada", "salida", "razonamiento", "cache_r", "cache_w", "costo"):
            dueno[k] += s[k]
        dueno["con_costo"] = dueno["con_costo"] or s["con_costo"]
        dueno["textos"] = (dueno["textos"] + s["textos"])[-5:]
    return corridas


corridas = []
try:
    _nombres = sorted(os.listdir(LOGS)) if os.path.isdir(LOGS) else []
except OSError as e:
    _nombres = []
    fallos.append(f"logs: {type(e).__name__}: {e}")
for issue in sorted({m.group(1) for m in (re.fullmatch(r"(\d+)-wave\.(?:log|jsonl)", n)
                                           for n in _nombres) if m}, key=int):
    # Los logs los escribe un agente: entrada hostil. Un log que no se pudo
    # leer es un fallo del reporte, nunca un reporte que no se escribe.
    try:
        corridas.extend(leer_corridas(issue))
    except Exception as e:
        fallos.append(f"corridas de {issue}: {type(e).__name__}: {e}")

for c in corridas:
    v = ultimo_veredicto(c["textos"])
    c["veredicto"] = str(v.get("verdict"))[:20] if v else None
    _pr = v.get("pr") if v else None
    c["pr"] = str(_pr) if isinstance(_pr, int) and not isinstance(_pr, bool) or \
        (isinstance(_pr, str) and _pr.isdigit() and len(_pr) < 10) else None
    c["tokens"] = c["entrada"] + c["salida"] + c["razonamiento"] + c["cache_r"] + c["cache_w"]
    # Sin la linea de salida la corrida sigue EN CURSO mientras no pase su
    # techo (mas un margen); despues es una corrida que se fue sin cerrar.
    techo = datetime.timedelta(minutes=(c["techo_min"] or 0) + 10)
    c["en_curso"] = (c["rc"] is None and c["veredicto"] is None and c["inicio"] is not None
                     and c["techo_min"] is not None and AHORA - c["inicio"] < techo)
    c["exito"] = c["veredicto"] in ("ready", "waiting")

corridas_7d = [c for c in corridas if c["inicio"] and c["inicio"] >= DESDE]
terminadas_7d = [c for c in corridas_7d if not c["en_curso"]]
exitos_7d = [c for c in terminadas_7d if c["exito"]]
tokens_7d = sum(c["tokens"] for c in corridas_7d)
costo_7d = sum(c["costo"] for c in corridas_7d)
con_costo_7d = any(c["con_costo"] for c in corridas_7d)

# ---------------------------------------------------------------- esperando al maintainer
# UN PR LISTO Y EN VERDE ESPERA AL MAINTAINER, Y ESO TIENE EDAD (2026-11-21):
# el maintainer pone `approved-for-ci` despues de revisar (sin el label el CI
# completo de upstream no corre), y el loop no le vuelve a preguntar
# (bin/crons.txt). El reporte dice cuantos hay, desde cuando, y con o sin label.
def estado_checks(checks):
    """'verde', 'rojo', 'pendiente' or 'sin checks', from a statusCheckRollup."""
    if not isinstance(checks, list) or not checks:
        return "sin checks"
    pendiente = False
    for c in checks:
        if not isinstance(c, dict):
            continue
        if c.get("__typename") == "StatusContext":
            st = str(c.get("state") or "").upper()
            if st in ("", "PENDING", "EXPECTED"):
                pendiente = True
            elif st != "SUCCESS":
                return "rojo"
            continue
        concl = str(c.get("conclusion") or "").upper()
        if str(c.get("status") or "").upper() != "COMPLETED" and not concl:
            pendiente = True
        elif concl not in ("SUCCESS", "NEUTRAL", "SKIPPED"):
            return "rojo"
    return "pendiente" if pendiente else "verde"


esperando = []
listos_no_verdes = 0
esperando_ok = True
rc, out = sh(f"{shlex.quote(GH_BIN)} pr list --repo {REPO} --author {AUTH} --state open "
             f"--limit 200 --json number,state,isDraft,createdAt,labels,statusCheckRollup,title",
             "gh pr list (abiertos)")
if rc != 0:
    esperando_ok = False
else:
    try:
        _abiertos = json.loads(out) if out.strip() else []
        if not isinstance(_abiertos, list):
            raise ValueError(f"la lista de PRs no es una lista: {type(_abiertos).__name__}")
        for p in _abiertos:
            if not isinstance(p, dict) or p.get("state", "OPEN") != "OPEN" or p.get("isDraft"):
                continue
            if estado_checks(p.get("statusCheckRollup")) != "verde":
                listos_no_verdes += 1
                continue
            etiquetas = {str(l.get("name")) for l in (p.get("labels") or []) if isinstance(l, dict)}
            creado = a_fecha(p.get("createdAt"))
            esperando.append((p.get("number"), creado, "approved-for-ci" in etiquetas,
                              str(p.get("title") or "")[:60]))
        esperando.sort(key=lambda e: e[1] or AHORA)
    except Exception as e:
        esperando_ok = False
        fallos.append(f"gh pr list (abiertos): {type(e).__name__}: {e}")

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
# "Sin nada nuevo" is only said when EVERYTHING was read and nothing failed:
# with a failure the silence would read as "nothing happened", and the
# failures (or a red gate) would be lost.
if not fallos and not nuevos_hoy and not en_marcha and not pendientes and not rojos:
    L = [f"**{titulo}**", "", "Sin nada nuevo: ningun PR nuevo, ningun pendiente."]

# LAS METRICAS VAN SIEMPRE (2026-11-21): "sin nada nuevo" habla del estado, no
# del rendimiento; un dia sin novedades tambien tiene su costo y su espera.
L.append("")
L.append("Metricas (7 dias):")
if prs_ok:
    L.append(f"  Mergeados en 7 d: {len(merge_7d)}"
             + (f"; mediana hasta el merge: {mediana_merge_h:.1f} h." if merge_7d else "."))
else:
    L.append("  Mergeados en 7 d: ? (no se pudo leer la lista de PRs).")
L.append(f"  Claims perdidos: {claims_perdidos_7d} en 7 d ({claims_perdidos} en total)."
         if claims_perdidos is not None else "  Claims perdidos: ? (no se pudo leer logs/claims-lost).")
if terminadas_7d:
    L.append(f"  Corridas de agente en 7 d: {len(corridas_7d)} ({len(corridas_7d) - len(terminadas_7d)} en curso); "
             f"exito {100 * len(exitos_7d) / len(terminadas_7d):.0f}% ({len(exitos_7d)} de "
             f"{len(terminadas_7d)} terminadas con ready/waiting; el resto blocked o sin veredicto).")
elif corridas_7d:
    L.append(f"  Corridas de agente en 7 d: {len(corridas_7d)}, todas en curso (sin tasa de exito todavia).")
else:
    L.append("  Corridas de agente en 7 d: 0.")
if not corridas_7d:
    L.append("  Tokens y $ por PR mergeado (7 d): sin datos (no hay corridas en logs/<N>-wave.jsonl).")
elif merge_7d:
    L.append(f"  Por PR mergeado (7 d): {fmt_tok(tokens_7d / len(merge_7d))} tokens"
             + (f", {fmt_usd(costo_7d / len(merge_7d))}" if con_costo_7d else ", $ ?")
             + f" (total {fmt_tok(tokens_7d)} tokens" + (f", {fmt_usd(costo_7d)}" if con_costo_7d else "")
             + f"; solo las corridas con .jsonl).")
else:
    L.append(f"  Por PR mergeado (7 d): ningun merge; las corridas gastaron {fmt_tok(tokens_7d)} tokens"
             + (f", {fmt_usd(costo_7d)}." if con_costo_7d else "."))

if not esperando_ok:
    L.append("Esperando al maintainer: ? (no se pudo leer los PRs abiertos).")
else:
    L.append(f"Esperando al maintainer (listos y en verde): {len(esperando)}"
             + (f" (+{listos_no_verdes} listos con checks rojos, pendientes o sin checks)" if listos_no_verdes else "")
             + (":" if esperando else "."))
    for num, creado, aprobado, titulo_pr in esperando[:10]:
        L.append(f"  · #{num} hace {fmt_edad(AHORA - creado) if creado else '?'}, "
                 f"approved-for-ci: {'si' if aprobado else 'NO'} - {titulo_pr}")

# Por slot: los slots con corridas en la ventana, el mas reciente primero.
por_slot = {}
for c in corridas_7d:
    por_slot.setdefault(c["issue"], []).append(c)
if por_slot:
    L.append("Agentes por slot (7 d):")
    orden = sorted(por_slot.items(), key=lambda kv: max(c["inicio"] for c in kv[1]), reverse=True)
    for issue, cs in orden[:10]:
        cs.sort(key=lambda c: c["inicio"])
        ultima = cs[-1]
        tok = sum(c["tokens"] for c in cs)
        costo = sum(c["costo"] for c in cs)
        techos = sum(1 for c in cs if c["techo"])
        if ultima["en_curso"]:
            fin = "en curso"
        else:
            fin = f"rc={ultima['rc'] if ultima['rc'] is not None else '?'}, veredicto {ultima['veredicto'] or 'ninguno'}"
            if ultima["pr"]:
                fin += f" (PR #{ultima['pr']})"
        L.append(f"  · #{issue}: {len(cs)} corrida(s), {sum(c['turnos'] for c in cs)} turnos, "
                 f"{fmt_tok(tok)} tokens (entrada {fmt_tok(sum(c['entrada'] for c in cs))}, "
                 f"salida {fmt_tok(sum(c['salida'] for c in cs))}, "
                 f"cache {fmt_tok(sum(c['cache_r'] for c in cs))}/{fmt_tok(sum(c['cache_w'] for c in cs))}), "
                 f"{fmt_usd(costo) if any(c['con_costo'] for c in cs) else '$ ?'}"
                 + (f", {techos} por techo de tiempo" if techos else "") + f"; ultima: {fin}.")

if fallos:
    L.append("Fallos: " + "; ".join(fallos)[:200])

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
