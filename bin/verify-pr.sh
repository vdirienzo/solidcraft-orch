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
# Exit 0 when everything the orchestrator checks is in order, 1 otherwise.
set -uo pipefail
PR="${1:?usage: verify-pr.sh <pr-number> [repo] [slot]}"
REPO="${2:-tangency-labs/solidcraft}"
SLOT_ARG="${3:-}"
# The paths come from the environment, with the default of THIS
# machine: the other PC exports its own (see docs/portable-orchestrator.md).
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
# The loop's directory: the gate verdicts live under it (gates/<slot>/).
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
# The checkout of the product: the fork's head is read from it.
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
FAIL=0
note() { printf '%s\n' "$*"; }
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; FAIL=1; }

note "=== PR #$PR ($REPO) ==="

JSON="$(gh pr view "$PR" --repo "$REPO" --json number,state,isDraft,headRefOid,headRefName,mergeable,mergeStateStatus,labels,body 2>/dev/null)"
if [ -z "$JSON" ]; then
  # The number may be the ISSUE's, not the PR's: find the PR that closes it.
  FOUND="$(gh pr list --repo "$REPO" --state all --limit 60 --json number,body \
            --jq ".[]|select((.body//\"\")|test(\"(?i)(fixes|closes|resolve) #${PR}\\\\b\"))|.number" 2>/dev/null | head -1)"
  if [ -n "$FOUND" ]; then
    note "  (el numero dado es el del issue; el PR que lo cierra es #$FOUND)"
    PR="$FOUND"
    JSON="$(gh pr view "$PR" --repo "$REPO" --json number,state,isDraft,headRefOid,headRefName,mergeable,mergeStateStatus,labels,body 2>/dev/null)"
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

# 1. the head must equal the fork's head (the local head can be ahead of what was pushed)
FORK_HEAD="$(git -C "$SOLIDCRAFT_REPO" ls-remote fork "refs/heads/$BRANCH" 2>/dev/null | cut -c1-40)"
if [ -n "$FORK_HEAD" ]; then
  [ "$FORK_HEAD" = "$HEAD" ] && ok "el head del PR coincide con el del fork" \
                            || bad "el head del PR ($HEAD) NO coincide con el del fork ($FORK_HEAD)"
else
  note "  --   la rama $BRANCH no esta en el fork (PR de otra rama?)"
fi

# 2. the closing keywords: the upstream parser closes every issue it finds
#    THE CLOSING PHRASES ARE ONE REGEX, USED TWICE: here (to count them) and
#    below (to know WHICH issue the PR closes, and therefore which slot's
#    gate has to have run for it).
CLOSING_RE='\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\s*:?\s*#?([0-9]+)'
CLOSED="$(printf '%s' "$BODY" | grep -inE "$CLOSING_RE" || true)"
# A REFERENCE IS NOT A CLOSING PHRASE (2026-11-03). GitHub only closes an
# issue when the body says close/fix/resolve, so 'Addresses #N' LEAVES THE
# ISSUE OPEN, on purpose: there are tracking issues that a partial fix must
# not close (see the tracking issue of the repo: quote the typed text, do
# not reject the ids). The gate used to reject those bodies outright, so
# the pull requests that did the right thing were the ones it blocked.
REFERENCE_RE='\b(addresses|refs?|see|part of|related to|follows up)\s*:?\s*#([0-9]+)'
REFERENCES="$(printf '%s' "$BODY" | grep -inE "$REFERENCE_RE" || true)"
if [ -z "$CLOSED" ]; then
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
  N="$(printf '%s\n' "$CLOSED" | wc -l)"
  note "  frases de cierre: $N"
  printf '%s\n' "$CLOSED" | sed 's/^/       /'
  # More than one closing phrase means the PR closes more than it should.
  [ "$N" -gt 1 ] && bad "el body cierra $N issues: solo el que nombra el PR debe cerrarse"
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
BODYFILE="$(mktemp)"; printf '%s' "$BODY" > "$BODYFILE"
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

# 7. the checks
CHECKS="$(gh pr checks "$PR" --repo "$REPO" 2>&1 | head -20)"
SKIPPED="$(printf '%s' "$CHECKS" | grep -ci 'skipping' || true)"
FAILED="$(printf '%s' "$CHECKS" | grep -ciE '\bfail' || true)"
PENDING="$(printf '%s' "$CHECKS" | grep -ci 'pending' || true)"
note "  checks: skipping=$SKIPPED fail=$FAILED pending=$PENDING"
# The light checks are the ones the agent can influence: the pr-checks bots, the
# defaults line, the duplicate check, the format and repository checks. They run
# without the maintainer's label. The HEAVY ones wait for approved-for-ci.
# On a DRAFT the workflow skips even these ("Draft pull requests run no CI"), so
# only a FAIL of a light check is a real problem, and only when the PR is not a draft.
LIGHT_BAD="$(printf '%s' "$CHECKS" | grep -iE 'defaults|duplicate|claim|kernel|triage|select|format|repository|lint' | grep -ciE '\bfail' || true)"
LIGHT_SKIP="$(printf '%s' "$CHECKS" | grep -iE 'defaults|duplicate|claim|kernel|triage|select|format|repository|lint' | grep -ci 'skipping' || true)"
if [ "$DRAFT" != "True" ] && [ "$LIGHT_BAD" -gt 0 ]; then
  bad "$LIGHT_BAD check(s) LIGERO(s) en fail (esos si dependen de nosotros)"
fi
if [ "$DRAFT" != "True" ] && [ "$LIGHT_SKIP" -gt 0 ]; then
  note "  --   $LIGHT_SKIP check(s) ligero(s) en skipping en un PR que NO es draft: eso si es un problema"
fi
if [ "$SKIPPED" -gt 0 ]; then
  if [ "$DRAFT" = "True" ]; then
    # The repo's own workflow: "Draft pull requests run no CI. It starts when the PR is
    # marked ready for review". A draft with everything skipping is the DESIGN, not a
    # problem to fix.
    note "  --   los checks pesados estan en skipping porque el PR es DRAFT: el CI del repo arranca al pasarlo a ready"
  else
    # Not a draft: the heavy jobs of a PR wait for the maintainer's approved-for-ci
    # label, and the agent can never add it.
    note "  --   los checks PESADOS esperan el label approved-for-ci del maintainer (el agente nunca lo agrega)"
  fi
fi
[ "$FAILED" -gt 0 ] && note "  --   hay checks en fail: mira el log del run mas NUEVO (los viejos suelen estar cancelados)"

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
#    the only one that was never checked.
#    The slot is looked for in three places, in this order:
#      1. the third argument of the script (the slot to check): it wins;
#      2. the issue the body closes ("Fixes #N" and the other closing
#         phrases the upstream parser accepts);
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
PR_FILES="$(gh pr view "$PR" --repo "$REPO" --json files --jq '.files[].path' 2>/dev/null || true)"
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

ISSUE="$(printf '%s' "$BODY" | grep -oiE "$CLOSING_RE" | head -1 | grep -oE '[0-9]+' | head -1 || true)"
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
[ "$FAIL" = "0" ] && note "VEREDICTO: todo en orden" || note "VEREDICTO: hay que arreglar lo marcado FAIL"
exit $FAIL
