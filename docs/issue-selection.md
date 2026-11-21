# Choosing the next issues: what is worth an agent

The wave picks its issues BEFORE it dispatches anything, and the cost of a wrong pick is an
agent burning its whole budget on an issue that was never free. The filters below are ordered
by how much they save.

## The filter order

Apply them in this order and stop at the first one that rejects the issue.

1. **Veto by area and state.** `kernel-paused`, `status:decision`, an in-progress label, or an
   area the maintainer parked. These are not "less attractive", they are off-limits.
   A parked area is also the **subject** when the cause lives in the parked code: the STEP and
   IGES reader is `crates/kernel/src/step_in/`, and this box vetoes the kernel (it cannot build
   it; upstream does take kernel work, in `solidcore/`), so an issue whose
   title names the format is off-limits even when the upstream labels it `area:io`. The
   selector vetoes the subjects `STEP` and `IGES` (in upper case: a lowercase "step" is a
   geometry step, not the format) and the titles that ARE the parked code: the kernel's own
   operations (`Boolean`, `Spline Boolean`, `Fillet`, `Chamfer`, `Shell`, `Sweep`, `Loft`,
   `Thread`, `Hole`, `Offset Face`, `Local operation`, `solidcore`, `Tessellation`) and the
   render workspace (`Render`). The upstream labels most of those `area:sketch` or `area:io`
   instead of `area:kernel`, so the labels do not park them: five "Spline Boolean" issues
   were in the pool before the subject veto.
2. **Claimed by an open PR.** Any open PR whose title or body names the issue. The lowest
   numbered open PR wins, so a higher-numbered one of ours loses the claim.
3. **DEAD, by the triage comments.** A comment that says the bug could not be reproduced, that
   it was fixed by another PR, that it is a duplicate, or that it should be reopened. The
   LABELS do not say this: a triaged-and-dead issue keeps its open state and its labels.
4. **A cause you can point at, in code.** Not "numbered steps that a headless run can
   execute" — that filter empties the pool, because the report often has no numbered
   steps while the cause is perfectly visible in the code. The filter that works: the
   CAUSE is located (a file and a line, in a crate that is not parked), and a
   deterministic RED is possible from it. A section that says the reproduction was not
   provided is a hint to read the code, not a veto.
   Two things that look like vetoes and are not: a fix that seems to need a DESIGN
   decision is often already decided in the tracking issue the candidate belongs to —
   read that tracking issue before setting the candidate aside; and a symptom with no
   steps can still be a solid bug when the code says so.
5. **Verifiable headless.** The agent has to be able to prove RED before GREEN on this box:
   no hardware that is not here, no driver that is not installed, no window manager, no display.
6. **One topic.** An issue whose fix spans several subsystems is several issues.

### A filter that is about the CODE, not the issue text
Two candidates can look equally good in the issue text and be worth completely different
amounts of an agent's budget, and the difference is where the behaviour lives:
- a failure whose message comes from a VETOED area is off-limits, even when the issue reads
  like a UI bug. Check where the string the report quotes is actually produced: if it lives in
  the kernel (`crates/kernel`, `solidcore/`), the honest outcome is to skip the issue, not to
  work around it;
- a request that is a DESIGN or ARCHITECTURE decision (adopt a language, a protocol, a
  dependency) is not a fix an agent can land: it needs a proposal, and it has to be settled by
  a human. It is a different kind of work and belongs in a different queue.

One grep for the error string or the command name decides both, and it is the cheapest check
in the sweep: it tells you which LAYER the bug is in, and therefore whether the fix is even
yours to write.

## Why the triage comments are a separate filter from the labels

The labels say what the issue is ABOUT. The comments say whether it is still TRUE. A triager
who could not reproduce it says so in a comment and the issue stays open with its labels
untouched, so a label-only filter keeps offering it. The same comment also carries the
reason a report was closed as not-a-bug, which is the thing that tells you to skip it.

Read the comments of every candidate. It is one call per issue and it is the cheapest filter
there is: a comment that kills the issue saves an agent's whole budget.

## The pool of clean issues is finite, but "empty" usually means the FILTER

Sweep the whole open set, not the first page — and size the listing limit above the
real count, because a truncated list is BLIND, not empty.

