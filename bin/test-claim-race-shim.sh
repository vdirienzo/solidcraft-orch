#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-claim-race-shim.sh - the tests of the SHIM of the rule of the claim.
#
# WHAT THIS FILE EXISTS FOR: loop/bin/claim-race.sh used to BE the rule of the
# claim (780 lines of arbitration of its own). Now it is a SHIM: it delegates
# the arbitration to bin/claim-verify.sh (the only arbiter of this repo) and
# translates its exit code to the one of the rule of the loop, which the brake
# (loop/bin/claim-brake.sh) and the publisher (loop/bin/agent-issue.sh) read:
#
#   arbiter 0  ->  0   OK        the claim is ours, or the issue is free
#   arbiter 1  ->  10  TAKEN     somebody else holds the claim
#   arbiter 2  ->  12  UNKNOWN   it could not be verified
#
# The tests here are HERMETIC: a stub of `gh` answers from a fixture and
# GitHub is never contacted. That is the only way to test the UNKNOWN case
# (rc=12): a network that does not answer has to be reproducible.
#
# The tests of the RULE itself are in bin/test-claim-verify.sh. These are the
# tests of the TRANSLATION.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/../loop/bin/claim-race.sh"
ARBITER="$HERE/claim-verify.sh"

TESTDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-claim-race-shim.XXXXXX")"
PASS=0
FAIL=0

cleanup() { rm -rf "$TESTDIR"; }
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FALLO - %s\n' "$1"; [ $# -gt 1 ] && printf '           %s\n' "$2"; }

if [ ! -f "$SHIM" ]; then
  echo "test-claim-race-shim: no esta el shim: $SHIM" >&2
  exit 1
fi
if [ ! -f "$ARBITER" ]; then
  echo "test-claim-race-shim: no esta el arbitro: $ARBITER" >&2
  exit 1
fi

# --- the stub of gh --------------------------------------------------------
mkdir -p "$TESTDIR/bin"
cat >"$TESTDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Answers `gh pr list` from the fixture in $GH_FIXTURE (one JSON object per
# line with number, title, body and author) and applies the --jq filter
# itself, the way the real gh does: the filter is what decides which pull
# requests claim the issue, and a stub that ignored it would answer "every
# pull request is a claim".
#
# GH_FAIL=1 makes every call fail: that is the case of "GitHub could not be
# read", which is NOT a green.
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
if [ -n "${GH_FAIL:-}" ]; then
  echo "gh: could not connect to github.com" >&2
  exit 1
fi
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
  printf '%s\n' "${GH_LOGIN:-ourfork}"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  # `gh pr view N --json author --jq .author.login`: the author of a pull
  # request, by its number.
  n="$3"
  for a in $GH_AUTHORS; do
    num="${a%%:*}"; who="${a#*:}"
    if [ "$num" = "$n" ]; then printf '%s\n' "$who"; exit 0; fi
  done
  printf '\n'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  jq_filter=""
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--jq" ]; then jq_filter="$a"; fi
    prev="$a"
  done
  if [ -n "$jq_filter" ]; then
    jq -r "$jq_filter" <"${GH_FIXTURE:-/dev/null}" 2>/dev/null
  else
    cat "${GH_FIXTURE:-/dev/null}"
  fi
  exit 0
fi
printf '[]\n'
exit 0
STUB
chmod +x "$TESTDIR/bin/gh"
export GH_LOG="$TESTDIR/gh.log"
export GH_FIXTURE="$TESTDIR/fixture.json"

# The stub of gh has to be FIRST in the PATH, or the real gh answers and the
# test measures the upstream instead of the fixture.
export PATH="$TESTDIR/bin:$PATH"

# WHO WE ARE: the login of the author of OUR pull requests.
export FORK_OWNER="ourfork"

# --- the helper ------------------------------------------------------------
# shim <args...> -> writes the stdout to $OUT, the stderr to $ERR and the
# exit code to $RC.
shim() {
  OUT="$(bash "$SHIM" "$@" 2>"$TESTDIR/err")"
  RC=$?
  ERR="$(cat "$TESTDIR/err")"
}

field() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }

# The fixture: each argument is "number|title|body[|author]". Without an
# author the pull request is of ANOTHER author (a rival).
write_fixture() {
  local arr="[]"
  local spec n rest t b a
  for spec in "$@"; do
    n="${spec%%|*}"; rest="${spec#*|}"
    t="${rest%%|*}"; rest="${rest#*|}"
    b="${rest%%|*}"; rest="${rest#*|}"
    a="${rest:-rival}"
    arr="$(jq -n --argjson number "$n" --arg title "$t" --arg body "$b" --arg author "$a" \
             --argjson arr "$arr" \
             '$arr + [{"number":$number,"title":$title,"body":$body,"author":{"login":$author}}]')"
  done
  printf '%s\n' "$arr" >"$GH_FIXTURE"
}

