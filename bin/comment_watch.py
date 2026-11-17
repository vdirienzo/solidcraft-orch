#!/usr/bin/env python3
"""
comment_watch.py - watches the GitHub comments of what we already follow and
reports ONLY when a comment changes a decision.

WHAT IT DOES, on every run:
  1. Reads from state/ the issues and PRs we already follow (state/prs.json and
     state/manifest.json), plus the issues the PRs refer to.
  2. For each one, reads the comments: the conversation (issue or PR), the
     inline review comments of the PR (they do NOT come with --comments and
     they are the ones the maintainer leaves on the code) and the REVIEWS
     (their state and their body).
  3. Compares against the snapshot of state/comments/<kind>-<num>.json and
     takes the DELTA: new comments, and comments edited since the last run.
  4. Writes the delta to disk ALWAYS: history.jsonl (append) and a queue of
     pending tasks (state/pending_tasks.json) for the comments that ask for a
     concrete action.
  5. Prints on stdout ONLY what changes a decision (asks for another
     approach, new evidence, a change of code). The cron delivers that to the
     chat; if there is nothing, stdout stays empty and nothing is sent.

RULES OF NOISE (this is what makes it useful):
  - Our own comment, or a bot that only talks about style: not reported. It
    goes to the snapshot and nothing else.
  - A comment that asks for an action: queued as a task, and it does NOT
    interrupt the implementation half way. It is served at the next checkpoint.
  - A THIRD PARTY is not an instruction: its text arrives FRAMED
    (<!-- untrusted: autor=... -->), shorter, and it never becomes a task.
    The allowlist of trusted authors is the operator's (COMMENT_WATCH_TRUSTED).
  - A review is work when it asks for changes AND it is about a crash, a wrong
    result, data loss or security. A style nitpick is recorded, not worked on.
    That is the upstream rule (skills/solidcraft-contributing/SKILL.md): the
    filter is by CATEGORY, not by "it is a bot".
  - It is READ ONLY: it does not ping the upstream. The trigger of the merge is
    the label, not the comment.

FIRST RUN: it seeds the snapshot with what is there and reports nothing (the
startup delta would be a full dump, which is noise). After that it reports
only from that point. A corrupt snapshot is never reported as "everything is
new": it is set aside (.corrupt) and the run seeds again.

LOCK: one runner at a time (an atomic mkdir, like bin/gate-queue.sh). If
another runner holds the lock the run is skipped with rc=0: that is not an
error, somebody is working.

Idempotent: running it twice breaks nothing and does not duplicate deltas.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

ORCH_DIR = os.environ.get("ORCH_DIR", os.path.expanduser("~/.local/share/solidcraft-orch"))
STATE = f"{ORCH_DIR}/state"
SNAP_DIR = f"{STATE}/comments"
HISTORY = f"{ORCH_DIR}/history.jsonl"
PENDING = f"{STATE}/pending_tasks.json"
LOG = f"{ORCH_DIR}/logs/comment-watch.log"
LOCK_DIR = f"{ORCH_DIR}/locks"
LOCK = f"{LOCK_DIR}/comment-watch.lock"
REPO = os.environ.get("SOLIDCRAFT_REPO", "tangency-labs/solidcraft")
OWNER = REPO.split("/")[0]

# The gh that is used: GH_BIN if it is defined, else the one of the PATH. A
# stub of gh left in a scratch directory makes "pr create" a no-op, so the
# binary is pinned and it is never resolved through the PATH at call time.
GH_BIN = os.environ.get("GH_BIN") or shutil.which("gh") or "gh"

# Exit codes. Rule 7: a verdict that does not reach the exit code is worse
# than no verdict. 0 is a normal run (or a skipped one: another runner holds
# the lock); 1 is a run that could NOT be done (the state is corrupt).
RC_OK = 0
RC_ERROR = 1

# How old a lock has to be before it can be released.
LOCK_EDAD_MIN = 20

MAX_RONDAS_POR_PR = int(os.environ.get("COMMENT_WATCH_MAX_RONDAS", "3"))
MAX_TAREAS_ABIERTAS = int(os.environ.get("COMMENT_WATCH_MAX_TAREAS", "12"))
PLAZO_HORAS = int(os.environ.get("COMMENT_WATCH_PLAZO_HORAS", "72"))

# Las cuentas que hablan por nosotros: un comentario nuestro no es un delta.
NOSOTROS = {"vdirienzo", "vdirienzo[bot]"}

# Los bots de review: su opinion ya se lee en el PR y en el gate, y su formato
# (HTML, bloques, "Walkthrough") rompe el texto del delta. No son una decision
# que cambie el plan, salvo que el bot diga que algo esta roto de verdad.
BOTS = {
    "coderabbitai",
    "coderabbitai[bot]",
    "github-actions",
    "github-actions[bot]",
    "dependabot",
    "dependabot[bot]",
    "solidcraft-triage",
    "solidcraft-triage[bot]",
    "copilot-pull-request-reviewer[bot]",
    "renovate",
    "renovate[bot]",
    # El bot de triage del upstream: sus "Triage by ..." no son pedidos de
    # una persona, son el clasificador del repo.
    "dudedagger42",
    "dudedagger42[bot]",
}

# The accounts that automate the repo (CI, dependency bots, the triage
# classifier): whatever they say is NOT work. A review bot (CodeRabbit,
# Copilot) CAN be work: the filter is the CATEGORY of the comment, not the
# fact of being a bot.
AUTOMATIZACION = {
    "github-actions",
    "github-actions[bot]",
    "dependabot",
    "dependabot[bot]",
    "renovate",
    "renovate[bot]",
    "solidcraft-triage",
    "solidcraft-triage[bot]",
    "dudedagger42",
    "dudedagger42[bot]",
}

# The authors we trust: the maintainer of the upstream repo, as the operator
# defines it (COMMENT_WATCH_TRUSTED, logins separated by comma). What is NOT
# in this list is a third party: its text arrives framed and is never a task.
CONFIABLES = {
    a.strip() for a in os.environ.get("COMMENT_WATCH_TRUSTED", "").split(",") if a.strip()
}


def es_bot(autor):
    return autor in BOTS or autor.endswith("[bot]")


def es_confiable(autor):
    """The author is in the allowlist the operator defined."""
    return autor in CONFIABLES


# Palabras que delatan un pedido de accion. Un comentario del mantenedor con
# alguna de estas cambia una decision; uno que sólo acusa recibo, no.
PIDE_ACCION = re.compile(
    r"\b(please|plz|kindly|could you|can you|would you|"
    r"needs? (?:a |an |the |to |you )|"
    r"must (?:be|have|add|include|name|say|change|fix)|"
    r"should (?:be|have|say|change|name)|"
    r"instead|rather than|not what i|"
    r"i (?:think|believe) (?:this|it|that|the)|"
    r"can we|let's|let us|"
    r"add (?:a |an |the )?(?:test|tests|evidence|screenshot|picture|comment|note|line)|"
    r"capture|re-?capture|screenshot|picture|evidence|"
    r"rebase|re-?base|force-?push|"
    r"change (?:the |this |that |it)|rename|fix (?:the |this |that )|"
    r"revert|drop (?:the |this )|rework)\b",
    re.IGNORECASE,
)

# Un comentario que SÍ cambia una decision: o lo pide el mantenedor, o pide
# un cambio de enfoque/evidencia/codigo de forma explicita.
PIDE_CAMBIO = re.compile(
    r"\b(needs? to be|needs? a |needs? an |needs? the |must be|has to be|"
    r"please|could you|can you|would you|"
    r"instead of|rather than|"
    r"add (?:a |an |the )?(?:test|tests|evidence|screenshot|picture)|"
    r"capture|re-?capture|evidence|screenshot|"
    r"rebase|re-?base|"
    r"i (?:think|believe) (?:this|it|that|the)|"
    r"not what i (?:want|asked|meant)|"
    r"that's (?:not|wrong)|this is (?:not|wrong)|wrong (?:here|there))\b",
    re.IGNORECASE,
)

# The four CRITICAL categories of the upstream rule
# (skills/solidcraft-contributing/SKILL.md: "Act on CodeRabbit comments only
# when they're about crashes, wrong results, data loss or security, and
# ignore style nitpicks"). The filter is by CATEGORY: a crash, a wrong result,
# data loss or a security problem is work; a style nitpick is not.
CATEGORIA_CRITICA = re.compile(
    r"\b(crash(?:es|ed|ing)?|"
    r"panic(?:ked|s)?|segfault|"
    r"deadlock|"
    r"hang(?:s|ing)?|"
    r"freez(?:es|ing)|"
    r"infinite loop|"
    r"stack overflow|"
    r"fatal error|"
    r"wrong (?:result|output|value|answer|number|geometry|behaviour|behavior)|"
    r"incorrect (?:result|output|value|answer|number|geometry)|"
    r"off[- ]by[- ]one|"
    r"data (?:loss|lost|corrupt(?:ion|ed)?)|"
    r"los(?:e|es|ing) (?:the )?data|"
    r"truncat(?:e|es|ed|ing)|"
    r"clobber(?:s|ed)?|"
    r"corrupt(?:s|ed|ion)? (?:the )?(?:file|data|state|model|design)|"
    r"security|"
    r"vulnerab(?:le|ility)|"
    r"injection|"
    r"path traversal|"
    r"privilege escalation|"
    r"secret(?:s)? (?:leak|exposed)|"
    r"leak(?:s|ed|ing)? (?:the )?(?:token|secret|credential|key|password)|"
    r"credential(?:s)? (?:leak|exposed)|"
    r"unsafe)\b",
    re.IGNORECASE,
)

# The opposite: a style nitpick. It is not work, even when it asks for
# changes.
ES_NITPICK = re.compile(
    r"\b(nits?|nitpick(?:s|ing)?|style|stylistic|cosmetic|typos?|spelling|"
    r"format(?:ting)?|prettier|whitespace|indentation|"
    r"maybe rename|consider renaming|could be renamed|"
    r"optional|nit:)\b",
    re.IGNORECASE,
)

# How much of a comment goes to the chat: a trusted author gets the whole
# thing up to the cap, a third party much less (and it arrives framed).
TOPE_CONFIABLE = 700
TOPE_TERCERO = 300

# The mark that tells the agent that what follows is not an order from the
# maintainer but text of a third party.
MARCA_TERCERO = "<!-- untrusted: autor={autor} -->"


def log(msg):
    # Los logs van a stderr, NO a stdout: con un cron --no-agent, stdout es lo
    # que se entrega al chat. Si el log saliera a stdout, cada corrida seria un
    # aviso espontaneo, y el watcher solo debe hablar cuando algo cambia.
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, file=sys.stderr)
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def gh(*args, timeout=90):
    """gh con salida cruda; '' si falla (la red no puede tumbar la corrida)."""
    try:
        p = subprocess.run(
            [GH_BIN, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            env={**os.environ, "PATH": os.path.expanduser("~/.local/bin") + ":" + os.environ.get("PATH", "")},
        )
        return p.stdout if p.returncode == 0 else ""
    except (subprocess.TimeoutExpired, OSError):
        return ""


def gh_json(*args, timeout=90):
    raw = gh(*args, timeout=timeout)
    if not raw.strip():
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


def cuerpo(body):
    """El cuerpo sin las partes que GitHub mete y que no son del autor."""
    b = body or ""
    b = re.sub(r"<!--.*?-->", "", b, flags=re.DOTALL)
    b = re.sub(r"```.*?```", "[bloque de codigo]", b, flags=re.DOTALL)
    b = re.sub(r"`([^`]*)`", r"`\1`", b)
    b = re.sub(r"\n{3,}", "\n\n", b)
    return b.strip()


def hash_cuerpo(b):
    return hashlib.sha256((b or "").encode("utf-8", "replace")).hexdigest()[:16]


def targets():
    """Los issues y PRs que ya seguimos: de state/, no de una lista a mano."""
    issues, prs = set(), set()

    prs_json = f"{STATE}/prs.json"
    if os.path.exists(prs_json):
        try:
            with open(prs_json) as f:
                d = json.load(f)
        except (OSError, json.JSONDecodeError):
            d = {}
        for p in d.get("open_prs", []) or []:
            # The entry that carries the key "pr" instead of "number" was
            # being lost: the pull request #11205 was counted as none. The
            # other consumer of this key (bin/orch-state.sh) normalizes both.
            n = p.get("number")
            if not isinstance(n, int):
                n = p.get("pr")
            if isinstance(n, int):
                prs.add(n)
            iss = p.get("issue")
            if isinstance(iss, int):
                issues.add(iss)

    # Los issues que los PRs referencian (Fixes #N / Refs #N): el PR los
    # referencia, el comentario suele estar en el issue.
    for n in sorted(prs):
        body = gh_json("pr", "view", str(n), "--repo", REPO, "--json", "body")
        if not body:
            continue
        for m in re.findall(r"(?:fixes|closes|resolves|refs|addresses)\s+#(\d+)", body.get("body") or "", re.IGNORECASE):
            issues.add(int(m))

    # Los issues que el manifiesto declara pendiente.
    man = f"{STATE}/manifest.json"
    if os.path.exists(man):
        try:
            with open(man) as f:
                d = json.load(f)
        except (OSError, json.JSONDecodeError):
            d = {}
        for key in ("issues", "pending", "triage_candidates"):
            v = d.get(key)
            if isinstance(v, list):
                for it in v:
                    if isinstance(it, int):
                        issues.add(it)
                    elif isinstance(it, str):
                        m = re.search(r"#(\d+)", it)
                        if m:
                            issues.add(int(m.group(1)))
                    elif isinstance(it, dict):
                        for k in ("issue", "number"):
                            if isinstance(it.get(k), int):
                                issues.add(it[k])

    issues = {i for i in issues if i > 0}
    prs = {p for p in prs if p > 0}
    return sorted(issues), sorted(prs)


def comentarios_issue(num):
    """Los comentarios de la conversacion de un issue."""
    d = gh_json("issue", "view", str(num), "--repo", REPO, "--json", "comments")
    out = []
    for c in (d or {}).get("comments", []) or []:
        out.append(
            {
                "id": str(c.get("id") or c.get("databaseId") or ""),
                "autor": (c.get("author") or {}).get("login", "?"),
                "cuerpo": cuerpo(c.get("body")),
                "creado": c.get("createdAt") or c.get("created_at") or "",
                "url": c.get("url") or "",
                "tipo": "comentario",
            }
        )
    return out


def comentarios_pr(num):
    """Los comentarios del PR: la conversacion MAS los review comments inline.

    Los inline NO salen con --comments: son los que el mantenedor deja sobre
    el codigo, y son los que importan.
    """
    out = []
    d = gh_json("pr", "view", str(num), "--repo", REPO, "--json", "comments")
    for c in (d or {}).get("comments", []) or []:
        out.append(
            {
                "id": str(c.get("id") or c.get("databaseId") or ""),
                "autor": (c.get("author") or {}).get("login", "?"),
                "cuerpo": cuerpo(c.get("body")),
                "creado": c.get("createdAt") or c.get("created_at") or "",
                "url": c.get("url") or "",
                "tipo": "comentario",
            }
        )
    raw = gh_json("api", f"repos/{REPO}/pulls/{num}/comments", timeout=90)
    for c in raw or []:
        out.append(
            {
                "id": f"inline-{c.get('id')}",
                "autor": (c.get("user") or {}).get("login", "?"),
                "cuerpo": cuerpo(c.get("body")),
                "creado": c.get("created_at") or c.get("createdAt") or "",
                "url": c.get("html_url") or "",
                "ruta": c.get("path") or "",
                "tipo": "inline",
            }
        )
    return out


def reviews_pr(num):
    """The REVIEWS of the PR: their state (CHANGES_REQUESTED/APPROVED/...) and
    their body, which is the summary a reviewer or a review tool posts.

    --json comments does NOT bring them, so without this the watcher sees
    neither the state of a review nor what it asks for.

    Returns (reviews, reviewDecision).
    """
    out = []
    d = gh_json("pr", "view", str(num), "--repo", REPO, "--json", "reviews")
    for r in (d or {}).get("reviews", []) or []:
        out.append(
            {
                "id": f"review-{r.get('id') or r.get('databaseId') or ''}",
                "autor": (r.get("author") or {}).get("login", "?"),
                "cuerpo": cuerpo(r.get("body")),
                "creado": r.get("submittedAt") or r.get("submitted_at") or "",
                "url": r.get("url") or "",
                "estado": (r.get("state") or "").upper(),
                "tipo": "review",
            }
        )
    dec = gh_json("pr", "view", str(num), "--repo", REPO, "--json", "reviewDecision")
    decision = ((dec or {}).get("reviewDecision") or "").upper()
    return out, decision


def snapshot_path(kind, num):
    return f"{SNAP_DIR}/{kind}-{num}.json"


def leer_snapshot(kind, num):
    """(snapshot, estado). estado: 'ausente' | 'ok' | 'corrupto'.

    A CORRUPT snapshot is never reported as "everything is new" (that would be
    a flood of tasks): it is set aside as <file>.corrupt, logged loudly, and
    the run seeds again. The old file is kept as evidence.
    """
    p = snapshot_path(kind, num)
    if not os.path.exists(p):
        return None, "ausente"
    try:
        with open(p) as f:
            d = json.load(f)
        if not isinstance(d, dict):
            raise ValueError("it is not an object")
        if not d.get("sembrado"):
            raise ValueError("it is not marked as seeded")
    except (OSError, ValueError) as e:
        log(f"ERROR: the snapshot {p} is corrupt ({e}): it is set aside as {p}.corrupt and the run seeds again")
        try:
            os.replace(p, p + ".corrupt")
        except OSError as e2:
            log(f"ERROR: the corrupt snapshot could not be set aside ({e2})")
        return None, "corrupto"
    return d, "ok"


def guardar_snapshot(kind, num, snap):
    os.makedirs(SNAP_DIR, exist_ok=True)
    tmp = snapshot_path(kind, num) + ".tmp"
    with open(tmp, "w") as f:
        json.dump(snap, f, indent=1, sort_keys=True)
    os.replace(tmp, snapshot_path(kind, num))


def delta(kind, num, coms, snap):
    """(nuevos, snap_nuevo)."""
    snap = snap or {"vistos": {}, "participantes": [], "sembrado": False}
    vistos = dict(snap.get("vistos", {}) or {})
    participantes = set(snap.get("participantes", []) or [])
    nuevos = []
    for c in coms:
        clave = c["id"] or hash_cuerpo(c["cuerpo"])
        h = hash_cuerpo(c["cuerpo"])
        # TODOS los comentarios quedan marcados como vistos, no solo los nuevos:
        # si solo se guardaran los nuevos, el siguiente delta repetiria el mismo.
        vistos[clave] = h
        if clave not in (snap.get("vistos", {}) or {}):
            nuevos.append({**c, "clave": clave, "hash": h, "participante_nuevo": c["autor"] not in participantes})
        elif (snap.get("vistos", {}) or {})[clave] != h:
            # Editado: el texto cambio. Es un delta: lo que dijo antes ya no vale.
            nuevos.append({**c, "clave": clave, "hash": h, "participante_nuevo": False, "editado": True})
    snap_nuevo = {
        "vistos": vistos,
        "participantes": sorted(participantes | {c["autor"] for c in coms}),
        "sembrado": True,
        "actualizado": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    return nuevos, snap_nuevo


class ColaCorrupta(Exception):
    """La cola de tareas pendientes no se pudo leer."""


def cargar_pendientes():
    """La cola de tareas pendientes.

    If it is CORRUPT it aborts: returning [] would make the run overwrite the
    file with an empty list and the maintainer's requests would disappear
    (rule 7: what cannot be known is not "no", it is an error).
    """
    if not os.path.exists(PENDING):
        return []
    try:
        with open(PENDING) as f:
            d = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise ColaCorrupta(str(e)) from e
    if not isinstance(d, list):
        raise ColaCorrupta("it is not a list")
    return d


def guardar_pendientes(items):
    os.makedirs(STATE, exist_ok=True)
    tmp = PENDING + ".tmp"
    with open(tmp, "w") as f:
        json.dump(items, f, indent=1, ensure_ascii=False)
    os.replace(tmp, PENDING)


# ---------------------------------------------------------------------------
# The lock: one runner at a time. Same pattern as bin/gate-queue.sh: an atomic
# mkdir, and an old lock is released ONLY when its owner is not alive (rule 21:
# the liveness of a lock is its AGE and its OWNER, never its PID alone: a
# recycled PID is not the owner).
# ---------------------------------------------------------------------------
def _inicio_proceso(pid):
    """When the process started (clock ticks since boot), or None."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            s = f.read()
    except OSError:
        return None
    try:
        campos = s[s.rindex(")") + 1:].split()
        return int(campos[19])
    except (ValueError, IndexError):
        return None


