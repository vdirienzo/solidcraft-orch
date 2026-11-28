# Known traps: read before you implement

Each of these has cost a cycle. Check them before dispatching an agent or writing a fix.

## Visibility caches cannot be keyed on `revision` alone
`Session::joint_visible` style lookups cannot be keyed on `revision` alone —
`app.session.visibility` is replaced wholesale without touching revision
(crates/ui-egui/src/control.rs), and the engine replaces it on undo/restore. Mirror the
existing `VisibilityCache` pattern, which compares CONTENT.

## A rejected predecessor PR is a constraint, not a footnote
Before implementing an issue, look for a CLOSED PR on it and read why the maintainer closed
it. A fix that makes a behaviour COARSER BY DEFAULT gets closed again — the maintainer's
objection is to the default, not to the idea — and the rejected PR usually names the TESTS
whose coordinates fit the old behaviour, which the new fix must keep green. Hand the
constraint and the named tests to the agent; do not let it rediscover them.

## The plan of record lives in the tracking issue
When an issue is PART of a tracking issue, the tracking issue states the maintainer's plan
(and its cost, e.g. "this alters about half the names in saved designs"). A fix that takes a
DIFFERENT approach must say so explicitly in the PR body and must not close the tracking
issue. Claiming the tracking issue's checklist item with another approach is the fastest way
to get a PR closed.

## A pending file that upstream already FOLDED breaks the build
The repo delivers locale strings and format changes through `pending/` files, and a bot
upstream folds them into the published files and DELETES them. So a branch that carries a
pending file upstream has already folded is a branch whose build fails: the build script
inserts the pending entries into the published catalogue and errors the moment a key is
already there ("`<id>` is already in <locale>.json (or another pending file)").

Two ways to end up in that state, and they look different but are the same bug:
- the working tree holds the published catalogue from AFTER the fold and the pending file
  from BEFORE it, so the same key is in both;
- a branch rebased onto a main that folded the file still carries the pending file.

The check before assuming a build is broken: for the key the error names, look for it in
the published catalogue AND in every pending file, and compare with the same lookup on
`origin/main`. If upstream has only the published one, the pending file is the stale half
and it has to go. It is a one-line deletion that unblocks a whole crate, and the build
error names the file so the diagnosis is cheap once you know the rule.

The same shape governs `crates/doc/src/format/pending/`: one file per change to what a
design file saves, and never an edit to `FORMAT` or to another change's file. A pending
file that is not in the upstream diff is work in flight, not drift: rescue it before any
reset of the main checkout.

## A pending locale file needs EVERY complete locale, not only English
A new UI string goes in `assets/locales/pending/<name>.json`, and the README of that folder
says a locale you leave out falls back to English. That is true of the INCOMPLETE locales
and false of the COMPLETE ones: the guard that checks the catalogues
(`every_complete_catalog_carries_every_english_message`, in the ui-egui crate) demands that
every complete catalogue carry every English message, so a pending file that only has `en`
fails the build over a missing message. Give the string in every complete locale of the repo
and read the guard for the authoritative list of which those are.

## The pull request body is judged by the UPSTREAM parser, and a body edit does not re-run the CI
The upstream check has its own parser (`scripts/pr-checks/pr-checks.js`); it accepts
`Changes a default:` and NOTHING else (`Changes to default:` is refused), and the value after it
has to be `no` or a `yes - <what>, old behaviour kept behind preference <name>`. Read that
parser instead of writing a local grep: a local check that accepts more than the authority is
worse than no check, because it hands out a false green, and the CI kills the pull request
after it is already published.

**What the parser accepts today (it changed on 2026-11-27; read the file, do not guess):**

- the value `no`, alone or with a note after it: `no`, `no.`, `no. Only a fix.`, `no, only a
  fix`, `no — a new button`, `no (only a fix)`;
- the value `yes`, with ANY punctuation before what changes: `yes, …`, `yes. …`, `yes — …`;
- the long `yes - <what>, old behaviour kept behind preference <name>`;
- the long `yes - <what>, approved by the owner` (it needs the `owner-approved` label, and with
  that label ANY `yes` passes);
- a value between backticks: `` `no` `` is read as `no`;
- the HEADING form: `## Changes a default` with the value on the first non-blank line under it
  (the line form and the heading form are both declarations; a body carries one).

A local copy of those rules is a rule that drifts: the copy here was stricter than the upstream
and rejected bodies the upstream accepts. `bin/pipeline.py` and `loop/bin/pr-defaults-line.sh`
CALL the upstream's parser; read the file before writing a check of your own.

