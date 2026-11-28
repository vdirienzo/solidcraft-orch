#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Checks that a pull request body carries the line `Changes a default:`.
#
# WHY: the upstream (pr-checks.yml) fails a pull request without that line.
# This script does NOT write it: it only CHECKS and reports, so whoever
# publishes the pull request writes the line (the agent rewrites the body
# later, following prompts/publish.md, and turns it into "yes - <what>" when
# the change really alters a default).
#
# TWO MODES:
#   bash bin/pr-defaults-line.sh --body <file>
#       the body of a FILE, OFFLINE: no GitHub, no network, no configuration.
#       It is the pre-flight of the publication: the body that is going to be
#       published is checked BEFORE it leaves the machine.
#   bash bin/pr-defaults-line.sh [--repo owner/name] [12 34]
#       the bodies of the open pull requests of ours (of the whole set when no
#       number is given).
#
# OUTPUT (stdout):
#   missing: <pr|file>   one line per body without the line
#   checked: <n> missing: <m>
#
# EXIT CODES:
#   0  every checked body has the line
#   1  at least one is missing it
#   2  bad usage (or a body that cannot be read)
#   6  GitHub could not be read: the check did NOT happen, and the caller
#      must read 6 as "unknown", never as "the line is missing"
#
# It only reads and reports: it never writes to a pull request and never
# closes anything.
# ---------------------------------------------------------------------------
set -uo pipefail

# The directory of this script: the checker of the configuration
# (bin/config-preflight.sh) lives next to it and it is called by path,
# never by a guess.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# The paths of THIS machine (bin/paths.sh, 2026-11-24): the repo versions the
# LOOP half, so the house's resolver is two levels up. It is sourced only when
# the variable is unset, and the literal below stays as the fallback for a
# machine without that file.
if [ -z "${SOLIDCRAFT_REPO:-}" ] && [ -f "$SCRIPT_DIR/../../bin/paths.sh" ]; then
  # shellcheck disable=SC1090
  . "$SCRIPT_DIR/../../bin/paths.sh"
fi

# --- the parser of the upstream -------------------------------------------
# WHY THIS IS NOT A GREP (28-10-2026, fixed 30-10-2026): the local script
# only asked "is there a line that starts with 'Changes a default:'". The
# upstream check (scripts/pr-checks/pr-checks.js) asks much more: the value
# has to be 'no' or a well formed 'yes - <what>, old behaviour kept behind
# preference <name>'. A body with 'Changes a default: totally wrong' passed
# the local gate and the remote CI rejected it: the local gate was MORE
# PERMISSIVE than the authority, which is exactly backwards. It cost a whole
# PR (the body of #7368 had to be rewritten and the branch re-pushed).
#
# The parser of the upstream is a PURE function with no dependencies and it
# is exported: the local gate CALLS it instead of re-implementing it. A
# local re-implementation of a rule of the repo is a rule that drifts.
#
# The script is read from the checkout when it is there and it is copied to a
# temporary file when the body is checked with --body: the offline mode
# must not need a network, a token or a configuration, and it must work from
# any directory.
PR_CHECKS_JS="${PR_CHECKS_JS:-}"
if [ -z "$PR_CHECKS_JS" ]; then
  for _cand in \
    "${REPO_ROOT:-}/scripts/pr-checks/pr-checks.js" \
    "${SOLIDCRAFT_REPO:-}/scripts/pr-checks/pr-checks.js" \
    "${REPO_ROOT:-$HOME/Projects/solidcraft-orch}/scripts/pr-checks/pr-checks.js" \
    "${SOLIDCRAFT_REPO:-${REPO_ROOT:-/home/user/solidcraft}}/scripts/pr-checks/pr-checks.js"; do
    if [ -n "$_cand" ] && [ -f "$_cand" ]; then PR_CHECKS_JS="$_cand"; break; fi
  done
fi

