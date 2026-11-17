#!/usr/bin/env python3
"""Visual evidence for #17070 (PR 17609): the question card in the Assistant panel.

Drives the real SolidCraft app over its control channel and takes pictures of
the whole window showing:

  (a) a question from a connected agent with its choice buttons, plus Decline
      and Cancel;
  (b) a link question from the same agent, with its Open button.

The agent is a real ACP process (a stand-in that speaks the Agent Client
Protocol over stdin/stdout), so the card is produced by the protocol path the
change adds, not by a mock of the panel.

Usage:
  capture-17070-evidence.py <port> <token> <outdir> <mode>

`<mode>` is `form` (the question with choices) or `link` (the question with an
address). The script prints what it did and what it read back. It never
fabricates a picture: if the app cannot be driven to the state, it exits
non-zero and says why.
"""
import json
import os
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 27970
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""
OUTDIR = sys.argv[3] if len(sys.argv) > 3 else os.path.join(
    os.environ.get("SCRATCH_DIR", os.path.expanduser("~/scratch")), "17070", "out")
MODE = sys.argv[4] if len(sys.argv) > 4 else "form"

AGENT_ID = "evidence-agent"
AGENT_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fake_acp_agent.py")
AGENT_LOG = os.path.join(OUTDIR, f"agent-protocol-{MODE}.log")

MESSAGE = "Build a bracket for the enclosure."


class Conn:
    def __init__(self, host, port, token):
        self.s = socket.create_connection((host, port), timeout=60)
        self.f = self.s.makefile("rwb")
        self.token = token
        self.authed = False

    def __call__(self, method, params=None, timeout=300):
        msg = {"method": method, "params": params or {}}
        if not self.authed:
            msg["token"] = self.token
        self.f.write((json.dumps(msg) + "\n").encode())
        self.f.flush()
        self.s.settimeout(timeout)
        line = self.f.readline()
        if not line:
            raise RuntimeError(f"the app closed the channel on {method}")
        self.authed = True
        reply = json.loads(line)
        if not reply.get("ok", False):
            print(f"  AVISO {method}: {json.dumps(reply)[:400]}")
        return reply

    def chat(self, params, timeout=300):
        """`ui.agent_chat`, and the chat's state as the app reports it."""
        r = self("ui.agent_chat", params, timeout=timeout)
        return r.get("result") or {}


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    c = Conn(HOST, PORT, TOKEN)
    log = []

    def note(tag, extra=None):
        rec = {"tag": tag}
        if extra:
            rec.update(extra)
        log.append(rec)
        print(f"  [{tag}] {json.dumps(extra)[:500] if extra else ''}")

    def pump(k=6, each=0.12):
        """Let the app run its frames between the calls."""
        for _ in range(k):
            time.sleep(each)
            c("ui.inspect", {})

    # ------------------------------------------------------------- the agent
    print("=== the agent is added to the panel's agents")
    command = f"python3 {AGENT_SCRIPT} {MODE} {AGENT_LOG}"
    state = c.chat({"add_agent": {"id": AGENT_ID, "name": "Evidence Agent", "kind": "acp", "command": command}})
    note("agent-added", {"id": AGENT_ID, "command": command, "agents": state.get("agents")})

    print("=== the agent is picked and connected")
    state = c.chat({"agent": AGENT_ID})
    state = c.chat({"connect": True})
    deadline = time.time() + 30
    while time.time() < deadline:
        pump(2)
        state = c.chat({})
        if state.get("state") == "ready":
            break
    note("connected", {"state": state.get("state"), "currentAgent": state.get("currentAgent")})
    if state.get("state") != "ready":
        print(f"  ERROR: the agent did not become ready: {state.get('state')}")
        print("  the app said:", json.dumps(state.get("items"))[:800])
        return 1

    print("=== the panel is open")
    c.chat({"open": True})
    pump(3)

    print("=== the message goes out, and the agent asks its question")
    c.chat({"send": MESSAGE})
    deadline = time.time() + 30
    question = None
    while time.time() < deadline:
        pump(2)
        state = c.chat({})
        for item in state.get("items") or []:
            if "question" in item:
                question = item
                break
        if question:
            break
    if not question:
        print("  ERROR: the question never reached the panel")
        print("  the app said:", json.dumps(state.get("items"))[:1200])
        return 1
    note("question", question)
    print("  the question:", json.dumps(question)[:600])

    # The card is drawn in the panel: let the frames run, then look.
    pump(8)

    print("=== the picture")
    name = f"17070-{MODE}.png"
    path = os.path.join(OUTDIR, name)
    r = c("ui.screenshot", {"path": path})
    ok = bool(r.get("ok", False))
    size = os.path.getsize(path) if os.path.exists(path) else 0
    print(f"  ui.screenshot {name} -> {'ok' if ok else json.dumps(r)[:300]} ({size} bytes)")
    if not ok or size == 0:
        print("  ERROR: the app did not write the picture")
        return 1

    # The same card in the smallest window the app allows: it must fit there too.
    print("=== the same card in the smallest window")
    small_name = f"17070-{MODE}-small-window.png"
    small_path = os.path.join(OUTDIR, small_name)
    c("ui.resize", {"width": 960, "height": 600})
    pump(8)
    r = c("ui.screenshot", {"path": small_path})
    small_ok = bool(r.get("ok", False))
    small_size = os.path.getsize(small_path) if os.path.exists(small_path) else 0
    print(f"  ui.screenshot {small_name} -> {'ok' if small_ok else json.dumps(r)[:300]} ({small_size} bytes)")
    c("ui.resize", {"width": 1280, "height": 720})
    pump(4)

    with open(os.path.join(OUTDIR, f"17070-{MODE}-estado.json"), "w") as fh:
        json.dump(
            {
                "puerto": PORT,
                "modo": MODE,
                "agente": {"id": AGENT_ID, "command": command, "log": AGENT_LOG},
                "mensaje": MESSAGE,
                "pregunta": question,
                "captura": {"nombre": name, "ruta": path, "bytes": size, "ok": ok},
                "captura_ventana_pequena": {"nombre": small_name, "ruta": small_path, "bytes": small_size, "ok": small_ok},
                "pasos": log,
            },
            fh,
            indent=1,
        )

    print("\n=== resumen")
    print(f"  pregunta: {question.get('question')}")
    print(f"  opciones: {[o.get('name') for o in question.get('options') or []]}")
    print(f"  enlace:   {question.get('url')}")
    print(f"  respuesta dada: {question.get('answer')}")
    print("\nPNGs en", OUTDIR)
    print("  ", name, size, "bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
