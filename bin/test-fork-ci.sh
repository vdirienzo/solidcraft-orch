#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-fork-ci.sh - los tests de bin/fork-ci.sh, el CI de upstream
# corrido en el fork como gate de un PR.
#
# POR QUE (2026-11-21): el gate pasa a ser el ci.yml de upstream
# despachado en el fork (CONTRIBUTING.md, "Sending a change", punto 3).
# Despachar cuesta runners y horas de reloj, y leer cuesta API: un
# despacho de mas son ~55 jobs, y una lectura que miente promueve un PR
# que el merge queue va a rechazar. Las reglas que se prueban:
#   a) el uso: --help sale 0, sin rama/sha o con una opcion o un sha
#      invalidos sale 64;
#   b) --status imprime UNA linea "FORKCI=... SHA=... RUN=... FALLAN=..."
#      y sale 0 VERDE, 1 ROJO, 2 PENDIENTE, 3 NINGUNO, 6 si no se pudo
#      leer (DESCONOCIDO: nunca un NINGUNO, que despacharia a ciegas);
#   c) FALLAN nombra los jobs en rojo, con la regla del mas reciente de
#      cada nombre (la de pipeline.evaluar_check_runs);
#   d) el issue se resuelve a NUESTRO PR abierto (su rama y su head); un
#      issue sin PR sale 4;
#   e) el despacho es UNO por sha: la segunda llamada dice YA_HAY_RUN y
#      no despacha; --force si despacha; --no-cross no pide cross_compile;
#   f) la rama del fork tiene que estar en el sha (4 si no, y 4 si la
#      rama no existe): el run prueba la punta de la rama;
#   g) el tope de runs en vuelo (5);
#   h) las lecturas de estado son pocas: un verde limpio es UNA llamada.
#
# HERMETICO: el gh es un stub FUERA del PATH (GH_BIN), el ORCH_DIR es un
# directorio temporal (las marcas de despacho y la cache de jobs caen
# ahi) y GitHub no se toca nunca.
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_CI="$HERE/fork-ci.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-fork-ci.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FALLA- %s\n' "$1"; fail=$((fail+1)); if [ $# -gt 1 ]; then printf '       %s\n' "$2"; fi; }

[ -f "$FORK_CI" ] || { echo "no encuentro $FORK_CI"; exit 1; }
command -v python3 >/dev/null || { echo "no hay python3"; exit 1; }

export ORCH_DIR="$TMP/orch"
export LOOP_DIR="$TMP/loop"
mkdir -p "$ORCH_DIR" "$LOOP_DIR" "$TMP/stub"
# EL GUARDIA (2026-11-21): el estado de la suite nunca cae en el orquestador vivo.
if [ -f "$HERE/test-guard.sh" ]; then
  # shellcheck disable=SC1091
  source "$HERE/test-guard.sh"
  test_guard_orch_dir "$ORCH_DIR"
fi
export FORK_CI_POLL_S=0
unset GATE_MODE FORK_CI_CROSS FORK_CI_MAX_INFLIGHT FORK_CI_CANCEL_STALE FORK_CI_GRACE_S

SHA="a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
OTRO="b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
D="$TMP/stub"

# El gh de los tests: responde de los archivos de $STUB_DIR y anota cada
# llamada en calls.log.
cat > "$TMP/gh-stub" <<'STUB'
#!/usr/bin/env python3
import json, os, sys, urllib.parse
D = os.environ["STUB_DIR"]
A = sys.argv[1:]
def log(l):
    open(os.path.join(D, "calls.log"), "a").write(l + "\n")
def cargar(n, default):
    try:
        return json.load(open(os.path.join(D, n)))
    except Exception:
        return default
def val(flag, default=""):
    return A[A.index(flag) + 1] if flag in A and A.index(flag) + 1 < len(A) else default
log("GH " + " ".join(A))
if A[:2] == ["workflow", "run"]:
    rama = val("--ref")
    log("DISPATCH:%s %s" % (rama, " ".join(A[2:])))
    runs = cargar("runs.json", [])
    rid = 9000 + len(runs) + 1
    runs.append({"id": rid, "status": "queued", "conclusion": None, "event": "workflow_dispatch",
                 "html_url": "https://github.com/vdirienzo/solidcraft/actions/runs/%d" % rid,
                 "head_sha": cargar("heads.json", {}).get(rama, ""), "head_branch": rama,
                 "created_at": "2026-11-21T23:00:00Z", "updated_at": "2026-11-21T23:00:00Z",
                 "run_attempt": 1})
    json.dump(runs, open(os.path.join(D, "runs.json"), "w"))
    sys.exit(0)
