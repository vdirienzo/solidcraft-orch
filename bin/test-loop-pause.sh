#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-loop-pause.sh - pausar y reanudar el loop sin tocar nada ajeno.
#
# Lo que se prueba, con un crontab STUB y procesos falsos (un "agente" en su
# propia sesion, un "gate" y un "build del usuario"):
#   1. pause saca el bloque del crontab, deja la marca y la wave no hace nada
#   2. pause --freeze congela el agente y el gate (estado T), y no el build
#      del usuario
#   3. resume los descongela, borra la marca y vuelve a poner el bloque
#   4. pause --stop corta el agente y el gate, y no el build del usuario
# LOOP_PAUSE_TAG limita el script a los procesos de este test: un agente real
# de la maquina nunca se congela ni se corta desde aca.
# Run:  bash bin/test-loop-pause.sh
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-loop-pause.XXXXXX")"
export ORCH_DIR="$TMP/orch"
# shellcheck source=/dev/null
source "$HERE/test-guard.sh"
mkdir -p "$ORCH_DIR/locks" "$TMP/stubs"

PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill -CONT -- "-$p" 2>/dev/null; kill -KILL -- "-$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0; fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FALLA- %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail+1)); }

# The crontab stub keeps the table in a file.
CRONTAB_FILE="$TMP/crontab.txt"
printf '0 * * * * echo otro-job-del-usuario\n' > "$CRONTAB_FILE"
cat > "$TMP/stubs/crontab" <<EOF
#!/usr/bin/env bash
case "\$1" in
  -l) cat "$CRONTAB_FILE" ;;
  -) cat > "$CRONTAB_FILE" ;;
esac
EOF
chmod +x "$TMP/stubs/crontab"
export PATH="$TMP/stubs:$PATH"
export LOOP_PAUSE_TAG="$TMP"

# The fake processes: each one is the leader of its own session, with a
# child, like an agent with its cargo. The tag is in their command line.
spawn() {  # $1 = a name that goes in the command line
  setsid bash -c 'sleep 300 & wait' "$1" >/dev/null 2>&1 < /dev/null &
  local p=$!
  PIDS+=("$p")
  echo "$p"
}
states() {  # the states of a session's processes
  ps -eo sid=,stat= | awk -v s="$1" '$1 == s {print substr($2,1,1)}' | sort -u | tr -d '\n'
}

bash "$HERE/install-crontab.sh" >/dev/null 2>&1
AGENT="$(spawn "$TMP/bin/agent-turn.sh")"
GATE="$(spawn "$TMP/bin/gate.sh")"
USER_BUILD="$(spawn "$TMP/my-own-cargo-build")"
sleep 0.5

# 1. pause
out="$(bash "$HERE/loop-pause.sh" pause 2>&1)"
if ! grep -q 'solidcraft-orch' "$CRONTAB_FILE" && grep -q 'otro-job-del-usuario' "$CRONTAB_FILE" \
   && [ -f "$ORCH_DIR/locks/loop-paused" ]; then
  ok "pause saca el bloque del loop (y no el resto del crontab) y deja la marca"
else
  no "pause saca el bloque del loop (y no el resto del crontab) y deja la marca" "$out / $(cat "$CRONTAB_FILE")"
fi
if [ "$(states "$AGENT")" != "T" ]; then
  ok "pause sin nivel deja correr al agente"
else
  no "pause sin nivel deja correr al agente" "$(states "$AGENT")"
fi
wave_out="$(bash "$HERE/wave.sh" --dry-run 2>&1)"
if printf '%s' "$wave_out" | grep -q 'el loop esta en pausa'; then
  ok "con la marca, la wave no hace nada"
else
  no "con la marca, la wave no hace nada" "$(printf '%s' "$wave_out" | head -3)"
fi

# 2. pause --freeze
out="$(bash "$HERE/loop-pause.sh" pause --freeze 2>&1)"
sleep 0.3
if [ "$(states "$AGENT")" = "T" ] && [ "$(states "$GATE")" = "T" ]; then
  ok "pause --freeze congela el agente y el gate (todos sus procesos)"
else
  no "pause --freeze congela el agente y el gate" "agente=$(states "$AGENT") gate=$(states "$GATE") / $out"
fi
if [ "$(states "$USER_BUILD")" != "T" ]; then
  ok "pause --freeze no toca el build del usuario"
else
  no "pause --freeze no toca el build del usuario"
fi
status="$(bash "$HERE/loop-pause.sh" status 2>&1)"
if printf '%s' "$status" | grep -q 'PAUSADO' && printf '%s' "$status" | grep -q 'estados:.*T'; then
  ok "status dice que esta en pausa y muestra los congelados"
else
  no "status dice que esta en pausa y muestra los congelados" "$status"
fi

# 3. resume
out="$(bash "$HERE/loop-pause.sh" resume 2>&1)"
sleep 0.3
if [ "$(states "$AGENT")" != "T" ] && [ "$(states "$GATE")" != "T" ] && [ ! -f "$ORCH_DIR/locks/loop-paused" ] \
   && grep -q '^# >>> solidcraft-orch >>>' "$CRONTAB_FILE" && grep -q 'otro-job-del-usuario' "$CRONTAB_FILE"; then
  ok "resume descongela, borra la marca y vuelve a poner el bloque"
else
  no "resume descongela, borra la marca y vuelve a poner el bloque" "agente=$(states "$AGENT") / $out"
fi

# 4. pause --stop
out="$(bash "$HERE/loop-pause.sh" pause --stop 2>&1)"
sleep 1
if [ -z "$(states "$AGENT")" ] && [ -z "$(states "$GATE")" ]; then
  ok "pause --stop corta el agente y el gate"
else
  no "pause --stop corta el agente y el gate" "agente=$(states "$AGENT") gate=$(states "$GATE") / $out"
fi
if [ -n "$(states "$USER_BUILD")" ]; then
  ok "pause --stop no toca el build del usuario"
else
  no "pause --stop no toca el build del usuario"
fi
bash "$HERE/loop-pause.sh" resume >/dev/null 2>&1

# Spanish aliases and usage.
if bash "$HERE/loop-pause.sh" estado >/dev/null 2>&1 && ! bash "$HERE/loop-pause.sh" cualquiera >/dev/null 2>&1; then
  ok "acepta los alias en castellano y rechaza un comando que no existe"
else
  no "acepta los alias en castellano y rechaza un comando que no existe"
fi

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ]
