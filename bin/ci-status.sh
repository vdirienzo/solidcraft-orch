#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ci-status.sh - el estado del CI de un head, en UNA linea.
#
# POR QUE EXISTE (2026-11-12): el CI de un head se pregunta MUCHAS veces por
# sesion (ping-ready, el gate, los reportes) y cada vez habia que releer el
# codigo de pipeline.py para saber COMO se pregunta. Esto es la pregunta
# hecha: una orden, una linea, el veredicto y de que.
#
# LA REGLA NO SE COPIA: el veredicto lo dice pipeline.evaluar_check_runs (la
# MISMA que usan ping-ready.sh y gate.sh, y la que tiene sus tests). Este
# script solo la USA: trae los check-runs con pipeline.fetch_check_runs y los
# evalua con pipeline.evaluar_check_runs. Si la regla cambia, el helper cambia
# con ella: no hay una segunda copia que se pueda quedar vieja.
#
# SOLO LECTURA e IDEMPOTENTE: pregunta a GitHub y no escribe nada. Correrlo
# dos veces da lo mismo.
#
# USO:
#   bash bin/ci-status.sh <sha|pr>
#   bash bin/ci-status.sh --pr 12345
#   bash bin/ci-status.sh --sha 1b95c2d2f819479504b75ae85364d96e399ca300
#
# Un argumento TODO de digitos se toma como numero de PR y se resuelve a su
# head sha (headRefOid); cualquier otra cosa se toma como sha.
#
# SALIDA (una linea, en stdout):
#   ESTADO=VERDE|ROJO|PENDIENTE SHA=<sha> CHECKS=<n> ROJO=<nombres|-> \
#     PENDIENTE=<nombres|-> SOBRA=<nombres|-> DETALLE=<que pasa>
#
#   ESTADO     el veredicto (pipeline.evaluar_check_runs)
#   CHECKS     cuantos checks (nombres distintos) tiene el head
#   ROJO       los checks que fallaron
#   PENDIENTE  los checks que todavia NO tienen veredicto (FALTAN)
#   SOBRA      los checks que tienen un run SOBRANTE: un run viejo que quedo
#              superado por otro del mismo nombre (el 'cancelled' que cancela
#              al run nuevo). No es un rojo: es un run de mas, y por eso el
#              rollup lo muestra junto al verde y hace ver rojo un PR verde.
#              Solo se listan los que SOBRAN de verdad (tienen un 'cancelled'
#              o un 'stale' superado): un check que se re-corrio entero
#              (scheduled, re-run) no sobra nada y no ensucia la linea.
#   DETALLE    el detalle de la regla, textual
#
# CODIGOS DE SALIDA:
#   0  el CI del head esta VERDE
#   1  el CI del head esta ROJO
#   2  el CI del head esta PENDIENTE (todavia no hay veredicto, o no se pudo
#      leer el CI: no se puede afirmar que este verde)
#   3  uso incorrecto (falta el argumento, o el PR no existe)
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# El orquestador: por la REGLA DEL CI (el directorio que tiene bin/pipeline.py),
# con el default del ambiente. El default usa $HOME, no un path fijo: en otra
# PC el orquestador esta en otro HOME.
ORCH_DEFAULT="${ORCH_DEFAULT:-$HOME/.local/share/solidcraft-orch}"
ORCH_DIR="${ORCH_DIR:-$(dirname "$HERE")}"
if [ ! -f "$ORCH_DIR/bin/pipeline.py" ] && [ -f "$ORCH_DEFAULT/bin/pipeline.py" ]; then
  ORCH_DIR="$ORCH_DEFAULT"
fi
PIPELINE_PY=""
for cand in "$ORCH_DIR/bin/pipeline.py" "$HERE/pipeline.py"; do
  [ -f "$cand" ] && { PIPELINE_PY="$cand"; break; }
done
if [ -z "$PIPELINE_PY" ]; then
  echo "ci-status.sh: no encuentro pipeline.py: la regla del CI vive ahi" >&2
  exit 3
fi
export PIPELINE_DIR="$(dirname "$PIPELINE_PY")"

# El repo donde se mira el CI: el UPSTREAM (ahi viven los check-runs del sha
# de un PR abierto contra el upstream, aunque el push sea del fork).
REPO="${REPO:-tangency-labs/solidcraft}"
VERBOSE=""

usage(){
  cat <<'USAGE' >&2
uso: ci-status.sh [--pr <n> | --sha <sha>] [--repo <owner/repo>] [-v] [<sha|pr>]
  --pr <n>      el numero de un PR: se resuelve a su head sha
  --sha <sha>   el sha de un head
  --repo <r>    el repo donde se mira el CI (tangency-labs/solidcraft)
  -v            ademas de la linea, el detalle check por check
  --help        esta ayuda
  (sin --pr/--sha: un argumento TODO de digitos es un numero de PR, y otra
   cosa es un sha)

salida (una linea):
  ESTADO=VERDE|ROJO|PENDIENTE SHA=<sha> CHECKS=<n> ROJO=<nombres|-> \
    PENDIENTE=<nombres|-> SOBRA=<nombres|-> DETALLE=<que pasa>

codigos de salida:
  0  VERDE      el CI del head esta verde
  1  ROJO       el CI del head esta rojo
  2  PENDIENTE  todavia no hay veredicto (o no se pudo leer el CI)
  3  uso incorrecto
USAGE
}

