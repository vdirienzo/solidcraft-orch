#!/usr/bin/env python3
"""El caso de control del issue #10181: un fallo REAL del comando `sketch.project`
(la cara ya esta proyectada) sigue mostrando la fila roja con el boton
"Create Issue...".

Es el contrapeso de la captura AFTER: el arreglo saca el boton SOLO cuando el
error es una negativa de contexto, no cuando el comando falla de verdad.

Uso: capture-10181-control.py <port> <token> <outdir>
"""
import json
import os
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 27878
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""
# The path comes from the environment, with the default of THIS machine: the
# other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR = os.environ.get("ORCH_DIR", os.path.expanduser("~/.local/share/solidcraft-orch"))
OUTDIR = sys.argv[3] if len(sys.argv) > 3 else f"{ORCH_DIR}/logs/evidence-10181"


class Conn:
    def __init__(self, host, port, token):
        self.s = socket.create_connection((host, port), timeout=30)
        self.f = self.s.makefile("rwb")
        self.token = token
        self.authed = False

    def __call__(self, method, params=None, timeout=180):
        msg = {"method": method, "params": params or {}}
        if not self.authed:
            msg["token"] = self.token
        self.f.write((json.dumps(msg) + "\n").encode())
        self.f.flush()
        self.s.settimeout(timeout)
        line = self.f.readline()
        if not line:
            raise RuntimeError(f"sin respuesta de {method}")
        self.authed = True
        reply = json.loads(line)
        if not reply.get("ok", False):
            print(f"  AVISO: {method} -> {json.dumps(reply)[:400]}")
        return reply

    def execute(self, command, params=None):
        return self("engine.execute", {"command": command, "params": params or {}})


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    c = Conn(HOST, PORT, TOKEN)
    log = []

    def step(name, value):
        log.append(f"===== {name} =====\n{value}\n")
        print(f"  {name}: {str(value)[:400]}")

    def pump(n=8, each=0.06):
        for _ in range(n):
            time.sleep(each)
            c("ui.inspect", {})

    c("ui.documents", {"action": "new"})
    pump(4)

    r = c.execute("solid.box", {"length": 40, "width": 30, "height": 20, "body_name": "Body1"})
    step("solid.box", json.dumps(r.get("result") or r.get("error"))[:300])
    pump(4)

    r = c.execute("sketch.create", {"plane": "XY"})
    step("sketch.create", json.dumps(r.get("result") or r.get("error"))[:300])
    pump(4)

    FACE = {"type": "face", "body": "Body1", "index": 5, "point": [20.0, 15.0, 20.0]}
    r = c.execute("select.set", {"items": [FACE]})
    step("select.set", json.dumps(r.get("result") or r.get("error"))[:300])
    pump(4)

    # La cara ya queda proyectada en el esbozo: proyectarla otra vez es un fallo
    # REAL del comando (no una negativa de contexto).
    r = c.execute("sketch.project", {"refs": [{"body": "Body1", "face": [20.0, 15.0, 20.0]}], "projection_link": True})
    step("sketch.project (la primera, la que funciona)", json.dumps(r.get("result") or r.get("error"))[:300])
    pump(6)

    # El panel Project, con la misma cara ya proyectada.
    r = c.execute("select.set", {"items": [FACE]})
    step("select.set (otra vez)", json.dumps(r.get("result") or r.get("error"))[:300])
    pump(4)
    r = c("ui.start", {"command": "sketch.project"})
    step("ui.start sketch.project", json.dumps(r.get("result"))[:300])
    pump(6)

    handles = (c("ui.handles", {"prefix": "dialog:ok"}).get("result") or [])
    ok = next((h for h in handles if h.get("name") == "dialog:ok"), None)
    step("handles dialog:ok", json.dumps(handles)[:300])
    if ok:
        c("ui.move", {"x": ok["x"], "y": ok["y"]})
        pump(8)
        c("ui.click", {"x": ok["x"], "y": ok["y"]})
        pump(10)

    st = c("ui.inspect", {}).get("result") or {}
    step("inspect: dialog con el error", json.dumps(st.get("dialog"))[:900])
    step("inspect: status", json.dumps(st.get("status"))[:400])

    handles = (c("ui.handles", {"prefix": "dialog:"}).get("result") or [])
    step("handles dialog:* (final)", json.dumps(handles)[:900])
    has_button = any(h.get("name") == "dialog:create_issue" for h in handles)
    step("boton Create Issue presente", has_button)

    png = os.path.join(OUTDIR, "10181-project-panel-real-failure.png")
    r = c("ui.screenshot", {"path": png})
    step("ui.screenshot", json.dumps(r.get("result") or r.get("error"))[:300])
    pump(3)

    with open(os.path.join(OUTDIR, "10181-control-inspect.txt"), "w") as fh:
        fh.write("\n".join(log))

    print("\nPNGs:")
    print(" ", png, os.path.getsize(png) if os.path.exists(png) else "NO EXISTE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
