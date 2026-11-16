#!/usr/bin/env python3
"""
comment_watch.py - mira los comentarios de GitHub de lo que ya seguimos, y
avisa SOLO cuando un comentario cambia una decision.

POR QUE EXISTE (2026-11-16): el bucle empujaba, corria el gate y esperaba un
label, pero no leia los comentarios. El mantenedor contesta con pedidos
concretos (capturas sin recorte, otro enfoque, otra evidencia) y el PR se
queda parado sin que nadie se entere: enterarse tarde cuesta un rework.

QUE HACE, en cada corrida:
  1. Lee de state/ los issues y PRs que ya seguimos (state/prs.json y
     state/manifest.json), mas los issues que los PRs referencian.
  2. Por cada uno, lee los comentarios: los de la conversacion (issue o PR) y
     los review comments inline del PR, que NO salen con --comments y son
     justamente los del mantenedor.
  3. Compara con el snapshot de state/comments/<kind>-<num>.json y saca el
     DELTA: comentarios nuevos, o comentarios de alguien que no habia
     participateado antes.
  4. Escribe el delta SIEMPRE a disco: history.jsonl (append) y una cola de
     tareas pendientes (state/pending_tasks.json) para los comentarios que
     piden una accion concreta.
  5. Imprime en stdout SOLO lo que cambia una decision (pide otro enfoque,
     pide evidencia nueva, pide un cambio de codigo). Con eso el cron puede
     entregarlo al chat; si no hay nada, stdout queda vacio y no se manda nada.

REGLAS DE RUIDO (esto es lo que lo hace util):
  - Un comentario propio, o de un participante conocido, que no cambia nada:
    no se reporta. Va al snapshot y nada mas.
  - Un comentario que pide una accion: se encola como tarea y NO interrumpe
    la implementacion a mitad. Se atiende en el proximo checkpoint.
  - Es SOLO LECTURA: no hace ping al upstream. El trigger del merge es el
    label, no el comentario.

PRIMERA CORRIDA: siembra el snapshot con lo que ya hay y no reporta nada
(el delta de arranque seria un volcado completo, que es ruido). Despues
reporta solo desde ese punto.

Idempotente: correrlo dos veces no rompe nada y no duplica deltas.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time

ORCH_DIR = os.environ.get("ORCH_DIR", os.path.expanduser("~/.local/share/solidcraft-orch"))
STATE = f"{ORCH_DIR}/state"
SNAP_DIR = f"{STATE}/comments"
HISTORY = f"{ORCH_DIR}/history.jsonl"
PENDING = f"{STATE}/pending_tasks.json"
LOG = f"{ORCH_DIR}/logs/comment-watch.log"
REPO = os.environ.get("SOLIDCRAFT_REPO", "tangency-labs/solidcraft")
OWNER = REPO.split("/")[0]

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


def es_bot(autor):
    return autor in BOTS or autor.endswith("[bot]")

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
            ["gh", *args],
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
            n = p.get("number")
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
            }
        )
    return out


def snapshot_path(kind, num):
    return f"{SNAP_DIR}/{kind}-{num}.json"


def leer_snapshot(kind, num):
    p = snapshot_path(kind, num)
    if not os.path.exists(p):
        return None
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


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


def cargar_pendientes():
    if not os.path.exists(PENDING):
        return []
    try:
        with open(PENDING) as f:
            d = json.load(f)
    except (OSError, json.JSONDecodeError):
        return []
    return d if isinstance(d, list) else []


def guardar_pendientes(items):
    os.makedirs(STATE, exist_ok=True)
    tmp = PENDING + ".tmp"
    with open(tmp, "w") as f:
        json.dump(items, f, indent=1, ensure_ascii=False)
    os.replace(tmp, PENDING)


def main():
    argv = sys.argv[1:]
    sembrar = "--seed" in argv
    issues, prs = targets()
    log(f"issues={len(issues)} prs={len(prs)}")

    deltas = []
    for kind, nums in (("issue", issues), ("pr", prs)):
        for num in nums:
            coms = comentarios_issue(num) if kind == "issue" else comentarios_pr(num)
            snap = leer_snapshot(kind, num)
            if snap is None and sembrar:
                # Siembra: el snapshot arranca con lo que hay y no reporta.
                _, snap_nuevo = delta(kind, num, coms, None)
                guardar_snapshot(kind, num, snap_nuevo)
                log(f"  {kind} #{num}: sembrado con {len(coms)} comentarios")
                continue
            nuevos, snap_nuevo = delta(kind, num, coms, snap)
            guardar_snapshot(kind, num, snap_nuevo)
            if nuevos:
                for c in nuevos:
                    c["kind"] = kind
                    c["num"] = num
                deltas.extend(nuevos)
                log(f"  {kind} #{num}: {len(nuevos)} delta(s)")

    if not deltas:
        log("sin delta")
        return 0

    # El delta, a disco, siempre.
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(HISTORY, "a") as f:
        for c in deltas:
            f.write(
                json.dumps(
                    {
                        "at": ts,
                        "tipo": "comentario",
                        "que": f"{c['kind']} #{c['num']}: {c['autor']}: {c['cuerpo'][:600]}",
                        "url": c.get("url", ""),
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )

    # La cola de tareas: lo que pide una accion concreta. No interrumpe nada:
    # se atiende en el proximo checkpoint.
    pend = cargar_pendientes()
    vistos = {p.get("clave") for p in pend}
    for c in deltas:
        if c["autor"] in NOSOTROS or es_bot(c["autor"]):
            continue
        if not PIDE_ACCION.search(c["cuerpo"]):
            continue
        clave = f"{c['kind']}-{c['num']}-{c['clave']}"
        if clave in vistos:
            continue
        pend.append(
            {
                "clave": clave,
                "kind": c["kind"],
                "num": c["num"],
                "autor": c["autor"],
                "url": c.get("url", ""),
                "ruta": c.get("ruta", ""),
                "creado": c["creado"],
                "detectado": ts,
                "estado": "pendiente",
                "pide": cuerpo(c["cuerpo"])[:1200],
            }
        )
    guardar_pendientes(pend)

    # Al chat: SOLO lo que cambia una decision. Lo demas queda en disco.
    cambios = []
    for c in deltas:
        if c["autor"] in NOSOTROS or es_bot(c["autor"]):
            continue
        texto = c["cuerpo"]
        if not PIDE_CAMBIO.search(texto):
            continue
        cambios.append(c)

    if not cambios:
        log(f"{len(deltas)} delta(s) a disco, ninguno cambia una decision")
        return 0

    print(f"**GitHub: {len(cambios)} comentario(s) que cambian una decision**\n")
    for c in cambios:
        etiqueta = "issue" if c["kind"] == "issue" else "PR"
        print(f"- **{etiqueta} #{c['num']}** — {c['autor']}: {c['cuerpo'][:700]}")
        if c.get("url"):
            print(f"  {c['url']}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
