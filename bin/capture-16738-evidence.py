#!/usr/bin/env python3
"""Visual evidence for #16738 (PR 17268): a sketch text is one unit when it is picked.

Drives the real SolidCraft app over its control channel and takes pictures of the
viewport showing:

  (a) a click on ONE letter's outline selects the WHOLE text (every outline of it
      is lit), which is what the change does;
  (b) the same view with Shift held: the single outline under the cursor comes back
      out of the selection, so one silhouette is left out.

Usage:
  capture-16738-evidence.py <port> <token> <outdir> <prefix>

The script prints what it did and what it read back (the selection, the hover, the
ids of the outlines of the text). It never fabricates a picture: if the app cannot
be driven to the state, it exits non-zero and says why.
"""
import json
import os
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 27901
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""
OUTDIR = sys.argv[3] if len(sys.argv) > 3 else "/tmp/evidence-16738"
PREFIX = sys.argv[4] if len(sys.argv) > 4 else "16738"

# The text we draw: two letters, so "the whole text" and "one outline out" are both
# visible in one picture (the 'O' has two outlines, the 'I' one).
TEXT = "IO"
TEXT_AT = [-20.0, 0.0]
TEXT_HEIGHT = 24.0


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

    def execute(self, command, params=None):
        return self("engine.execute", {"command": command, "params": params or {}})


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    c = Conn(HOST, PORT, TOKEN)
    log = []
    shots = []

    def pump(k=8, each=0.07):
        """The app processes ONE pointer event per frame: let the loop run between
        events, or the click arrives without a pointer."""
        for _ in range(k):
            time.sleep(each)
            c("ui.inspect", {})

    def note(tag, extra=None):
        rec = {"tag": tag}
        if extra:
            rec.update(extra)
        log.append(rec)
        print(f"  [{tag}] {json.dumps(extra)[:400] if extra else ''}")
        return rec

    def shot(tag):
        name = f"{PREFIX}-{tag}.png"
        path = os.path.join(OUTDIR, name)
        r = c("ui.screenshot", {"path": path})
        ok = bool(r.get("ok", False))
        size = os.path.getsize(path) if os.path.exists(path) else 0
        print(f"  ui.screenshot {name} -> {'ok' if ok else json.dumps(r)[:200]} ({size} bytes)")
        shots.append({"name": name, "path": path, "ok": ok, "bytes": size})
        return path if ok and size > 0 else None

    def selection():
        r = c("ui.selection", {})
        return (r.get("result") or {}).get("selection") or []

    # ---------------------------------------------------------------- the design
    print("=== a clean design")
    c("ui.documents", {"action": "new"})
    pump(4)
    docs = (c("ui.documents", {}).get("result") or {})
    active = docs.get("active", 0)
    for i in range(len(docs.get("documents", [])) - 1, -1, -1):
        if i != active:
            c("ui.documents", {"action": "close", "index": i, "force": True, "answer": "dont_save"})
    pump(3)

    print("=== the body")
    r = c.execute("solid.box", {"length": 120, "width": 90, "height": 20, "body_name": "Body1"})
    print("  solid.box ->", json.dumps(r.get("result") or r.get("error"))[:300])
    pump(4)

    print("=== the sketch (on the top face of the body)")
    # The sketch is made on the face the body sits on, so the viewport shows it.
    r = c.execute("sketch.create", {"plane": {"face": [60, 45, 20]}})
    print("  sketch.create ->", json.dumps(r.get("result") or r.get("error"))[:300])
    pump(6)

    print("=== the text in the sketch")
    r = c.execute("sketch.text", {"text": TEXT, "at": TEXT_AT, "height": TEXT_HEIGHT})
    res = r.get("result") or {}
    print("  sketch.text ->", json.dumps(res)[:400])
    err = r.get("error")
    if err:
        print(f"  ERROR: the text could not be created: {json.dumps(err)[:400]}")
        return 1
    link = res.get("link")
    curve_ids = res.get("curves") or []
    note("text-created", {"link": link, "curves": curve_ids})
    if not link or not curve_ids:
        print("  ERROR: the text came back without its link or its outlines")
        return 1
    pump(6)

    # ---------------------------------------------------------- where the text is
    print("=== the outlines of the text, in screen points")
    # The outlines are the text's own curves; the world position of each is what
    # the viewport draws. We ask the app where they land on screen.
    insp = c("ui.inspect", {}).get("result") or {}
    note("inspect", {"viewport": insp.get("viewport"), "camera": insp.get("camera")})

    # The outlines of a text are the curves the text owns. Their points come from
    # the engine, through the same command the browser uses.
    r = c.execute("sketch.inspect", {})
    sk = r.get("result") or {}
    curves = sk.get("curves") or []
    mine = [cu for cu in curves if cu.get("link") == link]
    note("text-outlines", {"count": len(mine), "ids": [cu.get("id") for cu in mine]})
    if not mine:
        print("  ERROR: the sketch does not report the text's outlines")
        return 1

    # A point of one outline, in the sketch's plane, to aim the pointer at.
    def outline_point(cu):
        kind = cu.get("type")
        if kind == "line":
            a = cu.get("start_at")
            b = cu.get("end_at")
            if a and b:
                return [(a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0]
        if kind in ("arc", "circle"):
            ctr = cu.get("center_at")
            if ctr:
                return [ctr[0], ctr[1]]
        if kind == "spline":
            pts = [p for p in (cu.get("points_at") or []) if p]
            if pts:
                p = pts[len(pts) // 2]
                return [p[0], p[1]]
        if kind == "conic":
            a = cu.get("start_at")
            b = cu.get("end_at")
            if a and b:
                return [(a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0]
        return None

    target = None
    for cu in mine:
        p = outline_point(cu)
        if p:
            target = (cu.get("id"), p)
            break
    if target is None:
        print("  ERROR: no outline of the text has a place to aim at")
        return 1
    note("target", {"curve": target[0], "point": target[1]})

    # Where that point lands on screen (sketch plane -> screen).
    scr = c("ui.sketchToScreen", {"points": [target[1]]}).get("result") or []
    print("  sketchToScreen ->", json.dumps(scr)[:200])
    if not scr or not scr[0]:
        print("  ERROR: the outline is not on screen")
        return 1
    x, y = float(scr[0][0]), float(scr[0][1])
    note("screen-point", {"x": x, "y": y})

    # --------------------------------------------------------------- the picture
    print("=== the pointer over one letter's outline")
    c("ui.move", {"x": x, "y": y})
    pump(10)
    hover = (c("ui.selection", {}).get("result") or {}).get("hover")
    note("hover-on-outline", {"hover": hover})
    shot("01-hover-outline")

    print("=== the click: the whole text must come with it")
    c("ui.click", {"x": x, "y": y})
    pump(12)
    sel = selection()
    ids = [s.get("id") for s in sel if isinstance(s, dict) and s.get("type") == "sketch_curve"]
    note("selection-after-click", {"count": len(sel), "curve_ids": ids})
    shot("02-text-picked-whole")

    picked_whole = len(ids) >= 2
    if not picked_whole:
        print(f"  AVISO: the click picked {len(ids)} outline(s), not the whole text")

    print("=== Shift+click: one outline comes back out")
    # Shift is held for the click itself (the app reads the modifier of the press).
    c("ui.move", {"x": x, "y": y, "shift": True})
    pump(10)
    c("ui.click", {"x": x, "y": y, "shift": True})
    pump(12)
    sel2 = selection()
    ids2 = [s.get("id") for s in sel2 if isinstance(s, dict) and s.get("type") == "sketch_curve"]
    note("selection-after-shift", {"count": len(sel2), "curve_ids": ids2})
    shot("03-shift-one-outline-out")

    one_out = len(ids2) == len(ids) - 1 and len(ids2) >= 1
    if not one_out:
        print(f"  AVISO: after Shift the selection holds {len(ids2)} outline(s) (it held {len(ids)})")

    with open(os.path.join(OUTDIR, f"{PREFIX}-estado.json"), "w") as fh:
        json.dump(
            {
                "prefijo": PREFIX,
                "puerto": PORT,
                "text": TEXT,
                "link": link,
                "outlines": [cu.get("id") for cu in mine],
                "pantalla": [x, y],
                "seleccion_tras_el_click": ids,
                "seleccion_tras_shift": ids2,
                "texto_entero_elegido": picked_whole,
                "una_silueta_fuera": one_out,
                "pasos": log,
                "capturas": shots,
            },
            fh,
            indent=1,
        )

    print("\n=== resumen")
    print(f"  el texto entero se elige con un click: {'SI' if picked_whole else 'NO'} ({len(ids)} contornos)")
    print(f"  Shift deja un contorno fuera:          {'SI' if one_out else 'NO'} ({len(ids2)} contornos)")
    print("\nPNGs en", OUTDIR)
    for s in shots:
        print("  ", s["name"], s["bytes"], "bytes", "ok" if s["ok"] else "FALLO")
    return 0 if (picked_whole and one_out and all(s["ok"] for s in shots)) else 2


if __name__ == "__main__":
    sys.exit(main())
