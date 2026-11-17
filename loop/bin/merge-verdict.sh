#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# merge-verdict.sh: the signal of the merge, from the cheap lane of the CI.
#
#   merge-verdict.sh <pr-number> [expected-sha] [--comment]
#
# What it reads: the check runs of the HEAD commit of the pull request, from
# the upstream repository (tangency-labs/solidcraft). Only the CHEAP lane is
# read: the jobs that run without the `approved-for-ci` label ("Quick
# compile", "Format and repository checks", "Select checks"). The heavy jobs
# come as `skipped` until a maintainer approves the run, so they say nothing.
#
# Three rules, all measured on the real repository (26-10-2026):
#   - ONE RUN PER JOB NAME: a commit can have several check runs with the
#     same name (a workflow that ran twice). The NEWEST run of each name is
#     the one that says what the CI thinks now; the older ones are history.
#     Reading the older one of a pair gives the wrong answer (a `skipped`
#     of 13:52 read after the `success` of 14:19 says PENDIENTE).
#   - THE RESPONSE IS PAGINATED: the API returns 30 check runs per page (the
#     commit f5eb88ba has 45), so the call is paginated. A lane that does
#     not fit in the first page would be truncated, and a truncated lane
#     says PENDIENTE when it is not.
#   - THE EXPECTED SHA IS COMPARED BY PREFIX (7 characters or more): the
#     expected sha can be the short one that a log carries, and the head the
#     full one. It is the rule that state.py and start-gate.sh use.
#
# Why it is a signal and not a verdict: it says whether the code of the PR
# compiles and passes the repository checks of the upstream. It does NOT say
# that the change is correct, and it does NOT publish anything: the complete
# gate (cargo xtask ci) is what decides that.
#
# The verdict file ($LOOP_DIR/merge.verdict):
#   MERGE_VERDICT=VERDE|ROJO|PENDIENTE|STALE
#   MERGE_SHA=<sha>
#   MERGE_JOBS=<names of the jobs, separated by comma>
#   MERGE_PR=<n>
#   AT=<epoch>
#
#   VERDE: every job of the lane finished with success.
#   ROJO: some job of the lane finished with a failure (the jobs are listed).
#   PENDIENTE: some job is still running, or there is no run for that commit
#     yet (the push may not be registered), or gh could not be reached.
#   STALE: the head of the PR is not the commit that was expected (the signal
#     is about another commit). MERGE_SHA is the head that was read.
#
# The network is optional: if gh is missing or fails, the file says PENDIENTE
# and the script exits 0. A missing signal is not an error of the loop.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
UPSTREAM="${UPSTREAM:-tangency-labs/solidcraft}"
VERDICT_FILE="$LOOP_DIR/merge.verdict"

usage() {
  cat <<'EOF'
usage: merge-verdict.sh <pr-number> [expected-sha] [--comment]

Reads the check runs of the head commit of the pull request from the upstream
repository and writes $LOOP_DIR/merge.verdict (MERGE_VERDICT, MERGE_SHA,
MERGE_JOBS, MERGE_PR, AT).

Only the cheap lane is read (Quick compile, Format and repository checks,
Select checks): the heavy jobs are skipped until a maintainer approves the
run. The verdict is a SIGNAL, not a publish decision.

The expected sha is compared by prefix (7 characters or more), so the short
sha of a log is accepted. Only the newest run of each job name is read.

environment:
  LOOP_DIR   the loop directory (default: ~/.local/share/solidcraft-loop)
  UPSTREAM   the upstream repository (default: tangency-labs/solidcraft)
  GH_BIN     the gh binary (default: the one in the PATH, then ~/.local/bin/gh)

options:
  --comment  post the signal as a comment on the pull request (off by
             default: the loop decides when to write on the upstream)
EOF
}

PR=""
EXPECTED_SHA=""
COMMENT=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --comment) COMMENT=1; shift ;;
    --) shift; break ;;
    -*) echo "merge-verdict: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -z "$PR" ]; then
        PR="$1"
      elif [ -z "$EXPECTED_SHA" ]; then
        EXPECTED_SHA="$1"
      else
        echo "merge-verdict: too many arguments" >&2
        usage >&2
        exit 2
      fi
      shift ;;
  esac
done
if [ -z "$PR" ]; then
  echo "merge-verdict: the number of the pull request is needed" >&2
  usage >&2
  exit 2
fi
case "$PR" in
  ''|*[!0-9]*) echo "merge-verdict: '$PR' is not a pull request number" >&2; exit 2 ;;
esac

mkdir -p "$LOOP_DIR" 2>/dev/null || true

# The token of the loop, when the environment does not have one yet.
if [ -z "${GH_TOKEN:-}" ] && [ -r "$LOOP_DIR/gh.env" ]; then
  GH_TOKEN="$(sed -n 's/^GH_TOKEN=//p' "$LOOP_DIR/gh.env" 2>/dev/null | head -1)"
  export GH_TOKEN
fi

