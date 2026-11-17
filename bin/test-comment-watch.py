#!/usr/bin/env python3
"""
test-comment-watch.py - tests for the comment watcher (#9178 tooling).

NO NETWORK AND NO TOUCHING THE REAL ORCH_DIR (this is checked FIRST):
  - `gh` is answered by a STUB (TMP/gh-stub) that reads a JSON fixture;
  - ORCH_DIR points to a tmpdir: state/, logs/, history.jsonl and the lock
    belong to the test;
  - the PATH of the test holds ONLY a sentinel `gh`: if anything invokes it, it
    writes TMP/red-tocada and the test fails. The real `gh` is not on the PATH,
    and HOME points to a tmpdir, so it is not in ~/.local/bin either;
  - GH_BIN pins WHICH gh is used: it is never resolved through the PATH.

What is under test is the LOGIC: the delta, the noise rules, the author
allowlist, the reviews, the lock, the task queue and the sums.

Usage: python3 test-comment-watch.py
"""
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

RAIZ = os.path.dirname(os.path.abspath(__file__))
RUTA = os.path.join(RAIZ, "comment_watch.py")

TMP = tempfile.mkdtemp(prefix="test-comment-watch-")
STUB = os.path.join(TMP, "gh-stub")
FIXTURES = os.path.join(TMP, "fixtures.json")
CALLS = os.path.join(TMP, "gh-calls.log")
SENTINEL_DIR = os.path.join(TMP, "pathbin")
RED = os.path.join(TMP, "red-tocada")

PR_NUM = 42
ISS_NUM = 100

# The real ORCH_DIR of this machine, BEFORE HOME is moved: the test must not
# create it and must not write into it.
ORCH_REAL = os.path.expanduser("~/.local/share/solidcraft-orch")
ORCH_REAL_EXISTIA = os.path.exists(ORCH_REAL)

fallos = []


def check(nombre, cond, detalle=""):
    if cond:
        print(f"  ok   {nombre}")
    else:
        print(f"  FAIL {nombre}  {detalle}")
        fallos.append(nombre)


# ---------------------------------------------------------------------------
# the harness: a stub of gh, a tmpdir for the state, and a PATH that cannot
# reach the network.
# ---------------------------------------------------------------------------
STUB_SRC = r'''#!/usr/bin/python3
"""Stub of `gh`: answers from a JSON fixture. It never touches the network."""
import json
import os
import sys

args = sys.argv[1:]

calls = os.environ.get("STUB_CALLS", "")
if calls:
    with open(calls, "a") as fh:
        fh.write(" ".join(args) + "\n")

fixtures = {}
try:
    with open(os.environ.get("STUB_FIXTURES", "")) as fh:
        fixtures = json.load(fh)
except Exception:
    fixtures = {}


def out(obj):
    sys.stdout.write(json.dumps(obj))
    sys.exit(0)


def campos(args):
    if "--json" in args:
        return args[args.index("--json") + 1].split(",")
    return []


if args[:2] == ["pr", "view"]:
    pr = (fixtures.get("prs") or {}).get(args[2]) or {}
    res = {}
    for c in campos(args):
        if c in ("reviews", "comments"):
            res[c] = pr.get(c) or []
        else:
            res[c] = pr.get(c) or ""
    out(res)

if args[:2] == ["issue", "view"]:
    iss = (fixtures.get("issues") or {}).get(args[2]) or {}
    res = {}
    for c in campos(args):
        res[c] = iss.get(c) or ([] if c == "comments" else "")
    out(res)

if args[:1] == ["api"]:
    partes = args[1].split("/") if len(args) > 1 else []
    if "pulls" in partes:
        n = partes[partes.index("pulls") + 1]
        out(((fixtures.get("prs") or {}).get(n) or {}).get("inline") or [])
    out([])

out({})
'''


def preparar_harness():
    with open(STUB, "w") as fh:
        fh.write(STUB_SRC)
    os.chmod(STUB, 0o755)

    # The sentinel: the only `gh` on the PATH of the test. If the watcher ever
    # resolves `gh` through the PATH, it writes RED and the test fails.
    os.makedirs(SENTINEL_DIR, exist_ok=True)
    centinela = os.path.join(SENTINEL_DIR, "gh")
    with open(centinela, "w") as fh:
        fh.write(
            "#!/bin/sh\n"
            'echo "the PATH gh was invoked: the test touched the network" > "%s"\n' % RED
            + "exit 1\n"
        )
    os.chmod(centinela, 0o755)


