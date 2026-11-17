#!/usr/bin/env bash
# verify-pr.sh - check a PR in ONE call instead of six.
#
# The orchestrator used to verify a PR with six separate terminal calls (the PR
# view, the fork head, the checks, the body validation, the defaults line, the
# closing keywords). Each one is a turn, and every turn re-sends the whole
# context. This does them all at once and prints a compact verdict.
#
#   bash verify-pr.sh <pr-number> [repo] [slot]
#
#   <pr-number>  the pull request to check
#   [repo]       owner/name of the repository (default: ours)
#   [slot]       the slot whose gate has to have run for this PR. It is the
#                ISSUE the PR closes (the gate of a slot is named after the
#                issue). It is only needed when the body does not say which
#                issue the PR closes and the branch does not say it either:
#                without it the gate CANNOT be verified, and that is a FAIL,
#                not a silence.
#
# EXIT CODES:
#   0  everything the orchestrator checks is in order
#   1  there is something to fix (the lines marked FAIL)
#   6  UNKNOWN: something could not be checked (the CI of the PR could not be
#      read, for example). A check that could not run is NOT a red: it is a
#      "nobody knows", and a "nobody knows" is never reported as "todo en
#      orden" (RULES.md: "un check que no pudo correr NO es un rojo").
set -uo pipefail
PR="${1:?usage: verify-pr.sh <pr-number> [repo] [slot]}"
REPO="${2:-tangency-labs/solidcraft}"
SLOT_ARG="${3:-}"
# The `gh` to use. A test points it at a stub OUTSIDE the PATH (rule 4: a
# fake `gh` in the PATH would answer "no-op" to `gh pr create` too).
GH_BIN="${GH_BIN:-gh}"
# The paths come from the environment, with the default of THIS
# machine: the other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
# The loop's directory: the gate verdicts live under it (gates/<slot>/).
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
# The checkout of the product: the fork's head is read from it.
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
FAIL=0
UNKNOWN=0
note() { printf '%s\n' "$*"; }
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; FAIL=1; }
# UNKNOWN is NOT a red: it says that something could not be checked. It is
# also NOT a green: the verdict of an UNKNOWN is never "todo en orden".
unknown() { printf '  UNKN %s\n' "$*"; UNKNOWN=1; }

note "=== PR #$PR ($REPO) ==="

