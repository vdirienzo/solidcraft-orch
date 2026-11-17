#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-ci-status.sh - ci-status.sh dice el estado del CI de un head, y lo
# dice con la MISMA regla que el resto del orquestador.
#
# POR QUE EXISTE ESTE TEST (2026-11-12): el estado del CI de un head se
# pregunta MUCHAS veces por sesion (ping-ready, el gate, los reportes). Cada
# vez habia que releer pipeline.py para saber COMO se pregunta. El helper
# (bin/ci-status.sh) existe para no tener que hacerlo, y este test existe
# para que el helper NO se desvíe de la regla:
#
#   a) un head con todos los checks en success -> VERDE, rc=0
#   b) un head con un check en failure         -> ROJO, rc=1, y el detalle
#                                                 nombra el check que fallo
#   c) un head con un check en in_progress     -> PENDIENTE, rc=2
#   d) un head SIN check-runs                  -> PENDIENTE, rc=2
#   e) un numero de PR se resuelve a su head sha (headRefOid)
#   f) el caso de la casa: un 'cancelled' viejo + un 'success' nuevo del
#      MISMO nombre -> VERDE (el cancelled no es un rojo), y el check que
#      'sobro' (tuvo dos runs) sale en SOBRA
#   g) la salida tiene el detalle de QUE checks faltan o sobran
#   h) uso: --help, sin argumento, sha inexistente
#
# NADA DE ESTE SCRIPT TOCA LA RED: el gh es un stub.
#
# LA LECCION DEL STUB (de bin/test-dup-scan.sh): el stub de gh tiene que
# APLICAR REALMENTE el --jq. Un stub que lo ignora responde el JSON entero
# (o nada) y el test mide el STUB, no la regla: todos los casos positivos
# fallarian por culpa del stub, no del codigo. Por eso el stub de este test
# es un script de python que corre jq de verdad con el filtro que le pasan.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_STATUS="$HERE/ci-status.sh"
TESTDIR="$(mktemp -d "${TMPDIR:-/tmp}/ci-status-test-XXXXXX")"
trap 'rm -rf "$TESTDIR"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FALLA- %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

[ -f "$CI_STATUS" ] || { echo "no encuentro $CI_STATUS"; exit 1; }
command -v python3 >/dev/null || { echo "no hay python3"; exit 1; }
command -v jq >/dev/null || { echo "no hay jq (el stub lo necesita para aplicar el --jq)"; exit 1; }

# --- el stub de gh ---------------------------------------------------------
# Responde a las DOS llamadas que importan:
#
#   gh api repos/<repo>/commits/<sha>/check-runs --paginate --jq <filtro>
#       -> los check-runs del sha, CON EL FILTRO APLICADO (jq de verdad).
#          El fixture es la respuesta cruda de la API ({"check_runs":[...]})
#          y el stub le pasa el --jq que le dieron, como hace el gh real.
#
#   gh pr view <n> --repo <repo> --json headRefOid
#       -> el head sha del PR, para probar la resolucion de un numero.
#
# El resto responde vacio. El PATH lo pone el test delante del gh real: si
# no, contesta el gh de verdad y el test mide GitHub en vez del fixture.
mkdir -p "$TESTDIR/bin"
cat > "$TESTDIR/bin/gh" <<'STUB'
#!/usr/bin/env python3
"""El stub de gh de este test.

El --jq se APLICA DE VERDAD con jq: el fixture es la respuesta cruda de la
API y el stub le pasa el filtro que le pasaron. Un stub que ignorara el
--jq mediria el stub, no la regla.
"""
import json
import os
import subprocess
import sys

D = os.environ.get("STUB_DIR", ".")
args = sys.argv[1:]


def fail(msg):
    sys.stderr.write("gh: %s\n" % msg)
    sys.exit(1)


def valor(flag):
    if flag in args:
        i = args.index(flag)
        if i + 1 < len(args):
            return args[i + 1]
    return None


def filtro():
    return valor("--jq") or ""


