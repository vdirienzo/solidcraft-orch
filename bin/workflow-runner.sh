#!/usr/bin/env bash
# ------------------------------------------------------------------
# workflow-runner.sh - el runner del grafo declarado en workflow.yaml.
#
# QUE HACE (2026-11-04): lee workflow.yaml, mira el estado REAL en disco y
# determina que nodos son ELEGIBLES ahora. Con --list los nombra; con
# --dry-run imprime el comando exacto sin hacerlo; sin nada ejecuta UN
# nodo elegible.
#
# LOS NODOS QUE COMPILEAN RUST NUNCA SE EJECUTAN AQUI: 'gate' y 'gate-queue'
# los lleva el cron que ya existe (solidcraft-gate-queue, */3). El runner es
# para lo que NO tiene cron.
#
# EL ESTADO (todo en disco, sin red):
#   $ORCH_DIR/state.json          los PRs (los que estan en draft, el issue, el head)
#   $ORCH_DIR/gates/queue.txt     la cola de gates pendiente
#   $LOOP_DIR/gates/<slot>/scope.verdict    el veredicto de cada slot (por SHA)
#
# USO:
#   bash bin/workflow-runner.sh --list        # que nodos son elegibles y por que
#   bash bin/workflow-runner.sh --dry-run     # el comando exacto, sin ejecutarlo
#   bash bin/workflow-runner.sh               # ejecuta UN nodo elegible
#   bash bin/workflow-runner.sh --json        # lo mismo, en JSON
#
# VARIABLES (para las pruebas y para no depender del HOME):
#   ORCH_DIR    raiz del orquestador (por defecto, el directorio del workflow.yaml)
#   LOOP_DIR    raiz del loop, donde estan los veredictos (por defecto, el estandar)
#   WORKFLOW    ruta del workflow.yaml (por defecto, $ORCH_DIR/workflow.yaml)
#   STATE_JSON  ruta del state.json (por defecto, $ORCH_DIR/state.json)
#
# Lo que ejecuta sale SIEMPRE del YAML: ningun comando se inventa aqui.
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$(dirname "$HERE")}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
WORKFLOW="${WORKFLOW:-$ORCH_DIR/workflow.yaml}"
STATE_JSON="${STATE_JSON:-$ORCH_DIR/state.json}"
LOG="$ORCH_DIR/logs/workflow-runner.log"

MODO="ejecutar"
FORMATO="texto"
case "${1:-}" in
  --list)    MODO="listar" ;;
  --dry-run) MODO="dry-run" ;;
  --json)    MODO="listar"; FORMATO="json" ;;
  --help|-h)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

[ -f "$WORKFLOW" ] || { echo "workflow-runner: no existe el workflow '$WORKFLOW'" >&2; exit 2; }

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

# El python que lee el YAML tiene que tener PyYAML. El PATH del que llama no es
# el PATH del sistema (un cron, un supervisor y un harness de pruebas no comparten
# entorno), asi que se busca uno que pueda importar el modulo.
PY=""
for cand in "${WORKFLOW_PYTHON:-}" python3 /usr/bin/python3 /usr/local/bin/python3; do
  [ -z "$cand" ] && continue
  if "$cand" -c "import yaml" >/dev/null 2>&1; then PY="$cand"; break; fi
done
if [ -z "$PY" ]; then
  echo "workflow-runner: ningun python3 con PyYAML (instala PyYAML o exporta WORKFLOW_PYTHON)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# El plan: python3 lee el YAML y el estado, y dice que nodos son elegibles.
# Cada linea del plan es:  nodo \t accion \t ejecutable \t razon \t comando
# ---------------------------------------------------------------------------
PLAN="$("$PY" - "$WORKFLOW" "$ORCH_DIR" "$LOOP_DIR" "$STATE_JSON" <<'PY'
import json, os, sys

try:
    import yaml
except ImportError:
    print("#ERROR:falta PyYAML", file=sys.stderr)
    sys.exit(2)

wf_path, orch, loop, state_path = sys.argv[1:5]

def cargar_yaml(p):
    with open(p, encoding="utf-8") as fh:
        return yaml.safe_load(fh)

try:
    grafo = cargar_yaml(wf_path)
except Exception as e:
    print("#ERROR:no se pudo leer el workflow: %s" % e, file=sys.stderr)
    sys.exit(2)
if not isinstance(grafo, dict):
    print("#ERROR:el workflow no es un mapa", file=sys.stderr)
    sys.exit(2)

