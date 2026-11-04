#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Levanta la app de SolidCraft con el canal de control para capturar evidencia.
#
#   run-evidence-app.sh <app-bin> <port> [display]
#
# El token se fija con SOLIDCRAFT_CONTROL_TOKEN (>=32 caracteres), asi el
# cliente y la app usan el mismo sin leer el archivo de token.
#
# XDG_DATA_HOME apunta a una carpeta nueva: los autosaves de otras corridas
# abririan un dialogo "recuperar diseno sin guardar?" sobre la ventana.
# ---------------------------------------------------------------------------
set -uo pipefail

BIN="${1:?app binary}"
PORT="${2:?control port}"
DISP="${3:-:98}"

XROOT="${HOME}/.local/x"
# shellcheck source=/dev/null
. "${XROOT}/env.sh"
export DISPLAY="$DISP"
export SOLIDCRAFT_GPU="${SOLIDCRAFT_GPU:-software}"

if [ ! -x "$BIN" ]; then
  echo "no app binary at $BIN" >&2
  exit 2
fi

XSOCK="/tmp/.X11-unix/X${DISP#:}"
if [ ! -S "$XSOCK" ]; then
  nohup "${XROOT}/start-xvfb.sh" "${DISP#:}" 1600x1000x24 >"/tmp/xvfb${DISP#:}.log" 2>&1 &
  for _ in $(seq 1 20); do
    sleep 1
    [ -S "$XSOCK" ] && break
  done
fi
[ -S "$XSOCK" ] || {
  echo "the X server on $DISP did not start" >&2
  exit 3
}

DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/solidcraft-evidence-10159.XXXXXX")"
export XDG_DATA_HOME="$DATA_DIR/data"
mkdir -p "$XDG_DATA_HOME"
echo "XDG_DATA_HOME=$XDG_DATA_HOME"

export SOLIDCRAFT_CONTROL_TOKEN="${SOLIDCRAFT_CONTROL_TOKEN:-$(openssl rand -hex 32)}"
echo "SOLIDCRAFT_CONTROL_TOKEN=$SOLIDCRAFT_CONTROL_TOKEN"

LOG="/tmp/app-evidence-10159-${PORT}.log"
"${BIN}" --control "$PORT" >"$LOG" 2>&1 &
APP_PID=$!
echo "APP_PID=$APP_PID"
echo "LOG=$LOG"

for _ in $(seq 1 60); do
  sleep 1
  if grep -q "control server listening on 127.0.0.1:${PORT}" "$LOG" 2>/dev/null; then
    echo "CONTROL_READY port=$PORT"
    # La ventana necesita un momento para aparecer (el canal abre antes).
    sleep 4
    exit 0
  fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "the app exited before opening its control channel" >&2
    tail -30 "$LOG" >&2
    exit 4
  fi
done
echo "the app did not open its control channel on $PORT" >&2
tail -30 "$LOG" >&2
exit 5
