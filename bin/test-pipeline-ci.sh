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
no(){ printf 'FALLA- %s\n' "$1"; fail=$((fail+1)); }

[ -f "$PIPELINE" ] || { echo "no encuentro $PIPELINE"; exit 1; }
command -v python3 >/dev/null || { echo "no hay python3"; exit 1; }

# ------------------------------------------------------------------
# 1. las funciones puras: se importan del modulo y se les pasan los
#    check-runs como dato (sin red).
# ------------------------------------------------------------------
run_py(){ python3 - "$@" <<'PY'
import sys, os, json
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

sys.exit(1 if fails else 0)
PY
}

export PIPELINE_DIR="$HERE"

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

# ------------------------------------------------------------------
# 2. el pipeline COMPLETO con un gh de mentira: se comprueba que un
#    PR sin la linea NO recibe un 'no' automatico y que un PR con el
#    CI en rojo NO se promueve.
# ------------------------------------------------------------------
ORCH="$TMP/orch"
LOOP="$TMP/loop"
mkdir -p "$ORCH/bin" "$ORCH/gates" "$LOOP/gates/slot1" "$TMP/checks"

# el veredicto del gate local: VERDE. El CI de GitHub es lo que se prueba aparte.
cat > "$LOOP/gates/slot1/scope.verdict" <<'EOF'
GATE_STATUS=finished
VERDICT=VERDE-SCOPE
NEW_FAILURES=0
SHA=abc123def4567890
EOF

# el stub de gh: registra lo que se le pide y contesta con lo que hay en $STUB_DIR.
cat > "$TMP/gh-stub" <<'STUB'
#!/usr/bin/env bash
D="${STUB_DIR:?}"
echo "gh $*" >> "$D/calls.log"
case "$1 $2" in
  "pr list")
    cat "$D/pr-list.json" ;;
  "pr view")
    echo '{"headRefOid":"abc123def4567890"}' ;;
  "pr edit")
    # el body editado va al log, para poder ver QUE se escribio
    echo "EDIT-BODY<<<$(printf '%s' "$*")>>>" >> "$D/calls.log"
    echo "https://github.com/tangency-labs/solidcraft/pull/999" ;;
  "pr ready")
    echo "READY:$3" >> "$D/calls.log"
    echo "ready" ;;
  "pr comment")
    echo "COMMENT:$3" >> "$D/calls.log"
    echo "comment" ;;
  "api "*)
    sha=$(printf '%s' "$2" | sed 's#.*/commits/##; s#/check-runs##')
    [ -f "$D/checks/$sha.jsonl" ] && cat "$D/checks/$sha.jsonl"
    ;;
esac
exit 0
STUB
chmod +x "$TMP/gh-stub"

export STUB_DIR="$TMP"
export GH_BIN="$TMP/gh-stub"
export ORCH_DIR="$ORCH"
export LOOP_DIR="$LOOP"
export MAX_INFLIGHT=0

# los check-runs por SHA: uno verde (el del run nuevo) y uno con el cancelled del viejo.
cat > "$TMP/checks/abc123def4567890.jsonl" <<'EOF'
{"name":"Defaults line check","status":"completed","conclusion":"cancelled","completed_at":"2026-11-06T15:46:35Z","started_at":"2026-11-06T15:46:30Z","id":111}
{"name":"Defaults line check","status":"completed","conclusion":"success","completed_at":"2026-11-06T15:46:43Z","started_at":"2026-11-06T15:46:38Z","id":222}
{"name":"Duplicate PR check","status":"completed","conclusion":"success","completed_at":"2026-11-06T15:46:51Z","started_at":"2026-11-06T15:46:40Z","id":223}
EOF

run_pipeline(){ python3 "$PIPELINE" > "$TMP/out.log" 2>&1; }

# --- caso A: el PR tiene la forma larga valida -------------------------------
cat > "$TMP/pr-list.json" <<'EOF'
[{"number":12574,"title":"Preset numbers","isDraft":true,
  "headRefOid":"abc123def4567890","labels":[],
  "body":"Preset numbers for functions\n\nFixes #12418\n\nChanges a default: yes - a new length field in an operation dialog starts with the size its tool ships with, shown in the design's unit, old behaviour kept behind preference scaled_length_defaults\n"}]