# --- gh api repos/.../commits/<sha>/check-runs --paginate --jq <filtro> ---
if args[:1] == ["api"]:
    path = ""
    skip = set()
    for i, a in enumerate(args[1:]):
        if a in ("-X", "--method", "-f", "--field", "-F", "--raw-field"):
            skip.add(i + 1)
    for i, a in enumerate(args[1:]):
        if i in skip or a.startswith("-"):
            continue
        path = a
        break

    base = path.split("?")[0]
    if base.startswith("repos/") and base.endswith("/check-runs"):
        sha = base.split("/commits/")[1].split("/")[0]
        fixture = os.path.join(D, "check-runs", "%s.json" % sha)
        if not os.path.isfile(fixture):
            fail("no check-runs para %s" % sha)
        with open(fixture, encoding="utf-8") as fh:
            crudo = fh.read()
        f = filtro()
        if not f:
            sys.stdout.write(crudo)
            sys.exit(0)
        # EL FILTRO SE APLICA: como el gh real, el --jq corre sobre la
        # respuesta cruda y devuelve un objeto por linea.
        r = subprocess.run(["jq", "-c", f], input=crudo, capture_output=True, text=True)
        if r.returncode != 0:
            fail("jq fallo: %s" % (r.stderr or "").strip())
        sys.stdout.write(r.stdout)
        sys.exit(0)

    if "/issues/" in base and base.endswith("/comments"):
        num = base.split("/issues/")[1].split("/")[0]
        path_c = os.path.join(D, "comments", "%s.json" % num)
        if not os.path.isfile(path_c):
            sys.stdout.write("[]")
            sys.exit(0)
        with open(path_c, encoding="utf-8") as fh:
            sys.stdout.write(fh.read())
        sys.exit(0)

    fail("unknown api path: %s" % path)

# --- gh pr view <n> --json headRefOid ---------------------------------------
if args[:2] == ["pr", "view"]:
    num = args[2]
    path = os.path.join(D, "prs", "%s.json" % num)
    if not os.path.isfile(path):
        fail("could not resolve to a PullRequest: %s" % num)
    with open(path, encoding="utf-8") as fh:
        crudo = fh.read()
    f = filtro()
    if not f:
        sys.stdout.write(crudo)
        sys.exit(0)
    r = subprocess.run(["jq", "-c", f], input=crudo, capture_output=True, text=True)
    if r.returncode != 0:
        fail("jq fallo: %s" % (r.stderr or "").strip())
    sys.stdout.write(r.stdout)
    sys.exit(0)

sys.exit(0)
STUB
chmod +x "$TESTDIR/bin/gh"
export STUB_DIR="$TESTDIR"
# The `gh` of the tests is OUTSIDE the PATH and is chosen with GH_BIN
# (README rule 4: a stub of a tool in a directory that may be on the PATH
# is what made a broken `gh` look like it worked).
export GH_BIN="$TESTDIR/bin/gh"

# --- las fixtures ----------------------------------------------------------
mkdir -p "$TESTDIR/check-runs" "$TESTDIR/prs"

# un check de prueba
mkrun(){ # $1 nombre, $2 conclusion, $3 completed_at, $4 id, $5 status
  python3 - "$1" "$2" "$3" "$4" "${5:-completed}" <<'PY'
import json, sys
name, conclusion, completed, rid, status = sys.argv[1:6]
print(json.dumps({"name": name, "status": status, "conclusion": conclusion,
                  "completed_at": completed, "started_at": completed, "id": int(rid)}))
PY
}
mkapi(){ # $1 sha, $2 ...runs -> la respuesta CRUDA de la API (un objeto por
          # linea, como los check-runs; el --jq del stub corre sobre esto)
  local sha="$1"; shift
  printf '{"total_count": %d, "check_runs": [%s]}\n' "$#" "$(
    local primero="si" r
    for r in "$@"; do
      [ "$primero" = "si" ] || printf ', '
      printf '%s' "$r"
      primero="no"
    done
  )" > "$TESTDIR/check-runs/$sha.json"
}