# --- el estado ------------------------------------------------------------
try:
    with open(state_path, encoding="utf-8") as fh:
        estado = json.load(fh)
except Exception:
    estado = {}
if not isinstance(estado, dict):
    estado = {}

def texto_de(entry, claves):
    partes = []
    for k in claves:
        v = entry.get(k)
        if isinstance(v, str):
            partes.append(v)
    return " ".join(partes)

def prs_del_estado():
    """Los PRs que el orquestador tiene registrados, con su estado y su head.

    EL ESTADO SE RECONCILIA: `open_prs` es la lista canonica (el PR esta abierto y
    en que estado) y manda sobre las otras dos, que son notas. Sin esa regla el
    PR #10859 figuraba DRAFT en `prs_esperando_el_gate` y MERGED en `open_prs` al
    mismo tiempo, y el runner proponia un gate para un PR ya mergeado.
    """
    vistos = {}

    def agrega(entry, claves_estado, autoritativo=False):
        if not isinstance(entry, dict):
            return
        pr = entry.get("number") or entry.get("pr")
        if pr is None:
            return
        pr = str(pr).lstrip("#")
        est = texto_de(entry, claves_estado)
        sha = entry.get("head") or entry.get("sha") or entry.get("headRefOid")
        issue = entry.get("issue")
        if issue is not None:
            issue = str(issue).lstrip("#")
        rec = vistos.get(pr)
        nuevo = rec is None
        if nuevo:
            rec = {"pr": pr, "issue": issue, "sha": sha, "draft": False,
                   "ready": False, "merged": False, "fuente": ""}
            vistos[pr] = rec
        if sha and not rec["sha"]:
            rec["sha"] = sha
        if issue and not rec["issue"]:
            rec["issue"] = issue
        bajo = est.lower()
        # MERGED gana siempre: un PR mergeado no esta ni en draft ni listo.
        if "merged" in bajo or "mergeado" in bajo:
            rec["merged"] = True
            rec["draft"] = False
            rec["ready"] = False
        else:
            if "draft" in bajo:
                rec["draft"] = True
                rec["ready"] = False
            if "ready" in bajo and "not ready" not in bajo:
                rec["ready"] = True
                rec["draft"] = False
        if autoritativo:
            rec["fuente"] = "open_prs"

    for entry in (estado.get("open_prs") or []):
        agrega(entry, ("state", "estado", "status"), autoritativo=True)
    for entry in (estado.get("prs_esperando_el_gate") or []):
        agrega(entry, ("estado", "state", "status"))
    for pr, texto in (estado.get("prs_por_slot") or {}).items():
        if not isinstance(texto, str):
            continue
        agrega({"pr": pr, "state": texto}, ("state",))
    return vistos

def veredictos():
    """(sha -> (slot, veredicto, status)) y los slots sin veredicto efectivo."""
    base = os.path.join(loop, "gates")
    por_sha = []
    slots = []
    if os.path.isdir(base):
        for slot in sorted(os.listdir(base)):
            ruta = os.path.join(base, slot, "scope.verdict")
            if not os.path.isfile(ruta):
                continue
            kv = {}
            try:
                with open(ruta, encoding="utf-8", errors="replace") as fh:
                    for linea in fh:
                        if "=" in linea:
                            k, v = linea.strip().split("=", 1)
                            kv[k] = v
            except OSError:
                continue
            sha = (kv.get("SHA") or "").strip()
            veredicto = (kv.get("VERDICT") or "").strip()
            status = (kv.get("GATE_STATUS") or "").strip()
            nuevos = (kv.get("NEW_FAILURES") or "").strip()
            por_sha.append({"sha": sha, "slot": slot, "veredicto": veredicto,
                            "status": status, "nuevos": nuevos})
            efectivo = os.path.join(base, slot, "scope.effective.verdict")
            slots.append({"slot": slot, "sha": sha, "veredicto": veredicto,
                          "status": status, "nuevos": nuevos,
                          "tiene_efectivo": os.path.isfile(efectivo)})
    return por_sha, slots

def mismo_sha(a, b):
    if not a or not b:
        return False
    a = a.strip().lower()
    b = b.strip().lower()
    if len(a) < 7 or len(b) < 7:
        return False
    return a.startswith(b) or b.startswith(a)

def es_verde(v):
    if v["veredicto"].upper().startswith("VERDE"):
        return True
    return v["status"] == "finished" and v["nuevos"] in ("0", "")

