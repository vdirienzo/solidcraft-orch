#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-pipeline-ci.sh - el pipeline NO puede promover un PR a ready
# con el CI de GitHub en rojo, y NO puede mentir en la linea
# "Changes a default:".
#
# El CI de upstream (pr-checks.yml) corre con
#   concurrency: {group: pr-checks-<n>, cancel-in-progress: true}
# asi que una edicion del body CANCELA el run anterior y crea otro con
# el MISMO nombre. El estado real de un PR hay que leerlo de los
# check-runs del HEAD SHA, no del rollup: el rollup mezcla el
# "cancelled" del run viejo con el "success" del nuevo (PR #11359,
# #9843).
#
# Y la linea "Changes a default:" no se inventa: un "no" automatico
# puede ser falso (un PR que mete una preferencia nueva SI cambia un
# default) y el mantenedor lo va a marcar.
#
# Y EL CRON NO MIENTE (2026-11-17): este corre cada 5 minutos, asi que
# sus silencios son los que hacen que el maintainer crea que algo pasa
# cuando no pasa nada:
#   - un 'gh' que falla tiene que ser VISIBLE y el rc tiene que llegar
#     al exit code (Regla 7 del repo: un veredicto que no llega al exit
#     code es peor que no tener veredicto);
#   - un veredicto de gate con el SHA CORTO se tiene que encontrar con
#     el head completo de la API (si no, el PR nunca llega a ready);
#   - el comentario del veredicto se postea UNA vez (con un marcador),
#     no cada 5 minutos en un PR publico;
#   - 'gh pr ready' que falla se loguea y cuenta como problema;
#   - la lista de PRs sale de la API paginada (no de un --limit 30);
#   - el issue de un PR sale del titulo o de un verbo de cierre real,
#     nunca de un '#numero' suelto.
#
# NADA DE ESTE SCRIPT TOCA LA RED: los check-runs se inyectan como
# dato y el gh es un stub.
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PIPELINE="$HERE/pipeline.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FALLA- %s\n' "$1"; fail=$((fail+1)); if [ $# -gt 1 ]; then printf '       %s\n' "$2"; fi; }

[ -f "$PIPELINE" ] || { echo "no encuentro $PIPELINE"; exit 1; }
command -v python3 >/dev/null || { echo "no hay python3"; exit 1; }
command -v jq >/dev/null || { echo "no hay jq (el stub lo necesita para aplicar el --jq)"; exit 1; }

