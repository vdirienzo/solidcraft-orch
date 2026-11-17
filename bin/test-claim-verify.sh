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
# THE RULE IS NOW THE UNION OF THE TWO RULES OF THE UPSTREAM (they do not
# agree with each other, and the upstream's own bot applies BOTH):
#
#   * the TITLE of the pull request names the issue ("... (#361)")
#     (upstream scripts/claim/claim.js, referencedIssues), OR
#   * the BODY of the pull request has a closing verb followed by the issue
#     (upstream scripts/claim/claim.js and scripts/pr-checks/pr-checks.js).
#     The '#' is REQUIRED there: it is what tells an issue reference from
#     prose with a number ("This fix 3 problems." is NOT a claim).
#
# With the old rule the verifier was BLIND to 193 rival pull requests that
# name the issue in the TITLE (measured over the 836 open pull requests of
# 2026-11-17, reports/loop-codigo.md B6): the PR #1608 "Correct mouse and
# trackpad navigation presets (#361)" held #361 and the guard said the issue
# was free.
#
# And it did not apply the rule of the upstream of "the same author"
# (scripts/claim/claim.js: a pull request does not compete with an older
# pull request of the same author): with two of OUR pull requests open on the
# same issue, the higher-numbered one was told it LOST and was CLOSED. That
# is real work thrown away.
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
# line with number, title, body and author) and records the call.
#
# It applies the `--jq` filter itself, the way the real gh does: the filter
# is what decides which pull requests mention the issue, and a stub that
# ignored it would answer "every pull request is a claim".
#
# GH_FAIL=1 makes every call fail: that is the case of "GitHub could not be
# read", which is NOT a green.
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
if [ -n "${GH_FAIL:-}" ]; then
  echo "gh: could not connect to github.com" >&2
  exit 1
fi
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
  printf '%s\n' "${GH_LOGIN:-}"
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
# The `gh` of the tests is OUTSIDE the PATH and is chosen with GH_BIN
# (README rule 4: a stub of a tool in a directory that may be on the PATH
# is what made a broken `gh` look like it worked).
export GH_BIN="$TESTDIR/bin/gh"

# WHO WE ARE: the login of the author of OUR pull requests. The verifier
# reads it from the same variable the publisher uses (FORK_OWNER).
export FORK_OWNER="ourfork"

# --- the helper ------------------------------------------------------------
# claim_verify <issue> [our_pr] -> writes the output to $OUT and the rc to $RC
claim_verify() {
  OUT="$(bash "$HERE/claim-verify.sh" "$@" 2>&1)"
  RC=$?
}

