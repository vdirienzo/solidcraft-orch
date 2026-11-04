#!/usr/bin/env python3
"""Captura la evidencia visual del issue #7114: donde cae un punto del sketch.

Habla con el control channel de la app (TCP, JSON por linea; la PRIMERA linea
lleva el token) y produce dos PNG de 1280x800 con la grilla dibujada a la vista:

  - CASO A: el puntero a un 1/16 de celda de un cruce de la grilla dibujada:
    el punto debe caer EN el cruce (el fix);
  - CASO B: el puntero en un valor EXACTO del lattice fino, que no esta sobre
    ninguna linea dibujada: el punto debe quedarse en ese valor exacto.

Que la app procese los eventos de puntero es lo unico que hace falta: procesa UN
evento de puntero POR FRAME (synthetic_input), asi que entre el move y el click
hay que dejar que corra el loop. Por eso el "pump": varias llamadas a ui.inspect
con una pausa entre cada una.

El PNG sale de ui.screenshot (la ventana con el overlay de egui, donde se dibujan
los marcadores del punto del sketch); ui.render solo dibuja la escena 3D y no
incluye los marcadores.

Uso: capture-7114-evidence.py [port] [token] [directorio-de-salida]
"""
import json
import os
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7717
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""
# The path comes from the environment, with the default of THIS machine: the
# other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR = os.environ.get("ORCH_DIR", os.path.expanduser("~/.local/share/solidcraft-orch"))
OUTDIR = sys.argv[3] if len(sys.argv) > 3 else f"{ORCH_DIR}/logs/evidence-7114"

WIDTH, HEIGHT = 1280, 800

# La camara: el paso de la grilla dibujada sale del alto de la vista
# (grid_step, crates/engine/src/view.rs). Con distance 60 el alto es 24 y el
# paso dibujado es 2 (el fino, 0.2): el cruce 20 es una linea dibujada y el
# valor 15 esta en el lattice fino, a mitad de celda, SIN linea dibujada.
DISTANCE = 60.0


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
            print(f"  AVISO: {method} -> {json.dumps(reply)[:300]}")
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

    def sketch_to_screen(local):
        r = c("ui.sketchToScreen", {"points": [local]})
        pts = r.get("result")
        if not isinstance(pts, list) or not pts or not isinstance(pts[0], list):
            raise RuntimeError(f"ui.sketchToScreen no devolvio un punto de pantalla: {json.dumps(r)[:300]}")
        return float(pts[0][0]), float(pts[0][1])

    def shoot(tag, local, cam_target, png_name, note):
        print(f"\n=== {tag}: {note}")
        print("  diseno ->", json.dumps(fresh_doc())[:200])

        # La camara primero: el paso de la grilla dibujada depende de su alto.
        c("ui.camera", {"distance": DISTANCE, "target": cam_target})
        pump(4)

        made = c.execute("sketch.create", {"plane": "XY"})
        print("  sketch.create ->", json.dumps(made.get("result"))[:200])
        c("ui.start", {"command": "sketch.point"})
        pump(3)

        sx, sy = sketch_to_screen(local)
        print(f"  puntero: local {local} -> pantalla ({sx:.2f}, {sy:.2f})")

        print("  ui.move ->", json.dumps(c("ui.move", {"x": sx, "y": sy}).get("result"))[:120])
        pump(8)

        print("  ui.click ->", json.dumps(c("ui.click", {"x": sx, "y": sy}).get("result"))[:120])
        pump(10)

        # El puntero se queda ahi: el preview de la herramienta dibuja el valor
        # ya snapeado al lado del punto ("15.00 mm, 15.00 mm").
        c("ui.move", {"x": sx, "y": sy})
        pump(6)

        png = os.path.join(OUTDIR, png_name)
        r = c("ui.screenshot", {"path": png})
        print("  ui.screenshot ->", json.dumps(r.get("result"))[:200])

        ins = c.execute("sketch.inspect")
        print("  sketch.inspect ->", json.dumps(ins.get("result"), indent=1)[:2500])
        return {"tag": tag, "png": png, "screenshot": r.get("result"), "inspect": ins.get("result"),
                "pointer_local": local, "camera_target": cam_target, "distance": DISTANCE}

    out = []
    # CASO A: el cruce visible. El puntero va a 20.3125: 0.3125 del cruce 20.0
    # y 0.0875 del punto del lattice 20.4 (no esta en el lattice), asi que la
    # regla 2 lo lleva al cruce y el punto cae en 20.0, sobre la linea dibujada.
    out.append(shoot(
        "CASO A", [20.3125, 20.0], [20.0, 20.0, 0.0], "7114-grid-crossing.png",
        "el punto debe caer EN el cruce dibujado (20.0, 20.0)"))

    # CASO B: un valor EXACTO del lattice fino. 15 no esta en ninguna linea
    # dibujada (las lines van de 2 en 2) y esta en el lattice fino (paso 0.2):
    # la regla 1 lo deja donde esta y el punto no se mueve.
    out.append(shoot(
        "CASO B", [15.0, 15.0], [15.0, 15.0, 0.0], "7114-fine-lattice.png",
        "el punto debe quedarse en el valor exacto del lattice (15.0, 15.0)"))

    with open(os.path.join(OUTDIR, "7114-sketch-inspect.txt"), "w") as fh:
        for r in out:
            fh.write(f"===== {r['tag']} =====\n")
            fh.write(f"pointer (sketch local): {r['pointer_local']}\n")
            fh.write(f"camera: distance {r['distance']} target {r['camera_target']}\n")
            fh.write(f"screenshot: {json.dumps(r['screenshot'])}\n")
            fh.write("sketch.inspect:\n")
            fh.write(json.dumps(r["inspect"], indent=1))
            fh.write("\n\n")
    print("\nPNGs:")
    for r in out:
        p = r["png"]
        print(" ", p, os.path.getsize(p) if os.path.exists(p) else "NO EXISTE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