# ------------------------------------------------------------------
# 1. las funciones puras: se importan del modulo y se les pasan los
#    check-runs como dato (sin red).
# ------------------------------------------------------------------
run_py(){ python3 - "$@" <<'PY'
import sys, os, json, tempfile
sys.path.insert(0, os.environ["PIPELINE_DIR"])
import pipeline as P

caso = sys.argv[1]
fails = []

def check(nombre, cond, detalle=""):
    # "PASS <nombre>" / "FAIL <nombre> :: <detalle>": lo cuenta el bash de abajo.
    if cond:
        print(f"PASS {nombre}")
    else:
        print(f"FAIL {nombre} :: {detalle}")
        fails.append(nombre)
def run(nombre, conclusion, completed, rid, status="completed", started=None):
    return {"name": nombre, "status": status, "conclusion": conclusion,
            "completed_at": completed, "started_at": started or completed, "id": rid}

if caso == "ci":
    # (a) un 'cancelled' viejo y un 'success' nuevo del MISMO nombre:
    #     el cancelled es el run que cancelo el nuevo -> VERDE, no un rojo.
    runs = [
        run("Defaults line check", "cancelled", "2026-11-06T15:46:35Z", 127988830749),
        run("Defaults line check", "success",  "2026-11-06T15:46:43Z", 127988860007),
        run("Duplicate PR check",  "success",  "2026-11-06T15:46:51Z", 127988860612),
        run("Picture check",        "skipped",  "2026-11-06T15:46:43Z", 127988860646),
    ]
    estado, detalle = P.evaluar_check_runs(runs)
    check("un cancelled viejo con un success nuevo del mismo nombre es VERDE",
          estado == P.VERDE, f"estado={estado} detalle={detalle}")
    ok_ci, _ = P.check_ci_verde(runs)
    check("check_ci_verde dice True en ese caso", ok_ci is True)

    # el caso real de #11359 / #9843: el cancelado tiene un completed_at POSTERIOR
    # (se cancela tarde) pero el success tiene un id MAYOR (es el run nuevo).
    runs = [
        run("Picture check", "cancelled", "2026-11-06T15:46:45Z", 127988830749),
        run("Picture check", "success",  "2026-11-06T15:46:43Z", 127988860646),
    ]
    estado, detalle = P.evaluar_check_runs(runs)
    check("el cancelled tardio no pisa al success del run nuevo",
          estado == P.VERDE, f"estado={estado} detalle={detalle}")

    # (b) un 'failure' real -> ROJO.
    runs = [
        run("Defaults line check", "failure",   "2026-11-07T10:10:56Z", 128374647675),
        run("Duplicate PR check",  "success",   "2026-11-07T10:13:27Z", 128375136172),
        run("ci",                  "success",   "2026-11-07T10:17:35Z", 128376019085),
    ]
    estado, detalle = P.evaluar_check_runs(runs)
    check("un failure real es ROJO", estado == P.ROJO, f"estado={estado} detalle={detalle}")
    check("el detalle nombra el check que fallo", "Defaults line check" in detalle, detalle)
    ok_ci, _ = P.check_ci_verde(runs)
    check("check_ci_verde dice False con un failure", ok_ci is False)

    # (c) un check todavia en curso (sin conclusion) -> PENDIENTE, ni verde ni rojo.
    runs = [
        run("Defaults line check", None, None, 128375136460, status="in_progress",
            started="2026-11-07T10:13:20Z"),
        run("Duplicate PR check",  "success", "2026-11-07T10:13:27Z", 128375136172),
    ]
    estado, detalle = P.evaluar_check_runs(runs)
    check("un check en curso es PENDIENTE", estado == P.PENDIENTE,
          f"estado={estado} detalle={detalle}")
    check("un check en curso no es verde", estado != P.VERDE)
    check("un check en curso no es rojo", estado != P.ROJO)

    # el mismo caso por el wrapper que habla con GitHub: sin SHA no hay veredicto.
    ok_ci, detalle = P.check_ci_verde_sha("")
    check("sin SHA no se promote (queda pendiente)", ok_ci is False)

elif caso == "defaults":
    # el body real del PR #12574: la forma larga VALIDA. No se pisa.
    body = (
        "Preset numbers for functions\n\n"
        "Fixes #12418\n\n"
        "Changes a default: yes - a new length field in an operation dialog starts with "
        "the size its tool ships with, shown in the design's unit, old behaviour kept "
        "behind preference scaled_length_defaults\n"
    )
    check("la linea 'yes - ... old behaviour kept behind preference X' esta presente",
          P.linea_defaults_presente(body))
    check("la forma larga de #12574 NO es mal formada",
          P.linea_defaults_malformada(body) is False)
    check("un body que habla de defaults se detecta",
          P.habla_de_defaults(body) is True)

    # un 'no' simple: presente y bien formado.
    body_no = "Fixes #1\n\nChanges a default: no\n"
    check("la linea 'no' esta presente", P.linea_defaults_presente(body_no))
    check("la linea 'no' NO es mal formada", P.linea_defaults_malformada(body_no) is False)

    # un 'yes' sin la parte de la preferencia: upstream lo rechaza.
    body_malo = "Fixes #1\n\nChanges a default: yes - cambia el color del fondo\n"
    check("un 'yes' sin 'old behaviour kept behind preference' esta presente",
          P.linea_defaults_presente(body_malo))
    check("un 'yes' sin la preferencia esta MAL FORMADO",
          P.linea_defaults_malformada(body_malo) is True)

    # un body SIN la linea: no se inventa sola (esa es la parte honesta).
    check("un body sin la linea NO la tiene", P.linea_defaults_presente("Fixes #1\n") is False)
    check("un body sin la linea no se marca como mal formada",
          P.linea_defaults_malformada("Fixes #1\n") is False)

    # el resumen de CodeRabbit no es del autor: no cuenta como que el PR hable de defaults.
    body_cr = ("Fixes #1\n\nChanges a default: no\n\n"
               "<!-- This is an auto-generated comment: release notes by coderabbit.ai -->\n\n"
               "## Summary by CodeRabbit\n\n"
               "* The tool's default number is interpreted directly.\n\n"
               "<!-- end of auto-generated comment: release notes by coderabbit.ai -->\n")
    check("el cuerpo del autor no incluye el resumen de CodeRabbit",
          "CodeRabbit" not in P.cuerpo_del_autor(body_cr))
    check("el resumen de CodeRabbit NO hace creer que el PR habla de defaults",
          P.habla_de_defaults(body_cr) is False)

    # un PR que SI habla de defaults (en su propio texto) se detecta igual.
    body_pref = ("Fixes #1\n\nAdds a preference scaled_length_defaults for the new field.\n")
    check("un PR que habla de una preferencia SI se detecta",
          P.habla_de_defaults(body_pref) is True)

    # la linea dentro de un bloque de codigo o de un comentario NO cuenta:
    # upstream la ignora (stripNoise), asi que el pipeline tampoco la da por buena.
    body_falso = "Fixes #1\n\n```\nChanges a default: no\n```\n"
    check("una linea de ejemplo dentro de un bloque de codigo NO cuenta como presente",
          P.linea_defaults_presente(body_falso) is False)

elif caso == "sin-red":
    # la funcion pura no puede tocar la red: con una lista vacia no intenta nada.
    estado, detalle = P.evaluar_check_runs([])
    check("sin check-runs el estado es PENDIENTE", estado == P.PENDIENTE, detalle)
    estado, detalle = P.evaluar_check_runs([{"name": "ci", "status": "completed",
                                             "conclusion": "success",
                                             "completed_at": "2026-11-07T10:17:35Z", "id": 1}])
    check("un solo check en verde es VERDE", estado == P.VERDE, detalle)

elif caso == "sha":
    # EL COMPARADOR DE SHAs (el mismo que bin/gate.sh): el veredicto en disco
    # puede traer el SHA corto (9 chars) y la API el head completo (40).
    check("dos SHAs iguales son el mismo commit",
          P.same_sha("abc123def4567890", "abc123def4567890") is True)
    check("un head de 40 que empieza con uno de 9 es el mismo commit",
          P.same_sha("abc123def" + "0" * 31, "abc123def") is True)
    check("un prefijo de menos de 7 chars NO alcanza",
          P.same_sha("abc1230", "abc123def") is False)
    check("dos SHAs distintos NO son el mismo commit",
          P.same_sha("1" * 40, "2" * 40) is False)
    check("un SHA vacio no es ningun commit",
          P.same_sha("", "abc123def") is False)

    # verdict_for: el veredicto con un SHA de 9 chars se tiene que encontrar
    # con un head de 40 que empieza igual. Con la comparacion exacta nunca
    # se encuentra: el gate se reencola cada 5 minutos y el PR no llega a ready.
    gates = tempfile.mkdtemp(prefix="gates-")
    P.GATES = gates
    slot = os.path.join(gates, "slot-corto")
    os.makedirs(slot, exist_ok=True)
    with open(os.path.join(slot, "scope.verdict"), "w") as fh:
        fh.write("GATE_STATUS=finished\nVERDICT=VERDE-SCOPE\nNEW_FAILURES=0\n"
                 "SHA=abc123def\n")
    v = P.verdict_for("abc123def" + "0" * 31)
    check("el veredicto con SHA de 9 chars se encuentra con un head de 40",
          v is not None, "v=%r" % (v,))
    check("el veredicto encontrado trae su slot",
          bool(v) and v.get("slot") == "slot-corto", "v=%r" % (v,))
    v2 = P.verdict_for("9" * 40)
    check("un veredicto con OTRO sha NO se encuentra", v2 is None, "v=%r" % (v2,))

elif caso == "issue":
    # EL ISSUE DE UN PR: del titulo ('<summary> (#12)') o de un verbo de
    # cierre real en el body ('Fixes #12'). NUNCA de un '#numero' suelto.
    check("'Fixes #12' en el body da el issue",
          P.issue_of("Lo que sea", "Arregla\n\nFixes #12\n") == "12")
    check("'Closes #12' en el body da el issue",
          P.issue_of("Lo que sea", "Closes #12") == "12")
    check("'Resolves #12' en el body da el issue",
          P.issue_of("Lo que sea", "Resolves #12") == "12")
    check("'Addresses #12' se puede seguir (pero no cierra)",
          P.issue_of("Lo que sea", "Addresses #12") == "12")
    check("'Refs #12' se puede seguir (pero no cierra)",
          P.issue_of("Lo que sea", "Refs #12") == "12")
    check("el titulo '(#12)' da el issue",
          P.issue_of("Preset numbers (#12)", "sin referencias") == "12")
    check("un '#3' suelto en el body NO da el issue",
          P.issue_of("Preset numbers", "This fix 3 problems.") is None)
    check("un '#3' dentro de un bloque de codigo NO da el issue",
          P.issue_of("Preset numbers", "```\n#3\n```") is None)
    check("el cierre del body manda sobre el titulo",
          P.issue_of("Preset (#12)", "Fixes #34") == "34")

    # la mencion suelta IMPIDE el arreglo: no se le cierra un issue al autor
    # por sorpresa (la distincion 'cierra' vs 'menciona' de bin/verify-pr.sh).
    check("un body que menciona #12 se detecta como mencion",
          P.menciona_issue("Arregla el crash de #12") is True)
    check("un body sin ningun numero de issue no menciona issues",
          P.menciona_issue("This fix 3 problems.") is False)

    # LA REPARACION: solo cuando el body no menciona NINGUN issue, y con
    # 'Fixes #N' (el contrato del claim), nunca con 'Addresses #N'.
    nuevo = P.reparar_body("Arregla el crash\n\nChanges a default: no\n", "Preset (#12)")
    check("un body sin referencias se repara con 'Fixes #12'",
          bool(nuevo) and "Fixes #12" in nuevo, "nuevo=%r" % (nuevo,))
    check("la reparacion conserva el body original",
          bool(nuevo) and nuevo.startswith("Arregla el crash"), "nuevo=%r" % (nuevo,))
    check("un body que SOLO menciona el issue NO se reescribe",
          P.reparar_body("Arregla el crash de #12\n", "Preset (#12)") is None)
    check("un body que ya cierra NO se reescribe",
          P.reparar_body("Fixes #12\n", "Preset (#12)") is None)
    check("sin issue en el titulo NO hay nada que reparar",
          P.reparar_body("Arregla el crash\n", "Preset numbers") is None)
    check("la reparacion nunca escribe 'Addresses'",
          not (nuevo and "Addresses" in nuevo), "nuevo=%r" % (nuevo,))
    vacio = P.reparar_body("", "Preset (#12)")
    check("un body vacio se repara con solo 'Fixes #12'",
          vacio == "Fixes #12\n", "vacio=%r" % (vacio,))

elif caso == "forkci":
    # EL CI DEL FORK (2026-11-21): evaluar_fork_ci es pura; la regla es la de
    # evaluar_check_runs (de cada nombre de job manda el mas reciente).
    def frun(rid, status, concl, created="2026-11-21T10:00:00Z"):
        return {"id": rid, "status": status, "conclusion": concl, "created_at": created,
                "html_url": "https://x/runs/%d" % rid, "head_sha": "f" * 40}
    def job(rid, nombre, concl, done="2026-11-21T11:00:00Z", status="completed"):
        return {"id": rid, "name": nombre, "status": status, "conclusion": concl,
                "started_at": "2026-11-21T10:01:00Z", "completed_at": done}
    r = P.evaluar_fork_ci([], {})
    check("sin runs el CI del fork es NINGUNO", r["estado"] == P.NINGUNO, r)
    r = P.evaluar_fork_ci([frun(1, "completed", "success")], {})
    check("un solo run terminado en success es VERDE sin leer sus jobs",
          r["estado"] == P.VERDE and r["run"] == "https://x/runs/1", r)
    r = P.evaluar_fork_ci([frun(1, "in_progress", None)],
                          {1: [job(10, "Select checks", "success")]})
    check("un run que sigue corriendo es PENDIENTE aunque sus primeros jobs esten verdes",
          r["estado"] == P.PENDIENTE, r)
    r = P.evaluar_fork_ci([frun(1, "in_progress", None)],
                          {1: [job(10, "Native Linux Clippy", "failure")]})
    check("un run que sigue corriendo con un job ya rojo es ROJO (temprano)",
          r["estado"] == P.ROJO and r["fallan"] == ["Native Linux Clippy"], r)
    r = P.evaluar_fork_ci([frun(1, "completed", "failure")],
                          {1: [job(10, "Native Linux tests", "failure"),
                               job(11, "Doc tests", "success")]})
    check("un run terminado con un job rojo es ROJO y FALLAN nombra el job",
          r["estado"] == P.ROJO and r["fallan"] == ["Native Linux tests"], r)
    r = P.evaluar_fork_ci([frun(1, "completed", "failure", "2026-11-21T10:00:00Z"),
                           frun(2, "completed", "success", "2026-11-21T14:00:00Z")],
                          {1: [job(10, "Native Linux tests", "failure", "2026-11-21T11:00:00Z")],
                           2: [job(20, "Native Linux tests", "success", "2026-11-21T15:00:00Z")]})
    check("de cada nombre manda el job mas reciente entre los runs del sha (el verde nuevo gana)",
          r["estado"] == P.VERDE and r["run"] == "https://x/runs/2", r)
    r = P.evaluar_fork_ci([frun(1, "completed", "failure")],
                          {1: [job(10, "Native Linux tests", "success"),
                               job(11, "Compile RISC-V (manual)", "failure")]})
    check("un rojo de un job que el merge queue no corre (RISC-V) no bloquea",
          r["estado"] == P.VERDE and r["informativos"] == ["Compile RISC-V (manual)"], r)
    r = P.evaluar_fork_ci([frun(1, "completed", "startup_failure")], {1: []})
    check("un run que no arranco (startup_failure, sin jobs) es ROJO",
          r["estado"] == P.ROJO, r)
    r = P.evaluar_fork_ci([frun(1, "completed", "cancelled")],
                          {1: [job(10, "Native Linux tests", "cancelled")]})
    check("un run cancelado no es un veredicto: PENDIENTE y dice como despacharlo de nuevo",
          r["estado"] == P.PENDIENTE and "--force" in r["detalle"], r)
    linea = P.linea_fork_ci({"estado": P.ROJO, "sha": "f" * 40, "run": "https://x/runs/1",
                             "fallan": ["Native Linux tests", "GPU path tests (1/4)"]})
    check("la linea de estado tiene FORKCI, SHA, RUN y FALLAN al final (con comas)",
          linea == "FORKCI=ROJO SHA=%s RUN=https://x/runs/1 "
                   "FALLAN=Native Linux tests,GPU path tests (1/4)" % ("f" * 40), linea)

elif caso == "modo":
    d = tempfile.mkdtemp(prefix="modo-")
    cfg = os.path.join(d, "config.env")
    check("sin entorno y sin config.env el modo es fork-ci",
          P.leer_gate_mode({}, cfg)[0] == "fork-ci")
    with open(cfg, "w") as fh:
        fh.write("OTRA=1\nexport GATE_MODE='local'   # el camino viejo\n")
    check("GATE_MODE=local de config.env (con export, comillas y comentario) se lee",
          P.leer_gate_mode({}, cfg)[0] == "local")
    check("el entorno gana a config.env",
          P.leer_gate_mode({"GATE_MODE": "fork-ci"}, cfg)[0] == "fork-ci")
    modo, origen = P.leer_gate_mode({"GATE_MODE": "rapido"}, cfg)
    check("un modo que no existe no se adivina: fork-ci, y el origen lo dice",
          modo == "fork-ci" and "rapido" in origen, (modo, origen))
    check("un ROJO-SCOPE terminado con NEW_FAILURES=0 NO es un verde local",
          P.gate_local_verde({"verdict": "ROJO-SCOPE", "status": "finished",
                              "new_failures": "0", "slot": "x"}) is False)
    check("un VERDE-SCOPE es un verde local",
          P.gate_local_verde({"verdict": "VERDE-SCOPE", "status": "finished",
                              "new_failures": "0", "slot": "x"}) is True)
    check("sin VERDICT, terminado y con NEW_FAILURES=0 (formato viejo) es verde",
          P.gate_local_verde({"verdict": "", "status": "finished",
                              "new_failures": "0", "slot": "x"}) is True)
    check("sin VERDICT y con NEW_FAILURES vacio NO es verde",
          P.gate_local_verde({"verdict": "", "status": "finished",
                              "new_failures": "", "slot": "x"}) is False)

sys.exit(1 if fails else 0)
PY
}