def _escribir_dueno(path):
    try:
        with open(os.path.join(path, "dueno.json"), "w") as f:
            json.dump(
                {"pid": os.getpid(), "inicio": _inicio_proceso(os.getpid()), "desde": time.time()},
                f,
            )
    except OSError:
        pass


def _dueno_vivo(path):
    """Is the owner of the lock still working?"""
    try:
        with open(os.path.join(path, "dueno.json")) as f:
            d = json.load(f)
    except (OSError, json.JSONDecodeError):
        # Without a registered owner there is no proof that it is alive: the
        # age of the lock is what protects.
        return False
    pid = d.get("pid")
    if not isinstance(pid, int):
        return False
    inicio = _inicio_proceso(pid)
    if inicio is None:
        return False
    guardado = d.get("inicio")
    return guardado is None or guardado == inicio


def tomar_lock():
    """(tomado, motivo). One single runner at a time."""
    os.makedirs(LOCK_DIR, exist_ok=True)
    try:
        os.mkdir(LOCK)
    except FileExistsError:
        pass
    except OSError as e:
        raise OSError(f"the lock could not be created: {e}") from e
    else:
        _escribir_dueno(LOCK)
        return True, "lock taken"

    # The lock exists: it is released only when it is OLD and its owner is not
    # alive anymore.
    try:
        edad = (time.time() - os.stat(LOCK).st_mtime) / 60
    except OSError:
        edad = 0
    if edad < LOCK_EDAD_MIN:
        return False, f"another runner is working (lock of {int(edad)} min)"
    if _dueno_vivo(LOCK):
        return False, f"another runner is working (lock of {int(edad)} min, its owner is still alive)"
    try:
        shutil.rmtree(LOCK)
        os.mkdir(LOCK)
    except OSError:
        return False, "another runner is working (the old lock could not be released)"
    _escribir_dueno(LOCK)
    return True, f"released an old lock ({int(edad)} min without a live owner)"


