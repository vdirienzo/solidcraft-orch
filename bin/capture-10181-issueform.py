#!/usr/bin/env python3
"""El sintoma tal cual lo reporta el issue #10181: el boton "Create Issue..."
abre el formulario "Report a bug" ENCIMA del viewport, y no se puede cerrar
ni mover.

Solo se puede capturar con la app SIN el arreglo (antes): con el arreglo el
boton no esta.

Uso: capture-10181-issueform.py <port> <token> <outdir>
"""
import json
import os
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 27879
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""
OUTDIR = sys.argv[3] if len(sys.argv) > 3 else "/home/user/.local/share/solidcraft-orch/logs/evidence-10181"


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
        print(f"  {name}: {str(value)[:300]}")

    def pump(n=8, each=0.06):
        for _ in range(n):
            time.sleep(each)
            c("ui.inspect", {})

    c("ui.documents", {"action": "new"})
    pump(4)
    c.execute("solid.box", {"length": 40, "width": 30, "height": 20, "body_name": "Body1"})
    pump(4)
    c.execute("sketch.create", {"plane": "XY"})
    pump(4)
    FACE = {"type": "face", "body": "Body1", "index": 5, "point": [20.0, 15.0, 20.0]}
    c.execute("select.set", {"items": [FACE]})
    pump(4)
    c("ui.start", {"command": "sketch.project"})
    pump(6)
    c.execute("sketch.finish", {})
    pump(8)

    handles = (c("ui.handles", {"prefix": "dialog:ok"}).get("result") or [])
    ok = next((h for h in handles if h.get("name") == "dialog:ok"), None)
    if ok:
        c("ui.move", {"x": ok["x"], "y": ok["y"]})
        pump(8)
        c("ui.click", {"x": ok["x"], "y": ok["y"]})
        pump(10)

    # El boton "Create Issue...": el que abre el formulario sobre el viewport.
    handles = (c("ui.handles", {"prefix": "dialog:create_issue"}).get("result") or [])
    step("handles dialog:create_issue", json.dumps(handles)[:300])
    issue = next((h for h in handles if h.get("name") == "dialog:create_issue"), None)
    if issue:
        c("ui.move", {"x": issue["x"], "y": issue["y"]})
        pump(8)
        c("ui.click", {"x": issue["x"], "y": issue["y"]})
        pump(12)

    st = c("ui.inspect", {}).get("result") or {}
    step("inspect: status", json.dumps(st.get("status"))[:300])
    handles = (c("ui.handles", {"prefix": ""}).get("result") or [])
    step("handles (todas)", json.dumps([h["name"] for h in handles])[:1200])

    png = os.path.join(OUTDIR, "10181-report-a-bug-form.png")
    r = c("ui.screenshot", {"path": png})
    step("ui.screenshot", json.dumps(r.get("result") or r.get("error"))[:300])
    pump(3)

    with open(os.path.join(OUTDIR, "10181-issueform-inspect.txt"), "w") as fh:
        fh.write("\n".join(log))

    print("\nPNGs:")
    print(" ", png, os.path.getsize(png) if os.path.exists(png) else "NO EXISTE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
