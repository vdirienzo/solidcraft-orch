#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ceiling.sh - the ceiling of the context of a session, and how to move it.
#
# WHAT THE CEILING IS: OpenCode compacts a session when its context reaches
# the ceiling, and the ceiling is NOT a number of the config: it is the window
# of the model minus the buffer that is kept free.
#
#     ceiling = window - buffer
#
# The window is the context window of the model (MiniMax-M3.1-Flash: 1.000.000)
# and the buffer is `compaction.buffer` of ~/.config/opencode/opencode.json.
# With the buffer unset OpenCode keeps 15% of the window free (at least 16k),
# so the default ceiling of a 1M model is 850.000.
#
# WHY IT MATTERS: below the ceiling the context grows with every step and the
# prefix of the prompt comes from the cache, which is cheap. Above it the
# session is compacted: the prefix changes, so the next request is billed as
# FRESH input (ten times the price of the cache) and the session starts again
# from the summary. A lower ceiling makes every step cheaper and compacts
# more often. Where the balance is better is measured, not guessed
# (bin/cache-effect.py reads the history that this script writes).
#
#   ceiling.sh show             what the ceiling is now
#   ceiling.sh set 175000       move it (the buffer is computed)
#   ceiling.sh restore          put back the value before the last move
#   ceiling.sh regimes          the history of the ceiling
#
# Every move is written to logs/ceiling.log: a move without a log is a move
# nobody can measure.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"

# The directory of this script: the checker of the configuration
# (bin/config-preflight.sh) lives next to it and it is called by path,
# never by a guess.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
LOG="${LOOP_DIR}/logs/ceiling.log"
MIN_CEILING=16000

say() { printf '%s\n' "$*"; }
die() { printf 'ceiling: %s\n' "$*" >&2; exit 1; }

# The configuration is CHECKED before it is read: a value with spaces and
# no quotes breaks the source of the config.env in the middle of the file,
# so the variable is never set and the script goes on with HALF of the
# policy, in silence (set -e is not on). The check only READS the file: it
# is read twice and sourced once. If the config.env is broken, the script
# STOPS here instead of running with half of the policy.
if [ -r "$LOOP_DIR/config.env" ]; then
  if [ -x "$SCRIPT_DIR/config-preflight.sh" ]; then
    bash "$SCRIPT_DIR/config-preflight.sh" "$LOOP_DIR/config.env" || exit 2
  elif ! bash -n "$LOOP_DIR/config.env" >/dev/null 2>&1; then
    echo "ceiling: the config.env has a syntax error: $LOOP_DIR/config.env" >&2
    exit 2
  fi
fi

# --- the window of the model -------------------------------------------------
# It is in the config of the loop (CONTEXT_WINDOW), not in this script: the
# model can change, and the number belongs with the rest of the settings.
window_of_model() {
  local value
  value="$(grep -m1 '^CONTEXT_WINDOW=' "$LOOP_DIR/config.env" 2>/dev/null | cut -d= -f2 | sed 's/ *#.*//' | tr -d ' \r')"
  [ -n "$value" ] || value=1000000
  printf '%s' "$value"
}

model_of_loop() {
  local value
  value="$(grep -m1 '^MODEL=' "$LOOP_DIR/config.env" 2>/dev/null | cut -d= -f2 | sed 's/ *#.*//' | tr -d ' \r')"
  [ -n "$value" ] || value="unknown"
  printf '%s' "$value"
}

# The buffer of the config. An unset buffer is 0 here: the caller decides
# what the unset means (the default of OpenCode keeps 15% of the window free).
buffer_of_config() {
  [ -f "$CONFIG" ] || { printf '0'; return 0; }
  python3 - "$CONFIG" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, ValueError):
    data = {}
compaction = data.get("compaction") or {}
buffer = compaction.get("buffer")
print(buffer if isinstance(buffer, int) else 0)
PY
}

write_config() {
  # $1: the new buffer. The file is written to a temporary one and moved:
  # OpenCode watches the config and reads it at any moment, and a half
  # written config is a broken one.
  python3 - "$CONFIG" "$1" <<'PY'
import json
import os
import sys

path, buffer = sys.argv[1], int(sys.argv[2])
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, ValueError):
    data = {}
compaction = data.get("compaction")
if not isinstance(compaction, dict):
    compaction = {}
    data["compaction"] = compaction
compaction["buffer"] = buffer
temporary = path + ".tmp.%d" % os.getpid()
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
os.replace(temporary, path)
PY
}

log_change() {
  # $1: the buffer before. $2: the buffer after. $3: the ceiling. $4: the note.
  # The log is the history the analysis reads.
  local iso model
  iso="$(date -u +%FT%H:%M:%SZ)"
  model="$(model_of_loop)"
  mkdir -p "$(dirname "$LOG")"
  printf 'iso=%s ceiling=%s buffer=%s model=%s note=%s\n' \
    "$iso" "$3" "$2" "$model" "$4" >> "$LOG"
}

ceiling_of() {
  local window buffer
  window="$(window_of_model)"
  buffer="$(buffer_of_config)"
  if [ "$buffer" -eq 0 ]; then
    # The buffer is unset: OpenCode keeps 15% of the window free (at least
    # 16k), so the ceiling is 85% of the window.
    printf '%s' "$((window - window / 20))"
  else
    printf '%s' "$((window - buffer))"
  fi
}

case "${1:-show}" in
  show)
    window="$(window_of_model)"
    buffer="$(buffer_of_config)"
    ceiling="$(ceiling_of)"
    say "config:    $CONFIG"
    say "model:     $(model_of_loop)"
    say "window:    $window tokens"
    say "buffer:    $buffer tokens"
    say "ceiling:   $ceiling tokens"
    ;;
  set)
    target="${2:-}"
    case "$target" in ''|*[!0-9]*) die "the ceiling must be a number of tokens" ;; esac
    window="$(window_of_model)"
    [ "$target" -ge "$MIN_CEILING" ] || die "the ceiling must be at least $MIN_CEILING tokens"
    [ "$target" -lt "$window" ] || die "the ceiling must be below the window ($window)"
    current="$(ceiling_of)"
    if [ "$current" = "$target" ]; then
      say "the ceiling is already $target tokens: nothing to do"
      exit 0
    fi
    backup="$CONFIG.bak-ceiling-$(date -u +%Y%m%d-%H%M%S)"
    cp -p "$CONFIG" "$backup" 2>/dev/null || true
    old_buffer="$(buffer_of_config)"
    write_config "$((window - target))"
    log_change "$old_buffer" "$((window - target))" "$target" \
      "${3:-the ceiling moved from $current to $target}"
    say "the ceiling is now $target tokens (buffer $((window - target)))"
    say "the previous config is in $backup"
    ;;
  restore)
    backup="$(ls -1t "$CONFIG".bak-ceiling-* 2>/dev/null | head -1)"
    [ -n "$backup" ] || die "there is no backup of the config to restore"
    window="$(window_of_model)"
    previous="$(buffer_of_config)"
    cp -p "$backup" "$CONFIG.tmp" && mv -f "$CONFIG.tmp" "$CONFIG"
    restored="$(ceiling_of)"
    log_change "$previous" "$(buffer_of_config)" "$restored" \
      "the ceiling was restored from $(basename "$backup")"
    say "the ceiling is back to $restored tokens (the buffer was $previous)"
    ;;
  regimes)
    [ -f "$LOG" ] || die "there is no history of the ceiling ($LOG)"
    cat "$LOG"
    ;;
  *)
    die "unknown command: $1 (show, set, restore, regimes)"
    ;;
esac