# The verdict is written here and nowhere else: the format is the contract
# with the reader of the loop, so it is written by ONE function.
write_verdict() {
  # write_verdict <verdict> <sha> <jobs>
  local verdict="$1" sha="$2" jobs="$3"
  local tmp="$VERDICT_FILE.tmp"
  if ! {
    printf 'MERGE_VERDICT=%s\n' "$verdict"
    printf 'MERGE_SHA=%s\n' "$sha"
    printf 'MERGE_JOBS=%s\n' "$jobs"
    printf 'MERGE_PR=%s\n' "$PR"
    printf 'AT=%s\n' "$(date +%s)"
  } > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    echo "merge-verdict: the verdict file cannot be written: $VERDICT_FILE" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$VERDICT_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    echo "merge-verdict: the verdict file cannot be replaced: $VERDICT_FILE" >&2
    return 1
  fi
  return 0
}

# The analysis of the check runs: the cheap lane only, and the verdict of it.
analyze() {
  # analyze <check-runs.json>
  python3 - "$1" <<'PY'
import json
import sys
from datetime import datetime, timezone

# The jobs that run without the `approved-for-ci` label. The heavy jobs are
# skipped until a maintainer approves the run, so they are not a signal.
LANE = ("Quick compile", "Format and repository checks", "Select checks")
# A conclusion that is neither a success nor a skip is a failure of the run:
# failure, timed_out, cancelled, action_required, neutral...
OK = ("success", "skipped")


def pages_of(text):
    """The JSON documents of the response, one per page.

    `gh api --paginate` answers with the pages concatenated (a page of an
    object endpoint is an object, so the body is `{...}{...}`), but the shape
    is not a contract: one object, an array of pages or an array of runs are
    read too. A body that cannot be read whole says nothing: the caller
    ends with PENDIENTE, never with a false VERDE.
    """
    decoder = json.JSONDecoder()
    documents = []
    index = 0
    length = len(text)
    while index < length:
        while index < length and text[index].isspace():
            index += 1
        if index >= length:
            break
        try:
            document, index = decoder.raw_decode(text, index)
        except ValueError:
            # A truncated body (or a body that is not JSON at all) is not a
            # signal: the pages read so far are dropped with it.
            return []
        documents.append(document)
    return documents


def runs_of(document):
    """The check runs of one page of the response."""
    if isinstance(document, dict):
        runs = document.get("check_runs")
        if isinstance(runs, list):
            return [run for run in runs if isinstance(run, dict)]
        return []
    if isinstance(document, list):
        out = []
        for item in document:
            if not isinstance(item, dict):
                continue
            if isinstance(item.get("check_runs"), list):
                out.extend(run for run in item["check_runs"]
                           if isinstance(run, dict))
            elif item.get("name"):
                out.append(item)
        return out
    return []


def moment(value):
    """A timestamp of the API as seconds, or None when it cannot be read."""
    text = str(value or "").strip()
    if not text:
        return None
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def order_of(run, index):
    """The order of a run: the newest run is the greatest one.

    The moment it started comes first, then the moment it finished, and
    finally the position in the response: the API returns the runs from the
    newest to the oldest (measured on the real repository: the check run of
    the `ci` job of 14:22 is the first one), so the FIRST one of a tie wins.
    """
    started = moment(run.get("started_at"))
    completed = moment(run.get("completed_at"))
    return (0 if started is None else 1, started or 0.0,
            0 if completed is None else 1, completed or 0.0, -index)


def newest_of(runs):
    """One run per name: the NEWEST run of each name.

    A commit can have several check runs with the same name (a workflow that
    ran twice, or a job that was re-run). The newest one is what the CI
    thinks now; the older ones are history. Without this rule a stale
    `skipped` or `in_progress` of an old run hides the `success` of the new
    one, and the signal says PENDIENTE when the lane is green.
    """
    best = {}
    for index, run in enumerate(runs):
        name = run.get("name", "")
        if not name:
            continue
        key = order_of(run, index)
        if name not in best or key > best[name][0]:
            best[name] = (key, index, run)
    return [best[name][2] for name in sorted(best, key=lambda n: best[n][1])]


def names(of):
    """The names of the jobs, without repeats."""
    out = []
    for run in of:
        name = run.get("name", "")
        if name and name not in out:
            out.append(name)
    return out


try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        text = fh.read()
except OSError:
    text = ""

runs = []
for document in pages_of(text):
    runs.extend(runs_of(document))

# The lane, with ONE run per job name: the newest one.
lane = newest_of([r for r in runs if r.get("name") in LANE])

pending = [r for r in lane if r.get("status") != "completed"]
failed = [r for r in lane if r.get("status") == "completed"
          and r.get("conclusion") not in OK]
succeeded = [r for r in lane if r.get("status") == "completed"
             and r.get("conclusion") == "success"]

if not lane:
    # No run for this commit (yet), or the lane did not start.
    verdict, jobs = "PENDIENTE", []
elif pending:
    # A job is still running: the verdict is not decided yet.
    verdict, jobs = "PENDIENTE", names(pending)
elif failed:
    verdict, jobs = "ROJO", names(failed)
elif succeeded:
    verdict, jobs = "VERDE", names(succeeded)
else:
    # Every job of the lane was skipped: there is no signal.
    verdict, jobs = "PENDIENTE", names(lane)

print(f"verdict={verdict}")
print(f"jobs={','.join(jobs)}")
PY
}

