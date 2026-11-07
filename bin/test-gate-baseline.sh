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

mkverdict(){ # $1 slot, $2 verdict, $3 new, $4 failed(csv), $5 deferred(opcional)
  mkdir -p "$LOOP_DIR/gates/$1"
  {
    echo "GATE_STATUS=finished"
    echo "VERDICT=$2"
    echo "NEW_FAILURES=$3"
    echo "FAILED_TESTS=$4"
    echo "SHA=abc123def4567890"
    [ -n "${5:-}" ] && echo "DEFERRED=$5"
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

# 6. a failure WITHOUT a name is a failure of the branch (2026-11-07).
#
# The NEW_FAILURES of the raw verdict is the sum of the new FAILING TESTS
# (which have a name and are the ones listed in FAILED_TESTS) and the
# PROBLEMS of the phases (a fmt that fails, a clippy that fails, a check
# that fails). A PROBLEM HAS NO NAME: it is not in FAILED_TESTS and it
# can not be looked up in the catalogue of the failures of origin/main,
# which only has names. The slot 6738 (fmt:fail) came out VERDE-SCOPE
# with NEW_FAILURES=0, a GREEN that the branch never earned: the discount
# was "COUNT == 0 means every failure was preexisting", and a failure
# without a name has COUNT 0.
cat > "$ORCH_DIR/baseline/failures-origin-main.txt" <<'EOF'
# comment line
engine::old::one
kernel::old::two
EOF
: > "$KNOWN_FAILING_TESTS"
mkverdict e ROJO-SCOPE 1 ""
run e
[ "$(field e VERDICT)" = "ROJO-SCOPE" ] && ok "un fallo SIN nombre deja el PR en rojo" \
  || no "un fallo SIN nombre deja el PR en rojo (quedo $(field e VERDICT))"
[ "$(field e NEW_FAILURES)" = "1" ] && ok "un fallo SIN nombre cuenta como fallo nuevo" \
  || no "un fallo SIN nombre cuenta como fallo nuevo (quedo $(field e NEW_FAILURES))"

# 7. a DEFERRED scope is not a verdict (2026-11-07).
#
# The gate says it out loud when it postpones a scope: "the scope was
# deferred (nextest-timeout): it is not a verdict". There is nothing to
# discount and nothing to publish, so the effective verdict of a deferred
# slot is NOT written. The one of a PREVIOUS run IS removed: it is the
# verdict of ANOTHER commit, and reading it as the verdict of this one is
# exactly the bug this script exists to avoid.
mkverdict f VERDE-SCOPE 0 ""
run f
[ -f "$LOOP_DIR/gates/f/scope.effective.verdict" ] && ok "un slot normal deja veredicto efectivo" \
  || no "un slot normal deja veredicto efectivo"
mkverdict f SKIP 0 "" "nextest-timeout"
run f
[ ! -f "$LOOP_DIR/gates/f/scope.effective.verdict" ] && ok "un scope diferido NO deja veredicto efectivo" \
  || no "un scope diferido NO deja veredicto efectivo"
[ ! -f "$LOOP_DIR/gates/f/scope.effective.verdict" ] && ok "un scope diferido borra el veredicto efectivo de un run anterior" \
  || no "un scope diferido borra el veredicto efectivo de un run anterior"

printf '\n%d casos, %d fallan\n' "$((pass+fail))" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
