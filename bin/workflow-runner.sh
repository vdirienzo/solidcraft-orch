#!/usr/bin/env bash
# ------------------------------------------------------------------
# workflow-runner.sh - el runner del grafo declarado en workflow.yaml.
#
# QUE HACE (2026-11-04): lee workflow.yaml, mira el estado REAL en disco y
# determina que nodos son ELEGIBLES ahora. Con --list los nombra (y dice quien
# los ejecuta); con --dry-run imprime el comando exacto sin hacerlo; sin nada
# ejecuta UN nodo elegible.
#
# LOS NODOS QUE COMPILAN RUST NUNCA SE EJECUTAN AQUI: 'gate' y 'gate-queue' los
# lleva el cron que ya existe (solidcraft-gate-queue, */3). El runner es para lo
# que NO tiene cron. Los nodos con cron tambien se PROPONEN (para que se vea que
# existen y quien los tiene), pero el runner no los duplica.
#
# ANTES DE HACER NADA VALIDA EL GRAFO: un workflow.yaml roto (una arista a un
# nodo que no existe, un script que no esta en bin/) NO se ejecuta: sale con
# error. Un runner que ejecuta un grafo sin validar no es un runner.
#
# EL ESTADO (todo en disco, sin red):
#   $STATE_DIR/state.json                    los PRs (los que estan en draft, el issue, el head)
#   $STATE_DIR/gates/queue.txt               la cola de gates pendiente
#   $LOOP_DIR/gates/<slot>/scope.verdict    el veredicto de cada slot (por SHA)
#
# USO:
#   bash bin/workflow-runner.sh --list        # que nodos son elegibles y por que
#   bash bin/workflow-runner.sh --dry-run     # el comando exacto, sin ejecutarlo
#   bash bin/workflow-runner.sh               # ejecuta UN nodo elegible
#   bash bin/workflow-runner.sh --json        # lo mismo, en JSON
#
# VARIABLES (para las pruebas y para no depender del HOME):
#   ROOT        donde esta bin/ (por defecto, el dir del workflow.yaml)
#   STATE_DIR   donde estan state.json y gates/queue.txt (por defecto, ROOT)
#   STATE_JSON  ruta del state.json (por defecto, $STATE_DIR/state.json)
#   LOOP_DIR    donde estan los veredictos (por defecto, el estandar)
#   WORKFLOW    ruta del workflow.yaml (por defecto, $ROOT/workflow.yaml)
#   SKIP_VALIDATE=1  no valida el grafo antes de actuar (solo para diagnostico)
#
# Lo que ejecuta sale SIEMPRE del YAML: ningun comando se inventa aqui.
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(dirname "$HERE")"
ROOT="${WORKFLOW_ROOT:-$DEFAULT_ROOT}"
STATE_DIR="${STATE_DIR:-$ROOT}"
STATE_JSON="${STATE_JSON:-$STATE_DIR/state.json}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
WORKFLOW="${WORKFLOW:-$ROOT/workflow.yaml}"
LOG="${WORKFLOW_LOG:-$STATE_DIR/logs/workflow-runner.log}"

MODO="ejecutar"
FORMATO="texto"
case "${1:-}" in
  --list)    MODO="listar" ;;
  --dry-run) MODO="dry-run" ;;
  --json)    MODO="listar"; FORMATO="json" ;;
  --help|-h)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
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

# --- el grafo se valida antes de ejecutar nada ------------------------------
VALIDADOR="$ROOT/bin/workflow-validate.py"
if [ "${SKIP_VALIDATE:-0}" != "1" ] && [ -f "$VALIDADOR" ]; then
  if ! "$PY" "$VALIDADOR" --workflow "$WORKFLOW" --root "$ROOT" --quiet >/dev/null 2>&1; then
    echo "workflow-runner: el grafo de $WORKFLOW esta roto; no se ejecuta nada" >&2
    "$PY" "$VALIDADOR" --workflow "$WORKFLOW" --root "$ROOT" >&2 || true
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# El plan: python3 lee el YAML y el estado, y dice que nodos son elegibles.
# Cada linea del plan es:  nodo \t accion \t ejecutable \t razon \t comando \t senal
# ---------------------------------------------------------------------------
PLAN="$("$PY" - "$WORKFLOW" "$ROOT" "$STATE_DIR" "$LOOP_DIR" "$STATE_JSON" <<'PY'
import json, os, shlex, sys

