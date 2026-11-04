#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-workflow-runner.sh - las pruebas del RUNNER del grafo.
#
# QUE SE PRUEBA (y por que):
#   1. con el estado VACIO no propone nada: un runner que siempre propone algo
#      es un runner que inventa trabajo;
#   2. con un PR en DRAFT sin veredicto propone gate-queue (ese PR necesita gate);
#   3. con la COLA con un item propone el drain (hay trabajo esperando);
#   4. con --dry-run imprime el comando y NO ejecuta nada;
#   5. ejecuta UN nodo elegible, y solo uno;
#   6. NUNCA ejecuta gate ni gate-queue: los dos compilan Rust y la caja esta
#      ocupada con los gates. Los propone (que se vea que existen) pero no los
#      ejecuta: el turno de compilacion es del cron.
#   7. con el grafo roto no ejecuta nada.
#
# LAS PRUEBAS SON HERMETICAS: no tocan el estado real, ni la cola real, ni los
# verdictos reales, ni GitHub. Todo corre contra un mini-orquestador temporal
# con scripts STUB que solo escriben en un marcador: lo que se prueba es la
# DECISION del runner (que propone y que ejecuta), no el trabajo de cada script.
#
# Run:  bash bin/test-workflow-runner.sh
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$(dirname "$HERE")}"
RUNNER="${RUNNER:-$ORCH_DIR/bin/workflow-runner.sh}"
WORKFLOW_REAL="${WORKFLOW:-$ORCH_DIR/workflow.yaml}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-workflow-runner.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf 'FALLA- %s\n' "$1"; }

[ -f "$RUNNER" ] || { echo "test-workflow-runner: no existe $RUNNER" >&2; exit 2; }
[ -f "$WORKFLOW_REAL" ] || { echo "test-workflow-runner: no existe $WORKFLOW_REAL" >&2; exit 2; }

# Un python3 con PyYAML: el PATH del harness no es el del sistema.
PY=""
for cand in "${WORKFLOW_PYTHON:-}" python3 /usr/bin/python3 /usr/local/bin/python3; do
  [ -z "$cand" ] && continue
  if "$cand" -c "import yaml" >/dev/null 2>&1; then PY="$cand"; break; fi
done
if [ -z "$PY" ]; then
  echo "test-workflow-runner: ningun python3 con PyYAML: no se puede correr la suite" >&2
  exit 2
fi

# --- el mini-orquestador de las pruebas ------------------------------------
ROOT="$TMP/orch"
LOOP="$TMP/loop"
MARCADOR="$TMP/ejecutado.txt"
mkdir -p "$ROOT/bin" "$ROOT/gates" "$LOOP/gates"
: > "$MARCADOR"

cp "$WORKFLOW_REAL" "$ROOT/workflow.yaml"
cp "$ORCH_DIR/bin/workflow-validate.py" "$ROOT/bin/workflow-validate.py" 2>/dev/null || true

# Los STUB: un script que NO hace el trabajo real, solo deja rastro de que
# corrio y con que argumentos. El runner decide; el script es un witness.
stub() {
  local nombre="$1"
  cat > "$ROOT/bin/$nombre" <<EOF
#!/usr/bin/env bash
echo "$nombre \$*" >> "$MARCADOR"
exit 0
EOF
  chmod +x "$ROOT/bin/$nombre"
}
stub claim-verify.sh
stub gate-queue.sh
stub gate.sh
stub gate-baseline.sh
stub verify-pr.sh
cat > "$ROOT/bin/pipeline.py" <<EOF
#!/usr/bin/env python3
import sys
with open("$MARCADOR", "a") as fh:
    fh.write("pipeline.py " + " ".join(sys.argv[1:]) + "\n")
EOF
chmod +x "$ROOT/bin/pipeline.py"

# El runner contra el mini-orquestador.
correr() {
  WORKFLOW="$ROOT/workflow.yaml" WORKFLOW_ROOT="$ROOT" STATE_DIR="$ROOT" \
  STATE_JSON="$ROOT/state.json" LOOP_DIR="$LOOP" WORKFLOW_LOG="$TMP/runner.log" \
  bash "$RUNNER" "$@" 2>&1
}

