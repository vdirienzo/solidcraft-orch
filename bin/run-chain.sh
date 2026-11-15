#!/usr/bin/env bash
# --------------------------------------------------------------------------
# run-chain.sh - corre el corredor de varios issues, UNO A LA VEZ.
#
# POR QUE (2026-11-11, medido): el provider de opencode (minimax) corta la
# conexion con ECONNRESET cuando hay varias sesiones de opencode simultaneas.
# En la wave wave-20261110-2257 se despacharon 4 issues a la vez: el primero
# (14801) termino bien en 16m45s y los otros tres muerte con ECONNRESET a los
# 10-20 min. En la wave anterior, con 2 simultaneos, mueren los 2. Con uno
# solo (14801) no hubo ninguna muerte.
#
# ASI QUE: un issue a la vez, en cadena. Cada uno es su propio servicio
# systemd (--unit), asi que el agente no hereda el cgroup del turno de Hermes.
#
# USO: bash bin/run-chain.sh <issue> [<issue> ...]
# --------------------------------------------------------------------------
set -u
ORCH=/home/user/.local/share/solidcraft-orch
LOOP=/home/user/.local/share/solidcraft-loop
TIMEOUT_MIN="${CHAIN_TIMEOUT:-40}"
SUFFIX="${CHAIN_SUFFIX:-$(date -u +%Y%m%d-%H%M)}"

for ISSUE in "$@"; do
  echo "chain: === issue $ISSUE $(date -u +%FT%TZ) ==="
  bash "$ORCH/bin/launch-slot-service.sh" "$ISSUE" "$TIMEOUT_MIN" "$SUFFIX"
  # El lock se refresca mientras el agente corre: un lock que nadie refresca
  # se vuelve stale a los 240 min y la proxima wave lo reapea por error.
  (
    while systemctl --user is-active --quiet "sc${ISSUE}.service"; do
      sleep 120
      bash "$ORCH/bin/slot-lock.sh" --slot "$ISSUE" --heartbeat >/dev/null 2>&1 || true
    done
  ) &
  HB=$!
  # Se espera a que el servicio termine antes de lanzar el siguiente: la
  # concurrencia es lo que mata al provider.
  while systemctl --user is-active --quiet "sc${ISSUE}.service"; do
    sleep 20
  done
  kill "$HB" 2>/dev/null || true
  echo "chain: issue $ISSUE terminado $(date -u +%FT%TZ)"
  sleep 20
done
echo "chain: fin $(date -u +%FT%TZ)"
