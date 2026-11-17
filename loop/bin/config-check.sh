#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# config-check.sh - the verifier of the config.env of the loop.
#
# WHY (01-11-2026): the config.env of the loop is SOURCED as bash by the
# scripts of bin/ (claim-guard.sh, claim-brake.sh, supervisor.sh, ...). A
# value with SPACES and no quotes breaks that source IN THE MIDDLE of the
# file:
#
#   CLAIM_EXCLUDED_LABELS=in progress,kernel-paused,status:decision
#
# bash reads that as the assignment CLAIM_EXCLUDED_LABELS=in followed by
# the command `progress,kernel-paused,status:decision`, which does not
# exist. The variable is never set (bash gives the assignment to the
# failed command, not to the shell), the rest of the file is not read and
# the script goes on with HALF of the policy, IN SILENCE: the scripts use
# `set -uo pipefail` WITHOUT -e, so a failed source does not stop them.
# The value of a broken source also depends on the state of the shell, so
# the failure is VARIABLE: the same file breaks a rule one run and not the
# next one.
#
# WHAT IT CHECKS:
#   1. the file is readable and has no syntax error (`bash -n`);
#   2. no value with spaces is UNQUOTED: the file is READ (never run) and
#      the line number and the name of the variable are reported;
#   3. the file is SOURCED in an isolated subshell and says nothing on
#      stderr: a runtime failure of the source is a broken config;
#   4. the variables that the loop cannot do without have a value:
#      CLAIM_EXCLUDED_LABELS, CLAIM_WANTED_LABEL (or CLAIM_WANTED_LABELS),
#      MAINT_THRESHOLD, UPSTREAM and FORK_OWNER.
#
# IT NEVER MODIFIES THE FILE: it only reads it.
#
# THE MODES:
#   (default)   the four checks above. The policy is judged: the file has
#               to be complete.
#   --static    only the checks that do NOT run the file (1 and 2) and that
#               do not judge the policy. It is what the pre-flight of the
#               scripts uses BEFORE they source the file: nothing is
#               sourced twice and nothing is executed twice.
#
# THE EXIT CODES:
#   0  everything is fine
#   1  there is a problem (the detail is printed)
#   2  wrong usage
#
#   bash bin/config-check.sh                     # the config.env of the loop
#   bash bin/config-check.sh --static FILE       # the pre-flight of the
#                                                 # scripts (no execution)
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
FILE=""
STATIC=0
QUIET=0

usage() {
  sed -n '2,/^# ---------------------------------------------------------------------------$/p' "$0" \
    | sed -n 's/^# \{0,1\}//p'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --static) STATIC=1; shift ;;
    --quiet)  QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "config-check: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)  if [ -n "$FILE" ]; then
          echo "config-check: only one file can be checked" >&2
          usage >&2
          exit 2
        fi
        FILE="$1"; shift ;;
  esac
done
[ $# -eq 0 ] || { echo "config-check: too many arguments" >&2; usage >&2; exit 2; }
[ -n "$FILE" ] || FILE="$LOOP_DIR/config.env"

# The variables the loop cannot do without. The scripts have a default for
# each of them, and THAT is the danger: a broken config.env is not a crash
# but a script that runs with a policy nobody chose.
MANDATORY_VARS="CLAIM_EXCLUDED_LABELS MAINT_THRESHOLD UPSTREAM FORK_OWNER"
# The label the funnel wants: one name or the other, never neither.
WANTED_VARS="CLAIM_WANTED_LABEL CLAIM_WANTED_LABELS"

PROBLEMS=0

problem() {
  PROBLEMS=$((PROBLEMS + 1))
  printf 'PROBLEM  %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# The scan of the lines: a value with spaces and no quotes is the bug.
#
# The value of an assignment is ONE word in bash. A space that is not
# inside quotes ends the word, and what follows is a COMMAND (or a
# comment, when it is a '#' that starts a word). The scan walks the value
# of every assignment with that rule in mind:
#   * inside ' or " the space is part of the value;
#   * inside ${...}, $(...) or `...` the space is part of the value;
#   * after a space, a '#' that starts a word is a comment: the value ends
#     there and the line is fine;
#   * after a space, anything else is a second word: the source breaks.
#
# SCAN_STATUS: 0 the value is one word (or empty), 1 the value has an
# unquoted space, 2 a quote is not closed.
# ---------------------------------------------------------------------------
scan_value() {
  local v="$1"
  local i=0
  local n=${#v}
  local c nx j
  local state=0
  # The stack of the CLOSERS of the nested groups: a `}` closes a ${...} and
  # a `)` closes a $(...). A stack (and not a counter) because the two can
  # be mixed: ${a:-$(b)} closes the inner one first.
  local stack=""
  # The characters that open and close a group. They are in variables
  # because a `)` inside a case pattern has to be escaped, and an escaped
  # one is easy to get wrong.
  local open_brace='{'
  local close_brace='}'
  local open_paren='('
  local close_paren=')'
  local dollar='$'
  local tick='`'
  # The TAB, in a variable: a `$(printf '\t')` would spawn a subshell for
  # EVERY character of the file.
  local tab=$(printf '\t')
  while [ "$i" -lt "$n" ]; do
    c="${v:i:1}"
    if [ -n "$stack" ]; then
      # inside ${...}, $(...) or `...`: the spaces are part of the value
      if [ "$c" = "\\" ]; then
        i=$((i + 1))
      elif [ "$c" = "$dollar" ]; then
        nx="${v:i+1:1}"
        if [ "$nx" = "$open_brace" ]; then
          stack="$close_brace$stack"
        elif [ "$nx" = "$open_paren" ]; then
          stack="$close_paren$stack"
        fi
        i=$((i + 1))
      elif [ "$c" = "$tick" ]; then
        stack="$tick$stack"
      elif [ "$c" = "$close_brace" ] || [ "$c" = "$close_paren" ] ||
           [ "$c" = "$tick" ]; then
        if [ "$c" = "${stack:0:1}" ]; then stack="${stack:1}"; fi
      fi
      i=$((i + 1))
      continue
    fi
    case "$state" in
      0) # plain text
        if [ "$c" = "'" ]; then
          state=1
        elif [ "$c" = '"' ]; then
          state=2
        elif [ "$c" = "\\" ]; then
          i=$((i + 1))
        elif [ "$c" = "$dollar" ]; then
          nx="${v:i+1:1}"
          if [ "$nx" = "$open_brace" ]; then
            stack="$close_brace$stack"
          elif [ "$nx" = "$open_paren" ]; then
            stack="$close_paren$stack"
          fi
          i=$((i + 1))
        elif [ "$c" = "$tick" ]; then
          stack="$tick$stack"
        elif [ "$c" = " " ] || [ "$c" = "$tab" ]; then
          # the word ends here: what follows must be a comment
          j=$i
          while [ "$j" -lt "$n" ]; do
            c="${v:j:1}"
            if [ "$c" = " " ] || [ "$c" = "$tab" ]; then
              j=$((j + 1))
            elif [ "$c" = "#" ]; then
              return 0
            else
              break
            fi
          done
          [ "$j" -ge "$n" ] && return 0
          return 1
        fi
        ;;
      1) # inside '...'
        [ "$c" = "'" ] && state=0
        ;;
      2) # inside "..."
        if [ "$c" = '"' ]; then
          state=0
        elif [ "$c" = "\\" ]; then
          i=$((i + 1))
        fi
        ;;
    esac
    i=$((i + 1))
  done
  [ "$state" -eq 0 ] || return 2
  return 0
}

