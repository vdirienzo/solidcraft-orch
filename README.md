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
| the turn of the agent | the same session, plus a nudge when the run ends without a verdict | `bin/agent-turn.sh` |
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

### The declared graph

The process of an issue is **declared**, not remembered:
[`workflow.yaml`](workflow.yaml) is 15 nodes with their edges, their preconditions,
what to do when they fail, and the vocabulary of signals that the runner evaluates
against the disk. It exists because the process used to live in the head of whoever
ran the orchestrator: 49 scripts and no map, so nobody could answer "what is next"
without rebuilding the state by hand.

```yaml
nodos:
  - id: buscar-issue    # an agent does it: script: null
  - id: claim-verify    # bin/claim-verify.sh
  - id: gate            # bin/gate.sh
senales:                # the conditions, evaluated against the state on disk
  - pr_draft_sin_veredicto
```

Two scripts read it:

| script | what it does |
|---|---|
| `bin/workflow-validate.py` | the graph has to be a graph: the edges point to nodes that exist, every script named exists, every signal used is declared, and `bin/crons.txt` and the graph agree |
| `bin/workflow-runner.sh --list` | the nodes that are eligible **now**, and why |
| `bin/workflow-runner.sh --dry-run` | the exact command of the node it would run, without running it |
| `bin/workflow-runner.sh` | runs exactly **one** eligible node, and only after validating the graph |

The runner never compiles Rust: a node marked `compilacion_pesada: si` is *proposed*,
and the cron that owns it runs it. It never calls the network either: GitHub is the
final truth, but the runner reads the state on disk, so if `state.json` is old the
proposals are old.

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
| solidcraft-wave | 10 min (`*/10`) | `wave.sh` | closes the finished slots, starts the free ones |
| solidcraft-pipeline | 5 min (`:02,:07,…`) | `pipeline.py` | dispatches the CI of the fork (or queues the local gate), passes the PRs to ready. It does **not** edit bodies any more |
| solidcraft-gate-queue | 5 min (`:03,:08,…`) | `gate-queue.sh` | drains the gate queue (two at a time) |
| solidcraft-comment-watch | 15 min (`:04,:19,…`) | `comment_watch.py` | reads the maintainer's comments into a task queue |
| solidcraft-nice-compilations | 10 min (`:01,:11,…`) | `nice-compilations.sh` | lowers the priority of the new builds |
| solidcraft-reporte-diario | `:16` and `:46` | `daily-report.py` | the daily report, no LLM |
| solidcraft-gc-disk | 30 min (`:14,:44`) | `gc-disk.sh` | the disk: artifacts and dead targets |
| solidcraft-loop-status | 30 min (`:06,:36`) | `loop-status.py` | the state of the loop, no LLM |

No two of them fall in the same minute, and the order inside the cycle matters: the
wave dispatches at `:00`, the pipeline queues the gates at `:02` and the queue takes
them at `:03`.

**Two jobs were taken out of the register on 2026-11-21**:
`solidcraft-ping-ready` (upstream's guide says not to ask for `approved-for-ci` over and
over; `bin/ping-ready.sh` stays for a manual `--report`) and
`solidcraft-wave-prompt-guard` (it watched a hermes cron, and hermes is gone).

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
    "Changes to default: no". The position does not matter; a code fence or an HTML
    comment break it. The parser also accepts `no` with a note behind it, the heading
    form `## Changes a default` with the value under it, and a backticked value.

**Upstream moved its rules on 2026-11-25 and 2026-11-28** (`AGENTS.md` was rewritten and the
skills moved to `.agents/skills/`). These are the rule now, not the old form:

- **The claim DRAFT carries the issue number** in its title (the claim bot reads it there);
  the **ready pull request does not**: `Area: what the user now gets`, present tense, no
  `feat:`/`fix:`, about 100 characters. The merge adds the `(#N)`. A follow-up says it in
  the title: `(follow-up to #23431)`.
