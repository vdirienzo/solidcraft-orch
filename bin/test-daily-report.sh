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
#
# EL STUB RESPETA --limit (2026-11-21): el reporte pedia `--limit 100` con 119
# PRs en el fork y decia 79 mergeados con 90 en GitHub. Un stub que devuelve
# TODO sin importar el limite no podia ver ese bug. `--state open` responde
# GH_PR_OPEN_FIXTURE si esta (los PRs abiertos con labels y checks).
case "${1:-}" in
  pr)
    if [ "${GH_FAIL:-0}" = "1" ]; then
      echo "gh: no autenticado" >&2
      exit 1
    fi
    fixture="${GH_PR_FIXTURE:-/dev/null}"
    limit=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "--limit" ] && limit="$a"
      if [ "$prev" = "--state" ] && [ "$a" = "open" ] && [ -n "${GH_PR_OPEN_FIXTURE:-}" ]; then
        fixture="$GH_PR_OPEN_FIXTURE"
      fi
      prev="$a"
    done
    if [ -n "$limit" ] && [ -s "$fixture" ]; then
      python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))[:int(sys.argv[2])]))' \
        "$fixture" "$limit"
    else
      cat "$fixture" 2>/dev/null
    fi ;;
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
# SIN ALERTAS (2026-11-21): loop-status sale con rc=2 cuando hay una ALERTA
# (bin/test-loop-status.sh las prueba). Aca se prueban los FALLOS de lectura:
# ningun slot libre (un slots.sh de stub) y ningun umbral de disco, para que un
# rc!=0 sea el fallo y no una alerta.
cat >"$TESTDIR/stub/slots.sh" <<'STUB'
#!/usr/bin/env bash
echo "slots_taken=0 free_slots=0 stale_locks=0"
STUB
NOALERT=(SLOTS_SH="$TESTDIR/stub/slots.sh" ALERT_DISK_MIN_GB=0 ORCH_TARGET_BASE="$ORCH2/targets")
OUT2=""; RC2=0
run_loop_status() {
  OUT2="$(env "${NOALERT[@]}" ORCH_DIR="$ORCH2" HERMES_HOME="$HERMES" WORKTREES_DIR="$WORKTREES" \
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
if [ "$RC2" -eq 1 ]; then
  ok "con la base ilegible loop-status sale con rc=1 (un fallo, no una alerta)"
else
  bad "con la base ilegible loop-status sale con rc=1" "rc=$RC2"
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
OUT3="$(env "${NOALERT[@]}" ORCH_DIR="$ORCH2" HERMES_HOME="$HERMES" WORKTREES_DIR="$WORKTREES" \
        GH_BIN="$TESTDIR/stub/gh" GH_FAIL=1 GH_PR_FIXTURE="$TESTDIR/prs.json" \
        GH_API_FIXTURE="$TESTDIR/issues.txt" \
        python3 "$HERE/loop-status.py" 2>&1)"
RC3=$?
if [ "$RC3" -eq 1 ]; then
  ok "con un gh que falla loop-status sale con rc=1 (un fallo, no una alerta)"
else
  bad "con un gh que falla loop-status sale con rc=1" "rc=$RC3"
fi
if printf '%s' "$OUT3" | grep -q "PRs abiertos: ?"; then
  ok "un gh que falla NO es 'no hay PRs'"
else
  bad "un gh que falla NO es 'no hay PRs'" "$(printf '%s' "$OUT3" | head -8)"
fi

# ===========================================================================
# LAS METRICAS (2026-11-21): las cuentas de GitHub enteras, las corridas de los
# agentes (tokens, $, turnos, rc, techos, veredicto), los claims perdidos y los
# PRs que esperan al maintainer. Las fechas se arman contra AHORA: una ventana
# de 7 dias con fechas fijas se venceria sola.
# ===========================================================================
iso_hace() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }

python3 - "$TESTDIR/prs-muchos.json" <<'PY'
import datetime, json, sys
ahora = datetime.datetime.now(datetime.timezone.utc)
z = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
prs = []
# 150 PRs: mas de una pagina de 100 (el bug de los 79 mergeados con 90).
for i in range(150):
    creado = ahora - datetime.timedelta(days=40)
    p = {"number": 1000 + i, "isDraft": False, "createdAt": z(creado), "title": f"PR {i}"}
    if i < 110:
        p["state"] = "MERGED"
        p["mergedAt"] = z(creado + datetime.timedelta(days=1))
    elif i < 135:
        p["state"] = "CLOSED"
    else:
        p["state"] = "OPEN"
    prs.append(p)
# tres merges en la ventana de 7 dias: 10, 20 y 30 horas hasta el merge
for k, horas in enumerate((10, 20, 30)):
    creado = ahora - datetime.timedelta(days=2 + k)
    prs[k].update(createdAt=z(creado), mergedAt=z(creado + datetime.timedelta(hours=horas)))
json.dump(prs, open(sys.argv[1], "w"))
PY

python3 - "$TESTDIR/prs-abiertos.json" <<'PY'
import datetime, json, sys
ahora = datetime.datetime.now(datetime.timezone.utc)
z = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
ok = [{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS", "name": "a"},
      {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SKIPPED", "name": "b"}]
rojo = ok + [{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE", "name": "c"}]
pend = ok + [{"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": "", "name": "d"}]
lbl = [{"name": "area:ui"}, {"name": "approved-for-ci"}]
def pr(n, horas, draft, checks, labels, title):
    return {"number": n, "state": "OPEN", "isDraft": draft, "labels": labels,
            "createdAt": z(ahora - datetime.timedelta(hours=horas)),
            "statusCheckRollup": checks, "title": title}
json.dump([pr(7002, 5, False, ok, [], "verde sin label"),
           pr(7001, 72, False, ok, lbl, "verde con label"),
           pr(7003, 1, True, ok, [], "draft verde"),
           pr(7004, 2, False, rojo, lbl, "rojo"),
           pr(7005, 3, False, pend, [], "pendiente")], open(sys.argv[1], "w"))
PY

# Las corridas: el .log de dispatch-slot.sh y el .jsonl de `opencode run
# --format json` (el formato medido con una llamada de verdad: step_finish
# con part.tokens.{input,output,reasoning,cache.read,cache.write} y part.cost).
mkdir -p "$ORCH/logs"
D555="$(iso_hace '-2 hours')"; E555="$(iso_hace '-1 hours')"
printf '\n===== %s dispatch-slot: issue 555, modelo m/x, techo 90 min =====\n' "$D555" >"$ORCH/logs/555-wave.log"
printf '===== %s dispatch-slot: el agente del issue 555 salio con rc=0 =====\n' "$E555" >>"$ORCH/logs/555-wave.log"
python3 - "$ORCH/logs/555-wave.jsonl" "$D555" <<'PY'
import datetime, json, sys
t0 = int(datetime.datetime.fromisoformat(sys.argv[2].replace("Z", "+00:00")).timestamp() * 1000) + 30000
def fin(i, o, cr, cw, cost):
    return {"type": "step_finish", "timestamp": t0, "sessionID": "ses_a",
            "part": {"type": "step-finish", "reason": "tool-calls", "cost": cost,
                     "tokens": {"input": i, "output": o, "reasoning": 0, "cache": {"read": cr, "write": cw}}}}
def txt(t):
    return {"type": "text", "timestamp": t0, "sessionID": "ses_a", "part": {"type": "text", "text": t}}
with open(sys.argv[1], "w") as fh:
    fh.write(json.dumps({"type": "step_start", "timestamp": t0, "sessionID": "ses_a", "part": {}}) + "\n")
    fh.write(json.dumps(fin(1000, 200, 5000, 100, 0.1)) + "\n")
    fh.write(json.dumps(txt('Un borrador: {"verdict": "blocked"} que no es el final')) + "\n")
    fh.write("esto no es json\n")
    fh.write(json.dumps(fin(2000, 300, 6000, 0, 0.2)) + "\n")
    fh.write(json.dumps(txt('Listo.\n```json\n{"verdict": "ready", "pr": 9001, "notes": "ok {x}"}\n```')) + "\n")
    fh.write('{"type":"step_fin')   # la linea cortada de un turno matado
PY
D556="$(iso_hace '-3 hours')"; E556="$(iso_hace '-2 hours')"
printf '===== %s dispatch-slot: issue 556, modelo m/x, techo 60 min =====\n' "$D556" >"$ORCH/logs/556-wave.log"
printf '===== %s dispatch-slot: el agente del issue 556 salio con rc=124 (techo de tiempo) =====\n' "$E556" >>"$ORCH/logs/556-wave.log"
python3 - "$ORCH/logs/556-wave.jsonl" "$D556" <<'PY'
import datetime, json, sys
t0 = int(datetime.datetime.fromisoformat(sys.argv[2].replace("Z", "+00:00")).timestamp() * 1000) + 30000
with open(sys.argv[1], "w") as fh:
    # entrada hostil: tokens que no son numeros, un costo en texto, un array
    fh.write(json.dumps({"type": "step_finish", "timestamp": t0, "sessionID": "ses_b",
                         "part": {"cost": "1.0", "tokens": {"input": "abc", "output": None, "cache": "x"}}}) + "\n")
    fh.write(json.dumps([1, 2, 3]) + "\n")
    fh.write(json.dumps({"type": "text", "timestamp": "ayer", "sessionID": "ses_b",
                         "part": {"text": 'sin tiempo {"no": "es un veredicto"} {roto'}}) + "\n")
PY
# una corrida EN CURSO (sin linea de salida, dentro de su techo) y una vieja
printf '===== %s dispatch-slot: issue 557, modelo m/x, techo 90 min =====\n' "$(iso_hace '-5 minutes')" >"$ORCH/logs/557-wave.log"
printf '===== %s dispatch-slot: issue 558, modelo m/x, techo 90 min =====\n' "$(iso_hace '-10 days')" >"$ORCH/logs/558-wave.log"
# los claims perdidos: uno de hoy, uno viejo y un archivo suelto que no cuenta
mkdir -p "$ORCH/logs/claims-lost/123-$(date -u +%Y%m%d-%H%M%S)" "$ORCH/logs/claims-lost/124-20200101-000000"
: >"$ORCH/logs/claims-lost/LEEME"

run_metricas() {
  OUT="$(ORCH_DIR="$ORCH" LOOP_DIR="$LOOP" HERMES_HOME="$HERMES" \
        WORKTREES_DIR="$WORKTREES" GH_BIN="$TESTDIR/stub/gh" \
        GH_PR_FIXTURE="$TESTDIR/prs-muchos.json" GH_PR_OPEN_FIXTURE="$TESTDIR/prs-abiertos.json" \
        GH_API_FIXTURE="$TESTDIR/issues.txt" \
        python3 "$HERE/daily-report.py" 2>"$TESTDIR/report.err")"
  RC=$?
  ERR="$(cat "$TESTDIR/report.err")"
}
expect() {  # expect <descripcion> <texto fijo que tiene que estar en el reporte>
  if printf '%s' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1" "falta: $2"; fi
}

echo "== 7. las cuentas de PRs son las de GitHub, mas alla de 100 =="
run_metricas
expect "con 150 PRs cuenta los 110 mergeados (no se corta en 100)" \
  "PRs: 15 abiertos (0 draft), 110 mergeados, 25 cerrados sin merge"
expect "mergeados en 7 dias y la mediana de horas hasta el merge" \
  "Mergeados en 7 d: 3; mediana hasta el merge: 20.0 h."
if [ "$RC" -eq 0 ]; then ok "el reporte con metricas sale con rc=0"; else bad "el reporte con metricas sale con rc=0" "rc=$RC / $ERR"; fi

echo "== 8. las corridas de los agentes: tokens, \$, turnos, rc, techo, veredicto =="
expect "el slot 555: tokens, cache, \$, turnos y el ULTIMO veredicto JSON" \
  "#555: 1 corrida(s), 2 turnos, 15k tokens (entrada 3k, salida 500, cache 11k/100), \$0.300; ultima: rc=0, veredicto ready (PR #9001)."
expect "el slot 556: el techo de tiempo, sin veredicto, y la entrada hostil vale 0" \
  "#556: 1 corrida(s), 1 turnos, 0 tokens (entrada 0, salida 0, cache 0/0), \$ ?, 1 por techo de tiempo; ultima: rc=124, veredicto ninguno."
expect "el slot 557 esta en curso" "#557: 1 corrida(s), 0 turnos"
if printf '%s' "$OUT" | grep -q "#557:.*ultima: en curso"; then ok "una corrida sin salida dentro de su techo esta en curso"; else bad "una corrida sin salida dentro de su techo esta en curso" "$(printf '%s' "$OUT" | grep '#557')"; fi
if printf '%s' "$OUT" | grep -q "#558:"; then bad "una corrida de hace 10 dias no entra en la ventana" "$(printf '%s' "$OUT" | grep '#558')"; else ok "una corrida de hace 10 dias no entra en la ventana"; fi
expect "la tasa de exito cuenta solo las terminadas" \
  "Corridas de agente en 7 d: 3 (1 en curso); exito 50% (1 de 2 terminadas con ready/waiting"
expect "tokens y \$ por PR mergeado en 7 dias" "Por PR mergeado (7 d): 5k tokens, \$0.100 (total 15k tokens, \$0.300"
if printf '%s' "$OUT$ERR" | grep -q "Traceback"; then bad "un .jsonl roto no rompe el reporte" "$ERR"; else ok "un .jsonl roto no rompe el reporte"; fi

echo "== 9. los claims perdidos =="
expect "los claims perdidos en 7 dias y en total (un archivo suelto no cuenta)" \
  "Claims perdidos: 1 en 7 d (2 en total)."

echo "== 10. los PRs que esperan al maintainer =="
expect "los listos y en verde, con los que no estan verdes aparte" \
  "Esperando al maintainer (listos y en verde): 2 (+2 listos con checks rojos, pendientes o sin checks):"
expect "un PR verde con approved-for-ci, con su edad" "· #7001 hace 3.0 d, approved-for-ci: si - verde con label"
expect "un PR verde sin approved-for-ci, con su edad" "· #7002 hace 5 h, approved-for-ci: NO - verde sin label"
if printf '%s' "$OUT" | grep -q "#7003\|#7004\|#7005"; then bad "ni el draft ni el rojo ni el pendiente esperan al maintainer" "$(printf '%s' "$OUT" | grep '#700[345]')"; else ok "ni el draft ni el rojo ni el pendiente esperan al maintainer"; fi
if printf '%s' "$OUT" | grep -n "#7001\|#7002" | head -1 | grep -q "#7001"; then ok "el que espera hace mas va primero"; else bad "el que espera hace mas va primero"; fi

echo "== 11. sin hermes (no hay state.db) no es un fallo =="
rm -f "$HERMES/state.db"
run_metricas
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT$ERR" | grep -q "state.db"; then
  ok "sin la base de hermes el reporte cuenta los procesos del agente y sale con rc=0"
else
  bad "sin la base de hermes el reporte cuenta los procesos del agente y sale con rc=0" "rc=$RC / $ERR"
fi
expect "sin la base, los agentes vivos son un numero" "Agentes vivos: "
if printf '%s' "$OUT" | grep -q "Agentes vivos: ?"; then bad "sin la base no dice 'Agentes vivos: ?'"; else ok "sin la base no dice 'Agentes vivos: ?'"; fi
make_db

printf '\n%d casos, %d fallan\n' "$((PASS+FAIL))" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