JSON="$("$GH_BIN" pr view "$PR" --repo "$REPO" --json number,state,isDraft,headRefOid,headRefName,mergeable,mergeStateStatus,labels,body 2>/dev/null)"
if [ -z "$JSON" ]; then
  # The number may be the ISSUE's, not the PR's: find the PR that closes it.
  FOUND="$("$GH_BIN" pr list --repo "$REPO" --state all --limit 60 --json number,body \
            --jq ".[]|select((.body//\"\")|test(\"(?i)(fixes|closes|resolve) #${PR}\\\\b\"))|.number" 2>/dev/null | head -1)"
  if [ -n "$FOUND" ]; then
    note "  (el numero dado es el del issue; el PR que lo cierra es #$FOUND)"
    PR="$FOUND"
    JSON="$("$GH_BIN" pr view "$PR" --repo "$REPO" --json number,state,isDraft,headRefOid,headRefName,mergeable,mergeStateStatus,labels,body 2>/dev/null)"
  fi
fi
[ -n "$JSON" ] || { echo "  FAIL no se pudo leer el PR (ni #$PR como PR ni como issue)"; exit 1; }

get() { printf '%s' "$JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$1',''))"; }

STATE="$(get state)";        DRAFT="$(get isDraft)";   HEAD="$(get headRefOid)"
MERGE="$(get mergeable)";    MS="$(get mergeStateStatus)"
BRANCH="$(get headRefName)"; BODY="$(printf '%s' "$JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['body'])")"
LABELS="$(printf '%s' "$JSON" | python3 -c "import json,sys; print(','.join(l['name'] for l in json.load(sys.stdin)['labels']))")"

note "state=$STATE draft=$DRAFT mergeable=$MERGE mergeState=$MS"
note "head=${HEAD:0:9} branch=$BRANCH labels=[$LABELS]"
note "body: $(printf '%s' "$BODY" | wc -l) lineas, $(printf '%s' "$BODY" | wc -c) bytes"

# The body in a file: the parser of the closing phrases and the validator of
# the upstream read it (it has newlines: it does not go in an argument).
BODYFILE="$(mktemp)"; printf '%s' "$BODY" > "$BODYFILE"

# 1. the head must equal the fork's head (the local head can be ahead of what was pushed)
FORK_HEAD="$(git -C "$SOLIDCRAFT_REPO" ls-remote fork "refs/heads/$BRANCH" 2>/dev/null | cut -c1-40)"
if [ -n "$FORK_HEAD" ]; then
  [ "$FORK_HEAD" = "$HEAD" ] && ok "el head del PR coincide con el del fork" \
                            || bad "el head del PR ($HEAD) NO coincide con el del fork ($FORK_HEAD)"
else
  note "  --   la rama $BRANCH no esta en el fork (PR de otra rama?)"
fi

# 2. the closing keywords: THE UPSTREAM IS THE AUTHORITY
#    The parser of the upstream (scripts/pr-checks/pr-checks.js:35-47,
#    parseClosing) is the one that says which issues a pull request closes.
#    Its rules, and the ones this script used to break:
#      * the '#' is REQUIRED: "Fixes #10181" closes an issue and "This fix 3
#        problems." is prose. The regex of this script had the '#'
#        OPTIONAL, so a sentence of prose was a closing phrase AND its
#        number became the SLOT of the gate: the verifier then looked for
#        the gate of the slot 3 and FAILED a perfectly valid pull request;
#      * it counts ISSUES, not LINES: "Fixes #10181, #10182" closes TWO
#        issues (the old script saw ONE line and let the PR through), and
#        the same issue twice closes ONE;
#      * a reference to another repository ("Fixes other/repo#5") closes
#        nothing of ours.
#    The rule is COPIED here (the upstream's parser is JavaScript and lives
#    in another repository); the semantics are the ones of the upstream.
CLOSING_RAW="$(python3 - "$REPO" "$BODYFILE" <<'PY'
import re, sys

repo = (sys.argv[1] or "").strip().lower()
with open(sys.argv[2], encoding="utf-8", errors="replace") as fh:
    body = fh.read()

# stripNoise: the upstream's (scripts/pr-checks/pr-checks.js:25-31). The
# comments of the template and the code blocks hold EXAMPLES, not claims.
text = re.sub(r"<!--.*?-->", "", body, flags=re.S)
text = re.sub(r"```.*?```", "", text, flags=re.S)
text = re.sub(r"~~~.*?~~~", "", text, flags=re.S)
text = re.sub(r"`[^`\n]*`", "", text)

# parseClosing: the upstream's (scripts/pr-checks/pr-checks.js:38).
CLOSING = re.compile(
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?[ \t]+"
    r"((?:(?:[\w.-]+/[\w.-]+)?#\d+(?:[ \t]*(?:,|and|&)[ \t]*)?)+)",
    re.IGNORECASE)
REF = re.compile(r"(?:([\w.-]+/[\w.-]+))?#(\d+)")

issues = []   # the unique issues, in the order of the body
first = ""    # the issue of the FIRST closing phrase: the slot of the gate
for m in CLOSING.finditer(text):
    for r in REF.finditer(m.group(1)):
        owner, number = r.group(1), r.group(2)
        if owner and repo and owner.lower() != repo:
            continue          # a reference to another repository closes nothing of ours
        if number not in issues:
            issues.append(number)
        if not first:
            first = number

print("count=%d" % len(issues))
print("first=%s" % first)
print("issues=%s" % " ".join("#" + i for i in issues))
PY
)"
CLOSED_COUNT=""
CLOSED_FIRST=""
CLOSED_LIST=""
while IFS='=' read -r _k _v; do
  case "$_k" in
    count)  CLOSED_COUNT="$_v" ;;
    first)  CLOSED_FIRST="$_v" ;;
    issues) CLOSED_LIST="$_v" ;;
  esac
done <<EOF
$CLOSING_RAW
EOF