estado_vacio() {
  echo '{"open_prs": []}' > "$ROOT/state.json"
  : > "$ROOT/gates/queue.txt"
  rm -rf "$LOOP/gates"; mkdir -p "$LOOP/gates"
}

# un PR en draft, con su head, y SIN veredicto para ese head
pr_draft_sin_veredicto() {
  cat > "$ROOT/state.json" <<'EOF'
{"open_prs": [{"number": 1234, "issue": 555, "state": "draft",
               "head": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
EOF
  : > "$ROOT/gates/queue.txt"
  rm -rf "$LOOP/gates"; mkdir -p "$LOOP/gates"
}

# un PR listo (no draft) con veredicto VERDE para su head
pr_listo_con_verde() {
  cat > "$ROOT/state.json" <<'EOF'
{"open_prs": [{"number": 1234, "issue": 555, "state": "ready",
               "head": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}
EOF
  : > "$ROOT/gates/queue.txt"
  rm -rf "$LOOP/gates"; mkdir -p "$LOOP/gates"
  mkdir -p "$LOOP/gates/555"
  cat > "$LOOP/gates/555/scope.verdict" <<'EOF'
GATE_STATUS=finished
VERDICT=VERDE-SCOPE
NEW_FAILURES=0
SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
  # el veredicto efectivo ya esta: gate-baseline no es elegible y el unico
  # nodo ejecutable es verify-pr
  cp "$LOOP/gates/555/scope.verdict" "$LOOP/gates/555/scope.effective.verdict"
}

# --- 1. el estado vacio no propone nada ------------------------------------
estado_vacio
out="$(correr --list)"
if printf '%s' "$out" | grep -q "ningun nodo es elegible"; then
  ok "con el estado vacio no propone nada"
else
  no "con el estado vacio no propone nada"; printf '     %s\n' "$out"
fi

# y tampoco ejecuta nada
: > "$MARCADOR"
correr >/dev/null
[ ! -s "$MARCADOR" ] && ok "con el estado vacio no ejecuta nada" \
                     || no "con el estado vacio no ejecuta nada: $(cat "$MARCADOR")"

# --- 2. un PR en draft sin veredicto propone gate-queue -------------------
pr_draft_sin_veredicto
out="$(correr --list)"
if printf '%s' "$out" | grep -q "gate-queue"; then
  ok "con un PR en draft sin veredicto propone gate-queue"
else
  no "con un PR en draft sin veredicto propone gate-queue"; printf '     %s\n' "$out"
fi

# la senal que lo habilita es la correcta (no un accidento)
if printf '%s' "$out" | grep "gate-queue" | grep -q "pr_draft_sin_veredicto"; then
  ok "la propuesta de gate-queue viene de la senal pr_draft_sin_veredicto"
else
  no "la propuesta de gate-queue viene de la senal pr_draft_sin_veredicto"; printf '     %s\n' "$out"
fi

# --- 3. con la cola con un item propone el drain --------------------------
pr_draft_sin_veredicto
printf '555 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$ROOT/gates/queue.txt"
out="$(correr --list)"
if printf '%s' "$out" | grep "gate-queue" | grep -q "drenar"; then
  ok "con la cola con un item propone el drain"
else
  no "con la cola con un item propone el drain"; printf '     %s\n' "$out"
fi

# con la cola VACIA no propone el drain
: > "$ROOT/gates/queue.txt"
out="$(correr --list)"
if ! printf '%s' "$out" | grep "gate-queue" | grep -q "drenar"; then
  ok "con la cola vacia no propone el drain"
else
  no "con la cola vacia no propone el drain"; printf '     %s\n' "$out"
fi

# --- 4. --dry-run imprime y NO ejecuta ------------------------------------
pr_listo_con_verde
: > "$MARCADOR"
out="$(correr --dry-run)"
if printf '%s' "$out" | grep -q "comando:"; then
  ok "el --dry-run imprime el comando"
else
  no "el --dry-run imprime el comando"; printf '     %s\n' "$out"
fi
[ ! -s "$MARCADOR" ] && ok "el --dry-run no ejecuta nada" \
                     || no "el --dry-run no ejecuta nada: $(cat "$MARCADOR")"

# --- 5. ejecuta UN nodo elegible, y solo uno ------------------------------
pr_listo_con_verde
: > "$MARCADOR"
correr >/dev/null
nlineas="$(wc -l < "$MARCADOR" | tr -d ' ')"
if [ "$nlineas" = "1" ]; then
  ok "el runner ejecuta UN nodo elegible (y solo uno)"
else
  no "el runner ejecuta UN nodo elegible (y solo uno): ejecuto $nlineas"
fi
if grep -q "verify-pr.sh 1234" "$MARCADOR"; then
  ok "el nodo ejecutado es el que corresponde (verify-pr del PR 1234)"
else
  no "el nodo ejecutado es el que corresponde"; printf '     %s\n' "$(cat "$MARCADOR")"
fi

# --- 6. NUNCA ejecuta gate ni gate-queue (compilan Rust) -------------------
pr_draft_sin_veredicto
printf '555 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$ROOT/gates/queue.txt"
: > "$MARCADOR"
correr >/dev/null
if ! grep -qE "gate\.sh|gate-queue\.sh" "$MARCADOR"; then
  ok "el runner NO ejecuta gate ni gate-queue (compilan Rust)"
else
  no "el runner NO ejecuta gate ni gate-queue"; printf '     %s\n' "$(cat "$MARCADOR")"
fi

# y los PROPONE igual, diciendo que los lleva el cron
out="$(correr --list)"
if printf '%s' "$out" | grep -q "cron"; then
  ok "el --list dice quien lleva los nodos que el runner no ejecuta"
else
  no "el --list dice quien lleva los nodos que el runner no ejecuta"; printf '     %s\n' "$out"
fi

# --- 7. con el grafo roto no ejecuta nada ---------------------------------
sed 's/^      a: verify-pr$/      a: nodo-que-no-existe/' "$ROOT/workflow.yaml" > "$ROOT/workflow-roto.yaml"
cp "$ROOT/workflow.yaml" "$ROOT/workflow-bueno.yaml"
cp "$ROOT/workflow-roto.yaml" "$ROOT/workflow.yaml"
: > "$MARCADOR"
out="$(correr --list)"
rc=$?
if [ $rc -ne 0 ] && [ ! -s "$MARCADOR" ]; then
  ok "con el grafo roto el runner no ejecuta nada y avisa"
else
  no "con el grafo roto el runner no ejecuta nada y avisa (rc=$rc)"
fi
cp "$ROOT/workflow-bueno.yaml" "$ROOT/workflow.yaml"

# --- 8. el estado se reconcilia: un PR MERGED no esta en draft ------------
cat > "$ROOT/state.json" <<'EOF'
{"open_prs": [{"number": 1234, "issue": 555, "state": "MERGED",
               "head": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}],
 "prs_esperando_el_gate": [{"pr": "#1234", "issue": "#555", "sha": "aaaa",
                            "estado": "DRAFT"}]}
EOF
: > "$ROOT/gates/queue.txt"
rm -rf "$LOOP/gates"; mkdir -p "$LOOP/gates"
out="$(correr --list)"
if ! printf '%s' "$out" | grep -q "gate-queue"; then
  ok "un PR mergeado no se propone como draft (el estado se reconcilia)"
else
  no "un PR mergeado no se propone como draft"; printf '     %s\n' "$out"
fi

# --- 9. el --json es JSON de verdad, y los campos no estan cruzados -------
pr_draft_sin_veredicto
out="$(correr --json)"
if printf '%s' "$out" | "$PY" -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
  ok "el --json del runner es JSON valido"
else
  no "el --json del runner es JSON valido"; printf '     %s\n' "$out"
fi

# el --json tiene que decir QUE senal habilito el nodo, no el motivo: si los
# dos campos estan cruzados, el --json miente aunque la tabla este bien.
if printf '%s' "$out" | "$PY" -c "
import json,sys
d=json.load(sys.stdin)
e=d['elegibles']
assert any(x['senal']=='pr_draft_sin_veredicto' for x in e), 'no dice la senal'
assert all(x['razon']!='pr_draft_sin_veredicto' for x in e), 'senal y razon cruzados'
" 2>/dev/null; then
  ok "el --json no cruza la senal con el motivo"
else
  no "el --json no cruza la senal con el motivo"; printf '     %s\n' "$out"
fi

printf '\n%d casos, %d fallan\n' "$((PASS+FAIL))" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