export PIPELINE_DIR="$HERE"
export ORCH_DIR="$TMP/orch"
export LOOP_DIR="$TMP/loop"
# EL GUARDIA (2026-11-21): el estado de la suite nunca cae en el orquestador vivo.
if [ -f "$HERE/test-guard.sh" ]; then
  # shellcheck disable=SC1091
  source "$HERE/test-guard.sh"
  test_guard_orch_dir "$ORCH_DIR"
fi
unset GATE_MODE FORK_CI_CROSS FORK_CI_MAX_INFLIGHT FORK_CI_CANCEL_STALE FORK_CI_ERROR_BACKOFF_S
export MAX_INFLIGHT=0
mkdir -p "$ORCH_DIR/bin" "$ORCH_DIR/gates" "$LOOP_DIR/gates/slot1" "$LOOP_DIR/gates/slot-corto" \
         "$TMP/checks" "$TMP/comments" "$TMP/prs"

# cuenta los casos que reporta python (PASS / FAIL) con los mismos contadores del bash.
count_py(){
  local out="$1"
  local n
  n=$(printf '%s\n' "$out" | grep -c '^PASS ' || true)
  pass=$((pass+n))
  n=$(printf '%s\n' "$out" | grep -c '^FAIL ' || true)
  fail=$((fail+n))
  printf '%s\n' "$out" | while IFS= read -r linea; do
    case "$linea" in
      "PASS "*) printf 'ok   - %s\n' "${linea#PASS }" ;;
      "FAIL "*) printf 'FALLA- %s\n' "${linea#FAIL }" ;;
    esac
  done
}

echo "# los check-runs del HEAD SHA (no el rollup)"
out=$(run_py ci); rc=$?
count_py "$out"
[ $rc -eq 0 ] || fail=$((fail+1))
echo "# la linea 'Changes a default:'"
out=$(run_py defaults); rc=$?
count_py "$out"
[ $rc -eq 0 ] || fail=$((fail+1))
echo "# la funcion pura no toca la red"
out=$(run_py sin-red); rc=$?
count_py "$out"
[ $rc -eq 0 ] || fail=$((fail+1))
echo "# el veredicto de gate se busca por SHA (prefijo)"
out=$(run_py sha); rc=$?
count_py "$out"
[ $rc -eq 0 ] || fail=$((fail+1))
echo "# el issue sale del titulo o de un verbo de cierre real"
out=$(run_py issue); rc=$?
count_py "$out"
[ $rc -eq 0 ] || fail=$((fail+1))
echo "# el CI del fork: la regla del mas reciente de cada nombre"
out=$(run_py forkci); rc=$?
count_py "$out"
[ $rc -eq 0 ] || fail=$((fail+1))
echo "# el modo del gate y el verde local"
out=$(run_py modo); rc=$?
count_py "$out"
[ $rc -eq 0 ] || fail=$((fail+1))

# ------------------------------------------------------------------
# 2. el pipeline COMPLETO con un gh de mentira.
# ------------------------------------------------------------------
# el veredicto del gate local: VERDE. El CI de GitHub es lo que se prueba aparte.
cat > "$LOOP_DIR/gates/slot1/scope.verdict" <<'EOF'
GATE_STATUS=finished
VERDICT=VERDE-SCOPE
NEW_FAILURES=0
SHA=abc123def4567890
EOF

# el stub de gh: registra lo que se le pide y contesta con lo que hay en $STUB_DIR.
#
# TRES COSAS QUE EL STUB TIENE QUE HACER BIEN (la leccion de bin/test-ci-status.sh):
#   1. aplicar el --jq DE VERDAD (con jq real): un stub que lo ignora mide el
#      stub, no la regla;
#   2. dejar que 'pr ready' FALLE, para probar que el pipeline lo loguea y
#      devuelva un rc distinto de cero;
#   3. guardar los comentarios que se postean, para que la corrida siguiente
#      vea el marcador del veredicto (la idempotencia por marcador).
cat > "$TMP/gh-stub" <<'STUB'
#!/usr/bin/env python3
"""El stub de gh de este test.

APLICA el --jq de verdad (con jq real), puede fallar ('pr ready', 'pr edit',
la lista de PRs) y guarda los comentarios que se postean, para que la corrida
siguiente vea el marcador del veredicto.
"""
import json
import os
import subprocess
import sys
import urllib.parse

D = os.environ.get("STUB_DIR", ".")
ARGS = sys.argv[1:]
CALLS = os.path.join(D, "calls.log")


def die(msg, rc=1):
    sys.stderr.write("gh: %s\n" % msg)
    sys.exit(rc)


def log(line):
    with open(CALLS, "a") as fh:
        fh.write(line + "\n")


def valor(flag, default=None):
    if flag in ARGS:
        i = ARGS.index(flag)
        if i + 1 < len(ARGS):
            return ARGS[i + 1]
    return default


def jq(texto, filtro):
    """El filtro --jq aplicado DE VERDAD (con jq real)."""
    if not filtro:
        return texto
    r = subprocess.run(["jq", "-c", filtro], input=texto, capture_output=True, text=True)
    if r.returncode != 0:
        die("jq fallo: %s" % (r.stderr or "").strip())
    return r.stdout


def api_path():
    """El path de la API: el primer argumento que no es un flag ni el valor de un flag."""
    con_valor = {"-X", "--method", "-f", "--field", "-F", "--raw-field", "--jq"}
    skip = set()
    for i, a in enumerate(ARGS[1:]):
        if a in con_valor:
            skip.add(i + 1)
    for i, a in enumerate(ARGS[1:]):
        if i in skip or a.startswith("-"):
            continue
        return a.split("?")[0]
    return ""


def api_query():
    """La query de la ruta de la API (lo que va despues del '?')."""
    for a in ARGS[1:]:
        if not a.startswith("-") and "?" in a:
            return a.split("?", 1)[1]
    return ""


def leer_json(f, default):
    try:
        return json.load(open(f))
    except Exception:
        return default


def fork_runs():
    return leer_json(os.path.join(D, "forkci", "runs.json"), [])


def guardar_runs(runs):
    os.makedirs(os.path.join(D, "forkci"), exist_ok=True)
    json.dump(runs, open(os.path.join(D, "forkci", "runs.json"), "w"))


