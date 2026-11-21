#!/usr/bin/env bash
# claim-verify.sh - the arbiter of the claim of an issue.
#
# WHAT IT DECIDES: whether an issue is still free for us or another pull
# request took it. The gate calls it BEFORE it compiles (eight minutes of
# the CPU of the machine) and refuses to run when the claim is lost (the
# gate exits 4). bin/publish-pr.sh calls it before opening the draft.
#
# WHY IT EXISTS: the upstream bot puts the label 'in progress' with a DELAY,
# so between the survey and the draft another agent can take the issue. We
# lost #10134, #10138 and #10079 that way on 31-10-2026 (RULES.md, step 5).
#
# LA REGLA YA NO VIVE ACA (2026-11-21): vive en bin/claim_rule.py, la UNICA
# implementacion de "quien tiene el claim" (la usan tambien next-issue.py e
# issue-card.py). Es la UNION de los dos bots del upstream: claim.js
# (referencedIssues: `#N` en el titulo, `Fixes #N` en el body SIN sacar nada,
# MAX_REFS) y pr-checks.js (parseClosing: la lista, owner/repo#N, sin el
# ruido). El filtro jq de antes sacaba los bloques de codigo como pr-checks.js,
# y claim.js no: un `Fixes #N` en un bloque de codigo era un claim para el bot
# y "libre" para nosotros, la direccion cara. bin/test-claim-rule.py compara
# el modulo con el claim.js y el pr-checks.js de verdad.
#
# THE RULE OF THE SAME AUTHOR: our own pull requests do NOT compete with us
# (upstream scripts/claim/claim.js: a pull request does not lose against an
# older pull request of the same author). Without our PR number there is no
# way to tell ours from the others, so every pull request that claims the
# issue blocks it, and so does the HOLD of claim.js (somebody assigned, or
# the 'in progress' label of somebody else's /claim).
#
# DE DONDE SALEN LOS PRs (2026-11-21):
#   * de la FOTO de bin/gh_snapshot.py, con --snapshot FILE (o GH_SNAPSHOT),
#     si esta completa, tiene menos de --max-age-min minutos (o
#     GH_SNAPSHOT_MAX_AGE_MIN, 15 por defecto) y conoce el issue: cero
#     llamadas a GitHub;
#   * si no, EN VIVO: `gh pr list --limit 2000` con un PRE-filtro jq que solo
#     deja los PRs cuyo texto contiene "#N" (la regla la aplica claim_rule.py,
#     no el jq), mas `gh issue view` para el hold cuando no hay PR nuestro.
# Sin --snapshot ni GH_SNAPSHOT es SIEMPRE en vivo: el gate y publish-pr.sh,
# los que deciden lo irreversible, no leen una foto vieja sin pedirlo.
#
# Usage:
#   bash bin/claim-verify.sh <issue> [our_pr]
#   bash bin/claim-verify.sh <issue> --our-pr <our_pr>
#   bash bin/claim-verify.sh <issue> [--our-pr <our_pr>] --snapshot FILE [--max-age-min N]
#
# The output (the contract with gate.sh, publish-pr.sh, close-slot.sh and
# loop/bin/claim-race.sh, which parse it): "issue=N PRs que lo mencionan: ..."
# and one "VEREDICTO=OK|OCUPADO|PERDIDO ..." line on stdout, or
# "VEREDICTO=ERROR ..." on stderr. The notes (where the PRs came from) go to
# stderr and never carry a '#'.
#
# Exit codes (the contract with bin/gate.sh and bin/publish-pr.sh):
#   0  -> the claim is OURS: no pull request of ANOTHER author with a lower
#         number claims the issue (or nobody claims it)
#   1  -> the claim is LOST (or the issue is TAKEN, without our PR)
#   2  -> usage error, or it could not be verified (UNKNOWN, never "no")
#
# If it is lost, the caller has to:
#   gh pr close <our_pr>            (close ours)
#   bash bin/slot-lock.sh --slot N --release
set -uo pipefail

usage() {
  echo "uso: bash bin/claim-verify.sh <issue> [nuestro_pr|--our-pr <nuestro_pr>] [--snapshot FILE] [--max-age-min N]" >&2
}

