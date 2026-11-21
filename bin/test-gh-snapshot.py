#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# test-gh-snapshot.py - la foto de GitHub (bin/gh_snapshot.py) esta entera o
# no esta.
#
# QUE PRUEBA, con un gh de mentira que pagina GraphQL desde una fixture:
#   - la foto entera: todos los issues y PRs abiertos (los dos cursores se
#     cruzan y no bajan todo dos veces), con las formas de `gh ... --json`;
#   - --max-age-min reusa una foto fresca sin llamar a GitHub;
#   - el refresco: solo lo que cambio (cerrados afuera, nuevos y editados
#     adentro), y si no cuadra con el totalCount, la foto entera;
#   - GitHub que falla a mitad de camino, o que responde con errores, o una
#     foto con agujeros: sale 2 y la foto anterior queda IGUAL, sin .tmp;
#   - load() rechaza una foto incompleta, de otra version o vieja.
#
# NUNCA toca GitHub. Corre: python3 bin/test-gh-snapshot.py
# ---------------------------------------------------------------------------
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gh_snapshot  # noqa: E402

PASS = 0
FAIL = 0


def ok(name):
    global PASS
    PASS += 1
    print(f"ok   - {name}")


def no(name, detail=""):
    global FAIL
    FAIL += 1
    print(f"FALLA- {name}")
    if detail:
        print(f"       {detail}")


STUB = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
vals = {}
for i, a in enumerate(args):
    if a in ("-f", "-F") and i + 1 < len(args):
        k, _, v = args[i + 1].partition("=")
        vals[k] = v
calls = os.environ["STUB_DIR"] + "/calls"
n = sum(1 for _ in open(calls)) + 1 if os.path.exists(calls) else 1
query = vals.get("query", "")
conn = "pullRequests" if "pullRequests(" in query else "issues"
changed = "UPDATED_AT" in query
with open(calls, "a") as fh:
    fh.write(f"{conn} {'cambios' if changed else vals.get('dir')} {vals.get('after', '-')} {vals.get('first')}\n")
fail_from = int(os.environ.get("STUB_FAIL_FROM", "0") or 0)
if fail_from and n >= fail_from:
    print("gh: HTTP 502: Bad Gateway", file=sys.stderr)
    sys.exit(1)
data = json.load(open(os.environ["STUB_DIR"] + "/data.json"))
if data.get("graphql_errors"):
    print(json.dumps({"errors": [{"message": "Something went wrong"}]}))
    sys.exit(0)
nodes = data["issues" if conn == "issues" else "prs"]
open_nodes = [x for x in nodes if x.get("state", "OPEN") == "OPEN"]
first = int(vals.get("first") or 100)
start = int(vals["after"][1:]) if vals.get("after") else 0
if changed:
    seq = sorted(nodes, key=lambda x: x["updatedAt"], reverse=True)
    if conn == "issues" and vals.get("since"):
        seq = [x for x in seq if x["updatedAt"] >= vals["since"]]
else:
    seq = sorted(open_nodes, key=lambda x: x["number"], reverse=vals.get("dir") == "DESC")
page = seq[start:start + first]
end = start + len(page)
body = {"pageInfo": {"hasNextPage": end < len(seq), "endCursor": f"c{end}" if page else None}, "nodes": page}
repo = {conn: body}
if changed:
    repo["open"] = {"totalCount": len(open_nodes) + int(data.get("open_extra", 0))}
else:
    body["totalCount"] = len(open_nodes) + int(data.get("total_extra", 0))