# A REFERENCE IS NOT A CLOSING PHRASE (2026-11-03). GitHub only closes an
# issue when the body says close/fix/resolve, so 'Addresses #N' LEAVES THE
# ISSUE OPEN, on purpose: there are tracking issues that a partial fix must
# not close (see the tracking issue of the repo: quote the typed text, do
# not reject the ids). The gate used to reject those bodies outright, so
# the pull requests that did the right thing were the ones it blocked.
REFERENCE_RE='\b(addresses|refs?|see|part of|related to|follows up)\s*:?\s*#([0-9]+)'
REFERENCES="$(printf '%s' "$BODY" | grep -inE "$REFERENCE_RE" || true)"
if [ -z "$CLOSED_COUNT" ]; then
  # El parser no pudo correr: eso NO es un verde (nadie sabe).
  unknown "no se pudo leer el body con el parser de cierre del upstream"
elif [ "$CLOSED_COUNT" = "0" ]; then
  # A docs-only PR with no issue to close is legitimate: it references no issue
  # and closes none. Anything else must say "Fixes #N".
  if [ -n "$REFERENCES" ]; then
    note "  el body NO cierra ningun issue: solo lo referencia ($(printf '%s\n' "$REFERENCES" | wc -l) referencia(s)). El issue queda abierto, a proposito."
  elif printf '%s' "$BODY" | grep -qiE 'no issue|documentation only|docs-only|without an issue'; then
    note "  --   el body no cierra ningun issue (y dice por que: es un PR sin issue)"
  else
    bad "el body no tiene ninguna frase de cierre (debe tener 'Fixes #N', 'Addresses #N', o decir que no hay issue)"
  fi
else
  note "  issues que cierra el body: $CLOSED_COUNT ($CLOSED_LIST)"
  # More than one closing phrase means the PR closes more than it should.
  [ "$CLOSED_COUNT" -gt 1 ] && bad "el body cierra $CLOSED_COUNT issues: solo el que nombra el PR debe cerrarse"
fi

# 3. exactly one 'Changes a default:' line
# THE UPSTREAM IS THE AUTHORITY (2026-11-03): the CI check (scripts/pr-checks/
# pr-checks.js) matches /^[ \t]*(?:[-*][ \t]+)?Changes a default:/i and NOTHING
# else. This gate used to accept 'Changes to default:' as well, so a body the
# upstream rejects passed here: the gate was more permissive than the
# authority, which is backwards. Three of our pull requests (#11388, #11359,
# #11205) were published with 'Changes to default: no' and the CI killed them.
DEF="$(printf '%s' "$BODY" | grep -ciE '^[[:space:]]*([-*][[:space:]]+)?Changes a default:' || true)"
[ "$DEF" = "1" ] && ok "una linea 'Changes a default:'" \
  || bad "lineas 'Changes a default:' (exactamente como las pide el upstream): $DEF (debe ser 1). 'Changes to default:' NO vale: el CI la rechaza."

# 4. the upstream parser on the body
if [ -x "$LOOP_DIR/bin/pr-defaults-line.sh" ]; then
  if bash "$LOOP_DIR/bin/pr-defaults-line.sh" --body "$BODYFILE" >/dev/null 2>&1; then
    ok "el validador de defaults del upstream pasa"
  else
    bad "el validador de defaults del upstream FALLA"
  fi
else
  note "  --   no hay pr-defaults-line.sh: no se pudo validar"
fi
rm -f "$BODYFILE"

# 5. a body must not cite paths that only exist on the local disk
LOCAL="$(printf '%s' "$BODY" | grep -cE "${HOME:-/home/user}|~/\.local|logs/[a-z0-9-]*\.log" || true)"
[ "$LOCAL" = "0" ] && ok "el body no cita rutas locales" \
                    || bad "el body cita $LOCAL ruta(s) locales (el reviewer no puede abrirlas)"

# 6. a draft must say why it is a draft
if [ "$DRAFT" = "True" ]; then
  if printf '%s' "$BODY" | grep -qiE 'evidence|screenshot|pending|draft'; then
    ok "el PR es draft y el body explica por que"
  else
    bad "el PR es draft pero el body no dice por que"
  fi
fi