ISSUE=""
OUR_PR=""
ISSUE_SET=0
SNAPSHOT="${GH_SNAPSHOT:-}"
MAX_AGE="${GH_SNAPSHOT_MAX_AGE_MIN:-15}"
while [ $# -gt 0 ]; do
  case "$1" in
    --our-pr)
      shift
      if [ $# -eq 0 ]; then
        echo "--our-pr necesita el numero de nuestro pull request" >&2
        usage
        exit 2
      fi
      OUR_PR="$1"
      ;;
    --our-pr=*)
      OUR_PR="${1#--our-pr=}"
      ;;
    --snapshot)
      shift
      if [ $# -eq 0 ]; then
        echo "--snapshot necesita el archivo de la foto" >&2
        usage
        exit 2
      fi
      SNAPSHOT="$1"
      ;;
    --snapshot=*)
      SNAPSHOT="${1#--snapshot=}"
      ;;
    --max-age-min)
      shift
      MAX_AGE="${1:-}"
      ;;
    --max-age-min=*)
      MAX_AGE="${1#--max-age-min=}"
      ;;
    -*)
      echo "opcion desconocida: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [ "$ISSUE_SET" -eq 0 ]; then
        ISSUE="$1"
        ISSUE_SET=1
      else
        OUR_PR="$1"
      fi
      ;;
  esac
  shift
done

if [ -z "$ISSUE" ]; then
  usage
  exit 2
fi
if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "el issue tiene que ser un numero: '$ISSUE'" >&2
  exit 2
fi
if [ -n "$OUR_PR" ] && ! [[ "$OUR_PR" =~ ^[0-9]+$ ]]; then
  echo "el pull request nuestro tiene que ser un numero: '$OUR_PR'" >&2
  exit 2
