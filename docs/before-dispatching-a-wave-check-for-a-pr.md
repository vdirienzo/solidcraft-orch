## Before dispatching a wave, check for a PR that appeared in the last hour
The open-PR survey at the start of the day is not enough: the issues of today are FRESH and
several agents work on them at the same time, so a duplicate PR can appear in the SAME HOUR
the wave goes out. The survey that misses them only looked at the PRs that existed before.

A busy upstream is the normal state of this repo, not an exception: many agents pick the
fresh issues at the same time, and an issue can have a PR within the hour of being filed. Every
wave should expect a fraction of its issues to already be taken.

**The check is the TITLES of today's PRs, not the issue numbers.** `gh search prs` for the
issue number finds only the PRs whose TITLE carries it; the ones that cover an issue without
naming it in the title are invisible to it, and a PR only names the issue in its body
("Closes #N"). So run both, and READ the titles:

    gh search prs --repo tangency-labs/solidcraft "<issue-number>" --limit 6 \
      --json number,title,state,author,createdAt
    gh pr list --repo tangency-labs/solidcraft --state open --limit 40 \
      --json number,title,author,createdAt,body \
      --jq '.[]|select(.createdAt|test("<today>"))|"\(.number)\t\(.author.login)\t\(.title)"'

A title like "Sketch: renaming or clicking a feature no longer reopens its sketch" covers the
issue "renaming a second extrusion opens the main sketch" even though no number appears. Read
the titles against the issue SYMPTOM, not against the issue number.

The cost is one command; the cost of missing it is an agent burning three hours on a fix that
already exists. On a busy day the free issues are the ones with NO PR from today AND a body
that says what happens ("Not provided" is a filter: it means there is nothing to reproduce).

**A duplicate found by the AGENT is the good case.** An agent that greps for the issue's PR
before publishing and reports the duplicate instead of opening a PR has saved the whole wave.
One that does not will publish on top of the other PR.

### The duplicate can come from YOUR OWN wave, and the second agent must ADOPT it
Two agents of the same wave can land on one issue: the first is dispatched, the wave moves
on, the issue is re-dispatched or a sibling task covers it, and the two overlap on the box.
The second one to finish finds a PR the first already opened, seconds earlier.

Opening a second PR fails the repo's duplicate check, so the second agent must ADOPT the
existing one: verify its head against the fork, verify its gate, and then READ ITS BODY for
factual claims and CORRECT what is wrong. A body written minutes earlier by a sibling that
never verified its own numbers carries exactly the errors a reviewer catches first, and
correcting one is a one-line edit that saves the review.

The orchestrator's part is to prevent the overlap: before dispatching an agent for a slot,
check whether a previous agent for that slot is still alive, and tell the new brief that a
sibling PR may already exist, so it verifies and corrects instead of opening a second one.

### When a duplicate is found mid-flight, stop the agent and make it report
Steering a running agent to stop costs nothing and saves the rest of its budget. The steer must
ask for FIVE things, because the agent holds the only copy of the analysis:
1. WHICH PR covers it, and whether it covers the WHOLE symptom or only part of it;
2. the ROOT CAUSE, with file and line — this is the expensive part and it is worth keeping;
3. the RED test if it wrote one, and where it is;
4. to COMMIT AND PUSH the diagnosis to the fork as a `wip` branch before releasing the lock,
   so the analysis survives even though no PR will be opened;
5. whether the RULE the other PR ships is RIGHT at the edges, not just whether it covers
   the reported symptom (see below).

### The other PR may already be MERGED, and the rule it shipped may still be wrong
Stopping an agent because someone else is doing the issue does not end the analysis: the
duplicate's implementation can encode a rule that handles the reported case and still
misbehaves on a neighbouring one. The symptom in the report is the case the reporter
happened to try, not the rule's whole surface.

So the steer asks (5) above, and the agent answers by computing the shipped rule over the
cases the issue implies. A concrete shape of this: a merged matcher tried the exact tag
then the base language, which is right for the tag in the report and wrong for a tag that
carries a script subtag before its region — the base then names a DIFFERENT catalogue than
the one the user is on.