prs = prs_del_estado()
vers, slots = veredictos()

def verdict_de(sha):
    for v in vers:
        if mismo_sha(v["sha"], sha):
            return v
    return None

drafts = [p for p in prs.values() if p["draft"]]
sin_veredicto = [p for p in drafts if p["sha"] and verdict_de(p["sha"]) is None]
con_verde = [p for p in drafts if p["sha"] and (lambda v: v and es_verde(v))(verdict_de(p["sha"]))]
listos = [p for p in prs.values() if not p["draft"] and p["sha"]
          and (lambda v: v and es_verde(v))(verdict_de(p["sha"]))]

# la cola de gates
cola = []
cola_ruta = os.path.join(orch, "gates", "queue.txt")
if os.path.isfile(cola_ruta):
    try:
        with open(cola_ruta, encoding="utf-8", errors="replace") as fh:
            for linea in fh:
                partes = linea.split()
                if partes:
                    cola.append({"issue": partes[0], "sha": partes[1] if len(partes) > 1 else ""})
    except OSError:
        cola = []

slots_sin_efectivo = [s for s in slots if not s["tiene_efectivo"]]

# --- las senales ----------------------------------------------------------
def objetivo_de(senal):
    """El sujeto de la senal: de donde salen {issue}, {pr}, {sha} y {slot}."""
    if senal == "pr_draft_sin_veredicto":
        if not sin_veredicto:
            return None
        p = sorted(sin_veredicto, key=lambda x: x["pr"])[0]
        return {"issue": p["issue"], "pr": p["pr"], "sha": p["sha"], "slot": ""}
    if senal == "pr_draft_con_veredicto_verde":
        if not con_verde:
            return None
        p = sorted(con_verde, key=lambda x: x["pr"])[0]
        return {"issue": p["issue"], "pr": p["pr"], "sha": p["sha"], "slot": ""}
    if senal == "pr_listo_para_verificar":
        if not listos:
            return None
        p = sorted(listos, key=lambda x: x["pr"])[0]
        return {"issue": p["issue"], "pr": p["pr"], "sha": p["sha"], "slot": ""}
    if senal == "cola_no_vacia":
        if not cola:
            return None
        return {"issue": cola[0]["issue"], "pr": "", "sha": cola[0]["sha"], "slot": ""}
    if senal == "slot_sin_veredicto_efectivo":
        if not slots_sin_efectivo:
            return None
        return {"issue": "", "pr": "", "sha": slots_sin_efectivo[0]["sha"],
                "slot": slots_sin_efectivo[0]["slot"]}
    if senal == "siempre":
        return {"issue": "", "pr": "", "sha": "", "slot": ""}
    return None

# --- los nodos ------------------------------------------------------------
nodos = grafo.get("nodos") or []
orden = ((grafo.get("flujo") or {}).get("orden")) or [n.get("id") for n in nodos]
pos = {nid: i for i, nid in enumerate(orden)}
nodos = sorted(nodos, key=lambda n: pos.get(n.get("id"), 10**6))

def render(args, obj):
    out = []
    for a in args or []:
        s = str(a)
        for k, v in (obj or {}).items():
            s = s.replace("{%s}" % k, str(v if v is not None else ""))
        if "{" in s and "}" in s:
            return None            # queda un marcador sin valor: no se puede correr
        out.append(s)
    return out

plan = []
for nodo in nodos:
    nid = nodo.get("id")
    if not nid:
        continue
    cron = nodo.get("cron")
    pesado = str(nodo.get("compilacion_pesada", "no")).lower() == "si"
    acciones = nodo.get("acciones") or []
    if not acciones:
        # Un nodo SIN acciones no es una propuesta: el runner solo propone lo que
        # puede ejecutar con datos del estado. Un nodo sin acciones y con cron
        # (pipeline) lo lleva su cron; uno sin cron y sin acciones (gate) lo lanza
        # otro nodo (el drain de la cola). Ninguno de los dos es del runner.
        continue
    for acc in acciones:
        cuando = acc.get("cuando") or []
        obj = None
        faltan = []
        for senal in cuando:
            o = objetivo_de(senal)
            if o is None:
                faltan.append(senal)
            elif obj is None:
                obj = o
        if faltan:
            continue                      # este nodo todavia no es elegible
        args = render(acc.get("args"), obj)
        if args is None:
            plan.append((nid, acc.get("id", ""), "no",
                         "faltan datos para completarlo", ""))
            continue
        script = acc.get("script")
        if not script:
            continue
        ruta = os.path.join(orch, script)
        if not os.path.isfile(ruta):
            plan.append((nid, acc.get("id", ""), "no",
                         "el script %s no esta en bin/" % script, ""))
            continue
        interp = acc.get("interprete") or ("python3" if script.endswith(".py") else "bash")
        comando = " ".join([interp, ruta] + args)
        if pesado:
            ejecutable, razon = "no", "compila Rust: lo lleva el cron (%s)" % (nodo.get("cron_job") or "solidcraft-gate-queue")
        elif cron:
            ejecutable, razon = "no", "ya tiene cron (%s): el runner no lo duplica" % nodo.get("cron_job")
        else:
            ejecutable, razon = "si", "elegible"
        plan.append((nid, acc.get("id", ""), ejecutable, razon, comando))

