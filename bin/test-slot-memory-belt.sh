#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-slot-memory-belt.sh - the scope of a slot has to fit in the box.
#
# WHY THE TESTS EXIST (2026-11-21): the scope of an issue was launched with
# a belt BURNED INTO the script (MemoryHigh=12G, MemoryMax=16G) on a box of
# 15 GB. A belt bigger than the box is no belt: the scope could ask for more
# RAM than the machine has, and the OOM killer would then take whatever it
# found FIRST.
#
# The rule this suite fixes:
#   1. the scope of a slot reads its ceiling from the POLICY of the box
#      (config.env), not from a number written in the script;
#   2. no script of bin/ carries a memory ceiling of its own;
#   3. the ceiling of the slot fits in the RAM of the box.
#
# (2026-11-21) A fourth check summed the slot and the belt of the hermes
# gateway, the resident service every session lived in. hermes no longer
# runs on the box (the agent is opencode, the scheduler the user crontab),
# so the service does not exist and the check could only skip: it went.
#
# The ceiling of the GATE is not in this sum: the gate is exclusive (it runs
# alone, with the heavy token) and its belt is the maximum of a run that is
# serialized against the heavy build of a slot.
# ---------------------------------------------------------------------------
set -uo pipefail

ORCH_DIR="${ORCH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BIN="$ORCH_DIR/bin"

pass=0
fail=0

ok() { printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL - %s\n' "$1"; printf '         %s\n' "$2"; fail=$((fail + 1)); }

# The scripts that launch the scope of an issue.
SLOT_SCRIPTS=( "run-issue-scope.sh" "launch-slot-service.sh" )

# The RAM of the box, in KiB (what /proc/meminfo answers).
box_kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || echo 0)"
box_gb=$(( box_kb / 1024 / 1024 ))

# The size of a systemd memory property, in KiB.
#
# systemd prints a number in BYTES (8589934592), not "8G", so the value it
# answers has to be read as bytes. The policy of the box writes "8G". Both
# forms are accepted here, in the same unit, so the comparison is honest.
to_kib() {
  local v="$1"
  case "$v" in
    *G) echo $(( ${v%G} * 1024 * 1024 )) ;;
    *M) echo $(( ${v%M} * 1024 )) ;;
    *K) echo "${v%K}" ;;
    "") echo 0 ;;
    "infinite"|"infinity") echo 0 ;;
    *)   # systemd answers in bytes: to KiB.
      echo $(( v / 1024 )) ;;
  esac
}

# 1. no script carries a memory ceiling of its own.
#
# The pattern is a number with a unit (12G, 512M, 4G) next to MemoryHigh or
# MemoryMax. A number that comes from a variable ($SLOT_MEMORY_MAX) is fine:
# that is the policy speaking, not the script.
#
# Only the CODE is looked at: a comment may name the number it replaced
# (that is the history of the fix, and the history matters).
for s in "${SLOT_SCRIPTS[@]}"; do
  path="$BIN/$s"
  if [ ! -f "$path" ]; then
    bad "el script $s existe" "no se encuentra $path"
    continue
  fi
  hits="$(grep -nE '^[^#]*\b(MemoryHigh|MemoryMax)=[0-9]+[KMG]' "$path" || true)"
  if [ -n "$hits" ]; then
    bad "$s no lleva un techo de memoria quemado" "$hits"
  else
    ok "$s no lleva un techo de memoria quemado"
  fi
done

# 2. the scope of a slot reads the ceiling of the policy.
#
# The policy of the box (config.env) is the only place that says how much
# RAM this machine has. A script that launches a scope has to read it from
# there, so the number follows the box and not the day it was written.
for s in "${SLOT_SCRIPTS[@]}"; do
  path="$BIN/$s"
  [ -f "$path" ] || continue
  if grep -qE 'SLOT_MEMORY_(HIGH|MAX)' "$path"; then
    ok "$s lee el techo del slot de la politica"
  else
    bad "$s lee el techo del slot de la politica" \
      "no usa SLOT_MEMORY_HIGH / SLOT_MEMORY_MAX"
  fi
done

# 3. the ceiling of the slot fits in the box.
#
# The box reads its RAM from /proc/meminfo: it is the truth of this machine,
# and a policy written for another box has to say so loudly instead of
# promising a scope that cannot fit.
policy="${LOOP_CONFIG:-$HOME/.local/share/solidcraft-loop/config.env}"

if [ ! -r "$policy" ]; then
  ok "la politica de la caja no esta en esta maquina: nada que comprobar"
else
  # The last definition wins in config.env (the policy is read in order),
  # so the ceiling of the slot is the one that is written last.
  slot_max=""
  while IFS= read -r line; do
    case "$line" in
      SLOT_MEMORY_MAX=*) slot_max="${line#SLOT_MEMORY_MAX=}" ;;
    esac
  done < "$policy"
  slot_max="${slot_max%% *}"
  slot_max="${slot_max%%#*}"
  slot_max="$(printf '%s' "$slot_max" | tr -d '"'"'" | tr -d '[:space:]')"

  if [ -z "$slot_max" ]; then
    bad "la politica dice cuanto puede pedir un slot" \
      "SLOT_MEMORY_MAX no esta en $policy"
  else
    slot_kib="$(to_kib "$slot_max")"
    if [ "$slot_kib" -ge "$box_kb" ]; then
      bad "el techo del slot cabe en la caja" \
        "el slot pide $slot_max y la caja tiene ${box_gb} GB"
    else
      ok "el techo del slot cabe en la caja: $slot_max sobre ${box_gb} GB"
    fi
  fi
fi

printf '\n%s: %d ok, %d FAIL\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