- **`Test change: <why the old expectation was wrong>`** only when the diff touches kernel
  source (`solidcore/`, `crates/smlib/`) AND changes or deletes a line of an existing test
  or golden expectation. New tests need no line.
- **A fixed test leaves `tests/KNOWN_FAILING_TESTS`.** If the fix makes a listed test pass,
  its line is removed in the same PR: the CI fails on a listed test that now passes.
- **Media only in two cases**: a change visible in the UI, or a change in how the model
  looks. A kernel or geometry fix proven by tests needs none. When it is needed, the
  pictures go in the description as links, never in the diff, and without private details
  (home paths, user names, tokens).
- **The gate here is narrow on purpose.** Upstream says "Before pushing: `cargo xtask ci`",
  but that `ci` always runs the whole-workspace clippy, the whole test suite (78 binaries,
  56-90 min on this box), the wasm build of every crate and the doc tests; only four checks
  are picked by changed paths. The local gate is `cargo xtask fast --base origin/main` plus
  `cargo xtask app-geometry` (new, `fast` does not run it) and the path gates the change
  touches; the complete `ci` belongs in the CI.
- **Merging `main` in is the cheap way to be up to date** (the CI carries a passing run when
  the merge leaves the change as it was); a rebase re-runs the whole suite. Rebasing is fine
  too, with `--force-with-lease` and only on your own branch.
- **The PR is opened ready for review** when the change is done: the draft is only the claim.

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

### On the process

28. **A cron that is not in `bin/crons.txt` does not run.** There were two graphs (the
    declared one in `workflow.yaml` and the installed one in the crontab) and nothing
    checked them: a cron could exist, run every day and be in neither list.
    `bin/workflow-validate.py` is the check.
29. **`gh issue list --limit` truncates the pool.** The upstream has ~6,800 issues open;
    `--limit 150` showed the selector 2% of them, and the rest looked like "no issue
    left". `bin/gh_snapshot.py` takes **one** snapshot of the open issues and PRs and
    everything reads that.
30. **One arbiter per concept.** The rule of "who owns the claim of issue N" lived in a
    `jq` inside `bin/claim-verify.sh` *and* in two scripts of `loop/`, and they did not
    read the body the same way. It is now one file: `bin/claim_rule.py`.
31. **`opencode run` ends when the model writes text without calling a tool.** A turn
    can finish with "let me instrument all the doc-level boolean calls" and no verdict,
    no commit, no push: the wave then closes the slot. `bin/agent-turn.sh` is the
    wrapper that nudges the same (still warm) session when the run has no verdict.

---

## 4. The scripts

About fifty scripts, grouped by what they are for. The name of the group is the
question you have when you look for one.

**The loop** — one turn of it, the pause, the schedule

| script | what it does |
|---|---|
| `bin/wave.sh` | one turn of the loop (close, reap, resume, start) |
| `bin/wave-chain.sh` | the sequencer of the wave of 14-11 (the resume path still points at it) |
| `bin/loop-pause.sh` | pause / resume the loop in three levels |
| `bin/crons.txt` | the register of the crons: **the source of truth** |
| `bin/install-crontab.sh` | installs the jobs of the register in the crontab of the user |
| `bin/loop-status.py` | the state of the loop, no LLM |
| `bin/daily-report.py` | the daily report, no LLM |

**The declared graph** — the process, written down

| script | what it does |
|---|---|
| `workflow.yaml` | the declaration of the process of an issue (15 nodes, edges, preconditions, signals) |
| `bin/workflow-validate.py` | the graph is a graph, and the register agrees with it |
| `bin/workflow-runner.sh` | runs **one** eligible node, after validating the graph |

**The slot** — the agent and its box