if A[:2] == ["pr", "list"]:
    print(json.dumps(cargar("prs.json", [])))
    sys.exit(0)
if A[:1] == ["api"]:
    ruta = next(a for a in A[1:] if not a.startswith("-") and a not in ("POST",))
    path, _, query = ruta.partition("?")
    q = urllib.parse.parse_qs(query)
    if os.path.exists(os.path.join(D, "fail")):
        sys.stderr.write("gh: HTTP 502: Server Error\n")
        sys.exit(1)
    if path.endswith("/runs") and "/actions/workflows/" in path:
        log("RUNS")
        runs = cargar("runs.json", [])
        if q.get("head_sha"):
            runs = [r for r in runs if r.get("head_sha") == q["head_sha"][0]]
        print(json.dumps({"total_count": len(runs), "workflow_runs": runs}))
    elif path.endswith("/jobs"):
        rid = path.split("/actions/runs/")[1].split("/")[0]
        log("JOBS:" + rid)
        print(json.dumps([{"jobs": cargar("jobs-%s.json" % rid, [])}]))
    elif path.endswith("/cancel"):
        log("CANCEL:" + path.split("/actions/runs/")[1].split("/")[0])
        print("{}")
    elif "/git/ref/heads/" in path:
        rama = path.split("/git/ref/heads/", 1)[1]
        heads = cargar("heads.json", {})
        if rama not in heads:
            sys.stderr.write("gh: Not Found (HTTP 404)\n")
            sys.exit(1)
        print(json.dumps({"object": {"sha": heads[rama]}}))
    else:
        sys.stderr.write("gh: el stub no conoce %s\n" % path)
        sys.exit(1)
    sys.exit(0)
sys.exit(0)
STUB
chmod 755 "$TMP/gh-stub"
export GH_BIN="$TMP/gh-stub" STUB_DIR="$D"

