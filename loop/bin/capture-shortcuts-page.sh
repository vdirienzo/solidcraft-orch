#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Screenshots the app's Keyboard Shortcuts page, optionally filtered, so a row
# with a bound key is visible. The recipe is verified.
#
#   capture-shortcuts-page.sh <out.png> [filter] [port]
#
#   out.png   where the screenshot is written
#   filter    text for the page's "Filter commands or keys" box (optional)
#   port      the control port of the running app (default: the newest token)
#
# The app must already be running with `--control <port>`, and it must be the
# ONLY instance: a second window covers the first one and the screenshot comes
# back "no frame was presented (window hidden?)".
#
# Prints the path of the PNG on stdout.
# ---------------------------------------------------------------------------
set -uo pipefail

OUT="${1:-}"
FILTER="${2:-}"
PORT="${3:-}"

if [ -z "$OUT" ]; then
  echo "usage: capture-shortcuts-page.sh <out.png> [filter] [port]" >&2
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

if [ -z "$PORT" ]; then
  TOKEN_FILE="$(ls -t "$HOME"/.local/share/solidcraft/control/*.token 2>/dev/null | head -1)"
  PORT="$(basename "${TOKEN_FILE:-none.token}" .token)"
else
  TOKEN_FILE="$HOME/.local/share/solidcraft/control/${PORT}.token"
fi

if [ ! -r "$TOKEN_FILE" ]; then
  echo "no token file for port $PORT ($TOKEN_FILE): is the app running with --control?" >&2
  exit 3
fi

TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
req() {  # req <id> <method> <params-json>
  printf '{"id":%s,"method":"%s","params":%s,"token":"%s"}\n' "$1" "$2" "$3" "$TOKEN" \
    | timeout 30 nc 127.0.0.1 "$PORT" | head -1
}

# 1. the page (editable: the one with the "+" button)
req 1 "ui.prefs" '{"open":"Keyboard Shortcuts"}' >/dev/null
sleep 1

# 2. the filter, so the row we want is at the top of the list
if [ -n "$FILTER" ]; then
  req 2 "ui.click" '{"x":855,"y":232}' >/dev/null
  sleep 1
  # the filter box keeps what the last session typed: clear it first
  for _ in $(seq 1 24); do
    req 3 "ui.key" '{"key":"Backspace"}' >/dev/null
  done
  sleep 1
  req 4 "ui.text" "{\"text\":\"${FILTER}\"}" >/dev/null
  sleep 2
fi

# 3. the screenshot
OUT_JSON="$(req 5 "ui.screenshot" "{\"path\":\"${OUT}\"}")"
printf '%s' "$OUT_JSON" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p'
printf '%s' "$OUT_JSON" | grep -q '"ok":true' || {
  echo "the screenshot failed: $OUT_JSON" >&2
  exit 4
}
webp_write "$OUT"
