#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-guard.sh - una suite que escribe estado nunca lo escribe en el
# orquestador vivo.
#
# POR QUE (2026-11-21): bin/test-orch-state.sh escribia su fixture sobre
# "$ORCH_DIR/history.jsonl", y ORCH_DIR era el directorio del orquestador de
# verdad (en esta maquina el repo y $HOME/.local/share/solidcraft-orch son el
# mismo directorio, por un symlink). La suite borro el historial del loop el
# 20-11-2026, y el repo manda correr la suite antes de cada commit. El arreglo
# de esa linea no protege a la proxima: este guardia si. Cada suite que le da
# un ORCH_DIR a un script que escribe (state/, state.json, history.jsonl,
# locks/, gates/, logs/) lo pasa por aca ANTES de escribir.
#
# USO (se hace source, no se ejecuta):
#   source "$HERE/test-guard.sh"
#   export ORCH_DIR="$TMP/orch"
#   test_guard_orch_dir                 # mira $ORCH_DIR
#   test_guard_orch_dir "$A" "$B"       # o los directorios que se le pasen
#
# Sale con 2 (la suite no corre) si alguno resuelve, con readlink -f, a:
#   - el directorio de este repo (el padre de este bin/): es el vivo cuando
#     el repo es el orquestador de la maquina, como aca;
#   - $HOME/.local/share/solidcraft-orch (el ORCH_DIR por defecto);
#   - cualquiera de TEST_GUARD_LIVE_DIRS (rutas extra, separadas por ':').
# Un directorio vacio tambien es un no: la suite no dijo donde escribe.
#
# Ejecutado (bash bin/test-guard.sh, como lo corre bin/test-all.sh) se prueba
# a si mismo: un guardia que nadie prueba es un guardia que se puede romper
# en silencio.
# ---------------------------------------------------------------------------

# La ruta real de un directorio, exista o no (readlink -f necesita que exista
# el padre; -m no necesita nada).
_test_guard_real() {
  readlink -f -- "$1" 2>/dev/null || readlink -m -- "$1" 2>/dev/null || printf '%s\n' "$1"
}

test_guard_orch_dir() {
  local here repo_dir dir real live live_real
  local -a dirs lives
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_dir="$(dirname "$here")"
  if [ "$#" -gt 0 ]; then
    dirs=("$@")
  else
    dirs=("${ORCH_DIR:-}")
  fi
  lives=("$repo_dir" "$HOME/.local/share/solidcraft-orch")
  if [ -n "${TEST_GUARD_LIVE_DIRS:-}" ]; then
    local IFS=':'
    # shellcheck disable=SC2206
    lives+=(${TEST_GUARD_LIVE_DIRS})
    unset IFS
  fi
  for dir in "${dirs[@]}"; do
    if [ -z "$dir" ]; then
      echo "test-guard: $(basename "$0"): ORCH_DIR vacio: la suite no dice donde escribe su estado" >&2
      exit 2
    fi
    real="$(_test_guard_real "$dir")"
    for live in "${lives[@]}"; do
      [ -n "$live" ] || continue
      live_real="$(_test_guard_real "$live")"
      if [ "$real" = "$live_real" ]; then
        echo "test-guard: $(basename "$0"): me niego a correr: ORCH_DIR=$dir es el orquestador VIVO ($live_real)." >&2
        echo "  Una suite escribe su estado en un directorio de prueba (mktemp -d), nunca en el de verdad." >&2
        exit 2
      fi
    done
  done
  return 0
}

# --- la prueba del propio guardia (solo cuando se ejecuta, no con source) ---
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-guard.XXXXXX")"
  trap 'rm -rf "$_tmp"' EXIT
  pass=0; fail=0
  _expect() {  # $1 rc esperado, $2 descripcion, $3... los argumentos del guardia
    local want="$1" what="$2" rc
    shift 2
    ( test_guard_orch_dir "$@" ) 2>/dev/null; rc=$?
    if [ "$rc" = "$want" ]; then
      printf 'ok   - %s\n' "$what"; pass=$((pass + 1))
    else
      printf 'FALLA- %s (rc=%s, se esperaba %s)\n' "$what" "$rc" "$want"; fail=$((fail + 1))
    fi
  }
  mkdir -p "$_tmp/orch" "$_tmp/home/.local/share"
  _expect 0 "un directorio de prueba (mktemp) pasa" "$_tmp/orch"
  _expect 0 "uno que todavia no existe tambien pasa" "$_tmp/no-existe/orch"
  _expect 2 "el repo del orquestador (el padre de bin/) NO pasa" "$(dirname "$_here")"
  _expect 2 "el repo con una barra y un punto de mas tampoco" "$(dirname "$_here")/./"
  _expect 2 "un ORCH_DIR vacio NO pasa" ""
  ln -s "$(dirname "$_here")" "$_tmp/atajo"
  _expect 2 "un symlink al repo NO pasa (readlink -f)" "$_tmp/atajo"
  ln -s "$_tmp/orch" "$_tmp/home/.local/share/solidcraft-orch"
  ( HOME="$_tmp/home" test_guard_orch_dir "$_tmp/orch" ) 2>/dev/null
  if [ "$?" = 2 ]; then
    printf 'ok   - el destino de $HOME/.local/share/solidcraft-orch NO pasa\n'; pass=$((pass + 1))
  else
    printf 'FALLA- el destino de $HOME/.local/share/solidcraft-orch NO pasa\n'; fail=$((fail + 1))
  fi
  ( TEST_GUARD_LIVE_DIRS="/nada:$_tmp/orch" test_guard_orch_dir "$_tmp/orch" ) 2>/dev/null
  if [ "$?" = 2 ]; then
    printf 'ok   - TEST_GUARD_LIVE_DIRS agrega directorios vivos\n'; pass=$((pass + 1))
  else
    printf 'FALLA- TEST_GUARD_LIVE_DIRS agrega directorios vivos\n'; fail=$((fail + 1))
  fi
  ( ORCH_DIR="$(dirname "$_here")" test_guard_orch_dir ) 2>/dev/null
  if [ "$?" = 2 ]; then
    printf 'ok   - sin argumentos mira $ORCH_DIR\n'; pass=$((pass + 1))
  else
    printf 'FALLA- sin argumentos mira $ORCH_DIR\n'; fail=$((fail + 1))
  fi
  printf '\n%d ok, %d FALLA\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi
