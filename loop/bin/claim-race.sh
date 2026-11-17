#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# claim-race.sh - THE RULE OF THE CLAIM: who holds the claim of an issue?
#
# THIS IS THE ONLY SCRIPT THAT DECIDES THE CLAIM. Everything that publishes
# or that works on an issue asks IT: the brake of the loop
# (bin/claim-brake.sh), the legacy guard of the funnel (bin/claim-guard.sh),
# the free-check (bin/claim-free.sh), the publisher (bin/agent-issue.sh)
# and the orchestrator (bin/claim-verify.sh) are ADAPTERS over this script,
# not another copy of the rule.
#
# WHY THIS EXISTS (01-11-2026): the claim of an issue is a RACE and the
# upstream label loses it (the bot applies 'in progress' with a DELAY). We
# lost the work of four issues that way: the code was written, the gate ran,
# the draft was opened, and then another agent's pull request turned out to
# hold the claim. The rule of the upstream is "the LOWEST numbered open pull
# request wins", so the question is not "is the issue claimed" but "WHO holds
# the claim and is it still us".
#
# THE WAYS OF LOSING ARE DIFFERENT AND THEY DESERVE DIFFERENT ANSWERS:
#   * TAKEN     somebody else holds the claim and we have no pull request
#              yet: the issue is not free to work on.
#   * LOST      somebody else holds the claim WITH A LOWER NUMBER than ours:
#              we lost the race. Our pull request is a duplicate and has to
#              be closed; the work has to be KEPT (it can be re-targeted to
#              another issue, or offered on the pull request that won).
#   * RESOLVED  the issue is not OPEN any more: it was closed, usually by the
#              pull request that fixed it. NOBODY won a race against us: the
#              work is MOOT, not lost. It is not published against that
#              issue, and it is not thrown away either.
#   * UNKNOWN   GitHub could not be read, or the list came back truncated:
#              the guard does NOT know, and a claim without a check is a
#              duplicate waiting to happen. Publishing over a claim that was
#              never seen is exactly how four issues were lost.
#
# THE RULE IS THE RULE OF THE UPSTREAM, not an invention of ours. The
# upstream decides the claim of an issue in TWO places, and this script reads
# both, because both can take the claim away from us:
#   * scripts/claim/claim.js (handlePull): a pull request CLAIMS an issue
#     when its title names it ("(#N)") or its body closes it ("Fixes #N"),
#     and the OLDEST open pull request wins (the lowest number). The
#     candidates are the pull requests that CROSS-REFERENCED the issue: they
#     are in the TIMELINE of the issue.
#   * scripts/pr-checks/pr-checks.js (findDuplicates): the CI fails our pull
#     request when a LOWER-numbered open pull request of ANOTHER author
#     closes the same issue. That is the check that turns a lost race into a
#     red pull request, so the arbitration here has to be at least as strict.
#
# The pull requests of OUR OWN author do not take the claim from us: the
# upstream skips the work of the same author (stacked pull requests), so this
# script skips it too. Without that rule a second pull request of ours for
# the same issue would make us lose a race against ourselves.
#
# THE MODES, ONE ARBITER (the same data, three questions):
#   * SELECTION (we are asking whether we may WORK on this issue): the
#     RECORD of the issue is read first (its assignees and the comments of
#     the bot: the label 'in progress' is applied with a delay, so its
#     ABSENCE is not proof and its presence is only one of the proofs),
#     and then the open pull requests of ANOTHER author that mention the
#     issue. Being wrong here costs a candidate issue; being wrong in the
#     race costs the whole work.
#   * RACE (we have a pull request for the issue and we ask whether we
#     still hold the claim): here the rule of the upstream decides: the
#     lowest numbered open pull request that CLAIMS the issue wins, and the
#     pull requests of the same author do not count. A pull request that
#     merely MENTIONS the issue does not take the claim from us, so it does
#     not make us lose.
#   * FUNNEL (may a NEW claim be made on this issue?): the issue is OPEN, it
#     carries no excluded label (the label of a claim included: the issue
#     is being worked on) and no open pull request of ANY author mentions
#     it, except the one that is being published right now.
#
# THE FACTS ARE CHEAP AND THE LIST IS NOT: the state, the labels and the
# record of the issue are read FIRST, and the list of the open pull requests
# is only read when they do not decide. A GitHub that does not answer is a
# FAILURE of the check, never a "free" issue.
#
# ONE PROCESS, ONE ANSWER: the rule is applied by ONE python program that
# reads GitHub itself and prints the answer. There is no second pass and no
# answer that travels from one process to another: a rule that is computed
# in two halves can disagree with itself, and a disagreement here is a
# duplicated pull request.
#
# USAGE:
#   bash bin/claim-race.sh <issue> [our_pr]
#   bash bin/claim-race.sh --issue N [--pr P] [--mode selection|race|funnel]
#                            [--repo R]
#
# The mode is chosen AUTOMATICALLY when it is not given: the race when we
# have a pull request for the issue (the one that is given, or our own open
# pull request for it), the selection otherwise.
#
# EXIT CODES (the only ones of the rule; every caller translates them):
#   0   OK        the claim is ours, or the issue is free
#   10  TAKEN     somebody else holds the claim (TAKEN or LOST)
#   11  RESOLVED  the issue is not open any more (the work is moot)
#   12  UNKNOWN   GitHub could not be read: the guard does NOT know
#   2   usage error
#
# The machine-readable answer goes to STDOUT, one KEY=VALUE per line:
#   VERDICT=OK|TAKEN|LOST|RESOLVED|UNKNOWN
#   REASON=<slug>             WHY (free, ours, lost-race, claimed-by,
#                             assigned, claim-label, mentioned-by-pr,
#                             issue-closed, issue-not-found, excluded-label,
#                             already-handled, unknown-github,
#                             unknown-truncated)
#   ISSUE=<n>
#   OURS=<pr>                 (the pull request the race is decided against)
#   HOLDER=<pr>               (the pull request that holds the claim)
#   HOLDER_AUTHOR=<login>
#   HOLDER_OURS=yes|no        (the holder is a pull request of our own author)
#   HOLDER_CLAIMS=yes|no      (the holder CLAIMS the issue the way the upstream
#                             parses it: that is the one that fails our CI)
#   HOLDER_LOGIN=<login>      (the person the RECORD names, when it is not
#                             a pull request: the bot's claim or an assignee)
#   OURS_HOLDER=<pr>          (our own open pull request for this issue)
#   ISSUE_STATE=OPEN|CLOSED
#   ISSUE_STATE_REASON=COMPLETED|NOT_PLANNED|...
# The human sentences go to STDERR, so a caller can parse the answer without
# reading prose.
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"

