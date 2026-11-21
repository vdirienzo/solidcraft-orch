#!/usr/bin/env python3
"""
pipeline.py - el eslabon que faltaba entre "el agente commitea" y "el PR queda publicado".

POR QUE EXISTE (2026-11-04): el claim de un issue vence a las 72 h si no hay un PR que lo
referencie. Antes, el agente commiteaba, pusheaba y corria el gate: si el gate se colgaba o
el agente se moria, el issue se perdia sin PR y el claim se iba. Ademas los gates se pedian
uno por uno, sin cola, y cada agente compilaba por su cuenta (convencion de locks).

QUE HACE ESTE SCRIPT, en cada corrida:
  1. Para cada PR nuestro que este en DRAFT: le agrega la referencia al issue si falta.
     La linea "Changes a default:" NO se inventa nunca: si falta, el PR se queda en draft y
     queda logueado que hay que escribirla a mano (un "no" automatico puede ser falso).
  2. Para cada PR en draft cuyo gate NO tenga veredicto todavia: en modo fork-ci (el
     default desde el 2026-11-21) DESPACHA ci.yml en el fork sobre el head (una vez por
     sha: ver "EL GATE ES EL CI DEL FORK"); en modo local (GATE_MODE=local) lo ENCOLA
     en gate-queue.sh, como antes.
  3. Para cada PR en draft cuyo gate dio verde (el CI del fork en el head, o un veredicto
     local verde del head) Y cuyo CI de GitHub esta VERDE en su HEAD SHA: lo pasa a READY.
     Sin comentarios: el veredicto queda en el log.
  4. NO pide mas trabajo del que hay donde correrlo: MAX_INFLIGHT gates locales en la
     cola, FORK_CI_MAX_INFLIGHT runs del fork en vuelo.
  5. Al final, un resumen con cuantos PRs tienen el CI de GitHub verde, pendiente y en rojo.
  Un PR que ya esta listo (el agente lo paso a ready) no se toca: ni se despacha ni
  vuelve a draft.

POR QUE EL CI DE GITHUB SE MIRA ADEMAS DEL GATE LOCAL (2026-11-07):
  El gate local (el nuestro) y el CI de GitHub (el de upstream) son dos cosas distintas. El
  CI de upstream incluye el "Defaults line check", el "Duplicate PR check" y el "Picture
  check": un PR con el gate local en verde pero el CI de upstream en rojo NO se puede
  mergear. Antes este script miraba solo el gate local y dejaba "Gate local en verde" un PR
  con un check rojo en pantalla (PR #12891, #12574).
  Y el estado del CI hay que leerlo de los CHECK-RUNS del HEAD SHA, no del rollup: el
  workflow pr-checks corre con `concurrency: {cancel-in-progress: true}`, asi que una
  edicion del body cancela el run anterior y crea otro con el MISMO nombre. Por eso en el
  rollup conviven un check "cancelled" y su gemelo en "success": no son dos checks, es el
  mismo check de dos runs. El que vale es el MAS RECIENTE de cada nombre.

Se corre desde un cron cada 5 minutos. Es idempotente: correrlo dos veces no rompe nada.

QUE NO MIENTE (2026-11-17):
  Este script corre cada 5 minutos, asi que sus silencios son los que hacen que
  el mantenedor crea que algo esta pasando cuando no esta pasando nada. Por eso:
    - un 'gh' que falla se ve (el comando, su rc y su stderr) y el rc LLEGA al
      exit code (Regla 7 del repo: un veredicto que no llega al exit code es
      peor que no tener veredicto);
    - un veredicto de gate con el SHA CORTO se encuentra con el head completo
      de la API (si no, el gate se reencola cada 5 minutos y el PR nunca llega
      a ready);
    - el comentario del veredicto lleva un marcador con el head sha y se
      postea UNA vez, no cada 5 minutos;
    - un 'gh pr ready' que falla se loguea y cuenta como problema;
    - la lista de PRs sale de la API paginada (no de un --limit 30);
    - el issue de un PR sale del titulo o de un verbo de cierre real, nunca de
      un '#numero' suelto.

  LOS CODIGOS DE SALIDA:
    0  todo bien
    1  la corrida ocurrio pero hubo problemas (un 'gh pr ready' que fallo, un
       body que no se pudo editar, un comentario que no se pudo postear)
    6  UNKNOWN: no se pudo leer la lista de PRs, asi que no se hizo nada. No es
       un 'no': es un 'no se sabe' (RULES.md: un check que no pudo correr NO
       es un rojo).
"""
import json
import os
import shutil
import re
import subprocess
import sys
import time

# The paths come from the environment, with the default of THIS machine: the
# other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR = os.environ.get("ORCH_DIR", os.path.expanduser("~/.local/share/solidcraft-orch"))
LOOP_DIR = os.environ.get("LOOP_DIR", os.path.expanduser("~/.local/share/solidcraft-loop"))
ORCH = ORCH_DIR
GATES = f"{LOOP_DIR}/gates"
QUEUE = f"{ORCH}/gates/queue.txt"
REPO = "tangency-labs/solidcraft"
FORK = "vdirienzo/solidcraft"
MAX_INFLIGHT = int(os.environ.get("MAX_INFLIGHT", "6"))
LOG = f"{ORCH}/logs/pipeline.log"
# LOS WORKTREES DE LOS SLOTS (2026-11-20).
#
# Un gate necesita el worktree de su slot: sin el, el gate no puede correr
# (bin/gate-queue.sh lo dice y no lo lanza). Y el PR en draft de un slot
# cerrado se queda en la cola para siempre: el pipeline lo encolaba cada
# cinco minutos y el cron de la cola lo sacaba cada tres, con lo que el
# cron de solidcraft-gate-queue fallaba 108 veces el 20-11-2026 con una
# condicion que no iba a cambiar (el PR #19492 es un draft cuyo slot esta
# cerrado). Un cron rojo cada tres minutos esconde los avisos de verdad.
WORKTREES_DIR = os.environ.get("WORKTREES_DIR", os.path.expanduser("~/solidcraft-wt"))


def log(msg):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line)
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


# El gh que se usa: GH_BIN si esta definido, si no el del PATH. Un stub de gh en un scratch
# que alguien dejo en el PATH hace no-op en 'pr create' y deja PRs que no existen (o no publica
# los que existentes): por eso es configurable y hay que verificar el binario.
GH_BIN = os.environ.get("GH_BIN") or shutil.which("gh") or "gh"

# El autor de nuestros PRs (el fork). La API no filtra por autor: el filtro se hace aca.
AUTHOR = "vdirienzo"
# How many open pull requests of ours the pipeline asks for. The upstream
# has a thousand open; ours are a handful. The limit is here so that a
# bug in the filter cannot ask for the whole upstream.
PR_LIMIT = 500


def recortar(texto, maximo=200):
    """El texto en una linea y recortado: el log tiene que decir QUE fallo."""
    t = " ".join(str(texto or "").split())
    if len(t) > maximo:
        t = t[:maximo] + "..."
    return t or "(sin stderr)"


def gh_run(*args, timeout=120):
    """(rc, stdout, stderr) de la llamada a gh. Es el UNICO lugar que corre gh.

    El rc NO se traga. Este script corre cada 5 minutos por cron: un 'gh' que
    fallaba en silencio (por ejemplo, un corte de auth de GitHub) producia un
    cron VERDE que no habia hecho nada.
    """
    try:
        r = subprocess.run([GH_BIN, *args], capture_output=True, text=True,
                           timeout=timeout)
    except FileNotFoundError as exc:
        return 127, "", f"no se pudo ejecutar {GH_BIN}: {exc}"
    except subprocess.TimeoutExpired:
        return 124, "", f"la llamada a gh se paso de {timeout}s"
    return r.returncode, r.stdout or "", r.stderr or ""


def gh(*args, timeout=120):
    """(rc, stdout) de la llamada a gh.

    Si el comando falla, el log dice QUE fallo (el comando, su rc y el stderr
    recortado) y el rc queda a la vista de quien llama: la falla es visible.
    """
    rc, out, err = gh_run(*args, timeout=timeout)
    if rc != 0:
        log(f"gh fallo: {GH_BIN} {' '.join(args)} -> rc={rc}: {recortar(err)}")
    return rc, out


def issue_of(title, body):
    """El issue que referencia el PR (o None si no se sabe).

    Ver el bloque de "EL ISSUE DE UN PR" mas abajo: sale del titulo o de un
    verbo de cierre real, NUNCA de un '#numero' suelto.
    """
    return issue_de_cierre(body) or issue_del_titulo(title) or issue_referenciado(body)


# --------------------------------------------------------------------------
# EL CI DE GITHUB (2026-11-07)
#
# El estado de un PR se lee de los check-runs de su HEAD SHA. Cada check-run trae un
# 'conclusion' (success/skipped/neutral/failure/cancelled/timed_out/...) y un
# 'completed_at'. Con `cancel-in-progress: true` un run viejo queda 'cancelled' cuando uno
# nuevo del MISMO nombre arranca: por eso, para cada NOMBRE de check, gana el run MAS
# RECIENTE. El 'cancelled' del run viejo NO cuenta como rojo.
#
# Todo esto es puro: no toca la red, y por eso se puede testear offline con check-runs
# inventados. La funcion que trae los check-runs de GitHub esta aparte (fetch_check_runs).
# --------------------------------------------------------------------------

# Las conclusiones que NO impiden promover.
CHECK_OK = ("success", "skipped", "neutral")
# Las conclusiones que son un rojo de verdad.
CHECK_ROJOS = ("failure", "timed_out", "action_required", "startup_failure")
# 'cancelled' y 'stale' no son fallos del PR: son runs superseded por uno nuevo.

VERDE = "verde"
PENDIENTE = "pendiente"
ROJO = "rojo"


def _id(run):
    try:
        return int(run.get("id") or 0)
    except (TypeError, ValueError):
        return 0


def _conclusion(run):
    return (run.get("conclusion") or "").lower()


def _status(run):
    return (run.get("status") or "").lower()


def _completed_at(run):
    return run.get("completed_at") or run.get("started_at") or ""


def _vigente(runs):
    """El run que cuenta de un grupo de check-runs del MISMO nombre.

    Gana el MAS RECIENTE por completed_at (y a igualdad, el id mas alto). El 'cancelled' del
    run viejo (el que cancelo el nuevo) no se confunde con un rojo: si hay un gemelo en
    verde creado despues, ese gemelo es el que manda.
    """
    completados = [r for r in runs if _status(r) == "completed"]
    if not completados:
        return None
    return max(completados, key=lambda r: (_completed_at(r), _id(r)))


def _en_vuelo(runs, vigente):
    """El run que esta corriendo AHORA en un grupo de check-runs del mismo nombre, o None.

    Un run en vuelo (queued/in_progress) que arranco DESPUES de que terminara el ultimo
    completado es el CI que se esta re-disparando ahora: todavia no hay veredicto. Un run
    en vuelo mas viejo que el ultimo completado es un resto (un run que GitHub nunca
    finalizo): no cuenta, porque si contara el PR quedaria pendiente para siempre.
    """
    for run in runs:
        if _status(run) == "completed":
            continue
        if vigente is None:
            return run
        if (run.get("started_at") or "", _id(run)) > (_completed_at(vigente), _id(vigente)):
            return run
    return None