def soltar_lock():
    """Releases the lock, but only if we are its owner."""
    try:
        with open(os.path.join(LOCK, "dueno.json")) as f:
            d = json.load(f)
    except (OSError, json.JSONDecodeError):
        return
    if d.get("pid") != os.getpid():
        return
    try:
        shutil.rmtree(LOCK)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# What is work and what is noise.
# ---------------------------------------------------------------------------
def review_pide_cambio(rev):
    """La review pide cambios."""
    if (rev.get("estado") or "").upper() == "CHANGES_REQUESTED":
        return True
    # Un bot de review deja la review en COMMENTED y el defecto en el cuerpo.
    return es_bot(rev["autor"]) and bool(CATEGORIA_CRITICA.search(rev.get("cuerpo") or ""))


def review_es_trabajo(rev):
    """Una review es trabajo si pide cambios y no es un nitpick de estilo.

    La CATEGORIA manda (regla del upstream): un crash, un resultado erroneo,
    una perdida de datos o un problema de seguridad son trabajo, aunque quien
    lo escriba sea un bot; un nitpick de estilo no es trabajo, aunque lo pida
    un humano de confianza.
    """
    texto = rev.get("cuerpo") or ""
    critica = bool(CATEGORIA_CRITICA.search(texto))
    if not review_pide_cambio(rev):
        return False
    if critica:
        return True
    return es_confiable(rev["autor"]) and not ES_NITPICK.search(texto)