# 7. the checks: THE STATE of each one, not its NAME
#    WHY (2026-11-17): the checks were read with a grep over their NAMES: a
#    check whose name contains "fail" ("failing to provision") counted as a
#    failure, and a check whose name says nothing about the filter was NOT
#    counted at all: the three that decide if a pull request is mergeable
#    ("Native Linux tests", "Native Linux Clippy", "Build tests") were among
#    the ones that were never looked at. And the exit code of `gh pr checks`
#    was thrown away: when `gh` failed (auth, network, "no checks reported")
#    the TEXT of its error went into the output, that text does not contain
#    "fail", and the verifier said "VEREDICTO: todo en orden" about a pull
#    request whose CI it never read.
#    Now the state of every check is read from the API and the exit code of
#    `gh` is checked: a CI that could not be read is NOT a green.
#
#    The list of the EXEMPT checks is EXPLICIT and SHORT: a check that is red
#    and is NOT in it BLOCKS the pull request.
is_exempt_check() {
  case "$1" in
    # The bots of the upstream. They run with pull_request_target and NEVER
    # check out the code of the pull request (the upstream says so in the
    # workflow), so their red state is about the base branch and not about
    # the change.
    "Claim bot"|"Triage bot") return 0 ;;
    *) return 1 ;;
  esac
}
CHECKS_ERRFILE="$(mktemp)"
CHECKS_FILE="$(mktemp)"
CHECKS_JSON="$("$GH_BIN" pr checks "$PR" --repo "$REPO" --json name,state,bucket 2>"$CHECKS_ERRFILE")"
CHECKS_RC=$?
printf '%s' "$CHECKS_JSON" > "$CHECKS_FILE"
# The state of every check: the bucket is the one of `gh` ("pass", "fail",
# "pending", "skipping", "cancel"); without it, the state decides.
CHECKS_LINES="$(python3 - "$CHECKS_FILE" <<'PY'
import json, sys

BUCKET = {"pass": "pass", "fail": "fail", "pending": "pending",
          "skipping": "skipping", "cancel": "cancel"}
STATE = {"SUCCESS": "pass", "NEUTRAL": "pass", "SKIPPED": "skipping",
         "CANCELLED": "cancel", "FAILURE": "fail", "TIMED_OUT": "fail",
         "ACTION_REQUIRED": "fail", "STARTUP_FAILURE": "fail", "STALE": "fail",
         "PENDING": "pending", "QUEUED": "pending", "IN_PROGRESS": "pending",
         "WAITING": "pending", "REQUESTED": "pending"}

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    data = None
if not isinstance(data, list):
    print("PARSED=0")
    raise SystemExit(0)
print("PARSED=%d" % len(data))
for c in data:
    if not isinstance(c, dict):
        continue
    name = str(c.get("name") or "?")
    bucket = str(c.get("bucket") or "").strip().lower()
    state = str(c.get("state") or "").strip().upper()
    # Un estado desconocido NO se da por bueno (la regla de pipeline.py): no
    # es un rojo, pero tampoco es un verde.
    cat = BUCKET.get(bucket) or STATE.get(state) or "pending"
    print("%s\t%s" % (cat, name))
PY
)"
CHECKS_PARSED=0
CHECKS_TOTAL=0
CHECKS_RED_N=0
CHECKS_EXEMPT_N=0
CHECKS_PENDING_N=0
CHECKS_SKIPPING_N=0
CHECKS_CANCEL_N=0
CHECKS_RED=""
CHECKS_RED_EXEMPT=""
CHECKS_PENDING=""
CHECKS_SKIPPING=""
CHECKS_CANCEL=""
while IFS=$'\t' read -r _cat _nm; do
  case "$_cat" in
    PARSED=*) CHECKS_PARSED="${_cat#PARSED=}"; continue ;;
  esac
  [ -n "$_cat" ] || continue
  CHECKS_TOTAL=$(( CHECKS_TOTAL + 1 ))
  case "$_cat" in
    fail)
      if is_exempt_check "$_nm"; then
        CHECKS_EXEMPT_N=$(( CHECKS_EXEMPT_N + 1 ))
        CHECKS_RED_EXEMPT="$CHECKS_RED_EXEMPT $_nm"
      else
        CHECKS_RED_N=$(( CHECKS_RED_N + 1 ))
        CHECKS_RED="$CHECKS_RED $_nm"
      fi ;;
    pending)  CHECKS_PENDING_N=$(( CHECKS_PENDING_N + 1 ));  CHECKS_PENDING="$CHECKS_PENDING $_nm" ;;
    skipping) CHECKS_SKIPPING_N=$(( CHECKS_SKIPPING_N + 1 )); CHECKS_SKIPPING="$CHECKS_SKIPPING $_nm" ;;
    cancel)   CHECKS_CANCEL_N=$(( CHECKS_CANCEL_N + 1 ));   CHECKS_CANCEL="$CHECKS_CANCEL $_nm" ;;
  esac