def servir_api(path):
    """(texto, rc, stderr) de la respuesta de la API para ese path."""
    if path.endswith("/check-runs"):
        sha = path.split("/commits/")[1].split("/")[0]
        f = os.path.join(D, "checks", "%s.jsonl" % sha)
        if not os.path.isfile(f):
            return "", 0, ""
        # A switch to make the check-runs UNREADABLE: the API answers with
        # something that is not the JSON it owes.
        if os.path.isfile(os.path.join(D, "checks-fail")):
            return "", 1, "gh: the API could not be read"
        lineas = [l for l in open(f).read().splitlines() if l.strip()]
        crudo = json.dumps({"total_count": len(lineas),
                             "check_runs": [json.loads(l) for l in lineas]})
    elif "/issues/" in path and path.endswith("/comments"):
        num = path.split("/issues/")[1].split("/")[0]
        if os.path.isfile(os.path.join(D, "comments-fail")):
            return "", 1, "gh: could not list comments: HTTP 502"
        f = os.path.join(D, "comments", "%s.json" % num)
        crudo = open(f).read() if os.path.isfile(f) else "[]"
    elif "/actions/workflows/" in path and path.endswith("/runs"):
        # EL CI DEL FORK (2026-11-21): los runs de ci.yml. El filtro head_sha
        # de la API se aplica DE VERDAD (un stub que lo ignora mide el stub).
        if os.path.isfile(os.path.join(D, "forkci-fail")):
            return "", 1, "gh: HTTP 502: Server Error"
        runs = fork_runs()
        q = urllib.parse.parse_qs(QUERY)
        if q.get("head_sha"):
            runs = [r for r in runs if r.get("head_sha") == q["head_sha"][0]]
        if q.get("event"):
            runs = [r for r in runs if r.get("event", "workflow_dispatch") == q["event"][0]]
        crudo = json.dumps({"total_count": len(runs), "workflow_runs": runs})
    elif "/actions/runs/" in path and path.endswith("/jobs"):
        rid = path.split("/actions/runs/")[1].split("/")[0]
        log("JOBS:%s" % rid)
        f = os.path.join(D, "forkci", "jobs-%s.json" % rid)
        jobs = json.load(open(f)) if os.path.isfile(f) else []
        crudo = json.dumps({"total_count": len(jobs), "jobs": jobs})
    elif "/actions/runs/" in path and path.endswith("/cancel"):
        rid = path.split("/actions/runs/")[1].split("/")[0]
        log("CANCEL:%s" % rid)
        runs = fork_runs()
        for r in runs:
            if str(r.get("id")) == rid:
                r["status"], r["conclusion"] = "completed", "cancelled"
        guardar_runs(runs)
        crudo = "{}"
    elif "/git/ref/heads/" in path:
        rama = path.split("/git/ref/heads/", 1)[1]
        heads = leer_json(os.path.join(D, "forkci", "heads.json"), {})
        if rama not in heads:
            return "", 1, "gh: Not Found (HTTP 404)"
        crudo = json.dumps({"ref": "refs/heads/" + rama, "object": {"sha": heads[rama]}})
    elif path.endswith("/pulls"):
        if os.path.isfile(os.path.join(D, "pulls-fail")):
            return "", 1, "gh: could not list pull requests: HTTP 401: Bad credentials"
        f = os.path.join(D, "pulls-garbage.json")
        if not os.path.isfile(f):
            f = os.path.join(D, "pulls.json")
        crudo = open(f).read() if os.path.isfile(f) else "[]"
    else:
        die("unknown api path: %s" % path)
    if "--slurp" in ARGS:
        # 'gh api --paginate --slurp' devuelve un ARRAY DE ARRAYS (una pagina por elemento)
        try:
            crudo = json.dumps([json.loads(crudo)])
        except ValueError:
            pass  # basura: se entrega tal cual (el pipeline tiene que avisar)
    return jq(crudo, valor("--jq")), 0, ""


if ARGS[:2] == ["workflow", "run"]:
    # El despacho de ci.yml en el fork. Como GitHub: el run aparece en la
    # lista (salvo con 'dispatch-no-run': la API tarda en listarlo).
    rama = valor("--ref", "")
    log("DISPATCH:%s %s" % (rama, " ".join(ARGS[2:])))
    if os.path.isfile(os.path.join(D, "dispatch-fail")):
        sys.stderr.write("could not create workflow dispatch event: HTTP 422: Actions has "
                         "been disabled for this repository.\n")
        sys.exit(1)
    if not os.path.isfile(os.path.join(D, "dispatch-no-run")):
        heads = leer_json(os.path.join(D, "forkci", "heads.json"), {})
        runs = fork_runs()
        rid = 7000 + len(runs) + 1
        runs.append({"id": rid, "status": "queued", "conclusion": None,
                     "html_url": "https://github.com/vdirienzo/solidcraft/actions/runs/%d" % rid,
                     "head_sha": heads.get(rama, ""), "head_branch": rama,
                     "event": "workflow_dispatch", "created_at": "2026-11-21T23:00:00Z",
                     "updated_at": "2026-11-21T23:00:00Z", "run_attempt": 1})
        guardar_runs(runs)
    print("Created workflow_dispatch event for ci.yml at %s" % rama)
    sys.exit(0)

if ARGS[:1] == ["api"]:
    QUERY = api_query()
    path = api_path()
    texto, rc, err = servir_api(path)
    if rc != 0:
        sys.stderr.write(err + "\n")
        sys.exit(rc)
    sys.stdout.write(texto)
    sys.exit(0)

if ARGS[:2] == ["pr", "list"]:
    f = os.path.join(D, "pulls.json")
    # The switch for a 'gh' that CANNOT read the list: a cron that answers
    # "there are no pull requests" when GitHub is down is the silence this
    # whole suite is about.
    if os.path.isfile(os.path.join(D, "pulls-fail")):
        sys.stderr.write("gh: Bad credentials (HTTP 401)\n")
        sys.exit(1)
    # The switch for a list that is not JSON: the tool answered, but what
    # it answered is not a list.
    if os.path.isfile(os.path.join(D, "pulls-garbage.json")):
        sys.stdout.write(open(os.path.join(D, "pulls-garbage.json")).read())
        sys.exit(0)
    crudo = open(f).read() if os.path.isfile(f) else "[]"
    # un gh de verdad recorta la lista al --limit: un stub que lo ignora
    # mediria el stub, no la regla (la lista truncada es justamente el bug).
    limite = valor("--limit")
    if limite:
        try:
            datos = json.loads(crudo)
            if isinstance(datos, list):
                crudo = json.dumps(datos[:int(limite)])
        except ValueError:
            pass
    sys.stdout.write(jq(crudo, valor("--jq")))
    sys.exit(0)

if ARGS[:2] == ["pr", "view"]:
    num = ARGS[2]
    f = os.path.join(D, "prs", "%s.json" % num)
    crudo = open(f).read() if os.path.isfile(f) else '{"headRefOid": ""}'
    sys.stdout.write(jq(crudo, valor("--jq")))
    sys.exit(0)

if ARGS[:2] == ["pr", "edit"]:
    num = ARGS[2]
    log("EDIT:%s" % num)
    log("EDIT-BODY<<<%s>>>" % " ".join(ARGS))
    if os.path.isfile(os.path.join(D, "edit-fail")):
        sys.stderr.write("gh: could not edit pull request: HTTP 422\n")
        sys.exit(1)
    print("https://github.com/tangency-labs/solidcraft/pull/%s" % num)
    sys.exit(0)

if ARGS[:2] == ["pr", "ready"]:
    num = ARGS[2]
    log("READY:%s" % num)
    ff = os.path.join(D, "ready-fail")
    if os.path.isfile(ff):
        if num in open(ff).read().split():
            sys.stderr.write("gh: could not mark pull request as ready: HTTP 403\n")
            sys.exit(1)
    sys.exit(0)

if ARGS[:2] == ["pr", "comment"]:
    num = ARGS[2]
    body = valor("--body", "")
    log("COMMENT:%s" % num)
    log("COMMENT-BODY<<<%s>>>" % body)
    # el comentario queda en el PR: la corrida siguiente lo tiene que ver
    f = os.path.join(D, "comments", "%s.json" % num)
    try:
        datos = json.load(open(f))
    except Exception:
        datos = []
    datos.append({"user": {"login": "vdirienzo"}, "body": body})
    with open(f, "w") as fh:
        json.dump(datos, fh)
    sys.exit(0)

sys.exit(0)
STUB
chmod +x "$TMP/gh-stub"

export STUB_DIR="$TMP"
export GH_BIN="$TMP/gh-stub"

# los check-runs por SHA: uno verde (el del run nuevo) y uno con el cancelled del viejo.
cat > "$TMP/checks/abc123def4567890.jsonl" <<'EOF'
{"name":"Defaults line check","status":"completed","conclusion":"cancelled","completed_at":"2026-11-06T15:46:35Z","started_at":"2026-11-06T15:46:30Z","id":111}
{"name":"Defaults line check","status":"completed","conclusion":"success","completed_at":"2026-11-06T15:46:43Z","started_at":"2026-11-06T15:46:38Z","id":222}
{"name":"Duplicate PR check","status":"completed","conclusion":"success","completed_at":"2026-11-06T15:46:51Z","started_at":"2026-11-06T15:46:40Z","id":223}
EOF

# la lista de PRs (la forma de la API: 'gh api repos/.../pulls'):
# cada linea: numero|titulo|draft(0/1)|sha|body|labels(json)
# el spec va por el fd 3: la entrada (stdin) es el heredoc del llamador.
set_pulls(){ python3 - "$TMP/pulls.json" 3<&0 <<'PY'
import json, os, sys
spec = os.fdopen(3, "r").read()
salida = []
for linea in spec.splitlines():
    if not linea.strip():
        continue
    num, titulo, draft, sha, body, labels = linea.split("|", 5)
    salida.append({"number": int(num), "title": titulo, "draft": draft == "1",
                   "user": {"login": "vdirienzo"},
                   "head": {"ref": "feat/x", "sha": sha},
                   "labels": json.loads(labels), "body": body.replace("\\n", "\n")})
json.dump(salida, open(sys.argv[1], "w"))
PY
}

run_pipeline(){ python3 "$PIPELINE" > "$TMP/out.log" 2>&1; return $?; }

# --- caso A: el PR tiene la forma larga valida -------------------------------
set_pulls <<'EOF'
12574|Preset numbers|1|abc123def4567890|Preset numbers for functions\n\nFixes #12418\n\nChanges a default: yes - a new length field in an operation dialog starts with the size its tool ships with, shown in the design's unit, old behaviour kept behind preference scaled_length_defaults\n|[]
EOF
: > "$TMP/calls.log"
run_pipeline
if grep -q "Changes to default: no" "$TMP/calls.log" || grep -q "Changes a default: no" "$TMP/calls.log"; then
  no "un 'yes' valido NO se pisa con un 'no'"
