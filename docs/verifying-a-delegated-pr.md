# Verifying a delegated PR before you call it done

The agent's summary is a claim. These are the checks that turn it into a fact, and the ones that
catch what a summary will happily omit.

## What the PR actually is
    gh pr view N --repo tangency-labs/solidcraft --json state,isDraft,headRefOid,headRefName,mergeable,mergeStateStatus,body,labels

- the head must equal the fork's head: `git ls-remote fork <branch>` (not the local head — the
  local head can be ahead of what was pushed);
- the body must carry the issue reference and EXACTLY ONE `Changes a default:` line;
- the state must be what you expect: a PR the maintainer acted on can be MERGED already, and
  your disk state can still say "awaiting maintainer". Verify mergedAt against the merge commit
  in the upstream log.

## What the CI actually did
    gh pr checks N --repo tangency-labs/solidcraft

Three states are not the same, and only one of them is green:
- `pass` — ran and passed.
- `skipping` — did not run. A run triggered while the PR was still a DRAFT has every heavy job
  skipped by payload; a PR whose checks are all skipping has no CI at all. Make it run by
  rebasing onto the current upstream head and force-pushing to the fork with --force-with-lease.
- `fail` on an OLD run — usually a run CANCELLED by a newer one (a new run for the same commit
  cancels the previous). Read the job's log before reporting a failure: `gh run view <id>
  --log-failed`. The run that counts is the newest for the head.

## That the local gate really covered
The scoped gate writes a verdict file with one field per phase. A phase that was SKIPPED (the
budget ran out on a cold compile) is UNKNOWN, not green. Read the verdict, and run the skipped
phase by hand:

    bash bin/gate.sh <n> <sha> [base]          # the entry point, from the orchestrator dir
    cat ~/.local/share/solidcraft-loop/gates/<n>/scope.verdict
    export CARGO_TARGET_DIR=$(bash bin/slot-target-dir.sh --slot <n>)
    cargo clippy -p <crate> --all-targets --profile ci -- -D warnings

Use `bin/gate.sh`, not `gate-quick.sh` directly: the cargo phases of the latter run in the
WORKING DIRECTORY, so a gate started from anywhere else dies with "could not find Cargo.toml"
in every phase and the verdict is a ROJO that says nothing about the change. `gate.sh` cds to
the slot's worktree and pre-builds the xtask in the ci profile.

Two more things about the verdict: it names the SHA it judged, and it is NOT deleted when the
head moves, so a verdict of an older commit still reads `VERDE-SCOPE` — compare its `SHA=`
line with the head before believing it. And a gate KILLED mid-run writes no verdict at all,
leaving the previous one on disk: read the log and the mtime of the verdict, not the verdict
alone. Run the gate in the BACKGROUND, or a tool timeout kills the gate with it.

## That the PR is not stale
A PR carries the CI of the day it was opened. A branch hundreds of commits behind
`origin/main` shows every heavy job skipping, which is not a property of the change but of
its age, and it hides a real regression behind a green light.

    git rev-list --count <fork-head>..origin/main     # how far behind

Rebase onto the current `origin/main` and force-push the branch to `fork` with
`--force-with-lease` (never force-push `main`, never push upstream). After the rebase the
change must be re-verified: the tests and the gate judge the NEW tree, and a rebase can
bring a conflict resolution that changes the behaviour. Re-run the directed tests AND the
gate on the rebased SHA, and only then read the verdict.

The rebase must be clean about what it preserves: compare the diff against the base before
and after (`git diff --stat <base>...<sha>`) and confirm the same files and the same line
count survive. A rebase that silently drops half the change reads exactly like a successful
one.

### The base moves WHILE the agent works, and the agent has to rebase again
An upstream that is busy moves `origin/main` during a long agent session, sometimes several
times: the agent rebases, runs the directed test, and then the base moves again before it
publishes. Two things follow, and both are the agent's job, not the orchestrator's:

- **Prove the rebase preserved the change, byte for byte.** Comparing a `--stat` line count
  is not proof, because a conflict resolution can change the patch and keep the count. Write
  the patch to a file before and after (`git diff <base>...<sha> > /tmp/patch.before` and
  `.after`) and diff the two files: an empty diff means the rebase moved the change and
  touched nothing in it. That is the statement the PR body needs.
- **Re-run the directed test after EVERY rebase**, not only after the last one. The test
  judges the tree it runs on, so a test that passed on an earlier base says nothing about
  the current one.

And the orchestrator's part: after the agent reports, compare the head it pushed with the
current `origin/main` before reading the gate verdict. A verdict names the SHA it judged, and
a base that moved after the gate means the verdict is about a tree that no longer exists.

## That the regression test can fail
A test that passes before and after the fix protects nothing. Prove it detects the bug: revert
ONLY the fixed logic, keeping the new APIs so the crate still compiles, and confirm the test
FAILS with the symptom it is meant to catch.

    # edit the fixed function back to its slow form, leave the new types alone
    cargo test -p <crate> --lib <test_name>      # must FAIL
    # restore
    cargo test -p <crate> --lib <test_name>      # must PASS

Reverting a whole file usually does not compile (the test uses APIs the old file lacks), and
then you have proven nothing. Change the behaviour, keep the API.

## That the invalidation cannot miss
When a PR adds a cache, read WHERE THE DATA CHANGES and check that every change is visible to
the cache's key:

    git grep -nE '<field>\.(push|clear|extend|retain)|<field>\[' origin/main -- crates/

If some site writes an element in place, a key built from the list's identity (buffer address,
length, first and last element) can miss it. Confirm there is no such site, or make the key
compare CONTENT.

## That the body says only true things
Read every factual claim in the body against the diff. A body that asserts behaviour the code
does not have is the first thing a reviewer checks, and it costs the PR its credibility.

## That the body names no local path
A body that points at a log file in the agent's own directory describes something the reviewer
cannot open: the file is not in the repo. Logs of RED/GREEN runs belong in the body's own
text — what the failure was, what the pass was — not as a path. Grep the body for `/home/`,
`logs/`, `~/.` and reword every hit, then re-validate: rewording can accidentally introduce
a closing keyword.

## That the body closes EXACTLY what you think it closes
Run upstream's own parser against the body and read the set of issues it will close, instead
of reading the body's phrases and hoping. The parser lives in the repo, so it can be run
directly:

    git show origin/main:scripts/pr-checks/pr-checks.js > /tmp/pr-checks.js
    node -e 'const src=require("fs").readFileSync("/tmp/pr-checks.js","utf8");
      eval(src.match(/function stripNoise[\s\S]*?\n}/)[0]);
      eval(src.match(/function parseClosing[\s\S]*?\n}/)[0]);
      console.log(parseClosing(require("fs").readFileSync("<body-file>","utf8"),"tangency-labs/solidcraft"));'

The parser reads a closing VERB followed by a NUMBER: a sentence that names the verb in prose
("free of any closing keyword") closes nothing, while a sentence that names the verb next to
a number closes that number even when the sentence says it does not. Run it and read the
list: an empty list is the proof that a PR closes no issue on purpose.