# --- 1) the exit code of the arbiter is translated --------------------------
echo "== el exit code del arbitro se traduce =="

# arbiter 0: nobody claims the issue.
write_fixture
shim 7777
if [ "$RC" -eq 0 ]; then
  ok "el arbitro 0 -> 0 (libre)"
else
  bad "el arbitro 0 -> 0 (libre)" "rc=$RC"
fi

# arbiter 1: a rival claims the issue.
write_fixture '500|Old|Fixes #7777'
shim 7777
if [ "$RC" -eq 10 ]; then
  ok "el arbitro 1 -> 10 (tomado por otro)"
else
  bad "el arbitro 1 -> 10 (tomado por otro)" "rc=$RC"
fi

# arbiter 2: GitHub could not be read.
write_fixture '500|Old|Fixes #7777'
GH_FAIL=1 shim 7777
if [ "$RC" -eq 12 ]; then
  ok "el arbitro 2 -> 12 (no se pudo verificar)"
else
  bad "el arbitro 2 -> 12 (no se pudo verificar)" "rc=$RC"
fi
unset GH_FAIL

# The three codes are DISTINCT: a broken translation would pass a test that
# only checks one of them.
write_fixture
shim 7777; rc_free="$RC"
write_fixture '500|Old|Fixes #7777'
shim 7777; rc_taken="$RC"
write_fixture '500|Old|Fixes #7777'
GH_FAIL=1 shim 7777; rc_unknown="$RC"
unset GH_FAIL
if [ "$rc_free" != "$rc_taken" ] && [ "$rc_taken" != "$rc_unknown" ] && [ "$rc_free" != "$rc_unknown" ]; then
  ok "los tres codigos son distintos (0 / 10 / 12)"
else
  bad "los tres codigos son distintos" "libre=$rc_free tomado=$rc_taken desconocido=$rc_unknown"
fi

# --- 2) the vocabulary of the rule -----------------------------------------
echo
echo "== la respuesta habla el idioma de la regla =="

write_fixture '500|Old|Fixes #7777'
shim 7777
if [ "$(field VERDICT)" = "TAKEN" ]; then
  ok "VERDICT=TAKEN cuando lo tiene otro"
else
  bad "VERDICT=TAKEN cuando lo tiene otro" "VERDICT=$(field VERDICT)"
fi
if [ "$(field ISSUE)" = "7777" ]; then
  ok "ISSUE=7777"
else
  bad "ISSUE=7777" "ISSUE=$(field ISSUE)"
fi
if [ "$(field HOLDER)" = "500" ]; then
  ok "HOLDER=500 (el PR que lo toma)"
else
  bad "HOLDER=500 (el PR que lo toma)" "HOLDER=$(field HOLDER)"
fi
if [ -n "$(field REASON)" ]; then
  ok "REASON dice por que ($(field REASON))"
else
  bad "REASON dice por que" "REASON vacio"
fi

write_fixture
shim 7777
if [ "$(field VERDICT)" = "OK" ]; then
  ok "VERDICT=OK cuando el issue esta libre"
else
  bad "VERDICT=OK cuando el issue esta libre" "VERDICT=$(field VERDICT)"
fi

# The arbiter's OWN answer is passed through: the caller has to see WHICH
# issue and WHICH pull request were in the answer.
write_fixture '500|Old|Fixes #7777'
shim 7777
if printf '%s\n' "$OUT" | grep -q 'VEREDICTO='; then
  ok "el stdout del arbitro se pasa tal cual"
else
  bad "el stdout del arbitro se pasa tal cual" "no hay VEREDICTO= en la salida"
fi
if printf '%s\n' "$OUT" | grep -q '7777'; then
  ok "la salida nombra el issue"
else
  bad "la salida nombra el issue" "no hay 7777 en la salida"
fi
if printf '%s\n' "$OUT" | grep -q '500'; then
  ok "la salida nombra el PR competidor"
else
  bad "la salida nombra el PR competidor" "no hay 500 en la salida"
fi

# --- 3) la regla del mismo autor (no competimos con nosotros) --------------
echo
echo "== nuestro propio pull request no es un competidor =="

write_fixture '4242|Nuestro|Fixes #7058|ourfork'
shim 7058 --pr 4242
if [ "$RC" -eq 0 ]; then
  ok "nuestro propio PR no nos quita el reclamo (rc=0)"
else
  bad "nuestro propio PR no nos quita el reclamo" "rc=$RC $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"
fi

