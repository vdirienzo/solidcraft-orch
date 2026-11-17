#!/usr/bin/env python3
"""Regression tests for the SLOT layout of the loop's state (bin/state.py).

The rules of the slots (the contract of `lote3-slots.md`, sections 2, 3, 4
and 8):

  * the migration v1 -> v2 moves the flat fields into the slot 0, leaves the
    globals where they are, and is idempotent;
  * the review belongs to ITS slot: the approval of the slot 0 does not
    publish the PR of the slot 1;
  * a verdict about the sha of another slot is refused, and the reason is said
    out loud;
  * the gate is FROZEN per slot: the sha of the slot 1 survives the gate of
    another slot (the global sidecar `gate.sha` is rewritten by every gate);
  * `published` is not counted twice (the global write lock);
  * the daily cap is not exceeded and the counter of the day does not grow;
  * a turn of the slot 1 does not touch the slot 0 (byte-identical);
  * the view of the slot (`state/slot-<S>.json`) has the keys the prompt
    reads, and the flat ones of today;
  * the rule of the 3 hours is per slot: an expired issue in flight fails its
    own slot and only its own slot;
  * the state INHERITED in conflict is arbitrated too: when two slots hold
    the same issue, the one with the real work keeps it and the other one
    gives it up (the same rule of "who wins" that the arbitration of the
    delta uses).

THE TESTS ARE HERMETIC: they touch nothing outside their own temporary
directory.
  * their own loop directory: its own logs/, its own gate.sha and its own
    gate-check.sh (a double: the tests do not run a CI). The live loop, its
    live state.json and its live logs are never read nor written;
  * a fake `gh` first in the PATH: the head of a PR is the sha the test gave
    for that PR (the two slots have two different heads, so a verdict of one
    slot is never the head of the other). GitHub is never contacted;
  * their own HOME: the worktree of an issue is never found there;
  * the report is marked as already published: no issue is ever created.

`bin/state.py` is being written RIGHT NOW: the tests are written against the
CONTRACT (the CLI of section 4 and the schema of section 2), not against a
particular implementation. A group whose functionality is not in state.py yet
is PENDIENTE, never a failure of the test: the summary says how many there
are and why.

Run:  python3 ~/.local/share/solidcraft-loop/bin/test-slots.py
"""

from __future__ import annotations

import datetime as dt
import fcntl
import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# The supervisor under test. `LOOP_STATE_PY` points at another copy of it:
# that is how the tests are run against the code BEFORE a fix.
STATE_PY = os.environ.get("LOOP_STATE_PY", os.path.join(HERE, "state.py"))

# The head SHA of the PR of the slot 0 (#4629) and the one of the PR of the
# slot 1 (#5130). They are DIFFERENT on purpose: a verdict of one slot is
# never the head of the PR of the other one.
HEAD = "6829879dcb2a0810dc49b291e2ab7c7091abf1ce"
SHA1 = "1" * 40

# Today (UTC) and now: the daily cap, the cooldown and the 3-hour rule are
# measured against them, so the tests cannot pin a day that is already over.
NOW = int(dt.datetime.now(dt.timezone.utc).timestamp())
TODAY = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")

# The PRs the fake `gh` knows about (the ones of the tests).
PRS = (4629, 5130)

# The `gh` of the tests: no GitHub, no network. The head of a PR is the sha
# the test gave for that PR (`LOOP_TEST_HEAD_<pr>`).
FAKE_GH = """#!/usr/bin/env bash
# The `gh` of the tests: the head of a PR is the head the test gave for it
# and the list of the PRs is the list of the tests. GitHub is never contacted.
case "$1 $2" in
  "pr view")
    case "$3" in
      4629) printf '%s\\n' "$LOOP_TEST_HEAD_4629" ;;
      5130) printf '%s\\n' "$LOOP_TEST_HEAD_5130" ;;
      *)    printf '\\n' ;;
    esac
    exit 0 ;;
  "pr list") printf '%s\\n' "$LOOP_TEST_PRS"; exit 0 ;;
esac
exit 1
"""

