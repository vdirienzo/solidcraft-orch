# Duplicate claims, and contributing instead of duplicating

The upstream repo is busy: many agents claim the fresh issues at the same time, so a wave
routinely finds that some of its issues already have a PR. This file is the recipe for
deciding what to do in each case, and for the one case where the right answer is neither
"open a PR" nor "stop": contribute.

## 1. The check, before an agent is dispatched

    gh search prs --repo tangency-labs/solidcraft "<issue-number>" --limit 6 \
      --json number,title,state,author,createdAt
    gh pr list --repo tangency-labs/solidcraft --state open --limit 40 \
      --json number,title,author,createdAt,body \
      --jq '.[]|select(.createdAt|test("<today>"))|"#\(.number)\t\(.author.login)\t\(.title)"'

READ THE TITLES of today's PRs against the issue SYMPTOM. `gh search prs` finds only the PRs
whose TITLE carries the number; a PR that covers an issue usually names it in the BODY
("Closes #N"), and its title describes the behaviour in the maintainer's words. A title like
"Sketch: renaming or clicking a feature no longer reopens its sketch" covers the issue
"renaming a second extrusion opens the main sketch" even though no number appears anywhere.

Also read the issue's COMMENTS: the claim bot posts there, and a closed claim or a "fixed by
#W" means the issue is not free.

`gh pr list` is the way to search PRs, not `gh api`: the API listing returns an empty body on
some PRs and a filter over the body then finds nothing.

## 2. The decision table

| what you find | what to do |
|---|---|
| no PR names or describes the issue | dispatch the agent |
| a PR covers it AND has code | stop the agent; take the analysis, open nothing |
| a PR covers it and is MERGED | stop the agent; then check whether the shipped RULE is right at the edges (section 4) |
| a PR covers it but is an EMPTY CLAIM (0 files, or a single "claim: #N" commit) | contribute the fix AS A COMMENT on that PR (section 3) |
| a PR covers PART of the symptom | the remainder needs its OWN issue; file it with the numbers and let the agent stop |
| a PR exists but its author is not moving it | wait for the takeover rule (an idle draft may be taken over), do not duplicate |
| the bug is ALREADY FIXED in `origin/main` | stop the agent; open nothing; say in the report that upstream carries the fix |

## 2a. The competitor that names the issue in PROSE: the guard cannot see it

The claim check (`bin/claim-verify.sh`) and the upstream `Duplicate PR check` both look for the
CLOSING VERB: `Fixes` / `Closes` / `Resolves` followed by `#N`. A competitor that describes the
same failure in PROSE, without the verb, is invisible to BOTH. So our PR can be a byte-identical
duplicate of someone else's and still look clean — while theirs has the LOWER number and wins.

Measured on 2026-11-11: our #14822 was byte-identical to #14811 (DuBearte, opened 43 minutes
earlier, carrying `approved-for-ci` + `ready to merge`). `claim-verify.sh` answered
`VEREDICTO=OCUPADO el PR #14822 ya reclama #14801` — it pointed at OUR OWN PR as the competitor,
because #14811 mentioned the issue in prose and not with a closing verb.

Two ways to catch it:

1. By the TEXT of the symptom. `gh pr list --search` indexes the title and the body, not the
   diff, so search for the panic message or the test name:
   `gh pr list --state open --search 'Dropped TexturesDelta'`. Searching `textures_delta` (the
   identifier that only exists in the diff) found nothing.
2. Mechanically, by the PATCH: `bin/dup-scan.sh <issue> <branch|sha>`. It compares the ADDED
   lines of our change against the added lines of every open PR that touches the same files, and
   excludes our own PR by number and by head sha. rc=1 means a confirmed duplicate.
   `bin/publish-pr.sh` refuses to publish on rc=1; `bin/gate.sh` warns.

The ratio guard: ours counts as a duplicate when our added lines are a SUBSET of theirs AND ours
is at least 40% of their added lines. The ratio stops a large unrelated PR that happens to contain
one of our lines from counting as a duplicate.

