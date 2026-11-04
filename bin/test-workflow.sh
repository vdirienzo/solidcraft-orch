#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-workflow.sh - las pruebas del VALIDADOR del grafo (workflow.yaml).
#
# POR QUE EXISTEN: el workflow.yaml declara el proceso de un issue. Si el
# validador no existe, un dia se renombra un nodo, la arista que lo apunta queda
# rota en silencio y el runner propone un nodo que no existe: el grafo miente.
#
# LA PRUEBA NEGATIVA ESTA AL FINAL Y ES LO IMPORTANTE: los casos 2 a 6 le
# apuntan el validador a GRAFOS ROTOS y exigen que FALLE. Un validador que
# siempre dice "OK" no es un validador: es un program's "todo bien". Si alguno de
# esos casos pasara, el suite falla.
#
# LOS GRAFOS ROTOS SE HACEN DEL REAL, CON SED Y AWK, NO A MANO: si el grafo
# bueno cambia, los rotos cambian con el y el suite sigue probando lo que dice
# probar. (Reconstruir un YAML a mano en el test es una segunda copia del grafo
# que se desincroniza sin avisar.)
#
# Run:  bash bin/test-workflow.sh
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$(dirname "$HERE")}"
WORKFLOW="${WORKFLOW:-$ORCH_DIR/workflow.yaml}"
VALIDADOR="${VALIDADOR:-$ORCH_DIR/bin/workflow-validate.py}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-workflow.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf 'FALLA- %s\n' "$1"; }

# El validador necesita un python con PyYAML: el PATH del harness no es el del
# sistema. Se busca uno que pueda importarlo.
PY=""
for cand in "${WORKFLOW_PYTHON:-}" python3 /usr/bin/python3 /usr/local/bin/python3; do
  [ -z "$cand" ] && continue
  if "$cand" -c "import yaml" >/dev/null 2>&1; then PY="$cand"; break; fi
done
if [ -z "$PY" ]; then
  echo "test-workflow: ningun python3 con PyYAML: no se puede correr la suite" >&2
  exit 2
fi

[ -f "$WORKFLOW" ] || { echo "test-workflow: no existe $WORKFLOW" >&2; exit 2; }
[ -f "$VALIDADOR" ] || { echo "test-workflow: no existe $VALIDADOR" >&2; exit 2; }

# Quita del YAML el bloque del nodo cuyo id es $1 (desde su "- id:" hasta el
# siguiente "- id:"). Se usa para los grafos rotos.
quitar_nodo() {
  awk -v target="  - id: $1" '
    /^  - id: / { dentro = ($0 == target) }
    !dentro { print }
  ' "$WORKFLOW"
}

# --- 1. el grafo real es valido -------------------------------------------
out="$("$PY" "$VALIDADOR" --workflow "$WORKFLOW" --root "$ORCH_DIR" 2>&1)"
rc=$?
if [ $rc -eq 0 ]; then
  ok "el workflow.yaml real valida (rc=0)"
else
  no "el workflow.yaml real valida (rc=$rc)"; printf '     %s\n' "$out"
fi

# el --json dice lo mismo
jout="$("$PY" "$VALIDADOR" --workflow "$WORKFLOW" --root "$ORCH_DIR" --json 2>/dev/null)"
jrc=$?
if [ $jrc -eq 0 ] && printf '%s' "$jout" | grep -q '"ok": true'; then
  ok "el --json del grafo real dice ok=true"
else
  no "el --json del grafo real dice ok=true (rc=$jrc)"
fi

# el grafo real declara los 12 nodos que el brief exige
faltan=""
for n in buscar-issue claim-verify causa-raiz test-red fix draft-pr \
         pipeline gate-queue gate gate-baseline verify-pr ci-upstream; do
  grep -q "^  - id: $n$" "$WORKFLOW" || faltan="$faltan $n"
done
[ -z "$faltan" ] && ok "el grafo declara los 12 nodos del proceso de un issue" \
                  || no "el grafo declara los 12 nodos (faltan:$faltan)"

# el runner y el validador viven al lado del workflow
[ -f "$ORCH_DIR/bin/workflow-runner.sh" ] && ok "el runner esta al lado del validador" \
                                         || no "el runner esta al lado del validador"

# --- 2. un nodo obligatorio que falta: FALLA -------------------------------
quitar_nodo verify-pr > "$TMP/falta-nodo.yaml"
"$PY" "$VALIDADOR" --workflow "$TMP/falta-nodo.yaml" --root "$ORCH_DIR" >"$TMP/o1" 2>&1
rc=$?
if [ $rc -ne 0 ] && grep -q "verify-pr" "$TMP/o1"; then
  ok "un grafo sin el nodo 'verify-pr' hace FALLAR al validador"
else
  no "un grafo sin el nodo 'verify-pr' hace FALLAR al validador (rc=$rc)"
fi

