#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-daily-report.sh - las pruebas de los REPORTES (reporte diario y
# estado del loop).
#
# POR QUE ESTE ARCHIVO EXISTE: el area no tenia archivo de test. El reporte
# diario es el reporte que lee el usuario (un cron a las 10:00 y a las 22:00)
# y estaba perdiendo justo lo unico para lo que existe: la ACCION de cada
# pendiente. El parser del resumen miraba "hacer:" DOS lineas mas abajo, pero
# orch-state.sh imprime cada pendiente en DOS lineas: el item y, en la
# SIGUIENTE, "      hacer: <accion>". El parser nunca la encontraba: el
# reporte decia QUE estaba pendiente y nunca QUE HACER (B9 de
# reports/loop-codigo.md, abierto el 2026-11-02).
#
# El estado del loop tenia la misma clase de mentira al reves: una base de
# datos que no se podia leer se reportaba como "Agentes vivos: 1", y el
# script salia siempre con rc=0.
#
# HERMETICO: ORCH_DIR, LOOP_DIR, HERMES_HOME y WORKTREES_DIR apuntan a
# directorios de prueba, y `gh` es un stub FUERA del PATH (se elige con
# GH_BIN) que responde desde un fixture. GitHub no se toca nunca.
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-daily-report.XXXXXX")"
PASS=0
FAIL=0

cleanup() { rm -rf "$TESTDIR"; }
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf '  FALLO - %s\n' "$1"
  if [ "$#" -gt 1 ]; then printf '         %s\n' "$2"; fi
}

# --- el stub de gh: FUERA del PATH, se elige con GH_BIN -------------------
mkdir -p "$TESTDIR/stub"
cat >"$TESTDIR/stub/gh" <<'STUB'
#!/usr/bin/env bash
# Un stub de gh que responde desde un fixture y NO toca la red. Los scripts
# lo eligen con GH_BIN (nunca esta en el PATH). Con GH_FAIL=1 falla, para
# probar que un comando que no pudo correr NO es una respuesta vacia.
case "${1:-}" in
  pr)
    if [ "${GH_FAIL:-0}" = "1" ]; then
      echo "gh: no autenticado" >&2
      exit 1
    fi
    cat "${GH_PR_FIXTURE:-/dev/null}" 2>/dev/null ;;
  api) cat "${GH_API_FIXTURE:-/dev/null}" 2>/dev/null ;;
  *)   printf '[]\n' ;;
esac
exit 0
STUB
chmod +x "$TESTDIR/stub/gh"

# --- los directorios de prueba --------------------------------------------
ORCH="$TESTDIR/orch"
LOOP="$TESTDIR/loop"
HERMES="$TESTDIR/hermes"
WORKTREES="$TESTDIR/worktrees"
ORCH2="$TESTDIR/orch2"
mkdir -p "$ORCH" "$LOOP/gates" "$HERMES" "$WORKTREES" "$ORCH2"
# El orquestador de verdad (es el que imprime el formato de los pendientes)
# y un stub de slot-stale.sh: el resumen NO tiene que hablar con GitHub, y
# el script de los locks es de otra area (se esta partiendo en --locks/--prs).
mkdir -p "$ORCH/bin"
ln -s "$HERE/orch-state.sh" "$ORCH/bin/orch-state.sh"
cat >"$ORCH/bin/slot-stale.sh" <<'STUB'
#!/usr/bin/env bash
# Un stub de slot-stale.sh: el resumen solo necesita los pendientes, y este
# script no puede hablar con GitHub. Vive en el ORCH_DIR de prueba, no en el PATH.
exit 0
STUB
chmod +x "$ORCH/bin/slot-stale.sh"

# un PR en el fixture: el reporte tiene que poder decir cuantos hay
cat >"$TESTDIR/prs.json" <<'EOF'
[{"number": 9001, "state": "OPEN", "isDraft": false, "createdAt": "2026-01-01T09:00:00Z", "title": "PR de prueba"}]
EOF
: >"$TESTDIR/issues.txt"

# la base de agentes: una base sqlite de verdad, VACIA (0 agentes vivos)
make_db() {
  rm -f "$HERMES/state.db"
  python3 - "$HERMES/state.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("create table if not exists sessions (id text, title text, "
          "parent_session_id text, last_activity_at real, ended_at real, "
          "source text, started_at real)")
c.commit()
c.close()
PY
}
make_db

# --- el state.json de fixture: DOS pendientes, cada uno con su accion ------
write_state() {
  cat >"$ORCH/state.json" <<'EOF'
{
  "orchestrator": "test",
  "version": 1,
  "started_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-01-01T00:00:00Z",
  "pending": [
    {"kind": "features-en-marcha",
     "what": "7 features despachadas en total: falta verificar",
     "action": "esperar y verificar"},
    {"kind": "gate-rojo",
     "what": "el gate del slot 12 dio rojo",
     "action": "re-lanzar el gate con el log nuevo"}
  ],
  "slots": {
    "slot-10123": {"issue": 10123, "role": "fixer", "status": "running"}
  },
  "open_prs": {},
  "gates": {}
}
EOF
}
write_state

