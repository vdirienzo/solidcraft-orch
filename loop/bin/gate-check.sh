#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# DETERMINISTIC gate verdict: green or red, comparing the log against
# baseline-failures.txt.
#
#   gate-check.sh [--slot <slot>] <gate-log-path>
#
# Why a script and not the model: "green" is a mechanical rule (the only
# failures are the ones in the baseline). If the model judges it, a tired turn
# judges it wrong and the loop publishes with new failures. Here the code
# applies the rule; the sc-gate agent only reports it.
#
# THE SLOT: a gate belongs to a slot (its worktree) and every slot has its
# own files under $LOOP_DIR/gates/<slot>/: pid, sha, verdict, log. With
# `--slot <slot>` the log is taken from the slot (gates/<slot>/log) when no
# path is given, and the verdict is written to gates/<slot>/verdict. Without
# `--slot` the script works on the DEFAULT slot: it prints the verdict (as it
# always did) and leaves it in $LOOP_DIR/gate.verdict, the file the loop
# reads today.
#
# A VERDICT GOES TO THE SLOT THAT GATED ITS LOG. The log of a slot is
# recorded in the slot's own `log` file, so the script can tell whose log it
# is judging: the verdict is written in the file of that slot, never in the
# file of another one (a verdict of slot 1 read as the verdict of slot 0
# could publish the wrong PR). The verdict file carries the slot and the
# sha it is about, so a reader never has to guess.
#
# THE VERDICT BELONGS TO THE SHA, NOT TO THE FILE. The log is ROTATED, never
# truncated: start-gate.sh keeps the log of the previous run of the same sha
# in <log>.1 and the new run writes a clean <log>. So when the log of the run
# that is going on has no EXIT= yet, the verdict of the last COMPLETED run
# (the rotated one) is the verdict of that sha: relaunching a gate does not
# erase the verdict the loop already had (2026-10-24: PR #5835 went green,
# was relaunched, and the loop published the same PR thirteen times).
#
# A log without EXIT= whose mtime is older than GATE_TIMEOUT_MIN is a DEAD
# run (the gate was killed, the machine went down): it is not "running" and
# it will never say anything.
#
# Output (stdout, key=value plus the list of new failures):
#   GATE_STATUS=running|finished|missing|dead
#   EXIT_CODE=0|101|<n>|unknown
#   VERDICT=VERDE|ROJO|PENDIENTE
#   NEW_FAILURES=<n>
#   FALLBACK_CRATES=<n>      (tests whose crate was a fallback)
#   --- new failures ---
#   <crate>::<test>
#
# With `--emit-baseline` it prints the log's failures in the
# baseline-failures.txt format (one per line, `crate::test`) instead. That is
# what `regen-baseline.sh` uses to regenerate the list from the COMPLETE
# baseline log (not from a partial one: an incomplete list means the gate can
# never be green). In that mode no verdict file is written.
#
# The comparison is by TEST NAME, not by line number nor by panic text. The
# crate is deduced from the panic path (`crates/geom/src/...` -> `geom`), so
# two crates with a homonymous test are not confused.
#
# The crate of EACH test is deduced from ITS OWN panic: a test binary can
# fail in two different crates (a test of `crates/io` that panics inside
# `crates/kernel`), and the crate of the last panic seen would put both in
# the same crate. If a test has no panic with a path (it should not happen),
# the crate of its test binary is used instead and the fallback is marked
# (a warning on stderr and FALLBACK_CRATES in the output).
# ---------------------------------------------------------------------------
set -uo pipefail

LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"