def evaluar_check_runs(check_runs):
    """El estado del CI de un SHA a partir de SUS check-runs. (estado, detalle)

    estado es VERDE, PENDIENTE o ROJO. Es pura: no toca la red, se testea offline.

    - Por cada NOMBRE de check se gana el run MAS RECIENTE (completed_at, y a igualdad el id).
      Asi el 'cancelled' del run viejo no se confunde con un rojo.
    - Un conclusion duro (failure/timed_out/action_required/startup_failure) en el run
      vigente -> ROJO.
    - Un run en vuelo (queued/in_progress) MAS NUEVO que el ultimo completado -> PENDIENTE:
      el CI todavia no dio veredicto (se acaba de re-disparar por una edicion del body) y no
      se promueve.
    - Sin check-runs -> PENDIENTE (el CI todavia no arranco).
    """
    if not check_runs:
        return PENDIENTE, "el CI todavia no arranco (sin check-runs en el HEAD SHA)"

    clasificado = clasificar_check_runs(check_runs)
    if clasificado is None:
        return PENDIENTE, "el CI todavia no arranco (sin check-runs en el HEAD SHA)"
    rojos = [f"{nombre} ({motivo})" for nombre, motivo in clasificado[0]]
    pendientes = [f"{nombre} ({motivo})" for nombre, motivo in clasificado[1]]

    if rojos:
        return ROJO, "rojo: " + ", ".join(sorted(rojos))
    if pendientes:
        return PENDIENTE, "pendiente: " + ", ".join(sorted(pendientes))
    return VERDE, "verde: todos los checks del HEAD SHA estan en verde"


def clasificar_check_runs(check_runs):
    """([(nombre, motivo) rojos], [(nombre, motivo) pendientes]) o None si no hay ninguno.

    LA MISMA REGLA DE evaluar_check_runs, CON LOS NOMBRES (2026-11-21): el CI del
    fork (los jobs de un run de ci.yml) se juzga con la regla de "gana el mas
    reciente de cada nombre", y su linea de estado tiene que decir QUE jobs
    fallan, no solo que algo fallo. Una sola regla para los dos: si cada uno
    tuviera la suya, el dia que se arregle una se rompe la otra.
    """
    grupos = {}
    for run in check_runs or []:
        if not isinstance(run, dict):
            continue
        grupos.setdefault(run.get("name") or "?", []).append(run)
    if not grupos:
        return None

    rojos = []
    pendientes = []
    for nombre, runs in grupos.items():
        vigente = _vigente(runs)

        # Un run en vuelo (queued/in_progress) MAS NUEVO que el ultimo completado es el
        # CI que esta corriendo ahora: manda el, y todavia no hay veredicto.
        if _en_vuelo(runs, vigente) is not None:
            pendientes.append((nombre, "corriendo"))
            continue

        if vigente is None:
            pendientes.append((nombre, "sin veredicto"))
            continue

        conclusion = _conclusion(vigente)
        if conclusion in CHECK_OK:
            continue
        if conclusion in CHECK_ROJOS:
            rojos.append((nombre, conclusion))
            continue
        if conclusion in ("cancelled", "stale"):
            # Run superseded. Si hay un gemelo en verde creado despues, ese gana (es el run
            # nuevo del mismo check); si no, no hay veredicto todavia -> pendiente.
            gemelo = max((r for r in runs
                          if _id(r) > _id(vigente) and _conclusion(r) in CHECK_OK),
                         key=_id, default=None)
            if gemelo is not None:
                continue
            pendientes.append((nombre, conclusion))
            continue
        # conclusion desconocida: no se la da por buena
        pendientes.append((nombre, conclusion or "sin conclusion"))

    return rojos, pendientes


def check_ci_verde(check_runs):
    """(bool, detalle): True solo si el CI de GitHub del HEAD SHA esta VERDE.

    Es el requisito ADICIONAL del gate local para promover un PR a ready: el gate local
    sigue siendo el que decide, pero un PR con el CI de upstream en rojo no se puede
    mergear, asi que no se promueve. Acepta la lista de check-runs (puro, testeable
    offline); la version que habla con GitHub es check_ci_verde_sha().
    """
    estado, detalle = evaluar_check_runs(check_runs)
    return estado == VERDE, detalle


def fetch_check_runs(sha, repo=REPO):
    """Los check-runs del HEAD SHA, uno por linea en JSON. (runs, error)"""
    if not sha:
        return [], "no se pudo leer el HEAD SHA"
    ruta = f"repos/{repo}/commits/{sha}/check-runs"
    rc, raw, err = gh_run("api", ruta, "--paginate", "--jq",
                          ".check_runs[] | {name,status,conclusion,completed_at,"
                          "started_at,id}", timeout=180)
    if rc != 0:
        return [], f"'gh api {ruta}' fallo: rc={rc}: {recortar(err)}"
    runs = []
    for linea in (raw or "").splitlines():
        linea = linea.strip()
        if not linea:
            continue
        try:
            runs.append(json.loads(linea))
        except json.JSONDecodeError:
            continue
    return runs, None


def check_ci_verde_sha(sha, repo=REPO):
    """(bool, detalle): el CI de GitHub del HEAD SHA, leido de GitHub."""
    runs, error = fetch_check_runs(sha, repo)
    if error:
        return False, f"no pude leer los check-runs: {error}"
    return check_ci_verde(runs)


# --------------------------------------------------------------------------
# EL GATE ES EL CI DEL FORK (2026-11-21)
#
# POR QUE: el gate local (bin/gate.sh -> gate-quick.sh del loop) dio un ROJO
# FALSO en el PR #20017 (nextest con --ignore-default-filter y
# SOLIDCRAFT_REQUIRE_GPU=1, contra un baseline de 18 dias) mientras el
# "Native Linux tests" de upstream pasaba sobre el MISMO head. Y compila 5-7
# paquetes durante 30+ minutos y llena los 15 GB de la caja. El CONTRIBUTING
# de upstream dice como ver el CI completo sin esperar el label: correrlo en
# el fork, en los runners gratis de GitHub, con las variables CI_RUNNER y
# CI_RUNNER_WINDOWS del fork y `gh workflow run ci.yml --ref <rama>
# -f cross_compile=true -R <fork>`. Ese run corre los jobs del merge queue:
# el juez es el que va a usar el merge, no una receta nuestra.
#
# Un push a una rama que no es main NO arranca el CI en el fork (ci.yml solo
# escucha push a main y develop, y el pull_request corre en upstream): el run
# hay que DESPACHARLO. El run usa el ci.yml DE LA RAMA y prueba la punta de la
# rama: por eso se despacha solo si la rama del fork esta en el sha pedido.
#
# EL MODO (GATE_MODE): fork-ci (el default) o local (bin/gate.sh, el camino
# viejo). Se lee del entorno o de $LOOP_DIR/config.env. En los dos modos un
# veredicto local VERDE del head tambien vale: es la alternativa.
#
# cross_compile=true (FORK_CI_CROSS=0 lo apaga): agrega DOS jobs ("Compile
# WebAssembly" y "Compile RISC-V (manual)") a un run de ~55, en un repo
# publico (los minutos de los runners estandar no se cobran) y en paralelo
# al camino critico (los tests nativos y la action matrix, de hasta 3 h con
# CI_RUNNER). Paga: el wasm es un job que el merge queue exige a todo grupo
# que toca los crates de abajo de las apps (casi todos nuestros PRs) y que
# `cargo xtask fast` no corre. El RISC-V viene en el mismo paquete pero el
# merge queue NO lo corre: se informa y no bloquea (FORK_CI_NO_BLOQUEAN).
#
# LA API SE RESPETA: un despacho por sha (la marca local se escribe ANTES del
# efecto y la lista de runs del sha se mira antes de despachar), la lectura
# del pipeline es UNA lista de runs por pasada, y los jobs se leen solo de los
# runs terminados que no son un verde limpio (los de un run terminado no
# cambian: se guardan en $ORCH_DIR/gates/fork-ci/).
# --------------------------------------------------------------------------
GATE_MODES = ("fork-ci", "local")
GATE_MODE_DEFAULT = "fork-ci"


def _entero_env(nombre, default):
    """Un entero del entorno; un valor que no es un entero no rompe el cron."""
    try:
        return int((os.environ.get(nombre) or "").strip() or default)
    except ValueError:
        return int(default)


FORK_CI_WORKFLOW = os.environ.get("FORK_CI_WORKFLOW", "ci.yml")
FORK_CI_CROSS = (os.environ.get("FORK_CI_CROSS", "1").strip() != "0")
# Dos runs a la vez: el plan gratis de GitHub corre 20 jobs a la vez y un run
# del fork tiene ~55; con mas de dos en vuelo los runs se esperan entre ellos
# y ninguno termina antes.
FORK_CI_MAX_INFLIGHT = _entero_env("FORK_CI_MAX_INFLIGHT", 2)
# Cuanto se espera a que aparezca el run de un despacho antes de darlo por
# perdido (la API tarda unos segundos en listarlo).
FORK_CI_GRACE_S = _entero_env("FORK_CI_GRACE_S", 900)
# Un run en vuelo de la MISMA rama con OTRO sha prueba un commit viejo, y el
# grupo de concurrencia de ci.yml (ci-<evento>-<ref>, sin cancel-in-progress
# para un despacho) hace que el run nuevo lo ESPERE: horas. Se cancela.
FORK_CI_CANCEL_STALE = (os.environ.get("FORK_CI_CANCEL_STALE", "1").strip() != "0")
# Bajo gates/ (que .gitignore ya deja afuera): ORCH_DIR es este repo en la caja.
FORK_CI_DIR = f"{ORCH}/gates/fork-ci"
# Los jobs que el merge queue NO corre: se informan, no bloquean.
FORK_CI_NO_BLOQUEAN = ("Compile RISC-V (manual)", "Nightly alert")
NINGUNO = "ninguno"
DESCONOCIDO = "desconocido"
RE_SHA_HEX = re.compile(r"^[0-9a-fA-F]{7,40}$")
RE_RAMA = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")


def valor_config(path, clave):
    """El valor de CLAVE en un config.env de shell ('' si no esta). Gana la ultima."""
    valor = ""
    texto = _leer(path)
    if not texto:
        return ""
    patron = re.compile(r"^\s*(?:export\s+)?" + re.escape(clave) + r"=(.*)$")
    for linea in texto.splitlines():
        m = patron.match(linea)
        if not m:
            continue
        v = m.group(1).strip()
        if v[:1] in ("'", '"'):
            cierre = v.find(v[0], 1)
            v = v[1:cierre] if cierre > 0 else v[1:]
        else:
            v = re.split(r"\s+#", v, maxsplit=1)[0].strip()
        valor = v
    return valor


def leer_gate_mode(environ=None, config=None):
    """(modo, origen): el modo del gate. El entorno gana, despues config.env, despues fork-ci.

    Un valor que no es ninguno de los dos modos NO se adivina: se usa el
    default y el origen lo dice (el log del cron lo muestra).
    """
    env = os.environ if environ is None else environ
    valor = (env.get("GATE_MODE") or "").strip()
    origen = "el entorno"
    if not valor:
        config = config or f"{LOOP_DIR}/config.env"
        valor = valor_config(config, "GATE_MODE")
        origen = config
    if not valor:
        return GATE_MODE_DEFAULT, "el default"
    if valor not in GATE_MODES:
        return GATE_MODE_DEFAULT, f"el default: GATE_MODE={valor!r} de {origen} no es un modo"
    return valor, origen


def gate_local_verde(v):
    """True si el veredicto LOCAL (verdict_for) es un verde.

    Un VERDICT que empieza con ROJO o que es SKIP NUNCA es verde (2026-11-21):
    antes bastaba GATE_STATUS=finished con NEW_FAILURES vacio o 0, y un
    ROJO-SCOPE por fmt:fail (sin tests rotos, NEW_FAILURES=0) contaba como
    verde. Solo un veredicto sin VERDICT (el formato viejo) cae en esa regla.
    """
    if not v:
        return False
    veredicto = (v.get("verdict") or "").strip().upper()
    if veredicto.startswith("VERDE"):
        return True
    if veredicto:
        return False
    return v.get("status") == "finished" and (v.get("new_failures") or "") == "0"


def _api_json(ruta, paginar=False, timeout=120, metodo=None):
    """(datos, error) de 'gh api RUTA'. paginar: --paginate --slurp (una lista de paginas)."""
    args = ["api", ruta]
    if metodo:
        args += ["-X", metodo]
    if paginar:
        args += ["--paginate", "--slurp"]
    rc, raw, err = gh_run(*args, timeout=timeout)
    if rc != 0:
        return None, f"'gh api {ruta}' fallo: rc={rc}: {recortar(err)}"
    if metodo and not (raw or "").strip():
        return {}, None
    try:
        return json.loads(raw or "null"), None
    except json.JSONDecodeError as exc:
        return None, f"'gh api {ruta}' no respondio JSON: {exc}"


_CAMPOS_RUN = ("id", "status", "conclusion", "html_url", "head_sha", "head_branch",
               "event", "created_at", "updated_at", "run_attempt")
_CAMPOS_JOB = ("id", "name", "status", "conclusion", "started_at", "completed_at",
               "html_url")


def fork_ci_runs(sha=None, repo=FORK):
    """(runs, error): los runs DESPACHADOS (workflow_dispatch) de ci.yml en el fork.

    Con un sha de 40 se le pide a la API solo ese sha; sin sha (o con uno
    corto, que la API no acepta) son los 100 mas nuevos y el filtro se hace
    aca. El filtro del evento tambien se vuelve a aplicar aca: el de la API no
    es el de la regla.
    """
    ruta = (f"repos/{repo}/actions/workflows/{FORK_CI_WORKFLOW}/runs"
            f"?event=workflow_dispatch&per_page=100")
    if sha and len(sha) == 40 and RE_SHA_HEX.match(sha):
        ruta += f"&head_sha={sha}"
    data, error = _api_json(ruta)
    if error:
        return None, error
    if not isinstance(data, dict) or not isinstance(data.get("workflow_runs"), list):
        return None, f"'gh api {ruta}' no trajo workflow_runs"
    runs = []
    for r in data["workflow_runs"]:
        if not isinstance(r, dict):
            continue
        if (r.get("event") or "workflow_dispatch") != "workflow_dispatch":
            continue
        if sha and not same_sha(r.get("head_sha") or "", sha):
            continue
        runs.append({k: r.get(k) for k in _CAMPOS_RUN})
    return runs, None


def fork_ci_jobs(run_id, repo=FORK):
    """(jobs, error): los jobs del ULTIMO intento de un run del fork (filter=latest)."""
    try:
        rid = int(run_id)
    except (TypeError, ValueError):
        return None, f"el id de run {run_id!r} no es un numero"
    ruta = f"repos/{repo}/actions/runs/{rid}/jobs?filter=latest&per_page=100"
    data, error = _api_json(ruta, paginar=True, timeout=180)
    if error:
        return None, error
    jobs = []
    for pagina in data if isinstance(data, list) else [data]:
        if not isinstance(pagina, dict):
            continue
        for j in pagina.get("jobs") or []:
            if isinstance(j, dict):
                jobs.append({k: j.get(k) for k in _CAMPOS_JOB})
    return jobs, None


def _jobs_cacheados(run, repo=FORK):
    """(jobs, error) de un run TERMINADO, con su cache en $ORCH_DIR/gates/fork-ci/.

    Los jobs de un run terminado no cambian hasta que alguien lo re-corre, y
    re-correrlo cambia run_attempt y updated_at: esa es la clave.
    """
    clave = f"{_id(run)}-{run.get('run_attempt') or 1}-{run.get('updated_at') or ''}"
    path = f"{FORK_CI_DIR}/jobs-{_id(run)}.json"
    txt = _leer(path) if os.path.isfile(path) else None
    if txt:
        try:
            guardado = json.loads(txt)
            if guardado.get("clave") == clave and isinstance(guardado.get("jobs"), list):
                return guardado["jobs"], None
        except (ValueError, AttributeError):
            pass
    jobs, error = fork_ci_jobs(_id(run), repo)
    if error is None and _status(run) == "completed":
        try:
            os.makedirs(FORK_CI_DIR, exist_ok=True)
            tmp = f"{path}.tmp.{os.getpid()}"
            with open(tmp, "w") as fh:
                json.dump({"clave": clave, "jobs": jobs}, fh)
            os.replace(tmp, path)
        except OSError:
            pass
    return jobs, error


def _nuevo(runs):
    """El run mas nuevo (por created_at, y a igualdad el id mas alto)."""
    return max(runs, key=lambda r: (r.get("created_at") or "", _id(r)))


def evaluar_fork_ci(runs, jobs_por_run):
    """El estado del CI del fork de UN sha. Pura: se testea offline.

    runs: los runs despachados de ese sha. jobs_por_run: {id: [jobs]} de los
    runs cuyos jobs se leyeron. Devuelve un dict con estado (VERDE, ROJO,
    PENDIENTE o NINGUNO), detalle, run (la url del run mas nuevo), fallan (los
    jobs en rojo) e informativos (los rojos que no bloquean).

    LA REGLA ES LA DE evaluar_check_runs: de cada NOMBRE de job manda el mas
    reciente, entre TODOS los runs del sha (un re-despacho con --force que
    pasa le gana al rojo del run anterior). Y con dos guardas propias:
      - mientras el run mas nuevo corre, a lo sumo PENDIENTE (o ROJO si uno de
        SUS jobs ya fallo): los jobs con 'needs' todavia no estan en la lista,
        y un "todos verdes" de los primeros no es el verde del run;
      - el run terminado manda sobre los jobs: un startup_failure no tiene
        jobs, y un 'failure' sin un job rojo que lo explique no es un verde.
    """
    res = {"estado": NINGUNO, "detalle": "el fork no tiene ningun run de ci.yml despachado "
           "para este sha", "run": "", "fallan": [], "informativos": []}
    runs = [r for r in (runs or []) if isinstance(r, dict)]
    if not runs:
        return res
    jobs_por_run = jobs_por_run or {}
    nuevo = _nuevo(runs)
    res["run"] = nuevo.get("html_url") or ""

    def separar(jobs):
        bloquean = [j for j in jobs if (j.get("name") or "") not in FORK_CI_NO_BLOQUEAN]
        info = [j for j in jobs if (j.get("name") or "") in FORK_CI_NO_BLOQUEAN]
        return bloquean, info

    if _status(nuevo) != "completed":
        jobs = jobs_por_run.get(_id(nuevo)) or []
        bloquean, _ = separar(jobs)
        clasificado = clasificar_check_runs(bloquean)
        if clasificado and clasificado[0]:
            res["estado"] = ROJO
            res["fallan"] = sorted(n for n, _ in clasificado[0])
            res["detalle"] = (f"ya fallaron {len(res['fallan'])} job(s) y el run sigue "
                              f"({_status(nuevo)})")
            return res
        terminados = sum(1 for j in jobs if _status(j) == "completed")
        res["estado"] = PENDIENTE
        res["detalle"] = (f"el run sigue ({_status(nuevo) or 'sin estado'}"
                          + (f"; {terminados} de {len(jobs)} jobs terminados" if jobs else "")
                          + ")")
        return res

    concl = _conclusion(nuevo)
    if len(runs) == 1 and _id(nuevo) not in jobs_por_run:
        # El atajo: un solo run, terminado en success, no necesita sus jobs.
        if concl == "success":
            res["estado"] = VERDE
            res["detalle"] = "el run termino en success"
            return res
    todos = []
    for r in runs:
        todos.extend(jobs_por_run.get(_id(r)) or [])
    bloquean, info = separar(todos)
    clasificado_info = clasificar_check_runs(info)
    if clasificado_info:
        res["informativos"] = sorted(n for n, _ in clasificado_info[0])
    clasificado = clasificar_check_runs(bloquean)
    if clasificado is None:
        if concl in CHECK_ROJOS:
            res["estado"] = ROJO
            res["fallan"] = [f"(el run: {concl})"]
            res["detalle"] = f"el run termino en {concl} sin jobs"
        else:
            res["estado"] = PENDIENTE
            res["detalle"] = (f"el run termino en {concl or 'sin conclusion'} sin jobs: "
                              f"no hay veredicto (fork-ci.sh --force lo despacha de nuevo)")
        return res
    rojos, pendientes = clasificado
    if rojos:
        res["estado"] = ROJO
        res["fallan"] = sorted(n for n, _ in rojos)
        res["detalle"] = f"{len(rojos)} job(s) en rojo"
        return res
    if pendientes:
        res["estado"] = PENDIENTE
        res["detalle"] = ("sin veredicto: " + ", ".join(sorted(f"{n} ({m})" for n, m in pendientes))
                          + (" (fork-ci.sh --force lo despacha de nuevo)"
                             if concl == "cancelled" else ""))
        return res
    if concl in CHECK_OK or (concl == "failure" and res["informativos"]):
        res["estado"] = VERDE
        res["detalle"] = (f"{len(bloquean)} jobs en verde"
                          + (f" (no bloquean: {', '.join(res['informativos'])})"
                             if res["informativos"] else ""))
        return res
    if concl in CHECK_ROJOS:
        res["estado"] = ROJO
        res["fallan"] = [f"(el run: {concl})"]
        res["detalle"] = f"el run termino en {concl} sin un job rojo que lo explique"
        return res
    res["estado"] = PENDIENTE
    res["detalle"] = f"el run termino en {concl or 'sin conclusion'}: no es un veredicto"
    return res