# --- correr el reporte ------------------------------------------------------
OUT=""; ERR=""; RC=0
run_report() {
  OUT="$(ORCH_DIR="$ORCH" LOOP_DIR="$LOOP" HERMES_HOME="$HERMES" \
        WORKTREES_DIR="$WORKTREES" GH_BIN="$TESTDIR/stub/gh" \
        GH_PR_FIXTURE="$TESTDIR/prs.json" GH_API_FIXTURE="$TESTDIR/issues.txt" \
        python3 "$HERE/daily-report.py" 2>"$TESTDIR/report.err")"
  RC=$?
  ERR="$(cat "$TESTDIR/report.err")"
}

# --- correr el estado del loop ---------------------------------------------
OUT2=""; RC2=0
run_loop_status() {
  OUT2="$(ORCH_DIR="$ORCH2" HERMES_HOME="$HERMES" WORKTREES_DIR="$WORKTREES" \
          GH_BIN="$TESTDIR/stub/gh" GH_PR_FIXTURE="$TESTDIR/prs.json" \
          GH_API_FIXTURE="$TESTDIR/issues.txt" \
          python3 "$HERE/loop-status.py" 2>&1)"
  RC2=$?
}

echo "== 1. las ACCIONES de los pendientes llegan al reporte =="
run_report
if printf '%s' "$OUT" | grep -q "esperar y verificar"; then
  ok "el reporte trae la accion del primer pendiente"
else
  bad "el reporte trae la accion del primer pendiente" "no aparece 'esperar y verificar' en el reporte"
fi
if printf '%s' "$OUT" | grep -q "re-lanzar el gate con el log nuevo"; then
  ok "el reporte trae la accion del segundo pendiente"
else
  bad "el reporte trae la accion del segundo pendiente" "no aparece 're-lanzar el gate con el log nuevo' en el reporte"
fi
if [ "$RC" -eq 0 ]; then
  ok "un reporte sin fallos sale con rc=0"
else
  bad "un reporte sin fallos sale con rc=0" "rc=$RC / $ERR"
fi

echo "== 2. los gates se leen de \$LOOP_DIR, no de un path fijo =="
# un gate en el directorio que el codigo viejo leia a mano
# ($ORCH/../solidcraft-loop/gates): si el reporte lo nombrara, estaria
# leyendo el lugar equivocado.
mkdir -p "$TESTDIR/solidcraft-loop/gates/slot-falso"
cat >"$TESTDIR/solidcraft-loop/gates/slot-falso/scope.effective.verdict" <<'EOF'
VERDICT=VERDE-SCOPE
NEW_FAILURES=0
SHA=012345678
EOF
run_report
if printf '%s' "$OUT" | grep -q "Gates en verde: 0/0"; then
  ok "con LOOP_DIR vacio el reporte dice 0 gates"
else
  bad "con LOOP_DIR vacio el reporte dice 0 gates" "$(printf '%s' "$OUT" | grep -i 'gates' | head -2)"
fi
if printf '%s' "$OUT" | grep -q "slot-falso"; then
  bad "el reporte NO lee los gates de \$ORCH/../solidcraft-loop" "menciona slot-falso"
else
  ok "el reporte NO lee los gates de \$ORCH/../solidcraft-loop"
fi
# El path de la maquina no se escribe: se construye, para que este archivo
# no tenga una ruta absoluta (el test de portabilidad las busca).
MACHINE_PATH="$HOME"
if printf '%s' "$OUT" | grep -q "$MACHINE_PATH"; then
  bad "el reporte no menciona paths de la maquina que lo larga" "$(printf '%s' "$OUT" | grep "$MACHINE_PATH" | head -2)"
else
  ok "el reporte no menciona paths de la maquina que lo larga"
fi
# y con un gate de verdad en LOOP_DIR, el reporte lo ve
mkdir -p "$LOOP/gates/slot-real"
cat >"$LOOP/gates/slot-real/scope.effective.verdict" <<'EOF'
VERDICT=VERDE-SCOPE
NEW_FAILURES=0
SHA=abcdef123
EOF
run_report
if printf '%s' "$OUT" | grep -q "slot-real"; then
  ok "un gate en \$LOOP_DIR/gates aparece en el reporte"
else
  bad "un gate en \$LOOP_DIR/gates aparece en el reporte" "$(printf '%s' "$OUT" | grep -i 'gate' | head -2)"
fi
rm -rf "$LOOP/gates/slot-real"