def comentario_es_tarea(c):
    """El comentario pide una accion concreta."""
    autor = c.get("autor") or ""
    if autor in NOSOTROS:
        return False
    if es_bot(autor):
        # Un bot solo trabaja si su comentario es de una categoria critica.
        return autor not in AUTOMATIZACION and bool(CATEGORIA_CRITICA.search(c.get("cuerpo") or ""))
    if not es_confiable(autor):
        # Un tercero no es una instruccion: no genera tarea.
        return False
    return bool(PIDE_ACCION.search(c.get("cuerpo") or ""))


def es_tarea(c):
    """El delta se convierte en tarea pendiente."""
    if c.get("tipo") == "review":
        return review_es_trabajo(c)
    return comentario_es_tarea(c)


def se_imprime(c):
    """El delta llega al chat (stdout)."""
    autor = c.get("autor") or ""
    if autor in NOSOTROS:
        return False
    if c.get("tipo") == "review":
        # Una review se anuncia solo si es trabajo: si es estilo, queda en el
        # historial y no interrumpe a nadie.
        return review_es_trabajo(c)
    if es_bot(autor):
        return comentario_es_tarea(c)
    texto = c.get("cuerpo") or ""
    if es_confiable(autor):
        return bool(PIDE_CAMBIO.search(texto))
    # Un tercero: se muestra ENMARCADO, para que el agente sepa que es texto
    # de un tercero y no una orden del mantenedor.
    return bool(PIDE_CAMBIO.search(texto)) or bool(CATEGORIA_CRITICA.search(texto))