done <<EOF
$CHECKS_LINES
EOF
CHECKS_ERR1="$(head -1 "$CHECKS_ERRFILE" 2>/dev/null | tr -d '\r')"
rm -f "$CHECKS_FILE" "$CHECKS_ERRFILE"
note "  checks: $CHECKS_TOTAL en total, $CHECKS_RED_N en rojo (bloquean), $CHECKS_EXEMPT_N exentos, $CHECKS_PENDING_N pendientes, $CHECKS_SKIPPING_N en skipping, $CHECKS_CANCEL_N cancelados"
if [ "$CHECKS_PARSED" -eq 0 ]; then
  # THE CI COULD NOT BE READ. That is NOT a red (a check that could not run
  # is not a red) but it is also NOT a green: nobody knows. UNKNOWN.
  unknown "no se pudo leer el CI del PR (gh pr checks salio con rc=$CHECKS_RC${CHECKS_ERR1:+: $CHECKS_ERR1})"
else
  if [ -n "$CHECKS_RED" ]; then
    bad "check(s) en rojo que bloquean el PR:$CHECKS_RED"
    note "  --   mira el log del run mas NUEVO (los viejos suelen estar cancelados)"
  fi
  if [ "$CHECKS_RC" -ne 0 ] && [ "$CHECKS_RC" -ne 8 ]; then
    # `gh pr checks` salio con un codigo que no es 0 (ni el 8 de "pending"):
    # o no pudo leer el rollup, o leyo algo a medias. El rollup que imprime
    # no alcanza para decir que el CI esta verde: UNKNOWN. (El 8 es el de
    # "checks pending": el CI todavia no dio veredicto, y eso es un estado
    # conocido, no un "no se sabe".)
    unknown "el CI del PR no se pudo leer bien (gh pr checks salio con rc=$CHECKS_RC${CHECKS_ERR1:+: $CHECKS_ERR1})"
  fi
  [ -n "$CHECKS_RED_EXEMPT" ] && note "  --   check(s) en rojo EXENTOS (no bloquean):$CHECKS_RED_EXEMPT"
  [ -n "$CHECKS_PENDING" ] && note "  --   check(s) pendientes:$CHECKS_PENDING"
  [ -n "$CHECKS_CANCEL" ] && note "  --   check(s) cancelados:$CHECKS_CANCEL (un run viejo cancelado no es un rojo del PR)"
  if [ -n "$CHECKS_SKIPPING" ]; then
    if [ "$DRAFT" = "True" ]; then
      # The repo's own workflow: "Draft pull requests run no CI. It starts when the PR is
      # marked ready for review". A draft with everything skipping is the DESIGN, not a
      # problem to fix.
      note "  --   los checks en skipping: el PR es DRAFT y el CI del repo arranca al pasarlo a ready"
    else
      # Not a draft: the heavy jobs of a PR wait for the maintainer's approved-for-ci
      # label, and the agent can never add it.
      note "  --   los checks en skipping esperan el label approved-for-ci del maintainer (el agente nunca lo agrega)"
    fi
  fi
fi