print(json.dumps({"data": {"rateLimit": {"cost": 2, "remaining": 4000 - n}, "repository": repo}}))
'''


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def node_issue(n, updated):
    return {"number": n, "title": f"issue {n}", "body": f"body {n}", "state": "OPEN",
            "createdAt": iso(1e9 + n), "updatedAt": updated, "author": {"login": "someone"},
            "labels": {"nodes": [{"name": "bug"}]}, "assignees": {"nodes": []},
            "comments": {"totalCount": 7, "nodes": [{"author": {"login": "triager"}, "body": "seen", "createdAt": updated}]}}


def node_pr(n, updated):
    return {"number": n, "title": f"pr (#{n - 10000})", "body": "", "state": "OPEN", "isDraft": True,
            "headRefName": f"fix-{n}", "baseRefName": "main", "createdAt": iso(1e9 + n), "updatedAt": updated,
            "author": {"login": "rival"}, "labels": {"nodes": []}, "additions": 3, "deletions": 1, "changedFiles": 1}


def main():
    tmp = tempfile.mkdtemp(prefix="test-gh-snapshot.")
    try:
        run_tests(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n{PASS + FAIL} casos, {FAIL} fallan")
    return 1 if FAIL else 0


def run_tests(tmp):
    stub_dir = os.path.join(tmp, "stub")
    os.makedirs(stub_dir)
    stub = os.path.join(stub_dir, "gh")
    with open(stub, "w", encoding="utf-8") as fh:
        fh.write(STUB)
    os.chmod(stub, 0o755)
    old = iso(time.time() - 7200)
    data = {"issues": [node_issue(n, old) for n in range(1, 251)],
            "prs": [node_pr(n, old) for n in range(10001, 10131)]}

    def put(d):
        with open(os.path.join(stub_dir, "data.json"), "w", encoding="utf-8") as fh:
            json.dump(d, fh)
        calls = os.path.join(stub_dir, "calls")
        if os.path.exists(calls):
            os.unlink(calls)

    def calls():
        p = os.path.join(stub_dir, "calls")
        return open(p).read().splitlines() if os.path.exists(p) else []

    out = os.path.join(tmp, "orch", "state", "cache", "gh-snapshot.json")
    env = dict(os.environ, GH_BIN=stub, STUB_DIR=stub_dir, ORCH_DIR=os.path.join(tmp, "orch"),
               GH_SNAPSHOT_RETRY_SLEEP="0", UPSTREAM_REPO="tangency-labs/solidcraft")
    env.pop("GH_SNAPSHOT", None)

    def run(*args, extra=None):
        return subprocess.run([sys.executable, os.path.join(HERE, "gh_snapshot.py"), *args],
                              capture_output=True, text=True, env=dict(env, **(extra or {})), timeout=120)

    def leftovers():
        d = os.path.dirname(out)
        return [f for f in os.listdir(d) if ".tmp." in f] if os.path.isdir(d) else []

    # --- the full photo -----------------------------------------------------
    put(data)
    done = run()
    snap, why = gh_snapshot.load(out)
    if done.returncode == 0 and done.stdout.strip() == out and snap is not None:
        ok("la foto entera se escribe en state/cache/gh-snapshot.json y dice donde quedo")
    else:
        no("la foto entera se escribe", f"rc={done.returncode} {why} {done.stderr[-300:]}")
        return
    if sorted(i["number"] for i in snap["issues"]) == list(range(1, 251)) and \
            [p["number"] for p in snap["prs"]] == list(range(10001, 10131)):
        ok("estan TODOS los issues (250) y TODOS los PRs (130) abiertos, sin repetidos")
    else:
        no("estan todos los issues y PRs", f"{len(snap['issues'])} issues, {len(snap['prs'])} PRs")
    issue_calls = [c for c in calls() if c.startswith("issues")]
    if len(issue_calls) <= 5 and any(" DESC " in c for c in issue_calls):
        ok(f"los dos cursores se cruzan: {len(issue_calls)} paginas para 250 issues, no el doble")
    else:
        no("los dos cursores se cruzan", " | ".join(issue_calls))
    i1 = next(i for i in snap["issues"] if i["number"] == 1)
    if i1["labels"] == [{"name": "bug"}] and i1["comments"][0]["author"] == {"login": "triager"} \
            and i1["commentsCount"] == 7 and snap["prs"][0]["author"] == {"login": "rival"}:
        ok("las formas son las de `gh ... --json` (labels[].name, comments[].author.login, author.login)")
    else:
        no("las formas son las de gh --json", json.dumps(i1)[:300])
    if snap["api"]["pages"] == len(calls()) and snap["api"]["cost"] == 2 * len(calls()) and snap["mode"] == "full":
        ok("la foto anota sus paginas y su costo en puntos (rateLimit.cost)")
    else:
        no("la foto anota sus paginas y su costo", json.dumps(snap["api"]))
    if not leftovers():
        ok("no queda ningun .tmp al lado de la foto")
    else:
        no("no queda ningun .tmp al lado de la foto", str(leftovers()))

    # --- reuse ----------------------------------------------------------------
    put(data)
    done = run("--max-age-min", "15")
    if done.returncode == 0 and not calls() and "reusada" in done.stderr:
        ok("--max-age-min reusa la foto fresca sin llamar a GitHub")
    else:
        no("--max-age-min reusa la foto fresca", f"rc={done.returncode} llamadas={calls()}")

    # --- the refresh ------------------------------------------------------------
    now = iso(time.time())
    changed = json.loads(json.dumps(data))
    changed["issues"][4]["state"] = "CLOSED"  # #5
    changed["issues"][4]["updatedAt"] = now
    changed["issues"][9]["title"] = "issue 10, edited"  # #10
    changed["issues"][9]["updatedAt"] = now
    changed["issues"].append(node_issue(999, now))
    changed["prs"][0]["state"] = "MERGED"  # 10001
    changed["prs"][0]["updatedAt"] = now
    changed["prs"].append(node_pr(10500, now))
    put(changed)
    done = run()
    snap, _ = gh_snapshot.load(out)
    nums = {i["number"] for i in snap["issues"]}
    title10 = next(i["title"] for i in snap["issues"] if i["number"] == 10)
    prs = {p["number"] for p in snap["prs"]}
    if done.returncode == 0 and snap["mode"] == "incremental" and 5 not in nums and 999 in nums \
            and title10 == "issue 10, edited" and 10001 not in prs and 10500 in prs and len(calls()) <= 2:
        ok(f"el refresco trae solo lo que cambio ({len(calls())} paginas): cerrados afuera, nuevos y editados adentro")
    else:
        no("el refresco trae solo lo que cambio",
           f"rc={done.returncode} modo={snap and snap.get('mode')} llamadas={calls()} {done.stderr[-200:]}")

    bad = dict(changed, open_extra=1)
    put(bad)
    done = run()
    snap, _ = gh_snapshot.load(out)
    if done.returncode == 0 and snap["mode"] == "full" and "no sirvio" in done.stderr:
        ok("un refresco que no cuadra con el totalCount se descarta: se baja la foto entera")
    else:
        no("un refresco que no cuadra se descarta", f"rc={done.returncode} modo={snap and snap.get('mode')}")

    put(changed)
    done = run("--full")
    snap, _ = gh_snapshot.load(out)
    if done.returncode == 0 and snap["mode"] == "full" and not any("cambios" in c for c in calls()):
        ok("--full baja la foto entera aunque se pueda refrescar")
    else:
        no("--full baja la foto entera", f"modo={snap and snap.get('mode')} {calls()}")

    # --- GitHub fails: nothing is written ------------------------------------------
    before = open(out, "rb").read()
    put(changed)
    done = run("--full", extra={"STUB_FAIL_FROM": "3"})
    if done.returncode == 2 and open(out, "rb").read() == before and not leftovers() \
            and "NO se escribio" in done.stderr:
        ok("GitHub que falla a mitad de camino: rc=2 y la foto anterior queda igual")
    else:
        no("GitHub que falla a mitad de camino", f"rc={done.returncode} {done.stderr[-200:]}")

    put(dict(changed, graphql_errors=True))
    done = run("--full")
    if done.returncode == 2 and open(out, "rb").read() == before:
        ok("una respuesta de GraphQL con errores: rc=2, nada escrito")
    else:
        no("una respuesta de GraphQL con errores", f"rc={done.returncode}")

    put(dict(changed, total_extra=50))
    fresh = os.path.join(tmp, "otra", "foto.json")
    done = run("--out", fresh, "--full")
    if done.returncode == 2 and not os.path.exists(fresh) and "agujeros" in done.stderr:
        ok("una foto con agujeros (50 menos que el totalCount) no se escribe")
    else:
        no("una foto con agujeros no se escribe", f"rc={done.returncode} {done.stderr[-200:]}")

    done = run("--max-age-min", "nada")
    if done.returncode == 64:
        ok("un error de uso sale 64")
    else:
        no("un error de uso sale 64", f"rc={done.returncode}")

    # --- load() ------------------------------------------------------------------
    good, _ = gh_snapshot.load(out)
    for name, mutate, max_age in (
        ("incompleta", lambda s: s.update(complete=False), None),
        ("de otra version", lambda s: s.update(version=99), None),
        ("vieja", lambda s: s.update(generated_epoch=time.time() - 3600), 15),
    ):
        s = json.loads(json.dumps(good))
        mutate(s)
        p = os.path.join(tmp, f"load-{name}.json")
        with open(p, "w", encoding="utf-8") as fh:
            json.dump(s, fh)
        got, why = gh_snapshot.load(p, max_age)
        if got is None and why:
            ok(f"load() rechaza una foto {name} ({why[:50]})")
        else:
            no(f"load() rechaza una foto {name}")
    got, why = gh_snapshot.load(os.path.join(tmp, "no-esta.json"))
    if got is None and "no hay foto" in why:
        ok("load() sin archivo dice que no hay foto")
    else:
        no("load() sin archivo dice que no hay foto", str(why))


if __name__ == "__main__":
    sys.exit(main())