| script | what it does |
|---|---|
| `bin/prepare-slot.sh` | the slot: lock, worktree, branch, target dir, brief |
| `bin/dispatch-slot.sh` | starts the opencode agent of a slot with the brief |
| `bin/agent-turn.sh` | one turn of the agent, with the nudge when the run has no verdict |
| `bin/agent-env.sh` | the agent runtime of this machine (binary, model, name) |
| `bin/close-slot.sh` | the close-out: verify the PR, free the disk, release the lock |
| `bin/slot-lock.sh` | the locks of the slots and the heavy-build token |
| `bin/slot-busy.sh` | is somebody working in this slot right now |
| `bin/slot-stale.sh` | which slots are stuck (old lock, branch that does not move) |
| `bin/slot-prs.py` | our pull requests, matched to the slots in flight |
| `bin/slot-target-dir.sh` | the target dir of a slot, one per slot |
| `bin/lock-heartbeat.sh` | refreshes the liveness of a lock |
| `bin/slots.sh` | how many slots may run at once (free cores and free RAM) |
| `bin/run-issue-scope.sh` | an issue runner with a memory ceiling |

**Choosing the work** — which issue, and whose claim it is

| script | what it does |
|---|---|
| `bin/next-issue.py` | the next issue worth an agent, and why |
| `bin/issue-card.py` | the card of an issue (cause, kernel or not, the value) |
| `bin/gh_snapshot.py` | one snapshot of the open issues and PRs of the upstream |
| `bin/dup-scan.sh` | one of our PRs duplicating another author's |
| `bin/claim_rule.py` | the one rule of "who owns the claim of issue N" |
| `bin/claim-verify.sh` | the arbiter of the claim (the exit code IS the verdict) |

**The gate and the pull request**

| script | what it does |
|---|---|
| `bin/gate.sh` | the local gate (`cargo xtask fast --base`) |
| `bin/fork-ci.sh` | the CI of the fork used as the gate |
| `bin/gate-queue.sh` | the queue of gates waiting for a build slot |
| `bin/gate-runner.sh` | the gates, one at a time |
| `bin/gate-baseline.sh` | the effective verdict: the raw one minus what was already broken |
| `bin/baseline-refresh.sh` | refreshes the failures measured on `origin/main` |
| `bin/pipeline.py` | dispatches the CI of the fork (or queues the local gate), passes the PRs to ready |
| `bin/publish-pr.sh` | the only way to open one of our pull requests |
| `bin/verify-pr.sh` | everything about a PR in one call (0 ok, 1 failed, 6 unknown) |
| `bin/ping-ready.sh` | the review package of the PRs that are ready (manual now, not a cron) |
| `bin/ping-ready-report.sh` | the same summary, without commenting on GitHub |
| `bin/ci-status.sh` | the CI of a head in one line |
| `bin/comment_watch.py` | the maintainer's comments become a task queue |

**The machine** — the box, the disk, the builds

| script | what it does |
|---|---|
| `bin/build-slot.sh` | the token of a build slot |
| `bin/cargo-jobs.sh` | how many parallel jobs a cargo invocation should use |
| `bin/nice-compilations.sh` | lowers the priority of the new builds |
| `bin/gc-disk.sh` | the disk: artifacts, dead targets, dead branches |
| `bin/sccache-health.sh` | is the compile cache earning the disk it holds? |
| `bin/branch-risk.sh` | the work that only exists on this machine |
| `bin/kill-orphan-browsers.sh` | the browsers of the MCP that were left without an owner |

**The state, the reports and the launchers**

| script | what it does |
|---|---|
| `bin/merge-state.sh` | the state split by concept, and its artifact (`--bootstrap`, `--check`) |
| `bin/state-set.py` | writes one key of the state and rebuilds the artifact |
| `bin/orch-state.sh` | the state, by part (`slots`, `prs`, `gates`, `issue N`) |
| `bin/rules-sync.sh`, `bin/rules-snapshot.sh` | did upstream move the rules this repo quotes |
| `bin/preflight.sh` | what this machine is missing |
| `bin/test-all.sh` | every suite of the orchestrator, and its verdict |
| `bin/launch-app.sh` | the app with its control channel open, for the evidence |
| `bin/launch-wave.sh`, `bin/launch-resume.sh`, `bin/launch-slot-service.sh` | a wave, a resume, and an agent as a transient systemd unit |
| `bin/sc_control.py` | the client of the control channel of the app |
| `bin/measure-17881-before-after.sh`, `bin/capture-17881-evidence.py`, `bin/experimento-paralelismo.sh` | the measurement of one issue, its evidence, and the experiment of the parallelism |

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

