#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-loop-status.sh - las ALERTAS del estado del loop.
#
# POR QUE ESTE ARCHIVO EXISTE (2026-11-21): el estado del loop decia "todo
# bien" con el loop parado. El 21-11 el crontab corria los .py con bash
# ("import: command not found" en cada corrida), la wave no despachaba nada
# con dos slots libres y nadie se entero. bin/loop-status.py ahora imprime
# `ALERTA: ...` arriba de todo y sale con rc=2 cuando:
#   1. no se despacho ningun agente en 2 h con slots libres, y la wave
#      encuentra candidatos (o su selector falla, o la wave no corre);
#   2. un log de cron repite la misma linea de error en sus ultimas corridas;
#   3. un slot en vuelo (estado `running` o lock) no tiene a nadie trabajando;
#   4. el disco de los targets tiene menos de 15 GB libres.
# Las pruebas de los FALLOS de lectura (base ilegible, gh que falla) siguen en
# bin/test-daily-report.sh, junto con las del reporte diario.
#
# HERMETICO: ORCH_DIR, HERMES_HOME, WORKTREES_DIR y ORCH_TARGET_BASE son
# directorios de prueba; gh y slots.sh son stubs FUERA del PATH (GH_BIN,
# SLOTS_SH). GitHub no se toca nunca. bin/slot-busy.sh es el de verdad: un
# proceso de prueba trabaja en un worktree de prueba.
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-loop-status.XXXXXX")"
PASS=0
FAIL=0
BG=""

cleanup() {
  [ -n "$BG" ] && kill "$BG" 2>/dev/null
  rm -rf "$TESTDIR"
}
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf '  FALLO - %s\n' "$1"
  if [ "$#" -gt 1 ]; then printf '         %s\n' "$2"; fi
}

mkdir -p "$TESTDIR/stub"
cat >"$TESTDIR/stub/gh" <<'STUB'
#!/usr/bin/env bash
# gh de prueba: ningun PR abierto, nunca la red.
printf '[]\n'
exit 0
STUB
cat >"$TESTDIR/stub/slots.sh" <<'STUB'
#!/usr/bin/env bash
# slots.sh de prueba: los slots libres los elige el test.
echo "slots_taken=0 free_slots=${STUB_FREE:-0} stale_locks=0"
STUB
chmod +x "$TESTDIR/stub/gh" "$TESTDIR/stub/slots.sh"

ORCH="$TESTDIR/orch"
LOGS="$ORCH/logs"
WT="$TESTDIR/worktrees"
mkdir -p "$LOGS" "$ORCH/locks" "$TESTDIR/hermes" "$WT"
cat >"$TESTDIR/crons.txt" <<'EOF'
# los crons de prueba (el formato de bin/crons.txt)
solidcraft-pipeline   | 2,7,12,17,22,27,32,37,42,47,52,57 * * * * | bin/pipeline.py    | pipeline | x
solidcraft-loop-status| 6,36 * * * *        | bin/loop-status.py | -        | x
solidcraft-wave       | */10 * * * *        | bin/wave.sh        | -        | x
EOF
echo '{"slots": {}}' >"$ORCH/state.json"

OUT=""; RC=0
run() {  # run [VAR=valor ...]: el estado del loop con el entorno de prueba
  OUT="$(env ORCH_DIR="$ORCH" HERMES_HOME="$TESTDIR/hermes" WORKTREES_DIR="$WT" \
        ORCH_TARGET_BASE="$ORCH/targets" GH_BIN="$TESTDIR/stub/gh" \
        SLOTS_SH="$TESTDIR/stub/slots.sh" CRONS_TXT="$TESTDIR/crons.txt" \
        ALERT_DISK_MIN_GB=0 STUB_FREE=0 "$@" \
        python3 "$HERE/loop-status.py" 2>&1)"
  RC=$?
}
has()    { if printf '%s' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1" "falta '$2' en: $(printf '%s' "$OUT" | grep -E 'ALERTA|despacho' | head -4)"; fi; }
hasnt()  { if printf '%s' "$OUT" | grep -qF -- "$2"; then bad "$1" "$(printf '%s' "$OUT" | grep -F -- "$2" | head -2)"; else ok "$1"; fi; }
iso_hace() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }
despacho() {  # despacho <issue> <cuando>
  printf '\n===== %s dispatch-slot: issue %s, modelo m/x, techo 90 min =====\n' "$(iso_hace "$2")" "$1" >>"$LOGS/$1-wave.log"
}
salida() {  # salida <issue> <cuando>
  printf '===== %s dispatch-slot: el agente del issue %s salio con rc=0 =====\n' "$(iso_hace "$2")" "$1" >>"$LOGS/$1-wave.log"
}

echo "== 1. sin nada raro: ninguna alerta y rc=0 =="
run
if [ "$RC" -eq 0 ]; then ok "sin alertas ni fallos sale con rc=0"; else bad "sin alertas ni fallos sale con rc=0" "rc=$RC: $OUT"; fi
hasnt "sin alertas no hay ninguna linea ALERTA" "ALERTA"
has "dice que no hay despachos registrados" "Ultimo despacho: ninguno registrado"

