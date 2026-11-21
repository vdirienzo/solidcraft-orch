## A FEATURE is planned with a GAP ANALYSIS of the plan, not dispatched on sight
When the issue pool runs dry, features are the next source of work — but a feature is not a bug
and the way to find one is different. The user asked for this explicitly: for features, plan
well and do a deep gap analysis of your OWN plan before dispatching anything.

**The triage of the maintainer means a different thing in a feature than in a bug.** In a bug
it is a veto ("kernel work is paused", "this is a duplicate of #X"). In a feature it is
usually DESCRIPTIVE of the current state: "0.28.0 draws all three origin planes in one
origin-plane colour, and no preference sets a colour per plane" is not "this is done", it is
"here is exactly what is missing". A filter that skips every triaged feature throws away the
best candidates; a filter that accepts every triaged feature dispatches agents onto work that
already exists.

So the filter for a feature is: read the triage and classify it —
- ALREADY DONE: it names the PR, the setting or the command that already does it. Out.
- ANOTHER TOOL: it says there is a different command for that. Out.
- INTENDED: it says the behaviour is deliberate. Out.
- ACCEPTED: it says "the request stands", "that would be useful", or welcomes a PR. **In.**
- UNTRIAGED: no comment. Weaker, but possible.

**Then verify the gap in the CODE, not in the triage.** On 01-11-2026 six features looked free
and the triage of five of them turned out to say they were already implemented (#10574 is a
setting off by default, #10473 was merged in #10417, #10250 is possible today with Joint
Origin, #10649 is the pattern command's own rule). Only one survived. Reading the code is what
separates "the issue describes a gap" from "the issue describes a behaviour somebody changed
their mind about".

**The gap analysis of the plan is where the real work is.** The plan for the surviving feature
("a colour per origin plane") looked like a three-line change; the gap analysis found six
things that would have broken it:
1. The token is ONE for the three planes, used in the draw call — the feature is a token per
   plane, so it touches the struct, the resolver AND the drawing.
2. A test asserts that the colour is the same on the window side and the view side. A new
   token has to keep passing it.
3. There are FOUR colour-vision modes. A colour that is a MIX of the axis colours (the issue
   asks for brown = red+green) is indistinguishable from red for a deuteranope: that would be
   an accessibility regression. The safe answer is that the theme PICKS the colour per plane,
   and the app does not compute the mix.
4. Twenty-seven theme files declare the token. The fallback (absent token = the old colour)
   means NONE of them has to be edited, which is also what the repo's own rules want.
5. The planes have TWO sets of names (XY/XZ/YZ and Top/Front/Right) and the draw code uses the
   first one.
6. A "simple feature" that is visible in the app is NOT simple to ship: the repo requires a
   screenshot of the result, which means building the app and driving it over the control
   channel.

Write the gap analysis down (a `plan-features.json` next to `state.json` is fine) and put the
resolved gaps in the agent's brief: an agent handed the gaps does not rediscover them, and one
handed only the goal repeats the plan that was already wrong.

**When the manual search returns ONE candidate and the pool should return more, the MANUAL
FILTER is the suspect, not the pool.** On 01-11-2026 a manual scan of 400 issues found one
workable feature; an agent with a brief that said "read the whole triage and classify it by
the maintainer's exact words" found **thirty**, seventeen of them headless. The manual filter
required a body over 200 characters AND no triage AND no kernel AND no competing PR — and the
best candidate (#5237, "the command reference should read like a table of raw strings") has a
triage that says *"a docs request ... A friendlier generated layout is a valid request; it
would need to stay generated so it can't drift from the commands"*. The filter threw it out
because it was triaged. In a FEATURE the triage is where the CONDITION on the scope lives, and
the issue does not say it: the agent must read it.

**A report that says the behaviour is wrong may be a report about a DIFFERENT convention.**
#10750 ("Box dimensions are swapped? the width is applied to the height") is not a bug: the
upstream test at `crates/ui-egui/src/primitive_units_tests.rs:226` already asserts the mapping
(`length` → X, `width` → Y, `height` → Z, `assert_size(..., [40.0, 30.0, 20.0])`), which is the
standard CAD convention. The reporter expected a different convention.

So there is a third kind of "already done", and it is the cheapest to check: **search the
upstream's own tests for the behaviour the issue complains about.** If a test already asserts
it, the issue is either about a different convention or it is wrong. That check costs one
search and saves a whole agent cycle.

The order of the three checks for a candidate, cheapest first:
1. Search the upstream tests for the behaviour. A test that already asserts it settles it.
2. Read the maintainer's triage: already done / another tool / intended / accepted.
3. Read the code and write the RED test.

**A subagent that finds the behaviour already asserted should close the issue without a PR and
say so** — that is a complete result, and the slot goes back to the pool. Do not let it look
for something to do.

**So the two halves of the work are different jobs**: an agent reads the triages and classifies
them (with the quote), and the orchestrator verifies the gap IN THE CODE and writes the gap
analysis of the plan. Neither substitutes for the other, and the second is what turns a list of
candidates into one dispatchable feature.

**A feature whose triage names the CONDITION is the best candidate there is.** #5237's triage
does not only accept the request, it says what the change has to be ("stay generated so it
can't drift") — which is exactly the scope definition the issue lacks, and it is what kept the
implementation from becoming "write a nice document by hand" (which the repo forbids: the file
is generated and `cargo xtask book` rewrites it).

### The issue pool is the bottleneck, not the machine
Measured on 01-11-2026 against the upstream: of 400 open issues, 177 are `area:kernel` and 75 carry `kernel-paused`. Of the 128 issues titled "X: operation failed", only 18 are outside the kernel, and of those 17 already have the maintainer's triage (duplicate of #346, "same refusal as #4325, kernel work is paused", "could not reproduce on 0.29.0").

So the workable pool is roughly 3-4 issues at a time, and it runs dry. Two consequences for how the wave is planned:

- A slot that spends its whole budget searching will come back empty. Give the searching agents a POOL that is already filtered, not the raw issue list, and let the implementing agents do the RED test.
- The filter that matters is the MAINTAINER'S TRIAGE, not the labels. `dudedagger42` comments on an issue mean the maintainer has already decided what happens to it: a triage that says "duplicate of #X" or "kernel work is paused" closes the issue for us. The labels alone lie: #10719 has no `area:kernel` label but the flange code is in `crates/kernel/`.

The filter that produced the last good issues, in order: not kernel (by label AND by where the fix would live), not triaged by the maintainer, not already claimed by an open PR, with a body that has concrete steps or an exact error message. The best candidate of that pass was #10747: an `area:io` unit mismatch with the exact JSON commands in the body and no triage at all.

### A refusal that many issues share is one fix, not many — unless the fix is in a paused area
Four issues (#4325, #10044, #10059, #10120) failed with the SAME message: "this face can't keep an attachment: its history can't tell it apart from other faces". That message lives in `crates/engine/src/cmd/sketch_face.rs:219` (the engine, NOT the kernel) — so it looked like one fix for four issues.

It was not. The maintainer's triage on #4325 says the choice between the two possible fixes is theirs for when the kernel work resumes (#3992). A shared refusal whose fix requires the paused area is a DEAD END no matter how many issues it explains. Check the triage of the CANONICAL issue of a shared refusal, not the number of issues it explains: the multiplier is a trap when the fix is in a paused area.

### The MAINTAINER'S OWN COMMENTS ON MERGED PRs are a source of work nobody has taken
The pool of open issues runs dry, and the labels and the triage do not show where the next
work is. The place that still has work is the maintainer's own review comments on PRs that
are ALREADY MERGED: a comment on a merged PR describes a defect that is still in `main`,
and nobody files an issue for it.

Found this way on 01-11-2026: on PR #4929 the maintainer wrote that when a reference has no
`body`, the message ends with an empty name — `...already projected into this sketch: face of `
(nothing after "of") — and that it should probably say `face of Body1`, or drop "of". That
comment is on a MERGED PR, so the defect is in `main` today, and no open issue tracked it.

The shape of the defect: `crates/sketch/src/link.rs`, `LinkSource::describe()`, does
`format!("face of {body}")` with `body: String`; the name is empty when the body is not
found in the model (`crates/doc/src/project.rs`, `unwrap_or_else(|| body.clone())`). It
touches `Edge`, `Face` and `Vertex` at once, and it is headless-testable.

So the way to find work when the issue pool is dry is not to read the issue list harder:
it is to read the MAINTAINER'S COMMENTS on their own merged PRs, and on the issues they
triage with a specific mechanism. The comments there are precise (file, symptom, expected
text) and nobody has claimed them.

### The liveness of a lock is its AGE, not its PID
The lock records the PID of the script that took it, and that script exits at once: the PID was
dead BY DESIGN and could never say who was alive. Four locks of a wave that was interrupted then
ate every slot, and `slots.sh` reported `free_slots=0` on an idle machine — the orchestrator
could not start any agent. So:
- Take with an owner: `slot-lock.sh --slot <n> --take --owner "<label>"`.
- A long job refreshes it: `slot-lock.sh --slot <n> --heartbeat` (a lock nobody refreshes for
  `SLOT_LOCK_STALE_MIN`, default 240 min, counts as stale).
- Reap a stale lock only with the evidence that its owner is gone:
  `slot-lock.sh --slot <n> --reap --older-than <min>`. It prints which lock it freed and who
  owned it. NEVER reap a lock whose owner is alive.
- `slots.sh` counts only FRESH locks as taken and reports `stale_locks=N`; the stale ones do not
  eat slots.

### The target dir comes from the script, never from a constant
`slot-target-dir.sh --slot <n>` resolves the base itself (the orchestrator's own `targets/`).
Do not hardcode the path: the base once pointed at a directory that did not exist, so an agent
asked for its target dir got an EMPTY one and rebuilt the world (30 GB) for nothing.

### Check the env when a script "does nothing"
A stale `ORCH_DIR` in the shell makes `slot-lock.sh` operate on the WRONG directory and print
nothing. `env -u ORCH_DIR bash bin/slot-lock.sh --list` shows the truth. The scripts read
`$ORCH_DIR` from the environment, so a leftover export from a previous test silently redirects
them.

### The `Changes a default:` line and the docs-only exemption
Upstream's `checkDefaults` SKIPS the check for a docs-only PR (`isDocsOnly`), so a docs PR can
pass CI without the line — but the repo's own rule and the contributing skill ask for it to be
filled in, and `pr-defaults-line.sh` (which CALLS upstream's parser) reports it missing. Fill
the line in; do not rely on the exemption.

## Reclaim disk and RAM as slots close
This box exists ONLY for this work, so a finished slot's weight is waste the moment it closes. Reclaim it as you go rather than when the disk gets tight: a scoped gate compiles the whole touched scope, so one slot's debug build reaches tens of GB and the box can fill up mid-gate.

- When a slot's PR is MERGED, delete its worktree, its target dir and its fork branch — but ONLY after verifying the fix is actually upstream. A merged-but-unverified cleanup loses the work.
- A squash merge changes the SHA, so an ancestor check on your commit reports a false negative. Compare CONTENT (`git diff <sha> origin/main -- crates/`) to prove the change is upstream.
- Delete the DEBUG profile and keep the RELEASE binary of a slot that may still owe evidence: the release build's LTO link takes tens of minutes, the debug build rebuilds in minutes.
- The scratch under /tmp is tmpfs: it is RAM, not disk, so a stale scratch dir from another tool costs MEMORY. Clear it too.
- Caches and toolchains are weight only when nothing selects them: a compilation cache with a ~0% hit rate is pure loss.

The per-location recipe — what to audit, what is safe to delete, what to keep, and the commands — is in `docs/disk-hygiene.md`.

## Answering a status question about the fork and the box
A status question ("what did I push", "how loaded is the machine") is answered from the RECORD
on disk, never from memory and never from the commit dates: a commit date is when the commit
was written locally, and the push timestamp lives in the remote-tracking reflog. PRs live in
upstream and branches live in the fork, so query PRs against upstream with `--author
<fork-owner>`; the fork's own PR list is empty by design and reads like "nothing is open" when
the opposite is true. Decide the unit of the answer (one SHA on two branches is two pushes and
one commit), label it, and lead with the record — times, SHAs, paths — and close with one plain
conclusion line. The commands for the reflog, the pushed-vs-local proof, the load
reconstruction, the vmstat column trap, the memory-rate rule and the two traps of this box are
in `docs/status-report-pushes-and-load.md`.

### A status report is a COUNT, not a catalogue
The user asked for the report in this shape and it is the standing format: how many pull
requests are open, how many were merged, how many were made in the last batch, what is being
worked on right now (one line per issue, the number and what it is, NO explanation of the
the state of the machine (load, disk, memory, one line), the items that are waiting for
a decision, and whether any bug of the loop was found. One line per pull request is the
thing to avoid: the list grows with the effort and the reader wants the totals. A TABLE with
a row per pull request is the same catalogue in prettier clothes — the count is the answer
and the table is the list the count replaced.

The report repeats the answer that is already on disk, so it is cheap to produce and it must
never carry a number that was not read. A scheduled daily report (a cron job whose prompt
collects the counts and whose delivery is the chat of origin) is the way to deliver it, and
the summary of the orchestrator's own state is the first command it runs.

### The hours of the report are ARGENTINE time, and the cron reads the SYSTEM timezone
The daily report goes out at 10am and 10pm ARGENTINE time. The user crontab reads its hours in
the timezone of the SYSTEM, and this box runs `America/Argentina/Buenos_Aires` (`timedatectl`),
so the hours of `bin/crons.txt` are Argentine hours here. On a box in another zone they are not:
Argentina is UTC-3 with NO daylight saving, so hours converted by hand drift by an hour twice a
year against a zone that has it. `bin/daily-report.py` computes its own time in UTC-3, so the
text of the report is right whatever the zone. (2026-11-21: the old scheduler, hermes, had its
own `timezone:` setting; it is gone.)

## Choosing the issues of a wave
The issues are picked BEFORE anything is dispatched, and a wrong pick costs an agent its whole
budget. The filters, in the order they save the most: the area and state vetoes, the open PR
that claims it, the TRIAGE COMMENTS that say it no longer reproduces or was fixed elsewhere,
the reproducibility of the steps, whether it can be verified headless on this box, and whether
it is one topic. The labels say what an issue is ABOUT; the comments say whether it is still
TRUE, and an issue that was triaged and found dead stays open with its labels untouched.

The pool of issues that survive every filter is finite and empties as the upstream triages, so
when the sweep yields nothing good the honest outcome is to dispatch NOBODY and wait for a
slot. Do not lower the bar to fill a slot: a PR built on an issue that will not reproduce
costs the credibility of everything else the fork ships. The sweep commands, the discard
reasons and the per-issue checks are in `docs/issue-selection.md`.

## The gate checks the claim BEFORE it compiles, and it has to know which PR is OURS
A scoped gate compiles the whole touched scope: eight minutes and the machine's CPU. When the
claim of the issue was already taken by another pull request, that work is thrown away with
the change, so the gate stops BEFORE its phases with exit 4 (the code the publisher uses for
an issue that is no longer open). A claim that cannot be READ (GitHub did not answer) does
NOT stop the gate: the gate is the work, and the brake that publishes decides on the claim
for the last time.

**The check needs to know OUR pull request, and without it the gate refuses to run on our
own work.** The rule is "the lowest-numbered open pull request that claims the issue wins",
so the check has to compare the competitors against OURS: our own PR is not a competitor. A
gate that asks the claim without saying which PR is ours reads our own PR as the agent that
took the issue and aborts with exit 4 — on EVERY pull request of ours, before compiling
anything. `gate.sh` therefore takes our PR as an optional fourth argument
(`bash bin/gate.sh <issue> <sha> [base] [our_pr]`) and, when it is not given, DISCOVERS it
from the branch of the worktree with `gh pr list --state open --head <branch>`.

Two traps in that discovery: in a worktree `.git` is a FILE, not a directory (so the test is
`[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ]`), and the block has to run AFTER `$REPO` is
defined. Both failures look the same from the outside — `our_pr=none` in the log and an exit
4 — and neither is visible unless the log says which PR was found.

**The brief must carry the RESULT of the analysis, not the charge to analyse:**
- the design, written out (the fields of the new struct, the maths, the files to touch);
- the precedents, by PR number ("read the diff of #7249"), so the agent reads ONE diff
  instead of hunting for one;
- the first step, literally: "open this file, write these lines, that is your RED";
- a deadline on the research: "if in 30 minutes you have not written the RED test, you
  are on the wrong path";
- and when a previous agent already produced something, the exact state of the worktree
  and the instruction "this exists, do not rewrite it".

**Quote the CODE TO PASTE, not the pattern to imitate.** A brief that says "follow the
pattern of <the neighbouring command>" sends the agent through hours of repository reading
and it writes nothing: measured, three hours and zero writes with a clean worktree at the
end. A brief that quotes the block of code to insert, the path of the file to create and the
exact verification commands leaves nothing to explore. When the shape of the change is known,
quote it; the agent's job becomes apply, verify, commit, push.

**Answer the questions the agent would otherwise go looking for.** Each unanswered question
is an hour of reading: does this string already exist in the catalogue, does a missing locale
fall back to English, which file does it belong in, what does the sibling command do with an
empty selection. Those answers cost the orchestrator two minutes of reading and the agent
three hours.

**SPLIT THE WORK INTO STEPS WITH A BINARY ACCEPTANCE CRITERION.** A feature that needs a
new command, a new document feature, a schema, locales and goldens is too big for one
agent: the whole of it failed four times (4h to 7h, nothing written) and the same feature
went through in 45 MINUTES once it was split — step one was "write the maths in
crates/doc/src/distribute.rs with its unit tests, cargo test -p solidcraft-doc in green, one
commit, nothing else", step two is the integration. A step whose acceptance is "the test suite
is green" ends; a step whose acceptance is "a PR exists" does not.

The research that finds nothing is described below, together with how to recover it.

## When the steps do NOT fit: publish the part that landed as a PARTIAL pull request
A feature split into steps can run out of road: the steps that extend existing content land,
the step that adds a NEW artifact to a crate the agent has never touched does not. Two
measured attempts at registering a new command (a new spec, a new schema entry, a new locale
file, a new registration) burned 500 iterations and wrote nothing — the SECOND one with the
exact pattern in the brief (the spec form, the function to copy, the sequence to follow, the
schema file, the locale file and its shape). The pattern turns a VIABLE ask into a cheap one;
it does not turn an INVIABLE one into a viable one. Diagnose the ARTIFACT, not the size of the
brief.

So when the work is half done, the half that landed is published and the half that did not is
declared. The shape of such a pull request:

- The first line names the split and carries NO closing verb: "Addresses #N (part 1 of 2: the
  geometry and the solver; the command and the UI come in a follow-up)". The upstream parser
  closes on verb+number, so "Fixes #N" on a partial PR closes an issue that is still half done.
- The body says what is IN and what is OUT, and names the one design decision the follow-up has
  to make. A constraint that one crate cannot see another crate's geometry needs the other
  crate to refresh it: say which side owns it, so the follow-up is not rediscovered.
- The tests of the part that did NOT land are marked `#[ignore = "<why>"]`: not deleted, and
  not left failing. A red test inside the scope makes the gate red and the partial pull
  request unpublishable, and a deleted test loses the specification of the follow-up. The
  reason string says what is missing, and the body repeats it in prose. The repo already
  ships ignored tests with their reason, so the form is the house style.
- For a change with NO screen (a constraint, a solver, a naming format) the evidence IS the
  test output with the numbers: the suite that passes and the cases it pins. Say that in the
  evidence section instead of leaving it empty, and say explicitly that the visual evidence
  comes with the follow-up.
- It stays a draft until the gate is green ON THE PUBLISHED HEAD, then goes ready.

The alternative — holding the verified commits hostage to the step that never landed — loses
them: the worktree is scratch, the branch is forgotten, and the next agent starts from zero.

## The research that finds nothing: the tell is the summary

A subagent that spent its whole budget investigating ends with a summary that reads like
a plan, not like a result: "I have the design nearly settled", "Now let me generate the
before version", "Time to stop analyzing and check upstream for the intended design".
Those sentences are the symptom. What to do, in order:

1. Look at the BRANCH and the WORKTREE, not at the summary:
   `git log --oneline origin/main..BRANCH` and `git status --short`. A zero-commit branch
   with a clean worktree means: nothing was written.
2. Look at what IS there. Two of the four dead agents had already written the RED test,
   and one had written a 450-line parser that was GREEN (`cargo test -p xtask` -> 87
   passed). That work is worth more than a fresh start.
3. Rebuild the brief around it and say, in the first lines, what exists and what does not:
   "the implementation is written and green; what is missing is: commit it, run the gate,
   generate the evidence, open the PR". A brief that starts with "the code is already
   there and compiles" turns the same task from five hours into forty-five minutes.

The one thing never to do: dispatch the same big brief again with a warning attached.
Three agents in a row researched the same feature to death. The brief is the bug.

## The evidence of a feature is generated text, not a screenshot

A change to a GENERATED document (the command reference, a table of parameters) is proved
by pasting the generated output before and after. The repo accepts that as evidence; a
screenshot of a document would be worse. The same goes for a CLI or MCP error message:
the exact text, before and after, IS the evidence.