reset(){
  rm -rf "$D" "$ORCH_DIR/gates/fork-ci"; mkdir -p "$D"
  printf '{"fix-100": "%s"}\n' "${1:-$SHA}" > "$D/heads.json"
  echo '[]' > "$D/runs.json"
  : > "$D/calls.log"
}
# runs: una linea por run, id|status|conclusion|head_sha|rama|created_at
set_runs(){ python3 - "$D/runs.json" 3<&0 <<'PY'
import json, os, sys
out = []
for l in os.fdopen(3).read().splitlines():
    if l.strip():
        rid, st, co, sha, rama, cr = l.split("|")
        out.append({"id": int(rid), "status": st, "conclusion": co or None,
                    "html_url": "https://github.com/vdirienzo/solidcraft/actions/runs/" + rid,
                    "head_sha": sha, "head_branch": rama, "event": "workflow_dispatch",
                    "created_at": cr, "updated_at": cr, "run_attempt": 1})
json.dump(out, open(sys.argv[1], "w"))
PY
}
job(){ printf '{"id":%s,"name":"%s","status":"completed","conclusion":"%s","started_at":"2026-11-21T10:01:00Z","completed_at":"%s"}' "$1" "$2" "$3" "${4:-2026-11-21T11:00:00Z}"; }
OUT=""; ERR=""; RC=0
run_fk(){ OUT="$(bash "$FORK_CI" "$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"; }
calls(){ grep -c "^$1" "$D/calls.log" || true; }

# --- a) el uso ----------------------------------------------------------------
reset
run_fk --help
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'FORKCI=VERDE|ROJO|PENDIENTE|NINGUNO' \
  && ok "a) --help sale 0 y dice la linea de estado" || no "a) --help sale 0 y dice la linea de estado" "rc=$RC"
run_fk
[ "$RC" -eq 64 ] && ok "a) sin rama ni sha es un error de uso (64)" || no "a) sin rama ni sha es un error de uso (64)" "rc=$RC"
run_fk fix-100 --rapido
[ "$RC" -eq 64 ] && ok "a) una opcion desconocida es un error de uso (64)" || no "a) una opcion desconocida es un error de uso (64)" "rc=$RC"
run_fk --status --sha 'zz;rm'
[ "$RC" -eq 64 ] && ok "a) un sha que no es hexadecimal es un error de uso (64)" || no "a) un sha que no es hexadecimal es un error de uso (64)" "rc=$RC"
run_fk 'fix-100;x' --status
[ "$RC" -eq 64 ] && [ "$(calls GH)" -eq 0 ] && ok "a) una rama con caracteres raros no llega a gh (64)" \
  || no "a) una rama con caracteres raros no llega a gh (64)" "rc=$RC calls=$(calls GH)"

# --- b) --status: una linea y el codigo de cada estado ----------------------
reset
run_fk --status --sha "$SHA"
[ "$RC" -eq 3 ] && [ "$OUT" = "FORKCI=NINGUNO SHA=$SHA RUN= FALLAN=" ] \
  && ok "b) sin run: FORKCI=NINGUNO y rc=3" || no "b) sin run: FORKCI=NINGUNO y rc=3" "rc=$RC out=$OUT"
set_runs <<EOF
11|completed|success|$SHA|fix-100|2026-11-21T10:00:00Z
EOF
: > "$D/calls.log"
run_fk --status --sha "$SHA"
[ "$RC" -eq 0 ] && [ "$OUT" = "FORKCI=VERDE SHA=$SHA RUN=https://github.com/vdirienzo/solidcraft/actions/runs/11 FALLAN=" ] \
  && ok "b) un run en success: FORKCI=VERDE con la url del run y rc=0" || no "b) un run en success: FORKCI=VERDE y rc=0" "rc=$RC out=$OUT"
[ "$(calls GH)" -eq 1 ] && ok "h) un verde limpio es UNA llamada a la API (sin leer los jobs)" \
  || no "h) un verde limpio es UNA llamada a la API" "$(cat "$D/calls.log")"
set_runs <<EOF
12|in_progress||$SHA|fix-100|2026-11-21T10:00:00Z
EOF
run_fk --status --sha "$SHA"
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^FORKCI=PENDIENTE ' \
  && ok "b) un run en vuelo: FORKCI=PENDIENTE y rc=2" || no "b) un run en vuelo: FORKCI=PENDIENTE y rc=2" "rc=$RC out=$OUT"
: > "$D/fail"
run_fk --status --sha "$SHA"
rm -f "$D/fail"
[ "$RC" -eq 6 ] && printf '%s' "$OUT" | grep -q '^FORKCI=DESCONOCIDO ' \
  && ok "b) la API que no responde es DESCONOCIDO (rc=6), nunca NINGUNO" || no "b) la API que no responde es DESCONOCIDO (rc=6)" "rc=$RC out=$OUT"

# --- c) FALLAN con la regla del mas reciente de cada nombre -----------------
reset
set_runs <<EOF
21|completed|failure|$SHA|fix-100|2026-11-21T10:00:00Z
EOF
printf '[%s,%s,%s]\n' "$(job 1 'Native Linux tests' failure)" "$(job 2 'GPU path tests (1/4)' failure)" \
  "$(job 3 'Native Linux Clippy' success)" > "$D/jobs-21.json"
run_fk --status --sha "$SHA"
[ "$RC" -eq 1 ] && [ "${OUT##*FALLAN=}" = "GPU path tests (1/4),Native Linux tests" ] \
  && ok "c) un run rojo: rc=1 y FALLAN nombra los jobs en rojo (separados por comas)" \
  || no "c) un run rojo: rc=1 y FALLAN nombra los jobs en rojo" "rc=$RC out=$OUT"
set_runs <<EOF
21|completed|failure|$SHA|fix-100|2026-11-21T10:00:00Z
22|completed|success|$SHA|fix-100|2026-11-21T14:00:00Z
EOF
printf '[%s,%s]\n' "$(job 4 'Native Linux tests' success 2026-11-21T15:00:00Z)" \
  "$(job 5 'GPU path tests (1/4)' success 2026-11-21T15:00:00Z)" > "$D/jobs-22.json"
run_fk --status --sha "$SHA"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'RUN=https://github.com/vdirienzo/solidcraft/actions/runs/22 ' \
  && ok "c) un re-despacho verde del mismo sha gana al rojo viejo (el mas reciente de cada nombre)" \
  || no "c) un re-despacho verde del mismo sha gana al rojo viejo" "rc=$RC out=$OUT"

# --- d) el issue es nuestro PR abierto ---------------------------------------
reset
cat > "$D/prs.json" <<EOF
[{"number": 501, "title": "Arregla algo (#100)", "isDraft": true, "body": "Fixes #100\n",
  "headRefName": "fix-100", "headRefOid": "$SHA", "labels": [], "author": {"login": "vdirienzo"}},
 {"number": 502, "title": "Otra cosa (#200)", "isDraft": true, "body": "Fixes #200\n",
  "headRefName": "fix-200", "headRefOid": "$OTRO", "labels": [], "author": {"login": "vdirienzo"}}]
EOF
run_fk 100 --status
[ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q "^FORKCI=NINGUNO SHA=$SHA " && printf '%s' "$ERR" | grep -q 'PR #501 (rama fix-100)' \
  && ok "d) el issue se resuelve a nuestro PR (su rama y su head)" || no "d) el issue se resuelve a nuestro PR" "rc=$RC out=$OUT err=$ERR"
run_fk 300 --status
[ "$RC" -eq 4 ] && ok "d) un issue sin PR nuestro sale 4" || no "d) un issue sin PR nuestro sale 4" "rc=$RC err=$ERR"

# --- e) UN despacho por sha ----------------------------------------------------
reset
run_fk fix-100 --sha "$SHA"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "^FORKCI_DESPACHO=DESPACHADO SHA=$SHA RAMA=fix-100 RUN=https://" \
  && ok "e) el despacho sale 0 y dice la url del run" || no "e) el despacho sale 0 y dice la url del run" "rc=$RC out=$OUT err=$ERR"
grep -q '^DISPATCH:fix-100 ci.yml --ref fix-100 -R vdirienzo/solidcraft -f cross_compile=true' "$D/calls.log" \
  && ok "e) despacha ci.yml en el fork, en la rama, con cross_compile=true" || no "e) despacha ci.yml con cross_compile=true" "$(grep DISPATCH "$D/calls.log")"
run_fk fix-100 --sha "$SHA"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^FORKCI_DESPACHO=YA_HAY_RUN ' && [ "$(calls DISPATCH)" -eq 1 ] \
  && ok "e) la segunda llamada para el mismo sha NO despacha (YA_HAY_RUN)" || no "e) la segunda llamada NO despacha" "rc=$RC out=$OUT"
run_fk fix-100 --sha "$SHA" --force
[ "$(calls DISPATCH)" -eq 2 ] && ok "e) --force despacha aunque el sha ya tenga run" || no "e) --force despacha" "$(calls DISPATCH)"
reset
run_fk fix-100 --no-cross
grep -q '^DISPATCH:' "$D/calls.log" && ! grep -q 'cross_compile' "$D/calls.log" \
  && ok "e) --no-cross no pide cross_compile (y sin --sha usa la punta de la rama)" || no "e) --no-cross no pide cross_compile" "$(cat "$D/calls.log")"

# --- f) la rama tiene que estar en el sha -------------------------------------
reset "$OTRO"
run_fk fix-100 --sha "$SHA"
[ "$RC" -eq 4 ] && printf '%s' "$OUT" | grep -q '^FORKCI_DESPACHO=RAMA_MOVIDA ' && [ "$(calls DISPATCH)" -eq 0 ] \
  && ok "f) la rama del fork en otro sha: no se despacha (RAMA_MOVIDA, rc=4)" || no "f) la rama en otro sha: no se despacha" "rc=$RC out=$OUT"
run_fk fix-999 --sha "$SHA"
[ "$RC" -eq 4 ] && printf '%s' "$OUT" | grep -q '^FORKCI_DESPACHO=RAMA_NO_EXISTE ' \
  && ok "f) una rama que no esta en el fork sale 4 (RAMA_NO_EXISTE)" || no "f) una rama que no esta en el fork sale 4" "rc=$RC out=$OUT"

# --- g) el tope de runs en vuelo ----------------------------------------------
reset
set_runs <<EOF
31|in_progress||$OTRO|fix-200|2026-11-21T10:00:00Z
32|queued||$OTRO|fix-300|2026-11-21T10:00:00Z
EOF
run_fk fix-100 --sha "$SHA"
[ "$RC" -eq 5 ] && printf '%s' "$OUT" | grep -q '^FORKCI_DESPACHO=OCUPADO ' && [ "$(calls DISPATCH)" -eq 0 ] \
  && ok "g) con FORK_CI_MAX_INFLIGHT runs en vuelo no despacha (OCUPADO, rc=5)" || no "g) con el tope lleno no despacha" "rc=$RC out=$OUT"
FORK_CI_MAX_INFLIGHT=3 run_fk fix-100 --sha "$SHA"
[ "$RC" -eq 0 ] && [ "$(calls DISPATCH)" -eq 1 ] \
  && ok "g) FORK_CI_MAX_INFLIGHT sube el tope" || no "g) FORK_CI_MAX_INFLIGHT sube el tope" "rc=$RC out=$OUT"

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
