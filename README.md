# solidcraft-orch

The orchestrator that turns SolidCraft issues into pull requests that a maintainer can
merge. Bash, Python and a user crontab: it is not an app, it is a process. Every piece
of state lives on disk, so it survives a crash, a `/new` session and a SIGKILL.

This README is also the onboarding guide. **Section 3 ("What NOT to do") is the most
important part of the file**: every line there is a lesson that cost hours. The long
version, with the measurements, is in
[`reports/lecciones-2026-11-22.md`](reports/lecciones-2026-11-22.md); what this session
did and what it produced is in
[`reports/sesion-2026-11-23.md`](reports/sesion-2026-11-23.md).

---

## 1. The runtime, as it is today

| piece | what it is | where it lives |
|---|---|---|
| the agent of a slot | an **opencode** session: `opencode run --standalone --auto --format json --title issue-N -m <model>` | `bin/dispatch-slot.sh` |
| the model, the binary, the agent name | the **policy of this machine**, not code | `bin/agent-env.sh` reads `$LOOP_DIR/config.env` |
| the scheduler | the **user crontab** (cron, not hermes) | `bin/install-crontab.sh` installs the jobs of `bin/crons.txt` |
| the claim arbiter | one implementation, asked once | `bin/claim-verify.sh` (exit code IS the verdict) |
| the gate | the CI of the fork (`GATE_MODE=fork-ci`) or the local one (`GATE_MODE=local`) | `bin/gate.sh`, `bin/fork-ci.sh` |
| the cleanup | the **orchestrator's** job, never the agent's | `bin/close-slot.sh` |
| the memory | files on disk, never the chat | `state/` (by concept), `state.json` (the artifact), `history.jsonl` |

**hermes is gone.** It was the runner of the agents and the owner of the crons; it is
not installed on this machine any more, and nothing in this repo needs it. Two lessons
came out of that: a scheduler that is not installed is not a scheduler (there were
**no crons at all** for a whole night, and the slots piled up: three "running" slots
with no agent and 53 GB of worktrees and target dirs), and a cron that runs a **copy** of
the script is a cron that runs old code (the wave ran a week-old `wave.sh` for hours and
nobody noticed). The crontab runs **the script of this repo**, so a fix lands in the
cron at once.

```
issue -> claim (draft PR) -> RED -> fix -> PR -> gate -> ready -> merge
```

Each step is a process that can die and be resumed; the edges are conditions on files
and on GitHub, not on a session being alive.

---

## 2. The loop

### The wave: the part that runs without anybody

`bin/wave.sh` is one turn of the loop, every 10 minutes:

1. **collects** the slots in flight: the ones in the state, the ones whose lock is taken
   (the lock is the durable record: the state can lose a slot) and the ones whose
   worktree is on disk (an agent that released its lock and died leaves 7 GB nobody
   knows about).
2. **closes** the slots whose work landed as a pull request and whose agent is not
   working any more: the PR is verified, the target dir and the worktree go, the brief
   goes, the lock is released. That is what frees the disk for the next agent (5.6 GB
   of target and 700 MB of worktree per slot).
3. **reaps** the locks of the slots that are dead without a pull request: their branch
   goes to the fork first (a branch in the fork is the work that survives), then the
   slot is marked `saved`.
4. **resumes** the work in progress before starting anything new: a slot with the work
   already in the fork is worth more than a new issue (the RED test is written, the
   analysis is done, and upstream will not give the issue back: the claim lapses after
   14 days without pushes).
5. **starts** the free slots: the next issue worth an agent (`bin/next-issue.py`), the
   slot prepared (`bin/prepare-slot.sh`), the agent dispatched (`bin/dispatch-slot.sh`).

**A slot whose agent is alive is never touched.** "The PR exists" is not "the work is
done": an agent that opened the PR keeps working on it (the gate, the evidence). The
liveness is checked by `bin/slot-busy.sh`: a process whose working directory is inside
the worktree or the target dir.

### Pausing it

`bin/loop-pause.sh` stops the loop without losing anything, in three levels:

```bash
bash bin/loop-pause.sh pause            # no NEW work: the crontab block goes
bash bin/loop-pause.sh pause --freeze   # also SIGSTOP of the agents and the gates
bash bin/loop-pause.sh pause --stop     # also SIGTERM: the CPU is free at once
bash bin/loop-pause.sh resume           # the crontab comes back
bash bin/loop-pause.sh status
```

`pause` leaves a marker (`locks/loop-paused`) so the wave exits early while it exists.
The work already pushed to the fork survives any of the three.

### The crons

The register is [`bin/crons.txt`](bin/crons.txt); `bin/workflow-validate.py` checks
that it and `workflow.yaml` agree, so a cron that runs and is not in the register does
not exist, and a cron in the register that is not in the workflow is an error of the
suite.