write_fixture() {
  # Each argument: number|title|body[|author].
  #
  # The author is the login of the author of the pull request. Without it
  # the pull request is of ANOTHER author (a rival).
  #
  # The fixture is built with jq, not with printf: a body that contains
  # quotes has to be escaped, and a hand-written JSON line with those quotes
  # inside is INVALID. jq then fails to read it, the error goes to
  # /dev/null and the pull request list comes back EMPTY — which reads as
  # "nobody claims this issue" and hides a real competitor.
  local arr="[]"
  local spec n rest t b a
  for spec in "$@"; do
    n="${spec%%|*}"
    rest="${spec#*|}"
    t="${rest%%|*}"
    rest="${rest#*|}"
    b="${rest%%|*}"
    a="${rest#*|}"
    [ "$a" = "$b" ] && a="rival"
    arr="$(jq -n --argjson number "$n" --arg title "$t" --arg body "$b" --arg author "$a" \
             --argjson arr "$arr" \
             '$arr + [{"number":$number,"title":$title,"body":$body,"author":{"login":$author}}]')"
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

write_fixture '4242|Nuestro|Fixes #7058|ourfork'
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

# ============================================================================
# THE UNION OF THE TWO RULES OF THE UPSTREAM (the 193 invisible rivals)
# ============================================================================
echo
echo "== la regla es la union de las dos reglas del upstream =="

# The case of the 193: the rival names the issue in the TITLE and the body
# does not mention it. The upstream's bot counts it (scripts/claim/claim.js
# reads the title); the old verifier did NOT and said the issue was free.
write_fixture '1608|Correct mouse and trackpad navigation presets (#361)|the body says nothing about the issue'
claim_verify 361
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'OCUPADO el PR #1608 ya reclama #361'; then
  ok "el rival que nombra el issue en el TITULO lo reclama (rc=1)"
else
  bad "el rival que nombra el issue en el TITULO lo reclama" \
      "rc=$RC $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi

# The same rival, with the issue in the body as well.
write_fixture '1608|Correct mouse and trackpad navigation presets (#361)|Fixes #361'
claim_verify 361
if [ "$RC" -eq 1 ]; then
  ok "el rival con el issue en el titulo y en el body lo reclama (rc=1)"
else
  bad "el rival con el issue en el titulo y en el body lo reclama" "rc=$RC"
fi

# THE THREE CASES THAT MADE THE ARBITER SAY "TAKEN" FOR A FREE ISSUE
# (2026-11-17). The three of them come from upstream's own parser:
#   - the noise: upstream strips the HTML comments and the code blocks
#     before it parses (stripNoise, pr-checks.js:25-31), so a "Fixes #N"
#     INSIDE A CODE BLOCK is an example, not a claim;
#   - another repository: upstream skips "owner/repo#N" when the repo is
#     not ours (parseClosing);
#   - our own pull request does not claim its own number (claim.js:297).
# Each of them costs a whole slot of the machine when it goes wrong.
# The bodies with real newlines: the write_fixture takes the body as one
# argument, and a literal "\n" would be two characters, not a line break.
CUERPO_EN_BLOQUE=$'```\nFixes #361\n```'
CUERPO_CON_RUIDO=$'antes\n```\nFixes #362\n```\ndespues\nFixes #361'
write_fixture "1700|un titulo sin issue|$CUERPO_EN_BLOQUE"
claim_verify 361
if [ "$RC" -eq 0 ]; then
  ok "un 'Fixes #361' dentro de un bloque de codigo NO lo reclama (el upstream saca el ruido)"
else
  bad "un 'Fixes #361' dentro de un bloque de codigo NO lo reclama" \
      "rc=$RC $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi

write_fixture '1701|otro titulo|Fixes other/repo#361'
claim_verify 361
if [ "$RC" -eq 0 ]; then
  ok "una referencia a OTRO repositorio no lo reclama"
else
  bad "una referencia a OTRO repositorio no lo reclama" \
      "rc=$RC $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi

write_fixture '361|propio|Fixes #361'
claim_verify 361
if [ "$RC" -eq 0 ]; then
  ok "un PR no se reclama a si mismo (claim.js:297)"
else
  bad "un PR no se reclama a si mismo (claim.js:297)" \
      "rc=$RC $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi

# And the real claim, with the noise around it, IS a claim.
write_fixture "1702|otro titulo mas|$CUERPO_CON_RUIDO"
claim_verify 361
if [ "$RC" -eq 1 ]; then
  ok "el cierre real sigue reclamando aunque el cuerpo tenga ruido (rc=1)"
else
  bad "el cierre real sigue reclamando aunque el cuerpo tenga ruido" "rc=$RC"
fi

# The issue in the body with a closing verb: the rule of pr-checks.js.
write_fixture '10826|Fix|Fixes #361'
claim_verify 361
if [ "$RC" -eq 1 ]; then
  ok "el verbo de cierre en el body lo reclama (rc=1)"
else
  bad "el verbo de cierre en el body lo reclama" "rc=$RC"
fi

# A claim in PROSE ("Claim for #743.") is NOT a claim: the upstream needs a
# closing verb (pr-checks.js:37). It only counts when the TITLE names it.
write_fixture '7978|Claim for the issue|Claim for #743.'
claim_verify 743
if [ "$RC" -eq 0 ]; then
  ok "un reclamo en prosa NO es un reclamo (rc=0)"
else
  bad "un reclamo en prosa NO es un reclamo" \
      "rc=$RC $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"
fi

write_fixture '7978|Claim for the issue (#743)|Claim for #743.'
claim_verify 743
if [ "$RC" -eq 1 ]; then
  ok "el mismo reclamo en prosa, con el issue en el TITULO, SI lo reclama (rc=1)"
else
  bad "el mismo reclamo en prosa, con el issue en el TITULO, SI lo reclama" "rc=$RC"
fi

# The '#' is what tells an issue reference from prose with a number.
write_fixture '500|Improve the thing|This fix 3 problems.'
claim_verify 3
if [ "$RC" -eq 0 ]; then
  ok "una prosa con un numero NO es un reclamo (rc=0)"
else
  bad "una prosa con un numero NO es un reclamo" \
      "rc=$RC $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"
fi

# A LIST of issues in the body: two UNIQUE issues, not one.
write_fixture '500|Fix|Fixes #10181, #10182'
claim_verify 10181
RC1=$RC
OUT1="$OUT"
claim_verify 10182
if [ "$RC1" -eq 1 ] && [ "$RC" -eq 1 ]; then
  ok "una lista de issues en el body reclama los DOS issues (rc=1 y rc=1)"
else
  bad "una lista de issues en el body reclama los DOS issues" \
      "rc=$RC1 y rc=$RC $(printf '%s' "$OUT1" | head -2 | tr '\n' ' ')"
fi

# The same issue in the title AND in the body is ONE issue, not two.
write_fixture '1608|Correct mouse and trackpad navigation presets (#361)|Fixes #361'
claim_verify 361
LIST="$(printf '%s\n' "$OUT" | sed -n 's/.*PRs que lo mencionan: \(.*\)(gana el.*/\1/p')"
COUNT="$(printf '%s' "$LIST" | wc -w | tr -d ' ')"
if [ "$RC" -eq 1 ] && [ "$COUNT" -eq 1 ]; then
  ok "el mismo issue en el titulo y en el body cuenta UN issue (rc=1)"
else
  bad "el mismo issue en el titulo y en el body cuenta UN issue" \
      "rc=$RC issues listados: $COUNT"
fi

# The issue of the list must not swallow a longer number.
write_fixture '500|Fix|Fixes #3610'
claim_verify 361
if [ "$RC" -eq 0 ]; then
  ok "un numero mas largo NO es este issue (rc=0)"
else
  bad "un numero mas largo NO es este issue" "rc=$RC"
fi

# ============================================================================
# THE RULE OF THE SAME AUTHOR (our own pull requests do not compete with us)
# ============================================================================
echo
echo "== un pull request nuestro no compite con nosotros =="

# The case of B7: two of OUR pull requests on the same issue. The
# higher-numbered one was told it LOST and was closed: real work thrown away.
write_fixture '9843|Nuestro|Fixes #361|ourfork' '11205|Nuestro stacked|Fixes #361|ourfork'
claim_verify 361 --our-pr 11205
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'PERDIDO'; then
  ok "dos PRs nuestros: el #11205 NO pierde (rc=0)"
else
  bad "dos PRs nuestros: el #11205 NO pierde" \
      "rc=$RC $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi

write_fixture '9843|Nuestro|Fixes #361|ourfork' '11205|Nuestro stacked|Fixes #361|ourfork'
claim_verify 361 --our-pr 9843
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'PERDIDO'; then
  ok "dos PRs nuestros: el #9843 NO pierde (rc=0)"
else
  bad "dos PRs nuestros: el #9843 NO pierde" \
      "rc=$RC $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi

# The same, with the number of our pull request as the second argument.
write_fixture '9843|Nuestro|Fixes #361|ourfork' '11205|Nuestro stacked|Fixes #361|ourfork'
claim_verify 361 11205
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'PERDIDO'; then
  ok "dos PRs nuestros, con el numero como segundo argumento: NO pierde (rc=0)"
else
  bad "dos PRs nuestros, con el numero como segundo argumento: NO pierde" \
      "rc=$RC $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi

# The other way around: a RIVAL with a lower number takes the claim.
write_fixture '9843|Un rival|Fixes #361|rival' '11205|Nuestro|Fixes #361|ourfork'
claim_verify 361 --our-pr 11205
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'perdio contra el #9843'; then
  ok "un rival con numero menor gana: el #11205 pierde (rc=1)"
else
  bad "un rival con numero menor gana: el #11205 pierde" \
      "rc=$RC $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi

# The rival with a HIGHER number does not take the claim from us.
write_fixture '9843|Nuestro|Fixes #361|ourfork' '11205|Un rival|Fixes #361|rival'
claim_verify 361 --our-pr 9843
if [ "$RC" -eq 0 ]; then
  ok "un rival con numero MAYOR no nos quita el reclamo (rc=0)"
else
  bad "un rival con numero MAYOR no nos quita el reclamo" \
      "rc=$RC $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi

# Our pull request that does NOT claim the issue, while another of ours
# holds it: the claim is OURS and nobody has to be closed.
write_fixture '9843|Nuestro|Fixes #361|ourfork' '11205|Nuestro otro|documentacion|ourfork'
claim_verify 361 --our-pr 11205
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'PERDIDO'; then
  ok "otro PR nuestro tiene el reclamo: el nuestro NO pierde (rc=0)"
else
  bad "otro PR nuestro tiene el reclamo: el nuestro NO pierde" \
      "rc=$RC $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi

# --- the exit codes: the contract with bin/gate.sh -------------------------
echo
echo "== los exit codes (el contrato con el gate) =="

# --our-pr without a number is a usage error.
claim_verify 361 --our-pr
if [ "$RC" -eq 2 ]; then
  ok "--our-pr sin numero es un error de uso (rc=2)"
else
  bad "--our-pr sin numero es un error de uso" "rc=$RC"
fi

claim_verify 361 --our-pr abc
if [ "$RC" -eq 2 ]; then
  ok "--our-pr que no es numero es un error de uso (rc=2)"
else
  bad "--our-pr que no es numero es un error de uso" "rc=$RC"
fi

# 0 = the claim is ours, 1 = it is lost, 2 = it could not be verified.
write_fixture '500|Fix|Fixes #7058|rival'
claim_verify 7058
if [ "$RC" -eq 1 ]; then
  ok "un issue reclamado por otro es OCUPADO (rc=1)"
else
  bad "un issue reclamado por otro es OCUPADO" "rc=$RC"
fi

write_fixture '500|Fix|nothing about the issue|rival'
claim_verify 7058
if [ "$RC" -eq 0 ]; then
  ok "un issue que nadie reclama esta libre (rc=0)"
else
  bad "un issue que nadie reclama esta libre" "rc=$RC"
fi

# GitHub could not be read: UNKNOWN, never "no" (the rule of the verdict).
write_fixture '500|Fix|Fixes #7058|rival'
GH_FAIL=1 claim_verify 7058
if [ "$RC" -eq 2 ]; then
  ok "si GitHub no se puede leer, el veredicto es UNKNOWN (rc=2)"
else
  bad "si GitHub no se puede leer, el veredicto es UNKNOWN" "rc=$RC"
fi
unset GH_FAIL

# The texts of the verdict are the contract with bin/gate.sh and
# bin/publish-pr.sh: they do not change.
write_fixture '500|Fix|Fixes #7058|rival'
claim_verify 7058 900
if printf '%s' "$OUT" | grep -q 'VEREDICTO=PERDIDO el PR #900 perdio contra el #500'; then
  ok "el texto de VEREDICTO=PERDIDO es el de siempre"
else
  bad "el texto de VEREDICTO=PERDIDO es el de siempre" \
      "$(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
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