# The scan of the file: the assignments whose value is broken.
# SCAN_LINES: the lines of the problem (empty when there is none).
SCAN_LINES=""
scan_file() {
  local file="$1" lineno=0 line name value status buf=""
  SCAN_LINES=""
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # a line that ends with a backslash continues in the next one
    if [ "${line%\\}" != "$line" ]; then
      buf="${buf}${line%\\}"
      continue
    fi
    line="${buf}${line}"
    buf=""
    # the name of the variable and its value
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      name="${BASH_REMATCH[2]}"
      value="${BASH_REMATCH[3]}"
      scan_value "$value"
      status=$?
      case "$status" in
        1) SCAN_LINES="${SCAN_LINES}${lineno}: ${name}: the value has spaces and is not quoted${NL:-$'\n'}" ;;
        2) SCAN_LINES="${SCAN_LINES}${lineno}: ${name}: a quote of the value is not closed${NL:-$'\n'}" ;;
      esac
    fi
  done < "$file"
  return 0
}

NL=$'\n'

# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------

if [ ! -e "$FILE" ]; then
  printf 'config-check: there is no file to check: %s\n' "$FILE"
  exit 1
fi
if [ ! -r "$FILE" ]; then
  printf 'config-check: the file cannot be read: %s\n' "$FILE"
  exit 1
fi

# 1. the syntax of the file
syntax_out="$(bash -n "$FILE" 2>&1)"
if [ $? -ne 0 ]; then
  problem "the file has a syntax error: $FILE"
  printf '%s\n' "$syntax_out" | sed 's/^/         /'
fi

# 2. the values with spaces and no quotes
scan_file "$FILE"
if [ -n "$SCAN_LINES" ]; then
  problem "the file has values with spaces that are not quoted: $FILE"
  printf '%s' "$SCAN_LINES" | sed 's/^/         /' >&2
fi

# 3. the source in an isolated subshell (only in the full mode: the static
#    mode never runs the file)
if [ "$STATIC" -eq 0 ]; then
  err_file="$(mktemp "${TMPDIR:-/tmp}/config-check.XXXXXX")" || {
    echo "config-check: a temporary file cannot be created" >&2
    exit 2
  }
  # `set -u` mirrors the scripts that source the file
  bash -u -c '. "$1"' _ "$FILE" >/dev/null 2>"$err_file"
  src_rc=$?
  if [ -s "$err_file" ] || [ "$src_rc" -ne 0 ]; then
    problem "the file does not source cleanly (rc=$src_rc): $FILE"
    sed 's/^/         /' "$err_file" >&2
  fi
  rm -f "$err_file"

  # 4. the variables the loop cannot do without
  missing="$(bash -u -c '
    . "$1" || exit 0
    for v in $2; do
      eval "value=\${$v-}"
      [ -n "$value" ] || printf "%s\n" "$v"
    done
    eval "wanted=\${$3-}"
    eval "wanted2=\${$4-}"
    [ -n "$wanted" ] || [ -n "$wanted2" ] || printf "%s|%s\n" "$3" "$4"
  ' _ "$FILE" "$MANDATORY_VARS" "${WANTED_VARS%% *}" "${WANTED_VARS#* }" 2>/dev/null)"
  if [ -n "$missing" ]; then
    while IFS= read -r m; do
      case "$m" in
        *"|"*) problem "the variable is empty (one of the two is enough): ${m}" ;;
        *) problem "the variable is empty (the loop cannot do without it): $m" ;;
      esac
    done <<EOF
$missing
EOF
  fi
fi

if [ "$PROBLEMS" -gt 0 ]; then
  printf 'config-check: %s problem(s) in %s\n' "$PROBLEMS" "$FILE" >&2
  exit 1
fi
[ "$QUIET" -eq 1 ] || printf 'config-check: OK %s\n' "$FILE"
exit 0