# The check of ONE body. It sets DEFAULTS_STATUS ('no', 'yes', 'malformed'
# or 'missing') and DEFAULTS_DETAIL (the offending text, when it is
# malformed). It returns 0 when the body passes the upstream rule.
#
# The status travels in a VARIABLE and not in the output: the output of the
# script is a contract ('missing: <pr>' lines and a 'checked: N missing: M'
# summary) and a detail glued to the status with a tab would break every
# reader of it.
DEFAULTS_STATUS=""
DEFAULTS_DETAIL=""
defaults_status() {
  local body="$1" js="$2" tmp
  DEFAULTS_STATUS=""
  DEFAULTS_DETAIL=""
  if [ -z "$js" ] || [ ! -f "$js" ]; then
    echo "pr-defaults-line: the parser of the upstream is not there: $js" >&2
    return 6
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "pr-defaults-line: node is not in the PATH: the body cannot be checked" >&2
    return 6
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/pr-defaults-body.XXXXXX")" || return 6
  printf '%s' "$body" > "$tmp"
  # The upstream file is a module of a GitHub Action: it exports the pure
  # functions, and requiring it does NOT run the action.
  local out
  out="$(node -e '
    const fs = require("fs");
    const p = require(process.argv[1]);
    const body = fs.readFileSync(process.argv[2], "utf8");
    const r = p.parseDefaults(body);
    process.stdout.write(r.status);
    if (r.status === "malformed") process.stdout.write("\t" + (r.detail || ""));
  ' "$js" "$tmp" 2>/dev/null)"
  local rc=$?
  rm -f "$tmp" 2>/dev/null
  [ "$rc" -eq 0 ] || return 6
  DEFAULTS_STATUS="${out%%$'\t'*}"
  if [ "$out" != "$DEFAULTS_STATUS" ]; then
    DEFAULTS_DETAIL="${out#*$'\t'}"
  fi
  return 0
}

# The explanation of a malformed line. It goes to STDERR: the stdout of this
# script is a contract and a reader of it must not see prose.
#
# THE FORMS (2026-11-28): the upstream's parser accepts more than two, and the
# help that names only the two old ones sends the author away from a body the
# upstream accepts. The truth is scripts/pr-checks/pr-checks.js.
explain_malformed() {
  printf 'pr-defaults-line: the "Changes a default:" line is malformed: %s\n' "${1:-}" >&2
  printf 'pr-defaults-line: it has to be one of:\n' >&2
  printf 'pr-defaults-line:   Changes a default: no\n' >&2
  printf 'pr-defaults-line:   Changes a default: no. Only a fix.   (a note after it is fine)\n' >&2
  printf 'pr-defaults-line:   Changes a default: yes - <what>, old behaviour kept behind preference <name>\n' >&2
  printf 'pr-defaults-line:   Changes a default: yes - <what>, approved by the owner  (needs the owner-approved label)\n' >&2
  printf 'pr-defaults-line:   ## Changes a default   (the value on the first line under it)\n' >&2
}

# node is NOT in the PATH of a login shell on this box: the toolchain lives
# in ~/.hermes/tools/node-<version>/bin. The script has to FIND it instead of
# demanding that the caller exports it, because the callers are a cron, a
# test harness and a shell: none of them knows about the toolchain.
# The REAL home of the user is consulted too, because a harness that runs
# with a temporary HOME (the tests do) would otherwise hide the toolchain.
if ! command -v node >/dev/null 2>&1; then
  REAL_HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
  for _node in "$HOME"/.hermes/tools/node-*/bin/node \
               ${REAL_HOME:+"$REAL_HOME"/.hermes/tools/node-*/bin/node} \
               /usr/local/bin/node /usr/bin/node /snap/bin/node; do
    if [ -x "$_node" ]; then
      export PATH="$(dirname "$_node"):$PATH"
      break
    fi
  done
fi

# --- the offline mode: the body of a file, without GitHub ------------------
# The pre-flight of the publication reads a FILE. It must not need a
# configuration, a network or a token, so this mode is dispatched BEFORE
# anything else is read: the first thing this script does is look at $1.
if [ "${1:-}" = "--body" ]; then
  BODY_PATH="${2:-}"
  if [ -z "$BODY_PATH" ] || [ ! -f "$BODY_PATH" ]; then
    echo "pr-defaults-line: --body needs a file that exists" >&2
    exit 2
  fi
  BODY="$(cat -- "$BODY_PATH" 2>/dev/null)" || {
    echo "pr-defaults-line: the body $BODY_PATH could not be read" >&2
    exit 2
  }
  defaults_status "$BODY" "$PR_CHECKS_JS" || exit 6
  case "$DEFAULTS_STATUS" in
    no|yes)
      printf 'checked: 1 missing: 0\n'
      exit 0
      ;;
    malformed)
      explain_malformed "$DEFAULTS_DETAIL"
      printf 'missing: %s\n' "$BODY_PATH"
      printf 'checked: 1 missing: 1\n'
      exit 1
      ;;
    *)
      printf 'missing: %s\n' "$BODY_PATH"
      printf 'checked: 1 missing: 1\n'
      exit 1
      ;;
  esac