**Three exit codes decide things, and they do not mean the same thing.** A script
that could not read the world returns "unknown", and "unknown" is never "no":

| script | 0 | 1 | other |
|---|---|---|---|
| `bin/verify-pr.sh` | the PR is fine | the PR is broken | 6 = it could not be read |
| `bin/claim-verify.sh` | the claim is ours | we LOST the claim | 2 = it could not be told |
| `bin/prepare-slot.sh` | the slot is ready | the slot could not be prepared | 6 = the cause is in the kernel, which this box does not build |

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
bash bin/test-all.sh             # every suite
bash bin/test-all.sh --fast      # only the ones that run anywhere
bash bin/test-all.sh gate        # only the suites whose name matches
```

41 suites live in `bin/test-*.sh` and `bin/test-*.py`. A suite that cannot run is
reported as a **failure**, never as a skip: a suite that cannot run is not a green.
The two that live in the loop (`test-gate-quick.sh` and `test-rules.py`) need the
machine, and five are heavy (`test-slot-parallelism.sh`, `test-deploy-drift.sh`,
`test-publish-pr.sh`, `test-state-split.sh`, `test-briefs.sh`).

Two checks that do not compile and are worth running before any heavy work:

```bash
cargo xtask fast --base origin/main   # the narrow local gate of this box: fmt, layers,
                                      # clippy, check, nextest on the packages the change
                                      # touches (upstream's prepush check is `cargo xtask ci`,
                                      # which is the whole suite and does not fit here)
cargo xtask app-geometry              # the new check `fast` does not run
bash bin/rules-sync.sh                # upstream moved a rule that this repo quotes
bash bin/rules-verdict.sh             # the same check as one verdict block (the watch job runs it)
```

**The watch job**: the automation `solidcraft-rules-watch` runs `bin/rules-verdict.sh` every six
hours and brings the verdict: `OK` (the snapshot matches `origin/main`), `CAMBIÓ` (the files that
moved and the diff stat) or `NO SE PUDO COMPROBAR` (the check could not run, which is not "up to
date"). It only reads: it changes nothing, it publishes nothing, it merges nothing. It also
checks two things that rot without noise: **the paths of upstream that our documents name exist**
(the skills, the scripts, the kernel files) and **the briefs cite paths that are still there**. The
verdict is also written to `~/.local/share/solidcraft-orch/state/rules-verdict.txt` with the date
and the upstream commit it measured. When it says something moved, a person orders the update and
a subagent does it against `RULES.md` and `prompts/`.

---

## 8. The pointers

| what | where |
|---|---|
| the lessons of this machine, with the numbers | [`reports/lecciones-2026-11-22.md`](reports/lecciones-2026-11-22.md) |
| what this session did and produced | [`reports/sesion-2026-11-23.md`](reports/sesion-2026-11-23.md) |
| the analysis of the loop, with the costs | [`reports/analisis-orquestador-2026-11-21.md`](reports/analisis-orquestador-2026-11-21.md) |
| the state at the start of a session | [`HANDOFF.md`](HANDOFF.md) |
| the rules of the orchestrator | [`RULES.md`](RULES.md) |
| the declared process of an issue | [`workflow.yaml`](workflow.yaml) |
| the documents of the loop | [`docs/`](docs/) — the index is [`docs/README.md`](docs/README.md); start with [`docs/starting-a-session.md`](docs/starting-a-session.md) and [`docs/known-traps.md`](docs/known-traps.md) |
| the rules of upstream (the truth) | `AGENTS.md`, `CONTRIBUTING.md` and `.agents/skills/` in the SolidCraft repository (`skills/` there are the MCP's, not the agents') |