When the sweep yields nothing good, the honest outcome is to dispatch NOBODY and wait
for a slot: an agent on an issue that will not reproduce produces a PR that cannot be
reviewed, and a PR built on a dead issue costs the credibility of the whole fork's output.
Do not lower the bar to fill a slot. Do not pick an issue from a vetoed area "because it is
quick". The slot waits; the upstream does not.

But before believing the pool is exhausted, check the FILTER, not the pool: the listing
limit, and the clause that demands an exact error message with reproduction steps. That
filter was applied to the whole open set and yielded ZERO candidates, while the same set
with the filter this file describes yields many. An empty sweep is a fact about the
filter until it is shown to be a fact about the upstream.

## The sweep

Labels first, because they cut the set cheaply:

    gh issue list --repo <upstream> --state open --limit 300 --label area:sketch \
      --json number,title,labels

Then the per-issue checks, in parallel, one call each:

    gh issue view <n> --repo <upstream> --json title,labels,body,comments

Read three fields of that: the LABELS (the veto), the COMMENTS (the deadness), and the BODY
(count the numbered steps; look for the reproduction section). A candidate with numbered steps
and no dead comment is worth a full read of the body; one without is not.

The number of open PRs is large enough that the limit matters: a guard that reads a truncated
list of PRs is BLIND, not wrong, so it reports that it does not know instead of reporting a
duplicate. Size the limit above the real count and check the count.

### The LABELS tell you where to look; the BODY tells you whether there is work
The label filter is cheap and it is not wrong, but on a big pool the issues that carry it are
dominated by the machine-generated reports: a crash reporter opens an issue with no
environment, no steps and a one-line body, and it carries the bug label like everything else.
Those issues have nothing to implement — there is no reproduction to make and no symptom to
locate. So the label is a place to start and the BODY is the filter that decides: a candidate
needs a body with substance (an error message, a behaviour, a reproduction), and not a report
with nothing in it.

Two traps in the sweep:
- a listing that TRUNCATES is BLIND, not empty, and the truncation is silent: it returns
  exactly the limit and says nothing. Page the endpoint (`per_page=100&page=N`) until the
  pages run out, and compare what was collected with the count the API reports.
- a text query that returns ZERO is not proof that the phrase is absent from the bodies. The
  search endpoint does not reliably index every issue body, so a phrase you found by reading
  a body can come back with no hits. Read the body of the issue you already have; never
  conclude from the query.

### Count the candidates by ROOT CAUSE, and cross the pool against the catalogue of known failures
A hundred issues that share a title and a label are not a hundred pieces of work: they are
often ONE cause wearing a hundred titles, and the fix belongs to the layer that PRODUCES the
message, not to the layer the title names. Two checks decide what is really available:
- follow the ERROR STRING to the code that emits it. If it comes from a parked area, the issue
  is not yours to fix however it is titled, and the honest count of available work drops by all
  of them at once.
- cross the pool against the upstream catalogue of tests that are known to fail today. An issue
  whose fix already landed upstream still shows as OPEN, with its test still listed as failing,
  and the tracking entry says the replacement is still to come. Those are already-fixed, not
  available — and they are a large share of a pool that looks free.

So the number that matters is not "how many issues are open" but "how many distinct causes
remain, in code we are allowed to touch, with the fix not yet upstream".

## The discard reasons, and what each one tells you

| Reason it is discarded | Where the reason shows up |
|---|---|
| Already fixed, by a PR that shipped | a comment naming the PR, or the fix's own test |
| Could not be reproduced | a triager's comment |
| Duplicate | a comment naming the other issue, and a bot claiming it |
| Claimed by another agent | an open PR naming it; the claim label alone is not proof |
| Needs hardware or a driver that is not here | the steps and the environment section |
| A feature request, not a bug | the title and the labels |
| Already in progress in a parked area | the labels |
| Another agent is working on it right now | the branch or the draft PR, usually in the last hour |

## After the pick, before the dispatch

Re-check the two things that can change in the minutes between the sweep and the dispatch:
the open PRs that name the issue, and the issue's own comments. The claim label is applied
with a delay, so an issue that was free at the sweep can be taken before the agent starts —
which is why the claim protocol re-verifies after the draft is open and not only before.
