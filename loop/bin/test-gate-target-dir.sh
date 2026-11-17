#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Test bank of gate-target-dir.sh, the layout of the target directories of
# the scoped gate. It writes nothing outside a temporary directory and it
# compiles nothing.
#
#   bash bin/test-gate-target-dir.sh
#
# The cases:
#   1. the base is the default one
#   2. the base comes from the environment
#   3. the directory of a slot is the base + slot-<name>
#   4. the name of a slot is normalized (lower case, safe characters, 60)
#   5. a name that can not be normalized is NOT invented (exit 2)
#   6. --slot without a name is an error (exit 2)
#   7. the directory of a run without a slot is the base + noslot
#   8. the list holds the directories that exist, and only the canonical ones
#   9. the legacy layout is the base itself
#  10. an unknown option is an error (exit 2)
#  11. the help answers and does nothing
#  12. no arguments is an error (exit 2)
#  13. the normalization is idempotent
#
# The exit code is 1 when a case fails.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${HELPER:-$SCRIPT_DIR/gate-target-dir.sh}"

if [ ! -f "$HELPER" ]; then
  echo "FALLO - gate-target-dir.sh is not found: $HELPER"
  exit 1
fi

TMP_TEST="$(mktemp -d "${TMPDIR:-/tmp}/test-gate-target-dir.XXXXXX" 2>/dev/null)" || {
  echo "FALLO - a temporary directory cannot be created"
  exit 1
}
cleanup() { rm -rf "$TMP_TEST"; }
trap cleanup EXIT

FAILURES=0

check_equal() {
  # check_equal <label> <got> <want>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1: $2"
  else
    echo "FALLO - $1: got '$2', wanted '$3'"
    FAILURES=$((FAILURES + 1))
  fi
}

check_rc() {
  # check_rc <label> <got rc> <want rc>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1: rc=$2"
  else
    echo "FALLO - $1: got rc=$2, wanted rc=$3"
    FAILURES=$((FAILURES + 1))
  fi
}

DEFAULT_BASE="/home/user/solidcraft-gate-quick/target"

# 1. the base is the default one
out="$(bash "$HELPER" --base 2>/dev/null)"
check_rc "caso 1 (la base responde)" "$?" "0"
check_equal "caso 1 (la base por defecto)" "$out" "$DEFAULT_BASE"

# 2. the base comes from the environment
out="$(GATE_QUICK_TARGET_DIR="$TMP_TEST/base" bash "$HELPER" --base 2>/dev/null)"
check_equal "caso 2 (la base viene del entorno)" "$out" "$TMP_TEST/base"

# 3. the directory of a slot is the base + slot-<name>
out="$(GATE_QUICK_TARGET_DIR="$TMP_TEST/base" bash "$HELPER" --slot s0 2>/dev/null)"
check_equal "caso 3 (el directorio del slot)" "$out" "$TMP_TEST/base/slot-s0"

# 4. the name of a slot is normalized
out="$(GATE_QUICK_TARGET_DIR="$TMP_TEST/base" bash "$HELPER" --slot "S0 Alt" 2>/dev/null)"
check_equal "caso 4 (el nombre se normaliza)" "$out" "$TMP_TEST/base/slot-s0-alt"
long="$(printf 'a%.0s' $(seq 1 80))"
out="$(GATE_QUICK_TARGET_DIR="$TMP_TEST/base" bash "$HELPER" --slot "$long" 2>/dev/null)"
check_equal "caso 4 (el nombre se corta a 60)" "$out" \
  "$TMP_TEST/base/slot-$(printf 'a%.0s' $(seq 1 60))"

# 5. a name that can not be normalized is NOT invented
for bad in ".." ".hidden" "-dash" "a..b" ""; do
  out="$(GATE_QUICK_TARGET_DIR="$TMP_TEST/base" bash "$HELPER" --slot "$bad" \
    2>/dev/null)"
  rc=$?
  check_rc "caso 5 (un nombre no usable: '$bad')" "$rc" "2"
  check_equal "caso 5 (un nombre no usable no imprime nada: '$bad')" "$out" ""
done

# 6. --slot without a name is an error
out="$(GATE_QUICK_TARGET_DIR="$TMP_TEST/base" bash "$HELPER" --slot 2>/dev/null)"
check_rc "caso 6 (--slot sin nombre)" "$?" "2"

# 7. the directory of a run without a slot is the base + noslot
out="$(GATE_QUICK_TARGET_DIR="$TMP_TEST/base" bash "$HELPER" --noslot 2>/dev/null)"
check_equal "caso 7 (el directorio sin slot)" "$out" "$TMP_TEST/base/noslot"

# 8. the list holds the directories that exist, and only the canonical ones
mkdir -p "$TMP_TEST/base/slot-s0" "$TMP_TEST/base/slot-s1" \
  "$TMP_TEST/base/slot-BAD" "$TMP_TEST/base/slot-" "$TMP_TEST/base/other"
out="$(GATE_QUICK_TARGET_DIR="$TMP_TEST/base" bash "$HELPER" --list 2>/dev/null)"
want="$TMP_TEST/base/slot-s0
$TMP_TEST/base/slot-s1"
check_equal "caso 8 (la lista sólo trae los canónicos)" "$out" "$want"

# 9. the legacy layout is the base itself
out="$(GATE_QUICK_TARGET_DIR="$TMP_TEST/base" bash "$HELPER" --legacy 2>/dev/null)"
check_equal "caso 9 (el layout legacy es la base)" "$out" "$TMP_TEST/base"

# 10. an unknown option is an error
bash "$HELPER" --nope >/dev/null 2>&1
check_rc "caso 10 (una opción desconocida)" "$?" "2"

# 11. the help answers and does nothing
bash "$HELPER" --help >/dev/null 2>&1
check_rc "caso 11 (la ayuda responde)" "$?" "0"

# 12. no arguments is an error
bash "$HELPER" >/dev/null 2>&1
check_rc "caso 12 (sin argumentos)" "$?" "2"

# 13. the normalization is idempotent
once="$(GATE_QUICK_TARGET_DIR="$TMP_TEST/base" bash "$HELPER" --slot "S0 Alt" \
  2>/dev/null)"
twice="$(GATE_QUICK_TARGET_DIR="$TMP_TEST/base" bash "$HELPER" --slot s0-alt \
  2>/dev/null)"
check_equal "caso 13 (normalizar dos veces es lo mismo)" "$once" "$twice"

# --- the verdict ----------------------------------------------------------
if [ "$FAILURES" -eq 0 ]; then
  echo "todos los casos pasan"
  exit 0
fi
echo "$FAILURES caso(s) fallan"
exit 1