# --- 4) la carrera: el numero mas bajo gana ------------------------------
echo
echo "== gana el pull request de numero menor =="

write_fixture '500|Old|Fixes #7777' '900|New|Fixes #7777'
shim 7777 --pr 900
if [ "$RC" -eq 10 ] && [ "$(field VERDICT)" = "LOST" ]; then
  ok "nuestro PR #900 pierde contra el #500 (rc=10)"
else
  bad "nuestro PR #900 pierde contra el #500" "rc=$RC VERDICT=$(field VERDICT)"
fi
if [ "$(field HOLDER)" = "500" ]; then
  ok "HOLDER=500 (el PR que nos gano)"
else
  bad "HOLDER=500 (el PR que nos gano)" "HOLDER=$(field HOLDER)"
fi

write_fixture '500|Old|Fixes #7777' '900|New|Fixes #7777'
shim 7777 --pr 500
if [ "$RC" -eq 0 ]; then
  ok "nuestro PR #500 gana contra el #900 (rc=0)"
else
  bad "nuestro PR #500 gana contra el #900" "rc=$RC VERDICT=$(field VERDICT)"
fi

# --- 5) el autor del que lo toma ------------------------------------------
echo
echo "== el autor del PR que lo toma =="

write_fixture '500|Old|Fixes #7777'
export GH_AUTHORS="500:alguien"
shim 7777
if [ "$(field HOLDER_AUTHOR)" = "alguien" ]; then
  ok "HOLDER_AUTHOR=alguien"
else
  bad "HOLDER_AUTHOR=alguien" "HOLDER_AUTHOR=$(field HOLDER_AUTHOR)"
fi
if [ "$(field HOLDER_OURS)" = "no" ]; then
  ok "HOLDER_OURS=no (no es nuestro)"
else
  bad "HOLDER_OURS=no (no es nuestro)" "HOLDER_OURS=$(field HOLDER_OURS)"
fi
# The brake reads HOLDER_LOGIN for the sentence it says out loud and the
# salvage writes it in the note ("who holds it: @X").
if [ "$(field HOLDER_LOGIN)" = "alguien" ]; then
  ok "HOLDER_LOGIN=alguien (el freno y el rescate lo leen)"
else
  bad "HOLDER_LOGIN=alguien (el freno y el rescate lo leen)" "HOLDER_LOGIN=$(field HOLDER_LOGIN)"
fi
unset GH_AUTHORS

# --- 6) el uso incorrecto --------------------------------------------------
echo
echo "== el uso incorrecto es un 2, como siempre =="

shim abc
if [ "$RC" -eq 2 ]; then
  ok "un issue que no es un numero -> 2"
else
  bad "un issue que no es un numero -> 2" "rc=$RC"
fi

shim 7777 abc
if [ "$RC" -eq 2 ]; then
  ok "un PR que no es un numero -> 2"
else
  bad "un PR que no es un numero -> 2" "rc=$RC"
fi

shim --bogus
if [ "$RC" -eq 2 ]; then
  ok "una opcion desconocida -> 2"
else
  bad "una opcion desconocida -> 2" "rc=$RC"
fi

shim
if [ "$RC" -eq 2 ]; then
  ok "sin argumentos -> 2"
else
  bad "sin argumentos -> 2" "rc=$RC"
fi

# --- 7) el arbitro se encuentra solo --------------------------------------
echo
echo "== el shim encuentra el arbitro =="

if grep -q 'bin/claim-verify.sh' "$SHIM"; then
  ok "el shim nombra al arbitro"
else
  bad "el shim nombra al arbitro" "no hay bin/claim-verify.sh en $SHIM"
fi

# The shim has to find the arbiter by itself, without ORCH_DIR, from any
# directory: the path is RELATIVE to the script.
( cd / && CLAIM_VERIFY= bash "$SHIM" 7777 >/dev/null 2>&1 )
if [ $? -ne 127 ]; then
  ok "el shim se puede correr desde cualquier directorio"
else
  bad "el shim se puede correr desde cualquier directorio" "rc=127"
fi

# --- 8) el codigo 11 (RESOLVED) NO lo produce el shim ----------------------
echo
echo "== el shim nunca devuelve 11 (RESOLVED) =="

# The arbiter has no RESOLVED: the issue that is not open any more is the
# publisher's check ("is the issue open?"), not the arbitration.
write_fixture '500|Old|Fixes #7777'
shim 7777
if [ "$RC" != "11" ]; then
  ok "un issue tomado -> $RC (no 11)"
else
  bad "un issue tomado -> no 11" "rc=11"
fi

# --- the verdict ----------------------------------------------------------
printf '\n%d ok, %d fallos\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