| cron | every | script | what it does |
|---|---|---|---|
| solidcraft-wave | 10 min | `wave.sh` | closes the finished slots, starts the free ones |
| solidcraft-pipeline | 5 min | `pipeline.py` | fixes the bodies, queues the gates, passes the PRs to ready |
| solidcraft-gate-queue | 5 min | `gate-queue.sh` | drains the gate queue (two at a time) |
| solidcraft-comment-watch | 15 min | `comment_watch.py` | reads the maintainer's comments into a task queue |
| solidcraft-nice-compilations | 10 min | `nice-compilations.sh` | lowers the priority of the new builds |
| solidcraft-reporte-diario | 16 and 46 | `daily-report.py` | the daily report, no LLM |
| solidcraft-gc-disk | 30 min | `gc-disk.sh` | the disk: artifacts and dead targets |
| solidcraft-loop-status | 30 min | `loop-status.py` | the state of the loop, no LLM |

No two of them fall in the same minute, and the order inside the cycle matters: the
wave dispatches at `:00`, the pipeline queues the gates at `:02`, the queue takes them
at `:03`.

```bash
bash bin/install-crontab.sh            # install the jobs (idempotent)
bash bin/install-crontab.sh --dry-run  # what it would do
bash bin/install-crontab.sh --remove   # take the jobs away
bash bin/preflight.sh                  # what this machine is missing
```

### The gate

Two gates, one policy knob (`$LOOP_DIR/config.env`):

- `GATE_MODE=fork-ci` (the default here): the CI of the fork is the gate. The fork has
  **only `ci.yml` enabled** (the other sixteen workflows of upstream are disabled: in
  October the fork published a nightly release and tagged its issues). This needs the
  fork's Actions to be enabled in the web UI; when they are off, the dispatch answers
  `422 Actions has been disabled for this repository` and the gate falls back to the
  light lane of upstream plus the local scoped gate.
- `GATE_MODE=local`: the scoped gate compiles here (`bin/gate.sh`).

A PR is passed to ready when the gate is green. **That decision is the orchestrator's**,
never the agent's.

---

## 3. What NOT to do

Every line is a lesson that cost hours. The numbers are in
[`reports/lecciones-2026-11-22.md`](reports/lecciones-2026-11-22.md).

### On the shared machine

1. **Do not compile Rust from an agent.** The gate queue compiles, two at a time. An
   agent that compiles takes a slot and competes for the Cargo locks: there have been
   3-9 concurrent builds, and two agents burned 2h29m each without a single commit.
2. **Do not use `pkill`, `killall` or `kill -9`.** On a shared machine a `pkill` can
   kill somebody else's build. To stop **your** build: keep its PID and send
   `kill -TERM` to that PID only. To wait for the box: a loop over `pgrep -x cargo`,
   or `bin/build-slot.sh --status`.
3. **Do not edit a script that is running.** Replace it atomically (`os.replace`, `mv`).
4. **Do not put a stub of a tool in a directory that can be on the `PATH`.** A fake `gh`
   that does nothing turns `pr create` into a no-op: pull requests that do not exist.
5. **Two heavy builds at most, each with its own `CARGO_TARGET_DIR`** (one per slot).
   A shared target makes one build delete the artifacts of the other: 2423 false
   failures, once.
6. **`CARGO_INCREMENTAL=0`, always.** With incremental the `rustc` runs are not
   cacheable and every slot recompiles the same dependencies.
7. **The box has 15 GB and ONE heavy build at a time.** The heavy token
   (`bin/slot-lock.sh --heavy`) exists for that. If a build dies with `signal 9`, that is
   memory, not code: wait for the box to breathe and try again. The agents that ran
   here for hours proved it: with eight builds at once, the engine's test binary (5 GB to
   link) was killed a dozen times.

### On the verdicts

8. **A verdict that does not reach the exit code is worse than no verdict.** Everything
   that fails exits non-zero, and whoever reports propagates the code.
9. **A failure that already exists in `origin/main` is not a regression.** The verdict
   that counts is the *effective* one (`bin/gate-baseline.sh`), which separates what was
   already broken from what the change broke.
10. **The baseline is merged, never replaced.** A merge cannot lower the count of
    pre-existing failures.
11. **The effective verdict must be compared against the same upstream commit.**
12. **A check that could not run is NOT a red**: exit code 6 = UNKNOWN, never "no".

### On the work

13. **The draft PR is the claim.** The bot's `/claim` expires after 72 h, but a **draft
    without pushes** can be taken over after **14 days** (`PR_IDLE_DAYS` in
    `scripts/claim/claim.js`). The 14 days are the number that matters for a draft.