**Editing the body does NOT re-trigger the checks.** The checks that read the body run when
the CI runs, and the CI runs on a push — so a body corrected after the fact leaves the pull
request with a red check until the next push. Validate the body with the upstream's own
parser BEFORE publishing, not after.

## A reference is not a closing phrase, and the difference is the point
GitHub closes an issue only when the body says `close`, `fix` or `resolve`. `Addresses #N`
leaves it OPEN on purpose, which is what a partial fix owes a tracking issue whose plan of
record lives upstream. A verifier that demands a closing verb rejects the correct body and
lets the wrong one through: accept a reference (addresses, refs, see, part of, related to) as
a valid mention, and count closing phrases separately from mentions so that a body cannot
close more issues than it names.

## The gate has to compile like the upstream CI, features included
A scoped build that does not include the CLI compiles the kernel WITHOUT its native
geometry library, because that feature is on by default in the CLI's manifest and
only reaches the kernel through it. Every geometric test then fails with the
message that says the build has no native library: a gate comes out red with
thousands of failures that are not failures. The upstream CI builds the whole
workspace, so it always has the feature, and that is why its catalogue of known
failing tests lists a few dozen and not thousands.

**Before believing a red gate, ask how the code was COMPILED, not only what it
tests.** The rule and the fix (the gate has to add the CLI to its scope, and the
upstream's own list of known failing tests is the authority on what is
pre-existing) are in the `solidcraft-orchestrator-gate` skill, which owns the gate.

## A suite that outlives the code cell dies with the kernel and takes its state
The code cell has a wall-clock limit of about five minutes, and when it expires the
kernel is killed and every variable it held is lost. A test suite that takes longer
has to run as a BACKGROUND PROCESS (a terminal call with notification) and be read
from its log afterwards, not inside the cell: run it in the cell and the cell
returns nothing, loses the values you were accumulating, and the suite still has to
be run again.

## Do not dispatch new features: only issues (measured, 2026-11-03)
132 agents were measured. The 20 working on features read **42.4 lines per line written**; the 112
working on issues read **25.1**. 35 of the 132 wrote nothing at all, and the worst one (1005 reads,
0 writes) was a feature. All 97 agents that wrote something ended with a pull request. The reason
is not tokens and not time: **inventing the implementation**. Five of the six cancelled features
say it in the same words ("the model does not start", "seven edits in two existing files",
"edits in an 8000-line eval.rs"). A feature asks for a decision about the API, the command spec,
the UI and the locales; an agent with 250 iterations spends them reading and never starts. An
issue arrives with the RED test written and the root cause traced: there the agent has to
implement, not invent. **So: no new features. Only issues.** A feature that is already started
may be finished when what is left is mechanical or already written (the #3599 Pierce constraint
is published with the verified part and the pending part declared). A brief that says "follow
the pattern of X" without the code produces explorers, not deliverables: it happened twice.

**The cost per ATTEMPT is the SAME; the DELIVERY rate is what differs.** Measured on the same
work: a feature attempt and an issue attempt cost about the same, so "features are expensive"
is not the reason to avoid them. The reason is that features rarely FINISH — the great majority
of the feature attempts were cancelled, while the issue attempts turned into pull requests. So
the lever is not the kind of work but the SHAPE of it: the issues that get delivered are the
ones whose cause is already located and whose RED test can be written without inventing
anything. An issue that is still a bare report costs what a feature costs, because it makes
the agent read to understand and never write.

## A token that cannot be released by hand is a token taken forever
`build-slot.sh --release` takes the token NAME ("slot-1") or its full PATH
("/…/build-slots/slot-1"): an agent that takes the token by hand releases it with the path it was
given, and a release that only understood the name left that token taken forever. The two slots
of the box then stay busy and every gate in the queue dies with "no free build slot". The same
is true of the lock of the queue runner: a lock left by a killed runner is released by AGE and
OWNER, never by pid.

## An issue with no pull request loses its claim, and the claim has a DEADLINE
The claim on an issue lapses when no pull request references it, and the window is measured in
HOURS, not in waves. So a backlog of started-but-unpublished issues is worse than an empty
backlog: every one of them expires silently and the work dies with it. Three rules:
- the agent opens the pull request in DRAFT at the COMMIT, not after the gate: the draft is
  what keeps the claim alive, and a gate can take 40 minutes or hang (why: the deadline
  counts from the commit, not from the gate).
- cap the work in flight. The queue compiles a couple at a time, so the backlog has to be
  smaller than what the queue can drain inside the window (why: a backlog bigger than the
  drain rate is a backlog that expires).
- the agents do not compile; the queue compiles. An agent that compiles takes the slot and
  contends for the build lock (see `docs/slot-rules.md`).