fi
if ! [[ "$MAX_AGE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "--max-age-min tiene que ser un numero de minutos: '$MAX_AGE'" >&2
  exit 2
fi
# Numbers without leading zeros: "0042" and "42" are the same issue.
ISSUE=$((10#$ISSUE))
[ -n "$OUR_PR" ] && OUR_PR=$((10#$OUR_PR))

# The gh of the machine, or the one of a test (the stub lives OUTSIDE the
# PATH: README rule 4). Without this the only way to test the script is a
# fake gh on the PATH, which is exactly what rule 4 forbids.
GH_BIN="${GH_BIN:-gh}"

REPO="${SC_REPO:-tangency-labs/solidcraft}"
# The top of the open pull requests that are asked for (9-11-2026): the
# upstream has 1009 open and with 1000 the guard went BLIND for every issue
# (it did not find the claim of anybody). MEASURED: `gh pr list --limit 2000`
# returns the 1009, all of them with their body. The 1000 was a number of
# ours, not a top of the tool.
LIMIT="${SC_PR_LIMIT:-2000}"

# --- the rule ------------------------------------------------------------------
# The module next to this script, or the one of the orchestrator's bin (a
# copy of this script that runs outside bin/). Without it the answer is
# UNKNOWN: an arbiter without its rule does not say "free".
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULE="$HERE/claim_rule.py"
[ -f "$RULE" ] || RULE="${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}/bin/claim_rule.py"
if [ ! -f "$RULE" ]; then
  echo "VEREDICTO=ERROR no esta la regla del claim (claim_rule.py) junto a $0" >&2
  exit 2
fi

# --- who we are --------------------------------------------------------------
# The author of OUR pull requests. The SAME source as bin/publish-pr.sh:
# FORK_OWNER of the environment, then the FORK_OWNER of the config.env of
# the loop, then the authenticated user of gh. The default is the fork of
# this repo (bin/pipeline.py: FORK = "vdirienzo/solidcraft").
OUR_AUTHOR_DEFAULT="vdirienzo"
LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
OUR_AUTHOR=""

resolve_our_author() {
  OUR_AUTHOR="${FORK_OWNER:-}"
  if [ -z "$OUR_AUTHOR" ] && [ -r "$LOOP_DIR/config.env" ]; then
    OUR_AUTHOR="$(grep -E '^[[:space:]]*(export[[:space:]]+)?FORK_OWNER=' "$LOOP_DIR/config.env" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"'"'" | tr -d '[:space:]')"
  fi
  if [ -z "$OUR_AUTHOR" ]; then
    OUR_AUTHOR="$("$GH_BIN" api user --jq .login 2>/dev/null | head -1)"
  fi
  # A login and nothing else: the answer of a broken gh is not a login.
  case "$OUR_AUTHOR" in
    ''|*[!A-Za-z0-9-]*) OUR_AUTHOR="$OUR_AUTHOR_DEFAULT" ;;
  esac
}
# Always: the hold (who is assigned, who the bot says claimed it) has to
# know who WE are, with or without our pull request.
resolve_our_author

RULE_ARGS=(verify --issue "$ISSUE" --me "$OUR_AUTHOR" --repo "$REPO")
[ -n "$OUR_PR" ] && RULE_ARGS+=(--our-pr "$OUR_PR")

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/claim-verify.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

# The verdict of the rule, checked: an exit code without its VEREDICTO line
# (a python that died: an uncaught exception exits 1) is NOT a lost claim.
# close-slot.sh CLOSES our pull request on rc=1.
run_rule() {
  local out rc
  out="$(python3 "$RULE" "${RULE_ARGS[@]}" "$@")"
  rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" | grep -q '^VEREDICTO=OK' || rc=99 ;;
    1) printf '%s\n' "$out" | grep -qE '^VEREDICTO=(OCUPADO|PERDIDO)' || rc=99 ;;
  esac
  if [ "$rc" -eq 99 ]; then
    echo "VEREDICTO=ERROR la regla del claim no dio un veredicto (claim_rule.py)" >&2
    return 2
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return "$rc"
}

# --- 1. the photo, when it was given and it serves -----------------------------
if [ -n "$SNAPSHOT" ]; then
  run_rule --snapshot "$SNAPSHOT" --max-age-min "$MAX_AGE"
  RC=$?
  # 10: the photo does not serve (missing, old, incomplete, does not know the
  # issue): the rule said why on stderr, and the answer comes from GitHub.
  [ "$RC" -ne 10 ] && exit "$RC"
fi

# --- 2. live -------------------------------------------------------------------
# THE PREFILTER, NOT THE RULE: it keeps the open pull requests whose title or
# body contains "#N" (or "#0N": claim.js reads "#07058" as 7058) and gives
# them whole, one JSON per line; claim_rule.py decides. Every claim of either
# bot contains that text, so the prefilter never hides a claimant.
#
# The pattern has no backslash and no lookahead: the jq of gh is gojq (the
# regexp of Go). "#N" is the FIRST "#digits" of the program on purpose: the
# stubs of the tests read the issue from there.
PREFILTER=".[] | select(((.title // \"\") + \" \" + (.body // \"\")) | test(\"#${ISSUE}([^0-9]|\$)\") or test(\"#0+${ISSUE}([^0-9]|\$)\")) | {number, author: (.author.login // \"\"), title: (.title // \"\"), body: (.body // \"\")} | @json"

# gh pr list (and not gh api) because the listing of the api returns the body
# empty in some pull requests and the filter over the body finds nothing.
# Its exit code is the answer to "could the list be read": a jq that gh does
# not understand fails the call too, so a broken filter is never "free".
if ! "$GH_BIN" pr list --repo "$REPO" --state open --limit "$LIMIT" \
      --json number,title,body,author \
      --jq "$PREFILTER" >"$TMPD/prs" 2>"$TMPD/prs.err"; then
  echo "VEREDICTO=ERROR no se pudo leer los PRs de $REPO (gh fallo, o el filtro no se pudo aplicar?)" >&2
  exit 2
fi

# The hold of claim.js (somebody assigned, the 'in progress' label), only
# without our pull request: after our draft the bot labels the issue for US.
# An issue that cannot be read leaves the hold unchecked (the rule says so on
# stderr); it does not turn the PR verdict into UNKNOWN.
if [ -z "$OUR_PR" ]; then
  "$GH_BIN" issue view "$ISSUE" --repo "$REPO" --json number,labels,assignees,comments \
    >"$TMPD/issue" 2>/dev/null || : >"$TMPD/issue"
  run_rule --prs-lines "$TMPD/prs" --issue-json "$TMPD/issue"
else
  run_rule --prs-lines "$TMPD/prs"
fi
exit $?
