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
# THE RULE OF THE CLAIM is the UNION of the two rules of the upstream, which
# do not agree with each other (and the bot of the upstream applies both):
#
#   * the TITLE of the pull request names the issue ("... (#361)")
#     (upstream scripts/claim/claim.js, referencedIssues), OR
#   * the BODY of the pull request has a closing verb followed by the issue
#     (upstream scripts/claim/claim.js and scripts/pr-checks/pr-checks.js,
#     parseClosing). The '#' is REQUIRED there: it is what tells an issue
#     reference from prose with a number ("This fix 3 problems." is NOT a
#     claim). A LIST counts every issue of it ("Fixes #10181, #10182").
#
# The old rule of this file (a closing verb over title+body) was BLIND to 193
# rival pull requests that name the issue in the TITLE (measured over the
# 836 open pull requests of 2026-11-17, reports/loop-codigo.md, B6): the
# PR #1608 "Correct mouse and trackpad navigation presets (#361)" held #361
# and the guard said the issue was free.
#
# THE RULE OF THE SAME AUTHOR: our own pull requests do NOT compete with us
# (upstream scripts/claim/claim.js: a pull request does not lose against an
# older pull request of the same author). Without it, two of our pull
# requests open on the same issue made the higher-numbered one LOSE, and the
# orchestrator CLOSED it: real work thrown away.
#
# Usage:
#   bash bin/claim-verify.sh <issue> [our_pr]
#   bash bin/claim-verify.sh <issue> --our-pr <our_pr>
#
# Exit codes (the contract with bin/gate.sh and bin/publish-pr.sh):
#   0  -> the claim is OURS: no pull request of ANOTHER author with a lower
#         number claims the issue
#   1  -> the claim is LOST: another pull request with a lower number has it
#   2  -> usage error, or it could not be verified (UNKNOWN, never "no")
#
# If it is lost, the caller has to:
#   gh pr close <our_pr>            (close ours)
#   bash bin/slot-lock.sh --slot N --release
set -uo pipefail

usage() {
  echo "uso: bash bin/claim-verify.sh <issue> [nuestro_pr|--our-pr <nuestro_pr>]" >&2
}

ISSUE=""
OUR_PR=""
ISSUE_SET=0
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

# --- the filter of the claim -------------------------------------------------
# The filter is a jq program in a file of its own: the jq of one line does
# not survive the escapes of the pattern, and the pattern has to be the
# upstream's own.
#
# The title rule is the one of scripts/claim/claim.js (referencedIssues):
# '#N' at the start of the title or after a space or a parenthesis.
# The body rule is the one of scripts/pr-checks/pr-checks.js (parseClosing):
# a closing verb, an optional colon, and then a LIST of issue references.
# The '#' is mandatory in the body.
#
# THREE THINGS THE FIRST VERSION OF THIS FILTER GOT WRONG (2026-11-17), and
# all three made the arbiter say TAKEN for an issue that is free - which
# costs a whole slot of the machine:
#   1. the NOISE was not stripped. Upstream strips the HTML comments and
#      the code blocks before it parses (stripNoise, pr-checks.js:25-31), so
#      a body with "Fixes #361" INSIDE A CODE BLOCK is free. Ours counted it.
#   2. a reference to ANOTHER REPOSITORY was counted. Upstream skips
#      "owner/repo#N" when the repo is not ours (parseClosing, the line
#      `if (ref[1] && repoFullName && ref[1].toLowerCase() !== ...) continue`).
#   3. the pull request's OWN number was counted. Upstream skips it
#      (claim.js:297, `if (n === pull.number) continue`).
#
# The patterns have NO backslash and NO lookahead on purpose: the jq of gh
# is gojq (the regexp of Go), where a lookahead does not exist. The rule of
# the upstream is written as ONE pattern: the verb, then the items of the
# list that come BEFORE the issue, then the issue. That is the rule of the
# upstream (the list of parseClosing) and it counts every issue of the list
# ("Fixes #10181, #10182" claims the two).
TITLE_RE="(^|[[:space:](])#${ISSUE}([^0-9A-Za-z_]|\$)"
BODY_RE="(?i)(?:^|[^0-9A-Za-z_])(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]*(?:(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+[[:space:]]*(?:,|and|&)[[:space:]]*)*(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#${ISSUE}([^0-9A-Za-z_]|\$)"
# The repository of a reference: "owner/repo#N" only counts when it is ours.
REPO_OWNER="${REPO%%/*}"
REPO_NAME="${REPO#*/}"
CLAIM_JQ="$(mktemp)"
trap 'rm -f "$CLAIM_JQ"' EXIT
cat >"$CLAIM_JQ" <<JQ
# The noise of upstream's stripNoise (pr-checks.js:25-31): the HTML comments
# and the code blocks are examples, not claims. The inline code is NOT
# stripped: upstream's parseClosing keeps it.
def sin_ruido:
  gsub("<!--[^>]*-->"; "")
  | gsub("\`\`\`[^<\`]*\`\`\`"; "")
  | gsub("~~~[^<~]*~~~"; "");

