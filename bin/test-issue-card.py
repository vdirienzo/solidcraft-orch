#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# test-issue-card.py - la ficha de un issue (bin/issue-card.py).
#
# QUE PRUEBA:
#   - la mitad del script: los textos de error citados, buscados con git grep
#     en el origin/main de un checkout de mentira, los crates de los hits y
#     kernel_cause (todos los hits que no son tests estan en el kernel);
#   - la mitad del modelo, con un opencode de mentira (OPENCODE_BIN, fuera del
#     PATH) que imprime un stream de eventos JSON: el JSON sale del ULTIMO
#     objeto del texto (con prosa, con un bloque ```json, partido en dos
#     eventos, con un ejemplo antes), los tipos se corrigen ("true", "120"), un
#     stream sin JSON deja llm.error y la ficha del script igual se guarda;
#   - el modelo es TRIAGE_MODEL, o el AGENT_MODEL de bin/agent-env.sh;
#   - la ficha se arma UNA vez: la segunda llamada no llama al modelo;
#   - drop_reason: lo que next-issue.py deja por la ficha.
#
# NUNCA toca GitHub ni un modelo. Corre: python3 bin/test-issue-card.py
# ---------------------------------------------------------------------------
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
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


def load_module():
    spec = importlib.util.spec_from_file_location("issue_card", os.path.join(HERE, "issue-card.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ANSWER = {"one_topic": True, "bug_with_repro": True, "maintainer_decided": False,
          "crash_without_replay": False, "platform_specific": False, "est_diff_lines": 40, "reason": "one check"}

# The stub of opencode: it writes down its arguments and its directory, and
# prints the stream of STUB_MODE.
OPENCODE = r'''#!/usr/bin/env python3
import json, os, sys
d = os.environ["STUB_DIR"]
with open(os.path.join(d, "opencode.calls"), "a") as fh:
    fh.write(json.dumps({"args": sys.argv[1:], "cwd": os.getcwd(), "files": os.listdir(".")}) + "\n")
answer = json.dumps(json.loads(os.environ["STUB_ANSWER"]))
mode = os.environ.get("STUB_MODE", "normal")
def ev(t, **part):
    print(json.dumps({"type": t, "timestamp": 1, "sessionID": "s", "part": part}))
ev("step_start", id="a")
if mode == "normal":
    ev("text", id="t1", messageID="m", type="text", text="Here is the triage:\n```json\n" + answer + "\n```")
elif mode == "split":
    ev("text", id="t1", messageID="m", type="text", text='An example: {"one_topic": false} and the answer: ')
    ev("text", id="t1", messageID="m", type="text", text=answer[:20])
    ev("text", id="t1", messageID="m", type="text", text=answer[20:])
elif mode == "garbage":
    print("this is not json")
    print(json.dumps({"type": "error", "error": {"name": "ProviderError", "message": "quota"}}))
elif mode == "plain":
    print("plain answer " + answer)
ev("step_finish", id="b", cost=0.0021, tokens={"input": 900, "output": 60, "reasoning": 0})
'''


def git(cwd, *args):
    subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True, text=True)


