#!/usr/bin/env python3
"""
workflow-validate.py - valida que el grafo declarado en workflow.yaml sea un grafo.

POR QUE EXISTE (2026-11-04): el workflow.yaml es la DECLARACION del proceso de un
issue (12 nodos, aristas, precondiciones, que hacer en cada fallo). Una declaracion
que no se valida es un documento: el dia que un nodo se renombre, la arista que lo
apunta queda rota en silencio y el runner propone un nodo que no existe.

QUE FALLA (rc=1):
  1. falta un nodo de los 12 obligatorios;
  2. una arista apunta a un nodo que no existe (de o a);
  3. un nodo (o una de sus acciones) declara un script que no esta en bin/;
  4. un nodo no tiene los campos obligatorios, o los tiene con un valor invalido
     (si_falla fuera del vocabulario, compilacion_pesada que no sea si/no, cron
     que no sea una expresion de 5 campos);
  5. una accion usa una senal que no esta declarada en `senales`;
  6. `flujo.orden` no cubre todos los nodos, o un id esta repetido.

COMO SE USA:
  python3 bin/workflow-validate.py                  # valida el workflow.yaml de al lado
  python3 bin/workflow-validate.py --json           # salida para maquinas
  python3 bin/workflow-validate.py --workflow RUTA  # valida otro archivo
  python3 bin/workflow-validate.py --root RUTA      # donde esta bin/ (por defecto, el
                                                    # directorio del workflow.yaml)

SALIDA: 0 = el grafo es valido; 1 = el grafo esta roto.
"""
import argparse
import json
import os
import re
import subprocess
import sys

# Los 12 nodos del proceso de un issue. No es una opinion: son los pasos que ya
# existen, cada uno con su script o con su agente.
NODOS_OBLIGATORIOS = [
    "buscar-issue",
    "claim-verify",
    "causa-raiz",
    "test-red",
    "fix",
    "draft-pr",
    "pipeline",
    "gate-queue",
    "gate",
    "gate-baseline",
    "verify-pr",
    "ci-upstream",
]

SI_FALLA_VALIDOS = {"reintentar", "descartar", "escalar", "esperar"}
COMPILACION_PESADA_VALIDOS = {"si", "no"}

CAMPOS_OBLIGATORIOS = [
    "id",
    "script",
    "lee",
    "escribe",
    "precondiciones",
    "si_falla",
    "cron",
    "compilacion_pesada",
]

# Una expresion de cron de 5 campos: "* * * * *" y cosas como "*/5 * * * *".
RE_CRON = re.compile(r"^(\S+\s+){4}\S+$")


class Resultado:
    def __init__(self):
        self.errores = []
        self.avisos = []

    def error(self, msg):
        self.errores.append(msg)

    def aviso(self, msg):
        self.avisos.append(msg)

    @property
    def ok(self):
        return not self.errores


def cargar_yaml(ruta, res):
    """Carga el YAML. Un YAML roto es un grafo roto: error, no excepcion."""
    try:
        import yaml
    except ImportError:
        res.error("falta el modulo PyYAML: no se puede leer el workflow")
        return None
    try:
        with open(ruta, encoding="utf-8") as fh:
            return yaml.safe_load(fh)
    except FileNotFoundError:
        res.error(f"no existe el archivo {ruta}")
    except Exception as e:                       # YAML invalido, permisos, etc.
        res.error(f"{ruta}: YAML invalido: {e}")
    return None


def chequear_script(res, etiqueta, script, root, interprete=None):
    """El script tiene que existir y estar en bin/.

    El bit de ejecucion solo se exige para lo que se corre con bash: un .py que se
    invoca como `python3 bin/pipeline.py` no lo necesita (y en esta caja pipeline.py
    no lo tiene, porque siempre se corrio con el interprete).
    """
    if script is None:
        return
    if not isinstance(script, str) or not script.strip():
        res.error(f"{etiqueta}: 'script' tiene que ser una ruta o null, no {script!r}")
        return
    if os.path.isabs(script):
        res.error(f"{etiqueta}: el script '{script}' es absoluto; tiene que ser relativo a bin/")
        return
    partes = script.split("/")
    if partes[0] != "bin":
        res.error(f"{etiqueta}: el script '{script}' no esta en bin/ (tiene que empezar por 'bin/')")
        return
    ruta = os.path.join(root, script)
    if not os.path.isfile(ruta):
        res.error(f"{etiqueta}: el script '{script}' no existe en {os.path.join(root, 'bin')}/")
        return
    if interprete == "bash" and not os.access(ruta, os.X_OK):
        res.error(f"{etiqueta}: el script '{script}' no es ejecutable (se corre con bash)")