A gap found in merged code is real work, and it needs its OWN issue (the repo's rule is one
issue per PR, and the merged PR's issue is already closed). The orchestrator files that issue
with the numbers, and the agent's rule plus its test become the brief for it. Never let the
gap ride along in the stopped agent's branch: the issue it was working on is someone else's.

Ask for a SHORT report: a long one gets truncated in the transcript and the orchestrator loses
the data it paid for. If the report arrives truncated, the recovery is the agent's commit
message or its notes file — so the steer should require the diagnosis to be committed, not
only printed.

### A duplicate that is only a CLAIM is an invitation, not a wall
When the PR that already covers an issue turns out to be an empty claim — a draft with zero
files, or a single "claim: #N" commit — the issue is not really taken: nobody has written the
fix yet. And a second PR is not an option anyway, because the duplicate check fails a PR for an
issue a lower-numbered open PR closes. The repo's own rule for this situation is to comment on
the existing PR instead of opening a second one.

So the move is to CONTRIBUTE the fix that already exists: comment on that PR with the rule,
the case table, the file and function names, the test names, and the fork branch to cherry-pick
from. The author gets the work for free and the issue gets fixed exactly once.

What makes such a comment worth reading:
- it states the RULE and its cases, not only a link to a branch: the author must be able to
  apply it without reading your diff;
- it names the exact file, function and test names, so the author does not have to hunt for
  where the behaviour lives;
- it points at the fork branch and SHA to cherry-pick, and says plainly that the commit is a
  wip, so the author knows the mandatory body line still has to be filled in on their side;
- it keeps every closing VERB away from every issue NUMBER. A comment that puts "fixes" next
  to a number reads as a claim to any scanner or reader, and the issue may not be yours to
  close. Name the number in prose with no verb beside it.
- it offers the MEASUREMENT, because the author cannot reproduce your environment: the counts
  before and after, and the command that produced them.

This is also the cheapest possible contribution when the gap you found is in MERGED code: the
shipped rule handled the reported case and still misbehaves on a neighbouring one. Say so in
the comment of the PR that shipped it, with the case table.

The recipe, the decision table and a comment skeleton are in
`docs/duplicate-claims-and-contributing-instead.md`

### A build that dies with 143 is MEMORY, and the fix is a scope of its own
(2026-11-21) The 4 GiB cap of the old hermes worker scope left with hermes; the limit now is the
box (15 GB). The OOM killer still takes a heavy build down with SIGTERM (exit 143) and NO error
message, and `journalctl` says `A process of this unit has been killed by the OOM killer`. The
agent reads it as a timeout and burns its budget on it again.

The fix is to run the heavy command in a systemd scope with the belt of a slot
(`SLOT_MEMORY_MAX` in `$LOOP_DIR/config.env`):
    systemd-run --user --scope --quiet --unit=orch-<issue>-<what> \
      -p MemoryMax="$SLOT_MEMORY_MAX" -p MemorySwapMax=0 -p OOMPolicy=continue \
      -- cargo test -p solidcraft-ui-egui --profile ci --lib <filter>
`--scope` keeps the command in the foreground (so the tool still sees its exit code), and the
OOM takes that scope, not the box. On the old 62 GB box this test needed 24 GB: when it does not
fit in the belt here, it is the job of the upstream CI.

Two traps on the way there:
- `RUSTFLAGS` OVERRIDES the flags of `~/.cargo/config.toml` (the mold linker and its
  `--threads=4` live there), so a `-C link-arg=...` added to save memory breaks the LINK
  of the build scripts ("could not compile `proc-macro2` (build script)"). Change
  `CARGO_PROFILE_CI_*` instead; `RUSTFLAGS` is the wrong knob.
- A `cargo` whose cwd is under `$WT_ROOT` (the worktrees) is killed by the loop's
  `kill_turn_leftovers` at every supervisor turn, and a `cargo` under the MAIN checkout is
  killed by the same rule. A build that dies with 143 in a worktree can be the supervisor,
  not the memory. `journalctl` tells the two apart: an OOM names the scope, the supervisor
  does not.

### The heavy work of a slot needs the slot's target dir, and the target dir is not enough
The OOM is not about the SCOPE of the change, it is about the SIZE of the crate: the
`ui-egui` lib test binary is the largest in the repo, so a `cargo test -p solidcraft-ui-egui`
is the command that dies. The test BINARY is built once per target dir; with
`CARGO_BUILD_JOBS=1` and the scope above it links and runs in a few minutes.
