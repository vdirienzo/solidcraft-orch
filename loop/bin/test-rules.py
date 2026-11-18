#!/usr/bin/env python3
"""Regression tests for the supervisor's rules (bin/state.py).

They are the rules the model cannot bend:
  * a phase that is not a transition is refused;
  * the gate's verdict is the SCRIPT's, and a green gate moves `gating` ->
    `gated` on its own;
  * a verdict of another commit is not a verdict;
  * `published` needs a green gate, an approved review, the quota and the
    cooldown;
  * the review verdict only counts when the REVIEW WORKER said it (the
    orchestrator cannot approve itself);
  * a verdict is a verdict ABOUT A COMMIT: without the sha the worker
    reviewed it is refused, and the publication needs it to be the head of
    the PR;
  * the verdict of a worker that finished late is collected at the end of
    the turn (it is not lost);
  * the approval of the workflows is per run (per head SHA);
  * the triage of the turn is kept: a dropped issue is not triaged again;
  * the two signals of the loop (the verdict of the quick gate and the
    signal of the merge) are exposed in the state with their sha, they are
    marked as obsolete when they are about another commit, and they never
    publish: they are partial;
  * the SCOPED gate of a slot (VERDE-SCOPE) is an authorisation: it
    publishes when it is green about the head of the PR, and it is refused
    when it is red, when it is about another commit, when a check did not
    run, when the scope is the whole workspace, or when it belongs to
    another slot.

THE TESTS ARE HERMETIC: they touch nothing outside their own temporary
directory.
  * their own loop directory: its own logs/, its own gate.sha and its own
    gate-check.sh (a double: the tests do not run a CI). The live loop, its
    live gate.sha and its live logs are never read nor written;
  * a fake `gh` first in the PATH: the head of the PR is the test's own HEAD
    and `gh pr list` answers an empty list. GitHub is never contacted;
  * their own HOME: the worktree of an issue is never found there;
  * the report is marked as already published: no issue is ever created.

Run:  python3 ~/.local/share/solidcraft-loop/bin/test-rules.py
"""
import contextlib
import importlib.machinery
import importlib.util
import datetime as dt
import inspect
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LOOP = os.path.dirname(HERE)

# This suite tests the scripts that live NEXT TO IT, so it has to be run from
# its own directory. A copy somewhere else (a /tmp scratch copy, for example)
# resolves LOOP to the parent of that copy and then looks for the scripts
# under a directory that does not exist: the suite dies with a traceback in
# the middle of a rule, which reads as a broken rule and not as a broken
# invocation. Say it plainly instead.
if not os.path.isfile(os.path.join(HERE, "state.py")):
    sys.stderr.write(
        "test-rules.py has to run from its own directory: it tests the scripts\n"
        "that live next to it, and this copy has none. Expected %s/state.py and\n"
        "did not find it. Run it as: python3 %s\n"
        % (HERE, os.path.join(LOOP, "bin", "test-rules.py")))
    sys.exit(2)

# The supervisor under test. `LOOP_STATE_PY` points at another copy of it:
# that is how the tests are run against the code BEFORE a fix (the red of the
# regression).
STATE_PY = os.environ.get("LOOP_STATE_PY", os.path.join(HERE, "state.py"))

# The head SHA of the PR the tests speak about (#4629). It is the head the
# fake `gh` answers with: the tests do not talk to GitHub.
HEAD = "6829879dcb2a0810dc49b291e2ab7c7091abf1ce"

# Today (UTC) and now: the daily cap and the cooldown are measured against
# them, so the tests cannot pin a day that is already over.
NOW = int(dt.datetime.now(dt.timezone.utc).timestamp())
TODAY = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")

# The PRs the fake `gh` knows about (the ones of the tests).
PRS = (4629, 5130)

# The issue and the pull request of the rules of the claim. They are
# FIXTURES and not real issues: a rule that names a real issue stops being
# general the day that issue is closed, and the numbers of the upstream are
# in the ten thousands.
CLAIM_ISSUE = "424242"
CLAIM_PR = "424243"

FAILS = []
MADE = []

# The temporary world of the tests (see the docstring).
ROOT = ""
LOOP_DIR = ""
BIN_DIR = ""
HOME_DIR = ""

# The `gh` of the tests: no GitHub, no network.
FAKE_GH = """#!/usr/bin/env bash
# The `gh` of the tests: the head of the PR is the HEAD of the test and the
# list of the PRs is the list of the tests. GitHub is never contacted.
case "$1 $2" in
  "pr view") printf '%s\\n' "$LOOP_TEST_PR_HEAD"; exit 0 ;;
  "pr list")
    # WHY THE --jq IS HONORED (2026-11-17): the arbitrator of the claim
    # (bin/claim-verify.sh) filters the list SERVER-SIDE, with
    # `gh pr list --jq`. A stub that ignores --jq returns the raw JSON,
    # the arbitrator parses it as if it were the filtered list, and every
    # line of the JSON becomes a false competitor. The stub has to
    # behave like the real `gh`: apply the --jq filter to the fixture.
    jq_filter=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--jq" ]; then jq_filter="$a"; fi
      case "$a" in --jq=*) jq_filter="${a#--jq=}" ;; esac
      prev="$a"
    done
    if [ -z "$jq_filter" ]; then
      printf '%s\\n' "$LOOP_TEST_PRS"; exit 0
    fi
    # The REAL jq: the program of the arbiter has a regex, strips the noise
    # of upstream and drops the references to other repositories. A stub
    # that only walks the fields would answer different questions.
    if ! command -v jq >/dev/null 2>&1; then
      echo "the stub of gh needs jq to honor --jq like the real gh" >&2
      exit 1
    fi
    printf '%s' "$LOOP_TEST_PRS" | jq -r "$jq_filter"
    exit 0
    ;;
esac
exit 1
"""

# The systemd-run of the tests: it records the scope it was asked to create
# and runs the command as if the scope had been created. The tests check the
# contract of the scope, not systemd itself.
FAKE_SYSTEMD_RUN = """#!/usr/bin/env bash
printf '%s\\n' "$@" >> "${SC_TEST_RECORD:-/dev/null}"
args=()
after=0
for a in "$@"; do
  if [ "$after" = 1 ]; then args+=("$a"); continue; fi
  if [ "$a" = "--" ]; then after=1; fi
done
if [ "${#args[@]}" -eq 0 ]; then exit 1; fi
exec "${args[@]}"
"""

# The systemd-run of the tests when the user bus is not there: it fails.
FAKE_SYSTEMD_RUN_FAIL = """#!/usr/bin/env bash
echo "Failed to connect to bus: No such file or directory" >&2
exit 1
"""

# The gate-check.sh of the tests: the verdict of a gate log, without a CI.
GATE_CHECK = """#!/usr/bin/env bash
# The gate-check.sh of the tests: the verdict of a gate log. A log without an
# EXIT= is a running gate (PENDIENTE), a log with a "failures:" block is red,
# any other finished log is green. A log without EXIT= that is older than
# GATE_TIMEOUT_MIN is DEAD (it will never say anything) and the ROTATED log
# (<log>.1) holds the verdict of the run that already finished.
log="${1:-}"
if [ ! -f "$log" ] && [ ! -f "$log.1" ]; then
  echo "GATE_STATUS=missing"
  echo "VERDICT=PENDIENTE"
  exit 0
fi
if [ ! -f "$log" ] || ! grep -qE '^EXIT=[0-9]+$' "$log"; then
  # the run that is going on has no EXIT=: the ROTATED log holds the verdict
  # of the sha when it has one.
  if [ -f "$log.1" ] && grep -qE '^EXIT=[0-9]+$' "$log.1"; then
    echo "GATE_STATUS=finished"
    if grep -qE '^failures:' "$log.1"; then
      echo "VERDICT=ROJO"
    else
      echo "VERDICT=VERDE"
    fi
    exit 0
  fi
  if [ ! -f "$log" ]; then
    echo "GATE_STATUS=missing"
    echo "VERDICT=PENDIENTE"
    exit 0
  fi
  age=$(( $(date +%s) - $(stat -c %Y "$log") ))
  if [ "$age" -gt $(( ${GATE_TIMEOUT_MIN:-90} * 60 )) ]; then
    echo "GATE_STATUS=dead"
    echo "VERDICT=PENDIENTE"
    exit 0
  fi
  echo "GATE_STATUS=running"
  echo "VERDICT=PENDIENTE"
  exit 0
fi
echo "GATE_STATUS=finished"
if grep -qE '^failures:' "$log"; then
  echo "VERDICT=ROJO"
else
  echo "VERDICT=VERDE"
fi
exit 0
"""




def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + ("" if cond else f"  <- {detail}"))
    if not cond:
        FAILS.append(name)


def make_loop_dir(root, sha, name="loop"):
    """A loop directory of the tests: its own logs, its own gate.sha and its
    own gate-check.sh. The live loop is never read."""
    loop = os.path.join(root, name)
    os.makedirs(os.path.join(loop, "logs"), exist_ok=True)
    os.makedirs(os.path.join(loop, "bin"), exist_ok=True)
    script = os.path.join(loop, "bin", "gate-check.sh")
    with open(script, "w", encoding="utf-8") as fh:
        fh.write(GATE_CHECK)
    os.chmod(script, 0o755)
    with open(os.path.join(loop, "gate.sha"), "w", encoding="utf-8") as fh:
        fh.write(sha + "\n")
    return loop


def test_env(loop_dir):
    """The environment of the tests: no GitHub, no live loop, no live HOME."""
    env = dict(os.environ)
    env["PATH"] = BIN_DIR + os.pathsep + env.get("PATH", "")
    env["LOOP_TEST_PR_HEAD"] = HEAD
    env["LOOP_TEST_PRS"] = json.dumps([
        {"number": num, "title": f"test #{num}", "isDraft": False,
         "createdAt": "2026-10-23T00:00:00Z", "mergeable": "MERGEABLE"}
        for num in PRS])
    env["LOOP_DIR"] = loop_dir
    env["HOME"] = HOME_DIR
    env["REPO"] = os.path.join(HOME_DIR, "no-repo")
    return env


def gate_log(tag, body, loop_dir=None):
    """A gate log inside the loop's logs directory (the rule) with a name that
    carries the SHA."""
    logs = os.path.join(loop_dir or LOOP_DIR, "logs")
    os.makedirs(logs, exist_ok=True)
    path = os.path.join(logs, f"gate-test-{tag}-{HEAD[:12]}.log")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    MADE.append(path)
    return path


def write_quick_verdict(loop_dir, **fields):
    """The verdict file of the quick gate (the format is the contract)."""
    path = os.path.join(loop_dir, "gate.quick.verdict")
    with open(path, "w", encoding="utf-8") as fh:
        for key, value in fields.items():
            fh.write(f"{key}={value}\n")
    MADE.append(path)
    return path


def write_merge_verdict(loop_dir, **fields):
    """The verdict file of the merge signal (the format is the contract)."""
    path = os.path.join(loop_dir, "merge.verdict")
    with open(path, "w", encoding="utf-8") as fh:
        for key, value in fields.items():
            fh.write(f"{key}={value}\n")
    MADE.append(path)
    return path


def write_scope_verdict(loop_dir, slot, **fields):
    """The verdict file of the SCOPED gate of ONE slot (the format is the
    contract with the writer of the gate: gate-quick.sh --slot)."""
    directory = os.path.join(loop_dir, "gates", str(slot))
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, "scope.verdict")
    with open(path, "w", encoding="utf-8") as fh:
        for key, value in fields.items():
            fh.write(f"{key}={value}\n")
    MADE.append(path)
    return path


def write_delta(path, payload):
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"type": "text",
                             "part": {"text": "```json\n" + json.dumps(payload) + "\n```"}}) + "\n")


def run(state, delta=None, cfg_extra="", extra_text=None, loop_dir=None,
        want_err=False, slot=""):
    """Runs state.py over a state and a delta. Returns the new state.

    With `want_err`, the stderr of the supervisor comes back too: that is
    where the refusals are said out loud, and a refusal nobody can read is a
    deadlock.

    With `slot`, the turn runs for THAT slot: the slot decides which gate
    (and which verdict file) the supervisor reads.
    """
    tmp = tempfile.mkdtemp(prefix="loop-rules-")
    try:
        sp = os.path.join(tmp, "state.json")
        lp = os.path.join(tmp, "ledger.md")
        tp = os.path.join(tmp, "turn.jsonl")
        state = dict(state)
        # the report is NEVER posted by the tests
        state["report"] = {"last": "2026-10-23", "issue": 1, "pending": False,
                           "comment_id": 0, "sig": "0:0:0"}
        with open(sp, "w", encoding="utf-8") as fh:
            json.dump(state, fh)
        if delta is not None:
            write_delta(tp, delta)
        if extra_text is not None:
            with open(tp, "a", encoding="utf-8") as fh:
                fh.write(json.dumps({"type": "text", "part": {"text": extra_text}}) + "\n")
        cfg = os.path.join(tmp, "config.env")
        with open(cfg, "w", encoding="utf-8") as fh:
            fh.write(cfg_extra)
        loop = loop_dir or LOOP_DIR
        cmd = [sys.executable, STATE_PY, "--state", sp, "--ledger", lp,
               "--turn-log", tp, "--config", cfg, "--loop-dir", loop]
        if slot:
            cmd += ["--slot", str(slot)]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180,
                              env=test_env(loop))
        with open(sp, encoding="utf-8") as fh:
            new = json.load(fh)
        if want_err:
            return new, proc.stderr
        return new
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


GREEN = "test a::b ... ok\n\nEXIT=0\n"
RUNNING = "test a::b ... ok\n\n$ cargo test\nrunning 1 test\n"
RED = "failures:\n    geom::tests::stale\n\nEXIT=1\n"


# --- the review verdict, at the level of the functions ---------------------
# These tests drive the supervisor's module with a fake state and a fake
# turn log: they need neither GitHub nor the gate nor the loop.

FAKE_SHA = "a" * 40
OTHER_SHA = "b" * 40


def load_state(path=None):
    """The supervisor's module (bin/state.py), loaded as a module.

    `LOOP_STATE_PY` points at another copy of it: that is how the tests are
    run against the code BEFORE a fix (the red of the regression).
    """
    path = path or os.environ.get("LOOP_STATE_PY", STATE_PY)
    loader = importlib.machinery.SourceFileLoader("loop_state", path)
    spec = importlib.util.spec_from_loader("loop_state", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def merge_review(st, state, delta, log, phase_before, cfg=None):
    """`merge_review` with the phase the turn started in.

    The signature before the fix does not take that phase: the tests run
    against that code too (that is the red of the regression). The same goes
    for `cfg` (the configuration of the loop, which says which upstream
    repository the PR head is read from).
    """
    try:
        params = inspect.signature(st.merge_review).parameters
    except (TypeError, ValueError):
        params = {}
    kwargs = {}
    if "phase_before" in params:
        kwargs["phase_before"] = phase_before
    if "cfg" in params:
        kwargs["cfg"] = cfg or {}
    st.merge_review(state, delta, log, [], **kwargs)


def worker_log(path, verdict="aprobar", sha=None):
    """A turn log with the review worker's call (the harness writes it)."""
    out = f"veredicto: {verdict}\n"
    if sha:
        out += f"sha revisado: {sha}\n"
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({
            "type": "tool_use",
            "part": {"state": {"status": "completed",
                               "input": {"agent": "sc-review",
                                         "description": "review the diff"},
                               "output": out}},
        }) + "\n")
    return path


def test_review_verdict():
    print("7. the verdict of the worker is a verdict about a commit")
    st = load_state()
    tmp = tempfile.mkdtemp(prefix="loop-rules-")
    try:
        log = os.path.join(tmp, "turn.jsonl")
        # the sha of the branch is the one of the worker: no git, no loop
        st.branch_sha = lambda branch: FAKE_SHA if branch else ""

        # (a) the delta path (the turn that approves and launches the gate)
        worker_log(log, sha=FAKE_SHA)
        state = {"phase": "gating", "branch": "fix/issue-1-x", "review": "",
                 "issue": 1, "branch_sha": ""}
        merge_review(st, state, {"review": "aprobado"}, log, "gating")
        check("the delta path writes a string", isinstance(state.get("review"), str),
              repr(state.get("review")))
        check("the delta path writes the verdict", state.get("review") == "aprobado",
              repr(state.get("review")))
        check("the delta path writes the sha", state.get("review_sha") == FAKE_SHA,
              repr(state.get("review_sha")))

        # (b) the implemented path (the turn the code lands in)
        state = {"phase": "implemented", "branch": "fix/issue-1-x", "review": "",
                 "issue": 1}
        merge_review(st, state, {"phase": "implemented"}, log, "claimed")
        check("the implemented path writes a string", isinstance(state.get("review"), str),
              repr(state.get("review")))
        check("the implemented path writes the verdict",
              state.get("review") == "aprobado", repr(state.get("review")))
        check("the implemented path writes the sha", state.get("review_sha") == FAKE_SHA,
              repr(state.get("review_sha")))

        # (c) the worker did not declare the sha it reviewed
        worker_log(log, sha=None)
        state = {"phase": "gating", "branch": "fix/issue-1-x", "review": "",
                 "issue": 1}
        merge_review(st, state, {"review": "aprobado"}, log, "gating")
        check("a verdict without a sha is refused", state.get("review") == "",
              repr(state.get("review")))

        # (d) there is no branch to tie the verdict to (the NameError of the
        #     turn: the delta was lost and the state was never written)
        worker_log(log, sha=FAKE_SHA)
        state = {"phase": "gating", "branch": "", "review": "", "issue": 1}
        crashed = ""
        try:
            merge_review(st, state, {"review": "aprobado"}, log, "gating")
        except Exception as exc:                      # noqa: BLE001 (the point)
            crashed = f"{type(exc).__name__}: {exc}"
        check("a verdict without a branch does not kill the turn", not crashed,
              crashed)
        check("a verdict that cannot be tied to a commit is refused",
              state.get("review") == "", repr(state.get("review")))

        # (e) the worker reviewed another commit
        worker_log(log, sha=OTHER_SHA)
        state = {"phase": "gating", "branch": "fix/issue-1-x", "review": "",
                 "issue": 1}
        merge_review(st, state, {"review": "aprobado"}, log, "gating")
        check("a verdict about another commit is refused", state.get("review") == "",
              repr(state.get("review")))

        print("8. the verdict of a worker that finished late is not lost")
        worker_log(log, sha=FAKE_SHA)
        state = {"phase": "gating", "branch": "fix/issue-1-x", "review": "",
                 "issue": 7}
        got = st.collect_review_verdict(state, log)
        check("the verdict is collected at the end of the turn",
              state.get("review") == "aprobado", repr(state.get("review")))
        check("the collected verdict keeps its sha", state.get("review_sha") == FAKE_SHA,
              repr(state.get("review_sha")))
        check("the collected verdict knows its issue", state.get("review_issue") == 7,
              repr(state.get("review_issue")))
        check("the collected verdict knows its branch",
              state.get("review_branch") == "fix/issue-1-x",
              repr(state.get("review_branch")))
        check("the collect says what it did", got == "aprobado", repr(got))

        # a verdict of the model (not of the worker) is not collected
        state = {"phase": "gating", "branch": "fix/issue-1-x", "review": "",
                 "issue": 7}
        text_log = os.path.join(tmp, "text.jsonl")
        with open(text_log, "w", encoding="utf-8") as fh:
            fh.write(json.dumps({"type": "text", "part": {"text": "veredicto: aprobar\n"}}) + "\n")
        st.collect_review_verdict(state, text_log)
        check("the orchestrator cannot approve itself at the end of the turn",
              state.get("review") == "", repr(state.get("review")))

        print("9. a publication needs a verdict about the head of the PR")
        st.pr_head_sha = lambda cfg, pr: FAKE_SHA
        st.gate_verdict = lambda log_path, loop_dir: "VERDE"
        st.gate_sha = lambda loop_dir, log_path: FAKE_SHA[:12]
        published = {"phase": "published", "pr": 4629, "review": "aprobado",
                     "review_sha": FAKE_SHA, "published": {}, "gate_verdict": "VERDE"}
        st.enforce_gate_and_publication(dict(published), {}, LOOP_DIR)
        check("a publication with a verdict about the head goes through",
              dict(published).get("phase") == "published", published.get("phase"))

        state = dict(published, review_sha="")
        st.enforce_gate_and_publication(state, {}, LOOP_DIR)
        check("a publication without a sha is refused", state.get("phase") == "gated",
              state.get("phase"))

        state = dict(published, review_sha=OTHER_SHA)
        st.enforce_gate_and_publication(state, {}, LOOP_DIR)
        check("a publication with a verdict about another commit is refused",
              state.get("phase") == "gated", state.get("phase"))

        print("10. the head of the PR is the head the verdict is tied to")
        # The branch is unknown (the state was never written) but the PR has
        # a head: the head of the PR is what is going to be published, so it
        # is the authority (the branch may not even exist yet).
        st.branch_sha = lambda branch: ""
        st.pr_head_sha = lambda cfg, pr: FAKE_SHA
        worker_log(log, sha=FAKE_SHA)
        state = {"phase": "gating", "branch": "", "review": "", "issue": 1,
                 "pr": 4629, "branch_sha": ""}
        merge_review(st, state, {"review": "aprobado"}, log, "gating")
        check("a verdict about the head of the PR is accepted",
              state.get("review") == "aprobado", repr(state.get("review")))

        # Without a PR the HEAD of the worktree of the issue is the third
        # source.
        st.pr_head_sha = lambda cfg, pr: ""
        if hasattr(st, "worktree_head_sha"):
            st.worktree_head_sha = lambda issue: FAKE_SHA
            state = {"phase": "gating", "branch": "", "review": "", "issue": 7}
            merge_review(st, state, {"review": "aprobado"}, log, "gating")
            check("a verdict about the HEAD of the worktree is accepted",
                  state.get("review") == "aprobado", repr(state.get("review")))
        else:
            check("a verdict about the HEAD of the worktree is accepted", False,
                  "the supervisor does not know the worktree of the issue")

        # Fail-closed: with no head at all the verdict is refused, and the log
        # says WHY (a refusal nobody can read is a deadlock).
        if hasattr(st, "worktree_head_sha"):
            st.worktree_head_sha = lambda issue: ""
        state = {"phase": "gating", "branch": "", "review": "", "issue": 1,
                 "pr": 4629, "branch_sha": ""}
        said = io.StringIO()
        with contextlib.redirect_stderr(said):
            merge_review(st, state, {"review": "aprobado"}, log, "gating")
        check("a verdict with no head at all is refused",
              state.get("review") == "", repr(state.get("review")))
        check("the refusal says why", "head of the PR" in said.getvalue(),
              said.getvalue().strip()[:200])

        # The publication and the verdict are tied to the SAME head: a
        # verdict accepted about the tip of the branch is published against
        # the tip of the branch.
        st.branch_sha = lambda branch: FAKE_SHA
        st.pr_head_sha = lambda cfg, pr: ""
        state = {"phase": "gated", "review": "aprobado", "review_sha": FAKE_SHA,
                 "branch": "fix/issue-1-x", "issue": 1, "pr": 4629}
        check("the verdict is compared with the head it was accepted against",
              st.review_matches_head(state, {}, 4629) is True,
              "the publication and the verdict do not agree on the head")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_triage(st=None):
    print("11. the triage of the turn is kept (a dropped issue is not triaged again)")
    st = st or load_state()
    st.branch_sha = lambda branch: ""
    tmp = tempfile.mkdtemp(prefix="loop-rules-")
    try:
        # a turn whose summary drops issue #4242
        summary = ("triage: issue #4242: soltar - the fix is upstream\n"
                   "triage: issue #4243: tomar - small and clear\n")
        st = run({"phase": "idle", "review": "", "prs": {}, "published": {},
                  "issue": 0, "skipped": []},
                 {"phase": "idle", "summary": summary})
        check("the triage of the summary is kept",
              st.get("triage", {}).get("4242", {}).get("veredicto") == "soltar",
              st.get("triage"))
        check("the reason of the triage is kept",
              st.get("triage", {}).get("4242", {}).get("motivo") == "the fix is upstream",
              st.get("triage"))
        check("a dropped issue is skipped",
              4242 in (st.get("skipped") or []), st.get("skipped"))
        check("an issue to take is not skipped",
              4243 not in (st.get("skipped") or []), st.get("skipped"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_publication_facts():
    """A publication is a FACT: the 3-hour rule does not un-publish it, an
    accepted publication is not re-evaluated, and it is counted once."""
    print("12. the 3-hour rule does not un-publish a PR")
    green2 = gate_log("g2", GREEN)
    running2 = gate_log("r2", RUNNING)

    # (a) a published PR that has been in flight for more than 3 hours is NOT
    #     degraded to 'failed': the PR is open upstream, and the publication
    #     has to be counted.
    old = {"issue": 4242, "started": NOW - 4 * 3600}
    st = run({"phase": "published", "pr": 4629, "issue": 4242, "review": "aprobado",
              "review_sha": HEAD, "gate_log": green2, "gate_verdict": "VERDE",
              "prs": {}, "published": {}, "in_flight": old},
             {"phase": "published", "pr": 4629})
    check("a published PR does not expire", st["phase"] == "published", st["phase"])
    check("the publication is counted",
          any(e.get("pr") == 4629 for e in (st.get("published", {}).get(TODAY) or [])),
          st.get("published"))
    check("the issue is done", 4242 in (st.get("done") or []), st.get("done"))

    # (a2) a SKIPPED issue is not degraded either: it was dropped on purpose.
    st = run({"phase": "skipped", "pr": 0, "issue": 4243, "review": "",
              "prs": {}, "published": {}, "skipped": [], "in_flight": old},
             {"phase": "skipped"})
    check("a skipped issue does not expire", st["phase"] == "skipped", st["phase"])
    check("the issue is still skipped", 4243 in (st.get("skipped") or []),
          st.get("skipped"))

    print("13. a publication is a fact: it is not re-evaluated")
    # (b) a publication that was already accepted is not re-evaluated: the
    #     gate of the next turn is PENDING and the phase stays 'published'.
    st = run({"phase": "published", "pr": 4629, "issue": 4242, "review": "aprobado",
              "review_sha": HEAD, "gate_log": running2, "prs": {}, "published": {},
              "published_pr": 4629, "published_sha": HEAD},
             {"phase": "published", "pr": 4629})
    check("a published PR is not re-evaluated", st["phase"] == "published", st["phase"])

    # (b2) the latch of ANOTHER PR does not protect this one: the publication
    #      of #4629 is not the publication of #5130.
    st = run({"phase": "published", "pr": 5130, "issue": 4242, "review": "aprobado",
              "review_sha": HEAD, "gate_log": running2, "prs": {}, "published": {},
              "published_pr": 4629, "published_sha": HEAD},
             {"phase": "published", "pr": 5130})
    check("the latch of another PR does not protect this one",
          st["phase"] == "gated", st["phase"])

    # (c) a force-push drops the latch: the publication was about another
    #     commit, so the PR has to be gated and reviewed again.
    st = run({"phase": "published", "pr": 4629, "issue": 4242, "review": "aprobado",
              "review_sha": HEAD, "gate_log": green2, "prs": {}, "published": {},
              "published_pr": 4629, "published_sha": OTHER_SHA},
             {"phase": "published", "pr": 4629})
    check("a force-push drops the latch (the PR is about another commit)",
          st.get("published_sha") == HEAD, st.get("published_sha"))

    # (c2) after a force-push the gate is about another commit: the PR is not
    #      published again until it is gated and reviewed again.
    stale_loop = make_loop_dir(ROOT, "1" * 40, name="loop-stale")
    stale = gate_log("s", GREEN, loop_dir=stale_loop)
    os.rename(stale, os.path.join(stale_loop, "logs", "gate-test-s-111111111111.log"))
    MADE[-1] = os.path.join(stale_loop, "logs", "gate-test-s-111111111111.log")
    st = run({"phase": "published", "pr": 4629, "issue": 4242, "review": "aprobado",
              "review_sha": HEAD, "gate_log": MADE[-1], "prs": {}, "published": {},
              "published_pr": 4629, "published_sha": OTHER_SHA},
             {"phase": "published", "pr": 4629}, loop_dir=stale_loop)
    check("a force-push drops the latch: the PR is gated again",
          st["phase"] == "gated", st["phase"])
    check("the latch of the old commit is gone", st.get("published_pr") == 0,
          st.get("published_pr"))

    # (d) the publication is counted ONCE, however many turns it lives.
    st = run({"phase": "gated", "pr": 4629, "issue": 4242, "review": "aprobado",
              "review_sha": HEAD, "gate_log": green2, "prs": {}, "published": {}},
             {"phase": "published", "pr": 4629})
    check("the publication goes through", st["phase"] == "published", st["phase"])
    entries = [e for e in (st.get("published", {}).get(TODAY) or [])
               if e.get("pr") == 4629]
    check("the PR is counted once", len(entries) == 1, st.get("published"))
    st = run(st, {"phase": "published", "pr": 4629})
    check("the publication survives the next turn", st["phase"] == "published",
          st["phase"])
    entries = [e for e in (st.get("published", {}).get(TODAY) or [])
               if e.get("pr") == 4629]
    check("the PR is still counted once", len(entries) == 1, st.get("published"))
    check("the issue is counted once", (st.get("done") or []).count(4242) == 1,
          st.get("done"))


def test_gate_dead_and_attempts():
    """A dead gate is given up, a verdict in the rotated log is not, and an
    issue that fails too many times is skipped."""
    print("14. a dead gate is given up, but a rotated verdict is not")
    # (a) a gate whose log has no EXIT= and whose ROTATED log has the green
    #     run is not dead: the sha is gated and the phase moves on.
    loop = make_loop_dir(ROOT, HEAD, name="loop-rotated")
    logs = os.path.join(loop, "logs")
    os.makedirs(logs, exist_ok=True)
    rotated = os.path.join(logs, f"gate-test-rot-{HEAD[:12]}.log")
    with open(rotated + ".1", "w", encoding="utf-8") as fh:
        fh.write(GREEN)
    with open(rotated, "w", encoding="utf-8") as fh:
        fh.write("")
    MADE.append(rotated)
    MADE.append(rotated + ".1")
    st = run({"phase": "gating", "pr": 0, "issue": 4244, "review": "",
              "gate_log": rotated, "prs": {}, "published": {}},
             {"phase": "gating"}, loop_dir=loop)
    check("a verdict in the rotated log is not a dead gate",
          st["phase"] != "failed", st["phase"])
    check("the verdict comes from the rotated log",
          st.get("gate_verdict") == "VERDE", st.get("gate_verdict"))

    # (b) a gate whose log has no EXIT=, whose mtime is older than the
    #     timeout and that has no rotated log is DEAD: it will never say
    #     anything, so the issue is given up.
    dead_loop = make_loop_dir(ROOT, HEAD, name="loop-dead")
    dead_logs = os.path.join(dead_loop, "logs")
    os.makedirs(dead_logs, exist_ok=True)
    dead = os.path.join(dead_logs, f"gate-test-dead-{HEAD[:12]}.log")
    with open(dead, "w", encoding="utf-8") as fh:
        fh.write("the gate was killed\n")
    old = dt.datetime.now(dt.timezone.utc).timestamp() - 3 * 3600
    os.utime(dead, (old, old))
    MADE.append(dead)
    st = run({"phase": "gating", "pr": 0, "issue": 4246, "review": "",
              "gate_log": dead, "prs": {}, "published": {}},
             {"phase": "gating"}, loop_dir=dead_loop)
    check("a dead gate is given up", st["phase"] == "failed", st["phase"])

    print("15. an issue that fails too many times is skipped")
    # (c) every entry in `failed` counts an attempt, and over the cap the
    #     issue is skipped: `failed` is not terminal, so without the brake the
    #     loop would give the same issue an infinite number of turns.
    st = run({"phase": "claimed", "pr": 0, "issue": 4247, "review": "",
              "prs": {}, "published": {}},
             {"phase": "failed"}, cfg_extra="MAX_ATTEMPTS_PER_ISSUE=2\n")
    check("the first failure is counted",
          (st.get("attempts") or {}).get("4247") == 1, st.get("attempts"))
    check("the issue is failed, not skipped", st["phase"] == "failed", st["phase"])
    st = run(st, {"phase": "failed"}, cfg_extra="MAX_ATTEMPTS_PER_ISSUE=2\n")
    check("the phase that stays failed is not counted twice",
          (st.get("attempts") or {}).get("4247") == 1, st.get("attempts"))
    st = run(dict(st, phase="claimed"), {"phase": "failed"},
             cfg_extra="MAX_ATTEMPTS_PER_ISSUE=2\n")
    check("the second failure is counted",
          (st.get("attempts") or {}).get("4247") == 2, st.get("attempts"))
    check("the issue is still failed", st["phase"] == "failed", st["phase"])
    st = run(dict(st, phase="claimed"), {"phase": "failed"},
             cfg_extra="MAX_ATTEMPTS_PER_ISSUE=2\n")
    check("over the cap the issue is skipped", st["phase"] == "skipped",
          st["phase"])
    check("the skipped issue is in the list", 4247 in (st.get("skipped") or []),
          st.get("skipped"))


def test_signal_verdicts():
    """The two signals of the loop (the quick gate and the merge lane) are
    exposed in the state, they are marked as obsolete when they are about
    another commit, and they never publish."""
    print("16. the verdict of the quick gate is exposed, with its sha")
    st = load_state()
    if not hasattr(st, "quick_verdict"):
        check("the supervisor exposes the verdict of the quick gate", False,
              "the supervisor does not know the quick gate")
        return
    loop = make_loop_dir(ROOT, HEAD, name="loop-signals")
    write_quick_verdict(loop, GATE_STATUS="finished", SCOPE="geom io",
                        VERDICT="VERDE-PARCIAL", NEW_FAILURES="0",
                        PUBLISHABLE="no", SHA=HEAD, AT="1700000000")
    state = {"phase": "gating", "branch": "fix/issue-1-x", "pr": 4629, "issue": 1}
    st.branch_sha = lambda branch: HEAD if branch else ""
    st.worktree_head_sha = lambda issue: ""
    quick = st.quick_verdict(loop, state)
    check("the verdict of the quick gate is exposed",
          quick.get("verdict") == "VERDE-PARCIAL", repr(quick))
    check("the verdict of the quick gate keeps its sha",
          quick.get("sha") == HEAD, repr(quick))
    check("the verdict of the quick gate keeps its moment",
          quick.get("at") == 1700000000, repr(quick))
    check("the verdict of the quick gate says that it cannot publish",
          quick.get("publishable") == "no", repr(quick))
    check("a current verdict is not obsolete", quick.get("stale") is False,
          repr(quick))

    # the quick gate ran on another commit: its verdict says nothing about
    # the code in flight, so it is obsolete.
    st.branch_sha = lambda branch: OTHER_SHA if branch else ""
    quick = st.quick_verdict(loop, state)
    check("an obsolete verdict is marked as such", quick.get("stale") is True,
          repr(quick))
    check("the reason of the obsolete verdict says why",
          "obsolete" in str(quick.get("reason", "")), repr(quick.get("reason")))

    # a quick gate that has not written its verdict yet
    quiet = make_loop_dir(ROOT, HEAD, name="loop-nosignal")
    quick = st.quick_verdict(quiet, state)
    check("a missing verdict is not a green one", quick.get("verdict") == "",
          repr(quick))
    check("a missing verdict says why it cannot be used",
          bool(quick.get("reason")), repr(quick))

    print("17. the signal of the merge is exposed, with its sha")
    write_merge_verdict(loop, MERGE_VERDICT="VERDE", MERGE_SHA=HEAD,
                        MERGE_JOBS="Quick compile,Format and repository checks",
                        MERGE_PR=4629, AT="1700000001")
    st.pr_head_sha = lambda cfg, pr: HEAD
    merge = st.merge_verdict(loop, {}, state)
    check("the signal of the merge is exposed",
          merge.get("verdict") == "VERDE", repr(merge))
    check("the signal of the merge keeps its sha",
          merge.get("sha") == HEAD, repr(merge))
    check("the signal of the merge keeps its moment",
          merge.get("at") == 1700000001, repr(merge))
    check("the signal of the merge is current", merge.get("stale") is False,
          repr(merge))
    # the signal is about another commit: it says nothing about the PR in
    # flight.
    st.pr_head_sha = lambda cfg, pr: OTHER_SHA
    merge = st.merge_verdict(loop, {}, state)
    check("an obsolete signal is marked as such", merge.get("stale") is True,
          repr(merge))
    check("the reason of the obsolete signal says why",
          "obsolete" in str(merge.get("reason", "")), repr(merge.get("reason")))

    print("18. a partial verdict does not publish")
    # The complete gate is RED and the only green thing is the quick gate:
    # the publication is refused, and the refusal says why.
    red = gate_log("q", RED, loop_dir=loop)
    published, err = run({"phase": "gated", "gate_log": red, "review": "aprobado",
                          "review_sha": HEAD, "prs": {}, "published": {},
                          "pr": 4629, "issue": 1, "branch": "fix/issue-1-x"},
                         {"phase": "published", "pr": 4629},
                         loop_dir=loop, want_err=True)
    check("a VERDE-PARCIAL does not publish", published["phase"] == "gated",
          published["phase"])
    check("the refusal says that a partial verdict does not publish",
          "VERDE-PARCIAL" in err and "does not publish" in err, err[-400:])

    # The same state with a GREEN complete gate: the publication goes
    # through. A partial verdict does not block what the complete gate
    # decides.
    green = gate_log("g", GREEN, loop_dir=loop)
    published, err = run({"phase": "gated", "gate_log": green, "review": "aprobado",
                          "review_sha": HEAD, "prs": {}, "published": {},
                          "pr": 4629, "issue": 1, "branch": "fix/issue-1-x"},
                         {"phase": "published", "pr": 4629},
                         loop_dir=loop, want_err=True)
    check("a green complete gate still publishes with a signal around",
          published["phase"] == "published", published["phase"])

    # Only the merge signal is green: the publication is refused and the
    # refusal names the signal.
    merge_loop = make_loop_dir(ROOT, HEAD, name="loop-merge-only")
    write_merge_verdict(merge_loop, MERGE_VERDICT="VERDE", MERGE_SHA=HEAD,
                         MERGE_JOBS="Quick compile", MERGE_PR=4629,
                         AT="1700000001")
    red2 = gate_log("q2", RED, loop_dir=merge_loop)
    published, err = run({"phase": "gated", "gate_log": red2, "review": "aprobado",
                          "review_sha": HEAD, "prs": {}, "published": {},
                          "pr": 4629, "issue": 1, "branch": "fix/issue-1-x"},
                         {"phase": "published", "pr": 4629},
                         loop_dir=merge_loop, want_err=True)
    check("the merge signal alone does not publish",
          published["phase"] == "gated", published["phase"])
    check("the refusal names the merge signal", "merge signal is VERDE" in err,
          err[-400:])


def test_scoped_gate():
    """The SCOPED gate is an authorisation: it publishes when it is green
    about the head of the PR, and it is refused when it is not."""
    print("19. the scoped gate publishes")
    loop = make_loop_dir(ROOT, HEAD, name="loop-scope")
    green_scope = {
        "GATE_STATUS": "finished",
        "SCOPE": "geom io",
        "SCOPE_KIND": "packages",
        "VERDICT": "VERDE-SCOPE",
        "NEW_FAILURES": "0",
        "FAILED_TESTS": "",
        "CHECKS": "fmt:ok|layers:ok|clippy:ok",
        "SHA": HEAD,
        "AT": "1700000002",
    }
    state = {"phase": "gated", "gate_log": "", "review": "aprobado",
             "review_sha": HEAD, "prs": {}, "published": {}, "pr": 4629,
             "issue": 1, "branch": "fix/issue-1-x"}
    delta = {"phase": "published", "pr": 4629}

    def scope(**fields):
        """The verdict of the scoped gate of the slot 0."""
        values = dict(green_scope)
        values.update(fields)
        return write_scope_verdict(loop, "0", **values)

    # (1) a green scoped verdict about the head of the PR publishes.
    scope()
    published, err = run(dict(state), delta, loop_dir=loop, want_err=True)
    check("a green scoped gate publishes", published["phase"] == "published",
          published["phase"] + " | " + err[-400:])

    # (2) a scoped verdict about ANOTHER commit does not publish.
    scope(SHA="0" * 40)
    published, err = run(dict(state), delta, loop_dir=loop, want_err=True)
    check("a stale scoped verdict does not publish",
          published["phase"] == "gated", published["phase"])
    check("the refusal says that the verdict is stale", "stale" in err,
          err[-400:])

    # (3) a red scoped verdict does not publish.
    scope(VERDICT="ROJO-SCOPE", NEW_FAILURES="2",
          FAILED_TESTS="geom::tests::stale")
    published, err = run(dict(state), delta, loop_dir=loop, want_err=True)
    check("a ROJO-SCOPE does not publish", published["phase"] == "gated",
          published["phase"])

    # (4) a check that did NOT run is not a green gate.
    scope(CHECKS="fmt:ok|layers:ok|clippy:skipped")
    published, err = run(dict(state), delta, loop_dir=loop, want_err=True)
    check("a scoped gate with a skipped clippy does not publish",
          published["phase"] == "gated", published["phase"])

    # (5) the scope of the whole workspace needs the COMPLETE gate.
    scope(SCOPE_KIND="full", SCOPE="workspace", VERDICT="SKIP",
          CHECKS="fmt:skipped|layers:skipped|clippy:skipped")
    published, err = run(dict(state), delta, loop_dir=loop, want_err=True)
    check("a scoped gate of the whole workspace does not publish",
          published["phase"] == "gated", published["phase"])

    # (6) without a scoped verdict the COMPLETE gate is required, as today.
    os.remove(os.path.join(loop, "gates", "0", "scope.verdict"))
    published, err = run(dict(state), delta, loop_dir=loop, want_err=True)
    check("without a scoped verdict the publication is refused",
          published["phase"] == "gated", published["phase"])
    check("the refusal says that the complete gate is required",
          "COMPLETE gate" in err and "VERDE-SCOPE" in err, err[-400:])

    # (7) the COMPLETE gate still publishes: it is not replaced, it is
    #     complemented.
    green = gate_log("scope-green", GREEN, loop_dir=loop)
    published, err = run(dict(state, gate_log=green), delta, loop_dir=loop,
                         want_err=True)
    check("the complete gate still publishes",
          published["phase"] == "published", published["phase"])

    # (8) the verdict of a slot never reaches another slot.
    write_scope_verdict(loop, "1", **green_scope)
    published, err = run(dict(state), delta, loop_dir=loop, want_err=True)
    check("the scoped verdict of another slot does not publish",
          published["phase"] == "gated", published["phase"])
    # ... and the slot that owns it does publish with it.
    two = {"version": 2, "prs": {}, "published": {},
           "slots": {"1": {"phase": "gated", "gate_log": "", "review": "aprobado",
                           "review_sha": HEAD, "pr": 4629, "issue": 1,
                           "branch": "fix/issue-1-x"}}}
    published, err = run(two, delta, loop_dir=loop, want_err=True, slot="1")
    slot_one = (published.get("slots") or {}).get("1") or {}
    check("the scoped verdict of its own slot publishes",
          slot_one.get("phase") == "published", repr(slot_one.get("phase")))

    # (9) a green scoped verdict moves `gating` to `gated` on its own.
    scope()
    published, err = run({"phase": "gating", "gate_log": "", "review": "",
                          "prs": {}, "published": {}, "pr": 4629,
                          "issue": 1, "branch": "fix/issue-1-x"},
                         {"phase": "gating"}, loop_dir=loop, want_err=True)
    check("a green scoped gate moves gating -> gated",
          published["phase"] == "gated", published["phase"])
    check("the verdict of the scoped gate is in the state",
          published.get("scope_verdict") == "VERDE-SCOPE",
          repr(published.get("scope_verdict")))
    check("the scope of the scoped gate is in the state",
          published.get("scope_packages") == "geom io",
          repr(published.get("scope_packages")))
    check("the sha of the scoped gate is in the state",
          published.get("scope_sha") == HEAD,
          repr(published.get("scope_sha")))


def test_scoped_gate_budget():
    """The scoped gate gets the time that is LEFT in the turn.

    A gate that systemd kills when the turn ends leaves no verdict, and a
    turn without a verdict is a lost turn. So the supervisor gives the gate
    the time that is left (less the two minutes that systemd needs to tear
    the unit down), bounded by a floor (below it the nextest phase cannot
    finish) and by a ceiling (the gate does not need more than that).
    """
    print("20. the scoped gate gets the time that is left in the turn")
    supervisor = os.path.join(LOOP, "bin", "supervisor.sh")
    gate = os.path.join(LOOP, "bin", "gate-quick.sh")
    with open(supervisor, encoding="utf-8") as fh:
        src = fh.read()
    with open(gate, encoding="utf-8") as fh:
        gate_src = fh.read()

    check("the launch gives the gate the budget of the run",
          'GATE_QUICK_TIMEOUT_MIN="$budget"' in src,
          "the launch does not pass the budget to the gate")
    check("the gate is not launched with less than the floor",
          "${GATE_QUICK_MIN_MIN:-12} + 2" in src,
          "the guard does not use the floor")

    # The rule is executable: the supervisor answers how much time the gate
    # would get with N minutes left in the turn. The test asks the script, it
    # does not read its source.
    def budget(left):
        env = dict(os.environ)
        env["LOOP_DIR"] = LOOP
        out = subprocess.run(["bash", supervisor, "--gate-budget", str(left)],
                             capture_output=True, text=True, env=env, timeout=60)
        return out.stdout.strip()

    ceiling = 0
    floor = 0
    with open(os.path.join(LOOP, "config.env"), encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("GATE_QUICK_TIMEOUT_MIN="):
                ceiling = int(line.split("=", 1)[1].split("#")[0].strip())
            elif line.startswith("GATE_QUICK_MIN_MIN="):
                floor = int(line.split("=", 1)[1].split("#")[0].strip())
    check("the config.env says what the ceiling and the floor are",
          ceiling > 0 and floor > 0 and floor < ceiling,
          f"ceiling={ceiling} floor={floor}")

    check("the budget is the time that is left in the turn",
          budget(20) == "18", f"20 min left -> {budget(20)!r}")
    check("the budget never goes over the ceiling",
          budget(90) == str(ceiling), f"90 min left -> {budget(90)!r}")
    check("the budget never goes under the floor",
          budget(5) == str(floor), f"5 min left -> {budget(5)!r}")
    check("the budget is the ceiling when the turn is long",
          budget(ceiling + 2) == str(ceiling),
          f"{ceiling + 2} min left -> {budget(ceiling + 2)!r}")
    check("the budget is the floor when the turn is short",
          budget(floor + 2) == str(floor),
          f"{floor + 2} min left -> {budget(floor + 2)!r}")

    # The gate takes the budget from the environment, and a budget that is
    # not a number is the ceiling (never zero: a gate with no budget does
    # not check anything and says nothing).
    env = dict(os.environ)
    env["GATE_QUICK_TIMEOUT_MIN"] = "not-a-number"
    env["LOOP_DIR"] = os.path.join(ROOT, "loop-budget")
    out = subprocess.run(["bash", gate, "--help"], capture_output=True,
                         text=True, env=env, timeout=60)
    check("the gate reads its budget from the environment",
          out.returncode == 0, out.stderr[-300:])

    # The defaults of the gate and the ones of the config.env are the same
    # number: a gate that runs with a different budget than the one the
    # supervisor thinks it has is a gate that is killed.
    with open(gate, encoding="utf-8") as fh:
        gate_src = fh.read()
    check("the ceiling of the gate is the one of the config.env",
          ceiling and f'GATE_QUICK_TIMEOUT_MIN:-{ceiling}' in gate_src,
          f"config.env says {ceiling!r} and the gate says {ceiling!r}?")


def test_scoped_gate_cgroup():
    """The scoped gate wears a cgroup belt, and the belt fails open.

    The supervisor launches the scoped gate in the FOREGROUND, so it
    inherits the cgroup of the loop service, whose memory.high and
    memory.max are both `max`: a heavy test can take the whole host and the
    global OOM killer may kill the brain of the turn instead of the test.
    The belt is a transient systemd scope with the memory, CPU, IO and task
    limits, and the scoped gate gets its own cargo target dir so it stops
    filling the target dir of the interactive sessions.
    The scope lives in the LOOP'S OWN slice: a scope with a CPU weight in
    app.slice turns the cpu controller on for that subtree and the complete
    gate (the critical path of the loop) becomes a third peer of it.
    The belt must NEVER be the reason the gate fails: if the scope cannot
    be created, the gate runs without it and says so.
    """
    print("21. the scoped gate has a cgroup belt that fails open")
    gate = os.path.join(LOOP, "bin", "gate-quick.sh")
    cfg = os.path.join(LOOP, "config.env")
    with open(gate, encoding="utf-8") as fh:
        gate_src = fh.read()
    with open(cfg, encoding="utf-8") as fh:
        cfg_src = fh.read()

    expected = {
        "GATE_QUICK_TARGET_DIR": "/home/user/solidcraft-gate-quick/target",
        # MEASURED (01-11-2026): the peak of a gate is 23.7 GB, and TWO gates
        # at the same time have to fit in the 62 GB of the box: 2 x 26G of
        # high and 2 x 23.7G of real peak leave 14.6 GB of margin. With the
        # old 32G/40G a second gate would have asked for 64 GB of demand on
        # 62 of RAM and the OOM killer would have taken a test binary, which
        # reads as a RED gate.
        "GATE_QUICK_MEMORY_HIGH": "26G",
        "GATE_QUICK_MEMORY_MAX": "32G",
        "GATE_QUICK_CPU_WEIGHT": "100",
        "GATE_QUICK_IO_WEIGHT": "50",
        "GATE_QUICK_SLICE": "app-solidcraft\\x2dloop.slice",
        "GATE_QUICK_TASKS_MAX": "4096",
        "GATE_QUICK_OOM_POLICY": "kill",
        "GATE_QUICK_CGROUP": "1",
        "GATE_QUICK_RUNTIME_GRACE": "120",
        # The mitigation of the auto-sabotage (27-10-2026): the wait of
        # the lock of the build directory, the grace of the debris of the
        # scopes and the root of the cgroups.
        "GATE_SCOPE_LOCK_WAIT": "0",
        "GATE_SCOPE_CLEAN_GRACE": "120",
        "GATE_CGROUP_ROOT": "/sys/fs/cgroup",
    }

    # The config.env declares the belt.
    declared = {}
    for line in cfg_src.splitlines():
        body = line.split("#", 1)[0].strip()
        if "=" in body:
            key, _, value = body.partition("=")
            declared[key.strip()] = value.strip().strip('"').strip("'")
    missing = sorted(k for k in expected if k not in declared)
    wrong = {k: declared[k] for k in expected
             if k in declared and declared[k] != expected[k]}
    check("the config.env declares the belt of the scoped gate",
          not missing and not wrong, f"missing={missing} wrong={wrong}")

    # The defaults of the gate and the ones of the config.env are the same
    # numbers: a gate that runs with a different belt than the operator
    # thinks it has is a gate with no belt.
    def default_of(key, value):
        if f"${{{key}:-{value}}}" in gate_src:
            return True
        # The default of a variable that can also be EMPTY is written without
        # the colon (${VAR-default}): an empty value means "no slice at all".
        if f"${{{key}-{value}}}" in gate_src:
            return True
        home = value.replace("/home/user", "$HOME", 1)
        return home != value and f"${{{key}:-{home}}}" in gate_src

    bad = sorted(k for k, v in expected.items() if not default_of(k, v))
    check("the gate's defaults are the ones of the config.env",
          not bad, f"the gate does not default {bad} to the configured value")

    check("the belt is a transient systemd scope of the user",
          "systemd-run" in gate_src and "--scope" in gate_src
          and "--user" in gate_src,
          "the gate does not build a systemd scope")
    for prop in ("MemoryHigh", "MemoryMax", "CPUWeight", "IOWeight",
                 "TasksMax", "OOMPolicy", "MemorySwapMax"):
        check(f"the scope of the scoped gate sets {prop}",
              prop in gate_src, f"the gate never sets {prop}")

    # --- the scope that is asked for (a fake systemd-run) ---------------
    fake_dir = os.path.join(ROOT, "fake-systemd")
    os.makedirs(fake_dir, exist_ok=True)
    record = os.path.join(ROOT, "systemd-run.argv")
    fake = os.path.join(fake_dir, "systemd-run")
    with open(fake, "w", encoding="utf-8") as fh:
        fh.write(FAKE_SYSTEMD_RUN)
    os.chmod(fake, 0o755)

    def probe(env_extra=None, path=None, timeout=180):
        env = dict(os.environ)
        env["LOOP_DIR"] = LOOP
        env["SC_TEST_RECORD"] = record
        if path:
            env["PATH"] = path + os.pathsep + env.get("PATH", "")
        if env_extra:
            env.update(env_extra)
        return subprocess.run(["bash", gate, "--scope-probe"],
                              capture_output=True, text=True, env=env,
                              timeout=timeout)

    def probe_values(out):
        vals = {}
        for line in out.splitlines():
            body = line.strip()
            if "=" not in body:
                continue
            key, _, value = body.partition("=")
            key = key.strip().lower().replace(" ", "")
            if key.startswith("scope-probe:"):
                key = key[len("scope-probe:"):]
            vals[key] = value.strip()
        return vals

    def value_of(vals, name):
        for cand in (name, name.replace(".", "_"), name.replace(".", "")):
            if cand in vals:
                return vals[cand]
        return None

    if os.path.exists(record):
        os.unlink(record)
    out = probe({"GATE_QUICK_MEMORY_HIGH": "1G",
                 "GATE_QUICK_MEMORY_MAX": "2G"}, fake_dir)
    argv = []
    if os.path.exists(record):
        with open(record, encoding="utf-8") as fh:
            argv = fh.read().split("\n")
    asked = "\n".join(argv)
    check("the scope is asked for with the configured limits",
          "MemoryHigh=1G" in asked and "MemoryMax=2G" in asked
          and "CPUWeight=100" in asked and "IOWeight=50" in asked
          and "TasksMax=4096" in asked and "OOMPolicy=kill" in asked
          and "MemorySwapMax=0" in asked,
          f"systemd-run was asked for {asked!r}")
    check("the scope is asked for in the slice of the loop",
          "--slice=app-solidcraft\\x2dloop.slice" in argv,
          f"the scope was not asked for the slice of the loop: {argv!r}")
    check("the scope is a user scope that lives in its own unit",
          "--user" in argv and "--scope" in argv
          and any(a.startswith("--unit=") for a in argv),
          f"systemd-run was asked for {argv!r}")

    # --- the belt disabled ---------------------------------------------
    if os.path.exists(record):
        os.unlink(record)
    out = probe({"GATE_QUICK_CGROUP": "0"}, fake_dir)
    said = (out.stdout + out.stderr).lower()
    check("with the belt disabled no scope is created",
          not os.path.exists(record),
          "the gate asked for a scope with GATE_QUICK_CGROUP=0")
    check("with the belt disabled the gate says so",
          "disable" in said, said[-300:])
    check("with the belt disabled the probe says the belt is not there",
          out.returncode == 1, f"rc={out.returncode} {out.stderr[-200:]}")

    # --- a scope that cannot be created (the belt fails open) -----------
    fail_dir = os.path.join(ROOT, "fake-systemd-fail")
    os.makedirs(fail_dir, exist_ok=True)
    fail_calls = os.path.join(ROOT, "systemd-run.calls")
    with open(os.path.join(fail_dir, "systemd-run"), "w", encoding="utf-8") as fh:
        fh.write(FAKE_SYSTEMD_RUN_FAIL.replace(
            'exit 1',
            'echo call >> "${SC_TEST_RECORD:-/dev/null}"\nexit 1'))
    os.chmod(os.path.join(fail_dir, "systemd-run"), 0o755)
    if os.path.exists(fail_calls):
        os.unlink(fail_calls)
    out = probe(path=fail_dir)
    said = (out.stdout + out.stderr).lower()
    check("a scope that cannot be created is reported",
          "belt" in said or "scope" in said, said[-300:])
    check("a scope that cannot be created does not pretend to be there",
          "memory.high=" not in out.stdout, out.stdout[-300:])
    check("a scope that cannot be created says the belt is not there",
          out.returncode == 1, f"rc={out.returncode} {out.stderr[-200:]}")
    calls = 0
    if os.path.exists(fail_calls):
        with open(fail_calls, encoding="utf-8") as fh:
            calls = len([l for l in fh.read().split("\n") if l.strip()])
    check("a scope that cannot be created is tried once, not in a loop",
          calls <= 1, f"systemd-run was tried {calls} times")

    # --- the GATE: the belt is a belt, not a judge ----------------------
    # The same gate, with the belt and without it, gives the same verdict:
    # the belt bounds the run, it never decides anything. The gate runs
    # here against a repository that is NOT a git one: the diff fails at
    # once, so the gate gives its verdict in a second and compiles NOTHING.
    gate_loop = os.path.join(ROOT, "gate-loop")
    fake_repo = os.path.join(ROOT, "fake-repo")
    os.makedirs(gate_loop, exist_ok=True)
    os.makedirs(fake_repo, exist_ok=True)
    verdict_file = os.path.join(gate_loop, "gates", "belt", "scope.verdict")

    def run_gate(env_extra=None, path=None):
        env = dict(os.environ)
        env["REPO"] = fake_repo
        env["LOOP_DIR"] = gate_loop
        if path:
            env["PATH"] = path + os.pathsep + env.get("PATH", "")
        if env_extra:
            env.update(env_extra)
        return subprocess.run(
            ["bash", gate, "--slot", "belt", "origin/main", "deadbeef1234"],
            capture_output=True, text=True, env=env, timeout=300)

    def read_verdict():
        if not os.path.exists(verdict_file):
            return ""
        with open(verdict_file, encoding="utf-8") as fh:
            return "\n".join(l for l in fh.read().splitlines()
                             if not l.startswith("AT="))

    plain = run_gate({"GATE_QUICK_CGROUP": "0"})
    plain_verdict = read_verdict()
    check("the gate without the belt gives its verdict",
          plain.returncode == 0 and "VERDICT=" in plain_verdict,
          f"rc={plain.returncode} {plain.stderr[-200:]}")

    broken = run_gate(path=fail_dir)
    check("a gate whose scope cannot be created does not fail",
          broken.returncode == plain.returncode,
          f"rc={broken.returncode} without the belt rc={plain.returncode}")
    check("a gate whose scope cannot be created says so",
          "no belt" in (broken.stdout + broken.stderr).lower(),
          (broken.stdout + broken.stderr)[-300:])
    check("a gate whose scope cannot be created gives the same verdict",
          read_verdict() == plain_verdict,
          f"{read_verdict()!r} != {plain_verdict!r}")

    scoped = run_gate()
    check("the gate with the belt gives the same verdict as without it",
          scoped.returncode == 0 and read_verdict() == plain_verdict,
          f"rc={scoped.returncode} {read_verdict()!r} != {plain_verdict!r}")

    # --- the real scope (when this host has a user bus) -----------------
    if shutil.which("systemd-run"):
        out = probe({"GATE_QUICK_MEMORY_HIGH": "1G",
                     "GATE_QUICK_MEMORY_MAX": "2G"})
        vals = probe_values(out.stdout)
        high = value_of(vals, "memory.high")
        if high is not None:
            check("the scope that runs the gate has the configured memory.high",
                  high == "1073741824", f"memory.high={high!r}")
            check("the scope that runs the gate has the configured memory.max",
                  value_of(vals, "memory.max") == "2147483648",
                  f"memory.max={value_of(vals, 'memory.max')!r}")
            check("the probe of the belt succeeds when the scope is there",
                  out.returncode == 0,
                  f"rc={out.returncode} {out.stderr[-300:]}")
        else:
            # Without a user bus there is no belt: the probe says so and
            # does not lie about the limits.
            said = (out.stdout + out.stderr).lower()
            check("without a user bus the probe says the belt is not there",
                  out.returncode != 0 and "belt" in said,
                  f"rc={out.returncode} {said[-300:]}")


def test_scoped_gate_gpu_stack():
    """The scoped gate runs the tests with the GPU stack of the complete gate.

    The scoped gate asks for a SOFTWARE adapter and it REQUIRES it: a test that
    would skip for want of an adapter fails instead of passing by accident.
    The ICD of lavapipe names its library RELATIVELY ("libvulkan_lvp.so"), so
    the loader resolves it through LD_LIBRARY_PATH: when that directory was
    missing there was no adapter at all and the tests of `ui-egui` died with
    the panic "no GPU adapter qualifies under the software policy". That red
    was STRUCTURAL: it made every change that touches `solidcraft-ui-egui`
    look broken and left the complete gate (2 h 50 min) as the only way to a
    green verdict.

    The rule is EXECUTABLE: the test evaluates the environment that the gate
    builds, in a bash that mimics the environment of the unit (the libraries of
    Chrome and NO lavapipe: that is exactly the state that broke the gate), and
    checks that the driver of the ICD resolves in it.
    """
    print("25. the scoped gate runs the tests with the GPU stack of the complete gate")
    gate = os.path.join(LOOP, "bin", "gate-quick.sh")
    with open(gate, encoding="utf-8") as fh:
        gate_src = fh.read()

    # (1) The environment of the GPU is declared and EXPORTED: the scope of
    #     the run is a child process of the gate and it needs it too.
    for needed in ("GPU_X_LD=", "GPU_DISPLAY=", "GPU_ICD=",
                   "export LD_LIBRARY_PATH", "export DISPLAY",
                   "export VK_ICD_FILENAMES"):
        check("the gate declares %s" % needed, needed in gate_src)

    # (2) The policy is NOT relaxed: the tests keep asking for the software
    #     adapter and they keep requiring it.
    check("the tests of the scoped gate still require a software adapter",
          "SOLIDCRAFT_GPU=software" in gate_src
          and "SOLIDCRAFT_REQUIRE_GPU=1" in gate_src)

    # (3) The environment that the gate builds: the driver of the ICD has to
    #     resolve in it.
    x_ld = "/home/user/.local/x/usr/lib/x86_64-linux-gnu"
    icd = "/home/user/.local/x/usr/share/vulkan/icd.d/lvp_icd.json"
    try:
        start = gate_src.index("GPU_X_LD=")
        end = gate_src.index("\nfi\n", start) + len("\nfi\n")
    except ValueError:
        check("the block of the GPU stack of the gate is there", False,
              "the gate has no GPU_X_LD block")
        return
    block = gate_src[start:end]

    fd, block_file = tempfile.mkstemp(prefix="gate-gpu-", suffix=".sh")
    os.close(fd)
    with io.open(block_file, "w", encoding="utf-8") as fh:
        fh.write(block)

    probe = """
set -uo pipefail
. "$1"
printf 'LD=%s\\n' "$LD_LIBRARY_PATH"
printf 'DISPLAY=%s\\n' "$DISPLAY"
printf 'ICD=%s\\n' "$VK_ICD_FILENAMES"
lib="$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$VK_ICD_FILENAMES" | head -1)"
printf 'DRIVER=%s\\n' "$lib"
found=0
IFS=':' read -r -a dirs <<< "$LD_LIBRARY_PATH"
for d in "${dirs[@]}"; do
  [ -n "$d" ] || continue
  if [ -r "$d/$lib" ]; then found=1; break; fi
done
printf 'FOUND=%s\\n' "$found"
"""
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", "/home/user"),
        # The LD of the unit: the libraries of Chrome and the XKB data. The
        # directory of lavapipe is NOT there: that is the state that broke it.
        "LD_LIBRARY_PATH": "/home/user/.local/chrome-deps/usr/lib/x86_64-linux-gnu:"
                           "/home/user/.local/x/usr/share/X11/xkb",
        "X_LD": x_ld,
        "DISPLAY": ":99",
        "VK_ICD_FILENAMES": icd,
    }
    try:
        out = subprocess.run(["bash", "-c", probe, "_", block_file], env=env,
                             capture_output=True, text=True, timeout=60)
    finally:
        os.unlink(block_file)
    text = out.stdout
    check("the environment of the gate is built without an error",
          out.returncode == 0, out.stderr[-300:])
    check("the LD of the gate has the directory of lavapipe",
          ("LD=" in text and x_ld in text.split("LD=", 1)[1].split("\n", 1)[0]),
          text[:300])
    check("the ICD of lavapipe is the one of the gate",
          ("ICD=" + icd) in text, text[:300])
    check("the driver of the ICD resolves in the LD of the gate",
          "FOUND=1" in text, text[:400])

    # (4) The real thing, when the binary is there: the CLI of the repo has to
    #     find a software adapter with that environment.
    cli = "/home/user/solidcraft/target/ci/solidcraft-cli"
    if not os.path.exists(cli):
        check("the CLI of the repo is not built here: the adapter is not checked",
              True, cli)
        return
    gpu_env = dict(env)
    gpu_env["SOLIDCRAFT_GPU"] = "software"
    gpu_env["SOLIDCRAFT_REQUIRE_GPU"] = "1"
    gpu_env["LD_LIBRARY_PATH"] = text.split("LD=", 1)[1].split("\n", 1)[0]
    try:
        gpu = subprocess.run([cli, "gpu"], env=gpu_env, capture_output=True,
                             text=True, timeout=180)
    except subprocess.TimeoutExpired:
        check("the CLI of the repo answers about the adapters", False, "timeout")
        return
    check("the CLI finds a software adapter with the environment of the gate",
          '"tier": "software"' in gpu.stdout,
          (gpu.stdout[-300:] + " " + gpu.stderr[-300:]))


def test_agent_preflight():
    """The turn does not start when the agent does not resolve.

    An agent FILE that exists is not an agent that opencode RESOLVES: the
    V2 schema of opencode asks every permission rule for the three fields
    (`action`, `resource`, `effect`), and an agent with a rule without
    `resource` is not registered. opencode then answers "Agent not found:
    sc-orchestrator", the turn dies before its first step, and the loop
    loses the turns without saying why: on the 26-10 that was 137 turns and
    2 h 55 min of a loop that did nothing at all.

    The supervisor asks the checker before every turn. The rule is
    EXECUTABLE: the test asks the script, it does not read its source.
    """
    print("21. the turn does not start with an agent that does not resolve")
    supervisor = os.path.join(LOOP, "bin", "supervisor.sh")
    checker = os.path.join(LOOP, "bin", "check-agents.sh")
    loop = os.path.join(ROOT, "loop-preflight")
    os.makedirs(os.path.join(loop, "bin"), exist_ok=True)

    def preflight(body=None):
        """The query of the supervisor, with its own checker."""
        script = os.path.join(loop, "bin", "check-agents.sh")
        if body is None:
            if os.path.exists(script):
                os.unlink(script)
        else:
            with open(script, "w", encoding="utf-8") as fh:
                fh.write(body)
            os.chmod(script, 0o755)
        env = dict(os.environ)
        env["LOOP_DIR"] = loop
        return subprocess.run(["bash", supervisor, "--preflight", "sc-orchestrator"],
                              capture_output=True, text=True, env=env, timeout=120)

    out = preflight("#!/usr/bin/env bash\necho 'OK sc-orchestrator'\nexit 0\n")
    check("the preflight passes with an agent that resolves",
          out.returncode == 0, out.stdout[-300:] + out.stderr[-300:])

    out = preflight("#!/usr/bin/env bash\n"
                    "echo 'OPENCODE NO RESUELVE sc-orchestrator: Agent not found'\n"
                    "exit 1\n")
    check("the preflight fails with an agent that does not resolve",
          out.returncode == 1, out.stdout[-300:])
    check("the preflight says what is wrong",
          "does not resolve" in out.stdout, out.stdout[-300:])

    # It FAILS OPEN: a checker that is not there does not block the loop.
    # The loop must not die because a helper is missing.
    out = preflight(None)
    check("a checker that is not there does not block the loop",
          out.returncode == 0, out.stdout[-300:] + out.stderr[-300:])

    # The checker probes ONE agent in the mode `only:`: the probe of the
    # eight agents is eight processes of opencode, too much for every turn
    # and enough for a doctor.
    fake = os.path.join(BIN_DIR, "opencode-fake")
    probe_log = os.path.join(ROOT, "opencode-probe.log")
    with open(fake, "w", encoding="utf-8") as fh:
        fh.write("#!/usr/bin/env bash\n"
                 "printf '%s\\n' \"$*\" >> \"$FAKE_OPENCODE_LOG\"\n"
                 "echo 'Model unavailable'\n")
    os.chmod(fake, 0o755)
    env = dict(os.environ)
    env["OPENCODE_BIN"] = fake
    env["AGENT_DIR"] = agents_dir()
    env["FAKE_OPENCODE_LOG"] = probe_log

    def probe(resolve):
        if os.path.exists(probe_log):
            os.unlink(probe_log)
        e = dict(env)
        if resolve:
            e["CHECK_AGENTS_RESOLVE"] = resolve
        else:
            e.pop("CHECK_AGENTS_RESOLVE", None)
        out = subprocess.run(["bash", checker], capture_output=True, text=True,
                             env=e, timeout=120)
        probes = []
        if os.path.exists(probe_log):
            with open(probe_log, encoding="utf-8") as fh:
                probes = [line.strip() for line in fh if line.strip()]
        return out, probes

    out, probes = probe("only:sc-orchestrator")
    check("the checker in the mode only: answers OK for the agent that resolves",
          out.returncode == 0, out.stdout[-300:] + out.stderr[-300:])
    check("the mode only: probes ONE agent",
          len(probes) == 1, f"{len(probes)} probe(s): {probes}")
    check("the mode only: probes the agent that was asked for",
          probes and "--agent sc-orchestrator" in probes[0],
          probes[0] if probes else "no probe")

    out, probes = probe(None)
    check("the full mode probes every agent",
          len(probes) == 8, f"{len(probes)} probe(s)")


def agents_dir():
    """Where the agent files are.

    The repo carries them (`agents/`), but the RUNTIME does not: opencode
    loads the agents from `~/.config/opencode/agents` and the loop dir only
    holds the scripts. The groups run in both places, so they ask here.

    The HOME of the test is a fake one (the groups must not touch the real
    config), so the directory of the agents of the user is the fallback:
    the agents are only READ, never written.
    """
    candidate = os.path.join(LOOP, "agents")
    if os.path.isdir(candidate):
        return candidate
    real = "/home/user/.config/opencode/agents"
    if os.path.isdir(real):
        return real
    return os.path.join(os.environ.get("HOME", "/home/user"),
                        ".config", "opencode", "agents")


def test_prompt_reads():
    """The reads that the prompt recommends have to be runnable.

    A denial is a step: the model asks for `tail -n 20 <path>`, the sandbox
    says no, and the model falls back to `cat`, which reads the whole file.
    On the 26-10 that was 3,41 M of tokens of the `ledger.md` (375 kB) and
    no other reason: the prompt recommended `tail -20` and the allow-list
    only knew `tail <path>`.

    The rule is EXECUTABLE: the test asks the checker of the prompts, it
    does not read the source of the allow-list.
    """
    print("22. the reads that the prompt recommends are runnable")
    checker = os.path.join(LOOP, "bin", "check-prompt-permissions.py")
    if not os.path.exists(checker):
        check("the checker of the prompts is there", False, checker)
        return

    # The agents of the repo when it has them (the runtime does not: opencode
    # loads them from ~/.config/opencode/agents) and the prompts of the repo
    # when it has them.
    agent_dir = agents_dir()
    prompts_dir = os.path.join(LOOP, "prompts")
    if not os.path.isdir(prompts_dir):
        prompts_dir = "/home/user/.local/share/solidcraft-loop/prompts"

    env = dict(os.environ)
    env["CHECK_AGENT_DIR"] = agent_dir
    env["CHECK_PROMPT_DIR"] = prompts_dir
    out = subprocess.run([sys.executable, checker], capture_output=True, text=True,
                         env=env, timeout=180)
    check("the checker of the prompts is happy", out.returncode == 0,
          out.stdout[-900:] + out.stderr[-300:])
    check("the checker of the prompts finds no dead instruction",
          "[iteration.md]" not in out.stdout, out.stdout[-900:])

    # The matcher of the checker, loaded as a module: the exact commands
    # that the prompt tells the model to run.
    saved = {k: os.environ.get(k) for k in ("CHECK_AGENT_DIR", "CHECK_PROMPT_DIR")}
    os.environ["CHECK_AGENT_DIR"] = agent_dir
    os.environ["CHECK_PROMPT_DIR"] = prompts_dir
    try:
        loader = importlib.machinery.SourceFileLoader("loop_prompt_perms", checker)
        spec = importlib.util.spec_from_loader("loop_prompt_perms", loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    # The module reads its directories when it is imported: the ones of the
    # test are the ones of this run, not the ones of the environment.
    module.AGENT_DIR = agent_dir
    module.PROMPT_DIR = prompts_dir
    rules = module.load("sc-orchestrator")
    loop = "/home/user/.local/share/solidcraft-loop"
    for cmd in (f"tail -n 20 {loop}/ledger.md",
                f"head -n 20 {loop}/ledger.md",
                f"wc -l {loop}/ledger.md",
                f"cat {loop}/ledger.md",
                f"tail {loop}/ledger.md"):
        ok, blockers = module.check(rules, cmd)
        check(f"the orchestrator can run {cmd!r}", ok, str(blockers))

    # The examples that the prompt marks as DENIED must STAY denied.
    for cmd in (f"ls -la {loop}/state/slot-0.json",
                "df -BG /home/user | tail -1"):
        ok, _ = module.check(rules, cmd)
        check(f"the orchestrator cannot run the denied {cmd!r}", not ok)


def test_slot_digest():
    """The digest of the slot: the summary that the model reads FIRST.

    The model read the view of the slot WHOLE (12 kB) and the ledger WHOLE
    (375 kB, 1121 lines) in every turn: 3,41 M of tokens of the ledger in
    24 h without a single new datum in it (the answer was always in the
    last fifteen lines). The digest carries the state of the slot and the
    last turns, and it has a FIXED ceiling: a line of the ledger can be a
    kilometre and the digest cannot grow with it.

    The rule is EXECUTABLE: the test asks the supervisor, it does not read
    the source of the digest.
    """
    print("23. the digest of the slot carries the state and has a ceiling")
    supervisor = os.path.join(LOOP, "bin", "supervisor.sh")
    loop = os.path.join(ROOT, "loop-digest")
    os.makedirs(os.path.join(loop, "state"), exist_ok=True)
    view = {
        "phase": "published", "issue": 5505, "branch": "fix/issue-5505",
        "branch_sha": "0123456789abcdef", "pr": 6345, "review": "aprobado",
        "gate_verdict": "PENDIENTE", "scope_verdict": "VERDE",
        "scope_kind": "layers", "scope_packages": "core",
        "merge_verdict": {"verdict": "VERDE", "pr": 6345,
                          "sha": "fedcba9876543210"},
        "in_flight": None, "published_pr": 6345, "mode": "normal",
        "counters": {"iterations": 412, "failures": 49, "consecutive": 1},
        "open_unmerged": 13, "allow_new_prs": True,
        "report": {"last": "2026-10-26", "pending": False},
        "attempts": {"5505": 3}, "triage": {}, "published": {},
        "prs": {"6345": {"title": "a title that is not in the digest"}},
        "slot": "0", "version": 3,
    }
    with open(os.path.join(loop, "state", "slot-0.json"), "w",
              encoding="utf-8") as fh:
        json.dump(view, fh, indent=2)
    ledger = os.path.join(loop, "ledger.md")
    with open(ledger, "w", encoding="utf-8") as fh:
        fh.write("| 2026-10-20T00:00Z | 1 | idle | - | the oldest line |\n")
        for i in range(40):
            fh.write("| 2026-10-26T00:%02dZ | 5505 | published | ok | %s |\n"
                     % (i, "x" * 5000))

    env = dict(os.environ)
    env["LOOP_DIR"] = loop
    out = subprocess.run(["bash", supervisor, "--digest", "0"],
                         capture_output=True, text=True, env=env, timeout=120)
    check("the query of the digest works", out.returncode == 0, out.stderr[-300:])
    digest = out.stdout
    if not digest:
        check("the digest has content", False, "the query printed nothing")
        return

    for field, value in (("phase", "published"), ("issue", "5505"),
                         ("branch", "fix/issue-5505"), ("pr", "6345"),
                         ("review", "aprobado"), ("gate_verdict", "PENDIENTE"),
                         ("scope_verdict", "VERDE"), ("kind", "layers"),
                         ("merge_verdict", "VERDE"), ("mode", "normal"),
                         ("counters", "iterations=412")):
        check(f"the digest carries {field}={value}",
              f"{field}: {value}" in digest, digest[:400])

    # The ceiling: the digest is a summary with a fixed size.
    check("the digest has a ceiling", len(digest) <= 12000,
          f"{len(digest)} bytes")

    # The last turns of the ledger, not the whole ledger.
    check("the digest carries the last turns of the ledger",
          "2026-10-26T00:39Z" in digest, digest[-400:])
    check("the digest does not carry the whole ledger",
          "the oldest line" not in digest, digest[:400])
    check("the long lines of the ledger are cut",
          "x" * 500 not in digest, "a line of the ledger was not cut")

    # The digest is a summary: it does not carry the whole view.
    check("the digest does not carry the whole view",
          "a title that is not in the digest" not in digest, digest[:400])

    # It points at the detail instead of replacing it.
    check("the digest points at the view",
          "state/slot-0.json" in digest, digest[-400:])
    check("the digest points at the ledger",
          "ledger.md" in digest, digest[-400:])


def test_slot_header():
    """The header of the slot: the FIRST thing of the message of the turn.

    The supervisor never wrote the header: the prompt promised it ("the
    supervisor picks the slot and tells you which one at the very beginning of
    this message, in a header") and the only slot written in the prompt was
    the EXAMPLE, whose slot was `0`. The slot 1 therefore read the view of the
    slot 0: two slots on the same work item, and that is how the conflict of
    `main` of the 28-10-2026 happened.

    The rule is EXECUTABLE: the test asks the supervisor for the message of a
    slot and reads its first lines. It does not read the source of the rule.
    """
    print("24. the message of the turn starts with the header of its slot")
    supervisor = os.path.join(LOOP, "bin", "supervisor.sh")
    loop = os.path.join(ROOT, "loop-header")
    prompts = os.path.join(loop, "prompts")
    os.makedirs(prompts, exist_ok=True)
    # The prompt of the iteration is COPIED: the test does not read the live
    # loop, it reads its own copy of the prompt.
    with open(os.path.join(LOOP, "prompts", "iteration.md"), "rb") as fh:
        iteration = fh.read()
    with open(os.path.join(prompts, "iteration.md"), "wb") as fh:
        fh.write(iteration)

    env = dict(os.environ)
    env["LOOP_DIR"] = loop
    for slot in ("0", "1"):
        out = subprocess.run(["bash", supervisor, "--prompt", slot],
                             capture_output=True, text=True, env=env, timeout=120)
        check(f"the query of the message of the slot {slot} works",
              out.returncode == 0, out.stderr[-300:])
        if out.returncode != 0:
            continue
        header, sep, body = out.stdout.partition("\n\n")
        lines = header.splitlines()
        check(f"the message of the slot {slot} starts with SLOT: {slot}",
              len(lines) == 3 and lines[0] == f"SLOT: {slot}",
              header[:200])
        check(f"the view of the message of the slot {slot} is its own",
              len(lines) > 1 and
              lines[1] == f"SLOT_VIEW: {loop}/state/slot-{slot}.json",
              header[:200])
        check(f"the digest of the message of the slot {slot} is its own",
              len(lines) > 2 and
              lines[2] == f"SLOT_DIGEST: {loop}/state/slot-{slot}.digest.md",
              header[:200])
        check(f"the prompt follows the header of the slot {slot}",
              sep == "\n\n" and body.startswith("# Vuelta del loop"),
              body[:120])
        # The header is NOT the example of the prompt: a slot written in the
        # example is not the slot of the turn.
        check(f"the example of the prompt carries no slot value (slot {slot})",
              "SLOT: 0" not in body and "SLOT: 1" not in body, body[:400])

    # The slot of the ENVIRONMENT is the slot of the turn: the systemd unit
    # puts it there (Environment=SLOT=%i) and the query takes no argument.
    env_slot = dict(env)
    env_slot["SLOT"] = "1"
    out = subprocess.run(["bash", supervisor, "--prompt"],
                         capture_output=True, text=True, env=env_slot, timeout=120)
    check("the slot of the environment is the slot of the message",
          out.returncode == 0 and out.stdout.startswith("SLOT: 1\n"),
          out.stdout[:120] + out.stderr[-200:])


def test_digest_other_slots():
    """The digest tells the slot what the OTHER slots have in flight.

    WHY (27-10): the model of the slot 1 read the rows of the ledger (a
    SHARED file) about the issue #7058 and spent a whole turn (5,6 min)
    trying to adopt an issue that the slot 0 had in flight. The digest said
    nothing about the other slots, so the only way to know was to read the
    ledger of the whole loop. The state refused the claim, but the turn was
    already spent.

    The rule is EXECUTABLE: the test asks the supervisor for the digest of
    a slot with another slot in flight, and it does not read the source.
    """
    print("30. the digest tells the slot what the other slots have in flight")
    supervisor = os.path.join(LOOP, "bin", "supervisor.sh")
    loop = os.path.join(ROOT, "loop-digest-others")
    os.makedirs(os.path.join(loop, "state"), exist_ok=True)
    common = {"counters": {}, "triage": {}, "published": {}, "prs": {},
              "report": {}, "attempts": {}, "merge_verdict": {},
              "version": 3}
    mine = dict(common, phase="idle", issue=0, branch="", pr=0, slot="0")
    other = dict(common, phase="gating", issue=7058,
                 branch="fix/issue-7058-svg-import-selection", pr=7368, slot="1")
    for name, view in (("slot-0.json", mine), ("slot-1.json", other)):
        with open(os.path.join(loop, "state", name), "w",
                  encoding="utf-8") as fh:
            json.dump(view, fh, indent=2)
    with open(os.path.join(loop, "ledger.md"), "w", encoding="utf-8") as fh:
        fh.write("| 2026-10-27T16:21Z | 7058 | gating | en curso | "
                 "the issue of the other slot |\n")

    env = dict(os.environ)
    env["LOOP_DIR"] = loop
    env["SLOT"] = "0"
    out = subprocess.run(["bash", supervisor, "--digest", "0"],
                         capture_output=True, text=True, env=env, timeout=120)
    check("the query of the digest works", out.returncode == 0, out.stderr[-300:])
    digest = out.stdout
    if not digest:
        check("the digest has content", False, "the query printed nothing")
        return

    check("the digest has the section of the other slots",
          "Los otros slots" in digest, digest[:400])
    check("the digest names the issue of the other slot",
          "7058" in digest, digest[:800])
    check("the digest says that the issue of the other slot is not yours",
          "no lo adoptés" in digest, digest[:800])

    # The prompt has to tell the model what to do with the section.
    with open(os.path.join(LOOP, "prompts", "iteration.md"),
              encoding="utf-8") as fh:
        prompt = fh.read()
    check("the prompt points at the section of the other slots",
          "Los otros slots" in prompt, "")


def turn_jsonl(path, steps=3, cost=0.01, reads=(), error=""):
    """A turn log of the tests: the events the scanner of the reads reads.

    The name starts with the date of the turn: the scanner filters by it.
    """
    with open(path, "w", encoding="utf-8") as fh:
        for _ in range(steps):
            fh.write(json.dumps({
                "type": "step_finish",
                "part": {
                    "type": "step-finish",
                    "cost": cost,
                    "tokens": {"input": 1000, "output": 100, "reasoning": 0,
                               "cache": {"read": 10000, "write": 0}},
                },
            }) + "\n")
            for name, chars in reads:
                fh.write(json.dumps({
                    "type": "tool_use",
                    "part": {"tool": "read", "state": {
                        "input": {"filePath": name},
                        "output": "x" * chars}},
                }) + "\n")
        if error:
            fh.write(json.dumps({
                "type": "error",
                "error": {"type": "unknown", "message": error},
            }) + "\n")


def test_marginal_effect():
    """What a change saved: the numbers per live turn, before and after.

    The plan of the tokens is measured with this: two sets of turns, the
    ones before the change and the ones after it. The numbers that are
    comparable are the ones PER LIVE TURN: the totals depend on the
    window and on how many turns each side had.

    The rule is EXECUTABLE: the test asks the script, it does not read
    its source.
    """
    print("24. the marginal effect of a change is measured")
    script = os.path.join(LOOP, "bin", "read-cost.py")
    if not os.path.exists(script):
        check("the script of the cost of the reads is there", False, script)
        return

    before_dir = os.path.join(ROOT, "turns-before")
    after_dir = os.path.join(ROOT, "turns-after")
    os.makedirs(before_dir, exist_ok=True)
    os.makedirs(after_dir, exist_ok=True)
    ledger = "/home/user/.local/share/solidcraft-loop/ledger.md"

    # BEFORE: two live turns (one of them reads the ledger whole) and one
    # dead turn: the agent does not resolve.
    turn_jsonl(os.path.join(before_dir, "2026-10-20T100000Z-1-slot0.jsonl"),
               steps=4, cost=0.02, reads=((ledger, 30000),))
    turn_jsonl(os.path.join(before_dir, "2026-10-21T100000Z-2-slot0.jsonl"),
               steps=4, cost=0.02)
    turn_jsonl(os.path.join(before_dir, "2026-10-22T100000Z-3-slot0.jsonl"),
               steps=1, cost=0.0, error='Agent not found: "sc-orchestrator"')

    # AFTER: two live turns that read the ledger by pieces.
    turn_jsonl(os.path.join(after_dir, "2026-10-26T100000Z-4-slot0.jsonl"),
               steps=4, cost=0.01, reads=((ledger, 600),))
    turn_jsonl(os.path.join(after_dir, "2026-10-26T110000Z-5-slot0.jsonl"),
               steps=4, cost=0.01)

    out = subprocess.run(
        [sys.executable, script, "--marginal", before_dir, after_dir],
        capture_output=True, text=True, timeout=180)
    check("the comparison of two sets of turns works", out.returncode == 0,
          out.stderr[-300:])
    text = out.stdout
    check("the comparison prints the dead turns apart",
          "dead (the agent)" in text, text[-400:])
    check("the comparison prints the change",
          "change" in text and "%" in text, text[-400:])
    check("the comparison prints the read chars per live turn",
          "read chars" in text, text[-400:])

    loader = importlib.machinery.SourceFileLoader("loop_read_cost", script)
    spec = importlib.util.spec_from_loader("loop_read_cost", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    if not hasattr(module, "marginal_metrics"):
        check("the script knows how to compare two sets of turns", False,
              "the script has no marginal mode")
        return

    before = module.marginal_metrics(module.scan_turns(before_dir))
    after = module.marginal_metrics(module.scan_turns(after_dir))
    check("the dead turn of the agent is counted apart",
          before["dead_agent"] == 1, str(before["dead_agent"]))
    check("the live turns are the ones that are not dead",
          before["live"] == 2 and after["live"] == 2,
          f"{before['live']} / {after['live']}")
    check("the read chars per live turn went down",
          after["per_turn"]["read_chars"] < before["per_turn"]["read_chars"],
          f"{after['per_turn']['read_chars']} vs "
          f"{before['per_turn']['read_chars']}")
    check("the cost per live turn went down",
          after["per_turn"]["cost"] < before["per_turn"]["cost"],
          f"{after['per_turn']['cost']} vs {before['per_turn']['cost']}")
    check("the ledger is the file that the change touches",
          before["files"].get(ledger, 0) > after["files"].get(ledger, 0),
          str(dict(before["files"])))

    # The window: the turns out of it are not counted.
    windowed = module.scan_turns(before_dir, since="2026-10-21")
    check("the window drops the turns out of it", len(windowed) == 2,
          str(len(windowed)))

    # A directory that is not there is refused (rc=2), not ignored.
    bad = subprocess.run(
        [sys.executable, script, "--marginal", before_dir,
         os.path.join(ROOT, "there-is-no-such-dir")],
        capture_output=True, text=True, timeout=60)
    check("a directory that is not there is refused", bad.returncode == 2,
          f"rc={bad.returncode}")


# --- the bash rules, extracted from the supervisor ------------------------

def bash_func(src, name):
    """The text of a bash function of the supervisor: from `name() {` to the
    first line that is exactly `}`."""
    out = []
    inside = False
    for line in src.splitlines():
        if not inside:
            if line.startswith(name + "() {"):
                inside = True
                out.append(line)
            continue
        out.append(line)
        if line == "}":
            return "\n".join(out) + "\n"
    raise ValueError("the function is not in the supervisor: " + name)


def bash_between(src, start, end, occurrence=1):
    """The text between two anchors of the supervisor. `occurrence` chooses
    which one of the repeated anchors is the start."""
    i = -1
    for _ in range(occurrence):
        i = src.index(start, i + 1)
    j = src.index(end, i)
    return src[i:j]


def write_script(path, body):
    with io.open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    return path


def run_bash(path, args, env=None, timeout=60):
    full = dict(os.environ)
    if env:
        full.update(env)
    return subprocess.run(["bash", path] + list(args), env=full,
                          capture_output=True, text=True, timeout=timeout)


def test_complete_gate_is_heavy_phase():
    """The complete gate alive is a HEAVY PHASE: the slot cedes the turn.

    The complete gate runs the whole test suite of the workspace: it takes
    about ten cores and thirty gigabytes, and its clock tests (a budget of
    30 s) go red with the load of another cargo in the same box. The gate is
    therefore a heavy phase like the implement is, and the slot that has
    heavy work to do cedes the turn while the gate runs.

    The cede happens BEFORE the model is called: no turn file is written, no
    token is spent and the daily cap of the slot is not consumed. The light
    work (the triage, the claim, the reading of a verdict) is NOT ceded: it
    is the work that has to keep flowing while the gate runs.

    The rule is EXECUTABLE: the block of the cede and the function that finds
    the live gate are taken from the supervisor and run against a fake gate
    process whose command line is the one of the complete gate.
    """
    print("26. the complete gate alive is a heavy phase")
    sup = os.path.join(LOOP, "bin", "supervisor.sh")
    with open(sup, encoding="utf-8") as fh:
        src = fh.read()

    live = bash_func(src, "live_gate_pid")
    block = bash_between(
        src,
        "# --- the complete gate alive: the machine is not ours",
        "# --- the heavy phase: one at a time in the whole machine")
    check("the supervisor has the block of the cede", bool(block.strip()))

    # The cede is BEFORE the model and BEFORE the turn file: the turn that
    # cedes does not exist.
    cede_at = src.index("# --- the complete gate alive: the machine is not ours")
    check("the cede is before the model is called",
          cede_at < src.index('"$OPENCODE_BIN" run'))
    check("the cede is before the turn file is written",
          cede_at < src.index("TURN_LOG="))

    live_file = write_script(os.path.join(ROOT, "live-gate.sh"), live)
    cede_file = write_script(os.path.join(ROOT, "cede-gate.sh"), block)
    harness = write_script(os.path.join(ROOT, "harness-gate.sh"), r"""
set -uo pipefail
phase="$1"; SLOT="$2"; LOOP_DIR="$3"; STUB_ISSUE="$4"
log() { echo "LOG: $*"; }
# A stub of `slot_issue`: the block under test only asks for the number of
# the issue to know which captures to look for.
slot_issue() { printf '%s' "$STUB_ISSUE"; }
. "$5"
. "$6"
echo "CONTINUE"
""")

    # Two loop directories: one with a live gate, one without.
    alive = os.path.join(ROOT, "loop-alive")
    dead = os.path.join(ROOT, "loop-dead")
    caps = os.path.join(ROOT, "loop-caps")
    for d in (alive, dead, caps):
        os.makedirs(os.path.join(d, "gates", "default"), exist_ok=True)
        os.makedirs(os.path.join(d, "evidence"), exist_ok=True)
    gate = subprocess.Popen(["bash", "-c", "exec -a 'cargo xtask ci' sleep 300"])
    try:
        for d in (alive, caps):
            with io.open(os.path.join(d, "gates", "default", "pid"), "w",
                         encoding="utf-8") as fh:
                fh.write(str(gate.pid))
        with io.open(os.path.join(caps, "evidence", "4629-antes.png"), "w",
                     encoding="utf-8") as fh:
            fh.write("png")

        def case(loop_dir, phase, issue="4629"):
            out = run_bash(harness, [phase, "0", loop_dir, issue,
                                     live_file, cede_file])
            return out

        out = case(alive, "claimed")
        check("with the gate alive the implement cedes the turn",
              "CONTINUE" not in out.stdout and out.returncode == 0,
              (out.stdout[-300:] + out.stderr[-300:]))
        check("the cede says why it cedes",
              "the complete gate is alive" in out.stdout, out.stdout[-300:])

        out = case(dead, "claimed")
        check("with no gate alive the implement goes on",
              "CONTINUE" in out.stdout, out.stdout[-300:])

        out = case(caps, "implemented")
        check("with the gate alive and the captures on disk the publication"
              " goes on",
              "CONTINUE" in out.stdout, out.stdout[-300:])

        out = case(alive, "implemented")
        check("with the gate alive and no captures the evidence cedes",
              "CONTINUE" not in out.stdout and out.returncode == 0,
              out.stdout[-300:])

        for light in ("selected", "gating", "gated"):
            out = case(alive, light)
            check("the light phase %s is not ceded" % light,
                  "CONTINUE" in out.stdout, out.stdout[-300:])
    finally:
        gate.terminate()
        try:
            gate.wait(timeout=10)
        except subprocess.TimeoutExpired:
            gate.kill()


def test_issue_in_flight_guard():
    """The worktree of an issue is at ONE path: the slot that does not own
    the issue does not touch it.

    The worktree of an issue lives in a single path (worktrees/issue-N) and
    the slot that does not own it removes it with `git worktree remove
    --force`. Two slots on the same issue would make the second one erase the
    work of the first one: the fix that is not committed yet, the evidence,
    the branch.

    The owner of an issue is the slot that is FURTHER ALONG (its phase has
    more rank) and, in a tie, the one with the lowest id: without that rule
    the two slots would cede to each other and the issue would stay still.
    A slot is alive if it is running right now (the lock of its turn is
    held) or if it started a turn recently.

    The rule is EXECUTABLE: the functions and the blocks are taken from the
    supervisor and run against a loop directory of the tests.
    """
    print("27. the issue in flight in another slot is not touched")
    sup = os.path.join(LOOP, "bin", "supervisor.sh")
    with open(sup, encoding="utf-8") as fh:
        src = fh.read()

    # The rank of the phases: the further along, the lower the number.
    rank_file = write_script(os.path.join(ROOT, "rank.sh"),
                              bash_func(src, "phase_rank"))
    rharness = write_script(os.path.join(ROOT, "harness-rank.sh"), r"""
. "$1"
for p in gated gating implemented claimed selected; do
  printf '%s=%s\n' "$p" "$(phase_rank "$p")"
done
""")

    def ranks_are_ordered():
        out = run_bash(rharness, [rank_file])
        got = dict(line.split("=", 1)
                   for line in out.stdout.strip().splitlines() if "=" in line)
        order = ["gated", "gating", "implemented", "claimed", "selected"]
        try:
            values = [int(got[p]) for p in order]
        except (KeyError, ValueError):
            return False
        return values == sorted(values) and len(set(values)) == len(values)

    constant = next((l for l in src.splitlines()
                     if l.startswith("ISSUE_IN_FLIGHT_FRESH_MIN=")), "")
    check("the freshness of a slot in flight has a default",
          constant == 'ISSUE_IN_FLIGHT_FRESH_MIN="${ISSUE_IN_FLIGHT_FRESH_MIN:-15}"',
          constant)
    funcs = (constant + "\n"
             + bash_func(src, "phase_rank")
             + bash_func(src, "slot_is_running")
             + bash_func(src, "issue_owners_alive")
             + bash_func(src, "issue_owner_elsewhere"))
    funcs_file = write_script(os.path.join(ROOT, "owner-funcs.sh"), funcs)
    harness = write_script(os.path.join(ROOT, "harness-owner.sh"), r"""
set -uo pipefail
LOOP_DIR="$1"; SLOT="$2"; NOW_EPOCH="$3"; ISSUE="$4"; HOLD="$5"
log() { echo "LOG: $*"; }
# A slot that holds the lock of its turn is running right now.
if [ -n "$HOLD" ]; then
  exec 8>"$LOOP_DIR/.lock.$HOLD"
  flock -n 8 || exit 9
fi
. "$6"
issue_owner_elsewhere "$ISSUE"
printf '\nRC=%s\n' "$?"
""")

    now = int(dt.datetime.now(dt.timezone.utc).timestamp())
    loop = os.path.join(ROOT, "loop-owners")
    os.makedirs(os.path.join(loop, "state"), exist_ok=True)

    def view(slot, issue, phase, mtime=None):
        path = os.path.join(loop, "state", "slot-%s.json" % slot)
        with io.open(path, "w", encoding="utf-8") as fh:
            fh.write(json.dumps({"issue": issue, "phase": phase}))
        if mtime is None:
            mtime = now
        os.utime(path, (mtime, mtime))

    def owner(slot="0", issue="4629", hold=""):
        out = run_bash(harness, [loop, slot, str(now), issue, hold, funcs_file])
        line = out.stdout.strip().splitlines()
        if not line or line[0].startswith("RC="):
            return None
        return line[0]

    check("the phase ranking is the one of the progress",
          ranks_are_ordered(), "the rank of the phases is not the progress")

    # (1) the owner: the other slot has the issue and it is alive
    view(1, 4629, "gating")
    check("the slot that has the issue alive is its owner",
          owner() == "1 gating", owner())

    # (2) the view of a slot that has not started a turn recently is stale
    view(1, 4629, "gating", mtime=now - 3600)
    check("a stale slot does not own anything", owner() is None, owner())

    # (3) a slot that is running right now owns it even with a stale view
    view(1, 4629, "gating", mtime=now - 3600)
    check("a running slot owns the issue even with a stale view",
          owner(hold="1") == "1 gating", owner(hold="1"))

    # (4) another issue, another phase, another slot
    view(1, 5555, "gating")
    check("a slot of another issue does not own this one",
          owner() is None, owner())
    view(1, 4629, "failed")
    check("a slot that is not in flight does not own the issue",
          owner() is None, owner())

    # (5) two owners: the one that is further along wins
    view(1, 4629, "claimed")
    view(2, 4629, "gated")
    check("the slot that is further along owns the issue",
          owner() == "2 gated", owner())

    # (6) a tie: the lowest id wins
    view(1, 4629, "gating")
    view(2, 4629, "gating")
    check("in a tie the lowest id owns the issue",
          owner() == "1 gating", owner())

    # (7) the view of THIS slot is not an owner
    os.unlink(os.path.join(loop, "state", "slot-1.json"))
    os.unlink(os.path.join(loop, "state", "slot-2.json"))
    view(0, 4629, "gating")
    check("the slot does not own its own issue", owner() is None, owner())
    os.unlink(os.path.join(loop, "state", "slot-0.json"))

    # --- the cede in front of the reuse of the worktree ------------------
    guard = bash_between(src, '    if [ -n "$WT_OWNER" ]; then',
                         '    WT_BRANCH_NOW=""')
    check("the supervisor has the guard of the owner", bool(guard.strip()))
    guard_file = write_script(os.path.join(ROOT, "guard.sh"),
                              bash_func(src, "phase_rank") + guard)
    gharness = write_script(os.path.join(ROOT, "harness-guard.sh"), r"""
set -uo pipefail
phase="$1"; SLOT="$2"; WT_ISSUE="$3"; WT_OWNER="$4"; WT_OWNER_PHASE="$5"
log() { echo "LOG: $*"; }
. "$6"
echo "CONTINUE"
""")

    def guard_case(phase, slot, owner_id, owner_phase):
        out = run_bash(gharness, [phase, slot, "4629", owner_id, owner_phase,
                                  guard_file])
        return out

    out = guard_case("claimed", "0", "1", "gated")
    check("the slot that is behind cedes the turn",
          "CONTINUE" not in out.stdout and out.returncode == 0,
          (out.stdout[-300:] + out.stderr[-300:]))
    check("the cede says which issue is in flight",
          "the issue #4629 is in flight in the slot 1" in out.stdout,
          out.stdout[-300:])

    out = guard_case("claimed", "0", "1", "selected")
    check("the slot that is further along does not cede",
          "CONTINUE" in out.stdout, out.stdout[-300:])

    out = guard_case("gating", "1", "0", "gating")
    check("in a tie the slot with the lowest id keeps the issue",
          "CONTINUE" not in out.stdout and out.returncode == 0,
          out.stdout[-300:])

    out = guard_case("gating", "0", "1", "gating")
    check("in a tie the slot with the highest id cedes",
          "CONTINUE" in out.stdout, out.stdout[-300:])

    out = guard_case("claimed", "0", "", "")
    check("without an owner nobody cedes", "CONTINUE" in out.stdout,
          out.stdout[-300:])

    # --- the cleanup of a worktree that another slot is using ------------
    cleanup = bash_between(src, '    if [ -n "$WT_OWNER" ]; then',
                           '      log "issue #${WT_ISSUE}: worktree removed'
                           ' ($WT_PATH)"\n', occurrence=2) + "    fi\n"
    check("the supervisor has the cleanup of the worktree",
          bool(cleanup.strip()))
    cleanup_file = write_script(os.path.join(ROOT, "cleanup.sh"), cleanup)
    charness = write_script(os.path.join(ROOT, "harness-cleanup.sh"), r"""
set -uo pipefail
WT_OWNER="$1"; WT_ISSUE="$2"; WT_PATH="$3"; REPO="$4"
log() { echo "LOG: $*"; }
. "$5"
""")
    git_log = os.path.join(ROOT, "git-calls.log")
    fake_bin = os.path.join(ROOT, "fake-bin")
    os.makedirs(fake_bin, exist_ok=True)
    write_script(os.path.join(fake_bin, "git"),
                 '#!/bin/sh\necho "$@" >> "%s"\nexit 0\n' % git_log)
    os.chmod(os.path.join(fake_bin, "git"), 0o755)
    wt = os.path.join(ROOT, "worktrees", "issue-4629")
    os.makedirs(wt, exist_ok=True)

    out = run_bash(charness, ["1", "4629", wt, ROOT, cleanup_file],
                   env={"PATH": fake_bin + ":" + os.environ.get("PATH", "")})
    check("the worktree of an issue in flight is not removed",
          "worktree remove" not in open(git_log).read()
          if os.path.exists(git_log) else True,
          out.stdout[-200:])
    check("the deferral says who is working on it",
          "the slot 1 is working on it" in out.stdout, out.stdout[-300:])

    if os.path.exists(git_log):
        os.unlink(git_log)
    out = run_bash(charness, ["", "4629", wt, ROOT, cleanup_file],
                   env={"PATH": fake_bin + ":" + os.environ.get("PATH", "")})
    removed = os.path.exists(git_log) and "worktree remove --force" in \
        open(git_log).read()
    check("the worktree of an issue that is done is removed", removed,
          out.stdout[-200:])


def test_gate_watchdog():
    """The watchdog of the complete gate decides by the PROGRESS, not by the
    age.

    The complete gate takes about 2 h 50 min and it prints while it works
    (nextest lists its slow tests every minute). The age alone killed two
    gates that were making progress: 2 h 50 min of CPU thrown away twice.

    The watchdog has three ways to say that a gate is not worth the machine:
    `stuck` (its log has not moved for GATE_SILENT_MIN), `expired` (it is
    older than the hard ceiling) and `stale` (the sha it gates was thrown
    away by a rewrite of the branch, so its verdict could never be used).

    It FAILS OPEN: a gate it cannot judge is left alone.

    The rule is EXECUTABLE: the real script is run against a log that moves,
    a log that does not, a gate that is too old and a branch that was
    rewritten.
    """
    print("28. the watchdog of the complete gate decides by the progress")
    wd = os.path.join(LOOP, "bin", "gate-watchdog.sh")
    check("the watchdog exists", os.path.isfile(wd), wd)

    now = int(time.time())

    def verdict(log=None, started=None, sha="", branch="", repo="",
                timeout=300, silent=90, touch=None):
        args = [wd, "--pid", "1", "--now", str(now), "--timeout-min",
                str(timeout), "--silent-min", str(silent)]
        args += ["--started", str(now - 600 if started is None else started)]
        if log:
            args += ["--log", log]
        if sha:
            args += ["--sha", sha]
        if branch:
            args += ["--branch", branch]
        if repo:
            args += ["--repo", repo]
        out = run_bash(wd, args[1:], timeout=60)
        got = {}
        for line in out.stdout.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                got[k] = v
        return got, out

    # --- a gate that works is left alone --------------------------------
    log_alive = os.path.join(ROOT, "gate-alive.log")
    write_script(log_alive, "PASS [ 1.0s] (1/1) a test\n")
    got, out = verdict(log=log_alive, started=now - 155 * 60)
    check("a gate of 155 min whose log moves is left alone",
          got.get("VERDICT") == "alive", out.stdout[-300:])

    # --- a gate whose log does not move is stuck -------------------------
    log_stuck = os.path.join(ROOT, "gate-stuck.log")
    write_script(log_stuck, "PASS [ 1.0s] (1/1) a test\n")
    old = now - 120 * 60
    os.utime(log_stuck, (old, old))
    got, out = verdict(log=log_stuck, started=now - 125 * 60)
    check("a gate whose log has not moved for 120 min is stuck",
          got.get("VERDICT") == "stuck", out.stdout[-300:])

    # --- the hard ceiling is the backstop --------------------------------
    got, out = verdict(log=log_alive, started=now - 400 * 60, timeout=300)
    check("a gate older than the ceiling is expired",
          got.get("VERDICT") == "expired", out.stdout[-300:])

    # --- it fails open ---------------------------------------------------
    got, out = verdict(log=None, started=0)
    check("without a start marker the gate is left alone",
          got.get("VERDICT") == "alive", out.stdout[-300:])
    got, out = verdict(log=os.path.join(ROOT, "no-such-log.log"),
                       started=now - 600)
    check("without a log the gate is left alone",
          got.get("VERDICT") == "alive", out.stdout[-300:])
    # A log that exists but cannot be READ: the watchdog cannot measure the
    # progress, so it does not call it a silence. The file is made
    # unreadable on purpose (the mode 000).
    log_unreadable = os.path.join(ROOT, "gate-unreadable.log")
    write_script(log_unreadable, "PASS [ 1.0s] (1/1) a test\n")
    old = now - 120 * 60
    os.utime(log_unreadable, (old, old))
    os.chmod(log_unreadable, 0o000)
    got, out = verdict(log=log_unreadable, started=now - 125 * 60)
    check("a log that cannot be read is not a silence",
          got.get("VERDICT") == "alive", out.stdout[-300:])
    os.chmod(log_unreadable, 0o644)

    # --- the drift of the tip: the branch was rewritten ------------------
    repo = os.path.join(ROOT, "repo-drift")
    os.makedirs(repo, exist_ok=True)
    env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}

    def git(*args):
        return subprocess.run(["git", "-C", repo] + list(args), env=env,
                              capture_output=True, text=True)

    git("init", "-q", "-b", "main")
    for i in range(3):
        write_script(os.path.join(repo, "f.txt"), "line %d\n" % i)
        git("add", "-A")
        git("commit", "-qm", "c%d" % i)
    c1 = git("rev-parse", "HEAD~2").stdout.strip()
    c2 = git("rev-parse", "HEAD~1").stdout.strip()
    git("checkout", "-q", "-b", "work")
    # The branch is rewritten: the tip moves to a commit that does not have
    # the old ones in its history.
    git("reset", "-q", "--hard", c1)
    write_script(os.path.join(repo, "f.txt"), "rewritten\n")
    git("add", "-A")
    git("commit", "-qm", "rewritten")
    tip = git("rev-parse", "work").stdout.strip()

    got, out = verdict(log=log_alive, sha=c2, branch="work", repo=repo)
    check("a gate whose sha was thrown away by a rewrite is stale",
          got.get("VERDICT") == "stale", out.stdout[-300:])
    check("the stale verdict says which sha and which branch",
          c2[:8] in got.get("REASON", "") and "work" in got.get("REASON", ""),
          got.get("REASON", "")[-200:])

    got, out = verdict(log=log_alive, sha=c1, branch="work", repo=repo)
    check("a gate whose sha is still in the branch is left alone",
          got.get("VERDICT") == "alive", out.stdout[-300:])

    # A gate of ANOTHER pull request: its sha is not part of this branch.
    git("checkout", "-q", "-b", "other", c1)
    write_script(os.path.join(repo, "other.txt"), "other\n")
    git("add", "-A")
    git("commit", "-qm", "other")
    other = git("rev-parse", "other").stdout.strip()
    got, out = verdict(log=log_alive, sha=other, branch="work", repo=repo)
    check("the gate of another pull request is not killed",
          got.get("VERDICT") == "alive", out.stdout[-300:])

    got, out = verdict(log=log_alive, sha=other, branch="no-such-branch",
                       repo=repo)
    check("without a branch there is no drift",
          got.get("VERDICT") == "alive", out.stdout[-300:])
    got, out = verdict(log=log_alive, sha="0" * 40, branch="work", repo=repo)
    check("without a valid sha there is no drift",
          got.get("VERDICT") == "alive", out.stdout[-300:])


def test_supervisor_uses_the_watchdog():
    """The supervisor asks the watchdog and obeys it, and it never kills a
    gate by the age alone.

    The block of the supervisor is extracted and run against a watchdog
    double: the doubles say `alive`, `stuck` and nothing at all (the
    watchdog fails), and the observable effects are checked: the gate is
    left alone, the gate is killed and marked with EXIT=124, and a watchdog
    that fails leaves the gate alone.
    """
    print("29. the supervisor obeys the watchdog of the complete gate")
    sup = os.path.join(LOOP, "bin", "supervisor.sh")
    with open(sup, encoding="utf-8") as fh:
        src = fh.read()

    block = bash_between(src, "# --- gate watchdog",
                         "# --- precondition 3: gh")
    check("the supervisor has the block of the watchdog",
          bool(block.strip()))
    check("the watchdog of the supervisor is bin/gate-watchdog.sh",
          "gate-watchdog.sh" in block)
    check("the age alone does not kill a gate any more",
          'age_min" -gt' not in block and "age_min -gt" not in block)

    harness = write_script(os.path.join(ROOT, "harness-watchdog.sh"), r"""
set -uo pipefail
LOOP_DIR="$1"; GATE_PID="$2"; GATE_STARTED="$3"; NOW_EPOCH="$4"
GATE_PATH_FILE="$5"; STATE_GATE_LOG="$6"; STUB_BRANCH="$7"; REPO="$8"
WD_STUB="$9"
GATE_ALIVE=1
GATE_TIMEOUT_MIN=300
GATE_SILENT_MIN=90
# The cleanup of the orphans looks at the processes that work in the gate
# worktree: here there is nothing (the test must not kill its own
# processes).
GATE_WORKTREE="$1/gate-wt-test"
log() { echo "LOG: $*"; }
slot_field() { printf '%s' "$STUB_BRANCH"; }
mkdir -p "$LOOP_DIR/bin"
cp "$WD_STUB" "$LOOP_DIR/bin/gate-watchdog.sh"
# ${10}, not $10: in bash $10 is $1 followed by a zero.
. "${10}"
echo "DONE"
""")

    def stub(body):
        path = os.path.join(ROOT, "wd-stub.sh")
        write_script(path, body)
        return path

    def case(verdict_text, rc=0):
        loop = os.path.join(ROOT, "loop-wd")
        os.makedirs(os.path.join(loop, "bin"), exist_ok=True)
        logf = os.path.join(loop, "gate.log")
        write_script(logf, "PASS [ 1.0s] (1/1) a test\n")
        body = "#!/usr/bin/env bash\n" + verdict_text
        wd = stub(body)
        # A gate of its own process group: the block kills the GROUP.
        proc = subprocess.Popen(["setsid", "bash", "-c",
                                 "exec -a 'cargo xtask ci' sleep 300"])
        try:
            with io.open(os.path.join(loop, "gate.pid"), "w",
                         encoding="utf-8") as fh:
                fh.write(str(proc.pid))
            with io.open(os.path.join(loop, "gate.sha"), "w",
                         encoding="utf-8") as fh:
                fh.write("0" * 40)
            out = run_bash(harness, [loop, str(proc.pid), "1", "1", logf, "",
                                     "fix/issue-4629", ROOT, wd,
                                     os.path.join(ROOT, "block.sh")])
            alive = proc.poll() is None
            if alive:
                proc.kill()
                proc.wait(timeout=10)
            pid_file = os.path.join(loop, "gate.pid")
            return out, alive, os.path.exists(pid_file), \
                open(logf, encoding="utf-8").read()
        finally:
            if proc.poll() is None:
                proc.kill()

    write_script(os.path.join(ROOT, "block.sh"), block)

    out, alive, pid_left, logtext = case(
        "printf 'VERDICT=alive\\nREASON=it works\\nAGE_MIN=10\\nSILENT_MIN=0\\n'\n")
    check("a gate that the watchdog says is alive is not killed",
          alive and pid_left, out.stdout[-300:])
    check("the log of a gate that is alive does not get an EXIT=",
          "EXIT=" not in logtext, logtext[-200:])

    out, alive, pid_left, logtext = case(
        "printf 'VERDICT=stuck\\nREASON=it says nothing\\nAGE_MIN=100\\nSILENT_MIN=120\\n'\n")
    check("a gate that the watchdog says is stuck is killed",
          not alive, out.stdout[-300:])
    check("the killed gate does not leave its pid file behind",
          not pid_left, out.stdout[-300:])
    check("the killed gate is marked with EXIT=124",
          "EXIT=124" in logtext, logtext[-200:])

    out, alive, pid_left, logtext = case(
        "printf 'VERDICT=stale\\nREASON=the branch was rewritten\\nAGE_MIN=100\\nSILENT_MIN=0\\n'\n")
    check("a gate that the watchdog says is stale is killed",
          not alive, out.stdout[-300:])

    out, alive, pid_left, logtext = case(
        "exit 1\n")
    check("a watchdog that fails leaves the gate alone",
          alive and pid_left, out.stdout[-300:])
    check("the supervisor says that it failed open",
          "left alone" in out.stdout, out.stdout[-300:])


def test_scope_deferred_while_the_complete_gate_is_alive():
    """The scoped gate is DEFERRED while the complete gate is alive.

    WHY (27-10): the complete gate holds tens of GB of memory (two test
    binaries of 19 GB and 16 GB) on a machine of 62 GB. A scoped gate
    launched next to it compiles in parallel and takes the memory that the
    complete gate needs: the OOM killer takes the BIGGEST process, so the
    victim is the COMPLETE GATE and the run that is in the middle (2 h 50
    min) is lost. The belt of the scope (32G/40G) does NOT protect the
    complete gate: the belt limits the scope, not the gate that is next to
    it. The deferral is the piece that complements the belt.

    The deferral is NOT a verdict and NOT a red code: the scope is
    postponed, and the state machine reads it as "no verdict" (a scope
    that is not finished).

    The rule is EXECUTABLE: the detection of the complete gate is taken
    from the gate-quick and run against a loop directory of the tests.
    """
    print("31. the scoped gate is deferred while the complete gate is alive")
    gate = os.path.join(LOOP, "bin", "gate-quick.sh")
    with open(gate, encoding="utf-8") as fh:
        src = fh.read()

    funcs_file = write_script(os.path.join(ROOT, "complete-gate-pid.sh"),
                               bash_func(src, "complete_gate_pid"))
    harness = write_script(os.path.join(ROOT, "harness-complete-gate.sh"), r"""
set -uo pipefail
LOOP_DIR="$1"
. "$2"
if p="$(complete_gate_pid 2>/dev/null)"; then
  printf 'DETECTED=%s\n' "$p"
else
  printf 'DETECTED=none\n'
fi
""")

    def detected(loop):
        out = run_bash(harness, [loop, funcs_file])
        lines = out.stdout.strip().splitlines()
        got = ""
        for line in lines:
            if line.startswith("DETECTED="):
                got = line.split("=", 1)[1]
                break
        return got, out

    loop = os.path.join(ROOT, "loop-defer")
    os.makedirs(os.path.join(loop, "gates", "default"), exist_ok=True)
    pid_file = os.path.join(loop, "gate.pid")
    slot_file = os.path.join(loop, "gates", "default", "pid")

    # (1) a complete gate that is alive: the cmdline carries its marker
    alive = subprocess.Popen(
        ["bash", "-c", 'exec -a "solidcraft-gate-slot:default" sleep 120'])
    time.sleep(0.3)
    try:
        cmdline = open("/proc/%d/cmdline" % alive.pid, "rb").read()
        cmdline = cmdline.replace(b"\0", b" ").decode("utf-8", "replace")
        check("the process of the test looks like a complete gate",
              "solidcraft-gate-slot:" in cmdline, cmdline[:120])

        with open(pid_file, "w", encoding="utf-8") as fh:
            fh.write(str(alive.pid))
        got, out = detected(loop)
        check("a complete gate that is alive is detected",
              got == str(alive.pid), out.stdout + out.stderr)

        # (2) the pid file of a slot counts too
        os.unlink(pid_file)
        with open(slot_file, "w", encoding="utf-8") as fh:
            fh.write(str(alive.pid))
        got, out = detected(loop)
        check("the pid file of a slot is also read",
              got == str(alive.pid), out.stdout + out.stderr)
        os.unlink(slot_file)

        # (3) a live process that is NOT a gate: nothing is deferred
        other = subprocess.Popen(["sleep", "120"])
        time.sleep(0.3)
        try:
            with open(pid_file, "w", encoding="utf-8") as fh:
                fh.write(str(other.pid))
            got, out = detected(loop)
            check("a live process that is not a gate does not defer anything",
                  got == "none", out.stdout + out.stderr)
        finally:
            other.kill()
            other.wait()

        # (4) a dead pid: nothing is deferred
        dead = subprocess.Popen(["sleep", "120"])
        dead.kill()
        dead.wait()
        with open(pid_file, "w", encoding="utf-8") as fh:
            fh.write(str(dead.pid))
        got, out = detected(loop)
        check("a dead pid does not defer anything",
              got == "none", out.stdout + out.stderr)

        # (5) a pid file with garbage: nothing, and no error of the shell
        with open(pid_file, "w", encoding="utf-8") as fh:
            fh.write("no-es-un-pid\n")
        got, out = detected(loop)
        check("a pid file with garbage does not defer anything",
              got == "none", out.stdout + out.stderr)
        check("a pid file with garbage does not break the shell",
              "integer expression" not in out.stderr
              and "integer expression" not in out.stdout,
              out.stderr[:200])
    finally:
        alive.kill()
        alive.wait()

    # (6) without pid files: nothing is deferred
    got, out = detected(loop)
    check("without a pid file nothing is deferred",
          got == "none", out.stdout + out.stderr)

    # --- the shape of the deferral -----------------------------------------
    block = bash_between(src, 'DEFER_PID=""', 'SCOPE="$PACKAGES"')
    check("the deferral writes a deferred verdict",
          "write_verdicts skipped" in block
          and "complete-gate-alive" in block, block[:300])
    check("the deferral happens before anything is compiled",
          src.index('DEFER_PID=""') < src.index('phase "fmt"'),
          "the deferral is after the first phase")
    check("the deferral uses the detection of the complete gate",
          "complete_gate_pid" in block, block[:200])

    # --- the name of the scope is unique per run ---------------------------
    # systemd refuses to create a unit that exists, and that refusal is
    # SILENT: the belt is not there and the gate runs unbounded.
    check("the name of the scope carries the pid of the run",
          'scope_unit_name "$SLOT_NAME-$$"' in src
          or "scope_unit_name \"$SLOT_NAME-$$\"" in src,
          "the scope unit is named after the slot alone")

    # --- the verdict file says that it is a deferral -----------------------
    check("the verdict file carries the key of the deferral",
          "DEFERRED=%s" in src, "")
    writer = bash_func(src, "write_verdicts")
    check("the writer of the verdicts takes the deferral",
          "deferred" in writer and "$deferred" in writer, writer[:300])

    # --- the state machine does not read a deferral as a green scope -------
    st_mod = load_state()
    green, why = st_mod.scoped_gate_green({
        "scope_verdict": "SKIP",
        "scope_status": "skipped",
        "scope_kind": "packages",
        "scope_new_failures": 0,
        "scope_checks": "fmt:skipped|layers:skipped|clippy:skipped",
    })
    check("a deferred scope is not a green scope", not green, why)

    # --- the supervisor runs the deferred scope again ------------------------
    # A deferral is a POSTPONEMENT, not a verdict: the scope was never
    # judged, so the supervisor runs it again when the machine is free.
    sup = os.path.join(LOOP, "bin", "supervisor.sh")
    with open(sup, encoding="utf-8") as fh:
        ssrc = fh.read()
    decision = bash_between(ssrc, 'q_sha="$(scope_verdict_field SHA)"',
                             "  # (5) The service has to be alive")
    check("the supervisor reads the key of the deferral",
          "scope_verdict_field DEFERRED" in decision, decision[:300])

    # --- the deferral is VISIBLE (the slot view and the digest) ------------
    # A deferral that nobody can see is a deferral that looks like a
    # verdict: the state machine knows it, but the model reads the digest
    # and the slot view, and there a SKIP looked like a red scope.
    check("the slot view exposes the deferral",
          "scope_deferred: ($sl.scope_deferred" in ssrc, "")
    check("the digest shows the deferral",
          "- scope_deferred: " in ssrc, "")

    # The digest of a slot with a deferral names the deferral: the model
    # reads the digest first, so a deferral that is not there looks like a
    # red scope that is never going to move.
    loop_view = os.path.join(ROOT, "loop-defer-view")
    os.makedirs(os.path.join(loop_view, "state"), exist_ok=True)
    with open(os.path.join(loop_view, "state", "slot-0.json"), "w",
              encoding="utf-8") as fh:
        json.dump({"phase": "implemented", "issue": 7058, "branch": "b",
                   "scope_verdict": "SKIP", "scope_status": "skipped",
                   "scope_kind": "packages", "scope_packages": "solidcraft",
                   "scope_deferred": "complete-gate-alive"}, fh, indent=2)
    env = dict(os.environ)
    env["LOOP_DIR"] = loop_view
    env["SLOT"] = "0"
    out = subprocess.run(["bash", sup, "--digest", "0"],
                         capture_output=True, text=True, env=env, timeout=120)
    check("the digest of a deferred slot says that it was deferred",
          "complete-gate-alive" in out.stdout, out.stdout[-400:])
    check("the decision of the supervisor is a value, not a return",
          "q_decision=" in decision and 'q_decision="skip"' in decision,
          decision[:400])
    decision_file = write_script(os.path.join(ROOT, "decision-defer.sh"), decision)
    dec_file = write_script(os.path.join(ROOT, "decide-defer.sh"), r"""
set -uo pipefail
sha="$1"; t_sha="$2"; t_status="$3"; t_verdict="$4"; t_deferred="$5"
BLOCK="$6"
scope_verdict_field() {
  case "$1" in
    SHA) printf '%s' "$t_sha" ;;
    GATE_STATUS) printf '%s' "$t_status" ;;
    VERDICT) printf '%s' "$t_verdict" ;;
    DEFERRED) printf '%s' "$t_deferred" ;;
  esac
}
log() { :; }
# The block is sourced INSIDE a function on purpose: the decision is read
# AFTER the function, so the harness does not depend on what a `return`
# inside a sourced file does (in bash it does NOT abort the function that
# sources it).
decide() {
  . "$BLOCK"
}
decide
printf 'DECISION=%s\n' "${q_decision:-unset}"
""")

    def decision(sha, status, verdict, deferred, verdict_sha=None):
        if verdict_sha is None:
            verdict_sha = sha
        out = run_bash(dec_file, [sha, verdict_sha, status, verdict, deferred,
                                  decision_file], timeout=30)
        got = ""
        for line in out.stdout.splitlines():
            if line.startswith("DECISION="):
                got = line.split("=", 1)[1].strip()
                break
        return got, out.stdout + out.stderr

    got, detail = decision("a" * 40, "finished", "VERDE-SCOPE", "")
    check("a green scope is not run again", got == "skip", detail)
    got, detail = decision("a" * 40, "skipped", "SKIP", "")
    check("a scope with nothing to check is not run again", got == "skip",
          detail)
    got, detail = decision("a" * 40, "failed", "SKIP", "")
    check("a scope that did not finish is run again", got == "run", detail)
    got, detail = decision("a" * 40, "skipped", "SKIP", "complete-gate-alive")
    check("a DEFERRED scope is run again (it is not a verdict)",
          got == "run", detail)
    got, detail = decision("a" * 40, "finished", "VERDE-SCOPE", "",
                            verdict_sha="b" * 40)
    check("a verdict of ANOTHER sha does not stop the scope", got == "run",
          detail)

    # --- the prompt tells the model what a deferral is ---------------------
    with open(os.path.join(LOOP, "prompts", "iteration.md"),
              encoding="utf-8") as fh:
        prompt = fh.read()
    check("the prompt knows the deferral",
          "DEFERRED=complete-gate-alive" in prompt, "")
    check("the prompt says that a deferral is not a verdict",
          "deferred, not judged" in prompt
          or "deferred, **not judged**" in prompt, "")

    # --- the state exposes the deferral -----------------------------------
    # The state is what the operator reads: the deferral has to be a field
    # of its own, and the refusal has to NAME it.
    defer_loop = make_loop_dir(ROOT, HEAD, name="loop-deferred")
    defer_dir = os.path.join(defer_loop, "gates", "0")
    os.makedirs(defer_dir, exist_ok=True)
    with open(os.path.join(defer_dir, "scope.verdict"), "w",
              encoding="utf-8") as fh:
        fh.write("GATE_STATUS=skipped\n"
                 "SCOPE=solidcraft solidcraft-ui-egui\n"
                 "SCOPE_KIND=packages\n"
                 "VERDICT=SKIP\n"
                 "NEW_FAILURES=0\n"
                 "CHECKS=fmt:skipped|layers:skipped|clippy:skipped\n"
                 "SHA=%s\n"
                 "AT=1793120144\n"
                 "DEFERRED=complete-gate-alive\n" % HEAD)
    st, err = run({"phase": "gated", "issue": 1, "branch": "b",
                   "branch_sha": HEAD, "pr": 1, "review": "aprobado"},
                  loop_dir=defer_loop, want_err=True, slot="0")
    check("the state exposes the deferral",
          st.get("scope_deferred") == "complete-gate-alive",
          repr(st.get("scope_deferred")))
    check("the refusal names the deferral",
          "DEFERRED" in err and "postponed" in err, err[-400:])


def test_the_watchdog_is_the_only_one_that_kills_the_gate():
    """The WATCHDOG is the only authority that kills the complete gate.

    WHY (27-10): the watchdog was rebuilt so that it does NOT kill a gate
    that is making progress (the age alone killed two gates that were
    working, 2 h 50 min of CPU each). That guarantee only holds if the
    WATCHDOG is the one that kills: a model that reads a log with two tests
    that take 100 minutes may decide on its own that the gate is hung and
    kill it. That kill is unmeasured, it does not write `EXIT=124` in the
    log (so the state waits GATE_TIMEOUT_MIN for a verdict that is never
    coming) and it can kill a gate that was about to finish.

    The rule is EXECUTABLE: it checks the prompt (the model is told) and the
    supervisor (the only place that kills a gate is the branch of the
    watchdog's verdict).
    """
    print("32. the watchdog is the only authority that kills the complete gate")

    with open(os.path.join(LOOP, "prompts", "iteration.md"),
              encoding="utf-8") as fh:
        prompt = fh.read()
    check("the prompt says that the watchdog is the only authority",
          "UNICA autoridad que mata el gate completo" in prompt
          or "ÚNICA autoridad que mata el gate completo" in prompt, "")
    check("the prompt forbids killing the gate by hand",
          "no lo mates" in prompt and "pkill" in prompt, "")
    check("the prompt says that a killed gate leaves EXIT=124",
          "EXIT=124" in prompt, "")

    with open(os.path.join(LOOP, "bin", "supervisor.sh"),
              encoding="utf-8") as fh:
        sup = fh.read()
    # The kills of the supervisor are NOT all kills of the gate: one is the
    # cargo that the killed turn left in the worktree of the issue and
    # another one is the token watchdog of the turn. The GATE is only killed
    # where GATE_PID appears, and that must be ONE place: the branch of the
    # watchdog's verdict.
    lines = sup.splitlines()
    gate_kills = [(i + 1, line) for i, line in enumerate(lines)
                  if "kill -TERM" in line and "GATE_PID" in line]
    check("the supervisor kills the gate in ONE place", len(gate_kills) == 1,
          "%d places: %s" % (len(gate_kills),
                             ", ".join(str(n) for n, _ in gate_kills)))
    verdict_at = sup.find('case "$WD_VERDICT" in')
    branch_at = sup.find("stale|stuck|expired)", verdict_at)
    kill_at = sup.find("kill -TERM", branch_at) if branch_at != -1 else -1
    check("that place is the branch of the watchdog's verdict",
          verdict_at != -1 and branch_at != -1 and kill_at > branch_at,
          "verdict at %d, branch at %d, kill at %d"
          % (verdict_at, branch_at, kill_at))
    check("the gate is killed as a group (the gate and its children)",
          len(gate_kills) == 1 and '"-$GATE_PID"' in gate_kills[0][1],
          "")
    hard = [(i + 1, line) for i, line in enumerate(lines)
            if "kill -KILL" in line and "GATE_PID" in line]
    check("the gate is killed hard in the same place", len(hard) == 1,
          "%d places" % len(hard))
    if len(gate_kills) == 1 and len(hard) == 1:
        check("the hard kill follows the polite one",
              0 < hard[0][0] - gate_kills[0][0] <= 6,
              "term at %d, kill at %d" % (gate_kills[0][0], hard[0][0]))
    else:
        check("the hard kill follows the polite one", False, "")
    check("the killed gate is marked as failed (EXIT=124)",
          "EXIT=124" in sup, "")


def test_the_death_of_a_gate_without_exit_is_recorded():
    """The death of a gate that did not write EXIT= is RECORDED (reaped).

    WHY (27-10): the watchdog is the only authority that KILLS the complete
    gate, and when it kills it, it writes EXIT=124 in the log so the state
    knows the gate did not pass. But the gate can die in other ways (a hand
    kill, a crash, the OOM killer): nobody writes EXIT= and the log keeps
    saying "running" for ever, so the state waits GATE_TIMEOUT_MIN for a
    verdict that is never coming.

    The reaper does NOT kill anything (the gate is already dead when it
    runs): it writes the record of a death that already happened.

    The rule is EXECUTABLE: it runs the reaper against gates of a test
    directory: a dead gate, a live gate, a gate that already said how it
    ended and the log of another run.
    """
    print("33. the death of a gate without EXIT= is recorded")
    reaper = os.path.join(LOOP, "bin", "gate-reap.sh")
    check("the reaper exists", os.path.isfile(reaper), reaper)
    check("the reaper is executable", os.access(reaper, os.X_OK), "")

    with open(reaper, encoding="utf-8") as fh:
        src = fh.read()
    check("the reaper does not kill anything",
          "kill -TERM" not in src and "kill -KILL" not in src
          and "pkill" not in src, "")
    check("the reaper only looks at the pid (kill -0)",
          "kill -0" in src, "")

    with open(os.path.join(LOOP, "bin", "supervisor.sh"),
              encoding="utf-8") as fh:
        sup = fh.read()
    check("the supervisor calls the reaper",
          sup.count("bin/gate-reap.sh") == 1,
          "%d calls" % sup.count("bin/gate-reap.sh"))

    sha = "0efbe540283656ada180eca5b3b7b33f62bd777b"
    short = sha[:12]
    work = os.path.join(ROOT, "loop-reap")
    os.makedirs(work, exist_ok=True)

    def reap(pid, log_name, sha_arg=sha):
        pid_file = os.path.join(work, "pid")
        with open(pid_file, "w", encoding="utf-8") as fh:
            fh.write(str(pid))
        out = subprocess.run(
            ["bash", reaper, "--pid-file", pid_file,
             "--log", os.path.join(work, log_name), "--sha", sha_arg],
            capture_output=True, text=True, timeout=60)
        verdict = ""
        for line in out.stdout.splitlines():
            if line.startswith("VERDICT="):
                verdict = line.split("=", 1)[1]
                break
        return verdict, out

    def log_text(name):
        path = os.path.join(work, name)
        if not os.path.isfile(path):
            return ""
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()

    # (1) a gate that died without writing EXIT=: the death is recorded
    name = "gate-7058-x-%s.log" % short
    with open(os.path.join(work, name), "w", encoding="utf-8") as fh:
        fh.write("running tests\n")
    dead = subprocess.Popen(["sleep", "120"])
    dead.kill()
    dead.wait()
    verdict, out = reap(dead.pid, name)
    check("a dead gate without EXIT= is recorded as killed",
          verdict == "reaped", out.stdout + out.stderr)
    check("the record is EXIT=124 (the code of timeout: it did not pass)",
          "EXIT=124" in log_text(name), log_text(name)[-80:])

    # (2) a gate that is alive: nothing is written
    name2 = "gate-7058-z-%s.log" % short
    with open(os.path.join(work, name2), "w", encoding="utf-8") as fh:
        fh.write("running tests\n")
    alive = subprocess.Popen(["sleep", "120"])
    time.sleep(0.3)
    try:
        verdict, out = reap(alive.pid, name2)
        check("a live gate is left alone", verdict == "alive",
              out.stdout + out.stderr)
        check("the log of a live gate is not touched",
              "EXIT=" not in log_text(name2), log_text(name2)[-80:])
    finally:
        alive.kill()
        alive.wait()

    # (3) a gate that already said how it ended: nothing is added
    name3 = "gate-7058-w-%s.log" % short
    with open(os.path.join(work, name3), "w", encoding="utf-8") as fh:
        fh.write("running tests\nEXIT=0\n")
    verdict, out = reap(dead.pid, name3)
    check("a gate that already has an EXIT= is not touched",
          verdict == "already-recorded", out.stdout + out.stderr)
    check("the log keeps its own EXIT=",
          log_text(name3).count("EXIT=") == 1, log_text(name3)[-80:])

    # (4) the log of ANOTHER run: it is not touched
    name4 = "gate-7058-v-aaaaaaaaaaaa.log"
    with open(os.path.join(work, name4), "w", encoding="utf-8") as fh:
        fh.write("running tests\n")
    verdict, out = reap(dead.pid, name4)
    check("the log of another run is not touched",
          verdict == "other-run", out.stdout + out.stderr)
    check("the log of another run keeps no EXIT=",
          "EXIT=" not in log_text(name4), log_text(name4)[-80:])


def test_the_orphans_of_a_dead_gate_are_killed():
    """The orphans of a DEAD gate are killed.

    WHY (27-10): nextest runs every test in its OWN process group, so the
    kill of the GROUP of the gate does not reach the test binaries: the
    measured ones are 19 GB and 16 GB. When the gate dies (killed by the
    watchdog, killed by hand, crashed or killed by the OOM killer) its
    children stay alive as orphans and keep tens of gigabytes of the 62 GB
    of the machine. The next gate then finds the RAM already taken: that is
    the OOM that cost the 2 h 50 min of the run of the day.

    The rule is EXECUTABLE: the two functions of the supervisor are
    extracted and run against processes of a test directory: the process
    that works in the gate worktree is an orphan and dies; the gate itself
    and the processes of another directory are left alone.
    """
    print("34. the orphans of a dead gate are killed")
    with open(os.path.join(LOOP, "bin", "supervisor.sh"),
              encoding="utf-8") as fh:
        sup = fh.read()

    find_fn = bash_func(sup, "gate_orphan_pids")
    kill_fn = bash_func(sup, "kill_gate_orphans")
    check("the supervisor knows how to find the orphans of the gate",
          bool(find_fn.strip()), "")
    check("the supervisor knows how to kill them", bool(kill_fn.strip()), "")

    # The cleanup lives in the block of the watchdog: the kill of the gate
    # and the cleanup of its orphans are the same decision.
    block = bash_between(sup, "# --- gate watchdog",
                         "# --- precondition 3: gh")
    check("the cleanup of the orphans is in the block of the watchdog",
          "kill_gate_orphans" in block and "gate_orphan_pids" in block, "")
    reaper_block = bash_between(sup, "# --- the reaper of the dead gate",
                                "# --- precondition 3: gh")
    check("the reaper also cleans the orphans of the gate it records",
          "kill_gate_orphans" in reaper_block, "")

    # The orphans are cleaned AFTER the group of the gate is killed: before
    # it, the gate itself would still be alive and it is not an orphan.
    i_group = block.index('kill -KILL "-$GATE_PID"')
    check("the orphans are cleaned after the group of the gate is killed",
          block.index("kill_gate_orphans", i_group) > i_group, "")

    # The pattern of the cwd is compared with the REAL path of the worktree:
    # the cwd of /proc is always resolved, so a worktree with a `..` in it
    # would never match and the orphans would survive.
    check("the worktree of the gate is normalized",
          "readlink -f" in sup and "GATE_WORKTREE" in sup, "")

    work = os.path.realpath(os.path.join(ROOT, "gate-wt"))
    other = os.path.realpath(os.path.join(ROOT, "not-gate-wt"))
    os.makedirs(work, exist_ok=True)
    os.makedirs(other, exist_ok=True)

    script = write_script(os.path.join(ROOT, "orphans.sh"), r"""
set -uo pipefail
GATE_WORKTREE="$1"
MODE="$2"
log() { echo "LOG: $*"; }
""")
    with io.open(script, "a", encoding="utf-8") as fh:
        fh.write(find_fn)
        fh.write(kill_fn)
        fh.write('case "$MODE" in\n'
                 '  find) gate_orphan_pids ;;\n'
                 '  kill) kill_gate_orphans ;;\n'
                 'esac\n')

    # (1) a process that works in the gate worktree: it is an orphan
    orphan = subprocess.Popen(["sleep", "300"], cwd=work)
    # (2) the gate itself: it is NOT an orphan
    gate = subprocess.Popen(
        ["bash", "-c", "exec -a 'solidcraft-gate-slot:default' sleep 300"],
        cwd=work)
    # (3) the nextest of a gate that is being launched: it is NOT an orphan
    launcher = subprocess.Popen(
        ["bash", "-c", "exec -a 'cargo-nextest nextest run' sleep 300"],
        cwd=work)
    # (4) a process of another directory: it is NOT an orphan
    foreign = subprocess.Popen(["sleep", "300"], cwd=other)
    try:
        time.sleep(0.5)
        out = run_bash(script, [work, "find"])
        pids = [p.strip() for p in out.stdout.splitlines() if p.strip()]
        check("the process of the gate worktree is an orphan",
              str(orphan.pid) in pids, out.stdout + out.stderr)
        check("the gate itself is not an orphan",
              str(gate.pid) not in pids, out.stdout + out.stderr)
        check("the nextest that is being launched is not an orphan",
              str(launcher.pid) not in pids, out.stdout + out.stderr)
        check("a process of another directory is not an orphan",
              str(foreign.pid) not in pids, out.stdout + out.stderr)

        # the safety guard: with an empty GATE_WORKTREE the pattern of the
        # cwd would be "/*" and it would match every process of the machine
        out = run_bash(script, ["", "find"])
        check("without a gate worktree no process of the machine is listed",
              not [p for p in out.stdout.splitlines() if p.strip()],
              out.stdout[-300:] + out.stderr[-300:])

        # (2) the kill: the orphan dies, the others live
        out = run_bash(script, [work, "kill"])
        time.sleep(0.5)
        check("the orphan of the dead gate is killed",
              orphan.poll() is not None, out.stdout + out.stderr)
        check("the gate itself is not killed by the cleanup",
              gate.poll() is None, "")
        check("the nextest that is being launched is not killed",
              launcher.poll() is None, "")
        check("a process of another directory is not killed",
              foreign.poll() is None, "")
    finally:
        for proc in (orphan, gate, launcher, foreign):
            if proc.poll() is None:
                proc.kill()
                proc.wait()


def test_the_token_counter_is_sampled():
    """The spend is measured from time to time, not on every beat.

    WHY: the counter sweeps the whole database of OpenCode. Running it on
    every five minutes spends CPU on a number that does not move in five
    minutes. The snapshot samples it and carries the last value forward,
    so the daily report keeps finding the field it reads.

    The rule is EXECUTABLE: the test runs the snapshot with a counter of
    its own and counts how many times that counter was called.
    """
    print("50. the token counter is sampled, not measured on every beat")
    script = os.path.join(LOOP, "bin", "metrics-snapshot.sh")
    if not os.path.exists(script):
        check("the snapshot of the metrics is there", False, script)
        return
    check("the snapshot of the metrics is a valid bash",
          subprocess.run(["bash", "-n", script], capture_output=True,
                         text=True).returncode == 0)

    root = tempfile.mkdtemp(prefix="rule50-")
    try:
        good = ("#!/usr/bin/env bash\n"
                "printf 'x\\n' >> \"${STUB_COUNT}\"\n"
                "printf 'tokens_24h=111 cost_24h=0.5 sessions_24h=2\\n'\n")
        down = ("#!/usr/bin/env bash\n"
                "printf 'x\\n' >> \"${STUB_COUNT}\"\n"
                "exit 1\n")

        def make_loop(name, body):
            loop = os.path.join(root, name)
            os.makedirs(os.path.join(loop, "bin"), exist_ok=True)
            os.makedirs(os.path.join(loop, "logs", "turns"), exist_ok=True)
            counter = os.path.join(loop, "bin", "oc-tokens")
            write_script(counter, body)
            os.chmod(counter, 0o755)
            return loop

        def snap(loop, count_file, knob="60"):
            env = dict(os.environ)
            env["LOOP_DIR"] = loop
            env["STUB_COUNT"] = count_file
            env["METRICS_TOKEN_SAMPLE_MIN"] = knob
            return subprocess.run(["bash", script], capture_output=True,
                                  text=True, env=env, timeout=60)

        def calls(count_file):
            if not os.path.exists(count_file):
                return 0
            with open(count_file, encoding="utf-8") as fh:
                return len([line for line in fh if line.strip()])

        def lines_of(loop):
            path = os.path.join(loop, "metrics.log")
            if not os.path.exists(path):
                return []
            with open(path, encoding="utf-8", errors="replace") as fh:
                return [line for line in fh if line.strip()]

        # --- the counter is NOT called on every beat ------------------------
        loop = make_loop("sampled", good)
        count = os.path.join(root, "count-sampled")
        first = snap(loop, count)
        check("the snapshot goes on when the counter answers",
              first.returncode == 0, first.stderr[-300:])
        check("the counter is called once", calls(count) == 1, calls(count))
        snap(loop, count)
        snap(loop, count)
        check("the counter is not called on every beat", calls(count) == 1,
              calls(count))
        written = lines_of(loop)
        check("the last value is carried forward in every line",
              len(written) == 3
              and all("tokens_24h=111" in line for line in written), written)

        # --- the knob can turn the sampling off -----------------------------
        loop0 = make_loop("every-beat", good)
        count0 = os.path.join(root, "count-every")
        for _ in range(3):
            snap(loop0, count0, knob="0")
        check("the knob of the sampling can turn the sampling off",
              calls(count0) == 3, calls(count0))

        # --- a broken knob is the default, not a surprise -------------------
        loopb = make_loop("broken-knob", good)
        countb = os.path.join(root, "count-broken")
        for _ in range(3):
            snap(loopb, countb, knob="abc")
        check("a broken knob is the default, not a surprise",
              calls(countb) == 1, calls(countb))

        # --- a counter that is down does not break the snapshot -------------
        loopd = make_loop("down", down)
        countd = os.path.join(root, "count-down")
        down_run = snap(loopd, countd)
        check("a counter that is down does not break the snapshot",
              down_run.returncode == 0, down_run.stderr[-300:])
        down_lines = lines_of(loopd)
        check("the line is written even without the counter",
              len(down_lines) == 1 and "phase=" in down_lines[0], down_lines)

        # --- the counter is called again when the minutes passed ------------
        loopa = make_loop("again", good)
        counta = os.path.join(root, "count-again")
        snap(loopa, counta)
        state = os.path.join(loopa, "tokens-sample.state")
        with open(state, encoding="utf-8") as fh:
            old = fh.read()
        old_at = int(re.search(r"^at=(\d+)$", old, re.M).group(1))
        with open(state, "w", encoding="utf-8") as fh:
            fh.write(re.sub(r"^at=\d+$", "at=%d" % (old_at - 3600), old,
                            flags=re.M))
        snap(loopa, counta)
        check("the counter is called again when the minutes passed",
              calls(counta) == 2, calls(counta))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main():
    global ROOT, LOOP_DIR, BIN_DIR, HOME_DIR
    ROOT = tempfile.mkdtemp(prefix="loop-rules-world-")
    HOME_DIR = os.path.join(ROOT, "home")
    BIN_DIR = os.path.join(ROOT, "bin")
    os.makedirs(HOME_DIR, exist_ok=True)
    os.makedirs(BIN_DIR, exist_ok=True)
    gh = os.path.join(BIN_DIR, "gh")
    with open(gh, "w", encoding="utf-8") as fh:
        fh.write(FAKE_GH)
    os.chmod(gh, 0o755)
    # the HOME of the tests: the worktree of an issue is never found there
    os.environ["HOME"] = HOME_DIR
    # the loop of the tests: its own logs, its own gate.sha, its own script
    LOOP_DIR = make_loop_dir(ROOT, HEAD)
    try:
        return run_tests()
    finally:
        shutil.rmtree(ROOT, ignore_errors=True)


def test_the_rows_of_the_ledger_are_history():
    """The rows of the ledger are HISTORY: a past `next` is not a plan.

    WHY (27-10): the digest of a slot carries the last rows of the ledger
    and every row carries the `next` that the model of that turn wrote. A
    row of the slot 1 said "next: kill the group of the hung complete gate
    (pid 1594753, kill by PGID)" and that row stayed in the digest of the
    following turns: the watchdog is the ONLY authority that kills the
    complete gate (rule 32), a model that kills it by hand breaks the
    evidence of the watchdog's verdict, and the plan of the row is about a
    gate that is already dead.

    The rule is EXECUTABLE: the supervisor is asked for the digest of a slot
    whose ledger has a row with a `next` of that kind, and the digest has to
    say that the rows are history and that a past `next` is not a plan.
    """
    print("35. the rows of the ledger are history: a past `next` is not a plan")
    supervisor = os.path.join(LOOP, "bin", "supervisor.sh")
    loop = os.path.join(ROOT, "loop-ledger-history")
    os.makedirs(os.path.join(loop, "state"), exist_ok=True)
    view = {"phase": "idle", "issue": 0, "branch": "", "pr": 0, "slot": "0",
            "counters": {}, "triage": {}, "published": {}, "prs": {},
            "report": {}, "attempts": {}, "merge_verdict": {}, "version": 3}
    with open(os.path.join(loop, "state", "slot-0.json"), "w",
              encoding="utf-8") as fh:
        json.dump(view, fh, indent=2)
    with open(os.path.join(loop, "ledger.md"), "w", encoding="utf-8") as fh:
        fh.write("| 2026-10-27T17:06Z | 7058 | failed | rojo | "
                 "próximo: matar el grupo de procesos del gate completo "
                 "colgado (pid 1594753, kill por PGID) |\n")

    env = dict(os.environ)
    env["LOOP_DIR"] = loop
    env["SLOT"] = "0"
    out = subprocess.run(["bash", supervisor, "--digest", "0"],
                         capture_output=True, text=True, env=env, timeout=120)
    check("the query of the digest works", out.returncode == 0, out.stderr[-300:])
    digest = out.stdout
    flat = " ".join(digest.split()).lower()
    check("the digest carries the rows of the ledger",
          "matar el grupo" in digest, digest[:400])
    check("the digest says that the rows are history", "historia" in flat,
          digest[:600])
    check("the digest says that a past `next` is not a plan to execute",
          "no es un plan para ejecutar" in flat, digest[:600])

    with open(os.path.join(LOOP, "prompts", "iteration.md"),
              encoding="utf-8") as fh:
        prompt = fh.read()
    prompt_flat = " ".join(prompt.split()).lower()
    check("the prompt says that the rows of the ledger are history",
          "historia" in prompt_flat and "próximo" in prompt_flat, "")
    check("the prompt says that the watchdog is the only one that kills it",
          "única autoridad que lo mata" in prompt_flat
          or "unica autoridad que lo mata" in prompt_flat, "")


def test_the_scoped_gate_counts_the_check_of_the_workspace():
    """The scoped gate counts the CHECK of the workspace.

    WHY (27-10): the scoped gate runs the tests of the packages the change
    touches. A change that breaks the COMPILATION of another package passes
    the tests of its own packages and publishes a PR that does not build:
    the CI of the upstream catches it (a red check), but the local gate is
    supposed to be the fair one, and the fair one compiles the workspace.

    So the line of the checks carries a FOURTH check, the one of the
    workspace: `fmt:ok|layers:ok|clippy:ok|check:ok`. The `check:` is `ok`
    when it ran and passed, `skipped` when the configuration turned it off
    (that is tolerated: the configuration said so) and `fail` when it
    failed. A `fail` is NOT a green gate.

    The rule is EXECUTABLE: the module of the supervisor is asked, not the
    source of it.
    """
    print("36. the scoped gate counts the check of the workspace")
    st = load_state()
    green = "fmt:ok|layers:ok|clippy:ok|check:ok"
    check("a workspace that compiled is ok", st.scope_checks_ok(green), green)
    check("a workspace check that was skipped is tolerated",
          st.scope_checks_ok("fmt:ok|layers:ok|clippy:ok|check:skipped"))
    check("a line of checks without the workspace is tolerated",
          st.scope_checks_ok("fmt:ok|layers:ok|clippy:ok"))
    check("a workspace that did not compile is NOT ok",
          not st.scope_checks_ok("fmt:ok|layers:ok|clippy:ok|check:fail"))
    check("a clippy that was skipped is NOT ok",
          not st.scope_checks_ok("fmt:ok|layers:ok|clippy:skipped|check:ok"))
    check("an empty line of checks is NOT ok", not st.scope_checks_ok(""))

    base = {"scope_verdict": "VERDE-SCOPE", "scope_status": "finished",
            "scope_kind": "packages", "scope_new_failures": "0"}
    ok, why = st.scoped_gate_green(dict(base, scope_checks=green))
    check("a scoped gate with a workspace that compiles is green", ok, why)
    ok, why = st.scoped_gate_green(
        dict(base, scope_checks="fmt:ok|layers:ok|clippy:ok|check:fail"))
    check("a scoped gate with a workspace that does not compile is NOT green",
          not ok, why)


def test_the_claim_of_an_issue_is_decided_in_code():
    """The claim of an issue is decided in CODE, not in a paragraph.

    WHY (27-10): a prompt that says "do not claim an issue that is already
    claimed" is forgotten once in a while, and a duplicate PR is a
    duplicate PR. The rules of the claim live in `bin/claim-guard.sh`: the
    issue is OPEN, it carries no excluded label, no OPEN PR of ANY author
    holds its claim (the bodies of the PRs AND the timeline of the issue
    are consulted) and the queue of our own PRs is below the ceiling.

    The exit codes are the contract: 0 the claim can be made, 2 an excluded
    label, 3 an open PR already holds it, 4 the issue is closed, 5 the
    ceiling of our PRs, 6 GitHub could not be asked (the guard does NOT
    know, and a claim without a check is a duplicate waiting to happen).

    The rule is EXECUTABLE: the guard is RUN against a `gh` of the tests
    whose answers come from the environment.
    """
    print("37. the claim of an issue is decided in code")
    guard = os.path.join(LOOP, "bin", "claim-guard.sh")
    if not os.path.exists(guard):
        check("the guard of the claim is there", False, guard)
        return
    check("the guard of the claim is executable", os.access(guard, os.X_OK))
    syntax = subprocess.run(["bash", "-n", guard], capture_output=True,
                             text=True)
    check("the guard of the claim is a valid bash", syntax.returncode == 0,
          syntax.stderr[-200:])

    # The `gh` of the tests: no GitHub, no network. The answers come from
    # the environment of the test.
    stub_dir = os.path.join(ROOT, "guard-bin")
    os.makedirs(stub_dir, exist_ok=True)
    stub = os.path.join(stub_dir, "gh")
    write_script(stub, """#!/usr/bin/env bash
case "${1:-}" in
  issue)
    if [ "${2:-}" = "view" ]; then printf '%s' "${GUARD_ISSUE:-}"; exit 0; fi
    ;;
  pr)
    if [ "${2:-}" = "list" ]; then
      for a in "$@"; do
        if [ "$a" = "--author" ]; then
          printf '%s' "${GUARD_OUR_PRS:-}"
          exit 0
        fi
      done
      # THE --jq IS HONORED (2026-11-18): the arbiter of the claim
      # (bin/claim-verify.sh) filters the list SERVER-SIDE, with
      # `gh pr list --jq`. A stub that ignores --jq returns the raw JSON,
      # the arbiter parses it as if it were the filtered list, and every
      # line of the JSON becomes a false competitor: the guard then says
      # "the open PR(s) 111 hold the claim" for an issue that is FREE.
      #
      # The REAL jq is used, not an approximation: the program of the
      # arbiter has a regex, strips the noise of upstream, drops the
      # references to other repositories and excludes the pull request
      # whose number IS the issue. A stub that only looks for a '#' would
      # answer different questions than the real one, and a test that
      # passes with the approximation would fail with the real filter.
      jq_filter=""
      prev=""
      for a in "$@"; do
        if [ "$prev" = "--jq" ]; then jq_filter="$a"; fi
        case "$a" in --jq=*) jq_filter="${a#--jq=}" ;; esac
        prev="$a"
      done
      if [ -z "$jq_filter" ]; then
        printf '%s' "${GUARD_PRS:-}"
        exit 0
      fi
      if ! command -v jq >/dev/null 2>&1; then
        echo "the stub of gh needs jq to honor --jq like the real gh" >&2
        exit 1
      fi
      printf '%s' "${GUARD_PRS:-}" | jq -r "$jq_filter"
      exit 0
    fi
    ;;
  api)
    printf '%s' "${GUARD_CROSS:-}"
    exit 0
    ;;
esac
exit 1
""")
    os.chmod(stub, 0o755)

    loop = os.path.join(ROOT, "loop-claim-guard")
    os.makedirs(loop, exist_ok=True)
    write_script(os.path.join(loop, "config.env"),
                 "MAINT_THRESHOLD=10\n"
                 # The value is QUOTED, exactly like the real config.env: a
                 # label with a space ("in progress") is a syntax error in a
                 # file that is SOURCED as bash, and the guard reads the
                 # configuration that way. The fixture wrote it unquoted and
                 # the source failed in the middle of the line, so the guard
                 # ran with the WRONG policy (the labels of the exclusion
                 # were not read at all). The rule that failed was not about
                 # the claim: it was about a broken fixture.
                 "CLAIM_EXCLUDED_LABELS=\"in progress,kernel-paused,"
                 "status:decision,needs-info,area:kernel\"\n"
                 "CLAIM_WANTED_LABEL=bug\n")

    def run_guard(issue, issue_json, prs, our_prs, cross):
        env = dict(os.environ)
        env["PATH"] = stub_dir + os.pathsep + env.get("PATH", "")
        env["LOOP_DIR"] = loop
        env["GUARD_ISSUE"] = issue_json
        env["GUARD_PRS"] = prs
        env["GUARD_OUR_PRS"] = our_prs
        env["GUARD_CROSS"] = cross
        return subprocess.run(["bash", guard, str(issue)], env=env,
                              capture_output=True, text=True, timeout=120)

    open_issue = json.dumps({"number": 1234, "state": "OPEN",
                              "title": "a bug", "labels": [{"name": "bug"}]})
    taken_issue = json.dumps({"number": 1234, "state": "OPEN",
                              "title": "a bug",
                              "labels": [{"name": "bug"},
                                         {"name": "in progress"}]})
    closed_issue = json.dumps({"number": 1234, "state": "CLOSED",
                               "title": "a bug", "labels": [{"name": "bug"}]})
    other_pr = json.dumps([{"number": 111, "title": "another fix",
                            "body": "nothing to see here"}])
    claiming_pr = json.dumps([{"number": 111, "title": "fix",
                               "body": "closes #1234"}])
    ours_7 = json.dumps([{"number": 7000 + n} for n in range(7)])
    ours_9 = json.dumps([{"number": 7000 + n} for n in range(9)])
    ours_10 = json.dumps([{"number": 7000 + n} for n in range(10)])

    out = run_guard(1234, open_issue, other_pr, ours_7, "")
    check("an open issue with no claim and a free queue can be claimed",
          out.returncode == 0, f"{out.returncode} {out.stdout[-200:]}")
    out = run_guard(1234, taken_issue, other_pr, ours_7, "")
    check("an issue with an excluded label is dropped",
          out.returncode == 2, f"{out.returncode} {out.stdout[-200:]}")
    out = run_guard(1234, open_issue, claiming_pr, ours_7, "")
    check("an issue claimed by the body of an open PR is dropped",
          out.returncode == 3, f"{out.returncode} {out.stdout[-200:]}")
    out = run_guard(1234, open_issue, other_pr, ours_7, "111\n")
    check("an issue claimed by the timeline of an open PR is dropped",
          out.returncode == 3, f"{out.returncode} {out.stdout[-200:]}")
    out = run_guard(1234, closed_issue, other_pr, ours_7, "")
    check("a closed issue is dropped",
          out.returncode == 4, f"{out.returncode} {out.stdout[-200:]}")
    out = run_guard(1234, open_issue, other_pr, ours_10, "")
    check("the ceiling of our open PRs stops the claim",
          out.returncode == 5, f"{out.returncode} {out.stdout[-200:]}")
    out = run_guard(1234, open_issue, "", ours_7, "")
    check("a GitHub that does not answer stops the claim",
          out.returncode == 6, f"{out.returncode} {out.stdout[-200:]}")
    out = run_guard(1234, open_issue, other_pr, ours_9, "")
    check("a queue below the ceiling can still claim",
          out.returncode == 0, f"{out.returncode} {out.stdout[-200:]}")

    # The contract is DOCUMENTED: the codes of the guard are the codes the
    # prompts tell the model to read, and the labels and the ceiling come
    # from the configuration (the prompt does not repeat them).
    with open(guard, encoding="utf-8") as fh:
        head = fh.read()[:4000]
    documented = {int(m) for m in re.findall(r"^#\s+(\d+)\s{2,}", head, re.M)}
    for code in (0, 2, 3, 4, 5, 6):
        check(f"the guard documents the exit code {code}", code in documented,
              sorted(documented))
    for prompt in ("triage.md", "claim.md"):
        path = os.path.join(LOOP, "prompts", prompt)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        missing = [c for c in (0, 2, 3, 4, 5, 6)
                   if not re.search(r"\|\s*%d\s*\|" % c, text)]
        check(f"the prompt {prompt} documents every exit code", not missing,
              missing)
    with open(os.path.join(LOOP, "config.env"), encoding="utf-8") as fh:
        config = fh.read()
    check("the configuration carries the excluded labels of the claim",
          "CLAIM_EXCLUDED_LABELS" in config)
    check("the configuration carries the ceiling of our open PRs",
          re.search(r"^MAINT_THRESHOLD=\s*\d+", config, re.M) is not None)
    agents = agents_dir()
    for name in ("sc-claim.md", "sc-triage.md"):
        path = os.path.join(agents, name)
        if not os.path.exists(path):
            check(f"the agent {name} is there", False, path)
            continue
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        allowed = re.search(
            r"resource:\s*\"[^\"]*claim-guard\.sh[^\"]*\"\s*\n\s*effect:\s*allow",
            text)
        check(f"the agent {name} allows the guard of the claim",
              allowed is not None, path)


def test_the_complete_gate_is_off_by_default():
    """The COMPLETE gate is off by default: the fair gate is the one of the scope.

    WHY (27-10): the complete gate (`cargo xtask ci`) takes 90-180 min of CPU
    and ~35 GB of RAM on a box of 62 GB without swap. The OOM killer takes
    the BIGGEST process: on 27-10 it took the complete gate of another slot
    and 2 h 50 min of work were lost. The upstream CI runs the full suite
    anyway when a maintainer adds `approved-for-ci`, and the merge queue
    runs it again on main: the local complete gate does NOT prevent a single
    red check, it only costs hours of CPU and tens of GB of RAM.

    So `GATE_COMPLETE_MODE=off` and the exit code 11 says "disabled on
    purpose": the queue removes the request (it can never be served) and the
    supervisor reports the refusal with its reason.

    The rule is EXECUTABLE: start-gate.sh is RUN in a loop directory of the
    tests and its exit code is looked at; the queue is RUN with a stub of
    start-gate.sh; the refusal of the supervisor is extracted and RUN.
    """
    print("38. the complete gate is off by default")
    with open(os.path.join(LOOP, "config.env"), encoding="utf-8") as fh:
        config = fh.read()
    check("the configuration turns the complete gate off",
          re.search(r"^GATE_COMPLETE_MODE=\s*off\s*$", config, re.M) is not None)

    loop = os.path.join(ROOT, "loop-gate-off")
    os.makedirs(loop, exist_ok=True)
    write_script(os.path.join(loop, "config.env"), "GATE_COMPLETE_MODE=off\n")
    start = os.path.join(LOOP, "bin", "start-gate.sh")

    def run_start(extra_env=None):
        env = dict(os.environ)
        env["LOOP_DIR"] = loop
        env.pop("GATE_COMPLETE_MODE", None)
        env.pop("SOLIDCRAFT_GATE_FORCE", None)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["bash", start, "deadbeef", "1234", "slug", "--slot", "tests",
             "--worktree", os.path.join(loop, "no-worktree")],
            env=env, capture_output=True, text=True, timeout=120)

    out = run_start()
    check("start-gate.sh says that the complete gate is disabled",
          out.returncode == 11, f"{out.returncode} {out.stderr[-200:]}")
    check("the reason of the refusal is written",
          "complete gate is disabled" in out.stderr, out.stderr[-200:])
    out = run_start({"SOLIDCRAFT_GATE_FORCE": "1"})
    check("the manual override does not refuse the launch",
          out.returncode != 11, f"{out.returncode} {out.stderr[-200:]}")

    # The queue: a request of a gate that can never be served leaves the
    # queue (otherwise the timer retries it every two minutes, forever).
    ql = os.path.join(ROOT, "loop-gate-queue")
    os.makedirs(os.path.join(ql, "bin"), exist_ok=True)
    os.makedirs(os.path.join(ql, "gates", "tests"), exist_ok=True)
    stub = os.path.join(ql, "bin", "start-gate.sh")
    write_script(stub, "#!/usr/bin/env bash\nexit 11\n")
    os.chmod(stub, 0o755)
    request = os.path.join(ql, "gates", "tests", "request")
    write_script(request, "sha=deadbeef\nissue=1234\nrequested_at=%d\n"
                 % int(time.time()))
    env = dict(os.environ)
    env["LOOP_DIR"] = ql
    out = subprocess.run(["bash", os.path.join(LOOP, "bin", "gate-queue.sh")],
                         env=env, capture_output=True, text=True, timeout=120)
    check("the queue does not fail when the complete gate is disabled",
          out.returncode == 0, f"{out.returncode} {out.stderr[-200:]}")
    check("the request of a gate that can never be served leaves the queue",
          not os.path.exists(request), request)

    # The supervisor: the refusal of the turn says WHY, and an exit code
    # that is not a refusal says nothing.
    supervisor = os.path.join(LOOP, "bin", "supervisor.sh")
    with open(supervisor, encoding="utf-8") as fh:
        src = fh.read()
    try:
        func = bash_func(src, "gate_refusals_of_turn")
    except ValueError as exc:
        check("the supervisor has the function of the refusals", False, str(exc))
        return
    harness = os.path.join(ROOT, "harness-refusals.sh")
    write_script(harness, 'set -uo pipefail\nTURN_LOG="$1"\n' + func +
                 "\ngate_refusals_of_turn\n")

    def refusals(exit_code, output):
        log = os.path.join(ROOT, "turn-%s.jsonl" % exit_code)
        entry = {"part": {"type": "tool", "state": {
            "status": "completed", "output": output,
            "metadata": {"metadata": {
                "exit": exit_code,
                "command": ("bash /home/user/.local/share/solidcraft-loop/bin/"
                            "start-gate.sh deadbeef 1234 slug")}}}}}
        with open(log, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")
        out = subprocess.run(["bash", harness, log], capture_output=True,
                             text=True, timeout=60)
        return out.stdout

    said = refusals(11, "the complete gate is disabled (GATE_COMPLETE_MODE=off):"
                          " nothing was launched")
    check("the supervisor reports that the complete gate is disabled",
          "complete gate is disabled" in said, said[:200])
    said = refusals(12, "something else happened")
    check("the supervisor says nothing about an exit that is not a refusal",
          said.strip() == "", said[:200])


# The stub of cargo for the rule of the guard: it compiles nothing, it runs
# nothing and it RECORDS its calls, so the rule can tell that the check of
# the workspace did not run. The sleep knob makes the computation of the
# scope slow, which is the situation the guard is for.
STUB_CARGO_OF_THE_GUARD = r'''#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "${1:-}" >> "${STUB_CARGO_LOG:?}"
case "${1:-}" in
  metadata)
    if [ -n "${STUB_METADATA_SLEEP:-}" ]; then
      sleep "${STUB_METADATA_SLEEP}"
    fi
    root="$(pwd)"
    printf '{"workspace_root":"%s","packages":[],"workspace_members":[],"target_directory":"%s/target","version":1}\n' "$root" "$root"
    exit 0
    ;;
  nextest)
    printf '    Summary [   0.001s] 1 test run: 1 passed, 0 failed, 0 skipped\n'
    exit 0
    ;;
esac
exit 0
'''


def slice_block_of_the_gate(src):
    """The block of the slices of the phases, as bash: from the line that
    gives the slice of the fmt to the LAST line that computes a slice.

    The share of the tests is computed AFTER the branch of the check of the
    workspace (it is what is left of the budget), so the block goes on
    past the `fi`. The block is taken from the gate as it is and it is RUN
    by the rules: the rules do not re-implement the repartition of the
    budget, they execute it and look at what it does."""
    lines = src.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith("FMT_SLICE="):
            start = i
            break
    if start is None:
        return ""
    end = start
    for j in range(start, len(lines)):
        stripped = lines[j].strip()
        if stripped == "" or stripped.startswith("#"):
            continue
        if "_SLICE=" not in stripped and not stripped.startswith(
                ("if", "else", "fi", "then", ")")):
            break
        end = j
    return "\n".join(lines[start:end + 1])


def verdict_block_of_the_gate(src):
    """The block that decides the verdict of the scope, as bash: from the
    line that gives its first value to the `fi` that closes it.

    The block is taken from the gate as it is and it is RUN by the rules:
    the rules do not re-implement the verdict of the scope, they execute
    it and look at what it does with a state of the phases."""
    lines = src.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith("SCOPE_VERDICT="):
            start = i
            break
    if start is None:
        return ""
    for j in range(start, len(lines)):
        if lines[j].strip() == "fi":
            return "\n".join(lines[start:j + 1])
    return ""


def test_the_check_of_the_workspace_only_runs_when_it_fits():
    """The check of the workspace only runs when it FITS.

    WHY (27-10): the check of the workspace is worth its time, but it is NOT
    cheap (4m31s cold, measured the 27-10-2026 on a box of 16 vCPU) and the
    computation of the scope (cargo metadata + affected.py) is part of the
    budget and takes 1-5 min. So a slow turn can arrive at the check with
    less time than the check needs.

    A check that eats the time of the tests leaves the scope WITHOUT tests,
    and a scope without tests is red: the gate of the scope would publish
    nothing, ever. So the check only runs when the time that is left pays
    for the check AND for the tests of the scope. When it does not fit it is
    skipped (a "skipped" says "we did not get to know", it is not a
    failure) and the scope keeps its tests.

    The rule is EXECUTABLE: the block of the slices is taken from the gate
    and RUN with a known budget (the sum of the slices has to be exactly the
    budget: a phase that takes more than its share eats the budget of the
    others, and the ones that suffer are the tests of the scope), and the
    GATE ITSELF is run with a scope that takes longer than the check needs.
    """
    print("39. the check of the workspace only runs when it fits")
    gate = os.path.join(LOOP, "bin", "gate-quick.sh")
    with open(gate, encoding="utf-8") as fh:
        src = fh.read()

    # The slices are EXECUTED, not read: the block is taken from the gate
    # and run with a known budget.
    block = slice_block_of_the_gate(src)
    check("the gate has a block of slices for its phases", block != "",
          "the block of the slices was not found")
    for mode in ("1", "0"):
        env = dict(os.environ)
        env["BUDGET"] = "100"
        env["GATE_CHECK_WORKSPACE"] = mode
        script = (block + "\necho $(( FMT_SLICE + LAYERS_SLICE + CLIPPY_SLICE"
                  " + CHECK_SLICE + NEXTEST_SLICE ))\n")
        out = subprocess.run(["bash", "-c", script], capture_output=True,
                             text=True, env=env, timeout=60)
        check(f"the slices of the phases add up to the budget (the check is {mode})",
              out.stdout.strip() == "100",
              f"{out.stdout.strip()!r} {out.stderr[-200:]}")

    # The guard itself: the check needs the time of the check AND the time
    # of the tests of the scope.
    check("the gate computes what the check needs (the check AND the tests)",
          "CHECK_NEEDED=$(( CHECK_SLICE + NEXTEST_SLICE ))" in src,
          "the guard does not add the two slices")
    check("the gate compares the time that is left with what the check needs",
          '[ "$CHECK_LEFT" -ge "$CHECK_NEEDED" ]' in src,
          "the guard does not compare the time that is left")

    # The GATE ITSELF, with a scope that takes longer than the check needs:
    # the computation of the scope is part of the budget, so a slow turn
    # arrives at the check without time for it. The check has to be skipped
    # WITHOUT running and the scope has to stay green (it keeps its tests).
    root = tempfile.mkdtemp(prefix="loop-check-guard-")
    try:
        repo = os.path.join(root, "repo")
        loop = os.path.join(root, "loop")
        stub = os.path.join(root, "bin")
        os.makedirs(os.path.join(repo, "crates", "alpha", "src"))
        os.makedirs(os.path.join(repo, "scripts", "ci"))
        os.makedirs(os.path.join(loop, "logs"))
        os.makedirs(stub)
        with open(os.path.join(repo, "Cargo.toml"), "w", encoding="utf-8") as fh:
            fh.write("[workspace]\n")
        with open(os.path.join(repo, "crates", "alpha", "src", "lib.rs"),
                  "w", encoding="utf-8") as fh:
            fh.write("pub fn alpha() {}\n")
        # The affected.py of the test: it says that the change touches one
        # package. The real one is not needed to prove the guard.
        with open(os.path.join(repo, "scripts", "ci", "affected.py"),
                  "w", encoding="utf-8") as fh:
            fh.write("import sys\nprint('full=false')\nprint('packages=alpha')\n")
        cargo = os.path.join(stub, "cargo")
        with open(cargo, "w", encoding="utf-8") as fh:
            fh.write(STUB_CARGO_OF_THE_GUARD)
        os.chmod(cargo, 0o755)
        calls_log = os.path.join(root, "cargo.log")
        with open(calls_log, "w", encoding="utf-8") as fh:
            fh.write("")
        git = ["git", "-C", repo]
        subprocess.run(git + ["init", "-q", "-b", "main"], check=True,
                       capture_output=True, text=True, timeout=60)
        subprocess.run(git + ["add", "-A"], check=True, capture_output=True,
                       text=True, timeout=60)
        subprocess.run(git + ["-c", "user.name=rule", "-c",
                              "user.email=rule@example.invalid",
                              "commit", "-qm", "base"], check=True,
                       capture_output=True, text=True, timeout=60)
        base = subprocess.run(git + ["rev-parse", "HEAD"], check=True,
                              capture_output=True, text=True,
                              timeout=60).stdout.strip()
        with open(os.path.join(repo, "crates", "alpha", "src", "lib.rs"),
                  "w", encoding="utf-8") as fh:
            fh.write("pub fn alpha() { pub fn beta() {} }\n")
        subprocess.run(git + ["add", "-A"], check=True, capture_output=True,
                       text=True, timeout=60)
        subprocess.run(git + ["-c", "user.name=rule", "-c",
                              "user.email=rule@example.invalid",
                              "commit", "-qm", "change"], check=True,
                       capture_output=True, text=True, timeout=60)
        sha = subprocess.run(git + ["rev-parse", "HEAD"], check=True,
                             capture_output=True, text=True,
                             timeout=60).stdout.strip()

        env = dict(os.environ)
        env["REPO"] = repo
        env["LOOP_DIR"] = loop
        env["PATH"] = stub + os.pathsep + env.get("PATH", "")
        env["GATE_QUICK_TIMEOUT_MIN"] = "1"
        env["STUB_CARGO_LOG"] = calls_log
        # The test is HERMETIC: the belt of the scope is disabled (no scope
        # of the user manager is created) and the root of the cgroups is a
        # directory of the test (the cleanup of the debris of the scopes
        # can not touch the scopes of the live loop).
        env["GATE_QUICK_CGROUP"] = "0"
        env["GATE_CGROUP_ROOT"] = os.path.join(root, "cgroup-empty")
        # 25 s of a budget of 60 s: when the check is asked for it, the time
        # that is left does not pay for the check AND for the tests.
        env["STUB_METADATA_SLEEP"] = "25"
        out = subprocess.run(["bash", gate, "--slot", "s0", base, sha],
                             capture_output=True, text=True, env=env,
                             timeout=300)
        verdict = os.path.join(loop, "gates", "s0", "scope.verdict")
        fields = {}
        if os.path.exists(verdict):
            with open(verdict, encoding="utf-8") as fh:
                for line in fh:
                    if "=" in line:
                        key, value = line.strip().split("=", 1)
                        fields[key] = value
        check("the gate answers with a verdict", out.returncode == 0,
              out.stderr[-300:])
        check("the scope is green although the check did not fit",
              fields.get("VERDICT") == "VERDE-SCOPE", fields)
        check("the check of the workspace is skipped, not failed",
              fields.get("CHECKS", "").endswith("check:skipped"),
              fields.get("CHECKS"))
        calls = []
        with open(calls_log, encoding="utf-8") as fh:
            calls = [line.strip() for line in fh if line.strip()]
        check("the check of the workspace did not run", "check" not in calls,
              calls)
        check("the tests of the scope ran", "nextest" in calls, calls)
    finally:
        shutil.rmtree(root, ignore_errors=True)


# --- 40: the scoped gates that fight for the build directory -----------------

# The stub of systemctl for the rule of the debris of the scopes: it answers
# the questions of the gate about the units and it RECORDS the kills, so the
# rule can tell that the debris was killed and that a scope with a gate of
# its own was NOT touched.
STUB_SYSTEMCTL_OF_THE_DEBRIS = r'''#!/usr/bin/env bash
set -uo pipefail
printf 'CALL %s\n' "$*" >> "${STUB_SYSTEMCTL_LOG:?}"
[ "${1:-}" = "--user" ] && shift
cmd="${1:-}"
shift || true
case "$cmd" in
  list-units)
    printf '%s\n' "${STUB_UNITS:-}"
    ;;
  show)
    unit="${1:-}"
    prop="${3:-}"
    case "$prop" in
      ControlGroup)
        case "$unit" in
          solidcraft-gate-quick-*.scope) printf '/%s\n' "$unit" ;;
          *) printf '\n' ;;
        esac
        ;;
      ActiveEnterTimestampMonotonic)
        up="$(cut -d' ' -f1 /proc/uptime 2>/dev/null || printf '0')"
        age="${STUB_SCOPE_AGE:-30}"
        case "$unit" in
          *-333.scope) age=0 ;;
        esac
        awk -v u="$up" -v a="$age" 'BEGIN { printf "%d\n", (u - a) * 1000000 }'
        ;;
      *) printf '\n' ;;
    esac
    ;;
  kill|stop)
    unit=""
    for a in "$@"; do unit="$a"; done
    printf 'ACTION %s %s\n' "$cmd" "$unit" >> "${STUB_SYSTEMCTL_LOG:?}"
    ;;
esac
exit 0
'''


def bash_functions_of_the_gate(src, names):
    """The text of some bash functions of the gate, ready to be sourced.

    The rule asks the GATE: its functions are taken from the script and RUN,
    so a rule that reads the source can not pass when the source does not
    work.
    """
    out = []
    for name in names:
        out.append(bash_func(src, name))
    return "\n".join(out)


def missing_bash_functions(src, names):
    """The functions of the gate that the belt does NOT have.

    A rule that asks for a function that does not exist has to say it (a
    FAIL) and not die with an exception: a rule that dies takes the whole
    battery of the rules with it.
    """
    missing = []
    for name in names:
        if (name + "() {") not in src:
            missing.append(name)
    return missing


def lock_holder(path, ready):
    """A process that holds the lock of the build directory: it is the OTHER
    scoped gate, the one that is compiling."""
    script = path + ".holder.sh"
    with open(script, "w", encoding="utf-8") as fh:
        fh.write('#!/usr/bin/env bash\n'
                 'exec 8>"$1" || exit 1\n'
                 'flock 8 || exit 1\n'
                 ': > "$2"\n'
                 'exec sleep 120\n')
    proc = subprocess.Popen(["bash", script, path, ready],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                            start_new_session=True)
    for _ in range(50):
        if os.path.exists(ready):
            break
        time.sleep(0.1)
    return proc


def test_the_scoped_gates_do_not_fight_for_the_build_directory():
    """Two scoped gates at the same time do not fight for the build directory.

    WHY (27-10-2026): the target directory of the scoped gate is SHARED by
    every slot (GATE_QUICK_TARGET_DIR), so two scoped gates at the same time
    fight for the cargo lock of the build directory, and the loser of that
    fight does not wait: it dies with "Blocking waiting for file lock on build
    directory" (20:12: the clippy of one gate died because the nextest of the
    other one was still alive). Three things stop it:

      (A) the leftovers of a scope die at the end of every phase: the
          binaries of the tests ESCAPE the kill of the group of processes
          (nextest runs every test in a process of its own, with a process
          group of its own), so the container that works is the CGROUP;
      (B) the debris of the scopes that died is cleaned when the gate starts:
          the debris holds the memory of the box and the lock of the build
          directory;
      (C) the scoped gates are serialized with a flock of the gates
          directory: the loser of the lock is DEFERRED, not judged.

    The rule is EXECUTABLE: the functions of the gate are extracted and RUN
    (with a fake cgroup, a fake systemctl and a fake lock) and the GATE
    ITSELF is run with the lock held by another process.

    The rule is HERMETIC: the belt of the scope is disabled and the root of
    the cgroups is a directory of the test, so the test does not create a
    scope of the user manager nor kill the scopes of the live loop.
    """
    print("40. the scoped gates do not fight for the build directory")
    gate = os.path.join(LOOP, "bin", "gate-quick.sh")
    with open(gate, encoding="utf-8") as fh:
        src = fh.read()

    # The belt of the leftovers, of the debris and of the lock: without
    # these functions the gate is the one of BEFORE the fix, and the rule
    # says it (a FAIL) instead of dying with an exception.
    needed = ["cgroup_pids", "pid_cmdline", "pid_state", "ppid_of",
              "kill_leftovers_in", "unit_property", "cleanup_dead_scopes",
              "scope_lock_acquire", "scope_lock_release",
              "scope_verdict_is_fresh"]
    missing = missing_bash_functions(src, needed)
    check("the gate has the belt of the leftovers, of the debris and of the "
          "lock", not missing,
          "the gate does not have: " + ", ".join(missing))
    if missing:
        return

    root = tempfile.mkdtemp(prefix="loop-scope-lock-")
    holders = []
    try:
        # --- (A) the leftovers of a scope die ------------------------------
        # run_child IS PART OF THE LIST (2026-11-18): the gate closes the
        # descriptors 8 and 9 in every child, and it does it through
        # run_child(). A function that calls run_child and is extracted
        # WITHOUT it fails with "run_child: command not found", and the
        # rule that reads the source passes while the code does not work:
        # the leftover of the scope was NOT killed.
        funcs = bash_functions_of_the_gate(src, ["cgroup_pids", "pid_cmdline",
                                                  "pid_state", "ppid_of",
                                                  "run_child",
                                                  "kill_leftovers_in"])
        script = os.path.join(root, "leftovers.sh")
        with open(script, "w", encoding="utf-8") as fh:
            fh.write(funcs)
            fh.write('\nkill_leftovers_in "$FAKE_CGROUP"\n')
        fake = os.path.join(root, "solidcraft-gate-quick-0-999.scope")
        os.makedirs(fake)
        # The orphan: a binary of a test that escaped the kill of the group of
        # processes. The daemon of sccache: it outlives the phase that
        # started it and it does not hold the cargo lock.
        orphan = subprocess.Popen(
            ["bash", "-c", "exec -a gate-quick.sh sleep 300"])
        daemon = subprocess.Popen(
            ["bash", "-c", "exec -a sccache sleep 300"])
        with open(os.path.join(fake, "cgroup.procs"), "w",
                  encoding="utf-8") as fh:
            fh.write("%d\n%d\n" % (orphan.pid, daemon.pid))
        env = dict(os.environ)
        env["FAKE_CGROUP"] = fake
        out = subprocess.run(["bash", script], capture_output=True, text=True,
                             env=env, timeout=60)
        try:
            orphan.wait(timeout=15)
        except subprocess.TimeoutExpired:
            pass
        check("the leftovers of the scope are killed",
              orphan.poll() is not None,
              "the orphan of the scope is still alive")
        check("the daemon of sccache is NOT killed", daemon.poll() is None,
              "the daemon of sccache died with the leftovers")
        for proc in (orphan, daemon):
            if proc.poll() is None:
                proc.kill()
                proc.wait()

        # --- (B) the debris of the scopes that died is cleaned ------------
        stub_dir = os.path.join(root, "stub")
        os.makedirs(stub_dir)
        systemctl = os.path.join(stub_dir, "systemctl")
        with open(systemctl, "w", encoding="utf-8") as fh:
            fh.write(STUB_SYSTEMCTL_OF_THE_DEBRIS)
        os.chmod(systemctl, 0o755)
        cg_root = os.path.join(root, "cgroup")
        debris_unit = "solidcraft-gate-quick-0-111.scope"
        alive_unit = "solidcraft-gate-quick-0-222.scope"
        young_unit = "solidcraft-gate-quick-0-333.scope"
        sleeper = subprocess.Popen(["bash", "-c", "exec -a sleeper sleep 300"])
        young_sleeper = subprocess.Popen(
            ["bash", "-c", "exec -a sleeper sleep 300"])
        gate_alive = subprocess.Popen(
            ["bash", "-c", "exec -a gate-quick.sh sleep 300"])
        for unit, pid in ((debris_unit, sleeper.pid),
                          (alive_unit, gate_alive.pid),
                          (young_unit, young_sleeper.pid)):
            scope = os.path.join(cg_root, unit)
            os.makedirs(scope)
            with open(os.path.join(scope, "cgroup.procs"), "w",
                      encoding="utf-8") as fh:
                fh.write("%d\n" % pid)
        log = os.path.join(root, "systemctl.log")
        # run_child IS PART OF THE LIST (2026-11-18): see the note of the
        # extraction of the leftovers. cleanup_dead_scopes calls it too.
        funcs = bash_functions_of_the_gate(src, ["unit_property",
                                                  "cgroup_pids", "pid_cmdline",
                                                  "run_child",
                                                  "cleanup_dead_scopes"])
        script = os.path.join(root, "debris.sh")
        with open(script, "w", encoding="utf-8") as fh:
            fh.write(funcs)
            fh.write("\ncleanup_dead_scopes\n")
        env = dict(os.environ)
        env["PATH"] = stub_dir + os.pathsep + env.get("PATH", "")
        env["GATE_CGROUP_ROOT"] = cg_root
        env["GATE_SCOPE_CLEAN_GRACE"] = "5"
        env["STUB_SYSTEMCTL_LOG"] = log
        env["STUB_UNITS"] = "\n".join([debris_unit, alive_unit, young_unit])
        out = subprocess.run(["bash", script], capture_output=True, text=True,
                             env=env, timeout=60)
        actions = ""
        if os.path.exists(log):
            with open(log, encoding="utf-8") as fh:
                actions = fh.read()
        check("the debris of a scope that died is killed",
              ("ACTION kill " + debris_unit) in actions, actions[-300:])
        check("a scope with a gate of its own is NOT touched",
              ("ACTION kill " + alive_unit) not in actions, actions[-300:])
        check("a scope that is starting is NOT touched",
              ("ACTION kill " + young_unit) not in actions, actions[-300:])
        for proc in (sleeper, young_sleeper, gate_alive):
            if proc.poll() is None:
                proc.kill()
                proc.wait()

        # --- (C) the lock of the build directory --------------------------
        gates = os.path.join(root, "gates")
        os.makedirs(os.path.join(gates, "s0"))
        funcs = bash_functions_of_the_gate(src, ["scope_lock_acquire",
                                                  "scope_lock_release",
                                                  "scope_verdict_is_fresh"])
        script = os.path.join(root, "lock.sh")
        with open(script, "w", encoding="utf-8") as fh:
            fh.write(funcs)
            fh.write('\n'
                     'GATES_DIR="$GATES_DIR_TEST"\n'
                     'SCOPE_LOCK_FILE="$GATES_DIR/scope.lock"\n'
                     'SLOT_NAME="s0"\n'
                     'SHA="$SHA_TEST"\n'
                     'GATE_SCOPE_LOCK_WAIT="${GATE_SCOPE_LOCK_WAIT_TEST:-0}"\n'
                     'if scope_lock_acquire; then echo "LOCK_FREE";\n'
                     'else echo "LOCK_BUSY"; fi\n'
                     'if scope_verdict_is_fresh; then echo "FRESH";\n'
                     'else echo "NOT_FRESH"; fi\n'
                     'scope_lock_release\n')
        env = dict(os.environ)
        env["GATES_DIR_TEST"] = gates
        env["SHA_TEST"] = "a" * 40
        out = subprocess.run(["bash", script], capture_output=True, text=True,
                             env=env, timeout=60)
        check("the lock of the build directory is taken when it is free",
              "LOCK_FREE" in out.stdout, out.stdout + out.stderr[-200:])
        verdict_file = os.path.join(gates, "s0", "scope.verdict")
        with open(verdict_file, "w", encoding="utf-8") as fh:
            fh.write("GATE_STATUS=finished\nVERDICT=VERDE-SCOPE\nSHA=%s\n"
                     % env["SHA_TEST"])
        out = subprocess.run(["bash", script], capture_output=True, text=True,
                             env=env, timeout=60)
        check("a verdict of this sha is a verdict (a deferral does not throw "
              "it away)", "FRESH" in out.stdout,
              out.stdout + out.stderr[-200:])
        env["SHA_TEST"] = "b" * 40
        out = subprocess.run(["bash", script], capture_output=True, text=True,
                             env=env, timeout=60)
        check("the verdict of another sha is not a verdict of this one",
              "NOT_FRESH" in out.stdout, out.stdout + out.stderr[-200:])
        with open(verdict_file, "w", encoding="utf-8") as fh:
            fh.write("GATE_STATUS=skipped\nVERDICT=SKIP\nSHA=%s\n"
                     "DEFERRED=scope-gate-alive\n" % ("a" * 40))
        env["SHA_TEST"] = "a" * 40
        out = subprocess.run(["bash", script], capture_output=True, text=True,
                             env=env, timeout=60)
        check("a postponement is not a verdict", "NOT_FRESH" in out.stdout,
              out.stdout + out.stderr[-200:])
        # The lock held by another scoped gate: the loser does not wait.
        ready = os.path.join(root, "lock.ready")
        holders.append(lock_holder(os.path.join(gates, "scope.lock"), ready))
        out = subprocess.run(["bash", script], capture_output=True, text=True,
                             env=env, timeout=60)
        check("the lock of the build directory is busy when another scoped "
              "gate holds it", "LOCK_BUSY" in out.stdout,
              out.stdout + out.stderr[-200:])

        # --- the GATE ITSELF, with the lock held by another gate ---------
        repo = os.path.join(root, "repo")
        loop = os.path.join(root, "loop")
        stub = os.path.join(root, "bin")
        os.makedirs(os.path.join(repo, "crates", "alpha", "src"))
        os.makedirs(os.path.join(repo, "scripts", "ci"))
        os.makedirs(os.path.join(loop, "logs"))
        os.makedirs(stub)
        with open(os.path.join(repo, "Cargo.toml"), "w", encoding="utf-8") as fh:
            fh.write("[workspace]\n")
        with open(os.path.join(repo, "crates", "alpha", "src", "lib.rs"),
                  "w", encoding="utf-8") as fh:
            fh.write("pub fn alpha() {}\n")
        # The affected.py of the test: it says that the change touches one
        # package. The real one is not needed to prove the lock.
        with open(os.path.join(repo, "scripts", "ci", "affected.py"),
                  "w", encoding="utf-8") as fh:
            fh.write("import sys\nprint('full=false')\nprint('packages=alpha')\n")
        cargo = os.path.join(stub, "cargo")
        with open(cargo, "w", encoding="utf-8") as fh:
            fh.write(STUB_CARGO_OF_THE_GUARD)
        os.chmod(cargo, 0o755)
        git = ["git", "-C", repo]
        subprocess.run(git + ["init", "-q", "-b", "main"], check=True,
                       capture_output=True, text=True, timeout=60)
        subprocess.run(git + ["add", "-A"], check=True, capture_output=True,
                       text=True, timeout=60)
        subprocess.run(git + ["-c", "user.name=rule", "-c",
                              "user.email=rule@example.invalid",
                              "commit", "-qm", "base"], check=True,
                       capture_output=True, text=True, timeout=60)
        base = subprocess.run(git + ["rev-parse", "HEAD"], check=True,
                             capture_output=True, text=True,
                             timeout=60).stdout.strip()
        with open(os.path.join(repo, "crates", "alpha", "src", "lib.rs"),
                  "w", encoding="utf-8") as fh:
            fh.write("pub fn alpha() { pub fn beta() {} }\n")
        subprocess.run(git + ["add", "-A"], check=True, capture_output=True,
                       text=True, timeout=60)
        subprocess.run(git + ["-c", "user.name=rule", "-c",
                              "user.email=rule@example.invalid",
                              "commit", "-qm", "change"], check=True,
                       capture_output=True, text=True, timeout=60)
        sha = subprocess.run(git + ["rev-parse", "HEAD"], check=True,
                             capture_output=True, text=True,
                             timeout=60).stdout.strip()
        calls_log = os.path.join(root, "calls.log")
        with open(calls_log, "w", encoding="utf-8") as fh:
            fh.write("")
        lock_file = os.path.join(loop, "gates", "scope.lock")
        os.makedirs(os.path.dirname(lock_file), exist_ok=True)
        ready = os.path.join(root, "gate-lock.ready")
        holders.append(lock_holder(lock_file, ready))
        env = dict(os.environ)
        env["REPO"] = repo
        env["LOOP_DIR"] = loop
        env["PATH"] = stub + os.pathsep + env.get("PATH", "")
        env["GATE_QUICK_TIMEOUT_MIN"] = "1"
        env["STUB_CARGO_LOG"] = calls_log
        # The test is hermetic: no scope of the user manager, and the cgroups
        # of the test are the only ones that the gate can see.
        env["GATE_QUICK_CGROUP"] = "0"
        env["GATE_CGROUP_ROOT"] = os.path.join(root, "cgroup-empty")
        out = subprocess.run(["bash", gate, "--slot", "s0", base, sha],
                             capture_output=True, text=True, env=env,
                             timeout=300)
        fields = {}
        verdict = os.path.join(loop, "gates", "s0", "scope.verdict")
        if os.path.exists(verdict):
            with open(verdict, encoding="utf-8") as fh:
                for line in fh:
                    if "=" in line:
                        key, value = line.strip().split("=", 1)
                        fields[key] = value
        check("the gate answers with a verdict", out.returncode == 0,
              out.stderr[-300:])
        check("the scope is postponed, not judged",
              fields.get("GATE_STATUS") == "skipped", fields)
        check("the postponement does not judge the scope",
              fields.get("VERDICT") == "SKIP", fields)
        check("the reason of the postponement is the other scoped gate",
              fields.get("DEFERRED") == "scope-gate-alive", fields)
        with open(calls_log, encoding="utf-8") as fh:
            calls = [line.strip() for line in fh if line.strip()]
        check("nothing is compiled while the lock is held",
              [c for c in calls if c != "metadata"] == [], calls)

        # --- the source of the belt ---------------------------------------
        check("the phases close the lock of the build directory",
              src.count("9>&-") >= 2,
              "the phases inherit the lock of the build directory")
        check("the debris of the scopes is cleaned OUTSIDE the scope",
              'if [ "${SC_QUICK_CGROUP:-0}" != "1" ]; then\n'
              '  cleanup_dead_scopes || true\n'
              'fi' in src,
              "the copy inside the scope cleans its own debris")
        check("the lock is taken BEFORE the phases compile",
              src.index("if ! scope_lock_acquire")
              < src.index('phase "fmt"'),
              "the lock is taken after the first phase")
        block = bash_between(src, "if ! scope_lock_acquire; then",
                              "# --- the run ---")
        check("the loser of the lock is deferred and not failed",
              '"scope-gate-alive"' in block and "exit 0" in block,
              block[-300:])
    finally:
        for proc in holders:
            try:
                proc.kill()
                proc.wait(timeout=10)
            except Exception:
                pass
        shutil.rmtree(root, ignore_errors=True)


def test_the_timeout_of_the_tests_is_a_postponement():
    """The timeout of the tests is a POSTPONEMENT, not a red.

    WHY (27-10-2026): the quick gate runs the tests under a timeout. When the
    timeout fires the runner dies with the tests that were running: the log
    says "SIGTERM" and "1 failed", and a parser that only knew about
    "FAIL|SIGSEGV|ABORT|SIGABRT|TIMEOUT" reads a failure that never happened.
    The verdict was ROJO-SCOPE with TWO invented failures and an EMPTY list of
    failed tests: the agent had nothing to fix and the slot was blocked.

    The cut is not a red and it is not a green either: the scope was NOT
    judged, it was POSTPONED. The verdict of a cut run without a real failure
    is SKIP and it invents no failure. A REAL failure that happened BEFORE the
    cut is still red: the cut does not hide it. And a test that dies on its
    own (SIGTERM with a run that was not cut) IS a failure.

    The rule is EXECUTABLE: the parser is run against synthetic logs, in its
    own loop directory (the live loop is never touched).
    """
    print("41. the timeout of the tests is a postponement, not a red")
    root = tempfile.mkdtemp(prefix="rule41-")
    try:
        loop = os.path.join(root, "loop")
        os.makedirs(loop, exist_ok=True)
        baseline = os.path.join(root, "baseline-failures.txt")
        with open(baseline, "w", encoding="utf-8") as fh:
            fh.write("")
        gate_check = os.path.join(HERE, "gate-check.sh")

        def run_check(body, name):
            """The verdict of the parser about a synthetic log."""
            log = os.path.join(root, name)
            with open(log, "w", encoding="utf-8") as fh:
                fh.write(body)
            env = dict(os.environ)
            env["LOOP_DIR"] = loop
            env["BASELINE_FAILURES"] = baseline
            out = subprocess.run(["bash", gate_check, log], env=env,
                                 capture_output=True, text=True, timeout=60)
            fields = {}
            failures = []
            in_failures = False
            for line in out.stdout.splitlines():
                match = re.match(r"^([A-Z_]+)=(.*)$", line)
                if match:
                    fields[match.group(1)] = match.group(2)
                    in_failures = False
                    continue
                if line.strip() == "--- new failures ---":
                    in_failures = True
                    continue
                if in_failures and line.strip():
                    failures.append(line.strip())
            return fields, failures

        # a run cut by the timeout: the test that was running died with it
        cut = ("    Starting 3262 tests across 3 binaries\n"
               "        SIGTERM [ 449.327s] (3262/3262) solidcraft-ui-egui "
               "render_workspace::tests::progressive_image_controls\n"
               "\n"
               "    Summary [ 624.981s] 3262 tests run: 3261 passed, 1 failed,"
               " 18 skipped\n"
               "EXIT=124\n")
        fields, failures = run_check(cut, "cut.log")
        check("a run cut by the timeout is not red",
              fields.get("VERDICT") == "SKIP", fields)
        check("a run cut by the timeout invents no failure",
              fields.get("NEW_FAILURES") == "0", fields)
        check("the cut is seen as a cut",
              fields.get("RUN_CUT") == "true", fields)
        check("a cut run names no failed test", failures == [], failures)

        # the same run with a REAL failure before the cut: the cut does not
        # hide it
        cut_real = ("    Starting 3262 tests across 3 binaries\n"
                    "        FAIL [   0.029s] (1/3262) solidcraft-kernel "
                    "boolean_props::scale_invariant\n"
                    "--- STDOUT:              solidcraft-kernel "
                    "boolean_props::scale_invariant ---\n"
                    "thread 'boolean_props::scale_invariant' panicked at "
                    "crates/kernel/src/lib.rs:10:5:\n"
                    "assertion failed: false\n"
                    "\n"
                    "        SIGTERM [ 449.327s] (3262/3262) solidcraft-ui-egui "
                    "render_workspace::tests::progressive_image_controls\n"
                    "\n"
                    "    Summary [ 624.981s] 3262 tests run: 3260 passed, 2 "
                    "failed, 18 skipped\n"
                    "EXIT=124\n")
        fields, failures = run_check(cut_real, "cut-real.log")
        check("a real failure before the cut is still red",
              fields.get("VERDICT") == "ROJO", fields)
        check("the real failure of a cut run is counted",
              fields.get("NEW_FAILURES") == "1", fields)
        check("the real failure of a cut run is named",
              failures == ["kernel::boolean_props::scale_invariant"], failures)

        # a run that was NOT cut: a test that died on its own IS a failure
        killed = ("    Starting 2 tests across 1 binary\n"
                  "        SIGTERM [   0.500s] (1/2) solidcraft-ui-egui "
                  "render_workspace::tests::progressive\n"
                  "\n"
                  "    Summary [   0.500s] 2 tests run: 1 passed, 1 failed, 0 "
                  "skipped\n"
                  "EXIT=1\n")
        fields, failures = run_check(killed, "killed.log")
        check("a test that dies on its own is a failure",
              fields.get("VERDICT") == "ROJO", fields)
        check("the dead test is named",
              failures == ["ui-egui::render_workspace::tests::progressive"],
              failures)

        # a run that finished: the verdict is the usual one
        green = ("    Starting 2 tests across 1 binary\n"
                 "        PASS [   0.010s] (1/2) solidcraft-kernel "
                 "boolean_props::scale_invariant\n"
                 "\n"
                 "    Summary [   0.010s] 2 tests run: 2 passed, 0 failed, 0 "
                 "skipped\n"
                 "EXIT=0\n")
        fields, failures = run_check(green, "green.log")
        check("a run that finished green is green",
              fields.get("VERDICT") == "VERDE", fields)
        check("a green run invents no failure",
              fields.get("NEW_FAILURES") == "0", fields)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_the_tests_run_only_on_the_touched_crate():
    """The tests run on the crate that was touched, not on the whole scope.

    WHY (27-10-2026): the scope of a change is the set of packages that the
    change can break: three packages for a change of ONE line, and 3262 tests
    of the whole scope for a change that touches one crate. The scope of the
    COMPILATION (the clippy and the check of the workspace) stays as it was:
    a dependent that does not compile is still red. The scope of the TESTS is
    narrowed to the packages whose DIRECTORY holds a changed file: the
    dependents are NOT here, because a test of a dependent is not a test of
    the change.

    The narrowing is an OPTIMIZATION: when it cannot be computed, or when a
    changed file belongs to no package, the tests run on the whole scope. A
    wrong narrower run is a green that hides a red.

    The rule is EXECUTABLE: the helper that computes the scope of the tests
    is run against a synthetic metadata and a synthetic list of paths.
    """
    print("42. the tests run only on the crate that was touched")
    root = tempfile.mkdtemp(prefix="rule42-")
    try:
        helper = os.path.join(HERE, "touched-packages.py")
        with open(os.path.join(HERE, "gate-quick.sh"), encoding="utf-8") as fh:
            src = fh.read()

        # --- the source of the gate ---------------------------------------
        # The tests use the narrow scope; the compilation uses the whole one.
        check("the tests run on the narrow scope",
              'cargo nextest run "${TEST_SCOPE_ARGS[@]}"' in src,
              "the nextest of the gate does not use the narrow scope")
        check("the clippy runs on the whole scope",
              'cargo clippy "${SCOPE_ARGS[@]}"' in src,
              "the clippy of the gate does not use the whole scope")
        check("the narrow scope comes from the helper",
              "TOUCHED_SCRIPT" in src and "touched-packages.py" in src,
              "the gate does not compute the scope of the tests")

        # --- the helper, run -----------------------------------------------
        meta = {
            "workspace_root": "/repo",
            "packages": [
                {"name": "solidcraft", "manifest_path": "/repo/Cargo.toml"},
                {"name": "solidcraft-ui-egui",
                 "manifest_path": "/repo/crates/ui-egui/Cargo.toml"},
                {"name": "solidcraft-web",
                 "manifest_path": "/repo/crates/web/Cargo.toml"},
            ],
        }
        meta_file = os.path.join(root, "metadata.json")
        with open(meta_file, "w", encoding="utf-8") as fh:
            json.dump(meta, fh)

        def scope_of(paths, name):
            """The scope of the tests for a list of changed paths."""
            paths_file = os.path.join(root, name + ".paths")
            with open(paths_file, "wb") as fh:
                fh.write(b"\0".join(p.encode("utf-8") for p in paths)
                         + b"\0")
            out = subprocess.run(
                ["python3", "-I", helper, "--paths", paths_file,
                 "--metadata", meta_file],
                capture_output=True, text=True, timeout=60)
            fields = {}
            for line in out.stdout.splitlines():
                if "=" in line:
                    key, _, value = line.partition("=")
                    fields[key] = value
            return out, fields

        out, fields = scope_of(["crates/ui-egui/src/viewport.rs"], "one")
        check("the helper answers",
              out.returncode == 0, out.stderr[-200:])
        check("the tests run on the crate that was touched",
              fields.get("packages") == "solidcraft-ui-egui", fields)
        check("the run is narrow", fields.get("narrow") == "true", fields)

        out, fields = scope_of(
            ["crates/ui-egui/src/viewport.rs", "crates/web/src/main.rs"],
            "two")
        check("the tests run on every crate that was touched",
              fields.get("packages") == "solidcraft-ui-egui solidcraft-web",
              fields)

        # a file that belongs to no package: the doubt is the whole scope
        out, fields = scope_of(["crates/ui-egui/src/viewport.rs",
                                 "tests/fixtures/data.json"], "orphan")
        check("a file with no owner keeps the whole scope",
              fields.get("narrow") == "false", fields)
        check("a file with no owner names no package",
              fields.get("packages") == "", fields)

        # a document changes no code: the scope of the tests does not change
        out, fields = scope_of(["crates/ui-egui/src/viewport.rs",
                                 "docs/README.md"], "doc")
        check("a document does not stop the narrowing",
              fields.get("narrow") == "true", fields)
        check("a document does not add a package",
              fields.get("packages") == "solidcraft-ui-egui", fields)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_the_fences_of_a_prompt_are_paired_line_by_line():
    """The fences of a prompt are paired LINE BY LINE, not with a regex.

    WHY (27-10-2026): the checker of the prompts paired the fences with a
    regex over the whole text that only knew the languages "bash", "sh" and
    none. The fence that OPENS a block of json was skipped and the fence
    that CLOSED it was taken for the opening of the next block: the prose
    that came after the block of json was read as if it were a command (the
    sentence "cut is a fact: ..." is a sentence, not a `cut`) and the
    content of the block of shell was never read at all. The false red was
    in the checker, not in the prompt: the prompt says the right thing.

    A block that HOLDS another fence is a wrapper (the prompts wrap a block
    of json in four backticks): the inner block is the real one.

    The rule is EXECUTABLE: the checker is asked about the real prompt of
    the iteration and about a synthetic prompt with the same shape.
    """
    print("43. the fences of a prompt are paired line by line")
    root = tempfile.mkdtemp(prefix="rule43-")
    try:
        checker = os.path.join(LOOP, "bin", "check-prompt-permissions.py")
        if not os.path.exists(checker):
            check("the checker of the prompts is there", False, checker)
            return

        agent_dir = agents_dir()
        prompts_dir = os.path.join(LOOP, "prompts")
        if not os.path.isdir(prompts_dir):
            prompts_dir = "/home/user/.local/share/solidcraft-loop/prompts"

        # The checker, loaded as a module: the parser of the fences is
        # asked directly, without the subprocess.
        saved = {k: os.environ.get(k) for k in ("CHECK_AGENT_DIR", "CHECK_PROMPT_DIR")}
        os.environ["CHECK_AGENT_DIR"] = agent_dir
        os.environ["CHECK_PROMPT_DIR"] = prompts_dir
        try:
            loader = importlib.machinery.SourceFileLoader("loop_fences", checker)
            spec = importlib.util.spec_from_loader("loop_fences", loader)
            module = importlib.util.module_from_spec(spec)
            loader.exec_module(module)
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        module.AGENT_DIR = agent_dir
        module.PROMPT_DIR = prompts_dir

        # --- the real prompt of the iteration ----------------------------
        real = os.path.join(prompts_dir, "iteration.md")
        with open(real, encoding="utf-8") as fh:
            text = fh.read()
        cmds = module.commands(text)
        check("the shell block of the prompt is read",
              any(c.startswith("git -C /home/user/solidcraft merge-base")
                  for c in cmds),
              "the block of shell of the prompt was never read")
        check("the prose of the prompt is not a command",
              not any("cut is a fact" in c for c in cmds),
              "the prose was read as if it were a command")

        # --- the synthetic prompt with the same shape --------------------
        fixture = os.path.join(root, "prompts")
        os.makedirs(fixture, exist_ok=True)
        synthetic = (
            "# Fixture of the fences\n"
            "\n"
            "```json\n"
            '{"phase": "gating"}\n'
            "```\n"
            "\n"
            "cut is a fact: this prose is not a command.\n"
            "\n"
            "```bash\n"
            "echo hello\n"
            "```\n"
        )
        with open(os.path.join(fixture, "iteration.md"), "w", encoding="utf-8") as fh:
            fh.write(synthetic)

        syn = module.commands(synthetic)
        check("the block of shell after a block of json is read",
              "echo hello" in syn, syn)
        check("the prose after a block of json is not a command",
              not any("cut is a fact" in c for c in syn), syn)
        check("the block of json is not read as shell",
              not any(c.startswith("{") for c in syn), syn)

        # the wrapper of four backticks: the inner block is the real one
        wrapped = ("````\n"
                   "```bash\n"
                   "echo wrapped\n"
                   "```\n"
                   "````\n")
        wcmds = module.commands(wrapped)
        check("the inner block of a wrapper is read",
              "echo wrapped" in wcmds, wcmds)

        # --- the checker on the synthetic prompt, end to end --------------
        env = dict(os.environ)
        env["CHECK_AGENT_DIR"] = agent_dir
        env["CHECK_PROMPT_DIR"] = fixture
        run = subprocess.run([sys.executable, checker], capture_output=True,
                             text=True, env=env, timeout=120)
        check("the checker finds no dead instruction in the synthetic prompt",
              run.returncode == 0,
              (run.stdout or "")[-1500:] + (run.stderr or "")[-500:])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_the_budget_is_split_with_the_measured_costs():
    """The budget of the gate is split with the MEASURED costs of the phases.

    WHY (27-10-2026): the repartition of the budget was measured on times
    that do not exist any more. The tests of the scope do NOT take 4m11s:
    they take 21m41s (11m17s to LINK the 21 binaries of the tests of
    `ui-egui`, 250 MB each one, and 10m25s to RUN them). With the old
    repartition (40% of the budget for the tests) the block of the tests
    was cut in the middle of its own link and the gate answered "we did not
    get to know" about a scope that passes: four gates in a row ended with
    EXIT=124 and no verdict.

    The repartition is a set of MEASURED numbers, not a guess: every phase
    keeps a margin over what it costs, the tests take the lion's share
    (they are the phase that decides the scope) and the sum of the slices
    is EXACTLY the budget, so a phase can never eat the share of another
    one (the share of the tests is what is left after the others).

    The linter is the phase that GROWS with the scope, so its slice has a
    thin margin: a cut of the linter is a postponement ("we did not get to
    know"), never a red gate. A red gate that says "the code is wrong" when
    the truth is "we ran out of time" is the auto-sabotage this whole
    package is about.

    The rule is EXECUTABLE: the block of the slices is taken from the gate
    and RUN with several budgets, and the OLD repartition is run with the
    same harness to prove that the rule is discriminante (a rule that
    accepts the old numbers accepts everything).
    """
    print("44. the budget of the gate is split with the measured costs")
    # The costs measured on the 27-10-2026 (box of 16 vCPU).
    measured_tests = 1301     # 677s to link the tests + 624s to run them
    measured_clippy = 130     # the clippy of a scope of three packages
    measured_check = 113      # the check of the whole workspace
    budget = 1800             # the default: GATE_QUICK_TIMEOUT_MIN=30

    gate = os.path.join(LOOP, "bin", "gate-quick.sh")
    with open(gate, encoding="utf-8") as fh:
        src = fh.read()
    block = slice_block_of_the_gate(src)
    check("the gate has a block of slices for its phases", block != "",
          "the block of the slices was not found")
    if not block:
        return

    def slices(blk, size, mode):
        """The slices of the gate, RUN: {name: seconds} or None."""
        env = dict(os.environ)
        env["BUDGET"] = str(size)
        env["GATE_CHECK_WORKSPACE"] = mode
        script = (blk + "\nprintf '%s %s %s %s %s\\n' \"$FMT_SLICE\""
                  " \"$LAYERS_SLICE\" \"$CLIPPY_SLICE\" \"$CHECK_SLICE\""
                  " \"$NEXTEST_SLICE\"\n")
        run = subprocess.run(["bash", "-c", script], capture_output=True,
                             text=True, env=env, timeout=60)
        if run.returncode != 0:
            return None
        parts = run.stdout.split()
        if len(parts) != 5:
            return None
        names = ("fmt", "layers", "clippy", "check", "nextest")
        return dict(zip(names, (int(p) for p in parts)))

    # --- the sum of the slices is EXACTLY the budget ----------------------
    for size in (1800, 1500, 1200, 900, 3600):
        for mode in ("1", "0"):
            got = slices(block, size, mode)
            check(f"the slices of a budget of {size}s are computed "
                  f"(the check of the workspace is {mode})",
                  got is not None, "the block of the slices did not run")
            if got is None:
                continue
            total = sum(got.values())
            check(f"the slices of a budget of {size}s add up to the budget "
                  f"(the check of the workspace is {mode})",
                  total == size, f"{total} != {size}: {got}")

    # --- the margins over the measured costs ------------------------------
    on = slices(block, budget, "1")
    off = slices(block, budget, "0")
    check("the slices of the default budget are computed", on and off,
          "the block of the slices did not run")
    if not on or not off:
        return
    check("the tests reach the cost that was measured",
          on["nextest"] >= measured_tests,
          f"{on['nextest']}s < {measured_tests}s: the tests would be cut")
    check("the tests reach the cost that was measured with the check off",
          off["nextest"] >= measured_tests,
          f"{off['nextest']}s < {measured_tests}s: the tests would be cut")
    check("the linter keeps a margin over the cost that was measured",
          on["clippy"] >= measured_clippy,
          f"{on['clippy']}s < {measured_clippy}s: the linter would be cut")
    check("the check of the workspace keeps a margin over its measured cost",
          on["check"] >= measured_check,
          f"{on['check']}s < {measured_check}s: the check would be cut")
    check("the check of the workspace takes nothing when it is off",
          off["check"] == 0, off["check"])

    # --- the shares that were decided -------------------------------------
    # The share of the tests is what is LEFT after the others: the sum of the
    # slices is EXACTLY the budget, whatever the budget is. The linter takes
    # 15% (270 s on a 30 min budget) because it compiles the scope a SECOND
    # time (the artifacts of the clippy are not the ones of `cargo check`):
    # a scope of three packages takes 125 s on a COLD clippy cache (measured
    # 2m05s on the slot 10138), so a slice of 8% (144 s) was cut in the middle
    # of the scope and the gate published without a linter (31-10-2026). With
    # the check of the workspace ON the tests take 73% (fmt 2 + layers 2 +
    # clippy 15 + check 8), and with it OFF they take 76% (the linter takes
    # the 8% that the check leaves).
    check("the tests take 73% of the budget with the check on",
          on["nextest"] == budget * 73 // 100, on["nextest"])
    check("the tests take 76% of the budget with the check off",
          off["nextest"] == budget * 76 // 100, off["nextest"])
    check("the linter has a slice that covers a whole compilation of the scope",
          on["clippy"] >= 240,
          f"{on['clippy']}s: el clippy del scope tarda 125s con el cache frio")
    check("the linter has a slice that covers a whole compilation of the scope (check off)",
          off["clippy"] >= 240,
          f"{off['clippy']}s: el clippy del scope tarda 125s con el cache frio")

    # --- the cut of the linter is a postponement, not a red --------------
    soft = re.search(r"PHASE_SOFT=1\s*\n\s*phase \"clippy", src)
    check("the linter of the gate is a soft phase", soft is not None,
          "the clippy is a hard phase: a cut of it would be a red gate")

    # --- the old repartition is refused by the same harness ---------------
    old = ("FMT_SLICE=$(( BUDGET * 5 / 100 ))\n"
           "LAYERS_SLICE=$(( BUDGET * 5 / 100 ))\n"
           "CLIPPY_SLICE=$(( BUDGET * 25 / 100 ))\n"
           "CHECK_SLICE=$(( BUDGET * 25 / 100 ))\n"
           "NEXTEST_SLICE=$(( BUDGET * 40 / 100 ))\n")
    got = slices(old, budget, "1")
    check("the old repartition does not reach the measured cost of the tests",
          got is not None and got["nextest"] < measured_tests,
          f"the old repartition gives {got}: the rule would not be "
          "discriminante")


def test_a_phase_that_was_cut_is_not_a_red_gate():
    """A phase that was CUT is not a red gate.

    WHY (27-10-2026): the linter is the phase that GROWS with the scope
    (130s for three packages, measured the 27-10-2026), so its share of
    the budget is thin and it is the phase that gets cut. A gate that says
    "the code is wrong" when the truth is "we ran out of time" sends the
    agent to fix a linter that was only late: that is the auto-sabotage
    this package is about.

    The phases that can be cut (the linter, the check of the workspace and
    the tests) are SOFT: a cut is a "skipped", and the scope keeps the
    verdict of the phases that did finish. The FAILURES of a phase (its
    exit code) are still red: the code is wrong and the agent has to fix
    it.

    The rule is EXECUTABLE: the block that decides the verdict of the
    scope is taken from the gate and RUN with the states of the phases.
    """
    print("45. a phase that was cut is not a red gate")
    gate = os.path.join(LOOP, "bin", "gate-quick.sh")
    with open(gate, encoding="utf-8") as fh:
        src = fh.read()
    block = verdict_block_of_the_gate(src)
    check("the gate has a block that decides the verdict of the scope",
          block != "", "the block of the verdict was not found")
    if not block:
        return

    def verdict(**states):
        """The verdict of the scope, RUN, with a state of the phases."""
        base = {"STATUS": "finished", "NEW_FAILURES": "0", "FMT_STATE": "ok",
                "LAYERS_STATE": "ok", "CLIPPY_STATE": "ok",
                "CHECK_STATE": "ok", "DEFERRED": "", "FAILED_TESTS": ""}
        base.update({k: str(v) for k, v in states.items()})
        env = dict(os.environ)
        env.update(base)
        script = block + "\necho \"$SCOPE_VERDICT\"\n"
        run = subprocess.run(["bash", "-c", script], capture_output=True,
                             text=True, env=env, timeout=30)
        if run.returncode != 0:
            return None
        return run.stdout.strip()

    check("the scope is green when every phase finished",
          verdict() == "VERDE-SCOPE", verdict())
    check("the scope is green when the linter was cut",
          verdict(CLIPPY_STATE="skipped") == "VERDE-SCOPE",
          verdict(CLIPPY_STATE="skipped"))
    check("the scope is green when the check of the workspace was cut",
          verdict(CHECK_STATE="skipped") == "VERDE-SCOPE",
          verdict(CHECK_STATE="skipped"))
    check("the scope is red when the linter FAILED",
          verdict(CLIPPY_STATE="fail") == "ROJO-SCOPE",
          verdict(CLIPPY_STATE="fail"))
    check("the scope is red when the check of the workspace FAILED",
          verdict(CHECK_STATE="fail") == "ROJO-SCOPE",
          verdict(CHECK_STATE="fail"))
    check("the scope is red when the fmt FAILED",
          verdict(FMT_STATE="fail") == "ROJO-SCOPE",
          verdict(FMT_STATE="fail"))
    check("the scope is red when the layers FAILED",
          verdict(LAYERS_STATE="fail") == "ROJO-SCOPE",
          verdict(LAYERS_STATE="fail"))
    check("the scope is red when there is a new failure",
          verdict(NEW_FAILURES="1") == "ROJO-SCOPE",
          verdict(NEW_FAILURES="1"))
    check("the scope is not judged when it was deferred",
          verdict(DEFERRED="nextest-timeout") == "SKIP",
          verdict(DEFERRED="nextest-timeout"))

    # --- the phases that can be cut are SOFT ------------------------------
    for name in ("clippy", "check --workspace", "nextest"):
        soft = re.search(r"PHASE_SOFT=1\s*\n\s*phase \"" + re.escape(name),
                         src)
        check(f"the phase {name} of the gate is soft", soft is not None,
              f"the phase {name} is hard: a cut of it would be a red gate")

    # --- the rule is discriminante ---------------------------------------
    # The verdict that the gate had BEFORE the linter became a soft phase:
    # a cut of the linter was a red gate.
    old = block.replace('[ "$CLIPPY_STATE" != "fail" ]',
                        '[ "$CLIPPY_STATE" = "ok" ]')
    check("the verdict of the gate can be changed to check the old one",
          old != block, "the block does not have the state of the linter")
    if old == block:
        return
    env = dict(os.environ)
    env.update({"STATUS": "finished", "NEW_FAILURES": "0", "FMT_STATE": "ok",
                "LAYERS_STATE": "ok", "CLIPPY_STATE": "skipped",
                "CHECK_STATE": "ok", "DEFERRED": "", "FAILED_TESTS": ""})
    run = subprocess.run(["bash", "-c", old + "\necho \"$SCOPE_VERDICT\"\n"],
                         capture_output=True, text=True, env=env, timeout=30)
    check("the old verdict made a cut of the linter a red gate",
          run.stdout.strip() == "ROJO-SCOPE", run.stdout.strip())


# --- 46: the pull request carries the issue number --------------------------
def test_the_pull_request_carries_the_issue_number():
    """The pull request carries the issue number in the TITLE and in the BODY.

    WHY: the claim of an issue is decided by the mentions. The upstream
    closes the issue when the body says "Fixes #N", and our own claim guard
    looks for "#N" in the title and in the body of the open pull requests: a
    pull request without the number is INVISIBLE to the guard and the loop can
    claim the same issue twice. And when the pull request opens in ANOTHER
    repository, "Fixes #N" points to a number of another repository: it would
    close nothing.

    The rule is EXECUTABLE: `bin/agent-issue.sh --dry-run` is RUN and the
    title and the body it would publish are read. The dry run does no
    network, no git and no worktree: the stubs of `gh`, `git`, `curl` and
    `wget` record every call, and the rule proves that NONE was made (with a
    control that shows the stubs really are the first in the PATH).
    """
    print("46. the pull request carries the issue number")
    agent = os.path.join(LOOP, "bin", "agent-issue.sh")
    if not os.path.exists(agent):
        check("the script of the agent issue is there", False, agent)
        return
    check("the script of the agent issue is a valid bash",
          subprocess.run(["bash", "-n", agent], capture_output=True,
                         text=True).returncode == 0)

    root = tempfile.mkdtemp(prefix="rule46-")
    try:
        home = os.path.join(root, "home")
        loop = os.path.join(root, "loop")
        stub_dir = os.path.join(root, "bin")
        for folder in (home, loop, stub_dir):
            os.makedirs(folder, exist_ok=True)
        # The configuration of the test: no real upstream, no real fork.
        with open(os.path.join(loop, "config.env"), "w", encoding="utf-8") as fh:
            fh.write("UPSTREAM=acme/one\nFORK_OWNER=forkowner\n"
                     "MODEL=test/model\n")
        # The stubs of the network: they FAIL and they record the call, so
        # the rule can prove that the dry run touched neither GitHub nor git.
        calls = os.path.join(root, "calls.log")
        for tool in ("gh", "git", "curl", "wget"):
            path = os.path.join(stub_dir, tool)
            write_script(path,
                         "#!/usr/bin/env bash\n"
                         "printf '%s\\n' \"$*\" >> \"" + calls + "\"\n"
                         "echo \"" + tool + ": not allowed in a dry run\" >&2\n"
                         "exit 1\n")
            os.chmod(path, 0o755)

        env = dict(os.environ)
        env["PATH"] = stub_dir + os.pathsep + env.get("PATH", "")
        # The HOME of the test: the script prepends $HOME/.local/bin to the
        # PATH (the real `gh` lives there) and the stub has to stay first.
        env["HOME"] = home
        env["LOOP_DIR"] = loop

        def dry_run(args, extra=None):
            """The dry run of the agent issue: its title, its body and its
            exit code."""
            local = dict(env)
            if extra:
                local.update(extra)
            run = subprocess.run(["bash", agent] + args, env=local,
                                 capture_output=True, text=True, timeout=60)
            title = ""
            body = []
            other = []
            for line in run.stdout.splitlines():
                if line.startswith("pr-title: "):
                    title = line[len("pr-title: "):]
                elif line.startswith("pr-body-line: "):
                    body.append(line[len("pr-body-line: "):])
                else:
                    other.append(line)
            return run, title, body, other

        # --- a) the issue and the pull request in the same repository --------
        run, title, body, other = dry_run(["--dry-run", "--repo", "acme/one",
                                           "--pr-repo", "acme/one", "7058"])
        check("the dry run of the agent issue works", run.returncode == 0,
              f"rc={run.returncode} {run.stderr[-200:]}")
        check("the title of the pull request carries the issue number",
              title.endswith("(#7058)"), title)
        check("the body of the pull request closes the issue of its own "
              "repository", "Fixes #7058" in body, body)
        check("the dry run prints nothing but the title and the body",
              other == [], other)

        # --- b) the pull request opens in ANOTHER repository -----------------
        run, title, body, other = dry_run(["--dry-run", "--repo", "acme/one",
                                           "--pr-repo", "acme/two", "7058"])
        check("the title carries the issue number in another repository too",
              title.endswith("(#7058)"), title)
        check("the body points at the issue of its own repository",
              "Task: https://github.com/acme/one/issues/7058" in body, body)
        check("the body mentions the issue number in another repository",
              any("#7058" in line for line in body), body)
        check("the body does not close an issue of another repository",
              not any("Fixes #7058" in line for line in body), body)
        check("the body states the line of the defaults",
              any(line.startswith("Changes a default: ") for line in body), body)

        # --- c) the title of the issue comes from the environment ------------
        run, title, body, other = dry_run(["--dry-run", "7058"],
                                           {"AGENT_ISSUE_TITLE": "the summary"})
        check("the title of the pull request is the title of the issue",
              title == "the summary (#7058)", title)

        # --- the dry run is OFFLINE ------------------------------------------
        recorded = ""
        if os.path.exists(calls):
            with open(calls, encoding="utf-8") as fh:
                recorded = fh.read()
        check("the dry run touches neither GitHub nor git",
              recorded.strip() == "", recorded.strip()[:200])
        # The control: the stubs really are the first in the PATH, so the
        # empty log above is a fact and not an accident.
        subprocess.run(["gh", "pr", "list"], env=env, capture_output=True,
                       text=True, timeout=30)
        with open(calls, encoding="utf-8") as fh:
            recorded = fh.read()
        check("the stubs of the test are the first in the PATH",
              "pr list" in recorded, recorded.strip()[:200])
    finally:
        shutil.rmtree(root, ignore_errors=True)


# --- 47: every pull request states "Changes a default:" --------------------
def test_every_pull_request_states_changes_a_default():
    """Every pull request of ours states `Changes a default:`.

    WHY: the upstream (pr-checks.yml) FAILS a pull request whose body does
    not say whether it changes a default. The check that says so lives in
    `bin/pr-defaults-line.sh`: it only READS and it only REPORTS, it never
    writes the line into a pull request (the agent rewrites the body later,
    following prompts/publish.md).

    The exit codes are the contract: 0 every checked pull request has the
    line, 1 at least one misses it, 6 GitHub could not be read. And 6 is
    "UNKNOWN", never "the line is missing": a check that did not happen
    cannot condemn a pull request (fail-open).

    The rule is EXECUTABLE: the script is RUN against a `gh` of the tests
    whose answers come from the environment (a JSON array of pull requests:
    number and body).
    """
    print("47. every pull request of ours states `Changes a default:`")
    script = os.path.join(LOOP, "bin", "pr-defaults-line.sh")
    if not os.path.exists(script):
        check("the script of the line of the defaults is there", False, script)
        return
    check("the script of the line of the defaults is executable",
          os.access(script, os.X_OK))
    check("the script of the line of the defaults is a valid bash",
          subprocess.run(["bash", "-n", script], capture_output=True,
                         text=True).returncode == 0)

    root = tempfile.mkdtemp(prefix="rule47-")
    try:
        home = os.path.join(root, "home")
        loop = os.path.join(root, "loop")
        stub_dir = os.path.join(root, "bin")
        for folder in (home, loop, stub_dir):
            os.makedirs(folder, exist_ok=True)
        with open(os.path.join(loop, "config.env"), "w", encoding="utf-8") as fh:
            fh.write("UPSTREAM=acme/one\nFORK_OWNER=forkowner\n")
        log = os.path.join(root, "gh.log")
        # The `gh` of the test: GitHub is never contacted. The answers come
        # from STUB_PRS (a JSON array of pull requests: number and body) and
        # STUB_FAIL (a GitHub that cannot be read).
        stub = os.path.join(stub_dir, "gh")
        write_script(stub,
                     "#!/usr/bin/env bash\n"
                     "printf '%s\\n' \"$*\" >> \"${STUB_LOG:-/dev/null}\"\n"
                     "if [ -n \"${STUB_FAIL:-}\" ]; then\n"
                     "  echo \"gh: could not connect to github.com\" >&2\n"
                     "  exit 1\n"
                     "fi\n"
                     "case \"${1:-} ${2:-}\" in\n"
                     "  \"pr list\")\n"
                     "    python3 -c 'import json, os\n"
                     "for pr in json.loads(os.environ.get(\"STUB_PRS\", \"[]\")):\n"
                     "    print(pr.get(\"number\"))'\n"
                     "    exit 0\n"
                     "    ;;\n"
                     "  \"pr view\")\n"
                     "    python3 -c 'import json, os, sys\n"
                     "number = sys.argv[1]\n"
                     "for pr in json.loads(os.environ.get(\"STUB_PRS\", \"[]\")):\n"
                     "    if str(pr.get(\"number\")) == number:\n"
                     "        print(pr.get(\"body\", \"\"))\n"
                     "        break' \"$3\"\n"
                     "    exit 0\n"
                     "    ;;\n"
                     "esac\n"
                     "exit 1\n")
        os.chmod(stub, 0o755)

        env = dict(os.environ)
        env["PATH"] = stub_dir + os.pathsep + env.get("PATH", "")
        # The HOME of the test: the script prepends $HOME/.local/bin to the
        # PATH (the real `gh` lives there) and the stub has to stay first.
        env["HOME"] = home
        env["LOOP_DIR"] = loop
        env["STUB_LOG"] = log

        def check_prs(prs, fail=False):
            """The check of the line of the defaults, RUN against the `gh` of
            the test."""
            local = dict(env)
            local["STUB_PRS"] = json.dumps(prs)
            if fail:
                local["STUB_FAIL"] = "1"
            return subprocess.run(["bash", script], env=local,
                                  capture_output=True, text=True, timeout=60)

        with_line = [{"number": 12, "body": "Changes a default: no\n\nbody"},
                     # The upstream (scripts/pr-checks/pr-checks.js) asks more
                     # than "is there a line": a 'yes' has to be well formed,
                     # 'yes - <what>, old behaviour kept behind preference
                     # <name>'. The validator calls the parser of the
                     # upstream, so a 'yes' without the preference is
                     # REFUSED, exactly like the remote CI refuses it. This
                     # fixture used a 'yes' without the preference and the
                     # check said it was missing the line: the fixture was
                     # wrong, not the validator (31-10-2026).
                     {"number": 13,
                      "body": "Changes a default: yes - the default of x, old behaviour kept behind preference x\n"}]
        without_line = [{"number": 12, "body": "Changes a default: no\n"},
                        {"number": 13, "body": "nothing to see here\n"}]

        # --- a) every pull request has the line -----------------------------
        out = check_prs(with_line)
        check("the pull requests with the line pass the check",
              out.returncode == 0, f"rc={out.returncode} {out.stdout[-200:]}")
        check("the check counts the pull requests it checked",
              re.search(r"checked: \d+ missing: 0", out.stdout) is not None,
              out.stdout.strip()[-200:])

        # --- b) one pull request misses the line ---------------------------
        out = check_prs(without_line)
        check("a pull request without the line fails the check",
              out.returncode == 1, f"rc={out.returncode} {out.stdout[-200:]}")
        check("the check names the pull request that misses the line",
              re.search(r"^missing: 13$", out.stdout, re.M) is not None,
              out.stdout.strip()[-200:])

        # --- c) a GitHub that cannot be read is UNKNOWN, not a missing line -
        out = check_prs(with_line, fail=True)
        check("a GitHub that cannot be read is not a verdict",
              out.returncode == 6, f"rc={out.returncode} {out.stdout[-200:]}")
        check("a GitHub that cannot be read is never read as a missing line",
              "missing:" not in out.stdout, out.stdout.strip()[-200:])

        # --- d) the check only READS ----------------------------------------
        recorded = ""
        if os.path.exists(log):
            with open(log, encoding="utf-8") as fh:
                recorded = fh.read()
        writes = [line for line in recorded.splitlines()
                  if re.search(r"\b(pr edit|pr close|pr create|pr merge|"
                               r"pr comment|pr ready|api -X POST)\b", line)]
        check("the check never writes to a pull request", not writes, writes)

        # --- e) the OFFLINE mode: the body of a file, without GitHub -------
        # The log of `gh` is emptied FIRST: from here on the check must not
        # ask GitHub anything, and the empty log is the proof.
        if os.path.exists(log):
            os.unlink(log)
        body_ok = os.path.join(root, "body-ok.md")
        with open(body_ok, "w", encoding="utf-8") as fh:
            fh.write("Fixes #7058\nChanges a default: no\n\nthe body\n")
        body_bad = os.path.join(root, "body-bad.md")
        with open(body_bad, "w", encoding="utf-8") as fh:
            fh.write("Fixes #7058\n\nthe body without the line\n")

        # No configuration at all: the offline mode cannot need one.
        offline = dict(env)
        offline.pop("LOOP_DIR", None)

        def check_body(path):
            """The offline mode, RUN against a body of a file."""
            return subprocess.run(["bash", script, "--body", path],
                                  env=offline, capture_output=True, text=True,
                                  timeout=60)

        out = check_body(body_ok)
        check("the offline mode accepts a body with the line",
              out.returncode == 0, f"rc={out.returncode} {out.stdout[-200:]}")
        check("the offline mode counts the body it checked",
              re.search(r"checked: 1 missing: 0", out.stdout) is not None,
              out.stdout.strip()[-200:])
        out = check_body(body_bad)
        check("the offline mode refuses a body without the line",
              out.returncode == 1, f"rc={out.returncode} {out.stdout[-200:]}")
        check("the offline mode names the body that misses the line",
              re.search(r"^missing: .*body-bad", out.stdout, re.M) is not None,
              out.stdout.strip()[-200:])
        out = subprocess.run(["bash", script, "--body"], env=offline,
                             capture_output=True, text=True, timeout=60)
        check("the offline mode without a file is a usage error",
              out.returncode == 2, f"rc={out.returncode}")
        out = subprocess.run(["bash", script, "--body",
                              os.path.join(root, "does-not-exist.md")],
                             env=offline, capture_output=True, text=True,
                             timeout=60)
        check("the offline mode with a body it cannot read is a usage error",
              out.returncode == 2, f"rc={out.returncode}")
        recorded = ""
        if os.path.exists(log):
            with open(log, encoding="utf-8") as fh:
                recorded = fh.read()
        check("the offline mode never asks GitHub", recorded.strip() == "",
              recorded.strip()[-200:])
    finally:
        shutil.rmtree(root, ignore_errors=True)


# --- 48: the branch is rebased before the gate and before the push ---------
def test_the_branch_is_rebased_before_the_gate_and_the_push():
    """The branch is REBASED onto the base before the narrow gate and before
    the push, and a failing rebase ABORTS the publication.

    WHY: the upstream CI runs on top of its main: a pull request with a stale
    base costs a red check. And the narrow gate has to validate the tree
    that is published, so the rebase happens BEFORE the gate. But a
    CONFLICTING rebase cannot be published: the branch would go up on top of
    a base it does not contain, the narrow gate would have validated a tree
    that is NOT the published one, and the pull request would be born red.
    The publication is ABORTED: the branch stays local, the turn reports it
    and nothing is published.

    The rule is EXECUTABLE in two shapes:
      * a STRUCTURAL one: the order is checked by the LINE NUMBERS of
        `bin/agent-issue.sh` (the rebase, the narrow gate, the push), and
        the failure path of the rebase is checked to ABORT the rebase and to
        STOP the publication (it does `exit`);
      * a BEHAVIOURAL one: the block of the rebase is taken from the script
        and RUN against a `git` of the test whose rebase FAILS: the block
        ends with the exit status 9 (the publication is aborted), it says
        that nothing is published and the `git` of the test recorded the
        `rebase --abort`.
    """
    print("48. the branch is rebased before the gate and before the push")
    agent = os.path.join(LOOP, "bin", "agent-issue.sh")
    if not os.path.exists(agent):
        check("the script of the agent issue is there", False, agent)
        return
    with open(agent, encoding="utf-8") as fh:
        src = fh.read()
    lines = src.splitlines()

    def line_of(pattern):
        """The line number of the first line that matches the pattern."""
        for number, line in enumerate(lines, 1):
            if re.search(pattern, line):
                return number
        return 0

    rebase = line_of(r"rebase \"\$BASE_REF\"")
    gate = line_of(r"cargo fmt --all -- --check")
    push = line_of(r"push --force-with-lease")
    check("the script rebases the branch", rebase > 0, "no rebase was found")
    check("the script runs the narrow gate", gate > 0,
          "no narrow gate was found")
    check("the script pushes the branch", push > 0, "no push was found")
    check("the rebase happens BEFORE the narrow gate", 0 < rebase < gate,
          f"rebase={rebase} gate={gate}")
    check("the rebase happens BEFORE the push", 0 < rebase < push,
          f"rebase={rebase} push={push}")

    # The block of the rebase, taken from the script.
    try:
        block = (bash_between(src, 'if git -C "$WORK" rebase "$BASE_REF"',
                               "\nfi\n") + "\nfi\n")
    except ValueError:
        block = ""
    check("the block of the rebase is in the script", block != "",
          "the block of the rebase was not found")
    if not block:
        return
    check("a rebase that fails stops the publication",
          "exit" in block, block)
    check("a rebase that fails is aborted", "rebase --abort" in block, block)

    # --- the behaviour: the block RUN against a `git` whose rebase FAILS ---
    root = tempfile.mkdtemp(prefix="rule48-")
    try:
        stub_dir = os.path.join(root, "bin")
        os.makedirs(stub_dir, exist_ok=True)
        log = os.path.join(root, "git.log")
        stub = os.path.join(stub_dir, "git")
        write_script(stub,
                     "#!/usr/bin/env bash\n"
                     "# The `git` of the test: the rebase FAILS and every call\n"
                     "# is recorded.\n"
                     "printf '%s\\n' \"$*\" >> \"${GIT_STUB_LOG:-/dev/null}\"\n"
                     "for a in \"$@\"; do\n"
                     "  if [ \"$a\" = \"rebase\" ]; then\n"
                     "    case \" $* \" in\n"
                     "      *\" --abort \"*) exit 0 ;;\n"
                     "      *) exit 1 ;;\n"
                     "    esac\n"
                     "  fi\n"
                     "done\n"
                     "exit 0\n")
        os.chmod(stub, 0o755)
        script = os.path.join(root, "rebase.sh")
        write_script(script,
                     "#!/usr/bin/env bash\n"
                     "WORK=\"" + root + "\"\n"
                     "BASE_REF=refs/remotes/agent/upstream-main\n" + block)
        env = dict(os.environ)
        env["PATH"] = stub_dir + os.pathsep + env.get("PATH", "")
        env["GIT_STUB_LOG"] = log
        run = subprocess.run(["bash", script], env=env, capture_output=True,
                             text=True, timeout=60)
        check("a rebase that fails stops the publication",
              run.returncode == 9, f"rc={run.returncode} {run.stderr[-200:]}")
        check("a rebase that fails says that nothing is published",
              "nothing is published" in run.stderr, run.stderr.strip()[-200:])
        recorded = ""
        if os.path.exists(log):
            with open(log, encoding="utf-8") as fh:
                recorded = fh.read()
        check("a rebase that fails aborts the rebase",
              "rebase --abort" in recorded, recorded.strip()[-200:])
    finally:
        shutil.rmtree(root, ignore_errors=True)


# --- 49: the duplicate pull requests are detected and reported --------------
def test_the_duplicate_pull_requests_are_detected():
    """The duplicate pull requests are DETECTED and REPORTED.

    WHY: the upstream applies "the lowest numbered open pull request wins":
    when two OPEN pull requests mention the same issue, the one with the
    LOWER number holds the claim. Our pull request that lost that race is a
    duplicate, and the loop CANNOT close it (the sandbox vetoes `gh pr
    close`): it DETECTS it, it REPORTS it and it stands down on that pull
    request (a human closes it).

    The exit codes are the contract: 0 no duplicate, 1 at least one duplicate
    (with the line `duplicate: ours=<n> other=<n> issue=#<n>`), and 6 GitHub
    could not be read: 6 is UNKNOWN, never "there is a duplicate"
    (fail-open).

    The rule is EXECUTABLE: `bin/claim-guard.sh --duplicates` is RUN against
    a `gh` of the tests that answers the two lists the mode reads (the open
    pull requests of OURS and the open pull requests of anyone) with two
    different answers.
    """
    print("49. the duplicate pull requests are detected and reported")
    guard = os.path.join(LOOP, "bin", "claim-guard.sh")
    if not os.path.exists(guard):
        check("the guard of the claim is there", False, guard)
        return
    check("the guard of the claim is a valid bash",
          subprocess.run(["bash", "-n", guard], capture_output=True,
                         text=True).returncode == 0)

    root = tempfile.mkdtemp(prefix="rule49-")
    try:
        home = os.path.join(root, "home")
        loop = os.path.join(root, "loop")
        stub_dir = os.path.join(root, "bin")
        for folder in (home, loop, stub_dir):
            os.makedirs(folder, exist_ok=True)
        with open(os.path.join(loop, "config.env"), "w", encoding="utf-8") as fh:
            fh.write("UPSTREAM=acme/one\nFORK_OWNER=forkowner\n")
        log = os.path.join(root, "gh.log")
        # The `gh` of the test: GitHub is never contacted. The two lists the
        # mode reads get two different answers: the one of OURS carries
        # `--author`, the one of anyone does not.
        stub = os.path.join(stub_dir, "gh")
        write_script(stub,
                     "#!/usr/bin/env bash\n"
                     "printf '%s\\n' \"$*\" >> \"${STUB_LOG:-/dev/null}\"\n"
                     "if [ -n \"${STUB_FAIL:-}\" ]; then\n"
                     "  echo \"gh: could not connect to github.com\" >&2\n"
                     "  exit 1\n"
                     "fi\n"
                     "case \"${1:-} ${2:-}\" in\n"
                     "  \"pr list\")\n"
                     "    for a in \"$@\"; do\n"
                     "      if [ \"$a\" = \"--author\" ]; then\n"
                     "        printf '%s' \"${STUB_OURS:-[]}\"\n"
                     "        exit 0\n"
                     "      fi\n"
                     "    done\n"
                     "    printf '%s' \"${STUB_OTHERS:-[]}\"\n"
                     "    exit 0\n"
                     "    ;;\n"
                     "esac\n"
                     "exit 1\n")
        os.chmod(stub, 0o755)

        env = dict(os.environ)
        env["PATH"] = stub_dir + os.pathsep + env.get("PATH", "")
        env["HOME"] = home
        env["LOOP_DIR"] = loop
        env["STUB_LOG"] = log
        # The work directory of the guard is inside the one of the test.
        env["TMPDIR"] = root

        def guard_duplicates(ours, others, fail=False):
            """The mode of the duplicates, RUN against the `gh` of the test."""
            local = dict(env)
            local["STUB_OURS"] = json.dumps(ours)
            local["STUB_OTHERS"] = json.dumps(others)
            if fail:
                local["STUB_FAIL"] = "1"
            return subprocess.run(["bash", guard, "--duplicates"], env=local,
                                  capture_output=True, text=True, timeout=120)

        ours = [{"number": 42, "title": "a fix", "body": "Fixes #123"}]
        # --- a) our pull request lost the race --------------------------------
        out = guard_duplicates(ours, [{"number": 17, "title": "another fix",
                                        "body": "Fixes #123"}])
        check("a pull request that lost the race is reported",
              out.returncode == 1, f"rc={out.returncode} {out.stdout[-300:]}")
        check("the duplicate names our pull request, the other one and the issue",
              "duplicate: ours=42 other=17 issue=#123" in out.stdout,
              out.stdout.strip()[-300:])
        # --- b) there is no duplicate -----------------------------------------
        out = guard_duplicates(ours, [{"number": 17, "title": "another fix",
                                        "body": "Fixes #999"}])
        check("a pull request that did not lose the race is not a duplicate",
              out.returncode == 0, f"rc={out.returncode} {out.stdout[-300:]}")
        check("no duplicate is reported when there is none",
              "duplicate:" not in out.stdout, out.stdout.strip()[-300:])
        # --- c) a GitHub that cannot be read is UNKNOWN, not a duplicate ------
        out = guard_duplicates(ours, ours, fail=True)
        check("a GitHub that cannot be read is not a verdict",
              out.returncode == 6, f"rc={out.returncode} {out.stdout[-300:]}")
        check("a GitHub that cannot be read is never read as a duplicate",
              "duplicate:" not in out.stdout, out.stdout.strip()[-300:])
        # --- the pull request of ours with the HIGHER number does not lose ---
        out = guard_duplicates(ours, [{"number": 50, "title": "a later fix",
                                        "body": "Fixes #123"}])
        check("the pull request with the lower number wins the race",
              out.returncode == 0, f"rc={out.returncode} {out.stdout[-300:]}")
        check("a pull request with a higher number is not a duplicate",
              "duplicate:" not in out.stdout, out.stdout.strip()[-300:])

        # --- the mode READS the configuration and it never CLOSES -------------
        recorded = ""
        if os.path.exists(log):
            with open(log, encoding="utf-8") as fh:
                recorded = fh.read()
        check("the mode reads the open pull requests of ours",
              "--repo acme/one --author forkowner" in recorded,
              recorded.strip()[-300:])
        check("the mode reads the open pull requests of anyone",
              re.search(r"--repo acme/one --state open", recorded) is not None,
              recorded.strip()[-300:])
        truncating = [line for line in recorded.splitlines()
                      if "pr list" in line and re.search(r"--limit(?:=|\s+)100(?:\s|$)", line)]
        check("no list of pull requests is truncated in silence",
              not truncating, truncating)
        closes = [line for line in recorded.splitlines()
                  if re.search(r"\b(pr close|pr edit|pr create|pr merge|"
                               r"api -X DELETE)\b", line)]
        check("the mode never closes anything", not closes, closes)
    finally:
        shutil.rmtree(root, ignore_errors=True)


# --- 51: the verdict of the line of the defaults is COMPUTED ---------------
def test_the_verdict_of_the_line_of_the_defaults_is_computed():
    """The line of the defaults is COMPUTED and the loop NEVER says `yes`.

    WHY (B1, B2): the upstream asks every pull request to say whether it
    changes a default, but the loop does not get to make that claim: a
    change of a default keeps the old behaviour behind a preference and the
    DECISION is the maintainer's (skills/solidcraft-preferences/SKILL.md).
    A `yes` written by the loop is either a lie (the change really happens)
    or a policy decision taken by a machine.

    So the verdict is COMPUTED, not written by hand, and it is fail-closed:
    anything the loop cannot read is an ESCALATION (a person decides) and
    never a `yes`.

    The rule is EXECUTABLE in two shapes:
      * a STRUCTURAL one: the literal `Changes a default: no` is NOT in the
        script (nobody writes the line by hand) and the verdict is a
        function of the script;
      * a BEHAVIOURAL one: that function is taken from the script and RUN:
        it prints `no` for a change that is not a change of a default and
        `escalate` for anything else, and the dry run of the agent STOPS
        (exit 7) when the verdict is an escalation.
    """
    print("51. the verdict of the line of the defaults is computed")
    agent = os.path.join(LOOP, "bin", "agent-issue.sh")
    if not os.path.exists(agent):
        check("the script of the agent issue is there", False, agent)
        return
    with open(agent, encoding="utf-8") as fh:
        src = fh.read()

    check("the script does not write the line of the defaults by hand",
          "Changes a default: no" not in src,
          "the line of the defaults is written by hand")
    check("the script computes the verdict of the line",
          "defaults_verdict()" in src, "there is no function of the verdict")
    try:
        verdict = bash_func(src, "defaults_verdict")
    except ValueError:
        check("the verdict is a function of the script", False,
              "defaults_verdict() was not found")
        return

    root = tempfile.mkdtemp(prefix="rule51-")
    try:
        script = os.path.join(root, "verdict.sh")
        write_script(script,
                     "#!/usr/bin/env bash\n"
                     "set -uo pipefail\n" + verdict +
                     'defaults_verdict "$1" "$2"\n')

        def of(received, changed=""):
            """The verdict of the script, RUN."""
            return subprocess.run(["bash", script, received, changed],
                                  capture_output=True, text=True,
                                  timeout=60).stdout.strip()

        check("a change that is not a change of a default is published as no",
              of("no") == "no", of("no"))
        check("nothing claimed is published as no", of("") == "no", of(""))
        check("the dot of the upstream is a no", of("no.") == "no", of("no."))
        check("a yes is never decided by the loop",
              of("yes - the default of the theme") == "escalate",
              of("yes - the default of the theme"))
        check("a claim the loop cannot read is an escalation",
              of("maybe") == "escalate", of("maybe"))
        check("a change of a file of the defaults is an escalation",
              of("no", "crates/ui-egui/src/prefs.rs") == "escalate",
              of("no", "crates/ui-egui/src/prefs.rs"))
        check("a change of another file is not an escalation",
              of("no", "crates/core/src/lib.rs") == "no",
              of("no", "crates/core/src/lib.rs"))

        # --- the dry run of the agent STOPS when the verdict escalates ------
        loop = os.path.join(root, "loop")
        os.makedirs(loop, exist_ok=True)
        with open(os.path.join(loop, "config.env"), "w", encoding="utf-8") as fh:
            fh.write("UPSTREAM=acme/one\nFORK_OWNER=forkowner\n")
        env = dict(os.environ)
        env["HOME"] = os.path.join(root, "home")
        env["LOOP_DIR"] = loop

        def dry(received):
            """The dry run of the agent issue, with a received verdict."""
            local = dict(env)
            local["AGENT_CHANGES_DEFAULT"] = received
            return subprocess.run(["bash", agent, "--dry-run", "--repo",
                                   "acme/one", "--pr-repo", "acme/one",
                                   "7058"], env=local, capture_output=True,
                                  text=True, timeout=60)

        out = dry("yes - the default of the theme")
        check("a change of a default stops the dry run",
              out.returncode == 7, f"rc={out.returncode} {out.stderr[-200:]}")
        check("the dry run of an escalation prints no body",
              "pr-body-line:" not in out.stdout, out.stdout.strip()[-200:])
        out = dry("no")
        check("a change that is not a change of a default is published",
              out.returncode == 0, f"rc={out.returncode} {out.stderr[-200:]}")
        check("the published line is a no",
              "pr-body-line: Changes a default: no" in out.stdout,
              out.stdout.strip()[-200:])
    finally:
        shutil.rmtree(root, ignore_errors=True)


# --- 52: the line of the defaults is checked before and after ---------------
def test_the_line_of_the_defaults_is_checked_before_and_after():
    """The line of the defaults is CHECKED before the publication and after
    it (B1c, B5).

    WHY: the line that `bin/pr-defaults-line.sh` checks is written by a model
    (prompts/claim.md) and the check is an INSPECTOR: nobody reads its exit
    code, so a pull request without the line is born red in the upstream (the
    upstream pull request #8010 is in `failure` for exactly this).
    So the check enters the brake of the publication:
      * a PRE-FLIGHT, against the body of the file that is going to be
        published, BEFORE the push: a body without the line never leaves the
        machine;
      * a POST-FLIGHT, against the published pull request, AFTER it is open:
        the publication can fail, and then the line is not confirmed.
    Both speak the SAME exit code: 8, "the line of the defaults is not
    confirmed".

    The rule is EXECUTABLE: the two blocks are taken from the script and RUN
    (the pre-flight against a body of a file, the post-flight against a `gh`
    of the tests).
    """
    print("52. the line of the defaults is checked before and after")
    agent = os.path.join(LOOP, "bin", "agent-issue.sh")
    if not os.path.exists(agent):
        check("the script of the agent issue is there", False, agent)
        return
    with open(agent, encoding="utf-8") as fh:
        src = fh.read()
    lines = src.splitlines()

    def line_of(pattern):
        """The line number of the first line that matches the pattern."""
        for number, line in enumerate(lines, 1):
            if re.search(pattern, line):
                return number
        return 0

    pre_anchor = "# --- the pre-flight of the line of the defaults ---"
    post_anchor = "# --- the post-flight of the line of the defaults ---"
    end_anchor = "# --- the end of the publication ---"
    publish = ""
    for line in lines:
        if line.startswith("# --- publicar"):
            publish = line
            break
    for name, anchor in (("the pre-flight", pre_anchor),
                         ("the post-flight", post_anchor),
                         ("the publication", publish),
                         ("the end of the publication", end_anchor)):
        check(f"the script has the anchor of {name}",
              bool(anchor) and anchor in src, anchor)
    if not (pre_anchor in src and post_anchor in src
            and publish and publish in src and end_anchor in src):
        return

    pre = line_of(re.escape(pre_anchor))
    push = line_of(r"push --force-with-lease")
    opened = line_of(r"repos/\$PR_REPO/pulls")
    post = line_of(re.escape(post_anchor))
    check("the pre-flight happens BEFORE the push", 0 < pre < push,
          f"pre={pre} push={push}")
    check("the pre-flight happens BEFORE the pull request is opened",
          0 < pre < opened, f"pre={pre} opened={opened}")
    check("the post-flight happens AFTER the pull request is opened",
          0 < opened < post, f"opened={opened} post={post}")

    # The exit codes of the script are DOCUMENTED in its header: the caller
    # (the loop, the runbook) reads them there and nowhere else.
    head = src[:4000]
    documented = {int(m) for m in re.findall(r"^#\s+(\d+)\s{2,}", head, re.M)}
    for code in (7, 8, 9):
        check(f"the script documents the exit code {code}", code in documented,
              sorted(documented))

    root = tempfile.mkdtemp(prefix="rule52-")
    try:
        home = os.path.join(root, "home")
        os.makedirs(home, exist_ok=True)
        body_ok = os.path.join(root, "body-ok.md")
        with open(body_ok, "w", encoding="utf-8") as fh:
            fh.write("Fixes #7058\nChanges a default: no\n")
        body_bad = os.path.join(root, "body-bad.md")
        with open(body_bad, "w", encoding="utf-8") as fh:
            fh.write("Fixes #7058\n")

        # --- the pre-flight, RUN against a body of a file --------------------
        script = os.path.join(root, "preflight.sh")
        write_script(script, "#!/usr/bin/env bash\nset -uo pipefail\n"
                     + bash_between(src, pre_anchor, publish))
        env = dict(os.environ)
        env["HOME"] = home
        env["SCRIPT_DIR"] = os.path.join(LOOP, "bin")
        env["BODY_FILE"] = body_ok
        run = subprocess.run(["bash", script], env=env, capture_output=True,
                             text=True, timeout=60)
        check("the pre-flight accepts a body with the line",
              run.returncode == 0,
              f"rc={run.returncode} {run.stderr[-200:]}")
        env["BODY_FILE"] = body_bad
        run = subprocess.run(["bash", script], env=env, capture_output=True,
                             text=True, timeout=60)
        check("the pre-flight stops a body without the line",
              run.returncode == 8,
              f"rc={run.returncode} {run.stderr[-200:]}")
        check("the pre-flight says that nothing is published",
              "nothing is published" in run.stderr, run.stderr.strip()[-200:])

        # --- the post-flight, RUN against a `gh` of the tests ----------------
        stub_dir = os.path.join(root, "bin")
        os.makedirs(stub_dir, exist_ok=True)
        stub = os.path.join(stub_dir, "gh")
        write_script(stub,
                     "#!/usr/bin/env bash\n"
                     "case \"${1:-} ${2:-}\" in\n"
                     "  \"pr view\")\n"
                     "    if [ -n \"${STUB_NO_LINE:-}\" ]; then\n"
                     "      printf '%s' 'nothing here'\n"
                     "    else\n"
                     "      printf '%s' 'Changes a default: no'\n"
                     "    fi\n"
                     "    exit 0\n"
                     "    ;;\n"
                     "esac\n"
                     "exit 1\n")
        os.chmod(stub, 0o755)
        script = os.path.join(root, "postflight.sh")
        write_script(script, "#!/usr/bin/env bash\nset -uo pipefail\n"
                     + bash_between(src, post_anchor, end_anchor))
        env["PATH"] = stub_dir + os.pathsep + env.get("PATH", "")
        env["LOOP_DIR"] = os.path.join(root, "loop")
        os.makedirs(env["LOOP_DIR"], exist_ok=True)
        env["PR_NUMBER"] = "42"
        env["PR_REPO"] = "acme/one"
        env["UPSTREAM"] = "acme/one"
        env["FORK_OWNER"] = "forkowner"
        run = subprocess.run(["bash", script], env=env, capture_output=True,
                             text=True, timeout=60)
        check("the post-flight accepts a pull request with the line",
              run.returncode == 0,
              f"rc={run.returncode} {run.stderr[-200:]}")
        env["STUB_NO_LINE"] = "1"
        run = subprocess.run(["bash", script], env=env, capture_output=True,
                             text=True, timeout=60)
        check("the post-flight stops a pull request without the line",
              run.returncode == 8,
              f"rc={run.returncode} {run.stderr[-200:]}")
        check("the post-flight says that the publication is not confirmed",
              "not confirmed" in run.stderr.lower(),
              run.stderr.strip()[-200:])
    finally:
        shutil.rmtree(root, ignore_errors=True)


# --- 53: the brake of the claim runs before the publication ----------------
def test_the_guard_of_the_claim_runs_before_the_publication():
    """The BRAKE of the claim runs BEFORE the publication and its exit code
    decides (B4).

    WHY: `bin/claim-guard.sh` was called by the prompts only: the code that
    PUBLISHES (`bin/agent-issue.sh`) never called it, so the brake of the
    claim was an instruction to a model and not a rule. A model forgets an
    instruction once in a while; a script does not.

    So the script runs the BRAKE (`bin/claim-brake.sh`) before it publishes
    and does NOT publish when the brake does not answer 0. The exit code of
    the brake IS the verdict of the brake and it is NOT translated:
      0   OK        the claim is ours (or the issue is free): publish.
      10  TAKEN     somebody else holds it: our pull request LOST the race
                    (or the issue was taken before we started). The work is
                    SAVED and the publish is REFUSED.
      11  RESOLVED  the issue is not open any more: nobody won a race
                    against us, the work is MOOT for this issue (it can be
                    re-targeted) but not lost. The work is SAVED and the
                    publish is REFUSED.
      12  UNKNOWN   GitHub could not be read: the brake does NOT know, and
                    a publish without a check is a duplicate waiting to
                    happen. The work is SAVED and the publish is REFUSED.

    The brake is told WHICH pull request is ours (`--pr <n>`), so our own
    pull request does not take the claim of its issue away from us.

    The rule is EXECUTABLE: the block of the brake is taken from the script
    and RUN against a brake of the tests whose exit code is the verdict.
    """
    print("53. the guard of the claim runs before the publication")
    agent = os.path.join(LOOP, "bin", "agent-issue.sh")
    if not os.path.exists(agent):
        check("the script of the agent issue is there", False, agent)
        return
    with open(agent, encoding="utf-8") as fh:
        src = fh.read()

    brake = "# --- the brake of the claim ---"
    verdict = "# --- the brake of the line of the defaults ---"
    check("the script has the anchor of the brake of the claim",
          brake in src, brake)
    check("the script has the anchor of the brake of the line",
          verdict in src, verdict)
    if brake not in src or verdict not in src:
        return

    block = bash_between(src, brake, verdict)
    check("the brake of the claim calls the brake", "claim-brake.sh" in block,
          block)
    check("the brake of the claim does NOT call the old guard",
          "claim-guard.sh" not in block, block)
    brake_at = src.index(brake)
    push_at = src.find("push --force-with-lease")
    check("the brake runs BEFORE the push", 0 <= brake_at < push_at,
          f"brake={brake_at} push={push_at}")

    root = tempfile.mkdtemp(prefix="rule53-")
    try:
        fake_bin = os.path.join(root, "bin")
        os.makedirs(fake_bin, exist_ok=True)
        args_log = os.path.join(root, "brake-args.log")
        # The brake of the test: it records its arguments and answers with the
        # exit code of the environment. The brake is what the publisher calls
        # (the ONE rule of the claim is in bin/claim-race.sh behind it).
        stub = os.path.join(fake_bin, "claim-brake.sh")
        write_script(stub,
                     "#!/usr/bin/env bash\n"
                     "printf '%s\\n' \"$*\" >> \"${BRAKE_ARGS_LOG:-/dev/null}\"\n"
                     "exit \"${BRAKE_RC:-0}\"\n")
        os.chmod(stub, 0o755)
        script = os.path.join(root, "brake.sh")
        write_script(script, "#!/usr/bin/env bash\nset -uo pipefail\n" + block)
        env = dict(os.environ)
        env["SCRIPT_DIR"] = fake_bin
        env["ISSUE"] = CLAIM_ISSUE
        env["BRAKE_ARGS_LOG"] = args_log
        env["BRAKE_RC"] = "0"
        run = subprocess.run(["bash", script], env=env, capture_output=True,
                             text=True, timeout=60)
        check("a brake that allows the claim lets the publication continue",
              run.returncode == 0,
              f"rc={run.returncode} {run.stderr[-200:]}")
        # The exit codes of the brake ARE the verdict: 10 the claim was
        # taken, 11 the issue is not open any more, 12 GitHub could not be
        # read. None of them publishes, and none of them is translated.
        for rc, why in (("10", "the claim was taken"),
                        ("11", "the issue is not open any more"),
                        ("12", "GitHub could not be read")):
            env["BRAKE_RC"] = rc
            run = subprocess.run(["bash", script], env=env, capture_output=True,
                                 text=True, timeout=60)
            check(f"the exit code of the brake ({why}) decides the publication",
                  run.returncode == int(rc),
                  f"rc={run.returncode} {run.stderr[-200:]}")
            check(f"the exit code of the brake ({why}) is not translated",
                  run.returncode == int(rc),
                  f"rc={run.returncode} {run.stderr[-200:]}")
            check(f"the brake ({why}) says that nothing is published",
                  "no publico nada" in run.stderr,
                  run.stderr.strip()[-200:])

        # --- the brake is told which pull request is ours -------------------
        recorded = ""
        if os.path.exists(args_log):
            with open(args_log, encoding="utf-8") as fh:
                recorded = fh.read()
        check("the brake is called with the issue",
              CLAIM_ISSUE in recorded, recorded.strip()[-200:])
        check("the brake is not told about a pull request that does not exist",
              "--pr" not in recorded, recorded.strip()[-200:])
        check("the brake is not called with the flag of the old guard",
              "--ours" not in recorded, recorded.strip()[-200:])
        if os.path.exists(args_log):
            os.unlink(args_log)
        env["BRAKE_RC"] = "0"
        env["EXISTING_PR"] = CLAIM_PR
        run = subprocess.run(["bash", script], env=env, capture_output=True,
                             text=True, timeout=60)
        recorded = ""
        if os.path.exists(args_log):
            with open(args_log, encoding="utf-8") as fh:
                recorded = fh.read()
        check("the brake is told which pull request is ours",
              "--pr %s" % CLAIM_PR in recorded, recorded.strip()[-200:])

        # --- the question the publisher asks is a question the RULE answers -
        # The brake is run FOR REAL here (the ONE rule of the claim is behind
        # it) against a `gh` of the tests: a question the rule refuses (a
        # mode it does not know, for example) is not a verdict but an
        # ERROR, the brake answers UNKNOWN (12) and NOTHING is ever
        # published. The publisher has to ask the rule something it knows.
        real = os.path.join(root, "real")
        real_bin = os.path.join(real, "bin")
        real_loop = os.path.join(real, "loop")
        os.makedirs(real_bin, exist_ok=True)
        os.makedirs(real_loop, exist_ok=True)
        gh = os.path.join(real_bin, "gh")
        write_script(gh,
                     "#!/usr/bin/env bash\n"
                     "case \"${1:-}\" in\n"
                     "  issue) printf '%s' \"$STUB_ISSUE\"; exit 0 ;;\n"
                     "  pr)    printf '%s' '[]'; exit 0 ;;\n"
                     "  api)   printf '%s' '[]'; exit 0 ;;\n"
                     "esac\n"
                     "exit 1\n")
        os.chmod(gh, 0o755)
        with open(os.path.join(real_loop, "config.env"), "w", encoding="utf-8") as fh:
            fh.write("SC_REPO=acme/one\nFORK_OWNER=forkowner\n")
        renv = dict(os.environ)
        renv["PATH"] = real_bin + os.pathsep + renv.get("PATH", "")
        renv["LOOP_DIR"] = real_loop
        renv["SCRIPT_DIR"] = os.path.join(LOOP, "bin")
        renv["ISSUE"] = CLAIM_ISSUE
        # The issue of the tests: OPEN, without labels, without assignees
        # and without comments: nobody holds its claim.
        renv["STUB_ISSUE"] = json.dumps({
            "number": int(CLAIM_ISSUE), "state": "OPEN", "stateReason": "",
            "title": "an issue of the tests", "labels": [], "assignees": [],
            "comments": []})
        run = subprocess.run(["bash", script], env=renv, capture_output=True,
                             text=True, timeout=120)
        check("the question the publisher asks the rule is a question it answers",
              run.returncode == 0 and "VERDICT=OK" in run.stderr,
              f"rc={run.returncode} {run.stderr[-300:]}")
    finally:
        shutil.rmtree(root, ignore_errors=True)


# --- 58: the claim is checked BEFORE the model starts ---------------------
def test_the_claim_is_checked_before_the_model_starts():
    """The claim of the issue is re-verified BEFORE the model starts (B4).

    WHY: the race is lost BETWEEN the survey of the issues and the opening
    of the draft, because the bot of the upstream applies the label 'in
    progress' with a DELAY. The brake at the publish catches it, but by
    then the agent has written the code, the gate has compiled the scope
    and the hours are spent. A race that is already lost has to cost a
    call to GitHub and nothing else.

    So the claim is checked again before the model runs, and the model does
    NOT start when the brake says the claim is gone: the work is saved by
    the brake, so nothing is thrown away, the turn says it early.

    The rule is EXECUTABLE: the block of the check is taken from the script
    and RUN against a brake of the tests whose exit code is the verdict.
    """
    print("58. the claim is checked before the model starts")
    agent = os.path.join(LOOP, "bin", "agent-issue.sh")
    if not os.path.exists(agent):
        check("the script of the agent issue is there", False, agent)
        return
    with open(agent, encoding="utf-8") as fh:
        src = fh.read()

    early = "# --- the claim is checked BEFORE the model starts"
    model = "# --- el agente ---"
    check("the script has the anchor of the early check of the claim",
          early in src, early)
    check("the script has the anchor of the agent", model in src, model)
    if early not in src or model not in src:
        return

    early_at = src.index(early)
    model_at = src.index(model)
    check("the early check of the claim runs BEFORE the model",
          0 <= early_at < model_at, f"early={early_at} model={model_at}")
    # The model itself is AFTER the check: the check is not a comment next
    # to the model, it is a check that runs before it.
    run_at = src.find("opencode run")
    check("the model runs AFTER the early check of the claim",
          0 <= early_at < run_at, f"early={early_at} model={run_at}")

    block = bash_between(src, early, model)
    check("the early check of the claim calls the brake",
          "claim-brake.sh" in block, block)
    check("the early check of the claim does NOT call the old guard",
          "claim-guard.sh" not in block, block)

    root = tempfile.mkdtemp(prefix="rule58-")
    try:
        fake_bin = os.path.join(root, "bin")
        os.makedirs(fake_bin, exist_ok=True)
        args_log = os.path.join(root, "brake-args.log")
        # The brake of the test: it records its arguments and answers with the
        # exit code of the environment.
        stub = os.path.join(fake_bin, "claim-brake.sh")
        write_script(stub,
                     "#!/usr/bin/env bash\n"
                     "printf '%s\\n' \"$*\" >> \"${BRAKE_ARGS_LOG:-/dev/null}\"\n"
                     "exit \"${BRAKE_RC:-0}\"\n")
        os.chmod(stub, 0o755)
        script = os.path.join(root, "early.sh")
        write_script(script, "#!/usr/bin/env bash\nset -uo pipefail\n" + block)
        env = dict(os.environ)
        env["SCRIPT_DIR"] = fake_bin
        env["ISSUE"] = CLAIM_ISSUE
        env["BRAKE_ARGS_LOG"] = args_log
        env["BRAKE_RC"] = "0"
        run = subprocess.run(["bash", script], env=env, capture_output=True,
                             text=True, timeout=60)
        check("a brake that allows the claim lets the model start",
              run.returncode == 0,
              f"rc={run.returncode} {run.stderr[-200:]}")
        # A brake that says the claim is gone STOPS the model: the exit
        # code of the brake is the exit code of the turn, and it is NOT
        # translated.
        for rc, why in (("10", "the claim was taken"),
                        ("11", "the issue is not open any more"),
                        ("12", "GitHub could not be read")):
            env["BRAKE_RC"] = rc
            run = subprocess.run(["bash", script], env=env, capture_output=True,
                                 text=True, timeout=60)
            check(f"the model does NOT start when the brake says {why}",
                  run.returncode == int(rc),
                  f"rc={run.returncode} {run.stderr[-200:]}")
            check(f"the brake ({why}) says that the model does not start",
                  "el modelo no arranca" in run.stderr,
                  run.stderr.strip()[-200:])

        # --- the early check is told which pull request is ours -----------
        recorded = ""
        if os.path.exists(args_log):
            with open(args_log, encoding="utf-8") as fh:
                recorded = fh.read()
        check("the early check is called with the issue",
              CLAIM_ISSUE in recorded, recorded.strip()[-200:])
        check("the early check is not told about a pull request that does not exist",
              "--pr" not in recorded, recorded.strip()[-200:])
        if os.path.exists(args_log):
            os.unlink(args_log)
        env["BRAKE_RC"] = "0"
        env["EXISTING_PR"] = CLAIM_PR
        run = subprocess.run(["bash", script], env=env, capture_output=True,
                             text=True, timeout=60)
        recorded = ""
        if os.path.exists(args_log):
            with open(args_log, encoding="utf-8") as fh:
                recorded = fh.read()
        check("the early check is told which pull request is ours",
              "--pr %s" % CLAIM_PR in recorded, recorded.strip()[-200:])
    finally:
        shutil.rmtree(root, ignore_errors=True)


# --- 54: the queue of the loop is counted by ORIGIN --------------------------
def test_the_queue_of_the_loop_is_counted_by_origin():
    """The queue of the loop is counted by ORIGIN, the retired pull requests
    are NOT counted, and a truncated list is a LOUD failure (B6, B7, B8, B9).

    WHY: the ceiling (`MAINT_THRESHOLD`) is the brake of the loop, and a brake
    that counts the wrong thing is no brake at all. The count was made by
    AUTHOR: every open pull request of the fork owner counted, including the
    ones a human opened by hand, and the pull requests the loop RETIRED
    (`RETIRED_PRS`) kept the queue busy forever. On top of that the list was
    read with a limit of 100 and the truncation was silent: a list of 100 pull
    requests says "100" when there are two hundred.

    So the count is made BY ORIGIN (the branches the loop opens), the retired
    pull requests are subtracted, and a truncated list is exit 6: the guard does
    NOT know, and a claim without a check is a duplicate waiting to happen.

    The rule is EXECUTABLE: the guard is RUN against a `gh` of the tests.
    """
    print("54. the queue of the loop is counted by origin")
    guard = os.path.join(LOOP, "bin", "claim-guard.sh")
    if not os.path.exists(guard):
        check("the guard of the claim is there", False, guard)
        return
    check("the guard of the claim is a valid bash",
          subprocess.run(["bash", "-n", guard], capture_output=True,
                         text=True).returncode == 0)

    root = tempfile.mkdtemp(prefix="rule54-")
    try:
        home = os.path.join(root, "home")
        loop = os.path.join(root, "loop")
        stub_dir = os.path.join(root, "bin")
        for folder in (home, loop, stub_dir):
            os.makedirs(folder, exist_ok=True)
        log = os.path.join(root, "gh.log")
        # The `gh` of the test: GitHub is never contacted.
        stub = os.path.join(stub_dir, "gh")
        write_script(stub,
                     "#!/usr/bin/env bash\n"
                     "printf '%s\\n' \"$*\" >> \"${STUB_LOG:-/dev/null}\"\n"
                     "case \"${1:-}\" in\n"
                     "  issue)\n"
                     "    if [ \"${2:-}\" = \"view\" ]; then\n"
                     "      printf '%s' \"${STUB_ISSUE:-}\"; exit 0\n"
                     "    fi\n"
                     "    ;;\n"
                     "  pr)\n"
                     "    if [ \"${2:-}\" = \"list\" ]; then\n"
                     "      for a in \"$@\"; do\n"
                     "        if [ \"$a\" = \"--author\" ]; then\n"
                     "          printf '%s' \"${STUB_OURS:-[]}\"; exit 0\n"
                     "        fi\n"
                     "      done\n"
                     "      printf '%s' \"${STUB_PRS:-[]}\"; exit 0\n"
                     "    fi\n"
                     "    ;;\n"
                     "  api)\n"
                     "    printf '%s' \"${STUB_CROSS:-}\"; exit 0\n"
                     "    ;;\n"
                     "esac\n"
                     "exit 1\n")
        os.chmod(stub, 0o755)

        issue = json.dumps({"number": 7058, "state": "OPEN",
                            "title": "a bug", "labels": [{"name": "bug"}]})
        # Six open pull requests of ours: four of the loop (one of them
        # RETIRED), one of an unknown origin (it counts as of the loop: the
        # guard does not know, and a brake that lets go is no brake) and one
        # opened by hand (it is not the queue of the loop).
        ours = [
            {"number": 101, "headRefName": "fix/issue-1-a"},
            {"number": 102, "headRefName": "spike/issue-2-b"},
            {"number": 103, "headRefName": "fix/issue-3-c"},
            {"number": 104, "headRefName": ""},
            {"number": 105, "headRefName": "manual/hand-made"},
            {"number": 106, "headRefName": "fix/issue-4-d"},
        ]

        def run_guard(ceiling="5", retired="106", ours_limit=None,
                      pr_limit=None, prs=None, args=("7058",)):
            """The guard of the claim, RUN against the `gh` of the test."""
            config = ["UPSTREAM=acme/one", "FORK_OWNER=forkowner",
                      "MAINT_THRESHOLD=%s" % ceiling,
                      "RETIRED_PRS=%s" % retired]
            if ours_limit:
                config.append("CLAIM_OUR_PR_LIMIT=%s" % ours_limit)
            if pr_limit:
                config.append("CLAIM_PR_LIMIT=%s" % pr_limit)
            with open(os.path.join(loop, "config.env"), "w",
                      encoding="utf-8") as fh:
                fh.write("\n".join(config) + "\n")
            env = dict(os.environ)
            env["PATH"] = stub_dir + os.pathsep + env.get("PATH", "")
            env["HOME"] = home
            env["LOOP_DIR"] = loop
            env["TMPDIR"] = root
            env["STUB_LOG"] = log
            env["STUB_ISSUE"] = issue
            env["STUB_OURS"] = json.dumps(ours)
            env["STUB_PRS"] = json.dumps(prs if prs is not None else [])
            env["STUB_CROSS"] = ""
            return subprocess.run(["bash", guard] + list(args), env=env,
                                  capture_output=True, text=True, timeout=120)

        # --- the ceiling counts the pull requests of the LOOP -----------------
        out = run_guard(ceiling="5")
        check("the ceiling counts the pull requests of the loop and not the "
              "ones of the author",
              out.returncode == 0,
              f"rc={out.returncode} {out.stdout.strip()[-300:]}")
        check("the two numbers of the queue are reported",
              "our-open-prs: 4/5" in out.stdout and
              "our-open-prs-by-author: 5" in out.stdout,
              out.stdout.strip()[-300:])
        out = run_guard(ceiling="4")
        check("the queue of the loop at the ceiling stops the claim",
              out.returncode == 5,
              f"rc={out.returncode} {out.stdout.strip()[-300:]}")
        # --- a retired pull request does not keep the queue busy -------------
        out = run_guard(ceiling="5", retired="")
        check("a retired pull request is not counted",
              out.returncode == 5,
              f"rc={out.returncode} {out.stdout.strip()[-300:]}")
        # --- a truncated list is a LOUD failure, not a verdict ----------------
        out = run_guard(ours_limit="3")
        check("a truncated list of our pull requests stops the guard",
              out.returncode == 6,
              f"rc={out.returncode} {out.stdout.strip()[-300:]}")
        check("a truncated list is named as truncated",
              "truncated" in out.stdout.lower(),
              out.stdout.strip()[-300:])
        out = run_guard(pr_limit="1",
                        prs=[{"number": 900, "title": "a", "body": ""},
                             {"number": 901, "title": "b", "body": ""}])
        check("a truncated list of the open pull requests stops the guard",
              out.returncode == 6,
              f"rc={out.returncode} {out.stdout.strip()[-300:]}")
        check("a truncated list of the upstream is named as truncated",
              "truncated" in out.stdout.lower(),
              out.stdout.strip()[-300:])
        # --- the list of ours is read with its own limit ----------------------
        recorded = ""
        if os.path.exists(log):
            with open(log, encoding="utf-8") as fh:
                recorded = fh.read()
        truncating = [line for line in recorded.splitlines()
                      if "pr list" in line and re.search(r"--limit(?:=|\s+)100(?:\s|$)", line)]
        check("the list of our pull requests is not read with a limit of 100",
              not truncating, truncating)
        # --- the limit of the upstream is NOT SHORTER than the list ---------
        # WHY (31-10-2026): CLAIM_PR_LIMIT was 700 while the upstream had 749
        # open pull requests, so the guard answered "does not know" (blind)
        # for EVERY duplicate check: it could not see the claim of a PR of
        # another author. The limit is now 1000 (the ceiling of `gh pr list`)
        # and the rule is that it may not go DOWN again without a change of
        # strategy: when the upstream reaches 1000 open PRs the guard has to
        # paginate, not to raise the limit.
        src = ""
        try:
            # HERE is the bin of the loop (this file lives in bin/), and
            # BIN_DIR is the fake bin of the test world (it only holds the
            # fake `gh`). The real guard is the one that has the limit.
            with open(os.path.join(HERE, "claim-guard.sh"), encoding="utf-8") as fh:
                src = fh.read()
        except Exception:
            pass
        limit = None
        m = re.search(r'CLAIM_PR_LIMIT="\$\{CLAIM_PR_LIMIT:-(\d+)\}"', src)
        if m:
            limit = int(m.group(1))
        check("the limit of the open pull requests of the upstream is 1000",
              limit == 1000,
              f"CLAIM_PR_LIMIT={limit}: con 700 el upstream tenia 749 PRs y el "
              f"guard se quedaba ciego en cada chequeo de duplicados")
    finally:
        shutil.rmtree(root, ignore_errors=True)


# --- 55: the funnel is asked LABEL BY LABEL ---------------------------------
def test_the_candidates_are_asked_label_by_label():
    """The candidates of the funnel are asked LABEL BY LABEL and the answers
    are MERGED (C2).

    WHY: the funnel wanted ONE label (`CLAIM_WANTED_LABEL=bug`), and the
    upstream reports the translations that are missing with `feature.yml` ->
    label `enhancement` (`.github/ISSUE_TEMPLATE/feature.yml:3`): those issues
    never reached the triage. Widening the funnel is a decision of the
    maintainer, not of the loop, so it is a KNOB (`CLAIM_WANTED_LABELS`) and
    not a constant of the code.

    The rule is EXECUTABLE: the guard is RUN against a `gh` of the tests that
    answers each label with a different list, and the list of the candidates
    must be the MERGE of both, without repetitions.
    """
    print("55. the candidates are asked label by label")
    guard = os.path.join(LOOP, "bin", "claim-guard.sh")
    if not os.path.exists(guard):
        check("the guard of the claim is there", False, guard)
        return
    check("the guard of the claim is a valid bash",
          subprocess.run(["bash", "-n", guard], capture_output=True,
                         text=True).returncode == 0)

    root = tempfile.mkdtemp(prefix="rule55-")
    try:
        home = os.path.join(root, "home")
        loop = os.path.join(root, "loop")
        stub_dir = os.path.join(root, "bin")
        for folder in (home, loop, stub_dir):
            os.makedirs(folder, exist_ok=True)
        log = os.path.join(root, "gh.log")
        # The `gh` of the test: the issues of each label are a different list.
        stub = os.path.join(stub_dir, "gh")
        write_script(stub,
                     "#!/usr/bin/env bash\n"
                     "printf '%s\\n' \"$*\" >> \"${STUB_LOG:-/dev/null}\"\n"
                     "case \"${1:-}\" in\n"
                     "  issue)\n"
                     "    if [ \"${2:-}\" = \"list\" ]; then\n"
                     "      label=\"\"\n"
                     "      want=0\n"
                     "      for a in \"$@\"; do\n"
                     "        if [ \"$want\" = \"1\" ]; then label=\"$a\"; want=0; fi\n"
                     "        if [ \"$a\" = \"--label\" ]; then want=1; fi\n"
                     "      done\n"
                     "      case \"$label\" in\n"
                     "        bug) printf '%s' \"${STUB_BUG:-[]}\" ;;\n"
                     "        enhancement) printf '%s' \"${STUB_ENH:-[]}\" ;;\n"
                     "        *) printf '%s' '[]' ;;\n"
                     "      esac\n"
                     "      exit 0\n"
                     "    fi\n"
                     "    ;;\n"
                     "  pr)\n"
                     "    if [ \"${2:-}\" = \"list\" ]; then\n"
                     "      for a in \"$@\"; do\n"
                     "        if [ \"$a\" = \"--author\" ]; then\n"
                     "          printf '%s' \"${STUB_OURS:-[]}\"; exit 0\n"
                     "        fi\n"
                     "      done\n"
                     "      printf '%s' \"${STUB_PRS:-[]}\"; exit 0\n"
                     "    fi\n"
                     "    ;;\n"
                     "  api)\n"
                     "    printf '%s' \"${STUB_CROSS:-}\"; exit 0\n"
                     "    ;;\n"
                     "esac\n"
                     "exit 1\n")
        os.chmod(stub, 0o755)

        bug = [{"number": 1, "title": "a bug", "labels": [{"name": "bug"}]},
               {"number": 2, "title": "another bug",
                "labels": [{"name": "bug"}]}]
        enhancement = [{"number": 2, "title": "another bug",
                        "labels": [{"name": "enhancement"}]},
                       {"number": 3, "title": "a translation",
                        "labels": [{"name": "enhancement"}]}]

        def run_candidates(wanted=None):
            """The list of the candidates, RUN against the `gh` of the test."""
            config = ["UPSTREAM=acme/one", "FORK_OWNER=forkowner",
                      "MAINT_THRESHOLD=10"]
            if wanted is not None:
                config.append("CLAIM_WANTED_LABELS=%s" % wanted)
            with open(os.path.join(loop, "config.env"), "w",
                      encoding="utf-8") as fh:
                fh.write("\n".join(config) + "\n")
            env = dict(os.environ)
            env["PATH"] = stub_dir + os.pathsep + env.get("PATH", "")
            env["HOME"] = home
            env["LOOP_DIR"] = loop
            env["TMPDIR"] = root
            env["STUB_LOG"] = log
            env["STUB_BUG"] = json.dumps(bug)
            env["STUB_ENH"] = json.dumps(enhancement)
            env["STUB_OURS"] = "[]"
            env["STUB_PRS"] = json.dumps([{"number": 900, "title": "a",
                                            "body": "nothing"}])
            env["STUB_CROSS"] = ""
            return subprocess.run(["bash", guard, "--candidates"], env=env,
                                  capture_output=True, text=True, timeout=120)

        # --- two labels: two questions, one merged list ----------------------
        if os.path.exists(log):
            os.unlink(log)
        out = run_candidates(wanted="bug,enhancement")
        check("the list of the candidates is written",
              out.returncode == 0,
              f"rc={out.returncode} {out.stdout.strip()[-300:]}")
        recorded = ""
        if os.path.exists(log):
            with open(log, encoding="utf-8") as fh:
                recorded = fh.read()
        asked = [line for line in recorded.splitlines()
                 if "issue list" in line]
        check("the funnel asks GitHub once per label", len(asked) == 2, asked)
        check("the funnel asks for the bug label",
              any("--label bug" in line for line in asked), asked)
        check("the funnel asks for the enhancement label",
              any("--label enhancement" in line for line in asked), asked)
        check("the issues of the labels are merged",
              "candidate: #3 " in out.stdout, out.stdout.strip()[-300:])
        check("an issue of two labels is listed once",
              out.stdout.count("candidate: #2 ") == 1,
              out.stdout.strip()[-300:])
        # --- the default of the knob is the label of the configuration --------
        if os.path.exists(log):
            os.unlink(log)
        out = run_candidates()
        check("the list of the candidates is written with the default label",
              out.returncode == 0,
              f"rc={out.returncode} {out.stdout.strip()[-300:]}")
        recorded = ""
        if os.path.exists(log):
            with open(log, encoding="utf-8") as fh:
                recorded = fh.read()
        asked = [line for line in recorded.splitlines()
                 if "issue list" in line]
        check("the default of the funnel is one label", len(asked) == 1, asked)
        check("the default of the funnel is the bug label",
              any("--label bug" in line for line in asked), asked)
    finally:
        shutil.rmtree(root, ignore_errors=True)


# --- 56: our own pull request does not keep the claim of its issue ----------
def test_our_own_pull_request_does_not_keep_the_claim():
    """Our OWN pull request does not keep the claim of its own issue (B4).

    WHY: the guard that runs before the publication asks whether an OPEN pull
    request holds the claim of the issue. When the pull request is OUR OWN
    (the one of the branch that is being published) the answer is yes by
    construction: the loop would never be able to publish anything twice. The
    guard has to know which pull request is ours (`--ours <pr>`), and the
    exclusion only applies when the author is OURS or unknown: a pull request
    that demonstrably belongs to somebody else keeps the claim.

    The rule is EXECUTABLE: the guard is RUN against a `gh` of the tests.
    """
    print("56. our own pull request does not keep the claim of its issue")
    guard = os.path.join(LOOP, "bin", "claim-guard.sh")
    if not os.path.exists(guard):
        check("the guard of the claim is there", False, guard)
        return
    check("the guard of the claim is a valid bash",
          subprocess.run(["bash", "-n", guard], capture_output=True,
                         text=True).returncode == 0)

    root = tempfile.mkdtemp(prefix="rule56-")
    try:
        home = os.path.join(root, "home")
        loop = os.path.join(root, "loop")
        stub_dir = os.path.join(root, "bin")
        for folder in (home, loop, stub_dir):
            os.makedirs(folder, exist_ok=True)
        with open(os.path.join(loop, "config.env"), "w", encoding="utf-8") as fh:
            fh.write("UPSTREAM=acme/one\nFORK_OWNER=forkowner\n"
                     "MAINT_THRESHOLD=10\n")
        stub = os.path.join(stub_dir, "gh")
        write_script(stub,
                     "#!/usr/bin/env bash\n"
                     "case \"${1:-}\" in\n"
                     "  issue)\n"
                     "    if [ \"${2:-}\" = \"view\" ]; then\n"
                     "      printf '%s' \"${STUB_ISSUE:-}\"; exit 0\n"
                     "    fi\n"
                     "    ;;\n"
                     "  pr)\n"
                     "    if [ \"${2:-}\" = \"list\" ]; then\n"
                     "      for a in \"$@\"; do\n"
                     "        if [ \"$a\" = \"--author\" ]; then\n"
                     "          printf '%s' \"${STUB_OURS:-[]}\"; exit 0\n"
                     "        fi\n"
                     "      done\n"
                     "      printf '%s' \"${STUB_PRS:-[]}\"; exit 0\n"
                     "    fi\n"
                     "    ;;\n"
                     "  api)\n"
                     "    printf '%s' \"${STUB_CROSS:-}\"; exit 0\n"
                     "    ;;\n"
                     "esac\n"
                     "exit 1\n")
        os.chmod(stub, 0o755)

        issue = json.dumps({"number": 7058, "state": "OPEN",
                            "title": "a bug", "labels": [{"name": "bug"}]})
        ours_pr = {"number": 42, "title": "fix", "body": "Fixes #7058",
                   "author": {"login": "forkowner"}}
        other_pr = {"number": 42, "title": "fix", "body": "Fixes #7058",
                    "author": {"login": "somebody-else"}}

        def run_guard(prs, args):
            """The guard of the claim, RUN against the `gh` of the test."""
            env = dict(os.environ)
            env["PATH"] = stub_dir + os.pathsep + env.get("PATH", "")
            env["HOME"] = home
            env["LOOP_DIR"] = loop
            env["TMPDIR"] = root
            env["STUB_ISSUE"] = issue
            env["STUB_PRS"] = json.dumps(prs)
            env["STUB_OURS"] = "[]"
            env["STUB_CROSS"] = ""
            return subprocess.run(["bash", guard] + list(args), env=env,
                                  capture_output=True, text=True, timeout=120)

        # --- an open pull request holds the claim of the issue ---------------
        out = run_guard([ours_pr], ["7058"])
        check("an open pull request holds the claim of the issue",
              out.returncode == 3,
              f"rc={out.returncode} {out.stdout.strip()[-300:]}")
        # --- our OWN pull request does not keep the claim --------------------
        out = run_guard([ours_pr], ["--ours", "42", "7058"])
        check("our own pull request does not keep the claim of its issue",
              out.returncode == 0,
              f"rc={out.returncode} {out.stdout.strip()[-300:]}")
        # --- the pull request of somebody else keeps the claim ---------------
        out = run_guard([other_pr], ["--ours", "42", "7058"])
        check("the pull request of another author keeps the claim",
              out.returncode == 3,
              f"rc={out.returncode} {out.stdout.strip()[-300:]}")
        # --- the usage of the flag -------------------------------------------
        out = run_guard([ours_pr], ["--ours", "42", "--duplicates"])
        check("--ours is not valid in the mode of the duplicates",
              out.returncode == 2,
              f"rc={out.returncode} {out.stdout.strip()[-300:]}")
        out = run_guard([ours_pr], ["--ours"])
        check("--ours without a pull request is a usage error",
              out.returncode == 2,
              f"rc={out.returncode} {out.stdout.strip()[-300:]}")
    finally:
        shutil.rmtree(root, ignore_errors=True)


# --- the disk collector knows the two trees of target dirs -------------------

# The stub of the helper of the ORCHESTRATOR (bin/slot-target-dir.sh): it
# answers with the dirs that exist under the base and it RECORDS that it was
# called. The GC has to ask the helper of the orchestrator for the layout of
# ITS tree: a layout that lives in two places is a layout that disagrees with
# itself, and the GC must not invent the layout of a tree that belongs to
# somebody else.
ORCH_SLOT_TARGET_DIR_STUB = r"""#!/usr/bin/env bash
set -uo pipefail
printf 'called\n' >> "${STUB_CALL_LOG:-/dev/null}"
BASE="${ORCH_TARGET_BASE:-${ORCH_DIR:-$HOME/.local/share/solidcraft-orch}/targets}"
case "${1:-}" in
  --base) printf '%s\n' "$BASE"; exit 0 ;;
  --list)
    for d in "$BASE"/slot-*; do
      [ -d "$d" ] || continue
      printf '%s\n' "$d"
    done
    exit 0
    ;;
esac
exit 2
"""

# The stub of the lock of a slot of the orchestrator (bin/slot-lock.sh): the
# answer of --status is 0 when the lock is FREE and 1 when it is TAKEN. The
# stub reads the answer from the environment, so the test decides which
# slots are owned by somebody.
ORCH_SLOT_LOCK_STUB = r"""#!/usr/bin/env bash
set -uo pipefail
MODE=""; TARGET=""; ACTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slot) MODE=slot; TARGET="$2"; shift 2 ;;
    --slot=*) MODE=slot; TARGET="${1#--slot=}"; shift ;;
    --status) ACTION=status; shift ;;
    *) shift ;;
  esac
done
[ "$MODE" = slot ] && [ "$ACTION" = status ] || exit 2
case " ${STUB_TAKEN_LOCKS:-} " in
  *" $TARGET "*) exit 1 ;;
esac
exit 0
"""


def test_the_disk_gc_knows_the_orchestrator_targets():
    """The disk collector knows the target dirs of the ORCHESTRATOR.

    WHY (31-10-2026): the target dir of a slot of the delegated agents is
    the tree of the ORCHESTRATOR (since the unification of the target dir
    the agent and the gate of a slot compile THERE), so that is the tree
    that fills the disk. The tree of the loop is the one that is left
    behind: nothing compiles there any more.

    A collector that only knew the tree of the loop swept a tree nobody
    used and NEVER touched the one that grows. The rule is therefore
    GENERAL: it does not name any issue, any slot and any pull request.

      * the GC asks the helper of the orchestrator for the layout of its
        tree (the helper is the source of truth of the layout) and the tree
        of the loop is still in the list;
      * without that helper the tree of the orchestrator is NOT touched:
        the GC does not invent the layout of a tree that belongs to
        somebody else;
      * the BASE of a tree is never a candidate: the collector removes the
        dirs of the slots ONE BY ONE (the base is their container);
      * a target dir that a live cargo is writing in is NEVER removed,
        whichever tree it belongs to;
      * a target dir that is being used right now (the lock of the slot of
        the orchestrator, the lock of the scoped gate) is never removed;
      * a target dir that was touched recently is never removed;
      * the mode does not touch the network: the list of the pull requests
        is not one of its guards.

    The tests are HERMETIC: the trees are built inside the temporary
    directory of the tests, and the only `gh` that exists in the PATH of
    the tests is a stub that RECORDS that it was called (the mode must not
    call it: GitHub is never contacted).
    """
    print("57. the disk collector knows the target dirs of the orchestrator")
    gc = os.path.join(LOOP, "bin", "gc-disk.sh")
    with open(gc, encoding="utf-8") as fh:
        src = fh.read()

    # --- the rule is in the CODE -------------------------------------------
    check("the GC knows the tree of the orchestrator",
          "ORCH_TARGET_BASE" in src and "slot-target-dir.sh" in src,
          "el GC no menciona el arbol del orquestador")
    check("the GC asks the helper of the orchestrator for its layout",
          "slot-target-dir.sh" in src and "--list" in src,
          "el GC no pregunta al helper del orquestador")
    check("the GC does not rebuild the layout of the orchestrator by name",
          re.search(r'ORCH_TARGET_BASE"?\s*/\s*slot-\*', src) is None,
          "el GC inventa el layout del orquestador en vez de preguntar")

    root = tempfile.mkdtemp(prefix="gc-orch-world-")
    try:
        # --- the world of the tests ----------------------------------------
        home = os.path.join(root, "home")
        loop = os.path.join(root, "loop")
        orch = os.path.join(root, "orch")
        loop_base = os.path.join(root, "loop-target")
        orch_base = os.path.join(root, "orch-target")
        for d in (home, loop, orch, loop_base, orch_base):
            os.makedirs(d, exist_ok=True)
        os.makedirs(os.path.join(loop, "logs"), exist_ok=True)
        os.makedirs(os.path.join(loop, "bin"), exist_ok=True)
        os.makedirs(os.path.join(orch, "bin"), exist_ok=True)
        # The helper of the LOOP is the real one: the layout of the tree of
        # the loop is read from it, with the base of the test.
        shutil.copy(os.path.join(LOOP, "bin", "gate-target-dir.sh"),
                    os.path.join(loop, "bin", "gate-target-dir.sh"))
        os.chmod(os.path.join(loop, "bin", "gate-target-dir.sh"), 0o755)
        # The helper of the ORCHESTRATOR and its lock are stubs.
        helper = os.path.join(orch, "bin", "slot-target-dir.sh")
        with open(helper, "w", encoding="utf-8") as fh:
            fh.write(ORCH_SLOT_TARGET_DIR_STUB)
        os.chmod(helper, 0o755)
        locker = os.path.join(orch, "bin", "slot-lock.sh")
        with open(locker, "w", encoding="utf-8") as fh:
            fh.write(ORCH_SLOT_LOCK_STUB)
        os.chmod(locker, 0o755)

        # The names of the slots are made up: the rule does not depend on
        # them, and the numbers are not numbers of any issue.
        stamp = int(time.time())
        old_loop = os.path.join(loop_base, "slot-%d" % stamp)
        old_orch = os.path.join(orch_base, "slot-%d" % (stamp + 1))
        fresh_orch = os.path.join(orch_base, "slot-%d" % (stamp + 2))
        live_orch = os.path.join(orch_base, "slot-%d" % (stamp + 3))
        locked_orch = os.path.join(orch_base, "slot-%d" % (stamp + 4))
        kept_orch = os.path.join(orch_base, "slot-%d" % (stamp + 5))
        for d in (old_loop, old_orch, fresh_orch, live_orch, locked_orch,
                  kept_orch):
            os.makedirs(d, exist_ok=True)

        def touch(path, hours_ago):
            """A file inside the dir with the age asked for."""
            when = time.time() - hours_ago * 3600
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("x")
            os.utime(path, (when, when))

        touch(os.path.join(old_loop, "artifact"), 48)
        touch(os.path.join(old_orch, "artifact"), 48)
        touch(os.path.join(fresh_orch, "artifact"), 0.2)
        touch(os.path.join(live_orch, "artifact"), 48)
        touch(os.path.join(locked_orch, "artifact"), 48)
        touch(os.path.join(kept_orch, "artifact"), 48)

        # The state of the orchestrator: one of its slots has a pull request
        # that is still open, so it keeps its warm cache on purpose (a
        # rebuild would cost the same again).
        with open(os.path.join(orch, "state.json"), "w",
                  encoding="utf-8") as fh:
            json.dump({"open_prs": {str(stamp + 100): {
                "issue": stamp + 5, "state": "open"}}}, fh)

        # A cargo that writes in the slot of the orchestrator: the GC reads
        # the name of the executable and the CARGO_TARGET_DIR from /proc.
        # The name is the NAME of the executable: a copy of `sleep` called
        # `cargo` is what the GC sees (a script that execs another binary
        # would be seen under the name of THAT binary).
        bindir = os.path.join(root, "bin")
        os.makedirs(bindir, exist_ok=True)
        live_cargo = os.path.join(bindir, "cargo")
        shutil.copy("/bin/sleep", live_cargo)
        os.chmod(live_cargo, 0o755)
        # The `gh` of the tests: it RECORDS that it was called. The mode of
        # the stale target dirs must not call it.
        gh_stub = os.path.join(bindir, "gh")
        with open(gh_stub, "w", encoding="utf-8") as fh:
            fh.write("#!/usr/bin/env bash\nprintf 'called\\n' >> \"$GH_CALLS\"\nexit 0\n")
        os.chmod(gh_stub, 0o755)

        calls = os.path.join(root, "helper-calls.log")
        gh_calls = os.path.join(root, "gh-calls.log")
        live_proc = subprocess.Popen(
            [live_cargo, "180"],
            env=dict(os.environ, CARGO_TARGET_DIR=live_orch),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(0.5)
            env = dict(os.environ)
            env["PATH"] = bindir + os.pathsep + env.get("PATH", "")
            env["HOME"] = home
            env["LOOP_DIR"] = loop
            env["ORCH_DIR"] = orch
            env["ORCH_TARGET_BASE"] = orch_base
            env["GATE_QUICK_TARGET_DIR"] = loop_base
            env["REPO"] = os.path.join(home, "no-repo")
            env["SOLIDCRAFT_WT_ROOT"] = os.path.join(home, "wt")
            env["GATE_WORKTREE"] = os.path.join(home, "gate-wt")
            env["EVIDENCE_WORKTREE"] = os.path.join(home, "evidence-wt")
            env["CARGO_TARGET_DIR"] = os.path.join(home, "no-repo", "target")
            env["STUB_CALL_LOG"] = calls
            env["STUB_TAKEN_LOCKS"] = os.path.basename(locked_orch)[len("slot-"):]
            env["GH_CALLS"] = gh_calls
            env["DISK_GC_ENABLED"] = "1"
            env["DISK_GC_STALE_TARGET_H"] = "3"

            out = subprocess.run(
                ["bash", gc, "--stale-targets", "--dry-run"], env=env,
                capture_output=True, text=True, timeout=180)
            report = out.stdout + out.stderr

            check("the mode of the stale target dirs works",
                  out.returncode == 0,
                  f"rc={out.returncode} {report.strip()[-400:]}")
            check("the mode of the stale target dirs does not touch the network",
                  not os.path.exists(gh_calls),
                  "el modo llamo al gh: gasta la cuota de la API")

            # --- it asks the helper of the orchestrator --------------------
            asked = ""
            if os.path.exists(calls):
                with open(calls, encoding="utf-8") as fh:
                    asked = fh.read()
            check("the GC asks the helper of the orchestrator for its tree",
                  asked.strip() != "",
                  "el helper del orquestador no fue consultado")

            # --- it knows BOTH trees ---------------------------------------
            check("the GC proposes the stale slot of the tree of the loop",
                  old_loop in report, report.strip()[-600:])
            check("the GC proposes the stale slot of the tree of the orchestrator",
                  old_orch in report, report.strip()[-600:])

            # --- the base is NEVER a candidate -----------------------------
            # The base is checked with the parenthesis of the report: the
            # name of the base is the PREFIX of the name of the dirs it
            # contains, and a plain substring would say that the base is a
            # candidate when only a dir of it is.
            check("the base of the tree of the loop is not a candidate",
                  ("BORRARÍA " + loop_base + " (") not in report,
                  report.strip()[-600:])
            check("the base of the tree of the orchestrator is not a candidate",
                  ("BORRARÍA " + orch_base + " (") not in report,
                  report.strip()[-600:])

            # --- the guards ------------------------------------------------
            check("a target dir that a live cargo writes in is never removed",
                  ("BORRARÍA " + live_orch) not in report,
                  report.strip()[-600:])
            check("a target dir that was touched recently is never removed",
                  ("BORRARÍA " + fresh_orch) not in report,
                  report.strip()[-600:])
            check("a target dir whose slot is owned is never removed",
                  ("BORRARÍA " + locked_orch) not in report,
                  report.strip()[-600:])
            check("a target dir that the orchestrator keeps on purpose is not removed",
                  ("BORRARÍA " + kept_orch) not in report,
                  report.strip()[-600:])

            # --- without the helper the tree of the orchestrator is NOT
            #     touched: the GC does not invent the layout of a tree that
            #     belongs to somebody else ---------------------------------
            bare = os.path.join(root, "orch-bare")
            os.makedirs(bare, exist_ok=True)
            env_bare = dict(env)
            env_bare["ORCH_DIR"] = bare
            out_bare = subprocess.run(
                ["bash", gc, "--stale-targets", "--dry-run"], env=env_bare,
                capture_output=True, text=True, timeout=180)
            report_bare = out_bare.stdout + out_bare.stderr
            check("without the helper of the orchestrator its tree is not touched",
                  ("BORRARÍA " + old_orch) not in report_bare,
                  report_bare.strip()[-600:])
            check("without the helper of the orchestrator the tree of the loop is still cleaned",
                  old_loop in report_bare, report_bare.strip()[-600:])

            # --- the mode deletes ONE BY ONE and it does not delete the
            #     base. The cargo is STILL alive here: the real run has to
            #     respect the same guards that the rehearsal respects. ----
            out2 = subprocess.run(
                ["bash", gc, "--stale-targets"], env=env,
                capture_output=True, text=True, timeout=180)
            report2 = out2.stdout + out2.stderr
            check("the real run of the mode of the stale target dirs works",
                  out2.returncode == 0,
                  f"rc={out2.returncode} {report2.strip()[-400:]}")
            check("the stale slot of the tree of the loop is removed",
                  not os.path.exists(old_loop), report2.strip()[-600:])
            check("the stale slot of the tree of the orchestrator is removed",
                  not os.path.exists(old_orch), report2.strip()[-600:])
            check("the base of the tree of the loop survives",
                  os.path.isdir(loop_base), "el GC borro la base del arbol")
            check("the base of the tree of the orchestrator survives",
                  os.path.isdir(orch_base), "el GC borro la base del arbol")
            check("the slot with a live cargo survives the real run",
                  os.path.isdir(live_orch), "el GC borro un target vivo")
            check("the slot that was touched recently survives the real run",
                  os.path.isdir(fresh_orch), "el GC borro un target reciente")
            check("the slot that is owned survives the real run",
                  os.path.isdir(locked_orch), "el GC borro un slot ajeno")
            check("the slot that the orchestrator keeps on purpose survives the real run",
                  os.path.isdir(kept_orch), "el GC borro una cache que el orquestador guarda")
        finally:
            try:
                live_proc.kill()
            except Exception:
                pass
    finally:
        shutil.rmtree(root, ignore_errors=True)


# --- 59: the configuration of the loop is CHECKED before it is sourced ------
def test_the_config_of_the_loop_is_checked_before_it_is_sourced():
    """The config.env is CHECKED before it is sourced, and the check SEES the
    values with spaces that are not quoted.

    WHY (01-11-2026): the config.env of the loop is SOURCED as bash by a
    dozen of scripts (bin/claim-guard.sh, bin/claim-brake.sh,
    bin/supervisor.sh, ...). A value with SPACES and no quotes breaks that
    source IN THE MIDDLE of the file:

        CLAIM_EXCLUDED_LABELS=in progress,kernel-paused,status:decision

    bash reads that as the assignment CLAIM_EXCLUDED_LABELS=in followed by
    the command `progress,kernel-paused,status:decision`, which does not
    exist. The variable is never set (bash hands the assignment to the
    failed command, not to the shell), the rest of the file is not read and
    the script goes on with HALF of the policy, IN SILENCE: the scripts use
    `set -uo pipefail` WITHOUT -e, so the failed source does not stop them.
    The value that a broken source leaves behind depends on the state of the
    shell, so the failure is VARIABLE: the same file broke 19 rules of the
    guard one run, 14 the next and 0 the third. The rule that broke was
    never the rule under test: it was a broken fixture.

    So there is a VERIFIER (bin/config-check.sh) and a PRE-FLIGHT
    (bin/config-preflight.sh) that every script that reads the config.env
    runs BEFORE it sources it. The verifier says what is wrong (the line
    and the name of the variable) and the pre-flight STOPS the script.

    The rule is EXECUTABLE: the verifier is RUN against the REAL config.env
    of the loop (it has to pass) and against FIXTURES of broken ones (it has
    to fail, naming the variable). The pre-flight is RUN against a broken
    config.env too: the script that reads it has to STOP, not to go on with
    half of the policy.

    THE TESTS ARE HERMETIC: the broken config.env are written in the
    temporary directory of the tests. The real one is only READ.
    """
    print("59. the configuration of the loop is checked before it is sourced")
    checker = os.path.join(LOOP, "bin", "config-check.sh")
    preflight = os.path.join(LOOP, "bin", "config-preflight.sh")

    # --- the verifier and the pre-flight are there ----------------------------
    for path, what in ((checker, "the verifier of the config.env"),
                       (preflight, "the pre-flight of the config.env")):
        check(f"{what} is there", os.path.exists(path), path)
        if not os.path.exists(path):
            continue
        check(f"{what} is executable", os.access(path, os.X_OK), path)
        syntax = subprocess.run(["bash", "-n", path], capture_output=True,
                                text=True)
        check(f"{what} is a valid bash", syntax.returncode == 0,
              syntax.stderr[-200:])

    # --- the REAL config.env of the loop PASSES the verifier ------------------
    real_config = os.path.join(LOOP, "config.env")
    with open(real_config, encoding="utf-8") as fh:
        before = fh.read()
    out = subprocess.run(["bash", checker, real_config], capture_output=True,
                         text=True, timeout=120)
    check("the config.env of the loop passes the verifier",
          out.returncode == 0,
          f"rc={out.returncode} {out.stdout[-300:]} {out.stderr[-300:]}")
    with open(real_config, encoding="utf-8") as fh:
        after = fh.read()
    check("the verifier does NOT modify the config.env", before == after,
          "el verificador toco el config.env")

    # --- the verifier SEES a value with spaces and no quotes ------------------
    root = tempfile.mkdtemp(prefix="loop-rules-config-")
    try:
        broken = os.path.join(root, "config.env")
        with open(broken, "w", encoding="utf-8") as fh:
            fh.write("MAINT_THRESHOLD=10\n"
                     "CLAIM_EXCLUDED_LABELS=in progress,kernel-paused,"
                     "status:decision\n"
                     "CLAIM_WANTED_LABEL=bug\n"
                     "UPSTREAM=acme/one\n"
                     "FORK_OWNER=forkowner\n")
        out = subprocess.run(["bash", checker, broken], capture_output=True,
                             text=True, timeout=120)
        check("the verifier REFUSES a value with spaces and no quotes",
              out.returncode == 1,
              f"rc={out.returncode} {out.stdout[-300:]} {out.stderr[-300:]}")
        report = out.stdout + out.stderr
        check("the verifier NAMES the variable that is broken",
              "CLAIM_EXCLUDED_LABELS" in report, report[-400:])
        check("the verifier NAMES the line that is broken",
              re.search(r"\b2:\s*CLAIM_EXCLUDED_LABELS", report) is not None,
              report[-400:])
        check("the verifier says the value has spaces and no quotes",
              "spaces" in report and "not quoted" in report, report[-400:])

        # --- the verifier SEES a mandatory variable that is empty --------------
        empty = os.path.join(root, "config-empty.env")
        with open(empty, "w", encoding="utf-8") as fh:
            fh.write("MAINT_THRESHOLD=\n"
                     "CLAIM_EXCLUDED_LABELS=\"in progress,kernel-paused\"\n"
                     "CLAIM_WANTED_LABEL=bug\n"
                     "UPSTREAM=acme/one\n"
                     "FORK_OWNER=forkowner\n")
        out = subprocess.run(["bash", checker, empty], capture_output=True,
                             text=True, timeout=120)
        check("the verifier REFUSES a mandatory variable that is empty",
              out.returncode == 1,
              f"rc={out.returncode} {out.stdout[-300:]} {out.stderr[-300:]}")
        report = out.stdout + out.stderr
        check("the verifier NAMES the empty variable",
              "MAINT_THRESHOLD" in report, report[-400:])

        # --- a config.env that is fine PASSES the verifier ---------------------
        good = os.path.join(root, "config-good.env")
        with open(good, "w", encoding="utf-8") as fh:
            fh.write("MAINT_THRESHOLD=10\n"
                     "CLAIM_EXCLUDED_LABELS=\"in progress,kernel-paused,"
                     "status:decision\"\n"
                     "CLAIM_WANTED_LABEL=bug\n"
                     "UPSTREAM=acme/one\n"
                     "FORK_OWNER=forkowner\n")
        out = subprocess.run(["bash", checker, good], capture_output=True,
                             text=True, timeout=120)
        check("a config.env with the values quoted passes the verifier",
              out.returncode == 0,
              f"rc={out.returncode} {out.stdout[-300:]} {out.stderr[-300:]}")

        # --- the PRE-FLIGHT STOPS the script that reads the config ------------
        loop = os.path.join(root, "loop")
        os.makedirs(os.path.join(loop, "bin"), exist_ok=True)
        for name in ("config-check.sh", "config-preflight.sh"):
            shutil.copy(os.path.join(LOOP, "bin", name),
                        os.path.join(loop, "bin", name))
            os.chmod(os.path.join(loop, "bin", name), 0o755)
        with open(os.path.join(loop, "config.env"), "w", encoding="utf-8") as fh:
            fh.write("MAINT_THRESHOLD=10\n"
                     "CLAIM_EXCLUDED_LABELS=in progress,kernel-paused\n"
                     "UPSTREAM=acme/one\n"
                     "FORK_OWNER=forkowner\n")

        # The guard of the claim: it reads the config.env, so it has to STOP.
        guard = os.path.join(LOOP, "bin", "claim-guard.sh")
        env = dict(os.environ)
        env["LOOP_DIR"] = loop
        env["HOME"] = os.path.join(root, "home")
        os.makedirs(env["HOME"], exist_ok=True)
        out = subprocess.run(["bash", guard, "1234"], env=env,
                             capture_output=True, text=True, timeout=120)
        check("the guard STOPS with a broken config.env", out.returncode != 0,
              f"rc={out.returncode} {out.stdout[-300:]}")
        report = out.stdout + out.stderr
        check("the guard says WHICH config.env is broken",
              "config.env" in report, report[-400:])
        # The verdict of the guard is NOT one of the codes of the policy: the
        # guard did not decide anything, it refused to start.
        check("the guard does not answer with a verdict of the policy",
              "does not source" not in out.stdout and
              "VERDICT" not in out.stdout,
              out.stdout[-300:])

        # The same guard with a config.env that is fine: it does NOT stop.
        with open(os.path.join(loop, "config.env"), "w", encoding="utf-8") as fh:
            fh.write("MAINT_THRESHOLD=10\n"
                     "CLAIM_EXCLUDED_LABELS=\"in progress,kernel-paused\"\n"
                     "CLAIM_WANTED_LABEL=bug\n"
                     "UPSTREAM=acme/one\n"
                     "FORK_OWNER=forkowner\n")
        out = subprocess.run(["bash", guard, "1234"], env=env,
                             capture_output=True, text=True, timeout=120)
        check("the guard with a config.env that is fine does not stop at the "
              "pre-flight",
              "config-preflight" not in (out.stdout + out.stderr),
              (out.stdout + out.stderr)[-400:])

        # --- the pre-flight is in EVERY script that reads the config.env ------
        scripts = ("agent-issue.sh", "ceiling.sh", "ceiling-experiment.sh",
                   "claim-brake.sh", "claim-free.sh", "claim-guard.sh",
                   "gate-check.sh", "gate-open-prs.sh", "gc-disk.sh",
                   "pr-defaults-line.sh", "start-gate.sh", "supervisor.sh",
                   "sweep-orphans.sh")
        for name in scripts:
            path = os.path.join(LOOP, "bin", name)
            if not os.path.exists(path):
                check(f"{name} is there", False, path)
                continue
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            check(f"{name} checks the config.env before it sources it",
                  "config-preflight.sh" in text, name)
            # The check has to come BEFORE the source: a check after it is
            # useless (the file is already half read).
            pre = text.find("config-preflight.sh")
            src = text.find('. "$LOOP_DIR/config.env"')
            if pre >= 0 and src >= 0:
                check(f"{name} checks the config.env BEFORE it sources it",
                      pre < src, f"preflight={pre} source={src}")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def run_tests():
    green = gate_log("g", GREEN)
    running = gate_log("r", RUNNING)
    red = gate_log("x", RED)

    print("1. the phase is a transition, not a wish")
    st = run({"phase": "idle", "review": "", "prs": {}, "published": {}},
              {"phase": "published", "pr": 5130})
    check("idle -> published is refused", st["phase"] != "published", st["phase"])

    st = run({"phase": "claimed", "review": "", "prs": {}, "published": {}},
              {"phase": "gated"})
    check("claimed -> gated is refused", st["phase"] != "gated", st["phase"])

    st = run({"phase": "gated", "review": "aprobado", "prs": {}, "published": {}},
              {"phase": "published", "pr": 5130})
    check("gated -> published without a gate is refused", st["phase"] == "gated",
          st["phase"])

    print("2. the gate's verdict is the script's, and it moves the phase")
    st = run({"phase": "gating", "gate_log": green, "review": "", "prs": {},
               "published": {}, "pr": 4629}, None)
    check("a green gate moves gating -> gated", st["phase"] == "gated", st["phase"])
    check("the verdict is stored", st.get("gate_verdict") == "VERDE", st.get("gate_verdict"))

    st = run({"phase": "gating", "gate_log": running, "review": "", "prs": {},
               "published": {}, "pr": 4629}, None)
    check("a running gate does not move the phase", st["phase"] == "gating", st["phase"])
    check("a running gate is not green", st.get("gate_verdict") != "VERDE",
          st.get("gate_verdict"))

    st = run({"phase": "gating", "gate_log": red, "review": "", "prs": {},
               "published": {}, "pr": 4629}, None)
    check("a red gate does not move the phase", st["phase"] == "gating", st["phase"])
    check("a red gate is not green", st.get("gate_verdict") != "VERDE",
          st.get("gate_verdict"))

    print("3. a verdict of another commit is not a verdict")
    # a gate of ANOTHER sha: its own loop directory, with its own gate.sha
    other_loop = make_loop_dir(ROOT, "1" * 40, name="loop-other")
    other = gate_log("o", GREEN, loop_dir=other_loop)
    os.rename(other, os.path.join(other_loop, "logs", "gate-test-o-111111111111.log"))
    MADE[-1] = os.path.join(other_loop, "logs", "gate-test-o-111111111111.log")
    st = run({"phase": "gated", "gate_log": MADE[-1], "review": "aprobado",
               "review_sha": HEAD, "prs": {}, "published": {}, "pr": 4629},
              {"phase": "published", "pr": 4629}, loop_dir=other_loop)
    check("a gate of another SHA does not publish", st["phase"] == "gated", st["phase"])

    print("4. publishing needs a green gate, a review, the quota and the cooldown")
    st = run({"phase": "gated", "gate_log": green, "review": "aprobado",
               "review_sha": HEAD, "prs": {}, "published": {}, "pr": 4629},
              {"phase": "published", "pr": 4629})
    check("published with a green gate and a review", st["phase"] == "published",
          st["phase"])

    st = run({"phase": "gated", "gate_log": green, "review": "",
               "review_sha": HEAD, "prs": {}, "published": {}, "pr": 4629},
              {"phase": "published", "pr": 4629})
    check("published without a review is refused", st["phase"] == "gated", st["phase"])

    st = run({"phase": "gated", "gate_log": "", "review": "aprobado",
               "review_sha": HEAD, "prs": {}, "published": {}, "pr": 4629},
              {"phase": "published", "pr": 4629})
    check("published without a gate is refused", st["phase"] == "gated", st["phase"])

    full = {TODAY: [{"pr": n, "at": NOW} for n in (1, 2, 3)]}
    st = run({"phase": "gated", "gate_log": green, "review": "aprobado",
               "review_sha": HEAD, "prs": {}, "published": full},
              {"phase": "published", "pr": 99},
              cfg_extra="MAX_PR_PER_DAY=3\nMIN_MINUTES_BETWEEN_PUBLISH=0\n")
    check("published over the daily cap is refused", st["phase"] == "gated", st["phase"])

    st = run({"phase": "gated", "gate_log": green, "review": "aprobado",
               "review_sha": HEAD, "prs": {},
               "published": {TODAY: [{"pr": 5, "at": NOW}]}},
              {"phase": "published", "pr": 99},
              cfg_extra="MAX_PR_PER_DAY=8\nMIN_MINUTES_BETWEEN_PUBLISH=600\n")
    check("published inside the cooldown is refused", st["phase"] == "gated", st["phase"])

    print("5. the review verdict only counts when the worker said it")
    st = run({"phase": "implemented", "review": "aprobado", "prs": {}, "published": {}},
              {"phase": "implemented"}, extra_text="veredicto: aprobar\n")
    check("the orchestrator cannot approve itself", st.get("review") != "aprobado",
          st.get("review"))

    print("6. the approval of the workflows is per run (per head SHA)")
    base = {"phase": "idle", "review": "", "prs": {"4629": {}}, "published": {}}
    st = run(dict(base), {"approval_asked": {"4629": "aaaa1111"}})
    check("the first ask is recorded",
          st.get("approval_asked", {}).get("4629") == "aaaa1111", st.get("approval_asked"))
    st = run(st, {"approval_asked": {"4629": "aaaa1111"}})
    check("the same sha is not asked again",
          st.get("approval_asked", {}).get("4629") == "aaaa1111")
    st = run(st, {"approval_asked": {"4629": "bbbb2222"}})
    check("a new sha may be asked again",
          st.get("approval_asked", {}).get("4629") == "bbbb2222",
          st.get("approval_asked"))
    st = run(st, {"approval_asked": {"9999": "cccc3333"}})
    check("a PR that is not ours is ignored",
          "9999" not in st.get("approval_asked", {}), st.get("approval_asked"))

    test_review_verdict()
    test_triage()
    test_publication_facts()
    test_gate_dead_and_attempts()
    test_signal_verdicts()
    test_scoped_gate()
    test_scoped_gate_budget()
    test_scoped_gate_cgroup()
    test_scoped_gate_gpu_stack()
    test_complete_gate_is_heavy_phase()
    test_issue_in_flight_guard()
    test_gate_watchdog()
    test_supervisor_uses_the_watchdog()
    test_agent_preflight()
    test_prompt_reads()
    test_slot_digest()
    test_slot_header()
    test_digest_other_slots()
    test_scope_deferred_while_the_complete_gate_is_alive()
    test_the_watchdog_is_the_only_one_that_kills_the_gate()
    test_the_death_of_a_gate_without_exit_is_recorded()
    test_the_timeout_of_the_tests_is_a_postponement()
    test_the_tests_run_only_on_the_touched_crate()
    test_the_fences_of_a_prompt_are_paired_line_by_line()
    test_the_budget_is_split_with_the_measured_costs()
    test_a_phase_that_was_cut_is_not_a_red_gate()
    test_the_orphans_of_a_dead_gate_are_killed()
    test_the_rows_of_the_ledger_are_history()
    test_marginal_effect()
    test_the_scoped_gate_counts_the_check_of_the_workspace()
    test_the_claim_of_an_issue_is_decided_in_code()
    test_the_complete_gate_is_off_by_default()
    test_the_check_of_the_workspace_only_runs_when_it_fits()
    test_the_scoped_gates_do_not_fight_for_the_build_directory()
    test_the_pull_request_carries_the_issue_number()
    test_every_pull_request_states_changes_a_default()
    test_the_branch_is_rebased_before_the_gate_and_the_push()
    test_the_duplicate_pull_requests_are_detected()
    test_the_verdict_of_the_line_of_the_defaults_is_computed()
    test_the_line_of_the_defaults_is_checked_before_and_after()
    test_the_guard_of_the_claim_runs_before_the_publication()
    test_the_claim_is_checked_before_the_model_starts()
    test_the_queue_of_the_loop_is_counted_by_origin()
    test_the_candidates_are_asked_label_by_label()
    test_our_own_pull_request_does_not_keep_the_claim()
    test_the_token_counter_is_sampled()
    test_the_disk_gc_knows_the_orchestrator_targets()
    test_the_config_of_the_loop_is_checked_before_it_is_sourced()

    print()
    for f in MADE:
        try:
            os.unlink(f)
        except OSError:
            pass
    if FAILS:
        print(f"{len(FAILS)} regla(s) fallan: {FAILS}")
        return 1
    print("todas las reglas pasan")
    return 0


if __name__ == "__main__":
    sys.exit(main())
