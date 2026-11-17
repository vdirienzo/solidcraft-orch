#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pr-comment.sh - leaves the pull requests of ours with a comment that tells
# the truth about the CI of their head.
#
#   bash bin/pr-comment.sh <pr> [<pr> ...]
#
# WHY: the loop asked for the approval of the fork workflows when the checks
# of a pull request sat in `action_required`. That state is gone: the checks
# have run and the `ci` context is green. A comment that still says "the CI
# has not run yet, a maintainer has to click Approve workflows to run" makes
# a pull request look stuck when it is not, so the stale comment is EDITED
# (not added next to it) with what is true now.
#
# WHAT IT SAYS:
#   - the head sha and the state of its `ci` context (read from the API),
#   - the verdict of the LOCAL complete gate on that same head, when there is
#     one (read from the gate log, whose name carries the sha),
#   - or, when only the SCOPED gate ran on that head, what the scoped gate
#     covered (the packages of the scope and their reverse dependencies) and
#     that the whole workspace was NOT run,
#   - that the change is ready for review and for the merge queue.
#
# It never says that a maintainer has to do anything that is not true, and it
# never asks for a review: the merge is the maintainer's, and the ruleset
# does not ask for one.
#
# The exit code is 0 when every pull request ended with a comment, and 1 when
# one of them could not be read.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
UPSTREAM="${UPSTREAM:-tangency-labs/solidcraft}"
LOG_DIR="$LOOP_DIR/logs"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <pr> [<pr> ...]" >&2
  exit 2
fi

say() { echo "[$(date -Is)] $*" >&2; }

# --- the head and the checks of a pull request ------------------------------
pr_head() {
  local sha
  sha="$(gh api "repos/$UPSTREAM/pulls/$1" --jq '.head.sha' 2>/dev/null)"
  case "${sha:-}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) printf '%s' "$sha" ;;
    *) printf '' ;;
  esac
}

# The `ci` context of a sha: the LAST run of it is the one that counts.
ci_state() {
  gh api "repos/$UPSTREAM/commits/$1/check-runs" --jq \
    '[.check_runs[]|select(.name=="ci")|(.status+"/"+(.conclusion//"-"))]|join(", ")' \
    2>/dev/null
}

# The check names of a sha, with their conclusion, for the comment. The ones
# that were SKIPPED are left out: the list would be a wall of "skipped" and
# the reader would not know which ones actually ran.
ci_jobs() {
  gh api "repos/$UPSTREAM/commits/$1/check-runs" --jq \
    '[.check_runs[]|select(.status=="completed" and .conclusion!="skipped")|"\(.name): \(.conclusion)"]|join(", ")' \
    2>/dev/null
}

# The heavy lane of the CI waits for the `approved-for-ci` label, which only a
# maintainer can add. Saying so is better than leaving a silent gap: the
# reader sees why the job is not there.
ci_heavy_skipped() {
  gh api "repos/$UPSTREAM/commits/$1/check-runs" --jq \
    '[.check_runs[]|select(.conclusion=="skipped" and (.name|test("Native Linux tests")))]|length' \
    2>/dev/null
}

# --- the local gate of a sha -------------------------------------------------
# The name of the log of a gate carries the sha of the tree it compiled, so
# the log of a head is found without guessing the slug.
gate_log_of_sha() {
  local sha="$1" file
  for file in "$LOG_DIR"/gate-*${sha:0:12}*.log; do
    [ -f "$file" ] || continue
    # The last log that finished is the one that counts.
    if grep -qE '^EXIT=[0-9]+[[:space:]]*$' "$file" 2>/dev/null; then
      printf '%s' "$file"
      return 0
    fi
  done
  for file in "$LOG_DIR"/gate-*${sha:0:12}*.log; do
    [ -f "$file" ] && { printf '%s' "$file"; return 0; }
  done
  return 1
}

gate_verdict_of() {
  bash "$LOOP_DIR/bin/gate-check.sh" "$1" 2>/dev/null | tr '\n' ' '
}