SHA_OK="1111111111111111111111111111111111111111"
SHA_ROJO="2222222222222222222222222222222222222222"
SHA_CORRE="3333333333333333333333333333333333333333"
SHA_VACIO="4444444444444444444444444444444444444444"
SHA_TWIN="5555555555555555555555555555555555555555"
SHA_RERUN="7777777777777777777777777777777777777777"
SHA_INEXISTENTE="6666666666666666666666666666666666666666"

# (a) todos en success
mkapi "$SHA_OK" \
  "$(mkrun 'ci' success 2026-11-07T15:34:38Z 900)" \
  "$(mkrun 'Quick compile' success 2026-11-07T15:30:46Z 830)"

# (b) uno en failure
mkapi "$SHA_ROJO" \
  "$(mkrun 'Defaults line check' failure 2026-11-07T10:10:56Z 800)" \
  "$(mkrun 'ci' success 2026-11-07T10:17:35Z 900)"

# (c) uno corriendo todavia (in_progress, sin conclusion)
mkapi "$SHA_CORRE" \
  "$(python3 -c 'import json;print(json.dumps({"name":"ci","status":"in_progress","conclusion":None,"completed_at":None,"started_at":"2026-11-07T16:02:11Z","id":950}))')" \
  "$(mkrun 'Quick compile' success 2026-11-07T15:30:46Z 830)"

# (d) sin check-runs
mkapi "$SHA_VACIO"

# (f) el caso de la casa: un 'cancelled' viejo + un 'success' nuevo del
#     MISMO nombre -> VERDE, y ese check 'sobro' (tuvo un run superado)
mkapi "$SHA_TWIN" \
  "$(mkrun 'Defaults line check' cancelled 2026-11-06T15:46:35Z 800)" \
  "$(mkrun 'Defaults line check' success 2026-11-06T15:46:43Z 810)" \
  "$(mkrun 'ci' success 2026-11-07T15:34:38Z 900)"

# (f2) un check que se RE-CORRIO entero (dos runs, los dos 'skipped'): no
#      sobra nada. Asi la linea no se ensucia con lo que es normal.
mkapi "$SHA_RERUN" \
  "$(mkrun 'Nightly alert' skipped 2026-11-06T15:46:35Z 700)" \
  "$(mkrun 'Nightly alert' skipped 2026-11-07T15:46:43Z 710)" \
  "$(mkrun 'ci' success 2026-11-07T15:34:38Z 900)"

# (e) un PR que apunta a un sha
printf '{"number": 12345, "headRefOid": "%s"}\n' "$SHA_OK" > "$TESTDIR/prs/12345.json"
# un PR que no existe
# (nada en $TESTDIR/prs/99999.json: el stub falla, como haria gh)

# --- el helper -------------------------------------------------------------
# ci_status <args...> -> la salida en $OUT y el rc en $RC
ci_status() {
  OUT="$(bash "$CI_STATUS" "$@" 2>&1)"
  RC=$?
}

# --- 1) un head con todo en verde ------------------------------------------
echo "== (a) todos los checks en success -> VERDE =="

ci_status --sha "$SHA_OK"
if [ "$RC" -eq 0 ]; then
  ok "(a) un head verde sale con rc=0"
else
  bad "(a) un head verde sale con rc=0" "rc=$RC out=$OUT"
fi
if printf '%s' "$OUT" | grep -q "^ESTADO=VERDE "; then
  ok "(a) la linea dice ESTADO=VERDE"
else
  bad "(a) la linea dice ESTADO=VERDE" "$OUT"
fi
if printf '%s' "$OUT" | grep -q "SHA=$SHA_OK"; then
  ok "(a) la linea dice que SHA miro"
else
  bad "(a) la linea dice que SHA miro" "$OUT"
fi

# --- 2) un head con un failure ---------------------------------------------
echo
echo "== (b) un check en failure -> ROJO =="

ci_status --sha "$SHA_ROJO"
if [ "$RC" -eq 1 ]; then
  ok "(b) un head rojo sale con rc=1"
else
  bad "(b) un head rojo sale con rc=1" "rc=$RC out=$OUT"
