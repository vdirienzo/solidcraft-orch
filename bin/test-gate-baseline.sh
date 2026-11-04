#!/usr/bin/env bash
# ------------------------------------------------------------------
# test-gate-baseline.sh - the EFFECTIVE verdict must subtract only the
# failures that were already failing in origin/main, and nothing else.
#
# The upstream SMLib migration (#11351) left 26 tests broken in main. If
# the filter is wrong in either direction, a broken PR gets published
# (too permissive) or a good PR never gets published (too strict).
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/gate-baseline.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ORCH_DIR="$TMP/orch"
LOOP_DIR="$TMP/loop"
mkdir -p "$ORCH_DIR/bin" "$ORCH_DIR/baseline" "$LOOP_DIR/gates"
# The HOME is isolated: the filter reads the upstream catalogue
# (tests/KNOWN_FAILING_TESTS) from $HOME/solidcraft, and the real one on this
# box would leak into the cases that expect nothing to be discounted.
export HOME="$TMP/home"
mkdir -p "$HOME"
KNOWN_FAILING_TESTS="$TMP/known-failing.txt"
: > "$KNOWN_FAILING_TESTS"
cp "$SRC" "$ORCH_DIR/bin/gate-baseline.sh"

pass=0; fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FALLA- %s\n' "$1"; fail=$((fail+1)); }

# The baseline: two failures that origin/main already had.
cat > "$ORCH_DIR/baseline/failures-origin-main.txt" <<'EOF'
# comment line
engine::old::one
kernel::old::two
EOF

mkverdict(){ # $1 slot, $2 verdict, $3 new, $4 failed(csv)
  mkdir -p "$LOOP_DIR/gates/$1"
  {
    echo "GATE_STATUS=finished"
    echo "VERDICT=$2"
    echo "NEW_FAILURES=$3"
    echo "FAILED_TESTS=$4"
    echo "SHA=abc123def4567890"
  } > "$LOOP_DIR/gates/$1/scope.verdict"
}

run(){ ORCH_DIR="$ORCH_DIR" LOOP_DIR="$LOOP_DIR" bash "$ORCH_DIR/bin/gate-baseline.sh" "$1" >/dev/null 2>&1; }
field(){ grep -E "^$2=" "$LOOP_DIR/gates/$1/scope.effective.verdict" 2>/dev/null | head -1 | cut -d= -f2-; }

# 1. every failure is preexisting -> green, and the raw verdict is not touched.
printf 'engine::catalogued::three\n' > "$KNOWN_FAILING_TESTS"
mkverdict a ROJO-SCOPE 2 "engine::old::one,kernel::old::two"
run a
[ "$(field a VERDICT)" = "VERDE-SCOPE" ] && ok "un ROJO con todos los fallos preexistentes es verde" \
  || no "un ROJO con todos los fallos preexistentes es verde (quedo $(field a VERDICT))"
[ "$(field a NEW_FAILURES)" = "0" ] && ok "los fallos preexistentes no cuentan como nuevos" \
  || no "los fallos preexistentes no cuentan como nuevos"
[ "$(field a PREEXISTING_FAILURES)" = "2" ] && ok "los preexistentes quedan contados aparte" \
  || no "los preexistentes quedan contados aparte"
[ "$(grep -E '^VERDICT=' "$LOOP_DIR/gates/a/scope.verdict" | cut -d= -f2)" = "ROJO-SCOPE" ] \
  && ok "el veredicto crudo NO se toca" || no "el veredicto crudo NO se toca"

# 2. one failure of its own -> stays red.
mkverdict b ROJO-SCOPE 3 "engine::old::one,engine::mine::new,kernel::old::two"
run b
[ "$(field b VERDICT)" = "ROJO-SCOPE" ] && ok "un fallo propio deja el PR en rojo" \
  || no "un fallo propio deja el PR en rojo (quedo $(field b VERDICT))"
[ "$(field b NEW_FAILURES)" = "1" ] && ok "solo cuenta el fallo propio" \
  || no "solo cuenta el fallo propio (quedo $(field b NEW_FAILURES))"
[ "$(field b FAILED_TESTS)" = "engine::mine::new" ] && ok "el fallo propio queda nombrado" \
  || no "el fallo propio queda nombrado"

# 3. a green gate stays green.
mkverdict c VERDE-SCOPE 0 ""
run c
[ "$(field c VERDICT)" = "VERDE-SCOPE" ] && ok "un gate verde sigue verde" || no "un gate verde sigue verde"

# 4. without a baseline, nothing is discounted.
rm -f "$ORCH_DIR/baseline/failures-origin-main.txt"
: > "$KNOWN_FAILING_TESTS"
mkverdict d ROJO-SCOPE 2 "engine::old::one,kernel::old::two"
run d
[ "$(field d VERDICT)" = "ROJO-SCOPE" ] && ok "sin baseline no se descuenta nada" \
  || no "sin baseline no se descuenta nada"
[ "$(field d NEW_FAILURES)" = "2" ] && ok "sin baseline el conteo queda entero" \
  || no "sin baseline el conteo queda entero"

# 5. a slot without a verdict fails loudly.
ORCH_DIR="$ORCH_DIR" LOOP_DIR="$LOOP_DIR" bash "$ORCH_DIR/bin/gate-baseline.sh" noexiste >/dev/null 2>&1
[ $? -ne 0 ] && ok "un slot sin veredicto da error" || no "un slot sin veredicto da error"

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
