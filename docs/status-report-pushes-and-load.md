# Status report: what went up to the fork, and how loaded the box is

Both halves of a status question ("what did I push", "how is the machine doing") are answered
from the RECORD on disk, not from memory and not from the commit dates.

## 1. What was pushed, and WHEN it was pushed

The commit date is when the commit was written locally, often hours before it reached GitHub.
The push timestamp lives in the reflog of the remote-tracking ref, one "update by push" entry
per push. A force-push supersedes the branch tip, and the reflog keeps every push that
happened, including the ones now superseded.

    git -C /home/user/solidcraft fetch fork --quiet
    git for-each-ref --format='%(refname)' refs/remotes/fork/

Then, per ref:

    git reflog show --date=unix --format='%gd\t%cd\t%gs\t%H' refs/remotes/fork/<branch>

Keep only the entries whose `%gs` contains "push", sort by `%cd` (unix) descending, and render
`sha | branch | subject`.

**Parse the reflog in python, not in awk.** The selector `%gd` contains `@{...}` and the
subject contains spaces, so shell field splitting breaks it: the awk version produced
"date: invalid date" and "ambiguous argument 'update'". A short python loop over the refs
(collect rows, sort by ts, print) is shorter than the shell quoting that fights it.

**Decide the unit of the answer and say which one it is.** One SHA pushed to two branches is
TWO pushes and ONE commit. A "last N pushes" list that mixes both without labelling is not a
count, and the reader cannot check it.

## 2. Pushed vs local-only, per SHA

    git branch -r --contains <sha>          # empty output = never left the machine
    git log --remotes=fork --not --remotes=origin --no-merges \
        --pretty='%cd|%h|%s' --date=iso     # what only the fork has

Do NOT add `--all` to that log: `--all` sweeps in local branches and makes unpushed work look
published. The `--contains` check is the one that settles a specific commit.

## 3. PR state lives in upstream, branches live in the fork

The fork has no PRs of its own: the PR is opened against upstream with a head branch that
lives on the fork. Querying the fork for PRs returns an empty list, which reads like "nothing
is open" when the opposite is true.

    gh pr list --repo tangency-labs/solidcraft --author <fork-owner> --state all --limit 12 \
      --json number,title,state,isDraft,headRefName,createdAt,mergedAt,updatedAt
    gh pr view <n> --repo tangency-labs/solidcraft \
      --json number,state,isDraft,mergeable,headRefOid,reviewDecision,updatedAt

## 4. Load reconstruction from what the kernel already exposes

Do not go looking for a sampler to install: the kernel already exposes everything a load
question needs, and the per-slot build dirs add the part the kernel cannot see (WHICH work
caused the load).

**Instant CPU split.** `vmstat`'s CPU block is the LAST four columns of the line
(`us sy id wa st gu`): busy = `$13+$14`, idle = `$15`, io wait = `$16`. Indexing from the
front of the line reads swap-out and reports a bogus "100% busy" on an idle box.

    vmstat 1 5          # instantaneous, read the numbers, don't parse blind
    vmstat 1 2 | tail -1 | awk '{print "busy", $13+$14, "idle", $15, "wa", $16}'

**Pressure trend (PSI).** `/proc/pressure/cpu` and `/proc/pressure/memory` expose avg10,
avg60, avg300. Read them twice, minutes apart: the DECAY of avg300 toward avg10 shows a peak
that just ended, which is the shape a load question is really asking about.

    cat /proc/pressure/cpu /proc/pressure/memory
    cat /proc/loadavg          # 1/5/15 min: the 15-min average is the recent history

**Build-activity timeline.** The per-slot target dirs are a free log of when work happened:
the mtime of every artifact the compilers wrote.

    find /home/user/.local/share/solidcraft-orch/targets -newermt '-2 hours' -type f \
      -printf '%TY-%Tm-%Td %TH:%TM\n' | cut -c1-16 | sort | uniq -c

Bucketed per 10 minutes this shows the build bursts AND which slot caused them. Per slot:

    for d in slot-10079 slot-10138 ...; do
      echo "$d: $(find .../targets/$d -newermt '-2 hours' -type f | wc -l)"; done

**Who is compiling right now** (attribution without asking the shell to guess):

    ps -eo args | grep -o 'targets/slot-[0-9]*' | sort | uniq -c

**Why the builds are expensive:**

    sccache --show-stats

A hit rate near 0% means every crate recompiles from scratch; that cache is pure loss and is
covered by the disk-hygiene rule (delete a cache whose hit rate is ~0). Quote the hit rate as
the cause of the spikes, not as an aside.

## 5. Memory: used vs available, and rates not totals

    free -m

The gap between `free` and `available` is buff/cache, which is reclaimable. A box with almost
no `free` but tens of GB `available` is not under memory pressure, and reporting the `free`
number alone invents a problem.

Swap and page-fault counters in `/proc/vmstat` are CUMULATIVE since boot:

    grep -E 'pswpin|pswpout|pgmajfault' /proc/vmstat

Quote them only as a RATE: sample, wait, sample again, and report the delta over the window.
The absolute since-boot number says nothing about the window asked about. `pswpin`/`pswpout`
staying at 0 and memory PSI staying near 0 are the real evidence of "no memory pressure".

## 6. Two traps on this box

- **Never run a recursive content search across `/home/user/.local/share/solidcraft-orch/`.**
  It contains the per-slot target dirs (tens of GB of build artifacts); the walk times out
  before it prints anything. Scope the search to `logs/` and the top-level files.
- **The kernel ring buffer is not readable by this user** (`dmesg` and `journalctl -p warning`
  return nothing). That silence is not evidence of a clean kernel; use PSI, `free` and
  `/proc/vmstat` for memory and CPU health instead.
