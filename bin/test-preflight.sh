#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-preflight.sh - the preflight has to say what is missing, and
# what breaks without it.
#
# POR QUE EXISTEN: el orquestador esta partido en dos directorios y la
# mitad LOOP no esta en este repo (ver docs/la-otra-mitad.md). El
# procedimento de instalacion del README no lo mencionaba, asi que el
# repo instalado no podia publicar, ni gatear, ni arbitrar. Este script
# es el que lo dice, con nombre y consecuencia.
#
# Lo que se prueba:
#   1. con todo en su lugar, el preflight da rc=0
#   2. sin la mitad LOOP, el preflight falla y nombra cada pieza, con lo que
#      se rompe sin ella
#   3. un crontab cuyo bloque no define PATH falla (2026-11-21: sin PATH el
#      cron no encuentra gh ni opencode y la wave no despacha a nadie)
#   4. un crontab sin el bloque del loop falla
# Las copias de hermes (~/.hermes/scripts) ya no se prueban: hermes no se usa
# mas. El crontab y el opencode son STUBS: el test no lee el crontab real.
#
# Run:  bash bin/test-preflight.sh
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR_REAL="$(dirname "$HERE")"
PREFLIGHT="$ORCH_DIR_REAL/bin/preflight.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-preflight.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FALLA- %s\n' "$1"; fail=$((fail+1)); }

# A LOOP with everything the preflight looks for, and stubs of crontab and
# opencode on the PATH (the crontab prints a block of the loop as
# bin/install-crontab.sh writes it; CRONTAB_FIXTURE says which one).
LOOP="$TMP/loop"
SOLIDCRAFT="$TMP/solidcraft"
WT="$TMP/wt"
STUBS="$TMP/stubs"
mkdir -p "$LOOP/bin" "$SOLIDCRAFT" "$WT" "$TMP/orch" "$STUBS"
git -C "$SOLIDCRAFT" init -q 2>/dev/null || true

for f in agent-issue.sh claim-race.sh claim-brake.sh claim-salvage.sh \
         gate-quick.sh pr-defaults-line.sh; do
  printf '#!/bin/sh\nexit 0\n' > "$LOOP/bin/$f"
  chmod +x "$LOOP/bin/$f"
done

printf '#!/bin/sh\nexit 0\n' > "$STUBS/opencode"
printf '#!/bin/sh\n[ "$1" = "-l" ] && cat "$CRONTAB_FIXTURE"\nexit 0\n' > "$STUBS/crontab"
chmod +x "$STUBS/opencode" "$STUBS/crontab"

# The good block: the PATH line and one job per line of the register.
GOOD="$TMP/crontab-good"
{
  echo "# >>> solidcraft-orch >>>"
  echo "PATH=$STUBS:/usr/bin:/bin"
  while IFS='|' read -r job schedule script node rest; do
    case "$job" in ''|\#*) continue ;; esac
    script="$(printf '%s' "$script" | tr -d '[:space:]')"
    echo "*/5 * * * * cd $ORCH_DIR_REAL && /usr/bin/env bash $script"
  done < "$ORCH_DIR_REAL/bin/crons.txt"
  echo "# <<< solidcraft-orch <<<"
} > "$GOOD"
NOPATH="$TMP/crontab-nopath"
grep -v '^PATH=' "$GOOD" > "$NOPATH"
EMPTY="$TMP/crontab-empty"
echo "0 * * * * true" > "$EMPTY"

run_preflight() {
  PATH="$STUBS:$PATH" CRONTAB_FIXTURE="${1:-$GOOD}" AGENT_CONFIG=/nonexistent \
  ORCH_DIR="$TMP/orch" LOOP_DIR="${2:-$LOOP}" \
  SOLIDCRAFT_REPO="$SOLIDCRAFT" WORKTREES_DIR="$WT" \
  bash "$PREFLIGHT" 2>&1
}

out="$(run_preflight)"; rc=$?
if [ $rc -eq 0 ]; then
  ok "con todo en su lugar el preflight da rc=0"
else
  no "con todo en su lugar el preflight da rc=0 (rc=$rc)"; printf '     %s\n' "$out"
fi

# --- sin la mitad LOOP -----------------------------------------------------
LOOP_VACIA="$TMP/loop-vacia"
mkdir -p "$LOOP_VACIA/bin"
out="$(run_preflight "$GOOD" "$LOOP_VACIA")"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "agent-issue.sh"; then
  ok "sin la mitad LOOP el preflight falla y nombra el publisher"
else
  no "sin la mitad LOOP el preflight falla y nombra el publisher (rc=$rc)"
fi
if printf '%s' "$out" | grep -q "no se abre ningun PR"; then
  ok "el mensaje dice que se rompe sin el publisher"
else
  no "el mensaje dice que se rompe sin el publisher"
fi
if printf '%s' "$out" | grep -q "gate-quick.sh"; then
  ok "tambien nombra el gate que compila"
else
  no "tambien nombra el gate que compila"
fi

# --- el bloque del crontab sin PATH ----------------------------------------
out="$(run_preflight "$NOPATH")"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "no define PATH"; then
  ok "un bloque del crontab sin PATH hace fallar el preflight"
else
  no "un bloque del crontab sin PATH hace fallar el preflight (rc=$rc)"; printf '     %s\n' "$out"
fi

# --- un crontab sin el bloque del loop --------------------------------------
out="$(run_preflight "$EMPTY")"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "no estan instalados"; then
  ok "un crontab sin los jobs del loop hace fallar el preflight"
else
  no "un crontab sin los jobs del loop hace fallar el preflight (rc=$rc)"; printf '     %s\n' "$out"
fi

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
