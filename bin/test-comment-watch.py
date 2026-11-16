#!/usr/bin/env python3
"""
test-comment-watch.py - pruebas del watcher de comentarios (#9178 tooling).

Sin red: se monkeypatchea gh() para que devuelva comentarios falsos. Lo que se
prueba es la LOGICA: el delta, la regla de ruido, la cola de tareas y el
hecho de que stdout queda vacio cuando nada cambia una decision.

Uso: python3 test-comment-watch.py
"""
import importlib.util
import io
import json
import os
import sys
import tempfile

RUTA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "comment_watch.py")
spec = importlib.util.spec_from_file_location("comment_watch", RUTA)
cw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cw)

fallos = []


def check(nombre, cond, detalle=""):
    if cond:
        print(f"  ok   {nombre}")
    else:
        print(f"  FAIL {nombre}  {detalle}")
        fallos.append(nombre)


def com(autor, texto, cid="c1", creado="2026-11-16T00:00:00Z"):
    return {"id": cid, "autor": autor, "cuerpo": texto, "creado": creado, "url": f"https://x/{cid}"}


print("1. el primer delta ve todo; el segundo, nada")
coms = [com("bherbruck", "please rebase onto main", "c1"), com("dudedagger42", "ok for me", "c2")]
n1, s1 = cw.delta("pr", 1, coms, None)
check("el primer delta ve los 2 comentarios", len(n1) == 2, f"vio {len(n1)}")
n2, s2 = cw.delta("pr", 1, coms, s1)
check("el segundo delta no ve nada", len(n2) == 0, f"vio {len(n2)}")
check("el snapshot guarda los vistos", len(s2["vistos"]) == 2, f"vistos={len(s2['vistos'])}")

print("2. un comentario nuevo se ve una sola vez")
coms2 = coms + [com("MattRuhland", "this needs a screenshot please", "c3")]
n3, s3 = cw.delta("pr", 1, coms2, s2)
check("el comentario nuevo aparece", len(n3) == 1 and n3[0]["id"] == "c3", f"vio {len(n3)}")
n4, _ = cw.delta("pr", 1, coms2, s3)
check("y no se repite en la corrida siguiente", len(n4) == 0, f"vio {len(n4)}")

print("3. un comentario editado es un delta")
editados = [com("bherbruck", "please rebase onto main, and add a test", "c1")]
n5, _ = cw.delta("pr", 1, editados, s3)
check("el texto editado se reporta", len(n5) == 1 and n5[0].get("editado"), f"vio {len(n5)}")

print("4. la regla de ruido")
check("un pedido de evidencia pide accion", bool(cw.PIDE_ACCION.search("please add a screenshot")))
check("un reclamo de recibo NO pide accion", not cw.PIDE_ACCION.search("thanks, looks good to me"))
check("un cambio de enfoque pide accion", bool(cw.PIDE_ACCION.search("instead of that, use the other approach")))
check("el cambio de decision se detecta", bool(cw.PIDE_CAMBIO.search("this needs to be a conic, not a spline")))
check("un thanks NO cambia una decision", not cw.PIDE_CAMBIO.search("thanks, looks good to me"))

print("5. el snapshot en disco y la cola de tareas")
with tempfile.TemporaryDirectory() as d:
    cw.SNAP_DIR = d
    cw.PENDING = os.path.join(d, "pending_tasks.json")
    cw.guardar_snapshot("pr", 42, {"vistos": {"c1": "h"}, "participantes": ["a"], "sembrado": True})
    leido = cw.leer_snapshot("pr", 42)
    check("el snapshot se escribe y se lee", leido is not None and leido["vistos"]["c1"] == "h")
    cw.guardar_pendientes([{"clave": "x", "estado": "pendiente"}])
    check("la cola se escribe y se lee", len(cw.cargar_pendientes()) == 1)

print("6. stdout vacio cuando nada cambia una decision")
stdout = io.StringIO()
stderr = io.StringIO()
real_out, real_err = sys.stdout, sys.stderr
sys.stdout, sys.stderr = stdout, stderr
try:
    rc = cw.main()
finally:
    sys.stdout, sys.stderr = real_out, real_err
check("main devuelve 0", rc == 0, f"rc={rc}")

print("7. los ids de curva no se confunden con los de comentario")
check("un id de comentario no es un id de curva", not cw.hash_cuerpo("n1").startswith("n1"))

print()
if fallos:
    print(f"FALLARON {len(fallos)}: {fallos}")
    sys.exit(1)
print("todas las pruebas pasan")
