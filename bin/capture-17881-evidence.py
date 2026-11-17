#!/usr/bin/env python3
"""Captura la evidencia del issue #17881: Home encuadra la pieza en el area
que los paneles dejan libre (y no en el centro de toda la ventana).

El script maneja la VENTANA REAL de la app (ui.screenshot) por el canal de
control: cierra la pagina de inicio, crea la pieza del issue (un cuerpo
centrado en el eje Z), abre el navegador dockeado a la izquierda, ejecuta el
comando Home y mide, por el mismo canal:

  * el rectangulo del viewport (ui.inspect -> viewport),
  * donde queda en pantalla el centro de la pieza (ui.worldToScreen),
  * el estado de la interfaz (ui.inspect -> ui, status), que dice si el app
    usa el host de paneles compartido o su propio layout.

Uso: capture-17881-evidence.py <port> <token> <directorio-de-salida> [prefijo]
"""
import json
ORCH_DIR = os.environ.get("ORCH_DIR", "/home/user/.local/share/solidcraft-orch")
import os
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 27981
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""
OUTDIR = sys.argv[3] if len(sys.argv) > 3 else os.path.join(ORCH_DIR, "evidence", "17881-home-framing")
PREFIX = sys.argv[4] if len(sys.argv) > 4 else "17881"

# La pieza del issue #17881: un cuerpo centrado en el eje Z, de 17x17x40.
BOX = {"length": 17, "width": 17, "height": 40, "body_name": "Part"}
MOVE = {"bodies": ["Part"], "translate": [-8.5, -8.5, 0]}
# El centro de la pieza: (0, 0, 20).
CENTRE = [0.0, 0.0, 20.0]
CORNERS = [
    [-8.5, -8.5, 0.0], [8.5, -8.5, 0.0], [-8.5, 8.5, 0.0], [8.5, 8.5, 0.0],
    [-8.5, -8.5, 40.0], [8.5, -8.5, 40.0], [-8.5, 8.5, 40.0], [8.5, 8.5, 40.0],
]


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


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    c = Conn(HOST, PORT, TOKEN)
    log = []

    def pump(k=8, each=0.06):
        """La app procesa un evento por frame: hay que dejar correr el loop."""
        for _ in range(k):
            time.sleep(each)
            c("ui.inspect", {})

    def state():
        return c("ui.inspect", {}).get("result") or {}

    def camera():
        return c("ui.camera", {}).get("result") or {}

    def screen_of(points):
        return c("ui.worldToScreen", {"points": points}).get("result") or []

    def shot(tag):
        name = f"{PREFIX}-{tag}.png"
        path = os.path.join(OUTDIR, name)
        r = c("ui.screenshot", {"path": path})
        ok = r.get("ok", False)
        print(f"  ui.screenshot {name} -> {'ok' if ok else json.dumps(r)[:200]}")
        log.append({"tag": "screenshot", "name": name, "ok": ok})
        return path if ok else None

    def settle_camera(rounds=40, each=0.08):
        """Espera a que la animacion de la vista se detenga."""
        last = None
        for _ in range(rounds):
            time.sleep(each)
            cam = camera()
            key = json.dumps(cam, sort_keys=True)
            c("ui.inspect", {})
            if key == last:
                return cam
            last = key
        return last

    def measure(tag):
        st = state()
        vp = st.get("viewport") or [0, 0, 0, 0]
        at = screen_of([CENTRE])
        corners = screen_of(CORNERS)
        rec = {
            "tag": tag,
            "viewport": vp,
            "centro_pieza": at,
            "esquinas": corners,
            "status": st.get("status"),
            "ui": st.get("ui"),
        }
        log.append(rec)
        print(f"  [{tag}] viewport={json.dumps(vp)}  centro_pieza={json.dumps(at)}")
        print(f"  [{tag}] status={json.dumps(st.get('status'))[:200]}")
        return rec

    print("=== la pagina de inicio se cierra: el app muestra el diseno ===")
    c("ui.home", {"open": False})
    pump(12)
    st = state()
    print("  home abierta:", st.get("home"), " viewport:", json.dumps(st.get("viewport")))
    print("  status:", json.dumps(st.get("status"))[:200])

    print("\n=== la pieza del issue: un cuerpo centrado en el eje Z ===")
    r = c.execute("solid.box", BOX)
    print("  solid.box ->", json.dumps(r.get("result") or r.get("error"))[:200])
    r = c.execute("solid.move", MOVE)
    print("  solid.move ->", json.dumps(r.get("result") or r.get("error"))[:200])
    pump(10)

    print("\n=== el navegador, dockeado a la izquierda ===")
    c("ui.set", {"layout": "docked"})
    c("ui.set", {"showBrowser": True})
    pump(16)
    before = measure("navegador-abierto-antes-de-home")
    shot("01-navegador-abierto-antes-de-home")

    print("\n=== Home ===")
    r = c.execute("view.home", {})
    print("  view.home ->", json.dumps(r.get("result") or r.get("error"))[:200])
    cam = settle_camera()
    print("  camara:", json.dumps(cam)[:300])
    after = measure("navegador-abierto-despues-de-home")
    shot("02-navegador-abierto-despues-de-home")

    print("\n=== la misma pieza sin el navegador (comparacion) ===")
    c("ui.set", {"showBrowser": False})
    pump(16)
    c.execute("view.home", {})
    cam = settle_camera()
    without = measure("sin-navegador-despues-de-home")
    shot("03-sin-navegador-despues-de-home")

    summary = {
        "puerto": PORT,
        "pasos": log,
    }
    with open(os.path.join(OUTDIR, f"{PREFIX}-estado.json"), "w") as fh:
        json.dump(summary, fh, indent=1)
    print("\nPNGs en", OUTDIR)
    for f in sorted(os.listdir(OUTDIR)):
        if f.endswith(".png"):
            print("  ", f, os.path.getsize(os.path.join(OUTDIR, f)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