When you close yours because of a duplicate, ask the author to add the closing keyword. #14811
did not carry `Fixes #14801`, so without that request the issue stays open after the fix lands.
And if the fix lands through the OTHER PR, the issue still does not close on its own: the bot only
closes an issue when the merged PR carries a closing verb. After the merge, put the evidence on
the issue (the merge sha, the line in the file) and say it can be closed; if you were the
claimant, release it with `/unclaim` as a comment (the bot answers "Released. This one is free
again" and drops the `in progress` label).

## 2b. The fix may already be in `main`, under a DIFFERENT issue number
Before an agent writes a fix, run its RED test against a clean worktree of `origin/main`.
If the RED PASSES there, the bug is fixed upstream: the fix landed with another issue's
number, or with none, and the only correct outcome is no pull request. The check costs one
throwaway worktree and one test run, and it saves the whole agent cycle.

The tell is in the numbers: the test was written against a branch hundreds of commits behind,
so the RED was real on that base and green on `main`, and the agent's implementation came out
byte-identical to the upstream commit that had already fixed it. A RED that reproduces only
on an old base is not a bug report, it is a report about the base.

Two things follow. First, the claim of that issue is often held by a pull request whose base
already includes the upstream fix, so the pull request that "wins the race" may be redundant:
that is a fact worth telling the maintainer in a comment, not a reason to open a second pull
request. Second, the work that is left over (the part the upstream fix does not cover) is
worth an issue of its own, with the numbers, and never rides along in the stopped agent's
branch.

A second PR for an issue that a lower-numbered open PR closes FAILS the repo's duplicate
check, so "open ours anyway" is not available in any of the duplicate rows.

## 3. Contributing to an empty claim

The repo's own instruction for this situation is to comment on the existing PR instead of
opening a second one. A comment with the finished work is a complete contribution: the author
gets the fix and the issue gets closed once.

    gh pr comment <pr-number> --repo tangency-labs/solidcraft --body-file <file>

### What the comment must contain

1. **The rule, in prose, with its cases.** A table of input -> output beats a link to a diff:
   the author must be able to apply it without reading your branch.

       | tag | catalog | why |
       |---|---|---|
       | `zh-Hant-TW`, `zh-Hant-HK` | `zh-TW` | the script says Traditional |
       | `zh-Hant` | `zh-TW` | the script alone |
       | `zh-HK`, `zh-MO` | `zh-TW` | Hong Kong and Macao use Traditional characters |
       | `zh-Hans-CN`, `zh-CN` | `zh` | Simplified |

2. **The exact place to put it**: the file, the function, and the names of the tests to add,
   and whether the new strings need a catalogue entry.
3. **The branch to cherry-pick from**: the fork, the branch, the SHA — and that the commit is
   a wip, so the mandatory `Changes a default:` line still has to be filled in on the author's
   side. (The upstream parser REJECTS a `yes` that does not carry
   `old behaviour kept behind preference <name>`, so a wip body line is often missing.)
4. **The measurement you took**, because the author cannot reproduce your environment: the
   counts before and after, and the command that produced them.

       LANG=de_DE.UTF-8   ->  3589 passed; 355 failed; 16 ignored
       without LANG       ->  3944 passed; 0 failed; 16 ignored

5. **The caveat that the case may not be a bug at all.** If you verified the rule yourself
   over the cases the issue implies, say the outcome and how you computed it.

### What the comment must NOT contain

- **A closing verb next to an issue number.** "fixes #N", "closes #N" and "resolved by #N"
  in a comment read as a claim to any scanner or reader, and the issue may not be yours to
  close. Name the number in prose with no verb beside it ("the locale-dependent suite, #10297").
  Check it with the upstream parser before posting:

      node -e 'const src=require("fs").readFileSync("/tmp/pr-checks.js","utf8");
        eval(src.match(/function stripNoise[\s\S]*?\n}/)[0]);
        eval(src.match(/function parseClosing[\s\S]*?\n}/)[0]);
        console.log(parseClosing(require("fs").readFileSync(process.argv[1],"utf8"),"tangency-labs/solidcraft"));' <file>

  An empty array is the result you want.
- **An accusation.** The claim is empty because the author is early, not because they did
  something wrong.

## 4. When the duplicate is MERGED, the shipped rule may still be wrong

Stopping an agent because someone else did the issue does not end the analysis: the shipped
implementation can handle the reported case and still misbehave on a neighbouring one. The
report is the case the reporter happened to try, not the rule's whole surface.

So ask the agent to COMPUTE the shipped rule over the cases the issue implies, not to check
whether it covers the reported symptom. A concrete shape: a matcher that tried the exact tag
and then the base language is right for the tag in the report and wrong for a tag that
carries a script subtag before its region, because the base then names a DIFFERENT catalogue
than the one the user is on.

A gap in merged code is real work and it needs its OWN issue (the repo's rule is one issue per
PR, and the merged PR's issue is already closed). File that issue with the numbers, and the
agent's rule plus its test become the brief for it. Never let the gap ride along in the
stopped agent's branch: the issue it was working on is someone else's.

## 5. The steer that stops an agent on a duplicate

Five things to ask for, because the agent holds the only copy of the analysis:

1. WHICH PR covers it, and whether it covers the WHOLE symptom or only part of it;
2. the ROOT CAUSE, with file and line — the expensive part, and it is worth keeping;
3. the RED test if it wrote one, and where it is;
4. to COMMIT AND PUSH the diagnosis to the fork as a `wip` branch before releasing the lock,
   so the analysis survives even though no PR will be opened;
5. whether the RULE the other PR ships is RIGHT at the edges, not just whether it covers the
   reported symptom.

Ask for a SHORT report: a long one gets truncated in the transcript and the orchestrator loses
the data it paid for. If it arrives truncated, the recovery is the agent's commit message — so
require the diagnosis to be committed, not only printed.

## 6. A PR another contributor holds: reply with OFFERS, do not take over

A PR on someone else's branch is not ours to rebase or push to. When its author says they will
rebase later ("to avoid rebasing over and over while review is pending, I will hold off until
this is close to merging, or whenever you want another look"), the useful reply is NOT silence
and NOT a rebase behind their back: it is a short comment with the CONCRETE OFFERS (rebase
onto the current main for them; run the scoped gate on the settled head and post the verdict)
and the decision left where it belongs, on their PR and their timing.

Say what changed on main since their last rebase and how big the conflict is likely to be:
that is the information they need to decide, and it is the information they cannot get without
doing the work you are offering to do.

Two things such a reply must not do:
- carry a closing VERB next to an issue number (the upstream parser reads the verb and the
  number, not the negation, so "does not close #N" closes it);
- be a paragraph of history. The author needs the offers and the state of main, in that order.

Read the whole thread before replying (`gh api repos/<owner>/<repo>/issues/<pr>/comments`),
because the previous turn of the conversation usually says what is already promised and what is
still owed.

## 7. The lock of a stopped agent

A stopped or finished agent often leaves its slot lock taken. Free it by AGE, never by PID,
and never a lock whose owner is still alive:

    bash bin/slot-lock.sh --slot <n> --reap --older-than <min>

The heavy lock is the gate's turn token and one left taken blocks EVERY gate on the machine
with an idle CPU. Take it, release it, always.