preparar_harness()

# HOME and PATH are pinned BEFORE the watcher is imported: the watcher reads
# both (HOME for ~/.local/bin, PATH for the gh lookup).
os.environ["HOME"] = os.path.join(TMP, "home")
os.makedirs(os.environ["HOME"], exist_ok=True)
os.environ["PATH"] = SENTINEL_DIR
os.environ["GH_BIN"] = STUB
os.environ["STUB_FIXTURES"] = FIXTURES
os.environ["STUB_CALLS"] = CALLS


def cargar(orch, confianza=""):
    """A fresh copy of the watcher, with its own ORCH_DIR and allowlist."""
    os.environ["ORCH_DIR"] = orch
    os.environ["COMMENT_WATCH_TRUSTED"] = confianza
    spec = importlib.util.spec_from_file_location("comment_watch", RUTA)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def escribir_json(ruta, obj):
    os.makedirs(os.path.dirname(ruta), exist_ok=True)
    with open(ruta, "w") as fh:
        json.dump(obj, fh, indent=1, ensure_ascii=False)


def item(cid, autor, cuerpo, creado="2026-11-16T00:00:00Z"):
    """A comment in the shape the watcher works with (after gh is parsed)."""
    return {"id": cid, "autor": autor, "cuerpo": cuerpo, "creado": creado, "url": f"https://x/{cid}"}


def comentario(cid, login, body, creado="2026-11-17T00:00:00Z"):
    return {
        "id": cid,
        "author": {"login": login},
        "body": body,
        "createdAt": creado,
        "url": f"https://github.com/tangency-labs/solidcraft/pull/{PR_NUM}#discussion_{cid}",
    }


def review(cid, login, state, body, creado="2026-11-17T00:00:00Z"):
    return {
        "id": cid,
        "author": {"login": login},
        "state": state,
        "body": body,
        "submittedAt": creado,
        "url": f"https://github.com/tangency-labs/solidcraft/pull/{PR_NUM}#pullrequestreview-{cid}",
    }


def fx(comentarios=(), reviews=(), inline=(), decision=""):
    return {
        "prs": {
            str(PR_NUM): {
                "body": f"Fixes #{ISS_NUM}",
                "comments": list(comentarios),
                "reviews": list(reviews),
                "reviewDecision": decision,
                "inline": list(inline),
            }
        },
        "issues": {str(ISS_NUM): {"comments": []}},
    }


def correr(nombre, pasos):
    """Runs the watcher once per step. Each step: fixtures/estado/preparar.

    Returns one result per step: {rc, out, err, orch, mod}.
    """
    orch = os.path.join(TMP, nombre, "orch")
    os.makedirs(os.path.join(orch, "state"), exist_ok=True)
    escribir_json(
        os.path.join(orch, "state", "prs.json"),
        {"open_prs": [{"number": PR_NUM, "issue": ISS_NUM}]},
    )
    res = []
    for paso in pasos:
        escribir_json(FIXTURES, paso.get("fixtures", {}))
        for rel, contenido in (paso.get("estado") or {}).items():
            ruta = os.path.join(orch, rel)
            os.makedirs(os.path.dirname(ruta), exist_ok=True)
            with open(ruta, "w") as fh:
                fh.write(contenido)
        mod = cargar(orch, paso.get("confianza", ""))
        if paso.get("preparar"):
            paso["preparar"](orch, mod)
        out, err = io.StringIO(), io.StringIO()
        real_out, real_err, real_argv = sys.stdout, sys.stderr, sys.argv
        sys.argv = ["comment_watch.py"] + list(paso.get("argv") or [])
        sys.stdout, sys.stderr = out, err
        try:
            rc = mod.main()
        except Exception as exc:  # a crash of the watcher is a failure, not the end
            rc = -1
            err.write(f"EXCEPTION: {exc!r}\n")
        finally:
            sys.stdout, sys.stderr, sys.argv = real_out, real_err, real_argv
        res.append(
            {
                "rc": rc,
                "out": out.getvalue(),
                "err": err.getvalue(),
                "orch": orch,
                "mod": mod,
            }
        )
    return res