# The directory of this script: the checker of the configuration
# (bin/config-preflight.sh) lives next to it and it is called by path,
# never by a guess.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATES_DIR="$LOOP_DIR/gates"
MODE="verdict"
SLOT=""
LOG=""
POSITIONAL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --emit-baseline) MODE="baseline"; shift ;;
    --slot)
      if [ $# -lt 2 ]; then echo "--slot needs a name" >&2; exit 2; fi
      SLOT="$2"; shift 2 ;;
    --slot=*) SLOT="${1#--slot=}"; shift ;;
    -h|--help)
      echo "usage: gate-check.sh [--slot <slot>] [--emit-baseline] <gate-log-path>" >&2
      exit 2 ;;
    --*) echo "unknown option: $1" >&2; exit 2 ;;
    *)
      if [ "$POSITIONAL" -eq 0 ]; then
        LOG="$1"
        POSITIONAL=1
      else
        echo "too many arguments" >&2
        exit 2
      fi
      shift ;;
  esac
done

BASELINE="${BASELINE_FAILURES:-$LOOP_DIR/baseline-failures.txt}"

# The age after which a log without EXIT= is a DEAD run and not a running
# one: the same limit the supervisor's watchdog uses (GATE_TIMEOUT_MIN), so
# both agree on what "stuck" means. It comes from the environment when the
# supervisor exports it, and from config.env otherwise.
GATE_TIMEOUT_MIN="${GATE_TIMEOUT_MIN:-}"
# The configuration is CHECKED before it is read: a value with spaces and
# no quotes breaks the source of the config.env in the middle of the file,
# so the variable is never set and the script goes on with HALF of the
# policy, in silence (set -e is not on). The check only READS the file: it
# is read twice and sourced once. If the config.env is broken, the script
# STOPS here instead of running with half of the policy.
if [ -r "$LOOP_DIR/config.env" ]; then
  if [ -x "$SCRIPT_DIR/config-preflight.sh" ]; then
    bash "$SCRIPT_DIR/config-preflight.sh" "$LOOP_DIR/config.env" || exit 2
  elif ! bash -n "$LOOP_DIR/config.env" >/dev/null 2>&1; then
    echo "gate-check: the config.env has a syntax error: $LOOP_DIR/config.env" >&2
    exit 2
  fi
fi

if [ -z "$GATE_TIMEOUT_MIN" ] && [ -r "$LOOP_DIR/config.env" ]; then
  GATE_TIMEOUT_MIN="$(sed -n 's/^GATE_TIMEOUT_MIN=\([0-9][0-9]*\).*/\1/p' \
    "$LOOP_DIR/config.env" 2>/dev/null | head -1)"
fi
case "$GATE_TIMEOUT_MIN" in ''|*[!0-9]*) GATE_TIMEOUT_MIN=90;; esac

# --- the slot -------------------------------------------------------------
# The name of a slot is a FILE NAME: it has to be safe inside a path. Lower
# case, [a-z0-9._-] only, no "..", not empty, not hidden. When the name
# cannot be normalized the script ABORTS: it never invents a name (a name
# that is not the slot's would read the verdict of another slot).
normalize_slot() {
  local raw="$1" out
  out="$(printf '%s' "$raw" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '-' | cut -c1-60)"
  case "$out" in
    ""|.|..) return 1 ;;
    *..*) return 1 ;;
    .*|-*) return 1 ;;
  esac
  printf '%s' "$out"
}

if [ -n "$SLOT" ]; then
  SLOT_NAME="$(normalize_slot "$SLOT")" || {
    echo "the slot name is not usable: $SLOT" >&2
    exit 2
  }
else
  SLOT_NAME="default"
fi