# --- 3. una arista a un nodo que no existe: FALLA -------------------------
sed 's/^      a: verify-pr$/      a: nodo-que-no-existe/' "$WORKFLOW" > "$TMP/arista-rota.yaml"
grep -q "nodo-que-no-existe" "$TMP/arista-rota.yaml" || {
  echo "test-workflow: no se pudo romper la arista (el YAML cambio de forma)" >&2
  exit 2
}
"$PY" "$VALIDADOR" --workflow "$TMP/arista-rota.yaml" --root "$ORCH_DIR" >"$TMP/o2" 2>&1
rc=$?
if [ $rc -ne 0 ] && grep -q "nodo-que-no-existe" "$TMP/o2"; then
  ok "una arista a un nodo inexistente hace FALLAR al validador"
else
  no "una arista a un nodo inexistente hace FALLAR al validador (rc=$rc)"
fi

# --- 4. un script que no esta en bin/: FALLA ------------------------------
sed 's|script: "bin/verify-pr.sh"|script: "bin/no-existe-jamas.sh"|' "$WORKFLOW" > "$TMP/script-roto.yaml"
grep -q "no-existe-jamas" "$TMP/script-roto.yaml" || {
  echo "test-workflow: no se pudo romper el script (el YAML cambio de forma)" >&2
  exit 2
}
"$PY" "$VALIDADOR" --workflow "$TMP/script-roto.yaml" --root "$ORCH_DIR" >"$TMP/o3" 2>&1
rc=$?
if [ $rc -ne 0 ] && grep -q "no-existe-jamas" "$TMP/o3"; then
  ok "un script que no esta en bin/ hace FALLAR al validador"
else
  no "un script que no esta en bin/ hace FALLAR al validador (rc=$rc)"
fi

# --- 5. un si_falla fuera del vocabulario: FALLA ---------------------------
sed 's/^    si_falla: escalar$/    si_falla: explota/' "$WORKFLOW" > "$TMP/sifalla-roto.yaml"
"$PY" "$VALIDADOR" --workflow "$TMP/sifalla-roto.yaml" --root "$ORCH_DIR" >"$TMP/o4" 2>&1
rc=$?
if [ $rc -ne 0 ] && grep -q "si_falla" "$TMP/o4"; then
  ok "un si_falla invalido hace FALLAR al validador"
else
  no "un si_falla invalido hace FALLAR al validador (rc=$rc)"
fi

# --- 6. una senal que no esta declarada: FALLA ----------------------------
sed 's/cuando: \[pr_listo_para_verificar\]/cuando: [senal-inventada]/' "$WORKFLOW" > "$TMP/senal-rota.yaml"
"$PY" "$VALIDADOR" --workflow "$TMP/senal-rota.yaml" --root "$ORCH_DIR" >"$TMP/o5" 2>&1
rc=$?
if [ $rc -ne 0 ] && grep -q "senal-inventada" "$TMP/o5"; then
  ok "una senal no declarada hace FALLAR al validador"
else
  no "una senal no declarada hace FALLAR al validador (rc=$rc)"
fi

# --- 7. el --json de un grafo roto lo dice ---------------------------------
"$PY" "$VALIDADOR" --workflow "$TMP/arista-rota.yaml" --root "$ORCH_DIR" --json >"$TMP/j1" 2>/dev/null
rc=$?
if [ $rc -ne 0 ] && grep -q '"ok": false' "$TMP/j1" && grep -q '"errores"' "$TMP/j1"; then
  ok "el --json de un grafo roto dice ok=false y lista los errores"
else
  no "el --json de un grafo roto dice ok=false y lista los errores (rc=$rc)"
fi

# --- 8. un YAML que ni se puede parsear: FALLA (no se cae) ---------------
printf 'nodos: [\n  esto no es yaml: {{{\n' > "$TMP/yaml-roto.yaml"
"$PY" "$VALIDADOR" --workflow "$TMP/yaml-roto.yaml" --root "$ORCH_DIR" >"$TMP/o6" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  ok "un YAML invalido hace FALLAR al validador (y no lo rompe)"
else
  no "un YAML invalido hace FALLAR al validador (rc=$rc)"
fi

# --- 9. un archivo que no existe: FALLA -----------------------------------
"$PY" "$VALIDADOR" --workflow "$TMP/no-existe.yaml" --root "$ORCH_DIR" >"$TMP/o7" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  ok "un workflow inexistente hace FALLAR al validador"
else
  no "un workflow inexistente hace FALLAR al validador (rc=$rc)"
fi

# --- 10. EL GRAFO ROTO HACE FALLAR AL RUNNER, NO SOLO AL VALIDADOR --------
# El runner valida antes de actuar: si el grafo esta roto, no ejecuta nada.
if [ -x "$ORCH_DIR/bin/workflow-runner.sh" ]; then
  out="$(WORKFLOW="$TMP/arista-rota.yaml" WORKFLOW_ROOT="$ORCH_DIR" \
         bash "$ORCH_DIR/bin/workflow-runner.sh" --list 2>&1)"
  rc=$?
  if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qi "roto"; then
    ok "el runner se niega a correr con un grafo roto"
  else
    no "el runner se niega a correr con un grafo roto (rc=$rc)"
  fi
fi

printf '\n%d casos, %d fallan\n' "$((PASS+FAIL))" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
