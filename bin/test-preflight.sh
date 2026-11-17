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
#   1. sin la mitad LOOP, el preflight falla y nombra cada pieza
#   2. sin las copias de los crons, tambien: el cron corre la COPIA,
#      no el repo, asi que un fix del repo no llega al cron
#   3. una copia VIEJA del cron se avisa (el cron corre codigo viejo)
#   4. con todo en su lugar, el preflight da rc=0
#   5. lo que falta tiene后果: el mensaje dice que se rompe
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

# A LOOP with everything the preflight looks for, and a HERMES_SCRIPTS
# with a copy of every script the crons run.
LOOP="$TMP/loop"
HERMES="$TMP/hermes"
SOLIDCRAFT="$TMP/solidcraft"
WT="$TMP/wt"
mkdir -p "$LOOP/bin" "$HERMES" "$SOLIDCRAFT" "$WT" "$TMP/orch"
git -C "$SOLIDCRAFT" init -q 2>/dev/null || true

for f in agent-issue.sh claim-race.sh claim-brake.sh claim-salvage.sh \
         gate-quick.sh pr-defaults-line.sh; do
  printf '#!/bin/sh\nexit 0\n' > "$LOOP/bin/$f"
  chmod +x "$LOOP/bin/$f"
done

# Every script the crons registry names, in the repo AND in the copy.
while IFS='|' read -r job schedule script node rest; do
  case "$job" in ''|\#*) continue ;; esac
  script="$(printf '%s' "$script" | tr -d '[:space:]')"
  base="$(basename "${script:-}")"
  [ -n "$base" ] || continue
  # The REAL script: the preflight compares the copy with the repo, and a
  # fake one would be reported as a stale copy (which is right, and is the
  # point of the check).
  if [ -f "$ORCH_DIR_REAL/$script" ]; then
    cp "$ORCH_DIR_REAL/$script" "$HERMES/$base"
  else
    printf '#!/bin/sh\nexit 0\n' > "$HERMES/$base"
  fi
done < "$ORCH_DIR_REAL/bin/crons.txt"

run_preflight() {
  ORCH_DIR="$TMP/orch" LOOP_DIR="$LOOP" HERMES_SCRIPTS="$HERMES" \
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
out="$(ORCH_DIR="$TMP/orch" LOOP_DIR="$LOOP_VACIA" HERMES_SCRIPTS="$HERMES" \
        SOLIDCRAFT_REPO="$SOLIDCRAFT" WORKTREES_DIR="$WT" bash "$PREFLIGHT" 2>&1)"; rc=$?
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

# --- sin las copias de los crons -----------------------------------------
HERMES_VACIA="$TMP/hermes-vacia"
mkdir -p "$HERMES_VACIA"
out="$(ORCH_DIR="$TMP/orch" LOOP_DIR="$LOOP" HERMES_SCRIPTS="$HERMES_VACIA" \
        SOLIDCRAFT_REPO="$SOLIDCRAFT" WORKTREES_DIR="$WT" bash "$PREFLIGHT" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "corre esa copia"; then
  ok "sin las copias de los crons el preflight falla (el cron corre la copia, no el repo)"
else
  no "sin las copias de los crons el preflight falla (rc=$rc)"
fi

# --- una copia VIEJA del cron ---------------------------------------------
HERMES_VIEJA="$TMP/hermes-vieja"
mkdir -p "$HERMES_VIEJA"
while IFS='|' read -r job schedule script node rest; do
  case "$job" in ''|\#*) continue ;; esac
  script="$(printf '%s' "$script" | tr -d '[:space:]')"
  base="$(basename "${script:-}")"
  [ -n "$base" ] || continue
  printf '#!/bin/sh\n# la version vieja\nexit 0\n' > "$HERMES_VIEJA/$base"
done < "$ORCH_DIR_REAL/bin/crons.txt"
out="$(ORCH_DIR="$TMP/orch" LOOP_DIR="$LOOP" HERMES_SCRIPTS="$HERMES_VIEJA" \
        SOLIDCRAFT_REPO="$SOLIDCRAFT" WORKTREES_DIR="$WT" bash "$PREFLIGHT" 2>&1)"
if printf '%s' "$out" | grep -q "codigo viejo"; then
  ok "una copia vieja del cron se avisa: el cron corre codigo viejo"
else
  no "una copia vieja del cron se avisa: el cron corre codigo viejo"
fi

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