# --- the signal -----------------------------------------------------------
GH_BIN="${GH_BIN:-}"
if [ -z "$GH_BIN" ]; then
  if command -v gh >/dev/null 2>&1; then
    GH_BIN="$(command -v gh)"
  elif [ -x "$HOME/.local/bin/gh" ]; then
    GH_BIN="$HOME/.local/bin/gh"
  fi
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/merge-verdict.XXXXXX" 2>/dev/null)" || {
  echo "merge-verdict: a temporary directory cannot be created" >&2
  exit 1
}
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

HEAD_SHA=""
if [ -z "$GH_BIN" ]; then
  echo "merge-verdict: gh is not available: the signal is PENDIENTE" >&2
  write_verdict PENDIENTE unknown "" || exit 1
  exit 0
fi

if ! HEAD_SHA="$("$GH_BIN" api "repos/$UPSTREAM/pulls/$PR" --jq .head.sha 2>"$TMP/pr.err")"; then
  echo "merge-verdict: the head of the PR cannot be read: the signal is PENDIENTE" >&2
  sed 's/^/merge-verdict: /' "$TMP/pr.err" >&2
  write_verdict PENDIENTE unknown "" || exit 1
  exit 0
fi
HEAD_SHA="$(printf '%s' "$HEAD_SHA" | tr -d '\r\n[:space:]')"
if [ -z "$HEAD_SHA" ]; then
  echo "merge-verdict: the head of the PR is empty: the signal is PENDIENTE" >&2
  write_verdict PENDIENTE unknown "" || exit 1
  exit 0
fi

# The check runs of the commit, with every page: the API returns 30 per
# page, and a truncated lane would say PENDIENTE when it is not.
CHECKS="$TMP/check-runs.json"
CHECKS_URL="repos/$UPSTREAM/commits/$HEAD_SHA/check-runs?per_page=100"
if ! "$GH_BIN" api --paginate "$CHECKS_URL" > "$CHECKS" 2>"$TMP/checks.err"; then
  echo "merge-verdict: the check runs cannot be read: the signal is PENDIENTE" >&2
  sed 's/^/merge-verdict: /' "$TMP/checks.err" >&2
  write_verdict PENDIENTE "$HEAD_SHA" "" || exit 1
  exit 0
fi

OUT=""
if ! OUT="$(analyze "$CHECKS")"; then
  echo "merge-verdict: the check runs cannot be read: the signal is PENDIENTE" >&2
  write_verdict PENDIENTE "$HEAD_SHA" "" || exit 1
  exit 0
fi

VERDICT=""
JOBS=""
while IFS= read -r line; do
  case "$line" in
    verdict=*) VERDICT="${line#verdict=}" ;;
    jobs=*) JOBS="${line#jobs=}" ;;
  esac
done <<< "$OUT"
if [ -z "$VERDICT" ]; then
  VERDICT="PENDIENTE"
fi

# Two SHAs are the same commit when their common prefix (the shortest of the
# two) is long enough: the expected sha can be the short one that a log
# carries and the head the full one. It is the rule that state.py and
# start-gate.sh use to tie a verdict to a commit.
same_commit() {
  local left="${1:-}" right="${2:-}" size
  left="$(printf '%s' "$left" | tr '[:upper:]' '[:lower:]')"
  right="$(printf '%s' "$right" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$left" ] || [ -z "$right" ]; then
    return 1
  fi
  size=${#left}
  if [ "${#right}" -lt "$size" ]; then
    size=${#right}
  fi
  [ "$size" -ge 7 ] || return 1
  [ "${left:0:$size}" = "${right:0:$size}" ]
}

# The commit that was expected is not the head of the PR: the signal would be
# about another commit, so it says nothing about what was expected.
if [ -n "$EXPECTED_SHA" ] && ! same_commit "$EXPECTED_SHA" "$HEAD_SHA"; then
  echo "merge-verdict: the head of the PR is $HEAD_SHA, not $EXPECTED_SHA" >&2
  VERDICT="STALE"
fi

write_verdict "$VERDICT" "$HEAD_SHA" "$JOBS" || exit 1

# The signal is printed too, so the loop can put it in a comment.
BODY="Merge signal (cheap lane): $VERDICT"
if [ -n "$JOBS" ]; then
  BODY="$BODY -- jobs: $JOBS"
fi
BODY="$BODY -- commit: $HEAD_SHA"
BODY="$BODY

This is a signal, not a publish verdict: the complete gate decides that."
printf '%s\n' "$BODY"

if [ "$COMMENT" -eq 1 ]; then
  if "$GH_BIN" api "repos/$UPSTREAM/issues/$PR/comments" -f body="$BODY" >/dev/null 2>&1; then
    echo "merge-verdict: the signal was commented on the PR" >&2
  else
    echo "merge-verdict: the comment could not be posted" >&2
  fi
fi

exit 0