def pendientes(orch):
    ruta = os.path.join(orch, "state", "pending_tasks.json")
    if not os.path.exists(ruta):
        return []
    try:
        with open(ruta) as fh:
            d = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return ["<corrupt>"]
    return d if isinstance(d, list) else []


def log_de(orch):
    ruta = os.path.join(orch, "logs", "comment-watch.log")
    if not os.path.exists(ruta):
        return ""
    with open(ruta) as fh:
        return fh.read()


def historia(orch):
    ruta = os.path.join(orch, "history.jsonl")
    if not os.path.exists(ruta):
        return ""
    with open(ruta) as fh:
        return fh.read()


def snapshot(orch, kind="pr", num=PR_NUM):
    return os.path.join(orch, "state", "comments", f"{kind}-{num}.json")


# ===========================================================================
print("1. the delta logic")
cw = cargar(os.path.join(TMP, "unit", "orch"))
coms = [item("c1", "bherbruck", "please rebase onto main"),
        item("c2", "dudedagger42", "ok for me")]
n1, s1 = cw.delta("pr", 1, coms, None)
check("the first delta sees the 2 comments", len(n1) == 2, f"saw {len(n1)}")
n2, s2 = cw.delta("pr", 1, coms, s1)
check("the second delta sees nothing", len(n2) == 0, f"saw {len(n2)}")
check("the snapshot keeps what it saw", len(s2["vistos"]) == 2, f"vistos={len(s2['vistos'])}")

print("2. a new comment is seen once")
coms2 = coms + [item("c3", "MattRuhland", "this needs a screenshot please")]
n3, s3 = cw.delta("pr", 1, coms2, s2)
check("the new comment shows up", len(n3) == 1 and n3[0]["id"] == "c3", f"saw {len(n3)}")
n4, _ = cw.delta("pr", 1, coms2, s3)
check("and it does not repeat on the next run", len(n4) == 0, f"saw {len(n4)}")

print("3. an edited comment is a delta")
editados = [item("c1", "bherbruck", "please rebase onto main, and add a test")]
n5, _ = cw.delta("pr", 1, editados, s3)
check("the edited text is reported", len(n5) == 1 and n5[0].get("editado"), f"saw {len(n5)}")

print("4. the noise rules")
check("a request for evidence asks for action", bool(cw.PIDE_ACCION.search("please add a screenshot")))
check("an ack does NOT ask for action", not cw.PIDE_ACCION.search("thanks, looks good to me"))
check("a change of approach asks for action", bool(cw.PIDE_ACCION.search("instead of that, use the other approach")))
check("the decision change is detected", bool(cw.PIDE_CAMBIO.search("this needs to be a conic, not a spline")))
check("a thanks does NOT change a decision", not cw.PIDE_CAMBIO.search("thanks, looks good to me"))

print("5. the critical categories (upstream rule) and the style nitpicks")
CRITICA = getattr(cw, "CATEGORIA_CRITICA", None)
for texto in (
    "the app crashes when the sketch is empty",
    "this produces a wrong result on a boolean",
    "the file is corrupted: data loss on save",
    "this is a security problem: the path is not escaped",
):
    check(f"critical: {texto[:38]}", bool(CRITICA and CRITICA.search(texto)))
for texto in (
    "nit: maybe rename this variable",
    "just a style comment about the formatting",
    "the typo in the comment",
):
    check(f"nitpick: {texto[:38]}", not (CRITICA and CRITICA.search(texto)))

print("6. the snapshot and the queue on disk")
unit = os.path.join(TMP, "unit", "orch")
os.makedirs(os.path.join(unit, "state"), exist_ok=True)
cw2 = cargar(unit)
cw2.guardar_snapshot("pr", 42, {"vistos": {"c1": "h"}, "participantes": ["a"], "sembrado": True})
leido = cw2.leer_snapshot("pr", 42)
estado = "ok"
if isinstance(leido, tuple):
    leido, estado = leido
check("the snapshot is written and read", leido is not None and leido["vistos"]["c1"] == "h", str(leido))
check("a good snapshot is 'ok'", estado == "ok", f"estado={estado}")
cw2.guardar_pendientes([{"clave": "x", "estado": "pendiente"}])
check("the queue is written and read", len(cw2.cargar_pendientes()) == 1)

