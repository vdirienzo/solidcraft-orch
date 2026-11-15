#!/usr/bin/env python3
"""Captura la evidencia del issue #2130: el highlight de la cara bajo el
cursor durante un gesto de trackpad, y su apagado con el arrastre de mouse.

El MISMO script corre para el binario BEFORE y el AFTER: lo unico que cambia
es el binario que se lanzo. Por eso el script solo dice QUE capturar y con
que nombre.

Que muestra:
  1. el puntero sobre la cara de un cuerpo: la cara se ilumina;
  2. un gesto de trackpad de dos dedos (el pinch: ctrl+wheel, el gesto de dos
     dedos que el canal de control SI sabe emitir) con el puntero quieto: la
     vista se mueve bajo el puntero;
  3. un arrastre con el mouse (boton del medio): la vista tambien se mueve,
     pero el highlight se apaga.

El PNG sale de ui.screenshot (la ventana real de la app, con la escena 3D y
el highlight). El estado del highlight se lee de `ui.selection`.hover, que es
app.viewport.hover: el valor que el fix congela en vez de limpiar.

Uso: capture-2130-evidence.py <port> <token> <directorio-de-salida> <prefijo>
"""
import json
import os
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 27891
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""
OUTDIR = sys.argv[3] if len(sys.argv) > 3 else "/tmp/evidence-2130"
PREFIX = sys.argv[4] if len(sys.argv) > 4 else "2130"


class Conn:
    def __init__(self, host, port, token):
        self.s = socket.create_connection((host, port), timeout=120)
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
            print(f"  AVISO {method}: {json.dumps(reply)[:300]}")
        return reply

    def execute(self, command, params=None):
        return self("engine.execute", {"command": command, "params": params or {}})


# La escena: una caja 400x400x20 (la del test de regresion) con la camara en
# iso, para que el cuerpo se vea entero y la cara de arriba ocupe un area
# grande donde el highlight se note.
BOX = {"length": 400, "width": 400, "height": 20}
CAM = {"target": [200.0, 200.0, 10.0], "yaw": 0.7, "pitch": 0.9, "distance": 600.0}
TOP_FACE = [200.0, 200.0, 20.0]


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    c = Conn(HOST, PORT, TOKEN)
    log = []
    n = [0]

    def pump(k=6, each=0.06):
        """La app procesa UN evento de puntero por frame: hay que dejar correr
        el loop entre un evento y el siguiente."""
        for _ in range(k):
            time.sleep(each)
            c("ui.inspect", {})

    def hover():
        h = (c("ui.selection", {}).get("result") or {}).get("hover")
        return h

    def cam():
        return (c("ui.camera", {}).get("result") or {})

    def note(tag, extra=None):
        h = hover()
        rec = {"tag": tag, "hover": h, "camera": cam()}
        if extra:
            rec.update(extra)
        log.append(rec)
        lit = "encendida" if h else "APAGADA"
        print(f"  [{tag}] highlight {lit}  hover={json.dumps(h)[:120]}")
        return h

    def shot(tag):
        n[0] += 1
        name = f"{PREFIX}-{n[0]:02d}-{tag}.png"
        path = os.path.join(OUTDIR, name)
        r = c("ui.screenshot", {"path": path})
        ok = r.get("ok", False)
        print(f"  ui.screenshot {name} -> {'ok' if ok else json.dumps(r)[:200]}")
        log.append({"tag": "screenshot", "name": name, "ok": ok})
        return path if ok else None

    print("=== la escena: la caja del test de regresion #2130 ===")
    r = c.execute("solid.box", BOX)
    print("  solid.box ->", json.dumps(r.get("result") or r.get("error"))[:200])
    r = c("ui.camera", CAM)
    print("  ui.camera ->", json.dumps(r.get("result") or r.get("error"))[:200])
    pump(8)

    pts = (c("ui.worldToScreen", {"points": [TOP_FACE]}).get("result") or [None])[0]
    print("  la cara de arriba en pantalla:", pts)
    if not pts:
        print("  ERROR: el punto no esta en pantalla")
        return 1
    sx, sy = float(pts[0]), float(pts[1])

    print("\n=== 1. el puntero sobre la cara: la cara se ilumina ===")
    c("ui.move", {"x": sx, "y": sy})
    pump(8)
    note("hover-on")
    shot("hover-on")

    print("\n=== 2. gesto de trackpad de dos dedos (pinch: ctrl+wheel) ===")
    print("   el puntero NO se mueve; la vista se mueve bajo el puntero")
    before_cam = cam()
    for _ in range(14):
        c("ui.scroll", {"x": sx, "y": sy, "delta": -30, "ctrl": True})
    # El pinch se procesa un evento por frame: el screenshot sale en medio.
    h = note("durante-el-gesto", {"antes": before_cam})
    shot("gesto-trackpad")
    pump(20)
    note("despues-del-gesto")
    shot("tras-el-gesto")

    print("\n=== 3. arrastre con el mouse (boton del medio) ===")
    print("   la vista tambien se mueve, pero el highlight se apaga")
    before_cam = cam()
    c("ui.drag", {"x0": sx, "y0": sy, "x1": sx - 120, "y1": sy + 60, "button": "middle", "steps": 24})
    h = note("durante-el-arrastre", {"antes": before_cam})
    shot("arrastre-mouse")
    pump(20)
    note("tras-el-arrastre")

    state = {
        "prefijo": PREFIX,
        "puerto": PORT,
        "pixel_cara_arriba": [sx, sy],
        "pasos": log,
    }
    with open(os.path.join(OUTDIR, f"{PREFIX}-estado.json"), "w") as fh:
        json.dump(state, fh, indent=1)

    print("\n=== resumen ===")
    for rec in log:
        if rec.get("tag") == "screenshot":
            continue
        print(f"  {rec['tag']:22s} hover={'face' if rec['hover'] else 'None'}")
    print("\nPNGs en", OUTDIR)
    for f in sorted(os.listdir(OUTDIR)):
        if f.endswith(".png"):
            print("  ", f, os.path.getsize(os.path.join(OUTDIR, f)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