def _marca_despacho(sha):
    return f"{FORK_CI_DIR}/{sha}.despacho"


def _edad_marca(sha, path=None):
    """Los segundos desde el despacho de ese sha, o None si no hay marca."""
    try:
        return max(0, int(time.time() - os.path.getmtime(path or _marca_despacho(sha))))
    except OSError:
        return None


# UN DESPACHO RECHAZADO NO SE REINTENTA CADA 5 MINUTOS (2026-11-21).
#
# El primer despacho real (rama fix-19690) volvio con "HTTP 422: Actions has
# been disabled for this repository" aunque actions/permissions decia
# enabled=true: es una condicion de GitHub que no cambia sola. Sin freno, el
# cron reintentaba cada pasada y salia rojo cada cinco minutos, el mismo ruido
# que escondio los avisos de verdad el 20-11-2026 (108 fallos de la cola). El
# rechazo se guarda; durante FORK_CI_ERROR_BACKOFF_S el sha no se despacha (se
# dice en el log en cada pasada) y el exit code cuenta solo el rechazo NUEVO.
FORK_CI_ERROR_BACKOFF_S = _entero_env("FORK_CI_ERROR_BACKOFF_S", 3600)


def _marca_rechazo(sha):
    return f"{FORK_CI_DIR}/{sha}.rechazo"


def rechazo_reciente(sha):
    """(edad, motivo) del ultimo despacho rechazado de ese sha si es reciente; si no, None."""
    path = _marca_rechazo(sha)
    edad = _edad_marca(sha, path)
    if edad is None or edad >= FORK_CI_ERROR_BACKOFF_S:
        return None
    return edad, recortar(_leer(path) or "", 240)


def _escribir_rechazo(sha, motivo):
    try:
        os.makedirs(FORK_CI_DIR, exist_ok=True)
        tmp = f"{_marca_rechazo(sha)}.tmp.{os.getpid()}"
        with open(tmp, "w") as fh:
            fh.write(motivo + "\n")
        os.replace(tmp, _marca_rechazo(sha))
    except OSError:
        pass


def estado_fork_ci(sha, lote=None, con_jobs_en_curso=True, repo=FORK):
    """El estado del CI del fork del sha (el dict de evaluar_fork_ci, con 'sha').

    lote: la lista de runs del fork ya leida (el pipeline la lee UNA vez por
    pasada); sin lote se le pregunta a la API por este sha. Un error de la
    API es DESCONOCIDO, nunca un NINGUNO: un NINGUNO despacha, y despachar a
    ciegas es despachar dos veces.
    """
    if lote is None:
        runs, error = fork_ci_runs(sha, repo)
        if error:
            return {"estado": DESCONOCIDO, "detalle": error, "run": "", "fallan": [],
                    "informativos": [], "sha": sha}
    else:
        runs = [r for r in lote if same_sha(r.get("head_sha") or "", sha)]
    jobs_por_run = {}
    if runs:
        nuevo = _nuevo(runs)
        if _status(nuevo) != "completed":
            if con_jobs_en_curso:
                jobs, error = fork_ci_jobs(_id(nuevo), repo)
                if error is None:
                    jobs_por_run[_id(nuevo)] = jobs
        elif not (len(runs) == 1 and _conclusion(nuevo) == "success"):
            for r in runs:
                jobs, error = _jobs_cacheados(r, repo)
                if error:
                    return {"estado": DESCONOCIDO, "detalle": error,
                            "run": nuevo.get("html_url") or "", "fallan": [],
                            "informativos": [], "sha": sha}
                jobs_por_run[_id(r)] = jobs
    res = evaluar_fork_ci(runs, jobs_por_run)
    res["sha"] = sha
    if res["estado"] == NINGUNO:
        edad = _edad_marca(sha)
        rechazo = rechazo_reciente(sha)
        if edad is not None and edad < FORK_CI_GRACE_S:
            res["estado"] = PENDIENTE
            res["detalle"] = f"despachado hace {edad}s: el run todavia no aparece en la API"
        elif rechazo is not None:
            res["detalle"] = (f"no hay run: GitHub rechazo el despacho hace {rechazo[0]}s "
                              f"({rechazo[1]})")
    return res


def fork_rama_head(rama, repo=FORK):
    """(sha, error, no_existe): la punta de la rama en el fork."""
    ruta = f"repos/{repo}/git/ref/heads/{rama}"
    rc, raw, err = gh_run("api", ruta)
    if rc != 0:
        no_existe = bool(re.search(r"(?i)not found|HTTP 404", err or ""))
        return "", f"'gh api {ruta}' fallo: rc={rc}: {recortar(err)}", no_existe
    try:
        data = json.loads(raw or "null")
    except json.JSONDecodeError as exc:
        return "", f"'gh api {ruta}' no respondio JSON: {exc}", False
    sha = ((data or {}).get("object") or {}).get("sha") if isinstance(data, dict) else ""
    if not sha:
        # Con un prefijo la API devuelve una LISTA de refs: no es esta rama.
        return "", f"la rama {rama} no esta en el fork", True
    return sha, None, False


def _tomar_marca(sha):
    """True si esta pasada se quedo con el despacho de ese sha (O_EXCL: uno solo gana)."""
    try:
        os.makedirs(FORK_CI_DIR, exist_ok=True)
    except OSError:
        return False
    path = _marca_despacho(sha)
    edad = _edad_marca(sha)
    if edad is not None and edad >= FORK_CI_GRACE_S:
        try:
            os.remove(path)
        except OSError:
            pass
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    except FileExistsError:
        return False
    except OSError:
        return False
    with os.fdopen(fd, "w") as fh:
        fh.write(f"sha={sha} at={time.strftime('%Y-%m-%dT%H:%M:%S')} pid={os.getpid()}\n")
    return True


# Los resultados de un despacho y su codigo de salida (bin/fork-ci.sh).
DESPACHO_RC = {"DESPACHADO": 0, "YA_HAY_RUN": 0, "ESPERANDO_RUN": 0, "ERROR": 1,
               "RECHAZADO": 1,
               "RAMA_MOVIDA": 4, "RAMA_NO_EXISTE": 4, "OCUPADO": 5, "DESCONOCIDO": 6,
               "USO": 64}


def despachar_fork_ci(rama, sha, forzar=False, cruzado=None, esperar_url=False,
                      repo=FORK):
    """Despacha ci.yml en el fork para la punta de RAMA, que tiene que ser SHA.

    Devuelve un dict: accion (una clave de DESPACHO_RC), detalle, run, sha.
    Es idempotente por sha: un sha que ya tiene un run (en vuelo o
    terminado) no se vuelve a despachar sin forzar, y la marca local se
    escribe ANTES del despacho (el run tarda en aparecer en la API).
    """
    cruzado = FORK_CI_CROSS if cruzado is None else cruzado
    out = {"accion": "USO", "detalle": "", "run": "", "sha": sha or "", "rama": rama or ""}
    if not rama or not RE_RAMA.match(rama) or ".." in rama or rama.startswith("-"):
        out["detalle"] = f"la rama {rama!r} no es un nombre de rama"
        return out
    if not sha or not RE_SHA_HEX.match(sha):
        out["detalle"] = f"el sha {sha!r} no es un sha"
        return out
    rechazo = None if forzar else rechazo_reciente(sha)
    if rechazo is not None:
        out["accion"] = "RECHAZADO"
        out["detalle"] = (f"GitHub rechazo el despacho hace {rechazo[0]}s ({rechazo[1]}); "
                          f"se reintenta pasados {FORK_CI_ERROR_BACKOFF_S}s o con --force")
        return out
    head, error, no_existe = fork_rama_head(rama, repo)
    if error:
        out["accion"] = "RAMA_NO_EXISTE" if no_existe else "DESCONOCIDO"
        out["detalle"] = error
        return out
    if not same_sha(head, sha):
        out["accion"] = "RAMA_MOVIDA"
        out["detalle"] = (f"la rama {rama} del fork esta en {head[:12]}, no en {sha[:12]}: "
                          f"el run probaria otro commit")
        return out
    sha = head
    out["sha"] = sha
    runs, error = fork_ci_runs(sha, repo)
    if error:
        out["accion"], out["detalle"] = "DESCONOCIDO", error
        return out
    if runs and not forzar:
        nuevo = _nuevo(runs)
        out["accion"] = "YA_HAY_RUN"
        out["run"] = nuevo.get("html_url") or ""
        out["detalle"] = (f"el sha ya tiene {len(runs)} run(s); el mas nuevo esta "
                          f"{_status(nuevo)} {_conclusion(nuevo)}".rstrip())
        return out
    edad = _edad_marca(sha)
    if edad is not None and edad < FORK_CI_GRACE_S and not forzar:
        out["accion"] = "ESPERANDO_RUN"
        out["detalle"] = f"despachado hace {edad}s: el run todavia no aparece en la API"
        return out
    lote, error = fork_ci_runs(None, repo)
    if error:
        out["accion"], out["detalle"] = "DESCONOCIDO", error
        return out
    en_vuelo = [r for r in lote if _status(r) != "completed"]
    cancelados = set()
    if FORK_CI_CANCEL_STALE:
        for r in en_vuelo:
            if (r.get("head_branch") or "") == rama and not same_sha(r.get("head_sha") or "", sha):
                _, err_c = _api_json(f"repos/{repo}/actions/runs/{_id(r)}/cancel", metodo="POST")
                if err_c is None:
                    cancelados.add(_id(r))
                    log(f"  fork-ci: cancelado el run {_id(r)} de {rama} "
                        f"({(r.get('head_sha') or '')[:12]}): su commit ya no es la punta")
    otros = [r for r in en_vuelo if _id(r) not in cancelados]
    if len(otros) >= FORK_CI_MAX_INFLIGHT and not forzar:
        out["accion"] = "OCUPADO"
        out["detalle"] = (f"ya hay {len(otros)} run(s) del fork en vuelo (tope "
                          f"FORK_CI_MAX_INFLIGHT={FORK_CI_MAX_INFLIGHT}): se despacha despues")
        return out
    if forzar:
        try:
            os.remove(_marca_despacho(sha))
        except OSError:
            pass
    if not _tomar_marca(sha):
        out["accion"] = "ESPERANDO_RUN"
        out["detalle"] = "otro proceso acaba de despachar este sha"
        return out
    args = ["workflow", "run", FORK_CI_WORKFLOW, "--ref", rama, "-R", repo]
    if cruzado:
        args += ["-f", "cross_compile=true"]
    rc, salida, err = gh_run(*args, timeout=120)
    if rc != 0:
        try:
            os.remove(_marca_despacho(sha))
        except OSError:
            pass
        out["accion"] = "ERROR"
        out["detalle"] = f"'gh {' '.join(args)}' fallo: rc={rc}: {recortar(err)}"
        _escribir_rechazo(sha, out["detalle"])
        return out
    try:
        os.remove(_marca_rechazo(sha))
    except OSError:
        pass
    out["accion"] = "DESPACHADO"
    out["detalle"] = (f"ci.yml despachado en {repo} para {rama} "
                      f"(cross_compile={'true' if cruzado else 'false'})")
    if esperar_url:
        # El run tarda unos segundos en aparecer: el CLI espera su url un rato
        # (FORK_CI_POLL_S entre lecturas; 0 en los tests).
        for _ in range(6):
            time.sleep(max(0, _entero_env("FORK_CI_POLL_S", 5)))
            runs, error = fork_ci_runs(sha, repo)
            if runs:
                out["run"] = _nuevo(runs).get("html_url") or ""
                break
    return out