# 8. the local gate verdict of the slot of this PR
#    WHY THE VERDICT IS NOT OPTIONAL (01-11-2026): the scoped gate
#    (VERDE-SCOPE) is the ONLY thing that publishes, so a PR whose gate
#    never ran is NOT ready to publish. The absence of the verdict used to
#    be a note ("-- no hay veredicto de gate") and the script said
#    "VEREDICTO: todo en orden": a FALSE green. Now it is a FAIL.
#    WHY THE SLOT IS NOT ALWAYS THE ISSUE OF THE BODY (01-11-2026): the
#    whole block was inside `if [ -n "$ISSUE" ]`, so a PR that closes no
#    issue (a docs PR, or one whose body forgot the closing phrase)
#    skipped the verification of the gate COMPLETELY: the script never
#    mentioned the gate and said "todo en orden". The most exposed PR was
#    the one that was never checked.
#    The slot is looked for in three places, in this order:
#      1. the third argument of the script (the slot to check): it wins;
#      2. the issue the body closes ("Fixes #N" and the other closing
#         phrases the upstream parser accepts): the FIRST ONE of the body,
#         and only a phrase that names an issue with its '#' (a sentence of
#         prose is not a closing phrase and its number is not a slot);
#      3. the number in the branch name ("fix/issue-NNNN-..."): a fallback.
#    When none of the three says which slot this is, the gate CANNOT be
#    verified: that is a FAIL of its own (not a silence, and not the same
#    FAIL as a red gate).
#    WHY THE SHA IS COMPARED (31-10-2026): the verdict file is per SLOT, not
#    per commit, and it is NOT deleted when the head moves. A verdict of an
#    older commit (a rebase, a new push, a slot that ran the gate before the
#    last change) reads as "VERDE-SCOPE" and this script used to call the
#    gate green without noticing that the verdict judged OTHER code. The
#    verdict is only the verdict of the commit it names.
# Is this pull request DOCUMENTATION ONLY? The criterion is the UPSTREAM's
# own (scripts/pr-checks/pr-checks.js, isDocsOnly): every file of the pull
# request matches the DOC_FILE pattern (docs/, a .md, LICENSE, the templates
# of the issues). A pull request that is only documentation has no code to
# compile, so it has no slot and no gate: see the note below.
DOCS_ONLY="0"
PR_FILES="$("$GH_BIN" pr view "$PR" --repo "$REPO" --json files --jq '.files[].path' 2>/dev/null || true)"
if [ -n "$PR_FILES" ]; then
  DOCS_ONLY="1"
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    case "$_f" in
      docs/*|*.md|LICENSE*|.github/ISSUE_TEMPLATE/*|.github/pull_request_template.md) ;;
      *) DOCS_ONLY="0"; break ;;
    esac
  done <<EOF
$PR_FILES
EOF
fi

# THE SLOT COMES FROM THE CLOSING PHRASE (the upstream's parser): the FIRST
# issue of the body, and only an issue that a closing phrase names with its
# '#'. A sentence of prose ("This fix 3 problems.") closes nothing and its
# number is NOT a slot: the old regex made it one, and the verifier then
# failed a valid pull request looking for the gate of a slot that does not
# exist.
ISSUE="$CLOSED_FIRST"
SLOT_FROM_BRANCH="$(printf '%s' "$BRANCH" | grep -oiE 'issue[-_/]?([0-9]+)' | head -1 | grep -oE '[0-9]+' | head -1 || true)"
SLOT=""
SLOT_FROM=""
if [ -n "$SLOT_ARG" ]; then
  SLOT="$SLOT_ARG"; SLOT_FROM="el argumento"
elif [ -n "$ISSUE" ]; then
  SLOT="$ISSUE"; SLOT_FROM="el body (cierra el issue #$ISSUE)"
elif [ -n "$SLOT_FROM_BRANCH" ]; then
  SLOT="$SLOT_FROM_BRANCH"; SLOT_FROM="la rama ($BRANCH)"
fi
if [ -n "$SLOT_ARG" ] && [ -n "$ISSUE" ] && [ "$SLOT_ARG" != "$ISSUE" ]; then
  bad "el slot que pediste ($SLOT_ARG) NO es el issue que cierra el PR ($ISSUE): revisa cual de los dos es el correcto (el gate se verifica sobre el slot $SLOT_ARG)"
fi
if [ -z "$SLOT" ]; then
  # WHY A DOCS-ONLY PR IS NOT A FAILURE (01-11-2026): a PR that closes no
  # issue AND changes no default cannot have a slot, because a slot is the
  # scope of a GATE, and a gate judges CODE. A pull request that only
  # documents how the repo works has no code to compile: demanding a slot
  # for it means the verifier reports a failure that cannot be fixed by
  # anybody, and a verifier that cries wolf is a verifier nobody reads.
  # The rule that decides it is the UPSTREAM's own: a docs-only pull
  # request is exempt from the check of the line of the defaults
  # (scripts/pr-checks/pr-checks.js, isDocsOnly). The same exemption
  # applies to the gate.
  if [ "$DOCS_ONLY" = "1" ]; then
    note "  --   este PR no cierra ningun issue y es de documentacion: no hay slot y no hay gate que correr (la exencion de docs del upstream)"
  else
    bad "no se puede verificar el gate de este PR: el body no dice que issue cierra, la rama ($BRANCH) no dice el slot y no se paso ninguno -> pasalo: bash bin/verify-pr.sh $PR $REPO <slot>"
  fi
else
  VF="$LOOP_DIR/gates/$SLOT/scope.verdict"
  # THE VERDICT BELONGS TO THE COMMIT, NOT TO THE NAME OF THE SLOT (2026-11-03).
  # The slot is a convention: the work of the issue 11641 was gated under the
  # slot "dependents", and the verifier could not find it. What has to be
  # checked is the COMMIT, and re-running a gate of forty minutes to recompute
  # a verdict that already exists is exactly the waste this loop fights.
  if [ ! -f "$VF" ]; then
    _head_full="$(printf '%s' "$HEAD" | tr -d '[:space:]')"
    for _cand in "$LOOP_DIR"/gates/*/scope.verdict; do
      [ -f "$_cand" ] || continue
      _csha="$(grep -E '^SHA=' "$_cand" | head -1 | cut -d= -f2 | tr -d '[:space:]')"
      [ -n "$_csha" ] || continue
      case "$_head_full" in
        "$_csha"*) VF="$_cand"; SLOT="$(basename "$(dirname "$_cand")")"; break ;;
      esac
    done
  fi
  if [ -f "$VF" ]; then
  # THE EFFECTIVE VERDICT (2026-11-03): upstream merged the SMLib v1.1.0-alpha
  # kernel migration (#11351) and left 26 tests of the workspace broken in
  # main. The gate counts every failure of its scope as NEW_FAILURES, so
  # every PR of ours came out ROJO for reasons that have nothing to do
  # with the change. gate-baseline.sh subtracts the failures that were
  # already failing in origin/main, and leaves the raw verdict alone.
  # It is recalculated here, on demand: the baseline can go stale.
  bash "$ORCH_DIR/bin/gate-baseline.sh" "$SLOT" >/dev/null 2>&1 || true
  EF="$LOOP_DIR/gates/$SLOT/scope.effective.verdict"
  [ -f "$EF" ] && VF="$EF"
  V="$(grep -E '^VERDICT|^NEW_FAILURES|^SHA' "$VF" | tr '\n' ' ')"
  V="$(grep -E '^PREEXISTING_FAILURES=' "$VF" | tr '\n' ' ')$V"
    note "  gate local (slot $SLOT, de $SLOT_FROM): $V"
    VERDICT_SHA="$(grep -E '^SHA=' "$VF" | head -1 | cut -d= -f2 | tr -d '[:space:]')"
    HEAD_SHA="$(printf '%s' "$HEAD" | tr -d '[:space:]')"
    # The verdict file names the commit with the SHORT sha (10 chars, what
    # the gate writes) and the PR gives the FULL one (40). They are the same
    # commit when the full one STARTS with the short one: the comparison is
    # by prefix, never by equality of two different lengths.
    SAME_SHA="no"
    if [ -n "$VERDICT_SHA" ] && [ -n "$HEAD_SHA" ]; then
      case "$HEAD_SHA" in
        "$VERDICT_SHA"*) SAME_SHA="si" ;;
      esac
    fi
    if [ -z "$VERDICT_SHA" ]; then
      bad "el veredicto del gate del slot $SLOT no dice que commit judged: no se puede comparar"
    elif [ -z "$HEAD_SHA" ]; then
      bad "no se pudo leer el head del PR: no se puede comprobar que el gate lo haya judged"
    elif [ "$SAME_SHA" != "si" ]; then
      bad "el gate local del slot $SLOT judged el commit $VERDICT_SHA, NO el head del PR ($HEAD_SHA): el veredicto no sirve"
    else
      printf '%s' "$V" | grep -q 'VERDICT=VERDE-SCOPE' && ok "el gate local del slot $SLOT esta verde (commit $VERDICT_SHA)" \
                                                     || bad "el gate local del slot $SLOT NO esta verde (leé el archivo: $VF)"
    fi
  else
    bad "falta el veredicto del gate del slot $SLOT (de $SLOT_FROM): corré el gate de este slot antes de publicar (bash bin/gate.sh $SLOT <sha>)"
  fi
fi

note ""
if [ "$FAIL" != "0" ]; then
  note "VEREDICTO: hay que arreglar lo marcado FAIL"
  exit 1
elif [ "$UNKNOWN" != "0" ]; then
  note "VEREDICTO: no se pudo verificar todo (UNKNOWN): no se puede afirmar que el PR esta en orden"
  exit 6
else
  note "VEREDICTO: todo en orden"
  exit 0
fi