echo "== 2. ningun despacho en 2 h con slots libres =="
# El ultimo turno de la wave, con los mensajes de bin/wave.sh: encontro
# issues y no pudo prepararlos.
cat >"$LOGS/cron-solidcraft-wave.log" <<'EOF'
wave: kill-orphan-browsers: 0 navegador(es) huerfano(s), 0 muerto(s)
wave: free_slots=2
wave: el issue #4242 no se pudo preparar (prepare-slot rc=3, fallo 1 de 3): se prueba el siguiente
wave:     prepare-slot: el issue #4242 no está libre (claim-verify rc=2): VEREDICTO=ERROR no se pudo leer los PRs
wave: el issue #4243 no se pudo preparar (prepare-slot rc=3, fallo 2 de 3): se prueba el siguiente
wave: 3 intentos fallaron en este turno: se para aca (los probados: 4242,4243)
EOF
despacho 100 '-3 hours'
run STUB_FREE=2
has "con candidatos que no se despachan hay ALERTA" \
  "ALERTA: ningun agente despachado hace 3.0 h con 2 slot(s) libre(s): la wave encuentra issues y no los despacha (prepare-slot: el issue #4242"
if [ "$RC" -eq 2 ]; then ok "una alerta sale con rc=2"; else bad "una alerta sale con rc=2" "rc=$RC"; fi
if printf '%s\n' "$OUT" | sed -n 2p | grep -q '^ALERTA'; then ok "la alerta va arriba de todo (la linea 2)"; else bad "la alerta va arriba de todo" "$(printf '%s\n' "$OUT" | sed -n 2p)"; fi
run STUB_FREE=0
hasnt "sin slots libres no se espera ningun despacho" "ningun agente despachado"
despacho 101 '-30 minutes'
run STUB_FREE=2
hasnt "con un despacho hace 30 min no hay alerta" "ningun agente despachado"
has "dice cuando fue el ultimo despacho" "Ultimo despacho: hace 0.5 h (#101)"
rm -f "$LOGS/101-wave.log"

# El turno dijo que no hay issues libres, y el turno SIGUIENTE ya empezo (sus
# lineas de retomar un slot no son la fase 4 del turno anterior).
cat >"$LOGS/cron-solidcraft-wave.log" <<'EOF'
wave: free_slots=2
wave: no hay ningún issue libre que valga un agente ahora
wave: kill-orphan-browsers: 0 navegador(es) huerfano(s), 0 muerto(s)
wave: el slot 19690 no se pudo preparar (prepare-slot rc=3, fallo 1 de 3): se sigue con los issues nuevos
EOF
run STUB_FREE=2
hasnt "sin issues libres no hay alerta de despacho" "ningun agente despachado"
has "dice que la wave no encuentra issues" "La wave no encuentra issues libres (no es una alerta)."

cat >"$LOGS/cron-solidcraft-wave.log" <<'EOF'
wave: free_slots=2
wave: no hay ningún issue libre que valga un agente ahora
wave:     next-issue: no se pudo leer el upstream
EOF
run STUB_FREE=2
has "un selector que falla es una alerta (no es 'no hay issues')" \
  "el selector de issues falla (next-issue: no se pudo leer el upstream)"

touch -d '-2 hours' "$LOGS/cron-solidcraft-wave.log"
run STUB_FREE=2
has "una wave que no escribe su log hace 2 h no corre" "y la wave no corre: su log no se escribe hace 120 min"
rm -f "$LOGS/cron-solidcraft-wave.log"
run STUB_FREE=2
has "sin log de la wave tambien es una alerta" "y la wave no tiene log"
rm -f "$LOGS/100-wave.log"

