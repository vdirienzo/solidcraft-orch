#!/usr/bin/env python3
"""Captura la evidencia visual del issue #10159: el mensaje del session log.

Habla con el control channel de la app (TCP, JSON por linea; la PRIMERA linea
lleva el token) y produce dos PNG de la ventana con el overlay de egui:

  - ANTES: el registro de la sesion (Help > Messages) abierto, SIN el mensaje
    del file chooser;
  - DESPUES: el mismo registro, con el mensaje que dice que el chooser que se
    abrio no es el del escritorio propio.

Que el mensaje aparezca depende de la app, no del script: el script solo
dispara la accion que abre un selector de archivos (File > Open) y espera a
que la app lo anote en el registro.

Que la app procese los eventos de puntero es lo unico que hace falta: procesa
UN evento de puntero POR FRAME (synthetic_input), asi que entre el movimiento
y el click hay que dejar que corra el loop. Por eso el "pump": varias llamadas
a ui.inspect con una pausa entre cada una.

El PNG sale de ui.screenshot (la ventana con el overlay de egui, donde se ve el
registro de la sesion); ui.render solo dibuja la escena 3D y no incluye los
textos de la UI.

Uso: capture-10159-evidence.py [port] [token] [directorio-de-salida]
"""
import json
import os
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7717
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""
OUTDIR = sys.argv[3] if len(sys.argv) > 3 else "/home/user/.local/share/solidcraft-orch/logs/evidence-10159"


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

    def pump(n=8, each=0.08):
        """La app procesa UN evento de puntero por frame: hay que dejar correr
        el loop entre el move y el click, o el click llega sin puntero."""
        for _ in range(n):
            time.sleep(each)
            c("ui.inspect", {})

    def messages():
        r = c("ui.messages", {})
        return (r.get("result") or {}).get("messages", [])

    def open_messages_window():
        """Help > Messages: el registro de la sesion."""
        r = c("ui.messages", {"open": True})
        print("  ui.messages open ->", json.dumps(r.get("result") or r.get("error"))[:200])
        pump(4)

    def screenshot(name):
        png = os.path.join(OUTDIR, name)
        r = c("ui.screenshot", {"path": png})
        print(f"  ui.screenshot -> {json.dumps(r.get('result') or r.get('error'))[:200]}")
        return png

    out = {}

    # --- ANTES: el registro de la sesion, todavia sin el mensaje -------------
    print("\n=== ANTES: el registro de la sesion sin el mensaje")
    before = messages()
    print(f"  mensajes al empezar: {len(before)}")
    open_messages_window()
    out["before_png"] = screenshot("10159-before-session-log.png")
    out["before_messages"] = before

    # --- la accion que abre un selector de archivos -------------------------
    # File > Open: el atajo es Ctrl+O. Se manda por el canal de control con
    # la misma entrada que el atajo (mods.command + Key::O).
    print("\n=== la accion: File > Open (Ctrl+O)")
    c("ui.key", {"key": "O", "cmd": True})
    pump(12, 0.12)

    state = c("ui.inspect", {}).get("result") or {}
    print("  file_picker_busy:", state.get("file_picker_busy"), "file_dialog_open:", state.get("file_dialog_open"))

    # La app anota el motivo en el registro (Help > Messages).
    after = messages()
    print(f"  mensajes despues: {len(after)}")
    for m in after[:5]:
        print("   -", json.dumps(m, ensure_ascii=False)[:240])

    # --- DESPUES: el registro de la sesion con el mensaje -------------------
    print("\n=== DESPUES: el registro de la sesion con el mensaje")
    open_messages_window()
    out["after_png"] = screenshot("10159-after-session-log.png")
    out["after_messages"] = after

    with open(os.path.join(OUTDIR, "10159-session-log.json"), "w") as fh:
        json.dump(out, fh, indent=1, ensure_ascii=False)

    print("\nPNGs:")
    for k in ("before_png", "after_png"):
        p = out.get(k)
        if p:
            print(" ", p, os.path.getsize(p) if os.path.exists(p) else "NO EXISTE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