else
  ok "un 'yes' valido NO se pisa con un 'no'"
fi
if grep -q "^READY:12574" "$TMP/calls.log"; then
  ok "un PR con el CI verde y el gate verde pasa a ready"
else
  no "un PR con el CI verde y el gate verde pasa a ready" "$(cat "$TMP/calls.log")"
fi

# --- caso: los check-runs NO se pueden leer -> UNKNOWN (6), no un fallo ----
# La diferencia importa: un fallo de GitHub que dura mas de una pasada
# dejaba el cron rojo cada cinco minutos, sin forma de distinguirlo de un
# problema de verdad. El repositorio tiene un codigo para "no se sabe": el 6.
set_pulls <<'EOF'
12574|Preset numbers|1|abc123def4567890|Preset numbers for functions\n\nFixes #12418\n\nChanges a default: no\n|[]
EOF
: > "$TMP/checks-fail"
: > "$TMP/calls.log"
run_pipeline
rc=$?
if [ "$rc" -eq 6 ]; then
  ok "los check-runs que no se pueden leer dan UNKNOWN (rc=6), no un fallo"
else
  no "los check-runs que no se pueden leer dan UNKNOWN (rc=6), no un fallo" "rc=$rc"
fi
if grep -q "desconocidos" "$TMP/out.log"; then
  ok "el log dice que no se pudo leer"
else
  no "el log dice que no se pudo leer" "$(tail -3 "$TMP/out.log")"
fi
rm -f "$TMP/checks-fail"

# --- caso B: el PR NO tiene la linea de defaults ----------------------------
set_pulls <<'EOF'
13000|Sin la linea|1|abc123def4567890|Arregla un crash en la salida\n\nFixes #12842\n|[]
EOF
: > "$TMP/calls.log"
run_pipeline
if grep -q "Changes a default:" "$TMP/calls.log"; then
  no "un body SIN la linea NO recibe un 'no' automatico"
else
  ok "un body SIN la linea NO recibe un 'no' automatico"
fi
if grep -q "^READY:13000" "$TMP/calls.log"; then
  no "un PR sin la linea de defaults NO se promueve (queda en draft)"
else
  ok "un PR sin la linea de defaults NO se promueve (queda en draft)"
fi
if grep -q "NO la invento" "$TMP/out.log"; then
  ok "el log dice que la linea la tiene que escribir el autor"
else
  no "el log dice que la linea la tiene que escribir el autor" "$(cat "$TMP/out.log")"
fi

# --- caso C: el CI de GitHub esta en ROJO -----------------------------------
cat > "$TMP/checks/abc123def4567890.jsonl" <<'EOF'
{"name":"Defaults line check","status":"completed","conclusion":"failure","completed_at":"2026-11-07T10:10:56Z","started_at":"2026-11-07T10:10:50Z","id":111}
{"name":"Duplicate PR check","status":"completed","conclusion":"success","completed_at":"2026-11-07T10:13:27Z","started_at":"2026-11-07T10:13:20Z","id":223}
EOF
set_pulls <<'EOF'
12574|Preset numbers|1|abc123def4567890|Preset numbers for functions\n\nFixes #12418\n\nChanges a default: no\n|[]
EOF
: > "$TMP/calls.log"
run_pipeline
if grep -q "^READY:12574" "$TMP/calls.log"; then
  no "un PR con el CI de GitHub en ROJO NO se promueve"
else
  ok "un PR con el CI de GitHub en ROJO NO se promueve"
fi
if grep -q "CI de GitHub esta ROJO" "$TMP/out.log"; then
  ok "el log dice que el CI de GitHub esta en rojo"
else
  no "el log dice que el CI de GitHub esta en rojo" "$(cat "$TMP/out.log")"
fi

# --- caso D: el CI todavia esta corriendo -----------------------------------
cat > "$TMP/checks/abc123def4567890.jsonl" <<'EOF'
{"name":"Defaults line check","status":"in_progress","conclusion":null,"completed_at":null,"started_at":"2026-11-07T10:13:20Z","id":333}
{"name":"Duplicate PR check","status":"completed","conclusion":"success","completed_at":"2026-11-07T10:13:27Z","started_at":"2026-11-07T10:13:20Z","id":223}
EOF
set_pulls <<'EOF'
12574|Preset numbers|1|abc123def4567890|Preset numbers for functions\n\nFixes #12418\n\nChanges a default: no\n|[]
EOF
: > "$TMP/calls.log"
run_pipeline
if grep -q "^READY:12574" "$TMP/calls.log"; then
  no "un PR con el CI corriendo NO se promueve"
else
  ok "un PR con el CI corriendo NO se promueve"
fi
if grep -q "CI pendiente" "$TMP/out.log"; then
  ok "el log dice 'CI pendiente'"
else
  no "el log dice 'CI pendiente'" "$(cat "$TMP/out.log")"
fi

# --- caso E: el resumen con cuantos PRs tienen el CI verde ------------------
cat > "$TMP/checks/abc123def4567890.jsonl" <<'EOF'
{"name":"Defaults line check","status":"completed","conclusion":"success","completed_at":"2026-11-06T15:46:43Z","started_at":"2026-11-06T15:46:38Z","id":222}
EOF
set_pulls <<'EOF'
12574|Verde|1|abc123def4567890|Arregla\n\nFixes #12418\n\nChanges a default: no\n|[]
13001|Tambien verde|0|abc123def4567890|Arregla\n\nFixes #12419\n|[]
EOF
: > "$TMP/calls.log"
run_pipeline
if grep -qE "CI de GitHub \(HEAD SHA\): 2 verde\(s\), 0 pendiente\(s\), 0 rojo\(s\)" "$TMP/out.log"; then
  ok "el resumen dice cuantos PRs tienen el CI verde, pendiente y rojo"
else
  no "el resumen dice cuantos PRs tienen el CI verde, pendiente y rojo" "$(cat "$TMP/out.log")"
fi

# --- caso F: el body se acaba de editar -> el CI vuelve a correr ------------
# El pipeline le agrega 'Fixes #N': eso dispara el workflow pr-checks (types: edited).
# Promover en la misma pasada dejaria un check rojo en pantalla: el PR espera.
set_pulls <<'EOF'
12574|Sin referencia al issue|1|abc123def4567890|Arregla el crash\n\nChanges a default: no\n|[]
EOF
: > "$TMP/calls.log"
run_pipeline
if grep -q "^READY:12574" "$TMP/calls.log"; then
  no "un PR cuyo body se acaba de editar NO se promueve en la misma pasada"
else
  ok "un PR cuyo body se acaba de editar NO se promueve en la misma pasada"
fi

# --- caso G: la linea de defaults esta mal formada --------------------------
set_pulls <<'EOF'
12574|Linea mal formada|1|abc123def4567890|Arregla\n\nFixes #12418\n\nChanges a default: yes - cambia el color\n|[]
EOF
: > "$TMP/calls.log"
run_pipeline
if grep -q "^READY:12574" "$TMP/calls.log"; then
  no "un PR con la linea de defaults mal formada NO se promueve"
else
  ok "un PR con la linea de defaults mal formada NO se promueve"
fi
if grep -q "MAL FORMADA" "$TMP/out.log"; then
  ok "el log avisa que la linea de defaults esta mal formada"
else
  no "el log avisa que la linea de defaults esta mal formada" "$(cat "$TMP/out.log")"
fi

# --- caso H: la etiqueta 'changes-default' ----------------------------------
set_pulls <<'EOF'
12574|Sin la linea, con etiqueta|1|abc123def4567890|Arregla\n\nFixes #12418\n|[{"name":"changes-default"}]
EOF
: > "$TMP/calls.log"
run_pipeline
if grep -q "Changes a default:" "$TMP/calls.log"; then
  no "con la etiqueta 'changes-default' NO se escribe un 'no' automatico"
else
  ok "con la etiqueta 'changes-default' NO se escribe un 'no' automatico"
fi
if grep -q "changes-default" "$TMP/out.log"; then
  ok "el log dice que el PR tiene la etiqueta 'changes-default'"
else
  no "el log dice que el PR tiene la etiqueta 'changes-default'" "$(cat "$TMP/out.log")"
fi

# ==================================================================
# LOS SILENCIOS DEL CRON (2026-11-17)
# ==================================================================

# --- I: la lista de PRs no se puede leer -> rc distinto de cero ------------
echo "== la lista de PRs no se puede leer: el cron NO sale verde =="
set_pulls <<'EOF'
12574|Preset numbers|1|abc123def4567890|Arregla\n\nFixes #12418\n\nChanges a default: no\n|[]
EOF
: > "$TMP/pulls-fail"
: > "$TMP/calls.log"
run_pipeline; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "un 'gh' que falla al listar los PRs sale con rc distinto de cero (rc=$rc)"
else
  no "un 'gh' que falla al listar los PRs sale con rc distinto de cero" "rc=$rc"
fi
if grep -q "rc=1" "$TMP/out.log" && grep -q "Bad credentials" "$TMP/out.log"; then
  ok "el log dice QUE fallo: el comando, su rc y el stderr"
else
  no "el log dice QUE fallo: el comando, su rc y el stderr" "$(cat "$TMP/out.log")"
fi
if grep -q "no pude leer la lista de PRs" "$TMP/out.log"; then
  ok "el log dice que no pudo leer la lista de PRs"