print("7. stdout stays empty when nothing changes a decision")
r = correr("vacio", [{"fixtures": fx()}])
check("main returns 0", r[0]["rc"] == 0, f"rc={r[0]['rc']}")
check("stdout is empty", r[0]["out"].strip() == "", repr(r[0]["out"][:120]))

print("8. curve ids are not confused with comment ids")
check("a comment id is not a curve id", not cw.hash_cuerpo("n1").startswith("n1"))

# ===========================================================================
print("9. I2: without a snapshot the first run seeds and reports nothing")
r = correr(
    "i2",
    [
        {
            "fixtures": fx(comentarios=[comentario("C1", "bherbruck", "please rebase onto main")]),
            "confianza": "bherbruck",
        }
    ],
)
check("I2: the first run reports nothing", r[0]["out"].strip() == "", repr(r[0]["out"][:160]))
check("I2: the first run queues no task", not pendientes(r[0]["orch"]), str(pendientes(r[0]["orch"])))
check("I2: the first run seeds the snapshot", os.path.exists(snapshot(r[0]["orch"])))
sembrado = None
if os.path.exists(snapshot(r[0]["orch"])):
    with open(snapshot(r[0]["orch"])) as fh:
        sembrado = json.load(fh).get("sembrado")
check("I2: the seed is marked as such", sembrado is True, f"sembrado={sembrado}")

print("10. a comment that arrives after the seed is a delta")
r = correr(
    "delta",
    [
        {"fixtures": fx(), "confianza": "bherbruck"},
        {
            "fixtures": fx(comentarios=[comentario("C1", "bherbruck", "please rebase onto main")]),
            "confianza": "bherbruck",
        },
    ],
)
check("the new comment is reported", "please rebase" in r[1]["out"], repr(r[1]["out"][:160]))
check("the new comment is a task", len(pendientes(r[1]["orch"])) == 1, str(pendientes(r[1]["orch"])))

print("11. I3: a corrupt snapshot does not report everything")
r = correr(
    "i3",
    [
        {
            "fixtures": fx(comentarios=[comentario("C1", "bherbruck", "please rebase onto main")]),
            "confianza": "bherbruck",
            "estado": {"state/comments/pr-42.json": "{this is not json"},
        }
    ],
)
check("I3: nothing is reported", r[0]["out"].strip() == "", repr(r[0]["out"][:160]))
check("I3: no task is queued", not pendientes(r[0]["orch"]), str(pendientes(r[0]["orch"])))
check("I3: it is logged", "corrupt" in log_de(r[0]["orch"]).lower(), log_de(r[0]["orch"])[-300:])
check(
    "I3: the old snapshot is kept",
    os.path.exists(snapshot(r[0]["orch"]) + ".corrupt"),
    str(os.listdir(os.path.dirname(snapshot(r[0]["orch"])))) if os.path.isdir(os.path.dirname(snapshot(r[0]["orch"]))) else "no dir",
)

print("12. I4: a corrupt queue aborts the run and is not overwritten")
r = correr(
    "i4",
    [
        {
            "fixtures": fx(comentarios=[comentario("C1", "bherbruck", "please rebase onto main")]),
            "confianza": "bherbruck",
            "estado": {"state/pending_tasks.json": "[{broken"},
        }
    ],
)
with open(os.path.join(r[0]["orch"], "state", "pending_tasks.json")) as fh:
    cola = fh.read()
check("I4: the exit code is not 0", r[0]["rc"] != 0, f"rc={r[0]['rc']}")
check("I4: the queue file is untouched", cola == "[{broken", repr(cola))
check("I4: it is logged", "corrupt" in log_de(r[0]["orch"]).lower(), log_de(r[0]["orch"])[-300:])

print("13. I5: with the lock taken the run is skipped")


def tomar_lock(orch, mod):
    ruta = getattr(mod, "LOCK", None) or os.path.join(orch, "locks", "comment-watch.lock")
    os.makedirs(ruta, exist_ok=True)


r = correr(
    "i5",
    [
        {
            "fixtures": fx(comentarios=[comentario("C1", "bherbruck", "please rebase onto main")]),
            "confianza": "bherbruck",
            "preparar": tomar_lock,
        }
    ],
)
check("I5: the exit code is 0", r[0]["rc"] == 0, f"rc={r[0]['rc']}")
check("I5: it logs the skipped run", "skip" in log_de(r[0]["orch"]).lower(), log_de(r[0]["orch"])[-300:])
check("I5: nothing was done", not os.path.exists(snapshot(r[0]["orch"])))
check("I5: no task was queued", not pendientes(r[0]["orch"]))

