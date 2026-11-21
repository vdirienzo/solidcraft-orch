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

LAS ALERTAS (2026-11-21): el estado decia "todo bien" con el loop parado. El
21-11 los crons corrian los .py con bash ("import: command not found" en cada
corrida), la wave no despachaba nada con dos slots libres y nadie se entero.
Ahora el estado grita una linea `ALERTA: ...` (arriba de todo) cuando:
- no se despacho ningun agente en 2 h, con slots libres (bin/slots.sh) y con
  la wave encontrando issues candidatos (o con el selector fallando), segun
  las lineas del ultimo turno en logs/cron-solidcraft-wave.log;
- un log de cron (logs/cron-*.log) repite la misma linea de error en sus
  ultimas corridas (command not found, Traceback, VEREDICTO=ERROR...);
- un slot `running` (o con lock) no tiene a nadie trabajando
  (bin/slot-busy.sh), pasada la gracia de la wave;
- quedan menos de 15 GB libres en el disco de los targets de los slots.

EXIT CODES:
  0  todo se leyo y no hay alertas
  1  algo no se pudo leer (la base, los PRs, los slots): el reporte dice "?"
  2  hay al menos una ALERTA
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import sqlite3
import datetime
import sys
import time

ORCH_DIR = os.environ.get("ORCH_DIR", os.path.expanduser("~/.local/share/solidcraft-orch"))
HERMES_HOME = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
# The gh binary: the tests point it at a stub OUTSIDE the PATH, so the tests
# never touch GitHub.
#
# EL gh DEL CRON (2026-11-21): el crontab corre con el PATH minimo y gh vive en
# ~/.local/bin ("gh: command not found" en logs/cron-solidcraft-ping-ready.log):
# si gh no esta en el PATH se usa el de ~/.local/bin.
def _gh_por_defecto():
    encontrado = shutil.which("gh")
    if encontrado:
        return encontrado
    local = os.path.expanduser("~/.local/bin/gh")
    return local if os.access(local, os.X_OK) else "gh"


GH_BIN = os.environ.get("GH_BIN") or _gh_por_defecto()
HERE = os.path.dirname(os.path.abspath(__file__))
LOGS = f"{ORCH_DIR}/logs"
# Los scripts hermanos: los tests los cambian por stubs (como GH_BIN).
SLOTS_SH = os.environ.get("SLOTS_SH") or os.path.join(HERE, "slots.sh")
SLOT_BUSY_SH = os.environ.get("SLOT_BUSY_SH") or os.path.join(HERE, "slot-busy.sh")
CRONS_TXT = os.environ.get("CRONS_TXT") or os.path.join(HERE, "crons.txt")
# La base de los targets de los slots (la misma que bin/slot-target-dir.sh).
TARGETS = os.environ.get("ORCH_TARGET_BASE") or f"{ORCH_DIR}/targets"


def _umbral(nombre, defecto):
    """A threshold from the environment: a value that is not a number is the default."""
    try:
        v = float(os.environ.get(nombre, ""))
    except ValueError:
        return defecto
    return v if v == v and v >= 0 else defecto


# Los umbrales de las alertas (los tests los mueven; la maquina usa estos).
ALERTA_DESPACHO_H = _umbral("ALERT_NO_DISPATCH_H", 2.0)
ALERTA_DISCO_GB = _umbral("ALERT_DISK_MIN_GB", 15.0)
# La wave corre cada 10 min: un log de la wave sin escribir en 30 es una wave
# que no corre.
WAVE_VIEJA_MIN = _umbral("ALERT_WAVE_STALE_MIN", 30.0)
# Un agente que salio deja su slot `running` hasta el proximo turno de la wave
# (10 min): eso no es un slot perdido.
GRACIA_SALIDA_MIN = _umbral("ALERT_SLOT_GRACE_MIN", 20.0)
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
    # SIN HERMES, LOS AGENTES SON LOS PROCESOS (2026-11-21): los agentes de
    # los slots son `opencode run --title issue-N` (bin/dispatch-slot.sh) y
    # ~/.hermes no existe en esta maquina. Una base que NO EXISTE no es una
    # base ilegible: se cuentan los procesos del agente. Una base que existe y
    # no se puede leer sigue siendo un "no se sabe" (D5).
    if not os.path.exists(DB):
        for issue in sorted(agentes_opencode(), key=int):
            out.append({"id": issue, "title": f"opencode issue-{issue}", "parent": "", "age": 0.0})
        return out, None
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