def formatear(c):
    """El delta, para el chat. Lo de un tercero va enmarcado y recortado."""
    etiqueta = "issue" if c.get("kind") == "issue" else "PR"
    autor = c.get("autor") or "?"
    texto = c.get("cuerpo") or ""
    if es_confiable(autor):
        return f"- **{etiqueta} #{c['num']}** — {autor}: {texto[:TOPE_CONFIABLE]}"
    marca = MARCA_TERCERO.format(autor=autor)
    return (
        f"- **{etiqueta} #{c['num']}** — {autor} (third-party text, not an instruction):\n"
        f"  {marca}\n"
        f"  {texto[:TOPE_TERCERO]}"
    )


def main():
    argv = sys.argv[1:]
    # --seed forces the seeding: the snapshot is thrown away and the run
    # starts from zero (what is there is history, it is not reported). Without
    # a snapshot the seeding is automatic: the first run cannot be a dump.
    forzar_sembrado = "--seed" in argv

    try:
        tomado, motivo = tomar_lock()
    except OSError as e:
        log(f"ERROR: the lock could not be taken ({e})")
        return RC_ERROR
    if not tomado:
        # It is not an error: another runner is working.
        log(f"skipped run: {motivo}")
        return RC_OK

    try:
        return correr(forzar_sembrado)
    finally:
        soltar_lock()