def validar(grafo, root, res):
    if not isinstance(grafo, dict):
        res.error("el workflow tiene que ser un mapa con 'nodos' y 'flujo'")
        return

    nodos = grafo.get("nodos")
    if not isinstance(nodos, list) or not nodos:
        res.error("falta la lista 'nodos'")
        nodos = []

    senales = grafo.get("senales") or []
    if not isinstance(senales, list):
        res.error("'senales' tiene que ser una lista")
        senales = []
    senales_set = set(senales)

    # --- los nodos ---------------------------------------------------------
    vistos = {}
    for i, nodo in enumerate(nodos):
        if not isinstance(nodo, dict):
            res.error(f"nodos[{i}]: no es un mapa")
            continue
        nid = nodo.get("id")
        if not isinstance(nid, str) or not nid.strip():
            res.error(f"nodos[{i}]: falta el 'id'")
            continue
        if nid in vistos:
            res.error(f"nodo '{nid}': id repetido")
            continue
        vistos[nid] = nodo

        for campo in CAMPOS_OBLIGATORIOS:
            if campo not in nodo:
                res.error(f"nodo '{nid}': falta el campo '{campo}'")

        if nodo.get("si_falla") not in SI_FALLA_VALIDOS:
            res.error(
                f"nodo '{nid}': 'si_falla' invalido: {nodo.get('si_falla')!r} "
                f"(uno de: {', '.join(sorted(SI_FALLA_VALIDOS))})"
            )
        cp = nodo.get("compilacion_pesada")
        if cp not in COMPILACION_PESADA_VALIDOS:
            res.error(f"nodo '{nid}': 'compilacion_pesada' invalido: {cp!r} (si|no)")

        cron = nodo.get("cron")
        if cron is not None:
            if not isinstance(cron, str) or not RE_CRON.match(cron.strip()):
                res.error(f"nodo '{nid}': 'cron' invalido: {cron!r} (expresion de 5 campos o null)")

        for campo in ("lee", "escribe", "precondiciones"):
            if campo in nodo and not isinstance(nodo[campo], list):
                res.error(f"nodo '{nid}': '{campo}' tiene que ser una lista")

        chequear_script(res, f"nodo '{nid}'", nodo.get("script"), root, nodo.get("interprete"))

        # las acciones del nodo: cada una puede tener su propio script y sus senales
        acciones = nodo.get("acciones") or []
        if not isinstance(acciones, list):
            res.error(f"nodo '{nid}': 'acciones' tiene que ser una lista")
            acciones = []
        for j, acc in enumerate(acciones):
            etiqueta = f"nodo '{nid}' accion '{acc.get('id', j)}'"
            if not isinstance(acc, dict):
                res.error(f"{etiqueta}: no es un mapa")
                continue
            if not acc.get("id"):
                res.error(f"{etiqueta}: falta el 'id' de la accion")
            chequear_script(res, etiqueta, acc.get("script"), root, acc.get("interprete"))
            when = acc.get("cuando")
            if when is None:
                res.error(f"{etiqueta}: falta 'cuando' (la senal que la habilita)")
            elif not isinstance(when, list):
                res.error(f"{etiqueta}: 'cuando' tiene que ser una lista de senales")
            else:
                for s in when:
                    if s not in senales_set:
                        res.error(f"{etiqueta}: la senal '{s}' no esta declarada en 'senales'")
            if acc.get("compilacion_pesada") not in COMPILACION_PESADA_VALIDOS:
                res.error(f"{etiqueta}: 'compilacion_pesada' invalido: {acc.get('compilacion_pesada')!r} (si|no)")
            args = acc.get("args")
            if args is not None and not isinstance(args, list):
                res.error(f"{etiqueta}: 'args' tiene que ser una lista")

    # --- los 12 nodos que tienen que estar ---------------------------------
    for nid in NODOS_OBLIGATORIOS:
        if nid not in vistos:
            res.error(f"falta el nodo obligatorio '{nid}'")

    # --- el flujo ----------------------------------------------------------
    flujo = grafo.get("flujo")
    if not isinstance(flujo, dict):
        res.error("falta el bloque 'flujo' (con 'orden' y 'aristas')")
        return

    orden = flujo.get("orden") or []
    if not isinstance(orden, list):
        res.error("'flujo.orden' tiene que ser una lista")
        orden = []
    for nid in orden:
        if nid not in vistos:
            res.error(f"'flujo.orden' nombra el nodo '{nid}' que no existe")
    for nid in vistos:
        if nid not in orden:
            res.error(f"el nodo '{nid}' no esta en 'flujo.orden'")

    aristas = flujo.get("aristas") or []
    if not isinstance(aristas, list):
        res.error("'flujo.aristas' tiene que ser una lista")
        aristas = []
    for k, arista in enumerate(aristas):
        if not isinstance(arista, dict):
            res.error(f"aristas[{k}]: no es un mapa")
            continue
        for lado in ("de", "a"):
            destino = arista.get(lado)
            if destino is None:
                res.error(f"aristas[{k}]: falta '{lado}'")
            elif destino not in vistos:
                res.error(f"aristas[{k}]: '{lado}' apunta al nodo '{destino}' que no existe")
        if not arista.get("si"):
            res.error(f"aristas[{k}]: falta la condicion 'si'")
        if "si_no" not in arista:
            res.aviso(f"aristas[{k}] ({arista.get('de')} -> {arista.get('a')}): no dice que pasa si no se cumple")


