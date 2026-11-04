#!/usr/bin/env python3
"""
pipeline.py - el eslabon que faltaba entre "el agente commitea" y "el PR queda publicado".

POR QUE EXISTE (2026-11-04): el claim de un issue vence a las 72 h si no hay un PR que lo
referencie. Antes, el agente commiteaba, pusheaba y corria el gate: si el gate se colgaba o
el agente se moria, el issue se perdia sin PR y el claim se iba. Ademas los gates se pedian
uno por uno, sin cola, y cada agente compilaba por su cuenta (contencion de locks).

QUE HACE ESTE SCRIPT, en cada corrida:
  1. Para cada PR nuestro que este en DRAFT: le corrige el body si no cumple el formato que
     exige el CI upstream ("Changes a default: no") y le agrega la referencia al issue.
  2. Para cada PR en draft cuyo gate NO tenga veredicto todavia: lo ENCOLA (gate-queue.sh).
  3. Para cada PR en draft cuyo gate ya dio verde: lo pasa a READY y deja el comentario con
     el veredicto, el SHA y el conteo de fallos preexistentes.
  4. NO encola mas trabajo del que la caja aguanta (MAX_INFLIGHT): la cola de gates va a 2
     compilaciones por vez, y un backlog grande es exactamente lo que hace vencer los claims.

Se corre desde un cron cada 5 minutos. Es idempotente: correrlo dos veces no rompe nada.
"""
import json
import os
import re
import subprocess
import sys
import time

ORCH = "/home/user/.local/share/solidcraft-orch"
GATES = "/home/user/.local/share/solidcraft-loop/gates"
QUEUE = f"{ORCH}/gates/queue.txt"
REPO = "tangency-labs/solidcraft"
FORK = "vdirienzo/solidcraft"
MAX_INFLIGHT = int(os.environ.get("MAX_INFLIGHT", "6"))
LOG = f"{ORCH}/logs/pipeline.log"


def log(msg):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line)
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def gh(*args, timeout=120):
    r = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=timeout)
    return r.stdout if r.returncode == 0 else ""


def issue_of(body, pr_num):
    """El issue que referencia el PR. 'Fixes #N' y 'Addresses #N' valen; el numero solo."""
    for pat in (r"(?:Fixes|Closes|Addresses|Refs)\s+#(\d+)", r"#(\d+)"):
        m = re.search(pat, body or "")
        if m:
            return m.group(1)
    return None


def verdict_for(sha):
    """El veredicto de gate de ese SHA, buscado en todos los slots por SHA (no por nombre)."""
    if not sha:
        return None
    for slot in sorted(os.listdir(GATES)) if os.path.isdir(GATES) else []:
        f = f"{GATES}/{slot}/scope.verdict"
        if not os.path.isfile(f):
            continue
        crudo = f
        try:
            txt = open(f, errors="replace").read()
        except OSError:
            continue
        if f"SHA={sha}" not in txt:
            continue
        # el veredicto EFECTIVO es el que cuenta: el crudo sale ROJO por los fallos
        # preexistentes de origin/main. gate-baseline.sh lo deja al lado.
        ef = f.replace("scope.verdict", "scope.effective.verdict")
        if os.path.isfile(ef):
            try:
                etxt = open(ef, errors="replace").read()
            except OSError:
                etxt = ""
            if f"SHA={sha}" in etxt:
                txt = etxt
                crudo = ef
        def grab(key, default=""):
            m = re.search(rf"^{key}=(.*)$", txt, re.M)
            return m.group(1).strip() if m else default
        status = grab("GATE_STATUS")
        if not status:
            # el efectivo puede no traer GATE_STATUS: se hereda del crudo
            try:
                status = re.search(r"^GATE_STATUS=(.*)$", open(crudo, errors="replace").read(), re.M).group(1).strip()
            except AttributeError:
                status = ""
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


def main():
    raw = gh("pr", "list", "--repo", REPO, "--author", "vdirienzo", "--state", "open",
             "--limit", "30", "--json", "number,title,isDraft,body,headRefName")
    try:
        prs = json.loads(raw or "[]")
    except json.JSONDecodeError:
        log("no pude leer la lista de PRs")
        return 0

    drafts = [p for p in prs if p.get("isDraft")]
    log(f"PRs nuestros abiertos: {len(prs)} ({len(drafts)} en draft)")

    queued = enqueued_issues()
    verds = {}
    pendientes = 0

    for pr in sorted(drafts, key=lambda p: p["number"]):
        num = pr["number"]
        body = pr.get("body") or ""
        iss = issue_of(body, num)
        if not iss:
            log(f"  PR #{num}: el body no referencia ningun issue -> no lo encolo")
            continue

        # 1. el body tiene que cumplir lo que exige el CI upstream
        if "Changes a default:" not in body:
            nuevo = body.rstrip() + "\n\nChanges a default: no\n"
            if gh("pr", "edit", str(num), "--repo", REPO, "--body", nuevo):
                log(f"  PR #{num}: le agregue 'Changes a default: no' al body")
        if not re.search(r"(?:Fixes|Closes|Addresses|Refs)\s+#\d+", body):
            nuevo = body.rstrip() + f"\n\nAddresses #{iss}\n"
            if gh("pr", "edit", str(num), "--repo", REPO, "--body", nuevo):
                log(f"  PR #{num}: le agregue la referencia al issue #{iss}")

        sha = gh("pr", "view", str(num), "--repo", REPO, "--json", "headRefOid")
        sha = (json.loads(sha).get("headRefOid") if sha else None) or ""
        v = verdict_for(sha)
        if v is None:
            # 2. sin veredicto: encolar, salvo que la caja ya tengaenough trabajo
            if iss in queued:
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
        # 3. verde -> ready, con el veredicto en el comentario
        verde = v["verdict"].startswith("VERDE") or (
            v["status"] == "finished" and v["new_failures"] in ("0", ""))
        if not verde:
            log(f"  PR #{num} (issue #{iss}): gate {v['status']}/{v['verdict']} "
                f"({v['new_failures']} fallos nuevos) -> sigue en draft")
            continue
        if gh("pr", "ready", str(num), "--repo", REPO):
            log(f"  PR #{num} (issue #{iss}): gate VERDE -> pasado a ready")
        cuerpo = (f"Gate local en verde.\n\n"
                  f"- SHA: `{sha}`\n"
                  f"- Veredicto: `{v['verdict']}` (GATE_STATUS: {v['status']})\n"
                  f"- Fallos nuevos: {v['new_failures'] or '0'}\n"
                  f"- Fallos preexistentes en origin/main: {v['preexisting'] or '0'}\n")
        gh("pr", "comment", str(num), "--repo", REPO, "--body", cuerpo)

    log(f"fin: {pendientes} encolado(s) ahora, {len(queued)} en la cola, "
        f"{len(verds)} con veredicto")
    return 0


if __name__ == "__main__":
    sys.exit(main())
