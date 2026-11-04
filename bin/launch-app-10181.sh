#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Lanza la app de la rama del PR #10594 con el canal de control abierto y
# espera a que el token aparezca.
#
#   launch-app-10181.sh <bin> <port> <token> <display> [logfile]
#
# El token se fija con SOLIDCRAFT_CONTROL_TOKEN (control_auth::env_token), asi
# que el cliente y la app usan el mismo sin leer el archivo de token.
# ---------------------------------------------------------------------------
set -uo pipefail

BIN="${1:?app binary}"
PORT="${2:?port}"
TOKEN="${3:?token}"
DISP="${4:-:99}"
LOG="${5:-/tmp/app-10181-${PORT}.log}"

XROOT="${HOME}/.local/x"
# shellcheck source=/dev/null
. "${XROOT}/env.sh"
export DISPLAY="$DISP"
export SOLIDCRAFT_GPU="${SOLIDCRAFT_GPU:-software}"
export SOLIDCRAFT_RENDERER="${SOLIDCRAFT_RENDERER:-cpu}"
export SOLIDCRAFT_CONTROL_TOKEN="$TOKEN"

if [ ! -x "$BIN" ]; then
  echo "no app binary at $BIN" >&2
  exit 2
fi

XSOCK="/tmp/.X11-unix/X${DISP#:}"
if [ ! -S "$XSOCK" ]; then
  echo "the X server on $DISP is not running" >&2
  exit 3
fi

# Los datos de la app: una carpeta nueva, para que no aparezca el dialogo de
# recuperar un diseno sin guardar de otra corrida.
DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/solidcraft-10181.XXXXXX")"
export XDG_DATA_HOME="$DATA_DIR/data"
mkdir -p "$XDG_DATA_HOME"
echo "data dir: $DATA_DIR" >&2

"$BIN" --control "$PORT" >"$LOG" 2>&1 &
APP_PID=$!
echo "$APP_PID" > "/tmp/app-10181-${PORT}.pid"
echo "app pid $APP_PID (log $LOG)" >&2

# El canal responde: un socket escuchando en el puerto.
for _ in $(seq 1 90); do
  sleep 1
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "the app exited" >&2
    tail -20 "$LOG" >&2
    exit 4
  fi
  if python3 -c "
import socket,sys
s=socket.socket()
s.settimeout(1)
sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT))==0 else 1)
" 2>/dev/null; then
    echo "the control channel is listening on 127.0.0.1:$PORT" >&2
    tail -5 "$LOG" >&2
    exit 0
  fi
done
echo "the control channel did not open on $PORT" >&2
tail -20 "$LOG" >&2
exit 5