# ======================================================================== alertas
DESPACHO_RE = re.compile(r"^===== (\S+) dispatch-slot: issue (\d+), modelo \S+, techo \d+ min =====")
SALIDA_RE = re.compile(r"^===== (\S+) dispatch-slot: el agente del issue (\d+) salio con rc=-?\d+")


def a_fecha(valor):
    try:
        d = datetime.datetime.fromisoformat(str(valor).replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)


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


def despachos():
    """{issue: (last dispatch, last exit)} from the lines of bin/dispatch-slot.sh
    in logs/<N>-wave.log (aware datetimes, or None)."""
    out = {}
    try:
        nombres = os.listdir(LOGS)
    except OSError:
        return out
    for n in nombres:
        if not re.fullmatch(r"\d+-wave\.log", n):
            continue
        ultimo, salida = None, None
        try:
            with open(os.path.join(LOGS, n), encoding="utf-8", errors="replace") as fh:
                for linea in fh:
                    if not linea.startswith("====="):
                        continue
                    m = DESPACHO_RE.match(linea)
                    if m and a_fecha(m.group(1)):
                        ultimo = a_fecha(m.group(1))
                        continue
                    m = SALIDA_RE.match(linea)
                    if m and a_fecha(m.group(1)):
                        salida = a_fecha(m.group(1))
        except OSError:
            continue
        out[n.split("-", 1)[0]] = (ultimo, salida)
    return out


