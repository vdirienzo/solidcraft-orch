#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# config-preflight.sh - the PRE-FLIGHT of the scripts that source config.env.
#
# WHY (01-11-2026): the config.env of the loop is SOURCED as bash. A value
# with SPACES and no quotes breaks that source IN THE MIDDLE of the file:
#
#   CLAIM_EXCLUDED_LABELS=in progress,kernel-paused,status:decision
#
# bash reads it as the assignment CLAIM_EXCLUDED_LABELS=in followed by the
# command `progress,kernel-paused,status:decision`, which does not exist.
# The variable is never set (bash hands the assignment to the failed
# command, not to the shell), the rest of the file is not read and the
# script goes on with HALF of the policy, IN SILENCE: the scripts use
# `set -uo pipefail` WITHOUT -e, so the failed source does not stop them.
# The rule that breaks depends on the state of the shell, so the same file
# breaks the suite one run and not the next one.
#
# WHAT IT DOES: it CHECKS the config.env BEFORE the script sources it, and
# it STOPS the script when the file is broken. The script then does not
# run with half a policy: it stops with a message that says what to fix.
#
# IT IS CHEAP AND IT SOURCES NOTHING: the check reads the file (it never
# runs it), so the config.env is read twice and sourced once.
#
# THE EXIT CODES:
#   0  the config.env is fine
#   1  the config.env is broken (the detail is on stderr)
#   2  the usage is wrong (no file to check)
# ---------------------------------------------------------------------------
set -uo pipefail

FILE="${1:-}"

if [ -z "$FILE" ]; then
  echo "config-preflight: the usage is: config-preflight.sh <config.env>" >&2
  exit 2
fi
if [ ! -r "$FILE" ]; then
  echo "config-preflight: the file cannot be read: $FILE" >&2
  exit 2
fi

# The checker of the config: it lives next to this script (bin/), so the
# pre-flight is called by path and never by a guess.
CHECKER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config-check.sh"

if [ ! -x "$CHECKER" ]; then
  # Without the checker there is nothing to do: the file is checked by the
  # cheap way (the syntax) and the script goes on.
  bash -n "$FILE" >/dev/null 2>&1 || {
    echo "config-preflight: the config.env has a syntax error: $FILE" >&2
    exit 1
  }
  exit 0
fi

# --static: the checks that do NOT run the file (the syntax and the values
# with spaces and no quotes). The static mode is the pre-flight: it must
# not execute a file that is about to be executed.
"$CHECKER" --static --quiet "$FILE"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "config-preflight: the config.env is broken: $FILE" >&2
  echo "config-preflight: the script STOPS here (it would run with half of the policy)" >&2
  echo "config-preflight: run bin/config-check.sh $FILE for the detail" >&2
  exit 1
fi
exit 0