# A reference to ANOTHER repository is not a claim on ours (upstream skips
# it in parseClosing). Ours counts, so it becomes the plain form; any other
# repo-qualified reference to the issue is removed.
def sin_otros_repos:
  gsub("(?i)${REPO_OWNER}/${REPO_NAME}#${ISSUE}"; "#${ISSUE}")
  | gsub("(?i)[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#${ISSUE}"; "");

.[] | select(
    # the title: the rule of the claim bot (referencedIssues)
    ((.title // "") | test("${TITLE_RE}"))
    or
    # the body: the rule of the pull request check (parseClosing), with the
    # noise out and the references to other repositories out
    (((.body // "") | sin_ruido | sin_otros_repos) | test("${BODY_RE}"))
  )
  # a pull request does not claim ITSELF (claim.js:297: "if (n === pull.number)
  # continue"): the PR whose number IS the issue we are asking about is not a
  # holder of it. It is NOT about excluding OUR pull request from the hits:
  # that is the rule of the same author, which is decided further down.
  | select((.number | tostring) != "${ISSUE}")
  | "\(.number)\t\(.author.login // "")"
JQ

# gh pr list (and not gh api) because the listing of the api returns the body
# empty in some pull requests and the filter over the body finds nothing.
# The author comes with it: the rule of the same author needs to know WHO
# wrote each pull request.
HITS="$("$GH_BIN" pr list --repo "$REPO" --state open --limit "$LIMIT" \
        --json number,title,body,author \
        --jq "$(cat "$CLAIM_JQ")" 2>/dev/null)"

# The hits, one per line: "number<TAB>author" (the author is empty when the
# tool did not say it).
HIT_NUMBERS=()
HIT_AUTHORS=()
while IFS=$'\t' read -r num author; do
  num="${num//[!0-9]/}"
  [ -n "$num" ] || continue
  author="${author//[[:space:]]/}"
  HIT_NUMBERS+=("$num")
  HIT_AUTHORS+=("$author")
done <<<"$HITS"

if [ "${#HIT_NUMBERS[@]}" -eq 0 ]; then
  # Distinguish "there is none" from "gh failed": check that the list of
  # pull requests could be read.
  #
  # THE PROBE USES THE SAME FILTER (2026-11-17). The probe used to ask for
  # the numbers WITHOUT the filter: if the FILTER was what failed (a jq
  # that does not understand the program, a pattern that does not compile),
  # the probe answered "the list can be read", the hits were empty, and the
  # arbiter said THE ISSUE IS FREE. That is the most expensive direction
  # there is: the orchestrator takes an issue that somebody else holds.
  if [ -n "${HITS//[[:space:]]/}" ] || ! "$GH_BIN" pr list --repo "$REPO" --state open --limit 1 \
        --json number,title,body,author --jq "$(cat "$CLAIM_JQ")" >/dev/null 2>&1; then
    echo "VEREDICTO=ERROR no se pudo leer los PRs de $REPO (gh fallo, o el filtro no se pudo aplicar?)" >&2
    exit 2
  fi
  echo "issue=$ISSUE PRs que lo mencionan: (ninguno)"
  if [ -n "$OUR_PR" ]; then
    echo "VEREDICTO=OK el claim es nuestro (PR #$OUR_PR, nadie mas lo menciona)"
  else
    echo "VEREDICTO=OK el issue esta libre (nadie lo menciona)"
  fi
  exit 0
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

# Is this pull request OURS?
is_ours() {
  local author="$1"
  [ -n "$author" ] || return 1
  [ -n "$OUR_AUTHOR" ] || return 1
  [ "${author,,}" = "${OUR_AUTHOR,,}" ]
}

# --- the winner --------------------------------------------------------------
# The pull request with the lowest number that COMPETES.
#
# Our own pull requests do NOT compete with us (the upstream skips the pull
# requests of the same author): the work stacked does not compete with
# itself. The one that is being verified always competes. Without our pull
# request there is no way to tell ours from the others, so every pull
# request that claims the issue blocks it.
OUR_HOLDER=""
WINNER=""
WINNER_AUTHOR=""
if [ -n "$OUR_PR" ]; then
  resolve_our_author
fi
for i in "${!HIT_NUMBERS[@]}"; do
  num="${HIT_NUMBERS[$i]}"
  author="${HIT_AUTHORS[$i]}"
  if [ -n "$OUR_PR" ] && [ "$num" != "$OUR_PR" ] && is_ours "$author"; then
    if [ -z "$OUR_HOLDER" ] || [ "$num" -lt "$OUR_HOLDER" ]; then
      OUR_HOLDER="$num"
    fi
    continue
  fi
  if [ -z "$WINNER" ] || [ "$num" -lt "$WINNER" ]; then
    WINNER="$num"
    WINNER_AUTHOR="$author"
  fi
done

echo "issue=$ISSUE PRs que lo mencionan: $(printf '%s\n' "${HIT_NUMBERS[@]}" | tr '\n' ' ')(gana el ${WINNER:-$OUR_HOLDER})"
if [ -n "$OUR_HOLDER" ]; then
  echo "issue=$ISSUE PRs nuestros (no compiten con nosotros): $OUR_HOLDER"
fi

if [ -n "$OUR_PR" ]; then
  if [ -z "$WINNER" ]; then
    # Nobody of another author claims the issue: the claim is OURS (another
    # of our pull requests holds it).
    echo "issue=$ISSUE el claim lo tiene nuestro PR #$OUR_HOLDER: no se pierde"
    echo "VEREDICTO=OK el claim es nuestro (PR #$OUR_PR)"
    exit 0
  fi
  if [ "$WINNER" = "$OUR_PR" ]; then
    echo "VEREDICTO=OK el claim es nuestro (PR #$OUR_PR)"
    exit 0
  fi
  echo "VEREDICTO=PERDIDO el PR #$OUR_PR perdio contra el #$WINNER"
  if [ -n "$WINNER_AUTHOR" ]; then
    echo "  el PR #$WINNER es de $WINNER_AUTHOR"
  fi
  echo "  cerralo con: gh pr close $OUR_PR"
  echo "  libera el slot con: bash bin/slot-lock.sh --slot $ISSUE --release"
  exit 1
fi

# Without our pull request: only says who won.
if [ -n "$WINNER" ] && [ "$WINNER" -le 0 ]; then
  echo "VEREDICTO=OK el issue esta libre (nadie lo menciona)"
  exit 0
fi
echo "VEREDICTO=OCUPADO el PR #$WINNER ya reclama #$ISSUE"
exit 1