def leer_cola(ruta, max_bytes=65536):
    """The last lines of a log (the first partial line is dropped)."""
    with open(ruta, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        tam = fh.tell()
        fh.seek(max(0, tam - max_bytes))
        datos = fh.read()
    lineas = datos.decode("utf-8", "replace").splitlines()
    return lineas[1:] if tam > max_bytes else lineas


def slots_libres():
    """free_slots of bin/slots.sh, or None when it could not be read."""
    try:
        p = subprocess.run(["bash", SLOTS_SH], capture_output=True, text=True, timeout=60,
                           env={**os.environ, "ORCH_DIR": ORCH_DIR})
    except Exception:
        return None
    m = re.search(r"free_slots=(\d+)", p.stdout or "")
    return int(m.group(1)) if m else None


# EL ULTIMO TURNO DE LA WAVE, DE SU LOG (2026-11-21). bin/wave.sh no fecha sus
# lineas: la hora del ultimo turno es el mtime del log, y lo que encontro el
# selector son las lineas de la fase 4 ("wave: free_slots=N" y las que la
# siguen). Si bin/wave.sh cambia estos mensajes, este patron cambia con el
# (bin/test-loop-status.sh fija los mensajes que se leen).
FASE4_RE = re.compile(
    r"^wave: (free_slots=\d+|\d+ intentos fallaron|no hay ningún issue libre|    |"
    r"el slot \d+ ya tiene (el lock|worktree)|\(seco\) preparar|el issue #\d+ no se pudo preparar|"
    r"el agente del slot \d+ (no )?arrancó \((dispatch-slot|log:))")


def ultima_wave():
    """(minutes since the wave log was written, lines of phase 4 of its last
    turn), or (None, []) when there is no log."""
    ruta = f"{LOGS}/cron-solidcraft-wave.log"
    try:
        edad = (time.time() - os.path.getmtime(ruta)) / 60
        lineas = leer_cola(ruta)
    except OSError:
        return None, []
    inicio = max((i for i, l in enumerate(lineas) if l.startswith("wave: free_slots=")), default=None)
    if inicio is None:
        return edad, []
    bloque = []
    for l in lineas[inicio:]:
        if bloque and not FASE4_RE.match(l):
            break
        bloque.append(l)
    return edad, bloque


def alerta_despacho(desp, libres, ahora):
    """(alert or None, info line) for "no agent dispatched in 2 h"."""
    ultimos = [(d, i) for i, (d, _) in desp.items() if d]
    if ultimos:
        cuando, issue = max(ultimos)
        horas = (ahora - cuando).total_seconds() / 3600
        info = f"Ultimo despacho: hace {horas:.1f} h (#{issue})"
    else:
        horas = None
        info = "Ultimo despacho: ninguno registrado (no hay lineas de dispatch-slot en logs/<N>-wave.log)"
    info += f"; slots libres: {libres if libres is not None else '?'}."
    if horas is not None and horas < ALERTA_DESPACHO_H:
        return None, info
    if not libres:
        # Sin slots libres no se espera ningun despacho (o no se sabe si hay).
        return None, info
    hace = f"hace {horas:.1f} h" if horas is not None else "nunca (desde que se registran)"
    base = f"ningun agente despachado {hace} con {libres} slot(s) libre(s)"
    edad, bloque = ultima_wave()
    if edad is None:
        return f"{base}, y la wave no tiene log (logs/cron-solidcraft-wave.log)", info
    if edad > WAVE_VIEJA_MIN:
        return f"{base}, y la wave no corre: su log no se escribe hace {edad:.0f} min", info
    if any(re.match(r"^wave: el agente del slot \d+ arrancó \(log:", l) for l in bloque):
        return None, info
    errores = [l[len("wave:"):].strip() for l in bloque if l.startswith("wave:     ")]
    fallidos = [l for l in bloque if re.match(
        r"^wave: (el issue #\d+ no se pudo preparar|el agente del slot \d+ no arrancó|\d+ intentos fallaron)", l)]
    if fallidos:
        detalle = errores[0] if errores else fallidos[0][len("wave:"):].strip()
        return f"{base}: la wave encuentra issues y no los despacha ({detalle[:140]})", info
    if any(l.startswith("wave: no hay ningún issue libre") for l in bloque):
        if errores:
            return f"{base}: el selector de issues falla ({errores[0][:140]})", info
        return None, info + " La wave no encuentra issues libres (no es una alerta)."
    return None, info


# Las lineas de error que, repetidas corrida tras corrida, son un cron roto.
ERROR_RE = re.compile(
    r"command not found|Traceback \(most recent call last\)|VEREDICTO=ERROR|syntax error|"
    r"Permission denied|No such file or directory|No module named|\b[A-Z]\w*Error\b")


def normalizar(linea):
    """The same error in two runs: the clock times are not part of the error."""
    linea = re.sub(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z?", "<t>", linea.strip())
    return re.sub(r"\b\d{1,2}:\d\d(:\d\d)?\b", "<t>", linea)


def intervalos_cron():
    """{log name: minutes between runs} from bin/crons.txt."""
    out = {}
    try:
        with open(CRONS_TXT, encoding="utf-8") as fh:
            filas = fh.read().splitlines()
    except OSError:
        return out
    for fila in filas:
        partes = [p.strip() for p in fila.split("#", 1)[0].split("|")]
        if len(partes) < 3 or not partes[0]:
            continue
        campos = partes[1].split()
        if len(campos) < 2:
            continue
        minutos, horas = campos[0], campos[1]
        m = re.fullmatch(r"\*/(\d+)", minutos)
        if m and int(m.group(1)) > 0:
            n = int(m.group(1))
        elif minutos == "*":
            n = 1
        elif re.fullmatch(r"\d+(,\d+)*", minutos):
            n = 60 / len(minutos.split(","))
        else:
            continue
        if horas != "*":
            n = 1440 / len(horas.split(",")) if re.fullmatch(r"\d+(,\d+)*", horas) else 1440
        out[f"cron-{partes[0]}.log"] = n
    return out


# EL MISMO ERROR EN LAS ULTIMAS CORRIDAS (2026-11-21). Los logs de los crons no
# tienen marcas de corrida (el crontab hace `>>` sin fecha), pero una corrida
# rota imprime lo MISMO cada vez. Un error es "el mismo en las ultimas 3
# corridas" cuando su linea (sin la hora) aparece 3 veces o mas con huecos
# parecidos entre si (corridas del mismo largo), la ultima vez dentro de la
# ultima corrida (menos lineas despues que un hueco) y con el log escrito en
# los ultimos dos intervalos del cron (un cron arreglado que no imprime nada
# deja de escribir, y la alerta se apaga sola).
def error_repetido(lineas):
    """(line, times) of the error that repeats in the last runs, or None."""
    pos = {}
    for i, l in enumerate(lineas):
        # Lo que los reportes CITAN no es un error de su cron: sus ALERTAS y las
        # lineas de sus listas ("  · #N titulo"), que se repiten en cada corrida
        # y pueden traer un "KeyError" en el titulo de un PR.
        if l.startswith("ALERTA") or re.match(r"\s*[·-] ", l) or not ERROR_RE.search(l):
            continue
        pos.setdefault(normalizar(l), []).append(i)
    hallado = None
    for ps in pos.values():
        if len(ps) < 3:
            continue
        h1, h2 = ps[-2] - ps[-3], ps[-1] - ps[-2]
        if max(h1, h2) > 3 * min(h1, h2) or len(lineas) - 1 - ps[-1] > max(h1, h2):
            continue
        # El primer error de la ultima corrida: suele ser la causa.
        if hallado is None or ps[-1] < hallado[0]:
            hallado = (ps[-1], len(ps))
    return (lineas[hallado[0]].strip(), hallado[1]) if hallado else None


def alertas_cron(ahora_ts):
    out = []
    intervalos = intervalos_cron()
    try:
        nombres = sorted(n for n in os.listdir(LOGS) if re.fullmatch(r"cron-.+\.log", n))
    except OSError:
        return out
    for n in nombres:
        ruta = os.path.join(LOGS, n)
        try:
            edad_min = (ahora_ts - os.path.getmtime(ruta)) / 60
            if edad_min > 2 * intervalos.get(n, 60) + 5:
                continue
            cola = leer_cola(ruta)
            r = error_repetido(cola)
        except OSError:
            continue
        if r:
            cron = n[len("cron-"):-len(".log")]
            # BASH LEYENDO UN .py (2026-11-21): el crontab llamaba `bash
            # bin/<x>.py` y bash se quejaba linea por linea del Python. La causa
            # se dice, para no tener que adivinarla desde "import: command not found".
            causa = ""
            if any(re.search(r"\.py: line \d+: (import|from): command not found", l) for l in cola[-200:]):
                causa = " [bash esta corriendo un .py: el crontab tiene que llamarlo con python3]"
            out.append(f"el cron {cron} repite el mismo error ({r[1]} veces, tambien en su ultima "
                       f"corrida): {r[0][:160]}{causa}")
    return out


def slots_en_vuelo():
    """{issue: (worktree, target dir)} of the slots `running` in the state and
    of the slot locks: the slots that should have an agent."""
    out = {}
    try:
        with open(STATE, encoding="utf-8") as fh:
            d = json.load(fh)
        for name, v in (d.get("slots") or {}).items():
            if isinstance(v, dict) and v.get("status") == "running":
                issue = str(v.get("issue") or name)
                if issue.isdigit():
                    out[issue] = (str(v.get("worktree") or os.path.join(WORKTREES, f"issue-{issue}")),
                                  str(v.get("target_dir") or f"{TARGETS}/slot-{issue}"))
    except Exception:
        pass
    return out


def disco_libre_gb(ruta):
    """Free GB on the filesystem of a path (the nearest directory that exists)."""
    while ruta and not os.path.exists(ruta):
        ruta = os.path.dirname(ruta)
    st = os.statvfs(ruta or "/")
    return st.f_bavail * st.f_frsize / 1024 ** 3


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
    # LA CAJA PARADA (2026-11-20): un lock de slot con NADIE trabajando en el
    # es un agente que se fue y un lock que come la caja. La noche del 19-11 al
    # 20-11 la caja estuvo tres horas y pico asi, con doce nucleos libres, y
    # el estado decia "todo bien". Ahora el estado lo dice en voz alta.
    #
    # EL SLOT `running` SIN AGENTE TAMBIEN (2026-11-21): el estado puede decir
    # `running` sin lock (dispatch-slot.sh escribe el estado, no el lock) y el
    # agente pudo morirse igual. Los dos se miran con bin/slot-busy.sh, y un
    # slot sin nadie es una ALERTA cuando paso la gracia: el agente que acaba de
    # salir deja su slot `running` hasta el proximo turno de la wave.
    alertas = []
    errores = []
    ahora_utc = datetime.datetime.now(datetime.timezone.utc)
    desp = despachos()
    en_vuelo = slots_en_vuelo()
    owners = {}
    for name, owner, age in ls:
        if name.startswith("slot-") and name[len("slot-"):].isdigit():
            issue = name[len("slot-"):]
            owners[issue] = (owner, age)
            en_vuelo.setdefault(issue, (os.path.join(WORKTREES, f"issue-{issue}"), f"{TARGETS}/slot-{issue}"))
    stalled = []
    for issue in sorted(en_vuelo, key=int):
        wt, td = en_vuelo[issue]
        try:
            done = subprocess.run(["bash", SLOT_BUSY_SH, wt, td], capture_output=True, text=True, timeout=60)
        except Exception as e:
            errores.append(f"slot-busy {issue}: {type(e).__name__}: {e}")
            continue
        if done.returncode == 0:
            continue
        owner, age = owners.get(issue, ("", ""))
        ultimo, salida = desp.get(issue, (None, None))
        nota = ""
        if salida and (ultimo is None or salida >= ultimo) and \
                (ahora_utc - salida).total_seconds() < GRACIA_SALIDA_MIN * 60:
            nota = f"el agente salio hace {(ahora_utc - salida).total_seconds() / 60:.0f} min: la wave lo cierra"
        elif ultimo and (salida is None or salida < ultimo) and (ahora_utc - ultimo).total_seconds() < 180:
            nota = "el agente se esta despachando"
        else:
            fuente = "lock" if issue in owners else "estado"
            alertas.append(f"el slot {issue} esta en vuelo ({fuente}) y su agente NO esta "
                           f"(bin/slot-busy.sh: nadie trabaja en {os.path.basename(wt)})")
        stalled.append((issue, owner or "-", age or "?", nota))

    # LAS DEMAS ALERTAS: despachos, crons rotos, disco.
    libres = slots_libres()
    if libres is None:
        errores.append("bin/slots.sh: no dijo free_slots")
    alerta, info_despacho = alerta_despacho(desp, libres, ahora_utc)
    if alerta:
        alertas.append(alerta)
    alertas.extend(alertas_cron(time.time()))
    try:
        libre_gb = disco_libre_gb(TARGETS)
        info_disco = f"Disco de los targets: {libre_gb:.0f} GB libres (alerta bajo {ALERTA_DISCO_GB:.0f} GB)."
        if libre_gb < ALERTA_DISCO_GB:
            alertas.append(f"quedan {libre_gb:.1f} GB libres en el disco de los targets "
                           f"(menos de {ALERTA_DISCO_GB:.0f} GB): bin/gc-disk.sh o liberar slots")
    except OSError as e:
        errores.append(f"disco: {type(e).__name__}: {e}")
        info_disco = "Disco de los targets: ? (no se pudo medir)."
    # Las alertas van ARRIBA DE TODO: es lo primero que se lee en el celu.
    for a in alertas:
        lineas.append(f"ALERTA: {a}")
    lineas.append(info_despacho)
    lineas.append(info_disco)
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
    if stalled:
        lineas.append("")
        lineas.append("PARADO: la caja esta esperando por un slot cuyo agente NO esta:")
        for issue, owner, age, nota in stalled:
            lineas.append(f"  · slot {issue} (lock de {age}, owner {owner}): nadie trabaja en el"
                          + (f" ({nota})" if nota else ""))
        lineas.append("  la wave suelta ese lock en su proximo paso (10 min)")

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
    elif not ag and not sl and not os.path.exists(DB):
        # Sin hermes no hay bot: el loop es el crontab (2026-11-21).
        lineas.append("")
        lineas.append("El loop arranca solo: la wave del crontab despacha cada 10 min (bin/crons.txt).")
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
    # is NOT a clean report (RULES.md). An ALERTA is louder than a "?": rc=2.
    fallos = [f for f in (ag_error, prs_error) if f] + errores
    for f in fallos:
        print(f"fallo: {f}", file=sys.stderr)
    if alertas:
        return 2
    return 1 if fallos else 0


if __name__ == "__main__":
    sys.exit(main())