fi
if printf '%s' "$OUT" | grep -q "^ESTADO=ROJO "; then
  ok "(b) la linea dice ESTADO=ROJO"
else
  bad "(b) la linea dice ESTADO=ROJO" "$OUT"
fi
if printf '%s' "$OUT" | grep -q "ROJO=Defaults line check"; then
  ok "(b) la linea nombra el check que fallo"
else
  bad "(b) la linea nombra el check que fallo" "$OUT"
fi
if printf '%s' "$OUT" | grep -q "failure"; then
  ok "(b) el detalle dice la conclusion (failure)"
else
  bad "(b) el detalle dice la conclusion (failure)" "$OUT"
fi

# --- 3) un check que todavia corre ----------------------------------------
echo
echo "== (c) un check in_progress -> PENDIENTE =="

ci_status --sha "$SHA_CORRE"
if [ "$RC" -eq 2 ]; then
  ok "(c) un head con un check corriendo sale con rc=2"
else
  bad "(c) un head con un check corriendo sale con rc=2" "rc=$RC out=$OUT"
fi
if printf '%s' "$OUT" | grep -q "^ESTADO=PENDIENTE "; then
  ok "(c) la linea dice ESTADO=PENDIENTE"
else
  bad "(c) la linea dice ESTADO=PENDIENTE" "$OUT"
fi
if printf '%s' "$OUT" | grep -q "PENDIENTE=ci"; then
  ok "(c) la linea nombra el check que falta veredicto"
else
  bad "(c) la linea nombra el check que falta veredicto" "$OUT"
fi

# --- 4) un head sin check-runs ---------------------------------------------
echo
echo "== (d) un head SIN check-runs -> PENDIENTE =="

ci_status --sha "$SHA_VACIO"
if [ "$RC" -eq 2 ]; then
  ok "(d) un head sin check-runs sale con rc=2"
else
  bad "(d) un head sin check-runs sale con rc=2" "rc=$RC out=$OUT"
fi
if printf '%s' "$OUT" | grep -q "^ESTADO=PENDIENTE "; then
  ok "(d) la linea dice ESTADO=PENDIENTE"
else
  bad "(d) la linea dice ESTADO=PENDIENTE" "$OUT"
fi
if printf '%s' "$OUT" | grep -qi "todavia no arranco"; then
  ok "(d) el detalle dice que el CI todavia no arranco"
else
  bad "(d) el detalle dice que el CI todavia no arranco" "$OUT"
fi

# --- 5) un numero de PR se resuelve a su head sha --------------------------
echo
echo "== (e) un numero de PR se resuelve a su head sha =="

ci_status --pr 12345
if [ "$RC" -eq 0 ]; then
  ok "(e) el PR #12345 (head verde) sale con rc=0"
else
  bad "(e) el PR #12345 (head verde) sale con rc=0" "rc=$RC out=$OUT"
fi
if printf '%s' "$OUT" | grep -q "SHA=$SHA_OK"; then
  ok "(e) el PR se resuelve a su head sha"
else
  bad "(e) el PR se resuelve a su head sha" "$OUT"
fi

# un numero sin --pr tambien se resuelve (es lo que hace el agente)
ci_status 12345
if printf '%s' "$OUT" | grep -q "SHA=$SHA_OK"; then
  ok "(e) un numero solo tambien se resuelve a su head sha"
else
  bad "(e) un numero solo tambien se resuelve a su head sha" "$OUT"
fi

# --- 6) el caso de la casa: el cancelled viejo no es un rojo ---------------
echo
echo "== (f) un 'cancelled' viejo + un 'success' nuevo del mismo nombre =="

ci_status --sha "$SHA_TWIN"
if [ "$RC" -eq 0 ]; then
  ok "(f) el cancelled viejo NO es un rojo: rc=0"
else
  bad "(f) el cancelled viejo NO es un rojo: rc=0" "rc=$RC out=$OUT"
fi
if printf '%s' "$OUT" | grep -q "^ESTADO=VERDE "; then
  ok "(f) la linea dice ESTADO=VERDE"