14. **The RED test comes before the fix.** The minimum deliverable of the investigation
    is the failing test, committed and pushed.
15. **The briefs are literal**: the code to apply, the path, the commit message, the
    test command. A brief that says "look for the bug" produces exploration, not code.
16. **Only issues, not features.** Measured on this machine: an issue costs $0.25 and
    16 h of agent time per delivery; a feature, $1.90 and 138 h, with an 86% chance of
    being cancelled. The issue arrives with the cause; a feature demands inventing the
    API, the command spec, the UI and the locales.
17. **A regression test goes in the area's existing test file**, never in a file named
    after the bug (`AGENTS.md`, issue #3226).
18. **`Changes a default: no` is the exact form** the upstream parser reads. Not
    "Changes to default: no". The position does not matter; a code fence, an HTML
    comment or backticks break it.

### On git and the repo

19. **Push ONLY to the fork.** Never to `origin`, never force-push to `main`, never
    change the branch of the main checkout.
20. **Do not touch the main checkout or the worktree of another slot.** Each agent has
    its own worktree.
21. **The liveness of a lock is its age and its owner, never its PID.** And release the
    slots: a build token taken without a live process blocks the whole queue.
22. **Before opening a PR, read the comments, the assignees, the timeline and the open
    PRs.** On a duplicate the lowest number wins. A lost claim is not thrown away: the
    diff and the commits are preserved and offered on the PR that won.

### On the disk and the slots

23. **The cleanup is the orchestrator's job.** `bin/close-slot.sh` removes the target
    dir, the worktree, the brief and the lock, and refuses to do it while a gate is
    running or queued. The agent must NOT delete its own worktree: the gate of the slot
    compiles inside it, and the pipeline queues that gate after the agent opens the PR.
    An agent that deleted its worktree produced a false ROJO on a healthy PR (#20017).
24. **Do not close a slot whose agent is still working.** The orchestrator deleted the
    worktrees of a live agent twice and aborted its test run. Close a slot when its
    agent has reported, or when the worktree is clean AND no process works in it.
25. **A leftover of a finished turn keeps a slot alive for hours.** An agent that left
    a `python3 -m http.server` running kept its slot "busy" for 20 h 54 min, and its
    79 GB of target were never freed: `bin/slot-busy.sh` sees the working directory of
    a process and calls the slot alive.
26. **`gh pr create --body @file` does not expand the file.** The pull request keeps the
    literal string `@/tmp/...` as its body, and the "Defaults line check" fails
    because of it. Use `gh pr create --body-file <file>`, or
    `gh api -X PATCH repos/tangency-labs/solidcraft/pulls/<n> -F body=@<file>`.
27. **The work that exists only on this machine is a commit that exists for nobody.** The
    question is "is MY work in the fork?", and the base of the comparison is the
    `main` of the **upstream**, not the fork's. `bash bin/branch-risk.sh` says the three
    things without confusing them: **AT RISK** (the commit is in no ref of the fork),
    **SAVED** (it is on GitHub under another name) and **merged**.

---

## 4. The scripts

| script | what it does |
|---|---|
| `bin/wave.sh` | one turn of the loop (close, reap, resume, start) |
| `bin/dispatch-slot.sh` | starts the opencode agent of a slot with the brief |
| `bin/agent-env.sh` | the agent runtime of this machine (binary, model, name) |
| `bin/prepare-slot.sh` | the slot: lock, worktree, branch, target dir, brief |
| `bin/close-slot.sh` | the close-out: verify the PR, free the disk, release the lock |
| `bin/next-issue.py` | the next issue worth an agent, and why |
| `bin/issue-card.py` | the card of an issue (cause, kernel or not, the value) |
| `bin/claim-verify.sh` | the arbiter of the claim (the exit code IS the verdict) |
| `bin/gate.sh`, `bin/fork-ci.sh` | the gate (local, or the CI of the fork) |
| `bin/pipeline.py` | fixes the bodies, queues the gates, passes the PRs to ready |
| `bin/verify-pr.sh` | everything about a PR in one call (0 ok, 1 failed, 6 unknown) |
| `bin/install-crontab.sh` | installs the crons of `bin/crons.txt` |
| `bin/loop-pause.sh` | pause / resume the loop in three levels |
| `bin/preflight.sh` | what this machine is missing |
| `bin/gc-disk.sh` | the disk: artifacts, dead targets, dead branches |
| `bin/orch-state.sh` | the state, by part (`slots`, `prs`, `gates`, `issue N`) |
| `bin/state-set.py` | writes one key of the state and rebuilds the artifact |
| `bin/merge-state.sh` | the state split by concept, and its artifact (`--bootstrap`, `--check`) |
| `bin/slot-lock.sh` | the locks of the slots and the heavy-build token |
| `bin/slot-busy.sh` | is somebody working in this slot right now |
| `bin/branch-risk.sh` | the work that only exists on this machine |
| `bin/ci-status.sh` | the CI of a head in one line |
| `bin/rules-sync.sh` | did upstream move the rules this repo quotes |
| `bin/test-all.sh` | every suite of the orchestrator, and its verdict |

The half of the orchestrator that lives in `$LOOP_DIR` (the publisher, the claim
arbitration of the loop, the scoped gate, the disk collector) is **versioned here**, in
[`loop/`](loop/). The runtime that is per machine (the verdicts, the logs, the
worktrees, `config.env`) is not.

---

## 5. The state

Everything is on disk; the chat is not the memory.

```
state/          the state by concept: slots, prs, gates, claims, policy, notes
state.json      the artifact: the same, rebuilt by bin/merge-state.sh
history.jsonl   append-only: what was done, one line per action
locks/          the lock of each slot, the heavy-build token, the pause marker
gates/          the queue of the gates, and the verdicts (in $LOOP_DIR/gates/)
targets/        the target dir of each slot (a cache: cargo rebuilds it)
logs/           the evidence: the turn of each agent, the verification of each PR
reports/        the measurements, the analyses, the lessons
```

Read it by parts, never whole:

```bash
bash bin/orch-state.sh              # summary: slots, PRs, gates
bash bin/orch-state.sh slots        # only the slots
bash bin/orch-state.sh issue 16829  # everything known about one issue
bash bin/orch-state.sh history 10   # the last ten actions
```

**The state has to be true, not complete.** An entry that is old (a merged PR that
still says "open") costs more than a missing one. GitHub is the truth; the disk is
corrected.

---

## 6. Installing it on another machine

```bash
git clone <this-repo> ~/.local/share/solidcraft-orch
cd ~/.local/share/solidcraft-orch
mkdir -p targets logs locks gates state reports briefs baseline
bash bin/merge-state.sh --bootstrap     # the state of a new machine (idempotent)
bash bin/merge-state.sh --check         # has to be rc=0
```

The other half, the runtime:

```bash
LOOP_DIR="${LOOP_DIR:-$HOME/.local/share/solidcraft-loop}"
mkdir -p "$LOOP_DIR"
ln -s "$ORCH_DIR/loop/bin"     "$LOOP_DIR/bin"      # the versioned code
ln -s "$ORCH_DIR/loop/prompts" "$LOOP_DIR/prompts"  # the prompts of the loop
cp "$ORCH_DIR/loop/config.env.example" "$LOOP_DIR/config.env"   # the policy of the machine
```

Then the agent runtime and the crons:

```bash
bash bin/preflight.sh         # says what is missing
bash bin/install-crontab.sh   # the crons
```

The paths have defaults, so on another machine it is enough to export them:

```
ORCH_DIR=...  LOOP_DIR=...  SOLIDCRAFT_REPO=...  WORKTREES_DIR=...
```

The secrets (never in a versioned file) are `GH_TOKEN` and
`SOLIDCRAFT_CONTROL_TOKEN`.

---

## 7. The tests

```bash
bash bin/test-all.sh          # every suite
bash bin/test-all.sh --fast   # only the ones that run anywhere
```

A suite that cannot run is reported as a **failure**, never as a skip: a suite that
cannot run is not a green. The two that live in the loop (`test-gate-quick.sh` and
`test-rules.py`) need the machine.

Two checks that do not compile and are worth running before any heavy work:

```bash
bash bin/gate-structural.sh   # the static checks of upstream (layers, mesh-decisions, ...)
bash bin/rules-sync.sh        # upstream moved a rule that this repo quotes
```

---

## 8. The pointers

| what | where |
|---|---|
| the lessons of this machine, with the numbers | [`reports/lecciones-2026-11-22.md`](reports/lecciones-2026-11-22.md) |
| what this session did and produced | [`reports/sesion-2026-11-23.md`](reports/sesion-2026-11-23.md) |
| the analysis of the loop, with the costs | [`reports/analisis-orquestador-2026-11-21.md`](reports/analisis-orquestador-2026-11-21.md) |
| the state at the start of a session | [`HANDOFF.md`](HANDOFF.md) |
| the rules of the orchestrator | [`RULES.md`](RULES.md) |
| the documents of the loop | [`docs/`](docs/) — start with [`docs/starting-a-session.md`](docs/starting-a-session.md) and [`docs/known-traps.md`](docs/known-traps.md) |
| the rules of upstream (the truth) | `AGENTS.md`, `CONTRIBUTING.md` and `skills/` in the SolidCraft repository |
