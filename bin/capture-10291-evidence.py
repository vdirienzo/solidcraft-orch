#!/usr/bin/env python3
"""Captura la evidencia visual del issue #10291: el dialogo Project con la recta
de otro sketch.

Reproduce los pasos del reporte (#10291) sobre la app real, por el canal de
control (TCP, JSON por linea; la PRIMERA linea lleva el token):

  1. sketch 1 sobre el plano XY, con una recta;
  2. un plano 2 paralelo (construct.plane.offset) y el sketch 2 sobre el;
  3. el dialogo Project (sketch.project con la preferencia del dialogo de
     opciones encendida);
  4. un click en la recta del sketch 1 en el viewport;
  5. el boton OK.

La diferencia BEFORE/AFTER no esta en el codigo de la app sino en el BINARIO:
este script es el MISMO para los dos, y lo que cambia es la build que se
lanza (main para el BEFORE, la rama del PR para el AFTER). Por eso el script
solo dice QUE capture y con que nombre.

La app procesa UN evento de puntero POR FRAME, asi que entre el move y el
click hay que dejar correr el loop: el "pump" (varias ui.inspect con una
pausa entre cada una) es lo que hace que el click llegue con puntero.

El PNG sale de ui.screenshot (la ventana con el overlay de egui, donde se ve el
dialogo y su mensaje de error); ui.render solo dibuja la escena 3D.

Uso: capture-10291-evidence.py <port> <token> <directorio-de-salida> <prefijo>
"""
import json
import os
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 27878
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""
OUTDIR = sys.argv[3] if len(sys.argv) > 3 else "/home/user/.local/share/solidcraft-orch/logs/evidence-10291"
PREFIX = sys.argv[4] if len(sys.argv) > 4 else "10291"


class Conn:
    def __init__(self, host, port, token):
        self.s = socket.create_connection((host, port), timeout=60)
        self.f = self.s.makefile("rwb")
        self.token = token
        self.authed = False
        self.id = 0

    def __call__(self, method, params=None, timeout=180):
        self.id += 1
        msg = {"id": self.id, "method": method, "params": params or {}}
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

    def run(command, params=None, label=None):
        r = c.execute(command, params)
        print(f"  {command} -> {json.dumps(r.get('result'))[:220]}")
        return r.get("result")

    def shot(name):
        path = os.path.join(OUTDIR, name)
        r = c("ui.screenshot", {"path": path})
        print(f"  ui.screenshot {name} -> {json.dumps(r.get('result'))[:200]}")
        return path

    def state():
        return (c("ui.inspect", {}).get("result") or {})

    print("\n=== la escena del reporte #10291 ===")
    # 1. El sketch 1 sobre el plano XY, con una recta.
    created = run("sketch.create", {"plane": "XY"}, "sketch 1")
    source = created.get("sketch") if isinstance(created, dict) else None
    run("sketch.line", {"points": [[10, 10], [30, 10]], "infer": False})
    run("sketch.finish", {})

    # 2. Un plano 2 PARALELO al 1 (a 10 mm por su normal) y el sketch 2 sobre el.
    run("construct.plane.offset", {"base": "XY", "offset": 10, "name": "Plane2"})
    run("sketch.create", {"plane": "Plane2"})

    # El sketch 1 tiene que verse para poder pickearlo: se muestra.
    c("ui.set", {"shownSketches": [source]})
    c("ui.view", {"view": "top"})
    pump(6)

    print("\n=== el dialogo Project ===")
    # El dialogo de opciones de Project: la preferencia por defecto lo abre.
    r = c("ui.start", {"command": "sketch.project"})
    print("  ui.start ->", json.dumps(r.get("result"))[:300])
    pump(6)
    st = state()
    print("  dialog:", json.dumps(st.get("dialog"))[:400])
    print("  status:", json.dumps(st.get("status"))[:200])

    # El click en la recta del sketch 1: el punto de pantalla de un punto de la
    # recta en el mundo (el punto medio de la recta, [20, 10, 0]).
    pts = (c("ui.worldToScreen", {"points": [[20, 10, 0]]}).get("result") or [None])[0]
    print("  el punto [20,10,0] en pantalla:", pts)
    if not pts:
        print("  ERROR: el punto no esta en pantalla")
        return 1
    sx, sy = float(pts[0]), float(pts[1])

    print("\n=== el pick de la recta del otro sketch ===")
    c("ui.move", {"x": sx, "y": sy})
    pump(8)
    c("ui.click", {"x": sx, "y": sy})
    pump(10)

    sel = (c("ui.selection", {}).get("result") or {})
    print("  la geometria del dialogo:", json.dumps(sel.get("dialog"))[:400])
    shot(f"{PREFIX}-dialog-pick.png")

    # El boton OK del dialogo: el handle "dialog:ok" lo publica la propia app.
    print("\n=== el boton OK ===")
    ok_at = (c("ui.at", {"handle": "dialog:ok"}).get("result") or None)
    print("  el boton OK en:", ok_at)
    if ok_at:
        c("ui.move", {"x": float(ok_at[0]), "y": float(ok_at[1])})
        pump(4)
        c("ui.click", {"x": float(ok_at[0]), "y": float(ok_at[1])})
        pump(10)

    st = state()
    print("  dialog despues del OK:", json.dumps(st.get("dialog"))[:400])
    print("  status despues del OK:", json.dumps(st.get("status"))[:300])
    sel = (c("ui.selection", {}).get("result") or {})
    print("  la geometria del dialogo (final):", json.dumps(sel.get("dialog"))[:400])

    shot(f"{PREFIX}-after-ok.png")

    # El modelo: el link de la curva proyectada, con el sketch de origen.
    insp = c.execute("sketch.inspect")
    print("  sketch.inspect ->", json.dumps(insp.get("result"))[:2000])

    with open(os.path.join(OUTDIR, f"{PREFIX}-state.txt"), "w") as fh:
        fh.write(f"PREFIX={PREFIX}\n")
        fh.write(f"source sketch={source}\n")
        fh.write(f"dialog after OK: {json.dumps(st.get('dialog'))}\n")
        fh.write(f"status after OK: {json.dumps(st.get('status'))}\n")
        fh.write(f"selection after OK: {json.dumps(sel)}\n")
        fh.write("sketch.inspect:\n")
        fh.write(json.dumps(insp.get("result"), indent=1))
        fh.write("\n")

    print("\nPNGs:")
    for name in (f"{PREFIX}-dialog-pick.png", f"{PREFIX}-after-ok.png"):
        p = os.path.join(OUTDIR, name)
        print(" ", p, os.path.getsize(p) if os.path.exists(p) else "NO EXISTE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