else
  bad "(f) la linea dice ESTADO=VERDE" "$OUT"
fi
if printf '%s' "$OUT" | grep -q "ROJO=-"; then
  ok "(f) la linea no nombra ningun check en rojo"
else
  bad "(f) la linea no nombra ningun check en rojo" "$OUT"
fi
if printf '%s' "$OUT" | grep -q "SOBRA=Defaults line check"; then
  ok "(f) la linea dice que check 'sobro' (tuvo un run superado)"
else
  bad "(f) la linea dice que check 'sobro' (tuvo un run superado)" "$OUT"
fi

# un check que se re-corrio entero (los dos 'skipped') NO sobra nada
ci_status --sha "$SHA_RERUN"
if [ "$RC" -eq 0 ]; then
  ok "(f2) un check re-corrido entero sigue verde (rc=0)"
else
  bad "(f2) un check re-corrido entero sigue verde (rc=0)" "rc=$RC out=$OUT"
fi
if printf '%s' "$OUT" | grep -q "SOBRA=-"; then
  ok "(f2) un check re-corrido entero NO 'sobra' (la linea no se ensucia)"
else
  bad "(f2) un check re-corrido entero NO 'sobra' (la linea no se ensucia)" "$OUT"
fi

# --- 7) el detalle: que checks faltan o sobran -----------------------------
echo
echo "== (g) la linea dice QUE checks faltan o sobran =="

ci_status --sha "$SHA_CORRE"
if printf '%s' "$OUT" | grep -q "CHECKS=2"; then
  ok "(g) la linea cuenta los checks del head"
else
  bad "(g) la linea cuenta los checks del head" "$OUT"
fi
if printf '%s' "$OUT" | grep -q "PENDIENTE=ci"; then
  ok "(g) la linea dice el check que FALTA"
else
  bad "(g) la linea dice el check que FALTA" "$OUT"
fi

# --- 8) el uso -------------------------------------------------------------
echo
echo "== (h) el uso =="

if bash "$CI_STATUS" --help >/dev/null 2>&1; then
  ok "(h) --help sale con rc=0"
else
  RC=$?
  bad "(h) --help sale con rc=0" "rc=$RC"
fi
if bash "$CI_STATUS" --help 2>&1 | grep -q "VERDE"; then
  ok "(h) --help dice los codigos de salida"
else
  bad "(h) --help dice los codigos de salida" ""
fi

ci_status
if [ "$RC" -eq 3 ]; then
  ok "(h) sin argumento es un error de uso (rc=3)"
else
  bad "(h) sin argumento es un error de uso (rc=3)" "rc=$RC out=$OUT"
fi

# un sha que no existe: gh falla, no se puede afirmar que este verde
ci_status --sha "$SHA_INEXISTENTE"
if [ "$RC" -eq 2 ]; then
  ok "(h) un sha que no se puede leer sale con rc=2 (no verde)"
else
  bad "(h) un sha que no se puede leer sale con rc=2 (no verde)" "rc=$RC out=$OUT"
fi

ci_status --pr 99999
if [ "$RC" -eq 3 ]; then
  ok "(h) un PR que no existe es un error de uso (rc=3)"
else
  bad "(h) un PR que no existe es un error de uso (rc=3)" "rc=$RC out=$OUT"
fi

# --- 9) la idempotencia: dos corridas, lo mismo ---------------------------
echo
echo "== (i) dos corridas dan lo mismo =="

ci_status --sha "$SHA_ROJO"
OUT1="$OUT"
ci_status --sha "$SHA_ROJO"
if [ "$OUT1" = "$OUT" ]; then
  ok "(i) correrlo dos veces da la misma linea"
else
  bad "(i) correrlo dos veces da la misma linea" "primera=$OUT1 segunda=$OUT"
fi

# --- el resumen ------------------------------------------------------------
echo
echo "== el resumen =="
if [ "$FAIL" -eq 0 ]; then
  echo "$PASS casos pasan, 0 fallan"
  exit 0
fi
echo "$PASS caso(s) pasan, $FAIL fallan"
exit 1