print("14. I1: a third party arrives framed, the maintainer does not")
r = correr(
    "i1-otro",
    [
        {"fixtures": fx(), "confianza": "bherbruck"},
        {
            "fixtures": fx(comentarios=[comentario("C1", "curioso-externo", "please rebase onto main")]),
            "confianza": "bherbruck",
        },
    ],
)
check("I1: the third party arrives framed", "untrusted: autor=curioso-externo" in r[1]["out"], repr(r[1]["out"][:300]))
check("I1: the third party is not a task", not pendientes(r[1]["orch"]), str(pendientes(r[1]["orch"])))
check("I1: the third party is still recorded", "curioso-externo" in historia(r[1]["orch"]))

r = correr(
    "i1-mant",
    [
        {"fixtures": fx(), "confianza": "bherbruck"},
        {
            "fixtures": fx(comentarios=[comentario("C1", "bherbruck", "please rebase onto main")]),
            "confianza": "bherbruck",
        },
    ],
)
check("I1: the maintainer arrives without framing", "untrusted:" not in r[1]["out"], repr(r[1]["out"][:300]))
check("I1: the maintainer is a task", len(pendientes(r[1]["orch"])) == 1, str(pendientes(r[1]["orch"])))

print("15. I6: a review that asks for changes and reports a crash is a task")
r = correr(
    "i6-crash",
    [
        {"fixtures": fx()},
        {
            "fixtures": fx(
                reviews=[
                    review(
                        "R1",
                        "coderabbitai",
                        "CHANGES_REQUESTED",
                        "This crashes the app when the sketch is empty",
                    )
                ],
                decision="CHANGES_REQUESTED",
            )
        },
    ],
)
check(
    "I6: the review is a task",
    any("crash" in (p.get("pide") or "") for p in pendientes(r[1]["orch"])),
    str(pendientes(r[1]["orch"])),
)

print("16. I6: a review that only asks for style is not a task")
r = correr(
    "i6-nit",
    [
        {"fixtures": fx()},
        {
            "fixtures": fx(
                reviews=[
                    review(
                        "R1",
                        "coderabbitai",
                        "CHANGES_REQUESTED",
                        "nit: maybe rename this variable to be clearer",
                    )
                ],
                decision="CHANGES_REQUESTED",
            )
        },
    ],
)
check("I6: the style review is not a task", not pendientes(r[1]["orch"]), str(pendientes(r[1]["orch"])))
check("I6: the style review is not printed", "maybe rename" not in r[1]["out"], repr(r[1]["out"][:300]))
check("I6: the style review is recorded", "maybe rename" in historia(r[1]["orch"]), historia(r[1]["orch"])[-300:])

print("17. idempotency: the same comment is not queued twice")
r = correr(
    "idem",
    [
        {"fixtures": fx(), "confianza": "bherbruck"},
        {
            "fixtures": fx(comentarios=[comentario("C1", "bherbruck", "please rebase onto main")]),
            "confianza": "bherbruck",
        },
        {
            "fixtures": fx(comentarios=[comentario("C1", "bherbruck", "please rebase onto main")]),
            "confianza": "bherbruck",
        },
    ],
)
check("the second run queues the task", len(pendientes(r[1]["orch"])) == 1, str(pendientes(r[1]["orch"])))
check("the third run queues nothing new", len(pendientes(r[2]["orch"])) == 1, str(pendientes(r[2]["orch"])))
check("the third run prints nothing", r[2]["out"].strip() == "", repr(r[2]["out"][:160]))

print("18. I5: an old lock is released only when its owner is dead")


def lock_viejo(dueno):
    def preparar(orch, mod):
        ruta = getattr(mod, "LOCK", None) or os.path.join(orch, "locks", "comment-watch.lock")
        os.makedirs(ruta, exist_ok=True)
        with open(os.path.join(ruta, "dueno.json"), "w") as fh:
            json.dump(dueno, fh)
        viejo = time.time() - 30 * 60
        os.utime(ruta, (viejo, viejo))
    return preparar


