#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Captures the evidence of a sketch solver change: a sketch is built in the
# app, driven through the control channel, and the window is screenshotted so
# the degrees-of-freedom readout of the sketch is visible.
#
#   capture-sketch-dof-evidence.sh <app-bin> <out.png> [display] [port]
#
# The design: a line with a length dimension whose value is zero. A length of
# zero holds the two ends of the line together, so it takes two of the line's
# degrees of freedom away (#5505).
#
# The app runs on its OWN X display (default :98), so it never covers the
# window of the loop that is running at the same time.
# ---------------------------------------------------------------------------
set -uo pipefail

BIN="${1:?app binary}"
OUT="${2:?output png}"
DISP="${3:-:98}"
PORT="${4:-0}"

# --- the WebP copy for the agent ---------------------------------------------
# The capture is written as a PNG (1600x1000) and published like that; the
# WebP sibling (same basename, 1024 px on the long side, q90) is written next
# to it: that is the one the agent reads, because it weighs 88% less and costs
# 19% fewer context tokens. Without a converter the capture does NOT fail: no
# .webp is written and the PNG is what there is.
WEBP_MAX="${WEBP_MAX:-1024}"
WEBP_QUALITY="${WEBP_QUALITY:-90}"

webp_write() {  # webp_write <png>  -> writes <png-without-extension>.webp
  local src="$1" base tmp head_hex
  [ -s "$src" ] || return 0
  base="${src%.*}"
  tmp="${base}.tmp.webp"
  rm -f "$tmp"
  if command -v cwebp >/dev/null 2>&1; then
    local cargs=(-quiet -q "$WEBP_QUALITY" -m 6 -resize "$WEBP_MAX" 0)
    case "$(cwebp -help 2>&1 || true)" in *-noalpha*) cargs+=(-noalpha) ;; esac
    cwebp "${cargs[@]}" "$src" -o "$tmp" >/dev/null 2>&1
  elif command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -loglevel error -y -i "$src" \
      -vf "scale='min(${WEBP_MAX},iw)':-2" -c:v libwebp -quality "$WEBP_QUALITY" \
      -compression_level 6 -pix_fmt yuv420p "$tmp" >/dev/null 2>&1
  elif command -v magick >/dev/null 2>&1; then
    magick "$src" -resize "${WEBP_MAX}x${WEBP_MAX}>" -quality "$WEBP_QUALITY" \
      -define webp:method=6 -alpha off "$tmp" >/dev/null 2>&1
  elif command -v convert >/dev/null 2>&1; then
    convert "$src" -resize "${WEBP_MAX}x${WEBP_MAX}>" -quality "$WEBP_QUALITY" \
      -define webp:method=6 -alpha off "$tmp" >/dev/null 2>&1
  else
    python3 - "$src" "$tmp" "$WEBP_MAX" "$WEBP_QUALITY" >/dev/null 2>&1 <<'PY'
import glob
import os
import sys

src, dst, max_dim, quality = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
try:
    from PIL import Image
except ImportError:
    # the user site-packages may not be on this python's path
    for path in glob.glob(os.path.expanduser('~/.local/lib/python*/site-packages')):
        sys.path.insert(0, path)
    from PIL import Image

image = Image.open(src)
image = image.convert('RGB')
image.thumbnail((max_dim, max_dim), Image.LANCZOS)
image.save(dst, 'WEBP', quality=quality, method=6)
PY
  fi
  # it is only published if what came out is a real WebP (RIFF....WEBP)
  head_hex="$(od -An -v -tx1 -N12 "$tmp" 2>/dev/null | tr -d ' \n')"
  case "$head_hex" in
    52494646????????57454250)
      mv -f "$tmp" "${base}.webp"
      echo "wrote ${base}.webp" >&2
      ;;
    *)
      rm -f "$tmp"
      ;;
  esac
  return 0
}

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

TOKEN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/solidcraft-evidence.XXXXXX")"
# The data folder of the app is a fresh one: the autosaves of the other runs
# would open a "recover unsaved design?" dialog over the window.
export XDG_DATA_HOME="$TOKEN_DIR/data"
mkdir -p "$XDG_DATA_HOME"

if [ "$PORT" = "0" ]; then
  PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
fi
TOKEN_FILE="$XDG_DATA_HOME/solidcraft/control/${PORT}.token"
rm -f "$TOKEN_FILE"

"${BIN}" --control "$PORT" >"/tmp/app-evidence-${PORT}.log" 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null' EXIT

for _ in $(seq 1 60); do
  sleep 1
  [ -s "$TOKEN_FILE" ] && break
done
if [ ! -s "$TOKEN_FILE" ]; then
  echo "the app did not open its control channel on $PORT" >&2
  tail -5 "/tmp/app-evidence-${PORT}.log" >&2
  exit 4
fi
TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"

say() { printf '{"id":%s,"method":"%s","params":%s,"token":"%s"}\n' "$1" "$2" "$3" "$TOKEN"; }
req() { say "$1" "$2" "$3" | timeout 60 nc 127.0.0.1 "$PORT" | head -1; }
run() { req "$1" "engine.execute" "{\"command\":\"$2\",\"params\":$3}"; }

# The sketch: a line, and a length dimension of zero on it.
run 1 "sketch.create" '{"plane":"XY"}'
run 2 "sketch.line" '{"points":[[-40,-40],[40,40]]}'

echo "--- the dimension of zero ---"
run 3 "sketch.dimension" '{"entities":["l1"],"type":"distance","value":0}'
sleep 2

echo "--- the state of the sketch ---"
req 4 "engine.execute" '{"command":"sketch.solve","params":{}}'
sleep 1
req 5 "engine.execute" '{"command":"sketch.inspect","params":{}}'
sleep 1

req 6 "ui.screenshot" "{\"path\":\"$OUT\"}"
sleep 1
[ -s "$OUT" ] || {
  echo "the screenshot was not written" >&2
  exit 5
}
webp_write "$OUT"
echo "wrote $OUT"