try:
    import yaml
except ImportError:
    print("#ERROR:falta PyYAML", file=sys.stderr)
    sys.exit(2)

wf_path, root, state_dir, loop, ruta_estado = sys.argv[1:6]

try:
    with open(wf_path, encoding="utf-8") as fh:
        grafo = yaml.safe_load(fh)
except Exception as e:
    print("#ERROR:no se pudo leer el workflow: %s" % e, file=sys.stderr)
    sys.exit(2)
if not isinstance(grafo, dict):
    print("#ERROR:el workflow no es un mapa", file=sys.stderr)
    sys.exit(2)

# --- el estado ------------------------------------------------------------
estado = {}
try:
    with open(ruta_estado, encoding="utf-8") as fh:
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

    EL ESTADO SE RECONCILIA: `open_prs` es la lista canonica (que PR esta abierto
    y en que estado) y manda sobre las otras dos, que son notas. Sin esa regla el
    PR #10859 figuraba DRAFT en `prs_esperando_el_gate` y MERGED en `open_prs` al
    mismo tiempo, y el runner proponia un gate para un PR ya mergeado.
    """
    vistos = {}

    def agrega(entry, claves_estado):
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
        if rec is None:
            rec = {"pr": pr, "issue": issue, "sha": sha, "draft": False,
                   "ready": False, "merged": False}
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

    # Las NOTAS van primero (prs_esperando_el_gate, prs_por_slot) y open_prs
    # DESPUES: open_prs es la lista canonica y su estado es el que vale. Al
    # revés, un PR mergeado figuraba DRAFT en una nota y el runner proponia un
    # gate para un PR que ya no existe.
    for entry in (estado.get("prs_esperando_el_gate") or []):
        agrega(entry, ("estado", "state", "status"))
    for pr, texto in (estado.get("prs_por_slot") or {}).items():
        if isinstance(texto, str):
            agrega({"pr": pr, "state": texto}, ("state",))
    for entry in (estado.get("open_prs") or []):
        agrega(entry, ("state", "estado", "status"))
    return vistos

def veredictos():
    """Los veredictos del gate (por SHA) y los slots sin veredicto efectivo."""
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
            try:
                mtime = os.path.getmtime(ruta)
            except OSError:
                mtime = 0
            registro = {
                "slot": slot, "sha": (kv.get("SHA") or "").strip(),
                "veredicto": (kv.get("VERDICT") or "").strip(),
                "status": (kv.get("GATE_STATUS") or "").strip(),
                "nuevos": (kv.get("NEW_FAILURES") or "").strip(),
                "mtime": mtime,
                "tiene_efectivo": os.path.isfile(os.path.join(base, slot, "scope.effective.verdict")),
            }
            por_sha.append(registro)
            slots.append(registro)
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
sin_verdicto = [p for p in drafts if p["sha"] and verdict_de(p["sha"]) is None]
con_verde = [p for p in drafts if p["sha"] and (lambda v: v and es_verde(v))(verdict_de(p["sha"]))]
listos = [p for p in prs.values() if not p["draft"] and not p["merged"] and p["sha"]
          and (lambda v: v and es_verde(v))(verdict_de(p["sha"]))]

# la cola de gates
cola = []
cola_ruta = os.path.join(state_dir, "gates", "queue.txt")
if os.path.isfile(cola_ruta):
    try:
        with open(cola_ruta, encoding="utf-8", errors="replace") as fh:
            for linea in fh:
                partes = linea.split()
                if partes:
                    cola.append({"issue": partes[0], "sha": partes[1] if len(partes) > 1 else ""})
    except OSError:
        cola = []

# los slots con veredicto crudo y sin efectivo: el mas reciente primero
slots_sin_efectivo = sorted([s for s in slots if not s["tiene_efectivo"]],
                             key=lambda s: -s["mtime"])

# --- las senales ----------------------------------------------------------
def objetivo_de(senal):
    """El sujeto de la senal: de donde salen {issue}, {pr}, {sha} y {slot}."""
    if senal == "pr_draft_sin_veredicto":
        if not sin_verdicto:
            return None
        p = sorted(sin_verdicto, key=lambda x: x["pr"])[0]
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
        s = slots_sin_efectivo[0]
        return {"issue": "", "pr": "", "sha": s["sha"], "slot": s["slot"]}
    if senal == "siempre":
        return {"issue": "", "pr": "", "sha": "", "slot": ""}
    if senal == "nunca":
        return None
    return None

# --- los nodos ------------------------------------------------------------
nodos = grafo.get("nodos") or []
orden = ((grafo.get("flujo") or {}).get("orden")) or [n.get("id") for n in nodos]
pos = {nid: i for i, nid in enumerate(orden)}
nodos = sorted(nodos, key=lambda n: pos.get(n.get("id"), 10 ** 6))

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
    for acc in (nodo.get("acciones") or []):
        if not isinstance(acc, dict):
            continue
        etiqueta = acc.get("id", "")
        # `cuando` = todas tienen que ser ciertas; `cuando_alguna` = al menos una.
        todas = acc.get("cuando") or []
        alguna = acc.get("cuando_alguna") or []
        if not todas and not alguna:
            continue
        obj = None
        senal = ""
        ok = True
        for s in todas:
            o = objetivo_de(s)
            if o is None:
                ok = False
                break
            senal = s
            if obj is None:
                obj = o
        if ok and alguna:
            hallada = None
            for s in alguna:
                o = objetivo_de(s)
                if o is not None:
                    hallada = o
                    senal = s
                    break
            if hallada is None:
                ok = False
            elif obj is None:
                obj = hallada
        if not ok:
            continue                      # este nodo todavia no es elegible
        args = render(acc.get("args"), obj)
        if args is None:
            plan.append((nid, etiqueta, "no", senal, "faltan datos para completarlo", ""))
            continue
        script = acc.get("script")
        if not script:
            continue
        ruta = os.path.join(root, script)
        if not os.path.isfile(ruta):
            plan.append((nid, etiqueta, "no", senal, "el script %s no esta en bin/" % script, ""))
            continue
        interp = acc.get("interprete") or ("python3" if script.endswith(".py") else "bash")
        comando = " ".join([interp, shlex.quote(ruta)] + [shlex.quote(a) for a in args])
        if pesado:
            ejecutable = "no"
            razon = "compila Rust: el runner no lo ejecuta (la compilacion es del cron)"
        elif cron:
            ejecutable = "no"
            razon = "ya tiene cron (%s): el runner no lo duplica" % nodo.get("cron_job")
        else:
            ejecutable = "si"
            razon = "elegible"
        plan.append((nid, etiqueta, ejecutable, senal, razon, comando))

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
if [ "$FORMATO" = "json" ]; then
  "$PY" - "$PLAN" <<'PY'
import json, sys
salida = []
for linea in sys.argv[1].splitlines():
    if not linea.strip():
        continue
    partes = linea.split("\t")
    while len(partes) < 6:
        partes.append("")
    nid, acc, ejec, senal, razon, cmd = partes[:6]
    salida.append({"nodo": nid, "accion": acc, "ejecutable": ejec == "si",
                   "razon": razon, "senal": senal, "comando": cmd})
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
  printf '%-16s %-12s %-10s %-32s %s\n' "NODO" "ACCION" "LO EJECUTO" "SENAL" "POR QUE"
  while IFS=$'\t' read -r nid acc ejec senal razon cmd; do
    [ -z "${nid:-}" ] && continue
    printf '%-16s %-12s %-10s %-32s %s\n' "$nid" "$acc" "$ejec" "$senal" "$razon"
  done <<< "$PLAN"
  exit 0
fi

# el primero que el runner puede ejecutar (orden del flujo)
ELEGIDO=""
while IFS=$'\t' read -r nid acc ejec senal razon cmd; do
  [ -z "${nid:-}" ] && continue
  if [ "$ejec" = "si" ]; then
    ELEGIDO="$nid	$acc	$razon	$cmd"
    break
  fi
done <<< "$PLAN"

if [ -z "$ELEGIDO" ]; then
  if [ -n "$PLAN" ]; then
    echo "workflow-runner: hay nodos elegibles pero ninguno los ejecuta el runner:"
    while IFS=$'\t' read -r nid acc ejec senal razon cmd; do
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
