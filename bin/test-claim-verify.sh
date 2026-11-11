#!/usr/bin/env bash
# test-claim-verify.sh - the tests of the re-verification of the claim.
#
# WHY THIS FILE EXISTS: the rule of the claim was unified in claim-race.sh,
# but claim-verify.sh (the one the GATE calls, to check the claim again after
# the draft is opened) kept its own copy of the rule. That copy was WRONG in
# two ways that cost real work:
#
#   1. It counted a MENTION in prose as a claim. The PR #6997 says "since
#      #10183 the UI follows the system language" and that was read as a rival
#      holding the claim: the gate aborted with exit 4 over an issue whose
#      work was already merged upstream.
#   2. Its limit was 800 open pull requests and the upstream has more than
#      800, so the list was TRUNCATED and the real competitor was not seen.
#
# A claim is a CLOSING VERB (Fixes / Closes / Resolves) followed by the
# number, exactly as the upstream's own parser does it
# (scripts/pr-checks/pr-checks.js, parseClosing).
#
# The tests are hermetic: a stub of `gh` answers from a fixture and GitHub is
# never contacted.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-claim-verify.XXXXXX")"
PASS=0
FAIL=0

cleanup() { rm -rf "$TESTDIR"; }
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FALLO - %s\n' "$1"; }

# --- the stub of gh --------------------------------------------------------
mkdir -p "$TESTDIR/bin"
cat >"$TESTDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Answers `gh pr list` from the fixture in $GH_FIXTURE (one JSON object per
# line with number, title and body) and records the call.
#
# It applies the `--jq` filter itself, the way the real gh does: the filter
# is what decides which pull requests mention the issue, and a stub that
# ignored it would answer "every pull request is a claim".
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
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

# --- the helper ------------------------------------------------------------
# claim_verify <issue> [our_pr] -> writes the output to $OUT and the rc to $RC
claim_verify() {
  OUT="$(bash "$HERE/claim-verify.sh" "$@" 2>&1)"
  RC=$?
}

write_fixture() {
  # Each argument: number|title|body.
  #
  # The fixture is built with jq, not with printf: a body that contains
  # quotes has to be escaped, and a hand-written JSON line with those quotes
  # inside is INVALID. jq then fails to read it, the error goes to
  # /dev/null and the pull request list comes back EMPTY — which reads as
  # "nobody claims this issue" and hides a real competitor.
  local arr="[]"
  local spec n rest t b
  for spec in "$@"; do
    n="${spec%%|*}"
    rest="${spec#*|}"
    t="${rest%%|*}"
    b="${rest#*|}"
    arr="$(jq -n --argjson number "$n" --arg title "$t" --arg body "$b" \
             --argjson arr "$arr" \
             '$arr + [{"number":$number,"title":$title,"body":$body}]')"
  done
  printf '%s\n' "$arr" >"$TESTDIR/fixture.json"
}
export GH_FIXTURE="$TESTDIR/fixture.json"

# --- 1) a mention in prose is NOT a claim ----------------------------------
echo "== una mencion en prosa NO es un reclamo =="

write_fixture '6997|Something|"since #10183 the UI follows the system language"'
claim_verify 10183
if [ "$RC" -eq 0 ]; then
  ok "una mencion en prosa no quita el reclamo (rc=0)"
else
  bad "una mencion en prosa no quita el reclamo" "rc=$RC $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"
fi

write_fixture '6997|Another|"the behaviour of #10183 was nice"'
claim_verify 10183
if [ "$RC" -eq 0 ]; then
  ok "una segunda forma de mencion tampoco lo quita (rc=0)"
else
  bad "una segunda forma de mencion tampoco lo quita" "rc=$RC"
fi

# --- 2) a closing verb IS a claim ------------------------------------------
echo
echo "== un verbo de cierre SI es un reclamo =="

write_fixture '10826|Fix|Closes #8834'
claim_verify 8834
if [ "$RC" -eq 1 ]; then
  ok "un verbo de cierre toma el reclamo (rc=1)"
else
  bad "un verbo de cierre toma el reclamo" "rc=$RC"