# Los estados del CI del fork y su codigo de salida (bin/fork-ci.sh --status).
ESTADO_RC = {VERDE: 0, ROJO: 1, PENDIENTE: 2, NINGUNO: 3, DESCONOCIDO: 6}


def linea_fork_ci(res):
    """La linea de estado: FORKCI=... SHA=... RUN=... FALLAN=... (FALLAN al final:
    los nombres de los jobs llevan espacios)."""
    return (f"FORKCI={res['estado'].upper()} SHA={res.get('sha') or ''} "
            f"RUN={res.get('run') or ''} FALLAN={','.join(res.get('fallan') or [])}")


def _pr_del_issue(issue):
    """(rama, sha, numero, error, ilegible): nuestro PR abierto de ese issue (el de
    numero mas bajo). ilegible=True: la lista no se pudo leer (no es un 'no hay')."""
    prs, error = listar_prs()
    if error:
        return "", "", None, error, True
    candidatos = [p for p in prs if issue_of(p.get("title"), p.get("body")) == str(issue)]
    if not candidatos:
        return "", "", None, f"no hay un PR abierto nuestro para el issue #{issue}", False
    pr = min(candidatos, key=lambda p: p.get("number") or 0)
    return (pr.get("headRefName") or "", pr.get("headRefOid") or "", pr.get("number"),
            None, False)


USO_FORK_CI = """uso: bash bin/fork-ci.sh <issue|rama> [--sha SHA] [--status] [--force] [--no-cross]
       bash bin/fork-ci.sh --status --sha SHA
       bash bin/fork-ci.sh --branch RAMA [--sha SHA] [--status]
  sin --status despacha ci.yml en el fork para la rama (una vez por sha);
  --status imprime FORKCI=VERDE|ROJO|PENDIENTE|NINGUNO SHA=... RUN=... FALLAN=...
  salida de --status: 0 VERDE, 1 ROJO, 2 PENDIENTE, 3 NINGUNO, 4 no hay PR/rama, 6 no se pudo leer
  salida del despacho: 0 despachado o ya tenia run, 1 el despacho fallo (o fallo hace
  menos de FORK_CI_ERROR_BACKOFF_S: no se reintenta sin --force), 4 la rama no esta
  en ese sha, 5 tope de runs en vuelo, 6 no se pudo leer, 64 uso"""


def fork_ci_cli(argv):
    """El CLI de bin/fork-ci.sh. Devuelve el codigo de salida."""
    objetivo = rama = sha = ""
    estado = forzar = False
    cruzado = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            print(USO_FORK_CI)
            return 0
        if a == "--status":
            estado = True
        elif a == "--force":
            forzar = True
        elif a == "--no-cross":
            cruzado = False
        elif a in ("--sha", "--branch"):
            if i + 1 >= len(argv):
                print(f"fork-ci: {a} necesita un valor\n{USO_FORK_CI}", file=sys.stderr)
                return 64
            if a == "--sha":
                sha = argv[i + 1].strip()
            else:
                rama = argv[i + 1].strip()
            i += 1
        elif a.startswith("-"):
            print(f"fork-ci: opcion desconocida {a}\n{USO_FORK_CI}", file=sys.stderr)
            return 64
        elif not objetivo:
            objetivo = a.strip()
        else:
            print(f"fork-ci: sobra el argumento {a}\n{USO_FORK_CI}", file=sys.stderr)
            return 64
        i += 1
    if sha and not RE_SHA_HEX.match(sha):
        print(f"fork-ci: el sha {sha!r} no es un sha", file=sys.stderr)
        return 64
    if objetivo and not rama:
        if objetivo.isdigit():
            rama, sha_pr, num, error, ilegible = _pr_del_issue(objetivo)
            if error:
                print(f"fork-ci: {error}", file=sys.stderr)
                return 6 if ilegible else 4
            print(f"fork-ci: el issue #{objetivo} es el PR #{num} (rama {rama})", file=sys.stderr)
            sha = sha or sha_pr
        else:
            rama = objetivo
    if not rama and not (estado and sha):
        print(USO_FORK_CI, file=sys.stderr)
        return 64
    if rama and (not RE_RAMA.match(rama) or ".." in rama or rama.startswith("-")):
        print(f"fork-ci: la rama {rama!r} no es un nombre de rama", file=sys.stderr)
        return 64
    if not sha:
        head, error, no_existe = fork_rama_head(rama)
        if error:
            print(f"fork-ci: {error}", file=sys.stderr)
            return 4 if no_existe else 6
        sha = head
    if estado:
        res = estado_fork_ci(sha)
        print(linea_fork_ci(res), flush=True)
        print(f"fork-ci: {res['detalle']}", file=sys.stderr)
        if res.get("informativos"):
            print(f"fork-ci: en rojo pero no bloquean: {', '.join(res['informativos'])}",
                  file=sys.stderr)
        return ESTADO_RC.get(res["estado"], 6)
    res = despachar_fork_ci(rama, sha, forzar=forzar, cruzado=cruzado, esperar_url=True)
    print(f"FORKCI_DESPACHO={res['accion']} SHA={res['sha']} RAMA={res['rama']} "
          f"RUN={res['run']}", flush=True)
    print(f"fork-ci: {res['detalle']}", file=sys.stderr)
    return DESPACHO_RC.get(res["accion"], 1)


# --------------------------------------------------------------------------
# LA LINEA "Changes a default:" (2026-11-07)
#
# El CI de upstream (scripts/pr-checks/pr-checks.js) exige una linea
#   "Changes a default: no"
# o la larga
#   "Changes a default: yes - <que>, old behaviour kept behind preference <nombre>"
# La linea que ya esta en el body es informacion DEL AUTOR: no se pisa nunca (un "yes"
# pisado con un "no" es mentira, y el mantenedor lo va a marcar).
# Y si la linea NO esta, este script NO la inventa con un "no" automatico: un PR que mete
# una preferencia nueva SI cambia un default, y un "no" mentido pasa el check de upstream
# y despues lo hace volver. Se deja el PR en draft y se loguea que la linea hay que
# escribirla a mano.
# --------------------------------------------------------------------------

RE_LINEA_DEFAULTS = re.compile(r"^[ \t]*(?:[-*][ \t]+)?Changes a default:", re.I | re.M)
RE_MENCIONA_DEFAULT = re.compile(
    r"\b(defaults?|preferencias?|preferences?|valores? por defecto)\b", re.I)
LABEL_CHANGES_DEFAULT = "changes-default"

# El ruido que upstream ignora antes de mirar la linea (scripts/pr-checks/pr-checks.js,
# stripNoise): los comentarios HTML y los bloques de codigo. Una linea de ejemplo dentro de
# un bloque de codigo NO es una declaracion: si la pipeline la creyera presente, dejaria
# pasar un PR que el check de upstream va a rechazar.
RE_COMENTARIO_HTML = re.compile(r"<!--[\s\S]*?-->")
RE_BLOQUE_CODIGO = re.compile(r"```[\s\S]*?```|~~~[\s\S]*?~~~")
RE_CODIGO_EN_LINEA = re.compile(r"`[^`\n]*`")


def strip_noise(body, inline_code=True):
    """El body sin el ruido que upstream ignora (comentarios y bloques de codigo)."""
    text = str(body or "")
    text = RE_COMENTARIO_HTML.sub("", text)
    text = RE_BLOQUE_CODIGO.sub("", text)
    if inline_code:
        text = RE_CODIGO_EN_LINEA.sub("", text)
    return text


# --------------------------------------------------------------------------
# EL ISSUE DE UN PR (2026-11-17)
#
# De donde sale el issue, en este orden:
#   1. un verbo de CIERRE real en el body ('Fixes #12', 'Closes #12',
#      'Resolves #12'). Es lo que cierra el issue, y es lo que leen el bot de
#      upstream (scripts/pr-checks/pr-checks.js, parseClosing) y el bot del
#      claim (scripts/claim/claim.js).
#   2. el issue del TITULO ('<summary> (#12)'): es el contrato del claim
#      (RULES.md: el bot lee '#N' en el titulo).
#   3. una REFERENCIA que no cierra ('Addresses #12', 'Refs #12').
#
# NUNCA de un '#numero' suelto: un '#3' en un bloque de codigo, en un heading
# o en un issue citado de paso NO es el issue del PR. El pipeline antes tomaba
# ese numero y lo escribia en el body de un PR publico ('Addresses #3'), o sea
# publicaba un numero que el autor nunca dijo.
#
# Y la distincion 'cierra' vs 'menciona' es la de bin/verify-pr.sh: un body
# que solo MENCIONA el issue puede ser un fix parcial, y escribirle
# 'Fixes #N' le cerraria un issue al autor por sorpresa.
# --------------------------------------------------------------------------