`bin/pipeline.py` implements the flow — it repairs the body of every draft, enqueues the gate
of the drafts that have no verdict yet, and promotes the ones that came back green.

**The exact deadline is about PUSHES, not about the claim in the abstract.**
`.agents/skills/solidcraft-contributing/SKILL.md`: *"A draft with no pushes for 72 hours may be taken
over"* — comment first, then open your own claim (you may start from its branch). So the
mechanism that protects the work is the push cadence, not the existence of the draft. If the
work sits for more than a day, push (an empty push counts) or the draft can be taken.

## The regression test goes in the area's EXISTING test file (2026-11-04)
`AGENTS.md:24`: *"A regression test goes in the area's existing test file, never a per-bug file
(#3226)"*. An agent wrote `viewport_hover_pan_tests.rs` for issue #2130 — a per-bug file, which
is FORBIDDEN. The area's file for the highlight is
the inline `mod feature_highlight_tests` of `crates/ui-egui/src/viewport.rs` (there is no
`feature_highlight_tests.rs` file: the area's tests live inside `viewport.rs`).

No automated check catches it (not in `xtask/`, not in `pr-checks.yml`): the maintainer catches
it in review, and there the PR dies. So when a brief says "write the RED test", it must say
IN WHICH FILE: find it first (`ls src/*_tests.rs` of the crate, `grep -n 'mod .*tests'
<archivo>.rs`) and name it literally in the brief.

## Verify the claims against the code, not from memory (2026-11-04)
The user asked whether what had been told to them was validated against the code, and the
honest answer was "half of it is verified, half of it is my own design". The rules to avoid
repeating that:
- before asserting a repo rule, grep the repo: `AGENTS.md`, `.agents/skills/*/SKILL.md` (the
  agents' rules; `skills/` is the app's MCP), `.github/workflows/`, `xtask/src/`. The rules
  that matter are written there.
- say explicitly which is which: what the REPO demands (verified) vs. what is this
  orchestrator's own design (do not defend it as if the repo asked for it).
- the authority for claims is `.agents/skills/solidcraft-contributing/SKILL.md`; the authority for the
  PR body format is `.github/pull_request_template.md` + `pr-checks.yml`, which demands
  `Changes a default: no` in that exact form.
- the issue pool is measured with the paginated issues API: `gh issue list --limit N` TRUNCATES
  and reports a pool that looks exhausted when it is not.

## Do not kill the processes of other agents (2026-11-04)
A `cargo`/`rustc` on the box can be the build of an AGENT, not of yours. `pkill -x cargo`
cuts it and breaks that agent's gate halfway (it had to be told through the steer channel).
To clean up, kill only the PIDs you started (keep them when you start them) or use the build
slots (`bin/build-slot.sh --status`): the slot is the right unit for "a heavy build in flight".
Same rule as for locks: liveness is AGE and OWNER, never pid.

## A measurement on a shared box needs a FREE box, a per-case cache, and ONE instance
A benchmark run on this box was destroyed twice and neither time by the measurement itself:
- a peer agent's `pkill` killed the run (the rule above: never `pkill` on a shared box);
- two instances of the same script ran at once, each waiting for the other's cargo lock, and
  the two of them measured each other instead of the thing being measured.

So a measurement on this box: waits for the box to be FREE (no `cargo`/`rustc` for a sustained
period, not one instant), uses a SEPARATE cache directory per case, and is launched exactly ONCE
— a relaunch from a command that timed out leaves an orphan running next to the new one, and
the two of them contaminate the numbers. If the numbers come out of a box that was busy, they
are not numbers: they are a mixture of the case and of whatever else was running.

## A secret scan has FALSE POSITIVES, and rewriting a self-reference breaks a script
Before pushing the orchestrator's code to a repo, the tree is scanned for tokens and keys. A hit
that is a self-reference (`export TOKEN="$TOKEN"`, or a value defaulted to
`$(openssl rand -hex 32)`) contains the NAME of a secret, not a secret: a regex that matches
`NAME=<16+ chars>` flags it. Read the line before changing the script — replacing a
self-reference with the environment variable changes nothing and breaks a working script. A
real value never goes into the repo AND never stays hardcoded in a script.

## A script that runs from a cron is never edited in place (2026-11-04)
`pipeline.py` runs every 5 minutes and `gate-queue.sh` every 3. Editing one of those files
while bash is reading it produces errors like `e: command not found` and
`syntax error near unexpected token 'fi'`, because bash reads the script by BYTE OFFSET and
the file changed size under it. Replace atomically (`os.replace`, or write to a temp file and
`mv`), never in place. The same applies to `state.json`, which the crons read.
