#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Captures the app's Keyboard Shortcuts page (Preferences > Shortcuts) and
# reports the key bound to a command. The recipe is verified: it opens the
# page, binds a key, screenshots it and reads the binding back.
#
#   capture-shortcuts.sh <command-id> <out.png> [key] [port]
#
#   command-id   the command whose "+" button is used (a VISIBLE row, e.g.
#                sketch.rectangle.center or sketch.line)
#   out.png      where the screenshot is written
#   key          the key to bind (default: ShiftLeft)
#   port         a free control port (default: one is picked)
#
# It talks to an app that is ALREADY running with `--control <port>`: this
# script does not start one (the caller decides, because only one instance may
# run at a time: a second window covers the first and the screenshot comes
# back "no frame was presented").
#
# Prints the bound key on stdout (e.g. `Shift+ShiftLeft` or `Shift`): that is
# the assertion the PR body quotes.
# ---------------------------------------------------------------------------
set -uo pipefail

CMD_ID="${1:-}"
OUT="${2:-}"
KEY="${3:-ShiftLeft}"
PORT="${4:-}"

if [ -z "$CMD_ID" ] || [ -z "$OUT" ]; then
  echo "usage: capture-shortcuts.sh <command-id> <out.png> [key] [port]" >&2
  exit 2
fi

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

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
TOKEN_FILE="$HOME/.local/share/solidcraft/control/${PORT}.token"

if [ -z "$PORT" ]; then
  # the newest token file wins: that is the app that is running now
  TOKEN_FILE="$(ls -t "$HOME"/.local/share/solidcraft/control/*.token 2>/dev/null | head -1)"
  PORT="$(basename "${TOKEN_FILE:-none.token}" .token)"
fi

if [ ! -r "$TOKEN_FILE" ]; then
  echo "no token file for port $PORT ($TOKEN_FILE): is the app running with --control?" >&2
  exit 3
fi

TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
say() { printf '{"id":%s,"method":"%s","params":%s,"token":"%s"}\n' "$1" "$2" "$3" "$TOKEN"; }

req() {  # req <id> <method> <params-json>
  printf '{"id":%s,"method":"%s","params":%s,"token":"%s"}\n' "$1" "$2" "$3" "$TOKEN" \
    | timeout 30 nc 127.0.0.1 "$PORT" | head -1
}

# 1. open the shortcuts page (editable: this is the one with the "+" button)
req 1 "ui.prefs" '{"open":"Keyboard Shortcuts"}' >/dev/null
sleep 1

# 2. the "+" button of the row
AT="$(req 2 "ui.at" "{\"handle\":\"keymap:capture:${CMD_ID}\"}")"
XY="$(printf '%s' "$AT" | sed -n 's/.*"result":\[\([0-9.]*\),\([0-9.]*\)\].*/\1 \2/p')"
if [ -z "$XY" ]; then
  echo "could not find the capture handle for ${CMD_ID}: $AT" >&2
  exit 4
fi
X="$(printf '%s' "$XY" | cut -d' ' -f1)"
Y="$(printf '%s' "$XY" | cut -d' ' -f2)"

# 3. click it (starts the capture) and press the key
req 3 "ui.click" "{\"x\":${X},\"y\":${Y}}" >/dev/null
sleep 1
req 4 "ui.key" "{\"key\":\"${KEY}\",\"shift\":true}" >/dev/null
sleep 1

# 4. the screenshot and the binding
req 5 "ui.screenshot" "{\"path\":\"${OUT}\"}" >/dev/null
webp_write "$OUT"
SHORTCUT="$(req 6 "ui.shortcut" "{\"command\":\"${CMD_ID}\"}")"
printf '%s' "$SHORTCUT" | sed -n 's/.*"key":"\([^"]*\)".*/\1/p'