# Un verbo de cierre REAL: el '#' es obligatorio (como en el parser de upstream:
# 'fix 3 problems' no cierra nada).
RE_CIERRE = re.compile(
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?[ \t]+#(\d{1,7})\b", re.I)
# Una referencia que NO cierra el issue.
RE_REFERENCIA = re.compile(
    r"\b(?:addresses|refs?|see|part of|related to|follows up)\b:?[ \t]+#(\d{1,7})\b",
    re.I)
# Cualquier numero de issue mencionado en el texto.
RE_NUMERO = re.compile(r"#(\d{1,7})\b")
# El issue del titulo: '<summary> (#12)'.
RE_TITULO_PAREN = re.compile(r"\(#(\d{1,7})\)\s*$")
# O cualquier '#12' del titulo (la misma regla que el bot de upstream).
RE_TITULO_CUALQUIERA = re.compile(r"(?:^|[\s(])#(\d{1,7})\b")


def issue_del_titulo(title):
    """El issue del titulo del PR: '<summary> (#12)'."""
    m = RE_TITULO_PAREN.search(title or "")
    if m:
        return m.group(1)
    m = RE_TITULO_CUALQUIERA.search(title or "")
    return m.group(1) if m else None


def issue_de_cierre(body):
    """El issue que el body CIERRA ('Fixes #12'). None si no cierra ninguno."""
    m = RE_CIERRE.search(strip_noise(body))
    return m.group(1) if m else None


def issue_referenciado(body):
    """El issue que el body solo MENCIONA ('Addresses #12', 'Refs #12')."""
    m = RE_REFERENCIA.search(strip_noise(body))
    return m.group(1) if m else None


def menciona_issue(body):
    """True si el body menciona ALGUN numero de issue ('#12'), aunque sea de paso.

    El cuerpo NO se limpia del ruido: un '#12' dentro de un bloque de codigo
    tambien es una mencion. Ante la duda, el estado por defecto es 'no se
    toco el body del autor' (no se le cierra un issue por sorpresa).
    """
    return bool(RE_NUMERO.search(body or ""))


def titulo_sin_numero(title):
    """El titulo de un PR listo: sin el " (#N)" del final que lleva el draft del claim."""
    return re.sub(r"\s*\(#\d+\)\s*$", "", title or "").strip()


def reparar_body(body, title):
    """El body con la referencia al issue que le falta, o None si no hay que tocarlo.

    Solo se repara un body que NO menciona ningun issue. Lo que se escribe es
    'Fixes #N' (el contrato del claim: RULES.md pide 'Fixes #N' en el body),
    no 'Addresses #N' (que no cierra nada).
    """
    if menciona_issue(body):
        return None
    iss = issue_del_titulo(title)
    if not iss:
        return None
    base = (body or "").rstrip()
    return f"{base}\n\nFixes #{iss}\n" if base else f"Fixes #{iss}\n"


# El resumen que CodeRabbit pega al final del body: no es del autor del PR y menciona
# 'default' en casi todos los cuerpos, asi que no sirve para saber si el PR toca un default.
RE_CODERABBIT = re.compile(
    r"<!--\s*This is an auto-generated comment.*?end of auto-generated comment.*?-->",
    re.S | re.I)


def cuerpo_del_autor(body):
    """El body que escribio el autor, sin el ruido ni el resumen de CodeRabbit.

    Ademas saca la propia linea 'Changes a default:': esa linea DECLARA si el PR toca un
    default, asi que no puede usarse como evidencia de que el PR habla de defaults.
    """
    texto = RE_CODERABBIT.sub("", str(body or ""))
    texto = RE_LINEA_DEFAULTS.sub("", texto)
    return strip_noise(texto, inline_code=True)


def linea_defaults_presente(body):
    """True si el body YA trae la linea 'Changes a default:' (la que sea).

    Mismo criterio que upstream (parseDefaults): sobre el body sin ruido, una linea que
    empiece con 'Changes a default:'. Una linea existente nunca se reescribe.
    """
    return bool(RE_LINEA_DEFAULTS.search(strip_noise(body, inline_code=False)))


# El formato que upstream (scripts/pr-checks/pr-checks.js) acepta: "no" o la forma larga
# "yes <—|–|->|→|-{1,2}|:> <que>, old behaviour kept behind (preference|pref|setting) <nombre>".
RE_DEFAULTS_VALOR = re.compile(
    r"^[ \t]*(?:[-*][ \t]+)?Changes a default:[ \t]*(.*?)[ \t]*$", re.I | re.M)
RE_DEFAULTS_NO = re.compile(r"^no\.?$", re.I)
RE_DEFAULTS_YES = re.compile(r"^yes\b[ \t]*(?:—|–|->|→|-{1,2}|:)[ \t]*(.+)$", re.I)
RE_DEFAULTS_PREF = re.compile(
    r"^(.*?)[ ,;]*\bold (?:behaviou?r|value) kept behind "
    r"(?:preference|pref|setting)[ \t]+`?([\w.:/-]+)`?\.?$", re.I)
RE_PLACEHOLDER = re.compile(r"^<.*>$")


def linea_defaults_malformada(body):
    """True si la linea 'Changes a default:' existe pero NO matchea el formato de upstream.

    Con la linea mal formada el check de upstream falla igual: avisarlo en el log es
    mejor que esperar a ver el PR en rojo.
    """
    m = RE_DEFAULTS_VALOR.search(strip_noise(body, inline_code=False))
    if not m:
        return False
    valor = m.group(1).replace("**", "").strip()
    if RE_DEFAULTS_NO.match(valor):
        return False
    yes = RE_DEFAULTS_YES.match(valor)
    if yes:
        pref = RE_DEFAULTS_PREF.match(yes.group(1))
        if pref and pref.group(1).strip() and not RE_PLACEHOLDER.match(pref.group(2)):
            return False
    return True


def habla_de_defaults(*textos):
    """True si alguno de los textos menciona un default o una preferencia: ahi, un 'no'
    automatico es informacion falsa."""
    for texto in textos:
        if texto and RE_MENCIONA_DEFAULT.search(cuerpo_del_autor(texto)):
            return True
    return False


def labels_de(pr):
    """Los nombres de etiqueta de un PR (los devuelve 'gh pr list --json labels')."""
    names = []
    for l in (pr.get("labels") or []):
        if isinstance(l, dict):
            names.append(l.get("name") or "")
        elif isinstance(l, str):
            names.append(l)
    return names


def contar_ci(conteo, rojos, pendientes, num, estado):
    """Suma el estado del CI de un PR al resumen: lo que al mantenedor le importa para
    decidir a quien pinguear."""
    conteo[estado] = conteo.get(estado, 0) + 1
    if estado == ROJO:
        rojos.append(num)
    elif estado == PENDIENTE:
        pendientes.append(num)


# EL COMPARADOR DE SHAs (2026-11-17): el mismo que bin/gate.sh.
#
# Dos SHAs son el mismo commit cuando uno es el prefijo del otro y el prefijo
# tiene al menos 7 chars: un SHA de 7 chars es el prefijo de MUCHOS commits.
# El gate escribe el SHA que le pasaron (a veces corto: en los veredictos del
# disco hay SHAs de 9 chars) y la API da el head completo (40 chars). Con la
# comparacion exacta el veredicto no se encuentra NUNCA y el PR no llega
# nunca a ready.
MIN_SHA = 7


def same_sha(a, b):
    """True si a y b son el mismo commit (uno es el prefijo del otro)."""
    if not a or not b:
        return False
    if a == b:
        return True
    if len(b) >= MIN_SHA and a.startswith(b):
        return True
    if len(a) >= MIN_SHA and b.startswith(a):
        return True
    return False


def _leer(path):
    """El contenido de un archivo, o None si no se pudo leer."""
    try:
        with open(path, errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def _sha_del_verdicto(txt):
    """El valor de 'SHA=' de un veredicto (la primera linea que lo trae)."""
    m = re.search(r"^SHA=(.*)$", txt or "", re.M)
    return m.group(1).strip() if m else ""


def verdict_for(sha):
    """El veredicto de gate de ese SHA, buscado en todos los slots por SHA (no por nombre).

    El SHA del veredicto y el del PR no siempre tienen la misma longitud: se
    comparan como PREFIJO (same_sha, como en bin/gate.sh).
    """
    if not sha:
        return None
    for slot in sorted(os.listdir(GATES)) if os.path.isdir(GATES) else []:
        f = f"{GATES}/{slot}/scope.verdict"
        if not os.path.isfile(f):
            continue
        crudo = f
        txt = _leer(f)
        if txt is None:
            continue
        if not same_sha(_sha_del_verdicto(txt), sha):
            continue
        # el veredicto EFECTIVO es el que cuenta: el crudo sale ROJO por los fallos
        # preexistentes de origin/main. gate-baseline.sh lo deja al lado.
        ef = f.replace("scope.verdict", "scope.effective.verdict")
        etxt = _leer(ef) if os.path.isfile(ef) else None
        if etxt and same_sha(_sha_del_verdicto(etxt), sha):
            txt = etxt
            crudo = ef
        def grab(key, default=""):
            m = re.search(rf"^{key}=(.*)$", txt, re.M)
            return m.group(1).strip() if m else default
        status = grab("GATE_STATUS")
        if not status:
            # el efectivo puede no traer GATE_STATUS: se hereda del crudo
            crudo_txt = _leer(crudo) or ""
            m = re.search(r"^GATE_STATUS=(.*)$", crudo_txt, re.M)
            status = m.group(1).strip() if m else ""
        return {
            "slot": slot,
            "status": status,
            "verdict": grab("VERDICT"),
            "new_failures": grab("NEW_FAILURES"),
            "preexisting": grab("PREEXISTING_FAILURES"),
            "path": f,
        }
    return None


def enqueued_issues():
    out = set()
    if os.path.isfile(QUEUE):
        for line in open(QUEUE, errors="replace"):
            parts = line.split()
            if parts:
                out.add(parts[0])
    return out


# --------------------------------------------------------------------------
# LA LISTA DE PRs (2026-11-17)
#
# La lista sale de la API paginada, no de 'gh pr list --limit 30': ese limite
# hacia invisibles los PRs pasados del #30 (para el pipeline y para el
# resumen), y 'gh pr list' ademas corta en 500 y deja pasar algunos
# (prompts/wave-prompt.md: hay que paginar con 'gh api --paginate').
#
# 'gh api --paginate --slurp' devuelve un ARRAY DE ARRAYS (una pagina por
# elemento) y la API no filtra por autor: el filtro se hace aca.
# --------------------------------------------------------------------------
def _aplanar(paginas):
    """Una lista de paginas (o una pagina) en una sola lista de PRs."""
    out = []
    for pagina in paginas if isinstance(paginas, list) else [paginas]:
        if isinstance(pagina, list):
            out.extend(pagina)
        elif isinstance(pagina, dict):
            out.append(pagina)
    return out


def _normalizar_pr(p):
    """Un PR con los mismos campos que usaba 'gh pr list --json'.

    It accepts the two shapes: the one of `gh pr list --json` (author,
    headRefOid, isDraft) and the one of the API (user, head.sha, draft).
    """
    head = p.get("head") or {}
    labels = []
    for l in (p.get("labels") or []):
        if isinstance(l, dict):
            labels.append({"name": l.get("name") or ""})
        elif isinstance(l, str):
            labels.append({"name": l})
    return {
        "number": p.get("number"),
        "title": p.get("title") or "",
        "body": p.get("body") or "",
        "isDraft": bool(p.get("isDraft") if "isDraft" in p else p.get("draft")),
        "headRefName": p.get("headRefName") or head.get("ref") or "",
        "headRefOid": p.get("headRefOid") or head.get("sha") or "",
        "labels": labels,
    }


def listar_prs():
    """(prs, error): los PRs abiertos NUESTROS. (error None = se pudo leer)

    Si la lista no se puede leer, el error dice QUE fallo (el comando, su rc y
    su stderr): un 'gh' que falla no es 'no hay PRs'.

    THE LIST IS ASKED FOR WITH THE AUTHOR FILTER (2026-11-17). The API's
    pulls endpoint has no author filter, so the first version paged through
    EVERY open pull request of the upstream - a thousand of them, with
    their bodies, megabytes every five minutes - and then threw away the
    ones that were not ours. `gh pr list --author` asks the server for
    ours only, which is what RULES.md:21 prescribed in the first place.
    The filter is ALSO applied here, because the filter of the tool is not
    the filter of the rule.
    """
    args = ["pr", "list", "--repo", REPO, "--author", AUTHOR,
            "--state", "open", "--limit", str(PR_LIMIT),
            "--json", "number,title,isDraft,body,headRefName,headRefOid,labels"]
    rc, raw, err = gh_run(*args)
    if rc != 0:
        return [], (f"'gh {' '.join(args[:4])}' fallo: rc={rc}: "
                    f"{recortar(err)}")
    try:
        data = json.loads(raw or "[]")
    except json.JSONDecodeError as exc:
        return [], (f"'gh pr list' respondio algo que no es JSON: {exc}")
    if not isinstance(data, list):
        return [], ("'gh pr list' no respondio una lista")
    prs = []
    for p in data:
        if not isinstance(p, dict):
            continue
        autor = (p.get("author") or {}).get("login")
        if autor and autor != AUTHOR:
            continue
        prs.append(_normalizar_pr(p))
    return prs, None


# --------------------------------------------------------------------------
# EL COMENTARIO DEL VERDICTO (2026-11-17)
#
# El comentario lleva un marcador con el head sha: el mismo patron que
# bin/ping-ready.sh ('<!-- ping-ready: sha=%s -->'). Con el marcador el
# comentario es idempotente: si ya esta en el PR, no se vuelve a postear. Sin
# el marcador, este cron postea un comentario identico cada 5 minutos en un PR
# publico.
#
# Y la clave de idempotencia se escribe ANTES del efecto: si el proceso se
# muere entre la clave y el comentario, la pasada siguiente ve la clave y no
# repite el efecto.
# --------------------------------------------------------------------------
MARCADOR_VERDICT = "<!-- pipeline-verdict: sha=%s -->"
CLAVES = f"{ORCH}/pipeline/verdicts"


def _clave(num, sha):
    return f"{CLAVES}/pr-{num}-{sha}.done"


def clave_ya_escrita(num, sha):
    """True si la clave del veredicto de este (PR, sha) ya esta escrita."""
    return os.path.isfile(_clave(num, sha))


def escribir_clave(num, sha):
    """La clave de idempotencia, escrita ANTES del efecto. (ok, error)

    La escritura es atomica (un temporal + os.replace): un crash a mitad de
    escritura deja el estado corrupto.
    """
    try:
        os.makedirs(CLAVES, exist_ok=True)
        final = _clave(num, sha)
        tmp = f"{final}.tmp.{os.getpid()}"
        with open(tmp, "w") as fh:
            fh.write(f"pr={num} sha={sha} at={time.strftime('%Y-%m-%dT%H:%M:%S')}\n")
        os.replace(tmp, final)
        return True, None
    except OSError as exc:
        return False, str(exc)


def borrar_clave(num, sha):
    """La clave se borra si el efecto NO se pudo hacer: lo que no se hizo se
    vuelve a hacer en la pasada siguiente (fallo seguro)."""
    try:
        os.remove(_clave(num, sha))
    except OSError:
        pass


def ya_comentado(num, sha):
    """(True|False|None, detalle): si el PR ya tiene el comentario del veredicto
    de este SHA.

    None = no se pudo saber (GitHub no respondio): ante la duda NO se postea
    (un comentario repetido cada 5 minutos en un PR publico es peor que un
    comentario que falta).
    """
    marcador = MARCADOR_VERDICT % sha
    ruta = f"repos/{REPO}/issues/{num}/comments?per_page=100"
    rc, raw, err = gh_run("api", ruta, "--paginate", "--slurp")
    if rc != 0:
        return None, f"'gh api {ruta}' fallo: rc={rc}: {recortar(err)}"
    try:
        data = json.loads(raw or "[]")
    except json.JSONDecodeError as exc:
        return None, f"la respuesta de 'gh api {ruta}' no es JSON: {exc}"
    for c in _aplanar(data):
        if not isinstance(c, dict):
            continue
        login = ((c.get("user") or {}).get("login")) or ""
        if login and login != AUTHOR:
            continue      # el comentario de otro no es nuestro
        if marcador in (c.get("body") or ""):
            return True, "el marcador ya esta en un comentario del PR"
    return False, "no hay ningun comentario con el marcador"


def slot_ocupado(iss):
    """True si un agente esta trabajando ahora en el worktree del slot (bin/slot-busy.sh).

    POR QUE (2026-11-21): el agente pushea despues de cada commit que compila
    (prompts/agent-brief.md) y el draft del claim ya trae 'Fixes #N' y
    'Changes a default: no'. Despachar el CI del fork en cada push de un
    trabajo a medias son ~55 jobs de horas por commit, que el siguiente push
    cancela. Mientras el agente trabaja, no se despacha: el run sale con el
    commit que el agente dejo al terminar. Sin worktree o sin el script no hay
    nadie trabajando (el slot cerrado tambien se gatea).
    """
    wt = os.path.join(WORKTREES_DIR, f"issue-{iss}")
    script = f"{ORCH}/bin/slot-busy.sh"
    if not os.path.isdir(wt) or not os.path.isfile(script):
        return False
    try:
        r = subprocess.run(["bash", script, wt], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0


def despachar_desde_pipeline(pr, num, iss, sha, lote, despachados, problemas, desconocidos):
    """Despacha el CI del fork de un draft sin run. Devuelve 1 si lo despacho, 0 si no.

    El tope de runs en vuelo se mira con el lote de la pasada (sin otra
    llamada) y sin contar el run viejo de la misma rama, que el despacho
    cancela: si contara, el run viejo le cerraria la puerta al nuevo.
    """
    rama = pr.get("headRefName") or ""
    if slot_ocupado(iss):
        log(f"  PR #{num} (issue #{iss}): el agente sigue trabajando en el slot -> el CI "
            f"del fork se despacha cuando termine")
        return 0
    en_vuelo = [r for r in (lote or []) if _status(r) != "completed"
                and not (FORK_CI_CANCEL_STALE and (r.get("head_branch") or "") == rama
                         and not same_sha(r.get("head_sha") or "", sha))]
    ocupados = len(en_vuelo) + despachados
    if ocupados >= FORK_CI_MAX_INFLIGHT:
        log(f"  PR #{num} (issue #{iss}): ya hay {ocupados} run(s) del fork en vuelo (tope "
            f"FORK_CI_MAX_INFLIGHT={FORK_CI_MAX_INFLIGHT}) -> espero, no despacho mas")
        return 0
    res = despachar_fork_ci(rama, sha)
    acc = res["accion"]
    log(f"  PR #{num} (issue #{iss}): CI del fork sin run -> {acc}: {res['detalle']}"
        + (f" {res['run']}" if res.get("run") else ""))
    if acc == "DESPACHADO":
        return 1
    if acc == "ERROR":
        # El rechazo NUEVO cuenta en el exit code; el que se esta esperando
        # (RECHAZADO) ya conto y se dice en el log en cada pasada.
        problemas.append(f"PR #{num}: el despacho del CI del fork fallo: {res['detalle']}")
    elif acc == "DESCONOCIDO":
        desconocidos.append(f"PR #{num}: CI del fork: {res['detalle']}")
    return 0


def main():
    prs, error = listar_prs()
    if error is not None:
        # UNKNOWN, no un 'no': no se pudo leer la lista, asi que no se hizo nada.
        # Y el rc tiene que llegar al exit code (Regla 7 del repo).
        log(f"no pude leer la lista de PRs: {error}")
        return 6

    drafts = [p for p in prs if p.get("isDraft")]
    log(f"PRs nuestros abiertos: {len(prs)} ({len(drafts)} en draft)")

    queued = enqueued_issues()
    verds = {}
    pendientes = 0
    # Los problemas de la corrida: cada uno sale en el log Y en el exit code.
    problemas = []
    # The things that could NOT be read. They are not failures: they are
    # the UNKNOWN of the repo (exit code 6). They do not make the run
    # "something failed"; they make it "nobody knows".
    desconocidos = []

    # EL MODO DEL GATE (2026-11-21): fork-ci (el CI de upstream en el fork) o
    # local (bin/gate.sh). La lista de runs del fork se lee UNA vez por pasada,
    # y solo si hay un draft que la necesite.
    modo, origen_modo = leer_gate_mode()
    log(f"modo del gate: {modo} (de {origen_modo})")
    lote_fork = None
    error_lote = None
    en_vuelo_fork = 0
    despachados = 0
    fork_conteo = {VERDE: 0, PENDIENTE: 0, ROJO: 0, NINGUNO: 0, DESCONOCIDO: 0}
    if modo == "fork-ci" and drafts:
        lote_fork, error_lote = fork_ci_runs()
        if error_lote:
            lote_fork = None
            desconocidos.append(f"CI del fork: no pude leer los runs: {error_lote}")
        else:
            en_vuelo_fork = sum(1 for r in lote_fork if _status(r) != "completed")

    # El resumen de CI: el numero que al mantenedor le importa (a quien pinguear).
    ci_conteo = {VERDE: 0, PENDIENTE: 0, ROJO: 0}
    ci_rojos = []
    ci_pendientes = []

    for pr in sorted(prs, key=lambda p: (p.get("number") or 0)):
        num = pr.get("number")
        body = pr.get("body") or ""
        title = pr.get("title") or ""
        sha = pr.get("headRefOid") or ""

        # 1. el estado del CI de GitHub en el HEAD SHA. Se mira en TODOS los PRs, no solo en
        #    los draft: el resumen tiene que decir quien esta rojo y quien esta esperando.
        if sha:
            runs, error = fetch_check_runs(sha)
            if error:
                estado, detalle_ci = PENDIENTE, f"no pude leer los check-runs: {error}"
                # UNKNOWN, not a failure: the check-runs could not be read.
                # It is a different thing from "an action failed", and the
                # cron has to tell them apart: a run of GitHub that fails
                # for every pull request would otherwise leave the cron red
                # every five minutes, for ever, with no way to tell it from
                # a real problem. The vocabulary already has 6 for this.
                desconocidos.append(f"PR #{num}: no pude leer los check-runs: {error}")
            else:
                estado, detalle_ci = evaluar_check_runs(runs)
        else:
            estado, detalle_ci = PENDIENTE, "no se pudo leer el HEAD SHA"

        if not pr.get("isDraft"):
            contar_ci(ci_conteo, ci_rojos, ci_pendientes, num, estado)
            continue

        iss = issue_of(title, body)
        if not iss:
            # Sin issue no se encola el gate: el slot es POR issue.
            log(f"  PR #{num}: no se sabe que issue es (ni el titulo lo nombra ni el "
                f"body lo cierra) -> no lo encolo")
            contar_ci(ci_conteo, ci_rojos, ci_pendientes, num, PENDIENTE)
            continue

        # 2. el body: la linea de defaults NO se inventa, la referencia al issue si.
        edite = False
        if not linea_defaults_presente(body):
            # Un 'no' automatico puede ser FALSO (un PR que mete una preferencia nueva si
            # cambia un default): mejor sin linea y con el PR en draft que con una linea
            # mentida que pasa el check de upstream y vuelve marcada.
            etiquetas = labels_de(pr)
            if LABEL_CHANGES_DEFAULT in etiquetas:
                pista = "el PR tiene la etiqueta 'changes-default'"
            elif habla_de_defaults(body):
                pista = "el PR habla de defaults/preferencias"
            else:
                pista = "el PR no dice nada de defaults, pero eso no alcanza para decir 'no'"
            log(f"  PR #{num}: falta la linea 'Changes a default:' -> NO la invento "
                f"({pista}): queda en draft y la linea la escribe el autor "
                f"('no' o 'yes - <que>, old behaviour kept behind preference <nombre>')")
            # Sin la linea (o mal formada) el check de upstream no puede dar verde.
            estado = PENDIENTE
            detalle_ci = "falta la linea 'Changes a default:'"
        elif linea_defaults_malformada(body):
            log(f"  PR #{num}: la linea 'Changes a default:' esta MAL FORMADA (el CI de "
                f"upstream la va a rechazar) -> queda en draft y la reescribe el autor")
            estado = PENDIENTE
            detalle_ci = "la linea 'Changes a default:' esta mal formada"
        # La referencia al issue: SOLO si el body no menciona ninguno. Un body que solo
        # menciona el issue puede ser un fix parcial, y escribirle 'Fixes #N' le
        # cerraria un issue al autor por sorpresa.
        #
        # EL PIPELINE YA NO EDITA EL BODY (2026-11-21): `gh pr edit --body` vuelve
        # a correr los checks de upstream y bin/publish-pr.sh lo prohibe; el body
        # lo escribe el agente al publicar. Un body sin issue se dice y el PR
        # queda en draft.
        nuevo = reparar_body(body, title)
        if nuevo is not None:
            log(f"  PR #{num}: el body no menciona ningun issue (falta 'Fixes "
                f"#{issue_del_titulo(title)}') -> sigue en draft; el body no se edita "
                f"desde aca")
            problemas.append(f"PR #{num}: el body no tiene 'Fixes #N'")
            estado = PENDIENTE
            detalle_ci = "el body no tiene 'Fixes #N'"
        if edite:
            # Se edito el body: el workflow pr-checks vuelve a correr (types: edited) y su
            # check todavia no existe. El CI que acabamos de leer judged el body VIEJO.
            estado = PENDIENTE
            detalle_ci = "el body se acaba de editar: el CI de upstream vuelve a correr"

        contar_ci(ci_conteo, ci_rojos, ci_pendientes, num, estado)

        if not sha:
            rc, raw = gh("pr", "view", str(num), "--repo", REPO, "--json", "headRefOid")
            sha = ""
            if rc == 0 and raw:
                try:
                    sha = (json.loads(raw).get("headRefOid")) or ""
                except json.JSONDecodeError:
                    sha = ""
        v = verdict_for(sha)
        local_verde = gate_local_verde(v)
        if v is not None:
            verds[num] = v

        # 3. EL GATE. En modo fork-ci: el CI de upstream corrido en el fork sobre el
        #    head (o, como alternativa, un veredicto local verde del head). En modo
        #    local: el veredicto de bin/gate.sh, como antes.
        if modo == "fork-ci":
            if local_verde:
                gate_desc = f"gate local {v['verdict'] or v['status']} (slot {v['slot']})"
            else:
                if lote_fork is None:
                    fk = {"estado": DESCONOCIDO, "run": "", "fallan": [],
                          "detalle": f"no pude leer los runs del fork: {error_lote}"}
                else:
                    fk = estado_fork_ci(sha, lote=lote_fork, con_jobs_en_curso=False)
                    if fk["estado"] == NINGUNO and len(lote_fork) >= 100:
                        # El lote son los 100 runs mas nuevos: el run de un sha
                        # viejo puede estar fuera. Se le pregunta por el sha.
                        fk = estado_fork_ci(sha, con_jobs_en_curso=False)
                    if fk["estado"] == DESCONOCIDO:
                        desconocidos.append(f"PR #{num}: CI del fork: {fk['detalle']}")
                fork_conteo[fk["estado"]] = fork_conteo.get(fk["estado"], 0) + 1
                if fk["estado"] == NINGUNO:
                    despachados += despachar_desde_pipeline(
                        pr, num, iss, sha, lote_fork, despachados, problemas,
                        desconocidos)
                    continue
                if fk["estado"] != VERDE:
                    fallan = f"; fallan: {', '.join(fk['fallan'])}" if fk.get("fallan") else ""
                    log(f"  PR #{num} (issue #{iss}): CI del fork {fk['estado'].upper()} "
                        f"({fk['detalle']}{fallan}) {fk.get('run') or ''} -> sigue en draft")
                    continue
                gate_desc = f"CI del fork VERDE ({fk.get('run') or 'sin url'})"
        elif v is None:
            # 3. sin veredicto: encolar, salvo que la caja ya tenga enough trabajo
            if iss in queued:
                continue
            # EL WORKTREE DEL SLOT (2026-11-20): sin worktree el gate NO puede
            # correr, y encolarlo hace que el cron de la cola falle cada tres
            # minutos con una condicion que no va a cambiar. Se dice en el log
            # (una vez por pasada) y no se encola: el gate se encolara solo
            # cuando el slot vuelva a tener su worktree.
            wt = os.path.join(WORKTREES_DIR, f"issue-{iss}")
            if not os.path.isdir(wt):
                log(f"  PR #{num} (issue #{iss}): el slot no tiene worktree ({wt}); el "
                    f"gate no puede correr y no se encola (se encolara cuando el "
                    f"slot tenga worktree)")
                continue
            if pendientes + len(queued) >= MAX_INFLIGHT:
                log(f"  PR #{num}: la cola ya tiene {len(queued) + pendientes} gates "
                    f"(tope {MAX_INFLIGHT}) -> espero, no encolo mas")
                continue
            r = subprocess.run(["bash", f"{ORCH}/bin/gate-queue.sh", "--enqueue", iss, sha],
                               capture_output=True, text=True)
            msg = (r.stdout or r.stderr).strip().splitlines()
            log(f"  PR #{num} (issue #{iss}): encolado el gate -> {msg[-1] if msg else 'ok'}")
            pendientes += 1
            continue
        elif not local_verde:
            log(f"  PR #{num} (issue #{iss}): gate {v['status']}/{v['verdict']} "
                f"({v['new_failures']} fallos nuevos) -> sigue en draft")
            continue
        else:
            gate_desc = f"gate local {v['verdict'] or v['status']} (slot {v['slot']})"

        # 4. gate verde -> ready (sin comentario: ver abajo)
        if not linea_defaults_presente(body):
            log(f"  PR #{num} (issue #{iss}): gate verde pero falta la linea "
                f"'Changes a default:' -> sigue en draft (la linea la escribe el autor)")
            continue
        if edite:
            # Se edito el body ahora: el workflow pr-checks vuelve a correr (types: edited) y
            # su check todavia no existe. Promover ahora dejaria un check rojo en pantalla.
            log(f"  PR #{num} (issue #{iss}): edite el body -> el CI de upstream vuelve a "
                f"correr: lo promovio en la proxima pasada")
            continue
        if estado != VERDE:
            log(f"  PR #{num} (issue #{iss}): {gate_desc} pero el CI de GitHub esta "
                f"{estado.upper()} ({detalle_ci}) -> sigue en draft")
            continue
        # 'gh pr ready' que falla se loguea y cuenta como problema: y NO se postea
        # el comentario (el comentario dice 'verde': seria mentira).
        rc, _ = gh("pr", "ready", str(num), "--repo", REPO)
        if rc != 0:
            log(f"  PR #{num} (issue #{iss}): 'gh pr ready' fallo -> el PR sigue en "
                f"draft y no comento el veredicto")
            problemas.append(f"PR #{num}: 'gh pr ready' fallo (rc={rc})")
            continue
        log(f"  PR #{num} (issue #{iss}): {gate_desc} y CI de GitHub VERDE -> pasado a ready")

        # SIN COMENTARIO DE ESTADO (2026-11-21): el pipeline dejaba en el PR un
        # comentario "Gate local en verde y CI de GitHub en verde" (en castellano,
        # en un repo que exige ingles). La guia de upstream
        # (.agents/skills/solidcraft-babysit-pr/SKILL.md) dice "No status
        # comments": el veredicto queda en el log y en el estado, no en GitHub.
        #
        # EL TITULO SIN EL NUMERO (2026-11-21): el draft del claim se titula
        # "<resumen> (#N)" (el bot del claim lee el #N), pero un PR listo para
        # revisar no lleva el numero en el titulo: el merge le agrega "(#PR)"
        # (.agents/skills/solidcraft-file-pr/SKILL.md). El "Fixes #N" del body
        # sigue sosteniendo el claim.
        limpio = titulo_sin_numero(title)
        if limpio and limpio != title:
            rc, _ = gh("pr", "edit", str(num), "--repo", REPO, "--title", limpio)
            if rc == 0:
                log(f"  PR #{num} (issue #{iss}): titulo sin el numero del issue -> {limpio!r}")
            else:
                problemas.append(f"PR #{num}: 'gh pr edit --title' fallo (rc={rc})")

    log(f"fin: {pendientes} encolado(s) ahora, {len(queued)} en la cola, "
        f"{len(verds)} con veredicto")
    if modo == "fork-ci":
        log(f"CI del fork (drafts sin gate local verde): {fork_conteo[VERDE]} verde(s), "
            f"{fork_conteo[PENDIENTE]} pendiente(s), {fork_conteo[ROJO]} rojo(s), "
            f"{fork_conteo[NINGUNO]} sin run, {fork_conteo[DESCONOCIDO]} sin leer; "
            f"{despachados} despachado(s) ahora, {en_vuelo_fork} run(s) en vuelo")
    log(f"CI de GitHub (HEAD SHA): {ci_conteo[VERDE]} verde(s), "
        f"{ci_conteo[PENDIENTE]} pendiente(s), {ci_conteo[ROJO]} rojo(s)")
    if ci_rojos:
        log(f"  PRs con el CI en rojo: {', '.join('#' + str(n) for n in ci_rojos)}")
    if ci_pendientes:
        log(f"  PRs con el CI pendiente: {', '.join('#' + str(n) for n in ci_pendientes)}")
    if problemas:
        # Un veredicto que no llega al exit code es peor que no tener veredicto.
        log(f"problemas: {len(problemas)}")
        for p in problemas:
            log(f"  - {p}")
        return 1
    if desconocidos:
        # Lo que no se pudo leer. No es un fallo: es un "no se sabe", y el
        # codigo del repo para eso es el 6 (UNKNOWN). Un fallo de GitHub que
        # dura mas de una pasada dejaba el cron rojo cada cinco minutos, sin
        # forma de distinguirlo de un problema de verdad.
        log(f"desconocidos: {len(desconocidos)}")
        for d in desconocidos:
            log(f"  - {d}")
        return 6
    return 0


if __name__ == "__main__":
    sys.exit(main())
