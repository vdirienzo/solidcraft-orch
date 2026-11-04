# Handing work over from a dead agent to its replacement

An agent that dies (iteration cap, interrupted delivery, session end) leaves its work in three
places, and each one dies with it if you do not rescue it first. Rescue BEFORE dispatching the
replacement: the replacement's brief is much stronger when it starts from a resolved design and a
proven-red test than when it starts from the issue text.

## An INTERRUPTED agent is not a dead agent
A delegation that ends as `status=interrupted` (the delivery was cut, the model was waiting for
a response) leaves the worktree EXACTLY as the live agent left it: a wip commit here, an
uncommitted diff there, and the lock still held by the interrupted owner. The rescue is the
same, but the brief differs in one way that matters — see step 4.

The interrupted agent's own transcript names the command it was running when the delivery was
cut. Read it before briefing: it tells you whether the agent was compiling, testing or
publishing, and therefore what state the work is really in.

A truncated summary ("TRUNCATED: hit max_iterations") means the summary is NOT the result:
the work may be half done, and the worktree is the truth. Go read the worktree, not the
summary.

## 1. Rescue the notes
Research, maps of the code and measurements live in scratch files that the next boot may wipe.

    ls -la /tmp/*<issue>* 2>/dev/null
    cp /tmp/<file> <orch>/logs/agent-<issue>-<name>.txt

Name them by the agent and the topic, not by the date: they are reusable, not a diary.

## 2. Rescue the code
The worktree holds the diff the agent never committed.

    cd <worktree> && git status --porcelain && git diff --stat

If there is a diff, commit it and push it to the FORK even when it does not compile:

    git add -A && git commit -m "wip(#<issue>): <what exists so far>"
    git push fork <branch>

### Read the status BEFORE `git add -A`: the agent left SCAFFOLDING behind
An agent that ran out of budget mid-investigation often leaves two kinds of trace: an
UNTRACKED scratch file (a probe, a temporary module) and a tracked-file change that
REFERENCES it (the `mod probe_tmp;` line it added to the real module). `git add -A` sweeps
both into the wip commit, and the commit then carries a file that does not belong to the
issue. Look at `git status --porcelain` first, and delete the scaffolding before committing:

    git status --porcelain          # ?? crates/.../probe_tmp.rs     <- scratch, delete it
                                    # M  crates/.../mod.rs            <- the line that names it

Delete the scratch file AND the line that references it, then confirm the tree is clean:

    rm -f crates/.../probe_tmp.rs && git checkout -- crates/.../mod.rs
    git status --porcelain          # must be empty

A worktree that is not clean is not rescued: the next agent inherits the scaffolding and the
reviewer of a PR built on it finds a probe file in the diff.

A `wip` commit on the fork is recoverable; an uncommitted tree is lost work, and this issue has
been lost more than once. The commit message must say what is done and what is NOT, so the
replacement (and you, later) can tell the difference.

## 3. Rescue the lock
The dead agent's slot lock still has its owner recorded.

    bash bin/slot-lock.sh --list                              # who holds what
    bash bin/slot-lock.sh --slot <n> --reap --older-than <min>  # frees it, and says whose it was

Reap only with the evidence that the owner is gone: no live process, no growing transcript, the
delegation reported finished. Never reap a lock whose owner is alive.

## 4. Write the replacement's brief around what exists
The replacement's brief must contain, as settled facts:
- what the dead agent ALREADY DID (the test that is written, the helpers that are in place), with
  the exact file and line, so it does not rewrite them;
- the RED proof and where its log is, so it does not rebuild it;
- the DESIGN DECISION, already made, with the reason — including which upstream pattern to copy;
- the ONE remaining step, named exactly;
- the hard constraints and the tests that must stay green;
- the rebase state: if the tree is already on the current upstream head, say so, or the
  replacement will reset --hard and destroy the rescued work;
- the publication contract (remote, branch, body lines, gate command) and the escape hatch:
  if it runs out of budget, commit a wip to the fork and report the exact state.

The brief must open by NAMING what survives and WHERE — the commit SHA or the uncommitted
file, the branch, and the step that was in flight. A replacement briefed as "start from
scratch" re-does hours of work and may re-derive a conclusion its predecessor already reached
with numbers.

Say explicitly what NOT to re-derive. A replacement that re-investigates what its predecessor
already settled will spend its whole budget investigating.

### Split the work by ARTEFACT: one artefact per agent
The single biggest cause of a replacement that also fails is a brief that asks for everything
at once. A brief that says "reproduce, write the RED, fix it, run the gate, open the PR" gives
the agent five things to finish and a budget for about one, so it finishes none of them and
the whole cycle is wasted. The brief that works names ONE artefact:

1. **the RED** — turn the probe into asserts, run it, bring the failing output;
2. **the fix** — given a RED that fails for the right reason, make it pass, commit, push;
3. **the gate and the PR** — given a fix already committed and pushed.

Each brief forbids the rest by name ("do not implement the fix, do not run the gate, do not
open a PR, do not read the docs, do not explore the repo"). With the diagnosis already in the
brief, the RED is a small job an agent finishes in minutes instead of an hour of reading.

A brief that names the artefact also makes the failure VISIBLE: an agent that is still
exploring after the RED stage has a transcript that says so, and the orchestrator can steer it
to the artefact ("you have everything you need: the diagnosis is done, the probe is at this
file, convert the printlns into asserts and run this command") instead of waiting for it to
notice on its own.

When the work was rescued into a `wip` branch, keep that branch and the new one separate: the
wip branch is the record of the analysis, the new branch is what becomes a PR. Do not push the
wip branch to upstream and do not open a PR from it.

### The brief must hand over FOUR things, or the replacement explores again
- WHAT IS PROVEN, with the file and the line (so it does not re-derive it);
- WHAT IS PRESERVED, as a commit SHA on the fork (so nothing is lost if it dies again);
- THE DECISION ALREADY MADE, verbatim (the design, the seam, the test file, the naming);
- THE EXACT NEXT STEP, as a single artefact ("write the RED now, the diagnosis is done").

Say explicitly what NOT to re-derive. A replacement that re-investigates what its predecessor
already settled will spend its whole budget investigating.

### The steer that unsticks a READING agent is concrete, and it gives away nothing
A steer that names the artefact is NECESSARY but often NOT SUFFICIENT: "Write the failing test
now" kept a reading agent reading, because it had the brief and kept checking whether the brief
was complete. The steer that works is CONCRETE and hands over the PLAN, so the agent no longer
looks for permission to start:

1. "The diagnosis is DONE. You have everything you need" — and say what that is, in one line;
2. the EXACT place to change (file, function, and the line the previous agent found);
3. the EXACT steps, numbered: open this file, make this change, run this command;
4. the thing that must NOT happen next ("do not read another file", "do not explore the repo");
5. what to skip for now ("do not commit yet, do not open a PR").

The mechanism: an agent that is reading is not searching for knowledge, it is looking for
permission to start. A steer that hands over the plan removes the need to find one.

### The symptom that an agent is one step from the budget
The agent's last words are "let me read the remaining pieces I need for the RED test", and its
worktree is still clean. It is one step away from the artefact and one step from the budget.
Steer it with the artefact, not with advice.

### The report has to fit: a long report is a lost report
The delegation transcript truncates a long final report, and what the orchestrator needs is the
numbers, not the prose. Ask for FIVE things and no more: the SHA, the `Changes a default:` line,
the RED output, the GREEN output, and the gate verdict with its SHA. A report that says "see
above" for the interesting part is a report that lost the interesting part. If it arrives
truncated, the recovery is the agent's commit message or its notes file — so require the
diagnosis to be COMMITTED, not only printed.

## 5. Verify the rescue before you trust it
    cd <worktree> && git status --porcelain   # clean: the rescued work is committed
    git log --oneline -1                       # the wip commit exists
    git ls-remote fork <branch>                # the fork has it

Only then dispatch the replacement.
