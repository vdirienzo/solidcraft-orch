#!/usr/bin/env python3
"""sc_control.py - the client of the control channel of the SolidCraft app.

WHY THIS FILE EXISTS: six capture scripts (capture-7114, capture-10159,
capture-10181 x3, capture-10291) each re-implemented the same client, the same
"pump" and the same "fresh document" helper, with small variations. The next
feature that needs visual evidence would have written the seventh.

WHAT IT DOES: the app exposes a control channel (TCP, JSON per line, the FIRST
line carries the token). With it one can run commands, inspect the state and
take a screenshot of the window WITH the egui overlay (which is where the
dialogs and their messages are drawn; `ui.render` only draws the 3D scene).

HOW TO LAUNCH THE APP: `solidcraft --control <port>` with SOLIDCRAFT_CONTROL_TOKEN
set (a hex token), on a display with an X server (Xvfb runs on :97, :98 and
:99 here, all 1600x1000). There is no GPU: the adapter is Vulkan/llvmpipe
(lavapipe), and the app opens a real window with it.

USE A DISPLAY OF YOUR OWN. This is the gotcha that costs the most time: on a
display where other apps are running and there is NO window manager, X reports
the window as fully covered, so egui SKIPS the UI pass: `ui.screenshot` answers
"no frame was presented (window hidden?)" and a click never reaches the
button. Nothing in the app is broken and nothing in the script is wrong: the
window is simply never shown. Start your own Xvfb on a free display and use
that one.

REBUILDING WITHOUT A SECOND BUILD: to capture the BEFORE state of a fix, revert
ONLY the hunk of the fix in the worktree and rebuild INCREMENTALLY in the same
CARGO_TARGET_DIR (minutes, no extra gigabytes); the rebuild after re-applying
the fix produces a byte-identical binary. A second full build of the app is
28 GB.

PUMPING: the app processes ONE pointer event PER FRAME, so between a move and
a click the loop has to run. `pump()` is that: several `ui.inspect` calls with
a pause between each one.
"""
import json
import os
import socket
import time

HOST = "127.0.0.1"
DEFAULT_PORT = 27878


class Conn:
    """The connection to the control channel of a running app."""

    def __init__(self, host=HOST, port=DEFAULT_PORT, token=""):
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
        """Runs an engine command (solid.box, sketch.project, ...)."""
        return self("engine.execute", {"command": command, "params": params or {}})

    def inspect(self):
        return self("ui.inspect", {})

    def handles(self):
        return self("ui.handles", {})

    def screenshot(self, path):
        """Saves the window (with the egui overlay) as a PNG."""
        os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
        return self("ui.screenshot", {"path": path})

    def pump(self, n=8, each=0.06):
        """Lets the app's loop run: it processes ONE pointer event PER FRAME."""
        for _ in range(n):
            time.sleep(each)
            self("ui.inspect", {})

    def fresh_doc(self):
        """A single empty design: the evidence comes from a clean state."""
        self("ui.documents", {"action": "new"})
        self.pump(4)
        docs = (self("ui.documents", {}).get("result") or {})
        active = docs.get("active", 0)
        for i in range(len(docs.get("documents", [])) - 1, -1, -1):
            if i != active:
                self("ui.documents", {"action": "close", "index": i, "force": True,
                                      "answer": "dont_save"})
        self.pump(3)
        return docs


def connect(port=DEFAULT_PORT, token="", host=HOST):
    """Connects to a running app and says whether the channel answered."""
    c = Conn(host, port, token)
    reply = c("ui.inspect", {})
    if not reply.get("ok", False):
        raise RuntimeError(f"el canal de control no respondio: {json.dumps(reply)[:300]}")
    return c


def screenshot(c, path):
    """Takes a screenshot and explains the failure that is NOT the code's fault.

    "no frame was presented (window hidden?)" means the window was never shown:
    the display had other apps on it and no window manager, so X reported it as
    covered and egui skipped the UI pass. Use a display of your own.
    """
    reply = c.screenshot(path)
    text = json.dumps(reply)
    if not reply.get("ok", False) and "frame was presented" in text:
        raise RuntimeError(
            "la app no presento ningun frame: la ventana esta tapada. "
            "Levanta un Xvfb PROPIO en un display libre y usa ese: sin window "
            "manager, X reporta la ventana como cubierta y egui saltea el pase "
            "de UI. Detalle: " + text[:300])
    return reply
