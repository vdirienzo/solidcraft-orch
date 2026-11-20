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
  2. Para cada PR en draft cuyo gate NO tenga veredicto todavia: lo ENCOLA (gate-queue.sh).
  3. Para cada PR en draft cuyo gate local ya dio verde Y cuyo CI de GitHub esta VERDE en
     su HEAD SHA: lo pasa a READY y deja el comentario con el veredicto, el SHA y el conteo
     de fallos preexistentes.
  4. NO encola mas trabajo del que la caja aguanta (MAX_INFLIGHT): la cola de gates va a 2
     compilaciones por vez, y un backlog grande es exactamente lo que hace vencer los claims.
  5. Al final, un resumen con cuantos PRs tienen el CI de GitHub verde, pendiente y en rojo.

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

    grupos = {}
    for run in check_runs:
        if not isinstance(run, dict):
            continue
        grupos.setdefault(run.get("name") or "?", []).append(run)
    if not grupos:
        return PENDIENTE, "el CI todavia no arranco (sin check-runs en el HEAD SHA)"

    rojos = []
    pendientes = []
    for nombre, runs in grupos.items():
        vigente = _vigente(runs)

        # Un run en vuelo (queued/in_progress) MAS NUEVO que el ultimo completado es el
        # CI que esta corriendo ahora: manda el, y todavia no hay veredicto.
        if _en_vuelo(runs, vigente) is not None:
            pendientes.append(f"{nombre} (corriendo)")
            continue

        if vigente is None:
            pendientes.append(f"{nombre} (sin veredicto)")
            continue

        conclusion = _conclusion(vigente)
        if conclusion in CHECK_OK:
            continue
        if conclusion in CHECK_ROJOS:
            rojos.append(f"{nombre} ({conclusion})")
            continue
        if conclusion in ("cancelled", "stale"):
            # Run superseded. Si hay un gemelo en verde creado despues, ese gana (es el run
            # nuevo del mismo check); si no, no hay veredicto todavia -> pendiente.
            gemelo = max((r for r in runs
                          if _id(r) > _id(vigente) and _conclusion(r) in CHECK_OK),
                         key=_id, default=None)
            if gemelo is not None:
                continue
            pendientes.append(f"{nombre} ({conclusion})")
            continue
        # conclusion desconocida: no se la da por buena
        pendientes.append(f"{nombre} ({conclusion or 'sin conclusion'})")

    if rojos:
        return ROJO, "rojo: " + ", ".join(sorted(rojos))
    if pendientes:
        return PENDIENTE, "pendiente: " + ", ".join(sorted(pendientes))
    return VERDE, "verde: todos los checks del HEAD SHA estan en verde"


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
        nuevo = reparar_body(body, title)
        if nuevo is not None:
            rc, _ = gh("pr", "edit", str(num), "--repo", REPO, "--body", nuevo)
            if rc == 0:
                log(f"  PR #{num}: le agregue 'Fixes #{issue_del_titulo(title)}' "
                    f"(el body no mencionaba ningun issue)")
                edite = True
            else:
                problemas.append(f"PR #{num}: 'gh pr edit' fallo (rc={rc})")
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
        if v is None:
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

        verds[num] = v
        # 4. verde local -> ready, con el veredicto en el comentario
        verde = v["verdict"].startswith("VERDE") or (
            v["status"] == "finished" and v["new_failures"] in ("0", ""))
        if not verde:
            log(f"  PR #{num} (issue #{iss}): gate {v['status']}/{v['verdict']} "
                f"({v['new_failures']} fallos nuevos) -> sigue en draft")
            continue
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
            log(f"  PR #{num} (issue #{iss}): gate local verde pero el CI de GitHub esta "
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
        log(f"  PR #{num} (issue #{iss}): gate VERDE y CI de GitHub VERDE -> pasado a ready")

        # El comentario del veredicto: con marcador, y UNA sola vez por head sha.
        marcador = MARCADOR_VERDICT % sha
        if clave_ya_escrita(num, sha):
            log(f"  PR #{num} (issue #{iss}): el veredicto de este SHA ya se habia "
                f"comentado -> no lo repito")
            continue
        ya, detalle = ya_comentado(num, sha)
        if ya is None:
            # No se pudo saber si ya esta: ante la duda no se postea (un comentario
            # repetido cada 5 minutos en un PR publico es peor que uno que falta).
            log(f"  PR #{num} (issue #{iss}): no se pudo saber si el veredicto ya estaba "
                f"comentado ({detalle}) -> no lo posteo ahora")
            problemas.append(f"PR #{num}: no se pudo leer los comentarios del PR")
            continue
        if ya:
            escribir_clave(num, sha)
            log(f"  PR #{num} (issue #{iss}): el veredicto de este SHA ya estaba en el PR "
                f"-> no lo repito")
            continue
        # La clave de idempotencia, ANTES del efecto.
        ok, err = escribir_clave(num, sha)
        if not ok:
            log(f"  PR #{num} (issue #{iss}): no se pudo escribir la clave del veredicto "
                f"({err}) -> no lo posteo (mejor no repetir que duplicar)")
            problemas.append(f"PR #{num}: no se pudo escribir la clave del veredicto")
            continue
        cuerpo = (f"{marcador}\n\n"
                  f"Gate local en verde y CI de GitHub en verde.\n\n"
                  f"- SHA: `{sha}`\n"
                  f"- Veredicto: `{v['verdict']}` (GATE_STATUS: {v['status']})\n"
                  f"- Fallos nuevos: {v['new_failures'] or '0'}\n"
                  f"- Fallos preexistentes en origin/main: {v['preexisting'] or '0'}\n")
        rc, _ = gh("pr", "comment", str(num), "--repo", REPO, "--body", cuerpo)
        if rc != 0:
            # Lo que no se hizo, se vuelve a hacer en la pasada siguiente.
            borrar_clave(num, sha)
            log(f"  PR #{num} (issue #{iss}): 'gh pr comment' fallo -> no quedo el "
                f"comentario del veredicto")
            problemas.append(f"PR #{num}: 'gh pr comment' fallo (rc={rc})")
            continue
        log(f"  PR #{num} (issue #{iss}): deje el comentario del veredicto con el "
            f"marcador del head sha")

    log(f"fin: {pendientes} encolado(s) ahora, {len(queued)} en la cola, "
        f"{len(verds)} con veredicto")
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