fi

write_fixture '10826|Fix|Fixes #8834'
claim_verify 8834
if [ "$RC" -eq 1 ]; then
  ok "'Fixes' toma el reclamo (rc=1)"
else
  bad "'Fixes' toma el reclamo" "rc=$RC"
fi

write_fixture '10826|Fix|Resolves #8834'
claim_verify 8834
if [ "$RC" -eq 1 ]; then
  ok "'Resolves' toma el reclamo (rc=1)"
else
  bad "'Resolves' toma el reclamo" "rc=$RC"
fi

# the verb can be followed by a colon, as the upstream's parser allows
write_fixture '10826|Fix|Fixes: #8834'
claim_verify 8834
if [ "$RC" -eq 1 ]; then
  ok "el verbo con dos puntos toma el reclamo (rc=1)"
else
  bad "el verbo con dos puntos toma el reclamo" "rc=$RC"
fi

# a different number must not be taken for this one
write_fixture '10826|Fix|Closes #8835'
claim_verify 8834
if [ "$RC" -eq 0 ]; then
  ok "un reclamo de OTRO issue no es un reclamo de este (rc=0)"
else
  bad "un reclamo de OTRO issue no es un reclamo de este" "rc=$RC"
fi

# --- 3) the lowest number wins ----------------------------------------------
echo
echo "== gana el pull request de numero menor =="

write_fixture '500|Old|Fixes #7777' '900|New|Fixes #7777'
claim_verify 7777 900
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'perdio contra el #500'; then
  ok "nuestro PR #900 pierde contra el #500"
else
  bad "nuestro PR #900 pierde contra el #500" "rc=$RC $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"
fi

write_fixture '500|Old|Fixes #7777' '900|New|Fixes #7777'
claim_verify 7777 500
if [ "$RC" -eq 0 ]; then
  ok "nuestro PR #500 gana contra el #900"
else
  bad "nuestro PR #500 gana contra el #900" "rc=$RC"
fi

# --- 4) our own pull request is not a rival --------------------------------
echo
echo "== nuestro propio pull request no es un competidor =="

write_fixture '4242|Nuestro|Fixes #7058'
claim_verify 7058 4242
if [ "$RC" -eq 0 ]; then
  ok "nuestro propio PR no nos quita el reclamo (rc=0)"
else
  bad "nuestro propio PR no nos quita el reclamo" "rc=$RC"
fi

# --- 5) the list of pull requests is NOT truncated ---------------------------
echo
echo "== la lista de pull requests no se trunca =="

# The upstream has more than 800 open pull requests; a limit of 800 hides the
# competitor. The limit has to be above that.
#
# 9-11-2026: the limit went from 1000 to 2000. The upstream had 1009 open PRs,
# and with a limit of 1000 the guard went BLIND for every issue (it did not
# find anyone's claim). `gh pr list --limit 2000` returns all of them.
if grep -q 'SC_PR_LIMIT:-2000' "$HERE/claim-verify.sh"; then
  ok "el limite de pull requests es 2000 (el upstream tiene mas de 1000 abiertos)"
else
  bad "el limite de pull requests es 2000" \
      "$(grep -n 'SC_PR_LIMIT' "$HERE/claim-verify.sh" | head -2 | tr '\n' ' ')"
fi

# --- 6) the usage and the unreadable list ----------------------------------
echo
echo "== el uso y la lista ilegible =="

claim_verify
if [ "$RC" -eq 2 ]; then
  ok "sin issue es un error de uso (rc=2)"
else
  bad "sin issue es un error de uso" "rc=$RC"
fi

claim_verify abc
if [ "$RC" -eq 2 ]; then
  ok "un issue que no es numero es un error de uso (rc=2)"
else
  bad "un issue que no es numero es un error de uso" "rc=$RC"
fi

# --- the summary -------------------------------------------------------------
echo
echo "== el resumen =="
printf '  %d caso(s) pasan, %d fallan\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf 'todos los casos pasan\n'
  exit 0
fi
printf '%d caso(s) fallan\n' "$FAIL"
exit 1