def make_checkout(root):
    files = {
        "crates/kernel/src/blend.rs": 'Err("the blend radius is too large for the edge".into())\n',
        "crates/kernel/tests/blend_tests.rs": 'assert_eq!(e, "the blend radius is too large for the edge");\n',
        "crates/engine/src/cmd/box_cmd.rs": 'format!("invalid parameters for `{id}`: `length` must be positive")\n',
    }
    for path, text in files.items():
        full = os.path.join(root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as fh:
            fh.write(text)
    subprocess.run(["git", "init", "-q", root], check=True)
    git(root, "-c", "user.email=t@example.invalid", "-c", "user.name=t", "add", "-A")
    git(root, "-c", "user.email=t@example.invalid", "-c", "user.name=t", "commit", "-qm", "main")
    git(root, "update-ref", "refs/remotes/origin/main", "HEAD")


def issue(number, title, body, labels=()):
    return {"number": number, "title": title, "body": body, "labels": [{"name": l} for l in labels],
            "assignees": [], "comments": [], "commentsCount": 0, "createdAt": "2026-11-20T00:00:00Z",
            "updatedAt": "2026-11-20T00:00:00Z"}


def main():
    tmp = tempfile.mkdtemp(prefix="test-issue-card.")
    try:
        run_tests(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n{PASS + FAIL} casos, {FAIL} fallan")
    return 1 if FAIL else 0


def run_tests(tmp):
    checkout = os.path.join(tmp, "checkout")
    make_checkout(checkout)
    orch = os.path.join(tmp, "orch")
    stub_dir = os.path.join(tmp, "stub")
    os.makedirs(stub_dir)
    oc = os.path.join(stub_dir, "opencode")
    with open(oc, "w", encoding="utf-8") as fh:
        fh.write(OPENCODE)
    os.chmod(oc, 0o755)
    gh = os.path.join(stub_dir, "gh")
    with open(gh, "w", encoding="utf-8") as fh:
        fh.write("#!/usr/bin/env bash\nexit 1\n")
    os.chmod(gh, 0o755)

    issues = [
        issue(1, "Fillet: the blend fails", "Steps:\n```\nerror: the blend radius is too large for the edge\n```"),
        issue(2, "Box: a zero length is accepted",
              "Running it says `invalid parameters for `solid.box`: `length` must be positive` and goes on.",
              labels=["bug", "area:doc"]),
        issue(3, "Sketch: no quotes at all", "it just happens"),
    ]
    snap = os.path.join(orch, "state", "cache", "gh-snapshot.json")
    os.makedirs(os.path.dirname(snap))
    now = time.time()
    with open(snap, "w", encoding="utf-8") as fh:
        json.dump({"version": 1, "complete": True, "repo": "tangency-labs/solidcraft", "generated_epoch": now,
                   "started_epoch": now, "full_epoch": now, "issues": issues,
                   "prs": [{"number": 77, "title": "Box zero (#2)", "body": "", "author": {"login": "rival"}}]}, fh)
    env = dict(os.environ, ORCH_DIR=orch, SOLIDCRAFT_REPO=checkout, OPENCODE_BIN=oc, GH_BIN=gh,
               STUB_DIR=stub_dir, STUB_ANSWER=json.dumps(ANSWER), TRIAGE_MODEL="stub/triage",
               UPSTREAM_REPO="tangency-labs/solidcraft")
    env.pop("GH_SNAPSHOT", None)
    calls_path = os.path.join(stub_dir, "opencode.calls")

    def run(*args, **extra):
        return subprocess.run([sys.executable, os.path.join(HERE, "issue-card.py"), *args],
                              capture_output=True, text=True, env=dict(env, **extra), timeout=120)

    def calls():
        return [json.loads(l) for l in open(calls_path)] if os.path.exists(calls_path) else []

    def card_file(n):
        with open(os.path.join(orch, "state", "cards", f"{n}.json"), encoding="utf-8") as fh:
            return json.load(fh)

    # --- the script half -------------------------------------------------------
    done = run("1", "--no-llm")
    card = json.loads(done.stdout) if done.returncode == 0 else {}
    paths = sorted({h["path"] for h in card.get("hits", [])})
    if card.get("kernel_cause") is True and card.get("crates") == ["kernel"] and \
            "crates/kernel/tests/blend_tests.rs" in paths and card.get("llm") is None and not calls():
        ok("el texto de error sale del kernel (el test no cuenta): kernel_cause, sin llamar al modelo")
    else:
        no("kernel_cause por los hits del kernel", f"rc={done.returncode} {json.dumps(card)[:300]} {done.stderr[-200:]}")
    if card_file(1) == card:
        ok("la ficha queda en state/cards/<N>.json")
    else:
        no("la ficha queda en state/cards/<N>.json")

    done = run("2", "--no-llm")
    card = json.loads(done.stdout) if done.returncode == 0 else {}
    searched = {h["searched"] for h in card.get("hits", [])}
    if card.get("kernel_cause") is False and card.get("crates") == ["engine"] and "invalid parameters for" in searched:
        ok("un mensaje con partes variables se encuentra por su pedazo fijo (engine, no kernel)")
    else:
        no("el pedazo fijo del mensaje", json.dumps(card)[:400])
    if card.get("claim") == {"state": "taken", "pr": 77, "author": "rival"} and card.get("labels") == ["area:doc", "bug"]:
        ok("la ficha dice las etiquetas y quien tiene el claim (claim_rule, desde la foto)")
    else:
        no("la ficha dice las etiquetas y el claim", json.dumps(card.get("claim")))

    done = run("3", "--no-llm")
    card = json.loads(done.stdout) if done.returncode == 0 else {}
    if card.get("hits") == [] and card.get("kernel_cause") is False:
        ok("sin textos citados no hay hits ni kernel_cause")
    else:
        no("sin textos citados no hay hits", json.dumps(card)[:200])

    # --- the model half ----------------------------------------------------------
    done = run("2")
    card = json.loads(done.stdout) if done.stdout.strip() else {}
    llm = card.get("llm") or {}
    c = calls()
    args = c[-1]["args"] if c else []
    if done.returncode == 0 and {k: llm.get(k) for k in ANSWER} == ANSWER and llm.get("cost") == 0.0021 \
            and llm.get("tokens") == {"input": 900, "output": 60}:
        ok("el JSON sale del bloque ```json del texto, con el costo y los tokens del step_finish")
    else:
        no("el JSON del stream", f"rc={done.returncode} {json.dumps(llm)} {done.stderr[-200:]}")
    if len(c) == 1 and args[:2] == ["run", "--standalone"] and "--format" in args and \
            args[args.index("--format") + 1] == "json" and args[args.index("-m") + 1] == "stub/triage" \
            and "ISSUE #2: Box: a zero length is accepted" in args[-1] and "bug, area:doc" in args[-1]:
        ok("UNA llamada: opencode run --standalone --format json -m $TRIAGE_MODEL con el issue en el prompt")
    else:
        no("la llamada a opencode", json.dumps(args)[:400])
    if c and c[-1]["files"] == [] and os.path.realpath(c[-1]["cwd"]) != os.path.realpath(os.getcwd()):
        ok("el modelo corre en un directorio vacio (no lee ni toca el proyecto)")
    else:
        no("el modelo corre en un directorio vacio", json.dumps(c[-1] if c else {}))
    if card.get("crates") == ["engine"]:
        ok("la ficha con el modelo conserva la mitad del script")
    else:
        no("la ficha con el modelo conserva la mitad del script")

    done = run("2")
    if done.returncode == 0 and len(calls()) == 1 and "reusada" in done.stderr:
        ok("la ficha se arma una vez: la segunda llamada no llama al modelo")
    else:
        no("la ficha se arma una vez", f"llamadas={len(calls())} {done.stderr[-200:]}")
    done = run("2", "--force", STUB_MODE="split")
    llm = (json.loads(done.stdout) if done.stdout.strip() else {}).get("llm") or {}
    if done.returncode == 0 and len(calls()) == 2 and llm.get("one_topic") is True and llm.get("est_diff_lines") == 40:
        ok("--force la rehace; el texto partido en eventos se junta y gana el ULTIMO objeto (no el ejemplo)")
    else:
        no("el texto partido y el ultimo objeto", json.dumps(llm))

    done = run("3", STUB_MODE="plain", STUB_ANSWER=json.dumps(dict(ANSWER, one_topic="false", est_diff_lines="120")))
    llm = (json.loads(done.stdout) if done.stdout.strip() else {}).get("llm") or {}
    if done.returncode == 0 and llm.get("one_topic") is False and llm.get("est_diff_lines") == 120:
        ok("una respuesta fuera del stream y con tipos de texto ('false', '120') se entiende y se corrige")
    else:
        no("la respuesta fuera del stream", json.dumps(llm))

    done = run("1", "--force", STUB_MODE="garbage")
    card = json.loads(done.stdout) if done.stdout.strip() else {}
    llm = card.get("llm") or {}
    if done.returncode == 1 and "quota" in (llm.get("error") or "") and card_file(1).get("kernel_cause") is True:
        ok("un stream sin JSON deja llm.error (rc=1) y la ficha del script igual se guarda")
    else:
        no("un stream sin JSON", f"rc={done.returncode} {json.dumps(llm)}")

    env_model = dict(env)
    env_model.pop("TRIAGE_MODEL")
    done = subprocess.run([sys.executable, os.path.join(HERE, "issue-card.py"), "1", "--force"],
                          capture_output=True, text=True, timeout=120,
                          env=dict(env_model, AGENT_MODEL="stub/agent-model", AGENT_BIN=oc))
    args = calls()[-1]["args"]
    if args[args.index("-m") + 1] == "stub/agent-model":
        ok("sin TRIAGE_MODEL el modelo es el AGENT_MODEL de bin/agent-env.sh")
    else:
        no("sin TRIAGE_MODEL el modelo es el de agent-env.sh", json.dumps(args)[:200])

    done = run("424242", "--no-llm")
    if done.returncode == 2:
        ok("un issue que no esta en la foto ni en GitHub: rc=2")
    else:
        no("un issue que no se puede leer: rc=2", f"rc={done.returncode}")

    # --- drop_reason and the parser, in the module -----------------------------------
    os.environ["ORCH_DIR"] = orch
    mod = load_module()
    cases = (
        ({"kernel_cause": True, "crates": ["kernel"]}, "codigo aparcado"),
        ({"llm": dict(ANSWER, one_topic=False)}, "varios temas"),
        ({"llm": dict(ANSWER, bug_with_repro=False)}, "reproduccion"),
        ({"llm": dict(ANSWER, maintainer_decided=True)}, "maintainer"),
        ({"llm": dict(ANSWER, crash_without_replay=True)}, "crash sin replay"),
        ({"llm": dict(ANSWER, platform_specific=True)}, "plataforma"),
        ({"llm": dict(ANSWER, est_diff_lines=301)}, "301 lineas"),
        ({"llm": ANSWER}, None),
        ({"llm": {"error": "timeout"}}, None),
    )
    for card, want in cases:
        got = mod.drop_reason(card)
        if (want is None and got is None) or (want and got and want in got):
            ok(f"drop_reason: {want or 'se toma'}")
        else:
            no(f"drop_reason: {want or 'se toma'}", repr(got))
    obj, meta = mod.parse_events('{"type":"text","part":{"id":"x","text":"no json here"}}\n')
    if obj is None and meta["errors"] == []:
        ok("parse_events: sin objeto no inventa uno")
    else:
        no("parse_events: sin objeto no inventa uno", repr(obj))


if __name__ == "__main__":
    sys.exit(main())