else
  no "el log dice que no pudo leer la lista de PRs" "$(cat "$TMP/out.log")"
fi
rm -f "$TMP/pulls-fail"

# --- J: la lista de PRs es basura que no es JSON -> rc distinto de cero ----
echo "== la lista de PRs es basura: rc distinto de cero =="
printf 'esto no es JSON\n' > "$TMP/pulls-garbage.json"
: > "$TMP/calls.log"
run_pipeline; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "una lista de PRs que no es JSON sale con rc distinto de cero (rc=$rc)"
else
  no "una lista de PRs que no es JSON sale con rc distinto de cero" "rc=$rc"
fi
if grep -qi "no es JSON" "$TMP/out.log"; then
  ok "el log dice que la respuesta no es JSON"
else
  no "el log dice que la respuesta no es JSON" "$(cat "$TMP/out.log")"
fi
rm -f "$TMP/pulls-garbage.json"

# --- K: el veredicto con el SHA corto se encuentra con el head largo ------
echo "== el veredicto con SHA de 9 chars se encuentra con el head de 40 =="
SHALTO="abc123def$(python3 -c 'print("0"*31)')"
cat > "$LOOP_DIR/gates/slot-corto/scope.verdict" <<EOF
GATE_STATUS=finished
VERDICT=VERDE-SCOPE
NEW_FAILURES=0
SHA=abc123def
EOF
cat > "$TMP/checks/$SHALTO.jsonl" <<'EOF'
{"name":"Defaults line check","status":"completed","conclusion":"success","completed_at":"2026-11-06T15:46:43Z","started_at":"2026-11-06T15:46:38Z","id":222}
EOF
set_pulls <<EOF
14000|Preset numbers|1|$SHALTO|Arregla\n\nFixes #12418\n\nChanges a default: no\n|[]
EOF
: > "$TMP/calls.log"
run_pipeline
if grep -q "^READY:14000" "$TMP/calls.log"; then
  ok "un veredicto con SHA de 9 chars se encuentra con el head de 40 (el PR llega a ready)"
else
  no "un veredicto con SHA de 9 chars se encuentra con el head de 40" "$(cat "$TMP/out.log")"
fi

# --- L: un veredicto de OTRO sha no se encuentra ----------------------------
echo "== un veredicto de otro SHA no se encuentra =="
SHAOTRO="$(python3 -c 'print("9"*40)')"
cat > "$TMP/checks/$SHAOTRO.jsonl" <<'EOF'
{"name":"Defaults line check","status":"completed","conclusion":"success","completed_at":"2026-11-06T15:46:43Z","started_at":"2026-11-06T15:46:38Z","id":222}
EOF
set_pulls <<EOF
14001|Otro PR|1|$SHAOTRO|Arregla\n\nFixes #12418\n\nChanges a default: no\n|[]
EOF
: > "$TMP/calls.log"
run_pipeline
if grep -q "^READY:14001" "$TMP/calls.log"; then
  no "un veredicto de OTRO sha NO se toma como el de este PR"
else
  ok "un veredicto de OTRO sha NO se toma como el de este PR"
fi

# --- M: 'gh pr ready' falla -> se loguea, rc!=0 y NO se comenta -------------
echo "== 'gh pr ready' falla: se loguea y no se postea el comentario =="
echo "14002" > "$TMP/ready-fail"
cat > "$TMP/checks/abc123def4567890.jsonl" <<'EOF'
{"name":"Defaults line check","status":"completed","conclusion":"success","completed_at":"2026-11-06T15:46:43Z","started_at":"2026-11-06T15:46:38Z","id":222}
EOF
set_pulls <<'EOF'
14002|Preset numbers|1|abc123def4567890|Arregla\n\nFixes #12418\n\nChanges a default: no\n|[]
EOF
: > "$TMP/calls.log"
run_pipeline; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "un 'gh pr ready' que falla sale con rc distinto de cero (rc=$rc)"
else
  no "un 'gh pr ready' que falla sale con rc distinto de cero" "rc=$rc"
fi
if grep -q "pr ready" "$TMP/out.log" && grep -q "rc=1" "$TMP/out.log"; then
  ok "el log dice que fallo 'gh pr ready' (con su rc)"
else
  no "el log dice que fallo 'gh pr ready' (con su rc)" "$(cat "$TMP/out.log")"
fi
if grep -q "^COMMENT:14002" "$TMP/calls.log"; then
  no "un 'gh pr ready' que falla NO deja comentario del veredicto"
else
  ok "un 'gh pr ready' que falla NO deja comentario del veredicto"
fi
rm -f "$TMP/ready-fail"