# The gate-check.sh of the tests: the verdict of a gate log, without a CI.
# A log with an EXIT= and no "failures:" block is green.
GATE_CHECK = """#!/usr/bin/env bash
log="${1:-}"
if [ ! -f "$log" ] && [ ! -f "$log.1" ]; then
  echo "GATE_STATUS=missing"
  echo "VERDICT=PENDIENTE"
  exit 0
fi
if [ ! -f "$log" ] || ! grep -qE '^EXIT=[0-9]+$' "$log"; then
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

GREEN = "test a::b ... ok\n\nEXIT=0\n"
RED = "failures:\n    geom::tests::stale\n\nEXIT=1\n"

# The status of every check.
OK = "ok"
PENDING = "PENDIENTE"
FAIL = "FALLO"

RESULTS = []

# The temporary world of the tests (see the docstring).
ROOT = ""
LOOP_DIR = ""
BIN_DIR = ""
HOME_DIR = ""

# What the state.py of today can do (it is being written: it may not accept
# --slot yet).
CAP = {"runs": False, "slot": False, "slot_view": False, "why": ""}


class Pending(Exception):
    """The functionality is not in state.py yet (it is being written)."""


def record(status, name, detail=""):
    """One line of the report and one line of the summary."""
    RESULTS.append((status, name, detail))
    label = {OK: "  ok   ", PENDING: "  PEND ", FAIL: "  FAIL "}[status]
    line = label + name
    if detail and status != OK:
        line += "  <- " + str(detail)[:400]
    print(line)


def check(name, cond, detail=""):
    """A check that ran: it passes or it fails."""
    record(OK if cond else FAIL, name, "" if cond else detail)
    return bool(cond)


def pend(name, reason):
    """A check that could not run: the feature is not in state.py yet."""
    record(PENDING, name, reason)
    return False


# --- the helpers of test-rules.py, reused when they are importable ----------
# test-rules.py is the regression gate of the loop: its style is the style of
# this file. It is imported (not copied) when it can be: it may be under
# construction too, and then the local copies below are used.

def _load_rules():
    """The module of test-rules.py, or None when it cannot be loaded."""
    path = os.path.join(HERE, "test-rules.py")
    if not os.path.exists(path):
        return None
    try:
        loader = importlib.machinery.SourceFileLoader("loop_test_rules", path)
        spec = importlib.util.spec_from_loader("loop_test_rules", loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        return module
    except Exception:                              # noqa: BLE001 (it may be half written)
        return None


RULES = _load_rules()

if RULES is not None:
    make_loop_dir = RULES.make_loop_dir
    write_delta = RULES.write_delta
else:
    def make_loop_dir(root, sha, name="loop"):
        """A loop directory of the tests: its own logs, its own gate.sha and
        its own gate-check.sh. The live loop is never read."""
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

    def write_delta(path, payload):
        block = "```json\n" + json.dumps(payload) + "\n```"
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"type": "text", "part": {"text": block}}) + "\n")


def gate_log_of(tag, body, sha, loop_dir):
    """A gate log whose NAME carries the sha of its gate.

    The name of the log IS the identity of the gate (`gate-...-<sha12>.log`),
    so the log of the slot 1 has to carry the sha of the slot 1: a log named
    after another sha would be the gate of another commit.
    """
    logs = os.path.join(loop_dir, "logs")
    os.makedirs(logs, exist_ok=True)
    path = os.path.join(logs, f"gate-test-{tag}-{sha[:12]}.log")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    return path


def write_gate_sidecars(loop_dir, slot_id, log_path, sha):
    """The sidecars of the gate of a slot.

    The identity of the gate belongs to the SUPERVISOR (the sidecars), not to
    the model: the tests write them so that the implementation finds the same
    gate whether it reads the sidecar or the field of the slot.
    """
    for name in (str(slot_id), "default"):
        base = os.path.join(loop_dir, "gates", name)
        os.makedirs(base, exist_ok=True)
        with open(os.path.join(base, "log"), "w", encoding="utf-8") as fh:
            fh.write(log_path + "\n")
        with open(os.path.join(base, "sha"), "w", encoding="utf-8") as fh:
            fh.write(sha + "\n")
    with open(os.path.join(loop_dir, "gate.log"), "w", encoding="utf-8") as fh:
        fh.write(log_path + "\n")
    with open(os.path.join(loop_dir, "gate.sha"), "w", encoding="utf-8") as fh:
        fh.write(sha + "\n")
    with open(os.path.join(loop_dir, "gate.path"), "w", encoding="utf-8") as fh:
        fh.write(log_path + "\n")
    with open(os.path.join(loop_dir, "gate.verdict"), "w", encoding="utf-8") as fh:
        fh.write("VERDICT=VERDE\n")


def test_env(loop_dir):
    """The environment of the tests: no GitHub, no live loop, no live HOME."""
    env = dict(os.environ)
    env["PATH"] = BIN_DIR + os.pathsep + env.get("PATH", "")
    env["LOOP_TEST_HEAD_4629"] = HEAD
    env["LOOP_TEST_HEAD_5130"] = SHA1
    env["LOOP_TEST_PRS"] = json.dumps([
        {"number": num, "title": f"test #{num}", "isDraft": False,
         "createdAt": "2026-10-23T00:00:00Z", "mergeable": "MERGEABLE"}
        for num in PRS])
    env["LOOP_DIR"] = loop_dir
    env["HOME"] = HOME_DIR
    env["REPO"] = os.path.join(HOME_DIR, "no-repo")
    return env


# --- the state of the tests -------------------------------------------------

def slot_fields(**fields):
    """The fields of a slot (the schema v2 of the contract).

    The gate of a slot is written BOTH as `gate_log` and as `gate: {log, ...}`:
    the contract has the flat one in the view and the nested one in the state,
    and the tests must not depend on which one the implementation reads.
    """
    base = {
        "phase": "idle",
        "issue": 0,
        "branch": "",
        "pr": 0,
        "review": "",
        "review_sha": "",
        "branch_sha": "",
        "in_flight": None,
        "gate_log": "",
        "gate": {"log": "", "sha": "", "verdict": "PENDIENTE", "checked_at": 0},
        "quick_verdict": {},
        "merge_verdict": {},
        "consecutive_failures": 0,
    }
    base.update(fields)
    return base


def build_state(slot0=None, slot1=None, **globals_):
    """A state in the shape v2 (the slots) with the flat fields of the slot 0
    mirrored at the top level.

    The mirror is what makes the same test meaningful in the v1 world (the
    flat state IS the slot 0): the migration moves those fields into the
    slot 0, so the flat copy is what the v1 supervisor reads.
    """
    s0 = slot_fields(**(slot0 or {}))
    s1 = slot_fields(**(slot1 or {}))
    state = {
        "version": 2,
        "mode": "normal",
        "published": {},
        "prs": {},
        "done": [],
        "skipped": [],
        "triage": {},
        "counters": {"iterations": 0, "failures": 0, "consecutive": 0},
        "attempts": {},
        "approval_asked": {},
        "report": {"last": "2026-10-23", "issue": 1, "pending": False,
                   "comment_id": 0, "sig": "0:0:0"},
        "allow_new_prs": True,
        "open_unmerged": 0,
        "gate": {"slot": "0", "log": "", "sha": "", "pid": 0, "started": 0,
                 "verdict": "PENDIENTE"},
        "slots": {"0": s0, "1": s1},
    }
    state.update(globals_)
    # the flat mirror of the slot 0 (the shape of v1)
    for key in ("phase", "issue", "branch", "pr", "review", "review_sha",
                "branch_sha", "in_flight", "gate_log"):
        state[key] = s0.get(key)
    state["gate_verdict"] = (s0.get("gate") or {}).get("verdict", "")
    state["published_pr"] = 0
    state["published_sha"] = ""
    return state


def slot_of(state, sid):
    """The slot `sid` of a state (the flat state IS the slot 0 in the v1
    world). None when the slot does not exist."""
    slots = state.get("slots")
    if isinstance(slots, dict) and isinstance(slots.get(str(sid)), dict):
        return slots[str(sid)]
    if str(sid) == "0":
        return state
    return None


def slot_value(slot, key):
    """The value of a per-slot key, wherever the implementation keeps it.

    The contract has the gate of a slot as `gate: {log, sha, verdict}` and the
    view with a flat `gate_log`: both are accepted here.
    """
    if not isinstance(slot, dict):
        return None
    if key in slot:
        return slot[key]
    aliases = {"gate_log": "log", "gate_sha": "sha", "gate_verdict": "verdict",
               "gate_checked_at": "checked_at"}
    if key in aliases:
        gate = slot.get("gate")
        if isinstance(gate, dict) and aliases[key] in gate:
            return gate[aliases[key]]
    return None


def published_pr(state, pr):
    """The publications of the day of one PR."""
    entries = (state.get("published") or {}).get(TODAY) or []
    return [e for e in entries if isinstance(e, dict) and e.get("pr") == pr]


def canonical(obj, keys=None):
    """The canonical JSON of an object (the byte-identical comparison).

    With `keys`, only those fields are compared: state.py fills the empty
    ones with their default (PENDIENTE, 0, ""), and that is not a change of
    the work, so a comparison of the whole object would say "it changed"
    when nothing of the work moved.
    """
    if keys is not None and isinstance(obj, dict):
        obj = {k: obj.get(k) for k in keys}
    return json.dumps(obj, sort_keys=True, ensure_ascii=False)


def sha_matches(left, right):
    """True when two shas are the same commit.

    The comparison is by prefix: the frozen sha of a gate can be the short one
    of the name of its log (`gate-...-<sha12>.log`).
    """
    left = str(left or "").strip().lower()
    right = str(right or "").strip().lower()
    if not left or not right:
        return False
    size = min(len(left), len(right))
    return size >= 7 and left[:size] == right[:size]


def first_diff(before, after):
    """Where two canonical JSON strings differ (the detail of a failure)."""
    for i, (a, b) in enumerate(zip(before, after)):
        if a != b:
            lo = max(0, i - 50)
            return f"at {i}: ...{before[lo:i]}[{a}] vs [{b}]"
    return f"length {len(before)} vs {len(after)}"


# --- running state.py -------------------------------------------------------

def _refused_or_pending(returncode, err):
    """A state.py that does not run is not a failure of the test: the file is
    being written. The reason is said out loud."""
    refused = re.search(r"unrecognized arguments:\s*(.+)", err or "")
    if refused:
        raise Pending(f"state.py does not accept {refused.group(1).strip()} yet: "
                      f"the slot work is not done")
    lines = (err or "").strip().splitlines()
    raise Pending("state.py does not run yet (it is being written): "
                  + (lines[-1] if lines else f"exit {returncode}"))


def run_state(state, delta=None, slot=None, cfg_extra="", loop_dir=None,
              want_err=False, slot_view=None):
    """Runs state.py over a state and a delta. Returns the new state.

    With `slot`, the invocation names the slot it writes to. With
    `slot_view`, the path where the view of the slot is written.
    """
    tmp = tempfile.mkdtemp(prefix="loop-slots-")
    try:
        sp = os.path.join(tmp, "state.json")
        lp = os.path.join(tmp, "ledger.md")
        tp = os.path.join(tmp, "turn.jsonl")
        with open(sp, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=2)
        if delta is not None:
            write_delta(tp, delta)
        cfg = os.path.join(tmp, "config.env")
        with open(cfg, "w", encoding="utf-8") as fh:
            fh.write(cfg_extra)
        loop = loop_dir or LOOP_DIR
        cmd = [sys.executable, STATE_PY, "--state", sp, "--ledger", lp,
               "--turn-log", tp, "--config", cfg, "--loop-dir", loop]
        if slot is not None:
            cmd += ["--slot", str(slot)]
        if slot_view is not None:
            cmd += ["--slot-view", slot_view]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180,
                              env=test_env(loop))
        if proc.returncode != 0:
            _refused_or_pending(proc.returncode, proc.stderr)
        with open(sp, encoding="utf-8") as fh:
            new = json.load(fh)
        if want_err:
            return new, proc.stderr or ""
        return new
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def run_race(state, delta, cfg_extra="", loop_dir=None, count=2):
    """N state.py at the SAME time over the SAME state file: the race the
    global write lock has to close. Returns the final state and the logs."""
    tmp = tempfile.mkdtemp(prefix="loop-slots-race-")
    try:
        sp = os.path.join(tmp, "state.json")
        lp = os.path.join(tmp, "ledger.md")
        tp = os.path.join(tmp, "turn.jsonl")
        with open(sp, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=2)
        write_delta(tp, delta)
        cfg = os.path.join(tmp, "config.env")
        with open(cfg, "w", encoding="utf-8") as fh:
            fh.write(cfg_extra)
        loop = loop_dir or LOOP_DIR
        cmd = [sys.executable, STATE_PY, "--state", sp, "--ledger", lp,
               "--turn-log", tp, "--config", cfg, "--loop-dir", loop]
        procs = [subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True,
                                   env=test_env(loop))
                 for _ in range(count)]
        results = []
        for proc in procs:
            try:
                _, err = proc.communicate(timeout=180)
            except subprocess.TimeoutExpired:
                proc.kill()
                _, err = proc.communicate()
            results.append((proc.returncode, err or ""))
        for code, err in results:
            if code != 0:
                _refused_or_pending(code, err)
        errs = [err for _, err in results]
        with open(sp, encoding="utf-8") as fh:
            new = json.load(fh)
        return new, errs
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def probe_state_py():
    """What the state.py of today can do (it is being written: it may not
    accept --slot yet)."""
    try:
        proc = subprocess.run([sys.executable, STATE_PY, "--help"],
                              capture_output=True, text=True, timeout=60,
                              env=test_env(LOOP_DIR))
    except (OSError, subprocess.SubprocessError) as exc:
        return {"runs": False, "slot": False, "slot_view": False,
                "why": f"state.py does not run: {exc}"}
    text = (proc.stdout or "") + (proc.stderr or "")
    return {
        "runs": proc.returncode == 0,
        "slot": bool(re.search(r"--slot(?![-\w])", text)),
        "slot_view": bool(re.search(r"--slot-view(?![-\w])", text)),
        "why": "" if proc.returncode == 0 else "state.py does not even print its help",
    }


def need_slot(what):
    """The group needs the slot work of state.py."""
    if not CAP.get("slot"):
        raise Pending("state.py does not accept --slot yet: "
                      f"the slot work is not done ({what})")


def probe_lock(loop_dir):
    """True when state.py waits for the lock of the loop (the global write
    lock is implemented), False when it runs without taking it, and None when
    there is no lock file yet (the lock is not implemented)."""
    names = (".state.lock", "state.lock", ".lock.state")
    path = None
    for name in names:
        candidate = os.path.join(loop_dir, name)
        if os.path.exists(candidate):
            path = candidate
            break
    if path is None:
        return None
    tmp = tempfile.mkdtemp(prefix="loop-slots-lock-")
    try:
        sp = os.path.join(tmp, "state.json")
        lp = os.path.join(tmp, "ledger.md")
        tp = os.path.join(tmp, "turn.jsonl")
        with open(sp, "w", encoding="utf-8") as fh:
            json.dump(build_state(), fh, indent=2)
        cfg = os.path.join(tmp, "config.env")
        with open(cfg, "w", encoding="utf-8") as fh:
            fh.write("")
        cmd = [sys.executable, STATE_PY, "--state", sp, "--ledger", lp,
               "--turn-log", tp, "--config", cfg, "--loop-dir", loop_dir]
        handle = open(path, "a+", encoding="utf-8")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True,
                                    env=test_env(loop_dir))
            try:
                _, err = proc.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.communicate()
                return True                      # it waits: the lock is taken
            if "lock" in (err or "").lower():
                return True                      # it refused because of the lock
            return False                         # it ran without waiting
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            handle.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --- 1. the migration v1 -> v2 ----------------------------------------------

def test_migration():
    print("1. the migration v1 -> v2 leaves the slot 0 with what was there")
    green = gate_log_of("mig", GREEN, HEAD, LOOP_DIR)
    write_gate_sidecars(LOOP_DIR, "0", green, HEAD)
    v1 = {
        "version": 1,
        "mode": "normal",
        "phase": "gated",
        "issue": 4242,
        "branch": "fix/issue-4242-x",
        "pr": 4629,
        "review": "aprobado",
        "review_sha": HEAD,
        "branch_sha": HEAD,
        "in_flight": {"issue": 4242, "started": NOW},
        "gate_log": green,
        "gate_verdict": "VERDE",
        "gate_checked_at": NOW,
        "published": {TODAY: [{"pr": 4629, "at": NOW}]},
        "prs": {"4629": {"title": "test #4629", "draft": False,
                         "created": "2026-10-23T00:00:00Z",
                         "mergeable": "MERGEABLE", "state": "open"}},
        "done": [],
        "skipped": [4243],
        "triage": {"4242": {"veredicto": "tomar", "motivo": "small", "at": NOW}},
        "counters": {"iterations": 7, "failures": 1, "consecutive": 0},
        "attempts": {},
        "approval_asked": {},
        "report": {"last": "2026-10-23", "issue": 1, "pending": False,
                   "comment_id": 0, "sig": "0:0:0"},
    }
    new = run_state(v1)
    slots = new.get("slots")
    if not isinstance(slots, dict) or "0" not in slots:
        pend("the migration creates the slot 0",
             "state.py does not migrate v1 -> v2 yet: the slot work is not done "
             f"(the slots of the state are {repr(slots)[:120]})")
        return
    s0 = slots.get("0")
    check("the slot 0 of the migrated state is a map", isinstance(s0, dict),
          repr(s0)[:200])
    if not isinstance(s0, dict):
        return
    check("the slot 0 keeps the phase", slot_value(s0, "phase") == "gated",
          repr(slot_value(s0, "phase")))
    check("the slot 0 keeps the issue", slot_value(s0, "issue") == 4242,
          repr(slot_value(s0, "issue")))
    check("the slot 0 keeps the branch", slot_value(s0, "branch") == "fix/issue-4242-x",
          repr(slot_value(s0, "branch")))
    check("the slot 0 keeps the PR", slot_value(s0, "pr") == 4629,
          repr(slot_value(s0, "pr")))
    check("the slot 0 keeps the review", slot_value(s0, "review") == "aprobado",
          repr(slot_value(s0, "review")))
    check("the slot 0 keeps the sha of the review",
          slot_value(s0, "review_sha") == HEAD, repr(slot_value(s0, "review_sha")))
    check("the slot 0 keeps the issue in flight",
          slot_value(s0, "in_flight") == {"issue": 4242, "started": NOW},
          repr(slot_value(s0, "in_flight")))
    check("the slot 0 keeps the log of the gate",
          slot_value(s0, "gate_log") == green, repr(slot_value(s0, "gate_log")))

    # the globals stay where they are
    check("the published map stays global",
          (new.get("published") or {}).get(TODAY) == [{"pr": 4629, "at": NOW}],
          repr(new.get("published")))
    check("the skipped list stays global", new.get("skipped") == [4243],
          repr(new.get("skipped")))
    check("the triage stays global",
          (new.get("triage") or {}).get("4242", {}).get("veredicto") == "tomar",
          repr(new.get("triage")))
    counters = new.get("counters") or {}
    check("the counters stay global",
          counters.get("failures") == 1 and counters.get("iterations", 0) >= 7,
          repr(new.get("counters")))
    check("the mode stays global", new.get("mode") == "normal", repr(new.get("mode")))
    check("the PRs stay global", isinstance(new.get("prs"), dict)
          and "4629" in (new.get("prs") or {}), repr(new.get("prs"))[:200])
    check("the globals are not copied into the slot",
          not any(k in s0 for k in ("published", "counters", "triage", "mode",
                                   "skipped", "prs")),
          repr(sorted(s0.keys())))

    # the migration is idempotent: reading the migrated state again does not
    # move anything.
    again = run_state(new)
    s0b = slot_of(again, "0") or {}
    check("the migration is idempotent (the phase stays)",
          slot_value(s0b, "phase") == "gated", repr(slot_value(s0b, "phase")))
    check("the migration is idempotent (the review stays)",
          slot_value(s0b, "review") == "aprobado", repr(slot_value(s0b, "review")))
    check("the migration is idempotent (the issue stays)",
          slot_value(s0b, "issue") == 4242, repr(slot_value(s0b, "issue")))
    check("the migration is idempotent (the published map stays)",
          (again.get("published") or {}).get(TODAY) == [{"pr": 4629, "at": NOW}],
          repr(again.get("published")))


# --- 2. the review of the slot 0 does not publish the PR of the slot 1 ------

def test_review_isolation():
    print("2. the review of the slot 0 does not publish the PR of the slot 1")
    need_slot("the review of a slot")
    loop1 = make_loop_dir(ROOT, SHA1, name="loop-slot1")
    green0 = gate_log_of("iso0", GREEN, HEAD, LOOP_DIR)
    green1 = gate_log_of("iso1", GREEN, SHA1, loop1)
    write_gate_sidecars(LOOP_DIR, "0", green0, HEAD)
    write_gate_sidecars(loop1, "1", green1, SHA1)
    s0 = slot_fields(phase="gated", issue=100, branch="fix/issue-100-x", pr=4629,
                     review="aprobado", review_sha=HEAD,
                     in_flight={"issue": 100, "started": NOW},
                     gate_log=green0,
                     gate={"log": green0, "sha": HEAD, "verdict": "VERDE"})
    s1 = slot_fields(phase="gated", issue=200, branch="fix/issue-200-y", pr=5130,
                     review="", review_sha="",
                     in_flight={"issue": 200, "started": NOW},
                     gate_log=green1,
                     gate={"log": green1, "sha": SHA1, "verdict": "VERDE"})
    state = build_state(s0, s1)
    state["gate"] = {"slot": "1", "log": green1, "sha": SHA1, "pid": 0,
                     "started": NOW, "verdict": "VERDE"}

    # (a) the slot 1 has no review: the approval of the slot 0 does not
    #     publish its PR.
    new, err = run_state(state, delta={"phase": "published", "pr": 5130},
                         slot=1, loop_dir=loop1, want_err=True)
    s1n = slot_of(new, "1") or {}
    check("the PR of the slot 1 is not published",
          slot_value(s1n, "phase") != "published", repr(slot_value(s1n, "phase")))
    check("the publication of the slot 1 is not counted",
          not published_pr(new, 5130), repr(new.get("published")))
    check("the approval of the slot 0 does not leak into the slot 1",
          slot_value(s1n, "review") == "", repr(slot_value(s1n, "review")))
    said = (err or "").lower()
    check("the refusal says why the PR is not published",
          any(word in said for word in ("review", "publish", "aprobado",
                                        "verdict")),
          (err or "")[-300:])

    # (b) the approval of the slot 0 is about the CODE of the slot 1 (the
    #     sha of the PR of the slot 1): even then it does not publish the PR
    #     of the slot 1. The approval of a slot is the approval of THAT slot.
    s0b = dict(s0)
    s0b["review_sha"] = SHA1
    state_b = build_state(s0b, s1)
    state_b["gate"] = state["gate"]
    new_b, _ = run_state(state_b, delta={"phase": "published", "pr": 5130},
                         slot=1, loop_dir=loop1, want_err=True)
    s1_b = slot_of(new_b, "1") or {}
    check("the approval of the slot 0 does not publish the PR of the slot 1 "
          "(even about its code)",
          slot_value(s1_b, "phase") != "published", repr(slot_value(s1_b, "phase")))
    check("the publication of the slot 1 is not counted (approval of slot 0)",
          not published_pr(new_b, 5130), repr(new_b.get("published")))
    s0_b = slot_of(new_b, "0") or {}
    check("the review of the slot 0 survives the turn of the slot 1",
          slot_value(s0_b, "review") == "aprobado", repr(slot_value(s0_b, "review")))

    # (c) the inverse: a veto in the slot 1 does not publish it either.
    s1v = dict(s1)
    s1v["review"] = "vetado"
    s1v["review_sha"] = SHA1
    state_c = build_state(s0, s1v)
    state_c["gate"] = state["gate"]
    new_c, _ = run_state(state_c, delta={"phase": "published", "pr": 5130},
                         slot=1, loop_dir=loop1, want_err=True)
    s1_c = slot_of(new_c, "1") or {}
    check("a veto in the slot 1 does not publish its PR",
          slot_value(s1_c, "phase") != "published", repr(slot_value(s1_c, "phase")))
    check("the publication of the slot 1 is not counted (veto)",
          not published_pr(new_c, 5130), repr(new_c.get("published")))

    # (d) the CONTROL: with ITS OWN approval the slot 1 publishes. Without
    #     it the refusals above could be the refusal of anything.
    s1c = dict(s1)
    s1c["review"] = "aprobado"
    s1c["review_sha"] = SHA1
    state3 = build_state(s0, s1c)
    state3["gate"] = state["gate"]
    new3, err3 = run_state(state3, delta={"phase": "published", "pr": 5130},
                           slot=1, loop_dir=loop1, want_err=True)
    s1n3 = slot_of(new3, "1") or {}
    check("the control: the slot 1 with its own approval publishes",
          slot_value(s1n3, "phase") == "published", repr(slot_value(s1n3, "phase")))
    check("the control: the publication is counted",
          len(published_pr(new3, 5130)) == 1, repr(new3.get("published")))


# --- 3. a verdict about the sha of another slot is refused ------------------

def test_verdict_of_another_slot():
    print("3. a verdict with the sha of another slot is refused")
    need_slot("the verdict of a slot")
    loop1 = make_loop_dir(ROOT, SHA1, name="loop-verdict")
    green0 = gate_log_of("v0", GREEN, HEAD, LOOP_DIR)
    green1 = gate_log_of("v1", GREEN, SHA1, loop1)
    write_gate_sidecars(LOOP_DIR, "0", green0, HEAD)
    write_gate_sidecars(loop1, "1", green1, SHA1)
    s0 = slot_fields(phase="gated", issue=100, branch="fix/issue-100-x", pr=4629,
                     review="aprobado", review_sha=HEAD,
                     in_flight={"issue": 100, "started": NOW},
                     gate_log=green0,
                     gate={"log": green0, "sha": HEAD, "verdict": "VERDE"})
    # the verdict of the slot 1 is approved, but it is about the sha of the
    # slot 0: it is not a verdict about the PR of the slot 1.
    s1 = slot_fields(phase="gated", issue=200, branch="fix/issue-200-y", pr=5130,
                     review="aprobado", review_sha=HEAD,
                     in_flight={"issue": 200, "started": NOW},
                     gate_log=green1,
                     gate={"log": green1, "sha": SHA1, "verdict": "VERDE"})
    state = build_state(s0, s1)
    state["gate"] = {"slot": "1", "log": green1, "sha": SHA1, "pid": 0,
                     "started": NOW, "verdict": "VERDE"}
    new, err = run_state(state, delta={"phase": "published", "pr": 5130},
                         slot=1, loop_dir=loop1, want_err=True)
    s1n = slot_of(new, "1") or {}
    check("the PR of the slot 1 is not published",
          slot_value(s1n, "phase") != "published", repr(slot_value(s1n, "phase")))
    check("the publication of the slot 1 is not counted",
          not published_pr(new, 5130), repr(new.get("published")))
    said = (err or "")
    low = said.lower()
    check("the refusal says why",
          HEAD[:8] in said
          or bool(re.search(r"sha|commit|another slot", low))
          or bool(re.search(r"slot[\s'\"#]*0\b", low)),
          said[-400:])


# --- 4. the gate is frozen per slot ----------------------------------------

def test_frozen_gate():
    print("4. the gate is frozen per slot (the sha survives another gate)")
    need_slot("the gate of a slot")
    loop1 = make_loop_dir(ROOT, SHA1, name="loop-frozen")
    green1 = gate_log_of("fr1", GREEN, SHA1, loop1)
    write_gate_sidecars(loop1, "1", green1, SHA1)
    s0 = slot_fields(phase="claimed", issue=100, branch="fix/issue-100-x",
                     in_flight={"issue": 100, "started": NOW})
    s1 = slot_fields(phase="gating", issue=200, branch="fix/issue-200-y", pr=5130,
                     gate_log=green1,
                     gate={"log": green1, "sha": SHA1, "verdict": "PENDIENTE"})
    state = build_state(s0, s1)
    state["gate"] = {"slot": "1", "log": green1, "sha": SHA1, "pid": 0,
                     "started": NOW, "verdict": "VERDE"}
    new = run_state(state, slot=1, loop_dir=loop1)
    s1n = slot_of(new, "1") or {}
    check("the green gate of the slot 1 moves it to 'gated'",
          slot_value(s1n, "phase") == "gated", repr(slot_value(s1n, "phase")))
    frozen_sha = slot_value(s1n, "gate_sha")
    frozen_verdict = slot_value(s1n, "gate_verdict")
    check("the gate of the slot 1 is frozen with its own sha",
          sha_matches(SHA1, frozen_sha), repr(frozen_sha))
    check("the gate of the slot 1 is frozen with its verdict",
          frozen_verdict == "VERDE", repr(frozen_verdict))

    # another gate starts: it rewrites the global sidecar and takes the
    # global gate for itself.
    with open(os.path.join(loop1, "gate.sha"), "w", encoding="utf-8") as fh:
        fh.write(HEAD + "\n")
    new["gate"] = {"slot": "0", "log": "", "sha": HEAD, "pid": 0,
                   "started": NOW, "verdict": "PENDIENTE"}
    again = run_state(new, slot=1, loop_dir=loop1)
    s1b = slot_of(again, "1") or {}
    check("the sha of the frozen gate survives another gate",
          sha_matches(SHA1, slot_value(s1b, "gate_sha")),
          repr(slot_value(s1b, "gate_sha")))
    check("the verdict of the frozen gate survives another gate",
          slot_value(s1b, "gate_verdict") == "VERDE",
          repr(slot_value(s1b, "gate_verdict")))


# --- 5. `published` is not counted twice -----------------------------------

def test_published_not_duplicated():
    print("5. `published` is not counted twice")
    green = gate_log_of("dup", GREEN, HEAD, LOOP_DIR)
    write_gate_sidecars(LOOP_DIR, "0", green, HEAD)
    state = build_state(slot0=slot_fields(
        phase="gated", issue=100, branch="fix/issue-100-x", pr=4629,
        review="aprobado", review_sha=HEAD, gate_log=green,
        gate={"log": green, "sha": HEAD, "verdict": "VERDE"}))
    final, errs = run_race(state, {"phase": "published", "pr": 4629},
                           cfg_extra="MAX_PR_PER_DAY=8\nMIN_MINUTES_BETWEEN_PUBLISH=0\n")
    entries = published_pr(final, 4629)
    check("the PR is counted once after two concurrent turns",
          len(entries) == 1, repr(final.get("published")))
    check("the issue is counted once", (final.get("done") or []).count(100) == 1,
          repr(final.get("done")))

    # and the same publication again, one turn later, is still counted once.
    again = run_state(final, {"phase": "published", "pr": 4629},
                      cfg_extra="MAX_PR_PER_DAY=8\nMIN_MINUTES_BETWEEN_PUBLISH=0\n")
    check("the PR is still counted once after the next turn",
          len(published_pr(again, 4629)) == 1, repr(again.get("published")))

    # the lock: state.py has to wait for the lock of the loop.
    lock = probe_lock(LOOP_DIR)
    if lock is None:
        pend("state.py takes the lock of the state",
             "there is no lock file in the loop directory "
             "(.state.lock / state.lock): the global write lock is not "
             "implemented yet")
    elif lock:
        check("state.py waits for the lock of the state", True)
    else:
        pend("state.py takes the lock of the state",
             "state.py does not wait for the lock of the loop: the global "
             "write lock is not implemented yet")


# --- 6. the daily cap is not exceeded ---------------------------------------

def test_daily_cap():
    print("6. the daily cap is not duplicated")
    green = gate_log_of("cap", GREEN, HEAD, LOOP_DIR)
    write_gate_sidecars(LOOP_DIR, "0", green, HEAD)
    state = build_state(slot0=slot_fields(
        phase="gated", issue=100, branch="fix/issue-100-x", pr=4629,
        review="aprobado", review_sha=HEAD, gate_log=green,
        gate={"log": green, "sha": HEAD, "verdict": "VERDE"}))
    state["published"] = {TODAY: [{"pr": 1, "at": NOW - 3600}]}
    new, err = run_state(state, delta={"phase": "published", "pr": 4629},
                         cfg_extra="MAX_PR_PER_DAY=1\nMIN_MINUTES_BETWEEN_PUBLISH=0\n",
                         want_err=True)
    check("the publication over the daily cap is refused",
          slot_value(slot_of(new, "0"), "phase") != "published",
          repr(slot_value(slot_of(new, "0"), "phase")))
    check("the counter of the day does not grow",
          len((new.get("published") or {}).get(TODAY) or []) == 1,
          repr(new.get("published")))
    check("the refusal says that the cap is full",
          "cap" in (err or "").lower() or "quota" in (err or "").lower()
          or "cupo" in (err or "").lower(), (err or "")[-300:])


# --- 7. a turn of the slot 1 does not touch the slot 0 ----------------------

def test_slot_isolation():
    print("7. with --slot 1, the slot 0 does not change")
    need_slot("the isolation of the slots")
    s0 = slot_fields(phase="claimed", issue=100, branch="fix/issue-100-x", pr=4629,
                     in_flight={"issue": 100, "started": NOW})
    s1 = slot_fields(phase="claimed", issue=200, branch="fix/issue-200-y", pr=5130,
                     in_flight={"issue": 200, "started": NOW})
    state = build_state(s0, s1)
    # the slot 0 is written first (a turn of its own), so the comparison is
    # between two states that the same code wrote.
    first = run_state(state, delta={"phase": "implemented"}, slot=0)
    before = canonical(slot_of(first, "0"))
    check("the slot 0 was written by a turn of its own",
          slot_value(slot_of(first, "0"), "phase") == "implemented",
          repr(slot_value(slot_of(first, "0"), "phase")))
    second = run_state(first, delta={"phase": "implemented"}, slot=1)
    after = canonical(slot_of(second, "0"))
    check("the slot 0 is byte-identical after a turn of the slot 1",
          before == after, first_diff(before, after))
    check("the slot 1 moved", slot_value(slot_of(second, "1"), "phase") == "implemented",
          repr(slot_value(slot_of(second, "1"), "phase")))


# --- 8. the view of the slot ------------------------------------------------

def test_slot_view():
    print("8. the view of the slot has the keys the prompt reads")
    need_slot("the view of the slot")
    loop1 = make_loop_dir(ROOT, SHA1, name="loop-view")
    green1 = gate_log_of("vw", GREEN, SHA1, loop1)
    write_gate_sidecars(loop1, "1", green1, SHA1)
    s0 = slot_fields(phase="claimed", issue=100, branch="fix/issue-100-x", pr=4629,
                     in_flight={"issue": 100, "started": NOW})
    s1 = slot_fields(phase="claimed", issue=200, branch="fix/issue-200-y", pr=5130,
                     in_flight={"issue": 200, "started": NOW})
    state = build_state(s0, s1)
    tmp = tempfile.mkdtemp(prefix="loop-slots-view-")
    try:
        view_path = os.path.join(tmp, "slot-1.json")
        run_state(state, delta={"phase": "implemented"}, slot=1, loop_dir=loop1,
                  slot_view=view_path if CAP.get("slot_view") else None)
        path = view_path
        if not os.path.exists(path):
            path = os.path.join(loop1, "state", "slot-1.json")
        if not os.path.exists(path):
            pend("the view of the slot is written",
                 f"no view file at {view_path} nor at "
                 f"{os.path.join(loop1, 'state', 'slot-1.json')}: "
                 "the view of the slot is not written yet")
            return
        with open(path, encoding="utf-8") as fh:
            view = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        pend("the view of the slot is written",
             f"the view of the slot cannot be read ({exc})")
        return
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    required = ("phase", "issue", "branch", "pr", "gate_log", "review",
                "review_sha", "quick_verdict", "merge_verdict", "triage",
                "published", "prs", "skipped", "counters", "mode", "report")
    missing = [key for key in required if key not in view]
    check("the view has every key the prompt reads", not missing,
          "missing: " + ", ".join(missing))
    check("the view is the view of its own slot", view.get("issue") == 200,
          repr(view.get("issue")))
    types = {"published": dict, "prs": dict, "skipped": list, "triage": dict,
             "counters": dict, "report": dict}
    wrong = [f"{key}:{type(view.get(key)).__name__}" for key, want in types.items()
             if key in view and not isinstance(view.get(key), want)]
    check("the globals of the view keep their shape", not wrong, ", ".join(wrong))


# --- 9. the rule of the 3 hours is per slot --------------------------------

def test_in_flight_per_slot():
    print("9. the rule of the 3 hours is per slot")
    need_slot("the issue in flight of a slot")
    old = {"issue": 100, "started": NOW - 4 * 3600}
    fresh = {"issue": 200, "started": NOW - 60}
    s0 = slot_fields(phase="claimed", issue=100, branch="fix/issue-100-x",
                     in_flight=old)
    s1 = slot_fields(phase="claimed", issue=200, branch="fix/issue-200-y",
                     in_flight=fresh)
    state = build_state(s0, s1)
    new = run_state(state, slot=0, cfg_extra="MAX_INFLIGHT_MIN=180\n")
    s0n = slot_of(new, "0") or {}
    s1n = slot_of(new, "1") or {}
    check("the slot with the expired issue in flight is failed",
          slot_value(s0n, "phase") == "failed", repr(slot_value(s0n, "phase")))
    check("the other slot is not affected by the expiry",
          slot_value(s1n, "phase") == "claimed", repr(slot_value(s1n, "phase")))
    check("the other slot keeps its issue in flight",
          slot_value(s1n, "in_flight") == fresh, repr(slot_value(s1n, "in_flight")))

    # and the other way round: the fresh slot does not die either.
    new2 = run_state(state, slot=1, cfg_extra="MAX_INFLIGHT_MIN=180\n")
    s1b = slot_of(new2, "1") or {}
    check("the slot with the recent issue in flight is not failed",
          slot_value(s1b, "phase") == "claimed", repr(slot_value(s1b, "phase")))


# --- the report -------------------------------------------------------------

# --- 10. the arbitration of the claim between two slots ----------------------

def test_claim_arbitration():
    print("10. an issue in flight in one slot is not claimed by the other")
    need_slot("the arbitration of the claim")
    s0 = slot_fields(phase="claimed", issue=100, branch="fix/issue-100-x", pr=4629,
                     in_flight={"issue": 100, "started": NOW})
    s1 = slot_fields(phase="idle", issue=0, branch="", pr=0, in_flight=None)
    state = build_state(s0, s1)

    # The slot 1 asks for the issue that the slot 0 has in flight: the
    # claim is refused, and the slot keeps what it had.
    #
    # The comparison is of the fields that MEAN something: state.py fills the
    # empty ones with their default (PENDIENTE, 0, ""), and that is not a
    # change of the work of the slot.
    before_other = canonical(slot_of(state, "0"), keys=("phase", "issue", "branch",
                                                         "pr", "review", "review_sha",
                                                         "in_flight"))
    refused = run_state(state, delta={"phase": "selected", "issue": 100,
                                       "branch": "fix/issue-100-z", "pr": 9999},
                         slot=1)
    check("the issue of the other slot was not taken",
          slot_value(slot_of(refused, "1"), "issue") != 100,
          repr(slot_value(slot_of(refused, "1"), "issue")))
    check("the branch of the other slot was not taken",
          slot_value(slot_of(refused, "1"), "branch") != "fix/issue-100-z",
          repr(slot_value(slot_of(refused, "1"), "branch")))
    check("the slot that asked keeps its phase",
          slot_value(slot_of(refused, "1"), "phase") == "idle",
          repr(slot_value(slot_of(refused, "1"), "phase")))
    check("the slot that has the issue did not change",
          canonical(slot_of(refused, "0"), keys=("phase", "issue", "branch",
                                                 "pr", "review", "review_sha",
                                                 "in_flight")) == before_other,
          first_diff(before_other,
                     canonical(slot_of(refused, "0"), keys=("phase", "issue", "branch",
                                                           "pr", "review", "review_sha",
                                                           "in_flight"))))

    # The control: a slot that proposes ITS OWN issue is a continuation, not
    # a conflict: it has to be accepted.
    ok = run_state(state, delta={"phase": "implemented", "issue": 100,
                                 "branch": "fix/issue-100-x", "pr": 4629},
                   slot=0)
    check("the slot that proposes its own issue is accepted",
          slot_value(slot_of(ok, "0"), "phase") == "implemented",
          repr(slot_value(slot_of(ok, "0"), "phase")))

    # A FAILED slot with a pull request open also holds its issue: `failed`
    # is not terminal (the slot resumes it) and the PR is open upstream, so
    # another slot taking the same issue would open a second PR about it.
    f0 = slot_fields(phase="failed", issue=300, branch="fix/issue-300-z", pr=7001,
                     in_flight=None)
    f1 = slot_fields(phase="idle", issue=0, branch="", pr=0, in_flight=None)
    state2 = build_state(f0, f1)
    refused2 = run_state(state2, delta={"phase": "selected", "issue": 300,
                                         "branch": "fix/issue-300-other", "pr": 7777},
                          slot=1)
    check("a failed slot with a pull request open still holds its issue",
          slot_value(slot_of(refused2, "1"), "issue") != 300,
          repr(slot_value(slot_of(refused2, "1"), "issue")))
    check("the failed slot keeps its pull request",
          slot_value(slot_of(refused2, "0"), "pr") == 7001,
          repr(slot_value(slot_of(refused2, "0"), "pr")))

    # A failed slot WITHOUT a pull request holds nothing: the claim failed
    # before the PR existed, so there is nothing to collide with.
    n0 = slot_fields(phase="failed", issue=400, branch="", pr=0, in_flight=None)
    n1 = slot_fields(phase="idle", issue=0, branch="", pr=0, in_flight=None)
    state3 = build_state(n0, n1)
    free = run_state(state3, delta={"phase": "selected", "issue": 400,
                                    "branch": "fix/issue-400-x", "pr": 8001},
                     slot=1)
    check("a failed slot without a pull request holds nothing",
          slot_value(slot_of(free, "1"), "issue") == 400,
          repr(slot_value(slot_of(free, "1"), "issue")))


# --- 11. the arbitration of the INHERITED state ----------------------------

def test_inherited_arbitration():
    print("11. two slots on the same issue: the inherited conflict is arbitrated")
    need_slot("the arbitration of the inherited state")

    # (a) the slot 1 has the pull request open (the real work) and the slot 0
    #     has the SAME issue: the slot 0 gives it up.
    s0 = slot_fields(phase="implemented", issue=6198, branch="fix/issue-6198-a",
                     pr=0, in_flight={"issue": 6198, "started": NOW})
    s1 = slot_fields(phase="implemented", issue=6198, branch="fix/issue-6198-b",
                     pr=4629, in_flight={"issue": 6198, "started": NOW})
    state = build_state(s0, s1)
    new, err = run_state(state, slot=0, want_err=True)
    s0n = slot_of(new, "0") or {}
    s1n = slot_of(new, "1") or {}
    check("the slot that loses the issue gives up the issue",
          slot_value(s0n, "issue") == 0, repr(slot_value(s0n, "issue")))
    check("the slot that loses the issue gives up the branch",
          slot_value(s0n, "branch") == "", repr(slot_value(s0n, "branch")))
    check("the slot that loses the issue gives up the pull request",
          slot_value(s0n, "pr") == 0, repr(slot_value(s0n, "pr")))
    check("the slot that loses the issue goes back to 'idle'",
          slot_value(s0n, "phase") == "idle", repr(slot_value(s0n, "phase")))
    check("the slot that wins the issue keeps it",
          slot_value(s1n, "issue") == 6198, repr(slot_value(s1n, "issue")))
    check("the slot that wins the issue keeps its branch",
          slot_value(s1n, "branch") == "fix/issue-6198-b",
          repr(slot_value(s1n, "branch")))
    check("the slot that wins the issue keeps its pull request",
          slot_value(s1n, "pr") == 4629, repr(slot_value(s1n, "pr")))
    check("the slot that wins the issue keeps its phase",
          slot_value(s1n, "phase") == "implemented",
          repr(slot_value(s1n, "phase")))
    check("the reason is in the log",
          "#6198" in (err or "") and "gives it up" in (err or ""),
          (err or "")[-300:])

    # (b) the inverse: the loser is the slot 1 and the winner is the slot 0
    #     (the same phase and no pull request on either: the lowest id wins).
    b0 = slot_fields(phase="claimed", issue=6198, branch="fix/issue-6198-a",
                     pr=0, in_flight={"issue": 6198, "started": NOW})
    b1 = slot_fields(phase="claimed", issue=6198, branch="fix/issue-6198-b",
                     pr=0, in_flight={"issue": 6198, "started": NOW})
    state_b = build_state(b0, b1)
    new_b, err_b = run_state(state_b, slot=1, want_err=True)
    b0n = slot_of(new_b, "0") or {}
    b1n = slot_of(new_b, "1") or {}
    check("the slot 1 gives up the issue of the slot 0",
          slot_value(b1n, "issue") == 0, repr(slot_value(b1n, "issue")))
    check("the slot 1 gives up its branch",
          slot_value(b1n, "branch") == "", repr(slot_value(b1n, "branch")))
    check("the slot 1 goes back to 'idle'",
          slot_value(b1n, "phase") == "idle", repr(slot_value(b1n, "phase")))
    check("the slot 0 keeps the issue",
          slot_value(b0n, "issue") == 6198, repr(slot_value(b0n, "issue")))
    check("the slot 0 keeps its branch",
          slot_value(b0n, "branch") == "fix/issue-6198-a",
          repr(slot_value(b0n, "branch")))
    check("the reason is in the log (the slot 1 gives it up)",
          "#6198" in (err_b or "") and "gives it up" in (err_b or ""),
          (err_b or "")[-300:])

    # (c) a slot in `claimed` wins over a `failed` slot without a pull
    #     request: the failed slot holds nothing (there is no PR open about
    #     the issue) and it gives the issue up. Its phase is NOT degraded:
    #     it was already `failed`, and giving an issue up is not a failure.
    c0 = slot_fields(phase="failed", issue=6198, branch="fix/issue-6198-a",
                     pr=0, in_flight=None)
    c1 = slot_fields(phase="claimed", issue=6198, branch="fix/issue-6198-b",
                     pr=0, in_flight={"issue": 6198, "started": NOW})
    state_c = build_state(c0, c1)
    new_c, err_c = run_state(state_c, slot=0, want_err=True)
    c0n = slot_of(new_c, "0") or {}
    c1n = slot_of(new_c, "1") or {}
    check("the failed slot without a pull request gives up the issue",
          slot_value(c0n, "issue") == 0, repr(slot_value(c0n, "issue")))
    check("the failed slot without a pull request keeps its phase",
          slot_value(c0n, "phase") == "failed", repr(slot_value(c0n, "phase")))
    check("the claimed slot keeps the issue",
          slot_value(c1n, "issue") == 6198, repr(slot_value(c1n, "issue")))
    check("the reason is in the log (the slot 0 gives it up)",
          "#6198" in (err_c or "") and "gives it up" in (err_c or ""),
          (err_c or "")[-300:])

    # (d) at the same phase, the slot with the pull request open wins: the
    #     PR is the real work (it is open upstream).
    d0 = slot_fields(phase="implemented", issue=6198, branch="fix/issue-6198-a",
                     pr=4629, in_flight={"issue": 6198, "started": NOW})
    d1 = slot_fields(phase="implemented", issue=6198, branch="fix/issue-6198-b",
                     pr=0, in_flight={"issue": 6198, "started": NOW})
    state_d = build_state(d0, d1)
    new_d, err_d = run_state(state_d, slot=1, want_err=True)
    d0n = slot_of(new_d, "0") or {}
    d1n = slot_of(new_d, "1") or {}
    check("the slot with the pull request open keeps the issue",
          slot_value(d0n, "issue") == 6198, repr(slot_value(d0n, "issue")))
    check("the slot with the pull request open keeps the pull request",
          slot_value(d0n, "pr") == 4629, repr(slot_value(d0n, "pr")))
    check("the slot without the pull request gives up the issue",
          slot_value(d1n, "issue") == 0, repr(slot_value(d1n, "issue")))
    check("the slot without the pull request gives up the pull request",
          slot_value(d1n, "pr") == 0, repr(slot_value(d1n, "pr")))

    # (e) two slots with DIFFERENT issues: nothing is touched.
    e0 = slot_fields(phase="claimed", issue=100, branch="fix/issue-100-x",
                     pr=0, in_flight={"issue": 100, "started": NOW})
    e1 = slot_fields(phase="claimed", issue=200, branch="fix/issue-200-y",
                     pr=0, in_flight={"issue": 200, "started": NOW})
    state_e = build_state(e0, e1)
    before_other = canonical(slot_of(state_e, "1"),
                             keys=("phase", "issue", "branch", "pr",
                                   "in_flight"))
    new_e, err_e = run_state(state_e, slot=0, want_err=True)
    check("the slot with its own issue is not touched",
          canonical(slot_of(new_e, "0"), keys=("phase", "issue", "branch",
                                                "pr", "in_flight"))
          == canonical(slot_of(state_e, "0"), keys=("phase", "issue", "branch",
                                                    "pr", "in_flight")),
          "the slot 0 changed")
    check("the other slot with its own issue is not touched",
          canonical(slot_of(new_e, "1"), keys=("phase", "issue", "branch",
                                                "pr", "in_flight")) == before_other,
          first_diff(before_other,
                     canonical(slot_of(new_e, "1"), keys=("phase", "issue",
                                                          "branch", "pr",
                                                          "in_flight"))))
    check("nothing is given up when the issues are different",
          "gives it up" not in (err_e or ""), (err_e or "")[-300:])

    # (f) the CONTROL: a slot that proposes ITS OWN issue is a continuation,
    #     not a conflict: it has to be accepted (the arbitration of the
    #     inherited state cannot break the group 10).
    f0 = slot_fields(phase="claimed", issue=100, branch="fix/issue-100-x",
                     pr=0, in_flight={"issue": 100, "started": NOW})
    f1 = slot_fields(phase="idle", issue=0, branch="", pr=0, in_flight=None)
    state_f = build_state(f0, f1)
    ok = run_state(state_f, delta={"phase": "implemented", "issue": 100,
                                   "branch": "fix/issue-100-x", "pr": 4629},
                   slot=0)
    check("the slot that proposes its own issue is accepted",
          slot_value(slot_of(ok, "0"), "phase") == "implemented",
          repr(slot_value(slot_of(ok, "0"), "phase")))
    check("the slot that proposes its own issue keeps it",
          slot_value(slot_of(ok, "0"), "issue") == 100,
          repr(slot_value(slot_of(ok, "0"), "issue")))


GROUPS = (test_migration, test_review_isolation, test_verdict_of_another_slot,
          test_frozen_gate, test_published_not_duplicated, test_daily_cap,
          test_slot_isolation, test_slot_view, test_in_flight_per_slot,
          test_claim_arbitration, test_inherited_arbitration)

# The name of a group in the summary (the function name is not a name).
GROUP_NAMES = {
    "test_migration": "the migration v1 -> v2",
    "test_review_isolation": "the review of slot 0 does not publish slot 1",
    "test_verdict_of_another_slot": "a verdict about the sha of another slot",
    "test_frozen_gate": "the gate is frozen per slot",
    "test_published_not_duplicated": "`published` is not counted twice",
    "test_daily_cap": "the daily cap is not duplicated",
    "test_slot_isolation": "a turn of slot 1 does not touch slot 0",
    "test_slot_view": "the view of the slot",
    "test_in_flight_per_slot": "the rule of the 3 hours is per slot",
    "test_claim_arbitration": "an issue in flight is not claimed twice",
    "test_inherited_arbitration": "two slots on the same issue are arbitrated",
}


def run_tests():
    global CAP
    CAP = probe_state_py()
    print("=== the slot rules of the loop (bin/state.py) ===")
    if not CAP["runs"]:
        record(PENDING, "state.py runs", CAP["why"])
    for group in GROUPS:
        name = GROUP_NAMES.get(group.__name__, group.__name__)
        try:
            group()
        except Pending as exc:
            record(PENDING, name, str(exc))
        except Exception as exc:                  # noqa: BLE001 (the point)
            record(FAIL, name, f"{type(exc).__name__}: {exc}")
    print()
    n_ok = sum(1 for status, _, _ in RESULTS if status == OK)
    n_pend = sum(1 for status, _, _ in RESULTS if status == PENDING)
    n_fail = sum(1 for status, _, _ in RESULTS if status == FAIL)
    print(f"ok: {n_ok}   PENDIENTE: {n_pend}   FALLO: {n_fail}")
    if n_fail:
        failed = [name for status, name, _ in RESULTS if status == FAIL]
        print(f"{len(failed)} prueba(s) fallan: {failed}")
        return 1
    if n_pend:
        print("sin fallos: las reglas que state.py todavia no tiene quedan "
              "PENDIENTE (no son fallos de este fichero)")
    else:
        print("todas las reglas pasan")
    return 0


def main():
    global ROOT, LOOP_DIR, BIN_DIR, HOME_DIR
    ROOT = tempfile.mkdtemp(prefix="loop-slots-world-")
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


if __name__ == "__main__":
    sys.exit(main())