echo "== 3. un state.json ilegible: rc!=0 y el log dice que paso =="
mv "$ORCH/state.json" "$ORCH/state.json.bak"
run_report
if [ "$RC" -ne 0 ]; then
  ok "sin state.json el reporte sale con rc!=0 (rc=$RC)"
else
  bad "sin state.json el reporte sale con rc!=0" "rc=0"
fi
if printf '%s' "$OUT$ERR" | grep -q "state.json"; then
  ok "el log dice que fallo con el state.json"
else
  bad "el log dice que fallo con el state.json" "$(printf '%s' "$OUT$ERR" | tail -3)"
fi
if printf '%s' "$OUT" | grep -q "Pendientes: ?"; then
  ok "sin state.json el reporte dice que no sabe los pendientes (no los deja vacios)"
else
  bad "sin state.json el reporte dice que no sabe los pendientes" "$(printf '%s' "$OUT" | tail -3)"
fi
mv "$ORCH/state.json.bak" "$ORCH/state.json"

echo "== 4. el reporte se escribe atomico =="
run_report
if grep -q "os.replace" "$HERE/daily-report.py"; then
  ok "el reporte se escribe con os.replace (no in-place)"
else
  bad "el reporte se escribe con os.replace (no in-place)" "no hay os.replace en bin/daily-report.py"
fi
if ls "$ORCH/reports"/*.tmp >/dev/null 2>&1; then
  bad "no queda un .tmp colgado en reports/" "$(ls "$ORCH/reports"/*.tmp 2>/dev/null)"
else
  ok "no queda un .tmp colgado en reports/"
fi
if [ -f "$ORCH/reports/latest.md" ]; then
  ok "latest.md existe"
else
  bad "latest.md existe" "no esta en $ORCH/reports"
fi
DIARIO="$(ls "$ORCH"/reports/daily-*.md 2>/dev/null | head -1)"
if [ -n "$DIARIO" ] && cmp -s "$DIARIO" "$ORCH/reports/latest.md"; then
  ok "latest.md y el reporte del dia tienen el mismo contenido"
else
  bad "latest.md y el reporte del dia tienen el mismo contenido" "diario='$DIARIO'"
fi
if grep -q "esperar y verificar" "$ORCH/reports/latest.md" 2>/dev/null \
   && grep -q "re-lanzar el gate con el log nuevo" "$ORCH/reports/latest.md" 2>/dev/null; then
  ok "latest.md esta completo (las dos acciones estan)"
else
  bad "latest.md esta completo (las dos acciones estan)" "falta algo en latest.md"
fi

echo "== 5. loop-status con una base ilegible =="
printf 'esto no es una base sqlite\n' >"$HERMES/state.db"
run_loop_status
if [ "$RC2" -ne 0 ]; then
  ok "con la base ilegible loop-status sale con rc!=0 (rc=$RC2)"
else
  bad "con la base ilegible loop-status sale con rc!=0" "rc=0"
fi
if printf '%s' "$OUT2" | grep -q "Agentes vivos: 1"; then
  bad "un fallo de base NO es un agente vivo" "el reporte dice 'Agentes vivos: 1'"
else
  ok "un fallo de base NO es un agente vivo"
fi
if printf '%s' "$OUT2" | grep -qi "no se pudo leer la base"; then
  ok "el estado del loop dice que no pudo leer la base"
else
  bad "el estado del loop dice que no pudo leer la base" "$(printf '%s' "$OUT2" | head -5)"
fi
if printf '%s' "$OUT2" | grep -q "Agentes vivos: 0 (el loop esta parado)"; then
  bad "sin base no se afirma que el loop este parado" "dice 'Agentes vivos: 0 (el loop esta parado)'"
else
  ok "sin base no se afirma que el loop este parado"
fi

echo "== 6. loop-status con un gh que falla =="
# la base vuelve a estar bien: lo que se prueba es el gh
make_db
OUT3="$(ORCH_DIR="$ORCH2" HERMES_HOME="$HERMES" WORKTREES_DIR="$WORKTREES" \
        GH_BIN="$TESTDIR/stub/gh" GH_FAIL=1 GH_PR_FIXTURE="$TESTDIR/prs.json" \
        GH_API_FIXTURE="$TESTDIR/issues.txt" \
        python3 "$HERE/loop-status.py" 2>&1)"
RC3=$?
if [ "$RC3" -ne 0 ]; then
  ok "con un gh que falla loop-status sale con rc!=0 (rc=$RC3)"
else
  bad "con un gh que falla loop-status sale con rc!=0" "rc=0"
fi
if printf '%s' "$OUT3" | grep -q "PRs abiertos: ?"; then
  ok "un gh que falla NO es 'no hay PRs'"
else
  bad "un gh que falla NO es 'no hay PRs'" "$(printf '%s' "$OUT3" | head -8)"
fi

printf '\n%d casos, %d fallan\n' "$((PASS+FAIL))" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
