#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Lanza la app de SolidCraft con el canal de control abierto y la deja
# escuchando en un puerto, con un token que el cliente ya conoce.
#
#   launch-app.sh <binario> <puerto> <token> [display] [directorio-de-logs]
#
# El token se fija con SOLIDCRAFT_CONTROL_TOKEN (control_auth::env_token): asi
# el cliente no necesita leer el archivo de token. La carpeta de datos es
# NUEVA: los autosaves de otras corridas abririan un dialogo de recuperacion
# sobre la ventana.
#
# La app corre en su PROPIO display (por defecto :98), para no tapar la
# ventana del loop que corre a la vez.
# ---------------------------------------------------------------------------
set -uo pipefail

BIN="${1:?app binary}"
PORT="${2:?puerto}"
TOKEN="${3:?token}"
DISP="${4:-:98}"
LOGDIR="${5:-/tmp}"

XROOT="${HOME}/.local/x"
# shellcheck source=/dev/null
. "${XROOT}/env.sh"
export DISPLAY="$DISP"
export SOLIDCRAFT_GPU="${SOLIDCRAFT_GPU:-software}"
export SOLIDCRAFT_CONTROL_TOKEN="$TOKEN"

# El servidor X de este display: el socket es la prueba (xdpyinfo no esta).
XSOCK="/tmp/.X11-unix/X${DISP#:}"
if [ ! -S "$XSOCK" ]; then
  nohup "${XROOT}/start-xvfb.sh" "${DISP#:}" 1600x1000x24 >"/tmp/xvfb${DISP#:}.log" 2>&1 &
  for _ in $(seq 1 20); do
    sleep 1
    [ -S "$XSOCK" ] && break
  done
fi
[ -S "$XSOCK" ] || { echo "el servidor X en $DISP no arranco" >&2; exit 3; }

DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/solidcraft-10291.XXXXXX")"
export XDG_DATA_HOME="$DATA_DIR/data"
mkdir -p "$XDG_DATA_HOME"
export XDG_CONFIG_HOME="$DATA_DIR/config"
mkdir -p "$XDG_CONFIG_HOME"

LOG="$LOGDIR/app-10291-${PORT}.log"
echo "app: $BIN --control $PORT (display $DISP, token ${TOKEN:0:8}..., log $LOG)"
"${BIN}" --control "$PORT" >"$LOG" 2>&1 &
APP_PID=$!
echo "$APP_PID" >"$LOGDIR/app-10291-${PORT}.pid"

# El canal de control responde cuando el puerto escucha.
for _ in $(seq 1 90); do
  sleep 1
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "la app se murio al arrancar:" >&2
    tail -30 "$LOG" >&2
    exit 4
  fi
  if python3 - "$PORT" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
PY
  then
    echo "el canal de control escucha en 127.0.0.1:$PORT (pid $APP_PID)"
    exit 0
  fi
done
echo "el canal de control no abrio en el puerto $PORT:" >&2
tail -30 "$LOG" >&2
exit 5