def elegir_python():
    """Un python3 que tenga PyYAML.

    El PATH del que llama NO es el PATH del sistema: un cron, un supervisor y un
    harness de pruebas no comparten entorno, y el python3 del PATH puede no tener
    PyYAML (el de /usr/bin lo tiene). Se prueban en orden y se usa el primero que
    puede importar el modulo.
    """
    candidatos = []
    if os.environ.get("WORKFLOW_PYTHON"):
        candidatos.append(os.environ["WORKFLOW_PYTHON"])
    candidatos += ["python3", "/usr/bin/python3", "/usr/local/bin/python3"]
    vistos = set()
    for py in candidatos:
        if py in vistos:
            continue
        vistos.add(py)
        try:
            r = subprocess.run([py, "-c", "import yaml"], capture_output=True, timeout=30)
            if r.returncode == 0:
                return py
        except (OSError, subprocess.SubprocessError):
            continue
    return None


def reexec_con_yaml():
    """Si este python no tiene PyYAML, se relanza con uno que si lo tiene."""
    try:
        import yaml  # noqa: F401
        return
    except ImportError:
        pass
    py = elegir_python()
    if not py:
        return
    if os.path.realpath(py) == os.path.realpath(sys.executable):
        return
    os.execv(py, [py, os.path.abspath(__file__)] + sys.argv[1:])


def main():
    ap = argparse.ArgumentParser(description="Valida el grafo del workflow.yaml")
    ap.add_argument("--workflow", help="ruta del workflow.yaml (por defecto, el de al lado)")
    ap.add_argument("--root", help="raiz donde esta bin/ (por defecto, el dir del workflow.yaml)")
    ap.add_argument("--json", action="store_true", help="salida en JSON")
    ap.add_argument("--quiet", action="store_true", help="no imprime el detalle de los errores")
    args = ap.parse_args()

    aqui = os.path.dirname(os.path.abspath(__file__))
    workflow = args.workflow or os.environ.get("WORKFLOW") or os.path.join(os.path.dirname(aqui), "workflow.yaml")
    root = args.root or os.environ.get("ORCH_DIR") or os.path.dirname(os.path.abspath(workflow))

    res = Resultado()
    grafo = cargar_yaml(workflow, res)
    if grafo is not None:
        validar(grafo, root, res)

    nodos = grafo.get("nodos") if isinstance(grafo, dict) else None
    aristas = grafo.get("flujo", {}).get("aristas") if isinstance(grafo, dict) and isinstance(grafo.get("flujo"), dict) else None

    if args.json:
        print(json.dumps({
            "ok": res.ok,
            "workflow": os.path.abspath(workflow),
            "root": os.path.abspath(root),
            "nodos": len(nodos) if isinstance(nodos, list) else 0,
            "aristas": len(aristas) if isinstance(aristas, list) else 0,
            "errores": res.errores,
            "avisos": res.avisos,
        }, ensure_ascii=False, indent=1))
        return 0 if res.ok else 1

    if res.ok:
        n = len(nodos) if isinstance(nodos, list) else 0
        a = len(aristas) if isinstance(aristas, list) else 0
        print(f"workflow-validate: OK  {os.path.abspath(workflow)}  ({n} nodos, {a} aristas)")
        for av in res.avisos:
            print(f"  aviso: {av}")
        return 0

    print(f"workflow-validate: FALLA  {os.path.abspath(workflow)}  ({len(res.errores)} error(es))")
    if not args.quiet:
        for e in res.errores:
            print(f"  - {e}")
    return 1


if __name__ == "__main__":
    reexec_con_yaml()
    sys.exit(main())