# --- N: el pipeline NO deja comentarios de estado (2026-11-21) -------------
# La guia de upstream (.agents/skills/solidcraft-babysit-pr/SKILL.md) dice "No
# status comments": pasar a ready no deja comentario. Y el titulo del claim
# "<resumen> (#N)" pierde el numero al pasar a ready (solidcraft-file-pr).
echo "== pasar a ready no deja comentario y le saca el numero al titulo =="
set_pulls <<'EOF2'
14003|Preset numbers (#12418)|1|abc123def4567890|Arregla\n\nFixes #12418\n\nChanges a default: no\n|[]
EOF2
rm -f "$TMP/comments/14003.json"
: > "$TMP/calls.log"
run_pipeline
run_pipeline
n=$(grep -c "^COMMENT:14003" "$TMP/calls.log" || true)
if [ "$n" -eq 0 ]; then
  ok "dos corridas del pipeline NO postean ningun comentario de estado"
else
  no "dos corridas del pipeline NO postean ningun comentario de estado" "comentarios=$n"
fi
if grep -q "^READY:14003" "$TMP/calls.log"; then
  ok "el PR verde pasa a ready igual (sin comentario)"
else
  no "el PR verde pasa a ready igual (sin comentario)" "$(cat "$TMP/calls.log")"
fi
if grep -q "titulo sin el numero del issue" "$TMP/out.log"; then
  ok "al pasar a ready, el titulo pierde el ' (#N)' del claim"
else
  no "al pasar a ready, el titulo pierde el ' (#N)' del claim" "$(cat "$TMP/out.log")"
fi

# --- O: la lista de PRs no esta truncada a 30 ------------------------------
echo "== la lista de PRs no esta truncada a 30 =="
python3 - "$TMP/pulls.json" <<'PY'
import json, sys
salida = []
for n in range(1, 32):
    salida.append({"number": 15000 + n, "title": "PR %d" % n, "draft": False,
                   "user": {"login": "vdirienzo"},
                   "head": {"ref": "feat/x", "sha": "%040d" % n},
                   "labels": [], "body": "Arregla\n\nFixes #%d\n" % (1000 + n)})
json.dump(salida, open(sys.argv[1], "w"))
PY
: > "$TMP/calls.log"
run_pipeline
if grep -q "PRs nuestros abiertos: 31" "$TMP/out.log"; then
  ok "el pipeline ve los 31 PRs (no solo 30)"
else
  no "el pipeline ve los 31 PRs (no solo 30)" "$(cat "$TMP/out.log")"
fi

# --- P: un numero suelto en el body NO es el issue -------------------------
echo "== un '#numero' suelto en el body NO es el issue =="
set_pulls <<'EOF'
14004|Arregla tres cosas|1|abc123def4567890|This fix 3 problems.\n\nChanges a default: no\n|[]
EOF
: > "$TMP/calls.log"
run_pipeline
if grep -qE "Fixes #3([^0-9]|$)" "$TMP/calls.log"; then
  no "un '3' de prosa NO se escribe como 'Fixes #3'"
else
  ok "un '3' de prosa NO se escribe como 'Fixes #3'"
fi
if grep -qE "Addresses #3([^0-9]|$)" "$TMP/calls.log"; then
  no "un '3' de prosa NO se escribe como 'Addresses #3'"
else
  ok "un '3' de prosa NO se escribe como 'Addresses #3'"
fi
if grep -q "no se sabe que issue es" "$TMP/out.log"; then
  ok "sin issue en el titulo ni verbo de cierre, el pipeline dice que no lo sabe"
else
  no "sin issue en el titulo ni verbo de cierre, el pipeline dice que no lo sabe" "$(cat "$TMP/out.log")"
fi

# --- Q: un body sin referencias se repara con 'Fixes #N' -------------------
echo "== un body sin referencias se repara con 'Fixes #N' =="
set_pulls <<'EOF'
14005|Preset numbers (#123)|1|abc123def4567890|This fix 3 problems.\n\nChanges a default: no\n|[]
EOF
: > "$TMP/calls.log"
run_pipeline
# El pipeline YA NO edita el body (2026-11-21): lo dice y deja el PR en draft.
if grep -qE "Fixes #123([^0-9]|$)" "$TMP/calls.log"; then
  no "un body sin referencias NO se edita desde el pipeline" "$(cat "$TMP/calls.log")"
else
  ok "un body sin referencias NO se edita desde el pipeline"
fi
if grep -q "falta 'Fixes #123'" "$TMP/out.log"; then
  ok "el log dice que al body le falta 'Fixes #123' (el issue del titulo)"
else
  no "el log dice que al body le falta 'Fixes #123'" "$(cat "$TMP/out.log")"
fi
if grep -qE "Fixes #3([^0-9]|$)" "$TMP/calls.log"; then
  no "el numero de la prosa NO gana al issue del titulo"
else
  ok "el numero de la prosa NO gana al issue del titulo"
fi
if grep -qE "Addresses #" "$TMP/calls.log"; then
  no "la reparacion NO usa 'Addresses' (el contrato del claim es 'Fixes')"
else
  ok "la reparacion NO usa 'Addresses' (el contrato del claim es 'Fixes')"
fi

# --- R: un slot SIN worktree no se encola (el gate no puede correr) ------
# El 20-11-2026 el PR #19492 (un draft cuyo slot esta cerrado) hacia que el
# pipeline reencolara su gate cada cinco minutos y el cron de la cola lo
# sacara cada tres: el cron solidcraft-gate-queue fallo 108 veces con una
# condicion que no iba a cambiar. Un slot sin worktree no se encola.
echo "== un slot sin worktree no se encola: el gate no puede correr =="
# El caso es del modo LOCAL (bin/gate.sh): en modo fork-ci no se encola nada.
export GATE_MODE=local
export MAX_INFLIGHT=5
export WORKTREES_DIR="$TMP/wt"
mkdir -p "$WORKTREES_DIR" "$ORCH_DIR/bin"
cp "$HERE/gate-queue.sh" "$ORCH_DIR/bin/gate-queue.sh"
SHASIN="aaaa1111bbbb2222cccc3333dddd4444eeee5555"
set_pulls <<EOF
14007|Sin worktree|1|$SHASIN|Arregla\n\nFixes #12418\n\nChanges a default: no\n|[]
EOF
rm -f "$ORCH_DIR/gates/queue.txt"
: > "$TMP/calls.log"
run_pipeline
if [ -s "$ORCH_DIR/gates/queue.txt" ]; then
  no "un PR cuyo slot NO tiene worktree NO se encola" "$(cat "$ORCH_DIR/gates/queue.txt")"
else
  ok "un PR cuyo slot NO tiene worktree NO se encola"
fi
if grep -q "no tiene worktree" "$TMP/out.log"; then
  ok "el log dice que el slot no tiene worktree"
else
  no "el log dice que el slot no tiene worktree" "$(tail -3 "$TMP/out.log")"
fi
# CON el worktree del slot, el gate se encola (el caso normal).
mkdir -p "$WORKTREES_DIR/issue-12418"
rm -f "$ORCH_DIR/gates/queue.txt"
: > "$TMP/calls.log"
run_pipeline
if grep -q "^12418 " "$ORCH_DIR/gates/queue.txt" 2>/dev/null; then
  ok "con el worktree del slot, el gate se encola"
else
  no "con el worktree del slot, el gate se encola" "$(tail -3 "$TMP/out.log")"
fi
rm -rf "$WORKTREES_DIR"
export MAX_INFLIGHT=0
unset GATE_MODE

# ==================================================================
# EL GATE ES EL CI DEL FORK (2026-11-21)
#
# El modo por defecto (sin GATE_MODE y sin config.env): un draft sin veredicto
# local se gatea con ci.yml despachado en el fork sobre su head. UNA vez por
# sha, nunca a ciegas, con un tope de runs en vuelo, sin despachar mientras el
# agente trabaja, y un PR que ya esta listo no se toca.
# ==================================================================
echo "== el gate es el CI del fork =="
unset GATE_MODE
export WORKTREES_DIR="$TMP/wt-fork"
mkdir -p "$WORKTREES_DIR"
SHAF="f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0"
SHAV="e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1"
cat > "$TMP/checks/$SHAF.jsonl" <<'EOF'
{"name":"Defaults line check","status":"completed","conclusion":"success","completed_at":"2026-11-21T15:46:43Z","started_at":"2026-11-21T15:46:38Z","id":222}
EOF
fork_reset(){
  rm -rf "$TMP/forkci" "$ORCH_DIR/gates/fork-ci"
  rm -f "$TMP/dispatch-fail" "$TMP/dispatch-no-run" "$TMP/forkci-fail"
  mkdir -p "$TMP/forkci"
  printf '{"feat/x": "%s"}\n' "${1:-$SHAF}" > "$TMP/forkci/heads.json"
  echo '[]' > "$TMP/forkci/runs.json"
  : > "$TMP/calls.log"
}
# Los runs del fork: una linea por run, id|status|conclusion|head_sha|rama|created_at
fork_set_runs(){ python3 - "$TMP/forkci/runs.json" 3<&0 <<'PY'
import json, os, sys
runs = []
for linea in os.fdopen(3).read().splitlines():
    if not linea.strip():
        continue
    rid, status, concl, sha, rama, created = linea.split("|")
    runs.append({"id": int(rid), "status": status, "conclusion": concl or None,
                 "html_url": "https://github.com/vdirienzo/solidcraft/actions/runs/" + rid,
                 "head_sha": sha, "head_branch": rama, "event": "workflow_dispatch",
                 "created_at": created, "updated_at": created, "run_attempt": 1})
json.dump(runs, open(sys.argv[1], "w"))
PY
}
fork_set_jobs(){ printf '%s\n' "$2" > "$TMP/forkci/jobs-$1.json"; }
n_calls(){ grep -c "^$1" "$TMP/calls.log" || true; }
draft_fork(){
  set_pulls <<EOF
16001|Fork CI (#16100)|1|$SHAF|Arregla\n\nFixes #16100\n\nChanges a default: no\n|[]
EOF
}

# --- F1: sin run -> UN despacho, con cross_compile, en la rama del PR -------
fork_reset; draft_fork
run_pipeline
if [ "$(n_calls DISPATCH)" -eq 1 ] && grep -q "^DISPATCH:feat/x .*--ref feat/x" "$TMP/calls.log" \
   && grep -q "^DISPATCH:.*-R vdirienzo/solidcraft" "$TMP/calls.log" \
   && grep -q "^DISPATCH:.*cross_compile=true" "$TMP/calls.log"; then
  ok "F1. un draft sin run del fork despacha ci.yml UNA vez, en su rama y con cross_compile"
else
  no "F1. un draft sin run del fork despacha ci.yml UNA vez, en su rama y con cross_compile" "$(cat "$TMP/calls.log")"
fi
if [ -f "$ORCH_DIR/gates/fork-ci/$SHAF.despacho" ] && ! grep -q "^READY:16001" "$TMP/calls.log"; then
  ok "F1. el despacho deja su marca y el PR sigue en draft"
else
  no "F1. el despacho deja su marca y el PR sigue en draft" "$(ls "$ORCH_DIR/fork-ci" 2>&1)"
fi
if grep -q "modo del gate: fork-ci (de el default)" "$TMP/out.log"; then
  ok "F1. sin GATE_MODE ni config.env el modo es fork-ci, y el log lo dice"
else
  no "F1. sin GATE_MODE ni config.env el modo es fork-ci, y el log lo dice" "$(head -3 "$TMP/out.log")"
fi

# --- F2: la pasada siguiente NO vuelve a despachar (el run ya esta) ---------
run_pipeline
if [ "$(n_calls DISPATCH)" -eq 1 ] && grep -q "CI del fork PENDIENTE" "$TMP/out.log"; then
  ok "F2. la pasada siguiente no vuelve a despachar: el run del sha esta en vuelo (PENDIENTE)"
else
  no "F2. la pasada siguiente no vuelve a despachar: el run del sha esta en vuelo (PENDIENTE)" \
     "dispatch=$(n_calls DISPATCH) $(grep 'PR #16001' "$TMP/out.log" | tail -2)"
fi

# --- F2b: el run todavia no aparece en la API: la marca frena el segundo ---
fork_reset; draft_fork
: > "$TMP/dispatch-no-run"
run_pipeline; run_pipeline
if [ "$(n_calls DISPATCH)" -eq 1 ]; then
  ok "F2b. con el run que la API todavia no lista, la marca local impide el segundo despacho"
else
  no "F2b. con el run que la API todavia no lista, la marca local impide el segundo despacho" \
     "dispatch=$(n_calls DISPATCH)"
fi

# --- F3: el run del sha termino en success -> ready ------------------------
fork_reset; draft_fork
fork_set_runs <<EOF
801|completed|success|$SHAF|feat/x|2026-11-21T10:00:00Z
EOF
run_pipeline
if grep -q "^READY:16001" "$TMP/calls.log" && grep -q "CI del fork VERDE" "$TMP/out.log" \
   && [ "$(n_calls DISPATCH)" -eq 0 ] && [ "$(n_calls JOBS)" -eq 0 ]; then
  ok "F3. el CI del fork VERDE en el head (y el de GitHub verde) pasa el draft a ready, sin leer jobs"
else
  no "F3. el CI del fork VERDE en el head (y el de GitHub verde) pasa el draft a ready, sin leer jobs" \
     "$(cat "$TMP/calls.log"; grep 'PR #16001' "$TMP/out.log")"
fi

# --- F4: el run termino en failure -> sigue en draft, dice que job falla ---
fork_reset; draft_fork
fork_set_runs <<EOF
802|completed|failure|$SHAF|feat/x|2026-11-21T10:00:00Z
EOF
fork_set_jobs 802 '[{"id":1,"name":"Native Linux tests","status":"completed","conclusion":"failure","started_at":"2026-11-21T10:01:00Z","completed_at":"2026-11-21T11:00:00Z"},{"id":2,"name":"Native Linux Clippy","status":"completed","conclusion":"success","started_at":"2026-11-21T10:01:00Z","completed_at":"2026-11-21T10:30:00Z"}]'
run_pipeline; run_pipeline
if ! grep -q "^READY:16001" "$TMP/calls.log" && grep -q "CI del fork ROJO" "$TMP/out.log" \
   && grep -q "fallan: Native Linux tests" "$TMP/out.log" && [ "$(n_calls DISPATCH)" -eq 0 ]; then
  ok "F4. el CI del fork ROJO deja el draft en draft y el log nombra el job que falla"
else
  no "F4. el CI del fork ROJO deja el draft en draft y el log nombra el job que falla" \
     "$(grep 'PR #16001' "$TMP/out.log" | tail -2)"
fi
if [ "$(n_calls JOBS)" -eq 1 ]; then
  ok "F4. los jobs de un run terminado se leen UNA vez (la segunda pasada usa la cache)"
else
  no "F4. los jobs de un run terminado se leen UNA vez (la segunda pasada usa la cache)" "jobs=$(n_calls JOBS)"
fi

# --- F5: el tope de runs en vuelo --------------------------------------------
fork_reset; draft_fork
fork_set_runs <<EOF
811|in_progress||$SHAV|feat/y|2026-11-21T10:00:00Z
812|queued||$SHAV|feat/z|2026-11-21T10:05:00Z
EOF
run_pipeline
if [ "$(n_calls DISPATCH)" -eq 0 ] && grep -q "FORK_CI_MAX_INFLIGHT=2" "$TMP/out.log"; then
  ok "F5. con dos runs del fork en vuelo (el tope) no se despacha otro"
else
  no "F5. con dos runs del fork en vuelo (el tope) no se despacha otro" \
     "dispatch=$(n_calls DISPATCH) $(grep 'PR #16001' "$TMP/out.log" | tail -1)"
fi

# --- F6: el run viejo de la MISMA rama se cancela y no ocupa el tope -------
fork_reset; draft_fork
fork_set_runs <<EOF
821|in_progress||$SHAV|feat/x|2026-11-21T10:00:00Z
822|in_progress||$SHAV|feat/z|2026-11-21T10:05:00Z
EOF
run_pipeline
if grep -q "^CANCEL:821" "$TMP/calls.log" && ! grep -q "^CANCEL:822" "$TMP/calls.log" \
   && [ "$(n_calls DISPATCH)" -eq 1 ] \
   && [ "$(grep -n '^CANCEL:821' "$TMP/calls.log" | cut -d: -f1)" -lt "$(grep -n '^DISPATCH' "$TMP/calls.log" | cut -d: -f1)" ]; then
  ok "F6. el run en vuelo de la misma rama con otro sha se cancela antes del despacho (y no cuenta en el tope)"
else
  no "F6. el run en vuelo de la misma rama con otro sha se cancela antes del despacho" "$(cat "$TMP/calls.log")"
fi

# --- F7: la rama del fork no esta en el sha del PR -> no se despacha -------
fork_reset "$SHAV"; draft_fork
run_pipeline
if [ "$(n_calls DISPATCH)" -eq 0 ] && grep -q "RAMA_MOVIDA" "$TMP/out.log"; then
  ok "F7. si la rama del fork esta en otro sha no se despacha (el run probaria otro commit)"
else
  no "F7. si la rama del fork esta en otro sha no se despacha" "$(grep 'PR #16001' "$TMP/out.log" | tail -1)"
fi

# --- F8: un PR que el agente ya paso a ready no se toca -------------------
fork_reset
set_pulls <<EOF
16002|Ya listo|0|$SHAF|Arregla\n\nFixes #16101\n\nChanges a default: no\n|[]
EOF
run_pipeline
if [ "$(n_calls DISPATCH)" -eq 0 ] && [ "$(n_calls READY)" -eq 0 ] && [ "$(n_calls EDIT)" -eq 0 ]; then
  ok "F8. un PR que ya esta listo no se despacha, no se vuelve a draft y no se edita"
else
  no "F8. un PR que ya esta listo no se despacha, no se vuelve a draft y no se edita" "$(cat "$TMP/calls.log")"
fi

# --- F9: los runs del fork no se pueden leer -> UNKNOWN, sin despachar ----
fork_reset; draft_fork
: > "$TMP/forkci-fail"
run_pipeline; rc=$?
if [ "$rc" -eq 6 ] && [ "$(n_calls DISPATCH)" -eq 0 ]; then
  ok "F9. si los runs del fork no se pueden leer: rc=6 (UNKNOWN) y no se despacha a ciegas"
else
  no "F9. si los runs del fork no se pueden leer: rc=6 (UNKNOWN) y no se despacha a ciegas" \
     "rc=$rc dispatch=$(n_calls DISPATCH)"
fi

# --- F10: GitHub rechaza el despacho -> rc=1 una vez, despues se espera ---
fork_reset; draft_fork
: > "$TMP/dispatch-fail"
run_pipeline; rc1=$?
run_pipeline; rc2=$?
if [ "$rc1" -eq 1 ] && grep -q "Actions has been disabled" "$TMP/out.log" \
   && [ "$(n_calls DISPATCH)" -eq 1 ] && [ "$rc2" -eq 0 ] && grep -q "RECHAZADO" "$TMP/out.log"; then
  ok "F10. un despacho rechazado sale rc=1 una vez; la pasada siguiente no reintenta (RECHAZADO, rc=0)"
else
  no "F10. un despacho rechazado sale rc=1 una vez; la pasada siguiente no reintenta" \
     "rc1=$rc1 rc2=$rc2 dispatch=$(n_calls DISPATCH) $(grep 'PR #16001' "$TMP/out.log" | tail -1)"
fi
if [ ! -f "$ORCH_DIR/gates/fork-ci/$SHAF.despacho" ]; then
  ok "F10. el despacho que fallo no deja la marca de despachado"
else
  no "F10. el despacho que fallo no deja la marca de despachado"
fi

# --- F11: el agente sigue trabajando en el slot -> no se despacha ---------
fork_reset; draft_fork
mkdir -p "$WORKTREES_DIR/issue-16100"
printf '#!/usr/bin/env bash\necho "busy: pid 1 trabaja en $1"\nexit 0\n' > "$ORCH_DIR/bin/slot-busy.sh"
run_pipeline
rm -f "$ORCH_DIR/bin/slot-busy.sh"
if [ "$(n_calls DISPATCH)" -eq 0 ] && grep -q "el agente sigue trabajando" "$TMP/out.log"; then
  ok "F11. mientras el agente trabaja en el slot no se despacha el CI del fork"
else
  no "F11. mientras el agente trabaja en el slot no se despacha el CI del fork" "$(grep 'PR #16001' "$TMP/out.log" | tail -1)"
fi

# --- F12: GATE_MODE=local en config.env: el camino viejo; el entorno gana --
fork_reset; draft_fork
printf 'GATE_MODE=local\n' > "$LOOP_DIR/config.env"
rm -f "$ORCH_DIR/gates/queue.txt"
MAX_INFLIGHT=5 run_pipeline
if grep -q "^16100 $SHAF" "$ORCH_DIR/gates/queue.txt" 2>/dev/null && [ "$(n_calls DISPATCH)" -eq 0 ]; then
  ok "F12. GATE_MODE=local en config.env encola el gate local y no despacha el fork"
else
  no "F12. GATE_MODE=local en config.env encola el gate local y no despacha el fork" \
     "$(cat "$ORCH_DIR/gates/queue.txt" 2>&1) $(grep -E 'modo|PR #16001' "$TMP/out.log")"
fi
rm -f "$ORCH_DIR/gates/queue.txt"
: > "$TMP/calls.log"
GATE_MODE=fork-ci run_pipeline
if [ "$(n_calls DISPATCH)" -eq 1 ] && [ ! -s "$ORCH_DIR/gates/queue.txt" ]; then
  ok "F12. GATE_MODE=fork-ci del entorno gana a config.env"
else
  no "F12. GATE_MODE=fork-ci del entorno gana a config.env" "dispatch=$(n_calls DISPATCH)"
fi
rm -f "$LOOP_DIR/config.env"
rm -rf "$WORKTREES_DIR/issue-16100"

# --- F13: un ROJO local no es un verde; en fork-ci el fork verde manda ----
mkdir -p "$LOOP_DIR/gates/slot-rojo"
cat > "$LOOP_DIR/gates/slot-rojo/scope.verdict" <<EOF
GATE_STATUS=finished
VERDICT=ROJO-SCOPE
NEW_FAILURES=0
CHECKS=fmt:fail
SHA=$SHAF
EOF
fork_reset; draft_fork
GATE_MODE=local run_pipeline
if ! grep -q "^READY:16001" "$TMP/calls.log"; then
  ok "F13. en modo local un ROJO-SCOPE con NEW_FAILURES=0 (fmt:fail) NO pasa el PR a ready"
else
  no "F13. en modo local un ROJO-SCOPE con NEW_FAILURES=0 (fmt:fail) NO pasa el PR a ready"
fi
fork_reset; draft_fork
fork_set_runs <<EOF
831|completed|success|$SHAF|feat/x|2026-11-21T10:00:00Z
EOF
run_pipeline
if grep -q "^READY:16001" "$TMP/calls.log"; then
  ok "F13. en modo fork-ci el CI del fork verde manda sobre un ROJO local viejo"
else
  no "F13. en modo fork-ci el CI del fork verde manda sobre un ROJO local viejo" "$(grep 'PR #16001' "$TMP/out.log")"
fi
rm -rf "$LOOP_DIR/gates/slot-rojo"
if grep -q "CI del fork (drafts sin gate local verde): 1 verde" "$TMP/out.log"; then
  ok "F13. el resumen cuenta el estado del CI del fork de los drafts"
else
  no "F13. el resumen cuenta el estado del CI del fork de los drafts" "$(grep 'CI del fork (' "$TMP/out.log")"
fi
unset WORKTREES_DIR

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