ISSUE=""
OUR_PR=""
MODE=""
REPO_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE="$2"; shift 2 ;;
    --pr)    OUR_PR="$2"; shift 2 ;;
    --mode)  MODE="$2"; shift 2 ;;
    --repo)  REPO_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    --*) echo "claim-race: unknown option: $1" >&2; exit 2 ;;
    *)  if [ -z "$ISSUE" ]; then ISSUE="$1"; shift
        elif [ -z "$OUR_PR" ]; then OUR_PR="$1"; shift
        else echo "claim-race: too many arguments: $1" >&2; exit 2
        fi ;;
  esac
done

if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "claim-race: the issue has to be a number: '$ISSUE'" >&2
  exit 2
fi
if [ -n "$OUR_PR" ] && ! [[ "$OUR_PR" =~ ^[0-9]+$ ]]; then
  echo "claim-race: our pull request has to be a number: '$OUR_PR'" >&2
  exit 2
fi
case "$MODE" in
  ""|selection|race|funnel) ;;
  *) echo "claim-race: the mode has to be selection, race or funnel: '$MODE'" >&2; exit 2 ;;
esac

# The rule is ONE python program: it reads GitHub, it decides and it prints
# the answer. It is run ONCE.
exec python3 - "$ISSUE" "$OUR_PR" "$MODE" "$REPO_OVERRIDE" "$LOOP_DIR" <<'PY'
import json
import os
import re
import subprocess
import sys