echo "== 3. un cron que repite el mismo error en sus ultimas corridas =="
corrida_rota() {
  cat <<'EOF'
bin/pipeline.py: line 3: $'\npipeline.py - el eslabon': command not found
bin/pipeline.py: line 60: import: command not found
bin/pipeline.py: line 61: import: command not found
bin/pipeline.py: line 70: syntax error near unexpected token `('
EOF
}
: >"$LOGS/cron-solidcraft-pipeline.log"
for _ in 1 2 3; do corrida_rota >>"$LOGS/cron-solidcraft-pipeline.log"; done
run
has "tres corridas con el mismo error son una alerta" \
  "ALERTA: el cron solidcraft-pipeline repite el mismo error (3 veces, tambien en su ultima corrida):"
has "la alerta nombra la causa: bash corriendo un .py" "bash esta corriendo un .py"
: >"$LOGS/cron-solidcraft-pipeline.log"
for _ in 1 2; do corrida_rota >>"$LOGS/cron-solidcraft-pipeline.log"; done
run
hasnt "dos corridas no son tres" "solidcraft-pipeline repite"
corrida_rota >>"$LOGS/cron-solidcraft-pipeline.log"
for i in 1 2 3 4 5 6 7 8; do echo "pipeline: PR $i al dia" >>"$LOGS/cron-solidcraft-pipeline.log"; done
run
hasnt "un cron arreglado (su ultima corrida no tiene el error) no alerta" "solidcraft-pipeline repite"
: >"$LOGS/cron-solidcraft-pipeline.log"
for _ in 1 2 3; do corrida_rota >>"$LOGS/cron-solidcraft-pipeline.log"; done
touch -d '-1 hour' "$LOGS/cron-solidcraft-pipeline.log"
run
hasnt "un log que no se escribe hace dos intervalos del cron no alerta" "solidcraft-pipeline repite"
rm -f "$LOGS/cron-solidcraft-pipeline.log"
# El log del propio estado tiene las ALERTAS que cita: no se cuentan.
for _ in 1 2 3; do
  printf 'SolidCraft - estado del loop (10:00)\nALERTA: el cron x repite el mismo error: line 1: import: command not found\n' \
    >>"$LOGS/cron-solidcraft-loop-status.log"
done
run
hasnt "las ALERTAS citadas en el log del estado no son errores del estado" "solidcraft-loop-status repite"
: >"$LOGS/cron-solidcraft-loop-status.log"
for _ in 1 2 3; do
  printf 'PRs abiertos: 1\n  · #9 VERDE - Kernel: a KeyError on import no longer crashes\n' \
    >>"$LOGS/cron-solidcraft-loop-status.log"
done
run
hasnt "el titulo de un PR en una lista no es un error del cron" "solidcraft-loop-status repite"
rm -f "$LOGS/cron-solidcraft-loop-status.log"
# Un Traceback de Python y un VEREDICTO=ERROR tambien son errores.
for i in 1 2 3; do
  printf 'pipeline: corrida %s\nTraceback (most recent call last):\n  File "x", line 1\nKeyError: %s\n' "$i" "'k'" \
    >>"$LOGS/cron-solidcraft-pipeline.log"
done
run
has "un Traceback repetido es una alerta" "solidcraft-pipeline repite el mismo error (3 veces"
rm -f "$LOGS/cron-solidcraft-pipeline.log"

echo "== 4. un slot en vuelo cuyo agente no esta =="
mkdir -p "$WT/issue-777"
cat >"$ORCH/state.json" <<EOF
{"slots": {"777": {"issue": 777, "status": "running", "worktree": "$WT/issue-777",
                   "target_dir": "$ORCH/targets/slot-777"},
           "778": {"issue": 778, "status": "saved"}}}
EOF
despacho 777 '-2 hours'
run
has "un slot running sin nadie trabajando es una alerta" \
  "ALERTA: el slot 777 esta en vuelo (estado) y su agente NO esta"
hasnt "un slot guardado no es un slot en vuelo" "slot 778"
( cd "$WT/issue-777" && exec sleep 120 ) &
BG=$!
sleep 0.3
run
hasnt "con un proceso trabajando en el worktree no hay alerta" "el slot 777 esta en vuelo"
kill "$BG" 2>/dev/null; wait "$BG" 2>/dev/null; BG=""
salida 777 '-5 minutes'
run
hasnt "un agente que salio hace 5 min no es alerta (la wave lo cierra)" "ALERTA: el slot 777"
has "el estado dice que la wave lo cierra" "el agente salio hace 5 min: la wave lo cierra"
echo '{"slots": {}}' >"$ORCH/state.json"
rm -f "$LOGS/777-wave.log"
mkdir -p "$ORCH/locks/slot-779"
echo "wave-1" >"$ORCH/locks/slot-779/owner"
iso_hace '-1 hours' >"$ORCH/locks/slot-779/since"
run
has "un lock de slot sin nadie trabajando es una alerta" "ALERTA: el slot 779 esta en vuelo (lock)"
rm -rf "$ORCH/locks/slot-779"

echo "== 5. el disco de los targets =="
run ALERT_DISK_MIN_GB=100000000
has "con menos libre que el umbral hay alerta" "ALERTA: quedan"
has "la alerta dice que hacer" "bin/gc-disk.sh o liberar slots"
run ALERT_DISK_MIN_GB=abc
if printf '%s' "$OUT" | grep -q "Traceback"; then bad "un umbral que no es numero no rompe el estado" "$OUT"; else ok "un umbral que no es numero no rompe el estado"; fi
has "un umbral que no es numero usa el de la maquina (15 GB)" "(alerta bajo 15 GB)"

echo "== 6. todo junto vuelve a estar limpio =="
run
if [ "$RC" -eq 0 ]; then ok "sin nada raro vuelve a salir con rc=0"; else bad "sin nada raro vuelve a salir con rc=0" "rc=$RC: $(printf '%s' "$OUT" | grep ALERTA)"; fi

printf '\n%d casos, %d fallan\n' "$((PASS+FAIL))" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