EOF
: > "$TMP/calls.log"
run_pipeline
if grep -q "Changes a default: no" "$TMP/calls.log"; then
  no "un 'yes' valido NO se pisa con un 'no'"
else
  ok "un 'yes' valido NO se pisa con un 'no'"
fi
if grep -q "^READY:12574" "$TMP/calls.log"; then
  ok "un PR con el CI verde y el gate verde pasa a ready"
else
  no "un PR con el CI verde y el gate verde pasa a ready" "$(cat "$TMP/calls.log")"
fi

# --- caso B: el PR NO tiene la linea de defaults ----------------------------
cat > "$TMP/pr-list.json" <<'EOF'
[{"number":13000,"title":"Sin la linea","isDraft":true,
  "headRefOid":"abc123def4567890","labels":[],
  "body":"Arregla un crash en la salida\n\nFixes #12842\n"}]
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
cat > "$TMP/pr-list.json" <<'EOF'
[{"number":12574,"title":"Preset numbers","isDraft":true,
  "headRefOid":"abc123def4567890","labels":[],
  "body":"Preset numbers for functions\n\nFixes #12418\n\nChanges a default: no\n"}]
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
cat > "$TMP/pr-list.json" <<'EOF'
[{"number":12574,"title":"Verde","isDraft":true,
  "headRefOid":"abc123def4567890","labels":[],
  "body":"Arregla\n\nFixes #12418\n\nChanges a default: no\n"},
 {"number":13001,"title":"Tambien verde","isDraft":false,
  "headRefOid":"abc123def4567890","labels":[],
  "body":"Arregla\n\nFixes #12419\n"}]
EOF
: > "$TMP/calls.log"
run_pipeline
if grep -qE "CI de GitHub \(HEAD SHA\): 2 verde\(s\), 0 pendiente\(s\), 0 rojo\(s\)" "$TMP/out.log"; then
  ok "el resumen dice cuantos PRs tienen el CI verde, pendiente y rojo"
else
  no "el resumen dice cuantos PRs tienen el CI verde, pendiente y rojo" "$(cat "$TMP/out.log")"
fi

# --- caso F: el body se acaba de editar -> el CI vuelve a correr ------------
# El pipeline le agrega 'Addresses #N': eso dispara el workflow pr-checks (types: edited).
# Promover en la misma pasada dejaria un check rojo en pantalla: el PR espera.
cat > "$TMP/pr-list.json" <<'EOF'
[{"number":12574,"title":"Sin referencia al issue","isDraft":true,
  "headRefOid":"abc123def4567890","labels":[],
  "body":"Arregla el crash de #12418\n\nChanges a default: no\n"}]
EOF
: > "$TMP/calls.log"
run_pipeline
if grep -q "^READY:12574" "$TMP/calls.log"; then
  no "un PR cuyo body se acaba de editar NO se promueve en la misma pasada"
else
  ok "un PR cuyo body se acaba de editar NO se promueve en la misma pasada"
fi
if grep -q "Addresses #" "$TMP/calls.log"; then
  ok "la referencia al issue se agrega igual (es honesta)"
else
  no "la referencia al issue se agrega igual (es honesta)" "$(cat "$TMP/calls.log")"
fi

# --- caso G: la linea de defaults esta mal formada --------------------------
cat > "$TMP/pr-list.json" <<'EOF'
[{"number":12574,"title":"Linea mal formada","isDraft":true,
  "headRefOid":"abc123def4567890","labels":[],
  "body":"Arregla\n\nFixes #12418\n\nChanges a default: yes - cambia el color\n"}]
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
cat > "$TMP/pr-list.json" <<'EOF'
[{"number":12574,"title":"Sin la linea, con etiqueta","isDraft":true,
  "headRefOid":"abc123def4567890","labels":[{"name":"changes-default"}],
  "body":"Arregla\n\nFixes #12418\n"}]
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

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
