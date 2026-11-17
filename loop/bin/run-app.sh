#!/usr/bin/env bash
# Runs SolidCraft (or any command) with the headless graphics environment.
#
#   run-app.sh [solidcraft args...]
#
# If the X server is not alive, it starts it. The control channel token can be
# set with SOLIDCRAFT_CONTROL_TOKEN; if it is not, one is generated and left in
# ~/.local/share/solidcraft-loop/control-token.
set -euo pipefail

XROOT="${HOME}/.local/x"
STATE_DIR="${HOME}/.local/share/solidcraft-loop"
REPO="${REPO:-/home/user/solidcraft}"
BIN="${SOLIDCRAFT_BIN:-${REPO}/target/release/solidcraft}"

# shellcheck source=/dev/null
. "${XROOT}/env.sh"

# The X server: if it is not running, start it.
if ! pgrep -x Xvfb >/dev/null 2>&1; then
  nohup "${XROOT}/start-xvfb.sh" 99 1600x1000x24 >/tmp/xvfb.log 2>&1 &
  for _ in $(seq 1 20); do
    sleep 1
    [ -S /tmp/.X11-unix/X99 ] && break
  done
fi
[ -S /tmp/.X11-unix/X99 ] || { echo "Xvfb did not start (see /tmp/xvfb.log)" >&2; exit 1; }

# Control channel token.
if [ -z "${SOLIDCRAFT_CONTROL_TOKEN:-}" ]; then
  TF="${STATE_DIR}/control-token"
  if [ ! -s "${TF}" ]; then
    install -d -m700 "${STATE_DIR}"
    openssl rand -hex 32 > "${TF}"
    chmod 600 "${TF}"
  fi
  SOLIDCRAFT_CONTROL_TOKEN="$(cat "${TF}")"
fi
export SOLIDCRAFT_CONTROL_TOKEN

exec "${BIN}" "$@"