for fila in plan:
    print("\t".join(str(x) for x in fila))
PY
)"
rc_py=$?
if [ $rc_py -ne 0 ]; then
  echo "workflow-runner: no se pudo calcular el plan (rc=$rc_py)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Que se hace con el plan
# ---------------------------------------------------------------------------
[ -z "$PLAN" ] && PLAN=""

if [ "$FORMATO" = "json" ]; then
  "$PY" - "$PLAN" <<'PY'
import json, sys
salida = []
for linea in sys.argv[1].splitlines():
    if not linea.strip():
        continue
    nid, acc, ejec, razon, cmd = linea.split("\t")
    salida.append({"nodo": nid, "accion": acc, "ejecutable": ejec == "si",
                   "razon": razon, "comando": cmd})
print(json.dumps({"elegibles": salida}, ensure_ascii=False, indent=1))
PY
  exit 0
fi

if [ "$MODO" = "listar" ]; then
  if [ -z "$PLAN" ]; then
    echo "workflow-runner: ningun nodo es elegible ahora"
    exit 0
  fi
  echo "workflow-runner: nodos elegibles segun $WORKFLOW"
  printf '%-16s %-12s %-10s %s\n' "NODO" "ACCION" "LO EJECUTO" "POR QUE"
  while IFS=$'\t' read -r nid acc ejec razon cmd; do
    [ -z "${nid:-}" ] && continue
    printf '%-16s %-12s %-10s %s\n' "$nid" "$acc" "$ejec" "$razon"
  done <<< "$PLAN"
  exit 0
fi

# el primero que el runner puede ejecutar (orden del flujo)
ELEGIDO=""
while IFS=$'\t' read -r nid acc ejec razon cmd; do
  [ -z "${nid:-}" ] && continue
  if [ "$ejec" = "si" ]; then
    ELEGIDO="$nid	$acc	$razon	$cmd"
    break
  fi
done <<< "$PLAN"

if [ -z "$ELEGIDO" ]; then
  if [ -n "$PLAN" ]; then
    echo "workflow-runner: hay nodos elegibles pero ninguno lo ejecuta el runner:"
    while IFS=$'\t' read -r nid acc ejec razon cmd; do
      [ -z "${nid:-}" ] && continue
      echo "  - $nid/$acc: $razon"
    done <<< "$PLAN"
  else
    echo "workflow-runner: ningun nodo es elegible ahora"
  fi
  exit 0
fi

IFS=$'\t' read -r NODO ACCION RAZON CMD <<< "$ELEGIDO"

if [ "$MODO" = "dry-run" ]; then
  echo "workflow-runner: haria esto (nada se ejecuta en --dry-run)"
  echo "  nodo:    $NODO/$ACCION  ($RAZON)"
  echo "  comando: $CMD"
  exit 0
fi

echo "workflow-runner: ejecuto $NODO/$ACCION ($RAZON)"
echo "  $CMD"
# el comando sale del YAML: se corre con 'bash -c' para que los argumentos con
# espacios (un body, un path) lleguen enteros al script.
bash -c "$CMD"
RC=$?
printf '[%s] %s/%s rc=%s\n' "$(date +%H:%M:%S)" "$NODO" "$ACCION" "$RC" >> "$LOG" 2>/dev/null || true
if [ $RC -ne 0 ]; then
  echo "workflow-runner: $NODO/$ACCION fallo (rc=$RC)" >&2
  echo "  el nodo declara si_falla en el YAML: mira ahi que hacer con este rc" >&2
fi
exit $RC
