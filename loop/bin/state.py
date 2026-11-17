#!/usr/bin/env python3
"""Owner of the SolidCraft loop state.

The MODEL proposes; this script decides. The orchestrator emits a JSON block
at the end of its answer and this script merges it over the existing
`state.json` (it never overwrites it from scratch) and, on top of that, keeps
the bookkeeping the model must not keep:

    in_flight   the 3-hour rule
    published   the daily cap (MAX_PR_PER_DAY) and the cooldown
    prs         our open PRs (maintenance mode)
    mode        normal | maintenance
    done        published issues
    skipped     dropped issues
    counters    iterations | failures | consecutive

If the model proposed those fields, it could grant itself the daily cap or
leave `in_flight` null to restart the 3-hour clock. So they are IGNORED here:
the supervisor keeps the books.

`review` is the middle case: the delta PROPOSES it (the orchestrator is the
one that talks to sc-review), but the supervisor does not take its word for
it. The verdict is written only when the turn log shows the review worker
(sc-review) saying it: the tool calls of the log are written by the harness,
not by the model, so a model that did not run the reviewer cannot leave one
there. A delta that proposes a verdict without that attestation is ignored,
and the refusal is logged.

`published` is a map by day: {"YYYY-MM-DD": [{"pr": N, "at": epoch}]}. The
timestamp is what the cooldown (MIN_MINUTES_BETWEEN_PUBLISH) needs: with the
old format (a bare list of PR numbers) it was impossible to know when the last
publication happened. The old format is converted on read.

THE SLOTS (schema v2). The state is of ONE issue in flight. With two issues
in flight there are two, so the state is a dict of SLOTS (`slots["0"]`,
`slots["1"]`) and the globals (the quota, the triage, the counters, the mode)
stay at the top level. The slot is decided by the SUPERVISOR (the invocation,
`--slot`), never by the delta of the model: a turn writes only in its own
slot, and the `review` of a slot is the review of THAT slot (the "aprobado"
of one slot does not publish the PR of another).

The file is migrated from v1 (the flat fields) to v2 when it is read: the
per-issue fields move to the slot "0" and the globals stay where they are.
The migration is idempotent and it loses nothing.

THE CLAIM IS ARBITRATED HERE. With two slots, both of them can triage at the
same time and reach the claim of the SAME issue before either of them has
opened the pull request: the rule of the prompts ("if there is already an
open pull request about that issue, do not open a second one") only fires
when the pull request ALREADY exists, and two slots that triaged at the
same time have not opened it yet. Two slots on one issue would fight over
the same worktree ($WT_ROOT/issue-<N>) and would open two pull requests
about the same bug. So the SUPERVISOR arbitrates: an issue that is in flight
in another slot is RESERVED by that slot, and the delta that tries to take
it is refused (the slot keeps what it had and the reason is said out loud).
The reservation is by ISSUE, not by slot, and it is decided inside the
global lock of the state: the state is read fresh there, so the slot that
took the issue first is seen by the one that comes second.

THE INHERITED STATE IS ARBITRATED TOO. The arbitration above only sees the
CLAIM of the turn. The state can arrive ALREADY in conflict (a slot took an
issue in a turn where the other slot had it in flight), and then two slots
work on the same issue: they fight over the same worktree
($WT_ROOT/issue-<N>) and they open two pull requests about the same bug. So
the state that is read is arbitrated too: when two slots hold the same
issue, the one that has the real work keeps it and the other one gives it up
(its issue, its branch and its pull request go empty, and its phase goes
back to `idle` when it was working on the issue). It happens inside the
global lock, with the state read fresh: two `state.py` in parallel would
otherwise resolve the same conflict in two different ways.

TWO PROCESSES, ONE FILE. `write_atomic` is atomic for the FILE, not for its
CONTENT: two `state.py` in parallel would lose the delta of one of them (the
quota would be counted twice, the attempts would be lost, the review of the
other slot would be overwritten). So the read -> merge -> write happens under
a short `flock` ($LOOP_DIR/.state.lock), and the state carries a `version`
(the CAS): the delta may say which version it was written against.

Usage:
    state.py --state state.json --ledger ledger.md --turn-log <turn jsonl>
              [--config config.env] [--gate-pid-file ...] [--gate-started-file ...]
              [--slot <S>] [--slot-view <ruta>]
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time

# --- the slots -------------------------------------------------------------
# The unit of work is the SLOT: one slot is one issue in flight. The slot is
# decided by the SUPERVISOR (the invocation), never by the delta of the
# model: a turn writes only in its own slot.
#
# The schema is v2: `slots` is a dict indexed by a stable id ("0", "1"), NOT
# an array (an array forces a renumbering when a slot closes, and the index
# would become the identity). The per-issue fields live in the slot; the
# globals stay at the top level.

STATE_VERSION = 2

# The legacy slot: the one the loop uses today (the single-slot mode). Its
# gate is the global one of the machine ($LOOP_DIR/gate.path and friends).
LEGACY_SLOT = "0"

# The fields that belong to ONE issue: they live in the slot. The `gate` of
# the slot is the FROZEN verdict of its gate (the sha it ran on); the `gate`
# at the top level is the LIVE gate of the machine (a global one).
SLOT_FIELDS = (
    "phase", "issue", "branch", "pr",
    "review", "review_sha", "review_issue", "review_branch", "branch_sha",
    "in_flight", "gate_log", "gate_verdict", "gate_checked_at",
    "quick_verdict", "merge_verdict", "published_pr", "published_sha",
    "consecutive_failures", "gate",
    # The verdict of the SCOPED gate of this slot (the alternative
    # authorisation). The keys are DISJOINT from the ones of the quick gate
    # (`verdict`, `status`, `scope`, `sha`): the orchestrator reads them side
    # by side and they are different things.
    "scope_verdict", "scope_status", "scope_kind", "scope_packages",
    "scope_checks", "scope_new_failures", "scope_failed_tests", "scope_sha",
    "scope_at", "scope_stale", "scope_reason", "scope_deferred",
)

# The fields that are GLOBAL: the quota of the upstream, the triage, the
# counters, the mode, the report and the live gate. They are the book's of
# the WHOLE loop, not of a slot.
GLOBAL_FIELDS = (
    "version", "mode", "published", "prs", "done", "skipped", "triage",
    "report", "approval_asked", "counters", "attempts", "allow_new_prs",
    "open_unmerged", "last_turn", "gate", "gate_pid", "gate_started",
    "slots",
)

# The flat keys at the top level are the LEGACY storage of the slot "0": the
# readers that have not been migrated yet (the supervisor, the prompts) read
# them, and the writers that have not been migrated yet (the supervisor's
# mark_turn_state) write them. They are the SAME data as `slots["0"]` (they
# are written from it, and on read they are what it holds), so they can never
# disagree with it. The `gate` of the slot is NOT among them: at the top
# level `gate` is the live gate.
LEGACY_FLAT_FIELDS = tuple(k for k in SLOT_FIELDS if k != "gate")

# The globals the MODEL consults in the view of its slot.
VIEW_GLOBALS = ("triage", "published", "prs", "skipped", "counters", "mode",
                "report", "allow_new_prs", "open_unmerged", "attempts")

DEFAULT = {
    "version": STATE_VERSION,
    "mode": "normal",
    "in_flight": None,
    "phase": "idle",
    "issue": 0,
    "branch": "",
    "pr": 0,
    "gate_log": "",
    "gate_pid": 0,
    "gate_started": 0,
    "review": "",
    "review_sha": "",
    "published": {},
    # the publication latch: the PR of the publication that was accepted. A
    # publication is a fact, not a verdict that is re-evaluated. It is PER
    # SLOT: the PR of a slot is not published with the verdict of another.
    "published_pr": 0,
    "published_sha": "",
    "prs": {},
    "done": [],
    "skipped": [],
    # how many times each issue was attempted (and failed): the brake of the
    # issue in flight, since `failed` is not terminal. It is GLOBAL: the map
    # is the book of every issue, and each slot writes the entry of its own
    # issue.
    "attempts": {},
    "report": {"last": "", "issue": 0, "pending": True},
    "approval_asked": {},
    "counters": {"iterations": 0, "failures": 0, "consecutive": 0},
    # the slots (v2): the per-issue fields of every slot in flight.
    "slots": {},
    # the LIVE gate of the machine: which slot owns it, its log, the sha it
    # ran on, its pid and its verdict.
    "gate": {},
}

# The fields a slot always has. The mutable ones are copied on every use: the
# state of a slot is a plain dict that the rules edit.
DEFAULT_SLOT = {
    "phase": "idle",
    "issue": 0,
    "branch": "",
    "pr": 0,
    "review": "",
    "review_sha": "",
    "review_issue": 0,
    "review_branch": "",
    "branch_sha": "",
    "in_flight": None,
    "gate_log": "",
    "gate_verdict": "",
    "gate_checked_at": 0,
    "quick_verdict": {},
    "merge_verdict": {},
    # The verdict of the SCOPED gate of this slot: the alternative
    # authorisation (VERDE-SCOPE), with its own vocabulary.
    "scope_verdict": "",
    "scope_status": "",
    "scope_kind": "",
    "scope_packages": "",
    "scope_checks": "",
    "scope_new_failures": 0,
    "scope_failed_tests": "",
    "scope_sha": "",
    "scope_at": 0,
    "scope_stale": False,
    "scope_reason": "",
    "scope_deferred": "",
    "published_pr": 0,
    "published_sha": "",
    "consecutive_failures": 0,
    "gate": {},
}

# The keys the model may propose. Everything else is derived here.
# `review` is in the list, but it does NOT go through the plain assignment:
# it has its own policy (merge_review): only the review worker writes it.
# `gate_log` is NOT in the list: the identity of the gate belongs to the
# SUPERVISOR (the sidecar of the slot), not to the model: a model that
# pointed the state at a log of its choice would decide what the gate said.
PROPOSABLE = ("phase", "issue", "branch", "pr", "review", "report_text",
              "approval_asked")

# The phases of the state machine, and the ones each may reach. The
# SUPERVISOR is the state machine: a phase the model proposes that is not
# reachable from the current one is refused (and said so in the log).
# Without this, a turn could propose "published" out of nowhere and the
# supervisor would take it: the whole gate (green CI) and the review were
# only the model's word.
PHASES = ("idle", "selected", "claimed", "implemented", "gating", "gated",
          "published", "failed", "skipped")

TRANSITIONS = {
    "idle":        {"idle", "selected", "claimed", "skipped", "failed"},
    "selected":    {"selected", "claimed", "skipped", "failed", "idle"},
    "claimed":     {"claimed", "implemented", "skipped", "failed", "idle"},
    "implemented": {"implemented", "gating", "gated", "failed", "idle", "claimed"},
    "gating":      {"gating", "gated", "implemented", "failed", "idle"},
    "gated":       {"gated", "published", "implemented", "failed", "idle"},
    "published":   {"published", "idle"},
    "failed":      {"failed", "idle", "selected", "claimed", "implemented",
                    "gating", "gated"},
    "skipped":     {"skipped", "idle"},
}

TERMINAL_PHASES = ("published", "failed", "skipped", "idle")

# The phases that mean "this slot is working on its issue RIGHT NOW". An
# issue in one of them is RESERVED by the slot that holds it: no other slot
# may take it (two slots on the same issue would fight over the same
# worktree and would open two pull requests about the same bug). A slot
# that is idle, or that has finished (published, skipped), holds nothing:
# `done` and `skipped` are global books, the issue is over for everybody.
#
# `failed` RESERVES the issue too, when the slot still holds a pull request:
# `failed` is not terminal (the slot resumes the issue), and the PR of that
# slot is OPEN upstream, so another slot taking the same issue would open a
# SECOND pull request about the same bug. A `failed` slot without a PR
# (the claim failed before the PR existed) holds nothing: there is nothing
# to collide with.
WORK_IN_PROGRESS_PHASES = ("selected", "claimed", "implemented", "gating",
                           "gated")

# The phases the 3-hour rule does NOT touch: the rule records that an issue in
# PROGRESS was given up, and a phase that means "the issue is over" is not
# work in progress. A published PR is open upstream (degrading it un-publishes
# it and takes it out of the quota), a skipped issue was dropped on purpose and
# a failed one was already given up. `gating`/`gated`: the gate is running or
# the PR is ready.
IN_FLIGHT_EXEMPT = ("gating", "gated", "published", "skipped", "failed")

# The phases whose issue is OVER: the pull request is already open upstream
# (published) or the issue was dropped on purpose (skipped). The books of
# those issues (`done`, `skipped`) are GLOBAL, so two slots cannot fight over
# them, and the slot keeps its issue: taking it away from it would un-publish
# its pull request.
FINISHED_PHASES = ("published", "skipped")

# --- the review verdict ----------------------------------------------------
# The values the verdict can take. "" = no verdict (nothing reviewed yet, or
# the verdict is obsolete because the code changed).
REVIEW_VALUES = {
    "": "",
    "aprobado": "aprobado",
    "aprobada": "aprobado",
    "aprobar": "aprobado",
    "apruebo": "aprobado",
    "vetado": "vetado",
    "vetada": "vetado",
    "vetar": "vetado",
    "veto": "vetado",
}

# The phases of the review cycle: the only ones where a verdict is decided
# (or reset). A `review` proposed in any other phase is ignored.
REVIEW_CYCLE = ("implemented", "claimed")

# The phases where a verdict may be RECORDED (the delta proposes it, or the
# supervisor collects it at the end of the turn): the review cycle, plus the
# gate that waits for it and the failure that interrupted the turn (the
# worker may have finished after the turn died). Outside them the issue is
# over (published, skipped) and a late verdict is ignored.
REVIEW_RECORD = REVIEW_CYCLE + ("gating", "gated", "failed")

# The phases a veto pulls back: a veto does not publish.
VETO_PULLBACK = ("gating", "gated")

# The SHA the reviewer says it reviewed. The verdict is about a concrete commit:
# without it, a verdict about some other code (or about nothing) would pass.
REVIEW_SHA = re.compile(
    r"^[ \t>*_#-]*sha revisado[ \t]*[:\-][ \t]*\**\s*([0-9a-f]{7,40})\b",
    re.I | re.M,
)

# The agent that writes the verdict. The tool calls of the turn log are
# written by the harness: the model cannot forge one.
REVIEW_AGENT = re.compile(r"sc-review", re.I)

# The contract of the review worker: "veredicto: aprobar | vetar".
REVIEW_VERDICT = re.compile(
    r"^[ \t>*_#-]*veredicto[ \t]*[:\-][ \t]*\**\s*(aprobar|aprobado|vetar|vetado|veto)\b",
    re.I | re.M,
)

# The contract of the triage worker: "triage: issue #<N>: <tomar|soltar> - <motivo>".
TRIAGE_LINE = re.compile(
    r"^[ \t>*_#-]*triage[ \t]*:[ \t]*issue[ \t]*#([0-9]+)[ \t]*:[ \t]*"
    r"(tomar|soltar)\b[ \t]*(?:[-–—:][ \t]*(.*))?$",
    re.I | re.M,
)

# --- the SIGNALS and the GATES of the loop ---------------------------------
# Files, written by other scripts:
#
#   gate.quick.verdict   the LEGACY MIRROR of the scoped gate (gate-quick.sh):
#                        the same run in the vocabulary it has always had
#                        (VERDE-PARCIAL|ROJO-PARCIAL|SKIP, PUBLISHABLE=no).
#                        It is NOT the verdict the state machine publishes on:
#                        the authoritative one is gates/<slot>/scope.verdict.
#   merge.verdict        the SIGNAL of the merge (merge-verdict.sh): the
#                        CHEAP lane of the CI of the upstream. It says that
#                        the code compiles and passes the repository checks;
#                        it does not say that the change is correct, and it
#                        does not publish anything.
#   gates/<slot>/scope.verdict
#                        the SCOPED gate of ONE slot: the nextest run over
#                        the packages the change touches, plus fmt, layers
#                        and a scoped clippy. It finishes in minutes and its
#                        verdict (VERDE-SCOPE) IS an authorisation: it is
#                        the ALTERNATIVE to the COMPLETE gate, never a
#                        replacement of it.
#
# The COMPLETE gate (the log of the slot, judged by gate-check.sh) is the
# other authorisation: it is the whole CI (20-35 hours per pull request),
# so it is OPTIONAL now. A slot publishes with the COMPLETE gate (VERDE) OR
# with the SCOPED gate (VERDE-SCOPE), both of them about the head of the
# pull request.
#
# The vocabularies are DISJOINT: the complete gate says VERDE|ROJO|
# PENDIENTE and the scoped gate says VERDE-SCOPE|ROJO-SCOPE|SKIP. There is
# NO publishable key in any of these files: the publication decision is
# DERIVED here, never read from a file.
#
# The signals are exposed in the state so the orchestrator can see them, and
# they are marked as OBSOLETE when they are about another commit: a verdict
# of another commit says nothing about the code in flight and it must not
# be used.
QUICK_VERDICT_FILE = "gate.quick.verdict"
MERGE_VERDICT_FILE = "merge.verdict"
SCOPE_VERDICT_FILE = "scope.verdict"

# What a refusal without a green gate says: WHAT is missing and WHAT would
# satisfy it. A refusal nobody can read is a deadlock.
GREEN_GATE_MISSING = ("what is missing is a green gate about the head of the "
                      "pull request: the COMPLETE gate (VERDE) or the SCOPED "
                      "gate (VERDE-SCOPE)")

# How the two kinds of gate are named in the log: the kind is the key of the
# frozen record, the phrase is what a human reads. The vocabulary of the
# module is the same one everywhere: the COMPLETE gate and the SCOPED gate.
GATE_KINDS = {"complete": "the COMPLETE gate", "scope": "the SCOPED gate"}


def gate_kind_phrase(kind):
    """The phrase of a kind of gate, as a human reads it in the log."""
    return GATE_KINDS.get(str(kind or ""), "the gate")


def note(message):
    """Everything the supervisor refuses goes to the log (stderr)."""
    print(message, file=sys.stderr)


def last_json_block(path):
    """The last ```json block of the session text. None if there is none."""
    texts = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(obj, dict):
                    continue
                if obj.get("type") == "text":
                    part = obj.get("part")
                    if isinstance(part, dict):
                        texts.append(part.get("text", ""))
                    elif isinstance(obj.get("text"), str):
                        texts.append(obj["text"])
    except OSError:
        return None
    blocks = re.findall(r"```json\s*(.*?)```", "\n".join(texts), re.S)
    for raw in reversed(blocks):
        # strict=False: a model that writes a literal newline inside a JSON
        # string (a multi-line report, for instance) produces invalid JSON by
        # the strict rules, and the whole delta would be lost. Lenient parsing
        # keeps the turn's work.
        for strict in (False, True):
            try:
                out = json.loads(raw, strict=strict)
            except json.JSONDecodeError:
                continue
            if isinstance(out, dict):
                return out
    return None


def write_atomic(path, obj):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".state.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_config(path):
    cfg = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw or raw.startswith("#") or "=" not in raw:
                    continue
                key, _, val = raw.partition("=")
                val = val.strip()
                if " #" in val:            # trailing comment on the value
                    val = val.split(" #", 1)[0].strip()
                if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                    val = val[1:-1]
                cfg[key.strip()] = val
    except OSError:
        pass
    return cfg


def as_int(cfg, key, default):
    try:
        return int(str(cfg.get(key, default)).strip())
    except (TypeError, ValueError):
        return default


def to_int(value, default=0):
    """An int out of anything (the sidecars are text, and they may be
    empty)."""
    try:
        return int(str(value).strip().split()[0])
    except (IndexError, TypeError, ValueError):
        return default


def as_float(cfg, key, default):
    try:
        return float(str(cfg.get(key, default)).strip())
    except (TypeError, ValueError):
        return default


def day_epoch(day):
    """The epoch of 00:00 UTC of a YYYY-MM-DD day. 0 if it is not a day."""
    try:
        return int(dt.datetime.strptime(str(day), "%Y-%m-%d")
                   .replace(tzinfo=dt.timezone.utc).timestamp())
    except (TypeError, ValueError):
        return 0


def normalize_published(published):
    """The published map: {day: [{"pr": N, "at": epoch}]}.

    The OLD format was {day: [pr, pr]}: a list of numbers with no timestamp,
    which cannot answer "when was the last publication?" (the cooldown needs
    it). It is converted here, and the epoch of the day at 00:00 UTC is used
    as the timestamp: the old format only knew the day of the publication.
    """
    out = {}
    if not isinstance(published, dict):
        return out
    for day, entries in published.items():
        day = str(day)
        if not isinstance(entries, list):
            continue
        lst = []
        for entry in entries:
            if isinstance(entry, dict):
                try:
                    pr = int(entry.get("pr") or 0)
                except (TypeError, ValueError):
                    continue
                try:
                    at = int(entry.get("at") or 0)
                except (TypeError, ValueError):
                    at = 0
                lst.append({"pr": pr, "at": at or day_epoch(day)})
            elif isinstance(entry, bool):
                continue
            elif isinstance(entry, (int, float)):
                lst.append({"pr": int(entry), "at": day_epoch(day)})
            elif isinstance(entry, str) and entry.strip().isdigit():
                lst.append({"pr": int(entry.strip()), "at": day_epoch(day)})
        out[day] = lst
    return out


def published_stats(published, today):
    """(publications of today, epoch of the last publication of any day)."""
    count = len(published.get(today, []) or [])
    last = 0
    for entries in published.values():
        for entry in entries or []:
            try:
                at = int(entry.get("at") or 0)
            except (AttributeError, TypeError, ValueError):
                continue
            last = max(last, at)
    return count, last


def normalize_review(raw):
    """The verdict of a proposed `review`. None if it is not a verdict."""
    if raw is None:
        return ""
    key = str(raw).strip().lower()
    return REVIEW_VALUES.get(key)     # None = invalid


def verdict_from_text(text):
    """The verdict of the review worker in a text. None if there is none.

    A line that mentions BOTH verdicts (the contract line, "veredicto: aprobar
    | vetar") is not a verdict: it is the template echoed back. And a text with
    both verdicts is ambiguous, so there is no verdict: the review stays
    pending. It used to take the LAST match, which turned a veto followed by
    the echoed contract into "aprobado".
    """
    kinds = set()
    for line in (text or "").splitlines():
        words = [w.lower() for w in REVIEW_VERDICT.findall(line)]
        if not words:
            continue
        low = line.lower()
        if (re.search(r"\baprobar|\baprobado", low)
                and re.search(r"\bvetar|\bvetado|\bveto", low)):
            continue
        kinds.add("aprobado" if words[-1].startswith("apro") else "vetado")
    if len(kinds) == 1:
        return kinds.pop()
    return None


def triage_from_summary(summary):
    """The triage verdicts in the summary of a turn.

    The lines are "triage: issue #<N>: <tomar|soltar> - <motivo>". They are
    a list of (issue, verdict, reason).
    """
    out = []
    for m in TRIAGE_LINE.finditer(summary or ""):
        try:
            issue = int(m.group(1))
        except (TypeError, ValueError):
            continue
        if issue <= 0:
            continue
        out.append((issue, m.group(2).strip().lower(),
                    str(m.group(3) or "").strip()))
    return out


def tool_output_text(out):
    """The text of a tool output (a string, or the parts of a list)."""
    if out is None:
        return ""
    if isinstance(out, str):
        return out
    if isinstance(out, dict):
        if isinstance(out.get("text"), str):
            return out["text"]
        # NOT the json dump: the dump would carry the model own text (the
        # brief) into the parser, and the brief is the model.
        return ""
    if isinstance(out, list):
        parts = []
        for item in out:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                if isinstance(item.get("text"), str):
                    parts.append(item["text"])
                else:
                    try:
                        parts.append(json.dumps(item, ensure_ascii=False))
                    except (TypeError, ValueError):
                        pass
        return "\n".join(parts)
    return str(out)


def branch_sha(branch):
    """The SHA the branch points at right now ("" if it cannot be read)."""
    if not branch:
        return ""
    repo = os.environ.get("REPO", "/home/user/solidcraft")
    try:
        out = subprocess.run(
            ["git", "-C", repo, "rev-parse", str(branch)],
            capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, ValueError, subprocess.SubprocessError):
        return ""
    return out if re.fullmatch(r"[0-9a-f]{7,40}", out) else ""


def worktree_head_sha(issue):
    """The HEAD of the worktree of an issue ("" when there is none).

    The worktree of an issue lives in $HOME/solidcraft-wt/issue-<N>: it is
    where the branch of the issue is built, so its HEAD is the commit the
    issue is about.
    """
    try:
        num = int(issue or 0)
    except (TypeError, ValueError):
        return ""
    if num <= 0:
        return ""
    path = os.path.join(os.path.expanduser("~"), "solidcraft-wt", f"issue-{num}")
    if not os.path.isdir(path):
        return ""
    try:
        out = subprocess.run(
            ["git", "-C", path, "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, ValueError, subprocess.SubprocessError):
        return ""
    return out if re.fullmatch(r"[0-9a-f]{7,40}", out) else ""


def reviewed_sha(text):
    """The SHA the review worker says it reviewed ("" if it does not say)."""
    m = REVIEW_SHA.search(text or "")
    return m.group(1).lower() if m else ""


def review_worker_verdict(turn_log, texts=None, expect_sha=None):
    """The verdict of the review worker in THIS turn.

    Only the TOOL CALLS are read: the log of the turn is written by the
    harness, so a model that did not dispatch the reviewer cannot leave a
    review call in it. The verdict itself is read from the output of that
    call (the text of the turn is NEVER read: `texts` is kept only for the call signature and is deliberately unused, because the orchestrator writes its own summary in that very format).

    The verdict counts only when the worker declared the sha it reviewed and
    that sha is the one expected (`expect_sha`, the tip of the branch): a
    verdict that cannot be tied to a commit is not a verdict.

    None if the review worker did not run (or did not say anything).
    """
    if not turn_log:
        return None, ""
    called = False
    verdict = None
    sha = ""
    # The sha the verdict has to be about: the tip of the branch. When it is
    # empty there is nothing to tie the verdict to, and the verdict is
    # refused (fail-closed).
    expected = str(expect_sha or "").strip().lower()
    try:
        with open(turn_log, encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    obj = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if not isinstance(obj, dict) or obj.get("type") != "tool_use":
                    continue
                part = obj.get("part")
                if not isinstance(part, dict):
                    continue
                tool_state = part.get("state")
                tool_state = tool_state if isinstance(tool_state, dict) else {}
                inp = tool_state.get("input")
                inp = inp if isinstance(inp, dict) else {}
                agent = " ".join(str(inp.get(k, "")) for k in
                                 ("agent", "subagent_type", "subagentType", "name"))
                if not REVIEW_AGENT.search(agent):
                    continue
                called = True
                out = tool_output_text(tool_state.get("output")
                                       if tool_state.get("output") is not None
                                       else tool_state.get("content"))
                found = verdict_from_text(out)
                declared = reviewed_sha(out)
                if found:
                    # A verdict counts ONLY when it is tied to a commit: the
                    # worker has to say WHICH sha it reviewed, and that sha
                    # has to be the tip of the branch. A verdict without a
                    # sha, or with the sha of another commit, is refused.
                    if not expected:
                        note("the review worker said a verdict but there is no "
                             "sha to tie it to (the head of the PR, the tip of "
                             "the branch and the HEAD of the worktree are all "
                             "unknown): refused (a verdict without a sha is "
                             "not a verdict)")
                        found = None
                    elif not declared:
                        note("the review worker did not declare the sha it "
                             "reviewed: refused")
                        found = None
                    elif not declared.startswith(expected[:7]):
                        note(f"the review worker reviewed another commit "
                             f"({declared[:8]} != {expected[:8]}): refused")
                        found = None
                if found:
                    verdict = found
                    sha = declared
    except OSError:
        return None, ""
    if verdict is None and called:
        # The worker was dispatched but its answer is not in this log (it was
        # left running in the background). There is NO verdict: the review
        # stays pending and the next turn collects the worker (the task tool
        # takes the worker's sessionID).
        #
        # It used to fall back to the text of the TURN, but the orchestrator
        # writes its own summary in that very format ("veredicto: aprobar"),
        # so the model could approve its own diff: the fallback was a
        # self-approval. The verdict counts only when the REVIEW WORKER said
        # it, in the output of its own call.
        note("the review worker did not report a verdict in this turn: the "
             "review stays pending (the orchestrator cannot approve itself)")
    return verdict, sha


def turn_texts(path):
    """The text parts of the turn log."""
    texts = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict) and obj.get("type") == "text":
                    part = obj.get("part")
                    if isinstance(part, dict):
                        texts.append(str(part.get("text", "") or ""))
                    elif isinstance(obj.get("text"), str):
                        texts.append(obj["text"])
    except OSError:
        pass
    return texts


def apply_verdict(state, verdict, sha=""):
    """Write the verdict of the worker and hold the line with it.

    The verdict is written with the commit it is about (`sha`): a verdict
    without a sha is not a verdict, and the publication needs that sha to be
    the head of the PR.
    """
    state["review"] = verdict
    state["review_sha"] = sha
    state["review_issue"] = state.get("issue")
    state["review_branch"] = state.get("branch")
    if verdict == "vetado" and str(state.get("phase", "")) in VETO_PULLBACK:
        note("review: veto -> the phase goes back to 'claimed' "
             "(a veto does not publish)")
        state["phase"] = "claimed"


def loop_dir_of(path):
    """The loop's directory (the parent of bin/)."""
    return os.path.dirname(os.path.dirname(os.path.abspath(path)))


def gate_check_output(log_path, loop_dir):
    """The raw output of gate-check.sh for this log ("" when it cannot run).

    The log has to be one of the loop's own gate logs: the model points at
    it, so a path from anywhere else (an old log of another PR, a file it
    made up) must not be able to produce a verdict.
    """
    if not log_path or not os.path.exists(log_path):
        return ""
    logs_dir = os.path.join(os.path.abspath(loop_dir), "logs")
    if os.path.dirname(os.path.abspath(log_path)) != logs_dir:
        print(f"the gate log {log_path!r} is not in {logs_dir}: no verdict",
              file=sys.stderr)
        return ""
    if not os.path.basename(log_path).startswith("gate-"):
        print(f"the gate log {log_path!r} is not a gate log: no verdict",
              file=sys.stderr)
        return ""
    script = os.path.join(loop_dir, "bin", "gate-check.sh")
    if not os.path.exists(script):
        return ""
    try:
        out = subprocess.run(["bash", script, log_path],
                             capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout or ""


def gate_verdict(log_path, loop_dir):
    """The gate's verdict, COMPUTED HERE (not taken from the model's word).

    It runs the same script the sc-gate worker runs, so the supervisor and the
    worker cannot disagree about what the gate said.
    """
    for line in gate_check_output(log_path, loop_dir).splitlines():
        if line.startswith("VERDICT="):
            return line.split("=", 1)[1].strip()
    return None


def gate_status(log_path, loop_dir):
    """The gate's status: running, finished, missing or dead.

    `dead` is the one that matters for the phase: a log without EXIT= older
    than GATE_TIMEOUT_MIN is a gate that was killed (or a machine that went
    down). It is not "running" and it will never say anything.
    """
    for line in gate_check_output(log_path, loop_dir).splitlines():
        if line.startswith("GATE_STATUS="):
            return line.split("=", 1)[1].strip()
    return ""


def gate_has_finished_run(log_path):
    """True when a run of this gate FINISHED: its log has an EXIT=, or the
    ROTATED log of the previous run (<log>.1) has it.

    start-gate.sh rotates the log of the previous run of the same sha into
    <log>.1 and writes a clean <log>, so the EXIT= of the run that already
    finished is in the rotated one. Without this, a gate that is alive looks
    dead (it "died without writing EXIT=") and a green run looks like it never
    happened.
    """
    if not log_path:
        return False
    for path in (log_path, str(log_path) + ".1"):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                if re.search(r"^EXIT=\d+\s*$", fh.read(), re.M):
                    return True
        except OSError:
            continue
    return False


def gate_sha(loop_dir, log_path):
    """The SHA the gate ran on: the sidecar file, or the log's name."""
    side = os.path.join(loop_dir, "gate.sha")
    try:
        with open(side, encoding="utf-8") as fh:
            value = fh.read().strip()
        if value:
            return value
    except OSError:
        pass
    name = os.path.basename(log_path or "")
    tail = name.rsplit("-", 1)[-1].removesuffix(".log")
    return tail if len(tail) == 12 and all(c in "0123456789abcdef" for c in tail) else ""


def gate_sha_of_log(log_path):
    """The SHA the gate of THIS log ran on, taken from the name of the log.

    start-gate.sh names the log `gate-<...>-<sha12>.log`, so the name IS the
    identity of the gate. The sidecar ($LOOP_DIR/gate.sha) is rewritten by
    every gate: reading it later would give the sha of the NEXT gate, which
    is why the sha of a finished gate is FROZEN in its slot.
    """
    name = os.path.basename(log_path or "")
    tail = name.rsplit("-", 1)[-1].removesuffix(".log")
    return tail if len(tail) == 12 and all(c in "0123456789abcdef" for c in tail) else ""


def read_sidecar(path):
    """The content of a sidecar file of the supervisor ("" when it is not
    there). A sidecar is one line; the `GATE_LOG=` prefix is tolerated
    because some of them are written in the KEY=VALUE format."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            value = fh.readline().strip()
    except OSError:
        return ""
    if "=" in value:
        key, _, rest = value.partition("=")
        if key.strip().upper() in ("GATE_LOG", "SHA", "LOG"):
            value = rest.strip()
    return value


def supervisor_gate_log(loop_dir, slot_id, state=None):
    """The log of the gate of THIS slot, as the SUPERVISOR says it.

    The identity of the gate is not the model's to decide: it is the sidecar
    of the slot ($LOOP_DIR/gates/<slot>/log), and for the legacy slot the
    global one ($LOOP_DIR/gate.path). The global one is the gate of the
    MACHINE: it is only adopted when this slot is its owner (the owner is in
    the state) or when it has no owner yet. Empty when the supervisor has no
    gate for this slot.
    """
    own = os.path.join(loop_dir, "gates", str(slot_id), "log")
    value = read_sidecar(own)
    if value:
        return value
    if str(slot_id) != LEGACY_SLOT:
        return ""
    live = state.get("gate") if isinstance(state, dict) else None
    owner = str((live or {}).get("slot") or "")
    if owner and owner != str(slot_id):
        return ""                 # the live gate is another slot's
    for path in (os.path.join(loop_dir, "gates", "default", "log"),
                 os.path.join(loop_dir, "gate.path")):
        value = read_sidecar(path)
        if value:
            return value
    return ""


def read_live_sidecars(loop_dir):
    """The LIVE gate of the machine, as the global sidecars say it."""
    out = {}
    log = read_sidecar(os.path.join(loop_dir, "gate.path"))
    if log:
        out["log"] = log
    sha = read_sidecar(os.path.join(loop_dir, "gate.sha"))
    if sha:
        out["sha"] = sha
    pid = read_sidecar(os.path.join(loop_dir, "gate.pid"))
    if pid:
        out["pid"] = to_int(pid, 0)
    started = read_sidecar(os.path.join(loop_dir, "gate.started"))
    if started:
        out["started"] = to_int(started, 0)
    data = read_verdict_file(os.path.join(loop_dir, "gate.verdict"))
    if isinstance(data, dict):
        verdict = str(data.get("VERDICT", "") or "")
        if verdict:
            out["verdict"] = verdict
    return out


def read_verdict_file(path):
    """The KEY=VALUE lines of a verdict file.

    None when the file cannot be read, {} when it is empty. The verdict files
    are written atomically (a temporary file + a rename), so a file that
    exists is a file that is complete.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return None
    out = {}
    for raw in text.splitlines():
        raw = raw.strip()
        if not raw or "=" not in raw:
            continue
        key, _, value = raw.partition("=")
        out[key.strip().upper()] = value.strip()
    return out


def quick_verdict(loop_dir, state):
    """The verdict of the QUICK gate, as the state exposes it.

    The quick gate checks only the packages the change touches: its verdict is
    PARTIAL and it never publishes. The state exposes it so the orchestrator
    can see it, and it is marked as OBSOLETE when it is about another commit:
    a verdict of another commit says nothing about the code in flight, and it
    must not be used for anything.

    The reason is always there when the verdict cannot be used: a signal
    nobody can read is a deadlock.
    """
    data = read_verdict_file(os.path.join(loop_dir, QUICK_VERDICT_FILE))
    if data is None:
        return {"verdict": "", "status": "", "scope": "", "new_failures": 0,
                "publishable": "", "sha": "", "at": 0, "stale": False,
                "reason": "the quick gate has not written its verdict yet"}
    verdict = str(data.get("VERDICT", "") or "")
    sha = str(data.get("SHA", "") or "")
    out = {
        "verdict": verdict,
        "status": str(data.get("GATE_STATUS", "") or ""),
        "scope": str(data.get("SCOPE", "") or ""),
        "new_failures": as_int(data, "NEW_FAILURES", 0),
        "publishable": str(data.get("PUBLISHABLE", "") or ""),
        "sha": sha,
        "at": as_int(data, "AT", 0),
        "stale": False,
        "reason": "",
    }
    if not verdict:
        out["stale"] = True
        out["reason"] = "the quick gate wrote a verdict file without a verdict"
        return out
    # The quick gate runs on the tip of the branch in flight: its verdict is
    # about that commit and about nothing else.
    expected = (branch_sha(state.get("branch"))
                or worktree_head_sha(state.get("issue")))
    if not expected:
        out["stale"] = True
        out["reason"] = ("the tip of the branch in flight is unknown: the "
                         "verdict cannot be tied to a commit")
    elif not sha_matches(expected, sha):
        out["stale"] = True
        out["reason"] = (f"the quick gate ran on {sha[:8] or 'an unknown sha'} "
                         f"and the tip of the branch is {expected[:8]}: it is "
                         f"obsolete")
    return out


def merge_verdict(loop_dir, cfg, state):
    """The signal of the MERGE, as the state exposes it.

    The signal is the cheap lane of the CI of the upstream: it says that the
    code of the PR compiles and passes the repository checks. It is a signal,
    not a verdict: it NEVER publishes. The gates that publish are the
    COMPLETE one (VERDE) and the SCOPED one (VERDE-SCOPE).

    It is marked as OBSOLETE when it is about another commit (or another
    pull request): a signal of another commit says nothing about the PR in
    flight, and it must not be used for anything.
    """
    data = read_verdict_file(os.path.join(loop_dir, MERGE_VERDICT_FILE))
    if data is None:
        return {"verdict": "", "sha": "", "jobs": "", "pr": 0, "at": 0,
                "stale": False,
                "reason": "the merge signal has not been read yet"}
    verdict = str(data.get("MERGE_VERDICT", "") or "")
    sha = str(data.get("MERGE_SHA", "") or "")
    pr = as_int(data, "MERGE_PR", 0)
    out = {
        "verdict": verdict,
        "sha": sha,
        "jobs": str(data.get("MERGE_JOBS", "") or ""),
        "pr": pr,
        "at": as_int(data, "AT", 0),
        "stale": False,
        "reason": "",
    }
    if not verdict:
        out["stale"] = True
        out["reason"] = "the merge signal file has no verdict"
        return out
    issue_pr = int(state.get("pr", 0) or 0)
    if not issue_pr:
        out["stale"] = True
        out["reason"] = ("there is no pull request in flight: the signal says "
                         "nothing about the code in flight")
        return out
    if pr and pr != issue_pr:
        out["stale"] = True
        out["reason"] = (f"the signal is about the pull request #{pr} and "
                         f"#{issue_pr} is in flight: it is obsolete")
        return out
    head = pr_head_sha(cfg or {}, issue_pr)
    if not head:
        out["stale"] = True
        out["reason"] = ("the head of the pull request cannot be read: the "
                         "signal cannot be tied to a commit")
    elif not sha_matches(head, sha):
        out["stale"] = True
        out["reason"] = (f"the signal is about {sha[:8] or 'an unknown sha'} "
                         f"and the head of the pull request is {head[:8]}: it "
                         f"is obsolete")
    return out


def scope_slot_name(slot_id):
    """The name of the slot as a FILE NAME: the same normalisation the writer
    of the verdict does (gate-quick.sh), so the reader looks in the directory
    the writer wrote.

    "" when the name cannot be normalised: a name that is not the slot's
    would read the verdict of another slot, and a verdict of another slot
    never publishes anything.
    """
    raw = str(slot_id or "").strip().lower()
    out = re.sub(r"[^a-z0-9._-]", "-", raw)[:60]
    if not out or out in (".", "..") or ".." in out:
        return ""
    if out.startswith(".") or out.startswith("-"):
        return ""
    return out


def scope_verdict_path(loop_dir, slot_id):
    """The verdict file of the SCOPED gate of one slot.

    It is PER SLOT: the verdict of a slot is never the verdict of another
    one, and the file of another slot must not be able to publish this one.
    """
    name = scope_slot_name(slot_id) or LEGACY_SLOT
    return os.path.join(loop_dir, "gates", name, SCOPE_VERDICT_FILE)


def scope_checks_ok(checks):
    """True when the CHECKS line of the scoped gate says that every check ran
    and passed: `fmt:ok|layers:ok|clippy:ok`.

    A check that did NOT run (`clippy:skipped`) is NOT ok: a scoped gate
    that did not check the code is not a green gate.

    The line can carry a fourth check, the one of the workspace
    (`cargo check --workspace`): `check:ok` when it ran, `check:skipped`
    when the configuration turned it off. A `check:fail` is NOT ok: the
    scoped gate does not publish a workspace that does not compile, even
    if the tests of the packages passed.
    """
    wanted = ("fmt", "layers", "clippy")
    got = {}
    for item in str(checks or "").split("|"):
        name, _, value = item.partition(":")
        name = name.strip().lower()
        if name:
            got[name] = value.strip().lower()
    if not all(got.get(name) == "ok" for name in wanted):
        return False
    # The `check:` can be ABSENT: a line written by a version of the gate
    # that did not run the check of the workspace says nothing about it,
    # and that is not a red verdict. A `check:fail` IS a red verdict.
    workspace = got.get("check", "")
    return workspace in ("ok", "skipped", "")


def scoped_gate_green(state):
    """True when the verdict of the SCOPED gate is a green authorisation.

    The scoped gate authorises a publication only when it FINISHED, it ran
    over a real SCOPE (the packages the change touches), it found no new
    failure and every check of the scope passed. A scope of the whole
    workspace (`full`) is not a scope: there the COMPLETE gate is required.

    The sha is NOT checked here: the caller checks it against the head of
    the pull request, with the same rule the complete gate has.

    It returns (green, why): `why` says what is missing, because a refusal
    nobody can read is a deadlock.
    """
    verdict = str(state.get("scope_verdict") or "")
    if not verdict:
        return False, "it has not written its verdict yet"
    if verdict != "VERDE-SCOPE":
        return False, f"it is {verdict}, not VERDE-SCOPE"
    status = str(state.get("scope_status") or "")
    if status != "finished":
        return False, f"it did not finish (status {status or 'unknown'})"
    kind = str(state.get("scope_kind") or "")
    if kind != "packages":
        return False, (f"the scope is {kind or 'unknown'}: the COMPLETE gate "
                       "is required")
    try:
        failures = int(state.get("scope_new_failures"))
    except (TypeError, ValueError):
        return False, "the number of new failures is not a number"
    if failures:
        return False, f"it found {failures} new failures"
    if not scope_checks_ok(state.get("scope_checks")):
        return False, (f"the checks are not green "
                       f"({state.get('scope_checks') or 'none'})")
    return True, ""


def scope_verdict(loop_dir, cfg, state, slot_id):
    """The verdict of the SCOPED gate of THIS slot, as the state exposes it.

    The scoped gate runs the tests of the packages the change touches (plus
    fmt, layers and a scoped clippy) and it finishes in minutes: its verdict
    (VERDE-SCOPE) is a REAL authorisation, the alternative to the COMPLETE
    gate (VERDE), which takes hours. The vocabularies are DISJOINT.

    The verdict is tied to a commit: it is marked as STALE when its SHA is
    not the head of the pull request, because a verdict of another commit
    says nothing about the code in flight.

    The file is PER SLOT ($LOOP_DIR/gates/<slot>/scope.verdict): the verdict
    of a slot is never the verdict of another one. A missing file is NOT an
    error: the publication falls back to the complete gate, exactly as
    before.
    """
    out = {
        "scope_verdict": "",
        "scope_status": "",
        "scope_kind": "",
        "scope_packages": "",
        "scope_checks": "",
        "scope_new_failures": 0,
        "scope_failed_tests": "",
        "scope_sha": "",
        "scope_at": 0,
        "scope_stale": False,
        "scope_reason": "",
        "scope_deferred": "",
    }
    data = read_verdict_file(scope_verdict_path(loop_dir, slot_id))
    if data is None:
        out["scope_reason"] = ("the scoped gate has not written its verdict "
                               "yet")
        return out
    out["scope_verdict"] = str(data.get("VERDICT", "") or "")
    out["scope_status"] = str(data.get("GATE_STATUS", "") or "")
    out["scope_kind"] = str(data.get("SCOPE_KIND", "") or "")
    out["scope_packages"] = str(data.get("SCOPE", "") or "")
    out["scope_checks"] = str(data.get("CHECKS", "") or "")
    out["scope_new_failures"] = as_int(data, "NEW_FAILURES", 0)
    out["scope_failed_tests"] = str(data.get("FAILED_TESTS", "") or "")
    out["scope_sha"] = str(data.get("SHA", "") or "")
    out["scope_at"] = as_int(data, "AT", 0)
    # The key of the deferral: the scope was POSTPONED (the complete gate was
    # alive and the machine was busy), it was never judged.
    out["scope_deferred"] = str(data.get("DEFERRED", "") or "")
    if not out["scope_verdict"]:
        out["scope_stale"] = True
        out["scope_reason"] = ("the scoped gate wrote a verdict file without "
                               "a verdict")
        return out
    # The scoped gate runs on the head of the pull request in flight: its
    # verdict is about that commit and about nothing else.
    head = expected_head_sha(state, cfg)
    if not head:
        out["scope_stale"] = True
        out["scope_reason"] = ("the head of the pull request cannot be read: "
                               "the verdict cannot be tied to a commit")
    elif not sha_matches(head, out["scope_sha"]):
        out["scope_stale"] = True
        out["scope_reason"] = (f"the scoped gate ran on "
                               f"{out['scope_sha'][:8] or 'an unknown sha'} and "
                               f"the head of the pull request is {head[:8]}: "
                               f"the verdict is stale")
    return out


def partial_verdict_reason(state):
    """Why a publication is refused when there is no green gate.

    The signals that do NOT publish are named one by one: the quick gate
    (VERDE-PARCIAL), the merge lane (VERDE) and the scoped gate when it is
    not a green authorisation (ROJO-SCOPE, SKIP, a scope that is not a set of
    packages, a check that did not run, a verdict about another commit).

    The message says WHAT is missing and WHAT would satisfy it: a green gate
    about the head of the pull request, the COMPLETE one (VERDE) or the
    SCOPED one (VERDE-SCOPE). The reason is said out loud, because a refusal
    nobody can read is a deadlock.
    """
    quick = state.get("quick_verdict") or {}
    merge = state.get("merge_verdict") or {}
    reasons = []
    if quick.get("verdict") == "VERDE-PARCIAL":
        if quick.get("stale"):
            reasons.append("the legacy mirror of the scoped gate is "
                           "VERDE-PARCIAL but it is obsolete "
                           f"({quick.get('reason') or 'unknown reason'}): it "
                           "does not publish")
        else:
            reasons.append("the legacy mirror of the scoped gate is "
                           "VERDE-PARCIAL: the mirror does not publish, only "
                           "the verdict of this slot (gates/<slot>/"
                           "scope.verdict) does")
    if merge.get("verdict") == "VERDE":
        if merge.get("stale"):
            reasons.append("the merge signal is VERDE but it is obsolete "
                           f"({merge.get('reason') or 'unknown reason'}): it "
                           "does not publish")
        else:
            reasons.append("the merge signal is VERDE (the cheap lane of the CI "
                           "of the upstream): it is a signal, not a gate of "
                           "this slot, so it does not publish")
    scope = str(state.get("scope_verdict") or "")
    if scope:
        green, why = scoped_gate_green(state)
        if not green:
            deferred = str(state.get("scope_deferred") or "")
            if deferred:
                reasons.append(f"the scoped gate was DEFERRED ({deferred}): "
                               "the scope was postponed, not judged")
            else:
                reasons.append(f"the scoped gate says {scope}: {why}")
        elif state.get("scope_stale"):
            reasons.append(f"the scoped gate says {scope} but its verdict is "
                           f"stale ({state.get('scope_reason') or 'unknown reason'}): "
                           "it does not publish")
    if not reasons:
        return GREEN_GATE_MISSING
    return "; ".join(reasons) + " -- " + GREEN_GATE_MISSING


def pr_head_sha(cfg, pr):
    """The head SHA of one of our PRs, straight from GitHub."""
    if not pr:
        return ""
    cmd = ["gh", "pr", "view", str(pr), "--repo",
           (cfg or {}).get("UPSTREAM", "tangency-labs/solidcraft"),
           "--json", "headRefOid", "--jq", ".headRefOid"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return ""
    if out.returncode != 0:
        return ""
    value = (out.stdout or "").strip().lower()
    return value if re.fullmatch(r"[0-9a-f]{7,40}", value) else ""


def expected_head_sha(state, cfg, pr=None):
    """The commit a verdict has to be about, in the order of authority.

    1. the head of the PR: it is what is going to be published, so it is the
       authoritative answer;
    2. the tip of the branch;
    3. the HEAD of the worktree of the issue.

    "" when none of them resolves: the verdict is then refused (fail-closed),
    because a verdict that cannot be tied to a commit is not a verdict.
    """
    if pr is None:
        pr = int(state.get("pr", 0) or 0)
    head = pr_head_sha(cfg or {}, pr)
    if head:
        return head
    head = branch_sha(state.get("branch"))
    if head:
        return head.lower()
    return worktree_head_sha(state.get("issue"))


def sha_matches(left, right):
    """True when two SHAs are the same commit (compared by prefix: the verdict
    may carry the short sha and the head the full one)."""
    left = str(left or "").strip().lower()
    right = str(right or "").strip().lower()
    if not left or not right:
        return False
    size = min(len(left), len(right))
    if size < 7:
        return False
    return left[:size] == right[:size]


def review_matches_head(state, cfg, pr):
    """True when the verdict of the review is about the head of the PR.

    The verdict is tied to a commit (`review_sha`): publishing code that was
    not reviewed, or that was reviewed before the last commit, is not
    publishing a reviewed PR. The comparison is by prefix: the verdict may
    carry the short sha and the head the full one.

    The head is the SAME one the verdict was accepted against (the head of
    the PR, the tip of the branch or the HEAD of the worktree, in that
    order): a verdict accepted about one commit and published about another
    would be a verdict about code nobody reviewed.
    """
    head = expected_head_sha(state, cfg, pr)
    return sha_matches(head, state.get("review_sha"))


def publication_latched(state, cfg, pr):
    """True when the publication of THIS PR was already accepted.

    A publication is a FACT, not a verdict: the supervisor accepted it once (a
    green gate, an approved review about the head of the PR, the quota and the
    cooldown) and nothing that happens later revokes a PR that is already open
    upstream (the gate log rotates, the review is cleared, the quota fills up).

    The latch names the PR and the commit it was about, and it is dropped when
    the work it refers to is gone: another PR (a new issue) or another head
    sha (a force-push: that publication was about another commit, so the PR
    has to be gated and reviewed again).
    """
    latched_pr = int(state.get("published_pr") or 0)
    if not latched_pr or latched_pr != int(pr or 0):
        return False
    head = pr_head_sha(cfg or {}, latched_pr)
    if not head:
        # The head cannot be read (GitHub did not answer): the latch is kept.
        # A publication is a fact, and a network failure is not a reason to
        # un-publish a PR that is open.
        return True
    latched_sha = str(state.get("published_sha") or "")
    if not latched_sha:
        return True
    return sha_matches(head, latched_sha)


def enforce_gate_and_publication(state, cfg, loop_dir, live=None, slot_id=""):
    """The rules the model cannot bend: the gate, the review and the quota.

    * A phase `gating` with a GREEN gate moves to `gated` on its own: the
      verdict is the script's, not the model's.
    * A phase `gated`/`published` needs a green gate whose SHA is the head of
      the PR (a verdict of another commit is not a verdict). The green gate
      is EITHER the COMPLETE gate (VERDE) OR the SCOPED gate of this slot
      (VERDE-SCOPE about the same head): the complete gate is optional, it
      is not the only way to publish.
    * A phase `published` needs an approved review, the daily quota and the
      cooldown between publications.
    * A publication that was ALREADY accepted is not re-evaluated: it is a
      fact, not a verdict that can be revoked.
    * The signals of the loop (the legacy mirror of the scoped gate and the
      merge lane) are exposed in the state, but the MERGE lane NEVER
      publishes: it is a signal, not a gate of this slot. A refusal says the
      reason out loud.

    It works on the view of ONE slot: the verdict of the gate, the review and
    the latch of the publication are the ones of THAT slot (the "aprobado" of
    a slot does not publish the PR of another).

    The sha of the gate is FROZEN in the slot when the gate finishes: the
    sidecar of the machine is rewritten by every gate, so reading it later
    would give the sha of the NEXT gate.
    """
    phase = str(state.get("phase", "idle"))
    pr = int(state.get("pr", 0) or 0)
    gate_log = str(state.get("gate_log") or "")
    frozen = state.get("gate") if isinstance(state.get("gate"), dict) else {}

    # The verdict of the gate of THIS slot: it is computed here, from the log
    # of the slot. The live gate is a fallback, and only its OWNER adopts it.
    verdict = gate_verdict(gate_log, loop_dir)
    if not verdict and live and slot_id:
        if str(live.get("slot") or "") == slot_id:
            verdict = str(live.get("verdict") or "") or None
    # The sha of that gate: the frozen one when the slot already has it (the
    # gate is the same one), the name of the log otherwise, and the sidecar
    # as the last resort.
    frozen_sha = str(frozen.get("sha") or "") if frozen.get("log") == gate_log else ""
    sha = frozen_sha or gate_sha_of_log(gate_log) or gate_sha(loop_dir, gate_log)
    now = int(dt.datetime.now(dt.timezone.utc).timestamp())
    if verdict:
        state["gate"] = {"log": gate_log, "sha": sha, "verdict": verdict,
                         "checked_at": now, "kind": "complete"}
        state["gate_verdict"] = verdict
        state["gate_checked_at"] = now
    else:
        # no new verdict: the frozen one is the verdict of the slot.
        # `gate_verdict` is the verdict of the COMPLETE gate and of nothing
        # else: the scoped gate has its own keys (`scope_*`).
        frozen = dict(frozen)
        frozen.setdefault("kind", "complete")
        state["gate_verdict"] = (str(frozen.get("verdict") or "")
                                  if frozen.get("kind") == "complete" else "")
        state["gate_checked_at"] = to_int(frozen.get("checked_at"), 0)
        state["gate"] = frozen

    # The two SIGNALS of the loop, exposed like the gate's verdict: they are
    # facts about the code in flight, and the ones that are about another
    # commit are marked as obsolete (they are not used for anything).
    state["quick_verdict"] = quick_verdict(loop_dir, state)
    state["merge_verdict"] = merge_verdict(loop_dir, cfg, state)

    # The verdict of the SCOPED gate of THIS slot: the alternative
    # authorisation. It is read from the file of the slot, so the verdict of
    # another slot is never seen here.
    state.update(scope_verdict(loop_dir, cfg, state, slot_id))
    scope_green, scope_why = scoped_gate_green(state)
    scope_sha = str(state.get("scope_sha") or "")

    # The gate that AUTHORISES this slot: the COMPLETE gate (VERDE) when it
    # has a verdict, the SCOPED gate (VERDE-SCOPE) otherwise. The two
    # vocabularies are disjoint and the sha of each one is checked against
    # the head of the pull request.
    authorising, authorising_sha = "", ""
    if str(state.get("gate_verdict") or "") == "VERDE":
        authorising, authorising_sha = "complete", sha
    elif scope_green:
        authorising, authorising_sha = "scope", scope_sha

    # The frozen gate record says WHICH gate it is: the complete one or the
    # scoped one. The complete gate keeps its record when it has one (it is
    # the strongest one); the scoped gate takes it when the complete gate
    # never said anything.
    if authorising == "scope" and not verdict \
            and not str(frozen.get("verdict") or ""):
        state["gate"] = {"file": scope_verdict_path(loop_dir, slot_id),
                         "sha": scope_sha,
                         "verdict": str(state.get("scope_verdict") or ""),
                         "checked_at": now, "kind": "scope"}

    if phase == "gating" and authorising:
        head = pr_head_sha(cfg, pr)
        if not (authorising_sha and head and sha_matches(head, authorising_sha)):
            note(f"{gate_kind_phrase(authorising)} is green but it ran on "
                 f"{authorising_sha[:8] or 'an unknown sha'} and the head of "
                 f"#{pr} is {head[:8] or 'unknown'}: the verdict is stale, the "
                 f"phase stays 'gating'")
        else:
            state["phase"] = "gated"
            note(f"{gate_kind_phrase(authorising)} is green (on "
                 f"{authorising_sha[:8] or 'an unknown sha'}): the phase moves "
                 f"to 'gated'")
            phase = "gated"

    # The publication latch: a publication that was already accepted is a FACT
    # and it is not re-evaluated on the next turns. The latch is dropped when
    # the work it refers to is gone (another PR, or another head sha after a
    # force-push): then the PR has to be gated and reviewed again.
    latched = phase == "published" and publication_latched(state, cfg, pr)
    latched_pr = int(state.get("published_pr") or 0)
    if latched_pr and not latched:
        note(f"published: the latch of pr #{latched_pr} is dropped (the work "
             f"it refers to is gone: another PR or another head sha)")
        state["published_pr"] = 0
        state["published_sha"] = ""
    if latched:
        note(f"published: pr #{pr} is already published: the phase is kept "
             f"(a publication is a fact, not a verdict that is re-evaluated)")

    if phase in ("gated", "published") and not latched:
        if not authorising:
            # The publication needs a GREEN gate about the head of the pull
            # request: the COMPLETE gate (VERDE) OR the SCOPED gate
            # (VERDE-SCOPE). The quick gate (VERDE-PARCIAL) and the merge
            # signal (VERDE) are partial: they say something true about the
            # code, but they do not publish, and the refusal says WHY: a
            # refusal nobody can read is a deadlock.
            note(f"phase '{phase}': there is no green gate "
                 f"(verdict={state.get('gate_verdict')!r}, "
                 f"scope={state.get('scope_verdict')!r}): refused")
            partial = partial_verdict_reason(state)
            if partial:
                note(partial)
            state["phase"] = "gated" if phase == "published" else phase
            phase = state["phase"]
        elif pr:
            head = pr_head_sha(cfg, pr)
            if not (authorising_sha and head
                    and sha_matches(head, authorising_sha)):
                note(f"phase '{phase}': {gate_kind_phrase(authorising)} ran on "
                     f"{authorising_sha[:8]} but the head of #{pr} is "
                     f"{head[:8]}: the verdict is stale, refused")
                state["phase"] = "gated"
                phase = "gated"

    if phase == "published" and not latched:
        if state.get("review") != "aprobado":
            note(f"phase 'published': the review is {state.get('review')!r}, not "
                 f"'aprobado': refused (the phase stays 'gated')")
            state["phase"] = "gated"
            phase = "gated"
        elif not review_matches_head(state, cfg, pr):
            # The verdict has to be about the code that is published now: a
            # verdict of another commit (or of nothing) is not a verdict.
            head = pr_head_sha(cfg, pr)
            sha_review = str(state.get("review_sha") or "")
            note(f"phase 'published': the review is about "
                 f"{sha_review[:8] or 'nothing'} and the head of #{pr} is "
                 f"{head[:8] or 'unknown'}: refused (the phase stays 'gated')")
            state["review"] = ""
            state["review_sha"] = ""
            state["phase"] = "gated"
            phase = "gated"
        else:
            published = normalize_published(state.get("published"))
            today = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
            today_n, prev_at = published_stats(published, today)
            cap = as_int(cfg, "MAX_PR_PER_DAY", 8)
            gap = as_int(cfg, "MIN_MINUTES_BETWEEN_PUBLISH", 60)
            now = int(dt.datetime.now(dt.timezone.utc).timestamp())
            if today_n >= cap:
                note(f"phase 'published': the daily cap is full "
                     f"({today_n}/{cap}): refused (the phase stays 'gated')")
                state["phase"] = "gated"
                phase = "gated"
            elif prev_at and (now - prev_at) < gap * 60:
                note(f"phase 'published': the cooldown of {gap} min is not over "
                     f"({(now - prev_at) // 60} min since the last one): refused "
                     f"(the phase stays 'gated')")
                state["phase"] = "gated"
                phase = "gated"
            else:
                # The publication is ACCEPTED: it is a fact from now on. The
                # latch keeps the next turns from re-evaluating it, and it
                # names the commit it was about: a force-push drops it and the
                # PR has to be gated and reviewed again.
                state["published_pr"] = pr
                state["published_sha"] = pr_head_sha(cfg, pr)
                note(f"published: pr #{pr} is published: the latch is set")


def refresh_branch_sha(state):
    """The tip of the branch of THIS slot, and the verdict it invalidates.

    The verdict is about a commit: if the code moved, the verdict of the
    previous commit says nothing about the code that is going to be
    published, so it is dropped (and said out loud). The sha of the branch
    is per slot: the code of another slot is another commit.
    """
    old = str(state.get("branch_sha") or "")
    new = branch_sha(state.get("branch"))
    state["branch_sha"] = new
    if old and new and not sha_matches(old, new) and state.get("review"):
        note(f"review: reset to '' (the branch moved from {old[:8]} to "
             f"{new[:8]}: the verdict was about another commit)")
        state["review"] = ""
        state["review_sha"] = ""
    return new


def review_of_another_slot(state, slot_id, sha):
    """The slot whose code this sha is ("" when it is nobody's).

    A verdict about the commit of ANOTHER slot is not a verdict about this
    one: it is refused (the "aprobado" of a slot says nothing about the PR
    of another one).
    """
    slots = state.get("slots")
    if not isinstance(slots, dict) or not sha:
        return ""
    for other, slot in slots.items():
        if str(other) == str(slot_id) or not isinstance(slot, dict):
            continue
        other_sha = str(slot.get("branch_sha") or "") or str(slot.get("review_sha") or "")
        if other_sha and sha_matches(other_sha, sha):
            return str(other)
    return ""


def refuse_review_of_another_slot(state, slot_id, view):
    """A verdict about the code of ANOTHER slot is dropped (and said out
    loud). It is checked in the two places a verdict can arrive: the delta of
    the turn and the collection at the end of the turn.
    """
    other = review_of_another_slot(state, slot_id,
                                   str(view.get("review_sha") or ""))
    if not other:
        return False
    note(f"review: reset to '' (the verdict is about the code of the slot "
         f"{other})")
    view["review"] = ""
    view["review_sha"] = ""
    return True


def merge_review(state, delta, turn_log, texts, phase_before=None, cfg=None):
    """The review verdict: ONLY the review worker writes it.

    The delta proposes it (the orchestrator is the one that talks to
    sc-review), but the supervisor does not take its word for it: the verdict
    is accepted only when the turn log shows the reviewer saying it AND the
    sha it reviewed is the head of the PR (the tip of the branch, or the HEAD
    of the worktree, when there is no PR yet). A delta that proposes a verdict
    in a context that does not correspond (or without the worker) is ignored,
    and the refusal is logged.

    `phase_before` is the phase the turn STARTED in: the verdict belongs to
    the review cycle of the issue, not to the phase the delta asks for (the
    delta of the turn that approves moves the issue to `gating`).

    `cfg` is the configuration of the loop: it is what tells the PR head from
    the upstream repository.
    """
    phase = str(state.get("phase", ""))
    cycle = str(phase_before if phase_before is not None else phase)

    # (1) the code changed: the verdict of the previous diff is obsolete.
    #     This one is the supervisor's, not the model's.
    if phase == "implemented":
        # The verdict must be about THIS code: the head of the PR (the tip of
        # the branch, or the HEAD of the worktree, when there is no PR yet).
        refresh_branch_sha(state)
        worker, sha = review_worker_verdict(
            turn_log, texts,
            expect_sha=expected_head_sha(state, cfg, state.get("pr")))
        if worker is None:
            if state.get("review"):
                note("review: reset to '' (the code changed: the verdict is obsolete)")
            state["review"] = ""
            state["review_sha"] = ""
            if str(delta.get("review", "") or "").strip().lower() in ("aprobado", "vetado"):
                note("delta: ignoring 'review' (the code changed: the verdict is obsolete)")
            return
        apply_verdict(state, worker, sha)
        return

    if "review" not in delta:
        return                                  # the verdict survives

    value = normalize_review(delta.get("review"))
    if value is None:
        note(f"delta: ignoring 'review' ({delta.get('review')!r} is not a verdict)")
        return

    if value == "":
        # Clearing a verdict grants nothing: it is accepted in the review
        # cycle only. Outside it, it is ignored (and logged): the approval of
        # a previous turn has to survive until the publication.
        if phase in REVIEW_CYCLE:
            state["review"] = ""
            state["review_sha"] = ""
        else:
            note(f"delta: ignoring 'review' (phase '{phase}' is not a review decision)")
        return

    # (2) a verdict: it needs the worker that made it, and the worker has to
    #     have reviewed the code that is on the branch right now.
    if cycle not in REVIEW_RECORD:
        note(f"delta: ignoring 'review' (the phase '{cycle}' is not a review decision)")
        return
    refresh_branch_sha(state)
    worker, sha = review_worker_verdict(
        turn_log, texts,
        expect_sha=expected_head_sha(state, cfg, state.get("pr")))
    if worker is None:
        note(f"delta: ignoring 'review' ({value!r}): no sc-review in the turn log "
             "(the model cannot approve itself)")
        return
    if worker != value:
        note(f"delta: ignoring 'review' ({value!r}): the review worker said {worker!r}")
    apply_verdict(state, worker, sha)


def collect_review_verdict(state, turn_log, cfg=None):
    """The verdict of the review worker, collected at the END of the turn.

    The verdict of a turn is read from the log of THAT turn (the tool calls
    are written by the harness, not by the model). A worker that finished
    LATE (the turn ended before it answered) or a turn that died before
    collecting it would lose the verdict: the next turn cannot use it (a
    verdict of another turn does not count) and recovering it costs a whole
    gate (58-90 min).

    So the supervisor reads the log of the turn ONE MORE TIME, when the turn
    is over, and keeps the verdict in the state: `review`, `review_sha` (the
    commit it is about), `review_issue` and `review_branch`.

    The rules are the ones of the delta (fail-closed): the verdict counts
    only when the review worker said it in the log of THIS turn AND it is
    tied to the head of the PR (the tip of the branch, or the HEAD of the
    worktree, when there is no PR yet). The log of another turn is NEVER
    read, and neither the text of the model nor `results/`.
    """
    phase = str(state.get("phase", ""))
    if phase not in REVIEW_RECORD:
        return ""
    expected = expected_head_sha(state, cfg)
    if not expected:
        note("review: the verdict was not collected: the head of the PR, the "
             "tip of the branch and the HEAD of the worktree are all unknown "
             "(a verdict cannot be tied to a commit)")
        return ""
    verdict, sha = review_worker_verdict(turn_log, None, expect_sha=expected)
    if not verdict:
        return ""
    if (str(state.get("review") or "") == verdict
            and str(state.get("review_sha") or "") == sha):
        return ""                             # nothing new
    apply_verdict(state, verdict, sha)
    note(f"review: the verdict of the worker was collected at the end of the "
         f"turn ({verdict}, about {sha[:8]})")
    return verdict


def refresh_prs(cfg):
    """Our open PRs (the ones the loop has to keep alive)."""
    owner = cfg.get("FORK_OWNER", "vdirienzo")
    upstream = cfg.get("UPSTREAM", "tangency-labs/solidcraft")
    cmd = [
        "gh", "pr", "list", "--repo", upstream, "--author", owner,
        "--state", "open", "--limit", "100",
        "--json", "number,title,isDraft,createdAt,mergeable",
    ]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if out.returncode != 0:
            return None
        data = json.loads(out.stdout or "[]")
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return None
    prs = {}
    for pr in data:
        num = str(pr.get("number"))
        prs[num] = {
            "title": pr.get("title", ""),
            "draft": bool(pr.get("isDraft")),
            "created": pr.get("createdAt", ""),
            "mergeable": pr.get("mergeable", "UNKNOWN"),
            "state": "open",
        }
    return prs


def fork_repo(cfg):
    """The fork's `owner/repo` slug, taken from the FORK url."""
    fork = str(cfg.get("FORK", "")).strip()
    if not fork:
        return f"{cfg.get('FORK_OWNER', 'vdirienzo')}/solidcraft"
    fork = fork.removesuffix(".git").rstrip("/")
    parts = [p for p in fork.split("/") if p]
    if len(parts) >= 2:
        return "/".join(parts[-2:])
    return f"{cfg.get('FORK_OWNER', 'vdirienzo')}/solidcraft"


def ensure_report_issue(cfg, state):
    """The fork issue that hosts the daily log. Created once, then reused."""
    report = state.setdefault("report", {"last": "", "issue": 0, "pending": True})
    num = int(report.get("issue") or 0)
    slug = fork_repo(cfg)
    if num:
        return num, slug
    title = "SolidCraft loop — daily log (automático)"
    body = (
        "Registro automático del loop de issues de SolidCraft.\n\n"
        "Este issue es el **log**: una vez por día el loop publica acá un reporte "
        "corto con los PRs entregados, los issues soltados y el estado del gate.\n\n"
        "- Lo publica el supervisor (`bin/state.py`).\n"
        "- No es un pedido: nadie lo responde.\n"
        "- Todo lo que el loop hace está también en `ledger.md`.\n"
    )
    try:
        out = subprocess.run(
            ["gh", "issue", "create", "--repo", slug, "--title", title, "--body", body],
            capture_output=True, text=True, timeout=90,
        )
    except (OSError, subprocess.SubprocessError):
        return 0, slug
    if out.returncode != 0:
        print(f"could not create the daily log issue: {out.stderr.strip()[:200]}",
              file=sys.stderr)
        return 0, slug
    m = re.search(r"/issues/(\d+)", out.stdout or "")
    if not m:
        return 0, slug
    report["issue"] = int(m.group(1))
    print(f"daily log issue created: {slug}#{report['issue']}", file=sys.stderr)
    return report["issue"], slug


def post_report(slug, issue, text, comment_id=0):
    """Post the daily report as a comment on the fork's log issue.

    With `comment_id`, the comment of the day is UPDATED instead of adding a
    new one: the daily log stays a single, current comment (a snapshot taken
    in the morning is useless by the afternoon).
    """
    try:
        if comment_id:
            out = subprocess.run(
                ["gh", "api", f"repos/{slug}/issues/comments/{comment_id}",
                 "-X", "PATCH", "-f", f"body={text}"],
                capture_output=True, text=True, timeout=90,
            )
        else:
            out = subprocess.run(
                ["gh", "api", f"repos/{slug}/issues/{issue}/comments", "-f", f"body={text}"],
                capture_output=True, text=True, timeout=90,
            )
    except (OSError, subprocess.SubprocessError):
        return False, 0
    if out.returncode != 0:
        print(f"could not post the daily report: {out.stderr.strip()[:200]}",
              file=sys.stderr)
        return False, 0
    new_id = 0
    m = re.search(r'"id"\s*:\s*(\d+)', out.stdout or "")
    if m:
        new_id = int(m.group(1))
    return True, new_id or comment_id


def ledger_line(state, summary, cfg):
    when = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
    phase = state.get("phase", "")
    issue = state.get("issue", 0)
    pr = state.get("pr", 0)
    verdict = {
        "published": "ok",
        "gated": "ok",
        "gating": "en curso",
        "implemented": "en curso",
        "claimed": "en curso",
        "selected": "en curso",
        "failed": "rojo",
        "skipped": "soltado",
        "idle": "-",
    }.get(phase, "-")
    detail = summary or ""
    if pr and "pr #" not in detail:
        detail = f"pr #{pr} · {detail}" if detail else f"pr #{pr}"
    if issue and "issue" not in detail.lower():
        detail = f"issue #{issue} · {detail}" if detail else f"issue #{issue}"
    return f"| {when} | {issue or '-'} | {phase or '-'} | {verdict} | {detail} |"


def normalize_slot_id(value):
    """The id of a slot: a stable string ("0", "1", ...).

    The id is the identity of the slot, so it is never renumbered: a slot
    that closes does not move the others. The SUPERVISOR decides it (the
    invocation), never the delta of the model.
    """
    text = str(value or "").strip()
    if not text:
        return LEGACY_SLOT
    if text.isdigit():
        return str(int(text))
    return re.sub(r"[^A-Za-z0-9_.-]", "_", text)[:32]


def slot_defaults(slot):
    """The slot with the fields it must have (and the types they must have:
    the file can come from another version of the supervisor)."""
    out = dict(slot) if isinstance(slot, dict) else {}
    for key, value in DEFAULT_SLOT.items():
        if key not in out:
            out[key] = copy.deepcopy(value)
    for key in ("review", "review_sha", "branch", "branch_sha", "gate_log",
                "review_branch", "gate_verdict", "scope_verdict",
                "scope_status", "scope_kind", "scope_packages",
                "scope_checks", "scope_failed_tests", "scope_sha",
                "scope_reason", "scope_deferred"):
        if not isinstance(out.get(key), str):
            out[key] = ""
    for key in ("scope_new_failures", "scope_at"):
        if isinstance(out.get(key), bool) or not isinstance(out.get(key), int):
            out[key] = 0
    if not isinstance(out.get("scope_stale"), bool):
        out["scope_stale"] = False
    if not isinstance(out.get("gate"), dict):
        out["gate"] = {}
    return out


def migrate_state(state, loaded=None):
    """v1 -> v2: the per-issue fields move to the slot "0".

    It is done ON READ and it is idempotent: a file that already has
    "slots" is left alone (only the defaults of the slot are filled). The
    globals stay where they are. Nothing is lost: a flat field that cannot
    be mapped stays at the top level and it is said in the log.

    `loaded` is the dict that was read from the file: the legacy flat keys
    of the file are the storage of the slot "0" (a writer that has not been
    migrated yet writes them), but the DEFAULTS of the supervisor are not
    (they would wipe the slot).

    Returns True when the file was migrated.
    """
    slots = state.get("slots")
    if isinstance(slots, dict) and slots:
        for slot_id, slot in list(slots.items()):
            slots[slot_id] = slot_defaults(slot)
        # The flat keys at the top level are the LEGACY storage of the slot
        # "0": a writer that has not been migrated yet (the supervisor's
        # mark_turn_state) writes them and reads them back, so they are what
        # the slot "0" holds. The other slots have no flat keys: they live
        # only in `slots`.
        legacy = slots.get(LEGACY_SLOT)
        if isinstance(legacy, dict) and isinstance(loaded, dict):
            for key in LEGACY_FLAT_FIELDS:
                if key in loaded:
                    legacy[key] = loaded[key]
        state["slots"] = slots
        state["version"] = max(STATE_VERSION, as_int(state, "version", 0))
        return False
    slot = {}
    for key in SLOT_FIELDS:
        if key in state:
            slot[key] = state.pop(key)
    # the frozen gate of the slot: the v1 state had the verdict of the gate
    # flat, and it is the frozen verdict of the slot "0".
    slot["gate"] = {
        "log": str(slot.get("gate_log") or ""),
        "sha": "",
        "verdict": str(slot.get("gate_verdict") or ""),
        "checked_at": to_int(slot.get("gate_checked_at"), 0),
    }
    state["slots"] = {LEGACY_SLOT: slot_defaults(slot)}
    # the flat fields that are not mapped to a slot stay at the top level:
    # nothing is lost, and the log says which ones they are.
    unknown = sorted(k for k in state if k not in GLOBAL_FIELDS)
    if unknown:
        note("state: these fields are not part of the schema and they stay at "
             f"the top level: {', '.join(unknown)}")
    state["version"] = max(STATE_VERSION, as_int(state, "version", 0))
    return True


def load_state(path):
    """The state of the file, in v2. Returns (state, migrated)."""
    state = dict(DEFAULT)
    state["counters"] = dict(DEFAULT["counters"])
    state["report"] = dict(DEFAULT["report"])
    state["slots"] = {}
    state["gate"] = {}
    loaded = None
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as fh:
                loaded = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"state.json unreadable ({exc}); using the default", file=sys.stderr)
    if isinstance(loaded, dict):
        state.update(loaded)
    if not isinstance(state.get("counters"), dict):
        state["counters"] = dict(DEFAULT["counters"])
    if not isinstance(state.get("report"), dict):
        state["report"] = dict(DEFAULT["report"])
    migrated = migrate_state(state, loaded if isinstance(loaded, dict) else None)
    return state, migrated


def note_version_mismatch(delta, version_read):
    """The CAS: the delta may say which version of the state it was written
    against.

    When it does not match, the delta is applied again over the FRESH state
    (the one that was just read under the lock): the delta is per slot and
    the merge is commutative, so nothing is lost. The gap is said out loud:
    a mismatch nobody can read is a mystery.
    """
    if not isinstance(delta, dict) or "expected_version" not in delta:
        return
    try:
        expected = int(delta.get("expected_version"))
    except (TypeError, ValueError):
        note("delta: 'expected_version' is not a number: ignored")
        return
    if expected != int(version_read or 0):
        note(f"delta: it was written for the version {expected} and the state "
             f"is at {version_read}: it is applied again over the fresh state "
             f"(the delta is per slot and the merge is commutative)")


def slot_view(state, slot_id):
    """The working view of ONE slot: its own fields plus the globals it needs.

    Every rule of the supervisor keeps working on a flat dict: the unit of
    work is the slot, and the globals (the quota, the triage, the counters)
    are read through the view.
    """
    slots = state.get("slots")
    if not isinstance(slots, dict):
        slots = {}
        state["slots"] = slots
    slot = slots.get(slot_id)
    if not isinstance(slot, dict):
        slot = {}
    view = {}
    for key, value in state.items():
        if key == "slots" or key in SLOT_FIELDS:
            continue          # the globals only: the slot has its own
        view[key] = value
    view.update(slot)
    for key, value in DEFAULT_SLOT.items():
        if key not in view:
            view[key] = copy.deepcopy(value)
    return view


def store_slot(state, slot_id, view):
    """The view goes back into the state: its own fields into the slot, the
    globals at the top level. The slots of the other slots are NOT touched.
    """
    slots = state.get("slots")
    if not isinstance(slots, dict):
        slots = {}
        state["slots"] = slots
    slot = {}
    for key in SLOT_FIELDS:
        if key in view:
            slot[key] = view[key]
    slots[slot_id] = slot
    for key, value in view.items():
        if key in SLOT_FIELDS or key == "slots":
            continue
        state[key] = value


def write_legacy_mirror(state):
    """The flat keys at the top level are the LEGACY storage of the slot "0".

    The readers that have not been migrated yet (the supervisor, the prompts)
    read them. They are written from `slots["0"]` and they are read back as
    the slot "0" (see migrate_state): they are the same data, so they cannot
    disagree with it.
    """
    slots = state.get("slots")
    slot = slots.get(LEGACY_SLOT) if isinstance(slots, dict) else None
    if not isinstance(slot, dict):
        return
    for key in LEGACY_FLAT_FIELDS:
        if key in slot:
            state[key] = slot[key]


def slot_holds_work(slot):
    """Whether this slot HOLDS work in progress on its issue.

    It is the reservation of the issue: the slot that is working on an issue
    holds it, and a `failed` slot holds it too WHEN IT STILL HAS A PULL
    REQUEST (`failed` is not terminal, the slot resumes the issue, and the PR
    is OPEN upstream: another slot taking the same issue would open a SECOND
    pull request about the same bug).

    It is ONE definition for the two arbitrations (the delta of the turn and
    the inherited state): they cannot disagree about what is reserved.
    """
    if not isinstance(slot, dict):
        return False
    phase = str(slot.get("phase") or "")
    if phase in WORK_IN_PROGRESS_PHASES:
        return True
    return phase == "failed" and to_int(slot.get("pr"), 0) != 0


def slot_rank(slot):
    """How much work a slot holds of its issue (the rule of "who wins").

    It is a tuple and the bigger the better:
      1. it holds work in progress (the issue is reserved by it);
      2. it has a pull request open (the PR is the real work: it is open
         upstream and nobody else can undo it).
    """
    return (1 if slot_holds_work(slot) else 0,
            1 if to_int(slot.get("pr"), 0) else 0)


def slot_id_key(slot_id):
    """The order of the ids of the slots: the numbers first, by number.

    The id of a slot is its identity and it is never renumbered, so the
    lowest id is the one that was there first.
    """
    text = str(slot_id)
    if text.isdigit():
        return (0, int(text), "")
    return (1, 0, text)


def slot_wins(slot, slot_id, other, other_id):
    """Whether this slot wins the issue against the other slot.

    THE RULE OF "WHO WINS", in this order:
      (a) the slot that is working on the issue wins over one that is not
          (a phase of work in progress, or a `failed` slot with a pull
          request open);
      (b) at the same phase, the slot with a pull request open wins (the PR
          is the real work);
      (c) at the same, the slot of the LOWEST id wins (the one that was
          there first).

    It is the SAME rule for the arbitration of the delta and the arbitration
    of the inherited state: they cannot contradict each other.
    """
    rank = slot_rank(slot)
    other_rank = slot_rank(other)
    if rank != other_rank:
        return rank > other_rank
    return slot_id_key(slot_id) < slot_id_key(other_id)


def winner_slot(candidates):
    """The slot that wins the contest for an issue (the keeper of the issue).

    `candidates` is a list of (slot_id, slot) pairs.
    """
    best = None
    for pair in candidates or []:
        slot_id, slot = str(pair[0]), pair[1]
        if best is None or slot_wins(slot, slot_id, best[1], best[0]):
            best = (slot_id, slot)
    return best


def issue_holder(state, issue):
    """The slot that HOLDS this issue ("" when nobody is working on it).

    It is the WINNER of the contest among the slots that are working on it
    (see `slot_wins`): the same rule that the arbitration of the inherited
    state uses, so the two cannot disagree about who keeps the issue.
    """
    num = to_int(issue, 0)
    if num <= 0:
        return ""
    slots = state.get("slots")
    if not isinstance(slots, dict):
        return ""
    candidates = []
    for other, slot in slots.items():
        if not isinstance(slot, dict):
            continue
        if to_int(slot.get("issue"), 0) != num:
            continue
        if slot_holds_work(slot):
            candidates.append((str(other), slot))
    if not candidates:
        return ""
    return winner_slot(candidates)[0]


def issue_reserved_by(state, slot_id, issue):
    """The slot that holds this issue in flight ("" when the issue is free).

    THE RESERVATION IS BY ISSUE, not by slot: the slot that took an issue
    holds it while it works on it, and no other slot may take it. It is
    symmetric: the slot 1 holding an issue keeps the slot 0 from taking it,
    and the other way round.

    A slot that is NOT working on anything (idle) or that has finished
    (published, skipped) holds nothing: `done` and `skipped` are global
    books, and the issue is over for everybody.

    A `failed` slot holds its issue WHEN IT STILL HAS A PULL REQUEST:
    `failed` is not terminal (the slot resumes the issue) and the PR is
    OPEN upstream, so another slot taking the same issue would open a
    SECOND pull request about the same bug. A failed slot without a PR
    (the claim failed before the PR existed) holds nothing.

    The holder is the WINNER of the contest for the issue (see
    `issue_holder`): when two slots hold it, the one with the real work
    keeps it, and that is the one that refuses the claim of the other.
    """
    holder = issue_holder(state, issue)
    if holder and holder != str(slot_id):
        return holder
    return ""


def release_issue(slot, slot_id, issue, keeper_id):
    """The slot gives the issue up: it keeps nothing of it.

    WHY: two slots on one issue fight over the same worktree
    ($WT_ROOT/issue-<N>) and open two pull requests about the same bug. The
    slot that has the real work keeps the issue; the other one is freed so it
    can triage again.

    The phase is NOT degraded to `failed`: giving an issue up is not a
    failure of the code. But a slot that was working on an issue it does not
    have any more cannot stay in `implemented` (that would be an incoherent
    state): its phase goes back to `idle`.
    """
    note(f"issue #{issue} is in flight in the slot {keeper_id}: the slot "
         f"{slot_id} gives it up")
    slot["issue"] = 0
    slot["branch"] = ""
    slot["pr"] = 0
    phase = str(slot.get("phase") or "")
    if phase in WORK_IN_PROGRESS_PHASES:
        slot["phase"] = "idle"
        note(f"the slot {slot_id} goes back to 'idle' (it was '{phase}' about "
             f"an issue it does not have)")
    inflight = slot.get("in_flight")
    if (isinstance(inflight, dict)
            and to_int(inflight.get("issue"), 0) == to_int(issue, 0)):
        slot["in_flight"] = None


def arbitrate_inherited(state):
    """The arbitration of the state INHERITED: two slots on the SAME issue.

    WHY: the arbitration of the delta only sees the CLAIM of the turn. The
    state can arrive ALREADY in conflict (a slot took an issue in a turn
    where the other slot had it in flight), and then two slots work on the
    same issue: they fight over the same worktree ($WT_ROOT/issue-<N>) and
    they open two pull requests about the same bug.

    The rule of "who wins" is the SAME one the arbitration of the delta uses
    (see `slot_wins`): the slot that has the real work keeps the issue and
    the other one gives it up (its issue, its branch and its pull request go
    empty, and its phase goes back to `idle` when it was working on it).

    It has to run UNDER THE LOCK of the state, with the state read fresh
    (inside `run_turn`): two `state.py` in parallel would see the same
    conflict and could resolve it in two different ways.
    """
    slots = state.get("slots")
    if not isinstance(slots, dict):
        return
    by_issue = {}
    for slot_id, slot in slots.items():
        if not isinstance(slot, dict):
            continue
        if str(slot.get("phase") or "") in FINISHED_PHASES:
            continue        # the issue is over for that slot
        num = to_int(slot.get("issue"), 0)
        if num <= 0:
            continue
        by_issue.setdefault(num, []).append((str(slot_id), slot))
    for num in sorted(by_issue):
        holders = by_issue[num]
        if len(holders) < 2:
            continue
        workers = [(sid, s) for sid, s in holders if slot_holds_work(s)]
        if not workers:
            # nobody is working on it: there is no work in flight to
            # arbitrate (the issue is only a number in two empty slots)
            continue
        keeper_id, _keeper = winner_slot(workers)
        for other_id, other in holders:
            if other_id == keeper_id:
                continue
            release_issue(other, other_id, num, keeper_id)


def slot_of_work(state, slot_id, key, value):
    """The slot whose branch (or pull request) this is ("" when nobody's).

    A branch and a pull request are the work of ONE slot: the branch of the
    issue of another slot is not this slot's branch, and neither is its pull
    request.
    """
    if value in (None, "", 0):
        return ""
    slots = state.get("slots")
    if not isinstance(slots, dict):
        return ""
    for other, slot in slots.items():
        if str(other) == str(slot_id) or not isinstance(slot, dict):
            continue
        if str(slot.get(key) or "") == str(value):
            return str(other)
    return ""


def arbitrate_claim(state, slot_id, delta):
    """The arbitration of the claim of a delta. THE MODEL PROPOSES, THE
    SUPERVISOR DECIDES.

    It returns (issue, holder, refused): the issue that is in flight in
    another slot (0 when there is none), the slot that holds it ("" when
    there is none) and the keys of the delta that are refused because of it
    (a map: the key -> the slot that holds that work).

    WHY: two slots can triage at the same time and reach the claim of the
    SAME issue before either of them has opened the pull request. The rule
    of the prompts ("if there is already an open pull request about that
    issue, do not open a second one") only fires when the pull request
    ALREADY exists, and two slots that triaged at the same time have not
    opened it yet. They would fight over the same worktree
    ($WT_ROOT/issue-<N>) and would open two pull requests about the same
    bug.

    The reservation is by ISSUE: the slot that took an issue holds it while
    it works on it (`selected|claimed|implemented|gating|gated`), and no
    other slot may take it. A slot that is idle, or that has finished
    (published, skipped), holds nothing: the issue is over for everybody.

    The issue of the slot ITSELF is not a conflict: proposing it again is a
    continuation, not a claim.

    The branch and the pull request go with the issue: they are refused with
    it (a branch of another slot is not this slot's branch). They are also
    refused on their own when the delta names the work of another slot
    without naming the issue (the model works on the issue of its slot and
    only names the branch).

    The holder of the issue is the winner of the contest for it (see
    `issue_holder` and `slot_wins`): it is the SAME rule that the
    arbitration of the inherited state uses, so the two cannot contradict
    each other.
    """
    issue = 0
    holder = ""
    refused = {}
    if not isinstance(delta, dict):
        return issue, holder, refused
    if "issue" in delta:
        try:
            proposed = int(delta.get("issue") or 0)
        except (TypeError, ValueError):
            proposed = 0
        if proposed > 0:
            other = issue_reserved_by(state, slot_id, proposed)
            if other:
                issue = proposed
                holder = other
                refused["issue"] = other
                refused["branch"] = other
                refused["pr"] = other
    for key in ("branch", "pr"):
        if key in refused or key not in delta:
            continue
        other = slot_of_work(state, slot_id, key, delta.get(key))
        if other:
            refused[key] = other
    return issue, holder, refused


def acquire_state_lock(loop_dir, timeout=30.0):
    """The global lock of the state: a short `flock` around read -> merge ->
    write.

    It is NOT blocking: a turn that cannot take the lock in `timeout` seconds
    gives up and says so. A turn that hangs forever is worse than a turn
    that does not write anything: the next turn retries with the fresh
    state.
    """
    path = os.path.join(loop_dir, ".state.lock")
    try:
        os.makedirs(loop_dir, exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    except OSError as exc:
        print(f"could not open the lock of the state ({path}): {exc}",
              file=sys.stderr)
        return None
    deadline = time.monotonic() + max(0.0, timeout)
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError:
            if time.monotonic() >= deadline:
                os.close(fd)
                return None
            time.sleep(0.05)


def release_state_lock(fd):
    """The lock of the state is released (closing the fd releases it too)."""
    if fd is None:
        return
    for call in (lambda: fcntl.flock(fd, fcntl.LOCK_UN), lambda: os.close(fd)):
        try:
            call()
        except OSError:
            pass


def append_ledger(path, line):
    """One line in the ledger, under a lock.

    The append is under a `flock` because a line can be LONGER than
    PIPE_BUF: two concurrent appends would be split in the middle.
    """
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    except OSError as exc:
        print(f"could not write the ledger: {exc}", file=sys.stderr)
        return
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, (line + "\n").encode("utf-8"))
    except OSError as exc:
        print(f"could not write the ledger: {exc}", file=sys.stderr)
    finally:
        release_state_lock(fd)


def write_slot_view(path, state, slot_id):
    """The view of the slot: what the MODEL reads.

    It has the same flat keys as the state of today (the phase, the issue,
    the gate log, the review...) plus the globals the model consults: the
    quota, the triage, the counters. The model does not read state.json: it
    reads this, and it only ever sees the slot of its turn.
    """
    slots = state.get("slots")
    slot = slots.get(slot_id) if isinstance(slots, dict) else None
    slot = slot_defaults(slot if isinstance(slot, dict) else {})
    view = {}
    for key in LEGACY_FLAT_FIELDS:
        view[key] = slot.get(key)
    for key in VIEW_GLOBALS:
        view[key] = state.get(key)
    view["slot"] = slot_id
    view["version"] = state.get("version")
    write_atomic(path, view)


def live_gate_of(loop_dir, state, slot_id, view):
    """The LIVE gate of the machine (there is one) and the slot that owns it.

    The sidecars are the supervisor's: they say which gate is running now.
    The owner is the slot whose gate it is.
    """
    live = state.get("gate")
    live = dict(live) if isinstance(live, dict) else {}
    for key, value in read_live_sidecars(loop_dir).items():
        if value not in (None, "", 0):
            live[key] = value
    owner = str(live.get("slot") or "")
    log = str(live.get("log") or "")
    slot_log = str(view.get("gate_log") or "")
    if log and slot_log and log == slot_log and owner in ("", slot_id):
        live["slot"] = slot_id
    return live


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--ledger", required=True)
    ap.add_argument("--turn-log", default="", help="jsonl of THIS turn")
    ap.add_argument("--config", default="")
    ap.add_argument("--gate-pid-file", default="")
    ap.add_argument("--gate-started-file", default="")
    ap.add_argument("--reports-dir", default="")
    ap.add_argument("--loop-dir", default="",
                    help="the loop's directory (where bin/ lives)")
    ap.add_argument("--session-id", default="")
    ap.add_argument("--slot", default=LEGACY_SLOT,
                    help="the slot of this turn (the supervisor decides it)")
    ap.add_argument("--slot-view", default="",
                    help="where to write the view of the slot (what the model "
                         "reads)")
    ap.add_argument("--lock-timeout", type=float, default=0.0,
                    help="seconds to wait for the lock of the state (0 = the "
                         "default)")
    a = ap.parse_args()

    cfg = read_config(a.config) if a.config else {}
    slot_id = normalize_slot_id(a.slot)
    loop_dir = a.loop_dir or loop_dir_of(a.state)
    timeout = a.lock_timeout or as_float(cfg, "STATE_LOCK_TIMEOUT_S", 30.0)
    if timeout <= 0:
        timeout = 30.0

    # The lock of the state: the read -> merge -> write has to be atomic for
    # the CONTENT of the file, not only for the file itself. Two slots in
    # parallel would lose the delta of one of them (the quota counted twice,
    # the attempts lost, the review of the other slot overwritten).
    lock = acquire_state_lock(loop_dir, timeout)
    if lock is None:
        print(f"the lock of the state is busy after {timeout:g}s: this turn "
              f"did not touch the state (another slot is writing it)", file=sys.stderr)
        return 1
    try:
        return run_turn(a, cfg, slot_id, loop_dir)
    finally:
        release_state_lock(lock)


def run_turn(a, cfg, slot_id, loop_dir):
    """The turn of ONE slot: read, merge and write the state.

    It runs under the global lock of the state (the caller takes it): the
    state is read FRESH, so the delta of this turn is applied over what the
    other slot wrote, not over what it wrote before.
    """
    state, migrated = load_state(a.state)
    if migrated:
        note("state: migrated to v2 (the per-issue fields of the old flat "
             "state moved to the slot '0')")
    version_read = int(state.get("version") or 0)

    # --- 0. the arbitration of the INHERITED state ------------------------
    # Two slots can hold the SAME issue when the state arrives already in
    # conflict (the claim of an earlier turn). It is arbitrated HERE, under
    # the global lock of the state and with the state read FRESH: two
    # `state.py` in parallel would otherwise see the same conflict and
    # resolve it in two different ways.
    arbitrate_inherited(state)

    # the working view of THIS slot: its own fields plus the globals it
    # needs. Every rule below keeps working on a flat dict: the unit of
    # work is the slot, and the globals are read through the view.
    view = slot_view(state, slot_id)

    # --- 1. the model's delta --------------------------------------------
    delta = last_json_block(a.turn_log) if a.turn_log else None
    texts = turn_texts(a.turn_log) if a.turn_log else []
    summary = ""
    report_text = ""
    # the phase the state is in NOW, before the delta overwrites it: the
    # transition is checked against this one, and it tells whether the issue
    # ENTERS `failed` in this turn (the attempt is counted once).
    phase_before = str(view.get("phase", "idle"))
    if delta is None:
        print("no json block: the state stays as it was", file=sys.stderr)
    else:
        note_version_mismatch(delta, version_read)
        # --- the arbitration of the claim --------------------------------
        # It happens HERE, under the global lock of the state: the state is
        # read FRESH inside the lock, so the slot that took the issue first
        # is seen by the one that comes second, and only one of them can
        # hold it. The issue that is in flight in another slot is reserved:
        # the claim is refused and the slot keeps what it had.
        conflict_issue, conflict_slot, refused = arbitrate_claim(
            state, slot_id, delta)
        if conflict_slot:
            note(f"issue #{conflict_issue} is already in flight in the slot "
                 f"{conflict_slot}: the claim is refused")
        for key, other in sorted(refused.items()):
            if key == "issue":
                continue
            note(f"delta: ignoring '{key}' (it belongs to the issue of "
                 f"the slot {other})")
        for key in PROPOSABLE:
            if key in delta and key not in ("review", "approval_asked"):
                if key in refused:
                    continue
                view[key] = delta[key]
        summary = str(delta.get("summary", "") or "")
        report_text = str(delta.get("report_text", "") or "").strip()
        if not report_text:
            lines = delta.get("report_lines")
            if isinstance(lines, list):
                report_text = "\n".join(str(x) for x in lines).strip()
        for ignored in ("published", "published_pr", "attempts", "in_flight",
                        "counters", "prs", "mode", "done", "skipped"):
            if ignored in delta:
                print(f"delta: ignoring '{ignored}' (the supervisor keeps it)",
                      file=sys.stderr)
        if "gate_log" in delta:
            print("delta: ignoring 'gate_log' (the identity of the gate "
                  "belongs to the supervisor)", file=sys.stderr)
        # `review` has its own policy: only the review worker writes it.
        merge_review(view, delta, a.turn_log, texts, phase_before, cfg)
        # a verdict about the commit of ANOTHER slot is not a verdict about
        # this one: it is refused.
        refuse_review_of_another_slot(state, slot_id, view)
        # `approval_asked` too: one request per PR, never twice. The model
        # proposes the PRs it asked to approve; the supervisor keeps the book
        # so a turn that repeats itself does not spam the maintainers.
        asked = view.setdefault("approval_asked", {})
        proposed = delta.get("approval_asked")
        if isinstance(proposed, dict):
            for num, value in proposed.items():
                key = str(num).strip()
                if not key:
                    continue
                if key not in (view.get("prs") or {}):
                    note(f"approval: PR #{key} is not one of ours: ignored")
                    continue
                # The approval is PER RUN, and every push creates a new run.
                # The key is therefore the head SHA, not the PR: a new push
                # (a new SHA) may be asked again, the same one may not.
                sha = str(value or "").strip()
                if not sha:
                    note(f"approval: PR #{key} without a head SHA: ignored")
                    continue
                if asked.get(key) == sha:
                    continue
                asked[key] = sha
                note(f"approval requested on PR #{key} (head {sha[:8]})")
        view["approval_asked"] = asked

        # --- the phase is a transition, not a wish ----------------------
        current = phase_before
        proposed = str(delta.get("phase", "") or "").strip()
        if "issue" in refused and proposed in WORK_IN_PROGRESS_PHASES:
            # The claim was refused: the phase that went with it is refused
            # too (a slot cannot be working on an issue it did not take).
            # The phase is NOT degraded to 'failed': a conflict of claim is
            # not a failure of the code, it is two slots that wanted the
            # same issue.
            note(f"phase: '{proposed}' is ignored (the claim of the issue "
                 f"#{conflict_issue} was refused): the phase stays "
                 f"'{current}'")
            view["phase"] = current
        elif proposed and proposed not in PHASES:
            note(f"phase: '{proposed}' is not a phase: refused (the phase stays "
                 f"'{current}')")
            view["phase"] = current
        elif proposed and proposed not in TRANSITIONS.get(current, set()):
            note(f"phase: '{current}' -> '{proposed}' is not a transition: "
                 f"refused")
            view["phase"] = current
        elif proposed:
            view["phase"] = proposed

    # --- 1a. the gate of THIS slot ----------------------------------------
    # The identity of the gate belongs to the SUPERVISOR (the sidecar of the
    # slot), not to the model: the model does not get to point the state at a
    # log of its choice.
    supervisor_log = supervisor_gate_log(loop_dir, slot_id, state)
    if supervisor_log:
        view["gate_log"] = supervisor_log

    # --- 1b. the supervisor's own rules on the phase ----------------------
    # The gate's verdict is computed HERE, not taken from the model's word,
    # and the publication needs a green gate, an approved review and the
    # quota. The model proposes; the supervisor decides. It all happens on
    # the view of THIS slot: the verdict, the review and the latch of the
    # publication are the ones of this slot.
    live = live_gate_of(loop_dir, state, slot_id, view)
    enforce_gate_and_publication(view, cfg, loop_dir, live=live, slot_id=slot_id)

    # --- 2. the supervisor's bookkeeping ---------------------------------
    now = int(dt.datetime.now(dt.timezone.utc).timestamp())
    phase = str(view.get("phase", "idle"))
    issue = int(view.get("issue", 0) or 0)
    pr = int(view.get("pr", 0) or 0)

    # the gate's PID and start marker are written by start-gate.sh
    for path, key in ((a.gate_pid_file, "gate_pid"), (a.gate_started_file, "gate_started")):
        if not path:
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                view[key] = int((fh.read().strip() or "0").split()[0])
        except (OSError, ValueError, IndexError):
            view[key] = 0

    # the 3-hour rule: an issue in flight for too long is given up
    max_inflight = as_int(cfg, "MAX_INFLIGHT_MIN", 180)
    inflight = view.get("in_flight")
    if isinstance(inflight, dict) and inflight.get("started"):
        age_min = (now - int(inflight["started"])) // 60
        if age_min > max_inflight and str(view.get("phase", "")) not in IN_FLIGHT_EXEMPT:
            print(f"in_flight expired ({age_min} min > {max_inflight}): failed",
                  file=sys.stderr)
            view["phase"] = "failed"
            view["in_flight"] = None
            phase = "failed"

    # a gate that is dead without an EXIT= in its log died (SIGKILL, OOM, the
    # machine went down). There is nothing to wait for: it is given up.
    if phase == "gating":
        gate_log = str(view.get("gate_log") or "")
        pid = int(view.get("gate_pid") or 0)
        alive = False
        if pid > 0:
            try:
                os.kill(pid, 0)
                alive = True
            except OSError:
                alive = False
        # M1: the EXIT= of the run that already finished can be in the
        # ROTATED log (<log>.1): the log of the run that is going on was
        # rotated and has no EXIT= yet. A green run that is in the .1 is NOT
        # a dead gate.
        finished = gate_has_finished_run(gate_log)
        # M3: the gate can also be dead without a dead pid: gate-check.sh
        # says `dead` when the log has no EXIT= and it is older than
        # GATE_TIMEOUT_MIN. Such a gate will never say anything.
        status = gate_status(gate_log, a.loop_dir or loop_dir_of(a.state)) \
            if gate_log else ""
        if status == "dead" and not finished:
            note("the gate is dead (no EXIT= and no finished run, not even in "
                 "the rotated log): failed")
            view["phase"] = "failed"
            phase = "failed"
        elif pid > 0 and not alive and gate_log and not finished:
            print("the gate died without writing EXIT=: failed", file=sys.stderr)
            view["phase"] = "failed"
            phase = "failed"

    # M8: the brake of the issue in flight. `failed` is NOT terminal (the
    # issue is retried), so without a counter the loop can give the same
    # issue an infinite number of turns. The attempts are counted here and,
    # over the cap (MAX_ATTEMPTS_PER_ISSUE), the issue is SKIPPED: it was
    # tried N times without a published PR and it is not worth another turn.
    if phase == "failed" and issue and phase_before != "failed":
        attempts = view.get("attempts")
        if not isinstance(attempts, dict):
            attempts = {}
            view["attempts"] = attempts
        key = str(issue)
        try:
            tried = int(attempts.get(key, 0) or 0) + 1
        except (TypeError, ValueError):
            tried = 1
        attempts[key] = tried
        cap = as_int(cfg, "MAX_ATTEMPTS_PER_ISSUE", 3)
        if tried > cap:
            note(f"the issue #{issue} was attempted {tried} times without a "
                 f"published PR: skipped (the cap is {cap})")
            view["phase"] = "skipped"
            phase = "skipped"

    if phase in TERMINAL_PHASES:
        view["in_flight"] = None
    elif issue:
        prev = view.get("in_flight")
        started = int(prev["started"]) if isinstance(prev, dict) and prev.get("started") else now
        view["in_flight"] = {"issue": issue, "started": started}

    # publication caps
    # `published` is {day: [{"pr": N, "at": epoch}]}: the timestamp is what
    # the cooldown (MIN_MINUTES_BETWEEN_PUBLISH) needs. The old format
    # (a bare list of PR numbers) is converted here, on read.
    raw_published = view.get("published")
    published = normalize_published(raw_published)
    if published != raw_published:
        note("published: converted to the new format "
             "({\"pr\": N, \"at\": epoch})")
    today = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    if phase == "published":
        # The publication is counted even if the model forgot the PR number:
        # a publication that does not count is a publication without a quota
        # (and the quota is what keeps the loop from flooding the upstream).
        # The cooldown is measured against the PREVIOUS publication, so it is
        # read before this one is added
        _, prev_at = published_stats(published, today)
        lst = list(published.get(today, []))
        if not any(entry.get("pr") == pr and pr for entry in lst):
            lst.append({"pr": pr, "at": now})
        published[today] = lst
        done = list(view.get("done", []))
        if issue and issue not in done:
            done.append(issue)
        view["done"] = done
        # the quota, for the log: the orchestrator decides with these numbers
        cap = as_int(cfg, "MAX_PR_PER_DAY", 8)
        gap = as_int(cfg, "MIN_MINUTES_BETWEEN_PUBLISH", 60)
        today_n, _ = published_stats(published, today)
        since = (now - prev_at) // 60 if prev_at else 0
        note(f"published: pr #{pr} at {now} "
             f"(today {today_n}/{cap}, "
             f"{'the previous one was ' + str(since) + ' min ago' if prev_at else 'it is the first one'}, "
             f"the cooldown asks for {gap} min)")
        if today_n > cap:
            note(f"WARNING: the daily cap is over ({today_n} > {cap})")
        if prev_at and (now - prev_at) < gap * 60:
            note(f"WARNING: the cooldown of {gap} min between publications is not over "
                 f"({since} min since the last one)")
    if phase == "skipped" and issue:
        skipped = list(view.get("skipped", []))
        if issue not in skipped:
            skipped.append(issue)
        view["skipped"] = skipped
    # --- the triage results -------------------------------------------------
    # The triage worker writes its verdict in the SUMMARY of the turn:
    #
    #     triage: issue #<N>: <tomar|soltar> - <motivo>
    #
    # The summary is the only channel the orchestrator has: it has no
    # write/edit, so a file in results/ would never be written by anyone and
    # the "soltar" of an issue would be lost (the issue would be triaged
    # again in every wait). The supervisor reads the summary and keeps the
    # verdict, so a candidate already dropped is not triaged again, and so a
    # "soltar" decided while a gate runs is recorded even though the phase
    # cannot move to `skipped` from `gating` (that transition does not exist,
    # and a live gate must not be stranded).
    #
    # The files in results/ are read too, when they exist: they are MEMORY
    # (they cannot approve a review, unblock a gate or publish anything).
    # Only the bookkeeping of the candidates is taken from them.
    triage_dir = os.path.join(a.loop_dir or loop_dir_of(a.state), "results")
    triage_state = view.setdefault("triage", {})
    if os.path.isdir(triage_dir):
        for name in sorted(os.listdir(triage_dir)):
            if not (name.startswith("triage-") and name.endswith(".json")):
                continue
            try:
                with open(os.path.join(triage_dir, name), encoding="utf-8") as fh:
                    entry = json.load(fh)
            except (OSError, ValueError):
                continue
            if not isinstance(entry, dict):
                continue
            try:
                t_issue = int(entry.get("issue", 0) or 0)
                t_at = int(entry.get("at", 0) or 0)
            except (TypeError, ValueError):
                continue
            verdict = str(entry.get("veredicto", "") or "").strip().lower()
            if t_issue <= 0 or verdict not in ("tomar", "soltar"):
                continue
            triage_state[str(t_issue)] = {
                "veredicto": verdict,
                "motivo": str(entry.get("motivo", "") or "")[:200],
                "at": t_at,
            }
            if verdict == "soltar" and t_issue != int(view.get("issue", 0) or 0):
                dropped = list(view.get("skipped", []))
                if t_issue not in dropped:
                    dropped.append(t_issue)
                    view["skipped"] = dropped
    # The summary of THIS turn is fresher than the files: it is applied last.
    for t_issue, verdict, motivo in triage_from_summary(summary):
        triage_state[str(t_issue)] = {
            "veredicto": verdict,
            "motivo": motivo[:200],
            "at": now,
        }
        if verdict == "soltar" and t_issue != int(view.get("issue", 0) or 0):
            dropped = list(view.get("skipped", []))
            if t_issue not in dropped:
                dropped.append(t_issue)
                view["skipped"] = dropped
                note(f"triage: issue #{t_issue} is dropped "
                     f"({motivo or 'no reason given'})")
    while len(triage_state) > 20:
        oldest = sorted(triage_state, key=lambda k: triage_state[k].get("at", 0))[0]
        triage_state.pop(oldest, None)

    view["published"] = published

    # a publication without an approved review is a rule violation: it is
    # counted (the quota has to be honest) but it does not pass unnoticed.
    if phase == "published" and view.get("review") != "aprobado":
        note(f"WARNING: pr #{pr} was published without an approved review "
             f"(review={view.get('review')!r}): the review is not a formality")

    # counters
    counters = view["counters"]
    counters["iterations"] = int(counters.get("iterations", 0)) + 1
    if phase == "failed":
        counters["failures"] = int(counters.get("failures", 0)) + 1
        counters["consecutive"] = int(counters.get("consecutive", 0)) + 1
    else:
        counters["consecutive"] = 0

    # our PRs and the mode (what decides maintenance)
    prs = refresh_prs(cfg)
    if prs is not None:
        view["prs"] = prs
    # The retired PRs (duplicates of other authors, see config.env) do not
    # count: they are not ours to merge and the loop does not work on them.
    retired = {p.strip() for p in str(cfg.get("RETIRED_PRS", "") or "").split(",") if p.strip()}
    open_unmerged = len([p for p in (view.get("prs", {}) or {}) if str(p) not in retired])
    maint = as_int(cfg, "MAINT_THRESHOLD", 5)
    # ALLOW_NEW_PRS=0 keeps the loop in maintenance whatever the PR count is:
    # while upstream's CI sits in `action_required` for every PR we open
    # (GitHub's first-time-contributor policy), another PR is another blocked
    # run. Only a human re-enables it.
    allow_new = str(cfg.get("ALLOW_NEW_PRS", "1")).strip().lower() not in ("0", "false", "no")
    if allow_new and open_unmerged >= maint:
        view["mode"] = "maintenance"
    elif not allow_new:
        view["mode"] = "maintenance"
    else:
        view["mode"] = "normal"
    view["allow_new_prs"] = allow_new
    view["open_unmerged"] = open_unmerged

    # --- the daily report ------------------------------------------------
    # The model COMPOSES the report; the supervisor publishes it. The rule
    # "once per day" belongs to the supervisor: the model cannot post twice,
    # and a missing report is retried on the next turn.
    report = view.setdefault("report", {"last": "", "issue": 0, "pending": True})
    issue_num, slug = ensure_report_issue(cfg, view)
    # The report is due when the day changed OR when the day's countable work
    # changed (a PR published, an issue dropped, an approval asked). The
    # comment of the day is UPDATED, so the log stays current instead of
    # freezing at the first turn of the morning.
    sig = f"{sum(len(v) for v in (view.get('published') or {}).values())}:" \
          f"{len(view.get('skipped') or [])}:{len(view.get('approval_asked') or {})}"
    was_pending = bool(report.get("pending"))
    if report_text and (was_pending or report.get("sig") != sig):
        ok, cid = post_report(slug, issue_num, report_text,
                              int(report.get("comment_id") or 0))
        # a local copy always, even if GitHub refused it
        try:
            reports_dir = a.reports_dir or os.path.join(
                os.path.dirname(os.path.abspath(a.ledger)), "reports")
            os.makedirs(reports_dir, exist_ok=True)
            with open(os.path.join(reports_dir, f"{today}.md"), "w",
                      encoding="utf-8") as fh:
                fh.write(report_text.rstrip() + "\n")
        except OSError as exc:
            print(f"could not save the local report: {exc}", file=sys.stderr)
        if ok:
            report["last"] = today
            report["pending"] = False
            report["sig"] = sig
            report["comment_id"] = cid
            print(f"daily report posted: {slug}#{issue_num} (comment {cid})",
                  file=sys.stderr)
        else:
            report["pending"] = True
            print("the daily report could not be posted: it stays pending",
                  file=sys.stderr)
    elif was_pending and not report_text:
        print("the daily report was due but the turn did not compose it: still pending",
              file=sys.stderr)
    report["pending"] = (report.get("last") != today) or (report.get("sig") != sig)
    view["report"] = report

    # --- 3. the state is written ------------------------------------------
    # The view of THIS slot goes into `slots[S]` and the globals stay at the
    # top level: the slots of the others are NOT touched.
    store_slot(state, slot_id, view)
    state["gate"] = live
    write_legacy_mirror(state)
    state["version"] = version_read + 1
    write_atomic(a.state, state)

    # --- 1c. the verdict of the review worker, collected at the end -------
    # The worker may have finished after the delta was composed (the turn
    # did not wait for it), or the turn may have died before collecting it.
    # The log of THIS turn is read one more time and the verdict is kept in
    # the state: otherwise it is lost, and recovering it costs a whole gate.
    if collect_review_verdict(view, a.turn_log, cfg):
        # the verdict that arrives late is checked too: a verdict about the
        # code of another slot is not a verdict about this one.
        refuse_review_of_another_slot(state, slot_id, view)
        store_slot(state, slot_id, view)
        write_legacy_mirror(state)
        state["version"] = int(state.get("version") or 0) + 1
        write_atomic(a.state, state)

    # --- 4. the ledger is written by the supervisor ----------------------
    # The append is under a lock: a line can be longer than PIPE_BUF and two
    # slots appending at the same time would split it in the middle.
    append_ledger(a.ledger, ledger_line(view, summary, cfg))

    # --- 5. the view of the slot, for the model --------------------------
    # The model does not read state.json: it reads the view of its slot.
    view_path = a.slot_view or os.path.join(loop_dir, "state",
                                             f"slot-{slot_id}.json")
    try:
        write_slot_view(view_path, state, slot_id)
    except OSError as exc:
        print(f"could not write the view of the slot: {exc}", file=sys.stderr)

    print(f"phase={phase} issue={issue} pr={pr} mode={view['mode']} "
          f"slot={slot_id} iters={counters['iterations']} "
          f"open_prs={open_unmerged} review={view.get('review', '')!r}")
    return 0


if __name__ == "__main__":
    # the exit code says whether the turn did its job: 1 when the state was
    # NOT written (the lock of the state was busy), so the supervisor knows
    # that the delta of this turn is lost.
    sys.exit(main())