MODE="auto"
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)   MODE="pr"; shift; [ $# -gt 0 ] || { echo "ci-status.sh: --pr necesita un numero" >&2; exit 3; }; TARGET="$1"; shift ;;
    --pr=*) MODE="pr"; TARGET="${1#*=}"; shift ;;
    --sha)  MODE="sha"; shift; [ $# -gt 0 ] || { echo "ci-status.sh: --sha necesita un sha" >&2; exit 3; }; TARGET="$1"; shift ;;
    --sha=*) MODE="sha"; TARGET="${1#*=}"; shift ;;
    --repo) shift; [ $# -gt 0 ] || { echo "ci-status.sh: --repo necesita un repo" >&2; exit 3; }; REPO="$1"; shift ;;
    --repo=*) REPO="${1#*=}"; shift ;;
    -v|--verbose) VERBOSE="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; [ $# -gt 0 ] || break; TARGET="$1"; shift; break ;;
    -*) echo "ci-status.sh: opcion desconocida: $1" >&2; usage; exit 3 ;;
    *) TARGET="$1"; shift ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "ci-status.sh: falta el sha o el numero de PR" >&2
  usage
  exit 3
fi

# Sin --pr/--sha: un numero es un PR, otra cosa es un sha. Un sha de 40
# digitos (todo hexadecimal puede ser solo digitos) es un sha, no un PR.
if [ "$MODE" = "auto" ]; then
  if [[ "$TARGET" =~ ^[0-9]{1,12}$ ]]; then MODE="pr"; else MODE="sha"; fi
fi

# El codigo de python pide el veredicto a pipeline.py (la regla) e imprime
# una sola linea. Los codigos de salida los pone el, no el bash.
python3 - "$MODE" "$TARGET" "$REPO" "$VERBOSE" <<'PY'
import json
import os
import subprocess
import sys

sys.path.insert(0, os.environ["PIPELINE_DIR"])
import pipeline

mode, target, repo, verbose = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]


def gh_run(*args):
    """(stdout, error) de una llamada a gh. El error es la primera linea del
    stderr, como lo reporta pipeline."""
    r = subprocess.run([pipeline.GH_BIN, *args], capture_output=True, text=True,
                       timeout=180)
    if r.returncode == 0:
        return r.stdout, ""
    err = (r.stderr or "").strip().splitlines()
    return "", (err[0] if err else "gh fallo (rc=%d)" % r.returncode)


if mode == "pr":
    out, err = gh_run("pr", "view", target, "--repo", repo, "--json", "headRefOid")
    if err:
        sys.stderr.write("ci-status.sh: no se pudo leer el PR #%s: %s\n" % (target, err))
        sys.exit(3)
    try:
        sha = (json.loads(out or "{}") or {}).get("headRefOid") or ""
    except ValueError:
        sha = ""
    if not sha:
        sys.stderr.write("ci-status.sh: el PR #%s no tiene head sha\n" % target)
        sys.exit(3)
else:
    sha = target

runs, error = pipeline.fetch_check_runs(sha, repo)
if error:
    # No se pudo leer el CI: NO se puede afirmar que este verde. PENDIENTE con
    # el motivo en el detalle (lo mismo que hace pipeline.py).
    print("ESTADO=PENDIENTE SHA=%s CHECKS=0 ROJO=- PENDIENTE=- SOBRA=- "
          "DETALLE=no pude leer los check-runs: %s" % (sha, error))
    sys.exit(2)

estado, detalle = pipeline.evaluar_check_runs(runs)

# El desglose por check: la MISMA regla, aplicada a un grupo de runs por vez
# (evaluar_check_runs agrupa por nombre). Asi los nombres no salen de otra
# regla: salen de la misma.
grupos = {}
for r in runs:
    if isinstance(r, dict):
        grupos.setdefault(r.get("name") or "?", []).append(r)

rojos, faltan, sobra = [], [], []
for nombre, rs in sorted(grupos.items()):
    g_estado, _ = pipeline.evaluar_check_runs(rs)
    if g_estado == pipeline.ROJO:
        rojos.append(nombre)
    elif g_estado == pipeline.PENDIENTE:
        faltan.append(nombre)
    # Un run SOBRANTE: un run viejo que quedo superado por otro del mismo
    # nombre (el 'cancelled' que cancela al run nuevo). Se reconoce con la
    # misma regla de pipeline: el run vigente mas un 'cancelled'/'stale'
    # viejo. Un check que se re-corrio entero (scheduled, re-run) NO sobra
    # nada: eso no ensucia la linea.
    vigente = pipeline._vigente(rs)
    if vigente is not None:
        for r in rs:
            if pipeline._id(r) >= pipeline._id(vigente):
                continue
            if pipeline._conclusion(r) in ("cancelled", "stale"):
                sobra.append(nombre)
                break

print("ESTADO=%s SHA=%s CHECKS=%d ROJO=%s PENDIENTE=%s SOBRA=%s DETALLE=%s" % (
    estado.upper(), sha, len(grupos),
    ",".join(rojos) or "-",
    ",".join(faltan) or "-",
    ",".join(sobra) or "-",
    detalle))

if verbose:
    for nombre, rs in sorted(grupos.items()):
        for r in sorted(rs, key=lambda x: (pipeline._completed_at(x), pipeline._id(x))):
            print("  %s: %s (%s) completed_at=%s id=%s" % (
                nombre,
                pipeline._conclusion(r) or pipeline._status(r) or "?",
                pipeline._status(r) or "?",
                pipeline._completed_at(r) or "-",
                pipeline._id(r)))

sys.exit({"verde": 0, "rojo": 1, "pendiente": 2}[estado])
PY