# The verdict of the output of gate-check.sh (the output is flat: the lines
# joined with spaces). It is VERDE, ROJO or PENDIENTE.
gate_verdict_of_text() {
  local text="$1" rest
  rest="${text#*VERDICT=}"
  [ "$rest" = "$text" ] && return 1
  printf '%s' "${rest%% *}"
}

# --- the scoped gate of a sha ------------------------------------------------
# The scoped gate writes its verdict in the slot that owns it:
# gates/<slot>/scope.verdict. The slot of a pull request is not known here, so
# every slot is searched and only the one whose SHA is the head of THIS pull
# request counts: a verdict of another commit says nothing about this head.
scope_field() {
  # scope_field <file> <key>
  local file="$1" key="$2" line
  line="$(grep -m1 "^${key}=" "$file" 2>/dev/null)" || return 1
  printf '%s' "${line#*=}"
}

# The checks of a scoped run, joined: one line per check, whatever separator
# the writer used (a comma or a pipe).
scope_checks() {
  local file="$1" line out=""
  while IFS= read -r line; do
    out="${out:+$out,}${line#CHECKS=}"
  done < <(grep -h '^CHECKS=' "$file" 2>/dev/null)
  printf '%s' "$out"
}

scope_verdict_of_sha() {
  local sha="$1" file
  for file in "$LOOP_DIR"/gates/*/scope.verdict; do
    [ -f "$file" ] || continue
    [ "$(scope_field "$file" SHA)" = "$sha" ] || continue
    printf '%s' "$file"
    return 0
  done
  return 1
}

# The scoped gate is green when its verdict is VERDE-SCOPE, the scope is a set
# of packages (not the whole workspace) and its three checks are green.
scope_is_green() {
  local file="$1" checks one
  [ "$(scope_field "$file" VERDICT)" = "VERDE-SCOPE" ] || return 1
  [ "$(scope_field "$file" SCOPE_KIND)" = "packages" ] || return 1
  checks="$(scope_checks "$file")"
  for one in fmt layers clippy; do
    case ",${checks//|/,}," in
      *",$one:ok,"*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# --- the comment -------------------------------------------------------------
build_body() {
  local pr="$1" sha="$2" ci="$3" jobs="$4" gate_log="$5" gate="$6" heavy="$7"
  local kind="${8:-new}" scope="${9:-}" packages="${10:-}"
  {
    if [ "$kind" = "stale" ]; then
      echo "The CI of this pull request no longer waits for the approval of"
      echo "the fork workflows: the checks of the current head \`$sha\` have"
      echo "run and the \`ci\` context is green."
    else
      echo "The CI of this pull request is green on the current head"
      echo "\`$sha\`: the checks have run and the \`ci\` context is green."
    fi
    if [ -n "$jobs" ]; then
      echo
      echo "Checks of that head: $jobs."
    fi
    if [ "${heavy:-0}" -gt 0 ]; then
      echo
      echo "The heavy lane of the CI (\`Native Linux tests\`) is skipped on"
      echo "purpose: it waits for the \`approved-for-ci\` label, which only a"
      echo "maintainer can add."
    fi
    # The local gate of this head, and WHICH one it was: the complete gate
    # covered the whole workspace, the scoped one only the packages of the
    # scope and their reverse dependencies. Saying "the full local gate is
    # green" when only the scoped gate ran would be a lie about a run that
    # did not happen.
    if [ -n "$gate" ]; then
      if [ "$(gate_verdict_of_text "$gate")" = "VERDE" ]; then
        echo
        echo "The complete gate (\`cargo xtask ci\`) was also run locally on that"
        echo "same head and it is green. The failures it reports are this"
        echo "machine's own baseline, none of them from this change."
      fi
    elif [ -n "$scope" ]; then
      echo
      echo "The scoped gate was run locally on that same head and it is green:"
      echo "the packages it covers ($packages) and their reverse dependencies"
      echo "pass, together with \`cargo fmt --check\`, \`cargo xtask layers\` and a"
      echo "scoped clippy. The whole workspace was NOT run."
    fi
    echo
    echo "The change is ready for review and for the merge queue."
  } | sed 's/[[:space:]]*$//'
}

# The comment that says the CI has not run yet: the stale one.
is_stale() {
  local body="$1"
  case "$body" in
    *action_required*|*"Approve workflows to run"*|*"every job of it is SKIPPED"*|*"every job skipped"*) return 0 ;;
    *) return 1 ;;
  esac
}

# The comment of this script: it is edited instead of duplicated, so the
# pull request does not collect one comment per run of this script. Both
# introductions are recognised: the script changed its wording once.
is_ours() {
  case "$1" in
    *"The CI of this pull request"*|*"Update on the CI of this pull request"*) return 0 ;;
    *) return 1 ;;
  esac
}

FAILED=0
for pr in "$@"; do
  sha="$(pr_head "$pr")"
  if [ -z "$sha" ]; then
    say "PR #$pr: the head could not be read: it is skipped"
    FAILED=1
    continue
  fi
  ci="$(ci_state "$sha")"
  jobs="$(ci_jobs "$sha")"
  heavy="$(ci_heavy_skipped "$sha")"
  gate_log=""
  gate=""
  if gate_log="$(gate_log_of_sha "$sha")"; then
    gate="$(gate_verdict_of "$gate_log")"
  fi
  scope=""
  scope_packages=""
  scope_file=""
  if scope_file="$(scope_verdict_of_sha "$sha")" && scope_is_green "$scope_file"; then
    scope="VERDE-SCOPE"
    scope_packages="$(scope_field "$scope_file" SCOPE)"
  fi

  # The comments of ours that this script has to deal with: the ones that say
  # the CI has not run yet (stale) and the ones it wrote itself (ours). They
  # are EDITED, never repeated next to each other.
  stale_ids=""
  ours_ids=""
  while IFS=$'\t' read -r cid cbody; do
    [ -n "$cid" ] || continue
    if is_stale "$cbody"; then
      stale_ids="$stale_ids $cid"
      continue
    fi
    if is_ours "$cbody"; then
      ours_ids="$ours_ids $cid"
    fi
  done < <(gh api "repos/$UPSTREAM/issues/$pr/comments?per_page=100" --jq \
    '.[]|select(.user.login=="vdirienzo")|[(.id|tostring), (.body|gsub("\t";" "))]|join("\t")' \
    2>/dev/null)

  # The one that carries the update: the LAST comment of this script if there
  # is one, otherwise the LAST stale comment (the most recent one).
  target_id=""
  kind="new"
  for cid in $ours_ids; do target_id="$cid"; done
  if [ -n "$target_id" ]; then
    kind="ours"
  else
    for cid in $stale_ids; do target_id="$cid"; done
    [ -n "$target_id" ] && kind="stale"
  fi

  body="$(build_body "$pr" "$sha" "$ci" "$jobs" "$gate_log" "$gate" \
    "${heavy:-0}" "$kind" "$scope" "$scope_packages")"

  if [ -n "$target_id" ]; then
    gh api -X PATCH "repos/$UPSTREAM/issues/comments/$target_id" \
      -f body="$body" >/dev/null 2>&1 \
      && say "PR #$pr: the comment $target_id was edited" \
      || { say "PR #$pr: the comment $target_id could not be edited"; FAILED=1; }
  else
    gh pr comment "$pr" -R "$UPSTREAM" --body "$body" >/dev/null 2>&1 \
      && say "PR #$pr: the comment was published" \
      || { say "PR #$pr: the comment could not be published"; FAILED=1; }
  fi

  # The others: they are marked as replaced, so nobody reads "the CI has not
  # run" on a pull request whose CI is green, and the pull request does not
  # collect one comment per run of this script.
  for cid in $stale_ids $ours_ids; do
    [ "$cid" = "$target_id" ] && continue
    gh api -X PATCH "repos/$UPSTREAM/issues/comments/$cid" \
      -f body="Replaced: the CI of this pull request has run since this comment was written, and the \`ci\` context of the current head is green. The current state is in the update below." \
      >/dev/null 2>&1 \
      && say "PR #$pr: the comment $cid was marked as replaced" \
      || { say "PR #$pr: the comment $cid could not be marked"; FAILED=1; }
  done
done

exit "$FAILED"