ISSUE, OUR_PR, MODE, REPO_OVERRIDE, LOOP_DIR = sys.argv[1:6]

# The verdict of the rule: the ONE vocabulary, and the ONE set of exit codes.
OK, TAKEN, LOST, RESOLVED, UNKNOWN = "OK", "TAKEN", "LOST", "RESOLVED", "UNKNOWN"
CODE = {OK: 0, TAKEN: 10, LOST: 10, RESOLVED: 11, UNKNOWN: 12}

ANSWER = {}


def say(text):
    sys.stderr.write("claim-race: %s\n" % text)


def emit(verdict, reason, holder="", holder_author="", claims_it="",
         holder_login="", state="", state_reason="", ours_holder=""):
    """The answer of the rule, in the ONE vocabulary and the ONE format."""
    ANSWER["verdict"] = verdict
    ANSWER["reason"] = reason
    ANSWER["holder"] = str(holder)
    ANSWER["holder_author"] = str(holder_author)
    ANSWER["claims"] = str(claims_it)
    ANSWER["holder_login"] = str(holder_login)
    ANSWER["state"] = str(state)
    ANSWER["state_reason"] = str(state_reason)
    ANSWER["ours_holder"] = str(ours_holder)


# --- the configuration -------------------------------------------------------
# config.env is the source of truth of the loop, and it is read HERE (not
# sourced): a value with a space in it ("in progress,kernel-paused") is a
# value, not a command. The environment is the second source, and the built
# in default is the last one.
def read_config(path):
    cfg = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[7:].strip()
                if "=" not in line:
                    continue
                key, _, value = line.partition("=")
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                else:
                    value = value.split(" #")[0].strip()
                cfg[key.strip()] = value
    except OSError:
        pass
    return cfg


CONFIG = read_config(os.path.join(LOOP_DIR, "config.env"))


def setting(name, default=""):
    for value in (CONFIG.get(name), os.environ.get(name)):
        if value:
            return value
    return default