r = correr(
    "i5-viejo",
    [
        {
            "fixtures": fx(comentarios=[comentario("C1", "bherbruck", "please rebase onto main")]),
            "confianza": "bherbruck",
            "preparar": lock_viejo({"pid": 999999}),
        }
    ],
)
check("I5: an old lock without a live owner is released", os.path.exists(snapshot(r[0]["orch"])))
check("I5: the run does not report the seeded comments", r[0]["out"].strip() == "", repr(r[0]["out"][:160]))

r = correr(
    "i5-dueno",
    [
        {
            "fixtures": fx(comentarios=[comentario("C1", "bherbruck", "please rebase onto main")]),
            "confianza": "bherbruck",
            "preparar": lock_viejo({"pid": os.getpid()}),
        }
    ],
)
check("I5: an old lock with a live owner is NOT released", not os.path.exists(snapshot(r[0]["orch"])))
check("I5: the run is skipped", r[0]["rc"] == 0 and "skipped run" in log_de(r[0]["orch"]), f"rc={r[0]['rc']}")

print("19. --seed starts over: the snapshot is thrown away and nothing is reported")
r = correr(
    "seed",
    [
        {"fixtures": fx(), "confianza": "bherbruck"},
        {
            "fixtures": fx(comentarios=[comentario("C1", "bherbruck", "please rebase onto main")]),
            "confianza": "bherbruck",
        },
        {
            "fixtures": fx(comentarios=[comentario("C1", "bherbruck", "please rebase onto main")]),
            "confianza": "bherbruck",
            "argv": ["--seed"],
        },
    ],
)
check("--seed: nothing is reported", r[2]["out"].strip() == "", repr(r[2]["out"][:160]))
with open(snapshot(r[2]["orch"])) as fh:
    sembrado = json.load(fh)
check("--seed: the snapshot starts over", len(sembrado.get("vistos", {})) == 1, str(sembrado.get("vistos")))

print("20. the script runs as a process: rc, stdout and the lock")
orch_proc = os.path.join(TMP, "proceso", "orch")
os.makedirs(os.path.join(orch_proc, "state"), exist_ok=True)
escribir_json(os.path.join(orch_proc, "state", "prs.json"), {"open_prs": [{"number": PR_NUM}]})
escribir_json(FIXTURES, fx(comentarios=[comentario("C1", "curioso-externo", "please rebase onto main")]))
env = dict(os.environ)
env["ORCH_DIR"] = orch_proc
env["COMMENT_WATCH_TRUSTED"] = "bherbruck"
proc = subprocess.run(
    [sys.executable, RUTA],
    capture_output=True,
    text=True,
    env=env,
    timeout=60,
)
check("the process returns 0", proc.returncode == 0, f"rc={proc.returncode} err={proc.stderr[-300:]}")
check("the process does not report the seeded comments", proc.stdout.strip() == "", repr(proc.stdout[:160]))
check("the process seeds the snapshot", os.path.exists(os.path.join(orch_proc, "state", "comments", f"pr-{PR_NUM}.json")))
check("the process releases the lock", not os.path.exists(os.path.join(orch_proc, "locks", "comment-watch.lock")))

print("21. the harness: no network, no real ORCH_DIR")
check("the PATH gh was never invoked", not os.path.exists(RED), "the sentinel gh was called")
check("the stub was used", os.path.exists(CALLS) and os.path.getsize(CALLS) > 0, "the stub was never called")
mod = r[-1]["mod"]
rutas = (mod.STATE, mod.SNAP_DIR, mod.PENDING, mod.LOG, mod.HISTORY, getattr(mod, "LOCK", ""))
check(
    "the watcher works inside the tmpdir",
    all(p.startswith(TMP) for p in rutas),
    str(rutas),
)
check("the watcher has a lock", getattr(mod, "LOCK", None) is not None, "the watcher has no LOCK")
check("the watcher uses the stub gh", getattr(mod, "GH_BIN", None) == STUB, str(getattr(mod, "GH_BIN", None)))
if not ORCH_REAL_EXISTIA:
    check("the real ORCH_DIR was not created", not os.path.exists(ORCH_REAL), ORCH_REAL)

print()
shutil.rmtree(TMP, ignore_errors=True)
if fallos:
    print(f"FAILED {len(fallos)}: {fallos}")
    sys.exit(1)
print("all the tests pass")