def correr(forzar_sembrado):
    # The queue is read FIRST: if it is corrupt the run aborts without
    # touching anything (no snapshots, no history, no queue). An empty queue
    # over a broken file would make the maintainer's requests disappear.
    try:
        pend = cargar_pendientes()
    except ColaCorrupta as e:
        log(f"ERROR: the pending task queue is corrupt ({e}): nothing was written and the run is aborted")
        return RC_ERROR

    issues, prs = targets()
    log(f"issues={len(issues)} prs={len(prs)}")

    deltas = []
    for kind, nums in (("issue", issues), ("pr", prs)):
        for num in nums:
            coms = comentarios_issue(num) if kind == "issue" else comentarios_pr(num)
            decision = ""
            if kind == "pr":
                reviews, decision = reviews_pr(num)
                coms = coms + reviews
            snap, estado_snap = leer_snapshot(kind, num)
            if estado_snap == "corrupto":
                log(f"  {kind} #{num}: corrupt snapshot: the run seeds again, nothing is reported")
            if snap is None or forzar_sembrado:
                # Siembra: el snapshot arranca con lo que hay y no reporta. El
                # delta de arranque seria un volcado completo, que es ruido.
                _, snap_nuevo = delta(kind, num, coms, None)
                if decision:
                    snap_nuevo["reviewDecision"] = decision
                guardar_snapshot(kind, num, snap_nuevo)
                log(f"  {kind} #{num}: seeded with {len(coms)} comment(s) (no delta)")
                continue
            if decision and snap.get("reviewDecision") and snap["reviewDecision"] != decision:
                log(f"  {kind} #{num}: reviewDecision {snap['reviewDecision']} -> {decision}")
            nuevos, snap_nuevo = delta(kind, num, coms, snap)
            if decision:
                snap_nuevo["reviewDecision"] = decision
            guardar_snapshot(kind, num, snap_nuevo)
            if nuevos:
                for c in nuevos:
                    c["kind"] = kind
                    c["num"] = num
                deltas.extend(nuevos)
                log(f"  {kind} #{num}: {len(nuevos)} delta(s)")

    if not deltas:
        log("sin delta")
        return RC_OK

    # El delta, a disco, siempre.
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        os.makedirs(ORCH_DIR, exist_ok=True)
        with open(HISTORY, "a") as f:
            for c in deltas:
                estado = f" [{c['estado']}]" if c.get("estado") else ""
                f.write(
                    json.dumps(
                        {
                            "at": ts,
                            "tipo": c.get("tipo", "comentario"),
                            "que": f"{c['kind']} #{c['num']}: {c['autor']}{estado}: {c['cuerpo'][:600]}",
                            # The same text under "action": the reader of the
                            # history (bin/orch-state.sh history) prints that
                            # key, and it was showing an empty line.
                            "action": f"{c['kind']} #{c['num']}: {c['autor']}{estado}: {c['cuerpo'][:600]}",
                            "url": c.get("url", ""),
                        },
                        ensure_ascii=False,
                    )
                    + "\n"
                )
    except OSError as e:
        log(f"ERROR: the history could not be written ({e})")

    # La cola de tareas: lo que pide una accion concreta. No interrumpe nada:
    # se atiende en el proximo checkpoint.
    vistos = {p.get("clave") for p in pend}
    abiertas = [p for p in pend if (p.get("estado") or "pendiente") == "pendiente"]
    por_pr = {}
    for p in abiertas:
        if p.get("kind") == "pr":
            por_pr[p.get("num")] = por_pr.get(p.get("num"), 0) + 1
    nuevas = []
    superadas = []
    for c in deltas:
        if not es_tarea(c):
            continue
        clave = f"{c['kind']}-{c['num']}-{c['clave']}"
        if clave in vistos:
            continue
        if len(abiertas) + len(nuevas) >= MAX_TAREAS_ABIERTAS:
            superadas.append((c, "la cola de tareas esta llena (circuit breaker)"))
            continue
        if c["kind"] == "pr" and por_pr.get(c["num"], 0) >= MAX_RONDAS_POR_PR:
            superadas.append((c, f"el PR #{c['num']} ya tiene {MAX_RONDAS_POR_PR} pedidos"))
            continue
        pide = cuerpo(c["cuerpo"])[:1200]
        if not es_confiable(c["autor"]):
            # What is not trusted arrives framed in the queue too: the agent
            # has to know that it is text of a third party.
            pide = MARCA_TERCERO.format(autor=c["autor"]) + "\n" + pide
        tarea = {
            "clave": clave,
            "kind": c["kind"],
            "num": c["num"],
            "autor": c["autor"],
            "url": c.get("url", ""),
            "ruta": c.get("ruta", ""),
            "creado": c["creado"],
            "detectado": ts,
            "estado": "pendiente",
            "deadline": int(time.time()) + PLAZO_HORAS * 3600,
            "tipo": c.get("tipo", "comentario"),
            "confiable": es_confiable(c["autor"]),
            "pide": pide,
        }
        if c.get("estado"):
            tarea["review_estado"] = c["estado"]
        nuevas.append(tarea)
    if nuevas:
        pend.extend(nuevas)
        try:
            guardar_pendientes(pend)
        except OSError as e:
            log(f"ERROR: the pending task queue could not be written ({e})")
            return RC_ERROR
    if superadas:
        # Lo que no se encola no se pierde: queda en la historia, con el
        # motivo. El agente lo lee y PREGUNTA una vez en vez de gastar.
        motivos = "; ".join(sorted({m for _, m in superadas}))
        try:
            os.makedirs(ORCH_DIR, exist_ok=True)
            with open(HISTORY, "a") as f:
                f.write(
                    json.dumps(
                        {
                            "at": ts,
                            "tipo": "tope",
                            "que": f"{len(superadas)} pedido(s) no se encolaron: {motivos}",
                            "action": f"{len(superadas)} pedido(s) no se encolaron: {motivos}",
                        },
                        ensure_ascii=False,
                    )
                    + "\n"
                )
        except OSError as e:
            log(f"ERROR: the history could not be written ({e})")
        for c, motivo in superadas:
            log(f"NO se encola: {c['kind']} #{c['num']} ({motivo})")

    # Al chat: SOLO lo que cambia una decision. Lo demas queda en disco.
    cambios = [c for c in deltas if se_imprime(c)]
    if not cambios:
        log(f"{len(deltas)} delta(s) a disco, ninguno cambia una decision")
        return RC_OK

    print(f"**GitHub: {len(cambios)} comentario(s) que cambian una decision**\n")
    for c in cambios:
        print(formatear(c))
        if c.get("url"):
            print(f"  {c['url']}")
        print()
    return RC_OK


if __name__ == "__main__":
    sys.exit(main())