def gh(args, timeout):
    """A call to `gh`. It returns (rc, stdout, stderr)."""
    try:
        done = subprocess.run(["gh"] + list(args), stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "", "the call to gh timed out"
    except OSError as exc:
        return None, "", str(exc)
    return (done.returncode, done.stdout.decode("utf-8", "replace"),
            done.stderr.decode("utf-8", "replace"))


def main():
    issue = ISSUE
    ours = OUR_PR
    mode = MODE or "auto"

    repo = (REPO_OVERRIDE or setting("SC_REPO") or setting("UPSTREAM")
            or "tangency-labs/solidcraft")
    try:
        limit = int(setting("SC_PR_LIMIT") or setting("CLAIM_PR_LIMIT") or "1000")
    except ValueError:
        limit = 1000
    if limit < 1:
        limit = 1000
    author = setting("SC_FORK_OWNER") or setting("FORK_OWNER") or ""
    claim_label = (setting("SC_CLAIM_LABEL") or "in progress").lower()
    excluded = (setting("CLAIM_EXCLUDED_LABELS")
                or "in progress,kernel-paused,status:decision,needs-info,"
                   "area:kernel")
    excluded_set = {t.strip().lower() for t in excluded.split(",") if t.strip()}

    # --- the record of the issue --------------------------------------------
    # The state, the labels, the assignees AND the comments in one call: the
    # comments are the part that the label cannot replace (the bot applies
    # the label of a claim with a delay).
    rc, out, err = gh(["issue", "view", issue, "--repo", repo, "--json",
                       "number,state,stateReason,labels,assignees,comments"],
                      120)
    if rc is None or rc != 0:
        # An issue that does not exist is not ignorance, it is a fact: there
        # is nothing to work on. A network that does not answer is ignorance.
        if re.search(r"404|not found|could not resolve", err or "", re.I):
            emit(RESOLVED, "issue-not-found", state="CLOSED")
            return
        emit(UNKNOWN, "unknown-github")
        return
    if not out.strip():
        emit(UNKNOWN, "unknown-github")
        return
    try:
        issue_doc = json.loads(out)
    except ValueError:
        emit(UNKNOWN, "unknown-github")
        return
    if not isinstance(issue_doc, dict):
        emit(UNKNOWN, "unknown-github")
        return

    labels = []
    for label in (issue_doc.get("labels") or []):
        name = str(label.get("name", "") if isinstance(label, dict) else label)
        if name:
            labels.append(name.strip())
    lowered = {name.lower() for name in labels}

    assignees = []
    for assignee in (issue_doc.get("assignees") or []):
        login = str((assignee or {}).get("login", "")
                    if isinstance(assignee, dict) else assignee)
        if login:
            assignees.append(login.strip())

    comments = []
    for comment in (issue_doc.get("comments") or []):
        if not isinstance(comment, dict):
            continue
        who = str((comment.get("author") or {}).get("login", "") or "")
        body = str(comment.get("body") or "")
        when = str(comment.get("createdAt") or "")
        comments.append((when, who, body))
    comments.sort(key=lambda item: item[0])

    CLAIMED_BY = re.compile(r"^Claimed by @([A-Za-z0-9-]+)\b", re.IGNORECASE)
    RELEASED = re.compile(r"\bfree again\b|\bReleased\.\b", re.IGNORECASE)
    HANDLED = re.compile(
        r"\balready (?:fixed|resolved|handled|done)\b"
        r"|\bfixed by\s+#\d+"
        r"|\bsame root cause\b"
        r"|\bduplicate of\s+#\d+"
        r"|\bplease reopen\b",
        re.IGNORECASE)

    record_holder = ""
    record_holder_ours = False
    for _when, _who, body in comments:
        match = CLAIMED_BY.search(body.strip())
        if match:
            record_holder = match.group(1)
            continue
        if RELEASED.search(body):
            record_holder = ""
            continue

    handled_evidence = ""
    for _when, _who, body in comments:
        if not handled_evidence and HANDLED.search(body):
            handled_evidence = body.strip().splitlines()[0][:160]

    # Our OWN claim is not a claim against us, and our own comments do not take
    # the issue out of our own funnel. The claim that is OURS is remembered
    # apart: the label of the upstream ('in progress') is applied by the bot
    # WHEN IT GRANTS THE CLAIM, so the label of our own claim is on the issue
    # and it does not mean that somebody else is working on it.
    if record_holder and author and record_holder.lower() == author.lower():
        record_holder_ours = True
        record_holder = ""
    ours_assignees = [login for login in assignees
                      if author and login.lower() == author.lower()]
    other_assignees = [login for login in assignees
                       if login not in ours_assignees]

    def excluded_labels(without_claim_label=False):
        """The labels that take the issue out of the funnel."""
        wanted = set(excluded_set)
        if without_claim_label:
            wanted.discard(claim_label)
        return sorted(lowered & wanted)

    issue_state = str(issue_doc.get("state") or "")
    issue_reason = str(issue_doc.get("stateReason") or "")
    ours_holder = ""

    # --- the facts that do not need the pull requests -----------------------
    if issue_state and issue_state != "OPEN":
        emit(RESOLVED, "issue-closed", state=issue_state,
             state_reason=issue_reason)
        return

    if mode == "funnel":
        # May a NEW claim be made on this issue? The labels that take it out
        # of the funnel come first: the work would be thrown away whatever
        # the claim says. The label of a claim IS one of them (the issue is
        # being worked on).
        if excluded_labels():
            emit(RESOLVED, "excluded-label", state=issue_state,
                 state_reason=issue_reason)
            return
    else:
        # The labels that take the issue out of the funnel for a reason that
        # is not somebody's claim. The label of a claim is NOT one of them
        # here: it is the claim itself, and it is judged below.
        if excluded_labels(without_claim_label=True):
            emit(RESOLVED, "excluded-label", state=issue_state,
                 state_reason=issue_reason)
            return

    # The RECORD of the issue: the strongest proof that somebody else is
    # already there (the bot's claim, an assignee).
    if record_holder:
        emit(TAKEN, "claimed-by", claims_it="no", holder_login=record_holder,
             state=issue_state, state_reason=issue_reason)
        return
    if other_assignees:
        emit(TAKEN, "assigned", holder_login=other_assignees[0],
             state=issue_state, state_reason=issue_reason)
        return

    # Our own claim (the bot's comment naming us, or the assignee being us)
    # means the label of a claim on the issue is OURS: it is not a claim
    # against us.
    ours_claim = record_holder_ours or bool(ours_assignees)
    if mode == "selection":
        if claim_label in lowered and not ours_claim:
            emit(TAKEN, "claim-label", state=issue_state,
                 state_reason=issue_reason)
            return
        if handled_evidence:
            emit(RESOLVED, "already-handled", state=issue_state,
                 state_reason=issue_reason)
            return

    # --- the open pull requests ---------------------------------------------
    # `gh pr list` and NOT `gh api`: the listing of the api returns the body
    # of some pull requests empty and the filter over the body finds nothing.
    rc, out, err = gh(["pr", "list", "--repo", repo, "--state", "open",
                       "--limit", str(limit), "--json",
                       "number,title,body,author"], 240)
    if rc is None or rc != 0 or not out.strip():
        emit(UNKNOWN, "unknown-github", state=issue_state,
             state_reason=issue_reason)
        return
    try:
        prs = json.loads(out)
    except ValueError:
        emit(UNKNOWN, "unknown-github", state=issue_state,
             state_reason=issue_reason)
        return
    if not isinstance(prs, list):
        emit(UNKNOWN, "unknown-github", state=issue_state,
             state_reason=issue_reason)
        return

    # A list that came back TRUNCATED is not a list: the guard does NOT know
    # and it does not say "the issue is free".
    if len(prs) >= limit:
        emit(UNKNOWN, "unknown-truncated", state=issue_state,
             state_reason=issue_reason)
        return

    # The timeline of the issue: the pull requests that cross-referenced it
    # are in it, and that is where the upstream looks for them (linkedPulls).
    # It is also the only place where a pull request that mentioned the issue
    # and then edited the mention away is still seen.
    rc, out, err = gh(["api",
                       "repos/%s/issues/%s/timeline?per_page=100" % (repo, issue),
                       "--paginate", "--slurp"], 180)
    if rc is None or rc != 0:
        emit(UNKNOWN, "unknown-github", state=issue_state,
             state_reason=issue_reason)
        return

    timeline = []
    timeline_ok = True
    try:
        timeline = json.loads(out) if out.strip() else []
    except ValueError:
        # The timeline is not JSON: it is the plain list of the numbers of the
        # cross-referenced pull requests (the shape the old guard asked for).
        # Then the text of the pull request is not known: the cross-reference
        # counts as a MENTION (it is evidence that somebody talked about the
        # issue) and it is not proof of a claim.
        timeline = []
        timeline_ok = False
    if isinstance(timeline, list) and timeline and isinstance(timeline[0], list):
        timeline = [item for page in timeline for item in page]
    if not isinstance(timeline, list):
        timeline = []
        timeline_ok = False

    open_prs = {}
    for pr in prs:
        try:
            number = int(pr.get("number"))
        except (TypeError, ValueError):
            continue
        open_prs[number] = {
            "author": str((pr.get("author") or {}).get("login") or ""),
            "title": str(pr.get("title") or ""),
            "body": str(pr.get("body") or ""),
            "bare": False,
        }

    # The pull requests that cross-referenced the issue. Their title and body
    # are the ones they had at the moment of the reference: a pull request
    # that mentions the issue and then edits the mention away still shows
    # here, and the upstream reads the timeline exactly like this.
    cross = {}
    if timeline_ok:
        for event in timeline:
            if not isinstance(event, dict):
                continue
            if event.get("event") != "cross-referenced":
                continue
            source = event.get("source") or {}
            issue_ref = source.get("issue") or {}
            if not issue_ref.get("pull_request"):
                continue
            try:
                number = int(issue_ref.get("number"))
            except (TypeError, ValueError):
                continue
            cross[number] = {
                "author": str((issue_ref.get("user") or {}).get("login") or ""),
                "title": str(issue_ref.get("title") or ""),
                "body": str(issue_ref.get("body") or ""),
                "bare": False,
            }
    else:
        for line in (out or "").splitlines():
            line = line.strip()
            if line.isdigit():
                cross[int(line)] = {"author": "", "title": "", "body": "",
                                    "bare": True}

    # The MENTION rule of the house: any "#N" in the title or in the body.
    # The word boundary matters: #103061 is not a mention of #10306.
    MENTION = re.compile(r"#%s\b" % re.escape(issue))
    # The rule of the upstream (scripts/claim/claim.js, referencedIssues): the
    # title names the issue ("(#N)") or the body CLOSES it ("Fixes #N").
    TITLE_REF = re.compile(r"(?:^|[\s(])#%s\b" % re.escape(issue))
    # The body of the upstream that does NOT strip the noise: a "Fixes #N"
    # inside a code block still claims the issue for the bot.
    BODY_CLOSE_RAW = re.compile(
        r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+#%s\b"
        % re.escape(issue), re.IGNORECASE)
    # The parser of the CI (scripts/pr-checks/pr-checks.js, parseClosing): it
    # strips the code blocks and the inline code, and it reads a LIST of
    # issues ("Fixes #1, #2"). It is the check that turns our pull request
    # RED.
    BODY_CLOSE_CI = re.compile(
        r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?[ \t]+"
        r"((?:(?:[\w.-]+/[\w.-]+)?#\d+(?:[ \t]*(?:,|and|&)[ \t]*)?)+)",
        re.IGNORECASE)
    CODE_BLOCK = re.compile(r"```[\s\S]*?```|~~~[\s\S]*?~~~")
    HTML_COMMENT = re.compile(r"<!--[\s\S]*?-->")
    INLINE_CODE = re.compile(r"`[^`\n]*`")

    def strip_noise(body):
        """The noise the CI strips: a "Fixes #N" inside a code block is an
        example, not a claim."""
        text = HTML_COMMENT.sub("", body)
        text = CODE_BLOCK.sub("", text)
        return INLINE_CODE.sub("", text)

    def body_closes_ci(body):
        """The parser of the CI: does the body close OUR issue?"""
        text = strip_noise(body)
        for match in BODY_CLOSE_CI.finditer(text):
            for ref in re.finditer(r"(?:([\w.-]+/[\w.-]+))?#(\d+)", match.group(1)):
                if ref.group(1) and repo and ref.group(1).lower() != repo.lower():
                    continue  # a URL to another repository does not close ours
                if int(ref.group(2)) == int(issue):
                    return True
        return False

    def mentions(entry):
        """The house's rule: this pull request MENTIONS the issue."""
        if entry.get("bare"):
            return True  # a cross-reference is evidence of a mention
        return bool(MENTION.search(entry["title"]) or MENTION.search(entry["body"]))

    def claims(entry):
        """The upstream's rule: this pull request CLAIMS the issue.

        It is the union of the two parsers of the upstream: the one of the
        bot (the title names it, or the body closes it, noise included) and
        the one of the CI (the body closes it, noise stripped, lists
        included). The arbitration has to be at least as strict as the
        strictest of them: a claim that only one of them sees still takes the
        claim away from us.
        """
        if entry.get("bare"):
            return False  # without the text of the pull request there is no claim
        if TITLE_REF.search(entry["title"]):
            return True
        if BODY_CLOSE_RAW.search(entry["body"]):
            return True
        return body_closes_ci(entry["body"])

    def is_ours(entry):
        return bool(author) and entry["author"] == author

    # Our own open pull request for this issue: the one that is being
    # published, or an older one of ours. It is reported, and it never takes
    # the claim from us (the upstream skips the stacked work of the same
    # author).
    for number, entry in sorted(open_prs.items()):
        if ours and number == int(ours):
            continue
        if is_ours(entry) and mentions(entry):
            ours_holder = str(number)
            break

    def holders(predicate, any_author=False, cross_is_holder=False):
        """The open pull requests that satisfy the predicate.

        The pull request of the same author does not count (the upstream
        skips the stacked work of the same author), and neither does the
        pull request that is being published right now. The funnel counts
        everybody: a NEW claim on an issue that we already have open is a
        duplicate too.
        """
        found = []
        for number, entry in sorted(open_prs.items()):
            if ours and number == int(ours):
                continue
            if not any_author and is_ours(entry):
                continue
            if predicate(entry):
                found.append((number, entry))
        # The cross-references of the timeline: a pull request that mentioned
        # the issue and then edited the mention away is still seen there,
        # with the text it had at the moment of the reference.
        for number, entry in sorted(cross.items()):
            if number not in open_prs:
                continue  # only the OPEN pull requests hold a claim
            if ours and number == int(ours):
                continue
            if not any_author and is_ours(entry):
                continue
            if cross_is_holder or predicate(entry):
                found.append((number, entry))
        return found

    def lowest(candidates):
        return sorted(candidates, key=lambda item: item[0])[0] if candidates else None

    # --- the FUNNEL --------------------------------------------------------
    if mode == "funnel":
        # No open pull request of ANY author may hold the issue, except the
        # one that is being published right now (and only when it is really
        # ours: a pull request that demonstrably belongs to somebody else
        # keeps the claim).
        ours_author = ""
        if ours:
            for number, entry in open_prs.items():
                if number == int(ours):
                    ours_author = entry["author"]
                    break
        exclude_ours = bool(ours) and ours_author in ("", author)
        claimers = []
        for number, entry in sorted(open_prs.items()):
            if exclude_ours and number == int(ours):
                continue
            if mentions(entry):
                claimers.append((number, entry))
        for number, entry in sorted(cross.items()):
            if number not in open_prs:
                continue
            if exclude_ours and number == int(ours):
                continue
            claimers.append((number, entry))
        if claimers:
            number, entry = sorted(claimers, key=lambda item: item[0])[0]
            emit(TAKEN, "mentioned-by-pr", holder=number,
                 holder_author=entry["author"],
                 claims_it="yes" if claims(entry) else "no",
                 holder_login=record_holder, state=issue_state,
                 state_reason=issue_reason, ours_holder=ours_holder)
            return
        emit(OK, "free", holder_login=record_holder, state=issue_state,
             state_reason=issue_reason, ours_holder=ours_holder)
        return

    # --- the RACE ----------------------------------------------------------
    if mode == "race" or (mode == "auto" and (ours or ours_holder)):
        # The lowest numbered holder that CLAIMS the issue wins. If that
        # number is lower than ours we lost the race; if it is higher we
        # still hold it and the other pull request is the one to close.
        ours_number = int(ours) if ours else (int(ours_holder) if ours_holder else 0)
        winner = lowest(holders(claims))
        if winner is None:
            emit(OK, "ours", holder_login=record_holder, state=issue_state,
                 state_reason=issue_reason, ours_holder=ours_holder)
            return
        number, entry = winner
        if not ours_number:
            # We have NO pull request of our own for this issue: the pull
            # request that holds the claim is OPEN, so its number is lower
            # than the one ours is going to get. The race is lost before it
            # starts.
            emit(TAKEN, "claimed-by-pr", holder=number,
                 holder_author=entry["author"], claims_it="yes",
                 holder_login=record_holder, state=issue_state,
                 state_reason=issue_reason, ours_holder=ours_holder)
            return
        if number >= ours_number:
            emit(OK, "ours", holder=number, holder_author=entry["author"],
                 claims_it="yes", holder_login=record_holder, state=issue_state,
                 state_reason=issue_reason, ours_holder=ours_holder)
            return
        emit(LOST, "lost-race", holder=number, holder_author=entry["author"],
             claims_it="yes", holder_login=record_holder, state=issue_state,
             state_reason=issue_reason, ours_holder=ours_holder)
        return

    # --- the SELECTION -----------------------------------------------------
    # A pull request of OURS already claims this issue: opening a second one
    # would be a duplicate of our own work.
    if ours_holder:
        emit(TAKEN, "duplicate-of-ours", holder=ours_holder,
             holder_author=author, claims_it="no", holder_login=record_holder,
             state=issue_state, state_reason=issue_reason, ours_holder=ours_holder)
        return

    # Any open pull request of another author that mentions the issue means
    # the issue is taken: the mention does not have to be a claim.
    winner = lowest(holders(mentions))
    if winner is not None:
        number, entry = winner
        emit(TAKEN, "mentioned-by-pr", holder=number,
             holder_author=entry["author"],
             claims_it="yes" if claims(entry) else "no",
             holder_login=record_holder, state=issue_state,
             state_reason=issue_reason, ours_holder=ours_holder)
        return

    emit(OK, "free", holder_login=record_holder, state=issue_state,
         state_reason=issue_reason, ours_holder=ours_holder)


main()

# --- the answer --------------------------------------------------------------
verdict = ANSWER.get("verdict", UNKNOWN)
reason = ANSWER.get("reason", "unknown-github")
if verdict not in CODE:
    verdict, reason = UNKNOWN, "unknown-github"

lines = ["VERDICT=%s" % verdict, "REASON=%s" % reason, "ISSUE=%s" % ISSUE]
if OUR_PR:
    lines.append("OURS=%s" % OUR_PR)
if ANSWER.get("holder"):
    lines.append("HOLDER=%s" % ANSWER["holder"])
if ANSWER.get("holder_author"):
    lines.append("HOLDER_AUTHOR=%s" % ANSWER["holder_author"])
    lines.append("HOLDER_OURS=%s" % ("yes" if ANSWER["holder_author"] == setting(
        "SC_FORK_OWNER") or setting("FORK_OWNER") else "no"))
if ANSWER.get("claims"):
    lines.append("HOLDER_CLAIMS=%s" % ANSWER["claims"])
if ANSWER.get("holder_login"):
    lines.append("HOLDER_LOGIN=%s" % ANSWER["holder_login"])
if ANSWER.get("ours_holder"):
    lines.append("OURS_HOLDER=%s" % ANSWER["ours_holder"])
if ANSWER.get("state"):
    lines.append("ISSUE_STATE=%s" % ANSWER["state"])
if ANSWER.get("state_reason"):
    lines.append("ISSUE_STATE_REASON=%s" % ANSWER["state_reason"])
sys.stdout.write("\n".join(lines) + "\n")

# The sentences, for the human that reads the log.
if verdict == OK:
    say("the claim of the issue #%s is ours (nobody holds it with a lower number)" % ISSUE)
elif verdict == TAKEN:
    if ANSWER.get("holder"):
        say("the issue #%s is TAKEN: the open pull request #%s mentions it"
            % (ISSUE, ANSWER["holder"]))
    else:
        say("the issue #%s is TAKEN: the record of the issue names @%s"
            % (ISSUE, ANSWER.get("holder_login") or "?"))
elif verdict == LOST:
    say("the claim of the issue #%s is LOST: the open pull request #%s holds it and its number is lower"
        % (ISSUE, ANSWER.get("holder") or "?"))
elif verdict == RESOLVED:
    say("the issue #%s is not OPEN any more (%s): the work is moot, not lost"
        % (ISSUE, reason))
else:
    say("the claim of the issue #%s could not be verified (%s): the guard does not know"
        % (ISSUE, reason))

sys.exit(CODE[verdict])
PY
