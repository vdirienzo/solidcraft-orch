#!/usr/bin/env python3
"""Captura la evidencia visual del issue #10181: el panel Project que se queda
abierto mientras el sketch termina.

Habla con el control channel de la app (TCP, JSON por linea; la PRIMERA linea
lleva el token) y produce dos PNG de 1280x800:

  - BEFORE: el panel Project con la fila ROJA y el boton "Create Issue...";
  - AFTER:  el mismo panel con el texto de guia y SIN el boton.

Que la app procese los eventos de puntero es lo unico que hace falta: procesa UN
evento de puntero POR FRAME (synthetic_input), asi que entre el move y el click
hay que dejar que corra el loop. Por eso el "pump": varias llamadas a ui.inspect
con una pausa entre cada una.

El PNG sale de ui.screenshot (la ventana con el overlay de egui, donde se dibuja
el panel del dialogo); ui.render solo dibuja la escena 3D y no incluye el panel.

Uso: capture-10181-evidence.py <port> <token> <outdir> <before|after>
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
TAG = sys.argv[4] if len(sys.argv) > 4 else "after"

WIDTH, HEIGHT = 1280, 800


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

    def pump(n=8, each=0.06):
        """La app procesa UN evento de puntero por frame: hay que dejar correr
        el loop entre el move y el click, o el click llega sin puntero."""
        for _ in range(n):
            time.sleep(each)
            c("ui.inspect", {})

    def fresh_doc():
        """Un diseno vacio y solo ese: la evidencia sale de un estado limpio."""
        c("ui.documents", {"action": "new"})
        pump(4)
        docs = (c("ui.documents", {}).get("result") or {})
        active = docs.get("active", 0)
        for i in range(len(docs.get("documents", [])) - 1, -1, -1):
            if i != active:
                c("ui.documents", {"action": "close", "index": i, "force": True, "answer": "dont_save"})
        pump(3)
        return (c("ui.documents", {}).get("result") or {}).get("documents")

    log = []

    def step(name, value):
        log.append(f"===== {name} =====\n{value}\n")
        print(f"  {name}: {str(value)[:300]}")

    print("=== diseno limpio")
    step("documentos", json.dumps(fresh_doc())[:300])

    # --- el cuerpo y el esbozo ---------------------------------------------
    print("=== el cuerpo")
    r = c.execute("solid.box", {"length": 40, "width": 30, "height": 20, "body_name": "Body1"})
    step("solid.box", json.dumps(r.get("result"))[:400])
    pump(4)

    print("=== el esbozo")
    r = c.execute("sketch.create", {"plane": "XY"})
    step("sketch.create", json.dumps(r.get("result"))[:400])
    pump(4)

    # --- la cara que se proyecta -------------------------------------------
    print("=== la seleccion: la cara de arriba de Body1")
    r = c.execute("select.set", {"items": [{"type": "face", "body": "Body1", "index": 5, "point": [20.0, 15.0, 20.0]}]})
    step("select.set", json.dumps(r.get("result") or r.get("error"))[:400])
    pump(4)

    # --- el panel Project (dialogo) ---------------------------------------
    # `ui.start` abre el dialogo del comando: el panel Project del esbozo.
    print("=== el panel Project")
    r = c("ui.start", {"command": "sketch.project"})
    step("ui.start sketch.project", json.dumps(r.get("result"))[:400])
    pump(6)

    st = c("ui.inspect", {}).get("result") or {}
    step("inspect: dialog", json.dumps(st.get("dialog"))[:400])

    handles = (c("ui.handles", {"prefix": "dialog:"}).get("result") or [])
    step("handles dialog:*", json.dumps(handles)[:800])

    # --- el esbozo termina: el contexto se va ------------------------------
    # Esto es lo que hace el issue: el panel queda abierto y el comando
    # `sketch.project` ya no esta disponible (no se esta editando un esbozo).
    print("=== el esbozo termina (el contexto se va)")
    r = c.execute("sketch.finish", {})
    step("sketch.finish", json.dumps(r.get("result") or r.get("error"))[:400])
    pump(8)

    st = c("ui.inspect", {}).get("result") or {}
    step("inspect: dialog tras el fin", json.dumps(st.get("dialog"))[:400])
    step("inspect: status", json.dumps(st.get("status"))[:400])

    # --- OK: el comando se corre y el motor lo rechaza ----------------------
    # Es el paso que produce el error: `sketch.project` ya no esta disponible
    # (no se esta editando un esbozo). El panel lo muestra como texto de guia
    # (sin boton "Create Issue...") con el arreglo.
    print("=== OK del panel Project (el motor rechaza el comando)")
    handles = (c("ui.handles", {"prefix": "dialog:ok"}).get("result") or [])
    step("handles dialog:ok", json.dumps(handles)[:400])
    ok = next((h for h in handles if h.get("name") == "dialog:ok"), None)
    if ok:
        print("  ui.move ->", json.dumps(c("ui.move", {"x": ok["x"], "y": ok["y"]}).get("result"))[:120])
        pump(8)
        print("  ui.click ->", json.dumps(c("ui.click", {"x": ok["x"], "y": ok["y"]}).get("result"))[:120])
        pump(10)
    else:
        print("  AVISO: no se encontro el boton OK")

    st = c("ui.inspect", {}).get("result") or {}
    step("inspect: dialog con el error", json.dumps(st.get("dialog"))[:900])
    step("inspect: status", json.dumps(st.get("status"))[:400])

    handles = (c("ui.handles", {"prefix": "dialog:"}).get("result") or [])
    step("handles dialog:* (final)", json.dumps(handles)[:900])
    has_button = any(h.get("name") == "dialog:create_issue" for h in handles)
    step("boton Create Issue presente", has_button)

    # --- la captura --------------------------------------------------------
    png = os.path.join(OUTDIR, f"10181-project-panel-{TAG}.png")
    r = c("ui.screenshot", {"path": png})
    step("ui.screenshot", json.dumps(r.get("result") or r.get("error"))[:400])
    pump(3)

    # Una segunda captura, por si la primera salio antes de que el panel
    # terminara de dibujar la fila.
    png2 = os.path.join(OUTDIR, f"10181-project-panel-{TAG}-2.png")
    r = c("ui.screenshot", {"path": png2})
    step("ui.screenshot 2", json.dumps(r.get("result") or r.get("error"))[:400])

    with open(os.path.join(OUTDIR, f"10181-{TAG}-inspect.txt"), "w") as fh:
        fh.write("\n".join(log))

    print("\nPNGs:")
    for p in (png, png2):
        print(" ", p, os.path.getsize(p) if os.path.exists(p) else "NO EXISTE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
