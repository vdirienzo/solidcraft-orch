#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Borra las sesiones de vuelta del loop que quedaron huérfanas.
#
# POR QUÉ: cuando un turno muere (el presupuesto de 55 min se agota, o systemd
# lo mata), su sesión `ses_loop-*` queda en la base con una vuelta a medias.
# El servidor de OpenCode RESUME esas sesiones al arrancar: la vuelta muerta
# vuelve a trabajar, despacha workers, toca el checkout y compila, pero sin
# presupuesto, sin estado, sin gate y sin que nadie recoja su delta. Con el
# loop desatendido eso es trabajo fantasma que compite con la vuelta real por
# el checkout y por el lock del target dir de cargo.
#
# Observed: the 08:40 turn was killed at 09:35 and its session was resumed by
# the server of the next turn, which dispatched a worker at 10:44 that was
# still running three hours later.
#
# QUÉ BORRA: sólo las sesiones `ses_loop-*` (las vueltas del loop) y sus
# hijas. NUNCA las sesiones del humano (`ses_e...` de la TUI): el janitor
# tiene la misma regla.
#
# CÓMO SE USA:
#   sweep-orphans.sh [sesion_a_conservar]
# El supervisor lo llama antes de cada vuelta (ExecStartPre del unit): en ese
# momento no hay ninguna vuelta en curso, así que todas las `ses_loop-*` son
# de turnos anteriores y se pueden borrar.
#
# EL SLOT: con dos slots hay dos vueltas en curso a la vez, y cada una tiene
# su propia sesión `ses_loop-<stamp>-<slot>`. Borrar las del otro slot sería
# matar su trabajo: la sesión del otro slot se borra SOLO si su turno ya no
# está vivo (no hay proceso opencode con esa sesión) y su lock está libre.
# El slot 0 (SLOT sin definir o "0") conserva el comportamiento de antes:
# borra todas las sesiones de vuelta que no sean la suya.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"

# The directory of this script: the checker of the configuration
# (bin/config-preflight.sh) lives next to it and it is called by path,
# never by a guess.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/.opencode/bin:$PATH"

# The configuration is CHECKED before it is sourced: a value with spaces
# and no quotes breaks the source in the middle of the file, so the
# variable is never set and the script goes on with HALF of the policy, in
# silence (set -e is not on). The check only READS the file: the config.env
# is read twice and sourced once. If the config.env is broken, the script
# STOPS here instead of running with half of the policy.
if [ -r "$LOOP_DIR/config.env" ]; then
  if [ -x "$SCRIPT_DIR/config-preflight.sh" ]; then
    bash "$SCRIPT_DIR/config-preflight.sh" "$LOOP_DIR/config.env" || exit 2
  elif ! bash -n "$LOOP_DIR/config.env" >/dev/null 2>&1; then
    echo "sweep-orphans: the config.env has a syntax error: $LOOP_DIR/config.env" >&2
    exit 2
  fi
fi

# config.env es la fuente de verdad del path del repo.
if [ -f "$LOOP_DIR/config.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$LOOP_DIR/config.env"
  set +a
fi
REPO="${REPO:-$HOME/solidcraft}"

KEEP="${1:-}"
SLOT="${SLOT:-0}"

# La lista de sesiones es por proyecto: el cwd decide cuáles se ven. El loop
# vive en $REPO, y sus sesiones están ahí.
cd "$REPO" 2>/dev/null || cd "$LOOP_DIR" || exit 0

# El turno de un slot está vivo si su lock está tomado: el supervisor toma
# `flock -n` sobre `.lock.<slot>` mientras dura su vuelta.
slot_busy() { # slot -> 0 si el lock del slot está tomado
  local slot="$1"
  [ -e "$LOOP_DIR/.lock.$slot" ] || return 1
  flock -n "$LOOP_DIR/.lock.$slot" -c true 2>/dev/null && return 1
  return 0
}

# El slot de una sesión: el session id es `ses_loop-<stamp>-slot<S>` (el
# supervisor lo compone con el slot). Las sesiones viejas (sin slot) son
# del layout de un solo slot: se tratan como slot 0.
slot_of_session() { # sid -> "0" | "1" | ...
  case "$1" in
    *-slot0) echo "0" ;;
    *-slot1) echo "1" ;;
    *-slot*) echo "${1##*-slot}" ;;
    *) echo "0" ;;
  esac
}

deleted=0
kept=0
while read -r sid; do
  [ -n "$sid" ] || continue
  [ "$sid" = "$KEEP" ] && continue
  sid_slot="$(slot_of_session "$sid")"
  # Una sesión de otro slot solo se borra si ese slot no tiene una vuelta
  # viva: con dos slots, borrar la sesión del otro es matar su trabajo.
  if [ "$sid_slot" != "$SLOT" ] && slot_busy "$sid_slot"; then
    echo "sweep: kept $sid (slot $sid_slot has a live turn)"
    kept=$((kept + 1))
    continue
  fi
  # La sesión del PROPIO slot se borra: la vuelta anterior ya terminó y la
  # nueva crea su propia sesión (un id nuevo). Lo que NO se puede es borrar
  # la sesión de la vuelta que va a empezar, y eso no ocurre: el id lleva el
  # pid, así que cada vuelta tiene el suyo.
  if opencode session delete "$sid" >/dev/null 2>&1; then
    echo "sweep: deleted $sid"
    deleted=$((deleted + 1))
  fi
done < <(opencode session list 2>/dev/null | awk '$1 ~ /^ses_loop-/ {print $1}')

echo "sweep: $deleted stale loop session(s) deleted (kept: ${KEEP:-none}; slot ${SLOT}; kept for live slots: $kept)"
exit 0