# The slot that owns a log: the slot that recorded that log path in its own
# `log` file. The verdict of a log belongs to the slot that gated it: a
# verdict written in the file of another slot is read as the verdict of that
# slot, and it can publish the wrong PR.
slot_of_log() {
  local path="$1" dir slot recorded
  for dir in "$GATES_DIR"/*/; do
    [ -d "$dir" ] || continue
    slot="$(basename "$dir")"
    [ -r "$dir/log" ] || continue
    recorded="$(head -1 "$dir/log" 2>/dev/null | tr -d '\r\n')"
    if [ -n "$recorded" ] && [ "$recorded" = "$path" ]; then
      printf '%s' "$slot"
      return 0
    fi
  done
  return 1
}

# The log of the slot (when no path is given).
if [ -z "$LOG" ] && [ "$SLOT_NAME" != "default" ]; then
  if [ -r "$GATES_DIR/$SLOT_NAME/log" ]; then
    LOG="$(head -1 "$GATES_DIR/$SLOT_NAME/log" 2>/dev/null | tr -d '\r\n')"
  fi
fi

# The slot the verdict is written for. It is the owner of the log when the
# log says who gated it, and the slot of the caller otherwise.
VERDICT_SLOT="$SLOT_NAME"
if [ -n "$LOG" ] && { [ -f "$LOG" ] || [ -f "$LOG.1" ]; }; then
  if owner="$(slot_of_log "$LOG")"; then
    VERDICT_SLOT="$owner"
    if [ "$owner" != "$SLOT_NAME" ]; then
      echo "the log $LOG belongs to the slot $owner, not to $SLOT_NAME:" \
        "its verdict goes to gates/$owner/verdict" >&2
    fi
  fi
fi

if [ "$VERDICT_SLOT" = "default" ]; then
  # The default slot keeps the file the loop reads today.
  VERDICT_FILE="$LOOP_DIR/gate.verdict"
  MIRROR_VERDICT="$GATES_DIR/default/verdict"
else
  VERDICT_FILE="$GATES_DIR/$VERDICT_SLOT/verdict"
  MIRROR_VERDICT=""
fi

# The sha the verdict is about: the one the slot gated. It is written with
# the verdict so a reader can tell whose commit it talks about without
# having to look at another file (a verdict of another sha is not a verdict
# of this one).
VERDICT_SHA=""
for sha_source in "$GATES_DIR/$VERDICT_SLOT/sha" "$LOOP_DIR/gate.sha"; do
  [ -r "$sha_source" ] || continue
  VERDICT_SHA="$(head -1 "$sha_source" 2>/dev/null | tr -d '\r\n')"
  [ -n "$VERDICT_SHA" ] && break
done

# The log of the run that is going on AND the rotated log of the previous run
# of the same sha (<log>.1): the verdict of a sha can come from the rotated
# one, so a log that is not there yet is not a missing verdict.
if [ -z "$LOG" ] || { [ ! -f "$LOG" ] && [ ! -f "$LOG.1" ]; }; then
  MISSING_BLOCK="GATE_STATUS=missing
EXIT_CODE=unknown
VERDICT=PENDIENTE
NEW_FAILURES=0
FALLBACK_CRATES=0"
  printf '%s\n' "$MISSING_BLOCK"
  # The default slot keeps today's behaviour: the file the loop reads is not
  # touched when there is no log (the supervisor only writes it with a log).
  # The other slots have no such legacy: their own verdict file says
  # "pending" until their gate writes a log.
  if [ "$MODE" = "verdict" ] && [ "$VERDICT_SLOT" != "default" ] && [ -n "$VERDICT_FILE" ]; then
    if { echo "GATE_SLOT=$VERDICT_SLOT"; echo "GATE_LOG=";
      printf '%s\n' "$MISSING_BLOCK"; } > "$VERDICT_FILE.tmp"; then
      mv -f "$VERDICT_FILE.tmp" "$VERDICT_FILE"
    else
      rm -f "$VERDICT_FILE.tmp" 2>/dev/null || true
    fi
  fi
  exit 0
fi

OUT="$(python3 - "$LOG" "$BASELINE" "$MODE" "$GATE_TIMEOUT_MIN" <<'PY'
import os, re, sys, time

log_path, baseline_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    timeout_min = int(sys.argv[4])
except (IndexError, ValueError):
    timeout_min = 90

def read_log(path):
    """The text of a log (None when it cannot be read)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def completed_run(text):
    """The LAST COMPLETED run of a log: its exit code, its section, and
    whether another run started after it.

    Only the LAST run in the file counts. A log used to be shared by every run
    of the same issue (and opened in append mode), so the previous run's EXIT=
    was still in the file: while the new gate was running, this script read the
    OLD "EXIT=0" and said "green" (the loop could publish code that was never
    gated), and a run that had failed left the file red for good.
    """
    found = list(re.finditer(r"^EXIT=(\d+)\s*$", text, re.M))
    if not found:
        return None
    last = found[-1]
    after = text[last.end():]
    # Anything after the last EXIT= that looks like a fresh run means the gate
    # is running again: the verdict is PENDIENTE, not the old run's.
    new_run = bool(re.search(
        r"^\$ cargo |^running \d+ tests|^\s*Compiling |^\s*Finished `", after, re.M))
    # the analysed section is the LAST COMPLETED run
    cut = found[-2].end() if len(found) > 1 else 0
    return {"exit": last.group(1), "section": text[cut:last.end()],
            "new_run": new_run}


log = read_log(log_path)
# The ROTATED log: start-gate.sh rotates the log of the previous run of the
# same sha into <log>.1, so the verdict of a run that already finished is not
# erased by the next one.
rotated = read_log(log_path + ".1")

if log is None and rotated is None:
    print("GATE_STATUS=missing")
    print("EXIT_CODE=unknown")
    print("VERDICT=PENDIENTE")
    print("NEW_FAILURES=0")
    print("FALLBACK_CRATES=0")
    sys.exit(0)

current_exists = log is not None
run = completed_run(log) if current_exists else None
prev = completed_run(rotated) if rotated is not None else None

# A log without EXIT= whose mtime is older than the timeout is a DEAD run:
# the gate was killed or the machine went down. The mtime is the right clock
# because cargo keeps writing to the log while it works.
dead = False
if current_exists:
    try:
        dead = (time.time() - os.path.getmtime(log_path)) > timeout_min * 60
    except OSError:
        dead = False

exit_code = "unknown"
judged = False
if run is not None:
    exit_code = run["exit"]
    log = run["section"]
    judged = not run["new_run"]
    status = "running" if run["new_run"] else "finished"
elif prev is not None:
    # The run that is going on has no EXIT= yet and the rotated log holds the
    # last COMPLETED run of this sha: the verdict of that run IS the verdict
    # of the sha (the path of the log carries it). The sha is GATED, so the
    # status is "finished" even when the new run is still writing: the answer
    # of this sha is already known.
    exit_code = prev["exit"]
    log = prev["section"]
    judged = True
    status = "finished"
else:
    log = log or ""
    status = "missing" if not current_exists else ("dead" if dead else "running")

# A run CUT by the timeout of the gate is not a red run. The timeout kills
# the runner (exit code 124) or the runner is killed (exit code 137) and the
# tests that were running die with it: the log then says "SIGTERM" and
# "1 failed", and a parser that does not know about the cut reads a FAIL
# that never happened. The cut is a POSTPONEMENT of the scope, not a
# failure of the change: nothing is known about it, so nothing is red.
run_cut = exit_code in ("124", "137")

# --- the failures in the log --------------------------------------------
# Two runners write two different logs, and the gate reads both:
#
#   libtest: the xtask runs every test binary and prints a summary line
#     per binary ("ok    geom lib solidcraft_geom  1.2s  ok. 5 passed"),
#     and the failures of a binary come as a block of names ("failures:"
#     and one indented name per line) below the output of the binary.
#
#   nextest: one PROCESS per test (the runner of the upstream CI), and it
#     prints a line per test:
#     "        FAIL [   0.029s] (3/3) solidcraft-kernel boolean_props::scale_invariant"
#     followed by the output of the failed test.
#
# The crate of every test comes from ITS OWN panic. The path of the file
# that panicked names the directory of its package, which is the name the
# xtask uses in its summary lines and the name the baseline uses. The
# summary line of the test binary ("FAIL  geom lib solidcraft_geom") gives
# the crate of the binary, which is only the fallback for a test without a
# panic path.
crate_from_path = re.compile(r"(?:crates|apps)/([A-Za-z0-9_.-]+)/")
binary_line = re.compile(r"^\s*(?:ok|FAIL)\s+(\S+)\s+(?:lib|test|bin)\s+\S+")
stdout_header = re.compile(r"^----\s+(.+?)\s+stdout\s+----\s*$")
# nextest: the status of a test, with the test target and the name of the
# test inside it. A test that died without failing is a failure too.
nextest_status = re.compile(
    r"^\s*(?:FAIL|SIGSEGV|ABORT|SIGABRT|TIMEOUT)\s+\[\s*[\d.]+s\]\s*"
    r"(?:\(\s*\d+/\d+\s*\)\s+)?(\S+)\s+(\S+)\s*$", re.M)
# The counter of nextest is PADDED to the width of the total when the run has
# four digits: "( 204/6361)", not "(204/6361)". The regex has to accept the
# spaces on both sides of the counter, or the parser finds NO failure in a log
# that has failures: the gate then says "the run failed and no test failure was
# found", counts one problem and every pull request of ours comes out red for a
# failure that is in the baseline (measured on 14-11-2026: 152 of the 364
# failure lines of the logs of the loop had the padded counter and were
# invisible to the parser).
# nextest: a test that was KILLED when the run was cut (the timeout of the
# gate fired and the runner killed the test that was running). A SIGTERM is
# NOT a failure of the test: it is the cut of the run. It only counts as a
# failure when the run was NOT cut (a test that died on its own is a failure,
# whatever its signal is).
nextest_killed = re.compile(
    r"^\s*(?:SIGTERM|SIGKILL)\s+\[\s*[\d.]+s\]\s*"
    r"(?:\(\s*\d+/\d+\s*\)\s+)?(\S+)\s+(\S+)\s*$", re.M)
# the colours of nextest and of cargo
ansi = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# nextest names a test target after the PACKAGE ("solidcraft-kernel") and
# the baseline names the crate after the DIRECTORY of the package
# ("kernel"). The rule holds for every crate but the apps, whose directory
# keeps the whole name.
APP_CRATES = {
    "solidcraft": "solidcraft",
    "solidcraft-cli": "solidcraft-cli",
    "solidcraft-web": "solidcraft-web",
    "solidcraft-3dx-client": "threedx-client",
}

def crate_of_binary(binary):
    """The crate of a nextest test target."""
    if binary in APP_CRATES:
        return APP_CRATES[binary]
    if binary.startswith("solidcraft-"):
        return binary[len("solidcraft-"):]
    return binary

def panic_crates_of(text):
    """The crate of every test that panicked, by the path of its panic."""
    crates = {}
    for line in text.splitlines():
        mt = re.search(r"thread '([^']+)'.*panicked at ([^\s:]+)", line)
        if not mt:
            continue
        mc = crate_from_path.search(mt.group(2))
        if mc:
            crates[mt.group(1)] = mc.group(1)
    return crates

def crate_of(name, crates):
    """The crate of a test: its own panic, or the one of its path suffix.

    A test whose name is not the name of its panic (a thread with a name of
    its own) is looked up by the suffix of the path.
    """
    if name in crates:
        return crates[name]
    for key, crate in crates.items():
        if key.endswith("::" + name) or name.endswith("::" + key):
            return crate
    return None

def libtest_failures(text):
    """The failed tests of a libtest log: (crate, test, fallback?)."""
    crates = {}         # test name -> crate (from its own panic)
    bin_crate = None    # the crate of the test binary being read
    cur_header = None   # the "---- <test> stdout ----" section being read
    names = []          # (test name, the crate of its binary), in order
    in_names = False

    for line in text.splitlines():
        # The summary line of a binary comes BEFORE its output (xtask prints
        # it when the test command finishes and the output of the binary
        # follows).
        mb = binary_line.match(line)
        if mb:
            bin_crate = mb.group(1)
            cur_header = None
            continue

        # a new test starts: the section of the previous one is over
        if re.match(r"^(test .*\.\.\.|test result:|running \d+ tests)", line):
            cur_header = None
            continue

        # "---- <test> stdout ----" (the section of a failed test)
        mh = stdout_header.match(line)
        if mh:
            cur_header = mh.group(1)
            continue

        # "thread '<name>' (<tid>) panicked at crates/<crate>/src/....rs:190:5:"
        mt = re.search(r"thread '([^']+)'.*panicked at ([^\s:]+)", line)
        if mt:
            mc = crate_from_path.search(mt.group(2))
            if mc:
                # the thread of the panic, and the test whose output it is
                crates[mt.group(1)] = mc.group(1)
                if cur_header:
                    crates.setdefault(cur_header, mc.group(1))
            continue

        # The names block: "failures:" followed by lines indented with 4 spaces
        if line.strip() == "failures:":
            in_names = True
            continue
        if in_names:
            if not line.strip():
                # a blank line ends the names block
                in_names = False
                continue
            mname = re.match(r"^    ([A-Za-z0-9_][A-Za-z0-9_:<>]*)\s*$", line)
            if mname:
                names.append((mname.group(1), bin_crate))
                continue
            in_names = False

    out = []
    for name, binary_crate in names:
        crate = crate_of(name, crates)
        if crate is None:
            # the panic of THIS test was not found: the crate of the binary
            # is used, and the fallback is marked
            out.append((binary_crate, name, True))
        else:
            out.append((crate, name, False))
    return out

def nextest_failures(text, cut=False):
    """The failed tests of a nextest log: (crate, test, fallback?).

    When the run was CUT, the tests that were killed are not failures: they
    are the cut. When it was not cut, a killed test IS a failure: a test
    that died on its own (SIGTERM of a panic, a kill of the OOM killer) is
    a failure of the change, whatever its signal is.
    """
    crates = panic_crates_of(text)
    out = []
    for line in text.splitlines():
        m = nextest_status.match(line)
        if not m and not cut:
            m = nextest_killed.match(line)
        if not m:
            continue
        binary, name = m.group(1), m.group(2)
        crate = crate_of(name, crates)
        if crate is None:
            out.append((crate_of_binary(binary), name, True))
        else:
            out.append((crate, name, False))
    return out

# The colours go: they are decoration, and they hide the words the parser
# looks for.
text = ansi.sub("", log)
if nextest_status.search(text) or nextest_killed.search(text):
    failures = nextest_failures(text, run_cut)
else:
    failures = libtest_failures(text)

# Deduplicate, keeping the order
seen = set()
uniq = []
for c, n, fb in failures:
    if (c, n) in seen:
        continue
    seen.add((c, n))
    uniq.append((c, n, fb))

fallbacks = [(c, n) for (c, n, fb) in uniq if fb]
for c, n in fallbacks:
    print(f"WARNING: the crate of '{n}' could not be deduced from its panic: "
          f"the crate of the test binary ({c or 'unknown'}) is used instead",
          file=sys.stderr)

# Baseline mode: print the log's failures in the list's format.
if mode == "baseline":
    for c, n, fb in uniq:
        print(f"{c}::{n}" if c else n)
    sys.exit(0)

# --- baseline -----------------------------------------------------------
baseline = set()
baseline_names = set()
try:
    with open(baseline_path, encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw or raw.startswith("#"):
                continue
            entry = raw.split("#", 1)[0].strip()
            if not entry:
                continue
            baseline.add(entry)
            # the name without the crate prefix, to compare tolerantly
            baseline_names.add(entry.split("::", 1)[1] if "::" in entry else entry)
except OSError:
    pass

def known(crate, name):
    if crate and f"{crate}::{name}" in baseline:
        return True
    # the crate could not be deduced (panic without a crates/ path): compare
    # by name alone
    return name in baseline_names

new_failures = [(c, n) for (c, n, fb) in uniq if not known(c, n)]

print(f"GATE_STATUS={status}")
print(f"EXIT_CODE={exit_code}")
print(f"RUN_CUT={'true' if run_cut else 'false'}")
print(f"FALLBACK_CRATES={len(fallbacks)}")
if not judged:
    # A run that is still going says nothing about the run before it: the loop
    # has to wait, not "fix" the failures of the previous run.
    print("VERDICT=PENDIENTE")
    print("NEW_FAILURES=0")
    sys.exit(0)

if run_cut:
    # The run was cut by the timeout of the gate. The failures that the log
    # names are REAL failures (a test that failed before the cut) and they
    # are red: the cut does not hide them. But the cut itself is NOT a
    # failure: the scope was POSTPONED, not judged, and the agent must not
    # go and fix tests that pass.
    if new_failures:
        print("VERDICT=ROJO")
        print(f"NEW_FAILURES={len(new_failures)}")
        print("--- new failures ---")
        for c, n in new_failures:
            print(f"{c}::{n}" if c else n)
    else:
        print("VERDICT=SKIP")
        print("NEW_FAILURES=0")
        print("GATE_ERROR=the run was cut by the timeout of the gate: "
              "the scope is deferred, not red")
elif exit_code == "0" and not new_failures:
    print("VERDICT=VERDE")
    print("NEW_FAILURES=0")
elif not new_failures and uniq:
    # EXIT != 0 but every failure is in the baseline -> green
    print("VERDICT=VERDE")
    print("NEW_FAILURES=0")
elif not new_failures:
    # EXIT != 0 and NO failure at all was found in the log: the run failed
    # for a reason that is not a test failure (a compile error, a runner
    # that did not start, a check of the gate that failed). It is NOT
    # green: a step that did not run is not a pass.
    print("VERDICT=ROJO")
    print("NEW_FAILURES=0")
    print("GATE_ERROR=the run failed and no test failure was found in the log")
else:
    print("VERDICT=ROJO")
    print(f"NEW_FAILURES={len(new_failures)}")
    print("--- new failures ---")
    for c, n in new_failures:
        print(f"{c}::{n}" if c else n)
PY
)"
PY_STATUS=$?

# A failure of the analysis is a failure of the script: nothing is printed
# and the exit code says so (the caller keeps its previous verdict).
if [ "$PY_STATUS" -ne 0 ]; then
  exit "$PY_STATUS"
fi

printf '%s\n' "$OUT"

# The verdict of the slot, left where its reader looks for it. The default
# slot keeps the file the loop reads today ($LOOP_DIR/gate.verdict); the
# other slots have their own (gates/<slot>/verdict). The format is the one
# of the supervisor: the log it is about, then the key=value lines.
#
# The slot and the sha go with it: the verdict of a slot says whose it is
# and which commit it is about, so a reader never has to guess (and never
# takes the verdict of another slot for its own).
if [ "$MODE" = "verdict" ] && [ -n "$VERDICT_FILE" ]; then
  VERDICT_TMP="$VERDICT_FILE.tmp"
  if { echo "GATE_SLOT=$VERDICT_SLOT"; echo "GATE_SHA=$VERDICT_SHA";
    echo "GATE_LOG=$LOG"; printf '%s\n' "$OUT"; } > "$VERDICT_TMP"; then
    mv -f "$VERDICT_TMP" "$VERDICT_FILE"
    if [ -n "$MIRROR_VERDICT" ]; then
      mkdir -p "$(dirname "$MIRROR_VERDICT")" 2>/dev/null || true
      cp -f "$VERDICT_FILE" "$MIRROR_VERDICT" 2>/dev/null || true
    fi
  else
    rm -f "$VERDICT_TMP" 2>/dev/null || true
  fi
fi