fi

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/.opencode/bin:$PATH"


# The configuration is CHECKED before it is sourced: a value with spaces
# and no quotes breaks the source in the middle of the file, so the
# variable is never set and the script goes on with HALF of the policy, in
# silence (set -e is not on). The check only READS the file: the config.env
# is read twice and sourced once. If the config.env is broken, the script
# STOPS here instead of running with half of the policy.
if [ -r "$LOOP_DIR/config.env" ]; then
  if [ -x "$SCRIPT_DIR/config-preflight.sh" ]; then
    bash "$SCRIPT_DIR/config-preflight.sh" "$LOOP_DIR/config.env" || exit 2
  elif ! bash -n "$LOOP_DIR/config.env" >/dev/null 2>&1; then
    echo "pr-defaults-line: the config.env has a syntax error: $LOOP_DIR/config.env" >&2
    exit 2
  fi
fi

# config.env is the source of truth for the paths, the model and the fork.
if [ -f "$LOOP_DIR/config.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$LOOP_DIR/config.env"
  set +a
fi

UPSTREAM="${UPSTREAM:-}"
# The author of our pull requests: FORK_OWNER in config.env; if it is not
# there, it is derived from the URL of the fork.
FORK_OWNER="${FORK_OWNER:-}"
if [ -z "$FORK_OWNER" ] && [ -n "${FORK:-}" ]; then
  FORK_OWNER="$(echo "$FORK" | sed -E 's#.*github.com[:/]([^/]+)/.*#\1#')"
fi

# --- the options ------------------------------------------------------------
REPO="$UPSTREAM"
PRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || { echo "pr-defaults-line: --repo needs owner/name" >&2; exit 2; }
      REPO="$2"; shift 2 ;;
    '')
      echo "pr-defaults-line: bad usage" >&2
      exit 2 ;;
    *[!0-9]*)
      echo "pr-defaults-line: not a pull request number: $1" >&2
      exit 2 ;;
    *)
      PRS+=("$1"); shift ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$FORK_OWNER" ]; then
  echo "pr-defaults-line: FORK_OWNER and a repository are needed (config.env or --repo)" >&2
  exit 2
fi

command -v gh >/dev/null || {
  echo "pr-defaults-line: gh is not in the PATH: GitHub cannot be read" >&2
  exit 6
}

# --- which pull requests to check -----------------------------------------
if [ ${#PRS[@]} -eq 0 ]; then
  if ! LIST="$(gh pr list -R "$REPO" --author "$FORK_OWNER" --state open \
      --json number --jq '.[].number' 2>/dev/null)"; then
    echo "pr-defaults-line: could not read the pull requests of $REPO" >&2
    exit 6
  fi
  for n in $LIST; do
    PRS+=("$n")
  done
fi

# --- the check -------------------------------------------------------------
CHECKED=0
MISSING=0
for pr in "${PRS[@]}"; do
  if ! BODY="$(gh pr view "$pr" -R "$REPO" --json body --jq .body 2>/dev/null)"; then
    echo "pr-defaults-line: could not read the body of the pull request #$pr" >&2
    exit 6
  fi
  CHECKED=$(( CHECKED + 1 ))
  # The SAME parser of the upstream that the offline mode uses (see the
  # note at the top of the file): the local gate can never be more
  # permissive than the authority it stands in for.
  defaults_status "$BODY" "$PR_CHECKS_JS" || exit 6
  case "$DEFAULTS_STATUS" in
    no|yes) : ;;
    malformed)
      explain_malformed "$DEFAULTS_DETAIL"
      printf 'missing: %s\n' "$pr"
      MISSING=$(( MISSING + 1 ))
      ;;
    *)
      printf 'missing: %s\n' "$pr"
      MISSING=$(( MISSING + 1 ))
      ;;
  esac
done

printf 'checked: %d missing: %d\n' "$CHECKED" "$MISSING"
[ "$MISSING" -eq 0 ] || exit 1
exit 0
